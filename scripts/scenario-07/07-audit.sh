#!/usr/bin/env bash
# scenario 07: HAProxy removing a web node whose Nginx stopped
set -uo pipefail
SCENARIO_ID=07
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

# half a second, so the roughly 6 second detection time is measured
AUDIT_INTERVAL=0.5
audit_init "$@"
TARGET=$(lab_saved_target "$(echo "$LAB_WEBS" | cut -d' ' -f1)")
cookie_var="LAB_COOKIE_$TARGET"

audit_probe vip-https probe_http "https://$LAB_SITE/"
# a user whose sticky cookie pins them to the broken node: redispatch must save them
audit_probe "pinned-$TARGET" probe_http --cookie "SRV=${!cookie_var}" "https://$LAB_SITE/"
for web in $LAB_WEBS; do
    audit_probe "hap-$web" probe_haproxy auto be_web "$web"
done
audit_probe "$TARGET:80" probe_tcp "$TARGET" 80
audit_run
