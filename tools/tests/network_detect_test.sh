#!/usr/bin/env bash
# =============================================================================
# tools/tests/network_detect_test.sh -- update-node.sh's network detection and
# the source prepare's build features: CRLF .node-meta, the genesis chain id
# fallback, a duplicated or unknown NETWORK (fail closed, no git, no cargo),
# image_network (devnet from NETWORK=devnet in .node-meta) and the devnet image
# paths that use it (pending NEW_IMAGE, fetch_docker_tags, json_prepare_docker),
# duplicated INSTALL_METHOD and BINARY_PATH, the build log and the build
# output check.
#
#   bash tools/tests/network_detect_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/network_detect_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/network_detect_test.sh
#
# Runs as any user; everything lives in a fixture tree (TN_ROOT_PREFIX). git
# and cargo are stubs on PATH that leave a marker when they run.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
mkdir -p "$T/h" "$T/bin"
grep -v '^main "\$@"$' "$TN_TEST_REPO/update-node.sh" > "$T/h/update-node.sh"
ln -s "$TN_TEST_REPO/lib" "$T/h/lib"
TN_ROOT_PREFIX="$T/fx"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/h/update-node.sh"
tn_test_post_common

run() {
    OUT="$("$@" 2>"$T/.err")"
    RC=$?
    ERR="$(cat "$T/.err")"
}
has() {
    case "$1" in
        *"$2"*) echo yes ;;
        *) echo no ;;
    esac
}
exists() { if [[ -e "$1" ]]; then echo yes; else echo no; fi; }

for c in cargo git; do
    printf '#!/bin/sh\ntouch "%s/%s-ran"\nexit 1\n' "$T" "$c" > "$T/bin/$c"
    chmod 0755 "$T/bin/$c"
done
PATH="$T/bin:$PATH"

META="$T/fx/etc/telcoin/.node-meta"
DD="$T/fx/data"
mkdir -p "$T/fx/etc/telcoin" "$DD/genesis"

