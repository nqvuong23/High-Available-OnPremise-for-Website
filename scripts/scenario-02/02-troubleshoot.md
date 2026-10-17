# Scenario 02 — troubleshooting: a web node is DOWN but looks healthy

> Do not read **Root cause** until your own diagnosis is finished. Run every command by hand.

## What you see

- The site still works through the VIP: the other web node carries everything.
- The HAProxy stats page shows one web node DOWN with `L4TOUT` (layer 4 timeout).
- From `mgmt01`, that same node answers `/healthz.php` perfectly and SSH works.

## Step 1 — read the exact reason HAProxy gives

```bash
source ~/.lab/secrets.env
curl -s -u "$LAB_STATS_USER:$LAB_STATS_PASS" 'http://192.168.10.11:8404/stats;csv' \
  | awk -F, 'NR==1 || $1=="be_web"' | cut -d, -f1,2,18,37,38
```

`L4TOUT` means HAProxy's TCP connection never completed. Not refused (that would be
`L4CON`), not a bad HTTP answer (`L7STS`). Something is eating packets.

## Step 2 — is the service really up?

```bash
curl -s http://192.168.20.11/healthz.php        # from mgmt01
ssh web01 'systemctl is-active nginx php8.3-fpm'
```

It answers `ok` to `mgmt01`. So Nginx works, and the difference is **who is asking**:
`mgmt01` (client zone) succeeds, the LB (dmz zone) times out.

## Step 3 — ping the LB from the web node

```bash
ssh web01 'ping -c2 -W1 192.168.10.11; ping -c2 -W1 192.168.20.12; ping -c2 -W1 192.168.20.254'
```

Its own zone answers, the dmz zone does not. "Reaches its own zone but nothing else"
reads like a firewall rule. The lab runs none (ADR-25), so `sudo nft list ruleset` rules
that out in one command and the answer has to be routing.

## Step 4 — which way does the reply leave?

```bash
ssh web01 'ip route get 192.168.10.11'
ssh web01 'ip route'
```

Compare with `ip route get 172.16.10.11`. One goes `via 192.168.20.254` on the zone NIC,
the other leaves through the NAT NIC towards `10.10.10.2`. Look for the missing line.

## Step 5 — prove it on the wire

```bash
ssh web01 'sudo tcpdump -ni any tcp port 80 and host 192.168.10.11 -c 6'
```

The SYN arrives on the zone NIC; the SYN-ACK leaves on the NAT NIC. The LB never gets
the reply, so its check times out: asymmetric routing.

## Step 6 — what should the routes be?

```bash
ssh web01 'sudo cat /etc/netplan/60-vagrant.yaml'
ssh web01 'networkctl status | head -30'
```

---

## Root cause

The route `192.168.10.0/24 via 192.168.20.254` was removed from `web01`. Requests from the
LBs still arrive through `fw01`, but replies to the dmz zone follow the NAT default route
and are lost. `web01` also cannot reach `VIP:3306`, so it could not serve pages even if
HAProxy sent it traffic.

## Fix

```bash
ssh web01 'sudo ip route replace 192.168.10.0/24 via 192.168.20.254'
```

Or `bash 02-rollback.sh`. `sudo netplan apply` also restores it, at the cost of bouncing
the links. The netplan file still declares the route, so a reboot would have hidden the cause.

## Verify

```bash
ssh web01 'ip route get 192.168.10.11'     # via 192.168.20.254
```

HAProxy marks the node UP again after `rise 2`, about 4 seconds.

## Lesson

- "Reaches its own zone but nothing else" is the signature of a missing route as often as
  of a firewall. `ip route get` settles it in one command, and in this lab an empty
  ruleset settles the other half.
- The direction of the failing connection matters: the request arrived, the reply was lost.
- While the NAT NIC still exists, every lab node holds two default routes. That is the
  condition that turns one deleted line into an asymmetric path.
