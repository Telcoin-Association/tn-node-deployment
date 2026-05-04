#!/usr/bin/env bash
# =============================================================================
# edit-config.sh -- Telcoin Network Node Configuration Editor
#
# Edit the configuration of a running validator or observer node without
# manually editing systemd service files. Changes take effect on next restart.
#
# USAGE:
#   sudo bash edit-config.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

readonly SCRIPT_VERSION="1.1.9"
readonly VALIDATOR_SERVICE="telcoin-validator"
readonly OBSERVER_SERVICE="telcoin-observer"
readonly VALIDATOR_SERVICE_FILE="/etc/systemd/system/telcoin-validator.service"
readonly OBSERVER_SERVICE_FILE="/etc/systemd/system/telcoin-observer.service"

TARGET_SERVICE=""
TARGET_SERVICE_FILE=""
NODE_TYPE=""

# =============================================================================
# HELPERS
# =============================================================================

# Read a value from the service file Environment= lines
read_env_var() {
    local var_name="$1"
    local service_file="$2"
    grep "Environment=\"${var_name}=" "$service_file" 2>/dev/null | \
        sed "s/.*Environment=\"${var_name}=//;s/\"//"
}

# Read the ExecStart line from the service file
read_exec_start() {
    local service_file="$1"
    grep "^ExecStart=" "$service_file" 2>/dev/null | sed 's/^ExecStart=//'
}

# Extract a specific flag value from the ExecStart line
read_flag() {
    local flag="$1"
    local exec_start="$2"
    echo "$exec_start" | awk -v f="$flag" '{
        for(i=1;i<=NF;i++) {
            if($i==f && i+1<=NF) {
                print $(i+1)
                exit
            }
        }
    }'
}

# Check if a flag exists in ExecStart
has_flag() {
    local flag="$1"
    local exec_start="$2"
    # Use awk to avoid grep treating --flags as grep options
    echo "$exec_start" | awk -v f="$flag" '{
        for(i=1;i<=NF;i++) {
            if($i==f) exit 0
        }
        exit 1
    }'
}

# Check if a flag exists in a file
has_flag_in_file() {
    local flag="$1"
    local service_file="$2"
    awk -v f="$flag" '{
        for(i=1;i<=NF;i++) {
            if($i==f) exit 0
        }
    } END{exit 1}' "$service_file"
}

# Replace or add an Environment= line in the service file
set_env_var() {
    local var_name="$1"
    local new_value="$2"
    local service_file="$3"

    if grep -q "Environment=\"${var_name}=" "$service_file"; then
        # Replace existing
        sed -i "s|Environment=\"${var_name}=.*\"|Environment=\"${var_name}=${new_value}\"|" "$service_file"
    else
        # Add after the last Environment= line
        sed -i "/^Environment=/a Environment=\"${var_name}=${new_value}\"" "$service_file"
    fi
}

# Replace a flag value in the ExecStart line
set_flag_value() {
    local flag="$1"
    local new_value="$2"
    local service_file="$3"
    perl -i -pe "s|\Q${flag}\E [^ ]*|${flag} ${new_value}|" "$service_file"
}

# Add a flag to ExecStart if not present
add_flag() {
    local flag="$1"
    local service_file="$2"
    if ! has_flag_in_file "$flag" "$service_file"; then
        sed -i "s|^ExecStart=\(.*\)$|ExecStart=\1 ${flag}|" "$service_file"
    fi
}

# Remove a flag from ExecStart
remove_flag() {
    local flag="$1"
    local service_file="$2"
    # Use perl for literal string removal to avoid regex issues with --flags
    perl -i -pe "s| \Q${flag}\E||g" "$service_file"
}

# Replace verbosity flags (-vvv, -vvvv etc) in ExecStart
set_verbosity() {
    local new_verbosity="$1"
    local service_file="$2"
    sed -i "s| -v\+ | ${new_verbosity} |" "$service_file"
}

