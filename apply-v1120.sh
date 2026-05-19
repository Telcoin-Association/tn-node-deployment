#!/usr/bin/env bash
# Run this in ~/tn-repo to apply v1.1.20
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Applying v1.1.20..."

# Fix 1: Add clang and libclang-dev to build_deps in both setup scripts
for script in setup-observer.sh setup-validator.sh; do
    sed -i 's/local build_deps=("build-essential" "cmake" "libclang-16-dev" "pkg-config" "libssl-dev" "libapr1-dev")/local build_deps=("build-essential" "cmake" "clang" "libclang-dev" "libclang-16-dev" "pkg-config" "libssl-dev" "libapr1-dev")/' "$SCRIPT_DIR/$script"
    echo "  Fix 1 - Updated build_deps: $script"
done

# Fix 2+3: Use Python to insert cargo PATH and toolchain install block
python3 << 'PYEOF'
import os

insertion = '''
    # Ensure cargo is in PATH -- it may have just been installed as root
    export PATH="${HOME}/.cargo/bin:/root/.cargo/bin:${PATH}"
    source "${HOME}/.cargo/env" 2>/dev/null || true

    # Install the exact Rust toolchain version required by this repo
    if [[ -f "${source_dir}/rust-toolchain.toml" ]]; then
        local required_toolchain
        required_toolchain=$(grep "channel" "${source_dir}/rust-toolchain.toml" 2>/dev/null | head -1 | grep -oE \\'[0-9]+\\.[0-9]+[^"]*\\' | tr -d \\'\\')
        if [[ -n "$required_toolchain" ]]; then
            print_info "Installing required Rust toolchain: ${required_toolchain}..."
            rustup toolchain install "$required_toolchain" 2>/dev/null || true
            print_ok "Rust toolchain ready: ${required_toolchain}"
        fi
    fi

'''

marker = '    # Ensure C/C++ build dependencies are present'

for script in ['setup-observer.sh', 'setup-validator.sh']:
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), script)
    with open(path, 'r') as f:
        content = f.read()
    if marker in content:
        content = content.replace(marker, insertion + marker, 1)
        with open(path, 'w') as f:
            f.write(content)
        print(f'  Fix 2+3 - Added cargo PATH and toolchain install: {script}')
    else:
        print(f'  WARNING: marker not found in {script} - skipping Fix 2+3')
PYEOF

# Bump all versions to 1.1.20
for f in setup-observer.sh setup-validator.sh check-node.sh edit-config.sh firewall-setup.sh remove-node.sh update-scripts.sh; do
    sed -i 's/readonly SCRIPT_VERSION="1.1.19"/readonly SCRIPT_VERSION="1.1.20"/' "$SCRIPT_DIR/$f"
    echo "  Bumped: $f"
done

sed -i 's/readonly COMMON_VERSION="1.1.19"/readonly COMMON_VERSION="1.1.20"/' "$SCRIPT_DIR/lib/common.sh"
echo "  Bumped: lib/common.sh"

# Update README changelog
python3 << 'PYEOF'
with open('README.md', 'r') as f:
    content = f.read()

entry = """### v1.1.20
- Added `clang` and `libclang-dev` to source build dependency checks -- fixes `stdarg.h` not found error when building from source on fresh machines
- Fixed cargo PATH for source builds -- cargo env is sourced correctly after Rust installation, including root cargo path fallback
- Added automatic Rust toolchain installation -- reads `rust-toolchain.toml` from the repo and installs the required toolchain version before building
- All scripts bumped to v1.1.20

"""

content = content.replace('## Changelog\n\n### v1.1.19', '## Changelog\n\n' + entry + '### v1.1.19')

with open('README.md', 'w') as f:
    f.write(content)
print("  Updated: README.md")
PYEOF

# Syntax checks
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
    echo "v1.1.20 upgrade complete. Now run:"
    echo "  git add ."
    echo "  git commit -m 'fix: v1.1.20 - clang deps, cargo PATH, rust toolchain auto-install for source builds'"
    echo "  git push origin main"
else
    echo "WARNING: One or more syntax checks failed -- review before pushing"
fi
