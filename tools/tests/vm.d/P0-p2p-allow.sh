#!/usr/bin/env bash
# =============================================================================
# tools/tests/vm.d/P0-p2p-allow.sh -- the P2P committee allowlist end to end,
# with the pinned tn-p2p-allow-sync release, under systemd and a real kernel
#
# A fake node: telcoin.service runs a python3 JSON-RPC stand-in on
# 127.0.0.1:8545, built like the one in P0-alerts.sh; this one serves a
# tn_admissionSnapshot v1 result read from a file, so the test can change it,
# and tn_getCurrentEpochInfo. .node-meta says NETWORK=testnet,
# OWNERSHIP_LAYOUT=2, RPC_PORT=8545, and /etc/telcoin/bootstrap-peers.yaml
# names one floor peer. firewall-setup.sh --reset turns ufw on and loads the
# new-flow limit (table inet tn_p2p); its listing, its boot copy and ufw's
# rule files are kept for the end.
#
# firewall-setup.sh --p2p-committee on then downloads the pinned release from
# GitHub, checks it with the real gpgv and installs it. The steps after it:
#   1. --version: the first line is the pin, and the binary is root 0755.
#   2. The journal holds the gpgv status lines of that check (a pass-through
#      gpgv first on PATH copies them there): GOODSIG, and VALIDSIG by a key of
#      lib/release-keys.
#   3. The three units: root 0644, systemd-analyze verify clean,
#      systemd-analyze security on the two services (score recorded, no
#      threshold yet), boot unit and timer enabled, and one run of the sync
#      unit inside its sandbox exits 0 with a fresh sync line.
#   4. Table inet tn_p2p_allow holds exactly the two snapshot addresses and the
#      floor address; table inet tn_p2p is gone.
#   5. The boot unit: open question 10 first (its first load with
#      ProtectKernelModules=yes in a runtime drop-in, reported and never
#      enforced), then a start, a stop (the table goes) and a start again, which
#      reloads current.nft with the same elements.
#   6. Open question 9: both named counters count real packets (a listed source
#      on lo, an unlisted one) and keep their values when the same program is
#      loaded again with nft -f and when a changed snapshot makes one
#      --p2p-committee sync load a changed program.
#   7. An element deleted by hand comes back after one --p2p-committee sync.
#   8. --p2p-committee off: table inet tn_p2p, its boot copy and unit, and
#      ufw's user.rules and user6.rules are byte-identical to before on, and no
#      unit, state dir or binary of the allowlist is left.
# On exit everything this file made is removed and the files it replaced are
# put back; ufw is turned off again when it was off before.
#
# SKIPs with "tn-p2p-allow-sync <tag> is not published" while lib/common.sh
# pins no tarball sha256 for the tag, or the release's SHA256SUMS cannot be
# downloaded; also without curl, python3, systemd as the init system or one of
# the tools the steps call, and on a host the release has no binary for.
# =============================================================================

set -u
# shellcheck source=tools/tests/vm.d/vm_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/vm_lib.sh"

NAME="P2P committee allowlist end to end"
FW="$VM_REPO/firewall-setup.sh"
T="$TN_TEST_TMP"

# step TEXT -- a heading in the CI log for the checks that follow.
step() {
    printf '\n== %s\n' "$1"
}

# note TEXT -- a fact this file records without judging it.
note() {
    printf 'NOTE  %s\n' "$1"
}

# indent -- copy stdin to stdout four spaces in, for command output in the log.
indent() {
    sed 's/^/    /'
}

# --- the release gate -----------------------------------------------------------
# the pin is read from the library itself, in a child shell: the library turns
# on set -e and pipefail, which this file does not want.
# shellcheck disable=SC2016  # expanded by the child shell
pin="$(bash -c '. "$1/lib/common.sh" >/dev/null 2>&1 || exit 1
printf "%s\n%s\n%s\n" "${TN_P2P_ALLOW_VERSION:-}" "${TN_P2P_ALLOW_TARBALL_SHA256:-}" "${TN_P2P_ALLOW_BASE_URL:-}"' \
    pin "$VM_REPO")" || pin=""
