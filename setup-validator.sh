#!/usr/bin/env bash
# =============================================================================
# setup-validator.sh -- Telcoin Network Validator Node Setup
#
# USAGE:
#   sudo bash setup-validator.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

readonly SCRIPT_VERSION="1.2.20"
readonly SERVICE_NAME="telcoin-validator"
readonly NODE_TYPE="validator"

NETWORK=""
CHAIN_ID=""
CHAIN_NAME=""
RPC_URL=""
EXPLORER_URL=""
INSTALL_METHOD=""
BINARY_PATH=""
DATA_DIR="$DEFAULT_DATA_DIR/validator"
CONFIG_DIR="$DEFAULT_CONFIG_DIR/validator"
LOG_DIR="$DEFAULT_LOG_DIR"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
VALIDATOR_ADDRESS=""
ADVERTISED_NAME=""
PUBLIC_IP=""
PRIMARY_MULTIADDR=""
WORKER_MULTIADDR=""
PRIMARY_LISTENER_MULTIADDR=""
WORKER_LISTENER_MULTIADDR=""
P2P_PORT="$DEFAULT_P2P_PORT"
WORKER_PORT="$DEFAULT_WORKER_PORT"
RPC_PORT="$DEFAULT_RPC_PORT"
METRICS_PORT="$DEFAULT_METRICS_PORT"
USE_LOAD_CREDENTIAL=false
PASSPHRASE_METHOD="loadcredential"  # loadcredential | tpm

# Testnet opt-in add-ons (see lib/common.sh / docs/testnet-addons.md). OFF by default;
# set by prompt_testnet_addons (interactive testnet only) and persisted to .node-meta.
ENABLE_HEALTHCHECK_MONITOR="false"
ENABLE_OBSERVABILITY="false"   # log shipping (Alloy -> Loki)
ENABLE_METRICS="false"         # metrics shipping (Alloy -> Prometheus); independent of logs
ENABLE_VPN="false"          # true | pending | false
VPN_OVERLAY_IP=""
VPN_NODE_PUBKEY=""
REGION=""

# =============================================================================
# STEPS
# =============================================================================

step_welcome() {
    clear
    echo ""
    echo "${BLUE}${BOLD}  ████████╗███████╗██╗      ██████╗ ██████╗ ██╗███╗   ██╗"
    echo "     ██╔══╝██╔════╝██║     ██╔════╝██╔═══██╗██║████╗  ██║"
    echo "     ██║   █████╗  ██║     ██║     ██║   ██║██║██╔██╗ ██║"
    echo "     ██║   ██╔══╝  ██║     ██║     ██║   ██║██║██║╚██╗██║"
    echo "     ██║   ███████╗███████╗╚██████╗╚██████╔╝██║██║ ╚████║"
    echo "     ╚═╝   ╚══════╝╚══════╝ ╚═════╝ ╚═════╝ ╚═╝╚═╝  ╚═══╝"
    echo "  ███╗   ██╗███████╗████████╗██╗    ██╗ ██████╗ ██████╗ ██╗  ██╗"
    echo "  ████╗  ██║██╔════╝╚══██╔══╝██║    ██║██╔═══██╗██╔══██╗██║ ██╔╝"
    echo "  ██╔██╗ ██║█████╗     ██║   ██║ █╗ ██║██║   ██║██████╔╝█████╔╝ "
    echo "  ██║╚██╗██║██╔══╝     ██║   ██║███╗██║██║   ██║██╔══██╗██╔═██╗ "
    echo "  ██║ ╚████║███████╗   ██║   ╚███╔███╔╝╚██████╔╝██║  ██║██║  ██╗"
    echo "  ╚═╝  ╚═══╝╚══════╝   ╚═╝    ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝${RESET}"
    echo ""
    echo "  ${BOLD}Telcoin Network -- Validator Node Setup  v${SCRIPT_VERSION}${RESET}"
    echo ""
    print_sep
    echo ""
    print_info "This script will set up a VALIDATOR node on the Telcoin Network."
    print_info "Prerequisites:"
    echo "    * GSMA MNO operators only -- validators must be GSMA-approved MNOs"
    echo "    * You have received validator approval from the Telcoin Association"
    echo "    * You have submitted hardware specs to grant@telcoin.org for approval"
    echo "    * You have a dedicated server meeting the minimum hardware requirements"
    echo "    * You are running this script as root (sudo)"
    echo ""
    print_warn "If you have not yet submitted your hardware specifications for approval"
    print_warn "please contact grant@telcoin.org before proceeding."
    echo ""
    print_sep
    echo ""

    if ! confirm "Ready to begin validator node setup?"; then
        print_info "Setup cancelled."
        exit 0
    fi
}

step_preflight() {
    print_header "Step 1 of 8: Pre-flight Checks"
    check_root
    detect_distro
    check_cve_2026_31431

    # Pick where node data lives BEFORE the disk check, so the check lands on the
    # right drive (a separate data mount, not the boot disk). Interactive only;
    # JSON/UI installs pre-set DATA_DIR via --data-dir (or use the default).
    if ! json_mode; then
        print_step "Available storage (mounted filesystems, largest first)..."
        echo ""
        # Filter on the real fstype column (not a path grep), drop pseudo/boot
        # mounts and sub-GB noise, and sort by free space so the biggest data
        # drive is listed first. Any real drive (ext4/xfs/zfs at /mnt, /data, ...)
        # is shown -- only pseudo filesystems are hidden.
        df -BG --output=fstype,target,avail,size 2>/dev/null \
            | awk 'NR>1 && ($3+0) >= 1 \
                   && $1 !~ /^(tmpfs|devtmpfs|udev|squashfs|overlay|efivarfs|vfat)$/ \
                   && $2 !~ /^\/boot/ { print ($3+0), $2, ($4+0) }' \
            | sort -rn \
            | awk '{printf "    %-28s %dG available / %dG total\n", $2, $1, $3}'
        echo ""
        # df only lists MOUNTED filesystems, so a data drive that hasn't been
        # mounted yet is invisible above. Show physical disks too (incl. unmounted).
        if command -v lsblk >/dev/null 2>&1; then
            print_info "Physical disks (a disk with no MOUNTPOINT is not mounted yet):"
            lsblk -e7 -o NAME,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null | sed 's/^/    /'
            echo ""
            print_info "If your data drive shows no MOUNTPOINT, mount it (and add it to"
            print_info "/etc/fstab) before pointing the node at it."
            echo ""
        fi
        print_step "Selecting data directory..."
        print_info "Where should node data be stored? If it's on a separate drive"
        print_info "(e.g. /mnt/data) enter the full path. Press Enter for the default."
        local input
        read -r -p "  Data directory [${DATA_DIR}]: " input
        DATA_DIR="${input:-$DATA_DIR}"
        print_ok "Data directory: ${DATA_DIR}"
    fi
    mkdir -p "$DATA_DIR" 2>/dev/null || true

    check_hardware "validator" "$DATA_DIR"
    check_internet
    # Core node ports + the ports the optional features use (Caddy dashboard 80/443,
    # WireGuard VPN 51820, health monitor 43174) so conflicts surface up front.
    check_ports \
        "${P2P_PORT}/udp:P2P primary" \
        "${WORKER_PORT}/udp:P2P worker" \
        "${RPC_PORT}/tcp:RPC" \
        "${METRICS_PORT}/tcp:Metrics (loopback, only if metrics enabled)" \
        "80/tcp:Caddy HTTP (optional dashboard)" \
        "443/tcp:Caddy HTTPS (optional dashboard)" \
        "51820/udp:WireGuard VPN (optional)" \
        "43174/tcp:Health monitor (optional)"

    for tool in curl git; do
        if command_exists "$tool"; then
            print_ok "${tool} is installed"
        else
            install_package "$tool"
        fi
    done

    # Check systemd version -- LoadCredential requires 247+ (Ubuntu 22.04+)
    print_step "Checking systemd version..."
    local systemd_ver
    systemd_ver=$(systemctl --version 2>/dev/null | head -1 | awk '{print $2}')
    if [[ -z "$systemd_ver" ]] || [[ "$systemd_ver" -lt 247 ]]; then
        print_error "systemd ${systemd_ver:-unknown} detected -- version 247+ required."
        print_info "Please upgrade to Ubuntu 22.04 LTS or later and try again."
        exit 1
    fi
    print_ok "systemd ${systemd_ver} detected (247+ required)"
    USE_LOAD_CREDENTIAL=true

    # Select network first so NETWORK is set before source build (needed for --features adiri).
    # In JSON mode network/method/passphrase are already set from flags by the orchestrator.
    echo ""
    print_step "Selecting network..."
    json_mode || select_network

    # Testnet opt-in add-ons: ask now ("ask early") so step_create_service can bake the
    # right node-launch flags on the first pass. Side-effect installs run later in
    # step_testnet_addons ("act late"). No-op off testnet / in JSON mode.
    json_mode || prompt_testnet_addons

    echo ""
    print_step "Selecting install method..."
    json_mode || _select_install_method_with_guard

    case "$INSTALL_METHOD" in
        source)   _preflight_source ;;
        docker)   _preflight_docker ;;
        existing) _preflight_existing ;;
    esac

    if [[ "$INSTALL_METHOD" != "docker" ]] && ! json_mode; then
        _select_passphrase_method
    fi

    print_ok "Pre-flight checks complete"
}

