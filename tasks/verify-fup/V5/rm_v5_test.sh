#!/usr/bin/env bash
# =============================================================================
# tasks/verify-fup/V5/rm_v5_test.sh -- V5's checks of remove-node.sh's teardown
# of the P2P new-flow limit (telcoin-p2p-limit.service, /etc/telcoin/p2p-limit.nft,
# table inet tn_p2p): the menu path, every --json scope, the leftover path, nft
# refusing the delete, nft absent, and nothing touched while another node remains.
#   bash tasks/verify-fup/V5/rm_v5_test.sh      (V5_SRC overrides the tree)
# All paths live under a fixture root; every system tool is a PATH stub.
# =============================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/tests/lib.sh
. "${HERE}/../../../tools/tests/lib.sh"
# shellcheck source=tasks/verify-fup/V5/v5stubs.sh
. "${HERE}/v5stubs.sh"
SRC="${V5_SRC:-$TN_TEST_REPO}"
T="$TN_TEST_TMP"
R="$T/root"
CALLS="$T/calls.log"
REAL_ID="$(command -v id)"
export CALLS REAL_ID
mkdir -p "$T/bin" "$T/h" "$R"
for tool in userdel groupdel gpasswd docker pkill; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s $*" >> "$CALLS"\nexit 0\n' "$tool" > "$T/bin/$tool"
done
cat > "$T/bin/systemctl" <<'V5S'
#!/usr/bin/env bash
printf '%s\n' "systemctl $*" >> "$CALLS"
case "${1:-}" in is-active) exit 3 ;; is-enabled) exit 1 ;; esac
exit 0
V5S
cat > "$T/bin/getent" <<'V5S'
#!/usr/bin/env bash
printf '%s\n' "getent $*" >> "$CALLS"
exit 2
V5S
cat > "$T/bin/id" <<'V5S'
#!/usr/bin/env bash
case "${1:-}" in v5rm*) exit 1 ;; esac
exec "$REAL_ID" "$@"
V5S
cat > "$T/bin/shred" <<'V5S'
#!/usr/bin/env bash
printf '%s\n' "shred $*" >> "$CALLS"
for a in "$@"; do case "$a" in -*) ;; *) rm -f -- "$a" ;; esac; done
exit 0
V5S
for tool in setpriv runuser; do
    printf '#!/usr/bin/env bash\nwhile [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done\nshift\nexec "$@"\n' > "$T/bin/$tool"
done
TBL="$T/nft.table"
export TBL
cat > "$T/bin/nft" <<'V5S'
#!/usr/bin/env bash
printf '%s\n' "nft $*" >> "$CALLS"
case "$*" in
    "list tables") echo "table ip filter"; [ -f "$TBL" ] && echo "table inet tn_p2p"; exit 0 ;;
    "-f -")
        prog="$(cat)"; printf '%s\n' "$prog" | sed 's/^/nft| /' >> "$CALLS"
        [ -z "${V5_NFT_FAIL:-}" ] || { echo "Error: busy" >&2; exit 1; }
        printf '%s\n' "$prog" | grep -q 'table inet tn_p2p {' && { echo bad >&2; exit 9; }
        printf '%s\n' "$prog" | grep -qx 'delete table inet tn_p2p' && rm -f "$TBL"
        exit 0 ;;
esac
echo "unsupported $*" >&2; exit 1
V5S
chmod +x "$T/bin/"*
mkdir -p "$T/bin-nonft"
for f in "$T/bin/"*; do [[ "${f##*/}" == nft ]] || cp "$f" "$T/bin-nonft/"; done
P_FULL="$T/bin:/usr/local/bin:/usr/bin:/bin"
P_NONFT="$T/bin-nonft:/usr/local/bin:/usr/bin:/bin"
PATH="$P_FULL"

grep -v '^main "\$@"$' "$SRC/remove-node.sh" > "$T/h/remove-node.sh"
ln -s "$SRC/lib" "$T/h/lib"
export TN_ROOT_PREFIX="$R"
unset TN_LOGROTATE_FILE TN_ASSUME_YES
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/h/remove-node.sh"
tn_test_post_common
set +e
CONFIRM_ANSWER=no
confirm() { [[ "$CONFIRM_ANSWER" == "yes" ]]; }
remove_testnet_addons() { :; }
SD="$R/etc/systemd/system"
ETC="$R/etc/telcoin"
UNIT="$SD/telcoin-p2p-limit.service"
NFTF="$ETC/p2p-limit.nft"

mk() {
    rm -rf "$R"; : > "$CALLS"
    mkdir -p "$SD" "$ETC" "$R/var/lib/telcoin/node-keys" "$R/run/telcoin"
    printf '[Service]\nUser=v5rmuser\nExecStart=/bin/true\n' > "$SD/telcoin.service"
    printf 'NETWORK=testnet\nINSTALL_METHOD=source\nHOST_SERVICE_USER=v5rmuser\nHOST_SERVICE_GROUP=v5rmuser\nDATA_DIR=%s\n' \
        "$R/var/lib/telcoin" > "$ETC/.node-meta"
    printf '[Unit]\n' > "$UNIT"
    printf 'table inet tn_p2p\n' > "$NFTF"
    : > "$TBL"
}
limit_state() {
    printf '%s %s %s' "$([[ -e "$UNIT" ]] && echo unit || echo -)" "$([[ -e "$NFTF" ]] && echo file || echo -)" \
        "$([[ -e "$TBL" ]] && echo table || echo -)"
}
calls() { cat "$CALLS"; }

