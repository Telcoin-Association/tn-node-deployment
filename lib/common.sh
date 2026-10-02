#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — Shared helper functions for Telcoin node setup scripts
# =============================================================================

set -euo pipefail

# Legacy-install compatibility resolvers. Sourced near the top so every script
# that sources common.sh gets tn_resolve_service / tn_resolve_config_dir /
# tn_resolve_data_dir / ... for free. fallback.sh is the only module that
# knows the old telcoin-{observer,validator} names + per-role dir layout.
# shellcheck source=lib/fallback.sh
source "${BASH_SOURCE[0]%/*}/fallback.sh"

# -----------------------------------------------------------------------------
# CONSTANTS
# -----------------------------------------------------------------------------

readonly TESTNET_CHAIN_ID="2017"
readonly TESTNET_CHAIN_NAME="adiri"
readonly TESTNET_RPC_URL="https://rpc.adiri.tel"
readonly TESTNET_EXPLORER="https://telscan.io"

# Mainnet has not launched. The chain id matches chain-configs/mainnet/genesis.yaml
# in telcoin-network; the RPC URL is the planned public endpoint.
readonly MAINNET_CHAIN_ID="487"
readonly MAINNET_CHAIN_NAME="telcoin"
readonly MAINNET_RPC_URL="https://rpc.telcoin.network"
readonly MAINNET_EXPLORER="https://telscan.io"

readonly DEVNET_CHAIN_ID="32285"
readonly DEVNET_CHAIN_NAME="devnet"
# Devnet now has a global load balancer in front of all five nodes, so it has a
# canonical RPC URL exactly like testnet. Previously empty, which left setup-node.sh
# printing a blank "RPC" line to devnet operators. Still env-overridable.
readonly DEVNET_RPC_URL="${DEVNET_RPC_URL:-https://rpc.devnet.telcoin.network}"
readonly DEVNET_EXPLORER="${DEVNET_EXPLORER:-}"

readonly DEFAULT_P2P_PORT="49590"
readonly DEFAULT_WORKER_PORT="49594"
readonly DEFAULT_RPC_PORT="8545"
readonly DEFAULT_METRICS_PORT="9101"   # node loopback Prometheus endpoint (matches the adiri fleet)
readonly COMMON_VERSION="1.6.0"

# The operator runbook, for any message that should point operators at it.
readonly TN_OPERATOR_GUIDE_URL="https://github.com/Telcoin-Association/tn-node-deployment/blob/main/OPERATOR.md"

# Per-role hardware tiers (telcoin-network docs/src/getting-started/hardware-requirements.md,
# physical cores; cloud vCPUs are usually hyperthreads, so 8 vCPU ~ 4 physical cores).
readonly HW_NODE_MIN_CPU=2;  readonly HW_NODE_MIN_RAM_GB=8;  readonly HW_NODE_MIN_DISK_GB=2000   # observer (follower)
readonly HW_RPC_MIN_CPU=4;   readonly HW_RPC_MIN_RAM_GB=16; readonly HW_RPC_MIN_DISK_GB=2000    # observer serving public RPC
readonly HW_VAL_MIN_CPU=8;   readonly HW_VAL_MIN_RAM_GB=32; readonly HW_VAL_MIN_DISK_GB=2000    # validator minimum (ECC, NVMe)
readonly HW_VAL_REC_CPU=16;  readonly HW_VAL_REC_RAM_GB=64; readonly HW_VAL_REC_DISK_GB=4000    # validator recommended

# Set by check_hardware for callers that embed them in JSON log lines (plain ASCII).
TN_HW_SUMMARY=""
TN_HW_GAPS=""

readonly DEFAULT_INSTALL_DIR="/opt/telcoin"
readonly DEFAULT_DATA_DIR="/var/lib/telcoin"
readonly DEFAULT_LOG_DIR="/var/log/telcoin"
readonly DEFAULT_CONFIG_DIR="/etc/telcoin"
SERVICE_USER="telcoin"
SERVICE_GROUP="telcoin"

readonly TN_REPO="https://github.com/Telcoin-Association/telcoin-network.git"
readonly TN_SOURCE_DIR="/opt/telcoin-source"
readonly MIN_RUST_VERSION="1.75.0"

# Tag suffixes used by each Telcoin network. Used by source-build pickers to
# default to the right release for the network the operator selected.
#   testnet -> "-adiri"  (Adiri testnet)
#   mainnet -> "-telcoin" (placeholder; will be confirmed when mainnet launches)
#   devnet  -> follows main; no tag filter
readonly NETWORK_TAG_SUFFIX_TESTNET="-adiri"
readonly NETWORK_TAG_SUFFIX_MAINNET="-telcoin"

# Oldest release the source-build picker offers and tn_ref_min_check accepts.
# Older tags exist upstream but lack features these scripts rely on:
# `keytool set-rpc` and `keytool generate pop` arrived in v0.12.0-adiri and
# `--enable-state-export` in v0.13.0-adiri, so 0.13.0 is the first release with
# all three. main and custom refs stay available in the picker.
# Bump this when the Telcoin team retires a baseline.
readonly MIN_SOURCE_VERSION_TESTNET="0.13.0"
readonly MIN_SOURCE_VERSION_MAINNET=""  # mainnet not launched; no minimum yet

# -----------------------------------------------------------------------------
# COLOURS
# -----------------------------------------------------------------------------

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

# Disable colours if not outputting to a terminal (e.g. piped to a file)
if [[ ! -t 1 ]]; then
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; RESET=''
fi

# -----------------------------------------------------------------------------
# PRINT HELPERS
# -----------------------------------------------------------------------------

print_header() {
    echo ""
    echo "${BLUE}${BOLD}================================================================${RESET}"
    echo "${BLUE}${BOLD}  $1${RESET}"
    echo "${BLUE}${BOLD}================================================================${RESET}"
    echo ""
}

print_step() {
    echo ""
    echo "${CYAN}${BOLD}>>> $1${RESET}"
}

print_ok() {
    echo "  ${GREEN}[OK]${RESET}  $1"
}

print_warn() {
    echo "  ${YELLOW}[WARN]${RESET} $1"
}

print_error() {
    echo ""
    echo "  ${RED}${BOLD}[ERROR]${RESET} $1" >&2
    echo ""
}

print_info() {
    echo "  ->  $1"
}

print_sep() {
    echo "${BLUE}----------------------------------------------------------------${RESET}"
}

confirm() {
    local prompt="$1"
    # Non-interactive callers (e.g. the UI's --json setup) set TN_ASSUME_YES so
    # prompts auto-accept instead of blocking on a read with no stdin -- which,
    # under `set -e`, would otherwise silently skip the action (or exit).
    if [[ "${TN_ASSUME_YES:-false}" == "true" ]]; then
        return 0
    fi
    local response=""
    echo ""
    read -r -p "  ?  $prompt [y/N]: " response
    echo ""
    # Lowercase with tr: bash 4 case conversion breaks macOS /bin/bash 3.2.
    response="$(printf '%s' "$response" | tr '[:upper:]' '[:lower:]')"
    [[ "$response" =~ ^y ]]
}

# -----------------------------------------------------------------------------
# SYSTEM CHECKS
# -----------------------------------------------------------------------------

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root. Try: sudo $0"
        exit 1
    fi
    print_ok "Running as root"
}

# tn_acquire_update_lock -- one node-mutating update at a time.
#
# A UI-triggered `update-node.sh --json --apply` and a CLI run of the same
# script used to be able to run concurrently: double service stop, racing
# truncate-writes to .pending-update, and two binary/image swaps interleaving.
# Callers acquire this lock before any mutating mode (prepare/apply/discard,
# or the interactive menu) and simply exit on failure; read-only --check runs
# never take it.
#
# Primary path is flock(1) on /var/lock (present on every systemd host): fd 9
# is held open for the life of the process, so the kernel releases the lock on
# ANY exit -- crash, SIGKILL, reboot -- and stale locks are impossible. Where
# flock or /var/lock is missing (stock macOS), fall back to an atomic mkdir
# lock (mkdir fails on anything that already exists, symlinks included) with a
# PID-staleness takeover. On failure, TN_UPDATE_LOCK_HOLDER carries the
# holder's PID ("" if unknown) so JSON-mode callers can report it.
#
# The mkdir lock is removed by an EXIT trap. A caller that owns its own EXIT trap
# (one that emits the final JSON "done" event, say) sets TN_EXIT_TRAP_OWNED=1
# before calling, so the lock never replaces that trap; it then calls
# tn_release_update_lock from its own trap. TN_UPDATE_LOCK_DIR names the mkdir
# lock while it is held ("" on the flock path, where the kernel releases it).
TN_UPDATE_LOCK_HOLDER=""
TN_UPDATE_LOCK_DIR=""
tn_acquire_update_lock() {
    TN_UPDATE_LOCK_HOLDER=""
    TN_UPDATE_LOCK_DIR=""
    # Overridable for tests only; production callers always use the default.
    local lock_file="${TN_UPDATE_LOCK_FILE:-/var/lock/telcoin-update.lock}"
    local lock_parent="${lock_file%/*}"

    if command -v flock >/dev/null 2>&1 && [[ -d "$lock_parent" ]]; then
        # Append-mode open: must not truncate the PID a current holder wrote.
        if ! exec 9>>"$lock_file"; then
            print_error "Cannot open lock file ${lock_file} (are you root?)"
            return 1
        fi
        if ! flock -n 9; then
            TN_UPDATE_LOCK_HOLDER="$(cat "$lock_file" 2>/dev/null || true)"
            print_error "Another update is already running${TN_UPDATE_LOCK_HOLDER:+ (PID ${TN_UPDATE_LOCK_HOLDER})}."
            print_info "Wait for it to finish, or verify with: ps -fp ${TN_UPDATE_LOCK_HOLDER:-<pid>}"
            return 1
        fi
        printf '%s\n' "$$" > "$lock_file" 2>/dev/null || true
        return 0
    fi

    # mkdir fallback (no flock / no /var/lock). PID-staleness check replaces
    # the kernel's automatic release; the dir is removed on normal exit.
    local lock_dir="${TMPDIR:-/tmp}/telcoin-update.lock.d"
    if mkdir "$lock_dir" 2>/dev/null; then
        printf '%s\n' "$$" > "${lock_dir}/pid" 2>/dev/null || true
        TN_UPDATE_LOCK_DIR="$lock_dir"
        if [[ -z "${TN_EXIT_TRAP_OWNED:-}" ]]; then
            # Expand lock_dir now, not at exit time (intentional).
            # shellcheck disable=SC2064
            trap "rm -rf '${lock_dir}'" EXIT
        fi
        return 0
    fi
    TN_UPDATE_LOCK_HOLDER="$(cat "${lock_dir}/pid" 2>/dev/null || true)"
    if [[ -n "$TN_UPDATE_LOCK_HOLDER" ]] && ! kill -0 "$TN_UPDATE_LOCK_HOLDER" 2>/dev/null; then
        rm -rf "$lock_dir" 2>/dev/null
        if mkdir "$lock_dir" 2>/dev/null; then
            TN_UPDATE_LOCK_HOLDER=""
            printf '%s\n' "$$" > "${lock_dir}/pid" 2>/dev/null || true
            TN_UPDATE_LOCK_DIR="$lock_dir"
            if [[ -z "${TN_EXIT_TRAP_OWNED:-}" ]]; then
                # Expand lock_dir now, not at exit time (intentional).
                # shellcheck disable=SC2064
                trap "rm -rf '${lock_dir}'" EXIT
            fi
            return 0
        fi
    fi
    print_error "Another update is already running${TN_UPDATE_LOCK_HOLDER:+ (PID ${TN_UPDATE_LOCK_HOLDER})}."
    print_info "Wait for it to finish. Stale lock cleanup: rm -rf ${lock_dir}"
    return 1
}

# tn_release_update_lock — remove the mkdir lock this process holds (a no-op on
# the flock path and when no lock is held). For callers that set
# TN_EXIT_TRAP_OWNED and so must release the lock from their own EXIT trap.
# Never fails.
tn_release_update_lock() {
    local dir="${TN_UPDATE_LOCK_DIR:-}" holder
    [[ -n "$dir" && -d "$dir" ]] || return 0
    holder="$(cat "${dir}/pid" 2>/dev/null || true)"
    if [[ -z "$holder" || "$holder" == "$$" ]]; then
        rm -rf "$dir" 2>/dev/null || true
    fi
    TN_UPDATE_LOCK_DIR=""
    return 0
}

detect_distro() {
    print_step "Detecting operating system..."
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        DISTRO="${ID:-unknown}"
        DISTRO_VERSION="${VERSION_ID:-unknown}"
    else
        DISTRO="unknown"
        DISTRO_VERSION="unknown"
    fi

    if command -v apt-get &>/dev/null;   then PKG_MANAGER="apt"
    elif command -v dnf &>/dev/null;     then PKG_MANAGER="dnf"
    elif command -v yum &>/dev/null;     then PKG_MANAGER="yum"
    elif command -v pacman &>/dev/null;  then PKG_MANAGER="pacman"
    else                                      PKG_MANAGER="unknown"
    fi

    print_ok "OS: ${DISTRO} ${DISTRO_VERSION} (package manager: ${PKG_MANAGER})"
}

check_cve_2026_31431() {
    print_step "Checking CVE-2026-31431 (Copy Fail) mitigation..."

    local is_loaded is_blocked

    # Check if module is currently loaded
    if grep -qE '^algif_aead ' /proc/modules 2>/dev/null; then
        is_loaded="yes"
    else
        is_loaded="no"
    fi

    # Check if module is blocked -- search all modprobe config files directly
    if grep -rq "install algif_aead /bin/false" \
        /etc/modprobe.d/ \
        /lib/modprobe.d/ \
        /run/modprobe.d/ 2>/dev/null; then
        is_blocked="yes"
    else
        is_blocked="no"
    fi

    if [[ "$is_loaded" == "yes" ]] || [[ "$is_blocked" == "no" ]]; then
        echo ""
        print_error "CVE-2026-31431 (Copy Fail) -- setup cannot continue"
        print_error "The algif_aead kernel module is not mitigated on this system."
        echo ""
        print_info "This is a HIGH severity local privilege escalation vulnerability"
        print_info "affecting all Linux kernels since 2017. Any local user can"
        print_info "escalate to root privileges."
        echo ""
        print_info "Please review and apply the mitigation before proceeding:"
        print_info "  https://copy.fail"
        echo ""
        print_info "Once mitigated, re-run this script."
        echo ""
        exit 1
    fi

    print_ok "CVE-2026-31431 mitigated -- algif_aead is blocked"
}

install_package() {
    local pkg="$1"
    print_info "Installing ${pkg}..."
    case "$PKG_MANAGER" in
        apt)    apt-get install -y "$pkg" &>/dev/null ;;
        dnf)    dnf install -y "$pkg" &>/dev/null ;;
        yum)    yum install -y "$pkg" &>/dev/null ;;
        pacman) pacman -S --noconfirm "$pkg" &>/dev/null ;;
        *)      print_warn "Cannot auto-install ${pkg} -- please install it manually."; return 1 ;;
    esac
    print_ok "${pkg} installed"
}

update_package_index() {
    print_step "Updating package index..."
    case "$PKG_MANAGER" in
        apt)     apt-get update -qq ;;
        dnf|yum) "$PKG_MANAGER" check-update -q || true ;;
        pacman)  pacman -Sy --noconfirm &>/dev/null ;;
    esac
    print_ok "Package index updated"
}

command_exists() {
    command -v "$1" &>/dev/null
}

# -----------------------------------------------------------------------------
# INPUT VALIDATION HELPERS
# -----------------------------------------------------------------------------

# Validate IPv4 dotted-quad. Returns 0 if valid.
validate_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local IFS=.
    local -a octets=($ip)
    for octet in "${octets[@]}"; do
        (( octet >= 0 && octet <= 255 )) || return 1
    done
    return 0
}

# Validate IPv6 (loose; accepts standard and compressed forms).
validate_ipv6() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] || return 1
    [[ "$ip" == *":"* ]] || return 1
    return 0
}

# Validate a public-facing IP (IPv4 or IPv6).
validate_public_ip() {
    local ip="$1"
    validate_ipv4 "$ip" || validate_ipv6 "$ip"
}

# Validate a TCP/UDP port (1-65535).
validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 )) || return 1
    return 0
}

# Validate an IP:PORT pair (used for metrics address).
validate_ip_port() {
    local val="$1"
    local ip="${val%:*}"
    local port="${val##*:}"
    [[ "$ip" != "$val" ]] || return 1
    validate_ipv4 "$ip" || return 1
    validate_port "$port" || return 1
    return 0
}

# Validate a libp2p multiaddr in the shapes this suite uses:
#   /ip4/<ipv4>/udp/<port>/quic-v1
#   /ip6/<ipv6>/udp/<port>/quic-v1
validate_multiaddr() {
    local addr="$1"
    if [[ "$addr" =~ ^/ip4/([^/]+)/udp/([0-9]+)/quic-v1$ ]]; then
        local ip="${BASH_REMATCH[1]}"
        local port="${BASH_REMATCH[2]}"
        # Accept 0.0.0.0 as a valid wildcard binding.
        [[ "$ip" == "0.0.0.0" ]] || validate_ipv4 "$ip" || return 1
        validate_port "$port" || return 1
        return 0
    fi
    if [[ "$addr" =~ ^/ip6/([^/]+)/udp/([0-9]+)/quic-v1$ ]]; then
        local ip="${BASH_REMATCH[1]}"
        local port="${BASH_REMATCH[2]}"
        [[ "$ip" == "::" ]] || validate_ipv6 "$ip" || return 1
        validate_port "$port" || return 1
        return 0
    fi
    return 1
}

# Public Artifact Registry for the testnet (-adiri) docker image.
readonly GAR_IMAGE_BASE="us-docker.pkg.dev/telcoin-network/tn-public/adiri"
readonly GAR_TAGS_URL="https://us-docker.pkg.dev/v2/telcoin-network/tn-public/adiri/tags/list"
# Fallback only when the registry is unreachable.
readonly DEFAULT_DOCKER_IMAGE="${GAR_IMAGE_BASE}:v0.15.0-adiri"

# Echo the latest published -adiri docker image ref (registry/path:tag) by
# querying the public Artifact Registry tag list and picking the highest version
# (sort -V). Mirrors the UI's latest_docker_image() so the CLI and GUI offer the
# same default. Falls back to DEFAULT_DOCKER_IMAGE when the registry is
# unreachable, so a node default is never the long-stale hardcoded tag.
latest_docker_image() {
    local json best=""
    json=$(curl -sf --max-time 10 "$GAR_TAGS_URL" 2>/dev/null || true)
    if [[ -n "$json" ]]; then
        best=$(printf '%s' "$json" \
            | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9._-]*' \
            | grep -- '-adiri' \
            | sort -V | tail -1 || true)
    fi
    if [[ -n "$best" ]]; then
        echo "${GAR_IMAGE_BASE}:${best}"
    else
        echo "$DEFAULT_DOCKER_IMAGE"
    fi
}

# Validate a Docker image reference (registry/path:tag).
# Accepts the registries this suite uses plus generic host/name:tag forms.
validate_docker_image() {
    local img="$1"
    [[ -n "$img" ]] || return 1
    [[ "$img" =~ [[:space:]] ]] && return 1
    # Require at least one ":" for tag and "/" for registry/repo separation.
    [[ "$img" == *:* ]] || return 1
    [[ "$img" =~ ^[A-Za-z0-9._/:@-]+$ ]] || return 1
    return 0
}

# -----------------------------------------------------------------------------
# RPC URL, RELEASE FLOOR AND CHAIN ID CHECKS
# -----------------------------------------------------------------------------

