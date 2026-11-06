#!/usr/bin/env bash
# =============================================================================
# tools/tests/p2p_allow_install_test.sh -- the tn-p2p-allow-sync install
# (_tn_p2p_allow_install and tn_p2p_allow_install, lib/common.sh) against a
# fixture release served from https://fixture.invalid/ by a curl shim, then the
# two firewall-setup.sh helpers that feed the installed tool: the config writer
# (fw_allow_write_config: its exact bytes and refusals) and the floor capture
# (fw_allow_capture_floor: which file it hands the tool, how it runs it, its
# refusals), against the tn-p2p-allow-sync stub of tools/tests/fwstub.sh.
#
#   bash tools/tests/p2p_allow_install_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/p2p_allow_install_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/p2p_allow_install_test.sh
#
# The release's SHA256SUMS is signed with a throwaway key through
# tools/tests/signing.sh: real gpg where it works, else its fake gpg and gpgv,
# which print the real status lines. Its tarball holds a #!/bin/sh binary that
# prints the five --version lines of the pinned release (or the lines a case
# gives it) and logs each call. The --version probe goes through the real
# tn_as_build_user with a setpriv shim and this account as the build account
# (nobody as root), so the binary sees the build account's environment, not the
# test's; tn_build_user_ensure (useradd) and tn_root_dir_ok (the fixture tree is
# not root's) are stubbed, and as a normal user an install shim drops -o/-g. A
# uname shim reports x86_64, or the architecture a case sets, so the release
# path runs on every host.
#
# Install cases: the happy path (root 0755 at the libexec path, the installed
# binary answers --version as the pinned release), then failures that each exit
# non-zero and leave an installed binary byte-identical and the staging dir
# empty: another architecture, a bad signature, a pin mismatch (only the sums
# downloaded), an extra sums entry, a tarball that does not match its sums line,
# an extra tarball member, a missing tarball (rc 2), a wrong first --version
# line, a wrong config-version, no snapshot version 1, a failing --version, an
# empty pin (nothing downloaded), and the public entry point, which carries the
# pinned tag and sha256 of lib/common.sh to the release URL.
#
# Maintainer tooling (not updater-tracked, no sidecar). bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tools/tests/fwstub.sh
. "${TN_TEST_DIR}/fwstub.sh"

T="$TN_TEST_TMP"
export TN_ROOT_PREFIX="$T/root"
export TN_UPDATE_LOCK_FILE="$T/lock/update.lock"
export REC="$T/rec"
FIX="$T/fix"
STAGE="$T/stage"
KEYS="$T/keys"
BIN="$T/bin"
SHIM="$T/shim"
export FIX
mkdir -p "$BIN" "$SHIM" "$FIX" "$KEYS" "$T/bh/.cargo/bin" "$T/fw" "$T/lock" \
    "$TN_ROOT_PREFIX/etc/telcoin" "$TN_ROOT_PREFIX/var/lib/telcoin/genesis" \
    "$TN_ROOT_PREFIX/var/lib/telcoin-p2p-allow" "$TN_ROOT_PREFIX/usr/local/libexec/telcoin"
mkdir -m 0700 "$STAGE"
export TN_RELEASE_STAGING_DIR="$STAGE" TN_RELEASE_KEYS_DIR="$KEYS"
tn_test_timeout_standin "$T/bh/.cargo/bin"

# source firewall-setup.sh without its trailing main call (it sources lib/common.sh)
grep -v '^main "\$@"$' "${TN_TEST_REPO}/firewall-setup.sh" > "$T/fw/firewall-setup.sh"
ln -s "${TN_TEST_REPO}/lib" "$T/fw/lib"
# shellcheck source=/dev/null
source "$T/fw/firewall-setup.sh"
set +e
TN_BUILD_HOME="$T/bh"
if [[ "$(id -u)" == 0 ]]; then TN_BUILD_USER=nobody; else TN_BUILD_USER="$(id -un)"; fi

