#!/usr/bin/env bash
# scenario 03: stop bind9 on the router
set -euo pipefail
SCENARIO_ID=03
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y]
Stops named on $LAB_ROUTER. Name resolution for $LAB_DOMAIN stops; IP traffic does not." "$@"

lab_require_ssh "$LAB_ROUTER"
lab_confirm "Stop named on $LAB_ROUTER."

lab_mark "simulate: systemctl stop named on $LAB_ROUTER"
lab_run "$LAB_ROUTER" "sudo systemctl stop named" || die "could not stop named"
log_ok "named is stopped on $LAB_ROUTER"
log_info "watch 03-audit.sh, diagnose with 03-troubleshoot.md, restore with 03-rollback.sh"
