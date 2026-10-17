#!/usr/bin/env bash
# scenario 05: let VRRP through again and wait for a single VIP holder
set -euo pipefail
SCENARIO_ID=05
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y] [-t lb-node]" "$@"
TARGET=$(lab_saved_target "$(echo "$LAB_LBS" | cut -d' ' -f2)")
lab_require_ssh "$TARGET"

lab_mark "rollback: remove the lab_chaos table on $TARGET"
lab_chaos_clear "$TARGET" || die "could not clear the chaos table on $TARGET"
lab_wait_for 20 "exactly one VIP holder" probe_vip_owner
lab_state_clear
log_ok "scenario 05 rolled back"
