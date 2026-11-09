#!/usr/bin/env bash
# =============================================================================
# setup-alerts.sh -- private alerts: a heartbeat from this host to monitors you own
#
# Optional, on every network, reversible. A systemd timer on this host checks the
# node once a minute (or at the interval you choose) and pushes up or down, with
# a short reason, to monitors you own: an Uptime Kuma push monitor, a
# healthchecks.io check or a JSON webhook. Each heartbeat says up or down with the
# reason (node mode, block and epoch); a webhook also gets this host's label and
# the network. Nothing else is sent, no port opens, the Telcoin Association is
# not involved, and the node is never stopped or restarted.
#
# A monitor URL holds the monitor's token. It is kept only in
# /etc/telcoin/alerts/targets (root 0600) and is shown only as kind@host.
#
# USAGE:
#   sudo bash setup-alerts.sh                     # menu
#   sudo bash setup-alerts.sh --enable            # asks for each URL, input hidden
#   printf 'kuma https://kuma.example.org/api/push/TOKEN\n' \
#     | sudo bash setup-alerts.sh --json --enable --targets-stdin [--interval 60]
#   bash setup-alerts.sh --json --status          # as root it shows the last run too
#   sudo bash setup-alerts.sh --json --test       # send a test heartbeat now
#   sudo bash setup-alerts.sh --json --refresh    # after update-scripts.sh changed the runner
#   sudo bash setup-alerts.sh --json --refresh --interval 120   # a new interval, alerts on
#   sudo bash setup-alerts.sh --json --disable    # remove the timer, runner, targets and state
#   Each action also runs without --json and then prints plain text.
#
# Targets: one "<kind> <url>" line each, kind kuma, healthchecks or webhook, at
# most 5, from exactly one of --targets-stdin, the TN_ALERT_TARGETS environment
# variable (the same lines) or repeated --target kind=url (that puts the URL on
# the command line, where other local users can read it, so it warns).
#
# Options of --enable: --interval N seconds, 30 to 3600 (default 60);
# --stall-after N (default the larger of 180 and 3 x the interval);
# --inactive-after N (default the larger of 900 and the stall time);
# --allow-http (http:// to a host other than 127.0.0.1, [::1] or localhost; also
# for the menu); --label NAME (the node name a webhook gets; default this host's
# name; also for the menu). --interval, --stall-after, --inactive-after and
# --label also go with --refresh. -h, --help: this text.
#
# On a node whose alerts are on, --enable and --refresh change only what the
# command line names: each of --interval, --stall-after, --inactive-after and
# --label replaces the stored value and the others stay, except that with
# --interval a threshold not given follows the new interval as above. The timer
# restarts with them; no disable is needed. --enable with targets changes the
# targets first (a new one must accept a test heartbeat), then applies the values.
#
# Exit status: 0 done; 1 refused, nothing changed; 2 the libraries are older than
# this script; 3 a step failed after something changed (the message says what is
# left).
# =============================================================================

# The targets may come in the environment: copy them and remove the variable
# before anything else runs, so no process this script starts inherits the URLs.
SA_ENV_TARGETS="${TN_ALERT_TARGETS-}"
unset TN_ALERT_TARGETS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

readonly SCRIPT_VERSION="2.1.0"

# The run's settings, from the command line (sa_parse_args, sa_pick_targets).
SA_ACTION=""            # status, enable, test, refresh, disable; empty: the menu
SA_TARGETS_STDIN=false
SA_ARGV_TARGETS=""      # --target values as "<kind> <url>" lines (a secret)
SA_TARGET_FLAG=""       # the first target flag given, for the combination check
SA_TIMING_FLAG=""       # the first of --interval, --stall-after, --inactive-after
# --interval, --stall-after and --inactive-after as given ("" = not given; the
# interval prompt sets SA_OPT_INTERVAL too). On a node whose alerts are on, only
# the given ones are applied (sa_timing_req).
SA_OPT_INTERVAL=""
SA_OPT_STALL=""
SA_OPT_INACTIVE=""
SA_ALLOW_HTTP=0
SA_RAW=""               # the target lines of this run (a secret)
SA_SRC=""               # where they came from: stdin, argv, env or the prompts
SA_I=""                 # interval, stall and inactive times (sa_timing)
SA_S=""
SA_A=""
SA_CUR="false"          # ENABLE_ALERTS from .node-meta (sa_read_cur)
SA_FAIL_MSG=""
SA_GAP_FNS=""
SA_GAP_LIBS=""
SA_GAP_N=0
# The label the library writes into alerts.env: only --label sets it.
ALERTS_LABEL_REQ=""

pause() { echo ""; read -r -p "  Press Enter to return to menu..." || true; }

# addons_say KIND MSG -- the say function the library reports through (KIND step,
# log, ok, warn or error): in --json mode a JSON event (step, warn and error keep
# their kind, the rest become log events), otherwise a print_* line.
addons_say() {
    if json_mode; then
        case "${1:-}" in
            step|warn|error) json_event "$1" "${2:-}" ;;
            *)               json_event log "${2:-}" ;;
        esac
    else
        case "${1:-}" in
            step)  print_step "${2:-}" ;;
            ok)    print_ok "${2:-}" ;;
            warn)  print_warn "${2:-}" ;;
            error) print_error "${2:-}" ;;
            *)     print_info "${2:-}" ;;
        esac
    fi
    return 0
}

# sa_baseline_refresh -- after a change went through (.node-meta, the files under
# /etc/telcoin/alerts, the runner): make the host baseline again
# (tn_host_baseline_refresh, a no-op without HOST_BASELINE=true in .node-meta or
# with a lib/common.sh that lacks it). Its lines go through addons_say. Never fails.
sa_baseline_refresh() {
    if declare -F tn_host_baseline_refresh >/dev/null 2>&1; then
        tn_host_baseline_refresh addons_say || true
    fi
    return 0
}

