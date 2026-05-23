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

readonly SCRIPT_VERSION="1.1.33"
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
    "check-node.sh:check-node.sh:SCRIPT_VERSION"
    "edit-config.sh:edit-config.sh:SCRIPT_VERSION"
    "firewall-setup.sh:firewall-setup.sh:SCRIPT_VERSION"
    "remove-node.sh:remove-node.sh:SCRIPT_VERSION"
    "update-scripts.sh:update-scripts.sh:SCRIPT_VERSION"
    "lib/common.sh:lib/common.sh:COMMON_VERSION"
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
    grep "readonly ${var}=" "$path" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown"
}

get_remote_version() {
    local remote_path="$1"
    local var="$2"
    local url="${GITHUB_RAW}/${remote_path}"
    curl -sf --max-time 10 "$url" 2>/dev/null | \
        grep "readonly ${var}=" | \
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

# =============================================================================
# CHECK VERSIONS
# =============================================================================

check_versions() {
    print_info "Checking for updates from GitHub..."
    print_info "Repository: ${GITHUB_RAW}"
    echo ""

    # Check internet connectivity
    if ! curl -sf --max-time 5 "https://github.com" &>/dev/null; then
        print_error "No internet connection -- cannot check for updates"
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

    local success=0
    local failed=0

    for entry in "${FILES_TO_UPDATE[@]}"; do
        local local_path remote_path
        IFS=: read -r local_path remote_path <<< "$entry"

        local url="${GITHUB_RAW}/${remote_path}"
        local dest="${SCRIPT_DIR}/${local_path}"
        local dest_dir
        dest_dir=$(dirname "$dest")

        mkdir -p "$dest_dir"

        printf "  Downloading %-30s " "${local_path}..."
        if ! curl -sf --max-time 30 "$url" -o "${dest}.tmp"; then
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
        local sha_url="${url}.sha256"
        local remote_sha
        remote_sha=$(curl -sf --max-time 10 "$sha_url" 2>/dev/null | awk '{print $1}' || true)
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

    check_versions
    download_updates
}

main "$@"
