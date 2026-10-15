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
# when every file verified; any failure exits.
verify_release() {
    local src="$1" tree="$2" signers="${STAGE}/allowed_signers"
    local line key val fmt="" rel="" serial="" n=0 hash path have seen

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
            format=*|release=*|serial=*|min_updater=*)
                key="${line%%=*}"
                val="${line#*=}"
                if grep -qx "h:${key}" "$seen"; then fail "MANIFEST repeats ${key}=."; fi
                printf 'h:%s\n' "$key" >> "$seen"
                case "$key" in
                    format) fmt="$val" ;;
                    release) rel="$val" ;;
                    serial) serial="$val" ;;
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
            [a-z]*=*) ;;   # a header key a later format adds; covered by the signature
            *) fail "MANIFEST line is malformed: ${line}" ;;
        esac
    done < "${src}/MANIFEST"
    [[ "$fmt" == "1" ]] || fail "MANIFEST format ${fmt:-missing} is not supported by this installer."
    [[ "$rel" == "$TN_SCRIPTS_TAG" ]] || fail "MANIFEST is for ${rel:-no release}, expected ${TN_SCRIPTS_TAG}."
    [[ "$serial" =~ ^[1-9][0-9]{0,8}$ ]] || fail "MANIFEST serial is malformed."
    [[ $n -gt 0 ]] || fail "MANIFEST lists no files."
    grep -qx 'p:update-scripts.sh' "$seen" || fail "MANIFEST does not list update-scripts.sh."
    grep -qx 'p:lib/allowed_signers' "$seen" || fail "MANIFEST does not list lib/allowed_signers."
    cp "${src}/MANIFEST" "${tree}/MANIFEST"
    cp "${src}/MANIFEST.sig" "${tree}/MANIFEST.sig"
    find "$tree" -type f -name '*.sh' -exec chmod +x {} +
    print_ok "All ${n} files match the signed MANIFEST (serial ${serial})"
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
    STAGE="$(mktemp -d "${HOME}/.telcoin-node-scripts.XXXXXX")" || fail "Could not create a staging directory in ${HOME}."
    trap 'rm -rf "$STAGE"' EXIT
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
    if [[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
    fi
    mv "${STAGE}/tree" "$INSTALL_DIR" || fail "Could not move the verified files to ${INSTALL_DIR}."
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
