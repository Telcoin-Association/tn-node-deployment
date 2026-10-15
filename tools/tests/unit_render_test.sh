#!/usr/bin/env bash
# tools/tests/unit_render_test.sh -- the node unit, start script and node.env
# writers (tn_write_node_unit, tn_write_start_script, tn_write_node_env).
# Renders both unit forms and both start scripts into a temp tree as a normal
# user; checks the credential line, the log target, the strict sandbox switch,
# that no TN_BLS name is in any rendered file (the unit's UnsetEnvironment= guard
# aside), that the scripts parse and the launch editors can read them, and,
# where systemd-analyze exists, that the units verify and the binary unit's
# exposure score is 3.0 or lower. As root the writers also run, into a fixture
# tree under /root. Maintainer tooling (not updater-tracked). bash 3.2 safe.
# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
TN_ROOT_PREFIX="$TN_TEST_TMP/empty"
mkdir -p "$TN_ROOT_PREFIX"
eval "$(tn_test_source_common)"
T="$TN_TEST_TMP"

# shellcheck disable=SC2034  # read by the library renderers
NETWORK=testnet
DATA_DIR=/var/lib/telcoin
PASSPHRASE_METHOD=stdin
LOG_TARGET=file
TN_DOCKER_IDS=1101:1101
TN_DOCKER_MEMORY=8g
IMG="us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.16.0-adiri"
BIN=/opt/telcoin/telcoin-network
PEERS='--bootstrap-peers "$(cat /etc/telcoin/bootstrap-peers.yaml)"'
ARGS_B="--datadir /var/lib/telcoin --log.stdout.format log-fmt -vvv --http --http.addr 127.0.0.1 --ws --ws.addr 127.0.0.1 ${PEERS}"
ARGS_D="--datadir /home/nonroot --log.stdout.format log-fmt -vvv --http --http.addr 127.0.0.1 --ws --ws.addr 127.0.0.1 ${PEERS}"

render() {  # render <unit|script> <method> [runner args] -> $OUT, $RC
    RC=0
    if [[ "$1" == unit ]]; then
        OUT="$(_tn_node_unit_text "$2" 2>"$T/err")" || RC=$?
    else
        OUT="$(_tn_start_script_text "$2" "$3" "$4" 2>"$T/err")" || RC=$?
    fi
}

# --- the binary unit ------------------------------------------------------------
render unit source
check_rc "binary unit renders" 0 "$RC"
UB="$OUT"
printf '%s\n' "$UB" > "$T/telcoin.service"
for line in "User=telcoin" "Group=telcoin" "ExecStart=/usr/local/libexec/telcoin/tn-start" \
    "LoadCredential=bls-passphrase:/etc/telcoin/bls-passphrase" "EnvironmentFile=/etc/telcoin/node.env" \
    "UnsetEnvironment=TN_BLS_PASSPHRASE" "Environment=HOME=/var/lib/telcoin" "NoNewPrivileges=yes" \
    "ProtectSystem=strict" "ProtectHome=yes" "PrivateTmp=yes" "PrivateDevices=yes" "ProtectKernelTunables=yes" \
    "ProtectKernelModules=yes" "ProtectKernelLogs=yes" "ProtectControlGroups=yes" "ProtectClock=yes" \
    "ProtectHostname=yes" "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK" "RestrictNamespaces=yes" \
    "LockPersonality=yes" "RestrictRealtime=yes" "RestrictSUIDSGID=yes" "ProtectProc=invisible" "LimitCORE=0" \
    "UMask=0077" "CapabilityBoundingSet=" "AmbientCapabilities=" "SystemCallArchitectures=native" \
    "RemoveIPC=yes" "KeyringMode=private" "ReadWritePaths=/var/lib/telcoin" "SyslogIdentifier=telcoin" \
    "StandardOutput=append:/var/log/telcoin/telcoin.log" "StandardError=append:/var/log/telcoin/telcoin-error.log" \
    "MemoryDenyWriteExecute=yes" "SystemCallFilter=@system-service" "SystemCallFilter=~@privileged" \
    "SystemCallErrorNumber=EPERM"; do
    check_has "binary unit: ${line}" "$line" "$UB"
