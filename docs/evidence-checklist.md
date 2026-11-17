# Screenshot checklist, one entry per failure scenario

What to capture while running each scenario, so the root `README.md` has evidence instead of
claims. Naming and image rules live in [images/README.md](images/README.md); this file only
says **what the picture must contain**.

## The standard four shots

Every scenario gets the same four, in this order. Three are mechanical, one is scenario
specific.

| Shot | File | Taken when | Must contain |
|---|---|---|---|
| A | `NN-baseline.png` | after `NN-audit.sh` starts, before `NN-simulate.sh` | several `[OK]` ticks with the clock column, so the measurement provably started before the fault |
| B | `NN-fault.png` | right after the `[MARK]` line | the `[MARK]`, the `[EVENT]` state change, **and the check that stayed green** on the same screen |
| C | `NN-proof.png` | during manual diagnosis | the one command that names the root cause, listed per scenario below |
| D | `NN-summary.png` | after rollback, on Ctrl-C | the recovery `[EVENT]` with its duration, plus the summary table |

Shot B is the one that carries the project. The point of each scenario is that something
stayed green while users suffered, so a screenshot of only the red line proves nothing. Keep
the failing probe and the misleading-green probe in the same frame.

Shot D is the source of every number in the README tables. Without it a number is an estimate.

Three scenarios already have file names hard-coded in the root README; keep those and add the
missing ones:

- `scenario-04`: `04-baseline.png`, `04-failover.png` (= shot B), then `04-proof.png`, `04-summary.png`
- `scenario-07`: `07-baseline.png`, `07-node-down.png` (= shot B), then `07-proof.png`, `07-summary.png`
- `scenario-16`: `16-baseline.png`, `16-primary-down.png` (= shot B), `16-failover.png` (= shot C), `16-summary.png`

## Shot C per scenario

The command whose output is the root cause. Capture the command line too, not only its output.

| # | Shot C command | Shot B must also show |
|---|---|---|
| 01 | `sysctl net.ipv4.ip_forward` reading 0 next to `grep -r ip_forward /etc/sysctl.d/` reading 1 | `ping 192.168.20.254` from `mgmt01` still answering while every backend is DOWN |
| 02 | `ip route get 192.168.10.11` and `ip route get 172.16.10.11` on `web01`, side by side | `L4TOUT` on the stats page while SSH and `/healthz.php` from `mgmt01` still work |
| 03 | `ss -ulnp sport = :53` on `fw01` empty, plus `dig @172.16.10.254 shop.lab.internal` timing out | `curl --resolve shop.lab.internal:443:192.168.10.100` returning 200: the shop is fine |
| 04 | `/usr/local/bin/chk_haproxy.sh; echo $?` on the old master, and `journalctl -u keepalived \| grep MASTER` on `lb02` | the VIP leaving `lb01` and arriving on `lb02`, with the failed-request ticks between |
| 05 | `nft list ruleset` on the backup showing a table at all, next to `ip -4 addr` showing the VIP on **both** LBs | `ip neigh show 192.168.10.100` on `fw01`, and a `tcpdump` that sees the adverts the daemon never got |
| 06 | `openssl s_client -connect ... \| openssl x509 -noout -subject -ext subjectAltName` showing the wrong SAN under a trusted issuer | `curl -k` returning 200 and every backend UP while `curl` exits 60 |
| 07 | `systemctl status nginx` and `ss -ltnp` on `web01`, plus `check_status` `L4CON` on the stats page | the site still 200 **and** the `pinned-web01` probe still 200, proving redispatch worked |
| 08 | the Nginx error log line naming the socket, next to `ls -l /run/php/` | a static file 200 from `web01` while `/healthz.php` on it is 502 and `systemctl status nginx` is green |
| 09 | `ps -eo pid,stat,wchan:32,cmd` showing `D` state, plus `dmesg \| tail` with "not responding, still trying" | both web nodes still UP in HAProxy while requests hang; shot D must include the grace-period wait |
| 10 | `exportfs -v` on `nfs01` listing one client, and `ansible-playbook site.yml --check --diff --limit nfs01` showing the drift | the `SRV=w1` probe 200 and the `SRV=w2` probe failing, both nodes UP |
| 11 | `df -h` and `df -i`, plus a write attempted as `www-data` failing while a root write succeeds | `/healthz.php` green and SSH working on a node at 100% |
| 12 | the manual `mysql -h 192.168.10.100 -u wp` error 1045 showing the **LB** address as the host, next to `SELECT user, host FROM mysql.user WHERE user='wp'` | every HAProxy check and `mysqlchk` green while every page shows the WordPress DB error |
| 13 | `SELECT @@read_only, @@super_read_only` returning 1, with `SHOW GLOBAL STATUS LIKE 'Uptime'` in seconds | `systemctl status mysql` green while the stats page shows `L7STS/503` and the `mysql` listener has no server |
| 14 | `curl -s -o /dev/null -w '%{http_code}' localhost:9200` returning 200 on the node, timing out from `mgmt01`, plus `nft list ruleset` | MySQL writable on 3306 while HAProxy reports `L4TOUT`; contrast the status code with scenario 13 |
| 15 | `SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_source%'` with status OFF, clients 0, `no_tx` above 0 | the shop still 200 on every probe: nothing visible, which is the whole point |
| 16 | the RB-02 steps in the terminal: fencing check, `Retrieved_Gtid_Set` vs `Executed_Gtid_Set`, `WAIT_FOR_EXECUTED_GTID_SET`, then the HAProxy switch on both LBs | the writer losing its commits at the moment the primary dies; shot D must also include `16-rpo-check.py` output with `rpo_missing` and the writer's `rto_ms` |
| 17 | the two per-file hash lists `diff`ed, showing the extra plugin files on `web01` only, next to `wp plugin list` reading the same active list on both nodes | the `X-Lab-Drift` header present on the `web01`-pinned request and absent on the `web02` one, with every check green |
| 18 | `nft list ruleset` on `web01` showing a table on the `output` hook, plus the `/dev/tcp` test to `VIP:3306` blocked on `web01` and open on `web02` | `web01` still UP in HAProxy while the `web01`-pinned probe is 500 and the `web02`-pinned probe is 200 |

## Extra captures that are not per scenario

| Path | What it shows |
|---|---|
| `architecture/verify-green.png` | a full `ansible-playbook verify.yml` run, every check `[OK]`, taken before the first scenario |
| `architecture/idempotent.png` | the second `ansible-playbook site.yml` run with `changed=0`, goal G8 |
| `architecture/no-firewall.png` | `nft list ruleset` empty on a non-router node and `ip router_nat` only on `fw01`, ADR-25 |
| `architecture/routed-hop.png` | `traceroute -n 192.168.30.11` from `web01` showing one hop at `192.168.20.254` |
| `scenario-16/16-rto-table.png` | the three drills side by side, mean RTO under 5 minutes, goal G7 |

## Before each run

- `ansible-playbook verify.yml` green, snapshot taken. A baseline shot from an unknown state is worthless.
- Terminal wide enough that no dashboard line wraps, and the clock column visible.
- Scenarios 05, 14 and 18 inject an nftables table. Shot D must include `nft list ruleset`
  coming back empty, or the rollback is not proven.
- Scenario 16 needs `16-order-writer.py` running in a third terminal before anything else, and
  `db01` and `db02` restored together.
