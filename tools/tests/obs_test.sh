#!/usr/bin/env bash
# =============================================================================
# tools/tests/obs_test.sh -- lib/observability.sh and setup-observability.sh: the
# push URL is empty off testnet/devnet, the Alloy tarball install fails closed (a
# 404 for the zip or its SHA256SUMS, a mismatch, a missing line), Grafana's apt key
# is pinned by fingerprint, the native unit's account and sandbox lines, the node log
# dir (NODE_LOG_DIR) in the reth flags and in config.alloy's __path__, its creation
# without a recursive chown, the committee guard before a node restart, and the
# health check refused while ufw is not active.
#
#   bash tools/tests/obs_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/obs_test.sh
#
# curl, gpg, unzip, install and getent are PATH stubs; tn_write_root_file and
# tn_root_dir_ok are replaced by functions (the fixture tree is not root-owned).
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T="$TN_TEST_TMP"
export TN_ROOT_PREFIX="$T/root"
export TN_UPDATE_LOCK_FILE="$T/update.lock"
export CURL_LOG="$T/curl.log" INSTALL_LOG="$T/install.log"
RP="$TN_ROOT_PREFIX"
mkdir -p "$RP/etc/telcoin" "$T/bin" "$T/so"
printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\n' > "$RP/etc/telcoin/.node-meta"

# curl: -o FILE; the URL picks the body. ZIP_RC / SUMS_RC make that download fail.
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --proto|--max-time) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
printf '%s\n' "$url" >> "${CURL_LOG:?}"
case "$url" in
    *.zip) [ "${ZIP_RC:-0}" = "0" ] || exit "$ZIP_RC"; printf 'zipbytes\n' > "$out" ;;
    */SHA256SUMS) [ "${SUMS_RC:-0}" = "0" ] || exit "$SUMS_RC"; printf '%s\n' "${SUMS_BODY:-}" > "$out" ;;
    *gpg.key) printf 'ARMORED\n' > "$out" ;;
    *) exit 22 ;;
esac
STUB
cat > "$T/bin/unzip" <<'STUB'
#!/usr/bin/env bash
printf 'binary\n' > alloy-linux-amd64
STUB
cat > "$T/bin/install" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${INSTALL_LOG:?}"
STUB
cat > "$T/bin/gpg" <<'STUB'
#!/usr/bin/env bash
out="" show=false last=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --show-keys) show=true; shift ;;
        --homedir) shift 2 ;;
        *) last="$1"; shift ;;
    esac
done
if [ "$show" = true ]; then
    printf 'pub:-:3072:1:X:1::::::scESC:\nfpr:::::::::%s:\n' "${GPG_FPR:-}"
    exit 0
fi
cp "$last" "$out"
STUB
cat > "$T/bin/getent" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "group telcoin-log" ] && [ "${HAS_LOG_GROUP:-1}" = "1" ] && { echo "telcoin-log:x:997:"; exit 0; }
exit 2
STUB
chmod +x "$T/bin/"*
PATH="$T/bin:/usr/local/bin:/usr/bin:/bin"
hash -r

eval "$(tn_test_source_common)"
set +e

WRITES="$T/writes"
: > "$WRITES"
tn_write_root_file() { printf '%s %s\n' "$1" "$2" >> "$WRITES"; cat > /dev/null; }
uname() { echo x86_64; }

# --- push URL ---------------------------------------------------------------------------
check "testnet: the adiri hub" "$OBS_PUSH_URL_TESTNET" "$(NETWORK=testnet obs_effective_push_url)"
check "mainnet: empty" "" "$(NETWORK=mainnet obs_effective_push_url)"
check "mainnet with an override: still empty" "" "$(NETWORK=mainnet OBS_PUSH_URL=https://x.example/push obs_effective_push_url)"
check "mainnet metrics: empty" "" "$(NETWORK=mainnet OBS_METRICS_PUSH_URL=https://x.example/w obs_effective_metrics_url)"
check "network unset: empty" "" "$(NETWORK='' obs_effective_push_url)"
check "devnet without a URL: empty" "" "$(NETWORK=devnet obs_effective_push_url)"
check "devnet override kept" "https://d.example/push" "$(NETWORK=devnet OBS_PUSH_URL=https://d.example/push obs_effective_push_url)"
( NETWORK=mainnet; ENABLE_OBSERVABILITY=true; ENABLE_METRICS=false; obs_enable "tok-0123456789abcdef" ) >"$T/out" 2>&1
check_rc "obs_enable refuses on mainnet" 1 $?

