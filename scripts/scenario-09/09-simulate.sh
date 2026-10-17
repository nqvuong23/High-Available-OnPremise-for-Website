#!/usr/bin/env bash
# scenario 09: stop the NFS server under the hard-mounted web nodes
set -euo pipefail
SCENARIO_ID=09
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y]
Stops nfs-server on $LAB_NFS. The web nodes mount it hard, so anything touching uploads
blocks in state D instead of failing, until the server returns." "$@"

lab_require_ssh "$LAB_NFS"
lab_confirm "Stop nfs-server on $LAB_NFS. Do not ls the uploads directory on a web node by hand: your shell will hang."

lab_mark "simulate: systemctl stop nfs-server on $LAB_NFS"
lab_run "$LAB_NFS" "sudo systemctl stop nfs-server" || die "could not stop nfs-server"
log_ok "nfs-server stopped on $LAB_NFS"
log_info "watch 09-audit.sh, diagnose with 09-troubleshoot.md, restore with 09-rollback.sh"
