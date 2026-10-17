# Scenario 16 — troubleshooting and runbook RB-02: the primary is gone

> Do not read **Root cause** until your own diagnosis is finished. Every step is manual on
> purpose: promoting a database is the one decision this design never automates (ADR-07).
>
> Before injecting, start the measurement in its own terminal:
> `python3 16-order-writer.py`. Its timestamps are your RTO; its CSV is your RPO input.

## What you see

- Every write fails; the order writer prints `[FAIL]` lines with error 2013 or 2003.
- The stats page shows the primary DOWN and the replica in MAINT: the `mysql` listener has no
  server at all. Nothing moved by itself, and that is correct.

## Step 1 — rule out the router before blaming the database

```bash
ping -c1 192.168.30.254          # the db zone gateway, i.e. fw01
ping -c1 192.168.30.12           # the replica
ping -c1 192.168.30.11           # the primary
```

If the gateway or the replica fails too, this is a routing outage (scenario 01). Do **not**
promote anything: both nodes may be alive and writable behind a broken router.

## Step 2 — prove the primary is dead, not slow (fencing)

```bash
ssh -o ConnectTimeout=3 db01 true; echo "ssh exit $?"
nc -zv -w2 192.168.30.11 3306
```

On Windows, `vagrant status db01` must say `poweroff`. In this lab the powered-off VM is the
fence: it cannot come back writable by itself, and it boots read-only anyway (ADR-09).
Promoting while the old primary might still accept writes is how two primaries happen.

## Step 3 — has the replica applied everything it received?

```bash
mysql --defaults-extra-file=~/.lab/ops.cnf -h 192.168.30.12 -e 'SHOW REPLICA STATUS\G' \
  | grep -E 'Replica_IO_Running|Replica_SQL_Running:|Retrieved_Gtid_Set|Executed_Gtid_Set|Last_IO_Error:'
```

`Replica_IO_Running: Connecting` is expected: its source is gone. What matters is that the
SQL thread applied every retrieved transaction. Wait for it explicitly:

```bash
mysql --defaults-extra-file=~/.lab/ops.cnf -h 192.168.30.12 -N -e \
  "SELECT WAIT_FOR_EXECUTED_GTID_SET('<paste Retrieved_Gtid_Set>', 30)"     # 0 = applied
```

## Step 4 — promote the replica

```bash
mysql --defaults-extra-file=~/.lab/ops.cnf -h 192.168.30.12 -e \
  "STOP REPLICA; RESET REPLICA ALL; SET GLOBAL super_read_only = OFF; SET GLOBAL read_only = OFF"
```

`RESET REPLICA ALL` removes the link to the old primary, so `db02` will not try to replicate
from `db01` when it comes back.

## Step 5 — move HAProxy, on both LBs

```bash
for lb in lb01 lb02; do
  ssh $lb "echo 'disable server mysql/db01' | sudo socat stdio /run/haproxy/admin.sock;
           echo 'enable server mysql/db02'  | sudo socat stdio /run/haproxy/admin.sock"
done
```

Both LBs, because the VIP can move between them at any time. This is a runtime change:
a HAProxy reload reverts it to `haproxy.cfg`.

## Step 6 — verify, then measure

```bash
mysql --defaults-extra-file=~/.lab/wp.cnf -e 'SELECT @@hostname, @@read_only'   # db02, 0
```

Wait for the order writer to print `write path restored after N.NNs`, stop it with Ctrl-C,
and record `rto_ms` from its summary. Then:

```bash
python3 16-rpo-check.py               # rpo_missing must be 0 while semi-sync was ON
```

---

## Root cause

The primary was powered off without a shutdown. HAProxy marked it DOWN within about 6 seconds,
and the replica is `disabled` in the `mysql` listener by design, so writes stopped until a
human promoted it. With semi-sync `AFTER_SYNC`, every order the application saw as confirmed
had already reached the replica: RPO = 0, provided semi-sync was ON at the moment of failure
(scenario 15 shows when it is not).

## Returning to normal — RB-03

Start `db01` from Windows (`vagrant up db01`), then `bash 16-rollback.sh`. It:

- refuses if both nodes are writable;
- checks for **errant GTIDs** on `db01`: transactions written to its binlog that `db02`
  never received. They exist when `db01` died between syncing its binlog and getting the
  replica's acknowledgement; no client was told they succeeded. Rejoining with them would
  hide them or break replication later, so the script stops and leaves the decision to you;
- rejoins `db01` as a replica of `db02`, then offers a planned switchover back.

## Lesson

- Rule out the router, then prove the primary is fenced. Only then promote.
- RTO here is mostly human time: detection, the checks above, two commands, two LBs.
- An unplugged primary can leave transactions only it knows about. The errant GTID check
  before rejoining is what keeps them from silently disappearing.
