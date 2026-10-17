#!/usr/bin/env bash
# scenario 13: the primary restarts and comes back read-only, as fencing intends
set -uo pipefail
SCENARIO_ID=13
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

audit_init "$@"
TARGET=$(lab_saved_target "$LAB_DB_PRIMARY")
REPLICA=$(echo "$LAB_DBS" | tr ' ' '\n' | grep -vx "$TARGET" | head -1)

audit_probe db-write probe_db_write
audit_probe vip-https probe_http --expect 200 "https://$LAB_SITE/"
audit_probe "hap-$TARGET" probe_haproxy auto mysql "$TARGET"
audit_probe "chk-$TARGET" probe_mysqlchk "$TARGET" 200
audit_probe "role-$TARGET" probe_db_role "$TARGET" rw
# mysqld itself is running fine: that is what makes this one confusing
audit_probe "mysqld-$TARGET" probe_service "$TARGET" mysql
audit_probe "repl-$REPLICA" probe_replication "$REPLICA"
audit_run
