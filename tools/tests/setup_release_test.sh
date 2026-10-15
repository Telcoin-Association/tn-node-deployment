#!/usr/bin/env bash
# tools/tests/setup_release_test.sh -- setup-node.sh's install inputs and Docker host
# setup: --release-tag/--build-ref take release tags of the network only and must
# agree, --docker-image takes a digest reference only (never with --release-tag),
# --install-method release is known, --allow-dirty is refused in --json; the
# live-restore merge of /etc/docker/daemon.json keeps other settings, leaves an
# already-set file alone and stops on a file that is not a JSON object; and
# edit-config.sh's set_docker_image resolves a release tag to its digest, runs only
# a digest, and records the image in .node-meta.
#
# Copies of setup-node.sh and edit-config.sh without their last line are sourced in
# subshells (both source lib/common.sh, whose readonly constants cannot be set
# twice in one shell). Maintainer tooling (not updater-tracked). bash 3.2 safe.
# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
mkdir -p "$T/sn" "$T/ec" "$T/root/etc/telcoin"
grep -v '^main "\$@"$' "$TN_TEST_REPO/setup-node.sh" > "$T/sn/setup-node.sh"
grep -v '^main "\$@"$' "$TN_TEST_REPO/edit-config.sh" > "$T/ec/edit-config.sh"
ln -s "$TN_TEST_REPO/lib" "$T/sn/lib"
ln -s "$TN_TEST_REPO/lib" "$T/ec/lib"
export TN_ROOT_PREFIX="$T/root" T
R="us-docker.pkg.dev/telcoin-network/tn-public/adiri"
D64="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
export R D64

# sn CODE -- run CODE in a subshell that sourced setup-node.sh (setup_fail exits 1
# with its message on stderr); prints "<rc>".
sn() {
    ( set +e
      # shellcheck source=/dev/null
      source "$T/sn/setup-node.sh" >/dev/null 2>&1
      set +e
      setup_fail() { printf '%s\n' "$*" >&2; exit 1; }
      setup_warn() { :; }
      eval "$1" ) >"$T/sn.out" 2>"$T/sn.err"
    printf '%s' "$?"
}
flags() {  # flags NAME EXPECTED-RC NETWORK METHOD TAG BUILD_REF IMAGE [PHASE]
    local rc
    rc="$(sn "JSON_MODE=true NETWORK=$3 INSTALL_METHOD='$4' RELEASE_TAG='$5' JSON_BUILD_REF='$6' DOCKER_IMAGE='$7' JSON_PHASE='${8:-keygen}'; init_install_flags; json_check_install_flags")"
    check_rc "$1" "$2" "$rc"
}
flags "release install with a testnet tag" 0 testnet release v0.16.0-adiri "" ""
flags "--build-ref alone names the release" 0 testnet release "" v0.16.0-adiri ""
flags "release install without a tag refused" 1 testnet release "" "" ""
flags "source build of main refused" 1 testnet source "" main ""
flags "source build of a commit id refused" 1 testnet source 5535ef1f0425973bd81ef3162f3d07219c3456d0 "" ""
flags "testnet tag on mainnet refused" 1 mainnet release v0.16.0-adiri "" ""
flags "--release-tag and --build-ref disagree" 1 testnet source v0.16.0-adiri v0.17.0-adiri ""
flags "docker by digest" 0 testnet docker "" "" "${R}@sha256:${D64}"
flags "docker by tag refused" 1 testnet docker "" "" "${R}:v0.16.0-adiri"
flags "docker image and release tag together refused" 1 testnet docker v0.16.0-adiri "" "${R}@sha256:${D64}"
flags "unknown install method refused" 1 testnet binary "" "" ""
flags "docker on mainnet (no image repository) refused" 1 mainnet docker "" "" ""
check "docker on mainnet: the refusal names the open decision" yes "$(grep -q 'open decision' "$T/sn.err" && echo yes || echo no)"
flags "docker on devnet (no image repository) refused" 1 devnet docker "" "" ""
# _preflight_docker: a network without an image repository stops before Docker's apt
# repository, the engine or daemon.json is touched.
for net in mainnet devnet; do
    rc="$(sn "NETWORK=$net RELEASE_TAG= DOCKER_IMAGE=; command() { return 1; }; _setup_docker_apt() { echo APT_RAN; }; _setup_docker_live_restore() { echo LIVE_RESTORE_RAN; }; _preflight_docker")"
    check "_preflight_docker on $net: refused before apt and daemon.json" "1 no no" \
        "$rc $(grep -q APT_RAN "$T/sn.out" && echo yes || echo no) $(grep -q LIVE_RESTORE_RAN "$T/sn.out" && echo yes || echo no)"
done
rc="$(sn "JSON_MODE=true ALLOW_DIRTY=true INSTALL_METHOD=source; init_install_flags")"
check_rc "--allow-dirty in --json refused" 1 "$rc"

