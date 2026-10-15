#!/usr/bin/env bash
# tools/tests/finalize_inputs_test.sh -- the inputs of setup-node.sh --json
# --phase=finalize (finalize_install_inputs). The install method, data dir,
# docker image and binary path come from the finalize flags or, when a flag
# leaves one out, from what keygen recorded in .node-meta; a flag that differs
# from the recorded value stops finalize before anything is written. An
# installed node is refused before the update lock and its layout migration
# (run_json_mode). A copy of setup-node.sh without its last line is sourced at
# the top level. Maintainer tooling (not updater-tracked). bash 3.2 safe.
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
# Images run by digest (TN_DOCKER_REQUIRE_DIGEST defaults to 1); IMG_TAG is the
# older tag form, which a keygen record may still hold and finalize refuses.
IMG="${GAR_IMAGE_BASE}@sha256:1111111111111111111111111111111111111111111111111111111111111111"
IMG_OTHER="${GAR_IMAGE_BASE}@sha256:2222222222222222222222222222222222222222222222222222222222222222"
IMG_TAG="${GAR_IMAGE_BASE}:v0.16.0-adiri"
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
# A keygen record that names the image by tag is refused, pointing at the digest form.
keygen_meta "INSTALL_METHOD=docker" "DATA_DIR=/mnt/tn" "DOCKER_IMAGE=${IMG_TAG}"
fin
check_rc "docker: a tag-form keygen record refused" 1 "$RC"
check "tag-form refusal names the record and the digest form" yes \
    "$(has "$ERR" "DOCKER_IMAGE=${IMG_TAG} in $CONFIG_DIR/.node-meta is not an image reference such as ${DEFAULT_DOCKER_IMAGE}")"
keygen_meta "INSTALL_METHOD=docker" "DATA_DIR=/mnt/tn" "DOCKER_IMAGE=${IMG}"

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

# run_json_mode refuses an installed node before the update lock and the layout
# migration it brings, so an older install is left as it is; with no unit the
# lock, the migration and the phase run in that order.
json_set_network() { :; }
json_check_install_flags() { :; }
json_check_keygen_inputs() { :; }
json_require_root() { :; }
tn_acquire_update_lock() { printf 'lock\n' >> "$T/ev"; return 0; }
tn_release_update_lock() { return 0; }
tn_migrate_ownership() { printf 'migrate\n' >> "$T/ev"; return 0; }
json_phase_finalize() { printf 'phase\n' >> "$T/ev"; }
json_phase_keygen() { printf 'phase\n' >> "$T/ev"; }
evs() {
    local e
    e="$(tr '\n' ' ' < "$T/ev" | sed 's/ $//')"
    printf '%s' "${e:-none}"
}
mkdir -p "$TN_ROOT_PREFIX/etc/systemd/system"
printf '[Service]\nExecStart=/opt/telcoin/start-telcoin.sh\n' > "$TN_ROOT_PREFIX/etc/systemd/system/telcoin.service"
keygen_meta "INSTALL_METHOD=existing" "BINARY_PATH=${BIN}"
cp "$CONFIG_DIR/.node-meta" "$T/meta.before"
for phase in finalize keygen; do
    : > "$T/ev"
    rc=0; ( JSON_PHASE="$phase" run_json_mode ) > "$T/out" 2>&1 || rc=$?
    check "installed node, --phase=${phase}: refused before the lock and the migration" "1 none" \
        "$rc $(evs)"
done
check "installed node: .node-meta unchanged" same "$(cmp -s "$T/meta.before" "$CONFIG_DIR/.node-meta" && echo same || echo changed)"
check "installed node: the refusal says why" yes "$(has "$(cat "$T/out")" "already installed")"
rm -f "$TN_ROOT_PREFIX/etc/systemd/system/telcoin.service"
: > "$T/ev"
rc=0; ( JSON_PHASE=finalize run_json_mode ) > "$T/out" 2>&1 || rc=$?
check "no unit: lock, migration, then the phase" "0 lock migrate phase" "$rc $(evs)"
finish
