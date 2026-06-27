#!/usr/bin/env bash
# =============================================================================
# install.sh -- Telcoin Network Node Scripts Installer
#
# Downloads the Telcoin Network node scripts from GitHub and sets them up
# ready to use. Run this once on a fresh machine before setting up a node.
#
# USAGE:
#   curl -fsSL https://install.telcoin.network | bash
#
#   Fallbacks (raw GitHub URL, if the vanity domain is ever unreachable):
#     curl -fsSL https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/main/install.sh | bash
#     wget -qO-  https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/main/install.sh | bash
# =============================================================================

set -euo pipefail

readonly REPO_URL="https://github.com/Telcoin-Association/tn-node-deployment.git"
readonly TARBALL_URL="https://github.com/Telcoin-Association/tn-node-deployment/archive/refs/heads/main.tar.gz"
readonly INSTALL_DIR="${HOME}/telcoin-node-scripts"
readonly BOLD='\033[1m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly RESET='\033[0m'

print_ok()    { echo -e "  ${GREEN}[OK]${RESET}  $*"; }
print_warn()  { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
print_error() { echo -e "  ${RED}[ERROR]${RESET} $*"; }
print_info()  { echo -e "  ${BLUE}->${RESET}  $*"; }
print_step()  { echo -e "  ${BOLD}>>>${RESET} $*"; }

# Non-interactive overwrite: --yes/-y/--force (or a truthy TN_ASSUME_YES env) skip
# the "Re-install and overwrite?" prompt and proceed as if the operator answered
# yes. With no flag/env the prompt is shown exactly as before.
ASSUME_YES=false
case "${TN_ASSUME_YES:-}" in 1|true|yes|y|TRUE|YES|Y) ASSUME_YES=true ;; esac
for arg in "$@"; do
    case "$arg" in
        --yes|-y|--force) ASSUME_YES=true ;;
    esac
done

echo ""
echo -e "${BLUE}${BOLD}"
echo "================================================================"
echo "  Telcoin Network -- Node Scripts Installer"
echo "================================================================"
echo -e "${RESET}"

# =============================================================================
# Check dependencies
# =============================================================================

print_step "Checking dependencies..."

# A downloader is required -- it fetches the scripts (git clone, or a tarball
# snapshot when git is absent) and is used by the node setup later on.
DOWNLOADER=""
if command -v curl &>/dev/null; then
    DOWNLOADER="curl"
elif command -v wget &>/dev/null; then
    DOWNLOADER="wget"
else
    print_error "Need either curl or wget. Please install one first:"
    echo ""
    echo "    Ubuntu/Debian:  sudo apt-get install -y curl"
    echo "    RHEL/CentOS:    sudo yum install -y curl"
    echo ""
    exit 1
fi
print_ok "downloader available (${DOWNLOADER})"

# git is preferred but optional. A fresh macOS has no git until the Xcode command
# line tools are installed, so fall back to a tarball snapshot (needs tar, which
# ships on stock macOS and Linux). update-scripts.sh keeps a tarball install
# current without git -- it fetches each file over curl/wget.
if command -v git &>/dev/null; then
    print_ok "git is available"
else
    print_warn "git not found -- will download a tarball snapshot instead (no git needed)."
    if ! command -v tar &>/dev/null; then
        print_error "Need git or tar to unpack the scripts. Please install one first:"
        echo ""
        echo "    Ubuntu/Debian:  sudo apt-get install -y git"
        echo "    macOS:          xcode-select --install   (provides git)"
        echo ""
        exit 1
    fi
fi

# =============================================================================
# Check if already installed
# =============================================================================

