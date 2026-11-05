#!/usr/bin/env bash
# =============================================================================
# tools/release-scripts.sh -- prepare and check a signed script release
#
#   bash tools/release-scripts.sh [--serial N] [--min-updater X.Y.Z] [--date YYYY-MM-DD] [--expires DAYS] TAG
#   bash tools/release-scripts.sh --check [--tag TAG] [--require-sig] [--require-fresh]
#
# TAG is scripts-vX.Y.Z. A release is the commit that tag names. That commit
# carries MANIFEST and MANIFEST.asc at the repository root, and RELEASE on main
# names the tag. update-scripts.sh and install.sh install a release only when
# MANIFEST.asc holds good OpenPGP signatures over MANIFEST by at least
# TN_SIG_THRESHOLD of the keys in lib/release-keys/*.asc (see RELEASE
# SIGNATURES below) and every file matches its MANIFEST hash.
#
# Prepare mode needs a clean git tree and at least one lib/release-keys/*.asc,
# each an armored public key with LF line endings and a final newline that is
# a row of an updater array. It writes:
#   install.sh  the TN_SCRIPTS_TAG line and the embedded copy of the release
#               keys (every lib/release-keys/*.asc, sorted by name)
#   RELEASE     one line, "<tag> <date>": the pointer update-scripts.sh reads from main
#   MANIFEST    format=1, release=, serial=, min_updater=, date=, expires=, then one
#               line per file: "sha256  <64 hex>  <path>", sorted by path
# and removes a MANIFEST.asc left over from the previous release. It never
# signs: it prints the gpg command the release signer runs with the release
# key. tools/cut-release.sh prep runs the whole sequence step by step.
#
#   --serial N          default: the previous MANIFEST's serial + 1 (required for
#                       the first release). Must be higher than the previous one.
#   --min-updater VER   default: the previous MANIFEST's min_updater, else the
#                       SCRIPT_VERSION of update-scripts.sh in the tree. Never higher
#                       than that SCRIPT_VERSION (the release could not install).
#   --date YYYY-MM-DD   the release date, written to RELEASE and to MANIFEST as
#                       date= (default: today, UTC).
#   --expires DAYS      the release expires DAYS days after its date (default 90,
#                       at most 3650): MANIFEST gets expires=YYYY-MM-DD. From that
#                       day the updater, the installer and check-node warn that a
#                       newer signed release is overdue; they still install it.
#                       Updaters and installers of 2.0.0 ignore date= and expires=.
#
# The file list is every path in the SCRIPTS, UI_BUNDLE and TESTNET_ADDONS_BUNDLE
# arrays of update-scripts.sh (read as text, the way tools/gen-checksums.sh reads
# them), plus install.sh and open-ui.sh; the release keys are SCRIPTS rows like
# any other file. Every array file must have a fresh .sha256 sidecar: updaters
# older than the manifest flow still read the sidecars, and a host's first
# signed release fetches the release keys through theirs.
#
# Check mode regenerates the file lines from the tree and compares them with
# MANIFEST, checks RELEASE, the install.sh tag and embedded keys, the release
# keys and the sidecars, and verifies MANIFEST.asc against lib/release-keys
# when it is present. It prints the release date and
# the expiry date, and warns when the release has expired (date= and expires= are
# optional: the manifests of 2.0.0 have neither). Without MANIFEST it reports that
# there is nothing to check and exits 0, unless --tag, --require-sig or
# --require-fresh is given. --tag also requires release= to equal TAG; --tag and
# --require-sig require a MANIFEST.asc that verifies; --require-fresh fails the
# check when the release has expired (today, UTC, is on or after expires=). CI
# runs check mode on release changes and tags, without --require-fresh.
#
# Needs gpgv to check a signature, and gpg only to print the key fingerprints
# in the signing command.
#
# Exit status: 0 done or check passed; 1 refused or check failed; 2 usage error.
#
# Maintainer tooling: update-scripts.sh does not track tools/ and this file has
# no .sha256 sidecar. bash 3.2 safe.
# =============================================================================

set -euo pipefail

readonly TAG_RE='^scripts-v[0-9]+\.[0-9]+\.[0-9]+$'
readonly KEYS_HEREDOC="TN_RELEASE_KEYS"

# =============================================================================
# RELEASE SIGNATURES
# =============================================================================
# The same text in update-scripts.sh, install.sh and tools/release-scripts.sh,
# from the banner above to the end-of-block line below
# (tools/tests/release_scripts_test.sh checks that the copies match). Each of
# them runs where lib/ may not exist yet, so none of them sources lib/common.sh.
#
# MANIFEST.asc holds detached OpenPGP signatures over MANIFEST, one armored
# block per signer. A release is signed when gpgv, given a keyring made from
# lib/release-keys/*.asc and nothing else (the keys that also sign
# telcoin-network releases), reports good signatures by at least
# TN_SIG_THRESHOLD distinct primary keys: the keyring is the allowlist. The
# status lines are judged the way _tn_gpg_status_verdict in lib/common.sh
# judges a node release:
#   - GOODSIG followed by VALIDSIG counts once for the primary key fingerprint
#     that ends the VALIDSIG line;
#   - BADSIG (by any key), EXPKEYSIG, REVKEYSIG or EXPSIG refuses;
#   - ERRSIG with code 9, or NO_PUBKEY, is a signature by a key that is not in
#     lib/release-keys: it counts for nothing and refuses nothing (a warning
#     names its key id); any other ERRSIG refuses.
# TN_SIG_THRESHOLD is the number of distinct release keys that must sign; a
# 2-of-N signing policy raises it.
readonly TN_SIG_FILE="MANIFEST.asc"
readonly TN_SIG_THRESHOLD=1
readonly TN_KEYS_DIR="lib/release-keys"

