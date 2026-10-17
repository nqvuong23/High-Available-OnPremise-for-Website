#!/usr/bin/env bash
# scenario 17: the two web nodes stop running the same code
set -uo pipefail
SCENARIO_ID=17
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

# hashing the whole tree takes a second or two per node
AUDIT_INTERVAL=5
audit_init "$@"

audit_probe code-match probe_code_match
for web in $LAB_WEBS; do
    cookie_var="LAB_COOKIE_$web"
    # the drift plugin adds a header; who sends it depends on which node served you
    audit_probe "drift-via-$web" probe_header X-Lab-Drift "https://$LAB_SITE/" --cookie "SRV=${!cookie_var}"
    audit_probe "hap-$web" probe_haproxy auto be_web "$web"
done
audit_probe vip-https probe_http "https://$LAB_SITE/"
audit_run
