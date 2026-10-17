# Scenario 01 — troubleshooting: everything across zones is down

> Work it like on-call. Do not read **Root cause** until your own diagnosis is finished.
> Every command is run by hand on purpose; read each output before running the next.

## What you see

- The site times out from `mgmt01`, and every HAProxy backend is DOWN.
- SSH from `mgmt01` to any node outside the client zone hangs. Ansible cannot reach them either.
- Yet `ping 192.168.20.254` and `ping 192.168.30.254` from `mgmt01` still answer.

## Step 1 — is this one service or every zone at once?

```bash
for h in lb01 web01 db01 nfs01; do ping -c1 -W1 $h >/dev/null && echo "$h ok" || echo "$h no reply"; done
```

Every node in three different zones failing together is one shared component, not four
broken hosts. Read it as a routing problem before opening a single service log.

## Step 2 — does the router itself answer?

```bash
ping -c2 172.16.10.254
ping -c2 192.168.20.254
ping -c2 192.168.30.254
```

All three answer. Note why: those are `fw01`'s **own** addresses, so the packet is
delivered to `fw01` and never forwarded. "The gateway pings" proves the router is alive,
not that it routes.

## Step 3 — where does the path stop?

```bash
traceroute -n -w 1 -q 1 192.168.20.11
ip route get 192.168.20.11
```

`ip route get` shows the expected next hop `172.16.10.254`, so `mgmt01` is sending the
packet to the right place. `traceroute` shows the first hop answering and then nothing.

## Step 4 — are the targets alive? Ask from the router

```bash
ssh fw01 'ping -c1 -W1 192.168.20.11; ping -c1 -W1 192.168.30.11'
```

They answer from `fw01`, because `fw01` sits directly on those segments. The hosts are fine.
So `fw01` reaches both sides but does not carry traffic between them.

## Step 5 — watch the router drop the packet

In one terminal on `fw01`:

```bash
ssh fw01
sudo tcpdump -ni any icmp and host 192.168.20.11
```

In another, from `mgmt01`: `ping -c3 192.168.20.11`

The echo request arrives on the client-zone NIC and is never sent out of the app-zone NIC.
A packet that enters but never leaves is either dropped by a filter or not forwarded at all.

## Step 6 — filter or forwarding?

```bash
ssh fw01 'sysctl net.ipv4.ip_forward; cat /proc/sys/net/ipv4/ip_forward'
ssh fw01 'sudo nft list ruleset'
ssh fw01 'grep -r ip_forward /etc/sysctl.conf /etc/sysctl.d/'
```

Compare the live value with what the files say it should be. The ruleset must hold the
masquerade table and nothing else; the lab runs no packet filter, so a filter chain here
is either an injected fault or a leftover. See ADR-25.

---

## Root cause

`net.ipv4.ip_forward` is `0` on `fw01`. The kernel delivers packets addressed to itself
but refuses to route anything else, before any netfilter hook is even reached.

## Fix

```bash
ssh fw01 'sudo sysctl -w net.ipv4.ip_forward=1'
```

Or `bash 01-rollback.sh`. The persistent value in `/etc/sysctl.d/99-router.conf` was never
changed, which is exactly why this fault survives until someone looks: a reboot would have
"fixed" it and hidden the cause.

## Verify

```bash
ping -c1 192.168.20.11 && curl -sI https://shop.lab.internal | head -1
ansible all -m ping
```

## Lesson

- A router answering pings on its own addresses says nothing about forwarding.
- Many failures in several zones at the same moment means a shared dependency. Check the
  path before the services.
- Live state and persistent configuration can disagree; read both.
