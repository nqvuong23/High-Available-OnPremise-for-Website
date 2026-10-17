# Scenario 13 — troubleshooting: MySQL is running, the shop cannot write

> Do not read **Root cause** until your own diagnosis is finished. Run every command by hand.

## What you see

- Pages fail with a database error; orders cannot be placed.
- `systemctl status mysql` on the primary is green and its uptime is a few seconds.
- The stats page shows the primary DOWN in the `mysql` listener, and the replica in MAINT.

## Step 1 — read why HAProxy dropped the primary

```bash
source ~/.lab/secrets.env
curl -s -u "$LAB_STATS_USER:$LAB_STATS_PASS" 'http://192.168.10.11:8404/stats;csv' \
  | awk -F, '$1=="mysql"' | cut -d, -f2,18,37,38
```

`L7STS` with code 503: HAProxy reached `mysqlchk` and was told "not writable". The network
and the port are fine; this is a database state.

## Step 2 — ask mysqlchk and MySQL directly

```bash
curl -s http://192.168.30.11:9200/; echo
mysql --defaults-extra-file=~/.lab/ops.cnf -h 192.168.30.11 -e \
  "SELECT @@hostname, @@read_only, @@super_read_only; SHOW GLOBAL STATUS LIKE 'Uptime'"
```

`read_only = 1` and an uptime of seconds: the server restarted and came back read-only.

## Step 3 — why did it restart?

```bash
ssh db01 'sudo journalctl -u mysql --since "-30 min" --no-pager | tail -15'
ssh db01 'sudo tail -n 20 /var/log/mysql/error.log'
```

Look for `Main process exited, code=killed, status=9/KILL` and InnoDB crash recovery lines.

## Step 4 — is it safe to open write? (RB-04)

The only question that matters before opening write: is any **other** node writable?

```bash
for db in 192.168.30.11 192.168.30.12; do
  mysql --defaults-extra-file=~/.lab/ops.cnf -h $db -N -e "SELECT @@hostname, @@read_only"
done
mysql --defaults-extra-file=~/.lab/ops.cnf -h 192.168.30.12 -e 'SHOW REPLICA STATUS\G' \
  | grep -E 'Source_Host|Running:|Seconds_Behind|Last_IO_Error:'
```

`db02` must be read-only and still a replica of `db01`. If `db02` is writable, someone already
failed over: stop, this is now runbook RB-03, not RB-04.

---

## Root cause

`mysqld` on the primary was killed and restarted. Its config file sets `read_only` and
`super_read_only` ON (ADR-09), so it came back read-only. `mysqlchk` therefore answers 503,
HAProxy takes the node out, and with the replica in MAINT the `mysql` listener has no server.
Nothing is broken: fencing is doing exactly what it was designed to do.

## Fix — runbook RB-04

```bash
mysql --defaults-extra-file=~/.lab/ops.cnf -h 192.168.30.11 -e \
  "SET GLOBAL super_read_only = OFF; SET GLOBAL read_only = OFF"
```

Or `bash 13-rollback.sh`, which refuses if another node is writable. HAProxy marks the node
UP after `rise 2`. The replica's IO thread reconnects within `SOURCE_CONNECT_RETRY`, 10 s.

## Lesson

- A healthy, running, read-only MySQL is indistinguishable from an outage to the application.
- Booting read-only means every restart, planned or not, needs a human. That is the cost of
  never having two writers, and RB-04 is the price list.
- The fencing check before opening write is the step that cannot be skipped.
