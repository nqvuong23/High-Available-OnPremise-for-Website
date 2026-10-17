# Scenario 12 — troubleshooting: "Error establishing a database connection", all green

> Do not read **Root cause** until your own diagnosis is finished. Run every command by hand.

## What you see

- Every page shows WordPress's `Error establishing a database connection`, HTTP 500.
- Both web nodes are UP on the stats page, `db01` is UP in the `mysql` listener.
- `mysqlchk` returns 200 on the primary. By every health check, nothing is wrong.

## Step 1 — reproduce the application's connection by hand

The application connects as `wp` through the VIP. Do exactly that from `mgmt01`:

```bash
mysql --defaults-extra-file=~/.lab/wp.cnf -e 'SELECT @@hostname'
```

Read the error word by word: `Access denied for user 'wp'@'192.168.10.11'`. The address in
the quotes is the source **MySQL saw**. It is an LB address, not `mgmt01` and not a web node.

## Step 2 — the same from a web node

```bash
ssh web01 'php -r "mysqli_report(MYSQLI_REPORT_OFF); \$m = @new mysqli(\"192.168.10.100\", \"wp\", \"x\", \"wordpress\", 3306); echo \$m->connect_error, PHP_EOL;"'
```

A wrong password here is fine: you only want the address in the error, and it is again the
LB's. Every connection through HAProxy arrives from the LB holding the VIP.

## Step 3 — which accounts exist?

```bash
mysql --defaults-extra-file=~/.lab/ops.cnf -h 192.168.30.11 -e \
  "SELECT user, host FROM mysql.user WHERE user = 'wp'"
mysql --defaults-extra-file=~/.lab/ops.cnf -h 192.168.30.11 -e "SHOW GRANTS FOR 'wp'@'192.168.20.11'"
```

The accounts exist, with the right privileges, for the wrong hosts.

## Step 4 — prove the source address on the wire

No login through the VIP succeeds right now, so the server keeps no session to look at.
Watch the connection attempts arrive instead:

```bash
ssh db01 'sudo tcpdump -ni any "tcp dst port 3306 and tcp[tcpflags] & tcp-syn != 0" -c 4'
```

Reload the shop in a browser while it runs. Every SYN comes from `192.168.10.11` or `.12`,
never from `192.168.20.x`: the web nodes never talk to MySQL directly.

---

## Root cause

The `wp` accounts were renamed from `'wp'@'192.168.10.11'` and `'wp'@'192.168.10.12'` to the
web node addresses. HAProxy proxies MySQL in TCP mode, so the server sees the LB address as
the client (architecture.md, "source IP on database connections"). No account matches, so
every application login fails, while every health check, none of which logs in as `wp`,
stays green.

## Fix

```bash
bash 12-rollback.sh
```

Never "fix" it by granting `wp` on `192.168.20.%`: if that makes the site work, traffic is
bypassing the LB.

## Lesson

- Error 1045 names the host MySQL matched against. Read it before reading any grant.
- Through a TCP proxy, the source is the proxy. That is the design, not a bug.
- Health checks that never authenticate as the application cannot see an authentication outage.
