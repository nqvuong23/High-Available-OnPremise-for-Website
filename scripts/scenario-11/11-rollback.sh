#!/usr/bin/env bash
# scenario 11: delete the fill file
set -euo pipefail
SCENARIO_ID=11
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

FILL=/var/tmp/lab-chaos-11.fill

lab_parse_args "usage: $(basename "$0") [-y] [-t web-node]" "$@"
TARGET=$(lab_saved_target "$(echo "$LAB_WEBS" | cut -d' ' -f1)")
lab_require_ssh "$TARGET"

lab_mark "rollback: rm $FILL on $TARGET"
lab_run "$TARGET" "sudo rm -f $FILL $FILL.tail" || die "could not remove $FILL on $TARGET"
lab_wait_for 10 "disk usage normal on $TARGET" probe_disk "$TARGET" /
lab_state_clear
log_ok "scenario 11 rolled back"