done
check "binary unit: TN_BLS only in the UnsetEnvironment= guard" "UnsetEnvironment=TN_BLS_PASSPHRASE" \
    "$(printf '%s\n' "$UB" | grep TN_BLS)"
check_lacks "binary unit: no LoadCredentialEncrypted for stdin" "LoadCredentialEncrypted" "$UB"
check_lacks "binary unit: log dir not writable" "ReadWritePaths=/var/lib/telcoin /var/log" "$UB"

PASSPHRASE_METHOD=credential render unit source
check_has "credential: LoadCredentialEncrypted line" \
    "LoadCredentialEncrypted=bls-passphrase:/etc/telcoin/bls-passphrase.cred" "$OUT"
check_lacks "credential: no plain LoadCredential" "LoadCredential=" "$OUT"
PASSPHRASE_METHOD=loadcredential render unit source
check_has "loadcredential (old name): LoadCredential line" "LoadCredential=bls-passphrase:/etc/telcoin/bls-passphrase" "$OUT"
PASSPHRASE_METHOD=tpm render unit source
check_lacks "tpm: no credential line" "LoadCredential" "$OUT"
check_has "tpm: TPM device allowed" "DeviceAllow=/dev/tpmrm0 rw" "$OUT"
check_lacks "tpm: no PrivateDevices" "PrivateDevices=yes" "$OUT"
PASSPHRASE_METHOD=env render unit source
check_rc "unknown passphrase method refused" 1 "$RC"

LOG_TARGET=journal render unit source
check_has "journal: StandardOutput" "StandardOutput=journal" "$OUT"
check_has "journal: StandardError" "StandardError=journal" "$OUT"
check_lacks "journal: no append" "append:" "$OUT"
LOG_TARGET=syslog render unit source
check_rc "unknown log target refused" 1 "$RC"
LOG_TARGET="" NETWORK=mainnet render unit source
check_has "mainnet defaults to the journal" "StandardOutput=journal" "$OUT"
check_has "mainnet chain name" "Description=Telcoin Network Node (telcoin)" "$OUT"
LOG_TARGET="" render unit source
check_has "testnet defaults to the files" "StandardOutput=append:/var/log/telcoin/telcoin.log" "$OUT"

NODE_LOG_DIR=/var/log/telcoin/node render unit source
check_has "NODE_LOG_DIR joins ReadWritePaths" "ReadWritePaths=/var/lib/telcoin /var/log/telcoin/node" "$OUT"
NODE_LOG_DIR="/var/log/x y" render unit source
check_rc "NODE_LOG_DIR with a space refused" 1 "$RC"
DATA_DIR=/home/telcoin/data render unit source
check_rc "data dir under /home refused" 1 "$RC"
DATA_DIR=/var/lib/../etc render unit source
check_rc "data dir with .. refused" 1 "$RC"
SERVICE_USER=root render unit source
check_rc "root service user refused" 1 "$RC"

TN_UNIT_STRICT_SANDBOX=0 render unit source
check_lacks "strict 0: no MemoryDenyWriteExecute" "MemoryDenyWriteExecute" "$OUT"
check_lacks "strict 0: no SystemCallFilter" "SystemCallFilter" "$OUT"
TN_UNIT_STRICT_SANDBOX=audit render unit source
check_has "strict audit: filter kept" "SystemCallFilter=@system-service" "$OUT"
check_lacks "strict audit: no EPERM" "SystemCallErrorNumber" "$OUT"

