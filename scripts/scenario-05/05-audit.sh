#!/usr/bin/env bash
# scenario 05: both LBs claim the VIP once VRRP adverts stop reaching one of them
set -uo pipefail
SCENARIO_ID=05
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

audit_init "$@"

audit_probe vip-owner probe_vip_owner
# the router can only send to one MAC: watch which LB really receives the traffic
audit_probe router-arp probe_vip_arp
audit_probe vip-https probe_http "https://$LAB_SITE/"
audit_probe lb-alive  probe_http "http://$LAB_VIP/haproxy-alive"
audit_probe db-write  probe_db_write
audit_run
