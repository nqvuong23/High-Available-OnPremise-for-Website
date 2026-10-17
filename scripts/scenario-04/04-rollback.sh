#!/usr/bin/env bash
# scenario 04: start HAProxy again and watch preempt take the VIP back
set -euo pipefail
SCENARIO_ID=04
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y] [-t lb-node]" "$@"
TARGET=$(lab_saved_target "$(echo "$LAB_LBS" | cut -d' ' -f1)")
lab_require_ssh "$TARGET"

probe_owner_is_target() {
    probe_vip_owner
    if [[ $P_STATE == OK && $P_DETAIL != "$TARGET" ]]; then
        P_STATE=FAIL
    fi
}

lab_mark "rollback: systemctl start haproxy on $TARGET"
lab_run "$TARGET" "sudo systemctl start haproxy" || die "could not start haproxy on $TARGET"
# preempt is on: the higher-priority LB takes the VIP back, a second short interruption
lab_wait_for 30 "VIP back on $TARGET" probe_owner_is_target || \
    log_warn "the VIP stays elsewhere; is $TARGET the MASTER with the higher priority?"
lab_state_clear
log_ok "scenario 04 rolled back"
