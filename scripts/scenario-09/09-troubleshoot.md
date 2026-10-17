# Scenario 09 — troubleshooting: pages hang, but every health check is green

> Do not read **Root cause** until your own diagnosis is finished. Run every command by hand.
>
> **Warning:** do not run a bare `ls` on `/var/www/wordpress/wp-content/uploads` while you
> investigate. If the mount is dead your shell blocks and cannot be interrupted. Prefix
> every command touching it with `timeout -s KILL 3`.

## What you see

- Pages load slowly or never finish; product images stay blank.
- HAProxy shows both web nodes UP, at least at first.
- After a while both web nodes may turn DOWN together, even though nobody touched them.

## Step 1 — is the web tier alive?

```bash
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://192.168.20.11/healthz.php
curl -s -o /dev/null -m 5 -w '%{http_code} %{time_total}s\n' http://192.168.20.11/wp-content/uploads/lab-probe.txt
```

`healthz.php` answers instantly; the uploads file hangs until curl gives up. The difference
between the two requests is exactly one thing: the second one touches NFS.

## Step 2 — what are the processes doing?

```bash
ssh web01 'ps -eo pid,stat,wchan:32,cmd | awk "\$2 ~ /^D/"'
```

State `D` is uninterruptible sleep, and a `wchan` like `rpc_wait_bit_killable` or
`nfs_wait_bit_killable` means waiting on an NFS reply. These are not PHP bugs and restarting
PHP-FPM will not help: new workers block the same way.

## Step 3 — what does the kernel say?

```bash
ssh web01 'sudo dmesg -T | grep -i nfs | tail -5'
ssh web01 'findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /var/www/wordpress/wp-content/uploads'
ssh web01 'sudo timeout -s KILL 3 stat /var/www/wordpress/wp-content/uploads; echo "exit $?"'
```

`server 192.168.20.21 not responding, still trying` is the `hard` mount doing its job:
retrying forever instead of returning an error. Exit 137 is the timeout killing a stuck stat.

## Step 4 — the server side

```bash
ping -c1 192.168.20.21
ssh nfs01 'systemctl status nfs-server --no-pager | head -6'
ssh nfs01 'sudo ss -ltn | grep 2049; cat /proc/fs/nfsd/threads 2>/dev/null'
ssh nfs01 'sudo exportfs -v'
```

The host answers ping, but nothing listens on 2049 and nothing is exported.

## Step 5 — why did both web nodes turn DOWN later?

```bash
curl -s http://192.168.20.11/fpm-status
```

Every request that touched uploads holds a PHP-FPM worker in state D. Once all
`pm.max_children` workers are stuck, even `/healthz.php` cannot get a worker, the checks time
out, and HAProxy drops both nodes together.

---

## Root cause

`nfs-server` was stopped on `nfs01`. The uploads export is mounted `hard` (ADR-11), so every
access blocks instead of failing. The shallow health check (ADR-05) deliberately ignores NFS,
so HAProxy keeps sending users to nodes that will hang, until workers run out.

## Fix

```bash
ssh nfs01 'sudo systemctl start nfs-server'
```

Or `bash 09-rollback.sh`. Clients recover by themselves, but the server starts in a grace
period: new opens can wait up to the NFSv4 lease time, 90 seconds by default. Measure it.

## Lesson

- Processes in state D waiting on NFS are a storage outage wearing a PHP costume.
- `hard` trades availability for integrity: no corrupted upload, but a hung tier. That is the
  accepted cost in ADR-11, and `nfs01` is the documented SPOF of ADR-10.
- The shallow check keeps one NFS outage from dropping both nodes instantly; it cannot stop
  exhaustion from doing it slowly. NFS needs its own monitoring.