VER="$(sed -n 1p <<< "$pin")"
SHA="$(sed -n 2p <<< "$pin")"
BASE="$(sed -n 3p <<< "$pin")"
if [[ -z "$VER" || -z "$BASE" ]] || ! grep -q -- '--p2p-committee' "$FW"; then
    skip "$NAME" "the tn-p2p-allow-sync pin or firewall-setup.sh --p2p-committee is not in the tree yet"
    finish
fi
# everything from here to the last SKIP of this block reads files and the
# network only. The local dry run in a container has no systemd, so this file
# must reach its SKIP there before any systemd call (systemctl, journalctl,
# systemd-analyze); the EXIT trap that calls systemctl is set after this block.
if [[ -z "$SHA" ]]; then
    note "lib/common.sh pins no sha256 for the ${VER} tarball (TN_P2P_ALLOW_TARBALL_SHA256 is empty), so its install refuses"
    skip "$NAME" "tn-p2p-allow-sync ${VER} is not published"
    finish
fi
if ! command -v curl >/dev/null 2>&1; then
    skip "$NAME" "curl not installed on this VM"
    finish
fi
if ! curl --proto '=https' --tlsv1.2 -fsSL --max-time 60 --max-filesize 1048576 \
    -o "$T/SHA256SUMS" --url "${BASE}/${VER}/SHA256SUMS" 2> "$T/curl.err"; then
    note "GET ${BASE}/${VER}/SHA256SUMS failed: $(head -n 1 "$T/curl.err")"
    skip "$NAME" "tn-p2p-allow-sync ${VER} is not published"
    finish
fi
note "${BASE}/${VER}/SHA256SUMS:"
indent < "$T/SHA256SUMS"
PY="$(command -v python3 2>/dev/null)" || PY=""
if [[ -z "$PY" ]]; then
    skip "$NAME" "python3 not installed on this VM"
    finish
fi
if [[ ! -d /run/systemd/system ]]; then
    skip "$NAME" "systemd is not the init system here"
    finish
fi
for tool in nft ufw flock ip gpg gpgv logger cmp systemctl journalctl systemd-analyze; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        skip "$NAME" "$tool not installed on this VM"
        finish
    fi
done
case "$(uname -m)" in
    x86_64|amd64) ;;
    *)
        skip "$NAME" "tn-p2p-allow-sync publishes an x86_64 binary only, not one for $(uname -m)"
        finish
        ;;
esac

# --- what this file changes, and how it is put back ----------------------------------
D=/usr/local/libexec/tn-vmtest-p2p-allow
UNIT_D=/etc/systemd/system
ALLOW_DIR=/var/lib/telcoin-p2p-allow
BIN=/usr/local/libexec/telcoin/tn-p2p-allow-sync
BOOT=telcoin-p2p-allow.service
SYNC=telcoin-p2p-allow-sync.service
TIMER=telcoin-p2p-allow-sync.timer
LIMIT=telcoin-p2p-limit.service
LIMIT_FILE=/etc/telcoin/p2p-limit.nft
DROPIN_D="/run/systemd/system/${BOOT}.d"
# a snapshot address put on lo, so packets from a listed source reach the
# counters without leaving the host.
LOCAL_SRC=198.51.100.7
GPGV_TAG="tn-vmtest-gpgv-$$"
REAL_GPGV="$(command -v gpgv)"
REAL_LOGGER="$(command -v logger)"

SAVED=(/etc/telcoin/.node-meta /etc/telcoin/bootstrap-peers.yaml "$UNIT_D/telcoin.service")
mkdir -p "$T/saved"
i=0
for f in "${SAVED[@]}"; do
    if [[ -e "$f" ]]; then cp -p "$f" "$T/saved/$i"; fi
    i=$((i + 1))
done
UFW_WAS_ACTIVE=no
if grep -qx 'Status: active' <<< "$(ufw status 2>/dev/null)"; then UFW_WAS_ACTIVE=yes; fi
BUILD_USER_MADE=no
if ! id -u tn-build >/dev/null 2>&1 && [[ ! -e /var/lib/tn-build ]]; then BUILD_USER_MADE=yes; fi
STAGING_MADE=no
if [[ ! -e /var/lib/telcoin-staging ]]; then STAGING_MADE=yes; fi
DATA_MADE=no
if [[ ! -e /var/lib/telcoin ]]; then DATA_MADE=yes; fi
LO_ADDED=no

