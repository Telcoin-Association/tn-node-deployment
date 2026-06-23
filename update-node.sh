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
#   - BLS / P2P keys in <data_dir>/node-keys/
#   - node-info.yaml (primary_network_key, multiaddrs)
#   - BLS passphrase at <config_dir>/bls-passphrase
#   - Chain config files (genesis/committee/parameters)
#   - Listener multiaddrs and other Environment= lines in the unit file
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

readonly SCRIPT_VERSION="1.1.52"
# GAR_TAGS_URL is provided by lib/common.sh (sourced above). Re-declaring it
# readonly here threw "GAR_TAGS_URL: readonly variable" to stderr, which the UI
# surfaced as "update checks aren't available on this host".
readonly VERIFY_TIMEOUT_SECONDS=45

NODE_TYPE=""
SERVICE_NAME=""
RPC_URL=""
NODE_TYPE_EXPLICITLY_SET=false
DISCARD_PENDING=false

# Non-interactive (--json) mode state. Drives the UI's Update feature via the
# root-owned telcoin-ui-helper. Empty/false here means classic interactive mode.
JSON_MODE=false
JSON_ACTION=""
JSON_REF=""
ASSUME_YES=false

# =============================================================================
# DETECTION
# =============================================================================

# Set NODE_TYPE + the type-specific RPC_URL. The systemd unit BASE name lives in
# SERVICE_NAME and is resolved separately (tn_resolve_service) so it is "telcoin"
# on a unified install and the legacy unit name on a legacy install.
set_node_type() {
    case "$1" in
        validator) NODE_TYPE="validator"; RPC_URL="http://127.0.0.1:8545" ;;
        observer)  NODE_TYPE="observer";  RPC_URL="http://127.0.0.1:8541" ;;
    esac
}

detect_node_type() {
    # Resolve the unit base name first so SERVICE_NAME is correct regardless of
    # whether the node type was forced via --validator/--observer.
    SERVICE_NAME="$(tn_resolve_service)" || {
        print_error "No Telcoin node installation found on this server."
        print_info "Run setup-observer.sh or setup-validator.sh first."
        exit 1
    }
    [[ "$NODE_TYPE_EXPLICITLY_SET" == "true" ]] && return 0
    set_node_type "$(tn_resolve_node_type)"
    print_info "Detected node type: ${NODE_TYPE}"
}

# Read INSTALL_METHOD from .node-meta. Returns "source" | "docker" | "existing" | "".
detect_install_method() {
    local meta
    meta="$(node_meta_path)" || return 0
    if [[ -f "$meta" ]]; then
        grep "^INSTALL_METHOD=" "$meta" 2>/dev/null | cut -d= -f2 || true
    fi
}