_select_install_method_with_guard() {
    while true; do
        select_install_method
        case "$INSTALL_METHOD" in
            binary)
                echo ""
                print_warn "Pre-built binary downloads are coming soon."
                print_info "Official releases will be available at:"
                print_info "  https://github.com/Telcoin-Association/tn-node-deployment/releases"
                print_warn "This option is not yet available -- please choose another method."
                echo ""
                read -r -p "  Press Enter to return to the install method menu..."
                echo ""
                ;;
            *) break ;;
        esac
    done
}

_select_passphrase_method() {
    echo ""
    print_header "BLS Passphrase Protection"
    echo "  How would you like to protect the BLS passphrase?"
    echo ""
    echo "  1) systemd LoadCredential (default -- recommended for most operators)"
    echo "       Passphrase secured by systemd. Never appears in process listings."
    echo "       Works on any Ubuntu 22.04+ server. Easy to recover."
    echo ""
    echo "  2) TPM/vTPM sealing (advanced -- maximum security)"
    echo "       Passphrase sealed to this machine's TPM chip."
    echo "       Cannot be decrypted on any other machine, even with root access."
    echo "       Requires TPM2 chip (GCP Shielded VM, AWS Nitro, or bare metal TPM2)."
    echo "       Recovery requires your offline backup passphrase."
    echo ""

    local choice
    while true; do
        read -r -p "  Enter choice [1/2]: " choice
        case "$choice" in
            1)
                PASSPHRASE_METHOD="loadcredential"
                print_ok "Passphrase method: systemd LoadCredential"
                break
                ;;
            2)
                if tpm_check_available; then
                    PASSPHRASE_METHOD="tpm"
                    print_ok "Passphrase method: TPM sealing"
                    print_warn "You will need to store your passphrase securely offline."
                else
                    print_error "No TPM2 chip detected on this system."
                    print_info "TPM sealing requires /dev/tpm0 or /dev/tpmrm0."
                    print_info "Falling back to systemd LoadCredential."
                    PASSPHRASE_METHOD="loadcredential"
                fi
                break
                ;;
            *) print_warn "Please enter 1 or 2." ;;
        esac
    done
}

