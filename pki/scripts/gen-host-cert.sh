#!/usr/bin/env bash
# Usage:   gen-host-cert.sh <inventory_hostname> <fqdn> <ip> [extra_ip]
# Example: gen-host-cert.sh cp-node1 cp-node1.lab.local 10.0.0.1
#
# Issues a SAN certificate (short name + FQDN + IP, serverAuth+clientAuth)
# signed by the Root CA. The filenames must match the ssl_signed_cert_filepath
# pattern in hosts.yml:
#   <inventory_hostname>-signed.crt  /  <inventory_hostname>-key.pem
#
# extra_ip: if you will reach Control Center from a browser over a public IP,
# add that IP here. Otherwise Jetty returns "HTTP ERROR 400 Invalid SNI" —
# which is a certificate-scope problem, not a network one.
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <inventory_hostname> <fqdn> <ip> [extra_ip]" >&2
  exit 1
fi

HOST=$1; FQDN=$2; IP=$3; EXTRA_IP="${4:-}"
PKI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$PKI_DIR/certs"

if [ ! -f "$PKI_DIR/ca/ca.crt" ] || [ ! -f "$PKI_DIR/ca/ca.key" ]; then
  echo "ERROR: no Root CA found. Run ./gen-root-ca.sh first." >&2
  exit 1
fi

openssl genrsa -out "$PKI_DIR/certs/${HOST}-key.pem" 2048
openssl req -new -key "$PKI_DIR/certs/${HOST}-key.pem" \
  -out "$PKI_DIR/certs/${HOST}.csr" \
  -subj "/C=TR/O=Confluent Lab/OU=Platform Engineering/CN=${FQDN}"

{
  cat <<CNF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = ${FQDN}
[v3_req]
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${HOST}
DNS.2 = ${FQDN}
IP.1 = ${IP}
CNF
  [ -n "$EXTRA_IP" ] && echo "IP.2 = ${EXTRA_IP}"
} > "$PKI_DIR/certs/${HOST}-san.cnf"

openssl x509 -req -in "$PKI_DIR/certs/${HOST}.csr" \
  -CA "$PKI_DIR/ca/ca.crt" -CAkey "$PKI_DIR/ca/ca.key" -CAcreateserial \
  -out "$PKI_DIR/certs/${HOST}-signed.crt" -days 825 \
  -extfile "$PKI_DIR/certs/${HOST}-san.cnf" -extensions v3_req

echo ""
openssl verify -CAfile "$PKI_DIR/ca/ca.crt" "$PKI_DIR/certs/${HOST}-signed.crt"
openssl x509 -in "$PKI_DIR/certs/${HOST}-signed.crt" -noout -ext subjectAltName
