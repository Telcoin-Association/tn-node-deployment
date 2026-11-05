#!/usr/bin/env bash
# =============================================================================
# tools/tests/updater_manifest_test.sh -- update-scripts.sh against signed
# fixture releases
#
#   bash tools/tests/updater_manifest_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/updater_manifest_test.sh
#
# A fixture "remote" directory stands in for raw.githubusercontent.com: a curl
# shim on PATH maps each URL to a file under it (rc 22 when the file is absent)
# and logs the URL. Releases are signed with throwaway OpenPGP keys made with
# gpg in a temp GNUPGHOME (tools/tests/signing.sh). Where GnuPG is absent (the
# bash:3.2 and ubuntu:24.04 images) a fake gpg and gpgv with the same
# interfaces and status lines stand in, so the updater's status parser still
# runs; the real-signature check is then reported as SKIP.
#
# Every refusal must leave the install tree byte-identical: the test compares
# a listing of every path plus the hash of every file before and after.
# No network, no root, nothing outside the temp dir.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
REPO="$TN_TEST_REPO"
BIN="$T/bin"
REMOTE="$T/remote"
RAW="$REMOTE/raw"
mkdir -p "$BIN" "$RAW/main"
unset TN_UPDATER_RELAUNCHED

ESC="$(printf '\033')"
# plain TEXT -- TEXT without colour escapes.
plain() {
    printf '%s\n' "$1" | sed "s/${ESC}\[[0-9;]*m//g"
}

_h() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1"
    else
        shasum -a 256 "$1"
    fi | awk '{print $1}'
}

# --- shims -------------------------------------------------------------------

cat > "$BIN/curl" <<EOF
#!/bin/sh
# curl shim: serve https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/<path>
# from $RAW/<path>; rc 22 when absent. Logs every URL.
out="" head=0 url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift ;;
        -I|-fsSLI|-sfI) head=1 ;;
        --proto|--max-time) shift ;;
        https://*) url="\$1" ;;
    esac
    shift
