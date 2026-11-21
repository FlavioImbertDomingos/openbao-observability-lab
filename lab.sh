#!/usr/bin/env bash
# OpenBao observability lab helper.
#   ./lab.sh up          start everything (generates Wazuh certs on first run)
#   ./lab.sh core        start only OpenBao + Prometheus + Grafana (no Wazuh, ~1 GB RAM)
#   ./lab.sh status      containers, Raft peers, URLs
#   ./lab.sh incident    simulate suspicious activity for the SIEM
#   ./lab.sh reads       show which node answered reads (standby read scaling)
#   ./lab.sh namespaces  list namespaces and log in as a team user
#   ./lab.sh pg up|failover [S]|status|down|reset   PostgreSQL cluster, second site, DR drill
#                        (failover 20: the link to site B is cut for 20 s before site A dies)
#   ./lab.sh dashboards  (re)import the "OpenBao SIEM" dashboard into Wazuh
#   ./lab.sh unseal      re-run init/unseal (after a restart of the OpenBao containers)
#   ./lab.sh token [pg]  print the root token
#   ./lab.sh versions    OpenBao version and role of each node
#   ./lab.sh snapshot    save a Raft snapshot to ./backups
#   ./lab.sh upgrade V   rolling upgrade to OpenBao version V (for example 2.7.3)
#   ./lab.sh down        stop (keeps data)
#   ./lab.sh reset       stop and delete ALL data, secrets and Wazuh certs
set -euo pipefail
cd "$(dirname "$0")"

# optional overrides (ports, versions, passwords)
if [ -f .env ]; then set -a; . ./.env; set +a; fi
BAO_PORT=${BAO_PORT:-8200}; BAO2_PORT=${BAO2_PORT:-8210}; BAO3_PORT=${BAO3_PORT:-8220}
PROMETHEUS_PORT=${PROMETHEUS_PORT:-9090}; GRAFANA_PORT=${GRAFANA_PORT:-3000}; WAZUH_PORT=${WAZUH_PORT:-8443}
WAZUH_AGENT_PORT=${WAZUH_AGENT_PORT:-1514}; WAZUH_ENROLL_PORT=${WAZUH_ENROLL_PORT:-1515}
BAOPG1_PORT=${BAOPG1_PORT:-8400}; BAOPG2_PORT=${BAOPG2_PORT:-8410}; BAOPGDR_PORT=${BAOPGDR_PORT:-8500}

CERTS=wazuh/config/wazuh_indexer_ssl_certs
CORE="bao-1 bao-2 bao-3 bao-init loadgen audit-rotate prometheus grafana"
PG_SERVICES="pg-a pg-b baopg-1 baopg-2 baopg-init canary pg-exporter-a pg-exporter-b"
ALLP="docker compose --profile pg --profile dr"     # down/reset cover every profile
PGC="docker compose --profile pg"

root_token() { sed -n 's/.*"root_token": *"\([^"]*\)".*/\1/p' secrets/init.json 2>/dev/null; }
root_token_pg() { sed -n 's/.*"root_token": *"\([^"]*\)".*/\1/p' secrets/pg/init.json 2>/dev/null; }

urls() {
  cat <<EOF

  OpenBao UI   http://localhost:$BAO_PORT      token: ./lab.sh token
  Prometheus   http://localhost:$PROMETHEUS_PORT      alerts: http://localhost:$PROMETHEUS_PORT/alerts
  Grafana      http://localhost:$GRAFANA_PORT      admin / ${GRAFANA_PASSWORD:-baolab}
  Wazuh        https://localhost:$WAZUH_PORT     admin / SecretPassword   (self-signed cert)
EOF
}

import_dashboards() {
  echo "Waiting for the Wazuh dashboard to import the OpenBao SIEM dashboard (up to 10 min)..."
  for i in $(seq 1 120); do
    if curl -sk -o /dev/null -w '%{http_code}' -u admin:SecretPassword https://localhost:$WAZUH_PORT/api/status | grep -q 200; then
      # index pattern first, never overwriting the one the Wazuh app creates
      curl -sk -o /dev/null -u admin:SecretPassword -H 'osd-xsrf: true' \
        --form file=@wazuh/wazuh-alerts-index-pattern.ndjson \
        "https://localhost:$WAZUH_PORT/api/saved_objects/_import?overwrite=false"
      curl -sk -u admin:SecretPassword -H 'osd-xsrf: true' \
        --form file=@wazuh/openbao-siem-dashboard.ndjson \
        "https://localhost:$WAZUH_PORT/api/saved_objects/_import?overwrite=true" | grep -q '"success":true' \
        && { echo "Imported: Wazuh > Dashboards > OpenBao SIEM"; return 0; }
    fi
    sleep 5
  done
  echo "Wazuh dashboard not ready yet; run ./lab.sh dashboards later."
}

