#!/usr/bin/env bash
# =============================================================================
# tools/tests/caddy_gateway_test.sh -- install-caddy.sh's third managed block, the
# worker gateway site: the block text (fences, v1 stamp, probe / POST / 405
# handlers, ports), every writer keeping the third block, teardown only when the
# last block goes, gateway-enable's no-op / rewrite / rollback, its refusals and its
# gate, rpc-advertise / rpc-unadvertise and rpc-disable / rpc-enable next to a
# gateway advertisement, rpc-enable's mainnet refusals (admission closed,
# GATEWAY_UPSTREAM), rpc-unadvertise's warning on a mainnet validator, rpc-advertise
# on a host with no node service yet, and the new phases through main (--json and
# human, both forms of the three new flags, usage errors, the older-library refusal).
#
#   bash tools/tests/run.sh tools/tests/caddy_gateway_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/caddy_gateway_test.sh
#
# Same fixture method as caddy_test.sh: the script is sourced from a copy without
# its `main "$@"` line; caddy, systemctl, ufw, install, ss and getent are PATH stubs;
# tn_write_root_file, tn_as_service_user, check_root, node_is_staked_validator and
# the DNS probes are functions; TN_ROOT_PREFIX points every path at the fixture.
# The node-info.yaml advertise path runs for real down to caddy_node_info_write,
# which records its arguments (adv_stubs, inside the case's subshell). A real Caddy
# checks the generated block in tools/tests/caddy_gateway_smoke.sh.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T="$TN_TEST_TMP"
export TN_ROOT_PREFIX="$T/root"
export TN_CADDY_RUN_PARENT="$T/run"
export TN_UPDATE_LOCK_FILE="$T/update.lock"
export TN_BACKUP_DIR="$T/backups"
export SYSCTL_LOG="$T/systemctl.log" UFW_LOG="$T/ufw.log"
RP="$TN_ROOT_PREFIX"
mkdir -p "$RP/etc/caddy" "$RP/etc/telcoin" "$T/run" "$T/bin" "$T/c"
printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nRPC_PORT=8545\n' > "$RP/etc/telcoin/.node-meta"

# --- PATH stubs ------------------------------------------------------------------------
cat > "$T/bin/caddy" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    version) echo "v2.8.4 h1:test" ;;
    validate) exit "${CADDY_VALIDATE_RC:-0}" ;;
    hash-password) read -r _ ; echo '$2a$14$abcdefghijklmnopqrstuv' ;;
esac
STUB
cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSCTL_LOG:?}"
case "$1" in
    is-active) exit "${CADDY_ACTIVE_RC:-0}" ;;
    is-failed) exit 1 ;;
    reload) exit "${RELOAD_RC:-0}" ;;
esac
exit 0
STUB
cat > "$T/bin/ufw" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${UFW_LOG:?}"
exit 0
STUB
# install -d (the admin drop-in directory after a teardown removed it) without -o/-g.
cat > "$T/bin/install" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "-d" ]; then for last; do :; done; mkdir -p "$last"; exit $?; fi
exit 1
STUB
cat > "$T/bin/ss" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$T/bin/getent" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "group caddy" ] && { echo "caddy:x:998:"; exit 0; }
exit 2
STUB
chmod +x "$T/bin/"*
PATH="$T/bin:/usr/local/bin:/usr/bin:/bin"
hash -r

grep -v '^main "\$@"$' "${TN_TEST_REPO}/install-caddy.sh" > "$T/c/install-caddy.sh"
ln -s "${TN_TEST_REPO}/lib" "$T/c/lib"
# shellcheck source=/dev/null
source "$T/c/install-caddy.sh"
set +e
trap tn_test_cleanup EXIT

export WRITES="$T/writes"
: > "$WRITES"
tn_write_root_file() {
    printf '%s %s %s\n' "${1#"$RP"}" "$2" "${3:-root}" >> "$WRITES"
    [[ -L "$1" || -d "$1" ]] && return 1
    cat > "$1"
}
tn_as_service_user() { "$@"; }
sleep() { :; }
check_root() { :; }
node_is_staked_validator() { return "${NSV_RC:-1}"; }
# check-dns without a network: the name resolves to this host's public address.
caddy_egress_ip() { echo 198.51.100.7; }
caddy_public_ip() { echo 198.51.100.7; }
caddy_resolve_domain() { echo 198.51.100.7; }
caddy_local_ips() { echo 10.0.0.5; }

# The advertise path below caddy_node_info_advertise: the lock, guard, wait and
# restart of caddy_test.sh's restart cases, and an editor that records
# "edit <mode> <http> <ws>". Called inside the case's subshell only.
ORDER="$T/order"
adv_stubs() {
    tn_local_rpc_url() { echo http://127.0.0.1:8545; }
    caddy_node_lock() { return 0; }
    tn_committee_down_guard() { echo guard >> "$ORDER"; return 0; }
    tn_wait_restart_window() { echo wait >> "$ORDER"; return 0; }
    caddy_node_info_can_edit() { return 0; }
    caddy_node_info_rpc_get() { echo "${NI_CUR:-none none}"; }
    caddy_node_info_write() { echo "edit $2 ${3:-none} ${4:-none}" >> "$ORDER"; return 0; }
    tn_resolve_service() { echo telcoin; }
    systemctl() { echo "systemctl $*" >> "$ORDER"; [[ "$1" == is-failed ]] && return 1; return 0; }
    # GET https://<host>/health (rpc-advertise's check of the URL): GW_URL_CODE
    # (default 200) and curl's exit GW_URL_RC (default 0); anything else: the node.
    curl() {
        case "$*" in
            *'https://'*'/health') printf '%s' "${GW_URL_CODE:-200}"; return "${GW_URL_RC:-0}" ;;
        esac
        echo '{"result":"0x7e1"}'
    }
}

# The library's tn_resolve_service (a unit file under TN_ROOT_PREFIX), for the cases
# that put it back after adv_stubs.
eval "lib_$(declare -f tn_resolve_service)"

