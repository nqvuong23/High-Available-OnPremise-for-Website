---
paths:
  - "Vagrantfile"
  - "vagrant-provision/**"
---

# Building the lab with Vagrant and VMware

> `vagrant` runs **only in Windows PowerShell** at the repo root. `mgmt01` never drives the hypervisor.
> All 9 VMs are declared in the `Vagrantfile`, `mgmt01` included. Nothing is installed by hand.

## Software on the Windows host

- VMware Workstation Pro 25H2, free for personal use, needs a Broadcom account to download.
- Vagrant 2.4.9, Vagrant VMware Utility 1.0.24 running as a Windows service, plugin `vagrant-vmware-desktop` 3.0.5.
- Mandatory install order: Workstation, then the Utility, then `vagrant plugin install`.
- With WSL2 or Virtual Machine Platform enabled, Workstation runs in Host VBS mode and is slower; acceptable.

## Boxes

- `bento/ubuntu-24.04` for all 9 VMs, pinned to `202510.26.0`. There is no second box and no ISO install.
- One distro family keeps the Ansible roles single-path; see ADR-13 and ADR-15.
- Always add a box with `--provider vmware_desktop --architecture amd64`; without those flags it reports that the box has no such provider.
- Download boxes before `vagrant up` so a network failure cannot be mistaken for a build failure.

## Virtual networks on the host

Create these in Virtual Network Editor before the first `vagrant up`:

- `vmnet1` = `192.168.10.0/24`, host-only, DHCP **off**, host virtual adapter on.
- `vmnet2` = `192.168.20.0/24`, host-only, DHCP **off**, host virtual adapter on.
- `vmnet3` = `192.168.30.0/24`, host-only, DHCP **off**, host virtual adapter on.
- `vmnet4` = `172.16.10.0/24`, host-only, DHCP **off**, host virtual adapter on.
- `vmnet8` = `10.10.10.0/24`, NAT, DHCP **on**, because NIC1 needs a lease for `vagrant ssh`.
- Apply, then wait for the Windows adapters to pick up their new `<subnet>.1` address.
- Delete any VMnet outside this plan. Leftovers occupy subnets and give the provider a wrong candidate to pick.

## How a NIC finds its zone

The provider chooses the VMnet, and a deterministic MAC address decides which address lands on which NIC. See ADR-20 for why it is done this way.

- `vagrant-vmware-desktop` picks a VMnet by **matching subnets**: it reads the VMnet list and looks for a device whose `hostonly_subnet` matches the IP being requested. The host VMnet layout from the previous section is what makes this land correctly.
- If no VMnet matches, it silently creates a **new** one with DHCP enabled. That is where stray VMnets come from, and it is a silent success rather than an error, so check Virtual Network Editor after the first build.
- Subnet matching means the VMnet number depends on the creation order in Virtual Network Editor, not on the `Vagrantfile`. The `Vagrantfile` does not care, because it never names a VMnet.
- The real hazard is **inside** the guest: Workstation reassigns PCI slots between rebuilds, so interface names like `ens33` shift and any config written against a name ends up on the wrong zone.
- The fix is to generate each MAC from the NIC index, the **zone index** and the host octet, write it into the `.vmx` with the `mac:` option, and have netplan select the interface with `match: { macaddress: ... }`. The interface name then stops mattering entirely.
- The MAC must be unique across the **whole lab**, not just within a node, and a MAC derived from the third octet is not: `192.168.10.11` and `172.16.10.11` both carry `10`, so `lb01` and `mgmt01` collided. The zone index is in the formula for exactly that reason.
- Being on different VMnets does not make a duplicate MAC safe. All VMnets are ports on the same host-side virtual switch driver, a unicast frame is delivered by MAC, and `match: { macaddress: ... }` stops identifying one NIC. Treat MAC uniqueness as a host-wide requirement, never a per-segment one.
- Consequence worth knowing: the netplan keys (`interface0`, `interface1`) are arbitrary identifiers, not device names. Do not expect to find them in `ip link` output.
- Verify the wire **and** the subnet on it. Read each Windows host adapter address and compare it with the plan. A VM on the right VMnet carrying an address from a subnet that no longer exists there boots fine and simply cannot ping.

## Vagrantfile conventions