# table_loaded NAME -- yes when nft lists table inet NAME, else no.
table_loaded() {
    local tables
    tables="$(nft list tables 2>/dev/null)"
    if grep -qx "table inet $1" <<< "$tables"; then echo yes; else echo no; fi
}

# vm_cleanup -- the EXIT trap. Failures here are ignored on purpose (this file
# runs without set -e): each step undoes what a failed run may have left.
vm_cleanup() {
    local f i=0
    # the allowlist first, units before the table, so no timer run loads it again.
    systemctl stop "$TIMER" "$SYNC" "$BOOT" >/dev/null 2>&1
    systemctl disable "$TIMER" "$BOOT" >/dev/null 2>&1
    rm -f "$UNIT_D/$TIMER" "$UNIT_D/$SYNC" "$UNIT_D/$BOOT"
    rm -rf "$DROPIN_D"
    if [[ "$(table_loaded tn_p2p_allow)" == "yes" ]]; then nft delete table inet tn_p2p_allow; fi
    rm -rf "$ALLOW_DIR"
    rm -f "$BIN"
    # the new-flow limit that --reset loaded.
    systemctl disable --now "$LIMIT" >/dev/null 2>&1
    rm -f "$UNIT_D/$LIMIT" "$LIMIT_FILE"
    if [[ "$(table_loaded tn_p2p)" == "yes" ]]; then nft delete table inet tn_p2p; fi
    if [[ "$UFW_WAS_ACTIVE" != "yes" ]]; then ufw --force disable >/dev/null 2>&1; fi
    # the fake node and the files it replaced.
    systemctl stop telcoin.service >/dev/null 2>&1
    for f in "${SAVED[@]}"; do
        if [[ -e "$T/saved/$i" ]]; then cp -p "$T/saved/$i" "$f"; else rm -f "$f"; fi
        i=$((i + 1))
    done
    rm -rf "$D"
    if [[ "$LO_ADDED" == "yes" ]]; then ip addr del "${LOCAL_SRC}/32" dev lo; fi
    if [[ "$BUILD_USER_MADE" == "yes" ]]; then
        userdel tn-build >/dev/null 2>&1
        rm -rf /var/lib/tn-build
    fi
    if [[ "$STAGING_MADE" == "yes" ]]; then rm -rf /var/lib/telcoin-staging; fi
    if [[ "$DATA_MADE" == "yes" ]]; then rm -rf /var/lib/telcoin; fi
    systemctl daemon-reload >/dev/null 2>&1
    systemctl reset-failed telcoin.service "$BOOT" "$SYNC" "$LIMIT" >/dev/null 2>&1
    tn_test_cleanup
}
trap vm_cleanup EXIT

# vm_snapshot IP... -- the tn_admissionSnapshot v1 result the stand-in serves,
# written whole to $D/snapshot.json: epoch 42, one primary swarm, available and
# authoritative (tracked_epoch 42, admission epoch 42, fallback null), and one
# current and eligible entry per IP, keyed by a BLS key of 0x and 192 hex
# digits that depends on the IP's position only.
vm_snapshot() {
    local i=0 ip key entries=""
    for ip in "$@"; do
        i=$((i + 1))
        key="$(printf '0x%02x%0190d' "$i" 0)"
        entries="${entries:+${entries},}{\"bls_pubkey\":\"${key}\",\"slots\":[\"current\",\"eligible\"],\"peer_id\":\"12D3KooWVmTest${i}\",\"network_pubkey\":\"23${i}\",\"multiaddrs\":[\"/ip4/${ip}/udp/49590/quic-v1\"],\"record_timestamp\":1793750400,\"source\":\"record\",\"admitted\":true}"
    done
    printf '{"version":1,"epoch":42,"swarms":[{"network":"primary","worker_id":null,"available":true,"tracked_epoch":42,"admission":{"configured":"Closed","effective":"Closed","epoch":42,"fallback":null,"resolved_current":%s,"required_current":%s,"connected_current":%s,"contradicted":0},"entries":[%s]}]}\n' \
        "$#" "$#" "$(($# - 1))" "$entries" > "$D/snapshot.json.new"
    mv -f "$D/snapshot.json.new" "$D/snapshot.json"
}

