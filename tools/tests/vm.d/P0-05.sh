#!/usr/bin/env bash
# =============================================================================
# tools/tests/vm.d/P0-05.sh -- signed script releases (assertions 7 and 8)
#
# A tampered manifest and an older serial are refused with the tree unchanged,
# and the installer verifies before it installs: the fixture tests for the
# updater, the installer, the release tool and the release ceremony, run on
# the VM's own gpgv (and gpg where the image has it; the tests fall back to
# stand-ins without it).
# =============================================================================

set -u
# shellcheck source=tools/tests/vm.d/vm_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/vm_lib.sh"

check "gpgv can verify signatures" "yes" "$(command -v gpgv >/dev/null 2>&1 && echo yes || echo no)"
for t in updater_manifest_test.sh install_test.sh release_scripts_test.sh cut_release_test.sh; do
    bash "$VM_REPO/tools/tests/$t" > "$TN_TEST_TMP/$t.log" 2>&1
    rc=$?
    check_rc "$t passes" 0 "$rc" || sed 's/^/    /' "$TN_TEST_TMP/$t.log"
done

finish
