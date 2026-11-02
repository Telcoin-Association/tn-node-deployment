#!/usr/bin/env bash
# =============================================================================
# tools/tests/vm.d/P0-08.sh -- the node unit and start script (assertion 4)
#
# Renders node.env, the start script and the unit for a stand-in binary with
# the library helpers, then checks the unit with systemd-analyze verify and its
# offline exposure score (3.0 or lower). The unit is named tn-vmtest so it
# never collides with a real one, and it is never started.
# =============================================================================

set -u
# shellcheck source=tools/tests/vm.d/vm_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/vm_lib.sh"
SERVICE_NAME=tn-vmtest
eval "$(tn_test_source_common)"

for fn in tn_write_node_env tn_write_start_script tn_write_node_unit; do
    if ! have_fn "$fn"; then
        skip "unit verify and exposure score" "$fn not in lib/common.sh yet"
        finish
    fi
done

id telcoin >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin telcoin
getent group telcoin-log >/dev/null 2>&1 || groupadd --system telcoin-log
mkdir -p /var/lib/telcoin
# shellcheck disable=SC2034  # read by the library helpers
NETWORK=testnet
# shellcheck disable=SC2034
LOG_TARGET=journal
# shellcheck disable=SC2034
PASSPHRASE_METHOD=credential
# shellcheck disable=SC2034
DATA_DIR=/var/lib/telcoin
install -o root -g root -m 0755 /dev/null /usr/local/bin/telcoin-network
printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/telcoin-network
unit="/etc/systemd/system/${SERVICE_NAME}.service"

tn_write_node_env /ip4/0.0.0.0/udp/49590/quic-v1 /ip4/0.0.0.0/udp/49595/quic-v1 > "$TN_TEST_TMP/w.log" 2>&1
check_rc "tn_write_node_env" 0 "$?" || sed 's/^/    /' "$TN_TEST_TMP/w.log"
tn_write_start_script release /usr/local/bin/telcoin-network "--datadir /var/lib/telcoin --http" > "$TN_TEST_TMP/w.log" 2>&1
check_rc "tn_write_start_script" 0 "$?" || sed 's/^/    /' "$TN_TEST_TMP/w.log"
tn_write_node_unit release > "$TN_TEST_TMP/w.log" 2>&1
check_rc "tn_write_node_unit" 0 "$?" || sed 's/^/    /' "$TN_TEST_TMP/w.log"

out="$(systemd-analyze verify "$unit" 2>&1)"
check_rc "systemd-analyze verify" 0 "$?" || printf '%s\n' "$out" | sed 's/^/    /'
score="$(systemd-analyze security --offline=true --no-pager "$unit" 2>/dev/null \
    | grep -o 'Overall exposure level for [^:]*: [0-9.]*' | awk '{print $NF}')"
check "4: exposure score 3.0 or lower (got ${score:-none})" "yes" \
    "$(awk -v s="${score:-99}" 'BEGIN { print (s + 0 <= 3.0) ? "yes" : "no" }')"
rm -f "$unit"

finish
