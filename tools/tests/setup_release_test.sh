#!/usr/bin/env bash
# tools/tests/setup_release_test.sh -- setup-node.sh's install inputs and Docker host
# setup: --release-tag/--build-ref take release tags of the network only and must
# agree, --docker-image takes a digest reference only (never with --release-tag),
# --install-method release is known, --allow-dirty is refused in --json; on devnet
# (no signed releases) --docker-image takes a digest of the devnet repository (the
# old single ghcr package is recognised but never pulled) and is
# required at keygen, --release-tag and source or release installs are refused;
# finalize holds the image keygen recorded to the pull rule and the build-feature
# check before the config, the unit and the container, and --docker-image there
# replaces it through keygen's checks, recorded only when all pass; the interactive image
# prompt stops at the end of input; the
# live-restore merge of /etc/docker/daemon.json keeps other settings, leaves an
# already-set file alone and stops on a file that is not a JSON object; and
# edit-config.sh's set_docker_image resolves a release tag to its digest, runs only
# a digest, and records the image in .node-meta, as its interactive menu
# (edit_docker_image) does; on a devnet host (NETWORK=devnet in .node-meta) it
# takes a digest only. In all of them, the image's build-feature check
# (tn_docker_image_network_ok, stubbed here and tested in docker_image_test.sh)
# runs after the pull and its digest check and before anything uses the image; a
# refusal stops the install or the change.
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
      # The build-feature check: logged beside the docker calls; FEAT_RC=1 refuses.
      tn_docker_image_network_ok() { printf 'check %s %s\n' "$1" "$2" >> "$T/docker.log"; return "${FEAT_RC:-0}"; }
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
flags "docker on mainnet (no mainnet release verifies yet) refused" 1 mainnet docker "" "" ""
check "docker on mainnet: the refusal says no mainnet release can be verified" yes "$(grep -q 'No mainnet release can be verified yet' "$T/sn.err" && echo yes || echo no)"
# Once Docker is allowed on mainnet (the launch release pins the chain configs), a
# digest alone of the mainnet package is taken only when .node-meta records it as
# a mainnet release's image: _preflight_docker refuses it before any docker
# call, for --docker-image and for a typed image alike; an image resolved from a
# release tag passes, and testnet is unchanged. The docker stub records its calls.
MR="ghcr.io/telcoin-association/tn-mainnet"
PD_STUBS="tn_docker_network_ok() { return 0; }; _setup_docker_apt() { :; }; _setup_docker_live_restore() { :; }; docker() { echo DOCKER_RAN; return 0; }; tn_docker_release_tag_for() { return 1; }; latest_docker_image() { return 1; }"
refused() { grep -q 'is not the image of a mainnet release this node has installed' "$T/sn.err" && echo yes || echo no; }
rc="$(sn "NETWORK=mainnet RELEASE_TAG= DOCKER_IMAGE='${MR}@sha256:${D64}'; ${PD_STUBS}; _preflight_docker")"
check_rc "mainnet preflight: a digest alone of no installed mainnet release is refused" 1 "$rc"
check "mainnet preflight: the refusal says to give the release tag" yes "$(grep -q 'give the release tag with --release-tag' "$T/sn.err" && echo yes || echo no)"
check "mainnet preflight: refused before any docker call" no "$(grep -q DOCKER_RAN "$T/sn.out" && echo yes || echo no)"
printf 'NETWORK=mainnet\nRELEASE_TAG=v1.0.0\nDOCKER_IMAGE_DIGEST=sha256:%s\n' "$D64" > "$T/root/etc/telcoin/.node-meta"
rc="$(sn "NETWORK=mainnet RELEASE_TAG= DOCKER_IMAGE='${MR}@sha256:${D64}'; ${PD_STUBS}; _preflight_docker")"
check "mainnet preflight: the digest of the recorded mainnet release passes the rule" no "$(refused)"
check "mainnet preflight: the recorded release image goes on to docker" yes "$(grep -q DOCKER_RAN "$T/sn.out" && echo yes || echo no)"
rm -f "$T/root/etc/telcoin/.node-meta"
# The interactive prompt: read is replaced by a stub that hands out INPUTS one
# at a time ("|" separated) and ends the subshell with rc 99 when they run out,
# so a prompt loop that never accepts an input cannot hang the test.
READ_STUB='read() { local a n v; for a in "$@"; do n="$a"; done; [[ -n "${INPUTS:-}" ]] || exit 99; case "$INPUTS" in *"|"*) v="${INPUTS%%|*}"; INPUTS="${INPUTS#*|}" ;; *) v="$INPUTS"; INPUTS="" ;; esac; printf -v "$n" "%s" "$v"; }'
rc="$(sn "NETWORK=mainnet RELEASE_TAG= DOCKER_IMAGE=; JSON_MODE=false; ${PD_STUBS}; tn_docker_image_for_tag() { printf '%s\\n' '${MR}@sha256:${D64}'; }; INPUTS='${MR}@sha256:${D64}|v1.0.0'; ${READ_STUB}; _preflight_docker")"
check "mainnet prompt: a typed digest of no installed release is refused" yes "$(refused)"
check "mainnet prompt: the release tag typed next is accepted" yes "$( [[ "$rc" != 99 ]] && grep -q DOCKER_RAN "$T/sn.out" && echo yes || echo no)"
rc="$(sn "NETWORK=testnet RELEASE_TAG= DOCKER_IMAGE='${R}@sha256:${D64}'; ${PD_STUBS}; _preflight_docker")"
check "testnet preflight: a digest alone is taken as before" no "$(refused)"
# At the end of input (stdin /dev/null) the image prompt stops with a refusal, with
# or without a default, instead of asking again: read is wrapped so that a prompt
# loop ends the subshell with rc 99 at the fourth prompt rather than spinning.
EOF_READ='read() { EOF_N=$((${EOF_N:-0} + 1)); [ "$EOF_N" -le 3 ] || exit 99; builtin read "$@"; }'
not_usable() { cat "$T/sn.out" "$T/sn.err" | grep -c 'Not usable'; }
rc="$(sn "NETWORK=testnet RELEASE_TAG= DOCKER_IMAGE=; JSON_MODE=false; ${PD_STUBS}; ${EOF_READ}; _preflight_docker" < /dev/null)"
check "image prompt at the end of input, no default: refused, not asked again" "1 0" "$rc $(not_usable)"
check "image prompt at the end of input: says no usable image was given" yes \
    "$(grep -qF 'The input ended at the Docker image prompt, so no usable image was given and the Docker install stops.' "$T/sn.err" && echo yes || echo no)"
