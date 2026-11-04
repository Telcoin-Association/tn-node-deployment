#!/usr/bin/env bash
# Check 2: the sign-time and verify-time package checks, sourced from etc/release.sh through
# drive.sh: check_sums_package (new; sign and verify), check_image_digest_file (through
# check_digest_package; build's self-check, sign, verify, publish), and cmd_sign/cmd_verify
# with the I/O stubbed, to show where in the flow a wrong package stops and what never runs.
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
drv() { env -u RELEASE_REPO -u GITHUB_ACTIONS -u RELEASE_YES bash "$V8_DIR/drive.sh" "$@"; }

M=ghcr.io/telcoin-association/tn-mainnet
T=ghcr.io/telcoin-association/tn-testnet
DG=sha256:$(printf '%064d' 0 | tr 0 a)

for spec in "v0.1.0 mainnet $M $T" "v0.17.0-adiri adiri $T $M"; do
    set -- $spec
    tag=$1 ch=$2 own=$3 other=$4
    wrong="IMAGE_DIGEST names an image in $other, but $tag is on the $ch channel, whose images are published only in $own"
    for fn in sums file; do
        p="$fn-$tag"
        expect "$p-right" 0 "PASSED" -- drv "$fn" "$tag"
        expect "$p-other-network" 1 "$wrong" -- env IDG="$other@@D@" bash "$V8_DIR/drive.sh" "$fn" "$tag"
        expect "$p-old-package" 1 "names an image in ghcr.io/telcoin-association/telcoin-network, but $tag" -- \
            env IDG="ghcr.io/telcoin-association/telcoin-network@@D@" bash "$V8_DIR/drive.sh" "$fn" "$tag"
        expect "$p-other-owner" 1 "names an image in ghcr.io/evil/${own##*/}, but" -- \
            env IDG="ghcr.io/evil/${own##*/}@@D@" bash "$V8_DIR/drive.sh" "$fn" "$tag"
        expect "$p-uppercase" 1 "names an image in GHCR.IO/" -- \
            env IDG="GHCR.IO/telcoin-association/${own##*/}@@D@" bash "$V8_DIR/drive.sh" "$fn" "$tag"
        expect "$p-tag-ref" 1 "not an image by digest; expected $own@sha256:<hex>" -- \
            env IDG="@SELF@:$tag" bash "$V8_DIR/drive.sh" "$fn" "$tag"
        expect "$p-tag-and-digest" 1 "names an image in $own:$tag, but" -- \
            env IDG="@SELF@:$tag@@D@" bash "$V8_DIR/drive.sh" "$fn" "$tag"
        expect "$p-empty" 1 "names '', not an image by digest" -- env IDG="" bash "$V8_DIR/drive.sh" "$fn" "$tag"
        expect "$p-two-lines" 1 "IMAGE_DIGEST must be a single line" -- \
            env IDG="@SELF@@@D@\n@SELF@@@D@" bash "$V8_DIR/drive.sh" "$fn" "$tag"
        expect "$p-two-lines-other" 1 "IMAGE_DIGEST must be a single line" -- \
            env IDG="@SELF@@@D@\n$other@@D@" bash "$V8_DIR/drive.sh" "$fn" "$tag"
    done
    # Shapes only check_image_digest_file refuses; check_sums_package checks the package alone.
    expect "sums-$tag-bad-digest-passes" 0 "PASSED" -- env IDG="@SELF@@sha256:XYZ" bash "$V8_DIR/drive.sh" sums "$tag"
    expect "file-$tag-bad-digest" 1 "IMAGE_DIGEST holds a malformed digest: sha256:XYZ" -- \
        env IDG="@SELF@@sha256:XYZ" bash "$V8_DIR/drive.sh" file "$tag"
    expect "file-$tag-trailing-blank" 1 "IMAGE_DIGEST must be a single line" -- \
        env IDG="@SELF@@@D@\n" bash "$V8_DIR/drive.sh" file "$tag"
    expect "file-$tag-crlf" 1 "malformed digest" -- env IDG="@SELF@@@D@\r" bash "$V8_DIR/drive.sh" file "$tag"
    expect "file-$tag-registry-differs" 1 "but the registry serves $own:$tag as sha256:bb" -- \
        env REG="sha256:$(printf '%064d' 0 | tr 0 b)" bash "$V8_DIR/drive.sh" file "$tag"
    expect "file-$tag-other-no-registry-call" 1 "$wrong" "registry_digest" -- \
        env IDG="$other@@D@" bash "$V8_DIR/drive.sh" file "$tag"
    for m in missing twice wronghash; do
        expect "sums-$tag-$m" 1 "SHA256SUMS does not list the IMAGE_DIGEST beside it exactly once with its hash" -- \
            env SUMS_MODE=$m bash "$V8_DIR/drive.sh" sums "$tag"
    done
    expect "sums-$tag-advice" 1 "$wrong; do not sign it" -- \
        env IDG="$other@@D@" ADVICE="do not sign it" bash "$V8_DIR/drive.sh" sums "$tag"

    # cmd_sign: the right package reaches gpg; a wrong one stops before confirm, gpg and pull.
    expect "sign-$tag-right" 0 "STOP: reached gpg" -- bash "$V8_DIR/drive.sh" sign "$tag"
    expect "sign-$tag-other" 1 "$wrong" "gpg " -- env IDG="$other@@D@" bash "$V8_DIR/drive.sh" sign "$tag"
    expect "sign-$tag-other-no-pull" 1 "$wrong" "docker pull" -- env IDG="$other@@D@" bash "$V8_DIR/drive.sh" sign "$tag"
    expect "sign-$tag-other-no-confirm" 1 "$wrong" "confirm Sign" -- env IDG="$other@@D@" bash "$V8_DIR/drive.sh" sign "$tag"
    # ISO=1: check_release_files replaced, so the refusal is the new check right before signing.
    expect "sign-$tag-iso-other" 1 "$wrong; do not sign it; rebuild the draft with make release-build TAG=$tag" "gpg " -- \
        env ISO=1 IDG="$other@@D@" bash "$V8_DIR/drive.sh" sign "$tag"
    expect "sign-$tag-iso-twice" 1 "exactly once" "gpg " -- env ISO=1 SUMS_MODE=twice bash "$V8_DIR/drive.sh" sign "$tag"
    # cmd_verify (allow-unsigned, a draft).
    expect "verify-$tag-right" 0 "verified $tag commit=" -- bash "$V8_DIR/drive.sh" verify "$tag"
    expect "verify-$tag-other" 1 "$wrong" "docker pull" -- env IDG="$other@@D@" bash "$V8_DIR/drive.sh" verify "$tag"
    expect "verify-$tag-iso-other" 1 "$wrong" "verified" -- env ISO=1 IDG="$other@@D@" bash "$V8_DIR/drive.sh" verify "$tag"
    expect "verify-$tag-two-lines" 1 "single line" "verified" -- \
        env IDG="@SELF@@@D@\n$other@@D@" bash "$V8_DIR/drive.sh" verify "$tag"
    expect "verify-$tag-bad-digest" 1 "malformed digest" "docker pull" -- \
        env IDG="@SELF@@sha256:XYZ" bash "$V8_DIR/drive.sh" verify "$tag"
done
{
    printf 'refusal texts (v0.1.0):\n'
    for c in file-v0.1.0-other-network file-v0.1.0-tag-ref file-v0.1.0-two-lines file-v0.1.0-bad-digest sign-v0.1.0-iso-other verify-v0.17.0-adiri-other; do
        printf '  %s: %s\n' "$c" "$(show "$c")"
    done
} | tee "$OUT/t2-messages.txt"
summary t2_package
