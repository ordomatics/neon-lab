#!/usr/bin/env bash
# Generates the pgbouncer-tls Secret (self-signed cert + userlist.txt) and
# applies it directly — never written to a file, since userlist.txt's md5
# hashes are password-equivalent for Postgres authentication.
#
# Usage: ROLE_PASSWORDS="odoo:odoo provisioner:<real-password>" ./generate-pgbouncer-secret.sh
# Each role/password pair must already be a real, working password on the
# compute (pg_hba requires md5 for every non-loopback connection — a
# placeholder is rejected with 28P01, see FINDINGS.md).
set -euo pipefail

: "${ROLE_PASSWORDS:?set ROLE_PASSWORDS=\"role:password ...\"}"
: "${TLS_CN:=neon-lab.ordomatics.com}"
: "${TLS_SANS:?set TLS_SANS=\"DNS:...,IP:...,IP:...\"}"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

openssl req -x509 -newkey rsa:2048 -keyout "$workdir/tls.key" -out "$workdir/tls.crt" \
  -days 825 -nodes -subj "/CN=${TLS_CN}" -addext "subjectAltName=${TLS_SANS}"

python3 - "$workdir/userlist.txt" <<PY
import hashlib, sys
out = sys.argv[1]
pairs = "${ROLE_PASSWORDS}".split()
with open(out, "w") as f:
    for pair in pairs:
        user, pw = pair.split(":", 1)
        h = "md5" + hashlib.md5((pw + user).encode()).hexdigest()
        f.write(f'"{user}" "{h}"\n')
PY

kubectl -n neon create secret generic pgbouncer-tls \
  --from-file=tls.crt="$workdir/tls.crt" \
  --from-file=tls.key="$workdir/tls.key" \
  --from-file=userlist.txt="$workdir/userlist.txt" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "pgbouncer-tls applied. Restart the deployment to pick up a changed userlist:"
echo "  kubectl -n neon rollout restart deploy/pgbouncer"