# meta LINE... -- write .node-meta with these lines (and DATA_DIR) as given.
# DATA_DIR is recorded as the node sees it; the resolvers prefix TN_ROOT_PREFIX.
meta() {
    : > "$META"
    printf 'DATA_DIR=/data\n' >> "$META"
    while [[ $# -gt 0 ]]; do
        printf '%s' "$1" >> "$META"
        shift
    done
}
genesis() { printf 'chainId: %s\n' "$1" > "$DD/genesis/genesis.yaml"; }
no_genesis() { rm -f "$DD/genesis/genesis.yaml"; }

# -----------------------------------------------------------------------------
# detect_network
# -----------------------------------------------------------------------------
no_genesis
meta $'NETWORK=mainnet\r\n'
run detect_network
check_rc "CRLF NETWORK=mainnet: rc 0" 0 "$RC"
check "CRLF NETWORK=mainnet: mainnet" "mainnet" "$OUT"

meta $'INSTALL_METHOD=source\r\n' $'NETWORK=testnet\r\n'
run detect_network
check "CRLF NETWORK=testnet: testnet" "testnet" "$OUT"

genesis 487
meta $'INSTALL_METHOD=source\n'
run detect_network
check_rc "no NETWORK, genesis 487: rc 0" 0 "$RC"
check "no NETWORK, genesis 487: mainnet" "mainnet" "$OUT"
genesis 2017
run detect_network
check "no NETWORK, genesis 2017: testnet" "testnet" "$OUT"
genesis 32285
run detect_network
check_rc "no NETWORK, devnet genesis: rc 1" 1 "$RC"
check "no NETWORK, devnet genesis: nothing printed" "" "$OUT"
no_genesis
run detect_network
check_rc "no NETWORK, no genesis: rc 1" 1 "$RC"

genesis 487
meta $'NETWORK=foo\n'
run detect_network
check_rc "NETWORK=foo: rc 1 (no genesis fallback)" 1 "$RC"
check "NETWORK=foo: nothing printed" "" "$OUT"
check "NETWORK=foo: reason on stderr" yes "$(has "$ERR" "NETWORK='foo'")"
meta $'NETWORK=devnet\n'
run detect_network
check_rc "NETWORK=devnet: rc 1" 1 "$RC"
meta $'NETWORK=\n'
run detect_network
check_rc "NETWORK empty: rc 1" 1 "$RC"

meta $'NETWORK=mainnet\n' $'NETWORK=testnet\n'
run detect_network
check_rc "duplicate NETWORK: rc 1 (no genesis fallback)" 1 "$RC"
check "duplicate NETWORK: nothing printed" "" "$OUT"
check "duplicate NETWORK: named on stderr" yes "$(has "$ERR" "NETWORK is set 2 times")"

# -----------------------------------------------------------------------------
# The mainnet gate (TN_MAINNET_ENABLED): the interactive menu's option 2 and
# setup-node's --network mainnet refuse while it is 0. $T/on holds a copy of
# lib/common.sh with the constant set to 1, standing for the launch release;
# each case runs in a child bash, as this shell has the library loaded already.
# -----------------------------------------------------------------------------
check "TN_MAINNET_ENABLED is 0 in this release" "0" "${TN_MAINNET_ENABLED-unset}"
run tn_mainnet_enabled
check_rc "tn_mainnet_enabled: rc 1 while it is 0" 1 "$RC"
mkdir -p "$T/off" "$T/on"
ln -s "$TN_TEST_REPO/lib" "$T/off/lib"
cp -R "$TN_TEST_REPO/lib" "$T/on/lib"
sed 's/^readonly TN_MAINNET_ENABLED=0$/readonly TN_MAINNET_ENABLED=1/' "$TN_TEST_REPO/lib/common.sh" > "$T/on/lib/common.sh"
check "the launch copy sets TN_MAINNET_ENABLED=1" yes \
    "$(grep -qx 'readonly TN_MAINNET_ENABLED=1' "$T/on/lib/common.sh" && echo yes || echo no)"
for d in off on; do
    cp "$TN_TEST_REPO/setup-node.sh" "$T/$d/setup-node-run.sh"
    grep -v '^main "\$@"$' "$TN_TEST_REPO/setup-node.sh" > "$T/$d/setup-node.sh"
done

# pick DIR INPUT -- select_network from DIR's library with INPUT (printf %b) on
# stdin: what it printed, then "picked: NETWORK|CHAIN_ID|CHAIN_NAME|RPC_URL|EXPLORER_URL".
pick() {
    # shellcheck disable=SC2016
    printf '%b' "$2" | "$BASH" -c 'source "$1/lib/common.sh" >/dev/null 2>&1; set +e
        select_network
        printf "picked: %s|%s|%s|%s|%s\n" "$NETWORK" "$CHAIN_ID" "$CHAIN_NAME" "$RPC_URL" "$EXPLORER_URL"' _ "$1" 2>&1
}
TESTNET_PICK="picked: testnet|2017|adiri|https://rpc.adiri.tel|https://telscan.io"
MAINNET_PICK="picked: mainnet|487|telcoin|https://rpc.telcoin.network|https://telscan.io"
# "2", then one line for the Enter prompt, then "1": no "Please enter 1 or 2."
# shows that the Enter prompt took the second line. Every input ends in "1", so
# the menu returns whatever it does with "2" (at end of input it would ask forever).
OUT="$(pick "$T/off" '2\nx\n1\n')"
check "menu, disabled: option 2 is coming soon" yes "$(has "$OUT" "-- for production (coming soon)")"
check "menu, disabled: 2 says mainnet has not launched" yes "$(has "$OUT" "Mainnet has not launched yet.")"
check "menu, disabled: 2 waits for Enter, then asks again" no "$(has "$OUT" "Please enter 1 or 2.")"
check_has "menu, disabled: 2 then 1 gives testnet" "$TESTNET_PICK" "$OUT"
# The same input: "x" and "1" stay unread when 2 is taken.
OUT="$(pick "$T/on" '2\nx\n1\n')"
check_has "menu, enabled: 2 gives mainnet" "$MAINNET_PICK" "$OUT"
check "menu, enabled: no coming soon" no "$(has "$OUT" "coming soon")"
check "menu, enabled: no not-launched note" no "$(has "$OUT" "has not launched")"
OUT="$(pick "$T/on" '1\n')"
check_has "menu, enabled: 1 still gives testnet" "$TESTNET_PICK" "$OUT"

# jsn DIR NETWORK -- setup-node's json_set_network NETWORK from DIR's copy in
# --json mode: the JSON events, then "set: ..." as pick prints it when it returns.
jsn() {
    # shellcheck disable=SC2016
    "$BASH" -c 'source "$1/setup-node.sh" >/dev/null 2>&1; set +e
        JSON_MODE=true; exec 3>&1
        json_set_network "$2"
        printf "set: %s|%s|%s|%s|%s\n" "$NETWORK" "$CHAIN_ID" "$CHAIN_NAME" "$RPC_URL" "$EXPLORER_URL"' _ "$1" "$2" 2>/dev/null
}
MAINNET_OFF="Mainnet is not enabled in this script release (lib/common.sh TN_MAINNET_ENABLED); nothing on this host was changed."
run jsn "$T/off" mainnet
check_rc "json_set_network mainnet, disabled: rc 1" 1 "$RC"
check_has "json_set_network mainnet, disabled: error event" "{\"event\":\"error\",\"msg\":\"${MAINNET_OFF}\"}" "$OUT"
check_has "json_set_network mainnet, disabled: done event" "{\"event\":\"done\",\"ok\":false,\"msg\":\"${MAINNET_OFF}\"}" "$OUT"
check "json_set_network mainnet, disabled: no network set" no "$(has "$OUT" "set: ")"
run jsn "$T/off" testnet
check_has "json_set_network testnet, disabled: testnet" "set: testnet|2017|adiri|https://rpc.adiri.tel|https://telscan.io" "$OUT"
run jsn "$T/on" mainnet
check_rc "json_set_network mainnet, enabled: rc 0" 0 "$RC"
check_has "json_set_network mainnet, enabled: the mainnet values" "set: mainnet|487|telcoin|https://rpc.telcoin.network|https://telscan.io" "$OUT"

# The whole script: --network mainnet stops at the gate, before the install
# flags are even read (the launch copy goes on to ask for --install-method).
rm -rf "$T/fx-setup"
mkdir -p "$T/fx-setup"
OUT="$(TN_ROOT_PREFIX="$T/fx-setup" "$BASH" "$T/off/setup-node-run.sh" --json --phase=keygen --network mainnet </dev/null 2>/dev/null)"
RC=$?
check_rc "setup-node --json --network mainnet, disabled: rc 1" 1 "$RC"
check "setup-node --json --network mainnet, disabled: ends with the refusal" \
    "{\"event\":\"done\",\"ok\":false,\"msg\":\"${MAINNET_OFF}\"}" "$(printf '%s\n' "$OUT" | tail -n 1)"
check "setup-node --json --network mainnet, disabled: nothing written" "" "$(find "$T/fx-setup" -mindepth 1 2>/dev/null)"
OUT="$(TN_ROOT_PREFIX="$T/fx-setup" "$BASH" "$T/on/setup-node-run.sh" --json --phase=keygen --network mainnet </dev/null 2>/dev/null)"
check "setup-node --json --network mainnet, enabled: past the gate" \
    "{\"event\":\"done\",\"ok\":false,\"msg\":\"--install-method is missing (expected source, release, docker or existing)\"}" \
    "$(printf '%s\n' "$OUT" | tail -n 1)"

# -----------------------------------------------------------------------------
# image_network: the network of a Docker image change (_tn_guard_network):
# detect_network's, or devnet from NETWORK=devnet in .node-meta (detect_network
# itself stays rc 1 there). Nothing else is guessed.
# -----------------------------------------------------------------------------
no_genesis
meta $'NETWORK=devnet\n'
run image_network
check "image_network, NETWORK=devnet: devnet" "0 devnet" "$RC $OUT"
meta $'NETWORK=devnet\r\n'
run image_network
check "image_network, CRLF NETWORK=devnet: devnet" "0 devnet" "$RC $OUT"
meta $'NETWORK=testnet\n'
run image_network
check "image_network, NETWORK=testnet: testnet" "0 testnet" "$RC $OUT"
meta $'NETWORK=mainnet\n'
run image_network
check "image_network, NETWORK=mainnet: mainnet" "0 mainnet" "$RC $OUT"
genesis 32285
meta $'INSTALL_METHOD=docker\n'
run image_network
check "image_network, no NETWORK, devnet genesis: rc 1, nothing" "1 " "$RC $OUT"
no_genesis
meta $'NETWORK=devnet\n' $'NETWORK=devnet\n'
run image_network
check "image_network, duplicate NETWORK=devnet: rc 1, nothing" "1 " "$RC $OUT"
check "image_network, duplicate NETWORK=devnet: named on stderr" yes "$(has "$ERR" "NETWORK is set 2 times")"
meta $'NETWORK=foo\n'
run image_network
check "image_network, NETWORK=foo: rc 1, nothing" "1 " "$RC $OUT"
check "image_network, NETWORK=foo: detect_network's reason on stderr" yes "$(has "$ERR" "NETWORK='foo'")"

# pending_key_check NEW_IMAGE on a devnet host: validate_docker_image takes the
# network from _tn_guard_network (no NETWORK global in update-node.sh).
R="us-docker.pkg.dev/telcoin-network/tn-public/adiri"
GH="ghcr.io/telcoin-association/telcoin-network"
D64="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
pk() {  # pk NAME EXPECTED-RC IMAGE
    local rc=0
    ( unset NETWORK TN_DOCKER_REQUIRE_DIGEST; pending_key_check NEW_IMAGE "$3" ) >/dev/null 2>&1 || rc=$?
    check_rc "$1" "$2" "$rc"
}
meta $'NETWORK=devnet\n'
pk "pending NEW_IMAGE, devnet: a digest of the old single ghcr package (recognised)" 0 "${GH}@sha256:${D64}"
pk "pending NEW_IMAGE, devnet: a legacy-repository digest" 0 "${R}@sha256:${D64}"
pk "pending NEW_IMAGE, devnet: another repository refused" 1 "docker.io/library/busybox@sha256:${D64}"
pk "pending NEW_IMAGE, devnet: a devnet tag refused" 1 "${R}:v0.2.0-devnet"
pk "pending NEW_IMAGE, devnet: a leading dash refused" 1 "-${GH}@sha256:${D64}"
meta $'NETWORK=testnet\n'
pk "pending NEW_IMAGE, testnet: a legacy-repository digest" 0 "${R}@sha256:${D64}"
meta $'NETWORK=mainnet\n'
pk "pending NEW_IMAGE, mainnet: the legacy repository refused" 1 "${R}@sha256:${D64}"
meta $'NETWORK=foo\n'
pk "pending NEW_IMAGE, network unknown: refused" 1 "${GH}@sha256:${D64}"

# fetch_docker_tags on devnet: nothing offered, and the registry is never asked
# (tn_registry_tags is stubbed to fail loudly; testnet is the positive control).
loud_tags() {  # loud_tags [NETWORK]
    rm -f "$T/loud.log"
    tn_registry_tags() { printf 'tn_registry_tags %s\n' "$*" >> "$T/loud.log"; printf 'v0.17.0-adiri\nv0.2.0-devnet\n'; }
    fetch_docker_tags "$@"
}
rc=0; out="$(loud_tags devnet)" || rc=$?
check "fetch_docker_tags devnet: nothing" "0 " "$rc $out"
check "fetch_docker_tags devnet: the registry not asked" no "$(exists "$T/loud.log")"
meta $'NETWORK=devnet\n'
rc=0; out="$(loud_tags)" || rc=$?
check "fetch_docker_tags, a devnet host: nothing" "0 " "$rc $out"
check "fetch_docker_tags, a devnet host: the registry not asked" no "$(exists "$T/loud.log")"
rc=0; out="$(loud_tags testnet)" || rc=$?
check "fetch_docker_tags testnet (control): the stub's final testnet tag" "0 v0.17.0-adiri" "$rc $out"
check "fetch_docker_tags testnet (control): the registry asked" yes "$(exists "$T/loud.log")"

# json_prepare_docker on a devnet host: a digest of the devnet repository or of
# the dev package goes on to the pull; a tag (devnet or testnet), another
# repository or the old single ghcr package (recognised, never pulled) is refused
# first. On a testnet host the dev package is refused.
# jpd_stubbed ARG -- json_prepare_docker with the running image and the pull
# stubbed (in run's subshell, so the real functions stay for later cases).
jpd_stubbed() {
    detect_current_docker_image() { printf '%s@sha256:%s\n' "$R" "$(printf '%s' "$D64" | tr 0 b)"; }
    docker_pull_target() { printf '%s %s\n' "$1" "$3" > "$T/pulled"; return 1; }
    json_prepare_docker "$1"
}
jpd() {  # jpd ARG -> JSON events in $T/json.log; RC
    rm -f "$T/pulled"
    exec 3>"$T/json.log"
    JSON_MODE=true
    run jpd_stubbed "$1"
    JSON_MODE=false
    exec 3>&-
}
meta $'NETWORK=devnet\n'
jpd "${R}@sha256:${D64}"
check "json prepare, devnet: a devnet repository digest reaches the pull" "1 ${R}@sha256:${D64} " "$RC $(cat "$T/pulled" 2>/dev/null)"
GD="ghcr.io/telcoin-association/tn-dev"
jpd "${GD}@sha256:${D64}"
check "json prepare, devnet: a dev package digest reaches the pull" "1 ${GD}@sha256:${D64} " "$RC $(cat "$T/pulled" 2>/dev/null)"
meta $'NETWORK=testnet\n'
jpd "${GD}@sha256:${D64}"
check "json prepare, testnet: the dev package refused before any pull" "1 yes no" \
    "$RC $(has "$(cat "$T/json.log")" "is not a testnet release tag or this network's image by digest") $(exists "$T/pulled")"
meta $'NETWORK=devnet\n'
for bad in v0.2.0-devnet "${R}:v0.2.0-devnet" v0.17.0-adiri "docker.io/library/busybox@sha256:${D64}" "${GH}@sha256:${D64}"; do
    jpd "$bad"
    check "json prepare, devnet: ${bad} refused before any pull" "1 yes no" \
        "$RC $(has "$(cat "$T/json.log")" "is not a devnet image by digest") $(exists "$T/pulled")"
done
meta $'NETWORK=foo\n'
jpd "${GH}@sha256:${D64}"
check "json prepare, network unknown: refused before any pull" "1 yes no" \
    "$RC $(has "$(cat "$T/json.log")" "cannot tell which network") $(exists "$T/pulled")"
# docker_pull_target (update-node's Docker prepare, interactive and --json): after
# the pull and its digest check the image's build features are checked for the
# node's network (tn_docker_image_network_ok, stubbed here: FEAT_RC=1 refuses),
# before the pending state is written; a refusal writes none and the --json
# prepare ends with an error event (the exit trap then sends done).
dpt_stubbed() {
    detect_current_docker_image() { printf '%s@sha256:%s\n' "$R" "$(printf '%s' "$D64" | tr 0 b)"; }
    build_log_file() { printf '%s\n' "$T/pull.log"; }
    docker() { printf '%s\n' "$*" >> "$T/order.log"; }
    tn_docker_holds_digest() { echo held >> "$T/order.log"; return 0; }
    tn_docker_image_network_ok() { printf 'check %s %s\n' "$1" "$2" >> "$T/order.log"; return "${FEAT_RC:-0}"; }
    write_pending_state() { echo pending >> "$T/order.log"; cat > "$T/pending"; }
    storage_migration_begin() { :; }
    json_prepare_docker "$1"
}
dpt() {  # dpt ARG -> JSON events in $T/json.log; the calls in $T/order.log; RC
    rm -f "$T/pending"
    : > "$T/order.log"
    exec 3>"$T/json.log"
    JSON_MODE=true
    run dpt_stubbed "$1"
    JSON_MODE=false
    exec 3>&-
}
order() { grep -v '^image inspect' "$T/order.log" | tr '\n' '|' | sed 's/|$//'; }
meta $'NETWORK=testnet\n'
dpt "${R}@sha256:${D64}"
check "docker prepare: pull, digest check, feature check, then the pending state" \
    "0 pull ${R}@sha256:${D64}|held|check testnet ${R}@sha256:${D64}|pending" "$RC $(order)"
check "docker prepare: the pending state names the new image" yes "$(has "$(cat "$T/pending" 2>/dev/null)" "NEW_IMAGE=${R}@sha256:${D64}")"
FEAT_RC=1
dpt "${R}@sha256:${D64}"
check "docker prepare, feature check refuses: rc 1, no pending state" "1 no" "$RC $(exists "$T/pending")"
check "docker prepare, feature check refuses: nothing after the check" \
    "pull ${R}@sha256:${D64}|held|check testnet ${R}@sha256:${D64}" "$(order)"
check "docker prepare, feature check refuses: a warn event says nothing was prepared" yes \
    "$(has "$(cat "$T/json.log")" "\"event\":\"warn\",\"msg\":\"The image ${R}@sha256:${D64} is not a testnet image (see above); nothing was prepared and the node was not touched.\"")"
check "docker prepare, feature check refuses: then an error event" yes \
    "$(has "$(cat "$T/json.log")" "\"event\":\"error\",\"msg\":\"the image ${R}@sha256:${D64} was not prepared (see the warning above)\"")"