check "image prompt at the end of input: no docker call" no "$(grep -q DOCKER_RAN "$T/sn.out" && echo yes || echo no)"
rc="$(sn "NETWORK=testnet RELEASE_TAG= DOCKER_IMAGE=; JSON_MODE=false; ${PD_STUBS}; latest_docker_image() { printf '%s\\n' '${R}@sha256:${D64}'; }; ${EOF_READ}; _preflight_docker" < /dev/null)"
check "image prompt at the end of input, with a default: refused too, the default not taken" "1 0 no" \
    "$rc $(not_usable) $(grep -q DOCKER_RAN "$T/sn.out" && echo yes || echo no)"
unset -f not_usable
unset EOF_READ
flags "docker on devnet without --docker-image refused (no signed release to take the newest from)" 1 devnet docker "" "" ""
check "docker on devnet without --docker-image: the refusal asks for one" yes "$(grep -q 'A devnet Docker install needs --docker-image' "$T/sn.err" && echo yes || echo no)"
# Devnet: an image by digest from the devnet repository or the dev package, never
# a tag; no --release-tag, and no install that needs a signed release. The old
# single ghcr package is in TN_DEVNET_IMAGE_REPOS to recognise a container, never
# to pull. The dev package is devnet's only.
GH="ghcr.io/telcoin-association/telcoin-network"
GD="ghcr.io/telcoin-association/tn-dev"
flags "devnet: docker by a legacy-repository digest" 0 devnet docker "" "" "${R}@sha256:${D64}"
flags "devnet: docker by a dev package digest" 0 devnet docker "" "" "${GD}@sha256:${D64}"
flags "devnet: docker by a digest of the old single ghcr package refused" 1 devnet docker "" "" "${GH}@sha256:${D64}"
flags "devnet: docker by another repository's digest refused" 1 devnet docker "" "" "docker.io/library/busybox@sha256:${D64}"
check "devnet: the refusal names the repositories a devnet pull takes" yes "$(grep -qF "the repository one of: ${R} ${GD})" "$T/sn.err" && echo yes || echo no)"
flags "testnet: docker by a dev package digest refused" 1 testnet docker "" "" "${GD}@sha256:${D64}"
flags "testnet: docker by a digest of the old single ghcr package refused" 1 testnet docker "" "" "${GH}@sha256:${D64}"
flags "testnet: docker by a digest of the testnet package" 0 testnet docker "" "" "ghcr.io/telcoin-association/tn-testnet@sha256:${D64}"
flags "testnet: docker by a digest of the mainnet package refused" 1 testnet docker "" "" "${MR}@sha256:${D64}"
flags "devnet: docker by a devnet tag refused" 1 devnet docker "" "" "${R}:v0.2.0-devnet"
flags "devnet: docker by main-<sha> refused" 1 devnet docker "" "" "${R}:main-0123abc"
flags "devnet: docker by a testnet release tag refused" 1 devnet docker "" "" "${R}:v0.16.0-adiri"
flags "devnet: finalize of a docker install without --docker-image (keygen recorded it)" 0 devnet docker "" "" "" finalize
flags "devnet: finalize with no install method (read back from .node-meta)" 0 devnet "" "" "" "" finalize
flags "finalize takes --docker-image (it replaces the recorded image)" 0 testnet docker "" "" "${R}@sha256:${D64}" finalize
flags "finalize: --docker-image of the old single package refused" 1 testnet docker "" "" "ghcr.io/telcoin-association/telcoin-network@sha256:${D64}" finalize
flags "devnet: --release-tag x-devnet refused" 1 devnet docker x-devnet "" ""
check "devnet: the --release-tag refusal says devnet has no signed releases" yes "$(grep -q -- '--release-tag x-devnet is refused on devnet: devnet has no signed releases' "$T/sn.err" && echo yes || echo no)"
flags "devnet: --release-tag x-devnet refused at finalize too" 1 devnet docker x-devnet "" "" finalize
flags "devnet: --build-ref v0.2.0-devnet refused" 1 devnet docker "" v0.2.0-devnet ""
flags "devnet: --release-tag with an existing binary refused" 1 devnet existing v0.2.0-devnet "" ""
flags "devnet: a source build at keygen refused" 1 devnet source "" "" ""
check "devnet: the source refusal names the way out" yes "$(grep -q -- '--install-method source is refused on devnet: it needs a signed release' "$T/sn.err" && echo yes || echo no)"
flags "devnet: a release install at keygen refused" 1 devnet release "" "" ""
flags "devnet: an existing binary at keygen accepted" 0 devnet existing "" "" ""
# _preflight_docker: mainnet (no mainnet release verifies yet) stops before Docker's
# apt repository, the engine or daemon.json is touched; so does devnet without
# --docker-image (it has no signed release to take an image from).
for net in mainnet devnet; do
    rc="$(sn "NETWORK=$net RELEASE_TAG= DOCKER_IMAGE=; command() { return 1; }; _setup_docker_apt() { echo APT_RAN; }; _setup_docker_live_restore() { echo LIVE_RESTORE_RAN; }; _preflight_docker")"
    check "_preflight_docker on $net: refused before apt and daemon.json" "1 no no" \
        "$rc $(grep -q APT_RAN "$T/sn.out" && echo yes || echo no) $(grep -q LIVE_RESTORE_RAN "$T/sn.out" && echo yes || echo no)"