CF="$RP/etc/caddy/Caddyfile"
NIF="$RP/data/node-info.yaml"
NM='NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nRPC_PORT=8545\n'
NMD='NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nRPC_PORT=8545\nDATA_DIR=/data\n'
# fresh [META] -- an empty fixture tree; META (printf %b) becomes .node-meta, '' = no node.
fresh() {
    rm -rf "$RP"
    mkdir -p "$RP/etc/caddy" "$RP/etc/telcoin" "$RP/etc/systemd/system/caddy.service.d" "$RP/data"
    if [[ -n "${1:-}" ]]; then printf '%b' "$1" > "$RP/etc/telcoin/.node-meta"; fi
    : > "$SYSCTL_LOG"; : > "$UFW_LOG"; : > "$WRITES"; : > "$ORDER"
    # shellcheck disable=SC2034 # read by caddy_mainnet_gate (sourced)
    CADDY_GATE_DONE=false
}
applies() { grep -cE '^(reload|restart) caddy$' "$SYSCTL_LOG"; }
gw_same() { caddy_current_gateway_block > "$T/gw.now"; if cmp -s "$T/gw.now" "$1"; then echo same; else echo differs; fi; }
tree_sum() { find "$RP" -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(cksum < "$f")" "${f#"$RP"}"; done; }
said() { if grep -qF -- "$1" "$T/out"; then echo yes; else echo "no: $(tail -n 3 "$T/out")"; fi; }
meta_has() { if grep -q "^$1=" "$RP/etc/telcoin/.node-meta"; then echo present; else echo absent; fi; }
# hbody NAME FILE -- the lines inside `<tab>handle NAME {` (NAME '' = the bare `handle {`).
hbody() {
    local h="\thandle $1 {"
    [[ -n "$1" ]] || h="\thandle {"
    awk -v h="$h" '$0==h {inb=1; next} inb && $0=="\t}" {exit} inb {print}' "$2"
}
mbody() { awk -v h="\t$1 {" '$0==h {inb=1; next} inb && $0=="\t}" {exit} inb {print}' "$2"; }
RPC_BLOCK="$T/rpc.block"
printf 'rpc.example.org {\n\treverse_proxy 127.0.0.1:8545\n}\n' > "$RPC_BLOCK"
# shellcheck disable=SC2034 # CADDY_PASSWORD is read by do_enable (sourced)
dash_on() { ( CADDY_PASSWORD='correct-horse-battery-staple'; do_enable "$1" admin ) >"$T/out" 2>&1; }

# --- the block text --------------------------------------------------------------------
check "fence constants from lib/common.sh" "# >>> tn-gateway >>>|# <<< tn-gateway <<<" "${TN_CADDY_GW_BEGIN:-}|${TN_CADDY_GW_END:-}"
GW="$T/gw.block"
( write_gateway_block gw1.example.org 8655 8656 "$GW" ) >"$T/out" 2>&1
check_rc "write_gateway_block rc 0" 0 $?
B="$(cat "$GW")"
check "block: first line is the v1 stamp" "# tn-gateway block v1" "$(head -n 1 "$GW")"
check_has "block: site line names the hostname" "gw1.example.org {" "$B"
check "block: braces balance" "$(tr -cd '{' < "$GW" | wc -c | tr -d ' ')" "$(tr -cd '}' < "$GW" | wc -c | tr -d ' ')"
P="$(mbody @probe "$GW")"
check_has "probe matcher: GET and HEAD" $'\t\tmethod GET HEAD' "$P"
check_has "probe matcher: the three paths" $'\t\tpath /health /ready /ready/any' "$P"
check_has "probe matcher: not an upgrade" $'\t\theader !Upgrade' "$P"
check "probe handler: the probe port" $'\t\treverse_proxy 127.0.0.1:8656' "$(hbody @probe "$GW")"
H="$(hbody '' "$GW")"
check_has "POST handler: the listen port" $'\t\treverse_proxy 127.0.0.1:8655' "$H"
check_has "POST handler: bodies capped at 2 MB" $'\t\t\tmax_size 2MB' "$H"
check_has "POST handler: CORS origin" $'\t\theader Access-Control-Allow-Origin "*"' "$H"
check_lacks "POST handler: no X-Forwarded-For override" "X-Forwarded-For" "$B"
check_has "WebSocket matcher: Upgrade: websocket" $'\t\theader_regexp wsup Upgrade (?i)websocket' "$(mbody @websocket "$GW")"
check "WebSocket handler: 405 with Allow" $'\t\theader Allow "POST, OPTIONS"\n\t\trespond 405' "$(hbody @websocket "$GW")"
check_has "non-POST matcher" $'\t@notpost not method POST OPTIONS' "$B"
check "non-POST handler: 405 with Allow" $'\t\theader Allow "POST, OPTIONS"\n\t\trespond 405' "$(hbody @notpost "$GW")"
check "preflight handler answers 200" yes "$(hbody @preflight "$GW" | grep -qx $'\t\trespond 200' && echo yes)"
check "handler order: preflight, websocket, probe, notpost, POST" "@preflight @websocket @probe @notpost {" \
    "$(grep -E $'^\thandle ' "$GW" | awk '{print $2}' | paste -sd' ' -)"
( write_gateway_block gw2.example.org 09200 9201 "$T/gw2.block" ) >"$T/out" 2>&1
check_rc "non-default ports: rc 0" 0 $?
check "non-default ports: probe handler" $'\t\treverse_proxy 127.0.0.1:9201' "$(hbody @probe "$T/gw2.block")"
check_has "non-default ports: POST handler (leading zero dropped)" $'\t\treverse_proxy 127.0.0.1:9200' "$(hbody '' "$T/gw2.block")"
check "non-default ports: read back by caddy_gateway_block_ports" "9200 9201" "$(caddy_gateway_block_ports < "$T/gw2.block")"
fresh "$NM"
( caddy_write_managed "" "" "$GW" ) >"$T/out" 2>&1
check_rc "caddy_write_managed, gateway block only: rc 0" 0 $?
check "managed file: one BEGIN fence line" 1 "$(grep -cxF -- "$TN_CADDY_GW_BEGIN" "$CF")"
check "managed file: one END fence line" 1 "$(grep -cxF -- "$TN_CADDY_GW_END" "$CF")"
check "managed file: first line inside the fence is the stamp" "# tn-gateway block v1" \
    "$(awk -v b="$TN_CADDY_GW_BEGIN" 'f {print; exit} $0==b {f=1}' "$CF")"
check "managed file: the block between the fences is the written block" same "$(gw_same "$GW")"

# --- every writer keeps the third block ----------------------------------------------
fresh "$NM"
( caddy_write_managed "" "" "$GW" ) >"$T/out" 2>&1
dash_on dash.example.org
check_rc "dashboard enable next to a gateway block: rc 0" 0 $?
check "dashboard enable: dashboard written" "dash.example.org" "$(caddy_current_dashboard_domain)"
check "dashboard enable: gateway block byte-identical" same "$(gw_same "$GW")"
( do_disable ) >"$T/out" 2>&1
check_rc "dashboard disable next to a gateway block: rc 0" 0 $?
check "dashboard disable: dashboard gone" "" "$(caddy_current_dashboard_block)"
check "dashboard disable: gateway block byte-identical" same "$(gw_same "$GW")"
check "dashboard disable: no teardown stub" 0 "$(grep -c 'external access disabled' "$CF")"
check "dashboard disable: 80/443 stay open" 0 "$(grep -c '^delete' "$UFW_LOG")"
check "dashboard disable: admin drop-in kept" yes "$([[ -f "$CADDY_ADMIN_DROPIN" ]] && echo yes)"
( do_gateway_disable ) >"$T/out" 2>&1
check_rc "gateway-disable, the last block: rc 0" 0 $?
check "last block gone: teardown stub" 1 "$(grep -c 'external access disabled' "$CF")"
check "last block gone: no gateway fence" 0 "$(grep -cxF -- "$TN_CADDY_GW_BEGIN" "$CF")"
check "last block gone: admin drop-in removed" no "$([[ -f "$CADDY_ADMIN_DROPIN" ]] && echo yes || echo no)"
check "last block gone: 80 and 443 closed" "delete allow 80/tcp|delete allow 443/tcp" "$(grep '^delete' "$UFW_LOG" | paste -sd'|' -)"

fresh "$NMD"
( caddy_write_managed "" "" "$GW" ) >"$T/out" 2>&1
before="$(tree_sum)"
( main --json --phase=rpc-enable --rpc-domain rpc.example.org --yes ) >"$T/ev" 2>"$T/out"
check_rc "rpc-enable next to a gateway block: refused (rc 1)" 1 $?
check "rpc-enable refusal names gateway-disable" yes "$(grep -q 'gateway-disable first' "$T/ev" && echo yes)"
check "rpc-enable refusal: tree byte-identical" same "$([[ "$(tree_sum)" == "$before" ]] && echo same)"
check "rpc-enable refusal: Caddy not reloaded" 0 "$(applies)"

fresh "$NMD"
printf 'original\n' > "$NIF"
( caddy_write_managed "" "$RPC_BLOCK" "$GW" ) >"$T/out" 2>&1
check "fixture: tn-rpc and tn-gateway blocks" "rpc.example.org gw1.example.org" "$(caddy_current_rpc_domain) $(caddy_current_gateway_domain)"
( adv_stubs; NI_CUR="https://rpc.example.org/ wss://rpc.example.org/"; do_rpc_disable ) >"$T/out" 2>&1
check_rc "rpc-disable next to a gateway block: rc 0" 0 $?
check "rpc-disable: tn-rpc block gone" no "$(caddy_block_present "$RPC_BEGIN" && echo yes || echo no)"
check "rpc-disable: gateway block byte-identical" same "$(gw_same "$GW")"
check "rpc-disable: no teardown" 0 "$(grep -c '^delete' "$UFW_LOG")"
check "rpc-disable without RPC_ADVERTISED_VIA: clears node-info as before" yes "$(grep -qx 'edit clear none none' "$ORDER" && echo yes)"

( caddy_write_managed "$T/none" "" ) >"$T/out" 2>&1
check_rc "caddy_write_managed with two arguments: rc 0" 0 $?
check "caddy_write_managed with two arguments: no gateway block" 0 "$(grep -cxF -- "$TN_CADDY_GW_BEGIN" "$CF")"

# --- teardown counts all three blocks --------------------------------------------------
fresh "$NM"
( caddy_write_managed "" "" "$GW" ) >"$T/out" 2>&1
dash_on dash.example.org
: > "$UFW_LOG"; : > "$SYSCTL_LOG"
( do_gateway_disable ) >"$T/out" 2>&1
check_rc "gateway-disable next to a dashboard: rc 0" 0 $?
check "gateway-disable: dashboard kept" "dash.example.org" "$(caddy_current_dashboard_domain)"
check "gateway-disable: gateway fence gone" 0 "$(grep -cxF -- "$TN_CADDY_GW_BEGIN" "$CF")"
check "gateway-disable: no teardown stub" 0 "$(grep -c 'external access disabled' "$CF")"
check "gateway-disable: 80/443 stay open" 0 "$(grep -c '^delete' "$UFW_LOG")"
check "gateway-disable: admin drop-in kept" yes "$([[ -f "$CADDY_ADMIN_DROPIN" ]] && echo yes)"
check "gateway-disable: one reload" "1 reload caddy" "$(applies) $(grep -E '^(reload|restart) caddy$' "$SYSCTL_LOG")"
( do_disable ) >"$T/out" 2>&1
check_rc "dashboard disable, the last block: rc 0" 0 $?
check "dashboard disable, last block: teardown stub" 1 "$(grep -c 'external access disabled' "$CF")"
check "dashboard disable, last block: admin drop-in removed" no "$([[ -f "$CADDY_ADMIN_DROPIN" ]] && echo yes || echo no)"
check "dashboard disable, last block: 80 and 443 closed" 2 "$(grep -c '^delete allow' "$UFW_LOG")"
before="$(tree_sum)"; : > "$SYSCTL_LOG"
( do_gateway_disable ) >"$T/out" 2>&1
check_rc "gateway-disable with no gateway block: rc 0" 0 $?
check "gateway-disable with no gateway block: nothing written, no reload" "same 0" "$([[ "$(tree_sum)" == "$before" ]] && echo same) $(applies)"

# --- gateway-enable: first run, no-op, new port, failed validate, rejected reload ------
fresh "$NM"
( do_gateway_enable gw1.example.org "" "" ) >"$T/out" 2>&1
check_rc "gateway-enable #1: rc 0" 0 $?
check "gateway-enable #1: one apply" 1 "$(applies)"
check "gateway-enable #1: block is write_gateway_block's (8655 / 8656)" same "$(gw_same "$GW")"
check "gateway-enable #1: 80 and 443 opened" "allow 80/tcp|allow 443/tcp" "$(paste -sd'|' - < "$UFW_LOG")"
check "gateway-enable #1: the node is not restarted" 0 "$(grep -c telcoin "$SYSCTL_LOG")"
w1="$(wc -l < "$WRITES")"; before="$(tree_sum)"
( do_gateway_enable GW1.Example.org. 8655 8656 ) >"$T/out" 2>&1
check_rc "gateway-enable #2 (same site): rc 0" 0 $?
check "gateway-enable #2: nothing written" "$w1" "$(wc -l < "$WRITES")"
check "gateway-enable #2: tree byte-identical" same "$([[ "$(tree_sum)" == "$before" ]] && echo same)"
check "gateway-enable #2: Caddy not reloaded" 1 "$(applies)"
check "gateway-enable #2: says so" yes "$(said 'nothing was written and Caddy was not reloaded')"
( do_gateway_enable gw1.example.org 9300 "" ) >"$T/out" 2>&1
check_rc "gateway-enable, new port: rc 0" 0 $?
check "gateway-enable, new port: rewritten" "9300 8656" "$(caddy_current_gateway_block | caddy_gateway_block_ports)"
check "gateway-enable, new port: one more reload" "2 reload caddy" "$(applies) $(grep -E '^(reload|restart) caddy$' "$SYSCTL_LOG" | tail -n 1)"
cp "$CF" "$T/cf.before"; n0="$(applies)"
( export CADDY_VALIDATE_RC=1; do_gateway_enable gw1.example.org 9400 "" ) >"$T/out" 2>&1
check_rc "gateway-enable, failed validate: rc 1" 1 $?
check "failed validate: live file unchanged" same "$(cmp -s "$CF" "$T/cf.before" && echo same)"
check "failed validate: no reload" "$n0" "$(applies)"
( export RELOAD_RC=1; do_gateway_enable gw1.example.org 9500 "" ) >"$T/out" 2>&1
check_rc "gateway-enable, rejected reload: rc 1" 1 $?
check "rejected reload: previous Caddyfile restored" same "$(cmp -s "$CF" "$T/cf.before" && echo same)"
check "rejected reload: says so" yes "$(said 'restored the previous Caddyfile')"

# --- gateway-enable keeps the dashboard; a block without the v1 stamp is stale --------
fresh "$NM"
dash_on dash.example.org
caddy_current_dashboard_block > "$T/dash.before"
( do_gateway_enable gw1.example.org "" "" ) >"$T/out" 2>&1
check_rc "gateway-enable next to a dashboard: rc 0" 0 $?
caddy_current_dashboard_block > "$T/dash.after"
check "gateway-enable: dashboard block byte-identical" same "$(cmp -s "$T/dash.before" "$T/dash.after" && echo same)"
sed '1d' "$GW" > "$T/gw.old"
( caddy_write_managed "$T/dash.after" "" "$T/gw.old" ) >"$T/out" 2>&1
( main --json --phase=gateway-status ) >"$T/ev" 2>"$T/out"
check "gateway-status: a block without the v1 stamp is stale" '"block_stale":true}' "$(grep -o '"block_stale":[a-z]*}' "$T/ev")"
: > "$SYSCTL_LOG"
( do_gateway_enable gw1.example.org "" "" ) >"$T/out" 2>&1
check "gateway-enable rewrites a stale block, one reload" "same 1" "$(gw_same "$GW") $(applies)"

# --- gateway-enable refusals (each leaves the tree byte-identical) --------------------
refused() { # refused NAME EXPECTED-TEXT DOMAIN [PORT] [PROBE]
    local name="$1" text="$2" rc
    before="$(tree_sum)"; : > "$SYSCTL_LOG"
    ( do_gateway_enable "$3" "${4:-}" "${5:-}" ) >"$T/out" 2>&1
    rc=$?
    check_rc "refused: ${name}" 1 "$rc"
    check "refused: ${name}: says why" yes "$(said "$text")"
    check "refused: ${name}: tree byte-identical, no reload" "same 0" "$([[ "$(tree_sum)" == "$before" ]] && echo same) $(applies)"
}
fresh "$NM"
( caddy_write_managed "" "$RPC_BLOCK" "" ) >"$T/out" 2>&1
refused "a tn-rpc block" "Run --phase=rpc-disable first" gw1.example.org
fresh "$NM"
dash_on dash.example.org
refused "the dashboard's hostname" "already serves the Node Manager dashboard" dash.example.org
refused "the dashboard's hostname, other case" "already serves the Node Manager dashboard" Dash.Example.org.
refused "port 1023" "invalid --gateway-port '1023'" gw1.example.org 1023
refused "port 65536" "invalid --gateway-port '65536'" gw1.example.org 65536
refused "port 8080 (Node Manager)" "invalid --gateway-port '8080'" gw1.example.org 8080
refused "port not a number" "invalid --gateway-port 'abc'" gw1.example.org abc
refused "probe port 8080" "invalid --gateway-probe-port '8080'" gw1.example.org 8655 8080
refused "probe port 70000" "invalid --gateway-probe-port '70000'" gw1.example.org 8655 70000
refused "the same two ports" "are both 9000" gw1.example.org 9000 9000
refused "an invalid hostname" "gateway domain" 'bad_host!'
( do_gateway_enable gw1.example.org "" "" ) >"$T/out" 2>&1
dash_on GW1.example.org
check_rc "control: dashboard on the gateway's hostname refused" 1 $?

# --- the gate ----------------------------------------------------------------------------
fresh 'NETWORK=mainnet\nOWNERSHIP_LAYOUT=2\nRPC_PORT=8545\nVALIDATOR_ADDRESS=0x1111111111111111111111111111111111111111\n'
before="$(tree_sum)"
( NSV_RC=0; do_gateway_enable gw1.example.org "" "" ) >"$T/out" 2>&1
check_rc "gate: staked mainnet validator refused" 1 $?
check "gate: staked mainnet validator: says why" yes "$(said 'is a staked validator')"
check "gate: staked mainnet validator: tree byte-identical" same "$([[ "$(tree_sum)" == "$before" ]] && echo same)"
fresh 'NETWORK=devnet\nOWNERSHIP_LAYOUT=2\nRPC_PORT=8545\n'
( do_gateway_enable gw1.example.org "" "" ) >"$T/out" 2>&1
check_rc "gate: devnet node allowed" 0 $?
fresh ""
mkdir -p "$RP/etc/telcoin/gateway"
printf 'GATEWAY_META_VERSION=1\n' > "$RP/etc/telcoin/gateway/gateway.meta"
( do_gateway_enable gw1.example.org "" "" ) >"$T/out" 2>&1
check_rc "gate: no node, gateway.meta present: allowed" 0 $?
check "gate: no node, gateway.meta present: block written" "gw1.example.org" "$(caddy_current_gateway_domain)"
rm -f "$RP/etc/telcoin/gateway/gateway.meta"
( do_gateway_disable ) >"$T/out" 2>&1
check_rc "A-6: gateway-disable is not gated (no node, no gateway.meta)" 0 $?
before="$(tree_sum)"
( do_gateway_enable gw1.example.org "" "" ) >"$T/out" 2>&1
check_rc "gate: no node, no gateway.meta: refused" 1 $?
check "gate: no node, no gateway.meta: says run setup-gateway.sh first" yes "$(said 'run setup-gateway.sh first')"
check "gate: no node, no gateway.meta: tree byte-identical" same "$([[ "$(tree_sum)" == "$before" ]] && echo same)"

# The block is current but Caddy is not running: no no-op, Caddy is started.
fresh "$NM"
( do_gateway_enable gw1.example.org "" "" ) >"$T/out" 2>&1
: > "$SYSCTL_LOG"
rm -f "$T/caddy-up"
( systemctl() {
      case "$1" in
          is-active) [[ -f "$T/caddy-up" ]] ;;
          restart) : > "$T/caddy-up"; command systemctl "$@" ;;
          *) command systemctl "$@" ;;
      esac
  }
  do_gateway_enable gw1.example.org 8655 8656 ) >"$T/out" 2>&1
