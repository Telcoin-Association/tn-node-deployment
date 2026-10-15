#!/usr/bin/env bash
# =============================================================================
# update-scripts.sh -- Telcoin Network Script Updater
#
# Brings the node scripts to the latest signed release: reads the release tag
# from RELEASE on main, verifies that tag's MANIFEST.sig against
# lib/allowed_signers, and installs every file whose hash differs from the
# MANIFEST, all together or not at all.
#
# USAGE:
#   bash ~/telcoin-node-scripts/update-scripts.sh
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

readonly SCRIPT_VERSION="1.1.72"
readonly TN_REPO_RAW="https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment"
# main serves only the RELEASE pointer and the connectivity probe; every release
# file is fetched from the tag RELEASE names.
readonly GITHUB_RAW="${TN_REPO_RAW}/main"
readonly TN_RELEASE_POINTER_URL="${GITHUB_RAW}/RELEASE"
readonly TN_SCRIPTS_TAG_RE='^scripts-v[0-9]+\.[0-9]+\.[0-9]+$'
readonly TN_SIGNER_PRINCIPAL="release@telcoin.org"
readonly TN_SIGNER_NAMESPACE="tn-node-scripts"
readonly TN_INSTALLER_URL="https://install.telcoin.network"

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
)
# NOTE: this list MUST name every maintainer key in lib/wgvpn/peers/ssh/*.pub. The
# updater fetches files by explicit path (it cannot glob the remote), so a key omitted
# here is silently NOT delivered to operators who update via update-scripts.sh — and
# the next `setup-vpn.sh --sync-keys` would then bake an INCOMPLETE maintainer set.
# When the admin add-peer.sh mirrors a new maintainer key into this repo, add a row here.

# The installed release record: the signed MANIFEST and MANIFEST.sig of the
# release this tree was last brought to. The install pass writes them last, so
# they name a release only once every file of it is in place.
readonly INSTALLED_MANIFEST="${SCRIPT_DIR}/MANIFEST"
readonly INSTALLED_SIG="${SCRIPT_DIR}/MANIFEST.sig"
readonly SIGNERS_FILE="${SCRIPT_DIR}/lib/allowed_signers"

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
BOOT_SIGNERS=""
M_RELEASE=""
M_SERIAL=""
M_MIN_UPDATER=""
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

