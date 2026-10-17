# Scenario 08 — troubleshooting: the web server is up, the node is DOWN anyway

> Do not read **Root cause** until your own diagnosis is finished. Run every command by hand.

## What you see

- The stats page shows one web node DOWN, like scenario 07.
- But that node still serves static files: the NFS probe file loads fine from it.
- `systemctl status nginx` on the node is green.

## Step 1 — the reason HAProxy gives

```bash
source ~/.lab/secrets.env
curl -s -u "$LAB_STATS_USER:$LAB_STATS_PASS" 'http://192.168.10.11:8404/stats;csv' \
  | awk -F, '$1=="be_web"' | cut -d, -f2,18,37,38
```

`L7STS` with `check_code` 502. Not refused, not a timeout: Nginx answered, and the answer
was an error. Compare with scenario 07, where the same DOWN came from `L4CON`.

## Step 2 — static versus dynamic

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.20.11/wp-content/uploads/lab-probe.txt
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.20.11/healthz.php
```

The static file is 200, anything PHP is 502. Nginx is fine; what is behind it is not.

## Step 3 — what does Nginx say?

```bash
ssh web01 'sudo tail -n 5 /var/log/nginx/error.log'
```

Look for `connect() to unix:/run/php/php8.3-fpm.sock failed`. `(2: No such file or
directory)` means nothing created the socket, `(111: Connection refused)` means the socket
exists with nobody behind it, `(13: Permission denied)` means a socket ownership problem.

## Step 4 — the PHP-FPM side

```bash
ssh web01 'ls -l /run/php/'
ssh web01 'systemctl status php8.3-fpm --no-pager | head -8'
ssh web01 'sudo journalctl -u php8.3-fpm -n 20 --no-pager'
ssh web01 'sudo php-fpm8.3 -t'
```

---

## Root cause

PHP-FPM was stopped on `web01`. Nginx kept running and returned `502 Bad Gateway` for every
PHP request, including `/healthz.php`, so HAProxy marked the node DOWN at layer 7. Static
files kept working, which is what makes "the web server is up" misleading.

## Fix

```bash
ssh web01 'sudo php-fpm8.3 -t && sudo systemctl start php8.3-fpm'
```

Or `bash 08-rollback.sh`.

## Lesson

- `/healthz.php` goes through PHP-FPM on purpose: a check on a static file would have kept
  this node in rotation while every page failed.
- The Nginx error log names the exact failing upstream; read it before restarting things.
- Same DOWN on the stats page, different `check_status`: 07 is layer 4, 08 is layer 7.