check_rc "gateway-enable, block current, Caddy stopped: rc 0" 0 $?
check "gateway-enable, block current, Caddy stopped: says so" yes "$(said 'but Caddy is not running')"
check "gateway-enable, block current, Caddy stopped: Caddy started" "yes 1" "$([[ -f "$T/caddy-up" ]] && echo yes) $(applies)"
check "gateway-enable, block current, Caddy stopped: the block is unchanged" same "$(gw_same "$GW")"
# A public RPC site (rpc-enable) on this host: rpc-advertise and rpc-unadvertise refuse.
fresh "$NMD"
printf 'original\n' > "$NIF"
( caddy_write_managed "" "$RPC_BLOCK" "" ) >"$T/out" 2>&1
cp "$RP/etc/telcoin/.node-meta" "$T/nm.before"; : > "$ORDER"
( adv_stubs; do_rpc_advertise gw1.example.org ) >"$T/out" 2>&1
check_rc "rpc-advertise next to a tn-rpc site: refused" 1 $?
check "rpc-advertise next to a tn-rpc site: names rpc-disable" yes "$(said 'run install-caddy.sh --phase rpc-disable first')"
( adv_stubs; do_rpc_unadvertise ) >"$T/out" 2>&1
check_rc "rpc-unadvertise next to a tn-rpc site: refused" 1 $?
check "tn-rpc site: nothing edited, nothing restarted, .node-meta byte-identical" " same" \
    "$(cat "$ORDER") $(cmp -s "$RP/etc/telcoin/.node-meta" "$T/nm.before" && echo same)"

