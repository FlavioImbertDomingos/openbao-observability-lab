# Rolling upgrades

```bash
BAO_VERSION=2.6.6 ./lab.sh up
./lab.sh versions
./lab.sh upgrade 2.7.3
```

The procedure is the one from the Vault lab:

1. Check autopilot: healthy, failure tolerance at least 1. Take a Raft snapshot to `backups/`.
2. Upgrade the standbys one at a time. Each is recreated on the new image, unsealed, and must be healthy in autopilot on the new version before the next one starts.
3. Step down the active node. An upgraded standby takes over.
4. Upgrade the former leader last.

## Measured

2.6.6 to 2.7.3, three nodes, load generator running, a probe reading `secret/app/config` from every node twice a second with no retries:

| | |
|---|---|
| Total time | 65 s |
| Reads | 384, 356 succeeded |
| Failed reads | 28, all on the node being restarted |
| Failed reads on other nodes during the leader change | 0 |

| Node | Unavailable |
|---|---|
| bao-2 (standby) | 1.6 s |
| bao-3 (standby) | 2.3 s |
| bao-1 (former leader) | 9.8 s |

Behind a load balancer that health-checks `/v1/sys/health`, clients see none of it. Unlike the Vault Community lab, the standbys served those reads themselves instead of forwarding them.

## Rollback

Stop the cluster, set `BAO_VERSION` back, restore the snapshot:

```bash
bao operator raft snapshot restore -force backups/snapshot-<time>.snap
```

## Real servers

The Vault lab's Ansible playbook does the same on VMs. For OpenBao, change the binary name (`bao`), the package or download URL, the environment variables (`BAO_ADDR`, `BAO_TOKEN`) and the service name. Porting it is on the list.
