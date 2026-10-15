#!/usr/bin/env bash
# =============================================================================
# tools/tests/vpn_selfheal_test.sh -- setup-vpn.sh: the generated self-heal helper
# (self-contained, no path under the scripts directory or /home), the KEYS list
# (listed files only, fingerprint check, "# revoked:" lines), the local deny list,
# a key dropped from KEYS leaving the authorized file on the next run, the
# tnadmin drop-in (maintainer range, root-owned key file, sshd -t roll-back), the
# sudoers recovery list, and the testnet-only removal of the units.
#
#   bash tools/tests/vpn_selfheal_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/vpn_selfheal_test.sh
#
# sshd, ufw and systemctl are PATH stubs (tools/tests/fwstub.sh); getent, usermod,
# chage, visudo and journalctl are stubs written here; ssh-keygen is the real one
# when installed, else a stand-in that computes the same SHA256 fingerprint.
# tn_write_root_file and vpn_root_file_ok are replaced after their own refusal
# checks, since the fixture tree is not root-owned.
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
RP="$TN_ROOT_PREFIX"
mkdir -p "$RP/etc/telcoin" "$RP/etc/wgvpn" "$RP/etc/ssh/sshd_config.d" "$RP/etc/sudoers.d" \
         "$RP/etc/systemd/system" "$RP/usr/local/sbin" "$T/vpn" "$T/keys" "$TNADMIN_HOME/.ssh"
printf 'NETWORK=testnet\nRPC_PORT=8545\n' > "$RP/etc/telcoin/.node-meta"
printf 'Include /etc/ssh/sshd_config.d/*.conf\nPasswordAuthentication yes\n' > "$RP/etc/ssh/sshd_config"
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
: > "${TNADMIN_HOME}.exists"

KEYGEN_KIND="ssh-keygen"
if ! command -v ssh-keygen >/dev/null 2>&1; then
    KEYGEN_KIND="stand-in"
    cat > "$T/bin/ssh-keygen" <<'STUB'
#!/usr/bin/env bash
# `ssh-keygen -lf FILE|- [-E sha256]`: SHA256 of the decoded key blob, base64, no padding.
f=""
while [ $# -gt 0 ]; do
    case "$1" in
        -lf) f="$2"; shift 2 ;;
        -E) shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$f" ] || exit 1
[ "$f" = "-" ] && f=/dev/stdin
rc=1
while read -r type blob rest; do
    case "$type" in ssh-*|sk-*|ecdsa-*) ;; *) continue ;; esac
    hex="$(printf '%s' "$blob" | base64 -d 2>/dev/null | sha256sum | cut -c1-64)"
    [ "${#hex}" -eq 64 ] || exit 1
    esc="$(printf '%s' "$hex" | sed 's/../\\x&/g')"
    printf '256 SHA256:%s %s (TEST)\n' "$(printf "$esc" | base64 | tr -d '=\n')" "$rest"
    rc=0
done < "$f"
exit $rc
STUB
    chmod +x "$T/bin/ssh-keygen"
fi
PATH="$T/bin:/usr/local/bin:/usr/bin:/bin"
hash -r

# Two throwaway keys that are in no KEYS file.
K1='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIIhY+QN3xUF1P+H8TzN8kqhgQuysWpwjDQgDRUratH6 test-one'
F1='SHA256:L+UT7B+87ssscfNSScXlriL8Aygvn7D8dORpQ/Ixsjo'
K2='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIChDSWeeTBTLfQ+yocsy2/qHylWdG3n57T53bxvRL/8+ test-two'
F2='SHA256:7D+lNSlRdz6UIbMgaeSpqOyp76MmUsL9gIQN+Zr9hVs'

grep -v '^main "\$@"$' "${TN_TEST_REPO}/setup-vpn.sh" > "$T/vpn/setup-vpn.sh"
ln -s "${TN_TEST_REPO}/lib" "$T/vpn/lib"
# shellcheck source=/dev/null
source "$T/vpn/setup-vpn.sh"
set +e
vpn_init_paths
NETWORK=testnet
VPN_META="$RP/etc/telcoin/.node-meta"
printf 'ok    (fingerprints from %s)\n' "$KEYGEN_KIND"

