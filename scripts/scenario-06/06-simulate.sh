#!/usr/bin/env bash
# scenario 06: replace the HAProxy certificate with one signed for the wrong name
set -euo pipefail
SCENARIO_ID=06
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y]
Issues a certificate for wrong.$LAB_DOMAIN from the lab CA and installs it on every LB.
The chain is valid; only the name is wrong. The original bundle is kept as shop.pem.chaos-06." "$@"

read -r -a lbs <<<"$LAB_LBS"
PKI=${lbs[0]}
lab_require_ssh "${lbs[@]}"
lab_confirm "Install a certificate for wrong.$LAB_DOMAIN on $LAB_LBS."

lab_mark "simulate: certificate for wrong.$LAB_DOMAIN on $LAB_LBS"
# signed by the real lab CA, so the error is a name mismatch and not an unknown issuer
lab_run "$PKI" "sudo bash -c 'cd /root/ca &&
  openssl req -new -newkey rsa:2048 -nodes -keyout chaos-06.key -subj /CN=wrong.$LAB_DOMAIN -out chaos-06.csr 2>/dev/null &&
  echo subjectAltName=DNS:wrong.$LAB_DOMAIN > chaos-06.ext &&
  openssl x509 -req -in chaos-06.csr -CA lab-ca.crt -CAkey lab-ca.key -CAcreateserial -days 30 -sha256 -extfile chaos-06.ext -out chaos-06.crt 2>/dev/null &&
  cat chaos-06.crt lab-ca.crt chaos-06.key > chaos-06.pem && chmod 600 chaos-06.pem'" \
  || die "could not issue the wrong certificate on $PKI"

for lb in $LAB_LBS; do
    lab_run "$PKI" "sudo cat /root/ca/chaos-06.pem" | lab_run_stdin "$lb" "sudo bash -c 'umask 077 &&
      cd /etc/haproxy/certs &&
      { [ -f shop.pem.chaos-06 ] || cp -p shop.pem shop.pem.chaos-06; } &&
      cat > shop.pem.new && mv shop.pem.new shop.pem &&
      haproxy -c -q -f /etc/haproxy/haproxy.cfg && systemctl reload haproxy'" \
      || die "could not install the certificate on $lb"
    log_ok "wrong certificate live on $lb"
done
log_info "watch 06-audit.sh, diagnose with 06-troubleshoot.md, restore with 06-rollback.sh"
