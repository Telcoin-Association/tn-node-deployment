#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — Shared helper functions for Telcoin node setup scripts
# =============================================================================

set -euo pipefail

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

readonly DEFAULT_P2P_PORT="49590"
readonly DEFAULT_WORKER_PORT="49594"
readonly DEFAULT_RPC_PORT="8545"
readonly DEFAULT_METRICS_PORT="9000"
readonly COMMON_VERSION="1.1.36"

# Validator node hardware requirements (official Telcoin Association specs)
readonly VALIDATOR_MIN_RAM_GB=128
readonly VALIDATOR_MIN_DISK_GB=4000
readonly VALIDATOR_MIN_CPU_CORES=16

# Observer node hardware requirements (official Telcoin Association specs)
readonly OBSERVER_MIN_RAM_GB=16
readonly OBSERVER_MIN_DISK_GB=500
readonly OBSERVER_MIN_CPU_CORES=8

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

check_hardware() {
    local node_type="${1:-validator}"
    print_step "Checking hardware requirements for ${node_type} node..."

    # Select thresholds based on node type
    local min_ram min_disk min_cpu
    if [[ "$node_type" == "observer" ]]; then
        min_ram=$OBSERVER_MIN_RAM_GB
        min_disk=$OBSERVER_MIN_DISK_GB
        min_cpu=$OBSERVER_MIN_CPU_CORES
    else
        min_ram=$VALIDATOR_MIN_RAM_GB
        min_disk=$VALIDATOR_MIN_DISK_GB
        min_cpu=$VALIDATOR_MIN_CPU_CORES
    fi

    local ram_kb ram_gb
    ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    ram_gb=$(( ram_kb / 1024 / 1024 ))
    if [[ $ram_gb -lt $min_ram ]]; then
        print_warn "RAM: ${ram_gb}GB detected, ${min_ram}GB recommended."
    else
        print_ok "RAM: ${ram_gb}GB"
    fi

    local cpu_cores
    cpu_cores=$(nproc)
    if [[ $cpu_cores -lt $min_cpu ]]; then
        print_warn "CPU cores: ${cpu_cores} detected, ${min_cpu} recommended."
    else
        print_ok "CPU cores: ${cpu_cores}"
    fi

    local disk_avail_gb
    disk_avail_gb=$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')
    if [[ $disk_avail_gb -lt $min_disk ]]; then
        print_warn "Disk: ${disk_avail_gb}GB available, ${min_disk}GB recommended."
    else
        print_ok "Disk: ${disk_avail_gb}GB available"
    fi
}

