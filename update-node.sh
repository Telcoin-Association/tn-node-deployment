#!/usr/bin/env bash
# =============================================================================
# update-node.sh -- Telcoin Network Node Update
#
# Updates a running Telcoin node to a newer version. Auto-detects the
# install method (source build / docker) and offers a two-phase workflow:
#
#   1. PREPARE  -- build new binary or pull new image (zero service impact)
#   2. APPLY    -- stop service, swap, restart, verify (brief downtime)
#
# The two phases can be run together (prepare-and-apply) or split so the
# operator can pick a quiet maintenance window for the apply step. The
# prepared state survives between invocations via a pending-state file.
#
# USAGE:
#   sudo bash update-node.sh
#   sudo bash update-node.sh --validator    # force validator (rare; auto-detected)
#   sudo bash update-node.sh --observer     # force observer
#   sudo bash update-node.sh --discard      # drop any pending prepared update
#
# What is NEVER touched by this script:
#   - BLS / P2P keys at /var/lib/telcoin/<type>/node-keys/
#   - node-info.yaml (primary_network_key, multiaddrs)
#   - BLS passphrase at /etc/telcoin/<type>/bls-passphrase
#   - Chain config files (genesis/committee/parameters)
#   - Listener multiaddrs and other Environment= lines in the unit file
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

readonly SCRIPT_VERSION="1.1.40"
readonly GAR_TAGS_URL="https://us-docker.pkg.dev/v2/telcoin-network/tn-public/adiri/tags/list"
readonly VERIFY_TIMEOUT_SECONDS=45

NODE_TYPE=""
SERVICE_NAME=""
RPC_URL=""
NODE_TYPE_EXPLICITLY_SET=false
DISCARD_PENDING=false

# =============================================================================
# DETECTION
# =============================================================================

set_node_type() {
    case "$1" in
        validator) NODE_TYPE="validator"; SERVICE_NAME="telcoin-validator"; RPC_URL="http://127.0.0.1:8545" ;;
        observer)  NODE_TYPE="observer";  SERVICE_NAME="telcoin-observer";  RPC_URL="http://127.0.0.1:8541" ;;
    esac
}

detect_node_type() {
    [[ "$NODE_TYPE_EXPLICITLY_SET" == "true" ]] && return 0
    local val="/etc/systemd/system/telcoin-validator.service"
    local obs="/etc/systemd/system/telcoin-observer.service"
    if   [[ -f "$val" ]] && [[ -f "$obs" ]]; then
        set_node_type validator
        print_info "Both node types installed -- defaulting to validator. Use --observer to switch."
    elif [[ -f "$val" ]]; then
        set_node_type validator
        print_info "Detected node type: validator"
    elif [[ -f "$obs" ]]; then
        set_node_type observer
        print_info "Detected node type: observer"
    else
        print_error "No Telcoin node installation found on this server."
        print_info "Run setup-observer.sh or setup-validator.sh first."
        exit 1
    fi
}

# Read INSTALL_METHOD from .node-meta. Returns "source" | "docker" | "existing" | "".
detect_install_method() {
    local meta="/etc/telcoin/${NODE_TYPE}/.node-meta"
    if [[ -f "$meta" ]]; then
        grep "^INSTALL_METHOD=" "$meta" 2>/dev/null | cut -d= -f2 || true
    fi
}

