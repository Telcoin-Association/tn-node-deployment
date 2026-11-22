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
# What .node-meta held when the keys were made.
[ -f "$REC/meta.log" ] && cp "$REC/meta.log" "$REC/meta.at-keytool"
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
# The binary runs (as root, in a real run) only once it passed the ownership and mode
# check: a group-writable one, refused for root and any other account alike, never runs.
# The build-feature refusals are checked below, with that check stubbed.
printf '#!/bin/sh\n: > "$REC/ran"\nexec "%s" "$@"\n' "$T/bin/tn-main" > "$T/bin/tn-gw"
chmod 0775 "$T/bin/tn-gw"
OWNED="the node binary must be a root-owned file, not group- or other-writable, in root-owned directories."
child "$T/sn" "${MK[@]}" --install-method existing --binary-path "$T/bin/tn-gw"
refused "a group-writable binary" "refusing $T/bin/tn-gw: ${OWNED}"
check "a group-writable binary: never run" no "$([[ -e "$REC/ran" ]] && echo yes || echo no)"
child "$T/sn" "${MK[@]}" --binary-path "$T/bin/tn-gw"
refused "a group-writable binary (--binary-path alone means existing)" "refusing $T/bin/tn-gw: ${OWNED}"
child "$T/sn" "${MK[@]/$ADDR/}" --install-method existing --binary-path "$T/bin/tn-main"
refused "no execution address" "--address is missing: keygen needs the node's execution address (0x followed by 40 hex digits)."
child "$T/sn" "${MK[@]/$ADDR/0x1234}" --install-method existing --binary-path "$T/bin/tn-main"
refused "a malformed execution address" "invalid --address 0x1234 -- expected 0x followed by 40 hex digits."
child "$T/sn" "${MK[@]/$ADDR/0x0000000000000000000000000000000000000000}" --install-method existing --binary-path "$T/bin/tn-main"
refused "the zero address" "--address is the zero address: the proof of possession is signed over the node's execution address, which receives its rewards; give that address."
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
display_node_info() { : > "$REC/display-node-info"; }
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
check_has "keygen: .node-meta records NETWORK=mainnet, the network of the keys" "NETWORK=mainnet" "$meta"
check_has "keygen: NETWORK=mainnet recorded before the keytool made the keys" "NETWORK=mainnet" \
    "$(cat "$REC/meta.at-keytool" 2>/dev/null)"
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
check "closing text: no onboarding or staking steps (display_node_info)" no "$([[ -e "$REC/display-node-info" ]] && echo yes || echo no)"
check "closing text: node-info.yaml shown" yes "$(has "$(cat "$T/err")" "Your node-info.yaml has been generated at:")"
check_lacks "closing text: no re-registering with the Association" "re-register with the Association" "$(cat "$T/err")"

# Over existing keys: refused, the keytool does not run again.
mkdir -p "$T/data/node-keys"
command rm -f "$REC/keytool.argv"
rc=0; ( main "${KGM[@]}" ) <<< "$PASS" > "$T/out" 2> "$T/err" || rc=$?
check_rc "existing keys: rc 1" 1 "$rc"
check "existing keys: refused, saying what it found" yes \
    "$(has "$(tail -n 1 "$T/out")" "\"msg\":\"node-keys already exist at $T/data/node-keys -- refusing to overwrite in non-interactive mode; nothing on this host was changed. An earlier keygen left the keys and $T/data/node-info.yaml but no stored passphrase")"
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
check "testnet keygen: the onboarding steps of before" yes "$([[ -e "$REC/display-node-info" ]] && echo yes || echo no)"
ensure_chain_configs_available() { : > "$REC/chain-configs"; return 1; }
rc="$( tn_mainnet_enabled() { return 0; }; keygen "${KGM[@]}" )"
check_rc "mainnet enabled: keygen stops at the chain configs" 1 "$rc"
check "mainnet enabled: chain configs asked for" yes "$([[ -e "$REC/chain-configs" ]] && echo yes || echo no)"
check "mainnet enabled: no keytool" no "$([[ -e "$REC/keytool.argv" ]] && echo yes || echo no)"

