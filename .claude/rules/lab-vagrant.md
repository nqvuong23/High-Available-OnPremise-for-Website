---
paths:
  - "Vagrantfile"
  - "vagrant-provision/**"
---

# Building the lab with Vagrant and VMware

> `vagrant` runs **only in Windows PowerShell** at the repo root. `mgmt01` never drives the hypervisor.
> `mgmt01` is installed by hand from the Debian 13.7 ISO and is not in the `Vagrantfile`; only the 8 lab VMs are.

## Software on the Windows host

- VMware Workstation Pro 25H2, free for personal use, needs a Broadcom account to download.
- Vagrant 2.4.9, Vagrant VMware Utility 1.0.24 running as a Windows service, plugin `vagrant-vmware-desktop` 3.0.5.
- Mandatory install order: Workstation, then the Utility, then `vagrant plugin install`.
- With WSL2 or Virtual Machine Platform enabled, Workstation runs in Host VBS mode and is slower; acceptable.

## Boxes

- `bento/ubuntu-24.04` for all 8 lab VMs, pinned to `202510.26.0`. `mgmt01` uses no box: it is installed from the Debian 13.7 netinst ISO.
- One distro family for the lab keeps the Ansible roles single-path; see ADR-13.
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

## Why VMnets must be pinned explicitly

- `vagrant-vmware-desktop` picks a VMnet by **matching subnets**: it reads the VMnet list and looks for a device whose `hostonly_subnet` matches the IP being requested.
- If none matches, it silently creates a **new** VMnet with DHCP enabled. That is where stray VMnets come from.
- Subnet matching means the VMnet number depends on the creation order in Virtual Network Editor, not on the `Vagrantfile`.
- Pinning `ethernetN.vnet` in the `.vmx` makes every rebuild land on the same VMnet.
- The provider action order is `Network -> VMXModify -> Boot`. `Network` writes the `.vmx` from subnet matching, `VMXModify` writes the `v.vmx[...]` values over it, then it boots. So the `v.vmx["ethernetN.vnet"]` block is the last word before the VM starts.
- Pinning the VMnet guarantees the right wire, not the right subnet on that wire. Verify both: read each Windows host adapter address and compare it with the plan. A VM on the correct VMnet carrying an address from a subnet that no longer exists there boots fine and simply cannot ping.

## Vagrantfile conventions

- Declare the zones in one table of subnet and VMnet, and the nodes in one array of name, memory, vCPU and per-zone host octet, so the plan changes in a single place.
- Validate the plan before the provider touches the hypervisor: duplicate IPs, an unknown zone, use of `.1` or `.100`, or two zones sharing a VMnet must abort the run.
- Set resources with `v.vmx["memsize"]` and `v.vmx["numvcpus"]`.
- Declare NIC1 as NAT with `v.nat_device = "vmnet8"`. Leaving it unset makes the provider write a meaningless `ethernet0.vnet` value, which shows up in the UI as the VM sitting on VMnet0.
- Set `v.allowlist_verified = true` so `ethernetN.pcislotnumber` survives rebuilds. Otherwise Workstation hands out new slots and guest interface names shift, which is exactly what breaks the `lab_iface` inventory variable.
- Pin NIC order with `adapter: i + 1`; slot N here maps to `ethernetN` in the `.vmx`.
- Enable `v.linked_clone = true` so VMs share the box base disk and save several GB.
- Set `v.gui = false`; everything is done over SSH.
- Disable the synced folder with `config.vm.synced_folder ".", "/vagrant", disabled: true`; HGFS from NTFS confuses file permissions and is not needed.
- Pin `box_version` per machine so a later rebuild produces the same OS.
- Declare `router01` first, so the gateway exists before the other zones boot.
- Keep comments short and in English, per `code-style.md`.

## Minimum provisioning

- Single goal: get the machine to a state Ansible can enter. Every service configuration is Ansible work.
- Install `python3`. One distro family means no extra per-OS packages are needed.
- Copy the shared public key into the `vagrant` user `authorized_keys`, written so a rerun cannot duplicate the line.
- Confirm passwordless sudo, and always check the sudoers file with `visudo -cf` before letting it take effect.
- Set the hostname through `node.vm.hostname`, never by hand in a script.
- The SSH key is generated on `mgmt01` first, then its public half is copied to `vagrant-provision/`. The `Vagrantfile` must abort with a clear message if that file is missing.

## Removing the NAT NIC

- Order matters: configure the zone NIC and the static routes first, confirm `ansible all -m ping` works over the zone NIC, and only then remove NAT.
- Removing NAT early leaves a node with no route in and no route out, recoverable only from the Workstation console.
- `router01` must already be forwarding and masquerading before any other node loses its NAT NIC, or that node loses internet access and `apt` dies.
- `router01` and `mgmt01` keep their NAT NIC permanently.
- After removal, `vagrant ssh` and `vagrant provision` no longer work for that node. `vagrant up`, `halt`, `destroy` and `snapshot` still do, because they act on the hypervisor rather than over the network.
- From that point, SSH goes from `mgmt01` over the zone NIC through `router01`.
- Record the removal in the snapshot name: snapshot `base` is taken **after** NAT removal, so a restore cannot bring the shortcut back.

## Snapshots

- Names follow the milestones: `fresh` for a bare OS, then `base`, `db-ready`, `lb-ready`, `app-ready`, `stable`, `baseline`.
- `vagrant snapshot save <name>` applies to every machine in the `Vagrantfile`.
- **Always restore `db01` and `db02` together to the same snapshot.** Mismatched snapshots mean mismatched GTIDs and replication that is very hard to untangle.
- Create `baseline` once the system is tuned and healthy; that is the return point for every chaos scenario.

## Common failures

- `vagrant up` hangs at "Waiting for machine to boot": check that the Vagrant VMware Utility service is still running.
- A vmnet verification error: set `v.verify_vmnet = false` in the provider block. This only skips the health check and does **not** fix a host-only collision.
- `vagrant plugin install` timing out against `gems.hashicorp.com`: the host has broken IPv6. Prefer IPv4 with `netsh interface ipv6 set prefixpolicy ::ffff:0:0/96 45 4 store=persistent`, then confirm with `show prefixpolicies`.
- A script failing with `bad interpreter: /bin/bash^M`: CRLF line endings, so make sure `.gitattributes` forces `eol=lf`.
- A node that pings its own zone but nothing else: the static routes via `.254` are missing, or the NAT NIC was removed before they were added.
