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

for spec in "v0.1.0 mainnet tn-mainnet tn-testnet CARGO_FEATURES= adiri" "v0.17.0-adiri adiri tn-testnet tn-mainnet CARGO_FEATURES=adiri none"; do
    set -- $spec
    tag=$1 ch=$2 pkg=$3 otherpkg=$4 feat=$5 badfeat=$6
    img=$G/$pkg
    if [ "$badfeat" = none ]; then badfeat=; fi
    n=build-$tag
    ask="$img refuses anonymous reads and the docker login does not see $img:$tag: if this is the first release image of the package $pkg, run again with RELEASE_FIRST_PUSH=$pkg; otherwise make the package public (maintainer guide, one-time setup)"
    stop="$img:$tag is pushed, but the package is not public: do its one-time setup (maintainer guide), then run make release-build TAG=$tag again with RELEASE_REBUILD=1"

    # Denied, and the login does not see the tag: a first push only with RELEASE_FIRST_PUSH=PACKAGE.
    expect "$n-fp-unset" 2 "$ask" "docker buildx build" -- bld "$tag" REG_SEQ=denied
    expect "$n-fp-unset-login-asked" 2 "docker buildx imagetools inspect $img:$tag --format" -- bld "$tag" REG_SEQ=denied
    expect "$n-fp-unset-login-reason" 2 "with the docker login, $img:$tag does not resolve: ERROR: $img:$tag: not found" -- bld "$tag" REG_SEQ=denied
    expect "$n-fp-yes-only" 2 "$ask" "docker buildx build" -- bld "$tag" RELEASE_YES=1 REG_SEQ=denied
    expect "$n-fp-yes-only-no-prompt" 2 "$ask" "continuing without a prompt" -- bld "$tag" RELEASE_YES=1 REG_SEQ=denied
    expect "$n-fp-yes-rebuild" 2 "$ask" "docker buildx build" -- bld "$tag" RELEASE_YES=1 RELEASE_REBUILD=1 REG_SEQ=denied
    expect "$n-fp-other-package" 2 "RELEASE_FIRST_PUSH is $otherpkg, but $tag is on the $ch channel, whose package is $pkg" "docker buildx build" -- \
        bld "$tag" RELEASE_FIRST_PUSH="$otherpkg" REG_SEQ=denied
    expect "$n-fp-full-image" 2 "RELEASE_FIRST_PUSH is $img, but" "docker buildx build" -- bld "$tag" RELEASE_FIRST_PUSH="$img" REG_SEQ=denied
    expect "$n-fp-upper" 2 "but $tag is on the $ch channel, whose package is $pkg" "docker buildx build" -- \
        bld "$tag" RELEASE_FIRST_PUSH="$(printf '%s' "$pkg" | tr '[:lower:]' '[:upper:]')" REG_SEQ=denied
    expect "$n-fp-one" 2 "RELEASE_FIRST_PUSH is 1, but" "docker buildx build" -- bld "$tag" RELEASE_FIRST_PUSH=1 REG_SEQ=denied
    # The matching value: builds with the channel's features, checks --version, pushes to the
    # channel's package, then stops with exit 2 before IMAGE_DIGEST, SHA256SUMS or any upload.
    expect "$n-fp" 2 "$stop" "release_upload" -- bld "$tag" RELEASE_FIRST_PUSH="$pkg" REG_SEQ=denied,denied
    expect "$n-fp-warn" 2 "warning: RELEASE_FIRST_PUSH=$pkg: pushing $img:$tag as the first image of the package; build stops after the push until the package is public" -- \
        bld "$tag" RELEASE_FIRST_PUSH="$pkg" REG_SEQ=denied,denied
    expect "$n-fp-push-target" 2 "docker push $img:$tag" -- bld "$tag" RELEASE_FIRST_PUSH="$pkg" REG_SEQ=denied,denied
    expect "$n-fp-features" 2 "--build-arg $feat --build-arg" -- bld "$tag" RELEASE_FIRST_PUSH="$pkg" REG_SEQ=denied,denied
    expect "$n-fp-no-digest-file" 2 "local artifacts: telcoin-network-$tag" "IMAGE_DIGEST=" -- bld "$tag" RELEASE_FIRST_PUSH="$pkg" REG_SEQ=denied,denied
    expect "$n-fp-no-verify" 2 "--- calls" "cmd_verify" -- bld "$tag" RELEASE_FIRST_PUSH="$pkg" REG_SEQ=denied,denied
    before "$n-fp" "docker run --rm --network none" "docker push"
    expect "$n-fp-with-yes" 2 "$stop" "release_upload" -- bld "$tag" RELEASE_YES=1 RELEASE_FIRST_PUSH="$pkg" REG_SEQ=denied,denied
    expect "$n-fp-badfeat" 1 "" "docker push" -- bld "$tag" RELEASE_FIRST_PUSH="$pkg" REG_SEQ=denied,denied OUT_FEATURES="$badfeat"
    # Any failed inspect counts as "the login does not see the tag" (N16).
    expect "$n-fp-login-error-unset" 2 "$ask" "docker buildx build" -- bld "$tag" LOGIN=error REG_SEQ=denied
    expect "$n-fp-login-error-pushes" 2 "docker push $img:$tag" -- bld "$tag" LOGIN=error RELEASE_FIRST_PUSH="$pkg" REG_SEQ=denied,denied

    # Denied, and the login sees the tag: private, not new; the RELEASE_REBUILD rule applies.
    private="warning: $img is private, not new: it refuses anonymous reads, but the docker login sees $img:$tag at $DG; make the package public as the maintainer guide's one-time setup says"
    exists="$img:$tag already exists ($DG); set RELEASE_REBUILD=1 to rebuild it"
    expect "$n-private" 1 "$exists" "docker buildx build" -- bld "$tag" LOGIN=D REG_SEQ=denied
    expect "$n-private-warn" 1 "$private" -- bld "$tag" LOGIN=D REG_SEQ=denied
    expect "$n-private-yes-fp" 1 "$exists" "docker buildx build" -- bld "$tag" LOGIN=D RELEASE_YES=1 RELEASE_FIRST_PUSH="$pkg" REG_SEQ=denied
    expect "$n-private-rebuild" 2 "$stop" "release_upload" -- bld "$tag" LOGIN=D RELEASE_REBUILD=1 REG_SEQ=denied,denied
    expect "$n-private-rebuild-builds" 2 "docker buildx build" -- bld "$tag" LOGIN=D RELEASE_REBUILD=1 REG_SEQ=denied,denied
    # An inspect that answers without a digest stops with exit 1.
    expect "$n-login-nodigest" 1 "docker buildx imagetools inspect $img:$tag answered without a digest" "docker buildx build" -- \
        bld "$tag" LOGIN=nodigest RELEASE_FIRST_PUSH="$pkg" REG_SEQ=denied
    expect "$n-login-bad-digest" 1 "answered without a digest: sha256:XYZ" "docker buildx build" -- bld "$tag" LOGIN=sha256:XYZ REG_SEQ=denied
    expect "$n-login-d-then-warning" 1 "answered without a digest" "docker buildx build" -- bld "$tag" LOGIN=d-then-warning REG_SEQ=denied

    # The public paths never ask the login, and RELEASE_FIRST_PUSH changes nothing on them.
    expect "$n-normal" 0 "IMAGE_DIGEST=$img@$DG" "imagetools inspect" -- bld "$tag" REG_SEQ=none,D
    expect "$n-normal-fp-ignored" 0 "IMAGE_DIGEST=$img@$DG" "first image" -- bld "$tag" RELEASE_FIRST_PUSH="$pkg" REG_SEQ=none,D
    expect "$n-normal-verify" 0 "cmd_verify 1" -- bld "$tag" REG_SEQ=none,D
    before "$n-normal" "docker run --rm --network none" "docker push"
    before "$n-normal-verify" "docker push $img:$tag" "release_upload"
    expect "$n-normal-badfeat" 1 "" "docker push" -- bld "$tag" REG_SEQ=none,D OUT_FEATURES="$badfeat"
    expect "$n-rerun-no-rebuild" 1 "$exists" "docker buildx build" -- bld "$tag" REG_SEQ=D
    expect "$n-rerun-fp-no-rebuild" 1 "$exists" "docker buildx build" -- bld "$tag" RELEASE_FIRST_PUSH="$pkg" REG_SEQ=D
    expect "$n-rerun-rebuild" 0 "IMAGE_DIGEST=$img@$DG" -- bld "$tag" RELEASE_REBUILD=1 REG_SEQ=D,D
    expect "$n-post-denied" 2 "$stop" "release_upload" -- bld "$tag" REG_SEQ=none,denied
    expect "$n-post-missing" 1 "the registry has no $img:$tag after the push" "release_upload" -- bld "$tag" REG_SEQ=none,none
    expect "$n-post-other" 1 "which is not the image just built" "release_upload" -- \
        bld "$tag" REG_SEQ="none,sha256:$(printf '%064d' 0 | tr 0 c)"
    expect "$n-published" 1 "release $tag is already published" "registry_digest" -- bld "$tag" REL_DRAFT_X=false REG_SEQ=denied
    expect "$n-signed" 1 "already carries SHA256SUMS.asc" "registry_digest" -- bld "$tag" REL_ASSETS_X=SHA256SUMS.asc REG_SEQ=denied
done
for f in build-v0.1.0-fp-badfeat build-v0.17.0-adiri-fp-badfeat build-v0.1.0-normal-badfeat build-v0.17.0-adiri-normal-badfeat; do
    expect "$f-is-feature-refusal" 0 "Build Features" -- grep -E '^error: .*(cargo features|without the adiri feature)' "$OUT/$f.txt"
done
grep -h -E '^(error|warning):' "$OUT/build-v0.1.0-fp-unset.txt" "$OUT/build-v0.1.0-fp.txt" "$OUT/build-v0.1.0-private-warn.txt" "$OUT/build-v0.1.0-fp-other-package.txt" | tee "$OUT/tx1-first-push-messages.txt"
summary tx1_build
