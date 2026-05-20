#!/usr/bin/env bash
# =============================================================================
# remove-node.sh -- Telcoin Network Node Removal
#
# Safely removes a Telcoin Network node installation from this server.
# Detects the install method (binary/source or Docker) and cleans up
# all associated files, services, containers and users.
#
# USAGE:
#   sudo bash remove-node.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

readonly SCRIPT_VERSION="1.1.24"

# =============================================================================
# DETECTION
# =============================================================================

detect_node_installs() {
    set +e  # grep returning no match is fine here
    OBSERVER_INSTALLED=false
    VALIDATOR_INSTALLED=false
    OBSERVER_DOCKER=false
    VALIDATOR_DOCKER=false
    OBSERVER_SERVICE_USER=""
    VALIDATOR_SERVICE_USER=""
    OBSERVER_SERVICE_GROUP=""
    VALIDATOR_SERVICE_GROUP=""

    # Check observer
    if [[ -f /etc/systemd/system/telcoin-observer.service ]]; then
        OBSERVER_INSTALLED=true

        # Read from metadata file first (most reliable, set during setup)
        if [[ -f /etc/telcoin/observer/.node-meta ]]; then
            OBSERVER_SERVICE_USER=$(grep "^HOST_SERVICE_USER=" /etc/telcoin/observer/.node-meta | cut -d= -f2 || echo "")
            OBSERVER_SERVICE_GROUP=$(grep "^HOST_SERVICE_GROUP=" /etc/telcoin/observer/.node-meta | cut -d= -f2 || echo "")
            local obs_method
            obs_method=$(grep "^INSTALL_METHOD=" /etc/telcoin/observer/.node-meta | cut -d= -f2 || echo "")
            [[ "$obs_method" == "docker" ]] && OBSERVER_DOCKER=true
        else
            # Fall back to reading service file
            OBSERVER_SERVICE_USER=$(grep "^User=" /etc/systemd/system/telcoin-observer.service | cut -d= -f2 || echo "")
            OBSERVER_SERVICE_GROUP=$(grep "^Group=" /etc/systemd/system/telcoin-observer.service | cut -d= -f2 || echo "")
            if grep -q "docker" /etc/systemd/system/telcoin-observer.service 2>/dev/null; then
                OBSERVER_DOCKER=true
            fi
        fi
    fi

    # Check validator
    if [[ -f /etc/systemd/system/telcoin-validator.service ]]; then
        VALIDATOR_INSTALLED=true

        if [[ -f /etc/telcoin/validator/.node-meta ]]; then
            VALIDATOR_SERVICE_USER=$(grep "^HOST_SERVICE_USER=" /etc/telcoin/validator/.node-meta | cut -d= -f2 || echo "")
            VALIDATOR_SERVICE_GROUP=$(grep "^HOST_SERVICE_GROUP=" /etc/telcoin/validator/.node-meta | cut -d= -f2 || echo "")
            local val_method
            val_method=$(grep "^INSTALL_METHOD=" /etc/telcoin/validator/.node-meta | cut -d= -f2 || echo "")
            [[ "$val_method" == "docker" ]] && VALIDATOR_DOCKER=true
        else
            VALIDATOR_SERVICE_USER=$(grep "^User=" /etc/systemd/system/telcoin-validator.service | cut -d= -f2 || echo "")
            VALIDATOR_SERVICE_GROUP=$(grep "^Group=" /etc/systemd/system/telcoin-validator.service | cut -d= -f2 || echo "")
            if grep -q "docker" /etc/systemd/system/telcoin-validator.service 2>/dev/null; then
                VALIDATOR_DOCKER=true
            fi
        fi
    fi
    set -e
}

