#!/usr/bin/env bash
# X1: the first-push path in cmd_build, and check_version_output before the push on both
# channels. The real registry_digest runs with curl stubbed (regreal); then the real cmd_build
# runs with git, docker, gh and the registry stubbed (build), the real confirm,
# image_binary, check_version_output, tar and write_sums included.
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
clean() { env -u RELEASE_REPO -u GITHUB_ACTIONS -u RELEASE_DRY_RUN -u RELEASE_IMAGE -u RELEASE_YES -u RELEASE_REBUILD "$@"; }
reg() { clean "$@" bash "$V8_DIR/drive.sh" regreal v0.1.0; }
# bld TAG [VAR=value...]
bld() {
    local tag=$1
    shift
    clean "$@" bash "$V8_DIR/drive.sh" build "$tag"
}
# before NAME A B: in the output of case NAME, the first line holding A comes before the first
# line holding B, and both exist.
before() {
    expect "$1-order" 0 "" -- awk -v a="$2" -v b="$3" \
        'index($0, a) && !ia { ia = NR } index($0, b) && !ib { ib = NR } END { exit !(ia && ib && ia < ib) }' "$OUT/$1.txt"
}
G=ghcr.io/telcoin-association
DG=sha256:$(printf '%064d' 0 | tr 0 a)

# The real registry_digest.
expect reg-403-first-push 0 "printed [denied]" -- reg MODE=first-push MANIFEST_CODE=403
expect reg-401-first-push 0 "printed [denied]" -- reg MODE=first-push MANIFEST_CODE=401
expect reg-token-403-first-push 0 "printed [denied]" -- reg MODE=first-push TOKEN_CODE=403
expect reg-403-plain 2 "answered HTTP 403: package is not public, or has never been pushed" -- reg MANIFEST_CODE=403
expect reg-404-first-push 0 "printed []" -- reg MODE=first-push MANIFEST_CODE=404
expect reg-200-first-push 0 "printed [$DG]" -- reg MODE=first-push MANIFEST_CODE=200
expect reg-500-first-push 3 "registry unavailable after 3 attempts (last answer: 500)" "denied" -- reg MODE=first-push MANIFEST_CODE=500
expect reg-curlfail-first-push 3 "registry unavailable after 3 attempts (last answer: 000)" "denied" -- reg MODE=first-push TOKEN_CODE=fail
expect reg-other-mode-403 2 "package is not public" -- reg MODE=First-Push MANIFEST_CODE=403

for spec in "v0.1.0 tn-mainnet CARGO_FEATURES= adiri" "v0.17.0-adiri tn-testnet CARGO_FEATURES=adiri none"; do
    set -- $spec
    tag=$1 pkg=$2 feat=$3 badfeat=$4
    img=$G/$pkg
    if [ "$badfeat" = none ]; then badfeat=; fi
    n=build-$tag
    # First push, nobody to answer the prompt: stops before anything is built or pushed.
    expect "$n-fp-no-tty" 2 "confirmation needed but stdin is not a TTY" "docker push" -- bld "$tag" REG_SEQ=denied
    expect "$n-fp-no-tty-no-build" 2 "warning: $img does not answer an anonymous read" "docker buildx build" -- bld "$tag" REG_SEQ=denied
    # First push answered: builds with the channel's features, checks --version, pushes to the
    # channel's package, then stops with exit 2 before IMAGE_DIGEST, SHA256SUMS or any upload.
    expect "$n-fp-yes" 2 "$img:$tag is pushed, but the package is not public: do its one-time setup (maintainer guide), then run make release-build TAG=$tag again with RELEASE_REBUILD=1" \
        "release_upload" -- bld "$tag" RELEASE_YES=1 REG_SEQ=denied,denied
    expect "$n-fp-yes-push-target" 2 "docker push $img:$tag" -- bld "$tag" RELEASE_YES=1 REG_SEQ=denied,denied
    expect "$n-fp-yes-features" 2 "--build-arg $feat --build-arg" -- bld "$tag" RELEASE_YES=1 REG_SEQ=denied,denied
    expect "$n-fp-yes-no-digest-file" 2 "local artifacts: telcoin-network-$tag" "IMAGE_DIGEST=" -- bld "$tag" RELEASE_YES=1 REG_SEQ=denied,denied
    expect "$n-fp-yes-no-verify" 2 "--- calls" "cmd_verify" -- bld "$tag" RELEASE_YES=1 REG_SEQ=denied,denied
    before "$n-fp-yes" "docker run --rm --network none" "docker push"
    # The version and feature check gates the push on the first-push path as on the normal one.
    expect "$n-fp-badfeat" 1 "" "docker push" -- bld "$tag" RELEASE_YES=1 REG_SEQ=denied,denied OUT_FEATURES="$badfeat"
    expect "$n-normal-badfeat" 1 "" "docker push" -- bld "$tag" REG_SEQ=none,D OUT_FEATURES="$badfeat"
    # Normal first build into a public package.
    expect "$n-normal" 0 "IMAGE_DIGEST=$img@$DG" -- bld "$tag" REG_SEQ=none,D
    expect "$n-normal-verify" 0 "cmd_verify 1" -- bld "$tag" REG_SEQ=none,D
    before "$n-normal" "docker run --rm --network none" "docker push"
    before "$n-normal-verify" "docker push $img:$tag" "release_upload"
    # The rerun after the one-time setup: the tag is now served.
    expect "$n-rerun-no-rebuild" 1 "$img:$tag already exists ($DG); set RELEASE_REBUILD=1 to rebuild it" "docker buildx build" -- bld "$tag" REG_SEQ=D
    expect "$n-rerun-rebuild" 0 "IMAGE_DIGEST=$img@$DG" -- bld "$tag" RELEASE_REBUILD=1 REG_SEQ=D,D
    # A private package that already holds the tag looks the same as a never-pushed one: with
    # RELEASE_YES=1 build rebuilds and pushes over :TAG without RELEASE_REBUILD=1.
    expect "$n-private-existing-overwritten" 2 "docker push $img:$tag" "already exists" -- bld "$tag" RELEASE_YES=1 REG_SEQ=denied,denied
    # Denied only after the push, 404 after the push, another digest after the push.
    expect "$n-post-denied" 2 "is pushed, but the package is not public" "release_upload" -- bld "$tag" REG_SEQ=none,denied
    expect "$n-post-missing" 1 "the registry has no $img:$tag after the push" "release_upload" -- bld "$tag" REG_SEQ=none,none
    expect "$n-post-other" 1 "which is not the image just built" "release_upload" -- \
        bld "$tag" REG_SEQ="none,sha256:$(printf '%064d' 0 | tr 0 c)"
    # Preconditions still stop before the registry is asked.
    expect "$n-published" 1 "release $tag is already published" "registry_digest" -- bld "$tag" REL_DRAFT_X=false REG_SEQ=denied
    expect "$n-signed" 1 "already carries SHA256SUMS.asc" "registry_digest" -- bld "$tag" REL_ASSETS_X=SHA256SUMS.asc REG_SEQ=denied
done
grep -E '^(error|warning):' "$OUT/build-v0.1.0-fp-yes.txt" | tee "$OUT/tx1-first-push-messages.txt"
summary tx1_build