# ---- the network the keys are for -----------------------------------------------------
# tn_keys_network_ok on its own: only a NETWORK=mainnet record refuses, and only another
# network; a host keyed by an older release (no NETWORK) keeps the behaviour of before.
kn() {  # kn WANTED [META LINE...] -- tn_keys_network_ok's rc, then its stderr
    local want="$1" rc=0 err
    shift
    if [[ $# -gt 0 ]]; then printf '%s\n' "$@" > "$T/kn.meta"; else command rm -f "$T/kn.meta"; fi
    err="$(tn_keys_network_ok "$want" "$T/kn.meta" 2>&1 >/dev/null)" || rc=$?
    printf '%s %s\n' "$rc" "$err"
}
check "keys network: no .node-meta passes" "0 " "$(kn testnet)"
check "keys network: no NETWORK recorded (an older keygen) passes" "0 " "$(kn testnet INSTALL_METHOD=existing)"
check "keys network: mainnet keys, mainnet node passes" "0 " "$(kn mainnet NETWORK=mainnet)"
check "keys network: testnet keys, devnet node as before" "0 " "$(kn devnet NETWORK=testnet)"
check "keys network: mainnet keys, testnet node refused" \
    "1 This host is recorded for mainnet (NETWORK=mainnet in $T/kn.meta, written before keygen makes mainnet keys), and a mainnet BLS key must never be used on another network, so a testnet node is refused here. Set up the testnet node on another host; this one runs mainnet only." \
    "$(kn testnet NETWORK=mainnet)"
check "keys network: mainnet keys, devnet node refused" 1 "$(kn devnet NETWORK=mainnet | cut -d' ' -f1)"
check "keys network: NETWORK twice cannot be told" 2 "$(kn mainnet NETWORK=mainnet NETWORK=testnet | cut -d' ' -f1)"

# The real keygen leaves NETWORK=mainnet; a later run for another network over those
# keys stops right after the root check, before the lock, the preflight or any write.
check_rc "keys network: mainnet keygen rc 0" 0 "$(keygen "${KGM[@]}")"
awk '/^unset /{next} { k = $0; sub(/=.*/, "", k); v[k] = $0; if (!(k in seen)) { seen[k] = 1; o[++n] = k } }
     END { for (i = 1; i <= n; i++) print v[o[i]] }' "$REC/meta.log" > "$CONFIG_DIR/.node-meta"
: > "$CONFIG_DIR/bls-passphrase.cred"
check_has "keys network: .node-meta as keygen left it" "NETWORK=mainnet" "$(cat "$CONFIG_DIR/.node-meta")"
cp "$CONFIG_DIR/.node-meta" "$T/meta.keygen"
LST=(--listener-primary /ip4/0.0.0.0/udp/49590/quic-v1 --listener-worker /ip4/0.0.0.0/udp/49594/quic-v1)
over_keys() {  # over_keys ARGS... -- main over the mainnet keys: rc, JSON in $T/out
    local rc=0
    command rm -rf "${T:?}/update.lock" "${T:?}/update.lock.d"
    command rm -f "${REC:?}"/*
    ( main "$@" ) <<< "$PASS" > "$T/out" 2> "$T/err" || rc=$?
    printf '%s\n' "$rc"
}
untouched() {  # untouched NAME -- the last over_keys run wrote and started nothing
    local f seen=""
    for f in "$REC/meta.log" "$REC/write-config" "$REC/create-service" "$REC/systemctl.log" \
             "$REC/docker.log" "$REC/keytool.argv" "$T/update.lock"; do
        [[ -e "$f" ]] && seen="${seen} ${f##*/}"
    done
    check "$1: nothing written or started" "same" \
        "$(cmp -s "$T/meta.keygen" "$CONFIG_DIR/.node-meta" && echo same || echo changed)${seen}"
    check "$1: the keys are left as they are" "yes yes" \
        "$([[ -f "$T/data/node-keys/bls.kw" ]] && echo yes || echo no) $([[ -f "$T/data/node-info.yaml" ]] && echo yes || echo no)"
}
KEYS_MAINNET="This host is recorded for mainnet (NETWORK=mainnet in $CONFIG_DIR/.node-meta, written before keygen makes mainnet keys), and a mainnet BLS key must never be used on another network, so a testnet node is refused here. Set up the testnet node on another host; this one runs mainnet only."
check_rc "testnet finalize over mainnet keys: rc 1" 1 "$(over_keys --json --phase=finalize --network testnet "${LST[@]}")"
check "testnet finalize over mainnet keys: refused" \
    "$(done_false "${KEYS_MAINNET} A --json run without --network is a testnet run. Nothing on this host was changed.")" "$(tail -n 1 "$T/out")"
untouched "testnet finalize over mainnet keys"
check_rc "finalize without --network over mainnet keys: rc 1" 1 "$(over_keys --json --phase=finalize "${LST[@]}")"
check "finalize without --network over mainnet keys: refused as testnet" \
    "$(done_false "${KEYS_MAINNET} A --json run without --network is a testnet run. Nothing on this host was changed.")" "$(tail -n 1 "$T/out")"
untouched "finalize without --network over mainnet keys"
check_rc "devnet finalize over mainnet keys: rc 1" 1 \
    "$(over_keys --json --phase=finalize --network devnet "${LST[@]}" --install-method existing --binary-path "$T/bin/tn-main")"
check "devnet finalize over mainnet keys: refused" yes \
    "$(has "$(tail -n 1 "$T/out")" "so a devnet node is refused here.")"
untouched "devnet finalize over mainnet keys"
check_rc "testnet keygen over mainnet keys: rc 1" 1 "$(over_keys "${KGT[@]}")"
check "testnet keygen over mainnet keys: refused before the preflight" \
    "$(done_false "${KEYS_MAINNET} A --json run without --network is a testnet run. Nothing on this host was changed.")" "$(tail -n 1 "$T/out")"
untouched "testnet keygen over mainnet keys"
# An interactive install asks once the network is chosen.
rc=0; ( NETWORK=testnet; setup_keys_network_check ) > /dev/null 2> "$T/err" || rc=$?
check "interactive testnet install over mainnet keys: refused" "1 yes" "${rc} $(has "$(cat "$T/err")" "$KEYS_MAINNET")"
# A mainnet finalize passes the check (with mainnet enabled, as in the launch release)
# and goes on to write the config and the service.
rc="$( tn_mainnet_enabled() { return 0; }; over_keys --json --phase=finalize --network mainnet "${LST[@]}" )"
check_lacks "mainnet finalize over mainnet keys: not refused for the network" "recorded for mainnet" "$(cat "$T/out")"
check "mainnet finalize over mainnet keys: goes on to the config and the service" "yes yes" \
    "$([[ -e "$REC/write-config" ]] && echo yes || echo no) $([[ -e "$REC/create-service" ]] && echo yes || echo no)"
# A host keyed by an older release (no NETWORK): a testnet finalize goes on as before.
grep -v '^NETWORK=' "$T/meta.keygen" > "$CONFIG_DIR/.node-meta"
over_keys --json --phase=finalize --network testnet "${LST[@]}" > /dev/null
check_lacks "no NETWORK recorded: a testnet finalize is not refused for the network" "recorded for mainnet" "$(cat "$T/out")"
check "no NETWORK recorded: a testnet finalize goes on to the config" yes "$([[ -e "$REC/write-config" ]] && echo yes || echo no)"
command rm -rf "$T/data" "$CONFIG_DIR/.node-meta" "$CONFIG_DIR/bls-passphrase.cred"

# ---- a keygen over keys that are there ---------------------------------------------------
# It stops before the lock and before anything is written (.node-meta, the keytool, the
# lock), and says what it found against this run: the same address and network (the
# node-info.yaml to send), another address (both named, and the way to start over), or
# keys recorded for another network (not this run's; the record stays).
mkdir -p "$T/data/node-keys"
: > "$T/data/node-keys/bls.kw"
: > "$CONFIG_DIR/bls-passphrase.cred"
ni() { printf 'name: stub\nexecution_address: %s\n' "$1" > "$T/data/node-info.yaml"; }
kept() {  # kept NAME SAVED_META -- the last over_keys run changed nothing: .node-meta, no write, keytool or lock
    local f seen=""
    for f in "$REC/meta.log" "$REC/keytool.argv" "$REC/credential" "$T/update.lock"; do
        [[ -e "$f" ]] && seen="${seen} ${f##*/}"
    done
    check "$1: nothing written, no keytool, no lock" "same" \
        "$(cmp -s "$2" "$CONFIG_DIR/.node-meta" && echo same || echo changed)${seen}"
}
LEAD="node-keys already exist at $T/data/node-keys -- refusing to overwrite in non-interactive mode; nothing on this host was changed."
cp "$T/meta.keygen" "$CONFIG_DIR/.node-meta"
ni "$ADDR"
check_rc "keygen over keys, the same address and network: rc 1" 1 "$(over_keys "${KGM[@]}")"
check "keygen over keys, the same address and network: all in place, use that node-info.yaml" \
    "$(done_false "${LEAD} An earlier keygen left the keys, $T/data/node-info.yaml and the stored passphrase (PASSPHRASE_METHOD=credential), all in place: there is nothing to generate. Use that node-info.yaml, and finalize this host when its release is out.")" \
    "$(tail -n 1 "$T/out")"
kept "keygen over keys, the same address and network" "$T/meta.keygen"
ni "0x000000000000000000000000000007310005EED3"
over_keys "${KGM[@]}" > /dev/null
check "keygen over keys, the same address in capitals: all in place" yes "$(has "$(tail -n 1 "$T/out")" "all in place: there is nothing to generate")"
OTHER="0x000000000000000000000000000007310005eed4"
ni "$OTHER"
check_rc "keygen over keys, another address: rc 1" 1 "$(over_keys "${KGM[@]}")"
check "keygen over keys, another address: both named, the way to start over, never 'use that node-info.yaml'" \
    "$(done_false "${LEAD} $T/data/node-info.yaml is for the execution address ${OTHER}, and this run asks for ${ADDR}: its proof of possession is signed for ${OTHER}, so it is not the file to send for ${ADDR}. Before genesis there is no mainnet chain for prepare-stake.sh --rotate-address (OPERATOR.md 6.6) to check, so start over: remove $T/data/node-keys and $T/data/node-info.yaml (sudo rm -rf), run keygen again with --address ${ADDR}, and send the new node-info.yaml in place of any you sent.")" \
    "$(tail -n 1 "$T/out")"
kept "keygen over keys, another address" "$T/meta.keygen"
# A testnet keygen over testnet keys for another address names the rotation of 6.6.
sed 's/^NETWORK=.*/NETWORK=testnet/' "$T/meta.keygen" > "$T/meta.testnet"
cp "$T/meta.testnet" "$CONFIG_DIR/.node-meta"
check_rc "testnet keygen over testnet keys, another address: rc 1" 1 "$(over_keys "${KGT[@]}")"
check "testnet keygen over testnet keys, another address: names prepare-stake.sh --rotate-address" yes \
    "$(has "$(tail -n 1 "$T/out")" "so it is not the file to send for ${ADDR}. Before these keys stake, sudo bash ${SCRIPT_DIR}/prepare-stake.sh --rotate-address ${ADDR} signs it for that address with the same keys (OPERATOR.md 6.6); or remove $T/data/node-keys and $T/data/node-info.yaml (sudo rm -rf) and run keygen again with that address.")"
kept "testnet keygen over testnet keys, another address" "$T/meta.testnet"
# Testnet keys, a mainnet keygen: refused for the network, and the record stays testnet.
ni "$ADDR"
check_rc "mainnet keygen over testnet keys: rc 1" 1 "$(over_keys "${KGM[@]}")"
check "mainnet keygen over testnet keys: refused, the record named" \
    "$(done_false "${LEAD} They are recorded for testnet (NETWORK=testnet in $CONFIG_DIR/.node-meta) and this run is for mainnet, so they are not this run's keys and their node-info.yaml is not to be sent for it. Generate the mainnet keys on another host, or, if the testnet keys here are no longer wanted, remove $T/data/node-keys and $T/data/node-info.yaml (sudo rm -rf) and run keygen again.")" \
    "$(tail -n 1 "$T/out")"
kept "mainnet keygen over testnet keys" "$T/meta.testnet"
check_lacks "mainnet keygen over testnet keys: never offered for the genesis" "Use that node-info.yaml" "$(cat "$T/out")"
# No NETWORK recorded (keys from an older release): the message of before, without the writes.
grep -v '^NETWORK=' "$T/meta.keygen" > "$T/meta.nonet"
cp "$T/meta.nonet" "$CONFIG_DIR/.node-meta"
check_rc "keygen over keys with no NETWORK recorded: rc 1" 1 "$(over_keys "${KGM[@]}")"
check "keygen over keys with no NETWORK recorded: all in place" yes "$(has "$(tail -n 1 "$T/out")" "${LEAD} An earlier keygen left the keys, $T/data/node-info.yaml and the stored passphrase (PASSPHRASE_METHOD=credential), all in place")"
kept "keygen over keys with no NETWORK recorded" "$T/meta.nonet"
command rm -rf "$T/data" "$CONFIG_DIR/.node-meta" "$CONFIG_DIR/bls-passphrase.cred"

# ---- an interrupted keygen --------------------------------------------------------------
# The passphrase is stored before the keytool runs, HUP, INT and TERM are held until the
# keys are checked, and a keygen whose keytool fails takes back what it wrote and the
# stored passphrase. tn-sig is the keytool as the operator's SSH drop meets it: it sends
# setup HUP after it wrote everything (sig.mode after: a HUP to setup alone), or after
# bls.kw only and then dies of it (mid: a HUP to the whole process group), or it writes
# no node-info.yaml at all (noinfo).
cat > "$T/bin/tn-sig" <<'STUB'
#!/bin/sh
if [ "$1" = "--version" ]; then
    printf 'telcoin-network\nVersion: 0.18.0\nCommit SHA: 0000000\nBuild Features: \n'
    exit 0
fi
dd=""
prev=""
for a in "$@"; do
    [ "$prev" = "--datadir" ] && dd="$a"
    prev="$a"
done
cat > /dev/null
[ -f "$REC/meta.log" ] && cp "$REC/meta.log" "$REC/meta.at-keytool"
mkdir -p "$dd/node-keys"
: > "$dd/node-keys/bls.kw"
mode="$(cat "$REC/sig.mode" 2>/dev/null)"
case "$mode" in
    noinfo) exit 0 ;;
    mid) kill -HUP "$(cat "$REC/setup.pid")"; exit 129 ;;
