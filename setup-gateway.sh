#!/usr/bin/env bash
# =============================================================================
# setup-gateway.sh -- the worker gateway: a public JSON-RPC front for transactions
#
# Optional and reversible. Runs the worker-gateway image as the systemd unit
# telcoin-gateway.service (container telcoin-gateway: host network, read-only,
# no capability). The gateway answers JSON-RPC POSTs: a transaction submission
# goes to the worker of the node it fronts (that node's RPC port, with its
# /health/workers answer as the readiness signal), every other call is proxied
# to the URL of --redirect-queries. It has no TLS, no WebSocket and no auth of
# its own; it limits each client IP to 100 requests a second and 32 connections.
# With --front caddy the public side is https://<domain>/ through this host's
# Caddy (install-caddy.sh writes the block); with --front none the gateway itself
# listens on 0.0.0.0:<listen port> over plain HTTP, and the firewall is yours.
#
# Two layouts. --mode same-host: next to the node on this host (not on mainnet;
# the node's launch file needs a --healthcheck flag). --mode standalone: on a
# host with no node, in front of a validator reached on its private IPv4
# (--upstream), whose firewall must let this host reach its RPC and health ports.
#
# USAGE:
#   sudo bash setup-gateway.sh --enable --mode same-host|standalone \
#     --image <repo>@sha256:<digest> --redirect-queries <url> [options] [--yes] [--json]
#   bash setup-gateway.sh --status [--json]          # no root needed
#   sudo bash setup-gateway.sh --refresh [--image <repo>@sha256:<digest>] [--yes] [--json]
#   sudo bash setup-gateway.sh --remove [--yes] [--json]
#   Give exactly one action. With none the script prints this text (no menu).
#
# Examples:
#   # Same host as the node, behind this host's Caddy:
#   sudo bash setup-gateway.sh --enable --mode same-host --domain gw.example.org \
#     --image us-docker.pkg.dev/telcoin-network/tn-public/worker-gateway@sha256:<64 hex> \
#     --redirect-queries https://rpc.example.org/
#   # Its own host (no node, no Caddy) in front of a validator at 10.0.0.12:
#   sudo bash setup-gateway.sh --enable --mode standalone --network devnet \
#     --upstream 10.0.0.12 --front none \
#     --image us-docker.pkg.dev/telcoin-network/tn-public/worker-gateway@sha256:<64 hex> \
#     --redirect-queries https://rpc.example.org/ --yes --json
#
# Options of --enable (a value flag takes "--flag VALUE" or "--flag=VALUE"):
#   --mode same-host|standalone  required
#   --image REF                  <repo>@sha256:<64 lowercase hex>; a tag is refused.
#                                devnet: the published worker-gateway repository;
#                                testnet, mainnet: only the digest this release pins
#                                (then --image may be left out)
#   --redirect-queries URL       http(s) URL that gets every call but submissions
#   --network NAME               devnet, testnet or mainnet; required on a host with
#                                no node, else .node-meta NETWORK, which it must equal
#   --front caddy|none           default caddy
#   --domain HOST                the public name; required with caddy, refused with none
#   --upstream IPV4              standalone, required: the validator's private IPv4
#   --rpc-port N                 the node's RPC port. Default same-host: the node's
#                                --http.port, else .node-meta RPC_PORT, else 8545;
#                                standalone: 8545
#   --health-port N              the node's --healthcheck port. Default same-host:
#                                the node's own; standalone: 43174
#   --listen-port N              JSON-RPC listener, default 8655
#   --probe-port N               /health, /ready, /ready/any on 127.0.0.1, default 8656
#   --metrics-port N             metrics on 127.0.0.1, default 9655
#   --trusted-proxies CIDRS      default 127.0.0.1/32 with caddy, none with none
#   --rate-limit-submissions N   submissions a second the gateway keeps for
#                                eth_sendRawTransaction out of its global bucket,
#                                so a query flood cannot starve them; default 300,
#                                0 turns the reservation off
# Other options:
#   --image REF                  also with --refresh: run that digest (same rules)
#   --yes                        with --enable, --refresh, --remove: do not ask.
#                                --enable and --remove print what they expose or
#                                remove and ask once; with no terminal --yes is
#                                required. --json never asks.
#   --json                       events on stdout, one {"event":"done",...} line
#                                last; everything else on stderr
#   -h, --help                   this text
#
# --enable waits up to 20 s for the gateway's /health, not for /ready (the node
# may be down). --refresh renders the unit again from
# /etc/telcoin/gateway/gateway.meta and restarts the gateway only. --remove
# removes the unit, the container, /etc/telcoin/gateway and the Caddy block; the
# image stays. --status always exits 0 once it could read the state: judge
# installed, active, ready and issues.
#
# Never: this script never stops, starts or restarts the node, never edits the
# node's launch file or .node-meta, and never opens a firewall port (on a
# standalone layout the validator opens its ports with firewall-setup.sh).
#
# Exit status: 0 done; 1 refused or rolled back, nothing changed; 2 the libraries
# are older than this script; 3 a step failed after something changed (the
# message says what is left); 143, 130, 129 stopped by TERM, INT, HUP.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

