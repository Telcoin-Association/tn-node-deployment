#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# tools/tests/signing.sh -- OpenPGP release-signing helpers for the fixture tests
#
# Sourced (never run) by updater_manifest_test.sh, install_test.sh,
# release_scripts_test.sh and cut_release_test.sh after tools/tests/lib.sh,
# with BIN set to a directory that is put first on PATH. Keys live in a
# throwaway GNUPGHOME under TN_TEST_TMP; nothing touches ~/.gnupg.
#
#   REAL_GPG        1 when gpg and gpgv can make, sign with and verify an
#                   ed25519 key here (and TN_TEST_FAKE_GPG is not 1)
#   newkey NAME [EXPIRY|--expired|--revoked]
#                   make key NAME (EXPIRY as gpg takes it, default 1y; --expired
#                   expired in 2020; --revoked carries its revocation); write its
#                   public key to $TN_TEST_TMP/NAME.asc; print its fingerprint
#   fpr_of NAME     the fingerprint newkey printed
#   sign_file FILE KEYNAME...   write FILE.asc: one armored detached signature
#                   over FILE per key, one after the other
#   sign_file_bad FILE KEYNAME  append to FILE.asc a signature by KEYNAME over
#                   other content (gpgv reports BADSIG for it)
#
# Where gpg is absent (the bash:3.2 and ubuntu:24.04 images) fake gpg and gpgv
# go into BIN, with the interfaces the scripts and tools use:
#   gpg --armor --detach-sign [-u|--local-user KEY] [--output|-o OUT] FILE
#   gpg --with-colons --import-options show-only --import < KEYFILE
#   gpg --card-status            (rc 1 when FAKE_NO_CARD=1)
#   gpg --status-fd=N -bsau KEY  and  gpg --status-fd=N --verify SIG -   (git)
#   gpgv --status-fd 1 --keyring KEYRING SIG FILE
# A fake key file is an armored block whose body is the base64 of
# "FAKEKEY <fingerprint> <ok|expired|revoked>"; a fake signature block holds
# "FAKESIG <fingerprint> <sha256 of the data>". The fake gpgv prints the status
# lines real gpgv prints (NEWSIG, GOODSIG, VALIDSIG, BADSIG, EXPKEYSIG,
# REVKEYSIG, ERRSIG ... 9 with NO_PUBKEY), so the scripts' status parser runs in
# every environment. Every fake gpg call is logged to $TN_FAKE_GPG_LOG.
#
# Maintainer tooling: not tracked by the updater, no .sha256 sidecar. bash 3.2 safe.
# =============================================================================

export GNUPGHOME="$TN_TEST_TMP/gnupg"
export TN_FAKE_GPG_LOG="$TN_TEST_TMP/gpg.log"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

_tn_g() {
    gpg --batch --no-tty --quiet --pinentry-mode loopback --passphrase '' "$@"
}

REAL_GPG=0
if [[ "${TN_TEST_FAKE_GPG:-}" != "1" ]] && command -v gpg >/dev/null 2>&1 && command -v gpgv >/dev/null 2>&1; then
    printf 'probe\n' > "$TN_TEST_TMP/probe.txt"
    if _tn_g --quick-gen-key 'Probe <probe@example.invalid>' ed25519 sign 1d >/dev/null 2>&1 \
        && _tn_g -u '<probe@example.invalid>' --armor --detach-sign -o "$TN_TEST_TMP/probe.asc" "$TN_TEST_TMP/probe.txt" >/dev/null 2>&1 \
        && _tn_g --armor --export '<probe@example.invalid>' | _tn_g --dearmor > "$TN_TEST_TMP/probe.gpg" 2>/dev/null \
        && gpgv --keyring "$TN_TEST_TMP/probe.gpg" "$TN_TEST_TMP/probe.asc" "$TN_TEST_TMP/probe.txt" >/dev/null 2>&1; then
        REAL_GPG=1
    fi
fi

if [[ $REAL_GPG -eq 0 ]]; then
    cat > "$BIN/gpg" <<'EOF'
