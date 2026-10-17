#!/usr/bin/env bash
# scenario 18: one web node loses the database while its health check stays green
set -uo pipefail
SCENARIO_ID=18
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

audit_init "$@"
TARGET=$(lab_saved_target "$(echo "$LAB_WEBS" | cut -d' ' -f1)")

# anonymous requests round-robin, so they fail on every other try
audit_probe vip-anon probe_http --expect 200 "https://$LAB_SITE/"
for web in $LAB_WEBS; do
    cookie_var="LAB_COOKIE_$web"
    audit_probe "pinned-$web" probe_http --expect 200 --cookie "SRV=${!cookie_var}" "https://$LAB_SITE/"
done
audit_probe "hap-$TARGET" probe_haproxy auto be_web "$TARGET"
audit_probe "healthz-$TARGET" probe_http --expect 200 "http://$(lab_ip "$TARGET")/healthz.php"
audit_probe "$TARGET-to-vip" probe_remote_tcp "$TARGET" "$LAB_VIP" "$LAB_MYSQL_PORT"
audit_run
