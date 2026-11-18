#!/usr/bin/env bash
# =============================================================================
# tools/tests/release_keys_test.sh -- tools/check-release-keys.sh on fixtures
# and on the tree
#
#   bash tools/tests/release_keys_test.sh
#
# A fixture superproject records a fixture tn-release-signing as its submodule
# at vendor/tn-release-signing. The check passes on exact copies of its
# keys/*.asc and fails on a changed byte, a missing, an extra or a symlinked
# key file; it reads the commit the index records from the submodule's object
# store, so edits to the submodule's checkout and a checkout at another commit
# change nothing until the pointer is staged; it cannot run (exit 2) without
# git, outside a work tree, below its top, with no gitlink, or with the
# submodule not initialized or lacking the commit. Last, the tree itself:
# lib/release-keys must match vendor/tn-release-signing (skipped where git or
# the submodule is unavailable; CI's "checksum freshness" job runs the check
# with the submodule checked out). The whole test is skipped without git.
# bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SH="${BASH:-bash}"
TOOL="$TN_TEST_REPO/tools/check-release-keys.sh"
T="$TN_TEST_TMP"
SUB="vendor/tn-release-signing"

if ! command -v git >/dev/null 2>&1; then
    skip "check-release-keys on fixtures and on the tree" "git is not installed"
    finish
fi

# The tree first, before HOME and the git configuration move into the temp
# dir: a maintainer's checkout reads its submodule the usual way.
OUT="$("$SH" "$TOOL" "$TN_TEST_REPO" 2>&1)"
RC=$?
case "$RC" in
    0) check "the tree: lib/release-keys matches tn-release-signing at the recorded commit" "0" "$RC" ;;
    2) skip "the tree: lib/release-keys matches tn-release-signing" "$(printf '%s' "$OUT" | head -n 1)" ;;
    *) check "the tree: lib/release-keys matches tn-release-signing at the recorded commit" "0" "$RC: $OUT" ;;
esac

# From here on the user's git configuration is not read.
export HOME="$T/home"
export XDG_CONFIG_HOME="$T/home/.config"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$T/home/.gitconfig"
mkdir -p "$HOME"
cat > "$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
	name = fixture
	email = fixture@example.invalid
[commit]
	gpgsign = false
[init]
	defaultBranch = main
[advice]
	detachedHead = false
EOF

# run [ROOT] -- the tool on ROOT (default the fixture superproject); OUT and RC
# get its output and status.
run() {
    OUT="$("$SH" "$TOOL" "${1:-$P}" 2>&1)"
    RC=$?
}

# --- the fixtures -------------------------------------------------------------
# S: tn-release-signing with two keys (one capitalised, as MavenRain.asc is)
# and a README in keys/. P: the superproject, its lib/release-keys a copy.
S="$T/sign"
P="$T/super"
git init -q "$S"
mkdir -p "$S/keys"
printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nalpha\n-----END PGP PUBLIC KEY BLOCK-----\n' > "$S/keys/alpha.asc"
printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nBeta\n-----END PGP PUBLIC KEY BLOCK-----\n' > "$S/keys/Beta.asc"
printf 'the keys\n' > "$S/keys/README.md"
git -C "$S" add -A && git -C "$S" commit -q -m one
S1="$(git -C "$S" rev-parse HEAD)"
printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nalpha, extended\n-----END PGP PUBLIC KEY BLOCK-----\n' > "$S/keys/alpha.asc"
git -C "$S" commit -q -a -m two
S2="$(git -C "$S" rev-parse HEAD)"

git init -q "$P"
mkdir -p "$P/lib/release-keys" "$P/vendor"
git clone -q "$S" "$P/$SUB"
git -C "$P/$SUB" checkout -q "$S1"
git -C "$S" show "$S1:keys/alpha.asc" > "$P/lib/release-keys/alpha.asc"
git -C "$S" show "$S1:keys/Beta.asc" > "$P/lib/release-keys/Beta.asc"
printf 'release keys\n' > "$P/lib/release-keys/README"
git -C "$P" add lib && git -C "$P" update-index --add --cacheinfo "160000,$S1,$SUB" \
    && git -C "$P" commit -q -m fixture
check "fixture: the superproject records the submodule at the first commit" \
    "160000 $S1" "$(git -C "$P" ls-files --stage -- "$SUB" | awk '{ print $1, $2 }')"

# --- exact copies pass ----------------------------------------------------------
run
check_rc "exact copies: exit 0" 0 "$RC"
check "exact copies: names the commit and the keys" \
    "check-release-keys: lib/release-keys/*.asc are the keys/*.asc of tn-release-signing at $S1 (Beta.asc alpha.asc)" "$OUT"
check "without ROOT: the repository the tool lives in, not the current directory" \
    "$("$SH" "$TOOL" "$TN_TEST_REPO" 2>&1; echo "rc=$?")" "$(cd "$P" && "$SH" "$TOOL" 2>&1; echo "rc=$?")"

# --- drift fails ----------------------------------------------------------------
cp "$P/lib/release-keys/alpha.asc" "$T/alpha.keep"
awk '{ printf "%s\r\n", $0 }' "$T/alpha.keep" > "$P/lib/release-keys/alpha.asc"
run
check_rc "a copy with CR line endings: exit 1" 1 "$RC"
check_has "a copy with CR line endings: says which" \
    "differs: lib/release-keys/alpha.asc (not a byte-for-byte copy of keys/alpha.asc at ${S1:0:12})" "$OUT"
