#!/usr/bin/env bash
# =============================================================================
# tools/tests/vm.d/P0-09.sh -- log rotation on every install (assertion 13)
# =============================================================================

set -u
# shellcheck source=tools/tests/vm.d/vm_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/vm_lib.sh"
eval "$(tn_test_source_common)"

if ! have_fn tn_install_logrotate; then
    skip "logrotate config" "tn_install_logrotate not in lib/common.sh yet"
    finish
fi
getent group telcoin-log >/dev/null 2>&1 || groupadd --system telcoin-log
mkdir -p /var/log/telcoin
tn_install_logrotate > "$TN_TEST_TMP/l.log" 2>&1
check_rc "tn_install_logrotate" 0 "$?" || sed 's/^/    /' "$TN_TEST_TMP/l.log"
out="$(logrotate -d /etc/logrotate.d/telcoin 2>&1)"
check_rc "13: logrotate -d accepts the config" 0 "$?" || printf '%s\n' "$out" | sed 's/^/    /'
check "13: the config selects the node logs" "yes" "$(printf '%s\n' "$out" | grep -q '/var/log/telcoin' && echo yes || echo no)"

finish
