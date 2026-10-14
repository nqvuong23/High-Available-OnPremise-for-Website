---
paths:
  - "ansible/roles/common/**"
  - "ansible/roles/firewall/**"
  - "ansible/inventory/**"
  - "Vagrantfile"
  - "scripts/**"
---

# Network, routing and the firewall matrix

> Principles: open the minimum, keep the database off any zone that does not need it, force cross-zone traffic through `fw01`, and **verify with a real port scan** instead of reading configuration.

## Address plan

| Zone | VMnet | Subnet | Gateway | Nodes | Reserved |
|---|---|---|---|---|---|
| dmz | `vmnet1` | `192.168.10.0/24` | `.254` | lb01 `.11`, lb02 `.12` | VIP `.100`, host `.1` |
| app | `vmnet2` | `192.168.20.0/24` | `.254` | web01 `.11`, web02 `.12`, nfs01 `.21` | `.100`, host `.1` |
| db | `vmnet3` | `192.168.30.0/24` | `.254` | db01 `.11`, db02 `.12` | `.100`, host `.1` |
| client | `vmnet4` | `172.16.10.0/24` | `.254` | mgmt01 `.11`, mon01 `.21` | `.100`, host `.1` |
| NAT | `vmnet8` | `10.10.10.0/24` | `.2` | temporary NIC1 on all lab VMs, permanent on fw01, mgmt01 and mon01 | — |

- `.254` in every zone is `fw01`. `.1` is the Windows host adapter. `.100` is reserved for a VIP, assigned only in the dmz zone today.
- Keep `.100` free in all four zones so a second VIP can be added later without renumbering.
- `.11` and `.12` are request-serving pairs, `.21` is a supporting service: `nfs01` in the app zone, `mon01` in the client zone. Keep that convention when adding a node.
- Every NIC carries a MAC generated from the node index and the host octet, and netplan matches on that MAC rather than on an interface name. A rebuild therefore cannot move a zone address onto the wrong NIC. See ADR-20.

## Routing

- `fw01` has one NIC per zone plus a permanent NAT NIC, with `net.ipv4.ip_forward=1`.
- `fw01` masquerades traffic leaving through the NAT NIC, so lab nodes keep internet access after their own NAT NIC is removed.
- A lab node must never get a second zone NIC to shortcut the router; that would void the isolation tests.
- While the temporary NAT NIC still exists, the default route sits on it, so the `common` role must add explicit static routes to the other zones via the local `.254`.
- Once the NAT NIC is removed, the default route becomes `.254` and those static routes are no longer needed. The role must handle both states idempotently.
- mgmt01 keeps its NAT NIC permanently, so it needs static routes for `192.168.10.0/24`, `192.168.20.0/24` and `192.168.30.0/24` via `172.16.10.254`, not a default route change.
- VRRP is link-local and never routed; it only works because lb01 and lb02 share `vmnet1`.

## Firewall tooling

- Every node runs `ufw` with `deny incoming` by default. There is only one distro family, so no branching by `ansible_os_family` is needed.
- `fw01` additionally runs an `nftables` forward policy, so the router decides which zone pairs may talk at all.
- Two layers on purpose: `nftables` on the router is the zone policy, `ufw` on each node is the host policy. A flow must be allowed by both.
- Every service role opens its own ports; the `common` role only sets the default policy and SSH.

## Allowed administrative sources

- "Admin" means mgmt01 `172.16.10.11` and the Windows host adapters `192.168.10.1`, `192.168.20.1`, `192.168.30.1`, `172.16.10.1`.
- Both may SSH into every node and reach the HAProxy stats page.
- The Windows host adapters bypass `fw01` because they sit directly on each host-only segment. That is accepted for convenience, but every acceptance test must be run from mgmt01 so it takes the routed path a real client would.

## Port matrix

Cross-zone, forwarded by `fw01`:

