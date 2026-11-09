#!/usr/bin/env bash
# =============================================================================
# tools/tests/setup_node_admission_test.sh -- setup-node.sh --admission and
# --trusted-nodes, the node admission settings of network-config:
#
#   the flags      main's option loop takes both, and refuses an empty or
#                  missing value; init_node_extra_flags keeps the mode in lower
#                  case, refuses another word, checks the trusted nodes file as
#                  a peers file is checked (the peers refusals are unchanged),
#                  refuses --trusted-nodes without --admission in a --json keygen
#                  (elsewhere the read-back checks the pair) and refuses a
#                  --release-tag below the floor before anything else;
#   the read-back  admission_read_back fills a flag left out from .node-meta
#                  (ADMISSION_MODE, TRUSTED_NODES_FILE, and with a mode
#                  BOOTSTRAP_PEERS_FILE) and stops on a bad mode, a missing file,
#                  a key set twice or a map with no mode;
#   the release    prepare_node_extra_flags asks tn_node_supports_admission:
#                  below MIN_ADMISSION_VERSION setup stops, naming the floor,
#                  before anything is installed or recorded; a release it cannot
#                  tell warns and goes on; closed without a trusted nodes map
#                  warns on mainnet;
#   the install    the trusted nodes map goes to CONFIG_DIR/trusted-nodes.yaml
#                  through tn_write_root_file, mode 0644, group root, fed from a
#                  file; .node-meta records both keys beside BOOTSTRAP_PEERS_FILE;
#   the render     setup_admission_config calls tn_network_config_render with the
#                  data dir, the mode and the installed maps (or none), and the
#                  real renderer writes the three entries; without a mode nothing
#                  is called and network-config keeps its bytes; a refused map
#                  stops setup; step_create_service renders right after
#                  prepare_node_extra_flags;
#   the runs       keygen then finalize, and an interactive run then a re-run
#                  with no flags: the re-run leaves network-config (its
#                  committee_peers too), the trusted nodes map and .node-meta
#                  byte-identical; --trusted-nodes alone over a recorded mode;
#   the library    a lib/common.sh without the renderer is refused up front;
#                  --help names both flags and the mainnet default.
#
#   bash tools/tests/setup_node_admission_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/setup_node_admission_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/setup_node_admission_test.sh
#
# A copy of setup-node.sh without its last line (main "$@") is sourced by a
# driver that runs one case per call. tn_write_root_file is a stand-in that logs
# its destination, mode, group and whether stdin is a pipe, then writes the file
# as the current user; tn_node_has_flag, tn_node_parse_check and
# tn_docker_release_tag_for are stand-ins; tn_network_config_render is the
# library's own, behind a wrapper that logs its arguments. It edits as the
# service user through the library's tn_as_service_user, with the setpriv, id
# and getent PATH stubs of network_config_test.sh (telcoin is uid and gid 991,
# and setpriv runs the command as the current user). Maintainer tooling (not
# updater-tracked). bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
SN="$TN_TEST_REPO/setup-node.sh"
ORIG_PATH="$PATH"
export SNM_DIR="$T"
CFG="$T/fx/etc/telcoin"
DD="$T/fx/var/lib/telcoin"
NC="$DD/network-config"
META="$CFG/.node-meta"

has() {
    case "$1" in
        *"$2"*) echo yes ;;
        *) echo no ;;
    esac
}

# ---- the copy of setup-node.sh, the driver and the stubs ----------------------
mkdir -p "$T/sn" "$T/bin" "$T/root" "$CFG" "$DD" "$T/fx/opt" "$T/in"
grep -v '^main "\$@"$' "$SN" > "$T/sn/setup-node.sh"
ln -s "$TN_TEST_REPO/lib" "$T/sn/lib"
# main's option loop, cut out as a function
{
    echo 'parse_fn() {'
    awk '/^    while \[\[ \$# -gt 0 \]\]; do$/ { f = 1 } f { print } f && /^    done$/ { exit }' "$SN"
    echo '}'
} > "$T/sn/parse.sh"