# Read NETWORK from .node-meta first, then fall back to inspecting the
# chain config's chain_name. Returns "testnet" | "mainnet" | "" (unknown).
detect_network() {
    local meta="/etc/telcoin/${NODE_TYPE}/.node-meta"
    local net=""
    if [[ -f "$meta" ]]; then
        net=$(grep "^NETWORK=" "$meta" 2>/dev/null | cut -d= -f2 || true)
        [[ -n "$net" ]] && { echo "$net"; return 0; }
    fi
    # Fall back: read genesis.yaml. Older installs do not write NETWORK to
    # .node-meta. Match the well-known chain_name values from common.sh.
    local data_dir="/var/lib/telcoin/${NODE_TYPE}"
    [[ -f "$meta" ]] && {
        local meta_dir
        meta_dir=$(grep "^DATA_DIR=" "$meta" 2>/dev/null | cut -d= -f2 || true)
        [[ -n "$meta_dir" ]] && [[ -d "$meta_dir" ]] && data_dir="$meta_dir"
    }
    local genesis="${data_dir}/genesis/genesis.yaml"
    if [[ -f "$genesis" ]]; then
        local name
        name=$(grep -E '^[[:space:]]*chain_name:' "$genesis" 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*chain_name:[[:space:]]*//; s/["'\'']//g; s/[[:space:]]//g')
        case "$name" in
            "$TESTNET_CHAIN_NAME"|adiri) echo "testnet"; return 0 ;;
            "$MAINNET_CHAIN_NAME"|telcoin) echo "mainnet"; return 0 ;;
        esac
    fi
    echo ""
}

detect_current_docker_image() {
    local unit="/etc/systemd/system/${SERVICE_NAME}.service"
    [[ -f "$unit" ]] || return 1
    grep -oE 'us-docker[^ ]+|gcr\.io[^ ]+|ghcr\.io[^ ]+' "$unit" | head -1
}

# git describe-style summary of the current source ref + commit
detect_current_source_ref() {
    [[ -d "${TN_SOURCE_DIR}/.git" ]] || return 1
    git -C "$TN_SOURCE_DIR" describe --tags --always --dirty 2>/dev/null || \
        git -C "$TN_SOURCE_DIR" rev-parse --short HEAD 2>/dev/null
}

# =============================================================================
# PENDING-STATE FILE
# /etc/telcoin/<type>/.pending-update
# =============================================================================

pending_state_path() {
    echo "/etc/telcoin/${NODE_TYPE}/.pending-update"
}

read_pending_state() {
    local path
    path=$(pending_state_path)
    [[ -f "$path" ]] && cat "$path"
}

write_pending_state() {
    local path
    path=$(pending_state_path)
    mkdir -p "$(dirname "$path")"
    cat > "$path"
    chmod 600 "$path"
}

clear_pending_state() {
    local path
    path=$(pending_state_path)
    [[ -f "$path" ]] && rm -f "$path"
}

# =============================================================================
# HEALTH VERIFY (post-restart)
# =============================================================================

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

# Backup the systemd unit file with a timestamped sibling. Echoes backup path.
backup_unit_file() {
    local file="$1"
    local ts backup
    ts=$(date -u '+%Y%m%d-%H%M%S')
    backup="${file}.bak.${ts}"
    cp -p "$file" "$backup" || return 1
    print_info "Unit file backup: ${backup}"
    echo "$backup"
}

# Returns 0 if service is active AND tn_latestConsensusHeader responds within
# VERIFY_TIMEOUT_SECONDS; non-zero otherwise.
verify_health_after_restart() {
    print_step "Verifying node health..."
    local waited=0
    while (( waited < VERIFY_TIMEOUT_SECONDS )); do
        if ! systemctl is-active --quiet "$SERVICE_NAME"; then
            print_warn "  Service not active yet (${waited}s)..."
            sleep 3
            waited=$(( waited + 3 ))
            continue
        fi
        local resp
        resp=$(curl -sS --connect-timeout 3 --max-time 5 -X POST \
            -H 'Content-Type: application/json' \
            --data '{"jsonrpc":"2.0","method":"tn_latestConsensusHeader","params":[],"id":1}' \
            "$RPC_URL" 2>/dev/null || echo "")
        if echo "$resp" | grep -q '"result"'; then
            print_ok "Service active and consensus RPC responding (${waited}s)"
            return 0
        fi
        sleep 3
        waited=$(( waited + 3 ))
    done
    print_error "Service did not become healthy within ${VERIFY_TIMEOUT_SECONDS}s"
    return 1
}

# =============================================================================
# DOCKER PATH
# =============================================================================

