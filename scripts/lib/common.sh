#!/usr/bin/env bash
# Shared helpers for every scenario script. Source it, never run it.
# The topology comes from /etc/lab/lab.env, written by the Ansible role mgmt,
# so no address is typed in any script.

[[ -n ${_LAB_COMMON_LOADED:-} ]] && return 0
_LAB_COMMON_LOADED=1

LAB_ENV_FILE=${LAB_ENV_FILE:-/etc/lab/lab.env}
if [[ ! -r $LAB_ENV_FILE ]]; then
    echo "[ERROR] $LAB_ENV_FILE missing; run ansible-playbook site.yml on mgmt01 first" >&2
    exit 2
fi
# shellcheck source=/dev/null
source "$LAB_ENV_FILE"
if [[ -r ${LAB_SECRETS:-} ]]; then
    # shellcheck source=/dev/null
    source "$LAB_SECRETS"
else
    echo "[WARN] ${LAB_SECRETS:-secrets file} unreadable: HAProxy stats and replication checks will fail" >&2
fi

SCENARIO_ID=${SCENARIO_ID:-00}
SCENARIO_DIR=${SCENARIO_DIR:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[1]}")")" && pwd)}
LAB_LOG_DIR="$SCENARIO_DIR/logs"
LAB_STATE_FILE="$SCENARIO_DIR/.state"
LAB_MARK_FILE="$LAB_LOG_DIR/$SCENARIO_ID-markers.log"
mkdir -p "$LAB_LOG_DIR"

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    C_OK=$'\e[32m' C_WARN=$'\e[33m' C_FAIL=$'\e[31m' C_INFO=$'\e[36m'
    C_MARK=$'\e[35m' C_DIM=$'\e[2m' C_BOLD=$'\e[1m' C_OFF=$'\e[0m'
else
    C_OK='' C_WARN='' C_FAIL='' C_INFO='' C_MARK='' C_DIM='' C_BOLD='' C_OFF=''
fi

# ---------------------------------------------------------------- output and time

log_info()  { printf '%s[INFO]%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
log_ok()    { printf '%s[OK]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
log_error() { printf '%s[ERROR]%s %s\n' "$C_FAIL" "$C_OFF" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# EPOCHREALTIME uses the locale decimal mark, so strip either one
now_ms()  { local t=${EPOCHREALTIME//[.,]/}; printf '%s' "$(( t / 1000 ))"; }
now_hms() { date '+%H:%M:%S.%3N'; }
ms_to_hms() { date -d "@$(( $1 / 1000 )).$(printf '%03d' $(( $1 % 1000 )))" '+%H:%M:%S.%3N'; }
fmt_ms()  { printf '%d.%02ds' $(( $1 / 1000 )) $(( ($1 % 1000) / 10 )); }
_secs_to_ms() { awk -v s="${1:-0}" 'BEGIN { printf "%d", s * 1000 }'; }

# ---------------------------------------------------------------- hosts and ssh

lab_ip() {
    local var="LAB_IP_$1"
    [[ -n ${!var:-} ]] || die "unknown host '$1'; known hosts: $LAB_ALL"
    printf '%s' "${!var}"
}

# zone of a host, and the gateway or subnet of a zone; read from lab.env, never typed
lab_zone() {
    local var="LAB_ZONE_$1"
    [[ -n ${!var:-} ]] || die "unknown host '$1'"
    printf '%s' "${!var}"
}

lab_gw() {
    local var="LAB_GW_$1"
    [[ -n ${!var:-} ]] || die "unknown zone '$1'"
    printf '%s' "${!var}"
}

lab_subnet() {
    local var="LAB_SUBNET_$1"
    [[ -n ${!var:-} ]] || die "unknown zone '$1'"
    printf '%s' "${!var}"
}

lab_in_list() {
    local needle=$1 item
    for item in $2; do [[ $item == "$needle" ]] && return 0; done
    return 1
}

LAB_SSH_TIMEOUT=${LAB_SSH_TIMEOUT:-6}
LAB_SSH_OPTS=(
    -i "$LAB_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=3
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
    -o ServerAliveInterval=2 -o ServerAliveCountMax=2
    -o ControlMaster=auto -o "ControlPath=$HOME/.ssh/lab-%C" -o ControlPersist=300
)

# run one command string on a node as the operator; stdin is closed so loops keep theirs
lab_run() {
    local host=$1 ip
    shift
    ip=$(lab_ip "$host") || return 255
    timeout -k 1 "$LAB_SSH_TIMEOUT" ssh -n "${LAB_SSH_OPTS[@]}" "$LAB_SSH_USER@$ip" "$*"
}

# same, but forwards stdin: SQL travels this way so no password reaches a command line
lab_run_stdin() {
    local host=$1 ip
    shift
    ip=$(lab_ip "$host") || return 255
    timeout -k 1 "$LAB_SSH_TIMEOUT" ssh "${LAB_SSH_OPTS[@]}" "$LAB_SSH_USER@$ip" "$*"
}

# MySQL as root over the node's unix socket (auth_socket); the SQL comes on stdin
lab_sql() {
    local host=$1
    shift
    lab_run_stdin "$host" "sudo mysql -N -B $*"
}

# MySQL as the operator, direct to one named node
db_ops() {
    local host=$1 ip
    shift
    ip=$(lab_ip "$host") || return 1
    timeout 6 mysql --defaults-extra-file="$LAB_MYSQL_OPS_CNF" --connect-timeout=2 -h "$ip" -N -B "$@"
}

# MySQL as the application, through the VIP exactly like WordPress
db_vip() {
    timeout 6 mysql --defaults-extra-file="$LAB_MYSQL_WP_CNF" --connect-timeout=2 -D "$LAB_WP_DB" -N -B "$@"
}

# every db node that is writable right now, space separated; empty when none is
db_writable_nodes() {
    local host ro out=()
    for host in $LAB_DBS; do
        ro=$(db_ops "$host" -e 'SELECT @@read_only' 2>/dev/null) || continue
        [[ $ro == 0 ]] && out+=("$host")
    done
    printf '%s' "${out[*]}"
}

# ---------------------------------------------------------------- scenario plumbing

LAB_YES=0
LAB_TARGET=''

# the node given with -t, otherwise the scenario default
lab_target() { printf '%s' "${LAB_TARGET:-$1}"; }

# for rollbacks: -t first, then the node the simulate step recorded, then the default
lab_saved_target() {
    local saved
    saved=$(lab_state_get target)
    printf '%s' "${LAB_TARGET:-${saved:-$1}}"
}

# common options of simulate and rollback scripts: -y no prompt, -t target node
lab_parse_args() {
    local usage=$1 opt OPTIND=1
    shift
    while getopts ':yt:h' opt; do
        case $opt in
            y) LAB_YES=1 ;;
            t) LAB_TARGET=$OPTARG ;;
            h) printf '%s\n' "$usage"; exit 0 ;;
            :) die "option -$OPTARG needs a value" ;;
            *) die "unknown option -$OPTARG; see -h" ;;
        esac
    done
}