TN_NC_CALLS="$T/calls.log"
TN_NC_REAL_ID="$(command -v id)"
export TN_NC_CALLS TN_NC_REAL_ID
cat > "$T/bin/id" <<'STUB'
#!/bin/sh
# the service account telcoin is uid 991 in group telcoin; any other question
# goes to the real id
if [ "$*" = "-u telcoin" ]; then echo 991; exit 0; fi
if [ "$*" = "-gn telcoin" ]; then echo telcoin; exit 0; fi
exec "$TN_NC_REAL_ID" "$@"
STUB
cat > "$T/bin/getent" <<'STUB'
#!/bin/sh
# one group: telcoin, gid 991
if [ "$1" = group ] && [ "$2" = telcoin ]; then echo 'telcoin:x:991:'; exit 0; fi
exit 2
STUB
cat > "$T/bin/setpriv" <<'STUB'
#!/bin/sh
# log the account options, then run the command as the current user
opts=""
while [ $# -gt 0 ] && [ "$1" != -- ]; do opts="$opts $1"; shift; done
[ $# -gt 0 ] && shift
printf 'setpriv%s -- %s\n' "$opts" "${1:-}" >> "$TN_NC_CALLS"
exec "$@"
STUB
chmod 0755 "$T/bin/id" "$T/bin/getent" "$T/bin/setpriv"

cat > "$T/sn/drv.sh" <<'DRV'
# drv.sh CASE [ARG...] -- source the copy of setup-node.sh, then run one case.
TN_ROOT_PREFIX="$SNM_DIR/root"
source "$SNM_DIR/sn/setup-node.sh"
source "$SNM_DIR/sn/parse.sh"
set +e
CONFIG_DIR="$SNM_DIR/fx/etc/telcoin"
DATA_DIR="$SNM_DIR/fx/var/lib/telcoin"
NETWORK="${SNM_NETWORK:-testnet}"
JSON_MODE="${SNM_JSON:-false}"
JSON_PHASE="${SNM_PHASE:-}"
ADMISSION_MODE="${SNM_MODE:-}"
TRUSTED_NODES_SRC="${SNM_TRUSTED:-}"
BOOTSTRAP_PEERS_SRC="${SNM_PEERS:-}"
RELEASE_TAG="${SNM_RELEASE_TAG:-}"
INSTALL_METHOD="${SNM_INSTALL:-existing}"
BINARY_PATH="$SNM_DIR/fx/opt/telcoin-network"
DOCKER_IMAGE="${SNM_IMAGE:-}"
SERVICE_USER=telcoin
SERVICE_GROUP=telcoin
exec 3>>"$SNM_DIR/events"
tn_write_root_file() {
    local how=file
    if [ -p /dev/stdin ]; then how=pipe; fi
    printf '%s %s %s %s\n' "$1" "$2" "${3:-root}" "$how" >> "$SNM_DIR/rootw.log"
    cat > "$1" && chmod "$2" "$1"
}
tn_node_has_flag() { return 0; }
tn_node_parse_check() { return 0; }
# the peers map's own installer chowns to root; here it copies (the real one
# goes through a temp file, so the installed map given again stays)
install_bootstrap_peers() {
    printf '%s %s\n' "$2" "$3" >> "$SNM_DIR/peers.log"
    [ "$2" = "$3" ] && return 0
    cp "$2" "$3" && chmod 0644 "$3"
}
tn_docker_release_tag_for() {
    [ -n "${SNM_DOCKER_TAG:-}" ] || return 1
    printf '%s\n' "$SNM_DOCKER_TAG"
}
eval "real_render() $(declare -f tn_network_config_render | sed 1d)"
tn_network_config_render() {
    printf '%s\n' "$*" >> "$SNM_DIR/render.log"
    real_render "$@"
}
vars() {
    echo "ADMISSION_MODE=${ADMISSION_MODE} TRUSTED_NODES_SRC=${TRUSTED_NODES_SRC}"
}
case "$1" in
    parse) shift; parse_fn "$@"; vars ;;
    init) init_node_extra_flags; vars ;;
    readback) admission_read_back; vars ;;
    readback-peers) admission_read_back; echo "BOOTSTRAP_PEERS_SRC=${BOOTSTRAP_PEERS_SRC}" ;;
    finalize-flags) finalize_node_extra_flags; vars ;;
    prepare) prepare_node_extra_flags; vars ;;
    render) setup_admission_config; echo "render rc $?" ;;
    keygen) init_node_extra_flags; prepare_node_extra_flags; vars ;;
    finalize) init_node_extra_flags; finalize_node_extra_flags; prepare_node_extra_flags; setup_admission_config; vars ;;
    interactive) init_node_extra_flags; prepare_node_extra_flags; setup_admission_config; vars ;;
    summary) set +u; PASSPHRASE_METHOD=credential; step_final_summary ;;
esac
DRV

# drv CASE [ARG...] -- run the driver with the stubs first on PATH; OUT (stdout
# and stderr together) and RC; the logs start empty.
drv() {
    rm -f "$T/rootw.log" "$T/render.log" "$T/events"
    : > "$T/calls.log"
    RC=0
    OUT="$(PATH="$T/bin:$ORIG_PATH" bash "$T/sn/drv.sh" "$@" 2>&1 < /dev/null)" || RC=$?
}
last() { printf '%s\n' "$OUT" | tail -n 1; }
logf() { if [[ -f "$1" ]]; then cat "$1"; fi; }
# reset -- no .node-meta, no installed maps, no network-config, no marker
reset() {
    rm -f "$META" "$CFG/trusted-nodes.yaml" "$CFG/bootstrap-peers.yaml" "$NC" "$T/fx/opt/telcoin-network.version"
}
marker() { printf '%s\n' "$1" > "$T/fx/opt/telcoin-network.version"; }
meta() {
    local l
    : > "$META"
    for l in "$@"; do
        printf '%s\n' "$l" >> "$META"
    done
}
metakey() { grep "^$1=" "$META" 2>/dev/null || true; }

