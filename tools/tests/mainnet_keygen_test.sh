#!/usr/bin/env bash
# tools/tests/mainnet_keygen_test.sh -- mainnet key generation ahead of mainnet
# (TN_MAINNET_KEYGEN_ENABLED, setup_mainnet_keygen_only). While TN_MAINNET_ENABLED is
# 0, setup-node.sh --json --phase=keygen --network mainnet runs with the operator's
# own node binary (--install-method existing --binary-path) when that binary is a
# mainnet build (one empty "Build Features:" line): it generates the keys and the
# proof of possession for the --address it is given, gets no chain configs, starts
# nothing and says what to send. The release, docker and source methods are refused
# with a message that names the way that works; finalize is refused as before; with
# TN_MAINNET_KEYGEN_ENABLED=0 the keygen is refused as before.
#
# The refusals run the real script in a child bash: each one stops before the root
# check, so nothing under the fixture root is written. The keygen itself runs from a
# copy of setup-node.sh without its last line, sourced at the top level, with the
# calls that touch the host replaced (the root check, the preflight's host checks,
# the service account and directories, .node-meta writes, the credential store); the
# real preflight of the existing binary and of the passphrase method,
# step_create_infrastructure, step_generate_keys and tn_keytool run against a
# recording telcoin-network stub.
# Maintainer tooling (not updater-tracked). bash 3.2 safe.
# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
REC="$T/rec"
export REC
mkdir -p "$T/sn" "$T/off" "$T/bin" "$REC" "$T/root" "$T/cfg"
grep -v '^main "\$@"$' "$TN_TEST_REPO/setup-node.sh" > "$T/sn/setup-node.sh"
cp "$TN_TEST_REPO/setup-node.sh" "$T/sn/setup-node-run.sh"
cp "$TN_TEST_REPO/setup-node.sh" "$T/off/setup-node-run.sh"
ln -s "$TN_TEST_REPO/lib" "$T/sn/lib"
# $T/off: the library with the key-generation switch at 0.
cp -R "$TN_TEST_REPO/lib" "$T/off/lib"
sed 's/^readonly TN_MAINNET_KEYGEN_ENABLED=1$/readonly TN_MAINNET_KEYGEN_ENABLED=0/' \
    "$TN_TEST_REPO/lib/common.sh" > "$T/off/lib/common.sh"
check "the switch-off copy sets TN_MAINNET_KEYGEN_ENABLED=0" yes \
    "$(grep -qx 'readonly TN_MAINNET_KEYGEN_ENABLED=0' "$T/off/lib/common.sh" && echo yes || echo no)"

# Stub node binaries. --version prints one "Build Features:" line holding the
# features in <stub>.features; any other call is the keytool: it records its argv
# and stdin and writes an encrypted-looking key and node-info.yaml in --datadir.
cat > "$T/bin/stub" <<'STUB'
#!/bin/sh
if [ "$1" = "--version" ]; then
    printf 'telcoin-network\nVersion: 0.18.0\nCommit SHA: 0000000\nBuild Features: %s\n' "$(cat "$0.features")"
    exit 0
fi
: > "$REC/keytool.argv"
dd=""
prev=""
for a in "$@"; do
    printf '%s\n' "$a" >> "$REC/keytool.argv"
    [ "$prev" = "--datadir" ] && dd="$a"
    prev="$a"
done
cat > "$REC/keytool.stdin"
mkdir -p "$dd/node-keys"
: > "$dd/node-keys/bls.kw"
printf 'name: stub\n' > "$dd/node-info.yaml"
STUB
for n in tn-main tn-adiri tn-testutils; do
    cp "$T/bin/stub" "$T/bin/$n"
    chmod 0755 "$T/bin/$n"
done
: > "$T/bin/tn-main.features"
printf 'adiri' > "$T/bin/tn-adiri.features"
printf 'test_utils' > "$T/bin/tn-testutils.features"
# Nothing may start or enable a node: systemctl and docker record any call.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$REC/$(basename "$0").log"\n' > "$T/bin/systemctl"
cp "$T/bin/systemctl" "$T/bin/docker"
chmod 0755 "$T/bin/systemctl" "$T/bin/docker"
PATH="$T/bin:$PATH"

ADDR="0x000000000000000000000000000007310005eed3"
PASS="a-mainnet-passphrase-20b"
MK=(--json --phase=keygen --network mainnet --address "$ADDR"
    --external-primary /ip4/203.0.113.10/udp/49590/quic-v1
    --external-worker /ip4/203.0.113.10/udp/49594/quic-v1
    --listener-primary /ip4/0.0.0.0/udp/49590/quic-v1
    --listener-worker /ip4/0.0.0.0/udp/49594/quic-v1
    --passphrase-stdin)