# set_elems SET -- the elements of set SET of table inet tn_p2p_allow, one per
# line, sorted; nothing when the set is empty or gone.
set_elems() {
    nft list set inet tn_p2p_allow "$1" 2>/dev/null | awk '
        /elements = \{/ { on = 1; sub(/.*elements = \{/, "") }
        on {
            last = sub(/\}.*/, "")
            n = split($0, a, /[ ,\t]+/)
            for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
            if (last) on = 0
        }' | LC_ALL=C sort
}

# counter_packets NAME -- the packets of named counter NAME of table inet
# tn_p2p_allow; nothing when it is gone.
counter_packets() {
    nft list counter inet tn_p2p_allow "$1" 2>/dev/null | sed -n 's/.*packets \([0-9][0-9]*\) bytes.*/\1/p'
}

# at_least A B -- yes when A is a whole number not below B.
at_least() {
    if [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= $2 )); then echo yes; fi
}

# send_udp SRC PORT COUNT -- COUNT UDP datagrams from SRC to SRC:PORT, so they
# reach the input hook through lo with source SRC.
send_udp() {
    "$PY" -I -c 'import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((sys.argv[1], 0))
for _ in range(int(sys.argv[3])):
    s.sendto(b"tn-vmtest", (sys.argv[1], int(sys.argv[2])))' "$1" "$2" "$3"
}

# sync_idle -- wait until no run of the sync unit is in flight (up to 60 s).
sync_idle() {
    local n=0
    while [[ "$(systemctl is-active "$SYNC" 2>/dev/null)" == "activating" && $n -lt 60 ]]; do
        sleep 1
        n=$((n + 1))
    done
}

# run_fw ARG... -- firewall-setup.sh ARG... with stdin closed; its output in
# $T/fw.out, rc the script's.
run_fw() {
    timeout 600 bash "$FW" "$@" < /dev/null > "$T/fw.out" 2>&1
}

# nf_mods -- the loaded netfilter modules, one name per line, sorted.
nf_mods() {
    awk '$1 ~ /^(nf_|nft_|nfnetlink)/ { print $1 }' /proc/modules | LC_ALL=C sort
}

# --- the fake node ------------------------------------------------------------------
step "the fake node: telcoin.service runs a JSON-RPC stand-in on 127.0.0.1:8545"
install -d -o root -g root -m 0755 "$D" /etc/telcoin /usr/local/libexec/telcoin
if [[ "$DATA_MADE" == "yes" ]]; then install -d -o root -g root -m 0700 /var/lib/telcoin; fi
cat > "$D/rpc.py" <<'PYEOF'
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

# the snapshot file is read on every call, so the test can change what the
# node serves between two syncs.
SNAPSHOT = sys.argv[1]
EPOCH_INFO = {"epoch": 42, "epochDuration": 21600}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            req = {}
        method = req.get("method")
        body = {"jsonrpc": "2.0", "id": req.get("id", 1)}
        if method == "tn_admissionSnapshot":
            with open(SNAPSHOT) as f:
                body["result"] = json.load(f)
        elif method == "tn_getCurrentEpochInfo":
            body["result"] = EPOCH_INFO
        else:
            body["error"] = {"code": -32601, "message": "method not found"}
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", 8545), Handler).serve_forever()
PYEOF
chmod 0644 "$D/rpc.py"
vm_snapshot 203.0.113.10 198.51.100.7
printf '[Unit]\nDescription=Fake Telcoin node for P0-p2p-allow\n\n[Service]\nExecStart=%s -I %s/rpc.py %s/snapshot.json\n' \
    "$PY" "$D" "$D" > "$UNIT_D/telcoin.service"
printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nINSTALL_METHOD=binary\nDATA_DIR=/var/lib/telcoin\nRPC_PORT=8545\n' > /etc/telcoin/.node-meta
chmod 0600 /etc/telcoin/.node-meta
printf 'peers:\n  - /ip4/192.0.2.50/udp/49590/quic-v1\n' > /etc/telcoin/bootstrap-peers.yaml
chmod 0644 /etc/telcoin/bootstrap-peers.yaml
systemctl daemon-reload
systemctl start telcoin.service
answer=""
for _ in $(seq 1 40); do
    answer="$(curl -s -X POST -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","method":"tn_admissionSnapshot","params":[],"id":1}' http://127.0.0.1:8545)"
    [[ -n "$answer" ]] && break
    sleep 0.25
done
if ! check "the stand-in serves tn_admissionSnapshot version 1" "yes" "$(grep -q '"version": 1' <<< "$answer" && echo yes)"; then
    journalctl -u telcoin.service --no-pager -o cat -n 20 2>/dev/null | indent
    finish
fi

# --- the firewall before committee mode ---------------------------------------------
step "firewall-setup.sh --reset: ufw on, the P2P ports open, the new-flow limit loaded"
run_fw --reset
rc=$?
if ! check_rc "firewall-setup.sh --reset" 0 "$rc"; then
    tail -n 40 "$T/fw.out" | indent
    finish
fi
check "ufw active" "Status: active" "$(ufw status | head -n 1)"
check "table inet tn_p2p loaded" "yes" "$(table_loaded tn_p2p)"
check "$LIMIT enabled" "enabled" "$(systemctl is-enabled "$LIMIT" 2>/dev/null)"
mkdir -p "$T/before"
nft list table inet tn_p2p > "$T/before/tn_p2p" 2>&1
for f in "$LIMIT_FILE" "$UNIT_D/$LIMIT" /etc/ufw/user.rules /etc/ufw/user6.rules; do
    cp -p "$f" "$T/before/${f##*/}"
done

