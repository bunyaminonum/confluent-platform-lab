# Testing: REST Proxy

## Tier 1 — Accessibility

```bash
for h in cp-node1 cp-node2 cp-node3; do
  echo "--- $h ---"
  curl -sk -o /dev/null -w "unauthenticated: HTTP %{http_code}\n" https://$h:8082/v3/clusters
done
```

Expected: `401` on every node.

## Tier 2 — Functional: produce through REST, verify by reading directly from the broker

This is the strongest proof that REST Proxy actually works, because it never
touches REST Proxy again after the write — if the message only *looked*
written but wasn't, this catches it.

```bash
curl -sk -u mds:$MDS_PW -X POST "https://cp-node1:8082/v3/clusters/$CID/topics" \
  -H "Content-Type: application/json" \
  -d '{"topic_name":"rest-proxy-ha-test","partitions_count":3,"replication_factor":3}'

curl -sk -u mds:$MDS_PW -X POST \
  "https://cp-node1:8082/v3/clusters/$CID/topics/rest-proxy-ha-test/records" \
  -H "Content-Type: application/json" \
  -d '{"key":{"type":"STRING","data":"k1"},"value":{"type":"STRING","data":"hello"}}'
```

The response carries a real `partition_id` and `offset` assigned by the
broker. Now read it back **bypassing REST Proxy entirely**:

```bash
ssh cp-node1 'sudo bash -c "cat > /tmp/oauth-client.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=OAUTHBEARER
sasl.login.callback.handler.class=io.confluent.kafka.clients.plugins.auth.token.TokenUserLoginCallbackHandler
sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required username=\"mds\" password=\"'$MDS_PW'\" metadataServerUrls=\"https://cp-node1:8090\";
ssl.truststore.location=/var/ssl/private/kafka_broker.truststore.jks
ssl.truststore.password=confluenttruststorepass
EOF
kafka-console-consumer --bootstrap-server cp-node1:9092 --topic rest-proxy-ha-test \
  --from-beginning --max-messages 1 --property print.key=true \
  --consumer.config /tmp/oauth-client.properties
rm -f /tmp/oauth-client.properties"'
```

Must print `k1  hello`.

> Run this `sudo`, not as a plain user — `cloud-user` cannot read
> `/var/ssl/private/kafka_broker.truststore.jks`, and the resulting error
> (`AccessDeniedException` buried at the bottom of a long stack trace) looks
> like a configuration problem when it is really a file-permission one.

## Tier 3 — Resilience: instance loss

REST Proxy is stateless — it holds no cluster metadata of its own and
coordinates with nothing. There is no leader to fail over. The test is
correspondingly simple:

### Confirm all three answer identically before touching anything

```bash
for h in cp-node1 cp-node2 cp-node3; do
  curl -sk -u mds:$MDS_PW "https://$h:8082/v3/clusters/$CID/topics/rest-proxy-ha-test/partitions/0"
done
```

All three must return the same partition metadata — they are three doors into
the same cluster, not three separate systems.

### Kill one instance

```bash
ssh cp-node2 "sudo systemctl stop confluent-kafka-rest"
```

### Confirm the other two are completely unaffected

```bash
curl -sk -u mds:$MDS_PW -X POST \
  "https://cp-node3:8082/v3/clusters/$CID/topics/rest-proxy-ha-test/records" \
  -H "Content-Type: application/json" \
  -d '{"key":{"type":"STRING","data":"k2"},"value":{"type":"STRING","data":"still working"}}'
```

Should succeed immediately, with no delay — unlike Schema Registry or Connect,
there is no rebalance to wait for, because there was never any shared state to
rebalance.

### Restart it

```bash
ssh cp-node2 "sudo systemctl start confluent-kafka-rest"
```

---

## Be honest about what this proves and what it doesn't

This tier shows that **the cluster** tolerates losing a REST Proxy instance.
It does **not** show that a specific client application does. A client
hardcoded to `https://cp-node2:8082` has no way to know `cp-node1` and
`cp-node3` exist, and will fail the moment `cp-node2` goes down. Real
client-side high availability requires either:

- a load balancer in front of all three instances, or
- a client library configured with multiple REST Proxy URLs and its own
  failover logic.

Neither is part of this repository — the resilience this tier demonstrates is
in the *server fleet*, not in any particular integration pointed at it.

---

## Cleanup

```bash
curl -sk -u mds:$MDS_PW -X DELETE "https://cp-node1:8082/v3/clusters/$CID/topics/rest-proxy-ha-test"
```