# path_ok P -- rc 0 for a relative path made of [A-Za-z0-9._/-] with no empty,
# "." or ".." component and no leading "-". A manifest naming anything else is
# refused whole. MANIFEST and MANIFEST.sig are the record, never a listed file.
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
# rc 0: printed a 64-hex-digit hash. rc 1: no usable sidecar (HTTP error, or the
# first field is not a 64-hex-digit hash). rc 2: the sidecar could not be fetched
# (network). The signed manifest is authoritative; a sidecar that exists must
# agree with it (older updaters still read the sidecars).
fetch_published_sha() {
    local body sha rc=0
    body="$(curl --proto '=https' --tlsv1.2 -fsSL --max-time 10 "${1}.sha256" 2>/dev/null)" || rc=$?
    if [[ $rc -eq 22 ]]; then
        return 1
    elif [[ $rc -ne 0 ]]; then
        return 2
    fi
    sha="$(printf '%s\n' "$body" | awk 'NR == 1 {print $1}')"
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || return 1
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

# bootstrap_signers TAG -- the first signed release reaching a tree that has
# neither lib/allowed_signers nor a MANIFEST record fetches the signer list once
# through its published .sha256, the channel that delivered this updater. From
# then on a new signer list arrives only in a manifest that verifies against the
# installed one.
bootstrap_signers() {
    local url want rc=0
    BOOT_SIGNERS="${STAGE}/allowed_signers.bootstrap"
    url="$(tag_url "$1" lib/allowed_signers)"
    print_warn "First signed release on this host: fetching the release signer list through its published checksum (one time only)."
    if ! fetch "$url" "$BOOT_SIGNERS"; then
        print_error "Could not download lib/allowed_signers of release $1; nothing was changed."
        return 1
    fi
    want="$(fetch_published_sha "$url")" || rc=$?
    if [[ $rc -ne 0 ]]; then
        print_error "No checksum is published for lib/allowed_signers in release $1; nothing was changed."
        return 1
    fi
    if [[ "$want" != "$(_sha256 "$BOOT_SIGNERS")" ]]; then
        print_error "lib/allowed_signers of release $1 does not match its published checksum; nothing was changed."
        return 1
    fi
}

# verify_manifest MANIFEST SIG SIGNERS -- rc 0 when SIG is a good signature over
# MANIFEST by a key SIGNERS lists for release@telcoin.org and tn-node-scripts.
verify_manifest() {
    local out
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        print_error "ssh-keygen (OpenSSH) is needed to verify script releases and is not installed; nothing was changed."
        print_info "  Ubuntu/Debian: sudo apt-get install -y openssh-client"
        return 1
    fi
    if ! out="$(ssh-keygen -Y verify -f "$3" -I "$TN_SIGNER_PRINCIPAL" -n "$TN_SIGNER_NAMESPACE" \
        -s "$2" < "$1" 2>&1)"; then
        print_error "The release manifest is not signed by a Telcoin release key; nothing was changed."
        printf '%s\n' "$out" | sed 's/^/        /'
        return 1
    fi
    print_ok "$(printf '%s\n' "$out" | head -1)"
}

manifest_bad() {
    print_error "The release manifest is malformed ($*); nothing was changed."
    return 1
}

# parse_manifest FILE -- fill M_RELEASE, M_SERIAL, M_MIN_UPDATER, M_PATHS and
# M_SHAS from a verified manifest. Refuses the whole manifest on any line it
# does not understand, a repeated key or path, or a path outside the tree.
parse_manifest() {
    local line hash path i n_fmt=0 n_rel=0 n_ser=0 n_min=0 fmt=""
    M_RELEASE=""
    M_SERIAL=""
    M_MIN_UPDATER=""
    M_PATHS=()
    M_SHAS=()
    if grep -q $'\r' "$1"; then manifest_bad "CR line endings"; return 1; fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            format=*)      n_fmt=$((n_fmt + 1)); fmt="${line#format=}" ;;
            release=*)     n_rel=$((n_rel + 1)); M_RELEASE="${line#release=}" ;;
            serial=*)      n_ser=$((n_ser + 1)); M_SERIAL="${line#serial=}" ;;
            min_updater=*) n_min=$((n_min + 1)); M_MIN_UPDATER="${line#min_updater=}" ;;
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
            [a-z]*=*) ;;   # a header key a later release adds; covered by the signature
            *) manifest_bad "bad line: ${line}"; return 1 ;;
        esac
    done < "$1"
    [[ $n_fmt -eq 1 && $n_rel -eq 1 && $n_ser -eq 1 && $n_min -eq 1 ]] \
        || { manifest_bad "format, release, serial and min_updater must each appear once"; return 1; }
    [[ "$fmt" == "1" ]] || { manifest_bad "format ${fmt} is not supported by this updater"; return 1; }
    [[ "$M_RELEASE" =~ $TN_SCRIPTS_TAG_RE ]] || { manifest_bad "release ${M_RELEASE}"; return 1; }
    [[ "$M_SERIAL" =~ ^[1-9][0-9]{0,8}$ ]] || { manifest_bad "serial ${M_SERIAL}"; return 1; }
    [[ "$M_MIN_UPDATER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { manifest_bad "min_updater ${M_MIN_UPDATER}"; return 1; }
    [[ -n "$(manifest_sha_for update-scripts.sh)" ]] || { manifest_bad "update-scripts.sh not listed"; return 1; }
    [[ -n "$(manifest_sha_for lib/allowed_signers)" ]] || { manifest_bad "lib/allowed_signers not listed"; return 1; }
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
    mv -f "${STAGE}/MANIFEST.sig" "$INSTALLED_SIG"
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

run_update() {
    local signers choice i ui_changed=false svc

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
    fetch_release_file "$RELEASE_TAG" MANIFEST.sig || exit 1

    signers="$SIGNERS_FILE"
    if [[ ! -f "$signers" ]]; then
        if [[ -f "$INSTALLED_MANIFEST" ]]; then
            print_error "lib/allowed_signers is missing, so no release can be verified; nothing was changed."
            reinstall_hint
            exit 1
        fi
        bootstrap_signers "$RELEASE_TAG" || exit 1
        signers="$BOOT_SIGNERS"
    fi

    verify_manifest "${STAGE}/MANIFEST" "${STAGE}/MANIFEST.sig" "$signers" || exit 1
    parse_manifest "${STAGE}/MANIFEST" || exit 1
    if [[ "$M_RELEASE" != "$RELEASE_TAG" ]]; then
        print_error "The manifest is for ${M_RELEASE}, but RELEASE names ${RELEASE_TAG}: refusing; nothing was changed."
        exit 1
    fi
    if [[ "$signers" == "$BOOT_SIGNERS" && "$(_sha256 "$signers")" != "$(manifest_sha_for lib/allowed_signers)" ]]; then
        print_error "The signer list fetched by checksum is not the one release ${M_RELEASE} lists; nothing was changed."
        exit 1
    fi
    check_serial || exit 1
    self_update || exit 1
    if version_gt "$M_MIN_UPDATER" "$SCRIPT_VERSION"; then
        refuse_min_updater "$SCRIPT_VERSION"
        exit 1
    fi
    plan_changes || exit 1

    if [[ ${#UPD_PATHS[@]} -eq 0 && ${#DEL_PATHS[@]} -eq 0 ]]; then
        if ! cmp -s "${STAGE}/MANIFEST" "$INSTALLED_MANIFEST" 2>/dev/null; then
            mv -f "${STAGE}/MANIFEST.sig" "$INSTALLED_SIG"
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
# MAIN
# =============================================================================

usage() {
    cat <<EOF
update-scripts.sh v${SCRIPT_VERSION} -- update the Telcoin Network node scripts

Usage: bash update-scripts.sh [-h | --help]

Reads the latest release tag from
  ${TN_RELEASE_POINTER_URL}
downloads that release's MANIFEST and MANIFEST.sig, and checks the signature
against lib/allowed_signers in
  ${SCRIPT_DIR}
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

The answer is read from standard input; there is no --yes option. To answer
from a script: printf 'y\n' | bash update-scripts.sh

Options:
  -h, --help   Show this help and exit without contacting GitHub.

Exit status: 0 when everything is current, updated, or the update is declined;
1 when GitHub cannot be reached, or a release is refused or fails verification;
2 for an unknown argument.
EOF
}

main() {
    # Arguments are handled before anything touches the network. The updater
    # takes none besides --help; anything else is refused rather than ignored.
    local arg
    for arg in "$@"; do
        case "$arg" in
            -h|--help) usage; exit 0 ;;
        esac
    done
    if [[ $# -gt 0 ]]; then
        printf 'update-scripts.sh: unknown argument: %s\n\n' "$1" >&2
        usage >&2
        exit 2
    fi

    # The staging dir is removed however the run ends. The signal traps turn
    # Ctrl-C, a hangup and SIGTERM into an exit, so the EXIT trap runs on every
    # bash.
    trap cleanup_stage EXIT
    trap 'exit 130' INT
    trap 'exit 129' HUP
    trap 'exit 143' TERM

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
