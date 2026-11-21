# OpenBao or Vault?

Research notes from November 2026, next to what the lab measured. Prices change and Vault Enterprise prices are not published, so treat the figures as ranges to check against a real quote.

## Features

| Capability | OpenBao 2.7 | Vault Community | Vault Enterprise |
|---|---|---|---|
| License | MPL 2.0, Linux Foundation (OpenSSF) | BUSL 1.1, source-available | Commercial |
| API, secrets engines, auth methods | Same as Vault 1.14 plus its own additions | | |
| Namespaces | Yes | No | Yes |
| Standbys serving reads | Yes (Raft since 2.5, PostgreSQL since 2.7) | No, they forward | Performance standbys |
| HSM auto-unseal (PKCS#11) | Yes | No | Yes |
| Control groups | Yes (2.7) | No | Yes |
| Declarative audit devices | Yes, API changes refused by default | No | No |
| Authenticated rekey and root generation | Yes | No | No |
| PostgreSQL HA storage | Yes | Community-supported backend, no read scaling | Integrated Storage or Consul only |
| DR site | PostgreSQL replication, manual promotion (this lab), or Raft snapshots | Raft snapshots | DR replication |
| Several active regions | Independent clusters | Independent clusters | Performance replication |
| Automated upgrades | Script them (this lab) | Script them | Autopilot upgrade automation |
| Sentinel policies | No | No | Yes |
| Transform (tokenization, format-preserving encryption) | No | No | Yes (ADP) |
| KMIP | No | No | Yes |
| Seal wrap, FIPS 140 validated builds | No upstream; vendor builds with FIPS 140-3 exist | No | Yes |
| Secrets sync to cloud secret managers | No | No | Yes |
| Support | Community, plus commercial vendors (ControlPlane and others) | Community | IBM |

## Cost

Vault Enterprise has no public price list. What is published:

- HCP Vault Dedicated (the hosted Enterprise binary): about $1,150 to $1,345 per cluster per month, plus $72.92 per client per month. A client is any app, service or user that authenticates.
- Reported self-managed contracts: about $51,000 list for 50 clients on one cluster, $88,600 list for 100 clients, with negotiated discounts of up to roughly 70%. Benchmarks for larger enterprise contracts run from about $80,000 to $500,000 per year.

The $6 million per year you may remember is not out of line for a very large estate. At the HCP list rate, $72.92 x 12 = $875 per client per year, so $6 million buys about 6,800 clients, before clusters, replication and support tiers. A company with thousands of services, pipelines and human users across several regions gets there quickly, because the bill scales with identities rather than servers.

OpenBao has no license fee. Its cost is the people who run it, the infrastructure, and optional support. ControlPlane sells hardened and long-term-support builds, FIPS 140-3 options and 24/7 support; its prices are not public either.

## Small and medium companies

OpenBao is the better choice for most of them.

- The Enterprise features a small or mid-size company usually wants are namespaces for teams, standbys that share the read load, HSM or KMS auto-unseal, and some DR story. OpenBao has the first three in the open-source build, and the fourth with PostgreSQL replication, as this lab shows.
- Vault Community is also free, but it lacks all of those, and the BUSL license limits what you may build on it.
- A 50 to 100 client Enterprise contract at $15,000 to $90,000 a year is hard to justify when the features you need are free.
- What you take on: upgrades, monitoring, backups and incident response are yours. That is true of Vault Community too. This lab is a starting point for exactly that work.

## Large enterprises

It depends on which Enterprise features you actually use.

Stay on, or choose, Vault Enterprise when you need:

- Transform for tokenization or format-preserving encryption (common in PCI environments), KMIP, or Sentinel;
- FIPS 140 validated builds with seal wrap, and a vendor that will put it in writing for auditors;
- performance replication, with several regions serving traffic from one logical cluster, or DR replication you do not have to build;
- one accountable vendor, already on the IBM paper.

OpenBao with a support contract is worth a serious look when:

- the Enterprise features in use are mostly namespaces, HSM unseal and read scaling;
- the bill is large enough that the savings pay for a platform team many times over;
- license and vendor independence matter (the MPL license allows a second vendor or your own fork).

Plan the move as a migration, not a binary swap. OpenBao forked from Vault 1.14, and the project notes that some Enterprise pieces (replication, seal wrapping, certain engines) cannot be made compatible without reverse engineering Vault Enterprise. In practice that means standing up OpenBao next to Vault and moving mounts, policies and auth configuration with Terraform, then moving applications.

## How this lab helps decide

Run the same exercises in both labs:

- `./lab.sh reads`: OpenBao spreads reads; Vault Community forwards everything to the active node.
- `./lab.sh namespaces`: free in OpenBao, Enterprise-only in Vault.
- `./lab.sh incident`: in OpenBao, rekey and root generation reach the audit log with an identity.
- `./lab.sh pg failover 30`: a second site with measured recovery time and data loss, without a license.

Then write down which Vault Enterprise features you use today. If the list is short, OpenBao probably covers it.
