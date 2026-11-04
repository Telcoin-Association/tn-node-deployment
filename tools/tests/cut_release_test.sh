#!/usr/bin/env bash
# =============================================================================
# tools/tests/cut_release_test.sh -- tools/cut-release.sh prep and tag against
# a bare "origin" repository on disk
#
#   bash tools/tests/cut_release_test.sh
#
# Copies the tracked files into a clone of a bare origin repository in the
# temp dir, with a throwaway release key in lib/release-keys, and drives
# `cut-release.sh prep TAG --yes` and `cut-release.sh tag TAG --yes`. git is
# real and pushes go to the bare origin. gpg and gpgv are the fakes of
# tools/tests/signing.sh, used even where GnuPG is installed, so no real key or
# agent is involved; git signs and verifies through the fake gpg (gpg.program
# in the clone). gh and curl are stand-ins that log their calls. HOME and the
# global git configuration point into the temp dir, so the user's git settings
# play no part. Needs git; without it (the bash:3.2 and ubuntu:24.04 images)
# the file is SKIP. No network, nothing outside the temp dir.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
REPO="$TN_TEST_REPO"
BIN="$T/bin"
mkdir -p "$BIN" "$T/home"

if ! command -v git >/dev/null 2>&1 || ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    skip "cut-release.sh" "git absent or not a git checkout"
    finish
fi

export TN_TEST_FAKE_GPG=1
# shellcheck source=tools/tests/signing.sh
. "$TN_TEST_DIR/signing.sh"
FPR1="$(newkey key1)"
FPR2="$(newkey key2)"

cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
# gh stand-in: logs the call; pr list prints the pull request once one exists.
echo "gh \$*" >> "$T/gh.log"
case "\$1 \$2" in
    "pr list") [ ! -f "$T/gh.pr" ] || cat "$T/gh.pr" ;;
    "pr create")
        while [ \$# -gt 0 ]; do
            if [ "\$1" = --body-file ]; then cp "\$2" "$T/pr-body.md"; fi
            shift
        done
        echo "https://github.example.invalid/pull/7" > "$T/gh.pr"
        cat "$T/gh.pr" ;;
    "run list") echo "\${GH_RUN:-completed success https://github.example.invalid/run/1}" ;;
    *) exit 1 ;;
esac
EOF
cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
# curl stand-in: the published installer names SERVED_TAG.
echo "curl \$*" >> "$T/curl.log"
printf '#!/usr/bin/env bash\n# the tag in TN_SCRIPTS_TAG below\nreadonly TN_SCRIPTS_TAG="%s"   # written by tools/release-scripts.sh\n' "\${SERVED_TAG:-}"
EOF
chmod +x "$BIN/gh" "$BIN/curl"

