#!/usr/bin/env bash
# =============================================================================
# tools/tests/vm.d/P0-16.sh -- SSH sources and sshd hardening
# (assertions 27 and 28)
#
# With PasswordAuthentication yes in a cloud-init drop-in, a firewall reset
# with --ssh-from leaves no SSH-from-anywhere rule, ufw active, and sshd's
# effective settings PasswordAuthentication no and PermitRootLogin no. ufw is
# turned off again at the end so the runner stays reachable for its own use.
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

mkdir -p /etc/ssh/sshd_config.d
printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/50-cloud-init.conf
out="$(timeout 600 bash "$fw" --reset --ssh-from 203.0.113.0/24 < /dev/null 2>&1)"
check_rc "firewall-setup.sh --reset --ssh-from" 0 "$?" || printf '%s\n' "$out" | tail -n 40 | sed 's/^/    /'
check "27: no SSH rule open to anywhere" "" "$(ufw status | grep -E '^22/tcp( \(v6\))? +ALLOW +Anywhere')"
check "27: ufw active" "Status: active" "$(ufw status | head -n 1)"
check "28: password authentication off" "passwordauthentication no" "$(sshd -T 2>/dev/null | grep -i '^passwordauthentication ')"
check "28: root login off" "permitrootlogin no" "$(sshd -T 2>/dev/null | grep -i '^permitrootlogin ')"
ufw --force disable >/dev/null 2>&1 || true

finish
