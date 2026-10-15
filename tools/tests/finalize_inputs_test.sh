#!/usr/bin/env bash
# tools/tests/finalize_inputs_test.sh -- the inputs of setup-node.sh --json
# --phase=finalize (finalize_install_inputs). The install method, data dir,
# docker image and binary path come from the finalize flags or, when a flag
# leaves one out, from what keygen recorded in .node-meta; a flag that differs
# from the recorded value stops finalize before anything is written. A copy of
# setup-node.sh without its last line is sourced at the top level. Maintainer
# tooling (not updater-tracked). bash 3.2 safe.
# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
mkdir -p "$T/sn" "$T/conf" "$T/root"
grep -v '^main "\$@"$' "$TN_TEST_REPO/setup-node.sh" > "$T/sn/setup-node.sh"
ln -s "$TN_TEST_REPO/lib" "$T/sn/lib"
TN_ROOT_PREFIX="$T/root"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/sn/setup-node.sh"
set +e  # setup-node.sh makes SERVICE_NAME readonly; tn_test_post_common would assign it

# shellcheck disable=SC2034  # read by setup-node.sh
NETWORK=testnet
CONFIG_DIR="$T/conf"
printf 'stored\n' > "$CONFIG_DIR/bls-passphrase"
check_binary_path() { return 0; }
IMG="${GAR_IMAGE_BASE}:v0.16.0-adiri"
IMG_OTHER="${GAR_IMAGE_BASE}:v0.15.0-adiri"
BIN=/opt/telcoin/telcoin-network

has() {
    case "$1" in
        *"$2"*) echo yes ;;
        *) echo no ;;
    esac
}

# keygen_meta LINE... -- .node-meta as a keygen run left it.
keygen_meta() { printf '%s\n' "PASSPHRASE_METHOD=stdin" "$@" > "$CONFIG_DIR/.node-meta"; }
# fin [VAR=VALUE...] -- finalize_install_inputs in a subshell with the finalize
# flags given (unset ones as main leaves them); RC, ERR, and GOT =
# "method|data dir|image|binary" as finalize resolved them.
# (The body is a function of its own: bash 3.2 misreads a case inside $(...).)
fin_body() {
    local kv
    INSTALL_METHOD="" DATA_DIR="$DEFAULT_DATA_DIR" DOCKER_IMAGE="" BINARY_PATH=""
    for kv in "$@"; do
        case "$kv" in
            INSTALL_METHOD=*) INSTALL_METHOD="${kv#*=}" ;;
            DATA_DIR=*) DATA_DIR="${kv#*=}" ;;
            DOCKER_IMAGE=*) DOCKER_IMAGE="${kv#*=}" ;;
            BINARY_PATH=*) BINARY_PATH="${kv#*=}" ;;
        esac
    done
    finalize_install_inputs >/dev/null 2>"$T/err" || exit $?
    printf '%s|%s|%s|%s' "$INSTALL_METHOD" "$DATA_DIR" "$DOCKER_IMAGE" "$BINARY_PATH"
}
fin() {
    : > "$T/err"
    GOT="$(fin_body "$@")"
    RC=$?
    ERR="$(cat "$T/err")"
}

# A docker keygen with a custom data dir.
keygen_meta "INSTALL_METHOD=docker" "DATA_DIR=/mnt/tn" "DOCKER_IMAGE=${IMG}"
fin
check "docker: no flags take the keygen record" "0 docker|/mnt/tn|${IMG}|" "$RC $GOT"
fin INSTALL_METHOD=docker DATA_DIR=/mnt/tn DOCKER_IMAGE="$IMG"
check "docker: the same values as flags pass" "0 docker|/mnt/tn|${IMG}|" "$RC $GOT"
fin INSTALL_METHOD=source
check_rc "docker keygen, --install-method source: refused" 1 "$RC"
check "the refusal names both values" yes "$(has "$ERR" "--install-method source differs from docker")"
check "the refusal says nothing changed" yes "$(has "$ERR" "Nothing was changed")"
fin DATA_DIR=/mnt/other
check_rc "--data-dir other than keygen's: refused" 1 "$RC"
check "data dir refusal names both" yes "$(has "$ERR" "--data-dir /mnt/other differs from /mnt/tn")"
fin DOCKER_IMAGE="$IMG_OTHER"
check_rc "--docker-image other than keygen's: refused" 1 "$RC"
check "image refusal names both" yes "$(has "$ERR" "--docker-image ${IMG_OTHER} differs from ${IMG}")"

# An existing-binary keygen with the default data dir.
keygen_meta "INSTALL_METHOD=existing" "DATA_DIR=${DEFAULT_DATA_DIR}" "DOCKER_IMAGE=" "BINARY_PATH=${BIN}"
fin
check "existing: no flags take the keygen record" "0 existing|${DEFAULT_DATA_DIR}||${BIN}" "$RC $GOT"
fin BINARY_PATH=/usr/local/bin/telcoin-network
check_rc "--binary-path other than keygen's: refused" 1 "$RC"
check "binary refusal names both" yes "$(has "$ERR" "--binary-path /usr/local/bin/telcoin-network differs from ${BIN}")"
fin DATA_DIR=/mnt/tn
check_rc "--data-dir set where keygen used the default: refused" 1 "$RC"

# A keygen from before the data dir was recorded: the flag is used as given.
keygen_meta "INSTALL_METHOD=existing" "BINARY_PATH=${BIN}"
fin DATA_DIR=/mnt/tn
check "no recorded data dir: the flag is used" "0 existing|/mnt/tn||${BIN}" "$RC $GOT"

# A recorded value gets the checks a flag gets.
keygen_meta "INSTALL_METHOD=existing" "DATA_DIR=/mnt/x y" "BINARY_PATH=${BIN}"
fin
check_rc "a recorded data dir with a space: refused" 1 "$RC"
finish
