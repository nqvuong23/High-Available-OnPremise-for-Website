# Scenario 05 — troubleshooting: the site flaps, and both LBs say they are MASTER

> Do not read **Root cause** until your own diagnosis is finished. Run every command by hand.

## What you see

- Requests mostly work, with odd stalls or resets.
- `vip-owner` on the audit shows `SPLIT lb01 lb02`: the VIP is configured on both nodes.
- The router's ARP entry for the VIP points at one LB, sometimes jumping to the other.

## Step 1 — confirm the split brain

```bash
for lb in lb01 lb02; do echo "== $lb"; ssh $lb 'ip -4 -brief addr show | grep 192.168.10.100'; done
ssh fw01 'ip neigh show 192.168.10.100'
for lb in lb01 lb02; do echo "== $lb"; ssh $lb 'cat /sys/class/net/*/address'; done
```

Two holders of one address is a duplicate IP on the segment. Whichever node answered ARP
last gets the traffic; that is what the router's `lladdr` tells you.

## Step 2 — what does each Keepalived believe?

```bash
for lb in lb01 lb02; do echo "== $lb"; ssh $lb 'sudo journalctl -u keepalived --since "-15 min" --no-pager | grep -E "STATE|Received"'; done
```

The backup logged `Entering MASTER STATE` without the master ever leaving. A BACKUP only
promotes itself when it stops **hearing** advertisements.

## Step 3 — are the advertisements on the wire?

```bash
ssh lb02 'sudo tcpdump -ni any vrrp -c 6'
```

You see `lb01`'s advertisements arriving at `lb02`. Important: tcpdump captures **before**
the firewall, so "tcpdump sees it but the daemon does not" means something between the NIC
and the process is dropping it.

## Step 4 — what is in between?

```bash
ssh lb02 'sudo nft list ruleset'
ssh lb02 'systemctl is-active nftables; command -v ufw || echo "ufw not installed"'
```

An LB should carry an **empty** ruleset: the lab runs no host firewall, so any table at
all is a finding. Look for a rule that matches protocol 112. See ADR-25.

## Step 5 — is multicast itself working?

```bash
ssh lb02 'ip maddr show | grep -B2 224.0.0.18'
```

The group is joined, so the problem is not the switch or the NIC.

---

## Root cause

An nftables table `inet lab_chaos` on the backup LB drops IP protocol 112 on input. The
backup no longer hears the master's advertisements, declares the master dead after
`3 × advert_int` plus skew, and claims the VIP. The master hears nothing contradicting it
from a lower priority and keeps the VIP too.

## Fix

```bash
ssh lb02 'sudo nft delete table inet lab_chaos'
```

Or `bash 05-rollback.sh`. As soon as advertisements arrive, the backup sees a higher
priority and releases the VIP.

## Verify

```bash
for lb in lb01 lb02; do ssh $lb 'ip -4 -brief addr show | grep -c 192.168.10.100'; done   # 1 then 0
```

## Lesson

- VRRP has no quorum: silence is read as death, so a filtering mistake produces two masters.
- `tcpdump` sees packets before any netfilter hook. "Seen on the wire, ignored by the daemon"
  points at a filter, never at the network.
- The lab deliberately runs no host firewall, so a non-empty ruleset on an LB is itself the
  answer. That is the whole reason this fault is diagnosable in one command.
