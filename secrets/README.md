# Secret Management Add-ons

Applied **after** the base installation is complete. **No reinstall is
required** — both options work by adding blocks to the existing inventory and
redeploying.

## The problem

In the base installation passwords are encrypted at rest in Ansible Vault, but
they are written in plaintext into the configuration files on the target hosts:

```bash
sudo grep -c "password=" /etc/kafka/server.properties     # 15+
```

Anyone who can read those files — a service account in the `confluent` group, a
backup archive, a log shipper — can read the keystore and LDAP passwords.

## The solution: ConfigProvider

A core Kafka feature (KIP-421). Instead of the password itself, the
configuration file carries a **reference**:

```properties
ssl.keystore.password=${file:/etc/kafka/secrets/broker.properties:keystore.password}
```

The process resolves the reference at startup. Kafka does not need to know
anything about the vault — the provider class is the bridge.

## Which one?

| | [file-configprovider](file-configprovider/) | [cyberark-conjur](cyberark-conjur/) |
|---|---|---|
| Extra dependencies | None (built into Kafka) | Conjur server + provider JARs |
| Where the secret lives | On the host, in a mode-640 file | In a central vault |
| Rotation | Update the file + restart | Update the vault + restart |
| Access control | File permissions | Vault policy, per-host authorization |
| Audit trail | None | On the vault side |
| Setup time | ~15 min | ~1 hour |
| Best suited to | Labs, PoCs, environments without a vault | Enterprise, audited environments |

**In short:** FileConfigProvider reads the password from a file — it still
lives on the machine, but no longer inside `server.properties`, and its
permissions can be tightened. CyberArk never stores the password on the machine
at all; the process fetches it from the vault at startup.

> **Consider the first as a stepping stone to the second:** set up the
> reference structure with FileConfigProvider, verify it works, then switch
> only the provider. Apart from `${file:...}` → `${cyberark:...}`, the rest of
> the configuration is identical.

## What is covered

Both add-ons are written for the **broker** and **Schema Registry**. The KRaft
controller, Kafka Connect, REST Proxy and Control Center are out of scope — the
pattern is the same, see the extension notes in each README.

> **Note on the controller:** it uses its own separate configuration file
> (`/etc/controller/server.properties`), not the broker's. Missing this
> distinction leads to "I added the references but the controller is still in
> plaintext".
