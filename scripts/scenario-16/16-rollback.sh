#!/usr/bin/env bash
# scenario 16: return the old primary (RB-04 or RB-03), then optionally switch back to it
set -euo pipefail
SCENARIO_ID=16
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

lab_parse_args "usage: $(basename "$0") [-y] [-t old-primary]
Run after starting the old primary from Windows (vagrant up <node>). Works out what happened:
  no failover done  -> opens write on the old primary again (RB-04)
  failover done     -> checks errant GTIDs, rejoins it as a replica (RB-03), then offers a
                       planned switchover back so the lab matches the inventory again" "$@"

[[ -n ${LAB_REPL_PASS:-} && -n ${LAB_REPL_USER:-} ]] || die "replication credentials missing from ${LAB_SECRETS:-the secrets file}"

OLD=$(lab_saved_target "$LAB_DB_PRIMARY")
NEW=$(echo "$LAB_DBS" | tr ' ' '\n' | grep -vx "$OLD" | head -1)
lab_run "$OLD" true >/dev/null 2>&1 || die "$OLD is unreachable; start it from Windows first: vagrant up $OLD"
lab_require_ssh "$NEW"

ro_of() { lab_sql "$1" <<<"SELECT @@read_only"; }
gtids_of() { lab_sql "$1" <<<"SELECT REPLACE(@@gtid_executed, '\n', '')"; }

# point $1 at $2 as its source; the password travels on stdin, never on a command line
attach_replica() {
    lab_sql "$1" <<EOF
STOP REPLICA;
RESET REPLICA ALL;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST = '$(lab_ip "$2")', SOURCE_PORT = $LAB_MYSQL_PORT,
  SOURCE_USER = '$LAB_REPL_USER', SOURCE_PASSWORD = '$LAB_REPL_PASS',
  SOURCE_AUTO_POSITION = 1, SOURCE_CONNECT_RETRY = 10, GET_SOURCE_PUBLIC_KEY = 1;
START REPLICA;
EOF
}

old_ro=$(ro_of "$OLD")
new_ro=$(ro_of "$NEW")
log_info "$OLD read_only=$old_ro, $NEW read_only=$new_ro"

if [[ $old_ro == 0 && $new_ro == 0 ]]; then
    die "SPLIT BRAIN: $OLD and $NEW are both writable. Stop every writer, decide which node holds the confirmed orders, and repair by hand. This script will not choose for you."
fi

if [[ $old_ro == 0 ]]; then
    log_info "$OLD is already the writable primary; nothing to return"
    lab_wait_for 20 "write path through the VIP" probe_db_write
    lab_state_clear
    exit 0
fi

if [[ $new_ro == 1 ]]; then
    # nobody was promoted: this is RB-04, the restarted primary only needs write opened
    lab_confirm "No failover happened. Open write on $OLD again (RB-04)."
    lab_mark "rollback: open write on $OLD (no failover had been done)"
    lab_sql "$OLD" <<<"SET GLOBAL super_read_only = OFF; SET GLOBAL read_only = OFF;"
    lab_wait_for 30 "write path through the VIP" probe_db_write
    lab_wait_for 60 "replication running on $NEW" probe_replication "$NEW"
    lab_state_clear
    log_ok "scenario 16 rolled back"
    exit 0
fi

# RB-03: $NEW was promoted. A transaction on $OLD that $NEW never received is errant:
# rejoining would hide it, or break replication on the first conflicting row.
errant=$(lab_sql "$OLD" <<<"SELECT GTID_SUBTRACT(REPLACE(@@gtid_executed, '\n', ''), '$(gtids_of "$NEW")')")
if [[ -n $errant ]]; then
    log_error "$OLD holds transactions $NEW never received: $errant"
    log_error "they were committed on $OLD before it died; with AFTER_SYNC no client was told they succeeded"
    die "refusing to rejoin. Inspect them with mysqlbinlog on $OLD, or restore db01 and db02 together from one snapshot"
fi
log_ok "no errant GTID on $OLD"

lab_confirm "Make $OLD a replica of $NEW (RB-03)."
lab_mark "rollback: $OLD rejoins as a replica of $NEW"
attach_replica "$OLD" "$NEW"
lab_wait_for 60 "$OLD replicating from $NEW" probe_replication "$OLD"

if [[ $LAB_YES != 1 ]]; then
    read -r -p "Switch back so $OLD is primary again (a few seconds without writes)? Type yes: " answer || answer=''
    if [[ $answer != yes ]]; then
        log_info "leaving $NEW as primary. To make that permanent, set mysql_primary_host: $NEW in"
        log_info "ansible/inventory/group_vars/all/main.yml and rerun: ansible-playbook site.yml --tags db,lb,mgmt"
        log_info "until then a HAProxy reload reverts the runtime switch made during RB-02"
        exit 0
    fi
fi

# planned switchover: freeze writes on the current primary, let the old one catch up, swap
lab_mark "rollback: switchover $NEW -> $OLD"
lab_sql "$NEW" <<<"SET GLOBAL super_read_only = ON;"
caught_up=$(lab_sql "$OLD" <<<"SELECT WAIT_FOR_EXECUTED_GTID_SET('$(gtids_of "$NEW")', 30)")
if [[ $caught_up != 0 ]]; then
    lab_sql "$NEW" <<<"SET GLOBAL super_read_only = OFF; SET GLOBAL read_only = OFF;"
    die "$OLD did not catch up within 30s; write reopened on $NEW, switchover abandoned"
fi
lab_sql "$OLD" <<<"STOP REPLICA; RESET REPLICA ALL; SET GLOBAL super_read_only = OFF; SET GLOBAL read_only = OFF;"
attach_replica "$NEW" "$OLD"

# a reload drops the runtime enable/disable done during RB-02 and goes back to haproxy.cfg
for lb in $LAB_LBS; do
    lab_run "$lb" "sudo systemctl reload haproxy" || log_warn "could not reload haproxy on $lb"
done

lab_wait_for 30 "write path through the VIP" probe_db_write
lab_wait_for 60 "replication running on $NEW" probe_replication "$NEW"
lab_state_clear
log_ok "scenario 16 rolled back: $OLD is primary, $NEW replicates from it"