# --- rpc-advertise / rpc-unadvertise / rpc-disable / rpc-enable -----------------------
fresh "${NMD}PUBLIC_WS_URL=wss://old.example.org/\n"
printf 'original\n' > "$NIF"
( caddy_write_managed "" "" "$GW" ) >"$T/out" 2>&1
: > "$SYSCTL_LOG"; cp "$CF" "$T/cf.before"; w1="$(wc -l < "$WRITES")"
( adv_stubs; do_rpc_advertise gw1.example.org ) >"$T/out" 2>&1
check_rc "rpc-advertise: rc 0" 0 $?
check "rpc-advertise: https://<host>/ and no ws URL, guarded restart" \
    "edit set https://gw1.example.org/ none|guard|wait|guard|systemctl restart telcoin" \
    "$(grep -v '^systemctl is-' "$ORDER" | paste -sd'|' -)"
check "rpc-advertise: PUBLIC_RPC_DOMAIN" "gw1.example.org" "$(addon_meta_get PUBLIC_RPC_DOMAIN '')"
check "rpc-advertise: PUBLIC_RPC_URL" "https://gw1.example.org" "$(addon_meta_get PUBLIC_RPC_URL '')"
check "rpc-advertise: RPC_ADVERTISED_VIA" "gateway" "$(addon_meta_get RPC_ADVERTISED_VIA '')"
check "rpc-advertise: PUBLIC_WS_URL unset" absent "$(meta_has PUBLIC_WS_URL)"
check "rpc-advertise: Caddyfile untouched, Caddy not reloaded" "same 0" "$(cmp -s "$CF" "$T/cf.before" && echo same) $(applies)"
check "rpc-advertise: no Caddy write" 0 "$(sed -n "$((w1 + 1)),\$p" "$WRITES" | grep -c '/etc/caddy/')"
# GET https://<host>/health must answer 200 from this host before the record changes.
for bad in "502 0 HTTP 502" "000 28 no answer within 5 s" "000 60 a TLS or certificate error"; do
    code="${bad%% *}"; rest="${bad#* }"; crc="${rest%% *}"; want="${rest#* }"
    cp "$NIF" "$T/nif.before"; cp "$RP/etc/telcoin/.node-meta" "$T/nm.before"; : > "$ORDER"
    ( adv_stubs; GW_URL_CODE="$code"; GW_URL_RC="$crc"; do_rpc_advertise gw9.example.org ) >"$T/out" 2>&1
    check_rc "rpc-advertise, /health ${want}: refused" 1 $?
    check "rpc-advertise, /health ${want}: says what was asked, what came back and why" "yes yes yes" \
        "$(said 'advertise https://gw9.example.org/') $(said "got ${want}") $(said 'breaks transaction forwarding')"
    check "rpc-advertise, /health ${want}: node-info.yaml and .node-meta byte-identical" "same same" \
        "$(cmp -s "$NIF" "$T/nif.before" && echo same) $(cmp -s "$RP/etc/telcoin/.node-meta" "$T/nm.before" && echo same)"
    check "rpc-advertise, /health ${want}: no edit, no restart" "" "$(cat "$ORDER")"