#!/usr/bin/env bash
# Fake gpg for hosts without GnuPG (tools/tests/signing.sh).
h() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | awk '{print $1}'; }
b64d() { if [ "$(printf 'eA==' | base64 -d 2>/dev/null)" = x ]; then base64 -d; else base64 -D; fi; }
[ -z "${TN_FAKE_GPG_LOG:-}" ] || echo "gpg $*" >> "$TN_FAKE_GPG_LOG"
mode="" key="" out="" sfd="" file="" sig=""
while [ $# -gt 0 ]; do
    case "$1" in
        --card-status) mode=card ;;
        --import) mode=show ;;
        --detach-sign|-b) [ "$mode" = verify ] || mode=sign ;;
        -bsau) mode=sign; key="$2"; shift ;;
        --verify) mode=verify; sig="$2"; shift ;;
        -u|--local-user) key="$2"; shift ;;
        --local-user=*) key="${1#--local-user=}" ;;
        -o|--output) out="$2"; shift ;;
        --status-fd) sfd="$2"; shift ;;
        --status-fd=*) sfd="${1#--status-fd=}" ;;
        --passphrase|--pinentry-mode|--faked-system-time|--import-options|--keyid-format) shift ;;
        -*) ;;
        *) file="$1" ;;
    esac
    shift
done
key="${key%!}"
case "$mode" in
    card)
        [ "${FAKE_NO_CARD:-}" != 1 ] || { echo "gpg: selecting card failed: No such device" >&2; exit 2; }
        echo "Reader ...........: Fake YubiKey" ;;
    show)
        sed -n '/^-----BEGIN PGP PUBLIC KEY BLOCK-----/,/^-----END/p' | grep -E '^[A-Za-z0-9+/]+=*$' | b64d \
            | awk '$1 == "FAKEKEY" { print "pub:u:255:22:" substr($2, 25) ":1793750400:::u:::scSC::::::23::0:"; print "fpr:::::::::" $2 ":" }' ;;
    sign)
        if [ -z "$file" ] || [ "$file" = - ]; then d="$(h)"; else d="$(h < "$file")"; fi
        body="$(printf -- '-----BEGIN PGP SIGNATURE-----\n\nFAKESIG %s %s\n-----END PGP SIGNATURE-----' "$key" "$d")"
        if [ -n "$out" ] && [ "$out" != - ]; then printf '%s\n' "$body" > "$out"; else printf '%s\n' "$body"; fi
        if [ -n "$sfd" ]; then echo "[GNUPG:] SIG_CREATED D 22 10 00 1793750400 $key" >&"$sfd"; fi ;;
    verify)
        d="$(h)"
        read -r magic sk sd < <(grep '^FAKESIG ' "$sig")
        out="${sfd:-2}"
        if [ "$magic" = FAKESIG ] && [ "$sd" = "$d" ]; then
            { echo "[GNUPG:] NEWSIG"; echo "[GNUPG:] GOODSIG ${sk:24} fake"
              echo "[GNUPG:] VALIDSIG $sk 2026-11-04 1793750400 0 4 0 22 10 00 $sk"; } >&"$out"
            echo "gpg: Good signature from fake key $sk" >&2
        else
            { echo "[GNUPG:] NEWSIG"; echo "[GNUPG:] BADSIG ${sk:24} fake"; } >&"$out"
            echo "gpg: BAD signature" >&2
            exit 1
        fi ;;
    *) echo "fake gpg: unsupported call" >&2; exit 2 ;;
esac
EOF
    cat > "$BIN/gpgv" <<'EOF'
#!/usr/bin/env bash
# Fake gpgv for hosts without GnuPG (tools/tests/signing.sh).
h() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | awk '{print $1}'; }
kr="" sig="" file="" rc=0 n=0
while [ $# -gt 0 ]; do
    case "$1" in
        --status-fd) shift ;;
        --keyring) kr="$2"; shift ;;
        -*) ;;
        *) if [ -z "$sig" ]; then sig="$1"; else file="$1"; fi ;;
    esac
    shift
done
d="$(h < "$file")"
while read -r magic fpr sd; do
    [ "$magic" = FAKESIG ] || continue
    n=$((n + 1))
    id="${fpr:24}"
    echo "[GNUPG:] NEWSIG"
    state="$(awk -v f="$fpr" '$1 == "FAKEKEY" && $2 == f { print $3; exit }' "$kr" 2>/dev/null)"
    if [ -z "$state" ]; then
        echo "[GNUPG:] ERRSIG $id 22 10 00 1793750400 9 $fpr"
        echo "[GNUPG:] NO_PUBKEY $id"
        echo "gpgv: Can't check signature: No public key" >&2
        rc=2
        continue
    fi
    if [ "$sd" != "$d" ]; then
        echo "[GNUPG:] BADSIG $id fake"
        echo "gpgv: BAD signature from fake key $fpr" >&2
        rc=1
        continue
    fi
    case "$state" in
        expired) echo "[GNUPG:] EXPKEYSIG $id fake" ;;
        revoked) echo "[GNUPG:] REVKEYSIG $id fake" ;;
        *) echo "[GNUPG:] GOODSIG $id fake" ;;
    esac
    echo "[GNUPG:] VALIDSIG $fpr 2026-11-04 1793750400 0 4 0 22 10 00 $fpr"
