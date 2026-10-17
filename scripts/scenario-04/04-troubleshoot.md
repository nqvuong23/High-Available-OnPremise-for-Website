# Scenario 04 — troubleshooting: the active load balancer lost HAProxy

> Do not read **Root cause** until your own diagnosis is finished. Run every command by hand.

## What you see

- A short burst of failed requests on the audit, then the site works again by itself.
- The VIP owner column changes from one LB to the other.
- Nobody touched the backup LB, yet it now carries all the traffic.

## Step 1 — rule out the router

```bash
ping -c1 192.168.10.254 && ping -c1 192.168.10.11 && ping -c1 192.168.10.12
```

Both LBs answer, so the path into the dmz zone is fine.

## Step 2 — who holds the VIP now, and since when?

```bash
for lb in lb01 lb02; do echo "== $lb"; ssh $lb 'ip -4 -brief addr show | grep 192.168.10.100'; done
ssh lb02 'sudo journalctl -u keepalived --since "-10 min" --no-pager | grep -E "STATE|priority"'
```

`Entering MASTER STATE` on the backup, with the timestamp. That timestamp minus the moment
the failure started is your failover time.

## Step 3 — why did the old master give it up?

```bash
ssh lb01 'sudo journalctl -u keepalived --since "-10 min" --no-pager | grep -iE "chk_haproxy|priority|BACKUP"'
ssh lb01 'sudo /usr/local/bin/chk_haproxy.sh; echo "check exit code: $?"'
```

The track script failed `fall 2` times, so `weight -20` took the priority from 110 to 90,
below the backup's 100. Keepalived itself is still running: it moved the VIP on purpose.

## Step 4 — what is wrong with HAProxy there?

```bash
ssh lb01 'systemctl status haproxy --no-pager | head -8'
ssh lb01 'sudo ss -ltnp | grep -E ":(80|443|3306|8404) "'
ssh lb01 'sudo journalctl -u haproxy -n 20 --no-pager'
```

## Step 5 — see the VRRP decision on the wire

```bash
ssh lb02 'sudo tcpdump -ni any vrrp -c 6'
```

Each advertisement carries the sender and its priority. Only the node with the highest
priority keeps sending.

---

## Root cause

HAProxy was stopped on the LB holding the VIP. Keepalived's `chk_haproxy` asks
`http://127.0.0.1/haproxy-alive`, which only HAProxy itself answers, so a stopped (or hung)
HAProxy fails the check even though the machine and Keepalived are healthy. The priority
drop handed the VIP to the backup within a few seconds, as designed in ADR-03.

## Fix

```bash
ssh lb01 'sudo systemctl start haproxy'
```

Or `bash 04-rollback.sh`. Preempt is on, so the VIP returns to `lb01` as soon as its check
passes `rise 2` times — a second, shorter interruption. Record both numbers.

## Verify

```bash
ssh lb01 'ip -4 -brief addr show | grep 192.168.10.100'
curl -sI https://shop.lab.internal | head -1
```

## Lesson

- The check proves HAProxy *serves*, not that the process exists; a hung process would fail
  it the same way.
- Two interruptions per incident with preempt on: one when the master fails, one when it
  returns. That is the cost written next to ADR-03.
- Measure with the audit running before the failure, never from memory afterwards.