# --- shims ------------------------------------------------------------------------
# every stub that wraps a real tool calls it by the path resolved here
cat > "$SHIM/curl" <<'SHIM'
#!/bin/sh
# curl: serves https://fixture.invalid/<path> from $FIX/<path>, logs proto and url
out=""; url=""; proto=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --url) url="$2"; shift 2 ;;
        --proto) proto="$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s %s\n' "$proto" "$url" >> "$REC.curl"
[ "$proto" = "=https" ] || exit 1
case "$url" in
    https://fixture.invalid/*) src="$FIX/${url#https://fixture.invalid/}" ;;
    *) exit 6 ;;
esac
[ -f "$src" ] || exit 22
cat "$src" > "$out"
SHIM
cat > "$SHIM/setpriv" <<'SHIM'
#!/bin/sh
# setpriv without the account switch: drops its options and runs the command
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
exec "$@"
SHIM
real_uname="$(command -v uname)"
cat > "$SHIM/uname" <<SHIM
#!/bin/sh
# uname -m answers \$TN_TEST_UNAME_M (default x86_64); anything else is the real uname
if [ "\$#" -eq 1 ] && [ "\$1" = -m ]; then
    printf '%s\n' "\${TN_TEST_UNAME_M:-x86_64}"
    exit 0
fi
exec "$real_uname" "\$@"
SHIM
chmod 0755 "$SHIM/curl" "$SHIM/setpriv" "$SHIM/uname"
if [[ "$(id -u)" != 0 ]]; then
    real_install="$(command -v install)"
    cat > "$SHIM/install" <<SHIM
#!/bin/sh
# install without -o/-g, for a run as a normal user
set -- "\$@" END
while [ "\$1" != END ]; do
    case "\$1" in
        -o|-g) shift 2 ;;
        *) set -- "\$@" "\$1"; shift ;;
    esac
done
shift
exec "$real_install" "\$@"
SHIM
    chmod 0755 "$SHIM/install"
fi
if ! command -v sha256sum >/dev/null 2>&1; then
    # macOS: the release check calls sha256sum, which only shasum provides there
    printf '#!/bin/sh\nexec %s -a 256 "$@"\n' "$(command -v shasum)" > "$SHIM/sha256sum"
    chmod 0755 "$SHIM/sha256sum"
fi

fw_stub_install "$BIN"
# shellcheck source=tools/tests/signing.sh
. "$TN_TEST_DIR/signing.sh"
PATH="$SHIM:$PATH"

tn_build_user_ensure() { return 0; }
tn_root_dir_ok() { [[ -d "$1" && ! -L "$1" ]]; }

newkey rel >/dev/null
cp "$TN_TEST_TMP/rel.asc" "$KEYS/rel.asc"

TAG="$TN_P2P_ALLOW_VERSION"
TRIPLE=x86_64-unknown-linux-musl
DIR="tn-p2p-allow-sync-${TAG}-${TRIPLE}"
TARBALL="${DIR}.tar.gz"
REL="$FIX/$TAG"
mkdir -p "$REL"
INST="$TN_P2P_ALLOW_BIN"
GOOD="tn-p2p-allow-sync ${TAG#v}
commit 0123456789abcdef0123456789abcdef01234567
target x86_64-unknown-linux-musl
snapshot-versions 1
config-version 1"
sha() { sha256sum < "$1" | cut -d' ' -f1; }
warn_line() { printf '  %s[WARN]%s %s' "$YELLOW" "$RESET" "$1"; }
# mkbin [TEXT [RC]] -- the release binary $T/relbin: it appends "$0 $*" to
# $T/probe.log and its environment to $T/probe.env, prints TEXT (default GOOD)
# and exits RC (default 0)
mkbin() {
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s %%s\\n" "$0" "$*" >> '\''%s'\''\n' "$T/probe.log"
        printf 'env >> '\''%s'\''\n' "$T/probe.env"
        printf "cat <<'VERSION'\n%s\nVERSION\n" "${1-$GOOD}"
        printf 'exit %s\n' "${2:-0}"
    } > "$T/relbin"
    chmod 0755 "$T/relbin"
}
# mktar [EXTRA] -- the release tarball, $T/relbin as its binary
mktar() {
    rm -rf "$T/tar"
    mkdir -p "$T/tar/$DIR"
    cp "$T/relbin" "$T/tar/$DIR/tn-p2p-allow-sync"
    for f in LICENSE-APACHE LICENSE-MIT NOTICE ${1:+"$1"}; do printf '%s\n' "$f" > "$T/tar/$DIR/$f"; done
    # no AppleDouble members from a macOS tar
    COPYFILE_DISABLE=1 tar -czf "$REL/$TARBALL" -C "$T/tar" "$DIR"
}
# release [EXTRA-SUMS-LINE] -- SHA256SUMS for the tarball, signed
release() {
    printf '%s  %s\n' "$(sha "$REL/$TARBALL")" "$TARBALL" > "$REL/SHA256SUMS"
    [[ -z "${1:-}" ]] || printf '%s\n' "$1" >> "$REL/SHA256SUMS"
    sign_file "$REL/SHA256SUMS" rel
}
stage_empty() {
    check "$1: staging left empty" "0" "$(find "$STAGE" -mindepth 1 | wc -l | tr -d ' ')"
}
run() { # PIN -> RC, the messages in $T/err
    : > "$REC.curl"
    : > "$T/probe.log"
    : > "$T/probe.env"
    RC=0
    _tn_p2p_allow_install "$TAG" "$1" "https://fixture.invalid/$TAG" 2>"$T/err" || RC=$?
}
mkbin
mktar
release
PIN="$(sha "$REL/$TARBALL")"