# ---- inputs -------------------------------------------------------------------
cat > "$T/in/trusted.yaml" <<'TRU'
# hubs for the closed validator
HubBLSkey1:
  primary:
    network_address: /ip4/203.0.113.10/udp/49590/quic-v1/p2p/12D3KooWHubPrimary
    network_key: 4XTTMhubprimary
  workers:
    0:
      network_address: /ip4/203.0.113.10/udp/49594/quic-v1/p2p/12D3KooWHubWorker
      network_key: 4XTTMhubworker
TRU
cat > "$T/in/peers.yaml" <<'PEE'
PeerBLSkey1:
  primary:
    network_address: /ip4/198.51.100.21/udp/49590/quic-v1/p2p/12D3KooWPeer1P
    network_key: 4XTTMpeer1p
  workers:
    - network_address: /ip4/198.51.100.21/udp/49594/quic-v1/p2p/12D3KooWPeer1W
      network_key: 4XTTMpeer1w
PEE
printf 'just a scalar\n' > "$T/in/scalar.yaml"
cp "$T/in/trusted.yaml" "$T/in/private.yaml"
awk 'BEGIN { for (i = 0; i < 1100; i++) printf("k%04d: 0123456789012345678901234567890123456789012345678901234567890\n", i) }' > "$T/in/big.yaml"
chmod 0644 "$T/in/trusted.yaml" "$T/in/peers.yaml" "$T/in/scalar.yaml" "$T/in/big.yaml"
chmod 0600 "$T/in/private.yaml"
TRUSTED="$T/in/trusted.yaml"
Z64=0000000000000000000000000000000000000000000000000000000000000000
PEERS="$T/in/peers.yaml"
# the network-config setup-node finds before the render: the advertised name
printf 'hostname: "validator-1"\n' > "$T/in/nc-before"
# what the render makes of it with the trusted nodes and the peers, mode closed
cat > "$T/in/nc-closed" <<'WNT'
hostname: "validator-1"
admission:
  mode: Closed
trusted_nodes:
  # hubs for the closed validator
  HubBLSkey1:
    primary:
      network_address: /ip4/203.0.113.10/udp/49590/quic-v1/p2p/12D3KooWHubPrimary
      network_key: 4XTTMhubprimary
    workers:
      0:
        network_address: /ip4/203.0.113.10/udp/49594/quic-v1/p2p/12D3KooWHubWorker
        network_key: 4XTTMhubworker
committee_peers:
  PeerBLSkey1:
    primary:
      network_address: /ip4/198.51.100.21/udp/49590/quic-v1/p2p/12D3KooWPeer1P
      network_key: 4XTTMpeer1p
    workers:
      - network_address: /ip4/198.51.100.21/udp/49594/quic-v1/p2p/12D3KooWPeer1W
        network_key: 4XTTMpeer1w
WNT

# -----------------------------------------------------------------------------
# the flags: main's option loop
# -----------------------------------------------------------------------------
drv parse --admission closed --trusted-nodes "$TRUSTED"
check "parse: both flags taken" "0 ADMISSION_MODE=closed TRUSTED_NODES_SRC=${TRUSTED}" "$RC $(last)"
for f in --admission --trusted-nodes; do
    drv parse "$f"
    check "parse: ${f} last, with no value, stops" "1 yes" "$RC $(has "$OUT" "${f} requires a value")"
    drv parse "$f" ""
    check "parse: ${f} with an empty value stops" "1 yes" "$RC $(has "$OUT" "${f} requires a value")"
    drv parse "$f" --json
    check "parse: ${f} followed by an option stops" "1 yes" "$RC $(has "$OUT" "${f} requires a value")"
done

# -----------------------------------------------------------------------------
# the flags: init_node_extra_flags
# -----------------------------------------------------------------------------
reset
for m in open grace closed Open Grace Closed; do
    SNM_MODE="$m" drv init
    lc="$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')"
    check "init: --admission ${m} is kept as ${lc}" "0 ADMISSION_MODE=${lc} TRUSTED_NODES_SRC=" "$RC $(last)"
done
SNM_MODE=CLOSED drv init
check "init: another word stops" "1 yes" "$RC $(has "$OUT" "--admission takes open, grace or closed, not CLOSED.")"
SNM_MODE=grace SNM_TRUSTED="$TRUSTED" drv init
check "init: a readable trusted nodes file is taken" "0 ADMISSION_MODE=grace TRUSTED_NODES_SRC=${TRUSTED}" "$RC $(last)"
SNM_TRUSTED="$TRUSTED" drv init
check "init: --trusted-nodes without --admission is left to an interactive run's read-back" \
    "0 ADMISSION_MODE= TRUSTED_NODES_SRC=${TRUSTED}" "$RC $(last)"
