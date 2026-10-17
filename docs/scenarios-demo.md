# This is detailed information about every failure scenario of the lab

> Eighteen scenarios, ordered bottom-up like the build: router, load balancers, web and
> storage, database. Each lives in `scripts/scenario-NN/` with its four files.
> This page is the overview; the full manual diagnosis of each one is `NN-troubleshoot.md`.

## How every scenario is run

1. Start from a known state: `ansible-playbook verify.yml` is green, and a snapshot exists.
2. Terminal 1: `bash scenario-NN/NN-audit.sh`. Leave it running before anything breaks.
3. Terminal 2: `bash scenario-NN/NN-simulate.sh`. The audit prints a `[MARK]` line.
4. Diagnose by hand with `NN-troubleshoot.md`. Stop before its **Root cause** section.
5. `bash scenario-NN/NN-rollback.sh`. It waits until the healthy state is proven.
6. Ctrl-C the audit. Its summary gives the outage per check: put those numbers in the
   postmortem, never estimates.

## Firewall rules inside a scenario

The lab runs no firewall: `ufw` is purged and `nftables.service` is stopped on every node
but the router, which keeps a masquerade-only table. See ADR-25.

Three scenarios (05, 14, 18) still need a blocked port to be realistic, so they inject one
deliberately. The rules are:

- Load the rule with `lab_chaos_rule` from `scripts/lib/common.sh`, which writes it into its
  own table `inet lab_chaos`. Never into `/etc/nftables.conf`, and never through `ufw`.
- The matching `NN-rollback.sh` must delete that table with `lab_chaos_clear` and then prove
  the healthy state, so no scenario can leave a filter behind.
- Nothing is persisted, so a reboot also clears the fault. `nft list ruleset` must come back
  empty on every node except the router once a scenario is rolled back.
- That emptiness is itself the diagnostic value: a non-empty ruleset can only be an injected
  fault, which is why these three are solvable in one command once you think to look.

## Catalogue

| # | Scenario | Layer | What stays green and hides it |
|---|---|---|---|
| 01 | IP forwarding off on the router | network | the router still answers ping |
| 02 | Route to the LB zone missing on a web node | network | the node answers health checks from `mgmt01` |
| 03 | bind9 down | network services | every request made by IP address |
| 04 | Active HAProxy dies, VIP moves | load balancer | nothing: it recovers by itself |
| 05 | VRRP blocked, split brain | load balancer | each LB thinks it is fine |
| 06 | Certificate with the wrong name | load balancer | backends UP, `curl -k` works |
| 07 | Nginx stopped on one web node | web | the site, served by the other node |
| 08 | PHP-FPM dead on one web node | web | static files on that node |
| 09 | NFS server down under hard mounts | storage | the shallow health check |
| 10 | Export revoked for one web node | storage | both web nodes UP |
| 11 | Root filesystem full on a web node | OS | the health check, and root itself |
| 12 | Application grant on the wrong source | database | every health check |
| 13 | Primary restarts read-only | database | `systemctl status mysql` |
| 14 | mysqlchk port filtered | database | MySQL itself, writable on 3306 |
| 15 | Replica down, semi-sync falls back | database | the shop: it keeps working |
| 16 | Primary dies, manual failover | database | nothing; this one is loud |
| 17 | Code drift between web nodes | application | every check |
| 18 | One web node loses its DB path | application | its health check, by design |

---

## `scenario-01`: IP forwarding turned off on the router

### Scenario description

- Injected: `net.ipv4.ip_forward=0` on `fw01`, runtime only; the persistent file is unchanged.
- Before: every zone reaches every other zone through `fw01`.
- After: every cross-zone flow stops. HAProxy marks every backend DOWN, the site times out,
  web nodes lose the DB VIP, and Ansible cannot reach anything outside the client zone.
- The trap: `ping 192.168.20.254` from `mgmt01` still answers, because those are the
  router's own addresses. "The gateway pings" says nothing about forwarding.
- Impact: total outage of the shop; no data at risk.

### How to run

```bash
bash scenario-01/01-audit.sh
bash scenario-01/01-simulate.sh
bash scenario-01/01-rollback.sh
```

### Troubleshooting (finding the cause)

- Many nodes in several zones failing at the same instant: a shared dependency, so check the
  path before any service.
