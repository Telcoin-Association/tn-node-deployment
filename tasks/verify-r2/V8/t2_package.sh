#!/usr/bin/env bash
# Check 2 (and W1/N3 at 57b8ec90a): the sign-time and verify-time package checks, sourced from
# etc/release.sh through drive.sh. check_digest_package now reads the IMAGE_DIGEST file and
# every refusal has one shape:
#   IMAGE_DIGEST <problem>, but <TAG> is on the <channel> channel, whose images are published
#   only in <IMAGE> (expected the one line <IMAGE>@sha256:<64 hex>); <advice>
# Exercised through check_sums_package (sign, verify), check_image_digest_file (build's
# self-check, sign, verify, publish) and cmd_sign/cmd_verify with the I/O stubbed.
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
drv() { env -u RELEASE_REPO -u GITHUB_ACTIONS -u RELEASE_YES "$@"; }

G=ghcr.io/telcoin-association
DG=sha256:$(printf '%064d' 0 | tr 0 a)
UPPER=sha256:$(printf '%064d' 0 | tr 0 A)

for spec in "v0.1.0 mainnet tn-mainnet tn-testnet" "v0.17.0-adiri adiri tn-testnet tn-mainnet"; do
    set -- $spec
    tag=$1 ch=$2 pkg=$3 own=$G/$3 other=$G/$4
    shape="but $tag is on the $ch channel, whose images are published only in $own (expected the one line $own@sha256:<64 hex>)"
    dflt="$shape; rebuild the draft with make release-build TAG=$tag, or report it if the release is published"
    # refuses NAME PROBLEM VAR=value...: both check functions refuse with the full shape.
    refuses() {
        local name=$1 problem=$2 fn
        shift 2
        for fn in sums file; do
            expect "$fn-$tag-$name" 1 "IMAGE_DIGEST $problem, $dflt" -- drv "$@" bash "$V8_DIR/drive.sh" "$fn" "$tag"
        done
    }
    passes() {
        local name=$1 fn
        shift
        for fn in sums file; do
            expect "$fn-$tag-$name" 0 "PASSED" -- drv "$@" bash "$V8_DIR/drive.sh" "$fn" "$tag"
        done
    }
    passes right
    passes right-no-final-newline IDG_RAW=1
    refuses other-network "names an image in $other" IDG="$other@@D@"
    refuses old-package "names an image in $G/telcoin-network" IDG="$G/telcoin-network@@D@"
    refuses other-owner "names an image in ghcr.io/evil/$pkg" IDG="ghcr.io/evil/$pkg@@D@"
    refuses uppercase-host "names an image in GHCR.IO/telcoin-association/$pkg" IDG="GHCR.IO/telcoin-association/$pkg@@D@"
    refuses leading-space "names an image in  $own" IDG=" @SELF@@@D@"
    refuses tag-ref "names '$own:$tag', which is not an image by digest" IDG="@SELF@:$tag"
    refuses tag-and-digest "names an image in $own:$tag" IDG="@SELF@:$tag@@D@"
    refuses empty-line "names '', which is not an image by digest" IDG=""
    refuses zero-bytes "holds 0 lines" IDG="" IDG_RAW=1
    refuses two-lines "holds 2 lines" IDG="@SELF@@@D@\n@SELF@@@D@"
    refuses two-lines-other "holds 2 lines" IDG="@SELF@@@D@\n$other@@D@"
    refuses trailing-blank "holds 2 lines" IDG="@SELF@@@D@\n"
    refuses bad-digest "names $own with the malformed digest 'sha256:XYZ'" IDG="@SELF@@sha256:XYZ"
    refuses crlf "names $own with the malformed digest '$DG?'" IDG="@SELF@@@D@\r"
    refuses empty-digest "names $own with the malformed digest ''" IDG="@SELF@@"
    refuses upper-hex "names $own with the malformed digest '$UPPER'" IDG="@SELF@@$UPPER"
    refuses sha512 "names $own with the malformed digest 'sha512:$(printf '%0128d' 0)'" IDG="@SELF@@sha512:$(printf '%0128d' 0)"
    refuses extra-at "names $own with the malformed digest '$DG@x'" IDG="@SELF@@@D@@x"
    refuses trailing-space "names $own with the malformed digest '$DG '" IDG="@SELF@@@D@ "
    # A NUL byte: bash drops it in $(cat), so the line reads as the right one (N14).
    expect "file-$tag-nul-byte-accepted" 0 "PASSED" -- drv IDG="@SELF@@@D@\0" bash "$V8_DIR/drive.sh" file "$tag"

    expect "file-$tag-registry-differs" 1 "but the registry serves $own:$tag as sha256:bb" -- \
        drv REG="sha256:$(printf '%064d' 0 | tr 0 b)" bash "$V8_DIR/drive.sh" file "$tag"
    expect "file-$tag-other-no-registry-call" 1 "names an image in $other" "registry_digest" -- \
        drv IDG="$other@@D@" bash "$V8_DIR/drive.sh" file "$tag"
    expect "file-$tag-bad-digest-no-registry-call" 1 "malformed digest" "registry_digest" -- \
        drv IDG="@SELF@@sha256:XYZ" bash "$V8_DIR/drive.sh" file "$tag"
    for m in missing twice wronghash; do
        expect "sums-$tag-$m" 1 "SHA256SUMS does not list the IMAGE_DIGEST beside it exactly once with its hash" -- \
            drv SUMS_MODE=$m bash "$V8_DIR/drive.sh" sums "$tag"
    done
    expect "sums-$tag-advice" 1 "names an image in $other, $shape; do not sign it" -- \
        drv IDG="$other@@D@" ADVICE="do not sign it" bash "$V8_DIR/drive.sh" sums "$tag"

    # cmd_sign: the right package reaches gpg; any refusal stops before confirm, gpg and pull.
    expect "sign-$tag-right" 0 "STOP: reached gpg" -- drv bash "$V8_DIR/drive.sh" sign "$tag"
    for c in "other:$other@@D@" "bad-digest:@SELF@@sha256:XYZ" "two-lines:@SELF@@@D@\n@SELF@@@D@"; do
        cn=${c%%:*}
        ci=${c#*:}
        expect "sign-$tag-$cn" 1 "$dflt" "gpg " -- drv IDG="$ci" bash "$V8_DIR/drive.sh" sign "$tag"
        expect "sign-$tag-$cn-no-pull" 1 "$shape" "docker pull" -- drv IDG="$ci" bash "$V8_DIR/drive.sh" sign "$tag"
        expect "sign-$tag-$cn-no-confirm" 1 "$shape" "confirm Sign" -- drv IDG="$ci" bash "$V8_DIR/drive.sh" sign "$tag"
        # ISO=1: check_release_files replaced; the refusal is the check right before signing.
        expect "sign-$tag-iso-$cn" 1 "$shape; do not sign it; rebuild the draft with make release-build TAG=$tag" "gpg " -- \
            drv ISO=1 IDG="$ci" bash "$V8_DIR/drive.sh" sign "$tag"
        expect "verify-$tag-$cn" 1 "$dflt" "verified" -- drv IDG="$ci" bash "$V8_DIR/drive.sh" verify "$tag"
        expect "verify-$tag-$cn-no-pull" 1 "$shape" "docker pull" -- drv IDG="$ci" bash "$V8_DIR/drive.sh" verify "$tag"
        expect "verify-$tag-iso-$cn" 1 "$shape" "verified" -- drv ISO=1 IDG="$ci" bash "$V8_DIR/drive.sh" verify "$tag"
    done
    expect "sign-$tag-iso-twice" 1 "exactly once" "gpg " -- drv ISO=1 SUMS_MODE=twice bash "$V8_DIR/drive.sh" sign "$tag"
    expect "verify-$tag-right" 0 "verified $tag commit=" -- drv bash "$V8_DIR/drive.sh" verify "$tag"
done
{
    printf 'refusal texts:\n'
    for c in file-v0.1.0-other-network file-v0.1.0-tag-ref file-v0.1.0-two-lines file-v0.1.0-bad-digest \
        file-v0.1.0-crlf file-v0.1.0-zero-bytes sign-v0.1.0-iso-other; do
        [ -f "$OUT/$c.txt" ] && printf '  %s: %s\n' "$c" "$(show "$c")"
    done
} | tee "$OUT/t2-messages.txt"
summary t2_package
