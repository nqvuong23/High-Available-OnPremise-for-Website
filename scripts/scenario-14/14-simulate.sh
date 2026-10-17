#!/usr/bin/env bash
# scenario 14: drop the mysqlchk port on the primary, loopback excepted
set -euo pipefail
SCENARIO_ID=14
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y]
Drops TCP $LAB_MYSQLCHK_PORT on the writable node from anything but loopback. MySQL stays
healthy and writable; HAProxy can no longer ask it." "$@"

primary=$(db_writable_nodes)
[[ $(wc -w <<<"$primary") == 1 ]] || die "expected exactly one writable node, found: '${primary:-none}'"
lab_require_ssh "$primary"
lab_confirm "Drop port $LAB_MYSQLCHK_PORT on $primary."

lab_state_set target "$primary"
lab_mark "simulate: drop tcp/$LAB_MYSQLCHK_PORT on $primary"
lab_chaos_rule "$primary" input "iifname != \"lo\" tcp dport $LAB_MYSQLCHK_PORT drop" \
    || die "nft failed on $primary"
log_ok "port $LAB_MYSQLCHK_PORT is filtered on $primary"
log_info "watch 14-audit.sh, diagnose with 14-troubleshoot.md, restore with 14-rollback.sh"
