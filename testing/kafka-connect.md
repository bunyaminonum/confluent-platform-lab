# Testing: Kafka Connect

## Tier 1 — Accessibility

```bash
for h in cp-node1 cp-node2 cp-node3; do
  echo "--- $h ---"
  curl -sk -o /dev/null -w "unauthenticated: HTTP %{http_code}\n" https://$h:8083/connectors
done
```

Expected: `401` on every node.

## Tier 2 — Functional: a real running connector

This test uses `FileStreamSourceConnector`. Despite its reputation for
"shipping with Kafka core," on this package-based install its JAR lives
outside cp-ansible's default `plugin.path` — Confluent isolates file
connectors (arbitrary host file read/write) behind an explicit opt-in. This
repository's `ansible/hosts.yml` already adds the directory via
`kafka_connect_plugins_path` (see "FileStreamSourceConnector needs an explicit
plugin path" in the main README); if you removed that override, list plugins
first to confirm it is actually loaded:

```bash
curl -sk -u mds:$MDS_PW https://cp-node1:8083/connector-plugins | grep -i filestream
```

Since this repository disables `auto.create.topics.enable`, create the target
topic first:

```bash
curl -sk -u mds:$MDS_PW -X POST "https://cp-node1:8082/v3/clusters/$CID/topics" \
  -H "Content-Type: application/json" \
  -d '{"topic_name":"connect-ha-test","partitions_count":3,"replication_factor":3}'
```

Create a source file on the node that will run the connector, then start it
through any of the three Connect REST endpoints:

```bash
ssh cp-node1 "echo 'connect resilience test' | sudo tee /tmp/connect-ha-test-input.txt"

curl -sk -u mds:$MDS_PW -X POST https://cp-node1:8083/connectors \
  -H "Content-Type: application/json" \
  -d '{
    "name": "ha-test-source",
    "config": {
      "connector.class": "org.apache.kafka.connect.file.FileStreamSourceConnector",
      "tasks.max": "1",
      "file": "/tmp/connect-ha-test-input.txt",
      "topic": "connect-ha-test"
    }
  }'
```

Confirm it is visible through **every** worker — proof the three form one
distributed group backed by the shared `connect-cluster-configs` /
`connect-cluster-offsets` / `connect-cluster-status` topics, not three
independent standalone workers:

```bash
curl -sk -u mds:$MDS_PW https://cp-node2:8083/connectors
curl -sk -u mds:$MDS_PW https://cp-node3:8083/connectors
```

Both must list `ha-test-source`.

Confirm the data actually moved:

```bash
curl -sk -u mds:$MDS_PW "https://cp-node1:8082/v3/clusters/$CID/topics/connect-ha-test/partitions/0"
```

## Tier 3 — Resilience: task failover on worker loss

### Find which worker is currently running the task

```bash
curl -sk -u mds:$MDS_PW https://cp-node1:8083/connectors/ha-test-source/status
```

The response includes a `"worker_id"` field for the connector and for each
task, in `host:port` form. That is the worker to kill.

### Kill that worker

```bash
ssh <that-worker-host> "sudo systemctl stop confluent-kafka-connect"
```

### Confirm the task moved to a surviving worker

Kafka Connect detects the failure through the consumer group's
`session.timeout.ms` and rebalances automatically — allow a few seconds, then
check status from a survivor:

```bash
curl -sk -u mds:$MDS_PW https://<a-surviving-worker>:8083/connectors/ha-test-source/status
```

The `worker_id` for the task must now point at one of the two survivors, and
`state` must be `RUNNING` — not `FAILED` or `UNASSIGNED`.

> If the task shows `state: FAILED`, check
> `"trace"` in the same response before assuming the rebalance itself failed —
> a task can legitimately fail for reasons unrelated to worker loss (e.g. the
> source file being unreadable by the new worker). This test only verifies
> that Connect *attempts* the reassignment, not that every connector type
> survives a host change unconditionally.

### Bring the stopped worker back

```bash
ssh <the-stopped-worker> "sudo systemctl start confluent-kafka-connect"
sleep 10
curl -sk -u mds:$MDS_PW https://<the-stopped-worker>:8083/connectors
```

Should list `ha-test-source` again, confirming the worker rejoined the group.

---

## Cleanup

```bash
curl -sk -u mds:$MDS_PW -X DELETE https://cp-node1:8083/connectors/ha-test-source
curl -sk -u mds:$MDS_PW -X DELETE "https://cp-node1:8082/v3/clusters/$CID/topics/connect-ha-test"
ssh cp-node1 "sudo rm -f /tmp/connect-ha-test-input.txt"
```
