#!/usr/bin/env bash
# =============================================================================
# lib/alerts.sh -- private alerts: a heartbeat this host pushes to monitors the
# operator owns (an Uptime Kuma push monitor, a healthchecks.io check, a JSON
# webhook). Works on every network; the Telcoin Association is not involved and
# no port opens.
#
# Sourced at the end of lib/common.sh, so every script that sources the library
# gets the alerts_* functions. Function definitions and plain variables only; no
# top-level side effects (it is sourced under the inherited `set -euo pipefail`).
# setup-alerts.sh drives it, check-node.sh calls alerts_status, remove-node.sh
# removes the same files without it.
#
# What an enable installs, every file root-owned and written through the
# primitives of lib/common.sh:
#   /etc/telcoin/alerts/                       root 0755 (_tn_root_layout_dir)
#   /etc/telcoin/alerts/targets                root 0600: one "<kind> <url>" per line,
#                                              at most 5; the only secret
#   /etc/telcoin/alerts/alerts.env             root 0644: what the runner checks
#   /usr/local/libexec/telcoin/tn-heartbeat    root 0755: lib/tn-heartbeat.sh
#   /etc/systemd/system/telcoin-heartbeat.service   oneshot, DynamicUser=yes
#   /etc/systemd/system/telcoin-heartbeat.timer     WantedBy=timers.target
# and records ENABLE_ALERTS=true in .node-meta. Before each run the service's
# ExecStartPre= (as root) rewrites /run/telcoin/heartbeat-service, root 0644: the
# node service's state, which the runner reads (alerts_unit_text says why). The
# runner reads the targets file as its credential "targets" (LoadCredential=)
# and keeps its state in its StateDirectory=, /var/lib/private/telcoin-heartbeat,
# which belongs to the dynamic user: the one directory of this add-on that root
# does not own.
#
# A monitor URL carries the monitor's token. It never goes on a command line,
# into an environment, a log line, a message or .node-meta: a target is shown as
# kind@host only. The targets reach tn_write_root_file on a process substitution
# run in this shell, never a pipe or a here-string (bash before 5.1 keeps a
# here-string in a temporary file).
#
# Nothing here stops or restarts the node, so there is no committee guard and no
# epoch wait. The callers hold the update lock.
#
# Say convention: a function that reports takes an optional FN and calls
# `FN KIND MSG` (KIND step, log, ok, warn or error); without FN it prints with
# print_step, print_info, print_ok, print_warn and print_error.
#
# Paths are under ${TN_ROOT_PREFIX:-} so the fixture tests can point them at a
# private tree; the unit texts always name the real paths. bash 3.2 safe.
# =============================================================================

# Version (tracked by update-scripts.sh). Plain, not readonly, so re-sourcing
# common.sh cannot trip on a readonly redefinition.
ALERTS_VERSION="2.1.0"

__ALERTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# The runner's helpers (hb_target_normalize, hb_url_host, hb_header_number,
# hb_state_get). Sourcing it runs nothing: hb_main runs only when the file is
# executed. An older checkout without it still sources this file.
if [[ -f "${__ALERTS_DIR}/tn-heartbeat.sh" ]]; then
    # shellcheck source=lib/tn-heartbeat.sh
    source "${__ALERTS_DIR}/tn-heartbeat.sh"
fi

# The real paths (the unit texts use these; the path functions add the prefix).
ALERTS_ETC_DIR="/etc/telcoin/alerts"
ALERTS_RUNNER="/usr/local/libexec/telcoin/tn-heartbeat"
ALERTS_UNIT="telcoin-heartbeat.service"
ALERTS_TIMER="telcoin-heartbeat.timer"
ALERTS_STATE_DIR="/var/lib/private/telcoin-heartbeat"
ALERTS_STATE_LINK="/var/lib/telcoin-heartbeat"
# The node service's systemctl show, written as root by the unit's ExecStartPre=
# before each run and read by the runner (it cannot reach the system bus).
ALERTS_SVC_STATE="/run/telcoin/heartbeat-service"
ALERTS_MAX_TARGETS=5
ALERTS_DEFAULT_INTERVAL=60
ALERTS_DEFAULT_STALL=180
ALERTS_DEFAULT_INACTIVE=900
ALERTS_RESTART_GRACE=120
ALERTS_DEFAULT_HEALTH_PORT=43174
ALERTS_MONITOR_HINT="Pause or delete this node's monitor: a push monitor alerts on silence."

# Results the functions leave for their caller (setup-alerts.sh builds its JSON
# from them).
#   ALERTS_ERR          the reason of the last refusal, one phrase, never a URL
#   ALERTS_VALID        alerts_targets_validate's normalised lines (a secret)
#   ALERTS_LABEL_REQ    set by the caller: the label --label asks for ("" = the one
#                       alerts.env holds, else this host's name)
#   ALERTS_APPLIED      what alerts_enable did: enabled, targets-changed, refreshed,
#                       or "targets-changed refreshed" (both, in that order)
#   ALERTS_RESULTS      lines "n kind host ok|fail code [why]" of the last run
#   ALERTS_NODE_STATUS, ALERTS_NODE_REASON   up|down and the reason of that run
#   ALERTS_ST_*         alerts_status: ENABLED (true|pending|false; "" when
#                       .node-meta cannot be read), TIMER (active|inactive|absent),
#                       LAST_RUN, LAST_STATUS, LAST_REASON, RUNNER_VERSION ("" when
#                       unknown)
ALERTS_ERR=""
ALERTS_VALID=""
: "${ALERTS_LABEL_REQ:=}"
ALERTS_APPLIED=""
ALERTS_RESULTS=""
ALERTS_NODE_STATUS=""
ALERTS_NODE_REASON=""
ALERTS_ST_ENABLED="false"
ALERTS_ST_TIMER="absent"
ALERTS_ST_LAST_RUN=""
ALERTS_ST_LAST_STATUS=""
ALERTS_ST_LAST_REASON=""
ALERTS_ST_RUNNER_VERSION=""

# -----------------------------------------------------------------------------
# Paths and messages
# -----------------------------------------------------------------------------

alerts_etc_dir()      { printf '%s\n' "${TN_ROOT_PREFIX:-}${ALERTS_ETC_DIR}"; }
alerts_targets_file() { printf '%s\n' "${TN_ROOT_PREFIX:-}${ALERTS_ETC_DIR}/targets"; }
alerts_env_file()     { printf '%s\n' "${TN_ROOT_PREFIX:-}${ALERTS_ETC_DIR}/alerts.env"; }
alerts_runner_path()  { printf '%s\n' "${TN_ROOT_PREFIX:-}${ALERTS_RUNNER}"; }
alerts_unit_path()    { printf '%s\n' "${TN_ROOT_PREFIX:-}/etc/systemd/system/${ALERTS_UNIT}"; }
alerts_timer_path()   { printf '%s\n' "${TN_ROOT_PREFIX:-}/etc/systemd/system/${ALERTS_TIMER}"; }
alerts_state_file()   { printf '%s\n' "${TN_ROOT_PREFIX:-}${ALERTS_STATE_DIR}/state"; }

# _alerts_say KIND MSG [FN] -- report MSG through FN, or print it.
_alerts_say() {
    if [[ -n "${3:-}" ]] && declare -F "$3" >/dev/null 2>&1; then
        "$3" "$1" "$2" || true
        return 0
    fi
    case "$1" in
        step)  print_step "$2" ;;
        ok)    print_ok "$2" ;;
        warn)  print_warn "$2" ;;
        error) print_error "$2" ;;
        *)     print_info "$2" ;;
    esac
    return 0
}

# _alerts_is_root -- rc 0 when this runs as root.
_alerts_is_root() {
    [[ "$(id -u 2>/dev/null)" == "0" ]]
}

# _alerts_env_value KEY -- the value of the first KEY= line of alerts.env; empty
# when the file or the line is absent.
_alerts_env_value() {
    local f line
    f="$(alerts_env_file)"
    [[ -f "$f" && -r "$f" ]] || return 0
    line="$(grep -m1 -E "^${1}=" "$f" 2>/dev/null)" || line=""
    printf '%s\n' "${line#*=}"
}

# _alerts_file_version FILE -- the HEARTBEAT_VERSION a runner file assigns; empty
# when it cannot be read.
_alerts_file_version() {
    local v
    v="$(grep -m1 -E '^HEARTBEAT_VERSION=' "$1" 2>/dev/null)" || v=""
    v="${v#*=}"
    v="${v%%[[:space:]]*}"
    v="${v//\"/}"
    v="${v//\'/}"
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || v=""
    printf '%s\n' "$v"
}

