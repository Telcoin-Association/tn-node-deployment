#!/usr/bin/env bash
# =============================================================================
# tools/tests/gateway_validator_test.sh -- the validator side of the worker
# gateway (a gateway on another host reaching this node's RPC and health ports):
#   the helpers    lib/common.sh tn_gateway_meta_path, tn_gateway_installed,
#                  tn_gateway_meta_get (file or key absent, empty value, a key on
#                  two lines), tn_gateway_from_list (no node, absent, set, twice),
#                  tn_gateway_from_rules_ok (ufw inactive, both rules, one
#                  missing named in TN_GATEWAY_FROM_MISSING, an Anywhere rule not
#                  counting, a host shown with or without /32, a CIDR source
#                  matched by its network address, the "ALLOW IN" layout) and
#                  tn_node_health_bind (bare port, ip:port, no flag, no launch
#                  file); lib/common.sh sources with and without lib/gateway.sh;
#   the parser     firewall-setup.sh --gateway-from alone, with --p2p-committee
#                  and with --status is refused before anything runs; a host
#                  with no node and a bad source are refused with the tree as it
#                  was;
#   the rules      --enable --gateway-from (both spellings) puts the two allows
#                  per source after the health-port block and before the default
#                  policy and records GATEWAY_ALLOW_FROM; --reset and a plain
#                  --enable put them back; a source dropped from the list loses
#                  its two rules; none deletes them and the key; mainnet across
#                  consecutive runs; committee mode on; --json --enable and
#                  --json --status ("gateway_from" before the last key,
#                  p2p_committee); the expected-rules rows;
#   the baseline   with no GATEWAY_ALLOW_FROM the ufw calls are the ones the
#                  scripts made before the gateway existed (recorded below from
#                  origin/main 2813343, testnet and mainnet);
#   the gateway    a host with a gateway and no node: --enable opens SSH and,
#   host           with the gateway's Caddy fence, 80/443, and nothing else.
#
#   bash tools/tests/run.sh tools/tests/gateway_validator_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/run.sh tools/tests/gateway_validator_test.sh
#
# lib/common.sh is sourced here for the helpers. firewall-setup.sh runs as a
# process: a driver sources a copy without its last line (main "$@"), replaces
# check_root, the root writers and the host probes, then calls main. ufw, sshd,
# systemctl and nft are the PATH stubs of tools/tests/fwstub.sh, with their state
# under a fixture TN_ROOT_PREFIX. Nothing touches the host. bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tools/tests/fwstub.sh
. "${TN_TEST_DIR}/fwstub.sh"
T="$TN_TEST_TMP"
R="$T/root"
export TN_ROOT_PREFIX="$R"
export UFW_LOG="$T/ufw.log"
export NFT_LOG="$T/nft.log"
export SYSTEMCTL_LOG="$T/systemctl.log"
export TN_FW_SNAP_PARENT="$T/snap"
export TN_UPDATE_LOCK_FILE="$T/lock/update.lock"
export FW_CALLS="$T/fwcalls.log"
META="$R/etc/telcoin/.node-meta"
GWD="$R/etc/telcoin/gateway"
GWMETA="$GWD/gateway.meta"
RULES="$R/etc/ufw/user.rules"
mkdir -p "$R/etc/telcoin" "$R/etc/ufw" "$R/etc/default" "$R/etc/ssh" "$TN_FW_SNAP_PARENT" "$T/fw" "$T/lock"
fw_stub_install "$T/bin"
PATH="$T/bin:/usr/local/bin:/usr/bin:/bin"
printf 'ENABLED=yes\n' > "$R/etc/ufw/ufw.conf"
: > "$RULES"

eval "$(tn_test_source_common)"
KP="$TN_KUMA_PORT"

has() {
    case "$2" in
        *"$1"*) echo yes ;;
        *) echo no ;;
    esac
}
# rcof CMD... -- run CMD here: RC, OUT (stdout), ERR (stderr).
rcof() {
    RC=0
    OUT="$("$@" 2>"$T/err")" || RC=$?
    ERR="$(cat "$T/err")"
}

