#!/usr/bin/env bash
# Check 7: the old package is gone from the docs or described as retired; the operator image
# check in installing-a-release.md, and its twin in the release notes that render_notes writes,
# accept only the tag's package (run with a fake docker first on PATH); the rollback block in
# releasing.md stops on another package; mdbook builds the book (output under SCRATCH), with
# its warnings compared to origin/main's book.
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
DG=sha256:$(printf '%064d' 0 | tr 0 a)
G=ghcr.io/telcoin-association
FAKEBIN=$SCRATCH/fakebin
mkdir -p "$FAKEBIN"
printf '#!/bin/sh\necho "FAKE-DOCKER $*"\n' >"$FAKEBIN/docker"
chmod +x "$FAKEBIN/docker"

# Old package: every remaining mention in the public docs says it is retired.
git -C "$TN" grep -n -i -E "$G/telcoin-network|packages/container/telcoin-network" -- \
    README.md SECURITY.md docs .github/ACTIONS.md etc/README.md >"$OUT/t7-old-package-hits.txt" || true
cat "$OUT/t7-old-package-hits.txt"
expect docs-old-package-only-retired 1 "" -- bash -c "grep -v -E 'never held a release and is (no longer|not) used' '$OUT/t7-old-package-hits.txt'"
expect docs-old-package-hits-two 0 "2" -- bash -c "wc -l <'$OUT/t7-old-package-hits.txt'"

# The operator block: from the "Check the image" heading, the first sh fence.
awk '/^### Check the image/ { s = 1; next } s && /^```sh/ { f = 1; next } f && /^```/ { exit } f' \
    "$TN/docs/src/getting-started/installing-a-release.md" >"$SCRATCH/op-block.sh"
# The release-notes twin from render_notes, with @IMAGE@ filled per channel.
awk '/^IMAGE_REF=\$\(cat IMAGE_DIGEST\)/ { f = 1 } f { print } f && /^esac/ { exit }' "$REL" >"$SCRATCH/notes-block.tmpl"
cat "$SCRATCH/op-block.sh"
run_op() { (cd "$SCRATCH" && printf '%s\n' "$2" >IMAGE_DIGEST && PATH="$FAKEBIN:$PATH" TAG=$1 sh op-block.sh); }
run_notes() {
    local img=$G/tn-mainnet
    case "$1" in *-adiri*) img=$G/tn-testnet ;; esac
    sed "s|@IMAGE@|$img|g" "$SCRATCH/notes-block.tmpl" >"$SCRATCH/notes-block.sh"
    (cd "$SCRATCH" && printf '%s\n' "$2" >IMAGE_DIGEST && PATH="$FAKEBIN:$PATH" sh notes-block.sh)
}
for r in run_op run_notes; do
    expect "$r-mainnet-ok" 0 "FAKE-DOCKER pull $G/tn-mainnet@$DG" -- $r v0.1.0 "$G/tn-mainnet@$DG"
    expect "$r-mainnet-rc-ok" 0 "FAKE-DOCKER pull $G/tn-mainnet@$DG" -- $r v0.1.0-rc1 "$G/tn-mainnet@$DG"
    expect "$r-mainnet-testnet-img" 0 "does not name an image in $G/tn-mainnet by digest" "FAKE-DOCKER" -- $r v0.1.0 "$G/tn-testnet@$DG"
    expect "$r-mainnet-old-img" 0 "does not name an image in $G/tn-mainnet" "FAKE-DOCKER" -- $r v0.1.0 "$G/telcoin-network@$DG"
    expect "$r-mainnet-lookalike" 0 "does not name an image" "FAKE-DOCKER" -- $r v0.1.0 "$G/tn-mainnet-x@$DG"
    expect "$r-mainnet-tagref" 0 "does not name an image" "FAKE-DOCKER" -- $r v0.1.0 "$G/tn-mainnet:v0.1.0"
    expect "$r-adiri-ok" 0 "FAKE-DOCKER pull $G/tn-testnet@$DG" -- $r v0.17.0-adiri "$G/tn-testnet@$DG"
    expect "$r-adiri-rc-ok" 0 "FAKE-DOCKER pull $G/tn-testnet@$DG" -- $r v0.17.0-adiri-rc2 "$G/tn-testnet@$DG"
    expect "$r-adiri-mainnet-img" 0 "does not name an image in $G/tn-testnet by digest" "FAKE-DOCKER" -- $r v0.17.0-adiri "$G/tn-mainnet@$DG"
    expect "$r-adiri-rc-mainnet-img" 0 "does not name an image in $G/tn-testnet" "FAKE-DOCKER" -- $r v0.17.0-adiri-rc2 "$G/tn-mainnet@$DG"
done

# releasing.md rollback: the case line on ${ALIAS%:*}.
awk '/^   PREV=vX.Y.Z-adiri/ { f = 1 } f && /^   case "\$REF"/ { print; exit }' "$TN/docs/src/maintainers/releasing.md" |
    sed 's/^   //; s/ &&$//' >"$SCRATCH/rollback-case.sh"
