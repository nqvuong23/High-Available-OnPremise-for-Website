#!/usr/bin/env bash
# scenario 09: start the NFS server and time how long clients take to recover
set -euo pipefail
SCENARIO_ID=09
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y]" "$@"
lab_require_ssh "$LAB_NFS"

lab_mark "rollback: systemctl start nfs-server on $LAB_NFS"
lab_run "$LAB_NFS" "sudo systemctl start nfs-server" || die "could not start nfs-server"

# the server opens a grace period on restart, so new opens can wait up to the lease time
for web in $LAB_WEBS; do
    lab_wait_for 150 "uploads readable again on $web" probe_nfs_read "$web" || true
done
log_ok "scenario 09 rolled back"
