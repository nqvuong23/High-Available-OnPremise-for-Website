---
paths:
  - "ansible/roles/nginx_php/**"
  - "ansible/roles/wordpress/**"
  - "ansible/roles/nfs_server/**"
  - "ansible/roles/nfs_client/**"
---

# Web, WordPress and NFS on Ubuntu 24.04

> The two web nodes must be **identical**. Any difference between web01 and web02 is a bug to fix.
> web01 is `192.168.20.11`, web02 is `192.168.20.12`, nfs01 is `192.168.20.21`, all inside the app zone.

## NFS

- The server runs on nfs01 with `nfs-kernel-server`, NFSv4 only, v3 disabled.
- Export `/srv/nfs/uploads` to exactly the two web node addresses, with `rw,sync,no_subtree_check`.
- Clients install `nfs-common` and mount with `nfsvers=4.2,hard,noatime,_netdev`.
- NFS traffic stays inside the app zone and never touches `router01`, which is why an NFS failure cannot be confused with a routing failure.
- Mounting `hard` is deliberate: data integrity first, at the cost of processes hanging in state D when NFS dies.
- Mount only `wp-content/uploads`, never the whole WordPress tree.

## UID and GID

- Create the `www-data` group and user with the **same fixed UID and GID** on web01, web02 and nfs01.
- Ubuntu ships `www-data` as UID 33 by default, but do not rely on the default: pin the number explicitly so a package install order cannot change it.
- Create them **before** installing packages, otherwise a package assigns an arbitrary number and the nodes drift.
- Mismatched UIDs over NFS cause permission errors that are very hard to spot, because the directory still lists normally.

## Nginx and PHP-FPM

- Install `nginx` 1.30.5 from the upstream nginx APT repository; Ubuntu 24.04 only ships 1.24.0, so the role adds the repository and its signing key first.
- Install `php8.3-fpm` from Ubuntu apt; it is in the default repositories, so no extra repo step is needed.
- PHP extensions WooCommerce needs: `mysqlnd`, `gd`, `mbstring`, `xml`, `intl`, `opcache`, `zip`, `curl`.
- PHP-FPM runs as `www-data`, listens on a unix socket, `pm=dynamic`.
- Set `pm.max_children` from the real measured memory per process, never by guesswork.
- Enable `pm.status_path` for `/fpm-status`, restricted to administrative sources and the LBs.
- Use `set_real_ip_from` with the two LB addresses so Nginx logs the real client IP instead of the LB.
- Set `client_max_body_size` together with `upload_max_filesize` and `post_max_size` large enough for product images.
- Nginx listens on the app-zone IP and loopback; it must not bind the temporary NAT NIC.

## Health check

- `/healthz.php` returns a static string only, proving Nginx can reach PHP-FPM.
- It must **not** query the database and must **not** read NFS.
- Reason: a shared component failing would make HAProxy drop both web nodes at once and turn one fault into a full outage.
- Accepted consequence: DB and NFS failures must be caught by `healthcheck.py`, not through HAProxy.

## AppArmor on Ubuntu 24.04

- Keep AppArmor enforcing; do not set a profile to complain mode just to make an error go away.
- Ubuntu ships no enforcing profile for Nginx or PHP-FPM by default, so the web path usually needs no profile work. Confirm that rather than assuming it, with `aa-status`.
- NFS access from Nginx needs no boolean equivalent, unlike SELinux. If reads from the mount fail, the cause is UID/GID or export options, not a security module.
- When a service breaks unexpectedly, check `journalctl -k | grep -i apparmor` and `/var/log/syslog` for DENIED lines **before** suspecting the application configuration.
- If a profile does have to change, ship it through Ansible with `aa-complain` never used as a permanent fix.

## WordPress and WooCommerce

- Download a single artifact and deploy it to both nodes so the code is byte-identical; verify the checksum on download.
- Pin the WordPress, WooCommerce and WP-CLI versions in `group_vars`; never use "latest".
- `wp-config.php` sets `DB_HOST` to `192.168.10.100:3306`, which means it goes through HAProxy in the dmz zone.
- Set `DISALLOW_FILE_MODS=true` so nobody can install a plugin through the admin UI and make the nodes drift.
- Set `WP_HOME` and `WP_SITEURL` to `https://shop.lab.internal`.
- Read the `X-Forwarded-Proto` header and set `$_SERVER['HTTPS']='on'`, otherwise the site loops on redirects or serves mixed content.
- Take the salts from Vault; `wp-config.php` is mode 640 owned by `root:www-data`.
- Disable the default WP-Cron and run a system cron on **one node only**, so WooCommerce scheduled tasks do not run twice.
- Run `wp core install` **exactly once** on web01, with `run_once` and a guard so it only runs when not already installed.

## Acceptance

- Place a real order over HTTPS and confirm it appears on both db01 and db02.
- Upload an image through web01 and view it through web02, then the other way round.
- Compare `sha256sum` across the whole code tree on both nodes; it must match exactly.
- Stop Nginx on one node and confirm HAProxy marks it DOWN within about 6 seconds while the site keeps serving.
- Confirm a web node cannot reach `192.168.30.11:3306` directly; only the VIP path may work.
