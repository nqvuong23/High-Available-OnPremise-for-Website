# Scenario 14 — troubleshooting: the database is fine, HAProxy says it is DOWN

> Do not read **Root cause** until your own diagnosis is finished. Run every command by hand.

## What you see

- The write path is down; pages fail with a database error.
- MySQL on the primary is running, writable, and accepts direct connections on 3306.
- The stats page shows the primary DOWN.

## Step 1 — the reason HAProxy gives

```bash
source ~/.lab/secrets.env
curl -s -u "$LAB_STATS_USER:$LAB_STATS_PASS" 'http://192.168.10.11:8404/stats;csv' \
  | awk -F, '$1=="mysql"' | cut -d, -f2,18,37,38
```

`L4TOUT`: HAProxy's TCP connection to the **check port** never completed. Compare with
scenario 13, where the check port answered 503. Different layer, different fault.

## Step 2 — is the database itself healthy?

```bash
mysql --defaults-extra-file=~/.lab/ops.cnf -h 192.168.30.11 -e "SELECT @@hostname, @@read_only"
nc -zv -w2 192.168.30.11 3306
```

Writable and reachable. The traffic path HAProxy uses for queries works; only its health
check fails. HAProxy routes on the check, not on the database.

## Step 3 — the check port, from outside and from inside

```bash
curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://192.168.30.11:9200/     # from mgmt01
ssh db01 'curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:9200/'
ssh db01 'sudo ss -ltn | grep 9200'
```

Times out from outside, answers 200 locally, and the socket is listening. Something between
the NIC and the socket drops the packets.

## Step 4 — see the packet arrive and go unanswered

```bash
ssh db01 'sudo tcpdump -ni any tcp port 9200 -c 6'
```

SYNs arrive from `192.168.10.11` and `.12`; no SYN-ACK leaves. tcpdump sees packets before
any netfilter hook, so the drop is a local filter.

## Step 5 — find the filter

```bash
ssh db01 'sudo nft list ruleset'
```

A db node should carry an empty ruleset: the lab runs no host firewall, so any table here
is the fault. See ADR-25.

---

## Root cause

An nftables table `inet lab_chaos` on the primary drops TCP 9200 from every interface but
loopback. MySQL and `mysqlchk` are both healthy; HAProxy simply cannot ask, times out, and
removes the only enabled server from the `mysql` listener.

## Fix

```bash
ssh db01 'sudo nft delete table inet lab_chaos'
```

Or `bash 14-rollback.sh`.

## Lesson

- `L4TOUT` versus `L7STS 503` separates "cannot ask" from "was told no". Read it first.
- A health check is a dependency in its own right: block it and a healthy service is removed.
- "Works from localhost, times out from outside, listening on the right address" is a
  packet filter, every time.
