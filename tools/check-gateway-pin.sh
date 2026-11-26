#!/usr/bin/env bash
# =============================================================================
# tools/check-gateway-pin.sh -- each worker-gateway pin of lib/gateway.sh is the
# image of the signed telcoin-network release recorded beside it
#
#   bash tools/check-gateway-pin.sh [--gateway-lib FILE] [--release-dir DIR | --base-url URL]
#
# lib/gateway.sh pins one worker-gateway image per network and names, on the
# same line, the telcoin-network release the image comes from
# (GW_TESTNET_IMAGE_PIN with GW_TESTNET_PIN_RELEASE, GW_MAINNET_IMAGE_PIN with
# GW_MAINNET_PIN_RELEASE). For each network, testnet first, a set pin passes
# only when, in this order:
#   1. the pin and its release are both set. Once TN_MAINNET_ENABLED of
#      lib/common.sh is 1 (tn_mainnet_enabled), the release that offers
#      mainnet, the mainnet pin must be set: an empty one is refused;
#   2. the release is a tag of that network (tn_release_tag_ok), so a release
#      candidate never backs the mainnet pin. One exception, the mainnet
#      placeholder: until telcoin-network publishes a mainnet release, a final
#      testnet release (tn_release_tag_final) backs the mainnet pin while
#      TN_MAINNET_ENABLED is 0, with a "mainnet: note: placeholder" line, and
#      rules 3 to 7 run against that release. At 1 it is refused, so the
#      release that offers mainnet pins a mainnet release;
#   3. the pin is GW_RELEASE_IMAGE_REPO@sha256:<64 lowercase hex>;
#   4. the release's SHA256SUMS-edge.asc verifies over its SHA256SUMS-edge
#      against lib/release-keys, judged by _tn_release_keyring and
#      _tn_release_sig_ok of lib/common.sh, the verdict a node release gets;
#   5. SHA256SUMS-edge lists only edge files of that release, each once:
#      IMAGE_DIGEST-<service> and <service>-<release>-x86_64-unknown-linux-gnu.tar.gz,
#      both or neither for each service, the worker gateway's among them. The
#      tarball names carry the tag, so another release's manifest, signed by
#      the same keys, does not pass;
#   6. IMAGE_DIGEST-worker-gateway has the hash its SHA256SUMS-edge line gives
#      and holds one line, GW_RELEASE_IMAGE_REPO@sha256:<64 lowercase hex>;
#   7. that line is the pin.
# A refusal or a failure on one network does not stop the other's check.
#
# Two modes. Online, the default, downloads <URL>/<release>/<file> over https
# with curl; URL is --base-url, else TN_RELEASE_BASE_URL of lib/common.sh (the
# telcoin-network GitHub releases). Offline, --release-dir DIR reads
# DIR/<release>/<file>, which must be regular files, and needs no network and
# no curl. --gateway-lib FILE checks the pins FILE sets instead of those of
# lib/gateway.sh; a file holding only the five assignments is enough.
#
# Environment:
#   TN_RELEASE_KEYS_DIR  release keys to verify against instead of
#                        lib/release-keys (the test hook of lib/common.sh).
#                        Refused for a release on TN_RELEASE_BASE_URL, so a
#                        published release is never judged against other keys.
#   TMPDIR               where the work directory is made (default /tmp)
#
# Empty pins pass without a download and without gpg, curl or sha256sum while
# TN_MAINNET_ENABLED is 0: when neither network sets a pin or a release, the
# tool prints "no pin" for both and exits 0. At 1 the empty mainnet pin is
# refused, still without a download.
#
# Exit status:
#   0  every set pin is the image of its signed release, or no pin is set
#      (while TN_MAINNET_ENABLED is 0)
#   1  a pin is refused (at TN_MAINNET_ENABLED=1 also an empty or placeholder
#      mainnet pin); "testnet: refused: ..." or "mainnet: refused: ..." on
#      stdout says why, then a summary on stderr
#   2  the check cannot run: a usage error; a missing tool, library function or
#      variable; TN_RELEASE_KEYS_DIR with a published release; no readable
#      release key; a release file that could not be downloaded or read. 2
#      wins over 1.
#
# CI runs it in the "release manifest" job and in publish-installer.yml, before
# an installer is published.
# Maintainer tooling: update-scripts.sh does not track tools/ and this file has
# no .sha256 sidecar. bash 3.2 safe.
# =============================================================================

set -uo pipefail

