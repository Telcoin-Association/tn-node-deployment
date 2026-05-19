#!/usr/bin/env bash
# =============================================================================
# setup-observer.sh -- Telcoin Network Observer Node Setup
#
# USAGE:
#   sudo bash setup-observer.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

readonly SCRIPT_VERSION="1.1.20"
readonly SERVICE_NAME="telcoin-observer"
readonly NODE_TYPE="observer"

NETWORK=""
CHAIN_ID=""
CHAIN_NAME=""
RPC_URL=""
EXPLORER_URL=""
INSTALL_METHOD=""
BINARY_PATH=""
DATA_DIR="$DEFAULT_DATA_DIR/observer"
CONFIG_DIR="$DEFAULT_CONFIG_DIR/observer"
LOG_DIR="$DEFAULT_LOG_DIR"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
P2P_PORT="$DEFAULT_P2P_PORT"
WORKER_PORT="$DEFAULT_WORKER_PORT"
RPC_PORT="8541"
METRICS_PORT="$DEFAULT_METRICS_PORT"
ENABLE_PUBLIC_RPC="false"
TN_SOURCE_DIR="/opt/telcoin-source"
OBSERVER_ADDRESS=""
PRIMARY_MULTIADDR=""
WORKER_MULTIADDR=""
PRIMARY_LISTENER_MULTIADDR=""
WORKER_LISTENER_MULTIADDR=""

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
    echo "  ${BOLD}Telcoin Network -- Observer Node Setup  v${SCRIPT_VERSION}${RESET}"
    echo ""
    print_sep
    echo ""
    print_info "This script will set up an OBSERVER node on the Telcoin Network."
    print_info "An observer:"
    echo "    * Syncs and stores the full chain state"
    echo "    * Serves JSON-RPC queries (same API as any EVM node)"
    echo "    * Forwards transactions to the network"
    echo "    * Does NOT participate in block creation or consensus"
    echo "    * Does NOT require Telcoin Association approval"
    echo ""
    print_sep
    echo ""

    if ! confirm "Ready to begin observer node setup?"; then
        print_info "Setup cancelled."
        exit 0
    fi
}

step_preflight() {
    print_header "Step 1 of 7: Pre-flight Checks"
    check_root
    detect_distro
    check_cve_2026_31431
    check_hardware "observer"
    check_internet
    check_ports "$P2P_PORT" "$WORKER_PORT" "$RPC_PORT" "$METRICS_PORT"

    for tool in curl git; do
        if command_exists "$tool"; then
            print_ok "${tool} is installed"
        else
            install_package "$tool"
        fi
    done

    print_ok "Pre-flight checks complete"
}

step_network() {
    print_header "Step 2 of 7: Network Selection"
    select_network
}