# ---- tn_gateway_meta_path, tn_gateway_installed, tn_gateway_meta_get -------------
rcof tn_gateway_meta_path
check "meta_path: the prefixed gateway.meta" "0 ${GWMETA}" "$RC $OUT"
rcof tn_gateway_installed
check "installed: no gateway.meta -> rc 1, nothing printed" "1 " "$RC $OUT"
rcof tn_gateway_meta_get NETWORK dflt
check "meta_get: file absent -> the default, rc 0" "0 dflt" "$RC $OUT"
mkdir -p "$GWD"
printf 'GATEWAY_META_VERSION=1\nNETWORK=devnet\nMODE=same-host\nMODE=standalone\nTRUSTED_PROXIES=\n' > "$GWMETA"
rcof tn_gateway_installed
check "installed: gateway.meta present -> rc 0, nothing printed" "0 " "$RC $OUT"
rcof tn_gateway_meta_get NETWORK x
check "meta_get: a key present" "0 devnet" "$RC $OUT"
rcof tn_gateway_meta_get DOMAIN dd
check "meta_get: key absent -> the default" "0 dd" "$RC $OUT"
rcof tn_gateway_meta_get DOMAIN
check "meta_get: key absent, no default -> empty, rc 0" "0 " "$RC $OUT"
rcof tn_gateway_meta_get TRUSTED_PROXIES x
GW_EMPTY="$RC $OUT"
printf 'NETWORK=devnet\nTRUSTED_PROXIES=\n' > "$META"
rcof addon_meta_get TRUSTED_PROXIES x
check "meta_get: an empty value reads as addon_meta_get reads it" "$RC $OUT" "$GW_EMPTY"
check "meta_get: an empty value is the value (empty), not the default" "0 " "$GW_EMPTY"
rcof tn_gateway_meta_get MODE x
check "meta_get: a key on two lines -> rc 2, nothing printed" "2 " "$RC $OUT"
check "meta_get: a key on two lines -> says so on stderr" yes "$(has "more than once" "$ERR")"
mv "$GWMETA" "$T/gw.meta.aside" && mkdir "$GWMETA"
rcof tn_gateway_installed
check "installed: gateway.meta is a directory -> rc 1" 1 "$RC"
rmdir "$GWMETA" && mv "$T/gw.meta.aside" "$GWMETA"

# ---- tn_gateway_from_list -----------------------------------------------------------
rm -f "$META"
rcof tn_gateway_from_list
check "from_list: no node -> rc 1, nothing printed" "1 " "$RC $OUT"
printf 'NETWORK=devnet\n' > "$META"
rcof tn_gateway_from_list
check "from_list: key absent -> rc 0, nothing printed" "0 " "$RC $OUT"
printf 'NETWORK=devnet\nGATEWAY_ALLOW_FROM=10.0.0.5,10.1.0.0/24\n' > "$META"
rcof tn_gateway_from_list
check "from_list: the stored comma list" "0 10.0.0.5,10.1.0.0/24" "$RC $OUT"
printf 'GATEWAY_ALLOW_FROM=10.0.0.5\nGATEWAY_ALLOW_FROM=10.0.0.6\n' > "$META"
rcof tn_gateway_from_list
check "from_list: key twice -> rc 2, nothing printed" "2 " "$RC $OUT"
check "from_list: key twice -> says so on stderr" yes "$(has "more than once" "$ERR")"