# Stop early with a clear message if another program already holds one of our ports.
check_ports() {   # check_ports <var names...>
  local ours bad=0 v p
  ours=$(docker ps --filter label=com.docker.compose.project=openbao-lab --format '{{.Ports}}' 2>/dev/null || true)
  for v in "$@"; do
    p=${!v}
    echo "$ours" | grep -q ":$p->" && continue          # already ours, running
    if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
      echo "Port $p ($v) is already in use by another program (the Vault lab uses the same ports)."
      echo "  See what holds it:   lsof -nP -iTCP:$p -sTCP:LISTEN"
      echo "  Or use another port: echo $v=1$p >> .env"
      bad=1
    fi
  done
  [ $bad -eq 0 ] || { echo; echo "Fix the port(s) above, then run the command again."; exit 1; }
}
ALL_PORTS="BAO_PORT BAO2_PORT BAO3_PORT PROMETHEUS_PORT GRAFANA_PORT WAZUH_PORT WAZUH_AGENT_PORT WAZUH_ENROLL_PORT"
CORE_PORTS="BAO_PORT BAO2_PORT BAO3_PORT PROMETHEUS_PORT GRAFANA_PORT"
PG_PORTS="BAOPG1_PORT BAOPG2_PORT BAOPGDR_PORT"

# ------------------------------------------------------------ node helpers
VNODES="1 2 3"
vstat() { docker compose exec -T bao-"$1" bao status -format=json 2>/dev/null || true; }
jfield() { sed -n "s/^ *\"$1\": *\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\} *$/\1/p" | head -1; }
node_version() { vstat "$1" | jfield version; }
leader() { for n in $VNODES; do vstat "$n" | grep -q '"is_self": true' && { echo "$n"; return 0; }; done; return 0; }
role() { grep -q '"is_self": true' && echo active || echo standby; }   # reads bao status JSON on stdin
vexec() { local n=$1; shift; docker compose exec -T -e BAO_TOKEN="$(root_token)" bao-"$n" bao "$@"; }

set_env() {   # set_env KEY VALUE  (persist in .env and in this shell)
  touch .env; { grep -v "^$1=" .env || true; } > .env.tmp; echo "$1=$2" >> .env.tmp; mv .env.tmp .env; export "$1=$2"
}
unset_env() { [ -f .env ] && { grep -v "^$1=" .env || true; } > .env.tmp && mv .env.tmp .env; unset "$1"; }

versions() {
  local l; l=$(leader)
  for n in $VNODES; do
    printf "  bao-%s  %-8s %s\n" "$n" "$(node_version "$n")" "$([ "$n" = "$l" ] && echo active || echo standby)"
  done
}