# _tn_ipv4_strict <a.b.c.d> — rc 0 for a dotted quad with every octet 0-255 and
# no leading zeros (010.0.0.1 is ambiguous: some resolvers read it as octal).
_tn_ipv4_strict() {
    local ip="${1:-}" a="" b="" c="" d="" o
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    IFS=. read -r a b c d <<<"$ip"
    for o in "$a" "$b" "$c" "$d"; do
        [[ "$o" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
        (( 10#$o <= 255 )) || return 1
    done
    return 0
}

# _tn_ipv6_strict <addr> — rc 0 for an IPv6 address in full or compressed form,
# with an optional IPv4 tail (::ffff:10.0.0.1). Zone ids (%eth0) are refused.
_tn_ipv6_strict() {
    local ip="${1:-}" tail g n compressed
    local -a groups=()
    [[ -n "$ip" && "$ip" =~ ^[0-9A-Fa-f:.]+$ && "$ip" == *:* ]] || return 1
    if [[ "$ip" == *.* ]]; then
        # An IPv4 tail stands in for the last two groups.
        tail="${ip##*:}"
        _tn_ipv4_strict "$tail" || return 1
        ip="${ip%"$tail"}0:0"
    fi
    [[ "$ip" != *:::* ]] || return 1
    compressed=0
    if [[ "$ip" == *::* ]]; then
        [[ "${ip/::/}" != *::* ]] || return 1
        compressed=1
    else
        # Without "::" the address can neither start nor end with a colon.
        [[ "$ip" != :* && "$ip" != *: ]] || return 1
    fi
    IFS=: read -r -a groups <<<"$ip"
    n=0
    for g in ${groups[@]+"${groups[@]}"}; do
        [[ -n "$g" ]] || continue
        [[ "$g" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        n=$(( n + 1 ))
    done
    if [[ "$compressed" == "1" ]]; then
        (( n <= 7 )) || return 1
    else
        (( n == 8 )) || return 1
    fi
    return 0
}

# _tn_url_split <url> — print "<scheme> <host> <port|->" for a URL of the shape
# validate_rpc_url accepts: http, https, ws or wss (lowercase); no userinfo; a
# path and query drawn from letters, digits and . _ ~ % / : @ + , ; = & ? -; no
# fragment. An IPv6 host keeps its brackets. rc 1 when the shape is wrong; the
# host and port values themselves are checked by the caller.
_tn_url_split() {
    local url="${1:-}" url_re v6_re name_re scheme auth host colon port
    url_re='^(https?|wss?)://([^/?#@]+)(/[A-Za-z0-9._~%/:@+,;=&-]*)?([?][A-Za-z0-9._~%/:@+,;=&?-]*)?$'
    v6_re='^(\[[0-9A-Fa-f:.]+\])(:([0-9]*))?$'
    name_re='^([A-Za-z0-9.-]+)(:([0-9]*))?$'
    [[ "$url" =~ $url_re ]] || return 1
    scheme="${BASH_REMATCH[1]}"
    auth="${BASH_REMATCH[2]}"
    if [[ "$auth" =~ $v6_re ]] || [[ "$auth" =~ $name_re ]]; then
        host="${BASH_REMATCH[1]}"
        colon="${BASH_REMATCH[2]}"
        port="${BASH_REMATCH[3]}"
    else
        return 1
    fi
    # "host:" with no port number is malformed.
    [[ -z "$colon" || -n "$port" ]] || return 1
    printf '%s %s %s\n' "$scheme" "$host" "${port:--}"
}

# _tn_host_ok <host> — rc 0 for "[IPv6]", a strict IPv4 dotted quad, or a DNS
# name: dot-separated labels of up to 63 letters, digits and inner hyphens,
# 253 characters at most, and a last label that is not all digits.
_tn_host_ok() {
    local host="${1:-}" label=""
    local -a labels=()
    if [[ "$host" == \[*\] ]]; then
        host="${host#\[}"
        host="${host%\]}"
        if _tn_ipv6_strict "$host"; then return 0; fi
        return 1
    fi
    [[ -n "$host" && ${#host} -le 253 ]] || return 1
    if [[ "$host" =~ ^[0-9.]+$ ]]; then
        if _tn_ipv4_strict "$host"; then return 0; fi
        return 1
    fi
    [[ "$host" != .* && "$host" != *. && "$host" != *..* ]] || return 1
    IFS=. read -r -a labels <<<"$host"
    for label in ${labels[@]+"${labels[@]}"}; do
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    done
    [[ ! "$label" =~ ^[0-9]+$ ]] || return 1
    return 0
}

# validate_rpc_url <url> [http|ws|any] — rc 0 when <url> is a usable RPC
# endpoint: http:// or https:// (mode http), ws:// or wss:// (mode ws), or any
# of the four (mode any, the default); a DNS name, IPv4 address or [IPv6] host;
# an optional port 1-65535; an optional path and query. Refused: userinfo
# (user@host), whitespace, quotes, backticks, control characters, a fragment,
# an uppercase scheme, and anything over 512 characters. No output.
validate_rpc_url() {
    local url="${1:-}" mode="${2:-any}" parts scheme="" host="" port=""
    [[ -n "$url" && ${#url} -le 512 ]] || return 1
    case "$url" in
        *[[:space:][:cntrl:]]*|*\"*|*\'*|*\`*) return 1 ;;
    esac
    parts="$(_tn_url_split "$url")" || return 1
    read -r scheme host port <<<"$parts"
    case "$mode" in
        http) [[ "$scheme" == "http" || "$scheme" == "https" ]] || return 1 ;;
        ws)   [[ "$scheme" == "ws" || "$scheme" == "wss" ]] || return 1 ;;
        any)  ;;
        *)    return 1 ;;
    esac
    if [[ "$port" != "-" ]]; then
        [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
        (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
    fi
    if _tn_host_ok "$host"; then return 0; fi
    return 1
}

# _tn_ipv4_is_private <a.b.c.d> — rc 0 for 0/8, 10/8, 100.64/10, 127/8,
# 169.254/16, 172.16/12 and 192.168/16. The address must already be valid.
_tn_ipv4_is_private() {
    local a="" b=""
    IFS=. read -r a b _ <<<"${1:-}"
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || return 1
    a=$(( 10#$a ))
    b=$(( 10#$b ))
    case "$a" in
        0|10|127) return 0 ;;
    esac
    if (( a == 100 && b >= 64 && b <= 127 )); then return 0; fi
    if (( a == 169 && b == 254 )); then return 0; fi
    if (( a == 172 && b >= 16 && b <= 31 )); then return 0; fi
    if (( a == 192 && b == 168 )); then return 0; fi
    return 1
}

# _tn_ipv6_is_private <addr> — rc 0 for :: and ::1, link-local fe80::/10, unique
# local fc00::/7, and an IPv4-mapped (::ffff:a.b.c.d) private address. Takes a
# valid, lowercase address without brackets.
_tn_ipv6_is_private() {
    local h="${1:-}" first tail
    if [[ "$h" == *.* ]]; then
        tail="${h##*:}"
        if [[ "${h%"$tail"}" =~ ^[0:]*ffff:$ ]] && _tn_ipv4_is_private "$tail"; then
            return 0
        fi
        return 1
    fi
    # Unspecified (all zero) or loopback (all zero, last group 1).
    if [[ "$h" =~ ^[0:]+$ ]]; then return 0; fi
    if [[ "${h%:*}" =~ ^[0:]*$ && "${h##*:}" =~ ^0{0,3}1$ ]]; then return 0; fi
    first="${h%%:*}"
    [[ -n "$first" ]] || return 1
    first="0000${first}"
    first="${first:${#first}-4}"
    case "$first" in
        fc*|fd*|fe8*|fe9*|fea*|feb*) return 0 ;;
    esac
    return 1
}

# rpc_url_is_private <url> — rc 0 when the URL points somewhere only this host or
# its private network can reach: loopback, RFC 1918, link-local, 100.64.0.0/10
# (carrier-grade NAT), IPv6 unique-local, localhost, a single-label name, or a
# name under .local, .localhost or .internal. rc 1 for a public host and for a
# URL that validate_rpc_url refuses. No output.
rpc_url_is_private() {
    local url="${1:-}" parts scheme="" host="" port=""
    validate_rpc_url "$url" any || return 1
    parts="$(_tn_url_split "$url")" || return 1
    read -r scheme host port <<<"$parts"
    host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
    if [[ "$host" == \[*\] ]]; then
        host="${host#\[}"
        host="${host%\]}"
        if _tn_ipv6_is_private "$host"; then return 0; fi
        return 1
    fi
    if [[ "$host" =~ ^[0-9.]+$ ]]; then
        if _tn_ipv4_is_private "$host"; then return 0; fi
        return 1
    fi
    case "$host" in
        localhost|*.localhost|*.local|*.internal) return 0 ;;
        *.*) return 1 ;;
    esac
    # A single-label name only resolves through a local search domain.
    return 0
}

# tn_ref_min_check <ref> <network> — check a release ref against the network's
# oldest supported release (MIN_SOURCE_VERSION_*). <ref> is a git ref
# (v0.13.0-adiri, main, a commit) or a docker image reference, which is judged
# on the part after its last ":" (…/adiri:v0.15.0-adiri). Prints one message on
# stdout when rc is not 0:
#   rc 0  allowed: a release tag at or above the floor, or no floor for <network>
#   rc 1  refused: an empty ref, or a version below the floor whatever its suffix
#   rc 2  allowed with a warning: not a release tag (main, a commit, a digest, or
#         a pre-release such as v0.13.0-rc1), so the version is unknown
# A release tag is vX.Y.Z with no suffix or with the network's tag suffix
# (-adiri on testnet). <network> is testnet (or adiri), mainnet or devnet;
# devnet, and an empty or unknown network, have no floor.
tn_ref_min_check() {
    local ref="${1:-}" network="${2:-}" floor suffix tag ver rest tag_re
    if [[ -z "$ref" ]]; then
        printf '%s\n' "empty ref: no source ref or docker image was given."
        return 1
    fi
    case "$network" in
        testnet|adiri) floor="$MIN_SOURCE_VERSION_TESTNET"; suffix="$NETWORK_TAG_SUFFIX_TESTNET" ;;
        mainnet)       floor="$MIN_SOURCE_VERSION_MAINNET"; suffix="$NETWORK_TAG_SUFFIX_MAINNET" ;;
        *)             floor=""; suffix="" ;;
    esac
    [[ -n "$floor" ]] || return 0
    tag="$ref"
    if [[ "$tag" == *:* ]]; then
        tag="${tag##*:}"
    fi
    tag_re='^v?([0-9]+\.[0-9]+\.[0-9]+)(-[A-Za-z0-9][A-Za-z0-9.-]*)?$'
    if [[ "$tag" =~ $tag_re ]]; then
        ver="${BASH_REMATCH[1]}"
        rest="${BASH_REMATCH[2]}"
        if ! version_gte "$ver" "$floor"; then
            printf '%s\n' "${ref} is older than v${floor}, the oldest ${network} release these scripts support (v${floor} is the first with keytool set-rpc, proof-of-possession signing and state export). Pick v${floor} or a newer release."
            return 1
        fi
        if [[ -z "$rest" || "$rest" == "$suffix" ]]; then
            return 0
        fi
        printf '%s\n' "${ref} is not a release tag (release tags look like v${floor}${suffix}), so it cannot be checked against the v${floor} minimum for ${network}. Make sure it is a release at v${floor} or newer."
        return 2
    fi
    printf '%s\n' "${ref} is not a release tag, so it cannot be checked against the v${floor} minimum for ${network}. Make sure it is v${floor} or newer."
    return 2
}

# tn_genesis_chain_id <genesis-file> — print the chain id a genesis file declares
# (the first chainId or chain_id key, decimal or 0x-hex, quoted or not) as plain
# decimal. The key may sit anywhere on a line, so YAML, pretty JSON and one-line
# JSON all work; YAML comment lines are skipped, and a longer key that merely ends
# in chain_id does not count. rc 1 when the file is unreadable or holds no such key.
tn_genesis_chain_id() {
    local file="${1:-}" live line id_re
    [[ -n "$file" && -f "$file" && -r "$file" ]] || return 1
    id_re='(^|[^A-Za-z0-9_])"?(chainId|chain_id)"?[[:space:]]*:[[:space:]]*"?(0[xX][0-9A-Fa-f]+|[0-9]+)"?([^A-Za-z0-9_.]|$)'
    live="$(grep -v -E '^[[:space:]]*#' "$file" 2>/dev/null || true)"
    line="$(grep -m1 -E -- "$id_re" <<<"$live" 2>/dev/null || true)"
    [[ -n "$line" && "$line" =~ $id_re ]] || return 1
    _tn_uint "${BASH_REMATCH[3]}"
}

# tn_is_public_chain_id <id> — rc 0 when <id> (decimal or 0x-hex) is one of the
# Association's networks: testnet, devnet or mainnet. No output.
tn_is_public_chain_id() {
    local id
    id="$(_tn_uint "${1:-}")" || return 1
    case "$id" in
        "$TESTNET_CHAIN_ID"|"$DEVNET_CHAIN_ID"|"$MAINNET_CHAIN_ID") return 0 ;;
    esac
    return 1
}

# Prompt for input, validate with a function, retry up to 3 times.
# Usage: prompt_with_validation <prompt-text> <validator-fn> <out-var>
# Returns 0 on success (out-var set), 1 if user exhausts retries.
prompt_with_validation() {
    local prompt_text="$1"
    local validator_fn="$2"
    local out_var="$3"
    local attempts=0
    local input
    while (( attempts < 3 )); do
        read -r -p "  ${prompt_text}: " input
        if "$validator_fn" "$input"; then
            printf -v "$out_var" '%s' "$input"
            return 0
        fi
        (( ++attempts ))
        if (( attempts < 3 )); then
            print_warn "Invalid input. ($((3 - attempts)) attempt(s) remaining)"
        fi
    done
    print_error "Too many invalid attempts. Aborting this step."
    return 1
}

# _tn_hw_disk_label <gb> — "2 TB" for whole thousands of GB, else "<gb> GB".
_tn_hw_disk_label() {
    local gb="${1:-0}"
    if [[ "$gb" -ge 1000 ]] && [[ $(( gb % 1000 )) -eq 0 ]]; then
        printf '%s TB' "$(( gb / 1000 ))"
    else
        printf '%s GB' "$gb"
    fi
}

# tn_physical_cores — print "<n> physical" with the number of physical CPU cores,
# or "<n> logical" when only the logical CPU count (every hyperthread counted) can
# be read. Sources, first answer wins:
#   1. `lscpu --parse=CORE,SOCKET`, one line per online logical CPU: the unique
#      (core, socket) pairs are the physical cores. A line without a core id is
#      skipped; an empty socket id counts as one socket. ui/server.py
#      (physical_cores) follows the same rules.
#   2. ${TN_PROC_CPUINFO:-/proc/cpuinfo}: unique (physical id, core id) pairs. x86
#      kernels print both; ARM kernels print neither and fall through.
#   3. `sysctl -n hw.physicalcpu` (macOS).
#   4. The logical count: nproc, then getconf _NPROCESSORS_ONLN.
# rc 1 with no output when none of them answers.
tn_physical_cores() {
    local out n cpuinfo
    if command -v lscpu >/dev/null 2>&1; then
        out="$(lscpu --parse=CORE,SOCKET 2>/dev/null || true)"
        n="$(awk -F, '
            /^[ \t]*#/ || NF == 0 { next }
            { core = $1; sock = $2; gsub(/[ \t]/, "", core); gsub(/[ \t]/, "", sock) }
            core == "" { next }
            !((core, sock) in seen) { seen[core, sock] = 1; c++ }
            END { print c + 0 }
        ' <<<"$out" 2>/dev/null || true)"
        if [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
            printf '%s physical\n' "$n"
            return 0
        fi
    fi
    cpuinfo="${TN_PROC_CPUINFO:-/proc/cpuinfo}"
    if [[ -r "$cpuinfo" ]]; then
        n="$(awk '
            function add_pair() {
                if (p != "" && c != "" && !((p, c) in seen)) { seen[p, c] = 1; k++ }
                p = ""; c = ""
            }
            /^processor[ \t]*:/ { add_pair() }
            /^physical id[ \t]*:/ { p = $0; sub(/^[^:]*:[ \t]*/, "", p) }
            /^core id[ \t]*:/ { c = $0; sub(/^[^:]*:[ \t]*/, "", c) }
            END { add_pair(); print k + 0 }
        ' "$cpuinfo" 2>/dev/null || true)"
        if [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
            printf '%s physical\n' "$n"
            return 0
        fi
    fi
    if command -v sysctl >/dev/null 2>&1; then
        n="$(sysctl -n hw.physicalcpu 2>/dev/null || true)"
        if [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
            printf '%s physical\n' "$n"
            return 0
        fi
    fi
    n=""
    if command -v nproc >/dev/null 2>&1; then
        n="$(nproc 2>/dev/null || true)"
    fi
    if [[ ! "$n" =~ ^[1-9][0-9]*$ ]] && command -v getconf >/dev/null 2>&1; then
        n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    fi
    if [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s logical\n' "$n"
        return 0
    fi
    return 1
}

# _tn_hw_cpu_text <n> <physical|logical> — "4 physical cores", "1 logical CPU".
_tn_hw_cpu_text() {
    local n="$1" what
    if [[ "${2:-}" == "physical" ]]; then what="physical core"; else what="logical CPU"; fi
    if [[ "$n" == "1" ]]; then
        printf '%s %s' "$n" "$what"
    else
        printf '%s %ss' "$n" "$what"
    fi
}

# _tn_hw_role <label> <min_cpu> <min_ram_gb> <min_disk_gb> <cpu> <ram_kb> <disk_kb>
# [cpu_kind] — print one line for a role tier. Empty cpu/ram_kb/disk_kb mean "could
# not measure" and never count as a shortfall. cpu_kind (physical or logical, from
# tn_physical_cores) only words the count. rc 1 when a measured value is below the
# tier, else 0. RAM and disk get 5 % slack: a "16 GB" box reports ~15.6 GiB and a
# formatted "2 TB" disk a little under 2000 GB.
_tn_hw_role() {
    local label="$1" min_cpu="$2" min_ram="$3" min_disk="$4" cpu="$5" ram_kb="$6" disk_kb="$7"
    local cpu_kind="${8:-logical}" spec need have unknown
    spec="${min_cpu} cores / ${min_ram} GB / $(_tn_hw_disk_label "$min_disk")"
    need=""
    have=""
    unknown=""
    if [[ -z "$cpu" ]]; then
        unknown="CPU"
    elif [[ "$cpu" -lt "$min_cpu" ]]; then
        need="${min_cpu} cores"
        have="$(_tn_hw_cpu_text "$cpu" "$cpu_kind")"
    fi
    if [[ -z "$ram_kb" ]]; then
        unknown="${unknown:+${unknown}, }RAM"
    elif [[ "$ram_kb" -lt $(( min_ram * 1024 * 1024 * 95 / 100 )) ]]; then
        need="${need:+${need}, }${min_ram} GB RAM"
        have="${have:+${have}, }$(( (ram_kb + 524288) / 1048576 )) GB RAM"
    fi
    if [[ -z "$disk_kb" ]]; then
        unknown="${unknown:+${unknown}, }disk"
    elif [[ "$disk_kb" -lt $(( min_disk * 1000000000 * 95 / 100 / 1024 )) ]]; then
        need="${need:+${need}, }$(_tn_hw_disk_label "$min_disk") disk"
        have="${have:+${have}, }$(( (disk_kb * 1024 + 500000000) / 1000000000 )) GB disk"
    fi
    if [[ -n "$need" ]]; then
        print_warn "${label}: below minimum — needs ≥ ${need} (have ${have})"
        if [[ -n "$unknown" ]]; then
            print_info "${label}: could not check ${unknown}; minimum is ${spec}"
        fi
        return 1
    fi
    if [[ -n "$unknown" ]]; then
        print_info "${label}: could not check ${unknown}; minimum is ${spec}"
    else
        print_ok "${label}: meets minimum (${spec})"
    fi
    return 0
}

# check_hardware [legacy_arg] [data_dir] — informational hardware report against the
# per-role tiers above. It never blocks setup and ALWAYS returns 0: every node is
# provisioned validator-capable, but the role is decided on-chain each epoch and a
# node below the validator tier still runs fine as a follower. $1 (the old
# node_type) is accepted for call-site compatibility and ignored. data_dir (default
# /) picks the filesystem to measure; it may not exist yet (created later in
# setup), so the nearest existing parent is used.
#   * CPU: tn_physical_cores. The tiers are physical cores; when only the logical
#     count can be read (every hyperthread counted, so up to twice the cores), the
#     tiers are compared with that and the report says so.
#   * RAM: MemTotal from ${TN_PROC_MEMINFO:-/proc/meminfo} (a harness can point it
#     at a fixture), shown rounded to whole GiB.
#   * Disk: TOTAL size of that filesystem (not free space) from POSIX `df -Pk`, in
#     decimal GB as disks are sold. Free space is reported too, with a warning at
#     90 % used or more.
# Sets TN_HW_SUMMARY (the "Detected" text) and TN_HW_GAPS (comma-separated roles
# below minimum, from node, rpc, validator; empty when all pass), both plain ASCII.
check_hardware() {
    local data_dir="${2:-/}"
    local meminfo cpu cpu_kind cores ram_kb ram_gb check_path df_line disk_kb disk_avail_kb disk_pct
    local mount_point disk_gb disk_free_gb cpu_txt ram_txt disk_txt gaps
    TN_HW_SUMMARY=""
    TN_HW_GAPS=""
    print_step "Checking hardware..."

    cpu=""
    cpu_kind=""
    cores="$(tn_physical_cores 2>/dev/null || true)"
    read -r cpu cpu_kind _ <<<"$cores" || true
    if [[ ! "$cpu" =~ ^[1-9][0-9]*$ ]] || [[ "$cpu_kind" != "physical" && "$cpu_kind" != "logical" ]]; then
        cpu=""
        cpu_kind=""
    fi

    meminfo="${TN_PROC_MEMINFO:-/proc/meminfo}"
    ram_kb=""
    if [[ -r "$meminfo" ]]; then
        ram_kb="$(awk '$1 == "MemTotal:" { print $2; exit }' "$meminfo" 2>/dev/null || true)"
    fi
    [[ "$ram_kb" =~ ^[1-9][0-9]*$ ]] || ram_kb=""
    ram_gb=""
    if [[ -n "$ram_kb" ]]; then
        ram_gb=$(( (ram_kb + 524288) / 1048576 ))
    fi

    check_path="$data_dir"
    while [[ -n "$check_path" && ! -e "$check_path" && "$check_path" != "/" ]]; do
        check_path="$(dirname "$check_path" 2>/dev/null || echo /)"
    done
    [[ -e "$check_path" ]] || check_path="/"

    # df -Pk line 2: filesystem, total kB, used, available kB, capacity%, mount point.
    # Fields are located from the capacity column so spaces in the device or mount
    # name cannot shift them.
    df_line=""
    if command -v df >/dev/null 2>&1; then
        df_line="$(df -Pk "$check_path" 2>/dev/null | awk 'NR == 2 {
            for (i = 5; i <= NF; i++) if ($i ~ /^[0-9]+%$/) break
            if (i > NF) exit
            m = $(i + 1)
            for (j = i + 2; j <= NF; j++) m = m " " $j
            print $(i - 3), $(i - 1), $i + 0, m
        }' 2>/dev/null || true)"
    fi
    disk_kb=""
    disk_avail_kb=""
    disk_pct=""
    mount_point=""
    if [[ -n "$df_line" ]]; then
        read -r disk_kb disk_avail_kb disk_pct mount_point <<<"$df_line" || true
    fi
    [[ "$disk_kb" =~ ^[1-9][0-9]*$ ]] || disk_kb=""
    [[ "$disk_avail_kb" =~ ^[0-9]+$ ]] || disk_avail_kb=""
    [[ "$disk_pct" =~ ^[0-9]+$ ]] || disk_pct=""
    [[ -n "$mount_point" ]] || mount_point="$check_path"
    # These strings end up inside JSON log lines: drop quotes, backslashes, controls.
    mount_point="${mount_point//[\"\\[:cntrl:]]/}"
    disk_gb=""
    disk_free_gb=""
    if [[ -n "$disk_kb" ]]; then
        disk_gb=$(( (disk_kb * 1024 + 500000000) / 1000000000 ))
    fi
    if [[ -n "$disk_avail_kb" ]]; then
        disk_free_gb=$(( (disk_avail_kb * 1024 + 500000000) / 1000000000 ))
    fi

    if [[ -n "$cpu" ]]; then cpu_txt="$(_tn_hw_cpu_text "$cpu" "$cpu_kind")"; else cpu_txt="unknown CPUs"; fi
    if [[ -n "$ram_gb" ]]; then ram_txt="${ram_gb} GB RAM"; else ram_txt="unknown RAM"; fi
    if [[ -n "$disk_gb" ]]; then
        disk_txt="${disk_gb} GB disk on ${mount_point}"
        if [[ -n "$disk_free_gb" ]]; then
            disk_txt="${disk_txt} (${disk_free_gb} GB free)"
        fi
    else
        disk_txt="unknown disk on ${mount_point}"
    fi
    TN_HW_SUMMARY="${cpu_txt}, ${ram_txt}, ${disk_txt}"
    print_info "Detected: ${TN_HW_SUMMARY}"
    if [[ "$cpu_kind" == "logical" ]]; then
        print_info "Physical cores could not be counted, so the tiers below are compared with logical CPUs; with hyperthreading that is up to twice the physical cores."
    fi
    if [[ -n "$disk_pct" ]] && [[ "$disk_pct" -ge 90 ]]; then
        print_warn "Disk ${mount_point} is ${disk_pct}% used (${disk_free_gb:-?} GB free)."
    fi

    gaps=""
    if ! _tn_hw_role "Full node (follower)" "$HW_NODE_MIN_CPU" "$HW_NODE_MIN_RAM_GB" "$HW_NODE_MIN_DISK_GB" \
        "$cpu" "$ram_kb" "$disk_kb" "$cpu_kind"; then
        gaps="node"
    fi
    if ! _tn_hw_role "Public RPC node" "$HW_RPC_MIN_CPU" "$HW_RPC_MIN_RAM_GB" "$HW_RPC_MIN_DISK_GB" \
        "$cpu" "$ram_kb" "$disk_kb" "$cpu_kind"; then
        gaps="${gaps:+${gaps},}rpc"
    fi
    if ! _tn_hw_role "Validator (minimum)" "$HW_VAL_MIN_CPU" "$HW_VAL_MIN_RAM_GB" "$HW_VAL_MIN_DISK_GB" \
        "$cpu" "$ram_kb" "$disk_kb" "$cpu_kind"; then
        gaps="${gaps:+${gaps},}validator"
    fi
    TN_HW_GAPS="$gaps"
    print_info "Validator (recommended): ${HW_VAL_REC_CPU} cores / ${HW_VAL_REC_RAM_GB} GB ECC / $(_tn_hw_disk_label "$HW_VAL_REC_DISK_GB") NVMe — ECC and NVMe are not checked here."
    print_info "Hardware checks never block setup; the node role is decided on-chain each epoch."
    return 0
}

# Check whether ports are free, protocol-aware. Each arg is "port[/proto][:label]"
# (proto defaults to tcp). UDP ports (e.g. the QUIC P2P ports) are checked against
# the UDP socket table -- the old version used `ss -tln` for everything, so UDP
# ports were never actually checked. Informational only (warns, never fails).
check_ports() {
    print_step "Checking required ports are available..."
    local spec pp port proto label flag
    for spec in "$@"; do
        label="${spec#*:}"; [[ "$label" == "$spec" ]] && label=""   # text after ':' (if any)
        pp="${spec%%:*}"                                             # port[/proto]
        port="${pp%%/*}"
        proto="${pp#*/}"; [[ "$proto" == "$pp" ]] && proto="tcp"    # no '/' -> tcp
        case "$proto" in
            udp) flag="-uln" ;;
            *)   flag="-tln"; proto="tcp" ;;
        esac
        local desc="${port}/${proto}"
        [[ -n "$label" ]] && desc="${desc} (${label})"
        # ':<port>' anchored so e.g. :9000 doesn't match :49000; trailing space is
        # the column boundary after the local address in ss output.
        if ss "$flag" 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
            print_warn "Port ${desc} is already in use."
        else
            print_ok "Port ${desc} is available"
        fi
    done
}

check_internet() {
    print_step "Checking internet connectivity..."
    if curl -s --max-time 10 "$TESTNET_RPC_URL" &>/dev/null || \
       curl -s --max-time 10 "https://1.1.1.1" &>/dev/null; then
        print_ok "Internet connectivity confirmed"
    else
        print_error "No internet connection detected."
        exit 1
    fi
}

version_gte() {
    [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]
}

check_rust() {
    print_step "Checking Rust installation..."
    if ! command_exists rustc; then
        print_info "Rust is not installed."
        return 1
    fi
    local rust_version
    rust_version=$(rustc --version | awk '{print $2}')
    if version_gte "$rust_version" "$MIN_RUST_VERSION"; then
        print_ok "Rust ${rust_version} detected"
        return 0
    else
        print_warn "Rust ${rust_version} found but ${MIN_RUST_VERSION}+ required."
        return 1
    fi
}

check_docker() {
    print_step "Checking Docker..."
    if ! command_exists docker; then
        print_info "Docker is not installed."
        return 1
    fi
    if ! docker info &>/dev/null; then
        print_warn "Docker installed but daemon is not running."
        return 1
    fi
    local v
    v=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
    print_ok "Docker ${v} running"
    return 0
}

verify_binary() {
    local binary_path="$1"

    # Skip binary verification for Docker installs
    if [[ "${INSTALL_METHOD:-}" == "docker" ]]; then
        print_step "Docker install -- skipping binary verification"
        print_ok "Using Docker image: ${DOCKER_IMAGE:-unknown}"
        return 0
    fi

    print_step "Verifying binary at: ${binary_path}"
    if [[ ! -f "$binary_path" ]]; then
        print_error "Binary not found at: ${binary_path}"
        return 1
    fi
    if [[ ! -x "$binary_path" ]]; then
        print_error "File not executable: ${binary_path}"
        return 1
    fi
    local v
    if v=$("$binary_path" --version 2>&1); then
        print_ok "Binary valid: ${v}"
    else
        print_warn "Binary found but --version returned an error. May still work."
    fi
    return 0
}

check_rpc_alive() {
    local rpc_url="$1"
    local max_attempts="${2:-10}"
    local wait_seconds="${3:-5}"
    print_step "Waiting for RPC at ${rpc_url}..."
    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        local response
        response=$(curl -s --max-time 5 -X POST \
            -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
            "$rpc_url" 2>/dev/null || true)
        if echo "$response" | grep -q '"result"'; then
            local chain_id
            chain_id=$(echo "$response" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
            print_ok "RPC responding. Chain ID: ${chain_id}"
            return 0
        fi
        print_info "Attempt ${attempt}/${max_attempts} -- waiting ${wait_seconds}s..."
        sleep "$wait_seconds"
        (( ++attempt ))
    done
    print_error "RPC did not respond after ${max_attempts} attempts."
    return 1
}

check_peer_count() {
    local rpc_url="$1"
    local min_peers="${2:-1}"
    print_step "Checking peer connections..."
    local response
    response=$(curl -s --max-time 5 -X POST \
        -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
        "$rpc_url" 2>/dev/null || echo "")
    if echo "$response" | grep -q '"result"'; then
        local peer_hex peer_count
        peer_hex=$(echo "$response" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
        peer_count=$(( 16#${peer_hex#0x} ))
        if [[ $peer_count -ge $min_peers ]]; then
            print_ok "Connected to ${peer_count} peer(s)"
            return 0
        else
            print_warn "Only ${peer_count} peer(s) connected."
            return 1
        fi
    else
        print_warn "Could not retrieve peer count."
        return 1
    fi
}

# -----------------------------------------------------------------------------
# SYSTEM SETUP
# -----------------------------------------------------------------------------

create_service_user() {
    # Create group first if it doesn't exist
    print_step "Creating service group: ${SERVICE_GROUP}..."
    if getent group "$SERVICE_GROUP" &>/dev/null; then
        print_ok "Group '${SERVICE_GROUP}' already exists"
    else
        groupadd --system "$SERVICE_GROUP"
        print_ok "Created system group '${SERVICE_GROUP}'"
    fi

    # Create user if it doesn't exist
    # For Docker installs, force UID 1101 to match the container's nonroot user
    print_step "Creating service user: ${SERVICE_USER}..."
    if id "$SERVICE_USER" &>/dev/null; then
        print_ok "User '${SERVICE_USER}' already exists"
        usermod -aG "$SERVICE_GROUP" "$SERVICE_USER" 2>/dev/null || true
    else
        if [[ "${INSTALL_METHOD:-}" == "docker" ]]; then
            useradd --uid "${DOCKER_UID:-1101}" --system --no-create-home --shell /bin/false \
                    --gid "$SERVICE_GROUP" \
                    --comment "Telcoin Network node service account" "$SERVICE_USER"
            print_ok "Created system user '${SERVICE_USER}' (UID ${DOCKER_UID:-1101}) in group '${SERVICE_GROUP}'"
        else
            useradd --system --no-create-home --shell /bin/false \
                    --gid "$SERVICE_GROUP" \
                    --comment "Telcoin Network node service account" "$SERVICE_USER"
            print_ok "Created system user '${SERVICE_USER}' in group '${SERVICE_GROUP}'"
        fi
    fi
    # For TPM installs, add service user to tss group for TPM device access
    if [[ "${PASSPHRASE_METHOD:-}" == "tpm" ]]; then
        if getent group tss &>/dev/null; then
            usermod -aG tss "$SERVICE_USER" 2>/dev/null || true
            print_ok "Added '${SERVICE_USER}' to tss group (TPM device access)"
        else
            print_warn "tss group not found -- TPM device access may fail"
        fi
    fi
}

create_directories() {
    local install_dir="${1:-$DEFAULT_INSTALL_DIR}"
    local data_dir="${2:-$DEFAULT_DATA_DIR}"
    local log_dir="${3:-$DEFAULT_LOG_DIR}"
    local config_dir="${4:-$DEFAULT_CONFIG_DIR}"
    print_step "Creating directory structure..."
    for dir in "$install_dir" "$data_dir" "$log_dir" "$config_dir"; do
        mkdir -p "$dir"
        chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "$dir"
        print_ok "Created: ${dir}"
    done
}

# -----------------------------------------------------------------------------
# NETWORK AND INSTALL METHOD SELECTION
# -----------------------------------------------------------------------------

# Write the optional advertised node name (hostname) into the data dir's
# network-config. Mirrors telcoin-ui-helper's set-hostname so a name chosen at
# setup time matches what the UI Config tab writes later. No-op when empty; a
# bad name warns and is skipped (the operator can set it later in the dashboard).
# Args: <data_dir> <name> [<owner_user:owner_group>]
write_advertised_name() {
    local data_dir="$1" name="$2" owner="${3:-}"
    [[ -z "$name" ]] && return 0
    if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
        print_warn "Invalid advertised name '${name}' -- skipping (set it later in the dashboard)."
        return 0
    fi
    local nc="${data_dir}/network-config"
    if [[ -f "$nc" ]] && grep -qE '^hostname:' "$nc"; then
        sed -i -E "s#^hostname:.*#hostname: \"${name}\"#" "$nc"
    elif [[ -f "$nc" ]]; then
        printf 'hostname: "%s"\n' "$name" >> "$nc"
    else
        printf 'hostname: "%s"\n' "$name" > "$nc"
    fi
    [[ -n "$owner" ]] && chown "$owner" "$nc" 2>/dev/null || true
    print_ok "Advertised node name set: ${name}"
}

# Record the ref of the source binary that was just installed, in a marker next
# to the binary (<install_dir>/telcoin-network.version). The UI reads this to show
# the version of the RUNNING binary instead of `git describe` of the source
# checkout -- which diverges after a prepare or a rolled-back apply (the checkout
# moves, the installed binary does not). Written only on a successful install /
# verified apply, so after a rollback the marker still names the running binary.
# Args: <install_dir> [<source_dir>] [<fallback_ref>]
write_source_version_marker() {
    local install_dir="$1" source_dir="${2:-$TN_SOURCE_DIR}" fallback="${3:-}"
    local marker="${install_dir}/telcoin-network.version" desc=""
    if [[ -d "${source_dir}/.git" ]]; then
        desc=$(git -C "$source_dir" describe --tags --always --dirty 2>/dev/null || true)
    fi
    [[ -z "$desc" ]] && desc="$fallback"
    [[ -z "$desc" ]] && return 0
    printf '%s\n' "$desc" > "$marker" 2>/dev/null && chmod 0644 "$marker" 2>/dev/null || true
}

select_network() {
    print_header "Network Selection"
    echo "  Which network do you want to connect to?"
    echo ""
    echo "  1) Adiri Testnet  (Chain ID: ${TESTNET_CHAIN_ID})  -- for testing"
    echo "  2) Mainnet        (Chain ID: ${MAINNET_CHAIN_ID})  -- for production (coming soon)"
    echo ""

    local choice
    while true; do
        read -r -p "  Enter choice [1/2]: " choice
        case "$choice" in
            1)
                NETWORK="testnet"
                CHAIN_ID="$TESTNET_CHAIN_ID"
                CHAIN_NAME="$TESTNET_CHAIN_NAME"
                RPC_URL="$TESTNET_RPC_URL"
                EXPLORER_URL="$TESTNET_EXPLORER"
                break
                ;;
            2)
                echo ""
                print_warn "Mainnet has not launched yet."
                print_info "Mainnet configuration will be available once the network goes live."
                print_info "Please select Adiri Testnet for now."
                echo ""
                read -r -p "  Press Enter to return to network selection..."
                echo ""
                ;;
            *)
                print_warn "Please enter 1 or 2."
                ;;
        esac
    done
    print_ok "Network: ${NETWORK} (Chain ID: ${CHAIN_ID})"
}

select_install_method() {
    print_header "Binary Installation Method"
    echo "  How would you like to obtain the telcoin binary?"
    echo ""
    echo "  1) Build from source  -- compiles from GitHub (~30 min, needs Rust)"
    echo "  2) Pre-built binary   -- downloads a release binary (coming soon)"
    echo "  3) Docker             -- pulls official image from Google Artifact Registry"
    echo "  4) I already have it  -- specify path to existing binary"
    echo ""

    local choice
    while true; do
        read -r -p "  Enter choice [1/2/3/4]: " choice
        case "$choice" in
            1) INSTALL_METHOD="source";   break ;;
            2) INSTALL_METHOD="binary";   break ;;
            3) INSTALL_METHOD="docker";   break ;;
            4) INSTALL_METHOD="existing"; break ;;
            *) print_warn "Please enter 1, 2, 3, or 4." ;;
        esac
    done
    print_ok "Install method: ${INSTALL_METHOD}"
}

# -----------------------------------------------------------------------------
# CHAIN CONFIG FILES
# -----------------------------------------------------------------------------

# tn_sync_submodules <repo_dir> — pin submodules to the checked-out ref.
#
# `git checkout <tag>` + `git pull` move the superproject but NOT its
# submodules, so a source tree can sit on a ref whose submodule pointer was
# advanced while the working copy still holds the old submodule content. That
# is exactly what broke v0.12.0-adiri source updates: tn-contracts gained
# deployments/*.json that genesis.rs include_str!'s, and every node updated via
# update-node.sh (which never synced submodules) died in cargo with a missing-
# file error. `submodule sync` first, so URL changes in .gitmodules are honored
# before fetching; then `update --init --recursive --force` to pin content to
# the superproject's recorded shas. Returns non-zero when the update fails
# (e.g. submodule remote unreachable); callers decide hard-fail vs warn.
# No-op (returns 0) when the directory is not a git checkout.
tn_sync_submodules() {
    local repo_dir="$1"
    [[ -d "${repo_dir}/.git" ]] || return 0
    git -C "$repo_dir" submodule sync --recursive 2>/dev/null || true
    git -C "$repo_dir" submodule update --init --recursive --force
}

ensure_chain_configs_available() {
    print_step "Ensuring chain-config files are available..."

    local source_dir="$TN_SOURCE_DIR"

    if [[ -d "${source_dir}/.git" ]]; then
        print_info "Repository already present -- pulling latest..."
        git -C "$source_dir" pull --ff-only 2>/dev/null && \
            print_ok "Repository up to date" || \
            print_warn "Could not pull latest. Using existing files."
        # Warn-only: chain configs are plain files in the superproject, so a
        # submodule failure must not block them; it only matters for builds.
        tn_sync_submodules "$source_dir" || \
            print_warn "submodule sync reported an issue -- chain configs are unaffected"
        return 0
    fi

    echo ""
    print_info "The chain-config YAML files (genesis.yaml, committee.yaml, parameters.yaml)"
    print_info "are required to run a node. They live in the Telcoin Network GitHub repo."
    print_info "Repository: ${TN_REPO}"
    print_info "Clone destination: ${source_dir}"
    echo ""

    if confirm "Clone the repository now to get the chain-config files?"; then
        print_step "Cloning repository..."
        if git clone --recurse-submodules "$TN_REPO" "$source_dir"; then
            print_ok "Repository cloned to: ${source_dir}"
        else
            print_error "Clone failed. Check your internet connection."
            print_info "Manual clone: git clone ${TN_REPO} ${source_dir}"
            exit 1
        fi
    else
        print_warn "Skipped. You will need to provide chain-config files manually in the next step."
    fi
}

# -----------------------------------------------------------------------------
# SYSTEMD SERVICE
# -----------------------------------------------------------------------------

write_systemd_service() {
    local service_name="$1"
    local description="$2"
    local exec_start="$3"
    local data_dir="${4:-$DEFAULT_DATA_DIR}"
    local log_dir="${5:-$DEFAULT_LOG_DIR}"

    local service_file="/etc/systemd/system/${service_name}.service"
    print_step "Writing systemd service: ${service_file}"

    cat > "$service_file" <<EOF
[Unit]
Description=${description}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
ExecStart=${exec_start}
Restart=on-failure
RestartSec=10
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=${data_dir} ${log_dir}
LimitNOFILE=65536
StandardOutput=append:${log_dir}/${service_name}.log
StandardError=append:${log_dir}/${service_name}-error.log

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    print_ok "Service file written: ${service_file}"
    print_info "Start:        systemctl start ${service_name}"
    print_info "Enable boot:  systemctl enable ${service_name}"
    print_info "View logs:    journalctl -u ${service_name} -f"
}


# Detect the internal/private IP of this machine.
# On cloud/data centre servers this is the VM's internal NIC address (e.g. 10.x.x.x)
# which is different from the public IP that peers connect to externally.
# On home/bare metal servers this is usually the LAN IP (e.g. 192.168.x.x).
detect_internal_ip() {
    local detected_ip
    detected_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")

    if [[ -z "$detected_ip" ]]; then
        # Fallback: try to get IP from the default route interface
        detected_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || echo "")
    fi

    echo "$detected_ip"
}

# Ask the operator to confirm or enter the listener IP address.
# Sets the global variable: LISTENER_IP
select_ipv4_binding() {
    # Sets BIND_IP (for listening) and ADVERTISE_IP (for advertising to peers)
    # These may differ when behind NAT or on a cloud VM

    # Detect internal IP
    local internal_ip
    internal_ip=$(ip route get 8.8.8.8 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' || echo "")
    [[ -z "$internal_ip" ]] && internal_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")

    print_info "Detected internal IP: ${internal_ip:-unknown}"
    echo ""
    echo "  Is this server behind NAT or does it have a separate public/external IP?"
    echo "  (e.g. home router, cloud VM with external IP assigned separately)"
    echo ""
    echo "  1) Yes -- I am behind NAT or have a separate public IP"
    echo "  2) No  -- my public IP is directly on this machine"
    echo ""

    local nat_choice
    while true; do
        read -r -p "  Enter choice [1/2]: " nat_choice
        case "$nat_choice" in
            1|2) break ;;
            *) print_warn "Please enter 1 or 2." ;;
        esac
    done

    BIND_IP="$internal_ip"

    if [[ "$nat_choice" == "1" ]]; then
        # Behind NAT -- detect and ask for public IP
        local detected_public
        detected_public=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
                         curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
                         echo "")
        echo ""
        if [[ -n "$detected_public" ]]; then
            print_info "Detected public IP: ${detected_public}"
            read -r -p "  Public IP to advertise to peers [${detected_public}]: " input
            ADVERTISE_IP="${input:-$detected_public}"
        else
            print_warn "Could not auto-detect public IP"
            read -r -p "  Enter your public IP address: " ADVERTISE_IP
        fi
        echo ""
        print_info "Node will listen on ${BIND_IP} and advertise ${ADVERTISE_IP} to peers"
        print_info "Ensure UDP ports are forwarded from your router/firewall to ${BIND_IP}"
    else
        ADVERTISE_IP="$internal_ip"
        print_info "Using ${ADVERTISE_IP} for both binding and advertising"
    fi

    LISTENER_IP="$ADVERTISE_IP"
}