# Read NETWORK from .node-meta first, then fall back to inspecting the
# chain config's chain_name. Returns "testnet" | "mainnet" | "" (unknown).
detect_network() {
    local meta
    meta="$(node_meta_path || true)"
    local net=""
    if [[ -n "$meta" && -f "$meta" ]]; then
        net=$(grep "^NETWORK=" "$meta" 2>/dev/null | cut -d= -f2 || true)
        [[ -n "$net" ]] && { echo "$net"; return 0; }
    fi
    # Fall back: read genesis.yaml. Older installs do not write NETWORK to
    # .node-meta. Match the well-known chain_name values from common.sh.
    local data_dir
    data_dir="$(tn_resolve_data_dir)"
    [[ -n "$meta" && -f "$meta" ]] && {
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
# <config_dir>/.pending-update
# =============================================================================

pending_state_path() {
    echo "$(tn_resolve_config_dir)/.pending-update"
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

# Start the service after clearing any leftover failed state and the
# start-rate-limit counter. The unit sets StartLimitBurst=5 / 60s with
# Restart=on-failure; a failed update + rollback can stop/start the service
# enough times to trip that limit, after which `systemctl start` is refused
# and the node stays down even with a good binary. reset-failed (a no-op when
# nothing is wrong) prevents that.
start_service() {
    systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
    systemctl start "$SERVICE_NAME"
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

    # Hash the unit file before/after the substitution so we can detect
    # "perl did nothing" -- symmetric with the source-binary hash check
    # added in v1.1.41. Avoids reporting a successful update when the
    # unit file was actually unchanged.
    local pre_unit_hash post_unit_hash
    pre_unit_hash=$(sha256sum "$unit" | awk '{print $1}')

    print_step "Stopping ${SERVICE_NAME}..."
    wait_for_service_stopped "$SERVICE_NAME"

    print_step "Updating unit file image reference..."
    perl -i -pe "s|\Q${old_image}\E|${new_image}|g" "$unit"
    systemctl daemon-reload

    post_unit_hash=$(sha256sum "$unit" | awk '{print $1}')
    if [[ "$pre_unit_hash" == "$post_unit_hash" ]]; then
        print_error "Unit file is unchanged after edit -- old image string not found."
        print_info "  Expected to replace: ${old_image}"
        print_info "  Unit file: ${unit}"
        print_info "Restoring from backup and aborting."
        cp -p "$backup" "$unit"
        systemctl daemon-reload
        start_service 2>/dev/null || true
        return 1
    fi
    # Confirm the new image actually appears in the file (defends against a
    # perl substitution that replaced the wrong text).
    if ! grep -qF "$new_image" "$unit"; then
        print_error "New image string not present in unit file after edit."
        print_info "  Expected to find: ${new_image}"
        print_info "Restoring from backup and aborting."
        cp -p "$backup" "$unit"
        systemctl daemon-reload
        start_service 2>/dev/null || true
        return 1
    fi
    print_ok "Unit file updated: ${pre_unit_hash:0:12}... -> ${post_unit_hash:0:12}..."

    print_step "Starting ${SERVICE_NAME} on new image..."
    start_service

    if verify_health_after_restart; then
        clear_pending_state
        if ! systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
            print_warn "Service is not enabled for auto-start on reboot."
            print_info "  Enable it: systemctl enable ${SERVICE_NAME}"
        fi
        print_ok "Update complete. Now running on: ${new_image}"
        print_info "Verify full health: bash ~/telcoin-node-scripts/check-node.sh"
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
        start_service
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

    # The adiri feature flag is required for testnet builds; mainnet builds omit it.
    local network cargo_features=""
    network=$(detect_network)
    case "$network" in
        testnet)
            cargo_features="--features adiri"
            print_info "Network: testnet -- enabling --features adiri"
            ;;
        mainnet)
            print_info "Network: mainnet -- building without the adiri feature"
            ;;
        *)
            print_warn "Could not determine network from .node-meta or genesis.yaml."
            print_warn "Defaulting to testnet (--features adiri) since mainnet has not launched."
            print_warn "Pass NETWORK=mainnet in $(node_meta_path || echo "$(tn_resolve_config_dir)/.node-meta") to override."
            cargo_features="--features adiri"
            ;;
    esac

    # Disk-space pre-flight. A clean cargo build can produce a target/
    # directory of several GB. Refuse to start a build when we can already
    # see disk is tight -- cleaner than failing mid-compile with cryptic
    # "no space left on device" errors.
    local avail_gb min_required_gb=5
    avail_gb=$(df -BG --output=avail "$TN_SOURCE_DIR" 2>/dev/null | awk 'NR==2 {gsub("G",""); print $1}')
    if [[ -n "$avail_gb" ]] && [[ "$avail_gb" -lt "$min_required_gb" ]]; then
        print_error "Only ${avail_gb}G available on the mount holding ${TN_SOURCE_DIR}"
        print_error "A source build typically needs ${min_required_gb}G+ for cargo artefacts."
        print_info "Free up some space and try again:"
        print_info "  du -sh ${TN_SOURCE_DIR}/target 2>/dev/null"
        print_info "  cargo clean --manifest-path ${TN_SOURCE_DIR}/Cargo.toml"
        return 1
    fi
    [[ -n "$avail_gb" ]] && print_info "Disk free on source mount: ${avail_gb}G (>= ${min_required_gb}G required)"

    echo ""
    print_warn "Source build typically takes 20-40 minutes."
    print_info "Service stays running during the build -- only the apply step incurs downtime."
    echo ""
    if ! confirm "Start the build now?"; then
        print_info "Cancelled."
        return 1
    fi

    # Make cargo findable. Sudo's PATH usually does not include
    # ~/.cargo/bin, which is where rustup installs cargo. Mirror what
    # setup-{observer,validator}.sh do at install time. Look at three
    # plausible locations so this works whether rustup ran as root or as
    # the invoking user.
    local user_cargo_dir=""
    [[ -n "${SUDO_USER:-}" ]] && [[ -d "/home/${SUDO_USER}/.cargo/bin" ]] \
        && user_cargo_dir="/home/${SUDO_USER}/.cargo/bin"
    export PATH="${HOME}/.cargo/bin:/root/.cargo/bin:${user_cargo_dir}:${PATH}"
    [[ -f "${HOME}/.cargo/env" ]] && source "${HOME}/.cargo/env" 2>/dev/null || true
    [[ -n "$user_cargo_dir" ]] && [[ -f "/home/${SUDO_USER}/.cargo/env" ]] \
        && source "/home/${SUDO_USER}/.cargo/env" 2>/dev/null || true

    if ! command -v cargo >/dev/null 2>&1; then
        print_error "cargo not found in PATH. Looked in:"
        print_info "  \${HOME}/.cargo/bin"
        print_info "  /root/.cargo/bin"
        [[ -n "$user_cargo_dir" ]] && print_info "  ${user_cargo_dir}"
        print_info "Install Rust:"
        print_info "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
        return 1
    fi
    print_info "cargo: $(command -v cargo)"

    # Capture the pre-build binary hash so we can detect "cargo did nothing"
    # after the build runs.
    local built="${TN_SOURCE_DIR}/target/release/telcoin-network"
    local pre_build_hash=""
    [[ -f "$built" ]] && pre_build_hash=$(sha256sum "$built" | awk '{print $1}')

    print_step "Building release binary (${new_ref}, ${cargo_features:-no features})..."
    # Use pushd/popd instead of a subshell so PIPESTATUS is captured from
    # the pipeline below. set -o pipefail (inherited from common.sh) makes
    # the pipeline return non-zero if cargo itself fails -- v1.1.40 and
    # earlier discarded that exit code by running the pipeline inside an
    # unchecked subshell, which let a failed build go undetected.
    pushd "$TN_SOURCE_DIR" >/dev/null
    # shellcheck disable=SC2086
    if ! cargo build --release $cargo_features 2>&1 | tee /tmp/tn-update-build.log; then
        popd >/dev/null
        print_error "cargo build failed. See /tmp/tn-update-build.log for the full output."
        print_info "  Last few lines:"
        tail -10 /tmp/tn-update-build.log 2>/dev/null | sed 's/^/    /'
        return 1
    fi
    popd >/dev/null

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

    # Did cargo actually produce a new binary? If the hash hasn't changed,
    # cargo decided no rebuild was needed (or did nothing). That used to
    # silently install the unchanged old binary on top of itself.
    local binary_hash
    binary_hash=$(sha256sum "$built" | awk '{print $1}')
    if [[ -n "$pre_build_hash" ]] && [[ "$pre_build_hash" == "$binary_hash" ]]; then
        print_warn "Binary hash did not change after build."
        print_info "  Pre-build:  ${pre_build_hash:0:16}..."
        print_info "  Post-build: ${binary_hash:0:16}..."
        print_info "  This usually means cargo decided no rebuild was needed,"
        print_info "  even though the build command exited 0. Double-check your ref:"
        print_info "    git -C ${TN_SOURCE_DIR} log -1 --format='%h %s'"
        if ! confirm "Proceed anyway with the existing (unchanged) binary?"; then
            print_info "Cancelled."
            return 1
        fi
    fi
    print_ok "Build complete: ${new_version}"

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

    # Hash the installed binary before we copy over it. If the cp does not
    # actually change anything (built and installed already identical), we
    # want to surface that as a "nothing happened" warning rather than
    # silently report success.
    local pre_install_hash
    pre_install_hash=$(sha256sum "$installed" | awk '{print $1}')

    print_step "Stopping ${SERVICE_NAME}..."
    wait_for_service_stopped "$SERVICE_NAME"

    print_step "Installing new binary..."
    # Check cp's exit code explicitly. A failed cp (disk full, permissions,
    # I/O error) under set -uo pipefail would leave the installed binary
    # in some indeterminate state; we want a loud failure with a restore
    # attempt rather than silently proceeding to start the service.
    if ! cp -p "$built" "$installed"; then
        print_error "Failed to copy ${built} to ${installed}"
        print_info "  Checking disk: $(df -h "$installed" | tail -1)"
        print_info "Restoring backup and aborting."
        cp -p "$backup" "$installed" 2>/dev/null || true
        start_service 2>/dev/null || true
        return 1
    fi
    if ! chmod +x "$installed"; then
        print_warn "Could not chmod +x ${installed} -- service may fail to start."
    fi

    local post_install_hash
    post_install_hash=$(sha256sum "$installed" | awk '{print $1}')
    if [[ "$pre_install_hash" == "$post_install_hash" ]]; then
        print_warn "Installed binary is identical to what was already at ${installed}."
        print_warn "The build did not produce different output -- you may still be"
        print_warn "running the previous version after restart. Investigate before"
        print_warn "treating this as a successful update."
    else
        print_ok "Binary swapped: ${pre_install_hash:0:12}... -> ${post_install_hash:0:12}..."
    fi

    print_step "Starting ${SERVICE_NAME} on new binary..."
    start_service

    if verify_health_after_restart; then
        clear_pending_state
        # Record the now-running ref so the UI reports the installed binary's
        # version (not the source checkout, which has moved to new_ref).
        write_source_version_marker "$DEFAULT_INSTALL_DIR" "$TN_SOURCE_DIR" "$new_ref"
        if ! systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
            print_warn "Service is not enabled for auto-start on reboot."
            print_info "  Enable it: systemctl enable ${SERVICE_NAME}"
        fi
        print_ok "Update complete. Now running: ${new_version}"
        print_info "Verify full health: bash ~/telcoin-node-scripts/check-node.sh"
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
        start_service
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
# JSON / NON-INTERACTIVE MODE
#
# Reached only via `--json` (the interactive default is completely unaffected).
# Used by the Telcoin Node Manager UI through the root-owned telcoin-ui-helper.
#
# fd handling: json_setup_fds dups the real stdout to fd 3 and points stdout at
# stderr, so every human-readable print_* / build line is harmless noise on
# stderr while fd 3 carries newline-delimited JSON the caller can stream + parse.
# Each emitted line is a self-contained JSON object: progress events
#   {"event":"step|error","msg":"..."}
# and a terminal result
#   {"event":"done","ok":true|false,"phase":"prepare|apply|discard",...}
# =============================================================================

json_setup_fds() {
    exec 3>&1   # fd3 = original stdout: JSON is written here
    exec 1>&2   # stdout now aliases stderr: print_*/build output is benign noise
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"
    s="${s//$'\r'/ }"
    s="${s//$'\t'/ }"
    printf '%s' "$s"
}

json_emit() { printf '%s\n' "$1" >&3; }

json_event() {
    # json_event <event> <msg>
    json_emit "{\"event\":\"${1}\",\"msg\":\"$(json_escape "${2:-}")\"}"
}

# Newest tag for the operator's network (source installs). Echoes "" if none.
latest_source_ref() {
    [[ -d "${TN_SOURCE_DIR}/.git" ]] || return 0
    local network suffix=""
    network=$(detect_network)
    case "$network" in
        testnet) suffix="$NETWORK_TAG_SUFFIX_TESTNET" ;;
        mainnet) suffix="$NETWORK_TAG_SUFFIX_MAINNET" ;;
    esac
    git -C "$TN_SOURCE_DIR" fetch --tags --quiet 2>/dev/null || true
    local t
    while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        [[ -n "$suffix" && "$t" != *"$suffix"* ]] && continue
        echo "$t"
        return 0
    done < <(git -C "$TN_SOURCE_DIR" tag --sort=-creatordate 2>/dev/null)
    return 0
}