# --- the fixture: a bare origin and a clone holding the tracked files -----------
ORIGIN="$T/origin.git"
W="$T/work"
TAG=scripts-v2.1.0
BR="release/$TAG"
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
mkdir -p "$W"
(cd "$REPO" && git ls-files | while IFS= read -r p; do [ -e "$p" ] && printf '%s\n' "$p"; done | tar -cf - -T -) | tar -xf - -C "$W"
# From here on the user's git configuration is not read: HOME and the global
# file are in the temp dir (the copy above still read the repository the
# usual way).
export HOME="$T/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$T/home/.gitconfig"
: > "$GIT_CONFIG_GLOBAL"
cp "$REPO/tools/cut-release.sh" "$REPO/tools/release-scripts.sh" "$W/tools/"
rm -f "$W/MANIFEST" "$W/MANIFEST.asc" "$W/RELEASE" "$W"/lib/release-keys/*.asc "$W"/lib/release-keys/*.asc.sha256
cp "$T/key1.asc" "$W/lib/release-keys/grantkee.asc"
(cd "$W" && bash tools/gen-checksums.sh >/dev/null)
gitw() { git -C "$W" "$@"; }
gitw init -q
gitw symbolic-ref HEAD refs/heads/main
gitw config user.name test
gitw config user.email test@example.invalid
gitw config gpg.program "$BIN/gpg"
gitw remote add origin "$ORIGIN"
gitw add -A
gitw commit -q -m fixture
gitw push -q origin main 2>/dev/null

# cut ARGS... -- run the clone's cut-release.sh; OUT and RC get its output and status.
cut() {
    OUT="$(cd "$W" && TN_CUT_POLL_SECONDS=0 TN_CUT_POLL_TRIES=3 bash tools/cut-release.sh "$@" < /dev/null 2>&1)"
    RC=$?
}
# order NAME PATTERN... -- each PATTERN first matches a line of OUT after the one before.
order() {
    local name="$1" p last=0 at
    shift
    for p in "$@"; do
        at="$(printf '%s\n' "$OUT" | awk -v p="$p" -v after="$last" 'NR > after && index($0, p) { print NR; exit }')"
        if [[ -z "$at" ]]; then
            check "$name" "in order" "missing after line ${last}: ${p}"
            return
        fi
        last="$at"
    done
    check "$name" "in order" "in order"
}
has() {   # has NAME TEXT -- OUT contains TEXT
    check "$1" "yes" "$(printf '%s\n' "$OUT" | grep -qF -- "$2" && echo yes || echo "no: $(printf '%s\n' "$OUT" | tail -n 3)")"
}

# --- usage ----------------------------------------------------------------------------
cut
check_rc "no command: usage error" 2 "$RC"
cut bogus
check_rc "unknown command: usage error" 2 "$RC"
cut prep
check_rc "prep without a tag: usage error" 2 "$RC"
cut prep scripts-v2
check_rc "a malformed tag: refused" 1 "$RC"
cut tag "$TAG" --serial 3
check_rc "tag with --serial: usage error" 2 "$RC"

# --- q stops before anything runs --------------------------------------------------------
OUT="$(cd "$W" && printf 'q\n' | bash tools/cut-release.sh prep "$TAG" 2>&1)"
RC=$?
check_rc "q: exits 0" 0 "$RC"
has "q: the first step was shown" "[1/9] fetch origin"
has "q: says how to carry on" "Stopped. Run the same command again to carry on from here."
check "q: no release branch" "absent" "$(gitw rev-parse -q --verify "refs/heads/$BR" >/dev/null && echo present || echo absent)"

# --- refusals ------------------------------------------------------------------------------
printf 'dirty\n' >> "$W/README.md"
cut prep "$TAG" --serial 1 --yes
check_rc "dirty tree: refused" 1 "$RC"
has "dirty tree: says why" "cut-release.sh: the tree has uncommitted changes: commit or stash them first"
check "dirty tree: no release branch" "absent" "$(gitw rev-parse -q --verify "refs/heads/$BR" >/dev/null && echo present || echo absent)"
gitw checkout -q -- README.md

cut prep "$TAG" --serial 1 --key "$FPR2" --yes
check_rc "a key that is not a release key: refused" 1 "$RC"
has "a key that is not a release key: says why" "cut-release.sh: the signing key ${FPR2} is not a primary key of lib/release-keys/*.asc"
check "a key that is not a release key: nothing prepared" "absent" "$([[ -e "$W/MANIFEST" ]] && echo present || echo absent)"
check "a key that is not a release key: nothing signed" "" "$(grep -e '--detach-sign' "$T/gpg.log" 2>/dev/null)"

# --- prep ----------------------------------------------------------------------------------
: > "$T/gpg.log"
cut prep "$TAG" --serial 1 --yes
check_rc "prep: exits 0" 0 "$RC"
order "prep: the steps in order" "] fetch origin" "] release branch" "signing key ${FPR1}" "] prepare MANIFEST" \
    "] sign MANIFEST" "] check the release" "] stage the release files" "] commit, signed" "] push the release branch" \
    "] open the release pull request"
has "prep: prints the signing command" "\$ gpg --armor --detach-sign --local-user ${FPR1}\\! --output MANIFEST.asc MANIFEST"
has "prep: prints the prepare command" "\$ bash tools/release-scripts.sh --serial 1 ${TAG}"
check "prep: card, then the manifest signature, then the signed commit" "yes" "$(awk -v f="${FPR1}!" '
    /--card-status/ && !c { c = NR }
    /--detach-sign --local-user/ && index($0, f) && !s { s = NR }
    /-bsau/ && index($0, f) && !g { g = NR }
    END { print (c && s && g && c < s && s < g) ? "yes" : "no" }' "$T/gpg.log")"
check "prep: origin has the release commit" "release: $TAG" "$(git -C "$ORIGIN" log -1 --format=%s "$BR" 2>/dev/null)"
check "prep: the commit carries the signature" "yes" "$(git -C "$ORIGIN" cat-file -e "$BR:MANIFEST.asc" 2>/dev/null && echo yes || echo no)"
check "prep: the commit is signed" "1" "$(git -C "$ORIGIN" cat-file commit "$BR" | grep -c '^gpgsig ')"
check "prep: MANIFEST serial 1" "serial=1" "$(git -C "$ORIGIN" show "$BR:MANIFEST" | grep '^serial=')"
check "prep: the pull request" "gh pr create --base main --head $BR --title release: $TAG --body-file" \
    "$(grep '^gh pr create' "$T/gh.log" | sed 's/--body-file .*/--body-file/')"
check "prep: the body names the serial, the key and the tag" "yes" \
    "$(grep -qF "Script release $TAG: serial 1," "$T/pr-body.md" && grep -qF "release key $FPR1" "$T/pr-body.md" \
        && grep -qF "cut-release.sh tag $TAG" "$T/pr-body.md" && echo yes || echo no)"
check "prep: the tree is clean" "" "$(gitw status --porcelain)"
check "prep: git config untouched" "" "$(gitw config --get user.signingkey; gitw config --get commit.gpgsign; git config --global --get user.signingkey)"