done
: > "$ORDER"
( adv_stubs; NI_CUR="https://gw1.example.org/ none"; do_rpc_unadvertise ) >"$T/out" 2>&1
check_rc "rpc-unadvertise: rc 0" 0 $?
check "rpc-unadvertise: clears node-info" yes "$(grep -qx 'edit clear none none' "$ORDER" && echo yes)"
check "rpc-unadvertise: the four keys gone" "absent absent absent absent" \
    "$(meta_has PUBLIC_RPC_DOMAIN) $(meta_has PUBLIC_RPC_URL) $(meta_has PUBLIC_WS_URL) $(meta_has RPC_ADVERTISED_VIA)"
check "rpc-unadvertise: Caddyfile untouched" same "$(cmp -s "$CF" "$T/cf.before" && echo same)"

fresh ""
( adv_stubs; do_rpc_advertise gw1.example.org ) >"$T/out" 2>&1
check_rc "rpc-advertise on a host with no node: refused" 1 $?
check "rpc-advertise, no node: says why" yes "$(said 'this host has no telcoin node')"
( adv_stubs; do_rpc_unadvertise ) >"$T/out" 2>&1
check_rc "rpc-unadvertise on a host with no node: refused" 1 $?
check "no node: nothing edited" "" "$(cat "$ORDER")"

fresh "${NMD}PUBLIC_RPC_DOMAIN=gw1.example.org\nPUBLIC_RPC_URL=https://gw1.example.org\nRPC_ADVERTISED_VIA=gateway\n"
printf 'original\n' > "$NIF"
( caddy_write_managed "" "$RPC_BLOCK" "" ) >"$T/out" 2>&1
( adv_stubs; do_rpc_disable ) >"$T/out" 2>&1
check_rc "rpc-disable with RPC_ADVERTISED_VIA=gateway: rc 0" 0 $?
check "rpc-disable via gateway: site removed" no "$(caddy_block_present "$RPC_BEGIN" && echo yes || echo no)"
check "rpc-disable via gateway: node-info not edited, node not restarted" "" "$(grep -v ' caddy$' "$ORDER")"
check "rpc-disable via gateway: node-info.yaml unchanged" original "$(cat "$NIF")"
check "rpc-disable via gateway: keys kept" "gw1.example.org https://gw1.example.org gateway" \
    "$(addon_meta_get PUBLIC_RPC_DOMAIN '') $(addon_meta_get PUBLIC_RPC_URL '') $(addon_meta_get RPC_ADVERTISED_VIA '')"
