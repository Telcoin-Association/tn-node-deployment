#!/usr/bin/env bash
# =============================================================================
# update-scripts.sh -- Telcoin Network Script Updater
#
# Checks all Telcoin Network node scripts against the latest versions on
# GitHub and downloads any that are out of date.
#
# USAGE:
#   bash ~/telcoin-node-scripts/update-scripts.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly SCRIPT_VERSION="1.1.54"
readonly GITHUB_RAW="https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/main"

# Colours
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly RESET='\033[0m'

print_ok()   { echo -e "  ${GREEN}[OK]${RESET}  $*"; }
print_warn() { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
print_error(){ echo -e "  ${RED}[ERROR]${RESET} $*"; }
print_info() { echo -e "  ${BLUE}->${RESET}  $*"; }
print_sep()  { echo "----------------------------------------------------------------"; }

# =============================================================================
# SCRIPTS TO CHECK
# =============================================================================

# Format: "local_path:remote_path:version_var"
declare -a SCRIPTS=(
    "setup-observer.sh:setup-observer.sh:SCRIPT_VERSION"
    "setup-validator.sh:setup-validator.sh:SCRIPT_VERSION"
    "install-caddy.sh:install-caddy.sh:SCRIPT_VERSION"
    "check-node.sh:check-node.sh:SCRIPT_VERSION"
    "edit-config.sh:edit-config.sh:SCRIPT_VERSION"
    "firewall-setup.sh:firewall-setup.sh:SCRIPT_VERSION"
    "remove-node.sh:remove-node.sh:SCRIPT_VERSION"
    "update-node.sh:update-node.sh:SCRIPT_VERSION"
    "update-scripts.sh:update-scripts.sh:SCRIPT_VERSION"
    "lib/common.sh:lib/common.sh:COMMON_VERSION"
    "lib/testnet-addons.env:lib/testnet-addons.env:TESTNET_ADDONS_VERSION"
    "lib/observability.sh:lib/observability.sh:OBSERVABILITY_VERSION"
    "setup-vpn.sh:setup-vpn.sh:SCRIPT_VERSION"
    "setup-observability.sh:setup-observability.sh:SCRIPT_VERSION"
    "ui/server.py:ui/server.py:UI_VERSION"
)

# The web UI is shipped as a bundle gated on ui/server.py's UI_VERSION. When that
# row needs updating we fetch these companion files alongside server.py and then
# redeploy via install-ui.sh --update. (server.py itself is fetched by the main
# loop because it is the SCRIPTS entry above.)
declare -a UI_BUNDLE=(
    "ui/static/index.html:ui/static/index.html"
    "ui/static/telcoin-logo.png:ui/static/telcoin-logo.png"
    "ui/telcoin-ui-helper.sh:ui/telcoin-ui-helper.sh"
    "ui/telcoin-ui.service:ui/telcoin-ui.service"
    "ui/requirements.txt:ui/requirements.txt"
    "ui/install-ui.sh:ui/install-ui.sh"
)

# Testnet add-on companion files WITHOUT their own version var (the Alloy config +
# the vendored wgvpn bundle). Fetched alongside whenever a versioned add-on file
# (setup-vpn.sh / setup-observability.sh / lib/observability.sh / lib/testnet-addons.env)
# updates -- mirrors how UI_BUNDLE rides along with ui/server.py.
declare -a TESTNET_ADDONS_BUNDLE=(
    "observability/config.alloy:observability/config.alloy"
    "lib/wgvpn/wg-node-bootstrap.sh:lib/wgvpn/wg-node-bootstrap.sh"
    "lib/wgvpn/hub-coordinates.env:lib/wgvpn/hub-coordinates.env"
    "lib/wgvpn/peers/ssh/grant.pub:lib/wgvpn/peers/ssh/grant.pub"
    "lib/wgvpn/peers/ssh/bluelights.pub:lib/wgvpn/peers/ssh/bluelights.pub"
    "lib/wgvpn/peers/ssh/README:lib/wgvpn/peers/ssh/README"
)

# =============================================================================
# HELPERS
# =============================================================================

get_local_version() {
    local file="$1"
    local var="$2"
    local path="${SCRIPT_DIR}/${file}"
    if [[ ! -f "$path" ]]; then
        echo "missing"
        return
    fi
    # Match both bash `readonly FOO="1.2.3"` and Python `FOO = "1.2.3"` so the
    # same updater can version-gate the web UI (UI_VERSION in ui/server.py).
    grep -E "(readonly[[:space:]]+)?${var}[[:space:]]*=" "$path" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown"
}

get_remote_version() {
    local remote_path="$1"
    local var="$2"
    local url="${GITHUB_RAW}/${remote_path}"
    curl --proto '=https' --tlsv1.2 -sf --max-time 10 "$url" 2>/dev/null | \
        grep -E "(readonly[[:space:]]+)?${var}[[:space:]]*=" | \
        grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | \
        head -1 || echo "unavailable"
}

version_gt() {
    # Returns 0 if $1 > $2
    [[ "$1" == "$2" ]] && return 1
    local IFS=.
    local i ver1=($1) ver2=($2)
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z "${ver2[i]:-}" ]]; then ver2[i]=0; fi
        if ((10#${ver1[i]} > 10#${ver2[i]})); then return 0; fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then return 1; fi
    done
    return 1
}

# Bootstrap the updater to the latest version of ITSELF before doing anything
# else, then re-exec. Without this, a node running an older update-scripts.sh
# uses that old copy's file list/logic for the whole run -- it updates itself in
# place but the new logic only takes effect on the NEXT run, so newly-tracked
# files are silently skipped ("ran it once, some updated, others didn't"). With
# this, a single invocation always converges. TN_UPDATER_RELAUNCHED guards
# against re-exec loops; failures here are non-fatal (we just continue).
self_bootstrap() {
    [[ "${TN_UPDATER_RELAUNCHED:-}" == "1" ]] && return 0
    local local_ver remote_ver
    local_ver=$(get_local_version "update-scripts.sh" "SCRIPT_VERSION")
    remote_ver=$(get_remote_version "update-scripts.sh" "SCRIPT_VERSION")
    [[ "$remote_ver" == "unavailable" || "$remote_ver" == "unknown" ]] && return 0
    version_gt "$remote_ver" "$local_ver" || return 0

    print_info "Updating the updater itself (${local_ver} -> ${remote_ver}) and relaunching..."
    local dest="${SCRIPT_DIR}/update-scripts.sh"
    if curl --proto '=https' --tlsv1.2 -sf --max-time 30 "${GITHUB_RAW}/update-scripts.sh" -o "${dest}.tmp" \
        && [[ -s "${dest}.tmp" ]] && bash -n "${dest}.tmp" 2>/dev/null; then
        mv "${dest}.tmp" "$dest"
        chmod +x "$dest" 2>/dev/null || true
        TN_UPDATER_RELAUNCHED=1 exec bash "$dest" "$@"
    fi
    rm -f "${dest}.tmp"
    print_warn "Could not self-update the updater -- continuing with the current version."
}

# =============================================================================
# CHECK VERSIONS
# =============================================================================

check_versions() {
    print_info "Checking for updates from GitHub..."
    print_info "Repository: ${GITHUB_RAW}"
    echo ""

    # Connectivity probe.
    # Earlier versions probed https://github.com directly. That's the full
    # HTML homepage (~200KB) which often timed out at the 5s mark on
    # residential links even when the actual updater endpoint
    # (raw.githubusercontent.com) was responding in well under 1s -- because
    # the homepage pulls JS bundles and assets, and the probe used `curl -sf`
    # which considers an interrupted download a failure.
    # Fix: HEAD-probe the real host the updater fetches from, with a small
    # known file (README.md) and a slightly more generous timeout.
    if ! curl --proto '=https' --tlsv1.2 -sfI --max-time 8 "${GITHUB_RAW}/README.md" &>/dev/null; then
        print_error "Cannot reach ${GITHUB_RAW} -- check internet/DNS or GitHub status"
        exit 1
    fi

    local updates_available=0
    declare -ga FILES_TO_UPDATE=()
    declare -gA LOCAL_VERSIONS=()
    declare -gA REMOTE_VERSIONS=()

    printf "  %-26s %-10s %-10s %s\n" "Script" "Local" "Remote" "Status"
    print_sep

    for entry in "${SCRIPTS[@]}"; do
        local local_path remote_path version_var
        IFS=: read -r local_path remote_path version_var <<< "$entry"

        local local_ver remote_ver status status_colour

        local_ver=$(get_local_version "$local_path" "$version_var")
        remote_ver=$(get_remote_version "$remote_path" "$version_var")

        LOCAL_VERSIONS["$local_path"]="$local_ver"
        REMOTE_VERSIONS["$local_path"]="$remote_ver"

        if [[ "$local_ver" == "missing" ]]; then
            status="MISSING"
            status_colour="${YELLOW}"
            (( ++updates_available ))
            FILES_TO_UPDATE+=("$local_path:$remote_path")
        elif [[ "$remote_ver" == "unavailable" ]]; then
            status="Cannot check"
            status_colour="${YELLOW}"
        elif version_gt "$remote_ver" "$local_ver"; then
            status="UPDATE AVAILABLE"
            status_colour="${YELLOW}"
            (( ++updates_available ))
            FILES_TO_UPDATE+=("$local_path:$remote_path")
        else
            status="Up to date"
            status_colour="${GREEN}"
        fi

        printf "  %-26s %-10s %-10s ${status_colour}%s${RESET}\n" \
            "$local_path" "$local_ver" "$remote_ver" "$status"
    done

    echo ""

    if [[ $updates_available -eq 0 ]]; then
        print_ok "All scripts are up to date"
        echo ""
        exit 0
    fi

    print_warn "${updates_available} script(s) have updates available"
    echo ""
    return 0
}

# =============================================================================
# DOWNLOAD UPDATES
# =============================================================================

download_updates() {
    echo ""
    read -r -p "  Download and install all updates? [Y/n]: " choice
    choice="${choice:-Y}"

    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        print_info "Update cancelled -- no changes made."
        echo ""
        exit 0
    fi

    echo ""
    print_info "Downloading updates..."
    echo ""

    # Always include common.sh if any script is being updated
    local has_common=false
    for entry in "${FILES_TO_UPDATE[@]}"; do
        [[ "$entry" == *"common.sh"* ]] && has_common=true
    done

    if [[ "$has_common" == "false" ]] && [[ ${#FILES_TO_UPDATE[@]} -gt 0 ]]; then
        FILES_TO_UPDATE+=("lib/common.sh:lib/common.sh")
    fi

    # If the UI version row triggered an update, pull the rest of its bundle
    # alongside server.py so the redeploy below has a complete, fresh source.
    local ui_update=false
    for entry in "${FILES_TO_UPDATE[@]}"; do
        [[ "$entry" == ui/server.py:* ]] && ui_update=true
    done
    if [[ "$ui_update" == "true" ]]; then
        FILES_TO_UPDATE+=("${UI_BUNDLE[@]}")
    fi

    # Likewise, pull the testnet add-on companion bundle when any versioned add-on
    # file is updating, so observability/config.alloy + the vendored wgvpn files stay
    # in sync with the scripts that consume them.
    local addons_update=false
    for entry in "${FILES_TO_UPDATE[@]}"; do
        case "$entry" in
            setup-vpn.sh:*|setup-observability.sh:*|lib/observability.sh:*|lib/testnet-addons.env:*) addons_update=true ;;
        esac
    done
    if [[ "$addons_update" == "true" ]]; then
        FILES_TO_UPDATE+=("${TESTNET_ADDONS_BUNDLE[@]}")
    fi

    local success=0
    local failed=0
    # Track the UI bundle separately so the UI redeploy is gated on the UI files
    # themselves succeeding -- not on an unrelated script's download failing.
    local ui_success=0 ui_total=0
    for entry in "${FILES_TO_UPDATE[@]}"; do
        [[ "${entry%%:*}" == ui/* ]] && (( ++ui_total )) || true
    done

    for entry in "${FILES_TO_UPDATE[@]}"; do
        local local_path remote_path
        IFS=: read -r local_path remote_path <<< "$entry"

        local url="${GITHUB_RAW}/${remote_path}"
        local dest="${SCRIPT_DIR}/${local_path}"
        local dest_dir
        dest_dir=$(dirname "$dest")

        mkdir -p "$dest_dir"

        printf "  Downloading %-30s " "${local_path}..."
        if ! curl --proto '=https' --tlsv1.2 -sf --max-time 30 "$url" -o "${dest}.tmp"; then
            rm -f "${dest}.tmp"
            echo -e "${RED}FAILED${RESET}  (download error)"
            (( ++failed ))
            continue
        fi

        # Integrity check 1: file is not empty
        if [[ ! -s "${dest}.tmp" ]]; then
            rm -f "${dest}.tmp"
            echo -e "${RED}FAILED${RESET}  (empty download)"
            (( ++failed ))
            continue
        fi

        # Integrity check 2: opportunistic SHA-256 verification.
        # The Telcoin repo does not currently publish .sha256 sidecars, but
        # check anyway so verification kicks in automatically once they exist.
        # NOTE: trust currently rests on TLS to a mutable branch ref; publish signed tags / pinned commits before mainnet.
        local sha_url="${url}.sha256"
        local remote_sha
        remote_sha=$(curl --proto '=https' --tlsv1.2 -sf --max-time 10 "$sha_url" 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$remote_sha" ]]; then
            local actual_sha
            actual_sha=$(sha256sum "${dest}.tmp" | awk '{print $1}')
            if [[ "$remote_sha" != "$actual_sha" ]]; then
                rm -f "${dest}.tmp"
                echo -e "${RED}FAILED${RESET}  (sha256 mismatch)"
                (( ++failed ))
                continue
            fi
        fi

        # Integrity check 3: shell scripts must parse cleanly.
        # Catches truncated downloads even when no sha256 is published.
        if [[ "$local_path" == *.sh ]]; then
            if ! bash -n "${dest}.tmp" 2>/dev/null; then
                rm -f "${dest}.tmp"
                echo -e "${RED}FAILED${RESET}  (syntax check)"
                (( ++failed ))
                continue
            fi
        fi

        mv "${dest}.tmp" "$dest"
        chmod +x "$dest" 2>/dev/null || true
        if [[ -n "$remote_sha" ]]; then
            echo -e "${GREEN}OK${RESET}      (verified)"
        else
            echo -e "${GREEN}OK${RESET}"
        fi
        (( ++success ))
        [[ "$local_path" == ui/* ]] && (( ++ui_success )) || true
    done

    echo ""

    if [[ $failed -eq 0 ]]; then
        print_ok "${success} script(s) updated successfully"
        echo ""
        print_info "All scripts are now up to date."
        print_info "If a node is running, restart it to apply any changes:"
        print_info "  sudo systemctl restart telcoin-observer"
        print_info "  sudo systemctl restart telcoin-validator"
    else
        print_warn "${success} updated, ${failed} failed"
        print_info "Check your internet connection and try again."
    fi

    echo ""

    # Web UI: the source now sits under ${SCRIPT_DIR}/ui (user-owned, no sudo
    # needed for the fetch). If the UI is installed, redeploy it so the new code
    # actually loads; otherwise just point the operator at the installer. Gated on
    # the UI BUNDLE downloading cleanly (ui_success == ui_total) -- an unrelated
    # script's download failure no longer blocks the UI redeploy.
    if [[ "$ui_update" == "true" && $ui_total -gt 0 && $ui_success -eq $ui_total ]]; then
        if [[ -d /opt/telcoin-ui ]]; then
            echo ""
            print_info "The web UI was updated. Redeploying it now -- ${BOLD}you may be"
            print_info "prompted for your sudo password${RESET} (the redeploy needs root)."
            if sudo bash "${SCRIPT_DIR}/ui/install-ui.sh" --update; then
                print_ok "Web UI redeployed and restarted -- no manual step needed"
            else
                print_warn "Automatic UI redeploy failed -- finish it manually:"
                print_info "  sudo bash ${SCRIPT_DIR}/ui/install-ui.sh --update"
            fi
        else
            print_info "UI source updated -- run the installer to set it up:"
            print_info "  sudo bash ${SCRIPT_DIR}/ui/install-ui.sh"
        fi
        echo ""
    elif [[ "$ui_update" == "true" && $ui_total -gt 0 ]]; then
        print_warn "Some UI files failed to download -- skipping the UI redeploy."
        print_info "Re-run the updater, then if needed: sudo bash ${SCRIPT_DIR}/ui/install-ui.sh --update"
        echo ""
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    clear
    echo -e "${BLUE}${BOLD}"
    echo "================================================================"
    echo "  Telcoin Network -- Script Updater  v${SCRIPT_VERSION}"
    echo "================================================================"
    echo -e "${RESET}"

    self_bootstrap "$@"   # ensure the latest updater logic runs (re-execs if stale)
    check_versions
    download_updates
}

main "$@"
