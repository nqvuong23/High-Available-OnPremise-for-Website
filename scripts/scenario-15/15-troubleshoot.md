# Scenario 15 — troubleshooting: one slow write, then everything looks normal

> Do not read **Root cause** until your own diagnosis is finished. Run every command by hand.

## What you see

- One write took about 3 seconds; after that writes are fast again.
- The shop works. Nobody would open a ticket for this.
- Yet the promise "a confirmed order exists on two machines" has quietly stopped being true.

## Step 1 — is the primary still semi-synchronous?

```bash
mysql --defaults-extra-file=~/.lab/ops.cnf -h 192.168.30.11 -e \
  "SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_source%'"
```

Read three values:

| Variable | Healthy | Here |
|---|---|---|
| `Rpl_semi_sync_source_status` | `ON` | `OFF` |
| `Rpl_semi_sync_source_clients` | `1` | `0` |
| `Rpl_semi_sync_source_no_tx` | stays still | climbs with every commit |

`no_tx` counts commits that were confirmed to the client **without** a replica acknowledgement.
Each one is an order that exists on one machine only.

## Step 2 — when did it fall back, and why?

```bash
ssh db01 'sudo grep -iE "semi-sync|timeout waiting" /var/log/mysql/error.log | tail -5'
mysql --defaults-extra-file=~/.lab/ops.cnf -h 192.168.30.11 -e "SHOW REPLICAS"
```

`Timeout waiting for reply of binlog` marks the moment, and `SHOW REPLICAS` is empty: no
replica is connected at all.

## Step 3 — the replica side

```bash
ping -c1 192.168.30.12
ssh db02 'systemctl status mysql --no-pager | head -5'
```

## Step 4 — what is the timeout, and is that the right number?

```bash
mysql --defaults-extra-file=~/.lab/ops.cnf -h 192.168.30.11 -e \
  "SHOW VARIABLES LIKE 'rpl_semi_sync_source_%'"
```

`timeout = 3000` explains the single 3 second write. `wait_point = AFTER_SYNC` is what makes
RPO=0 possible while semi-sync is ON.

---

## Root cause

MySQL on the replica `db02` was stopped. The primary waited the 3000 ms semi-sync timeout
for an acknowledgement on the next commit, then switched to async (ADR-08) and kept
accepting writes. From that moment until the replica returns, a primary failure loses every
order counted in `Rpl_semi_sync_source_no_tx`.

## Fix

```bash
ssh db02 'sudo systemctl start mysql'
```

Or `bash 15-rollback.sh`. The replica boots read-only, resumes replication, catches up, and the
primary switches semi-sync back ON by itself.

## Lesson

- Semi-sync degrades silently by design: availability over durability past the timeout.
- `Rpl_semi_sync_source_status` must be alerted on. M8 requires it, precisely for this.
- A single slow write is a symptom worth chasing.
