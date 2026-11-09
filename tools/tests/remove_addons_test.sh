#!/usr/bin/env bash
# =============================================================================
# tools/tests/remove_addons_test.sh -- remove-node.sh remove_testnet_addons on a
# fixture tree: every VPN leftover (units, helper, key files, sshd drop-in,
# sudoers file, account, overlay ufw rules) goes even when wg0.conf and the wg0
# link are gone; the sudoers file goes even when the tnadmin account is gone;
# the self-heal stops before the drop-in it watches is removed; files outside
# the list stay, the private alerts among them (they are no testnet add-on);
# remove_alerts takes those on a tree whose lib/ has no alerts.sh.
#
#   bash tools/tests/remove_addons_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/remove_addons_test.sh
#
# remove-node.sh is sourced from a copy without its `main "$@"` line, with
# TN_ROOT_PREFIX pointing the paths at a fixture tree. systemctl, docker, id,
# userdel, wg-quick, ip, sshd and ufw are PATH stubs that log their calls.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T="$TN_TEST_TMP"
R="$T/root"
export TN_ROOT_PREFIX="$R"
export CALLS="$T/calls"
mkdir -p "$T/bin" "$T/rn" "$R"
REAL_ID="$(command -v id)"
export REAL_ID

# id: `id -u NAME` succeeds for the names in FAKE_USERS; anything else is the real id.
cat > "$T/bin/id" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "-u" ] && [ -n "${2:-}" ]; then
    case " ${FAKE_USERS:-} " in *" $2 "*) echo 1001; exit 0 ;; esac
    exit 1
fi
exec "$REAL_ID" "$@"
STUB
# systemctl records whether the tnadmin drop-in still exists at the time of the call.
cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
d=no
[ -e "${TN_ROOT_PREFIX:?}/etc/ssh/sshd_config.d/15-tnadmin-overlay.conf" ] && d=yes
printf 'systemctl %s [dropin=%s]\n' "$*" "$d" >> "${CALLS:?}"
exit 0
STUB
for c in docker userdel wg-quick sshd ufw; do
    printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %s "$*" >> "${CALLS:?}"\nexit 0\n' "$c" > "$T/bin/$c"
done
# ip: the wg0 link exists only with WG_LINK=1.
cat > "$T/bin/ip" <<'STUB'
#!/usr/bin/env bash
[ "$*" = "link show wg0" ] && [ "${WG_LINK:-0}" = "1" ] && exit 0
exit 1
STUB
chmod +x "$T/bin/"*
PATH="$T/bin:/usr/local/bin:/usr/bin:/bin"
export PATH
hash -r

grep -v '^main "\$@"$' "${TN_TEST_REPO}/remove-node.sh" > "$T/rn/remove-node.sh"
ln -s "${TN_TEST_REPO}/lib" "$T/rn/lib"
# shellcheck source=/dev/null
source "$T/rn/remove-node.sh"
set +e
get_ssh_port() { echo 2222; }

LISTED="/etc/systemd/system/telcoin-alloy.service /usr/local/bin/alloy /etc/telcoin/alloy/config.alloy
/var/lib/telcoin-alloy/data /etc/systemd/system/tn-vpn-selfheal.path /etc/systemd/system/tn-vpn-selfheal.service
/usr/local/sbin/tn-vpn-selfheal /etc/wireguard/wg0.conf /etc/wireguard/wg0-private.key
/etc/ssh/sshd_config.d/15-tnadmin-overlay.conf /etc/systemd/system/tn-nftables.service
/etc/wgvpn/nftables-node.nft /usr/local/sbin/tn-node-ssh-lockdown /etc/wgvpn/tnadmin.keys
/etc/wgvpn/tnadmin.revoked /etc/wgvpn/tnadmin.authorized_keys /etc/sudoers.d/90-tnadmin"
ALERTS="/etc/systemd/system/telcoin-heartbeat.timer /etc/systemd/system/telcoin-heartbeat.service
/usr/local/libexec/telcoin/tn-heartbeat /etc/telcoin/alerts/targets /etc/telcoin/alerts/alerts.env
/var/lib/private/telcoin-heartbeat/state"
KEEP_BASE="/etc/wireguard/other.conf /etc/ssh/sshd_config.d/00-telcoin-hardening.conf
/etc/ssh/sshd_config.d/50-cloud-init.conf /usr/local/sbin/keep-me /etc/systemd/system/telcoin.service
/etc/telcoin/.node-meta /etc/sudoers.d/91-other /etc/wgvpn/other"
KEEP="$KEEP_BASE $ALERTS"

