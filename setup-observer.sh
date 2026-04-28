#!/usr/bin/env bash
# =============================================================================
# setup-observer.sh -- Telcoin Network Observer Node Setup
#
# USAGE:
#   sudo bash setup-observer.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

readonly SCRIPT_VERSION="1.0.1"
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
RPC_PORT="$DEFAULT_RPC_PORT"
METRICS_PORT="$DEFAULT_METRICS_PORT"
ENABLE_PUBLIC_RPC="false"
TN_SOURCE_DIR="/opt/telcoin-source"
OBSERVER_ADDRESS=""

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
    echo "     ╚═╝   ╚══════╝╚══════╝ ╚═════╝ ╚═════╝ ╚═╝╚═╝  ╚═══╝${RESET}"
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
    check_hardware
    check_internet
    check_ports "$P2P_PORT" "$RPC_PORT" "$METRICS_PORT"

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
    echo "  1) Private -- RPC accessible from this server only (recommended)"
    echo "  2) Public  -- RPC accessible from the internet"
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
    read -r -p "  P2P port        [${P2P_PORT}]: " input;     P2P_PORT="${input:-$P2P_PORT}"
    read -r -p "  RPC port        [${RPC_PORT}]: " input;     RPC_PORT="${input:-$RPC_PORT}"
    read -r -p "  Metrics port    [${METRICS_PORT}]: " input; METRICS_PORT="${input:-$METRICS_PORT}"

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
        git -C "$source_dir" pull
    else
        print_info "Cloning repository..."
        git clone --recurse-submodules "$TN_REPO" "$source_dir"
    fi


    print_info "Building release binary (this takes 20-40 minutes)..."
    cd "$source_dir"
    cargo build --release 2>&1 | tee /tmp/tn-build.log

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
    print_step "Downloading pre-built binary..."

    local api_url="https://api.github.com/repos/Telcoin-Association/telcoin-network/releases/latest"
    local release_info
    release_info=$(curl -s --max-time 30 "$api_url" 2>/dev/null || echo "")

    local DOWNLOAD_URL=""
    if [[ -n "$release_info" ]]; then
        local arch
        arch=$(uname -m)
        DOWNLOAD_URL=$(echo "$release_info" | \
            grep -o '"browser_download_url":"[^"]*linux[^"]*'"${arch}"'[^"]*"' | \
            grep -v '.sha256' | head -1 | cut -d'"' -f4)
    fi

    if [[ -z "$DOWNLOAD_URL" ]]; then
        print_warn "Could not detect download URL automatically."
        echo "$release_info" | grep '"browser_download_url"' | \
            grep -o '"[^"]*"$' | tr -d '"' 2>/dev/null || true
        echo ""
        read -r -p "  Paste the download URL: " DOWNLOAD_URL
    fi

    mkdir -p "$INSTALL_DIR"
    curl -L --progress-bar -o "${INSTALL_DIR}/telcoin" "$DOWNLOAD_URL"
    chmod +x "${INSTALL_DIR}/telcoin-network"
    BINARY_PATH="${INSTALL_DIR}/telcoin-network"

    local checksum_url="${DOWNLOAD_URL}.sha256"
    local checksum_file="${INSTALL_DIR}/telcoin.sha256"
    if curl -s --max-time 10 -o "$checksum_file" "$checksum_url" 2>/dev/null && \
       [[ -s "$checksum_file" ]]; then
        if (cd "$INSTALL_DIR" && sha256sum -c "$checksum_file" &>/dev/null); then
            print_ok "Checksum verified"
        else
            print_error "Checksum FAILED -- binary may be corrupted."
            exit 1
        fi
    else
        print_warn "No checksum available -- skipping integrity check."
    fi

    print_ok "Binary installed: ${BINARY_PATH}"
}

_setup_docker() {
    print_step "Setting up Docker..."

    if ! check_docker; then
        case "$PKG_MANAGER" in
            apt)
                apt-get install -y ca-certificates curl gnupg
                install -m 0755 -d /etc/apt/keyrings
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
                    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                chmod a+r /etc/apt/keyrings/docker.gpg
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
                    https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
                    tee /etc/apt/sources.list.d/docker.list > /dev/null
                apt-get update -qq
                apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
                systemctl start docker
                systemctl enable docker
                ;;
            *)
                print_error "Cannot auto-install Docker. See: https://docs.docker.com/engine/install/"
                exit 1
                ;;
        esac
    fi

    local image_name="ghcr.io/telcoin-association/telcoin-network:latest"
    docker pull "$image_name"

    mkdir -p "$INSTALL_DIR"
    cat > "${INSTALL_DIR}/telcoin" <<EOF
#!/usr/bin/env bash
exec docker run --rm \
    -v "${DATA_DIR}:/data" \
    -v "${CONFIG_DIR}:/config" \
    -p "${P2P_PORT}:${P2P_PORT}" \
    -p "${RPC_PORT}:${RPC_PORT}" \
    -p "${METRICS_PORT}:${METRICS_PORT}" \
    ${image_name} "\$@"