# --- the helper as a node gets it: no prefix, real write primitives ---------------------
PROD="$( TN_ROOT_PREFIX=""; vpn_init_paths; VPN_META=/etc/telcoin/.node-meta; vpn_selfheal_script )"
# The helper text is large: grep it from a file (lib.sh check_has pipes it into
# `grep -q`, which can end the pipe early and fail under pipefail).
PRODF="$T/helper.prod"
printf '%s\n' "$PROD" > "$PRODF"
has_line() { grep -qxF -- "$1" "$PRODF" && echo yes; }
check "helper starts with #!/bin/bash" "#!/bin/bash" "${PROD%%$'\n'*}"
check "helper: grep -c source = 0" "0" "$(grep -c source "$PRODF")"
check "helper: no /home path" "0" "$(grep -c /home "$PRODF")"
check "helper: no dot command" "0" "$(grep -cE '^[[:space:]]*\.[[:space:]]' "$PRODF")"
check "helper: no scripts-directory path" "0" "$(grep -cF "${TN_TEST_REPO}/" "$PRODF")"
check "helper: setup-vpn.sh only in comments" "0" "$(grep -v '^#' "$PRODF" | grep -c 'setup-vpn')"
check "helper: fixed PATH" "yes" "$(has_line "PATH=/usr/sbin:/usr/bin:/sbin:/bin")"
check "helper: keys file" "yes" "$(has_line "TNV_KEYS=/etc/wgvpn/tnadmin.keys")"
check "helper: deny list" "yes" "$(has_line "TNV_REVOKED=/etc/wgvpn/tnadmin.revoked")"
check "helper: admin CIDR" "yes" "$(has_line "TNV_CIDR=${TN_OVERLAY_ADMIN_CIDR}")"
check "helper: node meta" "yes" "$(has_line "TNV_META=/etc/telcoin/.node-meta")"
check "helper embeds the root write primitive" "1" "$(grep -c '^tn_write_root_file ()' "$PRODF")"
bash -n "$PRODF" 2>/dev/null; check_rc "helper parses" 0 $?
SVC="$(vpn_selfheal_service_unit)"
check_has "unit ExecStart is the helper" "ExecStart=/usr/local/sbin/tn-vpn-selfheal" "$SVC"
check_lacks "unit does not run setup-vpn.sh" "setup-vpn.sh" "$SVC"
check_has "path unit watches the drop-in" "PathChanged=/etc/ssh/sshd_config.d/15-tnadmin-overlay.conf" "$(vpn_selfheal_path_unit)"
check "probe address" "10.100.9.1" "$(vpn_probe_addr 10.100.9.0/24)"

# --- vpn_root_file_ok refuses fixture files (not root-owned or in a writable tree) ------
printf '%s\n' "$K1" > "$T/notroot"
vpn_root_file_ok "$T/notroot"; check_rc "root_file_ok refuses a non-root tree" 1 $?
ln -s "$T/notroot" "$T/link"
vpn_root_file_ok "$T/link"; check_rc "root_file_ok refuses a symlink" 1 $?
vpn_root_file_ok "relative"; check_rc "root_file_ok refuses a relative path" 1 $?
printf 'SHA256:x\n' > "$RP/etc/wgvpn/tnadmin.revoked"
out="$(printf '%s\n' "$K1" | vpn_filter_keys "$TNV_REVOKED" 2>/dev/null)"; rc=$?
check_rc "filter refuses a deny list that is not root-owned" 1 "$rc"
check "filter prints nothing then" "" "$out"
rm -f "$RP/etc/wgvpn/tnadmin.revoked"

