#!/usr/bin/env bash
# =============================================================================
# tools/tests/release_scripts_test.sh -- tools/release-scripts.sh on a copy of
# this repository, then install.sh on the release it produced
#
#   bash tools/tests/release_scripts_test.sh
#
# Copies the tracked files into a temp git repository, prepares a release
# there, signs it with a throwaway key (tools/tests/signing.sh), checks it,
# and installs it with the install.sh the tool wrote, through a curl shim that
# serves the release archive. Needs git and tar; without git (the bash:3.2
# image) the whole file is SKIP. No network, nothing outside the temp dir.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
REPO="$TN_TEST_REPO"
BIN="$T/bin"
W="$T/repo"
mkdir -p "$BIN" "$W" "$T/archives"

if ! command -v git >/dev/null 2>&1 || ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    skip "release-scripts.sh" "git absent or not a git checkout"
    finish
fi

_h() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1"
    else
        shasum -a 256 "$1"
    fi | awk '{print $1}'
}

# shellcheck source=tools/tests/signing.sh
. "$TN_TEST_DIR/signing.sh"
export PATH="$BIN:$PATH"
KEY1_LINE="$(newkey key1)"

gitc() {
    git -C "$W" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "$@"
}
commit_all() {
    gitc add -A >/dev/null && gitc commit -q -m "$1" >/dev/null
}
# tool ARGS... -- run the copy's release tool; OUT and RC get its output and status.
tool() {
    OUT="$(cd "$W" && bash tools/release-scripts.sh "$@" 2>&1)"
    RC=$?
}

(cd "$REPO" && git ls-files | tar -cf - -T -) | tar -xf - -C "$W"
git -C "$W" init -q
commit_all "fixture"

# --- refusals before the tree is ready ---------------------------------------
tool scripts-v2.0.0 --serial 200
check_rc "no key yet: refused" 1 "$RC"
check_has "no key yet: says why" "release-scripts.sh: lib/allowed_signers lists no key: add the release signer public key line first" "$OUT"

printf '%s\n' "$KEY1_LINE" >> "$W/lib/allowed_signers"
commit_all "add key"
tool scripts-v2.0.0 --serial 200
check_rc "signer list without sidecar: refused" 1 "$RC"
check_has "signer list without sidecar: says why" "release-scripts.sh: stale or missing sidecar: lib/allowed_signers.sha256" "$OUT"

# What release prep does: the signer list joins an updater array, sidecars refreshed.
awk '{ print } /^declare -a SCRIPTS=\(/ { print "    \"lib/allowed_signers:lib/allowed_signers:NONE\"" }' \
    "$W/update-scripts.sh" > "$T/us" && cat "$T/us" > "$W/update-scripts.sh"
(cd "$W" && bash tools/gen-checksums.sh >/dev/null)
commit_all "track signers"

printf 'dirty\n' >> "$W/README.md"
tool scripts-v2.0.0 --serial 200
check_rc "dirty tree: refused" 1 "$RC"
gitc checkout -q -- README.md

tool scripts-v2
check_rc "bad tag: refused" 1 "$RC"
tool scripts-v2.0.0
check_rc "first release without --serial: refused" 1 "$RC"
tool scripts-v2.0.0 --serial 200 --min-updater 99.0.0
check_rc "min_updater above the tree updater: refused" 1 "$RC"

# --- prepare -------------------------------------------------------------------
tool scripts-v2.0.0 --serial 200 --date 2026-10-15
check_rc "prepare: exits 0" 0 "$RC"
check_has "prepare: prints the signing command" "       ssh-keygen -Y sign -f ~/.ssh/id_ed25519_sk -n tn-node-scripts MANIFEST" "$OUT"
uver="$(sed -n 's/^readonly SCRIPT_VERSION="\([0-9.]*\)"$/\1/p' "$W/update-scripts.sh")"
check "prepare: header" "$(printf 'format=1\nrelease=scripts-v2.0.0\nserial=200\nmin_updater=%s' "$uver")" "$(head -n 4 "$W/MANIFEST")"
check "prepare: RELEASE" "scripts-v2.0.0 2026-10-15" "$(cat "$W/RELEASE")"
check "prepare: installer tag" 'readonly TN_SCRIPTS_TAG="scripts-v2.0.0"   # written by tools/release-scripts.sh' "$(grep '^readonly TN_SCRIPTS_TAG=' "$W/install.sh")"
check "prepare: installer still ends with main" 'main "$@"' "$(tail -n 1 "$W/install.sh")"
check "prepare: installer parses" "0" "$(bash -n "$W/install.sh" 2>&1; echo $?)"
embedded="$(awk -v q="'" '
    $0 == "TN_ALLOWED_SIGNERS" { inblock = 0 }
    inblock { print }
    index($0, "<<" q "TN_ALLOWED_SIGNERS" q) { inblock = 1 }