done
echo "\$url" >> "$T/curl.log"
[ -z "\${CURL_FAIL:-}" ] || exit 7
case "\$url" in
    https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/*)
        f="$RAW/\${url#https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/}" ;;
    *) exit 6 ;;
esac
[ -f "\$f" ] || exit 22
if [ "\$head" = 1 ]; then echo "HTTP/2 200"; exit 0; fi
if [ -n "\$out" ]; then cp "\$f" "\$out"; else cat "\$f"; fi
EOF
cat > "$BIN/sudo" <<EOF
#!/bin/sh
echo "sudo \$*" >> "$T/sudo.log"
exit 1
EOF
chmod +x "$BIN/curl" "$BIN/sudo"

# --- signing: real gpg, else a fake with the same interface -------------------
# shellcheck source=tools/tests/signing.sh
. "$TN_TEST_DIR/signing.sh"
export PATH="$BIN:$PATH"
FPR1="$(newkey key1)"
newkey key2 >/dev/null   # a valid key that is not a release key
FPR3="$(newkey key3)"
newkey kexp --expired >/dev/null
newkey krev --revoked >/dev/null

# --- release fixtures ----------------------------------------------------------

# A source tree for one release: SRC/<tag>/<files>. Files are small stand-ins
# except update-scripts.sh, the real updater under test.
SRC="$T/src"

base_tree() {   # base_tree DIR
    mkdir -p "$1/lib/release-keys" "$1/ui"
    cp "$REPO/update-scripts.sh" "$1/update-scripts.sh"
    cp "$T/key1.asc" "$1/lib/release-keys/key1.asc"
    printf 'release keys\n' > "$1/lib/release-keys/README"
    printf '#!/usr/bin/env bash\nreadonly SCRIPT_VERSION="1.0.0"\n' > "$1/setup-node.sh"
    printf '#!/usr/bin/env bash\nreadonly COMMON_VERSION="1.0.0"\n' > "$1/lib/common.sh"
    printf 'UI_VERSION = "1.0.0"\n' > "$1/ui/server.py"
    printf 'dropped later\n' > "$1/ui/dropped.txt"
}

# write_manifest DIR TAG SERIAL MIN -- MANIFEST for every file in DIR.
write_manifest() {
    local d="$1" p
    {
        printf 'format=1\nrelease=%s\nserial=%s\nmin_updater=%s\n' "$2" "$3" "$4"
        (cd "$d" && find . -type f ! -name MANIFEST ! -name 'MANIFEST.asc' ! -name '*.sha256' | sed 's|^\./||' | LC_ALL=C sort) \
            | while IFS= read -r p; do
                printf 'sha256  %s  %s\n' "$(_h "$d/$p")" "$p"
            done
    } > "$d/MANIFEST"
}

sign() {   # sign DIR KEYNAME...
    local d="$1"
    shift
    sign_file "$d/MANIFEST" "$@"
}

sidecars() {   # sidecars DIR -- a .sha256 beside every listed file
    local p
    awk '/^sha256  / {print $3}' "$1/MANIFEST" | while IFS= read -r p; do
        printf '%s  %s\n' "$(_h "$1/$p")" "$p" > "$1/$p.sha256"
    done
}

# publish DIR TAG -- serve DIR as release TAG and point RELEASE at it.
publish() {
    rm -rf "$RAW/refs/tags/$2"
    mkdir -p "$RAW/refs/tags"
    cp -R "$1" "$RAW/refs/tags/$2"
    printf '%s 2026-10-15\n' "$2" > "$RAW/main/RELEASE"
}

# install_release DIR -- make INST a tree at release DIR (files plus record).
INST="$T/inst"
install_release() {
    rm -rf "$INST"
    mkdir -p "$INST"
    (cd "$1" && find . -type f ! -name '*.sha256' | while IFS= read -r p; do
        mkdir -p "$INST/$(dirname "$p")"
        cp "$p" "$INST/$p"
    done)
    chmod +x "$INST/update-scripts.sh"
}

tree_sig() {
    (cd "$INST" && find . -print | LC_ALL=C sort \
        && find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(_h "$f")" "$f"; done)
}

# run_updater ANSWER -- run INST's updater, OUT/RC get its output and status.
run_updater() {
    : > "$T/curl.log"
    OUT="$(cd "$T" && printf '%s\n' "$1" | TERM=dumb bash "$INST/update-scripts.sh" 2>&1)"
    RC=$?
}

# says NAME PHRASE -- the last run's output contains PHRASE.
says() {
    check "$1: says why" "yes" "$(plain "$OUT" | grep -qF -- "$2" && echo yes || echo "no: $(plain "$OUT" | grep -F ERROR)")"
}

# refused NAME -- the updater exits 1 and INST is unchanged.
refused() {
    local before
    before="$(tree_sig)"
    run_updater y
    check_rc "$1: exits 1" 1 "$RC"
    check "$1: tree byte-identical" "$before" "$(tree_sig)"
}

printf 'README\n' > "$RAW/main/README.md"

# R1: serial 100. R2: serial 101, setup-node.sh 1.1.0, lib/new.env added,
# ui/dropped.txt removed.
R1="$SRC/r1"; base_tree "$R1"; write_manifest "$R1" scripts-v1.0.0 100 1.0.0; sign "$R1" key1; sidecars "$R1"
R2="$SRC/r2"; base_tree "$R2"
printf '#!/usr/bin/env bash\nreadonly SCRIPT_VERSION="1.1.0"\n' > "$R2/setup-node.sh"
printf 'NEW=1\n' > "$R2/lib/new.env"
printf 'UI_VERSION = "1.1.0"\n' > "$R2/ui/server.py"
rm -f "$R2/ui/dropped.txt"
write_manifest "$R2" scripts-v1.1.0 101 1.0.0; sign "$R2" key1; sidecars "$R2"
rm -f "$R2/lib/new.env.sha256"   # a file without a sidecar: the manifest is authoritative

if [[ $REAL_GPG -eq 1 ]]; then
    check "signer: real gpg and gpgv in use" "1" "$REAL_GPG"
else
    skip "real OpenPGP signatures" "gpg absent: a fake gpg and gpgv stand in"
fi

# --- good: R1 -> R2 ------------------------------------------------------------
install_release "$R1"
publish "$R2" scripts-v1.1.0
run_updater y
check_rc "good: exits 0" 0 "$RC"
check "good: setup-node.sh is the R2 copy" "$(_h "$R2/setup-node.sh")" "$(_h "$INST/setup-node.sh")"
check "good: new file installed" "NEW=1" "$(cat "$INST/lib/new.env" 2>/dev/null)"
check "good: dropped file removed" "absent" "$([[ -e "$INST/ui/dropped.txt" ]] && echo present || echo absent)"
check "good: MANIFEST record is R2" "$(_h "$R2/MANIFEST")" "$(_h "$INST/MANIFEST")"
check "good: MANIFEST.asc record is R2" "$(_h "$R2/MANIFEST.asc")" "$(_h "$INST/MANIFEST.asc")"
check_has "good: names the release key" "  [OK]  Release manifest signed by release key ${FPR1}" "$(plain "$OUT")"
check "good: no staging dir left" "" "$(cd "$INST" && find . -name '.tn-update.*')"
check "good: setup-node.sh executable" "yes" "$([[ -x "$INST/setup-node.sh" ]] && echo yes || echo no)"
check "good: sudo never run" "" "$(cat "$T/sudo.log" 2>/dev/null)"
check "good: UI command printed, not run" "1" "$(plain "$OUT" | grep -c 'sudo bash .*/ui/install-ui.sh')"
check_lacks "good: nothing fetched from main but RELEASE and the probe" "/main/setup-node.sh" "$(cat "$T/curl.log")"
check_has "good: files fetched from the tag" "https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/refs/tags/scripts-v1.1.0/setup-node.sh" "$(cat "$T/curl.log")"

# --- rerun: nothing to do ------------------------------------------------------
before="$(tree_sig)"
run_updater y
check_rc "rerun: exits 0" 0 "$RC"
check_has "rerun: up to date" "  [OK]  All scripts are up to date (scripts-v1.1.0, serial 101)" "$(plain "$OUT")"
check "rerun: tree unchanged" "$before" "$(tree_sig)"

# --- declined --------------------------------------------------------------------
install_release "$R1"
before="$(tree_sig)"
run_updater n
check_rc "declined: exits 0" 0 "$RC"
check "declined: tree unchanged" "$before" "$(tree_sig)"

# --- wrong signer ------------------------------------------------------------------
W="$SRC/wrong"; cp -R "$R2" "$W"; sign "$W" key2
publish "$W" scripts-v1.1.0
install_release "$R1"
refused "wrong signer"
check_has "wrong signer: says why" "  [ERROR] The release manifest is not signed by a Telcoin release key (no release key in lib/release-keys made a good signature); nothing was changed." "$(plain "$OUT")"

# --- no MANIFEST.asc published -----------------------------------------------------
NS="$SRC/nosig"; cp -R "$R2" "$NS"; rm -f "$NS/MANIFEST.asc"
publish "$NS" scripts-v1.1.0
install_release "$R1"
refused "no signature"
says "no signature" "Release scripts-v1.1.0 has no MANIFEST.asc; nothing was changed."