# --- the docker unit --------------------------------------------------------------
render unit docker
check_rc "docker unit renders" 0 "$RC"
UD="$OUT"
printf '%s\n' "$UD" > "$T/telcoin-docker.service"
for line in "User=root" "ExecStart=/usr/local/libexec/telcoin/tn-start-docker" "TimeoutStopSec=100" \
    "LoadCredential=bls-passphrase:/etc/telcoin/bls-passphrase" "PrivateTmp=yes" "UMask=0077" "LimitCORE=0" \
    "Wants=network-online.target docker.service" "After=network-online.target docker.service"; do
    check_has "docker unit: ${line}" "$line" "$UD"
done
check_lacks "docker unit: no Requires=docker" "Requires=" "$UD"
check "docker unit: ExecStartPre stops before it removes" \
    "$(printf 'ExecStartPre=-%s stop -t 80 telcoin\nExecStartPre=-%s rm -f telcoin' "$(_tn_docker_bin)" "$(_tn_docker_bin)")" \
    "$(printf '%s\n' "$UD" | grep '^ExecStartPre=')"
check_has "docker unit: ExecStop waits 80 s" "ExecStop=$(_tn_docker_bin) stop -t 80 telcoin" "$UD"
check "docker unit: TN_BLS only in the guard" "UnsetEnvironment=TN_BLS_PASSPHRASE" "$(printf '%s\n' "$UD" | grep TN_BLS)"

# --- the start scripts --------------------------------------------------------------
render script source "$BIN" "$ARGS_B"
check_rc "binary start script renders" 0 "$RC"
SB="$OUT"
printf '%s\n' "$SB" > "$T/tn-start"
render script docker "$IMG" "$ARGS_D"
check_rc "docker start script renders" 0 "$RC"
SD="$OUT"
printf '%s\n' "$SD" > "$T/tn-start-docker"
for f in tn-start tn-start-docker; do
    check "${f}: no TN_BLS anywhere" "0" "$(grep -c TN_BLS "$T/$f")"
    check "${f}: no export of a passphrase" "0" "$(grep -ci 'export.*pass' "$T/$f")"
    rc=0; bash -n "$T/$f" 2>/dev/null || rc=$?
    check_rc "${f}: parses under bash ${BASH_VERSION}" 0 "$rc"
    check_has "${f}: credential opened as stdin" \
        'exec < "${CREDENTIALS_DIRECTORY:?not set: start the node with systemctl}/bls-passphrase"' "$(cat "$T/$f")"
    check "${f}: peers map still readable by the launch editor" '$(cat /etc/telcoin/bootstrap-peers.yaml)' \
        "$(tn_launch_flag_get "$T/$f" --bootstrap-peers 2>/dev/null)"
    check "${f}: passphrase source on the node line" "stdin" \
        "$(tn_launch_flag_get "$T/$f" --bls-passphrase-source 2>/dev/null)"
done
check_has "binary script: exec line" "exec ${BIN} node --bls-passphrase-source stdin ${ARGS_B}" "$SB"
check "binary script: runner" "binary ${BIN}" "$(_tn_launch_awk runner "$T/tn-start" 2>/dev/null)"
check "docker script: runner" "docker ${IMG}" "$(_tn_launch_awk runner "$T/tn-start-docker" 2>/dev/null)"
for w in "-i" "--cap-drop ALL" "--security-opt no-new-privileges" "--read-only" "--pids-limit 4096" \
    "--memory 8g" "--ulimit nofile=65536:65536" "--log-opt max-size=50m" "--log-opt max-file=3" \
    "--stop-timeout 80" "--pull=never" "--user 1101:1101" "-e PRIMARY_LISTENER_MULTIADDR" \
    "-v /var/lib/telcoin:/home/nonroot"; do
    check_has "docker script: ${w}" "yes" "$(grep -q -- " ${w} " "$T/tn-start-docker" && echo yes)"
done
check_lacks "docker script: config dir not mounted" "/etc/telcoin:" "$SD"
check_lacks "docker script: no -e of a passphrase" "-e TN_BLS" "$SD"

