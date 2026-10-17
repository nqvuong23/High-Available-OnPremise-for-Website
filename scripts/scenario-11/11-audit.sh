#!/usr/bin/env bash
# scenario 11: a full root filesystem on one web node, the failure that started the ticket
set -uo pipefail
SCENARIO_ID=11
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

AUDIT_INTERVAL=2
audit_init "$@"
TARGET=$(lab_saved_target "$(echo "$LAB_WEBS" | cut -d' ' -f1)")

audit_probe "disk-$TARGET" probe_disk "$TARGET" /
# PHP writes every upload to its temp directory on the root filesystem first
audit_probe "tmp-write-$TARGET" probe_remote "$TARGET" \
    "f=/tmp/.lab-probe-\$\$; if sudo -u www-data sh -c \"head -c 65536 /dev/zero > \$f\" 2>/dev/null; then echo writable; else echo no-space; fi; sudo rm -f \$f" \
    '^writable$'
audit_probe "hap-$TARGET" probe_haproxy auto be_web "$TARGET"
audit_probe vip-https probe_http "https://$LAB_SITE/"
audit_run