check "rpc-disable via gateway: says rpc-unadvertise" yes "$(said 'rpc-unadvertise removes that advertisement')"

before="$(tree_sum)"
( main --json --phase=rpc-enable --rpc-domain rpc.example.org --yes ) >"$T/ev" 2>"$T/out"
check_rc "rpc-enable while RPC_ADVERTISED_VIA=gateway: refused" 1 $?
check "rpc-enable refusal names rpc-unadvertise" yes "$(grep -q 'rpc-unadvertise first' "$T/ev" && echo yes)"
check "rpc-enable refusal names the advertised URL" yes "$(grep -qF 'advertises https://gw1.example.org/ for a worker gateway' "$T/ev" && echo yes)"
check "rpc-enable refusal: tree byte-identical" same "$([[ "$(tree_sum)" == "$before" ]] && echo same)"

fresh "${NMD}PUBLIC_RPC_DOMAIN=rpc.example.org\nPUBLIC_RPC_URL=https://rpc.example.org\n"
printf 'original\n' > "$NIF"
( caddy_write_managed "" "$RPC_BLOCK" "" ) >"$T/out" 2>&1
( adv_stubs; NI_CUR="https://rpc.example.org/ wss://rpc.example.org/"; do_rpc_disable ) >"$T/out" 2>&1
check_rc "rpc-disable without the key: rc 0" 0 $?
check "rpc-disable without the key: clears node-info" yes "$(grep -qx 'edit clear none none' "$ORDER" && echo yes)"
check "rpc-disable without the key: PUBLIC_RPC_DOMAIN removed" absent "$(meta_has PUBLIC_RPC_DOMAIN)"

# --- mainnet: rpc-enable refuses a validator and a node a gateway fronts ----------------
NMM='NETWORK=mainnet\nOWNERSHIP_LAYOUT=2\nRPC_PORT=8545\nDATA_DIR=/data\nVALIDATOR_ADDRESS=0x1111111111111111111111111111111111111111\n'
GWMETA='PUBLIC_RPC_DOMAIN=gw1.example.org\nPUBLIC_RPC_URL=https://gw1.example.org\nRPC_ADVERTISED_VIA=gateway\n'
rpc_enable_refused() { # rpc_enable_refused NAME META EXPECTED-TEXT
    fresh "$2"
    printf 'original\n' > "$NIF"
    before="$(tree_sum)"
    ( main --json --phase=rpc-enable --rpc-domain rpc.example.org --yes ) >"$T/ev" 2>"$T/out"
    check_rc "rpc-enable, ${1}: refused (rc 1)" 1 $?
    check "rpc-enable, ${1}: says why" yes "$(grep -qF -- "$3" "$T/ev" && echo yes)"
    check "rpc-enable, ${1}: tree byte-identical, Caddy not reloaded" "same 0" \
        "$([[ "$(tree_sum)" == "$before" ]] && echo same) $(applies)"
}
rpc_enable_refused "mainnet, admission closed" "${NMM}ADMISSION_MODE=closed\n" \
    "This mainnet node runs admission closed, as a validator does."
check "rpc-enable, mainnet closed: names rpc-advertise" yes "$(grep -qF -- 'Advertise the gateway with --phase=rpc-advertise --rpc-domain <name>.' "$T/ev" && echo yes)"
check "rpc-enable, mainnet closed, nothing recorded: no recorded URL named" 0 "$(grep -c 'already advertises' "$T/ev")"
rpc_enable_refused "mainnet closed, advertised via a gateway" "${NMM}ADMISSION_MODE=closed\n${GWMETA}" "runs admission closed"
check "rpc-enable, mainnet closed via a gateway: never told to rpc-unadvertise" 0 "$(grep -c 'rpc-unadvertise first' "$T/ev")"
check "rpc-enable, mainnet closed via a gateway: names the recorded URL and how to change the name" "yes 0" \
    "$(grep -qF -- 'node-info.yaml already advertises https://gw1.example.org/ for the worker gateway; --phase=rpc-advertise --rpc-domain <name> changes the name.' "$T/ev" && echo yes) $(grep -c 'Advertise the gateway with' "$T/ev")"
rpc_enable_refused "mainnet, GATEWAY_UPSTREAM set" "${NMM}ADMISSION_MODE=open\nGATEWAY_UPSTREAM=10.0.0.9\n" \
    "GATEWAY_UPSTREAM=10.0.0.9: a worker gateway fronts this node"
check "rpc-enable, mainnet upstream: names gateway_upstream=off" yes "$(grep -qF -- '--set gateway_upstream=off first' "$T/ev" && echo yes)"
rpc_enable_refused "mainnet open, advertised via a gateway" "${NMM}ADMISSION_MODE=open\n${GWMETA}" "rpc-unadvertise first"
rpc_enable_refused "mainnet, ADMISSION_MODE twice" "${NMM}ADMISSION_MODE=open\nADMISSION_MODE=closed\n" \
    "ADMISSION_MODE is set more than once"
# Off mainnet neither refusal applies; on mainnet a node that is neither reaches the stake gate.
fresh "${NMD}ADMISSION_MODE=closed\nGATEWAY_UPSTREAM=10.0.0.9\n"
( caddy_rpc_enable_precheck rpc.example.org "" ) >"$T/out" 2>&1
check_rc "rpc-enable, testnet closed with GATEWAY_UPSTREAM: not refused" 0 $?
fresh "${NMM}ADMISSION_MODE=open\n"
( caddy_rpc_enable_precheck rpc.example.org "" ) >"$T/out" 2>&1
check_rc "rpc-enable, mainnet open, no upstream, not staked: not refused" 0 $?
( NSV_RC=0; caddy_rpc_enable_precheck rpc.example.org "" ) >"$T/out" 2>&1
check_rc "rpc-enable, mainnet open, staked: the stake gate refuses" 1 $?
check "rpc-enable, mainnet open, staked: says so" yes "$(said 'is a staked validator')"

# --- rpc-unadvertise on a mainnet validator warns that nothing forwards to it -------------
NOFWD='This validator now advertises no RPC URL, so other nodes cannot forward transactions to it'
for c in "closed 1" "open 0"; do
    adm="${c% *}"
    fresh "${NMM}ADMISSION_MODE=${adm}\n${GWMETA}"
    printf 'original\n' > "$NIF"
    ( adv_stubs; NI_CUR="https://gw1.example.org/ none"; do_rpc_unadvertise ) >"$T/out" 2>&1
    check_rc "rpc-unadvertise, mainnet ${adm}: rc 0" 0 $?
    check "rpc-unadvertise, mainnet ${adm}: cleared, keys gone" "yes absent" \
        "$(grep -qx 'edit clear none none' "$ORDER" && echo yes) $(meta_has RPC_ADVERTISED_VIA)"
    check "rpc-unadvertise, mainnet ${adm}: the no-forwarding warning" "${c#* }" "$(grep -cF -- "$NOFWD" "$T/out")"