# ---- tn_gateway_from_rules_ok (the fwstub ufw: user.rules shown as `ufw status`) ----
ufw_rules() { printf '%s\n' "$@" > "$RULES"; }
ufw_on() { printf 'ENABLED=%s\n' "$1" > "$R/etc/ufw/ufw.conf"; }
# rok LIST RPC HEALTH -- called directly (TN_GATEWAY_FROM_MISSING is a global):
# "RC MISSING" in ROK, anything printed in ROK_OUT.
rok() {
    local rc=0
    tn_gateway_from_rules_ok "$@" > "$T/rok" 2>&1 || rc=$?
    ROK="${rc} ${TN_GATEWAY_FROM_MISSING-unset}"
    ROK_OUT="$(cat "$T/rok")"
}
gw_pair() { printf 'allow from %s to any port %s proto tcp\nallow from %s to any port %s proto tcp\n' "$1" "$2" "$1" "$3"; }
gw_pair 10.0.0.5 8545 "$KP" > "$RULES"
ufw_on no
rok 10.0.0.5 8545 "$KP"
check "rules_ok: ufw inactive -> rc 1, ufw-inactive" "1 ufw-inactive" "$ROK"
ufw_on yes
rok 10.0.0.5 8545 "$KP"
check "rules_ok: both rules -> rc 0, MISSING empty" "0 " "$ROK"
check "rules_ok: prints nothing" "" "$ROK_OUT"
ufw_rules "allow from 10.0.0.5 to any port 8545 proto tcp"
rok 10.0.0.5 8545 "$KP"
check "rules_ok: health rule missing -> names source and health port" "1 10.0.0.5 ${KP}" "$ROK"
ufw_rules "allow from 10.0.0.5 to any port ${KP} proto tcp"
rok 10.0.0.5 8545 "$KP"
check "rules_ok: RPC rule missing -> names source and RPC port" "1 10.0.0.5 8545" "$ROK"
ufw_rules "allow 8545/tcp" "allow ${KP}/tcp"
rok 10.0.0.5 8545 "$KP"
check "rules_ok: a rule from Anywhere does not count" "1 10.0.0.5 8545" "$ROK"
gw_pair 10.0.0.5 8546 "$KP" > "$RULES"
rok 10.0.0.5 8545 "$KP"
check "rules_ok: a rule on another port does not count" "1 10.0.0.5 8545" "$ROK"
gw_pair 10.0.0.6/32 8545 "$KP" > "$RULES"
rok 10.0.0.6 8545 "$KP"
check "rules_ok: host listed bare, ufw shows /32 -> rc 0" "0 " "$ROK"
gw_pair 10.0.0.5 8545 "$KP" > "$RULES"
rok 10.0.0.5/32 8545 "$KP"
check "rules_ok: host listed with /32, ufw shows it bare -> rc 0" "0 " "$ROK"
gw_pair 10.1.0.0/24 8545 "$KP" > "$RULES"
rok 10.1.0.0/24 8545 "$KP"
check "rules_ok: a CIDR as written -> rc 0" "0 " "$ROK"
rok 10.1.0.7/24 8545 "$KP"
check "rules_ok: a CIDR matched by its network address -> rc 0" "0 " "$ROK"
rok 10.1.0.0/16 8545 "$KP"
check "rules_ok: a wider CIDR is another source" "1 10.1.0.0/16 8545" "$ROK"
{ gw_pair 10.0.0.5 8545 "$KP"; printf 'allow from 10.0.0.8 to any port 8545 proto tcp\n'; } > "$RULES"
rok "10.0.0.5,10.0.0.8" 8545 "$KP"
check "rules_ok: the first missing rule of a later source" "1 10.0.0.8 ${KP}" "$ROK"
gw_pair 10.0.0.5 8545 "$KP" > "$RULES"
rok "10.0.0.5, ,10.0.0.5 ," 8545 "$KP"
check "rules_ok: blank entries are skipped" "0 " "$ROK"
rok "" 8545 "$KP"
check "rules_ok: an empty list with ufw active -> rc 0" "0 " "$ROK"
# The layout of `ufw status verbose` (ALLOW IN, a comment, v6 lines).
ufw() {
    [[ "${1:-}" == "status" ]] || return 0
    printf 'Status: active\n\nTo                         Action      From\n--                         ------      ----\n'
    printf '8545/tcp                   ALLOW IN    10.3.0.1                   # tn gateway\n'
    printf '%s/tcp                  ALLOW IN    10.3.0.1\n' "$KP"
    printf '8545/tcp (v6)              ALLOW IN    Anywhere (v6)\n'
}
rok 10.3.0.1 8545 "$KP"
check "rules_ok: the ALLOW IN layout with a comment -> rc 0" "0 " "$ROK"
unset -f ufw

# ---- tn_node_health_bind --------------------------------------------------------------
rm -f "$META"
rcof tn_node_health_bind
check "health_bind: no node here (the real launch-target lookup) -> rc 2, nothing printed" "2 " "$RC $OUT"
# The launch target is a stand-in (the real one refuses a file not owned by root).
LT_FILE=""
LT_RC=1
tn_node_launch_target() {
    [[ -n "$LT_FILE" ]] || return "$LT_RC"
    printf 'telcoin binary %s\n' "$LT_FILE"
}
launch() { printf '#!/bin/bash\nexec /opt/telcoin/telcoin-network node --datadir /var/lib/telcoin --http --http.addr 127.0.0.1%s\n' "$1" > "$T/tn-start"; }
LT_FILE="$T/tn-start"
launch " --healthcheck ${KP}"
rcof tn_node_health_bind
check "health_bind: a bare port -> 127.0.0.1:<port>" "0 127.0.0.1:${KP}" "$RC $OUT"
launch " --healthcheck 0.0.0.0:${KP}"
rcof tn_node_health_bind
check "health_bind: ip:port as it is" "0 0.0.0.0:${KP}" "$RC $OUT"
launch " --healthcheck 10.0.0.9:${KP} --ws"
rcof tn_node_health_bind
check "health_bind: a private ip:port as it is" "0 10.0.0.9:${KP}" "$RC $OUT"
launch " --ws"
rcof tn_node_health_bind
check "health_bind: no --healthcheck -> rc 1, nothing printed" "1 " "$RC $OUT"
LT_FILE="$T/no-such-start"
rcof tn_node_health_bind
check "health_bind: launch file missing -> rc 2, nothing printed" "2 " "$RC $OUT"
LT_FILE=""
LT_RC=3
rcof tn_node_health_bind
check "health_bind: launch target refused -> rc 2" "2 " "$RC $OUT"

# ---- lib/common.sh sources with and without lib/gateway.sh ----------------------------
rc=0
bash -c 'set -euo pipefail; source "$1"; declare -F gw_etc_dir >/dev/null; declare -F tn_gateway_from_rules_ok >/dev/null' \
    _ "${TN_TEST_REPO}/lib/common.sh" > /dev/null 2>&1 || rc=$?
