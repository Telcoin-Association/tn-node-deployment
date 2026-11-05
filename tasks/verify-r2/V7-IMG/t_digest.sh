#!/usr/bin/env bash
# =============================================================================
# tasks/verify-r2/V7-IMG/t_digest.sh -- IMG check 2 (V7 spec): a release whose
# signed IMAGE_DIGEST names another package is refused. End to end through
# _tn_release_fetch with a real detached GPG signature by a throwaway key in a
# temporary GNUPGHOME (the release keys dir points at it), a curl stand-in that
# serves the fixture release over https://fixture.invalid/, and, because these
# scripts pin no mainnet chain configs yet, tn_chain_config_pin answering the
# fixture's hashes for mainnet (testnet keeps the library's pins). Mainnet
# v1.0.0 naming tn-testnet, the old package, GAR or tn-dev is refused with a
# message naming the image and tn-mainnet; tn-mainnet is taken. Testnet
# v0.17.0-adiri naming tn-mainnet, the old package or tn-dev is refused;
# tn-testnet and GAR are taken. tn_docker_image_for_tag on mainnet never falls
# back to the registry after such a refusal. Without gpg the signed cases SKIP.
#
#   bash tasks/verify-r2/V7-IMG/t_digest.sh
#
# Verifier harness (round 2, V7-IMG). bash 3.2 safe.
# =============================================================================
# shellcheck source=tasks/verify-r2/V7-IMG/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
eval "$(tn_test_source_common)"

FIX="$T/fix"
STAGE="$T/stage"
KEYS="$T/keys"
mkdir -p "$FIX" "$KEYS"
mkdir -m 0700 "$STAGE"
export FIX
cat > "$T/bin/curl" <<'SH'
#!/bin/sh
out=""; url=""; proto=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --url) url="$2"; shift 2 ;;
        --proto) proto="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[ "$proto" = "=https" ] || exit 1
case "$url" in
    https://fixture.invalid/*) src="$FIX/${url#https://fixture.invalid/}" ;;
    *) exit 6 ;;
esac
[ -f "$src" ] || exit 22
if [ -n "$out" ]; then cat "$src" > "$out"; else cat "$src"; fi
SH
chmod 0755 "$T/bin/curl"
PATH="$T/bin:$PATH"
export TN_RELEASE_STAGING_DIR="$STAGE" TN_RELEASE_KEYS_DIR="$KEYS"

if ! command -v gpg >/dev/null 2>&1 || ! command -v gpgv >/dev/null 2>&1; then
    skip "signed IMAGE_DIGEST cases" "gpg or gpgv absent"
    finish
fi
export GNUPGHOME="$T/gnupg"
mkdir -m 0700 "$GNUPGHOME"
G() { gpg --batch --no-tty --quiet --pinentry-mode loopback --passphrase '' "$@"; }
G --quick-gen-key 'V7 IMG <v7img@example.invalid>' ed25519 sign 1y 2>/dev/null
FA="$(gpg --batch --with-colons --list-keys v7img@example.invalid 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
if [[ -z "$FA" ]]; then
    skip "signed IMAGE_DIGEST cases" "gpg could not make a throwaway key"
    finish
fi
G --armor --export "$FA" > "$KEYS/v7img.asc"
h() { sha256sum < "$1" | cut -d' ' -f1; }
TRIPLE="$(_tn_release_triple)"

# mk_release TAG NETWORK IMAGE -- the fixture release TAG, signed by the throwaway key.
mk_release() {
    local tag="$1" net="$2" img="$3" rel="$FIX/$1" tb f
    rm -rf "$rel"
    mkdir -p "$rel/chain-configs/$net"
    tb="telcoin-network-${tag}-${TRIPLE}.tar.gz"
    printf 'tarball\n' > "$rel/$tb"
    printf '%s\n' "$img" > "$rel/IMAGE_DIGEST"
    for f in committee genesis parameters; do printf '%s %s\n' "$net" "$f" > "$rel/chain-configs/$net/$f.yaml"; done
    {
        printf '%s  IMAGE_DIGEST\n' "$(h "$rel/IMAGE_DIGEST")"
        for f in committee genesis parameters; do
            if [[ "$net" == testnet ]]; then
                printf '%s  chain-configs/testnet/%s.yaml\n' "$(_v7_orig_pin testnet "$f.yaml")" "$f"
            else
                printf '%s  chain-configs/mainnet/%s.yaml\n' "$(h "$rel/chain-configs/$net/$f.yaml")" "$f"
            fi
        done
        printf '%s  %s\n' "$(h "$rel/$tb")" "$tb"
    } > "$rel/SHA256SUMS"
    G -u "$FA" --armor --detach-sign -o "$rel/SHA256SUMS.asc" "$rel/SHA256SUMS" 2>/dev/null
}
eval "$(declare -f tn_chain_config_pin | sed '1s/^tn_chain_config_pin/_v7_orig_pin/')"
tn_chain_config_pin() {
    if [[ "${1:-}" == mainnet ]]; then
        h "$FIX/v1.0.0/chain-configs/mainnet/${2%.yaml}.yaml"
        return 0
    fi
    _v7_orig_pin "$@"
}

