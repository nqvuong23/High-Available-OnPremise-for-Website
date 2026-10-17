#!/usr/bin/env bash
# scenario 12: application accounts granted on the wrong source addresses
set -uo pipefail
SCENARIO_ID=12
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

audit_init "$@"

audit_probe vip-https probe_http --expect 200 "https://$LAB_SITE/"
# the 1045 detail names the address MySQL really saw: that is the clue
audit_probe db-write  probe_db_write
audit_probe primary   probe_primary
for web in $LAB_WEBS; do
    audit_probe "hap-$web" probe_haproxy auto be_web "$web"
done
for db in $LAB_DBS; do
    audit_probe "chk-$db" probe_mysqlchk "$db"
done
audit_run
