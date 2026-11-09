#!/usr/bin/env bash
# Check 3: RELEASE_IMAGE is honoured only with RELEASE_DRY_RUN=1 (init_env through drive.sh,
# and the real CLI, which stops in init_env before any git, gh, docker or network call);
# RELEASE_REPO and GITHUB_REPOSITORY change the GitHub slug and the image owner, never the
# package. Also: check-tag prints the parse (PACKAGE) and IMAGE to its log.
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
clean() { env -u RELEASE_REPO -u GITHUB_ACTIONS -u GITHUB_REPOSITORY -u RELEASE_DRY_RUN -u RELEASE_IMAGE "$@"; }
init() { clean "$@"; }
cli() { (cd "$TN" && clean TMPDIR="$SCRATCH" "$@"); }

for tag in v0.1.0 v0.17.0-adiri; do
    expect "dry-image-$tag" 0 "IMAGE=localhost:5000/x DRY_RUN=1" -- \
        init RELEASE_DRY_RUN=1 RELEASE_IMAGE=localhost:5000/x bash "$V8_DIR/drive.sh" init "$tag"
    expect "nodry-image-$tag" 2 "RELEASE_IMAGE is honoured only in a dry run (RELEASE_DRY_RUN=1)" -- \
        init RELEASE_IMAGE=localhost:5000/x bash "$V8_DIR/drive.sh" init "$tag"
    expect "dry0-image-$tag" 2 "RELEASE_IMAGE is honoured only in a dry run" -- \
        init RELEASE_DRY_RUN=0 RELEASE_IMAGE=localhost:5000/x bash "$V8_DIR/drive.sh" init "$tag"
    expect "nodry-empty-image-$tag" 2 "RELEASE_IMAGE is honoured only in a dry run" -- \
        init RELEASE_IMAGE= bash "$V8_DIR/drive.sh" init "$tag"
    expect "dry-ghcr-image-$tag" 2 "RELEASE_IMAGE must be localhost:PORT/ or 127.0.0.1:PORT/" -- \
        init RELEASE_DRY_RUN=1 RELEASE_IMAGE=ghcr.io/telcoin-association/tn-mainnet bash "$V8_DIR/drive.sh" init "$tag"
    expect "dry-noimage-build-$tag" 2 "dry run: set RELEASE_IMAGE to a localhost: or 127.0.0.1: repository" -- \
        init RELEASE_DRY_RUN=1 bash "$V8_DIR/drive.sh" build "$tag"
    for sub in check-tag build sign verify publish; do
        expect "cli-nodry-$sub-$tag" 2 "RELEASE_IMAGE is honoured only in a dry run" -- \
            cli RELEASE_IMAGE=localhost:5000/x ./etc/release.sh "$sub" "$tag"
    done
done

expect repo-same-owner 0 "REPO=Telcoin-Association/other-repo IMAGE=ghcr.io/telcoin-association/tn-mainnet " -- \
    init RELEASE_REPO=Telcoin-Association/other-repo bash "$V8_DIR/drive.sh" init v0.1.0
expect repo-named-like-package 0 "IMAGE=ghcr.io/telcoin-association/tn-mainnet " -- \
    init RELEASE_REPO=Telcoin-Association/tn-testnet bash "$V8_DIR/drive.sh" init v0.1.0
expect repo-named-like-package-adiri 0 "IMAGE=ghcr.io/telcoin-association/tn-testnet " -- \
    init RELEASE_REPO=Telcoin-Association/tn-mainnet bash "$V8_DIR/drive.sh" init v0.17.0-adiri
expect repo-other-owner 0 "IMAGE=ghcr.io/someone-else/tn-mainnet " -- \
    init RELEASE_REPO=Someone-Else/telcoin-network bash "$V8_DIR/drive.sh" init v0.1.0
expect repo-other-owner-warns 0 "warning: using repository Someone-Else/telcoin-network" -- \
    init RELEASE_REPO=Someone-Else/telcoin-network bash "$V8_DIR/drive.sh" init v0.1.0
expect repo-dry-image-wins 0 "REPO=Someone-Else/x IMAGE=localhost:5000/x " -- \
    init RELEASE_DRY_RUN=1 RELEASE_IMAGE=localhost:5000/x RELEASE_REPO=Someone-Else/x bash "$V8_DIR/drive.sh" init v0.1.0
expect repo-bad 2 "RELEASE_REPO must look like owner/repo" -- \
    init RELEASE_REPO=no-slash bash "$V8_DIR/drive.sh" init v0.1.0
expect repo-ci 0 "IMAGE=ghcr.io/telcoin-association/tn-testnet " -- \
    init GITHUB_ACTIONS=true GITHUB_REPOSITORY=Telcoin-Association/telcoin-network bash "$V8_DIR/drive.sh" init v0.17.0-adiri
expect repo-ci-fork 0 "IMAGE=ghcr.io/a-fork/tn-mainnet " -- \
    init GITHUB_ACTIONS=true GITHUB_REPOSITORY=A-Fork/telcoin-network bash "$V8_DIR/drive.sh" init v0.1.0
expect repo-honoured-without-dry-run 0 "DRY_RUN=0" -- \
    init RELEASE_REPO=Someone-Else/telcoin-network bash "$V8_DIR/drive.sh" init v0.1.0

expect checktag-mainnet 0 "PACKAGE=tn-mainnet" -- \
    init GITHUB_ACTIONS=true GITHUB_REPOSITORY=Telcoin-Association/telcoin-network bash "$V8_DIR/drive.sh" checktag v0.1.0
expect checktag-mainnet-image 0 "IMAGE=ghcr.io/telcoin-association/tn-mainnet" -- \
    init GITHUB_ACTIONS=true GITHUB_REPOSITORY=Telcoin-Association/telcoin-network bash "$V8_DIR/drive.sh" checktag v0.1.0
expect checktag-adiri 0 "IMAGE=ghcr.io/telcoin-association/tn-testnet" -- \
    init GITHUB_ACTIONS=true GITHUB_REPOSITORY=Telcoin-Association/telcoin-network bash "$V8_DIR/drive.sh" checktag v0.17.0-adiri-rc2
summary t3_env