readonly SCRIPT_VERSION="2.2.0"

# The run's settings, from the command line (sg_parse_args). The library inputs
# GW_IN_* are set by sg_inputs_reset and sg_set_value.
SG_ACTION=""            # enable, status, refresh, remove; empty: print the usage
SG_YES=false
SG_NETWORK_ARG=""       # --network as given
SG_ENABLE_FLAG=""       # the first option given that goes with --enable only
NETWORK=""              # this run's network (sg_resolve_network)
SG_INST=0               # 1 when gw_status found the gateway installed (sg_jfields)
SG_GAP_FNS=""
SG_GAP_LIBS=""
SG_GAP_N=0
# <repo>@sha256:<64 lowercase hex>, the only image reference form (contract 3.4).
SG_IMAGE_RE='^[a-z0-9]([a-z0-9._-]*[a-z0-9])?(:[0-9]{1,5})?(/[a-z0-9]([a-z0-9._-]*[a-z0-9])?)*@sha256:[0-9a-f]{64}$'

# sg_say KIND MSG -- the say function the library reports through (KIND step,
# log, ok, warn or error): in --json mode a JSON event (step, warn and error keep
# their kind, the rest become log events), otherwise a print_* line.
sg_say() {
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

# sg_baseline_refresh -- after a change: make the host baseline again
# (tn_host_baseline_refresh, a no-op without HOST_BASELINE=true in .node-meta).
# Only on a host with a node, and only with a lib/common.sh that has it. Never fails.
sg_baseline_refresh() {
    if declare -F tn_host_baseline_refresh >/dev/null 2>&1 && node_meta_path >/dev/null 2>&1; then
        tn_host_baseline_refresh sg_say || true
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
# before its rename, release the update lock, and send done ok:false when no done
# event was sent, with the last error event's message when there was one.
json_on_exit() {
    local rc=$? msg
    tn_remove_inflight_tmp 2>/dev/null || true
    tn_release_update_lock 2>/dev/null || true
    [[ "$JSON_DONE_EMITTED" == "true" ]] && return
    msg="$JSON_LAST_ERROR"
    if [[ -z "$msg" ]]; then
        msg="setup-gateway.sh stopped early (rc=${rc}); see its messages on stderr"
    fi
    json_emit "{\"event\":\"done\",\"ok\":false,\"msg\":\"$(json_escape "$msg")\"}"
}

# json_fail MSG [RC] -- an error event, then exit RC (default 1); json_on_exit
# sends done ok:false with MSG.
json_fail() { json_event error "$1"; exit "${2:-1}"; }

# sg_jstr VALUE -- VALUE as a JSON string, or null when it is empty.
sg_jstr() {
    if [[ -n "${1:-}" ]]; then
        printf '"%s"' "$(json_escape "$1")"
    else
        printf 'null'
    fi
}

# sg_true VALUE -- rc 0 when a library status value means yes (true, 1 or yes).
sg_true() {
    case "${1:-}" in
        true|1|yes) return 0 ;;
    esac
    return 1
}

# sg_jbool VALUE -- VALUE as a JSON boolean (anything but true, 1 or yes is false).
sg_jbool() {
    if sg_true "${1:-}"; then
        printf 'true'
    else
        printf 'false'
    fi
}

# sg_jist VALUE -- a status string: sg_jstr VALUE, or null when the gateway is not
# installed (SG_INST, set by sg_jfields).
sg_jist() {
    if [[ "$SG_INST" -eq 1 ]]; then
        sg_jstr "${1:-}"
    else
        printf 'null'
    fi
}

# sg_jfields ISSUES -- every status field of a done line (contract 3.2), each with
# its leading comma, from GW_ST_* (gw_status). Strings are null when the gateway
# is not installed; caddy_block is null with front none (or when unknown); issues
# is GW_ST_ISSUES, else ISSUES (gw_status's rc).
sg_jfields() {
    local n="${GW_ST_ISSUES:-}" cb="null"
    [[ "$n" =~ ^[0-9]{1,9}$ ]] || n="${1:-0}"
    [[ "$n" =~ ^[0-9]{1,9}$ ]] || n=0
    SG_INST=0
    if sg_true "${GW_ST_INSTALLED:-}"; then
        SG_INST=1
    fi
    if [[ "${GW_ST_FRONT:-}" != "none" && -n "${GW_ST_CADDY_BLOCK:-}" ]]; then
        cb="$(sg_jbool "${GW_ST_CADDY_BLOCK:-}")"
    fi
    printf ',"installed":%s,"enabled":%s,"active":%s' \
        "$(sg_jbool "${GW_ST_INSTALLED:-}")" "$(sg_jbool "${GW_ST_ENABLED:-}")" "$(sg_jbool "${GW_ST_ACTIVE:-}")"
    printf ',"mode":%s,"front":%s,"domain":%s,"image":%s,"image_held":%s' \
        "$(sg_jist "${GW_ST_MODE:-}")" "$(sg_jist "${GW_ST_FRONT:-}")" "$(sg_jist "${GW_ST_DOMAIN:-}")" \
        "$(sg_jist "${GW_ST_IMAGE:-}")" "$(sg_jbool "${GW_ST_IMAGE_HELD:-}")"
    printf ',"listen":%s,"probe":%s,"metrics":%s' \
        "$(sg_jist "${GW_ST_LISTEN:-}")" "$(sg_jist "${GW_ST_PROBE:-}")" "$(sg_jist "${GW_ST_METRICS:-}")"
    printf ',"upstream_rpc":%s,"upstream_readiness":%s,"redirect_queries":%s' \
        "$(sg_jist "${GW_ST_UPSTREAM_RPC:-}")" "$(sg_jist "${GW_ST_UPSTREAM_READINESS:-}")" \
        "$(sg_jist "${GW_ST_REDIRECT_QUERIES:-}")"
    printf ',"health":%s,"ready":%s,"ready_any":%s,"caddy_block":%s,"issues":%s' \
        "$(sg_jbool "${GW_ST_HEALTH:-}")" "$(sg_jbool "${GW_ST_READY:-}")" "$(sg_jbool "${GW_ST_READY_ANY:-}")" \
        "$cb" "$((10#$n))"
}

# sg_applied -- GW_APPLIED's words as this script's "applied" items (gateway:<word>).
sg_applied() {
    local w out=""
    for w in ${GW_APPLIED:-}; do
        out="${out:+${out} }gateway:${w}"
    done
    printf '%s' "$out"
}

# sg_finish APPLIED FIELDS MSG -- the end of a run that went through: in --json
# mode the done event (APPLIED the "applied" items separated by spaces, none when
# empty; FIELDS the extra fields, each with its leading comma), otherwise MSG as
# an [OK] line. Exit 0.
sg_finish() {
    local applied="" w
    for w in ${1:-}; do
        applied="${applied:+${applied},}\"$(json_escape "$w")\""
    done
    if json_mode; then
        json_done "{\"event\":\"done\",\"ok\":true,\"applied\":[${applied}],\"network\":$(sg_jstr "${NETWORK:-}")${2:-},\"msg\":\"$(json_escape "${3:-}")\"}"
    else
        print_ok "${3:-}"
    fi
    exit 0
}

# sg_fail MSG [RC] -- refuse or stop with MSG: an error event in --json mode (then
# done ok:false), an [ERROR] line otherwise. Exits RC (default 1).
sg_fail() {
    if json_mode; then
        json_fail "$1" "${2:-1}"
    fi
    print_error "$1"
    exit "${2:-1}"
}

# arg_fail MSG -- a bad command line: as sg_fail, exit 1.
arg_fail() {
    sg_fail "$1" 1
}

# sg_lib_end RC -- a library step that did not go through, GW_ERR saying why: rc 1
# (refused, or put back) ends the run with exit 1, any other rc (2: partial) with
# exit 3.
sg_lib_end() {
    local err="${GW_ERR:-}"
    if [[ "$1" -eq 1 ]]; then
        [[ -n "$err" ]] || err="the worker gateway step was refused or put back (see the messages above)"
        case "$err" in
            *"Nothing was changed.") ;;
            *) err="${err%.}. Nothing was changed." ;;
        esac
        sg_fail "$err" 1
    fi
    [[ -n "$err" ]] || err="a worker gateway step failed after something changed; the messages above say what is left"
    sg_fail "$err" 3
}

