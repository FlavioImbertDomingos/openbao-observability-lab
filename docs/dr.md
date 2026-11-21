# Disaster recovery drill

OpenBao has no equivalent of Vault Enterprise DR replication, and its developers have said they are unlikely to copy Vault's performance-secondary and DR-secondary model. With the PostgreSQL storage backend you can get a second site from the database instead. This lab builds that and measures it.

## Layout

```text
site A                                 site B
  baopg-1 ─┐                             (baopg-dr, stopped)
           ├── pg-a (primary) ── WAL ──▶ pg-b (streaming replica, slot "site_b")
  baopg-2 ─┘
  canary: writes secret/dr/canary about once a second, logs each acknowledged write
```

Both site A nodes share pg-a. The active node holds a row in `openbao_ha_locks`; the other is a read-enabled standby (read scaling on PostgreSQL is new in 2.7).

## Running it

```bash
./lab.sh pg up
./lab.sh pg status
./lab.sh pg failover            # site A is lost with a healthy link
./lab.sh pg reset && ./lab.sh pg up
./lab.sh pg failover 30         # the link to site B is cut 30 s before site A is lost
```

`failover` does what an operator would do:

1. Kills pg-a, baopg-1, baopg-2 and the canary at once.
2. `SELECT pg_promote()` on pg-b.
3. Starts baopg-dr against pg-b and unseals it with the same unseal key.
4. Reads the canary from site B and compares it with the last write site A acknowledged.

## Results

| | Healthy link (3 runs) | Link cut 20 s | Link cut 30 s | Link cut 60 s | Link cut 90 s |
|---|---|---|---|---|---|
| pg-b promoted | 1.1 to 1.3 s | 1.6 s | 1.6 s | 1.5 s | 1.8 s |
| baopg-dr unsealed | 2.5 to 2.6 s | 2.9 s | 3.0 s | 2.9 s | 3.0 s |
| baopg-dr active, first read | 12.6 to 15.4 s | 4.9 s | 5.2 s | 5.0 s | 5.1 s |
| Acknowledged writes lost | 0 | 23 (20 s) | 33 (30 s) | 67 (60 s) | 102 (91 s) |

The odd result: recovery was faster when the link had been cut. The HA lock explains it. The active node in site A keeps refreshing its row in `openbao_ha_locks`, and that row replicates to site B like any other. After a clean loss of site A, baopg-dr finds a fresh lock and waits about 10 seconds for it to expire. After a link cut, the copy in site B is already older than the lock TTL, so baopg-dr takes over at once. Either way the unseal itself takes under 3 seconds; the rest is the lock.

The data loss equals the length of the cut: everything written while site B was unreachable existed only in site A. With a healthy link and asynchronous replication, nothing was lost in this lab, but under real load you lose whatever was in flight. Synchronous replication (`synchronous_standby_names`) removes that window at the cost of write latency and of site A stalling when site B is down.

## Watching it

During a link cut:

- `pg_replication_lag_seconds{site="b"}` goes blank: the replica cannot be scraped.
- `pg_stat_replication` on the primary loses its row once the connection times out, so "bytes not replayed" stops too.
- The replication slot keeps the truth: `pg_replication_slots_pg_wal_lsn_diff{slot_name="site_b"}` rises, and `slot_is_active` turns 0 after `wal_sender_timeout`.

With the default 60 s timeout, a 20-second cut followed by the loss of site A raised nothing. The lab runs pg-a with `wal_sender_timeout=10s`; `PostgresReplicaDisconnected` fired about 40 s into a 60-second cut. Keep the timeout short and alert on the slot, not on lag.

## What this does and does not give you

It gives you a second site with the same OpenBao cluster: same keys, same tokens, same leases, same audit device configuration. Clients move by DNS or load balancer change.

It does not give you:

- automatic failover (the promotion and the DNS change are yours to script or run);
- a warm standby cluster serving reads in site B (the OpenBao node there starts at failover; OpenBao's invalidation design does not yet support standbys on a separate read replica);
- Vault Enterprise's performance replication, where several sites accept traffic at once.

For Raft storage there is no database to replicate. The options there are scheduled `bao operator raft snapshot save` copied to the other site and a tested restore, or an independent cluster per site kept identical by Terraform, as in the Vault lab.