show_detected() {
    set +e
    print_header "Detected Node Installations"

    if [[ "$OBSERVER_INSTALLED" == "false" ]] && [[ "$VALIDATOR_INSTALLED" == "false" ]]; then
        # Check for partial installs (directories exist but no service file)
        local partial=false
        local partial_items=()
        [[ -d /var/lib/telcoin ]]    && partial=true && partial_items+=("/var/lib/telcoin")
        [[ -d /opt/telcoin ]]        && partial=true && partial_items+=("/opt/telcoin")
        [[ -d /opt/telcoin-source ]] && partial=true && partial_items+=("/opt/telcoin-source")
        [[ -d /etc/telcoin ]]        && partial=true && partial_items+=("/etc/telcoin")
        [[ -d /var/log/telcoin ]]    && partial=true && partial_items+=("/var/log/telcoin")

        if [[ "$partial" == "true" ]]; then
            print_warn "No complete node installation found, but leftover files detected:"
            for item in "${partial_items[@]}"; do
                print_info "  ${item}"
            done
            echo ""
            if confirm "Remove these leftover files and directories?"; then
                for item in "${partial_items[@]}"; do
                    rm -rf "$item"
                    print_ok "Removed: ${item}"
                done
            else
                print_info "Leftover files kept."
            fi
            echo ""
            exit 0
        fi

        print_warn "No Telcoin node installations detected on this server."
        print_info "Nothing to remove."
        echo ""
        exit 0
    fi

    if [[ "$OBSERVER_INSTALLED" == "true" ]]; then
        local install_type="binary/source"
        [[ "$OBSERVER_DOCKER" == "true" ]] && install_type="Docker"
        print_ok "Observer node detected"
        print_info "  Install type:  ${install_type}"
        print_info "  Service user:  ${OBSERVER_SERVICE_USER:-unknown}"
        print_info "  Service group: ${OBSERVER_SERVICE_GROUP:-(none)}"
        local obs_status
        obs_status=$(systemctl is-active telcoin-observer 2>/dev/null || echo "inactive")
        print_info "  Status:        ${obs_status}"
        echo ""
    fi

    if [[ "$VALIDATOR_INSTALLED" == "true" ]]; then
        local install_type="binary/source"
        [[ "$VALIDATOR_DOCKER" == "true" ]] && install_type="Docker"
        print_ok "Validator node detected"
        print_info "  Install type:  ${install_type}"
        print_info "  Service user:  ${VALIDATOR_SERVICE_USER:-unknown}"
        print_info "  Service group: ${VALIDATOR_SERVICE_GROUP:-(none)}"
        local val_status
        val_status=$(systemctl is-active telcoin-validator 2>/dev/null || echo "inactive")
        print_info "  Status:        ${val_status}"
        echo ""
    fi
}

# =============================================================================
# REMOVAL FUNCTIONS
# =============================================================================

stop_and_disable_service() {
    local service_name="$1"
    print_step "Stopping and disabling ${service_name}..."
    systemctl stop "$service_name" 2>/dev/null || true
    systemctl disable "$service_name" 2>/dev/null || true
    rm -f "/etc/systemd/system/${service_name}.service"
    systemctl daemon-reload
    print_ok "Service ${service_name} removed"
}

remove_docker_container() {
    local container_name="$1"
    print_step "Removing Docker container: ${container_name}..."
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${container_name}$"; then
        docker stop "$container_name" 2>/dev/null || true
        docker rm "$container_name" 2>/dev/null || true
        print_ok "Container ${container_name} removed"

        # Offer to remove the image
        local image
        image=$(docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null || echo "")
        if [[ -n "$image" ]]; then
            echo ""
            if confirm "Also remove Docker image '${image}'? (frees disk space)"; then
                docker rmi "$image" 2>/dev/null || true
                print_ok "Image removed"
            fi
        fi
    else
        print_info "Container ${container_name} not found -- may already be removed"
    fi
}

remove_chain_data() {
    local node_type="$1"
    local data_dir="/var/lib/telcoin/${node_type}"

    if [[ -d "$data_dir" ]]; then
        local size
        size=$(du -sh "$data_dir" 2>/dev/null | cut -f1)
        print_info "Chain data at ${data_dir} (${size})"
        if confirm "Remove chain data? (node will need to resync if reinstalled)"; then
            rm -rf "$data_dir"
            print_ok "Chain data removed"
        else
            print_info "Chain data kept at ${data_dir}"
        fi
    fi
}

remove_keys() {
    local node_type="$1"
    local keys_dir="/var/lib/telcoin/${node_type}/node-keys"
    local config_dir="/etc/telcoin/${node_type}"

    if [[ -d "$keys_dir" ]] || [[ -d "$config_dir" ]]; then
        echo ""
        print_warn "================================================================"
        print_warn "  KEY DELETION WARNING"
        print_warn "================================================================"
        print_warn "This will permanently delete your node keys and passphrase."
        if [[ "$node_type" == "validator" ]]; then
            print_warn "Validator keys CANNOT be recovered without the passphrase."
            print_warn "You will need to re-register with the Telcoin Association"
            print_warn "and generate new keys if you reinstall."
        else
            print_warn "Observer keys cannot be recovered without the passphrase."
            print_warn "You will need to generate new keys if you reinstall."
        fi
        print_warn "================================================================"
        echo ""
        print_info "Keys location:      ${keys_dir}"
        print_info "Passphrase location: ${config_dir}/bls-passphrase"
        echo ""
        print_warn "Back up your keys before proceeding if you may need them again."
        echo ""

        local confirm_text
        read -r -p "  Type DELETE to confirm permanent key removal, or Enter to skip: " confirm_text
        if [[ "$confirm_text" == "DELETE" ]]; then
            rm -rf "$keys_dir"
            rm -rf "$config_dir"
            rm -f "/etc/telcoin/${node_type}/.node-meta" 2>/dev/null || true
            # Also remove TPM sealed files if present
            tpm_remove_sealed_files "$config_dir" 2>/dev/null || true
            print_ok "Keys and passphrase removed"
        else
            print_info "Keys kept -- skipping key removal"
        fi
    fi
}