# =============================================================================
# JSON (--json): events on fd 3 (the original stdout), everything else on stderr
# =============================================================================

JSON_MODE=false
JSON_DONE_EMITTED=false
JSON_LAST_ERROR=""

json_mode() { [[ "$JSON_MODE" == "true" ]]; }

json_setup_fds() {
    exec 3>&1   # fd3 = original stdout: JSON is written here
    exec 1>&2   # stdout now aliases stderr: print_* and command output are noise
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/ }"; s="${s//$'\t'/ }"
    printf '%s' "$s"
}

json_emit() { printf '%s\n' "$1" >&3; }
json_event() {
    if [[ "$1" == "error" ]]; then
        JSON_LAST_ERROR="${2:-}"
    fi
    json_emit "{\"event\":\"${1}\",\"msg\":\"$(json_escape "${2:-}")\"}"
}
json_done() { JSON_DONE_EMITTED=true; json_emit "$1"; }

# json_on_exit -- the EXIT trap of a --json run: remove a root file write stopped
# before its rename (the temp copy of the targets file holds the URLs), release
# the update lock, and send done ok:false when no done event was sent, with the
# last error event's message when there was one.
json_on_exit() {
    local rc=$? msg
    tn_remove_inflight_tmp 2>/dev/null || true
    tn_release_update_lock 2>/dev/null || true
    [[ "$JSON_DONE_EMITTED" == "true" ]] && return
    msg="$JSON_LAST_ERROR"
    if [[ -z "$msg" ]]; then
        msg="setup-alerts.sh stopped early (rc=${rc}); see its messages on stderr"
    fi
    json_emit "{\"event\":\"done\",\"ok\":false,\"msg\":\"$(json_escape "$msg")\"}"
}

# json_fail MSG [RC] -- an error event, then exit RC (default 1); json_on_exit
# sends done ok:false with MSG.
json_fail() { json_event error "$1"; exit "${2:-1}"; }

# sa_jstr VALUE -- VALUE as a JSON string, or null when it is empty.
sa_jstr() {
    if [[ -n "${1:-}" ]]; then
        printf '"%s"' "$(json_escape "$1")"
    else
        printf 'null'
    fi
}

# sa_jnum VALUE -- VALUE as a JSON number (leading zeros dropped), or null when it
# is not a whole number.
sa_jnum() {
    if [[ "${1:-}" =~ ^[0-9]{1,18}$ ]]; then
        printf '%s' "$((10#$1))"
    else
        printf 'null'
    fi
}

# sa_jtargets -- ALERTS_RESULTS ("n kind host ok|fail code [why]" lines) as a JSON
# array of {"n","provider","host","result","code"} objects, plus "why" for a
# failed push. A target is only ever shown by its host.
sa_jtargets() {
    local out="" obj line n kind host res code why
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        n="" kind="" host="" res="" code="" why=""
        read -r n kind host res code why <<< "$line" || true
        [[ "$n" =~ ^[0-9]{1,2}$ ]] || continue
        obj="{\"n\":$((10#$n)),\"provider\":\"$(json_escape "$kind")\",\"host\":\"$(json_escape "$host")\",\"result\":\"$(json_escape "$res")\",\"code\":$(sa_jnum "$code")"
        if [[ -n "$why" ]]; then
            obj="${obj},\"why\":\"$(json_escape "$why")\""
        fi
        out="${out:+${out},}${obj}}"
    done <<< "${ALERTS_RESULTS:-}"
    printf '[%s]' "$out"
}

# sa_jresult_fields -- the node status, its reason and the targets of the last test
# heartbeat, as the tail of a done event.
sa_jresult_fields() {
    printf ',"node_status":%s,"node_reason":%s,"targets":%s' \
        "$(sa_jstr "${ALERTS_NODE_STATUS:-}")" "$(sa_jstr "${ALERTS_NODE_REASON:-}")" "$(sa_jtargets)"
}

# sa_finish APPLIED FIELDS MSG -- the end of a run that went through: in --json mode
# the done event (APPLIED the "applied" items, separated by spaces, or none when
# empty; FIELDS the extra fields, each with its leading comma), then exit 0.
sa_finish() {
    local applied="" w
    for w in ${1:-}; do
        applied="${applied:+${applied},}\"$(json_escape "$w")\""
    done
    if json_mode; then
        json_done "{\"event\":\"done\",\"ok\":true,\"applied\":[${applied}],\"network\":$(sa_jstr "${NETWORK:-}")${2:-},\"msg\":\"$(json_escape "${3:-}")\"}"
    fi
    exit 0
}

# sa_fail MSG [RC] -- refuse or stop with MSG: an error event in --json mode (then
# done ok:false), an [ERROR] line otherwise. Exits RC (default 1).
sa_fail() {
    if json_mode; then
        json_fail "$1" "${2:-1}"
    fi
    print_error "$1"
    exit "${2:-1}"
}

# sa_end_failed RC [MSG] -- the end of a run whose library step already said why it
# failed: in --json mode done ok:false with MSG, else the last error event's
# message; nothing more is printed otherwise. Exits RC.
sa_end_failed() {
    local msg="${2:-}"
    if json_mode; then
        [[ -n "$msg" ]] || msg="$JSON_LAST_ERROR"
        [[ -n "$msg" ]] || msg="setup-alerts.sh stopped (rc ${1}); see the events above"
        json_done "{\"event\":\"done\",\"ok\":false,\"msg\":\"$(json_escape "$msg")\"}"
    fi
    exit "$1"
}

# arg_fail MSG -- a bad command line: an error event in --json mode (json_on_exit
# then sends done ok:false), otherwise an [ERROR] line. Exits 1.
arg_fail() {
    sa_fail "$1" 1
}