# fixture LIST... -- a fresh tree holding the named files plus the KEEP set.
fixture() {
    local f
    rm -rf "$R"
    for f in $KEEP "$@"; do
        mkdir -p "$R$(dirname "$f")"
        echo x > "$R$f"
    done
    : > "$CALLS"
}
present() { local f out=""; for f in "$@"; do [ -e "$R$f" ] && out="$out $f"; done; echo "${out# }"; }
# The P2P committee allowlist stays too: it goes with the last node
# (remove_node_host_files), never with the host-wide add-ons, which every node
# removal runs.
ALLOW="/etc/systemd/system/telcoin-p2p-allow.service /etc/systemd/system/telcoin-p2p-allow-sync.service
/etc/systemd/system/telcoin-p2p-allow-sync.timer /var/lib/telcoin-p2p-allow/config
/usr/local/libexec/telcoin/tn-p2p-allow-sync"
KEEP="$KEEP $ALLOW"

# --- wg0.conf and the link gone, everything else left behind ------------------------------
# shellcheck disable=SC2086
fixture $(printf '%s\n' $LISTED | grep -v '/etc/wireguard/wg0')
FAKE_USERS="tnadmin telcoin-alloy" WG_LINK=0 remove_testnet_addons >"$T/out" 2>&1
check_rc "no wg0: rc 0" 0 $?
# shellcheck disable=SC2086
check "no wg0: every listed path removed" "" "$(present $LISTED)"
# shellcheck disable=SC2086
check "no wg0: files outside the list kept" "$(echo $KEEP)" "$(present $KEEP)"
check "no wg0: /etc/wgvpn kept while it holds another file" "yes" "$([ -d "$R/etc/wgvpn" ] && echo yes)"
check_has "no wg0: tnadmin account removed" "userdel -r tnadmin" "$(cat "$CALLS")"
check_has "no wg0: alloy account removed" "userdel telcoin-alloy" "$(cat "$CALLS")"
check "no wg0: tn-nftables stopped" "yes" "$(grep -q '^systemctl disable --now tn-nftables.service ' "$CALLS" && echo yes)"
check_has "no wg0: admin range rule deleted" "ufw delete allow from ${TN_OVERLAY_ADMIN_CIDR} to any port 2222 proto tcp" "$(cat "$CALLS")"
check_has "no wg0: whole-overlay rule deleted" "ufw delete allow from ${TN_OVERLAY_CIDR} to any port 2222 proto tcp" "$(cat "$CALLS")"
check_has "self-heal stopped while the drop-in was still there" \
    "systemctl disable --now tn-vpn-selfheal.path tn-vpn-selfheal.service [dropin=yes]" "$(cat "$CALLS")"
check_has "sshd checked before the reload" "sshd -t" "$(cat "$CALLS")"
check_lacks "no wg0: no wg-quick down" "wg-quick" "$(cat "$CALLS")"

# --- only the sudoers file is left, and the account is gone --------------------------------
fixture /etc/sudoers.d/90-tnadmin
FAKE_USERS="" WG_LINK=0 remove_testnet_addons >"$T/out" 2>&1
check_rc "sudoers orphan: rc 0" 0 $?
check "sudoers orphan: 90-tnadmin removed" "" "$(present /etc/sudoers.d/90-tnadmin)"
check "sudoers orphan: 91-other kept" "/etc/sudoers.d/91-other" "$(present /etc/sudoers.d/91-other)"
check_lacks "sudoers orphan: no userdel" "userdel" "$(cat "$CALLS")"