check "docker prepare, feature check refuses: no done ok event" no "$(has "$(cat "$T/json.log")" '"ok":true')"
unset FEAT_RC
meta $'NETWORK=devnet\n'
dpt "${R}@sha256:${D64}"
check "docker prepare, devnet: the check is asked for devnet" "0 yes" "$RC $(has "$(order)" "check devnet ${R}@sha256:${D64}")"
unset -f dpt_stubbed dpt order
unset -f jpd_stubbed jpd loud_tags pk

# -----------------------------------------------------------------------------
# prepare: an unknown network stops before git and cargo
# -----------------------------------------------------------------------------
confirm() { return 0; }

prep_case() {
    local name="$1"
    rm -f "$T/cargo-ran" "$T/git-ran"
    run prepare_source_build v0.16.0-adiri
    check_rc "${name}: prepare rc 1" 1 "$RC"
    check "${name}: prepare names the network problem" yes "$(has "$OUT$ERR" "Cannot tell which network")"
    check "${name}: cargo never ran" no "$(exists "$T/cargo-ran")"
    check "${name}: git never ran" no "$(exists "$T/git-ran")"
    exec 3>"$T/json.log"
    JSON_MODE=true
    run json_prepare_source v0.16.0-adiri
    JSON_MODE=false
    exec 3>&-
    check_rc "${name}: --json prepare rc 1" 1 "$RC"
    check "${name}: --json error event" yes "$(has "$(cat "$T/json.log")" "cannot tell which network")"
    check "${name}: --json cargo never ran" no "$(exists "$T/cargo-ran")"
    check "${name}: --json git never ran" no "$(exists "$T/git-ran")"
}

