#!/usr/bin/env bash
# scenario 01: turn IP forwarding off on the router, runtime only
set -euo pipefail
SCENARIO_ID=01
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y]
Turns net.ipv4.ip_forward off on $LAB_ROUTER. The persistent sysctl file is left alone,
so a reboot of $LAB_ROUTER also restores service." "$@"

lab_require_ssh "$LAB_ROUTER"
lab_confirm "Stop forwarding on $LAB_ROUTER; every cross-zone flow breaks, Ansible included."

lab_mark "simulate: net.ipv4.ip_forward=0 on $LAB_ROUTER"
lab_run "$LAB_ROUTER" "sudo sysctl -q -w net.ipv4.ip_forward=0" || die "sysctl failed on $LAB_ROUTER"
log_ok "forwarding is off on $LAB_ROUTER"
log_info "watch 01-audit.sh, diagnose with 01-troubleshoot.md, restore with 01-rollback.sh"