# --- nothing installed yet: a failure installs nothing ---------------------------
sed 's/^/x/' "$REL/SHA256SUMS" > "$T/sums.bad"
cp "$REL/SHA256SUMS" "$T/sums.good"
cp "$T/sums.bad" "$REL/SHA256SUMS"
run "$PIN"
check_rc "nothing installed: a refused release is rc 1" 1 "$RC"
check "nothing installed: still nothing at the libexec path" "no" "$([[ -e "$INST" || -L "$INST" ]] && echo yes || echo no)"
cp "$T/sums.good" "$REL/SHA256SUMS"

# --- happy path ------------------------------------------------------------------
export TN_BLS_PASSPHRASE="not-for-the-probe"
run "$PIN"
unset TN_BLS_PASSPHRASE
check_rc "good release installed" 0 "$RC"
check "installed binary is the tarball's" "$(sha "$T/relbin")" "$(sha "$INST" 2>/dev/null)"
check "installed mode 755" "755" "$(stat -c '%a' "$INST")"
if [[ "$(id -u)" == 0 ]]; then
    check "installed root:root" "0 0" "$(stat -c '%u %g' "$INST")"
else
    skip "installed root:root" "needs root"
fi
check_has "the install is reported" "Installed tn-p2p-allow-sync ${TAG} as /usr/local/libexec/telcoin/tn-p2p-allow-sync." "$(cat "$T/err")"
check "three downloads, all https" "=https https://fixture.invalid/${TAG}/SHA256SUMS
=https https://fixture.invalid/${TAG}/SHA256SUMS.asc
=https https://fixture.invalid/${TAG}/${TARBALL}" "$(cat "$REC.curl")"
probe="$(cat "$T/probe.log")"
check "the binary was asked --version, once, as a copy in the build account's home" "yes" \
    "$([[ "$probe" == "$TN_BUILD_HOME/probe."*"/tn-p2p-allow-sync --version" && "$probe" != *$'\n'* ]] && echo yes || echo "no: $probe")"
check_has "the probe runs with the build account's home" "HOME=$TN_BUILD_HOME" "$(cat "$T/probe.env")"
check_lacks "the probe does not see the caller's environment" "TN_BLS_PASSPHRASE" "$(cat "$T/probe.env")"
check "the probe copy is removed" "" "$(ls -d "$TN_BUILD_HOME"/probe.* 2>/dev/null)"
check "the installed binary answers as the pinned release" "tn-p2p-allow-sync ${TAG#v}" "$("$INST" --version | sed -n 1p)"
check "no .new file left beside it" "" "$(ls "$INST".new.* 2>/dev/null)"
stage_empty "good"