esac
printf 'name: stub\n' > "$dd/node-info.yaml"
[ "$mode" = after ] && kill -HUP "$(cat "$REC/setup.pid")"
exit 0
STUB
chmod 0755 "$T/bin/tn-sig"
# The credential stub leaves the file, and the shred removes it, so what is left shows.
tn_store_credential() { printf '%s %s\n' "$1" "$2" > "$REC/credential"; : > "$1"; }
_tn_shred() { command rm -f -- "$1"; }
CRED="$CONFIG_DIR/bls-passphrase.cred"
sig_keygen() {  # sig_keygen MODE -- the mainnet keygen with tn-sig: rc, JSON in $T/out
    local rc=0
    command rm -rf "${T:?}/data" "${T:?}/update.lock" "${T:?}/update.lock.d" "$CRED" "$CONFIG_DIR/.node-meta"
    command rm -f "${REC:?}"/*
    printf '%s\n' "$1" > "$REC/sig.mode"
    ( sh -c 'echo "$PPID"' > "$REC/setup.pid"; main "${MK[@]}" --install-method existing --binary-path "$T/bin/tn-sig" --data-dir "$T/data" ) \
        <<< "$PASS" > "$T/out" 2> "$T/err" || rc=$?
    printf '%s\n' "$rc"
}
left() {  # left -- what the run left: the key, node-info.yaml, the credential
    printf '%s %s %s\n' "$([[ -f "$T/data/node-keys/bls.kw" ]] && echo key || echo no-key)" \
        "$([[ -f "$T/data/node-info.yaml" ]] && echo info || echo no-info)" "$([[ -f "$CRED" ]] && echo cred || echo no-cred)"
}
check_rc "HUP to setup during the keytool: rc 129" 129 "$(sig_keygen after)"
check "HUP to setup during the keytool: keys, node-info.yaml and the credential all in place" "key info cred" "$(left)"
check_has "HUP to setup during the keytool: the passphrase recorded" "PASSPHRASE_METHOD=credential" "$(cat "$REC/meta.log" 2>/dev/null)"
check "HUP to setup during the keytool: the credential stored before the keytool ran" yes \
    "$(has "$(cat "$REC/meta.at-keytool" 2>/dev/null)" "PASSPHRASE_METHOD=credential")"
check "HUP to setup during the keytool: no success reported" \
    "$(done_false "setup stopped by SIGHUP (rc=129)")" "$(tail -n 1 "$T/out")"
check_lacks "HUP to setup during the keytool: no file to send named" "Send $T/data/node-info.yaml" "$(cat "$T/out")"
# A re-run over what that run left says it is all there.
awk '/^unset /{next} { k = $0; sub(/=.*/, "", k); v[k] = $0; if (!(k in seen)) { seen[k] = 1; o[++n] = k } }
     END { for (i = 1; i <= n; i++) print v[o[i]] }' "$REC/meta.log" > "$CONFIG_DIR/.node-meta"
