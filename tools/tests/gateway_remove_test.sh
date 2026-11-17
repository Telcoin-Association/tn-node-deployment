#!/usr/bin/env bash
# =============================================================================
# tools/tests/gateway_remove_test.sh -- which worker gateway remove-node.sh may
# remove (remove_gateway, its callers on a host with only a node's leftovers).
#
# remove_gateway removes a gateway when a node unit is removed in the same run
# ("node"), or when gateway.meta says MODE=same-host. A gateway that runs on its
# own (MODE=standalone, or a gateway.meta with no readable MODE) on a host where
# only a node's leftovers are found is left whole, in the menu and under --json:
# the output points at setup-gateway.sh --remove. A same-host gateway's removal
# says when node-info.yaml still advertises it (.node-meta RPC_ADVERTISED_VIA).
#   bash tools/tests/run.sh tools/tests/gateway_remove_test.sh
#   docker run --rm --network none -v "$PWD:/w:ro" -w /w bash:3.2 \
#       bash tools/tests/run.sh tools/tests/gateway_remove_test.sh
# remove-node.sh is sourced from a copy without its common.sh source line and
# its `main "$@"` line. systemctl and docker are PATH stubs that log their
# calls; the steps of a leftover removal that reach past the fixture tree (the
# node unit, the host files, the private alerts) are stand-ins that log too.
# TN_ROOT_PREFIX points every path at the fixture tree.
# Maintainer tooling (not updater-tracked). bash 3.2 safe.
# =============================================================================
set -u
# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T="$TN_TEST_TMP"
R="$T/fx"
export TN_ROOT_PREFIX="$R"
export TN_UPDATE_LOCK_FILE="$T/update.lock"
export CALLS="$T/calls"
mkdir -p "$T/bin" "$T/rn" "$R"
: > "$CALLS"

cat > "$T/bin/systemctl" <<'STUB'
printf 'systemctl %s\n' "$*" >> "${CALLS:?}"
case "$1" in is-enabled|is-active) exit 3 ;; esac
exit 0
STUB
cat > "$T/bin/docker" <<'STUB'
printf 'docker %s\n' "$*" >> "${CALLS:?}"
exit 0
STUB
chmod +x "$T/bin/"*
PATH="$T/bin:$PATH"
export PATH
hash -r

eval "$(tn_test_source_common)"
sed -e '/^main "\$@"$/d' -e 's|^source "\${SCRIPT_DIR}/lib/common.sh"$|: lib/common.sh is already sourced|' \
    "$TN_TEST_REPO/remove-node.sh" > "$T/rn/remove-node.sh"
ln -s "$TN_TEST_REPO/lib" "$T/rn/lib"
# shellcheck source=/dev/null
source "$T/rn/remove-node.sh"
set +e
check "remove-node.sh copy: common.sh source line dropped" 1 "$(grep -c ': lib/common.sh is already sourced' "$T/rn/remove-node.sh")"

# Stand-ins for the steps that reach past the fixture tree.
CONFIRM_ANSWER=yes
confirm() { [[ "$CONFIRM_ANSWER" == "yes" ]]; }
detect_data_dir() { printf '%s\n' "$R/var/lib/telcoin"; }
stop_and_disable_service() { printf 'stand-in stop_and_disable_service %s\n' "$*" >> "$CALLS"; return 0; }
remove_node_host_files() { printf 'stand-in remove_node_host_files\n' >> "$CALLS"; return 0; }
remove_alerts() { return 0; }
report_orphaned_groups() { return 0; }

GWUNIT="$R/etc/systemd/system/telcoin-gateway.service"
GWDIR="$R/etc/telcoin/gateway"
GWIMG="us-docker.pkg.dev/telcoin-network/tn-public/worker-gateway@sha256:$(printf '%064d' 0 | tr 0 a)"

# fresh -- a host with an EMPTY node data directory and nothing else of a node.
fresh() {
    rm -rf "$R"
    mkdir -p "$R/etc/telcoin" "$R/etc/systemd/system" "$R/etc/caddy" "$R/var/lib/telcoin"
    : > "$CALLS"
}
# mkgw MODE -- gateway.meta (MODE= on its line; "" = no MODE line), unit, Caddy block.
mkgw() {
    mkdir -p "$GWDIR"
    {
        printf '%s\n' GATEWAY_META_VERSION=1 NETWORK=devnet
        [[ -z "$1" ]] || printf 'MODE=%s\n' "$1"
        printf '%s\n' FRONT=caddy DOMAIN=gw.example.org "IMAGE=$GWIMG" UPSTREAM_HOST=10.0.0.5 RPC_PORT=8545
    } > "$GWDIR/gateway.meta"
    chmod 0600 "$GWDIR/gateway.meta"
    printf '[Service]\nExecStart=/usr/bin/docker run --name telcoin-gateway\n' > "$GWUNIT"
    printf '%s\n' "# >>> tn-gateway >>>" "gw.example.org {" "}" "# <<< tn-gateway <<<" > "$R/etc/caddy/Caddyfile"
}
snap() { (cd "$R" && find . -print | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort); }
has() { if grep -qF -- "$1" <<< "$2"; then echo yes; else echo no; fi; }
gw_files() { printf '%s %s\n' "$([[ -f "$GWDIR/gateway.meta" ]] && echo meta || echo no-meta)" "$([[ -f "$GWUNIT" ]] && echo unit || echo no-unit)"; }
# the calls that change something (the menu's container scan only reads)
changes() { grep -vE '^systemctl is-|^docker ps ' "$CALLS"; }
POINTER='remove it with: sudo bash setup-gateway.sh --remove'

