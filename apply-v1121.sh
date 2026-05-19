#!/usr/bin/env bash
# Run this in ~/tn-repo to apply v1.1.21
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Applying v1.1.21..."

# =============================================================================
# Fix 1: Remove helper scripts from repo
# =============================================================================
for f in apply-v1120.sh fix-toolchain-line.sh; do
    if [[ -f "$SCRIPT_DIR/$f" ]]; then
        git rm "$SCRIPT_DIR/$f" 2>/dev/null || rm -f "$SCRIPT_DIR/$f"
        echo "  Removed: $f"
    fi
done

# =============================================================================
# Fix 2: Add Uptime Kuma port 43174 to firewall-setup.sh
# =============================================================================
python3 << 'PYEOF'
import os

path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'firewall-setup.sh')
with open(path, 'r') as f:
    content = f.read()

# Add Uptime Kuma option after the nginx/443 block in manage_node_ports
old = '''    echo ""
    print_info "Public RPC (nginx on port 443):"
    if ufw status 2>/dev/null | grep -q "443"; then
        print_ok "Port 443 is already open"
    else
        if confirm "Open port 443 for public RPC via nginx?"; then
            ufw allow 443/tcp &>/dev/null
            print_ok "Port 443 opened"
            print_info "Configure nginx to proxy to your RPC port"
        fi
    fi

    echo ""
    read -r -p "  Press Enter to return to menu..."
}'''

new = '''    echo ""
    print_info "Public RPC (nginx on port 443):"
    if ufw status 2>/dev/null | grep -q "443"; then
        print_ok "Port 443 is already open"
    else
        if confirm "Open port 443 for public RPC via nginx?"; then
            ufw allow 443/tcp &>/dev/null
            print_ok "Port 443 opened"
            print_info "Configure nginx to proxy to your RPC port"
        fi
    fi

    echo ""
    print_info "Uptime Kuma health monitoring (TCP port 43174):"
    if ufw status 2>/dev/null | grep -q "43174"; then
        print_ok "Port 43174 is already open"
    else
        if confirm "Open TCP port 43174 for Uptime Kuma health monitoring?"; then
            ufw allow 43174/tcp &>/dev/null
            print_ok "Port 43174 opened"
        fi
    fi

    echo ""
    read -r -p "  Press Enter to return to menu..."
}'''

if old in content:
    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)
    print('  Fix 2 - Added Uptime Kuma port 43174: firewall-setup.sh')
else:
    print('  WARNING: Could not find nginx block in firewall-setup.sh')
PYEOF

# =============================================================================
# Fix 3: Partial install detection in remove-node.sh
# =============================================================================
python3 << 'PYEOF'
import os

path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'remove-node.sh')
with open(path, 'r') as f:
    content = f.read()

# Add partial install detection after the show_detected function
old = '''    if [[ "$OBSERVER_INSTALLED" == "false" ]] && [[ "$VALIDATOR_INSTALLED" == "false" ]]; then
        print_warn "No Telcoin node installations detected on this server."
        print_info "Nothing to remove."
        echo ""
        exit 0
    fi'''

new = '''    if [[ "$OBSERVER_INSTALLED" == "false" ]] && [[ "$VALIDATOR_INSTALLED" == "false" ]]; then
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
    fi'''

if old in content:
    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)
    print('  Fix 3 - Added partial install detection: remove-node.sh')
else:
    print('  WARNING: Could not find target block in remove-node.sh')
PYEOF

# =============================================================================
# Fix 4: Service user/group validation in setup scripts
# =============================================================================
python3 << 'PYEOF'
import os

validation_block = '''
validate_service_name() {
    local name="$1"
    local label="$2"
    # Must start with a letter, only contain letters/numbers/hyphens/underscores, max 32 chars
    if [[ ! "$name" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,31}$ ]]; then
        print_error "${label} name '${name}' is invalid."
        print_info "Must start with a letter, contain only letters/numbers/hyphens/underscores, max 32 chars."
        return 1
    fi
    return 0
}

'''

