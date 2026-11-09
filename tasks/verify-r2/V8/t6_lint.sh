#!/usr/bin/env bash
# Check 6: bash -n (host 5.3 and bash:3.2), shellcheck -x -S style (host 0.11), actionlint on
# release.yaml (host), and make release-lint (pinned actionlint and shellcheck images, run with
# --network none on a read-only mount). Also the parse CLI under bash:3.2 on the branch and on
# origin/main, since the file's header says it is portable to macOS bash 3.2.
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
expect bash-n-host 0 "" -- bash -n "$REL"
expect shellcheck-style-host 0 "" -- bash -c "cd '$TN' && shellcheck -x -S style etc/release.sh"
expect actionlint-host 0 "" -- bash -c "cd '$TN' && actionlint .github/workflows/release.yaml .github/workflows/docs.yaml"
expect make-release-lint 0 "" "error" -- make -C "$TN" release-lint
if docker image inspect bash:3.2 >/dev/null 2>&1; then
    main_copy=$SCRATCH/release-origin-main.sh
    git -C "$TN" show origin/main:etc/release.sh >"$main_copy"
    expect bash32-n-branch 0 "" -- docker run --rm --network none -v "$TN:/w:ro" -w /w bash:3.2 bash -n etc/release.sh
    expect bash32-parse-branch 0 "PACKAGE=tn-testnet" -- \
        docker run --rm --network none -v "$TN:/w:ro" -w /w bash:3.2 bash etc/release.sh parse v0.17.0-adiri
    expect bash32-parse-main 0 "CHANNEL=adiri" -- \
        docker run --rm --network none -v "$SCRATCH:/w:ro" -w /w bash:3.2 bash release-origin-main.sh parse v0.17.0-adiri
else
    printf 'SKIP bash:3.2 image not present\n'
fi
summary t6_lint
