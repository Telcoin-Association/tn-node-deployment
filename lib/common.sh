#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — Shared helper functions for Telcoin node setup scripts
# =============================================================================

set -euo pipefail

# Legacy-install compatibility resolvers. Sourced near the top so every script
# that sources common.sh gets tn_resolve_service / tn_resolve_node_type /
# tn_resolve_config_dir / ... for free. fallback.sh is the only module that
# knows the old telcoin-{observer,validator} names + per-role dir layout.
# shellcheck source=lib/fallback.sh
source "${BASH_SOURCE[0]%/*}/fallback.sh"

# -----------------------------------------------------------------------------
# CONSTANTS
# -----------------------------------------------------------------------------

readonly TESTNET_CHAIN_ID="2017"
readonly TESTNET_CHAIN_NAME="adiri"
readonly TESTNET_RPC_URL="https://rpc.telcoin.network"
readonly TESTNET_EXPLORER="https://scan.telcoin.network"

readonly MAINNET_CHAIN_ID="2017"
readonly MAINNET_CHAIN_NAME="telcoin"
readonly MAINNET_RPC_URL="https://rpc.telcoin.network"
readonly MAINNET_EXPLORER="https://scan.telcoin.network"

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
readonly COMMON_VERSION="1.4.0"

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

# Minimum source version offered by the source-build picker. Older tags exist
# in the upstream repo but represent obsolete releases we don't want operators
# installing by accident. main and custom-ref are still always available.
# Bump this when the Telcoin team retires a baseline.
readonly MIN_SOURCE_VERSION_TESTNET="0.12.0"
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
    local response
    echo ""
    read -r -p "  ?  $prompt [y/N]: " response
    echo ""
    [[ "${response,,}" =~ ^y ]]
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
TN_UPDATE_LOCK_HOLDER=""
tn_acquire_update_lock() {
    TN_UPDATE_LOCK_HOLDER=""
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
        # Expand lock_dir now, not at exit time (intentional).
        # shellcheck disable=SC2064
        trap "rm -rf '${lock_dir}'" EXIT
        return 0
    fi
    TN_UPDATE_LOCK_HOLDER="$(cat "${lock_dir}/pid" 2>/dev/null || true)"
    if [[ -n "$TN_UPDATE_LOCK_HOLDER" ]] && ! kill -0 "$TN_UPDATE_LOCK_HOLDER" 2>/dev/null; then
        rm -rf "$lock_dir" 2>/dev/null
        if mkdir "$lock_dir" 2>/dev/null; then
            TN_UPDATE_LOCK_HOLDER=""
            printf '%s\n' "$$" > "${lock_dir}/pid" 2>/dev/null || true
            # Expand lock_dir now, not at exit time (intentional).
            # shellcheck disable=SC2064
            trap "rm -rf '${lock_dir}'" EXIT
            return 0
        fi
    fi
    print_error "Another update is already running${TN_UPDATE_LOCK_HOLDER:+ (PID ${TN_UPDATE_LOCK_HOLDER})}."
    print_info "Wait for it to finish. Stale lock cleanup: rm -rf ${lock_dir}"
    return 1
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

# _tn_hw_role <label> <min_cpu> <min_ram_gb> <min_disk_gb> <cpu> <ram_kb> <disk_kb>
# — print one line for a role tier. Empty cpu/ram_kb/disk_kb mean "could not
# measure" and never count as a shortfall. rc 1 when a measured value is below the
# tier, else 0. RAM and disk get 5 % slack: a "16 GB" box reports ~15.6 GiB and a
# formatted "2 TB" disk a little under 2000 GB.
_tn_hw_role() {
    local label="$1" min_cpu="$2" min_ram="$3" min_disk="$4" cpu="$5" ram_kb="$6" disk_kb="$7"
    local spec need have unknown
    spec="${min_cpu} cores / ${min_ram} GB / $(_tn_hw_disk_label "$min_disk")"
    need=""
    have=""
    unknown=""
    if [[ -z "$cpu" ]]; then
        unknown="CPU"
    elif [[ "$cpu" -lt "$min_cpu" ]]; then
        need="${min_cpu} cores"
        have="${cpu} CPUs"
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
#   * CPU: nproc, then getconf _NPROCESSORS_ONLN. Both count LOGICAL CPUs while the
#     tiers are physical cores, so a hyperthreaded box can look up to twice its
#     real size. That risk is noted here, not corrected.
#   * RAM: MemTotal from ${TN_PROC_MEMINFO:-/proc/meminfo} (a harness can point it
#     at a fixture), shown rounded to whole GiB.
#   * Disk: TOTAL size of that filesystem (not free space) from POSIX `df -Pk`, in
#     decimal GB as disks are sold. Free space is reported too, with a warning at
#     90 % used or more.
# Sets TN_HW_SUMMARY (the "Detected" text) and TN_HW_GAPS (comma-separated roles
# below minimum, from node, rpc, validator; empty when all pass), both plain ASCII.
check_hardware() {
    local data_dir="${2:-/}"
    local meminfo cpu ram_kb ram_gb check_path df_line disk_kb disk_avail_kb disk_pct
    local mount_point disk_gb disk_free_gb cpu_txt ram_txt disk_txt gaps
    TN_HW_SUMMARY=""
    TN_HW_GAPS=""
    print_step "Checking hardware..."

    cpu=""
    if command -v nproc >/dev/null 2>&1; then
        cpu="$(nproc 2>/dev/null || true)"
    fi
    if [[ ! "$cpu" =~ ^[1-9][0-9]*$ ]] && command -v getconf >/dev/null 2>&1; then
        cpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    fi
    [[ "$cpu" =~ ^[1-9][0-9]*$ ]] || cpu=""

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

    if [[ -n "$cpu" ]]; then cpu_txt="${cpu} CPUs"; else cpu_txt="unknown CPUs"; fi
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
    if [[ -n "$disk_pct" ]] && [[ "$disk_pct" -ge 90 ]]; then
        print_warn "Disk ${mount_point} is ${disk_pct}% used (${disk_free_gb:-?} GB free)."
    fi

    gaps=""
    if ! _tn_hw_role "Full node (follower)" "$HW_NODE_MIN_CPU" "$HW_NODE_MIN_RAM_GB" "$HW_NODE_MIN_DISK_GB" \
        "$cpu" "$ram_kb" "$disk_kb"; then
        gaps="node"
    fi
    if ! _tn_hw_role "Public RPC node" "$HW_RPC_MIN_CPU" "$HW_RPC_MIN_RAM_GB" "$HW_RPC_MIN_DISK_GB" \
        "$cpu" "$ram_kb" "$disk_kb"; then
        gaps="${gaps:+${gaps},}rpc"
    fi
    if ! _tn_hw_role "Validator (minimum)" "$HW_VAL_MIN_CPU" "$HW_VAL_MIN_RAM_GB" "$HW_VAL_MIN_DISK_GB" \
        "$cpu" "$ram_kb" "$disk_kb"; then
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
# Function selector for getValidator(address):
# keccak256("getValidator(address)") = 0x1904bb2e
readonly GET_VALIDATOR_SELECTOR="0x1904bb2e"

# node_stake_status <address> [rpc_url] — the single getValidator(address) probe.
# Prints exactly ONE line on stdout and nothing else (no print_* output):
#   "<status> <activation_epoch> <is_retired>"   rc 0   e.g. "3 12 0"
#   "none"                                        rc 0   the call reverted: no ConsensusNFT
#   "unknown"                                     rc 1   address empty or malformed
#   "unknown"                                     rc 2   curl failed, empty body, a non-revert
#                                                        RPC error (rate limit, method not
#                                                        found, ...), or a missing/short/
#                                                        non-hex result
# status is the ValidatorStatus enum above in decimal; is_retired is 0 or 1.
# rpc_url defaults to the local node (http://127.0.0.1:8545).
#
# The ValidatorInfo struct is ABI-encoded INLINE in the response. It carries no
# dynamic fields (blsPubkey is not part of the returned struct), so there is NO
# leading offset pointer -- every field sits at a fixed word index. Each field
# is 32 bytes / 64 hex chars, so word N starts at hex offset 64*N:
#   word 0 = validatorAddress (offset 0)
#   word 1 = activationEpoch  (offset 64)    uint32: low 8 hex chars at 120
#   word 2 = exitEpoch        (offset 128)
#   word 3 = currentStatus    (offset 192)   uint8 enum: decoded from 240..255
#   word 4 = isRetired        (offset 256)   bool: low byte at 318..319
#   word 5 = stakeVersion     (offset 320)
#   word 6 = region           (offset 384)
# Only the low bits of each word are decoded, so a 64-hex word can never
# overflow bash arithmetic.
node_stake_status() {
    local address="${1:-}" rpc_url="${2:-http://127.0.0.1:8545}"
    local call_data response result hex status_hex epoch_hex retired_hex
    local status epoch retired error_re revert_msg_re revert_code_re result_re hex_re
    error_re='"error"[[:space:]]*:[[:space:]]*[{]'
    revert_msg_re='[Rr]evert'
    revert_code_re='"code"[[:space:]]*:[[:space:]]*3([^0-9]|$)'
    result_re='"result"[[:space:]]*:[[:space:]]*"(0x[0-9a-fA-F]*)"'
    hex_re='^[0-9a-fA-F]+$'

    if [[ -z "$address" ]] || [[ ! "$address" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        printf '%s\n' "unknown"
        return 1
    fi

    # ABI-encode the call: selector + address left-padded to a 32-byte word.
    call_data="${GET_VALIDATOR_SELECTOR}000000000000000000000000${address:2}"
    response="$(curl -s --max-time 10 \
        -X POST \
        -H "Content-Type: application/json" \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"${CONSENSUS_REGISTRY}\",\"data\":\"${call_data}\"},\"latest\"],\"id\":1}" \
        "$rpc_url" 2>/dev/null || true)"

    if [[ -z "$response" ]]; then
        printf '%s\n' "unknown"
        return 2
    fi

    # getValidator reverts for an address that holds no ConsensusNFT. reth reports
    # an execution revert as error code 3 ("execution reverted"). Any other error
    # (rate limit, method not found, ...) says nothing about the address. Only an
    # error OBJECT counts, so a proxy that adds "error":null to a result is fine.
    if [[ "$response" =~ $error_re ]]; then
        if [[ "$response" =~ $revert_msg_re ]] || [[ "$response" =~ $revert_code_re ]]; then
            printf '%s\n' "none"
            return 0
        fi
        printf '%s\n' "unknown"
        return 2
    fi

    result=""
    if [[ "$response" =~ $result_re ]]; then
        result="${BASH_REMATCH[1]}"
    fi
    hex="${result#0x}"
    if [[ ${#hex} -lt 448 ]]; then
        printf '%s\n' "unknown"
        return 2
    fi

    status_hex="${hex:240:16}"
    epoch_hex="${hex:120:8}"
    retired_hex="${hex:318:2}"
    if [[ ! "$status_hex" =~ $hex_re ]] || [[ ! "$epoch_hex" =~ $hex_re ]] \
        || [[ ! "$retired_hex" =~ $hex_re ]]; then
        printf '%s\n' "unknown"
        return 2
    fi
    status=$(( 16#${status_hex} ))
    epoch=$(( 16#${epoch_hex} ))
    retired=$(( 16#${retired_hex} ))
    if [[ "$retired" -ne 0 ]]; then
        retired=1
    fi
    printf '%s %s %s\n' "$status" "$epoch" "$retired"
    return 0
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

# print_validator_onchain_status <address> <result-line> [is_retired 0|1] — render
# the operator-facing report for a node_stake_status result line ("<status>
# <activation_epoch> <is_retired>" or "none"). This is the single copy of the
# status label table and the "Next step" text. The optional third argument
# overrides the is_retired field of the line. Callers (check-node.sh,
# update-node.sh) grep the "Status: <label>" and "No validator record found"
# strings, so keep those labels stable. Returns 1 (after a warning) when the
# line is not a decoded result.
print_validator_onchain_status() {
    local validator_address="${1:-}" line="${2:-}" retired_arg="${3:-}"
    local status epoch retired status_label next_step
    status=""
    epoch=""
    retired=""
    read -r status epoch retired _ <<<"$line" || true

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
            next_step="Your validator has exited. You can now call unstake() to reclaim your TEL stake."
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
# report for an address. Returns 1 for a malformed address or an unreadable
# status, 0 when a report (including "No validator record found") was printed.
check_validator_onchain_status() {
    local validator_address="${1:-}" rpc_url="${2:-http://127.0.0.1:8545}"
    local out rc

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
        print_warn "Empty response from contract -- node may still be syncing or NFT not yet minted."
        return 1
    fi
    print_validator_onchain_status "$validator_address" "$out" || true
    return 0
}

# Display the contents of node-info.yaml after key generation
display_node_info() {
    local data_dir="$1"
    local validator_address="$2"
    local node_info_file="${data_dir}/node-info.yaml"
    local export_cmd node_info_arg

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
    echo "    cast call ${CONSENSUS_REGISTRY} \\"
    echo "      \"getCurrentStakeConfig()\" \\"
    echo "      --rpc-url <RPC_URL>"
    echo ""
    echo "  Step 4: On this node, export the stake(bytes,(bytes)) calldata (reads only node-info.yaml)"
    if [[ "${INSTALL_METHOD:-}" == "docker" ]]; then
        export_cmd="docker run --rm -v ${data_dir}:/home/nonroot/data:ro ${DOCKER_IMAGE:-<IMAGE>} telcoin keytool"; node_info_arg="/home/nonroot/data/node-info.yaml"
    else
        export_cmd="${BINARY_PATH:-telcoin-network} keytool"; node_info_arg="$node_info_file"
    fi
    echo "    ${export_cmd} export-staking-args \\"
    echo "      --node-info ${node_info_arg} --calldata"
    echo ""
    echo "  Step 5: From the machine holding your validator wallet, submit the stake"
    echo "    cast send ${CONSENSUS_REGISTRY} <CALLDATA_FROM_STEP_4> \\"
    echo "      --value <STAKE_AMOUNT_FROM_STEP_3> --from ${validator_address} \\"
    echo "      --ledger --rpc-url <RPC_URL>"
    echo "    (Use --trezor or --interactive instead of --ledger to match your wallet.)"
    echo ""
    echo "  Step 6: Wait for node to sync, then activate"
    echo "    cast send ${CONSENSUS_REGISTRY} \"activate()\" \\"
    echo "      --from ${validator_address} --ledger --rpc-url <RPC_URL>"
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
meta_set() {
    local key="$1" val="$2" file="${3:-}"
    [[ -n "$file" ]] || file="$(node_meta_path || true)"
    if [[ -z "$file" ]]; then
        print_warn "meta_set: no .node-meta found; cannot persist ${key}"
        return 1
    fi
    mkdir -p "$(dirname "$file")"
    [[ -f "$file" ]] || { : > "$file"; chmod 600 "$file"; }
    local tmp; tmp="$(mktemp)"
    grep -vE "^${key}=" "$file" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
    chmod 600 "$file" 2>/dev/null || true
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

# tn_node_inject_flags <file> <marker> <flags> — idempotently append <flags> onto the
# node-launch --http line (matched as a whole word, so --http.addr etc. are untouched)
# when <marker> is absent. awk avoids sed metachar pitfalls with the slashes in the
# flag paths. Returns 0 if it changed the file, 1 if already present / line not found.
# The caller is responsible for daemon-reload (docker) and restart.
tn_node_inject_flags() {
    local file="$1" marker="$2" flags="$3" tmp
    [[ -f "$file" ]] || return 1
    grep -q -- "$marker" "$file" 2>/dev/null && return 1
    tmp="$(mktemp)"
    awk -v flags="$flags" '
        !done && $0 ~ /(^|[[:space:]])--http([[:space:]]|$)/ { print $0 " " flags; done=1; next }
        { print }
    ' "$file" > "$tmp"
    if grep -q -- "$marker" "$tmp"; then cat "$tmp" > "$file"; rm -f "$tmp"; return 0; fi
    rm -f "$tmp"; return 1
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