if [[ -d "$INSTALL_DIR" ]]; then
    print_warn "Scripts already exist at: ${INSTALL_DIR}"
    echo ""
    print_info "To update existing scripts run:"
    print_info "  bash ${INSTALL_DIR}/update-scripts.sh"
    echo ""
    if [[ "$ASSUME_YES" == "true" ]]; then
        print_info "Overwrite confirmed non-interactively (--yes / TN_ASSUME_YES)."
    else
        read -r -p "  Re-install and overwrite? [y/N]: " choice
        choice="${choice:-N}"
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            print_info "Installation cancelled."
            echo ""
            exit 0
        fi
    fi
    print_step "Removing existing installation..."
    rm -rf "$INSTALL_DIR"
    print_ok "Removed existing installation"
fi

# =============================================================================
# Download repository (git clone preferred, tarball snapshot as fallback)
# =============================================================================

print_step "Downloading scripts from GitHub..."
print_info "Installing to: ${INSTALL_DIR}"
echo ""

if command -v git &>/dev/null; then
    print_info "Repository: ${REPO_URL}"
    echo ""
    if git clone --depth=1 "$REPO_URL" "$INSTALL_DIR"; then
        print_ok "Scripts downloaded successfully"
    else
        print_error "Failed to clone repository. Check your internet connection."
        exit 1
    fi
else
    print_info "Snapshot:   ${TARBALL_URL}"
    echo ""
    mkdir -p "$INSTALL_DIR"
    fetched=true
    if [[ "$DOWNLOADER" == "curl" ]]; then
        curl -fsSL "$TARBALL_URL" | tar -xz -C "$INSTALL_DIR" --strip-components=1 || fetched=false
    else
        wget -qO- "$TARBALL_URL" | tar -xz -C "$INSTALL_DIR" --strip-components=1 || fetched=false
    fi
    if [[ "$fetched" == "true" ]]; then
        print_ok "Scripts downloaded successfully (tarball snapshot)"
    else
        print_error "Failed to download or unpack the snapshot. Check your internet connection."
        rm -rf "$INSTALL_DIR"
        exit 1
    fi
fi

# =============================================================================
# Set permissions
# =============================================================================

print_step "Setting permissions..."
chmod +x "${INSTALL_DIR}/setup-node.sh"
chmod +x "${INSTALL_DIR}/setup-observer.sh"
chmod +x "${INSTALL_DIR}/setup-validator.sh"
chmod +x "${INSTALL_DIR}/check-node.sh"
chmod +x "${INSTALL_DIR}/edit-config.sh"
chmod +x "${INSTALL_DIR}/firewall-setup.sh"
chmod +x "${INSTALL_DIR}/remove-node.sh"
chmod +x "${INSTALL_DIR}/update-node.sh"
chmod +x "${INSTALL_DIR}/update-scripts.sh"
chmod +x "${INSTALL_DIR}/install.sh"
chmod +x "${INSTALL_DIR}/setup-vpn.sh"
chmod +x "${INSTALL_DIR}/setup-observability.sh"
chmod +x "${INSTALL_DIR}/lib/wgvpn/wg-node-bootstrap.sh"
chmod +x "${INSTALL_DIR}/ui/install-ui.sh"
chmod +x "${INSTALL_DIR}/ui/telcoin-ui-helper.sh"
print_ok "Permissions set"

# =============================================================================
# Done
# =============================================================================

echo ""
echo -e "${GREEN}${BOLD}"
echo "================================================================"
echo "  Installation complete!"
echo "================================================================"
echo -e "${RESET}"
print_info "Scripts installed to: ${INSTALL_DIR}"
echo ""
print_info "Next steps:"
echo ""
echo "    # Set up your node (one identity; validating is optional and decided on-chain)"
echo "    sudo bash ~/telcoin-node-scripts/setup-node.sh"
echo ""
echo "    # Check for script updates in future"
echo "    bash ~/telcoin-node-scripts/update-scripts.sh"
echo ""
echo "    # Optional - install the web UI (health/logs/config/traces over an SSH tunnel)"
echo "    sudo bash ~/telcoin-node-scripts/ui/install-ui.sh"
echo ""
print_info "Full documentation: https://github.com/Telcoin-Association/tn-node-deployment"
echo ""