# --- tampered MANIFEST (signed, then one hash changed) -------------------------------
X="$SRC/tampered"; cp -R "$R2" "$X"
awk -v h="$(_h "$R1/setup-node.sh")" '$3 == "setup-node.sh" {$0 = "sha256  " h "  setup-node.sh"} {print}' "$R2/MANIFEST" > "$X/MANIFEST"
cp "$R1/setup-node.sh" "$X/setup-node.sh"
publish "$X" scripts-v1.1.0
install_release "$R1"
printf 'local edit\n' >> "$INST/setup-node.sh"
refused "tampered manifest"
says "tampered manifest" "not signed by a Telcoin release key (the signature by key ${FPR1:24} does not match MANIFEST: one of the two was changed)"

# --- tampered file whose forged sidecar matches it ------------------------------------
F="$SRC/forged"; cp -R "$R2" "$F"
printf '#!/usr/bin/env bash\necho owned\n' > "$F/setup-node.sh"
printf '%s  setup-node.sh\n' "$(_h "$F/setup-node.sh")" > "$F/setup-node.sh.sha256"
publish "$F" scripts-v1.1.0
install_release "$R1"
refused "forged sidecar"
says "forged sidecar" "FAILED  (does not match the signed manifest)"
check_lacks "forged sidecar: nothing installed" "owned" "$(cat "$INST/setup-node.sh")"

# --- a sidecar that disagrees with the manifest --------------------------------------
D="$SRC/sidecar"; cp -R "$R2" "$D"
printf '%s  setup-node.sh\n' "$(_h "$R1/setup-node.sh")" > "$D/setup-node.sh.sha256"
publish "$D" scripts-v1.1.0
install_release "$R1"
refused "stale sidecar"
says "stale sidecar" "FAILED  (its .sha256 disagrees with the signed manifest)"

# --- a published sidecar that is not a hash -----------------------------------------------
Z="$SRC/sidecarbad"; cp -R "$R2" "$Z"
printf 'not-a-hash  setup-node.sh\n' > "$Z/setup-node.sh.sha256"
publish "$Z" scripts-v1.1.0
install_release "$R1"
refused "malformed sidecar"
says "malformed sidecar" "FAILED  (its published .sha256 is malformed)"

# --- lower serial -------------------------------------------------------------------------
install_release "$R2"
publish "$R1" scripts-v1.0.0
refused "lower serial"
check_has "lower serial: says why" "  [ERROR] Release scripts-v1.0.0 (serial 100) is older than the installed release (serial 101): refusing to go back; nothing was changed." "$(plain "$OUT")"

# --- same serial, different manifest ----------------------------------------------------------
S="$SRC/same"; cp -R "$R2" "$S"
printf 'other\n' > "$S/lib/new.env"
write_manifest "$S" scripts-v1.1.0 101 1.0.0; sign "$S" key1; sidecars "$S"
install_release "$R2"
publish "$S" scripts-v1.1.0
refused "same serial"
says "same serial" "reuses the installed serial 101"

# --- newer min_updater ----------------------------------------------------------------------
M="$SRC/minupd"; cp -R "$R2" "$M"
write_manifest "$M" scripts-v1.2.0 102 99.0.0; sign "$M" key1; sidecars "$M"
install_release "$R2"
publish "$M" scripts-v1.2.0
refused "newer min_updater"
says "newer min_updater" "needs update-scripts.sh 99.0.0 or newer; this one is"
check_has "newer min_updater: prints the bootstrap command" "  ->    curl --proto '=https' --tlsv1.2 -fsSL https://install.telcoin.network | bash" "$(plain "$OUT")"

# --- RELEASE names a tag whose manifest is for another release ----------------------------
publish "$R2" scripts-v9.9.9
install_release "$R1"
refused "release mismatch"
says "release mismatch" "The manifest is for scripts-v1.1.0, but RELEASE names scripts-v9.9.9"

# --- a path outside the tree ---------------------------------------------------------------
B="$SRC/badpath"; cp -R "$R2" "$B"
printf 'sha256  %s  ../escape.sh\n' "$(_h "$R2/setup-node.sh")" >> "$B/MANIFEST"
sign "$B" key1
publish "$B" scripts-v1.1.0
install_release "$R1"
refused "path outside the tree"
says "path outside the tree" "bad path: ../escape.sh"
# The signature file is the record, never a listed file.
BS="$SRC/badsigpath"; cp -R "$R2" "$BS"
printf 'sha256  %s  MANIFEST.asc\n' "$(_h "$R2/setup-node.sh")" >> "$BS/MANIFEST"
sign "$BS" key1
publish "$BS" scripts-v1.1.0
install_release "$R1"
refused "MANIFEST.asc listed as a file"
says "MANIFEST.asc listed as a file" "The release manifest is malformed (bad path: MANIFEST.asc)"
check "path outside the tree: nothing written beside the tree" "absent" "$([[ -e "$T/escape.sh" ]] && echo present || echo absent)"

# --- manifest without a release key --------------------------------------------------------------
N="$SRC/nokeys"; cp -R "$R2" "$N"
grep -v '  lib/release-keys/key1\.asc$' "$R2/MANIFEST" > "$N/MANIFEST"; sign "$N" key1
publish "$N" scripts-v1.1.0
install_release "$R1"
refused "release key not listed"
says "release key not listed" "The release manifest is malformed (no release key (lib/release-keys/*.asc) listed)"

