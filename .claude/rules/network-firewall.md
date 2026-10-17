---
paths:
  - "ansible/roles/common/**"
  - "ansible/roles/router/**"
  - "ansible/inventory/**"
  - "Vagrantfile"
  - "scripts/**"
---

# Network, routing and the port matrix

> **The lab runs no firewall.** `ufw` is purged on all 10 nodes, `nftables.service` runs only on `fw01` and only to masquerade. See ADR-25.
> Principles: force cross-zone traffic through `fw01`, keep every service bound as narrowly as it can be, and **verify with a real port scan** instead of reading configuration — knowing the scan now measures what is listening, not what is permitted.

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
- `fw01` masquerades through one table, `ip router_nat`, and holds no filter chain. That table is the only persistent netfilter rule in the lab; see ADR-25.
- A lab node must never get a second zone NIC to shortcut the router. Since ADR-25 routing is the only thing that decides reachability, so a shortcut NIC does not just weaken a test, it silently changes the topology and nothing else will report it.
- While the temporary NAT NIC still exists, the default route sits on it, so the `common` role must add explicit static routes to the other zones via the local `.254`.
- Once the NAT NIC is removed, the default route becomes `.254` and those static routes are no longer needed. The role must handle both states idempotently.
- mgmt01 keeps its NAT NIC permanently, so it needs static routes for `192.168.10.0/24`, `192.168.20.0/24` and `192.168.30.0/24` via `172.16.10.254`, not a default route change.
- VRRP is link-local and never routed; it only works because lb01 and lb02 share `vmnet1`.

## No firewall, and what replaces it

- `ufw` is **purged** on all 10 nodes by the `common` role, not merely disabled. See ADR-25.
- `nftables.service` is stopped and disabled everywhere except `fw01`, where it loads one table, `ip router_nat`, holding only the masquerade rule. Policy accept, no filter chain, nothing is ever dropped.
- The `nft` binary stays installed on every node, because chaos scenarios 05, 14 and 18 load their own `inet lab_chaos` table and delete it on rollback. That is the only way a drop rule may ever exist.
- No Ansible role writes a filter rule. If a role needs one to make a flow work, the design is wrong, not the firewall.
- What is left in place of the firewall is each service's own access control, and every one of them is now single-layer:

| Service | The only thing limiting access |
|---|---|
| MySQL | `bind_address` on the zone IP and loopback, plus the GRANT host pattern `192.168.10.%` |
| bind9 | `listen-on` with the four zone addresses, a socket restriction that keeps it off the NAT NIC |
| chrony | the `allow` ACL per zone subnet, applied **after** the packet arrives, so UDP 123 is open on every NIC including NAT |
| NFS | `/etc/exports` listing the two web node addresses |
| Nginx | `allow`/`deny all` on `/fpm-status` |
| HAProxy stats | the `bind` address on `fe_stats` plus HTTP auth |
| mysqlchk | the `bind` address of its socket unit |

- Read that table as a list of load-bearing settings. A typo in any of them used to be caught by the firewall and now is not.

## Administrative sources

- "Admin" means mgmt01 `172.16.10.11` and the Windows host adapters `192.168.10.1`, `192.168.20.1`, `192.168.30.1`, `172.16.10.1`.
- Both can SSH into every node and reach the HAProxy stats page. Nothing restricts SSH by source any more; the `vagrant` user takes key authentication only, which is what carries that now.
- The Windows host adapters bypass `fw01` because they sit directly on each host-only segment. That is accepted for convenience, but every acceptance test must be run from mgmt01 so it takes the routed path a real client would.

## Port matrix

This is **design intent**, not enforcement. Nothing checks it at the network layer, so it says which flows the architecture expects, which is what makes an unexpected flow in a packet capture a finding. Keep it accurate for exactly that reason.

Cross-zone, routed by `fw01`:

- admin -> every node: TCP 22, for SSH and Ansible.
- admin -> VIP `192.168.10.100`: TCP 80 and 443, to browse the site as a real user.
- admin -> lb01, lb02: TCP 8404, HAProxy stats page.
- admin -> web01, web02: TCP 80, to test each node directly when comparing cross-node uploads.
- admin -> VIP, db01, db02: TCP 3306, for the RPO measurement scripts and failover work.
- lb01, lb02 -> web01, web02: TCP 80, request forwarding and health checks.
- lb01, lb02 -> db01, db02: TCP 3306 to proxy MySQL, TCP 9200 to call `mysqlchk`.
- web01, web02 -> VIP `192.168.10.100`: TCP 3306, WordPress reads and writes through HAProxy.
- every node -> its own zone `.254`: UDP 123 for chrony, UDP and TCP 53 for bind9. Addressed to the router itself, so it terminates there rather than being forwarded.
- mon01 -> every node: TCP 9100 for `node_exporter`.
- mon01 -> db01, db02: TCP 9104 for `mysqld_exporter`.
- mon01 -> web01, web02: TCP 9113 for the Nginx exporter, TCP 9253 for the PHP-FPM exporter.
- mon01 -> lb01, lb02: TCP 8405 for the HAProxy Prometheus endpoint, which HAProxy 3.3 serves natively with no separate exporter.
- mon01 -> db01, db02: TCP 9200 to call `mysqlchk` as a Blackbox target, and -> web01, web02 TCP 80 for `/healthz.php`.
- every node -> mon01: TCP 3100, Grafana Alloy shipping logs into Loki.
- admin -> mon01: TCP 3000 for Grafana, TCP 9090 for Prometheus, TCP 9093 for Alertmanager.

