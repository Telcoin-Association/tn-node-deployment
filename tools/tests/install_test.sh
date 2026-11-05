#!/usr/bin/env bash
# =============================================================================
# tools/tests/install_test.sh -- install.sh: pinned tag, embedded release keys,
# truncation safety and verification of a signed fixture release
#
#   bash tools/tests/install_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/install_test.sh
#
# Static checks on install.sh, then runs of a tagged copy (TN_SCRIPTS_TAG and
# the release key block rewritten the way tools/release-scripts.sh does) with
# HOME in the temp dir and a curl shim that serves a fixture release archive and
# logs every URL. Signing as in updater_manifest_test.sh (tools/tests/signing.sh:
# real gpg, or a fake gpg and gpgv where GnuPG is absent).
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
    $0 == "TN_RELEASE_KEYS" { inblock = 0 }
    inblock { print }
    index($0, "<<" q "TN_RELEASE_KEYS" q) { inblock = 1 }
' "$INSTALLER")"
check "embedded release keys identical to lib/release-keys/*.asc, in name order" \
    "$(for f in $(cd "$REPO" && ls lib/release-keys/*.asc | LC_ALL=C sort); do cat "$REPO/$f"; done)" "$embedded"
check "needs gpgv, not ssh" "0" "$(grep -c 'ssh-''keygen' "$INSTALLER")"
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
FPR1="$(newkey key1)"
FPR2="$(newkey key2)"
newkey kexp --expired >/dev/null

if [[ $REAL_GPG -eq 1 ]]; then
    check "signer: real gpg and gpgv in use" "1" "$REAL_GPG"
else
    skip "real OpenPGP signatures" "gpg absent: a fake gpg and gpgv stand in"
fi

# tagged_installer TAG KEYS_FILE OUT -- install.sh with the tag and the release
# key block written in, as tools/release-scripts.sh does at release time.
tagged_installer() {
    awk -v tag="$1" -v sf="$2" -v q="'" '
        /^readonly TN_SCRIPTS_TAG=/ { print "readonly TN_SCRIPTS_TAG=\"" tag "\""; next }
        skipping && $0 == "TN_RELEASE_KEYS" { skipping = 0 }
        skipping { next }
        { print }
        index($0, "<<" q "TN_RELEASE_KEYS" q) {
            while ((getline line < sf) > 0) print line
            close(sf)
            skipping = 1
        }
    ' "$INSTALLER" > "$3"
}