# =============================================================================
# Library check, traps, usage
# =============================================================================

# _sa_lib_gap LIB FN... -- add each FN that is not defined to SA_GAP_FNS, and LIB
# to SA_GAP_LIBS when one of them is missing.
_sa_lib_gap() {
    local lib="$1" fn hit=0
    shift
    for fn in "$@"; do
        if ! declare -F "$fn" >/dev/null 2>&1; then
            SA_GAP_FNS="${SA_GAP_FNS:+${SA_GAP_FNS}, }${fn}"
            hit=1
        fi
    done
    if [[ $hit -eq 1 ]]; then
        SA_GAP_N=$((SA_GAP_N + 1))
        case "$SA_GAP_N" in
            1) SA_GAP_LIBS="$lib" ;;
            *) SA_GAP_LIBS="${SA_GAP_LIBS}|${lib}" ;;
        esac
    fi
    return 0
}

# alerts_require_lib -- exit 2 before anything else when lib/common.sh,
# lib/alerts.sh or lib/tn-heartbeat.sh lacks a helper this script calls (scripts
# updated without the libraries). One message names update-scripts.sh; a --json
# run also gets it as its done event.
alerts_require_lib() {
    local what msg a b c
    _sa_lib_gap lib/common.sh addon_meta_get addon_meta_lock addon_meta_write_begin meta_get meta_set meta_unset \
        node_meta_path tn_write_root_file tn_install_root_binary tn_root_dir_ok _tn_root_layout_dir \
        _tn_shred tn_systemd_version tn_resolve_service tn_node_launch_target tn_launch_flag_get \
        tn_local_rpc_url tn_remove_inflight_tmp tn_release_update_lock
    _sa_lib_gap lib/alerts.sh alerts_targets_validate alerts_write_targets alerts_rpc_url \
        alerts_write_env alerts_install_runner alerts_unit_text alerts_timer_text alerts_write_units \
        alerts_test alerts_enable alerts_set_targets alerts_refresh alerts_disable alerts_status \
        alerts_env_file alerts_targets_file alerts_timer_path alerts_unit_path
    _sa_lib_gap lib/tn-heartbeat.sh hb_target_normalize hb_url_host hb_header_number hb_state_get
    [[ "$SA_GAP_N" -eq 0 ]] && return 0
    IFS='|' read -r a b c <<< "$SA_GAP_LIBS" || true
    case "$SA_GAP_N" in
        1) what="${a} is" ;;
        2) what="${a} and ${b} are" ;;
        *) what="${a}, ${b} and ${c} are" ;;
    esac
    msg="${what} older than this script (it lacks ${SA_GAP_FNS}): run update-scripts.sh, then this again. Nothing was changed."
    # All of it on stderr (print_error puts its blank lines on stdout): in --json
    # mode stdout carries the done event only.
    print_error "$msg" >&2
    if json_mode; then
        printf '{"event":"done","ok":false,"error":"%s","msg":"%s"}\n' "$(json_escape "$msg")" "$(json_escape "$msg")"
    fi
    exit 2
}

# sa_on_exit -- the EXIT trap of the menu and of the plain actions: remove a root
# file write stopped before its rename, then release the update lock, as
# json_on_exit does for --json.
sa_on_exit() {
    tn_remove_inflight_tmp 2>/dev/null || true
    tn_release_update_lock 2>/dev/null || true
}

# sa_signal_traps -- TERM, INT and HUP end the run through exit, so the EXIT trap
# runs: bash 3.2 skips the EXIT trap of a shell that a signal kills by default
# when its parent shell has one.
sa_signal_traps() {
    trap 'exit 143' TERM
    trap 'exit 130' INT
    trap 'exit 129' HUP
}

