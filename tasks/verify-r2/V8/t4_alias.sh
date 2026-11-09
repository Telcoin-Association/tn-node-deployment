#!/usr/bin/env bash
# Check 4: the channel alias is created inside the tag's package only. Static: every registry
# write in etc/release.sh targets "$IMAGE:...". Dynamic: cmd_publish with verify, gh and the
# registry stubbed moves tn-mainnet:latest or tn-testnet:adiri to "$IMAGE@$D", never moves an
# alias for a release candidate, and stops before the move when the package serves another
# digest for the tag.
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# pub TAG [VAR=value...]
pub() {
    local tag=$1
    shift
    env -u RELEASE_REPO -u GITHUB_ACTIONS -u RELEASE_DRY_RUN -u RELEASE_IMAGE "$@" bash "$V8_DIR/drive.sh" publish "$tag"
}
M=ghcr.io/telcoin-association/tn-mainnet
T=ghcr.io/telcoin-association/tn-testnet
DG=sha256:$(printf '%064d' 0 | tr 0 a)

grep -n -E 'imagetools create|docker push|--tag |-t "' "$REL" | tee "$OUT/t4-registry-writes.txt"
expect static-writes-in-image 0 "" "ghcr.io" -- grep -E 'imagetools create|docker push' "$REL"
expect static-alias-line 0 'docker buildx imagetools create --prefer-index=false --tag "$IMAGE:$ALIAS" "$IMAGE@$D"' -- \
    grep -F 'imagetools create' "$REL"

expect publish-mainnet 0 "docker buildx imagetools create --prefer-index=false --tag $M:latest $M@$DG" -- pub v0.1.0
expect publish-mainnet-line 0 "published v0.1.0 image=$M@$DG alias=latest" -- pub v0.1.0
expect publish-mainnet-latest 0 "gh release edit v0.1.0 --repo Telcoin-Association/telcoin-network --draft=false --prerelease=false --latest" -- pub v0.1.0
expect publish-adiri 0 "docker buildx imagetools create --prefer-index=false --tag $T:adiri $T@$DG" -- pub v0.17.0-adiri
expect publish-adiri-not-mainnet 0 "alias=adiri" "$M" -- pub v0.17.0-adiri
expect publish-rc-no-alias 0 "alias=none" "imagetools create" -- pub v0.1.0-rc1
expect publish-adiri-rc-no-alias 0 "alias=none" "imagetools create" -- pub v0.17.0-adiri-rc2
expect publish-tag-moved 1 "moves only to the image this package serves for v0.1.0" "imagetools create" -- \
    pub v0.1.0 REG_TAG="sha256:$(printf '%064d' 0 | tr 0 c)"
expect publish-tag-missing 1 "$M:v0.1.0 is missing, not $DG" "imagetools create" -- pub v0.1.0 REG_TAG=
summary t4_alias
