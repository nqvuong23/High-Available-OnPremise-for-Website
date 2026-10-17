#!/usr/bin/env bash
# scenario 13: kill mysqld on the primary and let it come back
set -euo pipefail
SCENARIO_ID=13
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y]
SIGKILLs mysqld on the writable node, then makes sure it is running again. It restarts
read-only from its config file, so the write path stays down until someone opens it." "$@"

primary=$(db_writable_nodes)
[[ $(wc -w <<<"$primary") == 1 ]] || die "expected exactly one writable node, found: '${primary:-none}'"
lab_require_ssh "$primary"
lab_confirm "Kill mysqld on $primary."

lab_state_set target "$primary"
lab_mark "simulate: SIGKILL mysqld on $primary"
LAB_SSH_TIMEOUT=120 lab_run "$primary" "sudo systemctl kill -s SIGKILL mysql; sleep 3;
  systemctl is-active --quiet mysql || sudo systemctl start mysql" || die "mysql did not come back on $primary"

ro=$(lab_sql "$primary" <<<"SELECT @@read_only")
log_ok "mysqld is running again on $primary with read_only=$ro"
log_info "watch 13-audit.sh, diagnose with 13-troubleshoot.md, restore with 13-rollback.sh"
