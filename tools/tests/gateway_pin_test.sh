#!/usr/bin/env bash
# =============================================================================
# tools/tests/gateway_pin_test.sh -- tools/check-gateway-pin.sh, which checks
# each worker-gateway pin of lib/gateway.sh against the signed telcoin-network
# release recorded beside it, and the pin contract of lib/gateway.sh that the
# tool and gw_image_allowed share.
#
#   bash tools/tests/run.sh tools/tests/gateway_pin_test.sh
#   docker run --rm --network none -v "$PWD:/w:ro" -w /w bash:3.2 bash tools/tests/run.sh tools/tests/gateway_pin_test.sh
#   docker run --rm --network none -v "$PWD:/w:ro" -w /w ubuntu:24.04 bash tools/tests/run.sh tools/tests/gateway_pin_test.sh
#
# Two layers. The real layer runs the tool on tools/tests/gateway-pin.d, a
# release that a dry run of telcoin-network's etc/release.sh wrote and signed
# with a throwaway key (see its README): that release under its own key, the
# same release under other keys, and the dry run's node manifest in place of
# the edge manifest. It needs real gpg (REAL_GPG of tools/tests/signing.sh), so
# without it, or once the throwaway key has expired, those cases SKIP. The
# synthetic layer copies the same release files and signs SHA256SUMS-edge with
# keys made here, by real gpg where it works and by the stand-ins of signing.sh
# elsewhere, so it runs in every environment. The tool reads the keys through
# TN_RELEASE_KEYS_DIR with --release-dir, or with --base-url
# https://fixture.invalid, which a curl shim serves from $T/srv and logs.
#
# Cases: empty pins (nothing downloaded) and the tree's own pins; a matching
# pin offline and through the download path, a release that ships only the
# worker gateway, a good signature beside an unknown one; a wrong digest; a pin
# or a digest file outside GW_RELEASE_IMAGE_REPO; no signature, no .asc,
# BADSIG, a manifest changed after signing, a key that is not listed, an
# expired and a revoked key; a manifest with an extra, a missing or a malformed
# line, CRLF, a blank line, a name twice, no worker gateway, node files; a
# digest file that does not match its line, of two lines, with a control byte,
# missing or a symlink; a tag other than the manifest's, of the other network,
# of devnet, a mainnet release candidate, a pin or a release set alone; both
# networks at once, and 2 over 1; the interface (option conflicts, http,
# TN_RELEASE_KEYS_DIR with a published release, a FILE that lacks a variable,
# an unknown option, --help); no work dir left behind; the static contract of
# lib/gateway.sh (the release package, the devnet list, one line per pin and
# release under its network-gated marker) and _gw_pin_ok refusing what the
# tool refuses.
#
# Maintainer tooling (not updater-tracked, no sidecar). bash 3.2 safe.
# =============================================================================
set -u
# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T="$TN_TEST_TMP"
BIN="$T/bin"
mkdir -p "$BIN" "$T/tmp" "$T/srv"
# shellcheck source=tools/tests/signing.sh
. "${TN_TEST_DIR}/signing.sh"
# Release keys come only from the directory each run names.
unset TN_RELEASE_KEYS_DIR
eval "$(tn_test_source_common)"

TOOL="${TN_TEST_REPO}/tools/check-gateway-pin.sh"
FIXD="${TN_TEST_DIR}/gateway-pin.d"
GWLIB="${TN_TEST_REPO}/lib/gateway.sh"
TRIPLE="x86_64-unknown-linux-gnu"

# The tree's pins, before any case could touch them.
TREE_PINS="${GW_TESTNET_IMAGE_PIN}${GW_TESTNET_PIN_RELEASE}${GW_MAINNET_IMAGE_PIN}${GW_MAINNET_PIN_RELEASE}"

# --- curl shim --------------------------------------------------------------------
export GWT_SRV="$T/srv" GWT_CURL_LOG="$T/curl.log"
cat > "$BIN/curl" <<'SH'
#!/bin/sh
# curl: serves https://fixture.invalid/<path> from $GWT_SRV/<path>, logs proto and url
out=""; url=""; proto=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --url) url="$2"; shift 2 ;;
        --proto) proto="$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s %s\n' "$proto" "$url" >> "$GWT_CURL_LOG"
[ "$proto" = "=https" ] || exit 1
case "$url" in
    https://fixture.invalid/*) src="$GWT_SRV/${url#https://fixture.invalid/}" ;;
    *) exit 6 ;;
esac
[ -f "$src" ] || exit 22
cat "$src" > "$out"
SH
chmod 0755 "$BIN/curl"

# --- helpers ----------------------------------------------------------------------
# _h FILE -- FILE's sha256 in hex.
_h() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum < "$1"
    else
        shasum -a 256 < "$1"
    fi | awk '{ print $1 }'
}

# yn CMD... -- "yes" when CMD succeeds, else "no".
yn() { if "$@"; then echo yes; else echo no; fi; }

# says NAME NEEDLE TEXT -- TEXT contains NEEDLE; on failure the diff shows TEXT.
says() {
    case "$3" in
        *"$2"*) check "$1" "$2" "$2" ;;
        *) check "$1" "... $2 ..." "$3" ;;
    esac
}

