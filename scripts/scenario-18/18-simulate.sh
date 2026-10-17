#!/usr/bin/env bash
# scenario 18: block one web node's outgoing MySQL connections to the VIP
set -euo pipefail
SCENARIO_ID=18
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y] [-t web-node]
Drops traffic from one web node to $LAB_VIP:$LAB_MYSQL_PORT. Its pages fail, its /healthz.php
does not, so HAProxy keeps sending users to it: the blind spot accepted in ADR-05." "$@"

TARGET=$(lab_target "$(echo "$LAB_WEBS" | cut -d' ' -f1)")
lab_require_member "$TARGET" "$LAB_WEBS"
lab_require_ssh "$TARGET"
lab_confirm "Block $TARGET -> $LAB_VIP:$LAB_MYSQL_PORT."

lab_state_set target "$TARGET"
lab_mark "simulate: drop $TARGET -> $LAB_VIP:$LAB_MYSQL_PORT"
lab_chaos_rule "$TARGET" output "ip daddr $LAB_VIP tcp dport $LAB_MYSQL_PORT drop" \
    || die "nft failed on $TARGET"
log_ok "$TARGET can no longer reach the database"
log_info "watch 18-audit.sh, diagnose with 18-troubleshoot.md, restore with 18-rollback.sh"
