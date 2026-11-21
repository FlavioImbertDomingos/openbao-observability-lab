# Architecture

## Containers

| Service | Image | Role |
|---|---|---|
| bao-1, bao-2, bao-3 | openbao/openbao:2.7.3 | Raft cluster. One active node, two read-enabled standbys |
| bao-init | same image, `sh` | Initializes on first run, unseals on every run, seeds config |
| loadgen | same image, `sh` | Logins, KV, transit, namespace reads, tokens, quota bursts, spread over all nodes |
| audit-rotate | same image, `sh` | Copies and truncates audit logs above 200 MB |
| prometheus | prom/prometheus 3.16 | Scrapes every node directly, evaluates 15 alert rules |
| grafana | grafana 13.2 | Two provisioned dashboards |
| wazuh.manager, wazuh.indexer, wazuh.dashboard | wazuh 4.14.10 | Reads audit and server logs from the shared volume, 28 rules |

With `./lab.sh pg up` (profile `pg`):

| Service | Role |
|---|---|
| pg-a | PostgreSQL 17 primary, site A. `wal_sender_timeout=10s` so a broken link is noticed fast |
| pg-b | Streaming replica in site B, cloned with `pg_basebackup -R -C -S site_b` |
| baopg-1, baopg-2 | OpenBao nodes in site A, both on pg-a. The HA lock lives in the `openbao_ha_locks` table |
| baopg-init | Initializes and seeds the PostgreSQL cluster |
| canary | Writes `secret/dr/canary` with an increasing number about once a second and logs every acknowledged write |
| pg-exporter-a, pg-exporter-b | postgres-exporter for both sites |
| baopg-dr | Site B OpenBao node (profile `dr`), started only by `./lab.sh pg failover` |

## Data paths

- Metrics: Prometheus pulls `/v1/sys/metrics?format=prometheus` from each node. Standbys answer it, so you see every node, not only the active one.
- Audit: each node writes `/openbao/logs/audit.log` (Raft cluster) or `audit-pg.log` (PostgreSQL cluster) on the shared `bao-audit` volume. Wazuh mounts the volume read-only.
- Server logs: `log_file` per node (`bao-N.log`, `baopg-N.log`), JSON.

## Configuration choices worth knowing

The audit device is declared in the server configuration:

```hcl
audit "file" "file" {
  options {
    file_path = "/openbao/logs/audit.log"
    mode      = "0640"
  }
}
```

OpenBao 2.x sets `unsafe_allow_api_audit_creation = false`, so `bao audit enable` returns `cannot enable audit device via API; use declarative, config-based audit device management instead`. The block is applied at startup and on SIGHUP. Someone with a root token can no longer quietly disable auditing; they have to change the file on every node.

The audit device is replicated in the mount table, so every node uses the same `file_path`. In the lab all three nodes append to the same file on one volume. In production each node writes its own local file and the log shipper runs on every node. Before OpenBao 2.5 you could get away with collecting from the active node only, because standbys forwarded everything. Not any more.

OpenBao removed mlock in 2.0, so the config has no `disable_mlock` and the containers need no `IPC_LOCK` capability. Protect memory at the host instead (no swap, or encrypted swap).

Read scaling is on by default for Raft and (since 2.7) PostgreSQL. `disable_standby_reads = true` in the server config turns it off if your clients need read-after-write consistency and cannot send the consistency headers.

## Ports

| Port | Service |
|---|---|
| 8200, 8210, 8220 | bao-1, bao-2, bao-3 |
| 8400, 8410, 8500 | baopg-1, baopg-2, baopg-dr |
| 9090 | Prometheus |
| 3000 | Grafana |
| 8443 | Wazuh dashboard |
| 1514, 1515 | Wazuh agent ports (unused by the lab, open for your own agents) |

All of them can be moved in `.env`.
