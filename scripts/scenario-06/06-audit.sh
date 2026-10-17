#!/usr/bin/env bash
# scenario 06: a certificate with the wrong name while the site itself stays up
set -uo pipefail
SCENARIO_ID=06
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

audit_init "$@"

audit_probe https-strict   probe_http "https://$LAB_SITE/"
# -k skips validation: the service answering proves the fault is in the certificate only
audit_probe https-insecure probe_http --insecure "https://$LAB_SITE/"
audit_probe cert-san       probe_cert
audit_probe http-redirect  probe_http --expect 301 "http://$LAB_SITE/"
for web in $LAB_WEBS; do
    audit_probe "hap-$web" probe_haproxy auto be_web "$web"
done
audit_run
