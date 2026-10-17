#!/usr/bin/env bash
# scenario 02: one web node loses its route to the dmz zone
set -uo pipefail
SCENARIO_ID=02
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

audit_init "$@"
TARGET=$(lab_saved_target "$(echo "$LAB_WEBS" | cut -d' ' -f1)")
OTHER=$(echo "$LAB_WEBS" | tr ' ' '\n' | grep -vx "$TARGET" | head -1)

audit_probe vip-https       probe_http "https://$LAB_SITE/"
audit_probe "hap-$TARGET"   probe_haproxy auto be_web "$TARGET"
audit_probe "hap-$OTHER"    probe_haproxy auto be_web "$OTHER"
# asked directly from mgmt01, whose zone route on the target is still intact
audit_probe "$TARGET-healthz" probe_http "http://$(lab_ip "$TARGET")/healthz.php"
audit_probe "$TARGET-to-vip"  probe_remote_tcp "$TARGET" "$LAB_VIP" "$LAB_MYSQL_PORT"
audit_probe "$TARGET-lb-route" probe_remote "$TARGET" "ip route get $LAB_VIP | grep -o 'via [0-9.]*'" \
    "via $(lab_gw "$(lab_zone "$TARGET")")"
audit_run