EOF
    chmod +x "${INSTALL_DIR}/telcoin-network"
    BINARY_PATH="${INSTALL_DIR}/telcoin-network"
    print_ok "Docker wrapper written: ${BINARY_PATH}"
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
    create_service_user

    # The telcoin-network binary (built on reth) writes internal logs to
    # ~/.cache/reth/logs/ — we need to create this for the service user
    print_step "Creating reth cache directory..."
    mkdir -p "/home/${SERVICE_USER}/.cache/reth/logs/telcoin-network-logs"
    chown -R "${SERVICE_USER}:${SERVICE_USER}" "/home/${SERVICE_USER}"
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

    if "$BINARY_PATH" keytool generate observer \
        --datadir "$DATA_DIR" \
        --address "$OBSERVER_ADDRESS"; then
        print_ok "Observer keys generated in: ${DATA_DIR}/node-keys/"
    else
        print_error "Key generation failed."
        print_info "  Check binary path: ${BINARY_PATH}"
        print_info "  Check ${DATA_DIR} exists"
        exit 1
    fi

    unset TN_BLS_PASSPHRASE

    # Fix ownership so the telcoin service user can read the keys at runtime
    chown -R "${SERVICE_USER}:${SERVICE_USER}" "$DATA_DIR"

    local passphrase_file="${CONFIG_DIR}/bls-passphrase"
    echo "$bls_passphrase" > "$passphrase_file"
    chmod 600 "$passphrase_file"
    chown "${SERVICE_USER}:${SERVICE_USER}" "$passphrase_file"
    print_ok "Passphrase stored (mode 600): ${passphrase_file}"

    bls_passphrase=""
    bls_passphrase_confirm=""
    print_ok "Observer keys ready"
}

step_write_config() {
    print_header "Step 7 of 7: Writing Configuration"

    local genesis_dir="${DATA_DIR}/genesis"
    mkdir -p "$genesis_dir"
    chown -R "${SERVICE_USER}:${SERVICE_USER}" "$genesis_dir"

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
            chown -R "${SERVICE_USER}:${SERVICE_USER}" "$genesis_dir" "${DATA_DIR}/parameters.yaml"
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
        print_info ""
        print_info "  genesis.yaml    -> ${genesis_dir}/genesis.yaml"
        print_info "  committee.yaml  -> ${genesis_dir}/committee.yaml"
        print_info "  parameters.yaml -> ${DATA_DIR}/parameters.yaml"
        echo ""
        read -r -p "  Press Enter once you have copied the chain config files: "

        for f in "${genesis_dir}/genesis.yaml" "${genesis_dir}/committee.yaml" "${DATA_DIR}/parameters.yaml"; do
            if [[ -f "$f" ]]; then
                print_ok "Found: ${f}"
            else
                print_warn "Missing: ${f} -- node may not start without this file."
            fi
        done
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
# Copy to /etc/nginx/sites-available/telcoin-rpc and adapt for your domain.
# Prerequisites: sudo apt install nginx certbot python3-certbot-nginx

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

    # --- Network binding selection ---
    echo ""
    echo "  Network binding -- how the node listens for P2P connections:"
    echo ""
    echo "  1) IPv6  -- recommended, NAT-free, no router port forward needed"
    echo "              (/ip6/::/udp/49590/quic-v1)"
    echo ""
    echo "  2) IPv4  -- requires TCP/UDP port 30303 forwarded on your router"
    echo "              (/ip4/0.0.0.0/udp/49590/quic-v1)"
    echo ""
    echo "  3) Both  -- listens on IPv4 and IPv6 simultaneously"
    echo "              maximises peer connectivity"
    echo ""

    local bind_choice
    while true; do
        read -r -p "  Enter choice [1/2/3]: " bind_choice
        case "$bind_choice" in
            1)
                local primary_multiaddr="/ip6/::/udp/49590/quic-v1"
                local worker_multiaddr="/ip6/::/udp/49594/quic-v1"
                print_ok "Binding: IPv6"
                break
                ;;
            2)
                local primary_multiaddr="/ip4/0.0.0.0/udp/49590/quic-v1"
                local worker_multiaddr="/ip4/0.0.0.0/udp/49594/quic-v1"
                print_ok "Binding: IPv4"
                print_info "Ensure TCP/UDP port 30303 is forwarded to this server on your router."
                break
                ;;
            3)
                local primary_multiaddr="/ip4/0.0.0.0/udp/49590/quic-v1,/ip6/::/udp/49590/quic-v1"
                local worker_multiaddr="/ip4/0.0.0.0/udp/49594/quic-v1,/ip6/::/udp/49594/quic-v1"
                print_ok "Binding: IPv4 and IPv6"
                print_info "Ensure TCP/UDP port 30303 is forwarded to this server on your router."
                print_warn "Confirm with the Telcoin dev team that multiple listener addresses are supported."
                break
                ;;
            *)
                print_warn "Please enter 1, 2, or 3."
                ;;
        esac
    done

    local metrics_addr="127.0.0.1:${METRICS_PORT}"
    local passphrase_file="${CONFIG_DIR}/bls-passphrase"

    local exec_cmd="${BINARY_PATH} node \
--datadir ${DATA_DIR} \
--observer \
--instance ${instance} \
--metrics ${metrics_addr} \
--log.stdout.format log-fmt \
-vvv \
--http"

    local service_file="/etc/systemd/system/${SERVICE_NAME}.service"

    # Read the passphrase now so it gets embedded as a literal value in the
    # service file — systemd does not execute subshells in Environment= lines
    local bls_pass
    bls_pass=$(cat "${passphrase_file}" 2>/dev/null || echo '')

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
Group=${SERVICE_USER}
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

    systemctl daemon-reload
    print_ok "Service file written: ${service_file}"

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
        "P2P port=${P2P_PORT}" \
        "RPC port=${RPC_PORT}" \
        "Metrics port=${METRICS_PORT}" \
        "Systemd service=${SERVICE_NAME}" \
        "Explorer=${EXPLORER_URL}"

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
    echo "  1. Allow inbound TCP on port ${P2P_PORT} in your firewall"
    echo "  2. Wait for the node to finish syncing"
    echo "  3. Run the health check: bash check-node.sh --observer"
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