# Apply changes: reload systemd and optionally restart
apply_changes() {
    set +e  # Restart failure should not exit the script
    print_step "Applying changes..."
    systemctl daemon-reload
    print_ok "systemd reloaded"

    echo ""
    if confirm "Restart the node now to apply changes?"; then
        print_step "Restarting ${TARGET_SERVICE}..."
        systemctl restart "$TARGET_SERVICE" || true
        sleep 3
        if systemctl is-active --quiet "$TARGET_SERVICE"; then
            print_ok "Node restarted successfully"
        else
            print_error "Node failed to restart. Check logs:"
            print_info "  sudo tail -30 /var/log/telcoin/${TARGET_SERVICE}.log"
            print_info "  journalctl -u ${TARGET_SERVICE} --no-pager -n 30"
        fi
    else
        print_info "Changes saved. Restart the node when ready:"
        print_info "  sudo systemctl restart ${TARGET_SERVICE}"
    fi
    echo ""
    read -r -p "  Press Enter to return to menu..."
    set -e
}

# =============================================================================
# NODE DETECTION
# =============================================================================

detect_node() {
    local validator_exists=false
    local observer_exists=false

    [[ -f "$VALIDATOR_SERVICE_FILE" ]] && validator_exists=true
    [[ -f "$OBSERVER_SERVICE_FILE" ]]  && observer_exists=true

    if [[ "$validator_exists" == "false" ]] && [[ "$observer_exists" == "false" ]]; then
        print_error "No Telcoin node installation found."
        print_info "Run setup-validator.sh or setup-observer.sh first."
        exit 1
    fi

    if [[ "$validator_exists" == "true" ]] && [[ "$observer_exists" == "true" ]]; then
        echo ""
        print_info "Both a validator and observer node are installed."
        echo ""
        echo "  1) Validator node"
        echo "  2) Observer node"
        echo ""
        local choice
        while true; do
            read -r -p "  Which node do you want to configure? [1/2]: " choice
            case "$choice" in
                1) TARGET_SERVICE="$VALIDATOR_SERVICE"; TARGET_SERVICE_FILE="$VALIDATOR_SERVICE_FILE"; NODE_TYPE="validator"; break ;;
                2) TARGET_SERVICE="$OBSERVER_SERVICE";  TARGET_SERVICE_FILE="$OBSERVER_SERVICE_FILE";  NODE_TYPE="observer";  break ;;
                *) print_warn "Please enter 1 or 2." ;;
            esac
        done
    elif [[ "$validator_exists" == "true" ]]; then
        TARGET_SERVICE="$VALIDATOR_SERVICE"
        TARGET_SERVICE_FILE="$VALIDATOR_SERVICE_FILE"
        NODE_TYPE="validator"
        print_ok "Detected: validator node"
    else
        TARGET_SERVICE="$OBSERVER_SERVICE"
        TARGET_SERVICE_FILE="$OBSERVER_SERVICE_FILE"
        NODE_TYPE="observer"
        print_ok "Detected: observer node"
    fi
}

# =============================================================================
# DISPLAY CURRENT CONFIG
# =============================================================================

