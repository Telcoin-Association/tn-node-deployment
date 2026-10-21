#!/usr/bin/env bash
# =============================================================================
# tools/tests/addon_gates_test.sh -- the add-on gates in lib/common.sh:
# validate_health_src, the health-port rules (apply_kuma_rule and the operator
# extras), allow_overlay_ssh, addon_meta_get and tn_testnet_addons_present.
#
#   bash tools/tests/addon_gates_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/addon_gates_test.sh
#
# ufw is a PATH stub that appends each call to a log; nothing touches the host.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T="$TN_TEST_TMP"
export TN_ROOT_PREFIX="$T/root"
mkdir -p "$TN_ROOT_PREFIX/etc/telcoin" "$T/bin"
eval "$(tn_test_source_common)"

UFW_LOG="$T/ufw.log"
export UFW_LOG
cat > "$T/bin/ufw" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$UFW_LOG"
case "$1" in
    status) printf 'Status: active\n' ;;
esac
# UFW_FAIL_MATCH: a call whose arguments equal it fails.
[ -n "${UFW_FAIL_MATCH:-}" ] && [ "$*" = "$UFW_FAIL_MATCH" ] && exit 1
exit 0
STUB
chmod +x "$T/bin/ufw"
PATH="$T/bin:$PATH"
META="$TN_ROOT_PREFIX/etc/telcoin/.node-meta"

vh() { if validate_health_src "$1"; then echo 0; else echo 1; fi; }

# --- validate_health_src: never anywhere ------------------------------------
check "vhs 1.2.3.4" 0 "$(vh 1.2.3.4)"
check "vhs 203.0.113.0/24" 0 "$(vh 203.0.113.0/24)"
check "vhs 2001:db8::/32" 0 "$(vh 2001:db8::/32)"
check "vhs 0.0.0.0/0 refused" 1 "$(vh 0.0.0.0/0)"
check "vhs ::/0 refused" 1 "$(vh ::/0)"
check "vhs 1.2.3.4/0 refused" 1 "$(vh 1.2.3.4/0)"
check "vhs 0.0.0.0 refused" 1 "$(vh 0.0.0.0)"
check "vhs :: refused" 1 "$(vh ::)"
check "vhs /08 leading zero refused" 1 "$(vh 10.0.0.0/08)"
check "vhs /33 refused" 1 "$(vh 10.0.0.0/33)"
check "vhs empty refused" 1 "$(vh '')"
# ufw refuses an IPv4 octet with a leading zero; so does the check, before any change.
check "vhs 010.0.113.0/24 refused" 1 "$(vh 010.0.113.0/24)"
check "vhs 203.000.113.7 refused" 1 "$(vh 203.000.113.7)"
check "vhs 203.0.113.07/32 refused" 1 "$(vh 203.0.113.07/32)"
check "vhs 203.0.113.0/24 still ok" 0 "$(vh 203.0.113.0/24)"
check "vhs 10.0.0.0/8 ok" 0 "$(vh 10.0.0.0/8)"
check "vhs 100.64.0.0/10 ok" 0 "$(vh 100.64.0.0/10)"
check "vhs 0.1.2.3 ok (a single zero octet)" 0 "$(vh 0.1.2.3)"
# Masks shorter than /8 are close to "anywhere" and are refused.
check "vhs 128.0.0.0/1 refused" 1 "$(vh 128.0.0.0/1)"
check "vhs 10.0.0.0/7 refused" 1 "$(vh 10.0.0.0/7)"
check "vhs 0::/1 refused" 1 "$(vh 0::/1)"
check "vhs 2000::/3 refused" 1 "$(vh 2000::/3)"
check "vhs 2001:db8::/8 ok" 0 "$(vh 2001:db8::/8)"
check "vhs 2001:db8::1/129 refused" 1 "$(vh 2001:db8::1/129)"

# --- apply_kuma_rule on testnet ---------------------------------------------
printf 'NETWORK=testnet\nKUMA_EXTRA_SRC=198.51.100.7 0.0.0.0/0\n' > "$META"
: > "$UFW_LOG"
NETWORK=testnet
apply_kuma_rule 2>"$T/err"; rc=$?
check_rc "testnet kuma rc 1 (a /0 extra is skipped)" 1 "$rc"
check_has "testnet monitor rule" "allow from ${TN_KUMA_SRC} to any port ${TN_KUMA_PORT} proto tcp" "$(cat "$UFW_LOG")"
check_has "testnet extra rule" "allow from 198.51.100.7 to any port ${TN_KUMA_PORT} proto tcp" "$(cat "$UFW_LOG")"
check_lacks "testnet /0 extra never applied" "allow from 0.0.0.0/0" "$(cat "$UFW_LOG")"
check_has "testnet /0 extra warned" "yes" "$(grep -q "Skipping health source '0.0.0.0/0'" "$T/err" && echo yes)"

printf 'NETWORK=testnet\nKUMA_EXTRA_SRC=198.51.100.7\n' > "$META"
: > "$UFW_LOG"
apply_kuma_rule 2>/dev/null; rc=$?
check_rc "testnet kuma rc 0" 0 "$rc"