done
rc="$(sn "JSON_MODE=false NETWORK=testnet INSTALL_METHOD=docker RELEASE_TAG=v0.16.0-adiri DOCKER_IMAGE='${R}@sha256:${D64}'; init_install_flags")"
check "interactive: --docker-image and --release-tag together refused" "1 yes" "$rc $(grep -q 'not both' "$T/sn.err" && echo yes || echo no)"
rc="$(sn "NETWORK=devnet RELEASE_TAG=v0.2.0-devnet DOCKER_IMAGE=; command() { return 1; }; _setup_docker_apt() { echo APT_RAN; }; _setup_docker_live_restore() { echo LIVE_RESTORE_RAN; }; _preflight_docker")"
check "_preflight_docker on devnet with a release tag: refused before apt and daemon.json" "1 no no yes" \
    "$rc $(grep -q APT_RAN "$T/sn.out" && echo yes || echo no) $(grep -q LIVE_RESTORE_RAN "$T/sn.out" && echo yes || echo no) $(grep -q 'takes no --release-tag: devnet has no signed releases' "$T/sn.err" && echo yes || echo no)"
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
# The order: the release tag resolved, the image pulled, its digest checked, then
# its build features; a refusal stops setup before BINARY_PATH is set, so no
# container of it starts and .node-meta never names it.
FEAT='tn_docker_image_for_tag() { printf "resolve %s\n" "$2" >> "$T/docker.log"; printf "%s@sha256:%s\n" "$R" "$D64"; }; tn_docker_holds_digest() { echo held >> "$T/docker.log"; [ "$1" = "$DOCKER_IMAGE" ]; }; RELEASE_TAG=v0.17.0-adiri DOCKER_IMAGE='
: > "$T/docker.log"; rm -f "$T/bp"
rc="$(sn "$PD; $FEAT; _preflight_docker; printf '%s' \"\$BINARY_PATH\" > \"\$T/bp\"")"
check "feature check: resolve, pull, digest check, feature check, then setup goes on" \
    "0 docker resolve v0.17.0-adiri|pull ${R}@sha256:${D64}|held|check testnet ${R}@sha256:${D64}" \
    "$rc $(cat "$T/bp" 2>/dev/null) $(tr '\n' '|' < "$T/docker.log" | sed 's/|$//')"
