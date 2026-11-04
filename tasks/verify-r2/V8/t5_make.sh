#!/usr/bin/env bash
# Check 5: the Makefile's ad-hoc image targets push to tn-dev, and no target writes to
# tn-mainnet or tn-testnet except through etc/release.sh. `make -n` prints the recipes without
# running them (the $(shell ...) assignments only read git and files).
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
mk() { make -C "$TN" -n "$@"; }
for t in docker-adiri docker-devnet docker-push; do
    expect "make-n-$t" 0 "ghcr.io/telcoin-association/tn-dev:dev-" "tn-mainnet" -- mk "$t" TAG=abc123
    expect "make-n-$t-not-testnet" 0 "tn-dev" "tn-testnet" -- mk "$t" TAG=abc123
done
expect make-n-release-build 0 './etc/release.sh build "v0.1.0"' -- mk release-build TAG=v0.1.0
expect make-n-release-publish 0 './etc/release.sh publish "v0.17.0-adiri"' -- mk release-publish TAG=v0.17.0-adiri
# Every recipe line that pushes or retags: only the three tn-dev targets.
grep -n -E -- '--push|docker push|imagetools create|docker tag' "$TN/Makefile" | tee "$OUT/t5-make-pushes.txt"
expect make-push-lines-tn-dev 0 "" "tn-mainnet" -- grep -E -- '--push|docker push|imagetools create|docker tag' "$TN/Makefile"
expect make-no-release-package-in-recipes 1 "" -- \
    bash -c "grep -nE '^\s+[^@#].*(tn-mainnet|tn-testnet)' '$TN/Makefile'"
expect make-ghcr-image-tn-dev 0 "GHCR_IMAGE := ghcr.io/telcoin-association/tn-dev" -- grep -F 'GHCR_IMAGE :=' "$TN/Makefile"
expect make-old-package-gone 1 "" -- grep -F 'ghcr.io/telcoin-association/telcoin-network' "$TN/Makefile"
# A make variable can be overridden on the command line; recorded, not a defect of the branch.
expect make-override-possible 0 "tn-mainnet:dev-adiri-abc" -- \
    mk docker-push TAG=abc GHCR_IMAGE=ghcr.io/telcoin-association/tn-mainnet
summary t5_make