- Declare the zones in one table of name and subnet, and the nodes in one array of name, memory, vCPU and full zone addresses, so the plan changes in a single place.
- Derive everything else from that array: MAC, gateway, zone subnet, routes and the netplan document. No per-node special cases.
- Validate the plan before the provider touches the hypervisor. An unknown zone now aborts through `lab_zone_index`. Duplicate IPs, duplicate MACs and use of `.1` or `.100` must abort too. **Not implemented yet.**
- Abort with a clear message if `vagrant-provision/ansible-key.pub` is missing, because every node's provisioning depends on it. **Not implemented yet.**
- Set resources with `v.vmx["memsize"]` and `v.vmx["numvcpus"]`.
- Pin NIC order with `adapter: i + 1`; slot N here maps to `ethernetN` in the `.vmx`. Slot 0 is left to Vagrant's own NAT adapter, which is what `vagrant ssh` uses during provisioning.
- Give every NIC an explicit `mac:`, generated from the node index and the host octet. This is what makes the netplan `match` work; see the section above.
- Set `auto_config: false` and write the addresses through netplan instead. Letting Vagrant configure the interface would fight the netplan file.
- Enable `v.linked_clone = true` so VMs share the box base disk and save several GB.
- Set `v.gui = false`; everything is done over SSH.
- Set `v.vmx["cpuid.coresPerSocket"] = "1"` so the guest sees discrete sockets rather than cores, which keeps `lscpu` output predictable across rebuilds.
- Disable the synced folder with `config.vm.synced_folder ".", "/vagrant", disabled: true`; HGFS from NTFS confuses file permissions and is not needed.
- Pin `box_version` once at the top level; one box for all 9 VMs means there is nothing to vary per machine.
- Declare `fw01` first, so the gateway exists before the other zones boot.
- Keep the provisioning in named shell blocks (`name: "netplan"`, `name: "bootstrap"`) so a failed run says which step broke.
- Keep comments short and in English, per `code-style.md`.

## Minimum provisioning

- Single goal: get the machine to a state Ansible can enter. Every service configuration is Ansible work.
- Install `python3`. One distro family means no extra per-OS packages are needed.
- Copy the shared public key into the `vagrant` user `authorized_keys`, written so a rerun cannot duplicate the line.
- Confirm passwordless sudo, and always check the sudoers file with `visudo -cf` before letting it take effect.
- Set the hostname through `node.vm.hostname`, never by hand in a script.
- The SSH key pair must already exist in `vagrant-provision/` before the first `vagrant up`. It can no longer be generated on `mgmt01`, because `mgmt01` is now built by Vagrant and needs the key to get in. Generate it on the Windows host.
- Commit only the public half. The private key must stay out of git; `.gitignore` patterns that rely on a file extension will not catch a key named `ansible-key`.

## Removing the NAT NIC

- Order matters: configure the zone NIC and the static routes first, confirm `ansible all -m ping` works over the zone NIC, and only then remove NAT.
- Removing NAT early leaves a node with no route in and no route out, recoverable only from the Workstation console.
- `fw01` must already be forwarding and masquerading before any other node loses its NAT NIC, or that node loses internet access and `apt` dies.
- `fw01` and `mgmt01` keep their NAT NIC permanently.
- After removal, `vagrant ssh` and `vagrant provision` no longer work for that node. `vagrant up`, `halt`, `destroy` and `snapshot` still do, because they act on the hypervisor rather than over the network.
- From that point, SSH goes from `mgmt01` over the zone NIC through `fw01`.
- Record the removal in the snapshot name: snapshot `base` is taken **after** NAT removal, so a restore cannot bring the shortcut back.

## Snapshots

- Names follow the milestones: `fresh` for a bare OS, then `base`, `db-ready`, `lb-ready`, `app-ready`, `stable`, `baseline`.
- `vagrant snapshot save <name>` applies to every machine in the `Vagrantfile`.
- **Always restore `db01` and `db02` together to the same snapshot.** Mismatched snapshots mean mismatched GTIDs and replication that is very hard to untangle.
- Create `baseline` once the system is tuned and healthy; that is the return point for every chaos scenario.
- **`mgmt01` is now inside the `Vagrantfile`, so a bulk restore rolls back the control node too.** That silently discards any uncommitted work, the Vault password file and the virtualenv. Commit and push before restoring, or restore the affected nodes by name instead of all of them.

## Common failures

- `vagrant up` hangs at "Waiting for machine to boot": check that the Vagrant VMware Utility service is still running.
- A vmnet verification error: set `v.verify_vmnet = false` in the provider block. This only skips the health check and does **not** fix a host-only collision.
- `vagrant plugin install` timing out against `gems.hashicorp.com`: the host has broken IPv6. Prefer IPv4 with `netsh interface ipv6 set prefixpolicy ::ffff:0:0/96 45 4 store=persistent`, then confirm with `show prefixpolicies`.
- A script failing with `bad interpreter: /bin/bash^M`: CRLF line endings, so make sure `.gitattributes` forces `eol=lf`.
- `apt-get install` failing with `404 Not Found` on pool paths: the box index is stale, because `box_version` is pinned and the `.deb` files it names have been dropped from the pool since the box was built. Run `apt-get update` first; `bootstrap.sh` does it on every node for this reason. A 404 on a pool path means the index disagrees with the pool, while a broken mirror or resolver gives a timeout or a resolve error instead. Never reach for `--fix-missing`, which leaves a half-installed set.
- A node that pings its own zone but nothing else: the static routes via `.254` are missing, or the NAT NIC was removed before they were added.
- A node whose zone NIC is UP with the right address but that cannot reach **anything** in its own zone, while a neighbour on that same zone works: compare `ethernet*.address` across every `.vmx`, because this is what a duplicate MAC looks like. `ping` reports `Destination Host Unreachable` from the node's own address, which means ARP never resolved, so it reads like a firewall or routing fault and is neither. Prove it with `tcpdump -ni <nic> arp` on both VMs at once: the reply lands on the wrong one.