check_rc "source: lib/gateway.sh present -> rc 0 under set -e, gateway.sh loaded" 0 "$rc"
mkdir -p "$T/lib-nogw"
cp -R "${TN_TEST_REPO}/lib/." "$T/lib-nogw/"
rm -f "$T/lib-nogw/gateway.sh"
rc=0
bash -c 'set -euo pipefail; source "$1"; if declare -F gw_etc_dir >/dev/null; then exit 7; fi; declare -F tn_gateway_installed >/dev/null' \
    _ "$T/lib-nogw/common.sh" > /dev/null 2>&1 || rc=$?
check_rc "source: lib/gateway.sh absent -> rc 0 under set -e, the helpers still there" 0 "$rc"

# ---- firewall-setup.sh: the driver ------------------------------------------------------
grep -v '^main "\$@"$' "${TN_TEST_REPO}/firewall-setup.sh" > "$T/fw/firewall-setup.sh"
ln -s "${TN_TEST_REPO}/lib" "$T/fw/lib"
cat > "$T/fw/driver.sh" <<'DRV'
# shellcheck shell=bash
# driver.sh ARG... -- firewall-setup.sh's main with ARG; CALL=FN runs FN instead.
# shellcheck source=/dev/null
source "$(dirname "$0")/firewall-setup.sh"
check_root() { :; }
tn_migrate_ownership() { return 0; }
tn_write_root_file() { mkdir -p "${1%/*}"; cat > "$1"; }
_tn_root_layout_dir() { mkdir -p "$1" && chmod "$3" "$1"; }
detect_installed_nodes() { if [[ "${NODE:-1}" == 1 ]]; then echo telcoin.service; else echo none; fi; }
tn_resolve_service() { [[ "${NODE:-1}" == 1 ]] && echo telcoin; }
fw_p2p_ports() { printf '49590 primary\n49594 worker-0\n'; }
ip() { return 1; }
fw_committee_sync() { printf 'committee-sync %s\n' "$*" >> "$FW_CALLS"; return 0; }
fw_baseline_refresh() { :; }
# UFW_AS_UFW=1: `ufw status` shows a source the way ufw stores it (amendment A-2):
# a host without /32, a CIDR by its network address (10.164.0.7/24 here).
if [[ -n "${UFW_AS_UFW:-}" ]]; then
    ufw() {
        if [[ "${1:-}" == "status" ]]; then
            command ufw "$@" | sed -e 's#/32$##' -e 's#10[.]164[.]0[.]7/24$#10.164.0.0/24#'
        else
            command ufw "$@"
        fi
    }
fi
if [[ -n "${CALL:-}" ]]; then
    fw_load_network > /dev/null 2>&1
    "$CALL"
    exit $?
fi
main "$@"
DRV
# tree NETWORK|- [META LINE...] -- a fresh root: ufw on with 22/tcp only, a node
# whose .node-meta holds the lines (no node for "-"), no Caddy.
tree() {
    rm -rf "$R"
    mkdir -p "$R/etc/telcoin" "$R/etc/ufw" "$R/etc/default" "$R/etc/ssh"
    printf 'allow 22/tcp\n' > "$RULES"
    printf 'ENABLED=yes\n' > "$R/etc/ufw/ufw.conf"
    printf 'DEFAULT_INPUT_POLICY="DROP"\n' > "$R/etc/default/ufw"
    if [[ "$1" != "-" ]]; then
        printf '%s\n' "OWNERSHIP_LAYOUT=2" "NETWORK=$1" "${@:2}" > "$META"
    fi
    rm -f "$T/bin/caddy"
    : > "$UFW_LOG"
    : > "$FW_CALLS"
}
drun() {
    : > "$UFW_LOG"
    RC=0
    bash "$T/fw/driver.sh" "$@" > "$T/out" 2>&1 < /dev/null || RC=$?
    OUT="$(cat "$T/out")"
}
snapshot() { cat "$RULES" "$R/etc/ufw/ufw.conf" "$R/etc/default/ufw" "$META" 2>/dev/null; }
mutating() { grep -v '^status' "$UFW_LOG"; }
lno() { grep -nxF -- "$1" "$UFW_LOG" | head -n1 | cut -d: -f1; }
metakey() { grep "^$1=" "$META" 2>/dev/null; }
# in_order N... -- yes when every N is set and each is below the next.
in_order() {
    local prev="" n
    for n in "$@"; do
        [[ -n "$n" ]] || { echo no; return; }
        if [[ -n "$prev" && "$prev" -ge "$n" ]]; then echo no; return; fi
        prev="$n"
    done
    echo yes
}
A=10.164.0.50
B=10.164.0.51
rule() { printf 'allow from %s to any port %s proto tcp' "$1" "$2"; }

