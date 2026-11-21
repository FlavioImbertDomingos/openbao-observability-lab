#!/bin/sh
# Writes an increasing sequence number to secret/dr/canary on the PostgreSQL cluster,
# about once a second, and logs every write OpenBao acknowledged. After ./lab.sh pg failover,
# the last acknowledged number vs. what site B can read is the data loss (RPO).
# It also reads each value back from every node and logs stale reads to canary-stale.log.
set -u
TOKEN=$(cat "${SECRETS_DIR:-/secrets/pg}/canary-token")
LOG=${SECRETS_DIR:-/secrets/pg}/canary.log
NODES=${NODES:-"baopg-1 baopg-2"}
n=$(tail -1 "$LOG" 2>/dev/null | cut -d' ' -f1); n=${n:-0}
echo "[canary] writing from seq $n"
while true; do
  n=$((n+1))
  for node in $NODES; do   # writes go to whichever node answers; a standby forwards to the active node
    if BAO_ADDR=http://$node:8200 BAO_TOKEN=$TOKEN bao kv put secret/dr/canary seq=$n ts="$(date +%s)" >/dev/null 2>&1; then
      echo "$n $(date +%s) $node" >> "$LOG"; break
    fi
  done
  # read it straight back from every node: standbys answer reads themselves, and a read
  # right after a write can be stale there (eventual consistency). Count how often.
  for node in $NODES; do
    got=$(BAO_ADDR=http://$node:8200 BAO_TOKEN=$TOKEN bao kv get -field=seq secret/dr/canary 2>/dev/null)
    [ -n "$got" ] && [ "$got" -lt "$n" ] && echo "$n $got $(date +%s) $node" >> "${LOG%.log}-stale.log"
  done
  sleep 0.5
done