# _preflight_docker: the pulled image must be held under the digest asked for.
PD='command() { [ "$2" = docker ]; }; _setup_docker_live_restore() { :; }; docker() { printf "%s\n" "$*" >> "$T/docker.log"; }; NETWORK=testnet RELEASE_TAG= DOCKER_IMAGE="${R}@sha256:${D64}"'
: > "$T/docker.log"
rc="$(sn "$PD; tn_docker_holds_digest() { return 1; }; _preflight_docker")"
check "pulled image not held under its digest: setup stops" "1 yes" "$rc $(grep -q 'digest mismatch' "$T/sn.err" && echo yes || echo no)"
check_has "the image was pulled by digest" "pull ${R}@sha256:${D64}" "$(cat "$T/docker.log")"
rc="$(sn "$PD; tn_docker_holds_digest() { [ \"\$1\" = \"\$DOCKER_IMAGE\" ]; }; _preflight_docker; printf '%s' \"\$BINARY_PATH\" > \"\$T/bp\"")"
check "pulled image held under its digest: setup goes on" "0 docker" "$rc $(cat "$T/bp" 2>/dev/null)"

# _preflight_docker: an image given by digest alone is held to the oldest supported
# release through the release .node-meta records for that digest; otherwise a warning.
PDW='command() { [ "$2" = docker ]; }; _setup_docker_live_restore() { :; }; docker() { :; }; tn_docker_holds_digest() { return 0; }; setup_warn() { printf "WARN %s\n" "$*" >&2; }; NETWORK=testnet RELEASE_TAG= DOCKER_IMAGE="${R}@sha256:${D64}"'
rm -f "$T/root/etc/telcoin/.node-meta"
rc="$(sn "$PDW; _preflight_docker")"
check "digest alone, nothing recorded: goes on with a floor warning" "0 yes" "$rc $(grep -q 'WARN.*cannot be checked against the v' "$T/sn.err" && echo yes || echo no)"
printf 'DOCKER_IMAGE_DIGEST=sha256:%s\nRELEASE_TAG=v0.12.0-adiri\n' "$D64" > "$T/root/etc/telcoin/.node-meta"
rc="$(sn "$PDW; _preflight_docker")"
check "digest alone, recorded as a release below the floor: refused" "1 yes" "$rc $(grep -q 'older than v' "$T/sn.err" && echo yes || echo no)"
rm -f "$T/root/etc/telcoin/.node-meta"

# live-restore merge (tn_write_root_file and systemctl stubbed).
LR='tn_write_root_file() { cat > "$1"; }; systemctl() { printf "%s\n" "$*" >> "$T/systemctl.log"; }; _setup_docker_live_restore'
DJ="$T/root/etc/docker/daemon.json"
mkdir -p "$T/root/etc/docker"   # install -d -o root needs root
rc="$(sn "$LR")"
check "absent daemon.json: written with live-restore" "0 yes" "$rc $(grep -q '"live-restore": true' "$DJ" 2>/dev/null && echo yes || echo no)"
printf '{"log-driver": "json-file", "live-restore": false}\n' > "$DJ"
if ! command -v python3 >/dev/null 2>&1 && ! command -v jq >/dev/null 2>&1; then
    cp "$DJ" "$T/before"
    rc="$(sn "$LR")"
    check "existing daemon.json, no python3 or jq: stops with the manual step, file untouched" "1 yes same" \
        "$rc $(grep -q 'Neither python3 nor jq' "$T/sn.err" && echo yes || echo no) $(cmp -s "$DJ" "$T/before" && echo same || echo changed)"
    skip "daemon.json merge" "python3 and jq absent"
else
    rc="$(sn "$LR")"
    check "existing daemon.json: merged, other settings kept" "0 yes yes" \
        "$rc $(grep -q '"live-restore": true' "$DJ" && echo yes || echo no) $(grep -q '"log-driver": "json-file"' "$DJ" && echo yes || echo no)"
    check_has "docker reloaded, not restarted" "reload docker" "$(cat "$T/systemctl.log" 2>/dev/null)"
    cp "$DJ" "$T/before"
    : > "$T/systemctl.log"
    rc="$(sn "$LR")"
    check "already on: file untouched, no reload" "0 same none" "$rc $(cmp -s "$DJ" "$T/before" && echo same || echo changed) $(cat "$T/systemctl.log")none"
    printf '[1, 2]\n' > "$DJ"
    rc="$(sn "$LR")"
    check "not a JSON object: stops with the manual step" "1 yes [1, 2]" "$rc $(grep -q 'by hand' "$T/sn.err" && echo yes || echo no) $(cat "$DJ")"
fi

# Empty files and several documents, with python3 and with jq alone.
lr_on() { grep -q '"live-restore": true' "$DJ" && echo yes || echo no; }
for tool in python3 jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        skip "daemon.json edge cases with $tool" "$tool absent"
        continue
    fi
    only=""
    if [[ "$tool" == "jq" ]]; then
        only='command_exists() { [ "$1" != python3 ] && command -v "$1" >/dev/null 2>&1; }; '
    fi
    : > "$DJ"
    : > "$T/systemctl.log"
    rc="$(sn "${only}${LR}")"
    check "$tool: an empty daemon.json is taken as {}" "0 yes" "$rc $(lr_on)"
    check "$tool: live-restore reported on only once set" yes "$(grep -q 'live-restore on' "$T/sn.out" && echo yes || echo no)"
    printf '  \n\n' > "$DJ"
    rc="$(sn "${only}${LR}")"
    check "$tool: a whitespace-only daemon.json is taken as {}" "0 yes" "$rc $(lr_on)"
    printf '{"a": 1}\n{"b": 2}\n' > "$DJ"
    cp "$DJ" "$T/before"
    rc="$(sn "${only}${LR}")"
    check "$tool: two JSON documents are refused, file untouched" "1 same" "$rc $(cmp -s "$DJ" "$T/before" && echo same || echo changed)"
    printf '{"live-restore": true}\n{"b": 2}\n' > "$DJ"
    cp "$DJ" "$T/before"
    rc="$(sn "${only}${LR}")"
    check "$tool: two documents, the first already on: refused, not reported on" "1 same no" \
        "$rc $(cmp -s "$DJ" "$T/before" && echo same || echo changed) $(grep -q 'already on' "$T/sn.out" && echo yes || echo no)"
    printf '{"log-driver": "local"}\n' > "$DJ"
    rc="$(sn "${only}tn_write_root_file() { printf '{}\\n' > \"\$1\"; }; systemctl() { :; }; _setup_docker_live_restore")"
    check "$tool: a write that does not hold the key is not reported on" "1 no" \
        "$rc $(grep -q 'live-restore on' "$T/sn.out" && echo yes || echo no)"
done

# edit-config set_docker_image.
ec() {
    ( set +e
      # shellcheck source=/dev/null
      source "$T/ec/edit-config.sh" >/dev/null 2>&1
      set +e
      TARGET_LAUNCH_FILE="$T/tn-start-docker"
      tn_detect_network() { printf 'testnet\n'; }
      read_launch_line() { printf 'exec docker run --rm %s telcoin node --http\n' "${R}:v0.16.0-adiri"; }
      edit_launch_unambiguous() { return 0; }
      tn_docker_image_for_tag() { printf '%s@sha256:%s\n' "$R" "$D64"; }
      tn_docker_holds_digest() { return 0; }
      docker() { printf '%s\n' "$*" >> "$T/docker.log"; }
      swap_docker_image() { printf '%s\n' "$1" > "$T/swapped"; }
      meta_set() { printf '%s=%s\n' "$1" "$2" >> "$T/meta.log"; }
      meta_unset() { printf 'unset %s\n' "$1" >> "$T/meta.log"; }
      edit_error() { printf '%s\n' "$*" >&2; }
      edit_step() { :; }
      set_docker_image "$1" ) >/dev/null 2>"$T/ec.err"
    printf '%s' "$?"
}
rm -f "$T/swapped" "$T/meta.log"
rc="$(ec v0.17.0-adiri)"
check "edit: a release tag runs its digest" "0 ${R}@sha256:${D64}" "$rc $(cat "$T/swapped" 2>/dev/null)"
check "edit: .node-meta records image, digest and tag" "DOCKER_IMAGE=${R}@sha256:${D64} DOCKER_IMAGE_DIGEST=sha256:${D64} RELEASE_TAG=v0.17.0-adiri" "$(tr '\n' ' ' < "$T/meta.log" | sed 's/ $//')"
rm -f "$T/swapped" "$T/meta.log"
rc="$(ec "${R}:latest")"
check "edit: latest refused, nothing swapped" "1 no" "$rc $([[ -e "$T/swapped" ]] && echo yes || echo no)"
rc="$(ec "docker.io/library/busybox@sha256:${D64}")"
check "edit: another repository refused" "1 no" "$rc $([[ -e "$T/swapped" ]] && echo yes || echo no)"
rm -f "$T/meta.log"
rc="$(ec "${R}@sha256:$(printf '%s' "$D64" | tr 0 a)")"
check "edit: a digest alone runs as given, tag removed from .node-meta" "0 yes" "$rc $(grep -qx 'unset RELEASE_TAG' "$T/meta.log" && echo yes || echo no)"
rc="$( ( set +e; source "$T/ec/edit-config.sh" >/dev/null 2>&1; set +e; edit_error() { :; }; launch_current_form() { echo called > "$T/lcf"; }; swap_docker_image "${R}:v0.16.0-adiri" ) >/dev/null 2>&1; printf '%s' "$?")"
check "edit: swap_docker_image refuses a tag before touching anything" "1 no" "$rc $([[ -e "$T/lcf" ]] && echo yes || echo no)"
finish