# make_release TAG SERIAL DIR [HEADER...] -- a release tree in DIR with
# MANIFEST (HEADER lines after min_updater=), signed with key1; extra files not
# in MANIFEST stand in for docs and tools.
make_release() {
    local d="$3" p
    mkdir -p "$d/lib/release-keys" "$d/ui" "$d/tools"
    cp "$REPO/update-scripts.sh" "$d/update-scripts.sh"
    cp "$T/key1.asc" "$d/lib/release-keys/key1.asc"
    printf '#!/usr/bin/env bash\necho setup\n' > "$d/setup-node.sh"
    printf 'UI_VERSION = "1.0.0"\n' > "$d/ui/server.py"
    printf 'docs\n' > "$d/README.md"
    printf '#!/usr/bin/env bash\n' > "$d/tools/unlisted.sh"
    {
        printf 'format=1\nrelease=%s\nserial=%s\nmin_updater=1.0.0\n' "$1" "$2"
        if [[ $# -gt 3 ]]; then printf '%s\n' "${@:4}"; fi
        for p in lib/release-keys/key1.asc setup-node.sh ui/server.py update-scripts.sh; do
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
GOOD="$T/install-good.sh"
tagged_installer "$TAG" "$T/key1.asc" "$GOOD"
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
check "good: listed files and the record, nothing else" "$(printf '%s\n' MANIFEST MANIFEST.asc lib/release-keys/key1.asc setup-node.sh ui/server.py update-scripts.sh)" \
    "$(cd "$DEST" 2>/dev/null && find . -type f | sed 's|^\./||' | LC_ALL=C sort)"
check_has "good: names the release key" "  [OK]  Release signature verified (release key ${FPR1})" "$(printf '%s\n' "$OUT" | sed "s/$(printf '\033')\[[0-9;]*m//g")"
check "good: setup-node.sh verified copy" "$(_h "$REL/setup-node.sh")" "$(_h "$DEST/setup-node.sh" 2>/dev/null)"
check "good: scripts executable" "yes" "$([[ -x "$DEST/setup-node.sh" && -x "$DEST/update-scripts.sh" ]] && echo yes || echo no)"
check "good: fetched only the tag archive" "$ARCHIVE_URL_BASE/$TAG.tar.gz" "$(cat "$T/curl.log")"
check "good: no staging dir left" "0" "$(staged_left)"

# --- over an existing install ----------------------------------------------------------
printf 'operator edit\n' >> "$DEST/setup-node.sh"
run_installer "$GOOD" --yes
check_rc "reinstall: exits 0" 0 "$RC"
check "reinstall: setup-node.sh is the release copy" "$(_h "$REL/setup-node.sh")" "$(_h "$DEST/setup-node.sh" 2>/dev/null)"
check "reinstall: no staging or moved-aside dir left" "0" "$(staged_left)"

# A mv shim that fails when its first argument matches the pattern in MVFAIL.
REAL_MV="$(type -P mv)"  # the path, never a function of that name
mkdir -p "$T/mvbin"
cat > "$T/mvbin/mv" <<EOF
#!/bin/sh
case "\$1" in \$MVFAIL) echo "mv: refused by the test" >&2; exit 1 ;; esac
exec $REAL_MV "\$@"
EOF
chmod +x "$T/mvbin/mv"
# run_mvfail PATTERN -- run the good installer with --yes over the existing
# install, with mv failing for a source matching PATTERN.
run_mvfail() {
    local before path_was="$PATH"
    before="$(cd "$DEST" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(_h "$f")" "$f"; done)"
    PATH="$T/mvbin:$PATH"
    MVFAIL="$1" run_installer "$GOOD" --yes
    PATH="$path_was"
    AFTER_SAME="$([[ "$before" == "$(cd "$DEST" 2>/dev/null && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(_h "$f")" "$f"; done)" ]] && echo yes || echo no)"
}
export MVFAIL=""

# --- the verified tree cannot be moved in: the existing install is put back -------------
run_mvfail '*/tree'
check_rc "new tree not moved in: exits 1" 1 "$RC"
check "new tree not moved in: existing install put back as it was" "yes" "$AFTER_SAME"
check "new tree not moved in: no staging or moved-aside dir left" "0" "$(staged_left)"
check "new tree not moved in: says so" "yes" "$(printf '%s\n' "$OUT" | grep -qF "was put back as it was" && echo yes || echo no)"

# --- the existing install cannot be moved aside: nothing changes --------------------------
run_mvfail "$DEST"
check_rc "existing install not moved aside: exits 1" 1 "$RC"
check "existing install not moved aside: untouched" "yes" "$AFTER_SAME"
check "existing install not moved aside: no staging or moved-aside dir left" "0" "$(staged_left)"
check "existing install not moved aside: says so" "yes" "$(printf '%s\n' "$OUT" | grep -qF "aside; nothing was changed" && echo yes || echo no)"

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

# --- no MANIFEST.asc -----------------------------------------------------------------
Z="$T/rel-nosig"
cp -R "$REL" "$Z"
rm -f "$Z/MANIFEST.asc"
pack "$Z" "$TAG"
expect_refusal "unsigned release" "$GOOD"
check_has "unsigned release: says why" "  [ERROR] The release $TAG has no MANIFEST.asc." "$(printf '%s\n' "$OUT" | sed "s/$(printf '\033')\[[0-9;]*m//g")"

# --- the MANIFEST changed after signing --------------------------------------------------
X2="$T/rel-badsig"
cp -R "$REL" "$X2"
printf 'note=changed after signing\n' >> "$X2/MANIFEST"
pack "$X2" "$TAG"
expect_refusal "MANIFEST changed after signing" "$GOOD"
check_has "MANIFEST changed after signing: says why" "  [ERROR] The release signature does not verify against the Telcoin release keys (the signature by key ${FPR1:24} does not match MANIFEST: one of the two was changed). Nothing was installed." \
    "$(printf '%s\n' "$OUT" | sed "s/$(printf '\033')\[[0-9;]*m//g")"

# --- a manifest that lists no release key --------------------------------------------------
NK="$T/rel-nokey"
cp -R "$REL" "$NK"
grep -v '  lib/release-keys/key1\.asc$' "$REL/MANIFEST" > "$NK/MANIFEST"
sign_file "$NK/MANIFEST" key1
pack "$NK" "$TAG"
expect_refusal "no release key listed" "$GOOD"
check_has "no release key listed: says why" "  [ERROR] MANIFEST does not list a release key (lib/release-keys/*.asc)." "$(printf '%s\n' "$OUT" | sed "s/$(printf '\033')\[[0-9;]*m//g")"

# --- a release that adds a key: the embedded key verifies it, both keys install ------------
AK="$T/rel-addkey"
make_release "$TAG" 100 "$AK"
cp "$T/key2.asc" "$AK/lib/release-keys/key2.asc"
printf 'sha256  %s  lib/release-keys/key2.asc\n' "$(_h "$AK/lib/release-keys/key2.asc")" >> "$AK/MANIFEST"
sign_file "$AK/MANIFEST" key1
pack "$AK" "$TAG"
run_installer "$GOOD" --yes
check_rc "a release that adds a key: exits 0" 0 "$RC"
check "a release that adds a key: the new key is installed" "$(_h "$T/key2.asc")" "$(_h "$DEST/lib/release-keys/key2.asc" 2>/dev/null)"
sign_file "$AK/MANIFEST" key2
pack "$AK" "$TAG"
expect_refusal "a release signed only by the key it adds" "$GOOD"

# --- two embedded keys, two signatures; an expired embedded key -----------------------------
cat "$T/key1.asc" "$T/key2.asc" > "$T/keys12"
TWO="$T/install-two.sh"
tagged_installer "$TAG" "$T/keys12" "$TWO"
sign_file "$AK/MANIFEST" key1 key2
pack "$AK" "$TAG"
run_installer "$TWO" --yes
check_rc "two signatures: exits 0" 0 "$RC"
check_has "two signatures: both keys named" "  [OK]  Release signature verified (release key ${FPR1} ${FPR2})" "$(printf '%s\n' "$OUT" | sed "s/$(printf '\033')\[[0-9;]*m//g")"
cat "$T/key1.asc" "$T/kexp.asc" > "$T/keys1exp"
EXP="$T/install-exp.sh"
tagged_installer "$TAG" "$T/keys1exp" "$EXP"
sign_file "$REL/MANIFEST" key1 kexp
pack "$REL" "$TAG"
expect_refusal "a signature by an expired release key" "$EXP"
check "a signature by an expired release key: says why" "yes" \
    "$(printf '%s\n' "$OUT" | grep -qF "(it is signed by release key $(fpr_of kexp | cut -c25-40), which has expired). Nothing was installed." && echo yes || echo no)"
sign_file "$REL/MANIFEST" key1
pack "$REL" "$TAG"

# --- REL: release date and expiry (date=, expires=) -------------------------------------
# A date shim answers `date -u +%Y-%m-%d` with TODAY; other calls run the real date.
REAL_DATE="$(type -P date)"
cat > "$BIN/date" <<EOF
#!/bin/sh
if [ -n "\${TODAY:-}" ] && [ "\$*" = "-u +%Y-%m-%d" ]; then echo "\$TODAY"; exit 0; fi
exec $REAL_DATE "\$@"
EOF
chmod +x "$BIN/date"
export TODAY=""
ESC="$(printf '\033')"
# plain TEXT -- TEXT without colour escapes.
plain() {
    printf '%s\n' "$1" | sed "s/${ESC}\[[0-9;]*m//g"
}
EXPIRED_LINE="  [WARN] Script release $TAG expired on 2027-02-01; a newer signed release is overdue. Installing it anyway."
E="$T/rel-expires"
make_release "$TAG" 100 "$E" date=2026-11-03 expires=2027-02-01
check "expires: fixture header" "$(printf 'min_updater=1.0.0\ndate=2026-11-03\nexpires=2027-02-01')" "$(sed -n '4,6p' "$E/MANIFEST")"
pack "$E" "$TAG"
TODAY=2026-11-03 run_installer "$GOOD" --yes
check_rc "expires, fresh: exits 0" 0 "$RC"
check_lacks "expires, fresh: no warning" "expired" "$OUT"
check "expires, fresh: the record is the release MANIFEST" "$(_h "$E/MANIFEST")" "$(_h "$DEST/MANIFEST" 2>/dev/null)"
TODAY=2027-01-31 run_installer "$GOOD" --yes
check_lacks "expires, the day before: no warning" "expired" "$OUT"
TODAY=2027-02-01 run_installer "$GOOD" --yes
check_rc "expired: exits 0" 0 "$RC"
check_has "expired: the warning" "$EXPIRED_LINE" "$(plain "$OUT")"
check "expired: installed anyway" "$(_h "$E/setup-node.sh")" "$(_h "$DEST/setup-node.sh" 2>/dev/null)"
check "expired: warned before installing" "yes" \
    "$(plain "$OUT" | awk -v w="$EXPIRED_LINE" '$0 == w {seen = 1} /Installing to / && seen {print "yes"; exit}')"
# Far-off dates under this host's real date (GNU, busybox or macOS).
make_release "$TAG" 100 "$E" expires=2019-12-31
pack "$E" "$TAG"
run_installer "$GOOD" --yes
check_has "real date, expired 2019-12-31: the warning" "  [WARN] Script release $TAG expired on 2019-12-31; a newer signed release is overdue. Installing it anyway." "$(plain "$OUT")"
make_release "$TAG" 100 "$E" expires=2999-12-31
pack "$E" "$TAG"
run_installer "$GOOD" --yes
check_rc "real date, expires 2999-12-31: exits 0" 0 "$RC"
check_lacks "real date, expires 2999-12-31: no warning" "expired" "$OUT"

# Malformed or repeated date= / expires= refuse the release.
# bad_headers NAME PHRASE HEADER... -- a signed release with these lines is refused.
bad_headers() {
    local name="$1" phrase="$2" d="$T/rel-hdr"
    shift 2
    rm -rf "$d"
    make_release "$TAG" 100 "$d" "$@"
    pack "$d" "$TAG"
    expect_refusal "$name" "$GOOD"
    check_has "$name: says why" "  [ERROR] $phrase" "$(plain "$OUT")"
}
bad_headers "expires not a calendar date" "MANIFEST expires=2027-02-30 is not a calendar date YYYY-MM-DD." date=2026-11-03 expires=2027-02-30
bad_headers "expires empty" "MANIFEST expires= is not a calendar date YYYY-MM-DD." expires=
bad_headers "date in another format" "MANIFEST date=03/11/2026 is not a calendar date YYYY-MM-DD." date=03/11/2026 expires=2027-02-01
bad_headers "expires twice" "MANIFEST repeats expires=." expires=2027-02-01 expires=2027-03-01
bad_headers "date twice" "MANIFEST repeats date=." date=2026-11-03 date=2026-11-04
bad_headers "a blank before =" "MANIFEST line is malformed: expires =2027-02-01" "expires =2027-02-01"
TODAY=""

# --- an installer whose embedded key has CR line endings verifies as one with LF ---------------
awk '{ printf "%s\r\n", $0 }' "$T/key1.asc" > "$T/key1crlf"
tagged_installer "$TAG" "$T/key1crlf" "$T/install-crlf.sh"
check "a CRLF embedded key: the installer carries the CRs" "yes" "$(grep -q "$(printf '\r')" "$T/install-crlf.sh" && echo yes || echo no)"
pack "$REL" "$TAG"
run_installer "$T/install-crlf.sh" --yes
check_rc "a CRLF embedded key: exits 0" 0 "$RC"
check_has "a CRLF embedded key: verified with it" "  [OK]  Release signature verified (release key ${FPR1})" "$(printf '%s\n' "$OUT" | sed "s/$(printf '\033')\[[0-9;]*m//g")"

# --- an installer with no key, or a key block that is not a key -------------------------------
printf '# no keys\n' > "$T/nokeys"
tagged_installer "$TAG" "$T/nokeys" "$T/install-nokeys.sh"
pack "$REL" "$TAG"
expect_refusal "installer without keys" "$T/install-nokeys.sh"
check_has "installer without keys: says why" "  [ERROR] This installer carries no readable release key, so it cannot verify anything. Use the published installer: https://install.telcoin.network" \
    "$(printf '%s\n' "$OUT" | sed "s/$(printf '\033')\[[0-9;]*m//g")"
sed 's/^[A-Za-z0-9+\/]\{20\}/!!!!/' "$T/key1.asc" > "$T/badkey"
tagged_installer "$TAG" "$T/badkey" "$T/install-badkey.sh"
expect_refusal "installer whose key does not decode" "$T/install-badkey.sh"

finish