fri() {  # NAME TAG NETWORK IMAGE EXPECTED ("rc out")
    local rc=0 o
    mk_release "$2" "$3" "$4"
    o="$(tn_fetch_release_image "$2" "$3" "https://fixture.invalid/$2" 2>"$T/err")" || rc=$?
    check "IMAGE_DIGEST $3 $2: $1" "$5" "$rc $o"
    check "IMAGE_DIGEST $3 $2: $1: staging left empty" "0" "$(find "$STAGE" -mindepth 1 | wc -l | tr -d ' ')"
}
fri "tn-mainnet taken" v1.0.0 mainnet "${GM}@sha256:${D64}" "0 ${GM}@sha256:${D64}"
check "IMAGE_DIGEST mainnet: the signature really verified (no warning)" "" "$(cat "$T/err")"
fri "tn-testnet refused" v1.0.0 mainnet "${GT}@sha256:${D64}" "1 "
check "IMAGE_DIGEST mainnet: refusal names the image and tn-mainnet" "1" \
    "$(grep -cF "Release v1.0.0: IMAGE_DIGEST names ${GT}@sha256:${D64}, but a mainnet release image is <repository>@sha256:<digest> from ${GM}. The release is refused and nothing was pulled" "$T/err")"
fri "old single package refused" v1.0.0 mainnet "${GL}@sha256:${D64}" "1 "
fri "GAR refused" v1.0.0 mainnet "${GAR}@sha256:${D64}" "1 "
fri "tn-dev refused" v1.0.0 mainnet "${GD}@sha256:${D64}" "1 "
fri "tn-mainnet by tag refused" v1.0.0 mainnet "${GM}:v1.0.0" "1 "
fri "uppercase tn-mainnet refused" v1.0.0 mainnet "GHCR.IO/TELCOIN-ASSOCIATION/TN-MAINNET@sha256:${D64}" "1 "
fri "tn-testnet taken" v0.17.0-adiri testnet "${GT}@sha256:${D64}" "0 ${GT}@sha256:${D64}"
fri "GAR taken" v0.17.0-adiri testnet "${GAR}@sha256:${D64}" "0 ${GAR}@sha256:${D64}"
fri "tn-mainnet refused" v0.17.0-adiri testnet "${GM}@sha256:${D64}" "1 "
fri "old single package refused" v0.17.0-adiri testnet "${GL}@sha256:${D64}" "1 "
check "IMAGE_DIGEST testnet: old-package refusal lists the pull repositories" "1" \
    "$(grep -cF "but a testnet release image is <repository>@sha256:<digest> from ${GAR} or ${GT}." "$T/err")"
fri "tn-dev refused" v0.17.0-adiri testnet "${GD}@sha256:${D64}" "1 "
# SHA256SUMS changed after signing (BADSIG): refused, so the signature is really checked.
mk_release v1.0.0 mainnet "${GM}@sha256:${D64}"
printf '\n' >> "$FIX/v1.0.0/SHA256SUMS"
rc=0; tn_fetch_release_image v1.0.0 mainnet "https://fixture.invalid/v1.0.0" 2>/dev/null || rc=$?
check_rc "IMAGE_DIGEST mainnet: SHA256SUMS changed after signing refused" 1 "$rc"
# A tampered IMAGE_DIGEST after signing: the hash check refuses it.
mk_release v1.0.0 mainnet "${GM}@sha256:${D64}"
printf '%s@sha256:%s\n' "$GT" "$D64" > "$FIX/v1.0.0/IMAGE_DIGEST"
rc=0; tn_fetch_release_image v1.0.0 mainnet "https://fixture.invalid/v1.0.0" 2>/dev/null || rc=$?
check_rc "IMAGE_DIGEST mainnet: swapped after signing refused" 1 "$rc"
# tn_docker_image_for_tag on mainnet: the refusal is final, the registry is never asked.
mk_release v1.0.0 mainnet "${GT}@sha256:${D64}"
rc=0; o="$(tn_fetch_release_image v1.0.0 mainnet "https://fixture.invalid/v1.0.0" 2>/dev/null)" || rc=$?
check "IMAGE_DIGEST mainnet: refused (direct)" "1 " "$rc $o"
eval "$(declare -f tn_fetch_release_image | sed '1s/^tn_fetch_release_image/_v7_orig_fri/')"
tn_fetch_release_image() { _v7_orig_fri "$1" "$2" "https://fixture.invalid/$1" "${4:-}"; }
rc=0; o="$(tn_docker_image_for_tag mainnet v1.0.0 2>/dev/null)" || rc=$?
check "image_for_tag mainnet: a release naming tn-testnet refused" "1 " "$rc $o"
o="$( tn_registry_digest() { echo CALLED; }; tn_docker_image_for_tag mainnet v1.0.0 2>/dev/null )" || true
check "image_for_tag mainnet: no registry fallback after the refusal" "" "$o"
mk_release v0.17.0-adiri testnet "${GL}@sha256:${D64}"
o="$( tn_registry_digest() { echo "sha256:${D64}"; }; tn_docker_image_for_tag testnet v0.17.0-adiri 2>/dev/null )" || true
check "image_for_tag testnet: a release naming the old package refused, no registry fallback" "" "$o"
gpgconf --kill all >/dev/null 2>&1 || true
finish
