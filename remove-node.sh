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

readonly SCRIPT_VERSION="1.2.7"

# =============================================================================
# HELPERS
# =============================================================================

# Echo the config dir for a discovered unit. The resolvers (fallback.sh) already
# pick /etc/telcoin for the unified install and /etc/telcoin/<role> for a legacy
# install -- this thin wrapper just keeps the call sites readable. The unit name
# is accepted for symmetry with the rest of the per-unit teardown; the resolver
# keys off the on-disk .node-meta layout (there is one node per VM).
config_dir_for_unit() {
    tn_resolve_config_dir
}

# Resolve a node's data dir from its .node-meta (DATA_DIR=), falling back to the
# resolver's path (/var/lib/telcoin for the unified install, /var/lib/telcoin/<role>
# for a legacy install). Mirrors check-node.sh so all scripts agree on the path.
# Always echoes a path and returns 0 so set -e never trips.
detect_data_dir() {
    local meta dd
    meta="$(tn_resolve_config_dir)/.node-meta"
    if [[ -f "$meta" ]]; then
        dd=$(grep "^DATA_DIR=" "$meta" 2>/dev/null | cut -d= -f2 || true)
        if [[ -n "$dd" ]] && [[ -d "$dd" ]]; then
            echo "$dd"
            return 0
        fi
    fi
    tn_resolve_data_dir
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

# Echo every installed node unit file EXCEPT the one named by $1 (its base name).
# The candidate base names come from tn_all_node_services (telcoin + legacy), so
# a teardown of one node can check whether any sibling unit still present here
# references a shared image/user before removing it. One line per unit file.
other_node_unit_files() {
    local self="$1" name unit
    while IFS= read -r name; do
        [[ -z "$name" || "$name" == "$self" ]] && continue
        unit="/etc/systemd/system/${name}.service"
        [[ -f "$unit" ]] && printf '%s\n' "$unit"
    done < <(tn_all_node_services)
}

# True if a sibling node's service file references the given Docker image.
image_used_by_other_node() {
    local image="$1"
    local self="$2"   # the unit base name being removed
    local other_unit
    while IFS= read -r other_unit; do
        [[ -z "$other_unit" ]] && continue
        grep -qF "$image" "$other_unit" && return 0
    done < <(other_node_unit_files "$self")
    return 1
}

# True if a sibling node's service file uses the given service user.
user_used_by_other_node() {
    local user="$1"
    local self="$2"   # the unit base name being removed
    local other_unit
    while IFS= read -r other_unit; do
        [[ -z "$other_unit" ]] && continue
        if grep -qE "^(User|--user)[ =]${user}([:[:space:]]|$)" "$other_unit" || \
           grep -qE "^User=${user}$" "$other_unit"; then
            return 0
        fi
    done < <(other_node_unit_files "$self")
    return 1
}

# =============================================================================
# DETECTION
# =============================================================================

# Per-unit detection state, keyed by the unit BASE name (the new "telcoin" unit or,
# for a legacy install, one of the legacy unit names from tn_all_node_services).
# INSTALLED_UNITS lists whatever was found present; the maps carry that unit's
# install method/user/group. Operators run one node per VM, so this is normally a
# single entry -- but a stray legacy unit alongside the new one is still torn down.
declare -a INSTALLED_UNITS=()
declare -A UNIT_DOCKER=()
declare -A UNIT_USER=()
declare -A UNIT_GROUP=()
declare -A UNIT_TYPE=()

# Populate the per-unit state above by enumerating every candidate unit name from
# tn_all_node_services (telcoin + the legacy names) and inspecting the ones that
# are actually installed. .node-meta is authoritative; the unit's User=/Group= is
# the fallback. Node type / config dir come from the resolvers.
detect_node_installs() {
    set +e  # grep returning no match is fine here
    INSTALLED_UNITS=()
    UNIT_DOCKER=(); UNIT_USER=(); UNIT_GROUP=(); UNIT_TYPE=()

    local unit_name unit_file meta method ntype
    while IFS= read -r unit_name; do
        [[ -z "$unit_name" ]] && continue
        unit_file="/etc/systemd/system/${unit_name}.service"
        [[ -f "$unit_file" ]] || continue

        INSTALLED_UNITS+=("$unit_name")
        UNIT_DOCKER["$unit_name"]=false
        UNIT_USER["$unit_name"]=""
        UNIT_GROUP["$unit_name"]=""

        # Node type + config dir resolve from the on-disk layout (one node per VM).
        ntype="$(tn_resolve_node_type 2>/dev/null || echo validator)"
        UNIT_TYPE["$unit_name"]="$ntype"
        meta="$(config_dir_for_unit "$unit_name")/.node-meta"

        # Read from metadata file first (most reliable, set during setup).
        if [[ -f "$meta" ]]; then
            UNIT_USER["$unit_name"]=$(grep "^HOST_SERVICE_USER=" "$meta" | cut -d= -f2 || echo "")
            UNIT_GROUP["$unit_name"]=$(grep "^HOST_SERVICE_GROUP=" "$meta" | cut -d= -f2 || echo "")
            method=$(grep "^INSTALL_METHOD=" "$meta" | cut -d= -f2 || echo "")
            [[ "$method" == "docker" ]] && UNIT_DOCKER["$unit_name"]=true
        else
            # Fall back to reading the service file.
            UNIT_USER["$unit_name"]=$(grep "^User=" "$unit_file" | cut -d= -f2 || echo "")
            UNIT_GROUP["$unit_name"]=$(grep "^Group=" "$unit_file" | cut -d= -f2 || echo "")
            if grep -q "docker" "$unit_file" 2>/dev/null; then
                UNIT_DOCKER["$unit_name"]=true
            fi
        fi
    done < <(tn_all_node_services)
    set -e
}

show_detected() {
    set +e
    print_header "Detected Node Installations"

    if [[ ${#INSTALLED_UNITS[@]} -eq 0 ]]; then
        # Check for partial installs (directories exist but no service file). The
        # unified dirs (/etc/telcoin, /var/lib/telcoin) are the parents of any
        # legacy role subdir, so removing them clears a half-removed legacy install.
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
        else
            print_warn "No standard Telcoin node installation detected on this server."
        fi

        # A node may still be present via a non-standard install (manual / dev /
        # docker elsewhere) -- offer the scan before giving up.
        echo ""
        if confirm "Scan for non-standard / custom Telcoin installs (manual / dev / docker)?"; then
            scan_custom_installs
        fi
        echo ""
        print_info "Nothing more to do."
        exit 0
    fi

    local unit install_type status
    for unit in "${INSTALLED_UNITS[@]}"; do
        install_type="binary/source"
        [[ "${UNIT_DOCKER[$unit]}" == "true" ]] && install_type="Docker"
        print_ok "${UNIT_TYPE[$unit]^} node detected (${unit})"
        print_info "  Install type:  ${install_type}"
        print_info "  Service user:  ${UNIT_USER[$unit]:-unknown}"
        print_info "  Service group: ${UNIT_GROUP[$unit]:-(none)}"
        status=$(systemctl is-active "$unit" 2>/dev/null || echo "inactive")
        print_info "  Status:        ${status}"
        echo ""
    done
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
    local self_unit="${2:-}"  # unit base name being removed ("" skips sibling check)
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
        # If a sibling node's unit references the same image, skip removal
        # so we don't break it.
        if [[ -n "$self_unit" ]] && image_used_by_other_node "$image" "$self_unit"; then
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
    config_dir="$(tn_resolve_config_dir)"

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
            # Also remove TPM sealed files if present (before the dir itself).
            tpm_remove_sealed_files "$config_dir" 2>/dev/null || true
            rm -rf "$config_dir"
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

    # Only remove shared components if no other nodes remain. INSTALLED_UNITS is
    # refreshed by detect_node_installs and pruned as each unit is torn down.
    local remaining_nodes=${#INSTALLED_UNITS[@]}

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
    local self_unit="${3:-}"  # unit base name being removed ("" skips sibling check)

    # Fallback when .node-meta and the unit were both missing/unreadable (or the
    # unit ran as root, e.g. docker): recover the service account from the
    # configured/default service names so the group isn't silently orphaned.
    [[ -z "$service_user"  || "$service_user" == "root" ]]  && service_user="${SERVICE_USER:-telcoin}"
    [[ -z "$service_group" || "$service_group" == "root" ]] && service_group="${SERVICE_GROUP:-telcoin}"

    # Never touch root / non-telcoin system accounts.
    if [[ "$service_user" == "root" || "$service_group" == "root" ]]; then
        return
    fi

    # If a sibling node's unit still references this user, deleting would
    # leave it broken. Refuse and tell the operator.
    if [[ -n "$self_unit" ]] && user_used_by_other_node "$service_user" "$self_unit"; then
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

# Interactive: offer to also remove the web UI. $1 is the unit base name just
# removed; if any SIBLING node unit is still present we warn (the UI manages it
# too). The sibling list comes from tn_all_node_services via other_node_unit_files.
offer_ui_removal() {
    local self_unit="$1"
    [[ -d /opt/telcoin-ui || -f /etc/systemd/system/telcoin-ui.service ]] || return 0
    echo ""
    if [[ -n "$(other_node_unit_files "$self_unit")" ]]; then
        print_warn "The Node Manager UI also manages the other Telcoin node still installed here."
    fi
    if confirm "Also remove the Telcoin Node Manager UI (web dashboard)?"; then
        remove_ui_components
    fi
}

# =============================================================================
# REMOVE TESTNET ADD-ONS (Alloy log shipper + WireGuard admin overlay)
# =============================================================================

# Idempotent host-wide teardown of the opt-in add-ons. Safe to call even if none
# were enabled (each block guards on the component existing). Called from the
# node full-removal flow.
remove_testnet_addons() {
    # --- Alloy log shipper -----------------------------------------------------
    if [[ -f /etc/systemd/system/telcoin-alloy.service ]] || systemctl list-unit-files 2>/dev/null | grep -q '^telcoin-alloy.service'; then
        print_info "Removing Alloy log shipper (telcoin-alloy)..."
        systemctl disable --now telcoin-alloy.service >/dev/null 2>&1 || true
        docker rm -f telcoin-alloy >/dev/null 2>&1 || true
        docker rmi "${TN_ALLOY_IMAGE:-grafana/alloy:v1.5.1}" >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/telcoin-alloy.service
        rm -f /usr/local/bin/alloy   # native tarball install path (no-op for apt/docker installs)
        systemctl daemon-reload 2>/dev/null || true
    fi
    rm -rf /etc/telcoin/alloy /var/lib/telcoin-alloy

    # --- WireGuard admin overlay ----------------------------------------------
    if [[ -f /etc/wireguard/wg0.conf ]] || ip link show wg0 >/dev/null 2>&1; then
        print_info "Removing WireGuard admin overlay (wg0 + tnadmin)..."
        wg-quick down wg0 >/dev/null 2>&1 || true
        systemctl disable wg-quick@wg0.service >/dev/null 2>&1 || true
        rm -f /etc/wireguard/wg0.conf /etc/wireguard/wg0-private.key
        rm -f /etc/ssh/sshd_config.d/15-tnadmin-overlay.conf
        if sshd -t >/dev/null 2>&1; then systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true; fi
        systemctl disable --now tn-nftables.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/tn-nftables.service /etc/wgvpn/nftables-node.nft /usr/local/sbin/tn-node-ssh-lockdown
        rmdir /etc/wgvpn 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        # Remove the overlay-SSH ufw rule (mirrors setup-vpn.sh --disable).
        if ufw_installed && ufw_active; then
            local sp; sp="$(get_ssh_port)"; [[ -n "$sp" ]] || sp=22
            ufw delete allow from "${TN_OVERLAY_CIDR}" to any port "${sp}" proto tcp &>/dev/null || true
        fi
        if id -u tnadmin >/dev/null 2>&1; then
            userdel -r tnadmin >/dev/null 2>&1 || true
            rm -f /etc/sudoers.d/90-tnadmin
        fi
        print_info "Note: ask the Telcoin Association to de-enroll this node's overlay peer."
    fi
}

# =============================================================================
# REMOVE A NODE  (drives the unit/container/dir teardown from the resolvers)
# =============================================================================

# Tear down a SINGLE installed node unit and everything tied to it: the systemd
# unit, the docker container (when the install method is docker), chain data,
# keys/config, the host-wide testnet add-ons, shared components, and the service
# user. $1 is the unit base name (the new "telcoin" unit or a legacy unit name)
# discovered by detect_node_installs; its node type / dirs come from the resolvers.
# Prunes the unit from INSTALLED_UNITS so a follow-on remove_shared_components
# sees the correct remaining count.
remove_node_unit() {
    local unit="$1"
    local ntype="${UNIT_TYPE[$unit]:-$(tn_resolve_node_type)}"

    # Stop service
    stop_and_disable_service "$unit"

    # Docker container if applicable. The container shares the unit's base name
    # (new install: telcoin; legacy: telcoin-<role>); confirm via the resolver,
    # then attempt removal by that name and guard the shared image.
    if [[ "${UNIT_DOCKER[$unit]:-false}" == "true" ]]; then
        local ctr
        ctr="$(tn_resolve_container 2>/dev/null || echo "$unit")"
        remove_docker_container "$ctr" "$unit"
    fi

    # Chain data
    remove_chain_data "$ntype"

    # Keys -- separate explicit confirmation
    remove_keys "$ntype"

    # Testnet add-ons (Alloy log shipper + WireGuard admin overlay)
    remove_testnet_addons

    # Shared components
    remove_shared_components

    # Service user
    remove_service_user "${UNIT_USER[$unit]:-}" "${UNIT_GROUP[$unit]:-}" "$unit"

    echo ""
    print_ok "${ntype^} node removal complete (${unit})"

    # Prune from the installed set so remaining-node accounting stays correct.
    local -a kept=()
    local u
    for u in "${INSTALLED_UNITS[@]}"; do
        [[ "$u" == "$unit" ]] || kept+=("$u")
    done
    INSTALLED_UNITS=("${kept[@]}")

    report_orphaned_groups

    # Offer to also remove the web UI (warn if a sibling node still uses it).
    offer_ui_removal "$unit"
}

# Interactive entry point: confirm, then tear down every installed node unit
# (the new telcoin unit AND any legacy unit still present). Iterates a snapshot
# of INSTALLED_UNITS so the prune inside remove_node_unit doesn't disturb the loop.
remove_all_nodes() {
    print_header "Remove Telcoin Node"

    print_warn "This will remove the Telcoin node(s) from this server."
    echo ""

    if ! confirm "Proceed with node removal?"; then
        print_info "Cancelled -- no changes made."
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi

    echo ""

    local -a targets=("${INSTALLED_UNITS[@]}")
    local unit
    for unit in "${targets[@]}"; do
        remove_node_unit "$unit"
    done

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

    # One node per VM is the norm, but a legacy unit may coexist -- offer each
    # installed unit individually so the operator confirms per node. Units come
    # from detect_node_installs (driven by tn_all_node_services).
    local unit ntype ddir
    for unit in "${INSTALLED_UNITS[@]}"; do
        ntype="${UNIT_TYPE[$unit]:-node}"
        print_warn "This will wipe all ${ntype} chain data (${unit}). The node will resync."
        if confirm "Wipe ${ntype} chain data?"; then
            ddir="$(detect_data_dir "$ntype")"
            wait_for_service_stopped "$unit"
            rm -rf "${ddir}/db"
            systemctl start "$unit" 2>/dev/null || true
            print_ok "${ntype^} chain data wiped -- node restarted (${unit})"
        fi
        echo ""
    done

    read -r -p "  Press Enter to return to menu..."
}

# =============================================================================
# MAIN MENU
# =============================================================================

# =============================================================================
# CUSTOM / NON-STANDARD INSTALL SCAN
#
# Finds Telcoin nodes NOT installed by these scripts (manual installs, dev
# deployments, docker containers in other locations). Read-only by default;
# offers removal ONLY for the well-identified, reversible items (custom systemd
# services + docker containers). Data dirs / binaries / processes are REPORTED
# with the exact manual command -- never auto-deleted, never killed -- because
# name-matching is too loose to safely rm -rf and killing a node mid-write
# corrupts the DB. Everything is timeout-guarded so it can't hang on a bad mount.
# =============================================================================

# 0 (true) if a path belongs to the standard install or the deployment tooling
# itself (these scripts, the UI, the updater) -- i.e. NOT a custom item.
custom_is_excluded_path() {
    local p="$1"
    case "$p" in
        /opt/telcoin|/opt/telcoin/*|/opt/telcoin-source|/opt/telcoin-source/*) return 0 ;;
        /var/lib/telcoin|/var/lib/telcoin/*) return 0 ;;
        /etc/telcoin|/etc/telcoin/*) return 0 ;;
        /var/log/telcoin|/var/log/telcoin/*) return 0 ;;
        /opt/telcoin-ui|/opt/telcoin-ui/*|/opt/telcoin-ui-update|/opt/telcoin-ui-update/*) return 0 ;;
        *telcoin-node-scripts*|*tn-node-deployment*) return 0 ;;   # the scripts themselves
        "${SCRIPT_DIR}"|"${SCRIPT_DIR}"/*) return 0 ;;
    esac
    # Exclude the installed node's own data dir (standard, even if on a custom
    # drive). The resolver yields the single unified/legacy dir for this VM.
    local dd
    dd=$(detect_data_dir "$(tn_resolve_node_type 2>/dev/null || echo validator)")
    [[ "$p" == "$dd" || "$p" == "$dd"/* ]] && return 0
    return 1
}

# 0 (true) if a unit/container BASE name belongs to a node this tooling manages
# (the new telcoin unit, either legacy unit, or the Node Manager UI) and so must
# not be reported as a "custom" install. The node names come from
# tn_all_node_services so no legacy literal is hardcoded here.
custom_is_managed_name() {
    local name="$1" n
    [[ "$name" == "telcoin-ui" ]] && return 0
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        [[ "$name" == "$n" ]] && return 0
    done < <(tn_all_node_services)
    return 1
}

scan_custom_installs() {
    print_header "Scan for non-standard / custom installs"
    print_info "Read-only scan for Telcoin nodes NOT installed by these scripts"
    print_info "(manual installs, dev deployments, docker containers elsewhere)."
    echo ""
    local found=false

    # --- Custom systemd services (offer removal) ---------------------------
    # Collect first, THEN prompt. A `confirm` inside `while read < <(...)` reads
    # from the process-substitution stream (not the terminal), so the prompt is
    # skipped at EOF -- the matches go into an array and we iterate that instead.
    local svc svcname
    local -a custom_svcs=()
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        svcname=$(basename "$svc")
        # Skip the units this tooling manages (telcoin / legacy / UI).
        custom_is_managed_name "${svcname%.service}" && continue
        custom_svcs+=("$svc")
    done < <(grep -rlE 'telcoin-network|/tn-public' /etc/systemd/system/*.service 2>/dev/null || true)
    for svc in "${custom_svcs[@]}"; do
        svcname=$(basename "$svc")
        found=true
        print_warn "[CUSTOM] Service: ${svcname}  (${svc})"
        if confirm "  Stop, disable and remove ${svcname}?"; then
            systemctl stop "$svcname" 2>/dev/null || true
            systemctl disable "$svcname" 2>/dev/null || true
            rm -f "$svc"
            systemctl daemon-reload
            print_ok "  Removed ${svcname}"
        fi
    done

    # --- Custom docker containers (offer removal) --------------------------
    if command -v docker >/dev/null 2>&1; then
        local cline cname cimage cstatus
        local -a custom_ctrs=()
        while IFS= read -r cline; do
            [[ -z "$cline" ]] && continue
            cname=${cline%%$'\t'*}
            # Skip the containers this tooling manages (telcoin / legacy names).
            custom_is_managed_name "$cname" && continue
            custom_ctrs+=("$cline")
        done < <(timeout -k 2 5 docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null \
                   | grep -E 'telcoin-network/tn-public|/tn-public/|-adiri' || true)
        for cline in "${custom_ctrs[@]}"; do
            IFS=$'\t' read -r cname cimage cstatus <<< "$cline"
            found=true
            print_warn "[CUSTOM] Docker container: ${cname}  (image: ${cimage}; ${cstatus})"
            if confirm "  Stop and remove container ${cname}?"; then
                docker stop "$cname" >/dev/null 2>&1 || true
                docker rm "$cname" >/dev/null 2>&1 || true
                print_ok "  Removed container ${cname}"
            fi
        done
    fi

    # --- Custom data directories (REPORT ONLY) -----------------------------
    # Name-match telcoin* dirs, but only flag ones that actually look like node
    # data (a node-info.yaml / db / genesis / node-keys inside) -- so a service
    # user's home dir (e.g. /home/telcoin1) isn't mis-reported as chain data.
    local d
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        custom_is_excluded_path "$d" && continue
        [[ -f "${d}/node-info.yaml" || -d "${d}/db" || -d "${d}/genesis" || -d "${d}/node-keys" ]] || continue
        found=true
        print_warn "[CUSTOM] Data directory: ${d}"
        print_info  "  Remove manually if unwanted:  sudo rm -rf '${d}'"
    done < <(timeout -k 2 8 find /mnt /opt /data /srv /home -maxdepth 4 \
                  -type d -name 'telcoin*' -prune -print 2>/dev/null || true)

    # --- Custom binaries (REPORT ONLY) -------------------------------------
    local b
    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        custom_is_excluded_path "$b" && continue
        found=true
        print_warn "[CUSTOM] Binary: ${b}"
        print_info  "  Remove manually if unwanted:  sudo rm -f '${b}'"
    done < <(timeout -k 2 8 find /usr/local/bin /usr/bin /opt /srv /home -maxdepth 5 \
                  -type f -name 'telcoin-network' 2>/dev/null || true)

    # --- Unmanaged processes (REPORT ONLY -- never killed) -----------------
    local pid cmd cg n managed
    while read -r pid cmd; do
        [[ -z "$pid" ]] && continue
        # Skip anything owned by a known systemd unit or by docker/containerd
        # (a managed docker node's process lives under docker's cgroup, and is
        # already covered by the container scan above).
        cg=$(cat "/proc/${pid}/cgroup" 2>/dev/null || true)
        case "$cg" in
            *docker*|*containerd*) continue ;;
        esac
        # Skip cgroups owned by a unit this tooling manages (telcoin / legacy).
        managed=false
        while IFS= read -r n; do
            [[ -z "$n" ]] && continue
            [[ "$cg" == *"$n"* ]] && { managed=true; break; }
        done < <(tn_all_node_services)
        [[ "$managed" == "true" ]] && continue
        found=true
        print_warn "[CUSTOM] Unmanaged process: PID ${pid}"
        print_info  "  ${cmd}"
        print_info  "  Stop it via its own service/container -- do not kill a node mid-write."
    done < <(pgrep -a telcoin-network 2>/dev/null || true)

    echo ""
    if [[ "$found" == "false" ]]; then
        print_ok "No non-standard / custom Telcoin installs found."
    else
        print_info "Services and containers above could be removed here; data dirs,"
        print_info "binaries and processes were reported only -- act on them deliberately"
        print_info "with the commands shown."
    fi
    echo ""
    read -r -p "  Press Enter to continue..."
}

main_menu() {
    while true; do
        clear
        detect_node_installs
        print_header "Telcoin Network -- Node Removal  v${SCRIPT_VERSION}"
        show_detected

        # One node per VM is the norm, so a single set of actions covers it. If a
        # legacy unit happens to coexist with the new one, "Remove node" tears down
        # every installed unit (remove_all_nodes iterates them all).
        if [[ ${#INSTALLED_UNITS[@]} -eq 0 ]]; then
            exit 0
        fi

        echo "  What would you like to do?"
        echo ""
        if [[ ${#INSTALLED_UNITS[@]} -gt 1 ]]; then
            echo "  1) Remove all detected Telcoin nodes"
        else
            echo "  1) Remove the Telcoin node"
        fi
        echo "  2) Wipe chain data only (keeps keys and config)"
        echo "  s) Scan for non-standard / custom installs"
        echo "  3) Exit"
        echo ""
        local choice
        read -r -p "  Enter choice [1-3 or s]: " choice
        case "$choice" in
            1) remove_all_nodes ;;
            2) wipe_chain_data_only ;;
            s|S) scan_custom_installs ;;
            3) echo ""; print_info "Exiting."; exit 0 ;;
            *) print_warn "Please enter 1-3 or s." ;;
        esac
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

    # Resolve the actually-installed node (unified telcoin unit, or a legacy unit)
    # instead of assuming telcoin-<type>. The requested node_type must match what
    # is installed -- one node per VM -- so a mismatched request still errors out
    # exactly as before rather than silently removing the wrong node.
    local svc unit installed_type
    svc="$(tn_resolve_service)" || { json_event error "node not installed: ${node_type}"; return 1; }
    installed_type="$(tn_resolve_node_type 2>/dev/null || echo "")"
    if [[ -n "$installed_type" && "$installed_type" != "$node_type" ]]; then
        json_event error "node not installed: ${node_type}"
        return 1
    fi
    unit="/etc/systemd/system/${svc}.service"

    # Detect docker BEFORE removing the unit (.node-meta is authoritative; fall
    # back to the legacy inline `docker run` in the unit).
    local is_docker=false
    local meta
    meta="$(tn_resolve_config_dir)/.node-meta"
    if [[ "$(grep '^INSTALL_METHOD=' "$meta" 2>/dev/null | cut -d= -f2- || true)" == "docker" ]] \
       || grep -q "docker run" "$unit" 2>/dev/null; then
        is_docker=true
    fi

    # Resolve the service user/group BEFORE deleting the unit/.node-meta, so a
    # 'keys' (full) removal can clean up the account instead of orphaning it.
    # .node-meta is authoritative; the unit's User=/Group= is the fallback (but
    # docker units run as root, so ignore root and use the default service name).
    local svc_user="" svc_group=""
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

    json_event step "Stopping and disabling ${svc}"
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "$unit"
    systemctl daemon-reload

    if [[ "$is_docker" == "true" ]] && command -v docker >/dev/null 2>&1; then
        local ctr
        ctr="$(tn_resolve_container 2>/dev/null || echo "$svc")"
        json_event step "Removing docker container ${ctr}"
        docker stop "$ctr" 2>/dev/null || true
        docker rm "$ctr" 2>/dev/null || true
    fi

    if [[ "$scope" == "data" || "$scope" == "keys" ]]; then
        if [[ -d "$data_dir" ]]; then
            json_event step "Removing chain data ${data_dir}"
            rm -rf "$data_dir"
        fi
    fi

    if [[ "$scope" == "keys" ]]; then
        local config_dir
        config_dir="$(tn_resolve_config_dir)"
        json_event step "Removing keys and config ${config_dir}"
        rm -rf "${data_dir}/node-keys" 2>/dev/null || true
        if declare -f tpm_remove_sealed_files >/dev/null 2>&1; then
            tpm_remove_sealed_files "$config_dir" 2>/dev/null || true
        fi
        rm -rf "$config_dir" 2>/dev/null || true

        # Full removal: tear down the testnet add-ons too -- the Alloy log shipper holds
        # the mode-600 ingest token, and the WireGuard overlay leaves a sudo tnadmin user
        # + maintainer keys behind. Under --json, remove_testnet_addons' print_* output
        # goes to stderr (benign); it never writes to the JSON fd.
        if declare -f remove_testnet_addons >/dev/null 2>&1; then
            json_event step "Removing testnet add-ons (Alloy log shipper, VPN admin overlay)"
            remove_testnet_addons || true
        fi

        # Full removal: also drop the service user/group (skip root; keep if a
        # sibling node still uses the account).
        if [[ "$svc_user" != "root" ]] && id "$svc_user" &>/dev/null \
           && ! user_used_by_other_node "$svc_user" "$svc"; then
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

    json_emit "{\"event\":\"done\",\"ok\":true,\"node_type\":\"$(json_escape "$node_type")\",\"scope\":\"$(json_escape "$scope")\",\"ui_removed\":${ui_scheduled},\"msg\":\"${svc} removed (scope: ${scope})\"}"
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
