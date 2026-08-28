#!/usr/bin/env bash
# Creates a single-tier Root CA for the lab. Run once.
# The generated ca.key is SECRET and is git-ignored.
set -euo pipefail

PKI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CN="${1:-Confluent Lab Root CA}"

if [ -f "$PKI_DIR/ca/ca.crt" ]; then
  echo "ERROR: $PKI_DIR/ca/ca.crt already exists. Regenerating it would" >&2
  echo "       invalidate every host certificate. Delete it first if that" >&2
  echo "       is really what you want." >&2
  exit 1
fi

openssl genrsa -out "$PKI_DIR/ca/ca.key" 4096
openssl req -x509 -new -nodes -key "$PKI_DIR/ca/ca.key" -sha256 -days 3650 \
  -out "$PKI_DIR/ca/ca.crt" -subj "/C=TR/O=Confluent Lab/CN=${CN}"
chmod 600 "$PKI_DIR/ca/ca.key"

echo "Created: $PKI_DIR/ca/ca.crt (valid for 10 years)"
openssl x509 -in "$PKI_DIR/ca/ca.crt" -noout -subject -dates
