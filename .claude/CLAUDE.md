# HA e-commerce website, on-premise — Ticket #P1-0001

> Overview and hard constraints. Per-layer detail lives in `.claude/rules/`, see section 12.
> Every file in this repo is written in English: content, comments, log strings, names, commands.
> Vietnamese is used only when chatting with Claude Code, never inside a file. See `code-style.md`.

## 1. What this project is

- On-premise infrastructure lab running WordPress + WooCommerce in HA mode, with no SPOF on any request-serving layer.
- Real purpose: a portfolio project for System Engineer / SysAdmin / IT Infrastructure internship applications.
- Role played: System Engineer Intern handling ticket #P1-0001, from requirement analysis to operations handover.
- Customer requirements: 99.9% monthly uptime, zero lost orders, HTTPS on `shop.lab.internal`, plus documentation for the on-call team.
- Background: the previous single VPS went down for 3 hours because the disk filled up, and the sale season is about to drive traffic up.

## 2. Targets that must be met

- 99.9% uptime per month, about 43.8 minutes of downtime at most.
- VIP moves to the surviving LB in under 6 seconds when the active HAProxy dies.
- HAProxy removes a broken web node from the backend within roughly 6 seconds, with no user-visible error.
- Manual DB failover driven by a runbook, mean RTO under 5 minutes measured over at least 3 drills.
- RPO = 0 for confirmed orders, proven experimentally rather than claimed from configuration.
- TLS 1.2 minimum, certificate SAN matching `shop.lab.internal`.
- `ansible-playbook site.yml` must report `changed=0` on the second run.
- At least 12 failure scenarios, each with an inject script, a rollback script and a postmortem.

## 3. Architecture summary

- The network is split into 4 host-only zones; every cross-subnet packet goes through `router01`.
- Single entry point is VIP `192.168.10.100` in the DMZ zone, owned by Keepalived over VRRP.
- Two HAProxy nodes run active-passive, terminate TLS, balance HTTP for web and TCP for MySQL.
- Two web nodes run Nginx + PHP-FPM with byte-identical code, deployed only through Ansible.
- The WordPress uploads directory lives on shared NFS so both web nodes see the same files.
- Two MySQL 8.4 nodes run GTID replication with semi-sync; HAProxy routes to whichever node is writable.
- Every MySQL node boots read-only; only an operator opens write access.
- Guiding principle: automate the low-risk layers, keep the decision with a human at the database layer.

## 4. Machines in the lab

| Node | Zone and IP | RAM | vCPU | Role |
|---|---|---|---|---|
| `router01` | dmz `192.168.10.254`, app `192.168.20.254`, db `192.168.30.254`, client `172.16.10.254` | 512 MB | 1 | Gateway of all 4 zones, inter-zone forwarding policy, masquerade to NAT |
| `lb01` | dmz `192.168.10.11` | 512 MB | 1 | HAProxy + Keepalived MASTER, priority 110 |
| `lb02` | dmz `192.168.10.12` | 512 MB | 1 | HAProxy + Keepalived BACKUP, priority 100 |
| `web01` | app `192.168.20.11` | 1024 MB | 2 | Nginx + PHP-FPM, runs `wp core install` once |
| `web02` | app `192.168.20.12` | 1024 MB | 2 | Nginx + PHP-FPM |
| `nfs01` | app `192.168.20.21` | 512 MB | 1 | NFS server, a known and accepted SPOF |
| `db01` | db `192.168.30.11` | 1536 MB | 2 | MySQL, initial primary |
| `db02` | db `192.168.30.12` | 1536 MB | 2 | MySQL, initial replica |
| `mgmt01` | client `172.16.10.11` | 1024 MB | 1 | Admin box and test client: Ansible, k6, scripts |

- All 8 lab VMs run Ubuntu 24.04. Only `mgmt01` runs Debian 13.7, because it is the Ansible control node.
- VIP `192.168.10.100` is reserved for Keepalived and must never be assigned to a node.
- `.1` in every zone is the Windows host adapter, owned by VMware.
- 9 VMs and 8192 MB RAM in total, under the 10 GB ceiling the host can provide.

## 5. Deployment environment

