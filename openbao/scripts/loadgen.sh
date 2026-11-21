#!/bin/sh
# Background traffic so the dashboards and the SIEM have data.
# A mix of good and bad requests spread over all three nodes. Since OpenBao 2.5 the
# standbys answer reads themselves, so the per-node request panels show the spread.
set -u
TOKEN=$(cat "${SECRETS_DIR:-/secrets}/loadgen-token")
NODES=${NODES:-"bao-1 bao-2 bao-3"}
RATE=${LOADGEN_SLEEP:-3}     # seconds between rounds

pick() { set -- $NODES; i=$(( $(od -An -N1 -tu1 /dev/urandom) % $# + 1 )); eval echo "\$$i"; }

echo "[loadgen] starting, one round every ${RATE}s"
n=0
while true; do
  n=$((n+1))
  export BAO_ADDR="http://$(pick):8200"

  # logins: mostly good, a bad password now and then
  # (rare on purpose: OpenBao locks a user out after 5 failures in 15 minutes by default)
  bao login -no-store -method=userpass username=alice password=alice-pass >/dev/null 2>&1
  [ $((n % 60)) -eq 0 ] && bao login -no-store -method=userpass username=bob password=wrong >/dev/null 2>&1

  # AppRole: fetch role-id and a fresh secret-id, then log in
  ROLE_ID=$(BAO_TOKEN=$TOKEN bao read -field=role_id auth/approle/role/web/role-id 2>/dev/null)
  SECRET_ID=$(BAO_TOKEN=$TOKEN bao write -f -field=secret_id auth/approle/role/web/secret-id 2>/dev/null)
  APP_TOKEN=$(bao write -field=token auth/approle/login role_id="$ROLE_ID" secret_id="$SECRET_ID" 2>/dev/null)

  # app reads with its own token (served by whichever node got the request), plus a forbidden read now and then (403)
  BAO_TOKEN=$APP_TOKEN bao kv get secret/app/config >/dev/null 2>&1
  BAO_TOKEN=$APP_TOKEN bao kv get secret/app/db >/dev/null 2>&1
  [ $((n % 20)) -eq 0 ] && BAO_TOKEN=$APP_TOKEN bao kv get secret/admin/break-glass >/dev/null 2>&1

  # namespace traffic: a parent-namespace policy reaching into team-a
  BAO_TOKEN=$TOKEN bao kv get -namespace=team-a kv/service/config >/dev/null 2>&1

  # KV writes and transit
  BAO_TOKEN=$TOKEN bao kv put secret/loadgen/counter value=$n >/dev/null 2>&1
  CT=$(BAO_TOKEN=$TOKEN bao write -field=ciphertext transit/encrypt/payments plaintext=$(echo -n "card-$n" | base64) 2>/dev/null)
  BAO_TOKEN=$TOKEN bao write transit/decrypt/payments ciphertext="$CT" >/dev/null 2>&1

  # short-lived child tokens (leases come and go)
  BAO_TOKEN=$TOKEN bao token create -ttl=2m -policy=app -field=token >/dev/null 2>&1

  # burst against the rate-limited mount every 120 rounds, about every 10 minutes (HTTP 429)
  if [ $((n % 120)) -eq 0 ]; then
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do BAO_TOKEN=$APP_TOKEN bao kv get noisy/item >/dev/null 2>&1 & done
    wait
  fi

  # keep the periodic loadgen token alive
  [ $((n % 100)) -eq 0 ] && BAO_TOKEN=$TOKEN bao token renew >/dev/null 2>&1

  sleep "$RATE"
done