# Newest published docker tag. fetch_docker_tags emits oldest-first.
latest_docker_ref() {
    fetch_docker_tags | tail -1
}

json_check() {
    local install_method="$1"
    local current="" latest="" pending="null" avail="false"

    if [[ -f "$(pending_state_path)" ]]; then
        local phase
        phase=$(read_pending_state | grep '^PHASE=' | cut -d= -f2 || true)
        pending="\"$(json_escape "${phase:-pending}")\""
    fi

    case "$install_method" in
        source)
            current=$(detect_current_source_ref 2>/dev/null || echo "")
            latest=$(latest_source_ref 2>/dev/null || echo "")
            local exact_tag
            exact_tag=$(git -C "$TN_SOURCE_DIR" describe --tags --exact-match HEAD 2>/dev/null || echo "")
            [[ -n "$latest" && "$exact_tag" != "$latest" ]] && avail="true"
            ;;
        docker)
            local img
            img=$(detect_current_docker_image 2>/dev/null || echo "")
            current="${img##*:}"
            latest=$(latest_docker_ref 2>/dev/null || echo "")
            [[ -n "$latest" && -n "$current" && "$current" != "$latest" ]] && avail="true"
            ;;
        *)
            current=$(detect_current_source_ref 2>/dev/null || echo "")
            ;;
    esac

    json_emit "{\"install_method\":\"$(json_escape "$install_method")\",\"current_ref\":\"$(json_escape "$current")\",\"latest_ref\":\"$(json_escape "$latest")\",\"update_available\":${avail},\"pending\":${pending}}"
}

