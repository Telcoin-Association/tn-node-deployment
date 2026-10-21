#!/usr/bin/env bash
# =============================================================================
# tools/tests/release_fetch_test.sh -- tn_fetch_verified_release,
# tn_fetch_release_image, tn_release_extract_binary and tn_release_version_ok
# against a local fixture release signed with throwaway GPG keys (made here in
# a temp GNUPGHOME). A curl shim serves the fixture for https://fixture.invalid/
# and records that every download used --proto =https. Cases: a good release;
# BADSIG (SHA256SUMS changed after signing); a tampered tarball; a revoked key
# (REVKEYSIG), alone and beside a good signature; an expired key (EXPKEYSIG); an
# unknown key alone (refused); a good signature plus one by an unknown key
# (taken, one warning naming its key id); a BADSIG by a second listed key; a key
# file with two primary keys; a chain-config line that differs from the pins; an
# extra name; a missing file (rc 2); no keys; a bad tag (rc 3, nothing
# downloaded); the staging dir is empty after every failure. The status-line
# policy of _tn_release_sig_ok is also checked against a stubbed gpgv, for the
# lines a real keyring cannot produce (a BADSIG by a key that is not there,
# EXPSIG, an ERRSIG other than a missing key). Without gpg (bash:3.2) the gpg
# cases SKIP.
#
#   bash tools/tests/release_fetch_test.sh
#
# Maintainer tooling: not tracked by update-scripts.sh, no .sha256 sidecar.
# bash 3.2 safe.
# =============================================================================
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
eval "$(tn_test_source_common)"

FIX="$T/fix"
REC="$T/rec"
STAGE="$T/stage"
KEYS="$T/keys"
mkdir -p "$T/bin" "$FIX" "$REC" "$KEYS"
mkdir -m 0700 "$STAGE"
export FIX REC
cat > "$T/bin/curl" <<'SH'
#!/bin/sh
out=""; url=""; proto=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --url) url="$2"; shift 2 ;;
        --proto) proto="$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s %s\n' "$proto" "$url" >> "$REC/curl.log"
[ "$proto" = "=https" ] || exit 1
case "$url" in
    https://fixture.invalid/*) src="$FIX/${url#https://fixture.invalid/}" ;;
    *) exit 6 ;;
esac
[ -f "$src" ] || exit 22
cat "$src" > "$out"
SH
chmod 0755 "$T/bin/curl"
PATH="$T/bin:$PATH"
export TN_RELEASE_STAGING_DIR="$STAGE" TN_RELEASE_KEYS_DIR="$KEYS"

stage_empty() {
    local n
    n="$(find "$STAGE" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
    check "$1: staging left empty" "0" "$n"
}

# --- tag form: rc 3 before anything is fetched --------------------------------
: > "$REC/curl.log"
rc=0; out="$(tn_fetch_verified_release v0.16.0 testnet https://fixture.invalid/x 2>/dev/null)" || rc=$?
check_rc "testnet refuses a mainnet-form tag" 3 "$rc"
rc=0; out="$(tn_fetch_verified_release v0.16.0-adiri mainnet https://fixture.invalid/x 2>/dev/null)" || rc=$?
check_rc "mainnet refuses an -adiri tag" 3 "$rc"
rc=0; out="$(tn_fetch_verified_release main testnet 2>/dev/null)" || rc=$?
check_rc "a branch is not a release tag" 3 "$rc"
rc=0; out="$(tn_fetch_verified_release v0.16.0-adiri devnet 2>/dev/null)" || rc=$?
check_rc "devnet has no releases" 3 "$rc"
check "nothing downloaded for a bad tag" "" "$(cat "$REC/curl.log")"
stage_empty "bad tag"