lab_confirm() {
    [[ $LAB_YES == 1 ]] && return 0
    local answer
    read -r -p "$1 Type yes to continue: " answer || answer=''
    [[ $answer == yes ]] || die "aborted, nothing changed"
}

# lab_wait_for SECONDS WHAT probe args...: poll a probe until OK and report how long it took.
# The probe runs inside || so errexit in the caller cannot abort it halfway.
lab_wait_for() {
    local limit=$1 what=$2 start
    shift 2
    start=$(now_ms)
    while :; do
        _TICK_CACHE=()
        P_STATE=FAIL P_DETAIL=''
        "$@" || true
        if [[ $P_STATE == OK ]]; then
            log_ok "$what after $(fmt_ms $(( $(now_ms) - start ))) ($P_DETAIL)"
            return 0
        fi
        if (( $(now_ms) - start > limit * 1000 )); then
            log_warn "$what not reached within ${limit}s (last: $P_DETAIL)"
            return 1
        fi
        sleep 1
    done
}

lab_require_member() {
    lab_in_list "$1" "$2" || die "$1 is not one of: $2"
}

lab_require_ssh() {
    local host
    for host in "$@"; do
        lab_run "$host" true >/dev/null 2>&1 || die "cannot reach $host over SSH"
    done
}

lab_state_set() {
    touch "$LAB_STATE_FILE"
    { grep -v "^$1=" "$LAB_STATE_FILE" || true; printf '%s=%s\n' "$1" "$2"; } > "$LAB_STATE_FILE.tmp"
    mv "$LAB_STATE_FILE.tmp" "$LAB_STATE_FILE"
}

lab_state_get() {
    [[ -f $LAB_STATE_FILE ]] || return 0
    sed -n "s/^$1=//p" "$LAB_STATE_FILE" | tail -1
}

lab_state_clear() { rm -f "$LAB_STATE_FILE"; }

# The lab runs no firewall (ADR-25), so a filter rule only ever exists while a scenario
# injects one. It lives in its own table, never in /etc/nftables.conf, so nothing persists
# a reboot and deleting the table is the whole rollback. The router keeps its masquerade
# in table ip router_nat, which this never touches.
# lab_chaos_rule NODE HOOK RULE   (HOOK is input or output)
lab_chaos_rule() {
    local host=$1 hook=$2 rule=$3
    lab_run_stdin "$host" "sudo nft -f -" <<EOF
table inet lab_chaos
delete table inet lab_chaos
table inet lab_chaos {
    chain $hook {
        type filter hook $hook priority -10; policy accept;
        $rule
    }
}
EOF
}

lab_chaos_clear() {
    lab_run "$1" "if sudo nft list table inet lab_chaos >/dev/null 2>&1; then sudo nft delete table inet lab_chaos; fi"
}

# the LB holding the VIP right now (two names during a split brain, empty if none)
lab_vip_owner() {
    _TICK_CACHE=()
    probe_vip_owner || true
    printf '%s' "${_TICK_CACHE[vip_owner]:-}"
}

# a timestamped line the running audit prints inline, so before/during/after is visible
lab_mark() {
    printf '%s|%s\n' "$(now_ms)" "$*" >> "$LAB_MARK_FILE"
    log_info "marked at $(now_hms): $*"
}