SNM_TRUSTED="$TRUSTED" SNM_JSON=true SNM_PHASE=keygen drv init
check "init: --trusted-nodes without --admission stops a --json keygen" "1 yes" \
    "$RC $(has "$OUT" "--trusted-nodes needs --admission open, grace or closed: the trusted nodes go into network-config together with the admission mode.")"
# a --release-tag is judged in the preflight, before a build or a download
SNM_MODE=closed SNM_RELEASE_TAG=v0.16.0 drv init
check "init: --admission with a --release-tag below the floor stops" "1 yes" \
    "$RC $(has "$OUT" "--admission needs node release 0.17.0 or later, and this run installs v0.16.0, which ignores the admission settings of network-config. Pick a newer release, or leave --admission and --trusted-nodes out.")"
SNM_MODE=closed SNM_RELEASE_TAG=v0.16.0 SNM_JSON=true SNM_PHASE=keygen drv init
check "init: the same in a --json keygen" "1 yes" "$RC $(has "$OUT" "this run installs v0.16.0, which ignores")"
SNM_MODE=grace SNM_RELEASE_TAG=v0.17.0 drv init
check "init: a --release-tag at the floor passes" "0 ADMISSION_MODE=grace TRUSTED_NODES_SRC=" "$RC $(last)"
SNM_MODE=grace SNM_RELEASE_TAG=main drv init
check "init: a --release-tag that cannot be told is left to prepare_node_extra_flags" "0 no" "$RC $(has "$OUT" "Could not tell")"
SNM_RELEASE_TAG=v0.16.0 drv init
check "init: no --admission, no floor" "0 ADMISSION_MODE= TRUSTED_NODES_SRC=" "$RC $(last)"
SNM_TRUSTED="$TRUSTED" SNM_JSON=true SNM_PHASE=finalize drv init
check "init: a --json finalize may leave the mode to keygen's record" "0 ADMISSION_MODE= TRUSTED_NODES_SRC=${TRUSTED}" "$RC $(last)"
SNM_MODE=closed SNM_TRUSTED="$T/in/absent.yaml" drv init
check "init: a missing trusted nodes file stops" "1 yes" "$RC $(has "$OUT" "--trusted-nodes: ${T}/in/absent.yaml does not exist.")"
SNM_MODE=closed SNM_TRUSTED="$T/in" drv init
check "init: a directory stops" "1 yes" "$RC $(has "$OUT" "--trusted-nodes: ${T}/in is not a regular file.")"
SNM_MODE=closed SNM_TRUSTED="$T/in/private.yaml" drv init
check "init: a trusted nodes file others cannot read stops" "1 yes" \
    "$RC $(has "$OUT" "--trusted-nodes: ${T}/in/private.yaml is mode 600: other users cannot read it. Setup accepts only a trusted nodes file that others can already read, because the installed copy is world-readable (0644). Run chmod 644 ${T}/in/private.yaml first.")"
SNM_MODE=closed SNM_TRUSTED="$T/in/big.yaml" drv init
check "init: a trusted nodes file over 64 KiB stops" "1 yes" "$RC $(has "$OUT" "a trusted nodes map may have at most 65536 (64 KiB)")"
# the peers refusals read as before
SNM_PEERS="$T/in/private.yaml" drv init
check "init: the peers mode refusal is unchanged" "1 yes" \
    "$RC $(has "$OUT" "--bootstrap-peers: ${T}/in/private.yaml is mode 600: other users cannot read it. Setup accepts only a peers file that others can already read, because the installed copy is world-readable (0644) and the check passes the map on the command line of the node binary, where other users can see it. Run chmod 644 ${T}/in/private.yaml first.")"
SNM_PEERS="$T/in/big.yaml" drv init
check "init: the peers size refusal is unchanged" "1 yes" "$RC $(has "$OUT" "is $(wc -c < "$T/in/big.yaml" | tr -d ' ') bytes; a peers map may have at most 65536 (64 KiB).")"

# -----------------------------------------------------------------------------
# the read-back
# -----------------------------------------------------------------------------
reset
drv readback
check "read-back: no .node-meta, nothing" "0 ADMISSION_MODE= TRUSTED_NODES_SRC=" "$RC $(last)"
meta "NETWORK=testnet" "ADMISSION_MODE=grace" "TRUSTED_NODES_FILE=${TRUSTED}"
drv readback
check "read-back: both keys" "0 ADMISSION_MODE=grace TRUSTED_NODES_SRC=${TRUSTED}" "$RC $(last)"
SNM_MODE=closed drv readback
check "read-back: a flag given wins over the record" "0 ADMISSION_MODE=closed TRUSTED_NODES_SRC=${TRUSTED}" "$RC $(last)"
SNM_TRUSTED="$PEERS" drv readback
check "read-back: a map given wins over the record" "0 ADMISSION_MODE=grace TRUSTED_NODES_SRC=${PEERS}" "$RC $(last)"
meta "ADMISSION_MODE=" "TRUSTED_NODES_FILE="
drv readback
check "read-back: empty keys are none" "0 ADMISSION_MODE= TRUSTED_NODES_SRC=" "$RC $(last)"
meta "ADMISSION_MODE=Closed"
drv readback
check "read-back: a recorded mode that is not open, grace or closed stops" "1 yes" \
    "$RC $(has "$OUT" "ADMISSION_MODE=Closed in ${META} is not open, grace or closed. Fix the line, or pass --admission.")"