# ---- the parser: --gateway-from goes with --enable or --reset ----------------------------
# The real script, not root: the refusals come before the root check.
parse_run() {
    : > "$UFW_LOG"
    PRC=0
    POUT="$(bash "${TN_TEST_REPO}/firewall-setup.sh" "$@" 2>&1 < /dev/null)" || PRC=$?
}
tree devnet
BEFORE="$(snapshot)"
parse_run --gateway-from "$A"
check "parser: --gateway-from alone exits 1" 1 "$PRC"
check "parser: --gateway-from alone says it goes with --enable or --reset" yes "$(has "go with --enable or --reset" "$POUT")"
check "parser: --gateway-from alone runs no ufw" "" "$(cat "$UFW_LOG")"
parse_run --p2p-committee status --gateway-from "$A"
check "parser: --p2p-committee with --gateway-from exits 1" 1 "$PRC"
check "parser: --p2p-committee with --gateway-from: goes alone" yes "$(has "goes alone" "$POUT")"
check "parser: --p2p-committee with --gateway-from runs no ufw" "" "$(cat "$UFW_LOG")"
parse_run --p2p-committee on --gateway-from=none
check "parser: --p2p-committee with --gateway-from=none exits 1" 1 "$PRC"
check "parser: --p2p-committee with --gateway-from=none: goes alone" yes "$(has "goes alone" "$POUT")"
parse_run --status --gateway-from "$A"
check "parser: --status with --gateway-from exits 1" 1 "$PRC"
check "parser: --status with --gateway-from is refused" yes "$(has "go with --enable or --reset" "$POUT")"
check "parser: --status with --gateway-from runs no ufw" "" "$(cat "$UFW_LOG")"
check "parser refusals: the tree is as it was" "$BEFORE" "$(snapshot)"

# A bad source: refused, tree as it was, no mutating ufw call.
for v in 10.0.0.07 "${A},bogus" 300.1.2.3 "10.0.0.0/33"; do
    tree devnet "GATEWAY_ALLOW_FROM=${A}"
    BEFORE="$(snapshot)"
    drun --enable --gateway-from "$v"
    check "bad source ${v}: exits 1" 1 "$RC"
    check "bad source ${v}: tree as it was" "$BEFORE" "$(snapshot)"
    check "bad source ${v}: no mutating ufw call" "" "$(mutating)"
done
# A host with a gateway and no node: --gateway-from is refused.
tree -
mkdir -p "$GWD"
printf 'GATEWAY_META_VERSION=1\nNETWORK=devnet\nMODE=standalone\nFRONT=none\n' > "$GWMETA"
BEFORE="$(snapshot)"
NODE=0 drun --enable --gateway-from 10.0.0.1
check "no node: --enable --gateway-from exits 1" 1 "$RC"
check "no node: says a node is needed" yes "$(has "needs a node installed" "$OUT")"
check "no node: tree as it was" "$BEFORE" "$(snapshot)"
check "no node: no mutating ufw call" "" "$(mutating)"
NODE=0 drun --reset --gateway-from none
check "no node: --reset --gateway-from none exits 1" 1 "$RC"
check "no node: --reset --gateway-from none changes nothing" "" "$(mutating)"

# ---- devnet: the two rules per source, their place, the record ---------------------------
tree devnet
drun --enable --gateway-from "$A"
check_rc "devnet --enable --gateway-from: rc 0" 0 "$RC"
LOG="$(cat "$UFW_LOG")"
check_has "devnet --enable: the RPC rule" "$(rule "$A" 8545)" "$LOG"
check_has "devnet --enable: the health rule" "$(rule "$A" "$KP")" "$LOG"
check "devnet --enable: after the health-port block, before the default policy" yes \
    "$(in_order "$(lno "$(rule "$TN_KUMA_SRC" "$KP")")" "$(lno "$(rule "$A" 8545)")" "$(lno "$(rule "$A" "$KP")")" \
        "$(lno "default deny incoming")" "$(lno "--force enable")")"