genesis 487
meta $'NETWORK=foo\n'
prep_case "NETWORK=foo"
meta $'NETWORK=mainnet\n' $'NETWORK=mainnet\n'
prep_case "duplicate NETWORK"
meta $'NETWORK=devnet\n'
prep_case "NETWORK=devnet"
genesis 32285
meta $'INSTALL_METHOD=source\n'
prep_case "no NETWORK, devnet genesis"

# Positive controls: a known network gets its features and gets past the check.
meta $'NETWORK=testnet\r\n'
rm -f "$T/cargo-ran"
run prepare_source_build v0.16.0-adiri
check "testnet: prepare builds with the adiri feature" yes "$(has "$OUT$ERR" "Network: testnet -- building with --features adiri")"
check "testnet: cargo never ran (no source tree here)" no "$(exists "$T/cargo-ran")"
meta $'NETWORK=mainnet\n'
run prepare_source_build v0.16.0
check "mainnet: prepare builds without the adiri feature" yes "$(has "$OUT$ERR" "Network: mainnet -- building without the adiri feature")"
run tn_cargo_features_for "$(detect_network)"
check "mainnet: no cargo features" "" "$OUT"

# -----------------------------------------------------------------------------
# INSTALL_METHOD and BINARY_PATH through meta_get
# -----------------------------------------------------------------------------
meta $'INSTALL_METHOD=source\r\n'
run detect_install_method
check_rc "INSTALL_METHOD CRLF: rc 0" 0 "$RC"
check "INSTALL_METHOD CRLF: source" "source" "$OUT"
meta $'INSTALL_METHOD=source\n' $'INSTALL_METHOD=docker\n'
run detect_install_method
check_rc "duplicate INSTALL_METHOD: rc 2" 2 "$RC"
check "duplicate INSTALL_METHOD: nothing printed" "" "$OUT"
meta $'NETWORK=testnet\n'
run detect_install_method
check_rc "no INSTALL_METHOD: rc 0" 0 "$RC"
check "no INSTALL_METHOD: nothing printed" "" "$OUT"

