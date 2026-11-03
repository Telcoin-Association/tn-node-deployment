#!/usr/bin/env bash
# =============================================================================
# tools/tests/obs_test.sh -- lib/observability.sh and setup-observability.sh: the
# push URL is empty off testnet/devnet, the Alloy tarball install fails closed (a
# 404 for the zip or its SHA256SUMS, a mismatch, a missing line), Grafana's apt key
# is pinned by fingerprint, the native unit's account and sandbox lines, the node log
# dir (NODE_LOG_DIR) in the reth flags and in config.alloy's __path__, its creation
# without a recursive chown, the committee guard before a node restart, the
# health check refused while ufw is not active, and a partial disable (logs or
# metrics alone) rendering config.alloy like the enable (owner, group, log path)
# and failing when Alloy does not restart or stay active (library, menu, --json),
# and the ingest token file: its owner and mode, the env file without the token and
# with the TLS host variables, LoadCredential= and the sidecar's read-only mount,
# bearer_token_file and the TLS 1.3 pin in config.alloy, the env-file migration,
# --rotate-token with its rollback, the shred on disable and the status line.
#
# TN_UPSTREAM_ALLOY_CONFIG=<path to deploy-networks-common's
# observability/node-agent/config.alloy> also compares the vendored blocks with it
# (the sync note's diff); without it that check is skipped.
#
#   bash tools/tests/obs_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/obs_test.sh
#
# curl, gpg, unzip, install, getent and useradd are PATH stubs, and chown, systemctl
# and docker for the partial-disable and token cases; tn_write_root_file and
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
[ "$1 $2" = "group telcoin-alloy" ] && [ "${HAS_ALLOY_ACCT:-1}" = "1" ] && { echo "telcoin-alloy:x:990:"; exit 0; }
[ "$1 $2" = "passwd telcoin-alloy" ] && [ "${HAS_ALLOY_ACCT:-1}" = "1" ] && { echo "telcoin-alloy:x:990:990::/var/lib/telcoin-alloy:/usr/sbin/nologin"; exit 0; }
exit 2
STUB
# Never a real account, even as root in a container.
cat > "$T/bin/useradd" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$T/bin/"*
PATH="$T/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"  # macOS keeps sha256sum in /sbin
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
         "InaccessiblePaths=-/var/lib/telcoin -/etc/telcoin/bls-passphrase.cred -/etc/telcoin/bls-passphrase -/srv/tn-data" \
         "PrivateDevices=yes" "NoNewPrivileges=yes" "CapabilityBoundingSet=" "ProtectProc=invisible" \
         "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX" \
         "EnvironmentFile=/etc/telcoin/alloy/telcoin-alloy.env" \
         "LoadCredential=ingest-token:/etc/telcoin/alloy/ingest-token" "LimitCORE=0"; do
    check "unit has: $l" "yes" "$(grep -qxF -- "$l" "$T/unit" && echo yes)"
done
check "unit never runs as the node user" "no" "$(grep -qx 'User=telcoin' "$T/unit" && echo yes || echo no)"
check_lacks "unit: the stale credential store is gone" "credstore.encrypted" "$unit"
check_lacks "unit: no token in the unit text" "OBS_INGEST_TOKEN" "$unit"
obs_alloy_unit_text /usr/bin/alloy /e "" > "$T/unit2"
check "no telcoin-log group: no SupplementaryGroups line" "no" "$(grep -q '^SupplementaryGroups' "$T/unit2" && echo yes || echo no)"

# systemd-analyze verify on the rendered units (a host with systemd; skipped elsewhere,
# such as the bash:3.2 and ubuntu:24.04 images). ExecStart must name an executable.
# verify_unit NAME FILE -- rc 0 and no line about telcoin-alloy.service in its output.
verify_unit() {
    local out rc=0
    mkdir -p "$T/verify"
    cp "$2" "$T/verify/telcoin-alloy.service"
    out="$(systemd-analyze verify "$T/verify/telcoin-alloy.service" 2>&1)" || rc=$?
    check_rc "systemd-analyze verify: $1" 0 "$rc" || printf '%s\n' "$out" | sed 's/^/      /'
    check_lacks "systemd-analyze verify: $1 has no complaint" "telcoin-alloy.service" "$out"
}
if command -v systemd-analyze >/dev/null 2>&1 && systemd-analyze --version >/dev/null 2>&1; then
    obs_alloy_unit_text "$(type -P true)" /etc/telcoin/alloy/telcoin-alloy.env telcoin-log /srv/tn-data > "$T/unit-v"
    verify_unit "native unit" "$T/unit-v"
else
    skip "systemd-analyze verify: native unit" "no systemd-analyze here"
fi

# --- docker sidecar unit: the token as a read-only mount, never in the environment ---------
DUNIT="$(obs_alloy_docker_unit_text /etc/telcoin/alloy/telcoin-alloy.env /srv/tn-data/logs 990)"
printf '%s\n' "$DUNIT" > "$T/dunit"
check "sidecar: the token file mounted read-only at the credentials path" "yes" \
    "$(grep -qF -- ' --mount type=bind,source=/etc/telcoin/alloy/ingest-token,target=/run/credentials/telcoin-alloy/ingest-token,readonly ' <<< "$(grep '^ExecStart=' "$T/dunit")" && echo yes)"
check "sidecar: --group-add with the telcoin-alloy gid" "yes" "$(grep -qF -- ' --group-add 990 ' <<< "$(grep '^ExecStart=' "$T/dunit")" && echo yes)"
check "sidecar: the container writes no core dump" "yes" "$(grep -qF -- ' --ulimit core=0 ' <<< "$(grep '^ExecStart=' "$T/dunit")" && echo yes)"
check "sidecar unit: LimitCORE=0" "yes" "$(grep -qxF 'LimitCORE=0' "$T/dunit" && echo yes)"
check "sidecar: still the env file for the labels" "yes" "$(grep -qF -- ' --env-file /etc/telcoin/alloy/telcoin-alloy.env ' <<< "$(grep '^ExecStart=' "$T/dunit")" && echo yes)"
check_lacks "sidecar: no token variable" "OBS_INGEST_TOKEN" "$DUNIT"
check "sidecar: no -e environment flag" "no" "$(grep -qE -- '(^| )(-e|--env) ' "$T/dunit" && echo yes || echo no)"
if command -v systemd-analyze >/dev/null 2>&1 && systemd-analyze --version >/dev/null 2>&1 && [[ -x /usr/bin/docker ]]; then
    verify_unit "docker sidecar unit" "$T/dunit"
else
    skip "systemd-analyze verify: docker sidecar unit" "no systemd-analyze or /usr/bin/docker here"