# _alerts_owner_mode FILE -- "uid:gid mode" of FILE (stat), empty when unreadable.
_alerts_owner_mode() {
    stat -c '%u:%g %a' -- "$1" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Inputs: targets, timing, label, the local RPC
# -----------------------------------------------------------------------------

# alerts_targets_validate [ALLOW_HTTP] -- read "<kind> <url>" lines on stdin (a
# trailing CR dropped, blanks around the line and blank lines ignored), check and
# normalise each with hb_target_normalize (its HB_URL and HB_ERR), and print the
# normalised lines. Also
# leaves them in ALERTS_VALID, so a caller can run it in this shell with stdout to
# /dev/null and keep ALERTS_ERR. rc 1 and nothing printed on a bad line, more than
# ALERTS_MAX_TARGETS targets or none: ALERTS_ERR names the line number and the
# target as kind@host only ("line 2 (kuma@kuma.example.org): kuma: not an
# /api/push/<token> URL"). ALLOW_HTTP 1 accepts http:// to any host.
alerts_targets_validate() {
    local allow="${1:-0}" line kind url norm host who err n=0 count=0 out="" cr nl hre
    cr=$'\r'
    nl=$'\n'
    hre='^[][A-Za-z0-9.:_-]{1,253}$'
    ALERTS_VALID=""
    ALERTS_ERR=""
    if ! declare -F hb_target_normalize >/dev/null 2>&1; then
        ALERTS_ERR="lib/tn-heartbeat.sh is missing (run update-scripts.sh)"
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        line="${line%"$cr"}"
        line="${line#"${line%%[![:blank:]]*}"}"
        line="${line%"${line##*[![:blank:]]}"}"
        [[ -n "$line" ]] || continue
        kind="${line%%[[:blank:]]*}"
        if [[ "$kind" == "$line" ]]; then
            ALERTS_ERR="line ${n}: expected '<kind> <url>'"
            return 1
        fi
        url="${line#"$kind"}"
        url="${url#"${url%%[![:blank:]]*}"}"
        case "$kind" in
            kuma|healthchecks|webhook) ;;
            *)
                # The word is named only when it cannot be a URL or a token.
                if [[ "$kind" =~ ^[a-z]{1,16}$ ]]; then
                    ALERTS_ERR="line ${n}: unknown provider '${kind}' (kuma, healthchecks or webhook)"
                else
                    ALERTS_ERR="line ${n}: unknown provider (kuma, healthchecks or webhook)"
                fi
                return 1
                ;;
        esac
        count=$((count + 1))
        if [[ "$count" -gt "$ALERTS_MAX_TARGETS" ]]; then
            ALERTS_ERR="more than ${ALERTS_MAX_TARGETS} targets (at most ${ALERTS_MAX_TARGETS})"
            return 1
        fi
        host=""
        case "$url" in
            http://*|https://*) host="$(hb_url_host "$url" 2>/dev/null)" || host="" ;;
        esac
        [[ "$host" =~ $hre ]] || host=""
        who="$kind"
        [[ -z "$host" ]] || who="${kind}@${host}"
        # Called in this shell (not in a command substitution) so HB_ERR and HB_URL
        # survive; HB_ERR never holds the URL.
        HB_ERR=""
        HB_URL=""
        if ! hb_target_normalize "$kind" "$url" "$allow" >/dev/null 2>&1 || [[ -z "${HB_URL:-}" ]]; then
            err="${HB_ERR:-not a valid URL}"
            HB_URL=""
            ALERTS_ERR="line ${n} (${who}): ${err}"
            return 1
        fi
        norm="$HB_URL"
        HB_URL=""
        out="${out}${kind} ${norm}${nl}"
    done
    if [[ "$count" -eq 0 ]]; then
        ALERTS_ERR="no targets given"
        return 1
    fi
    ALERTS_VALID="$out"
    printf '%s' "$out"
    return 0
}

# _alerts_take_targets -- read the targets on stdin into ALERTS_VALID (normalised,
# http allowed: the caller checked --allow-http with alerts_targets_validate). A
# terminal or blank stdin leaves ALERTS_VALID empty (rc 0). rc 1 on a bad line
# (ALERTS_ERR).
_alerts_take_targets() {
    local raw=""
    ALERTS_VALID=""
    ALERTS_ERR=""
    if [[ ! -t 0 ]]; then
        raw="$(cat; printf x)" || raw="x"
        raw="${raw%x}"
    fi
    if [[ -z "${raw//[[:space:]]/}" ]]; then
        raw=""
        return 0
    fi
    alerts_targets_validate 1 >/dev/null < <(trap - ERR; printf '%s' "$raw") || { raw=""; return 1; }
    raw=""
    return 0
}

# _alerts_timing_ok INTERVAL STALL INACTIVE -- rc 0 when the three are whole
# seconds in range (interval 30-3600; stall from interval + 30 to 86400; inactive
# from stall to 86400). rc 1 with ALERTS_ERR otherwise.
_alerts_timing_ok() {
    local i="${1:-}" s="${2:-}" a="${3:-}"
    if [[ ! "$i" =~ ^[0-9]{1,5}$ ]] || (( 10#$i < 30 || 10#$i > 3600 )); then
        ALERTS_ERR="the interval must be a whole number of seconds from 30 to 3600"
        return 1
    fi
    if [[ ! "$s" =~ ^[0-9]{1,6}$ ]] || (( 10#$s < 10#$i + 30 || 10#$s > 86400 )); then
        ALERTS_ERR="--stall-after must be a whole number of seconds from $((10#$i + 30)) (the interval plus 30) to 86400"
        return 1
    fi
    if [[ ! "$a" =~ ^[0-9]{1,6}$ ]] || (( 10#$a < 10#$s || 10#$a > 86400 )); then
        ALERTS_ERR="--inactive-after must be a whole number of seconds from $((10#$s)) (the stall time) to 86400"
        return 1
    fi
    return 0
}

# _alerts_label [WANT] -- set ALERTS_LABEL_OUT to WANT when it is a valid label,
# else (no WANT) to this host's name filtered to letters, digits and . _ -, cut to
# 64 characters, or "node". rc 1 with ALERTS_ERR when WANT is not a valid label.
ALERTS_LABEL_OUT=""
_alerts_label() {
    local want="${1:-}" h
    ALERTS_LABEL_OUT=""
    if [[ -n "$want" ]]; then
        if [[ ! "$want" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
            ALERTS_ERR="the label must be 1 to 64 letters, digits, dots, underscores or dashes, starting with a letter or a digit"
            return 1
        fi
        ALERTS_LABEL_OUT="$want"
        return 0
    fi
    h="$(hostname 2>/dev/null)" || h=""
    [[ -n "$h" ]] || h="$(uname -n 2>/dev/null)" || h=""
    h="${h//[^A-Za-z0-9._-]/}"
    while [[ -n "$h" && "$h" != [A-Za-z0-9]* ]]; do
        h="${h#?}"
    done
    h="${h:0:64}"
    ALERTS_LABEL_OUT="${h:-node}"
    return 0
}

# _alerts_launch_file -- the node's launch file (tn_node_launch_target). rc 1 when
# there is none or it cannot be used.
_alerts_launch_file() {
    local target file
    target="$(tn_node_launch_target 2>/dev/null)" || return 1
    read -r _ _ file <<< "$target" || true
    [[ -n "$file" ]] || return 1
    printf '%s\n' "$file"
}

# alerts_rpc_url -- the node's local HTTP RPC as the runner reaches it,
# http://<addr>:<port>: --http.addr from the node command (absent or 0.0.0.0 ->
# 127.0.0.1, :: -> [::1], another address with a colon bracketed) and
# --http.port (absent -> the port of tn_local_rpc_url). rc 1 when the node command
# has no --http; rc 2 when the launch file cannot be read or the address is not
# one the runner accepts.
alerts_rpc_url() {
    local file addr port url rc re
    re='^http://[][A-Za-z0-9.:-]{1,80}$'
    file="$(_alerts_launch_file)" || return 2
    rc=0
    addr="$(tn_launch_flag_get "$file" --http.addr 2>/dev/null)" || rc=$?
    case "$rc" in
        0) ;;
        1) addr="" ;;
        2) return 1 ;;
        *) return 2 ;;
    esac
    rc=0
    port="$(tn_launch_flag_get "$file" --http.port 2>/dev/null)" || rc=$?
    case "$rc" in
        0)
            [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 2
            (( 10#$port >= 1 && 10#$port <= 65535 )) || return 2
            port="$((10#$port))"
            ;;
        1)
            url="$(tn_local_rpc_url 2>/dev/null)" || return 2
            port="${url##*:}"
            [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 2
            ;;
        2) return 1 ;;
        *) return 2 ;;
    esac
    case "$addr" in
        ""|0.0.0.0) addr="127.0.0.1" ;;
        "::"|"[::]") addr="[::1]" ;;
        \[*\]) ;;
        *:*) addr="[${addr}]" ;;
    esac
    url="http://${addr}:${port}"
    [[ "$url" =~ $re ]] || return 2
    printf '%s\n' "$url"
}

