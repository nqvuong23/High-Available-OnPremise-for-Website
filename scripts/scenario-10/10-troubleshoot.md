# Scenario 10 — troubleshooting: about half the users see broken images

> Do not read **Root cause** until your own diagnosis is finished. Run every command by hand.

## What you see

- Some users see product images, others get broken images and failed uploads.
- It sticks to the user: refresh all you want, the same person keeps the same result.
- Every health check is green and both web nodes are UP.

## Step 1 — make "some users" precise

Users are pinned to one node by the `SRV` cookie, which explains "it sticks to the user".

```bash
for c in w1 w2; do
  printf '%s ' $c; curl -s -o /dev/null -w '%{http_code}\n' -b "SRV=$c" \
    https://shop.lab.internal/wp-content/uploads/lab-probe.txt
done
```

One cookie gets 200, the other an error. The fault belongs to one node, not to the shop.

## Step 2 — confirm it on the node directly

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.20.11/wp-content/uploads/lab-probe.txt
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.20.12/wp-content/uploads/lab-probe.txt
ssh web02 'sudo tail -n 3 /var/log/nginx/error.log'
```

## Step 3 — what does the client see on the mount?

```bash
ssh web02 'findmnt /var/www/wordpress/wp-content/uploads'
ssh web02 'sudo -u www-data timeout -s KILL 3 ls -l /var/www/wordpress/wp-content/uploads | head -3'
ssh web02 'sudo dmesg -T | grep -i nfs | tail -5'
```

The mount is still listed, but access returns `Permission denied` or `Stale file handle`,
immediately. Not a hang: the server is up and answering, and saying no.

## Step 4 — ask the server what it exports, and to whom

```bash
ssh nfs01 'sudo exportfs -v'
ssh nfs01 'cat /etc/exports'
ssh nfs01 'ls -l /etc/exports*'
```

Count the client addresses. Is every web node listed?

## Step 5 — detect the drift the configuration-management way

```bash
cd ~/linux_project/ansible
ansible-playbook site.yml --check --diff --limit nfs01 --tags nfs
```

The diff of `/etc/exports` shows exactly what changed against the code.

---

## Root cause

`web02` was removed from `/etc/exports` on `nfs01` and the exports reloaded. Its existing
mount stays visible, but the server now refuses every request from it. `/healthz.php` never
reads NFS (ADR-05), so HAProxy keeps `web02` in rotation, and the users pinned to it get
broken images.

## Fix

```bash
bash 10-rollback.sh
```

The durable fix is `ansible-playbook site.yml --tags nfs`, which rewrites `/etc/exports`
from the template. A client whose handle went stale needs a remount.

## Lesson

- "Some users, consistently" plus sticky sessions means one node: pin a cookie and compare.
- An immediate error is a live server refusing; a hang is a dead server (scenario 09).
- `--check --diff` turns "someone edited a file by hand" from a guess into evidence.
