#!/usr/bin/env bash
# scenario 01: turn IP forwarding back on and wait for the routed path
set -euo pipefail
SCENARIO_ID=01
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y]" "$@"
lab_require_ssh "$LAB_ROUTER"

lab_mark "rollback: net.ipv4.ip_forward=1 on $LAB_ROUTER"
lab_run "$LAB_ROUTER" "sudo sysctl -q -w net.ipv4.ip_forward=1" || die "sysctl failed on $LAB_ROUTER"

lab_wait_for 30 "site answers through the VIP" probe_http "https://$LAB_SITE/"
lab_wait_for 30 "write path through the VIP" probe_db_write
log_ok "scenario 01 rolled back"