TCP 53 matters alongside UDP 53. A response past the UDP payload limit sets the truncated bit and the client retries over TCP, so a resolver listening only on UDP produces intermittent failures on large answers. Check both `ss -ulnp` and `ss -tlnp`.

Intra-zone, never touches the router:

- lb01 and lb02: IP protocol 112 to 224.0.0.18, VRRP advertisements inside the dmz zone.
- web01, web02 -> nfs01: TCP 2049, NFSv4 mount inside the app zone.
- db01 and db02: TCP 3306 both ways, replication in either direction so roles can be swapped on failover.

Flows the design rules out but **nothing blocks**. These used to be firewall tests; since ADR-25 they are honesty items, and each one needs the real behaviour recorded:

- app zone -> db zone directly. Routing permits it, so `web01` can open `192.168.30.11:3306`. The GRANT host pattern is what makes it fail, at authentication rather than at the network. If it ever succeeds, the application stopped going through the LB and nothing else will report it.
- client zone -> nfs01:2049. The port answers; the mount is refused by `/etc/exports`. A client-zone host can still reach and enumerate the RPC service.
- the NAT segment `10.10.10.0/24` -> UDP 123 on `fw01`. Reachable, because chrony binds `0.0.0.0` and its `allow` list refuses rather than drops. Accepted on a private host-only NAT; it would be a reflection and amplification source on anything routable.
- the NAT segment -> port 53 on `fw01`. Genuinely closed, because bind9's `listen-on` is a socket restriction. This is the one pair of the four where the service still provides real isolation, which is worth being able to explain.
- any zone -> any port not listed above. Reachable if something is listening. The scan is the inventory.

## Important constraints

- Never bind 3306 or 9200 on the NAT NIC under any circumstance. `bind_address` is the whole protection now, so this is a configuration rule rather than a firewall rule.
- Nothing may be bound to `0.0.0.0` unless the service genuinely has no narrower option. chrony is the one accepted exception, and it is recorded as a known limitation.
- The masquerade table on `fw01` is the only persistent netfilter rule in the lab. A second table in `/etc/nftables.conf` is a bug.
- An injected drop rule belongs in `inet lab_chaos`, loaded by `lab_chaos_rule`, and must be removed by the scenario's rollback. Nothing filter-related is ever persisted.
- Reachability is now a pure routing question, so `ip route get <dst>` answers it in one command. Use that before forming any other hypothesis.
- The DB source address rule still matters, for grants rather than for rules: MySQL sees the LB IP, not the web node IP.

## How to verify

- Prove no firewall is loaded: `nft list ruleset` must be **empty** on all 9 non-router nodes and show only `ip router_nat` on `fw01`, and `command -v ufw` must find nothing anywhere.
- Scan from mgmt01: `sudo nmap -sS -p- 192.168.10.11,12 192.168.20.11,12,21 192.168.30.11,12`. Every listening port shows open, so compare the result against what each service **binds**, not against the matrix. A port open wider than its `bind_address` should allow is the finding.
- Prove the routing is real: `traceroute -n 192.168.30.11` from web01 must show `192.168.20.254` as the first hop.
- Try the flow the design rules out, web01 to `192.168.30.11:3306`, and record what actually happens: the TCP connection succeeds and MySQL refuses the user. Do not write it up as blocked.
- Confirm the stats page and `/fpm-status` reject unknown sources. This is now the only layer in front of them, so test it from a node that is not on the allow list rather than assuming it.
- Confirm egress still works after NAT NIC removal: `curl -I https://deb.debian.org` from web01 must succeed through the router. If it fails, check the masquerade table first; nothing else can cause it.
- Confirm bind9 refuses the NAT address while answering on the zone addresses, from `mgmt01`, which keeps a NAT NIC and so has a genuine NAT-segment source address. Expect chrony to answer that same test from NAT and record it as the known limitation it is.
- Confirm `mon01` can scrape every exporter, and note that nothing stops a web node scraping them too.

## Domain name

- `shop.lab.internal` points to the VIP `192.168.10.100`, served by bind9 on `fw01` as an authoritative record in the `lab.internal` zone.
- Point it at the VIP, never at a node address, so every test follows the real user path.
- Lab nodes and `mgmt01` resolve it through `fw01`. The Windows host keeps a hosts-file entry instead: DNS resolution order across multiple adapters is unreliable and the host also needs normal internet DNS, so pointing the host at `fw01` is not practical.
- Every node has a forward and a reverse record. PTR records are unique per address, so `192.168.10.100` resolves back to `shop.lab.internal` and not to an LB name.
- The internal CA must be imported into the Windows Trusted Root store before the browser will trust the certificate.
