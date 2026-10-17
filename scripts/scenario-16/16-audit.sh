#!/usr/bin/env bash
# scenario 16: the write path and the database topology while the primary is gone
set -uo pipefail
SCENARIO_ID=16
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

audit_init "$@"

audit_probe db-write probe_db_write
# who is writable right now, found live rather than trusted from the inventory
audit_probe primary  probe_primary
for db in $LAB_DBS; do
    audit_probe "ping-$db" probe_ping "$db"
    audit_probe "hap-$db"  probe_haproxy auto mysql "$db" 'UP|MAINT'
    audit_probe "chk-$db"  probe_mysqlchk "$db"
    audit_probe "repl-$db" probe_replication "$db"
done
audit_probe semisync probe_semisync
audit_run