show_current_config() {
    set +e  # Disable exit-on-error for config reading -- grep returning no match is fine
    print_header "Current Configuration -- ${NODE_TYPE}"

    local exec_start
    exec_start=$(read_exec_start "$TARGET_SERVICE_FILE")

    local primary_multiaddr worker_multiaddr instance metrics verbosity rpc_enabled bls_pass_set
    local is_docker=false
    local docker_image=""

    # Detect if this is a Docker install
    if echo "$exec_start" | grep -qF "docker run"; then
        is_docker=true
        docker_image=$(echo "$exec_start" | grep -oE 'us-docker[^ ]+|gcr\.io[^ ]+|ghcr\.io[^ ]+' | head -1 || true)
        if [[ -z "$docker_image" ]]; then
            docker_image=$(echo "$exec_start" | awk '{for(i=1;i<=NF;i++) if($i ~ /:[a-z0-9]/) print $i}' | tail -1 || true)
        fi
    fi

    primary_multiaddr=$(read_env_var "PRIMARY_LISTENER_MULTIADDR" "$TARGET_SERVICE_FILE" || true)
    # For Docker, multiaddrs are in ExecStart not Environment lines
    if [[ -z "$primary_multiaddr" ]]; then
        primary_multiaddr=$(echo "$exec_start" | grep -oE 'PRIMARY_LISTENER_MULTIADDR=[^ ]+' | cut -d= -f2 || true)
    fi

    worker_multiaddr=$(read_env_var "WORKER_LISTENER_MULTIADDR" "$TARGET_SERVICE_FILE" || true)
    if [[ -z "$worker_multiaddr" ]]; then
        worker_multiaddr=$(echo "$exec_start" | grep -oE 'WORKER_LISTENER_MULTIADDR=[^ ]+' | cut -d= -f2 || true)
    fi

    instance=$(read_flag "--instance" "$exec_start")
    metrics=$(read_flag "--metrics" "$exec_start")
    bls_pass_set="(set)"

    # Service user/group
    local svc_user svc_group
    svc_user=$(grep "^User=" "$TARGET_SERVICE_FILE" 2>/dev/null | cut -d= -f2)
    svc_group=$(grep "^Group=" "$TARGET_SERVICE_FILE" 2>/dev/null | cut -d= -f2)

    # Detect verbosity
    if echo "$exec_start" | grep -q "\-vvvvv"; then      verbosity="TRACE (-vvvvv)"
    elif echo "$exec_start" | grep -q "\-vvvv"; then     verbosity="DEBUG (-vvvv)"
    elif echo "$exec_start" | grep -q "\-vvv"; then      verbosity="INFO  (-vvv)"
    elif echo "$exec_start" | grep -q "\-vv"; then       verbosity="WARN  (-vv)"
    elif echo "$exec_start" | grep -q "\-v[^v]"; then    verbosity="ERROR (-v)"
    else                                                  verbosity="unknown"
    fi || true

    # Detect RPC status
    if has_flag "--http" "$exec_start"; then
        local rpc_addr
        rpc_addr=$(read_flag "--http.addr" "$exec_start")
        if [[ -z "$rpc_addr" ]] || [[ "$rpc_addr" == "127.0.0.1" ]]; then
            rpc_enabled="Enabled (private -- localhost only)"
        else
            rpc_enabled="Enabled (public -- ${rpc_addr})"
        fi
    else
        rpc_enabled="Disabled"
    fi

    # Service status
    local status
    if systemctl is-active --quiet "$TARGET_SERVICE" 2>/dev/null; then
        status="Running"
    else
        status="Stopped"
    fi

    echo ""
    printf "  %-28s %s\n" "Service status:"        "$status"
    printf "  %-28s %s\n" "Node type:"             "$NODE_TYPE"
    local install_method_label="Binary"
    [[ "$is_docker" == "true" ]] && install_method_label="Docker"
    printf "  %-28s %s\n" "Install method:"        "$install_method_label"
    [[ "$is_docker" == "true" ]] && printf "  %-28s %s\n" "Docker image:" "${docker_image:-unknown}" || true
    printf "  %-28s %s\n" "Service user:"          "${svc_user:-unknown}"
    printf "  %-28s %s\n" "Service group:"         "${svc_group:-unknown}"
    printf "  %-28s %s\n" "Instance number:"       "${instance:-unknown}"
    printf "  %-28s %s\n" "Metrics address:"       "${metrics:-unknown}"
    printf "  %-28s %s\n" "Primary listener:"      "${primary_multiaddr:-unknown}"
    printf "  %-28s %s\n" "Worker listener:"       "${worker_multiaddr:-unknown}"
    printf "  %-28s %s\n" "Log verbosity:"         "$verbosity"
    printf "  %-28s %s\n" "RPC:"                   "$rpc_enabled"
    printf "  %-28s %s\n" "BLS passphrase:"        "$bls_pass_set"
    echo ""
    set -e  # Restore exit-on-error
}