# --- Alloy tarball fails closed ---------------------------------------------------------------
ZIPSUM="$(printf 'zipbytes\n' | sha256sum | cut -d' ' -f1)"
tarball() { : > "$INSTALL_LOG"; ( _obs_install_alloy_tarball ) >"$T/out" 2>&1; }
ZIP_RC=22 tarball; check_rc "zip 404: refused" 1 $?
check "zip 404: nothing installed" "" "$(cat "$INSTALL_LOG")"
SUMS_RC=22 tarball; check_rc "SHA256SUMS 404: refused" 1 $?
check "SHA256SUMS 404: nothing installed" "" "$(cat "$INSTALL_LOG")"
check "SHA256SUMS 404: said" "yes" "$(grep -q 'checksum file' "$T/out" && echo yes)"
SUMS_BODY="$(printf '%064d  alloy-linux-amd64.zip' 0)" tarball; check_rc "checksum mismatch: refused" 1 $?
check "mismatch: nothing installed" "" "$(cat "$INSTALL_LOG")"
SUMS_BODY="${ZIPSUM}  alloy-linux-arm64.zip" tarball; check_rc "no line for this asset: refused" 1 $?
check "no line: nothing installed" "" "$(cat "$INSTALL_LOG")"
export SUMS_BODY="${ZIPSUM} *alloy-linux-amd64.zip"
tarball
check "verified zip: installed to /usr/local/bin/alloy" "yes" "$(grep -q '/usr/local/bin/alloy$' "$INSTALL_LOG" && echo yes)"
unset SUMS_BODY

# --- Grafana apt key ------------------------------------------------------------------------------
: > "$WRITES"
( export GPG_FPR=0000000000000000000000000000000000000000; _obs_grafana_key "$T/grafana.gpg" ) >"$T/out" 2>&1
check_rc "wrong Grafana key refused" 1 $?
check "wrong Grafana key: nothing written" "" "$(cat "$WRITES")"
( export GPG_FPR="$OBS_GRAFANA_KEY_FPR"; _obs_grafana_key "$T/grafana.gpg" ) >"$T/out" 2>&1
check_rc "pinned Grafana key installed" 0 $?
check "pinned Grafana key written 0644" "$T/grafana.gpg 0644" "$(cat "$WRITES")"
check "constant: Grafana fingerprint checked 2026-10-15" "B53AE77BADB630A683046005963FA27710458545" "$OBS_GRAFANA_KEY_FPR"

# --- native unit -------------------------------------------------------------------------------------
unit="$(obs_alloy_unit_text /usr/bin/alloy /etc/telcoin/alloy/telcoin-alloy.env telcoin-log /srv/tn-data)"
printf '%s\n' "$unit" > "$T/unit"
for l in "User=telcoin-alloy" "Group=telcoin-alloy" "SupplementaryGroups=telcoin-log" \
         "ProtectSystem=strict" "ReadWritePaths=/var/lib/telcoin-alloy" "StateDirectory=telcoin-alloy" \
         "InaccessiblePaths=-/var/lib/telcoin -/etc/credstore.encrypted -/etc/telcoin/bls-passphrase -/srv/tn-data" \
         "PrivateDevices=yes" "NoNewPrivileges=yes" "CapabilityBoundingSet=" "ProtectProc=invisible" \
         "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX"; do
    check "unit has: $l" "yes" "$(grep -qxF -- "$l" "$T/unit" && echo yes)"
done
check "unit never runs as the node user" "no" "$(grep -qx 'User=telcoin' "$T/unit" && echo yes || echo no)"
obs_alloy_unit_text /usr/bin/alloy /e "" > "$T/unit2"
check "no telcoin-log group: no SupplementaryGroups line" "no" "$(grep -q '^SupplementaryGroups' "$T/unit2" && echo yes || echo no)"

# --- node log dir ------------------------------------------------------------------------------------
check "binary flags use /var/log/telcoin/node" "yes" \
    "$(grep -q -- '--log.file.directory /var/log/telcoin/node ' <<< "$(obs_reth_log_flags binary)" && echo yes)"