: > "$T/docker.log"; rm -f "$T/bp"
rc="$(sn "$PD; $FEAT; FEAT_RC=1; _preflight_docker; printf '%s' \"\$BINARY_PATH\" > \"\$T/bp\"")"
check "feature check refused: setup stops before BINARY_PATH is set" "1 none" "$rc $(cat "$T/bp" 2>/dev/null || echo none)"
check "feature check refused: the reason says no container started" yes \
    "$(grep -qF "Refusing the image ${R}@sha256:${D64}: it is not a testnet image (see above). No container was started and .node-meta was not written." "$T/sn.err" && echo yes || echo no)"
: > "$T/docker.log"
rc="$(sn "$PD; NETWORK=mainnet; tn_docker_network_ok() { return 0; }; _setup_mainnet_digest_ok() { return 0; }; tn_docker_release_tag_for() { return 1; }; tn_docker_holds_digest() { return 0; }; DOCKER_IMAGE='${MR}@sha256:${D64}'; _preflight_docker")"
check "feature check on mainnet: asked for the mainnet network" "0 yes" \
    "$rc $(grep -qxF "check mainnet ${MR}@sha256:${D64}" "$T/docker.log" && echo yes || echo no)"
unset FEAT
# Devnet by digest: pulled as given, no release tag looked up in a registry.
: > "$T/docker.log"; rm -f "$T/bp" "$T/loud"
rc="$(sn "$PD; NETWORK=devnet DOCKER_IMAGE=\"\${R}@sha256:\${D64}\"; tn_registry_tags() { echo tags > \"\$T/loud\"; return 1; }; tn_registry_digest() { echo digest > \"\$T/loud\"; return 1; }; tn_docker_holds_digest() { [ \"\$1\" = \"\$DOCKER_IMAGE\" ]; }; _preflight_docker; printf '%s %s' \"\$BINARY_PATH\" \"\${RELEASE_TAG:-none}\" > \"\$T/bp\"")"
check "devnet by digest: setup goes on, no release tag recorded" "0 docker none" "$rc $(cat "$T/bp" 2>/dev/null)"
check_has "devnet by digest: the image was pulled by digest" "pull ${R}@sha256:${D64}" "$(cat "$T/docker.log")"
check "devnet by digest: no registry lookup" "no" "$([[ -e "$T/loud" ]] && echo yes || echo no)"

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

# Finalize (--json --phase=finalize) is a new process: the image keygen recorded in
# .node-meta meets the rules keygen's preflight applied (finalize_install_inputs),
# before the config, the unit and the container: a repository a new pull for the
# network takes (the old single package is refused) and the build-feature check.
# The steps after it are logged beside the check: the resolve (the real
# tn_docker_resolve_ref, wrapped), the pull, the digest check, every .node-meta
# write ("record", through tn_write_root_file), the config (which also keeps the
# DOCKER_IMAGE line .node-meta holds at that moment), the unit and the start.
printf 'stored\n' > "$T/root/etc/telcoin/bls-passphrase"
FMETA="$T/root/etc/telcoin/.node-meta"
fin_meta() { printf 'PASSPHRASE_METHOD=stdin\nINSTALL_METHOD=docker\nDOCKER_IMAGE=%s\n' "$1" > "$FMETA"; }
# shellcheck disable=SC2016
FIN_WRAP='eval "$(declare -f tn_docker_resolve_ref | sed "1s/^tn_docker_resolve_ref /real_resolve_ref /")"; tn_docker_resolve_ref() { printf "resolve %s\n" "$2" >> "$T/docker.log"; real_resolve_ref "$@"; }'
# shellcheck disable=SC2016
FIN='CONFIG_DIR="$T/root/etc/telcoin" JSON_MODE=true INSTALL_METHOD= BINARY_PATH=; PRIMARY_LISTENER_MULTIADDR=/ip4/127.0.0.1/udp/49590/quic-v1; WORKER_LISTENER_MULTIADDR=/ip4/127.0.0.1/udp/49594/quic-v1; json_event() { :; }; finalize_node_extra_flags() { :; }; setup_release_lock() { :; }; step_host_baseline() { :; }; docker() { printf "%s\n" "$*" >> "$T/docker.log"; }; tn_docker_holds_digest() { echo held >> "$T/docker.log"; return 0; }; tn_write_root_file() { echo record >> "$T/docker.log"; cat > "$1"; }; step_write_config() { echo config >> "$T/docker.log"; grep "^DOCKER_IMAGE=" "$T/root/etc/telcoin/.node-meta" > "$T/meta-at-config"; }; step_create_service() { echo service >> "$T/docker.log"; }; json_done() { echo done >> "$T/docker.log"; }; '"${FIN_WRAP}"'; json_phase_finalize'
fin_calls() { uniq "$T/docker.log" | tr '\n' '|' | sed 's/|$//'; }
meta_same() { cmp -s "$FMETA" "$T/meta.before" && echo same || echo changed; }
fin_meta "${GH}@sha256:${D64}"
: > "$T/docker.log"
rc="$(sn "NETWORK=testnet; $FIN")"
check "finalize, testnet: a recorded image of the old single package refused before anything" "1 " "$rc $(fin_calls)"
check "finalize: the refusal names the image, the repository and the way out" yes \
    "$(grep -qF "Refusing the image ${GH}@sha256:${D64}: setup runs only ghcr.io/telcoin-association/tn-testnet@sha256:<digest>. No container was started; to replace it, run finalize again with --docker-image ghcr.io/telcoin-association/tn-testnet@sha256:<digest> (a testnet image)." "$T/sn.err" && echo yes || echo no)"