# =============================================================================
# EDIT FUNCTIONS
# =============================================================================

edit_listener_addresses() {
    set +e
    print_header "Edit Listener Addresses"

    local exec_start
    exec_start=$(read_exec_start "$TARGET_SERVICE_FILE")

    local current_primary current_worker
    current_primary=$(read_env_var "PRIMARY_LISTENER_MULTIADDR" "$TARGET_SERVICE_FILE" || true)
    if [[ -z "$current_primary" ]]; then
        current_primary=$(echo "$exec_start" | grep -oE 'PRIMARY_LISTENER_MULTIADDR=[^ ]+' | cut -d= -f2 || true)
    fi
    current_worker=$(read_env_var "WORKER_LISTENER_MULTIADDR" "$TARGET_SERVICE_FILE" || true)
    if [[ -z "$current_worker" ]]; then
        current_worker=$(echo "$exec_start" | grep -oE 'WORKER_LISTENER_MULTIADDR=[^ ]+' | cut -d= -f2 || true)
    fi

    print_info "Current primary: ${current_primary:-unknown}"
    print_info "Current worker:  ${current_worker:-unknown}"
    echo ""
    print_info "Choose new binding:"
    echo ""
    echo "  1) IPv6   -- listen on all IPv6 interfaces (NAT-free, recommended for cloud)"
    echo "  2) IPv4   -- listen on IPv4 (home/NAT or dedicated server)"
    echo "  3) Custom -- enter multiaddrs manually"
    echo ""

    local new_primary new_worker
    local choice
    while true; do
        read -r -p "  Enter choice [1/2/3]: " choice
        case "$choice" in
            1)
                new_primary="/ip6/::/udp/${DEFAULT_P2P_PORT}/quic-v1"
                new_worker="/ip6/::/udp/${DEFAULT_WORKER_PORT}/quic-v1"
                print_ok "Binding: IPv6"
                break
                ;;
            2)
                new_primary="/ip4/0.0.0.0/udp/${DEFAULT_P2P_PORT}/quic-v1"
                new_worker="/ip4/0.0.0.0/udp/${DEFAULT_WORKER_PORT}/quic-v1"
                print_ok "Binding: IPv4 all interfaces (0.0.0.0)"
                print_info "Node will accept connections on all IPv4 interfaces."
                break
                ;;
            3)
                read -r -p "  Primary listener multiaddr: " new_primary
                read -r -p "  Worker listener multiaddr:  " new_worker
                break
                ;;
            *) print_warn "Please enter 1, 2, or 3." ;;
        esac
    done

    # Update service file -- handle both binary and Docker installs
    if echo "$exec_start" | grep -qF "docker run"; then
        # Docker -- update ExecStart directly using perl
        perl -i -pe "s|PRIMARY_LISTENER_MULTIADDR=[^ ]+|PRIMARY_LISTENER_MULTIADDR=${new_primary}|g" "$TARGET_SERVICE_FILE"
        perl -i -pe "s|WORKER_LISTENER_MULTIADDR=[^ ]+|WORKER_LISTENER_MULTIADDR=${new_worker}|g" "$TARGET_SERVICE_FILE"
    else
        set_env_var "PRIMARY_LISTENER_MULTIADDR" "$new_primary" "$TARGET_SERVICE_FILE"
        set_env_var "WORKER_LISTENER_MULTIADDR"  "$new_worker"  "$TARGET_SERVICE_FILE"
    fi

    print_ok "Listener addresses updated"
    print_info "Primary: ${new_primary}"
    print_info "Worker:  ${new_worker}"
    set -e
    apply_changes
}