cat "$SCRATCH/rollback-case.sh"
rb() { ALIAS=$1 REF=$2 sh -c ". '$SCRATCH/rollback-case.sh' && echo PASSES"; }
expect rollback-adiri-ok 0 "PASSES" -- rb "$G/tn-testnet:adiri" "$G/tn-testnet@$DG"
expect rollback-adiri-other 1 "not an image in $G/tn-testnet" "PASSES" -- rb "$G/tn-testnet:adiri" "$G/tn-mainnet@$DG"
expect rollback-mainnet-ok 0 "PASSES" -- rb "$G/tn-mainnet:latest" "$G/tn-mainnet@$DG"
expect rollback-mainnet-other 1 "not an image in $G/tn-mainnet" "PASSES" -- rb "$G/tn-mainnet:latest" "$G/tn-testnet@$DG"

# Anchors the branch links to.
expect anchor-one-time-setup 0 "### One-time setup" -- grep -F '### One-time setup' "$TN/docs/src/maintainers/releasing.md"
expect anchor-registry-access 0 "## Registry access on the build server" -- grep -F '## Registry access on the build server' "$TN/docs/src/maintainers/yubikey-setup.md"

# 57b8ec90a: the first push needs RELEASE_FIRST_PUSH; the docs say so and the old prompt is gone.
RM=$TN/docs/src/maintainers/releasing.md
expect docs-first-push-command 0 'run `RELEASE_FIRST_PUSH=tn-testnet make release-build TAG=<tag>`' -- grep -F 'RELEASE_FIRST_PUSH=tn-testnet make release-build' "$RM"
expect docs-first-push-not-yes 0 '`RELEASE_YES=1` never stands in for it' -- grep -F 'RELEASE_YES=1` never stands in for it' "$RM"
expect docs-full-rebuild 0 "This is a full rebuild, so the first release of each network builds twice" -- grep -F 'This is a full rebuild' "$RM"
expect docs-row-asks 0 '`release-build` stops and asks for `RELEASE_FIRST_PUSH`' -- grep -F 'stops and asks for `RELEASE_FIRST_PUSH`' "$RM"
expect docs-row-private 0 '`release-build` stops before the build: the package is private, not new, and already holds `:<TAG>`' -- grep -F 'private, not new' "$RM"
expect docs-row-private-setup-first 0 'step 2 first (make the package public and set its access lists), then run step 4 again, with `RELEASE_REBUILD=1` if the tag must be rebuilt' -- grep -F 'private, not new' "$RM"
expect docs-row-private-no-warn-wording 1 "" -- grep -F 'warns that the package is private' "$RM"
expect docs-old-prompt-gone 1 "" -- grep -n -E 'asks whether to push|answer no and make it public' "$RM" "$TN/.github/ACTIONS.md"
expect docs-actions-first-push 0 'only with `RELEASE_FIRST_PUSH` set to the package' -- grep -F 'RELEASE_FIRST_PUSH' "$TN/.github/ACTIONS.md"
# The refusal the guide quotes is the start of what the code prints for that case.
quoted=$(sed -n 's/.*as in `\(IMAGE_DIGEST names an image in [^`]*\)`.*/\1/p' "$RM" | head -n 1)
expect docs-quoted-refusal-matches 1 "$quoted" -- \
    env -u RELEASE_REPO -u GITHUB_ACTIONS IDG="ghcr.io/telcoin-association/tn-mainnet@@D@" bash "$V8_DIR/drive.sh" file v0.17.0-adiri
expect docs-env-header 0 "RELEASE_FIRST_PUSH=PACKAGE" -- grep -F 'RELEASE_FIRST_PUSH=PACKAGE' "$REL"

# mdbook, output outside the worktree; origin/main's book from git archive for comparison.
if command -v mdbook >/dev/null 2>&1; then
    rm -rf "$SCRATCH/book-branch" "$SCRATCH/book-main" "$SCRATCH/main-tree"
    expect mdbook-branch 0 "" "[ERROR]" -- mdbook build "$TN/docs" -d "$SCRATCH/book-branch"
    mkdir -p "$SCRATCH/main-tree"
    git -C "$TN" archive origin/main docs CHANGELOG.md | tar -x -C "$SCRATCH/main-tree"
    expect mdbook-main 0 "" "[ERROR]" -- mdbook build "$SCRATCH/main-tree/docs" -d "$SCRATCH/book-main"
    grep -c WARN "$OUT/mdbook-branch.txt" "$OUT/mdbook-main.txt" || true
    expect mdbook-no-new-warnings 0 "" -- bash -c "diff <(grep WARN '$OUT/mdbook-main.txt' | sed 's/^[^]]*]//') <(grep WARN '$OUT/mdbook-branch.txt' | sed 's/^[^]]*]//')"
    expect mdbook-page-has-package 0 "tn-testnet" -- grep -o -m1 'tn-testnet' "$SCRATCH/book-branch/getting-started/installing-a-release.html"
else
    printf 'SKIP mdbook not installed\n'
fi
summary t7_docs
