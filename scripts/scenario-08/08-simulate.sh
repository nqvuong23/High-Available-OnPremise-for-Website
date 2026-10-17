#!/usr/bin/env bash
# scenario 08: stop PHP-FPM on one web node, leaving Nginx running
set -euo pipefail
SCENARIO_ID=08
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y] [-t web-node]
Stops $LAB_PHP_FPM on one web node. Nginx keeps answering, with 502 for every PHP request." "$@"

TARGET=$(lab_target "$(echo "$LAB_WEBS" | cut -d' ' -f1)")
lab_require_member "$TARGET" "$LAB_WEBS"
lab_require_ssh "$TARGET"
lab_confirm "Stop $LAB_PHP_FPM on $TARGET."

lab_state_set target "$TARGET"
lab_mark "simulate: systemctl stop $LAB_PHP_FPM on $TARGET"
lab_run "$TARGET" "sudo systemctl stop $LAB_PHP_FPM" || die "could not stop $LAB_PHP_FPM on $TARGET"
log_ok "$LAB_PHP_FPM stopped on $TARGET"
log_info "watch 08-audit.sh, diagnose with 08-troubleshoot.md, restore with 08-rollback.sh"
