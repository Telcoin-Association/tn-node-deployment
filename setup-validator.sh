#!/usr/bin/env bash
# =============================================================================
# setup-validator.sh -- Telcoin Network Validator Node Setup
#
# USAGE:
#   sudo bash setup-validator.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

readonly SCRIPT_VERSION="1.0.5"
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
PRIMARY_MULTIADDR=""
WORKER_MULTIADDR=""
P2P_PORT="$DEFAULT_P2P_PORT"
RPC_PORT="$DEFAULT_RPC_PORT"
METRICS_PORT="$DEFAULT_METRICS_PORT"
TN_SOURCE_DIR="/opt/telcoin-source"

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
    echo "  ${BOLD}Telcoin Network -- Validator Node Setup  v${SCRIPT_VERSION}${RESET}"
    echo ""
    print_sep
    echo ""
    print_info "This script will set up a VALIDATOR node on the Telcoin Network."
    print_info "Prerequisites:"
    echo "    * You have received validator approval from the Telcoin Association"
    echo "    * You have a dedicated server with a static IP address"
    echo "    * You are running this script as root (sudo)"
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
    print_header "Step 2 of 8: Network Selection"
    select_network
}

step_config() {
    print_header "Step 3 of 8: Node Configuration"

    echo "  Port configuration (press Enter to accept defaults):"
    echo ""

    local input
    read -r -p "  P2P port        [${P2P_PORT}]: " input;     P2P_PORT="${input:-$P2P_PORT}"
    read -r -p "  RPC port        [${RPC_PORT}]: " input;     RPC_PORT="${input:-$RPC_PORT}"
    read -r -p "  Metrics port    [${METRICS_PORT}]: " input; METRICS_PORT="${input:-$METRICS_PORT}"

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
    print_header "Step 4 of 8: Installing Binary"
    select_install_method

    case "$INSTALL_METHOD" in
        source)   install_from_source ;;
        binary)   install_prebuilt_binary ;;
        docker)   setup_docker ;;
        existing) use_existing_binary ;;
    esac
}