# gp KEYS ARG... -- run the tool under this bash with TMPDIR=$T/tmp and
# TN_RELEASE_KEYS_DIR=KEYS (- leaves it unset). Sets RC, OUT (stdout), ERR
# (stderr) and LOG (what the curl shim fetched in this run).
gp() {
    local kd="$1"
    shift
    : > "$T/curl.log"
    RC=0
    if [ "$kd" = - ]; then
        OUT="$(TMPDIR="$T/tmp" "${BASH:-bash}" "$TOOL" "$@" 2>"$T/err")" || RC=$?
    else
        OUT="$(TN_RELEASE_KEYS_DIR="$kd" TMPDIR="$T/tmp" "${BASH:-bash}" "$TOOL" "$@" 2>"$T/err")" || RC=$?
    fi
    ERR="$(cat "$T/err")"
    LOG="$(cat "$T/curl.log")"
}

# expect NAME RC NEEDLE... -- the last run exited RC, and its stdout or stderr
# holds each NEEDLE.
expect() {
    local name="$1" want="$2" n i=0
    shift 2
    check_rc "$name: rc $want" "$want" "$RC"
    for n in "$@"; do
        i=$((i + 1))
        says "$name: message ${i} of $#" "$n" "$OUT
$ERR"
    done
}

# pins FILE REPO TPIN TREL MPIN MREL -- a --gateway-lib FILE that holds only the
# five assignments, the pins on lib/gateway.sh's one-line form.
pins() {
    printf 'GW_RELEASE_IMAGE_REPO="%s"\nGW_TESTNET_IMAGE_PIN="%s" GW_TESTNET_PIN_RELEASE="%s"\nGW_MAINNET_IMAGE_PIN="%s" GW_MAINNET_PIN_RELEASE="%s"\n' \
        "$2" "$3" "$4" "$5" "$6" > "$1"
}

# fpins FILE PIN REL -- the fixture network pins PIN from release REL in FREPO;
# the other network pins nothing.
fpins() {
    if [ "$FNET" = testnet ]; then
        pins "$1" "$FREPO" "$2" "$3" "" ""
    else
        pins "$1" "$FREPO" "" "" "$2" "$3"
    fi
}

# --- the fixture ------------------------------------------------------------------
# A missing fixture is a failure: the synthetic layer is built from it too.
fix_ok=1
n=0
FTAG=""
for d in "$FIXD"/release/*; do
    [ -d "$d" ] || continue
    n=$((n + 1))
    FTAG="${d##*/}"
done
check "fixture: one release directory under gateway-pin.d/release" 1 "$n" || fix_ok=0
miss=""
for f in keys/rehearsal.asc node/SHA256SUMS node/SHA256SUMS.asc \
    "release/${FTAG}/SHA256SUMS-edge" "release/${FTAG}/SHA256SUMS-edge.asc" \
    "release/${FTAG}/IMAGE_DIGEST-worker-gateway" "release/${FTAG}/IMAGE_DIGEST-node-record-api"; do
    [ -f "$FIXD/$f" ] || miss="${miss} ${f}"
done
check "fixture: every file is present" "" "$miss" || fix_ok=0
FNET=""
ONET=""
if tn_release_tag_ok testnet "$FTAG"; then
    FNET=testnet ONET=mainnet
elif tn_release_tag_ok mainnet "$FTAG"; then
    FNET=mainnet ONET=testnet
fi
check "fixture: ${FTAG} is a testnet or a mainnet release tag" yes "$(yn [ -n "$FNET" ])" || fix_ok=0
[ "$fix_ok" -eq 1 ] || finish

FLINE="$(cat "$FIXD/release/${FTAG}/IMAGE_DIGEST-worker-gateway")"
FREPO="${FLINE%@sha256:*}"
FHEX="${FLINE##*@sha256:}"
re='^[0123456789abcdef]{64}$'
v=no
if [[ "$FHEX" =~ $re && "$FREPO" != "$FLINE" ]]; then
    v=yes
fi
check "fixture: IMAGE_DIGEST-worker-gateway is one image by digest" yes "$v" || finish
# FUP is the fixture network's name in the variable names, OTAG a release of
# that network other than the fixture's, XTAG a tag of the other network's form.
if [ "$FNET" = testnet ]; then
    FUP=TESTNET OTAG="v99.0.0-adiri" XTAG="v1.0.0"
else
    FUP=MAINNET OTAG="v99.0.0" XTAG="v1.0.0-adiri"
fi
NRTAR="node-record-api-${FTAG}-${TRIPLE}.tar.gz"
WGTAR="worker-gateway-${FTAG}-${TRIPLE}.tar.gz"
ZPIN="${FREPO}@sha256:$(printf '%064d' 0)"

# --- keys -------------------------------------------------------------------------
newkey good >/dev/null
newkey stranger >/dev/null
newkey old --expired >/dev/null
newkey gone --revoked >/dev/null
for k in good stranger old gone; do
    mkdir -p "$T/k-$k"
    cp "$T/$k.asc" "$T/k-$k/$k.asc"