' "$W/install.sh")"
check "prepare: installer carries the signer list" "$(cat "$W/lib/allowed_signers")" "$embedded"
paths="$(awk '/^sha256  / {print $3}' "$W/MANIFEST")"
check "prepare: paths sorted and unique" "$(printf '%s\n' "$paths" | LC_ALL=C sort -u)" "$paths"
for p in install.sh open-ui.sh lib/allowed_signers update-scripts.sh lib/common.sh ui/server.py observability/config.alloy; do
    check_has "prepare: lists $p" "$p" "$paths"
done
bad=""
while IFS= read -r line; do
    p="$(printf '%s\n' "$line" | awk '{print $3}')"
    [[ "$(printf '%s\n' "$line" | awk '{print $2}')" == "$(_h "$W/$p")" ]] || bad="$bad $p"
done < <(grep '^sha256  ' "$W/MANIFEST")
check "prepare: every hash matches the file" "" "$bad"
check "prepare: no signature yet" "absent" "$([[ -e "$W/MANIFEST.sig" ]] && echo present || echo absent)"

# --- check -------------------------------------------------------------------------
tool --check
check_rc "check unsigned: passes with a warning" 0 "$RC"
tool --check --tag scripts-v2.0.0
check_rc "check --tag unsigned: fails" 1 "$RC"
sign_file "$W/MANIFEST" key1
tool --check --tag scripts-v2.0.0
check_rc "check --tag signed: passes" 0 "$RC"
tool --check --tag scripts-v2.0.1
check_rc "check with another tag: fails" 1 "$RC"
cp "$W/setup-node.sh" "$T/setup-node.sh.keep"
printf '# edited after signing\n' >> "$W/setup-node.sh"
tool --check
check_rc "check after an edit: fails" 1 "$RC"
cat "$T/setup-node.sh.keep" > "$W/setup-node.sh"
newkey key2 >/dev/null
sign_file "$W/MANIFEST" key2
tool --check
check_rc "check with a foreign signature: fails" 1 "$RC"
sign_file "$W/MANIFEST" key1
commit_all "Release scripts-v2.0.0"

# --- install the release with the installer the tool wrote ---------------------------
ARCHIVE_URL_BASE="https://github.com/Telcoin-Association/tn-node-deployment/archive/refs/tags"
cat > "$BIN/curl" <<EOF
#!/bin/sh
out="" url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift ;;
        --proto|--max-time) shift ;;
        https://*) url="\$1" ;;
    esac
    shift
done
case "\$url" in
    $ARCHIVE_URL_BASE/*.tar.gz) f="$T/archives/\${url##*/}" ;;
    *) exit 6 ;;
esac
[ -f "\$f" ] || exit 22
cp "\$f" "\$out"
EOF
chmod +x "$BIN/curl"
gitc archive --format=tar.gz --prefix=tn-node-deployment-scripts-v2.0.0/ -o "$T/archives/scripts-v2.0.0.tar.gz" HEAD
mkdir -p "$T/home"
OUT="$(HOME="$T/home" TERM=dumb bash "$W/install.sh" < /dev/null 2>&1)"
RC=$?
check_rc "install the prepared release: exits 0" 0 "$RC"
check "install: every MANIFEST file present" "$(printf '%s\n' "$paths" | wc -l | tr -d ' ')" \
    "$(cd "$T/home/telcoin-node-scripts" 2>/dev/null && printf '%s\n' "$paths" | while IFS= read -r p; do [[ -f "$p" ]] && echo "$p"; done | wc -l | tr -d ' ')"

# --- next release: serial defaults to the previous + 1 --------------------------------------
printf '# next\n' >> "$W/open-ui.sh"
commit_all "change"
tool scripts-v2.0.1 --serial 200
check_rc "next release with a serial not above 200: refused" 1 "$RC"
tool scripts-v2.0.1 --date 2026-10-16
check_rc "next release: exits 0" 0 "$RC"
check "next release: serial 201" "serial=201" "$(grep '^serial=' "$W/MANIFEST")"
check "next release: old signature removed" "absent" "$([[ -e "$W/MANIFEST.sig" ]] && echo present || echo absent)"

finish