usage() {
    awk 'NR > 1 && /^# =+$/ { n++; if (n == 2) exit; next } NR > 1 && /^#/ { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

# =============================================================================
# Node context, root, lock
# =============================================================================

# sa_is_root -- rc 0 when this runs as root.
sa_is_root() {
    [[ "$(id -u 2>/dev/null)" == "0" ]]
}

# sa_need_root [WHAT] -- refuse (exit 1) unless this runs as root.
sa_need_root() {
    sa_is_root && return 0
    sa_fail "Run setup-alerts.sh${1:+ $1} as root (sudo). Nothing was changed."
}

# load_node_context -- NETWORK from .node-meta. Stops the run (exit 1) when there
# is no node on this host or NETWORK is set more than once. No network gate:
# private alerts work on every network.
load_node_context() {
    local meta v
    meta="$(node_meta_path 2>/dev/null)" || meta=""
    if [[ -z "$meta" ]]; then
        sa_fail "No Telcoin node was found on this host (no .node-meta under /etc/telcoin); run setup-node.sh first. Nothing was changed."
    fi
    if ! v="$(addon_meta_get NETWORK "" 2>/dev/null)"; then
        sa_fail "NETWORK is set more than once in .node-meta; remove the extra lines and run this again. Nothing was changed."
    fi
    NETWORK="$v"
}

# sa_read_cur -- SA_CUR: ENABLE_ALERTS from .node-meta (false when absent). rc 1
# when the key is set more than once (said).
sa_read_cur() {
    local v
    if ! v="$(addon_meta_get ENABLE_ALERTS false 2>/dev/null)"; then
        addons_say error "ENABLE_ALERTS is set more than once in .node-meta; remove the extra lines and run this again. Nothing was changed."
        return 1
    fi
    SA_CUR="${v:-false}"
}

# sa_alerts_on -- rc 0 when private alerts are on: ENABLE_ALERTS=true and the timer
# unit installed (the test alerts_enable makes before it changes targets instead).
sa_alerts_on() {
    [[ "$SA_CUR" == "true" && -f "$(alerts_timer_path)" ]]
}

# sa_alerts_present -- rc 0 when there is something to refresh: ENABLE_ALERTS=true
# or the timer unit installed.
sa_alerts_present() {
    [[ "$SA_CUR" == "true" || -f "$(alerts_timer_path)" ]]
}

# sa_lock_begin -- the update lock without the ownership migration (a status
# screen or a test heartbeat changes nothing of the install). Stops the run when
# another run holds it.
sa_lock_begin() {
    addon_meta_lock && return 0
    if json_mode; then
        json_fail "another node operation holds the update lock; run this again when it has finished. Nothing was changed."
    fi
    exit 1
}

# sa_write_begin -- before the first change: the update lock and, on a host set up
# by an older release, the ownership migration (addon_meta_write_begin). Stops the
# run when either refuses.
sa_write_begin() {
    addon_meta_write_begin && return 0
    if json_mode; then
        json_fail "the update lock or the ownership migration stopped this run (see its messages on stderr); nothing was changed"
    fi
    exit 1
}

# sa_env_interval -- the interval alerts.env holds, else SA_I.
sa_env_interval() {
    local line
    line="$(grep -m1 -E '^ALERTS_INTERVAL=[0-9]{1,5}$' "$(alerts_env_file)" 2>/dev/null)" || line=""
    if [[ -n "$line" ]]; then
        printf '%s\n' "${line#*=}"
    else
        printf '%s\n' "${SA_I:-}"
    fi
}

# =============================================================================
# Targets and timing
# =============================================================================

# sa_timing -- SA_I, SA_S and SA_A: the interval, stall and inactive times from
# --interval, --stall-after and --inactive-after (or the interval prompt). A
# missing one is derived: interval 60; stall the larger of 180 and 3 x the
# interval; inactive the larger of 900 and the stall time. alerts_enable checks
# the ranges.
sa_timing() {
    local i s a
    i="${SA_OPT_INTERVAL:-60}"
    i=$((10#$i))
    if [[ -n "$SA_OPT_STALL" ]]; then
        s=$((10#$SA_OPT_STALL))
    else
        s=$((3 * i))
        if (( s < 180 )); then
            s=180
        fi
    fi
    if [[ -n "$SA_OPT_INACTIVE" ]]; then
        a=$((10#$SA_OPT_INACTIVE))
    else
        a="$s"
        if (( a < 900 )); then
            a=900
        fi
    fi
    SA_I="$i"
    SA_S="$s"
    SA_A="$a"
}

# sa_timing_req -- SA_I, SA_S and SA_A for a node whose alerts are on: only what
# this run asked for. With --interval they are sa_timing's (a threshold not given
# follows the new interval); without it a value not given stays empty, and
# alerts_refresh keeps the one alerts.env holds.
sa_timing_req() {
    if [[ -n "$SA_OPT_INTERVAL" ]]; then
        sa_timing
        return 0
    fi
    SA_I=""
    SA_S=""
    SA_A=""
    if [[ -n "$SA_OPT_STALL" ]]; then
        SA_S="$((10#$SA_OPT_STALL))"
    fi
    if [[ -n "$SA_OPT_INACTIVE" ]]; then
        SA_A="$((10#$SA_OPT_INACTIVE))"
    fi
    return 0
}

# sa_check_targets RAW -- check and normalise the target lines in RAW
# (alerts_targets_validate; http:// to other hosts only with --allow-http). Runs
# in this shell, fed from a process substitution, so ALERTS_VALID keeps the
# normalised lines and ALERTS_ERR the reason, which names a target as kind@host
# only. rc 1 when a line is refused.
sa_check_targets() {
    alerts_targets_validate "$SA_ALLOW_HTTP" >/dev/null < <(trap - ERR; printf '%s' "$1")
}

# sa_read_targets_stdin -- --targets-stdin: every line of stdin into SA_RAW. Refused
# when stdin is a terminal (the URLs would show as they are typed) or empty.
sa_read_targets_stdin() {
    local raw
    if [[ -t 0 ]]; then
        arg_fail "--targets-stdin reads the targets from a pipe, not a terminal (the URLs would show as you type them). Nothing was changed."
    fi
    raw="$(cat; printf x)" || raw="x"
    raw="${raw%x}"
    if [[ -z "${raw//[[:space:]]/}" ]]; then
        raw=""
        arg_fail "--targets-stdin: no targets on stdin. Nothing was changed."
    fi
    SA_RAW="$raw"
    raw=""
}

# sa_explain -- what private alerts are, before the targets are asked for.
sa_explain() {
    print_info "A timer on this host pushes a heartbeat to monitors you own: an Uptime Kuma push URL, a healthchecks.io ping URL or a JSON webhook."
    print_info "Each heartbeat says up or down with the reason (node mode, block and epoch); a webhook also gets this host's label and the network. Nothing else is sent."
    print_info "No port opens, the Telcoin Association is not involved, and the node is not restarted."
    print_info "Each URL holds its monitor's token: it is kept in /etc/telcoin/alerts/targets (root 0600) and shown only as kind@host."
}

# sa_collect_targets -- ask for up to 5 targets, one at a time: the provider, then
# the URL with the input hidden. Each URL is checked as it is typed
# (hb_target_normalize; a refusal says why and asks again) and echoed back as
# kind@host only; an empty URL stops the questions. SA_RAW gets the
# "<kind> <url>" lines. rc 1 when no target was entered.
sa_collect_targets() {
    local n=0 choice kind url host nl
    nl=$'\n'
    SA_RAW=""
    while [[ $n -lt 5 ]]; do
        echo ""
        echo "  Where should the heartbeat go?"
        echo "    1) Uptime Kuma push URL"
        echo "    2) healthchecks.io ping URL"
        echo "    3) JSON webhook"
        choice=""
        read -r -p "  Provider [1-3]: " choice || break
        case "$choice" in
            1) kind="kuma" ;;
            2) kind="healthchecks" ;;
            3) kind="webhook" ;;
            *) print_warn "Please enter 1, 2 or 3."; continue ;;
        esac
        while true; do
            url=""
            read -r -s -p "  URL (input hidden): " url || url=""
            echo ""
            [[ -n "$url" ]] || break
            # In this shell, not in $( ): HB_ERR and HB_URL are read below.
            if hb_target_normalize "$kind" "$url" "$SA_ALLOW_HTTP" >/dev/null 2>&1; then
                break
            fi
            print_warn "${HB_ERR:-not a valid URL}; enter it again, or press Enter to stop."
        done
        if [[ -z "$url" ]]; then
            print_info "No URL entered."
            break
        fi
        host="$(hb_url_host "$HB_URL")"
        HB_URL=""
        n=$((n + 1))
        SA_RAW="${SA_RAW}${kind} ${url}${nl}"
        url=""
        print_ok "Target ${n}: ${kind}@${host}"
        [[ $n -lt 5 ]] || break
        choice=""
        read -r -p "  Add another? [y/N]: " choice || choice=""
        case "$choice" in
            y|Y|yes|Yes|YES) ;;
            *) break ;;
        esac
    done
    [[ $n -gt 0 ]]
}

# sa_prompt_interval -- ask for the interval (default 60); SA_OPT_INTERVAL gets it.
# The stall and inactive times follow from it (sa_timing).
sa_prompt_interval() {
    local v
    while true; do
        v=""
        read -r -p "  Interval in seconds [60]: " v || v=""
        v="${v:-60}"
        if [[ "$v" =~ ^[0-9]{1,4}$ ]] && (( 10#$v >= 30 && 10#$v <= 3600 )); then
            SA_OPT_INTERVAL="$((10#$v))"
            return 0
        fi
        print_warn "Enter a whole number of seconds from 30 to 3600."
    done
}

# sa_advice INTERVAL -- how to set up the monitor after an enable.
sa_advice() {
    addons_say log "Set the monitor's heartbeat interval to about $((2 * 10#$1)) s with 1-2 retries: a node update or a restart you run yourself shows as a short down."
}

# sa_enable_run ON -- alerts_enable with ALERTS_VALID on stdin (a process
# substitution run in this shell; empty when no targets were given). ON is 1 when
# private alerts were on before (SA_I, SA_S and SA_A then hold only the values
# this run asked for). rc 0 done (the host baseline made again); 1 refused or
# rolled back, the host as it was; 3 something changed and stays (SA_FAIL_MSG
# says what when the library's last error does not).
sa_enable_run() {
    local on="$1" rc=0 f
    SA_FAIL_MSG=""
    alerts_enable "$SA_I" "$SA_S" "$SA_A" addons_say < <(trap - ERR; printf '%s' "$ALERTS_VALID") || rc=$?
    ALERTS_VALID=""
    if [[ $rc -eq 0 ]]; then
        sa_baseline_refresh
        return 0
    fi
    if [[ "$on" == 1 ]]; then
        # 1: refused, or the previous targets put back: nothing changed. 2: a
        # targets change or a refresh went partway (the previous targets could not
        # be put back, or files were rewritten) and stays.
        if [[ $rc -eq 2 ]]; then
            sa_baseline_refresh
            return 3
        fi
        return 1
    fi
    f="$(alerts_targets_file)"
    if [[ -e "$f" || -L "$f" ]]; then
        SA_FAIL_MSG="private alerts were not enabled, and ${f}, which holds the monitor URLs, could not be removed; delete it by hand: sudo shred -u ${f}"
        sa_baseline_refresh
        return 3
    fi
    return 1
}

# =============================================================================
# Actions (--status, --enable, --test, --refresh, --disable; with or without --json)
# =============================================================================

# sa_do_status -- how private alerts stand (alerts_status). No lock and no root
# needed; without root the last run is not read, and "enabled" is null when
# .node-meta cannot be read. Exit 0; "issues" counts what alerts_status found.
sa_do_status() {
    local n=0
    load_node_context
    alerts_status addons_say || n=$?
    sa_finish "" ",\"enabled\":$(sa_jstr "${ALERTS_ST_ENABLED:-}"),\"timer\":\"$(json_escape "${ALERTS_ST_TIMER:-absent}")\",\"last_run\":$(sa_jnum "${ALERTS_ST_LAST_RUN:-}"),\"last_status\":$(sa_jstr "${ALERTS_ST_LAST_STATUS:-}"),\"last_reason\":$(sa_jstr "${ALERTS_ST_LAST_REASON:-}"),\"runner_version\":$(sa_jstr "${ALERTS_ST_RUNNER_VERSION:-}"),\"issues\":${n},\"targets\":$(sa_jtargets)" \
        "private alerts status"
}

# sa_do_enable -- --enable: turn private alerts on with the targets of this run.
# Without a target source: on a node with alerts on, a refresh; from a terminal
# (not --json), the questions; otherwise refused with the stdin hint. On a node
# with alerts on, only the --interval, --stall-after, --inactive-after and --label
# this run gives are applied (sa_timing_req), after the targets when it has some.
sa_do_enable() {
    local on=0 rc=0 applied msg w items=""
    sa_need_root --enable
    load_node_context
    sa_write_begin
    sa_read_cur || sa_end_failed 1
    if sa_alerts_on; then
        on=1
    fi
    if [[ -z "$SA_SRC" ]]; then
        if [[ $on -eq 1 ]]; then
            addons_say log "Private alerts are on already; refreshing them (the targets stay). To change the targets, run setup-alerts.sh and pick Change targets."
        elif json_mode; then
            sa_fail "--enable needs the targets: --targets-stdin (one '<kind> <url>' line each), TN_ALERT_TARGETS or --target kind=url. Nothing was changed."
        elif [[ -t 0 ]]; then
            print_header "Enable private alerts"
            sa_explain
            sa_collect_targets || sa_fail "No target was entered. Nothing was changed."
            SA_SRC="prompt"
            if [[ -z "$SA_TIMING_FLAG" ]]; then
                sa_prompt_interval
            fi
        else
            sa_fail "--enable needs the targets: pipe them in with --targets-stdin (one '<kind> <url>' line each), or run this from a terminal to type them. Nothing was changed."
        fi
    fi
    if [[ $on -eq 1 ]]; then
        sa_timing_req
    else
        sa_timing
    fi
    if [[ -n "$SA_RAW" ]]; then
        if ! sa_check_targets "$SA_RAW"; then
            SA_RAW=""
            sa_fail "Refused: ${ALERTS_ERR}. Nothing was changed."
        fi
        SA_RAW=""
    fi
    sa_enable_run "$on" || rc=$?
    if [[ $rc -ne 0 ]]; then
        sa_end_failed "$rc" "$SA_FAIL_MSG"
    fi
    applied="${ALERTS_APPLIED:-enabled}"
    case "$applied" in
        enabled)
            msg="private alerts enabled"
            sa_advice "$SA_I"
            ;;
        "targets-changed refreshed") msg="private alerts targets changed and refreshed" ;;
        targets-changed)             msg="private alerts targets changed" ;;
        *)                           msg="private alerts refreshed" ;;
    esac
    if [[ "$applied" == *refreshed && -n "$SA_OPT_INTERVAL" ]]; then
        sa_advice "$SA_I"
    fi
    for w in $applied; do
        items="${items:+${items} }alerts:${w}"
    done
    sa_finish "$items" ",\"interval\":$(sa_jnum "$(sa_env_interval)")$(sa_jresult_fields)" "$msg"
}

