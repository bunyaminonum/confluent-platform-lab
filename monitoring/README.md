# Monitoring: JMX Exporters → Prometheus → Grafana

Metrics collection has two halves, deployed by two different tools:

| Half | What | Deployed by |
|---|---|---|
| **Exporters** | A JMX Prometheus Java agent attached to every Confluent JVM on the VMs | **Ansible** (cp-ansible) |
| **Collectors** | Prometheus scraping those exporters, Grafana visualising them | **Compose** ([`../compose/`](../compose/)) |

This document covers the first half and how to connect it to the second.

---

## Before you start: this is not Control Center's Prometheus

Control Center Next Gen already ships a Prometheus, and it is easy to assume
it can serve as the platform's monitoring backend. It cannot. Its generated
configuration contains:

```yaml
scrape_configs: null
```

It scrapes nothing. Brokers and controllers **push** to it over OTLP
(`--web.enable-otlp-receiver`), it covers only those two component types, and
it exists to feed C3's own screens. Schema Registry, Connect and REST Proxy
never appear in it.

The Prometheus in [`../compose/`](../compose/) is a separate, scraping
instance that covers every component. Both run at the same time and do not
interfere — but they listen on the same default port (9090), so keep them on
different hosts or change one of them.

---

## Step 1 — Understand the port assignment

The JMX exporter ports are set **explicitly** in
[`../ansible/hosts.yml`](../ansible/hosts.yml):

| Component | This repo | cp-ansible default |
|---|---|---|
| KRaft Controller | 7071 | 8079 |
| Kafka Broker | **7072** | **8080** |
| Schema Registry | 7073 | 8078 |
| Kafka Connect | 7074 | 8077 |
| REST Proxy | 7075 | 8075 |

> **Why the broker port is not left at its default.** cp-ansible defaults the
> broker exporter to **8080** — one of the most commonly occupied ports on a
> shared host. If anything already holds it, the exporter cannot bind, and
> since the agent is loaded inside the broker JVM, the **broker itself** fails
> to start. The failure surfaces as a broker startup error with no obvious
> connection to monitoring.
>
> The 707x block avoids that collision and keeps every exporter in one
> predictable range. If you change it, change
> [`../compose/prometheus/prometheus.yml`](../compose/prometheus/prometheus.yml)
> to match — the two are not linked automatically.

Verify the range is free before enabling anything:

```bash
ansible all -i ../ansible/hosts.yml -m shell -a "ss -tlnp | grep -cE ':707[0-9]\b'"
```

Every node should report `0`.

## Step 2 — Handle the agent JAR (air-gap)

cp-ansible downloads the JMX exporter agent from Maven Central by default:

```yaml
jmxexporter_url_remote: true    # downloads jmx_prometheus_javaagent-1.0.1.jar
```

On hosts with no internet access this task fails. Fetch the JAR on a connected
machine, distribute it, and switch the flag:

```bash
# on a connected machine
curl -LO https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/1.0.1/jmx_prometheus_javaagent-1.0.1.jar

# distribute it to the path cp-ansible expects
ansible all -i ../ansible/hosts.yml -b -m file \
  -a "path=/opt/prometheus state=directory mode=0755"
ansible all -i ../ansible/hosts.yml -b -m copy \
  -a "src=jmx_prometheus_javaagent-1.0.1.jar dest=/opt/prometheus/jmx_prometheus_javaagent.jar mode=0755"
```

Then in `hosts.yml`:

```yaml
jmxexporter_url_remote: false
```

## Step 3 — Enable the exporters

In [`../ansible/hosts.yml`](../ansible/hosts.yml):

```yaml
jmxexporter_enabled: true
```

Redeploy. The agent is attached through the JVM options of each service, so
**every affected service restarts**:

```bash
cd ../ansible
ansible-playbook -i hosts.yml -e @vault.yml confluent.platform.all
```

> This is a rolling restart of the entire platform, not a config-only change.
> `deployment_strategy: rolling` keeps it safe for the broker tier, but treat
> it as a maintenance activity rather than a quick toggle.

## Step 4 — Verify the exporters

Each endpoint should return Prometheus text format:

```bash
for h in cp-node1 cp-node2 cp-node3; do
  for p in 7071 7072 7073 7074 7075; do
    printf "%-10s %s  " "$h" "$p"
    curl -s -o /dev/null -w "HTTP %{http_code}\n" "http://$h:$p/metrics"
  done
done
```

All `200`. Confirm real metrics are present, not just a live socket:

```bash
curl -s http://cp-node1:7072/metrics | grep -c '^kafka_'
```

> The exporter endpoints are **plain HTTP and unauthenticated** — the agent
> does not inherit the cluster's TLS or RBAC configuration. Keep 707x
> reachable only from your monitoring subnet. Do not expose it alongside the
> client-facing ports.

## Step 5 — Point Prometheus at them

The scrape configuration in
[`../compose/prometheus/prometheus.yml`](../compose/prometheus/prometheus.yml)
already targets these ports. Prometheus runs in a container and cannot resolve
your node names, so map them in `../compose/.env`:

```bash
CP_NODE1_NAME=cp-node1
CP_NODE1_IP=10.0.0.1
# ...
```

Start it:

```bash
cd ../compose
podman-compose --profile monitoring up -d
```

Confirm the targets turn healthy:

```bash
curl -s http://localhost:9090/api/v1/targets \
  | python3 -c "
import sys,json
for t in json.load(sys.stdin)['data']['activeTargets']:
    print(f\"{t['labels']['job']:20s} {t['labels']['instance']:20s} {t['health']}\")"
```

Every Confluent target should read `up`. If they stay `down`, work through it
in this order — each step rules out one layer:

1. `curl http://<node>:<port>/metrics` **from the host** — is the exporter up?
2. `podman exec prometheus wget -qO- http://<node>:<port>/metrics` — can the
   *container* reach it? Failure here is name resolution (`extra_hosts`) or a
   firewall.
3. Check `podman logs prometheus` for scrape errors.

## Step 6 — Grafana

```bash
# http://<host>:3000 — admin / GRAFANA_ADMIN_PASSWORD from .env
```

The Prometheus datasource is provisioned automatically. Dashboards are not
bundled; drop JSON into `../compose/grafana/dashboards/`.

---

## What this does not cover

- **Node Exporter** (CPU, memory, disk, network per VM). Not installed by
  cp-ansible or by this stack. A commented-out scrape job is left in
  `prometheus.yml` for when you add it.
- **Kubernetes metrics** (kube-state-metrics, cAdvisor) — only relevant if you
  run components on Kubernetes, which this repository does not.
- **Federation across sites.** A single Prometheus is enough for one cluster.
  Multi-site topologies typically federate per-site instances into Thanos or
  Mimir; that is out of scope here.
- **Alerting.** No alert rules or Alertmanager are configured. Note that
  Control Center Next Gen runs its **own** Alertmanager for its own alerts —
  if you add one here, give it a different port (C3's default already collides
  with the KRaft controller listener; see the main README).