PASSPHRASE_METHOD=tpm render script source "$BIN" "$ARGS_B"
check_has "tpm script: unseal into stdin" "exec < <(tn_unseal)" "$OUT"
check_lacks "tpm script: no TN_BLS" "TN_BLS" "$OUT"
printf '%s\n' "$OUT" > "$T/tn-start-tpm"
rc=0; bash -n "$T/tn-start-tpm" 2>/dev/null || rc=$?
check_rc "tpm script parses" 0 "$rc"

# Node arguments the writer refuses.
for bad in "--datadir /var/lib/telcoin" "--http --observer" "--http --validator" \
    "--http --bls-passphrase-source env" "--http; rm -rf /" '--http $(id)' '--http `id`' \
    "--http --x a|b" "--http --x a>b" '--http "$(cat relative)"' '--http "$(cat /a b)"' \
    "--http --x *" "--http -x" "--http --x 'a'"; do
    render script source "$BIN" "$bad"
    check_rc "args refused: ${bad}" 1 "$RC"
done
render script docker "evil.example/x:v0.16.0-adiri" "$ARGS_D"
check_rc "docker: other repository refused" 1 "$RC"
render script docker "$IMG" "$ARGS_D --x"
check_rc "docker: flag without value accepted" 0 "$RC"
render script source "relative/bin" "$ARGS_B"
check_rc "binary: relative runner refused" 1 "$RC"
TN_DOCKER_IDS=0:0 render script docker "$IMG" "$ARGS_D"
check_rc "docker: uid 0 refused" 1 "$RC"

# --- tn_docker_image_allowed / validate_docker_image ----------------------------------
REPO="us-docker.pkg.dev/telcoin-network/tn-public/adiri"
D64="$(printf '0123456789abcdef%.0s' 1 2 3 4)"
img_case() {  # img_case NAME RC IMAGE [NETWORK]
    local rc=0
    tn_docker_image_allowed "$3" "${4:-}" || rc=$?
    check_rc "image: $1" "$2" "$rc"
}
img_case "testnet release tag" 0 "${REPO}:v0.16.0-adiri"
img_case "testnet digest" 0 "${REPO}@sha256:${D64}"
img_case "short digest refused" 1 "${REPO}@sha256:abc"
img_case "upper-case digest refused" 1 "${REPO}@sha256:$(printf '%s' "$D64" | tr a-f A-F)"
img_case "hot-patch tag refused" 1 "${REPO}:v0.16.0-adiri-hotfix"
img_case "devnet tag refused" 1 "${REPO}:v0.17.0-devnet"
img_case "latest refused" 1 "${REPO}:latest"
img_case "other repository refused" 1 "docker.io/library/busybox:v0.16.0-adiri"
img_case "lookalike repository refused" 1 "${REPO}x:v0.16.0-adiri"
img_case "leading dash refused" 1 "-v/etc:/x"
img_case "whitespace refused" 1 "${REPO}:v0.16.0-adiri --privileged"
img_case "mainnet has no repository yet" 1 "${REPO}:v0.16.0" mainnet
img_case "devnet refused" 1 "${REPO}:v0.16.0-adiri" devnet
rc=0; TN_DOCKER_REQUIRE_DIGEST=1 tn_docker_image_allowed "${REPO}:v0.16.0-adiri" testnet || rc=$?
check_rc "image: tag refused once digests are required" 1 "$rc"
rc=0; TN_DOCKER_REQUIRE_DIGEST=1 tn_docker_image_allowed "${REPO}@sha256:${D64}" testnet || rc=$?
check_rc "image: digest passes once digests are required" 0 "$rc"
rc=0; validate_docker_image "${REPO}:v0.16.0-adiri" || rc=$?
check_rc "validate_docker_image uses NETWORK" 0 "$rc"
rc=0; validate_docker_image "evil.example/adiri:v0.16.0-adiri" || rc=$?
check_rc "validate_docker_image refuses another registry" 1 "$rc"
rc=0; tn_docker_ref_ok "evil.example/adiri:v0.16.0-adiri-x" || rc=$?
check_rc "tn_docker_ref_ok checks the shape only" 0 "$rc"
rc=0; tn_docker_ref_ok "-x:y" || rc=$?
check_rc "tn_docker_ref_ok refuses a leading dash" 1 "$rc"

