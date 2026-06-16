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

readonly SCRIPT_VERSION="1.2.3"

# =============================================================================
# HELPERS
# =============================================================================

# Resolve a node's data dir from its .node-meta (DATA_DIR=), falling back to the
# legacy /var/lib/telcoin/<type> for nodes installed before DATA_DIR was recorded.
# Mirrors check-node.sh's detect_data_dir so all scripts agree on the path. Always
# echoes a path and returns 0 so set -e never trips.
detect_data_dir() {
    local node_type="$1"
    local meta="/etc/telcoin/${node_type}/.node-meta"
    local default="/var/lib/telcoin/${node_type}"
    if [[ -f "$meta" ]]; then
        local dd
        dd=$(grep "^DATA_DIR=" "$meta" 2>/dev/null | cut -d= -f2 || true)
        if [[ -n "$dd" ]] && [[ -d "$dd" ]]; then
            echo "$dd"
            return 0
        fi
    fi
    echo "$default"
    return 0
}

# Stop a unit and wait for it to actually finish exiting before returning.
# systemctl stop normally blocks until the unit reaches inactive, but on some
# configurations (Type=simple with no ExecStop, or container teardown) the
# process can outlive the systemctl call by a few seconds. Poll explicitly
# so the caller can safely delete the chain DB without racing the process.
wait_for_service_stopped() {
    local unit="$1"
    local timeout="${2:-30}"
    local waited=0
    systemctl stop "$unit" 2>/dev/null || true
    while systemctl is-active --quiet "$unit" 2>/dev/null; do
        if (( waited >= timeout )); then
            print_warn "${unit} did not stop within ${timeout}s -- forcing kill"
            systemctl kill -s SIGKILL "$unit" 2>/dev/null || true
            sleep 2
            return
        fi
        sleep 1
        (( ++waited ))
    done
}

# True if the other node's service file references the given Docker image.
image_used_by_other_node() {
    local image="$1"
    local self="$2"  # "observer" | "validator"
    local other_unit
    if [[ "$self" == "observer" ]]; then
        other_unit="/etc/systemd/system/telcoin-validator.service"
    else
        other_unit="/etc/systemd/system/telcoin-observer.service"
    fi
    [[ -f "$other_unit" ]] || return 1
    grep -qF "$image" "$other_unit"
}

# True if the other node's service file uses the given service user.
user_used_by_other_node() {
    local user="$1"
    local self="$2"
    local other_unit
    if [[ "$self" == "observer" ]]; then
        other_unit="/etc/systemd/system/telcoin-validator.service"
    else
        other_unit="/etc/systemd/system/telcoin-observer.service"
    fi
    [[ -f "$other_unit" ]] || return 1
    grep -qE "^(User|--user)[ =]${user}([:[:space:]]|$)" "$other_unit" || \
        grep -qE "^User=${user}$" "$other_unit"
}

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
            report_orphaned_groups
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
    local self_type="${2:-}"  # observer | validator | "" (skip sibling check)
    print_step "Removing Docker container: ${container_name}..."

    # Capture the image BEFORE removing the container, since docker inspect
    # cannot read it after rm.
    local image=""
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${container_name}$"; then
        image=$(docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null || echo "")
        docker stop "$container_name" 2>/dev/null || true
        docker rm "$container_name" 2>/dev/null || true
        print_ok "Container ${container_name} removed"
    else
        print_info "Container ${container_name} not found -- may already be removed"
    fi

    if [[ -n "$image" ]]; then
        # If the other node's unit references the same image, skip removal
        # so we don't break the sibling node.
        if [[ -n "$self_type" ]] && image_used_by_other_node "$image" "$self_type"; then
            print_info "Image '${image}' is also used by the other Telcoin node -- keeping it."
            return
        fi
        echo ""
        if confirm "Also remove Docker image '${image}'? (frees disk space)"; then
            docker rmi "$image" 2>/dev/null || true
            print_ok "Image removed"
        fi
    fi
}

