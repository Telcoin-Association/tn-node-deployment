#!/usr/bin/env bash
# =============================================================================
# tasks/verify-r2/V7/t_bootstrap_install.sh -- V7 SIG items 4 and 5, and key
# rotation: update-scripts.sh on a host with no release key and no MANIFEST
# (bootstrap), install.sh with its embedded keys, and a second release that
# adds a key.
#
#   bash tasks/verify-r2/V7/t_bootstrap_install.sh   (host: gpg and gpgv)
# bash 3.2 safe.
# =============================================================================

set -u
# shellcheck source=tasks/verify-r2/V7/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
command -v gpg >/dev/null 2>&1 && command -v gpgv >/dev/null 2>&1 || { echo "needs gpg and gpgv"; exit 2; }

R="${V7_TMP}/repo"
SERVE="${V7_TMP}/serve"
BIN="${V7_TMP}/bin"
TODAY="$(date -u +%Y-%m-%d)"
v7_keys
v7_build_release "$R"
(cd "$R" && HOME="${V7_TMP}/home" bash tools/release-scripts.sh --serial 1 --date "$TODAY" "$V7_TAG" >/dev/null 2>&1)
v7_sign "$R/MANIFEST.asc" valid "$R/MANIFEST"
(cd "$R" && bash tools/release-scripts.sh --check --require-sig --tag "$V7_TAG" >/dev/null 2>&1)
chk "setup: release 1 checks" 0 "$?"
v7_git -C "$R" add MANIFEST MANIFEST.asc RELEASE install.sh
v7_git -C "$R" commit -q -m "release: ${V7_TAG}"
v7_serve_init "$SERVE" "$R"
v7_serve_pack "$SERVE"
v7_shim "$BIN" "$SERVE"
PACK="$SERVE/pack/tn-node-deployment-${V7_TAG}"
cp -R "$PACK" "${V7_TMP}/pack.orig"

restore() {
    rm -rf "$PACK"
    cp -R "${V7_TMP}/pack.orig" "$PACK"
    v7_serve_pack "$SERVE"
}
N=0
# bare_host [UPDATER] -- a host dir with only update-scripts.sh.
bare_host() {
    N=$((N + 1))
    H="${V7_TMP}/bhost$N"
    mkdir -p "$H"
    cp "${1:-$R/update-scripts.sh}" "$H/update-scripts.sh"
}
listing() { (cd "$1" && find . | LC_ALL=C sort | tr '\n' ' '); }
upd() {
    RC=0
    OUT="$(printf '%s\n' "$1" | PATH="$BIN:$PATH" TERM=dumb bash "$H/update-scripts.sh" 2>&1)" || RC=$?
}
keys_match_manifest() {
    local f bad=0
    for f in "$1"/lib/release-keys/*.asc; do
        [[ "sha256  $(v7_sha "$f")  lib/release-keys/${f##*/}" == "$(grep "  lib/release-keys/${f##*/}\$" "$1/MANIFEST")" ]] || bad=1
    done
    printf '%s %s\n' "$bad" "$(find "$1/lib/release-keys" -name '*.asc' | wc -l | tr -d ' ')"
}

echo "== 4 bootstrap"
bare_host; before="$(listing "$H")"
upd y
chk "bootstrap happy: rc 0" 0 "$RC"
chk_has "bootstrap happy: one-time warning" "First signed release on this host: fetching the release keys through their published checksums" "$OUT"
chk_has "bootstrap happy: signed by the valid key" "Release manifest signed by release key $(v7_fpr valid)" "$OUT"
chk "bootstrap happy: installed keys hash to the MANIFEST lines (bad count)" "0 5" "$(keys_match_manifest "$H")"
chk "bootstrap happy: MANIFEST and MANIFEST.asc installed" "yes yes" "$([[ -f "$H/MANIFEST" ]] && echo yes) $([[ -f "$H/MANIFEST.asc" ]] && echo yes)"
chk "bootstrap happy: no lib/allowed_signers, no staging dir left" "no 0" "$([[ -e "$H/lib/allowed_signers" ]] && echo yes || echo no) $(find "$H" -maxdepth 1 -name '.tn-update.*' | wc -l | tr -d ' ')"
RC=0; OUT="$(PATH="$BIN:$PATH" bash "$H/update-scripts.sh" --check 2>&1)" || RC=$?
chk "bootstrap happy: --check afterwards rc 0" 0 "$RC"

bare_host "$V7_WT/update-scripts.sh"
upd y
chk "bootstrap with an older updater (self-update path): rc 0" 0 "$RC"
chk_has "bootstrap with an older updater: runs the release copy" "copy of update-scripts.sh to install the release" "$OUT"
chk "bootstrap with an older updater: keys installed and match" "0 5" "$(keys_match_manifest "$H")"
chk "bootstrap with an older updater: the updater is the release's" "$(v7_sha "$R/update-scripts.sh")" "$(v7_sha "$H/update-scripts.sh")"