MAINNET_OFF="Mainnet is not enabled in this script release (lib/common.sh TN_MAINNET_ENABLED); nothing on this host was changed."
WAY="Generate the mainnet keys with --phase=keygen --install-method existing --binary-path <a telcoin-network binary built with no build features>; the rest of a mainnet install waits for the script release that enables mainnet (lib/common.sh TN_MAINNET_ENABLED). Nothing on this host was changed."
BEFORE_GENESIS="before genesis no mainnet release, image or source tag can be verified."

has() {
    case "$1" in
        *"$2"*) echo yes ;;
        *) echo no ;;
    esac
}
done_false() { printf '{"event":"done","ok":false,"msg":"%s"}' "$1"; }

# child DIR ARGS... -- DIR's real setup-node.sh in a child bash, the passphrase on
# stdin and an empty fixture root: RC, OUT (the JSON stream), LAST (its last line)
# and FILES (what the run left under the fixture root).
child() {
    local dir="$1"
    shift
    rm -rf "${T:?}/fx" "${REC:?}"/*
    mkdir -p "$T/fx"
    RC=0
    OUT="$(printf '%s\n' "$PASS" | TN_ROOT_PREFIX="$T/fx" "$BASH" "$dir/setup-node-run.sh" "$@" 2> "$T/child.err")" || RC=$?
    LAST="$(printf '%s\n' "$OUT" | tail -n 1)"
    FILES="$(find "$T/fx" -mindepth 1 2>/dev/null)"
}
# refused NAME MSG -- the last child run stopped with rc 1 and done MSG, wrote
# nothing, never ran the keytool.
refused() {
    check_rc "$1: rc 1" 1 "$RC"
    check "$1: ends with the refusal" "$(done_false "$2")" "$LAST"
    check "$1: nothing written, no keytool" " no" "${FILES} $([[ -e "$REC/keytool.argv" ]] && echo yes || echo no)"
}

# ---- the switch ------------------------------------------------------------------------
TN_ROOT_PREFIX="$T/root"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/sn/setup-node.sh"
set +e  # setup-node.sh makes SERVICE_NAME readonly
check "TN_MAINNET_ENABLED stays 0" "0" "${TN_MAINNET_ENABLED-unset}"
check "TN_MAINNET_KEYGEN_ENABLED is 1 in this release" "1" "${TN_MAINNET_KEYGEN_ENABLED-unset}"
rc=0; tn_mainnet_keygen_enabled || rc=$?
check_rc "tn_mainnet_keygen_enabled: rc 0" 0 "$rc"
mode() {  # mode JSON PHASE NETWORK -- setup_mainnet_keygen_only's rc
    local rc=0
    ( JSON_MODE="$1"; JSON_PHASE="$2"; JSON_NETWORK_INPUT="$3"; setup_mainnet_keygen_only ) || rc=$?
    printf '%s\n' "$rc"
}
check_rc "keygen-only mode: --json keygen on mainnet" 0 "$(mode true keygen mainnet)"
check_rc "keygen-only mode: not for finalize" 1 "$(mode true finalize mainnet)"
check_rc "keygen-only mode: not for testnet" 1 "$(mode true keygen testnet)"
check_rc "keygen-only mode: not outside --json" 1 "$(mode false keygen mainnet)"
check_rc "keygen-only mode: not once mainnet is enabled" 1 \
    "$( rc=0; ( tn_mainnet_enabled() { return 0; }; JSON_MODE=true; JSON_PHASE=keygen; JSON_NETWORK_INPUT=mainnet; setup_mainnet_keygen_only ) || rc=$?; echo "$rc" )"

# ---- refusals, each before the root check ---------------------------------------------
child "$T/sn" "${MK[@]}" --install-method release --release-tag v1.0.0
refused "release on mainnet" "--install-method release cannot install a mainnet node yet: ${BEFORE_GENESIS} ${WAY}"
child "$T/sn" "${MK[@]}" --install-method docker --docker-image "ghcr.io/telcoin-association/tn-mainnet@sha256:$(printf '%064d' 0)"
refused "docker on mainnet" "--install-method docker cannot install a mainnet node yet: ${BEFORE_GENESIS} ${WAY}"
child "$T/sn" "${MK[@]}" --install-method source --release-tag v1.0.0
refused "source on mainnet" "--install-method source cannot install a mainnet node yet: ${BEFORE_GENESIS} ${WAY}"
child "$T/sn" "${MK[@]}"
refused "no install method on mainnet" "--install-method is missing: ${BEFORE_GENESIS} ${WAY}"
child "$T/sn" "${MK[@]}" --install-method existing
refused "existing without --binary-path" "--install-method existing needs --binary-path PATH here: ${BEFORE_GENESIS} ${WAY}"
child "$T/sn" "${MK[@]}" --install-method existing --binary-path "$T/bin/tn-adiri"
refused "a binary built with the testnet feature" "Refusing the node binary at $T/bin/tn-adiri: it is not a mainnet build (This build has the features adiri; a mainnet build has none.). A mainnet node runs telcoin-network built with no build features (cargo build -p telcoin-network --bin telcoin-network --release --locked). The binary was not used."
child "$T/sn" "${MK[@]}" --binary-path "$T/bin/tn-testutils"
refused "a test build (--binary-path alone means existing)" "Refusing the node binary at $T/bin/tn-testutils: it is not a mainnet build (This build has the features test_utils; a mainnet build has none.). A mainnet node runs telcoin-network built with no build features (cargo build -p telcoin-network --bin telcoin-network --release --locked). The binary was not used."
child "$T/sn" "${MK[@]}" --install-method existing --binary-path "$T/bin/no-such-binary"
refused "a binary that does not run" "Refusing the node binary at $T/bin/no-such-binary: its --version did not run, so whether it is a mainnet build cannot be told. The binary was not used."
child "$T/sn" "${MK[@]/$ADDR/}" --install-method existing --binary-path "$T/bin/tn-main"
refused "no execution address" "--address is missing: keygen needs the node's execution address (0x followed by 40 hex digits)."
child "$T/sn" "${MK[@]/$ADDR/0x1234}" --install-method existing --binary-path "$T/bin/tn-main"
refused "a malformed execution address" "invalid --address 0x1234 -- expected 0x followed by 40 hex digits."
child "$T/sn" "${MK[@]}" --install-method existing --binary-path "$T/bin/tn-main" --passphrase-method stdin
refused "the passphrase in a root-only file" "--passphrase-method stdin is not taken on mainnet: the passphrase is kept only as an encrypted credential there."
PASS_SAVED="$PASS"
PASS="abcdefghijklmno"
child "$T/sn" "${MK[@]}" --install-method existing --binary-path "$T/bin/tn-main"
check_rc "a 15-byte passphrase: rc 1" 1 "$RC"
check "a 15-byte passphrase: the mainnet rule names 16 bytes" yes "$(has "$LAST" "16")"
check "a 15-byte passphrase: nothing written" "" "$FILES"
PASS="$PASS_SAVED"
# Finalize, and the keygen with the switch at 0: the refusal of today, byte for byte.
child "$T/sn" --json --phase=finalize --network mainnet --install-method existing --binary-path "$T/bin/tn-main" \
    --listener-primary /ip4/0.0.0.0/udp/49590/quic-v1 --listener-worker /ip4/0.0.0.0/udp/49594/quic-v1
refused "finalize on mainnet" "$MAINNET_OFF"
check_has "finalize on mainnet: the error event of today" "{\"event\":\"error\",\"msg\":\"${MAINNET_OFF}\"}" "$OUT"
child "$T/off" "${MK[@]}" --install-method existing --binary-path "$T/bin/tn-main"
refused "keygen with TN_MAINNET_KEYGEN_ENABLED=0" "$MAINNET_OFF"

# ---- the keygen ---------------------------------------------------------------------
if [[ "$(id -u)" == 0 ]]; then
    SERVICE_USER=nobody
    SERVICE_GROUP="$(id -gn nobody 2>/dev/null || echo nogroup)"
else
    SERVICE_USER="$(id -un)"
    SERVICE_GROUP="$(id -gn)"
fi
TN_UPDATE_LOCK_FILE="$T/update.lock"
CONFIG_DIR="$T/cfg"
check_root() { : > "$REC/root-reached"; }
# The preflight's own host checks (OS, packages, kernel, internet, hardware, systemd)
# are not this test's: its install-method and passphrase parts run for real.
step_preflight() {
    _preflight_existing
    setup_passphrase_method
}
tn_creds_supported() { return 0; }
tn_credential_key() { printf 'host+tpm2\n'; }
_tn_root_binary_ok() { TN_ROOT_BINARY_REAL="$1"; return 0; }
tn_service_user_can_run() { return 0; }
tn_service_user_ok() { return 0; }
tn_testnet_addons_present() { return 1; }
rm() { case "$*" in *.pwd.lock*) return 0 ;; esac; command rm "$@"; }
create_service_user() { :; }
create_directories() {
    mkdir -p "$DATA_DIR"
    if [[ "$(id -u)" == 0 ]]; then chown nobody "$DATA_DIR"; fi
}
tn_install_logrotate() { return 0; }
write_node_meta() { printf '%s\n' "$@" >> "$REC/meta.log"; }
meta_unset() { printf 'unset %s\n' "$1" >> "$REC/meta.log"; }
ensure_chain_configs_available() { : > "$REC/chain-configs"; return 1; }
tn_as_service_user() { "$@"; }
tn_store_credential() { printf '%s %s\n' "$1" "$2" > "$REC/credential"; }
_tn_shred() { :; }
display_node_info() { :; }
step_write_config() { : > "$REC/write-config"; }
step_create_service() { : > "$REC/create-service"; }

# keygen ARGS... -- main in a subshell, the passphrase on stdin: JSON in $T/out,
# the rest in $T/err; prints the exit status.
keygen() {
    local rc=0
    rm -rf "${T:?}/data" "${T:?}/update.lock" "${T:?}/update.lock.d"
    command rm -f "${REC:?}"/*
    ( main "$@" ) <<< "$PASS" > "$T/out" 2> "$T/err" || rc=$?
    printf '%s\n' "$rc"
}
KGM=("${MK[@]}" --install-method existing --binary-path "$T/bin/tn-main" --data-dir "$T/data")
check_rc "keygen: rc 0" 0 "$(keygen "${KGM[@]}")"
check "keygen: done ok" yes "$(has "$(tail -n 1 "$T/out")" "\"event\":\"done\",\"ok\":true,\"phase\":\"keygen\"")"
check "keygen: the mainnet done message" yes \
    "$(has "$(tail -n 1 "$T/out")" "\"msg\":\"mainnet keys generated -- BACK THEM UP; send $T/data/node-info.yaml only, never the keys or the passphrase; finalize once the mainnet release and genesis are published\"")"
check "keygen: the root check was reached" yes "$([[ -e "$REC/root-reached" ]] && echo yes || echo no)"
argv="$(cat "$REC/keytool.argv" 2>/dev/null)"
check "keytool: generate validator for the Safe address" yes \
    "$(has "$(printf '%s ' $argv)" "keytool generate validator --address ${ADDR} ")"
check "keytool: the passphrase source is stdin" yes \
    "$(has "$(printf '%s ' $argv)" "--bls-passphrase-source stdin ")"
check "keytool: the external addresses" yes \
    "$(has "$(printf '%s ' $argv)" "--external-primary-addr /ip4/203.0.113.10/udp/49590/quic-v1 --external-worker-addrs /ip4/203.0.113.10/udp/49594/quic-v1")"
check "keytool: the passphrase on stdin" "$PASS" "$(cat "$REC/keytool.stdin" 2>/dev/null)"
check_lacks "keytool: the passphrase in no argv" "$PASS" "$argv"
check_lacks "keytool: no cleartext key source" "no-passphrase" "$argv"
check "keygen: an encrypted key, no cleartext one" "yes no" \
    "$([[ -f "$T/data/node-keys/bls.kw" ]] && echo yes || echo no) $([[ -e "$T/data/node-keys/bls.key" ]] && echo yes || echo no)"
check "keygen: the passphrase kept as a TPM-sealed credential" "$CONFIG_DIR/bls-passphrase.cred host+tpm2" "$(cat "$REC/credential" 2>/dev/null)"
meta="$(cat "$REC/meta.log" 2>/dev/null)"
for kv in INSTALL_METHOD=existing "BINARY_PATH=$T/bin/tn-main" "DATA_DIR=$T/data" OWNERSHIP_LAYOUT=2 \
          PASSPHRASE_METHOD=credential CREDENTIAL_KEY=host+tpm2 "HOST_SERVICE_USER=${SERVICE_USER}"; do
    check_has "keygen: .node-meta records ${kv%%=*} for finalize" "$kv" "$meta"
done
check_lacks "keygen: .node-meta records no NETWORK (finalize takes --network)" "NETWORK=" "$meta"
check "keygen: no chain configs asked for" no "$([[ -e "$REC/chain-configs" ]] && echo yes || echo no)"
check "keygen: no chain-config file anywhere" "" \
    "$(find "$T" -name genesis.yaml -o -name committee.yaml -o -name parameters.yaml 2>/dev/null)"
check "keygen: the skip is said" yes \
    "$(has "$(cat "$T/out")" "{\"event\":\"log\",\"msg\":\"Mainnet chain configs are not published before genesis: keygen goes on without them. Finalize needs them, and runs only from the script release that pins them.\"}")"
check "keygen: no config, no service, no systemctl, no docker" "no no no no" \
    "$([[ -e "$REC/write-config" ]] && echo yes || echo no) $([[ -e "$REC/create-service" ]] && echo yes || echo no) $([[ -e "$REC/systemctl.log" ]] && echo yes || echo no) $([[ -e "$REC/docker.log" ]] && echo yes || echo no)"
check "keygen: node-info.yaml written" yes "$([[ -f "$T/data/node-info.yaml" ]] && echo yes || echo no)"
check "next: send node-info.yaml" yes "$(has "$(cat "$T/out")" "Send $T/data/node-info.yaml to the genesis ceremony: it is public")"
check "next: never the keys or the passphrase" yes "$(has "$(cat "$T/out")" "Never send or copy anywhere $T/data/node-keys/ (bls.kw is the BLS private key) or the BLS passphrase.")"
check "next: finalize later" yes "$(has "$(cat "$T/out")" "run setup-node.sh --json --phase=finalize on this host; it uses these keys as they are.")"

# Over existing keys: refused, the keytool does not run again.
mkdir -p "$T/data/node-keys"
command rm -f "$REC/keytool.argv"
rc=0; ( main "${KGM[@]}" ) <<< "$PASS" > "$T/out" 2> "$T/err" || rc=$?
check_rc "existing keys: rc 1" 1 "$rc"
check "existing keys: refused" "$(done_false "node-keys already exist at $T/data/node-keys -- refusing to overwrite in non-interactive mode")" "$(tail -n 1 "$T/out")"
check "existing keys: no keytool" no "$([[ -e "$REC/keytool.argv" ]] && echo yes || echo no)"
command rm -rf "$T/data"

# Controls: testnet keygen gets its chain configs and the message of before; with
# mainnet enabled (the launch release) mainnet keygen asks for them too.
KGT=()
for a in "${KGM[@]}"; do
    if [[ "$a" == mainnet ]]; then KGT+=(testnet); else KGT+=("$a"); fi
done
check_rc "testnet keygen: rc 1 at the (stubbed) chain-config refusal" 1 "$(keygen "${KGT[@]}")"
check "testnet keygen: chain configs asked for" yes "$([[ -e "$REC/chain-configs" ]] && echo yes || echo no)"
ensure_chain_configs_available() { : > "$REC/chain-configs"; return 0; }
check_rc "testnet keygen: rc 0" 0 "$(keygen "${KGT[@]}")"
check "testnet keygen: the done message of before" yes \
    "$(has "$(tail -n 1 "$T/out")" "\"msg\":\"keys generated -- BACK THEM UP before finalizing\"}")"
check_lacks "testnet keygen: no mainnet next steps" "genesis ceremony" "$(cat "$T/out")"
ensure_chain_configs_available() { : > "$REC/chain-configs"; return 1; }
rc="$( tn_mainnet_enabled() { return 0; }; keygen "${KGM[@]}" )"
check_rc "mainnet enabled: keygen stops at the chain configs" 1 "$rc"
check "mainnet enabled: chain configs asked for" yes "$([[ -e "$REC/chain-configs" ]] && echo yes || echo no)"
check "mainnet enabled: no keytool" no "$([[ -e "$REC/keytool.argv" ]] && echo yes || echo no)"

# ---- the build-feature rule on every mainnet existing install -------------------------
# _preflight_existing (keygen of a launch release, an interactive install) refuses a
# binary that is not a mainnet build; testnet takes any binary as before.
pe() {  # pe NETWORK BINARY -- _preflight_existing's rc
    local rc=0
    ( NETWORK="$1"; BINARY_PATH="$2"; JSON_MODE=true; exec 3>/dev/null; _preflight_existing ) > /dev/null 2>&1 || rc=$?
    printf '%s\n' "$rc"
}
check_rc "preflight existing, mainnet: a mainnet build passes" 0 "$(pe mainnet "$T/bin/tn-main")"
check_rc "preflight existing, mainnet: a testnet build refused" 1 "$(pe mainnet "$T/bin/tn-adiri")"
check_rc "preflight existing, testnet: any binary, as before" 0 "$(pe testnet "$T/bin/tn-adiri")"

finish
