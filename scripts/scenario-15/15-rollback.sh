#!/usr/bin/env bash
# scenario 15: start the replica and wait for semi-sync to switch back on
set -euo pipefail
SCENARIO_ID=15
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y] [-t db-node]" "$@"
TARGET=$(lab_saved_target "$(echo "$LAB_DBS" | tr ' ' '\n' | grep -vx "$LAB_DB_PRIMARY" | head -1)")
lab_require_ssh "$TARGET"

lab_mark "rollback: systemctl start mysql on $TARGET"
LAB_SSH_TIMEOUT=120 lab_run "$TARGET" "sudo systemctl start mysql" || die "could not start mysql on $TARGET"
# it boots read-only and resumes replication on its own: skip_replica_start is off
lab_wait_for 60 "replication running on $TARGET" probe_replication "$TARGET"
lab_wait_for 60 "semi-sync back on" probe_semisync
lab_state_clear
log_ok "scenario 15 rolled back"
