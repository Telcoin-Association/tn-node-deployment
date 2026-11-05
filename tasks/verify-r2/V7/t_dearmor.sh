#!/usr/bin/env bash
# =============================================================================
# tasks/verify-r2/V7/t_dearmor.sh -- V7 SIG item 3: tn_dearmor_keys on key
# files of every shape, each keyring checked against gpg --dearmor and with
# real gpgv (through tn_verify_manifest).
#
#   bash tasks/verify-r2/V7/t_dearmor.sh       (host: gpg and gpgv)
# bash 3.2 safe.
# =============================================================================

set -u
# shellcheck source=tasks/verify-r2/V7/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
command -v gpg >/dev/null 2>&1 && command -v gpgv >/dev/null 2>&1 || { echo "t_dearmor.sh needs gpg and gpgv"; exit 2; }
cd "$V7_WT" || exit 2
awk '$0 == "# RELEASE SIGNATURES" { on = 1 } /^# --- end of RELEASE SIGNATURES/ { on = 0 } on' update-scripts.sh > "$V7_TMP/block.sh"
# shellcheck disable=SC1090,SC1091
source "$V7_TMP/block.sh"

v7_keys
D="${V7_TMP}/d"
mkdir -p "$D"
printf 'release data\n' > "$D/data"
for k in valid second; do
    : > "$D/$k.sig"
    v7_sign "$D/$k.sig" "$k" "$D/data"
done

# case NAME -- a fresh dir D/NAME for the key files of one case.
casedir() {
    rm -rf "${D:?}/$1"
    mkdir -p "$D/$1"
    printf '%s\n' "$D/$1"
}

# dearmor NAME -- tn_dearmor_keys D/NAME: sets RC, ERR and D/NAME.kr.
dearmor() {
    RC=0
    ERR="$(tn_dearmor_keys "$D/$1" 2>&1 > "$D/$1.kr")" || RC=$?
}

# verifies NAME KEY -- tn_verify_manifest with D/NAME.kr over KEY's signature.
verifies() {
    tn_verify_manifest "$D/$1.kr" "$D/$2.sig" "$D/data" 2>/dev/null
}

g --dearmor < "${V7_TMP}/keys/valid.asc" > "$D/valid.ref"
cat "${V7_TMP}/keys/valid.asc" "${V7_TMP}/keys/second.asc" | g --dearmor > "$D/both.ref" 2>/dev/null || true

echo "== accepted shapes"
c="$(casedir plain)"; cp "${V7_TMP}/keys/valid.asc" "$c/k.asc"
dearmor plain; chk "plain gpg export: rc 0" 0 "$RC"
chk "plain gpg export: the bytes of gpg --dearmor" "$(v7_sha "$D/valid.ref")" "$(v7_sha "$D/plain.kr")"
chk "plain gpg export: gpgv verifies" "GOOD $(v7_fpr valid)" "$(verifies plain valid)"
chk "plain gpg export has a CRC line" 1 "$(grep -c '^=....$' "${V7_TMP}/keys/valid.asc")"

c="$(casedir headers)"
awk 'NR == 1 { print; print "Version: GnuPG v2"; print "Comment: a throwaway key"; print "Comment: https://example.invalid/key"; next } { print }' "${V7_TMP}/keys/valid.asc" > "$c/k.asc"
dearmor headers; chk "Version:/Comment: headers and CRC: rc 0" 0 "$RC"
chk "Version:/Comment: headers: same bytes" "$(v7_sha "$D/valid.ref")" "$(v7_sha "$D/headers.kr")"
chk "Version:/Comment: headers: gpgv verifies" "GOOD $(v7_fpr valid)" "$(verifies headers valid)"

c="$(casedir nocrc)"; grep -v '^=....$' "${V7_TMP}/keys/valid.asc" > "$c/k.asc"
dearmor nocrc; chk "no CRC line: rc 0" 0 "$RC"
chk "no CRC line: same bytes" "$(v7_sha "$D/valid.ref")" "$(v7_sha "$D/nocrc.kr")"

