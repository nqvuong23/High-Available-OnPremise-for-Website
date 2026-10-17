# Scenario 03 — troubleshooting: "the site is down" but only by name

> Do not read **Root cause** until your own diagnosis is finished. Run every command by hand.

## What you see

- `curl https://shop.lab.internal` from `mgmt01` fails, or reports the host is not found.
- The audit shows the site fine when it is reached **by the VIP address**.
- Orders still write: the database path is untouched.

## Step 1 — separate "cannot resolve" from "cannot connect"

```bash
curl -sv https://shop.lab.internal -o /dev/null 2>&1 | head -5
curl -s -o /dev/null -w '%{http_code}\n' --resolve shop.lab.internal:443:192.168.10.100 https://shop.lab.internal/
```

The first fails before any TCP connection (`Could not resolve host`). The second, with
the name pinned to the VIP, answers 200. The service is fine; the name is not.

## Step 2 — ask the lab DNS server directly

```bash
dig @172.16.10.254 shop.lab.internal +time=1 +tries=1
```

A timeout here means the server is not answering at all. Compare with what the system
resolver of `mgmt01` returns:

```bash
getent hosts shop.lab.internal
resolvectl query shop.lab.internal
resolvectl status | sed -n '/Link/,/DNS Servers/p'
```

`mgmt01` carries public fallback resolvers on purpose (`deploy-v1.md` section 20), so you
may get **NXDOMAIN from 8.8.8.8** instead of a timeout. An NXDOMAIN for a lab name is a
sign the lab server never answered, not that the record was deleted.

## Step 3 — the same from a lab node, which has no fallback

```bash
ssh web01 'resolvectl query shop.lab.internal; getent hosts db01.lab.internal'
```

## Step 4 — is the service on the router listening?

```bash
ssh fw01 'systemctl status named --no-pager | head -5'
ssh fw01 'sudo ss -lunp | grep ":53 "'
ssh fw01 'sudo journalctl -u named -n 20 --no-pager'
```

## Step 5 — would it start cleanly?

```bash
ssh fw01 'sudo named-checkconf -z'
```

If the config were broken, this is where it would show. Here it passes.

---

## Root cause

`named` is stopped on `fw01`. Everything addressed by IP keeps working, including
WordPress, which reaches MySQL through `192.168.10.100` and not a name. Anything that
starts from a lab name fails, and `fw01` itself loses all DNS because its
`/etc/resolv.conf` points at its own bind9.

## Fix

```bash
ssh fw01 'sudo systemctl start named'
```

Or `bash 03-rollback.sh`.

## Verify

```bash
dig +short @172.16.10.254 shop.lab.internal      # 192.168.10.100
```

## Lesson

- Split "resolve" from "connect" first: `curl --resolve` takes DNS out of the picture.
- The blast radius of a DNS outage depends on what was configured by name. Here only the
  operators lose, not the shop, because `DB_HOST` and every backend use addresses.
- A fallback resolver turns a timeout into NXDOMAIN. Know which one your client has.