done
mkdir -p "$T/k-reh"
cp "$FIXD/keys/rehearsal.asc" "$T/k-reh/rehearsal.asc"
# A key that is not in the keyring is named by its long key id.
SID="$(fpr_of stranger)"
SID="${SID:24}"

# --- the synthetic release ----------------------------------------------------------
# $T/rel/FTAG: the four fixture release files, SHA256SUMS-edge.asc made by good.
mkdir -p "$T/rel/${FTAG}"
cp "$FIXD/release/${FTAG}/"* "$T/rel/${FTAG}/"
sign_file "$T/rel/${FTAG}/SHA256SUMS-edge" good
# A case changes a copy: C is its --release-dir and CR its release.
C="$T/c"
CR="$C/${FTAG}"
fresh() {
    rm -rf "$C"
    mkdir -p "$C"
    cp -R "$T/rel/${FTAG}" "$C/"
}
# sums AWK-PROGRAM [VAR=VALUE...] -- rewrite CR's SHA256SUMS-edge through awk.
sums() {
    local prog="$1" a
    local -a vs
    shift
    vs=()
    for a in "$@"; do
        vs+=(-v "$a")
    done
    awk ${vs[@]+"${vs[@]}"} "$prog" "$CR/SHA256SUMS-edge" > "$T/sums.tmp" \
        && cat "$T/sums.tmp" > "$CR/SHA256SUMS-edge"
}
# drop NAME -- remove NAME's line from CR's SHA256SUMS-edge.
drop() { sums 'substr($0, 67) != n' "n=$1"; }
# fixline NAME -- NAME's SHA256SUMS-edge line takes the hash of CR/NAME.
fixline() { sums 'substr($0, 67) == n { $0 = h "  " n } { print }' "n=$1" "h=$(_h "$CR/$1")"; }
resign() { sign_file "$CR/SHA256SUMS-edge" good; }
# runc -- the fixture network's pin is FLINE from FTAG, checked against C.
PF="$T/p-ok"
fpins "$PF" "$FLINE" "$FTAG"
runc() { gp "$T/k-good" --gateway-lib "$PF" --release-dir "$C"; }

OKLINE="${FNET}: ok: GW_${FUP}_IMAGE_PIN is the worker-gateway image of telcoin-network ${FTAG} (${FLINE}); SHA256SUMS-edge.asc verifies against"
NOPIN="testnet: no pin
mainnet: no pin"

# =============================================================================
# empty pins
# =============================================================================
pins "$T/p-empty" "$FREPO" "" "" "" ""
gp - --gateway-lib "$T/p-empty"
check_rc "empty pins: rc 0 and one 'no pin' line per network" 0 "$RC"
check "empty pins: stdout is one 'no pin' line per network, testnet first" "$NOPIN" "$OUT"
says "empty pins: stderr says there is nothing to check" \
    "check-gateway-pin: no worker-gateway pin is set in $T/p-empty; nothing to check" "$ERR"

gp - --gateway-lib "$T/p-empty" --base-url https://fixture.invalid
check_rc "empty pins: nothing downloaded: rc 0" 0 "$RC"
check "empty pins: nothing downloaded: stdout" "$NOPIN" "$OUT"
check "empty pins: nothing downloaded" "" "$LOG"

if [ -z "$TREE_PINS" ]; then
    gp -
    check_rc "the tree's pins pass" 0 "$RC"
    check "the tree's pins pass: no pin on either network" "$NOPIN" "$OUT"
    check "the tree's pins pass: nothing downloaded" "" "$LOG"
else
    skip "the tree's pins pass" "the tree pins an image: the release manifest CI step checks it against the real release"
fi

# =============================================================================
# accepts
# =============================================================================
gp "$T/k-good" --gateway-lib "$PF" --release-dir "$T/rel"
expect "accepts a matching pin (synthetic, offline)" 0 "${OKLINE} $T/k-good" "${ONET}: no pin"
if [ "$FNET" = testnet ]; then
    want="${OKLINE} $T/k-good
mainnet: no pin"
else
    want="testnet: no pin
${OKLINE} $T/k-good"
fi
check "accepts a matching pin (synthetic, offline): stdout, testnet first" "$want" "$OUT"
check "accepts a matching pin (synthetic, offline): the summary" \
    "check-gateway-pin: every worker-gateway pin set in $PF is the image of its signed telcoin-network release" "$ERR"

rm -rf "$T/srv"
mkdir -p "$T/srv"
cp -R "$T/rel/${FTAG}" "$T/srv/"
DL="=https https://fixture.invalid/${FTAG}/SHA256SUMS-edge
=https https://fixture.invalid/${FTAG}/SHA256SUMS-edge.asc
=https https://fixture.invalid/${FTAG}/IMAGE_DIGEST-worker-gateway"
gp "$T/k-good" --gateway-lib "$PF" --base-url https://fixture.invalid
expect "accepts a matching pin (download path)" 0 "${OKLINE} $T/k-good"
check "accepts a matching pin (download path): three downloads over https, in order" "$DL" "$LOG"
gp "$T/k-good" --gateway-lib "$PF" --base-url https://fixture.invalid/
expect "accepts a matching pin (download path, a trailing / on the URL)" 0 "${OKLINE} $T/k-good"
check "accepts a matching pin (download path, a trailing / on the URL): the same three URLs" "$DL" "$LOG"
fpins "$T/p-otag" "$FLINE" "$OTAG"
gp "$T/k-good" --gateway-lib "$T/p-otag" --base-url https://fixture.invalid
expect "cannot check a release that is not published (download path)" 2 \
    "${FNET}: cannot check: could not download https://fixture.invalid/${OTAG}/SHA256SUMS-edge (the release may not exist or may not ship the worker gateway, or the download failed)" \
    "check-gateway-pin: 1 worker-gateway pin(s) could not be checked"

