# Scenario 17 — troubleshooting: the site behaves differently depending on who asks

> Do not read **Root cause** until your own diagnosis is finished. Run every command by hand.

## What you see

- A feature, a header or a page element appears for some users and not for others.
- Nothing is down. Every check is green.
- The difference sticks to the user, which points at the sticky cookie and so at one node.

## Step 1 — compare the two nodes as users see them

```bash
for c in w1 w2; do
  echo "== SRV=$c"; curl -s -D - -o /dev/null -b "SRV=$c" https://shop.lab.internal/ | grep -iE "^x-|^set-cookie"
done
```

A header present through one node only means the two nodes are not running the same thing.

## Step 2 — are the code trees identical?

```bash
for h in web01 web02; do
  printf '%s ' $h
  ssh $h "sudo bash -c 'cd /var/www/wordpress && find . -path ./wp-content/uploads -prune -o -type f -print0 \
    | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16'"
done
```

Two different hashes. `web-stack.md` says any difference between the web nodes is a bug.

## Step 3 — find exactly which files differ

```bash
for h in web01 web02; do
  ssh $h "sudo bash -c 'cd /var/www/wordpress && find . -path ./wp-content/uploads -prune -o -type f -print0 \
    | sort -z | xargs -0 sha256sum'" > /tmp/tree-$h.txt
done
diff /tmp/tree-web01.txt /tmp/tree-web02.txt
```

## Step 4 — what does WordPress think is active?

```bash
for h in web01 web02; do echo "== $h"; ssh $h 'cd /var/www/wordpress && sudo -u www-data wp plugin list --status=active 2>&1 | tail -n +1'; done
```

The active list lives in the **shared database**, so both nodes read the same list. Only one
has the files. The other silently skips a plugin it cannot find, and an admin page view on it
may deactivate the plugin for everyone.

## Step 5 — how could this get in?

```bash
ssh web01 'grep DISALLOW_FILE_MODS /var/www/wordpress/wp-config.php'
ssh web01 'sudo ls -la --time-style=full-iso /var/www/wordpress/wp-content/plugins/'
```

`DISALLOW_FILE_MODS` blocks installs through wp-admin, so this came in from a shell. The
timestamps of the extra directory date it.

---

## Root cause

A plugin was copied onto `web01` only and activated. The activation is shared state in MySQL;
the code is per node. Users pinned to `web01` get its behaviour, users on `web02` do not, and
an `ansible-playbook --check` would not notice: the WordPress task is guarded by `creates`, so
it never compares the existing tree.

## Fix

```bash
bash 17-rollback.sh
```

## Lesson

- With identical nodes, drift detection means hashing the tree; "it was deployed once" proves
  nothing about today.
- Plugin activation and plugin code live in different places: shared database, per-node disk.
- This is why ADR-12 forbids installing through the admin UI, and why a periodic tree hash
  belongs in `healthcheck.py`.