# The services whose files SHA256SUMS-edge lists: KNOWN_COMPONENTS of
# telcoin-network's etc/release.sh without the node, whose files SHA256SUMS
# lists.
GWPIN_EDGE_COMPONENTS="worker-gateway node-record-api"
# The one target the edge tarballs are built for (TRIPLE, etc/release.sh).
GWPIN_TRIPLE="x86_64-unknown-linux-gnu"
# The limits lib/common.sh sets on a node release's SHA256SUMS and IMAGE_DIGEST.
GWPIN_SUMS_MAX=1048576
GWPIN_DIGEST_MAX=4096
GWPIN_SECS=60

GWPIN_WORK=""

usage() {
    cat <<'EOF'
usage: tools/check-gateway-pin.sh [--gateway-lib FILE] [--release-dir DIR | --base-url URL]

Checks each worker-gateway pin of lib/gateway.sh (testnet, mainnet) against the
signed telcoin-network release recorded beside it. Exit 0 when every set pin is
that release's image (or no pin is set), 1 when a pin is refused, 2 when the
check cannot run.
EOF
}

# cannot MSG -- the check cannot run (startup only).
cannot() {
    printf 'check-gateway-pin: %s\n' "$*" >&2
    exit 2
}

# _gwpin_cleanup -- the EXIT trap: stop any gpg-agent of a network's keyring and
# remove the work directory.
_gwpin_cleanup() {
    local n
    if [ -z "$GWPIN_WORK" ] || [ ! -d "$GWPIN_WORK" ]; then
        return 0
    fi
    for n in testnet mainnet; do
        _tn_release_cleanup "${GWPIN_WORK}/${n}"
    done
    rm -rf -- "$GWPIN_WORK"
}

# TERM, INT and HUP end the run through exit, so the EXIT trap runs: bash 3.2
# skips the EXIT trap of a shell that a signal kills by default when its parent
# shell has one.
trap _gwpin_cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

# Arguments first, so --help and a usage error need no library.
GWPIN_LIB=""
GWPIN_DIR=""
GWPIN_BASE=""
opt_lib=0
opt_dir=0
opt_base=0
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --gateway-lib)
            [ $# -ge 2 ] || cannot "--gateway-lib needs a FILE"
            [ "$opt_lib" -eq 0 ] || cannot "give --gateway-lib once"
            GWPIN_LIB="$2"
            opt_lib=1
            shift
            ;;
        --release-dir)
            [ $# -ge 2 ] || cannot "--release-dir needs a DIR"
            [ "$opt_dir" -eq 0 ] || cannot "give --release-dir once"
            GWPIN_DIR="$2"
            opt_dir=1
            shift
            ;;
        --base-url)
            [ $# -ge 2 ] || cannot "--base-url needs a URL"
            [ "$opt_base" -eq 0 ] || cannot "give --base-url once"
            GWPIN_BASE="$2"
            opt_base=1
            shift
            ;;
        *) printf 'check-gateway-pin: unknown argument %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done
if [ "$opt_dir" -eq 1 ] && [ "$opt_base" -eq 1 ]; then
    cannot "give --release-dir or --base-url, not both"
fi
if [ "$opt_base" -eq 1 ]; then
    case "$GWPIN_BASE" in
        https://?*) GWPIN_BASE="${GWPIN_BASE%/}" ;;
        *) cannot "--base-url ${GWPIN_BASE} is not an https:// URL" ;;
    esac
fi
if [ "$opt_dir" -eq 1 ] && [ ! -d "$GWPIN_DIR" ]; then
    cannot "${GWPIN_DIR} is not a directory"
fi

GWPIN_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" \
    || cannot "could not find the repository this tool is in"
if [ "$opt_lib" -eq 0 ]; then
    GWPIN_LIB="${GWPIN_REPO}/lib/gateway.sh"