c="$(casedir crlf)"; sed 's/$/\r/' "${V7_TMP}/keys/valid.asc" > "$c/k.asc"
chk "crlf: the file has CR" 1 "$(grep -c $'^-----BEGIN PGP PUBLIC KEY BLOCK-----\r$' "$c/k.asc")"
dearmor crlf; chk "CRLF line endings: rc 0" 0 "$RC"
chk "CRLF line endings: same bytes" "$(v7_sha "$D/valid.ref")" "$(v7_sha "$D/crlf.kr")"
chk "CRLF line endings: gpgv verifies" "GOOD $(v7_fpr valid)" "$(verifies crlf valid)"

c="$(casedir twoblocks)"; cat "${V7_TMP}/keys/valid.asc" "${V7_TMP}/keys/second.asc" > "$c/k.asc"
dearmor twoblocks; chk "two armored blocks in one file: rc 0" 0 "$RC"
chk "two armored blocks: verifies the first key" "GOOD $(v7_fpr valid)" "$(verifies twoblocks valid)"
chk "two armored blocks: verifies the second key" "GOOD $(v7_fpr second)" "$(verifies twoblocks second)"

c="$(casedir onemulti)"; g --armor --export "$(v7_fpr valid)" "$(v7_fpr second)" > "$c/k.asc"
chk "one block holding two keys: one BEGIN line" 1 "$(grep -c '^-----BEGIN' "$c/k.asc")"
dearmor onemulti; chk "one block holding two keys: rc 0" 0 "$RC"
chk "one block holding two keys: verifies both" "GOOD $(v7_fpr valid) | GOOD $(v7_fpr second)" "$(verifies onemulti valid) | $(verifies onemulti second)"

c="$(casedir twofiles)"; cp "${V7_TMP}/keys/valid.asc" "$c/a.asc"; cp "${V7_TMP}/keys/second.asc" "$c/b.asc"
dearmor twofiles; chk "two key files: rc 0, verifies both" "0 GOOD $(v7_fpr valid) | GOOD $(v7_fpr second)" "$RC $(verifies twofiles valid) | $(verifies twofiles second)"

c="$(casedir surround)"; { echo "The release key of v7"; cat "${V7_TMP}/keys/valid.asc"; echo "trailing text"; } > "$c/k.asc"
dearmor surround; chk "text before BEGIN and after END: rc 0, same bytes" "0 $(v7_sha "$D/valid.ref")" "$RC $(v7_sha "$D/surround.kr")"

c="$(casedir multidir)"; cp "${V7_TMP}/keys/valid.asc" "$c/a.asc"
c2="$(casedir multidir2)"; cp "${V7_TMP}/keys/second.asc" "$c2/b.asc"
RC=0; tn_dearmor_keys "$D/multidir" "$D/multidir2" > "$D/multidir.kr" 2>/dev/null || RC=$?
chk "two DIR arguments: rc 0, verifies the second dir's key" "0 GOOD $(v7_fpr second)" "$RC $(verifies multidir second)"

c="$(casedir symlink)"; cp "${V7_TMP}/keys/valid.asc" "$c/real.key"; ln -s real.key "$c/k.asc"
dearmor symlink; chk "only a symlinked .asc: refused as no key file" "1" "$RC"
chk_has "only a symlinked .asc: the message" "no release key file (*.asc) in" "$ERR"

