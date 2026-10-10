---
paths:
  - "ansible/**"
  - "docs/**"
  - "Vagrantfile"
  - "scripts/**"
---

# Design decisions and trade-offs

> This is what interviewers ask about most. Every decision must state a **reason** and a **cost**.
> To change a decision here, update this rule first and only then the code.

## Load balancer layer

- **ADR-01 — HAProxy instead of Nginx as the load balancer.** Reason: flexible active health checks, a Runtime API that enables and disables servers without a reload, a readable stats page, and it balances both HTTP and TCP so MySQL can use it too. Cost: one more technology to learn.
- **ADR-02 — Terminate TLS at HAProxy.** Reason: certificates are managed in one place and web nodes only speak plain HTTP internally, which keeps their config simple. Cost: LB to web traffic is unencrypted, acceptable inside a private network.
- **ADR-03 — Keepalived with preempt on, lb01 priority 110 and lb02 priority 100.** Reason: lb01 is always MASTER while healthy, so the state is predictable. Cost: one extra short interruption when lb01 recovers.
- **ADR-04 — Sticky cookie `SRV` on the web backend.** Reason: a user stays on one node, which makes debugging easier. Cost: not functionally required, since WooCommerce keeps sessions in the database.

## Web and application layer

- **ADR-05 — Shallow web health check: `/healthz.php` only proves Nginx reaches PHP-FPM, it never touches DB or NFS.** Reason: a health check that depends on the DB would make HAProxy mark **both** web nodes DOWN when the DB slows down, turning one failure into a full outage. Cost: it cannot detect a DB failure, not even a single-node one, so DB and NFS need their own monitoring channel.
- **ADR-12 — Code is deployed only by Ansible, with `DISALLOW_FILE_MODS=true`.** Reason: prevents the two nodes from drifting when somebody installs a plugin through wp-admin. Cost: installing a plugin becomes a process, not a button in the admin UI.
- **ADR-10 — NFS for the uploads directory instead of GlusterFS.** Reason: simple, sufficient at lab scale, easy to troubleshoot. Cost: NFS becomes a single point of failure and must be listed as a known limitation.
- **ADR-11 — Mount NFS `hard`.** Reason: upload data is not corrupted when the network is flaky. Cost: if NFS dies, processes hang in state D, which must not be mistaken for a PHP bug.

## Database layer

- **ADR-06 — The application connects to the database through `VIP:3306`, and HAProxy picks the writable node using `mysqlchk`.** Reason: web nodes do not need to know which node is primary, so changing primary is an HAProxy operation rather than a `wp-config.php` edit on every node. Cost: an extra network hop, MySQL sees the LB IP as the source address, an LB failover drops open DB connections, and because the VIP lives in the dmz zone every query crosses `router01` twice.
- **ADR-07 — Controlled manual database failover, never automatic.** Reason: automatic failover without fencing easily produces two primaries accepting writes and corrupts order data; for money data, a few minutes waiting for a human is safer. Cost: RTO is measured in minutes and depends on the on-call person.
- **ADR-08 — Semi-synchronous replication, `AFTER_SYNC`, 3 second timeout.** Reason: the primary only reports a successful commit once the replica has received the event, so a confirmed order always exists on at least two nodes. Cost: higher write latency, and if the replica stops responding past the timeout it silently falls back to async, which makes monitoring **mandatory**.
- **ADR-09 — `super_read_only=ON` in the config file of both DB nodes.** Reason: any node that restarts comes back read-only, a simple form of fencing against two primaries. Cost: after a planned primary restart, write access must be opened by hand following runbook RB-04.

## Network layer