remove_chain_data() {
    local node_type="$1"
    local data_dir
    data_dir=$(detect_data_dir "$node_type")

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
    local keys_dir config_dir
    keys_dir="$(detect_data_dir "$node_type")/node-keys"
    config_dir="/etc/telcoin/${node_type}"

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
    [[ "$OBSERVER_INSTALLED" == "true" ]] && (( ++remaining_nodes ))
    [[ "$VALIDATOR_INSTALLED" == "true" ]] && (( ++remaining_nodes ))

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
    local self_type="${3:-}"  # observer | validator | "" (skip sibling check)

    # Fallback when .node-meta and the unit were both missing/unreadable (or the
    # unit ran as root, e.g. docker): recover the service account from the
    # configured/default service names so the group isn't silently orphaned.
    [[ -z "$service_user"  || "$service_user" == "root" ]]  && service_user="${SERVICE_USER:-telcoin}"
    [[ -z "$service_group" || "$service_group" == "root" ]] && service_group="${SERVICE_GROUP:-telcoin}"

    # Never touch root / non-telcoin system accounts.
    if [[ "$service_user" == "root" || "$service_group" == "root" ]]; then
        return
    fi

    # If the other node's unit still references this user, deleting would
    # leave the sibling broken. Refuse and tell the operator.
    if [[ -n "$self_type" ]] && user_used_by_other_node "$service_user" "$self_type"; then
        print_info "User '${service_user}' is still in use by the other Telcoin node -- keeping it."
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
            if groupdel "$service_group" 2>/dev/null; then
                print_ok "Group '${service_group}' removed"
            else
                print_warn "Could not remove group '${service_group}' (still in use?). Remove manually:"
                print_info "  sudo groupdel ${service_group}"
            fi
        fi
    fi
}

# Warn about Telcoin-related groups still present after removal (e.g. orphaned by
# an earlier crash where .node-meta + the unit were both gone). Matches the
# operator's quick check: getent group | grep -v telcoin-ui | grep telcoin.
report_orphaned_groups() {
    local orphans
    orphans=$(getent group | grep -v "telcoin-ui" | grep "telcoin" | cut -d: -f1 || true)
    [[ -z "$orphans" ]] && return 0
    echo ""
    print_warn "Possible orphaned Telcoin service group(s) still present:"
    local g
    while IFS= read -r g; do
        [[ -z "$g" ]] && continue
        print_info "  ${g}  ->  remove with:  sudo groupdel ${g}"
    done <<< "$orphans"
}

# =============================================================================
# REMOVE NODE MANAGER UI
# =============================================================================

# Uninstall the Telcoin Node Manager UI (service, app, helper + update engine,
# sudoers, and the service user). Safe to call when the UI is absent / partial.
remove_ui_components() {
    print_step "Removing Telcoin Node Manager UI..."
    systemctl stop telcoin-ui 2>/dev/null || true
    systemctl disable telcoin-ui 2>/dev/null || true
    rm -f /etc/systemd/system/telcoin-ui.service
    systemctl daemon-reload 2>/dev/null || true
    rm -rf /opt/telcoin-ui /opt/telcoin-ui-update
    rm -f /usr/local/sbin/telcoin-ui-helper
    rm -f /etc/sudoers.d/telcoin-ui
    if id telcoin-ui &>/dev/null; then
        userdel telcoin-ui 2>/dev/null || true
    fi
    print_ok "Telcoin Node Manager UI removed"
}

# Interactive: offer to also remove the web UI. `other_unit` is the sibling
# node's unit; if it still exists we warn (the UI manages it too).
offer_ui_removal() {
    local other_unit="$1"
    [[ -d /opt/telcoin-ui || -f /etc/systemd/system/telcoin-ui.service ]] || return 0
    echo ""
    if [[ -f "$other_unit" ]]; then
        print_warn "The Node Manager UI also manages the other Telcoin node still installed here."
    fi
    if confirm "Also remove the Telcoin Node Manager UI (web dashboard)?"; then
        remove_ui_components
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
        remove_docker_container "telcoin-observer" "observer"
    fi

    # Chain data
    remove_chain_data "observer"

    # Keys -- separate explicit confirmation
    remove_keys "observer"

    # Shared components
    remove_shared_components

    # Service user
    remove_service_user "$OBSERVER_SERVICE_USER" "$OBSERVER_SERVICE_GROUP" "observer"

    echo ""
    print_ok "Observer node removal complete"
    OBSERVER_INSTALLED=false

    report_orphaned_groups

    # Offer to also remove the web UI (warn if the validator still uses it).
    offer_ui_removal "/etc/systemd/system/telcoin-validator.service"

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
        remove_docker_container "telcoin-validator" "validator"
    fi

    # Chain data
    remove_chain_data "validator"

    # Keys -- separate explicit confirmation
    remove_keys "validator"

    # Shared components
    remove_shared_components

    # Service user
    remove_service_user "$VALIDATOR_SERVICE_USER" "$VALIDATOR_SERVICE_GROUP" "validator"

    echo ""
    print_ok "Validator node removal complete"
    VALIDATOR_INSTALLED=false

    report_orphaned_groups

    # Offer to also remove the web UI (warn if the observer still uses it).
    offer_ui_removal "/etc/systemd/system/telcoin-observer.service"

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
                wait_for_service_stopped telcoin-observer
                rm -rf "$(detect_data_dir observer)/db"
                systemctl start telcoin-observer 2>/dev/null || true
                print_ok "Observer chain data wiped -- node restarted"
            fi
            ;;
        2)
            print_warn "This will wipe all validator chain data. The node will resync."
            if confirm "Wipe validator chain data?"; then
                wait_for_service_stopped telcoin-validator
                rm -rf "$(detect_data_dir validator)/db"
                systemctl start telcoin-validator 2>/dev/null || true
                print_ok "Validator chain data wiped -- node restarted"
            fi
            ;;
        3)
            if confirm "Wipe chain data for both observer and validator?"; then
                wait_for_service_stopped telcoin-observer
                wait_for_service_stopped telcoin-validator
                rm -rf "$(detect_data_dir observer)/db"
                rm -rf "$(detect_data_dir validator)/db"
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

