# Testing: Control Center

## Tier 1 — Accessibility

```bash
curl -sk -o /dev/null -w "unauthenticated: HTTP %{http_code}\n" https://cp-node3:9021/2.0/clusters/kafka
```

Expected: `401`.

If you are testing from a browser rather than curl and see
`HTTP ERROR 400 Invalid SNI`, that is a certificate-scope issue, not a network
one — see the main README's TLS section.

## Tier 2 — Functional: Control Center actually sees every component

Logging in and seeing **"All clusters (0)"** is not a bug — it is a missing
role binding, covered in the main README's [UI access and RBAC](../README.md#5-ui-access-and-rbac)
section. Assuming those bindings are in place, verify Control Center's own
API reports every component correctly rather than trusting the UI alone:

```bash
TOKEN=$(curl -sk -u mds:$MDS_PW https://cp-node1:8090/security/1.0/authenticate \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['auth_token'])")

for c in kafka schema-registry connect; do
  echo "--- $c ---"
  curl -sk -H "Authorization: Bearer $TOKEN" "https://cp-node3:9021/2.0/clusters/$c"
done
```

Each must return a non-empty JSON array. An empty `[]` for a component that is
otherwise healthy almost always means Control Center was deployed **before**
that component — see the main README's "Redeploy Control Center after adding a
component" note.

```bash
curl -sk -H "Authorization: Bearer $TOKEN" https://cp-node3:9021/2.0/health/status
```

Should report a healthy overall status.

## Tier 3 — Resilience: there isn't any, by design of this repository

This repository runs a **single** Control Center instance. There is no
failover test to run here, and pretending otherwise would misrepresent what
was actually built. If `cp-node3` goes down, Control Center goes down with it
— the Kafka cluster itself is unaffected (C3 is an observer/management plane,
not part of the data path), but nobody can use the UI or its REST API until
it comes back.

If you need Control Center itself to be highly available, the shape of the
solution is:

- a **second** Control Center instance pointed at the same internal command
  topics (`confluent.controlcenter.internal.topics.replication` already makes
  those topics replicated — that is not the gap),
- something in front of both instances deciding which one is currently active
  (Control Center does not natively coordinate two instances into an
  active/standby pair the way Schema Registry or Connect coordinate their own
  peers),
- and a load balancer or DNS failover pointing users at whichever instance is
  active.

None of that exists in this repository. If you build it, the two things worth
testing afterward are the same as everywhere else in this guide: can a client
still reach a working instance after the active one dies, and does the
standby actually see the same data (verified by comparing `/2.0/health/status`
and cluster lists from both instances, the same way [schema-registry.md](schema-registry.md)
Tier 2 verifies replication).