# ------------------------------------------------------------ read scaling
reads() {   # count which node answered readtest/ reads, from each node's own metrics
  local p n before after
  [ -n "$(root_token)" ] || { echo "Not initialized. Run: ./lab.sh up"; exit 1; }
  count() { curl -s "http://localhost:$1/v1/sys/metrics?format=prometheus" \
    | awk '/^vault_route_read_readtest__count/ {s+=$2} END {print s+0}'; }
  echo "Sending 30 reads of readtest/item to each node and counting who answered:"
  for p in "$BAO_PORT:1" "$BAO2_PORT:2" "$BAO3_PORT:3"; do
    n=${p#*:}; p=${p%:*}
    before=$(count "$p")
    for i in $(seq 1 30); do curl -s -o /dev/null -H "X-Vault-Token: $(root_token)" "http://localhost:$p/v1/readtest/item"; done
    after=$(count "$p")
    printf "  bao-%s %-9s served %s of 30 locally\n" "$n" "($(vstat "$n" | role))" "$((after - before))"
  done
  echo "Writes still go to the active node: a standby forwards them."
  echo "In Vault Community every one of these reads would be forwarded to the active node."
}

# ------------------------------------------------------------ namespaces
namespaces() {
  [ -n "$(root_token)" ] || { echo "Not initialized. Run: ./lab.sh up"; exit 1; }
  echo "Namespaces (an Enterprise feature in Vault, open source in OpenBao):"
  vexec 1 namespace list
  echo
  echo "ana is an admin in team-a. Her token works only inside team-a:"
  local t
  t=$(docker compose exec -T -e BAO_NAMESPACE=team-a bao-1 bao login -no-store -field=token -method=userpass username=ana password=ana-pass 2>/dev/null | tail -1)
  try() { docker compose exec -T -e BAO_TOKEN="$t" "$@" >/dev/null 2>&1 && echo "allowed" || echo "denied (403)"; }
  echo "  team-a  kv/service/config:  $(try -e BAO_NAMESPACE=team-a bao-1 bao kv get kv/service/config)"
  echo "  team-b  kv/service/config:  $(try -e BAO_NAMESPACE=team-b bao-1 bao kv get kv/service/config)"
  echo "  root    secret/app/config:  $(try bao-1 bao kv get secret/app/config)"
  echo
  echo "Try it:  export BAO_ADDR=http://localhost:$BAO_PORT BAO_NAMESPACE=team-a; bao login -method=userpass username=ana"
}

# ------------------------------------------------------------ PostgreSQL + DR
pg_targets() {   # pg_targets on|dr|off   (dr adds the site B node once the drill starts it)
  if [ "$1" = on ] || [ "$1" = dr ]; then
    local t='"baopg-1:8200", "baopg-2:8200"'; [ "$1" = dr ] && t="$t, \"baopg-dr:8200\""
    echo "[{ \"targets\": [$t], \"labels\": { \"cluster\": \"pg\" } }]" > prometheus/targets/openbao-pg.json
    echo '[{ "targets": ["pg-exporter-a:9187", "pg-exporter-b:9187"] }]' > prometheus/targets/postgres-pg.json
  else
    echo '[]' > prometheus/targets/openbao-pg.json; echo '[]' > prometheus/targets/postgres-pg.json
  fi
  curl -s -X POST "http://localhost:$PROMETHEUS_PORT/-/reload" >/dev/null 2>&1 || true
}

pgstat() {   # pgstat <service> -> bao status JSON
  $ALLP exec -T "$1" bao status -format=json 2>/dev/null || true
}

pg() {
  case "${1:-}" in
    up)
      check_ports $PG_PORTS
      $PGC up -d $PG_SERVICES || { $PGC logs --tail 25 baopg-init; exit 1; }
      $PGC wait baopg-init >/dev/null 2>&1 || true
      $PGC logs baopg-init | tail -4
      pg_targets on
      # the Wazuh log collector only picks up files that exist when it starts
      if [ -n "$(docker compose ps -q wazuh.manager 2>/dev/null)" ]; then docker compose restart wazuh.manager >/dev/null; fi
      echo
      echo "PostgreSQL cluster is up: baopg-1 http://localhost:$BAOPG1_PORT, baopg-2 http://localhost:$BAOPG2_PORT"
      echo "Site B: pg-b streams from pg-a. The canary writes secret/dr/canary about once a second."
      echo "Grafana: OpenBao PostgreSQL and DR.  Next: ./lab.sh pg failover" ;;
    status|"")
      local s n
      for n in baopg-1 baopg-2 baopg-dr; do
        s=$(pgstat "$n")
        [ -n "$s" ] && printf "  %-9s %-8s %s\n" "$n" "$(echo "$s" | role)" "sealed=$(echo "$s" | jfield sealed)" \
          || printf "  %-9s stopped\n" "$n"
      done
      for n in pg-a pg-b; do
        s=$($ALLP exec -T "$n" psql -U openbao -d openbao -tAc "select case when pg_is_in_recovery() then 'replica' else 'primary' end" 2>/dev/null || echo stopped)
        printf "  %-9s %s\n" "$n" "$s"
      done
      $ALLP exec -T pg-a psql -U openbao -d openbao -tAc \
        "select 'replication: '||application_name||' '||state||', replay lag '||coalesce(replay_lag::text,'0') from pg_stat_replication" 2>/dev/null || true
      [ -f secrets/pg/canary.log ] && echo "  canary: last acknowledged write seq $(tail -1 secrets/pg/canary.log | cut -d' ' -f1)" ;;
    failover)
      pg_failover "${2:-0}" ;;
    down)
      $ALLP stop $PG_SERVICES baopg-dr >/dev/null 2>&1 || true
      pg_targets off
      echo "PostgreSQL cluster stopped (data kept). ./lab.sh pg up starts it again; ./lab.sh pg reset deletes it." ;;
    reset)
      $ALLP rm -sf $PG_SERVICES baopg-dr >/dev/null 2>&1 || true
      docker volume rm -f openbao-lab_pg-a-data openbao-lab_pg-b-data >/dev/null 2>&1 || true
      rm -rf secrets/pg; pg_targets off
      echo "PostgreSQL cluster and both databases deleted." ;;
    *) echo "Usage: ./lab.sh pg up|status|failover [seconds]|down|reset"; exit 1 ;;
  esac
}