check "docker flags unchanged" "yes" "$(grep -q -- '--log.file.directory /home/nonroot/logs ' <<< "$(obs_reth_log_flags docker)" && echo yes)"
printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nNODE_LOG_DIR=/srv/logs/node\n' > "$RP/etc/telcoin/.node-meta"
check "NODE_LOG_DIR from .node-meta" "yes" "$(grep -q -- '--log.file.directory /srv/logs/node ' <<< "$(obs_reth_log_flags binary)" && echo yes)"
ENABLE_OBSERVABILITY=true ENABLE_METRICS=false _obs_slice_alloy "${TN_TEST_REPO}/observability/config.alloy" "$T/cfg" /var/log/telcoin/node
check "native config.alloy tails the node log dir" "yes" "$(grep -qF '"/var/log/telcoin/node/telcoin-network-logs/reth.log*"' "$T/cfg" && echo yes)"
check "native config.alloy has no old path" "no" "$(grep -qF '"/var/log/telcoin/telcoin-network-logs/' "$T/cfg" && echo yes || echo no)"
ENABLE_OBSERVABILITY=true ENABLE_METRICS=false _obs_slice_alloy "${TN_TEST_REPO}/observability/config.alloy" "$T/cfg2" ""
check "docker config.alloy keeps the vendored path" "yes" "$(grep -qF '"/var/log/telcoin/telcoin-network-logs/reth.log*"' "$T/cfg2" && echo yes)"

tn_root_dir_ok() { return 0; }
: > "$INSTALL_LOG"
printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\n' > "$RP/etc/telcoin/.node-meta"
out="$(obs_prepare_node_log_dir 2>/dev/null)"; check_rc "node log dir created" 0 $?
check "node log dir printed" "/var/log/telcoin/node" "$out"
check "install -d as the service user, group telcoin-log, 2750" "-d -o telcoin -g telcoin-log -m 2750 -- /var/log/telcoin/node" "$(cat "$INSTALL_LOG")"
( export HAS_LOG_GROUP=0; obs_prepare_node_log_dir ) >/dev/null 2>&1; check_rc "no telcoin-log group: refused" 1 $?
printf 'NETWORK=testnet\nNODE_LOG_DIR=/a\nNODE_LOG_DIR=/b\n' > "$RP/etc/telcoin/.node-meta"
( obs_prepare_node_log_dir ) >/dev/null 2>&1; check_rc "duplicated NODE_LOG_DIR: refused" 1 $?
printf 'NETWORK=testnet\nNODE_LOG_DIR=relative/dir\n' > "$RP/etc/telcoin/.node-meta"
( obs_prepare_node_log_dir ) >/dev/null 2>&1; check_rc "relative NODE_LOG_DIR: refused" 1 $?
printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\n' > "$RP/etc/telcoin/.node-meta"
check "no recursive or service-user chown left in the lib" "0" \
    "$(grep -v '^[[:space:]]*#' "${TN_TEST_REPO}/lib/observability.sh" | grep -cE 'chown -R|chown "\$\{SERVICE_USER\}' || true)"
printf 'NETWORK=testnet\nENABLE_METRICS=true\nENABLE_METRICS=false\n' > "$RP/etc/telcoin/.node-meta"
( obs_disable_logs ) >/dev/null 2>&1; check_rc "duplicated ENABLE_METRICS stops obs_disable_logs" 1 $?
printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\n' > "$RP/etc/telcoin/.node-meta"

# --- committee guard ------------------------------------------------------------------------------------
REAL_CDG="$(declare -f tn_committee_down_guard)"
REAL_WAIT="$(declare -f tn_wait_restart_window)"
tn_committee_down_guard() { return "${CDG_RC:-0}"; }
( CDG_RC=1; obs_quorum_guard ) >/dev/null 2>&1; check_rc "quorum risk: no restart" 1 $?
( CDG_RC=2; obs_quorum_guard ) >/dev/null 2>&1; check_rc "guard rc 2 (unreadable where it counts): no restart" 1 $?
( CDG_RC=0; obs_quorum_guard ) >/dev/null 2>&1; check_rc "guard passes" 0 $?
( CDG_RC=1; TN_ALLOW_QUORUM_RISK=1; obs_quorum_guard ) >/dev/null 2>&1; check_rc "guard rc 1 + TN_ALLOW_QUORUM_RISK=1: restart" 0 $?
( CDG_RC=2; TN_ALLOW_QUORUM_RISK=1; obs_quorum_guard ) >/dev/null 2>&1; check_rc "guard rc 2 + TN_ALLOW_QUORUM_RISK=1: restart" 0 $?
eval "$REAL_CDG"

