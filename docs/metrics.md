# Metrics

OpenBao kept Vault's telemetry names, so everything in HashiCorp's Vault monitoring guidance applies. Prometheus scrapes `/v1/sys/metrics?format=prometheus` on every node with `unauthenticated_metrics_access = true` (lab only; use a token in production).

## First screen

| Signal | Metric | Alert when |
|---|---|---|
| Sealed node | `vault_core_unsealed` | 0 for 1 min |
| Active node | `vault_core_active` | no node at 1 |
| Raft fault tolerance | `vault_autopilot_failure_tolerance` | below 1 |
| Audit failures | `vault_audit_log_request_failure`, `..._response_failure` | any increase |
| Root tokens | `vault_token_create_root` | any increase |
| p99 latency | `vault_core_handle_request{quantile="0.99"}` | above 500 ms for 5 min |
| GC pause | `vault_runtime_total_gc_pause_ns` | above 2 s per minute |
| Leases | `vault_expire_num_leases` | above 250k |
| 429s | `vault_quota_rate_limit_violation` | any (info) |

## What changes with read-enabled standbys

- `vault_core_handle_request_count` is no longer concentrated on the active node. The "Request rate by node" panel shows all three carrying load.
- `vault_route_read_<mount>_count` per node tells you who served reads. `./lab.sh reads` uses it on a dedicated `readtest/` mount.
- Latency should be watched per node, not only on the active node.
- Quota violations are exported by whichever node rejected the request.
- `vault_core_locked_users` stayed at 0 in 2.7.3 while a user was locked. Use the audit log for lockouts.

## Namespaces

Usage gauges carry a `namespace` label:

```promql
sum by (namespace, mount_point) (vault_secret_kv_count)
sum by (namespace) (vault_identity_entity_count)
```

## PostgreSQL and DR

From postgres-exporter on both sites:

| Signal | Metric | Note |
|---|---|---|
| Database up | `pg_up` | per site |
| Site B role | `pg_replication_is_replica{site="b"}` | 1 replica, 0 promoted |
| Replica lag | `pg_replication_lag_seconds{site="b"}` | goes blank during a link cut |
| WAL held for site B | `pg_replication_slots_pg_wal_lsn_diff{slot_name="site_b"}` | keeps rising during a link cut |
| Site B connected | `pg_replication_slots_slot_is_active{slot_name="site_b"}` | 0 after `wal_sender_timeout` |

Alert rules: `PostgresDown`, `PostgresReplicaLagHigh`, `PostgresReplicaDisconnected`, `PostgresReplicaBehindBytes`.