check "devnet --enable: GATEWAY_ALLOW_FROM recorded" "GATEWAY_ALLOW_FROM=${A}" "$(metakey GATEWAY_ALLOW_FROM)"
check_has "devnet --enable: RPC rule in place" "$(rule "$A" 8545)" "$(cat "$RULES")"
check_has "devnet --enable: health rule in place" "$(rule "$A" "$KP")" "$(cat "$RULES")"
drun --reset
check_rc "devnet plain --reset: rc 0" 0 "$RC"
check_has "devnet plain --reset: ufw was reset" "--force reset" "$(cat "$UFW_LOG")"
check_has "devnet plain --reset: RPC rule re-applied" "$(rule "$A" 8545)" "$(cat "$RULES")"
check_has "devnet plain --reset: health rule re-applied" "$(rule "$A" "$KP")" "$(cat "$RULES")"
check "devnet plain --reset: the record kept" "GATEWAY_ALLOW_FROM=${A}" "$(metakey GATEWAY_ALLOW_FROM)"
drun --enable --gateway-from="${A},${B}"
check_rc "devnet --enable --gateway-from=A,B: rc 0" 0 "$RC"
check "devnet A,B: both recorded" "GATEWAY_ALLOW_FROM=${A},${B}" "$(metakey GATEWAY_ALLOW_FROM)"
check "devnet A,B: the four rules" "4" "$(grep -cE "^allow from (${A}|${B}) to any port (8545|${KP}) proto tcp$" "$RULES")"
check_lacks "devnet A,B: nothing of A deleted" "delete allow from ${A}" "$(cat "$UFW_LOG")"
drun --enable --gateway-from "$B"
check_rc "devnet A dropped: rc 0" 0 "$RC"
check_has "devnet A dropped: RPC rule deleted" "delete $(rule "$A" 8545)" "$(cat "$UFW_LOG")"
check_has "devnet A dropped: health rule deleted" "delete $(rule "$A" "$KP")" "$(cat "$UFW_LOG")"
check_lacks "devnet A dropped: no rule of A left" "from ${A} " "$(cat "$RULES")"
check "devnet A dropped: B's two rules stay" "2" "$(grep -cE "^allow from ${B} to any port (8545|${KP}) proto tcp$" "$RULES")"
check "devnet A dropped: the record is B" "GATEWAY_ALLOW_FROM=${B}" "$(metakey GATEWAY_ALLOW_FROM)"
drun --enable --gateway-from none
check_rc "devnet none: rc 0" 0 "$RC"
check_has "devnet none: B's RPC rule deleted" "delete $(rule "$B" 8545)" "$(cat "$UFW_LOG")"
check_has "devnet none: B's health rule deleted" "delete $(rule "$B" "$KP")" "$(cat "$UFW_LOG")"
check_lacks "devnet none: no gateway rule left" "from ${B} " "$(cat "$RULES")"
check "devnet none: GATEWAY_ALLOW_FROM unset" "" "$(metakey GATEWAY_ALLOW_FROM)"
check_has "devnet none: the monitor's health rule stays" "$(rule "$TN_KUMA_SRC" "$KP")" "$(cat "$RULES")"
drun --reset --gateway-from "$A"
check_rc "devnet --reset --gateway-from: rc 0" 0 "$RC"
check "devnet --reset --gateway-from: recorded" "GATEWAY_ALLOW_FROM=${A}" "$(metakey GATEWAY_ALLOW_FROM)"
check "devnet --reset --gateway-from: the two rules" "2" "$(grep -cE "^allow from ${A} to any port (8545|${KP}) proto tcp$" "$RULES")"
drun --reset --gateway-from none
check_rc "devnet --reset --gateway-from none: rc 0" 0 "$RC"
check "devnet --reset --gateway-from none: unset" "" "$(metakey GATEWAY_ALLOW_FROM)"
check_lacks "devnet --reset --gateway-from none: no gateway rule" "from ${A} " "$(cat "$RULES")"

# ---- mainnet: RPC_PORT from .node-meta, consecutive runs, a dropped source ----------------
tree mainnet SSH_ALLOW_FROM=203.0.113.7 RPC_PORT=8645
drun --enable --gateway-from "$A"
check_rc "mainnet --enable --gateway-from: rc 0" 0 "$RC"
check_has "mainnet --enable: RPC rule on RPC_PORT" "$(rule "$A" 8645)" "$(cat "$RULES")"
check_has "mainnet --enable: health rule" "$(rule "$A" "$KP")" "$(cat "$RULES")"
check_lacks "mainnet --enable: no rule on 8545" "port 8545 " "$(cat "$RULES")"
check "mainnet --enable: the P2P new-flow limit is loaded (committee mode off)" yes \
    "$(if [[ -e "$R/etc/telcoin/p2p-limit.nft" ]]; then echo yes; else echo no; fi)"
for n in 2 3; do
    drun --enable
    check_rc "mainnet plain --enable run ${n}: rc 0" 0 "$RC"
    check_has "mainnet plain --enable run ${n}: health rule still there" "$(rule "$A" "$KP")" "$(cat "$RULES")"
    check_has "mainnet plain --enable run ${n}: RPC rule still there" "$(rule "$A" 8645)" "$(cat "$RULES")"
    check_lacks "mainnet plain --enable run ${n}: the open health rule stays closed" "allow ${KP}/tcp" "$(cat "$RULES")"
done
drun --enable --gateway-from "$B"
check_rc "mainnet A dropped: rc 0" 0 "$RC"
check_has "mainnet A dropped: RPC rule deleted" "delete $(rule "$A" 8645)" "$(cat "$UFW_LOG")"
check_has "mainnet A dropped: health rule deleted" "delete $(rule "$A" "$KP")" "$(cat "$UFW_LOG")"
check_lacks "mainnet A dropped: no rule of A left" "from ${A} " "$(cat "$RULES")"
for n in 1 2; do
    drun --enable
    check "mainnet B, plain --enable run ${n}: B's two rules" "2" "$(grep -cE "^allow from ${B} to any port (8645|${KP}) proto tcp$" "$RULES")"
