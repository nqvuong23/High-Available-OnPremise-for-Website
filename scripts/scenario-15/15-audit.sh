#!/usr/bin/env bash
# scenario 15: semi-sync falling back to async when the replica disappears
set -uo pipefail
SCENARIO_ID=15
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

audit_init "$@"
TARGET=$(lab_saved_target "$(echo "$LAB_DBS" | tr ' ' '\n' | grep -vx "$LAB_DB_PRIMARY" | head -1)")

# a write that suddenly takes 3 seconds is the semi-sync timeout expiring
audit_probe db-write  probe_db_write
audit_probe semisync  probe_semisync
audit_probe "repl-$TARGET" probe_replication "$TARGET"
audit_probe "lag-$TARGET"  probe_heartbeat "$TARGET"
audit_probe vip-https probe_http "https://$LAB_SITE/"
audit_run
