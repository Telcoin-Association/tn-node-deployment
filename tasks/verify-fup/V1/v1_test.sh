#!/usr/bin/env bash
# =============================================================================
# tasks/verify-fup/V1/v1_test.sh -- independent verifier harness (V1) for the
# hardening follow-up packages LIB-A (mainnet refusals) and LIB-B (epoch timing
# derivation, network-keyed endpoints). Written from tasks/spec-fup-LIB-A.md and
# tasks/spec-fup-LIB-B.md, not from the implementers' fixtures.
#
#   bash tasks/verify-fup/V1/v1_test.sh                # the tree of this checkout
#   V1_REPO=/copy bash tasks/verify-fup/V1/v1_test.sh  # a mutated copy (mutate.sh)
#
# Each case runs in a fresh bash (drv.sh) that sources a copy of the script or
# library under test from a variant directory $T/v/<name>:
#   ship    the tree as is
#   on      lib/common.sh with TN_MAINNET_ENABLED=1
#   floor   lib/common.sh with MIN_SOURCE_VERSION_MAINNET="1.0.0"
#   launch  both of those plus a MAINNET_GENESIS_SHA256 pin (what launch flips)
#   nomain  lib/common.sh without TN_MAINNET_ENABLED and tn_mainnet_enabled
#   base    lib/ and setup-node.sh of 0a9db45 (before LIB-A/LIB-B), from V1_BASE
# check runs in this shell on the captured rc and output, never in a subshell.
# obs records a known finding: it prints FINDING and is counted apart, so the
# tree as is exits 0 and a mutation that breaks a behaviour exits 1.
# bash 3.2 safe.
# =============================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../../tools/tests/lib.sh"
R="${V1_REPO:-$TN_TEST_REPO}"
B="${V1_BASE:-$HERE/.base}"
T="$TN_TEST_TMP"
SH="${BASH:-bash}"
# Every case runs under timeout(1) when there is one (GNU and busybox take
# "timeout SECS CMD"): a mutation that makes a prompt loop ends as rc 124 there.
TO=""
if command -v timeout >/dev/null 2>&1; then TO="timeout 120"; fi
export T R
FINDINGS=0

# obs NAME EXPECTED ACTUAL -- a check whose failure is a reported finding.
obs() {
    if [[ "$2" == "$3" ]]; then
        CHECKS=$((CHECKS + 1))
        printf 'ok    %s\n' "$1"
        return 0
    fi
    FINDINGS=$((FINDINGS + 1))
    printf 'FINDING %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"
}
has() {
    case "$1" in
        *"$2"*) echo yes ;;
        *) echo no ;;
    esac
}

# ---- Variants -----------------------------------------------------------------
# mkvar NAME ROOT -- $T/v/NAME: ROOT's four scripts (whole, and *.fn.sh without
# the closing `main "$@"` line) beside a copy of ROOT/lib.
mkvar() {
    local d="$T/v/$1" s
    mkdir -p "$d"
    cp -R "$2/lib" "$d/lib"
    for s in setup-node update-node edit-config check-node; do
        [[ -f "$2/$s.sh" ]] || continue
        cp "$2/$s.sh" "$d/$s.sh"
        grep -v '^main "\$@"$' "$2/$s.sh" > "$d/$s.fn.sh"
    done
}
# vpatch NAME SED-EXPR ERE -- edit NAME's lib/common.sh; a FAIL when ERE does not
# match afterwards (the patch did not apply).
vpatch() {
    local f="$T/v/$1/lib/common.sh"
    sed -e "$2" "$f" > "$f.new" && cat "$f.new" > "$f"
    check "variant $1: patch applied (${3})" yes "$(grep -qE -- "$3" "$f" && echo yes || echo no)"
}
mkvar ship "$R"
mkvar on "$R"
vpatch on 's/^readonly TN_MAINNET_ENABLED=0$/readonly TN_MAINNET_ENABLED=1/' '^readonly TN_MAINNET_ENABLED=1$'
mkvar floor "$R"
vpatch floor 's/^readonly MIN_SOURCE_VERSION_MAINNET="".*/readonly MIN_SOURCE_VERSION_MAINNET="1.0.0"/' '^readonly MIN_SOURCE_VERSION_MAINNET="1.0.0"$'
mkvar launch "$R"
vpatch launch 's/^readonly TN_MAINNET_ENABLED=0$/readonly TN_MAINNET_ENABLED=1/' '^readonly TN_MAINNET_ENABLED=1$'
vpatch launch 's/^readonly MIN_SOURCE_VERSION_MAINNET="".*/readonly MIN_SOURCE_VERSION_MAINNET="1.0.0"/' '^readonly MIN_SOURCE_VERSION_MAINNET="1.0.0"$'
vpatch launch 's/^readonly MAINNET_GENESIS_SHA256=""$/readonly MAINNET_GENESIS_SHA256="1111111111111111111111111111111111111111111111111111111111111111"/' '^readonly MAINNET_GENESIS_SHA256="1{64}"$'
mkvar nomain "$R"
sed -e '/^tn_mainnet_enabled() {$/,/^}$/d' -e '/^readonly TN_MAINNET_ENABLED=/d' "$T/v/nomain/lib/common.sh" > "$T/nomain.sh"
cat "$T/nomain.sh" > "$T/v/nomain/lib/common.sh"
check "variant nomain: tn_mainnet_enabled removed" 0 "$(grep -c 'tn_mainnet_enabled() {' "$T/v/nomain/lib/common.sh")"
HAVE_BASE=no
if [[ -f "$B/lib/common.sh" && -f "$B/setup-node.sh" ]]; then
    mkvar base "$B"
    HAVE_BASE=yes
fi

# ---- Driver ---------------------------------------------------------------------
cat > "$T/drv.sh" <<'DRV'
# drv.sh -- one case: source V1_SRC, then the stub files in V1_STUBS, then eval
# V1_CODE. set -u stays on, as in the scripts; -e and pipefail are off.
set +e
# shellcheck source=/dev/null
source "$V1_SRC" >/dev/null 2>&1
set +e
set +o pipefail
for _v1s in ${V1_STUBS:-}; do
    # shellcheck source=/dev/null
    source "$_v1s"