# ---------------------------------------------------------------- probes
# Each probe sets P_STATE to OK, WARN or FAIL and a short P_DETAIL.
# Probes never exit and never block longer than their own timeout.

P_STATE=OK
P_DETAIL=''
declare -A _TICK_CACHE=()

_curl_reason() {
    case $1 in
        6)  echo dns-fail ;;
        7)  echo refused ;;
        28) echo timeout ;;
        35) echo tls-handshake ;;
        51|60) echo cert-invalid ;;
        52) echo empty-reply ;;
        56) echo conn-reset ;;
        77) echo ca-missing ;;
        *)  echo "curl-$1" ;;
    esac
}

_mysql_reason() {
    local msg=$1 code who
    code=$(sed -n 's/^ERROR \([0-9]*\).*/\1/p' <<<"$msg" | head -1)
    case $code in
        1045)
            who=$(sed -n "s/.*for user '\([^']*\)'@'\([^']*\)'.*/\1@\2/p" <<<"$msg" | head -1)
            echo "1045 denied ${who}" ;;
        1290) echo "1290 read-only" ;;
        2003) echo "2003 no-route" ;;
        2013) echo "2013 lost-conn" ;;
        1146) echo "1146 no-table" ;;
        '')   echo "${msg:0:40}" ;;
        *)    echo "err-$code" ;;
    esac
}

# probe_http [--expect 'CODES'] [--cookie C] [--insecure] [--no-resolve] [--max-ms N] URL
# --resolve pins the site name to the VIP, so a DNS fault cannot hide inside an HTTP probe
probe_http() {
    local expect='200|301|302' max_ms=1000 resolve=1 args=() url out rc code ms
    while [[ $# -gt 1 ]]; do
        case $1 in
            --expect)     expect=$2; shift 2 ;;
            --cookie)     args+=(-b "$2"); shift 2 ;;
            --insecure)   args+=(-k); shift ;;
            --no-resolve) resolve=0; shift ;;
            --max-ms)     max_ms=$2; shift 2 ;;
            *) break ;;
        esac
    done
    url=$1
    if (( resolve )); then
        args+=(--resolve "$LAB_SITE:443:$LAB_VIP" --resolve "$LAB_SITE:80:$LAB_VIP")
    fi
    out=$(curl -s -o /dev/null -m "${LAB_HTTP_TIMEOUT:-2}" --cacert "$LAB_CA_CERT" \
              -w '%{http_code} %{time_total}' "${args[@]}" "$url" 2>/dev/null)
    rc=$?
    code=${out%% *}
    ms=$(_secs_to_ms "${out#* }")
    if (( rc != 0 )); then
        P_STATE=FAIL P_DETAIL="$(_curl_reason "$rc") ${ms}ms"
        return
    fi
    P_DETAIL="$code ${ms}ms"
    if [[ ! $code =~ ^($expect)$ ]]; then
        P_STATE=FAIL
    elif (( ms > max_ms )); then
        P_STATE=WARN
    else
        P_STATE=OK
    fi
}

# probe_header NAME URL [--cookie C]: the value of one response header, OK when absent
probe_header() {
    local name=$1 url=$2 args=() value
    [[ ${3:-} == --cookie ]] && args+=(-b "$4")
    value=$(curl -s -o /dev/null -D - -m "${LAB_HTTP_TIMEOUT:-2}" --cacert "$LAB_CA_CERT" \
                --resolve "$LAB_SITE:443:$LAB_VIP" "${args[@]}" "$url" 2>/dev/null \
            | tr -d '\r' | awk -v h="$(tr '[:upper:]' '[:lower:]' <<<"$name"):" 'tolower($1) == h { print $2 }')
    if [[ -z $value ]]; then
        P_STATE=OK P_DETAIL=absent
    else
        P_STATE=FAIL P_DETAIL=$value
    fi
}

_hap_fetch() {
    local key="hap:$1" ip
    if [[ -n ${_TICK_CACHE[$key]+x} ]]; then
        _HAP_CSV=${_TICK_CACHE[$key]}
        return
    fi
    ip=$(lab_ip "$1")
    _HAP_CSV=$(curl -s -m 2 -u "${LAB_STATS_USER:-}:${LAB_STATS_PASS:-}" \
                   "http://$ip:$LAB_STATS_PORT/stats;csv" 2>/dev/null)
    _TICK_CACHE[$key]=$_HAP_CSV
}

