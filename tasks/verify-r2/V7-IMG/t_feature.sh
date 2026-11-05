#!/usr/bin/env bash
# =============================================================================
# tasks/verify-r2/V7-IMG/t_feature.sh -- IMG check 4 (V7 spec), the function
# itself: tn_docker_image_network_ok against a docker stand-in on PATH that
# prints a canned --version per image digest. Mainnet: no features only; testnet:
# adiri, faucet allowed, nothing else; one Build Features line exactly; a run
# that fails, or a timeout (rc 124, or 137 after the KILL), refuses (fail
# closed), and a timed-out run removes its container (docker rm -f <name>, under
# timeout -k 5 30); devnet is not checked; an unknown network and an image not
# given by digest refuse before any docker call; the docker run carries --init,
# --name tn-feature-check-<pid>-<n>, --pull=never, --network none, --cap-drop
# ALL, no-new-privileges, --read-only and --entrypoint /usr/local/bin/telcoin,
# under `timeout -k 5 60` where timeout exists; the message names the image, the
# features found and the network; a progress function gets the message.
#
#   bash tasks/verify-r2/V7-IMG/t_feature.sh
#
# Verifier harness (round 2, V7-IMG). bash 3.2 safe.
# =============================================================================
# shellcheck source=tasks/verify-r2/V7-IMG/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
eval "$(tn_test_source_common)"
v7_docker_stub "$T/bin"
PATH="$T/bin:$PATH"

N=0
case_() {  # NAME NETWORK FEATURES-LINE|@raw:TEXT EXPECTED-RC
    local d rc=0 txt
    N=$((N + 1))
    d="$(v7_digest "$N")"
    case "$3" in
        @raw:*) txt="${3#@raw:}" ;;
        *) txt="$(v7_version "$3")" ;;
    esac
    v7_canned "$d" "$txt"
    : > "$V7_DLOG"
    tn_docker_image_network_ok "$2" "${4:-$GT}@sha256:${d}" 2>"$T/err" || rc=$?
    check_rc "feature $2: $1" "$5" "$rc"
    LAST_IMG="${4:-$GT}@sha256:${d}"
}
NL=$'\n'
# mainnet
case_ "no features accepted" mainnet "Build Features: " "$GM" 0
case_ "no features, no trailing space accepted" mainnet "Build Features:" "$GM" 0
case_ "adiri refused" mainnet "Build Features: adiri" "$GM" 1
check_has "feature mainnet: refusal names image, features and network" "yes" \
    "$(grep -q "${LAST_IMG} was built with the features adiri, and a mainnet image has none" "$T/err" && echo yes || echo no)"
case_ "faucet refused" mainnet "Build Features: faucet" "$GM" 1
case_ "adiri,faucet refused" mainnet "Build Features: adiri,faucet" "$GM" 1
case_ "any feature refused" mainnet "Build Features: default" "$GM" 1
case_ "two lines refused" mainnet "Build Features: ${NL}Build Features: " "$GM" 1
check_has "feature mainnet: doubled line message" "yes" \
    "$(grep -q 'prints 2 "Build Features:" lines with --version, not one' "$T/err" && echo yes || echo no)"
case_ "missing line refused" mainnet "Build Profile: maxperf" "$GM" 1
case_ "indented line does not count (refused)" mainnet "  Build Features: " "$GM" 1
case_ "empty output refused" mainnet "@raw:" "$GM" 1
# testnet
case_ "adiri accepted" testnet "Build Features: adiri" "$GT" 0
case_ "adiri,faucet accepted" testnet "Build Features: adiri,faucet" "$GT" 0
case_ "faucet,adiri accepted" testnet "Build Features: faucet,adiri" "$GT" 0
case_ "adiri with CR accepted" testnet "Build Features: adiri"$'\r' "$GT" 0
case_ "no features refused" testnet "Build Features: " "$GT" 1
check_has "feature testnet: refusal names features none and the rule" "yes" \
    "$(grep -q "${LAST_IMG} was built with the features none, and a testnet image has adiri, and faucet at most" "$T/err" && echo yes || echo no)"