- **ADR-16 — Split the lab into 4 routed zones instead of one flat subnet.** Reason: dmz, app, db and client separation is what a real deployment looks like, it makes the firewall matrix meaningful, and it creates realistic routing and troubleshooting work. Cost: `router01` is one more VM to run, every cross-zone flow needs a route plus two firewall rules, and a routing mistake now looks exactly like a firewall mistake.
- **ADR-17 — One router VM, no VRRP between routers.** Reason: a second router would double the routing complexity for a lab whose point is application HA, not network HA. Cost: `router01` is a SPOF for every cross-zone flow, including order writes, and must be listed as a known limitation.
- **ADR-18 — Keep the VIP in the dmz zone only, with MySQL proxied through that same VIP.** Reason: one VRRP instance, one certificate, one entry point, and ADR-06 stays intact. Cost: web to DB traffic hairpins through `router01` twice, which adds latency and puts the router in the write path. The alternative, a second VIP in the app zone, was rejected as more LB configuration than the lab needs.
- **ADR-19 — Remove the NAT NIC from lab nodes once provisioning is done, keeping it only on `router01` and `mgmt01`.** Reason: with NAT attached, every node has a second way in and out, so the zone firewall and routing are never really tested; removing it forces all traffic onto the designed path. Cost: `vagrant ssh` and `vagrant provision` stop working on those nodes, internet access depends on `router01` masquerade, and the removal order must be respected or a node becomes unreachable.
- **ADR-20 — Pin each zone to a specific VMnet in the `.vmx` instead of letting the provider choose.** Reason: the provider picks a VMnet by subnet matching and will silently create a new one with DHCP on, which produced stray VMnets and nodes that boot but cannot ping. Cost: the host VMnet layout becomes a prerequisite that has to be documented and checked before every build.

## Infrastructure and tooling

- **ADR-13 — All 8 lab VMs run Ubuntu 24.04; Rocky Linux was dropped.** Reason: a single distro family removes the per-OS branching from every Ansible role, so the effort goes into the HA design instead of into packaging differences; it also halves the boxes, repositories and service-name variations to keep straight. Cost: no RHEL-family experience in the project and no SELinux, so the AppArmor and MySQL-on-Debian-family paths have to carry that learning instead. The earlier two-family design was dropped once it became clear the branching cost more than it taught.
- **ADR-14 — Ansible owns all configuration, Vagrant owns VM lifecycle.** Reason: the lab can be rebuilt from scratch by command, which demonstrates infrastructure-as-code thinking. Cost: more time spent writing it up front.
- **ADR-15 — The control node is the `mgmt01` VM running Debian 13.7, not WSL2 and not Ubuntu.** Reason: `mgmt01` sits inside the lab network, so it does not depend on WSL2 mirrored networking, which has known problems with hypervisor host-only adapters; Debian 13.7 ships Python 3.13, comfortably above the 3.12 that ansible-core 2.20 requires, while the Ubuntu 24.04 lab nodes stay on 3.12.3 as managed nodes. Cost: 1 GB of extra RAM, one machine outside the all-Ubuntu rule, and all work has to start by SSHing in from Windows.
- **ADR-22 — HAProxy 3.3 and Nginx 1.30.5 come from their upstream APT repositories, not from Ubuntu 24.04.** Reason: Ubuntu 24.04 freezes HAProxy at 2.8 and Nginx at 1.24.0, so the newer feature set and security fixes are only reachable upstream, and adding a signed third-party repository is itself a skill the Ansible roles should demonstrate. Cost: two extra repositories and signing keys to manage, upgrades no longer follow the distro release cycle, and a config written for 3.3 will not load on the 2.8 a rebuilt node would get if the repository step is skipped. MySQL 8.4 already follows the same pattern through the Oracle repository.
- **ADR-21 — `mgmt01` is both admin box and test client, and it is installed by hand from the Debian 13.7 netinst ISO rather than declared in the `Vagrantfile`.** Reason: the control node must survive `vagrant destroy` of the lab, and running load tests from the client zone means k6 traffic takes the same routed path a real user would; installing from the ISO also keeps the control node free of any Vagrant or box dependency, so it does not break when the plugin or the box pin changes. Cost: one machine is not reproducible by command, so its build steps must be written down in `docs/`.