# probe_haproxy LB|auto BACKEND SERVER [EXPECTED_STATUS]: server state as HAProxy sees it
probe_haproxy() {
    local lbs=$1 backend=$2 server=$3 expect=${4:-UP} lb row status check code
    [[ $lbs == auto ]] && lbs=$LAB_LBS
    row=''
    for lb in $lbs; do
        _hap_fetch "$lb"
        [[ -n $_HAP_CSV ]] || continue
        # columns found by header name, so a HAProxy upgrade cannot shift them
        row=$(awk -F, -v be="$backend" -v sv="$server" '
            NR == 1 { sub(/^# /, ""); for (i = 1; i <= NF; i++) col[$i] = i; next }
            $1 == be && $2 == sv { print $col["status"] "|" $col["check_status"] "|" $col["check_code"]; exit }
        ' <<<"$_HAP_CSV")
        [[ -n $row ]] && break
    done
    if [[ -z $row ]]; then
        P_STATE=FAIL P_DETAIL='stats unreachable'
        return
    fi
    IFS='|' read -r status check code <<<"$row"
    check=${check#\* }
    P_DETAIL="$status${check:+ $check}${code:+/$code}"
    if [[ $status =~ ^($expect)$ ]]; then
        P_STATE=OK
    elif [[ $status == */* ]]; then
        P_STATE=WARN
    else
        P_STATE=FAIL
    fi
}

# which LB holds the VIP; two holders is a split brain
probe_vip_owner() {
    local lb out owners=() unknown=()
    for lb in $LAB_LBS; do
        out=$(lab_run "$lb" "ip -4 -o addr show | grep -qF ' $LAB_VIP/' && echo yes || echo no" 2>/dev/null)
        case $out in
            yes) owners+=("$lb") ;;
            no)  ;;
            *)   unknown+=("$lb") ;;
        esac
    done
    if (( ${#owners[@]} == 1 )); then
        P_STATE=OK P_DETAIL=${owners[0]}
    elif (( ${#owners[@]} > 1 )); then
        P_STATE=FAIL P_DETAIL="SPLIT ${owners[*]}"
    else
        P_STATE=FAIL P_DETAIL=none
    fi
    if (( ${#unknown[@]} )); then
        [[ $P_STATE == OK ]] && P_STATE=WARN
        P_DETAIL+=" unreachable:${unknown[*]}"
    fi
    _TICK_CACHE[vip_owner]=${owners[*]}
}

# the MAC the router currently uses for the VIP, translated to an LB name
declare -A _LB_MACS=()
probe_vip_arp() {
    local lb mac
    if (( ${#_LB_MACS[@]} == 0 )); then
        for lb in $LAB_LBS; do
            mac=$(lab_run "$lb" "cat /sys/class/net/\$(ip -o -4 addr show | awk '\$4 ~ \"^$(lab_ip "$lb")/\" {print \$2}')/address" 2>/dev/null)
            [[ -n $mac ]] && _LB_MACS[$mac]=$lb
        done
    fi
    mac=$(lab_run "$LAB_ROUTER" "ip neigh show $LAB_VIP" 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "lladdr") print $(i + 1) }')
    if [[ -z $mac ]]; then
        P_STATE=WARN P_DETAIL='no arp entry'
    else
        P_STATE=OK P_DETAIL=${_LB_MACS[$mac]:-$mac}
    fi
}

# a real write through VIP:3306, the same path as a WooCommerce order
probe_db_write() {
    local out rc t0 ms
    t0=$(now_ms)
    out=$(db_vip -e "UPDATE lab_probe SET ts = NOW(3), writer = 'audit' WHERE id = 1; SELECT @@hostname" 2>&1)
    rc=$?
    ms=$(( $(now_ms) - t0 ))
    if (( rc == 0 )); then
        P_DETAIL="${out##*$'\n'} ${ms}ms"
        if (( ms > 1000 )); then P_STATE=WARN; else P_STATE=OK; fi
    elif (( rc == 124 )); then
        P_STATE=FAIL P_DETAIL="timeout ${ms}ms"
    else
        P_STATE=FAIL P_DETAIL=$(_mysql_reason "$out")
    fi
}

# probe_db_role NODE [rw|ro|any]: read_only of one node, asked directly
probe_db_role() {
    local host=$1 expect=${2:-any} out rc role
    out=$(db_ops "$host" -e 'SELECT @@read_only' 2>&1)
    rc=$?
    if (( rc != 0 )); then
        P_STATE=FAIL
        if (( rc == 124 )); then P_DETAIL=timeout; else P_DETAIL=$(_mysql_reason "$out"); fi
        return
    fi
    role=rw
    [[ $out == 1 ]] && role=ro
    P_DETAIL=$role
    if [[ $expect == any || $expect == "$role" ]]; then P_STATE=OK; else P_STATE=FAIL; fi
}

# probe_mysqlchk NODE [EXPECTED_CODES]: what HAProxy hears on port 9200
probe_mysqlchk() {
    local host=$1 expect=${2:-200|503} code rc ip
    ip=$(lab_ip "$host")
    code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://$ip:$LAB_MYSQLCHK_PORT/" 2>/dev/null)
    rc=$?
    if (( rc != 0 )); then
        P_STATE=FAIL P_DETAIL=$(_curl_reason "$rc")
        return
    fi
    case $code in
        200) P_DETAIL='200 rw' ;;
        503) P_DETAIL='503 ro' ;;
        *)   P_DETAIL=$code ;;
    esac
    if [[ $code =~ ^($expect)$ ]]; then P_STATE=OK; else P_STATE=FAIL; fi
}

probe_replication() {
    local host=$1 out rc io sql lag ioerr sqlerr
    out=$(db_ops "$host" -e 'SHOW REPLICA STATUS\G' 2>&1)
    rc=$?
    if (( rc != 0 )); then
        P_STATE=FAIL
        if (( rc == 124 )); then P_DETAIL=timeout; else P_DETAIL=$(_mysql_reason "$out"); fi
        return
    fi
    if [[ -z $out ]]; then
        P_STATE=WARN P_DETAIL='not a replica'
        return
    fi
    io=$(awk -F': ' '/ Replica_IO_Running:/ { print $2 }' <<<"$out")
    sql=$(awk -F': ' '/ Replica_SQL_Running:/ { print $2 }' <<<"$out")
    lag=$(awk -F': ' '/ Seconds_Behind_Source:/ { print $2 }' <<<"$out")
    ioerr=$(awk -F': ' '/ Last_IO_Errno:/ { print $2 }' <<<"$out")
    sqlerr=$(awk -F': ' '/ Last_SQL_Errno:/ { print $2 }' <<<"$out")
    if [[ $io == Yes && $sql == Yes ]]; then
        P_STATE=OK P_DETAIL="Yes/Yes lag=${lag}s"
    else
        P_STATE=FAIL P_DETAIL="io=$io sql=$sql"
        [[ ${ioerr:-0} != 0 ]] && P_DETAIL+=" io_err=$ioerr"
        [[ ${sqlerr:-0} != 0 ]] && P_DETAIL+=" sql_err=$sqlerr"
    fi
}

# the writable node, found per tick rather than trusted from the inventory
_primary_now() {
    if [[ -z ${_TICK_CACHE[primary]+x} ]]; then
        _TICK_CACHE[primary]=$(db_writable_nodes)
    fi
    printf '%s' "${_TICK_CACHE[primary]}"
}

# whether a confirmed order is really on two nodes; OFF means semi-sync fell back to async
probe_semisync() {
    local host out status clients async
    host=$(_primary_now)
    if [[ -z $host ]]; then
        P_STATE=FAIL P_DETAIL='no writable node'
        return
    fi
    host=${host%% *}
    out=$(db_ops "$host" -e "SHOW GLOBAL STATUS WHERE Variable_name IN
        ('Rpl_semi_sync_source_status', 'Rpl_semi_sync_source_clients', 'Rpl_semi_sync_source_no_tx')" 2>&1) || {
        P_STATE=FAIL P_DETAIL=$(_mysql_reason "$out")
        return
    }
    status=$(awk '$1 == "Rpl_semi_sync_source_status" { print $2 }' <<<"$out")
    clients=$(awk '$1 == "Rpl_semi_sync_source_clients" { print $2 }' <<<"$out")
    async=$(awk '$1 == "Rpl_semi_sync_source_no_tx" { print $2 }' <<<"$out")
    P_DETAIL="$host:$status clients=$clients async_tx=$async"
    if [[ $status == ON ]]; then P_STATE=OK; else P_STATE=FAIL; fi
}

probe_primary() {
    local nodes
    nodes=$(_primary_now)
    case $(wc -w <<<"$nodes") in
        1) P_STATE=OK P_DETAIL=$nodes ;;
        0) P_STATE=FAIL P_DETAIL=none ;;
        *) P_STATE=FAIL P_DETAIL="SPLIT ${nodes// /+}" ;;
    esac
}

# replication lag measured by the heartbeat row, independent of Seconds_Behind_Source
probe_heartbeat() {
    local host=$1 out
    out=$(db_ops "$host" -e 'SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, ts, NOW(3)) / 1000) FROM lab.heartbeat' 2>&1) || {
        P_STATE=FAIL P_DETAIL=$(_mysql_reason "$out")
        return
    }
    P_DETAIL="lag ${out}ms"
    if (( out < 2000 )); then P_STATE=OK; elif (( out < 10000 )); then P_STATE=WARN; else P_STATE=FAIL; fi
}

probe_ping() {
    local target=$1 ip out
    if [[ $target =~ ^[0-9.]+$ ]]; then ip=$target; else ip=$(lab_ip "$target"); fi
    if out=$(ping -c 1 -W 1 -q "$ip" 2>/dev/null); then
        P_STATE=OK P_DETAIL="$(sed -n 's|.*= [0-9.]*/\([0-9.]*\)/.*|\1|p' <<<"$out")ms"
    else
        P_STATE=FAIL P_DETAIL=no-reply
    fi
}

# probe_tcp HOST|IP PORT [--closed]: TCP connect from mgmt01; --closed inverts the verdict
probe_tcp() {
    local target=$1 port=$2 want=${3:-} ip rc
    if [[ $target =~ ^[0-9.]+$ ]]; then ip=$target; else ip=$(lab_ip "$target"); fi
    timeout 2 bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null
    rc=$?
    case $rc in
        0)   P_DETAIL=open ;;
        124) P_DETAIL=timeout ;;
        *)   P_DETAIL=refused ;;
    esac
    if [[ $want == --closed ]]; then
        if (( rc == 0 )); then P_STATE=FAIL; else P_STATE=OK; fi
    else
        if (( rc == 0 )); then P_STATE=OK; else P_STATE=FAIL; fi
    fi
}

# probe_remote NODE COMMAND REGEX: first output line of a remote command against a regex
probe_remote() {
    local host=$1 cmd=$2 want=$3 out rc
    out=$(lab_run "$host" "$cmd" 2>&1)
    rc=$?
    out=${out%%$'\n'*}
    if (( rc == 255 )); then
        P_STATE=FAIL P_DETAIL=ssh-unreachable
        return
    elif (( rc == 124 )); then
        P_STATE=FAIL P_DETAIL=ssh-timeout
        return
    fi
    P_DETAIL=${out:0:48}
    [[ -z $P_DETAIL ]] && P_DETAIL="rc=$rc"
    if [[ $out =~ $want ]]; then P_STATE=OK; else P_STATE=FAIL; fi
}

probe_service() { probe_remote "$1" "systemctl is-active $2" '^active$'; }

probe_sysctl() { probe_remote "$1" "sysctl -n $2" "^$3\$"; }

# probe_remote_tcp FROM_NODE IP PORT [--closed]: connectivity as seen from a lab node
probe_remote_tcp() {
    local from=$1 ip=$2 port=$3 want=${4:-} out
    out=$(lab_run "$from" "timeout 2 bash -c 'exec 3<>/dev/tcp/$ip/$port' 2>/dev/null; echo \$?" 2>/dev/null)
    case $out in
        0)   P_DETAIL=open ;;
        124) P_DETAIL=timeout ;;
        '')  P_STATE=FAIL P_DETAIL=ssh-unreachable; return ;;
        *)   P_DETAIL=refused ;;
    esac
    if [[ $want == --closed ]]; then
        if [[ $out == 0 ]]; then P_STATE=FAIL; else P_STATE=OK; fi
    else
        if [[ $out == 0 ]]; then P_STATE=OK; else P_STATE=FAIL; fi
    fi
}

