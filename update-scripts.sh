#!/usr/bin/env bash
# =============================================================================
# update-scripts.sh -- Telcoin Network Script Updater
#
# Brings the node scripts to the latest signed release: reads the release tag
# from RELEASE on main, verifies that tag's MANIFEST.asc (OpenPGP signatures
# over MANIFEST) with gpgv against the release keys in lib/release-keys, and
# installs every file whose hash differs from the MANIFEST, all together or
# not at all.
#
# USAGE:
#   bash ~/telcoin-node-scripts/update-scripts.sh           # update
#   bash ~/telcoin-node-scripts/update-scripts.sh --check   # report only
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A release that ships a new update-scripts.sh has that copy run from the
# staging dir of the run that verified it (see self_update). The copy then
# works on the tree the staging dir sits in and takes the staging dir over.
ADOPTED_STAGE=""
if [[ "${TN_UPDATER_RELAUNCHED:-}" == "1" && "${SCRIPT_DIR##*/}" == .tn-update.* ]]; then
    ADOPTED_STAGE="$SCRIPT_DIR"
    SCRIPT_DIR="${SCRIPT_DIR%/*}"
fi

# Pull in the node-identity resolvers so the restart hint below can name the
# actually-installed unit (the bare telcoin unit, or a legacy role-suffixed one).
# This script does not source lib/common.sh, so source fallback.sh directly.
# A lone copy of the updater has no lib/ on its first run, so test the file before
# sourcing it: under `set -e`, bash 3.2 exits on a failed `source` even with
# `|| true`. Without the file the restart hint falls back to "telcoin".
if [ -r "${SCRIPT_DIR}/lib/fallback.sh" ]; then
    # shellcheck source=lib/fallback.sh
    source "${SCRIPT_DIR}/lib/fallback.sh" 2>/dev/null || true
fi

readonly SCRIPT_VERSION="2.1.0"
readonly TN_REPO_RAW="https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment"
# main serves only the RELEASE pointer and the connectivity probe; every release
# file is fetched from the tag RELEASE names.
readonly GITHUB_RAW="${TN_REPO_RAW}/main"
readonly TN_RELEASE_POINTER_URL="${GITHUB_RAW}/RELEASE"
readonly TN_SCRIPTS_TAG_RE='^scripts-v[0-9]+\.[0-9]+\.[0-9]+$'
readonly TN_INSTALLER_URL="https://install.telcoin.network"

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

# Colours
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly RESET='\033[0m'

print_ok()   { echo -e "  ${GREEN}[OK]${RESET}  $*"; }
print_warn() { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
print_error(){ echo -e "  ${RED}[ERROR]${RESET} $*"; }
print_info() { echo -e "  ${BLUE}->${RESET}  $*"; }
print_sep()  { echo "----------------------------------------------------------------"; }

# =============================================================================
# SCRIPTS TO CHECK
# =============================================================================

# The three arrays below are the tracked set: tools/release-scripts.sh builds
# MANIFEST from them and tools/gen-checksums.sh writes their .sha256 sidecars.
# The updater itself installs whatever the signed MANIFEST lists and reads the
# version column of SCRIPTS only to show versions.

# Format: "local_path:remote_path:version_var"
declare -a SCRIPTS=(
    "setup-node.sh:setup-node.sh:SCRIPT_VERSION"
    "setup-observer.sh:setup-observer.sh:SCRIPT_VERSION"
    "setup-validator.sh:setup-validator.sh:SCRIPT_VERSION"
    "install-caddy.sh:install-caddy.sh:SCRIPT_VERSION"
    "check-node.sh:check-node.sh:SCRIPT_VERSION"
    "prepare-stake.sh:prepare-stake.sh:SCRIPT_VERSION"
    "edit-config.sh:edit-config.sh:SCRIPT_VERSION"
    "firewall-setup.sh:firewall-setup.sh:SCRIPT_VERSION"
    "remove-node.sh:remove-node.sh:SCRIPT_VERSION"
    "update-node.sh:update-node.sh:SCRIPT_VERSION"
    "migrate-node-naming.sh:migrate-node-naming.sh:SCRIPT_VERSION"
    "update-scripts.sh:update-scripts.sh:SCRIPT_VERSION"
    "lib/common.sh:lib/common.sh:COMMON_VERSION"
    "lib/fallback.sh:lib/fallback.sh:FALLBACK_VERSION"
    "lib/testnet-addons.env:lib/testnet-addons.env:TESTNET_ADDONS_VERSION"
    "lib/observability.sh:lib/observability.sh:OBSERVABILITY_VERSION"
    "setup-vpn.sh:setup-vpn.sh:SCRIPT_VERSION"
    "setup-observability.sh:setup-observability.sh:SCRIPT_VERSION"
    "ui/server.py:ui/server.py:UI_VERSION"
    "lib/release-keys/README:lib/release-keys/README:NONE"
    "lib/release-keys/grantkee.asc:lib/release-keys/grantkee.asc:NONE"
)

# The web UI is shipped as a bundle gated on ui/server.py's UI_VERSION. When that
# row needs updating we fetch these companion files alongside server.py and then
# redeploy via install-ui.sh --update. (server.py itself is fetched by the main
# loop because it is the SCRIPTS entry above.)
declare -a UI_BUNDLE=(
    "ui/static/index.html:ui/static/index.html"
    "ui/static/telcoin-logo.png:ui/static/telcoin-logo.png"
    "ui/telcoin-ui-helper.sh:ui/telcoin-ui-helper.sh"
    "ui/telcoin-ui.service:ui/telcoin-ui.service"
    "ui/requirements.txt:ui/requirements.txt"
    "ui/install-ui.sh:ui/install-ui.sh"
)

# Testnet add-on companion files WITHOUT their own version var (the Alloy config +
# the vendored wgvpn bundle). Fetched alongside whenever a versioned add-on file
# (setup-vpn.sh / setup-observability.sh / lib/observability.sh / lib/testnet-addons.env)
# updates -- mirrors how UI_BUNDLE rides along with ui/server.py.
declare -a TESTNET_ADDONS_BUNDLE=(
    "observability/config.alloy:observability/config.alloy"
    "lib/wgvpn/wg-node-bootstrap.sh:lib/wgvpn/wg-node-bootstrap.sh"
    "lib/wgvpn/hub-coordinates.env:lib/wgvpn/hub-coordinates.env"
    "lib/wgvpn/peers/ssh/grant.pub:lib/wgvpn/peers/ssh/grant.pub"
    "lib/wgvpn/peers/ssh/grant2.pub:lib/wgvpn/peers/ssh/grant2.pub"
    "lib/wgvpn/peers/ssh/bluelights.pub:lib/wgvpn/peers/ssh/bluelights.pub"
    "lib/wgvpn/peers/ssh/oobi.pub:lib/wgvpn/peers/ssh/oobi.pub"
    "lib/wgvpn/peers/ssh/sstanf.pub:lib/wgvpn/peers/ssh/sstanf.pub"
    "lib/wgvpn/peers/ssh/umair.pub:lib/wgvpn/peers/ssh/umair.pub"
    "lib/wgvpn/peers/ssh/xerxes.pub:lib/wgvpn/peers/ssh/xerxes.pub"
    "lib/wgvpn/peers/ssh/README:lib/wgvpn/peers/ssh/README"
    "lib/wgvpn/peers/ssh/KEYS:lib/wgvpn/peers/ssh/KEYS:NONE"
)
# NOTE: this list MUST name every maintainer key in lib/wgvpn/peers/ssh/*.pub. The
# updater fetches files by explicit path (it cannot glob the remote), so a key omitted
# here is silently NOT delivered to operators who update via update-scripts.sh — and
# the next `setup-vpn.sh --sync-keys` would then bake an INCOMPLETE maintainer set.
# When the admin add-peer.sh mirrors a new maintainer key into this repo, add a row here.

# The installed release record: the signed MANIFEST and MANIFEST.asc of the
# release this tree was last brought to. The install pass writes them last, so
# they name a release only once every file of it is in place. KEYS_DIR holds
# the release keys that verify the next release.
readonly INSTALLED_MANIFEST="${SCRIPT_DIR}/MANIFEST"
readonly INSTALLED_SIG="${SCRIPT_DIR}/${TN_SIG_FILE}"
readonly KEYS_DIR="${SCRIPT_DIR}/${TN_KEYS_DIR}"

# This run's staging directory, inside SCRIPT_DIR so that installing a verified
# file is a rename on the same filesystem. The EXIT trap removes it however the
# run ends, so a run that refuses or fails leaves the tree as it found it. A
# release copy run by self_update uses the staging dir it runs from.
STAGE="$ADOPTED_STAGE"
# 1 while the install pass is moving files into place (for the exit message).
INSTALLING=0

# The verified manifest, filled by parse_manifest. Declared at top level so they
# are globals on macOS /bin/bash 3.2, which has no `declare -g`.
RELEASE_TAG=""
BOOT_KEYS=""
M_RELEASE=""
M_SERIAL=""
M_MIN_UPDATER=""
M_DATE=""
M_EXPIRES=""
M_PATHS=()
M_SHAS=()
# Work lists, filled by plan_changes.
UPD_PATHS=()
DEL_PATHS=()

cleanup_stage() {
    if [[ -n "$STAGE" && -d "$STAGE" ]]; then
        rm -rf "${STAGE:?}"
    fi
    # Removal comes first: after a dropped session stdout may be gone, and a
    # failed message must not stop the cleanup.
    if [[ $INSTALLING -eq 1 ]]; then
        print_warn "Stopped while installing: some files are new and some are not. Run the updater again to finish." 2>/dev/null || true
    fi
}

# =============================================================================
# HELPERS
# =============================================================================

# Portable SHA-256 of a file's contents (hash only). Linux ships `sha256sum`;
# macOS ships `shasum` instead. Observers can run on macOS.
_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1"
    else
        shasum -a 256 "$1"
    fi | awk '{print $1}'
}