- `traceroute` shows the first hop and then nothing; `ip route get` on `mgmt01` is correct.
- From `fw01` itself every host answers: they are alive, the router is not carrying traffic.
- `tcpdump` on `fw01`: packets arrive on one NIC and never leave on the other.
- `sysctl net.ipv4.ip_forward` reads 0 while `/etc/sysctl.d/99-router.conf` says 1.

### Root cause and fix

- Forwarding disabled at runtime. Fix: `sysctl -w net.ipv4.ip_forward=1`.
- A reboot would also have fixed it, and destroyed the evidence.

### What it proves

- Distinguishing a routing outage from ten service outages. Known limitation: `fw01` is a
  SPOF for every cross-zone flow (ADR-17).

---

## `scenario-02`: static route to the LB zone removed on one web node

### Scenario description

- Injected: `ip route del 192.168.10.0/24` on `web01`. The NAT default route then catches
  traffic to the LB zone.
- Before: `web01` serves half the traffic.
- After: requests from the LBs still reach `web01` through `fw01`, but its replies leave
  through the NAT NIC and are lost (asymmetric routing). HAProxy marks it DOWN with
  `L4TOUT`; `web01` also cannot reach `VIP:3306`.
- The trap: from `mgmt01` the node is perfect: SSH works, `/healthz.php` answers, because
  the route to the client zone is intact. It reaches its own zone and nothing else, which
  looks exactly like a firewall rule, and the lab has none to blame.
- Impact: capacity halved, no user-visible error while `web02` carries the load.

### How to run

```bash
bash scenario-02/02-audit.sh
bash scenario-02/02-simulate.sh      # -t web02 for the other node
bash scenario-02/02-rollback.sh
```

### Troubleshooting (finding the cause)

- Read `check_status`: `L4TOUT`, not refused, so packets are being lost.
- Compare `ip route get 192.168.10.11` with `ip route get 172.16.10.11` on `web01`: one goes
  via the zone gateway, the other via `10.10.10.2` on the NAT NIC.
- `tcpdump` on `web01`: SYN in on the zone NIC, SYN-ACK out on the NAT NIC.

### Root cause and fix

- Missing static route. Fix: `ip route replace 192.168.10.0/24 via 192.168.20.254`, or
  `netplan apply`.

### What it proves

- Why the NAT NIC must eventually go (ADR-19): two default routes turn one missing line into
  an asymmetric path.

---

## `scenario-03`: internal DNS down

### Scenario description

- Injected: `systemctl stop named` on `fw01`.
- Before: every lab name resolves through `fw01`.
- After: `shop.lab.internal` stops resolving for the lab nodes and `mgmt01`; `fw01` itself
  loses all DNS. `mgmt01` gets NXDOMAIN from its public fallback instead of a timeout.
- The trap: the shop keeps working. WordPress reaches MySQL by IP, HAProxy addresses
  backends by IP, and the audit pins the site name to the VIP.
- Impact: operators lose names; customers using the hosts file notice nothing.

### How to run

```bash
bash scenario-03/03-audit.sh
bash scenario-03/03-simulate.sh
bash scenario-03/03-rollback.sh
```

### Troubleshooting (finding the cause)

- `curl --resolve shop.lab.internal:443:192.168.10.100 https://shop.lab.internal/` works:
  the service is fine, the name is not.
- `dig @172.16.10.254` times out; `resolvectl status` shows which servers each link asks.
- On `fw01`: nothing listens on port 53, `named-checkconf -z` passes.

### Root cause and fix

- `named` stopped. Fix: `systemctl start named`.

### What it proves

- The blast radius of DNS depends on what was configured by name. Here only operators lose,
  because every data path uses addresses.

---

## `scenario-04`: the active HAProxy dies and the VIP moves

### Scenario description

- Injected: `systemctl stop haproxy` on the LB holding the VIP.
- Before: `lb01` (priority 110) holds `192.168.10.100`.
- After: `chk_haproxy` fails twice, the priority drops to 90, `lb02` (100) claims the VIP
  within a few seconds. A handful of requests fail during the move.
- Rollback: when HAProxy returns, preempt hands the VIP back: a second, shorter blip.
- Impact: seconds of errors, measured by the audit at 0.5 s resolution.

### How to run

```bash
bash scenario-04/04-audit.sh
bash scenario-04/04-simulate.sh
bash scenario-04/04-rollback.sh
```

### Troubleshooting (finding the cause)

- `ip -4 addr` on both LBs, and `journalctl -u keepalived` for `Entering MASTER STATE`.
- Run `/usr/local/bin/chk_haproxy.sh; echo $?` on the old master: it fails.
- `tcpdump -ni any vrrp`: only the highest-priority node keeps advertising.