_preflight_source() {
    print_step "Installing source build dependencies..."

    if ! check_rust; then
        print_info "Installing Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
        export PATH="${HOME}/.cargo/bin:${PATH}"
        source "${HOME}/.cargo/env" 2>/dev/null || true
        if ! check_rust; then
            print_error "Rust installation failed. Cannot continue."
            exit 1
        fi
    fi

    export PATH="${HOME}/.cargo/bin:/root/.cargo/bin:${PATH}"
    source "${HOME}/.cargo/env" 2>/dev/null || true

    local build_deps=("build-essential" "cmake" "clang" "libclang-dev" "libclang-16-dev" "pkg-config" "libssl-dev" "libapr1-dev")
    local missing_deps=()
    for _dep in "${build_deps[@]}"; do
        if ! dpkg -l "$_dep" 2>/dev/null | grep -q "^ii"; then
            missing_deps+=("$_dep")
        fi
    done
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_warn "Missing build dependencies: ${missing_deps[*]}"
        if json_mode || confirm "Install missing packages now?"; then
            update_package_index
            for _dep in "${missing_deps[@]}"; do
                install_package "$_dep"
            done
        else
            print_error "Required build dependencies not installed. Cannot build from source."
            exit 1
        fi
    else
        print_ok "Build dependencies present"
    fi

    local source_dir="/opt/telcoin-source"
    if [[ -d "$source_dir/.git" ]]; then
        # Refresh a reused clone THOROUGHLY so it is never stale across
        # remove/reinstall cycles: all branches + ALL tags (incl. re-pointed
        # ones), and prune deleted refs. A bare `fetch --all` does NOT reliably
        # fetch tags -- that is how clones ended up missing newer -adiri release
        # tags (e.g. showing v0.6.0-adiri-101 instead of v0.10.0-adiri).
        print_info "Refreshing existing source clone (all branches + tags)..."
        run_streamed git -C "$source_dir" fetch --all --tags --prune --force
    else
        print_info "Cloning Telcoin Network repository..."
        run_streamed git clone --recurse-submodules "$TN_REPO" "$source_dir"
    fi

    echo ""
    print_header "Source Branch / Tag Selection"
    print_info "Per the Telcoin dev team, the general case for testnet is to build"
    print_info "from the latest -adiri tag. main works too and is the right default"
    print_info "for devnet. mainnet will have its own tag set when it launches."
    echo ""

    local build_ref
    if json_mode; then
        build_ref="$JSON_BUILD_REF"
        [[ -n "$build_ref" ]] || { print_error "No --build-ref supplied for source build."; exit 1; }
    else
        build_ref=$(pick_source_version "$NETWORK") || {
            print_error "No source ref selected -- cannot continue setup."
            exit 1
        }
    fi

    print_step "Checking out: ${build_ref}..."
    if ! git -C "$source_dir" checkout --force "$build_ref" 2>/dev/null; then
        if ! { git -C "$source_dir" fetch origin "$build_ref" 2>/dev/null && \
               git -C "$source_dir" checkout --force "$build_ref" 2>/dev/null; }; then
            print_error "Branch or tag '${build_ref}' not found in repository."
            exit 1
        fi
    fi
    # If build_ref is a branch (e.g. main), hard-reset to the remote tip so we
    # never build a stale local branch. No-op for tags/commits (immutable).
    if git -C "$source_dir" show-ref --verify --quiet "refs/remotes/origin/${build_ref}"; then
        git -C "$source_dir" reset --hard "origin/${build_ref}" 2>/dev/null || true
    fi
    # Sync submodules to the checked-out ref so a reused clone never builds with
    # stale submodule state.
    run_streamed git -C "$source_dir" submodule update --init --recursive --force \
        || print_warn "submodule sync reported an issue -- build may fail"
    print_ok "Checked out: ${build_ref}"

    if [[ -f "${source_dir}/rust-toolchain.toml" ]]; then
        local required_toolchain
        required_toolchain=$(grep "channel" "${source_dir}/rust-toolchain.toml" 2>/dev/null | head -1 | cut -d'"' -f2)
        if [[ -n "$required_toolchain" ]]; then
            print_info "Installing required Rust toolchain: ${required_toolchain}..."
            rustup toolchain install "$required_toolchain" 2>/dev/null || true
            print_ok "Rust toolchain ready: ${required_toolchain}"
        fi
    fi

    local cargo_features=""
    if [[ "${NETWORK:-}" == "testnet" ]]; then
        cargo_features="--features adiri"
        print_info "Building with testnet features: adiri"
    fi

    print_info "Building release binary (this takes 20-40 minutes)..."
    cd "$source_dir"
    if json_mode; then
        # Stream each build line to the UI (and keep the full log on disk) so the
        # operator sees compile progress instead of a frozen screen.
        cargo build --release $cargo_features 2>&1 | tee /tmp/tn-build.log | while IFS= read -r _line; do
            json_emit "{\"event\":\"log\",\"msg\":\"$(json_escape "$_line")\"}"
        done
    else
        cargo build --release $cargo_features 2>&1 | tee /tmp/tn-build.log
    fi

    local built="${source_dir}/target/release/telcoin-network"
    if [[ ! -f "$built" ]]; then
        print_error "Build failed. See /tmp/tn-build.log"
        exit 1
    fi

    mkdir -p "$INSTALL_DIR"
    cp "$built" "${INSTALL_DIR}/telcoin-network"
    chmod +x "${INSTALL_DIR}/telcoin-network"
    BINARY_PATH="${INSTALL_DIR}/telcoin-network"
    # Record the installed ref so the UI reports the running binary's version.
    write_source_version_marker "$INSTALL_DIR" "$source_dir" "$build_ref"
    print_ok "Binary installed: ${BINARY_PATH}"

    # Write build info for Node Manager UI
    mkdir -p /etc/telcoin
    {
        echo "build_ref=${build_ref}"
        echo "commit=$(git -C "$source_dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
        echo "branch=$(git -C "$source_dir" symbolic-ref --short HEAD 2>/dev/null || echo "detached")"
        echo "built_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    } > /etc/telcoin/build-info
    print_ok "Build info written: /etc/telcoin/build-info"
}

_preflight_docker() {
    print_step "Setting up Docker..."

    if ! command -v docker &>/dev/null; then
        print_info "Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        if ! command -v docker &>/dev/null; then
            print_error "Docker installation failed. Please install Docker manually."
            exit 1
        fi
        print_ok "Docker installed"
    else
        print_ok "Docker is installed"
    fi

    echo ""
    print_info "The official Telcoin Network Docker image is hosted at:"
    print_info "  ${GAR_IMAGE_BASE}"
    echo ""
    print_info "Enter the full image URL including tag (default is the latest"
    print_info "published -adiri tag, auto-detected from the registry)."
    echo ""

    local input
    if json_mode; then
        # The UI passes --docker-image; only auto-detect when it didn't.
        [[ -n "${DOCKER_IMAGE:-}" ]] || DOCKER_IMAGE="$(latest_docker_image)"
    else
        local default_image
        default_image="$(latest_docker_image)"
        read -r -p "  Docker image (press Enter to accept default)
  [${default_image}]: " input
        DOCKER_IMAGE="${input:-$default_image}"
    fi

    print_step "Pulling Docker image: ${DOCKER_IMAGE}..."
    if ! docker pull "$DOCKER_IMAGE"; then
        print_error "Failed to pull Docker image: ${DOCKER_IMAGE}"
        exit 1
    fi
    print_ok "Docker image pulled: ${DOCKER_IMAGE}"

    DOCKER_UID=1101
    print_info "Note: Docker install requires service user UID ${DOCKER_UID}"

    local existing_user
    existing_user=$(getent passwd "$DOCKER_UID" | cut -d: -f1 2>/dev/null || echo "")
    if [[ -n "$existing_user" ]] && [[ "$existing_user" != "$SERVICE_USER" ]]; then
        print_error "UID ${DOCKER_UID} is already in use by user '${existing_user}'"
        exit 1
    fi

    BINARY_PATH="docker"
}

_preflight_existing() {
    print_step "Locating existing binary..."

    local found
    found=$(command -v telcoin-network 2>/dev/null || \
            find /usr/local/bin /opt /home -name "telcoin-network" -type f 2>/dev/null | head -1 || \
            echo "")

    if [[ -n "$found" ]]; then
        print_info "Found: ${found}"
        if confirm "Use this binary?"; then
            BINARY_PATH="$found"
        fi
    fi

    if [[ -z "${BINARY_PATH:-}" ]]; then
        read -r -p "  Full path to telcoin binary: " input
        BINARY_PATH="$input"
    fi

    if ! verify_binary "$BINARY_PATH"; then
        print_error "Cannot verify binary at ${BINARY_PATH}."
        exit 1
    fi
}

step_network() {
    print_header "Step 2 of 8: Network Selection"
    select_network
}

step_config() {
    print_header "Step 3 of 8: Node Configuration"

    # JSON mode: ports and directory paths come from flags/defaults set by the
    # orchestrator (the validator's addresses + multiaddrs are handled in
    # step_generate_keys). Run the same step, non-interactively.
    if json_mode; then
        print_ok "Configuration set (non-interactive)"
        print_info "Ports: P2P ${P2P_PORT} / worker ${WORKER_PORT} / RPC ${RPC_PORT} / metrics ${METRICS_PORT}"
        return 0
    fi

    echo "  Port configuration (press Enter to accept defaults):"
    echo ""

    local input
    read -r -p "  P2P primary port [${P2P_PORT}]: "    input; P2P_PORT="${input:-$P2P_PORT}"
    read -r -p "  P2P worker port  [${WORKER_PORT}]: " input; WORKER_PORT="${input:-$WORKER_PORT}"
    read -r -p "  RPC port         [${RPC_PORT}]: "    input; RPC_PORT="${input:-$RPC_PORT}"
    read -r -p "  Metrics port     [${METRICS_PORT}]: " input; METRICS_PORT="${input:-$METRICS_PORT}"

    echo ""
    print_info "Data dir:    ${DATA_DIR}"
    print_info "Config dir:  ${CONFIG_DIR}"
    print_info "Log dir:     ${LOG_DIR}"
    print_info "Install dir: ${INSTALL_DIR}"
    echo ""

    if ! confirm "Use these default paths?"; then
        read -r -p "  Config directory  [${CONFIG_DIR}]: " input;  CONFIG_DIR="${input:-$CONFIG_DIR}"
        read -r -p "  Log directory     [${LOG_DIR}]: " input;     LOG_DIR="${input:-$LOG_DIR}"
        read -r -p "  Install directory [${INSTALL_DIR}]: " input; INSTALL_DIR="${input:-$INSTALL_DIR}"
    fi

    echo ""
    print_info "Advertised node name (optional) -- a public label for this validator."
    print_info "Leave blank for none; you can set or change it later in the dashboard."
    read -r -p "  Advertised node name [none]: " ADVERTISED_NAME
    ADVERTISED_NAME="$(printf '%s' "$ADVERTISED_NAME" | tr -d '[:space:]')"
    if [[ -n "$ADVERTISED_NAME" && ! "$ADVERTISED_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
        print_warn "Invalid name -- ignoring (set it later in the dashboard)."
        ADVERTISED_NAME=""
    fi

    print_ok "Configuration set"
}

validate_service_name() {
    local name="$1"
    local label="$2"
    if [[ ! "$name" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,31}$ ]]; then
        print_error "${label} name '${name}' is invalid."
        print_info "Must start with a letter, contain only letters/numbers/hyphens/underscores, max 32 chars."
        return 1
    fi
    return 0
}

step_create_infrastructure() {
    print_header "Step 4 of 8: Creating System Infrastructure"

    echo "  The node runs as a dedicated system user for security."
    echo "  Press Enter to accept defaults."
    echo ""
    local input
    # JSON mode keeps the default SERVICE_USER/SERVICE_GROUP (telcoin) -- no prompts.
    while ! json_mode; do
        read -r -p "  Service user name  [${SERVICE_USER}]: " input
        local proposed_user="${input:-$SERVICE_USER}"
        if validate_service_name "$proposed_user" "Service user"; then
            if id "$proposed_user" &>/dev/null && [[ $(id -u "$proposed_user") -lt 1000 ]] || ! id "$proposed_user" &>/dev/null; then
                SERVICE_USER="$proposed_user"
                break
            else
                print_error "User '${proposed_user}' already exists as a regular user (UID $(id -u "$proposed_user"))."
                print_info "Please choose a different name or press Enter to use the default."
            fi
        fi
    done

    while ! json_mode; do
        read -r -p "  Service group name [${SERVICE_GROUP}]: " input
        local proposed_group="${input:-$SERVICE_GROUP}"
        if validate_service_name "$proposed_group" "Service group"; then
            SERVICE_GROUP="$proposed_group"
            break
        fi
    done
    echo ""

    # Remove stale groupadd/useradd lock files if present. A crashed process can
    # leave these behind (notably /etc/.pwd.lock, the lckpwdf() lock), making
    # groupadd fail with "cannot lock /etc/group; try again later". This runs
    # unconditionally before any user/group creation -- safe because setup runs
    # as root in a controlled context and no legitimate concurrent process holds
    # these locks during a node install.
    rm -f /etc/.pwd.lock /etc/group.lock /etc/gshadow.lock /etc/passwd.lock /etc/shadow.lock
    print_info "Cleared any stale user/group lock files"

    create_service_user

    # Record the service account in .node-meta NOW (not just at the end), so an
    # install interrupted after this point still leaves remove-node.sh enough to
    # clean up the user/group. step_create_service later overwrites with the
    # full metadata.
    mkdir -p "$CONFIG_DIR"
    {
        echo "HOST_SERVICE_USER=${SERVICE_USER}"
        echo "HOST_SERVICE_GROUP=${SERVICE_GROUP}"
    } > "${CONFIG_DIR}/.node-meta"
    chmod 600 "${CONFIG_DIR}/.node-meta"
    print_ok "Recorded service account in ${CONFIG_DIR}/.node-meta (${SERVICE_USER}:${SERVICE_GROUP})"

    print_step "Creating reth cache directory..."
    mkdir -p "/home/${SERVICE_USER}/.cache/reth/logs/telcoin-network-logs"
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "/home/${SERVICE_USER}"
    print_ok "Reth cache directory created"

    create_directories "$INSTALL_DIR" "$DATA_DIR" "$LOG_DIR" "$CONFIG_DIR"
    verify_binary "$BINARY_PATH"
    ensure_chain_configs_available
    print_ok "Infrastructure ready"
}

step_generate_keys() {
    print_header "Step 5 of 8: Validator Key Management"

    print_info "Your validator needs a BLS key for consensus signing."
    echo ""

    if [[ -d "${DATA_DIR}/node-keys" ]]; then
        if json_mode; then
            print_error "node-keys already exist at ${DATA_DIR}/node-keys -- refusing to overwrite in non-interactive mode"
            exit 1
        fi
        print_warn "Key files already exist in ${DATA_DIR}/node-keys/"
        if ! confirm "Overwrite existing keys?"; then
            print_ok "Keeping existing keys"
            return 0
        fi
    fi

    local input bls_passphrase bls_passphrase_confirm
    if json_mode; then
        # Address + multiaddrs come from flags; passphrase from TN_BLS_PASSPHRASE (env only).
        [[ "$VALIDATOR_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]] || print_warn "Address format looks unusual. Proceeding anyway."
        for v in PRIMARY_MULTIADDR WORKER_MULTIADDR PRIMARY_LISTENER_MULTIADDR WORKER_LISTENER_MULTIADDR; do
            [[ -n "${!v}" ]] || { print_error "missing multiaddr: ${v}"; exit 1; }
        done
        bls_passphrase="${TN_BLS_PASSPHRASE:-}"
        [[ -n "$bls_passphrase" ]] || { print_error "TN_BLS_PASSPHRASE not set -- cannot generate keys."; exit 1; }
    else
        read -r -p "  Validator execution address (0x...): " VALIDATOR_ADDRESS
        if [[ ! "$VALIDATOR_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
            print_warn "Address format looks unusual. Proceeding anyway."
        fi

        local public_ip
        public_ip=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null || echo "")
        if [[ -n "$public_ip" ]] && ! validate_public_ip "$public_ip"; then
            print_warn "Auto-detected public IP looks invalid: ${public_ip} -- will prompt instead."
            public_ip=""
        fi
        if [[ -z "$public_ip" ]]; then
            print_warn "Could not auto-detect public IP."
            prompt_with_validation "Enter your public/external IP address" validate_public_ip public_ip || exit 1
        else
            print_info "Detected public IP: ${public_ip}"
        fi
        # Persist for the .node-meta record (read back by the Node Manager UI).
        PUBLIC_IP="$public_ip"

        echo ""
        echo "  External addresses (advertised to peers -- use your public/external IP):"
        local default_primary="/ip4/${public_ip}/udp/${P2P_PORT}/quic-v1"
        while true; do
            read -r -p "  External primary addr [${default_primary}]: " input
            PRIMARY_MULTIADDR="${input:-$default_primary}"
            validate_multiaddr "$PRIMARY_MULTIADDR" && break
            print_warn "Invalid multiaddr. Expected /ip4/<addr>/udp/<port>/quic-v1 or /ip6/..."
        done

        local default_worker="/ip4/${public_ip}/udp/${WORKER_PORT}/quic-v1"
        while true; do
            read -r -p "  External worker addr  [${default_worker}]: " input
            WORKER_MULTIADDR="${input:-$default_worker}"
            validate_multiaddr "$WORKER_MULTIADDR" && break
            print_warn "Invalid multiaddr. Expected /ip4/<addr>/udp/<port>/quic-v1 or /ip6/..."
        done

        local internal_ip
        internal_ip=$(detect_internal_ip)
        if [[ -n "$internal_ip" ]] && ! validate_ipv4 "$internal_ip" && ! validate_ipv6 "$internal_ip"; then
            print_warn "Auto-detected internal IP looks invalid: ${internal_ip} -- will prompt instead."
            internal_ip=""
        fi
        if [[ -z "$internal_ip" ]]; then
            print_warn "Could not auto-detect internal IP."
            read -r -p "  Enter your internal/NIC IP address [0.0.0.0]: " internal_ip
            internal_ip="${internal_ip:-0.0.0.0}"
            if ! validate_ipv4 "$internal_ip" && ! validate_ipv6 "$internal_ip"; then
                print_error "Invalid IP: ${internal_ip}"
                exit 1
            fi
        else
            print_info "Detected internal IP: ${internal_ip}"
        fi

        echo ""
        echo "  Listener addresses (what the node binds to -- use your internal/NIC IP):"
        local default_listener_primary="/ip4/${internal_ip}/udp/${P2P_PORT}/quic-v1"
        while true; do
            read -r -p "  Listener primary addr [${default_listener_primary}]: " input
            PRIMARY_LISTENER_MULTIADDR="${input:-$default_listener_primary}"
            validate_multiaddr "$PRIMARY_LISTENER_MULTIADDR" && break
            print_warn "Invalid multiaddr. Expected /ip4/<addr>/udp/<port>/quic-v1 or /ip6/..."
        done

        local default_listener_worker="/ip4/${internal_ip}/udp/${WORKER_PORT}/quic-v1"
        while true; do
            read -r -p "  Listener worker addr  [${default_listener_worker}]: " input
            WORKER_LISTENER_MULTIADDR="${input:-$default_listener_worker}"
            validate_multiaddr "$WORKER_LISTENER_MULTIADDR" && break
            print_warn "Invalid multiaddr. Expected /ip4/<addr>/udp/<port>/quic-v1 or /ip6/..."
        done

        echo ""
        print_warn "Set a passphrase to encrypt your BLS validator key."
        print_warn "Store this securely -- you need it every time the node starts."
        echo ""

        while true; do
            read -r -s -p "  Enter BLS key passphrase: " bls_passphrase
            echo ""
            read -r -s -p "  Confirm BLS key passphrase: " bls_passphrase_confirm
            echo ""
            if [[ "$bls_passphrase" == "$bls_passphrase_confirm" ]]; then
                if [[ -z "$bls_passphrase" ]]; then
                    print_warn "Empty passphrase is not recommended."
                    if ! confirm "Continue with no passphrase?"; then continue; fi
                fi
                break
            fi
            print_warn "Passphrases do not match -- try again."
        done
    fi

    print_step "Generating validator keys..."
    export TN_BLS_PASSPHRASE="$bls_passphrase"

    if [[ "${INSTALL_METHOD:-}" == "docker" ]]; then
        # Run keygen as the host service account that OWNS DATA_DIR (bind-mounted as the
        # container HOME /home/nonroot) -- NOT the image's default nonroot UID -- so reth
        # can write the generated keys. Mirrors the runtime ExecStart's --user. A numeric
        # --user has no passwd entry in the image, so $HOME would fall back to "/" and
        # reth's default log dir ($HOME/.cache/reth/logs) would be unwritable; pin
        # HOME=/home/nonroot (the writable bind-mounted datadir) so reth logs land there.
        local docker_uid docker_gid
        docker_uid=$(id -u "$SERVICE_USER" 2>/dev/null || echo "1101")
        docker_gid=$(id -g "$SERVICE_GROUP" 2>/dev/null || echo "1101")
        if docker run --rm \
            --user "${docker_uid}:${docker_gid}" \
            -e HOME=/home/nonroot \
            -e TN_BLS_PASSPHRASE="$bls_passphrase" \
            -v "${DATA_DIR}:/home/nonroot" \
            "$DOCKER_IMAGE" \
            telcoin keytool generate validator \
            --datadir /home/nonroot \
            --address "$VALIDATOR_ADDRESS" \
            --external-primary-addr "$PRIMARY_MULTIADDR" \
            --external-worker-addrs "$WORKER_MULTIADDR"; then
            print_ok "Validator keys generated in: ${DATA_DIR}/node-keys/"
        else
            print_error "Key generation failed."
            exit 1
        fi
    else
        if "$BINARY_PATH" keytool generate validator \
            --datadir "$DATA_DIR" \
            --address "$VALIDATOR_ADDRESS" \
            --external-primary-addr "$PRIMARY_MULTIADDR" \
            --external-worker-addrs "$WORKER_MULTIADDR"; then
            print_ok "Validator keys generated in: ${DATA_DIR}/node-keys/"
        else
            print_error "Key generation failed."
            exit 1
        fi
    fi

    unset TN_BLS_PASSPHRASE
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "$DATA_DIR"

    local passphrase_file="${CONFIG_DIR}/bls-passphrase"
    echo "$bls_passphrase" > "$passphrase_file"
    chmod 600 "$passphrase_file"
    chown "${SERVICE_USER}:${SERVICE_GROUP}" "$passphrase_file"

    if [[ "$PASSPHRASE_METHOD" == "tpm" ]]; then
        tpm_seal_passphrase "$passphrase_file" "$CONFIG_DIR" "$bls_passphrase"
    else
        print_ok "Passphrase stored via LoadCredential (mode 600): ${passphrase_file}"
    fi

    bls_passphrase=""
    bls_passphrase_confirm=""

    display_node_info "$DATA_DIR" "$VALIDATOR_ADDRESS"

    echo ""
    print_warn "BACK UP YOUR KEYS NOW."
    print_info "If ${DATA_DIR}/node-keys/ is lost, you must re-register with the Association."
    echo ""
    # JSON mode: the UI enforces the "BACKED UP" gate between keygen and finalize,
    # so no blocking prompt here.
    json_mode || read -r -p "  Press Enter to confirm you have backed up your keys: "
}

step_write_config() {
    print_header "Step 6 of 8: Writing Configuration"

    local genesis_dir="${DATA_DIR}/genesis"
    mkdir -p "$genesis_dir"
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "$genesis_dir"

    local chain_subdir
    case "$NETWORK" in
        testnet) chain_subdir="testnet" ;;
        devnet)  chain_subdir="devnet" ;;
        *)       chain_subdir="mainnet" ;;
    esac

    local chain_configs_found=false
    # TN_GENESIS_DIR (optional) points DIRECTLY at the dir holding genesis.yaml/
    # committee.yaml/parameters.yaml and is checked FIRST. Expands to nothing when
    # unset, so the existing search order is unchanged.
    local search_paths=(
        ${TN_GENESIS_DIR:+"$TN_GENESIS_DIR"}
        "${TN_SOURCE_DIR}/chain-configs/${chain_subdir}"
        "/opt/telcoin-source/chain-configs/${chain_subdir}"
        "./chain-configs/${chain_subdir}"
        "${CONFIG_DIR}/chain-configs/${chain_subdir}"
    )

    for search_path in "${search_paths[@]}"; do
        if [[ -f "${search_path}/genesis.yaml" ]] && \
           [[ -f "${search_path}/committee.yaml" ]] && \
           [[ -f "${search_path}/parameters.yaml" ]]; then
            print_ok "Found chain-configs at: ${search_path}"
            cp "${search_path}/genesis.yaml"    "${genesis_dir}/genesis.yaml"
            cp "${search_path}/committee.yaml"  "${genesis_dir}/committee.yaml"
            cp "${search_path}/parameters.yaml" "${DATA_DIR}/parameters.yaml"
            chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "$genesis_dir" "${DATA_DIR}/parameters.yaml"
            print_ok "Chain config files copied"
            chain_configs_found=true
            break
        fi
    done

    if [[ "$chain_configs_found" == "false" ]]; then
        print_warn "Chain config files not found automatically."
        print_info "Copy from: https://github.com/Telcoin-Association/telcoin-network/tree/main/chain-configs/${chain_subdir}/"
        echo ""
        if json_mode; then
            print_error "Chain config files missing and cannot prompt in non-interactive mode."
            exit 1
        fi
        read -r -p "  Press Enter once you have copied the chain config files: "
    fi

    # Optional advertised node name -> data dir's network-config (no-op if blank).
    write_advertised_name "$DATA_DIR" "$ADVERTISED_NAME" "${SERVICE_USER}:${SERVICE_GROUP}"

    print_ok "Configuration ready under: ${DATA_DIR}"
}

step_create_service() {
    print_header "Step 7 of 8: Creating Systemd Service"

    print_info "Instance number affects RPC port: 8545 - (instance - 1)"
    print_info "  Instance 1 -> RPC port 8545 (default for validators)"
    echo ""
    local input instance
    if json_mode; then
        instance="${JSON_INSTANCE:-1}"
    else
        read -r -p "  Instance number [1]: " input
        instance="${input:-1}"
    fi
    RPC_PORT=$(( 8545 - (instance - 1) ))
    # WS port: reth offsets it from --instance as ws_port += instance*2 - 2 (base 8546; see
    # reth RpcServerArgs::adjust_instance_ports) -- the opposite direction from HTTP and at 2x
    # step. instance 1 -> 8546, instance 5 -> 8554. The launch heredocs below enable --ws and
    # pin both --http.addr/--ws.addr to 127.0.0.1 so RPC + WS are reachable ONLY via the Caddy
    # TLS edge (reth already defaults to loopback; pinning makes the intent explicit + immune
    # to a future default change). WS_PORT is persisted to .node-meta so config-caddy.sh proxies
    # wss:// to the right port -- verify the real bind with `ss -tlnp` at rollout (do not trust
    # the formula blindly: a fork could change the derivation).
    WS_PORT=$(( 8546 + (instance * 2 - 2) ))
    print_ok "Instance: ${instance}, RPC port: ${RPC_PORT}, WS port: ${WS_PORT}"

    local primary_multiaddr="$PRIMARY_LISTENER_MULTIADDR"
    local worker_multiaddr="$WORKER_LISTENER_MULTIADDR"
    print_info "P2P listener (internal): ${primary_multiaddr}"

    local passphrase_file="${CONFIG_DIR}/bls-passphrase"
    local service_file="/etc/systemd/system/${SERVICE_NAME}.service"

    # The UI runs setup as two separate processes (keygen, then finalize). The
    # source build that sets BINARY_PATH happens in keygen, so in the finalize
    # process BINARY_PATH is empty here -- which would make the wrapper run the
    # system `node` (Node.js) instead of the Telcoin binary. Source builds always
    # install to ${INSTALL_DIR}/telcoin-network, so re-derive it.
    if [[ "${INSTALL_METHOD:-}" != "docker" && -z "${BINARY_PATH:-}" ]]; then
        BINARY_PATH="${INSTALL_DIR}/telcoin-network"
    fi

    if [[ "${INSTALL_METHOD:-}" == "docker" ]]; then
        local docker_uid docker_gid
        docker_uid=$(id -u "$SERVICE_USER" 2>/dev/null || echo "1101")
        docker_gid=$(id -g "$SERVICE_GROUP" 2>/dev/null || echo "1101")

        # Testnet opt-in launch flags (healthcheck + JSON log shipping) as ONE line, so
        # an empty tail can't leave a dangling backslash. Docker reth log dir is the
        # container path /home/nonroot/logs (= host ${DATA_DIR}/logs).
        local launch_flags; launch_flags="$(tn_node_launch_flags docker)"

        # BLS passphrase is injected at RUNTIME, mirroring the source/binary path below: a
        # root-owned wrapper reads it (TPM, else the systemd LoadCredential dir) and
        # pass-throughs it to the container with `-e TN_BLS_PASSPHRASE` (NAME only -- the
        # value is NEVER written into the unit, so `systemctl cat`/`show` stay clean). The
        # value still lives in the container's env (inherent to Docker; see the README
        # security note) -- keeping it out of the persisted unit is the meaningful win.
        #
        # Pin HOME=/home/nonroot in the docker run: a numeric --user has no passwd entry in
        # the image, so $HOME would default to "/" and reth's default log dir
        # ($HOME/.cache/reth/logs) would be unwritable -> the node crash-loops on boot unless
        # obs logging happens to add --log.file.directory. The datadir is bind-mounted at
        # /home/nonroot and owned by --user, so logs/keys land writable. (Same root cause as
        # the keygen docker run.)
        local wrapper="${INSTALL_DIR}/start-${SERVICE_NAME}.sh"
        install -d -m 0755 "${INSTALL_DIR}"
        if [[ "$PASSPHRASE_METHOD" == "tpm" ]]; then
            cat > "$wrapper" <<EOF
#!/usr/bin/env bash
# Auto-generated by setup-validator.sh v${SCRIPT_VERSION}
# Reads BLS passphrase from TPM (with LoadCredential fallback) and starts the node container.
if command -v tpm2_unseal &>/dev/null && \
   [[ -f ${CONFIG_DIR}/bls-tpm.pub ]] && \
   [[ -f ${CONFIG_DIR}/bls-tpm.priv ]]; then
    tpm2_createprimary -Q -C e -c /tmp/tn-tpm-primary.ctx 2>/dev/null
    tpm2_load -Q -C /tmp/tn-tpm-primary.ctx \
        -u ${CONFIG_DIR}/bls-tpm.pub \
        -r ${CONFIG_DIR}/bls-tpm.priv \
        -c /tmp/tn-tpm-sealed.ctx 2>/dev/null
    export TN_BLS_PASSPHRASE=\$(tpm2_unseal -Q -c /tmp/tn-tpm-sealed.ctx 2>/dev/null)
    rm -f /tmp/tn-tpm-primary.ctx /tmp/tn-tpm-sealed.ctx
fi
if [[ -z "\${TN_BLS_PASSPHRASE:-}" ]]; then
    export TN_BLS_PASSPHRASE=\$(cat "\${CREDENTIALS_DIRECTORY}/bls-passphrase" 2>/dev/null || echo "")
fi
exec docker run --rm \
--name ${SERVICE_NAME} \
--user ${docker_uid}:${docker_gid} \
-e "HOME=/home/nonroot" \
--network=host \
-e TN_BLS_PASSPHRASE \
-e "PRIMARY_LISTENER_MULTIADDR=${primary_multiaddr}" \
-e "WORKER_LISTENER_MULTIADDR=${worker_multiaddr}" \
-v ${DATA_DIR}:/home/nonroot \
-v ${CONFIG_DIR}:/etc/telcoin/validator:ro \
${DOCKER_IMAGE} \
telcoin node \
--datadir /home/nonroot \
--instance ${instance} \
--log.stdout.format log-fmt \
-vvv \
--http --http.addr 127.0.0.1 --ws --ws.addr 127.0.0.1 ${launch_flags}
EOF
        else
            cat > "$wrapper" <<EOF
#!/usr/bin/env bash
# Auto-generated by setup-validator.sh v${SCRIPT_VERSION}
# Reads BLS passphrase from the systemd credential directory and starts the node container.
export TN_BLS_PASSPHRASE=\$(cat "\${CREDENTIALS_DIRECTORY}/bls-passphrase")
exec docker run --rm \
--name ${SERVICE_NAME} \
--user ${docker_uid}:${docker_gid} \
-e "HOME=/home/nonroot" \
--network=host \
-e TN_BLS_PASSPHRASE \
-e "PRIMARY_LISTENER_MULTIADDR=${primary_multiaddr}" \
-e "WORKER_LISTENER_MULTIADDR=${worker_multiaddr}" \
-v ${DATA_DIR}:/home/nonroot \
-v ${CONFIG_DIR}:/etc/telcoin/validator:ro \
${DOCKER_IMAGE} \
telcoin node \
--datadir /home/nonroot \
--instance ${instance} \
--log.stdout.format log-fmt \
-vvv \
--http --http.addr 127.0.0.1 --ws --ws.addr 127.0.0.1 ${launch_flags}
EOF
        fi
        # Root-owned + non-writable by SERVICE_USER: the unit runs ExecStart as root, so a
        # service-user-writable wrapper would be a root-escalation vector.
        chmod 0750 "$wrapper"
        chown root:root "$wrapper"
        print_ok "Wrapper script written: ${wrapper}"

        {
            cat <<EOF
[Unit]
Description=Telcoin Network Validator Node (${CHAIN_NAME}) [Docker]
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=root
EOF
            # Only include LoadCredential for the loadcredential method (TPM manages the
            # passphrase itself -- the credential file may not exist).
            if [[ "$PASSPHRASE_METHOD" != "tpm" ]]; then
                echo "LoadCredential=bls-passphrase:${passphrase_file}"
            fi
            cat <<EOF
ExecStartPre=-/usr/bin/docker rm -f ${SERVICE_NAME}
ExecStart=${wrapper}
ExecStop=docker stop ${SERVICE_NAME}
Restart=on-failure
RestartSec=10
StandardOutput=append:${LOG_DIR}/${SERVICE_NAME}.log
StandardError=append:${LOG_DIR}/${SERVICE_NAME}-error.log

[Install]
WantedBy=multi-user.target
EOF
        } > "$service_file"

    else
        # Guard: never write a wrapper with an empty binary path (it would exec
        # the system `node` and fail with "node: bad option: --datadir").
        if [[ -z "${BINARY_PATH:-}" || ! -x "${BINARY_PATH}" ]]; then
            print_error "Node binary not found at '${BINARY_PATH:-<unset>}' -- cannot write start wrapper."
            print_info  "Expected the source build to install it at ${INSTALL_DIR}/telcoin-network."
            exit 1
        fi
        local wrapper="${INSTALL_DIR}/start-${SERVICE_NAME}.sh"

        # Testnet opt-in launch flags (healthcheck + JSON log shipping) as ONE line, so
        # an empty tail can't leave a dangling backslash. Binary reth log dir is the host
        # path /var/log/telcoin (already in the unit's ReadWritePaths, owned telcoin:telcoin).
        local launch_flags; launch_flags="$(tn_node_launch_flags binary)"

        if [[ "$PASSPHRASE_METHOD" == "tpm" ]]; then
            cat > "$wrapper" <<EOF
#!/usr/bin/env bash
# Auto-generated by setup-validator.sh v${SCRIPT_VERSION}
# Reads BLS passphrase from TPM (with LoadCredential fallback) and starts the node
if command -v tpm2_unseal &>/dev/null && \
   [[ -f ${CONFIG_DIR}/bls-tpm.pub ]] && \
   [[ -f ${CONFIG_DIR}/bls-tpm.priv ]]; then
    tpm2_createprimary -Q -C e -c /tmp/tn-tpm-primary.ctx 2>/dev/null
    tpm2_load -Q -C /tmp/tn-tpm-primary.ctx \
        -u ${CONFIG_DIR}/bls-tpm.pub \
        -r ${CONFIG_DIR}/bls-tpm.priv \
        -c /tmp/tn-tpm-sealed.ctx 2>/dev/null
    export TN_BLS_PASSPHRASE=\$(tpm2_unseal -Q -c /tmp/tn-tpm-sealed.ctx 2>/dev/null)
    rm -f /tmp/tn-tpm-primary.ctx /tmp/tn-tpm-sealed.ctx
fi
if [[ -z "\${TN_BLS_PASSPHRASE:-}" ]]; then
    export TN_BLS_PASSPHRASE=\$(cat "\${CREDENTIALS_DIRECTORY}/bls-passphrase" 2>/dev/null || echo "")
fi
export PRIMARY_LISTENER_MULTIADDR="${primary_multiaddr}"
export WORKER_LISTENER_MULTIADDR="${worker_multiaddr}"
exec ${BINARY_PATH} node \
  --datadir ${DATA_DIR} \
  --instance ${instance} \
  --log.stdout.format log-fmt \
  -vvv \
  --http --http.addr 127.0.0.1 --ws --ws.addr 127.0.0.1 ${launch_flags}
EOF
        else
            cat > "$wrapper" <<EOF
#!/usr/bin/env bash
# Auto-generated by setup-validator.sh v${SCRIPT_VERSION}
# Reads BLS passphrase from systemd credential directory and starts the node
export TN_BLS_PASSPHRASE=\$(cat "\${CREDENTIALS_DIRECTORY}/bls-passphrase")
export PRIMARY_LISTENER_MULTIADDR="${primary_multiaddr}"
export WORKER_LISTENER_MULTIADDR="${worker_multiaddr}"
exec ${BINARY_PATH} node \
  --datadir ${DATA_DIR} \
  --instance ${instance} \
  --log.stdout.format log-fmt \
  -vvv \
  --http --http.addr 127.0.0.1 --ws --ws.addr 127.0.0.1 ${launch_flags}
EOF
        fi

        chmod +x "$wrapper"
        chown "${SERVICE_USER}:${SERVICE_GROUP}" "$wrapper"
        print_ok "Wrapper script written: ${wrapper}"

        {
            cat <<EOF
[Unit]
Description=Telcoin Network Validator Node (${CHAIN_NAME})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
EOF
            # Only include LoadCredential for loadcredential method
            # TPM method manages passphrase directly -- file may not exist
            if [[ "$PASSPHRASE_METHOD" != "tpm" ]]; then
                echo "LoadCredential=bls-passphrase:${passphrase_file}"
            fi
            cat <<EOF
Environment="PRIMARY_LISTENER_MULTIADDR=${primary_multiaddr}"
Environment="WORKER_LISTENER_MULTIADDR=${worker_multiaddr}"
ExecStart=${wrapper}
Restart=on-failure
RestartSec=10
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=${DATA_DIR} ${LOG_DIR}
LimitNOFILE=65536
StandardOutput=append:${LOG_DIR}/${SERVICE_NAME}.log
StandardError=append:${LOG_DIR}/${SERVICE_NAME}-error.log

[Install]
WantedBy=multi-user.target
EOF
        } > "$service_file"
    fi

    systemctl daemon-reload
    print_ok "Service file written: ${service_file}"

    local meta_file="/etc/telcoin/validator/.node-meta"
    mkdir -p "/etc/telcoin/validator"
    cat > "$meta_file" <<EOF
HOST_SERVICE_USER=${SERVICE_USER}
HOST_SERVICE_GROUP=${SERVICE_GROUP}
INSTALL_METHOD=${INSTALL_METHOD:-binary}
PASSPHRASE_METHOD=${PASSPHRASE_METHOD}
DOCKER_IMAGE=${DOCKER_IMAGE:-}
NETWORK=${NETWORK}
DATA_DIR=${DATA_DIR}
RPC_PORT=${RPC_PORT}
WS_PORT=${WS_PORT}
PUBLIC_IP=${PUBLIC_IP:-}
EXTERNAL_PRIMARY_ADDR=${PRIMARY_MULTIADDR:-}
EXTERNAL_WORKER_ADDR=${WORKER_MULTIADDR:-}
VALIDATOR_ADDRESS=${VALIDATOR_ADDRESS:-}
REGION=${REGION:-}
ENABLE_HEALTHCHECK_MONITOR=${ENABLE_HEALTHCHECK_MONITOR:-false}
ENABLE_OBSERVABILITY=${ENABLE_OBSERVABILITY:-false}
ENABLE_METRICS=${ENABLE_METRICS:-false}
METRICS_PORT=${METRICS_PORT:-9101}
ENABLE_VPN=${ENABLE_VPN:-false}
VPN_OVERLAY_IP=${VPN_OVERLAY_IP:-}
VPN_NODE_PUBKEY=${VPN_NODE_PUBKEY:-}
EOF
    chmod 600 "$meta_file"
    print_ok "Node metadata written: ${meta_file}"

    # Start each install with a clean log. The unit appends
    # (StandardOutput=append:), so a re-install would otherwise concatenate its
    # output onto the previous install's log -- mixing old + new runs in the file
    # the UI's "download full log" serves. Truncate in place (preserves the
    # service-user ownership); systemd recreates a fresh file for a new install.
    [[ -f "${LOG_DIR}/${SERVICE_NAME}.log" ]] && : > "${LOG_DIR}/${SERVICE_NAME}.log" || true
    [[ -f "${LOG_DIR}/${SERVICE_NAME}-error.log" ]] && : > "${LOG_DIR}/${SERVICE_NAME}-error.log" || true

    echo ""
    if json_mode || confirm "Start the validator node now?"; then
        systemctl start "$SERVICE_NAME"
        sleep 3

        if systemctl is-active --quiet "$SERVICE_NAME"; then
            print_ok "Service is running"
        else
            print_error "Service failed to start."
            print_info "Check logs: journalctl -u ${SERVICE_NAME} --no-pager -n 50"
            systemctl status "$SERVICE_NAME" --no-pager || true
            exit 1
        fi

        local local_rpc="http://127.0.0.1:${RPC_PORT}"
        check_rpc_alive "$local_rpc" 15 6 || print_warn "RPC not yet responding -- normal during startup."

        echo ""
        check_validator_onchain_status "$VALIDATOR_ADDRESS" "$local_rpc"

        if json_mode || confirm "Enable auto-start on server reboot?"; then
            systemctl enable "$SERVICE_NAME"
            print_ok "Auto-start enabled"
        fi
    fi
}

step_final_summary() {
    print_summary "Validator Node Setup Complete" \
        "Network=${NETWORK} (Chain ID: ${CHAIN_ID})" \
        "Node type=Validator" \
        "Binary=${BINARY_PATH}" \
        "Data directory=${DATA_DIR}" \
        "Config directory=${CONFIG_DIR}" \
        "Log directory=${LOG_DIR}" \
        "P2P primary port=${P2P_PORT}" \
        "P2P worker port=${WORKER_PORT}" \
        "RPC port=${RPC_PORT}" \
        "Metrics port=${METRICS_PORT}" \
        "Systemd service=${SERVICE_NAME}" \
        "Explorer=${EXPLORER_URL}"

    if [[ "${INSTALL_METHOD:-}" != "docker" ]]; then
        if [[ "$PASSPHRASE_METHOD" == "tpm" ]]; then
            print_info "BLS passphrase sealed to TPM chip."
        else
            print_info "BLS passphrase secured via systemd LoadCredential (not exposed in service file)."
        fi
    fi
    echo ""
    echo "  Useful commands:"
    echo ""
    echo "  View logs:"
    echo "    journalctl -u ${SERVICE_NAME} -f"
    echo ""
    echo "  Check RPC:"
    echo "    curl -s -X POST -H 'Content-Type: application/json' \\"
    echo "      --data '{\"jsonrpc\":\"2.0\",\"method\":\"eth_chainId\",\"params\":[],\"id\":1}' \\"
    echo "      http://127.0.0.1:${RPC_PORT}"
    echo ""
    echo "  Stop / restart:"
    echo "    systemctl stop ${SERVICE_NAME}"
    echo "    systemctl restart ${SERVICE_NAME}"
    echo ""
    print_sep
    echo ""
    print_info "Next steps:"
    echo "  1. Allow inbound UDP on ports 49590 and 49594 in your firewall"
    echo "  2. Submit your ECDSA validator address to the Telcoin Association for governance approval"
    echo "  3. Once approved and NFT minted, stake your TEL via the ConsensusRegistry contract"
    echo "  4. Wait for your node to sync, then call activate()"
    echo "  5. Run the health check: bash check-node.sh --address ${VALIDATOR_ADDRESS}"
    echo "  6. Full guide: https://docs.telcoin.network/telcoin-network/staking/how-to-stake"
    echo ""
}

# =============================================================================
# JSON / NON-INTERACTIVE MODE  (phased, driven by the Node Manager UI)
#
# Reached only via `--json` (the interactive default is completely unaffected).
# Two phases, mirroring the UI's forced key-backup gate:
#   --json --phase=keygen   -> preflight + infrastructure + key generation only;
#                              writes NO unit and starts NOTHING. Emits the full
#                              node-info.yaml so the operator can back it up.
#   --json --phase=finalize -> write config + create service + start + verify.
#
# fd handling mirrors update-node.sh: stdout -> fd3 (newline-delimited JSON),
# real stdout -> stderr. BLS passphrase arrives via TN_BLS_PASSPHRASE env ONLY.
#
# Note: on-chain validator registration (governance approval, staking,
# activate()) is intentionally NOT performed here -- the UI surfaces the
# next-step guidance the interactive summary prints.
# =============================================================================

JSON_MODE=false
JSON_PHASE=""
JSON_BUILD_REF=""
JSON_INSTANCE="1"
JSON_NETWORK_INPUT="testnet"
JSON_DONE_EMITTED=false
# Optional override: dir holding genesis.yaml/committee.yaml/parameters.yaml,
# checked first by step_write_config. Preserve any env value; default empty so
# `set -u` never trips and the ${TN_GENESIS_DIR:+...} expansion is a no-op.
TN_GENESIS_DIR="${TN_GENESIS_DIR:-}"

json_mode() { [[ "$JSON_MODE" == "true" ]]; }

json_setup_fds() {
    exec 3>&1   # fd3 = original stdout: JSON is written here
    exec 1>&2   # stdout now aliases stderr: print_*/build output is benign noise
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/ }"; s="${s//$'\t'/ }"
    printf '%s' "$s"
}

json_emit() { printf '%s\n' "$1" >&3; }
json_event() { json_emit "{\"event\":\"${1}\",\"msg\":\"$(json_escape "${2:-}")\"}"; }
json_done() { JSON_DONE_EMITTED=true; json_emit "$1"; }

# Run a command, streaming each combined-output line to the UI as a JSON `log`
# event (JSON mode only) so the long, otherwise-silent steps -- the git clone and
# the 20-40 min cargo build -- show live progress instead of looking frozen. In
# interactive mode the command just runs normally. Returns the command's status.
run_streamed() {
    if json_mode; then
        "$@" 2>&1 | while IFS= read -r _line; do
            json_emit "{\"event\":\"log\",\"msg\":\"$(json_escape "$_line")\"}"
        done
        return "${PIPESTATUS[0]}"
    fi
    "$@"
}

json_on_exit() {
    local rc=$?
    [[ "$JSON_DONE_EMITTED" == "true" ]] && return
    json_emit "{\"event\":\"done\",\"ok\":false,\"msg\":\"setup exited early (rc=${rc}) -- see server logs / journalctl\"}"
}

json_set_network() {
    case "${1:-testnet}" in
        testnet|adiri)
            NETWORK="testnet"; CHAIN_ID="$TESTNET_CHAIN_ID"; CHAIN_NAME="$TESTNET_CHAIN_NAME"
            RPC_URL="${TESTNET_RPC_URL:-}"; EXPLORER_URL="${TESTNET_EXPLORER:-}" ;;
        devnet)
            NETWORK="devnet"; CHAIN_ID="$DEVNET_CHAIN_ID"; CHAIN_NAME="$DEVNET_CHAIN_NAME"
            RPC_URL="${DEVNET_RPC_URL:-}"; EXPLORER_URL="${DEVNET_EXPLORER:-}" ;;
        *) json_event error "unsupported network: ${1} (expected testnet or devnet)"; exit 1 ;;
    esac
}

