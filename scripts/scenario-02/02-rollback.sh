#!/usr/bin/env bash
# scenario 02: put the dmz route back exactly as it was
set -euo pipefail
SCENARIO_ID=02
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y] [-t web-node]" "$@"
TARGET=$(lab_saved_target "$(echo "$LAB_WEBS" | cut -d' ' -f1)")
lab_require_ssh "$TARGET"

route=$(lab_state_get route)
if [[ -z $route ]]; then
    lb_net=$(lab_subnet "$(lab_zone "$(echo "$LAB_LBS" | cut -d' ' -f1)")")
    route="$lb_net via $(lab_gw "$(lab_zone "$TARGET")")"
fi

lab_mark "rollback: ip route replace $route on $TARGET"
lab_run "$TARGET" "sudo ip route replace $route" || die "route restore failed on $TARGET"

lab_wait_for 30 "HAProxy marks $TARGET UP" probe_haproxy auto be_web "$TARGET"
lab_state_clear
log_ok "scenario 02 rolled back"