# --- tn_release_version_ok ------------------------------------------------------
V() { printf 'telcoin-network-cli Version: %s\nCommit SHA: abc\nBuild Timestamp: x\nBuild Features: %s\nBuild Profile: maxperf\n' "$1" "$2"; }
rc=0; tn_release_version_ok "$(V 0.17.0 '')" mainnet v0.17.0 2>/dev/null || rc=$?
check_rc "mainnet build, no features" 0 "$rc"
rc=0; tn_release_version_ok "$(V 0.17.0 adiri)" mainnet v0.17.0 2>/dev/null || rc=$?
check_rc "mainnet refuses adiri" 1 "$rc"
rc=0; tn_release_version_ok "$(V 0.17.0 faucet)" mainnet v0.17.0 2>/dev/null || rc=$?
check_rc "mainnet refuses faucet" 1 "$rc"
rc=0; tn_release_version_ok "$(V 0.17.0 adiri,faucet)" testnet v0.17.0-adiri 2>/dev/null || rc=$?
check_rc "testnet adiri,faucet" 0 "$rc"
rc=0; tn_release_version_ok "$(V 0.17.0 adiri)" testnet v0.17.0-adiri 2>/dev/null || rc=$?
check_rc "testnet adiri" 0 "$rc"
rc=0; tn_release_version_ok "$(V 0.17.0 faucet)" testnet v0.17.0-adiri 2>/dev/null || rc=$?
check_rc "testnet refuses faucet without adiri" 1 "$rc"
rc=0; tn_release_version_ok "$(V 0.17.0 '')" testnet v0.17.0-adiri 2>/dev/null || rc=$?
check_rc "testnet refuses no features" 1 "$rc"
rc=0; tn_release_version_ok "$(V 0.17.0 adiri,other)" testnet v0.17.0-adiri 2>/dev/null || rc=$?
check_rc "testnet refuses another feature" 1 "$rc"
rc=0; tn_release_version_ok "$(V 0.16.0 adiri)" testnet v0.17.0-adiri 2>/dev/null || rc=$?
check_rc "version must match the tag" 1 "$rc"
rc=0; tn_release_version_ok "$(V 0.17.0 ''; printf 'Build Features: adiri\n')" mainnet v0.17.0 2>/dev/null || rc=$?
check_rc "two Build Features lines refused" 1 "$rc"
rc=0; tn_release_version_ok "telcoin-network-cli Version: 0.17.0" mainnet v0.17.0 2>/dev/null || rc=$?
check_rc "no Build Features line refused" 1 "$rc"
rc=0; tn_release_version_ok "$(V 0.17.0 '*')" testnet v0.17.0-adiri 2>/dev/null || rc=$?
check_rc "a glob feature is refused, not expanded" 1 "$rc"

