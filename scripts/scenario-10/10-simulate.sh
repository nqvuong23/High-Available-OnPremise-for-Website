#!/usr/bin/env bash
# scenario 10: remove one web node from /etc/exports on the NFS server
set -euo pipefail
SCENARIO_ID=10
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y] [-t web-node]
Removes one web node from /etc/exports on $LAB_NFS and re-exports. That node's mount stays
in place but every access is refused. The original file is kept as /etc/exports.chaos-10." "$@"

TARGET=$(lab_target "$(echo "$LAB_WEBS" | awk '{print $NF}')")
lab_require_member "$TARGET" "$LAB_WEBS"
lab_require_ssh "$LAB_NFS" "$TARGET"
ip=$(lab_ip "$TARGET")
lab_confirm "Revoke the export for $TARGET ($ip) on $LAB_NFS."

lab_state_set target "$TARGET"
lab_mark "simulate: remove $TARGET from /etc/exports on $LAB_NFS"
lab_run "$LAB_NFS" "sudo bash -c '[ -f /etc/exports.chaos-10 ] || cp -p /etc/exports /etc/exports.chaos-10;
  sed -i -E \"s# $ip\\([^)]*\\)##\" /etc/exports && exportfs -ra && exportfs -f'" \
  || die "could not rewrite the exports on $LAB_NFS"
log_ok "$TARGET is no longer exported to"
log_info "watch 10-audit.sh, diagnose with 10-troubleshoot.md, restore with 10-rollback.sh"
