# What the real logs taught me

Everything here was observed in this lab on OpenBao 2.7.3 (and 2.6.6 for the upgrade), with the detection rules ported from the Vault 1.19 lab. Where it differs from Vault, it says so.

## 1. A write sent to a standby is audited twice

Since 2.5, standbys run requests themselves. When a request tries to write, the storage layer on the standby returns a read-only error and OpenBao forwards the request to the active node. The client never sees the error. The audit log does:

```text
request   auth/userpass/login/alice
response  auth/userpass/login/alice   error: invalid request
request   auth/userpass/login/alice
response  auth/userpass/login/alice   (token issued)
```

The same happens for KV writes (`cannot write to readonly storage`), token creation (`invalid request`) and every other write. Transit encryption, which does not write, is served by the standby with a single clean pair.

Effect on detection: the Vault lab's "6 failed logins in 2 minutes" rule fired on alice and on AppRole within minutes, because two thirds of the load generator's logins land on a standby. Fix: rule 100102 matches those two error strings at level 0, and rule 100110 (failed login) ignores them. Anything else that counts errors in audit logs (dashboards, anomaly jobs) needs the same filter.

## 2. Standbys log ERROR lines for writes that succeed

The same forwarding leaves lines like these in the standby's server log:

```text
failed to persist failed login user entry   error: cannot write to readonly storage
set namespace failed                         error: ... cannot write to readonly storage
failed to handle namespace deletion following failed creation
```

The namespace was created and deleted correctly through the active node; `bao namespace list` shows nothing tainted. Rule 100209 drops these to level 0.

## 3. Rekey and generate-root are authenticated and audited

In Vault, `sys/rekey/*` and `sys/generate-root/*` need no token and never reach the audit log; the Vault lab caught rekey from the server log only. In OpenBao 2.7:

- `bao operator rekey` is deprecated in favour of `bao operator rotate-keys`, which calls `sys/rotate/root/init` with a token.
- Root generation uses `sys/generate-root-token/attempt`, also with a token.
- The old unauthenticated endpoints answer `405 unsupported operation`. They are switched off by `disable_unauthed_rekey_endpoints` (default true since 2.5.0) and `disable_unauthed_generate_root_endpoints` (default true since 2.5.3).

Both now show up in the audit log with the identity that started them (rule 100140), and in the server log as `rotation initialized` and `root generation initialized` (rule 100202).

## 4. Audit devices live in the config file

`bao audit enable` and `bao audit disable` are refused with HTTP 400. The refused call is still audited, so rule 100141 fires on the attempt: someone tried to switch off auditing.

## 5. Lockout is visible only in the audit log

Vault 1.19 wrote `login attempts exceeded, user is locked out` to the server log. OpenBao 2.7.3 writes nothing. `vault_core_locked_users` stayed at 0 on all three nodes while `sys/locked-users` listed carol. The audit log is the reliable signal: after the fifth failure, the response changes from `invalid credentials` to `permission denied`. Rule 100114 alerts on that.

## 6. Rate limit quotas are per node

With a quota of 5 requests per second on `noisy/`, a burst sent to a standby was rejected by the standby itself, and the standby exported its own `vault_quota_rate_limit_violation`. Each node enforces the quota on what it serves, so three nodes allow about three times the configured rate. Size quotas for the node count, or put the limit in front of the cluster.

## 7. Standbys write audit lines

Per-node `vault_audit_log_request_count` after a short test: active 49, standby 24, standby 1. If your log shipper runs only where the active node is, you lose the reads served by standbys.

## 8. Metric names did not change

OpenBao still exports `vault_*` metrics and the same labels, plus a `namespace` label on usage gauges (`vault_secret_kv_count`, `vault_identity_entity_count`). The Vault lab's dashboards and alert rules worked after renaming the job.

## 9. Step-down still writes only a request line

`sys/step-down` produces a request line and no response line, as in Vault. The server log has `stepping down from active operation to standby` (rule 100208).

## 10. A broken link to site B looks healthy for a minute

During the DR drill, cutting the network to the replica did not move any lag metric. The primary drops the replica from `pg_stat_replication` and the replica cannot be scraped, so lag panels go blank instead of rising. The replication slot on the primary keeps counting (`pg_replication_slots_pg_wal_lsn_diff`), and `slot_is_active` turns 0 only after `wal_sender_timeout`, 60 seconds by default. With 60 s, a 20-second outage followed by the loss of site A never raised an alert. The lab sets 10 s and alerts on the slot. Details in [dr.md](dr.md).