json_phase_keygen() {
    json_event step "Running preflight checks and installing dependencies"
    step_preflight
    json_event step "Applying node configuration"
    step_config
    json_event step "Creating system infrastructure"
    step_create_infrastructure
    json_event step "Generating ${NODE_TYPE} keys"
    step_generate_keys

    local info="${DATA_DIR}/node-info.yaml" info_content=""
    [[ -f "$info" ]] && info_content="$(json_escape "$(cat "$info")")"
    json_done "{\"event\":\"done\",\"ok\":true,\"phase\":\"keygen\",\"node_type\":\"${NODE_TYPE}\",\"node_info_path\":\"$(json_escape "$info")\",\"keys_dir\":\"$(json_escape "${DATA_DIR}/node-keys")\",\"node_info\":\"${info_content}\",\"msg\":\"keys generated -- BACK THEM UP before finalizing\"}"
}

json_phase_finalize() {
    json_event step "Writing configuration"
    step_write_config
    json_event step "Creating service and starting node"
    step_create_service
    json_done "{\"event\":\"done\",\"ok\":true,\"phase\":\"finalize\",\"node_type\":\"${NODE_TYPE}\",\"service\":\"${SERVICE_NAME}\",\"rpc_port\":\"${RPC_PORT}\",\"msg\":\"${SERVICE_NAME} finalized and started -- on-chain registration still required (see docs)\"}"
}