- The Windows 11 host runs VMware Workstation Pro, Vagrant and all boxes; the host is the only place that drives the hypervisor.
- **No WSL2.** The control machine is the `mgmt01` VM running Debian 13.7.
- Daily workflow: SSH from Windows into `mgmt01`, then run every Ansible command and script there.
- `vagrant` runs only in Windows PowerShell at the repo root, never on `mgmt01`.
- `mgmt01` is installed by hand from the Debian 13.7 netinst ISO in VMware, with no Vagrant and no box; the 8 lab VMs are declared in the `Vagrantfile`.
- Every lab VM starts with a NAT NIC on `vmnet8` so Vagrant can reach it. That NIC is **removed once provisioning is done**, except on `router01` and `mgmt01`, which keep it permanently.
- After NAT removal, lab nodes reach the internet only through `router01` masquerade, and SSH only over their zone NIC; `vagrant ssh` and `vagrant provision` stop working, while `vagrant up`, `halt` and `snapshot` still do.
- The repo lives on Windows; `mgmt01` gets the code with `git clone`, never through a hypervisor shared folder.
- Debian 13.7 was chosen for `mgmt01` because it ships Python 3.13, which satisfies ansible-core 2.20; Debian 12 only has Python 3.11 and cannot run it.
- `mgmt01` runs the Debian 13.7 system Python 3.13 under a virtualenv; no `deadsnakes` or source build is involved.
- Lab nodes run the Ubuntu 24.04 system Python 3.12.3, which is what Ansible targets as the managed-node interpreter.

## 6. Virtual networks

| VMnet | Subnet | Type | Zone |
|---|---|---|---|
| `vmnet1` | `192.168.10.0/24` | host-only, DHCP off | DMZ / LB zone |
| `vmnet2` | `192.168.20.0/24` | host-only, DHCP off | App zone |
| `vmnet3` | `192.168.30.0/24` | host-only, DHCP off | DB zone |
| `vmnet4` | `172.16.10.0/24` | host-only, DHCP off | Client / admin zone |
| `vmnet8` | `10.10.10.0/24` | NAT, DHCP on | Provisioning and internet uplink |

- Every host-only zone has a Windows host virtual adapter at `<subnet>.1` and DHCP disabled; static addressing only.
- `vmnet8` keeps DHCP enabled because the temporary NIC1 needs a lease before `vagrant ssh` can work.
- Zones must never share a VMnet. Two zones on one VMnet share an L2 segment, which bypasses `router01` and voids the isolation tests.

## 7. Tech stack

- Virtualization: VMware Workstation Pro 25H2, Vagrant 2.4.9, plugin `vagrant-vmware-desktop` 3.0.5, Vagrant VMware Utility 1.0.24.
- Boxes: `bento/ubuntu-24.04` pinned to version `202510.26.0`, for the 8 lab VMs only; `mgmt01` has no box, it comes from the ISO.
- Operating systems: Ubuntu 24.04 everywhere, Debian 13.7 on `mgmt01` only.
- Router: kernel IP forwarding plus `nftables`, no routing daemon.
- Load balancer: HAProxy 3.3 from the upstream HAProxy APT repository, not the 2.8 Ubuntu ships; VIP through Keepalived 2.2.8 from Ubuntu apt with VRID 51.
- Web: Nginx 1.30.5 from the upstream nginx APT repository, not the 1.24.0 Ubuntu ships; PHP-FPM 8.3 from Ubuntu apt.
- Application: WordPress 7.0.x and WooCommerce 11.1.x, installed and managed with WP-CLI 2.12.0.
- Database: MySQL Community 8.4 LTS from the official Oracle APT repository, not the 8.0 Ubuntu ships.
- Shared storage: NFS v4.2, mounted `hard` onto the WordPress uploads directory.
- Automation: ansible-core 2.20.x in a virtualenv, secrets in Ansible Vault, checked with ansible-lint.
- Testing and operations: k6 2.1.x, Bash and Python 3.12.3 with PyMySQL on the lab nodes, alerts through the Telegram Bot API.
- Baseline security: AppArmor and `ufw` on every node, `nftables` forwarding policy on `router01`.
- Diagnostics: tcpdump, ss, lsof, mtr, traceroute, sysstat, conntrack-tools, auditd.

## 8. Repository layout

