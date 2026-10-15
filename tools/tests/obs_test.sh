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
check "install -d as the service user, group telcoin-log, 0750" "-d -o telcoin -g telcoin-log -m 0750 -- /var/log/telcoin/node" "$(cat "$INSTALL_LOG")"
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
tn_committee_down_guard() { return "${CDG_RC:-0}"; }
( CDG_RC=1; obs_quorum_guard ) >/dev/null 2>&1; check_rc "quorum risk: no restart" 1 $?
( CDG_RC=1; TN_ALLOW_QUORUM_RISK=1; obs_quorum_guard ) >/dev/null 2>&1; check_rc "TN_ALLOW_QUORUM_RISK=1: restart" 0 $?
( CDG_RC=2; obs_quorum_guard ) >/dev/null 2>&1; check_rc "committee unreadable: restart with a warning" 0 $?
( CDG_RC=0; obs_quorum_guard ) >/dev/null 2>&1; check_rc "guard passes" 0 $?
unset -f tn_committee_down_guard

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
health_flag_add() { printf 'called\n' > "$T/flag"; return 0; }
rm -f "$T/flag"
( UFW_ACT_RC=1; enable_health ) >"$T/out" 2>&1
check "ufw inactive: --healthcheck not added" "no" "$([[ -e "$T/flag" ]] && echo yes || echo no)"
printf 'NETWORK=testnet\nINSTALL_METHOD=binary\nINSTALL_METHOD=docker\n' > "$RP/etc/telcoin/.node-meta"
( load_node_context ) >"$T/out" 2>&1; check_rc "duplicated INSTALL_METHOD stops setup-observability" 1 $?

finish
