# Testing: Schema Registry

> The resilience test in this document was run end-to-end against a real
> deployment of this repository, including the actual leader failover. The
> commands and log patterns below are what that run produced.

## Tier 1 — Accessibility

Confirm all three instances are up, share the same leader-election group, and
enforce RBAC:

```bash
for h in cp-node1 cp-node2 cp-node3; do
  echo "--- $h ---"
  ssh $h "sudo grep 'schema.registry.group.id' /etc/schema-registry/schema-registry.properties"
  curl -sk -o /dev/null -w "unauthenticated: HTTP %{http_code}\n" https://$h:8081/subjects
done
```

Expected: identical `group.id` on all three, `401` on every unauthenticated
call.

## Tier 2 — Functional: replication proof

Register a schema through one instance, read it back through the other two.
This proves all three share the same `_schemas` backing topic rather than
holding independent state:

```bash
curl -sk -u mds:$MDS_PW -X POST https://cp-node1:8081/subjects/ha-test-value/versions \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{"schema": "{\"type\":\"string\"}"}'

curl -sk -u mds:$MDS_PW https://cp-node2:8081/subjects/ha-test-value/versions/latest
curl -sk -u mds:$MDS_PW https://cp-node3:8081/subjects/ha-test-value/versions/latest
```

Both reads must return the schema registered on `cp-node1`.

## Tier 3 — Resilience: leader failover

### Identify the current leader

Schema Registry elects a leader through a Kafka-based consumer group
(`SchemaRegistryCoordinator`), not through a config setting — you have to read
it from the logs:

```bash
for h in cp-node1 cp-node2 cp-node3; do
  echo "--- $h ---"
  ssh $h "sudo grep -i 'elect' /var/log/confluent/schema-registry/schema-registry.log | tail -3"
done
```

Look for the `leaderIdentity=...,host=<name>,port=8081,...` field — **the same
host must appear in all three independent logs**. That agreement across
independently-running processes is the actual evidence; trusting a single
node's self-report is weaker.

Example of what a genuine election result looks like (this line appears
identically on every node in the group, including the leader itself):

```
Finished rebalance with leader election result: Assignment{version=1, error=0,
leader='sr-1-<uuid>', leaderIdentity=version=1,host=cp-node1,port=8081,
scheme=https,leaderEligibility=true,isLeader=false}
(io.confluent.kafka.schemaregistry.leaderelector.kafka.KafkaGroupLeaderElector:271)
```

> The `isLeader=false` field inside that log line describes a property of the
> `SchemaRegistryIdentity` value object, not "am I the leader" — ignore it. The
> `leaderIdentity=host=...` value is the one that answers the question, and
> it's what you should compare across nodes.

### Kill the leader

```bash
ssh <leader-host> "sudo systemctl stop confluent-schema-registry"
```

### Prove writes still work

Immediately attempt a **new** schema registration through a surviving node.
Leader re-election takes a few seconds — retry once or twice if the first
attempt times out:

```bash
curl -sk -u mds:$MDS_PW -X POST https://<a-surviving-node>:8081/subjects/ha-test-failover-value/versions \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{"schema": "{\"type\":\"string\"}"}'
```

A response containing an `id` means the write succeeded through the new
leader.

### Confirm the new leader was actually elected

```bash
ssh <a-surviving-node> "sudo grep -i 'elect' /var/log/confluent/schema-registry/schema-registry.log | tail -3"
ssh <the-other-surviving-node> "sudo grep -i 'elect' /var/log/confluent/schema-registry/schema-registry.log | tail -3"
```

Both surviving nodes must now report the **same new** `leaderIdentity=host=...`
— and it must be one of the two survivors, not the node you stopped.

### Bring the stopped node back

```bash
ssh <the-stopped-node> "sudo systemctl start confluent-schema-registry"
sleep 15
curl -sk -u mds:$MDS_PW https://<the-stopped-node>:8081/subjects/ha-test-failover-value/versions/latest
```

The rejoined node must be able to read the schema that was registered while it
was down — proof it caught up from the `_schemas` topic rather than starting
with stale state.

---

## Cleanup

```bash
curl -sk -u mds:$MDS_PW -X DELETE https://cp-node1:8081/subjects/ha-test-value
curl -sk -u mds:$MDS_PW -X DELETE https://cp-node1:8081/subjects/ha-test-failover-value
```
