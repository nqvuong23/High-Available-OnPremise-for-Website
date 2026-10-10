# Roadmap and acceptance criteria

> This rule has no `paths` frontmatter on purpose: it is the roadmap, used to know where the work stands and what comes next.
> Mandatory bottom-up order: Network and Router -> OS -> Database -> LB/VIP -> Storage -> Web/App.
> Web needs the DB through the VIP, so the LB layer must be finished before WordPress.

## M0 — Host networking and the admin box

- Deliverable: 4 host-only VMnets configured in VMware, `mgmt01` installed by hand from the Debian 13.7 ISO, SSH key generated on `mgmt01`.
- Done when: `vmnet1` to `vmnet4` carry the planned subnets with DHCP off, and each has a Windows host adapter at `<subnet>.1`.
- Done when: `vmnet8` is NAT on `10.10.10.0/24` with DHCP on.
- Done when: `mgmt01` reaches the internet, holds `172.16.10.11`, and its public key is copied to `vagrant-provision/`.
- Snapshot when done: `mgmt-ready` on `mgmt01`.

## M1 — Lab build, routing and OS baseline

- Deliverable: `Vagrantfile`, role `router`, role `common`, the firewall matrix actually applied.
- Done when: 8 lab VMs are up on the right VMnets with the right static IPs, and `router01` forwards between all 4 zones.
- Done when: from `mgmt01`, `ansible all -m ping` succeeds over the zone NICs, routed through `router01`.
- Done when: `traceroute` from `web01` to `db01` shows exactly one hop at `192.168.20.254`, proving traffic is routed and not bridged.
- Done when: lab nodes still reach the internet after the NAT NIC is removed, through `router01` masquerade.
- Done when: AppArmor is enforcing, chrony is in sync, `ufw` opens only the ports in the matrix.
- Done when: the whole lab can be destroyed and rebuilt by command alone, no manual step, timed.
- Snapshot when done: `base`.

## M2 — Durable database layer

- Deliverable: role `mysql`, role `mysqlchk`, database bootstrap documentation.
- Done when: replication shows `Replica_IO_Running` and `Replica_SQL_Running` both `Yes`, semi-sync on.
- Done when: both nodes boot read-only, and a direct write to the replica is refused with error 1290.
- Done when: a heartbeat makes replication lag measurable; `mysqlchk` returns 200 on the primary and 503 on the replica.
- Snapshot when done: `db-ready`.

## M3 — Load balancer and VIP layer

- Deliverable: role `haproxy`, role `keepalived`, a self-signed internal PKI.
- Done when: HTTPS is valid against the internal CA and HTTP returns 301 to HTTPS.
- Done when: the VIP `192.168.10.100` answers from `mgmt01`, which reaches it through `router01`.
- Done when: stopping HAProxy on `lb01` moves the VIP to `lb02` in under 6 seconds, with a failed-request count recorded.
- The check "stop Nginx on one node and HAProxy marks it DOWN within about 6 seconds" can only be run after M4.
- Snapshot when done: `lb-ready`.

## M4 — Web, application and storage layer

- Deliverable: roles `nfs_server`, `nfs_client`, `nginx_php`, `wordpress`.
- Done when: WooCommerce can place a real order over HTTPS.
- Done when: an image uploaded through `web01` is viewable through `web02` and the other way round.
- Done when: the code tree checksum is identical on both web nodes.
- Snapshot when done: `app-ready`.

## M5 — Operations documentation

- Deliverable: runbooks RB-01 to RB-04, configuration change SOP, handover document, ADRs.
- Done when: someone else can perform a failover from the runbook alone, with no follow-up questions.

## M6 — Failure simulation and manual troubleshooting

- Deliverable: the `chaos/` and `postmortems/` directories.
- Done when: at least 12 scenarios have an inject script, a rollback script and a complete postmortem.
- Done when: RTO and RPO are measured for the sudden-primary-death scenario.

## M7 — Automation

- Deliverable: an idempotent playbook, `diagnose.yml`, `healthcheck.py`, `auto_remediate.sh`, `db_failover.py`, k6 scenarios.
- Done when: `site.yml` reports `changed=0` on the second run.
- Done when: the health check detects at least 10 failure scenarios within 2 minutes.
- Done when: there is a load test report from before and after tuning, with an explanation.

## Extra goals

- G5 — semi-sync: `Rpl_semi_sync_source_status = ON`, with an async versus semi-sync RPO comparison table.
- G6 — Keepalived: VIP moves in under 5 seconds, with the k6 error rate measured during the move.
- G7 — DB failover: at least 3 drills, mean RTO under 5 minutes, plus a runbook for returning the old primary as a replica.
- G8 — Ansible: `changed=0` on the second run, passwords in Vault, templates validated before reload.
- G9 — performance: a k6 table before and after tuning with p95, RPS and error rate.
- G10 — chaos: 19 scenarios planned, at least 10 required, at least 12 completed.
- G11 — incident automation: `diagnose.yml`, `triage.py`, `auto_remediate.sh`, `db_failover.py`, `order_writer.py`, `rpo_check.py`.
- G12 — documentation: README, diagrams, ADRs, runbooks, known limitations.

## Out of scope, must be stated in the README

- A single NFS server is a known SPOF; the future fix is GlusterFS, DRBD with Pacemaker, or object storage.
- `router01` is a single router and therefore a SPOF for every cross-zone flow, including web to DB; the future fix is a second router with VRRP, or collapsing the zones.
- No automatic DB failover; the future fix is Orchestrator or ProxySQL with fencing.
- Fencing is only simulated, by powering the VM off and by booting read-only; there is no real STONITH.
- The whole lab sits on one physical machine, so host-level failure is not covered.
- Backup and restore stops at rebuilding a replica; there is no real backup solution.
- Monitoring stops at health check scripts; there is no Zabbix or Grafana.