fetch_docker_tags() {
    curl -sS --max-time 5 "$GAR_TAGS_URL" 2>/dev/null | python3 <<'PYEOF' 2>/dev/null
import json, sys, re
try:
    d = json.load(sys.stdin)
    tags = d.get('tags', [])
    parsed = []
    for t in tags:
        m = re.match(r'^v(\d+)\.(\d+)\.(\d+)(?:-(.+))?$', t)
        if m:
            parsed.append((tuple(int(x) for x in m.groups()[:3]), m.group(4) or '', t))
    parsed.sort()
    for _, _, tag in parsed[-15:]:
        print(tag)
except Exception:
    pass
PYEOF
}

# Compose the full image URL given a current image (with registry path) and a new tag.
compose_image_url() {
    local current_image="$1"
    local new_tag="$2"
    echo "${current_image%:*}:${new_tag}"
}

prepare_docker_update() {
    local new_image="$1"
    print_header "Prepare Update -- Docker Install"

    local current_image
    current_image=$(detect_current_docker_image) || {
        print_error "Could not read current Docker image from ${SERVICE_NAME}.service"
        return 1
    }
    print_info "Current image: ${current_image}"
    print_info "Target image:  ${new_image}"
    echo ""
    if ! confirm "Proceed with the pull?"; then
        print_info "Cancelled."
        return 1
    fi

    local current_tag="${current_image##*:}"
    print_step "Pulling image: ${new_image}"
    if ! docker pull "$new_image"; then
        print_error "Image pull failed. Service untouched."
        return 1
    fi
    print_ok "Image pulled. Service still running on ${current_tag}."

    write_pending_state <<EOF
PHASE=pull_complete
INSTALL_METHOD=docker
OLD_IMAGE=${current_image}
NEW_IMAGE=${new_image}
PREPARED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
    print_ok "Pending update saved: $(pending_state_path)"
}

apply_docker_update() {
    # Read pending state
    local old_image new_image
    old_image=$(read_pending_state | grep ^OLD_IMAGE= | cut -d= -f2-)
    new_image=$(read_pending_state | grep ^NEW_IMAGE= | cut -d= -f2-)
    if [[ -z "$old_image" ]] || [[ -z "$new_image" ]]; then
        print_error "Pending state is incomplete -- cannot apply."
        return 1
    fi

    print_header "Apply Update -- Docker Install"
    print_info "From: ${old_image}"
    print_info "To:   ${new_image}"
    echo ""
    validator_downtime_warning_if_applicable || return 1

    local unit="/etc/systemd/system/${SERVICE_NAME}.service"
    local backup
    backup=$(backup_unit_file "$unit") || return 1

    print_step "Stopping ${SERVICE_NAME}..."
    wait_for_service_stopped "$SERVICE_NAME"

    print_step "Updating unit file image reference..."
    perl -i -pe "s|\Q${old_image}\E|${new_image}|g" "$unit"
    systemctl daemon-reload

    print_step "Starting ${SERVICE_NAME} on new image..."
    systemctl start "$SERVICE_NAME"

    if verify_health_after_restart; then
        clear_pending_state
        print_ok "Update complete. Now running on: ${new_image}"
        return 0
    fi

    # Health verify failed -- offer rollback
    print_error "Health check failed after restart."
    echo ""
    if confirm "Roll back to previous image (${old_image})?"; then
        print_step "Rolling back..."
        wait_for_service_stopped "$SERVICE_NAME"
        cp -p "$backup" "$unit"
        systemctl daemon-reload
        systemctl start "$SERVICE_NAME"
        if verify_health_after_restart; then
            clear_pending_state
            print_ok "Rolled back to ${old_image}"
        else
            print_error "Rollback failed too. Inspect logs:"
            print_info "  journalctl -u ${SERVICE_NAME} --no-pager -n 50"
        fi
    else
        print_warn "Leaving node on new image. Pending state cleared."
        clear_pending_state
    fi
}

# =============================================================================
# SOURCE PATH
# =============================================================================