probe_disk() {
    local host=$1 path=${2:-/} out pct ipct
    out=$(lab_run "$host" "df --output=pcent,ipcent $path | tail -1" 2>/dev/null) || {
        P_STATE=FAIL P_DETAIL=ssh-unreachable
        return
    }
    read -r pct ipct <<<"${out//%/}"
    P_DETAIL="disk=${pct}% inode=${ipct}%"
    if (( pct >= 98 || ipct >= 98 )); then
        P_STATE=FAIL
    elif (( pct >= 90 || ipct >= 90 )); then
        P_STATE=WARN
    else
        P_STATE=OK
    fi
}

probe_mount() {
    local host=$1 out
    out=$(lab_run "$host" "findmnt -n -o FSTYPE $LAB_UPLOADS || echo not-mounted" 2>/dev/null)
    P_DETAIL=${out:-ssh-unreachable}
    if [[ $out == nfs4 ]]; then P_STATE=OK; else P_STATE=FAIL; fi
}

# read the probe file on NFS as www-data; the timeout runs inside sudo so it kills
# the hung stat itself instead of leaving it stuck in state D on every tick
probe_nfs_read() {
    local host=$1 out rc
    out=$(lab_run "$host" "sudo -u www-data timeout -s KILL 3 stat -c %s $LAB_UPLOADS/$LAB_PROBE_FILE 2>&1; echo rc=\$?" 2>/dev/null)
    rc=${out##*rc=}
    out=${out%rc=*}
    out=${out%%$'\n'*}
    case $rc in
        0)   P_STATE=OK P_DETAIL=readable ;;
        137) P_STATE=FAIL P_DETAIL='hang >3s' ;;
        '')  P_STATE=FAIL P_DETAIL=ssh-unreachable ;;
        *)   out=${out##*: }; P_STATE=FAIL P_DETAIL=${out:0:32} ;;
    esac
}