# --- full VPN: wg0.conf and the link -------------------------------------------------------
# shellcheck disable=SC2086
fixture $LISTED
FAKE_USERS="tnadmin" WG_LINK=1 remove_testnet_addons >"$T/out" 2>&1
check_rc "full: rc 0" 0 $?
# shellcheck disable=SC2086
check "full: every listed path removed" "" "$(present $LISTED)"
check_has "full: wg0 brought down" "wg-quick down wg0" "$(cat "$CALLS")"
check_has "full: de-enrol note" "yes" "$(grep -q 'de-enroll' "$T/out" && echo yes)"
# shellcheck disable=SC2086
check "full: the P2P committee allowlist stays (not an add-on)" "$(echo $ALLOW)" "$(present $ALLOW)"
check_lacks "full: no allowlist unit stopped" "telcoin-p2p-allow" "$(cat "$CALLS")"

# --- nothing installed: nothing removed, no account touched --------------------------------
fixture
FAKE_USERS="" WG_LINK=0 remove_testnet_addons >"$T/out" 2>&1
check_rc "clean host: rc 0" 0 $?
# shellcheck disable=SC2086
check "clean host: files outside the list kept" "$(echo $KEEP)" "$(present $KEEP)"
check_lacks "clean host: no userdel" "userdel" "$(cat "$CALLS")"
check_lacks "clean host: no sshd reload" "reload ssh" "$(cat "$CALLS")"
check_lacks "clean host: the alerts files are no testnet add-on" "Testnet add-ons found" "$(cat "$T/out")"
check_lacks "clean host: the add-on teardown leaves the heartbeat alone" "heartbeat" "$(cat "$CALLS")"

# --- remove_alerts on a tree whose lib/ has no alerts.sh and no tn-heartbeat.sh -------------
# (an updater that installed remove-node.sh and not the library). A fresh bash
# sources a copy of remove-node.sh beside such a lib/ and runs remove_alerts.
mkdir -p "$T/rn2"
cp "$T/rn/remove-node.sh" "$T/rn2/remove-node.sh"
cp -R "${TN_TEST_REPO}/lib" "$T/rn2/lib"
rm -f "$T/rn2/lib/alerts.sh" "$T/rn2/lib/tn-heartbeat.sh"
fixture
ln -s private/telcoin-heartbeat "$R/var/lib/telcoin-heartbeat"
bash -c 'source "$1" >/dev/null 2>&1 || exit 9
         set +e
         remove_alerts; rc=$?
         declare -F | awk "{print \$3}" | grep -E "^(alerts|hb)_" > "$2"
         exit "$rc"' _ "$T/rn2/remove-node.sh" "$T/fns" >"$T/out" 2>&1
check_rc "no alerts library: rc 0" 0 $?
check "no alerts library: no alerts_* or hb_* function loaded" "" "$(cat "$T/fns" 2>/dev/null)"
# shellcheck disable=SC2086
check "no alerts library: every alerts file removed" "" "$(present $ALERTS)"
check "no alerts library: the config dir removed" "" "$(present /etc/telcoin/alerts /var/lib/private/telcoin-heartbeat)"
check "no alerts library: the state link removed" "no" "$([ -L "$R/var/lib/telcoin-heartbeat" ] && echo yes || echo no)"
# shellcheck disable=SC2086
check "no alerts library: the other files kept" "$(echo $KEEP_BASE)" "$(present $KEEP_BASE)"
check_has "no alerts library: the timer disabled" "systemctl disable --now telcoin-heartbeat.timer [dropin=no]" "$(cat "$CALLS")"
check "no alerts library: the hint" "1" "$(grep -c "Pause or delete this node's monitor: a push monitor alerts on silence." "$T/out")"

finish
