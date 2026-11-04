#!/usr/bin/env bash
# Check 8: commit messages on origin/main..release-packages-per-network carry no trailer and
# no attribution line; the diff touches only the files the UPS spec lists; the worktree is
# unchanged by this harness (only the untracked tasks/ directory).
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
RANGE=origin/main..release-packages-per-network
# The tip under test and its commit count: 0ba57016d (6) in the first round, 57b8ec90a (9) in
# the second, 7ae07a950 (10) at the final tip.
WANT_TIP=${V8_TIP:-7ae07a950}
WANT_N=${V8_COMMITS:-10}
git -C "$TN" log --format='%h %s' "$RANGE" | tee "$OUT/t8-subjects.txt"
expect commits-count 0 "$WANT_N" -- bash -c "git -C '$TN' rev-list --count '$RANGE'"
expect commits-tip 0 "$WANT_TIP" -- git -C "$TN" rev-parse --short=9 release-packages-per-network
expect commits-base 0 "a0d6e6e26" -- git -C "$TN" rev-parse --short=9 origin/main
expect commits-linear 0 "" -- bash -c "test \"\$(git -C '$TN' rev-list --merges --count '$RANGE')\" = 0"
expect commits-no-attribution 1 "" -- \
    bash -c "git -C '$TN' log --format=%B '$RANGE' | grep -n -i -E 'co-authored|signed-off|generated with|claude|anthropic|noreply@|🤖'"
for c in $(git -C "$TN" rev-list "$RANGE"); do
    expect "trailers-$(printf '%s' "$c" | cut -c1-9)" 0 "" -- \
        bash -c "test -z \"\$(git -C '$TN' log -1 --format=%B '$c' | git interpret-trailers --parse)\""
done
expect commits-prefix 1 "" -- bash -c "grep -v -E '^[0-9a-f]+ (release|make|ci|docs): ' '$OUT/t8-subjects.txt'"
git -C "$TN" diff --name-only origin/main release-packages-per-network | tee "$OUT/t8-files.txt"
ALLOWED='^(etc/release\.sh|\.github/workflows/release\.yaml|Makefile|README\.md|SECURITY\.md|etc/README\.md|\.github/ACTIONS\.md|docs/src/getting-started/installing-a-release\.md|docs/src/getting-started/validator-operations\.md|docs/src/maintainers/releasing\.md|docs/src/maintainers/yubikey-setup\.md)$'
expect diff-scope 1 "" -- grep -v -E "$ALLOWED" "$OUT/t8-files.txt"
expect worktree-clean 0 "" -- bash -c "test \"\$(git -C '$TN' status --porcelain)\" = '?? tasks/'"
expect head-is-branch 0 "release-packages-per-network" -- git -C "$TN" rev-parse --abbrev-ref HEAD
summary t8_commits
