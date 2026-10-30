#!/usr/bin/env bash
# =============================================================================
# tools/tests/vpn_enable_test.sh -- setup-vpn.sh run_bootstrap: the tnadmin sudo
# rule the operator agreed to is in /etc/sudoers.d/90-tnadmin before the WireGuard
# bootstrap runs, the bootstrap is told not to write that file (WG_NODE_SUDOERS=0),
# and the rule is written again afterwards only when the file no longer matches
# (vpn_sudoers_current). Also checks the WG_NODE_SUDOERS guard and the 14-line
# provenance header of the real vendored lib/wgvpn/wg-node-bootstrap.sh.
#
#   bash tools/tests/vpn_enable_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/vpn_enable_test.sh
#
# WGVPN_DIR is readonly and follows SCRIPT_DIR, so the test builds its own lib/:
# every entry of the repo's lib/ is linked in except wgvpn/, which holds a copy of
# hub-coordinates.env, a link to peers/ and a STUB wg-node-bootstrap.sh. The stub
# logs the WG_* inputs it got, snapshots the sudoers file as it finds it, notes
# whether tnadmin existed, then "creates" the account. It writes NOPASSWD:ALL
# when WG_NODE_SUDOERS is 1 (the upstream default) or BOOT_OLD=1 (a vendored copy
# without the guard). BOOT_NO_PUBKEY=1 makes it fail without a WG_NODE_PUBKEY line.
# getent, usermod, chage, visudo (exit $VISUDO_RC) and journalctl are stubs as in
# vpn_selfheal_test.sh; tn_write_root_file is a logger that writes stdin to the
# destination. Not updater-tracked. bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tools/tests/fwstub.sh
. "${TN_TEST_DIR}/fwstub.sh"
T="$TN_TEST_TMP"
export TN_ROOT_PREFIX="$T/root"
export UFW_LOG="$T/ufw.log"
export SYSTEMCTL_LOG="$T/systemctl.log"
export ACCT_LOG="$T/acct.log"
export TN_UPDATE_LOCK_FILE="$T/update.lock"
export TNADMIN_HOME="$T/home/tnadmin"
export BOOT_ENV_LOG="$T/boot.env"
export BOOT_SNAP="$T/boot.snap"
export BOOT_USER_EXISTED="$T/boot.user"
export ROOT_WRITE_LOG="$T/root-writes"
export ROOT_WRITE_BODY="$T/root-write-bodies"
RP="$TN_ROOT_PREFIX"
SUD="$RP/etc/sudoers.d/90-tnadmin"
mkdir -p "$RP/etc/telcoin" "$RP/etc/wgvpn" "$RP/etc/ssh/sshd_config.d" "$RP/etc/sudoers.d" \
         "$T/vpn/lib/wgvpn" "$TNADMIN_HOME/.ssh"
printf 'NETWORK=testnet\nRPC_PORT=8545\n' > "$RP/etc/telcoin/.node-meta"
: > "$SYSTEMCTL_LOG"
: > "$ACCT_LOG"
fw_stub_install "$T/bin"

cat > "$T/bin/getent" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
    "passwd tnadmin") [ -e "${TNADMIN_HOME}.exists" ] || exit 2
                      echo "tnadmin:x:1001:1001::${TNADMIN_HOME}:/bin/bash" ;;
    "shadow tnadmin") echo "tnadmin:*:19000:0:99999:7:::" ;;
    *) exit 2 ;;
esac
STUB
for t in usermod chage; do
    printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "%s" "$*" >> "${ACCT_LOG:?}"\n' "$t" > "$T/bin/$t"
done
printf '#!/usr/bin/env bash\nexit "${VISUDO_RC:-0}"\n' > "$T/bin/visudo"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/journalctl"
chmod +x "$T/bin/getent" "$T/bin/usermod" "$T/bin/chage" "$T/bin/visudo" "$T/bin/journalctl"
PATH="$T/bin:/usr/local/bin:/usr/bin:/bin"
hash -r

# --- fixture scripts directory: setup-vpn.sh, lib/ links, a stub bootstrap -----------------
grep -v '^main "\$@"$' "${TN_TEST_REPO}/setup-vpn.sh" > "$T/vpn/setup-vpn.sh"
for e in "${TN_TEST_REPO}"/lib/*; do
    [ "${e##*/}" = wgvpn ] && continue
    ln -s "$e" "$T/vpn/lib/${e##*/}"
done
cp "${TN_TEST_REPO}/lib/wgvpn/hub-coordinates.env" "$T/vpn/lib/wgvpn/"
ln -s "${TN_TEST_REPO}/lib/wgvpn/peers" "$T/vpn/lib/wgvpn/peers"
cat > "$T/vpn/lib/wgvpn/wg-node-bootstrap.sh" <<'BOOT'
#!/usr/bin/env bash
# Stand-in for the vendored bootstrap (vpn_enable_test.sh).
env | grep '^WG_' | sort >> "${BOOT_ENV_LOG:?}"
s="${TN_ROOT_PREFIX:?}/etc/sudoers.d/90-tnadmin"
if [ -e "$s" ]; then cp "$s" "${BOOT_SNAP:?}"; else echo ABSENT > "${BOOT_SNAP:?}"; fi
if getent passwd tnadmin >/dev/null 2>&1; then
    echo yes > "${BOOT_USER_EXISTED:?}"