# The drill: site A (pg-a, baopg-1, baopg-2) is lost at once. Site B promotes its replica,
# starts its own OpenBao node and unseals it. We measure how long that takes and how many
# acknowledged writes did not make it to site B.
pg_failover() {
  [ -f secrets/pg/init.json ] || { echo "Run ./lab.sh pg up first."; exit 1; }
  if [ "$($ALLP exec -T pg-b psql -U openbao -d openbao -tAc 'select pg_is_in_recovery()' 2>/dev/null)" != "t" ]; then
    echo "pg-b is not a replica any more (failover already done). Start over with: ./lab.sh pg reset && ./lab.sh pg up"; exit 1
  fi
  local cut=${1:-0} key t0 t1 t2 t3 last got lag
  case "$cut" in ''|*[!0-9]*) echo "Usage: ./lab.sh pg failover [seconds the link to site B is down first]"; exit 1 ;; esac
  key=$(sed -n 's/.*"unseal_keys_b64": *\[ *"\([^"]*\)".*/\1/p' <(tr -d '\n' < secrets/pg/init.json))
  echo "Before:"; pg status
  echo
  if [ "$cut" -gt 0 ]; then
    echo "0. Cutting the link to site B for $cut s (site A keeps taking writes; pg-b stops receiving them)"
    # a real cut: "docker pause" is not enough, the kernel keeps buffering WAL for a frozen pg-b
    docker network disconnect openbao-lab_default "$($ALLP ps -q pg-b)"
    sleep "$cut"
  fi
  echo "1. Losing site A: pg-a, baopg-1 and baopg-2 stop at the same moment"
  t0=$(date +%s.%N)
  $ALLP kill pg-a baopg-1 baopg-2 canary >/dev/null 2>&1   # the canary is a site A client: it goes too
  last=$(tail -1 secrets/pg/canary.log | cut -d' ' -f1)
  echo "   last write OpenBao acknowledged in site A: seq $last"
  if [ "$cut" -gt 0 ]; then
    docker network connect --alias pg-b openbao-lab_default "$($ALLP ps -q pg-b)"
    $ALLP restart pg-exporter-b >/dev/null 2>&1 &   # pg-b came back with a new IP address
    echo "   link to site B restored (site A is gone, so nothing more arrives)"
  fi
  echo "2. Promoting pg-b to primary"
  $ALLP exec -T pg-b psql -U openbao -d openbao -tAc "select pg_promote(true, 60)" >/dev/null
  t1=$(date +%s.%N)
  echo "3. Starting baopg-dr against pg-b and unsealing it"
  $ALLP up -d --no-deps baopg-dr >/dev/null 2>&1
  pg_targets dr
  for i in $(seq 1 60); do [ -n "$(pgstat baopg-dr)" ] && break; sleep 1; done
  $ALLP exec -T baopg-dr bao operator unseal "$key" >/dev/null
  local tu; tu=$(date +%s.%N)
  for i in $(seq 1 60); do pgstat baopg-dr | grep -q '"is_self": true' && break; sleep 1; done
  t2=$(date +%s.%N)
  got=$($ALLP exec -T -e BAO_TOKEN="$(root_token_pg)" baopg-dr bao kv get -field=seq secret/dr/canary 2>/dev/null || echo "?")
  t3=$(date +%s.%N)
  lag=$(( last - ${got/\?/0} ))
  # seconds of acknowledged writes missing in site B, from the canary's own timestamps
  local ts_last ts_got
  ts_last=$(awk -v n="$last" '$1==n {print $2}' secrets/pg/canary.log | tail -1)
  ts_got=$(awk -v n="$got" '$1==n {print $2}' secrets/pg/canary.log | tail -1)
  echo
  echo "Result"
  printf "  promote pg-b:                  %5.1f s\n" "$(echo "$t1 - $t0" | bc)"
  printf "  baopg-dr started and unsealed: %5.1f s after site A was lost\n" "$(echo "$tu - $t0" | bc)"
  printf "  baopg-dr active:               %5.1f s (waits for site A's HA lock in PostgreSQL to expire)\n" "$(echo "$t2 - $t0" | bc)"
  printf "  first read served in site B:   %5.1f s after site A was lost\n" "$(echo "$t3 - $t0" | bc)"
  echo "  canary in site B: seq $got, last acknowledged in site A: seq $last"
  echo "  data lost (RPO):               $lag acknowledged write(s), $(( ${ts_last:-0} - ${ts_got:-${ts_last:-0}} )) s of writes"
  echo
  echo "Clients would now need to reach http://localhost:$BAOPGDR_PORT (in production: DNS or a load balancer change)."
  echo "Same unseal key, same root token, same data: site B is the same OpenBao cluster, not a copy with its own keys."
  echo "Back to normal: ./lab.sh pg reset && ./lab.sh pg up"
}