# --- a standalone gateway and an empty node data directory: the menu ----------
fresh; mkgw standalone
before="$(snap)"
# shellcheck disable=SC2034  # read by the sourced remove-node.sh
(INSTALLED_UNITS=(); show_detected) < /dev/null > "$T/o" 2>&1
rc=$?
OUT="$(cat "$T/o")"
check_rc "standalone + empty data dir, menu: exit 0" 0 "$rc"
check "standalone + empty data dir, menu: the pointer" yes "$(has "$POINTER" "$OUT")"
check "standalone + empty data dir, menu: nothing removed (even with a yes)" "$before" "$(snap)"
check "standalone + empty data dir, menu: no systemctl or docker change" "" "$(changes)"

# --- the same host under --json -----------------------------------------------
fresh; mkgw standalone
before="$(snap)"
# shellcheck disable=SC2034  # read by the sourced remove-node.sh
(RM_JSON=true; json_remove validator service) 3> "$T/j" > "$T/o" 2> "$T/e"
rc=$?
check_rc "standalone + empty data dir, --json: rc 1 (no node)" 1 "$rc"
check "standalone + empty data dir, --json: the pointer as an event" 1 "$(grep -c '"event":"log".*setup-gateway.sh --remove' "$T/j")"
check "standalone + empty data dir, --json: no node installed" 1 "$(grep -c '"event":"error","msg":"no node installed' "$T/j")"
check "standalone + empty data dir, --json: nothing removed" "$before" "$(snap)"
check "standalone + empty data dir, --json: no systemctl or docker change" "" "$(changes)"

# --- a gateway.meta with no MODE counts as standalone ---------------------------
fresh; mkgw ""
before="$(snap)"
# shellcheck disable=SC2034  # read by the sourced remove-node.sh
(RM_JSON=true; json_remove validator service) 3> "$T/j" > "$T/o" 2> "$T/e"
check "no MODE, --json: nothing removed, the pointer" "$before 1" "$(snap) $(grep -c 'setup-gateway.sh --remove' "$T/j")"

# --- a standalone gateway next to real node leftovers: kept, leftovers kept -----
fresh; mkgw standalone
printf 'NETWORK=devnet\n' > "$R/etc/telcoin/.node-meta"
before="$(snap)"
# shellcheck disable=SC2034  # read by the sourced remove-node.sh
(INSTALLED_UNITS=(); show_detected) < /dev/null > "$T/o" 2>&1
OUT="$(cat "$T/o")"
check "standalone + node leftovers, menu: everything kept, the pointer" "yes yes" \
    "$([[ "$(snap)" == "$before" ]] && echo yes) $(has "$POINTER" "$OUT")"
check "standalone + node leftovers, menu: says why the leftovers stay" yes "$(has 'removing them would take the gateway' "$OUT")"
# shellcheck disable=SC2034  # read by the sourced remove-node.sh
(RM_JSON=true; json_remove validator service) 3> "$T/j" > "$T/o" 2> "$T/e"
check "standalone + node leftovers, --json: rc 1, kept, says why" "1 yes yes" \
    "$? $([[ "$(snap)" == "$before" ]] && echo yes) $(has 'remove the gateway first' "$(cat "$T/j")")"

# --- remove_gateway itself ------------------------------------------------------
fresh; mkgw standalone
RM_JSON=false
OUT="$(remove_gateway 2>&1)"
check "remove_gateway, standalone, no node removed: kept, the pointer" "meta unit yes" "$(gw_files) $(has "$POINTER" "$OUT")"
check "remove_gateway, standalone, no node removed: no call" "" "$(changes)"
OUT="$(remove_gateway node 2>&1)"
check "remove_gateway node (a node unit goes in this run): a standalone gateway is removed" "no-meta no-unit" "$(gw_files)"

fresh; mkgw same-host
printf '%s\n' NETWORK=devnet RPC_ADVERTISED_VIA=gateway PUBLIC_RPC_URL=https://gw.example.org > "$R/etc/telcoin/.node-meta"
OUT="$(remove_gateway 2>&1)"
check "remove_gateway, same-host: removed as before" "no-meta no-unit" "$(gw_files)"
check "remove_gateway, same-host: the call sequence as before" "systemctl disable --now telcoin-gateway.service
systemctl stop telcoin-gateway.service
docker rm -f telcoin-gateway
systemctl daemon-reload
systemctl reset-failed telcoin-gateway.service" "$(changes)"
check "remove_gateway, advertised via gateway: says node-info.yaml still advertises it, names rpc-unadvertise" "yes yes" \
    "$(has 'node-info.yaml still advertises https://gw.example.org' "$OUT") $(has 'install-caddy.sh --phase rpc-unadvertise' "$OUT")"
check "remove_gateway, advertised via gateway: the keys are kept" "2" "$(grep -cE '^(RPC_ADVERTISED_VIA|PUBLIC_RPC_URL)=' "$R/etc/telcoin/.node-meta")"

# --- a same-host gateway with the node's leftovers, --json: removed as before ---
fresh; mkgw same-host
printf 'NETWORK=devnet\n' > "$R/etc/telcoin/.node-meta"
# shellcheck disable=SC2034  # read by the sourced remove-node.sh
(RM_JSON=true; json_remove validator service) 3> "$T/j" > "$T/o" 2> "$T/e"
check "same-host + node leftovers, --json: the gateway is removed" "no-meta no-unit" "$(gw_files)"
check "same-host + node leftovers, --json: its removal step is an event" 1 "$(grep -c '"event":"step","msg":"Removing the worker gateway' "$T/j")"

finish
