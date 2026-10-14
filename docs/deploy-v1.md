# deploy-v1 — NTP server, internal DNS and NFS server

> Manual installation guide. Run these steps by hand once to understand the mechanism,
> then turn each part into an Ansible role. See section 32 for the hand-off list.
> Every command runs as root or under `sudo`.

## 1. Scope

Three services, two nodes:

| Service | Node | Package | Listens on |
|---|---|---|---|
| NTP server | `fw01` | `chrony` | UDP 123 |
| Internal DNS | `fw01` | `bind9` | UDP 53, TCP 53 |
| NFS server | `nfs01` | `nfs-kernel-server` | TCP 2049 |

Out of scope here: the `router` role itself, forwarding, masquerade and the `nftables`
zone policy. Those come from M1 and must already work.

### Conflicts this document resolves

Every one of these is a service or a setting that already owns the resource the new
service needs. None of them produce a clear error message, which is why each has its
own step.

| Conflict | What collides | Handled in |
|---|---|---|
| `systemd-timesyncd` vs `chronyd` | both are the machine's time client, two daemons stepping one clock | 4, 6, 9 |
| `systemd-resolved` vs `named` | `resolved` already holds `127.0.0.53:53` | 12, 17, 18 |
| `rpcbind` and `rpc-statd` vs NFSv4-only | v3 helpers keep extra ports open for nothing | 25 |
| `vmnet8` DHCP injecting an NTP source | `sourcedir /run/chrony-dhcp` adds it silently | 7 |
| `vmnet8` DHCP injecting a DNS server | node resolves public names but not `lab.internal` | 20 |
| `resolved` built-in `FallbackDNS` | masks a dead bind9 with public resolvers | 20 |
| `netplan apply` restoring the `resolv.conf` symlink | silently undoes the resolver change | 18, 32 |
| `named` needs to be up before `chronyd` resolves its pool | ordering, once `fw01` resolves through itself | 18 |

### Port surface after this document

| Port | Node | Allowed from | Must be refused from |
|---|---|---|---|
| UDP 123 | `fw01` | the 4 zone subnets | `10.10.10.0/24`, the NAT segment |
| UDP 323 | `fw01` | loopback only, for `chronyc` | everywhere else |
| UDP 53, TCP 53 | `fw01` | the 4 zone subnets | `10.10.10.0/24`, the NAT segment |
| TCP 2049 | `nfs01` | `web01` and `web02` only | the client zone, including `mgmt01` |
| TCP 111 | `nfs01` | nothing, `rpcbind` is masked | everywhere |

## 2. Prerequisites

- M1 is complete: all 10 VMs are up, `fw01` forwards between the 4 zones.
- `ansible all -m ping` succeeds from `mgmt01`.
- `fw01` reaches the internet, so chrony can sync upstream and bind9 can forward.
- Snapshot every VM before starting: `vagrant snapshot save pre-deploy-v1`.

Confirm the interface names before editing anything. They differ between VMware NIC
types, so never copy an interface name from this document:

```bash
ip -brief address
ip route
```

## 3. Decisions recorded by this document

These belong in `.claude/rules/decisions.md` as new ADRs. Each states a cost.

- **NTP and DNS are co-located on `fw01`.** Reason: `fw01` already holds a
  permanent NAT NIC and an address in all 4 zones, so it is the only node that can
  reach upstream and serve every zone without a new cross-zone flow. Cost: `fw01`
  was already a SPOF for routing and now also owns time and name resolution. This is
  acceptable only because a `fw01` outage already breaks every cross-zone flow,
  so it adds no new failure mode.
- **chrony, not `systemd-timesyncd`.** Reason: `timesyncd` is an SNTP client only and
  cannot serve time. Cost: one more service to configure on 10 nodes.
- **bind9, not `dnsmasq`.** Reason: real zone files, reverse zones, SOA serial
  discipline and `named-checkzone` validation are the skills worth learning, and bind9
  is what production uses for authoritative internal DNS. Cost: roughly 30 MB more RSS
  and far more configuration surface than `dnsmasq` needs for 9 static hosts.
- **`local stratum 10` on `fw01`.** Reason: the lab keeps serving a consistent
  clock to every node when the internet is unreachable, which keeps logs correlatable
  across nodes. Cost: clients trust a reference that may drift from real UTC.
- **NFSv4 only, v3 disabled.** Reason: collapses the port surface to TCP 2049 alone,
  with no `rpcbind` and no portmapper. Cost: `showmount` stops working, because the
  MOUNT protocol it uses is v3 only.

---

# Part 1 — NTP server on fw01 (chrony)

## 4. Why systemd-timesyncd and chrony conflict

Both want to be the machine's time client, and two daemons stepping the same clock
fight each other and produce visible jumps. Ubuntu 24.04 prevents that in two places:

- `chrony.service` declares `Conflicts=systemd-timesyncd.service`, so systemd stops
  `timesyncd` the moment chrony starts.
- Debian and Ubuntu patch `systemd-timesyncd.service` with
  `ConditionFileIsExecutable=!/usr/sbin/chronyd`, so `timesyncd` refuses to start
  while `chronyd` is installed.

Read both for yourself rather than trusting this document:

```bash
systemctl cat chrony.service | grep -i conflicts
systemctl cat systemd-timesyncd.service | grep -i condition
```