fi

# --- config.alloy: the token from a file, TLS 1.3 to the push host, in both pipelines ---------
# ccheck NAME FILE -- the endpoint lines in a rendered config.alloy with both pipelines.
ccheck() {
    local f="$2"
    check "$1: bearer_token_file in both endpoints" "2" \
        "$(grep -cF 'bearer_token_file = sys.env("CREDENTIALS_DIRECTORY") + "/ingest-token"' "$f")"
    check "$1: min_version TLS13 in both endpoints" "2" "$(grep -cF 'min_version = "TLS13"' "$f")"
    check "$1: the logs server name from OBS_PUSH_HOST" "1" "$(grep -cF 'server_name = sys.env("OBS_PUSH_HOST")' "$f")"
    check "$1: the metrics server name from OBS_METRICS_PUSH_HOST" "1" "$(grep -cF 'server_name = sys.env("OBS_METRICS_PUSH_HOST")' "$f")"
    check "$1: two tls_config blocks" "2" "$(grep -c 'tls_config {' "$f")"
    check "$1: no token variable in a River line" "0" "$(grep -v '^[[:space:]]*//' "$f" | grep -c 'OBS_INGEST_TOKEN')"
    check "$1: no bearer_token from the environment" "0" "$(grep -c 'bearer_token *=' "$f")"
}
ENABLE_OBSERVABILITY=true ENABLE_METRICS=true _obs_slice_alloy "${TN_TEST_REPO}/observability/config.alloy" "$T/cfg-both" ""
ccheck "vendored config" "$T/cfg-both"
_obs_alloy_fallback > "$T/fallback.alloy"
ENABLE_OBSERVABILITY=true ENABLE_METRICS=true _obs_slice_alloy "$T/fallback.alloy" "$T/cfg-fb" ""
ccheck "embedded fallback" "$T/cfg-fb"
ENABLE_OBSERVABILITY=true ENABLE_METRICS=false _obs_slice_alloy "${TN_TEST_REPO}/observability/config.alloy" "$T/cfg-l" ""
check "logs only: one tls_config, the logs one" "1 1" \
    "$(grep -c 'tls_config {' "$T/cfg-l") $(grep -cF 'sys.env("OBS_PUSH_HOST")' "$T/cfg-l")"
# river_lines FILE -- the River statements from local.file_match on, comments and
# whitespace removed, so the fallback (two-space indents) compares with the tab-indented file.
river_lines() { sed -n '/^local\.file_match/,$p' "$1" | grep -v '^[[:space:]]*//' | tr -d ' \t' | grep -v '^$'; }
check "embedded fallback: the same River statements as observability/config.alloy" \
    "$(river_lines "${TN_TEST_REPO}/observability/config.alloy")" "$(river_lines "$T/fallback.alloy")"
if [[ -n "${TN_UPSTREAM_ALLOY_CONFIG:-}" && -f "${TN_UPSTREAM_ALLOY_CONFIG}" ]]; then
    check "sync note: the vendored blocks equal upstream byte for byte" \
        "$(sed -n '/^local\.file_match/,$p' "$TN_UPSTREAM_ALLOY_CONFIG")" \
        "$(sed -n '/^local\.file_match/,$p' "${TN_TEST_REPO}/observability/config.alloy")"
else
    skip "sync note: the vendored blocks equal upstream byte for byte" "TN_UPSTREAM_ALLOY_CONFIG not set or absent"
fi
check "push host: plain URL" "obs.adiri.telcoin.network" "$(obs_url_host "$OBS_PUSH_URL_TESTNET")"
check "push host: user and port dropped" "hub.example" "$(obs_url_host 'https://u@hub.example:8443/api/v1/write')"
check "push host: IPv6 literal" "2001:db8::1" "$(obs_url_host 'https://[2001:db8::1]:443/x')"
check "push host: empty URL" "" "$(obs_url_host '')"

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


# --- partial disables render config.alloy like the enable; Alloy must stay up after a restart ---------
# From here chown and systemctl are PATH stubs. chown logs "OWNER:GROUP FILE" and exits
# CHOWN_RC. systemctl logs every call; restart exits ALLOY_RESTART_RC; is-active prints
# ALLOY_STATE (default active), or activating once more than ALLOY_UP_CHECKS reads were
# made, and exits 0 only for active. obs_disable is never driven here (it runs a real
# docker rm -f).
export CHOWN_LOG="$T/chown.log" SYSTEMCTL_LOG="$T/systemctl.log" ISACTIVE_N="$T/isactive.n"
cat > "$T/bin/chown" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$2" >> "${CHOWN_LOG:?}"
exit "${CHOWN_RC:-0}"
STUB
cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:?}"
case "${1:-}" in
    restart) exit "${ALLOY_RESTART_RC:-0}" ;;
    is-active)
        n=0
        [ -f "${ISACTIVE_N:?}" ] && n="$(cat "$ISACTIVE_N")"
        n=$((n + 1))
        echo "$n" > "$ISACTIVE_N"
        s="${ALLOY_STATE:-active}"
        [ "$n" -gt "${ALLOY_UP_CHECKS:-999}" ] && s=activating
        echo "$s"
        [ "$s" = active ]
        exit ;;
esac
exit 0
STUB
chmod +x "$T/bin/chown" "$T/bin/systemctl"
hash -r
SAVED_OBS_ETC_DIR="$OBS_ETC_DIR"
OBS_ETC_DIR="$RP/etc/telcoin/alloy"
CFG="${OBS_ETC_DIR}/config.alloy"
META="$RP/etc/telcoin/.node-meta"
mkdir -p "$OBS_ETC_DIR"
# meta_set writes through this from here on, so .node-meta keeps what a disable records.
tn_write_root_file() { printf '%s %s\n' "$1" "$2" >> "$WRITES"; cat > "$1"; }
unset NODE_LOG_DIR
NATIVE='NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nINSTALL_METHOD=binary\nENABLE_OBSERVABILITY=true\nENABLE_METRICS=true\nNODE_LOG_DIR=/var/log/telcoin/node'
DOCKER='NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nINSTALL_METHOD=docker\nENABLE_OBSERVABILITY=true\nENABLE_METRICS=true\nNODE_LOG_DIR=/var/log/telcoin/node'
NODEPATH='"/var/log/telcoin/node/telcoin-network-logs/reth.log*"'
VENDPATH='"/var/log/telcoin/telcoin-network-logs/reth.log*"'
SRC="${TN_TEST_REPO}/observability/config.alloy"
ENABLE_OBSERVABILITY=true ENABLE_METRICS=false _obs_slice_alloy "$SRC" "$T/want-logs" /var/log/telcoin/node
ENABLE_OBSERVABILITY=false ENABLE_METRICS=true _obs_slice_alloy "$SRC" "$T/want-metrics" ""

