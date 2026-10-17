#!/usr/bin/env bash
# scenario 07: start Nginx and wait for HAProxy to mark the node UP
set -euo pipefail
SCENARIO_ID=07
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y] [-t web-node]" "$@"
TARGET=$(lab_saved_target "$(echo "$LAB_WEBS" | cut -d' ' -f1)")
lab_require_ssh "$TARGET"

lab_mark "rollback: systemctl start nginx on $TARGET"
lab_run "$TARGET" "sudo nginx -t -q && sudo systemctl start nginx" || die "could not start nginx on $TARGET"
lab_wait_for 20 "HAProxy marks $TARGET UP" probe_haproxy auto be_web "$TARGET"
lab_state_clear
log_ok "scenario 07 rolled back"