# The real guard with the committee unreadable: the node votes (CvvActive) and no RPC
# answers. Testnet warns and restarts; mainnet and an unknown network refuse unless
# TN_ALLOW_QUORUM_RISK=1; a mainnet node whose mode cannot be read refuses when it is
# staked and restarts when it is not.
tn_node_mode() { [[ -n "${GUARD_MODE:-}" ]] && printf '%s\n' "$GUARD_MODE"; [[ -n "${GUARD_MODE:-}" ]]; }
tn_epoch_info() { return 1; }
tn_rpc_call() { return 1; }
tn_genesis_chain_id() { return 1; }
node_is_staked_validator() { return "${NSV_RC:-0}"; }
# The public RPC serves the network's chain but gives no committee (the chain-id
# check itself is quorum_guard_test's).
REAL_CHAIN="$(declare -f _tn_rpc_chain_is)"
_tn_rpc_chain_is() { return 0; }
guard_case() { # guard_case NAME EXPECTED-RC META-LINES [ENV=VAL...]
    local name="$1" want="$2" meta="$3"
    shift 3
    printf '%b\n' "$meta" > "$RP/etc/telcoin/.node-meta"
    ( for kv in "$@"; do export "${kv?}"; done; obs_quorum_guard ) >"$T/guard.out" 2>&1
    check_rc "real guard: ${name}" "$want" $? || sed "s/^/      /" "$T/guard.out"
}
guard_case "testnet, committee unreadable: restart" 0 'NETWORK=testnet' GUARD_MODE=CvvActive
guard_case "mainnet voting node, committee unreadable: refused" 1 'NETWORK=mainnet' GUARD_MODE=CvvActive
check "real guard: the refusal is said" "yes" "$(grep -q 'Not restarting: the committee could not be read' "$T/guard.out" && echo yes)"
guard_case "mainnet with TN_ALLOW_QUORUM_RISK=1: restart" 0 'NETWORK=mainnet' GUARD_MODE=CvvActive TN_ALLOW_QUORUM_RISK=1
guard_case "unknown network, committee unreadable: refused" 1 'OWNERSHIP_LAYOUT=2' GUARD_MODE=CvvActive
guard_case "mainnet, mode unreadable, staked: refused" 1 'NETWORK=mainnet\nVALIDATOR_ADDRESS=0x1111111111111111111111111111111111111111' NSV_RC=0
guard_case "mainnet, mode unreadable, not staked: restart" 0 'NETWORK=mainnet\nVALIDATOR_ADDRESS=0x1111111111111111111111111111111111111111' NSV_RC=1
unset -f tn_node_mode tn_epoch_info tn_rpc_call tn_genesis_chain_id node_is_staked_validator
eval "$REAL_CHAIN"
printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\n' > "$RP/etc/telcoin/.node-meta"

# obs_restart_window: the guard first, then the epoch wait, right before the restart; the
# guard runs even when the wait helper is missing.
ORDER="$T/order"
tn_committee_down_guard() {
    echo guard >> "$ORDER"
    if grep -q wait "$ORDER"; then return "${CDG_AFTER_RC:-${CDG_RC:-0}}"; fi
    return "${CDG_RC:-0}"
}
tn_wait_restart_window() { echo wait >> "$ORDER"; return "${WAIT_RC:-0}"; }
: > "$ORDER"; ( obs_restart_window ) >/dev/null 2>&1; check_rc "restart window: rc 0" 0 $?
check "restart window: guard, wait, guard" "guard wait guard" "$(paste -sd' ' "$ORDER")"
: > "$ORDER"; ( CDG_AFTER_RC=1; obs_restart_window ) >/dev/null 2>&1; check_rc "restart window: guard refuses after the wait, rc 1" 1 $?
check "restart window: the second guard ran after the wait" "guard wait guard" "$(paste -sd' ' "$ORDER")"
: > "$ORDER"; ( CDG_RC=1; obs_restart_window ) >/dev/null 2>&1; check_rc "restart window: guard refuses, rc 1" 1 $?
check "restart window: no wait after a refusal" "guard" "$(paste -sd' ' "$ORDER")"
: > "$ORDER"; ( CDG_RC=2; obs_restart_window ) >/dev/null 2>&1; check_rc "restart window: guard rc 2, rc 1" 1 $?
: > "$ORDER"; ( WAIT_RC=3; obs_restart_window ) >/dev/null 2>&1; check_rc "restart window: a failed wait, rc 1" 1 $?
unset -f tn_wait_restart_window
: > "$ORDER"; ( obs_restart_window ) >"$T/out" 2>&1; check_rc "restart window without the wait helper: restart after the guard" 0 $?
check "restart window without the wait helper: the guard still ran" "guard" "$(paste -sd' ' "$ORDER")"
check "restart window without the wait helper: warned" "yes" "$(grep -q 'has no tn_wait_restart_window' "$T/out" && echo yes)"
: > "$ORDER"; ( CDG_RC=1; obs_restart_window ) >/dev/null 2>&1; check_rc "restart window without the wait helper: guard refusal still stops it" 1 $?
eval "$REAL_CDG"
eval "$REAL_WAIT"

