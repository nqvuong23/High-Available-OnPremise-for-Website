#!/usr/bin/env bash
# scenario 07: stop Nginx on one web node
set -euo pipefail
SCENARIO_ID=07
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y] [-t web-node]
Stops Nginx on one web node. HAProxy should mark it DOWN after fall 3 x inter 2s." "$@"

TARGET=$(lab_target "$(echo "$LAB_WEBS" | cut -d' ' -f1)")
lab_require_member "$TARGET" "$LAB_WEBS"
lab_require_ssh "$TARGET"
lab_confirm "Stop Nginx on $TARGET."

lab_state_set target "$TARGET"
lab_mark "simulate: systemctl stop nginx on $TARGET"
lab_run "$TARGET" "sudo systemctl stop nginx" || die "could not stop nginx on $TARGET"
log_ok "Nginx stopped on $TARGET"
log_info "watch 07-audit.sh for the DOWN event, restore with 07-rollback.sh"