meta "ADMISSION_MODE=closed" "TRUSTED_NODES_FILE=${T}/in/absent.yaml"
drv readback
check "read-back: a recorded map that is gone stops" "1 yes" \
    "$RC $(has "$OUT" "TRUSTED_NODES_FILE in ${META}: ${T}/in/absent.yaml does not exist. Put the file back, or pass --trusted-nodes FILE.")"
meta "ADMISSION_MODE=closed" "ADMISSION_MODE=open"
drv readback
check "read-back: a key set twice stops" "1 yes" "$RC $(has "$OUT" "ADMISSION_MODE is set more than once in ${META}")"
meta "TRUSTED_NODES_FILE=${TRUSTED}"
drv readback
check "read-back: a recorded map with no mode stops" "1 yes" \
    "$RC $(has "$OUT" "A trusted nodes map (${TRUSTED}) but no admission mode: pass --admission open, grace or closed.")"
meta "ADMISSION_MODE=closed" "TRUSTED_NODES_FILE=${TRUSTED}" "STATE_EXPORT=4"
SNM_JSON=true SNM_PHASE=finalize drv finalize-flags
check "read-back: finalize_node_extra_flags reads both" "0 ADMISSION_MODE=closed TRUSTED_NODES_SRC=${TRUSTED}" "$RC $(last)"
# committee_peers comes from the bootstrap peers map, so a mode brings it back
meta "ADMISSION_MODE=closed" "BOOTSTRAP_PEERS_FILE=${PEERS}"
drv readback-peers
check "read-back: with a mode, the recorded peers map too" "0 BOOTSTRAP_PEERS_SRC=${PEERS}" "$RC $(last)"
SNM_MODE=open drv readback-peers
check "read-back: with a mode given, the recorded peers map too" "0 BOOTSTRAP_PEERS_SRC=${PEERS}" "$RC $(last)"
SNM_PEERS="$TRUSTED" drv readback-peers
check "read-back: a peers map given wins over the record" "0 BOOTSTRAP_PEERS_SRC=${TRUSTED}" "$RC $(last)"
meta "BOOTSTRAP_PEERS_FILE=${PEERS}"
drv readback-peers
check "read-back: no mode, the peers map is not read back here" "0 BOOTSTRAP_PEERS_SRC=" "$RC $(last)"
meta "ADMISSION_MODE=grace" "BOOTSTRAP_PEERS_FILE=${T}/in/absent.yaml"
drv readback-peers
check "read-back: a recorded peers map that is gone stops" "1 yes" \
    "$RC $(has "$OUT" "BOOTSTRAP_PEERS_FILE in ${META}: ${T}/in/absent.yaml does not exist. Put the file back, or pass --bootstrap-peers FILE.")"

# -----------------------------------------------------------------------------
# the release, the install and .node-meta: prepare_node_extra_flags
# -----------------------------------------------------------------------------
reset
marker v0.16.0-adiri
SNM_MODE=closed SNM_TRUSTED="$TRUSTED" drv prepare
check "release: below the floor stops, naming it" "1 yes" \
    "$RC $(has "$OUT" "--admission needs node release 0.17.0 or later, and this run installs v0.16.0-adiri, which ignores the admission settings of network-config. Pick a newer release, or leave --admission and --trusted-nodes out.")"
check "release: below the floor installs nothing" "no|" "$([[ -e "$CFG/trusted-nodes.yaml" ]] && echo yes || echo no)|$(logf "$T/rootw.log")"
check "release: below the floor records nothing" "" "$(logf "$META")"
SNM_RELEASE_TAG=v0.16.0 SNM_INSTALL=release SNM_MODE=open drv prepare
check "release: RELEASE_TAG is the one asked" "1 yes" "$RC $(has "$OUT" "this run installs v0.16.0, which ignores")"
SNM_INSTALL=docker SNM_IMAGE="ghcr.io/example/tn@sha256:${Z64}" SNM_DOCKER_TAG=v0.16.2 SNM_MODE=grace drv prepare
check "release: a Docker image goes by the release that names it" "1 yes" "$RC $(has "$OUT" "this run installs v0.16.2, which ignores")"
SNM_INSTALL=docker SNM_IMAGE="ghcr.io/example/tn@sha256:${Z64}" SNM_DOCKER_TAG=v0.17.0 SNM_MODE=grace drv prepare
check "release: a Docker image of a release at the floor passes" "0 ADMISSION_MODE=grace TRUSTED_NODES_SRC=" "$RC $(last)"
reset
SNM_MODE=closed SNM_TRUSTED="$TRUSTED" drv prepare
check "release: a binary that cannot be told warns and goes on" "0 yes" \
    "$RC $(has "$OUT" "Could not tell whether the node binary at ${T}/fx/opt/telcoin-network is release 0.17.0 or later, which --admission needs (an older release ignores the admission settings); writing them anyway.")"