# sa_do_test -- --test: one heartbeat now (alerts_test), under the update lock.
# Exit 0 when a target accepted it, 1 otherwise.
sa_do_test() {
    local rc=0
    sa_need_root --test
    load_node_context
    sa_lock_begin
    if [[ ! -f "$(alerts_unit_path)" ]]; then
        sa_fail "Private alerts are not set up on this host; enable them first: sudo bash setup-alerts.sh --enable. Nothing was changed."
    fi
    alerts_test addons_say || rc=$?
    case "$rc" in
        0) sa_finish "alerts:tested" "$(sa_jresult_fields)" "test heartbeat sent" ;;
        1) sa_end_failed 1 "no target accepted the test heartbeat; check the URLs and this host's network" ;;
        *) sa_end_failed 1 "the heartbeat runner recorded no run; see what it said with: journalctl -u telcoin-heartbeat -n 20" ;;
    esac
}

# sa_do_refresh -- --refresh: after a script update, install the runner again and
# rewrite its settings and units (alerts_refresh), with the --interval,
# --stall-after, --inactive-after and --label this run gives (sa_timing_req; the
# others stay as stored). Exit 1 when a value is refused (nothing changed), 3 when
# it stopped partway.
sa_do_refresh() {
    local rc=0
    sa_need_root --refresh
    load_node_context
    sa_write_begin
    sa_read_cur || sa_end_failed 1
    if ! sa_alerts_present; then
        alerts_refresh addons_say || rc=$?
        sa_finish "" "" "private alerts are off; nothing to refresh"
    fi
    sa_timing_req
    alerts_refresh addons_say "$SA_I" "$SA_S" "$SA_A" || rc=$?
    case "$rc" in
        0) sa_baseline_refresh ;;
        1) sa_end_failed 1 ;;
        *)
            sa_baseline_refresh
            sa_end_failed 3
            ;;
    esac
    if [[ -n "$SA_OPT_INTERVAL" ]]; then
        sa_advice "$SA_I"
    fi
    sa_finish "alerts:refreshed" ",\"interval\":$(sa_jnum "$(sa_env_interval)")" "private alerts refreshed"
}

