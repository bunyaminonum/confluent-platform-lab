# Testing Guide

Verification procedures for every component, organised in three tiers. Run
them in this order — each tier assumes the previous one already passed.

| Tier | Question it answers | Example |
|---|---|---|
| 1. Accessibility | Is the service up and is RBAC actually enforced? | port listening, TLS handshake, 401 without credentials |
| 2. Functional | Does it actually do its job, not just accept connections? | register a schema, produce a message, create a connector |
| 3. Resilience | Does it survive losing an instance? | kill the leader, kill a worker, kill a controller |

Tier 3 is the one most guides skip, and the one that actually matters — a
component that is "up" and a component that survives a real failure are two
different claims. Every resilience test in this directory was designed to be
run against **this repository's actual multi-instance layout** (Schema
Registry, Kafka Connect and REST Proxy on all three nodes) — not a
theoretical description of what Kafka *can* do.

| Component | Doc | Accessibility | Functional | Resilience |
|---|---|:---:|:---:|:---:|
| Kafka Broker & KRaft Controller | [kafka-broker-and-controller.md](kafka-broker-and-controller.md) | ✅ | ✅ | ✅ |
| Schema Registry | [schema-registry.md](schema-registry.md) | ✅ | ✅ | ✅ |
| Kafka Connect | [kafka-connect.md](kafka-connect.md) | ✅ | ✅ | ✅ |
| REST Proxy | [rest-proxy.md](rest-proxy.md) | ✅ | ✅ | ✅ (stateless) |
| Control Center | [control-center.md](control-center.md) | ✅ | ✅ | — (single instance, see note in that doc) |

---

## Before you start

Every doc below assumes:

1. The base installation (main [README.md](../README.md)) is complete and
   `confluent.platform.all` finished without errors.
2. You are running commands from the control node, with the cluster ID and
   MDS password available as shell variables:

```bash
export CONFLUENT_PLATFORM_USERNAME=mds CONFLUENT_PLATFORM_PASSWORD='<MDS_PW>'
confluent login --url https://cp-node1:8090 --certificate-authority-path ../pki/ca/ca.crt
CID=$(confluent cluster list -o json | python3 -c \
  "import sys,json;print(json.load(sys.stdin)[0]['scope']['clusters']['kafka-cluster'])")
MDS_PW='<MDS_PW>'
```

3. Node names follow the base inventory: `cp-node1`, `cp-node2`, `cp-node3`.
   Substitute your real hostnames throughout.

## A note on the resilience tests

These tests **stop a real systemd service** on a real node. They are safe to
run — every component here runs with at least 3 instances or tolerates one
node loss by design — but they are not read-only. Read each resilience
section fully before running it, and restart the stopped service at the end
of the test (each doc includes that step).

Do not run more than one component's resilience test at the same time, and
never stop two nodes of the same component simultaneously — that exceeds what
any of these components are designed to tolerate.