fin_meta "${R}@sha256:${D64}"
: > "$T/docker.log"
rc="$(sn "NETWORK=testnet; $FIN")"
check "finalize, testnet: a good recorded image is checked, then config, unit and start" \
    "0 check testnet ${R}@sha256:${D64}|config|service|done" "$rc $(fin_calls)"
: > "$T/docker.log"
rc="$(sn "NETWORK=testnet; FEAT_RC=1; $FIN")"
check "finalize, the feature check refuses: nothing after it" "1 check testnet ${R}@sha256:${D64}" "$rc $(fin_calls)"
check "finalize, the feature check refuses: no container started, the way out named" yes \
    "$(grep -qF "Refusing the image ${R}@sha256:${D64}: it is not a testnet image (see above). No container was started; to replace it, run finalize again with --docker-image ghcr.io/telcoin-association/tn-testnet@sha256:<digest> (a testnet image)." "$T/sn.err" && echo yes || echo no)"
fin_meta "${GD}@sha256:${D64}"
: > "$T/docker.log"
rc="$(sn "NETWORK=devnet; $FIN")"
check "finalize, devnet: a dev package image is asked for devnet, then config, unit and start" \
    "0 check devnet ${GD}@sha256:${D64}|config|service|done" "$rc $(fin_calls)"
fin_meta "${GH}@sha256:${D64}"
: > "$T/docker.log"
rc="$(sn "NETWORK=devnet; $FIN")"
check "finalize, devnet: the old single package refused before anything" "1 " "$rc $(fin_calls)"
# --docker-image at finalize naming another image than the recorded one replaces it
# through keygen's checks: resolved (the pull rule), pulled by digest, held under it,
# checked for its build features, and only then recorded in .node-meta (image,
# digest, and the release tag removed when none names it), before the config. A
# refusal leaves .node-meta as it was; the recorded image itself is no override.
OV="ghcr.io/telcoin-association/tn-testnet@sha256:$(printf '%s' "$D64" | tr 0 e)"
fin_meta "${GH}@sha256:${D64}"
printf 'DOCKER_IMAGE_DIGEST=sha256:%s\nRELEASE_TAG=v0.16.0-adiri\n' "$D64" >> "$FMETA"
: > "$T/docker.log"; rm -f "$T/meta-at-config"
rc="$(sn "NETWORK=testnet; DOCKER_IMAGE='${OV}'; $FIN")"
check "finalize --docker-image: resolve, pull, digest check, feature check, record, then config, unit and start" \
    "0 resolve ${OV}|pull ${OV}|held|check testnet ${OV}|record|config|service|done" "$rc $(fin_calls)"
check "finalize --docker-image: .node-meta names the new image when the config is written" \
    "DOCKER_IMAGE=${OV}" "$(cat "$T/meta-at-config" 2>/dev/null)"
check_has "finalize --docker-image: the new digest recorded" "DOCKER_IMAGE_DIGEST=${OV##*@}" "$(cat "$FMETA")"
check_lacks "finalize --docker-image: the old release tag removed" "RELEASE_TAG=" "$(cat "$FMETA")"
fin_meta "${R}@sha256:${D64}"
cp "$FMETA" "$T/meta.before"
OLDPKG="${GH}@sha256:$(printf '%s' "$D64" | tr 0 d)"
: > "$T/docker.log"
rc="$(sn "NETWORK=testnet; DOCKER_IMAGE='${OLDPKG}'; $FIN")"
check "finalize --docker-image of the old single package: refused at the resolve, nothing after it" \
    "1 resolve ${OLDPKG}" "$rc $(fin_calls)"
check "finalize --docker-image of the old single package: .node-meta as it was" same "$(meta_same)"
check "finalize --docker-image refused: says .node-meta was not changed" yes \
    "$(grep -qF "Refusing the image ${OLDPKG} given with --docker-image (see above). No container was started and .node-meta was not changed." "$T/sn.err" && echo yes || echo no)"
: > "$T/docker.log"
rc="$(sn "NETWORK=testnet; DOCKER_IMAGE='${OV}'; FEAT_RC=1; $FIN")"
check "finalize --docker-image, the feature check refuses: nothing after it" \
    "1 resolve ${OV}|pull ${OV}|held|check testnet ${OV}" "$rc $(fin_calls)"