# =============================================================================
# Library check, traps, usage
# =============================================================================

# _sg_lib_gap LIB FN... -- add each FN that is not defined to SG_GAP_FNS, and LIB
# to SG_GAP_LIBS when one of them is missing.
_sg_lib_gap() {
    local lib="$1" fn hit=0
    shift
    for fn in "$@"; do
        if ! declare -F "$fn" >/dev/null 2>&1; then
            SG_GAP_FNS="${SG_GAP_FNS:+${SG_GAP_FNS}, }${fn}"
            hit=1
        fi
    done
    if [[ $hit -eq 1 ]]; then
        SG_GAP_N=$((SG_GAP_N + 1))
        case "$SG_GAP_N" in
            1) SG_GAP_LIBS="$lib" ;;
            *) SG_GAP_LIBS="${SG_GAP_LIBS}|${lib}" ;;
        esac
    fi
    return 0
}

# gateway_require_lib -- exit 2 before anything else when lib/common.sh or
# lib/gateway.sh lacks a helper this script calls (scripts updated without the
# libraries). One message names update-scripts.sh; a --json run also gets it as
# its done event.
gateway_require_lib() {
    local what msg a b
    _sg_lib_gap lib/common.sh node_meta_path meta_get tn_gateway_meta_get \
        tn_remove_inflight_tmp tn_release_update_lock
    _sg_lib_gap lib/gateway.sh gw_validate_inputs gw_enable gw_refresh gw_remove gw_status
    [[ "$SG_GAP_N" -eq 0 ]] && return 0
    IFS='|' read -r a b <<< "$SG_GAP_LIBS" || true
    case "$SG_GAP_N" in
        1) what="${a} is" ;;
        *) what="${a} and ${b} are" ;;
    esac
    msg="${what} older than this script (it lacks ${SG_GAP_FNS}): run update-scripts.sh, then this again. Nothing was changed."
    # All of it on stderr (print_error puts its blank lines on stdout): in --json
    # mode stdout carries the done event only.
    print_error "$msg" >&2
    if json_mode; then
        printf '{"event":"done","ok":false,"error":"%s","msg":"%s"}\n' "$(json_escape "$msg")" "$(json_escape "$msg")"
    fi
    exit 2
}