# From here on: plain writers for the fixture tree.
export WRITES="$T/writes"
: > "$WRITES"
tn_write_root_file() {
    printf '%s %s\n' "$1" "$2" >> "$WRITES"
    [[ -L "$1" || -d "$1" ]] && return 1
    cat > "$1"
}
vpn_root_file_ok() { [[ "${1:-}" == /* && -f "${1:-}" && ! -L "${1:-}" ]]; }

# --- KEYS list --------------------------------------------------------------------------
cp "${TN_TEST_REPO}"/lib/wgvpn/peers/ssh/*.pub "${TN_TEST_REPO}/lib/wgvpn/peers/ssh/KEYS" "$T/keys/"
VPN_KEYS_DIR="$T/keys"
REPO_N="$(grep -cE '^[A-Za-z0-9]' "$T/keys/KEYS")"
out="$(vpn_keys_from_list "$T/keys" 2>"$T/err")"; rc=$?
check_rc "repo KEYS verifies" 0 "$rc"
check "repo KEYS: every listed key" "$REPO_N" "$(printf '%s\n' "$out" | grep -c '^ssh-\|^sk-')"
check "repo KEYS: no warning" "" "$(cat "$T/err")"
printf '%s\n' "$K1" > "$T/keys/stranger.pub"
out="$(vpn_keys_from_list "$T/keys" 2>/dev/null)"
check_lacks "unlisted .pub ignored" "test-one" "$out"
printf 'extra %s\n' "$F1" >> "$T/keys/KEYS"
printf '%s\n' "$K1" > "$T/keys/extra.pub"
out="$(vpn_keys_from_list "$T/keys" 2>/dev/null)"
check_has "listed key with matching fingerprint used" "$K1" "$out"
printf '%s\n' "$K2" > "$T/keys/extra.pub"
out="$(vpn_keys_from_list "$T/keys" 2>"$T/err")"; rc=$?
check_rc "fingerprint mismatch skips only that key" 0 "$rc"
check_lacks "mismatched key not used" "test-two" "$out"
check_has "mismatch warned" "yes" "$(grep -q 'KEYS lists' "$T/err" && echo yes)"
printf '%s\n%s\n' "$K1" "$K2" > "$T/keys/extra.pub"
out="$(vpn_keys_from_list "$T/keys" 2>/dev/null)"
check_lacks "a .pub with two keys is skipped" "test-one" "$out"
printf '%s\n' "$K1" > "$T/keys/extra.pub"
printf '# revoked: %s extra 2026-10-15\n' "$F1" >> "$T/keys/KEYS"
out="$(vpn_keys_from_list "$T/keys" 2>/dev/null)"; rc=$?
check_rc "revoked line keeps the rest" 0 "$rc"
check_lacks "revoked fingerprint never used" "test-one" "$out"
cp "$T/keys/KEYS" "$T/KEYS.good"
printf 'broken-line\n' >> "$T/keys/KEYS"
out="$(vpn_keys_from_list "$T/keys" 2>/dev/null)"; rc=$?
check_rc "malformed KEYS line refuses" 1 "$rc"
check "malformed KEYS prints nothing" "" "$out"
cp "$T/KEYS.good" "$T/keys/KEYS"
printf 'grant %s\n' "$F2" >> "$T/keys/KEYS"
vpn_keys_from_list "$T/keys" >/dev/null 2>&1; check_rc "duplicated name refuses" 1 $?
printf 'only %s\n' "$F2" > "$T/keys/KEYS"
vpn_keys_from_list "$T/keys" >/dev/null 2>&1; check_rc "no usable key refuses" 1 $?
rm -f "$T/keys/KEYS"
vpn_keys_from_list "$T/keys" >/dev/null 2>&1; check_rc "missing KEYS refuses" 1 $?
cp "$T/KEYS.good" "$T/keys/KEYS"

# --- local deny list ----------------------------------------------------------------------
out="$(printf '%s\n%s\n' "$K1" "$K2" | vpn_filter_keys "$TNV_REVOKED")"
check "no deny list keeps every key" "$K1
$K2" "$out"
printf '# blocked here\n%s  # test-two\n' "$F2" > "$TNV_REVOKED"
out="$(printf '%s\n# comment\n\nnot a key\n%s\n' "$K1" "$K2" | vpn_filter_keys "$TNV_REVOKED" 2>/dev/null)"
check "deny list drops the key, comments and junk" "$K1" "$out"
rm -f "$TNV_REVOKED"
out="$(printf 'not a key\nalso not\n' | vpn_filter_keys "$TNV_REVOKED" 2>/dev/null)"; rc=$?
check_rc "filter refuses when no line can be fingerprinted" 1 "$rc"

# --- assemble + write: listed keys in, local revocation out, removal on re-run -------------
printf 'two %s\n' "$F2" >> "$T/keys/KEYS"
printf '%s\n' "$K2" > "$T/keys/two.pub"
assemble_pubkeys 2>/dev/null
check_has "assembled set has the new key" "$K2" "$TNADMIN_PUBKEYS"
write_tnadmin_keys >"$T/out" 2>&1; check_rc "write_tnadmin_keys rc 0" 0 $?
check_has "tnadmin.keys has the key" "$K2" "$(cat "$TNV_KEYS")"
check_has "authorized file has the key" "$K2" "$(cat "$TNV_AUTH")"
check_has "authorized file written 0644" "$TNV_AUTH 0644" "$(cat "$WRITES")"
check_has "keys file written 0644" "$TNV_KEYS 0644" "$(cat "$WRITES")"
printf '%s\n' "$F2" > "$TNV_REVOKED"
assemble_pubkeys 2>/dev/null
write_tnadmin_keys >"$T/out" 2>&1
check_has "local revocation: tnadmin.keys still lists it" "$K2" "$(cat "$TNV_KEYS")"
check_lacks "local revocation: not authorized" "test-two" "$(cat "$TNV_AUTH")"
rm -f "$TNV_REVOKED"
assemble_pubkeys 2>/dev/null; write_tnadmin_keys >/dev/null 2>&1
check_has "deny line removed: key back" "$K2" "$(cat "$TNV_AUTH")"
: > "$WRITES"
write_tnadmin_keys >"$T/out" 2>&1
check "unchanged set: nothing rewritten" "" "$(cat "$WRITES")"
cp "$T/KEYS.good" "$T/keys/KEYS"
assemble_pubkeys 2>/dev/null; write_tnadmin_keys >/dev/null 2>&1
check_lacks "key dropped from KEYS: gone on the next run" "test-two" "$(cat "$TNV_AUTH")"
check_lacks "key dropped from KEYS: gone from tnadmin.keys" "test-two" "$(cat "$TNV_KEYS")"
check "authorized count = KEYS count" "$REPO_N" "$(grep -c . "$TNV_AUTH")"

# --- drop-in ------------------------------------------------------------------------------
: > "$SYSTEMCTL_LOG"
write_scoped_sshd >"$T/out" 2>&1; check_rc "drop-in rc 0" 0 $?
D="$(cat "$TNV_DROPIN")"
check_has "drop-in: maintainer range" "Match Address ${TN_OVERLAY_ADMIN_CIDR}" "$D"
check_has "drop-in: only tnadmin from it" "    AllowUsers tnadmin" "$D"
check_has "drop-in: tnadmin block" "Match User tnadmin Address ${TN_OVERLAY_ADMIN_CIDR}" "$D"
check_has "drop-in: root-owned key file" "    AuthorizedKeysFile /etc/wgvpn/tnadmin.authorized_keys" "$D"
check_lacks "drop-in: not the whole overlay" "$TN_OVERLAY_CIDR" "$D"
check_has "drop-in reloads sshd" "reload ssh" "$(cat "$SYSTEMCTL_LOG")"
: > "$WRITES"
write_scoped_sshd >"$T/out" 2>&1
check "drop-in unchanged: not rewritten" "" "$(cat "$WRITES")"
printf 'old drop-in\n' > "$TNV_DROPIN"
SSHD_T_RC=1 vpn_sshd_apply >/dev/null 2>&1; check_rc "sshd -t failure rc 1" 1 $?
check "sshd -t failure restores the old drop-in" "old drop-in" "$(cat "$TNV_DROPIN")"
rm -f "$TNV_DROPIN"
SSHD_T_RC=1 vpn_sshd_apply >/dev/null 2>&1
check "sshd -t failure on a fresh drop-in removes it" "no" "$([[ -e "$TNV_DROPIN" ]] && echo yes || echo no)"
printf '%s\n' "$K1" > "$TNADMIN_HOME/.ssh/authorized_keys.tnvpn"
vpn_reassert sshd >/dev/null 2>&1
check "old per-user key file removed once the drop-in moved" "no" "$([[ -e "$TNADMIN_HOME/.ssh/authorized_keys.tnvpn" ]] && echo yes || echo no)"

# --- sudoers --------------------------------------------------------------------------------
write_tnadmin_sudoers false >"$T/out" 2>&1; check_rc "recovery sudoers rc 0" 0 $?
S="$(cat "$RP/etc/sudoers.d/90-tnadmin")"
check_has "sudoers: recovery rule" "tnadmin ALL=(root) NOPASSWD: TN_RECOVERY" "$S"
check_lacks "sudoers: no full root" "NOPASSWD:ALL" "$S"
check_has "sudoers: status without a pager" "yes" "$(grep -q 'systemctl status --no-pager telcoin' <<<"$S" && echo yes)"
check_has "sudoers: journal without a pager" "yes" "$(grep -q 'journalctl --no-pager -u telcoin -n 200' <<<"$S" && echo yes)"
check_lacks "sudoers: check-node.sh only from a root-owned tree" "check-node.sh" "$S"
check_has "sudoers written 0440" "$RP/etc/sudoers.d/90-tnadmin 0440" "$(cat "$WRITES")"
write_tnadmin_sudoers true >"$T/out" 2>&1
check_has "granted sudoers: full root" "tnadmin ALL=(ALL) NOPASSWD:ALL" "$(cat "$RP/etc/sudoers.d/90-tnadmin")"
VISUDO_RC=1 write_tnadmin_sudoers false >"$T/out" 2>&1; check_rc "visudo failure rc 1" 1 $?
check "visudo failure removes the file (no sudo, not full root)" "no" "$([[ -e "$RP/etc/sudoers.d/90-tnadmin" ]] && echo yes || echo no)"
ROOT_GRANT=""
printf 'VPN_MAINTAINER_ROOT=true\n' >> "$VPN_META"
check "grant read from .node-meta" "true" "$(vpn_root_grant_wanted)"
ROOT_GRANT=revoke
check "revoke flag wins" "false" "$(vpn_root_grant_wanted)"
ROOT_GRANT=""
printf 'VPN_MAINTAINER_ROOT=false\n' >> "$VPN_META"
vpn_root_grant_wanted >/dev/null 2>&1; check_rc "duplicated VPN_MAINTAINER_ROOT stops" 1 $?
grep -v '^VPN_MAINTAINER_ROOT=' "$VPN_META" > "$T/meta" && cat "$T/meta" > "$VPN_META"

# --- bootstrap guard ----------------------------------------------------------------------------
vpn_tnadmin_home_safe 2>/dev/null; check_rc "home safe" 0 $?
mv "$TNADMIN_HOME/.ssh" "$T/realssh"; ln -s "$T/realssh" "$TNADMIN_HOME/.ssh"
vpn_tnadmin_home_safe >/dev/null 2>&1; check_rc "symlinked ~tnadmin/.ssh refuses the bootstrap" 1 $?
rm -f "$TNADMIN_HOME/.ssh"; mv "$T/realssh" "$TNADMIN_HOME/.ssh"

# --- the generated helper, run in the fixture tree ---------------------------------------------
: > "$WRITES"
install_selfheal_units >"$T/out" 2>&1; check_rc "install_selfheal_units rc 0" 0 $?
check_has "helper written 0755" "$TNV_SELF 0755" "$(cat "$WRITES")"
check_has "service unit written" "$TNV_SERVICE_UNIT 0644" "$(cat "$WRITES")"
check_has "path unit enabled" "enable --now tn-vpn-selfheal.path" "$(cat "$SYSTEMCTL_LOG")"
# Run the helper with the test stubs ahead of its fixed PATH.
sed "s|^PATH=/usr/sbin:/usr/bin:/sbin:/bin\$|PATH=$T/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin|" "$TNV_SELF" > "$T/helper"
check "helper has the expected PATH line" "1" "$(grep -c "^PATH=$T/bin:" "$T/helper")"
printf 'two %s\n' "$F2" >> "$T/keys/KEYS"
assemble_pubkeys 2>/dev/null; install_keys_file
bash "$T/helper" --keys >"$T/out" 2>&1; check_rc "helper --keys rc 0" 0 $?
check_has "helper installs the new key" "$K2" "$(cat "$TNV_AUTH")"
printf '%s\n' "$F2" > "$TNV_REVOKED"
bash "$T/helper" --keys >"$T/out" 2>&1
check_lacks "helper honours the local deny list" "test-two" "$(cat "$TNV_AUTH")"
rm -f "$TNV_REVOKED"
cp "$T/KEYS.good" "$T/keys/KEYS"
assemble_pubkeys 2>/dev/null; install_keys_file
bash "$T/helper" --keys >"$T/out" 2>&1
check_lacks "helper: key dropped from KEYS is gone" "test-two" "$(cat "$TNV_AUTH")"
rm -f "$TNV_DROPIN"; : > "$ACCT_LOG"
bash "$T/helper" >"$T/out" 2>&1; check_rc "helper full run rc 0" 0 $?
check_has "helper rewrote the drop-in" "Match Address ${TN_OVERLAY_ADMIN_CIDR}" "$(cat "$TNV_DROPIN")"
check_has "helper fixed the tnadmin login" "usermod -p * tnadmin" "$(cat "$ACCT_LOG")"
bash "$T/helper" --bogus >/dev/null 2>&1; check_rc "helper refuses an unknown flag" 2 $?
printf 'NETWORK=testnet\n' >> "$VPN_META"
bash "$T/helper" >"$T/out" 2>&1; check_rc "helper: duplicated NETWORK rc 1" 1 $?
check "helper: duplicated NETWORK keeps the units" "yes" "$([[ -f "$TNV_SERVICE_UNIT" ]] && echo yes)"
printf 'NETWORK=mainnet\nRPC_PORT=8545\n' > "$VPN_META"
: > "$SYSTEMCTL_LOG"
bash "$T/helper" >"$T/out" 2>&1; check_rc "helper off testnet rc 0" 0 $?
check "helper off testnet removes the service unit" "no" "$([[ -e "$TNV_SERVICE_UNIT" ]] && echo yes || echo no)"
check "helper off testnet removes the path unit" "no" "$([[ -e "$TNV_PATH_UNIT" ]] && echo yes || echo no)"
check "helper off testnet removes itself" "no" "$([[ -e "$TNV_SELF" ]] && echo yes || echo no)"
check_has "helper never stops its own service" "disable tn-vpn-selfheal.service" "$(cat "$SYSTEMCTL_LOG")"
check_lacks "helper leaves the keys alone off testnet" "Wrote" "$(cat "$T/out")"

# --- do_selfheal off testnet (an older unit running setup-vpn.sh) ------------------------------
printf 'NETWORK=testnet\n' > "$VPN_META"
install_selfheal_units >/dev/null 2>&1
NETWORK=mainnet
do_selfheal >"$T/out" 2>&1; check_rc "do_selfheal off testnet rc 0" 0 $?
check "do_selfheal off testnet removes the units" "no" "$([[ -e "$TNV_SERVICE_UNIT" || -e "$TNV_SELF" ]] && echo yes || echo no)"
NETWORK=testnet

# --- whole verbs under set -e (no early exit from an unguarded failure) ----------------------
printf 'NETWORK=testnet\n' > "$VPN_META"
( set -e; do_sync_keys ) >"$T/out" 2>&1; check_rc "do_sync_keys under set -e rc 0" 0 $?
check_has "sync-keys installed the helper" "yes" "$([[ -f "$TNV_SELF" ]] && echo yes)"
check_has "sync-keys narrowed sudo" "tnadmin ALL=(root) NOPASSWD: TN_RECOVERY" "$(cat "$RP/etc/sudoers.d/90-tnadmin")"
# A grant writes .node-meta, so it first migrates an old ownership layout; here the
# migration refuses (the fixture service user does not exist) and nothing is written.
( set -e; ROOT_GRANT=grant; do_sync_keys ) >"$T/out" 2>&1; check_rc "grant on an old layout that cannot migrate rc 1" 1 $?
check_lacks "old layout: grant not recorded" "VPN_MAINTAINER_ROOT" "$(cat "$VPN_META")"
check_lacks "old layout: sudo not widened" "NOPASSWD:ALL" "$(cat "$RP/etc/sudoers.d/90-tnadmin")"
check "old layout: migration refusal named" "yes" "$(grep -q 'ownership migration stopped' "$T/out" && echo yes)"
printf 'OWNERSHIP_LAYOUT=2\n' >> "$VPN_META"
( set -e; ROOT_GRANT=grant; do_sync_keys ) >"$T/out" 2>&1; check_rc "sync-keys --grant-maintainer-root rc 0" 0 $?
check_has "grant recorded in .node-meta" "VPN_MAINTAINER_ROOT=true" "$(cat "$VPN_META")"
check_has "grant wrote full root" "tnadmin ALL=(ALL) NOPASSWD:ALL" "$(cat "$RP/etc/sudoers.d/90-tnadmin")"
( set -e; do_sync_keys ) >"$T/out" 2>&1
check_has "grant kept without a flag" "tnadmin ALL=(ALL) NOPASSWD:ALL" "$(cat "$RP/etc/sudoers.d/90-tnadmin")"
( set -e; ROOT_GRANT=revoke; do_sync_keys ) >"$T/out" 2>&1
check_has "revoke recorded" "VPN_MAINTAINER_ROOT=false" "$(cat "$VPN_META")"
check_lacks "revoke dropped full root" "NOPASSWD:ALL" "$(cat "$RP/etc/sudoers.d/90-tnadmin")"
( set -e; do_status ) >"$T/out" 2>&1; check_rc "do_status under set -e rc 0" 0 $?
check_has "status reports the helper" "yes" "$(grep -q 'Self-heal runs the root-owned' "$T/out" && echo yes)"
( set -e; NETWORK=mainnet; do_selfheal ) >"$T/out" 2>&1; check_rc "do_selfheal off testnet under set -e" 0 $?

# --- remove-node.sh tears the self-heal down before the drop-in it watches ---------------------
RN="${TN_TEST_REPO}/remove-node.sh"
sh_line="$(grep -n 'systemctl disable --now tn-vpn-selfheal.path tn-vpn-selfheal.service' "$RN" | head -1 | cut -d: -f1)"
dropin_line="$(grep -n 'rm -f /etc/ssh/sshd_config.d/15-tnadmin-overlay.conf' "$RN" | head -1 | cut -d: -f1)"
check "remove-node: self-heal stopped before the drop-in goes" "yes" \
    "$([[ -n "$sh_line" && -n "$dropin_line" && "$sh_line" -lt "$dropin_line" ]] && echo yes)"
check "remove-node: key files removed" "yes" \
    "$(grep -q 'rm -f /etc/wgvpn/tnadmin.keys /etc/wgvpn/tnadmin.revoked /etc/wgvpn/tnadmin.authorized_keys' "$RN" && echo yes)"
check "remove-node: admin range rule deleted" "yes" \
    "$(grep -q 'for cidr in "\${TN_OVERLAY_ADMIN_CIDR:-}" "\${TN_OVERLAY_CIDR:-}"' "$RN" && echo yes)"

# --- verb gating --------------------------------------------------------------------------------
( parse_args --status --grant-maintainer-root ) >/dev/null 2>&1; check_rc "grant flag refused with --status" 1 $?
( MODE=enable; ROOT_GRANT=""; parse_args --sync-keys --grant-maintainer-root; printf '%s %s\n' "$MODE" "$ROOT_GRANT" ) > "$T/out" 2>&1
check "grant flag with --sync-keys" "sync-keys grant" "$(tail -n 1 "$T/out")"
( NETWORK=mainnet; require_testnet ) >/dev/null 2>&1; check_rc "mainnet refuses the enabling verbs" 1 $?

finish