# --- the release keys: expired, revoked, two signatures, threshold 2 ------------------------------
# K1 ships four keys: key1, key3, kexp (expired) and krev (revoked). Each
# release below is signed differently and published over a K1 install.
K1="$SRC/k1"; cp -R "$R1" "$K1"
cp "$T/key3.asc" "$T/kexp.asc" "$T/krev.asc" "$K1/lib/release-keys/"
write_manifest "$K1" scripts-v1.0.0 100 1.0.0; sign "$K1" key1; sidecars "$K1"
K2="$SRC/k2"; cp -R "$K1" "$K2"
printf '#!/usr/bin/env bash\nreadonly SCRIPT_VERSION="1.1.0"\n' > "$K2/setup-node.sh"
write_manifest "$K2" scripts-v1.1.0 101 1.0.0; sidecars "$K2"
publish_signed() {   # publish_signed KEYNAME... -- K2 signed by these keys, served
    sign "$K2" "$@"
    publish "$K2" scripts-v1.1.0
    install_release "$K1"
}
publish_signed kexp
refused "expired release key"
says "expired release key" "(it is signed by release key $(fpr_of kexp | cut -c25-40), which has expired)"
publish_signed key1 kexp
refused "expired release key beside a good one"
says "expired release key beside a good one" "which has expired"
publish_signed krev
refused "revoked release key"
says "revoked release key" "(it is signed by release key $(fpr_of krev | cut -c25-40), which has been revoked)"
publish_signed key1 key3
run_updater y
check_rc "two release keys: exits 0" 0 "$RC"
check_has "two release keys: both counted, in signature order" "  [OK]  Release manifest signed by release key ${FPR1} ${FPR3}" "$(plain "$OUT")"
# Threshold 2: the updater of K1 and of the release, with TN_SIG_THRESHOLD=2.
sed 's/^readonly TN_SIG_THRESHOLD=1$/readonly TN_SIG_THRESHOLD=2/' "$REPO/update-scripts.sh" > "$T/us2"
cp "$T/us2" "$K1/update-scripts.sh"; write_manifest "$K1" scripts-v1.0.0 100 1.0.0; sign "$K1" key1 key3; sidecars "$K1"
cp "$T/us2" "$K2/update-scripts.sh"; write_manifest "$K2" scripts-v1.1.0 101 1.0.0; sidecars "$K2"
publish_signed key1
refused "threshold 2, one signature"
says "threshold 2, one signature" "(good signatures by 1 release key(s), 2 needed)"
publish_signed key1 key1
refused "threshold 2, one key twice"
says "threshold 2, one key twice" "(good signatures by 1 release key(s), 2 needed)"
publish_signed key1 key3
run_updater y
check_rc "threshold 2, two keys: exits 0" 0 "$RC"
check "threshold 2, two keys: installed" "$(_h "$K2/setup-node.sh")" "$(_h "$INST/setup-node.sh")"

# --- self-update: the release ships a different updater ------------------------------------
# The release copy appends a line to $MARK each time it runs.
MARK="$T/release-updater-ran"
export MARK
U="$SRC/selfupd"; cp -R "$R2" "$U"
awk '{print} /^set -euo pipefail$/ && !done {print "[ -n \"${MARK:-}\" ] && echo ran >> \"$MARK\" || true"; done = 1}' \
    "$R2/update-scripts.sh" > "$U/update-scripts.sh"
write_manifest "$U" scripts-v1.3.0 103 1.0.0; sign "$U" key1; sidecars "$U"
publish "$U" scripts-v1.3.0
install_release "$R1"
rm -f "$MARK"
run_updater y
check_rc "self-update: exits 0" 0 "$RC"
check "self-update: release copy ran once" "ran" "$(cat "$MARK" 2>/dev/null)"
check "self-update: updater is the release copy" "$(_h "$U/update-scripts.sh")" "$(_h "$INST/update-scripts.sh")"
check "self-update: updater executable" "yes" "$([[ -x "$INST/update-scripts.sh" ]] && echo yes || echo no)"
check "self-update: rest installed by the new copy" "$(_h "$U/setup-node.sh")" "$(_h "$INST/setup-node.sh")"
check "self-update: release recorded" "$(_h "$U/MANIFEST")" "$(_h "$INST/MANIFEST")"
check "self-update: no staging dir left" "" "$(cd "$INST" && find . -name '.tn-update.*')"
check_has "self-update: runs the release copy" "  ->  Running the scripts-v1.3.0 copy of update-scripts.sh to install the release..." "$(plain "$OUT")"

# --- self-update declined: the release copy asks, nothing is installed -----------------------
install_release "$R1"
before="$(tree_sig)"
rm -f "$MARK"
run_updater n
check_rc "self-update declined: exits 0" 0 "$RC"
check "self-update declined: release copy asked" "ran" "$(cat "$MARK" 2>/dev/null)"
check "self-update declined: tree byte-identical, updater too" "$before" "$(tree_sig)"

# --- self-update with a tampered file: refused before the release copy runs -----------------
# The manifest lists a new updater and setup-node.sh; the published setup-node.sh
# is not the one it lists. Nothing changes, the installed updater's mode included.
Y="$SRC/selfbad"; cp -R "$U" "$Y"
printf '#!/usr/bin/env bash\necho tampered\n' > "$Y/setup-node.sh"
printf '%s  setup-node.sh\n' "$(_h "$Y/setup-node.sh")" > "$Y/setup-node.sh.sha256"
publish "$Y" scripts-v1.3.0
install_release "$R1"
chmod 0750 "$INST/update-scripts.sh"
mode_before="$(ls -ln "$INST/update-scripts.sh" | awk '{print $1}')"
rm -f "$MARK"
refused "self-update, tampered file"
says "self-update, tampered file" "FAILED  (does not match the signed manifest)"
check "self-update, tampered file: updater mode unchanged" "$mode_before" "$(ls -ln "$INST/update-scripts.sh" | awk '{print $1}')"
check "self-update, tampered file: release copy never ran" "no" "$([[ -e "$MARK" ]] && echo yes || echo no)"
check "self-update, tampered file: no staging dir left" "" "$(cd "$INST" && find . -name '.tn-update.*')"

