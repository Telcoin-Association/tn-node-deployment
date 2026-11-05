#!/usr/bin/env bash
# V6 repro: firewall-setup.sh view_status on a mainnet node names the testnet
# monitor address (TN_KUMA_SRC, via a variable the lint cannot see) and calls the
# by-design closed health port an error. Uses the fixture stubs; touches nothing
# on the host. Usage: bash kuma_mainnet_repro.sh
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$here/../../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT
# shellcheck source=tools/tests/fwstub.sh
. "$REPO/tools/tests/fwstub.sh"
export TN_ROOT_PREFIX="$T/root" UFW_LOG="$T/ufw.log" NFT_LOG="$T/nft.log" TN_FW_SNAP_PARENT="$T/snap"
mkdir -p "$TN_ROOT_PREFIX/etc/telcoin" "$TN_ROOT_PREFIX/etc/ufw" "$TN_ROOT_PREFIX/etc/default" \
    "$TN_ROOT_PREFIX/etc/ssh" "$TN_FW_SNAP_PARENT" "$T/fw"
fw_stub_install "$T/bin"
PATH="$T/bin:/usr/local/bin:/usr/bin:/bin"
grep -v '^main "\$@"$' "$REPO/firewall-setup.sh" > "$T/fw/firewall-setup.sh"
ln -s "$REPO/lib" "$T/fw/lib"
# shellcheck source=/dev/null
source "$T/fw/firewall-setup.sh"
set +e
NETWORK=mainnet
for state in anywhere closed; do
    ufw_active() { return 0; }
    # shellcheck disable=SC2317,SC2329 # called by view_status
    detect_installed_nodes() { printf "%s\n" validator; }
    # shellcheck disable=SC2317,SC2329 # called by view_status
    fw_lib_check() { return 0; }
    # shellcheck disable=SC2317,SC2329 # called by view_status
    kuma_rule_state() { printf '%s\n' "$KSTATE"; }
    KSTATE="$state"
    printf -- '--- NETWORK=%s, health port %s\n' "$NETWORK" "$state"
    view_status </dev/null > "$T/out" 2>&1; sed "s/\x1b\[[0-9;]*m//g" "$T/out" | grep -A3 "Uptime Kuma"
done