check_has "a copy with CR line endings: says what to do" \
    "check-release-keys: lib/release-keys/*.asc are not the keys/*.asc of tn-release-signing at $S1; copy them as lib/release-keys/README says (Adding or removing a key)" "$OUT"
sed 's/alpha/alphb/' "$T/alpha.keep" > "$P/lib/release-keys/alpha.asc"
run
check_rc "one changed byte: exit 1" 1 "$RC"
check_has "one changed byte: says which" \
    "differs: lib/release-keys/alpha.asc (not a byte-for-byte copy of keys/alpha.asc at ${S1:0:12})" "$OUT"
cp "$T/alpha.keep" "$P/lib/release-keys/alpha.asc"

mv "$P/lib/release-keys/Beta.asc" "$T/beta.keep"
run
check_rc "a key file missing: exit 1" 1 "$RC"
check_has "a key file missing: says which" \
    "missing: lib/release-keys/Beta.asc (keys/Beta.asc is in tn-release-signing at ${S1:0:12})" "$OUT"
cp "$T/beta.keep" "$P/lib/release-keys/beta.asc"
run
check_rc "a key file renamed (case): exit 1" 1 "$RC"
check "a key file renamed (case): missing and extra" \
    "$(printf '%s\n' "missing: lib/release-keys/Beta.asc (keys/Beta.asc is in tn-release-signing at ${S1:0:12})" \
        "extra: lib/release-keys/beta.asc (no keys/beta.asc in tn-release-signing at ${S1:0:12})")" \
    "$(printf '%s\n' "$OUT" | grep -E '^(missing|extra):')"
rm -f "$P/lib/release-keys/beta.asc"
mv "$T/beta.keep" "$P/lib/release-keys/Beta.asc"

cp "$T/alpha.keep" "$P/lib/release-keys/gamma.asc"
run
check_rc "an extra key file: exit 1" 1 "$RC"
check_has "an extra key file: says which" \
    "extra: lib/release-keys/gamma.asc (no keys/gamma.asc in tn-release-signing at ${S1:0:12})" "$OUT"
rm -f "$P/lib/release-keys/gamma.asc"

mv "$P/lib/release-keys/alpha.asc" "$P/alpha.real"
ln -s ../../alpha.real "$P/lib/release-keys/alpha.asc"
run
check_rc "a symlinked key file: exit 1" 1 "$RC"
check_has "a symlinked key file: says which" "not a regular file: lib/release-keys/alpha.asc" "$OUT"
rm -f "$P/lib/release-keys/alpha.asc"
mv "$P/alpha.real" "$P/lib/release-keys/alpha.asc"
run
check_rc "restored: exit 0" 0 "$RC"

# --- the object store at the recorded commit, not the checkout -----------------
printf 'edited\n' >> "$P/$SUB/keys/alpha.asc"
rm -f "$P/$SUB/keys/Beta.asc"
run
check_rc "submodule checkout edited: still exit 0" 0 "$RC"
git -C "$P/$SUB" checkout -q -f "$S2"
run
check_rc "submodule checked out at another commit, pointer not staged: still exit 0" 0 "$RC"
git -C "$P" add "$SUB"
run
check_rc "pointer moved and staged, keys not copied: exit 1" 1 "$RC"
check_has "pointer moved and staged: says which" \
    "differs: lib/release-keys/alpha.asc (not a byte-for-byte copy of keys/alpha.asc at ${S2:0:12})" "$OUT"
git -C "$P/$SUB" cat-file blob "$S2:keys/alpha.asc" > "$P/lib/release-keys/alpha.asc"
run
check_rc "pointer moved and keys copied: exit 0" 0 "$RC"
check_has "pointer moved and keys copied: names the new commit" \
    "check-release-keys: lib/release-keys/*.asc are the keys/*.asc of tn-release-signing at $S2 (Beta.asc alpha.asc)" "$OUT"
git -C "$P" add -A && git -C "$P" commit -q -m "move the pointer"

# --- cannot run: exit 2 ---------------------------------------------------------
git clone -q "$P" "$T/clone"
run "$T/clone"
check_rc "submodule not initialized: exit 2" 2 "$RC"
check "submodule not initialized: says how to fix it" \
    "check-release-keys: the submodule $SUB is not initialized: run git submodule update --init -- $SUB" "$OUT"

git -C "$P" update-index --cacheinfo "160000,0123456789abcdef0123456789abcdef01234567,$SUB"
run
check_rc "submodule lacks the recorded commit: exit 2" 2 "$RC"
check "submodule lacks the recorded commit: says how to fix it" \
    "check-release-keys: the submodule $SUB lacks commit 0123456789abcdef0123456789abcdef01234567, which the index records: run git submodule update --init -- $SUB" "$OUT"
git -C "$P" update-index --cacheinfo "160000,$S2,$SUB"

git init -q "$T/nolink"
run "$T/nolink"
check_rc "no gitlink: exit 2" 2 "$RC"
check "no gitlink: says so" "check-release-keys: the index records no submodule at $SUB" "$OUT"

mkdir -p "$T/plain"
run "$T/plain"
check_rc "not a git work tree: exit 2" 2 "$RC"
run "$P/lib"
check_rc "below the top of the work tree: exit 2" 2 "$RC"
check "below the top of the work tree: says so" "check-release-keys: $P/lib is not the top of its git work tree" "$OUT"
OUT="$("$SH" "$TOOL" --bogus 2>&1)"
check_rc "unknown option: exit 2" 2 "$?"
OUT="$("$SH" "$TOOL" "$P" "$P" 2>&1)"
check_rc "two ROOTs: exit 2" 2 "$?"

run
check_rc "the fixture is whole again: exit 0" 0 "$RC"

finish
