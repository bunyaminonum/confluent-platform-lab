# Testing: Kafka Broker & KRaft Controller

Two independent failure domains live here, and they need separate tests:
**data availability** (can you still produce/consume if a broker dies) and
**metadata availability** (can the cluster still make decisions if a
controller dies). A healthy broker layer with a dead controller quorum looks
fine until you try to create a topic.

## Tier 1 — Accessibility

```bash
for h in cp-node1 cp-node2 cp-node3; do
  echo "--- $h broker TLS ---"
  openssl s_client -connect $h:9092 -CAfile ../pki/ca/ca.crt </dev/null 2>&1 | grep "Verify return code"
done
```

Expected: `Verify return code: 0 (ok)` on all three.

## Tier 2 — Functional: produce and consume

```bash
curl -sk -u mds:$MDS_PW -X POST "https://cp-node1:8082/v3/clusters/$CID/topics" \
  -H "Content-Type: application/json" \
  -d '{"topic_name":"broker-ha-test","partitions_count":3,"replication_factor":3}'
```

Reuse the OAUTHBEARER client config pattern to talk to the broker directly
(see [rest-proxy.md](rest-proxy.md) Tier 2 for the full file), then:

```bash
ssh cp-node1 'kafka-console-producer --bootstrap-server cp-node1:9092 \
  --topic broker-ha-test --producer.config /tmp/oauth-client.properties <<< "hello broker"'
```

## Tier 3a — Resilience: broker leader failover

### Find the current partition leader

```bash
ssh cp-node1 'kafka-topics --bootstrap-server cp-node1:9092 --command-config /tmp/oauth-client.properties \
  --describe --topic broker-ha-test'
```

The output lists `Leader`, `Replicas` and `Isr` per partition. Pick any
partition and note its leader broker ID.

### Kill that broker

```bash
ssh <the-leader-node> "sudo systemctl stop confluent-server"
```

### Confirm a new leader was elected and the topic is still usable

```bash
ssh <a-surviving-node> 'kafka-topics --bootstrap-server <a-surviving-node>:9092 --command-config /tmp/oauth-client.properties \
  --describe --topic broker-ha-test'
```

The `Isr` column should shrink by one (the stopped broker drops out), and the
`Leader` for the affected partition should now point at a surviving broker.
Produce and consume again through a survivor to confirm the topic is fully
usable, not just "described successfully":

```bash
ssh <a-surviving-node> 'kafka-console-producer --bootstrap-server <a-surviving-node>:9092 \
  --producer.config /tmp/oauth-client.properties --topic broker-ha-test <<< "still working"'
```

### Bring the broker back

```bash
ssh <the-stopped-node> "sudo systemctl start confluent-server"
sleep 20
ssh <the-stopped-node> 'kafka-topics --bootstrap-server <the-stopped-node>:9092 --command-config /tmp/oauth-client.properties \
  --describe --topic broker-ha-test'
```

The `Isr` column should grow back to include the returning broker once it has
caught up.

## Tier 3b — Resilience: controller quorum tolerance

This is the test most guides skip entirely, and the one that actually decides
whether your cluster can survive a real incident: **the controller quorum in
this repository is static** (`controller.quorum.voters`, not the dynamic
KIP-853 mechanism — see the main README's "Out of scope" section). A 3-node
static quorum tolerates exactly **one** controller failure. Losing a second
one loses the ability to make any metadata decision — no new topics, no
partition reassignment, no leader elections — until a manual recovery
procedure is run. Confirming the *one-failure* case is safe and worthwhile;
deliberately testing the *two-failure* case on this repository is not, because
recovering from it is a manual procedure this repository does not implement.

### Get a Kerberos ticket

The controller listener authenticates with Kerberos, not the OAUTHBEARER
token used everywhere else — this is the same distinction the main README
calls out for `auth_mode: ldap` only covering the client-facing listener.
Reusing a broker's own keytab works, since that identity already has whatever
authorization it needs to talk to controllers as part of normal operation:

```bash
ssh cp-node1 "kinit -kt ../pki/keytabs/cp-node1-kafka_broker.keytab kafka/cp-node1.lab.local@LAB.LOCAL && klist"

ssh cp-node1 'cat > /tmp/kerberos-admin.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=GSSAPI
sasl.kerberos.service.name=kafka
sasl.jaas.config=com.sun.security.auth.module.Krb5LoginModule required useTicketCache=true;
ssl.truststore.location=/var/ssl/private/kafka_broker.truststore.jks
ssl.truststore.password=confluenttruststorepass
EOF'
```

### Check quorum health

```bash
ssh cp-node1 'kafka-metadata-quorum.sh --bootstrap-controller cp-node1:9093 \
  --command-config /tmp/kerberos-admin.properties describe --status'
```

Note the current leader and the three voter IDs.

### Stop exactly one controller

```bash
ssh <a-non-leader-controller-node> "sudo systemctl stop confluent-kcontroller"
```

### Confirm the quorum still functions

```bash
ssh cp-node1 'kafka-metadata-quorum.sh --bootstrap-controller <a-surviving-node>:9093 \
  --command-config /tmp/kerberos-admin.properties describe --status'
```

Then prove it in practice, not just in the status output — create a topic
through a surviving broker:

```bash
curl -sk -u mds:$MDS_PW -X POST "https://<a-surviving-node>:8082/v3/clusters/$CID/topics" \
  -H "Content-Type: application/json" \
  -d '{"topic_name":"quorum-survives-test","partitions_count":1,"replication_factor":1}'
```

Success confirms the two remaining controllers still hold a majority (2 of 3)
and the cluster can still make metadata decisions.

### Bring the controller back

```bash
ssh <the-stopped-node> "sudo systemctl start confluent-kcontroller"
```

> **Do not stop a second controller on top of this one.** With only one
> voter left there is no majority, metadata operations stop entirely, and
> recovering requires Confluent's documented multi-region KRaft disaster
> recovery procedure — well outside what this repository sets up. If you need
> to actually validate that recovery path, do it as a deliberate, separate
> exercise with a snapshot or a disposable environment, not on a running lab.

---

## Cleanup

```bash
curl -sk -u mds:$MDS_PW -X DELETE "https://cp-node1:8082/v3/clusters/$CID/topics/broker-ha-test"
curl -sk -u mds:$MDS_PW -X DELETE "https://cp-node1:8082/v3/clusters/$CID/topics/quorum-survives-test"
ssh cp-node1 "rm -f /tmp/oauth-client.properties /tmp/kerberos-admin.properties; kdestroy"
```
