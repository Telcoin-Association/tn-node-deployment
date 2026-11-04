#!/usr/bin/env bash
# X2: cmd_draft (CI) on a draft that already holds an IMAGE_DIGEST. The claim under test: draft
# fails, before it renders or edits the body, when that IMAGE_DIGEST names another package or
# is malformed, where it used to drop the digest from the body silently. The right package
# keeps its digest in the body.
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# drf TAG [VAR=value...]
drf() {
    local tag=$1
    shift
    env -u RELEASE_REPO -u RELEASE_DRY_RUN -u RELEASE_IMAGE GITHUB_ACTIONS=true \
        GITHUB_REPOSITORY=Telcoin-Association/telcoin-network "$@" bash "$V8_DIR/drive.sh" draft "$tag"
}
G=ghcr.io/telcoin-association
DG=sha256:$(printf '%064d' 0 | tr 0 a)
for spec in "v0.1.0 mainnet tn-mainnet tn-testnet" "v0.17.0-adiri adiri tn-testnet tn-mainnet"; do
    set -- $spec
    tag=$1 ch=$2 own=$G/$3 other=$G/$4
    n=draft-$tag
    expect "$n-right" 0 "render_notes digest=[$DG]" -- drf "$tag"
    expect "$n-right-edits" 0 "gh release edit $tag --repo Telcoin-Association/telcoin-network --notes-file" -- drf "$tag"
    expect "$n-other" 1 "IMAGE_DIGEST names an image in $other, but $tag is on the $ch channel, whose images are published only in $own; rebuild the draft with make release-build TAG=$tag" \
        "render_notes" -- drf "$tag" IDG="$other@@D@"
    expect "$n-other-no-edit" 1 "::error::IMAGE_DIGEST names an image in $other" "gh release edit" -- drf "$tag" IDG="$other@@D@"
    expect "$n-old-package" 1 "names an image in $G/telcoin-network" "render_notes" -- drf "$tag" IDG="$G/telcoin-network@@D@"
    expect "$n-tag-ref" 1 "not an image by digest" "render_notes" -- drf "$tag" IDG="@SELF@:$tag"
    expect "$n-empty" 1 "names '', not an image by digest" "render_notes" -- drf "$tag" IDG=""
    expect "$n-two-lines" 1 "IMAGE_DIGEST must be a single line" "render_notes" -- drf "$tag" IDG="@SELF@@@D@\n@SELF@@@D@"
    # Right package, malformed digest: the claim says draft fails; these assert that claim.
    expect "$n-bad-digest-fails" 1 "malformed" "render_notes" -- drf "$tag" IDG="@SELF@@sha256:XYZ"
    expect "$n-crlf-fails" 1 "malformed" "render_notes" -- drf "$tag" IDG="@SELF@@@D@\r"
    expect "$n-empty-digest-fails" 1 "malformed" "render_notes" -- drf "$tag" IDG="@SELF@@"
done
summary tx2_draft
