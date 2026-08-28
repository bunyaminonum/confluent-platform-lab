# Supporting Services (Compose)

The services the Confluent cluster **depends on** or that **observe** it:
directory, secrets vault, metrics.

> **Confluent Platform itself is not here.** Brokers, controllers, Schema
> Registry, Kafka Connect, REST Proxy and Control Center are deployed onto VMs
> with **Ansible** — see the [main README](../README.md). This stack exists so
> the surrounding infrastructure is reproducible with one command instead of a
> page of `podman run` invocations. Keep that boundary: adding Confluent
> components here would fork the deployment story into two competing tools.

## Profiles

Nothing starts unless you ask for it:

| Profile | Services | When you need it |
|---|---|---|
| `ldap` | OpenLDAP | **Required** — backs RBAC/MDS |
| `conjur` | Conjur database, server, nginx proxy, CLI | Optional — see [`../secrets/cyberark-conjur/`](../secrets/cyberark-conjur/) |
| `monitoring` | Prometheus, Grafana | Optional — see [`../monitoring/`](../monitoring/) |

## Quick start

```bash
cd compose
cp .env.example .env      # then fill it in — every password is required
podman-compose --profile ldap up -d
```

Add profiles as you need them; they compose:

```bash
podman-compose --profile ldap --profile monitoring up -d
podman-compose --profile ldap --profile conjur --profile monitoring up -d
```

`docker compose` works identically — substitute the command.

> Every password in `.env` is declared with `:?` in the compose file, so a
> missing value fails immediately with a named error instead of silently
> starting a container with an empty password.

## Ports

| Service | Host port | Notes |
|---|---|---|
| OpenLDAP | 1389, 1636 | Unprivileged; rootless podman cannot bind 389/636 |
| Conjur proxy | 8443 | Only the proxy is exposed; server and database stay on the internal network |
| Prometheus | 9090 | |
| Grafana | 3000 | |

## Monitoring notes

**Prometheus cannot resolve your node names.** It runs in a container and does
not inherit the host's `/etc/hosts`, so the `CP_NODE*_NAME` / `CP_NODE*_IP`
pairs in `.env` are injected as `extra_hosts`. Use the same names as
`inventory_hostname` in [`../ansible/hosts.yml`](../ansible/hosts.yml), or the
scrape targets will never resolve.

**This is not Control Center's Prometheus.** Control Center Next Gen ships its
own Prometheus, which is push-based (OTLP), covers only brokers and
controllers, and exists purely to feed C3's dashboards — its config literally
contains `scrape_configs: null`. The instance here scrapes every component
over JMX. The two coexist and do not interfere.

**Targets will show `down` until you enable the exporters.** That is expected,
not a misconfiguration — [`../monitoring/README.md`](../monitoring/README.md)
covers turning them on. To confirm the scrape machinery itself is working
before then, check the self-scrape target:

```bash
curl -s --get "http://localhost:9090/api/v1/query" --data-urlencode 'query=up{job="prometheus"}'
```

A value of `1` means Prometheus is genuinely scraping.

## Conjur notes

Conjur needs a TLS certificate for its nginx proxy before first start:

```bash
mkdir -p tls
openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
  -keyout tls/conjur.key -out tls/conjur.crt \
  -subj "/CN=cp-node1" -addext "subjectAltName=DNS:cp-node1"
```

Account creation, policy loading and API keys are covered in
[`../secrets/cyberark-conjur/README.md`](../secrets/cyberark-conjur/README.md).

> The upstream Conjur quickstart runs its database with no persistent volume,
> so a `down` wipes every secret. A named volume (`conjur-db-data`) is attached
> here to avoid that. **`down -v` still destroys it** — that flag removes
> volumes.

## Persistence

Named volumes survive `down` and restarts: `openldap-data`, `openldap-config`,
`conjur-db-data`, `prometheus-data`, `grafana-data`.

All services carry `restart: always`. Under podman that policy only takes
effect across a host reboot if the bundled systemd unit is enabled — podman
has no persistent daemon to enforce it:

```bash
sudo systemctl enable --now podman-restart.service
```

Skipping this is a genuine failure mode: after a reboot the containers stay
down, and because the brokers resolve their secrets from Conjur at startup,
the Kafka cluster fails to come up with an error that points at Kafka rather
than at the missing vault.

## Operations

```bash
podman-compose --profile ldap --profile monitoring ps
podman-compose logs -f prometheus
podman-compose --profile monitoring restart prometheus

# reload Prometheus config without a restart (--web.enable-lifecycle is set)
curl -X POST http://localhost:9090/-/reload

podman-compose --profile ldap --profile monitoring down     # keeps volumes
podman-compose --profile ldap --profile monitoring down -v  # DESTROYS data
```

## Grafana dashboards

The Prometheus datasource is provisioned automatically. Dashboards are not
bundled — drop JSON files into `grafana/dashboards/` and they load within
30 seconds. Confluent publishes a community dashboard set for these JMX
exporter metrics.