json_prepare() {
    local install_method="$1" ref="$2"
    if [[ -z "$ref" ]]; then
        json_event error "no ref supplied"; return 1
    fi
    case "$install_method" in
        source) json_prepare_source "$ref" ;;
        docker) json_prepare_docker "$ref" ;;
        *) json_event error "install method '${install_method}' cannot be updated"; return 1 ;;
    esac
}

json_prepare_source() {
    local new_ref="$1"
    if [[ ! -d "${TN_SOURCE_DIR}/.git" ]]; then
        json_event error "source directory not found at ${TN_SOURCE_DIR}"; return 1
    fi
    local current_ref
    current_ref=$(detect_current_source_ref || echo "unknown")

    json_event step "Checking out ${new_ref}"
    if ! git -C "$TN_SOURCE_DIR" checkout "$new_ref" 2>/dev/null; then
        if ! { git -C "$TN_SOURCE_DIR" fetch origin "$new_ref" 2>/dev/null && \
               git -C "$TN_SOURCE_DIR" checkout "$new_ref" 2>/dev/null; }; then
            json_event error "could not check out '${new_ref}' -- branch or tag not found"
            return 1
        fi
    fi
    git -C "$TN_SOURCE_DIR" pull --ff-only 2>/dev/null || true

    # The adiri feature flag is required for testnet builds; mainnet omits it.
    local network cargo_features=""
    network=$(detect_network)
    case "$network" in
        mainnet) ;;
        *) cargo_features="--features adiri" ;;
    esac

    # Make cargo findable under sudo's PATH (mirrors prepare_source_build).
    local user_cargo_dir=""
    [[ -n "${SUDO_USER:-}" ]] && [[ -d "/home/${SUDO_USER}/.cargo/bin" ]] \
        && user_cargo_dir="/home/${SUDO_USER}/.cargo/bin"
    export PATH="${HOME}/.cargo/bin:/root/.cargo/bin:${user_cargo_dir}:${PATH}"
    [[ -f "${HOME}/.cargo/env" ]] && source "${HOME}/.cargo/env" 2>/dev/null || true
    [[ -n "$user_cargo_dir" ]] && [[ -f "/home/${SUDO_USER}/.cargo/env" ]] \
        && source "/home/${SUDO_USER}/.cargo/env" 2>/dev/null || true
    if ! command -v cargo >/dev/null 2>&1; then
        json_event error "cargo not found in PATH -- install Rust on this host"; return 1
    fi

    local built="${TN_SOURCE_DIR}/target/release/telcoin-network"
    local pre_build_hash=""
    [[ -f "$built" ]] && pre_build_hash=$(sha256sum "$built" | awk '{print $1}')

    json_event step "Building ${new_ref} (${cargo_features:-no features}) -- this can take 20-40 minutes"
    pushd "$TN_SOURCE_DIR" >/dev/null
    # shellcheck disable=SC2086
    if ! cargo build --release $cargo_features >/tmp/tn-update-build.log 2>&1; then
        popd >/dev/null
        json_event error "cargo build failed -- see /tmp/tn-update-build.log on the host"
        return 1
    fi
    popd >/dev/null

    [[ -f "$built" ]] || { json_event error "build produced no binary at ${built}"; return 1; }
    if ! "$built" --version >/dev/null 2>&1; then
        json_event error "built binary failed its --version check"; return 1
    fi
    local new_version binary_hash
    new_version=$("$built" --version 2>/dev/null | head -1)
    binary_hash=$(sha256sum "$built" | awk '{print $1}')
    if [[ -n "$pre_build_hash" && "$pre_build_hash" == "$binary_hash" ]]; then
        json_event step "Note: binary hash unchanged -- cargo decided no rebuild was needed for ${new_ref}"
    fi

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
    json_emit "{\"event\":\"done\",\"ok\":true,\"phase\":\"prepare\",\"new_ref\":\"$(json_escape "$new_ref")\",\"new_version\":\"$(json_escape "$new_version")\"}"
}

