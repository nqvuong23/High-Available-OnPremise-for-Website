#!/usr/bin/env bash
# scenario 02: delete the static route to the dmz zone on one web node
set -euo pipefail
SCENARIO_ID=02
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

LB_NET=$(lab_subnet "$(lab_zone "$(echo "$LAB_LBS" | cut -d' ' -f1)")")

lab_parse_args "usage: $(basename "$0") [-y] [-t web-node]
Removes the route to the LB zone $LB_NET on one web node. Traffic to the LBs and the VIP
then falls back to the NAT default route. Netplan still holds the route, so a reboot
restores it." "$@"

TARGET=$(lab_target "$(echo "$LAB_WEBS" | cut -d' ' -f1)")
lab_require_member "$TARGET" "$LAB_WEBS"
lab_require_ssh "$TARGET"

route=$(lab_run "$TARGET" "ip route show $LB_NET") || die "cannot read routes on $TARGET"
[[ -n $route ]] || die "$TARGET has no route to $LB_NET; already simulated?"
lab_confirm "Delete '$route' on $TARGET."

lab_state_set target "$TARGET"
lab_state_set route "$route"
lab_mark "simulate: ip route del $LB_NET on $TARGET"
lab_run "$TARGET" "sudo ip route del $LB_NET" || die "route delete failed on $TARGET"
log_ok "route to the LB zone removed on $TARGET"
log_info "watch 02-audit.sh, diagnose with 02-troubleshoot.md, restore with 02-rollback.sh"