# --- --json scopes ---------------------------------------------------------------
for scope in service data; do
    mk
    ( set -e; json_remove validator "$scope" ) 3> "$T/json" > "$T/out" 2>&1; rc=$?
    check_rc "R1 json ${scope}: rc 0" 0 "$rc"
    check "R1 json ${scope}: limit untouched" "unit file table" "$(limit_state)"
    check_lacks "R1 json ${scope}: no p2p-limit systemctl call" "telcoin-p2p-limit" "$(calls)"
done
mk
( set -e; json_remove validator keys ) 3> "$T/json" > "$T/out" 2>&1; rc=$?
check_rc "R2 json keys (last node): rc 0" 0 "$rc"
check "R2 json keys: unit, file and table gone" "- - -" "$(limit_state)"
check_sub "R2 json keys: unit disabled and stopped" "systemctl disable --now telcoin-p2p-limit.service" "$(calls)"
check_sub "R2 json keys: the table delete program" $'nft| table inet tn_p2p\nnft| delete table inet tn_p2p' "$(calls)"
check "R2 json keys: stdout is JSON only, ends with done ok" "yes" \
    "$(grep -v '^{' "$T/json" | grep -q . && echo no || { tail -n1 "$T/json" | grep -q '"event":"done","ok":true' && echo yes; })"
# another node remains (a second node unit)
mk
printf '[Service]\nExecStart=/bin/true\n' > "$SD/telcoin-validator.service"
( set -e; json_remove validator keys ) 3> "$T/json" > "$T/out" 2>&1; rc=$?
echo "info  R3 keys with another node unit: rc=$rc state=[$(limit_state)] other=$(other_node_unit_files telcoin | tr '\n' ' ')"
check "R3 json keys with another node: unit and table untouched" "unit table" \
    "$(limit_state | awk '{print $1, $3}')"
check "R3b (adversarial) json keys with another node: the boot ruleset file survives" "file" \
    "$(limit_state | awk '{print $2}')"
# --- the menu path ------------------------------------------------------------------
mk
INSTALLED_UNITS=(telcoin telcoin-validator)
remove_shared_components > "$T/out" 2>&1
check "R4 menu with two nodes: limit untouched" "unit file table" "$(limit_state)"
mk
INSTALLED_UNITS=(telcoin)
remove_shared_components > "$T/out" 2>&1
check "R5 menu, last node: limit removed" "- - -" "$(limit_state)"
check_sub "R5 menu: says so" "Deleted the P2P new-flow limit (nftables table inet tn_p2p)" "$(cat "$T/out")"
# --- the leftover path -----------------------------------------------------------------
mk
rm -f "$SD/telcoin.service"
CONFIRM_ANSWER=yes
remove_leftovers > "$T/out" 2>&1; rc=$?
CONFIRM_ANSWER=no
check "R6 leftovers: rc 0, limit removed" "0 - - -" "$rc $(limit_state)"
mk
rm -rf "$SD/telcoin.service" "$ETC" "$R/var/lib/telcoin"
CONFIRM_ANSWER=yes
remove_leftovers > "$T/out" 2>&1; rc=$?
CONFIRM_ANSWER=no
echo "info  R7 only the limit unit and table left: remove_leftovers rc=$rc state=[$(limit_state)]"
# --- nft refusing, nft absent, no table -----------------------------------------------
mk
export V5_NFT_FAIL=1
_rm_p2p_limit > "$T/out" 2>&1; rc=$?
unset V5_NFT_FAIL
check "R8 nft refuses the delete: rc 0, unit and file gone, table stays" "0 - - table" "$rc $(limit_state)"
check_sub "R8 warning names the command" "remove it with: sudo nft delete table inet tn_p2p" "$(cat "$T/out")"
mk
PATH="$P_NONFT"
if command -v nft > /dev/null 2>&1; then
    PATH="$P_FULL"; skip "R9 nft absent" "nft on the reduced PATH"
else
    _rm_p2p_limit > "$T/out" 2>&1; rc=$?
    PATH="$P_FULL"
    check "R9 nft absent: rc 0, unit and file gone" "0 - -" "$rc $(limit_state | awk '{print $1, $2}')"
    check_lacks "R9 nft absent: no nft call" "nft " "$(calls)"
fi
mk
rm -f "$TBL"
_rm_p2p_limit > "$T/out" 2>&1
check_lacks "R10 no table: no nft -f call" "nft -f" "$(calls)"
mk
rm -f "$UNIT" "$NFTF"
_rm_p2p_limit > "$T/out" 2>&1
check_lacks "R11 no unit: no systemctl call for it" "telcoin-p2p-limit" "$(calls)"
finish