# --- status-line policy, gpgv stubbed ----------------------------------------------
SD="$T/sigpol"
mkdir -p "$SD/bin"
PA=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
PB=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
printf '%s\n%s\n' "$PA" "$PB" > "$SD/allow"
printf '#!/bin/sh\ncat "$SIG_STATUS"\n' > "$SD/bin/gpgv"
chmod 0755 "$SD/bin/gpgv"
GA="[GNUPG:] GOODSIG AAAAAAAAAAAAAAAA A <a@example.invalid>
[GNUPG:] VALIDSIG ${PA} 2026-10-21 0 0 4 0 22 10 00 ${PA}"
GB="[GNUPG:] GOODSIG BBBBBBBBBBBBBBBB B <b@example.invalid>
[GNUPG:] VALIDSIG ${PB} 2026-10-21 0 0 4 0 22 10 00 ${PB}"
UX="[GNUPG:] ERRSIG 1111222233334444 22 10 00 1792597639 9 11112222333344445555666677778888AAAABBBB
[GNUPG:] NO_PUBKEY 1111222233334444"
UY="[GNUPG:] ERRSIG 5555666677778888 1 8 00 1792597639 9 -
[GNUPG:] NO_PUBKEY 5555666677778888"
pol() { # STATUS-LINES -> "<rc> <printed line>"
    local rc=0 v
    printf '%s\n' "$1" > "$SD/status"
    v="$(SIG_STATUS="$SD/status" PATH="$SD/bin:$PATH" _tn_release_sig_ok "$SD")" || rc=$?
    printf '%s %s' "$rc" "$v"
}
check "policy: a good listed signature" "0 GOOD" "$(pol "$GA")"
check "policy: two good listed signatures" "0 GOOD" "$(pol "$GA
$GB")"
check "policy: good plus an unknown co-signer: taken, its key id named once" "0 GOOD 1111222233334444" "$(pol "$GA
$UX")"
check "policy: two unknown co-signers, each named once" "0 GOOD 1111222233334444 5555666677778888" "$(pol "$UX
$GA
$UY
$UX")"
check "policy: only an unknown signer refuses" "1 NOSIG 1111222233334444" "$(pol "$UX")"
check "policy: no signature at all refuses" "1 NOSIG" "$(pol "")"
check "policy: BADSIG by a key that is not there refuses" "1 BADSIG" "$(pol "$GA
[GNUPG:] BADSIG 1111222233334444 X <x@example.invalid>")"
check "policy: BADSIG by a second listed key refuses" "1 BADSIG" "$(pol "$GA
[GNUPG:] BADSIG BBBBBBBBBBBBBBBB B <b@example.invalid>")"
check "policy: EXPSIG refuses" "1 EXPSIG" "$(pol "$GA
[GNUPG:] EXPSIG BBBBBBBBBBBBBBBB B <b@example.invalid>")"
check "policy: EXPKEYSIG refuses" "1 EXPKEYSIG" "$(pol "[GNUPG:] EXPKEYSIG BBBBBBBBBBBBBBBB B <b@example.invalid>
$GA")"
check "policy: REVKEYSIG beside a good signature refuses" "1 REVKEYSIG" "$(pol "$GA
[GNUPG:] REVKEYSIG BBBBBBBBBBBBBBBB B <b@example.invalid>")"
check "policy: an ERRSIG other than a missing key refuses" "1 ERRSIG" "$(pol "$GA
[GNUPG:] ERRSIG BBBBBBBBBBBBBBBB 99 10 00 1792597639 4 ${PB}")"
check "policy: a VALIDSIG whose primary key is not listed refuses" "1 NOSIG" "$(pol "[GNUPG:] GOODSIG CCCCCCCCCCCCCCCC C <c@example.invalid>
[GNUPG:] VALIDSIG CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC 2026-10-21 0 0 4 0 22 10 00 CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC")"
check "policy: a VALIDSIG without its GOODSIG refuses" "1 NOSIG" "$(pol "[GNUPG:] VALIDSIG ${PA} 2026-10-21 0 0 4 0 22 10 00 ${PA}")"

if ! command -v gpg >/dev/null 2>&1 || ! command -v gpgv >/dev/null 2>&1; then
    skip "release fixture" "gpg absent"
    finish
fi

# --- fixture keys -----------------------------------------------------------------
export GNUPGHOME="$T/gnupg"
mkdir -m 0700 "$GNUPGHOME"
G() { gpg --batch --no-tty --quiet --pinentry-mode loopback --passphrase '' "$@"; }
fpr_of() { gpg --batch --with-colons --list-keys "$1" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }'; }
G --quick-gen-key 'Release A <a@example.invalid>' ed25519 sign 1y 2>/dev/null
G --quick-gen-key 'Release B <b@example.invalid>' ed25519 sign 1y 2>/dev/null
G --quick-gen-key 'Release C <c@example.invalid>' ed25519 sign 1y 2>/dev/null
G --faked-system-time 20200101T000000 --quick-gen-key 'Release D <d@example.invalid>' ed25519 sign 2d 2>/dev/null
FA="$(fpr_of a@example.invalid)"; FB="$(fpr_of b@example.invalid)"
FC="$(fpr_of c@example.invalid)"; FD="$(fpr_of d@example.invalid)"
if [[ -z "$FA" || -z "$FB" || -z "$FC" || -z "$FD" ]]; then
    skip "release fixture" "gpg could not make the throwaway keys"
    finish