done
eval "$V1_CODE"
DRV
# run_case VARIANT FILE CODE STDIN [STUB...] -- FILE is lib (the variant's
# lib/common.sh), a file name in the variant dir, or an absolute path. Sets RC,
# OUT (stdout), ERR (stderr), J (fd 3), ALL (the three), CALLS (the stub log).
run_case() {
    local v="$1" f="$2" code="$3" in="$4" src
    shift 4
    case "$f" in
        lib) src="$T/v/$v/lib/common.sh" ;;
        /*) src="$f" ;;
        *) src="$T/v/$v/$f" ;;
    esac
    : > "$T/o"
    : > "$T/e"
    : > "$T/j"
    : > "$T/calls"
    # shellcheck disable=SC2086
    V1_SRC="$src" V1_CODE="$code" V1_STUBS="$*" V1_CALLS="$T/calls" \
        $TO "$SH" "$T/drv.sh" <"$in" 2>"$T/e" 3>"$T/j" | head -c 1000000 >"$T/o"
    RC=${PIPESTATUS[0]}
    OUT="$(cat "$T/o")"
    ERR="$(head -c 1000000 "$T/e")"
    J="$(cat "$T/j")"
    ALL="${OUT}
${ERR}
${J}"
    CALLS="$(cat "$T/calls")"
}
infile() {  # infile NAME TEXT -- a stdin file holding TEXT (printf %b)
    printf '%b' "$2" > "$T/in.$1"
    printf '%s' "$T/in.$1"
}
N0=/dev/null
MREPO="ghcr.io/telcoin-association/telcoin-network"
D64="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
DCUR="fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
DU="0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
export MREPO D64 DCUR DU
# meta TEXT -- the fixture .node-meta under $TN_ROOT_PREFIX (TEXT empty: none).
export TN_ROOT_PREFIX="$T/root"
meta() {
    rm -f "${T:?}/root/etc/telcoin/.node-meta"
    mkdir -p "$T/root/etc/telcoin"
    [[ -z "$1" ]] || printf '%b\n' "$1" > "$T/root/etc/telcoin/.node-meta"
}
meta ""

echo "== A. Mainnet flag (LIB-A 1-4)"
run_case ship lib 'tn_mainnet_enabled; echo "rc=$? val=$TN_MAINNET_ENABLED"' "$N0"
check "A1 shipped library: tn_mainnet_enabled rc 1, constant 0" "rc=1 val=0" "$OUT"
export TN_MAINNET_ENABLED=1
run_case ship lib 'tn_mainnet_enabled; echo "rc=$?"; ( TN_MAINNET_ENABLED=1 ) 2>/dev/null; echo "assign=$?"; tn_mainnet_enabled; echo "rc=$?"' "$N0"
unset TN_MAINNET_ENABLED
check "A1 TN_MAINNET_ENABLED=1 in the environment does not enable mainnet; the constant cannot be set" "rc=1
assign=1
rc=1" "$OUT"
run_case on lib 'tn_mainnet_enabled; echo "rc=$?"' "$N0"
check "A1 patched library: tn_mainnet_enabled rc 0" "rc=0" "$OUT"
check "A1 constant line once, readonly, 0" 1 "$(grep -c '^readonly TN_MAINNET_ENABLED=0$' "$R/lib/common.sh")"
check "A1 the UI constant line agrees with the library (False and 0)" "False 0" \
    "$(sed -n 's/^TN_MAINNET_ENABLED = \(.*\)$/\1/p' "$R/ui/server.py") $(sed -n 's/^readonly TN_MAINNET_ENABLED=\(.*\)$/\1/p' "$R/lib/common.sh")"

SN='select_network; echo "NETWORK=$NETWORK CHAIN_ID=$CHAIN_ID CHAIN_NAME=$CHAIN_NAME RPC_URL=$RPC_URL EXPLORER_URL=$EXPLORER_URL"'
run_case ship lib "$SN" "$(infile s1 '2\nX\n1\n')"
check_rc "A2 select_network (shipped) 2, Enter, 1: rc 0" 0 "$RC"
check "A2 shipped: 2 then 1 gives testnet" yes "$(has "$OUT" "NETWORK=testnet CHAIN_ID=2017")"
check "A2 shipped: 2 says mainnet has not launched" yes "$(has "$ALL" "Mainnet has not launched yet.")"
check "A2 shipped: the line after 2 is read by the Enter prompt (no 'Please enter 1 or 2')" no "$(has "$ALL" "Please enter 1 or 2")"
check "A2 shipped: menu says (coming soon)" yes "$(has "$ALL" "for production (coming soon)")"
A2_ALL="$ALL"
if [[ "$HAVE_BASE" == yes ]]; then
    run_case base lib "$SN" "$T/in.s1"
    check "A2 shipped: menu, note and Enter prompt exactly as before the round" "$ALL" "$A2_ALL"
fi
run_case on lib "$SN" "$(infile s2 '2\n\n1\n')"
check "A2 enabled: 2 gives the four mainnet values" yes "$(has "$OUT" "NETWORK=mainnet CHAIN_ID=487 CHAIN_NAME=telcoin RPC_URL=https://rpc.telcoin.network EXPLORER_URL=https://telscan.io")"
check "A2 enabled: no (coming soon)" no "$(has "$ALL" "coming soon")"
check "A2 enabled: no not-launched note" no "$(has "$ALL" "not launched")"
run_case on lib "$SN" "$(infile s3 '1\n')"
check "A2 enabled: 1 still gives testnet" yes "$(has "$OUT" "NETWORK=testnet CHAIN_ID=2017")"

MSG_A3="Mainnet is not enabled in this script release (lib/common.sh TN_MAINNET_ENABLED); nothing on this host was changed."
JS='json_set_network "$V1_A"; echo "after NETWORK=$NETWORK CHAIN_ID=$CHAIN_ID RPC_URL=$RPC_URL"'
export V1_A=mainnet
run_case ship setup-node.fn.sh "$JS" "$N0"
check_rc "A3 json_set_network mainnet (shipped): rc 1" 1 "$RC"
check "A3 shipped: the refusal message" yes "$(has "$ALL" "$MSG_A3")"
check "A3 shipped: nothing set after the refusal" no "$(has "$OUT" "after")"
run_case on setup-node.fn.sh "$JS" "$N0"
check "A3 enabled: mainnet values set" "after NETWORK=mainnet CHAIN_ID=487 RPC_URL=https://rpc.telcoin.network" "$OUT"
for V1_A in testnet adiri; do
    export V1_A
    run_case ship setup-node.fn.sh "$JS" "$N0"
    check "A3 shipped: $V1_A unchanged" "after NETWORK=testnet CHAIN_ID=2017 RPC_URL=https://rpc.adiri.tel" "$OUT"
done
export V1_A=bogus
run_case ship setup-node.fn.sh "$JS" "$N0"
check_rc "A3 unknown network still refused" 1 "$RC"
unset V1_A

# The whole script, --json: the refusal is the first answer, before the root check.
e2e_setup() {  # e2e_setup VARIANT ARGS...
    local v="$1"
    shift
    mkdir -p "$T/e2e.$v/etc"
    find "$T/e2e.$v" | sort > "$T/e2e.before"
    TN_ROOT_PREFIX="$T/e2e.$v" TN_UPDATE_LOCK_FILE="$T/e2e.$v/lock" "$SH" "$T/v/$v/setup-node.sh" "$@" </dev/null >"$T/o" 2>"$T/e"
    RC=$?
    OUT="$(cat "$T/o")"
    ERR="$(cat "$T/e")"
    find "$T/e2e.$v" | sort > "$T/e2e.after"
}
e2e_setup ship --json --phase keygen --network mainnet --install-method release --release-tag v1.0.0
check_rc "A3 e2e: setup-node --json --network mainnet exits 1" 1 "$RC"
check "A3 e2e: error event carries the message" yes "$(has "$OUT" "{\"event\":\"error\",\"msg\":\"${MSG_A3}\"}")"
check "A3 e2e: ends with done ok:false" yes "$(printf '%s\n' "$OUT" | tail -n 1 | grep -q '^{"event":"done","ok":false' && echo yes || echo no)"
check "A3 e2e: stdout is JSON lines only" 0 "$(printf '%s\n' "$OUT" | grep -vc '^{')"
check "A3 e2e: nothing written under the root prefix" "$(cat "$T/e2e.before")" "$(cat "$T/e2e.after")"
e2e_setup ship --json --phase keygen --network mainnet --release-tag v0.16.0-adiri --build-ref v0.17.0-adiri
check "A3 e2e: a bad install flag is reported first, still nothing written" "no $(cat "$T/e2e.before")" "$(has "$OUT" "Mainnet is not enabled") $(cat "$T/e2e.after")"
e2e_setup on --json --phase keygen --network mainnet --install-method release --release-tag v1.0.0
check "A3 e2e enabled: the mainnet refusal is gone" no "$(has "$OUT$ERR" "Mainnet is not enabled")"

# The helper's setup: the engine library decides.
mkdir -p "$T/h"
printf '#!/bin/sh\n# flags the helper looks for: --release-tag --log-target --passphrase-stdin --allow-no-tpm\necho "FAKE-SETUP $*" >> "$V1_CALLS"\n' > "$T/h/fake-setup.sh"
chmod 0755 "$T/h/fake-setup.sh"
printf 'source "%s"\n' "$T/v/ship/lib/common.sh" > "$T/h/ship.sh"
printf 'source "%s"\ntn_mainnet_enabled() { return 1; }\n' "$T/v/ship/lib/common.sh" > "$T/h/one.sh"
printf 'source "%s"\n' "$T/v/nomain/lib/common.sh" > "$T/h/nomain.sh"
printf 'source "%s"\n' "$T/v/on/lib/common.sh" > "$T/h/on.sh"
HC='set +e +o pipefail
UNIT_DIR="$T/hr/etc/systemd/system"; ETC_DIR="$T/hr/etc/telcoin"; VAR_DIR="$T/hr/var/lib/telcoin"
LOG_DIR="$T/hr/var/log/telcoin"; OPT_DIR="$T/hr/opt/telcoin"; SETUP_SCRIPT="$T/h/fake-setup.sh"
HELPER_LIB="$V1_HLIB"; LIB_REQUIRE_ROOT=0; AUDIT_LOG="$T/h/audit.log"; AUDIT_LOGGER=""
TN_SETUP_NETWORK="$V1_HNET"; TN_SETUP_INSTALL_METHOD=existing
cmd_setup keygen; echo "rc=$?"'
PASSIN="$(infile pass 'correct horse battery staple 42\n')"
helper() {  # helper LIBFILE NETWORK
    export V1_HLIB="$1" V1_HNET="$2"
    run_case ship "$R/ui/telcoin-ui-helper.sh" "$HC" "$PASSIN"
}
for hl in ship one nomain missing; do
    helper "$T/h/$hl.sh" mainnet
    check_rc "A4 helper setup mainnet, library '$hl': refused" 1 "$RC"
    check "A4 helper '$hl': the message names the constant and the library" yes \
        "$(has "$ERR" "mainnet is not enabled in this script release (TN_MAINNET_ENABLED in $T/h/$hl.sh); nothing was changed")"
    check "A4 helper '$hl': setup-node never ran" no "$(has "$CALLS" FAKE-SETUP)"
done
helper "$T/h/on.sh" mainnet
check "A4 helper, enabled library: no mainnet refusal" no "$(has "$ERR" "mainnet is not enabled")"
check "A4 helper, enabled library: setup-node runs" yes "$(has "$CALLS" "FAKE-SETUP")"
helper "$T/h/ship.sh" testnet
check "A4 helper, testnet: no mainnet refusal" no "$(has "$ERR" "mainnet is not enabled")"
check "A4 helper, testnet: setup-node runs" yes "$(has "$CALLS" "FAKE-SETUP")"
helper "$T/h/ship.sh" adiri
check "A4 helper, adiri (testnet): no mainnet refusal" no "$(has "$ERR" "mainnet is not enabled")"

echo "== H. An older library behind the new scripts"
e2e_setup nomain --json --phase keygen --network testnet --install-method release --release-tag v0.16.0-adiri
check_rc "H1 setup-node over a library without tn_mainnet_enabled: exits 1" 1 "$RC"
check "H1 the gate's JSON error names the library as older" yes "$(has "$OUT" '{"event":"error","msg":"lib/common.sh 2.0.1 is older than this setup-node.sh: run update-scripts.sh and try again."}')"
check "H1 the gate's done event" yes "$(printf '%s\n' "$OUT" | tail -n 1 | grep -q '^{"event":"done","ok":false' && echo yes || echo no)"
e2e_setup nomain --network testnet
check_rc "H1 interactive: exits 1" 1 "$RC"
check "H1 interactive: [ERROR] line on stderr" yes "$(has "$ERR" "[ERROR] lib/common.sh 2.0.1 is older than this setup-node.sh")"

echo "== B. The release floor on the eight entry points (LIB-A 5)"
cat > "$T/stub-upd.sh" <<'STUBU'
# update-node stubs: the network, the current install, and every fetch, build,
# resolve or pull records "PAST <what>" (the floor let the target through).
v1_log() { printf '%s\n' "$*" >> "$V1_CALLS"; }
detect_network() { printf '%s\n' "$V1_NET"; }
image_network() { printf '%s\n' "$V1_NET"; }
installed_source_ref() { printf '\n'; }
update_downgrade_check() { return 0; }
tn_build_user_ensure() { return 0; }
source_checkout() { v1_log "PAST source_checkout $*"; return 1; }
source_build_stage() { v1_log "PAST source_build_stage"; return 1; }
release_stage() { v1_log "PAST release_stage $*"; return 1; }
tn_release_stage() { v1_log "PAST tn_release_stage"; return 2; }
tn_docker_image_for_tag() { v1_log "PAST tn_docker_image_for_tag $*"; return 1; }
docker_pull_target() { v1_log "PAST docker_pull_target $*"; return 1; }
detect_current_docker_image() { printf '%s\n' "${MREPO}@sha256:${DCUR}"; }
confirm() { v1_log "PAST confirm $*"; return 1; }
docker() { v1_log "PAST docker $*"; return 1; }
STUBU
cat > "$T/stub-ec.sh" <<'STUBE'
# edit-config stubs: as stub-upd.sh, and a Docker launch file.
v1_log() { printf '%s\n' "$*" >> "$V1_CALLS"; }
_tn_guard_network() { printf '%s\n' "$V1_NET"; }
tn_docker_network_ok() { return 0; }
tn_docker_image_for_tag() { v1_log "PAST tn_docker_image_for_tag $*"; return 1; }
docker() { v1_log "PAST docker $*"; return 1; }
confirm() { v1_log "PAST confirm $*"; return 1; }
edit_launch_unambiguous() { return 0; }
TARGET_LAUNCH_FILE="$T/launch.sh"
printf '#!/bin/sh\nexec docker run --rm %s@sha256:%s node --http\n' "$MREPO" "$DCUR" > "$T/launch.sh"
STUBE
# site N VARIANT NET REF -- run entry point N (1-8) on REF.
SITES="prepare_source_build prepare_release_update prepare_docker_update json_prepare_source json_prepare_release json_prepare_docker edit_docker_image set_docker_image"
site() {
    local n="$1" v="$2" fn
    export V1_NET="$3" V1_REF="$4"
    # shellcheck disable=SC2086
    fn="$(printf '%s\n' $SITES | sed -n "${n}p")"
    case "$n" in
        1|2|3) run_case "$v" update-node.fn.sh "JSON_MODE=false; $fn \"\$V1_REF\"; echo \"rc=\$?\"" "$N0" "$T/stub-upd.sh" ;;
        4|5|6) run_case "$v" update-node.fn.sh "JSON_MODE=true; $fn \"\$V1_REF\"; echo \"rc=\$?\"" "$N0" "$T/stub-upd.sh" ;;
        7) run_case "$v" edit-config.fn.sh "JSON_MODE=false; $fn; echo \"rc=\$?\"" "$(infile ed "${4}\n\n\n")" "$T/stub-ec.sh" ;;
        8) run_case "$v" edit-config.fn.sh "JSON_MODE=true; $fn \"\$V1_REF\"; echo \"rc=\$?\"" "$N0" "$T/stub-ec.sh" ;;
    esac
    SITE="$fn"
}
# past -- yes when the entry point went past the floor: a fetch stub ran, or a
# source update reached its checkout stage (TN_SOURCE_DIR is a readonly
# /opt/telcoin-source, absent here, checked right after the floor).
past() {
    if [[ "$(has "$CALLS" "PAST")" == yes || "$(has "$ALL" "Source directory not found at")" == yes ]]; then
        echo yes
    else
        echo no
    fi
}
for n in 1 2 3 4 5 6 7 8; do
    meta ""
    site "$n" floor mainnet v0.9.0
    check "B $SITE: mainnet v0.9.0 below the 1.0.0 floor refused" yes "$(has "$ALL" "v0.9.0 is older than v1.0.0")"
    check "B $SITE: mainnet v0.9.0 refused before any fetch" no "$(past)"
    case "$n" in
        4|5|6|8) check "B $SITE: the refusal is an error event" yes "$(has "$J" '{"event":"error","msg":"v0.9.0 is older than v1.0.0')" ;;
    esac
    site "$n" floor mainnet v1.0.0
    check "B $SITE: mainnet v1.0.0 goes on to the fetch" yes "$(past)"
    check "B $SITE: mainnet v1.0.0 no floor message" no "$(has "$ALL" "older than")"
    site "$n" floor testnet v0.12.0-adiri
    check "B $SITE: testnet v0.12.0-adiri refused (floor 0.13.0)" yes "$(has "$ALL" "v0.12.0-adiri is older than v0.13.0")"
    check "B $SITE: testnet v0.12.0-adiri refused before any fetch" no "$(past)"
    site "$n" floor testnet v0.13.0-adiri
    check "B $SITE: testnet v0.13.0-adiri goes on" yes "$(past)"
    site "$n" floor testnet v0.12.0-adiri-rc1
    check "B $SITE: testnet release candidate below the floor refused" yes "$(has "$ALL" "v0.12.0-adiri-rc1 is older than v0.13.0")"
    check "B $SITE: testnet rc below the floor: no fetch" no "$(past)"
    site "$n" floor mainnet v1.0.0-rc1
    check "B $SITE: mainnet release candidate refused before any fetch" no "$(past)"
    site "$n" floor mainnet v0.9.0-rc1
    check "B $SITE: mainnet rc below the floor refused before any fetch" no "$(past)"
    site "$n" ship mainnet v0.9.0
    check "B $SITE: shipped (empty mainnet floor) v0.9.0 goes on" yes "$(past)"
done
# Docker forms: <repo>:<tag>, and a digest whose release .node-meta records.
for n in 3 6 7 8; do
    meta ""
    site "$n" floor mainnet "${MREPO}:v0.9.0"
    check "B $SITE: mainnet <repo>:v0.9.0 refused before resolution" "yes no" "$(has "$ALL" "is older than v1.0.0") $(past)"
    site "$n" floor mainnet "${MREPO}:v1.0.0"
    check "B $SITE: mainnet <repo>:v1.0.0 goes on" yes "$(past)"
    meta "NETWORK=mainnet\nDOCKER_IMAGE_DIGEST=sha256:${D64}\nRELEASE_TAG=v0.9.0"
    site "$n" floor mainnet "${MREPO}@sha256:${D64}"
    check "B $SITE: mainnet digest recorded as v0.9.0 refused by the floor" "yes no" "$(has "$ALL" "older than v1.0.0") $(past)"
    meta "NETWORK=mainnet\nDOCKER_IMAGE_DIGEST=sha256:${D64}\nRELEASE_TAG=v1.0.0"
    site "$n" floor mainnet "${MREPO}@sha256:${D64}"
    check "B $SITE: mainnet digest recorded as v1.0.0 goes on" yes "$(past)"
    meta "NETWORK=testnet\nDOCKER_IMAGE_DIGEST=sha256:${D64}\nRELEASE_TAG=v0.12.0-adiri"
    site "$n" floor testnet "${MREPO}@sha256:${D64}"
    check "B $SITE: testnet digest recorded as v0.12.0-adiri refused by the floor" "yes no" "$(has "$ALL" "older than v0.13.0") $(past)"
done
meta ""

echo "== C. The mainnet digest rule (LIB-A 6)"
RS='say() { printf "SAY %s %s\n" "$1" "$2"; }; tn_docker_resolve_ref "$V1_NET" "$V1_ARG" say; echo "rc=$?"'
resolve() {  # resolve VARIANT NET ARG
    export V1_NET="$2" V1_ARG="$3"
    run_case "$1" lib "$RS" "$N0"
}
MSG_C="on mainnet an image is named by its release tag, so the digest comes from the signed release; sha256:${D64} is not the image of a mainnet release this node has installed"
meta ""
resolve ship mainnet "${MREPO}@sha256:${D64}"
check "C1 mainnet digest, nothing recorded: refused, nothing on stdout" "rc=1" "$OUT"
check "C1 mainnet digest, nothing recorded: the reason on stderr" yes "$(has "$ERR" "$MSG_C")"
meta "NETWORK=mainnet\nDOCKER_IMAGE_DIGEST=sha256:${D64}\nRELEASE_TAG=v1.0.0"
resolve ship mainnet "${MREPO}@sha256:${D64}"
check "C2 mainnet digest recorded as v1.0.0: taken with that tag" "${MREPO}@sha256:${D64} v1.0.0
rc=0" "$OUT"
meta "NETWORK=mainnet\nDOCKER_IMAGE_DIGEST=sha256:${DCUR}\nRELEASE_TAG=v1.0.0"
resolve ship mainnet "${MREPO}@sha256:${D64}"
check "C3 mainnet digest, another digest recorded: refused" "rc=1" "$OUT"
for tg in v0.16.0-adiri v1.0.0-rc1 ""; do
    meta "NETWORK=mainnet\nDOCKER_IMAGE_DIGEST=sha256:${D64}\nRELEASE_TAG=${tg}"
    resolve ship mainnet "${MREPO}@sha256:${D64}"
    check "C4 mainnet digest recorded with tag '${tg}' (not a mainnet release): refused" "rc=1" "$OUT"
done
meta "NETWORK=mainnet\nDOCKER_IMAGE_DIGEST=sha256:${D64}\nRELEASE_TAG=v1.0.0"
resolve ship mainnet "${MREPO}@sha256:${DU}"
check "C5 mainnet digest in uppercase hex, lowercase recorded: refused" "rc=1" "$OUT"
meta "NETWORK=mainnet\nDOCKER_IMAGE_DIGEST=sha256:${DU}\nRELEASE_TAG=v1.0.0"
resolve ship mainnet "${MREPO}@sha256:${DU}"
check "C5 mainnet digest in uppercase hex, recorded uppercase: refused" "rc=1" "$OUT"
# Testnet and devnet: exactly as before the round (0a9db45).
DEVR="$(V1_SRC="$T/v/ship/lib/common.sh" V1_CODE='printf "%s" "$TN_DEVNET_IMAGE_REPO"' V1_STUBS="" "$SH" "$T/drv.sh" </dev/null 2>/dev/null)"
GAR="us-docker.pkg.dev/telcoin-network/tn-public/adiri"
cmp_base() {  # cmp_base NAME NET ARG META
    local o1 e1
    meta "$4"
    resolve ship "$2" "$3"
    o1="$OUT"
    e1="$ERR"
    if [[ "$HAVE_BASE" != yes ]]; then
        skip "$1" "no V1_BASE"
        return 0
    fi
    resolve base "$2" "$3"
    check "$1" "$OUT / $ERR" "$o1 / $e1"
}
cmp_base "C6 testnet ghcr digest, nothing recorded: as before" testnet "${MREPO}@sha256:${D64}" ""
cmp_base "C6 testnet GAR digest, nothing recorded: as before" testnet "${GAR}@sha256:${D64}" ""
cmp_base "C6 testnet digest recorded as v0.16.0-adiri: as before" testnet "${MREPO}@sha256:${D64}" "NETWORK=testnet\nDOCKER_IMAGE_DIGEST=sha256:${D64}\nRELEASE_TAG=v0.16.0-adiri"
cmp_base "C6 testnet digest recorded with a mainnet tag: as before" testnet "${MREPO}@sha256:${D64}" "NETWORK=testnet\nDOCKER_IMAGE_DIGEST=sha256:${D64}\nRELEASE_TAG=v1.0.0"
cmp_base "C6 testnet uppercase digest: as before" testnet "${MREPO}@sha256:${DU}" ""
cmp_base "C6 devnet digest: as before" devnet "${DEVR}@sha256:${D64}" ""
cmp_base "C6 devnet uppercase digest: as before" devnet "${DEVR}@sha256:${DU}" ""
cmp_base "C6 testnet latest: as before" testnet "${MREPO}:latest" ""
meta ""
resolve ship testnet "${MREPO}@sha256:${D64}"
check "C6 testnet digest alone still taken (rc 0) with the downgrade warning" "yes yes" "$(has "$OUT" "rc=0") $(has "$ALL" "downgrade and oldest-release checks cannot be applied")"
# Through the entry points: refused before any pull.
meta ""
site 6 ship mainnet "${MREPO}@sha256:${D64}"
check "C7 json_prepare_docker: mainnet digest refused, nothing pulled" "yes no" "$(has "$J" '"event":"error","msg":"image refused') $(past)"
site 3 ship mainnet "${MREPO}@sha256:${D64}"
check "C7 prepare_docker_update: mainnet digest refused, nothing pulled" "yes no" "$(has "$ERR" "$MSG_C") $(past)"
site 8 ship mainnet "${MREPO}@sha256:${D64}"
check "C7 set_docker_image: mainnet digest refused with the mainnet message" yes "$(has "$J" "image refused: ${MREPO}@sha256:${D64} (give a mainnet release tag; a digest alone is taken only for a mainnet release this node has installed)")"
check "C7 set_docker_image: nothing pulled" no "$(past)"
site 7 ship mainnet "${MREPO}@sha256:${D64}"
check "C7 edit_docker_image: mainnet digest refused, nothing pulled" "yes no" "$(has "$ALL" "Image refused: ${MREPO}@sha256:${D64}") $(past)"
obs "C8 edit_docker_image: the mainnet refusal does not suggest a digest" no "$(has "$ALL" "Give a mainnet release tag, or ${MREPO}@sha256:<digest>.")"
obs "C8 edit_docker_image: the mainnet prompt gives no testnet tag as its example" no "$(has "$ALL" "Enter a mainnet release tag (such as v0.16.0-adiri)")"
meta "NETWORK=mainnet\nDOCKER_IMAGE_DIGEST=sha256:${D64}\nRELEASE_TAG=v1.0.0"
site 6 ship mainnet "${MREPO}@sha256:${D64}"
check "C7 json_prepare_docker: recorded mainnet release digest goes on to the pull" yes "$(has "$CALLS" "PAST docker_pull_target")"
meta ""
# setup-node at launch (flag 1, floor set, chain configs pinned): its digest path.
SC='setup_fail() { printf "%s\n" "$*" >&2; exit 1; }; setup_warn() { :; }
JSON_MODE=true; NETWORK=mainnet; INSTALL_METHOD=docker; RELEASE_TAG=""; JSON_BUILD_REF=""; JSON_PHASE=keygen
DOCKER_IMAGE="${MREPO}@sha256:${D64}"; json_check_install_flags; echo "rc=$?"'
run_case launch setup-node.fn.sh "$SC" "$N0"
SC_RC="$OUT"
resolve launch mainnet "${MREPO}@sha256:${D64}"
check "C9 launch library: tn_docker_resolve_ref refuses the bare mainnet digest" "rc=1" "$OUT"
obs "C9 setup-node --json --docker-image <ghcr digest> on mainnet at launch: refused like tn_docker_resolve_ref" "rc=1" "$SC_RC"
cat > "$T/stub-pd9.sh" <<'STUB9'
setup_fail() { printf 'FAIL %s\n' "$*"; exit 1; }
setup_warn() { printf 'WARN %s\n' "$*"; }
setup_progress() { :; }
_setup_docker_live_restore() { :; }
tn_docker_release_tag_for() { return 1; }
mkdir -p "$T/dstub"
printf '#!/bin/sh\nexit 0\n' > "$T/dstub/docker"
chmod 0755 "$T/dstub/docker"
PATH="$T/dstub:$PATH"
STUB9
run_case launch setup-node.fn.sh 'NETWORK=mainnet; RELEASE_TAG=""; DOCKER_IMAGE="${MREPO}@sha256:${D64}"; JSON_MODE=true; json_event() { printf "EV %s %s\n" "$1" "$2"; }; _preflight_docker; echo "rc=$? image=$DOCKER_IMAGE"' "$N0" "$T/stub-pd9.sh"
obs "C9 setup-node _preflight_docker at launch: a bare ghcr digest on mainnet is refused before the pull" "no" "$(has "$OUT" "Pulling Docker image: ${MREPO}@sha256:${D64}")"

echo "== D. Epoch timing derivation (LIB-B 1-2)"
cat > "$T/stub-wait.sh" <<'STUBW'
# tn_wait_restart_window stubs: a clock that the naps move, an RPC that answers
# tn_nodeMode, tn_getCurrentEpochInfo and eth_getBlockByNumber from V1_* values.
#   V1_MODE        mode answer (empty: the call fails)
#   V1_SECS        seconds to the boundary at the start
#   V1_DUR         epochDuration as written in the JSON (empty: the key is absent)
#   V1_TS          block timestamp (default boundary - V1_DUR)
#   V1_EFAIL       URLs whose epoch reads fail ("all": every one)
#   V1_UNK_RC      rc of _tn_mode_unknown_wait_url (0 staked, 3 unreadable, 1 not)
V1_NOW=1800000000
V1_SLEPT=0
V1_BOUNDARY=$(( V1_NOW + ${V1_SECS:-0} ))
v1_log() { printf '%s\n' "$*" >> "$V1_CALLS"; }
_tn_now() { printf '%s\n' "$V1_NOW"; }
_tn_nap() { V1_NOW=$(( V1_NOW + $1 )); V1_SLEPT=$(( V1_SLEPT + $1 )); v1_log "nap $1"; return 0; }
_tn_mode_unknown_wait_url() { printf '%s\n' "http://pub.example"; return "${V1_UNK_RC:-1}"; }
say() { printf '%s|%s\n' "$1" "$2"; }
tn_rpc_call() {
    local url="$1" m="$2" id ts durkey
    v1_log "rpc $url $m"
    case "$m" in
        tn_nodeMode)
            [[ -n "${V1_MODE:-}" ]] || { printf 'transport connection-refused\n'; return 1; }
            printf '{"jsonrpc":"2.0","id":1,"result":"%s"}\n' "$V1_MODE" ;;
        tn_getCurrentEpochInfo|tn_getEpochInfo)
            case " ${V1_EFAIL:-} " in
                *" all "*|*" $url "*) printf 'transport connection-refused\n'; return 1 ;;
            esac
            id=7
            if (( V1_NOW >= V1_BOUNDARY )); then id=8; fi
            durkey=""
            [[ -z "${V1_DUR:-}" ]] || durkey="\"epochDuration\":${V1_DUR},"
            printf '{"jsonrpc":"2.0","id":1,"result":{"epochId":%s,"blockHeight":100,%s"stakeVersion":1,"committee":[]}}\n' "$id" "$durkey" ;;
        eth_getBlockByNumber)
            ts="${V1_TS:-$(( V1_BOUNDARY - ${V1_DUR:-0} ))}"
            printf '{"jsonrpc":"2.0","id":1,"result":{"timestamp":"0x%x"}}\n' "$ts" ;;
        *) printf 'malformed\n'; return 1 ;;
    esac
}
STUBW
WC='tn_wait_restart_window http://127.0.0.1:8545 say; echo "rc=$? slept=$V1_SLEPT"'
# wait_case VARIANT MODE SECS DUR [ENV=VALUE ...] -- one wait; the env words are
# exported for the case and removed after it, with V1_TS, V1_EFAIL, V1_UNK_RC.
wait_case() {
    local v="$1" kv
    export V1_MODE="$2" V1_SECS="$3" V1_DUR="$4" TN_EPOCH_JITTER_MAX=0
    shift 4
    for kv in "$@"; do export "${kv?}"; done
    run_case "$v" lib "$WC" "$N0" "$T/stub-wait.sh"
    for kv in "$@"; do unset "${kv%%=*}"; done
    unset V1_MODE V1_SECS V1_DUR V1_TS V1_EFAIL V1_UNK_RC
}
slept() { printf '%s\n' "$OUT" | sed -n 's/^rc=0 slept=\([0-9]*\)$/\1/p'; }
lastl() { printf '%s\n' "$OUT" | tail -n 1; }
wait_case ship CvvActive 5000 21600
check "D1 21600 s epoch, 5000 s out: no wait" 0 "$(slept)"
check "D1 the log names the 300s margin" yes "$(has "$OUT" "outside the 300s margin; no need to wait.")"
check "D1 the log says margin and settle are derived" yes "$(has "$OUT" "Margin 300s and settle 90s, derived from a 21600 s epoch.")"
wait_case ship CvvActive 200 21600
check "D2 21600 s epoch, 200 s out: waits to the boundary, then settles 90 s" 300 "$(slept)"
check "D2 the settle is 90 s" yes "$(has "$OUT" "Giving the new committee 90s to settle.")"
D2_NAPS="$(printf '%s\n' "$CALLS" | grep '^nap' | tr '\n' ' ')"
if [[ "$HAVE_BASE" == yes ]]; then
    wait_case base CvvActive 200 21600
    check "D2 testnet numbers unchanged: the same naps as before the round" "$(printf '%s\n' "$CALLS" | grep '^nap' | tr '\n' ' ')" "$D2_NAPS"
    wait_case base CvvActive 5000 21600
    check "D2 testnet, far boundary: no wait before the round either" 0 "$(slept)"
else
    skip "D2 testnet numbers unchanged" "no V1_BASE"
fi
wait_case ship CvvActive 1000 604800
check "D3 604800 s epoch, 1000 s out: no wait" 0 "$(slept)"
check "D3 the log names the 900s margin" yes "$(has "$OUT" "outside the 900s margin; no need to wait.")"
check "D3 the log says 900 and 300 derived" yes "$(has "$OUT" "Margin 900s and settle 300s, derived from a 604800 s epoch.")"
wait_case ship CvvActive 800 604800
check "D4 604800 s epoch, 800 s out (inside 900): waits 810, settles 300" 1110 "$(slept)"
check "D4 the step message carries the derived values" yes "$(has "$OUT" "Waiting at most 1800s (TN_EPOCH_WAIT_MAX); set TN_SKIP_EPOCH_WAIT=1 to skip. Margin 900s and settle 300s, derived from a 604800 s epoch.")"
check "D4 settle 300" yes "$(has "$OUT" "Giving the new committee 300s to settle.")"
wait_case ship CvvActive 800 604800 TN_EPOCH_MARGIN=120
check "D5 TN_EPOCH_MARGIN=120 wins over the derived 900: no wait at 800 s" 0 "$(slept)"
check "D5 the log names the source of each value" yes "$(has "$OUT" "Margin 120s from TN_EPOCH_MARGIN; settle 300s derived from a 604800 s epoch.")"
wait_case ship CvvActive 100 604800 TN_EPOCH_SETTLE=30
check "D6 TN_EPOCH_SETTLE=30 wins: waits 105, settles 30" 135 "$(slept)"
check "D6 the log names TN_EPOCH_SETTLE" yes "$(has "$OUT" "Margin 900s derived from a 604800 s epoch; settle 30s from TN_EPOCH_SETTLE.")"
wait_case ship CvvActive 4000 21600 TN_EPOCH_MARGIN=5000
check "D7 an explicit margin above the clamp is used as given (5000): waits" 4095 "$(slept)"
check "D7 and the cap rises to cover it" yes "$(has "$OUT" "TN_EPOCH_WAIT_MAX 1800 is shorter than the wait it bounds (margin 5000 + settle 90 + two polls); using 5120.")"
wait_case ship CvvActive 800 604800 TN_EPOCH_WAIT_MAX=100
check "D8 TN_EPOCH_WAIT_MAX=100 under derived 900+300: raised with the warning" yes "$(has "$OUT" "warn|TN_EPOCH_WAIT_MAX 100 is shorter than the wait it bounds (margin 900 + settle 300 + two polls); using 1230.")"
check "D8 the raised cap lets the wait and the settle run" 1110 "$(slept)"
check "D8 the step message says the raised cap" yes "$(has "$OUT" "Waiting at most 1230s")"
wait_case ship CvvActive 800 604800 TN_EPOCH_WAIT_MAX=100 TN_EPOCH_POLL=20
check "D8 poll 20: the sum uses two polls of 20" yes "$(has "$OUT" "(margin 900 + settle 300 + two polls); using 1240.")"
wait_case ship CvvActive 5000 21600 TN_EPOCH_WAIT_MAX=420
check "D9 a cap equal to margin+settle+2*poll (420): no warning" no "$(has "$OUT" "shorter than the wait")"
wait_case ship CvvActive 5000 21600 TN_EPOCH_WAIT_MAX=419
check "D9 a cap one short (419): raised to 420" yes "$(has "$OUT" "TN_EPOCH_WAIT_MAX 419 is shorter than the wait it bounds (margin 300 + settle 90 + two polls); using 420.")"
wait_case ship CvvActive 200 21600 TN_EPOCH_WAIT_MAX=0
check "D10 TN_EPOCH_WAIT_MAX=0: no wait" 0 "$(slept)"
check "D10 TN_EPOCH_WAIT_MAX=0: says the wait is off" yes "$(has "$OUT" "epoch wait disabled by TN_EPOCH_WAIT_MAX=0")"
check "D10 TN_EPOCH_WAIT_MAX=0: no warning" no "$(has "$OUT" "warn|")"
check "D10 TN_EPOCH_WAIT_MAX=0: no RPC asked" no "$(has "$CALLS" "rpc ")"
wait_case ship CvvActive 200 21600 TN_SKIP_EPOCH_WAIT=1
check "D10 TN_SKIP_EPOCH_WAIT=1: no wait, no RPC" "0 no" "$(slept) $(has "$CALLS" "rpc ")"
# The blind wait: the mode and the boundary unreadable on a staked node.
export V1_EFAIL=all V1_UNK_RC=0
wait_case ship "" 200 21600
check "D11 blind wait: 300 + 90 as before" 390 "$(slept)"
D11_OUT="$OUT"
export V1_EFAIL=all V1_UNK_RC=0
wait_case ship "" 200 21600 TN_EPOCH_WAIT_MAX=100
check "D11 blind wait: the cap as set (100), no raise warning" "100 no" "$(slept) $(has "$OUT" "shorter than the wait")"
export V1_EFAIL=all V1_UNK_RC=0
wait_case ship "" 200 604800 TN_EPOCH_MARGIN=60 TN_EPOCH_SETTLE=20
check "D11 blind wait: explicit margin and settle (60 + 20)" 80 "$(slept)"
if [[ "$HAVE_BASE" == yes ]]; then
    export V1_EFAIL=all V1_UNK_RC=0
    wait_case base "" 200 21600
    check "D11 blind wait: the same messages as before the round" "$OUT" "$D11_OUT"
fi
# The keytool pin: a voting node whose epoch info cannot be read does not wait.
export V1_EFAIL=all
wait_case ship CvvActive 200 21600
check "D12 CvvActive, epoch unreadable: continues without a wait" "rc=0 slept=0" "$(lastl)"
check "D12 says so" yes "$(has "$OUT" "could not be read")"
# Derivation through the public RPC (mode unreadable, staked, local epoch unreadable).
export V1_EFAIL="http://127.0.0.1:8545" V1_UNK_RC=0
wait_case ship "" 800 604800
check "D13 epoch length read from the public RPC is used (900 margin): waits" 1110 "$(slept)"
# Malformed environment values: not a whole number of seconds, so derived.
for mv in abc "" " 300" -5 1234567890 3e2; do
    wait_case ship CvvActive 1000 604800 "TN_EPOCH_MARGIN=$mv"
    check "D14 TN_EPOCH_MARGIN='$mv' is not used: derived 900 (1000 s out: no wait)" "0 yes" "$(slept) $(has "$OUT" "Margin 900s and settle 300s, derived from a 604800 s epoch.")"
done
wait_case ship CvvActive 1000 604800 TN_EPOCH_MARGIN=0300
check "D14 TN_EPOCH_MARGIN=0300 is 300 from the environment" yes "$(has "$OUT" "Margin 300s from TN_EPOCH_MARGIN")"
wait_case ship CvvActive 1000 604800 TN_EPOCH_SETTLE=abc
check "D14 TN_EPOCH_SETTLE=abc is not used: derived 300" yes "$(has "$OUT" "settle 300s, derived")"
# epochDuration edge values.
wait_case ship CvvActive 200 0
check "D15 epochDuration 0: the fixed 300/90 apply" yes "$(has "$OUT" "Margin 300s by default; settle 90s by default.")"
check "D15 epochDuration 0, 200 s out: waits and settles 90" 300 "$(slept)"
wait_case ship CvvActive 200 -5
check "D16 epochDuration negative: no wait (unreadable epoch info)" "rc=0 slept=0" "$(lastl)"
check "D16 says the boundary could not be read" yes "$(has "$OUT" "no-epochDuration")"
wait_case ship CvvActive 200 ""
check "D16 epochDuration missing: no wait" "rc=0 slept=0" "$(lastl)"
export V1_TS=1800000000
wait_case ship CvvActive 0 999999999999999999
check "D17 huge epochDuration: clamped to 900/300, far boundary, no wait" "0 yes" "$(slept) $(has "$OUT" "Margin 900s and settle 300s, derived from a 999999999999999999 s epoch.")"
export V1_TS=1800000000
wait_case ship CvvActive 0 9999999999999999999
check "D17 a 19-digit epochDuration is unreadable: no wait" "rc=0 slept=0" "$(lastl)"
export V1_TS=$(( 1800000000 + 1000 - 604800 ))
wait_case ship CvvActive 1000 '"0x93a80"'
check "D17 epochDuration in hex (0x93a80 = 604800): derived 900/300" yes "$(has "$OUT" "Margin 900s and settle 300s, derived from a 604800 s epoch.")"
wait_case ship CvvActive 1000 64800
check "D17 18 h epoch: 900 and 270" yes "$(has "$OUT" "Margin 900s and settle 270s, derived from a 64800 s epoch.")"
wait_case ship CvvActive 1000 43200
check "D17 12 h epoch: 600 and 180 (docs note)" yes "$(has "$OUT" "Margin 600s and settle 180s, derived from a 43200 s epoch.")"
wait_case ship CvvActive -1000 21600
check "D19 boundary passed long ago: warns, no wait, with the timing sentence" "0 yes" "$(slept) $(has "$OUT" "should have ended 16m 40s ago and has not; not waiting. Margin 300s and settle 90s, derived from a 21600 s epoch.")"
wait_case ship CvvActive 100 1
check "D17 1 s epoch: clamped up to 300 and 90" yes "$(has "$OUT" "Margin 300s and settle 90s, derived from a 1 s epoch.")"
wait_case ship Observer 100 604800
check "D18 Observer: no wait" 0 "$(slept)"

echo "== E. check_internet per network (LIB-B 3)"
mkdir -p "$T/stub"
cat > "$T/stub/curl" <<STUBC
#!$(command -v bash)
for a in "\$@"; do
    case "\$a" in
        http*) printf '%s\n' "\$a" >> "\$V1_CURLLOG"
               case " \${V1_CURL_FAIL:-} " in *" \$a "*|*" all "*) exit 7 ;; esac ;;
    esac
done
exit 0
STUBC
chmod 0755 "$T/stub/curl"
export V1_CURLLOG="$T/curl.log"
CI='PATH="$T/stub:$PATH"; check_internet; echo "rc=$?"'
inet() {  # inet NETWORK|-unset [FAIL]
    : > "$V1_CURLLOG"
    if [[ "$1" == -unset ]]; then
        unset NETWORK
    else
        export NETWORK="$1"
    fi
    export V1_CURL_FAIL="${2:-}"
    run_case ship lib "$CI" "$N0"
    unset NETWORK V1_CURL_FAIL
    CURLS="$(tr '\n' ' ' < "$V1_CURLLOG")"
}
inet testnet
check "E1 testnet probes its own RPC" "rc=0 https://rpc.adiri.tel " "$(printf '%s\n' "$OUT" | grep '^rc=') $CURLS"
inet mainnet
check "E1 mainnet probes the mainnet RPC only" "rc=0 https://rpc.telcoin.network " "$(printf '%s\n' "$OUT" | grep '^rc=') $CURLS"
inet devnet
check "E1 devnet probes the devnet RPC" "rc=0 https://rpc.devnet.telcoin.network " "$(printf '%s\n' "$OUT" | grep '^rc=') $CURLS"
inet mainnet "https://rpc.telcoin.network"
check "E2 mainnet RPC down: falls back to 1.1.1.1, never the testnet RPC" "rc=0 https://rpc.telcoin.network https://1.1.1.1 " "$(printf '%s\n' "$OUT" | grep '^rc=') $CURLS"
inet mainnet all
check_rc "E2 mainnet, nothing answers: exits 1" 1 "$RC"
check "E2 and says so" yes "$(has "$ALL" "nternet")"
for nv in "" -unset adiri MAINNET " mainnet"; do
    inet "$nv"
    check_rc "E3 NETWORK '${nv}': fails closed (exit 1)" 1 "$RC"
    check "E3 NETWORK '${nv}': curl never runs" "" "$CURLS"
    check "E3 NETWORK '${nv}': the message names NETWORK" yes "$(has "$ALL" "NETWORK must be testnet, mainnet or devnet")"
done
# setup-node runs it after the network is chosen (interactive) or set (--json).
cat > "$T/stub-pre.sh" <<'STUBP'
v1_log() { printf '%s\n' "$*" >> "$V1_CALLS"; }
check_root() { :; }
setup_take_lock() { :; }
detect_distro() { :; }
setup_write_restart_guards() { :; }
check_cve_2026_31431() { :; }
prompt_setup_path() { :; }
check_hardware() { :; }
check_ports() { :; }
command_exists() { return 0; }
install_package() { v1_log "install $*"; }
select_network() { v1_log "select_network"; NETWORK="$V1_PICK"; }
tn_os_floor_check() { v1_log "floor_check NETWORK=$NETWORK"; return 1; }
PATH="$T/stub:$PATH"
STUBP
export V1_PICK=mainnet
: > "$V1_CURLLOG"
run_case ship setup-node.fn.sh 'JSON_MODE=false; NETWORK=""; DATA_DIR="$T/dd"; step_preflight; echo "rc=$?"' "$N0" "$T/stub-pre.sh"
check "E4 setup-node interactive: network chosen, then the mainnet RPC probed" "select_network https://rpc.telcoin.network" "$(printf '%s\n' "$CALLS" | grep -m1 select_network) $(head -n 1 "$V1_CURLLOG")"
: > "$V1_CURLLOG"
run_case ship setup-node.fn.sh 'JSON_MODE=true; json_event() { :; }; NETWORK=devnet; DATA_DIR="$T/dd"; step_preflight; echo "rc=$?"' "$N0" "$T/stub-pre.sh"
check "E4 setup-node --json: no menu, the set network probed" "no https://rpc.devnet.telcoin.network" "$(has "$CALLS" select_network) $(head -n 1 "$V1_CURLLOG")"
unset V1_PICK

echo "== F. check-node network RPC (LIB-B 4)"
CNF="$T/cn.fn.sh"
{
    grep -E '^(QUERY_NETWORK|NETWORK_RPC|NODE_NETWORK|NETWORK_SRC|NETWORK_NOTE|EXPECTED_CHAIN_ID|NETWORK_RPC_LABEL|NETWORK_SKIP_WHY|LOCAL_CHAIN_ID)=' "$R/check-node.sh"
    for fn in lower hex_to_dec network_chain_id network_rpc_url chain_network resolve_network; do
        awk -v f="$fn" '$0 ~ "^" f "\\(\\) *\\{" {p=1} p {print} p && /^}/ {exit}' "$R/check-node.sh"
    done
} > "$CNF"
check "F0 check-node functions extracted" 6 "$(grep -cE '^(lower|hex_to_dec|network_chain_id|network_rpc_url|chain_network|resolve_network)\(\)' "$CNF")"
RN='source "$T/cn.fn.sh"; LOCAL_CHAIN_ID="${V1_LCID:-}"; [[ -z "${V1_NRPC:-}" ]] || NETWORK_RPC="$V1_NRPC"; [[ -z "${V1_NONET:-}" ]] || QUERY_NETWORK=false
resolve_network; printf "net=%s rpc=%s query=%s why=%s label=%s\n" "$NODE_NETWORK" "$NETWORK_RPC" "$QUERY_NETWORK" "$NETWORK_SKIP_WHY" "$NETWORK_RPC_LABEL"'
rnet() {  # rnet META [LCID] [NRPC] [NONET]
    meta "$1"
    export V1_LCID="${2:-}" V1_NRPC="${3:-}" V1_NONET="${4:-}"
    run_case ship lib "$RN" "$N0"
    unset V1_LCID V1_NRPC V1_NONET
}
UNK="network unknown; give --network-rpc URL to compare"
rnet "NETWORK=mainnet"
check "F1 mainnet: its own RPC, labelled" "net=mainnet rpc=https://rpc.telcoin.network query=true why=--no-network label=https://rpc.telcoin.network (mainnet public RPC)" "$OUT"
rnet "NETWORK=testnet"
check "F1 testnet: its own RPC" "net=testnet rpc=https://rpc.adiri.tel query=true why=--no-network label=https://rpc.adiri.tel (testnet public RPC)" "$OUT"
rnet "NETWORK=devnet"
check "F1 devnet: its own RPC" "net=devnet rpc=https://rpc.devnet.telcoin.network query=true why=--no-network label=https://rpc.devnet.telcoin.network (devnet public RPC)" "$OUT"
rnet ""
check "F2 unknown network: no RPC, the query skipped with the note" "net= rpc= query=false why=${UNK} label=none (${UNK})" "$OUT"
rnet "NETWORK=adiri"
check "F2 NETWORK=adiri in .node-meta is unknown: skipped, never the testnet RPC" "net= rpc= query=false why=${UNK} label=none (${UNK})" "$OUT"
rnet "NETWORK=adiri" 0x7e1
check "F2 NETWORK=adiri with the local chain id 2017: testnet from the chain id" "net=testnet rpc=https://rpc.adiri.tel" "$(printf '%s' "$OUT" | sed 's/ query=.*//')"
rnet "" 0x1e7
check "F2 no .node-meta, local chain id 487: mainnet" "net=mainnet rpc=https://rpc.telcoin.network" "$(printf '%s' "$OUT" | sed 's/ query=.*//')"
rnet "" 0x1
check "F2 unknown local chain id: skipped" "net= rpc= query=false" "$(printf '%s' "$OUT" | sed 's/ why=.*//')"
rnet "NETWORK=mainnet" "" "https://my.rpc"
check "F3 --network-rpc wins on mainnet, labelled" "net=mainnet rpc=https://my.rpc query=true why=--no-network label=https://my.rpc (--network-rpc, for mainnet)" "$OUT"
rnet "" "" "https://my.rpc"
check "F3 --network-rpc on an unknown network: queried" "net= rpc=https://my.rpc query=true why=--no-network label=https://my.rpc (--network-rpc, for an unknown network)" "$OUT"
rnet "NETWORK=testnet" "" "" 1
check "F4 --no-network: no label, why --no-network" "query=false why=--no-network label=" "$(printf '%s' "$OUT" | sed 's/.* query=/query=/')"
rnet "" "" "" 1
check "F4 --no-network on an unknown network: why stays --no-network" "query=false why=--no-network label=" "$(printf '%s' "$OUT" | sed 's/.* query=/query=/')"
# The whole report: labels, and no request to the testnet RPC on mainnet or unknown.
cnrun() {  # cnrun META ARGS...
    meta "$1"
    shift
    : > "$V1_CURLLOG"
    export V1_CURL_FAIL=all
    PATH="$T/stub:$PATH" "$SH" "$T/v/ship/check-node.sh" --rpc http://127.0.0.1:9 "$@" </dev/null >"$T/o" 2>&1
    RC=$?
    unset V1_CURL_FAIL
    OUT="$(cat "$T/o")"
    CURLS="$(cat "$V1_CURLLOG")"
}
cnrun ""
check "F5 report, unknown network: header line" yes "$(has "$OUT" "Network RPC:  none (${UNK})")"
check "F5 report, unknown network: section 3 says why" yes "$(has "$OUT" "Network query skipped (${UNK})")"
check "F5 report, unknown network: the testnet RPC is never asked" no "$(has "$CURLS" "adiri")"
cnrun "NETWORK=mainnet"
check "F5 report, mainnet: header names the mainnet public RPC" yes "$(has "$OUT" "Network RPC:  https://rpc.telcoin.network (mainnet public RPC)")"
check "F5 report, mainnet: asks the mainnet RPC" yes "$(has "$CURLS" "https://rpc.telcoin.network")"
check "F5 report, mainnet: never the testnet RPC" no "$(has "$CURLS" "adiri")"
cnrun "NETWORK=mainnet" --network-rpc https://my.rpc
check "F5 report, --network-rpc: header says whose it is" yes "$(has "$OUT" "Network RPC:  https://my.rpc (--network-rpc, for mainnet)")"
cnrun "NETWORK=testnet" --no-network
check "F5 report, --no-network: no RPC line, skipped (--no-network)" "no yes" "$(has "$OUT" "Network RPC:") $(has "$OUT" "Network query skipped (--no-network)")"
check_rc "F5 report exits 0" 0 "$RC"
"$SH" "$T/v/ship/check-node.sh" --help </dev/null >"$T/o" 2>&1
check "F6 --help: the default is none when the network is unknown" yes "$(has "$(tr -s ' \n' '  ' < "$T/o")" "mainnet https://rpc.telcoin.network; none when the network is unknown)")"
meta ""