tn_launch_runner() { return 1; }
meta $'BINARY_PATH=/usr/local/bin/tn-a\n' $'BINARY_PATH=/usr/local/bin/tn-b\n'
run existing_binary_path
check_rc "duplicate BINARY_PATH: rc 2" 2 "$RC"
check "duplicate BINARY_PATH: not the default path" no "$(has "$OUT" "${DEFAULT_INSTALL_DIR}/telcoin-network")"
check "duplicate BINARY_PATH: neither recorded path" no "$(has "$OUT" "/usr/local/bin/tn-")"
check "duplicate BINARY_PATH: explained" yes "$(has "$ERR" "BINARY_PATH is set more than once")"
meta $'BINARY_PATH=/usr/local/bin/tn-a\n'
run existing_binary_path
check "single BINARY_PATH: used" "/usr/local/bin/tn-a" "$OUT"

# -----------------------------------------------------------------------------
# Build log and build output
# -----------------------------------------------------------------------------
mkdir -p "$T/tmpdir"
L1="$(TMPDIR="$T/tmpdir" build_log_file)"
L2="$(TMPDIR="$T/tmpdir" build_log_file)"
check "build log: under TMPDIR with the tn-build prefix" yes "$(has "$L1" "$T/tmpdir/tn-build.")"
check "build log: mode 600" "600" "$(stat -c '%a' -- "$L1" 2>/dev/null)"
check "build log: a new name each time" yes "$([[ -n "$L1" && "$L1" != "$L2" ]] && echo yes || echo no)"

