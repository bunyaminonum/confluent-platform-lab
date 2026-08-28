# Secret Externalization with FileConfigProvider

Moves passwords out of `server.properties` into a separate file with tightened
permissions. Requires no additional dependencies — `FileConfigProvider` ships
with Apache Kafka.

**Prerequisite:** the base installation from the main README must be complete
and the cluster running.

---

## How it works

```properties
# before:
ssl.keystore.password=confluentkeystorestorepass

# after:
ssl.keystore.password=${file:/etc/kafka/secrets/broker.properties:keystore.password}
```

The broker resolves the `${file:...}` reference at startup and reads the actual
value from that file. `server.properties` can stay world-readable; the password
now lives in a mode-640 file.

`allowed.paths` is a security boundary — the provider may only read files from
that directory.

---

## Step 1 — Create the secret files

On every broker node:

```bash
sudo mkdir -p /etc/kafka/secrets
sudo tee /etc/kafka/secrets/broker.properties >/dev/null <<'EOF'
keystore.password=confluentkeystorestorepass
truststore.password=confluenttruststorepass
ldap.bind.password=<LDAP_BIND_PASSWORD>
EOF
sudo chown root:confluent /etc/kafka/secrets/broker.properties
sudo chmod 640 /etc/kafka/secrets/broker.properties
```

> **The `keystore.password` value is fixed and cannot be chosen freely.**
> cp-ansible builds the keystores with `keytool` using its own default password
> (`confluentkeystorestorepass`). Put a different value here and the broker
> cannot open the keystore, failing with `Keystore was tampered with, or
> password was incorrect`. To genuinely change it you must also set
> cp-ansible's `ssl_keystore_store_password` to the same value and have the
> keystores regenerated.

On Schema Registry nodes (all three, if SR runs everywhere):

```bash
sudo mkdir -p /etc/schema-registry/secrets
sudo tee /etc/schema-registry/secrets/sr.properties >/dev/null <<'EOF'
keystore.password=confluentkeystorestorepass
truststore.password=confluenttruststorepass
kafkastore.password=<SVC_KAFKA_SCHEMAREGISTRY_LDAP_PASSWORD>
EOF
sudo chown root:confluent /etc/schema-registry/secrets/sr.properties
sudo chmod 640 /etc/schema-registry/secrets/sr.properties
```

To distribute these with Ansible instead, `distribute-secrets.yml` automates
the whole step:

```bash
cd /opt/confluent-platform-lab/ansible
ansible-playbook -i hosts.yml -e @vault.yml \
  ../secrets/file-configprovider/distribute-secrets.yml
```

## Step 2 — Add the blocks to the inventory

Add the following at the **top** of the **`kafka_broker_custom_properties`**
block in `ansible/hosts.yml`, before the existing `ldap.*` lines:

```yaml
      config.providers: file
      config.providers.file.class: org.apache.kafka.common.config.provider.FileConfigProvider
      config.providers.file.param.allowed.paths: /etc/kafka/secrets
      ssl.key.password: "${file:/etc/kafka/secrets/broker.properties:keystore.password}"
      ssl.keystore.password: "${file:/etc/kafka/secrets/broker.properties:keystore.password}"
      ssl.truststore.password: "${file:/etc/kafka/secrets/broker.properties:truststore.password}"
      confluent.metadata.server.ssl.key.password: "${file:/etc/kafka/secrets/broker.properties:keystore.password}"
      confluent.metadata.server.ssl.keystore.password: "${file:/etc/kafka/secrets/broker.properties:keystore.password}"
      confluent.metadata.server.ssl.truststore.password: "${file:/etc/kafka/secrets/broker.properties:truststore.password}"
      kafka.rest.client.ssl.truststore.password: "${file:/etc/kafka/secrets/broker.properties:truststore.password}"
      kafka.rest.confluent.metadata.ssl.truststore.password: "${file:/etc/kafka/secrets/broker.properties:truststore.password}"
      listener.name.broker.ssl.key.password: "${file:/etc/kafka/secrets/broker.properties:keystore.password}"
      listener.name.broker.ssl.keystore.password: "${file:/etc/kafka/secrets/broker.properties:keystore.password}"
      listener.name.broker.ssl.truststore.password: "${file:/etc/kafka/secrets/broker.properties:truststore.password}"
      listener.name.controller.ssl.key.password: "${file:/etc/kafka/secrets/broker.properties:keystore.password}"
      listener.name.controller.ssl.keystore.password: "${file:/etc/kafka/secrets/broker.properties:keystore.password}"
      listener.name.controller.ssl.truststore.password: "${file:/etc/kafka/secrets/broker.properties:truststore.password}"
      listener.name.internal.ssl.key.password: "${file:/etc/kafka/secrets/broker.properties:keystore.password}"
      listener.name.internal.ssl.keystore.password: "${file:/etc/kafka/secrets/broker.properties:keystore.password}"
      listener.name.internal.ssl.truststore.password: "${file:/etc/kafka/secrets/broker.properties:truststore.password}"
```