step_config() {
    print_header "Step 3 of 7: Node Configuration"

    echo "  RPC access:"
    echo ""
    echo "  1) Private (recommended) -- RPC accessible from this server only"
    echo "              No firewall changes needed. Best for personal use,"
    echo "              development, and internal tooling."
    echo ""
    echo "  2) Public                -- RPC endpoint accessible from the internet"
    echo "              Requires nginx on port 443 (HTTPS)."
    echo "              You will need to open port 443 on your firewall"
    echo "              and router. An example nginx config will be"
    echo "              generated for you to configure."
    echo ""
    local choice
    while true; do
        read -r -p "  Enter choice [1/2]: " choice
        case "$choice" in
            1) ENABLE_PUBLIC_RPC="false"; break ;;
            2) ENABLE_PUBLIC_RPC="true";  break ;;
            *) print_warn "Please enter 1 or 2." ;;
        esac
    done

    echo ""
    echo "  Port configuration (press Enter to accept defaults):"
    echo ""

    local input
    read -r -p "  P2P primary port [${P2P_PORT}]: "    input; P2P_PORT="${input:-$P2P_PORT}"
    read -r -p "  P2P worker port  [${WORKER_PORT}]: " input; WORKER_PORT="${input:-$WORKER_PORT}"
    read -r -p "  RPC port         [${RPC_PORT}]: "    input; RPC_PORT="${input:-$RPC_PORT}"
    read -r -p "  Metrics port     [${METRICS_PORT}]: " input; METRICS_PORT="${input:-$METRICS_PORT}"

    echo ""
    echo "  Directory paths (press Enter to accept defaults):"
    echo ""
    print_info "Data dir:    ${DATA_DIR}"
    print_info "Config dir:  ${CONFIG_DIR}"
    print_info "Log dir:     ${LOG_DIR}"
    print_info "Install dir: ${INSTALL_DIR}"
    echo ""

    if ! confirm "Use these default paths?"; then
        read -r -p "  Data directory    [${DATA_DIR}]: " input;    DATA_DIR="${input:-$DATA_DIR}"
        read -r -p "  Config directory  [${CONFIG_DIR}]: " input;  CONFIG_DIR="${input:-$CONFIG_DIR}"
        read -r -p "  Log directory     [${LOG_DIR}]: " input;     LOG_DIR="${input:-$LOG_DIR}"
        read -r -p "  Install directory [${INSTALL_DIR}]: " input; INSTALL_DIR="${input:-$INSTALL_DIR}"
    fi

    print_ok "Configuration set"

    # Set multiaddrs now so they're available for key generation.
    # Two distinct address roles:
    #   PRIMARY_MULTIADDR / WORKER_MULTIADDR      -- external (advertised to peers, public IP)
    #   PRIMARY_LISTENER_MULTIADDR / WORKER_LISTENER_MULTIADDR -- listener (NIC bind, internal IP)
    echo ""
    echo "  Network addresses:"
    echo ""

    # External (advertised) address
    local public_ip
    public_ip=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null || echo "")
    if [[ -z "$public_ip" ]]; then
        print_warn "Could not auto-detect public IP."
        read -r -p "  Enter your public/external IP address: " public_ip
    else
        print_info "Detected public IP: ${public_ip}"
    fi

    echo ""
    echo "  External addresses (advertised to peers -- use your public/external IP):"
    local default_primary="/ip4/${public_ip}/udp/${P2P_PORT}/quic-v1"
    read -r -p "  External primary addr [${default_primary}]: " input
    PRIMARY_MULTIADDR="${input:-$default_primary}"

    local default_worker="/ip4/${public_ip}/udp/${WORKER_PORT}/quic-v1"
    read -r -p "  External worker addr  [${default_worker}]: " input
    WORKER_MULTIADDR="${input:-$default_worker}"

    # Listener (bind) address
    local internal_ip
    internal_ip=$(detect_internal_ip)
    if [[ -z "$internal_ip" ]]; then
        print_warn "Could not auto-detect internal IP."
        read -r -p "  Enter your internal/NIC IP address: " internal_ip
        internal_ip="${internal_ip:-0.0.0.0}"
    else
        print_info "Detected internal IP: ${internal_ip}"
    fi

    echo ""
    echo "  Listener addresses (what the node binds to -- use your internal/NIC IP):"
    local default_listener_primary="/ip4/${internal_ip}/udp/${P2P_PORT}/quic-v1"
    read -r -p "  Listener primary addr [${default_listener_primary}]: " input
    PRIMARY_LISTENER_MULTIADDR="${input:-$default_listener_primary}"

    local default_listener_worker="/ip4/${internal_ip}/udp/${WORKER_PORT}/quic-v1"
    read -r -p "  Listener worker addr  [${default_listener_worker}]: " input
    WORKER_LISTENER_MULTIADDR="${input:-$default_listener_worker}"

    print_ok "External: ${PRIMARY_MULTIADDR} | Listener: ${PRIMARY_LISTENER_MULTIADDR}"
}

step_install_binary() {
    print_header "Step 4 of 7: Installing Binary"
    select_install_method

    case "$INSTALL_METHOD" in
        source)   _install_from_source ;;
        binary)   _install_prebuilt_binary ;;
        docker)   _setup_docker ;;
        existing) _use_existing_binary ;;
    esac
}