# _tn_b64d -- decode the base64 on stdin. An older macOS base64 decodes only
# with -D.
_tn_b64d() {
    if [[ "$(printf 'eA==' | base64 -d 2>/dev/null)" == "x" ]]; then
        base64 -d
    else
        base64 -D
    fi
}

# _tn_armor_body N -- the base64 lines of the Nth public key block on stdin:
# the armor header lines up to the first blank line, the "=" checksum line and
# the END line left out. rc 1 when there is no Nth block, it has no blank line
# or no END line, its body is empty, or a body line is not base64.
_tn_armor_body() {
    LC_ALL=C awk -v want="$1" '
        { sub(/\r$/, "") }
        st == 0 && $0 == "-----BEGIN PGP PUBLIC KEY BLOCK-----" { if (++n == want) st = 1; next }
        st == 0 { next }
        st == 1 && /^[ \t]*$/ { st = 2; next }
        st == 1 && /^-----/ { exit 1 }
        st == 1 { next }
        $0 == "-----END PGP PUBLIC KEY BLOCK-----" { ok = 1; exit }
        /^=/ && length($0) == 5 { next }
        $0 ~ "^[A-Za-z0-9+/]+=*$" { print; body++; next }
        { exit 1 }
        END { if (!ok || !body) exit 1 }
    '
}