# --- on -------------------------------------------------------------------------------
step "firewall-setup.sh --p2p-committee on: install ${VER} from GitHub, check it with gpgv, load the allowlist"
# the keys the install may accept, as lib/common.sh lists them (_tn_release_keyring).
install -d -m 0700 "$T/gnupg"
ALLOW=""
for k in "$VM_REPO"/lib/release-keys/*.asc; do
    ALLOW="${ALLOW}$(GNUPGHOME="$T/gnupg" gpg --batch --no-tty --quiet --with-colons --import-options show-only \
        --import < "$k" 2>/dev/null | awk -F: '$1 == "pub" { want = 1; next } $1 == "fpr" && want { print $10; want = 0 }')"$'\n'
done
# the scripts send gpgv's status lines to their own verdict and its messages to
# /dev/null, so nothing reaches the journal; this pass-through runs the real
# gpgv with the same arguments, hands its output on unchanged and copies the
# status lines to the journal under GPGV_TAG.
mkdir -p "$T/shim"
cat > "$T/shim/gpgv" <<SHIM
#!/bin/sh
out="\$(${REAL_GPGV} "\$@")"
rc=\$?
printf '%s\n' "\$out" | ${REAL_LOGGER} -t ${GPGV_TAG}
printf '%s\n' "\$out"
exit "\$rc"
SHIM
chmod 0755 "$T/shim/gpgv"
PATH="$T/shim:$PATH" timeout 600 bash "$FW" --p2p-committee on < /dev/null > "$T/fw.out" 2>&1
rc=$?
indent < "$T/fw.out"
if ! check_rc "firewall-setup.sh --p2p-committee on" 0 "$rc"; then
    finish
fi
check ".node-meta says P2P_COMMITTEE=on" "P2P_COMMITTEE=on" "$(grep '^P2P_COMMITTEE=' /etc/telcoin/.node-meta)"

step "1: the installed binary is the pinned release"
check "the binary is root:root 0755" "root:root 755" "$(stat -c '%U:%G %a' "$BIN" 2>/dev/null)"
vout="$("$BIN" --version 2>&1)"
indent <<< "$vout"
check "--version first line is the pin" "tn-p2p-allow-sync ${VER#v}" "$(sed -n 1p <<< "$vout")"

step "2: the journal holds the gpgv check of the release's SHA256SUMS"
journalctl --sync >/dev/null 2>&1
glog="$(journalctl -t "$GPGV_TAG" --no-pager -o cat 2>/dev/null)"
indent <<< "$glog"
check "journal: gpgv said GOODSIG" "yes" "$(grep -q '^\[GNUPG:] GOODSIG ' <<< "$glog" && echo yes)"
fpr="$(sed -n 's/^\[GNUPG:] VALIDSIG .* \([0-9A-F]\{40\}\)$/\1/p' <<< "$glog" | head -n 1)"
check "journal: VALIDSIG by a key of lib/release-keys (${fpr:-none})" "yes" \
    "$([[ -n "$fpr" ]] && grep -qxF -- "$fpr" <<< "$ALLOW" && echo yes)"

step "3: the three units"
for u in "$BOOT" "$SYNC" "$TIMER"; do
    check "$u is root:root 0644" "root:root 644" "$(stat -c '%U:%G %a' "$UNIT_D/$u" 2>/dev/null)"
done
out="$(systemd-analyze verify "$UNIT_D/$BOOT" "$UNIT_D/$SYNC" "$UNIT_D/$TIMER" 2>&1)"
rc=$?
check_rc "systemd-analyze verify on the three units" 0 "$rc" || indent <<< "$out"
check_lacks "systemd-analyze verify warns about none of them" "telcoin-p2p-allow" "$out"
# a timer runs no process, so its exposure score measures nothing: the score is
# recorded for the two services.
for u in "$BOOT" "$SYNC"; do
    score="$(systemd-analyze security --offline=true --no-pager "$UNIT_D/$u" 2>/dev/null \
        | grep -o 'Overall exposure level for [^:]*: [0-9.]*' | awk '{print $NF}')"
    check "systemd-analyze security $u: exposure ${score:-none} (recorded, no threshold yet)" "yes" \
        "$([[ "$score" =~ ^[0-9]+[.][0-9]+$ ]] && echo yes)"
done
check "$BOOT enabled" "enabled" "$(systemctl is-enabled "$BOOT" 2>/dev/null)"
check "$TIMER enabled" "enabled" "$(systemctl is-enabled "$TIMER" 2>/dev/null)"
check "$TIMER active" "active" "$(systemctl is-active "$TIMER" 2>/dev/null)"
# the timer may have started a run already (OnBootSec is long past); a start
# then waits for that run.
timeout 120 systemctl start "$SYNC"
rc=$?
check_rc "systemctl start $SYNC (one run inside its sandbox)" 0 "$rc"
check "$SYNC result" "success" "$(systemctl show -p Result --value "$SYNC" 2>/dev/null)"
check "$SYNC exit status" "0" "$(systemctl show -p ExecMainStatus --value "$SYNC" 2>/dev/null)"
inv="$(systemctl show -p InvocationID --value "$SYNC" 2>/dev/null)"
journalctl --sync >/dev/null 2>&1
slog="$(journalctl --no-pager -o cat "_SYSTEMD_INVOCATION_ID=${inv}" 2>/dev/null)"
indent <<< "$slog"
check "journal: the run printed a fresh sync line for epoch 42" "yes" \
    "$(grep -qE '^result=(applied|unchanged) reason= epoch=42 ' <<< "$slog" && echo yes)"
# no timer run from here on unless a --p2p-committee sync below starts it again.
systemctl stop "$TIMER"
sync_idle

step "4: table inet tn_p2p_allow holds the two snapshot addresses and the floor address"
check "table inet tn_p2p_allow loaded" "yes" "$(table_loaded tn_p2p_allow)"
check "table inet tn_p2p gone while committee mode is on" "no" "$(table_loaded tn_p2p)"
v4="$(set_elems allow_v4)"
indent <<< "$v4"
check_has "allow_v4 holds 203.0.113.10 (snapshot)" "203.0.113.10" "$v4"
check_has "allow_v4 holds 198.51.100.7 (snapshot)" "198.51.100.7" "$v4"
check "allow_v4 is the two snapshot addresses and the floor (192.0.2.50), nothing else" \
    "$(printf '%s\n' 192.0.2.50 198.51.100.7 203.0.113.10 | LC_ALL=C sort)" "$v4"
check "allow_v6, static_v4 and static_v6 are empty" "" \
    "$(set_elems allow_v6; set_elems static_v4; set_elems static_v6)"

step "5: the boot unit (open question 10 at its first load, then a restart reloads current.nft)"
expect="$v4"
# open question 10: is ProtectKernelModules=yes safe on the boot unit, whose
# first load after boot may need the kernel to load nftables modules? Reported,
# never enforced: the shipped unit leaves it off.
if grep -q '^nf_tables ' /proc/modules; then
    nft_state="nf_tables loaded as a module, used by $(awk '$1 == "nf_tables" { print $3 }' /proc/modules)"
elif [[ -d /sys/module/nf_tables ]]; then
    nft_state="nf_tables built into the kernel"
else
    nft_state="nf_tables not loaded"
fi
nf_mods > "$T/mods.before"
nft delete table inet tn_p2p_allow
install -d -m 0755 "$DROPIN_D"
printf '[Service]\nProtectKernelModules=yes\n' > "$DROPIN_D/50-vmtest-protect-kernel-modules.conf"
systemctl daemon-reload
timeout 60 systemctl start "$BOOT" > "$T/probe.out" 2>&1
prc=$?
ploaded="$(table_loaded tn_p2p_allow)"
nf_mods > "$T/mods.after"
newmods="$(grep -vxF -f "$T/mods.before" "$T/mods.after" | tr '\n' ' ')"
note "open question 10 (kernel $(uname -r)): $BOOT with ProtectKernelModules=yes: start rc ${prc}, table loaded ${ploaded}; before it ${nft_state}; modules loaded by the start: ${newmods:-none}"
if [[ "$prc" -ne 0 ]]; then
    indent < "$T/probe.out"
    journalctl -u "$BOOT" --no-pager -o cat -n 10 2>/dev/null | indent
fi
systemctl stop "$BOOT" >/dev/null 2>&1
rm -rf "$DROPIN_D"
systemctl daemon-reload
systemctl reset-failed "$BOOT" >/dev/null 2>&1
if [[ "$(table_loaded tn_p2p_allow)" == "yes" ]]; then nft delete table inet tn_p2p_allow; fi
# the shipped unit.
timeout 60 systemctl start "$BOOT"
check_rc "start $BOOT" 0 "$?"
check "$BOOT active" "active" "$(systemctl is-active "$BOOT" 2>/dev/null)"
check "start: allow_v4 loaded from current.nft" "$expect" "$(set_elems allow_v4)"
timeout 60 systemctl stop "$BOOT"
check_rc "stop $BOOT" 0 "$?"
check "stop: ExecStop deleted table inet tn_p2p_allow" "no" "$(table_loaded tn_p2p_allow)"
timeout 60 systemctl start "$BOOT"
check_rc "start $BOOT again" 0 "$?"
check "restart: table inet tn_p2p_allow loaded again" "yes" "$(table_loaded tn_p2p_allow)"
check "restart: allow_v4 reloaded from current.nft" "$expect" "$(set_elems allow_v4)"

step "6: open question 9: the named counters survive a reload (kernel $(uname -r), $(nft --version 2>/dev/null))"
if ip addr add "${LOCAL_SRC}/32" dev lo; then LO_ADDED=yes; fi
send_udp "$LOCAL_SRC" 49590 3
send_udp 127.0.0.1 49590 2
sleep 1
acc0="$(counter_packets tn_accept_p2p_listed)"
drop0="$(counter_packets tn_drop_p2p_unlisted)"
check "tn_accept_p2p_listed counted the listed source (${acc0:-none} packets, 3 sent)" "yes" "$(at_least "$acc0" 3)"
check "tn_drop_p2p_unlisted counted 127.0.0.1 (${drop0:-none} packets, 2 sent)" "yes" "$(at_least "$drop0" 2)"
cp "$ALLOW_DIR/current.nft" "$T/current.1"
out="$(nft -f "$ALLOW_DIR/current.nft" 2>&1)"
check_rc "nft -f current.nft (the same program again)" 0 "$?" || indent <<< "$out"
acc1="$(counter_packets tn_accept_p2p_listed)"
drop1="$(counter_packets tn_drop_p2p_unlisted)"
check "same program: tn_accept_p2p_listed kept its value (${acc0:-none} -> ${acc1:-none})" "yes" "$(at_least "$acc1" "${acc0:-1}")"
check "same program: tn_drop_p2p_unlisted kept its value (${drop0:-none} -> ${drop1:-none})" "yes" "$(at_least "$drop1" "${drop0:-1}")"
vm_snapshot 203.0.113.10 198.51.100.7 203.0.113.20
run_fw --p2p-committee sync
rc=$?
indent < "$T/fw.out"
check_rc "firewall-setup.sh --p2p-committee sync (a changed snapshot)" 0 "$rc"
check "the changed snapshot changed current.nft" "yes" "$(cmp -s "$T/current.1" "$ALLOW_DIR/current.nft" || echo yes)"
check_has "allow_v4 holds 203.0.113.20 (the new entry)" "203.0.113.20" "$(set_elems allow_v4)"
acc2="$(counter_packets tn_accept_p2p_listed)"
drop2="$(counter_packets tn_drop_p2p_unlisted)"
check "changed program: tn_accept_p2p_listed kept its value (${acc1:-none} -> ${acc2:-none})" "yes" "$(at_least "$acc2" "${acc1:-1}")"
check "changed program: tn_drop_p2p_unlisted kept its value (${drop1:-none} -> ${drop2:-none})" "yes" "$(at_least "$drop2" "${drop1:-1}")"
note "open question 9 on this image: accept ${acc0:-?} -> ${acc1:-?} -> ${acc2:-?}, drop ${drop0:-?} -> ${drop1:-?} -> ${drop2:-?} (same program, then a changed one)"
systemctl stop "$TIMER"
sync_idle

step "7: an element deleted by hand comes back after one --p2p-committee sync"
expect="$(set_elems allow_v4)"
out="$(nft delete element inet tn_p2p_allow allow_v4 '{ 203.0.113.10 }' 2>&1)"
check_rc "nft delete element allow_v4 { 203.0.113.10 }" 0 "$?" || indent <<< "$out"
check "deleted: allow_v4 lacks 203.0.113.10" "no" \
    "$(if grep -qxF 203.0.113.10 <<< "$(set_elems allow_v4)"; then echo yes; else echo no; fi)"
run_fw --p2p-committee sync
rc=$?
indent < "$T/fw.out"
check_rc "firewall-setup.sh --p2p-committee sync" 0 "$rc"
check "healed: allow_v4 is whole again" "$expect" "$(set_elems allow_v4)"

step "8: firewall-setup.sh --p2p-committee off brings the earlier P2P firewall back byte for byte"
run_fw --p2p-committee off
rc=$?
indent < "$T/fw.out"
check_rc "firewall-setup.sh --p2p-committee off" 0 "$rc"
check ".node-meta says P2P_COMMITTEE=off" "P2P_COMMITTEE=off" "$(grep '^P2P_COMMITTEE=' /etc/telcoin/.node-meta)"
check "table inet tn_p2p_allow gone" "no" "$(table_loaded tn_p2p_allow)"
check "table inet tn_p2p byte-identical to before on" "$(cat "$T/before/tn_p2p")" "$(nft list table inet tn_p2p 2>&1)"
for f in "$LIMIT_FILE" "$UNIT_D/$LIMIT" /etc/ufw/user.rules /etc/ufw/user6.rules; do
    check "${f} byte-identical to before on" "yes" "$(cmp -s "$T/before/${f##*/}" "$f" && echo yes)"
done
check "$LIMIT enabled again" "enabled" "$(systemctl is-enabled "$LIMIT" 2>/dev/null)"
left=""
for f in "$UNIT_D/$BOOT" "$UNIT_D/$SYNC" "$UNIT_D/$TIMER" "$ALLOW_DIR" "$BIN"; do
    if [[ -e "$f" || -L "$f" ]]; then left="${left} ${f}"; fi
done
check "no unit, state dir or binary of the allowlist left" "" "$left"

finish