echo "== refused shapes"
c="$(casedir notkey)"; printf 'this is not a key\n' > "$c/k.asc"
dearmor notkey; chk "plain text: refused" 1 "$RC"; chk_has "plain text: message" "is not an ASCII-armored OpenPGP public key" "$ERR"
c="$(casedir sigblock)"; cp "$D/valid.sig" "$c/k.asc"
dearmor sigblock; chk "a PGP SIGNATURE block: refused" 1 "$RC"
c="$(casedir secret)"; g --armor --export-secret-keys "$(v7_fpr second)" > "$c/k.asc" 2>/dev/null
chk "secret: the export is a PRIVATE KEY BLOCK" 1 "$(grep -c '^-----BEGIN PGP PRIVATE KEY BLOCK-----$' "$c/k.asc")"
dearmor secret; chk "a PRIVATE KEY BLOCK: refused" 1 "$RC"
c="$(casedir noend)"; grep -v '^-----END' "${V7_TMP}/keys/valid.asc" > "$c/k.asc"
dearmor noend; chk "no END line: refused" 1 "$RC"; chk_has "no END line: message" "public key block 1 is malformed" "$ERR"
c="$(casedir noblank)"; grep -v '^$' "${V7_TMP}/keys/valid.asc" > "$c/k.asc"
dearmor noblank; chk "no blank line after BEGIN: refused" 1 "$RC"
c="$(casedir badchar)"; awk 'NR == 4 { print substr($0, 1, 10) "*" substr($0, 12); next } { print }' "${V7_TMP}/keys/valid.asc" > "$c/k.asc"
dearmor badchar; chk "a body line with a non-base64 character: refused" 1 "$RC"
c="$(casedir emptybody)"; printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\n\n-----END PGP PUBLIC KEY BLOCK-----\n' > "$c/k.asc"
dearmor emptybody; chk "an empty body: refused" 1 "$RC"
c="$(casedir badsecond)"; { cat "${V7_TMP}/keys/valid.asc"; grep -v '^-----END' "${V7_TMP}/keys/second.asc"; } > "$c/k.asc"
dearmor badsecond; chk "a good block then a malformed one: refused" 1 "$RC"; chk_has "a good block then a malformed one: message" "public key block 2 is malformed" "$ERR"
c="$(casedir midpad)"; awk 'NR == 4 { print "QUJD=="; } { print }' "${V7_TMP}/keys/valid.asc" > "$c/k.asc"
dearmor midpad; chk "padding in the middle of the body: refused (does not decode)" 1 "$RC"
c="$(casedir emptydir)"
dearmor emptydir; chk "an empty dir: refused" 1 "$RC"
c="$(casedir onegoodonebad)"; cp "${V7_TMP}/keys/valid.asc" "$c/a.asc"; printf 'junk\n' > "$c/b.asc"
dearmor onegoodonebad; chk "a good key file and a junk one: refused whole" 1 "$RC"

echo "== decodes but is not a key (spec: armor and decode only)"
c="$(casedir garbagekey)"
{ printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\n\n'; printf 'not an OpenPGP packet at all\n' | base64; printf -- '-----END PGP PUBLIC KEY BLOCK-----\n'; } > "$c/k.asc"
dearmor garbagekey; chk "armored garbage: tn_dearmor_keys accepts it (NOTE)" 0 "$RC"
c="$(casedir garbagefirst)"; cp "$D/garbagekey/k.asc" "$c/a.asc"; cp "${V7_TMP}/keys/valid.asc" "$c/b.asc"
dearmor garbagefirst; chk "armored garbage before a real key: rc 0" 0 "$RC"
GV="$(verifies garbagefirst valid)" || true
printf '   armored garbage before the real key, verdict: %s\n' "$GV"
c="$(casedir garbagelast)"; cp "${V7_TMP}/keys/valid.asc" "$c/a.asc"; cp "$D/garbagekey/k.asc" "$c/b.asc"
dearmor garbagelast; GV2="$(verifies garbagelast valid)" || true
printf '   armored garbage after the real key, verdict: %s\n' "$GV2"
chk "armored garbage never makes a signature verify that would not: foreign stays NOSIG" "NOSIG" "$(: > "$D/f.sig"; v7_sign "$D/f.sig" foreign "$D/data"; tn_verify_manifest "$D/garbagefirst.kr" "$D/f.sig" "$D/data" 2>/dev/null)"

v7_finish