# ------------------------------------------------------------ snapshots and upgrades
snapshot() {
  mkdir -p backups
  local f="snapshot-$(date +%Y%m%d-%H%M%S).snap" l; l=$(leader)
  [ -n "$l" ] || { echo "No active node. Unseal first: ./lab.sh unseal"; exit 1; }
  docker compose run --rm --no-deps -e BAO_ADDR="http://bao-$l:8200" -e BAO_TOKEN="$(root_token)" \
    bao-init -c "bao operator raft snapshot save /backups/$f" >/dev/null 2>&1 || true
  [ -s "backups/$f" ] || { echo "Snapshot failed"; exit 1; }
  echo "  snapshot: backups/$f ($(wc -c < "backups/$f" | tr -d ' ') bytes)"
}

wait_healthy() {   # wait_healthy [NODE VERSION]: autopilot healthy, can lose one voter, NODE on VERSION
  local l s blk
  sleep 5
  for i in $(seq 1 60); do
    l=$(leader)
    if [ -n "$l" ]; then
      s=$(vexec "$l" operator raft autopilot state -format=json 2>/dev/null || true)
      # first "Healthy" in the JSON is the cluster-level value
      if echo "$s" | grep -m1 -Ei '"healthy":' | grep -q true \
         && echo "$s" | grep -Eq '"(FailureTolerance|failure_tolerance)": [1-9]'; then
        [ -z "${1:-}" ] && return 0
        blk=$(echo "$s" | awk -v n="\"bao-$1\": {" 'index($0,n){f=1} f{print} f&&/NodeType/{exit}')
        echo "$blk" | grep -q "\"Version\": \"$2\"" && echo "$blk" | grep -q '"Healthy": true' && return 0
      fi
    fi
    sleep 5
  done
  echo "Cluster not healthy after 5 minutes. Check: ./lab.sh status"; exit 1
}

upgrade_node() {   # upgrade_node N VERSION
  local n=$1 v=$2 rc
  echo "- bao-$n: $(node_version "$n") -> $v"
  set_env "BAO${n}_VERSION" "$v"
  docker compose up -d --no-deps bao-"$n" >/dev/null 2>&1
  for i in $(seq 1 60); do   # wait until the new process answers (0 unsealed, 2 sealed)
    rc=0; docker compose exec -T bao-"$n" bao status >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 1 ] && break; sleep 2
  done
  docker compose run --rm --no-deps bao-init /scripts/init.sh > "backups/unseal-bao-$n.log" 2>&1 \
    || { echo "  unseal failed, see backups/unseal-bao-$n.log"; exit 1; }
  wait_healthy "$n" "$v"
  echo "  bao-$n is $(node_version "$n"), unsealed, healthy in autopilot"
}

