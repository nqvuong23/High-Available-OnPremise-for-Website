# How to set up the lab from nothing

> Covers M0 and M1: the Windows host prerequisites and the first `vagrant up`.
> Everything after that is Ansible work, run from `mgmt01`.
> All 10 VMs come from the `Vagrantfile`. Nothing is installed by hand any more.

## The task list

1. Install the host software, in the required order.
2. Create the 5 virtual networks in Virtual Network Editor.
3. Generate the shared SSH key pair into `vagrant-provision/`.
4. Download the box, then `vagrant up`.
5. Verify routing and reachability, then snapshot.

## Step 1: Install the host software

Order matters. The plugin will not install before the Utility is running.

1. VMware Workstation Pro 25H2 — free for personal use, needs a Broadcom account.
2. Vagrant 2.4.9.
3. Vagrant VMware Utility 1.0.24 — confirm the Windows service is running.
4. `vagrant plugin install vagrant-vmware-desktop --plugin-version 3.0.5`

```powershell
vagrant plugin list
Get-Service -Name "VMware Vagrant*"
```

## Step 2: Create the virtual networks

In Virtual Network Editor, with administrator rights:

| VMnet | Subnet | Type | DHCP | Host adapter |
|---|---|---|---|---|
| `vmnet1` | `192.168.10.0/24` | host-only | **off** | on |
| `vmnet2` | `192.168.20.0/24` | host-only | **off** | on |
| `vmnet3` | `192.168.30.0/24` | host-only | **off** | on |
| `vmnet4` | `172.16.10.0/24` | host-only | **off** | on |
| `vmnet8` | `10.10.10.0/24` | NAT | **on** | on |

- DHCP stays on for `vmnet8` only, because the temporary NAT NIC needs a lease before `vagrant ssh` can work.
- Apply, then wait for each Windows adapter to pick up its `<subnet>.1` address.
- **Delete any VMnet outside this plan.** A leftover occupies a subnet and gives the provider a wrong candidate to match against, which produces nodes that boot but cannot ping.

Verify from PowerShell before going further:

```powershell
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -like "*VMnet*" } | Format-Table InterfaceAlias, IPAddress
```

Each of the five subnets must appear exactly once, at `.1`.

## Step 3: Generate the SSH key pair

The `Vagrantfile` copies this public key into every node, `mgmt01` included. Because `mgmt01` is now built by Vagrant, the key has to exist **before** the first `vagrant up` — it can no longer be generated on `mgmt01` itself. See ADR-21.

```powershell
ssh-keygen -t ed25519 -f vagrant-provision/ansible-key -N '""' -C "ansible lab key"
```

Then confirm only the public half is tracked:

```powershell
git status --short vagrant-provision/
```

`ansible-key.pub` may be committed. `ansible-key` must not — it is the private key, and `.gitignore` matches it by name because it has no extension to match on.

## Step 4: Build the lab

```powershell
vagrant box add bento/ubuntu-24.04 --box-version 202510.26.0 --provider vmware_desktop --architecture amd64
vagrant up --provider vmware_desktop
vagrant status
```

- Add the box first, so a download failure cannot be mistaken for a build failure.
- `fw01` is declared first on purpose, so the gateway exists before the other zones boot.

## Step 5: Verify, then snapshot

From the Windows host:

```powershell
ssh vagrant@172.16.10.11        # mgmt01
```

From `mgmt01`, prove the routing is real rather than bridged:

```bash
ping -c2 192.168.20.11
traceroute -n 192.168.30.11     # first hop must be 172.16.10.254
```

Then on `web01`, confirm cross-zone traffic is routed:

```bash
traceroute -n 192.168.30.11     # first hop must be 192.168.20.254
```

A first hop that is **not** `.254` means the two zones share an L2 segment, which voids every isolation test. Go back to step 2.

Snapshot once this passes:

```powershell
vagrant snapshot save fresh
```

## Careful with snapshots from here on

`vagrant snapshot save` and `restore` act on **every** machine in the `Vagrantfile`, which now includes `mgmt01` and `mon01`. A bulk restore therefore rolls back the control node as well, discarding uncommitted work, the Vault password file and the virtualenv.

Commit and push before restoring, or restore individual nodes by name.

## What comes next

- `docs/deploy-v1.md` — NTP and internal DNS on `fw01`, NFS on `nfs01`, by hand first.
- `.claude/rules/milestones.md` — the full M0 to M8 roadmap and each acceptance test.