### Root cause and fix

- HAProxy stopped on the master. Fix: start it; preempt returns the VIP.

### What it proves

- M3 and goal G6: the VIP moves in under 6 seconds without a human. Record the failed request
  count and both transition times from the audit summary.

---

## `scenario-05`: VRRP blocked, both LBs hold the VIP

### Scenario description

- Injected: an nftables table `inet lab_chaos` on the backup LB drops IP protocol 112.
- Before: one VIP holder.
- After: the backup stops hearing the master, promotes itself, and both LBs carry
  `192.168.10.100`: a duplicate IP. The router sends to whichever answered ARP last.
- The trap: each Keepalived log looks reasonable on its own.
- Impact: intermittent stalls and resets; worse under load and with stateful sessions.

### How to run

```bash
bash scenario-05/05-audit.sh
bash scenario-05/05-simulate.sh
bash scenario-05/05-rollback.sh
```

### Troubleshooting (finding the cause)

- The VIP on both LBs; `ip neigh show 192.168.10.100` on `fw01` to see who gets the traffic.
- `tcpdump` on the backup **sees** the master's adverts: captured before any netfilter hook, so the
  daemon is being starved by a filter.
- `nft list ruleset` shows a table at all, which on a firewall-less node is the answer.

### Root cause and fix

- VRRP dropped on input. Fix: `nft delete table inet lab_chaos`.

### What it proves

- VRRP has no quorum: silence reads as death. That is why `before.rules` carries an explicit
  protocol 112 rule.

---

## `scenario-06`: certificate issued for the wrong name

### Scenario description

- Injected: both LBs serve a certificate for `wrong.lab.internal`, signed by the real lab CA.
- Before: HTTPS validates against the lab CA.
- After: every validating client rejects the site (curl exit 60, browser warning), while
  HTTP still redirects, every backend is UP and `curl -k` returns 200.
- Impact: for users, a full outage; for a port-based monitor, nothing happened.

### How to run

```bash
bash scenario-06/06-audit.sh
bash scenario-06/06-simulate.sh
bash scenario-06/06-rollback.sh
```

### Troubleshooting (finding the cause)

- `curl -v` names the problem; `curl -k` working proves TLS and backends are fine.
- `openssl s_client ... | openssl x509 -noout -subject -issuer -dates -ext subjectAltName`
  shows a trusted issuer and the wrong SAN.
- Compare fingerprints on both LBs.

### Root cause and fix

- Wrong SAN. Fix: restore the bundle, or `ansible-playbook site.yml --tags lb`.

### What it proves

- A certificate check must validate name and expiry, not only that the port answers.

---

## `scenario-07`: Nginx stopped on one web node

### Scenario description

- Injected: `systemctl stop nginx` on `web01`.
- After: HAProxy's check gets `connection refused` (`L4CON`) and marks the node DOWN after
  `fall 3` checks at `inter 2s`, about 6 seconds.
- The audit includes a user pinned to `web01` by the `SRV` cookie: `option redispatch` with
  `retries 3` moves them to `web02`, so even they see no error.
- Impact: none for users; capacity halved.

### How to run

```bash
bash scenario-07/07-audit.sh
bash scenario-07/07-simulate.sh
bash scenario-07/07-rollback.sh
```

### Troubleshooting (finding the cause)

- Read `check_status` on the stats page: `L4CON`, refused.
- `nc -zv 192.168.20.11 80` refused at once: host up, port closed.
- `systemctl status nginx`, `ss -ltnp`, `nginx -t` on the node.

### Root cause and fix

- Nginx stopped. Fix: `nginx -t && systemctl start nginx`.

### What it proves

- M4 acceptance: a broken web node leaves the backend in about 6 seconds with no user-visible
  error. The audit measures the exact time.

---

## `scenario-08`: PHP-FPM dead, Nginx still up

### Scenario description

- Injected: `systemctl stop php8.3-fpm` on `web01`.
- After: Nginx answers `502 Bad Gateway` for every PHP request, including `/healthz.php`;
  HAProxy marks the node DOWN at layer 7 (`L7STS/502`).
- The trap: static files, such as the NFS probe file, still load from that node, and
  `systemctl status nginx` is green.
- Impact: none for users after the node leaves the pool.

### How to run

```bash
bash scenario-08/08-audit.sh
bash scenario-08/08-simulate.sh
bash scenario-08/08-rollback.sh
```