_install_from_source() {
    print_step "Building from source..."

    if ! check_rust; then
        print_info "Installing Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
        export PATH="${HOME}/.cargo/bin:${PATH}"
        if ! check_rust; then
            print_error "Rust installation failed."
            exit 1
        fi
    fi

    local source_dir="/opt/telcoin-source"
    if [[ -d "$source_dir/.git" ]]; then
        print_info "Updating existing source clone..."
        git -C "$source_dir" fetch --all
    else
        print_info "Cloning repository..."
        git clone --recurse-submodules "$TN_REPO" "$source_dir"
    fi

    # --- Branch / tag selection ---
    echo ""
    print_header "Source Branch / Tag Selection"
    echo "  Which branch or tag would you like to build from?"
    echo ""
    echo "  1) main (recommended -- stable release)"
    echo "  2) Custom branch or tag (for testing unreleased fixes)"
    echo ""
    local branch_choice
    while true; do
        read -r -p "  Enter choice [1/2]: " branch_choice
        case "$branch_choice" in
            1|2) break ;;
            *) print_warn "Please enter 1 or 2." ;;
        esac
    done

    local build_ref="main"
    if [[ "$branch_choice" == "2" ]]; then
        echo ""
        read -r -p "  Enter branch or tag name: " build_ref
        build_ref="${build_ref:-main}"
        echo ""
        print_warn "Building from '${build_ref}' -- this may be unstable or incomplete."
        print_warn "Only use custom branches/tags if instructed by the Telcoin dev team."
        echo ""
    fi

    # Validate and checkout the branch/tag
    print_step "Checking out: ${build_ref}..."
    if ! git -C "$source_dir" checkout "$build_ref" 2>/dev/null; then
        # Try fetching it explicitly (handles remote branches not yet locally known)
        if git -C "$source_dir" fetch origin "$build_ref" 2>/dev/null && \
           git -C "$source_dir" checkout "$build_ref" 2>/dev/null; then
            print_ok "Checked out: ${build_ref}"
        else
            print_error "Branch or tag '${build_ref}' not found in repository."
            exit 1
        fi
    else
        print_ok "Checked out: ${build_ref}"
    fi


    # Ensure cargo is in PATH -- it may have just been installed as root
    export PATH="${HOME}/.cargo/bin:/root/.cargo/bin:${PATH}"
    source "${HOME}/.cargo/env" 2>/dev/null || true

    # Install the exact Rust toolchain version required by this repo
    if [[ -f "${source_dir}/rust-toolchain.toml" ]]; then
        local required_toolchain
        required_toolchain=$(grep "channel" "${source_dir}/rust-toolchain.toml" 2>/dev/null | head -1 | cut -d'"' -f2)
        if [[ -n "$required_toolchain" ]]; then
            print_info "Installing required Rust toolchain: ${required_toolchain}..."
            rustup toolchain install "$required_toolchain" 2>/dev/null || true
            print_ok "Rust toolchain ready: ${required_toolchain}"
        fi
    fi

    # Ensure C/C++ build dependencies are present
    print_step "Checking source build dependencies..."
    local build_deps=("build-essential" "cmake" "clang" "libclang-dev" "libclang-16-dev" "pkg-config" "libssl-dev" "libapr1-dev")
    local missing_deps=()
    for _dep in "${build_deps[@]}"; do
        if ! dpkg -l "$_dep" 2>/dev/null | grep -q "^ii"; then
            missing_deps+=("$_dep")
        fi
    done
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_warn "Missing build dependencies: ${missing_deps[*]}"
        if confirm "Install missing packages now?"; then
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

    # Build -- always include faucet feature for testnet
    local cargo_features=""
    if [[ "${NETWORK:-}" == "testnet" ]]; then
        cargo_features="--features faucet"
        print_info "Building with testnet features: faucet"
    fi

    print_info "Building release binary (this takes 20-40 minutes)..."
    cd "$source_dir"
    cargo build --release $cargo_features 2>&1 | tee /tmp/tn-build.log

    local built="${source_dir}/target/release/telcoin-network"
    if [[ ! -f "$built" ]]; then
        print_error "Build failed. See /tmp/tn-build.log"
        exit 1
    fi

    mkdir -p "$INSTALL_DIR"
    cp "$built" "${INSTALL_DIR}/telcoin-network"
    chmod +x "${INSTALL_DIR}/telcoin-network"
    BINARY_PATH="${INSTALL_DIR}/telcoin-network"
    print_ok "Binary installed: ${BINARY_PATH}"
}

_install_prebuilt_binary() {
    print_step "Pre-built binary..."
    echo ""
    print_warn "Pre-built binary downloads are coming soon."
    print_info "Official releases will be available at:"
    print_info "  https://github.com/Telcoin-Association/tn-node-deployment/releases"
    echo ""
    print_warn "This option is not yet available -- please choose another method."
    echo ""
    read -r -p "  Press Enter to return to the install method menu..."
    echo ""
    step_install_binary
}