# --- node.env -------------------------------------------------------------------------
P=/ip4/10.0.0.5/udp/49590/quic-v1
W=/ip4/10.0.0.5/udp/49594/quic-v1
rc=0; ENV_OUT="$(_tn_node_env_text "$P" "$W" 2>/dev/null)" || rc=$?
check_rc "node.env renders" 0 "$rc"
check_has "node.env: primary" "PRIMARY_LISTENER_MULTIADDR=${P}" "$ENV_OUT"
check_has "node.env: worker" "WORKER_LISTENER_MULTIADDR=${W}" "$ENV_OUT"
check_has "node.env: rpc addr default" "TN_RPC_ADDR=127.0.0.1" "$ENV_OUT"
check_lacks "node.env: no TN_BLS" "TN_BLS" "$ENV_OUT"
for pair in "|${W}" "${P}|" "/ip4/10.0.0.5/udp/49590/quic-v1;x|${W}" "${P}|/ip4/1.2.3.4/tcp/1"; do
    rc=0; _tn_node_env_text "${pair%%|*}" "${pair#*|}" >/dev/null 2>&1 || rc=$?
    check_rc "node.env refused: ${pair}" 1 "$rc"
done
rc=0; _tn_node_env_text "$P" "$W" "1.2.3.4;x" >/dev/null 2>&1 || rc=$?
check_rc "node.env: bad rpc addr refused" 1 "$rc"

# The start script reads node.env without sourcing it.
mkdir -p "$T/run"
printf '%s\n' "$ENV_OUT" 'TN_BLS_PASSPHRASE=leak' 'X=$(touch '"$T"'/run/pwned)' > "$T/run/node.env"
printf 'secret\n' > "$T/run/bls-passphrase"
printf '#!/bin/sh\nprintf "%%s|" "$PRIMARY_LISTENER_MULTIADDR" "${TN_BLS_PASSPHRASE:-unset}" "$3"\nread -r p; printf "%%s\\n" "$p"\n' > "$T/run/node"
chmod 0755 "$T/run/node"
CONFIG_DIR="$T/run" render script source "$T/run/node" "--http"
printf '%s\n' "$OUT" > "$T/run/tn-start"
got="$(cd "$T/run" && env -u TN_BLS_PASSPHRASE CREDENTIALS_DIRECTORY="$T/run" bash "$T/run/tn-start" 2>&1)"
check "start script: listeners exported, nothing else, passphrase on stdin" "${P}|unset|stdin|secret" "$got"
check "start script: node.env never executed" "no" "$([[ -e "$T/run/pwned" ]] && echo yes || echo no)"
got="$(env -u CREDENTIALS_DIRECTORY bash "$T/run/tn-start" 2>&1)"; rc=$?
check "start script: refuses without systemd credentials" "1 yes" \
    "$rc $(printf '%s' "$got" | grep -q 'start the node with systemctl' && echo yes)"

# --- systemd-analyze ------------------------------------------------------------------
if command -v systemd-analyze >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    mkdir -p "$T/sa"
    for u in telcoin telcoin-docker; do
        sed 's|^ExecStart=.*|ExecStart=/bin/true|' "$T/${u}.service" > "$T/sa/${u}.service"
        out="$(systemd-analyze verify "$T/sa/${u}.service" 2>&1)"; rc=$?
        check_rc "systemd-analyze verify ${u}" 0 "$rc" || printf '%s\n' "$out" | sed 's/^/      /'
        check_lacks "systemd-analyze verify ${u}: nothing about the unit" "${u}.service:" "$out"
    done
    score="$(systemd-analyze security --offline=true --no-pager "$T/sa/telcoin.service" 2>/dev/null \
        | grep -o 'Overall exposure level for [^:]*: [0-9.]*' | awk '{print $NF}')"
    check "binary unit exposure 3.0 or lower (got ${score:-none})" "yes" \
        "$(awk -v s="${score:-99}" 'BEGIN { print (s + 0 <= 3.0) ? "yes" : "no" }')"
