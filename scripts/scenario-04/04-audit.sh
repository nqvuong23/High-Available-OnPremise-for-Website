#!/usr/bin/env bash
# scenario 04: the VIP moving to the backup LB when the active HAProxy dies
set -uo pipefail
SCENARIO_ID=04
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

# half a second, so the failover time is measured rather than guessed
AUDIT_INTERVAL=0.5
audit_init "$@"

audit_probe vip-owner  probe_vip_owner
audit_probe lb-alive   probe_http "http://$LAB_VIP/haproxy-alive"
audit_probe vip-https  probe_http "https://$LAB_SITE/"
audit_probe db-write   probe_db_write
for lb in $LAB_LBS; do
    audit_probe "haproxy-$lb" probe_service "$lb" haproxy
done
audit_run
