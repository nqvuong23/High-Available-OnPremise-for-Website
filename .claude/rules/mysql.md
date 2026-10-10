---
paths:
  - "ansible/roles/mysql/**"
  - "ansible/roles/mysqlchk/**"
  - "scripts/**"
  - "docs/runbooks/**"
---

# MySQL 8.4: replication, semi-sync and failover

> This layer holds the money data. Every decision here favours safety over speed.
> Both DB nodes run Ubuntu 24.04 in the db zone, `192.168.30.11` and `192.168.30.12`.

## Mandatory safety rules

- **Never fail over automatically.** Every promote requires explicit human confirmation.
- **Never let both nodes be writable.** Before promoting, be certain the old primary is dead or powered off.
- Every node always boots with `super_read_only=ON`; write access is only opened at runtime.
- Before letting an old primary rejoin as a replica, **always check for errant GTIDs** with `GTID_SUBTRACT`.
- Semi-sync can silently downgrade to async when the replica is gone past the timeout; monitor `Rpl_semi_sync_source_status`, otherwise the RPO=0 promise no longer holds.
- `auto_remediate.sh` must never restart or otherwise touch MySQL.

## Installation on Ubuntu 24.04

- Ubuntu 24.04 ships MySQL 8.0 in its own repository. Hold or avoid that package so apt cannot pull it in instead of 8.4.
- Add the official Oracle APT repository for the `mysql-8.4-lts` track, install its signing key, then install `mysql-community-server`.
- Install `python3-pymysql` so `community.mysql` modules work.
- Bootstrap: Debian-family packages start MySQL with an empty root password over the unix socket rather than writing a temporary password to the log. Set the password from Vault on first run and write `/root/.my.cnf` with mode 600.
- The Debian-family package also installs its own `debian.cnf` maintenance account; keep it consistent with the Vault password or maintenance scripts will fail after a password change.
- AppArmor confines `mysqld` through `/etc/apparmor.d/usr.sbin.mysqld`. Any datadir or log path moved outside the default needs an AppArmor rule, or startup fails with a permission error that looks nothing like a permission problem.

## Core configuration

- Identity and binlog: a distinct `server_id` on each node, `log_bin` on, `binlog_format=ROW`.
- GTID: `gtid_mode=ON` and `enforce_gtid_consistency=ON`.
- Durability: `sync_binlog=1` and `innodb_flush_log_at_trx_commit=1`, never lowered for performance.
- Read-only at boot: `read_only=ON` and `super_read_only=ON` in the config file of **both** nodes.
- Others: `relay_log_recovery=ON`, `skip_name_resolve`, `event_scheduler=ON` for the heartbeat.
- `bind_address` listens on the zone IP and loopback only; nothing binds the NAT NIC.
- Buffer pool around half the node RAM, so roughly 768 MB on a 1536 MB node.

## Semi-sync

- Load the plugins with `plugin_load_add` for `semisync_source.so` and `semisync_replica.so`.
- Enable **both** roles on **both** nodes so a role swap needs no extra plugin install.
- Set `rpl_semi_sync_source_wait_point=AFTER_SYNC` and `rpl_semi_sync_source_timeout=3000`.
- Verify: `Rpl_semi_sync_source_status` must be `ON` and `Rpl_semi_sync_source_clients` must be 1.

## MySQL 8.4 syntax

- These statements are **removed** and will raise a syntax error: `CHANGE MASTER TO`, `START SLAVE`, `STOP SLAVE`, `SHOW SLAVE STATUS`, `RESET MASTER`, `SHOW MASTER STATUS`, the `MASTER_*` options, and `IGNORE_SERVER_IDS`.
- Use instead: `CHANGE REPLICATION SOURCE TO` with `SOURCE_*` options, `START REPLICA`, `STOP REPLICA`, `SHOW REPLICA STATUS`, `RESET BINARY LOGS AND GTIDS`, `SHOW BINARY LOG STATUS`.
- Default authentication is `caching_sha2_password`; `mysql_native_password` is disabled by default.
- The replication user therefore needs `GET_SOURCE_PUBLIC_KEY=1`, or TLS must be enabled.

## Accounts

- The application user, the replication user and the operator user are granted on `192.168.10.%` or on exactly the two LB addresses `192.168.10.11` and `192.168.10.12`.
- Reason: connections pass through HAProxy, so MySQL sees the LB IP as the source, not the web node IP and not the VIP.
- Do **not** grant the application user on `192.168.20.%`. Web nodes never connect directly; if that grant makes things work, the traffic is bypassing the LB and the design is broken.
- The replication user is granted between the two db-zone addresses, since replication stays inside the db zone.
- The `mysqlchk` user only needs to read status variables and should be limited to `localhost`.

## mysqlchk

- Listens on port 9200, returns HTTP 200 when the node is writable and 503 when it is read-only.
- Condition for a 200: both `@@read_only` and `@@super_read_only` are 0.
- Implement it with a systemd socket unit to keep it light; no web server needed.
- Port 9200 must be open to the two LB addresses only, and never on the NAT NIC.

## Acceptance

- Write on the primary, then read it on the replica.
- A direct write to the replica must be refused with error 1290.
- `SHOW REPLICA STATUS` shows `Replica_IO_Running` and `Replica_SQL_Running` both `Yes`.
- Reboot each DB node; both must come back read-only.
- `curl localhost:9200` returns 200 on the primary and 503 on the replica.
- From a web node, `mysql -h 192.168.10.100` connects, while `mysql -h 192.168.30.11` is blocked by the firewall.

## Failover drills

- Run `order_writer.py` to create orders continuously, logging an ID only **after** the commit succeeds.
- Hard power off the primary VM with `vagrant halt --force db01` to simulate sudden death.
- Follow runbook RB-02, time it to get the RTO, then run `rpo_check.py` to get the RPO.
- Repeat at least 3 times with semi-sync, plus one run with async to build the comparison table.
- Note in each postmortem whether the router was in the path for that drill, since two routed hops are part of the measured RTO.