# --- duplicated KUMA_EXTRA_SRC fails closed ---------------------------------
printf 'NETWORK=testnet\nKUMA_EXTRA_SRC=198.51.100.7\nKUMA_EXTRA_SRC=198.51.100.8\n' > "$META"
: > "$UFW_LOG"
kuma_extra_list >/dev/null 2>&1; rc=$?
check_rc "dup KUMA_EXTRA_SRC list rc 2" 2 "$rc"
apply_kuma_extra_rules 2>/dev/null; rc=$?
check_rc "dup KUMA_EXTRA_SRC apply rc 1" 1 "$rc"
check_lacks "dup KUMA_EXTRA_SRC applies nothing" "198.51.100" "$(cat "$UFW_LOG")"
before="$(cat "$META")"
kuma_extra_add 192.0.2.9 >/dev/null 2>&1; rc=$?
check_rc "dup KUMA_EXTRA_SRC add refused" 1 "$rc"
check "dup KUMA_EXTRA_SRC meta untouched by add" "$before" "$(cat "$META")"

# --- apply_kuma_rule on mainnet: removes, never adds ------------------------
printf 'NETWORK=mainnet\nKUMA_EXTRA_SRC=198.51.100.7\n' > "$META"
: > "$UFW_LOG"
NETWORK=mainnet
apply_kuma_rule 2>/dev/null; rc=$?
check_rc "mainnet kuma rc 1" 1 "$rc"
check_lacks "mainnet never adds a health allow" "allow from ${TN_KUMA_SRC}" "$(grep -v '^delete' "$UFW_LOG")"
check_has "mainnet deletes the monitor rule" "delete allow from ${TN_KUMA_SRC} to any port ${TN_KUMA_PORT} proto tcp" "$(cat "$UFW_LOG")"
check_has "mainnet deletes the extra rule" "delete allow from 198.51.100.7 to any port ${TN_KUMA_PORT} proto tcp" "$(cat "$UFW_LOG")"
check_has "mainnet deletes the open rule" "delete allow ${TN_KUMA_PORT}/tcp" "$(cat "$UFW_LOG")"
# A delete that fails on mainnet is an error (rc 2), never ignored.
for bad in "delete allow ${TN_KUMA_PORT}/tcp" \
           "delete allow from ${TN_KUMA_SRC} to any port ${TN_KUMA_PORT} proto tcp" \
           "delete allow from 198.51.100.7 to any port ${TN_KUMA_PORT} proto tcp"; do
    : > "$UFW_LOG"
    UFW_FAIL_MATCH="$bad" apply_kuma_rule 2>"$T/err"; rc=$?
    check_rc "mainnet failed '${bad}' rc 2" 2 "$rc"
    check_has "mainnet failed delete says the port may be open" "yes" "$(grep -q 'may still be open' "$T/err" && echo yes)"
done
: > "$UFW_LOG"
NETWORK=""
apply_kuma_rule 2>/dev/null; rc=$?
check_rc "unknown network kuma rc 1" 1 "$rc"
check_lacks "unknown network never adds" "allow from ${TN_KUMA_SRC}" "$(grep -v '^delete' "$UFW_LOG")"

# --- allow_overlay_ssh -------------------------------------------------------
check "admin cidr default" "10.100.9.0/24" "$TN_OVERLAY_ADMIN_CIDR"
get_ssh_port() { echo 2222; }
: > "$UFW_LOG"
NETWORK=testnet
allow_overlay_ssh >/dev/null 2>&1; rc=$?
check_rc "overlay ssh testnet rc 0" 0 "$rc"
check "overlay ssh testnet calls" "delete allow from 10.100.0.0/16 to any port 2222 proto tcp
allow from 10.100.9.0/24 to any port 2222 proto tcp" "$(cat "$UFW_LOG")"
: > "$UFW_LOG"
NETWORK=mainnet
allow_overlay_ssh >/dev/null 2>&1; rc=$?
check_rc "overlay ssh mainnet rc 1" 1 "$rc"
check_lacks "overlay ssh mainnet adds nothing" "allow from 10.100.9.0/24 to any port 2222 proto tcp" "$(grep -v '^delete' "$UFW_LOG")"

# --- addon_meta_get ----------------------------------------------------------
printf 'INSTALL_METHOD=docker\nENABLE_VPN=true\nENABLE_VPN=false\n' > "$META"
v="$(addon_meta_get INSTALL_METHOD binary)"; rc=$?
check "addon_meta_get value" "docker" "$v"
check_rc "addon_meta_get rc 0" 0 "$rc"
v="$(addon_meta_get RPC_PORT 8545)"; rc=$?
check "addon_meta_get default" "8545" "$v"
v="$(addon_meta_get ENABLE_VPN false 2>"$T/err")"; rc=$?
check_rc "addon_meta_get dup rc 2" 2 "$rc"
check "addon_meta_get dup prints nothing" "" "$v"
check_has "addon_meta_get dup message" "yes" "$(grep -q 'ENABLE_VPN is set more than once' "$T/err" && echo yes)"

# --- tn_testnet_addons_present -----------------------------------------------
P="$TN_ROOT_PREFIX"
out="$(tn_testnet_addons_present)"; rc=$?
check_rc "addons none rc 1" 1 "$rc"
check "addons none output" "" "$out"
mkdir -p "$P/etc/systemd/system" "$P/etc/caddy" "$P/etc/wireguard"
: > "$P/etc/systemd/system/telcoin-alloy.service"
printf '# Managed by the Telcoin Node Manager\n' > "$P/etc/caddy/Caddyfile"
out="$(tn_testnet_addons_present)"; rc=$?
check_rc "addons obs+caddy rc 0" 0 "$rc"
check "addons obs+caddy list" "observability,caddy" "$out"
: > "$P/etc/systemd/system/tn-vpn-selfheal.path"
check "addons all three" "vpn,observability,caddy" "$(tn_testnet_addons_present)"
printf 'stock\n' > "$P/etc/caddy/Caddyfile"
check "addons unmanaged Caddyfile ignored" "vpn,observability" "$(tn_testnet_addons_present)"

finish
