#!/usr/bin/env bash
# =============================================================================
# install.sh -- Telcoin Network Node Scripts Installer
#
# Downloads the Telcoin Network node scripts from GitHub and sets them up
# ready to use. Run this once on a fresh machine before setting up a node.
#
# USAGE:
#   curl -fsSL https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/main/install.sh | bash
#
#   or:
#   wget -qO- https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/main/install.sh | bash
# =============================================================================

set -euo pipefail

readonly REPO_URL="https://github.com/Telcoin-Association/tn-node-deployment.git"
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

if ! command -v git &>/dev/null; then
    print_error "git is not installed. Please install it first:"
    echo ""
    echo "    Ubuntu/Debian:  sudo apt-get install -y git"
    echo "    RHEL/CentOS:    sudo yum install -y git"
    echo "    macOS:          brew install git"
    echo ""
    exit 1
fi
print_ok "git is available"

if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
    print_warn "Neither curl nor wget found -- may be needed for other operations"
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
    read -r -p "  Re-install and overwrite? [y/N]: " choice
    choice="${choice:-N}"
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        print_info "Installation cancelled."
        echo ""
        exit 0
    fi
    print_step "Removing existing installation..."
    rm -rf "$INSTALL_DIR"
    print_ok "Removed existing installation"
fi

# =============================================================================
# Clone repository
# =============================================================================

print_step "Downloading scripts from GitHub..."
print_info "Repository: ${REPO_URL}"
print_info "Installing to: ${INSTALL_DIR}"
echo ""

if git clone --depth=1 "$REPO_URL" "$INSTALL_DIR"; then
    print_ok "Scripts downloaded successfully"
else
    print_error "Failed to clone repository. Check your internet connection."
    exit 1
fi

# =============================================================================
# Set permissions
# =============================================================================

print_step "Setting permissions..."
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
echo "    # Set up an observer node"
echo "    sudo bash ~/telcoin-node-scripts/setup-observer.sh"
echo ""
echo "    # Set up a validator node"
echo "    sudo bash ~/telcoin-node-scripts/setup-validator.sh"
echo ""
echo "    # Check for script updates in future"
echo "    bash ~/telcoin-node-scripts/update-scripts.sh"
echo ""
echo "    # Optional - install the web UI (health/logs/config/traces over an SSH tunnel)"
echo "    sudo bash ~/telcoin-node-scripts/ui/install-ui.sh"
echo ""
print_info "Full documentation: https://github.com/Telcoin-Association/tn-node-deployment"
echo ""