# processes stuck in uninterruptible sleep: the fingerprint of a dead hard NFS mount
probe_dstate() {
    local host=$1 out
    out=$(lab_run "$host" "ps -eo stat= | grep -c '^D'" 2>/dev/null)
    if [[ -z $out ]]; then
        P_STATE=FAIL P_DETAIL=ssh-unreachable
    elif (( out == 0 )); then
        P_STATE=OK P_DETAIL='D=0'
    else
        P_STATE=WARN P_DETAIL="D=$out"
    fi
}

probe_cert() {
    local out san
    out=$(timeout 4 openssl s_client -connect "$LAB_VIP:443" -servername "$LAB_SITE" </dev/null 2>/dev/null \
          | openssl x509 -noout -ext subjectAltName 2>/dev/null)
    if [[ -z $out ]]; then
        P_STATE=FAIL P_DETAIL='no certificate'
        return
    fi
    san=$(grep -o 'DNS:[^, ]*' <<<"$out" | head -1)
    P_DETAIL=${san:-no-dns-san}
    if grep -qF "DNS:$LAB_SITE" <<<"$out"; then P_STATE=OK; else P_STATE=FAIL; fi
}

# probe_dns NAME SERVER [EXPECTED]: ask one server directly, bypassing the local resolver
probe_dns() {
    local name=$1 server=$2 want=${3:-} out rc
    out=$(dig +short +time=1 +tries=1 "@$server" "$name" A 2>/dev/null)
    rc=$?
    out=${out%%$'\n'*}
    if (( rc == 9 )) || [[ $out == *'timed out'* || $out == *'communications error'* ]]; then
        P_STATE=FAIL P_DETAIL=timeout
    elif [[ -z $out ]]; then
        P_STATE=FAIL P_DETAIL='no answer'
    else
        P_DETAIL=$out
        if [[ -z $want || $out == "$want" ]]; then P_STATE=OK; else P_STATE=FAIL; fi
    fi
}