# sa_do_disable -- --disable: remove the timer, its service, the runner, the
# targets and the runner's state (alerts_disable). Exit 3 when the targets file
# could not be deleted.
sa_do_disable() {
    local rc=0 f
    sa_need_root --disable
    load_node_context
    sa_write_begin
    alerts_disable addons_say || rc=$?
    sa_baseline_refresh
    if [[ $rc -ne 0 ]]; then
        f="$(alerts_targets_file)"
        sa_end_failed 3 "private alerts were removed except ${f}, which holds the monitor URLs; delete it by hand: sudo shred -u ${f}"
    fi
    sa_finish "alerts:disabled" "" "private alerts disabled"
}

# =============================================================================
# Menu
# =============================================================================

# sa_state_word -- on, pending or off, as .node-meta records it.
sa_state_word() {
    local v
    v="$(addon_meta_get ENABLE_ALERTS false 2>/dev/null)" || v="dup"
    case "$v" in
        true)    printf 'on\n' ;;
        pending) printf 'pending\n' ;;
        dup)     printf 'unknown (ENABLE_ALERTS is set more than once in .node-meta)\n' ;;
        *)       printf 'off\n' ;;
    esac
}

menu_status() {
    print_header "Private alerts status"
    alerts_status addons_say || true
    pause
}