done
drun --reset
check_rc "mainnet plain --reset: rc 0" 0 "$RC"
check "mainnet plain --reset: B's two rules re-applied" "2" "$(grep -cE "^allow from ${B} to any port (8645|${KP}) proto tcp$" "$RULES")"

# ---- committee mode on: the gateway rules survive --enable and --reset --------------------
tree mainnet SSH_ALLOW_FROM=203.0.113.7 P2P_COMMITTEE=on "GATEWAY_ALLOW_FROM=${A}"
drun --enable
check_rc "committee on --enable: rc 0" 0 "$RC"
check "committee on --enable: the gateway's two rules" "2" "$(grep -cE "^allow from ${A} to any port (8545|${KP}) proto tcp$" "$RULES")"
check "committee on --enable: the committee resync ran" "committee-sync quiet" "$(cat "$FW_CALLS")"
check "committee on --enable: no P2P new-flow limit (committee mode is on)" no \
    "$(if [[ -e "$R/etc/telcoin/p2p-limit.nft" ]]; then echo yes; else echo no; fi)"
drun --reset
check_rc "committee on --reset: rc 0" 0 "$RC"
check "committee on --reset: the gateway's two rules" "2" "$(grep -cE "^allow from ${A} to any port (8545|${KP}) proto tcp$" "$RULES")"
check "committee on --reset: GATEWAY_ALLOW_FROM kept" "GATEWAY_ALLOW_FROM=${A}" "$(metakey GATEWAY_ALLOW_FROM)"

# ---- --json --enable, --json --status, the expected rules ---------------------------------
tree devnet
drun --json --enable --gateway-from "${A},${B}"
check_rc "--json --enable --gateway-from: rc 0" 0 "$RC"
check "--json --enable: a done line, ok" yes "$(has '"event":"done","ok":true' "$OUT")"
check "--json --enable: recorded" "GATEWAY_ALLOW_FROM=${A},${B}" "$(metakey GATEWAY_ALLOW_FROM)"
check "--json --enable: the four rules" "4" "$(grep -cE "^allow from (${A}|${B}) to any port (8545|${KP}) proto tcp$" "$RULES")"
JS="$(bash "$T/fw/driver.sh" --json --status 2>/dev/null < /dev/null)"
check "--json --status: gateway_from lists the sources" yes "$(has "\"gateway_from\":[\"${A}\",\"${B}\"]" "$JS")"
check "--json --status: gateway_from comes right before p2p_committee" yes \
    "$(has "\"gateway_from\":[\"${A}\",\"${B}\"],\"p2p_committee\":{" "$JS")"
PCT="${JS##*\"p2p_committee\":}"
check "--json --status: p2p_committee is the last key" "no no }}" \
    "$(has '"gateway_from"' "$PCT") $(has '"desired"' "$PCT") ${JS: -2}"
check "--json --status: the RPC row in desired" yes \
    "$(has "\"spec\":\"8545/tcp from ${A}\",\"label\":\"Worker gateway RPC\",\"source\":\"${A}\",\"ok\":true" "$JS")"
check "--json --status: the health row in desired" yes \
    "$(has "\"spec\":\"${KP}/tcp from ${A}\",\"label\":\"Worker gateway health\",\"source\":\"${A}\",\"ok\":true" "$JS")"
TAB="$(printf '\t')"
DES="$(CALL=desired_firewall_rules bash "$T/fw/driver.sh" 2>/dev/null < /dev/null)"
check_has "expected rules: the RPC row" "8545/tcp from ${B}${TAB}Worker gateway RPC${TAB}${B}" "$DES"
check_has "expected rules: the health row" "${KP}/tcp from ${B}${TAB}Worker gateway health${TAB}${B}" "$DES"
VIEW="$(CALL=view_status bash "$T/fw/driver.sh" 2>/dev/null < /dev/null | sed 's/\x1b\[[0-9;]*m//g')"
check "status screen: the gateway sources heading" yes "$(has "Worker gateway sources -- TCP 8545 (RPC) and ${KP} (health)" "$VIEW")"
check "status screen: a row per source" "yes yes" "$(has "$A" "$VIEW") $(has "$B" "$VIEW")"
# The status screen and the expected rules read ufw's display the way
# tn_gateway_from_rules_ok does: a /32 source shown bare, a CIDR shown by its
# network address still count as in place.
tree devnet
drun --enable --gateway-from "10.164.0.9/32,10.164.0.7/24"
check_rc "a /32 and a host-bits CIDR: --enable rc 0" 0 "$RC"
JS="$(UFW_AS_UFW=1 bash "$T/fw/driver.sh" --json --status 2>/dev/null < /dev/null)"
check "ufw's display: the /32 source's RPC row is satisfied" yes \
    "$(has "\"spec\":\"8545/tcp from 10.164.0.9/32\",\"label\":\"Worker gateway RPC\",\"source\":\"10.164.0.9/32\",\"ok\":true" "$JS")"