### Troubleshooting (finding the cause)

- Same DOWN as scenario 07, different `check_status`: `L7STS/502`, not `L4CON`.
- Static 200, PHP 502: the problem is behind Nginx.
- The Nginx error log names the failing socket; `ls -l /run/php/` shows it missing.

### Root cause and fix

- PHP-FPM stopped. Fix: `php-fpm8.3 -t && systemctl start php8.3-fpm`.

### What it proves

- Why the health check goes through PHP-FPM: a static check would keep a dead app in rotation.

---

## `scenario-09`: NFS server down under hard mounts

### Scenario description

- Injected: `systemctl stop nfs-server` on `nfs01`.
- After: anything touching uploads blocks in state D (`hard` mount, ADR-11). Images hang,
  pages that check the uploads directory hang, PHP-FPM workers pile up.
- The trap: `/healthz.php` never touches NFS (ADR-05), so HAProxy keeps both nodes UP and
  sends users into the hang, until every worker is stuck and both nodes fall together.
- On recovery the server starts in a grace period: new opens can wait up to the NFSv4 lease
  time, 90 s by default. The rollback measures it.
- Impact: slowdown, then outage; no corrupted upload.

### How to run

```bash
bash scenario-09/09-audit.sh
bash scenario-09/09-simulate.sh
bash scenario-09/09-rollback.sh
```

### Troubleshooting (finding the cause)

- Never `ls` the uploads directory bare: use `timeout -s KILL 3`.
- `ps -eo pid,stat,wchan:32,cmd` shows processes in `D` waiting on RPC.
- `dmesg`: `server 192.168.20.21 not responding, still trying`.
- On `nfs01`: nothing on 2049, nothing exported.

### Root cause and fix

- NFS server stopped. Fix: start it; clients recover by themselves after the grace period.

### What it proves

- State D on NFS is a storage outage, not a PHP bug. `nfs01` is the documented SPOF (ADR-10).

---

## `scenario-10`: export revoked for one web node

### Scenario description

- Injected: `web02` removed from `/etc/exports` on `nfs01`, exports reloaded.
- After: `web02`'s mount still appears, but every access is refused at once. Users pinned to
  `web02` get broken images and failed uploads; users on `web01` are fine.
- The trap: both web nodes stay UP. "Some users, consistently" is the only symptom.
- Impact: roughly half the users lose images and uploads.

### How to run

```bash
bash scenario-10/10-audit.sh
bash scenario-10/10-simulate.sh      # -t web01 for the other node
bash scenario-10/10-rollback.sh
```

### Troubleshooting (finding the cause)

- Pin `SRV=w1` and `SRV=w2` with curl: one node fails.
- On `web02`: `Permission denied` or `Stale file handle`, immediately, not a hang.
- `exportfs -v` on `nfs01` lists one client; `ansible-playbook site.yml --check --diff --limit nfs01`
  shows the exact drift.

### Root cause and fix

- Export edited by hand. Fix: restore it (`--tags nfs`), remount if the handle went stale.

### What it proves

- An immediate refusal is a live server saying no; a hang is a dead server (09).
- `--check --diff` turns a hand edit into evidence.

---

## `scenario-11`: root filesystem full on one web node

### Scenario description

- Injected: files owned by `nobody` fill `/` on `web01` to 100% for non-root users.
- After: PHP cannot write the temporary file every upload passes through, so uploads through
  `web01` fail; pages still render.
- The trap: root keeps the ext4 reserved blocks, so SSH, sudo and "I can write as root" all
  work, and `/healthz.php` is green.
- This is the failure class that took the original single VPS down for three hours.

### How to run

```bash
bash scenario-11/11-audit.sh
bash scenario-11/11-simulate.sh
bash scenario-11/11-rollback.sh
```

### Troubleshooting (finding the cause)

- `df -h` **and** `df -i` on every web node.
- Write as `www-data`, not as root, to see what the service sees.
- `du -xh --max-depth=1 /`, `find -xdev -size +200M`, and `lsof +L1` for deleted-but-open files.

### Root cause and fix

- Disk full. Fix: remove the files; in real life, find the writer first.

### What it proves

- Disk usage needs an alert well before 100%; M8 requires exactly that.

---

## `scenario-12`: application grant on the wrong source address

### Scenario description

- Injected: the `wp` accounts renamed from the LB addresses to the web node addresses, the
  classic mistake of thinking MySQL sees the web nodes.
