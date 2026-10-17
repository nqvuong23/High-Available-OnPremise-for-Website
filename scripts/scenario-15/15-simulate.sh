#!/usr/bin/env bash
# scenario 15: stop MySQL on the replica
set -euo pipefail
SCENARIO_ID=15
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y] [-t db-node]
Stops MySQL on the read-only replica. The primary waits rpl_semi_sync_source_timeout for an
acknowledgement once, then silently continues in async mode: RPO=0 no longer holds." "$@"

writable=$(db_writable_nodes)
default=$(echo "$LAB_DBS" | tr ' ' '\n' | grep -vx "${writable%% *}" | head -1)
TARGET=$(lab_target "$default")
lab_require_member "$TARGET" "$LAB_DBS"
lab_in_list "$TARGET" "$writable" && die "$TARGET is the writable node; this scenario stops the replica"
lab_require_ssh "$TARGET"
lab_confirm "Stop MySQL on the replica $TARGET."

lab_state_set target "$TARGET"
lab_mark "simulate: systemctl stop mysql on $TARGET"
LAB_SSH_TIMEOUT=90 lab_run "$TARGET" "sudo systemctl stop mysql" || die "could not stop mysql on $TARGET"
log_ok "MySQL stopped on $TARGET; the next write on the primary waits for the semi-sync timeout"
log_info "watch 15-audit.sh, diagnose with 15-troubleshoot.md, restore with 15-rollback.sh"