refuse_case() {
    local name="$1" want="$2" before
    bare_host
    before="$(listing "$H")"
    upd y
    chk "bootstrap ${name}: rc 1" 1 "$RC"
    chk_has "bootstrap ${name}: message" "$want" "$OUT"
    chk "bootstrap ${name}: nothing installed, no staging dir" "$before" "$(listing "$H")"
    restore
}
printf '%064d  lib/release-keys/second.asc\n' 0 > "$PACK/lib/release-keys/second.asc.sha256"
refuse_case "a key sidecar that does not match" "lib/release-keys/second.asc of release ${V7_TAG} does not match its published checksum; nothing was changed."
rm -f "$PACK/lib/release-keys/second.asc.sha256"
refuse_case "a key with no sidecar" "No checksum is published for lib/release-keys/second.asc in release ${V7_TAG}; nothing was changed."
printf 'not a hash\n' > "$PACK/lib/release-keys/second.asc.sha256"
refuse_case "a malformed key sidecar" "The published checksum for lib/release-keys/second.asc in release ${V7_TAG} is malformed; nothing was changed."
cp "${V7_TMP}/keys/foreign.asc" "$PACK/lib/release-keys/second.asc"
printf '%s  lib/release-keys/second.asc\n' "$(v7_sha "$PACK/lib/release-keys/second.asc")" > "$PACK/lib/release-keys/second.asc.sha256"
refuse_case "a key file (and sidecar) that is not the MANIFEST line" "The release key lib/release-keys/second.asc fetched by checksum is not the one release ${V7_TAG} lists; nothing was changed."
cp "${V7_TMP}/keys/foreign.asc" "$PACK/lib/release-keys/second.asc"
printf '%s  lib/release-keys/second.asc\n' "$(v7_sha "$PACK/lib/release-keys/second.asc")" > "$PACK/lib/release-keys/second.asc.sha256"
: > "$PACK/MANIFEST.asc"; v7_sign "$PACK/MANIFEST.asc" foreign "$PACK/MANIFEST"
refuse_case "a swapped key that signs MANIFEST.asc (MANIFEST unchanged)" "fetched by checksum is not the one release ${V7_TAG} lists"
: > "$PACK/MANIFEST.asc"; v7_sign "$PACK/MANIFEST.asc" foreign "$PACK/MANIFEST"
refuse_case "a MANIFEST.asc by a key not in the fetched set" "no release key in lib/release-keys made a good signature"
awk '/  lib\/release-keys\/second\.asc$/ { print "sha256  " $2 "  lib/release-keys/sub/second.asc"; next } { print }' "${V7_TMP}/pack.orig/MANIFEST" > "$PACK/MANIFEST"
refuse_case "a MANIFEST naming a key below a subdirectory" "The release manifest names a bad key path lib/release-keys/sub/second.asc; nothing was changed."
grep -v '  lib/release-keys/' "${V7_TMP}/pack.orig/MANIFEST" > "$PACK/MANIFEST"
refuse_case "a MANIFEST that lists no key" "Release ${V7_TAG} lists no release key (lib/release-keys/*.asc); nothing was changed."
bare_host; cp "$PACK/MANIFEST" "$H/MANIFEST"; before="$(listing "$H")"
upd y
chk "a host with a MANIFEST and no keys: rc 1" 1 "$RC"
chk_has "a host with a MANIFEST and no keys: message" "lib/release-keys holds no release key (*.asc), so no release can be verified; nothing was changed." "$OUT"
chk "a host with a MANIFEST and no keys: unchanged" "$before" "$(listing "$H")"