- After: every page shows `Error establishing a database connection`.
- The trap: every health check is green. None of them logs in as `wp`.
- Impact: total shop outage; no data at risk.

### How to run

```bash
bash scenario-12/12-audit.sh
bash scenario-12/12-simulate.sh
bash scenario-12/12-rollback.sh
```

### Troubleshooting (finding the cause)

- Connect as `wp` through the VIP by hand and read the 1045 error: the host in it is the LB.
- `SELECT user, host FROM mysql.user WHERE user = 'wp'`: right privileges, wrong hosts.
- `tcpdump` on `db01`: every SYN comes from `192.168.10.x`, never from the web nodes.

### Root cause and fix

- Through a TCP proxy, the source is the proxy (ADR-06). Fix: rename the accounts back.
  Never grant on `192.168.20.%`.

### What it proves

- The "source IP on database connections" trap in `architecture.md`, as a diagnosis exercise.

---

## `scenario-13`: the primary restarts and comes back read-only

### Scenario description

- Injected: `mysqld` on the primary SIGKILLed, then running again.
- After: it boots with `read_only` ON from its config (ADR-09). `mysqlchk` answers 503,
  HAProxy removes it, and with the replica in MAINT the `mysql` listener has no server.
- The trap: `systemctl status mysql` is green, uptime a few seconds, and the database is
  perfectly healthy.
- Impact: write path down until a human opens write.

### How to run

```bash
bash scenario-13/13-audit.sh
bash scenario-13/13-simulate.sh
bash scenario-13/13-rollback.sh      # runbook RB-04, with the fencing check
```

### Troubleshooting (finding the cause)

- Stats page: `L7STS/503`, so HAProxy was told "not writable".
- `SELECT @@read_only` is 1, `Uptime` is seconds; the journal shows the kill.
- Before opening write: is any other node writable? If yes, this is RB-03, not RB-04.

### Root cause and fix

- Fencing working as designed. Fix: RB-04, open write after checking every peer is read-only.

### What it proves

- Every restart needs a human, and that is the price of never having two writers.

---

## `scenario-14`: mysqlchk port filtered on a healthy primary

### Scenario description

- Injected: `inet lab_chaos` on the primary drops TCP 9200 from everything but loopback.
- After: HAProxy's check times out (`L4TOUT`), the primary is removed, writes stop.
- The trap: MySQL is up, writable and reachable on 3306; `mysqlchk` answers 200 locally.
- Impact: write path down while the database is fine.

### How to run

```bash
bash scenario-14/14-audit.sh
bash scenario-14/14-simulate.sh
bash scenario-14/14-rollback.sh
```

### Troubleshooting (finding the cause)

- `L4TOUT` (cannot ask) versus scenario 13's `L7STS/503` (was told no).
- Works on localhost, times out from outside, listening on the right address: a packet filter.
- `tcpdump` shows SYNs arriving and no SYN-ACK; `nft list ruleset` shows the extra table.

### Root cause and fix

- Filtered health check port. Fix: `nft delete table inet lab_chaos`.

### What it proves

- The health check is a dependency in its own right.

---

## `scenario-15`: replica down, semi-sync silently falls back to async

### Scenario description

- Injected: `systemctl stop mysql` on the replica.
- After: the next commit waits `rpl_semi_sync_source_timeout`, 3 s, once; then the primary
  switches to async and writes are fast again.
- The trap: the shop works, nobody files a ticket, yet every order counted in
  `Rpl_semi_sync_source_no_tx` now exists on one machine only.
- Impact: none visible; RPO=0 no longer holds until the replica returns.

### How to run

```bash
bash scenario-15/15-audit.sh
bash scenario-15/15-simulate.sh
bash scenario-15/15-rollback.sh
```

### Troubleshooting (finding the cause)

- `SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_source%'`: status OFF, clients 0, `no_tx` climbing.
- The primary's error log marks the moment with `Timeout waiting for reply of binlog`.
- `SHOW REPLICAS` is empty.

### Root cause and fix

- Replica stopped. Fix: start it; it catches up and semi-sync switches back on.

### What it proves

- ADR-08's cost: semi-sync degrades silently, so `Rpl_semi_sync_source_status` must be
  alerted on (M8, goal G5).

---

## `scenario-16`: the primary dies, manual failover

### Scenario description

- Injected: the primary powered off without a shutdown, like pulling its plug.
- Before: run `python3 scenario-16/16-order-writer.py`, which logs an order only after its
  commit returns.