# sg_on_exit -- the EXIT trap of a plain run: remove a root file write stopped
# before its rename, then release the update lock, as json_on_exit does.
sg_on_exit() {
    tn_remove_inflight_tmp 2>/dev/null || true
    tn_release_update_lock 2>/dev/null || true
}

# sg_signal_traps -- TERM, INT and HUP end the run through exit, so the EXIT trap
# runs: bash 3.2 skips the EXIT trap of a shell that a signal kills by default
# when its parent shell has one.
sg_signal_traps() {
    trap 'exit 143' TERM
    trap 'exit 130' INT
    trap 'exit 129' HUP
}

usage() {
    awk 'NR > 1 && /^# =+$/ { n++; if (n == 2) exit; next } NR > 1 && /^#/ { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
    printf '\nsetup-gateway.sh %s\n' "$SCRIPT_VERSION"
}

# =============================================================================
# Root, network, consent
# =============================================================================

# sg_is_root -- rc 0 when this runs as root.
sg_is_root() {
    [[ "$(id -u 2>/dev/null)" == "0" ]]
}

# sg_need_root [WHAT] -- refuse (exit 1) unless this runs as root.
sg_need_root() {
    sg_is_root && return 0
    sg_fail "Run setup-gateway.sh${1:+ $1} as root (sudo). Nothing was changed."
}