# probe_resolver NAME [EXPECTED]: what applications on mgmt01 actually get
probe_resolver() {
    local name=$1 want=${2:-} out
    out=$(timeout 4 getent ahostsv4 "$name" 2>/dev/null | awk 'NR == 1 { print $1 }')
    if [[ -z $out ]]; then
        P_STATE=FAIL P_DETAIL=unresolved
    else
        P_DETAIL=$out
        if [[ -z $want || $out == "$want" ]]; then P_STATE=OK; else P_STATE=FAIL; fi
    fi
}

# code tree hash on every web node; more than one distinct hash is drift
probe_code_match() {
    local host out hashes=() distinct
    for host in $LAB_WEBS; do
        out=$(LAB_SSH_TIMEOUT=20 lab_run "$host" "sudo bash -c 'cd $LAB_WP_ROOT && find . -path ./wp-content/uploads -prune -o -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-10'" 2>/dev/null)
        hashes+=("$host:${out:-?}")
    done
    distinct=$(printf '%s\n' "${hashes[@]#*:}" | sort -u | wc -l)
    P_DETAIL="${hashes[*]}"
    if (( distinct == 1 )) && [[ ${hashes[0]#*:} != '?' ]]; then P_STATE=OK; else P_STATE=FAIL; fi
}

# ---------------------------------------------------------------- the audit dashboard
# Usage in a scenario:  audit_init "$@"; audit_probe LABEL probe_x args...; audit_run

AUDIT_INTERVAL=${AUDIT_INTERVAL:-1}
AUDIT_COUNT=0
AUDIT_CHANGES_ONLY=0
AUDIT_LABELS=()
AUDIT_CMDS=()
_AUDIT_EVENTS=()
_MARKS_SEEN=0
declare -A _PREV_STATE=() _FAIL_SINCE=() _FAIL_TICKS=() _FAIL_MAX=() _FAIL_TOTAL=()

audit_init() {
    local opt OPTIND=1
    while getopts ':i:n:ch' opt; do
        case $opt in
            i) AUDIT_INTERVAL=$OPTARG ;;
            n) AUDIT_COUNT=$OPTARG ;;
            c) AUDIT_CHANGES_ONLY=1 ;;
            h) printf 'usage: %s [-i seconds] [-n ticks] [-c]\n' "$(basename "$0")"
               printf '  -i  seconds between ticks (default %s)\n' "$AUDIT_INTERVAL"
               printf '  -n  stop after n ticks (default: until Ctrl-C)\n'
               printf '  -c  print a tick only when something changed\n'
               exit 0 ;;
            *) die "unknown option; see -h" ;;
        esac
    done
    AUDIT_INTERVAL_MS=$(_secs_to_ms "$AUDIT_INTERVAL")
    AUDIT_LOG="$LAB_LOG_DIR/$SCENARIO_ID-audit-$(date +%Y%m%d-%H%M%S).log"
}

audit_probe() {
    AUDIT_LABELS+=("$1")
    shift
    AUDIT_CMDS+=("$(printf '%q ' "$@")")
}

_audit_emit() {
    printf '%s\n' "$2"
    printf '%s\n' "$1" >> "$AUDIT_LOG"
}

_audit_color() {
    case $1 in
        OK)   printf '%s' "$C_OK" ;;
        WARN) printf '%s' "$C_WARN" ;;
        *)    printf '%s' "$C_FAIL" ;;
    esac
}

_audit_worse() {
    local rank_a rank_b
    case $1 in OK) rank_a=0 ;; WARN) rank_a=1 ;; *) rank_a=2 ;; esac
    case $2 in OK) rank_b=0 ;; WARN) rank_b=1 ;; *) rank_b=2 ;; esac
    if (( rank_b > rank_a )); then printf '%s' "$2"; else printf '%s' "$1"; fi
}

_audit_track() {
    local label=$1 state=$2 detail=$3 now prev dur
    now=$(now_ms)
    prev=${_PREV_STATE[$label]:-}
    if [[ -n $prev && $prev != "$state" ]]; then
        _AUDIT_EVENTS+=("$label $prev -> $state ($detail)")
    fi
    if [[ $state == FAIL ]]; then
        _FAIL_TICKS[$label]=$(( ${_FAIL_TICKS[$label]:-0} + 1 ))
        [[ -z ${_FAIL_SINCE[$label]:-} ]] && _FAIL_SINCE[$label]=$now
    elif [[ -n ${_FAIL_SINCE[$label]:-} ]]; then
        dur=$(( now - _FAIL_SINCE[$label] ))
        _FAIL_TOTAL[$label]=$(( ${_FAIL_TOTAL[$label]:-0} + dur ))
        (( dur > ${_FAIL_MAX[$label]:-0} )) && _FAIL_MAX[$label]=$dur
        _AUDIT_EVENTS+=("$label recovered after $(fmt_ms "$dur")")
        unset "_FAIL_SINCE[$label]"
    fi
    _PREV_STATE[$label]=$state
}