# the --version probe reads nothing of the caller's stdin (a terminal for an interactive on)
{
    printf '#!/bin/sh\n'
    printf 'cat > '\''%s'\''\n' "$T/probe.stdin"
    printf "cat <<'VERSION'\n%s\nVERSION\n" "$GOOD"
} > "$T/relbin"
chmod 0755 "$T/relbin"
mktar
release
printf 'the caller'\''s stdin\n' > "$T/in"
printf 'unread\n' > "$T/probe.stdin"
_tn_p2p_allow_install "$TAG" "$(sha "$REL/$TARBALL")" "https://fixture.invalid/$TAG" < "$T/in" 2>"$T/err" && RC=0 || RC=$?
check "probe stdin: installed, the probe read an empty stdin" "0|" "$RC|$(cat "$T/probe.stdin")"
mkbin
mktar
release
PIN="$(sha "$REL/$TARBALL")"
cp "$REL/SHA256SUMS" "$T/sums.good"
run "$PIN"
check_rc "probe stdin: the default release back in place" 0 "$RC"

# --- failures leave the installed binary as it was ---------------------------------
printf '#!/bin/sh\necho old\n' > "$T/old"
chmod 0755 "$T/old"
cp "$T/old" "$INST"
OLD="$(sha "$INST")"
kept() {
    check "$1: installed binary unchanged" "$OLD" "$(sha "$INST")"
    stage_empty "$1"
}

# no release for this architecture: nothing is downloaded
export TN_TEST_UNAME_M=aarch64
run "$PIN"
unset TN_TEST_UNAME_M
check_rc "another architecture refused" 1 "$RC"
check_has "another architecture: the reason" "No tn-p2p-allow-sync release is published for this architecture (aarch64); there is one for x86_64 only." "$(cat "$T/err")"
check "another architecture: nothing downloaded" "" "$(cat "$REC.curl")"
kept "another architecture"

# a bad signature: SHA256SUMS changed after signing
printf '%s  %s\n' "$(tr '0-9a-f' '1-9a-f0' <<< "$PIN")" "$TARBALL" > "$REL/SHA256SUMS"
run "$PIN"
check_rc "bad signature refused" 1 "$RC"
check_has "bad signature: the refusal names BADSIG" "Release tn-p2p-allow-sync ${TAG}: SHA256SUMS is not verified: a signature does not match SHA256SUMS (BADSIG). Nothing from this release is used." "$(cat "$T/err")"
check "bad signature: the tarball was not downloaded" "2" "$(wc -l < "$REC.curl" | tr -d ' ')"
kept "bad signature"
cp "$T/sums.good" "$REL/SHA256SUMS"

# the pin does not match the signed line
OTHER="$(printf 'other' > "$T/other"; sha "$T/other")"
run "$OTHER"
check_rc "pin mismatch refused" 1 "$RC"
check "pin mismatch: the tarball was not downloaded" "2" "$(wc -l < "$REC.curl" | tr -d ' ')"
check_has "pin mismatch: the reason names both hashes" "Release tn-p2p-allow-sync ${TAG}: SHA256SUMS gives ${TARBALL} the sha256 ${PIN}, but these scripts pin ${OTHER}. Update the scripts (update-scripts.sh) before installing it." "$(cat "$T/err")"
kept "pin mismatch"

# SHA256SUMS lists a second file
release "${PIN}  NOTICE"
run "$PIN"
check_rc "an extra sums entry refused" 1 "$RC"
check_has "extra sums entry: the reason" "Release tn-p2p-allow-sync ${TAG}: SHA256SUMS names NOTICE, which is not part of a tn-p2p-allow-sync release." "$(cat "$T/err")"
kept "extra sums entry"
release

# the server's tarball is not the one SHA256SUMS signs (and the pin names)
cp "$REL/$TARBALL" "$T/tar.good"
mkbin "$GOOD" 0
printf 'exit 0\n' >> "$T/relbin"
mktar
run "$PIN"
check_rc "a tarball that does not match its sums line refused" 1 "$RC"
check_has "sums mismatch: the reason" "Release tn-p2p-allow-sync ${TAG}: ${TARBALL} does not match its SHA256SUMS line." "$(cat "$T/err")"
check "sums mismatch: the binary was never asked" "" "$(cat "$T/probe.log")"
kept "sums mismatch"
mkbin
cp "$T/tar.good" "$REL/$TARBALL"