# sg_node_network -- prints NETWORK from this host's .node-meta: nothing when
# there is no node or no NETWORK line. rc 2 when NETWORK is set more than once.
# Never stops the run (a standalone gateway host has no node).
sg_node_network() {
    local meta v rc=0
    meta="$(node_meta_path 2>/dev/null)" || return 0
    [[ -n "$meta" ]] || return 0
    v="$(meta_get NETWORK "$meta" 2>/dev/null)" || rc=$?
    case "$rc" in
        0) printf '%s' "$v" ;;
        2) return 2 ;;
    esac
    return 0
}

# sg_resolve_network -- NETWORK for this run: --network (which must equal the
# node's when this host has one), else the node's .node-meta NETWORK, else, for
# --status, --refresh and --remove, gateway.meta NETWORK. --enable with no
# network is refused; the others go on with none (the library judges). Sets
# GW_IN_NETWORK to it.
# shellcheck disable=SC2034  # GW_IN_NETWORK is read by lib/gateway.sh
sg_resolve_network() {
    local node="" rc=0 v=""
    node="$(sg_node_network)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        sg_fail "NETWORK is set more than once in .node-meta; remove the extra lines and run this again. Nothing was changed."
    fi
    if [[ -n "$SG_NETWORK_ARG" ]]; then
        if [[ -n "$node" && "$node" != "$SG_NETWORK_ARG" ]]; then
            sg_fail "--network ${SG_NETWORK_ARG} differs from the node on this host (.node-meta says ${node}). Nothing was changed."
        fi
        NETWORK="$SG_NETWORK_ARG"
    elif [[ -n "$node" ]]; then
        NETWORK="$node"
    elif [[ "$SG_ACTION" == "enable" ]]; then
        sg_fail "No network: this host has no node whose .node-meta names one, so give --network (devnet, testnet or mainnet). Nothing was changed."
    else
        v="$(tn_gateway_meta_get NETWORK "" 2>/dev/null)" || rc=$?
        if [[ $rc -eq 2 ]]; then
            sg_fail "NETWORK is set more than once in ${TN_GATEWAY_META:-/etc/telcoin/gateway/gateway.meta}; remove the extra lines and run this again. Nothing was changed."
        fi
        if [[ $rc -eq 0 ]]; then
            NETWORK="$v"
        fi
    fi
    GW_IN_NETWORK="$NETWORK"
    return 0
}

# sg_summary_enable -- what --enable exposes, one sentence per line, from the
# values gw_validate_inputs resolved (GW_V_*).
sg_summary_enable() {
    if [[ "${GW_V_FRONT:-}" == "none" ]]; then
        printf '%s\n' "The worker gateway answers JSON-RPC from anyone who reaches port ${GW_V_LISTEN_PORT:-?} on any address of this host, over plain HTTP (no TLS); this script changes no firewall rule."
    else
        printf '%s\n' "The worker gateway answers JSON-RPC from anyone on the internet at https://${GW_V_DOMAIN:-?}/, through this host's Caddy."
    fi
    printf '%s\n' \
        "Transaction submissions go to the node's worker at http://${GW_V_UPSTREAM_HOST:-?}:${GW_V_RPC_PORT:-?}; every other call is proxied to ${GW_V_REDIRECT:-?}." \
        "There is no auth: each client IP gets at most 100 requests a second and 32 connections. The node is not stopped or restarted."
}

# sg_summary_remove -- what --remove takes away, one sentence per line, from the
# status the library read (GW_ST_*).
sg_summary_remove() {
    if [[ "${GW_ST_FRONT:-}" == "caddy" && -n "${GW_ST_DOMAIN:-}" ]]; then
        printf '%s\n' "https://${GW_ST_DOMAIN}/ stops answering: its Caddy block is removed."
    elif [[ -n "${GW_ST_LISTEN:-}" ]]; then
        printf '%s\n' "The worker gateway on ${GW_ST_LISTEN} stops answering."
    fi
    printf '%s\n' \
        "The unit ${TN_GATEWAY_UNIT:-telcoin-gateway.service}, its container and /etc/telcoin/gateway are removed; the image stays." \
        "The node is not stopped or restarted."
}