check "finalize --docker-image, the feature check refuses: .node-meta as it was" same "$(meta_same)"
check "finalize --docker-image, the feature check refuses: says .node-meta was not changed" yes \
    "$(grep -qF "Refusing the image ${OV}: it is not a testnet image (see above). No container was started and .node-meta was not changed." "$T/sn.err" && echo yes || echo no)"
: > "$T/docker.log"
rc="$(sn "NETWORK=testnet; DOCKER_IMAGE='${R}@sha256:${D64}'; $FIN")"
check "finalize --docker-image equal to the recorded image: no override, as without the flag" \
    "0 check testnet ${R}@sha256:${D64}|config|service|done same" "$rc $(fin_calls) $(meta_same)"
rm -f "$FMETA" "$T/root/etc/telcoin/bls-passphrase" "$T/meta.before" "$T/meta-at-config"
unset -f fin_meta fin_calls meta_same
unset FIN FIN_WRAP FMETA OV OLDPKG

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

# edit-config's Docker image menu on a network without a repository names why.
( set +e
         # shellcheck source=/dev/null
         source "$T/ec/edit-config.sh" >/dev/null 2>&1
         set +e
         read_launch_line() { printf 'exec docker run --rm %s@sha256:%s telcoin node --http\n' "$R" "$D64"; }
         tn_detect_network() { printf 'mainnet\n'; }
         edit_docker_image ) < /dev/null > "$T/ec.out" 2>&1
check "edit menu, mainnet: the reason is named, nothing asked" "yes no" \
    "$(grep -q 'No mainnet release can be verified yet' "$T/ec.out" && echo yes || echo no) $(grep -q 'Release tag or image' "$T/ec.out" && echo yes || echo no)"

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
      tn_docker_image_network_ok() { printf 'check %s %s\n' "$1" "$2" >> "$T/docker.log"; return "${FEAT_RC:-0}"; }
      swap_docker_image() { printf '%s\n' "$1" > "$T/swapped"; printf 'swap %s\n' "$1" >> "$T/docker.log"; }
      meta_set() { printf '%s=%s\n' "$1" "$2" >> "$T/meta.log"; }
      meta_unset() { printf 'unset %s\n' "$1" >> "$T/meta.log"; }
      edit_error() { printf '%s\n' "$*" >&2; }
      edit_step() { :; }
      set_docker_image "$1" ) >/dev/null 2>"$T/ec.err"
    printf '%s' "$?"
}
rm -f "$T/swapped" "$T/meta.log"
: > "$T/docker.log"
rc="$(ec v0.17.0-adiri)"
check "edit: a release tag runs its digest" "0 ${R}@sha256:${D64}" "$rc $(cat "$T/swapped" 2>/dev/null)"
check "edit: .node-meta records image, digest and tag" "DOCKER_IMAGE=${R}@sha256:${D64} DOCKER_IMAGE_DIGEST=sha256:${D64} RELEASE_TAG=v0.17.0-adiri" "$(tr '\n' ' ' < "$T/meta.log" | sed 's/ $//')"
check "edit: pull, feature check, then the swap" "pull ${R}@sha256:${D64}|check testnet ${R}@sha256:${D64}|swap ${R}@sha256:${D64}" \
    "$(tr '\n' '|' < "$T/docker.log" | sed 's/|$//')"
rm -f "$T/swapped" "$T/meta.log"
rc="$(FEAT_RC=1 ec v0.17.0-adiri)"
check "edit: the feature check refuses: nothing swapped, nothing recorded" "1 no no" \
    "$rc $([[ -e "$T/swapped" ]] && echo yes || echo no) $([[ -e "$T/meta.log" ]] && echo yes || echo no)"
check "edit: the refusal says the image is not changed" yes \
    "$(grep -qF "refusing ${R}@sha256:${D64}: it is not a testnet image (see above); the image is not changed" "$T/ec.err" && echo yes || echo no)"
rm -f "$T/swapped" "$T/meta.log"
rc="$(ec "${R}:latest")"
check "edit: latest refused, nothing swapped" "1 no" "$rc $([[ -e "$T/swapped" ]] && echo yes || echo no)"
rc="$(ec "docker.io/library/busybox@sha256:${D64}")"
check "edit: another repository refused" "1 no" "$rc $([[ -e "$T/swapped" ]] && echo yes || echo no)"
rc="$(ec "${GD}@sha256:${D64}")"
check "edit: the dev package refused on testnet" "1 no" "$rc $([[ -e "$T/swapped" ]] && echo yes || echo no)"
rm -f "$T/meta.log"
rc="$(ec "${R}@sha256:$(printf '%s' "$D64" | tr 0 a)")"
check "edit: a digest alone runs as given, tag removed from .node-meta" "0 yes" "$rc $(grep -qx 'unset RELEASE_TAG' "$T/meta.log" && echo yes || echo no)"
rc="$( ( set +e; source "$T/ec/edit-config.sh" >/dev/null 2>&1; set +e; edit_error() { :; }; launch_current_form() { echo called > "$T/lcf"; }; swap_docker_image "${R}:v0.16.0-adiri" ) >/dev/null 2>&1; printf '%s' "$?")"
check "edit: swap_docker_image refuses a tag before touching anything" "1 no" "$rc $([[ -e "$T/lcf" ]] && echo yes || echo no)"