# --- setup-observability: health check needs an active ufw ------------------------------------------
# The copy does not source lib/common.sh again (its readonly constants are set).
grep -v -e '^main "\$@"$' -e '^source "\${SCRIPT_DIR}/lib/common.sh"$' "${TN_TEST_REPO}/setup-observability.sh" > "$T/so/setup-observability.sh"
ln -s "${TN_TEST_REPO}/lib" "$T/so/lib"
# shellcheck source=/dev/null
source "$T/so/setup-observability.sh"
set +e
ufw_installed() { return "${UFW_INST_RC:-0}"; }
ufw_active() { return "${UFW_ACT_RC:-0}"; }
( UFW_ACT_RC=1; health_firewall_ready ) >"$T/out" 2>&1; check_rc "ufw inactive: health check refused" 1 $?
check "ufw inactive: said" "yes" "$(grep -q 'ufw is inactive' "$T/out" && echo yes)"
( UFW_INST_RC=1; health_firewall_ready ) >"$T/out" 2>&1; check_rc "ufw missing: health check refused" 1 $?
( health_firewall_ready ) >"$T/out" 2>&1; check_rc "ufw active: health check allowed" 0 $?
MIG_LOG="$T/mig.log"
: > "$MIG_LOG"
tn_migrate_ownership() { echo migrate >> "$MIG_LOG"; return 0; }
pause() { :; }
health_flag_add() { printf 'called\n' > "$T/flag"; return 0; }
rm -f "$T/flag"
( UFW_ACT_RC=1; enable_health ) >"$T/out" 2>&1
check "ufw inactive: --healthcheck not added" "no" "$([[ -e "$T/flag" ]] && echo yes || echo no)"
check "ufw inactive: refused by the firewall check" "yes" "$(grep -q 'ufw is inactive' "$T/out" && echo yes)"
# The menu session takes the lock without the ownership migration; an action that
# changes something migrates first.
: > "$MIG_LOG"
( so_lock_begin ) >"$T/out" 2>&1; check_rc "menu session lock rc 0" 0 $?
check "menu session lock: no ownership migration" "" "$(cat "$MIG_LOG")"
( TN_ASSUME_YES=true; obs_disable_logs() { :; }; disable_logging ) >"$T/out" 2>&1
check "menu disable: ownership migration first" "migrate" "$(cat "$MIG_LOG")"
: > "$MIG_LOG"
( tn_migrate_ownership() { echo migrate >> "$MIG_LOG"; return 3; }; TN_ASSUME_YES=true
  obs_disable_logs() { echo disabled >> "$MIG_LOG"; }; disable_logging ) >"$T/out" 2>&1
check "menu disable: a refused migration changes nothing" "migrate" "$(cat "$MIG_LOG")"
printf 'NETWORK=testnet\nINSTALL_METHOD=binary\nINSTALL_METHOD=docker\n' > "$RP/etc/telcoin/.node-meta"
( load_node_context ) >"$T/out" 2>&1; check_rc "duplicated INSTALL_METHOD stops setup-observability" 1 $?

