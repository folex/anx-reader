#!/bin/sh
set -eu
cert_dir="${1:-${TMPDIR:-/tmp}/anx-transport-cert}"
mkdir -p "$cert_dir"
cd "$cert_dir"
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca-key.pem -out ca.pem -days 1 -subj /CN=TransportTestCA -addext basicConstraints=critical,CA:TRUE
openssl req -newkey rsa:2048 -nodes -keyout key.pem -out leaf.csr -subj /CN=localhost
printf 'subjectAltName=DNS:localhost\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' > leaf.ext
openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out cert.pem -days 1 -extfile leaf.ext
