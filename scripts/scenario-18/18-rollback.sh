#!/usr/bin/env bash
# scenario 18: unblock the database path of the web node
set -euo pipefail
SCENARIO_ID=18
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y] [-t web-node]" "$@"
TARGET=$(lab_saved_target "$(echo "$LAB_WEBS" | cut -d' ' -f1)")
lab_require_ssh "$TARGET"

cookie_var="LAB_COOKIE_$TARGET"
lab_mark "rollback: remove the lab_chaos table on $TARGET"
lab_chaos_clear "$TARGET" || die "could not clear the chaos table on $TARGET"
lab_wait_for 20 "pages served by $TARGET again" \
    probe_http --expect 200 --cookie "SRV=${!cookie_var}" "https://$LAB_SITE/"
lab_state_clear
log_ok "scenario 18 rolled back"