printf 'bin\n' > "$T/built"
run tn_built_binary_ok "$T/built" "$(id -u)"
check_rc "built binary: regular file owned by this uid" 0 "$RC"
ln -s "$T/built" "$T/built-link"
run tn_built_binary_ok "$T/built-link" "$(id -u)"
check_rc "built binary: symlink refused" 1 "$RC"
run tn_built_binary_ok "$T/missing" "$(id -u)"
check_rc "built binary: missing refused" 1 "$RC"
mkdir "$T/built-dir"
run tn_built_binary_ok "$T/built-dir" "$(id -u)"
check_rc "built binary: directory refused" 1 "$RC"
run tn_built_binary_ok "$T/built" 4242
check_rc "built binary: another owner refused" 1 "$RC"

# ---- LIB-B: check_internet probes the node's own network ----------------------------
# A recording curl answers only for the URLs in CURL_OK. check_internet exits, so
# it runs in a subshell and the log file carries what it did.
CURL_OK=""
curl() {
    local u
    for u in "$@"; do :; done
    printf '%s\n' "$u" >> "$T/curl.log"
    case " $CURL_OK " in
        *" $u "*) return 0 ;;
    esac
    return 7
}
SAVED_NETWORK="${NETWORK:-}"
# net_probe NETWORK -- one check_internet: RC, PROBED (the URLs curl was given, in
# order) and its output in ci.out.
net_probe() {
    rm -f "$T/curl.log"
    NETWORK="$1"
    RC=0
    ( check_internet ) > "$T/ci.out" 2>&1 || RC=$?
    PROBED="$(cat "$T/curl.log" 2>/dev/null || true)"
}
CURL_OK="$MAINNET_RPC_URL"
net_probe mainnet
check_rc "check_internet: mainnet answers" 0 "$RC"
check "check_internet: mainnet probes its own RPC only" "$MAINNET_RPC_URL" "$PROBED"
CURL_OK="https://1.1.1.1"
net_probe mainnet
check "check_internet: mainnet RPC down, then 1.1.1.1" "$(printf '%s\n%s' "$MAINNET_RPC_URL" https://1.1.1.1)" "$PROBED"
check_lacks "check_internet: mainnet never probes adiri" "adiri" "$PROBED"
CURL_OK="$DEVNET_RPC_URL"
net_probe devnet
check "check_internet: devnet probes the devnet RPC" "$DEVNET_RPC_URL" "$PROBED"
CURL_OK="$TESTNET_RPC_URL"
net_probe testnet
check "check_internet: testnet probes the testnet RPC" "$TESTNET_RPC_URL" "$PROBED"
CURL_OK=""
net_probe testnet
check_rc "check_internet: nothing answers: exit 1" 1 "$RC"
check "check_internet: nothing answers: said so" yes "$(grep -qF 'No internet connection detected.' "$T/ci.out" && echo yes || echo no)"
CURL_OK="https://1.1.1.1"
net_probe ""
check_rc "check_internet: NETWORK empty fails closed" 1 "$RC"
check "check_internet: NETWORK empty: curl not called" "" "$PROBED"
check "check_internet: NETWORK empty: the message names NETWORK" yes "$(grep -qF 'NETWORK must be testnet, mainnet or devnet (it is empty)' "$T/ci.out" && echo yes || echo no)"
net_probe adiri
check_rc "check_internet: unknown NETWORK fails closed" 1 "$RC"
check "check_internet: unknown NETWORK: curl not called" "" "$PROBED"
unset -f curl
NETWORK="$SAVED_NETWORK"
# setup-node's preflight sets NETWORK (the prompt, or --network in a --json run)
# before its connectivity check runs.
check "setup-node: the network is chosen before check_internet" yes "$(awk '
    /^step_preflight\(\) \{/ { f = 1 }
    f && /^}/ { exit }
    f && /^[[:space:]]*json_mode \|\| select_network/ { s = NR }
    f && /^[[:space:]]*check_internet[[:space:]]*$/ { c = NR }
    END { print (s && c && s < c) ? "yes" : "no" }' "$TN_TEST_REPO/setup-node.sh")"

