#!/usr/bin/env bash
# scenario 14: remove the filter and wait for HAProxy to take the primary back
set -euo pipefail
SCENARIO_ID=14
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y] [-t db-node]" "$@"
TARGET=$(lab_saved_target "$LAB_DB_PRIMARY")
lab_require_ssh "$TARGET"

lab_mark "rollback: remove the lab_chaos table on $TARGET"
lab_chaos_clear "$TARGET" || die "could not clear the chaos table on $TARGET"
lab_wait_for 20 "HAProxy marks $TARGET UP" probe_haproxy auto mysql "$TARGET"
lab_state_clear
log_ok "scenario 14 rolled back"
