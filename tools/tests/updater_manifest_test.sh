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
# and logs the URL. Releases are signed with a throwaway ed25519 key made with
# ssh-keygen -N '' in the temp dir. Where ssh-keygen is absent (the bash:3.2
# image) a fake ssh-keygen with the same -Y sign / -Y verify interface stands
# in, so the updater's bash 3.2 path still runs; the real-signature case is then
# reported as SKIP.
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

# --- signing: real ssh-keygen, else a fake with the same interface ------------

REAL_SSH=0
if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -q -t ed25519 -N '' -C probe -f "$T/probe" >/dev/null 2>&1 \
        && printf 'x\n' > "$T/probe.txt" \
        && ssh-keygen -Y sign -f "$T/probe" -n tn-node-scripts "$T/probe.txt" >/dev/null 2>&1 \
        && REAL_SSH=1
fi
if [[ $REAL_SSH -eq 0 ]]; then
    cat > "$BIN/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
# Fake ssh-keygen for hosts without OpenSSH. A "key" is a random token; a
# signature names the namespace, the token and the SHA-256 of the data.
h() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | awk '{print $1}'; }
mode="" key="" ns="" princ="" sig="" file=""
while [ $# -gt 0 ]; do
    case "$1" in
        -Y) mode="$2"; shift ;;
        -f) key="$2"; shift ;;
        -n) ns="$2"; shift ;;
        -I) princ="$2"; shift ;;
        -s) sig="$2"; shift ;;
        -t|-N|-C) shift ;;
        -q) ;;
        *) file="$1" ;;
    esac
    shift
done
case "$mode" in
    "")
        tok="k${RANDOM}${RANDOM}${RANDOM}$$"
        echo "FAKEKEY $tok" > "$key"
        echo "fake-ed25519 $tok" > "$key.pub" ;;
    sign)
        tok="$(awk '{print $2}' "$key")"
        printf 'FAKESIG %s %s %s\n' "$ns" "$tok" "$(h < "$file")" > "$file.sig" ;;
    verify)
        read -r magic sns stok shash < "$sig" || { echo "bad signature" >&2; exit 255; }
        [ "$magic" = FAKESIG ] && [ "$sns" = "$ns" ] || { echo "bad signature" >&2; exit 255; }
        grep -v '^[[:space:]]*#' "$key" | grep -F "$princ namespaces=\"$ns\" fake-ed25519 $stok" >/dev/null \
            || { echo "no principal matched" >&2; exit 255; }
        [ "$(h)" = "$shash" ] || { echo "signature verification failed" >&2; exit 255; }
        echo "Good \"$ns\" signature for $princ with FAKE key $stok" ;;
esac
EOF
    chmod +x "$BIN/ssh-keygen"
fi
export PATH="$BIN:$PATH"

# newkey NAME -- make a key; print its allowed-signers line.
newkey() {
    ssh-keygen -q -t ed25519 -N '' -C "$1" -f "$T/$1" >/dev/null 2>&1
    printf 'release@telcoin.org namespaces="tn-node-scripts" %s\n' "$(awk '{print $1, $2}' "$T/$1.pub")"
}
KEY1_LINE="$(newkey key1)"
KEY2_LINE="$(newkey key2)"

# --- release fixtures ----------------------------------------------------------

# A source tree for one release: SRC/<tag>/<files>. Files are small stand-ins
# except update-scripts.sh, the real updater under test.
SRC="$T/src"

base_tree() {   # base_tree DIR
    mkdir -p "$1/lib" "$1/ui"
    cp "$REPO/update-scripts.sh" "$1/update-scripts.sh"
    {
        printf '# test signers\n'
        printf '%s\n' "$KEY1_LINE"
    } > "$1/lib/allowed_signers"
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
        (cd "$d" && find . -type f ! -name MANIFEST ! -name 'MANIFEST.sig' ! -name '*.sha256' | sed 's|^\./||' | LC_ALL=C sort) \
            | while IFS= read -r p; do
                printf 'sha256  %s  %s\n' "$(_h "$d/$p")" "$p"
            done
    } > "$d/MANIFEST"
}