# _alerts_rpc_refusal RC -- the sentence for an alerts_rpc_url failure.
_alerts_rpc_refusal() {
    if [[ "${1:-}" == 1 ]]; then
        printf '%s\n' "The node command has no --http, so the runner cannot read the local RPC; add it with edit-config.sh and run this again. Nothing was changed."
    else
        printf '%s\n' "The node's launch file cannot be read, or its --http.addr is not a plain address, so the runner cannot find the local RPC. Nothing was changed."
    fi
}

# _alerts_health_port -- the port of --healthcheck on the node command (a value
# addr:port keeps the part after the last colon), else 43174.
_alerts_health_port() {
    local file v
    if file="$(_alerts_launch_file)" && v="$(tn_launch_flag_get "$file" --healthcheck 2>/dev/null)"; then
        v="${v##*:}"
        if [[ "$v" =~ ^[0-9]{1,5}$ ]] && (( 10#$v >= 1 && 10#$v <= 65535 )); then
            printf '%s\n' "$((10#$v))"
            return 0
        fi
    fi
    printf '%s\n' "$ALERTS_DEFAULT_HEALTH_PORT"
}

# -----------------------------------------------------------------------------
# Writers
# -----------------------------------------------------------------------------

# _alerts_dir_ready -- make /etc/telcoin/alerts root 0755. The writer's rc.
_alerts_dir_ready() {
    _tn_root_layout_dir "$(alerts_etc_dir)" root 0755
}

# alerts_write_targets -- write stdin (normalised "<kind> <url>" lines) to the
# targets file, root 0600. Feed it from a process substitution run in this
# shell: < <(trap - ERR; printf '%s' "$targets"). The writer's rc.
alerts_write_targets() {
    local rc=0
    _alerts_dir_ready || return $?
    tn_write_root_file "$(alerts_targets_file)" 0600 || rc=$?
    return "$rc"
}

# alerts_write_env INTERVAL STALL INACTIVE [LABEL] -- write alerts.env, root 0644:
# the node service, its local RPC, network and chain id, this host's label, the
# health port and the timing. rc 0; 1 refused (ALERTS_ERR says why; nothing
# written); 2 the write failed.
alerts_write_env() {
    local interval="${1:-}" stall="${2:-}" inactive="${3:-}" svc rpc net chain port text rc
    ALERTS_ERR=""
    _alerts_timing_ok "$interval" "$stall" "$inactive" || return 1
    _alerts_label "${4:-}" || return 1
    if ! svc="$(tn_resolve_service 2>/dev/null)" || [[ ! "$svc" =~ ^[A-Za-z0-9_.@-]{1,64}$ ]]; then
        ALERTS_ERR="no node service is installed on this host"
        return 1
    fi
    rc=0
    rpc="$(alerts_rpc_url)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        ALERTS_ERR="$(_alerts_rpc_refusal "$rc")"
        ALERTS_ERR="${ALERTS_ERR% Nothing was changed.}"
        return 1
    fi
    if ! net="$(addon_meta_get NETWORK "" 2>/dev/null)"; then
        ALERTS_ERR="NETWORK is set more than once in .node-meta"
        return 1
    fi
    if [[ ! "$net" =~ ^[a-z]{0,16}$ ]]; then
        ALERTS_ERR="NETWORK in .node-meta is not a network name"
        return 1
    fi
    case "$net" in
        testnet) chain="$TESTNET_CHAIN_ID" ;;
        mainnet) chain="$MAINNET_CHAIN_ID" ;;
        devnet)  chain="$DEVNET_CHAIN_ID" ;;
        *)       chain="" ;;
    esac
    port="$(_alerts_health_port)"
    text="# Written by setup-alerts.sh. Change it with setup-alerts.sh, not by hand.
