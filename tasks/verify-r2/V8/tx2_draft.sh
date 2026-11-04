#!/usr/bin/env bash
# X2 / W1: cmd_draft (CI) on a draft that already holds an IMAGE_DIGEST. Draft must stop, before
# it renders or edits the body, on an IMAGE_DIGEST that is not the one line
# "<IMAGE>@sha256:<64 hex>" in the tag's package (another package, no "@", several lines, a
# malformed digest, a trailing CR, an empty digest), with the one refusal shape; the right
# package keeps its digest in the body.
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
    shape="but $tag is on the $ch channel, whose images are published only in $own (expected the one line $own@sha256:<64 hex>); rebuild the draft with make release-build TAG=$tag, or report it if the release is published"
    expect "$n-right" 0 "render_notes digest=[$DG]" -- drf "$tag"
    expect "$n-right-edits" 0 "gh release edit $tag --repo Telcoin-Association/telcoin-network --notes-file" -- drf "$tag"
    expect "$n-right-no-final-newline" 0 "render_notes digest=[$DG]" -- drf "$tag" IDG_RAW=1
    # stops NAME PROBLEM VAR=value...: exit 1 with the shape, ::error:: in CI, no render, no edit.
    stops() {
        local name=$1 problem=$2
        shift 2
        expect "$n-$name" 1 "IMAGE_DIGEST $problem, $shape" "render_notes" -- drf "$tag" "$@"
        expect "$n-$name-ci" 1 "::error::IMAGE_DIGEST $problem" "gh release edit" -- drf "$tag" "$@"
    }
    stops other "names an image in $other" IDG="$other@@D@"
    stops old-package "names an image in $G/telcoin-network" IDG="$G/telcoin-network@@D@"
    stops tag-ref "names '$own:$tag', which is not an image by digest" IDG="@SELF@:$tag"
    stops empty-line "names '', which is not an image by digest" IDG=""
    stops zero-bytes "holds 0 lines" IDG="" IDG_RAW=1
    stops two-lines "holds 2 lines" IDG="@SELF@@@D@\n@SELF@@@D@"
    # The W1 cases of the first round (exit 0 with the digest dropped at 0ba57016d).
    stops bad-digest "names $own with the malformed digest 'sha256:XYZ'" IDG="@SELF@@sha256:XYZ"
    stops crlf "names $own with the malformed digest '$DG?'" IDG="@SELF@@@D@\r"
    stops empty-digest "names $own with the malformed digest ''" IDG="@SELF@@"
done
summary tx2_draft