# the tarball carries a fifth member (signed and pinned, so only the member list refuses it)
mktar README
release
run "$(sha "$REL/$TARBALL")"
check_rc "an extra tarball member refused" 1 "$RC"
check_has "extra member: the member list named" "$(warn_line "${TARBALL} must hold exactly tn-p2p-allow-sync, LICENSE-APACHE, LICENSE-MIT and NOTICE under ${DIR}/.")" "$(cat "$T/err")"
kept "extra member"
cp "$T/tar.good" "$REL/$TARBALL"
release

# the tarball is missing on the server
mv "$REL/$TARBALL" "$T/tar.away"
run "$PIN"
check_rc "a missing tarball is rc 2" 2 "$RC"
check_has "missing tarball: the download failure named" "Could not download https://fixture.invalid/${TAG}/${TARBALL}." "$(cat "$T/err")"
kept "missing tarball"
mv "$T/tar.away" "$REL/$TARBALL"

# --version answers that do not fit the pin or the formats: each is a release of
# its own, signed and pinned, so only the answer refuses it
vcase() { # NAME TEXT RC WHY: WHY is the whole warning line
    mkbin "$2" "$3"
    mktar
    release
    run "$(sha "$REL/$TARBALL")"
    check_rc "$1 refused" 1 "$RC"
    check_has "$1: the reason" "$4" "$(cat "$T/err")"
    kept "$1"
}
vcase "a wrong first --version line" "tn-p2p-allow-sync 0.0.9
commit 0123456789abcdef0123456789abcdef01234567
target x86_64-unknown-linux-musl
snapshot-versions 1
config-version 1" 0 "$(warn_line "The tn-p2p-allow-sync binary's --version starts with 'tn-p2p-allow-sync 0.0.9', not 'tn-p2p-allow-sync ${TAG#v}'.")"
vcase "a wrong config-version" "tn-p2p-allow-sync ${TAG#v}
commit 0123456789abcdef0123456789abcdef01234567
target x86_64-unknown-linux-musl
snapshot-versions 1
config-version 2" 0 "$(warn_line "The tn-p2p-allow-sync binary does not read config version 1, the one these scripts write (its --version needs one 'config-version 1' line).")"
vcase "no snapshot version 1" "tn-p2p-allow-sync ${TAG#v}
commit 0123456789abcdef0123456789abcdef01234567
target x86_64-unknown-linux-musl
snapshot-versions 2
config-version 1" 0 "$(warn_line "The tn-p2p-allow-sync binary does not read snapshot version 1, the one nodes serve (it reads 2).")"
vcase "a binary that fails --version" "$GOOD" 1 "The tn-p2p-allow-sync binary of release tn-p2p-allow-sync ${TAG} did not answer --version (run as ${TN_BUILD_USER})."

# snapshot-versions with more than one version, one of them 1: taken
mkbin "tn-p2p-allow-sync ${TAG#v}
commit 0123456789abcdef0123456789abcdef01234567
target x86_64-unknown-linux-musl
snapshot-versions 1,2
config-version 1"
mktar
release
run "$(sha "$REL/$TARBALL")"
check_rc "snapshot-versions 1,2 taken" 0 "$RC"
check "snapshot-versions 1,2: installed" "$(sha "$T/relbin")" "$(sha "$INST")"
cp "$T/old" "$INST"

# an empty pin refuses before anything is downloaded
: > "$REC.curl"
: > "$T/say"
say() { printf '%s|%s\n' "$1" "$2" >> "$T/say"; }
RC=0
_tn_p2p_allow_install "$TAG" "" "" say 2>"$T/err" || RC=$?
check_rc "an empty pin refused" 1 "$RC"
check "no pin: the reason goes to the progress function" "warn|These scripts pin no sha256 for the tn-p2p-allow-sync ${TAG} tarball yet, so it cannot be installed; update the scripts (update-scripts.sh). Nothing was downloaded." "$(cat "$T/say")"
check "no pin: nothing downloaded" "" "$(cat "$REC.curl")"
kept "no pin"