fi
# source looks a name without a slash up on PATH first.
case "$GWPIN_LIB" in
    */*) ;;
    *) GWPIN_LIB="./${GWPIN_LIB}" ;;
esac
if [ ! -f "$GWPIN_LIB" ] || [ ! -r "$GWPIN_LIB" ]; then
    cannot "${GWPIN_LIB} is not a readable regular file"
fi

# The signature verdict is the one lib/common.sh gives every release, so a
# change to that rule applies here unedited. Sourced at the top level (bash 3.2
# keeps a readonly array assigned inside a function local to it); it turns on
# -e, which goes back off because every failure below is reported.
# shellcheck source=lib/common.sh
source "${GWPIN_REPO}/lib/common.sh" || cannot "could not load ${GWPIN_REPO}/lib/common.sh"
set +e
for f in _tn_release_keyring _tn_release_sig_ok _tn_release_get _tn_release_cleanup \
    _tn_release_sum _tn_release_keys_dir tn_release_tag_ok tn_release_tag_final \
    tn_release_tag_grammar tn_mainnet_enabled; do
    declare -F "$f" >/dev/null 2>&1 \
        || cannot "lib/common.sh lacks ${f}; this tool runs only with the lib/common.sh beside it"
done
[ -n "${TN_RELEASE_BASE_URL:-}" ] \
    || cannot "lib/common.sh lacks TN_RELEASE_BASE_URL; this tool runs only with the lib/common.sh beside it"

if [ "$opt_dir" -eq 0 ] && [ "$opt_base" -eq 0 ]; then
    GWPIN_BASE="${TN_RELEASE_BASE_URL%/}"
fi
if [ -n "${TN_RELEASE_KEYS_DIR:-}" ] && [ "$opt_dir" -eq 0 ] \
    && [ "$GWPIN_BASE" = "${TN_RELEASE_BASE_URL%/}" ]; then
    cannot "TN_RELEASE_KEYS_DIR names other release keys; a release on ${TN_RELEASE_BASE_URL} is checked only against lib/release-keys (unset it, or give --release-dir)"
fi

# lib/common.sh has sourced the tree's lib/gateway.sh: unset its values, so a
# FILE that lacks one is refused rather than checked with the tree's.
unset GW_RELEASE_IMAGE_REPO GW_TESTNET_IMAGE_PIN GW_TESTNET_PIN_RELEASE \
    GW_MAINNET_IMAGE_PIN GW_MAINNET_PIN_RELEASE
# shellcheck source=lib/gateway.sh
source "$GWPIN_LIB" || cannot "could not load ${GWPIN_LIB}"
set +e
for v in GW_RELEASE_IMAGE_REPO GW_TESTNET_IMAGE_PIN GW_TESTNET_PIN_RELEASE \
    GW_MAINNET_IMAGE_PIN GW_MAINNET_PIN_RELEASE; do
    [ -n "${!v+x}" ] || cannot "${GWPIN_LIB} does not set ${v}"
done
[ -n "$GW_RELEASE_IMAGE_REPO" ] || cannot "${GWPIN_LIB} sets GW_RELEASE_IMAGE_REPO to an empty value"

# Once mainnet is offered an empty mainnet pin is refused, so this shortcut is
# taken only while it is not.
if ! tn_mainnet_enabled \
    && [ -z "${GW_TESTNET_IMAGE_PIN}${GW_TESTNET_PIN_RELEASE}${GW_MAINNET_IMAGE_PIN}${GW_MAINNET_PIN_RELEASE}" ]; then
    printf 'testnet: no pin\nmainnet: no pin\n'
    printf 'check-gateway-pin: no worker-gateway pin is set in %s; nothing to check\n' "$GWPIN_LIB" >&2
    exit 0
fi

for t in gpg gpgv; do
    command -v "$t" >/dev/null 2>&1 || cannot "${t} is not installed; a pin cannot be checked without it"
done
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    cannot "sha256sum (or shasum) is not installed; a pin cannot be checked without it"
fi
if [ "$opt_dir" -eq 0 ]; then
    command -v curl >/dev/null 2>&1 || cannot "curl is not installed; a pin cannot be checked without it"
fi
# macOS sets TMPDIR with a trailing slash; strip it so no path holds "//".
gwpin_tmp="${TMPDIR:-/tmp}"
GWPIN_WORK="$(mktemp -d "${gwpin_tmp%/}/check-gateway-pin.XXXXXX")" \
    || cannot "could not make a work directory under ${gwpin_tmp%/}"

# _gwpin_sha256 FILE -- FILE's sha256 in hex: sha256sum, or shasum on macOS.
_gwpin_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum < "$1"
    else
        shasum -a 256 < "$1"
    fi | awk '{ print $1 }'
}

# _gwpin_get REL NAME OUT MAX -- release REL's file NAME into OUT: from
# DIR/REL/NAME offline, else downloaded from <URL>/REL/NAME (at most MAX bytes).
# rc 2 when the file cannot be had, with the reason on stdout.
_gwpin_get() {
    local rel="$1" name="$2" out="$3" max="$4" src
    if [ "$opt_dir" -eq 1 ]; then
        src="${GWPIN_DIR}/${rel}/${name}"
        if [ ! -f "$src" ] || [ -L "$src" ]; then
            printf '%s is not a regular file\n' "$src"
            return 2
        fi
        if ! cp -- "$src" "$out" 2>/dev/null; then
            printf 'could not read %s\n' "$src"
            return 2
        fi
        return 0
    fi
    if ! _tn_release_get "${GWPIN_BASE}/${rel}/${name}" "$out" "$max" "$GWPIN_SECS"; then
        printf 'could not download %s/%s/%s (the release may not exist or may not ship the worker gateway, or the download failed)\n' \
            "$GWPIN_BASE" "$rel" "$name"
        return 2
    fi
    return 0
}

# _gwpin_image_ok IMAGE -- rc 0 when IMAGE is
# GW_RELEASE_IMAGE_REPO@sha256:<64 lowercase hex>. A prefix comparison, not
# gw_image_allowed: a dry-run release names a registry by host:port.
_gwpin_image_ok() {
    local hex re='^[0123456789abcdef]{64}$'
    case "$1" in
        "${GW_RELEASE_IMAGE_REPO}@sha256:"*) ;;
        *) return 1 ;;
    esac
    hex="${1#"${GW_RELEASE_IMAGE_REPO}@sha256:"}"
    [[ "$hex" =~ $re ]]
}

# _gwpin_edge_shape FILE TAG -- rc 0 when FILE (SHA256SUMS-edge) is the edge
# manifest of release TAG: "<64 hex>  <name>" lines, each name once, each
# IMAGE_DIGEST-<service> or <service>-TAG-<triple>.tar.gz of an edge service,
# both or neither for each service, the worker gateway's present. The same
# keys sign every release's manifests, so only the tag in the tarball names
# ties a good signature to TAG. Order is not checked. Prints the reason on rc 1.
_gwpin_edge_shape() {
    local f="$1" tag="$2" line name c known seen=" " dig tar hd ht re
    re='^[0123456789abcdef]{64}  [ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/-]+$'
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ ! "$line" =~ $re ]]; then
            printf 'malformed line in SHA256SUMS-edge\n'
            return 1
        fi
        name="${line#*  }"
        case "$seen" in
            *" ${name} "*) printf 'SHA256SUMS-edge names %s twice\n' "$name"; return 1 ;;
        esac
        seen="${seen}${name} "
        known=0
        for c in $GWPIN_EDGE_COMPONENTS; do
            if [ "$name" = "IMAGE_DIGEST-${c}" ] || [ "$name" = "${c}-${tag}-${GWPIN_TRIPLE}.tar.gz" ]; then
                known=1
            fi
        done
        if [ "$known" -ne 1 ]; then
            printf 'SHA256SUMS-edge names %s, which is not an edge file of %s\n' "$name" "$tag"
            return 1
        fi
    done < "$f"
    for c in $GWPIN_EDGE_COMPONENTS; do
        dig="IMAGE_DIGEST-${c}"
        tar="${c}-${tag}-${GWPIN_TRIPLE}.tar.gz"
        hd=0
        ht=0
        case "$seen" in *" ${dig} "*) hd=1 ;; esac
        case "$seen" in *" ${tar} "*) ht=1 ;; esac
        if [ "$hd" -eq 1 ] && [ "$ht" -eq 0 ]; then
            printf 'SHA256SUMS-edge lists %s without %s\n' "$dig" "$tar"
            return 1
        fi
        if [ "$hd" -eq 0 ] && [ "$ht" -eq 1 ]; then
            printf 'SHA256SUMS-edge lists %s without %s\n' "$tar" "$dig"
            return 1
        fi
    done
    case "$seen" in
        *" IMAGE_DIGEST-worker-gateway "*) ;;
        *)
            printf 'SHA256SUMS-edge does not list the worker gateway (IMAGE_DIGEST-worker-gateway and worker-gateway-%s-%s.tar.gz)\n' \
                "$tag" "$GWPIN_TRIPLE"
            return 1
            ;;
    esac
    return 0
}

# _gwpin_sig_why VERDICT -- the reason for a refusing _tn_release_sig_ok line,
# worded as _tn_release_open words it for SHA256SUMS.
_gwpin_sig_why() {
    local ids=""
    case "$1" in
        *" "*) ids="${1#* }" ;;
    esac
    case "${1%% *}" in
        BADSIG) printf 'a signature does not match SHA256SUMS-edge (BADSIG)\n' ;;
        EXPKEYSIG) printf 'a signature was made by an expired key (EXPKEYSIG)\n' ;;
        REVKEYSIG) printf 'a signature was made by a revoked key (REVKEYSIG)\n' ;;
        EXPSIG) printf 'a signature has expired (EXPSIG)\n' ;;
        ERRSIG) printf 'a signature could not be checked (ERRSIG)\n' ;;
        *)
            if [ -n "$ids" ]; then
                printf 'no good signature by a key in %s; it is signed only by key %s, which is not there\n' \
                    "$(_tn_release_keys_dir)" "$ids"
            else
                printf 'no good signature by a key in %s\n' "$(_tn_release_keys_dir)"
            fi
            ;;
    esac
}

# _gwpin_check NET PIN REL -- check NET's pin PIN against release REL and print
# NET's lines. rc 0 ok or no pin, 1 refused, 2 the check cannot run.
_gwpin_check() {
    local net="$1" pin="$2" rel="$3" up d keys why v sigrc ids want got n line
    case "$net" in
        testnet) up="TESTNET" ;;
        *) up="MAINNET" ;;
    esac
    if [ -z "$pin" ] && [ -z "$rel" ]; then
        if [ "$net" = mainnet ] && tn_mainnet_enabled; then
            printf '%s: refused: GW_%s_IMAGE_PIN and GW_%s_PIN_RELEASE are empty, but this scripts release offers mainnet (TN_MAINNET_ENABLED=1); pin the worker-gateway image of a signed mainnet release\n' \
                "$net" "$up" "$up"
            return 1
        fi
        printf '%s: no pin\n' "$net"
        return 0
    fi
    if [ -z "$pin" ]; then
        printf '%s: refused: GW_%s_PIN_RELEASE is %s but GW_%s_IMAGE_PIN is empty; set both or neither\n' \
            "$net" "$up" "$rel" "$up"
        return 1
    fi
    if [ -z "$rel" ]; then
        printf '%s: refused: GW_%s_IMAGE_PIN is set but GW_%s_PIN_RELEASE is empty; record the telcoin-network release the pin comes from\n' \
            "$net" "$up" "$up"
        return 1
    fi
    # The tag check comes before any path or URL is built from REL.
    if [ "$net" = mainnet ] && tn_release_tag_final testnet "$rel"; then
        if tn_mainnet_enabled; then
            printf '%s: refused: GW_%s_PIN_RELEASE %s is a testnet release, the placeholder taken only while TN_MAINNET_ENABLED is 0, but this scripts release offers mainnet (TN_MAINNET_ENABLED=1); bump the pin to the worker-gateway image of a signed mainnet release\n' \
                "$net" "$up" "$rel"
            return 1
        fi
        printf '%s: note: placeholder: GW_%s_PIN_RELEASE %s is a testnet release, standing in for mainnet while TN_MAINNET_ENABLED is 0; the release that offers mainnet must pin a mainnet release\n' \
            "$net" "$up" "$rel"
    elif ! tn_release_tag_ok "$net" "$rel"; then
        printf '%s: refused: GW_%s_PIN_RELEASE %s is not a %s release tag (%s)\n' \
            "$net" "$up" "$rel" "$net" "$(tn_release_tag_grammar)"
        return 1
    fi
    if ! _gwpin_image_ok "$pin"; then
        printf '%s: refused: GW_%s_IMAGE_PIN %s is not GW_RELEASE_IMAGE_REPO@sha256:<64 lowercase hex>\n' \
            "$net" "$up" "$pin"
        return 1
    fi

    d="${GWPIN_WORK}/${net}"
    keys="$(_tn_release_keys_dir)"
    _tn_release_keyring "$d"
    case $? in
        0) ;;
        1) printf '%s: cannot check: no release key in %s (*.asc)\n' "$net" "$keys"; return 2 ;;
        *) printf '%s: cannot check: could not read the release keys in %s\n' "$net" "$keys"; return 2 ;;
    esac
    # _tn_release_sig_ok reads DIR/SHA256SUMS and DIR/SHA256SUMS.asc; gpgv does
    # not care what the files are called.
    if ! why="$(_gwpin_get "$rel" SHA256SUMS-edge "${d}/SHA256SUMS" "$GWPIN_SUMS_MAX")" \
        || ! why="$(_gwpin_get "$rel" SHA256SUMS-edge.asc "${d}/SHA256SUMS.asc" "$GWPIN_SUMS_MAX")"; then
        printf '%s: cannot check: %s\n' "$net" "$why"
        return 2
    fi

    v="$(_tn_release_sig_ok "$d")"
    sigrc=$?
    if [ "$sigrc" -ne 0 ]; then
        printf '%s: refused: telcoin-network %s: SHA256SUMS-edge is not verified: %s\n' \
            "$net" "$rel" "$(_gwpin_sig_why "$v")"
        return 1
    fi
    ids=""
    case "$v" in
        *" "*) ids="${v#* }" ;;
    esac
    if [ -n "$ids" ]; then
        printf '%s: note: SHA256SUMS-edge.asc of %s also carries a signature by key %s, which is not in %s; it was not checked\n' \
            "$net" "$rel" "$ids" "$keys"
    fi

    if ! why="$(_gwpin_edge_shape "${d}/SHA256SUMS" "$rel")"; then
        printf '%s: refused: telcoin-network %s: %s\n' "$net" "$rel" "$why"
        return 1
    fi

    # The image is read only from the file whose hash the verified manifest
    # lists.
    if ! why="$(_gwpin_get "$rel" IMAGE_DIGEST-worker-gateway "${d}/IMAGE_DIGEST-worker-gateway" "$GWPIN_DIGEST_MAX")"; then
        printf '%s: cannot check: %s\n' "$net" "$why"
        return 2
    fi
    want="$(_tn_release_sum "${d}/SHA256SUMS" IMAGE_DIGEST-worker-gateway)"
    if ! got="$(_gwpin_sha256 "${d}/IMAGE_DIGEST-worker-gateway")" || [ -z "$got" ]; then
        printf '%s: cannot check: could not hash IMAGE_DIGEST-worker-gateway of %s\n' "$net" "$rel"
        return 2
    fi
    if [ -z "$want" ] || [ "$want" != "$got" ]; then
        printf '%s: refused: telcoin-network %s: IMAGE_DIGEST-worker-gateway does not match its SHA256SUMS-edge line\n' \
            "$net" "$rel"
        return 1
    fi
    n="$(awk 'END { print NR }' "${d}/IMAGE_DIGEST-worker-gateway")"
    if [ "$n" != "1" ]; then
        printf '%s: refused: telcoin-network %s: IMAGE_DIGEST-worker-gateway holds %s lines, not one\n' \
            "$net" "$rel" "$n"
        return 1
    fi
    line="$(cat "${d}/IMAGE_DIGEST-worker-gateway")"
    if ! _gwpin_image_ok "$line"; then
        # Printable ASCII spelled as a byte range: busybox tr has no [:print:].
        printf '%s: refused: telcoin-network %s: IMAGE_DIGEST-worker-gateway names %s, not an image in GW_RELEASE_IMAGE_REPO by digest\n' \
            "$net" "$rel" "$(printf '%s' "$line" | LC_ALL=C tr -c ' -~' '?')"
        return 1
    fi
    if [ "$line" != "$pin" ]; then
        printf '%s: refused: GW_%s_IMAGE_PIN is %s, but telcoin-network %s publishes %s\n' \
            "$net" "$up" "$pin" "$rel" "$line"
        return 1
    fi
    printf '%s: ok: GW_%s_IMAGE_PIN is the worker-gateway image of telcoin-network %s (%s); SHA256SUMS-edge.asc verifies against %s\n' \
        "$net" "$up" "$rel" "$pin" "$keys"
    return 0
}

refused=0
failed=0
for net in testnet mainnet; do
    case "$net" in
        testnet) _gwpin_check testnet "$GW_TESTNET_IMAGE_PIN" "$GW_TESTNET_PIN_RELEASE" ;;
        *) _gwpin_check mainnet "$GW_MAINNET_IMAGE_PIN" "$GW_MAINNET_PIN_RELEASE" ;;
    esac
    case $? in
        0) ;;
        1) refused=$((refused + 1)) ;;
        *) failed=$((failed + 1)) ;;
    esac
done

if [ "$failed" -gt 0 ]; then
    printf 'check-gateway-pin: %s worker-gateway pin(s) could not be checked\n' "$failed" >&2
    exit 2
fi
if [ "$refused" -gt 0 ]; then
    printf 'check-gateway-pin: %s worker-gateway pin(s) refused; correct the pin and its release in %s (one line per network)\n' \
        "$refused" "$GWPIN_LIB" >&2
    exit 1
fi
printf 'check-gateway-pin: every worker-gateway pin set in %s is the image of its signed telcoin-network release\n' \
    "$GWPIN_LIB" >&2
exit 0
