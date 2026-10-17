#!/usr/bin/env bash
# scenario 04: stop HAProxy on the LB that holds the VIP
set -euo pipefail
SCENARIO_ID=04
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y] [-t lb-node]
Stops HAProxy on the LB holding the VIP (or on -t). Keepalived's check fails twice,
the priority drops by 20 and the other LB claims the VIP." "$@"

owner=$(lab_vip_owner)
TARGET=$(lab_target "${owner%% *}")
[[ -n $TARGET ]] || die "no LB holds $LAB_VIP; fix that before running this scenario"
lab_require_member "$TARGET" "$LAB_LBS"
lab_require_ssh "$TARGET"
lab_confirm "Stop HAProxy on $TARGET (VIP holder: ${owner:-none})."

lab_state_set target "$TARGET"
lab_mark "simulate: systemctl stop haproxy on $TARGET"
lab_run "$TARGET" "sudo systemctl stop haproxy" || die "could not stop haproxy on $TARGET"
log_ok "HAProxy stopped on $TARGET"
log_info "watch 04-audit.sh for the VIP move, restore with 04-rollback.sh"
