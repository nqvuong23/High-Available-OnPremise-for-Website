#!/usr/bin/env bash
# scenario 11: fill the root filesystem of one web node
set -euo pipefail
SCENARIO_ID=11
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

FILL=/var/tmp/lab-chaos-11.fill

lab_parse_args "usage: $(basename "$0") [-y] [-t web-node]
Fills / on one web node with $FILL. It is written as nobody, so on ext4 the root-reserved
blocks stay free and SSH and sudo keep working, while every non-root service hits ENOSPC." "$@"

TARGET=$(lab_target "$(echo "$LAB_WEBS" | cut -d' ' -f1)")
lab_require_member "$TARGET" "$LAB_WEBS"
lab_require_ssh "$TARGET"
lab_confirm "Fill the root filesystem of $TARGET."

lab_state_set target "$TARGET"
lab_mark "simulate: fill / on $TARGET"
# fallocate does the bulk fast; a dd tail then runs to ENOSPC, because allocating exactly the
# free space can fail on extent metadata. Without root-reserved blocks (xfs) keep 64 MiB, so
# root itself can still log in and clean up.
LAB_SSH_TIMEOUT=180 lab_run "$TARGET" "
  fstype=\$(findmnt -n -o FSTYPE --target /var/tmp)
  avail=\$(df --output=avail -B1 /var/tmp | tail -1)
  case \$fstype in
    ext*) sudo -u nobody fallocate -l \$(( avail - 16 * 1024 * 1024 )) $FILL &&
          { sudo -u nobody dd if=/dev/zero of=$FILL.tail bs=1M status=none 2>/dev/null || true; } ;;
    *)    sudo -u nobody fallocate -l \$(( avail - 64 * 1024 * 1024 )) $FILL ;;
  esac
  df -h / | tail -1" \
  || die "could not fill / on $TARGET"
log_ok "/ is full for non-root users on $TARGET"
log_info "watch 11-audit.sh, diagnose with 11-troubleshoot.md, restore with 11-rollback.sh"