# _file_version PATH VAR -- the X.Y.Z that VAR is set to in PATH (bash
# `readonly VAR="1.2.3"` or Python `VAR = "1.2.3"`), or "-".
_file_version() {
    local v=""
    if [[ -n "$2" && -f "$1" ]]; then
        v="$(grep -E "(readonly[[:space:]]+)?${2}[[:space:]]*=" "$1" 2>/dev/null \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    fi
    printf '%s\n' "${v:--}"
}

# version_var_for PATH -- the version variable the SCRIPTS row for PATH names.
version_var_for() {
    local entry lp var
    for entry in "${SCRIPTS[@]}"; do
        IFS=: read -r lp _ var <<< "$entry"
        if [[ "$lp" == "$1" ]]; then
            printf '%s\n' "$var"
            return 0
        fi
    done
    printf '\n'
}

version_gt() {
    # Returns 0 if $1 > $2
    [[ "$1" == "$2" ]] && return 1
    local IFS=.
    local i ver1=($1) ver2=($2)
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z "${ver2[i]:-}" ]]; then ver2[i]=0; fi
        if ((10#${ver1[i]} > 10#${ver2[i]})); then return 0; fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then return 1; fi
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

# days_text N -- "1 day" or "N days".
days_text() {
    if [[ "$1" == "1" ]]; then echo "1 day"; else echo "$1 days"; fi
}

# days_left EXPIRES -- the days from today (UTC) until the date EXPIRES: 0 or
# less once that day has come.
days_left() {
    local today
    today="$(ymd_days "$(date -u +%Y-%m-%d)")" || return 1
    echo $(( $(ymd_days "$1") - today ))
}

# release_expired EXPIRES -- rc 0 when a release that expires on EXPIRES has
# expired (today, UTC, is that day or later), printing how long ago: "today",
# "1 day ago" or "N days ago". rc 1 and nothing printed for an empty EXPIRES or
# a release that has not expired.
release_expired() {
    local left
    [[ -n "$1" ]] || return 1
    left="$(days_left "$1")" || return 1
    (( left <= 0 )) || return 1
    if (( left == 0 )); then echo "today"; else echo "$(days_text $(( -left ))) ago"; fi
}

# path_ok P -- rc 0 for a relative path made of [A-Za-z0-9._/-] with no empty,
# "." or ".." component and no leading "-". A manifest naming anything else is
# refused whole. MANIFEST and MANIFEST.asc are the record, never a listed file.
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

# have_keys DIR -- rc 0 when DIR holds at least one release key file (*.asc).
have_keys() {
    local f
    for f in "$1"/*.asc; do
        [[ -f "$f" && ! -L "$f" ]] && return 0
    done
    return 1
}

# tag_url TAG PATH -- the raw URL of PATH at release tag TAG.
tag_url() {
    printf '%s/refs/tags/%s/%s\n' "$TN_REPO_RAW" "$1" "$2"
}

# fetch URL DEST -- curl's rc: 0 ok, 22 an HTTP error (not published), other
# values a network failure.
fetch() {
    curl --proto '=https' --tlsv1.2 -fsSL --max-time 30 -o "$2" "$1" 2>/dev/null
}

# fetch_published_sha URL -- print the SHA-256 that URL.sha256 publishes for URL.
# rc 0: printed a 64-hex-digit hash. rc 1: no sidecar is published (HTTP error).
# rc 2: the sidecar could not be fetched (network). rc 3: a sidecar is published
# but its first field is not a 64-hex-digit hash. The signed manifest is
# authoritative; a sidecar that exists must agree with it (older updaters still
# read the sidecars).
fetch_published_sha() {
    local body sha rc=0
    body="$(curl --proto '=https' --tlsv1.2 -fsSL --max-time 10 "${1}.sha256" 2>/dev/null)" || rc=$?
    if [[ $rc -eq 22 ]]; then
        return 1
    elif [[ $rc -ne 0 ]]; then
        return 2
    fi
    sha="$(printf '%s\n' "$body" | awk 'NR == 1 {print $1}')"
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || return 3
    printf '%s\n' "$sha"
}

reinstall_hint() {
    print_info "Re-install the scripts with the verified installer, then run the updater again:"
    print_info "  curl --proto '=https' --tlsv1.2 -fsSL ${TN_INSTALLER_URL} | bash"
}

# =============================================================================
# RELEASE AND MANIFEST
# =============================================================================

# read_release_tag -- set RELEASE_TAG from the RELEASE pointer on main. The
# pointer is not signed: it can only name a tag, and that tag's manifest must
# verify and carry a serial no lower than the installed one.
read_release_tag() {
    local f="${STAGE}/RELEASE" rc=0
    fetch "$TN_RELEASE_POINTER_URL" "$f" || rc=$?
    if [[ $rc -eq 22 ]]; then
        print_error "No signed script release is published yet (no RELEASE file at ${GITHUB_RAW})."
        return 1
    elif [[ $rc -ne 0 ]]; then
        print_error "Could not download ${TN_RELEASE_POINTER_URL} (network error). Try again in a few minutes."
        return 1
    fi
    RELEASE_TAG="$(awk 'NR == 1 {print $1}' "$f")"
    if [[ ! "$RELEASE_TAG" =~ $TN_SCRIPTS_TAG_RE ]]; then
        print_error "RELEASE does not name a scripts-vX.Y.Z tag; nothing was changed."
        return 1
    fi
}

# fetch_release_file TAG NAME -- download NAME at TAG into the staging dir.
fetch_release_file() {
    local rc=0
    fetch "$(tag_url "$1" "$2")" "${STAGE}/$2" || rc=$?
    if [[ $rc -eq 22 ]]; then
        print_error "Release $1 has no $2; nothing was changed."
        return 1
    elif [[ $rc -ne 0 ]]; then
        print_error "Could not download $2 of release $1 (network error). Try again in a few minutes."
        return 1
    fi
}

# bootstrap_keys TAG -- the first signed release reaching a tree that has
# neither a release key (lib/release-keys/*.asc) nor a MANIFEST record takes
# the release keys once from the release itself: every key file the fetched,
# not yet verified, MANIFEST lists, each checked against its published .sha256,
# the channel that delivered this updater. run_update then verifies the
# manifest with those keys and requires their hashes to be the ones it lists.
# From then on a new key set arrives only in a manifest that verifies against
# the installed keys.
bootstrap_keys() {
    local tag="$1" a h p url want rc n=0
    BOOT_KEYS="${STAGE}/bootstrap-keys"
    mkdir -p "$BOOT_KEYS" || return 1
    print_warn "First signed release on this host: fetching the release keys through their published checksums (one time only)."
    while read -r a h p; do
        [[ "$a" == sha256 && "$p" == "${TN_KEYS_DIR}/"*.asc ]] || continue
        if ! path_ok "$p" || [[ "${p#"${TN_KEYS_DIR}"/}" == */* ]]; then
            print_error "The release manifest names a bad key path ${p}; nothing was changed."
            return 1
        fi
        url="$(tag_url "$tag" "$p")"
        if ! fetch "$url" "${BOOT_KEYS}/${p##*/}"; then
            print_error "Could not download ${p} of release ${tag}; nothing was changed."
            return 1
        fi
        rc=0
        want="$(fetch_published_sha "$url")" || rc=$?
        if [[ $rc -eq 3 ]]; then
            print_error "The published checksum for ${p} in release ${tag} is malformed; nothing was changed."
            return 1
        elif [[ $rc -ne 0 ]]; then
            print_error "No checksum is published for ${p} in release ${tag}; nothing was changed."
            return 1
        fi
        if [[ "$want" != "$(_sha256 "${BOOT_KEYS}/${p##*/}")" ]]; then
            print_error "${p} of release ${tag} does not match its published checksum; nothing was changed."
            return 1
        fi
        n=$((n + 1))
    done < "${STAGE}/MANIFEST"
    if [[ $n -eq 0 ]]; then
        print_error "Release ${tag} lists no release key (${TN_KEYS_DIR}/*.asc); nothing was changed."
        return 1
    fi
}

# check_boot_keys -- after the manifest verified with the bootstrap keys:
# every key file fetched must hash to the line the verified manifest lists.
check_boot_keys() {
    local f
    for f in "${BOOT_KEYS}"/*.asc; do
        [[ -f "$f" ]] || continue
        if [[ "$(_sha256 "$f")" != "$(manifest_sha_for "${TN_KEYS_DIR}/${f##*/}")" ]]; then
            print_error "The release key ${TN_KEYS_DIR}/${f##*/} fetched by checksum is not the one release ${M_RELEASE} lists; nothing was changed."
            return 1
        fi
    done
}

