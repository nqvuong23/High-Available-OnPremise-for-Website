# Screenshots and diagrams

One folder per scenario, plus `architecture/` for diagrams and whole-system screenshots.
The root `README.md` already points at the file names below, so dropping a file in with the
right name is all that is needed.

## Naming

`NN-<what-it-shows>.png`, lowercase, hyphens only. Keep the scenario number as the prefix so
a file is never ambiguous once it is out of its folder.

## Files the root README expects

| Path | What it should show |
|---|---|
| `architecture/topology.png` | The system diagram, drawn in draw.io or Excalidraw |
| `architecture/verify-green.png` | A full `ansible-playbook verify.yml` run, every check `[OK]` |
| `scenario-04/04-baseline.png` | The audit dashboard before the fault: VIP on lb01, everything OK |
| `scenario-04/04-failover.png` | The `[MARK]` line, the VIP moving, and the summary table |
| `scenario-07/07-baseline.png` | Both web nodes UP in the audit dashboard |
| `scenario-07/07-node-down.png` | web01 going DOWN while the site stays `200` |
| `scenario-16/16-baseline.png` | db01 writable, replication running, semi-sync ON |
| `scenario-16/16-primary-down.png` | The moment the primary disappears |
| `scenario-16/16-failover.png` | The manual failover steps in the terminal |

Add more for the other scenarios as they are run; the folders already exist.

## Taking a usable screenshot

- Make the terminal wide enough that no dashboard line wraps. The audit output is one line
  per tick and wrapping makes it unreadable.
- Include the clock column and the `[MARK]` / `[EVENT]` lines. They are the evidence that
  the measurement started before the fault.
- Always capture the **summary table** printed when the dashboard is stopped with Ctrl-C.
  That table is the source of every number in the README.
- Crop to the terminal only. No desktop, no taskbar, no window title bar.
- PNG, not JPG. Text stays sharp.
- Keep each file under about 500 KB so the repository stays small.
