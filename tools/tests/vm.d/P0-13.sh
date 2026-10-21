#!/usr/bin/env bash
# =============================================================================
# tools/tests/vm.d/P0-13.sh -- no perl program expands a shell variable
# (assertion 23)
# =============================================================================

set -u
# shellcheck source=tools/tests/vm.d/vm_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/vm_lib.sh"

if [[ ! -f "$VM_REPO/tools/check-perl-interp.sh" ]]; then
    skip "check-perl-interp.sh finds nothing" "tools/check-perl-interp.sh not in the tree yet"
    finish
fi
out="$(cd "$VM_REPO" && git ls-files -z '*.sh' | xargs -0 bash tools/check-perl-interp.sh 2>&1)"
rc=$?
check_rc "check-perl-interp.sh finds nothing" 0 "$rc" || printf '%s\n' "$out" | sed 's/^/    /'

finish