pd_reset() { # pd_reset META -- META into .node-meta; no config, empty chown and systemctl logs
    printf '%b\n' "$1" > "$META"
    rm -f "$CFG" "$ISACTIVE_N"
    : > "$CHOWN_LOG"
    : > "$SYSTEMCTL_LOG"
}
pd() { # pd FUNC META [ENV=VAL...] -- FUNC in a subshell (sleep stubbed); output in $T/pd.out; its rc
    local fn="$1"
    pd_reset "$2"
    shift 2
    ( sleep() { :; }; for kv in "$@"; do export "${kv?}"; done; "$fn" ) >"$T/pd.out" 2>&1
}
yn() { if "$@"; then echo yes; else echo no; fi; }
cfg_has() { yn grep -qF -- "$1" "$CFG"; }
pd_said() { yn grep -qF -- "$1" "$T/pd.out"; }
reads() { grep -c '^is-active ' "$SYSTEMCTL_LOG"; }

pd obs_disable_metrics "$NATIVE"; rc=$?
check_rc "native metrics disable: rc 0" 0 "$rc"
check "native metrics disable: __path__ at the node log dir" "yes" "$(cfg_has "$NODEPATH")"
check "native metrics disable: no vendored __path__" "no" "$(cfg_has "$VENDPATH")"
check "native metrics disable: the file the enable renders for logs only" "$(cat "$T/want-logs")" "$(cat "$CFG")"
check "native metrics disable: root:telcoin-alloy" "root:telcoin-alloy $CFG" "$(cat "$CHOWN_LOG")"
check "native metrics disable: mode 0640" "640" "$(stat -c %a "$CFG")"
check_has "native metrics disable: recorded" "ENABLE_METRICS=false" "$(cat "$META")"
check "native metrics disable: logs pipeline kept" "yes" "$(cfg_has 'local.file_match')"
check "native metrics disable: metrics pipeline gone" "no" "$(cfg_has 'prometheus.remote_write')"
check "native metrics disable: restarted once" "1" "$(grep -c '^restart telcoin-alloy.service$' "$SYSTEMCTL_LOG")"
check "settle window: 5 seconds" "5" "${OBS_ALLOY_SETTLE_SECS:-unset}"
check "healthy restart: is-active read OBS_ALLOY_SETTLE_SECS times" "${OBS_ALLOY_SETTLE_SECS:-5}" "$(reads)"
check "native metrics disable: said" "yes" "$(pd_said 'Metrics shipping stopped')"

pd obs_disable_logs "$NATIVE"; rc=$?
check_rc "native logs disable: rc 0" 0 "$rc"
check "native logs disable: root:telcoin-alloy" "root:telcoin-alloy $CFG" "$(cat "$CHOWN_LOG")"
check "native logs disable: the file the enable renders for metrics only" "$(cat "$T/want-metrics")" "$(cat "$CFG")"
check "native logs disable: logs pipeline gone" "no" "$(cfg_has 'local.file_match')"
check "native logs disable: metrics pipeline kept" "yes" "$(cfg_has 'prometheus.remote_write')"
check_has "native logs disable: recorded" "ENABLE_OBSERVABILITY=false" "$(cat "$META")"

pd obs_disable_metrics "$DOCKER"; rc=$?
check_rc "docker metrics disable: rc 0" 0 "$rc"
check "docker metrics disable: root:root" "root:root $CFG" "$(cat "$CHOWN_LOG")"
check "docker metrics disable: vendored __path__" "yes" "$(cfg_has "$VENDPATH")"

pd obs_disable_metrics "$NATIVE" NODE_LOG_DIR=/srv/tn/node; rc=$?
check_rc "NODE_LOG_DIR global: rc 0" 0 "$rc"
check "the NODE_LOG_DIR global wins over .node-meta" "yes" "$(cfg_has '"/srv/tn/node/telcoin-network-logs/reth.log*"')"

pd obs_disable_metrics "$NATIVE" ALLOY_STATE=activating; rc=$?
check_rc "Alloy in a restart loop: rc 1" 1 "$rc"
check "Alloy in a restart loop: said" "yes" "$(pd_said 'did not stay running after the restart (state: activating)')"
check "Alloy in a restart loop: stops at the first read" "1" "$(reads)"
check_has "Alloy in a restart loop: the choice is still recorded" "ENABLE_METRICS=false" "$(cat "$META")"
check "Alloy in a restart loop: says where the choice stands" "yes" "$(pd_said 'off in config.alloy and .node-meta')"
check "Alloy in a restart loop: no success line" "no" "$(pd_said 'Metrics shipping stopped')"

pd obs_disable_metrics "$NATIVE" ALLOY_UP_CHECKS=2; rc=$?
check_rc "Alloy down after two reads: rc 1" 1 "$rc"
check "Alloy down after two reads: a third read caught it" "3" "$(reads)"

pd obs_disable_metrics "$NATIVE" ALLOY_RESTART_RC=1; rc=$?
check_rc "restart fails: rc 1" 1 "$rc"
check "restart fails: said" "yes" "$(pd_said 'Failed to start telcoin-alloy.service')"
check "restart fails: no is-active read" "0" "$(reads)"

pd obs_disable_metrics "$NATIVE" CHOWN_RC=1; rc=$?
check_rc "chown fails: rc 1" 1 "$rc"
check "chown fails: said" "yes" "$(pd_said "Could not write ${CFG} as root:telcoin-alloy 0640.")"
check_has "chown fails: the choice is not recorded" "ENABLE_METRICS=true" "$(cat "$META")"
check "chown fails: no restart" "no" "$(yn grep -q '^restart' "$SYSTEMCTL_LOG")"

pd obs_disable_metrics "${NATIVE}\nINSTALL_METHOD=docker"; rc=$?
check_rc "duplicated INSTALL_METHOD: rc 1" 1 "$rc"
check "duplicated INSTALL_METHOD: no config written" "no" "$(yn test -e "$CFG")"
check "duplicated INSTALL_METHOD: no chown, no systemctl" "" "$(cat "$CHOWN_LOG" "$SYSTEMCTL_LOG")"
check_has "duplicated INSTALL_METHOD: nothing recorded" "ENABLE_METRICS=true" "$(cat "$META")"