reset
marker v0.17.0-adiri
SNM_MODE=closed SNM_TRUSTED="$TRUSTED" drv prepare
check "install: at the floor, the map is installed" "0 ADMISSION_MODE=closed TRUSTED_NODES_SRC=${CFG}/trusted-nodes.yaml" "$RC $(last)"
check_has "install: through tn_write_root_file, 0644, group root, from a file" "${CFG}/trusted-nodes.yaml 0644 root file" "$(logf "$T/rootw.log")"
check "install: the bytes of the map" same "$(cmp -s "$TRUSTED" "$CFG/trusted-nodes.yaml" && echo same || echo differ)"
check "install: mode 0644" 644 "$(stat -c '%a' "$CFG/trusted-nodes.yaml" 2>/dev/null)"
check "install: the ok line" yes "$(has "$OUT" "Trusted nodes map installed: ${CFG}/trusted-nodes.yaml")"
check "meta: ADMISSION_MODE recorded" "ADMISSION_MODE=closed" "$(metakey ADMISSION_MODE)"
check "meta: TRUSTED_NODES_FILE names the installed map" "TRUSTED_NODES_FILE=${CFG}/trusted-nodes.yaml" "$(metakey TRUSTED_NODES_FILE)"
check "meta: beside the other node flag keys" "BOOTSTRAP_PEERS_FILE= STATE_EXPORT=off" "$(metakey BOOTSTRAP_PEERS_FILE) $(metakey STATE_EXPORT)"
check "render: prepare_node_extra_flags renders nothing itself" "" "$(logf "$T/render.log")"
reset
marker v0.17.0
drv prepare
check "meta: no --admission records both keys empty" "0 ADMISSION_MODE= TRUSTED_NODES_FILE=" "$RC $(metakey ADMISSION_MODE) $(metakey TRUSTED_NODES_FILE)"
check "release: no --admission asks nothing" "no" "$(has "$OUT" "--admission needs")"
check "install: no --trusted-nodes installs nothing" "no|" "$([[ -e "$CFG/trusted-nodes.yaml" ]] && echo yes || echo no)|$(grep 'trusted-nodes' "$T/rootw.log" 2>/dev/null || true)"
# an interactive run reads the record back; a --json keygen does not
meta "ADMISSION_MODE=grace"
drv prepare
check "prepare: an interactive run keeps the recorded mode" "0 ADMISSION_MODE=grace TRUSTED_NODES_SRC=" "$RC $(last)"
meta "ADMISSION_MODE=grace"
SNM_JSON=true SNM_PHASE=keygen drv prepare
check "prepare: a --json keygen starts from its flags" "0 ADMISSION_MODE=" "$RC $(metakey ADMISSION_MODE)"

# -----------------------------------------------------------------------------
# the render: setup_admission_config
# -----------------------------------------------------------------------------
reset
cp "$T/in/nc-before" "$NC"
cp "$TRUSTED" "$CFG/trusted-nodes.yaml"
cp "$PEERS" "$CFG/bootstrap-peers.yaml"
SNM_MODE=closed SNM_TRUSTED="$CFG/trusted-nodes.yaml" SNM_PEERS="$CFG/bootstrap-peers.yaml" drv render
check "render: the arguments" "0 ${DD} closed ${CFG}/trusted-nodes.yaml ${CFG}/bootstrap-peers.yaml" "$RC $(logf "$T/render.log")"
check "render: network-config holds the three entries" "$(cat "$T/in/nc-closed")" "$(cat "$NC")"
check "render: as the service user" yes "$(has "$(logf "$T/calls.log")" "setpriv --reuid 991 --regid 991 --clear-groups --no-new-privs -- sh")"
check "render: the ok line" yes "$(has "$OUT" "Admission settings written to ${NC} (mode Closed)")"
cp "$NC" "$T/nc-first"
SNM_MODE=closed SNM_TRUSTED="$CFG/trusted-nodes.yaml" SNM_PEERS="$CFG/bootstrap-peers.yaml" drv render
check "render: a second render leaves network-config byte-identical" "0 same" "$RC $(cmp -s "$T/nc-first" "$NC" && echo same || echo differ)"
SNM_MODE=grace drv render
check "render: no maps, both none" "0 ${DD} grace none none" "$RC $(logf "$T/render.log")"
check "render: none drops the two entries" "$(printf 'hostname: "validator-1"\nadmission:\n  mode: Grace')" "$(cat "$NC")"
SNM_MODE=grace SNM_JSON=true drv render
check "render: --json logs the settings" yes "$(has "$(logf "$T/events")" '"msg":"admission: grace, trusted nodes none, committee peers none"')"
cp "$T/in/nc-closed" "$NC"
drv render
check "render: no mode calls nothing" "0||" "$RC|$(logf "$T/render.log")|$(logf "$T/calls.log")"
check "render: no mode leaves network-config as it was" same "$(cmp -s "$T/in/nc-closed" "$NC" && echo same || echo differ)"
cp "$T/in/scalar.yaml" "$CFG/trusted-nodes.yaml"
SNM_MODE=closed SNM_TRUSTED="$CFG/trusted-nodes.yaml" drv render
check "render: a refused map stops setup" "1 yes" \
    "$RC $(has "$OUT" "The admission settings were not written to ${NC} (see the message above), so setup stops before the node is started.")"