# --- prep again: every step is already done -----------------------------------------------
head_before="$(git -C "$ORIGIN" rev-parse "$BR")"
cut prep "$TAG" --yes
check_rc "prep again: exits 0" 0 "$RC"
for what in "MANIFEST names $TAG" "MANIFEST.asc verifies" "release: $TAG" "origin/$BR is" "https://github.example.invalid/pull/7"; do
    has "prep again: already done: $what" "already done: $what"
done
check "prep again: no new commit" "$head_before" "$(git -C "$ORIGIN" rev-parse "$BR")"
check "prep again: one pull request" "1" "$(grep -c '^gh pr create' "$T/gh.log")"

# --- tag before the merge -----------------------------------------------------------------
cut tag "$TAG" --yes
check_rc "tag before the merge: refused" 1 "$RC"
has "tag before the merge: says why" "origin/main does not carry release $TAG (its MANIFEST names no release): merge the release pull request first"
check "tag before the merge: no tag" "absent" "$(gitw rev-parse -q --verify "refs/tags/$TAG" >/dev/null && echo present || echo absent)"

# --- the merge, then tag -------------------------------------------------------------------
gitw push -q origin "$BR:main" 2>/dev/null
: > "$T/gpg.log"
SERVED_TAG="$TAG" cut tag "$TAG" --yes
check_rc "tag: exits 0" 0 "$RC"
order "tag: the steps in order" "] fetch origin" "] origin/main carries release $TAG" "] make the signed tag" \
    "] verify the tag signature" "] push the tag" "] wait for CI" "] the published installer names $TAG"
has "tag: the check ran on origin/main" "MANIFEST check passed for $TAG (serial 1, min_updater"
check "tag: origin has the tag on main" "$(git -C "$ORIGIN" rev-parse main)" "$(git -C "$ORIGIN" rev-parse "refs/tags/$TAG^{commit}" 2>/dev/null)"
check "tag: the tag is signed" "1" "$(git -C "$ORIGIN" cat-file tag "$TAG" 2>/dev/null | grep -c '^-----BEGIN PGP SIGNATURE-----$')"
check "tag: signed with the release key" "yes" "$(grep -qF -- "-bsau ${FPR1}!" "$T/gpg.log" && echo yes || echo no)"
has "tag: CI conclusion" "   ci.yml: success https://github.example.invalid/run/1"
has "tag: publish conclusion" "   publish-installer.yml: success https://github.example.invalid/run/1"
has "tag: the installer serves the tag" "   https://install.telcoin.network serves $TAG"
check "tag: no temporary worktree left" "1" "$(gitw worktree list | wc -l | tr -d ' ')"

SERVED_TAG="$TAG" cut tag "$TAG" --yes
check_rc "tag again: exits 0" 0 "$RC"
has "tag again: the tag is already there" "already done: $TAG names origin/main"
has "tag again: already pushed" "already done: origin has $TAG"

SERVED_TAG=scripts-v2.0.0 cut tag "$TAG" --yes
check_rc "the installer serves another tag: fails" 1 "$RC"
has "the installer serves another tag: says what it serves" "https://install.telcoin.network serves: readonly TN_SCRIPTS_TAG=\"scripts-v2.0.0\""
GH_RUN="completed failure https://github.example.invalid/run/2" SERVED_TAG="$TAG" cut tag "$TAG" --yes
check_rc "a failed CI run: fails" 1 "$RC"
has "a failed CI run: prints the conclusion" "   ci.yml: failure https://github.example.invalid/run/2"

# --- status --------------------------------------------------------------------------------
cut status
check_rc "status: exits 0" 0 "$RC"
has "status: the release branch" "Release branch: $BR"
has "status: the signature" "signature: MANIFEST.asc verifies (release check passes)"
has "status: the tag" "Release tag: $TAG on "
has "status: the tag signature" "tag signature: good"
has "status: the CI run" "ci.yml: completed success https://github.example.invalid/run/1"

# --- --sig-from a signature over other content: the check refuses, nothing is committed ----
printf 'other content\n' > "$T/other"
gpg --armor --detach-sign --local-user "${FPR1}!" --output "$T/other.asc" "$T/other"
gitw checkout -q main
gitw pull -q --ff-only origin main 2>/dev/null
cut prep scripts-v2.1.1 --sig-from "$T/other.asc" --yes
check_rc "--sig-from a signature over other content: refused" 1 "$RC"
has "--sig-from: the card is not checked" "WARN the card is not checked: the signature comes from $T/other.asc"
has "--sig-from: the check says why" "FAIL MANIFEST.asc does not verify against lib/release-keys: the signature by key ${FPR1:24} does not match MANIFEST"
check "--sig-from: nothing committed" "$(gitw rev-parse origin/main)" "$(gitw rev-parse HEAD)"
check "--sig-from: nothing pushed" "absent" "$(git -C "$ORIGIN" rev-parse -q --verify refs/heads/release/scripts-v2.1.1 >/dev/null && echo present || echo absent)"

finish