edit_instance_number() {
    print_header "Edit Instance Number"

    local exec_start current_instance
    exec_start=$(read_exec_start "$TARGET_SERVICE_FILE")
    current_instance=$(read_flag "--instance" "$exec_start")
    local current_rpc=$(( 8545 - (current_instance - 1) ))

    print_info "Current instance: ${current_instance} (RPC port: ${current_rpc})"
    echo ""
    print_info "Instance number affects the RPC port: 8545 - (instance - 1)"
    print_info "  Instance 1 -> RPC port 8545  (default for validators)"
    print_info "  Instance 5 -> RPC port 8541  (default for observers)"
    echo ""

    local new_instance
    read -r -p "  New instance number [${current_instance}]: " input
    new_instance="${input:-$current_instance}"

    local new_rpc=$(( 8545 - (new_instance - 1) ))
    set_flag_value "--instance" "$new_instance" "$TARGET_SERVICE_FILE"
    print_ok "Instance updated to ${new_instance} (RPC port: ${new_rpc})"
    apply_changes
}

edit_metrics() {
    print_header "Edit Metrics Address"

    local exec_start current_metrics
    exec_start=$(read_exec_start "$TARGET_SERVICE_FILE")
    current_metrics=$(read_flag "--metrics" "$exec_start")

    print_info "Current metrics address: ${current_metrics}"
    print_info "Format: IP:PORT (e.g. 127.0.0.1:9000)"
    echo ""

    local new_metrics
    read -r -p "  New metrics address [${current_metrics}]: " input
    new_metrics="${input:-$current_metrics}"

    set_flag_value "--metrics" "$new_metrics" "$TARGET_SERVICE_FILE"
    print_ok "Metrics address updated to: ${new_metrics}"
    apply_changes
}

edit_verbosity() {
    print_header "Edit Log Verbosity"

    print_info "Higher verbosity means more log output."
    print_info "Use INFO for normal operation, DEBUG for troubleshooting."
    echo ""
    echo "  1) ERROR  (-v)      -- errors only"
    echo "  2) WARN   (-vv)     -- warnings and errors"
    echo "  3) INFO   (-vvv)    -- recommended for production"
    echo "  4) DEBUG  (-vvvv)   -- detailed output for troubleshooting"
    echo "  5) TRACE  (-vvvvv)  -- very verbose, use sparingly"
    echo ""

    local choice
    while true; do
        read -r -p "  Enter choice [1-5]: " choice
        case "$choice" in
            1) local new_verbosity="-v";     break ;;
            2) local new_verbosity="-vv";    break ;;
            3) local new_verbosity="-vvv";   break ;;
            4) local new_verbosity="-vvvv";  break ;;
            5) local new_verbosity="-vvvvv"; break ;;
            *) print_warn "Please enter 1-5." ;;
        esac
    done

    set_verbosity "$new_verbosity" "$TARGET_SERVICE_FILE"
    print_ok "Log verbosity updated to: ${new_verbosity}"
    apply_changes
}

