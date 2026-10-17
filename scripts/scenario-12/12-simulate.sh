#!/usr/bin/env bash
# scenario 12: "fix" the application grants to the web node addresses
set -euo pipefail
SCENARIO_ID=12
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

WP_USER=${LAB_WP_USER:-wp}

lab_parse_args "usage: $(basename "$0") [-y]
Renames the application accounts from the LB addresses to the web node addresses, the
mistake of believing MySQL sees the web nodes as the source. Runs on the writable node." "$@"

primary=$(db_writable_nodes)
[[ $(wc -w <<<"$primary") == 1 ]] || die "expected exactly one writable node, found: '${primary:-none}'"
lab_require_ssh "$primary"

read -r -a lbs <<<"$LAB_LBS"
read -r -a webs <<<"$LAB_WEBS"
pairs=()
for i in "${!lbs[@]}"; do
    [[ -n ${webs[i]:-} ]] || break
    pairs+=("'$WP_USER'@'$(lab_ip "${lbs[i]}")' TO '$WP_USER'@'$(lab_ip "${webs[i]}")'")
done
sql="RENAME USER $(IFS=,; echo "${pairs[*]}");"

lab_confirm "On $primary: $sql"
lab_state_set target "$primary"
lab_mark "simulate: $sql on $primary"
lab_sql "$primary" <<<"$sql" || die "rename failed on $primary"
log_ok "application accounts now name the web node addresses"
log_info "watch 12-audit.sh, diagnose with 12-troubleshoot.md, restore with 12-rollback.sh"
