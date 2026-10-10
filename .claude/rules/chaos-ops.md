---
paths:
  - "chaos/**"
  - "postmortems/**"
  - "docs/runbooks/**"
  - "scripts/**"
  - "loadtest/**"
---

# Failure simulation, runbooks and operations

> This is the biggest differentiator in an interview: evidence of having handled real incidents and drawn lessons from them.

## Procedure for every scenario

- Restore to the `baseline` snapshot, or confirm the system is healthy.
- Start `probe.sh` in the background before injecting, so the real user impact is measured.
- Inject with `inject.sh`; ideally have someone else pick a scenario you do not know in advance.
- Work it like an on-call engineer and **do not read the root cause before finishing the diagnosis**.
- Restore service, identify the root cause, then roll back through Ansible rather than by hand.
- Write the postmortem immediately afterwards, while the detail is fresh.

## Chaos directory layout

- One directory per scenario: `chaos/Sxx-<name>/`.
- Inside: `inject.sh` to break it, `rollback.sh` to restore it, and `README.md` with the learning goal and expected observations.
- 19 scenarios planned, at least 10 required, at least 12 fully completed.

## Identified scenarios

- Code drift between the two web nodes, simulating a plugin installed through wp-admin on one machine.
- NFS death leaving PHP processes hung in state D, which is not a PHP fault.
- A database failure affecting only one web node, which the deliberately shallow health check cannot detect.
- A wrong GRANT, from forgetting that MySQL sees the LB address as the source rather than the web node address.
- Sudden primary death, used to measure RTO and RPO.
- `router01` down, which breaks every cross-zone flow at once: HAProxy marks all backends DOWN, web nodes cannot reach the DB VIP, and Ansible cannot reach anything. The lesson is distinguishing a routing outage from a service outage.
- A static route removed on one node, so it can reach its own zone but nothing else, which looks exactly like a firewall problem.
- IP forwarding turned off on `router01`, a partial version of the same failure that is harder to spot because the router itself still answers pings.

## Additional candidates to fill the catalogue

- Stop HAProxy or Keepalived on the node currently holding the VIP.
- Stop Nginx or PHP-FPM on one web node.
- Break the NFS export options or the UID/GID mapping so Nginx cannot read the uploads directory.
- Fill the disk, and a separate scenario that fills the inode table.
- Wrong firewall rule blocking 3306, 2049, 9200 or VRRP.
- Masquerade rule removed on `router01`, so the lab keeps working but `apt` stops, which only surfaces on the next deployment.
- A web node given a second NIC into the db zone, bypassing the router: everything works, and the isolation test silently stops meaning anything.
- Replication lag spiking, or the IO thread failing.
- Replica death letting semi-sync silently downgrade to async.
- A primary restarted while the operator forgets to open write access.
- Clock drift between nodes from a broken chrony.
- A TLS certificate expired or carrying the wrong SAN.
- Configuration edited by hand on a node, detected with `--check --diff`.

## Runbooks

- RB-01 — load balancer and VIP failover when the active HAProxy dies, including how to measure the interruption.
- RB-02 — database failover when the primary dies: confirm it is fenced, choose the replica, open write access, switch HAProxy, verify.
- RB-03 — returning the old primary as a replica, with a mandatory errant GTID check first.
- RB-04 — opening write access after a planned primary restart, since MySQL always boots read-only.
- Every runbook follows the same frame: symptoms, how to confirm, the steps, how to verify, how to roll back.
- Each runbook must say early on how to rule out a routing or router failure, because that fault presents as a failure of whatever layer is being investigated.
- Acceptance: someone else can follow it without asking a single question.

## Postmortem template

- A few lines summarising the incident.
- Real impact, with numbers from `probe.sh` rather than estimates.
- Timeline: detected, work started, service restored.
- Root cause, clearly separated from the surface symptom.
- What went well and what did not.
- Measured RTO and RPO.
- Corrective actions so it cannot happen the same way again.
- The new rule learned, to be added to `triage.py`.

## Operations scripts

- `probe.sh` — hits the VIP continuously, records timestamp, HTTP code and duration, and totals the outage time. Run from `mgmt01` so it takes the routed client path.
- `healthcheck.py` — runs every minute and checks the VIP, HAProxy stats, each web node health, replication, semi-sync, read-only state, NFS, disk and inodes.
- `healthcheck.py` must also check reachability of each zone gateway, so a router fault is reported as itself instead of as eight unrelated failures.
- Telegram alerting must resist spam: group repeated errors, hold a cooldown between messages, and send a recovery notice.
- `diagnose.yml` — one command that collects all evidence onto the admin box: `ss`, journal, `df -h`, `df -i`, service states, `ip route`, `nft list ruleset`, AppArmor denials.
- `triage.py` — applies rules learned from postmortems to the diagnostic data and prints suspicions with the next command to run.
- `auto_remediate.sh` — only handles safe faults such as restarting Nginx or PHP-FPM, with a per-hour limit, a `--dry-run` mode, and it **never touches MySQL**.
- `db_failover.py` — assists a failover: checks the safety conditions, requires operator confirmation, and only then acts.
- `order_writer.py` and `rpo_check.py` — create orders continuously and reconcile confirmed orders to measure RPO.

## Automatic versus manual

- Automated because the risk is low: VIP movement, removing a failed web node, log rotation, disk and inode detection, sending alerts.
- Left to a human because the risk is high: promoting a database, opening write access, returning an old primary as a replica, handling errant GTIDs, rolling back a large configuration change, anything touching order data.
- Network changes sit with the human too: a bad route or firewall apply can lock everyone out of the lab.

## Load test

- The k6 scenario simulates viewing the home page, viewing a product and adding to the cart.
- Set pass/fail thresholds for p95 and error rate inside the scenario itself.
- Run it from `mgmt01` in the client zone, so the measurement includes the routed hops a real user pays for.
- Run a baseline with default configuration first and save the result.
- Tune **one variable at a time** and rerun the same scenario, so it is clear which change actually helped.
- Finish with a before-and-after table of p95, RPS and error rate, with an explanation.
