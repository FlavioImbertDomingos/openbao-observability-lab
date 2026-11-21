# SIEM

Wazuh reads, with `log_format json`:

- `/var/log/openbao/audit.log` and `audit-pg.log`: the file audit devices of both clusters
- `/var/log/openbao/bao-*.log` and `baopg-*.log`: server logs, one per node

Normal traffic is decoded at level 0 and never indexed. Only findings become alerts.

## Rules

| ID | Level | Fires on |
|---|---|---|
| 100100, 100101 | 0 | Any audit line; any audit response |
| 100102 | 0 | First, failed try of a write on a standby (forwarded afterwards) |
| 100110 | 5 | Failed login (standby forward errors excluded) |
| 100111 | 10 | 6 failed logins on one path in 2 minutes |
| 100114 | 10 | Login refused because the user is locked out |
| 100112, 100113 | 5, 10 | Failed OIDC callback, and 6 of them in 2 minutes |
| 100120 | 5 | Permission denied |
| 100121 | 9 | Same identity denied 5 times in a minute |
| 100125 | 6 | Rate limit quota exceeded (needs `enable_rate_limit_audit_logging`) |
| 100130 | 8 | Root token used |
| 100131 | 12 | New root token issued |
| 100140 | 10 | Privileged endpoint: generate-root-token, rotate, seal, step-down, raw |
| 100141 | 12 | Audit device change attempted (refused by OpenBao, still audited) |
| 100142 | 9 | Policy changed |
| 100143 | 9 | Auth method or secrets engine changed |
| 100144 | 9 | Namespace created or deleted |
| 100200 | 0 | Any server log line |
| 100201 | 5 | Server ERROR line |
| 100209 | 0 | Server ERROR caused by a standby write attempt |
| 100202 | 10 | Key rotation or root generation started or cancelled, root token generated |
| 100203 | 10 | A node was sealed |
| 100204 | 6 | A node became active |
| 100205 | 3 | Unsealed, entering standby |
| 100206 | 7 | Raft leader lost, election started |
| 100207 | 10 | Lockout line (Vault wording; OpenBao 2.7.3 does not write it) |
| 100208 | 7 | Active node stepped down |

## `./lab.sh incident`

| Step | Detection |
|---|---|
| 8 wrong passwords for carol | 100110, 100111, then 100114 once she is locked out |
| Root token for routine reads | 100130 |
| New root token minted | 100131 |
| Generate-root started and cancelled | 100140 (audit) and 100202 (server log) |
| `rotate-keys` started and cancelled | 100140 and 100202 |
| Policy written and deleted | 100142 |
| `bao audit disable file` | 100141 |
| Namespace created and deleted | 100144 |
| bob denied 6 times | 100120, 100121 |

Test a rule against a real line:

```bash
docker compose exec -T bao-1 tail -1 /openbao/logs/audit.log \
  | docker compose exec -T wazuh.manager /var/ossec/bin/wazuh-logtest
```