- `Vagrantfile` and `vagrant-provision/` — declare the 8 lab VMs plus the minimum provisioning Ansible needs to get in.
- `ansible/` — `ansible.cfg`, `requirements.yml`, `inventory/`, `site.yml`, `diagnose.yml`, `roles/`.
- `ansible/roles/` — common, router, nfs_server, nfs_client, mysql, mysqlchk, nginx_php, wordpress, haproxy, keepalived, pki.
- `scripts/` — probe.sh, healthcheck.py, triage.py, auto_remediate.sh, db_failover.py, order_writer.py, rpo_check.py.
- `loadtest/k6/` — load test scenarios and the before/after tuning performance report.
- `chaos/` — one directory per scenario, each with `inject.sh`, `rollback.sh` and `README.md`.
- `postmortems/` — one file per failure drill.
- `docs/` — README, diagrams, ADRs, runbooks RB-01 to RB-04, change SOP, handover document, known limitations.

## 9. Common commands

```powershell
# Windows PowerShell, at the repo root
vagrant up --provider vmware_desktop
vagrant status
vagrant snapshot save <name>           # snapshots every VM
vagrant halt --force db01              # hard power off, for DB failover drills
ssh mgmt01                             # jump to the admin box to work
```

```bash
# On mgmt01, inside ansible/
ansible all -m ping
ansible-playbook site.yml
ansible-playbook site.yml --check --diff     # detect hand-edited configuration
ansible-playbook site.yml --limit db --tags mysql
ansible-vault edit inventory/group_vars/all/vault.yml
ansible-lint
```

## 10. Rules that must never be broken

- Never fail the database over automatically; every promote needs explicit human confirmation.
- Never let both MySQL nodes be writable; confirm the old primary is dead or fenced before promoting.
- Always check for errant GTIDs before letting an old primary rejoin as a replica.
- The web health check must never touch DB or NFS, because one shared failure would drop both nodes at once.
- Every infrastructure change goes through Ansible; a hand edit made to experiment must be coded or rolled back immediately.
- Secrets live in Ansible Vault; never commit the vault password, private keys, certificates or `.vagrant/`.
- Snapshot before injecting a deliberate failure; restore `db01` and `db02` together so GTIDs cannot diverge.
- When tuning performance, change one variable at a time and record the measurement for each run.
- Never remove a lab VM NAT NIC before Ansible can reach that node over its zone NIC through `router01`.
- Never give a lab node a second zone NIC to shortcut the router; cross-zone traffic must stay routed.

## 11. Working method

- Do it by hand once to understand the mechanism, then turn it into an Ansible role.
- Build bottom-up in dependency order: Network and Router -> OS -> Database -> LB/VIP -> Storage -> Web/App.
- Every milestone has its own acceptance test; pass it, snapshot, then move on.
- Every RTO, RPO and error-rate number must be measured and recorded, never estimated.
- Write documentation as the work happens, not at the end.
- Always explain *why*, not just *how*, because interviewers ask for reasons more than for steps.
- Be honest about design limits; anything out of scope is stated explicitly instead of hidden.

## 12. Where the detail lives

- `milestones.md` — milestones M1 to M7 and their acceptance criteria; always loaded, this is the roadmap.
- `code-style.md` — language and comment rules for code, commands and log strings; always loaded.
- `architecture.md` — full diagram, data flows, zone routing, state before and after DB failover.
- `decisions.md` — design decisions with their reasons and trade-offs.
- `lab-vagrant.md` — Vagrantfile conventions, resources, VMnet pinning, NAT NIC removal, snapshot rules.
- `network-firewall.md` — zone layout, routing, port matrix and firewall principles per node.
- `ansible-conventions.md` — role standards, idempotency, Vault, lint.
- `mysql.md` — GTID, semi-sync, MySQL 8.4 syntax, failover safety rules.
- `haproxy-keepalived.md` — LB configuration, health checks, VRRP, internal PKI.
- `web-stack.md` — Nginx, PHP-FPM, WordPress, NFS and AppArmor on Ubuntu 24.04.
- `chaos-ops.md` — failure injection, runbooks, postmortems, alerting.
- Every rule except `milestones.md` and `code-style.md` has a `paths` frontmatter, so it loads only when a related file is touched; when that file does not exist yet, read the rule directly before starting.