So the conflict is handled automatically. Mask it anyway, in step 6: packaging only
protects you while chrony stays installed, and an explicit mask makes the intent
visible and keeps the Ansible role idempotent.

`timesyncd` could never have served time here in any case. It is an SNTP client with
no server mode, which is the real reason chrony is the only option on `fw01`.

## 5. Install chrony on fw01

```bash
apt-get update
apt-get install -y chrony
```

## 6. Take systemd-timesyncd out of the way

```bash
systemctl disable --now systemd-timesyncd
systemctl mask systemd-timesyncd
```

Confirm it is gone and chrony owns the clock:

```bash
systemctl is-enabled systemd-timesyncd    # expect: masked
timedatectl status                        # expect: NTP service: active
```

## 7. Configure fw01 as an NTP server

Ubuntu's `/etc/chrony/chrony.conf` already loads drop-ins through `confdir
/etc/chrony/conf.d`. Add the server role as a drop-in instead of editing the shipped
file, so the package can still be upgraded cleanly.

Write `/etc/chrony/conf.d/server.conf`:

```
# serve time to the four lab zones
allow 192.168.10.0/24
allow 192.168.20.0/24
allow 192.168.30.0/24
allow 172.16.10.0/24

# keep serving a consistent clock when upstream is unreachable
local stratum 10
```

Keep the upstream `pool` lines that Ubuntu ships in `chrony.conf`. They give
`fw01` its real reference.

One caveat on the NAT NIC: `chrony.conf` also carries `sourcedir /run/chrony-dhcp`,
so a DHCP-provided NTP server from `vmnet8` is added automatically. It is harmless,
but it makes the source list non-deterministic. Drop that line if you want the source
list to come only from configuration.

Apply and confirm chrony now opens the server port:

```bash
systemctl restart chrony
ss -ulnp | grep ':123'
```

Without any `allow` directive chronyd runs client-only and does not open UDP 123 at
all, so this command is the real proof the server role took effect.

You will also see `127.0.0.1:323` in the output. That is chronyd's command socket,
which `chronyc` talks to locally. It is bound to loopback and `cmdallow` is empty by
default, so it is not remotely reachable. Do not mistake it for an open port.

**chrony and bind9 are not equally restrictable, and this matters.** bind9 has
`listen-on`, which keeps the socket off the NAT NIC at the kernel level. chrony has no
real equivalent: `allow` is an ACL applied *after* the packet arrives, not a socket
restriction, and `bindaddress` accepts only one IPv4 address while `fw01` has four
zone addresses to serve. So chronyd binds `0.0.0.0:123` and the NAT NIC is included.

The consequence: **for NTP, `ufw` is the only thing standing between the NAT segment
and an open NTP server.** bind9 has two independent layers, chrony has one. Treat the
step 8 rules as load-bearing rather than belt-and-braces, and verify them with the
test in step 10 rather than assuming them.

The only socket-level control chrony offers is `port 0`, which disables the server
entirely. That is correct for the 8 clients and wrong for `fw01`.

## 8. Open the firewall on fw01

NTP is addressed to the router itself, not forwarded through it, so this is a `ufw`
rule and not an `nftables` forward rule. `fw01` runs both tools, and
`network-firewall.md` keeps `ufw` scoped to traffic terminating on the router.

```bash
ufw allow from 192.168.10.0/24 to any port 123 proto udp comment 'ntp dmz'
ufw allow from 192.168.20.0/24 to any port 123 proto udp comment 'ntp app'
ufw allow from 192.168.30.0/24 to any port 123 proto udp comment 'ntp db'
ufw allow from 172.16.10.0/24 to any port 123 proto udp comment 'ntp client'
ufw reload
```

Never open 123 on the NAT NIC. Writing each rule against a specific zone subnet
already prevents that, because `10.10.10.0/24` is not in the list. An open NTP server
facing NAT is a reflection and amplification source.

## 9. Point the lab nodes at fw01

Each node uses the `.254` address **of its own zone**, so the request stays inside the
zone and never crosses the router's forwarding path.

| Node | NTP server to use |
|---|---|
| `lb01`, `lb02` | `192.168.10.254` |
| `web01`, `web02`, `nfs01` | `192.168.20.254` |
| `db01`, `db02` | `192.168.30.254` |
| `mgmt01` | `172.16.10.254` |

The default `pool` lines live in `chrony.conf` itself, so a drop-in cannot remove
them. Replace `/etc/chrony/chrony.conf` on each client with a minimal file. This is
what the Ansible template will deploy, so the manual edit matches the final state.

`/etc/chrony/chrony.conf` on a client, shown for an app-zone node:

```
server 192.168.20.254 iburst

