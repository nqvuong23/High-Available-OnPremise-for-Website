#!/usr/bin/env bash
# scenario 09: a dead NFS server under hard mounts, seen by users and by HAProxy
set -uo pipefail
SCENARIO_ID=09
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

# every probe that touches NFS may block for its full timeout while the server is down
AUDIT_INTERVAL=2
audit_init "$@"

audit_probe vip-https probe_http "https://$LAB_SITE/"
for web in $LAB_WEBS; do
    audit_probe "hap-$web"  probe_haproxy auto be_web "$web"
    audit_probe "nfs-$web"  probe_nfs_read "$web"
    audit_probe "dproc-$web" probe_dstate "$web"
done
audit_probe nfs-server probe_service "$LAB_NFS" nfs-server
audit_run