echo "== 4 bootstrap trust limit (whoever serves the tag serves the keys)"
cp "${V7_TMP}/keys/foreign.asc" "$PACK/lib/release-keys/second.asc"
printf '%s  lib/release-keys/second.asc\n' "$(v7_sha "$PACK/lib/release-keys/second.asc")" > "$PACK/lib/release-keys/second.asc.sha256"
awk -v h="$(v7_sha "$PACK/lib/release-keys/second.asc")" '/  lib\/release-keys\/second\.asc$/ { print "sha256  " h "  lib/release-keys/second.asc"; next } { print }' "${V7_TMP}/pack.orig/MANIFEST" > "$PACK/MANIFEST"
: > "$PACK/MANIFEST.asc"; v7_sign "$PACK/MANIFEST.asc" foreign "$PACK/MANIFEST"
bare_host; upd n
chk "bootstrap: a tag that swaps key, sidecar, MANIFEST line and signature is accepted (NOTE: trust on first use)" "0 yes" "$RC $([[ "$OUT" == *"signed by release key $(v7_fpr foreign)"* ]] && echo yes || echo no)"
restore
bare_host; mkdir -p "$H/lib/release-keys"; cp "${V7_TMP}/keys/valid.asc" "$H/lib/release-keys/grantkee.asc"
cp "${V7_TMP}/keys/foreign.asc" "$PACK/lib/release-keys/second.asc"
printf '%s  lib/release-keys/second.asc\n' "$(v7_sha "$PACK/lib/release-keys/second.asc")" > "$PACK/lib/release-keys/second.asc.sha256"
awk -v h="$(v7_sha "$PACK/lib/release-keys/second.asc")" '/  lib\/release-keys\/second\.asc$/ { print "sha256  " h "  lib/release-keys/second.asc"; next } { print }' "${V7_TMP}/pack.orig/MANIFEST" > "$PACK/MANIFEST"
: > "$PACK/MANIFEST.asc"; v7_sign "$PACK/MANIFEST.asc" foreign "$PACK/MANIFEST"
upd n
chk "the same swap against a host that already has the release key: refused" "1" "$RC"
chk_has "the same swap against a host with the key: NOSIG" "no release key in lib/release-keys made a good signature" "$OUT"
restore
bare_host; mkdir -p "$H/lib"; printf 'release@telcoin.org namespaces="tn-node-scripts" ssh-ed25519 AAAA\n' > "$H/lib/allowed_signers"
upd y
chk "a host with a leftover lib/allowed_signers: update rc 0" 0 "$RC"
chk "a host with a leftover lib/allowed_signers: the file stays (no sweep)" yes "$([[ -e "$H/lib/allowed_signers" ]] && echo yes || echo no)"

echo "== 5 installer"
IN=0
inst() {
    IN=$((IN + 1))
    IH="${V7_TMP}/ihome$IN"
    mkdir -p "$IH"
    if [[ -n "${2:-}" ]]; then mkdir -p "$IH/telcoin-node-scripts"; printf 'old install\n' > "$IH/telcoin-node-scripts/marker"; fi
    RC=0
    OUT="$(PATH="$BIN:$PATH" HOME="$IH" bash "$1" --yes 2>&1)" || RC=$?
}
inst "$R/install.sh"
chk "installer, embedded keys: rc 0" 0 "$RC"
chk_has "installer, embedded keys: signature verified" "Release signature verified (release key $(v7_fpr valid))" "$OUT"
chk "installer: installed keys hash to the MANIFEST lines" "0 5" "$(keys_match_manifest "$IH/telcoin-node-scripts")"
chk "installer: no lib/allowed_signers installed" no "$([[ -e "$IH/telcoin-node-scripts/lib/allowed_signers" ]] && echo yes || echo no)"
chk "installer: the installed install.sh embeds the installed keys" "$(cat "$IH"/telcoin-node-scripts/lib/release-keys/*.asc | v7_sha /dev/stdin)" \
    "$(awk '/<<.TN_RELEASE_KEYS./{b=1;next} /^TN_RELEASE_KEYS$/{b=0} b' "$IH/telcoin-node-scripts/install.sh" | v7_sha /dev/stdin)"

cp "${V7_TMP}/keys/foreign.asc" "$PACK/lib/release-keys/second.asc"; v7_serve_pack "$SERVE"
inst "$R/install.sh" old
chk "installer, a key file that is not its MANIFEST line: rc 1" 1 "$RC"
chk_has "installer, a key file that is not its MANIFEST line: message" "lib/release-keys/second.asc does not match its MANIFEST hash. Nothing was installed." "$OUT"
chk "installer, refused: the old install is as it was" "./marker" "$(cd "$IH/telcoin-node-scripts" && find . -type f)"
chk "installer, refused: no staging or aside dir left" "0" "$(find "$IH" -maxdepth 1 -name '.telcoin-node-scripts*' | wc -l | tr -d ' ')"
restore

cp "${V7_TMP}/keys/foreign.asc" "$PACK/lib/release-keys/extra.asc"; v7_serve_pack "$SERVE"
inst "$R/install.sh"
chk "installer, an unlisted extra key file in the archive: rc 0" 0 "$RC"
chk "installer, the unlisted extra key file is not installed" no "$([[ -e "$IH/telcoin-node-scripts/lib/release-keys/extra.asc" ]] && echo yes || echo no)"
restore

awk -v f="${V7_TMP}/keys/valid.asc" '
    /<<.TN_RELEASE_KEYS./ { print; while ((getline l < f) > 0) print l; skip = 1; next }
    skip && /^TN_RELEASE_KEYS$/ { skip = 0 }
    skip { next } { print }' "$R/install.sh" > "${V7_TMP}/install-validonly.sh"