prepare_source_build() {
    local new_ref="$1"
    print_header "Prepare Update -- Source Build"

    if [[ ! -d "${TN_SOURCE_DIR}/.git" ]]; then
        print_error "Source directory not found at ${TN_SOURCE_DIR}"
        print_info "This script can only update installs that built from /opt/telcoin-source."
        return 1
    fi

    local current_ref
    current_ref=$(detect_current_source_ref || echo "unknown")
    print_info "Current source ref: ${current_ref}"
    print_info "Target ref:         ${new_ref}"

    print_step "Checking out: ${new_ref}"
    if ! git -C "$TN_SOURCE_DIR" checkout "$new_ref" 2>/dev/null; then
        # Try fetching the ref explicitly then checking out
        if git -C "$TN_SOURCE_DIR" fetch origin "$new_ref" 2>/dev/null && \
           git -C "$TN_SOURCE_DIR" checkout "$new_ref" 2>/dev/null; then
            print_ok "Checked out: ${new_ref}"
        else
            print_error "Could not check out '${new_ref}' -- branch or tag not found."
            return 1
        fi
    else
        print_ok "Checked out: ${new_ref}"
    fi
    # Pull if this is a branch (not a tag) so we get the latest commit on it
    git -C "$TN_SOURCE_DIR" pull --ff-only 2>/dev/null || true

    # Faucet feature flag is required for testnet builds; mainnet builds omit it.
    local network cargo_features=""
    network=$(detect_network)
    case "$network" in
        testnet)
            cargo_features="--features faucet"
            print_info "Network: testnet -- enabling --features faucet"
            ;;
        mainnet)
            print_info "Network: mainnet -- building without faucet feature"
            ;;
        *)
            print_warn "Could not determine network from .node-meta or genesis.yaml."
            print_warn "Defaulting to testnet (--features faucet) since mainnet has not launched."
            print_warn "Pass NETWORK=mainnet in /etc/telcoin/${NODE_TYPE}/.node-meta to override."
            cargo_features="--features faucet"
            ;;
    esac

    echo ""
    print_warn "Source build typically takes 20-40 minutes."
    print_info "Service stays running during the build -- only the apply step incurs downtime."
    echo ""
    if ! confirm "Start the build now?"; then
        print_info "Cancelled."
        return 1
    fi

    print_step "Building release binary (${new_ref}, ${cargo_features:-no features})..."
    # Run from the source dir; preserve original cwd
    (
        cd "$TN_SOURCE_DIR"
        # shellcheck disable=SC2086
        cargo build --release $cargo_features 2>&1 | tee /tmp/tn-update-build.log
    )

    local built="${TN_SOURCE_DIR}/target/release/telcoin-network"
    if [[ ! -f "$built" ]]; then
        print_error "Build did not produce ${built}. See /tmp/tn-update-build.log"
        return 1
    fi

    # Sanity-check the new binary runs (catches the rare case where cargo
    # finishes but the resulting binary is broken).
    if ! "$built" --version &>/dev/null; then
        print_error "Built binary failed --version check. Build may be corrupt."
        return 1
    fi
    local new_version
    new_version=$("$built" --version 2>/dev/null | head -1)
    print_ok "Build complete: ${new_version}"

    # Stash a hash of the built binary so apply can sanity-check the file
    # hasn't been swapped out between phases.
    local binary_hash
    binary_hash=$(sha256sum "$built" | awk '{print $1}')

    write_pending_state <<EOF
PHASE=build_complete
INSTALL_METHOD=source
OLD_REF=${current_ref}
NEW_REF=${new_ref}
NEW_VERSION=${new_version}
BUILT_BINARY=${built}
BUILT_HASH=${binary_hash}
PREPARED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
    print_ok "Pending update saved: $(pending_state_path)"
}