upgrade() {
  local target=${1:-} l n new todo
  [ -n "$target" ] || { echo "Usage: ./lab.sh upgrade <version>   (tags: https://hub.docker.com/r/openbao/openbao/tags)"; exit 1; }
  mkdir -p backups
  echo "Pulling openbao/openbao:$target ..."; docker pull -q "openbao/openbao:$target" >/dev/null
  echo "Before:"; versions
  echo "1. Pre-checks and snapshot"
  wait_healthy; snapshot
  echo "2. Upgrade standbys one at a time, the active node last"
  while :; do
    l=$(leader); todo=""
    for n in $VNODES; do [ "$(node_version "$n")" != "$target" ] && todo="$todo $n"; done
    [ -z "$todo" ] && break
    n=""; for c in $todo; do [ "$c" != "$l" ] && { n=$c; break; }; done
    if [ -z "$n" ]; then
      echo "- bao-$l is active and still on $(node_version "$l"): stepping it down"
      vexec "$l" operator step-down >/dev/null 2>&1 || true
      for i in $(seq 1 30); do new=$(leader); [ -n "$new" ] && [ "$new" != "$l" ] && break; sleep 2; done
      echo "  new active node: bao-$new ($(node_version "$new"))"
      n=$l
    fi
    upgrade_node "$n" "$target"
  done
  for n in $VNODES; do unset_env "BAO${n}_VERSION"; done
  set_env BAO_VERSION "$target"
  echo "Done. After:"; versions
  echo "Rollback, if ever needed: stop the cluster, set BAO_VERSION back, restore the snapshot from backups/."
}

certs() {
  if [ ! -f "$CERTS/root-ca.pem" ]; then
    echo "Generating Wazuh certificates (first run only)..."
    mkdir -p "$CERTS"
    docker run --rm --entrypoint sh -v "$PWD/$CERTS:/certificates" -v "$PWD/wazuh/gen-certs.sh:/gen-certs.sh:ro" \
      wazuh/wazuh-certs-generator:0.0.5 /gen-certs.sh
  fi
}

case "${1:-}" in
  up)
    check_ports $ALL_PORTS
    certs
    docker compose up -d || { echo; echo "--- bao-init log ---"; docker compose logs --tail 25 bao-init; exit 1; }
    echo "Waiting for OpenBao init/unseal..."
    docker compose wait bao-init >/dev/null 2>&1 || true
    docker compose logs bao-init | tail -8
    import_dashboards
    urls ;;
  core)
    check_ports $CORE_PORTS
    docker compose up -d $CORE || { echo; echo "--- bao-init log ---"; docker compose logs --tail 25 bao-init; exit 1; }
    docker compose wait bao-init >/dev/null 2>&1 || true
    docker compose logs bao-init | tail -8
    urls ;;
  status)
    docker compose ps --format "table {{.Service}}\t{{.State}}\t{{.Status}}"
    echo
    docker compose exec -e BAO_TOKEN="$(root_token)" bao-1 bao operator raft list-peers || true
    echo; versions
    urls ;;
  dashboards)
    import_dashboards ;;
  incident)
    docker compose run --rm --no-deps bao-init /scripts/incident.sh ;;
  reads)
    reads ;;
  namespaces)
    namespaces ;;
  pg)
    shift; pg "$@" ;;
  unseal)
    docker compose up -d --force-recreate bao-init
    docker compose wait bao-init >/dev/null 2>&1 || true
    docker compose logs bao-init | tail -8 ;;
  token)
    if [ "${2:-}" = "pg" ]; then root_token_pg; else root_token; fi ;;
  versions)
    versions ;;
  snapshot)
    snapshot ;;
  upgrade)
    upgrade "${2:-}" ;;
  down)
    $ALLP down ;;
  reset)
    read -r -p "Delete all lab data, secrets and Wazuh certs? [y/N] " a
    [ "$a" = "y" ] || exit 0
    $ALLP down -v
    rm -f secrets/init.json secrets/loadgen-token secrets/.seeded
    rm -rf secrets/pg
    pg_targets off 2>/dev/null || true
    rm -rf "$CERTS" ;;
  *)
    sed -n '2,17p' "$0" ;;
esac