echo "== G. _setup_image_example and its callers (LIB-B 5)"
IE='NETWORK="$V1_NET"; _setup_image_example; echo'
img_ex() {  # img_ex VARIANT NET
    export V1_NET="$2"
    run_case "$1" setup-node.fn.sh "$IE" "$N0"
}
img_ex ship mainnet
check "G1 mainnet example: the mainnet repository by digest" "${MREPO}@sha256:<digest>" "$OUT"
check "G1 mainnet example: no adiri" no "$(has "$OUT" adiri)"
for nn in testnet devnet ""; do
    img_ex ship "$nn"
    t1="$OUT"
    if [[ "$HAVE_BASE" == yes ]]; then
        img_ex base "$nn"
        check "G2 '${nn}' example unchanged from before the round" "$OUT" "$t1"
    fi
done
# Callers on mainnet (launch library: Docker on mainnet allowed).
GC='setup_fail() { printf "FAIL %s\n" "$*"; exit 1; }; setup_warn() { :; }; NETWORK=mainnet; JSON_MODE=true; JSON_PHASE=keygen
INSTALL_METHOD=docker; RELEASE_TAG=""; JSON_BUILD_REF=""; DOCKER_IMAGE="not-an-image"; json_check_install_flags'
run_case launch setup-node.fn.sh "$GC" "$N0"
check "G3 json_check_install_flags, mainnet, bad --docker-image: example is mainnet's" "yes no" "$(has "$OUT" "such as ${MREPO}@sha256:<digest>") $(has "$OUT" adiri)"
meta "NETWORK=mainnet\nPASSPHRASE_METHOD=credential\nINSTALL_METHOD=docker\nDOCKER_IMAGE=not an image"
: > "$T/root/etc/telcoin/bls-passphrase.cred"
GF='setup_fail() { printf "FAIL %s\n" "$*"; exit 1; }; setup_warn() { :; }; finalize_same_as_keygen() { :; }; CONFIG_DIR="$TN_ROOT_PREFIX/etc/telcoin"; NETWORK=mainnet; INSTALL_METHOD=docker; DOCKER_IMAGE=""
finalize_install_inputs; echo "rc=$?"'
run_case launch setup-node.fn.sh "$GF" "$N0"
check "G3 finalize_install_inputs, mainnet, bad recorded image: example is mainnet's" "yes no" "$(has "$OUT" "such as ${MREPO}@sha256:<digest>") $(has "$OUT" adiri)"
meta ""
cat > "$T/stub-pd.sh" <<'STUBD'
setup_fail() { printf 'FAIL %s\n' "$*"; exit 1; }
setup_warn() { :; }
_setup_docker_live_restore() { :; }
latest_docker_image() { return 1; }
tn_docker_image_for_tag() { return 1; }
check_release_floor() { :; }
mkdir -p "$T/dstub"
printf '#!/bin/sh\nexit 0\n' > "$T/dstub/docker"
chmod 0755 "$T/dstub/docker"
PATH="$T/dstub:$PATH"
STUBD
run_case launch setup-node.fn.sh 'NETWORK=mainnet; RELEASE_TAG=""; DOCKER_IMAGE=""; JSON_MODE=false; _preflight_docker; echo "rc=$?"' "$(infile pd "bogus\n${MREPO}@sha256:${D64}\n")" "$T/stub-pd.sh"
check "G3 _preflight_docker, mainnet, a bad entry: the example is mainnet's" "yes no" "$(has "$ALL" "or the image by digest, such as ${MREPO}@sha256:<digest>.") $(has "$ALL" "tn-public/adiri")"
run_case ship setup-node.fn.sh 'setup_fail() { printf "FAIL %s\n" "$*"; exit 1; }; NETWORK=devnet; JSON_MODE=true; JSON_PHASE=keygen; INSTALL_METHOD=docker; RELEASE_TAG=""; JSON_BUILD_REF=""; DOCKER_IMAGE=""; json_check_install_flags' "$N0"
check "G4 devnet caller still names the devnet repository" yes "$(has "$OUT" "needs --docker-image ${DEVR}@sha256:<digest>")"

printf '\n%s finding(s) recorded (FINDING lines above)\n' "$FINDINGS"
finish
