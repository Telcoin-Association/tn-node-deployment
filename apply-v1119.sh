#!/usr/bin/env bash
# Run this script on your Linux box in ~/tn-node-deployment to complete the v1.1.19 upgrade
# It bumps version numbers in all scripts that only changed version (not content)
# and updates the README changelog.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Bumping remaining scripts to v1.1.19..."

# Bump SCRIPT_VERSION in all scripts
for f in check-node.sh edit-config.sh firewall-setup.sh remove-node.sh update-scripts.sh; do
    sed -i 's/readonly SCRIPT_VERSION="1.1.18"/readonly SCRIPT_VERSION="1.1.19"/' "$SCRIPT_DIR/$f"
    echo "  Bumped: $f"
done

# Bump COMMON_VERSION in lib/common.sh
sed -i 's/readonly COMMON_VERSION="1.1.18"/readonly COMMON_VERSION="1.1.19"/' "$SCRIPT_DIR/lib/common.sh"
echo "  Bumped: lib/common.sh"

# Update README changelog
python3 << 'PYEOF'
import sys
with open('README.md', 'r') as f:
    content = f.read()

entry = """### v1.1.19
- Added branch/tag selection for source builds -- choose `main` (default) or enter any branch or tag name (e.g. `issue-679`) to build unreleased fixes
- Source builds on Adiri testnet now always include `--features faucet` (required for testnet operation)
- Both changes apply to observer and validator setup scripts
- All scripts bumped to v1.1.19

"""

content = content.replace('## Changelog\n\n### v1.1.18', '## Changelog\n\n' + entry + '### v1.1.18')

with open('README.md', 'w') as f:
    f.write(content)
print("  Updated: README.md")
PYEOF

# Syntax check all scripts
echo ""
echo "Running syntax checks..."
for f in setup-observer.sh setup-validator.sh check-node.sh edit-config.sh firewall-setup.sh remove-node.sh update-scripts.sh install.sh lib/common.sh; do
    bash -n "$SCRIPT_DIR/$f" && echo "  OK: $f" || echo "  FAIL: $f"
done

echo ""
echo "v1.1.19 upgrade complete. Now run:"
echo "  git add ."
echo "  git commit -m 'feat: v1.1.19 - branch/tag selection for source builds, faucet feature for testnet'"
echo "  git push origin main"