- After: every write fails. Nothing fails over by itself (ADR-07): the replica is `disabled`
  in the `mysql` listener on purpose.
- The fix is runbook RB-02, entirely manual: rule out the router, prove the primary is
  fenced, wait for the replica to apply what it received, promote it, move HAProxy on both LBs.
- Impact: write outage for the time a human needs. RPO must be 0 while semi-sync was ON.

### How to run

```bash
python3 scenario-16/16-order-writer.py     # terminal 3, before anything else
bash scenario-16/16-audit.sh
bash scenario-16/16-simulate.sh
# follow RB-02 in 16-troubleshoot.md, then:
python3 scenario-16/16-rpo-check.py
# vagrant up db01 on Windows, then:
bash scenario-16/16-rollback.sh
```

### Troubleshooting (finding the cause)

- Ping the db zone gateway and the replica first: a routing outage must never trigger a
  promotion, both nodes could be alive and writable behind it.
- Fence: SSH and 3306 dead, `vagrant status` says `poweroff`.
- `SHOW REPLICA STATUS`: compare `Retrieved_Gtid_Set` and `Executed_Gtid_Set`, then
  `WAIT_FOR_EXECUTED_GTID_SET` before promoting.

### Root cause and fix

- Primary gone. Fix: RB-02 promotion, then RB-03 to return the old primary: the rollback
  checks for **errant GTIDs** before rejoining it, refuses if any exist, and offers a planned
  switchover back.

### What it proves

- Goals G7 and RPO=0: three drills give the mean RTO; `16-rpo-check.py` gives `rpo_missing`.
- Record per drill: RTO from the writer's `rto_ms`, `rpo_missing`, and whether semi-sync was ON.

---

## `scenario-17`: code drift between the web nodes

### Scenario description

- Injected: a small plugin copied onto `web01` only and activated with WP-CLI.
- After: activation is stored in the shared database, the code only on `web01`. Users pinned
  to `web01` get an extra `X-Lab-Drift` header; users on `web02` do not. An admin page view
  on `web02` may deactivate the plugin for everyone.
- The trap: every check is green, and `ansible-playbook --check` does not notice either,
  because the WordPress task is guarded by `creates`.
- Impact: inconsistent behaviour depending on which node serves the user.

### How to run

```bash
bash scenario-17/17-audit.sh
bash scenario-17/17-simulate.sh
bash scenario-17/17-rollback.sh
```

### Troubleshooting (finding the cause)

- Pin each node with the cookie and compare response headers.
- Hash the code tree on both nodes, then `diff` the per-file hash lists to find the extra files.
- `wp plugin list` reads the shared active list on both nodes; only one has the files.

### Root cause and fix

- A plugin installed from a shell on one node. Fix: deactivate and remove it.

### What it proves

- Why ADR-12 sets `DISALLOW_FILE_MODS`, and why drift detection must hash the tree.

---

## `scenario-18`: one web node loses its database path

### Scenario description

- Injected: `inet lab_chaos` on `web01` drops its outgoing connections to `VIP:3306`.
- After: every PHP page on `web01` fails with a database error; `web02` is fine.
  Anonymous users fail on every other request (round-robin); pinned users always or never.
- The trap: `/healthz.php` never touches the database, so HAProxy keeps `web01` in rotation.
  This is the blind spot ADR-05 accepts on purpose.
- Impact: about half the requests fail.

### How to run

```bash
bash scenario-18/18-audit.sh
bash scenario-18/18-simulate.sh
bash scenario-18/18-rollback.sh
```

### Troubleshooting (finding the cause)

- Pin each node: one always 500, one always 200.
- From each web node, test `VIP:3306` with `/dev/tcp`: blocked on one only.
- Route correct and ping working (unlike scenario 02); an unexpected nftables table on the
  `output` hook.

### Root cause and fix

- Outbound filter on one node. Fix: `nft delete table inet lab_chaos`.

### What it proves

- The trade-off of the shallow health check: one shared fault no longer drops every node,
  and a fault on one node goes unseen. The DB path needs its own check per web node.

---

## Measurements to record

Fill this from the audit summaries and the scenario 16 tools; never estimate.

| # | Detection time | Outage seen by users | Recovery time | Notes |
|---|---|---|---|---|
| 04 | | | | VIP move and preempt return, both |
| 07 | | | | target: about 6 s |
| 09 | | | | includes the NFS grace period |
| 13 | | | | human time to RB-04 |
| 16 | | | | RTO from `rto_ms`, `rpo_missing` from the check |