remove_shared_components() {
    local remove_binary=false
    local remove_source=false
    local remove_user=false

    # Only remove shared components if no other nodes remain
    local remaining_nodes=0
    [[ "$OBSERVER_INSTALLED" == "true" ]] && (( remaining_nodes++ ))
    [[ "$VALIDATOR_INSTALLED" == "true" ]] && (( remaining_nodes++ ))

    # If we're removing all nodes, offer to clean shared components
    if [[ $remaining_nodes -le 1 ]]; then
        echo ""
        print_step "Shared components..."

        if [[ -f /opt/telcoin/telcoin-network ]]; then
            if confirm "Remove binary at /opt/telcoin/telcoin-network?"; then
                rm -rf /opt/telcoin
                print_ok "Binary removed"
            fi
        fi

        if [[ -d /opt/telcoin-source ]]; then
            local size
            size=$(du -sh /opt/telcoin-source 2>/dev/null | cut -f1)
            if confirm "Remove source code at /opt/telcoin-source (${size})?"; then
                rm -rf /opt/telcoin-source
                print_ok "Source code removed"
            fi
        fi

        if [[ -d /var/log/telcoin ]]; then
            if confirm "Remove log directory at /var/log/telcoin?"; then
                rm -rf /var/log/telcoin
                print_ok "Logs removed"
            fi
        fi
    fi
}

remove_service_user() {
    local service_user="$1"
    local service_group="$2"

    if [[ -z "$service_user" ]]; then
        return
    fi

    echo ""
    if id "$service_user" &>/dev/null; then
        if confirm "Remove service user '${service_user}'?"; then
            # Remove home directory cache
            rm -rf "/home/${service_user}" 2>/dev/null || true
            userdel "$service_user" 2>/dev/null || true
            print_ok "User '${service_user}' removed"
        fi
    fi

    if [[ -n "$service_group" ]] && getent group "$service_group" &>/dev/null; then
        if confirm "Remove service group '${service_group}'?"; then
            groupdel "$service_group" 2>/dev/null || true
            print_ok "Group '${service_group}' removed"
        fi
    fi
}

# =============================================================================
# REMOVE OBSERVER
# =============================================================================

remove_observer() {
    print_header "Remove Observer Node"

    print_warn "This will remove the observer node from this server."
    echo ""

    if ! confirm "Proceed with observer node removal?"; then
        print_info "Cancelled -- no changes made."
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi

    echo ""

    # Stop service
    stop_and_disable_service "telcoin-observer"

    # Docker container if applicable
    if [[ "$OBSERVER_DOCKER" == "true" ]]; then
        remove_docker_container "telcoin-observer"
    fi

    # Chain data
    remove_chain_data "observer"

    # Keys -- separate explicit confirmation
    remove_keys "observer"

    # Shared components
    remove_shared_components

    # Service user
    remove_service_user "$OBSERVER_SERVICE_USER" "$OBSERVER_SERVICE_GROUP"

    echo ""
    print_ok "Observer node removal complete"
    OBSERVER_INSTALLED=false
    echo ""
    read -r -p "  Press Enter to return to menu..."
}

# =============================================================================
# REMOVE VALIDATOR
# =============================================================================

remove_validator() {
    print_header "Remove Validator Node"

    print_warn "This will remove the validator node from this server."
    echo ""

    if ! confirm "Proceed with validator node removal?"; then
        print_info "Cancelled -- no changes made."
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi

    echo ""

    # Stop service
    stop_and_disable_service "telcoin-validator"

    # Docker container if applicable
    if [[ "$VALIDATOR_DOCKER" == "true" ]]; then
        remove_docker_container "telcoin-validator"
    fi

    # Chain data
    remove_chain_data "validator"

    # Keys -- separate explicit confirmation
    remove_keys "validator"

    # Shared components
    remove_shared_components

    # Service user
    remove_service_user "$VALIDATOR_SERVICE_USER" "$VALIDATOR_SERVICE_GROUP"

    echo ""
    print_ok "Validator node removal complete"
    VALIDATOR_INSTALLED=false
    echo ""
    read -r -p "  Press Enter to return to menu..."
}

