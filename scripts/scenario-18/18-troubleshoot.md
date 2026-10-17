# Scenario 18 — troubleshooting: half the requests fail, every check is green

> Do not read **Root cause** until your own diagnosis is finished. Run every command by hand.

## What you see

- About every second anonymous request shows `Error establishing a database connection`.
- Logged-in users either always fail or never fail, depending on who they are.
- Both web nodes are UP, the primary is UP, `mysqlchk` says 200.

## Step 1 — which node fails?

```bash
for c in w1 w2; do printf '%s ' $c; curl -s -o /dev/null -w '%{http_code}\n' -b "SRV=$c" https://shop.lab.internal/; done
```

One cookie always gets 500, the other always 200. Anonymous users alternate because HAProxy
round-robins them. The fault is one node.

## Step 2 — why is that node still in rotation?

```bash
curl -s http://192.168.20.11/healthz.php
```

`ok`. The health check proves Nginx reaches PHP-FPM and nothing more (ADR-05). This is the
exact blind spot that ADR accepts on purpose.

## Step 3 — can that node reach the database path?

```bash
ssh web01 'timeout 3 bash -c "</dev/tcp/192.168.10.100/3306" && echo open || echo blocked'
ssh web02 'timeout 3 bash -c "</dev/tcp/192.168.10.100/3306" && echo open || echo blocked'
```

Blocked from one, open from the other. Same zone, same router, same VIP: the difference has
to be on the node itself.

## Step 4 — routing or filtering?

```bash
ssh web01 'ip route get 192.168.10.100'
ssh web01 'ping -c1 -W1 192.168.10.100'
ssh web01 'sudo nft list ruleset'
```

The route is right and ping works (compare with scenario 02, where the route was the
problem). A web node should carry an empty ruleset, so look for the table that is there at
all, and note it sits on the **output** hook. See ADR-25.

## Step 5 — confirm on the wire

```bash
ssh web01 'sudo tcpdump -ni any host 192.168.10.100 and port 3306 -c 4'
```

With an output drop, nothing leaves at all: the SYN is discarded before it reaches the NIC.

---

## Root cause

An nftables table `inet lab_chaos` on `web01` drops its outgoing connections to
`192.168.10.100:3306`. Every PHP page on `web01` fails to connect to MySQL; `/healthz.php`
never connects, so HAProxy keeps `web01` in rotation and roughly half the traffic fails.

## Fix

```bash
ssh web01 'sudo nft delete table inet lab_chaos'
```

Or `bash 18-rollback.sh`.

## Lesson

- A shallow health check trades "one shared fault drops every node" for "a fault on one node
  goes unseen". ADR-05 chose the second; this is its price, and why the DB path needs its own
  check per web node in `healthcheck.py`.
- Pin a cookie to turn "some requests fail" into "this node fails".
- Same symptom as scenario 02 from the user's side, different layer: route versus filter.