edit_rpc() {
    print_header "Edit RPC Access"

    local exec_start
    exec_start=$(read_exec_start "$TARGET_SERVICE_FILE")

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
    echo "  3) Disabled              -- RPC completely off"
    echo ""

    local choice
    while true; do
        read -r -p "  Enter choice [1/2/3]: " choice
        case "$choice" in
            1)
                # Rebuild ExecStart without any --http flags, then add private config
                # Read current ExecStart, strip all --http* flags and their values, append clean config
                local current_exec
                current_exec=$(grep "^ExecStart=" "$TARGET_SERVICE_FILE" | sed 's/^ExecStart=//')
                # Remove --http, --http.addr and their values
                local clean_exec
                clean_exec=$(echo "$current_exec" | \
                    sed 's/ --http\.addr [^ ]*//g' | \
                    sed 's/ --http[^\.][^ ]*//g' | \
                    sed 's/ --http$//g')
                sed -i "s|^ExecStart=.*$|ExecStart=${clean_exec} --http --http.addr 127.0.0.1|" "$TARGET_SERVICE_FILE"
                print_ok "RPC set to private (localhost only)"
                break
                ;;
            2)
                local current_exec
                current_exec=$(grep "^ExecStart=" "$TARGET_SERVICE_FILE" | sed 's/^ExecStart=//')
                local clean_exec
                clean_exec=$(echo "$current_exec" | \
                    sed 's/ --http\.addr [^ ]*//g' | \
                    sed 's/ --http[^\.][^ ]*//g' | \
                    sed 's/ --http$//g')
                sed -i "s|^ExecStart=.*$|ExecStart=${clean_exec} --http --http.addr 0.0.0.0|" "$TARGET_SERVICE_FILE"
                print_ok "RPC set to public (0.0.0.0)"
                print_warn "Ensure you have an nginx reverse proxy configured before"
                print_warn "opening this port on your firewall."
                break
                ;;
            3)
                local current_exec
                current_exec=$(grep "^ExecStart=" "$TARGET_SERVICE_FILE" | sed 's/^ExecStart=//')
                local clean_exec
                clean_exec=$(echo "$current_exec" | \
                    sed 's/ --http\.addr [^ ]*//g' | \
                    sed 's/ --http[^\.][^ ]*//g' | \
                    sed 's/ --http$//g')
                sed -i "s|^ExecStart=.*$|ExecStart=${clean_exec}|" "$TARGET_SERVICE_FILE"
                print_ok "RPC disabled"
                break
                ;;
            *) print_warn "Please enter 1, 2, or 3." ;;
        esac
    done

    apply_changes
}

edit_bls_passphrase() {
    print_header "Edit BLS Passphrase"

    local passphrase_file
    if [[ "$NODE_TYPE" == "validator" ]]; then
        passphrase_file="/etc/telcoin/validator/bls-passphrase"
    else
        passphrase_file="/etc/telcoin/observer/bls-passphrase"
    fi

    if [[ ! -f "$passphrase_file" ]]; then
        print_error "Passphrase file not found at: ${passphrase_file}"
        return 1
    fi

    print_warn "Changing the BLS passphrase updates the stored passphrase used"
    print_warn "to decrypt your keys at startup. This does NOT re-encrypt your"
    print_warn "key files -- your keys must have been generated with this passphrase."
    print_warn "Only use this if you know your keys match the new passphrase."
    echo ""

    if ! confirm "Are you sure you want to change the stored passphrase?"; then
        print_info "Passphrase unchanged."
        return 0
    fi

    local new_pass new_pass_confirm
    while true; do
        read -r -s -p "  Enter new BLS passphrase: " new_pass
        echo ""
        read -r -s -p "  Confirm new BLS passphrase: " new_pass_confirm
        echo ""
        if [[ "$new_pass" == "$new_pass_confirm" ]]; then
            break
        fi
        print_warn "Passphrases do not match -- try again."
    done

    # Update the passphrase file
    echo "$new_pass" > "$passphrase_file"
    chmod 600 "$passphrase_file"
    chown "${SERVICE_USER}:${SERVICE_USER}" "$passphrase_file"
    print_ok "Passphrase file updated"

    # Update the service file with the new literal passphrase
    local bls_pass
    bls_pass=$(cat "$passphrase_file")
    sed -i "s|Environment=\"TN_BLS_PASSPHRASE=.*\"|Environment=\"TN_BLS_PASSPHRASE=${bls_pass}\"|" "$TARGET_SERVICE_FILE"
    print_ok "Service file updated"

    new_pass=""
    new_pass_confirm=""

    apply_changes
}

