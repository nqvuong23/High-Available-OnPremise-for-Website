#!/usr/bin/env bash
# scenario 14: a healthy primary taken out because its health check port is filtered
set -uo pipefail
SCENARIO_ID=14
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

audit_init "$@"
TARGET=$(lab_saved_target "$LAB_DB_PRIMARY")

audit_probe db-write probe_db_write
audit_probe "hap-$TARGET" probe_haproxy auto mysql "$TARGET"
# from mgmt01 the port looks dead; from the node itself it answers 200
audit_probe "chk-remote-$TARGET" probe_mysqlchk "$TARGET" 200
audit_probe "chk-local-$TARGET" probe_remote "$TARGET" \
    "curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:$LAB_MYSQLCHK_PORT/" '^200$'
audit_probe "role-$TARGET" probe_db_role "$TARGET" rw
audit_probe "3306-$TARGET" probe_tcp "$TARGET" "$LAB_MYSQL_PORT"
audit_run