sign() {   # sign DIR KEYNAME
    rm -f "$1/MANIFEST.sig"
    ssh-keygen -Y sign -f "$T/$2" -n tn-node-scripts "$1/MANIFEST" >/dev/null 2>&1
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

if [[ $REAL_SSH -eq 1 ]]; then
    check "signer: real ssh-keygen in use" "1" "$REAL_SSH"
else
    skip "real ssh-keygen signatures" "ssh-keygen absent: a fake signer stands in"
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
check "good: MANIFEST.sig record is R2" "$(_h "$R2/MANIFEST.sig")" "$(_h "$INST/MANIFEST.sig")"
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
check_has "wrong signer: says why" "  [ERROR] The release manifest is not signed by a Telcoin release key; nothing was changed." "$(plain "$OUT")"

# --- tampered MANIFEST (signed, then one hash changed) -------------------------------
X="$SRC/tampered"; cp -R "$R2" "$X"
awk -v h="$(_h "$R1/setup-node.sh")" '$3 == "setup-node.sh" {$0 = "sha256  " h "  setup-node.sh"} {print}' "$R2/MANIFEST" > "$X/MANIFEST"
cp "$R1/setup-node.sh" "$X/setup-node.sh"
publish "$X" scripts-v1.1.0
install_release "$R1"
printf 'local edit\n' >> "$INST/setup-node.sh"
refused "tampered manifest"
says "tampered manifest" "not signed by a Telcoin release key"

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
check "path outside the tree: nothing written beside the tree" "absent" "$([[ -e "$T/escape.sh" ]] && echo present || echo absent)"

# --- manifest without lib/allowed_signers ------------------------------------------------------
N="$SRC/nosigners"; cp -R "$R2" "$N"
grep -v '  lib/allowed_signers$' "$R2/MANIFEST" > "$N/MANIFEST"; sign "$N" key1
publish "$N" scripts-v1.1.0
install_release "$R1"
refused "signer list not listed"
says "signer list not listed" "lib/allowed_signers not listed"

# --- self-update: the release ships a different updater ------------------------------------
U="$SRC/selfupd"; cp -R "$R2" "$U"
printf '# fixture: release copy of the updater\n' >> "$U/update-scripts.sh"
write_manifest "$U" scripts-v1.3.0 103 1.0.0; sign "$U" key1; sidecars "$U"
publish "$U" scripts-v1.3.0
install_release "$R1"
run_updater y
check_rc "self-update: exits 0" 0 "$RC"
check "self-update: updater is the release copy" "$(_h "$U/update-scripts.sh")" "$(_h "$INST/update-scripts.sh")"
check "self-update: rest installed by the new copy" "$(_h "$U/MANIFEST")" "$(_h "$INST/MANIFEST")"
check_has "self-update: relaunched" "  ->  Updating the updater itself to the scripts-v1.3.0 copy and relaunching..." "$(plain "$OUT")"

# --- self-update refused: the release copy is older than its own min_updater ---------------
V="$SRC/selfold"; cp -R "$U" "$V"
write_manifest "$V" scripts-v1.4.0 104 99.0.0; sign "$V" key1; sidecars "$V"
publish "$V" scripts-v1.4.0
install_release "$R1"
refused "self-update below min_updater"
says "self-update below min_updater" "needs update-scripts.sh 99.0.0 or newer"

# --- first signed release on an old tree: signer list through its sidecar ------------------
install_release "$R1"
rm -f "$INST/MANIFEST" "$INST/MANIFEST.sig" "$INST/lib/allowed_signers"
publish "$R2" scripts-v1.1.0
run_updater y
check_rc "bootstrap: exits 0" 0 "$RC"
check "bootstrap: signer list installed" "$(_h "$R2/lib/allowed_signers")" "$(_h "$INST/lib/allowed_signers" 2>/dev/null)"
check "bootstrap: release recorded" "$(_h "$R2/MANIFEST")" "$(_h "$INST/MANIFEST" 2>/dev/null)"

install_release "$R1"
rm -f "$INST/MANIFEST" "$INST/MANIFEST.sig" "$INST/lib/allowed_signers"
G="$SRC/bootbad"; cp -R "$R2" "$G"
printf '%s  lib/allowed_signers\n' "$(_h "$R1/setup-node.sh")" > "$G/lib/allowed_signers.sha256"
publish "$G" scripts-v1.1.0
refused "bootstrap: signer sidecar mismatch"
says "bootstrap: signer sidecar mismatch" "does not match its published checksum"

install_release "$R1"
rm -f "$INST/lib/allowed_signers"
publish "$R2" scripts-v1.1.0
refused "signer list deleted after a signed install"
says "signer list deleted after a signed install" "lib/allowed_signers is missing"

# --- no release published yet ---------------------------------------------------------------
rm -f "$RAW/main/RELEASE"
install_release "$R1"
refused "no RELEASE"
says "no RELEASE" "No signed script release is published yet"

finish
