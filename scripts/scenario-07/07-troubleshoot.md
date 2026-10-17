# Scenario 07 — troubleshooting: one web node is DOWN on the stats page

> Do not read **Root cause** until your own diagnosis is finished. Run every command by hand.

## What you see

- The stats page shows one web node DOWN; the site still serves from the other.
- Even a user whose sticky cookie points at the broken node keeps getting pages.

## Step 1 — rule out the router

```bash
ping -c1 192.168.20.11 && ping -c1 192.168.20.12
```

## Step 2 — read the reason, not just the colour

```bash
source ~/.lab/secrets.env
curl -s -u "$LAB_STATS_USER:$LAB_STATS_PASS" 'http://192.168.10.11:8404/stats;csv' \
  | awk -F, 'NR==1 || $1=="be_web"' | cut -d, -f1,2,18,22,24,37,38
```

| check_status | Meaning |
|---|---|
| `L4CON` | connection refused: nothing listening on the port |
| `L4TOUT` | no answer at all: dropped on the way, or the host is gone |
| `L7STS` | it answered, with a bad HTTP status (see `check_code`) |

`chkdown` counts DOWN transitions and `lastchg` the seconds since the last one.

## Step 3 — test the node from outside the LB

```bash
curl -sI http://192.168.20.11/healthz.php
nc -zv -w2 192.168.20.11 80
```

`Connection refused` arrives instantly: the host is up and actively refusing port 80.

## Step 4 — on the node

```bash
ssh web01 'systemctl status nginx --no-pager | head -8'
ssh web01 'sudo ss -ltnp | grep ":80 "'
ssh web01 'sudo journalctl -u nginx -n 20 --no-pager'
ssh web01 'sudo nginx -t'
```

`nginx -t` passing tells you a start will succeed; failing tells you why it stopped.

## Step 5 — how long did HAProxy take?

```bash
ssh lb01 'sudo grep -E "web01 is (DOWN|UP)" /var/log/haproxy.log | tail -4'
```

Compare that timestamp with the `[MARK]` line on the audit.

---

## Root cause

Nginx was stopped on `web01`. HAProxy's check got `connection refused` (`L4CON`) and,
after `fall 3` checks at `inter 2s`, marked the node DOWN, about 6 seconds. `option
redispatch` with `retries 3` moved even cookie-pinned users to the other node, so users saw
no error during the detection window.

## Fix

```bash
ssh web01 'sudo nginx -t && sudo systemctl start nginx'
```

Or `bash 07-rollback.sh`. HAProxy needs `rise 2` passing checks, about 4 seconds.

## Lesson

- Read `check_status` before touching anything: refused, timed out and wrong status are
  three different faults on three different layers.
- The 6 second figure is the product of `inter` and `fall`. Change either and the SLO moves.
- Compare with scenario 08, where the node is DOWN for a very different reason.