command rm -f "$REC/keytool.argv" "$REC/sig.mode"
rc=0; ( main "${MK[@]}" --install-method existing --binary-path "$T/bin/tn-sig" --data-dir "$T/data" ) <<< "$PASS" > "$T/out" 2> "$T/err" || rc=$?
check "re-run over a complete keygen: rc 1, nothing to generate" "1 yes" \
    "${rc} $(has "$(tail -n 1 "$T/out")" "An earlier keygen left the keys, $T/data/node-info.yaml and the stored passphrase (PASSPHRASE_METHOD=credential), all in place: there is nothing to generate.")"
check "re-run over a complete keygen: left as it was" "key info cred" "$(left)"

check_rc "keytool stopped by the HUP: rc 1" 1 "$(sig_keygen mid)"
check "keytool stopped by the HUP: its keys and the credential taken back" "no-key no-info no-cred" "$(left)"
check_has "keytool stopped by the HUP: the passphrase record taken back" "unset PASSPHRASE_METHOD" "$(cat "$REC/meta.log" 2>/dev/null)"
check "keytool stopped by the HUP: no success, the undo named" \
    "$(done_false "Key generation failed (keytool rc 129); what it wrote and the stored passphrase were removed, so keygen can run again.")" \
    "$(tail -n 1 "$T/out")"

