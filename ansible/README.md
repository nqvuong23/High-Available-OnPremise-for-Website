# Ansible: build the whole lab with one playbook

## First run

Runs on `mgmt01`:

```bash
source ~/ansible-venv/bin/activate
chmod o-w ~/linux_project/ansible      
cd ~/linux_project/ansible   
export ANSIBLE_CONFIG=$PWD/ansible.cfg

ansible-galaxy collection install -r requirements.yml -p ./collections
bash ~/linux_project/scripts/tools/gen-vault.sh 

ansible all -m ping
ansible-playbook site.yml
ansible-playbook verify.yml
```

Run `site.yml` a second time: it must report `changed=0`. A remaining `changed` is a bug in that task, not noise.

## What runs where

| Play | Hosts | Roles |
|---|---|---|
| baseline | every node | `common` |
| router | `fw01` | `router`(forwarding, masquerade, chrony server, bind9, static resolver) |
| storage | `nfs01` | `nfs_server` |
| database | `db01`, `db02` | `mysql`, `mysqlchk` |
| LB and VIP | `lb01`, `lb02` | `haproxy` (with the internal PKI), `keepalived` |
| web | `web01`, `web02` | `nfs_client`, `nginx_php`, `wordpress` |
| control node | `mgmt01` | `mgmt` (CA trust, `/etc/lab/lab.env`, `~/.lab/` credentials) |

## Where values live

- Addresses: `inventories/hosts.yml`, once per node. Everything else is derived from it.
- Topology, ports, names: `inventories/group_vars/all/vars.yml`.
- Secrets: `inventories/group_vars/all/vault.yml`, encrypted. Template: `inventories/group_vars/all/vault.yml.example`.
- NIC names are never written down: `lab_iface` finds the NIC that holds `lab_ip` from facts.

## Day-to-day run

```bash
ansible-playbook site.yml --check --diff          # detect manual edits on any node
ansible-playbook site.yml --tags web --limit web02
ansible-vault edit inventories/group_vars/all/vault.yml
```