pd obs_disable_metrics "${NATIVE}\nNODE_LOG_DIR=/srv/other"; rc=$?
check_rc "duplicated NODE_LOG_DIR: rc 1" 1 "$rc"
check "duplicated NODE_LOG_DIR: no config written" "no" "$(yn test -e "$CFG")"
check_has "duplicated NODE_LOG_DIR: nothing recorded" "ENABLE_METRICS=true" "$(cat "$META")"

# obs_enable renders through the same helper and runs the same restart check (its
# account, install, unit and node-flag steps are stubbed).
oe() { # oe META LOGS METRICS [ENV=VAL...] -- obs_enable in a subshell; output in $T/pd.out; its rc
    local logs="$2" metrics="$3"
    pd_reset "$1"
    shift 3
    ( sleep() { :; }
      obs_check_reth_flags() { return 0; }
      obs_prepare_node_log_dir() { printf '%s\n' /var/log/telcoin/node; }
      obs_alloy_account() { return 0; }
      obs_install_alloy_native() { return 0; }
      obs_write_alloy_native_unit() { return 0; }
      obs_ensure_reth_flags() { return 0; }
      _obs_data_dir() { printf '%s\n' "$T/dd"; }
      tn_as_service_user() { return 0; }
      obs_run_alloy_docker() { return 0; }
      for kv in "$@"; do export "${kv?}"; done
      NETWORK=testnet; ENABLE_OBSERVABILITY="$logs"; ENABLE_METRICS="$metrics"
      obs_enable "tok-0123456789abcdef" ) >"$T/pd.out" 2>&1
}
BASE='NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nINSTALL_METHOD=binary'
oe "$BASE" true false; rc=$?
check_rc "native enable: rc 0" 0 "$rc"
check "native enable: the same file as the metrics disable leaves" "$(cat "$T/want-logs")" "$(cat "$CFG")"
check "native enable: root:telcoin-alloy" "root:telcoin-alloy $CFG" "$(cat "$CHOWN_LOG")"
check "native enable: is-active read OBS_ALLOY_SETTLE_SECS times" "${OBS_ALLOY_SETTLE_SECS:-5}" "$(reads)"
check "native enable: running line" "yes" "$(pd_said 'Telemetry shipper running (telcoin-alloy.service).')"
check_has "native enable: recorded" "ENABLE_OBSERVABILITY=true" "$(cat "$META")"
oe "$BASE" true false ALLOY_STATE=failed; rc=$?
check_rc "native enable, Alloy does not stay up: rc 1" 1 "$rc"
check "native enable, Alloy does not stay up: said" "yes" "$(pd_said '(state: failed)')"
check "native enable, Alloy does not stay up: no running line" "no" "$(pd_said 'Telemetry shipper running')"
check_lacks "native enable, Alloy does not stay up: not recorded as enabled" "ENABLE_OBSERVABILITY=true" "$(cat "$META")"
oe 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nINSTALL_METHOD=docker' true true; rc=$?
check_rc "docker enable: rc 0" 0 "$rc"
check "docker enable: the vendored file, byte for byte" "$(cat "$SRC")" "$(cat "$CFG")"
check "docker enable: root:root" "root:root $CFG" "$(cat "$CHOWN_LOG")"

# The menu and --json callers say when a partial disable did not finish.
( confirm() { return 0; }; pause() { :; }; addon_meta_write_begin() { return 0; }
  obs_disable_metrics() { return 1; }; disable_metrics ) >"$T/out" 2>&1
check "menu: a metrics disable that did not finish is said" "yes" "$(yn grep -q 'did not finish' "$T/out")"
( confirm() { return 0; }; pause() { :; }; addon_meta_write_begin() { return 0; }
  obs_disable_logs() { return 1; }; disable_logging ) >"$T/out" 2>&1
check "menu: a log disable that did not finish is said" "yes" "$(yn grep -q 'Disabling log shipping did not finish' "$T/out")"
jsonrun() { # jsonrun [ENV=VAL...] -- main --json --disable-metrics with the real run_json_mode on NATIVE; RC, EV
    pd_reset "$NATIVE"
    : > "$T/ev"
    RC=0
    ( sleep() { :; }; check_root() { :; }; detect_distro() { :; }
      addon_meta_write_begin() { return 0; }
      json_setup_fds() { exec 3>>"$T/ev"; }
      for kv in "$@"; do export "${kv?}"; done
      main --json --disable-metrics </dev/null ) >"$T/out" 2>&1 || RC=$?
    EV="$(cat "$T/ev")"
}
jsonrun ALLOY_STATE=activating
check_rc "json: Alloy down: rc 1" 1 "$RC"
check "json: Alloy down: an error event" "yes" \
    "$(yn grep -q '"event":"error","msg":"disabling metrics shipping did not finish' "$T/ev")"
check "json: Alloy down: done ok:false" "yes" "$(yn grep -q '"event":"done","ok":false' "$T/ev")"
check_lacks "json: Alloy down: no metrics:disabled marker" "metrics:disabled" "$EV"
jsonrun
check_rc "json: Alloy up: rc 0" 0 "$RC"
check "json: Alloy up: the marker is in done" "yes" \
    "$(yn grep -qF '"event":"done","ok":true,"applied":["metrics:disabled"]' "$T/ev")"

# --- the ingest token file (#35) ------------------------------------------------------------------
# From here tn_write_root_file logs "DEST MODE GROUP" to $TW and writes DEST with MODE;
# TRF_FAIL=<suffix> makes the write of a DEST ending in it fail (rc 2). systemctl also
# fails its first ALLOY_RESTART_FAILS restarts and lists telcoin-alloy.service; docker
# logs its calls.
TW="$T/tw.log"
export RESTART_N="$T/restart.n" DOCKER_LOG="$T/docker.log"
tn_write_root_file() {
    printf '%s %s %s\n' "$1" "$2" "${3:-root}" >> "$TW"
    if [[ -n "${TRF_FAIL:-}" && "$1" == *"$TRF_FAIL" ]]; then
        cat > /dev/null
        return 2
    fi
    cat > "$1" && chmod "$2" "$1"
}
cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:?}"
case "${1:-}" in
    restart)
        n=0
        [ -f "${RESTART_N:?}" ] && n="$(cat "$RESTART_N")"
        n=$((n + 1))
        echo "$n" > "$RESTART_N"
        [ "$n" -le "${ALLOY_RESTART_FAILS:-0}" ] && exit 1
        exit "${ALLOY_RESTART_RC:-0}" ;;
    is-active)
        n=0
        [ -f "${ISACTIVE_N:?}" ] && n="$(cat "$ISACTIVE_N")"
        n=$((n + 1))
        echo "$n" > "$ISACTIVE_N"
        s="${ALLOY_STATE:-active}"
        [ "$n" -gt "${ALLOY_UP_CHECKS:-999}" ] && s=activating
        echo "$s"
        [ "$s" = active ]
        exit ;;
    list-unit-files) echo "telcoin-alloy.service enabled enabled"; exit 0 ;;