check_rc "keytool wrote no node-info.yaml: rc 1" 1 "$(sig_keygen noinfo)"
check "keytool wrote no node-info.yaml: keys and credential taken back" "no-key no-info no-cred" "$(left)"
check "keytool wrote no node-info.yaml: no success" \
    "$(done_false "Key generation left no $T/data/node-info.yaml; the new keys and the stored passphrase were removed, so keygen can run again.")" "$(tail -n 1 "$T/out")"
check_lacks "keytool wrote no node-info.yaml: no file to send named" "Send $T/data/node-info.yaml" "$(cat "$T/out")"

# KILL or a power loss can still stop a run between two steps. Each state it can leave,
# and the one an older release left after a HUP, is named on a re-run and at finalize.
command rm -rf "$T/data" "$CRED"
mkdir -p "$T/data/node-keys"
: > "$T/data/node-keys/bls.kw"
printf 'name: stub\n' > "$T/data/node-info.yaml"
grep -v -E '^(PASSPHRASE_METHOD|CREDENTIAL_KEY)=' "$T/meta.keygen" > "$T/meta.nopass"
cp "$T/meta.nopass" "$CONFIG_DIR/.node-meta"
NOPASS="An earlier keygen left the keys and $T/data/node-info.yaml but no stored passphrase (no PASSPHRASE_METHOD, or its file is missing): it stopped before it stored the passphrase, and the keys open only with the passphrase typed for that run. If you still have it, store it as OPERATOR.md section 2.12 shows (systemd-creds encrypt --name=bls-passphrase --with-key=host+tpm2 - $CRED, then PASSPHRASE_METHOD=credential and CREDENTIAL_KEY=host+tpm2 in $CONFIG_DIR/.node-meta). Otherwise remove $T/data/node-keys and $T/data/node-info.yaml (sudo rm -rf), run keygen again, and send the new node-info.yaml in place of any you sent."
rc=0; ( main "${MK[@]}" --install-method existing --binary-path "$T/bin/tn-sig" --data-dir "$T/data" ) <<< "$PASS" > "$T/out" 2> "$T/err" || rc=$?
check "keys without a stored passphrase, re-run: rc 1, the state and the way out" \
    "1 $(done_false "node-keys already exist at $T/data/node-keys -- refusing to overwrite in non-interactive mode; nothing on this host was changed. ${NOPASS}")" "${rc} $(tail -n 1 "$T/out")"