fresh
drop "IMAGE_DIGEST-node-record-api"
drop "$NRTAR"
resign
runc
expect "accepts a release that ships only the worker gateway" 0 "${OKLINE} $T/k-good"

fresh
sign_file "$CR/SHA256SUMS-edge" good stranger
runc
expect "a good signature beside an unknown co-signer is taken, with a note" 0 \
    "${FNET}: note: SHA256SUMS-edge.asc of ${FTAG} also carries a signature by key ${SID}, which is not in $T/k-good; it was not checked" \
    "${OKLINE} $T/k-good"

# =============================================================================
# real signature (the dry run's own release and key)
# =============================================================================
REAL_CASES="R1 accepts the rehearsal release under its own signature
R2 refuses the rehearsal signature under other keys
R3 refuses the node's real signed manifest in place of the edge manifest"
real_why=""
if [ "$REAL_GPG" -ne 1 ]; then
    real_why="needs real gpg: the stand-in cannot read the throwaway key of gateway-pin.d"
else
    reh="$(gpg --batch --no-tty --with-colons --import-options show-only --import < "$FIXD/keys/rehearsal.asc" 2>/dev/null)"
    RID="$(awk -F: '$1 == "pub" { print $5; exit }' <<< "$reh")"
    exp="$(awk -F: '$1 == "pub" { print $7; exit }' <<< "$reh")"
    if [ -n "$exp" ] && [ "$exp" -le "$(date +%s)" ]; then
        when="$(date -u -d "@${exp}" +%Y-%m-%d 2>/dev/null || date -u -r "$exp" +%Y-%m-%d 2>/dev/null || printf '%s' "$exp")"
        real_why="the rehearsal key expired on ${when}; refresh tools/tests/gateway-pin.d"
    fi
fi
if [ -n "$real_why" ]; then
    while IFS= read -r c; do
        skip "$c" "$real_why"
    done <<< "$REAL_CASES"
else
    check "R: the rehearsal key has a key id" yes "$(yn [ -n "$RID" ])"
    gp "$T/k-reh" --gateway-lib "$PF" --release-dir "$FIXD/release"
    expect "R1 accepts the rehearsal release under its own signature" 0 "${OKLINE} $T/k-reh"
    check_lacks "R1: no note (one signature, by a listed key)" "note:" "$OUT"

    gp "$T/k-good" --gateway-lib "$PF" --release-dir "$FIXD/release"
    expect "R2 refuses the rehearsal signature under other keys" 1 \
        "${FNET}: refused: telcoin-network ${FTAG}: SHA256SUMS-edge is not verified: no good signature by a key in $T/k-good; it is signed only by key ${RID}, which is not there"

    rm -rf "$T/r3"
    mkdir -p "$T/r3/${FTAG}"
    cp "$FIXD/node/SHA256SUMS" "$T/r3/${FTAG}/SHA256SUMS-edge"
    cp "$FIXD/node/SHA256SUMS.asc" "$T/r3/${FTAG}/SHA256SUMS-edge.asc"
    cp "$FIXD/release/${FTAG}/IMAGE_DIGEST-worker-gateway" "$T/r3/${FTAG}/"
    gp "$T/k-reh" --gateway-lib "$PF" --release-dir "$T/r3"
    expect "R3 refuses the node's real signed manifest in place of the edge manifest" 1 \
        "${FNET}: refused: telcoin-network ${FTAG}: SHA256SUMS-edge names IMAGE_DIGEST, which is not an edge file of ${FTAG}"
    check_lacks "R3: the signature itself verifies" "not verified" "$OUT"
fi

# =============================================================================
# wrong digest
# =============================================================================
fpins "$T/p-zero" "$ZPIN" "$FTAG"
gp "$T/k-good" --gateway-lib "$T/p-zero" --release-dir "$T/rel"
expect "refuses a wrong digest" 1 \
    "${FNET}: refused: GW_${FUP}_IMAGE_PIN is ${ZPIN}, but telcoin-network ${FTAG} publishes ${FLINE}" \
    "check-gateway-pin: 1 worker-gateway pin(s) refused; correct the pin and its release in $T/p-zero (one line per network)"