menu_enable() {
    local rc=0
    print_header "Enable private alerts"
    addon_meta_write_begin || { pause; return 0; }
    sa_read_cur || { pause; return 0; }
    if sa_alerts_on; then
        print_info "Private alerts are on already. Pick 3 to change the targets, or 5 to refresh them after a script update."
        pause
        return 0
    fi
    sa_explain
    if ! sa_collect_targets; then
        print_info "No target entered; nothing was changed."
        pause
        return 0
    fi
    sa_prompt_interval
    sa_timing
    if ! sa_check_targets "$SA_RAW"; then
        SA_RAW=""
        print_error "Refused: ${ALERTS_ERR}. Nothing was changed."
        pause
        return 0
    fi
    SA_RAW=""
    sa_enable_run 0 || rc=$?
    if [[ $rc -eq 0 ]]; then
        sa_advice "$SA_I"
    elif [[ -n "$SA_FAIL_MSG" ]]; then
        print_error "$SA_FAIL_MSG"
    fi
    pause
}

menu_targets() {
    local rc=0
    print_header "Change the private alerts targets"
    addon_meta_write_begin || { pause; return 0; }
    sa_read_cur || { pause; return 0; }
    if ! sa_alerts_on; then
        print_warn "Private alerts are off on this host; pick 2 to enable them."
        pause
        return 0
    fi
    print_info "The new targets replace the current ones once one of them accepts a test heartbeat; otherwise the current ones stay."
    if ! sa_collect_targets; then
        print_info "No target entered; nothing was changed."
        pause
        return 0
    fi
    if ! sa_check_targets "$SA_RAW"; then
        SA_RAW=""
        print_error "Refused: ${ALERTS_ERR}. Nothing was changed."
        pause
        return 0
    fi
    SA_RAW=""
    alerts_set_targets addons_say < <(trap - ERR; printf '%s' "$ALERTS_VALID") || rc=$?
    ALERTS_VALID=""
    if [[ $rc -ne 1 ]]; then
        # 0 changed; 2 changed and the previous targets could not be put back.
        sa_baseline_refresh
    fi
    pause
}

menu_test() {
    print_header "Send a test heartbeat"
    if [[ ! -f "$(alerts_unit_path)" ]]; then
        print_warn "Private alerts are not set up on this host; pick 2 to enable them."
        pause
        return 0
    fi
    alerts_test addons_say || true
    pause
}

menu_refresh() {
    local rc=0
    print_header "Refresh private alerts"
    addon_meta_write_begin || { pause; return 0; }
    sa_read_cur || { pause; return 0; }
    if ! sa_alerts_present; then
        alerts_refresh addons_say || true
        pause
        return 0
    fi
    print_info "Installs the runner of these scripts again and rewrites its settings and units; the targets stay and the node is not restarted."
    alerts_refresh addons_say || rc=$?
    if [[ $rc -ne 1 ]]; then
        # 0 refreshed; 2 stopped partway. 1 refused, nothing changed.
        sa_baseline_refresh
    fi
    pause
}

menu_disable() {
    print_header "Disable private alerts"
    addon_meta_write_begin || { pause; return 0; }
    print_info "Removes the heartbeat timer, its service, the runner, the targets and the runner's state. The node keeps running."
    if confirm "Disable private alerts on this host?"; then
        alerts_disable addons_say || true
        sa_baseline_refresh
    else
        print_info "Nothing was changed."
    fi
    pause
}

# sa_menu -- the interactive menu, under the update lock (each change takes the
# ownership migration first).
sa_menu() {
    local choice
    sa_need_root
    load_node_context
    sa_lock_begin
    while true; do
        clear 2>/dev/null || true
        print_header "Telcoin Network -- Private Alerts  v${SCRIPT_VERSION}"
        print_info "Network: ${NETWORK:-unknown}   Private alerts: $(sa_state_word)"
        echo ""
        echo "  1) Status"
        echo "  2) Enable private alerts"
        echo "  3) Change targets"
        echo "  4) Send a test heartbeat now"
        echo "  5) Refresh after a script update"
        echo "  6) Disable private alerts"
        echo "  7) Exit"
        echo ""
        choice=""
        if ! read -r -p "  Enter choice [1-7]: " choice; then
            echo ""
            exit 0
        fi
        case "$choice" in
            1) menu_status ;;
            2) menu_enable ;;
            3) menu_targets ;;
            4) menu_test ;;
            5) menu_refresh ;;
            6) menu_disable ;;
            7) echo ""; print_info "Exiting."; exit 0 ;;
            *) print_warn "Please enter 1-7."; sleep 1 ;;
        esac
    done
}

# =============================================================================
# Arguments and main
# =============================================================================

# sa_set_action NAME -- one action per run.
sa_set_action() {
    if [[ -n "$SA_ACTION" && "$SA_ACTION" != "$1" ]]; then
        arg_fail "Give one action: --status, --enable, --test, --refresh or --disable. Nothing was changed."
    fi
    SA_ACTION="$1"
}