_setup_docker() {
    print_header "Step 4 of 7: Docker Setup"

    if ! command -v docker &>/dev/null; then
        print_step "Installing Docker..."
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
    print_info "  us-docker.pkg.dev/telcoin-network/tn-public/adiri"
    echo ""
    print_info "Enter the full image URL including tag."
    print_info "Check for the latest tag at:"
    print_info "  https://console.cloud.google.com/artifacts/docker/telcoin-network/us/tn-public/adiri"
    echo ""

    local input
    read -r -p "  Docker image (press Enter to accept default)
  [us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.9.1-adiri]: " input
    DOCKER_IMAGE="${input:-us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.9.1-adiri}"

    print_step "Pulling Docker image: ${DOCKER_IMAGE}..."
    if ! docker pull "$DOCKER_IMAGE"; then
        print_error "Failed to pull Docker image: ${DOCKER_IMAGE}"
        print_info "Check the image URL and tag and try again."
        exit 1
    fi
    print_ok "Docker image pulled: ${DOCKER_IMAGE}"

    DOCKER_UID=1101
    print_info "Note: Docker install requires service user UID ${DOCKER_UID}"
    print_info "      This matches the container's internal 'nonroot' user."

    local existing_user
    existing_user=$(getent passwd "$DOCKER_UID" | cut -d: -f1 2>/dev/null || echo "")
    if [[ -n "$existing_user" ]] && [[ "$existing_user" != "$SERVICE_USER" ]]; then
        print_error "UID ${DOCKER_UID} is already in use by user '${existing_user}'"
        print_info "Please free up UID ${DOCKER_UID} or choose a different install method."
        exit 1
    fi

    INSTALL_METHOD="docker"
    BINARY_PATH="docker"
    print_ok "Docker setup complete"
}

_use_existing_binary() {
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

    if [[ -z "$BINARY_PATH" ]]; then
        read -r -p "  Full path to telcoin binary: " input
        BINARY_PATH="$input"
    fi

    if ! verify_binary "$BINARY_PATH"; then
        print_error "Cannot verify binary at ${BINARY_PATH}."
        exit 1
    fi
}