done < <(grep '^FAKESIG ' "$sig" 2>/dev/null)
if [ "$n" -eq 0 ]; then
    echo "[GNUPG:] NODATA 1"
    echo "gpgv: no signature found" >&2
    rc=2
fi
exit "$rc"
EOF
    chmod +x "$BIN/gpg" "$BIN/gpgv"
fi
export PATH="$BIN:$PATH"

# newkey NAME [EXPIRY|--expired|--revoked] -- see the header.
newkey() {
    local name="$1" opt="${2:-1y}" fpr home state
    if [[ $REAL_GPG -eq 1 ]]; then
        if [[ "$opt" == --expired ]]; then
            _tn_g --faked-system-time 20200101T000000 --quick-gen-key "$name <$name@example.invalid>" ed25519 sign 2d >/dev/null 2>&1
            printf '20200101T000100\n' > "$TN_TEST_TMP/$name.time"
        else
            [[ "$opt" != --revoked ]] || opt=1y
            _tn_g --quick-gen-key "$name <$name@example.invalid>" ed25519 sign "$opt" >/dev/null 2>&1
        fi
        fpr="$(gpg --batch --with-colons --list-keys "<$name@example.invalid>" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
        _tn_g --armor --export "$fpr" > "$TN_TEST_TMP/$name.asc"
        if [[ "${2:-}" == --revoked ]]; then
            # The public key with its revocation, from a second home; the
            # secret key here stays usable, so the key can still sign.
            home="$TN_TEST_TMP/gnupg-revoke-$name"
            mkdir -p "$home" && chmod 700 "$home"
            GNUPGHOME="$home" _tn_g --import "$TN_TEST_TMP/$name.asc" >/dev/null 2>&1
            sed 's/^:-----BEGIN/-----BEGIN/' "$GNUPGHOME/openpgp-revocs.d/$fpr.rev" \
                | GNUPGHOME="$home" _tn_g --import >/dev/null 2>&1
            GNUPGHOME="$home" _tn_g --armor --export "$fpr" > "$TN_TEST_TMP/$name.asc"
        fi
    else
        fpr="$(printf '%s %s %s\n' "$name" "$$" "$RANDOM" | if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi \
            | awk '{print toupper(substr($1, 1, 40))}')"
        state=ok
        case "${2:-}" in
            --expired) state=expired ;;
            --revoked) state=revoked ;;
        esac
        {
            printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\n\n'
            printf 'FAKEKEY %s %s\n' "$fpr" "$state" | base64 | tr -d '\n'
            printf '\n=FAKE\n-----END PGP PUBLIC KEY BLOCK-----\n'
        } > "$TN_TEST_TMP/$name.asc"
    fi
    printf '%s\n' "$fpr" > "$TN_TEST_TMP/$name.fpr"
    printf '%s\n' "$fpr"
}

fpr_of() {
    cat "$TN_TEST_TMP/$1.fpr"
}

# _sign_one FILE KEYNAME DATA -- append to FILE.asc a signature by KEYNAME over DATA.
_sign_one() {
    local t=""
    [[ ! -f "$TN_TEST_TMP/$2.time" ]] || t="$(cat "$TN_TEST_TMP/$2.time")"
    if [[ -n "$t" ]]; then
        _tn_g --faked-system-time "$t" -u "$(fpr_of "$2")!" --armor --detach-sign -o - "$3" >> "$1.asc" 2>/dev/null
    else
        _tn_g -u "$(fpr_of "$2")!" --armor --detach-sign -o - "$3" >> "$1.asc" 2>/dev/null
    fi
}

sign_file() {
    local f="$1" k
    shift
    : > "$f.asc"
    for k in "$@"; do
        _sign_one "$f" "$k" "$f"
    done
}

sign_file_bad() {
    printf 'other content\n' > "$TN_TEST_TMP/other-content"
    _sign_one "$1" "$2" "$TN_TEST_TMP/other-content"
}