# sg_confirm SUMMARY_FN QUESTION WHAT -- state the summary and get consent, as
# install-caddy.sh does for a public RPC site. --json: a warn event, no question
# (the caller's action is the consent). Otherwise --yes, or a yes typed on a
# terminal; without a terminal and without --yes the run stops before any change.
sg_confirm() {
    local line ans="" text
    if json_mode; then
        text="$("$1" | tr '\n' ' ')"
        json_event warn "${text% }"
        return 0
    fi
    while IFS= read -r line; do print_warn "$line"; done < <("$1")
    [[ "$SG_YES" == "true" ]] && return 0
    [[ -t 0 ]] || sg_fail "${3} needs your consent to the above: run again with --yes (or from a terminal). Nothing was changed."
    read -r -p "  ${2} [y/N]: " ans || ans=""
    case "$ans" in
        y|Y|yes|Yes|YES) return 0 ;;
    esac
    sg_fail "${3} was not done (not confirmed). Nothing was changed."
}

# sg_plain_status -- without --json: the status the library read, a few lines.
sg_plain_status() {
    json_mode && return 0
    print_info "installed $(sg_jbool "${GW_ST_INSTALLED:-}"), enabled $(sg_jbool "${GW_ST_ENABLED:-}"), active $(sg_jbool "${GW_ST_ACTIVE:-}"), network ${NETWORK:-unknown}"
    if sg_true "${GW_ST_INSTALLED:-}"; then
        print_info "mode ${GW_ST_MODE:-?}, front ${GW_ST_FRONT:-?}${GW_ST_DOMAIN:+ (${GW_ST_DOMAIN})}, listen ${GW_ST_LISTEN:-?}, upstream ${GW_ST_UPSTREAM_RPC:-?}"
        print_info "image ${GW_ST_IMAGE:-?} (held $(sg_jbool "${GW_ST_IMAGE_HELD:-}"))"
    fi
    print_info "health $(sg_jbool "${GW_ST_HEALTH:-}"), ready $(sg_jbool "${GW_ST_READY:-}"), ready_any $(sg_jbool "${GW_ST_READY_ANY:-}"), issues ${1:-0}"
    return 0
}

# =============================================================================
# Actions (--enable, --status, --refresh, --remove; with or without --json)
# =============================================================================

# sg_do_status -- how the worker gateway stands (gw_status). No root and no lock.
# Exit 0 once the state was read; "issues" counts what gw_status found.
sg_do_status() {
    local n=0
    sg_resolve_network
    gw_status sg_say || n=$?
    sg_plain_status "$n"
    sg_finish "" "$(sg_jfields "$n")" "worker gateway status"
}

# sg_after_change RC -- after gw_enable, gw_refresh or gw_remove: on rc 0 nothing
# more (the library refreshed the host baseline itself when something changed);
# otherwise end the run (sg_lib_end), with the baseline first when the step went
# partway (the library does not refresh it then).
sg_after_change() {
    if [[ "$1" -eq 0 ]]; then
        return 0
    fi
    [[ "$1" -eq 1 ]] || sg_baseline_refresh
    sg_lib_end "$1"
}

# sg_quiet KIND MSG -- a say function that says nothing.
sg_quiet() { return 0; }

# sg_end_changed MSG_CHANGED MSG_SAME -- the done line of a change that went
# through: GW_ST_* read again (gw_status, through sg_quiet: the change already
# said what it did), then sg_finish.
sg_end_changed() {
    local n=0 applied msg="$1"
    applied="$(sg_applied)"
    [[ -n "$applied" ]] || msg="$2"
    gw_status sg_quiet || n=$?

    sg_finish "$applied" "$(sg_jfields "$n")" "$msg"
}

# sg_do_enable -- --enable: check the inputs (gw_validate_inputs), state what gets
# exposed and get consent, then gw_enable. Exit 1 refused or put back, 3 partial.
sg_do_enable() {
    local rc=0
    sg_need_root --enable
    sg_resolve_network
    gw_validate_inputs sg_say || rc=$?
    [[ $rc -eq 0 ]] || sg_lib_end 1
    sg_confirm sg_summary_enable "Enable the worker gateway?" "Enabling the worker gateway"
    gw_enable sg_say || rc=$?
    sg_after_change "$rc"
    sg_end_changed "worker gateway enabled" "the worker gateway was already as asked; nothing had to change"
}