# The interactive image menu (edit_docker_image) on testnet: the release tag typed
# at the prompt resolves to its digest, the image is pulled and held under it, its
# build features are checked, and only then is the menu locked, the start script
# swapped and the image recorded (edit_record_image, through meta_set). A refusal
# leaves all three alone.
ecm() {
    ( set +e
      # shellcheck source=/dev/null
      source "$T/ec/edit-config.sh" >/dev/null 2>&1
      set +e
      TARGET_LAUNCH_FILE="$T/tn-start-docker"
      tn_detect_network() { printf 'testnet\n'; }
      read_launch_line() { printf 'exec docker run --rm %s@sha256:%s telcoin node --http\n' "$R" "$(printf '%s' "$D64" | tr 0 b)"; }
      tn_docker_image_for_tag() { printf '%s@sha256:%s\n' "$R" "$D64"; }
      docker() { printf '%s\n' "$*" >> "$T/docker.log"; }
      tn_docker_holds_digest() { echo held >> "$T/docker.log"; return 0; }
      tn_docker_image_network_ok() { printf 'check %s %s\n' "$1" "$2" >> "$T/docker.log"; return "${FEAT_RC:-0}"; }
      menu_lock() { echo lock >> "$T/docker.log"; }
      backup_edit_targets() { echo backup >> "$T/docker.log"; }
      swap_docker_image() { printf 'swap %s\n' "$1" >> "$T/docker.log"; }
      meta_set() { printf '%s=%s\n' "$1" "$2" >> "$T/meta.log"; }
      meta_unset() { printf 'unset %s\n' "$1" >> "$T/meta.log"; }
      apply_changes() { echo apply >> "$T/docker.log"; }
      edit_docker_image ) <<< "$1" > "$T/ec.out" 2>&1
}
calls() { tr '\n' '|' < "$T/docker.log" | sed 's/|$//'; }
rm -f "$T/meta.log"
: > "$T/docker.log"
ecm v0.17.0-adiri
check "edit menu: pull, digest check, feature check, then lock, swap and apply" \
    "pull ${R}@sha256:${D64}|held|check testnet ${R}@sha256:${D64}|lock|backup|swap ${R}@sha256:${D64}|apply" "$(calls)"
check "edit menu: .node-meta records image, digest and tag" \
    "DOCKER_IMAGE=${R}@sha256:${D64} DOCKER_IMAGE_DIGEST=sha256:${D64} RELEASE_TAG=v0.17.0-adiri" "$(tr '\n' ' ' < "$T/meta.log" 2>/dev/null | sed 's/ $//')"
rm -f "$T/meta.log"
: > "$T/docker.log"
FEAT_RC=1 ecm v0.17.0-adiri
check "edit menu, the feature check refuses: nothing after the check" \
    "pull ${R}@sha256:${D64}|held|check testnet ${R}@sha256:${D64}" "$(calls)"
check "edit menu, the feature check refuses: .node-meta untouched" no "$([[ -e "$T/meta.log" ]] && echo yes || echo no)"
check "edit menu, the feature check refuses: the image is not changed" yes \
    "$(grep -qF "Refusing ${R}@sha256:${D64}: it is not a testnet image (see above). The image is not changed." "$T/ec.out" && echo yes || echo no)"
unset -f ecm calls

