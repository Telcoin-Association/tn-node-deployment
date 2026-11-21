#!/usr/bin/env bash
# V-CHAIN harness: lib/gateway.sh (_gw_chain_fits, _gw_chain_name, _gw_chain_check
# with a curl stub on PATH), lib/alerts.sh (ALERTS_CHAIN_ID per network, writers
# stubbed) and lib/tn-heartbeat.sh (_hb_check_rpc's chain comparison, _hb_rpc
# stubbed), per chain id.
#
#   bash tasks/verify-req/V-CHAIN/harness/h_addons.sh
set -u
HDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HDIR}/../../../.." && pwd)"
# shellcheck source=/dev/null
. "${REPO}/tools/tests/lib.sh"
T="$TN_TEST_TMP"
TN_ROOT_PREFIX="$T/fx"
mkdir -p "$T/fx/etc/telcoin" "$T/bin"
eval "$(tn_test_source_common)"

echo "== lib/gateway.sh"
for net in mainnet testnet devnet; do
    line=""
    for id in 731 487 2017 32285 12345; do
        rc=0; _gw_chain_fits "$net" "$id" || rc=$?
        line="${line} ${id}:$([[ $rc -eq 0 ]] && echo fits || echo no)"
    done
    printf '   _gw_chain_fits %-7s%s\n' "$net" "$line"
done
check "_gw_chain_fits devnet 487 (upstream devnet id)" "0" "$(_gw_chain_fits devnet 487; echo $?)"
check "_gw_chain_fits devnet 731" "1" "$(_gw_chain_fits devnet 731; echo $?)"
check "_gw_chain_fits mainnet 731 / 487" "0 1" "$(_gw_chain_fits mainnet 731; printf '%s ' $?; _gw_chain_fits mainnet 487; printf '%s' $?)"
check "_gw_chain_name 731 / 487 / 2017" "mainnet|neither mainnet nor testnet|testnet" \
    "$(_gw_chain_name 731)|$(_gw_chain_name 487)|$(_gw_chain_name 2017)"
printf '%s\n' '#!/bin/sh' 'cat "$GW_STUB_ANSWER"' > "$T/bin/curl"
chmod 0755 "$T/bin/curl"
GW_STUB_ANSWER="$T/answer"
export GW_STUB_ANSWER
PATH="$T/bin:$PATH"
hash -r
gwc() {
    printf '{"jsonrpc":"2.0","id":1,"result":"%s"}' "$2" > "$GW_STUB_ANSWER"
    _GW_CHAIN_KEY="" GW_ERR="" rc=0
    _gw_chain_check "$1" 10.0.0.12 8545 >/dev/null 2>&1 || rc=$?
    printf 'rc=%s %s' "$rc" "$GW_ERR"
}
for c in "mainnet 0x2db" "mainnet 0x1e7" "devnet 0x1e7" "devnet 0x2db" "testnet 0x2db"; do
    # shellcheck disable=SC2086
    printf '   _gw_chain_check %-14s -> %s\n' "$c" "$(gwc $c)"
done
check "gateway: mainnet given, upstream 0x1e7: refused" "rc=1 the upstream http://10.0.0.12:8545 is on chain 487 (neither mainnet nor testnet), and the network given is mainnet: give the network that node runs" "$(gwc mainnet 0x1e7)"
check "gateway: devnet given, upstream 0x1e7: fits" "rc=0 " "$(gwc devnet 0x1e7)"

echo "== lib/alerts.sh: ALERTS_CHAIN_ID"
tn_resolve_service() { printf 'telcoin\n'; }
alerts_rpc_url() { printf 'http://127.0.0.1:8545\n'; }
_alerts_health_port() { printf '9090\n'; }
_alerts_dir_ready() { return 0; }
tn_write_root_file() { cat > "$T/alerts.env"; }
AL_NET=""
addon_meta_get() { [[ "$1" == NETWORK ]] && printf '%s\n' "$AL_NET"; return 0; }
for net in mainnet testnet devnet other; do
    AL_NET="$net"; rm -f "$T/alerts.env"; rc=0
    alerts_write_env 60 240 600 >/dev/null 2>&1 || rc=$?
    printf '   NETWORK=%-7s rc=%s %s\n' "$net" "$rc" "$(grep '^ALERTS_CHAIN_ID=' "$T/alerts.env" 2>/dev/null || echo "(no file: ${ALERTS_ERR:-})")"
done
AL_NET=mainnet; alerts_write_env 60 240 600 >/dev/null 2>&1
check_has "alerts.env, mainnet" "ALERTS_CHAIN_ID=731" "$(cat "$T/alerts.env")"

echo "== lib/tn-heartbeat.sh: the chain comparison"
# shellcheck source=/dev/null
. "${REPO}/lib/tn-heartbeat.sh"
HB_HEX=""
_hb_rpc() { r_rc=0; r_code=200; r_time=0.010; r_body="{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"${HB_HEX}\"}"; }
hb() {
    local chain_id="$1" rpc_url="http://127.0.0.1:8545" svc_active=1 svc_since="" started=0 grace=60
    local down_msg="" up_msg="" rpc_up=0 ping=""
    HB_HEX="$2"
    _hb_check_rpc
    printf 'down="%s"' "$down_msg"
}
for c in "731 0x2db" "731 0x1e7" "731 0x2DB" "731 0x02db" "487 0x1e7"; do
    # shellcheck disable=SC2086
    printf '   expected %-10s -> %s\n' "$c" "$(hb $c)"
done
check "heartbeat, mainnet env, rpc 0x2db" 'down=""' "$(hb 731 0x2db)"
check "heartbeat, mainnet env, rpc 0x1e7" 'down="wrong chain: rpc reports 487, expected 731"' "$(hb 731 0x1e7)"
check "heartbeat, an old alerts.env (487), rpc 0x2db" 'down="wrong chain: rpc reports 731, expected 487"' "$(hb 487 0x2db)"
finish