else
    echo no > "${BOOT_USER_EXISTED:?}"
fi
: > "${TNADMIN_HOME:?}.exists"
if [ "${BOOT_OLD:-0}" = 1 ] || [ "${WG_NODE_SUDOERS:-1}" = 1 ]; then
    echo "tnadmin ALL=(ALL) NOPASSWD:ALL" > "$s"
fi
[ "${BOOT_NO_PUBKEY:-0}" = 1 ] && exit 1
echo "WG_NODE_PUBKEY=fixturepub="
BOOT
chmod +x "$T/vpn/lib/wgvpn/wg-node-bootstrap.sh"

# shellcheck source=/dev/null
source "$T/vpn/setup-vpn.sh"
set +e
vpn_init_paths
NETWORK=testnet
VPN_META="$RP/etc/telcoin/.node-meta"
OVERLAY_IP="10.100.20.7"
# Two throwaway keys that are in no KEYS file.
TNADMIN_INSTALL='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIIhY+QN3xUF1P+H8TzN8kqhgQuysWpwjDQgDRUratH6 test-one
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIChDSWeeTBTLfQ+yocsy2/qHylWdG3n57T53bxvRL/8+ test-two'

# The fixture tree is not root-owned: log each root write and its content, then write it.
tn_write_root_file() {
    printf '%s %s\n' "$1" "$2" >> "$ROOT_WRITE_LOG"
    [[ -L "$1" || -d "$1" ]] && return 1
    tee -a "$ROOT_WRITE_BODY" > "$1"
}

# reset_case -- no sudoers file, no tnadmin account, empty logs.
reset_case() {
    rm -f "$SUD" "${TNADMIN_HOME}.exists" "$BOOT_SNAP" "$BOOT_USER_EXISTED"
    : > "$BOOT_ENV_LOG"
    : > "$ROOT_WRITE_LOG"
    : > "$ROOT_WRITE_BODY"
}

# yes_no CMD... -- "yes" when CMD succeeds, else "no".
yes_no() { if "$@"; then echo yes; else echo no; fi; }
writes_of_sudoers() { grep -c "^${SUD} " "$ROOT_WRITE_LOG"; }
out_has() { grep -q -- "$1" "$T/out"; }
final_text() { if [[ -e "$SUD" ]]; then cat "$SUD"; else echo ABSENT; fi; }

LIMITED="$(vpn_sudoers_text false)"
FULL="$(vpn_sudoers_text true)"

# --- root=false, healthy bootstrap ------------------------------------------------------------
reset_case
( run_bootstrap false ) >"$T/out" 2>&1; rc=$?
check_rc "enable: rc 0" 0 "$rc"
SNAP="$(cat "$BOOT_SNAP")"
check "limited rule present when the bootstrap runs" "yes" \
    "$(yes_no grep -q 'TN_RECOVERY' "$BOOT_SNAP")"
check_lacks "limited rule present when the bootstrap runs: no full root" "NOPASSWD:ALL" "$SNAP"
check "tnadmin did not exist yet when the rule was written" "no ABSENT=no" \
    "$(cat "$BOOT_USER_EXISTED") ABSENT=$([[ "$SNAP" == ABSENT ]] && echo yes || echo no)"
ENVL="$(cat "$BOOT_ENV_LOG")"
check_has "bootstrap got WG_NODE_SUDOERS=0" "WG_NODE_SUDOERS=0" "$ENVL"
check_has "bootstrap got WG_NODE_SSHD_HARDEN=0" "WG_NODE_SSHD_HARDEN=0" "$ENVL"
check_has "bootstrap got WG_NODE_ENFORCE=0" "WG_NODE_ENFORCE=0" "$ENVL"
check_has "bootstrap got WG_NODE_PUBLIC_SSH=1" "WG_NODE_PUBLIC_SSH=1" "$ENVL"
check_lacks "no NOPASSWD:ALL at any point: snapshot" "NOPASSWD:ALL" "$SNAP"
check_lacks "no NOPASSWD:ALL at any point: root writes" "NOPASSWD:ALL" "$(cat "$ROOT_WRITE_BODY")"
check_lacks "no NOPASSWD:ALL at any point: final file" "NOPASSWD:ALL" "$(final_text)"
check "no NOPASSWD:ALL at any point: final file is the limited rule" "$LIMITED" "$(final_text)"
check "rules written once" "1" "$(writes_of_sudoers)"
check "rules written 0440" "$SUD 0440" "$(cat "$ROOT_WRITE_LOG")"
check "healthy bootstrap: no rewrite warning" "no" "$(yes_no out_has 'bootstrap changed')"
check "healthy bootstrap: pubkey reported" "yes" "$(yes_no out_has 'Node pubkey: fixturepub=')"

