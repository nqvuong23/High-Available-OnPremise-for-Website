---
paths:
  - "ansible/**"
---

# Ansible standards

> Runs on `mgmt01` (Ubuntu 24.04, Python 3.12.3) inside a virtualenv. The strictest acceptance criterion: `site.yml` reports `changed=0` on the second run.

## Environment

- ansible-core 2.20.x installed in a virtualenv; Ubuntu 24.04 blocks `pip` into the system Python under PEP 668.
- The control node needs Python 3.12 or newer. Ubuntu 24.04 ships 3.12.3, which clears that by one minor version — close to the floor, so check the requirement before upgrading ansible-core. Managed nodes run the same 3.12.3.
- Pin collection versions in `requirements.yml`: `community.mysql`, `ansible.posix`, `community.general`, `community.crypto`.
- Set `ANSIBLE_CONFIG` explicitly so there is no doubt which `ansible.cfg` is read.

## Connectivity

- Ansible reaches managed nodes over their zone NIC, routed through `fw01`. `mgmt01` needs static routes to all three lab zones.
- Before the NAT NICs are removed, Ansible may still be reaching nodes over NAT. Verify with `ansible all -m setup -a 'filter=ansible_default_ipv4'` that the path is the intended one, since a working ping over the wrong NIC hides a broken route.
- `ansible_host` must be the zone IP, never the NAT IP, so the inventory stays valid after NAT removal.

## Structure

- Every role has `defaults/`, `tasks/`, `templates/` and `handlers/` as needed.
- One distro family means no `tasks/RedHat.yml` and `tasks/Debian.yml` split; keep a single task path and do not add per-OS branching for a case that cannot occur.
- `mgmt01` is the control node and configures itself, so keep whatever targets it in a separate play rather than in `site.yml`'s managed-node run.
- `site.yml` calls roles in dependency order: common -> router -> nfs -> mysql -> mysqlchk -> haproxy -> keepalived -> web -> mgmt. There is no firewall play (ADR-25) and no monitoring play (ADR-26).
- `fw01` must be configured before any role that depends on cross-zone reachability, and now also before anything that needs DNS or NTP, because it serves both.
- Group the inventory two ways: by role (`router`, `lb`, `web`, `db`, `nfs`, `mgmt`) and by zone (`dmz`, `app`, `dbzone`, `client`).
- Variables used in more than one place, such as the VIP, the domain, the zone subnets, the gateway octet and UID/GID, are defined **once** in `group_vars`.

## Idempotency

- Prefer standard modules with their fully qualified name over `shell` and `command`.
- When `command` is unavoidable, declare `changed_when` or `creates` so it cannot report a false change.
- Verify by running `site.yml` a second time; wherever a `changed` remains, fix that task.
- Use `ansible-playbook site.yml --check --diff` to detect configuration edited by hand on a node.
- Routing tasks are the usual source of false changes; template-plus-validate the masquerade file and compare current state before writing. No role may add a filter rule, and `community.general.ufw` is used in exactly one place, to disable `ufw` before the `common` role purges it.

## Safe configuration changes

- Every config template must have a `validate:` or a handler that checks syntax before the service reloads.
- Examples: `nginx -t` for Nginx, `haproxy -c -f %s` for HAProxy, `visudo -cf %s` for sudoers, `mysqld --validate-config` for MySQL, `nft -c -f %s` for the masquerade file.
- Never reload or restart a service whose config file has not passed a syntax check.
- Network changes are the dangerous class: a bad netplan apply can lock Ansible out. Stage them so the previous state is restored if connectivity is lost. Dropping the firewall removed the other way to do this, which was the point of ADR-25.

## Secrets

- Database passwords, the Telegram token and the CA private key all live in Ansible Vault.
- Name secret variables with a `vault_` prefix so a template makes it obvious which values are secret.
- Keep the vault password file outside the repo with mode 600; never commit it.
- Use `no_log: true` on any task that could print a secret.
- The VRRP password is limited to 8 characters by the protocol; generate it already truncated to avoid a confusing failure.

## Quality

- Run `ansible-lint` at the `production` profile before committing.
- Every task needs a `name` that clearly states what it does, in English and imperative mood; see `code-style.md`.
- Small commits, with a message naming the role that changed and why.

## Required libraries on managed nodes

- DB nodes need `PyMySQL` before `community.mysql` modules will work.
- Install those dependencies inside the matching role; never assume the box already has them.