esac
exit 0
STUB
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
exit 0
STUB
chmod +x "$T/bin/systemctl" "$T/bin/docker"
hash -r
TOKF="${OBS_ETC_DIR}/ingest-token"
ENVF="${OBS_ETC_DIR}/telcoin-alloy.env"
UNITF="$RP/etc/systemd/system/telcoin-alloy.service"
OLDTOK="old-token-0123456789abcdef"
NEWTOK="new-token-fedcba9876543210"
tk_reset() { # tk_reset META -- META into .node-meta, no Alloy files, empty logs
    pd_reset "$1"
    rm -f "$TOKF" "$ENVF" "$UNITF" "$RESTART_N"
    : > "$TW"
    : > "$DOCKER_LOG"
}
tw_has() { yn grep -qxF -- "$1" "$TW"; }

# The token file: root:telcoin-alloy 0640, one line, from a variable.
tk_reset "$NATIVE"
( obs_write_token_file "$NEWTOK" ) >"$T/tk.out" 2>&1
check_rc "token file written" 0 $?
check "token file: root:telcoin-alloy 0640 through tn_write_root_file" "yes" "$(tw_has "$TOKF 0640 telcoin-alloy")"
check "token file: the token on one line" "$NEWTOK" "$(cat "$TOKF")"
check "token file: one line" "1" "$(wc -l < "$TOKF" | tr -d ' ')"
check_lacks "token file write: the token is not printed" "$NEWTOK" "$(cat "$T/tk.out")"
( TRF_FAIL=ingest-token; obs_write_token_file "$NEWTOK" ) >"$T/tk.out" 2>&1
check_rc "token file write fails: rc 1" 1 $?
check "token file write fails: said" "yes" "$(yn grep -qF 'Could not write the ingest token file' "$T/tk.out")"