else
    skip "systemd-analyze verify and security" "systemd-analyze or a running systemd absent"
fi

# --- the writers, as root ---------------------------------------------------------------
if [[ "$(id -u)" != 0 ]]; then
    rc=0; tn_write_node_env "$P" "$W" >/dev/null 2>&1 || rc=$?
    check "writer refused outside a root-owned tree (not root)" "yes" "$([[ $rc -ne 0 ]] && echo yes)"
    skip "writers into a root-owned fixture tree" "not root"
    finish
fi
R="$(mktemp -d /root/tn_unit.XXXXXX)"
chmod 0755 "$R"
trap 'rm -rf "$R"; tn_test_cleanup' EXIT
mkdir -p "$R/etc/telcoin" "$R/etc/systemd/system" "$R/opt/telcoin"
chmod 0755 "$R/etc" "$R/etc/telcoin" "$R/etc/systemd" "$R/etc/systemd/system" "$R/opt" "$R/opt/telcoin"
install -o root -g root -m 0755 /dev/null "$R$BIN"
TN_ROOT_PREFIX="$R"
rc=0; tn_write_node_env "$P" "$W" >/dev/null 2>&1 || rc=$?
check_rc "root: node.env written" 0 "$rc"
check "root: node.env mode" "0 644" "$(stat -c '%u %a' "$R/etc/telcoin/node.env" 2>/dev/null)"
rc=0; tn_write_start_script source "$BIN" "$ARGS_B" >/dev/null 2>&1 || rc=$?
check_rc "root: binary start script written" 0 "$rc"
check "root: tn-start root 0755" "0 0 755" "$(stat -c '%u %g %a' "$R/usr/local/libexec/telcoin/tn-start" 2>/dev/null)"
check "root: tn-start content" "$SB" "$(cat "$R/usr/local/libexec/telcoin/tn-start" 2>/dev/null)"
rc=0; tn_write_start_script docker "$IMG" "$ARGS_D" >/dev/null 2>&1 || rc=$?
check_rc "root: docker start script written" 0 "$rc"
check "root: tn-start-docker root 0755 (no secret in it; the UI reads it)" "0 0 755" \
    "$(stat -c '%u %g %a' "$R/usr/local/libexec/telcoin/tn-start-docker" 2>/dev/null)"
rc=0; tn_write_node_unit source >/dev/null 2>&1 || rc=$?
check_rc "root: unit written" 0 "$rc"
check "root: unit root 0644" "0 0 644" "$(stat -c '%u %g %a' "$R/etc/systemd/system/telcoin.service" 2>/dev/null)"
check "root: unit content" "$UB" "$(cat "$R/etc/systemd/system/telcoin.service" 2>/dev/null)"
chmod 0777 "$R$BIN"
before="$(cat "$R/usr/local/libexec/telcoin/tn-start")"
rc=0; tn_write_start_script source "$BIN" "$ARGS_B --x" >/dev/null 2>&1 || rc=$?
check_rc "root: world-writable binary refused" 1 "$rc"
check "root: refused write left the script" "$before" "$(cat "$R/usr/local/libexec/telcoin/tn-start")"
rc=0; tn_install_journald_dropin >/dev/null 2>&1 || rc=$?
check_rc "root: journald drop-in written" 0 "$rc"
check_has "root: journald cap" "SystemMaxUse=4G" "$(cat "$R/etc/systemd/journald.conf.d/50-telcoin.conf" 2>/dev/null)"
finish