driftfile /var/lib/chrony/chrony.drift
makestep 1 3
rtcsync
logdir /var/log/chrony
```

Then on every client:

```bash
systemctl disable --now systemd-timesyncd
systemctl mask systemd-timesyncd
systemctl restart chrony
```

A single `server` line means chrony cannot detect a lying server by majority vote.
Accepted: there is only one time source in this lab by design, and a second source
would defeat the single-reference goal.

## 10. Verify the time layer

On `fw01`:

```bash
chronyc tracking      # Stratum should be 2 or 3, Leap status Normal
chronyc sources -v    # upstream pool sources, one marked '^*'
chronyc serverstats   # NTP packets received climbs as clients poll
chronyc clients       # every lab node must appear here
```

On any client:

```bash
chronyc sources -v    # exactly one source, the zone .254, marked '^*'
chronyc tracking      # System time offset well under one second
timedatectl status    # System clock synchronized: yes
```

Record the measured values, do not estimate them. `chronyc clients` is the single
best proof that the server role works, because it only lists hosts that actually
received a reply.

Measured on first build — fill in from the commands above:

| Measurement | Command | Value |
|---|---|---|
| fw01 stratum | `chronyc tracking` | |
| fw01 offset from upstream | `chronyc tracking` | |
| client offset from fw01 | `chronyc tracking` | |
| clients served | `chronyc clients` | |

Expect `makestep 1 3` to correct a large initial offset in one jump on the first
three updates, then slew only. A node that still shows a large offset after a few
minutes has a blocked UDP 123 path, not a chrony problem. Check with
`chronyc sources -v` showing `?` for the source, then the `ufw` rules on `fw01`.

### Prove the NTP server is closed on the NAT segment

This is the test that matters most, because step 7 explained that `ufw` is the only
layer protecting UDP 123. Run it from `mgmt01`, which is the right place: it keeps its
NAT NIC permanently, so it is genuinely on `10.10.10.0/24` and its packets arrive with
a NAT-segment source address that no `allow` rule covers.

Find the `fw01` NAT address, then query it from the NAT side:

```bash
# on fw01
ip -4 -brief address show | awk '/10\.10\.10\./ {print $3}'