apply_source_update() {
    local built old_ref new_ref new_version expected_hash
    built=$(read_pending_state | grep ^BUILT_BINARY= | cut -d= -f2-)
    old_ref=$(read_pending_state | grep ^OLD_REF= | cut -d= -f2-)
    new_ref=$(read_pending_state | grep ^NEW_REF= | cut -d= -f2-)
    new_version=$(read_pending_state | grep ^NEW_VERSION= | cut -d= -f2-)
    expected_hash=$(read_pending_state | grep ^BUILT_HASH= | cut -d= -f2-)
    if [[ -z "$built" ]] || [[ ! -f "$built" ]]; then
        print_error "Pending built binary not found at ${built:-?}"
        return 1
    fi

    print_header "Apply Update -- Source Install"
    print_info "From: ${old_ref}"
    print_info "To:   ${new_ref}  (${new_version})"
    echo ""

    # Sanity: confirm the binary on disk still matches the one we built
    local actual_hash
    actual_hash=$(sha256sum "$built" | awk '{print $1}')
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        print_warn "Built binary hash has changed since prepare phase."
        print_info "  Expected: ${expected_hash}"
        print_info "  Actual:   ${actual_hash}"
        if ! confirm "Proceed anyway?"; then
            print_info "Cancelled."
            return 1
        fi
    fi

    validator_downtime_warning_if_applicable || return 1

    local installed="${DEFAULT_INSTALL_DIR}/telcoin-network"
    if [[ ! -f "$installed" ]]; then
        print_error "Installed binary not found at ${installed}"
        return 1
    fi

    # Backup current binary (mode+ownership preserved)
    local ts backup
    ts=$(date -u '+%Y%m%d-%H%M%S')
    backup="${installed}.bak.${ts}"
    cp -p "$installed" "$backup" || {
        print_error "Could not back up current binary."
        return 1
    }
    print_info "Binary backup: ${backup}"

    print_step "Stopping ${SERVICE_NAME}..."
    wait_for_service_stopped "$SERVICE_NAME"

    print_step "Installing new binary..."
    cp -p "$built" "$installed"
    chmod +x "$installed"

    print_step "Starting ${SERVICE_NAME} on new binary..."
    systemctl start "$SERVICE_NAME"

    if verify_health_after_restart; then
        clear_pending_state
        print_ok "Update complete. Now running: ${new_version}"
        return 0
    fi

    # Health verify failed -- rollback
    print_error "Health check failed after restart."
    echo ""
    if confirm "Roll back to previous binary?"; then
        print_step "Rolling back..."
        wait_for_service_stopped "$SERVICE_NAME"
        cp -p "$backup" "$installed"
        chmod +x "$installed"
        systemctl start "$SERVICE_NAME"
        if verify_health_after_restart; then
            clear_pending_state
            print_ok "Rolled back to previous binary"
        else
            print_error "Rollback failed too. Inspect logs:"
            print_info "  journalctl -u ${SERVICE_NAME} --no-pager -n 50"
        fi
    else
        print_warn "Leaving node on new binary. Pending state cleared."
        clear_pending_state
    fi
}

# =============================================================================
# VALIDATOR GUARD
# =============================================================================

validator_downtime_warning_if_applicable() {
    if [[ "$NODE_TYPE" != "validator" ]]; then
        return 0
    fi
    echo ""
    print_warn "================================================================"
    print_warn "  VALIDATOR DOWNTIME WARNING"
    print_warn "================================================================"
    print_warn "Stopping a validator during its committee window means missed"
    print_warn "consensus rounds and lost block rewards for the downtime period."
    print_warn "Apply updates during a planned maintenance window if possible."
    print_warn "================================================================"
    echo ""
    local input
    read -r -p "  Type CONFIRM to proceed with the validator restart: " input
    if [[ "$input" != "CONFIRM" ]]; then
        print_info "Cancelled."
        return 1
    fi
    return 0
}

# =============================================================================
# INTERACTIVE VERSION PICKER (Docker)
# Print informational messages to stderr; print only the chosen ref/image
# on stdout so the caller can capture it via $(...). Return 0 on selection,
# 1 on cancel or error.
# =============================================================================