check "render: the renderer says why" yes "$(has "$OUT" "does not start with a map keyed by BLS public key")"
check "render: a refused map leaves network-config as it was" same "$(cmp -s "$T/in/nc-closed" "$NC" && echo same || echo differ)"
# step_create_service: right after prepare_node_extra_flags, before anything it writes
check "order: step_create_service renders right after prepare_node_extra_flags" \
    "prepare_node_extra_flags setup_admission_config" \
    "$(sed -n '/^step_create_service() {/,/^}/p' "$SN" | grep -E '^    [a-z_]+$' | grep -A1 -x '    prepare_node_extra_flags' | tr -d ' ' | tr '\n' ' ' | sed 's/ $//')"
check "order: step_write_config does not render" 0 \
    "$(sed -n '/^step_write_config() {/,/^}/p' "$SN" | grep -c 'setup_admission_config\|tn_network_config_render')"

# -----------------------------------------------------------------------------
# the runs: keygen then finalize; an interactive run, then a re-run
# -----------------------------------------------------------------------------
reset
marker v0.17.0
cp "$T/in/nc-before" "$NC"
SNM_JSON=true SNM_PHASE=keygen SNM_MODE=closed SNM_TRUSTED="$TRUSTED" SNM_PEERS="$PEERS" drv keygen
check "keygen: records both and renders nothing" "0 ADMISSION_MODE=closed TRUSTED_NODES_FILE=${CFG}/trusted-nodes.yaml|" \
    "$RC $(metakey ADMISSION_MODE) $(metakey TRUSTED_NODES_FILE)|$(logf "$T/render.log")"
check "keygen: network-config untouched" same "$(cmp -s "$T/in/nc-before" "$NC" && echo same || echo differ)"
SNM_JSON=true SNM_PHASE=finalize drv finalize
check "finalize: keygen's choice, read back" "0 ADMISSION_MODE=closed TRUSTED_NODES_SRC=${CFG}/trusted-nodes.yaml" "$RC $(last)"
check "finalize: rendered with the installed maps" "${DD} closed ${CFG}/trusted-nodes.yaml ${CFG}/bootstrap-peers.yaml" "$(logf "$T/render.log")"
check "finalize: the trusted nodes map is not written again" "" "$(grep 'trusted-nodes' "$T/rootw.log" 2>/dev/null || true)"
check "finalize: network-config" "$(cat "$T/in/nc-closed")" "$(cat "$NC")"
reset
marker v0.17.0
cp "$T/in/nc-before" "$NC"
SNM_MODE=closed SNM_TRUSTED="$TRUSTED" SNM_PEERS="$PEERS" drv interactive
check "interactive: rendered" "0 $(cat "$T/in/nc-closed")" "$RC $(cat "$NC")"
cp "$NC" "$T/nc-run1"
cp "$META" "$T/meta-run1"
cp "$CFG/trusted-nodes.yaml" "$T/trusted-run1"
drv interactive
check "re-run: the recorded settings, read back" "0 ADMISSION_MODE=closed TRUSTED_NODES_SRC=${CFG}/trusted-nodes.yaml" "$RC $(last)"
check "re-run: rendered with the recorded peers map" "${DD} closed ${CFG}/trusted-nodes.yaml ${CFG}/bootstrap-peers.yaml" "$(logf "$T/render.log")"
check "re-run: network-config byte-identical, committee_peers kept" same "$(cmp -s "$T/nc-run1" "$NC" && echo same || echo differ)"
check "re-run: .node-meta byte-identical" same "$(cmp -s "$T/meta-run1" "$META" && echo same || echo differ)"
check "re-run: the trusted nodes map byte-identical and not rewritten" "same|" \
    "$(cmp -s "$T/trusted-run1" "$CFG/trusted-nodes.yaml" && echo same || echo differ)|$(grep 'trusted-nodes' "$T/rootw.log" 2>/dev/null || true)"
