#!/usr/bin/env bash
# =============================================================================
# tools/tests/install_test.sh -- install.sh: pinned tag, embedded signers,
# truncation safety and verification of a signed fixture release
#
#   bash tools/tests/install_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/install_test.sh
#
# Static checks on install.sh, then runs of a tagged copy (TN_SCRIPTS_TAG and
# the signer block rewritten the way tools/release-scripts.sh does) with HOME in
# the temp dir and a curl shim that serves a fixture release archive and logs
# every URL. Signing as in updater_manifest_test.sh (tools/tests/signing.sh).
# No network, no root, nothing outside the temp dir.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
REPO="$TN_TEST_REPO"
INSTALLER="$REPO/install.sh"
BIN="$T/bin"
mkdir -p "$BIN" "$T/archives"

_h() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1"
    else
        shasum -a 256 "$1"
    fi | awk '{print $1}'
}

# --- static checks -------------------------------------------------------------

check "no refs/heads/main in install.sh" "0" "$(grep -c 'refs/heads/main' "$INSTALLER")"
check "last line calls main" 'main "$@"' "$(tail -n 1 "$INSTALLER")"
check "one main call" "1" "$(grep -c '^main "\$@"$' "$INSTALLER")"
embedded="$(awk -v q="'" '
    $0 == "TN_ALLOWED_SIGNERS" { inblock = 0 }
    inblock { print }
    index($0, "<<" q "TN_ALLOWED_SIGNERS" q) { inblock = 1 }
' "$INSTALLER")"
check "embedded signers identical to lib/allowed_signers" "$(cat "$REPO/lib/allowed_signers")" "$embedded"
# A curl or wget in command position (line start, or after ; & | ( or $( ).
check "curl runs only https-only" "" "$(grep -nE '(^|[;&|(])[[:space:]]*curl ' "$INSTALLER" | grep -v -- "--proto '=https' --tlsv1.2")"
check "wget runs only https-only" "" "$(grep -nE '(^|[;&|(])[[:space:]]*wget ' "$INSTALLER" | grep -v -- '--https-only')"
check "curl and wget each run once" "2" "$(grep -cE '(^|[;&|(])[[:space:]]*(curl|wget) ' "$INSTALLER")"
check "top level runs nothing but set, readonly and definitions" "" "$(awk '
    /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ { infn = 1 }
    infn && /^\}/ { infn = 0; next }
    infn { next }
    /^(#|$)/ { next }
    /^set -euo pipefail$/ { next }
    /^readonly [A-Z_]+=/ { next }
    /^main "\$@"$/ { next }
    { print NR ": " $0 }
' "$INSTALLER")"

# --- shims ----------------------------------------------------------------------

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
echo "\$url" >> "$T/curl.log"
case "\$url" in
    $ARCHIVE_URL_BASE/*.tar.gz) f="$T/archives/\${url##*/}" ;;
    *) exit 6 ;;
esac
[ -f "\$f" ] || exit 22
if [ -n "\$out" ]; then cp "\$f" "\$out"; else cat "\$f"; fi
EOF
for tool in git wget; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/curl.log"\nexit 1\n' "$tool" "$T" > "$BIN/$tool"
done
chmod +x "$BIN/curl" "$BIN/git" "$BIN/wget"

# shellcheck source=tools/tests/signing.sh
. "$TN_TEST_DIR/signing.sh"
export PATH="$BIN:$PATH"
KEY1_LINE="$(newkey key1)"
newkey key2 >/dev/null

if [[ $REAL_SSH -eq 1 ]]; then
    check "signer: real ssh-keygen in use" "1" "$REAL_SSH"
else
    skip "real ssh-keygen signatures" "ssh-keygen absent: a fake signer stands in"
fi