- admin -> every node: TCP 22, for SSH and Ansible.
- admin -> VIP `192.168.10.100`: TCP 80 and 443, to browse the site as a real user.
- admin -> lb01, lb02: TCP 8404, HAProxy stats page.
- admin -> web01, web02: TCP 80, to test each node directly when comparing cross-node uploads.
- admin -> VIP, db01, db02: TCP 3306, for the RPO measurement scripts and failover work.
- lb01, lb02 -> web01, web02: TCP 80, request forwarding and health checks.
- lb01, lb02 -> db01, db02: TCP 3306 to proxy MySQL, TCP 9200 to call `mysqlchk`.
- web01, web02 -> VIP `192.168.10.100`: TCP 3306, WordPress reads and writes through HAProxy.
- every node -> its own zone `.254`: UDP 123 for chrony, UDP and TCP 53 for bind9. Addressed to the router itself, so this is a `ufw` rule on `fw01` and not an `nftables` forward rule.
- mon01 -> every node: TCP 9100 for `node_exporter`.
- mon01 -> db01, db02: TCP 9104 for `mysqld_exporter`.
- mon01 -> web01, web02: TCP 9113 for the Nginx exporter, TCP 9253 for the PHP-FPM exporter.
- mon01 -> lb01, lb02: TCP 8405 for the HAProxy Prometheus endpoint, which HAProxy 3.3 serves natively with no separate exporter.
- mon01 -> db01, db02: TCP 9200 to call `mysqlchk` as a Blackbox target, and -> web01, web02 TCP 80 for `/healthz.php`.
- every node -> mon01: TCP 3100, Grafana Alloy shipping logs into Loki.
- admin -> mon01: TCP 3000 for Grafana, TCP 9090 for Prometheus, TCP 9093 for Alertmanager.

TCP 53 is needed alongside UDP 53. A response past the UDP payload limit sets the truncated bit and the client retries over TCP, so opening only UDP produces intermittent failures on large answers.

Intra-zone, never touches the router:

- lb01 and lb02: IP protocol 112 to 224.0.0.18, VRRP advertisements inside the dmz zone.
- web01, web02 -> nfs01: TCP 2049, NFSv4 mount inside the app zone.
- db01 and db02: TCP 3306 both ways, replication in either direction so roles can be swapped on failover.

Denied on purpose, and worth testing:

- app zone -> db zone directly. Web nodes must reach MySQL only through the VIP, never `192.168.30.11:3306`.
- client zone -> nfs01:2049. NFS is not an administrative interface.
- the NAT segment `10.10.10.0/24` -> UDP 123 and port 53 on `fw01`. An NTP or DNS server reachable from NAT is a reflection and amplification source. Test this one explicitly; the `allow` list in `chrony.conf` is an ACL applied after the packet arrives, not a socket restriction, so `ufw` is the only layer protecting UDP 123.
- any zone -> any port not listed above.

## Important constraints

- While the temporary NAT NIC exists, SSH must be open on **both** the NAT NIC and the zone NIC; blocking the NAT NIC too early kills `vagrant ssh`.
- Never expose 3306 or 9200 on the NAT NIC under any circumstance.
- `ufw` does not understand `proto vrrp`; add an IP protocol 112 rule to `/etc/ufw/before.rules` and then `ufw reload`.
- `ufw` on a routing node also filters the FORWARD chain. On `fw01`, manage forwarding with `nftables` and keep `ufw` scoped to traffic addressed to the router itself, so the two tools cannot silently contradict each other.
- A `ufw` rule on a lab node must be written against the real source address, which for DB traffic is the LB IP, not the web node IP.

## How to verify

- Scan from mgmt01: `sudo nmap -sS -p- 192.168.10.11,12 192.168.20.11,12,21 192.168.30.11,12` and compare against the matrix.
- Prove the routing is real: `traceroute -n 192.168.30.11` from web01 must show `192.168.20.254` as the first hop.
- Try a source that is **not** allowed, for example web01 calling `192.168.30.11:3306` directly, and confirm it is blocked.
- Confirm the stats page and `/fpm-status` reject unknown sources.
- Read the live state with `ufw status verbose` on each node and `nft list ruleset` on `fw01`.
- Confirm egress still works after NAT NIC removal: `curl -I https://deb.debian.org` from web01 must succeed through the router.
- Confirm the NTP and DNS services on `fw01` answer on the zone addresses and are refused on its NAT address. Run the refusal test from `mgmt01`, which keeps a NAT NIC and so has a genuine NAT-segment source address.
- Confirm `mon01` can scrape every exporter and that nothing else can: a `curl` to `:9100` from a web node must be blocked.

## Domain name

- `shop.lab.internal` points to the VIP `192.168.10.100`, served by bind9 on `fw01` as an authoritative record in the `lab.internal` zone.
- Point it at the VIP, never at a node address, so every test follows the real user path.
- Lab nodes and `mgmt01` resolve it through `fw01`. The Windows host keeps a hosts-file entry instead: DNS resolution order across multiple adapters is unreliable and the host also needs normal internet DNS, so pointing the host at `fw01` is not practical.
- Every node has a forward and a reverse record. PTR records are unique per address, so `192.168.10.100` resolves back to `shop.lab.internal` and not to an LB name.
- The internal CA must be imported into the Windows Trusted Root store before the browser will trust the certificate.