fi
G --armor --export "$FA" > "$KEYS/a.asc"
G --armor --export "$FD" > "$KEYS/d.asc"
# C signs first, then is revoked; the key file carries the revocation.
TAG=v0.17.0-adiri
TRIPLE="$(_tn_release_triple)"
TARBALL="telcoin-network-${TAG}-${TRIPLE}.tar.gz"
REL="$FIX/$TAG"
mkdir -p "$REL" "$T/tar/telcoin-network-${TAG}-${TRIPLE}"
printf '#!/bin/sh\necho node\n' > "$T/tar/telcoin-network-${TAG}-${TRIPLE}/telcoin-network"
chmod 0755 "$T/tar/telcoin-network-${TAG}-${TRIPLE}/telcoin-network"
for f in LICENSE-APACHE LICENSE-MIT NOTICE; do printf '%s\n' "$f" > "$T/tar/telcoin-network-${TAG}-${TRIPLE}/$f"; done
tar -czf "$REL/$TARBALL" -C "$T/tar" "telcoin-network-${TAG}-${TRIPLE}"
D64="$(printf 'image' | sha256sum | cut -d' ' -f1)"
printf '%s@sha256:%s\n' "$GAR_IMAGE_BASE" "$D64" > "$REL/IMAGE_DIGEST"
h() { sha256sum < "$1" | cut -d' ' -f1; }
write_sums() { # [committee-hash]
    {
        printf '%s  %s\n' "$(h "$REL/IMAGE_DIGEST")" IMAGE_DIGEST
        printf '%s  chain-configs/testnet/committee.yaml\n' "${1:-$TESTNET_COMMITTEE_SHA256}"
        printf '%s  chain-configs/testnet/genesis.yaml\n' "$TESTNET_GENESIS_SHA256"
        printf '%s  chain-configs/testnet/parameters.yaml\n' "$TESTNET_PARAMETERS_SHA256"
        printf '%s  %s\n' "$(h "$REL/$TARBALL")" "$TARBALL"
    } > "$REL/SHA256SUMS"
}
sign() { # FPR [FPR...]: one detached signature per key, appended
    local k
    : > "$REL/SHA256SUMS.asc"
    for k in "$@"; do
        G --faked-system-time "${FAKE_TIME:-}" -u "$k" --armor --detach-sign -o - "$REL/SHA256SUMS" >> "$REL/SHA256SUMS.asc" 2>/dev/null \
            || G -u "$k" --armor --detach-sign -o - "$REL/SHA256SUMS" >> "$REL/SHA256SUMS.asc"
    done
}
write_sums
sign "$FA"
fetch() { # TAG -> rc in RC, stdout in OUT
    RC=0
    OUT="$(tn_fetch_verified_release "$1" testnet "https://fixture.invalid/$1" 2>"$T/err")" || RC=$?
}