# sg_do_refresh -- --refresh: render the unit again from gateway.meta (a new
# --image replaces the stored one) and restart the gateway only (gw_refresh).
sg_do_refresh() {
    local rc=0
    sg_need_root --refresh
    sg_resolve_network
    gw_refresh sg_say || rc=$?
    sg_after_change "$rc"
    sg_end_changed "worker gateway refreshed" "the worker gateway was already current; nothing had to change"
}

# sg_do_remove -- --remove: state what goes and get consent (only when there is a
# gateway to remove), then gw_remove. The image stays.
sg_do_remove() {
    local rc=0
    sg_need_root --remove
    sg_resolve_network
    gw_status || true
    if sg_true "${GW_ST_INSTALLED:-}" || sg_true "${GW_ST_ENABLED:-}" || sg_true "${GW_ST_ACTIVE:-}"; then
        sg_confirm sg_summary_remove "Remove the worker gateway?" "Removing the worker gateway"
    fi
    gw_remove sg_say || rc=$?
    sg_after_change "$rc"
    sg_end_changed "worker gateway removed; its image stays on this host" "there is no worker gateway on this host; nothing to remove"
}

# =============================================================================
# Arguments and main
# =============================================================================

# sg_inputs_reset -- the library inputs (contract 3.3), empty = not given, set
# after the libraries were sourced so nothing in the environment reaches them.
# shellcheck disable=SC2034  # GW_IN_* and GW_CADDY_SCRIPT are read by lib/gateway.sh
sg_inputs_reset() {
    GW_IN_MODE="" GW_IN_NETWORK="" GW_IN_IMAGE="" GW_IN_DOMAIN="" GW_IN_FRONT=""
    GW_IN_UPSTREAM="" GW_IN_RPC_PORT="" GW_IN_HEALTH_PORT="" GW_IN_REDIRECT=""
    GW_IN_LISTEN_PORT="" GW_IN_PROBE_PORT="" GW_IN_METRICS_PORT="" GW_IN_TRUSTED_PROXIES=""
    GW_IN_RATE_LIMIT_SUBMISSIONS=""
    GW_CADDY_SCRIPT="${SCRIPT_DIR}/install-caddy.sh"
}

# sg_set_action NAME -- one action per run (the same one twice is accepted).
sg_set_action() {
    if [[ -n "$SG_ACTION" && "$SG_ACTION" != "$1" ]]; then
        arg_fail "Give one action: --enable, --status, --refresh or --remove. Nothing was changed."
    fi
    SG_ACTION="$1"
}

# sg_set_value FLAG VALUE -- a value flag. Checked here: the vocabulary of --mode,
# --front and --network, the port syntax and the image reference form; every other
# value, and every check that needs this host or the defaults, is the library's.
# shellcheck disable=SC2034  # GW_IN_* are read by lib/gateway.sh
sg_set_value() {
    if [[ -z "$2" ]]; then
        arg_fail "$1 needs a value. Nothing was changed."
    fi
    case "$1" in
        --mode)
            case "$2" in
                same-host|standalone) GW_IN_MODE="$2" ;;
                *) arg_fail "--mode takes same-host or standalone. Nothing was changed." ;;
            esac
            ;;
        --front)
            case "$2" in
                caddy|none) GW_IN_FRONT="$2" ;;
                *) arg_fail "--front takes caddy or none. Nothing was changed." ;;
            esac
            ;;
        --network)
            case "$2" in
                devnet|testnet|mainnet) SG_NETWORK_ARG="$2" ;;
                *) arg_fail "--network takes devnet, testnet or mainnet. Nothing was changed." ;;
            esac
            ;;
        --image)
            if [[ ! "$2" =~ $SG_IMAGE_RE ]]; then
                arg_fail "--image takes <repo>@sha256:<64 lowercase hex>; a tag is refused. Nothing was changed."
            fi
            GW_IN_IMAGE="$2"
            ;;
        --rpc-port|--health-port|--listen-port|--probe-port|--metrics-port)
            if [[ ! "$2" =~ ^[1-9][0-9]{0,4}$ ]] || (( 10#$2 > 65535 )); then
                arg_fail "$1 takes a port number, 1 to 65535. Nothing was changed."
            fi
            case "$1" in
                --rpc-port)     GW_IN_RPC_PORT="$2" ;;
                --health-port)  GW_IN_HEALTH_PORT="$2" ;;
                --listen-port)  GW_IN_LISTEN_PORT="$2" ;;
                --probe-port)   GW_IN_PROBE_PORT="$2" ;;
                --metrics-port) GW_IN_METRICS_PORT="$2" ;;
            esac
            ;;
        --domain)           GW_IN_DOMAIN="$2" ;;
        --upstream)         GW_IN_UPSTREAM="$2" ;;
        --redirect-queries) GW_IN_REDIRECT="$2" ;;
        --trusted-proxies)  GW_IN_TRUSTED_PROXIES="$2" ;;
        --rate-limit-submissions) GW_IN_RATE_LIMIT_SUBMISSIONS="$2" ;;
    esac
    if [[ "$1" != "--image" ]]; then
        SG_ENABLE_FLAG="${SG_ENABLE_FLAG:-$1}"
    fi
    return 0
}