# --- self-update refused: the release copy is older than its own min_updater ---------------
V="$SRC/selfold"; cp -R "$U" "$V"
write_manifest "$V" scripts-v1.4.0 104 99.0.0; sign "$V" key1; sidecars "$V"
publish "$V" scripts-v1.4.0
install_release "$R1"
refused "self-update below min_updater"
says "self-update below min_updater" "needs update-scripts.sh 99.0.0 or newer"

# --- first signed release on a bare host: release keys through their sidecars -----------------
# bare -- INST as R1 without the record and without any release key.
bare() {
    install_release "$R1"
    rm -f "$INST/MANIFEST" "$INST/MANIFEST.asc" "$INST"/lib/release-keys/*.asc
}
bare
publish "$R2" scripts-v1.1.0
run_updater y
check_rc "bootstrap: exits 0" 0 "$RC"
says "bootstrap" "First signed release on this host: fetching the release keys through their published checksums (one time only)."
check "bootstrap: release key installed" "$(_h "$R2/lib/release-keys/key1.asc")" "$(_h "$INST/lib/release-keys/key1.asc" 2>/dev/null)"
check "bootstrap: release recorded" "$(_h "$R2/MANIFEST")" "$(_h "$INST/MANIFEST" 2>/dev/null)"
check "bootstrap: no staging dir left" "" "$(cd "$INST" && find . -name '.tn-update.*')"

bare
G="$SRC/bootbad"; cp -R "$R2" "$G"
printf '%s  lib/release-keys/key1.asc\n' "$(_h "$R1/setup-node.sh")" > "$G/lib/release-keys/key1.asc.sha256"
publish "$G" scripts-v1.1.0
refused "bootstrap: key sidecar mismatch"
says "bootstrap: key sidecar mismatch" "lib/release-keys/key1.asc of release scripts-v1.1.0 does not match its published checksum; nothing was changed."

bare
H="$SRC/bootmalformed"; cp -R "$R2" "$H"
printf 'nothash  lib/release-keys/key1.asc\n' > "$H/lib/release-keys/key1.asc.sha256"
publish "$H" scripts-v1.1.0
refused "bootstrap: malformed key sidecar"
says "bootstrap: malformed key sidecar" "The published checksum for lib/release-keys/key1.asc in release scripts-v1.1.0 is malformed"

bare
NSC="$SRC/bootnoside"; cp -R "$R2" "$NSC"
rm -f "$NSC/lib/release-keys/key1.asc.sha256"
publish "$NSC" scripts-v1.1.0
refused "bootstrap: no key sidecar"
says "bootstrap: no key sidecar" "No checksum is published for lib/release-keys/key1.asc in release scripts-v1.1.0"

# The key file and its sidecar agree and the manifest verifies with that key,
# but the manifest lists another hash for it.
bare
HM="$SRC/boothash"; cp -R "$R2" "$HM"
awk -v h="$(_h "$R1/setup-node.sh")" '$3 == "lib/release-keys/key1.asc" { $0 = "sha256  " h "  lib/release-keys/key1.asc" } { print }' \
    "$R2/MANIFEST" > "$HM/MANIFEST"
sign "$HM" key1
publish "$HM" scripts-v1.1.0
refused "bootstrap: key hash not the listed one"
says "bootstrap: key hash not the listed one" "The release key lib/release-keys/key1.asc fetched by checksum is not the one release scripts-v1.1.0 lists; nothing was changed."

# A release signed by a key other than the one it ships, on a bare host.
bare
BF="$SRC/bootforeign"; cp -R "$R2" "$BF"; sign "$BF" key2
publish "$BF" scripts-v1.1.0
refused "bootstrap: signed by another key"
says "bootstrap: signed by another key" "no release key in lib/release-keys made a good signature"

install_release "$R1"
rm -f "$INST"/lib/release-keys/*.asc
publish "$R2" scripts-v1.1.0
refused "release keys deleted after a signed install"
says "release keys deleted after a signed install" "lib/release-keys holds no release key (*.asc), so no release can be verified; nothing was changed."

install_release "$R1"
printf 'not a key\n' > "$INST/lib/release-keys/key1.asc"
refused "installed key file that is not a key"
says "installed key file that is not a key" "cannot be read, so no release can be verified; nothing was changed."

# --- REL: release date and expiry (date=, expires=) and --check ------------------------------
# A date shim on PATH answers `date -u +%Y-%m-%d` with TODAY when it is set, so
# "today" is fixed for the expiry checks; every other call runs the real date.
REAL_DATE="$(type -P date)"
cat > "$BIN/date" <<EOF
#!/bin/sh
if [ -n "\${TODAY:-}" ] && [ "\$*" = "-u +%Y-%m-%d" ]; then echo "\$TODAY"; exit 0; fi
exec $REAL_DATE "\$@"
EOF
chmod +x "$BIN/date"
export TODAY=""

# with_headers DIR LINE... -- put the header LINEs after min_updater= in DIR/MANIFEST.
# Plain bash: BSD awk (macOS) refuses a newline in an -v value.
with_headers() {
    local d="$1" line
    shift
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "$line"
        if [[ "$line" == min_updater=* && $# -gt 0 ]]; then printf '%s\n' "$@"; fi
    done < "$d/MANIFEST" > "$d/MANIFEST.new"
    mv -f "$d/MANIFEST.new" "$d/MANIFEST"
}
# run_check -- run INST's updater with --check (TMPDIR in the test dir), OUT/RC.
mkdir -p "$T/tmp"
run_check() {
    : > "$T/curl.log"
    OUT="$(cd "$T" && TMPDIR="$T/tmp" TERM=dumb bash "$INST/update-scripts.sh" --check < /dev/null 2>&1)"
    RC=$?
}

# R3: serial 102, setup-node.sh 1.2.0, released 2026-11-03, expires 2027-02-01.
R3="$SRC/r3"; cp -R "$R2" "$R3"
printf '#!/usr/bin/env bash\nreadonly SCRIPT_VERSION="1.2.0"\n' > "$R3/setup-node.sh"
write_manifest "$R3" scripts-v1.5.0 102 1.0.0
with_headers "$R3" date=2026-11-03 expires=2027-02-01
sign "$R3" key1; sidecars "$R3"
check "expires: fixture header" "$(printf 'format=1\nrelease=scripts-v1.5.0\nserial=102\nmin_updater=1.0.0\ndate=2026-11-03\nexpires=2027-02-01')" "$(head -n 6 "$R3/MANIFEST")"

# A fresh release installs without a warning.
install_release "$R2"
publish "$R3" scripts-v1.5.0
TODAY=2026-11-03 run_updater y
check_rc "expires, fresh: exits 0" 0 "$RC"
check "expires, fresh: installed" "$(_h "$R3/setup-node.sh")" "$(_h "$INST/setup-node.sh")"
check "expires, fresh: release recorded" "$(_h "$R3/MANIFEST")" "$(_h "$INST/MANIFEST")"
check_lacks "expires, fresh: no expiry warning" "expired" "$(plain "$OUT")"

# --check: installed and newest are the same fresh release.
before="$(tree_sig)"
TODAY=2026-11-03 run_check
check_rc "check, current: exits 0" 0 "$RC"
check_has "check, current: installed line" "  ->  Installed:  scripts-v1.5.0, serial 102, released 2026-11-03, expires 2027-02-01 (signature verified)" "$(plain "$OUT")"
check_has "check, current: newest line" "  ->  Newest:     scripts-v1.5.0, serial 102, released 2026-11-03, expires 2027-02-01 (signature verified)" "$(plain "$OUT")"
check_has "check, current: nothing pending" "  [OK]  No update pending: every file matches scripts-v1.5.0." "$(plain "$OUT")"
check_has "check, current: days left" "  [OK]  Up to date with scripts-v1.5.0; it expires 2027-02-01 (in 90 days)." "$(plain "$OUT")"
check "check, current: tree byte-identical" "$before" "$(tree_sig)"
check "check, current: temp dir removed" "" "$(ls -A "$T/tmp")"
check_lacks "check, current: no banner" "Script Updater" "$OUT"
TODAY=2027-01-31 run_check
check_has "check, the day before: 1 day left" "  [OK]  Up to date with scripts-v1.5.0; it expires 2027-02-01 (in 1 day)." "$(plain "$OUT")"

# --check: the installed release has expired.
TODAY=2027-02-04 run_check
check_rc "check, installed expired: exits 1" 1 "$RC"
check_has "check, installed expired: says so" "  [WARN] Installed release scripts-v1.5.0 expired on 2027-02-01 (3 days ago); a newer signed release is overdue." "$(plain "$OUT")"
check_lacks "check, installed expired: one expiry line for one release" "Newest release" "$(plain "$OUT")"
TODAY=2027-02-01 run_check
check_rc "check, expires today: exits 1" 1 "$RC"
check_has "check, expires today: says today" "  [WARN] Installed release scripts-v1.5.0 expired on 2027-02-01 (today); a newer signed release is overdue." "$(plain "$OUT")"

# --check: the installed release has expired and the newest cannot be fetched:
# the expiry warning comes first, from the record alone, and rc is 2.
TODAY=2027-02-04 CURL_FAIL=1 run_check
check_rc "check, installed expired, fetch fails: exits 2" 2 "$RC"
check_has "check, installed expired, fetch fails: still warns" "  [WARN] Installed release scripts-v1.5.0 expired on 2027-02-01 (3 days ago); a newer signed release is overdue." "$(plain "$OUT")"
check "check, installed expired, fetch fails: the warning before the fetch error" "yes" \
    "$(plain "$OUT" | awk '/expired on 2027-02-01/ {w = NR} /network error/ {e = NR} END {print (w && e && w < e) ? "yes" : "no"}')"

# --check: a release the updater would refuse is rc 2.
publish "$R2" scripts-v1.1.0
TODAY=2026-11-03 run_check
check_rc "check, RELEASE goes back to a lower serial: exits 2" 2 "$RC"
check_has "check, lower serial: says so" "  [ERROR] RELEASE names scripts-v1.1.0 (serial 101), older than the installed release (serial 102): the updater refuses it." "$(plain "$OUT")"
check_has "check, lower serial: names the risk" "  ->  A release pointer that goes back can mean tampering: tell support@telcoin.org." "$(plain "$OUT")"
S3="$SRC/r3same"; rm -rf "$S3"; cp -R "$R3" "$S3"
printf '#!/usr/bin/env bash\nreadonly SCRIPT_VERSION="1.2.1"\n' > "$S3/setup-node.sh"
write_manifest "$S3" scripts-v1.5.0 102 1.0.0; with_headers "$S3" date=2026-11-03 expires=2027-02-01
sign "$S3" key1; sidecars "$S3"
publish "$S3" scripts-v1.5.0
TODAY=2027-02-04 run_check
check_rc "check, same serial, another manifest: exits 2" 2 "$RC"
check_has "check, same serial: says so" "  [ERROR] Release scripts-v1.5.0 reuses the installed serial 102 with a different manifest: the updater refuses it." "$(plain "$OUT")"
check_has "check, same serial and expired: the expiry still warned" "  [WARN] Installed release scripts-v1.5.0 expired on 2027-02-01 (3 days ago); a newer signed release is overdue." "$(plain "$OUT")"
install_release "$R2"
publish "$R3" scripts-v1.5.0
rm -f "$INST/setup-node.sh"; mkdir "$INST/setup-node.sh"
TODAY=2026-11-03 run_check
check_rc "check, a listed file is a directory here: exits 2" 2 "$RC"
says "check, a listed file is a directory here" "setup-node.sh is not a regular file"
install_release "$R3"

# An expired release is still installed, with the warning.
install_release "$R2"
TODAY=2027-02-02 run_updater y
check_rc "expired at update: exits 0" 0 "$RC"
check_has "expired at update: the warning" "  [WARN] Script release scripts-v1.5.0 expired on 2027-02-01; a newer signed release is overdue. Installing it anyway." "$(plain "$OUT")"
check "expired at update: installed anyway" "$(_h "$R3/setup-node.sh")" "$(_h "$INST/setup-node.sh")"
check "expired at update: release recorded" "$(_h "$R3/MANIFEST")" "$(_h "$INST/MANIFEST")"
TODAY=2027-02-02 run_updater y
check_rc "expired, up to date: exits 0" 0 "$RC"
check_has "expired, up to date: the warning without installing" "  [WARN] Script release scripts-v1.5.0 expired on 2027-02-01; a newer signed release is overdue." "$(plain "$OUT")"
check_has "expired, up to date: up to date" "  [OK]  All scripts are up to date (scripts-v1.5.0, serial 102)" "$(plain "$OUT")"

# --check: an update is pending; then the newest release has expired too.
install_release "$R2"
TODAY=2026-11-03 run_check
check_rc "check, pending: exits 1" 1 "$RC"
check_has "check, pending: installed line of a 2.0.0-shaped record" "  ->  Installed:  scripts-v1.1.0, serial 101, release date not recorded, no expiry date (signature verified)" "$(plain "$OUT")"
check_has "check, pending: says what to run" "  [WARN] Update pending: 1 file(s) to update, 0 to remove. Run: bash $INST/update-scripts.sh" "$(plain "$OUT")"
TODAY=2027-03-01 run_check
check_rc "check, pending and newest expired: exits 1" 1 "$RC"
check_has "check, newest expired: says so" "  [WARN] Newest release scripts-v1.5.0 expired on 2027-02-01 (28 days ago); a newer signed release is overdue." "$(plain "$OUT")"

# --check: a 2.0.0-shaped release (no date=, no expires=) installed and newest.
publish "$R2" scripts-v1.1.0
TODAY=2026-11-03 run_check
check_rc "check, no expiry: exits 0" 0 "$RC"
check_has "check, no expiry: says so" "  [OK]  Up to date with scripts-v1.1.0; it carries no expiry date." "$(plain "$OUT")"

# --check: nothing installed, no RELEASE, a network failure, a tampered record.
rm -f "$INST/MANIFEST" "$INST/MANIFEST.asc"
TODAY=2026-11-03 run_check
check_rc "check, nothing installed: exits 2" 2 "$RC"
check_has "check, nothing installed: says so" "  [WARN] No signed release is installed in $INST (no MANIFEST record)." "$(plain "$OUT")"
check_has "check, nothing installed: still names the newest" "  ->  Newest:     scripts-v1.1.0, serial 101, release date not recorded, no expiry date (signature verified)" "$(plain "$OUT")"
check_has "check, nothing installed: what to run" "  ->  To install it: bash $INST/update-scripts.sh" "$(plain "$OUT")"
install_release "$R2"
CURL_FAIL=1 run_check
check_rc "check, network failure: exits 2" 2 "$RC"
says "check, network failure" "(network error). Try again in a few minutes."
printf 'serial=999\n' >> "$INST/MANIFEST"
run_check
check_rc "check, tampered record: exits 2" 2 "$RC"
says "check, tampered record" "The release manifest is not signed by a Telcoin release key"
# The installed record verifies; the newest release (serial 101) is signed by a
# key that is not a release key: --check fails the check, it reports no update.
install_release "$R1"
publish "$SRC/wrong" scripts-v1.1.0
before="$(tree_sig)"
run_check
check_rc "check, newest signed by another key: exits 2" 2 "$RC"
check_has "check, newest signed by another key: says why" "  [ERROR] The release manifest is not signed by a Telcoin release key (no release key in lib/release-keys made a good signature); nothing was changed." "$(plain "$OUT")"
check_lacks "check, newest signed by another key: no newest line" "Newest:" "$(plain "$OUT")"
check_lacks "check, newest signed by another key: no pending update" "Update pending" "$(plain "$OUT")"
check "check, newest signed by another key: tree byte-identical" "$before" "$(tree_sig)"
publish "$R2" scripts-v1.1.0
install_release "$R2"
install_release "$R2"
mv "$RAW/main/RELEASE" "$T/RELEASE.keep"
run_check
check_rc "check, no RELEASE: exits 2" 2 "$RC"
says "check, no RELEASE" "No signed script release is published yet"
mv "$T/RELEASE.keep" "$RAW/main/RELEASE"
OUT="$(bash "$INST/update-scripts.sh" --check --bogus 2>&1)"; RC=$?
check_rc "check with an unknown argument: exits 2" 2 "$RC"

# Malformed and repeated date= / expires= refuse the whole manifest.
# bad_headers NAME PHRASE LINE... -- a signed R3 with these header lines is refused.
bad_headers() {
    local name="$1" phrase="$2" d="$SRC/hdr"
    shift 2
    rm -rf "$d"; cp -R "$R3" "$d"
    write_manifest "$d" scripts-v1.5.0 102 1.0.0
    with_headers "$d" "$@"
    sign "$d" key1; sidecars "$d"
    publish "$d" scripts-v1.5.0
    install_release "$R2"
    refused "$name"
    says "$name" "$phrase"
}
bad_headers "expires not a calendar date" "The release manifest is malformed (expires 2027-02-30)" date=2026-11-03 expires=2027-02-30
bad_headers "expires in another format" "The release manifest is malformed (expires 2027/02/01)" expires=2027/02/01
bad_headers "date not zero-padded" "The release manifest is malformed (date 2026-11-3)" date=2026-11-3 expires=2027-02-01
bad_headers "expires twice" "date and expires may each appear once at most" expires=2027-02-01 expires=2027-03-01
bad_headers "date twice" "date and expires may each appear once at most" date=2026-11-03 date=2026-11-04
bad_headers "expires empty" "The release manifest is malformed (expires )" expires=
bad_headers "a blank before =" "The release manifest is malformed (bad line: expires =2027-02-01)" "expires =2027-02-01"
# A manifest with expires= and no date= is fine.
D2="$SRC/expiresonly"; rm -rf "$D2"; cp -R "$R3" "$D2"
write_manifest "$D2" scripts-v1.5.0 102 1.0.0; with_headers "$D2" expires=2027-02-01
sign "$D2" key1; sidecars "$D2"
publish "$D2" scripts-v1.5.0
install_release "$R2"
TODAY=2026-11-03 run_updater y
check_rc "expires without date: accepted" 0 "$RC"

# The real date of this host (GNU, busybox or macOS): far-off dates either way.
D3="$SRC/realdate"; rm -rf "$D3"; cp -R "$R3" "$D3"
write_manifest "$D3" scripts-v1.6.0 103 1.0.0; with_headers "$D3" date=2026-11-03 expires=2999-12-31
sign "$D3" key1; sidecars "$D3"
publish "$D3" scripts-v1.6.0
install_release "$D3"
run_check
check_rc "real date, expires 2999-12-31: exits 0" 0 "$RC"
check "real date, expires 2999-12-31: days left counted" "yes" \
    "$(plain "$OUT" | grep -qE '^  \[OK\]  Up to date with scripts-v1\.6\.0; it expires 2999-12-31 \(in [0-9]+ days\)\.$' && echo yes || echo no)"
write_manifest "$D3" scripts-v1.6.0 103 1.0.0; with_headers "$D3" date=2019-10-01 expires=2019-12-31
sign "$D3" key1; sidecars "$D3"
publish "$D3" scripts-v1.6.0
install_release "$D3"
run_check
check_rc "real date, expired 2019-12-31: exits 1" 1 "$RC"
check "real date, expired 2019-12-31: days ago counted" "yes" \
    "$(plain "$OUT" | grep -qE '^  \[WARN\] Installed release scripts-v1\.6\.0 expired on 2019-12-31 \([0-9]+ days ago\); a newer signed release is overdue\.$' && echo yes || echo no)"

# An expired release that ships a new updater: the running updater downloads and
# verifies first, then the release copy runs and prints the warning, once.
UE="$SRC/selfexp"; rm -rf "$UE"; cp -R "$U" "$UE"
write_manifest "$UE" scripts-v1.7.0 104 1.0.0; with_headers "$UE" date=2026-11-03 expires=2027-02-01
sign "$UE" key1; sidecars "$UE"
publish "$UE" scripts-v1.7.0
install_release "$R2"
rm -f "$MARK"
TODAY=2027-02-02 run_updater y
check_rc "self-update, expired: exits 0" 0 "$RC"
check "self-update, expired: release copy ran once" "ran" "$(cat "$MARK" 2>/dev/null)"
check "self-update, expired: installed" "$(_h "$UE/MANIFEST")" "$(_h "$INST/MANIFEST")"
check "self-update, expired: one warning" "1" "$(plain "$OUT" | grep -c 'expired on 2027-02-01; a newer signed release is overdue')"
check "self-update, expired: the release copy warns, after the files are verified" "yes" \
    "$(plain "$OUT" | awk '/Running the scripts-v1.7.0 copy/ {r = NR} /expired on 2027-02-01/ {w = NR} END {print (r && w && r < w) ? "yes" : "no"}')"

# The 2.0.0 updater on main (1187ddb) checked an SSH signature file that an
# OpenPGP-signed release does not carry: it refuses the release and changes
# nothing, and the host takes the release with the installer.
if command -v git >/dev/null 2>&1 && git -C "$REPO" cat-file -e 1187ddb:update-scripts.sh 2>/dev/null; then
    publish "$R3" scripts-v1.5.0
    install_release "$R2"
    rm -f "$INST/MANIFEST" "$INST/MANIFEST.asc"
    git -C "$REPO" show 1187ddb:update-scripts.sh > "$INST/update-scripts.sh"
    TODAY=2026-11-03 refused "2.0.0 updater, OpenPGP-signed release"
    says "2.0.0 updater, OpenPGP-signed release" "Release scripts-v1.5.0 has no MANIFEST"
else
    skip "2.0.0 updater and an OpenPGP-signed release" "git or commit 1187ddb not available"
fi
TODAY=""

# --- no release published yet ---------------------------------------------------------------
rm -f "$RAW/main/RELEASE"
install_release "$R1"
refused "no RELEASE"
says "no RELEASE" "No signed script release is published yet"

finish
