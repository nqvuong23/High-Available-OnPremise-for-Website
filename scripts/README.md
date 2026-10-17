# Failure scenarios

Runs on `mgmt01`, after `ansible-playbook site.yml`. The playbook writes the two things every
script reads, so no address or password is ever typed in a script:

- `/etc/lab/lab.env` — the topology, generated from the Ansible inventory.
- `~/.lab/` — MySQL client files and secrets, mode 600.

Keep `scripts/` next to `ansible/`. Full descriptions are in `docs/scenarios-demo.md`.

## Layout

```
scripts/
  lib/common.sh            shared SSH helpers, probes and the dashboard loop
  tools/gen-vault.sh       random secrets for a fresh lab
  scenario-NN/
    NN-audit.sh            continuous dashboard: before, during and after the fault
    NN-simulate.sh         injects the fault once
    NN-rollback.sh         restores the healthy state and waits until it is proven
    NN-troubleshoot.md     the manual diagnosis, root cause at the bottom
    logs/                  audit logs and the markers simulate/rollback leave (git-ignored)
```

## Running one scenario

Use two terminals on `mgmt01`.

```bash
# terminal 1: start watching before anything breaks
bash scenario-07/07-audit.sh            # -i 0.5 interval, -n 100 ticks, -c changes only

# terminal 2: break it, diagnose by hand, restore
bash scenario-07/07-simulate.sh         # -t web02 picks another node, -y skips the prompt
less scenario-07/07-troubleshoot.md     # stop before "Root cause"
bash scenario-07/07-rollback.sh
```

The audit prints one line per tick, an `[EVENT]` on every state change with the outage
duration on recovery, and a `[MARK]` line when simulate or rollback runs, so the timeline is
readable without guessing. Ctrl-C prints a summary table and the log path. Those numbers are
what a postmortem quotes.

Scenario 16 adds a load generator: run `python3 scenario-16/16-order-writer.py` in a third
terminal before injecting, then `python3 scenario-16/16-rpo-check.py` after the failover.

## Before every scenario

- `ansible-playbook verify.yml` is green, so the starting state is known.
- Snapshot first. Restore `db01` and `db02` together, never one alone, or their GTIDs diverge.
- One scenario at a time; every rollback assumes it is the only fault in the lab.

## If a script refuses to run

- `[ERROR] /etc/lab/lab.env missing`: run `site.yml`, which writes it.
- `Permission denied` on `./NN-audit.sh`: files copied from Windows lose the exec bit; use
  `bash NN-audit.sh`, or `chmod +x scenario-*/*.sh scenario-16/*.py tools/*.sh`.
