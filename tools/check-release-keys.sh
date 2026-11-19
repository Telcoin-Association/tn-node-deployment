#!/usr/bin/env bash
# =============================================================================
# tools/check-release-keys.sh -- the shipped release keys are copies of the
# tn-release-signing keys at the commit the tree records
#
#   bash tools/check-release-keys.sh [ROOT]
#
# lib/release-keys/*.asc must be byte-for-byte copies of keys/*.asc in the
# tn-release-signing repository at the commit ROOT records for its submodule
# vendor/tn-release-signing: the same set of names and the same bytes. The
# submodule is where the keys come from; lib/release-keys is what ships, since
# install.sh downloads GitHub's archive of a release tag, which never holds a
# submodule's files, and the updater installs the files the signed MANIFEST
# lists. lib/release-keys/README says how to move the pointer and copy them.
#
# The commit is the gitlink in ROOT's index (git ls-files --stage): HEAD's in
# a clean checkout such as CI's, and the moved pointer once git add has staged
# it, so a pointer move can be checked before it is committed. The keys are
# read from the submodule's object store at that commit (git cat-file), never
# from its checked-out files, so a submodule checked out at another commit, or
# with local edits, changes nothing. lib/release-keys is read from the working
# tree. ROOT is the top of the superproject's work tree; without it, the
# repository this tool lives in.
#
# Exit status:
#   0  they match; one line on stdout names the commit and the keys
#   1  they differ; one line per difference on stdout ("missing:", "extra:",
#      "differs:", "not a regular file:"), then a summary on stderr
#   2  the check cannot run: git is missing, ROOT is not the top of a git work
#      tree, the index records no gitlink at vendor/tn-release-signing (or an
#      unmerged one), or the submodule is not initialized or lacks the commit
#      (git submodule update --init -- vendor/tn-release-signing fixes both)
#
# CI runs it in the "checksum freshness" job, which checks the submodule out.
# Maintainer tooling: update-scripts.sh does not track tools/ and this file has
# no .sha256 sidecar. bash 3.2 safe.
# =============================================================================

set -u

readonly SUB="vendor/tn-release-signing"
readonly KEYS_DIR="lib/release-keys"

usage() {
    cat <<'EOF'
usage: tools/check-release-keys.sh [ROOT]

Checks that lib/release-keys/*.asc are byte-for-byte copies of keys/*.asc in
tn-release-signing at the commit the index records for the submodule
vendor/tn-release-signing. Exit 0 when they match, 1 when they differ, 2 when
the check cannot run.
EOF
}

cannot() {
    printf 'check-release-keys: %s\n' "$*" >&2
    exit 2
}

root=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) printf 'check-release-keys: unknown option %s\n' "$1" >&2; usage >&2; exit 2 ;;
        *)
            [ -z "$root" ] || cannot "give one ROOT, not ${root} and $1"
            root="$1"
            ;;
    esac
    shift
done
if [ $# -gt 0 ]; then
    [ -z "$root" ] && [ $# -eq 1 ] || cannot "give one ROOT"
    root="$1"
fi
if [ -z "$root" ]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
fi
[ -d "$root" ] || cannot "${root} is not a directory"
cd "$root" || exit 2

command -v git >/dev/null 2>&1 || cannot "git is not installed"
[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] \
    || cannot "${root} is not a git work tree (a tag archive holds no submodule to compare with)"
[ -z "$(git rev-parse --show-prefix 2>/dev/null)" ] \
    || cannot "${root} is not the top of its git work tree"

# The gitlink: exactly one index entry, mode 160000, stage 0.
entry="$(git ls-files --stage -- "$SUB")"
[ -n "$entry" ] || cannot "the index records no submodule at ${SUB}"
[ "$(printf '%s\n' "$entry" | wc -l | tr -d ' ')" = "1" ] \
    || cannot "${SUB} is not one gitlink in the index (unmerged, or a directory of files)"
mode="${entry%% *}"
rest="${entry#* }"
sha="${rest%% *}"
rest="${rest#* }"
stage="${rest%%$'\t'*}"
[ "$mode" = "160000" ] && [ "$stage" = "0" ] \
    || cannot "${SUB} is not one gitlink in the index (unmerged, or a directory of files)"

# Every read of the submodule goes through its own repository, never one a
# caller's environment names.
sub_git() {
    (
        unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
            GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
        git -C "$SUB" "$@"
    )
}

# An uninitialized submodule is an empty directory inside the superproject's
# work tree, where git -C would read the superproject instead: its prefix
# there is not empty.
init_hint="run git submodule update --init -- ${SUB}"
[ -d "$SUB" ] || cannot "${SUB} is not checked out: ${init_hint}"
prefix="$(sub_git rev-parse --show-prefix 2>/dev/null)" && [ -z "$prefix" ] \
    || cannot "the submodule ${SUB} is not initialized: ${init_hint}"
sub_git cat-file -e "${sha}^{commit}" 2>/dev/null \
    || cannot "the submodule ${SUB} lacks commit ${sha}, which the index records: ${init_hint}"

# The key files at that commit: the blobs directly under keys/ named *.asc.
upstream="$(sub_git ls-tree "$sha" -- keys/ 2>/dev/null | awk -F '\t' '
    { split($1, m, " ") }
    m[2] == "blob" && $2 ~ /^keys\/[^\/]+\.asc$/ { sub(/^keys\//, "", $2); print $2 }
' | LC_ALL=C sort)"
here="$(for f in "$KEYS_DIR"/*.asc; do
    if [ -e "$f" ] || [ -L "$f" ]; then printf '%s\n' "${f##*/}"; fi
done | LC_ALL=C sort)"

short="${sha:0:12}"
bad=0
report() {
    printf '%s\n' "$*"
    bad=1
}

if [ -z "$upstream" ]; then
    report "missing: keys/*.asc (tn-release-signing at ${short} holds no key file)"
fi
while IFS= read -r n; do
    [ -n "$n" ] || continue
    if ! printf '%s\n' "$here" | grep -qxF -- "$n"; then
        report "missing: ${KEYS_DIR}/${n} (keys/${n} is in tn-release-signing at ${short})"
    elif [ -L "${KEYS_DIR}/${n}" ] || [ ! -f "${KEYS_DIR}/${n}" ]; then
        report "not a regular file: ${KEYS_DIR}/${n}"
    elif ! sub_git cat-file blob "${sha}:keys/${n}" | cmp -s - "${KEYS_DIR}/${n}"; then
        report "differs: ${KEYS_DIR}/${n} (not a byte-for-byte copy of keys/${n} at ${short})"
    fi
done <<EOF
$upstream
EOF
while IFS= read -r n; do
    [ -n "$n" ] || continue
    if ! printf '%s\n' "$upstream" | grep -qxF -- "$n"; then
        report "extra: ${KEYS_DIR}/${n} (no keys/${n} in tn-release-signing at ${short})"
    fi
done <<EOF
$here
EOF

if [ "$bad" -ne 0 ]; then
    printf 'check-release-keys: %s/*.asc are not the keys/*.asc of tn-release-signing at %s; copy them as %s/README says (Adding or removing a key)\n' \
        "$KEYS_DIR" "$sha" "$KEYS_DIR" >&2
    exit 1
fi
printf 'check-release-keys: %s/*.asc are the keys/*.asc of tn-release-signing at %s (%s)\n' \
    "$KEYS_DIR" "$sha" "$(printf '%s\n' "$upstream" | tr '\n' ' ' | sed 's/ $//')"
