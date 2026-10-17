#!/usr/bin/env bash
# scenario 17: install and activate a plugin on one web node only, as wp-admin would
set -euo pipefail
SCENARIO_ID=17
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

PLUGIN=lab-drift

lab_parse_args "usage: $(basename "$0") [-y] [-t web-node]
Copies a small plugin onto one web node and activates it. Activation is stored in the shared
database, so every node now believes the plugin is active, but only one has its code." "$@"

TARGET=$(lab_target "$(echo "$LAB_WEBS" | cut -d' ' -f1)")
lab_require_member "$TARGET" "$LAB_WEBS"
lab_require_ssh "$TARGET"
lab_confirm "Install and activate the $PLUGIN plugin on $TARGET only."

dir="$LAB_WP_ROOT/wp-content/plugins/$PLUGIN"
lab_state_set target "$TARGET"
lab_mark "simulate: plugin $PLUGIN installed on $TARGET only"
if ! lab_run_stdin "$TARGET" "sudo -u www-data mkdir -p $dir && sudo -u www-data tee $dir/$PLUGIN.php >/dev/null" <<'EOF'
<?php
/*
 * Plugin Name: Lab drift demo
 * Description: Scenario 17. Present on one web node only, to show what code drift does.
 */
add_action('send_headers', function () {
    header('X-Lab-Drift: ' . gethostname());
});
EOF
then
    die "could not write the plugin on $TARGET"
fi
lab_run "$TARGET" "cd $LAB_WP_ROOT && sudo -u www-data env WP_CLI_CACHE_DIR=/var/cache/lab/wp-cli wp plugin activate $PLUGIN" \
    || die "could not activate $PLUGIN on $TARGET"
log_ok "$PLUGIN is active, and its code exists on $TARGET only"
log_info "watch 17-audit.sh, diagnose with 17-troubleshoot.md, restore with 17-rollback.sh"