edit_p2p_ports() {
    print_header "Edit P2P Ports"

    local exec_start
    exec_start=$(read_exec_start "$TARGET_SERVICE_FILE")

    local current_primary current_worker
    current_primary=$(read_env_var "PRIMARY_LISTENER_MULTIADDR" "$TARGET_SERVICE_FILE")
    current_worker=$(read_env_var "WORKER_LISTENER_MULTIADDR" "$TARGET_SERVICE_FILE")

    print_info "Current primary listener: ${current_primary:-unknown}"
    print_info "Current worker listener:  ${current_worker:-unknown}"
    echo ""
    print_info "Default ports are 49590 (primary) and 49594 (worker)."
    print_info "Only change these if you have a port conflict."
    echo ""

    local new_primary_port new_worker_port
    read -r -p "  Primary P2P port [49590]: " input
    new_primary_port="${input:-49590}"
    read -r -p "  Worker P2P port  [49594]: " input
    new_worker_port="${input:-49594}"

    # Rebuild multiaddrs with new ports keeping same IP/protocol
    local new_primary new_worker
    if [[ -n "$current_primary" ]]; then
        new_primary=$(echo "$current_primary" | sed "s|/udp/[0-9]*/|/udp/${new_primary_port}/|")
        new_worker=$(echo "$current_worker" | sed "s|/udp/[0-9]*/|/udp/${new_worker_port}/|")
    else
        new_primary="/ip4/0.0.0.0/udp/${new_primary_port}/quic-v1"
        new_worker="/ip4/0.0.0.0/udp/${new_worker_port}/quic-v1"
    fi

    set_env_var "PRIMARY_LISTENER_MULTIADDR" "$new_primary" "$TARGET_SERVICE_FILE"
    set_env_var "WORKER_LISTENER_MULTIADDR"  "$new_worker"  "$TARGET_SERVICE_FILE"
    print_ok "P2P ports updated"
    print_info "Primary: ${new_primary}"
    print_info "Worker:  ${new_worker}"
    apply_changes
}

edit_docker_image() {
    print_header "Update Docker Image"

    local exec_start
    exec_start=$(read_exec_start "$TARGET_SERVICE_FILE")

    if ! echo "$exec_start" | grep -qF "docker run"; then
        print_warn "This node is not running via Docker."
        print_info "Docker image updates only apply to Docker installs."
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi

    local current_image
    current_image=$(echo "$exec_start" | grep -oE 'us-docker[^ ]+|gcr\.io[^ ]+|ghcr\.io[^ ]+' | head -1)
    [[ -z "$current_image" ]] && current_image=$(echo "$exec_start" | awk '{for(i=1;i<=NF;i++) if($i ~ /:[a-z0-9]/) print $i}' | tail -1)

    print_info "Current image: ${current_image:-unknown}"
    echo ""
    print_info "Enter the new image URL and tag."
    print_info "Check for latest tags at:"
    print_info "  https://console.cloud.google.com/artifacts/docker/telcoin-network/us/tn-public/adiri"
    echo ""

    local new_image
    read -r -p "  New Docker image [${current_image}]: " input
    new_image="${input:-$current_image}"

    if [[ "$new_image" == "$current_image" ]]; then
        print_info "Image unchanged."
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi

    print_step "Pulling new image: ${new_image}..."
    if ! docker pull "$new_image"; then
        print_error "Failed to pull image: ${new_image}"
        print_info "Check the image URL and tag and try again."
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi
    print_ok "Image pulled successfully"

    # Replace old image with new image in ExecStart
    perl -i -pe "s|\Q${current_image}\E|${new_image}|g" "$TARGET_SERVICE_FILE"
    print_ok "Service file updated to use: ${new_image}"
    apply_changes
}