check_ports() {
    print_step "Checking required ports are available..."
    local ports=("$@")
    for port in "${ports[@]}"; do
        if ss -tlnp | grep -q ":${port} "; then
            print_warn "Port ${port} is already in use."
        else
            print_ok "Port ${port} is available"
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

ensure_chain_configs_available() {
    print_step "Ensuring chain-config files are available..."

    local source_dir="/opt/telcoin-source"
    TN_SOURCE_DIR="$source_dir"

    if [[ -d "${source_dir}/.git" ]]; then
        print_info "Repository already present -- pulling latest..."
        git -C "$source_dir" pull --ff-only 2>/dev/null && \
            print_ok "Repository up to date" || \
            print_warn "Could not pull latest. Using existing files."
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
#   6 = Any        (retired)
#
# ConsensusRegistry address (from tn-contracts/deployments/deployments.json):
readonly CONSENSUS_REGISTRY="0x07e17e17e17e17e17e17e17e17e17e17e17e17e1"
#
# Function selector for getValidator(address):
# keccak256("getValidator(address)") = 0x1904bb2e
readonly GET_VALIDATOR_SELECTOR="0x1904bb2e"

check_validator_onchain_status() {
    local validator_address="$1"
    local rpc_url="${2:-http://127.0.0.1:8545}"

    print_step "Checking validator on-chain status..."
    print_info "Address:  ${validator_address}"
    print_info "Contract: ${CONSENSUS_REGISTRY}"
    echo ""

    if [[ -z "$validator_address" ]] || [[ ! "$validator_address" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        print_warn "Invalid validator address -- skipping on-chain check."
        return 1
    fi

    # ABI-encode the call: selector + address padded to 32 bytes
    # Address is right-aligned in a 32-byte word, left-padded with zeros
    local padded_address
    padded_address="000000000000000000000000${validator_address:2}"
    local call_data="${GET_VALIDATOR_SELECTOR}${padded_address}"

    # Make the eth_call
    local response
    response=$(curl -s --max-time 10 \
        -X POST \
        -H "Content-Type: application/json" \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"${CONSENSUS_REGISTRY}\",\"data\":\"${call_data}\"},\"latest\"],\"id\":1}" \
        "$rpc_url" 2>/dev/null || echo "")

    # Check if the call returned an error (validator doesn't exist / no NFT)
    if echo "$response" | grep -q '"error"'; then
        print_warn "No validator record found for ${validator_address}"
        print_info "This means no ConsensusNFT has been minted for this address yet."
        echo ""
        print_info "Next step:"
        echo "    Submit your ECDSA validator address to the Telcoin Association"
        echo "    for governance approval: ${validator_address}"
        echo "    Once approved, governance will mint a ConsensusNFT to your address."
        return 0
    fi

    # Extract the result hex string
    local result
    result=$(echo "$response" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)

    if [[ -z "$result" ]] || [[ "$result" == "0x" ]]; then
        print_warn "Empty response from contract -- node may still be syncing or NFT not yet minted."
        return 1
    fi

    # The ValidatorInfo struct is ABI-encoded in the response.
    # The currentStatus field is at a fixed offset in the struct.
    # Struct layout (each field is 32 bytes):
    #   [0]   blsPubkey (dynamic, offset pointer)
    #   [1]   validatorAddress
    #   [2]   activationEpoch
    #   [3]   exitEpoch
    #   [4]   currentStatus  <-- this is what we want
    #   [5]   isRetired
    #   [6]   isDelegated
    #   [7]   stakeVersion
    #
    # Strip 0x prefix, then each 32-byte word is 64 hex chars
    local hex="${result#0x}"

    # currentStatus is at word index 4 (0-indexed), so offset = 4 * 64 = 256 chars
    # But first word is a dynamic type offset pointer, so we need to be careful.
    # The first word is the offset to blsPubkey bytes data.
    # Static fields start at word 1:
    #   word 1 = validatorAddress (offset 64)
    #   word 2 = activationEpoch  (offset 128)
    #   word 3 = exitEpoch        (offset 192)
    #   word 4 = currentStatus    (offset 256)
    local status_hex="${hex:256:64}"
    local status_dec=$(( 16#${status_hex} ))

    # Also extract activationEpoch for display (word 2, offset 128)
    local activation_hex="${hex:128:64}"
    local activation_epoch=$(( 16#${activation_hex} ))

    # Decode status to human readable
    local status_label status_colour next_step
    case $status_dec in
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
            next_step="Activation is in progress. You will become Active at epoch ${activation_epoch}. No action needed."
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
            status_label="Retired"
            next_step="This validator has been permanently retired."
            ;;
        *)
            status_label="Unknown (status code: ${status_dec})"
            next_step="Contact the Telcoin Association for assistance."
            ;;
    esac

    # Display results
    if [[ $status_dec -eq 3 ]]; then
        print_ok "ConsensusNFT: Found"
        print_ok "Status: ${status_label}"
    elif [[ $status_dec -eq 0 ]] || [[ $status_dec -eq 1 ]] || [[ $status_dec -eq 2 ]]; then
        print_ok "ConsensusNFT: Found"
        print_warn "Status: ${status_label}"
    else
        print_warn "Status: ${status_label}"
    fi

    echo ""
    print_info "Next step:"
    echo "    ${next_step}"
    echo ""
}

# Display the contents of node-info.yaml after key generation
display_node_info() {
    local data_dir="$1"
    local validator_address="$2"
    local node_info_file="${data_dir}/node-info.yaml"

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
    echo "  Step 4: Submit stake transaction"
    echo "    Read your BLS public key and proof of possession from node-info.yaml above"
    echo "    cast send ${CONSENSUS_REGISTRY} \\"
    echo "      \"stake(bytes,(bytes,bytes))\" \\"
    echo "      <BLS_PUBKEY_COMPRESSED> \\"
    echo "      \"(<UNCOMPRESSED_PUBKEY>,<UNCOMPRESSED_SIGNATURE>)\" \\"
    echo "      --value <STAKE_AMOUNT> \\"
    echo "      --trezor \\"
    echo "      --rpc-url <RPC_URL>"
    echo ""
    echo "  Step 5: Wait for node to sync, then activate"
    echo "    cast send ${CONSENSUS_REGISTRY} \\"
    echo "      \"activate()\" \\"
    echo "      --trezor \\"
    echo "      --rpc-url <RPC_URL>"
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

    # Pick the suffix and label for the operator's network.
    local suffix="" net_label=""
    case "$network" in
        testnet) suffix="$NETWORK_TAG_SUFFIX_TESTNET"; net_label="testnet (adiri)" ;;
        mainnet) suffix="$NETWORK_TAG_SUFFIX_MAINNET"; net_label="mainnet" ;;
        devnet)  suffix="";  net_label="devnet (follows main)" ;;
        *)       suffix="";  net_label="unknown -- no tag filter" ;;
    esac

    print_step "Fetching latest refs from origin..." >&2
    if ! git -C "$TN_SOURCE_DIR" fetch --tags --quiet 2>/dev/null; then
        print_warn "git fetch failed -- showing cached refs only" >&2
    fi

    local current_ref
    current_ref=$(git -C "$TN_SOURCE_DIR" describe --tags --always --dirty 2>/dev/null || echo "unknown")

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

    echo "" >&2
    print_info "Network:              ${net_label}" >&2
    print_info "Current source ref:   ${current_ref}" >&2
    if [[ ${#tags[@]} -gt 0 ]]; then
        local latest_tag="${tags[0]}"
        if [[ "$current_ref" == *"$latest_tag"* ]]; then
            print_ok  "You are on the latest ${network:-applicable} tag (${latest_tag})." >&2
        else
            print_info "Latest matching tag:  ${latest_tag}  (recommended for ${network:-this network})" >&2
        fi
    fi
    echo "" >&2

    print_info "Available versions to build:" >&2
    local i=1
    for tag in "${tags[@]}"; do
        local marker=""
        [[ "$current_ref" == *"$tag"* ]] && marker="  <-- current"
        [[ $i -eq 1 ]] && [[ -z "$marker" ]] && marker="  <-- recommended (latest ${network:-tag})"
        printf "  %2d) %s%s\n" "$i" "$tag" "$marker" >&2
        (( ++i ))
    done
    local tag_count=$(( i - 1 ))

    local main_label="main (bleeding-edge dev branch"
    [[ "$network" == "devnet" ]] && main_label="main (recommended for devnet"
    main_label="${main_label})"

    local main_opt=$i;   printf "  %2d) %s\n"                                 "$main_opt" "$main_label" >&2; (( ++i ))
    local custom_opt=$i; printf "  %2d) Custom branch / tag / commit hash\n"  "$custom_opt" >&2; (( ++i ))
    local cancel_opt=$i; printf "  %2d) Cancel\n"                              "$cancel_opt" >&2
    echo "" >&2

    local choice
    read -r -p "  Select [1-${cancel_opt}] (default 1): " choice >&2
    # Empty input -> select the recommended (1)
    [[ -z "$choice" ]] && choice=1

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
    if (( choice >= 1 && choice <= tag_count )); then
        echo "${tags[$((choice - 1))]}"
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