# The env file: no token, the TLS host variables, CREDENTIALS_DIRECTORY on docker only.
tk_reset "$NATIVE"
( ENABLE_METRICS=true; NETWORK=testnet; _obs_write_env_file ) >"$T/tk.out" 2>&1
check_rc "native env file written" 0 $?
check "env file: root 0600 through tn_write_root_file" "yes" "$(tw_has "$ENVF 0600 root")"
check_lacks "env file: no OBS_INGEST_TOKEN" "OBS_INGEST_TOKEN" "$(cat "$ENVF")"
check_has "env file: the logs push host" "OBS_PUSH_HOST=obs.adiri.telcoin.network" "$(cat "$ENVF")"
check_has "env file: the metrics push host" "OBS_METRICS_PUSH_HOST=obs.adiri.telcoin.network" "$(cat "$ENVF")"
check_has "env file: the logs push URL" "OBS_PUSH_URL=${OBS_PUSH_URL_TESTNET}" "$(cat "$ENVF")"
check_lacks "native env file: no CREDENTIALS_DIRECTORY (systemd sets it)" "CREDENTIALS_DIRECTORY" "$(cat "$ENVF")"
tk_reset "$DOCKER"
( ENABLE_METRICS=false; NETWORK=testnet; OBS_PUSH_URL=https://hub.example:8443/loki/api/v1/push; _obs_write_env_file ) >"$T/tk.out" 2>&1
check_rc "docker env file written" 0 $?
check_has "docker env file: CREDENTIALS_DIRECTORY at the mount" "CREDENTIALS_DIRECTORY=/run/credentials/telcoin-alloy" "$(cat "$ENVF")"
check_has "env file: an override's host" "OBS_PUSH_HOST=hub.example" "$(cat "$ENVF")"
check_lacks "metrics off: no metrics host" "OBS_METRICS_PUSH_HOST" "$(cat "$ENVF")"

# Migration: an env file that still holds the token.
tk_reset "$NATIVE"
printf 'TN_NODE=old\nOBS_PUSH_URL=%s\nOBS_INGEST_TOKEN=%s\n' "$OBS_PUSH_URL_TESTNET" "$OLDTOK" > "$ENVF"
( NETWORK=testnet; _obs_write_env_file; _obs_write_env_file ) >"$T/tk.out" 2>&1
check_rc "legacy env: migrated" 0 $?
check "legacy env: its token moved to the token file" "$OLDTOK" "$(cat "$TOKF" 2>/dev/null)"
check "legacy env: written root:telcoin-alloy 0640" "yes" "$(tw_has "$TOKF 0640 telcoin-alloy")"
check_lacks "legacy env: the line is gone" "OBS_INGEST_TOKEN" "$(cat "$ENVF")"
check "legacy env: said once" "1" "$(grep -c 'no longer holds the ingest token' "$T/tk.out")"
check_lacks "legacy env: the token is not printed" "$OLDTOK" "$(cat "$T/tk.out")"
tk_reset "$NATIVE"
printf 'OBS_INGEST_TOKEN=%s\n' "$OLDTOK" > "$ENVF"
printf '%s\n' "$NEWTOK" > "$TOKF"
( NETWORK=testnet; _obs_write_env_file ) >"$T/tk.out" 2>&1
check "legacy env beside a token file: the token file is kept" "$NEWTOK" "$(cat "$TOKF")"
check_lacks "legacy env beside a token file: the line is gone" "OBS_INGEST_TOKEN" "$(cat "$ENVF")"
tk_reset "$NATIVE"
printf 'OBS_INGEST_TOKEN=%s\n' "$OLDTOK" > "$ENVF"
( NETWORK=testnet; TRF_FAIL=ingest-token; _obs_write_env_file ) >"$T/tk.out" 2>&1
check_rc "legacy env, token file write fails: rc 1" 1 $?
check_has "legacy env, token file write fails: the env file keeps the token" "OBS_INGEST_TOKEN=${OLDTOK}" "$(cat "$ENVF")"

# obs_existing_token: the token file first, then the legacy env line.
tk_reset "$NATIVE"
check "existing token: none" "" "$(obs_existing_token)"
printf 'OBS_INGEST_TOKEN=%s\n' "$OLDTOK" > "$ENVF"
check "existing token: the legacy env line" "$OLDTOK" "$(obs_existing_token)"
printf '%s\n' "$NEWTOK" > "$TOKF"
check "existing token: the token file wins" "$NEWTOK" "$(obs_existing_token)"
: > "$TOKF"
check "existing token: an empty token file falls back to the env line" "$OLDTOK" "$(obs_existing_token)"

# The unit writers.
tk_reset "$NATIVE"
( NETWORK=testnet; obs_write_alloy_native_unit ) >"$T/tk.out" 2>&1
check_rc "native unit written" 0 $?
check "native unit: root 0644" "yes" "$(tw_has "$UNITF 0644 root")"
check_has "native unit: LoadCredential= of the token file" "LoadCredential=ingest-token:${TOKF}" "$(cat "$UNITF")"
check_has "native unit: LimitCORE=0" "LimitCORE=0" "$(cat "$UNITF")"
check "native unit: daemon-reload" "yes" "$(yn grep -qx 'daemon-reload' "$SYSTEMCTL_LOG")"
tk_reset "$DOCKER"
( NETWORK=testnet; obs_write_alloy_units ) >"$T/tk.out" 2>&1
check_rc "docker unit written" 0 $?
check "docker unit: the token file mounted" "yes" "$(yn grep -qF -- "--mount type=bind,source=${TOKF},target=/run/credentials/telcoin-alloy/ingest-token,readonly" "$UNITF")"
check "docker unit: the gid of telcoin-alloy" "yes" "$(yn grep -qF -- '--group-add 990 ' "$UNITF")"
check "docker unit: logs from the data dir" "yes" "$(yn grep -qF -- "${DEFAULT_DATA_DIR}/logs:/var/log/telcoin:ro " "$UNITF")"
tk_reset "$DOCKER"
( export HAS_ALLOY_ACCT=0; NETWORK=testnet; obs_run_alloy_docker /srv/logs ) >"$T/tk.out" 2>&1
check_rc "docker unit without the telcoin-alloy group: rc 1" 1 $?
check "docker unit without the group: said" "yes" "$(yn grep -qF 'There is no telcoin-alloy group' "$T/tk.out")"
check "docker unit without the group: no unit" "no" "$(yn test -e "$UNITF")"

# obs_enable writes the token file on both runtimes (account, install and node flags stubbed).
tk_reset 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nINSTALL_METHOD=docker'
( sleep() { :; }; obs_check_reth_flags() { return 0; }; obs_alloy_account() { return 0; }
  obs_ensure_reth_flags() { return 0; }; _obs_data_dir() { printf '%s\n' "$T/dd"; }
  tn_as_service_user() { return 0; }
  NETWORK=testnet; ENABLE_OBSERVABILITY=true; ENABLE_METRICS=true
  obs_enable "  ${NEWTOK}  " ) >"$T/tk.out" 2>&1
check_rc "docker enable: rc 0" 0 $?
check "docker enable: the trimmed token in the token file" "$NEWTOK" "$(cat "$TOKF" 2>/dev/null)"
check "docker enable: the sidecar unit mounts it" "yes" "$(yn grep -qF -- "source=${TOKF}," "$UNITF")"
check_lacks "docker enable: no token in the env file" "$NEWTOK" "$(cat "$ENVF")"
check_lacks "docker enable: no token in the unit" "$NEWTOK" "$(cat "$UNITF")"
check_lacks "docker enable: the token is not printed" "$NEWTOK" "$(cat "$T/tk.out")"

# A partial disable on a host still on the env-file token migrates it with the unit.
tk_reset "$NATIVE"
printf 'TN_NODE=old\nOBS_INGEST_TOKEN=%s\n' "$OLDTOK" > "$ENVF"
printf 'OLD UNIT\n' > "$UNITF"
( sleep() { :; }; obs_disable_metrics ) >"$T/tk.out" 2>&1
check_rc "legacy host, metrics disable: rc 0" 0 $?
check "legacy host, metrics disable: the token moved to the token file" "$OLDTOK" "$(cat "$TOKF" 2>/dev/null)"
check_lacks "legacy host, metrics disable: no token line left" "OBS_INGEST_TOKEN" "$(cat "$ENVF")"
check_has "legacy host, metrics disable: the unit reads the token file" "LoadCredential=ingest-token:${TOKF}" "$(cat "$UNITF")"
check "legacy host, metrics disable: config.alloy reads it" "1" "$(grep -c 'bearer_token_file' "$CFG")"

# obs_disable shreds the token file, and an env file that still holds the token.
tk_reset "$NATIVE"
printf '%s\n' "$NEWTOK" > "$TOKF"
printf 'TN_NODE=n\nOBS_PUSH_HOST=h\n' > "$ENVF"
( obs_disable ) >"$T/tk.out" 2>&1
check_rc "obs_disable: rc 0" 0 $?
check "obs_disable: the token file is gone" "no" "$(yn test -e "$TOKF")"
check "obs_disable: an env file without the token is kept" "yes" "$(yn test -e "$ENVF")"
check "obs_disable: said" "yes" "$(yn grep -qF 'ingest token file was shredded' "$T/tk.out")"
check "obs_disable: the sidecar container removed" "yes" "$(yn grep -qx 'rm -f telcoin-alloy' "$DOCKER_LOG")"
tk_reset "$NATIVE"
printf 'OBS_INGEST_TOKEN=%s\n' "$OLDTOK" > "$ENVF"
( obs_disable ) >"$T/tk.out" 2>&1
check "obs_disable: an env file that holds the token is gone" "no" "$(yn test -e "$ENVF")"

# obs_status: the token file line, never the value.
tk_status() { # tk_status [STAT-OUTPUT] -- _obs_token_status with stat answering STAT-OUTPUT
    ( TK_STAT="${1:-}"
      if [[ -n "$TK_STAT" ]]; then stat() { printf '%s\n' "$TK_STAT"; }; fi
      _obs_token_status ) >"$T/tk.out" 2>&1
}
tk_reset "$NATIVE"
printf '%s\n' "$NEWTOK" > "$TOKF"
tk_status "640 root:telcoin-alloy"
check "status: token file present (0640 root:telcoin-alloy)" "yes" \
    "$(yn grep -qF "Ingest token file present (0640 root:telcoin-alloy): ${TOKF}" "$T/tk.out")"
check_lacks "status: never the token" "$NEWTOK" "$(cat "$T/tk.out")"
tk_status "644 root:root"
check "status: a wrong mode or owner is said" "yes" "$(yn grep -qF 'is 644 root:root, not 0640 root:telcoin-alloy' "$T/tk.out")"
rm -f "$TOKF"
printf 'OBS_INGEST_TOKEN=%s\n' "$OLDTOK" > "$ENVF"
tk_status
check "status: a token still in the env file is said" "yes" "$(yn grep -qF 'The ingest token is still in' "$T/tk.out")"
check_lacks "status: never the legacy token" "$OLDTOK" "$(cat "$T/tk.out")"
rm -f "$ENVF"
tk_status
check "status: no token file is said" "yes" "$(yn grep -qF 'No ingest token file at' "$T/tk.out")"
printf '%s\n' "$NEWTOK" > "$TOKF"
( curl() { return 22; }; obs_status ) >"$T/tk.out" 2>&1
check "obs_status: the token line under the unit state" "yes" "$(yn grep -qF 'Ingest token file' "$T/tk.out")"
check_lacks "obs_status: never the token" "$NEWTOK" "$(cat "$T/tk.out")"

# obs_rotate_token: an installed native shipper on the old token.
rot_fixture() { # rot_fixture META [legacy] -- installed Alloy files on OLDTOK
    tk_reset "$1"
    if [[ "${2:-}" == legacy ]]; then
        printf 'TN_NODE=old\nOBS_INGEST_TOKEN=%s\n' "$OLDTOK" > "$ENVF"
    else
        printf '%s\n' "$OLDTOK" > "$TOKF"
        printf 'TN_NODE=old\n' > "$ENVF"
    fi
    printf 'OLD CONFIG\n' > "$CFG"
    printf 'OLD UNIT\n' > "$UNITF"
    TOK_ST=""
    [[ -f "$TOKF" ]] && TOK_ST="$(stat -c '%a %G' "$TOKF")"
    mkdir -p "$T/before"
    cp "$ENVF" "$T/before/env"
    cp "$CFG" "$T/before/cfg"
    cp "$UNITF" "$T/before/unit"
}
rot() { ( sleep() { :; }; for kv in "$@"; do export "${kv?}"; done; obs_rotate_token "$NEWTOK" ) >"$T/tk.out" 2>&1; }
rot_said() { yn grep -qF -- "$1" "$T/tk.out"; }
restarts() { grep -c '^restart telcoin-alloy.service$' "$SYSTEMCTL_LOG"; }
rot_fixture "$NATIVE"
rot; rc=$?
check_rc "rotate: rc 0" 0 "$rc"
check "rotate: the new token in the token file" "$NEWTOK" "$(cat "$TOKF")"
check "rotate: written root:telcoin-alloy 0640" "yes" "$(tw_has "$TOKF 0640 telcoin-alloy")"
check "rotate: Alloy restarted once" "1" "$(restarts)"
check "rotate: watched OBS_ALLOY_SETTLE_SECS reads" "${OBS_ALLOY_SETTLE_SECS:-5}" "$(reads)"
check "rotate: nothing but Alloy is restarted" "" "$(grep '^restart' "$SYSTEMCTL_LOG" | grep -v '^restart telcoin-alloy.service$')"
check_has "rotate: the unit re-rendered with LoadCredential=" "LoadCredential=ingest-token:${TOKF}" "$(cat "$UNITF")"
check "rotate: config.alloy re-rendered" "2" "$(grep -c 'bearer_token_file' "$CFG")"
check "rotate: said" "yes" "$(rot_said 'Ingest token rotated')"
check_lacks "rotate: the token is not printed" "$NEWTOK" "$(cat "$T/tk.out")"
check_lacks "rotate: no token in the env file" "$NEWTOK" "$(cat "$ENVF")"
check_lacks "rotate: no token in the unit" "$NEWTOK" "$(cat "$UNITF")"

rot_fixture "$NATIVE" legacy
rot; rc=$?
check_rc "rotate on the env-file token: rc 0" 0 "$rc"
check "rotate on the env-file token: the new token in the token file" "$NEWTOK" "$(cat "$TOKF")"
check_lacks "rotate on the env-file token: the line is gone" "OBS_INGEST_TOKEN" "$(cat "$ENVF")"
check "rotate on the env-file token: the move is said" "yes" "$(rot_said 'no longer holds the ingest token')"

# Rollback: the restart fails, the previous files come back and Alloy restarts on them.
rot_fixture "$NATIVE"
rot ALLOY_RESTART_FAILS=1; rc=$?
check_rc "rotate, restart fails: rc 1" 1 "$rc"
check "rotate, restart fails: the previous token is back" "$OLDTOK" "$(cat "$TOKF")"
check "rotate, restart fails: the env file is back" "$(cat "$T/before/env")" "$(cat "$ENVF")"
check "rotate, restart fails: config.alloy is back" "$(cat "$T/before/cfg")" "$(cat "$CFG")"
check "rotate, restart fails: the unit is back" "$(cat "$T/before/unit")" "$(cat "$UNITF")"
check "rotate, restart fails: the token file back with the mode and group it had" "yes" "$(tw_has "$TOKF ${TOK_ST}")"
check "rotate, restart fails: Alloy restarted again" "2" "$(restarts)"
check "rotate, restart fails: the rollback is said" "yes" "$(rot_said 'Rolled back: telcoin-alloy.service runs on the previous token again')"
check_lacks "rotate, restart fails: no success line" "Ingest token rotated" "$(cat "$T/tk.out")"

rot_fixture "$NATIVE"
rot ALLOY_UP_CHECKS=2; rc=$?
check_rc "rotate, Alloy does not stay up on either token: rc 1" 1 "$rc"
check "rotate, Alloy does not stay up on either token: the previous token is back" "$OLDTOK" "$(cat "$TOKF")"
check "rotate, Alloy does not stay up on either token: said" "yes" "$(rot_said 'does not stay running on the previous token either')"

rot_fixture "$NATIVE" legacy
rot ALLOY_RESTART_FAILS=1; rc=$?
check_rc "rotate on the env-file token, restart fails: rc 1" 1 "$rc"
check "rotate on the env-file token, restart fails: no token file left" "no" "$(yn test -e "$TOKF")"
check_has "rotate on the env-file token, restart fails: the env file holds the old token again" "OBS_INGEST_TOKEN=${OLDTOK}" "$(cat "$ENVF")"

rot_fixture "$NATIVE"
rot TRF_FAIL=telcoin-alloy.service; rc=$?
check_rc "rotate, the unit write fails: rc 1" 1 "$rc"
check "rotate, the unit write fails: no restart" "0" "$(restarts)"
check "rotate, the unit write fails: the previous token is back" "$OLDTOK" "$(cat "$TOKF")"
check "rotate, the unit write fails: said" "yes" "$(rot_said 'Alloy was not restarted')"

rot_fixture 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nINSTALL_METHOD=binary\nENABLE_OBSERVABILITY=false\nENABLE_METRICS=false'
rot; rc=$?
check_rc "rotate with both pipelines off: refused" 1 "$rc"
check "rotate with both pipelines off: nothing written" "" "$(cat "$TW")"
check "rotate with both pipelines off: said" "yes" "$(rot_said 'both off on this node')"
rot_fixture "$NATIVE"
rm -f "$UNITF"
rot; rc=$?
check_rc "rotate without the unit: refused" 1 "$rc"
check "rotate without the unit: the token file is untouched" "$OLDTOK" "$(cat "$TOKF")"
rot_fixture "$DOCKER"
rot; rc=$?
check_rc "docker rotate: rc 0" 0 "$rc"
check "docker rotate: the sidecar unit mounts the token file" "yes" "$(yn grep -qF -- "source=${TOKF}," "$UNITF")"
check_has "docker rotate: CREDENTIALS_DIRECTORY in the env file" "CREDENTIALS_DIRECTORY=/run/credentials/telcoin-alloy" "$(cat "$ENVF")"

# setup-observability.sh --rotate-token: menu, one-shot, --json.
rot_fixture "$NATIVE"
( sleep() { :; }; addon_meta_write_begin() { return 0; }; rotate_token <<< "$NEWTOK" ) >"$T/tk.out" 2>&1
check "menu rotate: the new token in the token file" "$NEWTOK" "$(cat "$TOKF")"
check "menu rotate: said" "yes" "$(rot_said 'Ingest token rotated')"
rot_fixture "$NATIVE"
( addon_meta_write_begin() { return 0; }; rotate_token <<< "" ) >"$T/tk.out" 2>&1
check "menu rotate, nothing entered: the token file is untouched" "$OLDTOK" "$(cat "$TOKF")"
check "menu rotate, nothing entered: said" "yes" "$(rot_said 'No token entered; nothing was changed.')"
cli() { # cli STDIN ARGS... -- main without --json (root, distro and lock stubbed); RC
    local input="$1"
    shift
    RC=0
    ( sleep() { :; }; check_root() { :; }; detect_distro() { :; }; addon_meta_write_begin() { return 0; }
      main "$@" <<< "$input" ) >"$T/tk.out" 2>&1 || RC=$?
}
rot_fixture "$NATIVE"
cli "$NEWTOK" --rotate-token --token-stdin
check_rc "--rotate-token --token-stdin: rc 0" 0 "$RC"
check "--rotate-token --token-stdin: the new token in the token file" "$NEWTOK" "$(cat "$TOKF")"
check_lacks "--rotate-token --token-stdin: the token is not printed" "$NEWTOK" "$(cat "$T/tk.out")"
rot_fixture "$NATIVE"
( unset TN_OBS_TOKEN; sleep() { :; }; check_root() { :; }; detect_distro() { :; }; addon_meta_write_begin() { return 0; }
  main --rotate-token </dev/null ) >"$T/tk.out" 2>&1
check_rc "--rotate-token without a token or a terminal: rc 1" 1 $?
check "--rotate-token without a token or a terminal: said" "yes" "$(rot_said '--rotate-token needs the new token')"
check "--rotate-token without a token or a terminal: the token file is untouched" "$OLDTOK" "$(cat "$TOKF")"
rot_fixture "$NATIVE"
( export TN_OBS_TOKEN="$NEWTOK"; sleep() { :; }; check_root() { :; }; detect_distro() { :; }
  addon_meta_write_begin() { return 0; }; main --rotate-token </dev/null ) >"$T/tk.out" 2>&1
check_rc "--rotate-token with TN_OBS_TOKEN: rc 0" 0 $?
check "--rotate-token with TN_OBS_TOKEN: rotated" "$NEWTOK" "$(cat "$TOKF")"
rot_fixture "$NATIVE"
cli "$NEWTOK" --rotate-token --token-stdin --enable-logs
check_rc "--rotate-token with an enable: refused" 1 "$RC"
check "--rotate-token with an enable: said" "yes" "$(rot_said '--rotate-token runs on its own')"
check "--rotate-token with an enable: the token file is untouched" "$OLDTOK" "$(cat "$TOKF")"
jrot() { # jrot STDIN [ENV=VAL...] -- main --json --rotate-token --token-stdin; RC, EV
    local input="$1"
    shift
    : > "$T/ev"
    RC=0
    ( sleep() { :; }; check_root() { :; }; detect_distro() { :; }
      addon_meta_write_begin() { return 0; }
      json_setup_fds() { exec 3>>"$T/ev"; }
      for kv in "$@"; do export "${kv?}"; done
      if [[ -n "$input" ]]; then
          main --json --rotate-token --token-stdin <<< "$input"
      else
          unset TN_OBS_TOKEN
          main --json --rotate-token </dev/null
      fi ) >"$T/tk.out" 2>&1 || RC=$?
    EV="$(cat "$T/ev")"
}
rot_fixture "$NATIVE"
jrot "$NEWTOK"
check_rc "json rotate: rc 0" 0 "$RC"
check "json rotate: done ok:true with token:rotated" "yes" \
    "$(yn grep -qF '"event":"done","ok":true,"applied":["token:rotated"]' "$T/ev")"
check "json rotate: only JSON on stdout" "0" "$(grep -cv '^{' "$T/ev")"
check "json rotate: the new token in the token file" "$NEWTOK" "$(cat "$TOKF")"
check_lacks "json rotate: the token is in no event" "$NEWTOK" "$EV"
check_lacks "json rotate: the token is not in the log" "$NEWTOK" "$(cat "$T/tk.out")"
rot_fixture "$NATIVE"
jrot "$NEWTOK" ALLOY_RESTART_FAILS=1
check_rc "json rotate, restart fails: rc 1" 1 "$RC"
check "json rotate, restart fails: the error says it was rolled back" "yes" \
    "$(yn grep -qF '"event":"error","msg":"the ingest token was not rotated: telcoin-alloy.service did not stay running on the new token; the previous token was put back and Alloy runs on it again"' "$T/ev")"
check "json rotate, restart fails: done ok:false" "yes" "$(yn grep -qF '"event":"done","ok":false' "$T/ev")"
check_lacks "json rotate, restart fails: no token:rotated" "token:rotated" "$EV"
check "json rotate, restart fails: the previous token is back" "$OLDTOK" "$(cat "$TOKF")"
rot_fixture "$NATIVE"
jrot ""
check_rc "json rotate without a token: rc 1" 1 "$RC"
check "json rotate without a token: said" "yes" "$(yn grep -qF 'rotating the ingest token needs the new token' "$T/ev")"
check "json rotate without a token: done ok:false" "yes" "$(yn grep -qF '"event":"done","ok":false' "$T/ev")"
check "json rotate without a token: the token file is untouched" "$OLDTOK" "$(cat "$TOKF")"

OBS_ETC_DIR="$SAVED_OBS_ETC_DIR"

finish
