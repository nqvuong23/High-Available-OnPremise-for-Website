#!/usr/bin/env bash
# scenario 13: runbook RB-04, open write on the restarted primary after the fencing check
set -euo pipefail
SCENARIO_ID=13
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y] [-t db-node]" "$@"
TARGET=$(lab_saved_target "$LAB_DB_PRIMARY")
lab_require_ssh "$TARGET"

# never two writers: every other node must be read-only before this one opens
writable=$(db_writable_nodes)
for host in $writable; do
    [[ $host == "$TARGET" ]] && continue
    die "$host is writable; opening write on $TARGET would create two primaries"
done
if lab_in_list "$TARGET" "$writable"; then
    log_info "$TARGET is already writable"
else
    lab_confirm "Open write on $TARGET (every other node is read-only)."
    lab_mark "rollback: open write on $TARGET"
    lab_sql "$TARGET" <<<"SET GLOBAL super_read_only = OFF; SET GLOBAL read_only = OFF;" \
        || die "could not open write on $TARGET"
fi

lab_wait_for 20 "write path through the VIP" probe_db_write
lab_state_clear
log_ok "scenario 13 rolled back"