# ---- LIB-B: setup-node's image example names the node's own network ------------------
sed -n '/^_setup_image_example() {/,/^}/p' "$TN_TEST_REPO/setup-node.sh" > "$T/img.sh"
# shellcheck source=/dev/null
. "$T/img.sh"
SAVED_NETWORK="${NETWORK:-}"
NETWORK=mainnet
img="$(_setup_image_example)"
check "image example: mainnet is the mainnet repository by digest" "$(tn_docker_repo_for mainnet)@sha256:<digest>" "$img"
check "image example: mainnet is the tn-mainnet package" "ghcr.io/telcoin-association/tn-mainnet@sha256:<digest>" "$img"
check_lacks "image example: mainnet names no testnet package" "tn-testnet" "$img"
check_lacks "image example: mainnet names not the old single package" "telcoin-association/telcoin-network" "$img"
check_lacks "image example: mainnet names no adiri image" "adiri" "$img"
check_lacks "image example: mainnet is not the testnet default" "$DEFAULT_DOCKER_IMAGE" "$img"
NETWORK=testnet
check "image example: testnet unchanged" "$DEFAULT_DOCKER_IMAGE" "$(_setup_image_example)"
NETWORK=devnet
check "image example: devnet unchanged" "${TN_DEVNET_IMAGE_REPO}@sha256:<digest>" "$(_setup_image_example)"
NETWORK="$SAVED_NETWORK"

finish
