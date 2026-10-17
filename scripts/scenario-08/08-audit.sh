#!/usr/bin/env bash
# scenario 08: Nginx up but PHP-FPM dead on one web node
set -uo pipefail
SCENARIO_ID=08
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

AUDIT_INTERVAL=0.5
audit_init "$@"
TARGET=$(lab_saved_target "$(echo "$LAB_WEBS" | cut -d' ' -f1)")
cookie_var="LAB_COOKIE_$TARGET"
ip=$(lab_ip "$TARGET")

audit_probe vip-https "probe_http" "https://$LAB_SITE/"
audit_probe "pinned-$TARGET" probe_http --cookie "SRV=${!cookie_var}" "https://$LAB_SITE/"
audit_probe "hap-$TARGET" probe_haproxy auto be_web "$TARGET"
# the web server still answers static files: "nginx is up" is not "the app is up"
audit_probe "$TARGET-static"  probe_http --expect 200 "http://$ip/wp-content/uploads/$LAB_PROBE_FILE"
audit_probe "$TARGET-healthz" probe_http --expect 200 "http://$ip/healthz.php"
audit_probe "$TARGET-fpm"     probe_service "$TARGET" "$LAB_PHP_FPM"
audit_run