# =============================================================================
# JSON / NON-INTERACTIVE MODE
#
# Reached only via `--json` (the interactive default is completely unaffected).
# Used by the Telcoin Node Manager UI through the root-owned telcoin-ui-helper.
# DESTRUCTIVE: requires --yes, and the server gates it behind a typed "DELETE"
# confirmation. Scope is cumulative:
#   service -> stop+disable+rm unit (+ docker container)
#   data    -> service + remove chain data
#   keys    -> data + remove keys/config/.node-meta (+ TPM sealed files)
#
#   remove-node.sh --json --remove <observer|validator> --scope <service|data|keys> --yes
# =============================================================================

JSON_REMOVE_TYPE=""
JSON_REMOVE_SCOPE=""
JSON_YES=false
JSON_REMOVE_UI=false

json_setup_fds() {
    exec 3>&1   # fd3 = original stdout: JSON is written here
    exec 1>&2   # stdout now aliases stderr: print_* output is benign noise
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/ }"; s="${s//$'\r'/ }"; s="${s//$'\t'/ }"
    printf '%s' "$s"
}

json_emit() { printf '%s\n' "$1" >&3; }
json_event() { json_emit "{\"event\":\"${1}\",\"msg\":\"$(json_escape "${2:-}")\"}"; }

json_remove() {
    local node_type="$1" scope="$2"
    case "$node_type" in observer|validator) ;; *) json_event error "invalid node type: ${node_type}"; return 1 ;; esac
    case "$scope" in service|data|keys) ;; *) json_event error "invalid scope: ${scope}"; return 1 ;; esac

    local unit="/etc/systemd/system/telcoin-${node_type}.service"
    if [[ ! -f "$unit" ]]; then
        json_event error "node not installed: telcoin-${node_type}"
        return 1
    fi

    # Detect docker BEFORE removing the unit (we read the install method from it).
    local is_docker=false
    grep -q "docker run" "$unit" 2>/dev/null && is_docker=true

    # Resolve the service user/group BEFORE deleting the unit/.node-meta, so a
    # 'keys' (full) removal can clean up the account instead of orphaning it.
    # .node-meta is authoritative; the unit's User=/Group= is the fallback (but
    # docker units run as root, so ignore root and use the default service name).
    local svc_user="" svc_group="" meta="/etc/telcoin/${node_type}/.node-meta"
    if [[ -f "$meta" ]]; then
        svc_user=$(grep '^HOST_SERVICE_USER=' "$meta" 2>/dev/null | cut -d= -f2- || true)
        svc_group=$(grep '^HOST_SERVICE_GROUP=' "$meta" 2>/dev/null | cut -d= -f2- || true)
    fi
    [[ -z "$svc_user" ]]  && svc_user=$(grep '^User=' "$unit" 2>/dev/null | cut -d= -f2- || true)
    [[ -z "$svc_group" ]] && svc_group=$(grep '^Group=' "$unit" 2>/dev/null | cut -d= -f2- || true)
    [[ -z "$svc_user"  || "$svc_user"  == "root" ]] && svc_user="${SERVICE_USER:-telcoin}"
    [[ -z "$svc_group" || "$svc_group" == "root" ]] && svc_group="${SERVICE_GROUP:-telcoin}"

    # Resolve the data dir from .node-meta BEFORE it (and the meta) get removed,
    # so a custom data drive is cleaned up instead of orphaned.
    local data_dir
    data_dir=$(detect_data_dir "$node_type")

    json_event step "Stopping and disabling telcoin-${node_type}"
    systemctl stop "telcoin-${node_type}" 2>/dev/null || true
    systemctl disable "telcoin-${node_type}" 2>/dev/null || true
    rm -f "$unit"
    systemctl daemon-reload

    if [[ "$is_docker" == "true" ]] && command -v docker >/dev/null 2>&1; then
        json_event step "Removing docker container telcoin-${node_type}"
        docker stop "telcoin-${node_type}" 2>/dev/null || true
        docker rm "telcoin-${node_type}" 2>/dev/null || true
    fi

    if [[ "$scope" == "data" || "$scope" == "keys" ]]; then
        if [[ -d "$data_dir" ]]; then
            json_event step "Removing chain data ${data_dir}"
            rm -rf "$data_dir"
        fi
    fi

    if [[ "$scope" == "keys" ]]; then
        local config_dir="/etc/telcoin/${node_type}"
        json_event step "Removing keys and config ${config_dir}"
        rm -rf "${data_dir}/node-keys" 2>/dev/null || true
        rm -rf "$config_dir" 2>/dev/null || true
        if declare -f tpm_remove_sealed_files >/dev/null 2>&1; then
            tpm_remove_sealed_files "$config_dir" 2>/dev/null || true
        fi

        # Full removal: also drop the service user/group (skip root; keep if the
        # other node still uses the account).
        if [[ "$svc_user" != "root" ]] && id "$svc_user" &>/dev/null \
           && ! user_used_by_other_node "$svc_user" "$node_type"; then
            json_event step "Removing service user ${svc_user}"
            rm -rf "/home/${svc_user}" 2>/dev/null || true
            userdel "$svc_user" 2>/dev/null || true
        fi
        if [[ "$svc_group" != "root" ]] && getent group "$svc_group" &>/dev/null; then
            json_event step "Removing service group ${svc_group}"
            groupdel "$svc_group" 2>/dev/null \
                || json_event step "Could not remove group ${svc_group} (still in use) -- run: groupdel ${svc_group}"
        fi

        # Warn about any Telcoin-related groups that remain orphaned.
        local orphans og
        orphans=$(getent group | grep -v "telcoin-ui" | grep "telcoin" | cut -d: -f1 || true)
        while IFS= read -r og; do
            [[ -z "$og" ]] && continue
            json_event step "Orphaned group remains: ${og} -- remove with: groupdel ${og}"
        done <<< "$orphans"
    fi

    # Optional: also remove the Node Manager UI. This is requested FROM the UI,
    # so we must not uninstall it inline -- stopping telcoin-ui would kill this
    # very process (same cgroup) mid-removal. Instead schedule a detached,
    # transient systemd unit (its own cgroup, survives the stop). The short sleep
    # lets the 'done' event below flush and the SSE close before the UI goes down.
    local ui_scheduled=false
    if [[ "$JSON_REMOVE_UI" == "true" ]]; then
        if command -v systemd-run >/dev/null 2>&1; then
            json_event step "Scheduling Node Manager UI removal -- this web interface will go offline shortly"
            systemd-run --quiet --collect --unit="telcoin-ui-uninstall" bash -c '
                sleep 2
                systemctl stop telcoin-ui 2>/dev/null || true
                systemctl disable telcoin-ui 2>/dev/null || true
                rm -f /etc/systemd/system/telcoin-ui.service
                systemctl daemon-reload 2>/dev/null || true
                rm -rf /opt/telcoin-ui /opt/telcoin-ui-update
                rm -f /usr/local/sbin/telcoin-ui-helper
                rm -f /etc/sudoers.d/telcoin-ui
                id telcoin-ui >/dev/null 2>&1 && userdel telcoin-ui 2>/dev/null || true
            ' >/dev/null 2>&1 && ui_scheduled=true || true
        fi
        [[ "$ui_scheduled" == "true" ]] || json_event step "Could not schedule UI removal -- run remove-node.sh on the server to remove the UI"
    fi

    json_emit "{\"event\":\"done\",\"ok\":true,\"node_type\":\"$(json_escape "$node_type")\",\"scope\":\"$(json_escape "$scope")\",\"ui_removed\":${ui_scheduled},\"msg\":\"telcoin-${node_type} removed (scope: ${scope})\"}"
}

run_json_mode() {
    json_setup_fds
    check_root
    if [[ "$JSON_YES" != "true" ]]; then
        json_event error "refusing destructive removal without --yes"
        return 1
    fi
    json_remove "$JSON_REMOVE_TYPE" "$JSON_REMOVE_SCOPE"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local json_mode=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)   json_mode=true; shift ;;
            --remove) JSON_REMOVE_TYPE="${2:-}"; shift; [[ $# -gt 0 ]] && shift ;;
            --scope)  JSON_REMOVE_SCOPE="${2:-}"; shift; [[ $# -gt 0 ]] && shift ;;
            --yes)    JSON_YES=true; shift ;;
            --remove-ui) JSON_REMOVE_UI=true; shift ;;
            *) shift ;;
        esac
    done

    if [[ "$json_mode" == "true" ]]; then
        run_json_mode
        exit $?
    fi

    check_root
    main_menu
}

main "$@"
