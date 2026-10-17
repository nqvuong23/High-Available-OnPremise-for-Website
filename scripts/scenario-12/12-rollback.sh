#!/usr/bin/env bash
# scenario 12: grant the application accounts on the LB addresses again
set -euo pipefail
SCENARIO_ID=12
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

WP_USER=${LAB_WP_USER:-wp}

lab_parse_args "usage: $(basename "$0") [-y]" "$@"
primary=$(db_writable_nodes)
[[ $(wc -w <<<"$primary") == 1 ]] || die "expected exactly one writable node, found: '${primary:-none}'"
lab_require_ssh "$primary"

read -r -a lbs <<<"$LAB_LBS"
read -r -a webs <<<"$LAB_WEBS"
pairs=()
for i in "${!lbs[@]}"; do
    [[ -n ${webs[i]:-} ]] || break
    web_ip=$(lab_ip "${webs[i]}")
    exists=$(lab_sql "$primary" <<<"SELECT COUNT(*) FROM mysql.user WHERE user = '$WP_USER' AND host = '$web_ip'")
    [[ $exists == 1 ]] && pairs+=("'$WP_USER'@'$web_ip' TO '$WP_USER'@'$(lab_ip "${lbs[i]}")'")
done

if (( ${#pairs[@]} )); then
    sql="RENAME USER $(IFS=,; echo "${pairs[*]}");"
    lab_mark "rollback: $sql on $primary"
    lab_sql "$primary" <<<"$sql" || die "rename failed on $primary"
else
    log_info "no account on a web node address; nothing to rename"
fi

lab_wait_for 20 "write path through the VIP" probe_db_write
lab_state_clear
log_ok "scenario 12 rolled back"
