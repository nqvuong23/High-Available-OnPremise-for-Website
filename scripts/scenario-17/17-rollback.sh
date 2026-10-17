#!/usr/bin/env bash
# scenario 17: deactivate and remove the drift plugin, then prove the trees match again
set -euo pipefail
SCENARIO_ID=17
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

PLUGIN=lab-drift

lab_parse_args "usage: $(basename "$0") [-y] [-t web-node]" "$@"
TARGET=$(lab_saved_target "$(echo "$LAB_WEBS" | cut -d' ' -f1)")
lab_require_ssh "$TARGET"

lab_mark "rollback: remove plugin $PLUGIN from $TARGET"
# deactivate first, on the node that has the code, so the shared option is cleaned properly
lab_run "$TARGET" "cd $LAB_WP_ROOT && sudo -u www-data env WP_CLI_CACHE_DIR=/var/cache/lab/wp-cli wp plugin deactivate $PLUGIN" \
    || log_warn "$PLUGIN was not active on $TARGET"
for web in $LAB_WEBS; do
    lab_run "$web" "sudo rm -rf $LAB_WP_ROOT/wp-content/plugins/$PLUGIN" || die "could not remove $PLUGIN on $web"
done

LAB_SSH_TIMEOUT=30 lab_wait_for 30 "code identical on every web node" probe_code_match
lab_state_clear
log_ok "scenario 17 rolled back"
