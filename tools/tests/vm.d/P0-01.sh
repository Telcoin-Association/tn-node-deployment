#!/usr/bin/env bash
# =============================================================================
# tools/tests/vm.d/P0-01.sh -- root-owned install and config trees
# (assertions 1 and 2)
#
# Builds a fake install in the older layout (the service user owns /opt/telcoin
# and /etc/telcoin), runs tn_migrate_ownership, then checks that nothing under
# the install, config and libexec trees is owned by anyone but root and that
# the service user cannot create a link in /opt/telcoin. No node binary.
# =============================================================================

set -u
# shellcheck source=tools/tests/vm.d/vm_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/vm_lib.sh"
eval "$(tn_test_source_common)"

if ! have_fn tn_migrate_ownership; then
    skip "ownership migration on a fake install" "tn_migrate_ownership not in lib/common.sh yet"
    finish
fi

id telcoin >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin telcoin
getent group telcoin-log >/dev/null 2>&1 || groupadd --system telcoin-log
mkdir -p /opt/telcoin /etc/telcoin /var/lib/telcoin /var/log/telcoin
printf '#!/bin/sh\nexit 0\n' > /opt/telcoin/telcoin-network
chmod 0755 /opt/telcoin/telcoin-network
printf 'v0.0.0-vmtest\n' > /opt/telcoin/telcoin-network.version
printf 'NETWORK=testnet\nNODE_TYPE=validator\nINSTALL_METHOD=binary\nDATA_DIR=/var/lib/telcoin\nSERVICE_USER=telcoin\nSERVICE_GROUP=telcoin\n' \
    > /etc/telcoin/.node-meta
chown -R telcoin:telcoin /opt/telcoin /etc/telcoin /var/lib/telcoin /var/log/telcoin

tn_migrate_ownership > "$TN_TEST_TMP/migrate.log" 2>&1
rc=$?
check_rc "tn_migrate_ownership on the old layout" 0 "$rc" || sed 's/^/    /' "$TN_TEST_TMP/migrate.log"
check "1: install, config and libexec trees are root-owned" "" \
    "$(find /opt/telcoin /etc/telcoin /usr/local/libexec/telcoin ! -user root 2>/dev/null)"
check "2: the service user cannot create a link in /opt/telcoin" "denied" \
    "$(runuser -u telcoin -- ln -s /etc/x /opt/telcoin/vmtest-link 2>/dev/null && echo created || echo denied)"
check "migration is idempotent" "0" "$(tn_migrate_ownership >/dev/null 2>&1; echo $?)"

finish