done
fresh "${NMM}ADMISSION_MODE=closed\n${GWMETA}"
printf 'original\n' > "$NIF"
( adv_stubs; caddy_node_info_can_edit() { return 1; }; NI_CUR="https://gw1.example.org/ none"; do_rpc_unadvertise ) >"$T/out" 2>&1
check_rc "rpc-unadvertise, mainnet closed, node-info.yaml not editable: rc 0" 0 $?
check "rpc-unadvertise, not editable: says the URL is still there, not the warning" "yes 0" \
    "$(said 'still advertises the removed endpoint') $(grep -cF -- "$NOFWD" "$T/out")"

# --- rpc-advertise before the node's service exists ---------------------------------------
# No node unit on mainnet: nothing can answer /health yet, so a failure is a warning
# and the record is written. Off mainnet, with NETWORK unreadable, or with a unit the
# refusal is unchanged.
for c in "testnet|${NMD}" "NETWORK twice|NETWORK=mainnet\n${NMD}"; do
    fresh "${c#*|}"
    printf 'original\n' > "$NIF"
    before="$(tree_sum)"
    ( adv_stubs; tn_resolve_service() { lib_tn_resolve_service "$@"; }
      GW_URL_CODE=000; GW_URL_RC=6; main --phase=rpc-advertise --rpc-domain gw9.example.org ) >"$T/out" 2>&1
    check_rc "rpc-advertise, ${c%%|*}, no node unit, /health fails: refused" 1 $?
    check "rpc-advertise, ${c%%|*}, no node unit: the refusal, not the warning" "yes 0" \
        "$(said 'breaks transaction forwarding') $(grep -c 'is not verified' "$T/out")"
    check "rpc-advertise, ${c%%|*}, no node unit: tree byte-identical, no edit" "same " \
        "$([[ "$(tree_sum)" == "$before" ]] && echo same) $(cat "$ORDER")"
done
fresh "${NMM}ADMISSION_MODE=closed\n"
printf 'original\n' > "$NIF"
( adv_stubs; tn_resolve_service() { lib_tn_resolve_service "$@"; }
  GW_URL_CODE=000; GW_URL_RC=6; main --phase=rpc-advertise --rpc-domain gw9.example.org ) >"$T/out" 2>&1
check_rc "rpc-advertise, no node unit, /health fails: rc 0" 0 $?
check "rpc-advertise, no node unit: warns not verified, why, and who checks later" "yes yes yes yes" \
    "$(said 'https://gw9.example.org/ is not verified') $(said 'got the name does not resolve') \
$(said 'nothing can answer before the node and its gateway run') $(said 'check-node.sh verifies it later')"
check "rpc-advertise, no node unit: https://<host>/ written, no ws URL, no restart" "edit set https://gw9.example.org/ none" \
    "$(grep -v '^systemctl is-' "$ORDER" | paste -sd'|' -)"
check "rpc-advertise, no node unit: the three .node-meta keys" "gw9.example.org https://gw9.example.org gateway" \
    "$(addon_meta_get PUBLIC_RPC_DOMAIN '') $(addon_meta_get PUBLIC_RPC_URL '') $(addon_meta_get RPC_ADVERTISED_VIA '')"
check "rpc-advertise, no node unit: open items name the URL and the restart" "yes yes" \
    "$(said 'Open items: https://gw9.example.org/ not verified; node not restarted') $(said 'Worker gateway advertisement set: https://gw9.example.org/')"
fresh "${NMM}ADMISSION_MODE=closed\n"
printf 'original\n' > "$NIF"
( adv_stubs; tn_resolve_service() { lib_tn_resolve_service "$@"; }
  GW_URL_CODE=000; GW_URL_RC=6; main --json --phase=rpc-advertise --rpc-domain gw9.example.org ) >"$T/ev" 2>"$T/out"
check_rc "json rpc-advertise, no node unit, /health fails: rc 0" 0 $?
check "json rpc-advertise, no node unit: the warning once, done ok naming it" "1 1" \
    "$(grep -c '"event":"warn","msg":"https://gw9.example.org/ is not verified' "$T/ev") \
$(grep '"event":"done","ok":true' "$T/ev" | grep -c 'https://gw9.example.org/ not verified')"
fresh "${NMM}ADMISSION_MODE=closed\n"
printf 'original\n' > "$NIF"
: > "$RP/etc/systemd/system/telcoin.service"
cp "$NIF" "$T/nif.before"; cp "$RP/etc/telcoin/.node-meta" "$T/nm.before"
( adv_stubs; tn_resolve_service() { lib_tn_resolve_service "$@"; }
  GW_URL_CODE=000; GW_URL_RC=6; do_rpc_advertise gw9.example.org ) >"$T/out" 2>&1
check_rc "rpc-advertise, node unit, /health fails: refused" 1 $?
check "rpc-advertise, node unit: the refusal, not the warning" "yes 0" \
    "$(said 'breaks transaction forwarding') $(grep -c 'is not verified' "$T/out")"
check "rpc-advertise, node unit: node-info.yaml and .node-meta byte-identical, no edit" "same same " \
    "$(cmp -s "$NIF" "$T/nif.before" && echo same) $(cmp -s "$RP/etc/telcoin/.node-meta" "$T/nm.before" && echo same) $(cat "$ORDER")"

# --- main: --json ----------------------------------------------------------------------
GS_RE='^\{"installed":(true|false),"running":(true|false),"enabled":(true|false),"domain":"[^"]*","port":([0-9]+|null),"probe_port":([0-9]+|null),"block_stale":(true|false)\}$'
done_lines() { grep -c '"event":"done"' "$T/ev"; }
done_ok() { grep '"event":"done"' "$T/ev" | grep -c '"ok":true'; }
fresh "$NMD"
printf 'original\n' > "$NIF"
( main --json --phase=gateway-status ) >"$T/ev" 2>"$T/out"
check_rc "json gateway-status, no block: rc 0" 0 $?
check "json gateway-status, no block: one object, nulls" \
    '{"installed":true,"running":true,"enabled":false,"domain":"","port":null,"probe_port":null,"block_stale":false}' "$(cat "$T/ev")"
