#!/usr/bin/env bash
# scenario 03: start bind9 and wait for answers
set -euo pipefail
SCENARIO_ID=03
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y]" "$@"
lab_require_ssh "$LAB_ROUTER"

lab_mark "rollback: systemctl start named on $LAB_ROUTER"
lab_run "$LAB_ROUTER" "sudo systemctl start named" || die "could not start named"
lab_wait_for 30 "bind9 answers for $LAB_SITE" probe_dns "$LAB_SITE" "$(lab_gw "$(lab_zone "$LAB_MGMT")")" "$LAB_VIP"
log_ok "scenario 03 rolled back"
