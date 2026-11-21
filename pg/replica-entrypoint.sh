#!/bin/sh
# Site B database: a streaming replica of pg-a, cloned on first start with pg_basebackup.
# -R writes standby.signal and primary_conninfo, -C -S site_b creates a replication slot
# on the primary so WAL is kept until the replica has it.
# ./lab.sh pg failover promotes it with SELECT pg_promote().
set -e
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "replica: cloning from $PRIMARY_HOST"
  until PGPASSWORD=replicator pg_basebackup -h "$PRIMARY_HOST" -U replicator -D "$PGDATA" -R -X stream -C -S site_b; do
    echo "replica: primary not ready, retrying"; sleep 3; rm -rf "${PGDATA:?}"/*
  done
  chmod 700 "$PGDATA"
fi
exec postgres -c hot_standby=on
