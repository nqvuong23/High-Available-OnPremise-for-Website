# Scenario 11 — troubleshooting: uploads fail on one node, everything else looks fine

> Do not read **Root cause** until your own diagnosis is finished. Run every command by hand.
> This is the class of failure that took the original single VPS down for three hours.

## What you see

- Uploading a product image through wp-admin fails for some users with
  `The uploaded file could not be moved` or `Failed to write file to disk`.
- Browsing works, the stats page is all green.

## Step 1 — which node, and is it about the user?

Uploads go to one node per session (sticky cookie). Check every web node rather than
guessing which one served the failing request.

```bash
for h in web01 web02; do echo "== $h"; ssh $h 'df -h / ; df -i /'; done
```

## Step 2 — how can root still write?

```bash
ssh web01 'sudo touch /var/tmp/root-test && echo root can write; sudo rm -f /var/tmp/root-test'
ssh web01 'sudo -u www-data touch /tmp/www-test && echo www-data can write || echo www-data cannot'
ssh web01 'sudo tune2fs -l $(findmnt -n -o SOURCE /) | grep -iE "reserved block count|block size"'
```

ext4 keeps about 5% of blocks for root, so root, `sshd` and `sudo` still work while every
service running as a normal user gets `No space left on device`. That is why you could log
in to diagnose, and also why "I can write a file as root" proves nothing.

## Step 3 — what is using the space?

```bash
ssh web01 'sudo du -xh --max-depth=1 / 2>/dev/null | sort -h | tail -8'
ssh web01 'sudo du -xh --max-depth=1 /var 2>/dev/null | sort -h | tail -5'
ssh web01 'sudo find / -xdev -type f -size +200M -printf "%s %u %p\n" 2>/dev/null | sort -n | tail -5'
```

`-x` stays on the root filesystem, so the NFS mount is never walked.

## Step 4 — space held by deleted files

```bash
ssh web01 'sudo lsof +L1 2>/dev/null | head'
ssh web01 'sudo journalctl --disk-usage'
```

A file deleted while a process holds it open keeps its blocks until the process closes it.
`du` cannot see it; `lsof +L1` can. Restarting the holder frees the space.

## Step 5 — who noticed?

```bash
ssh web01 'sudo tail -n 3 /var/log/nginx/error.log'
```

Nothing alerted. HAProxy's check only proves PHP answers, not that the node can store data.

---

## Root cause

Two files owned by `nobody`, `/var/tmp/lab-chaos-11.fill` and `.fill.tail`, filled the root
filesystem of `web01` to 100% for every non-root user. PHP writes uploads to its temp directory on `/` before moving them to
NFS, so uploads through `web01` fail while pages still render.

## Fix

```bash
ssh web01 'sudo rm -f /var/tmp/lab-chaos-11.fill /var/tmp/lab-chaos-11.fill.tail'
```

Or `bash 11-rollback.sh`. In a real incident: find the writer before deleting anything, and
never delete a file a process still holds open; restart the process instead.

## Lesson

- Check `df -h` **and** `df -i`: a filesystem can be full of inodes with blocks to spare.
- Root's reserved blocks keep the box manageable and hide the problem from root at once.
- Disk usage needs an alert well before 100%: M8 requires one that fires before the
  filesystem is full, precisely because of this scenario.