check "keys without a stored passphrase, re-run: keys left, no credential made" "key info no-cred" "$(left)"
cp "$T/meta.nopass" "$CONFIG_DIR/.node-meta"
rc="$( tn_mainnet_enabled() { return 0; }; over_keys --json --phase=finalize --network mainnet "${LST[@]}" )"
check "keys without a stored passphrase, finalize: rc 1, the state and the way out" \
    "1 $(done_false "No stored BLS passphrase recorded in $CONFIG_DIR/.node-meta (PASSPHRASE_METHOD). ${NOPASS}")" "${rc} $(tail -n 1 "$T/out")"
command rm -f "$T/data/node-info.yaml"
cp "$T/meta.keygen" "$CONFIG_DIR/.node-meta"
: > "$CRED"
rc=0; ( main "${MK[@]}" --install-method existing --binary-path "$T/bin/tn-sig" --data-dir "$T/data" ) <<< "$PASS" > "$T/out" 2> "$T/err" || rc=$?
check "keys without node-info.yaml, re-run: rc 1, remove and run again" "1 yes" \
    "${rc} $(has "$(tail -n 1 "$T/out")" "An earlier keygen did not finish: it left no complete key set (node-keys/bls.kw and $T/data/node-info.yaml), and keys it did not finish were never reported. Remove $T/data/node-keys and $T/data/node-info.yaml (sudo rm -rf), then run keygen again.")"