# =============================================================================
# wrong repository
# =============================================================================
fpins "$T/p-dev" "${TN_DEV_IMAGE_REPO}@sha256:${FHEX}" "$FTAG"
gp "$T/k-good" --gateway-lib "$T/p-dev" --base-url https://fixture.invalid
expect "refuses a pin outside GW_RELEASE_IMAGE_REPO, before any download" 1 \
    "${FNET}: refused: GW_${FUP}_IMAGE_PIN ${TN_DEV_IMAGE_REPO}@sha256:${FHEX} is not GW_RELEASE_IMAGE_REPO@sha256:<64 lowercase hex>"
check "refuses a pin outside GW_RELEASE_IMAGE_REPO, before any download: nothing downloaded" "" "$LOG"

fresh
printf '%s\n' "ghcr.io/telcoin-association/tn-testnet@sha256:${FHEX}" > "$CR/IMAGE_DIGEST-worker-gateway"
fixline IMAGE_DIGEST-worker-gateway
resign
runc
expect "refuses a release whose digest file names another repository" 1 \
    "${FNET}: refused: telcoin-network ${FTAG}: IMAGE_DIGEST-worker-gateway names ghcr.io/telcoin-association/tn-testnet@sha256:${FHEX}, not an image in GW_RELEASE_IMAGE_REPO by digest"

fresh
printf '%s\033\n' "$FLINE" > "$CR/IMAGE_DIGEST-worker-gateway"
fixline IMAGE_DIGEST-worker-gateway
resign
runc
expect "a digest line with a control byte is refused and shown with ? in its place" 1 \
    "${FNET}: refused: telcoin-network ${FTAG}: IMAGE_DIGEST-worker-gateway names ${FLINE}?, not an image in GW_RELEASE_IMAGE_REPO by digest"
check_lacks "a digest line with a control byte: the byte is not printed" "$(printf '\033')" "$OUT"

# =============================================================================
# signature
# =============================================================================
fresh
: > "$CR/SHA256SUMS-edge.asc"
runc
expect "refuses an unsigned manifest" 1 \
    "${FNET}: refused: telcoin-network ${FTAG}: SHA256SUMS-edge is not verified: no good signature by a key in $T/k-good"
check_lacks "refuses an unsigned manifest: no key is named" "signed only by key" "$OUT"

fresh
rm -f "$CR/SHA256SUMS-edge.asc"
runc
expect "cannot check without SHA256SUMS-edge.asc" 2 \
    "${FNET}: cannot check: ${CR}/SHA256SUMS-edge.asc is not a regular file" \
    "check-gateway-pin: 1 worker-gateway pin(s) could not be checked"

fresh
sign_file "$CR/SHA256SUMS-edge" good
sign_file_bad "$CR/SHA256SUMS-edge" good
runc
expect "refuses a BADSIG beside a good signature" 1 \
    "${FNET}: refused: telcoin-network ${FTAG}: SHA256SUMS-edge is not verified: a signature does not match SHA256SUMS-edge (BADSIG)"

fresh
sums 'substr($0, 67) == n { c = substr($0, 1, 1); $0 = (c == "0" ? "1" : "0") substr($0, 2) } { print }' "n=$NRTAR"
runc
expect "refuses a manifest changed after signing" 1 \
    "SHA256SUMS-edge is not verified: a signature does not match SHA256SUMS-edge (BADSIG)"

fresh
sign_file "$CR/SHA256SUMS-edge" stranger
runc
expect "refuses a signature by a key that is not listed" 1 \
    "${FNET}: refused: telcoin-network ${FTAG}: SHA256SUMS-edge is not verified: no good signature by a key in $T/k-good; it is signed only by key ${SID}, which is not there"

fresh
sign_file "$CR/SHA256SUMS-edge" old
gp "$T/k-old" --gateway-lib "$PF" --release-dir "$C"
expect "refuses an expired key" 1 \
    "SHA256SUMS-edge is not verified: a signature was made by an expired key (EXPKEYSIG)"

fresh
sign_file "$CR/SHA256SUMS-edge" gone
gp "$T/k-gone" --gateway-lib "$PF" --release-dir "$C"
expect "refuses a revoked key" 1 \
    "SHA256SUMS-edge is not verified: a signature was made by a revoked key (REVKEYSIG)"

mkdir -p "$T/k-none"
gp "$T/k-none" --gateway-lib "$PF" --release-dir "$T/rel"
expect "cannot check without a release key" 2 "${FNET}: cannot check: no release key in $T/k-none (*.asc)"

# =============================================================================
# wrong shape (each re-signed by good)
# =============================================================================
REFUSED="${FNET}: refused: telcoin-network ${FTAG}: SHA256SUMS-edge"

fresh
printf '%s  extra.txt\n' "$(printf '%064d' 0 | tr 0 e)" >> "$CR/SHA256SUMS-edge"
resign
runc
expect "refuses an extra line" 1 "${REFUSED} names extra.txt, which is not an edge file of ${FTAG}"

fresh
drop "$NRTAR"
resign
runc
expect "refuses a missing line" 1 "${REFUSED} lists IMAGE_DIGEST-node-record-api without ${NRTAR}"

fresh
drop "IMAGE_DIGEST-node-record-api"
resign
runc
expect "refuses a tarball line without its digest file" 1 "${REFUSED} lists ${NRTAR} without IMAGE_DIGEST-node-record-api"