# on mgmt01, against that address
chronyc -h <fw01-nat-ip> tracking
```

It must fail with `506 Cannot talk to daemon` or time out. An answer means `ufw` is
not covering the NAT segment and the lab is running a reflectable NTP server.

Repeat the same query against the zone address to confirm the allowed path still
works, which proves the first result was the firewall and not a dead service:

```bash
chronyc -h 172.16.10.254 tracking      # expect a normal tracking report
```

Note that `chronyc -h` uses UDP 323, not 123, so this pair tests reachability of the
host rather than the NTP service itself. For a true NTP-protocol probe from `mgmt01`:

```bash
sntp -t 3 <fw01-nat-ip>    # must time out
sntp -t 3 172.16.10.254        # must return an offset
```

---

# Part 2 — Internal DNS on fw01 (bind9)

## 11. Install bind9

```bash
apt-get install -y bind9 bind9-utils bind9-dnsutils
```

- `bind9` — the `named` daemon.
- `bind9-utils` — `named-checkconf` and `named-checkzone`, used in step 17.
- `bind9-dnsutils` — `dig` and `delv`, used in step 20.

The service is `named.service`, with `bind9.service` kept as an alias. `named` runs as
user `bind`.

Ubuntu 24.04 ships an enforcing AppArmor profile at
`/etc/apparmor.d/usr.sbin.named`. It grants read on `/etc/bind/**` and read-write on
`/var/lib/bind/**`. Static zone files therefore live happily in `/etc/bind/zones/`.
If you later add DNSSEC inline signing or dynamic updates, `named` needs to write a
journal next to the zone file and the files must move to `/var/lib/bind/`. Per
`web-stack.md`, never fix an AppArmor denial with `aa-complain`; check
`journalctl -k | grep -i apparmor` for DENIED lines first.

## 12. Configure options

Replace `/etc/bind/named.conf.options`:

```
acl lab {
    192.168.10.0/24;
    192.168.20.0/24;
    192.168.30.0/24;
    172.16.10.0/24;
    localhost;
};

options {
    directory "/var/cache/bind";

    # bind only the zone addresses and loopback, never the NAT NIC
    listen-on port 53 {
        127.0.0.1;
        192.168.10.254;
        192.168.20.254;
        192.168.30.254;
        172.16.10.254;
    };
    listen-on-v6 { none; };

    allow-query     { lab; };
    allow-recursion { lab; };
    allow-transfer  { none; };

    recursion yes;
    forwarders { 1.1.1.1; 8.8.8.8; };
    forward only;

    dnssec-validation auto;
    version none;
};
```

Four details worth understanding rather than copying:

- **`listen-on` must be explicit.** `fw01` also runs `systemd-resolved`, which
  binds `127.0.0.53:53`. `listen-on { any; }` would collide with it and `named` would
  fail to start. Listing addresses avoids the collision and keeps `named` off the
  `10.10.10.0/24` NAT NIC, so the lab never exposes an open resolver.
- **`allow-recursion { lab; }`** restricts the recursive service to the four zones. An
  open recursive resolver is a DNS amplification source.
- **`forward only`** means `named` never walks down from the root servers. Reason: one
  predictable upstream hop instead of a full recursion over the NAT path. Cost: DNS
  stops working for public names if both forwarders are unreachable, even when the
  root servers would have answered.
- **`version none`** stops `named` reporting its version to a `dig +short version.bind
  txt chaos` probe. Minor hardening, free to apply.

## 13. Declare the zones

Replace `/etc/bind/named.conf.local`:

```
# forward zone
zone "lab.internal" {
    type master;
    file "/etc/bind/zones/db.lab.internal";
};

# reverse zones, one per lab subnet
zone "10.168.192.in-addr.arpa" {
    type master;
    file "/etc/bind/zones/db.192.168.10";
};

zone "20.168.192.in-addr.arpa" {
    type master;
    file "/etc/bind/zones/db.192.168.20";
};

zone "30.168.192.in-addr.arpa" {
    type master;
    file "/etc/bind/zones/db.192.168.30";
};

zone "10.16.172.in-addr.arpa" {
    type master;
    file "/etc/bind/zones/db.172.16.10";
};
```

Note the two reverse zones that both start with `10`: `10.168.192.in-addr.arpa` is
`192.168.10.0/24` and `10.16.172.in-addr.arpa` is `172.16.10.0/24`. The file names are
deliberately written as the subnet, not as the reversed zone name, so they cannot be
confused.

```bash
mkdir -p /etc/bind/zones
```

## 14. Forward zone file

Write `/etc/bind/zones/db.lab.internal`:

```
$TTL 3600
@       IN  SOA ns1.lab.internal. admin.lab.internal. (
            2026101201  ; serial, YYYYMMDDnn
            3600        ; refresh
            600         ; retry
            604800      ; expire
            3600 )      ; negative cache TTL

@       IN  NS      ns1.lab.internal.

; name server, fw01 in the dmz zone
ns1     IN  A       192.168.10.254

; fw01, one record per zone interface
fw01        IN  A   192.168.10.254
fw01-dmz    IN  A   192.168.10.254
fw01-app    IN  A   192.168.20.254
fw01-db     IN  A   192.168.30.254
fw01-client IN  A   172.16.10.254

; the only entry point a client should ever use
shop    IN  A       192.168.10.100
vip     IN  A       192.168.10.100

; dmz zone
lb01    IN  A       192.168.10.11
lb02    IN  A       192.168.10.12

; app zone
web01   IN  A       192.168.20.11
web02   IN  A       192.168.20.12
nfs01   IN  A       192.168.20.21

; db zone
db01    IN  A       192.168.30.11
db02    IN  A       192.168.30.12

; client zone
mgmt01  IN  A       172.16.10.11
```

`shop.lab.internal` points at the VIP `192.168.10.100`, never at `lb01` or `lb02`.
Pointing it at a node address would make every test bypass Keepalived and silently
invalidate the VIP failover results.

`ns1` is an A record and not a CNAME. An NS record must never point at a CNAME.

## 15. Reverse zone files

A PTR record must be unique per address. `192.168.10.100` therefore gets exactly one
PTR, pointing at `shop`.

`/etc/bind/zones/db.192.168.10`:

```
$TTL 3600
@   IN  SOA ns1.lab.internal. admin.lab.internal. (
        2026101201 3600 600 604800 3600 )
@   IN  NS  ns1.lab.internal.

11  IN  PTR lb01.lab.internal.
12  IN  PTR lb02.lab.internal.
100 IN  PTR shop.lab.internal.
254 IN  PTR fw01-dmz.lab.internal.
```

`/etc/bind/zones/db.192.168.20`:

```
$TTL 3600
@   IN  SOA ns1.lab.internal. admin.lab.internal. (
        2026101201 3600 600 604800 3600 )
@   IN  NS  ns1.lab.internal.

11  IN  PTR web01.lab.internal.
12  IN  PTR web02.lab.internal.
21  IN  PTR nfs01.lab.internal.
254 IN  PTR fw01-app.lab.internal.
```

`/etc/bind/zones/db.192.168.30`:

```
$TTL 3600
@   IN  SOA ns1.lab.internal. admin.lab.internal. (
        2026101201 3600 600 604800 3600 )
@   IN  NS  ns1.lab.internal.

11  IN  PTR db01.lab.internal.
12  IN  PTR db02.lab.internal.
254 IN  PTR fw01-db.lab.internal.
```

`/etc/bind/zones/db.172.16.10`:

```
$TTL 3600
@   IN  SOA ns1.lab.internal. admin.lab.internal. (
        2026101201 3600 600 604800 3600 )
@   IN  NS  ns1.lab.internal.

11  IN  PTR mgmt01.lab.internal.
254 IN  PTR fw01-client.lab.internal.
```

## 16. File ownership

`named` reads these as user `bind`. Keep them unreadable by everyone else:

```bash
chown -R root:bind /etc/bind/zones
chmod 750 /etc/bind/zones
chmod 640 /etc/bind/zones/*
```

## 17. Validate before reloading

Never reload `named` without checking first. A syntax error in one zone file takes
the whole resolver down, and on this lab that means DNS for all 10 nodes.

```bash
named-checkconf
named-checkzone lab.internal                /etc/bind/zones/db.lab.internal
named-checkzone 10.168.192.in-addr.arpa     /etc/bind/zones/db.192.168.10
named-checkzone 20.168.192.in-addr.arpa     /etc/bind/zones/db.192.168.20
named-checkzone 30.168.192.in-addr.arpa     /etc/bind/zones/db.192.168.30
named-checkzone 10.16.172.in-addr.arpa      /etc/bind/zones/db.172.16.10
```

`named-checkconf` prints nothing on success. Each `named-checkzone` must end with
`OK`. Only then:

```bash
systemctl restart named
systemctl status named --no-pager
ss -lnp | grep ':53'
```

The `ss` output must show `named` on the four zone addresses and `127.0.0.1`, and
`systemd-resolve` on `127.0.0.53`. If `named` is missing from an address, it lost the
bind and the journal will say why.

The Ansible role must run this same validation before the handler reloads, per
extra goal G8: templates validated before reload.

## 18. Resolver configuration on fw01 itself

`fw01` should use its own bind9, which also proves recursion works locally.
Order matters: bind9 must already answer before you move the resolver, so the node
never sits without DNS and breaks `apt`.

Confirm bind9 answers first:

```bash
dig @127.0.0.1 web01.lab.internal +short      # expect 192.168.20.11
dig @127.0.0.1 deb.debian.org +short          # expect public addresses
```

Only when both work, disable `systemd-resolved` and write a static resolver file:

```bash
systemctl disable --now systemd-resolved
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<'EOF'
nameserver 127.0.0.1
search lab.internal
options timeout:2 attempts:2
EOF
```

`/etc/resolv.conf` on Ubuntu 24.04 is normally a symlink into
`/run/systemd/resolve/`, so it has to be removed before writing a real file. Netplan
can recreate the symlink on `netplan apply`, so this step must be owned by Ansible
and re-checked after any network change. Verify with `ls -l /etc/resolv.conf`,
which must show a regular file and not a symlink.

If this breaks, recover by writing `nameserver 1.1.1.1` into `/etc/resolv.conf`, then
fix bind9.

### The ordering dependency this step creates

`fw01` now resolves through its own bind9, and chrony's upstream sources are
**names**, not addresses: `pool ntp.ubuntu.com` has to be resolved before chrony can
reach any upstream server. So from this step onward, chronyd depends on named.

Nothing enforces that order. `chrony.service` orders itself after
`network-online.target` and knows nothing about `named.service`, so on a cold boot
chronyd can start first, fail to resolve the pool, and have no upstream source.

This is survivable rather than fatal, for two reasons worth understanding:

- chronyd retries name resolution periodically instead of giving up at startup, so it
  picks up the pool once named is answering.
- `local stratum 10` from step 7 means `fw01` keeps serving a usable clock to the
  9 other nodes during that window, so the lab stays internally consistent even before
  upstream is reachable.

The honest cost: for a few minutes after a cold boot, `fw01` may serve a clock
that has not yet been corrected against upstream. Clock-sensitive work, such as
recording an RTO measurement, should not start until `chronyc tracking` shows a real
reference rather than the local one.

Confirm the dependency resolved itself after a reboot:

```bash
systemctl reboot
# once back up
chronyc sources -v     # the pool sources must be present, not just the local ref
chronyc tracking       # Reference ID must not be 7F7F0101, which means local only
```

If you would rather make the order explicit than rely on the retry, add a drop-in:

```bash
systemctl edit chrony.service
```

```
[Unit]
After=named.service
Wants=named.service
```

Reason to prefer the drop-in: a cold boot reaches a correct clock sooner and the
dependency is documented in the unit rather than implied. Cost: chrony's startup is
now gated on a service it does not strictly require, so a broken named delays time
sync instead of leaving it degraded. Either choice is defensible; record which one you
picked, because it changes what a boot-time postmortem should expect to see.

## 19. Open the firewall on fw01

```bash
for net in 192.168.10.0/24 192.168.20.0/24 192.168.30.0/24 172.16.10.0/24; do
    ufw allow from "$net" to any port 53 proto udp comment 'dns'
    ufw allow from "$net" to any port 53 proto tcp comment 'dns tcp'
done
ufw reload
ufw status verbose
```

TCP 53 is needed as well as UDP 53. A response larger than the UDP payload limit sets
the truncated bit and the client retries over TCP. Opening only UDP produces
intermittent failures on large answers, which is a confusing symptom to debug.

As with NTP, `10.10.10.0/24` is deliberately absent, so nothing on the NAT side can
query this resolver.

## 20. Point the lab nodes at fw01

Each node uses the `.254` of its own zone, the same rule as NTP.

On an Ubuntu 24.04 lab node, add `nameservers` to the **existing** zone NIC block in
the netplan file. Do not change any `addresses` or `routes` here; routing is M1's
concern and `network-firewall.md` describes the two routing states.

Shown for an app-zone node, with the interface name replaced by the real one:

```yaml
network:
  version: 2
  ethernets:
    <zone-nic>:
      nameservers:
        search: [lab.internal]
        addresses: [192.168.20.254]
```

While the temporary NAT NIC still exists, it must be stopped from injecting its own
DNS server. VMware's DHCP on `vmnet8` hands out a resolver, and `systemd-resolved`
will happily use it, which produces a node that resolves public names but not
`lab.internal`. On the NAT NIC block:

```yaml
    <nat-nic>:
      dhcp4: true
      dhcp4-overrides:
        use-dns: false
```

Leave `use-routes` alone. The default route belongs to M1 and changing it here would
break the node.

### Disable the built-in fallback resolvers

`use-dns: false` stops DHCP from supplying a resolver, but `systemd-resolved` has a
second source that netplan does not touch: `FallbackDNS`, compiled into the binary and
pointing at public Cloudflare and Google resolvers. It is used whenever no link has a
usable DNS server.

That is actively harmful here. If bind9 dies, every node silently keeps resolving
public names through the fallback while `lab.internal` returns nothing. The symptom is
a node that looks like it has working DNS but cannot find `shop.lab.internal`, which
sends you hunting through zone files instead of looking at a dead `named`.

On every node except `mgmt01`, write `/etc/systemd/resolved.conf.d/no-fallback.conf`:

```
[Resolve]
FallbackDNS=
```

An empty value clears the compiled-in list. Then:

```bash
systemctl restart systemd-resolved
resolvectl status | grep -i fallback      # must show no fallback servers
```

Now a bind9 outage fails loudly on every node instead of degrading quietly. That is
the behaviour you want: `healthcheck.py` can detect it, and the chaos scenario for a
dead resolver produces an unambiguous result.

`mgmt01` is deliberately the exception, for the reason given at the end of this step.

Apply and check:

```bash
netplan generate            # syntax check, changes nothing
netplan apply
resolvectl status            # per-link DNS, the zone .254 on the zone NIC only
resolvectl query web01.lab.internal
```

### mgmt01 is the one exception

`mgmt01` runs the same Ubuntu 24.04 and the same netplan as every other node, so the
configuration above applies to it too, with `172.16.10.254` as its resolver. One
thing differs: it is the **only** node that also gets a public fallback resolver.

```yaml
network:
  version: 2
  ethernets:
    <zone-nic>:
      nameservers:
        search: [lab.internal]
        addresses: [172.16.10.254, 1.1.1.1]
```

Reason: `mgmt01` is the Ansible control node. If bind9 dies it must still resolve
`archive.ubuntu.com` to repair the lab, otherwise the one machine that can fix the
problem is also the one that cannot install anything.

Cost: when `fw01` is unreachable, `lab.internal` lookups fall through to `1.1.1.1`
and return NXDOMAIN rather than timing out. That is acceptable, because a resolver
only fails over on timeout and not on NXDOMAIN, so the fallback never shadows a
working bind9.

Consequence for the previous step: **do not** apply the `FallbackDNS=` drop-in to
`mgmt01`. Its fallback is deliberate and explicit, declared in netplan where it can
be seen, rather than compiled into the binary where it cannot.

Verify the result rather than the configuration:

```bash
resolvectl status
getent hosts web01
```

## 21. Verify the DNS layer

From `mgmt01`, which takes the real routed path a client would:

```bash
# forward lookups
dig +short shop.lab.internal        # expect 192.168.10.100
dig +short web01.lab.internal       # expect 192.168.20.11
dig +short db02.lab.internal        # expect 192.168.30.12

# short-name resolution via the search domain
getent hosts web01

# reverse lookups, one per zone
dig +short -x 192.168.10.100        # expect shop.lab.internal.
dig +short -x 192.168.20.21         # expect nfs01.lab.internal.
dig +short -x 192.168.30.11         # expect db01.lab.internal.
dig +short -x 172.16.10.11          # expect mgmt01.lab.internal.

# recursion for public names
dig +short deb.debian.org

# the resolver must be authoritative, check the aa flag
dig shop.lab.internal | grep -E 'flags:|AUTHORITY'
```

Confirm the resolver is **not** open, from a source outside the four zones. Run this
on `fw01` against its own NAT address:

```bash
NAT_IP=$(ip -4 -brief address show | awk '/10\.10\.10\./ {print $3}' | cut -d/ -f1)
dig @"${NAT_IP}" shop.lab.internal
```

This must time out or be refused. An answer here means `listen-on` is wrong and the
lab is running an open resolver on the NAT segment.

## 22. Serial discipline

Every time a zone file changes, the SOA serial must increase. `named` uses the serial
to decide whether the zone changed, and a reload with an unchanged serial is silently
ignored by anything that caches.

- Format is `YYYYMMDDnn`, so `2026101201` is the first change on 2026-10-12.
- Bump `nn` for a second change the same day, and roll the date on the next day.
- Forgetting the bump is the single most common bind9 mistake. The symptom is a change
  that "did not apply", with no error anywhere.

Check the live serial after any edit:

```bash
dig +short lab.internal SOA @127.0.0.1
```

The Ansible role should template the serial from a variable so it is explicit in
version control, not generated at run time. A generated serial changes on every run
and breaks the `changed=0` requirement from G8.

---

# Part 3 — NFS server on nfs01 (nfs-kernel-server)

## 23. Pin the www-data UID and GID first

Do this **before** installing any package, on `nfs01`, `web01` and `web02`.

NFS with AUTH_SYS compares numeric UIDs, not names. If `www-data` is UID 33 on one
node and UID 34 on another, the directory still lists normally but reads and writes
fail with permission errors that look nothing like a UID problem. It is one of the
hardest faults to spot in this whole lab.

`www-data` ships in the Ubuntu base system as 33:33, but do not rely on the default.
Check it explicitly on all three nodes:

```bash
id www-data        # expect uid=33(www-data) gid=33(www-data)
```

If any node disagrees, fix it before continuing, with no `www-data` process running:

```bash
groupmod -g 33 www-data
usermod -u 33 -g 33 www-data
```

Record the chosen number. The Ansible role must set it explicitly with `uid: 33` and
`gid: 33` rather than letting a package assign one, because package install order
would otherwise decide it and the nodes would drift on a rebuild.

## 24. Install nfs-kernel-server

```bash
apt-get install -y nfs-kernel-server
```

## 25. Disable NFSv3, keep v4.2 only

Edit `/etc/nfs.conf`:

```
[nfsd]
vers3 = n
vers4 = y
vers4.0 = n
vers4.1 = n
vers4.2 = y
```

NFSv3 needs `rpcbind` and a scatter of helper ports. NFSv4 carries everything over a
single TCP connection on 2049, which is why the port matrix has exactly one line for
NFS. With v3 off, the v3 helpers are dead weight and worth masking:

```bash
systemctl mask rpcbind.service rpcbind.socket rpc-statd.service
systemctl restart nfs-server
```

Confirm what the kernel actually enabled, rather than trusting the config file:

```bash
cat /proc/fs/nfsd/versions     # expect -3 +4 -4.0 -4.1 +4.2
ss -tlnp | grep 2049
```

Accepted cost: `showmount -e nfs01` no longer works anywhere, because `showmount`
speaks the v3-only MOUNT protocol. Use `exportfs -v` on the server and a real mount
from the client instead. Do not read a `showmount` failure as a broken export.

Confirm `rpcbind` is really gone, so the port matrix line for TCP 111 is accurate:

```bash
ss -tlnp | grep ':111'      # expect no output
systemctl is-enabled rpcbind.socket     # expect: masked
```

### Why one port is genuinely enough

Disabling 4.0 is what makes the single-port claim true, and it is worth being explicit
about. In NFSv4.0 the **server** calls back to the client for delegation recalls, and
the client has to open a callback port for it, so a v4.0 deployment needs more than
2049 open in the return direction. NFSv4.1 replaced that with a session backchannel
multiplexed over the client's existing connection, and 4.2 inherits it. With 4.0 off,
there is no callback port to open and TCP 2049 in one direction is the entire surface.

One caveat on `vers4.1 = n` with `vers4.2 = y`: the kernel exposes 4.1 and 4.2 as
independent version flags, so this combination is accepted, but 4.2 is built on the
4.1 session machinery and a client that can only negotiate 4.1 will now be refused.
That is intentional here, because `web-stack.md` pins the client mount to
`nfsvers=4.2`. Verify the kernel agreed with the config rather than assuming it — this
is exactly why step 25 reads `/proc/fs/nfsd/versions` instead of trusting
`/etc/nfs.conf`.

## 26. Create the export directory

```bash
mkdir -p /srv/nfs/uploads
chown www-data:www-data /srv/nfs/uploads
chmod 2775 /srv/nfs/uploads
```

The setgid bit in `2775` makes every file created inside inherit the `www-data` group,
so an upload from `web01` stays group-readable for `web02`.

## 27. Define the export

Write `/etc/exports`:

```
# WordPress uploads, exported to the two web nodes only
/srv/nfs/uploads 192.168.20.11(rw,sync,no_subtree_check) 192.168.20.12(rw,sync,no_subtree_check)
```

- Two explicit host addresses, not a subnet. `nfs01` sits in the app zone next to
  other nodes, and only the web nodes have any business mounting this.
- `sync` means the server acknowledges a write only after it reaches stable storage.
  Cost: slower writes. Reason: an order's product image must not vanish on a crash.
- `no_subtree_check` avoids a known class of failures when a file is renamed while
  open. It is the standard choice for a dedicated export.
- `root_squash` is the default and is deliberately left on, so root on a web node maps
  to `nobody` here. WordPress runs as `www-data`, so nothing legitimate needs root.

Apply and verify:

```bash
exportfs -ra
exportfs -v
```

The `exportfs -v` output must list both web node addresses with the options above.
Note it also shows `root_squash` even though `/etc/exports` does not, which confirms
the default is active.

## 28. Open the firewall on nfs01

```bash
ufw allow from 192.168.20.11 to any port 2049 proto tcp comment 'nfs web01'
ufw allow from 192.168.20.12 to any port 2049 proto tcp comment 'nfs web02'
ufw reload
ufw status verbose
```

`mgmt01` is intentionally **not** allowed. NFS is not an administrative interface, and
`network-firewall.md` lists `client zone -> nfs01:2049` as a flow that must be denied
and tested.

## 29. Mount from the web nodes

On `web01` and `web02`:

```bash
apt-get install -y nfs-common
mkdir -p /var/www/wordpress/wp-content/uploads
```

Add to `/etc/fstab`:

```
192.168.20.21:/srv/nfs/uploads  /var/www/wordpress/wp-content/uploads  nfs4  nfsvers=4.2,hard,noatime,_netdev  0  0
```

```bash
mount -a
findmnt /var/www/wordpress/wp-content/uploads
```

Three things to understand here:

- Mount only `wp-content/uploads`, never the whole WordPress tree. The code must stay
  local and identical on both nodes, deployed by Ansible; sharing it over NFS would
  make `nfs01` a SPOF for the application code as well as for uploads.
- `hard` is deliberate, per ADR-11. When NFS dies, processes block in state D instead
  of receiving an I/O error and corrupting an upload. Accepted cost: a hung PHP-FPM
  worker must not be misdiagnosed as a PHP bug. Check `findmnt` and `dmesg` for NFS
  server timeouts before touching the application.
- `_netdev` tells systemd the mount needs the network, so boot does not stall or fail
  ordering against the interface coming up.

## 30. Verify the NFS layer

The real test is cross-node visibility, not a successful mount.

On `web01`:

```bash
sudo -u www-data touch /var/www/wordpress/wp-content/uploads/from-web01
```

On `web02`:

```bash
ls -l /var/www/wordpress/wp-content/uploads/from-web01
sudo -u www-data touch /var/www/wordpress/wp-content/uploads/from-web02
```

Back on `web01`, confirm `from-web02` is visible, then check the UID mapping landed
correctly on the server. On `nfs01`:

```bash
ls -ln /srv/nfs/uploads
```

The numeric owner must be `33 33` on both files. A different number on one of them
means the UID pinning in step 23 was not applied on that node, and this is exactly the
fault that is invisible from a plain `ls -l`.

Clean up:

```bash
rm -f /var/www/wordpress/wp-content/uploads/from-web0*
```

Confirm the denied path as well, from `mgmt01`:

```bash
nc -zv -w 3 192.168.20.21 2049      # must fail
```

---

# Part 4 — Acceptance and hand-off

## 31. Acceptance checklist

Time:

- [ ] `systemd-timesyncd` is masked on all 10 nodes.
- [ ] `chronyc clients` on `fw01` lists all 8 other nodes.
- [ ] Every client shows exactly one source, its own zone `.254`, marked `^*`.
- [ ] `timedatectl status` shows `System clock synchronized: yes` everywhere.
- [ ] `sntp` from `mgmt01` to the `fw01` NAT address times out, and to
      `172.16.10.254` returns an offset.
- [ ] UDP 323 on `fw01` is bound to loopback only.
- [ ] After a `fw01` reboot, `chronyc tracking` shows a real reference and not
      the local one.

DNS:

- [ ] `named-checkconf` and all five `named-checkzone` runs report `OK`.
- [ ] Forward lookups resolve for all 10 nodes plus `shop` and `vip`.
- [ ] Reverse lookups resolve in all four subnets.
- [ ] `shop.lab.internal` resolves to `192.168.10.100`, never to a node address.
- [ ] Public recursion works from every zone.
- [ ] A query to the `fw01` NAT address is refused or times out.
- [ ] `ls -l /etc/resolv.conf` on `fw01` shows a regular file, not a symlink.
- [ ] `resolvectl status` shows no fallback DNS servers on any node except `mgmt01`.
- [ ] `resolvectl status` on `mgmt01` shows `172.16.10.254` first and `1.1.1.1` as the
      deliberate fallback.
- [ ] Stopping `named` makes `lab.internal` lookups fail on the lab nodes instead of
      falling through to a public resolver.

NFS:

- [ ] `/proc/fs/nfsd/versions` shows v3 off and v4.2 on.
- [ ] `ss -tlnp` on `nfs01` shows 2049 and nothing on 111.
- [ ] `exportfs -v` lists only `192.168.20.11` and `192.168.20.12`.
- [ ] A file written on `web01` is visible on `web02`, and the reverse.
- [ ] `ls -ln` on `nfs01` shows numeric owner `33 33` for files from both nodes.
- [ ] `mgmt01` cannot reach `192.168.20.21:2049`.

Then snapshot: `vagrant snapshot save deploy-v1`.

## 32. Turn this into Ansible

Nothing above is finished until it is code. Per the project rule, a hand edit made to
experiment must be coded or rolled back immediately.

| Role | Tasks to add |
|---|---|
| `common` | install chrony, mask `systemd-timesyncd`, template `chrony.conf` with the zone `.254` from a variable, set the resolver on the zone NIC, drop `FallbackDNS=` into `resolved.conf.d/`, set `use-dns: false` on the NAT NIC while it exists |
| `router` | chrony `conf.d/server.conf`, bind9 packages, `named.conf.options`, `named.conf.local`, all five zone files, `ufw` rules for 53 and 123, static `/etc/resolv.conf` |
| `nfs_server` | pin `www-data` 33:33 before packages, install `nfs-kernel-server`, `/etc/nfs.conf`, mask the v3 helpers, create and own the export, `/etc/exports`, `ufw` rule for 2049 |
| `nfs_client` | pin `www-data` 33:33, install `nfs-common`, create the mount point, `fstab` entry, mount |

Guard both new `fw01` services behind variables so they stay visibly optional:

```yaml
deploy_ntp_server: true
deploy_dns_server: true
```

Three idempotency traps to handle, all of which would break the `changed=0`
requirement in G8:

- The SOA serial must come from a variable, never be generated at run time.
- `netplan apply` can restore the `/etc/resolv.conf` symlink on `fw01`. The task
  must check the file type, not just the content.
- Validate with `named-checkconf` and `named-checkzone` in a handler before the reload,
  so a bad template cannot take DNS down for the whole lab.

## 33. Known limitations

These belong in the README's out-of-scope list.

- `fw01` now owns routing, time and name resolution. It was already a SPOF for
  every cross-zone flow, so this adds no new failure mode, but it does widen the blast
  radius of a `fw01` outage. The future fix is the same one already listed for
  routing: a second router with VRRP.
- The Windows host cannot practically use `fw01` as its resolver, because DNS
  resolution order across multiple adapters is unreliable and the host also needs
  normal internet DNS. `shop.lab.internal` therefore stays in the Windows hosts file.
  Only the lab nodes and `mgmt01` get real internal DNS.
- There is one NTP source and one DNS server, so neither layer has the redundancy the
  request-serving layers have. This is accepted: a clock or name resolution outage
  degrades operations and log correlation, it does not drop orders.
- `nfs01` remains a known SPOF, per ADR-10. Nothing here changes that.