In the same block, replace the **`ldap.java.naming.security.credentials`** line:

```yaml
      # was: "{{ vault_ldap_bind_password }}"
      ldap.java.naming.security.credentials: "${file:/etc/kafka/secrets/broker.properties:ldap.bind.password}"
```

For Schema Registry, add a **new** block under `all: vars:`:

```yaml
    schema_registry_custom_properties:
      config.providers: file
      config.providers.file.class: org.apache.kafka.common.config.provider.FileConfigProvider
      config.providers.file.param.allowed.paths: /etc/schema-registry/secrets
      ssl.key.password: "${file:/etc/schema-registry/secrets/sr.properties:keystore.password}"
      ssl.keystore.password: "${file:/etc/schema-registry/secrets/sr.properties:keystore.password}"
      ssl.truststore.password: "${file:/etc/schema-registry/secrets/sr.properties:truststore.password}"
      confluent.metadata.ssl.truststore.password: "${file:/etc/schema-registry/secrets/sr.properties:truststore.password}"
      kafkastore.ssl.truststore.password: "${file:/etc/schema-registry/secrets/sr.properties:truststore.password}"
      kafkastore.sasl.jaas.config: >-
        org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required
        username="svc-kafka-schemaregistry"
        password="${file:/etc/schema-registry/secrets/sr.properties:kafkastore.password}"
        metadataServerUrls="{{ groups['kafka_broker'] | map('regex_replace', '^(.*)$', 'https://\1:8090') | join(',') }}";
```

Ready to copy: [`hosts-overlay.yml`](hosts-overlay.yml)

## Step 3 — Redeploy

```bash
cd /opt/confluent-platform-lab/ansible
ansible-playbook -i hosts.yml -e @vault.yml confluent.platform.all
```

## Step 4 — Verify

No plaintext passwords should remain in the configuration:

```bash
ansible kafka_broker -i hosts.yml -b -m shell -a \
  'grep -iE "password=|credentials=" /etc/kafka/server.properties | grep -v "\${file:" | wc -l'
```

Every node must report `0`. Services must be healthy:

```bash
ansible all -i hosts.yml -b -m shell -a \
  'systemctl is-active confluent-server confluent-schema-registry'
openssl s_client -connect cp-node1:9092 -CAfile ../pki/ca/ca.crt </dev/null 2>&1 \
  | grep "Verify return code"
```

> If a service refuses to start, check the **key part** of the reference: in
> `${file:<path>:<key>}` the key must match the left-hand side of the line in
> the file exactly. A typo does not report "no such key" — the value resolves
> to empty and the keystore fails to open.

---

## Extending

**Controller.** It uses its own file, `/etc/controller/server.properties`. Add
the same pattern to the `vars:` block of the `kafka_controller:` group,
changing only the paths:

```yaml
kafka_controller:
  vars:
    kafka_controller_custom_properties:
      config.providers: file
      config.providers.file.class: org.apache.kafka.common.config.provider.FileConfigProvider
      config.providers.file.param.allowed.paths: /etc/controller/secrets
      ssl.key.password: "${file:/etc/controller/secrets/controller.properties:keystore.password}"
      ssl.keystore.password: "${file:/etc/controller/secrets/controller.properties:keystore.password}"
      ssl.truststore.password: "${file:/etc/controller/secrets/controller.properties:truststore.password}"
      confluent.metadata.ssl.truststore.password: "${file:/etc/controller/secrets/controller.properties:truststore.password}"
      listener.name.broker.ssl.key.password: "${file:/etc/controller/secrets/controller.properties:keystore.password}"
      listener.name.broker.ssl.keystore.password: "${file:/etc/controller/secrets/controller.properties:keystore.password}"
      listener.name.broker.ssl.truststore.password: "${file:/etc/controller/secrets/controller.properties:truststore.password}"
      listener.name.controller.ssl.key.password: "${file:/etc/controller/secrets/controller.properties:keystore.password}"
      listener.name.controller.ssl.keystore.password: "${file:/etc/controller/secrets/controller.properties:keystore.password}"
      listener.name.controller.ssl.truststore.password: "${file:/etc/controller/secrets/controller.properties:truststore.password}"
```

Remember to create `/etc/controller/secrets/controller.properties` owned by
`root:confluent` with mode 640.

**Connect / REST Proxy / Control Center.** Same pattern; only the directory and
the `<component>_custom_properties` variable name change.
