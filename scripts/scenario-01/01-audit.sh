#!/usr/bin/env bash
# scenario 01: every cross-zone flow while fw01 stops forwarding
set -uo pipefail
SCENARIO_ID=01
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

audit_init "$@"
WEB=$(echo "$LAB_WEBS" | cut -d' ' -f1)
DB=$(echo "$LAB_DBS" | cut -d' ' -f1)

# the router's own addresses answer even when forwarding is off: that is the trap
audit_probe gw-local   probe_ping "$(lab_gw "$(lab_zone "$LAB_MGMT")")"
audit_probe gw-web     probe_ping "$(lab_gw "$(lab_zone "$WEB")")"
audit_probe "$WEB"     probe_ping "$WEB"
audit_probe "$DB"      probe_ping "$DB"
audit_probe vip-https  probe_http "https://$LAB_SITE/"
audit_probe vip-3306   probe_tcp "$LAB_VIP" "$LAB_MYSQL_PORT"
audit_probe fw-to-web  probe_remote "$LAB_ROUTER" "ping -c1 -W1 $(lab_ip "$WEB") >/dev/null && echo reachable || echo unreachable" '^reachable$'
audit_probe forwarding probe_sysctl "$LAB_ROUTER" net.ipv4.ip_forward 1
audit_run
