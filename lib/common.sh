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
readonly SERVICE_USER="telcoin"

readonly TN_REPO="https://github.com/Telcoin-Association/telcoin-network.git"
readonly MIN_RUST_VERSION="1.75.0"

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
        (( attempt++ ))
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
    print_step "Creating service user: ${SERVICE_USER}..."
    if id "$SERVICE_USER" &>/dev/null; then
        print_ok "User '${SERVICE_USER}' already exists"
    else
        useradd --system --no-create-home --shell /bin/false \
                --comment "Telcoin Network node service account" "$SERVICE_USER"
        print_ok "Created system user '${SERVICE_USER}'"
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
        chown -R "${SERVICE_USER}:${SERVICE_USER}" "$dir"
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
    echo "  2) Pre-built binary   -- downloads a release binary"
    echo "  3) Docker             -- pulls the official Docker image"
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
Group=${SERVICE_USER}
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
