#!/usr/bin/env bash
# Generates a random password for every account in bootstrap.ldif, writes it to
# LDAP, and records the generated values in ldap/generated-passwords.txt
# (git-ignored). Copy those values into ansible/vault.yml, then delete the file.
#
# Usage: ./set-passwords.sh <ldap_admin_password>
set -euo pipefail

[ "$#" -eq 1 ] || { echo "Usage: $0 <ldap_admin_password>" >&2; exit 1; }
ADMIN_PW=$1
BASE="dc=lab,dc=local"            # << must match cp_ldap_base
CONTAINER=openldap
OUT="$(dirname "${BASH_SOURCE[0]}")/generated-passwords.txt"

ACCOUNTS=(
  "uid=mds,ou=users"
  "cn=ldap-bind-user"
  "uid=svc-kafka-broker,ou=users"
  "uid=svc-kafka-schemaregistry,ou=users"
  "uid=svc-kafka-connect,ou=users"
  "uid=svc-kafka-proxy,ou=users"
  "uid=svc-kafka-controlcenter,ou=users"
  "uid=developer1,ou=users"
)

: > "$OUT"; chmod 600 "$OUT"
for RDN in "${ACCOUNTS[@]}"; do
  PW=$(openssl rand -base64 16)
  HASH=$(podman exec "$CONTAINER" slappasswd -s "$PW")
  printf 'dn: %s,%s\nchangetype: modify\nreplace: userPassword\nuserPassword: %s\n' \
    "$RDN" "$BASE" "$HASH" \
    | podman exec -i "$CONTAINER" ldapmodify -x -H ldap://localhost:389 \
        -D "cn=admin,${BASE}" -w "$ADMIN_PW" >/dev/null
  echo "${RDN%%,*}:${PW}" >> "$OUT"
  echo "  set: ${RDN}"
done

echo ""
echo "Passwords written to: $OUT"
echo "Copy them into ansible/vault.yml, then delete this file."
