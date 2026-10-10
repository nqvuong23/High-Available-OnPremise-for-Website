---
paths:
  - "ansible/roles/common/**"
  - "ansible/roles/router/**"
  - "ansible/inventory/**"
  - "Vagrantfile"
  - "scripts/**"
---

# Network, routing and the firewall matrix

> Principles: open the minimum, keep the database off any zone that does not need it, force cross-zone traffic through `router01`, and **verify with a real port scan** instead of reading configuration.

## Address plan

| Zone | VMnet | Subnet | Gateway | Nodes | Reserved |
|---|---|---|---|---|---|
| dmz | `vmnet1` | `192.168.10.0/24` | `.254` | lb01 `.11`, lb02 `.12` | VIP `.100`, host `.1` |
| app | `vmnet2` | `192.168.20.0/24` | `.254` | web01 `.11`, web02 `.12`, nfs01 `.21` | `.100`, host `.1` |
| db | `vmnet3` | `192.168.30.0/24` | `.254` | db01 `.11`, db02 `.12` | `.100`, host `.1` |
| client | `vmnet4` | `172.16.10.0/24` | `.254` | mgmt01 `.11` | `.100`, host `.1` |
| NAT | `vmnet8` | `10.10.10.0/24` | `.2` | temporary NIC1 on all lab VMs, permanent on router01 and mgmt01 | — |

- `.254` in every zone is `router01`. `.1` is the Windows host adapter. `.100` is reserved for a VIP, assigned only in the dmz zone today.
- Keep `.100` free in all four zones so a second VIP can be added later without renumbering.

## Routing

- `router01` has one NIC per zone plus a permanent NAT NIC, with `net.ipv4.ip_forward=1`.
- `router01` masquerades traffic leaving through the NAT NIC, so lab nodes keep internet access after their own NAT NIC is removed.
- A lab node must never get a second zone NIC to shortcut the router; that would void the isolation tests.
- While the temporary NAT NIC still exists, the default route sits on it, so the `common` role must add explicit static routes to the other zones via the local `.254`.
- Once the NAT NIC is removed, the default route becomes `.254` and those static routes are no longer needed. The role must handle both states idempotently.
- mgmt01 keeps its NAT NIC permanently, so it needs static routes for `192.168.10.0/24`, `192.168.20.0/24` and `192.168.30.0/24` via `172.16.10.254`, not a default route change.
- VRRP is link-local and never routed; it only works because lb01 and lb02 share `vmnet1`.

## Firewall tooling

- Every node runs `ufw` with `deny incoming` by default. There is only one distro family, so no branching by `ansible_os_family` is needed.
- `router01` additionally runs an `nftables` forward policy, so the router decides which zone pairs may talk at all.
- Two layers on purpose: `nftables` on the router is the zone policy, `ufw` on each node is the host policy. A flow must be allowed by both.
- Every service role opens its own ports; the `common` role only sets the default policy and SSH.

## Allowed administrative sources

- "Admin" means mgmt01 `172.16.10.11` and the Windows host adapters `192.168.10.1`, `192.168.20.1`, `192.168.30.1`, `172.16.10.1`.
- Both may SSH into every node and reach the HAProxy stats page.
- The Windows host adapters bypass `router01` because they sit directly on each host-only segment. That is accepted for convenience, but every acceptance test must be run from mgmt01 so it takes the routed path a real client would.

## Port matrix

Cross-zone, forwarded by `router01`:

- admin -> every node: TCP 22, for SSH and Ansible.
- admin -> VIP `192.168.10.100`: TCP 80 and 443, to browse the site as a real user.
- admin -> lb01, lb02: TCP 8404, HAProxy stats page.
- admin -> web01, web02: TCP 80, to test each node directly when comparing cross-node uploads.
- admin -> VIP, db01, db02: TCP 3306, for the RPO measurement scripts and failover work.
- lb01, lb02 -> web01, web02: TCP 80, request forwarding and health checks.
- lb01, lb02 -> db01, db02: TCP 3306 to proxy MySQL, TCP 9200 to call `mysqlchk`.
- web01, web02 -> VIP `192.168.10.100`: TCP 3306, WordPress reads and writes through HAProxy.

Intra-zone, never touches the router:

- lb01 and lb02: IP protocol 112 to 224.0.0.18, VRRP advertisements inside the dmz zone.
- web01, web02 -> nfs01: TCP 2049, NFSv4 mount inside the app zone.
- db01 and db02: TCP 3306 both ways, replication in either direction so roles can be swapped on failover.

Denied on purpose, and worth testing:

- app zone -> db zone directly. Web nodes must reach MySQL only through the VIP, never `192.168.30.11:3306`.
- client zone -> nfs01:2049. NFS is not an administrative interface.
- any zone -> any port not listed above.

## Important constraints

- While the temporary NAT NIC exists, SSH must be open on **both** the NAT NIC and the zone NIC; blocking the NAT NIC too early kills `vagrant ssh`.
- Never expose 3306 or 9200 on the NAT NIC under any circumstance.
- `ufw` does not understand `proto vrrp`; add an IP protocol 112 rule to `/etc/ufw/before.rules` and then `ufw reload`.
- `ufw` on a routing node also filters the FORWARD chain. On `router01`, manage forwarding with `nftables` and keep `ufw` scoped to traffic addressed to the router itself, so the two tools cannot silently contradict each other.
- A `ufw` rule on a lab node must be written against the real source address, which for DB traffic is the LB IP, not the web node IP.

## How to verify

- Scan from mgmt01: `sudo nmap -sS -p- 192.168.10.11,12 192.168.20.11,12,21 192.168.30.11,12` and compare against the matrix.
- Prove the routing is real: `traceroute -n 192.168.30.11` from web01 must show `192.168.20.254` as the first hop.
- Try a source that is **not** allowed, for example web01 calling `192.168.30.11:3306` directly, and confirm it is blocked.
- Confirm the stats page and `/fpm-status` reject unknown sources.
- Read the live state with `ufw status verbose` on each node and `nft list ruleset` on `router01`.
- Confirm egress still works after NAT NIC removal: `curl -I https://deb.debian.org` from web01 must succeed through the router.

## Domain name

- `shop.lab.internal` points to the VIP `192.168.10.100`, declared in the Windows hosts file and in `/etc/hosts` on mgmt01.
- Point it at the VIP, never at a node address, so every test follows the real user path.
- The internal CA must be imported into the Windows Trusted Root store before the browser will trust the certificate.
