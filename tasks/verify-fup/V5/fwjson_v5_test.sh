#!/usr/bin/env bash
# tasks/verify-fup/V5/fwjson_v5_test.sh -- firewall-setup.sh's --json runs
# through main (V5 driver: the script with check_root stubbed): --json --status
# prints one JSON object with p2p_new_flow_limit, --json --enable with a bad
# TN_P2P_NEW_FLOW_RATE prints only JSON and ends with done ok:false rc 1, and a
# good --json --enable keeps stdout JSON-only while the limit is written.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/../../../tools/tests/lib.sh"
. "${TN_TEST_DIR}/fwstub.sh"
. "${HERE}/v5stubs.sh"
SRC="${V5_SRC:-$TN_TEST_REPO}"
T="$TN_TEST_TMP"
export TN_ROOT_PREFIX="$T/root" UFW_LOG="$T/ufw.log" V5_NFT_LOG="$T/nft.log" TN_FW_SNAP_PARENT="$T/snap" V5_REAL_WRITER=0
R="$TN_ROOT_PREFIX"
mkdir -p "$R/etc/telcoin" "$R/etc/systemd/system" "$R/etc/ufw" "$R/etc/default" "$R/etc/ssh" "$T/snap" "$T/fw"
fw_stub_install "$T/fwbin"
v5_stubs_install "$T/bin" "$T/fwbin"
PATH="$T/bin:/usr/local/bin:/usr/bin:/bin"
grep -v '^main "\$@"$' "${SRC}/firewall-setup.sh" > "$T/fw/firewall-setup.sh"
ln -s "${SRC}/lib" "$T/fw/lib"
v5_overrides_text > "$T/overrides.sh"
cat > "$T/drv.sh" <<V5D
#!/usr/bin/env bash
source "$T/fw/firewall-setup.sh"
source "$T/overrides.sh"
check_root() { :; }
main "\$@"
V5D
printf 'NETWORK=testnet\n' > "$R/etc/telcoin/.node-meta"
: > "$V5_NFT_LOG"; : > "$UFW_LOG"
printf 'allow 22/tcp\n' > "$R/etc/ufw/user.rules"; printf 'ENABLED=yes\n' > "$R/etc/ufw/ufw.conf"
printf 'DEFAULT_INPUT_POLICY="ACCEPT"\n' > "$R/etc/default/ufw"
jsononly() { grep -v '^{' "$1" | grep -q . && echo no || echo yes; }
TN_P2P_NEW_FLOW_RATE=0 bash "$T/drv.sh" --json --enable > "$T/o1" 2> "$T/e1"; rc=$?
check_rc "J1 --json --enable with a bad rate: rc 1" 1 "$rc"
check "J2 stdout is JSON only" "yes" "$(jsononly "$T/o1")"
check_sub "J3 an error event names the variable" '{"event":"error","msg":"TN_P2P_NEW_FLOW_RATE is '"'"'0'"'"', not a whole number' "$(cat "$T/o1")"
check_sub "J4 ends with done ok:false rc 1" '"event":"done","ok":false,"action":"enable","rc":1' "$(tail -n1 "$T/o1")"
check "J5 no ufw mutation, no nft write" "0 0" "$(grep -vc '^status' "$UFW_LOG" 2>/dev/null; true) $(grep -c '^nft -f -$' "$V5_NFT_LOG" 2>/dev/null; true)"
bash "$T/drv.sh" --json --enable > "$T/o2" 2> "$T/e2"; rc=$?
check_rc "J6 --json --enable: rc 0" 0 "$rc"
check "J7 stdout is JSON only (the limit's info lines went to stderr)" "yes" "$(jsononly "$T/o2")"
check_sub "J8 done ok:true" '"event":"done","ok":true' "$(tail -n1 "$T/o2")"
check_sub "J9 the info line is on stderr" "P2P new-flow limit: UDP 49590 and 49594 accept at most 20" "$(cat "$T/e2")"
bash "$T/drv.sh" --json --status > "$T/o3" 2> "$T/e3"; rc=$?
check "J10 --json --status: one line" "1" "$(wc -l < "$T/o3" | tr -d ' ')"
check_sub "J11 --json --status carries the limit, persistent" \
    '"p2p_new_flow_limit":{"active":true,"rate":20,"burst":40,"reason":null,"persistent":true}' "$(cat "$T/o3")"
if command -v python3 > /dev/null 2>&1; then
    check "J12 --json --status parses" "dict" "$(python3 -c 'import json,sys; print(type(json.load(open(sys.argv[1]))).__name__)' "$T/o3" 2>&1)"
else
    skip "J12 JSON parse" "no python3"
fi
finish