install_from_source() {
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

install_prebuilt_binary() {
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

setup_docker() {
    print_step "Docker..."
    echo ""
    print_warn "Official Docker Hub image is coming soon."
    print_info "The public Docker Hub image will be available at:"
    print_info "  docker pull telcoin/telcoin-network:latest  (coming soon)"
    echo ""
    print_warn "This option is not yet available -- please choose another method."
    echo ""
    read -r -p "  Press Enter to return to the install method menu..."
    echo ""
    step_install_binary
}
use_existing_binary() {
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
    print_header "Step 5 of 8: Creating System Infrastructure"
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
    print_header "Step 6 of 8: Validator Key Management"

    print_info "Your validator needs a BLS key for consensus signing."
    echo ""

    if [[ -d "${DATA_DIR}/node-keys" ]]; then
        print_warn "Key files already exist in ${DATA_DIR}/node-keys/"
        if ! confirm "Overwrite existing keys?"; then
            print_ok "Keeping existing keys"
            return 0
        fi
    fi

    read -r -p "  Validator execution address (0x...): " VALIDATOR_ADDRESS
    if [[ ! "$VALIDATOR_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        print_warn "Address format looks unusual. Proceeding anyway."
    fi

    local public_ip
    public_ip=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null || echo "0.0.0.0")

    local default_primary="/ip4/${public_ip}/udp/49590/quic-v1"
    read -r -p "  Primary listener multiaddr [${default_primary}]: " input
    PRIMARY_MULTIADDR="${input:-$default_primary}"

    local default_worker="/ip4/${public_ip}/udp/49594/quic-v1"
    read -r -p "  Worker listener multiaddr  [${default_worker}]: " input
    WORKER_MULTIADDR="${input:-$default_worker}"

    echo ""
    print_warn "Set a passphrase to encrypt your BLS validator key."
    print_warn "Store this securely -- you need it every time the node starts."
    echo ""

    local bls_passphrase bls_passphrase_confirm
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

    print_step "Generating validator keys..."
    export TN_BLS_PASSPHRASE="$bls_passphrase"

    if "$BINARY_PATH" keytool generate validator \
        --datadir "$DATA_DIR" \
        --address "$VALIDATOR_ADDRESS" \
        --external-primary-addr "$PRIMARY_MULTIADDR" \
        --external-worker-addrs "$WORKER_MULTIADDR"; then
        print_ok "Validator keys generated in: ${DATA_DIR}/node-keys/"
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

    # Display node-info.yaml so operator knows what to send to the Association
    display_node_info "$DATA_DIR"

    echo ""
    print_warn "BACK UP YOUR KEYS NOW."
    print_info "If ${DATA_DIR}/node-keys/ is lost, you must re-register with the Association."
    echo ""
    read -r -p "  Press Enter to confirm you have backed up your keys: "
}

step_write_config() {
    print_header "Step 7 of 8: Writing Configuration"

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
            print_ok "Chain config files copied"
            chain_configs_found=true
            break
        fi
    done

    if [[ "$chain_configs_found" == "false" ]]; then
        print_warn "Chain config files not found automatically."
        print_info "Copy from: https://github.com/Telcoin-Association/telcoin-network/tree/main/chain-configs/${chain_subdir}/"
        print_info "  genesis.yaml    -> ${genesis_dir}/genesis.yaml"
        print_info "  committee.yaml  -> ${genesis_dir}/committee.yaml"
        print_info "  parameters.yaml -> ${DATA_DIR}/parameters.yaml"
        echo ""
        read -r -p "  Press Enter once you have copied the chain config files: "
    fi

    print_ok "Configuration ready under: ${DATA_DIR}"
}

step_create_service() {
    print_header "Step 8 of 8: Creating Systemd Service"

    print_info "Instance number affects RPC port: 8545 - (instance - 1)"
    print_info "  Instance 1 -> RPC port 8545 (default for validators)"
    echo ""
    local input
    read -r -p "  Instance number [1]: " input
    local instance="${input:-1}"
    RPC_PORT=$(( 8545 - (instance - 1) ))
    print_ok "Instance: ${instance}, RPC port: ${RPC_PORT}"

    # --- Network binding selection ---
    echo ""
    echo "  Network binding -- how the node listens for P2P connections:"
    echo ""
    echo "  1) IPv6  -- listen on all IPv6 interfaces"
    echo "              NAT-free, no router port forward needed"
    echo ""
    echo "  2) IPv4  -- listen on a specific IPv4 address"
    echo "              requires TCP/UDP port 30303 forwarded on your router"
    echo ""

    local bind_choice
    while true; do
        read -r -p "  Enter choice [1/2]: " bind_choice
        case "$bind_choice" in
            1)
                local primary_multiaddr="/ip6/::/udp/49590/quic-v1"
                local worker_multiaddr="/ip6/::/udp/49594/quic-v1"
                print_ok "Binding: IPv6"
                break
                ;;
            2)
                # Detect internal IP for IPv4 binding
                select_listener_ip
                local primary_multiaddr="/ip4/${LISTENER_IP}/udp/49590/quic-v1"
                local worker_multiaddr="/ip4/${LISTENER_IP}/udp/49594/quic-v1"
                print_ok "Binding: IPv4 (${LISTENER_IP})"
                print_info "Ensure TCP/UDP port 30303 is forwarded to this server on your router."
                break
                ;;
            *)
                print_warn "Please enter 1 or 2."
                ;;
        esac
    done
    local metrics_addr="127.0.0.1:${METRICS_PORT}"
    local passphrase_file="${CONFIG_DIR}/bls-passphrase"

    local exec_cmd="${BINARY_PATH} node \
--datadir ${DATA_DIR} \
--instance ${instance} \
--metrics ${metrics_addr} \
--log.stdout.format log-fmt \
-vvv \
--http"

    local service_file="/etc/systemd/system/${SERVICE_NAME}.service"

    # Read the passphrase now so it gets embedded as a literal value
    local bls_pass
    bls_pass=$(cat "${passphrase_file}" 2>/dev/null || echo '')

    cat > "$service_file" <<EOF
[Unit]
Description=Telcoin Network Validator Node (${CHAIN_NAME})
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
    if confirm "Start the validator node now?"; then
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

        # Check validator on-chain status
        echo ""
        check_validator_onchain_status "$VALIDATOR_ADDRESS" "$local_rpc"

        if confirm "Enable auto-start on server reboot?"; then
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
    echo "  1. Allow inbound TCP on port ${P2P_PORT} in your firewall"
    echo "  2. Register your node-info.yaml with the Telcoin Association"
    echo "  3. Run the health check: bash check-node.sh"
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
