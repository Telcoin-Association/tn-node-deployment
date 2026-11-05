#!/usr/bin/env bash
# =============================================================================
# tasks/verify-fup/V5/realnft_v5.sh -- the P2P new-flow limit against the real
# nft, in a throwaway container with CAP_NET_ADMIN (its own network namespace):
#   docker run --rm --cap-add NET_ADMIN -v "$PWD:/w" -w /w ubuntu:24.04 \
#       bash tasks/verify-fup/V5/realnft_v5.sh
# Installs nftables (and python3 for a UDP sender/listener), renders the program
# with firewall-setup.sh's own functions, loads it twice, lists it, parses the
# listing with fw_p2p_limit_live, deletes it present and absent, checks the
# refusals are atomic, and sends new UDP flows over lo to see the meter drop.
# =============================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "$(id -u)" == 0 ]] || { echo "needs root in a container"; exit 2; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -q > /dev/null 2>&1
apt-get install -y -q nftables python3-minimal iproute2 > /tmp/apt.log 2>&1 || { tail -5 /tmp/apt.log; exit 2; }
. "${HERE}/../../../tools/tests/lib.sh"
. "${HERE}/v5stubs.sh"
T="$TN_TEST_TMP"
export TN_ROOT_PREFIX="$T/root"
mkdir -p "$TN_ROOT_PREFIX/etc/telcoin" "$T/fw" "$T/bin"
# systemctl stub only (the container has no systemd); the real nft stays on PATH.
v5_stubs_install "$T/sb" "$T/sb"
cp "$T/sb/systemctl" "$T/bin/systemctl"
PATH="$T/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
NFT="$(command -v nft)"
echo "info  $("$NFT" --version) at $NFT; kernel $(uname -r)"
grep -v '^main "\$@"$' "${TN_TEST_REPO}/firewall-setup.sh" > "$T/fw/firewall-setup.sh"
ln -s "${TN_TEST_REPO}/lib" "$T/fw/lib"
v5_overrides_text > "$T/overrides.sh"
source "$T/fw/firewall-setup.sh"
source "$T/overrides.sh"
set +e
REC="${HERE}/records"
mkdir -p "$REC"
printf 'NETWORK=testnet\n' > "$TN_ROOT_PREFIX/etc/telcoin/.node-meta"

fw_p2p_limit_text 20 40 > "$T/p.nft"
"$NFT" -c -f "$T/p.nft" > "$T/c.out" 2>&1; check_rc "N1 nft -c -f on the rendered program" 0 $?
"$NFT" -f "$T/p.nft" > "$T/l1.out" 2>&1; r1=$?
check_rc "N2 first load (no table yet)" 0 "$r1"; [[ $r1 == 0 ]] || cat "$T/l1.out"
"$NFT" -f "$T/p.nft" > "$T/l2.out" 2>&1; r2=$?
check_rc "N3 second load (table present): idempotent" 0 "$r2"; [[ $r2 == 0 ]] || cat "$T/l2.out"
"$NFT" list table inet tn_p2p > "$REC/nft-list-table.txt" 2>&1
L="$(cat "$REC/nft-list-table.txt")"
check_sub "N4 listing has set tn_p2p_src4" "set tn_p2p_src4 {" "$L"
check_sub "N5 listing has set tn_p2p_src6" "set tn_p2p_src6 {" "$L"
check_sub "N6 listing keeps the /64 mask" "ip6 saddr & ffff:ffff:ffff:ffff::" "$L"
check "N7 listing: exactly one chain, two rules with ct state new" "1 2" \
    "$(grep -c 'chain input' <<< "$L") $(grep -c 'ct state new' <<< "$L")"
