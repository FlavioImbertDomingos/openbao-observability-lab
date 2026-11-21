#!/bin/sh
# Initializes, unseals and seeds the 3-node lab cluster.
# Safe to run again: on later runs it only unseals.
# LAB ONLY: one unseal key (threshold 1) and the root token are written to ./secrets.
set -eu

SECRETS=${SECRETS_DIR:-/secrets}
INIT_FILE=$SECRETS/init.json
NODES=${NODES:-"bao-1 bao-2 bao-3"}
FIRST_NODE=${NODES%% *}
SEED=${SEED:-full}          # full = Raft lab cluster, pg = PostgreSQL cluster
mkdir -p "$SECRETS"

log() { echo "[bao-init] $*"; }

status_code() {   # 0 = unsealed, 2 = sealed, 1 = error / not reachable
  BAO_ADDR="http://$1:8200" bao status >/dev/null 2>&1 && echo 0 || echo $?
}

wait_reachable() {
  for i in $(seq 1 90); do
    c=$(status_code "$1")
    [ "$c" != "1" ] && return 0
    sleep 2
  done
  log "$1 not reachable at http://$1:8200 for 3 minutes."
  log "If an earlier start failed (for example a port conflict), recreate the containers:"
  log "  docker compose down && ./lab.sh up      (keeps all data)"
  exit 1
}

json_field() {    # json_field <file> <key>  -> first string value (or first array element)
  tr -d '\n ' < "$1" | sed -n "s/.*\"$2\":\[*\"\([^\"]*\)\".*/\1/p"
}

for n in $NODES; do wait_reachable "$n"; done

export BAO_ADDR=http://$FIRST_NODE:8200

if ! bao status -format=json 2>/dev/null | grep -q '"initialized": true'; then
  log "initializing $FIRST_NODE (1 key share, threshold 1: lab only)"
  bao operator init -key-shares=1 -key-threshold=1 -format=json > "$INIT_FILE"
  chmod 600 "$INIT_FILE"
  FIRST_RUN=1
else
  FIRST_RUN=0
fi

UNSEAL_KEY=$(json_field "$INIT_FILE" unseal_keys_b64)
ROOT_TOKEN=$(json_field "$INIT_FILE" root_token)
[ -n "$UNSEAL_KEY" ] || { log "cannot read unseal key from $INIT_FILE"; exit 1; }

unseal() {
  for i in $(seq 1 60); do
    c=$(status_code "$1")
    [ "$c" = "0" ] && { log "$1 unsealed"; return 0; }
    BAO_ADDR="http://$1:8200" bao operator unseal "$UNSEAL_KEY" >/dev/null 2>&1 || true
    sleep 2
  done
  log "could not unseal $1"; exit 1
}

for n in $NODES; do unseal "$n"; done   # on the first run this also joins the Raft followers

export BAO_TOKEN=$ROOT_TOKEN

wait_active() {   # an active node answers sys/leader with is_self on one of the nodes
  for i in $(seq 1 60); do
    bao read -format=json sys/leader 2>/dev/null | grep -q '"leader_address": "http' && return 0
    sleep 2
  done
  log "no active node after 120s"; return 1
}
wait_active

if [ "$FIRST_RUN" = "1" ] || [ ! -f "$SECRETS/.seeded" ]; then
  log "seeding lab configuration ($SEED)"
  # No "bao audit enable" here: the audit device is declared in the server config.

  bao secrets enable -path=secret -version=2 kv

  if [ "$SEED" = "pg" ]; then
    bao kv put secret/dr/canary seq=0 >/dev/null
    bao policy write dr-canary - <<'POL'