# sg_unknown_arg ARG -- refuse an argument this script does not know. It is named
# only when it looks like an option.
sg_unknown_arg() {
    local a="${1%%=*}"
    if [[ "$a" =~ ^--?[A-Za-z][A-Za-z0-9-]{0,40}$ ]]; then
        arg_fail "Unknown argument: ${a} (see --help). Nothing was changed."
    fi
    arg_fail "Unknown argument (not shown); see --help. Nothing was changed."
}

sg_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) shift ;;
            --enable|--status|--refresh|--remove)
                sg_set_action "${1#--}"
                shift
                ;;
            --yes)
                SG_YES=true
                shift
                ;;
            --mode|--image|--redirect-queries|--network|--domain|--front|--upstream|--rpc-port|--health-port|--listen-port|--probe-port|--metrics-port|--trusted-proxies|--rate-limit-submissions)
                # A value flag needs a value; the next option is not one.
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    arg_fail "$1 needs a value. Nothing was changed."
                fi
                sg_set_value "$1" "$2"
                shift 2
                ;;
            --mode=*|--image=*|--redirect-queries=*|--network=*|--domain=*|--front=*|--upstream=*|--rpc-port=*|--health-port=*|--listen-port=*|--probe-port=*|--metrics-port=*|--trusted-proxies=*|--rate-limit-submissions=*)
                sg_set_value "${1%%=*}" "${1#*=}"
                shift
                ;;
            *) sg_unknown_arg "$1" ;;
        esac
    done
}

# sg_check_combos -- no action: the usage (refused with --json); then each option
# goes with the actions that use it.
sg_check_combos() {
    local a="$SG_ACTION"
    if [[ -z "$a" ]]; then
        if json_mode; then
            arg_fail "--json needs one action: --enable, --status, --refresh or --remove. Nothing was changed."
        fi
        usage
        exit 0
    fi
    if [[ -n "$SG_ENABLE_FLAG" && "$a" != "enable" ]]; then
        arg_fail "${SG_ENABLE_FLAG} goes with --enable. Nothing was changed."
    fi
    if [[ -n "$GW_IN_IMAGE" && "$a" != "enable" && "$a" != "refresh" ]]; then
        arg_fail "--image goes with --enable or --refresh. Nothing was changed."
    fi
    if [[ "$SG_YES" == "true" && "$a" == "status" ]]; then
        arg_fail "--yes goes with --enable, --refresh or --remove. Nothing was changed."
    fi
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
    if [[ "$help" == "true" || $# -eq 0 ]]; then
        usage
        exit 0
    fi
    gateway_require_lib
    # This script owns the EXIT trap, which releases the update lock the library takes.
    # shellcheck disable=SC2034  # read by lib/common.sh
    TN_EXIT_TRAP_OWNED=1
    if json_mode; then
        json_setup_fds
        trap json_on_exit EXIT
    else
        trap sg_on_exit EXIT
    fi
    sg_signal_traps
    sg_inputs_reset
    sg_parse_args "$@"
    sg_check_combos
    case "$SG_ACTION" in
        enable)  sg_do_enable ;;
        status)  sg_do_status ;;
        refresh) sg_do_refresh ;;
        remove)  sg_do_remove ;;
    esac
}

main "$@"
