#!/usr/bin/env bash
# =============================================================================
# tools/tests/sshd_dropin_test.sh -- firewall-setup.sh fw_sshd_harden: the
# sshd_config.d drop-in, its check with `sshd -t` and roll-back, the effective
# values read back with `sshd -T` (a 50-cloud-init.conf saying
# "PasswordAuthentication yes" loses to the 00- drop-in), and the warnings.
#
#   bash tools/tests/sshd_dropin_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/sshd_dropin_test.sh
#
# sshd and systemctl are PATH stubs (tools/tests/fwstub.sh); tn_write_root_file
# is replaced by a plain writer, since the fixture tree is not root-owned.
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
D="$TN_ROOT_PREFIX/etc/ssh/sshd_config.d"
mkdir -p "$D" "$TN_ROOT_PREFIX/etc/telcoin" "$T/fw"
fw_stub_install "$T/bin"
PATH="$T/bin:/usr/local/bin:/usr/bin:/bin"

grep -v '^main "\$@"$' "${TN_TEST_REPO}/firewall-setup.sh" > "$T/fw/firewall-setup.sh"
ln -s "${TN_TEST_REPO}/lib" "$T/fw/lib"
# shellcheck source=/dev/null
source "$T/fw/firewall-setup.sh"
set +e

WRITES="$T/writes"
tn_write_root_file() {
    printf '%s %s\n' "$1" "$2" >> "$WRITES"
    [[ -L "$1" || -d "$1" ]] && return 1
    cat > "$1"
}

F="$FW_SSHD_DROPIN"
printf 'Include /etc/ssh/sshd_config.d/*.conf\nPasswordAuthentication yes\nPermitRootLogin yes\n' > "$TN_ROOT_PREFIX/etc/ssh/sshd_config"
printf 'PasswordAuthentication yes\n' > "$D/50-cloud-init.conf"

check "drop-in path" "$D/00-telcoin-hardening.conf" "$F"
check "before: cloud-init wins" "yes" "$(get_ssh_password_auth)"

# --- fresh drop-in ---------------------------------------------------------------
: > "$SYSTEMCTL_LOG"
fw_sshd_harden "PasswordAuthentication no" "KbdInteractiveAuthentication no" >"$T/out" 2>&1; rc=$?
check_rc "harden password rc 0" 0 "$rc"
check_has "drop-in PasswordAuthentication" "PasswordAuthentication no" "$(cat "$F")"
check_has "drop-in KbdInteractiveAuthentication" "KbdInteractiveAuthentication no" "$(cat "$F")"
check_has "written 0644 through tn_write_root_file" "$F 0644" "$(cat "$WRITES")"
check "effective passwordauthentication" "no" "$(get_ssh_password_auth)"
check "effective kbdinteractive" "no" "$(fw_sshd_effective kbdinteractiveauthentication x)"
check_has "sshd reloaded" "reload ssh" "$(cat "$SYSTEMCTL_LOG")"
check "main sshd_config untouched" "Include /etc/ssh/sshd_config.d/*.conf
PasswordAuthentication yes
PermitRootLogin yes" "$(cat "$TN_ROOT_PREFIX/etc/ssh/sshd_config")"

# --- second directive merges -------------------------------------------------------
fw_sshd_harden "PermitRootLogin no" >"$T/out" 2>&1; rc=$?
check_rc "harden root rc 0" 0 "$rc"
check "drop-in keeps both" "2" "$(grep -c -E '^(PasswordAuthentication|KbdInteractiveAuthentication) no$' "$F")"
check_has "drop-in PermitRootLogin" "PermitRootLogin no" "$(cat "$F")"
check "PermitRootLogin once" "1" "$(grep -c '^PermitRootLogin' "$F")"
check "effective permitrootlogin" "no" "$(get_ssh_root_login)"
fw_sshd_harden "PermitRootLogin no" >/dev/null 2>&1
check "re-run keeps one PermitRootLogin" "1" "$(grep -c '^PermitRootLogin' "$F")"

# --- sshd -t fails: previous drop-in back, no reload ------------------------------------
prev="$(cat "$F")"
: > "$SYSTEMCTL_LOG"
SSHD_T_RC=1 fw_sshd_harden "PasswordAuthentication no" "X11Forwarding no" >"$T/out" 2>&1; rc=$?
check_rc "sshd -t failure rc 1" 1 "$rc"
check "sshd -t failure restores the drop-in" "$prev" "$(cat "$F")"
check "sshd -t failure does not reload" "" "$(cat "$SYSTEMCTL_LOG")"

rm -f "$F"
SSHD_T_RC=1 fw_sshd_harden "PermitRootLogin no" >"$T/out" 2>&1; rc=$?
check_rc "sshd -t failure on a fresh drop-in rc 1" 1 "$rc"
check "fresh drop-in removed on failure" "no" "$([[ -e "$F" ]] && echo yes || echo no)"

# --- no Include line: warned, rc 3 ---------------------------------------------------
printf 'PasswordAuthentication yes\n' > "$TN_ROOT_PREFIX/etc/ssh/sshd_config"
fw_sshd_harden "PasswordAuthentication no" >"$T/out" 2>&1; rc=$?
check_rc "no Include line rc 3" 3 "$rc"
check_has "no Include line warned" "yes" "$(grep -q 'has no .Include' "$T/out" && echo yes)"

# --- a symlinked drop-in is refused untouched -------------------------------------------
rm -f "$F"
printf 'canary\n' > "$T/canary"
ln -s "$T/canary" "$F"
fw_sshd_harden "PermitRootLogin no" >"$T/out" 2>&1; rc=$?
check_rc "symlink drop-in rc 1" 1 "$rc"
check "symlink target untouched" "canary" "$(cat "$T/canary")"

finish