run_json_mode() {
    json_setup_fds
    trap json_on_exit EXIT
    check_root
    export TN_ASSUME_YES=true   # non-interactive: auto-accept confirms (no stdin)
    json_set_network "$JSON_NETWORK_INPUT"
    case "$JSON_PHASE" in
        keygen)   json_phase_keygen ;;
        finalize) json_phase_finalize ;;
        *)        json_event error "unknown or missing --phase (expected keygen|finalize)"; exit 1 ;;
    esac
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    local json_mode=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)                json_mode=true; shift ;;
            --phase)               JSON_PHASE="${2:-}"; shift 2 ;;
            --phase=*)             JSON_PHASE="${1#*=}"; shift ;;
            --network)             JSON_NETWORK_INPUT="${2:-}"; shift 2 ;;
            --install-method)      INSTALL_METHOD="${2:-}"; shift 2 ;;
            --passphrase-method)   PASSPHRASE_METHOD="${2:-}"; shift 2 ;;
            --address)             VALIDATOR_ADDRESS="${2:-}"; shift 2 ;;
            --build-ref)           JSON_BUILD_REF="${2:-}"; shift 2 ;;
            --docker-image)        DOCKER_IMAGE="${2:-}"; shift 2 ;;
            --instance)            JSON_INSTANCE="${2:-}"; shift 2 ;;
            --external-primary)    PRIMARY_MULTIADDR="${2:-}"; shift 2 ;;
            --external-worker)     WORKER_MULTIADDR="${2:-}"; shift 2 ;;
            --listener-primary)    PRIMARY_LISTENER_MULTIADDR="${2:-}"; shift 2 ;;
            --listener-worker)     WORKER_LISTENER_MULTIADDR="${2:-}"; shift 2 ;;
            --public-ip)           PUBLIC_IP="${2:-}"; shift 2 ;;
            --rpc-public)          shift 2 ;;  # validators have no public-RPC option; ignored
            --advertised-name)     ADVERTISED_NAME="${2:-}"; shift 2 ;;
            --data-dir)            DATA_DIR="${2:-$DATA_DIR}"; shift 2 ;;
            --service-user)        SERVICE_USER="${2:-}"; shift 2 ;;
            --service-group)       SERVICE_GROUP="${2:-}"; shift 2 ;;
            --genesis-dir)         TN_GENESIS_DIR="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ "$json_mode" == "true" ]]; then
        JSON_MODE=true
        run_json_mode
        exit $?
    fi

    step_welcome
    step_preflight
    step_config
    step_create_infrastructure
    step_generate_keys
    step_write_config
    step_create_service
    step_testnet_addons
    step_final_summary
}

main "$@"