# the entry point of the scripts carries the pinned tag and sha256 to the release
# URL: the pin is a sha256, and the first download asked for is the SHA256SUMS of
# TN_P2P_ALLOW_VERSION under TN_P2P_ALLOW_BASE_URL, which the curl shim does not
# serve (rc 2, a network failure), so nothing is installed
: > "$REC.curl"
: > "$T/say"
RC=0
tn_p2p_allow_install say 2>"$T/err" || RC=$?
check_rc "tn_p2p_allow_install against the release URL: a network failure here" 2 "$RC"
case "$TN_P2P_ALLOW_TARBALL_SHA256" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) PIN_SHAPE="64 hex" ;;
    *) PIN_SHAPE="not hex" ;;
esac
[[ ${#TN_P2P_ALLOW_TARBALL_SHA256} -eq 64 ]] || PIN_SHAPE="not 64 characters"
check "the scripts pin a sha256 for the ${TN_P2P_ALLOW_VERSION} tarball" "64 hex" "$PIN_SHAPE"
check "the entry point asks for the SHA256SUMS of the pinned tag first" "=https ${TN_P2P_ALLOW_BASE_URL}/${TN_P2P_ALLOW_VERSION}/SHA256SUMS" "$(head -n 1 "$REC.curl")"
kept "the entry point against the release URL"

command -v gpgconf >/dev/null 2>&1 && gpgconf --kill all >/dev/null 2>&1

# --- fw_allow_write_config and fw_allow_capture_floor --------------------------------
# root-owned writes are logged and land in the fixture, as in firewall_reset_test.sh
PATH="$BIN:/usr/local/bin:/usr/bin:/bin"
WRITES="$T/writes"
tn_write_root_file() {
    printf '%s %s\n' "$1" "$2" >> "$WRITES"
    if [[ -n "${WRITE_FAIL:-}" && "$1" == "$WRITE_FAIL" ]]; then
        cat > /dev/null
        return 2
    fi
    cat > "$1"
}
META="$TN_ROOT_PREFIX/etc/telcoin/.node-meta"
CFG="$FW_ALLOW_DIR/config"
cp "$BIN/tn-p2p-allow-sync" "$TN_P2P_ALLOW_BIN"

check "FW_ALLOW_DIR" "$TN_ROOT_PREFIX/var/lib/telcoin-p2p-allow" "$FW_ALLOW_DIR"
check "TN_P2P_ALLOW_BIN" "$TN_ROOT_PREFIX/usr/local/libexec/telcoin/tn-p2p-allow-sync" "$TN_P2P_ALLOW_BIN"

wc_run() { RC=0; : > "$WRITES"; fw_allow_write_config 2>"$T/err" || RC=$?; }
printf 'NETWORK=mainnet\nRPC_PORT=8645\nP2P_ALLOW_FROM=203.0.113.0/24, 198.51.100.9\n' > "$META"
wc_run
check_rc "config: written" 0 "$RC"
check "config: exact bytes" "# tn-p2p-allow-sync config, written by firewall-setup.sh
CONFIG_VERSION=1
RPC_PORT=8645
P2P_PORTS=49590,49594
P2P_ALLOW_FROM=203.0.113.0/24,198.51.100.9" "$(cat "$CFG")"
check "config: ends with one newline" "0a" "$(tail -c 1 "$CFG" | od -An -tx1 | tr -d ' ')"
check "config: one root write, mode 0600" "$CFG 0600" "$(cat "$WRITES")"

printf 'NETWORK=mainnet\n' > "$META"
wc_run
check_rc "config: no RPC_PORT, no list" 0 "$RC"
check "config: default RPC port, empty P2P_ALLOW_FROM" "# tn-p2p-allow-sync config, written by firewall-setup.sh
CONFIG_VERSION=1
RPC_PORT=8545
P2P_PORTS=49590,49594
P2P_ALLOW_FROM=" "$(cat "$CFG")"

fw_p2p_ports() { printf '49600 primary\n49604 worker-0\n49605 worker-1\n'; }
printf 'RPC_PORT=8545\nP2P_ALLOW_FROM=2001:db8::/32\n' > "$META"
wc_run
check "config: three ports in order, an IPv6 CIDR" "P2P_PORTS=49600,49604,49605
P2P_ALLOW_FROM=2001:db8::/32" "$(sed -n '4,5p' "$CFG")"
# a port listed twice is written once: the tool refuses a repeat
fw_p2p_ports() { printf '49590 primary\n49590 worker-0\n'; }
wc_run
check_rc "config: a repeated primary port written" 0 "$RC"
check "config: the repeated port once" "P2P_PORTS=49590" "$(sed -n 4p "$CFG")"
fw_p2p_ports() { printf '49590 primary\n49594 worker-0\n49594 worker-1\n49595 worker-2\n'; }
wc_run
check "config: a repeated worker port once, the order kept" "P2P_PORTS=49590,49594,49595" "$(sed -n 4p "$CFG")"
fw_p2p_ports() { printf '49590 primary\n0499 worker-0\n'; }
cp "$CFG" "$T/cfg.before"
wc_run
check_rc "config: a bad port refused" 1 "$RC"
check "config: a bad port writes nothing" "" "$(cat "$WRITES")"
eval "$(sed -n '/^fw_p2p_ports() {$/,/^}$/p' "$T/fw/firewall-setup.sh")"

printf 'RPC_PORT=8545\nRPC_PORT=8546\n' > "$META"
wc_run
check_rc "config: RPC_PORT twice refused" 1 "$RC"
check "config: RPC_PORT twice writes nothing" "" "$(cat "$WRITES")"
check "config: the old file stays" "$(cat "$T/cfg.before")" "$(cat "$CFG")"
printf 'RPC_PORT=8545\nP2P_ALLOW_FROM=203.0.113.0/24,not-an-address\n' > "$META"
wc_run
check_rc "config: an invalid P2P_ALLOW_FROM entry refused" 1 "$RC"
check "config: the invalid entry is named" "1" "$(grep -c "not-an-address" "$T/err")"
check "config: an invalid entry writes nothing" "" "$(cat "$WRITES")"
printf 'RPC_PORT=8545\nP2P_ALLOW_FROM=203.0.113.0/24\nP2P_ALLOW_FROM=198.51.100.9\n' > "$META"
wc_run
check_rc "config: P2P_ALLOW_FROM twice refused" 1 "$RC"
# hosts the tool refuses as never a peer's source: refused here, the entry named
for e in 224.0.0.1 239.255.255.250 169.254.10.10 169.254.1.1/32 fe80::1 FE80::1 febf::1 \
    ff02::1 ff00::/128 0:0:0:0:0:0:0:0 ::0 0000::0 ::ffff:a9fe:101 0:0:0:0:0:ffff:e000:1 ::ffff:0:0; do
    printf 'RPC_PORT=8545\nP2P_ALLOW_FROM=203.0.113.0/24,%s\n' "$e" > "$META"
    wc_run
    check "config: never a peer's source refused: $e" "1|1|" \
        "$RC|$(grep -c "lists ${e}, an unspecified, multicast or link-local address" "$T/err")|$(cat "$WRITES")"
done
check "config: a refused host leaves the old file" "$(cat "$T/cfg.before")" "$(cat "$CFG")"
# networks in those ranges, and hosts next to them, are the tool's to take
for e in fe80::/64 224.0.0.0/8 169.254.0.0/16 ff::1 fe8::1 fec0::1 223.255.255.255 240.0.0.1 \
    169.255.0.1 ::1 ::ffff:cb00:7109 2001:db8::ff02; do
    printf 'RPC_PORT=8545\nP2P_ALLOW_FROM=%s\n' "$e" > "$META"
    wc_run
    check "config: taken: $e" "0|P2P_ALLOW_FROM=$e" "$RC|$(sed -n 5p "$CFG")"
done
printf 'RPC_PORT=8545\n' > "$META"
WRITE_FAIL="$CFG" wc_run
check_rc "config: a failed write is rc 1" 1 "$RC"
check "config: the failed write is named" "1" "$(grep -c '/var/lib/telcoin-p2p-allow/config could not be written' "$T/err")"

cf_run() { RC=0; : > "$REC.log"; fw_allow_capture_floor 2>"$T/err" || RC=$?; }
PEERS="$TN_ROOT_PREFIX/etc/telcoin/bootstrap-peers.yaml"
GEN="$TN_ROOT_PREFIX/var/lib/telcoin/genesis/committee.yaml"
cp "$TN_TEST_REPO/tools/tests/genesis.d/testnet/committee.yaml" "$GEN"
printf 'NETWORK=testnet\n' > "$META"
cf_run
check_rc "floor: from the genesis committee" 0 "$RC"
check "floor: the tool gets the genesis committee.yaml" "--state-dir $FW_ALLOW_DIR capture-floor $GEN" "$(cat "$REC.log")"
printf '{}\n' > "$PEERS"
cf_run
check_rc "floor: from the peers file" 0 "$RC"
check "floor: the peers file wins" "--state-dir $FW_ALLOW_DIR capture-floor $PEERS" "$(cat "$REC.log")"
export TN_P2P_STUB_STDIN=1
printf 'not for the tool\n' > "$T/stdin"
RC=0; : > "$REC.log"; fw_allow_capture_floor < "$T/stdin" 2>"$T/err" || RC=$?
unset TN_P2P_STUB_STDIN
check "floor: the tool's stdin is closed" "0|" "$RC|$(cat "$REC.stdin")"
export TN_BLS_PASSPHRASE="not-for-the-tool"
cf_run
unset TN_BLS_PASSPHRASE
check_rc "floor: run with a passphrase in the environment" 0 "$RC"
check_lacks "floor: the tool does not see TN_BLS_PASSPHRASE" "TN_BLS_PASSPHRASE" "$(cat "$REC.env")"
rm -f "$PEERS"
ln -s "$GEN" "$PEERS"
cf_run
check_rc "floor: a symlinked peers file refused" 1 "$RC"
check "floor: a symlinked peers file is not handed over" "" "$(cat "$REC.log")"
rm -f "$PEERS"
printf 'DATA_DIR=/srv/node\n' > "$META"
mkdir -p "$TN_ROOT_PREFIX/srv/node/genesis"
cf_run
check_rc "floor: DATA_DIR without a genesis committee refused" 1 "$RC"
check "floor: the missing file is named" "1" "$(grep -c '/srv/node/genesis/committee.yaml is missing' "$T/err")"
check "floor: nothing handed over" "" "$(cat "$REC.log")"
cp "$GEN" "$TN_ROOT_PREFIX/srv/node/genesis/committee.yaml"
cf_run
check "floor: DATA_DIR from .node-meta" "--state-dir $FW_ALLOW_DIR capture-floor $TN_ROOT_PREFIX/srv/node/genesis/committee.yaml" "$(cat "$REC.log")"
printf 'DATA_DIR=/srv/node\nDATA_DIR=/srv/other\n' > "$META"
cf_run
check_rc "floor: DATA_DIR twice refused" 1 "$RC"
check "floor: DATA_DIR twice hands nothing over" "" "$(cat "$REC.log")"
printf 'NETWORK=testnet\n' > "$META"
export TN_P2P_STUB_RC_CAPTURE_FLOOR=2
cf_run
unset TN_P2P_STUB_RC_CAPTURE_FLOOR
check_rc "floor: the tool's exit code comes back" 2 "$RC"
check "floor: its failure is named" "1" "$(grep -c 'capture-floor /var/lib/telcoin/genesis/committee.yaml failed (exit 2)' "$T/err")"
# no descriptor above 2 reaches the tool
cat > "$TN_P2P_ALLOW_BIN" <<'FDS'
#!/bin/sh
ls /proc/self/fd > "$REC.fds"
FDS
if [[ -d /proc/self/fd ]]; then
    exec 7>"$T/held"
    cf_run
    exec 7>&-
    check "floor: only fds 0-2 (and ls's own) reach the tool" "0 1 2 3" "$(sort -n < "$REC.fds" | tr '\n' ' ' | sed 's/ $//')"
else
    skip "floor: descriptors" "no /proc"
fi

finish
