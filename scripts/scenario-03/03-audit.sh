#!/usr/bin/env bash
# scenario 03: name resolution against the traffic itself while bind9 is down
set -uo pipefail
SCENARIO_ID=03
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

audit_init "$@"
WEB=$(echo "$LAB_WEBS" | cut -d' ' -f1)
# every node asks the router address of its own zone
DNS_SERVER=$(lab_gw "$(lab_zone "$LAB_MGMT")")

audit_probe dns-direct   probe_dns "$LAB_SITE" "$DNS_SERVER" "$LAB_VIP"
# what an application on mgmt01 gets: its netplan adds public fallback resolvers
audit_probe mgmt-resolve probe_resolver "$LAB_SITE" "$LAB_VIP"
audit_probe "$WEB-resolve" probe_remote "$WEB" "r=\$(timeout 3 getent ahostsv4 $LAB_SITE | awk 'NR==1{print \$1}'); echo \${r:-unresolved}" "^$LAB_VIP\$"
# by name, through the real resolver, the way a user's browser would
audit_probe https-by-name probe_http --no-resolve "https://$LAB_SITE/"
# pinned to the VIP: the application path itself
audit_probe https-by-ip  probe_http "https://$LAB_SITE/"
audit_probe db-write     probe_db_write
audit_probe named        probe_service "$LAB_ROUTER" named
audit_run
