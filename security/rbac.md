# RBAC on Confluent Platform — a working guide

This guide explains Confluent Platform's role-based access control from first
principles, then shows how to run it in production: how to model service
accounts, which roles to grant, how to avoid a binding per topic, and how to
read the errors when something is denied.

It is written against this repository's cluster (`cp-lab`, three nodes, RBAC
with an LDAP directory) and every command is runnable as-is. Substitute your own
names where they differ.

**Read [§1](#1-the-four-building-blocks) and [§2](#2-authorization-happens-in-more-than-one-place)
before anything else.** Most RBAC confusion is not about syntax; it is about not
knowing which of several independent gates rejected the request.

---

## Contents

1. [The four building blocks](#1-the-four-building-blocks)
2. [Authorization happens in more than one place](#2-authorization-happens-in-more-than-one-place)
3. [Scopes: why SystemAdmin is not enough](#3-scopes-why-systemadmin-is-not-enough)
4. [The roles, and which to pick](#4-the-roles-and-which-to-pick)
5. [Prefixes: one binding instead of a hundred](#5-prefixes-one-binding-instead-of-a-hundred)
6. [Service accounts](#6-service-accounts)
7. [RBAC and ACLs together](#7-rbac-and-acls-together)
8. [Walkthrough: a connector with its own identity](#8-walkthrough-a-connector-with-its-own-identity)
9. [Reading a denial](#9-reading-a-denial)
10. [Production checklist](#10-production-checklist)

---

## 1. The four building blocks

RBAC has exactly four moving parts. Everything else is detail.

A **principal** is who is asking. It is written `User:alice`,
`User:svc-kafka-connect`, or `Group:kafka-developers`. In this repository
principals come from LDAP: the MDS binds to the directory, authenticates the
name and password, and the resulting identity becomes the principal.

A **resource** is what is being touched — a topic, a consumer group, a Schema
Registry subject, a connector, or a whole cluster. It is written
`Topic:orders`, `Group:orders-consumers`, `Subject:orders-value`,
`Connector:orders-source`.

A **role** is a named bundle of permissions: `DeveloperRead`, `DeveloperWrite`,
`ResourceOwner`, `SystemAdmin`, and a handful of others. You cannot invent new
ones; you pick from the predefined set.

A **role binding** ties the three together and is the only thing you actually
create:

> **principal** + **role** + **resource** + **scope** = role binding

Read a binding as an English sentence and it is always obvious what it does:

```bash
confluent iam rbac role-binding create \
  --principal User:svc-orders \
  --role DeveloperWrite \
  --resource Topic:orders \
  --kafka-cluster "$CID"
```

*"Let `svc-orders` write to the topic `orders` on this Kafka cluster."*

The bindings themselves live in the **Metadata Service (MDS)** — the component
listening on port 8090 on every broker. MDS is the system of record: it
authenticates principals against LDAP, stores every binding, and answers the
"may this principal do this?" questions that the other components ask. Nothing
about RBAC is stored in your Ansible inventory or in a properties file, which
has a practical consequence worth internalising early: **role bindings are
runtime state, not configuration.** Rebuild the cluster from scratch and the
bindings do not come back with it.

---

## 2. Authorization happens in more than one place

This is the single most useful thing to understand, and the reason RBAC
problems feel like whack-a-mole.

A connector producing Avro data to a topic passes through **three independent
gates**, in this order:

```
                                         ┌─────────────────────────┐
  ① authenticate to Schema Registry ───► │  who are you?           │  401 if silent
                                         └─────────────────────────┘
                                                    │
                                         ┌─────────────────────────┐
  ② register the schema             ───► │  may you write Subject? │  403 if unbound
                                         └─────────────────────────┘
                                                    │
                                         ┌─────────────────────────┐
  ③ produce the record              ───► │  may you write Topic?   │  TopicAuthorizationException
                                         └─────────────────────────┘
```

They are enforced by different components, they fail with different errors, and
fixing one simply reveals the next. If you fix gate ① and the job still fails,
that is not a sign the fix was wrong — it is a sign it worked.

Gate ① is **authentication**, not authorization, and it is a common source of
lost hours. Having TLS configured is not the same as having credentials. TLS
encrypts the connection and lets the client verify the *server*; it says
nothing about who the *client* is unless mutual TLS is in play. A converter
with `schema.registry.url` and a full set of `schema.registry.ssl.*` properties
but no `basic.auth.user.info` connects successfully and is then treated as
anonymous.

Gates ② and ③ are authorization, and both are RBAC — but they are checked
against *different scopes*, which is the subject of the next section.

---

## 3. Scopes: why SystemAdmin is not enough

A scope answers "on which cluster does this binding apply?" Confluent's scopes
are hierarchical in shape but **not inherited** in effect.

The Kafka cluster is the root. Schema Registry, Connect and ksqlDB each hang off
it as their own scope, identified by the cluster ID plus a component ID:

```
kafka-cluster: akd6s5ClRHC9wwfPscyakg          ← --kafka-cluster
├── schema-registry-cluster: schema-registry   ← --schema-registry-cluster
├── connect-cluster: connect-cluster           ← --connect-cluster
└── ksql-cluster: ...                          ← --ksql-cluster
```

Every binding names the Kafka cluster, and a binding for a component resource
names the component too. So a Schema Registry binding carries **both** flags:

```bash
confluent iam rbac role-binding create \
  --principal User:svc-orders --role DeveloperWrite \
  --kafka-cluster "$CID" \
  --schema-registry-cluster schema-registry \
  --resource Subject:orders-value
```

Here is the part that surprises people: **`SystemAdmin` on the Kafka cluster
grants nothing on Schema Registry or Connect.** Each component scope is
evaluated separately. A principal can be an all-powerful Kafka administrator
and still be refused when it tries to register a schema. This is deliberate —
it lets you delegate Kafka administration without also handing over the schema
catalogue — but it means "I already gave it SystemAdmin" is never a valid reason
to skip a component-scoped binding.

The `--connect-cluster` value is another reliable trip hazard. It is **not** the
`kafka_connect_cluster_name` from the inventory (`cp-lab-connect`); it is the
Connect worker group id, `kafka_connect_group_id`, which defaults to
`connect-cluster`. Confirm it rather than assuming:

```bash
confluent cluster list
```

The `Component ID` column holds the value each `--*-cluster` flag expects.

---

## 4. The roles, and which to pick

Roles divide into two families, and mixing them up is the most common
over-permissioning mistake.

**Cluster-scoped roles** are administrative. They are granted without a
`--resource` flag and apply to a whole cluster:

| Role | What it is for |
|---|---|
| `SystemAdmin` | Everything, on everything in scope. Break-glass and initial setup only. |
| `ClusterAdmin` | Provision and manage the cluster, brokers, networking. Cannot read or write topic data. |
| `UserAdmin` | Manage role bindings — grant access to others. |
| `SecurityAdmin` | Security features, audit logs; also what a component needs to *ask* MDS authorization questions. |
| `Operator` | Monitoring; can pause, resume and scale connectors. |

**Resource-scoped roles** are what applications get. They always carry a
`--resource` flag:

| Role | Grants | Typical holder |
|---|---|---|
| `DeveloperRead` | read + describe | consumers, sink connectors |
| `DeveloperWrite` | write + describe (**not** read) | producers, source connectors |
| `DeveloperManage` | create and delete the resource | tooling that provisions topics |
| `ResourceOwner` | read + write + manage + the right to grant access to others | the team that owns a data domain |

Two rules carry most of the weight:

**Start at `DeveloperWrite` or `DeveloperRead` and escalate only on a real
denial.** `ResourceOwner` is convenient and it is how most people's first
cluster ends up with every service account able to delete every topic. Reach for
it when a principal genuinely owns a data domain and needs to delegate, not
because a narrower role was inconvenient to work out.

**Never use `SystemAdmin` for data access.** Confluent's guidance is to restrict
it to one or two people per cluster, for initial setup and emergencies. An
application that produces to a topic needs `DeveloperWrite` on that topic — that
is the entire requirement.

---

## 5. Prefixes: one binding instead of a hundred

The obvious way to grant topic access does not scale:

```bash
# don't do this
... --resource Topic:orders
... --resource Topic:orders-dlq
... --resource Topic:orders-retry
```

Every new topic becomes a change request. Instead, decide a **naming
convention** first, then bind once against the prefix:

```bash
confluent iam rbac role-binding create --principal User:svc-orders \
  --role DeveloperWrite --kafka-cluster "$CID" \
  --resource Topic:orders. --prefix
```

Every topic whose name begins with `orders.` is now covered, including ones that
do not exist yet. The `--prefix` flag works the same way for `Group:` and
`Subject:` resources.

This makes the naming convention a **security boundary**, not a tidiness
preference. A good convention encodes the owner in the leading segment —
`orders.`, `payments.`, `inventory.` — so that a prefix binding maps exactly
onto one team's data. A convention like `prod-`/`dev-` is useless for this
purpose, because every team's topics share the prefix.

Choose the convention before the first binding. Changing it later means
rewriting every binding *and* renaming every topic, which Kafka does not
support in place.

One convenience worth knowing: Schema Registry subjects are named
`<topic>-value` and `<topic>-key` by default, so a topic prefix and a subject
prefix are the same string. `Topic:orders.` and `Subject:orders.` cover the same
data domain.

---

## 6. Service accounts

A service account is simply a principal that belongs to a workload rather than a
person. On this platform they are LDAP entries like any user — what makes them
service accounts is how you treat them.

### One identity per workload

The rule is one service account per deployable unit, not one per team and not
one shared "app" account. The reason is blast radius: a binding attaches to a
principal, so every workload sharing a principal shares its full reach. If
`svc-app` can write `orders.` and `payments.`, then the orders producer can
write payment records — not by design, but because nothing prevents it.

Name them so that the owner is obvious from the binding list, since that list is
what you will audit: `svc-orders-source`, `svc-payments-api`,
`svc-inventory-sink`. Include the application, avoid personal names, avoid
anything temporary like `svc-test2`.

### What this repository's service accounts already have

cp-ansible creates each component's own service account and grants it what the
*component* needs to function. It does **not** grant anything the component's
*workloads* need. Knowing which is which saves a lot of guessing:

| Account | Granted automatically | You must grant |
|---|---|---|
| `svc-kafka-broker` | broker/MDS operation | — |
| `svc-kafka-schemaregistry` | `SecurityAdmin` on the SR cluster, `ResourceOwner` on `_schemas`, its consumer group, `_confluent-command` | — |
| `svc-kafka-connect` | `SecurityAdmin` on the Connect cluster, `ResourceOwner` on `connect-cluster-configs` / `-offsets` / `-statuses` and the worker group | **every data topic, subject and consumer group a connector touches** |
| `svc-kafka-proxy` | `ResourceOwner` on `_confluent-command`, `_confluent-monitoring` | — (REST Proxy impersonates the calling user) |
| `svc-kafka-controlcenter` | `SystemAdmin` at Kafka scope | bindings at Schema Registry and Connect scope for UI visibility |

The Connect row is where nearly all real work lands, and §8 walks through it.

### Two tiers for Connect

Connect has a worker identity and, optionally, a per-connector identity.

The **worker** identity (`svc-kafka-connect`) runs the cluster: it reads and
writes the three internal topics, coordinates the worker group, and asks MDS
whether incoming REST calls are authorized. cp-ansible sets this up completely.

The **connector** identity is whoever the connector's producer and consumer run
as. By default that is also the worker identity, which means every connector on
the cluster inherits the union of all connector permissions. For production this
is the thing to fix: set `connector.client.config.override.policy: All` on the
worker (this repository already does, in
[`ansible/hosts.yml`](../ansible/hosts.yml)) and give each connector its own
account.

### Rotating credentials

Service account passwords live in `ansible/vault.yml` and are written into the
components' `.properties` files in plaintext. Rotating one means changing it in
LDAP, updating the vault, and redeploying the affected role. Bindings survive a
password change untouched — they attach to the principal name, not the
credential — so rotation never requires re-granting anything.

To remove the plaintext copies on disk entirely, see
[`../secrets/`](../secrets/).

---

## 7. RBAC and ACLs together

Kafka's older ACL mechanism still exists and both are evaluated. The ordering is
what matters:

1. **ACL `DENY`** — if one matches, the request is refused, regardless of
   anything else.
2. **ACL `ALLOW`** and **RBAC role bindings** — either one grants access.

Use RBAC as the default: it is centrally stored, role-based, and it is the only
mechanism that can authorize connectors at all. Reach for an ACL in two cases —
when you need an explicit *deny* (RBAC has no negative grant), and when you need
finer granularity than a role provides. The common pattern is an RBAC binding
granting a group broad access plus a narrow ACL `DENY` carving one principal out
of it.

This cluster runs both providers, set in
[`ansible/hosts.yml`](../ansible/hosts.yml):

```
confluent.authorizer.access.rule.providers=CONFLUENT,KRAFT_ACL
```

---

## 8. Walkthrough: a connector with its own identity

This is the production pattern end to end: a source connector writing Avro to
`orders.raw`, running as its own service account with the narrowest bindings
that work. Run it against the lab cluster and each denial you meet on the way is
one you will recognise in production.

### Prepare the session

```bash
cd /opt/confluent-platform-lab/ansible
export MDS_PW=$(ansible-vault view vault.yml | awk -F'"' '/vault_mds_super_user_password/{print $2}')
export CONFLUENT_PLATFORM_USERNAME=mds CONFLUENT_PLATFORM_PASSWORD="$MDS_PW"
confluent login --url https://cp-node1:8090 --certificate-authority-path ../pki/ca/ca.crt --save
export CID=$(confluent cluster list -o json \
  | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['scope']['clusters']['kafka-cluster'])")
```

MDS tokens last one hour. When commands start failing with `Error: not logged
in`, that is expiry, not permissions — run the login again.

### Step 1 — create the service account in LDAP

```bash
cd /opt/confluent-platform-lab
ORDERS_PW=$(openssl rand -base64 16)
podman exec openldap ldapadd -x -H ldap://localhost:389 \
  -D "cn=admin,dc=lab,dc=local" -w "<LDAP_ADMIN_PW>" <<EOF
dn: uid=svc-orders-source,ou=users,dc=lab,dc=local
objectClass: inetOrgPerson
uid: svc-orders-source
cn: Orders Source Connector
sn: ServiceAccount
userPassword: $(podman exec openldap slappasswd -s "$ORDERS_PW")
EOF
echo "svc-orders-source password: $ORDERS_PW"
```

Record the password — it goes into the connector configuration in step 4, and in
a real deployment into your secret store rather than a shell variable.

Verify the account can authenticate and that MDS can see it:

```bash
podman exec openldap ldapwhoami -x -H ldap://localhost:389 \
  -D "uid=svc-orders-source,ou=users,dc=lab,dc=local" -w "$ORDERS_PW"
```

### Step 2 — create the topic

Automatic topic creation is disabled on this cluster
(`auto.create.topics.enable: "false"`), which is the right setting for
production: it forces topics to be provisioned deliberately rather than
appearing because of a typo in a connector config.

```bash
curl -sk -u "mds:$MDS_PW" -X POST "https://cp-node1:8082/v3/clusters/$CID/topics" \
  -H "Content-Type: application/json" \
  -d '{"topic_name":"orders.raw","partitions_count":3,"replication_factor":3}' \
  -w "\nHTTP %{http_code}\n"
```

### Step 3 — grant the minimum

Four bindings, all scoped to the `orders.` prefix so the whole domain is covered
once:

```bash
# produce to the domain's topics
confluent iam rbac role-binding create --principal User:svc-orders-source \
  --role DeveloperWrite --kafka-cluster "$CID" --resource Topic:orders. --prefix

# register schemas for the same domain
confluent iam rbac role-binding create --principal User:svc-orders-source \
  --role DeveloperWrite --kafka-cluster "$CID" \
  --schema-registry-cluster schema-registry --resource Subject:orders. --prefix

# idempotent producer — cluster scope, no --resource on a topic
confluent iam rbac role-binding create --principal User:svc-orders-source \
  --role DeveloperWrite --kafka-cluster "$CID" --resource Cluster:kafka-cluster

# only for sink connectors: their consumer group
confluent iam rbac role-binding create --principal User:svc-orders-source \
  --role DeveloperRead --kafka-cluster "$CID" --resource Group:connect- --prefix
```

The third one is the one everybody skips. Connect enables the idempotent
producer by default, and idempotent writes are authorized at **cluster** scope.
A perfectly correct `Topic:` binding on its own still fails, and the error
message talks about the topic, which sends you looking in the wrong place.

Check what you granted — this list is your audit surface:

```bash
confluent iam rbac role-binding list --principal User:svc-orders-source --kafka-cluster "$CID"
```

### Step 4 — run the connector as that account

Two overrides are required, and supplying only one is a subtle failure: the
first sets the Kafka producer's identity, the second the converter's identity
towards Schema Registry. Miss the second and the schema is registered as the
worker while the data is produced as `svc-orders-source`.

```bash
cat > /tmp/orders-source.json <<EOF
{
  "connector.class": "org.apache.kafka.connect.file.FileStreamSourceConnector",
  "name": "orders-source",
  "topic": "orders.raw",
  "file": "/tmp/orders-input.txt",
  "tasks.max": "1",

  "producer.override.sasl.jaas.config": "org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required username=\"svc-orders-source\" password=\"$ORDERS_PW\" metadataServerUrls=\"https://cp-node1:8090,https://cp-node2:8090,https://cp-node3:8090\";",

  "value.converter.basic.auth.credentials.source": "USER_INFO",
  "value.converter.schema.registry.basic.auth.user.info": "svc-orders-source:$ORDERS_PW"
}
EOF

echo "order-1" | sudo tee /tmp/orders-input.txt

curl -sk -u "mds:$MDS_PW" -X PUT -H "Content-Type: application/json" \
  --data @/tmp/orders-source.json -w "\nHTTP %{http_code}\n" \
  https://cp-node1:8083/connectors/orders-source/config
```

### Step 5 — verify

```bash
curl -sk -u "mds:$MDS_PW" https://cp-node1:8083/connectors/orders-source/status | python3 -m json.tool
```

Look at `tasks[0].state`, not `connector.state`. A connector whose task has died
still reports `RUNNING` at the connector level — this is the single most
misleading thing in the Connect API.

```bash
curl -sk -u "mds:$MDS_PW" https://cp-node1:8081/subjects
```

`orders.raw-value` should now be listed.

### Step 6 — prove the isolation

The point of a per-connector account is that it *cannot* reach outside its
domain. Confirm that rather than assuming it:

```bash
curl -sk -u "svc-orders-source:$ORDERS_PW" -X POST \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  --data '{"schema":"\"string\""}' -w "\nHTTP %{http_code}\n" \
  https://cp-node1:8081/subjects/payments.raw-value/versions
```

A `403` here is the test passing. If this returns `200`, a binding is wider than
intended — check the prefix on the `Subject:` binding.

---

## 9. Reading a denial

Every RBAC failure names a component, an operation and a resource. Once you can
place the message on the right gate, the fix follows immediately.

| Message | Gate | Meaning | Fix |
|---|---|---|---|
| `RestClientException: Unauthorized; error code: 401` | ① authentication | the client sent no credentials, or wrong ones | add `basic.auth.credentials.source` + `...basic.auth.user.info` |
| `Error: not logged in` from the CLI | ① authentication | MDS token expired (1 hour) | `confluent login --save` again |
| `User is denied operation Write on Subject: X` (403) | ② SR authorization | authenticated but unbound at SR scope | `DeveloperWrite` on `Subject:` with `--schema-registry-cluster` |
| `TopicAuthorizationException: Not authorized to access topics: [X]` | ③ Kafka authorization | no topic binding — or no cluster-scope binding for the idempotent producer | `DeveloperWrite` on `Topic:` **and** on `Cluster:kafka-cluster` |
| `GroupAuthorizationException` | ③ Kafka authorization | consumer group not bound | `DeveloperRead` on `Group:` |
| Control Center shows "All clusters (0)" | ② visibility | the *logged-in user* has no binding | see §5 of the main [README](../README.md) |
| A component returns `[]` where data was expected | ② visibility | the *querying principal* has no binding at that scope | check bindings before suspecting configuration |

Three habits make this faster:

**Check the task, not the connector.** `connector.state` reflects whether the
connector object exists; `tasks[].state` reflects whether it works.

**Fetch a fresh token after granting.** Bindings apply immediately, but a token
issued before the grant does not carry it. In the UI, log out and back in.

**Reproduce the denial with `curl` as the principal in question.** It removes
every layer of guessing about which identity was actually used:

```bash
curl -sk -u "svc-orders-source:$ORDERS_PW" -o /dev/null \
  -w "HTTP %{http_code}\n" https://cp-node1:8081/subjects
```

---

## 10. Production checklist

**Modelling**

- One service account per deployable workload, named for the application.
- A topic naming convention whose leading segment identifies the owner, agreed
  before the first binding is created.
- Prefix bindings against that convention; a binding per topic is a sign the
  convention is missing.

**Least privilege**

- `DeveloperWrite` / `DeveloperRead` as the default; `ResourceOwner` only for
  genuine data-domain owners.
- `SystemAdmin` restricted to one or two people per cluster, for setup and
  emergencies.
- No service account holds `SystemAdmin`.
- Verify isolation by attempting an out-of-domain operation and confirming 403.

**Operations**

- Role bindings are runtime state and are not restored by redeploying. Script
  them, keep the script in version control, and make it idempotent.
- Audit with `confluent iam rbac role-binding list --principal ... --kafka-cluster "$CID"`
  per service account; the output is short by design when least privilege holds.
- Bind human users through LDAP groups, service accounts individually. Group
  bindings authorize correctly but are not reflected in Control Center's cluster
  visibility — see "Roles granted through a group may not show up in the UI" in
  §6 of the main [README](../README.md).
- Rotating a password does not affect bindings.

**Before going live**

- Replace the trial licence (`vault_confluent_license_key`).
- Move service account passwords out of the on-disk `.properties` files —
  see [`../secrets/`](../secrets/).
- Point MDS at the corporate directory rather than the lab OpenLDAP container.
- Confirm `connector.client.config.override.policy: All` is set and that every
  production connector actually carries both overrides from §8 step 4.

---

## Sources

- [Use role-based access control (RBAC) for authorization in Confluent Platform](https://docs.confluent.io/platform/current/security/authorization/rbac/overview.html)
- [Use Predefined RBAC Roles in Confluent Platform](https://docs.confluent.io/platform/current/security/authorization/rbac/rbac-predefined-roles.html)
- [Kafka Connect and RBAC for Confluent Platform](https://docs.confluent.io/platform/current/connect/rbac-index.html)
- [Example Connect role-binding sequence](https://docs.confluent.io/platform/current/connect/rbac/connect-rbac-example.html)
- [Configure RBAC for Schema Registry in Confluent Platform](https://docs.confluent.io/platform/current/schema-registry/security/rbac-schema-registry.html)
- [Use access control lists (ACLs) for authorization in Confluent Platform](https://docs.confluent.io/platform/current/security/authorization/acls/overview.html)