# verify_manifest MANIFEST SIG KEYDIR [quiet] -- rc 0 when SIG holds good
# signatures over MANIFEST by at least TN_SIG_THRESHOLD of the release keys in
# KEYDIR/*.asc (see RELEASE SIGNATURES). Prints the fingerprints that signed
# unless the 4th argument is quiet.
verify_manifest() {
    local kr verdict err rc=0
    if ! command -v gpgv >/dev/null 2>&1; then
        print_error "gpgv (GnuPG) is needed to verify script releases and is not installed; nothing was changed."
        print_info "  Ubuntu/Debian: sudo apt-get install -y gpgv     macOS: brew install gnupg"
        return 1
    fi
    kr="${STAGE}/release-keys.gpg"
    if ! err="$(tn_dearmor_keys "$3" 2>&1 > "$kr")"; then
        print_error "The release keys in $3 cannot be read, so no release can be verified; nothing was changed."
        printf '%s\n' "$err" | sed 's/^/        /'
        return 1
    fi
    verdict="$(tn_verify_manifest "$kr" "$2" "$1")" || rc=$?
    rm -f "$kr"
    if [[ $rc -ne 0 ]]; then
        print_error "The release manifest is not signed by a Telcoin release key ($(tn_sig_reason "$verdict")); nothing was changed."
        return 1
    fi
    [[ "${4:-}" == "quiet" ]] || print_ok "Release manifest signed by release key ${verdict#GOOD }"
}