chk "installer copy embedding only the valid key" 1 "$(grep -c '^-----BEGIN PGP PUBLIC KEY BLOCK-----$' "${V7_TMP}/install-validonly.sh")"
: > "$PACK/MANIFEST.asc"; v7_sign "$PACK/MANIFEST.asc" second "$PACK/MANIFEST"; v7_serve_pack "$SERVE"
inst "${V7_TMP}/install-validonly.sh"
chk "installer trust root: a signature by a key the archive ships but the installer does not embed: rc 1" 1 "$RC"
chk_has "installer trust root: NOSIG" "no release key in lib/release-keys made a good signature" "$OUT"
restore
awk '/<<.TN_RELEASE_KEYS./ { print; skip = 1; next } skip && /^TN_RELEASE_KEYS$/ { skip = 0 } skip { next } { print }' "$R/install.sh" > "${V7_TMP}/install-nokeys.sh"
inst "${V7_TMP}/install-nokeys.sh"
chk "installer with an empty key block: rc 1" 1 "$RC"
chk_has "installer with an empty key block: message" "This installer carries no readable release key" "$OUT"
awk '/<<.TN_RELEASE_KEYS./ { print; b = 1; next } /^TN_RELEASE_KEYS$/ { b = 0 } b { sub(/$/, "\r") } { print }' "$R/install.sh" > "${V7_TMP}/install-crlf.sh"
inst "${V7_TMP}/install-crlf.sh"
chk "installer whose embedded keys have CRLF line endings: rc (0 would mirror tn_dearmor_keys)" 0 "$RC"
printf '   installer with CRLF embedded keys: %s\n' "$(printf '%s\n' "$OUT" | grep -E 'ERROR|verified' | head -2 | tr '\n' ' ')"

echo "== key rotation: release 2 adds new.asc"
TAG2="scripts-v2.1.1"
IH1="${V7_TMP}/ihome1/telcoin-node-scripts"
v7_newkey new valid
cp "${V7_TMP}/keys/new.asc" "$R/lib/release-keys/new.asc"
awk '{ print } /^    "lib\/release-keys\/old.asc:lib\/release-keys\/old.asc:NONE"$/ { print "    \"lib/release-keys/new.asc:lib/release-keys/new.asc:NONE\"" }' "$R/update-scripts.sh" > "$R/u.new"
mv "$R/u.new" "$R/update-scripts.sh"; chmod +x "$R/update-scripts.sh"
(cd "$R" && bash tools/gen-checksums.sh >/dev/null)
v7_git -C "$R" add -A; v7_git -C "$R" commit -q -m "add new.asc"
(cd "$R" && HOME="${V7_TMP}/home" bash tools/release-scripts.sh --date "$TODAY" "$TAG2" >/dev/null 2>&1)
chk "release 2: serial 2 by default" "serial=2" "$(grep '^serial=' "$R/MANIFEST")"
serve2() {
    rm -rf "$SERVE/pack2"; mkdir -p "$SERVE/pack2"
    (cd "$R" && "$V7_REAL_GIT" archive HEAD) | tar -xf - -C "$SERVE/pack2"
    cp "$R/MANIFEST" "$R/RELEASE" "$R/install.sh" "$SERVE/pack2/"
    cp "$1" "$SERVE/pack2/MANIFEST.asc"
    rm -f "$SERVE/tags/$TAG2"; ln -s "$SERVE/pack2" "$SERVE/tags/$TAG2"
    cp "$R/RELEASE" "$SERVE/main/RELEASE"
}
: > "${V7_TMP}/r2-new.asc"; v7_sign "${V7_TMP}/r2-new.asc" new "$R/MANIFEST"
: > "${V7_TMP}/r2-valid.asc"; v7_sign "${V7_TMP}/r2-valid.asc" valid "$R/MANIFEST"
serve2 "${V7_TMP}/r2-new.asc"
H="$IH1"; before="$(listing "$H")"; upd y
chk "rotation: release 2 signed only by the new key: refused on a release-1 host" 1 "$RC"
chk_has "rotation: release 2 signed only by the new key: NOSIG" "no release key in lib/release-keys made a good signature" "$OUT"
chk "rotation: refused host unchanged" "$before" "$(listing "$H")"
serve2 "${V7_TMP}/r2-valid.asc"
upd y
chk "rotation: release 2 signed by the installed valid key: rc 0" 0 "$RC"
chk "rotation: new.asc installed and matches MANIFEST" "0 6" "$(keys_match_manifest "$H")"
RC=0; OUT="$(PATH="$BIN:$PATH" bash "$H/update-scripts.sh" --check 2>&1)" || RC=$?
chk "rotation: --check after release 2: rc 0" 0 "$RC"

v7_finish