# --trusted-nodes alone over the recorded mode: the mode is kept, the new map goes in
sed 's/^# hubs for the closed validator$/# the second hub list/' "$TRUSTED" > "$T/in/trusted-b.yaml"
chmod 0644 "$T/in/trusted-b.yaml"
SNM_TRUSTED="$T/in/trusted-b.yaml" drv interactive
check "re-run: --trusted-nodes alone keeps the recorded mode" "0 ADMISSION_MODE=closed TRUSTED_NODES_SRC=${CFG}/trusted-nodes.yaml" "$RC $(last)"
check "re-run: --trusted-nodes alone installs the new map" same "$(cmp -s "$T/in/trusted-b.yaml" "$CFG/trusted-nodes.yaml" && echo same || echo differ)"
check_has "re-run: --trusted-nodes alone renders the new map" "  # the second hub list" "$(cat "$NC")"
# --trusted-nodes alone, nothing recorded: the read-back's pair check stops it
reset
marker v0.17.0
cp "$T/in/nc-before" "$NC"
SNM_TRUSTED="$TRUSTED" drv interactive
check "interactive: --trusted-nodes alone with no recorded mode stops" "1 yes" \
    "$RC $(has "$OUT" "A trusted nodes map (${TRUSTED}) but no admission mode: pass --admission open, grace or closed.")"
check "interactive: --trusted-nodes alone with no recorded mode writes nothing" "||same" \
    "$(logf "$T/rootw.log")|$(logf "$T/render.log")|$(cmp -s "$T/in/nc-before" "$NC" && echo same || echo differ)"
# without a mode, an interactive run keeps its old peers behaviour: only the flag counts
reset
marker v0.17.0
cp "$PEERS" "$CFG/bootstrap-peers.yaml"
meta "BOOTSTRAP_PEERS_FILE=${CFG}/bootstrap-peers.yaml"
drv prepare
check "interactive: no mode, a recorded peers map is not read back" "0 BOOTSTRAP_PEERS_FILE=" "$RC $(metakey BOOTSTRAP_PEERS_FILE)"
SNM_MODE=closed SNM_TRUSTED="$CFG/trusted-nodes.yaml" drv summary
check_has "summary: the admission mode" "$(printf '  %-22s %s' Admission: closed)" "$OUT"
check_has "summary: the trusted nodes map" "$(printf '  %-22s %s' 'Trusted nodes:' "${CFG}/trusted-nodes.yaml")" "$OUT"
# a mainnet validator without --admission: nothing written, nothing recorded
reset
marker v0.17.0
cp "$T/in/nc-before" "$NC"
SNM_NETWORK=mainnet drv interactive
check "mainnet: no --admission, no admission settings" "0 ADMISSION_MODE= TRUSTED_NODES_SRC=||same" \
    "$RC $(last)|$(logf "$T/render.log")|$(cmp -s "$T/in/nc-before" "$NC" && echo same || echo differ)"
# closed with no trusted nodes map: a warning on mainnet, where validators are
# expected to run --admission closed --trusted-nodes <hubs>
W_CLOSED="Admission closed without --trusted-nodes: the node admits only the previous, current and next committees and the bootstrap peers. Mainnet validators are expected to run --admission closed --trusted-nodes <hubs>."
for c in "mainnet closed none yes" "mainnet closed trusted no" "mainnet grace none no" "testnet closed none no"; do
    # shellcheck disable=SC2086  # the case is four words, split on purpose
    set -- $c
    reset
    marker v0.17.0
    cp "$T/in/nc-before" "$NC"
    tr=""
    [[ "$3" == none ]] || tr="$TRUSTED"
    SNM_NETWORK="$1" SNM_MODE="$2" SNM_TRUSTED="$tr" drv interactive
    check "warning: ${1}, ${2}, trusted map ${3}: warned ${4}" "0 ${4}" "$RC $(has "$OUT" "$W_CLOSED")"
done
reset
marker v0.17.0
SNM_NETWORK=mainnet SNM_JSON=true SNM_PHASE=keygen SNM_MODE=closed drv keygen
check "warning: a mainnet --json keygen warns too, as a log event" "0 yes" \
    "$RC $(has "$(logf "$T/events")" "\"msg\":\"WARNING: ${W_CLOSED}\"")"

# -----------------------------------------------------------------------------
# the library gate and --help
# -----------------------------------------------------------------------------
mkdir -p "$T/old"
cp "$SN" "$T/old/setup-node.sh"
cp -R "$TN_TEST_REPO/lib" "$T/old/lib"
printf '%s\n' 'unset -f tn_network_config_render' >> "$T/old/lib/common.sh"
RC=0
OUT="$(bash "$T/old/setup-node.sh" --help 2>&1)" || RC=$?
check "library: one without the renderer is refused" "1 yes" "$RC $(has "$OUT" "is older than this setup-node.sh: run update-scripts.sh and try again.")"
RC=0
OUT="$(bash "$SN" --help 2>&1)" || RC=$?
check "--help: both flags" "0 yes yes" "$RC $(has "$OUT" "--admission open|grace|closed") $(has "$OUT" "--trusted-nodes <file>")"
check "--help: the mainnet default and expectation" "yes yes" \
    "$(has "$OUT" "network-config alone on every network, mainnet validators") $(has "$OUT" "Mainnet validators are expected to run")"
check "--help: the read-back keys" "yes yes" "$(has "$OUT" "ADMISSION_MODE for --admission") $(has "$OUT" "TRUSTED_NODES_FILE for")"

finish