pick_docker_version() {
    local current_image
    current_image=$(detect_current_docker_image) || {
        print_error "Could not read current Docker image from ${SERVICE_NAME}.service" >&2
        return 1
    }
    local current_tag="${current_image##*:}"
    local registry_path="${current_image%:*}"

    print_step "Querying registry for available tags..." >&2
    local -a all_tags
    while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        all_tags+=("$t")
    done < <(fetch_docker_tags)

    echo "" >&2
    print_info "Current image:        ${current_image}" >&2

    # No tags = registry unreachable or returned nothing parseable.
    if [[ ${#all_tags[@]} -eq 0 ]]; then
        print_warn "Could not reach registry (or no parseable tags returned)." >&2
        echo "" >&2
        print_info "Falling back to manual entry." >&2
        local custom_tag
        read -r -p "  Enter target tag (e.g. ${current_tag}) or Enter to cancel: " custom_tag >&2
        [[ -z "$custom_tag" ]] && { print_info "Cancelled." >&2; return 1; }
        if ! [[ "$custom_tag" =~ ^[A-Za-z0-9._-]+$ ]]; then
            print_error "Tag contains unexpected characters: ${custom_tag}" >&2
            return 1
        fi
        if [[ "$custom_tag" == "$current_tag" ]]; then
            print_info "That is your current tag. Nothing to update." >&2
            return 1
        fi
        echo "${registry_path}:${custom_tag}"
        return 0
    fi

    # fetch_docker_tags returns oldest-first; reverse for newest-first menu.
    local -a tags_desc
    for ((i=${#all_tags[@]}-1; i>=0; i--)); do
        tags_desc+=("${all_tags[i]}")
    done
    local latest_tag="${tags_desc[0]}"

    if [[ "$current_tag" == "$latest_tag" ]]; then
        print_ok "You are on the latest published tag (${latest_tag})." >&2
    else
        print_info "Latest published tag: ${latest_tag}" >&2
    fi
    echo "" >&2

    print_info "Available image tags:" >&2
    local i=1
    for tag in "${tags_desc[@]}"; do
        local marker=""
        [[ "$tag" == "$current_tag" ]] && marker="  <-- current"
        [[ $i -eq 1 ]] && [[ -z "$marker" ]] && marker="  <-- latest"
        printf "  %2d) %s%s\n" "$i" "$tag" "$marker" >&2
        (( ++i ))
    done
    local tag_count=$(( i - 1 ))
    local custom_opt=$i; printf "  %2d) Custom tag\n" "$custom_opt" >&2; (( ++i ))
    local cancel_opt=$i; printf "  %2d) Cancel\n"     "$cancel_opt" >&2
    echo "" >&2

    local choice
    read -r -p "  Select [1-${cancel_opt}]: " choice >&2

    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        print_warn "Invalid selection." >&2
        return 1
    fi
    if (( choice == cancel_opt )); then
        print_info "Cancelled." >&2
        return 1
    fi
    if (( choice == custom_opt )); then
        local custom_tag
        read -r -p "  Enter target tag: " custom_tag >&2
        [[ -z "$custom_tag" ]] && { print_info "Cancelled." >&2; return 1; }
        if ! [[ "$custom_tag" =~ ^[A-Za-z0-9._-]+$ ]]; then
            print_error "Tag contains unexpected characters: ${custom_tag}" >&2
            return 1
        fi
        if [[ "$custom_tag" == "$current_tag" ]]; then
            print_info "That is your current tag. Nothing to update." >&2
            return 1
        fi
        echo "${registry_path}:${custom_tag}"
        return 0
    fi
    if (( choice >= 1 && choice <= tag_count )); then
        local selected="${tags_desc[$((choice - 1))]}"
        if [[ "$selected" == "$current_tag" ]]; then
            print_info "That is your current tag. Nothing to update." >&2
            return 1
        fi
        echo "${registry_path}:${selected}"
        return 0
    fi

    print_warn "Invalid selection." >&2
    return 1
}

# Ask the operator: prepare-only or prepare-and-apply or cancel.
# Echoes "prepare" | "prepare_and_apply" | "cancel".

# =============================================================================
# MAIN MENU
# =============================================================================

show_pending_summary() {
    local state phase prepared_at
    state=$(read_pending_state)
    phase=$(echo "$state" | grep ^PHASE= | cut -d= -f2)
    prepared_at=$(echo "$state" | grep ^PREPARED_AT= | cut -d= -f2)
    print_header "Pending update detected"
    echo "$state" | sed 's/^/    /'
    echo ""
    print_info "Prepared at: ${prepared_at}  (phase: ${phase})"
    echo ""
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --validator) set_node_type validator; NODE_TYPE_EXPLICITLY_SET=true; shift ;;
            --observer)  set_node_type observer;  NODE_TYPE_EXPLICITLY_SET=true; shift ;;
            --discard)   DISCARD_PENDING=true; shift ;;
            -h|--help)
                grep '^# ' "$0" | head -30 | sed 's/^# \?//'
                exit 0
                ;;
            *) print_warn "Unknown argument: $1"; shift ;;
        esac
    done

    check_root
    print_header "Telcoin Network Node Update  v${SCRIPT_VERSION}"
    detect_node_type
    print_info "Service:       ${SERVICE_NAME}"

    local install_method
    install_method=$(detect_install_method)
    print_info "Install method: ${install_method:-unknown (no .node-meta found)}"

    case "$install_method" in
        existing)
            print_error "Install method is 'existing' (an externally-supplied binary)."
            print_info "This script only updates source builds and Docker installs."
            print_info "To update an existing-binary install, replace the file at"
            print_info "  ${DEFAULT_INSTALL_DIR}/telcoin-network manually, then restart the service."
            exit 1
            ;;
        source|docker)
            ;;
        *)
            print_error "Install method is unknown -- cannot proceed safely."
            print_info "Re-run setup-${NODE_TYPE}.sh to rewrite .node-meta, or supply"
            print_info "INSTALL_METHOD={source|docker} manually in /etc/telcoin/${NODE_TYPE}/.node-meta"
            exit 1
            ;;
    esac

    # Handle --discard flag
    if [[ "$DISCARD_PENDING" == "true" ]]; then
        if [[ -f "$(pending_state_path)" ]]; then
            show_pending_summary
            if confirm "Discard this pending update?"; then
                clear_pending_state
                print_ok "Pending state cleared."
            else
                print_info "Kept."
            fi
        else
            print_info "No pending update to discard."
        fi
        exit 0
    fi

    # Pending state present -> offer apply/discard
    if [[ -f "$(pending_state_path)" ]]; then
        show_pending_summary

        # Sanity check: install method in pending state must match current
        local pending_method
        pending_method=$(read_pending_state | grep ^INSTALL_METHOD= | cut -d= -f2)
        if [[ "$pending_method" != "$install_method" ]]; then
            print_warn "Pending state was prepared for install method '${pending_method}',"
            print_warn "but this node is now '${install_method}'. Refusing to apply."
            print_info "Use --discard to clear the pending state."
            exit 1
        fi

        echo "  1) Apply now"
        echo "  2) Discard and prepare a different update"
        echo "  3) Exit (leave pending for later)"
        echo ""
        local choice
        read -r -p "  Enter choice [1-3]: " choice
        case "$choice" in
            1)
                if [[ "$install_method" == "source" ]]; then
                    apply_source_update
                else
                    apply_docker_update
                fi
                ;;
            2)
                clear_pending_state
                print_info "Pending state cleared."
                echo ""
                # Fall through to the no-pending-state flow below
                ;;
            *) print_info "Exiting. Pending update remains; run this script again to apply."; exit 0 ;;
        esac
        # If choice was 2, continue to the picker flow
        if [[ "$choice" != "2" ]]; then
            exit 0
        fi
    fi

    # No pending state (or pending state was just discarded) -> show what is
    # available, let the operator pick a version, then ask prepare vs apply.
    local target=""
    if [[ "$install_method" == "source" ]]; then
        target=$(pick_source_version "$(detect_network)") || { print_info "No update prepared."; exit 0; }
    else
        target=$(pick_docker_version) || { print_info "No update prepared."; exit 0; }
    fi

    local action
    action=$(pick_action)
    case "$action" in
        prepare)
            if [[ "$install_method" == "source" ]]; then
                prepare_source_build "$target"
            else
                prepare_docker_update "$target"
            fi
            print_info "Run this script again when you are ready to apply."
            ;;
        prepare_and_apply)
            if [[ "$install_method" == "source" ]]; then
                prepare_source_build "$target" && apply_source_update
            else
                prepare_docker_update "$target" && apply_docker_update
            fi
            ;;
        cancel) print_info "Cancelled." ;;
    esac
}

main "$@"
