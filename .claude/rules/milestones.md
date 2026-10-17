# Roadmap and acceptance criteria

> This rule has no `paths` frontmatter on purpose: it is the roadmap, used to know where the work stands and what comes next.
> Mandatory bottom-up order: Network and Router -> OS -> Database -> LB/VIP -> Storage -> Web/App.
> Web needs the DB through the VIP, so the LB layer must be finished before WordPress.

## M0 — Host networking and the SSH key

- Deliverable: 5 VMnets configured in VMware, and the shared SSH key pair present in `vagrant-provision/` before the first `vagrant up`.
- Done when: `vmnet1` to `vmnet4` carry the planned subnets with DHCP off, and each has a Windows host adapter at `<subnet>.1`.
- Done when: `vmnet8` is NAT on `10.10.10.0/24` with DHCP on.
- Done when: no VMnet exists outside this plan, checked in Virtual Network Editor. A stray VMnet occupies a subnet and gives the provider a wrong candidate to match.
- Done when: `vagrant-provision/ansible-key.pub` exists and the matching private key is **ignored by git**, not committed.
- The key can no longer be generated on `mgmt01`, because `mgmt01` is now built by Vagrant and needs the key to already exist. Generate it on the Windows host or on any throwaway machine. See ADR-21.
- Nothing to snapshot yet; no VM exists at this point.

## M1 — Lab build, routing and OS baseline

- Deliverable: `Vagrantfile`, role `common`, role `router` with forwarding and masquerade.
- Done when: all 10 VMs are up on the right VMnets with the right static IPs, and `fw01` forwards between all 4 zones.
- Done when: every NIC is matched by MAC address, so a rebuild cannot shift which interface holds which zone address. See ADR-20.
- Done when: from `mgmt01`, `ansible all -m ping` succeeds over the zone NICs, routed through `fw01`.
- Done when: `traceroute` from `web01` to `db01` shows exactly one hop at `192.168.20.254`, proving traffic is routed and not bridged.
- Done when: lab nodes still reach the internet after the NAT NIC is removed, through `fw01` masquerade.
- Done when: AppArmor is enforcing and chrony is in sync.
- Done when: no firewall is loaded anywhere. `nft list ruleset` is empty on the 9 non-router nodes, shows only `ip router_nat` on `fw01`, and `ufw` is not installed on any node. See ADR-25.
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
- Done when: the VIP `192.168.10.100` answers from `mgmt01`, which reaches it through `fw01`.
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

## M8 — Monitoring and logging

- Start only after M7 passes and is snapshotted. Monitoring needs a real system with real failure modes to observe, and `chaos/` is what proves an alert fires.
- Deliverable: roles `monitoring_server` and `monitoring_agent`, dashboards, alert rules, `mon01` fully built by Ansible.
- Stack: Prometheus, Alertmanager, Loki, Grafana on `mon01`; `node_exporter`, `mysqld_exporter`, Blackbox Exporter and Grafana Alloy on the monitored nodes. See ADR-23.
- Done when: every node appears in Prometheus as `up`, scraped from `mon01` across the routed path.
- Done when: an alert fires for at least 10 of the `chaos/` scenarios, with the delay from inject to alert recorded per scenario.
- Done when: `mysql_global_status_rpl_semi_sync_source_status` is alerted on. ADR-08 says semi-sync falls back to async silently on timeout, so without this alert G5 cannot be claimed.
- Done when: a disk-filling alert fires before the filesystem is full, which is the failure that caused the original incident.
- Done when: logs from all 10 nodes land in Loki and a chaos postmortem is written by correlating log lines **across** nodes by timestamp. This only works because `fw01` serves NTP; without a common clock the correlation is meaningless.
- Done when: Loki labels are limited to host, job and unit. No request ID or client IP in a label, because label cardinality is what kills Loki.
- Known limitation to record: `mon01` sits in the client zone, so `fw01` is in the monitoring path. If `fw01` dies, monitoring goes blind and cannot alert on the thing that died.

## Extra goals

- G5 — semi-sync: `Rpl_semi_sync_source_status = ON`, with an async versus semi-sync RPO comparison table.
- G6 — Keepalived: VIP moves in under 5 seconds, with the k6 error rate measured during the move.
- G7 — DB failover: at least 3 drills, mean RTO under 5 minutes, plus a runbook for returning the old primary as a replica.
- G8 — Ansible: `changed=0` on the second run, passwords in Vault, templates validated before reload.
- G9 — performance: a k6 table before and after tuning with p95, RPS and error rate.
- G10 — chaos: 19 scenarios planned, at least 10 required, at least 12 completed.
- G11 — incident automation: `diagnose.yml`, `triage.py`, `auto_remediate.sh`, `db_failover.py`, `order_writer.py`, `rpo_check.py`.
- G12 — documentation: README, diagrams, ADRs, runbooks, known limitations.
- G13 — observability: a table of the `chaos/` scenarios against the alert that fires and the measured delay from inject to alert, plus one postmortem written by correlating Loki logs across nodes.

## Out of scope, must be stated in the README

- No firewall on any node and no zone policy on the router; see ADR-25. The 4 zones stay routed and separate, but nothing enforces which pairs may talk, so the app zone can reach the db zone directly and only the MySQL GRANT host pattern stops it. Every "denied on purpose" flow is design intent, not enforcement, and each service's own access control is single-layer with nothing behind it. The future fix is to put the `nftables` zone policy back; this is the largest honesty item in the project and must be stated first, not buried.
- A single NFS server is a known SPOF; the future fix is GlusterFS, DRBD with Pacemaker, or object storage.
- `fw01` is a single router and therefore a SPOF for every cross-zone flow, including web to DB; the future fix is a second router with VRRP, or collapsing the zones.
- No automatic DB failover; the future fix is Orchestrator or ProxySQL with fencing.
- Fencing is only simulated, by powering the VM off and by booting read-only; there is no real STONITH.
- The whole lab sits on one physical machine, so host-level failure is not covered.
- Backup and restore stops at rebuilding a replica; there is no real backup solution.
- Monitoring covers metrics, logs and alerting, but not tracing, and Prometheus keeps only local short-term storage; there is no Thanos or Mimir, so history is bounded by the retention set on `mon01`.
- No SNMP or IPMI monitoring, because there is no physical network hardware or BMC in the lab. This is the main thing Zabbix would have added. See ADR-23.