# --- good ---------------------------------------------------------------------------
: > "$REC/curl.log"
fetch "$TAG"
check_rc "good release" 0 "$RC"
check "good: tarball path" "$TARBALL" "${OUT##*/}"
check "good: tarball in staging" "1" "$( [[ -f "$OUT" && "$OUT" == "$STAGE"/rel.*/"$TARBALL" ]] && echo 1 || echo 0)"
check "good: verified SHA256SUMS beside it" "1" "$( [[ -f "${OUT%/*}/SHA256SUMS" ]] && echo 1 || echo 0)"
check "every download used --proto =https" "0" "$(grep -vc '^=https ' "$REC/curl.log")"
check "four files downloaded" "4" "$(wc -l < "$REC/curl.log" | tr -d ' ')"
rc=0; tn_release_extract_binary "$OUT" "$T/node.bin" || rc=$?
check_rc "extract: good tarball" 0 "$rc"
check "extract: binary content" "$(cat "$T/tar/telcoin-network-${TAG}-${TRIPLE}/telcoin-network")" "$(cat "$T/node.bin")"
check "extract: mode" "755" "$(stat -c '%a' "$T/node.bin")"
_tn_release_cleanup "${OUT%/*}"
stage_empty "good, after cleanup"
rc=0; img="$(tn_fetch_release_image "$TAG" testnet "https://fixture.invalid/$TAG" 2>/dev/null)" || rc=$?
check_rc "image: good" 0 "$rc"
check "image: by digest" "${GAR_IMAGE_BASE}@sha256:${D64}" "$img"
stage_empty "image"

# --- BADSIG: SHA256SUMS changed after it was signed -------------------------------
cp "$REL/SHA256SUMS" "$T/sums.good"
sed 's/^\(.\)/0/' "$T/sums.good" | head -n 1 > "$REL/SHA256SUMS"; sed -n '2,$p' "$T/sums.good" >> "$REL/SHA256SUMS"
fetch "$TAG"
check_rc "BADSIG refused" 1 "$RC"
check_has "BADSIG named" "1" "$(grep -c BADSIG "$T/err")"
stage_empty "BADSIG"
cp "$T/sums.good" "$REL/SHA256SUMS"

# --- tampered tarball ------------------------------------------------------------------
cp "$REL/$TARBALL" "$T/tar.good"
printf 'x' >> "$REL/$TARBALL"
fetch "$TAG"
check_rc "tampered tarball refused" 1 "$RC"
stage_empty "tampered tarball"
cp "$T/tar.good" "$REL/$TARBALL"

# --- unknown key -------------------------------------------------------------------------
sign "$FB"
fetch "$TAG"
check_rc "unknown key refused" 1 "$RC"
stage_empty "unknown key"

# --- a good signature plus one by an unknown key: taken, with one warning ------------------
KB="${FB:24:16}"
sign "$FA" "$FB"
fetch "$TAG"
check_rc "a good signature plus one by an unknown key: taken" 0 "$RC"
check "unknown co-signer: one warning line names its key id" "1" "$(grep -c "$KB" "$T/err")"
check_has "unknown co-signer: the warning says the key is not there" "1" "$(grep -c 'not in .*so that signature was not checked' "$T/err")"
[[ "$RC" -eq 0 ]] && _tn_release_cleanup "${OUT%/*}"
stage_empty "two signatures"

# --- two good signatures by listed keys ----------------------------------------------------
G --armor --export "$FB" > "$KEYS/b.asc"
sign "$FA" "$FB"
fetch "$TAG"
check_rc "two listed signers" 0 "$RC"
[[ "$RC" -eq 0 ]] && _tn_release_cleanup "${OUT%/*}"
check "two listed signers: no warning" "0" "$(grep -c 'not checked' "$T/err")"

# --- a BADSIG by the second listed key next to a good one ----------------------------------
printf 'not the release\n' > "$T/other.txt"
sign "$FA"
G -u "$FB" --armor --detach-sign -o - "$T/other.txt" >> "$REL/SHA256SUMS.asc"
fetch "$TAG"
check_rc "a BADSIG by a second listed key refused" 1 "$RC"
check_has "second listed key: BADSIG named" "1" "$(grep -c BADSIG "$T/err")"
stage_empty "BADSIG by a second listed key"
rm -f "$KEYS/b.asc"

# --- one key file carrying two primary keys --------------------------------------------------
mv "$KEYS/a.asc" "$T/a.asc.away"
G --armor --export "$FA" "$FB" > "$KEYS/ab.asc"
sign "$FB"
fetch "$TAG"
check_rc "one armored block, two primaries: the second one's signature taken" 0 "$RC"
[[ "$RC" -eq 0 ]] && _tn_release_cleanup "${OUT%/*}"
{ G --armor --export "$FA"; G --armor --export "$FB"; } > "$KEYS/ab.asc"
fetch "$TAG"
check_rc "two armored blocks in one file: the second one's signature taken" 0 "$RC"
[[ "$RC" -eq 0 ]] && _tn_release_cleanup "${OUT%/*}"
rm -f "$KEYS/ab.asc"
mv "$T/a.asc.away" "$KEYS/a.asc"

# --- REVKEYSIG ------------------------------------------------------------------------------
# Both signature files are made while C still signs; the revocation comes after.
sign "$FA" "$FC"
cp "$REL/SHA256SUMS.asc" "$T/ac.asc"
sign "$FC"
rev="$(ls "$GNUPGHOME"/openpgp-revocs.d/"$FC".rev 2>/dev/null)"
if [[ -n "$rev" ]]; then
    sed 's/^:-----/-----/' "$rev" | G --import 2>/dev/null
    G --armor --export "$FC" > "$KEYS/c.asc"
    fetch "$TAG"
    check_rc "revoked key refused" 1 "$RC"
    check_has "REVKEYSIG named" "1" "$(grep -c REVKEYSIG "$T/err")"
    stage_empty "revoked key"
    cp "$T/ac.asc" "$REL/SHA256SUMS.asc"
    fetch "$TAG"
    [[ "$RC" -eq 0 ]] && _tn_release_cleanup "${OUT%/*}"
    check_rc "a revoked key beside a good listed signature refused" 1 "$RC"
    check_has "revoked beside good: REVKEYSIG named" "1" "$(grep -c REVKEYSIG "$T/err")"
    stage_empty "revoked beside good"
    rm -f "$KEYS/c.asc"
else
    skip "revoked key" "no revocation certificate in GNUPGHOME"
fi

# --- EXPKEYSIG: key D expired in 2020; the signature was made while it was valid -----------
FAKE_TIME=20200101T120000 sign "$FD"
fetch "$TAG"
check_rc "expired key refused" 1 "$RC"
check_has "EXPKEYSIG named" "1" "$(grep -c EXPKEYSIG "$T/err")"
stage_empty "expired key"

# --- chain-config line differs from the pins ------------------------------------------------
write_sums "$(printf 'other' | sha256sum | cut -d' ' -f1)"
sign "$FA"
fetch "$TAG"
check_rc "chain-config mismatch refused" 1 "$RC"
check_has "mismatch names the file" "1" "$(grep -c 'chain-configs/testnet/committee.yaml' "$T/err")"
stage_empty "chain-config mismatch"

# --- an extra name / a missing chain-config line ----------------------------------------------
write_sums
printf '%s  ../../etc/passwd\n' "$D64" >> "$REL/SHA256SUMS"
sign "$FA"
fetch "$TAG"
check_rc "extra name refused" 1 "$RC"
stage_empty "extra name"
write_sums
grep -v parameters.yaml "$REL/SHA256SUMS" > "$T/s4"; cp "$T/s4" "$REL/SHA256SUMS"
sign "$FA"
fetch "$TAG"
check_rc "missing chain-config line refused" 1 "$RC"
stage_empty "missing line"

# --- IMAGE_DIGEST not one digest line ----------------------------------------------------------
cp "$REL/IMAGE_DIGEST" "$T/img.good"
printf '%s:latest\n' "$GAR_IMAGE_BASE" > "$REL/IMAGE_DIGEST"
write_sums
sign "$FA"
fetch "$TAG"
check_rc "IMAGE_DIGEST by tag refused" 1 "$RC"
stage_empty "IMAGE_DIGEST by tag"
cp "$T/img.good" "$REL/IMAGE_DIGEST"

# --- image in the repository the release workflow publishes to ----------------------------------
printf 'ghcr.io/telcoin-association/telcoin-network@sha256:%s\n' "$D64" > "$REL/IMAGE_DIGEST"
write_sums
sign "$FA"
rc=0; img="$(tn_fetch_release_image "$TAG" testnet "https://fixture.invalid/$TAG" 2>/dev/null)" || rc=$?
check "image in ghcr.io/telcoin-association/telcoin-network: taken" "0 ghcr.io/telcoin-association/telcoin-network@sha256:${D64}" "$rc $img"
stage_empty "ghcr repository"
printf 'ghcr.io/someone-else/telcoin-network@sha256:%s\n' "$D64" > "$REL/IMAGE_DIGEST"
write_sums
sign "$FA"
rc=0; img="$(tn_fetch_release_image "$TAG" testnet "https://fixture.invalid/$TAG" 2>/dev/null)" || rc=$?
check "image in a repository not in the list refused" "1 " "$rc $img"
cp "$T/img.good" "$REL/IMAGE_DIGEST"

# --- image from another repository ---------------------------------------------------------------
printf 'evil.example/adiri@sha256:%s\n' "$D64" > "$REL/IMAGE_DIGEST"
write_sums
sign "$FA"
rc=0; img="$(tn_fetch_release_image "$TAG" testnet "https://fixture.invalid/$TAG" 2>/dev/null)" || rc=$?
check_rc "image from another repository refused" 1 "$rc"
check "no image printed" "" "$img"
stage_empty "other repository"
cp "$T/img.good" "$REL/IMAGE_DIGEST"

# --- a missing file is a network failure (rc 2) ----------------------------------------------------
write_sums
sign "$FA"
mv "$REL/$TARBALL" "$T/tar.away"
fetch "$TAG"
check_rc "missing tarball is rc 2" 2 "$RC"
stage_empty "missing tarball"
mv "$T/tar.away" "$REL/$TARBALL"

# --- no keys ---------------------------------------------------------------------------------------
mkdir -p "$T/nokeys"
RC=0; OUT="$(TN_RELEASE_KEYS_DIR="$T/nokeys" tn_fetch_verified_release "$TAG" testnet "https://fixture.invalid/$TAG" 2>/dev/null)" || RC=$?
check_rc "no keys refused" 1 "$RC"
stage_empty "no keys"

# --- staging dir that is not 0700 -------------------------------------------------------------------
chmod 0755 "$STAGE"
fetch "$TAG"
check_rc "loose staging dir refused" 1 "$RC"
chmod 0700 "$STAGE"

# --- good again after all that -----------------------------------------------------------------------
fetch "$TAG"
check_rc "good release again" 0 "$RC"
[[ "$RC" -eq 0 ]] && _tn_release_cleanup "${OUT%/*}"

# --- tarball layout ---------------------------------------------------------------------------------
mkdir -p "$T/bad1/telcoin-network-${TAG}-${TRIPLE}"
cp "$T/tar/telcoin-network-${TAG}-${TRIPLE}"/* "$T/bad1/telcoin-network-${TAG}-${TRIPLE}/"
printf 'x\n' > "$T/bad1/telcoin-network-${TAG}-${TRIPLE}/extra"
tar -czf "$T/bad1/$TARBALL" -C "$T/bad1" "telcoin-network-${TAG}-${TRIPLE}"
rc=0; tn_release_extract_binary "$T/bad1/$TARBALL" "$T/bad1.bin" 2>/dev/null || rc=$?
check_rc "extract: extra member refused" 1 "$rc"
mkdir -p "$T/bad2/telcoin-network-${TAG}-${TRIPLE}"
for f in LICENSE-APACHE LICENSE-MIT NOTICE; do printf '%s\n' "$f" > "$T/bad2/telcoin-network-${TAG}-${TRIPLE}/$f"; done
ln -s /bin/sh "$T/bad2/telcoin-network-${TAG}-${TRIPLE}/telcoin-network"
tar -czf "$T/bad2/$TARBALL" -C "$T/bad2" "telcoin-network-${TAG}-${TRIPLE}"
rc=0; tn_release_extract_binary "$T/bad2/$TARBALL" "$T/bad2.bin" 2>/dev/null || rc=$?
check_rc "extract: symlinked binary refused" 1 "$rc"
check "extract: nothing written for a symlink" "0" "$( [[ -e "$T/bad2.bin" ]] && echo 1 || echo 0)"

gpgconf --kill all >/dev/null 2>&1 || true
finish
