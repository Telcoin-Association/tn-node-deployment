#!/usr/bin/env bash
# =============================================================================
# install.sh -- Telcoin Network Node Scripts Installer
#
# Downloads one signed release of the node scripts (the tag in TN_SCRIPTS_TAG
# below), checks MANIFEST.sig against the release signers embedded in this file
# and every file against its MANIFEST hash, and only then puts the verified
# files in ~/telcoin-node-scripts. On any failure nothing is installed and an
# existing install is left as it was.
#
# USAGE:
#   curl --proto '=https' --tlsv1.2 -fsSL https://install.telcoin.network | bash
#
#   To overwrite an existing install without the prompt:
#   curl --proto '=https' --tlsv1.2 -fsSL https://install.telcoin.network | bash -s -- --yes
#
# Needs curl or wget, tar, and ssh-keygen (OpenSSH 8.2 or later), which stock
# Ubuntu and macOS provide. All the work happens in main(), which the last line
# calls, so a download that stops part way runs nothing.
#
# tools/release-scripts.sh writes TN_SCRIPTS_TAG and the signer block in the
# release commit; a copy with no tag refuses to run.
# =============================================================================

set -euo pipefail

readonly TN_SCRIPTS_TAG=""   # written by tools/release-scripts.sh
readonly TN_SIGNER_PRINCIPAL="release@telcoin.org"
readonly TN_SIGNER_NAMESPACE="tn-node-scripts"
readonly TN_ARCHIVE_BASE="https://github.com/Telcoin-Association/tn-node-deployment/archive/refs/tags"
readonly TN_INSTALLER_URL="https://install.telcoin.network"
readonly INSTALL_DIR="${HOME}/telcoin-node-scripts"
# Mirrors TN_OPERATOR_GUIDE_URL in lib/common.sh. This installer runs before lib/
# is on disk (it is what downloads it), so the URL is spelled out here.
readonly TN_OPERATOR_GUIDE_URL="https://github.com/Telcoin-Association/tn-node-deployment/blob/main/OPERATOR.md"
readonly BOLD='\033[1m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly RESET='\033[0m'

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

# The keys that may sign a release: an exact copy of lib/allowed_signers at the
# release tag (tools/tests/install_test.sh checks that the two match).
tn_allowed_signers() {
    cat <<'TN_ALLOWED_SIGNERS'
# lib/allowed_signers -- the keys that may sign a tn-node-deployment script release
#
# update-scripts.sh and install.sh install a release only when its MANIFEST.sig
# verifies against this file:
#
#   ssh-keygen -Y verify -f lib/allowed_signers -I release@telcoin.org \
#       -n tn-node-scripts -s MANIFEST.sig < MANIFEST
#
# Format: the ALLOWED SIGNERS section of ssh-keygen(1), one key per line:
#
#   release@telcoin.org namespaces="tn-node-scripts" <key type> <base64 public key> <comment>
#
# The principal is always release@telcoin.org and the namespace always
# tn-node-scripts. A release signer uses a hardware-backed key, key type
# sk-ssh-ed25519@openssh.com; the comment names the signer. Lines starting with
# # are comments and blank lines are ignored.
#
# A host replaces this file only from a release whose MANIFEST verifies against
# the copy it already has, so adding or removing a signer takes a signature from
# a key the host already trusts. install.sh carries an identical copy (written
# by tools/release-scripts.sh); tools/tests/install_test.sh checks the two match.
#
# No release key is listed yet. Until a signer's public key line is added below,
# no manifest verifies and neither the updater nor the installer installs anything.
TN_ALLOWED_SIGNERS
}

print_ok()    { echo -e "  ${GREEN}[OK]${RESET}  $*"; }
print_warn()  { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
print_error() { echo -e "  ${RED}[ERROR]${RESET} $*"; }
print_info()  { echo -e "  ${BLUE}->${RESET}  $*"; }
print_step()  { echo -e "  ${BOLD}>>>${RESET} $*"; }

fail() {
    print_error "$*"
    echo ""
    exit 1
}

_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1"
    else
        shasum -a 256 "$1"
    fi | awk '{print $1}'
}

# path_ok P: a relative path made of [A-Za-z0-9._/-] with no empty, "." or ".."
# component and no leading "-" (the rule update-scripts.sh applies).
path_ok() {
    local p="$1"
    [[ "$p" =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ ]] || return 1
    case "/$p/" in
        */./*|*/../*|*//*) return 1 ;;
    esac
    case "$p" in
        MANIFEST|MANIFEST.sig) return 1 ;;
    esac
    return 0
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

# warn_expired TAG EXPIRES: an expired release (today, UTC, on or after EXPIRES)
# is still installed, with a warning that a newer signed release is overdue.
warn_expired() {
    local today
    [[ -n "$2" ]] || return 0
    today="$(ymd_days "$(date -u +%Y-%m-%d)")" || return 0
    (( today >= $(ymd_days "$2") )) || return 0
    print_warn "Script release $1 expired on $2; a newer signed release is overdue. Installing it anyway."
    print_info "The release still verifies. If no newer one appears soon, tell support@telcoin.org."
}

# fetch URL DEST: download over HTTPS only.
fetch() {
    if [[ "$DOWNLOADER" == "curl" ]]; then
        curl --proto '=https' --tlsv1.2 -fsSL --max-time 300 -o "$2" "$1"
    else
        wget --https-only -q -O "$2" "$1"
    fi
}

check_dependencies() {
    print_step "Checking dependencies..."
    DOWNLOADER=""
    if command -v curl >/dev/null 2>&1; then
        DOWNLOADER="curl"
    elif command -v wget >/dev/null 2>&1; then
        DOWNLOADER="wget"
    else
        print_error "Need either curl or wget. Please install one first:"
        echo ""
        echo "    Ubuntu/Debian:  sudo apt-get install -y curl"
        echo "    RHEL/CentOS:    sudo yum install -y curl"
        echo ""
        exit 1
    fi
    print_ok "downloader available (${DOWNLOADER})"
    command -v tar >/dev/null 2>&1 || fail "Need tar to unpack the release. Ubuntu/Debian: sudo apt-get install -y tar"
    # The release signature is checked with ssh-keygen -Y verify. Without it
    # nothing can be verified, so the installer stops rather than skip the check.
    command -v ssh-keygen >/dev/null 2>&1 \
        || fail "Need ssh-keygen (OpenSSH) to verify the release signature. Ubuntu/Debian: sudo apt-get install -y openssh-client"
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
        fail "Need sha256sum or shasum to check the release files."
    fi
    print_ok "tar, ssh-keygen and a SHA-256 tool are available"
}

# confirm_overwrite: when an install exists, ask (or take --yes) before going on.
# The prompt reads the terminal, because under curl | bash standard input is the
# script itself.
confirm_overwrite() {
    [[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" ]] || return 0
    print_warn "Scripts already exist at: ${INSTALL_DIR}"
    echo ""
    print_info "To update existing scripts run:"
    print_info "  bash ${INSTALL_DIR}/update-scripts.sh"
    echo ""
    if [[ "$ASSUME_YES" == "true" ]]; then
        print_info "Overwrite confirmed non-interactively (--yes / TN_ASSUME_YES)."
        return 0
    fi
    local choice=""
    if ! read -r -p "  Re-install and overwrite? [y/N]: " choice < /dev/tty 2>/dev/null; then
        choice=""
        echo ""
        print_info "No terminal to ask on. To overwrite without the prompt, run the installer with: bash -s -- --yes"
    fi
    if [[ ! "${choice:-N}" =~ ^[Yy]$ ]]; then
        print_info "Installation cancelled."
        echo ""
        exit 0
    fi
}

# verify_release SRC TREE: check SRC/MANIFEST.sig against the embedded signers
# and that the manifest names this installer's tag, then copy every listed file
# whose hash matches into TREE (with MANIFEST and MANIFEST.sig). Returns only
# when every file verified; any failure exits. date= and expires= are optional
# (the 2.0.0 release has neither); when present each is a calendar date.
verify_release() {
    local src="$1" tree="$2" signers="${STAGE}/allowed_signers"
    local line key val fmt="" rel="" serial="" rdate="" expires="" n=0 hash path have seen

    tn_allowed_signers > "$signers"
    grep -qvE '^[[:space:]]*(#|$)' "$signers" \
        || fail "This installer lists no release signing key, so it cannot verify anything. Use the published installer: ${TN_INSTALLER_URL}"
    [[ -f "${src}/MANIFEST" && ! -L "${src}/MANIFEST" ]] || fail "The release ${TN_SCRIPTS_TAG} has no MANIFEST."
    [[ -f "${src}/MANIFEST.sig" && ! -L "${src}/MANIFEST.sig" ]] || fail "The release ${TN_SCRIPTS_TAG} has no MANIFEST.sig."
    if ! ssh-keygen -Y verify -f "$signers" -I "$TN_SIGNER_PRINCIPAL" -n "$TN_SIGNER_NAMESPACE" \
        -s "${src}/MANIFEST.sig" < "${src}/MANIFEST" >/dev/null 2>&1; then
        fail "The release signature does not verify against the Telcoin release keys. Nothing was installed."
    fi
    print_ok "Release signature verified (${TN_SIGNER_PRINCIPAL})"

    if grep -q $'\r' "${src}/MANIFEST"; then fail "MANIFEST is malformed (CR line endings)."; fi
    seen="${STAGE}/seen"
    : > "$seen"
    mkdir -p "$tree"
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            format=*|release=*|serial=*|min_updater=*|date=*|expires=*)
                key="${line%%=*}"
                val="${line#*=}"
                if grep -qx "h:${key}" "$seen"; then fail "MANIFEST repeats ${key}=."; fi
                printf 'h:%s\n' "$key" >> "$seen"
                case "$key" in
                    format) fmt="$val" ;;
                    release) rel="$val" ;;
                    serial) serial="$val" ;;
                    date) rdate="$val" ;;
                    expires) expires="$val" ;;
                esac
                ;;
            sha256\ \ *)
                if [[ ! "$line" =~ ^sha256\ \ ([0-9a-f]{64})\ \ (.+)$ ]]; then
                    fail "MANIFEST line is malformed: ${line}"
                fi
                hash="${BASH_REMATCH[1]}"
                path="${BASH_REMATCH[2]}"
                path_ok "$path" || fail "MANIFEST names a bad path: ${path}"
                if grep -qxF "p:${path}" "$seen"; then fail "MANIFEST lists ${path} twice."; fi
                printf 'p:%s\n' "$path" >> "$seen"
                if [[ -L "${src}/${path}" || ! -f "${src}/${path}" ]]; then
                    fail "The release archive lacks ${path} (or it is not a regular file)."
                fi
                have="$(_sha256 "${src}/${path}")"
                [[ "$have" == "$hash" ]] || fail "${path} does not match its MANIFEST hash. Nothing was installed."
                mkdir -p "${tree}/$(dirname "$path")"
                cp "${src}/${path}" "${tree}/${path}"
                n=$((n + 1))
                ;;
            # A header key a later format adds (covered by the signature); a key
            # with a blank in it, such as "expires =", is malformed.
            [a-z]*=*) [[ "${line%%=*}" != *[[:space:]]* ]] || fail "MANIFEST line is malformed: ${line}" ;;
            *) fail "MANIFEST line is malformed: ${line}" ;;
        esac
    done < "${src}/MANIFEST"
    [[ "$fmt" == "1" ]] || fail "MANIFEST format ${fmt:-missing} is not supported by this installer."
    [[ "$rel" == "$TN_SCRIPTS_TAG" ]] || fail "MANIFEST is for ${rel:-no release}, expected ${TN_SCRIPTS_TAG}."
    [[ "$serial" =~ ^[1-9][0-9]{0,8}$ ]] || fail "MANIFEST serial is malformed."
    if grep -qx 'h:date' "$seen" && ! ymd_days "$rdate" >/dev/null; then
        fail "MANIFEST date=${rdate} is not a calendar date YYYY-MM-DD."
    fi
    if grep -qx 'h:expires' "$seen" && ! ymd_days "$expires" >/dev/null; then
        fail "MANIFEST expires=${expires} is not a calendar date YYYY-MM-DD."
    fi
    [[ $n -gt 0 ]] || fail "MANIFEST lists no files."
    grep -qx 'p:update-scripts.sh' "$seen" || fail "MANIFEST does not list update-scripts.sh."
    grep -qx 'p:lib/allowed_signers' "$seen" || fail "MANIFEST does not list lib/allowed_signers."
    cp "${src}/MANIFEST" "${tree}/MANIFEST"
    cp "${src}/MANIFEST.sig" "${tree}/MANIFEST.sig"
    find "$tree" -type f -name '*.sh' -exec chmod +x {} +
    print_ok "All ${n} files match the signed MANIFEST (serial ${serial})"
    warn_expired "$rel" "$expires"
}

parse_args() {
    ASSUME_YES=false
    case "${TN_ASSUME_YES:-}" in 1|true|yes|y|TRUE|YES|Y) ASSUME_YES=true ;; esac
    local arg
    for arg in "$@"; do
        case "$arg" in
            --yes|-y|--force) ASSUME_YES=true ;;
        esac
    done
}

# cleanup -- the EXIT trap: put a moved-aside install back when the new tree
# did not get into place, then remove the staging directory.
cleanup() {
    if [[ -n "${ASIDE:-}" ]]; then
        if [[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" ]]; then
            print_warn "The previous install is kept in ${ASIDE}/telcoin-node-scripts."
        elif mv "${ASIDE}/telcoin-node-scripts" "$INSTALL_DIR" 2>/dev/null; then
            rmdir "$ASIDE" 2>/dev/null || true
            print_info "The existing install at ${INSTALL_DIR} was put back as it was."
        else
            print_error "The existing install could not be put back; it is in ${ASIDE}/telcoin-node-scripts."
        fi
    fi
    rm -rf "${STAGE:-}"
}

main() {
    parse_args "$@"

    echo ""
    echo -e "${BLUE}${BOLD}"
    echo "================================================================"
    echo "  Telcoin Network -- Node Scripts Installer"
    echo "================================================================"
    echo -e "${RESET}"

    if [[ -z "$TN_SCRIPTS_TAG" ]]; then
        fail "This copy of install.sh names no release. Use the published installer: curl --proto '=https' --tlsv1.2 -fsSL ${TN_INSTALLER_URL} | bash"
    fi

    check_dependencies
    confirm_overwrite

    # Everything is downloaded and checked in a staging directory beside the
    # install, then moved into place in one step.
    ASIDE=""
    STAGE="$(mktemp -d "${HOME}/.telcoin-node-scripts.XXXXXX")" || fail "Could not create a staging directory in ${HOME}."
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    print_step "Downloading release ${TN_SCRIPTS_TAG}..."
    local archive="${TN_ARCHIVE_BASE}/${TN_SCRIPTS_TAG}.tar.gz"
    print_info "Archive: ${archive}"
    fetch "$archive" "${STAGE}/release.tar.gz" \
        || fail "Could not download ${archive}. Check your internet connection."
    mkdir -p "${STAGE}/src"
    tar -xzf "${STAGE}/release.tar.gz" -C "${STAGE}/src" --strip-components=1 \
        || fail "Could not unpack the release archive."

    print_step "Verifying the release..."
    verify_release "${STAGE}/src" "${STAGE}/tree"

    print_step "Installing to ${INSTALL_DIR}..."
    # An existing install is moved aside first, into a new directory of its
    # own (so the move can never land inside another directory), and removed
    # only once the verified tree is in place. Until then the EXIT trap puts
    # it back.
    if [[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" ]]; then
        ASIDE="$(mktemp -d "${INSTALL_DIR%/*}/.telcoin-node-scripts.old.$(date +%Y%m%d%H%M%S).XXXXXX")" \
            || fail "Could not create a directory in ${HOME} to move the existing install aside; nothing was changed."
        if ! mv "$INSTALL_DIR" "${ASIDE}/telcoin-node-scripts"; then
            rmdir "$ASIDE" 2>/dev/null || true
            ASIDE=""
            fail "Could not move the existing install at ${INSTALL_DIR} aside; nothing was changed."
        fi
    fi
    mv "${STAGE}/tree" "$INSTALL_DIR" || fail "Could not move the verified files to ${INSTALL_DIR}."
    if [[ -n "$ASIDE" ]]; then
        local old="$ASIDE"
        ASIDE=""
        rm -rf "$old"
    fi
    print_ok "Scripts installed (${TN_SCRIPTS_TAG})"

    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "================================================================"
    echo "  Installation complete!"
    echo "================================================================"
    echo -e "${RESET}"
    print_info "Scripts installed to: ${INSTALL_DIR}"
    echo ""
    print_info "Next steps:"
    echo ""
    echo "    # Set up your node (one identity; validating is optional and decided on-chain)"
    echo "    sudo bash ~/telcoin-node-scripts/setup-node.sh"
    echo ""
    echo "    # Check for script updates in future"
    echo "    bash ~/telcoin-node-scripts/update-scripts.sh"
    echo ""
    echo "    # Optional - install the web UI (health/logs/config/traces over an SSH tunnel)"
    echo "    sudo bash ~/telcoin-node-scripts/ui/install-ui.sh"
    echo ""
    print_info "Operator runbook:   ${TN_OPERATOR_GUIDE_URL}"
    print_info "Full documentation: https://github.com/Telcoin-Association/tn-node-deployment"
    echo ""
}

main "$@"