fresh
drop "IMAGE_DIGEST-worker-gateway"
drop "$WGTAR"
resign
runc
expect "refuses a manifest without the worker gateway" 1 \
    "${REFUSED} does not list the worker gateway (IMAGE_DIGEST-worker-gateway and ${WGTAR})"

fresh
: > "$CR/SHA256SUMS-edge"
resign
runc
expect "refuses an empty manifest" 1 "${REFUSED} does not list the worker gateway"

fresh
cp "$FIXD/node/SHA256SUMS" "$CR/SHA256SUMS-edge"
resign
runc
expect "refuses node files" 1 "${REFUSED} names IMAGE_DIGEST, which is not an edge file of ${FTAG}"

fresh
sums 'NR == 1 { $0 = toupper(substr($0, 1, 64)) substr($0, 65) } { print }'
resign
runc
expect "refuses a malformed line (upper-case hex)" 1 "${FNET}: refused: telcoin-network ${FTAG}: malformed line in SHA256SUMS-edge"

fresh
sums '{ printf "%s\r\n", $0 }'
resign
runc
expect "refuses CRLF lines" 1 "${FNET}: refused: telcoin-network ${FTAG}: malformed line in SHA256SUMS-edge"

fresh
sums 'NR == 2 { print "" } { print }'
resign
runc
expect "refuses a blank line" 1 "${FNET}: refused: telcoin-network ${FTAG}: malformed line in SHA256SUMS-edge"

fresh
sums '{ print } substr($0, 67) == n { print }' "n=IMAGE_DIGEST-worker-gateway"
resign
runc
expect "refuses a name twice" 1 "${REFUSED} names IMAGE_DIGEST-worker-gateway twice"

# =============================================================================
# digest file
# =============================================================================
fresh
printf '%s\n' "$ZPIN" > "$CR/IMAGE_DIGEST-worker-gateway"
gp "$T/k-good" --gateway-lib "$T/p-zero" --release-dir "$C"
expect "refuses a digest file that does not match its line" 1 \
    "${FNET}: refused: telcoin-network ${FTAG}: IMAGE_DIGEST-worker-gateway does not match its SHA256SUMS-edge line"
check_lacks "refuses a digest file that does not match its line: the changed file is not taken as the pin's" "${FNET}: ok:" "$OUT"

fresh
printf '%s\n%s\n' "$FLINE" "$FLINE" > "$CR/IMAGE_DIGEST-worker-gateway"
fixline IMAGE_DIGEST-worker-gateway
resign
runc
expect "refuses a digest file of two lines" 1 \
    "${FNET}: refused: telcoin-network ${FTAG}: IMAGE_DIGEST-worker-gateway holds 2 lines, not one"

fresh
rm -f "$CR/IMAGE_DIGEST-worker-gateway"
runc
expect "cannot check without IMAGE_DIGEST-worker-gateway" 2 \
    "${FNET}: cannot check: ${CR}/IMAGE_DIGEST-worker-gateway is not a regular file"

fresh
mv "$CR/IMAGE_DIGEST-worker-gateway" "$CR/IMAGE_DIGEST-worker-gateway.real"
ln -s IMAGE_DIGEST-worker-gateway.real "$CR/IMAGE_DIGEST-worker-gateway"
runc
expect "a symlinked release file is not read (offline)" 2 \
    "${FNET}: cannot check: ${CR}/IMAGE_DIGEST-worker-gateway is not a regular file"

# =============================================================================
# tag
# =============================================================================
rm -rf "$C"
mkdir -p "$C"
cp -R "$T/rel/${FTAG}" "$C/${OTAG}"
gp "$T/k-good" --gateway-lib "$T/p-otag" --release-dir "$C"
expect "refuses a tag that does not match the recorded one" 1 \
    "${FNET}: refused: telcoin-network ${OTAG}: SHA256SUMS-edge names" "which is not an edge file of ${OTAG}"
check_lacks "refuses a tag that does not match the recorded one: the signature itself verifies" "not verified" "$OUT"

fpins "$T/p-x" "$FLINE" "$XTAG"
gp "$T/k-good" --gateway-lib "$T/p-x" --base-url https://fixture.invalid
expect "refuses a release tag of the other network's form, before any download" 1 \
    "${FNET}: refused: GW_${FUP}_PIN_RELEASE ${XTAG} is not a ${FNET} release tag ($(tn_release_tag_grammar))"
check "refuses a release tag of the other network's form, before any download: nothing downloaded" "" "$LOG"

fpins "$T/p-dn" "$FLINE" "v0.2.0-devnet"
gp "$T/k-good" --gateway-lib "$T/p-dn" --base-url https://fixture.invalid
expect "refuses a devnet tag" 1 "${FNET}: refused: GW_${FUP}_PIN_RELEASE v0.2.0-devnet is not a ${FNET} release tag"
check "refuses a devnet tag: nothing downloaded" "" "$LOG"

pins "$T/p-rc" "$FREPO" "" "" "$FLINE" "v1.0.0-rc1"
gp "$T/k-good" --gateway-lib "$T/p-rc" --base-url https://fixture.invalid
expect "refuses a mainnet release candidate" 1 \
    "mainnet: refused: GW_MAINNET_PIN_RELEASE v1.0.0-rc1 is not a mainnet release tag" "release candidates are testnet only"