manifest_bad() {
    print_error "The release manifest is malformed ($*); nothing was changed."
    return 1
}

# parse_manifest FILE -- fill M_RELEASE, M_SERIAL, M_MIN_UPDATER, M_DATE,
# M_EXPIRES, M_PATHS and M_SHAS from a verified manifest. Refuses the whole
# manifest on any line it does not understand, a repeated key or path, or a path
# outside the tree. date= and expires= are optional (the 2.0.0 release has
# neither); when present each appears once and is a calendar date YYYY-MM-DD.
parse_manifest() {
    local line hash path i n_fmt=0 n_rel=0 n_ser=0 n_min=0 n_date=0 n_exp=0 fmt=""
    M_RELEASE=""
    M_SERIAL=""
    M_MIN_UPDATER=""
    M_DATE=""
    M_EXPIRES=""
    M_PATHS=()
    M_SHAS=()
    if grep -q $'\r' "$1"; then manifest_bad "CR line endings"; return 1; fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            format=*)      n_fmt=$((n_fmt + 1)); fmt="${line#format=}" ;;
            release=*)     n_rel=$((n_rel + 1)); M_RELEASE="${line#release=}" ;;
            serial=*)      n_ser=$((n_ser + 1)); M_SERIAL="${line#serial=}" ;;
            min_updater=*) n_min=$((n_min + 1)); M_MIN_UPDATER="${line#min_updater=}" ;;
            date=*)        n_date=$((n_date + 1)); M_DATE="${line#date=}" ;;
            expires=*)     n_exp=$((n_exp + 1)); M_EXPIRES="${line#expires=}" ;;
            sha256\ \ *)
                if [[ ! "$line" =~ ^sha256\ \ ([0-9a-f]{64})\ \ (.+)$ ]]; then
                    manifest_bad "bad line: ${line}"
                    return 1
                fi
                hash="${BASH_REMATCH[1]}"
                path="${BASH_REMATCH[2]}"
                path_ok "$path" || { manifest_bad "bad path: ${path}"; return 1; }
                for ((i = 0; i < ${#M_PATHS[@]}; i++)); do
                    [[ "${M_PATHS[i]}" != "$path" ]] || { manifest_bad "${path} listed twice"; return 1; }
                done
                M_PATHS+=("$path")
                M_SHAS+=("$hash")
                ;;
            # A header key a later release adds (covered by the signature); a key
            # with a blank in it, such as "expires =", is malformed.
            [a-z]*=*) [[ "${line%%=*}" != *[[:space:]]* ]] || { manifest_bad "bad line: ${line}"; return 1; } ;;
            *) manifest_bad "bad line: ${line}"; return 1 ;;
        esac
    done < "$1"
    [[ $n_fmt -eq 1 && $n_rel -eq 1 && $n_ser -eq 1 && $n_min -eq 1 ]] \
        || { manifest_bad "format, release, serial and min_updater must each appear once"; return 1; }
    [[ "$fmt" == "1" ]] || { manifest_bad "format ${fmt} is not supported by this updater"; return 1; }
    [[ "$M_RELEASE" =~ $TN_SCRIPTS_TAG_RE ]] || { manifest_bad "release ${M_RELEASE}"; return 1; }
    [[ "$M_SERIAL" =~ ^[1-9][0-9]{0,8}$ ]] || { manifest_bad "serial ${M_SERIAL}"; return 1; }
    [[ "$M_MIN_UPDATER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { manifest_bad "min_updater ${M_MIN_UPDATER}"; return 1; }
    [[ $n_date -le 1 && $n_exp -le 1 ]] || { manifest_bad "date and expires may each appear once at most"; return 1; }
    if [[ $n_date -eq 1 ]] && ! ymd_days "$M_DATE" >/dev/null; then manifest_bad "date ${M_DATE}"; return 1; fi
    if [[ $n_exp -eq 1 ]] && ! ymd_days "$M_EXPIRES" >/dev/null; then manifest_bad "expires ${M_EXPIRES}"; return 1; fi
    [[ -n "$(manifest_sha_for update-scripts.sh)" ]] || { manifest_bad "update-scripts.sh not listed"; return 1; }
    for ((i = 0; i < ${#M_PATHS[@]}; i++)); do
        [[ "${M_PATHS[i]}" != "${TN_KEYS_DIR}/"*.asc ]] || return 0
    done
    manifest_bad "no release key (${TN_KEYS_DIR}/*.asc) listed"
    return 1
}

# manifest_sha_for PATH -- the hash the verified manifest lists for PATH, or "".
manifest_sha_for() {
    local i
    for ((i = 0; i < ${#M_PATHS[@]}; i++)); do
        if [[ "${M_PATHS[i]}" == "$1" ]]; then
            printf '%s\n' "${M_SHAS[i]}"
            return 0
        fi
    done
    return 0
}

# check_serial -- refuse a release older than the installed record, or a
# different manifest that reuses the installed serial.
check_serial() {
    local old
    [[ -f "$INSTALLED_MANIFEST" ]] || return 0
    old="$(awk -F= '$1 == "serial" {print $2}' "$INSTALLED_MANIFEST")"
    if [[ ! "$old" =~ ^[1-9][0-9]{0,8}$ ]]; then
        print_error "The installed release record ${INSTALLED_MANIFEST} has no readable serial; nothing was changed."
        reinstall_hint
        return 1
    fi
    if (( 10#$M_SERIAL < 10#$old )); then
        print_error "Release ${M_RELEASE} (serial ${M_SERIAL}) is older than the installed release (serial ${old}): refusing to go back; nothing was changed."
        return 1
    fi
    if (( 10#$M_SERIAL == 10#$old )) && ! cmp -s "${STAGE}/MANIFEST" "$INSTALLED_MANIFEST"; then
        print_error "Release ${M_RELEASE} reuses the installed serial ${old} with a different manifest: refusing; nothing was changed."
        return 1
    fi
}

refuse_min_updater() {
    print_error "Release ${M_RELEASE} needs update-scripts.sh ${M_MIN_UPDATER} or newer; this one is ${1}. Nothing was changed."
    reinstall_hint
}

# self_update -- when the verified manifest lists a different update-scripts.sh,
# download and verify every changed file of the release (stage_files), the
# updater among them, then run the release copy of the updater from the staging
# dir. That copy takes the staging dir over, reuses the files verified here,
# asks, and installs the whole release, itself included, in its one install
# pass: the update runs with the release's own updater logic, and the tree
# changes only in that pass. Once per invocation (TN_UPDATER_RELAUNCHED).
# Returns non-zero, with nothing installed, when a file cannot be downloaded or
# verified or the release copy is older than min_updater.
self_update() {
    local want have run newver
    [[ "${TN_UPDATER_RELAUNCHED:-}" != "1" ]] || return 0
    want="$(manifest_sha_for update-scripts.sh)"
    have="$(_sha256 "${SCRIPT_DIR}/update-scripts.sh")"
    [[ "$want" != "$have" ]] || return 0

    print_info "Release ${M_RELEASE} ships a new update-scripts.sh: verifying every changed file before running it..."
    echo ""
    plan_changes || return 1
    if ! stage_files; then
        echo ""
        print_error "A file of release ${M_RELEASE} failed verification or download; nothing was installed."
        print_info "Run the updater again in a few minutes; if it keeps failing, contact support@telcoin.org."
        return 1
    fi
    echo ""
    newver="$(_file_version "${STAGE}/files/update-scripts.sh" SCRIPT_VERSION)"
    if [[ "$newver" == "-" ]] || version_gt "$M_MIN_UPDATER" "$newver"; then
        refuse_min_updater "${SCRIPT_VERSION} (and the release copy is ${newver})"
        return 1
    fi
    # The copy that runs sits at the top of the staging dir, apart from the
    # files/ tree that the install pass moves into place.
    run="${STAGE}/update-scripts.sh"
    cp "${STAGE}/files/update-scripts.sh" "$run" || return 1
    print_info "Running the ${M_RELEASE} copy of update-scripts.sh to install the release..."
    # exec skips the EXIT trap: the release copy removes the staging dir.
    TN_UPDATER_RELAUNCHED=1 exec bash "$run"
}

# plan_changes -- fill UPD_PATHS with every listed file that is missing or
# differs from the manifest, and DEL_PATHS with files the installed record lists
# that the new manifest does not.
plan_changes() {
    local i p dest
    UPD_PATHS=()
    DEL_PATHS=()
    for ((i = 0; i < ${#M_PATHS[@]}; i++)); do
        p="${M_PATHS[i]}"
        dest="${SCRIPT_DIR}/${p}"
        if [[ -L "$dest" || ! -e "$dest" ]]; then
            UPD_PATHS+=("$p")
        elif [[ ! -f "$dest" ]]; then
            print_error "${dest} is not a regular file; nothing was changed."
            return 1
        elif [[ "$(_sha256 "$dest")" != "${M_SHAS[i]}" ]]; then
            UPD_PATHS+=("$p")
        fi
    done
    [[ -f "$INSTALLED_MANIFEST" ]] || return 0
    while IFS= read -r p; do
        path_ok "$p" || continue
        [[ -z "$(manifest_sha_for "$p")" ]] || continue
        if [[ -f "${SCRIPT_DIR}/${p}" || -L "${SCRIPT_DIR}/${p}" ]]; then
            DEL_PATHS+=("$p")
        fi
    done < <(awk '/^sha256  [0-9a-f]+  / {print $3}' "$INSTALLED_MANIFEST")
}

# stage_files -- download every file in UPD_PATHS from the release tag into the
# staging dir and check it: the manifest hash, the published sidecar when one
# exists, and `bash -n` for scripts. A file self_update already verified into
# this staging dir is kept when it still matches the manifest. rc 0 only when
# every file passed.
stage_files() {
    local i p url tmp want side rc
    for ((i = 0; i < ${#UPD_PATHS[@]}; i++)); do
        p="${UPD_PATHS[i]}"
        want="$(manifest_sha_for "$p")"
        tmp="${STAGE}/files/${p}"
        if [[ -f "$tmp" && ! -L "$tmp" && "$(_sha256 "$tmp")" == "$want" ]]; then
            printf "  Staged      %-36s " "${p}..."
            if [[ "$p" == *.sh ]] && ! bash -n "$tmp" 2>/dev/null; then
                echo -e "${RED}FAILED${RESET}  (syntax check)"
                return 1
            fi
            echo -e "${GREEN}verified${RESET}"
            continue
        fi
        mkdir -p "$(dirname "$tmp")"
        url="$(tag_url "$M_RELEASE" "$p")"
        printf "  Downloading %-36s " "${p}..."
        if ! fetch "$url" "$tmp"; then
            echo -e "${RED}FAILED${RESET}  (download error)"
            return 1
        fi
        if [[ "$(_sha256 "$tmp")" != "$want" ]]; then
            echo -e "${RED}FAILED${RESET}  (does not match the signed manifest)"
            return 1
        fi
        rc=0
        side="$(fetch_published_sha "$url")" || rc=$?
        if [[ $rc -eq 2 ]]; then
            echo -e "${RED}FAILED${RESET}  (checksum download error)"
            return 1
        fi
        if [[ $rc -eq 3 ]]; then
            echo -e "${RED}FAILED${RESET}  (its published .sha256 is malformed)"
            return 1
        fi
        if [[ $rc -eq 0 && "$side" != "$want" ]]; then
            echo -e "${RED}FAILED${RESET}  (its .sha256 disagrees with the signed manifest)"
            return 1
        fi
        if [[ "$p" == *.sh ]] && ! bash -n "$tmp" 2>/dev/null; then
            echo -e "${RED}FAILED${RESET}  (syntax check)"
            return 1
        fi
        echo -e "${GREEN}verified${RESET}"
    done
}

# install_pass -- move every staged file into place, remove the files the
# release dropped, then write the release record. Runs only after stage_files
# verified every file.
install_pass() {
    local i p dest
    INSTALLING=1
    for ((i = 0; i < ${#UPD_PATHS[@]}; i++)); do
        p="${UPD_PATHS[i]}"
        dest="${SCRIPT_DIR}/${p}"
        if [[ "$p" == *.sh ]]; then
            chmod +x "${STAGE}/files/${p}" 2>/dev/null || true
        fi
        if ! mkdir -p "$(dirname "$dest")" || ! mv -f "${STAGE}/files/${p}" "$dest"; then
            print_error "Could not install ${p}. The release record was not updated: run the updater again."
            INSTALLING=0
            return 1
        fi
    done
    for ((i = 0; i < ${#DEL_PATHS[@]}; i++)); do
        rm -f "${SCRIPT_DIR:?}/${DEL_PATHS[i]}"
    done
    mv -f "${STAGE}/${TN_SIG_FILE}" "$INSTALLED_SIG"
    mv -f "${STAGE}/MANIFEST" "$INSTALLED_MANIFEST"
    INSTALLING=0
}

# =============================================================================
# UPDATE
# =============================================================================

print_plan() {
    local i p var
    printf "  %-36s %-10s %-10s %s\n" "File" "Local" "Release" "Status"
    print_sep
    for ((i = 0; i < ${#UPD_PATHS[@]}; i++)); do
        p="${UPD_PATHS[i]}"
        var="$(version_var_for "$p")"
        if [[ -e "${SCRIPT_DIR}/${p}" ]]; then
            printf "  %-36s %-10s %-10s ${YELLOW}%s${RESET}\n" "$p" \
                "$(_file_version "${SCRIPT_DIR}/${p}" "$var")" "$(_file_version "${STAGE}/files/${p}" "$var")" "UPDATE"
        else
            printf "  %-36s %-10s %-10s ${YELLOW}%s${RESET}\n" "$p" \
                "missing" "$(_file_version "${STAGE}/files/${p}" "$var")" "NEW"
        fi
    done
    for ((i = 0; i < ${#DEL_PATHS[@]}; i++)); do
        printf "  %-36s %-10s %-10s ${YELLOW}%s${RESET}\n" "${DEL_PATHS[i]}" "-" "-" "REMOVE (no longer shipped)"
    done
    echo ""
}

# warn_expired -- the warning an update run prints when the verified release
# has expired. An expiry date tells the release signer a newer release is due;
# the release still verifies, so the run carries on and installs it.
warn_expired() {
    local more=""
    release_expired "$M_EXPIRES" >/dev/null || return 0
    [[ ${#UPD_PATHS[@]} -eq 0 && ${#DEL_PATHS[@]} -eq 0 ]] || more=" Installing it anyway."
    print_warn "Script release ${M_RELEASE} expired on ${M_EXPIRES}; a newer signed release is overdue.${more}"
    print_info "The release still verifies. If no newer one appears soon, tell support@telcoin.org."
    echo ""
}

run_update() {
    local keys choice i ui_changed=false svc

    print_info "Checking for a signed script release..."
    print_info "Repository: ${TN_REPO_RAW}"
    echo ""

    # Connectivity probe: HEAD a small known file on the host the updater
    # fetches from (README.md stays at the repository root for this).
    if ! curl --proto '=https' --tlsv1.2 -fsSLI --max-time 8 "${GITHUB_RAW}/README.md" >/dev/null 2>&1; then
        print_error "Cannot reach ${GITHUB_RAW} -- check internet/DNS or GitHub status"
        exit 1
    fi

    if [[ -z "$STAGE" ]]; then
        STAGE="$(mktemp -d "${SCRIPT_DIR}/.tn-update.XXXXXX")" || {
            print_error "Could not create a staging directory in ${SCRIPT_DIR}."
            exit 1
        }
    fi

    read_release_tag || exit 1
    print_info "Latest release: ${RELEASE_TAG}"
    fetch_release_file "$RELEASE_TAG" MANIFEST || exit 1
    fetch_release_file "$RELEASE_TAG" "$TN_SIG_FILE" || exit 1

    keys="$KEYS_DIR"
    if ! have_keys "$keys"; then
        if [[ -f "$INSTALLED_MANIFEST" ]]; then
            print_error "${TN_KEYS_DIR} holds no release key (*.asc), so no release can be verified; nothing was changed."
            reinstall_hint
            exit 1
        fi
        bootstrap_keys "$RELEASE_TAG" || exit 1
        keys="$BOOT_KEYS"
    fi

    verify_manifest "${STAGE}/MANIFEST" "${STAGE}/${TN_SIG_FILE}" "$keys" || exit 1
    parse_manifest "${STAGE}/MANIFEST" || exit 1
    if [[ "$M_RELEASE" != "$RELEASE_TAG" ]]; then
        print_error "The manifest is for ${M_RELEASE}, but RELEASE names ${RELEASE_TAG}: refusing; nothing was changed."
        exit 1
    fi
    if [[ "$keys" == "$BOOT_KEYS" ]]; then
        check_boot_keys || exit 1
    fi
    check_serial || exit 1
    self_update || exit 1
    if version_gt "$M_MIN_UPDATER" "$SCRIPT_VERSION"; then
        refuse_min_updater "$SCRIPT_VERSION"
        exit 1
    fi
    plan_changes || exit 1
    warn_expired

    if [[ ${#UPD_PATHS[@]} -eq 0 && ${#DEL_PATHS[@]} -eq 0 ]]; then
        if ! cmp -s "${STAGE}/MANIFEST" "$INSTALLED_MANIFEST" 2>/dev/null; then
            mv -f "${STAGE}/${TN_SIG_FILE}" "$INSTALLED_SIG"
            mv -f "${STAGE}/MANIFEST" "$INSTALLED_MANIFEST"
            print_info "Every file already matches ${M_RELEASE}; recorded it as the installed release."
        fi
        print_ok "All scripts are up to date (${M_RELEASE}, serial ${M_SERIAL})"
        echo ""
        exit 0
    fi

    print_info "Release ${M_RELEASE} (serial ${M_SERIAL}): verifying ${#UPD_PATHS[@]} file(s) before installing any..."
    echo ""
    if ! stage_files; then
        echo ""
        print_error "A file of release ${M_RELEASE} failed verification or download; nothing was installed."
        print_info "Run the updater again in a few minutes; if it keeps failing, contact support@telcoin.org."
        exit 1
    fi
    echo ""
    print_plan

    if ! read -r -p "  Install these changes? [Y/n]: " choice; then
        choice="n"
        echo ""
    fi
    choice="${choice:-Y}"
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        print_info "Update cancelled -- no changes made."
        echo ""
        exit 0
    fi

    for ((i = 0; i < ${#UPD_PATHS[@]}; i++)); do
        [[ "${UPD_PATHS[i]}" != ui/* ]] || ui_changed=true
    done
    install_pass || exit 1

    echo ""
    print_ok "Installed ${M_RELEASE}: ${#UPD_PATHS[@]} file(s) updated, ${#DEL_PATHS[@]} removed."
    print_info "If a node is running, restart it to apply any changes:"
    svc="$(tn_resolve_service 2>/dev/null || echo telcoin)"
    print_info "  sudo systemctl restart ${svc}"
    echo ""
    # The web UI runs from a root-owned copy. The updater never runs sudo itself:
    # it prints the command that redeploys (or installs) the UI from this tree.
    if [[ "$ui_changed" == "true" ]]; then
        if [[ -d /opt/telcoin-ui ]]; then
            print_info "The web UI files changed. Redeploy the UI to load them:"
            print_info "  sudo bash ${SCRIPT_DIR}/ui/install-ui.sh --update"
        else
            print_info "UI source updated. To set up the web UI:"
            print_info "  sudo bash ${SCRIPT_DIR}/ui/install-ui.sh"
        fi
        echo ""
    fi
}

# =============================================================================
# CHECK (--check)
# =============================================================================

# release_line TAG SERIAL DATE EXPIRES -- one release for the --check report.
release_line() {
    local when="released $3" exp="no expiry date"
    [[ -n "$3" ]] || when="release date not recorded"
    [[ -z "$4" ]] || exp="expires $4"
    printf '%s, serial %s, %s, %s\n' "$1" "$2" "$when" "$exp"
}

# check_release -- the --check report: the installed release (its record checked
# against the release keys in lib/release-keys) and whether it has expired, then the newest
# release (RELEASE on main and the signed MANIFEST of the tag it names), whether
# an update is pending and whether the newest release has expired. Downloads
# into a temp dir only and changes nothing in the tree. rc 0 when the installed
# release is the newest and neither has expired; 1 when an update is pending or
# a release has expired; 2 when no signed release is installed, the installed
# record does not verify, or the newest release cannot be fetched or verified or
# would be refused. 2 wins over 1; the installed release's expiry is reported
# before anything is fetched, so it is printed in every case.
check_release() {
    local rc=0 installed=none i_rel="" i_ser="" i_exp="" ago
    # The temp dir comes first: verifying the installed record needs it too.
    STAGE="$(mktemp -d "${TMPDIR:-/tmp}/tn-update-check.XXXXXX" 2>/dev/null \
        || mktemp -d /tmp/tn-update-check.XXXXXX)" || {
        print_error "Could not create a temp directory for the check."
        return 2
    }
    if [[ ! -f "$INSTALLED_MANIFEST" ]]; then
        print_warn "No signed release is installed in ${SCRIPT_DIR} (no MANIFEST record)."
    elif ! have_keys "$KEYS_DIR" || [[ ! -f "$INSTALLED_SIG" ]]; then
        print_error "The installed release record cannot be verified: ${KEYS_DIR} holds no release key (*.asc) or ${INSTALLED_SIG} is missing."
        reinstall_hint
        installed=bad
    elif ! verify_manifest "$INSTALLED_MANIFEST" "$INSTALLED_SIG" "$KEYS_DIR" quiet \
        || ! parse_manifest "$INSTALLED_MANIFEST"; then
        print_info "That is the installed release record ${INSTALLED_MANIFEST}."
        reinstall_hint
        installed=bad
    else
        installed=ok
        i_rel="$M_RELEASE"
        i_ser="$M_SERIAL"
        i_exp="$M_EXPIRES"
        print_info "Installed:  $(release_line "$M_RELEASE" "$M_SERIAL" "$M_DATE" "$M_EXPIRES") (signature verified)"
        if ago="$(release_expired "$i_exp")"; then
            print_warn "Installed release ${i_rel} expired on ${i_exp} (${ago}); a newer signed release is overdue."
            rc=1
        fi
    fi

    read_release_tag || return 2
    fetch_release_file "$RELEASE_TAG" MANIFEST || return 2
    fetch_release_file "$RELEASE_TAG" "$TN_SIG_FILE" || return 2
    if ! have_keys "$KEYS_DIR"; then
        print_error "Release ${RELEASE_TAG} cannot be verified: ${KEYS_DIR} holds no release key (*.asc)."
        return 2
    fi
    verify_manifest "${STAGE}/MANIFEST" "${STAGE}/${TN_SIG_FILE}" "$KEYS_DIR" quiet || return 2
    parse_manifest "${STAGE}/MANIFEST" || return 2
    if [[ "$M_RELEASE" != "$RELEASE_TAG" ]]; then
        print_error "The manifest is for ${M_RELEASE}, but RELEASE names ${RELEASE_TAG}: the updater refuses it."
        return 2
    fi
    print_info "Newest:     $(release_line "$M_RELEASE" "$M_SERIAL" "$M_DATE" "$M_EXPIRES") (signature verified)"
    if [[ "$installed" != "ok" ]]; then
        [[ "$installed" != "none" ]] || print_info "To install it: bash ${SCRIPT_DIR}/update-scripts.sh"
        return 2
    fi

    # A release the updater would refuse is a failed check, not a pending update:
    # a pointer that goes back to an older or a different manifest can mean
    # tampering.
    if (( 10#$M_SERIAL < 10#$i_ser )); then
        print_error "RELEASE names ${M_RELEASE} (serial ${M_SERIAL}), older than the installed release (serial ${i_ser}): the updater refuses it."
        print_info "A release pointer that goes back can mean tampering: tell support@telcoin.org."
        return 2
    elif (( 10#$M_SERIAL == 10#$i_ser )) && ! cmp -s "${STAGE}/MANIFEST" "$INSTALLED_MANIFEST"; then
        print_error "Release ${M_RELEASE} reuses the installed serial ${i_ser} with a different manifest: the updater refuses it."
        print_info "Two manifests with one serial can mean tampering: tell support@telcoin.org."
        return 2
    elif ! plan_changes; then
        return 2
    elif [[ ${#UPD_PATHS[@]} -gt 0 || ${#DEL_PATHS[@]} -gt 0 ]]; then
        print_warn "Update pending: ${#UPD_PATHS[@]} file(s) to update, ${#DEL_PATHS[@]} to remove. Run: bash ${SCRIPT_DIR}/update-scripts.sh"
        rc=1
    elif ! cmp -s "${STAGE}/MANIFEST" "$INSTALLED_MANIFEST"; then
        print_warn "Update pending: every file already matches ${M_RELEASE}, but the record names ${i_rel}. Run: bash ${SCRIPT_DIR}/update-scripts.sh"
        rc=1
    else
        print_ok "No update pending: every file matches ${M_RELEASE}."
    fi

    if [[ "$M_RELEASE" != "$i_rel" ]] && ago="$(release_expired "$M_EXPIRES")"; then
        print_warn "Newest release ${M_RELEASE} expired on ${M_EXPIRES} (${ago}); a newer signed release is overdue."
        rc=1
    fi
    if [[ $rc -eq 0 ]]; then
        if [[ -n "$M_EXPIRES" ]]; then
            print_ok "Up to date with ${M_RELEASE}; it expires ${M_EXPIRES} (in $(days_text "$(days_left "$M_EXPIRES")"))."
        else
            print_ok "Up to date with ${M_RELEASE}; it carries no expiry date."
        fi
    fi
    return "$rc"
}

# =============================================================================
# MAIN
# =============================================================================

usage() {
    cat <<EOF
update-scripts.sh v${SCRIPT_VERSION} -- update the Telcoin Network node scripts

Usage: bash update-scripts.sh [--check | -h | --help]

Reads the latest release tag from
  ${TN_RELEASE_POINTER_URL}
downloads that release's MANIFEST and MANIFEST.asc, and checks the OpenPGP
signatures with gpgv against the release keys (lib/release-keys/*.asc) in
  ${SCRIPT_DIR}
At least ${TN_SIG_THRESHOLD} release key(s) must have signed; a bad, expired or
revoked signature refuses the release. A host with no release key and no
installed release takes the keys once from the release, each checked against
its published .sha256. Needs gpgv (Ubuntu/Debian: apt-get install gpgv; macOS:
brew install gnupg).
It refuses a release older than the installed one (the serial in MANIFEST), and
a release whose min_updater is newer than both this updater and the release's
own copy of it.

Every changed file is downloaded from the release tag and must match its
MANIFEST hash (and its .sha256 sidecar, when one is published) before anything
is installed. When the release lists a different update-scripts.sh, the
release's copy, verified with the rest, then runs from the staging directory
and carries on from there. It asks "Install these changes? [Y/n]"; Enter means
yes. All the changed files, the updater among them, are then installed
together, files the release no longer ships are removed, and MANIFEST records
the installed release. On any refusal or failure the tree is left as it was.

The web UI is not redeployed automatically: the updater prints the sudo command.

A release carries an expiry date (expires= in MANIFEST, 90 days after its
release date unless the release signer chose otherwise). From that day on the
updater warns "Script release <tag> expired on <date>; a newer signed release
is overdue." and still installs the release: it verifies as before.

The answer is read from standard input; there is no --yes option. To answer
from a script: printf 'y\n' | bash update-scripts.sh

Options:
  --check      Report the installed release and the newest signed release (tag,
               serial, release date, expiry date), whether an update is pending
               and whether either release has expired. Installs nothing, needs
               no root, and asks nothing.
  -h, --help   Show this help and exit without contacting GitHub.

Exit status: 0 when everything is current, updated, or the update is declined;
1 when GitHub cannot be reached, or a release is refused or fails verification;
2 for an unknown argument.
With --check:
  0  the installed release is the newest and neither has expired.
  1  an update is pending, or the installed or the newest release has expired.
  2  no signed release is installed; the installed release record does not
     verify; the newest release cannot be fetched or verified (no RELEASE, a
     network error, a bad signature, a malformed manifest); or the updater
     would refuse it (a lower serial than the installed one, the installed
     serial with a different manifest, or a listed file that is not a regular
     file here).
  When a case of 2 and one of 1 both hold, the exit status is 2. The expiry of
  the installed release is checked before anything is downloaded, so its
  warning is printed in every case.
EOF
}

main() {
    # Arguments are handled before anything touches the network. The updater
    # takes --check and --help; anything else is refused rather than ignored.
    local arg mode=update rc=0
    for arg in "$@"; do
        case "$arg" in
            -h|--help) usage; exit 0 ;;
        esac
    done
    for arg in "$@"; do
        case "$arg" in
            --check) mode=check ;;
            *)
                printf 'update-scripts.sh: unknown argument: %s\n\n' "$arg" >&2
                usage >&2
                exit 2
                ;;
        esac
    done

    # The staging dir is removed however the run ends. The signal traps turn
    # Ctrl-C, a hangup and SIGTERM into an exit, so the EXIT trap runs on every
    # bash.
    trap cleanup_stage EXIT
    trap 'exit 130' INT
    trap 'exit 129' HUP
    trap 'exit 143' TERM

    # The report is meant for a terminal or a cron job alike: no screen clear,
    # no banner, and the exit status carries the answer.
    if [[ "$mode" == "check" ]]; then
        check_release || rc=$?
        exit "$rc"
    fi

    # Clearing the screen is cosmetic: with TERM unset or unusable `clear` fails,
    # and that must not end the run under set -e.
    clear 2>/dev/null || true
    echo -e "${BLUE}${BOLD}"
    echo "================================================================"
    echo "  Telcoin Network -- Script Updater  v${SCRIPT_VERSION}"
    echo "================================================================"
    echo -e "${RESET}"

    run_update
}

main "$@"