case_ "faucet alone refused" testnet "Build Features: faucet" "$GT" 1
case_ "adiri,evil refused" testnet "Build Features: adiri,evil" "$GT" 1
case_ "adiri twice on two lines refused" testnet "Build Features: adiri${NL}Build Features: adiri" "$GT" 1
case_ "missing line refused" testnet "Commit SHA: 1" "$GT" 1
case_ "space-separated list refused (upstream splits on [, ]; NOTE)" testnet "Build Features: adiri faucet" "$GT" 1
# the run itself
d="$(v7_digest 900)"
v7_canned "$d" "$(v7_version 'Build Features: ')"
rc=0; V7_RUN_RC=1 tn_docker_image_network_ok mainnet "${GM}@sha256:${d}" 2>"$T/err" || rc=$?
check_rc "feature: docker run exit 1 refused even with a good line" 1 "$rc"
check_has "feature: run failure says it was not used" "yes" "$(grep -q 'docker run exited 1), so it is not used' "$T/err" && echo yes || echo no)"
rc=0; tn_docker_image_network_ok mainnet "${GM}@sha256:$(v7_digest 901)" 2>"$T/err" || rc=$?
check_rc "feature: image not held (docker exit 125) refused" 1 "$rc"
# v7_name LINE -- the --name in LINE; v7_unname LINE -- LINE with that name as NAME.
v7_name() { printf '%s\n' "$1" | sed -n 's/.* --name \([^ ]*\) .*/\1/p'; }
v7_unname() { printf '%s\n' "$1" | sed 's/ --name [^ ]* / --name NAME /'; }
# timeout: a stand-in that logs its arguments; V7_TMO_RC=124 (or 137) plays a hang
# that timed out (or was killed after the TERM).
if command -v timeout >/dev/null 2>&1; then
    v7_timeout_stub "$T/bin"
    : > "$V7_DLOG"
    rc=0; tn_docker_image_network_ok mainnet "${GM}@sha256:${d}" 2>"$T/err" || rc=$?
    check_rc "feature: under timeout, good image accepted" 0 "$rc"
    check "feature: the run goes through timeout -k 5 60, behind --init, named" "timeout -k 5 60 docker run --rm --init --name NAME --pull=never --network none --cap-drop ALL --security-opt no-new-privileges --read-only --entrypoint /usr/local/bin/telcoin ${GM}@sha256:${d} --version" "$(v7_unname "$(head -n 1 "$V7_DLOG")")"
    check "feature: the container name is tn-feature-check-<pid>-<n>" yes \
        "$(v7_name "$(head -n 1 "$V7_DLOG")" | grep -qE '^tn-feature-check-[0-9]+-[0-9]+$' && echo yes || echo no)"
    check "feature: a run that finished removes nothing" 0 "$(grep -c 'docker rm' "$V7_DLOG")"
    for trc in 124 137; do
        : > "$V7_DLOG"
        rc=0; V7_TMO_RC="$trc" tn_docker_image_network_ok mainnet "${GM}@sha256:${d}" 2>"$T/err" || rc=$?
        check_rc "feature: timeout (rc ${trc}) refused" 1 "$rc"
        check_has "feature: timeout message names the limit and rc ${trc}" "yes" \
            "$(grep -q "did not finish --version within 60 seconds (docker run exited ${trc} under timeout)" "$T/err" && echo yes || echo no)"
        nm="$(v7_name "$(head -n 1 "$V7_DLOG")")"
        check "feature: rc ${trc}: docker rm -f of that container, under timeout, after the run" \
            "timeout -k 5 30 docker rm -f ${nm}|rm -f ${nm}" "$(sed -n '2p;3p' "$V7_DLOG" | tr '\n' '|' | sed 's/|$//')"
    done
    unset trc nm
    rm -f "$T/bin/timeout"
else
    skip "feature: timeout cases" "no timeout on this host"
fi
: > "$V7_DLOG"
rc=0; PATH="$T/bin:/usr/bin:/bin" tn_docker_image_network_ok mainnet "${GM}@sha256:${d}" 2>/dev/null || rc=$?
check_rc "feature: good image accepted" 0 "$rc"
check_has "feature: docker run flags" "run --rm --init --name NAME --pull=never --network none --cap-drop ALL --security-opt no-new-privileges --read-only --entrypoint /usr/local/bin/telcoin ${GM}@sha256:${d} --version" "$(v7_unname "$(cat "$V7_DLOG")")"
# before any docker call
for img in "${GM}:v1.0.0" "-${GM}@sha256:${d}" "${GM}@sha256:${d} --privileged" "" "${GM}"; do
    : > "$V7_DLOG"
    rc=0; tn_docker_image_network_ok mainnet "$img" 2>/dev/null || rc=$?
    check "feature: not by digest refused, no docker call: '${img}'" "1 0" "$rc $(wc -l < "$V7_DLOG" | tr -d ' ')"
done
: > "$V7_DLOG"
rc=0; tn_docker_image_network_ok devnet "${GD}@sha256:${d}" 2>"$T/err" || rc=$?
check "feature: devnet not checked (rc 0, no docker call)" "0 0" "$rc $(wc -l < "$V7_DLOG" | tr -d ' ')"
check_has "feature: devnet info line" "yes" "$(grep -q 'Devnet images are not checked' "$T/err" && echo yes || echo no)"
for n in adiri "" prod; do
    : > "$V7_DLOG"
    rc=0; tn_docker_image_network_ok "$n" "${GM}@sha256:${d}" 2>/dev/null || rc=$?
    check "feature: network '${n}' refused, no docker call" "1 0" "$rc $(wc -l < "$V7_DLOG" | tr -d ' ')"
done
# the progress function gets the refusal
v7_canned "$d" "$(v7_version 'Build Features: adiri')"
SAID="$T/said"
say() { printf '%s|%s\n' "$1" "$2" >> "$SAID"; }
: > "$SAID"
rc=0; tn_docker_image_network_ok mainnet "${GM}@sha256:${d}" say 2>/dev/null || rc=$?
check "feature: refusal through the progress function" "1 1" "$rc $(grep -c '^warn|Image refused: ' "$SAID")"
# a docker run that writes to stderr only: still refused, stderr not mistaken for output
v7_canned "$d" ""
rc=0; tn_docker_image_network_ok testnet "${GT}@sha256:${d}" 2>/dev/null || rc=$?
check_rc "feature: blank output refused" 1 "$rc"
finish