check "refuses a mainnet release candidate: nothing downloaded" "" "$LOG"

fpins "$T/p-norel" "$FLINE" ""
gp "$T/k-good" --gateway-lib "$T/p-norel" --release-dir "$T/rel"
expect "refuses a pin without its release" 1 \
    "${FNET}: refused: GW_${FUP}_IMAGE_PIN is set but GW_${FUP}_PIN_RELEASE is empty; record the telcoin-network release the pin comes from"

fpins "$T/p-nopin" "" "$FTAG"
gp "$T/k-good" --gateway-lib "$T/p-nopin" --release-dir "$T/rel"
expect "refuses a release without its pin" 1 \
    "${FNET}: refused: GW_${FUP}_PIN_RELEASE is ${FTAG} but GW_${FUP}_IMAGE_PIN is empty; set both or neither"

# =============================================================================
# both networks and interface
# =============================================================================
# The other network pins the same image with no release: refused before any read.
if [ "$FNET" = testnet ]; then
    pins "$T/p-two" "$FREPO" "$FLINE" "$FTAG" "$FLINE" ""
else
    pins "$T/p-two" "$FREPO" "$FLINE" "" "$FLINE" "$FTAG"
fi
gp "$T/k-good" --gateway-lib "$T/p-two" --release-dir "$T/rel"
expect "one network ok and the other refused" 1 "${OKLINE} $T/k-good" \
    "check-gateway-pin: 1 worker-gateway pin(s) refused"
check "one network ok and the other refused: one ok line" 1 "$(grep -c -- "^${FNET}: ok: " <<< "$OUT")"
check "one network ok and the other refused: one refused line" 1 "$(grep -c -- "^${ONET}: refused: " <<< "$OUT")"
check "one network ok and the other refused: testnet's line comes first" testnet "$(sed -n '1s/:.*//p' <<< "$OUT")"

# The fixture network's release is not in the directory: cannot, while the
# other network is refused.
if [ "$FNET" = testnet ]; then
    pins "$T/p-two2" "$FREPO" "$FLINE" "$OTAG" "$FLINE" ""
else
    pins "$T/p-two2" "$FREPO" "$FLINE" "" "$FLINE" "$OTAG"
fi
gp "$T/k-good" --gateway-lib "$T/p-two2" --release-dir "$T/rel"
expect "a pin that cannot be checked beside a refused one: 2 wins over 1" 2 \
    "${FNET}: cannot check: $T/rel/${OTAG}/SHA256SUMS-edge is not a regular file" \
    "${ONET}: refused: " "check-gateway-pin: 1 worker-gateway pin(s) could not be checked"

gp - --gateway-lib "$PF" --release-dir "$T/rel" --base-url https://fixture.invalid
expect "--release-dir with --base-url" 2 "check-gateway-pin: give --release-dir or --base-url, not both"

gp - --gateway-lib "$PF" --base-url http://fixture.invalid
expect "--base-url http://" 2 "check-gateway-pin: --base-url http://fixture.invalid is not an https:// URL"
check "--base-url http://: nothing downloaded" "" "$LOG"

gp "$T/k-good" --gateway-lib "$PF"
expect "TN_RELEASE_KEYS_DIR with the default base URL" 2 \
    "check-gateway-pin: TN_RELEASE_KEYS_DIR names other release keys; a release on ${TN_RELEASE_BASE_URL} is checked only against lib/release-keys (unset it, or give --release-dir)"
check "TN_RELEASE_KEYS_DIR with the default base URL: nothing downloaded" "" "$LOG"
gp "$T/k-good" --gateway-lib "$PF" --base-url "${TN_RELEASE_BASE_URL}/"
expect "TN_RELEASE_KEYS_DIR with the published base URL given by --base-url" 2 "checked only against lib/release-keys"
check "TN_RELEASE_KEYS_DIR with the published base URL given by --base-url: nothing downloaded" "" "$LOG"

printf 'GW_RELEASE_IMAGE_REPO="%s"\nGW_TESTNET_IMAGE_PIN="" GW_TESTNET_PIN_RELEASE=""\nGW_MAINNET_IMAGE_PIN=""\n' "$FREPO" > "$T/p-lacks"
gp - --gateway-lib "$T/p-lacks"
expect "a --gateway-lib that lacks GW_MAINNET_PIN_RELEASE" 2 \
    "check-gateway-pin: $T/p-lacks does not set GW_MAINNET_PIN_RELEASE"
check_lacks "a --gateway-lib that lacks GW_MAINNET_PIN_RELEASE: the tree's value does not stand in" "no pin" "$OUT"

pins "$T/p-norepo" "" "" "" "" ""
gp - --gateway-lib "$T/p-norepo"
expect "a --gateway-lib with an empty GW_RELEASE_IMAGE_REPO" 2 \
    "check-gateway-pin: $T/p-norepo sets GW_RELEASE_IMAGE_REPO to an empty value"

gp - --gateway-lib "$T/nothing-here"
expect "a --gateway-lib that is not a file" 2 "check-gateway-pin: $T/nothing-here is not a readable regular file"