check "ufw's display: the CIDR source's health row is satisfied" yes \
    "$(has "\"spec\":\"${KP}/tcp from 10.164.0.7/24\",\"label\":\"Worker gateway health\",\"source\":\"10.164.0.7/24\",\"ok\":true" "$JS")"
VIEW="$(UFW_AS_UFW=1 CALL=view_status bash "$T/fw/driver.sh" 2>/dev/null < /dev/null | sed 's/\x1b\[[0-9;]*m//g')"
check "ufw's display: the status screen finds both sources' rules" "yes yes no" \
    "$(has "10.164.0.9/32: TCP 8545 and ${KP} allowed" "$VIEW") $(has "10.164.0.7/24: TCP 8545 and ${KP} allowed" "$VIEW") $(has "is not allowed" "$VIEW")"
tree devnet
JS="$(bash "$T/fw/driver.sh" --json --status 2>/dev/null < /dev/null)"
check "--json --status without a list: gateway_from is empty" yes "$(has '"gateway_from":[],"p2p_committee":{' "$JS")"

# ---- the baseline: no GATEWAY_ALLOW_FROM -> the ufw calls of before the gateway ------------
# Recorded from origin/main 2813343 (firewall-setup.sh and lib/) with this driver.
BASE_TESTNET_ENABLE="status
allow 22/tcp
delete allow 43174/tcp
allow from 104.155.184.201/32 to any port 43174 proto tcp
allow 49590/udp
allow 49594/udp
default deny incoming
default allow outgoing
--force enable"
BASE_TESTNET_RESET="status
--force reset
allow 22/tcp
delete allow 43174/tcp
allow from 104.155.184.201/32 to any port 43174 proto tcp
allow 49590/udp
allow 49594/udp
default deny incoming
default allow outgoing
--force enable"
BASE_MAINNET_ENABLE="status
allow from 203.0.113.7 to any port 22 proto tcp
delete allow 43174/tcp
delete allow from 104.155.184.201/32 to any port 43174 proto tcp
allow 49590/udp
allow 49594/udp
default deny incoming
default allow outgoing
delete allow 22/tcp
--force enable"
tree testnet
drun --enable
check "baseline testnet --enable: the ufw calls of before" "0 ${BASE_TESTNET_ENABLE}" "$RC $(cat "$UFW_LOG")"
tree testnet
drun --reset
check "baseline testnet --reset: the ufw calls of before" "0 ${BASE_TESTNET_RESET}" "$RC $(cat "$UFW_LOG")"
tree mainnet SSH_ALLOW_FROM=203.0.113.7 RPC_PORT=8645
drun --enable
check "baseline mainnet --enable: the ufw calls of before" "0 ${BASE_MAINNET_ENABLE}" "$RC $(cat "$UFW_LOG")"

# ---- a host with a gateway and no node ------------------------------------------------------
tree -
mkdir -p "$GWD" "$R/etc/caddy"
printf 'GATEWAY_META_VERSION=1\nNETWORK=devnet\nMODE=standalone\nFRONT=caddy\n' > "$GWMETA"
printf '# Caddyfile\n%s\nrpc.example.org {\n    reverse_proxy 127.0.0.1:8655\n}\n%s\n' "$TN_CADDY_GW_BEGIN" "$TN_CADDY_GW_END" > "$R/etc/caddy/Caddyfile"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/caddy"
chmod 0755 "$T/bin/caddy"
rc=0
NODE=0 CALL=caddy_serves_public_edge bash "$T/fw/driver.sh" > /dev/null 2>&1 < /dev/null || rc=$?
check_rc "caddy_serves_public_edge: only the gateway fence -> true" 0 "$rc"
NODE=0 drun --enable
check_rc "gateway host --enable: rc 0" 0 "$RC"
LOG="$(mutating)"
check_has "gateway host --enable: SSH" "allow 22/tcp" "$LOG"
check_has "gateway host --enable: 80" "allow 80/tcp" "$LOG"
check_has "gateway host --enable: 443" "allow 443/tcp" "$LOG"
check_lacks "gateway host --enable: no P2P rule" "/udp" "$LOG"
check_lacks "gateway host --enable: no health rule" "$KP" "$LOG"
check "gateway host --enable: ufw on" "ENABLED=yes" "$(cat "$R/etc/ufw/ufw.conf")"
check "gateway host --enable: no .node-meta written" no "$(if [[ -e "$META" ]]; then echo yes; else echo no; fi)"
printf 'example.org {\n    reverse_proxy 127.0.0.1:3000\n}\n' > "$R/etc/caddy/Caddyfile"
rc=0
NODE=0 CALL=caddy_serves_public_edge bash "$T/fw/driver.sh" > /dev/null 2>&1 < /dev/null || rc=$?
check_rc "caddy_serves_public_edge: a foreign Caddyfile -> false" 1 "$rc"

finish
