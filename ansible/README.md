# Ansible: build the whole lab with one playbook

Runs on `mgmt01`. Rebuilds everything `docs/how-to-setup.md` does by hand, starting from
the Vagrant `base` snapshot. Keep `ansible/` and `scripts/` side by side.

## First run

```bash
source ~/ansible-venv/bin/activate
cd ~/linux_project/ansible          # wherever ansible/ was copied
export ANSIBLE_CONFIG=$PWD/ansible.cfg

ansible-galaxy collection install -r requirements.yml -p ./collections
bash ../scripts/tools/gen-vault.sh  # random secrets, encrypted, password in ~/.vault_pass.txt

ansible all -m ping
ansible-playbook site.yml
ansible-playbook verify.yml
```

Run `site.yml` a second time: it must report `changed=0`. A remaining `changed` is a bug
in that task, not noise.

## What runs where

| Play | Hosts | Roles |
|---|---|---|
| baseline | every node | `common` |
| router | `fw01` | `router`: forwarding, masquerade, chrony server, bind9, static resolver |
| storage | `nfs01` | `nfs_server` |
| database | `db01`, `db02` | `mysql`, `mysqlchk` |
| LB and VIP | `lb01`, `lb02` | `haproxy` (with the internal PKI), `keepalived` |
| web | `web01`, `web02` | `nfs_client`, `nginx_php`, `wordpress` |
| control node | `mgmt01` | `mgmt`: CA trust, `/etc/lab/lab.env`, `~/.lab/` credentials |

## Where values live

- Addresses: `inventory/hosts.yml`, once per node. Everything else is derived from it.
- Topology, ports, names: `inventory/group_vars/all/main.yml`.
- Secrets: `inventory/group_vars/all/vault.yml`, encrypted. Template: `vault.yml.example`.
- NIC names are never written down: `lab_iface` finds the NIC that holds `lab_ip` from facts.

## Decisions worth knowing before you change something

- Packages come from Ubuntu apt (HAProxy 2.8, Nginx 1.24, MySQL 8.0), matching the
  manual build that was proven in `how-to-setup.md`. Moving to the upstream versions
  in `CLAUDE.md` is a separate, deliberate change.
- MySQL `root` keeps Ubuntu's `auth_socket`, so there is no root password to manage;
  Ansible connects over the unix socket as root.
- Write is opened on `mysql_primary_host` only after checking every peer is read-only.
  If a failover made another node writable, the play stops instead of creating a
  second primary. After a failover, change `mysql_primary_host` and rerun.
- The PKI lives in the `haproxy` role, because a role directory named `pki` matches
  `.gitignore`. The CA key never leaves the first LB.
- No firewall anywhere: `common` purges `ufw` and keeps `nftables.service` stopped on
  every node, and the only netfilter rule in the lab is the masquerade `router` writes
  on `fw01`. Reachability is therefore decided by routing alone. See ADR-25.
- HAProxy and Keepalived templates hide their diff because they hold passwords;
  `--check` still reports them as changed when they drift.

## Day-to-day

```bash
ansible-playbook site.yml --check --diff          # detect hand edits on any node
ansible-playbook site.yml --tags web --limit web02
ansible-vault edit inventory/group_vars/all/vault.yml
```