gp - --gateway-lib "$PF" --release-dir "$T/nothing-here"
expect "a --release-dir that is not a directory" 2 "check-gateway-pin: $T/nothing-here is not a directory"

gp - --release-dir
expect "an option without its value" 2 "check-gateway-pin: --release-dir needs a DIR"

gp - --gateway-lib "$PF" --gateway-lib "$PF"
expect "an option given twice" 2 "check-gateway-pin: give --gateway-lib once"

gp - --frobnicate
expect "an unknown option" 2 "check-gateway-pin: unknown argument --frobnicate" "usage: tools/check-gateway-pin.sh"
check "an unknown option: nothing on stdout" "" "$OUT"

gp - --help
expect "--help" 0
check_has "--help: stdout has the usage line" \
    "usage: tools/check-gateway-pin.sh [--gateway-lib FILE] [--release-dir DIR | --base-url URL]" "$OUT"

check "the work dir is removed" "" "$(ls -A "$T/tmp")"

# =============================================================================
# static contract of the tree (from the sourced library and the file text)
# =============================================================================
check "GW_RELEASE_IMAGE_REPO is the producer's package" "ghcr.io/telcoin-association/tn-worker-gateway" "$GW_RELEASE_IMAGE_REPO"
for r in "$TN_DEV_IMAGE_REPO" "$GW_RELEASE_IMAGE_REPO" "us-docker.pkg.dev/telcoin-network/tn-public/worker-gateway"; do
    case " $GW_DEVNET_IMAGE_REPOS " in
        *" $r "*) v=yes ;;
        *) v=no ;;
    esac
    check "devnet takes ${r}" yes "$v"
done
for U in TESTNET MAINNET; do
    check "each pin line holds its release: ${U}" 1 \
        "$(grep -cE "^GW_${U}_IMAGE_PIN=\"[^\"]*\" GW_${U}_PIN_RELEASE=\"[^\"]*\"\$" "$GWLIB")"
    check "no other line assigns the ${U} pin or its release" 1 \
        "$(grep -cE "^[[:space:]]*(export[[:space:]]+)?GW_${U}_(IMAGE_PIN|PIN_RELEASE)=" "$GWLIB")"
    above="$(awk -v p="GW_${U}_IMAGE_PIN=" 'index($0, p) == 1 { print prev; exit } { prev = $0 }' "$GWLIB")"
    case "$above" in
        "# network-gated: "*) v=yes ;;
        *) v=no ;;
    esac
    check "each pin line keeps its network-gated marker: ${U}" yes "$v"
done

# _gw_pin_ok and the tool on the same pins, with the tree's GW_RELEASE_IMAGE_REPO.
PHEX="$(printf '%064d' 0 | tr 0 c)"
for net in testnet mainnet; do
    if [ "$net" = testnet ]; then
        good_rel="v1.0.0-adiri" bad_rel="v1.0.0"
    else
        good_rel="v1.0.0" bad_rel="v1.0.0-adiri"
    fi
    rc=0
    _gw_pin_ok "$net" "${GW_RELEASE_IMAGE_REPO}@sha256:${PHEX}" "$good_rel" || rc=$?
    check_rc "the library takes a ${net} pin in GW_RELEASE_IMAGE_REPO with a ${net} release" 0 "$rc"
    for c in "outside the repository|${TN_DEV_IMAGE_REPO}@sha256:${PHEX}|${good_rel}" \
        "with upper-case hex|${GW_RELEASE_IMAGE_REPO}@sha256:$(printf '%064d' 0 | tr 0 C)|${good_rel}" \
        "with an empty release|${GW_RELEASE_IMAGE_REPO}@sha256:${PHEX}|" \
        "with a release of the wrong network|${GW_RELEASE_IMAGE_REPO}@sha256:${PHEX}|${bad_rel}"; do
        what="${c%%|*}"
        rest="${c#*|}"
        pin="${rest%%|*}"
        rel="${rest#*|}"
        rc=0
        _gw_pin_ok "$net" "$pin" "$rel" || rc=$?
        check_rc "the library refuses what the tool refuses: a ${net} pin ${what}: _gw_pin_ok" 1 "$rc"
        if [ "$net" = testnet ]; then
            pins "$T/p-lib" "$GW_RELEASE_IMAGE_REPO" "$pin" "$rel" "" ""
        else
            pins "$T/p-lib" "$GW_RELEASE_IMAGE_REPO" "" "" "$pin" "$rel"
        fi
        gp "$T/k-good" --gateway-lib "$T/p-lib" --release-dir "$T/rel"
        check_rc "the library refuses what the tool refuses: a ${net} pin ${what}: the tool" 1 "$RC"
    done
done
check "the work dir is removed after the library cases too" "" "$(ls -A "$T/tmp")"

# Stop the gpg-agents real gpg started for the keys made here.
if command -v gpgconf >/dev/null 2>&1; then
    for h in "$T"/gnupg*; do
        [ -d "$h" ] && GNUPGHOME="$h" gpgconf --kill all >/dev/null 2>&1
    done
fi
finish
