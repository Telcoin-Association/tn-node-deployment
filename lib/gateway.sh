#!/usr/bin/env bash
# =============================================================================
# lib/gateway.sh -- the worker gateway: telcoin-network's worker-gateway image,
# run by docker under systemd, as the public JSON-RPC front of a node's worker.
# Submissions go to the worker (on this host, or a validator's private address);
# every other call goes to the --redirect-queries URL. HTTP only, no TLS: with
# front "caddy" it listens on 127.0.0.1 behind the Caddy edge, with front "none"
# on 0.0.0.0.
#
# Sourced at the end of lib/common.sh, so every script that sources the library
# gets the gw_* functions. Function definitions and plain variables only; no
# top-level side effects (it is sourced under the inherited `set -euo pipefail`).
# setup-gateway.sh drives it: it sets the GW_IN_* inputs and GW_CADDY_SCRIPT,
# calls the public functions with its say function and reads GW_ERR, GW_APPLIED
# and GW_ST_*. Return codes: 0 done; 1 refused, or failed and put back (nothing
# was changed); 2 a step failed and the put-back failed too (GW_ERR says what is
# left). gw_status returns the number of issues instead.
#
# What an enable installs, every file root-owned and written through the
# primitives of lib/common.sh:
#   /etc/telcoin/gateway/                         root 0755 (_tn_root_layout_dir)
#   /etc/telcoin/gateway/gateway.meta             root 0600 (meta_set): the inputs,
#                                                 KEY=value, GATEWAY_META_VERSION=1
#   /etc/systemd/system/telcoin-gateway.service   root 0644 (tn_write_root_file)
# and, through install-caddy.sh (its owner) with front "caddy", the tn-gateway
# block of /etc/caddy/Caddyfile. The unit runs the container telcoin-gateway
# (--rm, so it leaves nothing behind) as 1101:1101, read-only, no capability,
# host network; the image is pulled by digest by gw_image_ensure, never by the
# unit (--pull=never), and stays when the gateway is removed. Before a file is
# replaced it is copied with tn_backup_file (TN_BACKUP_DIR, root 0700) so a
# failed change can put it back. Nothing here writes .node-meta.
#
# Nothing here stops, starts or restarts the node. The public functions that
# change something take the update lock (addon_meta_lock) unless the caller
# holds it already, and release only a lock they took. gw_status needs no root.
#
# Say convention: every public function takes an optional FN and calls
# `FN KIND MSG` (KIND step, log, ok, warn or error); without FN it prints with
# print_step, print_info, print_ok, print_warn and print_error. It never writes
# fd 3.
#
# Paths are under ${TN_ROOT_PREFIX:-} so the fixture tests can point them at a
# private tree; the unit text always names the real paths. bash 3.2 safe.
# =============================================================================

# The GW_* globals are this library's interface (setup-gateway.sh sets the
# inputs and reads the results), so their use is outside this file.
# shellcheck disable=SC2034
#
# Version (tracked by update-scripts.sh). Plain, not readonly, so re-sourcing
# common.sh cannot trip on a readonly redefinition.
GATEWAY_VERSION="2.2.0"

# Image trust (contract 3.4). Only <repository>@sha256:<64 lowercase hex>.
# network-gated: devnet allow-list of worker-gateway repositories; gw_image_allowed reads it for devnet only
GW_DEVNET_IMAGE_REPOS="us-docker.pkg.dev/telcoin-network/tn-public/worker-gateway"
# The digests this scripts release pins (full <repo>@sha256:... references; the
# signed MANIFEST covers this file). Empty: no gateway on that network yet.
# network-gated: the testnet pin; gw_image_allowed reads it for testnet only
GW_TESTNET_IMAGE_PIN=""
# network-gated: the mainnet pin; gw_image_allowed reads it for mainnet only
GW_MAINNET_IMAGE_PIN=""
# Every flag the unit passes; gw_image_probe needs each in the image's --help.
GW_REQUIRED_FLAGS="--listen-addr --probe-addr --metrics --upstream-rpc-url --upstream-readiness-url --worker-id --redirect-queries --trusted-proxies"
# docker for the unit text when `command -v docker` gives no absolute path.
GW_DOCKER_FALLBACK="/usr/bin/docker"

# Inputs the script sets (empty = not given).
: "${GW_IN_MODE:=}" "${GW_IN_NETWORK:=}" "${GW_IN_IMAGE:=}" "${GW_IN_DOMAIN:=}" "${GW_IN_FRONT:=}"
: "${GW_IN_UPSTREAM:=}" "${GW_IN_RPC_PORT:=}" "${GW_IN_HEALTH_PORT:=}" "${GW_IN_REDIRECT:=}"
: "${GW_IN_LISTEN_PORT:=}" "${GW_IN_PROBE_PORT:=}" "${GW_IN_METRICS_PORT:=}" "${GW_IN_TRUSTED_PROXIES:=}"
# install-caddy.sh's path; empty skips the Caddy step with a warning.
: "${GW_CADDY_SCRIPT:=}"
# Seconds gw_enable and gw_refresh wait for GET /health after a (re)start.
: "${GW_HEALTH_WAIT:=20}"

# Results left for the caller.
#   GW_ERR       the reason of the last refusal or failure, one phrase (without
#                "Nothing was changed.")
#   GW_APPLIED   space list of enabled refreshed caddy removed; "" = nothing changed
#   GW_V_*       gw_validate_inputs (or gateway.meta): MODE NETWORK IMAGE DOMAIN
#                FRONT UPSTREAM RPC_PORT HEALTH_PORT REDIRECT LISTEN_PORT
#                PROBE_PORT METRICS_PORT TRUSTED_PROXIES, plus UPSTREAM_HOST
#   GW_ST_*      gw_status, one per status field: INSTALLED ENABLED ACTIVE
#                IMAGE_HELD HEALTH READY READY_ANY (true|false); MODE FRONT DOMAIN
#                IMAGE LISTEN PROBE METRICS UPSTREAM_RPC UPSTREAM_READINESS
#                REDIRECT_QUERIES NETWORK ("" = null); CADDY_BLOCK (true|false, ""
#                = null with front none or not installed); ISSUES (a number)
GW_ERR=""
GW_APPLIED=""
GW_V_MODE="" GW_V_NETWORK="" GW_V_IMAGE="" GW_V_DOMAIN="" GW_V_FRONT="" GW_V_UPSTREAM=""
GW_V_RPC_PORT="" GW_V_HEALTH_PORT="" GW_V_REDIRECT="" GW_V_LISTEN_PORT="" GW_V_PROBE_PORT=""
GW_V_METRICS_PORT="" GW_V_TRUSTED_PROXIES="" GW_V_UPSTREAM_HOST=""
GW_ST_INSTALLED="false" GW_ST_ENABLED="false" GW_ST_ACTIVE="false" GW_ST_MODE="" GW_ST_FRONT=""
GW_ST_DOMAIN="" GW_ST_IMAGE="" GW_ST_IMAGE_HELD="false" GW_ST_LISTEN="" GW_ST_PROBE=""
GW_ST_METRICS="" GW_ST_UPSTREAM_RPC="" GW_ST_UPSTREAM_READINESS="" GW_ST_REDIRECT_QUERIES=""
GW_ST_HEALTH="false" GW_ST_READY="false" GW_ST_READY_ANY="false" GW_ST_CADDY_BLOCK=""
GW_ST_ISSUES=0 GW_ST_NETWORK=""

# Character classes spelled out (a range such as [a-z] follows the locale).
_GW_DIGITS="0123456789"
_GW_LOWER="abcdefghijklmnopqrstuvwxyz"
_GW_ALNUM="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
_GW_ABSENT="<absent>"
# Put-back state of the change in progress (_gw_reset_undo).
_GW_TOOK_LOCK=0 _GW_WAS_ENABLED=0 _GW_WAS_ACTIVE=0 _GW_DID_ENABLE=0 _GW_DID_START=0
_GW_WROTE_UNIT=0 _GW_WROTE_META=0 _GW_MADE_DIR=0 _GW_MADE_PARENT=0 _GW_BK_UNIT="" _GW_BK_UNIT_SUM=""
_GW_BK_META="" _GW_BK_META_SUM="" _GW_PUTBACK_ERR="" _GW_NISSUES=0

# -----------------------------------------------------------------------------
# Paths and messages
# -----------------------------------------------------------------------------