# tn_dearmor_keys DIR... -- write the binary OpenPGP keys of every DIR/*.asc
# to stdout, a keyring for gpgv --keyring. A key file holds one or more
# ASCII-armored public key blocks; only base64 is needed to read them, no gpg.
# rc 1, with a message on stderr, when no DIR holds a *.asc file, or a file
# holds no public key block, a malformed one, or one whose body does not
# decode.
tn_dearmor_keys() {
    local dir f n=0 blocks i
    for dir in "$@"; do
        for f in "$dir"/*.asc; do
            [[ -f "$f" && ! -L "$f" ]] || continue
            blocks="$(grep -c '^-----BEGIN PGP PUBLIC KEY BLOCK-----' "$f" 2>/dev/null)" || blocks=0
            if [[ "$blocks" -eq 0 ]]; then
                printf '%s is not an ASCII-armored OpenPGP public key\n' "$f" >&2
                return 1
            fi
            i=1
            while [[ $i -le $blocks ]]; do
                if ! _tn_armor_body "$i" < "$f" > /dev/null; then
                    printf '%s: public key block %s is malformed\n' "$f" "$i" >&2
                    return 1
                fi
                if ! _tn_armor_body "$i" < "$f" | _tn_b64d; then
                    printf '%s: public key block %s does not decode\n' "$f" "$i" >&2
                    return 1
                fi
                i=$((i + 1))
            done
            n=$((n + 1))
        done
    done
    if [[ $n -eq 0 ]]; then
        printf 'no release key file (*.asc) in %s\n' "$*" >&2
        return 1
    fi
}

# tn_sig_verdict -- judge the gpgv status lines on stdin. rc 0 and the line
# "GOOD <fpr>..." (the distinct primary fingerprints that made a good
# signature) when at least TN_SIG_THRESHOLD keys did and nothing refuses.
# Otherwise rc 1 and one line: "BADSIG <key id>", "EXPKEYSIG <key id>",
# "REVKEYSIG <key id>", "EXPSIG <key id>", "ERRSIG <key id> <code>", "NOSIG"
# when no release key made a good signature, or "THRESHOLD <n> <fpr>..." when
# fewer than TN_SIG_THRESHOLD did. The key ids of signatures by keys that are
# not release keys go to stderr, each once.
tn_sig_verdict() {
    local tag kw rest id x code fpr good=0 n=0 bad="" fprs="" unknown=""
    while read -r tag kw rest; do
        [[ "$tag" == "[GNUPG:]" ]] || continue
        case "$kw" in
            BADSIG|EXPKEYSIG|REVKEYSIG|EXPSIG)
                read -r id x <<< "$rest"
                [[ -n "$bad" ]] || bad="$kw ${id}"
                ;;
            NO_PUBKEY|ERRSIG)
                # ERRSIG <keyid> <pkalgo> <hashalgo> <class> <time> <code> [<fpr>]
                read -r id x x x x code x <<< "$rest"
                [[ "$kw" == NO_PUBKEY ]] && code=9
                if [[ "$code" != 9 || ! "$id" =~ ^[0-9A-F]{16,40}$ ]]; then
                    [[ -n "$bad" ]] || bad="ERRSIG ${id} ${code}"
                else
                    case " ${unknown} " in
                        *" ${id} "*) ;;
                        *) unknown="${unknown:+${unknown} }${id}" ;;
                    esac
                fi
                ;;
            GOODSIG) good=1 ;;
            VALIDSIG)
                fpr="${rest##* }"
                if [[ "$good" -eq 1 && "$fpr" =~ ^[0-9A-F]{40}$ ]]; then
                    case " ${fprs} " in
                        *" ${fpr} "*) ;;
                        *) fprs="${fprs:+${fprs} }${fpr}"; n=$((n + 1)) ;;
                    esac
                fi
                good=0
                ;;
        esac
    done
    for id in $unknown; do
        printf 'a signature by key %s, which is not a release key, was not checked\n' "$id" >&2
    done
    if [[ -n "$bad" ]]; then
        printf '%s\n' "$bad"
        return 1
    fi
    if [[ $n -eq 0 ]]; then
        printf 'NOSIG\n'
        return 1
    fi
    if [[ $n -lt $TN_SIG_THRESHOLD ]]; then
        printf 'THRESHOLD %s %s\n' "$n" "$fprs"
        return 1
    fi
    printf 'GOOD %s\n' "$fprs"
}

# tn_verify_manifest KEYRING SIG FILE -- run gpgv over FILE with the detached
# signatures in SIG and the keys in KEYRING (made by tn_dearmor_keys), in a
# throwaway GnuPG home, and judge its status lines with tn_sig_verdict: that
# line on stdout and that rc. gpgv's own messages go to stderr when the
# verdict refuses. rc 1 and "NOGPGV" when gpgv is not installed.
tn_verify_manifest() {
    local kr="$1" home out rc=0
    if ! command -v gpgv >/dev/null 2>&1; then
        printf 'NOGPGV\n'
        return 1
    fi
    [[ "$kr" == /* ]] || kr="$(pwd)/${kr}"
    home="$(mktemp -d "${TMPDIR:-/tmp}/tn-gpgv.XXXXXX")" || { printf 'NOTEMP\n'; return 1; }
    out="$(GNUPGHOME="$home" gpgv --status-fd 1 --keyring "$kr" "$2" "$3" 2> "${home}/log")" || true
    printf '%s\n' "$out" | tn_sig_verdict || rc=$?
    if [[ $rc -ne 0 && -s "${home}/log" ]]; then
        sed 's/^/    /' "${home}/log" >&2
    fi
    rm -rf "$home"
    return "$rc"
}

# tn_sig_reason VERDICT -- why a tn_verify_manifest verdict line refuses, as a
# phrase for a message.
tn_sig_reason() {
    local kw a b
    read -r kw a b <<< "$1"
    case "$kw" in
        BADSIG) printf 'the signature by key %s does not match MANIFEST: one of the two was changed\n' "$a" ;;
        EXPKEYSIG) printf 'it is signed by release key %s, which has expired\n' "$a" ;;
        REVKEYSIG) printf 'it is signed by release key %s, which has been revoked\n' "$a" ;;
        EXPSIG) printf 'the signature by key %s has expired\n' "$a" ;;
        ERRSIG) printf 'gpgv could not check the signature by key %s (error %s)\n' "$a" "$b" ;;
        NOSIG) printf 'no release key in %s made a good signature\n' "$TN_KEYS_DIR" ;;
        THRESHOLD) printf 'good signatures by %s release key(s), %s needed\n' "$a" "$TN_SIG_THRESHOLD" ;;
        NOGPGV) printf 'gpgv is not installed\n' ;;
        *) printf 'gpgv could not run\n' ;;
    esac
}
# --- end of RELEASE SIGNATURES (the same text in all three scripts) ---

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

die() {
    printf 'release-scripts.sh: %s\n' "$*" >&2
    exit 1
}

usage() {
    echo "Usage:"
    sed -n '5,6p' "${BASH_SOURCE[0]}" | sed 's/^#//'
}

_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1"
    else
        shasum -a 256 "$1"
    fi | awk '{print $1}'
}

# version_gt A B: rc 0 when A > B (X.Y.Z, compared field by field).
version_gt() {
    local IFS=.
    local -a a b
    local i
    read -r -a a <<< "$1"
    read -r -a b <<< "$2"
    for i in 0 1 2; do
        if ((10#${a[i]:-0} > 10#${b[i]:-0})); then return 0; fi
        if ((10#${a[i]:-0} < 10#${b[i]:-0})); then return 1; fi
    done
    return 1
}

# ymd_days YYYY-MM-DD -- print the day number (days since 1970-01-01) of a real
# calendar date from 1970 on; rc 1 for anything else. Pure bash: busybox and
# macOS date cannot parse a date, and the same text runs in every script that
# reads a MANIFEST date (tools/tests/release_scripts_test.sh checks the copies).
# The digits are listed one by one: in a UTF-8 locale [0-9] can match other
# digits, such as full-width ones, that bash arithmetic cannot read.
ymd_days() {
    local y m d n
    [[ "$1" =~ ^([0123456789]{4})-([0123456789]{2})-([0123456789]{2})$ ]] || return 1
    y=$((10#${BASH_REMATCH[1]}))
    m=$((10#${BASH_REMATCH[2]}))
    d=$((10#${BASH_REMATCH[3]}))
    n=31
    if [[ $m -eq 4 || $m -eq 6 || $m -eq 9 || $m -eq 11 ]]; then
        n=30
    elif [[ $m -eq 2 ]]; then
        n=28
        if (( y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) )); then n=29; fi
    fi
    if (( y < 1970 || m < 1 || m > 12 || d < 1 || d > n )); then return 1; fi
    # Days from the civil date (H. Hinnant's algorithm), the year starting in March.
    if (( m <= 2 )); then y=$((y - 1)); m=$((m + 9)); else m=$((m - 3)); fi
    printf '%s\n' "$(( (y / 400) * 146097 + (y % 400) * 365 + (y % 400) / 4 - (y % 400) / 100 \
        + (153 * m + 2) / 5 + d - 1 - 719468 ))"
}

# days_ymd N -- the YYYY-MM-DD of day number N (days since 1970-01-01).
days_ymd() {
    local z era doe yoe y doy mp d m
    z=$(( $1 + 719468 ))
    era=$(( z / 146097 ))
    doe=$(( z - era * 146097 ))
    yoe=$(( (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 ))
    y=$(( yoe + era * 400 ))
    doy=$(( doe - (365 * yoe + yoe / 4 - yoe / 100) ))
    mp=$(( (5 * doy + 2) / 153 ))
    d=$(( doy - (153 * mp + 2) / 5 + 1 ))
    if (( mp < 10 )); then m=$((mp + 3)); else m=$((mp - 9)); y=$((y + 1)); fi
    printf '%04d-%02d-%02d\n' "$y" "$m" "$d"
}

# days_text N -- "1 day" or "N days".
days_text() {
    if [[ "$1" == "1" ]]; then echo "1 day"; else echo "$1 days"; fi
}

# path_ok P: rc 0 for a relative path made of [A-Za-z0-9._/-] with no empty,
# "." or ".." component and no leading "-" (the rule update-scripts.sh applies).
path_ok() {
    local p="$1"
    [[ "$p" =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ ]] || return 1
    case "/$p/" in
        */./*|*/../*|*//*) return 1 ;;
    esac
    case "$p" in
        MANIFEST|MANIFEST.asc) return 1 ;;
    esac
    return 0
}

# array_paths: the local path of every row of the three updater arrays.
array_paths() {
    awk '
        /^declare -a (SCRIPTS|UI_BUNDLE|TESTNET_ADDONS_BUNDLE)=\(/ { inblock = 1; next }
        inblock && /^\)/                                          { inblock = 0; next }
        inblock && /"/                                            { print }
    ' update-scripts.sh \
        | sed -e 's/^[[:space:]]*"//' -e 's/".*$//' \
        | cut -d: -f1
}

# release_paths: the sorted, de-duplicated list MANIFEST covers.
release_paths() {
    { array_paths; printf '%s\n' install.sh open-ui.sh; } | LC_ALL=C sort -u
}

# manifest_lines: one "sha256  <hash>  <path>" line per release path, or rc 1
# with a message for a path that is missing, not a regular file, or malformed.
manifest_lines() {
    local p bad=0
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if ! path_ok "$p"; then
            printf 'release-scripts.sh: malformed path in the updater arrays: %s\n' "$p" >&2
            bad=1
        elif [[ -L "$p" || ! -f "$p" ]]; then
            printf 'release-scripts.sh: not a regular file: %s\n' "$p" >&2
            bad=1
        else
            printf 'sha256  %s  %s\n' "$(_sha256 "$p")" "$p"
        fi
    done < <(release_paths)
    return "$bad"
}

# check_sidecars: every array file has a sidecar whose first field is the
# file's hash.
check_sidecars() {
    local p want have bad=0
    while IFS= read -r p; do
        [[ -n "$p" && -f "$p" ]] || continue
        want="$(_sha256 "$p")"
        have=""
        [[ -f "${p}.sha256" ]] && have="$(awk 'NR == 1 {print $1}' "${p}.sha256")"
        if [[ "$have" != "$want" ]]; then
            printf 'release-scripts.sh: stale or missing sidecar: %s.sha256\n' "$p" >&2
            bad=1
        fi
    done < <(array_paths | LC_ALL=C sort -u)
    if [[ $bad -ne 0 ]]; then
        printf 'release-scripts.sh: run bash tools/gen-checksums.sh and commit the sidecars.\n' >&2
        return 1
    fi
}

# key_files: every lib/release-keys/*.asc of the tree, sorted by name.
key_files() {
    local f
    for f in "${TN_KEYS_DIR}"/*.asc; do
        if [[ -f "$f" ]]; then printf '%s\n' "$f"; fi
    done | LC_ALL=C sort
}

# keys_concat: the release key files, one after the other in name order: the
# text install.sh embeds. A file whose last byte is not a newline gets one, so
# its END line never runs into the BEGIN line of the next file.
keys_concat() {
    local f
    while IFS= read -r f; do
        cat "$f"
        if [[ -n "$(tail -c 1 "$f")" ]]; then
            echo ""
        fi
    done < <(key_files)
}

# check_keys: rc 0 when lib/release-keys holds at least one *.asc, every one
# is an armored public key that decodes, has LF line endings and ends with a
# newline (install.sh embeds the files one after the other as text), holds a
# primary key gpg can read (checked where gpg is installed: a block that
# decodes to something else makes gpgv drop the whole keyring), and is a row
# of an updater array (so it ships, with a sidecar). Messages on stderr.
check_keys() {
    local f err tracked bad=0
    if [[ -z "$(key_files)" ]]; then
        printf 'release-scripts.sh: %s holds no release key (*.asc): add the release signer public key first\n' "$TN_KEYS_DIR" >&2
        return 1
    fi
    if ! err="$(tn_dearmor_keys "$TN_KEYS_DIR" 2>&1 > /dev/null)"; then
        printf 'release-scripts.sh: %s\n' "$err" >&2
        bad=1
    fi
    tracked="$(array_paths)"
    while IFS= read -r f; do
        if grep -q $'\r' "$f"; then
            printf 'release-scripts.sh: %s has CR line endings: write it with LF line endings (as gpg --armor --export does)\n' "$f" >&2
            bad=1
        fi
        if [[ -n "$(tail -c 1 "$f")" ]]; then
            printf 'release-scripts.sh: %s does not end with a newline: export the key again with gpg --armor --export <fingerprint> > %s (install.sh embeds the key files one after the other)\n' "$f" "$f" >&2
            bad=1
        fi
        if command -v gpg >/dev/null 2>&1 && ! key_fpr "$f" > /dev/null; then
            printf 'release-scripts.sh: gpg reads no primary key from %s: export the key again with gpg --armor --export <fingerprint>\n' "$f" >&2
            bad=1
        fi
        if ! printf '%s\n' "$tracked" | grep -qxF -- "$f"; then
            printf 'release-scripts.sh: %s is not in an updater array: add the row "%s:%s:NONE" to SCRIPTS in update-scripts.sh so it ships, then run bash tools/gen-checksums.sh\n' "$f" "$f" "$f" >&2
            bad=1
        fi
    done < <(key_files)
    return "$bad"
}

# key_fpr FILE: the primary fingerprint of every key in FILE, one per line,
# from gpg in a throwaway GnuPG home; rc 1 when gpg is missing or reads none.
key_fpr() {
    local home f
    command -v gpg >/dev/null 2>&1 || return 1
    home="$(mktemp -d "${TMPDIR:-/tmp}/tn-gpg.XXXXXX")" || return 1
    f="$(GNUPGHOME="$home" gpg --batch --no-tty --quiet --with-colons --import-options show-only \
        --import < "$1" 2>/dev/null | awk -F: '$1 == "pub" { want = 1; next } $1 == "fpr" && want { print $10; want = 0 }')" || f=""
    rm -rf "$home"
    [[ -n "$f" ]] || return 1
    printf '%s\n' "$f"
}

# sign_commands: the gpg command that signs MANIFEST, once per release key.
sign_commands() {
    local f fprs fpr
    while IFS= read -r f; do
        if fprs="$(key_fpr "$f")"; then
            for fpr in $fprs; do
                printf '       gpg --armor --detach-sign --local-user %s! --output %s MANIFEST   # %s\n' \
                    "$fpr" "$TN_SIG_FILE" "$f"
            done
        else
            printf '       gpg --armor --detach-sign --local-user "<the fingerprint of %s>!" --output %s MANIFEST\n' \
                "$f" "$TN_SIG_FILE"
        fi
    done < <(key_files)
}

# header FILE KEY: the value of KEY=... in FILE; rc 1 when absent or repeated.
header() {
    local n
    n="$(awk -F= -v k="$2" '$1 == k {c++} END {print c + 0}' "$1")"
    [[ "$n" == "1" ]] || return 1
    awk -F= -v k="$2" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$1"
}

# header_count FILE KEY: how many KEY=... lines FILE has.
header_count() {
    awk -F= -v k="$2" '$1 == k {c++} END {print c + 0}' "$1"
}

updater_version() {
    sed -n 's/^readonly SCRIPT_VERSION="\([0-9][0-9.]*\)"$/\1/p' update-scripts.sh | head -1
}

# embedded_keys: the release keys embedded in install.sh.
embedded_keys() {
    awk -v m="$KEYS_HEREDOC" -v q="'" '
        $0 == m { inblock = 0 }
        inblock { print }
        index($0, "<<" q m q) { inblock = 1 }
    ' install.sh
}

installer_tag() {
    sed -n 's/^readonly TN_SCRIPTS_TAG="\([^"]*\)".*$/\1/p' install.sh | head -1
}

# verify_sig: verify MANIFEST.asc with the keys of lib/release-keys. Prints
# the tn_verify_manifest verdict line, or NOKEYS when the keys cannot be read,
# and returns 0 only for a good verdict.
verify_sig() {
    local kr v rc=0
    kr="$(mktemp "${TMPDIR:-/tmp}/tn-release-keys.XXXXXX")" || { echo "NOKEYS"; return 1; }
    if ! tn_dearmor_keys "$TN_KEYS_DIR" > "$kr" 2>/dev/null; then
        rm -f "$kr"
        echo "NOKEYS"
        return 1
    fi
    v="$(tn_verify_manifest "$kr" "$TN_SIG_FILE" MANIFEST)" || rc=$?
    rm -f "$kr"
    printf '%s\n' "$v"
    return "$rc"
}

# rewrite_installer TAG: set TN_SCRIPTS_TAG and replace the embedded release keys.
rewrite_installer() {
    local tag="$1" tmp keys
    keys="$(mktemp "${TMPDIR:-/tmp}/tn-release-keys.XXXXXX")" || die "could not create a temp file"
    keys_concat > "$keys"
    if grep -qx "$KEYS_HEREDOC" "$keys"; then
        rm -f "$keys"
        die "a release key file contains the heredoc marker line ${KEYS_HEREDOC}"
    fi
    [[ "$(grep -c '^readonly TN_SCRIPTS_TAG=' install.sh)" == "1" ]] || die "install.sh: expected one readonly TN_SCRIPTS_TAG= line"
    [[ "$(grep -c "^${KEYS_HEREDOC}\$" install.sh)" == "1" ]] || die "install.sh: expected one ${KEYS_HEREDOC} heredoc"
    tmp="$(mktemp "install.sh.XXXXXX")"
    awk -v tag="$tag" -v m="$KEYS_HEREDOC" -v sf="$keys" -v q="'" '
        /^readonly TN_SCRIPTS_TAG=/ {
            print "readonly TN_SCRIPTS_TAG=\"" tag "\"   # written by tools/release-scripts.sh"
            next
        }
        skipping && $0 == m { skipping = 0 }
        skipping { next }
        { print }
        index($0, "<<" q m q) {
            while ((getline line < sf) > 0) print line
            close(sf)
            skipping = 1
        }
    ' install.sh > "$tmp"
    rm -f "$keys"
    chmod 755 "$tmp"
    mv -f "$tmp" install.sh
}

prepare() {
    local tag="$1" serial="$2" min="$3" date="$4" days="$5"
    local prev_serial="" prev_min="" uver tmp day expires today

    [[ "$tag" =~ $TAG_RE ]] || die "release tag must look like scripts-v1.2.3, got: ${tag}"
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git work tree"
    [[ -z "$(git status --porcelain)" ]] || die "the tree has uncommitted changes; commit or stash them first"
    check_keys || exit 1

    uver="$(updater_version)"
    [[ "$uver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "cannot read SCRIPT_VERSION from update-scripts.sh"

    if [[ -f MANIFEST ]]; then
        prev_serial="$(header MANIFEST serial)" || die "the previous MANIFEST has no single serial= line"
        prev_min="$(header MANIFEST min_updater)" || die "the previous MANIFEST has no single min_updater= line"
    fi
    if [[ -z "$serial" ]]; then
        [[ -n "$prev_serial" ]] || die "first release: pass --serial N"
        serial=$((10#$prev_serial + 1))
    fi
    [[ "$serial" =~ ^[1-9][0-9]{0,8}$ ]] || die "serial must be a positive integer, got: ${serial}"
    if [[ -n "$prev_serial" ]] && (( 10#$serial <= 10#$prev_serial )); then
        die "serial ${serial} is not higher than the previous release serial ${prev_serial}"
    fi
    if [[ -z "$min" ]]; then
        min="${prev_min:-$uver}"
    fi
    [[ "$min" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "min_updater must look like 1.2.3, got: ${min}"
    if version_gt "$min" "$uver"; then
        die "min_updater ${min} is newer than the updater in this tree (${uver}): no host could install the release"
    fi
    [[ -n "$date" ]] || date="$(date -u +%Y-%m-%d)"
    day="$(ymd_days "$date")" || die "date must be a calendar date like 2026-10-15, got: ${date}"
    if [[ ! "$days" =~ ^[1-9][0-9]{0,3}$ ]] || (( 10#$days > 3650 )); then
        die "--expires takes a number of days from 1 to 3650, got: ${days}"
    fi
    expires="$(days_ymd "$((day + 10#$days))")"
    today="$(ymd_days "$(date -u +%Y-%m-%d)")" || die "cannot read today's date"

    check_sidecars || exit 1
    local p
    while IFS= read -r p; do
        git ls-files --error-unmatch -- "$p" >/dev/null 2>&1 || die "not committed to git: ${p}"
    done < <(release_paths)

    rewrite_installer "$tag"
    printf '%s %s\n' "$tag" "$date" > RELEASE

    tmp="$(mktemp "MANIFEST.XXXXXX")"
    {
        printf 'format=1\n'
        printf 'release=%s\n' "$tag"
        printf 'serial=%s\n' "$serial"
        printf 'min_updater=%s\n' "$min"
        printf 'date=%s\n' "$date"
        printf 'expires=%s\n' "$expires"
        manifest_lines
    } > "$tmp" || { rm -f "$tmp"; die "could not hash the release files"; }
    chmod 644 "$tmp"
    mv -f "$tmp" MANIFEST
    rm -f "$TN_SIG_FILE"

    cat <<EOF
Prepared ${tag}: serial ${serial}, min_updater ${min}, $(grep -c '^sha256 ' MANIFEST) files.
Release date ${date}; the release expires ${expires} (${days} days later).
Wrote MANIFEST, RELEASE and install.sh (tag and embedded release keys). Nothing is signed yet.

Release signer, with the release key (its YubiKey here, or through a forwarded gpg-agent):

  1. Review the change:            git diff -- install.sh RELEASE; cat MANIFEST
  2. Sign the manifest (touch the key when it blinks); ${TN_SIG_THRESHOLD} of these keys must sign:
$(sign_commands)
     A further signer appends to it: the same command with --output - MANIFEST >> ${TN_SIG_FILE}
  3. Check the signature against the keys the release ships:
       bash tools/release-scripts.sh --check --require-sig --tag ${tag}
  4. Commit and open the release pull request:
       git add MANIFEST ${TN_SIG_FILE} RELEASE install.sh
       git commit -S -m "release: ${tag}"
  5. After it merges, tag the merge commit on main and push the tag:
       git tag -s ${tag} <merge commit> -m ${tag}
       git push origin ${tag}

bash tools/cut-release.sh prep ${tag} (and, after the merge, tag ${tag}) runs these steps one by one.
EOF
    if (( day + 10#$days <= today )); then
        printf 'release-scripts.sh: WARN %s expires %s, on or before today (%s): every updater, installer and check-node will report it as expired. Prepare it again with a later --date or a longer --expires before signing.\n' \
            "$tag" "$expires" "$(days_ymd "$today")" >&2
    fi
}

check() {
    local tag="$1" require_sig="$2" require_fresh="$3"
    local fmt rel serial min rdate="" expires="" n uver itag rtag bad=0 tmp v

    if [[ ! -f MANIFEST ]]; then
        if [[ -n "$tag" || "$require_sig" == "1" || "$require_fresh" == "1" ]]; then
            die "no MANIFEST in the tree"
        fi
        echo "No MANIFEST in the tree: nothing to check."
        return 0
    fi
    if grep -q $'\r' MANIFEST; then die "MANIFEST has CR line endings"; fi

    fmt="$(header MANIFEST format)" || die "MANIFEST: no single format= line"
    rel="$(header MANIFEST release)" || die "MANIFEST: no single release= line"
    serial="$(header MANIFEST serial)" || die "MANIFEST: no single serial= line"
    min="$(header MANIFEST min_updater)" || die "MANIFEST: no single min_updater= line"
    [[ "$fmt" == "1" ]] || die "MANIFEST: format=${fmt}, expected 1"
    [[ "$rel" =~ $TAG_RE ]] || die "MANIFEST: release=${rel} is not a scripts-vX.Y.Z tag"
    [[ "$serial" =~ ^[1-9][0-9]{0,8}$ ]] || die "MANIFEST: serial=${serial} is not a positive integer"
    [[ "$min" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "MANIFEST: min_updater=${min} is not X.Y.Z"
    # date= and expires= are optional; a line that is there must hold a calendar
    # date (an empty value too is refused, as the updater and installer refuse it).
    n="$(header_count MANIFEST date)"
    [[ "$n" -le 1 ]] || die "MANIFEST: date= appears more than once"
    if [[ "$n" == "1" ]]; then
        rdate="$(header MANIFEST date)"
        ymd_days "$rdate" >/dev/null || die "MANIFEST: date=${rdate} is not a calendar date YYYY-MM-DD"
    fi
    n="$(header_count MANIFEST expires)"
    [[ "$n" -le 1 ]] || die "MANIFEST: expires= appears more than once"
    if [[ "$n" == "1" ]]; then
        expires="$(header MANIFEST expires)"
        ymd_days "$expires" >/dev/null || die "MANIFEST: expires=${expires} is not a calendar date YYYY-MM-DD"
    fi
    if [[ -n "$tag" && "$rel" != "$tag" ]]; then
        die "MANIFEST: release=${rel} but the tag is ${tag}"
    fi

    uver="$(updater_version)"
    if version_gt "$min" "$uver"; then
        echo "FAIL min_updater ${min} is newer than the updater in the tree (${uver})" >&2
        bad=1
    fi

    tmp="$(mktemp "${TMPDIR:-/tmp}/tn-manifest.XXXXXX")"
    if ! manifest_lines > "$tmp"; then
        bad=1
    fi
    if ! grep -vE '^[a-z_]+=' MANIFEST | diff -u - "$tmp" >&2; then
        echo "FAIL MANIFEST file lines differ from the tree (- MANIFEST, + tree)" >&2
        bad=1
    fi
    rm -f "$tmp"

    if [[ -f RELEASE ]]; then
        rtag="$(awk 'NR == 1 {print $1}' RELEASE)"
        if [[ "$rtag" != "$rel" ]]; then
            echo "FAIL RELEASE names ${rtag:-nothing}, MANIFEST is ${rel}" >&2
            bad=1
        fi
        if [[ -n "$rdate" && "$(awk 'NR == 1 {print $2}' RELEASE)" != "$rdate" ]]; then
            echo "FAIL RELEASE is dated $(awk 'NR == 1 {print $2}' RELEASE), MANIFEST date=${rdate}" >&2
            bad=1
        fi
    elif [[ -n "$tag" ]]; then
        echo "FAIL no RELEASE file" >&2
        bad=1
    fi
    itag="$(installer_tag)"
    if [[ "$itag" != "$rel" ]]; then
        echo "FAIL install.sh TN_SCRIPTS_TAG is ${itag:-empty}, MANIFEST is ${rel}" >&2
        bad=1
    fi
    if [[ "$(embedded_keys)" != "$(keys_concat)" ]]; then
        echo "FAIL the release keys embedded in install.sh differ from ${TN_KEYS_DIR}/*.asc" >&2
        bad=1
    fi
    check_keys || bad=1
    check_sidecars || bad=1
    check_expiry "$rel" "$rdate" "$expires" "$require_fresh" || bad=1

    if [[ -f "$TN_SIG_FILE" ]]; then
        if v="$(verify_sig)"; then
            echo "${TN_SIG_FILE} verifies: signed by ${v#GOOD } (${TN_SIG_THRESHOLD} release key(s) needed)."
        elif [[ "$v" == "NOKEYS" ]]; then
            echo "FAIL ${TN_SIG_FILE} cannot be checked: ${TN_KEYS_DIR} holds no readable release key" >&2
            bad=1
        else
            echo "FAIL ${TN_SIG_FILE} does not verify against ${TN_KEYS_DIR}: $(tn_sig_reason "$v")" >&2
            bad=1
        fi
    elif [[ -n "$tag" || "$require_sig" == "1" ]]; then
        echo "FAIL no ${TN_SIG_FILE}" >&2
        bad=1
    else
        echo "WARN no ${TN_SIG_FILE} yet (unsigned release candidate)" >&2
    fi

    if [[ $bad -ne 0 ]]; then
        echo "MANIFEST check failed for ${rel}." >&2
        return 1
    fi
    echo "MANIFEST check passed for ${rel} (serial ${serial}, min_updater ${min})."
}

# check_expiry REL DATE EXPIRES REQUIRE_FRESH: print the release date and the
# expiry; warn when the release has expired (today, UTC, is on or after
# EXPIRES), and fail (rc 1) then when REQUIRE_FRESH is 1. A release with no
# expires= line never expires. Fails as well when EXPIRES is not after DATE.
check_expiry() {
    local rel="$1" rdate="$2" expires="$3" fresh="$4" today left when
    [[ -z "$rdate" ]] || echo "Release date ${rdate}."
    if [[ -z "$expires" ]]; then
        echo "MANIFEST has no expires= line: ${rel} does not expire."
        return 0
    fi
    if [[ -n "$rdate" ]] && (( $(ymd_days "$expires") <= $(ymd_days "$rdate") )); then
        echo "FAIL MANIFEST expires=${expires} is not after date=${rdate}" >&2
        return 1
    fi
    today="$(ymd_days "$(date -u +%Y-%m-%d)")" || die "cannot read today's date"
    left=$(( $(ymd_days "$expires") - today ))
    if (( left > 0 )); then
        echo "Release ${rel} expires ${expires} (in $(days_text "$left"))."
        return 0
    fi
    when="today"
    (( left == 0 )) || when="$(days_text $(( -left ))) ago"
    if [[ "$fresh" == "1" ]]; then
        echo "FAIL release ${rel} expired on ${expires} (${when}): cut a newer release" >&2
        return 1
    fi
    echo "WARN release ${rel} expired on ${expires} (${when}): a newer signed release is overdue" >&2
}

main() {
    local mode=prepare tag="" serial="" min="" date="" days=90 require_sig=0 require_fresh=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check) mode=check ;;
            --tag) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; tag="$2"; shift ;;
            --require-sig) require_sig=1 ;;
            --require-fresh) require_fresh=1 ;;
            --serial) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; serial="$2"; shift ;;
            --min-updater) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; min="$2"; shift ;;
            --date) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; date="$2"; shift ;;
            --expires) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; days="$2"; shift ;;
            -h|--help) usage; exit 0 ;;
            -*) printf 'release-scripts.sh: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
            *) [[ -z "$tag" ]] || { usage >&2; exit 2; }; tag="$1" ;;
        esac
        shift
    done
    if [[ "$mode" == "check" ]]; then
        if [[ -n "$tag" && ! "$tag" =~ $TAG_RE ]]; then
            die "--tag must look like scripts-v1.2.3, got: ${tag}"
        fi
        check "$tag" "$require_sig" "$require_fresh"
    else
        [[ -n "$tag" ]] || { usage >&2; exit 2; }
        prepare "$tag" "$serial" "$min" "$date" "$days"
    fi
}

main "$@"
