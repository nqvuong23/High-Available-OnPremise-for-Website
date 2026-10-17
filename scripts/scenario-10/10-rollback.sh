#!/usr/bin/env bash
# scenario 10: restore /etc/exports and remount on the client if its handle went stale
set -euo pipefail
SCENARIO_ID=10
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y] [-t web-node]" "$@"
TARGET=$(lab_saved_target "$(echo "$LAB_WEBS" | awk '{print $NF}')")
lab_require_ssh "$LAB_NFS" "$TARGET"

lab_mark "rollback: restore /etc/exports on $LAB_NFS"
lab_run "$LAB_NFS" "sudo bash -c 'if [ -f /etc/exports.chaos-10 ]; then mv /etc/exports.chaos-10 /etc/exports; fi; exportfs -ra'" \
    || die "could not restore the exports on $LAB_NFS"

if ! lab_wait_for 15 "uploads readable on $TARGET" probe_nfs_read "$TARGET"; then
    # a handle refused while unexported can stay stale; a fresh mount clears it
    log_warn "remounting uploads on $TARGET"
    lab_run "$TARGET" "sudo umount -l $LAB_UPLOADS && sudo mount $LAB_UPLOADS" || die "remount failed on $TARGET"
    lab_wait_for 30 "uploads readable on $TARGET after remount" probe_nfs_read "$TARGET"
fi
lab_state_clear
log_ok "scenario 10 rolled back"
