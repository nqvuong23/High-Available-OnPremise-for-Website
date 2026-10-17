#!/usr/bin/env bash
# scenario 06: restore the original certificate bundle on every LB
set -euo pipefail
SCENARIO_ID=06
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y]" "$@"
read -r -a lbs <<<"$LAB_LBS"
PKI=${lbs[0]}
lab_require_ssh "${lbs[@]}"

lab_mark "rollback: original certificate on $LAB_LBS"
for lb in $LAB_LBS; do
    lab_run "$lb" "sudo bash -c 'cd /etc/haproxy/certs &&
      if [ -f shop.pem.chaos-06 ]; then mv shop.pem.chaos-06 shop.pem; fi &&
      haproxy -c -q -f /etc/haproxy/haproxy.cfg && systemctl reload haproxy'" \
      || die "could not restore the certificate on $lb"
    log_ok "original certificate restored on $lb"
done
lab_run "$PKI" "sudo rm -f /root/ca/chaos-06.key /root/ca/chaos-06.csr /root/ca/chaos-06.ext /root/ca/chaos-06.crt /root/ca/chaos-06.pem" || true

lab_wait_for 20 "certificate valid for $LAB_SITE" probe_http "https://$LAB_SITE/"
log_ok "scenario 06 rolled back"
