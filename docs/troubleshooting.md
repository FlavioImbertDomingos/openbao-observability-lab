# Troubleshooting

| Symptom | Fix |
|---|---|
| `Port 8200 is already in use` | The Vault lab or another program holds it. `./lab.sh down` in the other lab, or move the port in `.env` |
| OpenBao sealed after a Docker restart | `./lab.sh unseal` |
| `cannot enable audit device via API` | Expected. Audit devices are declared in `openbao/config/bao.hcl`; edit it and send SIGHUP (`docker compose kill -s HUP bao-1 bao-2 bao-3`) |
| `bao operator rekey` prints a deprecation warning | Use `bao operator rotate-keys` |
| Failed-login alerts for users who log in fine | Old rules without 100102: a standby's first try of a forwarded write. Restart wazuh.manager to load the current rules |
| Wazuh dashboard empty | `./lab.sh dashboards`, then pick the `wazuh-alerts-*` index pattern. The first start can take 5 minutes |
| Wazuh indexer exits on Linux | `sudo sysctl -w vm.max_map_count=262144` |
| `./lab.sh pg failover` says pg-b is not a replica | A failover already ran. `./lab.sh pg reset && ./lab.sh pg up` |
| PostgreSQL dashboard shows site B down after a drill | The exporter reconnects within a minute after pg-b gets its network back |
| OpenBao node down alert for baopg-dr | Only after a drill, while baopg-dr runs; `./lab.sh pg reset` clears the target |