# tagged_installer TAG SIGNERS_FILE OUT -- install.sh with the tag and signer
# block written in, as tools/release-scripts.sh does at release time.
tagged_installer() {
    awk -v tag="$1" -v sf="$2" -v q="'" '
        /^readonly TN_SCRIPTS_TAG=/ { print "readonly TN_SCRIPTS_TAG=\"" tag "\""; next }
        skipping && $0 == "TN_ALLOWED_SIGNERS" { skipping = 0 }
        skipping { next }
        { print }
        index($0, "<<" q "TN_ALLOWED_SIGNERS" q) {
            while ((getline line < sf) > 0) print line
            close(sf)
            skipping = 1
        }
    ' "$INSTALLER" > "$3"
}

# make_release TAG SERIAL DIR -- a release tree in DIR with MANIFEST, signed
# with key1; extra files not in MANIFEST stand in for docs and tools.
make_release() {
    local d="$3" p
    mkdir -p "$d/lib" "$d/ui" "$d/tools"
    cp "$REPO/update-scripts.sh" "$d/update-scripts.sh"
    printf '# test signers\n%s\n' "$KEY1_LINE" > "$d/lib/allowed_signers"
    printf '#!/usr/bin/env bash\necho setup\n' > "$d/setup-node.sh"
    printf 'UI_VERSION = "1.0.0"\n' > "$d/ui/server.py"
    printf 'docs\n' > "$d/README.md"
    printf '#!/usr/bin/env bash\n' > "$d/tools/unlisted.sh"
    {
        printf 'format=1\nrelease=%s\nserial=%s\nmin_updater=1.0.0\n' "$1" "$2"
        for p in lib/allowed_signers setup-node.sh ui/server.py update-scripts.sh; do
            printf 'sha256  %s  %s\n' "$(_h "$d/$p")" "$p"
        done
    } > "$d/MANIFEST"
    sign_file "$d/MANIFEST" key1
}

# pack DIR TAG -- serve DIR as the archive of TAG (top directory like GitHub's).
pack() {
    local top="tn-node-deployment-$2"
    rm -rf "${T:?}/pack"
    mkdir -p "$T/pack"
    cp -R "$1" "$T/pack/$top"
    (cd "$T/pack" && tar -czf "$T/archives/$2.tar.gz" "$top")
}

HOME_DIR="$T/home"
# run_installer COPY [ARGS...] -- run COPY with HOME in the temp dir.
run_installer() {
    local copy="$1"
    shift
    : > "$T/curl.log"
    OUT="$(HOME="$HOME_DIR" TERM=dumb bash "$copy" "$@" < /dev/null 2>&1)"
    RC=$?
}
staged_left() {
    find "$HOME_DIR" -maxdepth 1 -name '.telcoin-node-scripts.*' | wc -l | tr -d ' '
}

TAG=scripts-v1.0.0
SIGNERS="$T/signers"
printf '# test signers\n%s\n' "$KEY1_LINE" > "$SIGNERS"
GOOD="$T/install-good.sh"
tagged_installer "$TAG" "$SIGNERS" "$GOOD"
REL="$T/rel"
make_release "$TAG" 100 "$REL"
pack "$REL" "$TAG"

# --- the repository copy names no release -------------------------------------
mkdir -p "$HOME_DIR"
run_installer "$INSTALLER"
check_rc "untagged copy: exits 1" 1 "$RC"
check "untagged copy: no download" "" "$(cat "$T/curl.log")"
check "untagged copy: nothing installed" "absent" "$([[ -e "$HOME_DIR/telcoin-node-scripts" ]] && echo present || echo absent)"