path "secret/data/dr/*" { capabilities = ["create", "read", "update"] }
POL
    bao token create -policy=dr-canary -period=24h -display-name=dr-canary -field=token > "$SECRETS/canary-token"
    chmod 600 "$SECRETS/canary-token"
    touch "$SECRETS/.seeded"
    log "cluster ready"; exit 0
  fi

  bao secrets enable transit
  bao write -f transit/keys/payments >/dev/null
  bao kv put secret/app/config api_key=lab-123 db_host=db.lab.local >/dev/null
  bao kv put secret/app/db username=app password=initial-pass >/dev/null
  bao kv put secret/admin/break-glass note="only admins" >/dev/null
  bao secrets enable -path=readtest -version=1 kv   # only ./lab.sh reads touches it, so its counters are clean
  bao write readtest/item value=1 >/dev/null
  bao secrets enable -path=noisy -version=2 kv
  bao kv put noisy/item value=1 >/dev/null

  bao policy write app - <<'POL'
path "secret/data/app/*"      { capabilities = ["read"] }
path "secret/metadata/app/*"  { capabilities = ["list"] }
path "noisy/data/*"           { capabilities = ["read"] }
path "transit/encrypt/payments" { capabilities = ["update"] }
path "transit/decrypt/payments" { capabilities = ["update"] }
POL
  bao policy write loadgen - <<'POL'
path "secret/*"                { capabilities = ["create", "read", "update", "patch", "list"] }
path "transit/*"               { capabilities = ["update"] }
path "auth/token/create"       { capabilities = ["update"] }
path "auth/token/revoke"       { capabilities = ["update"] }
path "auth/approle/role/web/secret-id" { capabilities = ["update"] }
path "auth/approle/role/web/role-id"   { capabilities = ["read"] }
path "team-a/*"                { capabilities = ["create", "read", "update", "list"] }
POL

  bao auth enable userpass
  bao write auth/userpass/users/alice password=alice-pass token_policies=app token_ttl=15m
  bao write auth/userpass/users/bob   password=bob-pass   token_policies=app token_ttl=15m
  bao write auth/userpass/users/carol password=carol-pass token_policies=app token_ttl=15m  # target of ./lab.sh incident
  bao auth enable approle
  bao write auth/approle/role/web token_policies=app token_ttl=10m secret_id_ttl=1h

  # Namespaces: an Enterprise feature in Vault, part of the open-source core in OpenBao.
  # Each team gets its own mounts, policies and users; the root namespace cannot see inside
  # unless it asks for the namespace explicitly.
  for ns in team-a team-b; do
    bao namespace create "$ns" >/dev/null
    BAO_NAMESPACE=$ns bao secrets enable -path=kv -version=2 kv >/dev/null
    BAO_NAMESPACE=$ns bao kv put kv/service/config owner="$ns" >/dev/null
    BAO_NAMESPACE=$ns bao policy write team-admin - >/dev/null <<'POL'
path "kv/*"   { capabilities = ["create", "read", "update", "delete", "list"] }
path "sys/policies/acl/*" { capabilities = ["read", "list"] }
POL
    BAO_NAMESPACE=$ns bao auth enable userpass >/dev/null
  done
  BAO_NAMESPACE=team-a bao write auth/userpass/users/ana  password=ana-pass  token_policies=team-admin >/dev/null
  BAO_NAMESPACE=team-b bao write auth/userpass/users/ben  password=ben-pass  token_policies=team-admin >/dev/null

  # rate limit quota on one mount so quota metrics have something to show
  bao write sys/quotas/rate-limit/noisy path=noisy/ rate=5 interval=1s
  # rejected (429) requests are not audited unless you turn this on
  bao write sys/quotas/config enable_rate_limit_audit_logging=true

  bao token create -policy=loadgen -policy=app -period=24h -display-name=loadgen -field=token > "$SECRETS/loadgen-token"
  chmod 600 "$SECRETS/loadgen-token"

  touch "$SECRETS/.seeded"
fi

log "cluster ready"
if [ "$SEED" = "full" ]; then bao operator raft list-peers || true; fi
log "root token saved in $INIT_FILE (./lab.sh token)"