# --- root=true: full root was granted, so it is in place before the bootstrap ---------------
reset_case
( run_bootstrap true ) >"$T/out" 2>&1; rc=$?
check_rc "granted: rc 0" 0 "$rc"
check "granted: full root before the bootstrap" "yes" "$(yes_no grep -q 'NOPASSWD:ALL' "$BOOT_SNAP")"
check "granted: final file is the full-root rule" "$FULL" "$(final_text)"
check "granted: written once" "1" "$(writes_of_sudoers)"
check "granted: no rewrite warning" "no" "$(yes_no out_has 'bootstrap changed')"

# --- the bootstrap fails: the limited rule stays ---------------------------------------------
reset_case
export BOOT_NO_PUBKEY=1
( run_bootstrap false ) >"$T/out" 2>&1; rc=$?
unset BOOT_NO_PUBKEY
check_rc "no pubkey: rc 1" 1 "$rc"
check "no pubkey: says so" "yes" "$(yes_no out_has 'did not report a WG_NODE_PUBKEY')"
check "no pubkey: limited rule left in place" "$LIMITED" "$(final_text)"

# --- an older vendored copy without the guard writes full root: put the rule back -----------
reset_case
export BOOT_OLD=1
( run_bootstrap false ) >"$T/out" 2>&1; rc=$?
unset BOOT_OLD
check_rc "old bootstrap: rc 0" 0 "$rc"
check "old bootstrap: final file is the limited rule" "$LIMITED" "$(final_text)"
check "old bootstrap: warns that the bootstrap changed it" "yes" "$(yes_no out_has 'bootstrap changed')"
check "old bootstrap: rules written twice" "2" "$(writes_of_sudoers)"

# --- visudo refuses the rule: no sudo at all, never full root ---------------------------------
reset_case
export VISUDO_RC=1
( run_bootstrap false ) >"$T/out" 2>&1; rc=$?
unset VISUDO_RC
check_rc "visudo refuses: the bootstrap still runs (rc 0)" 0 "$rc"
check "visudo refuses: no file when the bootstrap runs" "ABSENT" "$(cat "$BOOT_SNAP")"
check "visudo refuses: no file afterwards" "ABSENT" "$(final_text)"
check "visudo refuses: says tnadmin has no sudo" "yes" "$(yes_no out_has 'no sudo')"

# --- vpn_sudoers_current -------------------------------------------------------------------
reset_case
printf '%s\n' "$LIMITED" > "$SUD"
vpn_sudoers_current false; check_rc "current: limited file matches false" 0 $?
vpn_sudoers_current true; check_rc "current: limited file does not match true" 1 $?
printf 'x' >> "$SUD"
vpn_sudoers_current false; check_rc "current: one byte appended" 1 $?
printf '%s\n' "$LIMITED" > "$T/real-sudoers"
rm -f "$SUD"
ln -s "$T/real-sudoers" "$SUD"
vpn_sudoers_current false; check_rc "current: a symlink to a matching file" 1 $?
rm -f "$SUD"
vpn_sudoers_current false; check_rc "current: missing file" 1 $?

# --- the real vendored bootstrap and the call in setup-vpn.sh ----------------------------------
VB="${TN_TEST_REPO}/lib/wgvpn/wg-node-bootstrap.sh"
check "vendored: the full-root write sits inside the WG_NODE_SUDOERS guard" \
    'if [ "${WG_NODE_SUDOERS}" = "1" ]; then' \
    "$(awk '/NOPASSWD:ALL/ && /tee/ { print prev; exit } { prev = $0 }' "$VB")"
check "vendored: WG_NODE_SUDOERS defaults to 1 exactly once" "1" \
    "$(grep -cF 'WG_NODE_SUDOERS="${WG_NODE_SUDOERS:-1}"' "$VB")"
check "vendored header: line 2 is a comment" "yes" "$(sed -n 2p "$VB" | grep -q '^#' && echo yes || echo no)"
check "vendored header: line 15 closes it" "yes" "$(sed -n 15p "$VB" | grep -q '^# =====' && echo yes || echo no)"
check "vendored header: line 16 is the upstream body" "#" "$(sed -n 16p "$VB")"
check "vendored header: stripping lines 2-15 leaves the upstream start" \
    "$(printf '#!/bin/bash\n#\n# wg-node-bootstrap.sh')" \
    "$(sed '2,15d' "$VB" | head -n 3 | cut -c1-22)"
# Portable SHA-256 of stdin (hash only): GNU sha256sum on Linux, shasum -a 256 on macOS.
body_sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -c1-64; }
check "vendored header: the recorded sha is the body's" \
    "$(sed '2,15d' "$VB" | body_sha)" \
    "$(sed -n 's/^#   upstream sha256: \([0-9a-f]\{64\}\)$/\1/p' "$VB")"
check "setup-vpn.sh passes WG_NODE_SUDOERS=0" "1" \
    "$(grep -cF 'WG_NODE_SUDOERS=0 \' "${TN_TEST_REPO}/setup-vpn.sh")"

finish