gw_etc_dir()   { printf '%s\n' "${TN_ROOT_PREFIX:-}${TN_GATEWAY_ETC_DIR}"; }
gw_meta_file() { tn_gateway_meta_path; }
gw_unit_path() { printf '%s\n' "${TN_ROOT_PREFIX:-}/etc/systemd/system/${TN_GATEWAY_UNIT}"; }
_gw_caddyfile() { printf '%s\n' "${TN_ROOT_PREFIX:-}/etc/caddy/Caddyfile"; }

# _gw_say KIND MSG [FN] -- report MSG through FN, or print it. Always rc 0.
_gw_say() {
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

# _gw_refuse MSG [FN] -- GW_ERR=MSG, say it as a refusal; always rc 1 (callers
# write `_gw_refuse ... || return 1`).
_gw_refuse() {
    GW_ERR="$1"
    _gw_say error "${1}. Nothing was changed." "${2:-}"
    return 1
}

_gw_is_root() { [[ "$(id -u 2>/dev/null)" == "0" ]]; }

# _gw_docker_bin -- the absolute docker path the unit names.
_gw_docker_bin() {
    local d
    d="$(command -v docker 2>/dev/null || true)"
    case "$d" in
        /*) printf '%s\n' "$d" ;;
        *)  printf '%s\n' "$GW_DOCKER_FALLBACK" ;;
    esac
}

# -----------------------------------------------------------------------------
# Checks on single values
# -----------------------------------------------------------------------------

# _gw_port_ok P -- 1..65535 written without a leading zero.
_gw_port_ok() {
    local re="^[123456789][${_GW_DIGITS}]{0,4}$"
    [[ "${1:-}" =~ $re ]] || return 1
    validate_port "$1"
}

_gw_network_ok() { case "${1:-}" in testnet|mainnet|devnet) return 0 ;; esac; return 1; }

# _gw_upstream_ok IP -- a strict private IPv4 that can be another host: not
# 0.0.0.0/8 and not loopback (a standalone gateway has no node of its own).
_gw_upstream_ok() {
    _tn_ipv4_strict "${1:-}" || return 1
    _tn_ipv4_is_private "$1" || return 1
    case "$1" in 0.*|127.*) return 1 ;; esac
    return 0
}

_gw_domain_ok() {
    local l="[${_GW_ALNUM}]([${_GW_ALNUM}-]{0,61}[${_GW_ALNUM}])?" re
    re="^${l}(\\.${l})+$"
    [[ ${#1} -le 253 && "$1" =~ $re ]]
}

_gw_redirect_ok() {
    local re="^https?://[${_GW_ALNUM}.-]+(:[${_GW_DIGITS}]+)?(/[${_GW_ALNUM}._~/-]*)?$"
    [[ "${1:-}" =~ $re ]]
}

# _gw_proxies_ok LIST -- a comma list of IPv4/IPv6 addresses or CIDRs (the
# characters only; the gateway parses them at start).
_gw_proxies_ok() {
    local re="^[${_GW_DIGITS}abcdefABCDEF.:/]+(,[${_GW_DIGITS}abcdefABCDEF.:/]+)*$"
    [[ "${1:-}" =~ $re ]]
}

# _gw_docker_ok -- docker installed and its daemon answering; rc 1 with GW_ERR.
_gw_docker_ok() {
    if ! command -v docker >/dev/null 2>&1; then
        GW_ERR="docker is not installed on this host"
        return 1
    fi
    if ! docker info >/dev/null 2>&1; then
        GW_ERR="the docker daemon does not answer (start it: systemctl start docker)"
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Inputs
# -----------------------------------------------------------------------------

# gw_validate_inputs [FN] -- resolve the GW_IN_* inputs and their defaults into
# GW_V_* and refuse (rc 1, GW_ERR, said through FN) everything contract 3.1
# lists: mode against this host, network, upstream, front and domain, ports,
# the redirect URL, the image trust rule, docker. Changes nothing.
gw_validate_inputs() {
    local fn="${1:-}" node=0 nnet="" net rc bind="" launch="" target="" p v
    GW_ERR=""
    GW_V_MODE="" GW_V_NETWORK="" GW_V_IMAGE="" GW_V_DOMAIN="" GW_V_FRONT="" GW_V_UPSTREAM=""
    GW_V_RPC_PORT="" GW_V_HEALTH_PORT="" GW_V_REDIRECT="" GW_V_LISTEN_PORT="" GW_V_PROBE_PORT=""
    GW_V_METRICS_PORT="" GW_V_TRUSTED_PROXIES="" GW_V_UPSTREAM_HOST=""
    if node_meta_path >/dev/null 2>&1; then node=1; fi

    case "$GW_IN_MODE" in
        same-host|standalone) GW_V_MODE="$GW_IN_MODE" ;;
        "") _gw_refuse "give --mode same-host or --mode standalone" "$fn" || return 1 ;;
        *)  _gw_refuse "--mode takes same-host or standalone, not '${GW_IN_MODE}'" "$fn" || return 1 ;;
    esac

    # Network: a node host's own, which --network must equal; else --network.
    net="$GW_IN_NETWORK"
    if [[ "$node" == 1 ]]; then
        nnet="$(addon_meta_get NETWORK "" 2>/dev/null)" \
            || { _gw_refuse "this node's .node-meta holds NETWORK more than once" "$fn" || return 1; }
        if [[ -n "$nnet" && -n "$net" && "$net" != "$nnet" ]]; then
            _gw_refuse "--network ${net} is not this node's network (${nnet})" "$fn" || return 1
        fi
        net="${nnet:-$net}"
    fi
    [[ -n "$net" ]] || { _gw_refuse "give --network (this host has no node to take it from)" "$fn" || return 1; }
    _gw_network_ok "$net" || { _gw_refuse "unknown network '${net}' (testnet, mainnet or devnet)" "$fn" || return 1; }
    GW_V_NETWORK="$net"

    if [[ "$GW_V_MODE" == "same-host" ]]; then
        [[ "$node" == 1 ]] || { _gw_refuse "--mode same-host needs the node on this host and none is installed (on a host of its own use --mode standalone --upstream <validator private IPv4>)" "$fn" || return 1; }
        # network-gated: mainnet keeps the gateway off validator hosts (contract 3.1)
        [[ "$net" != "mainnet" ]] || { _gw_refuse "on mainnet the gateway runs on its own host (use --mode standalone there)" "$fn" || return 1; }
        [[ -z "$GW_IN_UPSTREAM" ]] || { _gw_refuse "--upstream is for --mode standalone; same-host reaches the node on 127.0.0.1" "$fn" || return 1; }
        rc=0
        bind="$(tn_node_health_bind 2>/dev/null)" || rc=$?
        if [[ "$rc" -eq 1 ]]; then
            _gw_refuse "the node runs without --healthcheck, and the gateway reads the node's readiness from it; give the node a health port (--healthcheck ${TN_KUMA_PORT:-43174}) and run this again" "$fn" || return 1
        elif [[ "$rc" -ne 0 || -z "$bind" ]]; then
            _gw_refuse "cannot read the node's launch file (check it with check-node.sh)" "$fn" || return 1
        fi
        GW_V_UPSTREAM=""
        GW_V_UPSTREAM_HOST="127.0.0.1"
        GW_V_HEALTH_PORT="${GW_IN_HEALTH_PORT:-${bind##*:}}"
        GW_V_RPC_PORT="$GW_IN_RPC_PORT"
        if [[ -z "$GW_V_RPC_PORT" ]]; then
            target="$(tn_node_launch_target 2>/dev/null)" || target=""
            read -r _ _ launch <<< "$target" || true
            if [[ -n "$launch" ]]; then
                GW_V_RPC_PORT="$(tn_launch_flag_get "$launch" --http.port 2>/dev/null)" || GW_V_RPC_PORT=""
            fi
        fi
        if [[ -z "$GW_V_RPC_PORT" ]]; then
            GW_V_RPC_PORT="$(addon_meta_get RPC_PORT "" 2>/dev/null)" || GW_V_RPC_PORT=""
        fi
        GW_V_RPC_PORT="${GW_V_RPC_PORT:-8545}"
    else
        [[ "$node" == 0 ]] || { _gw_refuse "--mode standalone is for a host without a node, and this host runs one (use --mode same-host)" "$fn" || return 1; }
        [[ -n "$GW_IN_UPSTREAM" ]] || { _gw_refuse "--mode standalone needs --upstream <the validator's private IPv4>" "$fn" || return 1; }
        _gw_upstream_ok "$GW_IN_UPSTREAM" || { _gw_refuse "--upstream ${GW_IN_UPSTREAM} is not a private IPv4 address of another host (10/8, 172.16/12, 192.168/16, 100.64/10 or 169.254/16, no leading zeros)" "$fn" || return 1; }
        GW_V_UPSTREAM="$GW_IN_UPSTREAM"
        GW_V_UPSTREAM_HOST="$GW_IN_UPSTREAM"
        GW_V_RPC_PORT="${GW_IN_RPC_PORT:-8545}"
        GW_V_HEALTH_PORT="${GW_IN_HEALTH_PORT:-${TN_KUMA_PORT:-43174}}"
    fi

    GW_V_FRONT="${GW_IN_FRONT:-caddy}"
    case "$GW_V_FRONT" in
        caddy)
            [[ -n "$GW_IN_DOMAIN" ]] || { _gw_refuse "--front caddy needs --domain <the gateway's hostname>" "$fn" || return 1; }
            _gw_domain_ok "$GW_IN_DOMAIN" || { _gw_refuse "--domain ${GW_IN_DOMAIN} is not a hostname" "$fn" || return 1; }
            GW_V_DOMAIN="$GW_IN_DOMAIN"
            ;;
        none)
            [[ -z "$GW_IN_DOMAIN" ]] || { _gw_refuse "--domain is for --front caddy; --front none serves no hostname" "$fn" || return 1; }
            ;;
        *)  _gw_refuse "--front takes caddy or none, not '${GW_V_FRONT}'" "$fn" || return 1 ;;
    esac

    GW_V_LISTEN_PORT="${GW_IN_LISTEN_PORT:-$TN_GATEWAY_LISTEN_PORT}"
    GW_V_PROBE_PORT="${GW_IN_PROBE_PORT:-$TN_GATEWAY_PROBE_PORT}"
    GW_V_METRICS_PORT="${GW_IN_METRICS_PORT:-$TN_GATEWAY_METRICS_PORT}"
    for p in "rpc:${GW_V_RPC_PORT}" "health:${GW_V_HEALTH_PORT}" "listen:${GW_V_LISTEN_PORT}" \
             "probe:${GW_V_PROBE_PORT}" "metrics:${GW_V_METRICS_PORT}"; do
        v="${p#*:}"
        _gw_port_ok "$v" || { _gw_refuse "the ${p%%:*} port '${v}' is not a port (1-65535)" "$fn" || return 1; }
    done
    if [[ "$GW_V_LISTEN_PORT" == "$GW_V_PROBE_PORT" || "$GW_V_LISTEN_PORT" == "$GW_V_METRICS_PORT" \
          || "$GW_V_PROBE_PORT" == "$GW_V_METRICS_PORT" ]]; then
        _gw_refuse "the listen, probe and metrics ports must be three different ports" "$fn" || return 1
    fi
    if [[ "$GW_V_MODE" == "same-host" ]]; then
        for v in "$GW_V_LISTEN_PORT" "$GW_V_PROBE_PORT" "$GW_V_METRICS_PORT"; do
            if [[ "$v" == "$GW_V_RPC_PORT" || "$v" == "$GW_V_HEALTH_PORT" ]]; then
                _gw_refuse "port ${v} is the node's RPC or health port on this host" "$fn" || return 1
            fi
        done
    fi

    [[ -n "$GW_IN_REDIRECT" ]] || { _gw_refuse "give --redirect-queries <url> (where the gateway sends every call that is not a submission)" "$fn" || return 1; }
    _gw_redirect_ok "$GW_IN_REDIRECT" || { _gw_refuse "--redirect-queries must be http(s)://host[:port][/path] (letters, digits and . - _ ~ / only)" "$fn" || return 1; }
    GW_V_REDIRECT="$GW_IN_REDIRECT"

    if [[ -n "$GW_IN_TRUSTED_PROXIES" ]]; then
        _gw_proxies_ok "$GW_IN_TRUSTED_PROXIES" || { _gw_refuse "--trusted-proxies takes a comma list of addresses or CIDRs" "$fn" || return 1; }
        GW_V_TRUSTED_PROXIES="$GW_IN_TRUSTED_PROXIES"
    elif [[ "$GW_V_FRONT" == "caddy" ]]; then
        GW_V_TRUSTED_PROXIES="127.0.0.1/32"
    fi

    GW_V_IMAGE="$GW_IN_IMAGE"
    if [[ -z "$GW_V_IMAGE" ]]; then
        case "$net" in
            # network-gated: the pinned image is the default on testnet only
            testnet) GW_V_IMAGE="$GW_TESTNET_IMAGE_PIN" ;;
            # network-gated: the pinned image is the default on mainnet only
            mainnet) GW_V_IMAGE="$GW_MAINNET_IMAGE_PIN" ;;
        esac
    fi
    gw_image_allowed "$GW_V_IMAGE" "$net" || { _gw_refuse "$GW_ERR" "$fn" || return 1; }
    _gw_docker_ok || { _gw_refuse "$GW_ERR" "$fn" || return 1; }
    return 0
}

# -----------------------------------------------------------------------------
# Image
# -----------------------------------------------------------------------------

# gw_image_allowed IMAGE NETWORK -- rc 0 when the trust rule of contract 3.4
# takes IMAGE on NETWORK; rc 1 with GW_ERR. No output.
gw_image_allowed() {
    local img="${1:-}" net="${2:-}" pin="" repo re
    GW_ERR=""
    case "$net" in
        devnet) ;;
        # network-gated: testnet runs only its pin
        testnet) pin="$GW_TESTNET_IMAGE_PIN" ;;
        # network-gated: mainnet runs only its pin
        mainnet) pin="$GW_MAINNET_IMAGE_PIN" ;;
        *) GW_ERR="unknown network '${net}' (testnet, mainnet or devnet)"; return 1 ;;
    esac
    if [[ "$net" != "devnet" && -z "$pin" ]]; then
        GW_ERR="this scripts release pins no worker-gateway image for ${net}"
        return 1
    fi
    if [[ -z "$img" ]]; then
        GW_ERR="give the worker-gateway image as --image <repository>@sha256:<digest>"
        return 1
    fi
    re="^[${_GW_LOWER}${_GW_DIGITS}][${_GW_LOWER}${_GW_DIGITS}._/-]*@sha256:[${_GW_DIGITS}abcdef]{64}$"
    if [[ ! "$img" =~ $re ]]; then
        GW_ERR="image refused: ${img} (only <repository>@sha256:<64 lowercase hex> is taken; tags are refused)"
        return 1
    fi
    repo="${img%@sha256:*}"
    if [[ "$net" == "devnet" ]]; then
        case " ${GW_DEVNET_IMAGE_REPOS} " in *" ${repo} "*) return 0 ;; esac
        GW_ERR="image refused: devnet takes the worker gateway only from ${GW_DEVNET_IMAGE_REPOS}"
        return 1
    fi
    if [[ "$img" != "$pin" ]]; then
        GW_ERR="image refused: ${net} runs only the worker-gateway image this scripts release pins (${pin})"
        return 1
    fi
    return 0
}

# gw_image_ensure IMAGE [FN] -- docker holds IMAGE by digest, pulling it when it
# does not. rc 0; rc 1 unavailable (GW_ERR).
gw_image_ensure() {
    local img="${1:-}" fn="${2:-}"
    GW_ERR=""
    if tn_docker_holds_digest "$img" >/dev/null 2>&1; then
        return 0
    fi
    _gw_say step "Pulling the worker-gateway image ${img}" "$fn"
    if ! docker pull "$img" >/dev/null 2>&1; then
        GW_ERR="docker pull of the worker-gateway image failed (${img})"
        return 1
    fi
    if ! tn_docker_holds_digest "$img" >/dev/null 2>&1; then
        GW_ERR="docker holds no image with digest ${img#*@} after the pull"
        return 1
    fi
    return 0
}

# gw_image_probe IMAGE [FN] -- run the image's --help offline and unprivileged
# and need every flag of GW_REQUIRED_FLAGS in it. rc 0/1 (GW_ERR).
gw_image_probe() {
    local img="${1:-}" fn="${2:-}" out f re missing=""
    GW_ERR=""
    if ! out="$(docker run --rm --network=none --read-only --cap-drop ALL --user 1101:1101 \
                --pull=never "$img" --help 2>&1)"; then
        GW_ERR="the worker-gateway image did not run its --help (${img})"
        return 1
    fi
    for f in $GW_REQUIRED_FLAGS; do
        re="(^|[^${_GW_ALNUM}-])${f}([^${_GW_ALNUM}-]|$)"
        [[ "$out" =~ $re ]] || missing="${missing:+${missing} }${f}"
    done
    if [[ -n "$missing" ]]; then
        GW_ERR="the image's --help lacks ${missing}: not a worker gateway this release can run"
        return 1
    fi
    _gw_say log "The image's --help lists every flag the unit passes." "$fn"
    return 0
}

# -----------------------------------------------------------------------------
# Rendering (from GW_V_*)
# -----------------------------------------------------------------------------

# gw_render_args -- the gateway's argument line, one line.
gw_render_args() {
    local a="127.0.0.1:${GW_V_LISTEN_PORT}"
    [[ "$GW_V_FRONT" != "none" ]] || a="0.0.0.0:${GW_V_LISTEN_PORT}"
    printf '%s' "--listen-addr ${a} --probe-addr 127.0.0.1:${GW_V_PROBE_PORT}" \
        " --metrics 127.0.0.1:${GW_V_METRICS_PORT}" \
        " --upstream-rpc-url http://${GW_V_UPSTREAM_HOST}:${GW_V_RPC_PORT}" \
        " --upstream-readiness-url http://${GW_V_UPSTREAM_HOST}:${GW_V_HEALTH_PORT}/health/workers" \
        " --worker-id 0 --redirect-queries ${GW_V_REDIRECT}"
    [[ -z "$GW_V_TRUSTED_PROXIES" ]] || printf ' --trusted-proxies %s' "$GW_V_TRUSTED_PROXIES"
    printf '\n'
}

# gw_unit_text -- the systemd unit. Real paths only; no version line, so a
# scripts update alone does not count as a change.
gw_unit_text() {
    local d args
    d="$(_gw_docker_bin)"
    args="$(gw_render_args)"
    printf '%s\n' \
        "# Written by setup-gateway.sh. Change it with setup-gateway.sh, not by hand." \
        "[Unit]" \
        "Description=Telcoin worker gateway (${GW_V_MODE}, front ${GW_V_FRONT})" \
        "After=network-online.target docker.service" \
        "Wants=network-online.target" \
        "Requires=docker.service" \
        "" \
        "[Service]" \
        "Type=simple" \
        "ExecStartPre=-${d} rm -f ${TN_GATEWAY_CONTAINER}" \
        "ExecStart=${d} run --rm --name ${TN_GATEWAY_CONTAINER} --network=host --user 1101:1101 --read-only --cap-drop ALL --security-opt no-new-privileges --pull=never --stop-timeout 60 ${GW_V_IMAGE} ${args}" \
        "ExecStop=${d} stop -t 60 ${TN_GATEWAY_CONTAINER}" \
        "Restart=on-failure" \
        "RestartSec=5" \
        "TimeoutStopSec=75" \
        "" \
        "[Install]" \
        "WantedBy=multi-user.target"
}

# _gw_meta_lines -- gateway.meta as GW_V_* say it should be, KEY=value lines.
_gw_meta_lines() {
    printf '%s\n' "GATEWAY_META_VERSION=1" "NETWORK=${GW_V_NETWORK}" "MODE=${GW_V_MODE}" \
        "FRONT=${GW_V_FRONT}" "DOMAIN=${GW_V_DOMAIN}" "IMAGE=${GW_V_IMAGE}" \
        "UPSTREAM_HOST=${GW_V_UPSTREAM_HOST}" "RPC_PORT=${GW_V_RPC_PORT}" \
        "HEALTH_PORT=${GW_V_HEALTH_PORT}" "LISTEN_PORT=${GW_V_LISTEN_PORT}" \
        "PROBE_PORT=${GW_V_PROBE_PORT}" "METRICS_PORT=${GW_V_METRICS_PORT}" \
        "REDIRECT_QUERIES=${GW_V_REDIRECT}" "TRUSTED_PROXIES=${GW_V_TRUSTED_PROXIES}"
}

# _gw_meta_diff -- the lines of _gw_meta_lines that gateway.meta does not hold
# (absent, different, or on more than one line).
_gw_meta_diff() {
    local line key have rc
    while IFS= read -r line; do
        key="${line%%=*}"
        rc=0
        have="$(tn_gateway_meta_get "$key" "$_GW_ABSENT" 2>/dev/null)" || rc=$?
        if [[ "$rc" -ne 0 || "$have" != "${line#*=}" ]]; then
            printf '%s\n' "$line"
        fi
    done < <(_gw_meta_lines)
}

# _gw_load_meta -- GW_V_* from gateway.meta. rc 0; 1 a key is missing or a value
# is not one this library writes; 2 a key is on more than one line (GW_ERR).
_gw_load_meta() {
    local k v rc s missing=""
    for k in NETWORK MODE FRONT DOMAIN IMAGE UPSTREAM_HOST RPC_PORT HEALTH_PORT LISTEN_PORT \
             PROBE_PORT METRICS_PORT REDIRECT_QUERIES TRUSTED_PROXIES; do
        rc=0
        v="$(tn_gateway_meta_get "$k" "$_GW_ABSENT" 2>/dev/null)" || rc=$?
        if [[ "$rc" -eq 2 ]]; then
            GW_ERR="${TN_GATEWAY_META} holds ${k} more than once"
            return 2
        fi
        if [[ "$rc" -ne 0 || "$v" == "$_GW_ABSENT" ]]; then
            missing="${missing:+${missing} }${k}"
            v=""
        fi
        s="$k"
        [[ "$k" != "REDIRECT_QUERIES" ]] || s="REDIRECT"
        printf -v "GW_V_${s}" '%s' "$v"
    done
    GW_V_UPSTREAM=""
    [[ "$GW_V_MODE" != "standalone" ]] || GW_V_UPSTREAM="$GW_V_UPSTREAM_HOST"
    if [[ -n "$missing" ]]; then
        GW_ERR="${TN_GATEWAY_META} lacks ${missing}"
        return 1
    fi
    for v in "$GW_V_RPC_PORT" "$GW_V_HEALTH_PORT" "$GW_V_LISTEN_PORT" "$GW_V_PROBE_PORT" "$GW_V_METRICS_PORT"; do
        _gw_port_ok "$v" || { GW_ERR="${TN_GATEWAY_META} holds an invalid port (${v})"; return 1; }
    done
    if ! _gw_network_ok "$GW_V_NETWORK" || ! _tn_ipv4_strict "$GW_V_UPSTREAM_HOST" \
        || ! _gw_redirect_ok "$GW_V_REDIRECT" \
        || { [[ -n "$GW_V_TRUSTED_PROXIES" ]] && ! _gw_proxies_ok "$GW_V_TRUSTED_PROXIES"; }; then
        GW_ERR="${TN_GATEWAY_META} holds a value this release does not write"
        return 1
    fi
    case "${GW_V_MODE}/${GW_V_FRONT}" in
        same-host/caddy|same-host/none|standalone/caddy|standalone/none) ;;
        *) GW_ERR="${TN_GATEWAY_META} holds an invalid MODE or FRONT"; return 1 ;;
    esac
    return 0
}

# _gw_unit_word FILE FLAG -- the word after FLAG on FILE's ExecStart= line.
_gw_unit_word() {
    awk -v f="$2" '/^ExecStart=/ { for (i = 1; i < NF; i++) if ($i == f) { print $(i + 1); exit } }' "$1" 2>/dev/null
}

# _gw_load_unit -- GW_V_* from the unit file (readable without root): what
# gw_status shows when gateway.meta cannot be read. rc 1 no readable unit.
_gw_load_unit() {
    local f la ru rr
    f="$(gw_unit_path)"
    [[ -r "$f" ]] || return 1
    la="$(_gw_unit_word "$f" --listen-addr)"
    ru="$(_gw_unit_word "$f" --upstream-rpc-url)"
    rr="$(_gw_unit_word "$f" --upstream-readiness-url)"
    GW_V_LISTEN_PORT="${la##*:}"
    GW_V_FRONT="caddy"
    [[ "$la" != 0.0.0.0:* ]] || GW_V_FRONT="none"
    GW_V_PROBE_PORT="$(_gw_unit_word "$f" --probe-addr)"
    GW_V_PROBE_PORT="${GW_V_PROBE_PORT##*:}"
    GW_V_METRICS_PORT="$(_gw_unit_word "$f" --metrics)"
    GW_V_METRICS_PORT="${GW_V_METRICS_PORT##*:}"
    ru="${ru#http://}"
    GW_V_UPSTREAM_HOST="${ru%%:*}"
    GW_V_RPC_PORT="${ru##*:}"
    rr="${rr#http://*:}"
    GW_V_HEALTH_PORT="${rr%%/*}"
    GW_V_MODE="standalone"
    [[ "$GW_V_UPSTREAM_HOST" != "127.0.0.1" ]] || GW_V_MODE="same-host"
    GW_V_REDIRECT="$(_gw_unit_word "$f" --redirect-queries)"
    GW_V_TRUSTED_PROXIES="$(_gw_unit_word "$f" --trusted-proxies)"
    GW_V_IMAGE="$(awk '/^ExecStart=/ { for (i = 1; i < NF - 1; i++) if ($i == "--stop-timeout") { print $(i + 2); exit } }' "$f" 2>/dev/null)"
    GW_V_DOMAIN="" GW_V_NETWORK=""
    return 0
}

# -----------------------------------------------------------------------------
# Change and put back
# -----------------------------------------------------------------------------

_gw_reset_undo() {
    _GW_WAS_ENABLED=0 _GW_WAS_ACTIVE=0 _GW_DID_ENABLE=0 _GW_DID_START=0 _GW_WROTE_UNIT=0
    _GW_WROTE_META=0 _GW_MADE_DIR=0 _GW_MADE_PARENT=0 _GW_BK_UNIT="" _GW_BK_UNIT_SUM="" _GW_BK_META=""
    _GW_BK_META_SUM="" _GW_PUTBACK_ERR=""
}

_gw_unit_enabled() { systemctl is-enabled --quiet "$TN_GATEWAY_UNIT" >/dev/null 2>&1; }
_gw_unit_active()  { systemctl is-active --quiet "$TN_GATEWAY_UNIT" >/dev/null 2>&1; }
_gw_container_present() { docker container inspect "$TN_GATEWAY_CONTAINER" >/dev/null 2>&1; }
_gw_http_ok() { curl -fsS -o /dev/null --max-time 2 --noproxy '*' "$1" >/dev/null 2>&1; }

# _gw_file_is FILE TEXT -- rc 0 when FILE is a regular file holding TEXT and one
# newline (what tn_write_root_file writes from a here-string).
_gw_file_is() {
    local cur
    [[ -f "$1" && ! -L "$1" ]] || return 1
    cur="$(cat -- "$1" 2>/dev/null && printf x)" || return 1
    [[ "${cur%x}" == "${2}"$'\n' ]]
}

_gw_sum() {
    if [[ -f "$1" ]]; then cksum < "$1" 2>/dev/null || printf 'unreadable\n'; else printf 'absent\n'; fi
}

# _gw_wait_health PORT -- GET /health on 127.0.0.1:PORT answers 200 within
# GW_HEALTH_WAIT seconds.
_gw_wait_health() {
    local i=0
    while [[ "$i" -lt "$GW_HEALTH_WAIT" ]]; do
        _gw_http_ok "http://127.0.0.1:${1}/health" && return 0
        sleep 1
        i=$((i + 1))
    done
    _gw_http_ok "http://127.0.0.1:${1}/health"
}

# _gw_lock -- take the update lock unless this run holds it (_GW_TOOK_LOCK=1
# when this call took it). rc 1 another run holds it (GW_ERR).
_gw_lock() {
    _GW_TOOK_LOCK=0
    [[ -z "${TN_UPDATE_LOCK_KIND:-}" ]] || return 0
    if ! addon_meta_lock >/dev/null 2>&1; then
        GW_ERR="another node operation holds the update lock; run this again when it has finished"
        return 1
    fi
    _GW_TOOK_LOCK=1
    return 0
}

_gw_unlock() {
    if [[ "$_GW_TOOK_LOCK" == 1 ]]; then
        tn_release_update_lock
        _GW_TOOK_LOCK=0
    fi
    return 0
}

_gw_baseline() {
    if declare -F tn_host_baseline_refresh >/dev/null 2>&1; then
        tn_host_baseline_refresh "${1:-}" || true
    fi
    return 0
}

# _gw_putback [FN] -- undo what the change in progress did (the _GW_* state):
# stop a gateway this run started, disable what it enabled, put the unit and
# gateway.meta back (or remove them when there were none), start the previous
# gateway again when it ran before. rc 0; rc 1 something could not be put back
# (_GW_PUTBACK_ERR).
_gw_putback() {
    local unit meta dir why=""
    unit="$(gw_unit_path)"
    meta="$(gw_meta_file)"
    dir="$(gw_etc_dir)"
    if [[ "$_GW_DID_START" == 1 && "$_GW_WAS_ACTIVE" == 0 ]]; then
        systemctl stop "$TN_GATEWAY_UNIT" >/dev/null 2>&1 || why="${why}the gateway did not stop; "
        docker rm -f "$TN_GATEWAY_CONTAINER" >/dev/null 2>&1 || true
    fi
    if [[ "$_GW_DID_ENABLE" == 1 ]]; then
        systemctl disable "$TN_GATEWAY_UNIT" >/dev/null 2>&1 || why="${why}the unit is still enabled; "
    fi
    if [[ "$_GW_WROTE_UNIT" == 1 ]]; then
        if [[ -n "$_GW_BK_UNIT" ]]; then
            tn_restore_backup "$_GW_BK_UNIT" "$_GW_BK_UNIT_SUM" "$unit" 0644 >/dev/null 2>&1 \
                || why="${why}the previous unit was not restored (backup ${_GW_BK_UNIT}); "
        else
            rm -f -- "$unit" 2>/dev/null || why="${why}the new unit was not removed; "
        fi
    fi
    if [[ "$_GW_WROTE_META" == 1 ]]; then
        if [[ -n "$_GW_BK_META" ]]; then
            tn_restore_backup "$_GW_BK_META" "$_GW_BK_META_SUM" "$meta" 0600 >/dev/null 2>&1 \
                || why="${why}the previous gateway.meta was not restored (backup ${_GW_BK_META}); "
        else
            rm -f -- "$meta" 2>/dev/null || why="${why}the new gateway.meta was not removed; "
        fi
    fi
    if [[ "$_GW_MADE_DIR" == 1 && -d "$dir" ]]; then
        rm -f -- "$dir"/.tn.* 2>/dev/null || true
        rmdir -- "$dir" 2>/dev/null || why="${why}${TN_GATEWAY_ETC_DIR} was not removed; "
    fi
    if [[ "$_GW_MADE_PARENT" == 1 && -d "${dir%/*}" ]]; then
        rmdir -- "${dir%/*}" 2>/dev/null || why="${why}${TN_GATEWAY_ETC_DIR%/*} was not removed; "
    fi
    if [[ "$_GW_WROTE_UNIT" == 1 ]]; then
        systemctl daemon-reload >/dev/null 2>&1 || why="${why}systemctl daemon-reload failed; "
    fi
    if [[ "$_GW_DID_START" == 1 && "$_GW_WAS_ACTIVE" == 1 ]]; then
        systemctl restart "$TN_GATEWAY_UNIT" >/dev/null 2>&1 || why="${why}the previous gateway did not start again; "
    fi
    _GW_PUTBACK_ERR="${why%; }"
    [[ -z "$why" ]]
}

# _gw_fail [FN] -- after the first change: put back, say why; rc 1 when the
# put-back worked, 2 when it did not. Never rc 0 (callers write
# `_gw_fail "$fn" || return $?`).
_gw_fail() {
    local fn="${1:-}"
    if _gw_putback "$fn"; then
        _gw_reset_undo
        _gw_say error "${GW_ERR}. What this run changed was put back. Nothing was changed." "$fn"
        return 1
    fi
    GW_ERR="${GW_ERR}; putting the previous state back failed too: ${_GW_PUTBACK_ERR}"
    _gw_reset_undo
    _gw_say error "${GW_ERR}. Run setup-gateway.sh --status." "$fn"
    return 2
}

# _gw_apply FN WORD -- install what GW_V_* describe. When the unit text and
# gateway.meta are what is installed and the unit is enabled and active,
# nothing is written or restarted (GW_APPLIED stays ""). Else: back up, write
# the changed gateway.meta keys and the unit, daemon-reload, enable, restart the
# gateway (only when its unit changed or it was not running) and wait for its
# /health; GW_APPLIED=WORD. The put-back state stays set for the caller's next
# step. rc 0/1/2 as _gw_fail.
_gw_apply() {
    local fn="${1:-}" word="${2:-enabled}" unit meta dir text diff out line unit_same=0
    unit="$(gw_unit_path)"
    meta="$(gw_meta_file)"
    dir="$(gw_etc_dir)"
    _gw_reset_undo
    text="$(gw_unit_text)"
    diff="$(_gw_meta_diff)"
    if _gw_file_is "$unit" "$text"; then unit_same=1; fi
    if _gw_unit_enabled; then _GW_WAS_ENABLED=1; fi
    if _gw_unit_active; then _GW_WAS_ACTIVE=1; fi
    if [[ "$unit_same" == 1 && -z "$diff" && "$_GW_WAS_ENABLED" == 1 && "$_GW_WAS_ACTIVE" == 1 ]]; then
        _gw_say log "The worker gateway already runs with these settings; it was not restarted." "$fn"
        return 0
    fi

    if [[ -n "$diff" && -e "$meta" ]]; then
        out="$(tn_backup_file "$meta" gateway.meta 2>/dev/null)" \
            || { _gw_refuse "could not back up ${TN_GATEWAY_META}" "$fn" || return 1; }
        _GW_BK_META="${out% *}" _GW_BK_META_SUM="${out##* }"
    fi
    if [[ "$unit_same" == 0 && -e "$unit" ]]; then
        out="$(tn_backup_file "$unit" "$TN_GATEWAY_UNIT" 2>/dev/null)" \
            || { _gw_refuse "could not back up ${TN_GATEWAY_UNIT}" "$fn" || return 1; }
        _GW_BK_UNIT="${out% *}" _GW_BK_UNIT_SUM="${out##* }"
    fi

    _gw_say step "Installing the worker gateway (${GW_V_MODE}, front ${GW_V_FRONT})" "$fn"
    if [[ ! -d "${dir%/*}" ]]; then
        _GW_MADE_PARENT=1
        _tn_root_layout_dir "${dir%/*}" root 0755 >/dev/null 2>&1 \
            || { GW_ERR="could not create ${TN_GATEWAY_ETC_DIR%/*}"; _gw_fail "$fn" || return $?; }
    fi
    if [[ ! -d "$dir" ]]; then
        _GW_MADE_DIR=1
        _tn_root_layout_dir "$dir" root 0755 >/dev/null 2>&1 \
            || { GW_ERR="could not create ${TN_GATEWAY_ETC_DIR}"; _gw_fail "$fn" || return $?; }
    fi
    if [[ -n "$diff" ]]; then
        _GW_WROTE_META=1
        while IFS= read -r line; do
            meta_set "${line%%=*}" "${line#*=}" "$meta" >/dev/null 2>&1 \
                || { GW_ERR="could not write ${TN_GATEWAY_META}"; _gw_fail "$fn" || return $?; }
        done <<< "$diff"
    fi
    if [[ "$unit_same" == 0 ]]; then
        _GW_WROTE_UNIT=1
        tn_write_root_file "$unit" 0644 <<< "$text" >/dev/null 2>&1 \
            || { GW_ERR="could not write ${TN_GATEWAY_UNIT}"; _gw_fail "$fn" || return $?; }
        systemctl daemon-reload >/dev/null 2>&1 \
            || { GW_ERR="systemctl daemon-reload failed"; _gw_fail "$fn" || return $?; }
    fi
    if [[ "$_GW_WAS_ENABLED" == 0 ]]; then
        _GW_DID_ENABLE=1
        systemctl enable "$TN_GATEWAY_UNIT" >/dev/null 2>&1 \
            || { GW_ERR="systemctl enable ${TN_GATEWAY_UNIT} failed"; _gw_fail "$fn" || return $?; }
    fi
    if [[ "$unit_same" == 0 || "$_GW_WAS_ACTIVE" == 0 ]]; then
        _GW_DID_START=1
        systemctl restart "$TN_GATEWAY_UNIT" >/dev/null 2>&1 \
            || { GW_ERR="${TN_GATEWAY_UNIT} did not start (see journalctl -u ${TN_GATEWAY_UNIT})"; _gw_fail "$fn" || return $?; }
        _gw_say step "Waiting up to ${GW_HEALTH_WAIT} s for the gateway's /health" "$fn"
        _gw_wait_health "$GW_V_PROBE_PORT" \
            || { GW_ERR="the gateway did not answer GET /health on 127.0.0.1:${GW_V_PROBE_PORT} within ${GW_HEALTH_WAIT} s (see journalctl -u ${TN_GATEWAY_UNIT})"; _gw_fail "$fn" || return $?; }
    fi
    GW_APPLIED="$word"
    return 0
}

# _gw_json_msg LINE -- the "msg" string of one JSON event line (escaped quotes
# turned back), or nothing.
_gw_json_msg() {
    printf '%s\n' "$1" | sed -nE 's/.*"msg"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' \
        | sed -e 's/\\"/"/g' || true
}

# _gw_caddy FN PHASE [ARG...] -- run install-caddy.sh --json --phase PHASE ARG...
# and judge its last done line (events come on its fd 3, which it points at its
# stdout; its human text goes to stderr and is let through). Its warn and error
# events are said through FN. _GW_CADDY_CHANGED=1 when the Caddyfile changed.
# rc 0 ok (also skipped: GW_CADDY_SCRIPT empty); 1 it refused or failed (it puts
# its own files back); 2 it ended without a done line (state unknown).
_GW_CADDY_CHANGED=0
_gw_caddy() {
    local fn="$1" phase="$2" out="" crc=0 line done_line="" msg cf before re
    shift 2
    _GW_CADDY_CHANGED=0
    if [[ -z "$GW_CADDY_SCRIPT" ]]; then
        _gw_say warn "The Caddy step was skipped (no install-caddy.sh given): run install-caddy.sh --phase ${phase} yourself." "$fn"
        return 0
    fi
    if [[ ! -f "$GW_CADDY_SCRIPT" ]]; then
        GW_ERR="install-caddy.sh not found (${GW_CADDY_SCRIPT})"
        return 1
    fi
    cf="$(_gw_caddyfile)"
    before="$(_gw_sum "$cf")"
    _gw_say step "Caddy: install-caddy.sh --phase ${phase}" "$fn"
    out="$(bash "$GW_CADDY_SCRIPT" --json --phase "$phase" "$@" 3>&1 </dev/null)" || crc=$?
    [[ "$(_gw_sum "$cf")" == "$before" ]] || _GW_CADDY_CHANGED=1
    re='"event"[[:space:]]*:[[:space:]]*"(warn|error|done)"'
    while IFS= read -r line; do
        [[ "$line" =~ $re ]] || continue
        case "${BASH_REMATCH[1]}" in
            done) done_line="$line" ;;
            *) msg="$(_gw_json_msg "$line")"; [[ -z "$msg" ]] || _gw_say warn "Caddy: ${msg}" "$fn" ;;
        esac
    done <<< "$out"
    if [[ -z "$done_line" ]]; then
        GW_ERR="install-caddy.sh --phase ${phase} ended without a result (exit ${crc}); check the Caddy block with install-caddy.sh --phase gateway-status"
        return 2
    fi
    msg="$(_gw_json_msg "$done_line")"
    re='"ok"[[:space:]]*:[[:space:]]*true'
    if [[ "$done_line" =~ $re ]]; then
        [[ -z "$msg" ]] || _gw_say log "Caddy: ${msg}" "$fn"
        return 0
    fi
    GW_ERR="install-caddy.sh --phase ${phase} failed${msg:+: ${msg}}"
    return 1
}

_gw_caddy_block_present() {
    local cf
    cf="$(_gw_caddyfile)"
    [[ -r "$cf" ]] && grep -qF -- "$TN_CADDY_GW_BEGIN" "$cf" 2>/dev/null
}

# _gw_summary -- one line of what runs, from GW_V_*.
_gw_summary() {
    local a="127.0.0.1"
    [[ "$GW_V_FRONT" != "none" ]] || a="0.0.0.0"
    printf '%s\n' "listen ${a}:${GW_V_LISTEN_PORT}${GW_V_DOMAIN:+ (https://${GW_V_DOMAIN}/ through Caddy)}, worker http://${GW_V_UPSTREAM_HOST}:${GW_V_RPC_PORT}, queries to ${GW_V_REDIRECT}"
}

# -----------------------------------------------------------------------------
# Enable, refresh, remove
# -----------------------------------------------------------------------------

# gw_enable [FN] -- validate, check the image (trust, pull, --help probe),
# install or change the gateway (_gw_apply), then with front caddy run
# install-caddy.sh --phase gateway-enable (itself a no-op when its block is
# current); a gateway that moves from caddy to none gets gateway-disable. Any
# failure after the first write puts the previous state back. rc 0/1/2.
gw_enable() {
    local fn="${1:-}" rc=0
    GW_ERR="" GW_APPLIED=""
    _gw_is_root || { _gw_refuse "setup-gateway.sh --enable needs root (run it with sudo)" "$fn" || return 1; }
    _gw_lock || { _gw_refuse "$GW_ERR" "$fn" || return 1; }
    _gw_enable_locked "$fn" || rc=$?
    _gw_unlock
    return "$rc"
}

_gw_enable_locked() {
    local fn="${1:-}" prev_front="" r
    gw_validate_inputs "$fn" || return 1
    gw_image_ensure "$GW_V_IMAGE" "$fn" || { _gw_refuse "$GW_ERR" "$fn" || return 1; }
    gw_image_probe "$GW_V_IMAGE" "$fn" || { _gw_refuse "$GW_ERR" "$fn" || return 1; }
    if tn_gateway_installed; then
        prev_front="$(tn_gateway_meta_get FRONT "" 2>/dev/null)" || prev_front=""
    fi
    _gw_apply "$fn" enabled || return $?
    r=0
    if [[ "$GW_V_FRONT" == "caddy" ]]; then
        _gw_caddy "$fn" gateway-enable --gateway-domain "$GW_V_DOMAIN" \
            --gateway-port "$GW_V_LISTEN_PORT" --gateway-probe-port "$GW_V_PROBE_PORT" || r=$?
    elif [[ "$prev_front" == "caddy" ]] || _gw_caddy_block_present; then
        _gw_caddy "$fn" gateway-disable || r=$?
    fi
    if [[ "$r" -ne 0 ]]; then
        if [[ "$r" -eq 2 ]]; then
            _gw_putback "$fn" || GW_ERR="${GW_ERR}; putting the gateway back failed too: ${_GW_PUTBACK_ERR}"
            _gw_reset_undo
            _gw_say error "${GW_ERR}." "$fn"
            return 2
        fi
        _gw_fail "$fn" || return $?
    fi
    _gw_reset_undo
    [[ "$_GW_CADDY_CHANGED" == 0 ]] || GW_APPLIED="${GW_APPLIED:+${GW_APPLIED} }caddy"
    if [[ -z "$GW_APPLIED" ]]; then
        _gw_say ok "The worker gateway is enabled and current; nothing had to change. The node was not restarted." "$fn"
        return 0
    fi
    _gw_baseline "$fn"
    _gw_say ok "The worker gateway is enabled: $(_gw_summary). The node was not restarted." "$fn"
    return 0
}

# gw_refresh [FN] -- re-render the gateway from gateway.meta (a non-empty
# GW_IN_IMAGE replaces IMAGE, after the trust rule, pull and probe), with the
# same no-op rule as gw_enable; restarts the gateway unit only. rc 0/1/2.
gw_refresh() {
    local fn="${1:-}" rc=0
    GW_ERR="" GW_APPLIED=""
    _gw_is_root || { _gw_refuse "setup-gateway.sh --refresh needs root (run it with sudo)" "$fn" || return 1; }
    _gw_lock || { _gw_refuse "$GW_ERR" "$fn" || return 1; }
    _gw_refresh_locked "$fn" || rc=$?
    _gw_unlock
    return "$rc"
}

_gw_refresh_locked() {
    local fn="${1:-}" rc=0
    tn_gateway_installed || { _gw_refuse "the worker gateway is not installed (enable it with setup-gateway.sh --enable)" "$fn" || return 1; }
    _gw_load_meta || rc=$?
    [[ "$rc" -eq 0 ]] || { _gw_refuse "${GW_ERR}; run setup-gateway.sh --enable again with the settings you want" "$fn" || return 1; }
    [[ -z "$GW_IN_IMAGE" ]] || GW_V_IMAGE="$GW_IN_IMAGE"
    gw_image_allowed "$GW_V_IMAGE" "$GW_V_NETWORK" || { _gw_refuse "$GW_ERR" "$fn" || return 1; }
    _gw_docker_ok || { _gw_refuse "$GW_ERR" "$fn" || return 1; }
    gw_image_ensure "$GW_V_IMAGE" "$fn" || { _gw_refuse "$GW_ERR" "$fn" || return 1; }
    gw_image_probe "$GW_V_IMAGE" "$fn" || { _gw_refuse "$GW_ERR" "$fn" || return 1; }
    _gw_apply "$fn" refreshed || return $?
    _gw_reset_undo
    if [[ -z "$GW_APPLIED" ]]; then
        _gw_say ok "The worker gateway is current; nothing had to change." "$fn"
        return 0
    fi
    _gw_baseline "$fn"
    _gw_say ok "The worker gateway was refreshed: $(_gw_summary). The node was not restarted." "$fn"
    return 0
}

# gw_remove [FN] -- with a Caddy block (front caddy), install-caddy.sh --phase
# gateway-disable first (while gateway.meta still exists, which its gate needs);
# then disable and stop the unit, remove the unit, the container and
# /etc/telcoin/gateway. The image stays. rc 0; 1 refused (nothing changed); 2
# something is left (GW_ERR names it).
gw_remove() {
    local fn="${1:-}" rc=0
    GW_ERR="" GW_APPLIED=""
    _gw_is_root || { _gw_refuse "setup-gateway.sh --remove needs root (run it with sudo)" "$fn" || return 1; }
    _gw_lock || { _gw_refuse "$GW_ERR" "$fn" || return 1; }
    _gw_remove_locked "$fn" || rc=$?
    _gw_unlock
    return "$rc"
}

_gw_remove_locked() {
    local fn="${1:-}" unit meta dir front="" img="" r=0 left=""
    unit="$(gw_unit_path)"
    meta="$(gw_meta_file)"
    dir="$(gw_etc_dir)"
    if tn_gateway_installed; then
        front="$(tn_gateway_meta_get FRONT "" 2>/dev/null)" || front=""
        img="$(tn_gateway_meta_get IMAGE "" 2>/dev/null)" || img=""
    fi
    if ! tn_gateway_installed && [[ ! -e "$unit" && ! -e "$dir" ]] && ! _gw_caddy_block_present \
        && ! _gw_container_present; then
        _gw_say ok "The worker gateway is not installed; nothing to remove." "$fn"
        return 0
    fi
    if [[ "$front" == "caddy" ]] || _gw_caddy_block_present; then
        _gw_caddy "$fn" gateway-disable || r=$?
        if [[ "$r" -eq 1 ]]; then
            _gw_refuse "$GW_ERR" "$fn" || return 1
        elif [[ "$r" -ne 0 ]]; then
            _gw_say error "${GW_ERR}. The gateway itself was not removed." "$fn"
            return 2
        fi
    fi
    _gw_say step "Removing the worker gateway" "$fn"
    systemctl disable --now "$TN_GATEWAY_UNIT" >/dev/null 2>&1 || true
    systemctl stop "$TN_GATEWAY_UNIT" >/dev/null 2>&1 || true
    docker rm -f "$TN_GATEWAY_CONTAINER" >/dev/null 2>&1 || true
    rm -f -- "$unit" 2>/dev/null || true
    if [[ -d "$dir" && ! -L "$dir" ]]; then
        rm -f -- "$meta" "$dir"/.tn.* 2>/dev/null || true
        rmdir -- "$dir" 2>/dev/null || true
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed "$TN_GATEWAY_UNIT" >/dev/null 2>&1 || true
    [[ ! -e "$unit" ]] || left="${left}the unit file, "
    [[ ! -e "$dir" ]] || left="${left}${TN_GATEWAY_ETC_DIR}, "
    if _gw_unit_active; then left="${left}a running ${TN_GATEWAY_UNIT}, "; fi
    if _gw_container_present; then left="${left}the container ${TN_GATEWAY_CONTAINER}, "; fi
    if [[ -n "$left" ]]; then
        GW_ERR="the gateway was only partly removed; left: ${left%, }"
        _gw_say error "${GW_ERR}. Run setup-gateway.sh --remove again." "$fn"
        return 2
    fi
    GW_APPLIED="removed"
    _gw_baseline "$fn"
    _gw_say ok "The worker gateway is removed. Its image stays in docker${img:+ (remove it with: docker image rm ${img})}. The node was not touched." "$fn"
    return 0
}

# -----------------------------------------------------------------------------
# Status
# -----------------------------------------------------------------------------

_gw_issue() {
    _GW_NISSUES=$((_GW_NISSUES + 1))
    _gw_say warn "$1" "${2:-}"
    return 0
}

# gw_status [FN] -- fill GW_ST_* and say each issue with its fix. rc = number of
# issues (at most 20). Without root, gateway.meta (0600) cannot be read: the
# values then come from the unit file and the checks that need root (image held
# when docker refuses, drift against gateway.meta) are skipped, which is said.
gw_status() {
    local fn="${1:-}" unit lrc=0 root=0 a text
    GW_ERR=""
    _GW_NISSUES=0
    GW_ST_INSTALLED="false" GW_ST_ENABLED="false" GW_ST_ACTIVE="false" GW_ST_MODE="" GW_ST_FRONT=""
    GW_ST_DOMAIN="" GW_ST_IMAGE="" GW_ST_IMAGE_HELD="false" GW_ST_LISTEN="" GW_ST_PROBE=""
    GW_ST_METRICS="" GW_ST_UPSTREAM_RPC="" GW_ST_UPSTREAM_READINESS="" GW_ST_REDIRECT_QUERIES=""
    GW_ST_HEALTH="false" GW_ST_READY="false" GW_ST_READY_ANY="false" GW_ST_CADDY_BLOCK=""
    GW_ST_ISSUES=0 GW_ST_NETWORK=""
    unit="$(gw_unit_path)"
    if _gw_is_root; then root=1; fi
    if _gw_unit_enabled; then GW_ST_ENABLED="true"; fi
    if _gw_unit_active; then GW_ST_ACTIVE="true"; fi

    if ! tn_gateway_installed; then
        if [[ -e "$unit" || "$GW_ST_ACTIVE" == "true" ]]; then
            _gw_issue "A ${TN_GATEWAY_UNIT} is on this host without ${TN_GATEWAY_META}: remove it with setup-gateway.sh --remove" "$fn"
        fi
        _gw_say log "Worker gateway: not installed (enable it with setup-gateway.sh --enable)." "$fn"
        GW_ST_ISSUES="$_GW_NISSUES"
        return "$_GW_NISSUES"
    fi
    GW_ST_INSTALLED="true"

    if [[ -r "$(gw_meta_file)" ]]; then
        _gw_load_meta || lrc=$?
        if [[ "$lrc" -ne 0 ]]; then
            _gw_issue "${GW_ERR}: run setup-gateway.sh --enable again with the settings you want" "$fn"
            _gw_load_unit || true
        fi
    else
        lrc=3
        _gw_say log "Not root: ${TN_GATEWAY_META} cannot be read, so these values come from the unit file and the drift check is skipped." "$fn"
        _gw_load_unit || true
    fi
    GW_ST_NETWORK="$GW_V_NETWORK" GW_ST_MODE="$GW_V_MODE" GW_ST_FRONT="$GW_V_FRONT"
    GW_ST_DOMAIN="$GW_V_DOMAIN" GW_ST_IMAGE="$GW_V_IMAGE" GW_ST_REDIRECT_QUERIES="$GW_V_REDIRECT"
    a="127.0.0.1"
    [[ "$GW_V_FRONT" != "none" ]] || a="0.0.0.0"
    if [[ -n "$GW_V_LISTEN_PORT" ]]; then GW_ST_LISTEN="${a}:${GW_V_LISTEN_PORT}"; fi
    if [[ -n "$GW_V_PROBE_PORT" ]]; then GW_ST_PROBE="127.0.0.1:${GW_V_PROBE_PORT}"; fi
    if [[ -n "$GW_V_METRICS_PORT" ]]; then GW_ST_METRICS="127.0.0.1:${GW_V_METRICS_PORT}"; fi
    if [[ -n "$GW_V_UPSTREAM_HOST" ]]; then
        GW_ST_UPSTREAM_RPC="http://${GW_V_UPSTREAM_HOST}:${GW_V_RPC_PORT}"
        GW_ST_UPSTREAM_READINESS="http://${GW_V_UPSTREAM_HOST}:${GW_V_HEALTH_PORT}/health/workers"
    fi

    if [[ ! -f "$unit" ]]; then
        _gw_issue "The unit file ${TN_GATEWAY_UNIT} is missing: run setup-gateway.sh --refresh" "$fn"
    elif [[ "$lrc" -eq 0 ]]; then
        text="$(gw_unit_text)"
        _gw_file_is "$unit" "$text" \
            || _gw_issue "The unit differs from ${TN_GATEWAY_META}: run setup-gateway.sh --refresh" "$fn"
    fi
    [[ "$GW_ST_ENABLED" == "true" ]] \
        || _gw_issue "${TN_GATEWAY_UNIT} does not start at boot: run setup-gateway.sh --refresh" "$fn"
    [[ "$GW_ST_ACTIVE" == "true" ]] \
        || _gw_issue "${TN_GATEWAY_UNIT} is not running (see journalctl -u ${TN_GATEWAY_UNIT}); start it with setup-gateway.sh --refresh" "$fn"

    if [[ -n "$GW_V_PROBE_PORT" ]]; then
        if _gw_http_ok "http://127.0.0.1:${GW_V_PROBE_PORT}/health"; then GW_ST_HEALTH="true"; fi
        if _gw_http_ok "http://127.0.0.1:${GW_V_PROBE_PORT}/ready"; then GW_ST_READY="true"; fi
        if _gw_http_ok "http://127.0.0.1:${GW_V_PROBE_PORT}/ready/any"; then GW_ST_READY_ANY="true"; fi
    fi
    if [[ "$GW_ST_ACTIVE" == "true" && "$GW_ST_HEALTH" != "true" ]]; then
        _gw_issue "The gateway runs but GET /health on ${GW_ST_PROBE:-its probe port} does not answer 200 (see journalctl -u ${TN_GATEWAY_UNIT})" "$fn"
    fi
    if [[ "$GW_ST_HEALTH" == "true" && "$GW_ST_READY" != "true" ]]; then
        _gw_say log "The gateway's /ready is not 200: the worker at ${GW_ST_UPSTREAM_READINESS:-its upstream} is not accepting transactions (the node may be down or catching up); submissions get 503 until it is." "$fn"
    fi

    if [[ -n "$GW_V_IMAGE" ]]; then
        if tn_docker_holds_digest "$GW_V_IMAGE" >/dev/null 2>&1; then
            GW_ST_IMAGE_HELD="true"
        elif [[ "$root" == 1 ]] || docker info >/dev/null 2>&1; then
            _gw_issue "docker does not hold the gateway image ${GW_V_IMAGE}: run setup-gateway.sh --refresh" "$fn"
        else
            _gw_say log "Not root and docker refuses this user: the image check was skipped." "$fn"
        fi
    fi

    if [[ "$GW_V_FRONT" == "caddy" ]]; then
        if _gw_caddy_block_present; then
            GW_ST_CADDY_BLOCK="true"
        elif [[ -r "$(_gw_caddyfile)" ]]; then
            GW_ST_CADDY_BLOCK="false"
            _gw_issue "The Caddyfile has no tn-gateway block: run setup-gateway.sh --enable again" "$fn"
        else
            GW_ST_CADDY_BLOCK="false"
            _gw_say log "The Caddyfile cannot be read here: the Caddy block check was skipped." "$fn"
        fi
    elif _gw_caddy_block_present; then
        _gw_issue "A tn-gateway Caddy block is present although the gateway has front none: run install-caddy.sh --phase gateway-disable" "$fn"
    fi

    [[ "$_GW_NISSUES" -le 20 ]] || _GW_NISSUES=20
    GW_ST_ISSUES="$_GW_NISSUES"
    if [[ "$_GW_NISSUES" -eq 0 ]]; then
        _gw_say ok "Worker gateway: ${GW_ST_MODE}, front ${GW_ST_FRONT}, $([[ "$GW_ST_READY" == "true" ]] && printf 'ready' || printf 'not ready'); $(_gw_summary)." "$fn"
    fi
    return "$_GW_NISSUES"
}

: # gateway.sh sources with status 0