step_create_infrastructure() {
    print_header "Step 5 of 7: Creating System Infrastructure"

    echo "  The node runs as a dedicated system user for security."
    echo "  Press Enter to accept defaults."
    echo ""
    local input
    read -r -p "  Service user name  [${SERVICE_USER}]: "  input; SERVICE_USER="${input:-$SERVICE_USER}"
    read -r -p "  Service group name [${SERVICE_GROUP}]: " input; SERVICE_GROUP="${input:-$SERVICE_GROUP}"
    echo ""

    create_service_user

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
    print_header "Step 6 of 7: Observer Key Generation"

    print_info "An observer node needs keys for its P2P network identity."
    echo ""

    if [[ -d "${DATA_DIR}/node-keys" ]]; then
        print_warn "Key files already exist in ${DATA_DIR}/node-keys/"
        if ! confirm "Overwrite existing keys?"; then
            print_ok "Keeping existing keys"
            return 0
        fi
    fi

    read -r -p "  Observer Ethereum address (0x...): " OBSERVER_ADDRESS
    if [[ ! "$OBSERVER_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        print_warn "Address format looks unusual. Proceeding anyway."
    fi

    echo ""
    print_warn "Set a passphrase to encrypt this node's BLS key."
    print_warn "You will need this every time the node starts."
    echo ""

    local bls_passphrase bls_passphrase_confirm
    while true; do
        read -r -s -p "  Enter BLS key passphrase: " bls_passphrase
        echo ""
        read -r -s -p "  Confirm BLS key passphrase: " bls_passphrase_confirm
        echo ""
        if [[ "$bls_passphrase" == "$bls_passphrase_confirm" ]]; then
            break
        fi
        print_warn "Passphrases do not match -- try again."
    done

    print_step "Generating observer keys..."
    export TN_BLS_PASSPHRASE="$bls_passphrase"

    if [[ "${INSTALL_METHOD:-}" == "docker" ]]; then
        if docker run --rm \
            -e TN_BLS_PASSPHRASE="$bls_passphrase" \
            -v "${DATA_DIR}:/home/nonroot" \
            "$DOCKER_IMAGE" \
            telcoin keytool generate observer \
            --datadir /home/nonroot \
            --address "$OBSERVER_ADDRESS" \
            --external-primary-addr "${PRIMARY_MULTIADDR}" \
            --external-worker-addrs "${WORKER_MULTIADDR}"; then
            print_ok "Observer keys generated in: ${DATA_DIR}/node-keys/"
        else
            print_error "Key generation failed."
            exit 1
        fi
    else
        if "$BINARY_PATH" keytool generate observer \
            --datadir "$DATA_DIR" \
            --address "$OBSERVER_ADDRESS" \
            --external-primary-addr "${PRIMARY_MULTIADDR}" \
            --external-worker-addrs "${WORKER_MULTIADDR}"; then
            print_ok "Observer keys generated in: ${DATA_DIR}/node-keys/"
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
    print_ok "Passphrase stored (mode 600): ${passphrase_file}"

    bls_passphrase=""
    bls_passphrase_confirm=""
    print_ok "Observer keys ready"
}

step_write_config() {
    print_header "Step 7 of 7: Writing Configuration"

    local genesis_dir="${DATA_DIR}/genesis"
    mkdir -p "$genesis_dir"
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "$genesis_dir"

    local chain_subdir
    [[ "$NETWORK" == "testnet" ]] && chain_subdir="testnet" || chain_subdir="mainnet"

    local chain_configs_found=false
    local search_paths=(
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
            print_ok "Chain config files copied to ${DATA_DIR}"
            chain_configs_found=true
            break
        fi
    done

    if [[ "$chain_configs_found" == "false" ]]; then
        print_warn "Chain config files not found automatically."
        echo ""
        print_info "Copy these files from the Telcoin Network repo:"
        print_info "  https://github.com/Telcoin-Association/telcoin-network/tree/main/chain-configs/${chain_subdir}/"
        echo ""
        read -r -p "  Press Enter once you have copied the chain config files: "
    fi

    if [[ "$ENABLE_PUBLIC_RPC" == "true" ]]; then
        _write_nginx_config
    fi

    print_ok "Configuration ready under: ${DATA_DIR}"
}

_write_nginx_config() {
    local nginx_snippet="${CONFIG_DIR}/nginx-rpc-example.conf"
    print_info "Writing nginx reverse proxy example to: ${nginx_snippet}"
    cat > "$nginx_snippet" <<'EOF'
# Example nginx reverse proxy for Telcoin Network observer RPC
limit_req_zone $binary_remote_addr zone=rpc_limit:10m rate=100r/s;

server {
    listen 443 ssl http2;
    server_name rpc.yourdomain.com;

    ssl_certificate     /etc/letsencrypt/live/rpc.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/rpc.yourdomain.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        limit_req zone=rpc_limit burst=20 nodelay;
        proxy_pass http://127.0.0.1:8545;
        proxy_http_version 1.1;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 60s;
    }
}

server {
    listen 80;
    server_name rpc.yourdomain.com;
    return 301 https://$host$request_uri;
}
EOF
    print_ok "Nginx example written: ${nginx_snippet}"
}

step_create_service() {
    print_header "Step 7 of 7: Creating Systemd Service"

    print_info "The --instance flag affects the RPC port: 8545 - (instance - 1)"
    print_info "  Instance 5 -> RPC port 8541 (default for observers)"
    echo ""
    local input
    read -r -p "  Instance number [5]: " input
    local instance="${input:-5}"
    RPC_PORT=$(( 8545 - (instance - 1) ))
    print_ok "Instance: ${instance}, RPC port: ${RPC_PORT}"

    local primary_multiaddr="$PRIMARY_LISTENER_MULTIADDR"
    local worker_multiaddr="$WORKER_LISTENER_MULTIADDR"
    print_info "P2P listener (internal): ${primary_multiaddr}"

    local metrics_addr="127.0.0.1:${METRICS_PORT}"
    local passphrase_file="${CONFIG_DIR}/bls-passphrase"

    local exec_cmd
    local bls_pass
    bls_pass=$(cat "${passphrase_file}" 2>/dev/null || echo '')

    if [[ "${INSTALL_METHOD:-}" == "docker" ]]; then
        local docker_uid docker_gid
        docker_uid=$(id -u "$SERVICE_USER" 2>/dev/null || echo "1101")
        docker_gid=$(id -g "$SERVICE_GROUP" 2>/dev/null || echo "1101")
        exec_cmd="docker run --rm \
--name ${SERVICE_NAME} \
--user ${docker_uid}:${docker_gid} \
--network=host \
-e TN_BLS_PASSPHRASE=${bls_pass} \
-e PRIMARY_LISTENER_MULTIADDR=${primary_multiaddr} \
-e WORKER_LISTENER_MULTIADDR=${worker_multiaddr} \
-v ${DATA_DIR}:/home/nonroot \
-v ${CONFIG_DIR}:/etc/telcoin/observer:ro \
${DOCKER_IMAGE} \
telcoin node \
--datadir /home/nonroot \
--observer \
--instance ${instance} \
--metrics ${metrics_addr} \
--log.stdout.format log-fmt \
-vvv \
--http"
    else
        exec_cmd="${BINARY_PATH} node \
--datadir ${DATA_DIR} \
--observer \
--instance ${instance} \
--metrics ${metrics_addr} \
--log.stdout.format log-fmt \
-vvv \
--http"
    fi

    local service_file="/etc/systemd/system/${SERVICE_NAME}.service"

    if [[ "${INSTALL_METHOD:-}" != "docker" ]]; then
        cat > "$service_file" <<EOF
[Unit]
Description=Telcoin Network Observer Node (${CHAIN_NAME})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
Environment="TN_BLS_PASSPHRASE=${bls_pass}"
Environment="PRIMARY_LISTENER_MULTIADDR=${primary_multiaddr}"
Environment="WORKER_LISTENER_MULTIADDR=${worker_multiaddr}"
ExecStart=${exec_cmd}
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
    else
        cat > "$service_file" <<EOF
[Unit]
Description=Telcoin Network Observer Node (${CHAIN_NAME}) [Docker]
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=root
ExecStartPre=-/usr/bin/docker rm -f ${SERVICE_NAME}
ExecStart=${exec_cmd}
ExecStop=docker stop ${SERVICE_NAME}
Restart=on-failure
RestartSec=10
StandardOutput=append:${LOG_DIR}/${SERVICE_NAME}.log
StandardError=append:${LOG_DIR}/${SERVICE_NAME}-error.log

[Install]
WantedBy=multi-user.target
EOF
    fi

    systemctl daemon-reload
    print_ok "Service file written: ${service_file}"

    local meta_file="/etc/telcoin/observer/.node-meta"
    mkdir -p "/etc/telcoin/observer"
    cat > "$meta_file" <<EOF
HOST_SERVICE_USER=${SERVICE_USER}
HOST_SERVICE_GROUP=${SERVICE_GROUP}
INSTALL_METHOD=${INSTALL_METHOD:-binary}
DOCKER_IMAGE=${DOCKER_IMAGE:-}
EOF
    chmod 600 "$meta_file"
    print_ok "Node metadata written: ${meta_file}"

    echo ""
    if confirm "Start the observer node now?"; then
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
        check_rpc_alive "$local_rpc" 15 6 || print_warn "RPC not yet responding -- normal during initial sync."

        if confirm "Enable auto-start on server reboot?"; then
            systemctl enable "$SERVICE_NAME"
            print_ok "Auto-start enabled"
        fi
    fi
}

step_final_summary() {
    print_summary "Observer Node Setup Complete" \
        "Network=${NETWORK} (Chain ID: ${CHAIN_ID})" \
        "Node type=Observer" \
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

    echo "  P2P Listener addresses (set in systemd service):"
    echo "    Primary: ${PRIMARY_MULTIADDR}"
    echo "    Worker:  ${WORKER_MULTIADDR}"
    echo ""
    print_info "No router port forwarding is required for observer nodes."
    echo ""
    echo "  Useful commands:"
    echo ""
    echo "  View logs:"
    echo "    journalctl -u ${SERVICE_NAME} -f"
    echo ""
    echo "  Check sync status:"
    echo "    curl -s -X POST -H 'Content-Type: application/json' \\"
    echo "      --data '{\"jsonrpc\":\"2.0\",\"method\":\"eth_syncing\",\"params\":[],\"id\":1}' \\"
    echo "      http://127.0.0.1:${RPC_PORT}"
    echo ""
    echo "  Stop / restart:"
    echo "    systemctl stop ${SERVICE_NAME}"
    echo "    systemctl restart ${SERVICE_NAME}"
    echo ""
    print_sep
    echo ""
    print_info "Next steps:"
    echo "  1. Wait for the node to finish syncing"
    echo "  2. Run the health check: bash check-node.sh --observer"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    step_welcome
    step_preflight
    step_network
    step_config
    step_install_binary
    step_create_infrastructure
    step_generate_keys
    step_write_config
    step_create_service
    step_final_summary
}

main "$@"
