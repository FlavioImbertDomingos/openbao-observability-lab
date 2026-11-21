#!/bin/sh
# Simulates suspicious activity so you can watch Wazuh alerts and Grafana panels react.
# Every step is harmless and undone where needed.
set -u
export BAO_ADDR=http://${TARGET:-bao-1}:8200
ROOT=$(tr -d '\n ' < ${SECRETS_DIR:-/secrets}/init.json | sed -n 's/.*"root_token":"\([^"]*\)".*/\1/p')

step() { echo; echo "== $*"; }

step "1. Brute force: 8 failed logins for carol (OpenBao locks her out after 5 by default)"
for i in 1 2 3 4 5 6 7 8; do
  bao login -no-store -method=userpass username=carol password="guess$i" >/dev/null 2>&1
done

step "2. Root token used for routine reads"
BAO_TOKEN=$ROOT bao kv get secret/admin/break-glass >/dev/null
BAO_TOKEN=$ROOT bao audit list >/dev/null

step "3. A new root token is minted"
NEWROOT=$(BAO_TOKEN=$ROOT bao token create -policy=root -ttl=5m -field=token)
BAO_TOKEN=$ROOT bao token revoke "$NEWROOT" >/dev/null

step "4. Generate-root attempt started and cancelled (authenticated in OpenBao 2.7, so it is audited)"
BAO_TOKEN=$ROOT bao operator generate-root -init >/dev/null 2>&1
BAO_TOKEN=$ROOT bao operator generate-root -cancel >/dev/null 2>&1

step "5. Unseal key rotation started and cancelled (bao operator rotate-keys, the old rekey)"
BAO_TOKEN=$ROOT bao operator rotate-keys -init -key-shares=1 -key-threshold=1 >/dev/null 2>&1
BAO_TOKEN=$ROOT bao operator rotate-keys -cancel >/dev/null 2>&1

step "6. Policy modified"
BAO_TOKEN=$ROOT bao policy write temp-escalation - >/dev/null <<'POL'
path "secret/*" { capabilities = ["read", "list"] }
POL
BAO_TOKEN=$ROOT bao policy delete temp-escalation >/dev/null

step "7. Someone tries to switch off auditing through the API (OpenBao refuses: audit is declared in config)"
BAO_TOKEN=$ROOT bao audit disable file >/dev/null 2>&1

step "8. A shadow namespace is created and removed"
BAO_TOKEN=$ROOT bao namespace create shadow-ops >/dev/null 2>&1
BAO_TOKEN=$ROOT bao namespace delete shadow-ops >/dev/null 2>&1

step "9. Repeated permission denied on the break-glass secret"
APP=$(bao login -no-store -method=userpass -field=token username=bob password=bob-pass 2>/dev/null)
for i in 1 2 3 4 5 6; do BAO_TOKEN=$APP bao kv get secret/admin/break-glass >/dev/null 2>&1; done

echo
echo "Done. Wazuh: Dashboards > OpenBao SIEM, or Threat Hunting > Events with rule.groups:openbao."
