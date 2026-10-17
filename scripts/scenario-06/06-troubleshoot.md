# Scenario 06 — troubleshooting: browsers refuse the site, every health check says it is up

> Do not read **Root cause** until your own diagnosis is finished. Run every command by hand.

## What you see

- Browsers show a certificate warning; `curl https://shop.lab.internal` fails with exit 60.
- HTTP still answers 301, every HAProxy backend is UP, and `curl -k` returns 200.
- A check that only tests "port 443 open" would report this outage as healthy.

## Step 1 — read curl's exact complaint

```bash
curl -sv https://shop.lab.internal -o /dev/null 2>&1 | grep -iE "subject|issuer|expire|SSL|error"
echo "exit: $?"
curl -sk -o /dev/null -w '%{http_code}\n' https://shop.lab.internal/
```

`-k` succeeding means TLS works and the backend works. Only the validation step fails.
Read the error: is it an unknown issuer, an expired date, or a name mismatch?

## Step 2 — look at the certificate the VIP actually serves

```bash
echo | openssl s_client -connect 192.168.10.100:443 -servername shop.lab.internal 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

Check the subject, the issuer, both dates, and every name in the SAN. Clients validate the
**SAN**, not the CN.

## Step 3 — does the chain verify?

```bash
echo | openssl s_client -connect 192.168.10.100:443 -servername shop.lab.internal \
  -CAfile /usr/local/share/ca-certificates/lab-ca.crt 2>/dev/null | grep -E "Verify return|verify error"
```

`Verify return code: 0 (ok)` with a hostname failure in curl means the issuer is trusted and
only the name is wrong.

## Step 4 — is it the same on both LBs?

```bash
for lb in lb01 lb02; do echo "== $lb"; ssh $lb 'sudo openssl x509 -in /etc/haproxy/certs/shop.pem -noout -fingerprint -sha256 -ext subjectAltName'; done
ssh lb01 'sudo ls -l /etc/haproxy/certs/'
```

Compare fingerprints. A different certificate on the backup is a separate bug that only
appears after a failover.

## Step 5 — what should it be?

```bash
ssh lb01 'sudo openssl x509 -in /root/ca/shop.crt -noout -ext subjectAltName -dates'
```

---

## Root cause

The bundle in `/etc/haproxy/certs/shop.pem` on both LBs was replaced by a certificate for
`wrong.lab.internal`, signed by the real lab CA. The chain is trusted; the SAN does not
contain `shop.lab.internal`, so every validating client rejects it.

## Fix

```bash
bash 06-rollback.sh
```

The real fix path is Ansible: `ansible-playbook site.yml --tags lb` rewrites the bundle from
`/root/ca/shop.crt`, because the `haproxy` role owns that file.

## Verify

```bash
curl -sI https://shop.lab.internal | head -1      # no -k
```

## Lesson

- Separate "TLS works" from "this certificate is valid for this name" with `curl -k`.
- A port check is not a certificate check. Whatever watches TLS has to validate the name and
  the expiry date, or it reports a certificate outage as healthy — which is exactly what
  HAProxy's own backend checks do here.
- Compare both LBs: a certificate fault on the backup is invisible until the VIP moves.