# --- the ingest token: --token-stdin, and a warning for --token on argv ---------------------------
tokrun() { # tokrun STDIN ARGS... -- main with run_json_mode replaced; RC, EV (JSON events)
    local input="$1"
    shift
    : > "$T/ev"
    RC=0
    ( run_json_mode() { printf 'TOKEN=%s\n' "$JSON_TOKEN" > "$T/tok"; json_done '{"event":"done","ok":true}'; }
      json_setup_fds() { exec 3>>"$T/ev"; }
      main "$@" <<< "$input" ) >"$T/out" 2>&1 || RC=$?
    EV="$(cat "$T/ev")"
}
rm -f "$T/tok"
tokrun "tok-from-stdin" --json --enable-logs --token-stdin
check_rc "--token-stdin rc 0" 0 "$RC"
check "--token-stdin: token read from stdin" "TOKEN=tok-from-stdin" "$(cat "$T/tok" 2>/dev/null)"
check_lacks "--token-stdin: no argv warning" "command line" "$EV"
rm -f "$T/tok"
tokrun $'tok-crlf\r' --json --enable-logs --token-stdin
check "--token-stdin: CR dropped" "TOKEN=tok-crlf" "$(cat "$T/tok" 2>/dev/null)"
rm -f "$T/tok"
tokrun "" --json --enable-logs --token argv-token
check_rc "--token rc 0" 0 "$RC"
check "--token: still used" "TOKEN=argv-token" "$(cat "$T/tok" 2>/dev/null)"
check "--token: warns that it is on the command line" "yes" \
    "$(grep -q '"event":"warn".*--token puts the ingest token on the command line' "$T/ev" && echo yes)"
tokrun "tok" --json --enable-logs --token argv-token --token-stdin
check_rc "--token with --token-stdin refused" 1 "$RC"
check "--token with --token-stdin: done event says why" "yes" "$(grep -q 'cannot be combined' "$T/ev" && echo yes)"
tokrun "" --json --enable-logs --token-stdin
check_rc "--token-stdin with nothing on stdin refused" 1 "$RC"
( run_json_mode() { :; }; main_menu() { :; }; main --token-stdin <<< "tok" ) >"$T/out" 2>&1
check_rc "--token-stdin without --json refused" 1 $?
check "--token-stdin without --json: said" "yes" "$(grep -q 'goes with --json' "$T/out" && echo yes)"


# --- obs_ensure_reth_flags: the unit is re-rendered for NODE_LOG_DIR before the restart ----------------
mkdir -p "$RP/etc/systemd/system"
U="$RP/etc/systemd/system/telcoin.service"
(
    tn_node_launch_target() { printf 'telcoin source %s\n' "$T/tn-start"; }
    tn_rerender_node_launch() { echo rerender >> "$T/ensure.log"; printf 'SupplementaryGroups=telcoin-log\nReadWritePaths=/var/lib/telcoin /var/log/telcoin/node\n' > "$U"; }
    _obs_flags_apply() { _OBS_FLAGS_CHANGED=0; return 0; }
    systemctl() { echo "systemctl $*" >> "$T/ensure.log"; return 0; }
    confirm() { return 0; }
    obs_restart_window() { return 0; }
    ENABLE_OBSERVABILITY=true NODE_LOG_DIR=/var/log/telcoin/node
    printf 'ReadWritePaths=/var/lib/telcoin\n' > "$U"; : > "$T/ensure.log"
    obs_ensure_reth_flags >/dev/null 2>&1; echo "rc=$?" >> "$T/ensure.log"
    cp "$T/ensure.log" "$T/ensure1.log"
    : > "$T/ensure.log"
    obs_ensure_reth_flags >/dev/null 2>&1; echo "rc=$?" >> "$T/ensure.log"
    cp "$T/ensure.log" "$T/ensure2.log"
    tn_rerender_node_launch() { echo refused >> "$T/ensure.log"; return 1; }
    printf 'ReadWritePaths=/var/lib/telcoin\n' > "$U"; : > "$T/ensure.log"
    obs_ensure_reth_flags >/dev/null 2>&1; echo "rc=$?" >> "$T/ensure.log"
    cp "$T/ensure.log" "$T/ensure3.log"
)
check "unit without the log dir: re-rendered, reloaded, restarted" \
    "$(printf 'rerender\nsystemctl daemon-reload\nsystemctl restart telcoin\nrc=0')" "$(cat "$T/ensure1.log")"
check "unit already carries the log dir: nothing to do" "rc=0" "$(cat "$T/ensure2.log")"
check "re-render refused: no restart, rc 1" "$(printf 'refused\nrc=1')" "$(cat "$T/ensure3.log")"
_obs_unit_has_log_dir telcoin /var/log/telcoin/node; check_rc "a unit without the group: not ready" 1 $?
printf 'SupplementaryGroups=telcoin-log\nReadWritePaths=/var/lib/telcoin /var/log/telcoin/node2\n' > "$U"
_obs_unit_has_log_dir telcoin /var/log/telcoin/node; check_rc "a different dir does not count" 1 $?


finish