select_listener_ip() {
    local detected_ip
    detected_ip=$(detect_internal_ip)

    echo ""
    print_info "The node needs to know which IP address to bind its P2P listener to."
    print_info "On cloud/data centre servers this is your VM internal IP (e.g. 10.x.x.x)."
    print_info "On home/bare metal servers this is your LAN IP (e.g. 192.168.x.x)."
    print_info "This is NOT the same as your public IP -- peers reach you via your"
    print_info "public IP, but the node listens on the internal/private interface."
    echo ""

    if [[ -n "$detected_ip" ]]; then
        print_info "Detected internal IP: ${detected_ip}"
        if confirm "Use this IP address for the listener?"; then
            LISTENER_IP="$detected_ip"
        else
            read -r -p "  Enter the correct internal IP address: " LISTENER_IP
        fi
    else
        print_warn "Could not auto-detect internal IP."
        read -r -p "  Enter your internal IP address: " LISTENER_IP
    fi

    print_ok "Listener IP: ${LISTENER_IP}"
}

# =============================================================================
# JSON-RPC, EPOCH AND RESTART-WINDOW HELPERS
# =============================================================================
#
# Contract shared by the RPC helpers below: rc 0 puts the value on stdout. Any
# other rc puts ONE line "<kind> <detail>" on stdout, where kind is
#   transport   curl could not finish the request: dns, connect, timeout, tls, ...
#   http        the server answered with a non-2xx status, e.g. "http 429"
#   rpc-error   a JSON-RPC error object: "rpc-error <code> <message>"
#   malformed   the answer (or an argument) is not the expected shape
# Capture with: out="$(fn ...)" || rc=$?
# They print nothing else and never call exit. Numbers that can exceed 64 bits
# (wei amounts) are kept as strings; see tn_hex_to_dec and tn_wei_to_tel.

# _tn_uint <value> — print a non-negative integer given in decimal or 0x-hex as
# plain decimal. Only values bash arithmetic can hold are accepted (up to 18
# decimal digits or 15 hex digits); rc 1 for anything else.
_tn_uint() {
    local v="${1:-}"
    if [[ "$v" =~ ^[0-9]{1,18}$ ]]; then
        printf '%s\n' "$(( 10#$v ))"
        return 0
    fi
    if [[ "$v" =~ ^0[xX][0-9A-Fa-f]{1,15}$ ]]; then
        printf '%s\n' "$(( 16#${v:2} ))"
        return 0
    fi
    return 1
}

# _tn_now — the current Unix time in seconds, or 0 when date fails. A function so
# tests can replace the clock.
_tn_now() {
    local t
    t="$(date +%s 2>/dev/null || true)"
    [[ "$t" =~ ^[0-9]+$ ]] || t=0
    printf '%s\n' "$t"
}

# _tn_curl_reason <curl-exit-code> — a one-word transport failure reason.
_tn_curl_reason() {
    case "${1:-}" in
        3)    printf 'bad-url' ;;
        5|6)  printf 'dns' ;;
        7)    printf 'connect' ;;
        28)   printf 'timeout' ;;
        35|51|53|54|58|59|60|64|66|77|80|82|83|90|91) printf 'tls' ;;
        52)   printf 'empty-reply' ;;
        55|56) printf 'connection-reset' ;;
        127)  printf 'curl-missing' ;;
        *)    printf 'curl-exit-%s' "${1:-unknown}" ;;
    esac
}