json_prepare_docker() {
    local arg="$1"
    local current_image
    current_image=$(detect_current_docker_image) || {
        json_event error "could not read current docker image from unit"; return 1; }
    # Accept a bare tag (compose against the current registry path) or a full ref.
    local new_image
    if [[ "$arg" == *:* || "$arg" == */* ]]; then
        new_image="$arg"
    else
        new_image=$(compose_image_url "$current_image" "$arg")
    fi

    json_event step "Pulling ${new_image}"
    if ! docker pull "$new_image" >/tmp/tn-update-build.log 2>&1; then
        json_event error "image pull failed -- see /tmp/tn-update-build.log on the host"; return 1
    fi

    write_pending_state <<EOF
PHASE=pull_complete
INSTALL_METHOD=docker
OLD_IMAGE=${current_image}
NEW_IMAGE=${new_image}
PREPARED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
    json_emit "{\"event\":\"done\",\"ok\":true,\"phase\":\"prepare\",\"new_image\":\"$(json_escape "$new_image")\"}"
}

json_apply() {
    local install_method="$1"
    if [[ ! -f "$(pending_state_path)" ]]; then
        json_event error "no pending update to apply"; return 1
    fi
    local pending_method
    pending_method=$(read_pending_state | grep '^INSTALL_METHOD=' | cut -d= -f2 || true)
    if [[ -n "$pending_method" && "$pending_method" != "$install_method" ]]; then
        json_event error "pending update was prepared for '${pending_method}' but node is '${install_method}'"
        return 1
    fi
    # In JSON mode a validator restart needs an explicit --yes (replaces the
    # typed CONFIRM of interactive mode); never restart a validator implicitly.
    if [[ "$NODE_TYPE" == "validator" && "$ASSUME_YES" != "true" ]]; then
        json_event error "validator apply requires explicit confirmation (--yes)"; return 1
    fi
    case "$install_method" in
        source) json_apply_source ;;
        docker) json_apply_docker ;;
        *) json_event error "install method '${install_method}' cannot be applied"; return 1 ;;
    esac
}

json_apply_source() {
    local built old_ref new_ref new_version
    built=$(read_pending_state | grep '^BUILT_BINARY=' | cut -d= -f2-)
    old_ref=$(read_pending_state | grep '^OLD_REF=' | cut -d= -f2-)
    new_ref=$(read_pending_state | grep '^NEW_REF=' | cut -d= -f2-)
    new_version=$(read_pending_state | grep '^NEW_VERSION=' | cut -d= -f2-)
    if [[ -z "$built" || ! -f "$built" ]]; then
        json_event error "prepared binary not found at ${built:-?}"; return 1
    fi
    local installed="${DEFAULT_INSTALL_DIR}/telcoin-network"
    if [[ ! -f "$installed" ]]; then
        json_event error "installed binary not found at ${installed}"; return 1
    fi

    local ts backup
    ts=$(date -u '+%Y%m%d-%H%M%S')
    backup="${installed}.bak.${ts}"
    cp -p "$installed" "$backup" || { json_event error "could not back up current binary"; return 1; }

    json_event step "Stopping ${SERVICE_NAME}"
    wait_for_service_stopped "$SERVICE_NAME"

    json_event step "Installing new binary"
    if ! cp -p "$built" "$installed"; then
        json_event error "failed to install new binary -- restoring backup"
        cp -p "$backup" "$installed" 2>/dev/null || true
        start_service 2>/dev/null || true
        return 1
    fi
    chmod +x "$installed" 2>/dev/null || true

    json_event step "Starting ${SERVICE_NAME} on new binary"
    start_service

    json_event step "Verifying node health"
    if verify_health_after_restart; then
        clear_pending_state
        # Record the now-running ref so the UI reports the installed binary's
        # version (not the source checkout, which has moved to new_ref).
        write_source_version_marker "$DEFAULT_INSTALL_DIR" "$TN_SOURCE_DIR" "$new_ref"
        json_emit "{\"event\":\"done\",\"ok\":true,\"phase\":\"apply\",\"new_ref\":\"$(json_escape "$new_ref")\",\"new_version\":\"$(json_escape "$new_version")\"}"
        return 0
    fi

    json_event step "Health check failed -- rolling back to previous binary"
    wait_for_service_stopped "$SERVICE_NAME"
    cp -p "$backup" "$installed"
    chmod +x "$installed" 2>/dev/null || true
    start_service
    if verify_health_after_restart; then
        clear_pending_state
        json_emit "{\"event\":\"done\",\"ok\":false,\"phase\":\"apply\",\"rolled_back\":true,\"msg\":\"health check failed; rolled back to previous binary\"}"
    else
        json_emit "{\"event\":\"done\",\"ok\":false,\"phase\":\"apply\",\"rolled_back\":false,\"msg\":\"health check failed and rollback failed; inspect journalctl -u ${SERVICE_NAME}\"}"
    fi
    return 1
}

json_apply_docker() {
    local old_image new_image
    old_image=$(read_pending_state | grep '^OLD_IMAGE=' | cut -d= -f2-)
    new_image=$(read_pending_state | grep '^NEW_IMAGE=' | cut -d= -f2-)
    if [[ -z "$old_image" || -z "$new_image" ]]; then
        json_event error "pending state is incomplete -- cannot apply"; return 1
    fi
    local unit="/etc/systemd/system/${SERVICE_NAME}.service"
    local ts backup
    ts=$(date -u '+%Y%m%d-%H%M%S')
    backup="${unit}.bak.${ts}"
    cp -p "$unit" "$backup" || { json_event error "could not back up unit file"; return 1; }
    local pre_hash post_hash
    pre_hash=$(sha256sum "$unit" | awk '{print $1}')

    json_event step "Stopping ${SERVICE_NAME}"
    wait_for_service_stopped "$SERVICE_NAME"

    json_event step "Updating unit file image reference"
    perl -i -pe "s|\Q${old_image}\E|${new_image}|g" "$unit"
    systemctl daemon-reload
    post_hash=$(sha256sum "$unit" | awk '{print $1}')
    if [[ "$pre_hash" == "$post_hash" ]] || ! grep -qF "$new_image" "$unit"; then
        json_event error "unit file image not updated -- restoring backup"
        cp -p "$backup" "$unit"; systemctl daemon-reload; start_service 2>/dev/null || true
        return 1
    fi

    json_event step "Starting ${SERVICE_NAME} on new image"
    start_service

    json_event step "Verifying node health"
    if verify_health_after_restart; then
        clear_pending_state
        json_emit "{\"event\":\"done\",\"ok\":true,\"phase\":\"apply\",\"new_image\":\"$(json_escape "$new_image")\"}"
        return 0
    fi

    json_event step "Health check failed -- rolling back to previous image"
    wait_for_service_stopped "$SERVICE_NAME"
    cp -p "$backup" "$unit"; systemctl daemon-reload; start_service
    if verify_health_after_restart; then
        clear_pending_state
        json_emit "{\"event\":\"done\",\"ok\":false,\"phase\":\"apply\",\"rolled_back\":true,\"msg\":\"health check failed; rolled back to previous image\"}"
    else
        json_emit "{\"event\":\"done\",\"ok\":false,\"phase\":\"apply\",\"rolled_back\":false,\"msg\":\"health check and rollback failed; inspect journalctl -u ${SERVICE_NAME}\"}"
    fi
    return 1
}

json_discard() {
    if [[ -f "$(pending_state_path)" ]]; then
        clear_pending_state
        json_emit "{\"event\":\"done\",\"ok\":true,\"phase\":\"discard\",\"msg\":\"pending update cleared\"}"
    else
        json_emit "{\"event\":\"done\",\"ok\":true,\"phase\":\"discard\",\"msg\":\"no pending update to discard\"}"
    fi
}

run_json_mode() {
    json_setup_fds
    check_root
    detect_node_type
    local install_method
    install_method=$(detect_install_method || true)
    case "$JSON_ACTION" in
        check)   json_check   "$install_method" ;;
        prepare) json_prepare "$install_method" "$JSON_REF" ;;
        apply)   json_apply   "$install_method" ;;
        discard) json_discard ;;
        *)       json_event error "unknown or missing --json action"; return 1 ;;
    esac
}

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
            --discard)   DISCARD_PENDING=true; JSON_ACTION="discard"; shift ;;
            --json)      JSON_MODE=true; shift ;;
            --check)     JSON_ACTION="check"; shift ;;
            --prepare)   JSON_ACTION="prepare"; shift ;;
            --apply)     JSON_ACTION="apply"; shift ;;
            --ref)       JSON_REF="${2:-}"; shift 2 ;;
            --yes)       ASSUME_YES=true; shift ;;
            -h|--help)
                grep '^# ' "$0" | head -30 | sed 's/^# \?//'
                exit 0
                ;;
            *) print_warn "Unknown argument: $1"; shift ;;
        esac
    done

    # Non-interactive JSON mode short-circuits the whole interactive flow.
    if [[ "$JSON_MODE" == "true" ]]; then
        run_json_mode
        exit $?
    fi

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
            print_info "INSTALL_METHOD={source|docker} manually in $(node_meta_path || echo "$(tn_resolve_config_dir)/.node-meta")"
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