for script in ['setup-observer.sh', 'setup-validator.sh']:
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), script)
    with open(path, 'r') as f:
        content = f.read()

    # Add validate_service_name function before step_create_infrastructure
    marker = 'step_create_infrastructure() {'
    if marker in content and 'validate_service_name' not in content:
        content = content.replace(marker, validation_block + marker)
        print(f'  Fix 4 - Added validate_service_name function: {script}')

    # Update service user prompt to validate input
    old_user_block = '''    local input
    read -r -p "  Service user name  [${SERVICE_USER}]: "  input; SERVICE_USER="${input:-$SERVICE_USER}"
    read -r -p "  Service group name [${SERVICE_GROUP}]: " input; SERVICE_GROUP="${input:-$SERVICE_GROUP}"
    echo ""

    create_service_user'''

    new_user_block = '''    local input
    while true; do
        read -r -p "  Service user name  [${SERVICE_USER}]: "  input
        local proposed_user="${input:-$SERVICE_USER}"
        if validate_service_name "$proposed_user" "Service user"; then
            # Check it is not already a regular (non-system) user
            if id "$proposed_user" &>/dev/null && [[ $(id -u "$proposed_user") -lt 1000 ]] || ! id "$proposed_user" &>/dev/null; then
                SERVICE_USER="$proposed_user"
                break
            else
                print_error "User '${proposed_user}' already exists as a regular user (UID $(id -u "$proposed_user"))."
                print_info "Please choose a different name or press Enter to use the default."
            fi
        fi
    done

    while true; do
        read -r -p "  Service group name [${SERVICE_GROUP}]: " input
        local proposed_group="${input:-$SERVICE_GROUP}"
        if validate_service_name "$proposed_group" "Service group"; then
            SERVICE_GROUP="$proposed_group"
            break
        fi
    done
    echo ""

    create_service_user'''

    if old_user_block in content:
        content = content.replace(old_user_block, new_user_block)
        print(f'  Fix 4 - Added user/group validation: {script}')
    else:
        print(f'  WARNING: Could not find user block in {script}')

    with open(path, 'w') as f:
        f.write(content)
PYEOF

# =============================================================================
# Bump all versions to 1.1.21
# =============================================================================
for f in setup-observer.sh setup-validator.sh check-node.sh edit-config.sh firewall-setup.sh remove-node.sh update-scripts.sh; do
    sed -i 's/readonly SCRIPT_VERSION="1.1.20"/readonly SCRIPT_VERSION="1.1.21"/' "$SCRIPT_DIR/$f"
    echo "  Bumped: $f"
done

sed -i 's/readonly COMMON_VERSION="1.1.20"/readonly COMMON_VERSION="1.1.21"/' "$SCRIPT_DIR/lib/common.sh"
echo "  Bumped: lib/common.sh"

# =============================================================================
# Update README changelog
# =============================================================================
python3 << 'PYEOF'
with open('README.md', 'r') as f:
    content = f.read()

entry = """### v1.1.21
- Removed helper scripts (`apply-v1120.sh`, `fix-toolchain-line.sh`) from repository
- Added TCP port 43174 (Uptime Kuma health monitoring) to firewall setup script
- Added partial install detection to `remove-node.sh` -- detects and offers to clean up leftover directories from interrupted installs
- Added service user/group name validation in both setup scripts -- prevents crashes when invalid names or existing regular users are entered
- All scripts bumped to v1.1.21

"""

content = content.replace('## Changelog\n\n### v1.1.20', '## Changelog\n\n' + entry + '### v1.1.20')

with open('README.md', 'w') as f:
    f.write(content)
print("  Updated: README.md")
PYEOF

# =============================================================================
# Syntax checks
# =============================================================================
echo ""
echo "Running syntax checks..."
OK=true
for f in setup-observer.sh setup-validator.sh check-node.sh edit-config.sh firewall-setup.sh remove-node.sh update-scripts.sh install.sh lib/common.sh; do
    if bash -n "$SCRIPT_DIR/$f"; then
        echo "  OK: $f"
    else
        echo "  FAIL: $f"
        OK=false
    fi
done

echo ""
if [[ "$OK" == "true" ]]; then
    echo "v1.1.21 upgrade complete. Now run:"
    echo "  git add ."
    echo "  git commit -m 'fix: v1.1.21 - Uptime Kuma port, partial install detection, user validation, remove helper scripts'"
    echo "  git push origin main"
else
    echo "WARNING: One or more syntax checks failed -- review before pushing"
fi