check "N8 a second load did not duplicate the rules" "2" "$(grep -c 'drop' <<< "$L")"
check "N9 fw_p2p_limit_live parses the real listing" "on 20 40" "$(FW_P2P_LOADED=false; fw_p2p_limit_live)"
"$NFT" -f - <<< $'table inet tn_p2p\ndelete table inet tn_p2p' > "$T/d1.out" 2>&1
check_rc "N10 delete-only program, table present" 0 $?
"$NFT" -f - <<< $'table inet tn_p2p\ndelete table inet tn_p2p' > "$T/d2.out" 2>&1
check_rc "N11 delete-only program, table absent" 0 $?
check "N12 table gone after the delete" "" "$("$NFT" list tables | grep tn_p2p)"
"$NFT" delete table inet tn_p2p > /dev/null 2>&1; echo "info  N13 plain 'nft delete table' on an absent table rc=$? (ExecStop has the - prefix)"
for spec in '49590 primary\n' '49590 primary\n49594 worker-0\n49595 worker-1\n'; do
    V5_PORTS="$spec" fw_p2p_limit_text 20 40 > "$T/v.nft"
    "$NFT" -f "$T/v.nft" > "$T/v.out" 2>&1
    check_rc "N14 ports [$(printf '%b' "$spec" | awk '{print $1}' | paste -sd, -)] load" 0 $?
done
for rb in "1 100000" "100000 1" "100000 100000" "1 1"; do
    fw_p2p_limit_text $rb > "$T/rb.nft"
    "$NFT" -f "$T/rb.nft" > "$T/rb.out" 2>&1; rc=$?
    check_rc "N15 rate/burst ${rb} loads" 0 "$rc"; [[ $rc == 0 ]] || head -3 "$T/rb.out"
done
# atomic refusal: a broken program leaves the loaded table as it was
"$NFT" -f "$T/p.nft"
V5_PORTS='49590 primary\nabc worker-0\n' fw_p2p_limit_text 7 9 > "$T/bad.nft"
"$NFT" -f "$T/bad.nft" > "$T/bad.out" 2>&1; rb=$?
check "N16 a non-numeric port is refused by nft" "yes" "$([[ $rb != 0 ]] && echo yes)"
check "N17 the refused program left the previous table (20/40)" "on 20 40" "$(FW_P2P_LOADED=false; fw_p2p_limit_live)"
# end to end with the script's own sync: write, then a list deletes it
FW_P2P_RATE=20; FW_P2P_BURST=40; FW_P2P_SRCS=(); FW_P2P_LOADED=true
fw_p2p_limit_sync telcoin.service > "$T/s1.out" 2>&1
check "N18 fw_p2p_limit_sync writes it with the real nft" "on 20 40" "$(FW_P2P_LOADED=false; fw_p2p_limit_live)"
check "N19 boot program written and loadable" "0" "$("$NFT" -c -f "$TN_ROOT_PREFIX/etc/telcoin/p2p-limit.nft" > /dev/null 2>&1; echo $?)"
FW_P2P_SRCS=(10.0.0.0/8); FW_P2P_LOADED=true
fw_p2p_limit_sync telcoin.service > "$T/s2.out" 2>&1
check "N20 with a list the sync deletes it" "" "$("$NFT" list tables | grep tn_p2p)"
FW_P2P_SRCS=(); FW_P2P_LOADED=true
# the meter on real traffic: 60 new flows from 127.0.0.1 over lo to 49590
fw_p2p_limit_sync telcoin.service > /dev/null 2>&1
cat > "$T/udp.py" <<'V5P'
import socket, sys, time
fam = socket.AF_INET6 if ":" in sys.argv[1] else socket.AF_INET
dst, src, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
rx = socket.socket(fam, socket.SOCK_DGRAM); rx.bind((dst, 49590)); rx.settimeout(0.5)
for i in range(n):
    tx = socket.socket(fam, socket.SOCK_DGRAM)
    if src != "-":
        tx.bind((src, 0))
    tx.sendto(b"x", (dst, 49590)); tx.close()
got = 0
while True:
    try:
        rx.recvfrom(16); got += 1
    except socket.timeout:
        break
