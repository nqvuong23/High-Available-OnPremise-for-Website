#!/usr/bin/env bash
# scenario 10: one web node loses access to the uploads export, the other does not
set -uo pipefail
SCENARIO_ID=10
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

AUDIT_INTERVAL=2
audit_init "$@"

for web in $LAB_WEBS; do
    cookie_var="LAB_COOKIE_$web"
    # the same image, requested by a user pinned to each node through the VIP
    audit_probe "img-via-$web" probe_http --expect 200 --cookie "SRV=${!cookie_var}" \
        "https://$LAB_SITE/wp-content/uploads/$LAB_PROBE_FILE"
    audit_probe "nfs-$web" probe_nfs_read "$web"
    audit_probe "hap-$web" probe_haproxy auto be_web "$web"
    # exportfs lists clients by address, so count the lines naming this node's IP
    audit_probe "export-$web" probe_remote "$LAB_NFS" "sudo exportfs -v | grep -cF '$(lab_ip "$web")('" '^[1-9]'
done
audit_run