_audit_marks() {
    local total line
    [[ -f $LAB_MARK_FILE ]] || return 0
    total=$(wc -l < "$LAB_MARK_FILE")
    while (( _MARKS_SEEN < total )); do
        _MARKS_SEEN=$(( _MARKS_SEEN + 1 ))
        line=$(sed -n "${_MARKS_SEEN}p" "$LAB_MARK_FILE")
        if [[ ${line%%|*} =~ ^[0-9]+$ ]]; then
            line="$(ms_to_hms "${line%%|*}") ${line#*|}"
        fi
        _audit_emit "[MARK]  $line" "${C_MARK}[MARK]  $line${C_OFF}"
    done
}

_audit_tick() {
    local i label worst=OK plain='' colored='' ts event
    ts=$(now_hms)
    _TICK_CACHE=()
    _AUDIT_EVENTS=()
    for i in "${!AUDIT_LABELS[@]}"; do
        label=${AUDIT_LABELS[i]}
        P_STATE=FAIL P_DETAIL='probe error'
        eval "${AUDIT_CMDS[i]}"
        worst=$(_audit_worse "$worst" "$P_STATE")
        plain+="  $label=$P_DETAIL"
        colored+="  $(_audit_color "$P_STATE")$label=$P_DETAIL$C_OFF"
        _audit_track "$label" "$P_STATE" "$P_DETAIL"
    done
    if (( ! AUDIT_CHANGES_ONLY || ${#_AUDIT_EVENTS[@]} || $1 == 1 )); then
        _audit_emit "$ts [$(printf '%-4s' "$worst")]$plain" \
                    "$C_DIM$ts$C_OFF $(_audit_color "$worst")[$(printf '%-4s' "$worst")]$C_OFF$colored"
    fi
    for event in "${_AUDIT_EVENTS[@]}"; do
        _audit_emit "[EVENT] $ts $event" "${C_BOLD}[EVENT]${C_OFF} $ts $event"
    done
}

_audit_summary() {
    local label now ticks max total
    now=$(now_ms)
    printf '\n'
    _audit_emit "[INFO] summary after $_AUDIT_TICKS ticks, log $AUDIT_LOG" \
                "${C_INFO}[INFO]${C_OFF} summary after $_AUDIT_TICKS ticks, log $AUDIT_LOG"
    _audit_emit "$(printf '  %-22s %10s %16s %14s' check fail_ticks longest_outage total_outage)" \
                "$(printf '  %-22s %10s %16s %14s' check fail_ticks longest_outage total_outage)"
    for label in "${AUDIT_LABELS[@]}"; do
        ticks=${_FAIL_TICKS[$label]:-0}
        max=${_FAIL_MAX[$label]:-0}
        total=${_FAIL_TOTAL[$label]:-0}
        if [[ -n ${_FAIL_SINCE[$label]:-} ]]; then
            (( now - _FAIL_SINCE[$label] > max )) && max=$(( now - _FAIL_SINCE[$label] ))
            total=$(( total + now - _FAIL_SINCE[$label] ))
            label+='*'
        fi
        _audit_emit "$(printf '  %-22s %10s %16s %14s' "$label" "$ticks" "$(fmt_ms "$max")" "$(fmt_ms "$total")")" \
                    "$(printf '  %-22s %10s %16s %14s' "$label" "$ticks" "$(fmt_ms "$max")" "$(fmt_ms "$total")")"
    done
    _audit_emit "  * still failing when the audit stopped" "  * still failing when the audit stopped"
}

_AUDIT_TICKS=0
audit_run() {
    local start elapsed rest
    : "${AUDIT_LOG:?audit_init must run before audit_run}"
    [[ -f $LAB_MARK_FILE ]] && _MARKS_SEEN=$(wc -l < "$LAB_MARK_FILE")
    _audit_emit "[INFO] scenario $SCENARIO_ID audit, interval ${AUDIT_INTERVAL}s, Ctrl-C to stop" \
                "${C_INFO}[INFO]${C_OFF} scenario $SCENARIO_ID audit, interval ${AUDIT_INTERVAL}s, Ctrl-C to stop"
    trap '_audit_summary; exit 0' INT TERM
    while :; do
        _AUDIT_TICKS=$(( _AUDIT_TICKS + 1 ))
        start=$(now_ms)
        _audit_marks
        _audit_tick "$_AUDIT_TICKS"
        if (( AUDIT_COUNT > 0 && _AUDIT_TICKS >= AUDIT_COUNT )); then
            break
        fi
        elapsed=$(( $(now_ms) - start ))
        rest=$(( AUDIT_INTERVAL_MS - elapsed ))
        (( rest > 0 )) && sleep "$(printf '%d.%03d' $(( rest / 1000 )) $(( rest % 1000 )))"
    done
    _audit_summary
}
