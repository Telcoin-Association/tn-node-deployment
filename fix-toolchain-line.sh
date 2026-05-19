#!/usr/bin/env bash
# Fix the broken toolchain detection line in setup-observer.sh and setup-validator.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 << 'PYEOF'
import os, re

# The broken line to replace
old_line = '''        required_toolchain=$(grep "channel" "${source_dir}/rust-toolchain.toml" 2>/dev/null | head -1 | grep -oE \\'[0-9]+\\.[0-9]+[^"]*\\' | tr -d \\'\\')'''

# Simple replacement using cut instead of complex regex
new_line = '''        required_toolchain=$(grep "channel" "${source_dir}/rust-toolchain.toml" 2>/dev/null | head -1 | cut -d'"' -f2)'''

for script in ['setup-observer.sh', 'setup-validator.sh']:
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), script)
    with open(path, 'r') as f:
        content = f.read()
    if old_line in content:
        content = content.replace(old_line, new_line)
        with open(path, 'w') as f:
            f.write(content)
        print(f'  Fixed toolchain line: {script}')
    else:
        # Try a broader match
        import re
        pattern = r'        required_toolchain=\$\(grep "channel".*rust-toolchain.*\)'
        match = re.search(pattern, content)
        if match:
            content = content[:match.start()] + new_line + content[match.end():]
            with open(path, 'w') as f:
                f.write(content)
            print(f'  Fixed toolchain line (regex): {script}')
        else:
            print(f'  WARNING: could not find toolchain line in {script}')
PYEOF

echo ""
echo "Syntax checks..."
for f in setup-observer.sh setup-validator.sh; do
    bash -n "$SCRIPT_DIR/$f" && echo "  OK: $f" || echo "  FAIL: $f"
done
