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

readonly SCRIPT_VERSION="1.2.9"

# Root prepended to the systemd unit directory and to the host files removed
# beside the node (unit backups and drop-ins, start scripts, node.env, backups,
# logrotate and journald files, the lock directory). It is the same root the
# resolvers in lib/fallback.sh probe: empty in production, a fixture tree in
# tools/tests/remove_test.sh. The older shared paths (/opt/telcoin,
# /opt/telcoin-source, /var/log/telcoin) and the scan are not prefixed.
TN_RM_ROOT="${TN_ROOT_PREFIX:-}"

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

# rm_meta_get KEY META -- print KEY's value from the .node-meta file META (nothing
# when KEY is absent; rc 0 either way). A key set more than once has no single
# value: print an error naming KEY and return 2, so the caller stops instead of
# guessing which account or directory to delete.
rm_meta_get() {
    local v rc=0
    v="$(meta_get "$1" "$2" 2>/dev/null)" || rc=$?
    if [[ $rc -eq 2 ]]; then
        print_error "${1} is set more than once in ${2}; keep one line and run this again. This node is not removed."
        return 2
    fi
    printf '%s\n' "$v"
}

# Resolve a node's data dir from its .node-meta (DATA_DIR=), falling back to the
# resolver's path (/var/lib/telcoin for the unified install, /var/lib/telcoin/<role>
# for a legacy install). Mirrors check-node.sh so all scripts agree on the path.
# Echoes a path and returns 0, except when DATA_DIR is set more than once in
# .node-meta: then it prints the error, echoes nothing and returns 2, and the
# caller removes nothing.
detect_data_dir() {
    local meta dd
    meta="$(tn_resolve_config_dir)/.node-meta"
    if [[ -f "$meta" ]]; then
        dd="$(rm_meta_get DATA_DIR "$meta")" || return 2
        if [[ -n "$dd" ]] && [[ -d "$dd" ]]; then
            printf '%s\n' "$dd"
            return 0
        fi
    fi
    tn_resolve_data_dir
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
        unit="${TN_RM_ROOT}/etc/systemd/system/${name}.service"
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

# Per-unit detection state. INSTALLED_UNITS lists the unit BASE names found present
# (the new "telcoin" unit or, for a legacy install, one of the legacy unit names
# from tn_all_node_services). The three arrays beside it hold, at the same index,
# that unit's install method (true for docker), service user and service group.
# They are plain indexed arrays kept in step, not associative arrays, so the script
# runs under macOS /bin/bash 3.2. Operators run one node per VM, so this is normally
# a single entry -- but a stray legacy unit alongside the new one is still torn down.
declare -a INSTALLED_UNITS=()
declare -a UNIT_DOCKER=()
declare -a UNIT_USER=()
declare -a UNIT_GROUP=()
# Units whose .node-meta sets HOST_SERVICE_USER, HOST_SERVICE_GROUP,
# INSTALL_METHOD or DATA_DIR more than once. They stay in INSTALLED_UNITS (so a
# sibling's teardown keeps the shared components) but are never removed.
declare -a BLOCKED_UNITS=()

# unit_blocked UNIT -- 0 when UNIT is in BLOCKED_UNITS.
unit_blocked() {
    local want="$1" u
    for u in ${BLOCKED_UNITS[@]+"${BLOCKED_UNITS[@]}"}; do
        [[ "$u" == "$want" ]] && return 0
    done
    return 1
}

# unit_index UNIT -- print UNIT's index in INSTALLED_UNITS (and so in UNIT_DOCKER,
# UNIT_USER and UNIT_GROUP). Returns 1 and prints nothing when UNIT is not there.
unit_index() {
    local want="$1" i=0 u
    for u in ${INSTALLED_UNITS[@]+"${INSTALLED_UNITS[@]}"}; do
        if [[ "$u" == "$want" ]]; then
            printf '%s\n' "$i"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# forget_unit UNIT -- drop UNIT from INSTALLED_UNITS and from the same index of the
# three arrays beside it, so every remaining unit keeps its own method/user/group.
forget_unit() {
    local gone="$1" i=0 n
    local -a units=() dockers=() users=() groups=()
    n=${#INSTALLED_UNITS[@]}
    while [[ $i -lt $n ]]; do
        if [[ "${INSTALLED_UNITS[$i]}" != "$gone" ]]; then
            units+=("${INSTALLED_UNITS[$i]}")
            dockers+=("${UNIT_DOCKER[$i]:-false}")
            users+=("${UNIT_USER[$i]:-}")
            groups+=("${UNIT_GROUP[$i]:-}")
        fi
        i=$((i + 1))
    done
    INSTALLED_UNITS=(${units[@]+"${units[@]}"})
    UNIT_DOCKER=(${dockers[@]+"${dockers[@]}"})
    UNIT_USER=(${users[@]+"${users[@]}"})
    UNIT_GROUP=(${groups[@]+"${groups[@]}"})
}

# Populate the per-unit state above by enumerating every candidate unit name from
# tn_all_node_services (telcoin + the legacy names) and inspecting the ones that
# are actually installed. .node-meta is authoritative; the unit's User=/Group= is
# the fallback. The config dir comes from the resolvers. No role is recorded:
# the role is decided on-chain each epoch, not by anything on this server. A key
# set more than once in .node-meta puts the unit in BLOCKED_UNITS.
detect_node_installs() {
    set +e  # grep returning no match is fine here
    INSTALLED_UNITS=()
    UNIT_DOCKER=(); UNIT_USER=(); UNIT_GROUP=()
    BLOCKED_UNITS=()

    local unit_name unit_file meta method is_docker svc_user svc_group dup
    while IFS= read -r unit_name; do
        [[ -z "$unit_name" ]] && continue
        unit_file="${TN_RM_ROOT}/etc/systemd/system/${unit_name}.service"
        [[ -f "$unit_file" ]] || continue

        is_docker=false
        svc_user=""
        svc_group=""

        # Config dir resolves from the on-disk layout (one node per VM).
        meta="$(config_dir_for_unit "$unit_name")/.node-meta"

        # Read from metadata file first (most reliable, set during setup).
        if [[ -f "$meta" ]]; then
            dup=false
            svc_user="$(rm_meta_get HOST_SERVICE_USER "$meta")" || dup=true
            svc_group="$(rm_meta_get HOST_SERVICE_GROUP "$meta")" || dup=true
            method="$(rm_meta_get INSTALL_METHOD "$meta")" || dup=true
            rm_meta_get DATA_DIR "$meta" >/dev/null || dup=true
            [[ "$method" == "docker" ]] && is_docker=true
            [[ "$dup" == "true" ]] && BLOCKED_UNITS+=("$unit_name")
        else
            # Fall back to reading the service file.
            svc_user=$(grep "^User=" "$unit_file" | cut -d= -f2 || echo "")
            svc_group=$(grep "^Group=" "$unit_file" | cut -d= -f2 || echo "")
            if grep -q "docker" "$unit_file" 2>/dev/null; then
                is_docker=true
            fi
        fi

        # Append to all four together so the indexes stay aligned.
        INSTALLED_UNITS+=("$unit_name")
        UNIT_DOCKER+=("$is_docker")
        UNIT_USER+=("$svc_user")
        UNIT_GROUP+=("$svc_group")
    done < <(tn_all_node_services)
    set -e
}

show_detected() {
    # errexit is off while the report runs and restored to the caller's setting
    # at the end, so it no longer leaks into the menu.
    local errexit_was_on=false
    [[ "$-" == *e* ]] && errexit_was_on=true
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
                # Shred the key and passphrase files these trees can hold first
                # (unified layout and the legacy per-role subdirectories).
                local sub
                for sub in "" /validator /observer; do
                    shred_key_files "/var/lib/telcoin${sub}/node-keys" "/etc/telcoin${sub}"
                done
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

    local i=0 unit install_type status
    while [[ $i -lt ${#INSTALLED_UNITS[@]} ]]; do
        unit="${INSTALLED_UNITS[$i]}"
        install_type="binary/source"
        [[ "${UNIT_DOCKER[$i]:-false}" == "true" ]] && install_type="Docker"
        print_ok "Node detected (${unit})"
        print_info "  Install type:  ${install_type}"
        print_info "  Service user:  ${UNIT_USER[$i]:-unknown}"
        print_info "  Service group: ${UNIT_GROUP[$i]:-(none)}"
        status=$(systemctl is-active "$unit" 2>/dev/null || echo "inactive")
        print_info "  Status:        ${status}"
        if unit_blocked "$unit"; then
            print_warn "  Removal blocked: .node-meta sets a key more than once (see the error above)."
        fi
        echo ""
        i=$((i + 1))
    done
    if [[ "$errexit_was_on" == "true" ]]; then
        set -e
    fi
}

# =============================================================================
# REMOVAL FUNCTIONS
# =============================================================================

_RM_SHRED_NOTED=false

# _rm_shred FILE... -- delete each FILE. A regular file is overwritten first with
# `shred -u` when shred is installed; `rm -f` always follows, so a missing or
# failing shred still deletes it. A symlink is unlinked itself and never
# followed; a directory or an absent path is left alone. Always returns 0.
_rm_shred() {
    local f
    for f in "$@"; do
        if [[ -L "$f" ]]; then
            rm -f -- "$f" 2>/dev/null || true
        elif [[ -f "$f" ]]; then
            if [[ "$_RM_SHRED_NOTED" != "true" ]]; then
                _RM_SHRED_NOTED=true
                print_info "Overwriting files with shred before deleting them is best effort on SSDs, copy-on-write and cloud disks."
            fi
            if command -v shred >/dev/null 2>&1; then
                shred -u -- "$f" >/dev/null 2>&1 || true
            fi
            rm -f -- "$f" 2>/dev/null || true
        fi
    done
    return 0
}

# _rm_shred_tree DIR -- _rm_shred every regular file under DIR. Nothing is done
# when DIR is a symlink; symlinks inside DIR are not followed. DIR itself is
# left for the caller to remove.
_rm_shred_tree() {
    local f
    local -a files=()
    [[ -d "$1" && ! -L "$1" ]] || return 0
    while IFS= read -r f; do
        [[ -n "$f" ]] && files+=("$f")
    done < <(find "$1" -type f 2>/dev/null)
    _rm_shred ${files[@]+"${files[@]}"}
}

# _rm_dir DIR -- rm -rf the real directory DIR; a symlink named DIR is unlinked
# and its target left alone. Always returns 0.
_rm_dir() {
    if [[ -L "$1" ]]; then
        rm -f -- "$1" 2>/dev/null || true
    elif [[ -d "$1" ]]; then
        rm -rf -- "$1" 2>/dev/null || true
    fi
    return 0
}

# remove_unit_leftovers UNIT -- remove what older releases left beside the unit
# file: the UNIT.bak.* and UNIT.service.bak.* copies (shredded: they can hold the
# passphrase) and the drop-in directory UNIT.service.d.
remove_unit_leftovers() {
    local unit="$1" sd f
    sd="${TN_RM_ROOT}/etc/systemd/system"
    for f in "${sd}/${unit}.bak."* "${sd}/${unit}.service.bak."*; do
        _rm_shred "$f"
    done
    _rm_dir "${sd}/${unit}.service.d"
}

stop_and_disable_service() {
    local service_name="$1"
    print_step "Stopping and disabling ${service_name}..."
    systemctl stop "$service_name" 2>/dev/null || true
    systemctl disable "$service_name" 2>/dev/null || true
    rm -f "${TN_RM_ROOT}/etc/systemd/system/${service_name}.service"
    remove_unit_leftovers "$service_name"
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
    local data_dir
    if ! data_dir="$(detect_data_dir)" || [[ -z "$data_dir" ]]; then
        print_error "Chain data not removed: the data directory is unknown."
        return 1
    fi

    if [[ -d "$data_dir" ]]; then
        local size
        size=$(du -sh "$data_dir" 2>/dev/null | cut -f1)
        print_info "Chain data at ${data_dir} (${size})"
        if confirm "Remove chain data? (node will need to resync if reinstalled)"; then
            # The node keys under the data dir go with it: shred them first.
            if [[ ! -L "$data_dir" ]]; then
                _rm_shred_tree "${data_dir}/node-keys"
            fi
            rm -rf "$data_dir"
            print_ok "Chain data removed"
        else
            print_info "Chain data kept at ${data_dir}"
        fi
    fi
}

# shred_key_files KEYS_DIR CONFIG_DIR -- shred every file under KEYS_DIR and
# remove it, then shred the passphrase files in CONFIG_DIR and in /etc/telcoin:
# the encrypted credential bls-passphrase.cred, the plaintext bls-passphrase and
# the TPM-sealed bls-tpm.pub / bls-tpm.priv of very old installs. The caller
# removes CONFIG_DIR.
shred_key_files() {
    local keys_dir="$1" config_dir="$2" d
    _rm_shred_tree "$keys_dir"
    _rm_dir "$keys_dir"
    for d in "$config_dir" "${TN_RM_ROOT}/etc/telcoin"; do
        _rm_shred "${d}/bls-passphrase.cred" "${d}/bls-passphrase" \
                  "${d}/bls-tpm.pub" "${d}/bls-tpm.priv"
    done
}

# The warning is the same for every node: the role is decided on-chain, so
# nothing on this server says whether these keys are staked to validate.
remove_keys() {
    local data_dir keys_dir config_dir
    if ! data_dir="$(detect_data_dir)" || [[ -z "$data_dir" ]]; then
        print_error "Keys not removed: the data directory is unknown."
        return 1
    fi
    keys_dir="${data_dir}/node-keys"
    config_dir="$(tn_resolve_config_dir)"

    if [[ -d "$keys_dir" ]] || [[ -d "$config_dir" ]]; then
        echo ""
        print_warn "================================================================"
        print_warn "  KEY DELETION WARNING"
        print_warn "================================================================"
        print_warn "This will permanently delete your node keys and passphrase."
        print_warn "Node keys CANNOT be recovered without the passphrase."
        print_warn "If these keys are staked to validate, you will need to"
        print_warn "re-register with the Telcoin Association and generate new"
        print_warn "keys if you reinstall."
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
            shred_key_files "$keys_dir" "$config_dir"
            rm -rf "$config_dir"
            print_ok "Keys and passphrase removed"
        else
            print_info "Keys kept -- skipping key removal"
        fi
    fi
}

# remove_node_host_files -- remove the host files every node install shares:
# the start scripts in /usr/local/libexec/telcoin (and that directory when it is
# empty), /etc/telcoin/node.env, the backups in /var/backups/telcoin (shredded:
# they can hold unit, launch-file and passphrase copies), the logrotate file
# (TN_LOGROTATE_FILE), the journald drop-in 50-telcoin.conf and the lock
# directory /run/telcoin, the release staging directory /var/lib/telcoin-staging,
# and the source-build account tn-build with its home /var/lib/tn-build. The
# caller runs it only when no other node install
# remains. Every path is under TN_RM_ROOT (see the top of this file).
remove_node_host_files() {
    local r="$TN_RM_ROOT" m f
    local -a files=()
    for m in source docker; do
        f="$(tn_start_script_path "$m")" || continue
        files+=("${r}${f}")
    done
    files+=("${r}/etc/telcoin/node.env"
            "${TN_LOGROTATE_FILE:-${r}/etc/logrotate.d/telcoin}"
            "${r}/etc/systemd/journald.conf.d/50-telcoin.conf")
    for f in "${files[@]}"; do
        if [[ -L "$f" || -f "$f" ]]; then
            rm -f -- "$f" 2>/dev/null || true
            print_ok "Removed ${f#"$r"}"
        fi
    done
    rmdir "${r}/usr/local/libexec/telcoin" 2>/dev/null || true
    if [[ -L "${r}/var/backups/telcoin" || -d "${r}/var/backups/telcoin" ]]; then
        _rm_shred_tree "${r}/var/backups/telcoin"
        _rm_dir "${r}/var/backups/telcoin"
        print_ok "Removed /var/backups/telcoin"
    fi
    if [[ -L "${r}/run/telcoin" || -d "${r}/run/telcoin" ]]; then
        _rm_dir "${r}/run/telcoin"
        print_ok "Removed /run/telcoin"
    fi
    # Release staging (downloads and build logs) and the source-build account with
    # its home (toolchain, cargo cache, build output). lib/release-keys stays: it is
    # part of the operator's scripts tree.
    if [[ -L "${r}/var/lib/telcoin-staging" || -d "${r}/var/lib/telcoin-staging" ]]; then
        _rm_dir "${r}/var/lib/telcoin-staging"
        print_ok "Removed /var/lib/telcoin-staging"
    fi
    if [[ -z "$r" ]] && id -u tn-build >/dev/null 2>&1; then
        userdel tn-build >/dev/null 2>&1 || true
        print_ok "Removed the tn-build account"
    fi
    if [[ -L "${r}/var/lib/tn-build" || -d "${r}/var/lib/tn-build" ]]; then
        _rm_dir "${r}/var/lib/tn-build"
        print_ok "Removed /var/lib/tn-build"
    fi
    return 0
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

        remove_node_host_files
    fi
}

# Service groups left in place on purpose during this run: the operator declined
# to remove them, or a sibling node still uses the account. report_orphaned_groups
# lists these as kept rather than as possibly orphaned.
declare -a KEPT_GROUPS=()

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
        [[ -n "$service_group" ]] && KEPT_GROUPS+=("$service_group")
        remove_log_group "$service_user" "$self_unit"
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
        else
            KEPT_GROUPS+=("$service_group")
        fi
    fi

    remove_log_group "$service_user" "$self_unit"
}

# remove_log_group SERVICE_USER SELF_UNIT -- remove the log-reader group
# (TN_LOG_GROUP, telcoin-log) when no other node unit than SELF_UNIT is installed
# and getent lists no member in it but SERVICE_USER. Otherwise the group is kept
# and recorded in KEPT_GROUPS. RM_LOG_GROUP_MSG holds the outcome line (empty
# when the group does not exist) for the JSON path.
RM_LOG_GROUP_MSG=""
remove_log_group() {
    local svc_user="${1:-}" self_unit="${2:-}" g line m
    local -a list=() others=()
    g="${TN_LOG_GROUP:-telcoin-log}"
    RM_LOG_GROUP_MSG=""
    line="$(getent group "$g" 2>/dev/null)" || return 0
    [[ -n "$line" ]] || return 0
    if [[ -n "$(other_node_unit_files "$self_unit")" ]]; then
        RM_LOG_GROUP_MSG="Group ${g} is still used by the other Telcoin node -- keeping it."
        print_info "$RM_LOG_GROUP_MSG"
        KEPT_GROUPS+=("$g")
        return 0
    fi
    IFS=',' read -r -a list <<< "${line##*:}"
    for m in ${list[@]+"${list[@]}"}; do
        if [[ -n "$m" && "$m" != "$svc_user" ]]; then
            others+=("$m")
        fi
    done
    if [[ ${#others[@]} -gt 0 ]]; then
        RM_LOG_GROUP_MSG="Group ${g} still has other members (${others[*]}) -- keeping it."
        print_info "$RM_LOG_GROUP_MSG"
        KEPT_GROUPS+=("$g")
        return 0
    fi
    if groupdel "$g" 2>/dev/null; then
        RM_LOG_GROUP_MSG="Group ${g} removed"
        print_ok "$RM_LOG_GROUP_MSG"
    else
        RM_LOG_GROUP_MSG="Could not remove group ${g} (still in use?) -- run: groupdel ${g}"
        print_warn "Could not remove group '${g}' (still in use?). Remove manually:"
        print_info "  sudo groupdel ${g}"
    fi
    return 0
}

# 0 when GROUP was kept on purpose during this run (see KEPT_GROUPS).
group_was_kept() {
    local want="$1" g
    for g in ${KEPT_GROUPS[@]+"${KEPT_GROUPS[@]}"}; do
        [[ "$g" == "$want" ]] && return 0
    done
    return 1
}

# Report Telcoin-related groups still present after removal. A group kept on
# purpose (declined at the prompt, or still used by a sibling node) is listed as
# kept; any other may be orphaned (e.g. by an earlier crash where .node-meta + the
# unit were both gone). Matches the operator's quick check:
# getent group | grep -v telcoin-ui | grep telcoin.
report_orphaned_groups() {
    local groups g
    local -a kept=() orphaned=()
    groups=$(getent group | grep -v "telcoin-ui" | grep "telcoin" | cut -d: -f1 || true)
    [[ -z "$groups" ]] && return 0
    while IFS= read -r g; do
        [[ -z "$g" ]] && continue
        if group_was_kept "$g"; then
            kept+=("$g")
        else
            orphaned+=("$g")
        fi
    done <<< "$groups"
    if [[ ${#kept[@]} -gt 0 ]]; then
        echo ""
        print_info "Telcoin service group(s) kept:"
        for g in "${kept[@]}"; do
            print_info "  ${g}  ->  remove later with:  sudo groupdel ${g}"
        done
    fi
    if [[ ${#orphaned[@]} -gt 0 ]]; then
        echo ""
        print_warn "Possible orphaned Telcoin service group(s) still present:"
        for g in "${orphaned[@]}"; do
            print_info "  ${g}  ->  remove with:  sudo groupdel ${g}"
        done
    fi
}

# =============================================================================
# REMOVE NODE MANAGER UI
# =============================================================================

# Uninstall the Telcoin Node Manager UI (service, app, venv, helper + update
# engine, sudoers, access token, state dir, and the service user). The sudoers
# file goes first, so the UI account loses its grants before anything else
# changes. The helper's audit log (/var/log/telcoin-ui) stays as a record. Safe
# to call when the UI is absent / partial.
remove_ui_components() {
    print_step "Removing Telcoin Node Manager UI..."
    rm -f /etc/sudoers.d/telcoin-ui
    # An interrupted install-ui.sh run can leave its sudoers candidate (inert:
    # sudo skips names with a dot).
    rm -f /etc/sudoers.d/.telcoin-ui.*
    systemctl stop telcoin-ui 2>/dev/null || true
    systemctl disable telcoin-ui 2>/dev/null || true
    rm -f /etc/systemd/system/telcoin-ui.service
    systemctl daemon-reload 2>/dev/null || true
    rm -rf /opt/telcoin-ui /opt/telcoin-ui-venv /opt/telcoin-ui-update
    # Temp trees an interrupted install-ui.sh run can leave beside them.
    rm -rf /opt/.telcoin-ui.* /opt/.telcoin-ui-venv.* /opt/.telcoin-ui-update.*
    rm -f /usr/local/sbin/telcoin-ui-helper /usr/local/sbin/telcoin-ui-helper.new
    rm -rf /etc/telcoin-ui /var/lib/telcoin-ui
    if id telcoin-ui &>/dev/null; then
        userdel telcoin-ui 2>/dev/null || true
    fi
    print_ok "Telcoin Node Manager UI removed"
    if [[ -d /var/log/telcoin-ui ]]; then
        print_info "The UI audit log stays in /var/log/telcoin-ui (remove it by hand when no longer needed)."
    fi
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
# were enabled (each step guards on the component existing or is a no-op).
# Called from the node full-removal flow. The VPN files, the tnadmin sudoers file,
# the account and the overlay SSH rules go whether or not wg0 is still up or
# configured, so a half-removed VPN is cleared too. TN_ROOT_PREFIX (empty in
# production) roots the file paths for the fixture test.
remove_testnet_addons() {
    local found p="${TN_ROOT_PREFIX:-}" f left=false reload=false sp cidr
    local -a vpn_files=(/etc/wireguard/wg0.conf /etc/wireguard/wg0-private.key
        /etc/systemd/system/tn-nftables.service /etc/wgvpn/nftables-node.nft
        /usr/local/sbin/tn-node-ssh-lockdown
        /etc/wgvpn/tnadmin.keys /etc/wgvpn/tnadmin.revoked /etc/wgvpn/tnadmin.authorized_keys
        /etc/sudoers.d/90-tnadmin)
    local dropin=/etc/ssh/sshd_config.d/15-tnadmin-overlay.conf
    found="$(tn_testnet_addons_present 2>/dev/null || true)"
    if [[ -n "$found" ]]; then
        print_info "Testnet add-ons found on this host: ${found}."
    fi
    # --- Alloy log shipper -----------------------------------------------------
    if [[ -f "${p}/etc/systemd/system/telcoin-alloy.service" ]] || systemctl list-unit-files 2>/dev/null | grep -q '^telcoin-alloy.service'; then
        print_info "Removing Alloy log shipper (telcoin-alloy)..."
        systemctl disable --now telcoin-alloy.service >/dev/null 2>&1 || true
        docker rm -f telcoin-alloy >/dev/null 2>&1 || true
        docker rmi "${TN_ALLOY_IMAGE:-grafana/alloy:v1.5.1}" >/dev/null 2>&1 || true
        rm -f "${p}/etc/systemd/system/telcoin-alloy.service"
        rm -f "${p}/usr/local/bin/alloy"   # native tarball install path (no-op for apt/docker installs)
        systemctl daemon-reload 2>/dev/null || true
    fi
    rm -rf "${p}/etc/telcoin/alloy" "${p}/var/lib/telcoin-alloy"
    if id -u telcoin-alloy >/dev/null 2>&1; then
        userdel telcoin-alloy >/dev/null 2>&1 || true
    fi

    # --- VPN self-heal ----------------------------------------------------------
    # Stopped and removed first: its path unit watches the sshd drop-in removed
    # below, and would otherwise run the helper again and put the drop-in back.
    if [[ -e "${p}/etc/systemd/system/tn-vpn-selfheal.path" || -e "${p}/etc/systemd/system/tn-vpn-selfheal.service" \
          || -e "${p}/usr/local/sbin/tn-vpn-selfheal" ]]; then
        print_info "Removing the VPN self-heal units and helper..."
        systemctl disable --now tn-vpn-selfheal.path tn-vpn-selfheal.service >/dev/null 2>&1 || true
        rm -f "${p}/etc/systemd/system/tn-vpn-selfheal.path" "${p}/etc/systemd/system/tn-vpn-selfheal.service" \
              "${p}/usr/local/sbin/tn-vpn-selfheal"
        systemctl daemon-reload 2>/dev/null || true
    fi

    # --- WireGuard admin overlay: the link -------------------------------------
    if [[ -f "${p}/etc/wireguard/wg0.conf" ]] || ip link show wg0 >/dev/null 2>&1; then
        print_info "Removing WireGuard admin overlay (wg0)..."
        wg-quick down wg0 >/dev/null 2>&1 || true
        systemctl disable wg-quick@wg0.service >/dev/null 2>&1 || true
        print_info "Note: ask the Telcoin Association to de-enroll this node's overlay peer."
    fi

    # --- VPN files, sudoers, account and firewall rules ------------------------
    for f in "${vpn_files[@]}" "$dropin"; do
        if [[ -e "${p}${f}" || -L "${p}${f}" ]]; then
            left=true
        fi
    done
    if [[ "$left" == "true" ]] || id -u tnadmin >/dev/null 2>&1; then
        print_info "Removing the admin overlay files, the tnadmin account and its sudo rules..."
    fi
    if [[ -e "${p}/etc/systemd/system/tn-nftables.service" ]]; then
        systemctl disable --now tn-nftables.service >/dev/null 2>&1 || true
        reload=true
    fi
    if [[ -e "${p}${dropin}" || -L "${p}${dropin}" ]]; then
        rm -f "${p}${dropin}"
        if sshd -t >/dev/null 2>&1; then systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true; fi
    fi
    for f in "${vpn_files[@]}"; do
        rm -f "${p}${f}"
    done
    rmdir "${p}/etc/wgvpn" 2>/dev/null || true
    if [[ "$reload" == "true" ]]; then
        systemctl daemon-reload 2>/dev/null || true
    fi
    # The overlay SSH rules (mirrors setup-vpn.sh --disable): the maintainers' admin
    # range and the whole-overlay rule older releases added. ufw edits its rule
    # files when inactive too, and deleting a rule that is not there is a no-op.
    if ufw_installed; then
        sp="$(get_ssh_port)"; [[ -n "$sp" ]] || sp=22
        for cidr in "${TN_OVERLAY_ADMIN_CIDR:-}" "${TN_OVERLAY_CIDR:-}"; do
            [[ -n "$cidr" ]] || continue
            ufw delete allow from "$cidr" to any port "${sp}" proto tcp &>/dev/null || true
        done
    fi
    if id -u tnadmin >/dev/null 2>&1; then
        userdel -r tnadmin >/dev/null 2>&1 || true
    fi
}

# =============================================================================
# REMOVE A NODE  (drives the unit/container/dir teardown from the resolvers)
# =============================================================================

# Tear down a SINGLE installed node unit and everything tied to it: the systemd
# unit, the docker container (when the install method is docker), chain data,
# keys/config, the host-wide testnet add-ons, shared components, and the service
# user. $1 is the unit base name (the new "telcoin" unit or a legacy unit name)
# discovered by detect_node_installs; its dirs come from the resolvers.
# Prunes the unit from INSTALLED_UNITS so a follow-on remove_shared_components
# sees the correct remaining count.
remove_node_unit() {
    local unit="$1"
    local idx is_docker svc_user svc_group
    if unit_blocked "$unit"; then
        print_error "Not removing ${unit}: its .node-meta sets a key more than once (see above). Nothing was changed."
        return 1
    fi
    is_docker=false
    svc_user=""
    svc_group=""
    if idx="$(unit_index "$unit")"; then
        is_docker="${UNIT_DOCKER[$idx]:-false}"
        svc_user="${UNIT_USER[$idx]:-}"
        svc_group="${UNIT_GROUP[$idx]:-}"
    fi

    # Stop service
    stop_and_disable_service "$unit"

    # Docker container if applicable. The container shares the unit's base name
    # (new install: telcoin; legacy: telcoin-<role>); confirm via the resolver,
    # then attempt removal by that name and guard the shared image.
    if [[ "$is_docker" == "true" ]]; then
        local ctr
        ctr="$(tn_resolve_container 2>/dev/null || echo "$unit")"
        remove_docker_container "$ctr" "$unit"
    fi

    # Chain data
    remove_chain_data

    # Keys -- separate explicit confirmation
    remove_keys

    # Testnet add-ons (Alloy log shipper + WireGuard admin overlay)
    remove_testnet_addons

    # Shared components
    remove_shared_components

    # Service user
    remove_service_user "$svc_user" "$svc_group" "$unit"

    echo ""
    print_ok "Node removal complete (${unit})"

    # Prune from the installed set so remaining-node accounting stays correct.
    forget_unit "$unit"

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

    local -a targets=(${INSTALLED_UNITS[@]+"${INSTALLED_UNITS[@]}"})
    local unit
    for unit in ${targets[@]+"${targets[@]}"}; do
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
    local unit ddir
    for unit in ${INSTALLED_UNITS[@]+"${INSTALLED_UNITS[@]}"}; do
        print_warn "This will wipe all chain data (${unit}). The node will resync."
        if confirm "Wipe chain data for ${unit}?"; then
            if ! ddir="$(detect_data_dir)" || [[ -z "$ddir" ]]; then
                print_error "Chain data for ${unit} not wiped: the data directory is unknown."
                continue
            fi
            wait_for_service_stopped "$unit"
            rm -rf "${ddir}/db"
            systemctl start "$unit" 2>/dev/null || true
            print_ok "Chain data wiped -- node restarted (${unit})"
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
    dd="$(detect_data_dir 2>/dev/null)" || dd=""
    if [[ -n "$dd" ]] && [[ "$p" == "$dd" || "$p" == "$dd"/* ]]; then
        return 0
    fi
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
    for svc in ${custom_svcs[@]+"${custom_svcs[@]}"}; do
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
        for cline in ${custom_ctrs[@]+"${custom_ctrs[@]}"}; do
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
        # Cosmetic: with TERM unset or unusable `clear` fails, which must not end
        # the run under set -e.
        clear 2>/dev/null || true
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
        if ! read -r -p "  Enter choice [1-3 or s]: " choice; then
            # stdin is closed: no answer can come, so leave instead of looping.
            echo ""
            exit 0
        fi
        # The actions are best effort: a step that fails is reported and the rest
        # of the teardown still runs. errexit is off while an action runs and back
        # on for the menu.
        case "$choice" in
            1) set +e; remove_all_nodes; set -e ;;
            2) set +e; wipe_chain_data_only; set -e ;;
            s|S) set +e; scan_custom_installs; set -e ;;
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
#   service -> stop+disable+rm unit, its old backups (shredded) and drop-in dir
#              (+ docker container)
#   data    -> service + remove chain data (node keys inside it shredded)
#   keys    -> data + shred keys and passphrase files, remove config/.node-meta,
#              the service account, the log-reader group and, when no other
#              node unit is installed, the shared host files
#              (remove_node_host_files)
# A key set more than once in .node-meta stops every scope before any change.
#
#   remove-node.sh --json --remove <observer|validator> --scope <service|data|keys> --yes
#
# <observer|validator> is the Node Manager UI's slot name, not a role. Either
# value removes the single installed node; the role is decided on-chain.
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
    local slot="$1" scope="$2"
    # The token is the UI slot name, not a role. It is still validated so a typo
    # fails loudly, but it is never compared with the .node-meta NODE_TYPE: that
    # value is only a default-view hint, and the role is decided on-chain.
    case "$slot" in observer|validator) ;; *) json_event error "invalid node slot: ${slot}"; return 1 ;; esac
    case "$scope" in service|data|keys) ;; *) json_event error "invalid scope: ${scope}"; return 1 ;; esac

    # Resolve the actually-installed node (unified telcoin unit, or a legacy unit)
    # instead of assuming telcoin-<slot>. One node per VM, so whichever slot the
    # UI sends, this is the node to remove.
    local svc unit
    svc="$(tn_resolve_service)" || { json_event error "no node installed"; return 1; }
    unit="${TN_RM_ROOT}/etc/systemd/system/${svc}.service"

    # Read .node-meta BEFORE anything is removed. It is authoritative for the
    # install method, the service user/group and the data dir; a key set more
    # than once stops the removal here, with nothing changed.
    local meta method="" svc_user="" svc_group="" dup=""
    meta="$(tn_resolve_config_dir)/.node-meta"
    if [[ -f "$meta" ]]; then
        method="$(rm_meta_get INSTALL_METHOD "$meta")" || dup=INSTALL_METHOD
        svc_user="$(rm_meta_get HOST_SERVICE_USER "$meta")" || dup=HOST_SERVICE_USER
        svc_group="$(rm_meta_get HOST_SERVICE_GROUP "$meta")" || dup=HOST_SERVICE_GROUP
        rm_meta_get DATA_DIR "$meta" >/dev/null || dup=DATA_DIR
    fi
    if [[ -n "$dup" ]]; then
        json_event error "${dup} is set more than once in ${meta}; keep one line and run this again (nothing was removed)"
        return 1
    fi

    # Docker when .node-meta says so; fall back to the legacy inline `docker run`
    # in the unit.
    local is_docker=false
    if [[ "$method" == "docker" ]] || grep -q "docker run" "$unit" 2>/dev/null; then
        is_docker=true
    fi

    # The service user/group, so a 'keys' (full) removal can clean up the account
    # instead of orphaning it. The unit's User=/Group= is the fallback (but docker
    # units run as root, so ignore root and use the default service name).
    [[ -z "$svc_user" ]]  && svc_user=$(grep '^User=' "$unit" 2>/dev/null | cut -d= -f2- || true)
    [[ -z "$svc_group" ]] && svc_group=$(grep '^Group=' "$unit" 2>/dev/null | cut -d= -f2- || true)
    [[ -z "$svc_user"  || "$svc_user"  == "root" ]] && svc_user="${SERVICE_USER:-telcoin}"
    [[ -z "$svc_group" || "$svc_group" == "root" ]] && svc_group="${SERVICE_GROUP:-telcoin}"

    # Resolve the data dir from .node-meta BEFORE it (and the meta) get removed,
    # so a custom data drive is cleaned up instead of orphaned.
    local data_dir
    if ! data_dir="$(detect_data_dir)" || [[ -z "$data_dir" ]]; then
        json_event error "the data directory is unknown (nothing was removed)"
        return 1
    fi

    # The unit, its old backups (shredded) and its drop-in directory.
    json_event step "Stopping and disabling ${svc}"
    stop_and_disable_service "$svc"

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
            # The node keys under the data dir go with it: shred them first.
            if [[ ! -L "$data_dir" ]]; then
                _rm_shred_tree "${data_dir}/node-keys"
            fi
            rm -rf "$data_dir"
        fi
    fi

    if [[ "$scope" == "keys" ]]; then
        local config_dir
        config_dir="$(tn_resolve_config_dir)"
        json_event step "Removing keys and config ${config_dir} (key and passphrase files are shredded)"
        shred_key_files "${data_dir}/node-keys" "$config_dir"
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

        # The log-reader group and the host files every node install shares, when
        # no other node unit is installed here.
        remove_log_group "$svc_user" "$svc"
        if [[ -n "$RM_LOG_GROUP_MSG" ]]; then
            json_event step "$RM_LOG_GROUP_MSG"
        fi
        if [[ -z "$(other_node_unit_files "$svc")" ]]; then
            json_event step "Removing start scripts, node.env, backups, logrotate and journald files and the lock directory"
            remove_node_host_files
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

    # "node_type" echoes the UI slot name; the key is kept for existing UI clients.
    json_emit "{\"event\":\"done\",\"ok\":true,\"node_type\":\"$(json_escape "$slot")\",\"scope\":\"$(json_escape "$scope")\",\"ui_removed\":${ui_scheduled},\"msg\":\"${svc} removed (scope: ${scope})\"}"
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
