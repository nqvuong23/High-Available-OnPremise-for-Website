#!/usr/bin/env bash
# scenario 16: power the primary off at once, like pulling its plug
set -euo pipefail
SCENARIO_ID=16
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y]
Powers the writable node off without a shutdown. Nothing fails over by itself (ADR-07):
promote the replica by hand with runbook RB-02 in 16-troubleshoot.md.
Start 16-order-writer.py first, so RTO and RPO are measured instead of estimated." "$@"

primary=$(db_writable_nodes)
[[ $(wc -w <<<"$primary") == 1 ]] || die "expected exactly one writable node, found: '${primary:-none}'"
lab_require_ssh "$primary"
lab_confirm "Power off $primary immediately. Bring it back later from Windows: vagrant up $primary."

lab_state_set target "$primary"
lab_mark "simulate: hard power-off of $primary"
# the SSH session dies with the machine, so its exit code means nothing here
lab_run "$primary" "sudo systemctl poweroff --force --force" >/dev/null 2>&1 || true

sleep 3
if ping -c1 -W1 "$(lab_ip "$primary")" >/dev/null 2>&1; then
    log_warn "$primary still answers ping; check it is really down before promoting anything"
else
    log_ok "$primary is down"
fi
log_info "fail over by hand with RB-02 in 16-troubleshoot.md, then measure with 16-rpo-check.py"