command rm -rf "$T/data" "$CONFIG_DIR/.node-meta" "$CRED"

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

# check_binary_mainnet itself: the ownership and mode check first, then --version under
# timeout -k 5 30 and the build-feature rule.
cbm() {  # cbm BINARY -- check_binary_mainnet's rc and the done message it ends with
    local rc=0 out
    command rm -f "$REC/ran" "$REC/timeout.argv"
    out="$( ( BINARY_PATH="$1"; JSON_MODE=true; exec 3>&1; check_binary_mainnet ) 2>/dev/null )" || rc=$?
    printf '%s %s\n' "$rc" "$(printf '%s\n' "$out" | tail -n 1)"
}
NOT_MAINNET="A mainnet node runs telcoin-network built with no build features (cargo build -p telcoin-network --bin telcoin-network --release --locked). The binary was not used."
check "binary check: a mainnet build passes" "0 " "$(cbm "$T/bin/tn-main")"
check "binary check: a build with the testnet feature" \
    "1 $(done_false "Refusing the node binary at $T/bin/tn-adiri: it is not a mainnet build (This build has the features adiri; a mainnet build has none.). ${NOT_MAINNET}")" "$(cbm "$T/bin/tn-adiri")"
check "binary check: a test build" \
    "1 $(done_false "Refusing the node binary at $T/bin/tn-testutils: it is not a mainnet build (This build has the features test_utils; a mainnet build has none.). ${NOT_MAINNET}")" "$(cbm "$T/bin/tn-testutils")"
check "binary check: a binary that does not run" \
    "1 $(done_false "Refusing the node binary at $T/bin/no-such-binary: its --version did not run, so whether it is a mainnet build cannot be told. The binary was not used.")" "$(cbm "$T/bin/no-such-binary")"
out="$( _tn_root_binary_ok() { return 1; }; cbm "$T/bin/tn-gw" )"
check "binary check: one that fails the ownership check is refused before it runs" \
    "1 $(done_false "refusing $T/bin/tn-gw: ${OWNED}") no" "${out} $([[ -e "$REC/ran" ]] && echo yes || echo no)"
mkdir -p "$T/tbin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "$REC/timeout.argv"\nexit 124\n' > "$T/tbin/timeout"
chmod 0755 "$T/tbin/timeout"
out="$( PATH="$T/tbin:$PATH"; cbm "$T/bin/tn-main" )"
check "binary check: a --version that does not finish in 30 seconds" \
    "1 $(done_false "Refusing the node binary at $T/bin/tn-main: its --version did not finish within 30 seconds, so whether it is a mainnet build cannot be told. The binary was stopped and not used.")" "$out"
check "binary check: --version runs under timeout -k 5 30" "-k 5 30 $T/bin/tn-main --version" "$(cat "$REC/timeout.argv" 2>/dev/null)"

finish
