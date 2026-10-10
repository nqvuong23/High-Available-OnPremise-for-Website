---
paths:
  - "ansible/roles/haproxy/**"
  - "ansible/roles/keepalived/**"
  - "ansible/roles/pki/**"
---

# HAProxy, Keepalived and the internal PKI

> Both LBs run Ubuntu 24.04 in the dmz zone with **identical configuration**; the only difference is the Keepalived priority.
> lb01 is `192.168.10.11`, lb02 is `192.168.10.12`, the VIP is `192.168.10.100`.

## Internal PKI

- Create a self-signed CA with `community.crypto`; keep the CA private key out of the repo.
- The server certificate SAN must contain `DNS:shop.lab.internal` and `IP:192.168.10.100`.
- HAProxy needs a PEM file holding both the certificate and the private key, mode 600.
- Import the CA into the Windows Trusted Root store so the browser stops warning.
- Also install the CA on `mgmt01`, otherwise `curl` from the test client fails and that looks like an HAProxy fault.

## HAProxy

- Install HAProxy 3.3 from the upstream HAProxy APT repository; Ubuntu 24.04 only ships 2.8, so the role adds the repository and its signing key first.
- Validate the config with `haproxy -c -f %s` before any reload; a template that fails validation must never reach a running node.
- Frontend on port 80: redirect 301 to HTTPS, and serve the `monitor-uri` that Keepalived checks.
- Frontend on port 443: bind the certificate, force TLS 1.2 minimum, add `X-Forwarded-For` and `X-Forwarded-Proto: https`.
- Web backend: `balance roundrobin`, sticky cookie `SRV`, health check `GET /healthz.php` against `192.168.20.11:80` and `192.168.20.12:80`.
- Web health check parameters: `check inter 2s fall 3 rise 2`, plus `option redispatch` and `retries 3`.
- `inter 2s fall 3` is exactly why a broken node leaves the backend within about 6 seconds, matching the SLO.
- `listen mysql` in TCP mode on port 3306, servers `192.168.30.11` and `192.168.30.12`, health checked through port 9200 on `mysqlchk`.
- In the normal state db01 is `check` and db02 is `disabled`, which corresponds to MAINT.
- Stats page on port 8404 with authentication, restricted to administrative sources.
- Enable the admin socket so the Runtime API can enable and disable servers without a reload.

## Cross-zone considerations

- Both backends are in other zones, so every health check and every proxied connection is forwarded by `router01`.
- If `router01` is down, HAProxy marks every backend DOWN and the stats page shows a total outage that is actually a routing failure. Check the route before suspecting the backends.
- Connection timeouts must allow for the extra routed hops; do not tune them so tight that a normal router hop looks like a failure.
- The web-to-DB path enters HAProxy from the app zone and leaves towards the db zone, so `listen mysql` must accept connections sourced from `192.168.20.%`.

## Logging and log rotation

- Configure rsyslog to receive HAProxy logs and write them to a dedicated file.
- Confirm logrotate actually runs, because the root cause in the original ticket was a full disk.
- Verify with `logrotate -d`, then force a rotation and check the service can still write.

## Keepalived

- Install Keepalived 2.2.8 from Ubuntu apt; one VRRP instance with `virtual_router_id 51`.
- lb01 gets priority 110, lb02 gets priority 100, preempt left at its default.
- `advert_int 1` puts detection at roughly 3 seconds, within the under-6-second SLO.
- Declare the interface through the `lab_iface` variable, since guest NIC names differ between machines.
- The VRRP instance binds the dmz NIC. It must not be bound to the temporary NAT NIC, or the VIP appears on the wrong segment.
- Take the authentication password from Vault and keep it at 8 characters or fewer, as the protocol requires.

## track_script

- The check script must confirm HAProxy **actually responds**, not merely that the process is alive.
- Implementation: `curl` the `monitor-uri` on localhost with a 1 second timeout.
- Declare `interval 2 fall 2 rise 2` and `weight -20` so the MASTER priority drops below the BACKUP when HAProxy breaks.
- Enable `enable_script_security` and make sure the script is not in a world-writable directory.

## System requirements

- Set `net.ipv4.ip_nonlocal_bind=1`, because HAProxy on the BACKUP node must bind a VIP it does not own yet.
- Open IP protocol 112 between the two LBs; `ufw` has no `proto vrrp`, so add the rule to `/etc/ufw/before.rules`.
- VRRP is link-local and stays inside `vmnet1`; it is never routed and must never be expected to cross a zone.
- If the host-only segment blocks multicast, switch to `unicast_src_ip` and `unicast_peer`.

## Acceptance

- `curl -I http://shop.lab.internal` returns 301 and `curl -I https://shop.lab.internal` validates against the internal CA, both run from `mgmt01` so the request is routed.
- From `mgmt01`, connect with `mysql -h 192.168.10.100` and confirm it is talking to the current primary.
- Run a continuous probe or k6, stop HAProxy on lb01, measure how long the VIP takes to move and count failed requests.
- Start HAProxy on lb01 again and watch it take the VIP back through preempt, recording the second short interruption.
- Confirm `router01` is not in the VRRP path: stopping the router must not move the VIP, though it will mark the backends DOWN.