# --- truncated downloads run nothing --------------------------------------------
# Every prefix that stops before the last line, at 37-byte steps, plus the copy
# without its last five lines.
size="$(wc -c < "$GOOD" | tr -d ' ')"
last="$(tail -n 1 "$GOOD" | wc -c | tr -d ' ')"
limit=$((size - last))
bad_prefix=""
n=1
while [[ $n -le $limit ]]; do
    head -c "$n" "$GOOD" > "$T/trunc.sh"
    : > "$T/curl.log"
    HOME="$HOME_DIR" TERM=dumb bash "$T/trunc.sh" --yes < /dev/null > /dev/null 2>&1
    if [[ -s "$T/curl.log" || -e "$HOME_DIR/telcoin-node-scripts" || "$(staged_left)" != "0" ]]; then
        bad_prefix="$bad_prefix $n"
        rm -rf "${HOME_DIR:?}/telcoin-node-scripts"
    fi
    n=$((n + 37))
done
check "truncated prefixes: none downloads or installs" "" "$bad_prefix"
lines="$(wc -l < "$GOOD" | tr -d ' ')"
head -n "$((lines - 5))" "$GOOD" > "$T/trunc5.sh"
run_installer "$T/trunc5.sh" --yes
check "copy without its last 5 lines: no download" "" "$(cat "$T/curl.log")"
check "copy without its last 5 lines: nothing installed" "absent" "$([[ -e "$HOME_DIR/telcoin-node-scripts" ]] && echo present || echo absent)"

# --- good install ------------------------------------------------------------------
run_installer "$GOOD"
check_rc "good: exits 0" 0 "$RC"
DEST="$HOME_DIR/telcoin-node-scripts"
check "good: listed files and the record, nothing else" "$(printf '%s\n' MANIFEST MANIFEST.sig lib/allowed_signers setup-node.sh ui/server.py update-scripts.sh)" \
    "$(cd "$DEST" 2>/dev/null && find . -type f | sed 's|^\./||' | LC_ALL=C sort)"
check "good: setup-node.sh verified copy" "$(_h "$REL/setup-node.sh")" "$(_h "$DEST/setup-node.sh" 2>/dev/null)"
check "good: scripts executable" "yes" "$([[ -x "$DEST/setup-node.sh" && -x "$DEST/update-scripts.sh" ]] && echo yes || echo no)"
check "good: fetched only the tag archive" "$ARCHIVE_URL_BASE/$TAG.tar.gz" "$(cat "$T/curl.log")"
check "good: no staging dir left" "0" "$(staged_left)"

# expect_refusal NAME COPY -- exits 1, the existing install is untouched.
expect_refusal() {
    local before
    before="$(cd "$DEST" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(_h "$f")" "$f"; done)"
    run_installer "$2" --yes
    check_rc "$1: exits 1" 1 "$RC"
    check "$1: existing install untouched" "$before" \
        "$(cd "$DEST" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(_h "$f")" "$f"; done)"
    check "$1: no staging dir left" "0" "$(staged_left)"
}

# --- a tampered file -----------------------------------------------------------------
X="$T/rel-tampered"
cp -R "$REL" "$X"
printf 'echo owned\n' >> "$X/setup-node.sh"
pack "$X" "$TAG"
expect_refusal "tampered file" "$GOOD"

# --- signed by a key the installer does not list ------------------------------------------
W="$T/rel-wrong"
cp -R "$REL" "$W"
sign_file "$W/MANIFEST" key2
pack "$W" "$TAG"
expect_refusal "wrong signer" "$GOOD"

# --- a signed manifest for another release ---------------------------------------------
O="$T/rel-other"
make_release scripts-v0.9.0 90 "$O"
pack "$O" "$TAG"
expect_refusal "manifest for another release" "$GOOD"

# --- no MANIFEST.sig -----------------------------------------------------------------
Z="$T/rel-nosig"
cp -R "$REL" "$Z"
rm -f "$Z/MANIFEST.sig"
pack "$Z" "$TAG"
expect_refusal "unsigned release" "$GOOD"

# --- an installer with no key lines ----------------------------------------------------
printf '# no keys\n' > "$T/nokeys"
tagged_installer "$TAG" "$T/nokeys" "$T/install-nokeys.sh"
pack "$REL" "$TAG"
expect_refusal "installer without keys" "$T/install-nokeys.sh"

finish