print(got)
V5P
got4="$(python3 "$T/udp.py" 127.0.0.1 - 60 2>&1)"
echo "info  N21 60 new IPv4 flows from 127.0.0.1: ${got4} delivered (burst 40, 20/minute)"
check "N21 the v4 meter lets about the burst through and drops the rest" "yes" \
    "$([[ "$got4" =~ ^[0-9]+$ && "$got4" -ge 40 && "$got4" -le 42 ]] && echo yes)"
"$NFT" list set inet tn_p2p tn_p2p_src4 > "$REC/nft-set4-after-traffic.txt" 2>&1
check_sub "N22 v4 set keyed per address" "127.0.0.1" "$(cat "$REC/nft-set4-after-traffic.txt")"
if command ip -6 addr add 2001:db8:1:2::5/128 dev lo 2>/dev/null && command ip -6 addr add 2001:db8:1:2::6/128 dev lo 2>/dev/null \
   && command ip -6 addr add 2001:db8:9::1/128 dev lo 2>/dev/null; then
    sleep 1
    a="$(python3 "$T/udp.py" 2001:db8:9::1 2001:db8:1:2::5 30 2>&1)"
    b="$(python3 "$T/udp.py" 2001:db8:9::1 2001:db8:1:2::6 30 2>&1)"
    echo "info  N23 30 + 30 IPv6 flows from ::5 and ::6 of one /64: ${a} + ${b} delivered"
    check "N23 two addresses of one /64 share the burst" "yes" \
        "$([[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && $((a + b)) -ge 40 && $((a + b)) -le 42 ]] && echo yes)"
    "$NFT" list set inet tn_p2p tn_p2p_src6 > "$REC/nft-set6-after-traffic.txt" 2>&1
    check_sub "N24 v6 set holds the /64 (2001:db8:1:2::)" "2001:db8:1:2::" "$(cat "$REC/nft-set6-after-traffic.txt")"
    check_lacks "N25 v6 set holds no full address" "2001:db8:1:2::5" "$(cat "$REC/nft-set6-after-traffic.txt")"
else
    skip "N23-N25 IPv6 /64 traffic" "cannot add IPv6 addresses to lo here"
fi
# established flows untouched: one socket pair, 60 datagrams on one flow
"$NFT" -f - <<< $'table inet tn_p2p\ndelete table inet tn_p2p'
fw_p2p_limit_sync telcoin.service > /dev/null 2>&1
cat > "$T/est.py" <<'V5P'
import socket, sys
reply = sys.argv[1] == "reply"
rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); rx.bind(("127.0.0.1", 49594)); rx.settimeout(0.5)
tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); tx.bind(("127.0.0.1", 0)); tx.settimeout(0.5)
got = 0
tx.sendto(b"x", ("127.0.0.1", 49594))
if reply:
    _, peer = rx.recvfrom(16); got += 1
    rx.sendto(b"y", peer); tx.recvfrom(16)
for i in range(59):
    tx.sendto(b"x", ("127.0.0.1", 49594))
while True:
    try:
        rx.recvfrom(16); got += 1
    except socket.timeout:
        break
print(got)
V5P
est="$(python3 "$T/est.py" reply 2>&1)"
check "N26 one flow the receiver answers (established after the reply): all 60 datagrams delivered" "60" "$est"
"$NFT" -f - <<< $'table inet tn_p2p\ndelete table inet tn_p2p'
fw_p2p_limit_sync telcoin.service > /dev/null 2>&1
uni="$(python3 "$T/est.py" noreply 2>&1)"
echo "info  N27 one flow never answered: ${uni} of 60 datagrams delivered (ct state stays new until a reply)"
check "N27 (finding) an unanswered flow is metered per packet, not per flow" "40" "$uni"
"$NFT" list ruleset > "$REC/nft-ruleset-final.txt" 2>&1
finish
