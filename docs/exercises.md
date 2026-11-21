# Exercises

Each one takes 5 to 15 minutes. Start with `./lab.sh up`.

## 1. Read scaling

Run `./lab.sh reads`. Every node should serve its 30 reads. Then write through a standby and watch the audit log:

```bash
export BAO_ADDR=http://localhost:8210 BAO_TOKEN=$(./lab.sh token)
bao kv put secret/demo x=1
docker compose exec bao-1 tail -4 /openbao/logs/audit.log | jq -c '[.type,.request.path,.error]'
```

You should see four lines: the standby's failed try and the forwarded call. Question: what would a "count of audit errors" panel show if half your writes land on standbys?

## 2. Read-after-write

Write on the active node and read on a standby immediately, in a loop. The canary in the PostgreSQL cluster does this and logs stale reads to `secrets/pg/canary-stale.log`. Then set `disable_standby_reads = true` in `bao.hcl`, restart one node, and compare.

## 3. Namespaces

`./lab.sh namespaces`, then log in as ana in team-a and try to read team-b and the root namespace. Create a policy in the root namespace that grants `team-a/kv/data/*` and give it to a root-namespace token. Which namespace does the audit line show?

## 4. Incident response

`./lab.sh incident`, then in Wazuh filter `rule.groups:openbao and rule.level >= 9`. Find who rotated the unseal keys and from which address. In the Vault lab this was not possible from the audit log.

## 5. Lockout

Lock carol out (5 bad passwords), then check `vault_core_locked_users` in Prometheus, `bao read sys/locked-users`, the server logs and the audit log. Which one tells you? Unlock her with `bao write sys/locked-users/<mount_accessor>/unlock/carol`.

## 6. Quotas per node

Send 30 requests in parallel to `noisy/item` on one node, then 10 to each node. Compare the 429 counts. Redesign the quota for a three-node cluster.

## 7. Failover

`docker compose stop bao-1` (if it is active). Watch Grafana: Active node, Fault tolerance, Leadership lost. Which alert fires first? Start it again and run `./lab.sh unseal`.

## 8. Rolling upgrade

Start on 2.6.6 (`BAO_VERSION=2.6.6` in `.env`, after `./lab.sh reset`), run a read probe against all three ports, then `./lab.sh upgrade 2.7.3`. Count failed reads per node.

## 9. DR drill

`./lab.sh pg up`, wait two minutes, `./lab.sh pg failover`. Reset, then `./lab.sh pg failover 60` and watch the PostgreSQL and DR dashboard and Prometheus alerts during the cut. Why was recovery faster after the cut? (Hint: `openbao_ha_locks`.)

## 10. Change the detection window

Set pg-a back to the default `wal_sender_timeout` (remove the `command:` line in `docker-compose.yml`), repeat the 60-second cut and see when `PostgresReplicaDisconnected` fires, if at all.

## 11. Your own detection

Pick something the rules do not cover (a token created with a very long TTL, a new auth method in a namespace, a transit key exported) and write a rule in `wazuh/rules/openbao_rules.xml`. Test it with `wazuh-logtest`, then `docker compose restart wazuh.manager`.
