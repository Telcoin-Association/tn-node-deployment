#!/usr/bin/env bash
# =============================================================================
# tools/tests/vm.d/P0-16.sh -- SSH sources and sshd hardening
# (assertions 27 and 28)
#
# A firewall reset with --ssh-from leaves no SSH-from-anywhere rule and ufw
# active. With PasswordAuthentication yes in a cloud-init drop-in, the SSH
# menu's options 1 (disable password authentication) and 2 (disable root
# login) leave sshd's effective settings PasswordAuthentication no and
# PermitRootLogin no. At the end ufw is turned off again and the two sshd
# drop-ins are put back as they were, so the runner stays usable.
# =============================================================================

set -u
# shellcheck source=tools/tests/vm.d/vm_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/vm_lib.sh"

fw="$VM_REPO/firewall-setup.sh"
if ! grep -q -- '--ssh-from' "$fw" || ! grep -q '00-telcoin-hardening.conf' "$fw"; then
    skip "SSH sources and sshd drop-in" "firewall-setup.sh has no --ssh-from / sshd drop-in yet"
    finish
fi
for tool in ufw sshd; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        skip "SSH sources and sshd drop-in" "$tool not installed on this VM"
        finish
    fi
done

d=/etc/ssh/sshd_config.d
dropins=(50-cloud-init.conf 00-telcoin-hardening.conf)
mkdir -p "$d"
for f in "${dropins[@]}"; do
    if [[ -e "$d/$f" ]]; then cp -p "$d/$f" "$TN_TEST_TMP/$f.saved"; fi
done
# sshd -t and -T need the privilege separation dir, which ssh.service creates
# when it starts; a runner that has not started sshd yet has none.
[[ -d /run/sshd ]] || install -d -m 0755 /run/sshd

restore() {
    local f
    ufw --force disable >/dev/null 2>&1 || true
    for f in "${dropins[@]}"; do
        if [[ -e "$TN_TEST_TMP/$f.saved" ]]; then
            cp -p "$TN_TEST_TMP/$f.saved" "$d/$f"
        else
            rm -f "$d/$f"
        fi
    done
    systemctl reload ssh >/dev/null 2>&1 || true
}

printf 'PasswordAuthentication yes\n' > "$d/50-cloud-init.conf"
rm -f "$d/00-telcoin-hardening.conf"

out="$(timeout 600 bash "$fw" --reset --ssh-from 203.0.113.0/24 < /dev/null 2>&1)"
check_rc "firewall-setup.sh --reset --ssh-from" 0 "$?" || printf '%s\n' "$out" | tail -n 40 | sed 's/^/    /'
check "27: no SSH rule open to anywhere" "" "$(ufw status | grep -E '^22/tcp( \(v6\))? +ALLOW +Anywhere')"
check "27: ufw active" "Status: active" "$(ufw status | head -n 1)"

# The SSH menu (manage_ssh) applies the hardening through fw_sshd_harden:
# option 1 with PasswordAuthentication and KbdInteractiveAuthentication no,
# option 2 with PermitRootLogin no. Call it the same way from a copy of the
# script without its last line (main "$@"), next to the repository's lib/.
mkdir -p "$TN_TEST_TMP/fw"
grep -v '^main "\$@"$' "$fw" > "$TN_TEST_TMP/fw/firewall-setup.sh"
ln -s "$VM_REPO/lib" "$TN_TEST_TMP/fw/lib"
harden() {
    # shellcheck disable=SC2016  # expanded by the child shell
    bash -c '. "$1"; shift; fw_sshd_harden "$@"' fw "$TN_TEST_TMP/fw/firewall-setup.sh" "$@" < /dev/null
}
out="$(harden "PasswordAuthentication no" "KbdInteractiveAuthentication no" 2>&1)"
check_rc "28: SSH menu option 1 applied" 0 "$?" || printf '%s\n' "$out" | sed 's/^/    /'
out="$(harden "PermitRootLogin no" 2>&1)"
check_rc "28: SSH menu option 2 applied" 0 "$?" || printf '%s\n' "$out" | sed 's/^/    /'
check "28: password authentication off" "passwordauthentication no" "$(sshd -T 2>/dev/null | grep -i '^passwordauthentication ')"
check "28: root login off" "permitrootlogin no" "$(sshd -T 2>/dev/null | grep -i '^permitrootlogin ')"

restore
finish