ALERTS_SERVICE=${svc}
ALERTS_RPC_URL=${rpc}
ALERTS_NETWORK=${net}
ALERTS_CHAIN_ID=${chain}
ALERTS_LABEL=${ALERTS_LABEL_OUT}
ALERTS_HEALTH_PORT=${port}
ALERTS_INTERVAL=$((10#$interval))
ALERTS_STALL_AFTER=$((10#$stall))
ALERTS_INACTIVE_AFTER=$((10#$inactive))
ALERTS_RESTART_GRACE=${ALERTS_RESTART_GRACE}"
    rc=0
    _alerts_dir_ready || rc=$?
    if [[ $rc -ne 0 ]]; then
        ALERTS_ERR="$(alerts_etc_dir) could not be made"
        return "$rc"
    fi
    tn_write_root_file "$(alerts_env_file)" 0644 <<< "$text" || rc=$?
    [[ $rc -eq 0 ]] || ALERTS_ERR="$(alerts_env_file) could not be written"
    return "$rc"
}

# alerts_install_runner -- check lib/tn-heartbeat.sh with bash -n and install it
# as /usr/local/libexec/telcoin/tn-heartbeat, root 0755 (tn_install_root_binary).
# rc 0; 1 refused (ALERTS_ERR); 2 the install failed.
alerts_install_runner() {
    local src="${__ALERTS_DIR}/tn-heartbeat.sh" dest dir rc=0
    ALERTS_ERR=""
    if [[ ! -f "$src" || -L "$src" ]]; then
        ALERTS_ERR="lib/tn-heartbeat.sh is missing (run update-scripts.sh)"
        return 1
    fi
    if ! bash -n "$src" 2>/dev/null; then
        ALERTS_ERR="lib/tn-heartbeat.sh does not parse (bash -n); run update-scripts.sh"
        return 1
    fi
    dest="$(alerts_runner_path)"
    dir="${dest%/*}"
    if [[ ! -d "$dir" ]]; then
        _tn_root_layout_dir "$dir" root 0755 || rc=$?
    fi
    [[ $rc -eq 0 ]] && { tn_install_root_binary "$src" "$dest" || rc=$?; }
    [[ $rc -eq 0 ]] || ALERTS_ERR="${dest} could not be installed"
    return "$rc"
}

# alerts_unit_text RUNNER [DATA_DIR] -- print telcoin-heartbeat.service: a oneshot
# under a dynamic user that gets the targets as a credential, keeps its state in
# its own StateDirectory= and cannot see the node's data dir (DATA_DIR too when
# it is outside /var/lib/telcoin) or the BLS passphrase.
#
# A dynamic user cannot talk to the system bus (dbus-daemon drops a connection
# from a uid it cannot resolve), so the runner's own systemctl show fails. The
# ExecStartPre= line runs as root outside the sandbox ("+"; "-" lets the run go
# on when it fails): it removes the last answer, writes the node service's
# systemctl show to a .tmp file and renames it to ALERTS_SVC_STATE, root 0644
# in the root 0755 /run/telcoin (the update-lock dir), where the runner can read
# it and cannot write. The line is the only thing that runs as root, and it
# reads the service state and nothing else.
alerts_unit_text() {
    local runner="$1" dd="${2:-}" hidden
    hidden="-/var/lib/telcoin -/etc/telcoin/bls-passphrase.cred -/etc/telcoin/bls-passphrase"
    while [[ "$dd" == */ && "$dd" != / ]]; do
        dd="${dd%/}"
    done
    if [[ -n "$dd" && "$dd" != /var/lib/telcoin && "$dd" != /var/lib/telcoin/* ]]; then
        hidden="${hidden} -${dd}"
    fi
    printf '%s\n' \
        '[Unit]' \
        'Description=Telcoin node heartbeat (private alerts)' \
        'After=network-online.target' \
        'Wants=network-online.target' \
        '' \
        '[Service]' \
        'Type=oneshot' \
        "ExecStart=${runner}" \
        "ExecStartPre=-+/bin/sh -c 'umask 022; install -d -o root -g root -m 0755 /run/telcoin && rm -f ${ALERTS_SVC_STATE} ${ALERTS_SVC_STATE}.tmp && systemctl show --no-pager -p LoadState -p ActiveState -p SubState -p NRestarts -p ActiveEnterTimestampMonotonic -p StateChangeTimestampMonotonic \"\${ALERTS_SERVICE}.service\" > ${ALERTS_SVC_STATE}.tmp && mv -f ${ALERTS_SVC_STATE}.tmp ${ALERTS_SVC_STATE}'" \
        'DynamicUser=yes' \
        "EnvironmentFile=${ALERTS_ETC_DIR}/alerts.env" \
        "LoadCredential=targets:${ALERTS_ETC_DIR}/targets" \
        'UnsetEnvironment=TN_BLS_PASSPHRASE' \
        'StateDirectory=telcoin-heartbeat' \
        'StateDirectoryMode=0700' \
        'UMask=0077' \
        'TimeoutStartSec=150' \
        'SyslogIdentifier=tn-heartbeat' \
        'ProtectSystem=strict' \
        'ProtectHome=yes' \
        'PrivateTmp=yes' \
        'PrivateDevices=yes' \
        'NoNewPrivileges=yes' \
        'CapabilityBoundingSet=' \
        'ProtectProc=invisible' \
        "InaccessiblePaths=${hidden}" \
        'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6' \
        'ProtectKernelTunables=yes' \
        'ProtectKernelModules=yes' \
        'ProtectKernelLogs=yes' \
        'ProtectControlGroups=yes' \
        'ProtectClock=yes' \
        'ProtectHostname=yes' \
        'RestrictNamespaces=yes' \
        'RestrictRealtime=yes' \
        'LockPersonality=yes' \
        'MemoryDenyWriteExecute=yes' \
        'SystemCallArchitectures=native' \
        'SystemCallFilter=@system-service' \
        'MemoryMax=64M' \
        'CPUQuota=20%' \
        'TasksMax=32' \
        'LimitCORE=0'
}

# alerts_timer_text INTERVAL -- print telcoin-heartbeat.timer: two minutes after
# boot, then every INTERVAL seconds after the last run, within 5 seconds.
alerts_timer_text() {
    printf '%s\n' \
        '[Unit]' \
        'Description=Telcoin node heartbeat timer (private alerts)' \
        '' \
        '[Timer]' \
        'OnBootSec=120' \
        "OnUnitActiveSec=${1}" \
        'AccuracySec=5' \
        "Unit=${ALERTS_UNIT}" \
        '' \
        '[Install]' \
        'WantedBy=timers.target'
}

# alerts_write_units INTERVAL -- write both units, root 0644, the node's data dir
# (DATA_DIR in .node-meta) hidden from the runner, then systemctl daemon-reload.
# rc 0; 1 refused (ALERTS_ERR); 2 a write or the reload failed.
alerts_write_units() {
    local interval="${1:-}" dd text rc=0
    ALERTS_ERR=""
    if [[ ! "$interval" =~ ^[0-9]{1,5}$ ]] || (( 10#$interval < 30 || 10#$interval > 3600 )); then
        ALERTS_ERR="the interval must be a whole number of seconds from 30 to 3600"
        return 1
    fi
    if ! dd="$(addon_meta_get DATA_DIR "" 2>/dev/null)"; then
        ALERTS_ERR="DATA_DIR is set more than once in .node-meta"
        return 1
    fi
    # A unit file line cannot carry spaces, % or $ in a path; such a data dir stays
    # out of InaccessiblePaths= (its 0700 owner still keeps the dynamic user out).
    if [[ -n "$dd" ]] && { [[ ! "$dd" =~ ^/[A-Za-z0-9._/-]+$ ]] || [[ "/${dd}/" == */../* || "/${dd}/" == */./* ]]; }; then
        dd=""
    fi
    text="$(alerts_unit_text "$ALERTS_RUNNER" "$dd")"
    tn_write_root_file "$(alerts_unit_path)" 0644 <<< "$text" || rc=$?
    if [[ $rc -eq 0 ]]; then
        text="$(alerts_timer_text "$((10#$interval))")"
        tn_write_root_file "$(alerts_timer_path)" 0644 <<< "$text" || rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        ALERTS_ERR="the heartbeat units could not be written"
        return "$rc"
    fi
    if ! systemctl daemon-reload >/dev/null 2>&1; then
        ALERTS_ERR="systemctl daemon-reload failed"
        return 2
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Test, enable, change, refresh, disable
# -----------------------------------------------------------------------------

# _alerts_read_results STATE -- fill ALERTS_RESULTS, ALERTS_NODE_STATUS and
# ALERTS_NODE_REASON from the state file (hb_state_get), for the targets the
# targets file lists (all 5 slots when it cannot be read). Prints nothing.
_alerts_read_results() {
    local st="$1" max="$ALERTS_MAX_TARGETS" f n line kind res code a b why host nl
    nl=$'\n'
    ALERTS_RESULTS=""
    ALERTS_NODE_STATUS="$(hb_state_get "$st" last_status 2>/dev/null)" || ALERTS_NODE_STATUS=""
    ALERTS_NODE_REASON="$(hb_state_get "$st" last_reason 2>/dev/null)" || ALERTS_NODE_REASON=""
    f="$(alerts_targets_file)"
    if [[ -f "$f" && -r "$f" && ! -L "$f" ]]; then
        max="$(grep -c '' "$f" 2>/dev/null)" || max="$ALERTS_MAX_TARGETS"
        [[ "$max" =~ ^[0-9]+$ ]] || max="$ALERTS_MAX_TARGETS"
        [[ "$max" -le "$ALERTS_MAX_TARGETS" ]] || max="$ALERTS_MAX_TARGETS"
    fi
    n=1
    while [[ "$n" -le "$max" ]]; do
        line="$(hb_state_get "$st" "push_${n}" 2>/dev/null)" || line=""
        if [[ -n "$line" ]]; then
            kind="" res="" code="" a="" b=""
            read -r kind res code a b <<< "$line" || true
            if [[ -n "$b" ]]; then
                why="$a"
                host="$b"
            else
                why=""
                host="$a"
            fi
            ALERTS_RESULTS="${ALERTS_RESULTS:+${ALERTS_RESULTS}${nl}}${n} ${kind} ${host} ${res} ${code}${why:+ ${why}}"
        fi
        n=$((n + 1))
    done
    return 0
}

# _alerts_say_results FN -- one line per target of ALERTS_RESULTS, as kind@host;
# _ALERTS_OK_COUNT gets the number of targets that accepted the heartbeat.
_ALERTS_OK_COUNT=0
_alerts_say_results() {
    local fn="${1:-}" line n kind host res code why
    _ALERTS_OK_COUNT=0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        n="" kind="" host="" res="" code="" why=""
        read -r n kind host res code why <<< "$line" || true
        if [[ "$res" == "ok" ]]; then
            _ALERTS_OK_COUNT=$((_ALERTS_OK_COUNT + 1))
            _alerts_say ok "Target ${n} ${kind}@${host}: accepted (${code})" "$fn"
        else
            _alerts_say warn "Target ${n} ${kind}@${host}: failed (${code}${why:+ ${why}})" "$fn"
        fi
    done <<< "$ALERTS_RESULTS"
    return 0
}

# alerts_test [FN] -- run the heartbeat once now (systemctl start; it blocks until
# the oneshot ends) and read what it recorded. Fills ALERTS_RESULTS (lines
# "n kind host ok|fail code [why]"), ALERTS_NODE_STATUS (up|down) and
# ALERTS_NODE_REASON, and says one line per target as kind@host. rc 0 at least one
# target accepted; 1 every target failed; 2 no run was recorded (the hint names
# journalctl).
alerts_test() {
    local fn="${1:-}" t0 st lr
    ALERTS_RESULTS=""
    ALERTS_NODE_STATUS=""
    ALERTS_NODE_REASON=""
    _alerts_say step "Sending a test heartbeat" "$fn"
    st="$(alerts_state_file)"
    t0="$(date +%s)"
    systemctl start "$ALERTS_UNIT" >/dev/null 2>&1 || true
    lr="$(hb_state_get "$st" last_run 2>/dev/null)" || lr=""
    if [[ "$lr" =~ ^[0-9]{1,18}$ ]] && (( 10#$lr < t0 )); then
        # A run the timer had started before this one may have answered the start;
        # one more start makes a run of its own.
        systemctl start "$ALERTS_UNIT" >/dev/null 2>&1 || true
        lr="$(hb_state_get "$st" last_run 2>/dev/null)" || lr=""
    fi
    if [[ ! "$lr" =~ ^[0-9]{1,18}$ ]] || (( 10#$lr < t0 )); then
        _alerts_say warn "The heartbeat runner recorded no run just now; see what it said with: journalctl -u telcoin-heartbeat -n 20" "$fn"
        return 2
    fi
    _alerts_read_results "$st"
    _alerts_say_results "$fn"
    if [[ -n "$ALERTS_NODE_STATUS" ]]; then
        _alerts_say log "The node reads as ${ALERTS_NODE_STATUS}: ${ALERTS_NODE_REASON:-no reason recorded}" "$fn"
    fi
    if [[ "$_ALERTS_OK_COUNT" -gt 0 ]]; then
        return 0
    fi
    _alerts_say warn "No target accepted the heartbeat." "$fn"
    return 1
}

# _alerts_enable_undo FN PREV PRESENT -- remove what a fresh enable wrote
# (alerts_disable, quiet, without the monitor hint and without its .node-meta
# write; a targets file it could not delete is said), then leave ENABLE_ALERTS
# as the enable found it: PRESENT 1, the value PREV (setup-node records pending
# before it runs the enable, and a failed enable leaves it pending); PRESENT 0, no
# ENABLE_ALERTS line (meta_unset). .node-meta is rewritten only when it does not
# say that already, so a failed enable leaves the file as it was. An operator's
# own disable records false.
_alerts_enable_undo() {
    local meta f now rc prev="${2:-}" present="${3:-1}"
    alerts_disable "" no-hint keep-meta >/dev/null 2>&1 || true
    f="$(alerts_targets_file)"
    if [[ -e "$f" || -L "$f" ]]; then
        _alerts_say error "Could not delete ${f}, which holds the monitor URLs; remove it by hand (sudo shred -u ${f})." "${1:-}"
    fi
    meta="$(node_meta_path 2>/dev/null)" || meta=""
    [[ -n "$meta" ]] || return 0
    if [[ "$present" == 1 ]]; then
        rc=0
        now="$(meta_get ENABLE_ALERTS "$meta" 2>/dev/null)" || rc=$?
        if [[ $rc -ne 0 || "$now" != "$prev" ]]; then
            meta_set ENABLE_ALERTS "$prev" "$meta" >/dev/null 2>&1 || true
        fi
    else
        meta_unset ENABLE_ALERTS "$meta" >/dev/null 2>&1 || true
    fi
    return 0
}

# alerts_enable INTERVAL STALL INACTIVE [FN] -- turn private alerts on. The targets
# come in on stdin (alerts_targets_validate's lines, fed from a process
# substitution); no targets is allowed only when alerts are on already. Refused
# (rc 1, one sentence ending "Nothing was changed."): not root, no .node-meta, no
# node service, no --http on the node command, systemd older than
# TN_STDIN_MIN_SYSTEMD, ENABLE_ALERTS set more than once, a bad interval, label or
# target line. Otherwise it writes the targets, alerts.env, the runner and the
# units, sends a test heartbeat, and only when a target accepted it starts the
# timer and records ENABLE_ALERTS=true; when none did, everything it wrote is
# removed again and .node-meta is left as it was: ENABLE_ALERTS keeps the value it
# had, or stays absent (rc 1).
#
# On a node with alerts on, INTERVAL, STALL and INACTIVE are what the caller asked
# for: an empty one keeps the value alerts.env holds. New targets go through
# alerts_set_targets and then, when a value or ALERTS_LABEL_REQ was given, through
# alerts_refresh with them; no targets goes through alerts_refresh. The values are
# checked first, so a bad one changes nothing. rc 1 nothing changed (refused, or
# the previous targets put back); 2 a change went partway and stays (said).
#
# ALERTS_APPLIED says what was done: enabled, targets-changed, refreshed, or
# "targets-changed refreshed". The caller holds the update lock
# (addon_meta_write_begin). Never touches the node.
alerts_enable() {
    local interval="${1:-}" stall="${2:-}" inactive="${3:-}" fn="${4:-}" meta cur v rc present=1 asked
    ALERTS_ERR=""
    ALERTS_APPLIED=""
    if ! _alerts_is_root; then
        _alerts_say error "Private alerts are set up as root (sudo). Nothing was changed." "$fn"
        return 1
    fi
    meta="$(node_meta_path 2>/dev/null)" || meta=""
    if [[ -z "$meta" ]]; then
        _alerts_say error "There is no .node-meta on this host, so there is no node to watch. Nothing was changed." "$fn"
        return 1
    fi
    if ! tn_resolve_service >/dev/null 2>&1; then
        _alerts_say error "No node service is installed on this host (telcoin.service). Nothing was changed." "$fn"
        return 1
    fi
    rc=0
    alerts_rpc_url >/dev/null 2>&1 || rc=$?
    if [[ $rc -ne 0 ]]; then
        _alerts_say error "$(_alerts_rpc_refusal "$rc")" "$fn"
        return 1
    fi
    v="$(tn_systemd_version 2>/dev/null)" || v=""
    if [[ ! "$v" =~ ^[0-9]+$ ]] || (( v < ${TN_STDIN_MIN_SYSTEMD:-247} )); then
        _alerts_say error "Private alerts need systemd ${TN_STDIN_MIN_SYSTEMD:-247} or later (LoadCredential=); this host runs ${v:-a version that cannot be read}. Nothing was changed." "$fn"
        return 1
    fi
    # meta_get tells an absent key (rc 1) from one set more than once (rc 2), so a
    # rollback can leave a host that had no ENABLE_ALERTS line without one.
    rc=0
    cur="$(meta_get ENABLE_ALERTS "$meta" 2>/dev/null)" || rc=$?
    case "$rc" in
        0) ;;
        1)
            cur="false"
            present=0
            ;;
        *)
            _alerts_say error "ENABLE_ALERTS is set more than once in .node-meta; remove the extra lines and run this again. Nothing was changed." "$fn"
            return 1
            ;;
    esac
    if ! _alerts_label "${ALERTS_LABEL_REQ:-}"; then
        _alerts_say error "Refused: ${ALERTS_ERR}. Nothing was changed." "$fn"
        return 1
    fi
    if ! _alerts_take_targets; then
        _alerts_say error "Refused: ${ALERTS_ERR}. Nothing was changed." "$fn"
        return 1
    fi

    if [[ "$cur" == "true" && -f "$(alerts_timer_path)" ]]; then
        asked="${interval}${stall}${inactive}${ALERTS_LABEL_REQ:-}"
        if ! _alerts_refresh_values "$interval" "$stall" "$inactive"; then
            ALERTS_VALID=""
            _alerts_say error "Refused: ${ALERTS_ERR}. Nothing was changed." "$fn"
            return 1
        fi
        if [[ -z "$ALERTS_VALID" ]]; then
            rc=0
            alerts_refresh "$fn" "$interval" "$stall" "$inactive" || rc=$?
            [[ $rc -ne 0 ]] || ALERTS_APPLIED="refreshed"
            return "$rc"
        fi
        rc=0
        alerts_set_targets "$fn" < <(trap - ERR; printf '%s' "$ALERTS_VALID") || rc=$?
        ALERTS_VALID=""
        [[ $rc -eq 0 ]] || return "$rc"
        ALERTS_APPLIED="targets-changed"
        [[ -n "$asked" ]] || return 0
        rc=0
        alerts_refresh "$fn" "$interval" "$stall" "$inactive" || rc=$?
        if [[ $rc -ne 0 ]]; then
            _alerts_say error "The new targets are in place, but the new settings were not fully applied; run setup-alerts.sh --refresh with the same options again." "$fn"
            return 2
        fi
        ALERTS_APPLIED="targets-changed refreshed"
        return 0
    fi
    if ! _alerts_timing_ok "$interval" "$stall" "$inactive"; then
        ALERTS_VALID=""
        _alerts_say error "Refused: ${ALERTS_ERR}. Nothing was changed." "$fn"
        return 1
    fi
    if [[ -z "$ALERTS_VALID" ]]; then
        _alerts_say error "No targets were given: pass at least one '<kind> <url>' line. Nothing was changed." "$fn"
        return 1
    fi

    _alerts_say step "Enabling private alerts" "$fn"
    rc=0
    alerts_write_targets < <(trap - ERR; printf '%s' "$ALERTS_VALID") || rc=$?
    ALERTS_VALID=""
    if [[ $rc -ne 0 ]]; then
        ALERTS_ERR="the targets file could not be written"
    else
        alerts_write_env "$interval" "$stall" "$inactive" "${ALERTS_LABEL_REQ:-}" \
            && alerts_install_runner \
            && alerts_write_units "$interval" \
            || rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        _alerts_enable_undo "$fn" "$cur" "$present"
        _alerts_say error "Private alerts were not enabled: ${ALERTS_ERR:-a file could not be written}. The files written for them were removed." "$fn"
        return 1
    fi
    rc=0
    alerts_test "$fn" || rc=$?
    if [[ $rc -ne 0 ]]; then
        _alerts_enable_undo "$fn" "$cur" "$present"
        _alerts_say error "No target accepted the test heartbeat; private alerts were not enabled. Check the URLs and run this again." "$fn"
        return 1
    fi
    if ! systemctl enable --now "$ALERTS_TIMER" >/dev/null 2>&1; then
        _alerts_enable_undo "$fn" "$cur" "$present"
        _alerts_say error "The heartbeat timer did not start (systemctl enable --now ${ALERTS_TIMER}); private alerts were not enabled and the files written for them were removed." "$fn"
        return 1
    fi
    if ! meta_set ENABLE_ALERTS true "$meta" >/dev/null 2>&1; then
        _alerts_enable_undo "$fn" "$cur" "$present"
        _alerts_say error ".node-meta could not record ENABLE_ALERTS=true; private alerts were not enabled and the files written for them were removed." "$fn"
        return 1
    fi
    ALERTS_APPLIED="enabled"
    _alerts_say ok "Private alerts enabled: ${ALERTS_TIMER} sends a heartbeat every $((10#$interval)) s. The node was not restarted." "$fn"
    return 0
}

# alerts_set_targets [FN] -- replace the targets (stdin, as alerts_enable takes
# them) and send a test heartbeat. When no target accepts it, the previous
# targets file is put back byte for byte (rc 1). rc 2 when that put-back failed
# too (the new targets stay; the message says so). Refused (rc 1, nothing
# changed): a bad or empty target list, alerts not set up.
alerts_set_targets() {
    local fn="${1:-}" f old="" had=0 rc
    ALERTS_ERR=""
    if ! _alerts_take_targets; then
        _alerts_say error "Refused: ${ALERTS_ERR}. Nothing was changed." "$fn"
        return 1
    fi
    if [[ -z "$ALERTS_VALID" ]]; then
        _alerts_say error "No targets were given: pass at least one '<kind> <url>' line. Nothing was changed." "$fn"
        return 1
    fi
    if [[ ! -f "$(alerts_timer_path)" ]]; then
        ALERTS_VALID=""
        _alerts_say error "Private alerts are not set up on this host; enable them first. Nothing was changed." "$fn"
        return 1
    fi
    f="$(alerts_targets_file)"
    if [[ -f "$f" && ! -L "$f" ]]; then
        if ! old="$(cat -- "$f" && printf x)"; then
            old=""
            ALERTS_VALID=""
            _alerts_say error "The current targets file cannot be read. Nothing was changed." "$fn"
            return 1
        fi
        old="${old%x}"
        had=1
    fi
    _alerts_say step "Changing the private alerts targets" "$fn"
    rc=0
    alerts_write_targets < <(trap - ERR; printf '%s' "$ALERTS_VALID") || rc=$?
    ALERTS_VALID=""
    if [[ $rc -ne 0 ]]; then
        old=""
        _alerts_say error "The new targets file could not be written. Nothing was changed." "$fn"
        return 1
    fi
    rc=0
    alerts_test "$fn" || rc=$?
    if [[ $rc -eq 0 ]]; then
        old=""
        _alerts_say ok "Targets changed; the next heartbeats go to the new targets." "$fn"
        return 0
    fi
    rc=0
    if [[ $had -eq 1 ]]; then
        tn_write_root_file "$f" 0600 < <(trap - ERR; printf '%s' "$old") || rc=$?
    else
        _tn_shred "$f"
    fi
    old=""
    if [[ $rc -ne 0 ]]; then
        _alerts_say error "No target accepted the test heartbeat, and the previous targets could not be put back: ${f} holds the new ones. Run this again with working targets." "$fn"
        return 2
    fi
    _alerts_say error "No target accepted the test heartbeat; the previous targets were put back." "$fn"
    return 1
}

# _alerts_refresh_values [INTERVAL STALL INACTIVE] -- the timing a refresh writes:
# each value given (not empty) replaces the one alerts.env holds, the others keep
# it; when alerts.env holds no usable set, the defaults stand in for it
# (_ALERTS_STORED_BAD 1). Leaves _ALERTS_RI, _ALERTS_RS and _ALERTS_RA. rc 1 with
# ALERTS_ERR when the result is out of range or ALERTS_LABEL_REQ is not a label.
_ALERTS_RI=""
_ALERTS_RS=""
_ALERTS_RA=""
_ALERTS_STORED_BAD=0
_alerts_refresh_values() {
    local i s a
    _ALERTS_STORED_BAD=0
    i="$(_alerts_env_value ALERTS_INTERVAL)"
    s="$(_alerts_env_value ALERTS_STALL_AFTER)"
    a="$(_alerts_env_value ALERTS_INACTIVE_AFTER)"
    if ! _alerts_timing_ok "$i" "$s" "$a"; then
        _ALERTS_STORED_BAD=1
        i="$ALERTS_DEFAULT_INTERVAL"
        s="$ALERTS_DEFAULT_STALL"
        a="$ALERTS_DEFAULT_INACTIVE"
    fi
    ALERTS_ERR=""
    [[ -z "${1:-}" ]] || i="$1"
    [[ -z "${2:-}" ]] || s="$2"
    [[ -z "${3:-}" ]] || a="$3"
    _ALERTS_RI="$i"
    _ALERTS_RS="$s"
    _ALERTS_RA="$a"
    _alerts_timing_ok "$i" "$s" "$a" || return 1
    if [[ -n "${ALERTS_LABEL_REQ:-}" ]]; then
        _alerts_label "$ALERTS_LABEL_REQ" || return 1
    fi
    return 0
}

# alerts_refresh [FN] [INTERVAL STALL INACTIVE] -- after a script update, or to
# change the timing or the label of a node whose alerts are on: install the runner
# again, write alerts.env and the units, reload systemd and restart the timer.
# INTERVAL, STALL and INACTIVE, when given (not empty), replace the values
# alerts.env holds; an omitted or empty one keeps the stored value (the defaults
# when alerts.env holds none usable, with a warning). The label is
# ALERTS_LABEL_REQ when set, else the stored one. The values are checked before
# anything is written. Nothing to do (rc 0, said) when alerts are off and no timer
# is installed. rc 1 refused, nothing changed (said); 2 a step failed after a
# file may have been rewritten (said).
alerts_refresh() {
    local fn="${1:-}" cur interval stall inactive label
    ALERTS_ERR=""
    if ! cur="$(addon_meta_get ENABLE_ALERTS false 2>/dev/null)"; then
        _alerts_say error "ENABLE_ALERTS is set more than once in .node-meta; remove the extra lines and run this again. Nothing was changed." "$fn"
        return 1
    fi
    if [[ "$cur" != "true" && ! -f "$(alerts_timer_path)" ]]; then
        _alerts_say log "Private alerts are off; nothing to refresh." "$fn"
        return 0
    fi
    _alerts_say step "Refreshing private alerts (runner, settings, units)" "$fn"
    if ! _alerts_refresh_values "${2:-}" "${3:-}" "${4:-}"; then
        _alerts_say error "Refused: ${ALERTS_ERR}. Nothing was changed." "$fn"
        return 1
    fi
    interval="$_ALERTS_RI"
    stall="$_ALERTS_RS"
    inactive="$_ALERTS_RA"
    if [[ $_ALERTS_STORED_BAD -eq 1 && -f "$(alerts_env_file)" ]]; then
        if [[ -z "${2:-}${3:-}${4:-}" ]]; then
            _alerts_say warn "alerts.env holds no usable interval, stall and inactive times; using ${ALERTS_DEFAULT_INTERVAL}, ${ALERTS_DEFAULT_STALL} and ${ALERTS_DEFAULT_INACTIVE} s." "$fn"
        elif [[ -z "${2:-}" || -z "${3:-}" || -z "${4:-}" ]]; then
            _alerts_say warn "alerts.env holds no usable interval, stall and inactive times; the defaults (${ALERTS_DEFAULT_INTERVAL}, ${ALERTS_DEFAULT_STALL} and ${ALERTS_DEFAULT_INACTIVE} s) stand in for the ones not given." "$fn"
        fi
    fi
    label="${ALERTS_LABEL_REQ:-}"
    if [[ -z "$label" ]]; then
        label="$(_alerts_env_value ALERTS_LABEL)"
        [[ "$label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || label=""
    fi
    ALERTS_ERR=""
    if ! alerts_install_runner || ! alerts_write_env "$interval" "$stall" "$inactive" "$label" \
        || ! alerts_write_units "$interval"; then
        _alerts_say error "The refresh stopped: ${ALERTS_ERR:-a file could not be written}. Run it again once that is fixed." "$fn"
        return 2
    fi
    if [[ "$cur" == "true" ]]; then
        systemctl enable "$ALERTS_TIMER" >/dev/null 2>&1 || true
    fi
    if ! systemctl restart "$ALERTS_TIMER" >/dev/null 2>&1; then
        _alerts_say error "The heartbeat timer did not restart (systemctl restart ${ALERTS_TIMER}); check: systemctl status ${ALERTS_TIMER}" "$fn"
        return 2
    fi
    _alerts_say ok "Private alerts refreshed: runner $(_alerts_file_version "$(alerts_runner_path)"), every $((10#$interval)) s. The node was not restarted." "$fn"
    return 0
}

# alerts_disable [FN] [no-hint] [keep-meta] -- remove private alerts: stop and
# disable the timer, stop the service, remove its state (systemctl clean, or rm
# when the directory is still there), shred the targets file and any .tn.* temp
# copy an interrupted write left beside it, remove alerts.env, its directory,
# the service-state file in /run/telcoin (never the directory), both units and
# the runner, reload systemd and record ENABLE_ALERTS=false (a
# failure is a warning). Then the monitor hint. The words after FN, in either
# order: no-hint leaves the hint out; keep-meta leaves .node-meta alone (the
# rollback of a failed enable puts ENABLE_ALERTS back itself). rc 1 when the
# targets file is still there.
alerts_disable() {
    local fn="${1:-}" hint=1 keepmeta=0 a f sd sl meta
    for a in "${2:-}" "${3:-}"; do
        case "$a" in
            no-hint)   hint=0 ;;
            keep-meta) keepmeta=1 ;;
        esac
    done
    _alerts_say step "Disabling private alerts" "$fn"
    systemctl disable --now "$ALERTS_TIMER" >/dev/null 2>&1 || true
    systemctl stop "$ALERTS_UNIT" >/dev/null 2>&1 || true
    sd="${TN_ROOT_PREFIX:-}${ALERTS_STATE_DIR}"
    sl="${TN_ROOT_PREFIX:-}${ALERTS_STATE_LINK}"
    systemctl clean --what=state "$ALERTS_UNIT" >/dev/null 2>&1 || true
    if [[ -e "$sd" || -L "$sd" ]]; then
        rm -rf -- "$sd" 2>/dev/null || true
        rm -f -- "$sl" 2>/dev/null || true
    elif [[ -L "$sl" ]]; then
        rm -f -- "$sl" 2>/dev/null || true
    fi
    f="$(alerts_targets_file)"
    _tn_shred "$f"
    # A temp copy a writer left when it was stopped mid-write holds the URLs too.
    _tn_shred "$(alerts_etc_dir)"/.tn.*
    rm -f -- "$(alerts_env_file)" 2>/dev/null || true
    # The service state the unit's ExecStartPre= wrote; /run/telcoin stays (the
    # update lock lives there).
    rm -f -- "${TN_ROOT_PREFIX:-}${ALERTS_SVC_STATE}" "${TN_ROOT_PREFIX:-}${ALERTS_SVC_STATE}.tmp" 2>/dev/null || true
    rmdir -- "$(alerts_etc_dir)" 2>/dev/null || true
    rm -f -- "$(alerts_unit_path)" "$(alerts_timer_path)" "$(alerts_runner_path)" 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed "$ALERTS_UNIT" >/dev/null 2>&1 || true
    if [[ $keepmeta -eq 0 ]]; then
        meta="$(node_meta_path 2>/dev/null)" || meta=""
        if [[ -n "$meta" ]] && ! meta_set ENABLE_ALERTS false "$meta" >/dev/null 2>&1; then
            _alerts_say warn ".node-meta could not record ENABLE_ALERTS=false; the heartbeat is removed all the same." "$fn"
        fi
    fi
    if [[ -e "$f" || -L "$f" ]]; then
        _alerts_say error "Could not delete ${f}, which holds the monitor URLs; remove it by hand (sudo shred -u ${f})." "$fn"
        return 1
    fi
    _alerts_say ok "Private alerts disabled: the heartbeat timer, its service, the runner and its files are removed. The node was not restarted." "$fn"
    if [[ $hint -eq 1 ]]; then
        _alerts_say log "$ALERTS_MONITOR_HINT" "$fn"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Status
# -----------------------------------------------------------------------------

# _alerts_timer_next -- the NEXT column of systemctl list-timers for the timer
# ("Wed 2026-11-04 12:00:00 UTC"), or "unknown".
_alerts_timer_next() {
    local out line nl
    nl=$'\n'
    out="$(systemctl list-timers --all --no-legend "$ALERTS_TIMER" 2>/dev/null)" || out=""
    line="${out%%"$nl"*}"
    line="$(printf '%s\n' "$line" | awk '$1 ~ /^[A-Z][a-z][a-z]$/ && NF >= 4 { print $1, $2, $3, $4; exit }')" || line=""
    printf '%s\n' "${line:-unknown}"
}

# alerts_status [FN] -- say how private alerts stand. A host where ENABLE_ALERTS is
# false or absent (or .node-meta cannot be read) and no timer unit is installed
# gets the one line "Private alerts: off (enable them with setup-alerts.sh)" (rc
# 0). Otherwise: on, pending or off (.node-meta; "unknown (run with sudo)" when it
# cannot be read, and then the alerts count as on when the timer is enabled,
# systemctl is-enabled), the timer, and, as root, the last run (its age, up or down, the
# reason) and each target of it as kind@host; the owner and mode of the targets
# file; the installed runner's version against this checkout's; alerts.env
# against the node (service name, local RPC). Fills the ALERTS_ST_* variables and
# ALERTS_RESULTS. Returns the number of issues, at most 20: alerts on but the
# timer inactive or missing, the last run older than 3 x the interval + 30 s or
# none, every push of it failed or none recorded, the targets file missing or
# not root:root 0600, ENABLE_ALERTS set more than once, the runner missing or of
# another version, alerts.env out of step with the node.
alerts_status() {
    local fn="${1:-}" issues=0 en on=0 timer_f st lr now age interval nst nreason f om iv cv es svc ru cu rc meta
    ALERTS_ST_ENABLED="false"
    ALERTS_ST_TIMER="absent"
    ALERTS_ST_LAST_RUN=""
    ALERTS_ST_LAST_STATUS=""
    ALERTS_ST_LAST_REASON=""
    ALERTS_ST_RUNNER_VERSION=""
    ALERTS_RESULTS=""
    timer_f="$(alerts_timer_path)"

    # .node-meta is root 0600: without root it exists but cannot be read, and its
    # ENABLE_ALERTS is unknown rather than absent.
    meta="$(node_meta_path 2>/dev/null)" || meta=""
    if [[ -n "$meta" && -e "$meta" && ! -r "$meta" ]]; then
        en="unreadable"
        ALERTS_ST_ENABLED=""
    elif ! en="$(addon_meta_get ENABLE_ALERTS false 2>/dev/null)"; then
        en="unknown"
    fi
    if [[ "$en" != "true" && "$en" != "pending" && "$en" != "unknown" && ! -f "$timer_f" ]]; then
        # A host without private alerts gets one line (check-node calls this on every report).
        _alerts_say log "Private alerts: off (enable them with setup-alerts.sh)" "$fn"
        return 0
    fi
    _alerts_say step "Private alerts (heartbeat to your own monitor)" "$fn"
    if [[ "$en" == "unknown" ]]; then
        issues=$((issues + 1))
        _alerts_say warn "ENABLE_ALERTS is set more than once in .node-meta; keep one line." "$fn"
    fi
    case "$en" in
        true)    ALERTS_ST_ENABLED="true"; on=1; _alerts_say log "Private alerts: on" "$fn" ;;
        pending)
            ALERTS_ST_ENABLED="pending"
            _alerts_say log "Private alerts: pending" "$fn"
            _alerts_say log "Finish the setup with: sudo bash setup-alerts.sh" "$fn"
            ;;
        unreadable)
            # The timer's enablement stands in for ENABLE_ALERTS.
            _alerts_say log "Private alerts: unknown (run with sudo)" "$fn"
            if systemctl is-enabled --quiet "$ALERTS_TIMER" >/dev/null 2>&1; then
                on=1
            fi
            ;;
        *)       _alerts_say log "Private alerts: off" "$fn" ;;
    esac

    if [[ ! -f "$timer_f" ]]; then
        _alerts_say log "timer not installed" "$fn"
        if [[ $on -eq 1 ]]; then
            issues=$((issues + 1))
            _alerts_say warn "Private alerts are on, but ${ALERTS_TIMER} is not installed; put it back with: sudo bash setup-alerts.sh --refresh" "$fn"
        fi
    elif systemctl is-active --quiet "$ALERTS_TIMER" 2>/dev/null; then
        ALERTS_ST_TIMER="active"
        _alerts_say ok "timer active, next run $(_alerts_timer_next)" "$fn"
    else
        ALERTS_ST_TIMER="inactive"
        _alerts_say log "timer inactive" "$fn"
        if [[ $on -eq 1 ]]; then
            issues=$((issues + 1))
            _alerts_say warn "Private alerts are on, but ${ALERTS_TIMER} is not running; start it with: sudo bash setup-alerts.sh --refresh" "$fn"
        fi
    fi

    if [[ $on -eq 0 && ! -f "$timer_f" ]]; then
        [[ "$issues" -le 20 ]] || issues=20
        return "$issues"
    fi

    # The last run (the state dir belongs to the dynamic user: root only).
    if _alerts_is_root; then
        st="$(alerts_state_file)"
        lr="$(hb_state_get "$st" last_run 2>/dev/null)" || lr=""
        if [[ ! "$lr" =~ ^[0-9]{1,18}$ ]]; then
            _alerts_say log "no heartbeat run recorded" "$fn"
            if [[ $on -eq 1 ]]; then
                issues=$((issues + 1))
                _alerts_say warn "No heartbeat run is recorded; see what the runner said with: journalctl -u telcoin-heartbeat -n 20" "$fn"
            fi
        else
            ALERTS_ST_LAST_RUN="$((10#$lr))"
            _alerts_read_results "$st"
            nst="$ALERTS_NODE_STATUS"
            nreason="$ALERTS_NODE_REASON"
            ALERTS_ST_LAST_STATUS="$nst"
            ALERTS_ST_LAST_REASON="$nreason"
            now="$(date +%s)"
            age=$((now - 10#$lr))
            (( age >= 0 )) || age=0
            _alerts_say log "last run ${age}s ago: ${nst:-unknown}${nreason:+, ${nreason}}" "$fn"
            interval="$(_alerts_env_value ALERTS_INTERVAL)"
            [[ "$interval" =~ ^[0-9]{1,5}$ ]] || interval="$ALERTS_DEFAULT_INTERVAL"
            if [[ $on -eq 1 ]] && (( age > 3 * 10#$interval + 30 )); then
                issues=$((issues + 1))
                _alerts_say warn "The last heartbeat run was ${age}s ago, more than 3 x the ${interval} s interval; check: journalctl -u telcoin-heartbeat -n 20" "$fn"
            fi
            local line n kind host res code why okc=0 tot=0
            while IFS= read -r line; do
                [[ -n "$line" ]] || continue
                n="" kind="" host="" res="" code="" why=""
                read -r n kind host res code why <<< "$line" || true
                tot=$((tot + 1))
                [[ "$res" != "ok" ]] || okc=$((okc + 1))
                _alerts_say log "target ${n} ${kind}@${host} ${res} ${code}${why:+ ${why}}" "$fn"
            done <<< "$ALERTS_RESULTS"
            if [[ $on -eq 1 && $tot -eq 0 ]]; then
                issues=$((issues + 1))
                _alerts_say warn "The last run recorded no target; check the targets with: sudo bash setup-alerts.sh" "$fn"
            elif [[ $on -eq 1 && $okc -eq 0 ]]; then
                issues=$((issues + 1))
                _alerts_say warn "Every push of the last run failed, so your monitor hears nothing; check the targets and the network with: sudo bash setup-alerts.sh --test" "$fn"
            fi
        fi
    else
        _alerts_say log "last run not checked (run with sudo)" "$fn"
    fi

    # The targets file: root:root 0600.
    f="$(alerts_targets_file)"
    if [[ -L "$f" || ( -e "$f" && ! -f "$f" ) ]]; then
        issues=$((issues + 1))
        _alerts_say warn "${f} is not a regular file; disable and enable private alerts again." "$fn"
    elif [[ -f "$f" ]]; then
        om="$(_alerts_owner_mode "$f")"
        if [[ "$om" != "0:0 600" ]]; then
            issues=$((issues + 1))
            _alerts_say warn "${f} must be root:root 0600 (it is ${om:-unreadable}); fix it with: sudo chown root:root ${f} && sudo chmod 0600 ${f}" "$fn"
        fi
    elif [[ $on -eq 1 ]]; then
        issues=$((issues + 1))
        _alerts_say warn "Private alerts are on, but ${f} is missing; set the targets again with: sudo bash setup-alerts.sh" "$fn"
    fi

    # The runner: installed and of this checkout's version.
    iv=""
    if [[ -f "$(alerts_runner_path)" ]]; then
        iv="$(_alerts_file_version "$(alerts_runner_path)")"
    fi
    cv="$(_alerts_file_version "${__ALERTS_DIR}/tn-heartbeat.sh")"
    ALERTS_ST_RUNNER_VERSION="$iv"
    if [[ ! -f "$(alerts_runner_path)" ]]; then
        issues=$((issues + 1))
        _alerts_say warn "The heartbeat runner ${ALERTS_RUNNER} is missing; run: sudo bash setup-alerts.sh --refresh" "$fn"
    elif [[ -n "$cv" && "$iv" != "$cv" ]]; then
        issues=$((issues + 1))
        _alerts_say warn "The installed heartbeat runner is ${iv:-of an unknown version}, these scripts carry ${cv}; run: sudo bash setup-alerts.sh --refresh" "$fn"
    else
        _alerts_say log "runner ${iv:-unknown}" "$fn"
    fi

    # alerts.env against the node (its install method and RPC port come from
    # .node-meta, so not without it).
    if [[ -f "$(alerts_env_file)" && "$en" == "unreadable" ]]; then
        _alerts_say log "alerts.env not compared with the node (run with sudo)" "$fn"
    elif [[ -f "$(alerts_env_file)" ]]; then
        es="$(_alerts_env_value ALERTS_SERVICE)"
        svc="$(tn_resolve_service 2>/dev/null)" || svc=""
        if [[ "$es" != "$svc" ]]; then
            issues=$((issues + 1))
            _alerts_say warn "alerts.env watches ${es:-no service}, but the node service is ${svc:-not installed}; run: sudo bash setup-alerts.sh --refresh" "$fn"
        fi
        ru="$(_alerts_env_value ALERTS_RPC_URL)"
        rc=0
        cu="$(alerts_rpc_url 2>/dev/null)" || rc=$?
        if [[ $rc -ne 0 ]]; then
            issues=$((issues + 1))
            _alerts_say warn "The runner reads the RPC at ${ru:-no address}, but the node's local RPC address cannot be read now; check the node command's --http flags." "$fn"
        elif [[ "$ru" != "$cu" ]]; then
            issues=$((issues + 1))
            _alerts_say warn "The runner reads the RPC at ${ru:-no address}, but the node serves it at ${cu}; run: sudo bash setup-alerts.sh --refresh" "$fn"
        fi
    elif [[ $on -eq 1 ]]; then
        issues=$((issues + 1))
        _alerts_say warn "Private alerts are on, but $(alerts_env_file) is missing; run: sudo bash setup-alerts.sh --refresh" "$fn"
    fi

    [[ "$issues" -le 20 ]] || issues=20
    return "$issues"
}

: # alerts.sh sources with status 0