# edit-config on a devnet host: tn_detect_network names no network and .node-meta
# says NETWORK=devnet (_tn_guard_network). Images by digest only, from the devnet
# repository (the old single ghcr package is never pulled); a devnet tag names no image (the real
# tn_docker_image_for_tag refuses it before any release is fetched).
ecd() {
    ( set +e
      # shellcheck source=/dev/null
      source "$T/ec/edit-config.sh" >/dev/null 2>&1
      set +e
      TARGET_LAUNCH_FILE="$T/tn-start-docker"
      tn_detect_network() { return 1; }
      meta_get() { [ "$1" = NETWORK ] && [ -n "$ECD_META" ] && printf '%s\n' "$ECD_META"; }
      read_launch_line() { printf 'exec docker run --rm %s@sha256:%s telcoin node --http\n' "$R" "$(printf '%s' "$D64" | tr 0 b)"; }
      edit_launch_unambiguous() { return 0; }
      tn_fetch_release_image() { echo fetched > "$T/fetched"; return 1; }
      tn_docker_holds_digest() { return 0; }
      docker() { printf '%s\n' "$*" >> "$T/docker.log"; }
      tn_docker_image_network_ok() { printf 'check %s %s\n' "$1" "$2" >> "$T/docker.log"; return "${FEAT_RC:-0}"; }
      swap_docker_image() { printf '%s\n' "$1" > "$T/swapped"; }
      meta_set() { printf '%s=%s\n' "$1" "$2" >> "$T/meta.log"; }
      meta_unset() { printf 'unset %s\n' "$1" >> "$T/meta.log"; }
      edit_error() { printf '%s\n' "$*" >&2; }
      edit_step() { :; }
      set_docker_image "$1" ) >/dev/null 2>"$T/ec.err"
    printf '%s' "$?"
}
swapped() { [[ -e "$T/swapped" ]] && cat "$T/swapped" || echo none; }
ECD_META=devnet
rm -f "$T/swapped" "$T/meta.log" "$T/fetched"
: > "$T/docker.log"
rc="$(ecd "${R}@sha256:${D64}")"
check "edit, devnet: a legacy-repository digest runs as given" "0 ${R}@sha256:${D64}" "$rc $(swapped)"
check_has "edit, devnet: the feature check is asked for devnet (which skips it)" "check devnet ${R}@sha256:${D64}" "$(cat "$T/docker.log")"
check "edit, devnet: .node-meta records image and digest, no tag" "DOCKER_IMAGE=${R}@sha256:${D64} DOCKER_IMAGE_DIGEST=sha256:${D64} unset RELEASE_TAG" "$(tr '\n' ' ' < "$T/meta.log" | sed 's/ $//')"
rm -f "$T/swapped" "$T/meta.log"
rc="$(ecd "${GD}@sha256:${D64}")"
check "edit, devnet: a dev package digest runs as given" "0 ${GD}@sha256:${D64}" "$rc $(swapped)"
for bad in v0.2.0-devnet "${R}:v0.2.0-devnet" v0.16.0-adiri "${R}:main-0123abc" "docker.io/library/busybox@sha256:${D64}" "${R}:latest" "${GH}@sha256:${D64}"; do
    rm -f "$T/swapped"
    rc="$(ecd "$bad")"
    check "edit, devnet: ${bad} refused, nothing swapped" "1 none yes" "$rc $(swapped) $(grep -q 'give a devnet image by digest' "$T/ec.err" && echo yes || echo no)"
done
check "edit, devnet: no release fetched for a devnet tag" "no" "$([[ -e "$T/fetched" ]] && echo yes || echo no)"
ECD_META=""
rm -f "$T/swapped"
rc="$(ecd "${GH}@sha256:${D64}")"
check "edit, network unknown: refused, nothing swapped" "1 none yes" "$rc $(swapped) $(grep -q 'cannot tell which network' "$T/ec.err" && echo yes || echo no)"
ECD_META=testnet
rc="$(ecd "${GH}@sha256:${D64}")"
check "edit, .node-meta says testnet but detection fails: refused" "1 none" "$rc $(swapped)"
# swap_docker_image itself (no network given): the devnet digest passes its check
# and reaches the rewrite; with the network unknown it stops before it.
swap_probe() {
    rm -f "$T/lcf"
    ( set +e; source "$T/ec/edit-config.sh" >/dev/null 2>&1; set +e
      tn_detect_network() { return 1; }
      meta_get() { [ "$1" = NETWORK ] && [ -n "$ECD_META" ] && printf '%s\n' "$ECD_META"; }
      edit_error() { :; }; launch_current_form() { echo called > "$T/lcf"; return 1; }
      swap_docker_image "$1" ) >/dev/null 2>&1
    printf '%s %s' "$?" "$([[ -e "$T/lcf" ]] && echo yes || echo no)"
}
ECD_META=devnet
check "swap, devnet: a digest of the old single ghcr package (recognised) reaches the rewrite" "1 yes" "$(swap_probe "${GH}@sha256:${D64}")"
check "swap, devnet: another repository stops before it" "1 no" "$(swap_probe "docker.io/library/busybox@sha256:${D64}")"
ECD_META=""
check "swap, network unknown: stops before the rewrite" "1 no" "$(swap_probe "${GH}@sha256:${D64}")"
# The interactive image menu on devnet asks for a digest, never a release tag.
( set +e
         # shellcheck source=/dev/null
         source "$T/ec/edit-config.sh" >/dev/null 2>&1
         set +e
         read_launch_line() { printf 'exec docker run --rm %s@sha256:%s telcoin node --http\n' "$R" "$D64"; }
         tn_detect_network() { return 1; }
         meta_get() { [ "$1" = NETWORK ] && printf 'devnet\n'; }
         edit_docker_image ) < /dev/null > "$T/ec.out" 2>&1
check "edit menu, devnet: asks for the image by digest, not a release tag" "yes no" \
    "$(grep -q 'Enter the devnet image by digest' "$T/ec.out" && echo yes || echo no) $(grep -q 'release tag (such as' "$T/ec.out" && echo yes || echo no)"
unset ECD_META
finish