( main --json --phase gateway-enable --gateway-domain gw2.example.org --gateway-port=9200 --gateway-probe-port 9201 ) >"$T/ev" 2>"$T/out"
check_rc "json gateway-enable (--gateway-domain X, --gateway-port=N, --gateway-probe-port N): rc 0" 0 $?
check "json gateway-enable: exactly one done line, ok" "1 1" "$(done_lines) $(done_ok)"
( main --json --phase gateway-status ) >"$T/ev" 2>"$T/out"
check "json gateway-status: one line" 1 "$(wc -l < "$T/ev" | tr -d ' ')"
check "json gateway-status: the contract's keys, numbers for the ports" yes "$([[ "$(cat "$T/ev")" =~ $GS_RE ]] && echo yes)"
check "json gateway-status: values" '{"installed":true,"running":true,"enabled":true,"domain":"gw2.example.org","port":9200,"probe_port":9201,"block_stale":false}' "$(cat "$T/ev")"
( main --json --phase=gateway-enable --gateway-domain=gw2.example.org --gateway-port 9210 --gateway-probe-port=9211 ) >"$T/ev" 2>"$T/out"
check_rc "json gateway-enable (--gateway-domain=X, --gateway-port N, --gateway-probe-port=N): rc 0" 0 $?
check "json gateway-enable #2: one done line, ok" "1 1" "$(done_lines) $(done_ok)"
check "json gateway-enable #2: both forms parsed" "9210 9211" "$(caddy_current_gateway_block | caddy_gateway_block_ports)"
( main --json --phase=gateway-enable --gateway-domain=gw2.example.org --gateway-port 9210 --gateway-probe-port=9211 ) >"$T/ev" 2>"$T/out"
check "json gateway-enable, unchanged: one done line, says nothing written" "1 1" "$(done_lines) $(grep -c 'nothing written, Caddy not reloaded' "$T/ev")"
( main --json --phase=gateway-check-dns --gateway-domain gw2.example.org ) >"$T/ev" 2>"$T/out"
check_rc "json gateway-check-dns: rc 0" 0 $?
check "json gateway-check-dns: one object for the hostname" "1 1" "$(wc -l < "$T/ev" | tr -d ' ') $(grep -c '^{"domain":"gw2.example.org",.*"propagated":true' "$T/ev")"
( main --json --phase=gateway-check-dns --gateway-domain='bad_host!' ) >"$T/ev" 2>"$T/out"
check_rc "json gateway-check-dns, invalid name: rc 1" 1 $?
check "json gateway-check-dns, invalid name: error field" 1 "$(grep -c '"error":"invalid domain' "$T/ev")"
( adv_stubs; main --json --phase=rpc-advertise --rpc-domain=gw2.example.org ) >"$T/ev" 2>"$T/out"
check_rc "json rpc-advertise: rc 0" 0 $?
check "json rpc-advertise: one done line, ok" "1 1" "$(done_lines) $(done_ok)"
( adv_stubs; NI_CUR="https://gw2.example.org/ none"; main --json --phase rpc-unadvertise ) >"$T/ev" 2>"$T/out"
check_rc "json rpc-unadvertise: rc 0" 0 $?
check "json rpc-unadvertise: one done line, ok" "1 1" "$(done_lines) $(done_ok)"
( main --json --phase=gateway-disable ) >"$T/ev" 2>"$T/out"
check_rc "json gateway-disable: rc 0" 0 $?
check "json gateway-disable: one done line, ok" "1 1" "$(done_lines) $(done_ok)"
( main --json --phase=gateway-enable --gateway-domain=gw2.example.org --gateway-port=8080 ) >"$T/ev" 2>"$T/out"
check_rc "json gateway-enable refused: rc 1" 1 $?
check "json gateway-enable refused: one done line, ok:false" "1 0" "$(done_lines) $(done_ok)"

# --- main: human mode --------------------------------------------------------------------
human() { ( main "$@" ) >"$T/out" 2>&1; }
human --phase=gateway-enable --gateway-domain gw3.example.org
check_rc "human gateway-enable: rc 0" 0 $?
check "human gateway-enable: says enabled" yes "$(said 'Worker gateway site enabled at https://gw3.example.org/')"
human --phase gateway-enable --gateway-domain=gw3.example.org
check_rc "human gateway-enable again: rc 0" 0 $?
check "human gateway-enable again: nothing written" yes "$(said 'nothing was written and Caddy was not reloaded')"
human --phase=gateway-status
check_rc "human gateway-status: rc 0" 0 $?
check "human gateway-status: the site and its ports" yes "$(said 'https://gw3.example.org/  (POST -> 127.0.0.1:8655, probes -> 127.0.0.1:8656)')"
human --phase=gateway-check-dns --gateway-domain gw3.example.org
check_rc "human gateway-check-dns: rc 0" 0 $?
check "human gateway-check-dns: names the hostname" yes "$(said 'gw3.example.org')"
( adv_stubs; main --phase=rpc-advertise --rpc-domain gw3.example.org ) >"$T/out" 2>&1
check_rc "human rpc-advertise: rc 0" 0 $?
check "human rpc-advertise: says so" yes "$(said 'Worker gateway advertisement set: https://gw3.example.org/')"
( adv_stubs; NI_CUR="https://gw3.example.org/ none"; main --phase=rpc-unadvertise ) >"$T/out" 2>&1
check_rc "human rpc-unadvertise: rc 0" 0 $?
check "human rpc-unadvertise: says so" yes "$(said 'Worker gateway advertisement removed.')"
human --phase=gateway-disable
check_rc "human gateway-disable: rc 0" 0 $?
check "human gateway-disable: says so" yes "$(said 'The worker gateway site is removed.')"

# --- main: usage errors and the older library -----------------------------------------
for flag in --gateway-domain --gateway-port --gateway-probe-port; do
    ( main --json --phase=gateway-enable "$flag" ) >"$T/ev" 2>"$T/out"
    check_rc "json: ${flag} as the last word: usage error rc 2" 2 $?
    check "json: ${flag} as the last word: error + done ok:false" "1 1" \
        "$(grep -c "\"event\":\"error\",\"msg\":\"${flag} needs a value" "$T/ev") $(grep -c '"event":"done","ok":false' "$T/ev")"
    human --phase=gateway-enable "$flag"
    check_rc "human: ${flag} as the last word: usage error rc 2" 2 $?
done
( unset -f tn_gateway_installed; main --json --phase=gateway-status ) >"$T/ev" 2>"$T/out"
check_rc "older library (no tn_gateway_installed): rc 2" 2 $?
check "older library: error + done name what is missing" 2 "$(grep -c 'lacks tn_gateway_installed' "$T/ev")"
( unset TN_CADDY_GW_BEGIN TN_CADDY_GW_END; main --json --phase=gateway-enable --gateway-domain gw1.example.org ) >"$T/ev" 2>"$T/out"
check_rc "older library (no fence names): rc 2" 2 $?
check "older library: names both fences" 2 "$(grep -c 'lacks TN_CADDY_GW_BEGIN, TN_CADDY_GW_END' "$T/ev")"
( unset -f tn_gateway_installed; main --phase=gateway-status ) >"$T/out" 2>&1
check_rc "older library, human mode: rc 2" 2 $?

finish