refresh_chain_configs() {
    print_header "Refresh Chain Configs"

    local source_dir="/opt/telcoin-source"
    local node_data_dir

    if [[ "$NODE_TYPE" == "observer" ]]; then
        node_data_dir="/var/lib/telcoin/observer"
    else
        node_data_dir="/var/lib/telcoin/validator"
    fi

    print_info "This pulls the latest chain-configs from the repository and"
    print_info "copies them to your node data directory."
    print_info "Use this when the testnet restarts with new genesis/committee/parameters."
    echo ""
    print_warn "The node will be restarted to apply the new configs."
    echo ""

    if ! confirm "Refresh chain configs for ${NODE_TYPE}?"; then
        print_info "Cancelled."
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi

    # Pull latest from repo
    if [[ -d "${source_dir}/.git" ]]; then
        print_step "Pulling latest chain configs..."
        git -C "$source_dir" pull
        print_ok "Repository updated"
    else
        print_warn "Source directory not found at ${source_dir}"
        print_info "Cannot refresh chain configs without the cloned repository."
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi

    # Copy updated configs
    local chain_config_src="${source_dir}/chain-configs/testnet"
    if [[ ! -d "$chain_config_src" ]]; then
        print_warn "Chain config directory not found at ${chain_config_src}"
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi

    print_step "Copying chain configs to ${node_data_dir}..."
    mkdir -p "${node_data_dir}/genesis"
    cp "${chain_config_src}/genesis.yaml"    "${node_data_dir}/genesis/" 2>/dev/null || true
    cp "${chain_config_src}/committee.yaml"  "${node_data_dir}/genesis/" 2>/dev/null || true
    cp "${chain_config_src}/parameters.yaml" "${node_data_dir}/" 2>/dev/null || true

    local svc_user
    svc_user=$(grep "^User=" "$TARGET_SERVICE_FILE" 2>/dev/null | cut -d= -f2 || echo "telcoin")
    local svc_group
    svc_group=$(grep "^Group=" "$TARGET_SERVICE_FILE" 2>/dev/null | cut -d= -f2 || echo "telcoin")
    chown -R "${svc_user}:${svc_group}" "$node_data_dir"
    print_ok "Chain configs updated"

    apply_changes
}

restart_node() {
    print_header "Restart Node"

    local status
    if systemctl is-active --quiet "$TARGET_SERVICE" 2>/dev/null; then
        status="running"
    else
        status="stopped"
    fi

    print_info "Service: ${TARGET_SERVICE} (${status})"
    echo ""

    if confirm "Restart ${TARGET_SERVICE} now?"; then
        print_step "Restarting ${TARGET_SERVICE}..."
        systemctl restart "$TARGET_SERVICE"
        sleep 3
        if systemctl is-active --quiet "$TARGET_SERVICE"; then
            print_ok "Node restarted successfully"
        else
            print_error "Node failed to restart. Check logs:"
            print_info "  journalctl -u ${TARGET_SERVICE} --no-pager -n 30"
        fi
    else
        print_info "Cancelled."
    fi

    echo ""
    read -r -p "  Press Enter to return to menu..."
}

# =============================================================================
# MAIN MENU
# =============================================================================

main_menu() {
    while true; do
        show_current_config

        echo "  What would you like to change?"
        echo ""
        echo "  1) Listener addresses   (PRIMARY/WORKER_LISTENER_MULTIADDR)"
        echo "  2) Instance number      (affects RPC port)"
        echo "  3) Metrics address"
        echo "  4) Log verbosity"
        echo "  5) RPC access           (private / public / disabled)"
        echo "  6) BLS passphrase"
        echo "  7) P2P ports            (49590/49594)"
        echo "  8) Docker image         (Docker installs only)"
        echo "  9) Refresh chain configs (pull latest genesis/committee/parameters)"
        echo " 10) Restart node"
        echo " 11) Exit"
        echo ""

        local choice
        read -r -p "  Enter choice [1-11]: " choice
        case "$choice" in
            1)  edit_listener_addresses ;;
            2)  edit_instance_number    ;;
            3)  edit_metrics            ;;
            4)  edit_verbosity          ;;
            5)  edit_rpc                ;;
            6)  edit_bls_passphrase     ;;
            7)  edit_p2p_ports          ;;
            8)  edit_docker_image       ;;
            9)  refresh_chain_configs   ;;
            10) restart_node            ;;
            11) echo ""; print_info "Exiting."; exit 0 ;;
            *) print_warn "Please enter 1-11." ;;
        esac
    done
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    clear
    print_header "Telcoin Network Node Configuration Editor  v${SCRIPT_VERSION}"
    check_root
    detect_node
    main_menu
}

main "$@"