# sa_set_value FLAG VALUE -- a value flag.
sa_set_value() {
    local nl kind
    nl=$'\n'
    case "$1" in
        --target)
            kind="${2%%=*}"
            if [[ "$2" != *=* || -z "$kind" || -z "${2#*=}" ]]; then
                arg_fail "--target needs kind=url, with kind kuma, healthchecks or webhook. Nothing was changed."
            fi
            SA_ARGV_TARGETS="${SA_ARGV_TARGETS}${kind} ${2#*=}${nl}"
            SA_TARGET_FLAG="${SA_TARGET_FLAG:-$1}"
            ;;
        --interval|--stall-after|--inactive-after)
            if [[ ! "$2" =~ ^[0-9]{1,6}$ ]]; then
                arg_fail "$1 needs a whole number of seconds. Nothing was changed."
            fi
            case "$1" in
                --interval)       SA_OPT_INTERVAL="$2" ;;
                --stall-after)    SA_OPT_STALL="$2" ;;
                --inactive-after) SA_OPT_INACTIVE="$2" ;;
            esac
            SA_TIMING_FLAG="${SA_TIMING_FLAG:-$1}"
            ;;
        --label)
            if [[ ! "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
                arg_fail "--label takes 1 to 64 letters, digits, dots, underscores or dashes, starting with a letter or a digit. Nothing was changed."
            fi
            ALERTS_LABEL_REQ="$2"
            ;;
    esac
}

# sa_unknown_arg ARG -- refuse an argument this script does not know. It is named
# only when it looks like an option: a stray URL would carry its token.
sa_unknown_arg() {
    local a="${1%%=*}"
    if [[ "$a" =~ ^--?[A-Za-z][A-Za-z0-9-]{0,40}$ ]]; then
        arg_fail "Unknown argument: ${a} (see --help). Nothing was changed."
    fi
    arg_fail "Unknown argument (not shown, in case it holds a URL); see --help. Nothing was changed."
}

sa_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) shift ;;
            --status|--enable|--test|--refresh|--disable)
                sa_set_action "${1#--}"
                shift
                ;;
            --targets-stdin)
                SA_TARGETS_STDIN=true
                SA_TARGET_FLAG="${SA_TARGET_FLAG:-$1}"
                shift
                ;;
            --allow-http)
                SA_ALLOW_HTTP=1
                shift
                ;;
            --target|--interval|--stall-after|--inactive-after|--label)
                # A value flag needs a value; the next option is not one.
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    arg_fail "$1 needs a value. Nothing was changed."
                fi
                sa_set_value "$1" "$2"
                shift 2
                ;;
            --target=*|--interval=*|--stall-after=*|--inactive-after=*|--label=*)
                sa_set_value "${1%%=*}" "${1#*=}"
                shift
                ;;
            *) sa_unknown_arg "$1" ;;
        esac
    done
}

# sa_check_combos -- each option goes with the actions that use it.
sa_check_combos() {
    local a="${SA_ACTION:-menu}"
    if json_mode && [[ -z "$SA_ACTION" ]]; then
        arg_fail "--json needs one action: --status, --enable, --test, --refresh or --disable. Nothing was changed."
    fi
    if [[ -n "$SA_TARGET_FLAG" && "$a" != "enable" ]]; then
        arg_fail "${SA_TARGET_FLAG} goes with --enable (the menu asks for the targets). Nothing was changed."
    fi
    if [[ -n "$SA_TIMING_FLAG" && "$a" != "enable" && "$a" != "refresh" ]]; then
        arg_fail "${SA_TIMING_FLAG} goes with --enable or --refresh (the menu asks for the interval). Nothing was changed."
    fi
    if [[ "$SA_ALLOW_HTTP" == 1 && "$a" != "enable" && "$a" != "menu" ]]; then
        arg_fail "--allow-http goes with --enable or the menu. Nothing was changed."
    fi
    if [[ -n "$ALERTS_LABEL_REQ" && "$a" != "enable" && "$a" != "refresh" && "$a" != "menu" ]]; then
        arg_fail "--label goes with --enable, --refresh or the menu. Nothing was changed."
    fi
    return 0
}

# sa_pick_targets -- the target lines of an --enable run into SA_RAW, from exactly
# one source: --targets-stdin, --target or TN_ALERT_TARGETS (copied before the
# library was sourced). --target warns, once.
sa_pick_targets() {
    local n=0 use_env=0
    if [[ "$SA_ACTION" == "enable" && -n "$SA_ENV_TARGETS" ]]; then
        use_env=1
        n=$((n + 1))
    fi
    if [[ "$SA_TARGETS_STDIN" == "true" ]]; then
        n=$((n + 1))
    fi
    if [[ -n "$SA_ARGV_TARGETS" ]]; then
        n=$((n + 1))
    fi
    if [[ $n -gt 1 ]]; then
        SA_ARGV_TARGETS=""
        SA_ENV_TARGETS=""
        arg_fail "Give the targets one way: --targets-stdin, --target or TN_ALERT_TARGETS. Nothing was changed."
    fi
    if [[ -n "$SA_ARGV_TARGETS" ]]; then
        addons_say warn "--target puts the URL on the command line, where other local users can read it while this runs; pipe it in with --targets-stdin instead."
        SA_RAW="$SA_ARGV_TARGETS"
        SA_SRC="argv"
    elif [[ "$SA_TARGETS_STDIN" == "true" ]]; then
        sa_read_targets_stdin
        SA_SRC="stdin"
    elif [[ $use_env -eq 1 ]]; then
        SA_RAW="$SA_ENV_TARGETS"
        SA_SRC="env"
    fi
    SA_ARGV_TARGETS=""
    SA_ENV_TARGETS=""
    return 0
}

main() {
    local arg help=false
    # --json and --help are found before anything else runs: with --json, stdout
    # carries JSON only from here, and json_on_exit closes the run with a done event
    # whatever stops it, a bad argument too.
    for arg in "$@"; do
        case "$arg" in
            --json)    JSON_MODE=true ;;
            -h|--help) help=true ;;
        esac
    done
    if [[ "$help" == "true" ]]; then
        usage
        exit 0
    fi
    alerts_require_lib
    # This script owns the EXIT trap, which releases the update lock.
    TN_EXIT_TRAP_OWNED=1
    if json_mode; then
        json_setup_fds
        trap json_on_exit EXIT
    else
        trap sa_on_exit EXIT
    fi
    sa_signal_traps
    sa_parse_args "$@"
    sa_check_combos
    sa_pick_targets
    case "$SA_ACTION" in
        status)  sa_do_status ;;
        enable)  sa_do_enable ;;
        test)    sa_do_test ;;
        refresh) sa_do_refresh ;;
        disable) sa_do_disable ;;
        *)       sa_menu ;;
    esac
}

main "$@"