# tn_rpc_call <url> <method> [params-json] [max-time] — one JSON-RPC POST.
# params-json defaults to [] and is inserted verbatim; max-time (seconds, default
# 10) bounds the whole request. rc 0 prints the response body on one line. On
# failure (rc 1) the checks run in this order: transport, HTTP status not 2xx,
# an "error" object (rpc-error <code> <message>), no "result" key (malformed).
# A "result" of null counts as present; callers check the fields they need.
tn_rpc_call() {
    local url="${1:-}" method="${2:-}" params="${3:-[]}" max_time="${4:-10}"
    local body raw rc code resp nl err_re code_re msg_re res_re rest ecode emsg
    nl=$'\n'
    if [[ ! "$max_time" =~ ^[0-9]{1,3}$ ]] || (( 10#$max_time == 0 )); then
        max_time=10
    fi
    if [[ ! "$method" =~ ^[A-Za-z0-9_]+$ ]]; then
        printf 'malformed bad-method\n'
        return 1
    fi
    body="{\"jsonrpc\":\"2.0\",\"method\":\"${method}\",\"params\":${params},\"id\":1}"
    rc=0
    # --url keeps a URL that starts with - from being read as a curl option.
    raw="$(curl -sS --max-time "$((10#$max_time))" -X POST \
        -H 'Content-Type: application/json' \
        --data "$body" -w '\n%{http_code}' --url "$url" 2>/dev/null)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf 'transport %s\n' "$(_tn_curl_reason "$rc")"
        return 1
    fi
    code="${raw##*"$nl"}"
    resp=""
    if [[ "$raw" == *"$nl"* ]]; then
        resp="${raw%"$nl"*}"
    fi
    if [[ ! "$code" =~ ^2[0-9][0-9]$ ]]; then
        code="$(printf '%s' "$code" | tr -cd '0-9')"
        printf 'http %s\n' "${code:-000}"
        return 1
    fi
    # JSON never holds a raw line break inside a string, so folding them is safe.
    resp="$(printf '%s' "$resp" | tr '\r\n' '  ')"
    resp="${resp#"${resp%%[![:space:]]*}"}"
    if [[ -z "$resp" ]]; then
        printf 'malformed empty-body\n'
        return 1
    fi
    if [[ "$resp" != \{* ]]; then
        printf 'malformed not-json\n'
        return 1
    fi
    err_re='"error"[[:space:]]*:[[:space:]]*[{]'
    if [[ "$resp" =~ $err_re ]]; then
        rest="${resp#*\"error\"}"
        code_re='"code"[[:space:]]*:[[:space:]]*(-?[0-9]+)'
        msg_re='"message"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
        ecode="?"
        emsg=""
        if [[ "$rest" =~ $code_re ]]; then
            ecode="${BASH_REMATCH[1]}"
        fi
        if [[ "$rest" =~ $msg_re ]]; then
            emsg="${BASH_REMATCH[1]}"
        fi
        emsg="$(printf '%s' "$emsg" | tr -d '\000-\037')"
        if [[ -n "$emsg" ]]; then
            printf 'rpc-error %s %s\n' "$ecode" "${emsg:0:200}"
        else
            printf 'rpc-error %s\n' "$ecode"
        fi
        return 1
    fi
    res_re='"result"[[:space:]]*:'
    if [[ ! "$resp" =~ $res_re ]]; then
        printf 'malformed no-result\n'
        return 1
    fi
    printf '%s\n' "$resp"
    return 0
}

# tn_json_field <json> <key> — print the value of the first "<key>": that holds a
# scalar: a string (printed without its quotes, with \" and \\ unescaped and any
# other escape left as written), a number or a boolean. rc 1 when the key is
# missing or its value is null, an object or an array. A plain text matcher, not
# a JSON parser: it is meant for the flat JSON-RPC answers these scripts read.
tn_json_field() {
    local json="${1:-}" key="${2:-}" re val str out c
    [[ "$key" =~ ^[A-Za-z0-9_]+$ ]] || return 1
    re='"'"${key}"'"[[:space:]]*:[[:space:]]*("(([^"\\]|\\.)*)"|[-+.0-9A-Za-z]+|[[{])'
    [[ "$json" =~ $re ]] || return 1
    val="${BASH_REMATCH[1]}"
    str="${BASH_REMATCH[2]}"
    case "$val" in
        \"*)
            out=""
            while [[ "$str" == *\\* ]]; do
                out="${out}${str%%\\*}"
                str="${str#*\\}"
                c="${str:0:1}"
                if [[ "$c" == "\"" || "$c" == "\\" ]]; then
                    out="${out}${c}"
                    str="${str:1}"
                else
                    out="${out}\\"
                fi
            done
            printf '%s\n' "${out}${str}"
            return 0
            ;;
        "["|"{"|null)
            return 1
            ;;
    esac
    printf '%s\n' "$val"
    return 0
}

# _tn_json_uint <json> <key> — tn_json_field, then _tn_uint (decimal or 0x-hex in,
# decimal out). rc 1 when the field is missing or not such a number.
_tn_json_uint() {
    local v
    v="$(tn_json_field "${1:-}" "${2:-}")" || return 1
    _tn_uint "$v"
}

# tn_local_rpc_url — the local node's HTTP RPC: http://127.0.0.1:<port>, where the
# port is RPC_PORT from .node-meta, else the RPC_PORT variable, else 8545.
tn_local_rpc_url() {
    local port=""
    port="$(meta_get RPC_PORT 2>/dev/null || true)"
    if ! validate_port "$port" 2>/dev/null; then
        port="${RPC_PORT:-}"
        if ! validate_port "$port" 2>/dev/null; then
            port="$DEFAULT_RPC_PORT"
        fi
    fi
    printf 'http://127.0.0.1:%s\n' "$((10#$port))"
}

# tn_node_mode [url] — the node's consensus mode from tn_nodeMode: CvvActive (in
# the committee and voting), CvvInactive (in the committee, catching up) or
# Observer. url defaults to tn_local_rpc_url. Any other answer is malformed.
tn_node_mode() {
    local url="${1:-}" out rc mode
    [[ -n "$url" ]] || url="$(tn_local_rpc_url)"
    rc=0
    out="$(tn_rpc_call "$url" tn_nodeMode '[]')" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '%s\n' "$out"
        return 1
    fi
    mode="$(tn_json_field "$out" result || true)"
    case "$mode" in
        CvvActive|CvvInactive|Observer)
            printf '%s\n' "$mode"
            return 0
            ;;
    esac
    mode="$(printf '%s' "$mode" | tr -cd 'A-Za-z0-9_-')"
    mode="${mode:0:40}"
    printf 'malformed node-mode %s\n' "${mode:-none}"
    return 1
}

# tn_epoch_info [url] [epoch] [max_time] — one line from tn_getCurrentEpochInfo,
# or from tn_getEpochInfo when a decimal epoch is given (nodes answer for
# current-3 up to current+2):
#   <epoch_id> <block_height> <epoch_duration> <stake_version> <committee_csv|->
# The committee is the comma-separated lowercase list of member addresses, or
# "-" when empty. block_height is the first block of the epoch and
# epoch_duration is in seconds. epochIssuance is never decoded. max_time bounds
# the call in seconds (tn_rpc_call's default 10 when empty).
tn_epoch_info() {
    local url="${1:-}" epoch="${2:-}" max_time="${3:-10}" out rc id height dur ver inner addr list committee_re addr_re
    [[ -n "$url" ]] || url="$(tn_local_rpc_url)"
    rc=0
    if [[ -n "$epoch" ]]; then
        if [[ ! "$epoch" =~ ^[0-9]{1,10}$ ]]; then
            printf 'malformed bad-epoch\n'
            return 1
        fi
        out="$(tn_rpc_call "$url" tn_getEpochInfo "[$((10#$epoch))]" "$max_time")" || rc=$?
    else
        out="$(tn_rpc_call "$url" tn_getCurrentEpochInfo '[]' "$max_time")" || rc=$?
    fi
    if [[ "$rc" -ne 0 ]]; then
        printf '%s\n' "$out"
        return 1
    fi
    id="$(_tn_json_uint "$out" epochId)" || { printf 'malformed no-epochId\n'; return 1; }
    height="$(_tn_json_uint "$out" blockHeight)" || { printf 'malformed no-blockHeight\n'; return 1; }
    dur="$(_tn_json_uint "$out" epochDuration)" || { printf 'malformed no-epochDuration\n'; return 1; }
    ver="$(_tn_json_uint "$out" stakeVersion)" || { printf 'malformed no-stakeVersion\n'; return 1; }
    committee_re='"committee"[[:space:]]*:[[:space:]]*[[]([^]]*)[]]'
    addr_re='(0x[0-9a-fA-F]{40})'
    list=""
    if [[ "$out" =~ $committee_re ]]; then
        inner="${BASH_REMATCH[1]}"
        while [[ "$inner" =~ $addr_re ]]; do
            addr="${BASH_REMATCH[1]}"
            list="${list:+${list},}${addr}"
            inner="${inner#*"$addr"}"
        done
    fi
    list="$(printf '%s' "$list" | tr '[:upper:]' '[:lower:]')"
    printf '%s %s %s %s %s\n' "$id" "$height" "$dur" "$ver" "${list:--}"
}

# tn_epoch_secs_left [url] — time to the end of the current epoch:
#   <secs_left> <epoch_id> <boundary_unix> <epoch_duration>
# The boundary is timestamp(block[blockHeight-1]) + epochDuration, the block
# being the last one of the previous epoch. secs_left is negative once the
# boundary has passed: the epoch then closes at the first commit after it, and
# the epoch votes go round for another 60 to 75 seconds.
tn_epoch_secs_left() {
    local url="${1:-}" info rc id height dur n blk ts now boundary
    [[ -n "$url" ]] || url="$(tn_local_rpc_url)"
    rc=0
    info="$(tn_epoch_info "$url")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '%s\n' "$info"
        return 1
    fi
    id=""
    height=""
    dur=""
    read -r id height dur _ <<<"$info"
    n=0
    if (( height > 0 )); then
        n=$(( height - 1 ))
    fi
    rc=0
    blk="$(tn_rpc_call "$url" eth_getBlockByNumber "[\"$(printf '0x%x' "$n")\",false]")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '%s\n' "$blk"
        return 1
    fi
    ts="$(_tn_json_uint "$blk" timestamp)" || { printf 'malformed no-block-timestamp\n'; return 1; }
    now="$(_tn_now)"
    if [[ "$now" == "0" ]]; then
        printf 'malformed no-clock\n'
        return 1
    fi
    boundary=$(( ts + dur ))
    printf '%s %s %s %s\n' "$(( boundary - now ))" "$id" "$boundary" "$dur"
}

# _tn_env_uint <name> <default> — the environment variable <name> when it is a
# plain non-negative integer (at most 9 digits), else <default>.
_tn_env_uint() {
    local v="${!1:-}"
    if [[ "$v" =~ ^[0-9]{1,9}$ ]]; then
        printf '%s\n' "$(( 10#$v ))"
    else
        printf '%s\n' "${2:-0}"
    fi
}

# _tn_fmt_secs <n> — "1h 5m", "4m 10s" or "45s" for a non-negative count.
_tn_fmt_secs() {
    local s="${1:-0}" h m
    [[ "$s" =~ ^[0-9]+$ ]] || s=0
    s=$(( 10#$s ))
    h=$(( s / 3600 ))
    m=$(( (s % 3600) / 60 ))
    s=$(( s % 60 ))
    if (( h > 0 )); then
        printf '%dh %dm' "$h" "$m"
    elif (( m > 0 )); then
        printf '%dm %ds' "$m" "$s"
    else
        printf '%ds' "$s"
    fi
}

# _tn_due_text <secs-left> — "due in 4m 10s", "due now" or "passed 30s ago ...".
_tn_due_text() {
    local s="${1:-0}"
    [[ "$s" =~ ^-?[0-9]+$ ]] || s=0
    if (( s > 0 )); then
        printf 'due in %s' "$(_tn_fmt_secs "$s")"
    elif (( s == 0 )); then
        printf 'due now'
    else
        printf 'passed %s ago (the epoch closes at the next commit)' "$(_tn_fmt_secs "$(( -s ))")"
    fi
}

# _tn_wait_say <step|log|warn> <message> — the default progress printer for
# tn_wait_restart_window. Writes to stderr, so a caller that prints JSON on
# stdout keeps it clean even when it passes no printer of its own.
_tn_wait_say() {
    case "${1:-}" in
        step) print_step "${2:-}" >&2 ;;
        warn) print_warn "${2:-}" >&2 ;;
        *)    print_info "${2:-}" >&2 ;;
    esac
    return 0
}

# tn_wait_restart_window [url] [progress-fn] — before a committee node is stopped,
# wait for the current epoch to close so the restart does not land on the epoch
# change, when the node's vote matters most. Always rc 0 and never exits: on any
# doubt it reports and returns, so the caller carries on. progress-fn (default
# _tn_wait_say, on stderr) is called as `fn step|log|warn MESSAGE`; JSON-mode
# callers pass one that emits events. url defaults to tn_local_rpc_url.
#
# Environment: TN_SKIP_EPOCH_WAIT=1 skips the wait; TN_EPOCH_MARGIN (300) is how
# close the boundary must be before waiting; TN_EPOCH_SETTLE (90) is the pause
# after the epoch changes; TN_EPOCH_WAIT_MAX (1800) caps the whole wait, settle
# included, and 0 turns the wait off; TN_EPOCH_POLL (15, clamped to 5-20) is the
# poll and heartbeat interval. Each epoch read while waiting may take at most
# 30 - poll seconds, so two heartbeats are never more than 30 s apart.
#
# Policy:
#   1. Skipped (TN_SKIP_EPOCH_WAIT=1 or TN_EPOCH_WAIT_MAX=0), node mode
#      unreadable, or mode not CvvActive: log and return.
#   2. Time to the boundary unreadable: warn and return. More than the margin
#      away: log and return. Passed more than the margin ago with the epoch still
#      open (stalled, or this node far behind): warn once and return.
#   3. Otherwise one step message, then poll until the epoch id rises, with a log
#      heartbeat every poll. Two failed reads in a row, or the cap: warn, return.
#   4. Settle for TN_EPOCH_SETTLE seconds with heartbeats, inside the cap.
# Callers wait before stopping or editing anything, and never before the restart
# that rolls back a failed change.
tn_wait_restart_window() {
    local url="${1:-}" fn="${2:-}"
    local margin settle cap poll mode out rc secs epoch boundary dur
    local start now waited slept remaining nap due fails cur info note settle_left
    [[ -n "$url" ]] || url="$(tn_local_rpc_url)"
    if [[ -z "$fn" ]] || ! declare -F "$fn" >/dev/null 2>&1; then
        fn="_tn_wait_say"
    fi
    margin="$(_tn_env_uint TN_EPOCH_MARGIN 300)"
    settle="$(_tn_env_uint TN_EPOCH_SETTLE 90)"
    cap="$(_tn_env_uint TN_EPOCH_WAIT_MAX 1800)"
    poll="$(_tn_env_uint TN_EPOCH_POLL 15)"
    if (( poll < 5 )); then poll=5; fi
    if (( poll > 20 )); then poll=20; fi

    if [[ "${TN_SKIP_EPOCH_WAIT:-}" == "1" ]]; then
        "$fn" log "Not waiting for the epoch boundary (TN_SKIP_EPOCH_WAIT=1)." || true
        return 0
    fi
    if (( cap == 0 )); then
        "$fn" log "Not waiting for the epoch boundary: epoch wait disabled by TN_EPOCH_WAIT_MAX=0." || true
        return 0
    fi
    rc=0
    mode="$(tn_node_mode "$url")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        "$fn" log "Could not read the node mode from ${url} (${mode}); not waiting for the epoch boundary." || true
        return 0
    fi
    if [[ "$mode" != "CvvActive" ]]; then
        "$fn" log "Node mode is ${mode}, so this node is not voting in the current committee; no need to wait for the epoch boundary." || true
        return 0
    fi
    rc=0
    out="$(tn_epoch_secs_left "$url")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        "$fn" warn "This node is in the committee, but the time to the next epoch boundary could not be read (${out}). Continuing without waiting." || true
        return 0
    fi
    secs=0
    epoch=""
    boundary=0
    dur=0
    read -r secs epoch boundary dur <<<"$out"
    if [[ ! "$secs" =~ ^-?[0-9]+$ || ! "$epoch" =~ ^[0-9]+$ || ! "$boundary" =~ ^[0-9]+$ ]]; then
        "$fn" warn "This node is in the committee, but the epoch timing answer was not understood (${out}). Continuing without waiting." || true
        return 0
    fi
    if (( secs > margin )); then
        "$fn" log "Epoch ${epoch} ends in $(_tn_fmt_secs "$secs"), outside the ${margin}s margin; no need to wait." || true
        return 0
    fi
    # The boundary passed longer ago than the margin and the epoch is still open:
    # it is stalled or this node is far behind, and waiting cannot help either.
    if (( secs < -margin )); then
        "$fn" warn "Epoch ${epoch} should have ended $(_tn_fmt_secs "$(( -secs ))") ago and has not; not waiting." || true
        return 0
    fi

    "$fn" step "Waiting for epoch ${epoch} to close before restarting: this node is in the committee and the boundary is $(_tn_due_text "$secs"). Waiting at most ${cap}s (TN_EPOCH_WAIT_MAX); set TN_SKIP_EPOCH_WAIT=1 to skip." || true
    start="$(_tn_now)"
    slept=0
    fails=0
    cur=""
    info=""
    note=""
    while :; do
        # Elapsed time is the clock or the sum of the naps, whichever is larger,
        # so the cap holds even when the clock does not move.
        now="$(_tn_now)"
        waited=$(( now - start ))
        if (( slept > waited )); then waited="$slept"; fi
        remaining=$(( cap - waited ))
        if (( remaining <= 0 )); then
            "$fn" warn "Epoch ${epoch} has not closed after ${waited}s (limit ${cap}s, TN_EPOCH_WAIT_MAX). Continuing anyway." || true
            return 0
        fi
        nap="$poll"
        if (( nap > remaining )); then nap="$remaining"; fi
        sleep "$nap" || true
        slept=$(( slept + nap ))
        now="$(_tn_now)"
        waited=$(( now - start ))
        if (( slept > waited )); then waited="$slept"; fi
        due=$(( boundary - now ))
        # Heartbeat before the read, so a slow read never stretches the gap.
        "$fn" log "Still waiting for epoch ${epoch} to close: ${waited}s so far, boundary $(_tn_due_text "$due").${note}" || true
        note=""
        rc=0
        info="$(tn_epoch_info "$url" "" "$(( 30 - poll ))")" || rc=$?
        if [[ "$rc" -ne 0 ]]; then
            fails=$(( fails + 1 ))
            if (( fails >= 2 )); then
                "$fn" warn "Could not read the epoch twice in a row (${info}). Continuing without waiting further." || true
                return 0
            fi
            note=" The last epoch read failed (${info}); retrying."
            continue
        fi
        fails=0
        cur="${info%% *}"
        if [[ "$cur" =~ ^[0-9]+$ ]] && (( 10#$cur > 10#$epoch )); then
            break
        fi
    done

    now="$(_tn_now)"
    waited=$(( now - start ))
    if (( slept > waited )); then waited="$slept"; fi
    settle_left="$settle"
    if (( settle_left > cap - waited )); then settle_left=$(( cap - waited )); fi
    if (( settle_left <= 0 )); then
        if (( settle > 0 )); then
            "$fn" log "Epoch ${epoch} closed (now epoch ${cur}); the wait limit leaves no time to settle. Continuing." || true
        else
            "$fn" log "Epoch ${epoch} closed (now epoch ${cur}). Continuing." || true
        fi
        return 0
    fi
    "$fn" log "Epoch ${epoch} closed (now epoch ${cur}). Giving the new committee ${settle_left}s to settle." || true
    while (( settle_left > 0 )); do
        nap="$poll"
        if (( nap > settle_left )); then nap="$settle_left"; fi
        sleep "$nap" || true
        settle_left=$(( settle_left - nap ))
        if (( settle_left > 0 )); then
            "$fn" log "Settling: ${settle_left}s left." || true
        fi
    done
    "$fn" log "Epoch ${cur} is under way; continuing." || true
    return 0
}

# tn_hex_to_dec <hex> — print an unsigned hex number of any length (0x optional,
# up to 64 digits for a 256-bit word) in decimal. Long arithmetic in base-1e9
# limbs, so a 256-bit wei amount never touches 64-bit bash arithmetic and no
# python3 is needed. rc 1 when <hex> is empty or not hex.
tn_hex_to_dec() {
    local hex="${1:-}" i d j n v carry out
    local -a limbs=()
    hex="${hex#0x}"
    hex="${hex#0X}"
    [[ -n "$hex" && ${#hex} -le 64 && "$hex" =~ ^[0-9A-Fa-f]+$ ]] || return 1
    limbs=(0)
    i=0
    while (( i < ${#hex} )); do
        d=$(( 16#${hex:i:1} ))
        carry="$d"
        n=${#limbs[@]}
        j=0
        while (( j < n )); do
            v=$(( limbs[j] * 16 + carry ))
            limbs[j]=$(( v % 1000000000 ))
            carry=$(( v / 1000000000 ))
            j=$(( j + 1 ))
        done
        if (( carry > 0 )); then
            limbs[n]="$carry"
        fi
        i=$(( i + 1 ))
    done
    n=${#limbs[@]}
    out="${limbs[n-1]}"
    j=$(( n - 2 ))
    while (( j >= 0 )); do
        out="${out}$(printf '%09d' "${limbs[j]}")"
        j=$(( j - 1 ))
    done
    printf '%s\n' "$out"
}

# tn_wei_to_tel <wei-decimal> — format a wei amount (a decimal string of any
# length) as TEL, 18 decimals: "1,000,000" or "0.5". String handling only.
tn_wei_to_tel() {
    local wei="${1:-}" int frac out
    [[ "$wei" =~ ^[0-9]+$ ]] || return 1
    wei="${wei#"${wei%%[!0]*}"}"
    [[ -n "$wei" ]] || wei="0"
    if (( ${#wei} > 18 )); then
        int="${wei:0:${#wei}-18}"
        frac="${wei:${#wei}-18}"
    else
        int="0"
        frac="000000000000000000${wei}"
        frac="${frac:${#frac}-18}"
    fi
    # Drop the trailing zeros of the fraction.
    frac="${frac%"${frac##*[!0]}"}"
    out=""
    while (( ${#int} > 3 )); do
        out=",${int:${#int}-3}${out}"
        int="${int:0:${#int}-3}"
    done
    out="${int}${out}"
    if [[ -n "$frac" ]]; then
        out="${out}.${frac}"
    fi
    printf '%s\n' "$out"
}

# =============================================================================
# VALIDATOR ON-CHAIN STATUS CHECK
# =============================================================================
#
# Calls getValidator(address) on the ConsensusRegistry contract and decodes
# the ValidatorStatus from the response. Uses the local node RPC — no wallet
# or external dependencies needed, it is a read-only eth_call.
#
# ValidatorStatus enum from the contract:
#   0 = Undefined  (NFT exists but never staked)
#   1 = Staked     (staked, waiting to call activate())
#   2 = PendingActivation (activate() called, waiting for next epoch)
#   3 = Active     (fully active in consensus)
#   4 = PendingExit
#   5 = Exited
#   6 = Any        (sentinel for status queries, not a lifecycle stage; the
#                   contract parks a retired validator's record here)
#
# Retirement itself is the separate isRetired bool (struct word 4). A retired
# record is a tombstone: getValidator still answers for it after the NFT is
# burned, and the address can never stake again.
#
# ConsensusRegistry address (from tn-contracts/deployments/deployments.json):
readonly CONSENSUS_REGISTRY="0x07e17e17e17e17e17e17e17e17e17e17e17e17e1"
#
# Function selectors (first 4 bytes of keccak256 of the signature):
#   getValidator(address)     0x1904bb2e
#   getCurrentStakeVersion()  0x67398331
#   stakeConfig(uint8)        0xa71954ec
readonly GET_VALIDATOR_SELECTOR="0x1904bb2e"
readonly GET_CURRENT_STAKE_VERSION_SELECTOR="0x67398331"
readonly STAKE_CONFIG_SELECTOR="0xa71954ec"

# _tn_word_fits <64-hex-word> <bits> — rc 0 when the word is 64 hex characters and
# every bit above the low <bits> is zero: a valid ABI encoding of a uint<bits>
# (160 for an address, 8 for a bool or an enum).
_tn_word_fits() {
    local word="${1:-}" bits="${2:-256}" lead
    [[ ${#word} -eq 64 && "$word" =~ ^[0-9a-fA-F]+$ ]] || return 1
    lead="${word:0:$(( 64 - bits / 4 ))}"
    [[ "$lead" =~ ^0*$ ]]
}

# node_stake_status <address> [rpc_url] — the single getValidator(address) probe.
# Prints exactly ONE line on stdout and nothing else (no print_* output):
#   "<status> <activation_epoch> <is_retired> <exit_epoch>"  rc 0  e.g. "3 12 0 0"
#   "none"                       rc 0  the call reverted: no ConsensusNFT
#   "unknown bad-address"        rc 1  address empty or malformed
#   "unknown <kind> <detail>"    rc 2  the status could not be read; kind and detail
#                                      come from tn_rpc_call (transport ..., http 429,
#                                      rpc-error ..., malformed ...)
# status is the ValidatorStatus enum above in decimal; is_retired is 0 or 1;
# exit_epoch is 0 until an exit starts and 4294967295 while it is pending. The
# first three fields keep their old order, so a reader written for the older
# three-field line keeps working as long as it reads a spare last variable
# (read -r status epoch retired _). rpc_url defaults to tn_local_rpc_url.
#
# The ValidatorInfo struct is ABI-encoded INLINE in the response: seven 32-byte
# words (64 hex characters each, word N at hex offset 64*N), no offset pointer:
#   word 0 validatorAddress  address
#   word 1 activationEpoch   uint32
#   word 2 exitEpoch         uint32
#   word 3 currentStatus     uint8 enum, 0-6
#   word 4 isRetired         bool
#   word 5 stakeVersion      uint8
#   word 6 region            uint8
# (IConsensusRegistry.ValidatorInfo in tn-contracts 10cc12b7, the commit
# v0.15.0-adiri pins.) The decode is strict: exactly seven words, each zero above
# its type, isRetired 0 or 1, status within the enum, and status 6 (Any) only
# with isRetired set: retiring a validator writes Any plus isRetired, the record
# kept as a tombstone, and nothing writes Any alone. Anything else is
# "unknown malformed ...", never a guessed status. Only the low bits are
# decoded, so bash arithmetic never sees a 256-bit value.
node_stake_status() {
    local address="${1:-}" rpc_url="${2:-}"
    local call_data out rc kind rest ecode emsg result_re hex bits i
    local status activation exit_epoch retired
    if [[ -z "$address" ]] || [[ ! "$address" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        printf '%s\n' "unknown bad-address"
        return 1
    fi
    [[ -n "$rpc_url" ]] || rpc_url="$(tn_local_rpc_url)"

    # ABI-encode the call: selector + address left-padded to a 32-byte word.
    call_data="${GET_VALIDATOR_SELECTOR}000000000000000000000000${address:2}"
    rc=0
    out="$(tn_rpc_call "$rpc_url" eth_call "[{\"to\":\"${CONSENSUS_REGISTRY}\",\"data\":\"${call_data}\"},\"latest\"]")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        # getValidator reverts with InvalidTokenId(uint256) (data 0xed15e6cf...) for
        # an address that holds no ConsensusNFT, and reth reports a revert as error
        # code 3 ("execution reverted"). Any other error (rate limit, method not
        # found, ...) says nothing about the address.
        kind="${out%% *}"
        if [[ "$kind" == "rpc-error" ]]; then
            rest="${out#rpc-error }"
            ecode="${rest%% *}"
            emsg=""
            if [[ "$rest" == *" "* ]]; then
                emsg="${rest#* }"
            fi
            if [[ "$ecode" == "3" || "$emsg" =~ [Rr]evert ]]; then
                printf '%s\n' "none"
                return 0
            fi
        fi
        printf 'unknown %s\n' "$out"
        return 2
    fi

    result_re='"result"[[:space:]]*:[[:space:]]*"0x([0-9a-fA-F]*)"'
    if [[ ! "$out" =~ $result_re ]]; then
        printf '%s\n' "unknown malformed result-not-hex"
        return 2
    fi
    hex="${BASH_REMATCH[1]}"
    if [[ ${#hex} -ne 448 ]]; then
        printf 'unknown malformed result-length %s\n' "${#hex}"
        return 2
    fi
    # Bits each word may use: address, uint32, uint32, uint8, bool, uint8, uint8.
    i=0
    for bits in 160 32 32 8 8 8 8; do
        if ! _tn_word_fits "${hex:$(( i * 64 )):64}" "$bits"; then
            printf 'unknown malformed word-%s\n' "$i"
            return 2
        fi
        i=$(( i + 1 ))
    done
    activation=$(( 16#${hex:120:8} ))
    exit_epoch=$(( 16#${hex:184:8} ))
    status=$(( 16#${hex:254:2} ))
    retired=$(( 16#${hex:318:2} ))
    if (( status > 6 )); then
        printf '%s\n' "unknown malformed word-3"
        return 2
    fi
    if (( retired > 1 )); then
        printf '%s\n' "unknown malformed word-4"
        return 2
    fi
    if (( status == 6 && retired == 0 )); then
        printf '%s\n' "unknown malformed status-6-not-retired"
        return 2
    fi
    printf '%s %s %s %s\n' "$status" "$activation" "$retired" "$exit_epoch"
    return 0
}

# tn_stake_amount_wei [rpc_url] [max_time] — the stake the registry asks for now:
#   "<wei> <stake_version>"  rc 0, wei as a decimal string (1e24, 1,000,000 TEL,
#                            on testnet today)
# Reads getCurrentStakeVersion(), then word 0 (stakeAmount) of the four-word
# stakeConfig(version). Failures follow the RPC helper contract: rc 1 and one
# "<kind> <detail>" line. rpc_url defaults to tn_local_rpc_url; max_time (per
# call, seconds) to 10. Format the amount with tn_wei_to_tel.
tn_stake_amount_wei() {
    local rpc_url="${1:-}" max_time="${2:-10}" out rc result_re hex ver wei
    [[ -n "$rpc_url" ]] || rpc_url="$(tn_local_rpc_url)"
    result_re='"result"[[:space:]]*:[[:space:]]*"0x([0-9a-fA-F]*)"'
    rc=0
    out="$(tn_rpc_call "$rpc_url" eth_call "[{\"to\":\"${CONSENSUS_REGISTRY}\",\"data\":\"${GET_CURRENT_STAKE_VERSION_SELECTOR}\"},\"latest\"]" "$max_time")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '%s\n' "$out"
        return 1
    fi
    hex=""
    if [[ "$out" =~ $result_re ]]; then
        hex="${BASH_REMATCH[1]}"
    fi
    if ! _tn_word_fits "$hex" 8; then
        printf '%s\n' "malformed stake-version"
        return 1
    fi
    ver=$(( 16#${hex:62:2} ))
    rc=0
    out="$(tn_rpc_call "$rpc_url" eth_call "[{\"to\":\"${CONSENSUS_REGISTRY}\",\"data\":\"${STAKE_CONFIG_SELECTOR}$(printf '%064x' "$ver")\"},\"latest\"]" "$max_time")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '%s\n' "$out"
        return 1
    fi
    hex=""
    if [[ "$out" =~ $result_re ]]; then
        hex="${BASH_REMATCH[1]}"
    fi
    if [[ ${#hex} -ne 256 ]]; then
        printf 'malformed stake-config-length %s\n' "${#hex}"
        return 1
    fi
    wei="$(tn_hex_to_dec "${hex:0:64}")" || { printf '%s\n' "malformed stake-amount"; return 1; }
    printf '%s %s\n' "$wei" "$ver"
}

# node_is_staked_validator <address> [rpc_url] — no output. rc 0 when the registry
# reports a registered validator (status 1-4: Staked, PendingActivation, Active,
# PendingExit); rc 1 for a definite non-validator (status 0, 5 or 6, or no NFT
# record); rc 2 when the status could not be read (see node_stake_status).
node_is_staked_validator() {
    local out status rc
    rc=0
    out="$(node_stake_status "${1:-}" "${2:-}")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        return 2
    fi
    status="${out%% *}"
    case "$status" in
        1|2|3|4) return 0 ;;
    esac
    return 1
}

# print_validator_onchain_status <address> <result-line> [is_retired 0|1]
#   [current_epoch] — render the operator-facing report for a node_stake_status
# result line ("<status> <activation_epoch> <is_retired> <exit_epoch>", the older
# three-field form without exit_epoch, or "none"). This is the single copy of the
# status label table and the "Next step" text. The optional third argument
# overrides the is_retired field of the line (pass "" to keep it). The optional
# fourth argument is the network's current epoch; for an Exited validator it
# says whether unstake() is eligible now. Callers (check-node.sh,
# update-node.sh) grep the "Status: <label>" and "No validator record found"
# strings, so keep those labels stable. Returns 1 (after a warning) when the
# line is not a decoded result.
print_validator_onchain_status() {
    local validator_address="${1:-}" line="${2:-}" retired_arg="${3:-}" cur_epoch="${4:-}"
    local status epoch retired exit_epoch status_label next_step eligible
    status=""
    epoch=""
    retired=""
    exit_epoch=""
    read -r status epoch retired exit_epoch _ <<<"$line" || true

    if [[ "$status" == "none" ]]; then
        print_warn "No validator record found for ${validator_address}"
        print_info "This means no ConsensusNFT has been minted for this address yet."
        echo ""
        print_info "Next step:"
        echo "    Submit your ECDSA validator address to the Telcoin Association"
        echo "    for governance approval: ${validator_address}"
        echo "    Once approved, governance will mint a ConsensusNFT to your address."
        return 0
    fi

    if [[ ! "$status" =~ ^[0-9]+$ ]]; then
        print_warn "Empty response from contract -- node may still be syncing or NFT not yet minted."
        return 1
    fi
    [[ "$epoch" =~ ^[0-9]+$ ]] || epoch="?"
    if [[ -n "$retired_arg" ]]; then
        retired="$retired_arg"
    fi
    [[ "$retired" == "1" ]] || retired="0"
    # exitEpoch is 0 before an exit starts and type(uint32).max while it is pending;
    # neither is an epoch the validator exited at.
    if [[ "$exit_epoch" =~ ^[0-9]{1,10}$ ]]; then
        exit_epoch=$(( 10#$exit_epoch ))
        if [[ "$exit_epoch" == "0" || "$exit_epoch" == "4294967295" ]]; then
            exit_epoch=""
        fi
    else
        exit_epoch=""
    fi
    [[ "$cur_epoch" =~ ^[0-9]{1,10}$ ]] || cur_epoch=""

    case "$status" in
        0)
            status_label="Undefined (NFT minted, not yet staked)"
            next_step="You have a ConsensusNFT. Next: stake your TEL by calling stake() on the ConsensusRegistry contract with your BLS public key."
            ;;
        1)
            status_label="Staked (waiting for activation)"
            next_step="You have staked. Next: call activate() on the ConsensusRegistry contract to enter the activation queue."
            ;;
        2)
            status_label="Pending Activation (activating at next epoch)"
            next_step="Activation is in progress. You will become Active at epoch ${epoch}. No action needed."
            ;;
        3)
            status_label="Active (participating in consensus)"
            next_step="Your validator is fully active. No action needed."
            ;;
        4)
            status_label="Pending Exit"
            next_step="Your validator is exiting. It will be removed from the committee at the next eligible epoch."
            ;;
        5)
            status_label="Exited"
            # unstake() is eligible from the epoch after the exit epoch.
            if [[ -n "$exit_epoch" ]]; then
                eligible=$(( 10#$exit_epoch + 1 ))
                next_step="Your validator exited at epoch ${exit_epoch}; unstake() becomes eligible at epoch ${eligible}."
                if [[ -z "$cur_epoch" ]]; then
                    next_step="${next_step} The current epoch was not read, so check it before calling unstake() to reclaim your TEL stake."
                elif (( 10#$cur_epoch >= eligible )); then
                    next_step="${next_step} That is now: the network is at epoch ${cur_epoch}, so you can call unstake() to reclaim your TEL stake."
                else
                    next_step="${next_step} That is not yet: the network is at epoch ${cur_epoch}, $(( eligible - 10#$cur_epoch )) epoch(s) to go."
                fi
            else
                next_step="Your validator has exited. unstake() becomes eligible from the epoch after its exit epoch; call it then to reclaim your TEL stake."
            fi
            ;;
        6)
            # Retiring moves the record to Any and sets isRetired, so Any + retired is
            # the normal retired tombstone and keeps the plain "Retired" label.
            if [[ "$retired" == "1" ]]; then
                status_label="Retired"
                next_step="This validator has been permanently retired."
            else
                status_label="Any (reserved status sentinel)"
                next_step="Contact the Telcoin Association for assistance."
            fi
            ;;
        *)
            status_label="Unknown (status code: ${status})"
            next_step="Contact the Telcoin Association for assistance."
            ;;
    esac
    if [[ "$retired" == "1" ]] && [[ "$status" != "6" ]]; then
        status_label="${status_label} (Retired)"
    fi

    # Display results
    if [[ "$status" -eq 3 ]]; then
        print_ok "ConsensusNFT: Found"
        print_ok "Status: ${status_label}"
    elif [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]] || [[ "$status" -eq 2 ]]; then
        print_ok "ConsensusNFT: Found"
        print_warn "Status: ${status_label}"
    else
        print_warn "Status: ${status_label}"
    fi
    if [[ "$retired" == "1" ]]; then
        print_info "This validator is retired (isRetired is set on-chain): the address can never rejoin."
        print_info "Onboarding again needs new keys and a new ConsensusNFT."
    fi

    echo ""
    print_info "Next step:"
    echo "    ${next_step}"
    echo ""
    return 0
}

# check_validator_onchain_status <address> [rpc_url] — print the on-chain status
# report for an address. When the status cannot be read it says why, with one
# hint for each kind of failure: no answer (transport), rate limiting (HTTP 429),
# or an answer that did not decode (malformed). For an Exited validator it also
# reads the current epoch so the report can say whether unstake() is eligible.
# Returns 1 for a malformed address or an unreadable status, 0 when a report
# (including "No validator record found") was printed. rpc_url defaults to
# tn_local_rpc_url.
check_validator_onchain_status() {
    local validator_address="${1:-}" rpc_url="${2:-}"
    local out rc detail info cur_epoch

    [[ -n "$rpc_url" ]] || rpc_url="$(tn_local_rpc_url)"
    print_step "Checking validator on-chain status..."
    print_info "Address:  ${validator_address}"
    print_info "Contract: ${CONSENSUS_REGISTRY}"
    echo ""

    if [[ -z "$validator_address" ]] || [[ ! "$validator_address" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        print_warn "Invalid validator address -- skipping on-chain check."
        return 1
    fi

    rc=0
    out="$(node_stake_status "$validator_address" "$rpc_url")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        detail="${out#unknown }"
        print_warn "Could not read the on-chain stake status from ${rpc_url} (${detail})."
        case "$detail" in
            transport*)
                print_info "Nothing answered. Check that the node is running and its RPC listens on that address, then run the check again."
                ;;
            "http 429"*)
                print_info "The RPC is rate limiting requests (HTTP 429). Wait a minute and try again, or query your own node instead."
                ;;
            "http 502"*|"http 503"*|"http 504"*)
                print_info "The RPC endpoint is unavailable (HTTP ${detail#http }); try again in a minute."
                ;;
            malformed*)
                print_info "The RPC answered, but not with a getValidator result. The node may still be syncing, or the URL is not a Telcoin Network RPC."
                ;;
            *)
                print_info "The RPC refused the call. Check the URL, then run the check again."
                ;;
        esac
        return 1
    fi
    cur_epoch=""
    if [[ "${out%% *}" == "5" ]]; then
        info="$(tn_epoch_info "$rpc_url" || true)"
        cur_epoch="${info%% *}"
        [[ "$cur_epoch" =~ ^[0-9]+$ ]] || cur_epoch=""
    fi
    print_validator_onchain_status "$validator_address" "$out" "" "$cur_epoch" || true
    return 0
}

# display_node_info <data_dir> <validator_address> — show node-info.yaml after key
# generation and the steps to become a validator. Step 3 reads the stake amount
# live (getCurrentStakeVersion, then stakeConfig) from the network RPC in
# RPC_URL, which select_network sets; with RPC_URL empty, or when the read
# fails, it prints the cast commands instead. The steps end with a pointer to
# prepare-stake.sh, which runs the checks once the node has synced.
display_node_info() {
    local data_dir="$1"
    local validator_address="$2"
    local node_info_file="${data_dir}/node-info.yaml"
    local export_cmd node_info_arg stake_rpc stake_out stake_rc stake_wei stake_ver stake_tel value_arg

    echo ""
    print_step "Node Identity Information"

    if [[ ! -f "$node_info_file" ]]; then
        print_warn "node-info.yaml not found at: ${node_info_file}"
        print_info "Key generation may not have completed successfully."
        return 1
    fi

    echo ""
    echo "  Your node-info.yaml has been generated at:"
    echo "    ${node_info_file}"
    echo ""
    echo "  Contents:"
    print_sep
    cat "$node_info_file"
    print_sep
    echo ""
    print_warn "BACK UP your node-info.yaml and node-keys/ directory now."
    print_warn "Lost keys cannot be recovered without the passphrase."
    echo ""
    print_info "Next steps to become an active validator:"
    echo ""
    echo "  Step 1: Request Governance Approval"
    echo "    Submit your ECDSA validator address to the Telcoin Association:"
    echo "    Address: ${validator_address}"
    echo "    Governance will verify off-chain and mint a ConsensusNFT to your address."
    echo ""
    echo "  Step 2: Verify you have received your ConsensusNFT"
    echo "    cast call ${CONSENSUS_REGISTRY} \\"
    echo "      \"balanceOf(address)(uint256)\" \\"
    echo "      ${validator_address} \\"
    echo "      --rpc-url <RPC_URL>"
    echo "    (Returns 1 if whitelisted, 0 if not)"
    echo ""
    echo "  Step 3: Check required stake amount"
    stake_rpc="${RPC_URL:-}"
    value_arg="<STAKE_AMOUNT_FROM_STEP_3>"
    stake_out="RPC_URL is not set"
    stake_rc=1
    if [[ -n "$stake_rpc" ]]; then
        stake_rc=0
        stake_out="$(tn_stake_amount_wei "$stake_rpc" 5)" || stake_rc=$?
    fi
    stake_wei=""
    stake_ver=""
    stake_tel=""
    if [[ "$stake_rc" -eq 0 ]]; then
        read -r stake_wei stake_ver _ <<<"$stake_out"
        stake_tel="$(tn_wei_to_tel "$stake_wei" || true)"
    fi
    if [[ -n "$stake_tel" ]]; then
        echo "    Required stake: ${stake_tel} TEL (${stake_wei} wei, stake version ${stake_ver}),"
        echo "    read from ${stake_rpc}."
        value_arg="$stake_wei"
    else
        echo "    Could not read the stake amount (${stake_out}). Read it with:"
        echo "    cast call ${CONSENSUS_REGISTRY} \\"
        echo "      \"getCurrentStakeVersion()(uint8)\" --rpc-url <RPC_URL>"
        echo "    cast call ${CONSENSUS_REGISTRY} \\"
        echo "      \"stakeConfig(uint8)(uint256,uint256,uint256,uint32)\" <VERSION> --rpc-url <RPC_URL>"
        echo "    (The first value stakeConfig returns is the stake amount in wei.)"
    fi
    echo ""
    echo "  Step 4: On this node, export the stake(bytes,(bytes)) calldata (reads only node-info.yaml)"
    # keytool asks for a passphrase source even though this export never reads the
    # key, and -q keeps its log line out of the output; both go before `keytool`.
    if [[ "${INSTALL_METHOD:-}" == "docker" ]]; then
        export_cmd="docker run --rm -v ${data_dir}:/home/nonroot/data:ro ${DOCKER_IMAGE:-<IMAGE>} telcoin -q --bls-passphrase-source no-passphrase keytool"; node_info_arg="/home/nonroot/data/node-info.yaml"
    else
        export_cmd="${BINARY_PATH:-telcoin-network} -q --bls-passphrase-source no-passphrase keytool"; node_info_arg="$node_info_file"
    fi
    echo "    ${export_cmd} export-staking-args \\"
    echo "      --node-info ${node_info_arg} --calldata"
    echo ""
    echo "  Step 5: From the machine holding your validator wallet, submit the stake"
    echo "    cast send ${CONSENSUS_REGISTRY} <CALLDATA_FROM_STEP_4> \\"
    echo "      --value ${value_arg} --from ${validator_address} \\"
    echo "      --ledger --rpc-url <RPC_URL>"
    echo "    (Use --trezor or --interactive instead of --ledger to match your wallet.)"
    echo ""
    echo "  Step 6: Wait for node to sync, then activate"
    echo "    cast send ${CONSENSUS_REGISTRY} \"activate()\" \\"
    echo "      --from ${validator_address} --ledger --rpc-url <RPC_URL>"
    echo ""
    echo "  Once the node has synced, prepare-stake.sh does Steps 2 to 4 for you: it checks"
    echo "  the whitelist, the stake amount and your balance, simulates the stake, and prints"
    echo "  the exact commands for Steps 5 and 6:"
    echo "    sudo bash prepare-stake.sh"
    echo ""
    echo "  Full staking guide: https://docs.telcoin.network/telcoin-network/staking/how-to-stake"
    echo ""
}




# =============================================================================
# TPM / vTPM HELPER FUNCTIONS
# =============================================================================

# Check if a TPM2 chip is available on this system
tpm_check_available() {
    if [[ -e /dev/tpm0 ]] || [[ -e /dev/tpmrm0 ]]; then
        print_ok "TPM2 chip detected"
        # Install tpm2-tools if needed
        if ! command -v tpm2_createprimary &>/dev/null; then
            print_info "Installing tpm2-tools..."
            install_package "tpm2-tools"
        fi
        print_ok "tpm2-tools available"
        return 0
    else
        return 1
    fi
}

# Seal the BLS passphrase to the TPM chip.
# Stores sealed blob at ${config_dir}/bls-tpm.pub and bls-tpm.priv
# Shows the passphrase once and offers to delete the plaintext file.
#
# Usage: tpm_seal_passphrase <passphrase_file> <config_dir> <passphrase>
tpm_seal_passphrase() {
    local passphrase_file="$1"
    local config_dir="$2"
    local passphrase="$3"

    print_step "Sealing BLS passphrase to TPM..."

    # Create TPM primary key context
    if ! tpm2_createprimary -Q -C e -c /tmp/tn-tpm-primary.ctx 2>/dev/null; then
        print_error "TPM primary key creation failed."
        print_info "Falling back to LoadCredential file storage."
        rm -f /tmp/tn-tpm-primary.ctx
        return 1
    fi

    # Create sealed data object from passphrase file
    if ! tpm2_create -Q \
        -C /tmp/tn-tpm-primary.ctx \
        -i "$passphrase_file" \
        -u "${config_dir}/bls-tpm.pub" \
        -r "${config_dir}/bls-tpm.priv" 2>/dev/null; then
        print_error "TPM sealing failed."
        print_info "Falling back to LoadCredential file storage."
        rm -f /tmp/tn-tpm-primary.ctx "${config_dir}/bls-tpm.pub" "${config_dir}/bls-tpm.priv"
        return 1
    fi

    # Verify seal before removing primary context
    tpm2_load -Q -C /tmp/tn-tpm-primary.ctx         -u "${config_dir}/bls-tpm.pub"         -r "${config_dir}/bls-tpm.priv"         -c /tmp/tn-tpm-verify.ctx 2>/dev/null
    local verify_result
    verify_result=$(tpm2_unseal -Q -c /tmp/tn-tpm-verify.ctx 2>/dev/null || echo "")
    rm -f /tmp/tn-tpm-primary.ctx /tmp/tn-tpm-verify.ctx
    if [[ -z "$verify_result" ]]; then
        print_error "TPM seal verification failed."
        rm -f "${config_dir}/bls-tpm.pub" "${config_dir}/bls-tpm.priv"
        return 1
    fi
    print_ok "TPM seal verified successfully"
    chmod 600 "${config_dir}/bls-tpm.pub" "${config_dir}/bls-tpm.priv"
    chown "${SERVICE_USER}:${SERVICE_GROUP}" "${config_dir}/bls-tpm.pub" "${config_dir}/bls-tpm.priv" 2>/dev/null || true
    print_ok "Passphrase sealed to TPM: ${config_dir}/bls-tpm.pub / bls-tpm.priv"

    # Show passphrase once and offer to delete plaintext file
    echo ""
    print_warn "================================================================"
    print_warn "  IMPORTANT -- STORE YOUR PASSPHRASE OFFLINE NOW"
    print_warn "================================================================"
    print_warn "Your BLS passphrase has been sealed to this machine's TPM chip."
    print_warn "If this machine is rebuilt or the TPM is reset, you will need"
    print_warn "your passphrase to re-seal it."
    echo ""
    print_info "Your BLS passphrase is:"
    echo ""
    echo "    ${passphrase}"
    echo ""
    print_warn "Write this down and store it in a password manager or hardware"
    print_warn "wallet. This is the ONLY time it will be shown."
    print_warn "================================================================"
    echo ""

    local confirm_text
    read -r -p "  Type CONFIRMED to delete the plaintext passphrase file, or Enter to keep it: " confirm_text
    if [[ "$confirm_text" == "CONFIRMED" ]]; then
        rm -f "$passphrase_file"
        print_ok "Plaintext passphrase file deleted. TPM is the only copy on this machine."
        print_warn "Ensure you have stored your passphrase offline before continuing."
    else
        print_info "Plaintext file kept at: ${passphrase_file}"
        print_info "The node will use TPM first, falling back to the file if TPM is unavailable."
    fi
}

# Remove TPM sealed files for a node type (called during node removal)
tpm_remove_sealed_files() {
    local config_dir="$1"
    if [[ -f "${config_dir}/bls-tpm.pub" ]] || [[ -f "${config_dir}/bls-tpm.priv" ]]; then
        print_step "Removing TPM sealed passphrase files..."
        rm -f "${config_dir}/bls-tpm.pub" "${config_dir}/bls-tpm.priv"
        print_ok "TPM sealed files removed"
    fi
}

print_summary() {
    local title="$1"
    shift
    echo ""
    echo "${GREEN}${BOLD}================================================================${RESET}"
    echo "${GREEN}${BOLD}  ${title}${RESET}"
    echo "${GREEN}${BOLD}================================================================${RESET}"
    echo ""
    for item in "$@"; do
        local key="${item%%=*}"
        local value="${item#*=}"
        printf "  ${BOLD}%-22s${RESET} %s\n" "${key}:" "${value}"
    done
    echo ""
    echo "${GREEN}${BOLD}================================================================${RESET}"
    echo ""
}

# -----------------------------------------------------------------------------
# SOURCE VERSION PICKER
# Used by setup-{observer,validator}.sh and by update-node.sh.
# Echoes the chosen ref on stdout; informational output goes to stderr so the
# caller can capture the selection via $(...). Returns 0 on selection, 1 on
# cancel or error.
#
# Telcoin's testnet release tags (-adiri) sit on a branch parallel to main and
# are the recommended default for testnet operators (per the dev team).
# Main is acceptable for testnet (and is the right default for devnet) but is
# not the recommended default for testnet operators.
#
# Usage: pick_source_version <network>
#   network = "testnet" | "mainnet" | "devnet" | ""  (empty -> show everything)
# -----------------------------------------------------------------------------
pick_source_version() {
    local network="$1"
    if [[ ! -d "${TN_SOURCE_DIR}/.git" ]]; then
        print_error "Source directory not found at ${TN_SOURCE_DIR}" >&2
        return 1
    fi

    # Pick the suffix, minimum version, and label for the operator's network.
    local suffix="" min_ver="" net_label=""
    case "$network" in
        testnet) suffix="$NETWORK_TAG_SUFFIX_TESTNET"; min_ver="$MIN_SOURCE_VERSION_TESTNET"; net_label="testnet (adiri)" ;;
        mainnet) suffix="$NETWORK_TAG_SUFFIX_MAINNET"; min_ver="$MIN_SOURCE_VERSION_MAINNET"; net_label="mainnet" ;;
        devnet)  suffix="";  min_ver=""; net_label="devnet (follows main)" ;;
        *)       suffix="";  min_ver=""; net_label="unknown -- no tag filter" ;;
    esac

    print_step "Fetching latest refs from origin..." >&2
    if ! git -C "$TN_SOURCE_DIR" fetch --tags --quiet 2>/dev/null; then
        print_warn "git fetch failed -- showing cached refs only" >&2
    fi

    # Describe-style summary string (for display). Includes -N-gSHA suffix
    # when HEAD is past a tag, so the operator sees how far past.
    local current_describe
    current_describe=$(git -C "$TN_SOURCE_DIR" describe --tags --always --dirty 2>/dev/null || echo "unknown")

    # Accurate "where am I" detection. We compute three pieces of state and
    # use them in the display + marker logic below.
    #
    #   exact_tag       non-empty only when HEAD is EXACTLY at an annotated tag
    #   head_branch     name of the local branch HEAD is on (empty if detached)
    #   on_main_state   "tip"     -- on main branch, HEAD == origin/main
    #                   "behind"  -- on main branch, but origin/main has advanced
    #                   "none"    -- not on main (could be feature branch or detached)
    #   feature_branch  set to head_branch when on a NON-main local branch
    #                   (e.g. log_db_name) so we can label that instead of
    #                   misreporting the operator as "detached"
    local exact_tag head_sha main_sha head_branch on_main_state="none"
    local behind_count=0 main_tip_summary=""
    local feature_branch="" feature_ahead_main=0 feature_summary=""

    exact_tag=$(git -C "$TN_SOURCE_DIR" describe --tags --exact-match HEAD 2>/dev/null || echo "")
    head_sha=$(git -C "$TN_SOURCE_DIR" rev-parse HEAD 2>/dev/null || echo "")
    main_sha=$(git -C "$TN_SOURCE_DIR" rev-parse origin/main 2>/dev/null || echo "")
    head_branch=$(git -C "$TN_SOURCE_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "")

    if [[ "$head_branch" == "main" ]] && [[ -n "$head_sha" ]] && [[ -n "$main_sha" ]]; then
        if [[ "$head_sha" == "$main_sha" ]]; then
            on_main_state="tip"
        elif git -C "$TN_SOURCE_DIR" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
            on_main_state="behind"
            behind_count=$(git -C "$TN_SOURCE_DIR" rev-list --count HEAD..origin/main 2>/dev/null || echo "0")
            main_tip_summary=$(git -C "$TN_SOURCE_DIR" log --max-count=1 --format='%h %ar -- %s' origin/main 2>/dev/null || echo "")
        fi
    elif [[ -n "$head_branch" ]] && [[ "$head_branch" != "main" ]]; then
        # Operator is on a named local branch other than main (e.g. log_db_name).
        feature_branch="$head_branch"
        feature_ahead_main=$(git -C "$TN_SOURCE_DIR" rev-list --count origin/main..HEAD 2>/dev/null || echo "0")
        feature_summary=$(git -C "$TN_SOURCE_DIR" log -1 --format='%s' HEAD 2>/dev/null || echo "")
    fi

    # Collect tags, newest by creator date first.
    local -a all_tags
    while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        all_tags+=("$t")
    done < <(git -C "$TN_SOURCE_DIR" tag --sort=-creatordate 2>/dev/null | head -20)

    # Filter by network suffix when applicable. testnet keeps only tags
    # containing "-adiri", mainnet only "-telcoin". devnet/unknown keeps all.
    local -a tags
    if [[ -n "$suffix" ]]; then
        local t
        for t in "${all_tags[@]}"; do
            [[ "$t" == *"$suffix"* ]] && tags+=("$t")
        done
        # If filtering left us with nothing, fall back to showing everything
        # so the operator still has options.
        if [[ ${#tags[@]} -eq 0 ]]; then
            print_warn "No tags matched the ${network} pattern (${suffix}). Showing all tags." >&2
            tags=("${all_tags[@]}")
        fi
    else
        tags=("${all_tags[@]}")
    fi

    # Apply minimum-version filter: drop tags older than MIN_SOURCE_VERSION_*
    # so operators are not shown obsolete releases. main and custom remain
    # available below the list, so anyone who genuinely needs an older build
    # can still type it. If the filter would leave the list empty, fall back
    # to showing the unfiltered list rather than nothing.
    if [[ -n "$min_ver" ]]; then
        local -a recent_tags
        local tag base_ver
        for tag in "${tags[@]}"; do
            # Strip leading "v" and trailing "-suffix" to get X.Y.Z
            base_ver="${tag#v}"
            base_ver="${base_ver%%-*}"
            if [[ "$base_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
                && version_gte "$base_ver" "$min_ver"; then
                recent_tags+=("$tag")
            fi
        done
        if [[ ${#recent_tags[@]} -gt 0 ]]; then
            tags=("${recent_tags[@]}")
        else
            print_warn "No tags >= v${min_ver} found. Showing unfiltered list." >&2
        fi
    fi

    echo "" >&2
    print_info "Network:              ${net_label}" >&2
    # Friendlier "current" description naming what the operator is actually
    # on: exact tag, main (at-tip or behind), a non-main feature branch, or
    # a truly detached commit.
    if [[ -n "$exact_tag" ]]; then
        print_info "Current source ref:   ${exact_tag} (exactly on this tag)" >&2
    elif [[ "$on_main_state" == "tip" ]]; then
        print_info "Current source ref:   main @ ${head_sha:0:8}  (${current_describe})" >&2
        print_info "origin/main:          up to date" >&2
    elif [[ "$on_main_state" == "behind" ]]; then
        local commits_word="commits"
        [[ "$behind_count" == "1" ]] && commits_word="commit"
        print_info "Current source ref:   built from main @ ${head_sha:0:8}  (${current_describe})" >&2
        print_warn "origin/main has moved: ${behind_count} ${commits_word} since your build" >&2
        [[ -n "$main_tip_summary" ]] && print_info "Latest on main:       ${main_tip_summary}" >&2
    elif [[ -n "$feature_branch" ]]; then
        local ahead_word="commits"
        [[ "$feature_ahead_main" == "1" ]] && ahead_word="commit"
        print_info "Current source ref:   branch '${feature_branch}' @ ${head_sha:0:8}" >&2
        if [[ "$feature_ahead_main" -gt 0 ]]; then
            print_info "Relative to main:     ${feature_ahead_main} ${ahead_word} ahead of main" >&2
        fi
        [[ -n "$feature_summary" ]] && print_info "Latest commit:        \"${feature_summary}\"" >&2
    else
        print_info "Current source ref:   ${current_describe}  (detached / not on any branch or tag)" >&2
    fi
    if [[ ${#tags[@]} -gt 0 ]]; then
        local latest_tag="${tags[0]}"
        if [[ "$exact_tag" == "$latest_tag" ]]; then
            print_ok  "You are on the latest ${network:-applicable} tag (${latest_tag})." >&2
        else
            print_info "Latest matching tag:  ${latest_tag}  (recommended for ${network:-this network})" >&2
        fi
    fi
    echo "" >&2

    print_info "Available versions to build:" >&2
    local i=1

    # 1) main -- the latest current version (default). Marked per where HEAD sits
    #    relative to origin/main.
    local main_label="main (latest current version"
    [[ "$network" == "devnet" ]] && main_label="main (recommended for devnet"
    main_label="${main_label})"
    case "$on_main_state" in
        tip)
            main_label="${main_label}  <-- current"
            ;;
        behind)
            local commits_word="commits"
            [[ "$behind_count" == "1" ]] && commits_word="commit"
            main_label="${main_label}  <-- ${behind_count} ${commits_word} newer than your build"
            ;;
    esac
    local main_opt=$i; printf "  %2d) %s\n" "$main_opt" "$main_label" >&2; (( ++i ))

    # 2) latest tagged release (most recent detected tag), if any exist.
    local tag_opt=0 latest_tag=""
    if [[ ${#tags[@]} -gt 0 ]]; then
        latest_tag="${tags[0]}"
        local tag_label="${latest_tag}  (latest ${network:-tagged} release)"
        [[ "$exact_tag" == "$latest_tag" ]] && tag_label="${latest_tag}  <-- current"
        tag_opt=$i; printf "  %2d) %s\n" "$tag_opt" "$tag_label" >&2; (( ++i ))
    fi

    local custom_opt=$i; printf "  %2d) Custom branch / tag / commit hash\n"  "$custom_opt" >&2; (( ++i ))
    local cancel_opt=$i; printf "  %2d) Cancel\n"                              "$cancel_opt" >&2
    echo "" >&2

    # Network-aware default: testnet/mainnet operators should get the latest
    # tagged release (main is bleeding-edge and not network-compatible); devnet
    # follows main. main stays listed first either way.
    local default_opt=$main_opt
    if [[ "$network" != "devnet" && $tag_opt -gt 0 ]]; then
        default_opt=$tag_opt
    fi

    local choice
    read -r -p "  Select [1-${cancel_opt}] (default ${default_opt}): " choice >&2
    # Empty input -> the network-aware default
    [[ -z "$choice" ]] && choice=$default_opt

    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        print_warn "Invalid selection." >&2
        return 1
    fi
    if (( choice == cancel_opt )); then
        print_info "Cancelled." >&2
        return 1
    fi
    if (( choice == custom_opt )); then
        local custom_ref
        read -r -p "  Enter branch / tag / commit hash: " custom_ref >&2
        [[ -z "$custom_ref" ]] && { print_info "Cancelled." >&2; return 1; }
        echo "$custom_ref"
        return 0
    fi
    if (( choice == main_opt )); then
        echo "main"
        return 0
    fi
    if (( tag_opt > 0 && choice == tag_opt )); then
        echo "$latest_tag"
        return 0
    fi

    print_warn "Invalid selection." >&2
    return 1
}

# Ask the operator: prepare-only, prepare-and-apply, or cancel. Used by
# update-node.sh; lives in common.sh so it can be reused by future tooling.
# Echoes "prepare" | "prepare_and_apply" | "cancel".
pick_action() {
    echo "" >&2
    echo "  What would you like to do?" >&2
    echo "    1) Prepare only (build/pull now, apply later)" >&2
    echo "    2) Prepare AND apply (build/pull, then immediately apply)" >&2
    echo "    3) Cancel" >&2
    echo "" >&2
    local choice
    read -r -p "  Enter choice [1-3]: " choice >&2
    case "$choice" in
        1) echo "prepare" ;;
        2) echo "prepare_and_apply" ;;
        *) echo "cancel" ;;
    esac
}

# =============================================================================
# TESTNET OPT-IN ADD-ONS — shared scaffolding (COMMON_VERSION >= 1.2.0)
#
# Three additive, testnet-only, opt-in capabilities for external operators:
#   * healthcheck monitoring   (--healthcheck + source-restricted ufw rule)
#   * centralized logging       (Alloy -> central Loki)        [lib/observability.sh]
#   * WireGuard admin SSH        (core-team overlay access)      [setup-vpn.sh]
# All OFF by default. See docs/testnet-addons.md for the trust model.
# =============================================================================

# Public constants (hub coords, Kuma source, obs URL, Alloy image). Sourced here so
# every script that sources common.sh gets them transitively. Guarded so an older
# checkout without the file still works.
__COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -f "${__COMMON_DIR}/testnet-addons.env" ]]; then
    source "${__COMMON_DIR}/testnet-addons.env"
fi
# Safety-net defaults. lib/testnet-addons.env is the AUTHORITATIVE, editable home for
# these (edit there). This mirror only guarantees the constants are set so the helpers
# below — and the always-run status views — don't trip the inherited `set -u` if the
# env file is briefly missing mid-update. `:=` is a no-op when the var is already set.
: "${TN_WG_HUB_ENDPOINT:=34.20.198.253:51820}"
: "${TN_WG_HUB_PUBKEY:=hqIDskzaOS5t6DE91VX+V9Z4NJjKlNufl4kQr/KuF1k=}"
: "${TN_OVERLAY_CIDR:=10.100.0.0/16}"
: "${TN_OVERLAY_RESERVED_NETS:=0 1 2 9}"
: "${TN_OVERLAY_EXTERNAL_BAND_HINT:=10.100.20.0/24}"
: "${TN_KUMA_SRC:=104.155.184.201/32}"
: "${TN_KUMA_PORT:=43174}"
# Optional, comma-separated extra CIDRs allowed to TCP-probe the health port (TN_KUMA_PORT)
# at host-UFW enable time — e.g. the Google Cloud load-balancer health-check ranges when a
# node sits behind a GCP LB. Empty by default, so generic operators see NO change; the devnet
# deployment sets it (devnet-firewall.sh) to let LB backends pass. See apply_lb_hc_rule.
: "${TN_LB_HC_RANGES:=}"
: "${OBS_PUSH_URL_TESTNET:=https://obs.adiri.telcoin.network/loki/api/v1/push}"
: "${TN_ALLOY_IMAGE:=grafana/alloy:v1.5.1}"
: "${TN_ALLOY_NATIVE_VERSION:=1.5.1}"

# -----------------------------------------------------------------------------
# Network gate
# -----------------------------------------------------------------------------

# is_testnet — soft check for use INSIDE the interactive setup flow (NETWORK is
# already set there). Returns 0 on the Adiri testnet.
is_testnet() { [[ "${NETWORK:-}" == "testnet" ]]; }

# is_testnet_like — soft check for the hard gate below. Returns 0 on the Adiri
# testnet OR on devnet. Devnet shares the same opt-in add-on surface as testnet
# (observability/health), so require_testnet treats it as allowed. The interactive
# add-on prompts keep using is_testnet (testnet-only) and are unaffected.
is_testnet_like() { [[ "${NETWORK:-}" == "testnet" || "${NETWORK:-}" == "devnet" ]]; }

# require_testnet — hard gate for STANDALONE scripts (setup-vpn.sh etc.). Exits if
# the node is not on testnet (or devnet). Callers must load NETWORK from .node-meta first.
require_testnet() {
    if ! is_testnet_like; then
        print_error "Testnet-only feature. This node's NETWORK is '${NETWORK:-unset}'."
        print_info  "The VPN / observability / healthcheck add-ons are offered only on the Adiri testnet."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# .node-meta persistence (single primitive for every opt-in's state)
# -----------------------------------------------------------------------------

# node_meta_path — echo the active .node-meta path. The unified install
# (/etc/telcoin/.node-meta) is checked first; legacy per-role installs are
# resolved by fallback.sh. Returns 1 if no node is installed.
node_meta_path() {
    local unified="${TN_ROOT_PREFIX:-}/etc/telcoin/.node-meta"
    [[ -f "$unified" ]] && { printf '%s\n' "$unified"; return 0; }
    tn_legacy_node_meta_path
}

# meta_get <key> [file] — echo KEY's value (everything after the first '='). Returns
# 1 (and echoes nothing) if the key/file is absent. Default file = node_meta_path.
meta_get() {
    local key="$1" file="${2:-}"
    [[ -n "$file" ]] || file="$(node_meta_path)" || return 1
    [[ -f "$file" ]] || return 1
    local line
    line="$(grep -E "^${key}=" "$file" 2>/dev/null | head -n1)" || return 1
    [[ -n "$line" ]] || return 1
    printf '%s\n' "${line#*=}"
}

# meta_set <key> <value> [file] — idempotent upsert into .node-meta (mode 600).
# Rewrites via grep -v + append (no sed) so values containing / + = are safe.
# Every other key in the file survives. Refuses (rc 1, file untouched) a key that
# is not ^[A-Z][A-Z0-9_]*$ or a value holding a CR or LF, which would otherwise
# smuggle a second KEY= line into the file. Warnings go to stderr so JSON-mode
# callers keep a clean stdout.
meta_set() {
    local key="${1:-}" val="${2:-}" file="${3:-}" tmp nl cr
    nl=$'\n'
    cr=$'\r'
    if [[ ! "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
        print_warn "meta_set: refusing key '${key}' (expected A-Z, 0-9 and _ only, starting with a letter)" >&2
        return 1
    fi
    if [[ "$val" == *"$nl"* || "$val" == *"$cr"* ]]; then
        print_warn "meta_set: refusing a value for ${key} that contains a line break" >&2
        return 1
    fi
    [[ -n "$file" ]] || file="$(node_meta_path || true)"
    if [[ -z "$file" ]]; then
        print_warn "meta_set: no .node-meta found; cannot persist ${key}" >&2
        return 1
    fi
    mkdir -p "$(dirname "$file")" || return 1
    [[ -f "$file" ]] || { ( umask 077; : > "$file" ) || return 1; }
    tmp="$(mktemp 2>/dev/null || true)"
    [[ -n "$tmp" && -f "$tmp" ]] || return 1
    grep -vE "^${key}=" "$file" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    if ! cat "$tmp" > "$file"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    chmod 600 "$file" 2>/dev/null || true
    return 0
}

# meta_unset <key> [file] — remove every KEY= line from .node-meta. rc 0 when the
# key (or the file) is absent, and the file is then left untouched. Same key rule
# as meta_set (rc 1 otherwise); other keys survive and the file stays mode 600.
meta_unset() {
    local key="${1:-}" file="${2:-}" tmp
    if [[ ! "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
        print_warn "meta_unset: refusing key '${key}' (expected A-Z, 0-9 and _ only, starting with a letter)" >&2
        return 1
    fi
    [[ -n "$file" ]] || file="$(node_meta_path || true)"
    [[ -n "$file" && -f "$file" ]] || return 0
    grep -qE "^${key}=" "$file" 2>/dev/null || return 0
    tmp="$(mktemp 2>/dev/null || true)"
    [[ -n "$tmp" && -f "$tmp" ]] || return 1
    grep -vE "^${key}=" "$file" > "$tmp" 2>/dev/null || true
    if ! cat "$tmp" > "$file"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    chmod 600 "$file" 2>/dev/null || true
    return 0
}

# -----------------------------------------------------------------------------
# Overlay-IP / CIDR validation (WireGuard admin overlay)
# -----------------------------------------------------------------------------

# validate_cidr <a.b.c.d/N> — a syntactically valid IPv4 CIDR (mask 0..32).
validate_cidr() {
    local cidr="$1" ip mask
    [[ "$cidr" == */* ]] || return 1
    ip="${cidr%/*}"; mask="${cidr#*/}"
    [[ "$mask" =~ ^[0-9]+$ ]] && (( mask >= 0 && mask <= 32 )) || return 1
    validate_ipv4 "$ip"
}

# validate_overlay_ip <a.b.c.d> — an IPv4 inside 10.100.0.0/16, host octet 1..254,
# NOT in a reserved /24 (hub/adiri/devnet/maintainers). The core team assigns one
# from the external band (10.100.20.0/24+); see lib/testnet-addons.env.
validate_overlay_ip() {
    local ip="$1" net idx r
    [[ "$ip" =~ ^10\.100\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    net="${BASH_REMATCH[1]}"; idx="${BASH_REMATCH[2]}"
    (( net >= 0 && net <= 255 )) || return 1
    (( idx >= 1 && idx <= 254 )) || return 1
    for r in ${TN_OVERLAY_RESERVED_NETS:-0 1 2 9}; do
        [[ "$net" == "$r" ]] && return 1
    done
    return 0
}

# -----------------------------------------------------------------------------
# ufw helpers (shared by firewall-setup.sh, setup-vpn.sh, setup-observability.sh)
# Historically defined in firewall-setup.sh; centralized here so the standalone
# add-on scripts can reuse them. firewall-setup.sh no longer redefines these four.
# -----------------------------------------------------------------------------

ufw_installed() { command -v ufw &>/dev/null; }

ufw_active() { ufw status 2>/dev/null | grep -q "Status: active"; }

# ufw_has_allow <port> <tcp|udp> — 0 if an ALLOW rule for that port/proto exists.
# Matches both regular and (v6) entries; protocol is matched explicitly.
ufw_has_allow() {
    local port="$1" proto="$2"
    ufw status 2>/dev/null | \
        grep -qE "^${port}/${proto}([[:space:]]+\(v6\))?[[:space:]]+ALLOW"
}

# get_ssh_port — the sshd listen port (defaults to 22 when unset).
get_ssh_port() {
    grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22"
}

# validate_health_src <ip|cidr> — accept a bare IPv4/IPv6 OR a CIDR (v4 or v6).
# For a CIDR, split on '/', require a numeric mask, and dispatch by family: IPv4 with
# mask 0..32, or IPv6 with mask 0..128. For a bare address: IPv4 or IPv6. Generalizes
# the IPv4-only validate_cidr for the operator-chosen health sources. Returns 0 if valid.
validate_health_src() {
    local src="$1"
    if [[ "$src" == */* ]]; then
        local ip="${src%/*}" mask="${src#*/}"
        [[ "$mask" =~ ^[0-9]+$ ]] || return 1
        if validate_ipv4 "$ip"; then
            (( mask >= 0 && mask <= 32 ))
        elif validate_ipv6 "$ip"; then
            (( mask >= 0 && mask <= 128 ))
        else
            return 1
        fi
    else
        validate_ipv4 "$src" || validate_ipv6 "$src"
    fi
}

# kuma_extra_list — echo the space-separated operator-chosen health sources persisted
# in .node-meta (KUMA_EXTRA_SRC), or nothing. The single source of truth for the set.
kuma_extra_list() {
    meta_get KUMA_EXTRA_SRC 2>/dev/null || true
}

# apply_kuma_extra_rules — (re)apply an `allow from <src>` rule for every operator-
# persisted health source so they survive a `ufw --force reset`. Idempotent (ufw
# dedups) and quiet (the operator gets a dedicated confirmation elsewhere). No-op when
# the list is empty.
apply_kuma_extra_rules() {
    local src
    for src in $(kuma_extra_list); do
        ufw allow from "$src" to any port "${TN_KUMA_PORT}" proto tcp >/dev/null 2>&1 || true
    done
}

# kuma_extra_add <src> — validate, dedupe-append to KUMA_EXTRA_SRC, persist, then apply
# the single ufw allow rule. Returns non-zero WITHOUT persisting on invalid input.
kuma_extra_add() {
    local src="$1" cur s
    validate_health_src "$src" || return 1
    cur="$(kuma_extra_list)"
    for s in $cur; do
        # Already persisted: just (re)apply the rule idempotently and report success.
        if [[ "$s" == "$src" ]]; then
            ufw allow from "$src" to any port "${TN_KUMA_PORT}" proto tcp >/dev/null 2>&1 || true
            return 0
        fi
    done
    meta_set KUMA_EXTRA_SRC "${cur:+$cur }$src"
    ufw allow from "$src" to any port "${TN_KUMA_PORT}" proto tcp >/dev/null 2>&1 || true
}

# kuma_extra_remove <src> — drop <src> from KUMA_EXTRA_SRC, persist the trimmed list,
# then delete its ufw allow rule. Removing an entry that isn't present is harmless.
kuma_extra_remove() {
    local src="$1" cur new="" s
    cur="$(kuma_extra_list)"
    for s in $cur; do
        [[ "$s" == "$src" ]] && continue
        new="${new:+$new }$s"
    done
    meta_set KUMA_EXTRA_SRC "$new"
    ufw delete allow from "$src" to any port "${TN_KUMA_PORT}" proto tcp >/dev/null 2>&1 || true
}

# apply_kuma_rule — source-restrict the health probe (port TN_KUMA_PORT) to the
# Association uptime monitor (TN_KUMA_SRC) as the always-on baseline, PLUS any
# operator-chosen sources persisted in KUMA_EXTRA_SRC (apply_kuma_extra_rules). First
# removes any pre-existing open-to-anywhere rule for the port: ufw does NOT replace
# rules, so a lingering "allow <port>/tcp" (Anywhere) would otherwise shadow the
# restriction and keep the port open to the whole internet. Because every call site
# routes through here, the operator's extras are restored automatically after a
# `ufw --force reset`. Idempotent (ufw dedups identical rules).
apply_kuma_rule() {
    local rc
    # Drop a stale open-to-Anywhere rule (and its v6 twin) for the health port, if any.
    ufw delete allow "${TN_KUMA_PORT}/tcp" >/dev/null 2>&1 || true
    ufw allow from "${TN_KUMA_SRC}" to any port "${TN_KUMA_PORT}" proto tcp
    rc=$?
    # Layer operator-chosen sources on top of the TA baseline.
    apply_kuma_extra_rules
    return "$rc"
}

# apply_lb_hc_rule — admit the load-balancer health-check source ranges (TN_LB_HC_RANGES,
# comma-separated CIDRs) to the health port. No-op when TN_LB_HC_RANGES is empty (the
# default), so non-LB nodes are unaffected. Idempotent (ufw dedups). Distinct from the
# Kuma/operator sources so the LB ranges are obvious and not confused with monitor hosts.
# Called from apply_recommended_firewall (every enable re-stages it after a ufw reset).
apply_lb_hc_rule() {
    [[ -n "${TN_LB_HC_RANGES:-}" ]] || return 0
    local src
    # Split on commas; ufw rejects a comma-joined list, so add one rule per CIDR.
    IFS=',' read -ra _lb_hc_srcs <<< "${TN_LB_HC_RANGES}"
    for src in "${_lb_hc_srcs[@]}"; do
        src="${src//[[:space:]]/}"   # tolerate "a, b" spacing
        [[ -n "$src" ]] || continue
        ufw allow from "$src" to any port "${TN_KUMA_PORT}" proto tcp >/dev/null 2>&1 || true
    done
}

# allow_overlay_ssh — admit SSH from the whole WireGuard overlay so the core team can
# reach the node over the VPN even after public SSH is restricted. Idempotent.
allow_overlay_ssh() {
    local port; port="$(get_ssh_port)"
    [[ -n "$port" ]] || port=22
    ufw allow from "${TN_OVERLAY_CIDR}" to any port "${port}" proto tcp
}

# -----------------------------------------------------------------------------
# Node-launch flag tail (healthcheck + JSON log shipping)
# -----------------------------------------------------------------------------

# tn_node_launch_flags <docker|binary> — the extra `telcoin node` flags implied by
# the opt-ins enabled for THIS setup run, as one space-joined string (emit on a
# single line to avoid dangling-backslash bugs when the tail is empty). Reads the
# ENABLE_* globals set by prompt_testnet_addons. obs flags come from
# obs_reth_log_flags / obs_metrics_reth_flags (lib/observability.sh); the log flags
# branch on install method because the reth log dir differs (container
# /home/nonroot/logs vs host /var/log/telcoin), while --metrics is a loopback addr.
# --metrics is gated here (not unconditional) so a metrics-off node runs reth's
# zero-overhead noop recorder — byte-identical to a node installed without these scripts.
tn_node_launch_flags() {
    local method="$1" flags=""
    # is_testnet_like (testnet OR devnet) — devnet shares the same opt-in add-on surface
    # (see is_testnet_like at the top of this file). Each feature below stays individually
    # gated by its own ENABLE_* (default off), so this only lets devnet REACH those gates;
    # it emits nothing extra unless an opt-in is explicitly turned on.
    is_testnet_like || { printf '%s' ""; return 0; }
    if [[ "${ENABLE_HEALTHCHECK_MONITOR:-false}" == "true" ]]; then
        flags+=" --healthcheck ${TN_KUMA_PORT}"
    fi
    if [[ "${ENABLE_METRICS:-false}" == "true" ]] && declare -F obs_metrics_reth_flags >/dev/null 2>&1; then
        flags+=" $(obs_metrics_reth_flags)"
    fi
    if [[ "${ENABLE_OBSERVABILITY:-false}" == "true" ]] && declare -F obs_reth_log_flags >/dev/null 2>&1; then
        flags+=" $(obs_reth_log_flags "$method")"
    fi
    printf '%s' "${flags# }"
}

# tn_node_launch_target — echo "<svc> <method> <file>" for the installed node, where
# file is the launch config to patch: the systemd unit (docker) or the start wrapper
# (binary/source). Returns 1 if no node service is present.
tn_node_launch_target() {
    local svc method meta file
    svc="$(tn_resolve_service)" || return 1
    meta="$(node_meta_path || true)"
    method="$(meta_get INSTALL_METHOD "$meta" 2>/dev/null || echo binary)"; [[ -n "$method" ]] || method="binary"
    # Docker installs now run via a start wrapper too (the BLS LoadCredential change moved
    # the `docker run` out of the unit's ExecStart into ${INSTALL_DIR}/start-<svc>.sh). The
    # --http line obs flags attach to therefore lives in the wrapper -- patch it when present.
    # Fall back to the unit for legacy docker installs that still inline `docker run`.
    if [[ "$method" == "docker" ]]; then
        if [[ -f "${DEFAULT_INSTALL_DIR}/start-${svc}.sh" ]]; then file="${DEFAULT_INSTALL_DIR}/start-${svc}.sh"
        else file="/etc/systemd/system/${svc}.service"; fi
    else file="${DEFAULT_INSTALL_DIR}/start-${svc}.sh"; fi
    printf '%s %s %s\n' "$svc" "$method" "$file"
}

# -----------------------------------------------------------------------------
# Node launch file: target line and flag edits (COMMON_VERSION >= 1.6.0)
# -----------------------------------------------------------------------------
#
# A launch file is the start wrapper setup-node.sh writes (its heredoc joins the
# command onto one `exec docker run ... telcoin node ...` or `exec <binary> node
# ...` line; hand edits may split it with trailing backslashes) or, on old docker
# installs, the systemd unit that holds the whole command on one ExecStart= line.
# Every helper below reads it the same way:
#   * a line whose first non-blank character is # is a comment (; too in a .service
#     file). In a shell wrapper a comment line ends a continued command, as bash
#     reads it; in a unit it is skipped and the command goes on (systemd.syntax).
#   * words are split as the shell splits them, so "$(cat /etc/telcoin/x.yaml)" is
#     one word, and a word starting with # begins a trailing comment. In a
#     wrapper an unquoted ; | & < > ( ) ends a word, and a node command holding
#     one (a pipe, &&, 2>&1, a trailing &) is not one simple command, so it is
#     neither read nor edited (rc 3). No shell reads a unit, so there those
#     characters are part of a word, and only a ; standing alone as a word
#     (systemd's separator between two commands) has that effect. New values
#     and flags must be single shell words in both kinds of file.
#   * the target line is the first non-comment line holding the word --http in a
#     command that has the word `node` before it. New flags go there, before a
#     trailing backslash, else at the end of the line.
#   * reads and edits of an existing flag look only at the words after `node` in
#     that command; FLAG=VALUE counts too. A value is the next word unless that
#     starts with -, so a flag followed by another flag is a boolean.
# Return codes shared by the edits: 0 changed, 1 no change needed, 2 no live node
# --http line, 3 refused (a trailing comment on a line that would change, a bad
# flag or value, a quote the parser cannot balance, or a staged copy that fails the
# checks), 4 I/O error. The file is untouched unless rc is 0. Edits are staged in a
# temp file and written back with `cat >`, which keeps owner and mode, only when
# the staged copy is non-empty, has as many --http lines as before, reads back as
# intended and, for a shell wrapper that passed bash -n, still passes it. The
# caller owns any backup, the daemon-reload of a unit and the restart.

# _tn_launch_is_unit FILE — rc 0 when FILE is a systemd unit (name ends in .service).
_tn_launch_is_unit() {
    [[ "${1:-}" == *.service ]]
}

# _tn_launch_awk MODE FILE [FLAG [VALUE [HASVAL [FLAGS [UNIT]]]]] — the launch-file
# parser. MODE is target (print the target line number), get, probe (print
# "<count> <boolean 0|1> <raw value>" of FLAG), runner (print "docker <image>" or
# "binary <path>"), set, unset or inject (print the whole edited file). UNIT (1 or
# 0) says how to read FILE; it defaults to the name of FILE, and a staged temp copy
# passes the kind of the file it was made from. Inputs reach awk through the
# environment, so nothing is escape-processed. Exit 10 done, 11 no change needed or
# FLAG absent, 12 no target line, 13 refused, 14 VALUE (set) or FLAGS (inject) is
# not plain shell words; anything else is an awk failure.
_tn_launch_awk() {
    local unit="${7:-}"
    if [[ "$unit" != "0" && "$unit" != "1" ]]; then
        unit=0
        if _tn_launch_is_unit "$2"; then
            unit=1
        fi
    fi
    TN_LE_MODE="$1" TN_LE_FLAG="${3:-}" TN_LE_VALUE="${4:-}" TN_LE_HASVAL="${5:-0}" \
    TN_LE_FLAGS="${6:-}" TN_LE_UNIT="$unit" awk '
        function q_sq(s, i,    j) {
            j = index(substr(s, i), SQ)
            return j ? i + j - 1 : 0
        }
        function q_bq(s, i, n,    c) {
            while (i <= n) {
                c = substr(s, i, 1)
                if (c == "\\") { i += 2; continue }
                if (c == "`") return i
                i++
            }
            return 0
        }
        function q_dq(s, i, n,    c) {
            while (i <= n) {
                c = substr(s, i, 1)
                if (c == "\\") { i += 2; continue }
                if (c == "\"") return i
                if (c == "`") { i = q_bq(s, i + 1, n); if (!i) return 0; i++; continue }
                if (c == "$" && substr(s, i + 1, 1) == "(") { i = q_nest(s, i + 2, n, "(", ")"); if (!i) return 0; i++; continue }
                if (c == "$" && substr(s, i + 1, 1) == "{") { i = q_nest(s, i + 2, n, "{", "}"); if (!i) return 0; i++; continue }
                i++
            }
            return 0
        }
        function q_nest(s, i, n, op, cl,    c, d) {
            d = 1
            while (i <= n) {
                c = substr(s, i, 1)
                if (c == "\\") { i += 2; continue }
                if (c == SQ) { i = q_sq(s, i + 1); if (!i) return 0; i++; continue }
                if (c == "\"") { i = q_dq(s, i + 1, n); if (!i) return 0; i++; continue }
                if (c == "`") { i = q_bq(s, i + 1, n); if (!i) return 0; i++; continue }
                if (c == op) d++
                else if (c == cl) { d--; if (!d) return i }
                i++
            }
            return 0
        }
        # Split s into words as the shell does. ln > 0 records them in the file
        # table (TT text, TL line, TS and TE first and last column); ln 0 records
        # them in W. Sets tk_n (words), tk_cont (ends in a continuation
        # backslash), tk_com (column of a trailing # comment, 0 for none),
        # tk_bad (a quote that does not close on this line), tk_meta (an
        # unquoted ; | & < > ( ) or line break: it ends a word, and the line is
        # more than one simple command or carries a redirection) and tk_glob
        # (an unquoted * ? [, which the shell would expand). With lit set (a
        # systemd unit line, which no shell reads) those characters are part of
        # a word, and only a ; standing alone as a word, the separator between
        # two commands in one ExecStart=, sets tk_meta.
        function tok(s, ln, lit,    n, i, c, st, j) {
            tk_n = 0; tk_cont = 0; tk_com = 0; tk_bad = 0; tk_meta = 0; tk_glob = 0
            n = length(s); i = 1
            while (i <= n) {
                c = substr(s, i, 1)
                if (c == " " || c == "\t") { i++; continue }
                if (!lit && index(META, c)) { tk_meta = 1; i++; continue }
                if (c == "#") { tk_com = i; return }
                if (c == "\\" && substr(s, i + 1) ~ /^[ \t]*$/) { tk_cont = 1; return }
                st = i
                while (i <= n) {
                    c = substr(s, i, 1)
                    if (c == " " || c == "\t" || (!lit && index(META, c))) break
                    if (c == "\\") {
                        if (substr(s, i + 1) ~ /^[ \t]*$/) { tk_cont = 1; break }
                        i += 2; continue
                    }
                    if (index(GLOB, c)) tk_glob = 1
                    j = -1
                    if (c == SQ) j = q_sq(s, i + 1)
                    else if (c == "\"") j = q_dq(s, i + 1, n)
                    else if (c == "`") j = q_bq(s, i + 1, n)
                    else if (c == "$" && substr(s, i + 1, 1) == "(") j = q_nest(s, i + 2, n, "(", ")")
                    else if (c == "$" && substr(s, i + 1, 1) == "{") j = q_nest(s, i + 2, n, "{", "}")
                    if (j < 0) { i++; continue }
                    if (!j) { tk_bad = 1; return }
                    i = j + 1
                }
                tk_n++
                if (lit && substr(s, st, i - st) == ";") tk_meta = 1
                if (ln) { NT++; TT[NT] = substr(s, st, i - st); TL[NT] = ln; TS[NT] = st; TE[NT] = i - 1 }
                else W[tk_n] = substr(s, st, i - st)
                if (tk_cont) return
            }
        }
        # A word without its outer quotes, when one pair encloses all of it.
        function unq(t,    n, q) {
            n = length(t)
            if (n < 2) return t
            q = substr(t, 1, 1)
            if (q == SQ && q_sq(t, 2) == n) return substr(t, 2, n - 2)
            if (q == "\"" && q_dq(t, 2, n) == n) return substr(t, 2, n - 2)
            return t
        }
        # Line i rebuilt without the words in DEL and with the words in REP
        # replaced, keeping its indentation, the gaps between kept words and its
        # tail (a continuation backslash, say).
        function relin(i,    s, o, k, kept, tx) {
            s = L[i]; o = ""; kept = 0
            for (k = LT0[i]; k <= LT1[i]; k++) {
                if (k in DEL) continue
                tx = (k in REP) ? REP[k] : TT[k]
                if (kept) o = o substr(s, TE[k - 1] + 1, TS[k] - TE[k - 1] - 1) tx
                else o = substr(s, 1, TS[LT0[i]] - 1) tx
                kept = 1
            }
            if (!kept) o = substr(s, 1, TS[LT0[i]] - 1)
            return o substr(s, TE[LT1[i]] + 1)
        }
        # Apply DEL and REP to the node command. A line left with nothing but
        # blanks and a backslash is dropped; when that line ended the command,
        # the line before it loses its backslash. Returns 1 when a line that
        # would change has a trailing comment.
        function edit_cmd(    i, k, hit, s, last) {
            for (i = CF[tc]; i <= CL[tc]; i++) {
                if ((i in COM) || LT1[i] < LT0[i]) continue
                hit = 0
                for (k = LT0[i]; k <= LT1[i]; k++) if ((k in DEL) || (k in REP)) hit = 1
                if (!hit) continue
                if (LCOM[i]) return 1
                s = relin(i)
                if (s ~ /^[ \t]*(\\[ \t]*)?$/) DROP[i] = 1
                else NEWL[i] = s
            }
            last = CL[tc]
            if ((last in DROP) && !LCONT[last]) {
                for (i = last - 1; i >= CF[tc]; i--) {
                    if ((i in COM) || (i in DROP)) continue
                    s = (i in NEWL) ? NEWL[i] : L[i]
                    sub(/[ \t]*\\[ \t]*$/, "", s)
                    NEWL[i] = s
                    break
                }
            }
            return 0
        }
        # Line i with text added before a trailing backslash, else at the end.
        function ins_line(i, text,    s) {
            s = L[i]
            if (LCONT[i]) { sub(/[ \t]*\\[ \t]*$/, "", s); return s " " text " \\" }
            return s " " text
        }
        function emit(    i) {
            for (i = 1; i <= N; i++) {
                if (i in DROP) continue
                if (i in NEWL) print NEWL[i]
                else print L[i]
            }
        }
        BEGIN { SQ = sprintf("%c", 39); META = ";|&<>()\n\r"; GLOB = "*?[" }
        { L[NR] = $0 }
        END {
            N = NR
            mode = ENVIRON["TN_LE_MODE"]; unit = (ENVIRON["TN_LE_UNIT"] == "1")
            flag = ENVIRON["TN_LE_FLAG"]; val = ENVIRON["TN_LE_VALUE"]
            hasval = (ENVIRON["TN_LE_HASVAL"] == "1"); ins = ENVIRON["TN_LE_FLAGS"]
            # A new value must be one plain shell word and new flags plain
            # words: nothing the shell would split, redirect, run or expand.
            if (mode == "set" && hasval) {
                tok(val, 0)
                if (tk_n != 1 || tk_com || tk_bad || tk_cont || tk_meta || tk_glob || W[1] != val) exit 14
            }
            if (mode == "inject") {
                tok(ins, 0)
                if (tk_n < 1 || tk_com || tk_bad || tk_cont || tk_meta || tk_glob) exit 14
            }
            NT = 0; nc = 0; cont = 0
            for (i = 1; i <= N; i++) {
                s = L[i]
                if (s ~ /^[ \t]*#/ || (unit && s ~ /^[ \t]*;/)) {
                    COM[i] = 1
                    if (!unit) cont = 0
                    continue
                }
                if (!cont) { nc++; CF[nc] = i; CT0[nc] = NT + 1 }
                LT0[i] = NT + 1
                tok(s, i, unit)
                LT1[i] = NT; LCONT[i] = tk_cont; LCOM[i] = tk_com; LBAD[i] = tk_bad; LMETA[i] = tk_meta
                for (k = LT0[i]; k <= NT; k++) TC[k] = nc
                CL[nc] = i; CT1[nc] = NT
                cont = tk_cont && !tk_bad
            }
            tk = 0
            for (k = 1; k <= NT; k++) {
                if (TT[k] != "--http") continue
                c = TC[k]
                for (j = CT0[c]; j < k; j++) if (TT[j] == "node") break
                if (j < k) { tk = k; tn = j; tc = c; break }
            }
            if (!tk) exit 12
            tl = TL[tk]
            # A quote the parser could not close makes the command unreliable;
            # in a shell wrapper one anywhere before it does too. An operator or
            # redirection inside the node command (a pipe, &&, 2>&1, a trailing
            # &; in a unit a ; word between two commands) means it is not one
            # simple command, so it is not read or edited.
            for (i = (unit ? CF[tc] : 1); i <= CL[tc]; i++) if (LBAD[i]) exit 13
            for (i = CF[tc]; i <= CL[tc]; i++) if (LMETA[i]) exit 13
            if (mode == "target") { print tl; exit 10 }
            if (mode == "inject") {
                if (LCOM[tl]) exit 13
                NEWL[tl] = ins_line(tl, ins)
                emit(); exit 10
            }
            no = 0
            for (k = tn + 1; k <= CT1[tc]; k++) {
                t = TT[k]
                if (t == flag) {
                    no++; OF[no] = k; OV[no] = 0; OB[no] = 1; OR[no] = ""
                    if (k < CT1[tc] && substr(TT[k + 1], 1, 1) != "-") { OV[no] = k + 1; OB[no] = 0; OR[no] = TT[k + 1]; k++ }
                } else if (index(t, flag "=") == 1) {
                    no++; OF[no] = k; OV[no] = 0; OB[no] = 0; OR[no] = substr(t, length(flag) + 2)
                }
            }
            if (mode == "get") { if (!no) exit 11; print unq(OR[1]); exit 10 }
            if (mode == "probe") { printf "%d %d %s\n", no, (no ? OB[1] : 0), (no ? OR[1] : ""); exit 10 }
            if (mode == "runner") {
                dk = 0; dr = 0
                for (k = CT0[tc]; k < tn; k++) {
                    t = unq(TT[k]); sub(/^ExecStart=[-@:+!]*/, "", t); b = t; sub(/^.*\//, "", b)
                    if (b == "docker") dk = k
                    else if (dk && TT[k] == "run") { dr = k; break }
                }
                if (dr) {
                    b = unq(TT[tn - 1]); sub(/^.*\//, "", b)
                    im = (b == "telcoin" || b == "telcoin-network") ? tn - 2 : tn - 1
                    if (im <= dr) exit 11
                    print "docker " unq(TT[im]); exit 10
                }
                if (tn <= CT0[tc]) exit 11
                t = unq(TT[tn - 1]); sub(/^ExecStart=[-@:+!]*/, "", t)
                print "binary " t; exit 10
            }
            if (mode == "unset") {
                if (!no) exit 11
                for (m = 1; m <= no; m++) { DEL[OF[m]] = 1; if (OV[m]) DEL[OV[m]] = 1 }
                if (edit_cmd()) exit 13
                emit(); exit 10
            }
            if (mode == "set") {
                nt = hasval ? flag " " val : flag
                if (no) {
                    if (no == 1 && (hasval ? (!OB[1] && OR[1] == val) : OB[1])) exit 11
                    REP[OF[1]] = nt; if (OV[1]) DEL[OV[1]] = 1
                    for (m = 2; m <= no; m++) { DEL[OF[m]] = 1; if (OV[m]) DEL[OV[m]] = 1 }
                    if (edit_cmd()) exit 13
                } else {
                    if (LCOM[tl]) exit 13
                    NEWL[tl] = ins_line(tl, nt)
                }
                emit(); exit 10
            }
            exit 13
        }
    ' "$2"
}

# _tn_launch_flag_ok FLAG — rc 0 for a long option name such as --state-export-keep.
_tn_launch_flag_ok() {
    local re='^--[A-Za-z0-9][A-Za-z0-9._-]*$'
    [[ "${1:-}" =~ $re ]]
}

# _tn_launch_http_count FILE — the number of lines holding the word --http, comment
# lines included (the same count tn_node_strip_observer_flag compares).
_tn_launch_http_count() {
    grep -cE -- '(^|[[:space:]])--http([[:space:]]|\\?$)' "$1" 2>/dev/null || true
}

# _tn_launch_live_lines FILE [UNIT] — the non-comment lines of FILE, read as a unit
# when UNIT is 1 (default: from the name of FILE).
_tn_launch_live_lines() {
    local unit="${2:-}"
    if [[ "$unit" != "0" && "$unit" != "1" ]]; then
        unit=0
        if _tn_launch_is_unit "$1"; then
            unit=1
        fi
    fi
    awk -v u="$unit" '/^[ \t]*#/ { next } u == 1 && /^[ \t]*;/ { next } { print }' "$1" 2>/dev/null
}

# _tn_launch_same_but OLD NEW LINE TEXT — rc 0 when NEW has as many lines as OLD
# and matches it everywhere except line LINE, which reads TEXT.
_tn_launch_same_but() {
    TN_LE_TEXT="$4" awk -v n="$3" '
        NR == FNR { b[FNR] = $0; nb = FNR; next }
        { nl = FNR
          if (FNR == n + 0) { if ($0 != ENVIRON["TN_LE_TEXT"]) bad = 1 }
          else if ($0 != b[FNR]) bad = 1 }
        END { exit (bad || nl != nb || n + 0 < 1) }
    ' "$1" "$2" 2>/dev/null
}

# _tn_launch_staged_ok OP FILE TMP FLAG VALUE HASVAL FLAGS MARKER — rc 0 when the
# staged copy TMP of FILE may be written: non-empty, as many --http lines, and the
# change reads back as intended (set: FLAG once, with VALUE or as a boolean; unset:
# FLAG gone; inject: only the target line changed, to that line plus FLAGS, and
# MARKER now on a live line). A shell wrapper that passed bash -n must still pass.
_tn_launch_staged_ok() {
    local op="$1" file="$2" tmp="$3" flag="$4" value="$5" hasval="$6" flags="$7" marker="$8"
    local unit=0 before after rc probe n b raw tl old want re live
    if _tn_launch_is_unit "$file"; then
        unit=1
    fi
    [[ -s "$tmp" ]] || return 1
    before="$(_tn_launch_http_count "$file")"
    after="$(_tn_launch_http_count "$tmp")"
    [[ -n "$before" && "$before" == "$after" ]] || return 1
    case "$op" in
        set|unset)
            rc=0
            probe="$(_tn_launch_awk probe "$tmp" "$flag" "" 0 "" "$unit")" || rc=$?
            [[ "$rc" -eq 10 ]] || return 1
            n=""
            b=""
            raw=""
            read -r n b raw <<<"$probe" || true
            if [[ "$op" == "unset" ]]; then
                [[ "$n" == "0" ]] || return 1
            elif [[ "$hasval" == "1" ]]; then
                [[ "$n" == "1" && "$b" == "0" && "$raw" == "$value" ]] || return 1
            else
                [[ "$n" == "1" && "$b" == "1" ]] || return 1
            fi
            ;;
        inject)
            rc=0
            tl="$(_tn_launch_awk target "$file")" || rc=$?
            [[ "$rc" -eq 10 && "$tl" =~ ^[0-9]+$ ]] || return 1
            old="$(sed -n "${tl}p" "$file")"
            re='[[:space:]]*\\[[:space:]]*$'
            if [[ "$old" =~ $re ]]; then
                want="${old%"${BASH_REMATCH[0]}"} ${flags} \\"
            else
                want="${old} ${flags}"
            fi
            _tn_launch_same_but "$file" "$tmp" "$tl" "$want" || return 1
            live="$(_tn_launch_live_lines "$tmp" "$unit")"
            grep -qE -- "$marker" <<<"$live" 2>/dev/null || return 1
            ;;
        *)
            return 1
            ;;
    esac
    if [[ "$unit" -eq 0 ]] && "${BASH:-bash}" -n "$file" 2>/dev/null \
        && ! "${BASH:-bash}" -n "$tmp" 2>/dev/null; then
        return 1
    fi
    return 0
}

# _tn_launch_write FILE TMP — copy TMP over FILE in place (cat >, so owner and mode
# stay) and compare the bytes; on a failure the old content is put back. rc 0
# written, 4 I/O error.
_tn_launch_write() {
    local file="$1" tmp="$2" keep
    keep="$(mktemp 2>/dev/null || true)"
    [[ -n "$keep" && -f "$keep" ]] || return 4
    if ! { cat "$file" > "$keep"; } 2>/dev/null; then
        rm -f "$keep"
        return 4
    fi
    if { cat "$tmp" > "$file"; } 2>/dev/null && cmp -s "$tmp" "$file"; then
        rm -f "$keep"
        return 0
    fi
    { cat "$keep" > "$file"; } 2>/dev/null || true
    rm -f "$keep"
    return 4
}

# _tn_launch_edit OP FILE FLAG VALUE HASVAL FLAGS MARKER — stage one edit with the
# parser, check the staged copy and write it back. rc per the family table.
_tn_launch_edit() {
    local op="$1" file="$2" flag="$3" value="$4" hasval="$5" flags="$6" marker="$7" tmp rc
    tmp="$(mktemp 2>/dev/null || true)"
    [[ -n "$tmp" && -f "$tmp" ]] || return 4
    rc=0
    _tn_launch_awk "$op" "$file" "$flag" "$value" "$hasval" "$flags" > "$tmp" 2>/dev/null || rc=$?
    case "$rc" in
        10) rc=0 ;;
        11) rc=1 ;;
        12) rc=2 ;;
        13) rc=3 ;;
        14)
            rc=3
            if [[ "$op" == "set" ]]; then
                printf 'tn_launch_flag_set: the value for %s is not a single shell word (a space, an unquoted ; | & < > ( ) * ? [, a line break or an open quote)\n' "$flag" >&2
            else
                printf 'tn_node_inject_flags: FLAGS are not single shell words (an unquoted ; | & < > ( ) * ? [, a line break, an open quote or a # word)\n' >&2
            fi
            ;;
        *)  rc=4 ;;
    esac
    if [[ "$rc" -eq 0 ]]; then
        if ! _tn_launch_staged_ok "$op" "$file" "$tmp" "$flag" "$value" "$hasval" "$flags" "$marker"; then
            rc=3
        elif [[ ! -w "$file" ]]; then
            rc=4
        else
            _tn_launch_write "$file" "$tmp" || rc=$?
        fi
    fi
    rm -f "$tmp"
    return "$rc"
}

# tn_node_inject_flags FILE MARKER_ERE FLAGS — add FLAGS (one or more words, copied
# verbatim) to the target line of launch file FILE unless MARKER_ERE, an extended
# regex, already matches a non-comment line. FLAGS must contain what MARKER_ERE
# matches, so a second call changes nothing. rc per the family table: 1 when the
# marker is already on a live line; 3 when FLAGS is empty or not single shell words
# (an unquoted ; | & < > ( ) * ? [, a line break, an open quote or a # word; a
# line on stderr says so), carries $, % or a backtick into a .service file, or
# when MARKER_ERE is empty, invalid or still unmatched after the edit. Callers:
# setup-observability.sh (--healthcheck), lib/observability.sh (log and metrics
# flags), install-caddy.sh (--ws flags).
tn_node_inject_flags() {
    local file="${1:-}" marker="${2:-}" flags="${3:-}" live rc
    [[ -n "$file" && -f "$file" && -r "$file" ]] || return 4
    [[ -n "$marker" && -n "$flags" ]] || return 3
    if _tn_launch_is_unit "$file"; then
        case "$flags" in
            *'$'*|*'%'*|*'`'*) return 3 ;;
        esac
    fi
    live="$(_tn_launch_live_lines "$file")"
    rc=0
    grep -qE -- "$marker" <<<"$live" 2>/dev/null || rc=$?
    case "$rc" in
        0) return 1 ;;
        1) ;;
        *) return 3 ;;
    esac
    _tn_launch_edit inject "$file" "" "" 0 "$flags" "$marker"
}

# tn_launch_flag_get FILE FLAG — print the value FLAG has in the node command of
# launch file FILE, outer quotes removed (an empty line for a boolean flag). The
# first occurrence wins. rc 0 found, 1 absent, 2 no live node --http line, 3 a bad
# FLAG or a command the parser cannot read, 4 FILE missing or unreadable.
tn_launch_flag_get() {
    local file="${1:-}" flag="${2:-}" out rc
    [[ -n "$file" && -f "$file" && -r "$file" ]] || return 4
    _tn_launch_flag_ok "$flag" || return 3
    rc=0
    out="$(_tn_launch_awk get "$file" "$flag" 2>/dev/null)" || rc=$?
    case "$rc" in
        10) printf '%s\n' "$out"; return 0 ;;
        11) return 1 ;;
        12) return 2 ;;
        13) return 3 ;;
        *)  return 4 ;;
    esac
}

# tn_launch_flag_set FILE FLAG [VALUE] — make the node command of launch file FILE
# carry FLAG with VALUE (copied verbatim, quotes and all) or, with no VALUE, as a
# boolean. An existing FLAG is rewritten where it stands and any repeat removed; a
# missing one is added to the target line. rc per the family table: 1 when FLAG
# already reads VALUE exactly; 3 for an empty VALUE, one starting with - or #, one
# that is not a single shell word (a space, an unquoted ; | & < > ( ) * ? [, a line
# break or an open quote; a line on stderr says so; quote it, as in
# '"$(cat /etc/telcoin/x.yaml)"'), and, in a .service file, a VALUE with $, % or a
# backtick (systemd would expand them).
tn_launch_flag_set() {
    local file="${1:-}" flag="${2:-}" value="" hasval=0
    if [[ $# -ge 3 ]]; then
        value="$3"
        hasval=1
    fi
    [[ -n "$file" && -f "$file" && -r "$file" ]] || return 4
    _tn_launch_flag_ok "$flag" || return 3
    if [[ "$hasval" -eq 1 ]]; then
        [[ -n "$value" ]] || return 3
        case "$value" in
            -*|'#'*) return 3 ;;
        esac
        if _tn_launch_is_unit "$file"; then
            case "$value" in
                *'$'*|*'%'*|*'`'*) return 3 ;;
            esac
        fi
    fi
    _tn_launch_edit set "$file" "$flag" "$value" "$hasval" "" ""
}

# tn_launch_flag_unset FILE FLAG — remove every occurrence of FLAG, with its value,
# from the node command of launch file FILE. A line left empty is dropped. rc per
# the family table (1 when FLAG is absent).
tn_launch_flag_unset() {
    local file="${1:-}" flag="${2:-}"
    [[ -n "$file" && -f "$file" && -r "$file" ]] || return 4
    _tn_launch_flag_ok "$flag" || return 3
    _tn_launch_edit unset "$file" "$flag" "" 0 "" ""
}

# tn_launch_runner [FILE] — print the runner spec of the node command in launch
# file FILE (default: the file tn_node_launch_target names): "docker:<image>" when
# the command is `docker run ... <image> telcoin node ...`, else "binary:<path>"
# for `<path> node ...` (a bare name is looked up on PATH). Read from the launch
# file, which is what actually starts the node, not from .node-meta. rc 0 printed,
# 1 no runner recognised, 2 no live node --http line or no node service, 3 a
# command the parser cannot read, 4 FILE missing or unreadable.
tn_launch_runner() {
    local file="${1:-}" target out rc kind val image_re
    image_re='^[A-Za-z0-9][A-Za-z0-9._/:@-]*$'
    if [[ -z "$file" ]]; then
        target="$(tn_node_launch_target 2>/dev/null)" || return 2
        read -r _ _ file <<<"$target" || true
    fi
    [[ -n "$file" && -f "$file" && -r "$file" ]] || return 4
    rc=0
    out="$(_tn_launch_awk runner "$file" 2>/dev/null)" || rc=$?
    case "$rc" in
        10) ;;
        11) return 1 ;;
        12) return 2 ;;
        13) return 3 ;;
        *)  return 4 ;;
    esac
    kind="${out%% *}"
    val="${out#* }"
    case "$kind" in
        docker)
            [[ "$val" =~ $image_re ]] || return 1
            printf 'docker:%s\n' "$val"
            ;;
        binary)
            if [[ "$val" != /* ]]; then
                val="$(command -v "$val" 2>/dev/null || true)"
            fi
            [[ "$val" == /* ]] || return 1
            case "$val" in
                *[[:space:]]*|*'$'*|*'`'*) return 1 ;;
            esac
            printf 'binary:%s\n' "$val"
            ;;
        *)
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Node binary: keytool and probes (COMMON_VERSION >= 1.6.0)
# -----------------------------------------------------------------------------
#
# SPEC is a runner spec from tn_launch_runner: docker:<image> runs `telcoin` in a
# throwaway container of that image, binary:<abs-path> runs that file. Probes ask
# the binary that actually starts the node, so a feature check follows the release
# installed rather than a version number (every release reports crate 0.1.0).

# _tn_runner_probe SPEC ARGS... — run the node binary of SPEC with ARGS for a help
# or parse probe: no data dir mounted, stdin from /dev/null. rc is the binary's
# own, or 127 when SPEC is malformed or names no executable file.
_tn_runner_probe() {
    local spec="${1:-}" bin
    if [[ $# -gt 0 ]]; then
        shift
    fi
    case "$spec" in
        docker:?*)
            docker run --rm "${spec#docker:}" telcoin "$@" </dev/null
            ;;
        binary:/?*)
            bin="${spec#binary:}"
            [[ -f "$bin" && -x "$bin" ]] || return 127
            "$bin" "$@" </dev/null
            ;;
        *)
            return 127
            ;;
    esac
}

# _tn_help_lists WORD TEXT — rc 0 when clap help TEXT defines WORD on an option
# line ("  -h, --help", "      --http.addr <HTTP_ADDR>") or a subcommand line
# ("  set-rpc  Set or clear ..."). Description lines are indented deeper and never
# count, so a flag only mentioned in another flag's help is not taken as listed.
_tn_help_lists() {
    TN_HELP_WORD="$1" awk '
        { line = $0
          match(line, /^ */)
          if (RLENGTH > 6) next
          sub(/^ +/, "", line)
          if (line ~ /^-[A-Za-z0-9], /) line = substr(line, 5)
          sub(/[ ,=<].*$/, "", line)
          sub(/\[.*$/, "", line)
          sub(/\.\.\.$/, "", line)
          if (line != "" && line == ENVIRON["TN_HELP_WORD"]) { found = 1; exit } }
        END { exit(found ? 0 : 1) }
    ' <<<"$2" 2>/dev/null
}

# tn_node_has_flag SPEC FLAG — rc 0 when `node --help` of SPEC lists FLAG (say
# --bootstrap-peers, new in v0.15.0-adiri), 1 when it does not, 4 when the probe
# could not run (no such binary, docker failed).
tn_node_has_flag() {
    local spec="${1:-}" flag="${2:-}" out rc
    [[ -n "$flag" ]] || return 1
    rc=0
    out="$(_tn_runner_probe "$spec" node --help 2>&1)" || rc=$?
    case "$rc" in
        0) ;;
        1|2) return 1 ;;
        *) return 4 ;;
    esac
    _tn_help_lists "$flag" "$out"
}

# tn_keytool_has SPEC WORD [SUBCMD...] — rc 0 when `keytool SUBCMD... --help` of
# SPEC lists WORD, an option (--rpc-http) or a subcommand (set-rpc); 1 when it does
# not or the subcommand is unknown to this release; 4 when the probe could not run.
tn_keytool_has() {
    local spec="${1:-}" word="${2:-}" out rc
    [[ $# -ge 2 && -n "$word" ]] || return 1
    shift 2
    rc=0
    out="$(_tn_runner_probe "$spec" keytool "$@" --help 2>&1)" || rc=$?
    case "$rc" in
        0) ;;
        1|2) return 1 ;;
        *) return 4 ;;
    esac
    _tn_help_lists "$word" "$out"
}

# _tn_parse_check_message — read clap's output on stdin and print its error as one
# line. The probe's ARGS are this function's arguments. For
# "invalid value '<value>' for '<arg>': <reason>" the value, which may span many
# lines and is often a whole file, becomes '…'; inside the reason every
# double-quoted string (serde quotes the input it rejects that way) becomes "…",
# and so does a backquoted word that occurs in ARGS. Other errors pass through
# as they are. Lines after the first are trimmed and joined with "; ", up to
# clap's Usage: or "For more information" footer. rc 1, no output, when there
# is no clap error line. Usage: _tn_parse_check_message ARGS... <clap-output. The
# ARGS reach awk through its environment, not an argument list, so they do not
# show in the process list.
_tn_parse_check_message() {
    (
        i=0
        for arg in "$@"; do
            i=$(( i + 1 ))
            export "TN_PC_A${i}=${arg}"
        done
        export TN_PC_N="$i"
        awk '
            function redact(s,    o, i, n, c, j, cc, inner, k, hit) {
                o = ""; n = length(s); i = 1
                while (i <= n) {
                    c = substr(s, i, 1)
                    if (c == "\"") {
                        j = i + 1
                        while (j <= n) {
                            cc = substr(s, j, 1)
                            if (cc == "\\") { j += 2; continue }
                            if (cc == "\"") break
                            j++
                        }
                        if (j > n) { o = o "\"" ELL; break }
                        o = o "\"" ELL "\""; i = j + 1; continue
                    }
                    if (c == "`") {
                        j = index(substr(s, i + 1), "`")
                        if (j) {
                            inner = substr(s, i + 1, j - 1); hit = 0
                            for (k = 1; k <= NA; k++) if (inner != "" && index(A[k], inner)) hit = 1
                            o = o "`" (hit ? ELL : inner) "`"; i += j + 1; continue
                        }
                    }
                    o = o c; i++
                }
                return o
            }
            BEGIN {
                SQ = sprintf("%c", 39); ESC = sprintf("%c", 27); ELL = "…"
                IV = "invalid value " SQ; FQ = SQ " for " SQ
                NA = ENVIRON["TN_PC_N"] + 0
                for (k = 1; k <= NA; k++) A[k] = ENVIRON["TN_PC_A" k]
            }
            { gsub(ESC "\\[[0-9;]*m", ""); all = (NR == 1) ? $0 : all "\n" $0 }
            END {
                if (substr(all, 1, 6) == "error:") p = 1
                else { p = index(all, "\nerror:"); if (p) p++ }
                if (!p) exit 1
                msg = substr(all, p)
                iv = (substr(msg, 1, 7 + length(IV)) == "error: " IV)
                if (iv) {
                    # The value is one of ARGS, so cut exactly that (the longest
                    # match, should one argument start another). When it cannot be
                    # found as given, cut up to the last quote-for-quote-dash.
                    best = 0; blen = -1
                    for (k = 1; k <= NA; k++) {
                        if (A[k] == "" || !index(msg, IV A[k] FQ)) continue
                        if (length(A[k]) > blen) { best = k; blen = length(A[k]) }
                    }
                    q = 8 + length(IV)
                    if (best) {
                        nd = IV A[best] FQ; r = index(msg, nd)
                        msg = substr(msg, 1, r - 1) IV ELL FQ substr(msg, r + length(nd))
                    } else {
                        r = 0; t = q
                        while ((k = index(substr(msg, t), FQ "-")) > 0) { r = t + k - 1; t = r + 1 }
                        if (r) msg = substr(msg, 1, q - 1) ELL substr(msg, r)
                        else msg = substr(msg, 1, q - 1) ELL SQ
                    }
                }
                m = split(msg, L, "\n"); line = ""
                for (j = 1; j <= m; j++) {
                    s = L[j]; sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
                    if (s ~ /^(Usage:|For more information)/) break
                    if (s != "") line = (line == "") ? s : line "; " s
                }
                if (iv) line = redact(line)
                print line
            }
        ' 2>/dev/null
    )
}

# tn_node_parse_check SPEC ARGS... — rc 0 when the node binary of SPEC accepts
# `node ARGS... --help`. clap parses every value before it prints the help, so this
# checks a value such as a --bootstrap-peers map without starting anything. rc 1
# when the arguments are rejected, with clap's error on stdout as ONE line
# (_tn_parse_check_message): the rejected value shows as '…' and input that the
# reason quotes as "…", so the message can be shown to someone who may not read
# the file the value came from. rc 4 when the probe could not run, with the reason
# on stdout. The value still goes to the node binary as an argument, which other
# local users can see in the process list while the probe runs.
tn_node_parse_check() {
    local spec="${1:-}" out rc line
    if [[ $# -gt 0 ]]; then
        shift
    fi
    rc=0
    out="$(_tn_runner_probe "$spec" node "$@" --help 2>&1)" || rc=$?
    case "$rc" in
        0)
            return 0
            ;;
        1|2)
            line="$(_tn_parse_check_message "$@" <<<"$out" || true)"
            printf '%s\n' "${line:-rejected (exit ${rc})}"
            return 1
            ;;
        *)
            printf 'could not run the node binary of %s (exit %s)\n' "$spec" "$rc"
            return 4
            ;;
    esac
}

# _tn_path_owner PATH — print "<uid> <gid>" of PATH (GNU stat, then BSD stat).
_tn_path_owner() {
    local out re='^[0-9]+ [0-9]+$'
    out="$(stat -c '%u %g' "$1" 2>/dev/null || true)"
    if [[ ! "$out" =~ $re ]]; then
        out="$(stat -f '%u %g' "$1" 2>/dev/null || true)"
    fi
    [[ "$out" =~ $re ]] || return 1
    printf '%s\n' "$out"
}

# tn_keytool SPEC DATA_DIR ARGS... — run `keytool ARGS...` of runner SPEC on node
# data dir DATA_DIR; keytool's output passes through. Every @DATADIR@ inside an
# argument becomes the data dir as keytool sees it: DATA_DIR for binary:, the mount
# point /home/nonroot for docker:.
#   * Global flags go before `keytool`: -q, so the tracing line keytool otherwise
#     prints on stdout cannot spoil a $(...) capture, unless ARGS already has it;
#     and --datadir, the data dir as keytool sees it. A --datadir X (or
#     --datadir=X) anywhere in ARGS is moved there, since keytool refuses it
#     after some subcommands. When ARGS starts with export-staking-args and
#     TN_BLS_PASSPHRASE is unset or empty, --bls-passphrase-source no-passphrase is
#     added too: that command never reads the key yet refuses to run without a
#     passphrase source. Never for generate ..., which would then write or read
#     the key in the clear, nor for anything else.
#   * A non-empty TN_BLS_PASSPHRASE reaches keytool through the environment only;
#     docker gets `-e TN_BLS_PASSPHRASE` by name, so the value is in no argv. An
#     empty one is treated as unset: keytool runs without the variable.
#   * docker runs as the owner of DATA_DIR, with HOME=/home/nonroot and DATA_DIR
#     mounted there, the way setup-node.sh runs keygen. DATA_DIR must exist.
# rc is keytool's own, or 4 when it cannot be started (bad SPEC, no executable
# file, no DATA_DIR for docker, too few arguments, --datadir without a value);
# docker's own failures come back as docker's rc (125 and up).
tn_keytool() {
    local spec="${1:-}" data_dir="${2:-}" in_dir arg rest done_part first bin owner uid gid
    local dd_val="" has_q=0 has_src=0 has_pass=0 is_dd
    local -a args=() glob=() drun=()
    if [[ $# -lt 3 || -z "$data_dir" ]]; then
        printf 'tn_keytool: usage: tn_keytool SPEC DATA_DIR KEYTOOL-ARGS...\n' >&2
        return 4
    fi
    shift 2
    case "$spec" in
        docker:?*) in_dir="/home/nonroot" ;;
        binary:/?*) in_dir="$data_dir" ;;
        *)
            printf 'tn_keytool: unknown runner spec: %s\n' "$spec" >&2
            return 4
            ;;
    esac
    dd_val="$in_dir"
    while [[ $# -gt 0 ]]; do
        arg="$1"
        shift
        is_dd=0
        case "$arg" in
            --datadir)
                if [[ $# -eq 0 ]]; then
                    printf 'tn_keytool: --datadir needs a value\n' >&2
                    return 4
                fi
                arg="$1"
                shift
                is_dd=1
                ;;
            --datadir=*)
                arg="${arg#--datadir=}"
                is_dd=1
                ;;
            -q|--quiet) has_q=1 ;;
            --bls-passphrase-source|--bls-passphrase-source=*) has_src=1 ;;
        esac
        rest="$arg"
        done_part=""
        while [[ "$rest" == *@DATADIR@* ]]; do
            done_part="${done_part}${rest%%@DATADIR@*}${in_dir}"
            rest="${rest#*@DATADIR@}"
        done
        if [[ "$is_dd" -eq 1 ]]; then
            dd_val="${done_part}${rest}"
        else
            args+=("${done_part}${rest}")
        fi
    done
    first="${args[0]:-}"
    if [[ -n "${TN_BLS_PASSPHRASE:-}" ]]; then
        has_pass=1
    fi
    if [[ "$has_q" -eq 0 ]]; then
        glob+=(-q)
    fi
    glob+=(--datadir "$dd_val")
    if [[ "$has_src" -eq 0 && "$first" == "export-staking-args" && "$has_pass" -eq 0 ]]; then
        glob+=(--bls-passphrase-source no-passphrase)
    fi
    case "$spec" in
        binary:*)
            bin="${spec#binary:}"
            if [[ ! -f "$bin" || ! -x "$bin" ]]; then
                printf 'tn_keytool: %s is not an executable file\n' "$bin" >&2
                return 4
            fi
            if [[ "$has_pass" -eq 1 ]]; then
                TN_BLS_PASSPHRASE="$TN_BLS_PASSPHRASE" "$bin" ${glob[@]+"${glob[@]}"} keytool ${args[@]+"${args[@]}"}
            else
                ( unset TN_BLS_PASSPHRASE; "$bin" ${glob[@]+"${glob[@]}"} keytool ${args[@]+"${args[@]}"} )
            fi
            ;;
        docker:*)
            if [[ ! -d "$data_dir" ]]; then
                printf 'tn_keytool: data dir %s does not exist\n' "$data_dir" >&2
                return 4
            fi
            owner="$(_tn_path_owner "$data_dir")" || {
                printf 'tn_keytool: cannot read the owner of %s\n' "$data_dir" >&2
                return 4
            }
            uid="${owner%% *}"
            gid="${owner##* }"
            drun=(run --rm --user "${uid}:${gid}" -e HOME=/home/nonroot)
            if [[ "$has_pass" -eq 1 ]]; then
                drun+=(-e TN_BLS_PASSPHRASE)
            fi
            drun+=(-v "${data_dir}:/home/nonroot" "${spec#docker:}" telcoin)
            if [[ "$has_pass" -eq 1 ]]; then
                TN_BLS_PASSPHRASE="$TN_BLS_PASSPHRASE" docker "${drun[@]}" ${glob[@]+"${glob[@]}"} keytool ${args[@]+"${args[@]}"}
            else
                ( unset TN_BLS_PASSPHRASE; docker "${drun[@]}" ${glob[@]+"${glob[@]}"} keytool ${args[@]+"${args[@]}"} )
            fi
            ;;
    esac
}

# -----------------------------------------------------------------------------
# node-info.yaml readers (COMMON_VERSION >= 1.6.0)
# -----------------------------------------------------------------------------
#
# keytool writes node-info.yaml beside the node keys. v0.15.0-adiri and later
# write p2p_info.workers as a list with one entry per worker; v0.14.0 and older
# write a single p2p_info.worker map. Both shapes are read, with awk only (no
# python3 or yq on a node). The readers return rc 0 with the value, 1 when the
# value is absent, null or unusable, and 4 when FILE is missing or unreadable.

# _tn_node_info_flat FILE — every scalar of a block-style YAML file as one
# "<dotted.path><TAB><value>" line, list items numbered from 0
# (p2p_info.workers.0.rpc.http). Quotes and trailing comments are removed; ~, null
# and an empty value come out empty. Any indent width works, and a list may sit at
# its key's own indent. Flow style ({...}, [...]) comes out as raw text. rc 3 for
# a tab in the indentation, which YAML forbids.
_tn_node_info_flat() {
    awk '
        function lead(s) { match(s, /^ */); return RLENGTH }
        function path(k,    i, p) { p = ""; for (i = 1; i <= D; i++) p = p FK[i] "."; return p k }
        function put(k, v) { printf "%s\t%s\n", path(k), v }
        # A scalar without its quotes or a trailing comment; nulls come out empty.
        function scalar(v,    q, j, n) {
            sub(/^[ \t]+/, "", v)
            q = substr(v, 1, 1); n = length(v)
            if (q == "\"") {
                for (j = 2; j <= n; j++) {
                    if (substr(v, j, 1) == "\\") { j++; continue }
                    if (substr(v, j, 1) == "\"") return substr(v, 2, j - 2)
                }
                return v
            }
            if (q == SQ) {
                for (j = 2; j <= n; j++) {
                    if (substr(v, j, 1) != SQ) continue
                    if (substr(v, j + 1, 1) == SQ) { j++; continue }
                    return substr(v, 2, j - 2)
                }
                return v
            }
            if (match(v, /[ \t]#/)) v = substr(v, 1, RSTART - 1)
            sub(/[ \t]+$/, "", v)
            if (v == "~" || v == "null" || v == "Null" || v == "NULL") v = ""
            return v
        }
        # A key with no value opens a block whose indent the next line sets.
        function opener(k, n) { D++; FK[D] = k; FP[D] = 1; FO[D] = n; FI[D] = -1; FQ[D] = 0; FC[D] = 0 }
        function frame(k, ind) { D++; FK[D] = k; FP[D] = 0; FO[D] = -1; FI[D] = ind; FQ[D] = 0; FC[D] = 0 }
        function pair(n, c,    k, v, q) {
            if (!match(c, /:([ \t]|$)/)) return
            k = substr(c, 1, RSTART - 1); v = substr(c, RSTART + 1)
            sub(/[ \t]+$/, "", k)
            q = substr(k, 1, 1)
            if ((q == "\"" || q == SQ) && length(k) >= 2 && substr(k, length(k), 1) == q) k = substr(k, 2, length(k) - 2)
            sub(/^[ \t]+/, "", v)
            if (v == "" || substr(v, 1, 1) == "#") { opener(k, n); return }
            put(k, scalar(v))
        }
        BEGIN { SQ = sprintf("%c", 39); D = 0 }
        {
            s = $0
            sub(/\r$/, "", s)
            if (s ~ /^[ \t]*$/ || s ~ /^[ \t]*#/) next
            if (s ~ /^(---|\.\.\.)([ \t]|$)/) next
            if (s ~ /^ *\t/) { bad = 1; exit }
            n = lead(s); c = substr(s, n + 1)
            item = (c ~ /^-([ \t]|$)/)
            if (D > 0 && FP[D]) {
                if (n > FO[D] || (n == FO[D] && item)) { FP[D] = 0; FI[D] = n; FQ[D] = item; FC[D] = 0 }
                else { D--; put(FK[D + 1], "") }
            }
            while (D > 0 && (FI[D] > n || (FI[D] == n && FQ[D] && !item))) D--
            if (!item) { pair(n, c); next }
            if (!(D > 0 && FQ[D] && FI[D] == n)) next
            idx = FC[D]++
            r = substr(c, 2); col = n + 1
            while (r ~ /^[ \t]/) { r = substr(r, 2); col++ }
            if (r == "" || substr(r, 1, 1) == "#") { opener(idx, n); next }
            q = substr(r, 1, 1)
            if (q != "\"" && q != SQ && match(r, /:([ \t]|$)/)) { frame(idx, col); pair(col, r); next }
            put(idx, scalar(r))
        }
        END {
            if (bad) exit 3
            if (D > 0 && FP[D]) { D--; put(FK[D + 1], "") }
        }
    ' "$1" 2>/dev/null
}

# _tn_ni_pick FLAT PATH — print the value at PATH in FLAT; rc 1 when PATH is absent.
_tn_ni_pick() {
    TN_NI_PATH="$2" awk -F '\t' '
        $1 == ENVIRON["TN_NI_PATH"] { sub(/^[^\t]*\t/, ""); print; found = 1; exit }
        END { exit(found ? 0 : 1) }
    ' <<<"$1" 2>/dev/null
}

# _tn_multiaddr_udp_port MULTIADDR — print the UDP port of a multiaddr such as
# /ip4/203.0.113.7/udp/49590/quic-v1/p2p/12D3...; rc 1 when it has none.
_tn_multiaddr_udp_port() {
    local re='/udp/([0-9]{1,5})(/|$)' port
    [[ "${1:-}" =~ $re ]] || return 1
    port=$(( 10#${BASH_REMATCH[1]} ))
    (( port >= 1 && port <= 65535 )) || return 1
    printf '%s\n' "$port"
}

# tn_node_info_field FILE KEY — print one field of node-info.yaml. KEY is name,
# bls_public_key, execution_address, proof_of_possession, primary_address (the
# primary network_address multiaddr as written) or primary_port (its UDP port).
# An unknown KEY is rc 1.
tn_node_info_field() {
    local file="${1:-}" key="${2:-}" flat path v rc
    case "$key" in
        name|bls_public_key|execution_address|proof_of_possession) path="$key" ;;
        primary_address|primary_port) path="p2p_info.primary.network_address" ;;
        *) return 1 ;;
    esac
    [[ -n "$file" && -f "$file" && -r "$file" ]] || return 4
    rc=0
    flat="$(_tn_node_info_flat "$file")" || rc=$?
    [[ "$rc" -eq 0 ]] || return 1
    v="$(_tn_ni_pick "$flat" "$path")" || return 1
    [[ -n "$v" ]] || return 1
    if [[ "$key" == "primary_port" ]]; then
        v="$(_tn_multiaddr_udp_port "$v")" || return 1
    fi
    printf '%s\n' "$v"
}

# tn_node_info_worker_ports FILE — print the UDP port of each worker in
# node-info.yaml, one per line in worker order (p2p_info.workers), or the single
# port of a legacy p2p_info.worker map. rc 1, with nothing printed, when there is
# no worker or any worker address has no UDP port.
tn_node_info_worker_ports() {
    local file="${1:-}" flat rc count i v port out
    [[ -n "$file" && -f "$file" && -r "$file" ]] || return 4
    rc=0
    flat="$(_tn_node_info_flat "$file")" || rc=$?
    [[ "$rc" -eq 0 ]] || return 1
    count="$(awk -F '\t' '
        index($1, "p2p_info.workers.") == 1 {
            s = substr($1, 18); sub(/\..*$/, "", s)
            if (s ~ /^[0-9]+$/ && s + 1 > m) m = s + 1
        }
        END { print m + 0 }
    ' <<<"$flat" 2>/dev/null || true)"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    out=""
    if (( count > 0 )); then
        i=0
        while (( i < count )); do
            v="$(_tn_ni_pick "$flat" "p2p_info.workers.${i}.network_address")" || return 1
            port="$(_tn_multiaddr_udp_port "$v")" || return 1
            out="${out}${port}"$'\n'
            i=$(( i + 1 ))
        done
    else
        v="$(_tn_ni_pick "$flat" "p2p_info.worker.network_address")" || return 1
        port="$(_tn_multiaddr_udp_port "$v")" || return 1
        out="${port}"$'\n'
    fi
    printf '%s' "$out"
}

# tn_node_info_rpc FILE [IDX] — print "<http|none> <ws|none>", the JSON-RPC endpoints
# worker IDX (default 0) advertises in node-info.yaml (keytool set-rpc edits worker
# 0). A legacy p2p_info.worker map is worker 0. rc 1 when there is no such worker
# or its rpc is not a block map (flow style is not read).
tn_node_info_rpc() {
    local file="${1:-}" idx="${2:-0}" flat rc base v http ws
    [[ "$idx" =~ ^[0-9]+$ ]] || return 1
    idx=$(( 10#$idx ))
    [[ -n "$file" && -f "$file" && -r "$file" ]] || return 4
    rc=0
    flat="$(_tn_node_info_flat "$file")" || rc=$?
    [[ "$rc" -eq 0 ]] || return 1
    case "$flat" in
        *"p2p_info.workers."*)
            base="p2p_info.workers.${idx}"
            ;;
        *)
            [[ "$idx" -eq 0 ]] || return 1
            base="p2p_info.worker"
            ;;
    esac
    case "$flat" in
        *"${base}."*) ;;
        *) return 1 ;;
    esac
    if v="$(_tn_ni_pick "$flat" "${base}.rpc")" && [[ -n "$v" ]]; then
        return 1
    fi
    http="$(_tn_ni_pick "$flat" "${base}.rpc.http" || true)"
    ws="$(_tn_ni_pick "$flat" "${base}.rpc.ws" || true)"
    printf '%s %s\n' "${http:-none}" "${ws:-none}"
}

# tn_node_has_observer_flag <file> — rc 0 when a NON-comment line of <file> carries
# the `--observer` flag as a whole token: bounded by line start or whitespace on the
# left and by whitespace, end of line or a trailing line-continuation backslash on
# the right (so --observer-foo / --observer=x never match). Lines whose first
# non-blank character is `#` are comments and are ignored. rc 1 otherwise, or when
# <file> is missing or unreadable. No output.
tn_node_has_observer_flag() {
    local file="${1:-}"
    [[ -n "$file" && -f "$file" && -r "$file" ]] || return 1
    awk '
        /^[[:space:]]*#/ { next }
        /(^|[[:space:]])--observer([[:space:]]|\\?$)/ { found = 1; exit }
        END { exit(found ? 0 : 1) }
    ' "$file" 2>/dev/null
}

# tn_node_strip_observer_flag <file> — idempotently remove the `--observer` flag
# from a node launch file (start wrapper or legacy docker unit). Releases after
# v0.15.0-adiri reject the flag outright, so an old wrapper must lose it before the
# node is restarted on a new binary or image.
#   * flag absent (per tn_node_has_observer_flag): rc 0, file untouched;
#   * a line holding only the flag (plus optional `\`) is deleted. When that line
#     ended the command (no `\`), the trailing `\` is dropped from the line before
#     it so the continuation does not swallow the next command;
#   * on any other non-comment line the token and one adjacent run of whitespace
#     are removed; comment lines are never touched; --instance is never touched.
# The edit is staged in a temp file and only written back (cat > file, which keeps
# owner and mode) when the temp copy is non-empty, no longer has the flag, and has
# the same number of whole-word --http lines. On any failed check the file is left
# as it was and rc is 1. The caller owns the backup, daemon-reload (docker unit)
# and restart, as with tn_node_inject_flags.
tn_node_strip_observer_flag() {
    local file="${1:-}" tmp http_before http_after http_re
    http_re='(^|[[:space:]])--http([[:space:]]|\\?$)'
    tn_node_has_observer_flag "$file" || return 0
    [[ -w "$file" ]] || return 1
    tmp="$(mktemp 2>/dev/null || true)"
    [[ -n "$tmp" && -f "$tmp" ]] || return 1
    if ! awk '
        function flush() { if (have) print prev; have = 0 }
        /^[[:space:]]*#/ { flush(); prev = $0; have = 1; prev_comment = 1; next }
        /^[[:space:]]*--observer[[:space:]]*(\\[[:space:]]*)?$/ {
            if ($0 !~ /\\[[:space:]]*$/ && have && !prev_comment) sub(/[[:space:]]*\\[[:space:]]*$/, "", prev)
            next
        }
        {
            line = $0
            while (match(line, /(^|[[:space:]])--observer([[:space:]]|\\?$)/)) {
                tstart = RSTART
                if (substr(line, RSTART, 1) != "-") tstart = RSTART + 1
                before = substr(line, 1, tstart - 1)
                after = substr(line, tstart + 10)
                if (before ~ /[^[:space:]]/) sub(/[[:space:]]+$/, "", before)
                else sub(/^[[:space:]]+/, "", after)
                line = before after
            }
            flush(); prev = line; have = 1; prev_comment = 0
        }
        END { flush() }
    ' "$file" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"; return 1
    fi
    http_before="$(grep -cE -- "$http_re" "$file" 2>/dev/null || true)"
    http_after="$(grep -cE -- "$http_re" "$tmp" 2>/dev/null || true)"
    if [[ -s "$tmp" ]] && ! tn_node_has_observer_flag "$tmp" \
        && [[ -n "$http_before" && "$http_before" == "$http_after" ]]; then
        if cat "$tmp" > "$file"; then
            rm -f "$tmp"; return 0
        fi
    fi
    rm -f "$tmp"; return 1
}

# tn_target_drops_observer <text...> — rc 0 when the release named by <text> no
# longer needs `--observer` in the launch line, so stripping it is safe. <text> is
# any tag / image / version string (all args joined with spaces), e.g.
# `v0.15.0-adiri`, `us-docker.pkg.dev/...:v0.14.0-adiri` or `main telcoin-network
# 0.16.0`. The FIRST x.y.z in it is compared against 0.15.0: v0.15.0-adiri still
# accepts `--observer` as a hidden no-op and the first release after it rejects it
# (`unexpected argument '--observer'`), so stripping from 0.15.0 upward is always
# safe. With no x.y.z at all (branch name, bare SHA, digest) the target is assumed
# to be the newest code and rc is 0.
tn_target_drops_observer() {
    local text found ver_re
    ver_re='([0-9]+\.[0-9]+\.[0-9]+)'
    text="$*"
    found=""
    if [[ "$text" =~ $ver_re ]]; then
        found="${BASH_REMATCH[1]}"
    fi
    [[ -n "$found" ]] || return 0
    version_gte "$found" "0.15.0"
}

# -----------------------------------------------------------------------------
# In-setup opt-in flow ("ask early, act late")
# -----------------------------------------------------------------------------

# prompt_testnet_addons — interactive opt-in prompts shown right after network
# selection (testnet only). Sets ENABLE_* / REGION globals so step_create_service
# can bake the right node-launch flags on the first pass. The side-effect installs
# happen later in step_testnet_addons. No-op in JSON/non-interactive mode.
prompt_testnet_addons() {
    is_testnet || return 0
    [[ "${TN_ASSUME_YES:-false}" == "true" ]] && return 0   # JSON/UI: leave defaults

    print_header "Testnet add-ons (optional)"
    print_info "These let the Telcoin Association help run the testnet. Every one is OFF"
    print_info "by default and purely additive — opting out changes nothing about your node."
    print_info "Full trust model: docs/testnet-addons.md"

    echo ""
    print_step "Health monitoring"
    print_info "Exposes a TCP health endpoint (port ${TN_KUMA_PORT:-43174}) probed by the"
    print_info "Association uptime monitor (${TN_KUMA_SRC:-104.155.184.201/32}) so we can alert you if your node drops."
    print_info "You can also allow your own monitoring hosts later: firewall-setup.sh -> Manage node ports."
    if confirm "Enable the health-monitor endpoint?"; then
        ENABLE_HEALTHCHECK_MONITOR="true"
    fi

    echo ""
    print_step "Centralized logging"
    print_info "Ships your node's logs to the Association's Loki so we can help you debug."
    print_info "Needs a per-operator ingest token (you'll paste it, hidden, at the end of setup)."
    if confirm "Enable log shipping?"; then
        ENABLE_OBSERVABILITY="true"
    fi

    echo ""
    print_step "Metrics shipping"
    print_info "Ships your node's Prometheus metrics to the Association's central Prometheus"
    print_info "(block height, peer counts, resource use) — powers the shared node dashboards."
    print_info "Independent of logging, but reuses the SAME ingest token (one token covers both)."
    if confirm "Enable metrics shipping?"; then
        ENABLE_METRICS="true"
    fi

    # Region is a shared identity label for both telemetry pipelines — ask once if either on.
    if [[ "${ENABLE_OBSERVABILITY:-false}" == "true" || "${ENABLE_METRICS:-false}" == "true" ]]; then
        local input
        read -r -p "  Region label for your node (e.g. us-east, eu-west) [${REGION:-unknown}]: " input
        REGION="${input:-${REGION:-unknown}}"
    fi

    echo ""
    print_step "VPN admin SSH"
    print_info "Lets the Association SSH into your node over a private WireGuard overlay"
    print_info "(e.g. to help recover a stuck node) via a sudo-capable 'tnadmin' user."
    print_info "Reversible, and needs a core-team-assigned overlay IP — so it's completed"
    print_info "in a separate step (setup-vpn.sh) after this setup finishes."
    if confirm "Opt into VPN admin SSH (finish later via setup-vpn.sh)?"; then
        ENABLE_VPN="pending"
    fi
}

# step_testnet_addons — performs the side-effect installs for whatever was opted into
# in prompt_testnet_addons (ufw health rule, Alloy log shipper) and prints next-step
# guidance. Runs AFTER step_create_service (so launch flags are already baked) and
# before step_final_summary. No-op in JSON mode and on non-testnet.
step_testnet_addons() {
    json_mode 2>/dev/null && return 0
    is_testnet || return 0
    [[ "${ENABLE_HEALTHCHECK_MONITOR:-false}" == "true" || \
       "${ENABLE_OBSERVABILITY:-false}" == "true" || \
       "${ENABLE_METRICS:-false}" == "true" || \
       "${ENABLE_VPN:-false}" != "false" ]] || return 0

    print_header "Testnet add-ons — applying"

    if [[ "${ENABLE_HEALTHCHECK_MONITOR:-false}" == "true" ]]; then
        print_step "Health monitor"
        if ufw_installed && ufw_active; then
            if apply_kuma_rule; then
                print_ok "ufw: ${TN_KUMA_SRC} -> ${TN_KUMA_PORT}/tcp (Association monitor only)"
            else
                print_warn "Could not add the ufw rule; open it via firewall-setup.sh."
            fi
        elif ufw_installed; then
            # ufw installed but INACTIVE: --healthcheck binds ${TN_KUMA_PORT} on all
            # interfaces, so with no active firewall the port is reachable from the internet.
            apply_kuma_rule >/dev/null 2>&1 || true   # stage the restricted rule for when ufw is enabled
            print_warn "ufw is INACTIVE — once the node restarts, health port ${TN_KUMA_PORT} is reachable from the INTERNET."
            print_warn "Enable the firewall: run firewall-setup.sh (a source-restricted rule is already staged)."
        else
            print_warn "ufw is NOT installed — health port ${TN_KUMA_PORT} will be exposed to the internet once the node restarts."
            print_warn "Install ufw + run firewall-setup.sh, or otherwise block ${TN_KUMA_PORT}/tcp."
        fi
        print_info "Verify once the node is up: curl -s http://127.0.0.1:${TN_KUMA_PORT}  (expect OK)"
    fi

    if [[ "${ENABLE_OBSERVABILITY:-false}" == "true" || "${ENABLE_METRICS:-false}" == "true" ]]; then
        local what="logs + metrics"
        [[ "${ENABLE_METRICS:-false}" != "true" ]] && what="logs"
        [[ "${ENABLE_OBSERVABILITY:-false}" != "true" ]] && what="metrics"
        print_step "Centralized telemetry — ${what} (Alloy)"
        if declare -F obs_enable >/dev/null 2>&1; then
            local token=""
            print_info "Paste the per-operator obs ingest token (hidden input; leave blank to skip)."
            print_info "One token covers both logs and metrics."
            read -r -s -p "  Obs ingest token: " token; echo ""
            if [[ -n "$token" ]]; then
                if obs_enable "$token"; then
                    print_ok "Alloy telemetry shipper started (${what})."
                else
                    print_warn "Alloy setup did not complete; re-run setup-observability.sh."
                fi
            else
                print_warn "No token entered — telemetry not started. Run setup-observability.sh when you have one."
            fi
        else
            print_warn "lib/observability.sh missing — update scripts, then run setup-observability.sh."
        fi
    fi

    if [[ "${ENABLE_VPN:-false}" == "pending" ]]; then
        print_step "VPN admin SSH"
        print_info "Recorded as PENDING. To finish: ask the Telcoin Association for an overlay"
        print_info "IP, then run:  sudo bash setup-vpn.sh"
    fi

    echo ""
}

# Optional add-on libraries (function defs only; safe to source under set -e).
# Sourced at the END so the helpers above are already defined. Guarded for older
# checkouts that predate these files. MUST use if/fi (not `[[ ]] && source`): a
# trailing && that evaluates false would make `source lib/common.sh` itself return
# non-zero, which under the inherited `set -e` aborts every caller right here.
if [[ -f "${__COMMON_DIR}/observability.sh" ]]; then
    source "${__COMMON_DIR}/observability.sh"
fi
: # ensure common.sh always sources with status 0