# =============================================================================
# WIPE CHAIN DATA ONLY
# =============================================================================

wipe_chain_data_only() {
    print_header "Wipe Chain Data Only"

    print_info "This removes chain database only -- keeps keys, config and service."
    print_info "The node will resync from scratch when restarted."
    echo ""

    local choice
    if [[ "$OBSERVER_INSTALLED" == "true" ]] && [[ "$VALIDATOR_INSTALLED" == "true" ]]; then
        echo "  1) Wipe observer chain data"
        echo "  2) Wipe validator chain data"
        echo "  3) Wipe both"
        echo "  4) Cancel"
        echo ""
        read -r -p "  Enter choice [1-4]: " choice
    elif [[ "$OBSERVER_INSTALLED" == "true" ]]; then
        choice=1
    elif [[ "$VALIDATOR_INSTALLED" == "true" ]]; then
        choice=2
    fi

    case "$choice" in
        1)
            print_warn "This will wipe all observer chain data. The node will resync."
            if confirm "Wipe observer chain data?"; then
                systemctl stop telcoin-observer 2>/dev/null || true
                rm -rf /var/lib/telcoin/observer/db
                systemctl start telcoin-observer 2>/dev/null || true
                print_ok "Observer chain data wiped -- node restarted"
            fi
            ;;
        2)
            print_warn "This will wipe all validator chain data. The node will resync."
            if confirm "Wipe validator chain data?"; then
                systemctl stop telcoin-validator 2>/dev/null || true
                rm -rf /var/lib/telcoin/validator/db
                systemctl start telcoin-validator 2>/dev/null || true
                print_ok "Validator chain data wiped -- node restarted"
            fi
            ;;
        3)
            if confirm "Wipe chain data for both observer and validator?"; then
                systemctl stop telcoin-observer telcoin-validator 2>/dev/null || true
                rm -rf /var/lib/telcoin/observer/db
                rm -rf /var/lib/telcoin/validator/db
                systemctl start telcoin-observer telcoin-validator 2>/dev/null || true
                print_ok "Chain data wiped for both nodes -- nodes restarted"
            fi
            ;;
        4|*) print_info "Cancelled" ;;
    esac

    echo ""
    read -r -p "  Press Enter to return to menu..."
}

# =============================================================================
# MAIN MENU
# =============================================================================

main_menu() {
    while true; do
        clear
        detect_node_installs
        print_header "Telcoin Network -- Node Removal  v${SCRIPT_VERSION}"
        show_detected

        echo "  What would you like to do?"
        echo ""

        if [[ "$OBSERVER_INSTALLED" == "true" ]] && [[ "$VALIDATOR_INSTALLED" == "true" ]]; then
            echo "  1) Remove observer node"
            echo "  2) Remove validator node"
            echo "  3) Remove both nodes"
            echo "  4) Wipe chain data only (keeps keys and config)"
            echo "  5) Exit"
            echo ""
            local choice
            read -r -p "  Enter choice [1-5]: " choice
            case "$choice" in
                1) remove_observer ;;
                2) remove_validator ;;
                3) remove_observer; remove_validator ;;
                4) wipe_chain_data_only ;;
                5) echo ""; print_info "Exiting."; exit 0 ;;
                *) print_warn "Please enter 1-5." ;;
            esac
        elif [[ "$OBSERVER_INSTALLED" == "true" ]]; then
            echo "  1) Remove observer node"
            echo "  2) Wipe chain data only (keeps keys and config)"
            echo "  3) Exit"
            echo ""
            local choice
            read -r -p "  Enter choice [1-3]: " choice
            case "$choice" in
                1) remove_observer ;;
                2) wipe_chain_data_only ;;
                3) echo ""; print_info "Exiting."; exit 0 ;;
                *) print_warn "Please enter 1-3." ;;
            esac
        elif [[ "$VALIDATOR_INSTALLED" == "true" ]]; then
            echo "  1) Remove validator node"
            echo "  2) Wipe chain data only (keeps keys and config)"
            echo "  3) Exit"
            echo ""
            local choice
            read -r -p "  Enter choice [1-3]: " choice
            case "$choice" in
                1) remove_validator ;;
                2) wipe_chain_data_only ;;
                3) echo ""; print_info "Exiting."; exit 0 ;;
                *) print_warn "Please enter 1-3." ;;
            esac
        else
            exit 0
        fi
    done
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    check_root
    main_menu
}

main "$@"
