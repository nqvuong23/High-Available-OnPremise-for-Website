#!/usr/bin/env bash
# scenario 05: drop incoming VRRP on the backup LB, so it stops hearing the master
set -euo pipefail
SCENARIO_ID=05
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y] [-t lb-node]
Drops IP protocol 112 on input of the LB that does not hold the VIP (or on -t).
It hears no master, promotes itself, and both LBs hold the VIP." "$@"

owner=$(lab_vip_owner)
default=$(echo "$LAB_LBS" | tr ' ' '\n' | grep -vx "${owner%% *}" | head -1)
TARGET=$(lab_target "$default")
lab_require_member "$TARGET" "$LAB_LBS"
lab_require_ssh "$TARGET"
lab_confirm "Drop VRRP on $TARGET (VIP holder: ${owner:-none})."

lab_state_set target "$TARGET"
lab_mark "simulate: drop VRRP input on $TARGET"
lab_chaos_rule "$TARGET" input "ip protocol 112 drop" || die "nft failed on $TARGET"
log_ok "VRRP is dropped on $TARGET; expect a second MASTER within about 4 seconds"
log_info "watch 05-audit.sh, diagnose with 05-troubleshoot.md, restore with 05-rollback.sh"
