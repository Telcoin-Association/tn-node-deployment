#!/usr/bin/env bash
# =============================================================================
# tools/tests/edit_config_admission_test.sh -- edit-config.sh --set admission=...
# and --set trusted_nodes=..., the node admission settings of network-config:
#
#   the values     admission takes open, grace or closed (the node's Open, Grace,
#                  Closed too) and refuses another word; trusted_nodes takes an
#                  absolute path or none and needs a recorded admission mode;
#   the release    below MIN_ADMISSION_VERSION the edit is refused, naming the
#                  floor, with nothing written; a release that cannot be told
#                  warns and goes on; a docker image is judged by the release
#                  .node-meta records for its digest;
#   the render     tn_network_config_render (the library's own, as the service
#                  user) gets the data dir, the mode, the installed trusted nodes
#                  map or none, and the bootstrap peers map when the node command
#                  loads one; .node-meta records ADMISSION_MODE and
#                  TRUSTED_NODES_FILE as setup-node writes them; the map is
#                  installed root 0644 through tn_write_root_file from a file;
#                  show and the menu reflect the settings; trusted_nodes=none
#                  removes the entry, the map and the record; a bootstrap peers
#                  edit carries committee_peers along;
#   the shape      a malformed trusted nodes map is refused before anything is
#                  written;
#   the restart    the committee guard and the epoch wait run before the
#                  restart, a refusal puts every file back, and a node that does
#                  not come back healthy has network-config, the map and
#                  .node-meta rolled back byte for byte;
#   the library    a lib/common.sh without the renderer is refused up front;
#                  --help names both fields.
#
#   bash tools/tests/edit_config_admission_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/edit_config_admission_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/edit_config_admission_test.sh
#
# A copy of edit-config.sh without its last line (main "$@") is sourced by a
# driver that runs one case per call. The root writers (tn_write_root_file,
# tn_backup_file, tn_restore_backup) are stand-ins that write as the current
# user and log what they were given; systemctl, the committee guard, the epoch
# wait, the lock and tn_launch_runner are stand-ins too. The renderer, meta_get
# and meta_set, edit_backup and the data-dir restore are the real ones, and
# tn_as_service_user runs through the setpriv, id and getent PATH stubs of
# network_config_test.sh (telcoin is uid and gid 991, setpriv runs the command as
# the current user and drops the -T of mv, which busybox and macOS lack).
# Maintainer tooling (not updater-tracked). bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
ORIG_PATH="$PATH"
export ECA_DIR="$T"
FX="$T/fx"
CFG="$FX/etc/telcoin"
DD="$FX/var/lib/telcoin"
NC="$DD/network-config"
META="$CFG/.node-meta"
DEST="$CFG/trusted-nodes.yaml"
PEERS="$CFG/bootstrap-peers.yaml"
LAUNCH="$FX/usr/local/libexec/telcoin/tn-start"
MARKER="$FX/opt/telcoin/telcoin-network.version"

has() {
    case "$1" in
        *"$2"*) echo yes ;;
        *) echo no ;;
    esac
}
# macOS has shasum and no sha256sum; edit_restore_one hashes with sha256sum
if ! command -v sha256sum >/dev/null 2>&1; then
    # shellcheck disable=SC2329  # exported for the driver, which calls it
    sha256sum() { shasum -a 256 "$@"; }
    export -f sha256sum
fi

# ---- the copy of edit-config.sh, the driver and the stubs ---------------------
mkdir -p "$T/ec" "$T/bin" "$T/bk" "$T/in" "$T/snap" "$CFG" "$DD" "$FX/opt/telcoin" \
    "$FX/usr/local/libexec/telcoin" "$FX/etc/systemd/system"
grep -v '^main "\$@"$' "$TN_TEST_REPO/edit-config.sh" > "$T/ec/edit-config.sh"
ln -s "$TN_TEST_REPO/lib" "$T/ec/lib"

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
# log the account options and the command, then run the command as the current
# user; mv loses -T, which busybox and macOS mv lack
opts=""
while [ $# -gt 0 ] && [ "$1" != -- ]; do opts="$opts $1"; shift; done
[ $# -gt 0 ] && shift
printf 'setpriv%s -- %s\n' "$opts" "${1:-}" >> "$TN_NC_CALLS"
if [ "${1:-}" = mv ]; then
    for a in "$@"; do
        shift
        [ "$a" = -T ] || set -- "$@" "$a"
    done
fi
exec "$@"
STUB
chmod 0755 "$T/bin/id" "$T/bin/getent" "$T/bin/setpriv"

cat > "$T/ec/drv.sh" <<'DRV'
# drv.sh CASE [ARG...] -- source the copy of edit-config.sh, then run one case.
TN_ROOT_PREFIX="$ECA_DIR/fx"
source "$ECA_DIR/ec/edit-config.sh"
set +e
SERVICE_USER=telcoin
SERVICE_GROUP=telcoin
JSON_MODE="${ECA_JSON:-false}"
exec 3>>"$ECA_DIR/events"
rec() { printf '%s\n' "$*" >> "$ECA_DIR/calls.log"; }
tn_write_root_file() {
    local how=file
    if [ -p /dev/stdin ]; then how=pipe; fi
    printf '%s %s %s %s\n' "$1" "$2" "${3:-root}" "$how" >> "$ECA_DIR/rootw.log"
    cat > "$1" && chmod "$2" "$1"
}
tn_backup_file() {
    local copy
    copy="$(mktemp "$ECA_DIR/bk/${2:-${1##*/}}.XXXXXX")" || return 2
    cat -- "$1" > "$copy" || return 2
    printf '%s %s\n' "$copy" "$(sha256sum < "$copy" | cut -d' ' -f1)"
}
tn_restore_backup() {
    [ "$(sha256sum < "$1" | cut -d' ' -f1)" = "$2" ] || return 1
    tn_write_root_file "$3" "$4" "${5:-root}" < "$1"
}
# seq_next FILE -- print the first word of FILE and drop it from the file
seq_next() {
    local seq first
    seq="$(cat "$1")"
    first="${seq%% *}"
    if [ "$seq" = "$first" ]; then : > "$1"; else printf '%s' "${seq#* }" > "$1"; fi
    printf '%s\n' "$first"
}
# is-active answers with the next word of active.seq (then 0), show -p
# NRestarts with the next word of nrestarts.seq (then nothing, as a systemd
# without the property)
systemctl() {
    local rc=0
    rec "systemctl $*"
    if [ "$1" = is-active ] && [ -s "$ECA_DIR/active.seq" ]; then
        rc="$(seq_next "$ECA_DIR/active.seq")"
    fi
    if [ "$1 ${2:-} ${3:-}" = "show -p NRestarts" ] && [ -s "$ECA_DIR/nrestarts.seq" ]; then
        seq_next "$ECA_DIR/nrestarts.seq"
    fi
    return "$rc"
}
sleep() { rec "sleep $*"; }
chown() { :; }
tn_committee_down_guard() { rec guard; return "${ECA_GUARD_RC:-0}"; }
tn_wait_restart_window() { rec wait; return 0; }
tn_host_baseline_refresh() { :; }
tn_local_rpc_url() { printf 'http://127.0.0.1:8545\n'; }
tn_launch_runner() { printf '%s\n' "${ECA_SPEC:-binary:$ECA_DIR/fx/opt/telcoin/telcoin-network}"; }
tn_node_has_flag() { return 0; }
tn_node_parse_check() { return 0; }
edit_require_root() { :; }
edit_lock() { EDIT_LOCK_HELD=true; return 0; }
resolve_target() {
    TARGET_SERVICE=telcoin
    TARGET_SERVICE_FILE="$ECA_DIR/fx/etc/systemd/system/telcoin.service"
    TARGET_LAUNCH_FILE="$ECA_DIR/fx/usr/local/libexec/telcoin/tn-start"
}
eval "real_render() $(declare -f tn_network_config_render | sed 1d)"
tn_network_config_render() {
    rec "render $*"
    real_render "$@"
}
NO_EPOCH_WAIT="${ECA_NO_WAIT:-false}"
resolve_target
case "$1" in
    set) EDIT_SET_PAIR="$2"; run_set ;;
    show) show_current_config ;;
    menu-admission) edit_admission ;;
    menu-trusted) edit_trusted_nodes ;;
    menu) main_menu ;;
esac
DRV

# drv CASE [ARG...] -- run the driver with the stubs first on PATH; OUT (stdout
# and stderr together) and RC; the logs start empty.
drv() {
    rm -f "$T/rootw.log" "$T/events"
    : > "$T/calls.log"
    RC=0
    OUT="$(PATH="$T/bin:$ORIG_PATH" bash "$T/ec/drv.sh" "$@" 2>&1 < "${DRV_IN:-/dev/null}")" || RC=$?
}
logf() { if [[ -f "$1" ]]; then cat "$1"; fi; }
calls() { grep -E '^(guard|wait|render|systemctl restart)' "$T/calls.log" | tr '\n' ';'; }
metakey() { grep "^$1=" "$META" 2>/dev/null || true; }
# snap / same -- save network-config, the map and .node-meta, then compare
snap() { local f; for f in "$NC" "$DEST" "$META"; do rm -f "$T/snap/${f##*/}"; [[ ! -e "$f" ]] || cp -p "$f" "$T/snap/${f##*/}"; done; }
same() {
    local f out=""
    for f in "$NC" "$DEST" "$META"; do
        if [[ -e "$T/snap/${f##*/}" ]]; then
            cmp -s "$T/snap/${f##*/}" "$f" || out="${out} ${f##*/}-changed"
        elif [[ -e "$f" ]]; then
            out="${out} ${f##*/}-new"
        fi
    done
    out="${out# }"
    printf '%s\n' "${out:-same}"
}
launch() {  # launch [peers]
    if [[ "${1:-}" == peers ]]; then
        # shellcheck disable=SC2016  # the $(cat ...) belongs in the launch file as text
        printf '#!/bin/bash\nexec /opt/telcoin/telcoin-network node --datadir /var/lib/telcoin --bootstrap-peers "$(cat /etc/telcoin/bootstrap-peers.yaml)" --http -vvv\n' > "$LAUNCH"
    else
        printf '#!/bin/bash\nexec /opt/telcoin/telcoin-network node --datadir /var/lib/telcoin --http -vvv\n' > "$LAUNCH"
    fi
}
# reset [META LINE...] -- the node's default network-config, no map, no peers,
# release v0.17.0, a .node-meta holding DATA_DIR and the lines given
reset() {
    local l
    cp "$T/in/default.yaml" "$NC"
    rm -f "$DEST" "$PEERS" "$T/active.seq" "$T/nrestarts.seq"
    launch
    printf 'v0.17.0\n' > "$MARKER"
    printf 'DATA_DIR=%s\nNETWORK=testnet\n' "$DD" > "$META"
    for l in "$@"; do printf '%s\n' "$l" >> "$META"; done
    chmod 0600 "$META"
    unset ECA_SPEC ECA_GUARD_RC ECA_JSON ECA_NO_WAIT
}

# ---- inputs -------------------------------------------------------------------
K1=pDmpE29YEhr93MPVPCGkWx3BsCcow4oExmxv5viJz2GTjsaXwc3YwKxE1CFdVuTVSudsFDutFSVmtgF98Abs56JZPfGQs6GzbqXDFkGA1eZx2edkwfP2Q6eRLo8coLhvTNj
K2=rZdhyVGJAtz7kyFtFARWVVcw5DB3o9E4GvPN6zuKfUhUBGFRvEK2PgEV44CJt9wu9GMyssFQBFXRknrenuhJixo9KCADrZzHdtcvAwAYDmcLc7Ugh9epGc5LRZC5TK2hnYA
printf 'hostname: '"''"'\nadmission:\n  mode: Open\n  snapshot_max_age_secs: 300\npeer_readiness_timeout:\n  secs: 120\n  nanos: 0\nbootstrap_peers: {}\ntrusted_nodes: {}\ncommittee_peers: {}\n' > "$T/in/default.yaml"
# hub HUB KEY OCTET -- one trusted node entry
hub() {
    printf '%s:\n  primary:\n    network_address: /ip4/203.0.113.%s/udp/49590/quic-v1/p2p/12D3KooWHub%sP\n    network_key: 4XTTMhub%sp\n  workers:\n    0:\n      network_address: /ip4/203.0.113.%s/udp/49594/quic-v1/p2p/12D3KooWHub%sW\n      network_key: 4XTTMhub%sw\n' "$1" "$2" "$2" "$2" "$2" "$2" "$2"
}
{ printf -- '---\n# hubs for the closed validator\n'; hub "$K1" 10; } > "$T/in/t1.yaml"
{ hub "$K1" 10; printf '\n'; hub "$K2" 11; } > "$T/in/t2.yaml"
printf '%s:\n  primary:\n    network_address: /ip4/198.51.100.21/udp/49590/quic-v1/p2p/12D3KooWPeer1P\n    network_key: 4XTTMpeer1p\n  workers:\n    - network_address: /ip4/198.51.100.21/udp/49594/quic-v1/p2p/12D3KooWPeer1W\n      network_key: 4XTTMpeer1w\n' "$K2" > "$T/in/peers.yaml"
chmod 0644 "$T/in/"*.yaml

# ---- admission ------------------------------------------------------------------
reset
drv set admission=closed
check_rc "admission=closed: rc 0" 0 "$RC"
check "admission=closed: network-config holds mode Closed and keeps the lease" \
    "$(printf 'admission:\n  mode: Closed\n  snapshot_max_age_secs: 300')" "$(grep -A2 '^admission:' "$NC")"
check "admission=closed: no trusted nodes and no committee peers written" "0 0" \
    "$(grep -c '^trusted_nodes' "$NC") $(grep -c '^committee_peers' "$NC")"
check "admission=closed: ADMISSION_MODE recorded in lower case" "ADMISSION_MODE=closed" "$(metakey ADMISSION_MODE)"
check "admission=closed: render, guard, wait, guard, restart" \
    "render $DD closed none none;guard;wait;guard;systemctl restart telcoin;" "$(calls)"
check "admission=closed: network-config edited as the service user" yes \
    "$(has "$(logf "$T/calls.log")" "setpriv --reuid 991 --regid 991 --clear-groups --no-new-privs -- sh")"
check "admission=closed: .node-meta written root 0600" "$META 0600 root" "$(grep -F "$META" "$T/rootw.log" | cut -d" " -f1-3 | sort -u)"
check "admission=closed: TRUSTED_NODES_FILE recorded beside the mode, as setup-node writes it" "TRUSTED_NODES_FILE=" "$(metakey TRUSTED_NODES_FILE)"
check "admission=closed: the done line" yes "$(has "$OUT" "applied and telcoin healthy")"
drv show
check "show: the admission mode from network-config" yes "$(has "$OUT" "Admission mode:              Closed")"
check "show: no trusted nodes" yes "$(has "$OUT" "Trusted nodes:               none")"
snap
drv set admission=closed
check "admission=closed again: nothing changed, no restart" "0|yes|" \
    "$RC|$(has "$OUT" "admission is already closed; nothing changed")|$(calls | sed 's/^render[^;]*;//')"
check "admission=closed again: files byte-identical" "same" "$(same)"
drv set admission=Grace
check "admission=Grace: the node's word is taken, kept in lower case" "0 ADMISSION_MODE=grace yes" \
    "$RC $(metakey ADMISSION_MODE) $(has "$(cat "$NC")" "  mode: Grace")"
snap
drv set admission=strict
check "admission=strict: refused, named" "1 yes" "$RC $(has "$OUT" "admission takes open, grace or closed, not strict")"
check "admission=strict: nothing rendered, nothing restarted, files byte-identical" "|same" "$(calls)|$(same)"

# ---- mainnet: closed without trusted nodes warns, as setup-node does ------------
W9="Admission closed without --trusted-nodes: the node admits only the previous, current and next committees and the bootstrap peers. Mainnet validators are expected to run --admission closed --trusted-nodes <hubs>."
# on_mainnet -- NETWORK=mainnet in .node-meta instead of testnet
on_mainnet() { grep -v '^NETWORK=' "$META" > "$T/meta.tmp"; printf 'NETWORK=mainnet\n' >> "$T/meta.tmp"; cat "$T/meta.tmp" > "$META"; }
reset
drv set admission=closed
check "testnet, admission=closed without trusted nodes: no warning" "0 no" "$RC $(has "$OUT" "Admission closed without")"
reset
on_mainnet
drv set admission=closed
check "mainnet, admission=closed without trusted nodes: written, with the warning" "0 yes yes" \
    "$RC $(has "$OUT" "$W9") $(has "$OUT" "Set the hubs with trusted_nodes.")"
drv set admission=grace
check "mainnet, admission=grace without trusted nodes: no warning" "0 no" "$RC $(has "$OUT" "Admission closed without")"
drv set admission=closed
drv set "trusted_nodes=$T/in/t1.yaml"
drv set admission=closed
check "mainnet, admission=closed with trusted nodes: no warning" "0 no" "$RC $(has "$OUT" "Admission closed without")"
export ECA_JSON=true
drv set trusted_nodes=none
check "mainnet, trusted_nodes=none on a closed node: the warning as an event" "0 yes" \
    "$RC $(has "$(logf "$T/events")" "{\"event\":\"warn\",\"msg\":\"$W9")"
unset ECA_JSON
drv set admission=open
drv set trusted_nodes=none
check "mainnet, trusted_nodes=none on an open node: no warning" "0 no" "$RC $(has "$OUT" "Admission closed without")"

# ---- the release ----------------------------------------------------------------
reset
printf 'v0.16.0\n' > "$MARKER"
snap
drv set admission=closed
check "release v0.16.0: refused, naming the floor" "1 yes" \
    "$RC $(has "$OUT" "the admission settings need node release 0.17.0 or later, and this node runs v0.16.0")"
check "release v0.16.0: nothing rendered or restarted, files byte-identical" "|same" "$(calls)|$(same)"
printf 'main\n' > "$MARKER"
drv set admission=closed
check "release unknown (main): warned, then written" "0 yes ADMISSION_MODE=closed" \
    "$RC $(has "$OUT" "could not tell whether the installed release (main) is 0.17.0 or later") $(metakey ADMISSION_MODE)"
D64=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
reset "DOCKER_IMAGE_DIGEST=sha256:$D64" "RELEASE_TAG=v0.16.2"
export ECA_SPEC="docker:ghcr.io/telcoin/telcoin-network@sha256:$D64"
drv set admission=closed
check "docker image of v0.16.2 (recorded for its digest): refused" "1 yes" "$RC $(has "$OUT" "this node runs v0.16.2")"
reset "DOCKER_IMAGE_DIGEST=sha256:$D64" "RELEASE_TAG=v0.17.1"
export ECA_SPEC="docker:ghcr.io/telcoin/telcoin-network@sha256:$D64"
drv set admission=open
check "docker image of v0.17.1: written" "0 ADMISSION_MODE=open" "$RC $(metakey ADMISSION_MODE)"
unset ECA_SPEC

# ---- trusted nodes ----------------------------------------------------------------
reset
snap
drv set "trusted_nodes=$T/in/t1.yaml"
check "trusted_nodes without a mode: refused" "1 yes" "$RC $(has "$OUT" "trusted_nodes needs an admission mode")"
check "trusted_nodes without a mode: nothing written" "|same" "$(calls)|$(same)"
drv set trusted_nodes=relative.yaml
check "trusted_nodes=relative path: refused" "1 yes" "$RC $(has "$OUT" "trusted_nodes takes an absolute path or none")"
reset ADMISSION_MODE=closed
drv set "trusted_nodes=$T/in/t1.yaml"
check_rc "trusted_nodes=FILE: rc 0" 0 "$RC"
check "trusted_nodes=FILE: installed byte for byte" yes "$(cmp -s "$T/in/t1.yaml" "$DEST" && echo yes)"
check "trusted_nodes=FILE: installed root 0644 from a file" "$DEST 0644 root file" "$(grep -F "$DEST" "$T/rootw.log")"
check "trusted_nodes=FILE: rendered with the installed map" "render $DD closed $DEST none;guard;wait;guard;systemctl restart telcoin;" "$(calls)"
check "trusted_nodes=FILE: network-config holds the map under trusted_nodes" "$(printf 'trusted_nodes:\n  # hubs for the closed validator\n  %s:\n    primary:' "$K1")" \
    "$(grep -A3 '^trusted_nodes:' "$NC")"
check "trusted_nodes=FILE: one trusted_nodes entry" 1 "$(grep -c '^trusted_nodes' "$NC")"
check "trusted_nodes=FILE: TRUSTED_NODES_FILE recorded" "TRUSTED_NODES_FILE=$DEST" "$(metakey TRUSTED_NODES_FILE)"
drv show
check "show: the trusted nodes map" yes "$(has "$OUT" "Trusted nodes:               $DEST")"
drv set admission=grace
check "admission=grace with a map: the map is written again" "0 yes" \
    "$RC $(has "$(calls)" "render $DD grace $DEST none")"
# a peers map the node command loads goes in as committee_peers
cp "$T/in/peers.yaml" "$PEERS"
launch peers
drv set admission=closed
check "admission with bootstrap peers: committee_peers from the installed map" "0 yes 1" \
    "$RC $(has "$(calls)" "render $DD closed $DEST $PEERS") $(grep -c '^committee_peers:' "$NC")"
drv set bootstrap_peers=none
check "bootstrap_peers=none with a mode: committee_peers follows" "0 yes 0" \
    "$RC $(has "$(calls)" "render $DD closed $DEST none") $(grep -c '^committee_peers' "$NC")"
drv set "bootstrap_peers=$T/in/peers.yaml"
check "bootstrap_peers=FILE with a mode: committee_peers follows" "0 yes 1" \
    "$RC $(has "$(calls)" "render $DD closed $DEST $PEERS") $(grep -c '^committee_peers:' "$NC")"
drv set trusted_nodes=none
check "trusted_nodes=none: rc 0, no trusted_nodes entry, the map removed" "0 0 gone" \
    "$RC $(grep -c '^trusted_nodes' "$NC") $([[ -e "$DEST" ]] && echo there || echo gone)"
check "trusted_nodes=none: TRUSTED_NODES_FILE emptied, as setup-node writes it" "TRUSTED_NODES_FILE=" "$(metakey TRUSTED_NODES_FILE)"
check "trusted_nodes=none: the mode and committee peers stay" "ADMISSION_MODE=closed 1" "$(metakey ADMISSION_MODE) $(grep -c '^committee_peers:' "$NC")"
snap
drv set trusted_nodes=none
check "trusted_nodes=none again: nothing changed, no restart" "0|yes||same" \
    "$RC|$(has "$OUT" "nothing changed")|$(calls | sed 's/^render[^;]*;//')|$(same)"
reset
drv set trusted_nodes=none
check "trusted_nodes=none, nothing set: no render, no restart, both keys recorded empty" \
    "0||yes|ADMISSION_MODE= TRUSTED_NODES_FILE=" \
    "$RC|$(calls)|$(has "$OUT" "only its record in .node-meta changed, which the node does not read, so telcoin was not restarted")|$(metakey ADMISSION_MODE) $(metakey TRUSTED_NODES_FILE)"
snap
drv set trusted_nodes=none
check "trusted_nodes=none, nothing set, again: nothing changed" "0 yes same" "$RC $(has "$OUT" "nothing changed") $(same)"
# an older .node-meta without TRUSTED_NODES_FILE, network-config already Closed:
# the key is filled in, and the node is not restarted for it
reset
drv set admission=closed
grep -v '^TRUSTED_NODES_FILE=' "$META" > "$T/meta.tmp"
cat "$T/meta.tmp" > "$META"
export ECA_JSON=true
drv set admission=closed
check "admission=closed, the node already Closed, the key absent: recorded, no restart" "0||TRUSTED_NODES_FILE=" \
    "$RC|$(calls | sed 's/^render[^;]*;//')|$(metakey TRUSTED_NODES_FILE)"
check "admission=closed, only .node-meta changed: the done event" yes \
    "$(has "$(logf "$T/events")" '"event":"done","ok":true,"field":"admission","value":"closed","msg":"admission is already closed for the node; only its record in .node-meta changed')"
unset ECA_JSON
grep -v '^TRUSTED_NODES_FILE=' "$META" > "$T/meta.tmp"
cat "$T/meta.tmp" > "$META"
DRV_IN="$T/in/menu.txt"
printf '3\n\n' > "$DRV_IN"
drv menu-admission
check "menu: Closed again, the key absent: recorded, no restart offered" "TRUSTED_NODES_FILE=||yes" \
    "$(metakey TRUSTED_NODES_FILE)|$(calls | sed 's/^render[^;]*;//')|$(has "$OUT" "only its record in .node-meta changed, which the node does not read, so no restart is needed")"
DRV_IN=""

# ---- the shape: refused before anything is written ----------------------------
# bad NAME WANT -- $T/in/bad.yaml is refused naming WANT, nothing written
bad() {
    chmod 0644 "$T/in/bad.yaml"
    snap
    drv set "trusted_nodes=$T/in/bad.yaml"
    check "malformed map (${1}): refused" "1 yes" "$RC $(has "$OUT" "$2")"
    check "malformed map (${1}): nothing written or restarted" "|same" "$(logf "$T/rootw.log")$(calls)|$(same)"
}
reset ADMISSION_MODE=closed
printf '0x%s:\n  primary:\n    network_address: /ip4/1.2.3.4/udp/1/quic-v1\n    network_key: k\n  workers: {}\n' "${K1:0:20}" > "$T/in/bad.yaml"
bad "0x-prefixed key" "is not a BLS public key (base58"
hub "$K1" 10 | grep -v network_key > "$T/in/bad.yaml"
bad "no network_key" "has no network_key"
hub "$K1" 10 | head -n 4 > "$T/in/bad.yaml"
bad "no workers" "has no workers"
{ hub "$K1" 10; printf '  name: hub-a\n'; } > "$T/in/bad.yaml"
bad "unknown field" "name is not a field of a trusted node"
{ hub "$K1" 10; hub "$K1" 12; } > "$T/in/bad.yaml"
bad "key twice" "is in the map twice"
printf '{"%s": {"primary": {}}}\n' "$K1" > "$T/in/bad.yaml"
bad "flow style" "is not a BLS public key and a colon"
hub "$K1" 10 | awk '{ sub(/^    network_address/, "\tnetwork_address"); print }' > "$T/in/bad.yaml"
bad "tab indent" "is indented with a tab"
printf '%s:\n  primary: {network_address: /ip4/1.2.3.4/udp/1/quic-v1, network_key: k}\n  workers: {}\n' "$K1" > "$T/in/bad.yaml"
bad "flow primary" "write primary as a block"
hub "$K1" 10 | sed 's|network_address: .*|network_address: ~|' > "$T/in/bad.yaml"
bad "null address" "the network_address of"
{ hub "$K1" 10; printf -- '---\n'; hub "$K2" 11; } > "$T/in/bad.yaml"
bad "second document" "starts a second YAML document"
hub "$K1" 10 | awk '{ printf "%s\r\n", $0 }' > "$T/in/bad.yaml"
bad "CRLF" "ends in a carriage return"
printf '# no hubs yet\n---\n' > "$T/in/bad.yaml"
bad "no entries" "holds no BLS public key entries"
printf '  %s:\n' "$K1" > "$T/in/bad.yaml"
bad "indented first line" "no BLS public key comes before it"
# VD6: maps the node refuses that an earlier check let through
{ hub "${K1%?}" 10; } > "$T/in/bad.yaml"
bad "key of 130 characters" "is not a BLS public key: it is 130 characters long, and a key is 131 or 132"
hub abc 10 > "$T/in/bad.yaml"
bad "key of 3 characters" "it is 3 characters long"
# prim KEY / wk ID -- a primary block, and one worker entry
prim() { printf '%s:\n  primary:\n    network_address: /ip4/203.0.113.10/udp/49590/quic-v1/p2p/12D3KooWHubP\n    network_key: 4XTTMhubp\n' "$1"; }
wk() { printf '    %s:\n      network_address: /ip4/203.0.113.10/udp/49594/quic-v1/p2p/12D3KooWHubW\n      network_key: 4XTTMhubw\n' "$1"; }
{ prim "$K1"; printf '  workers:\n'; wk zero; } > "$T/in/bad.yaml"
bad "worker id not a number" "zero is not a worker id; the workers of"
{ prim "$K1"; printf '  workers:\n'; wk 70000; } > "$T/in/bad.yaml"
bad "worker id past 65535" "70000 is not a worker id"
{ prim "$K1"; printf '  workers:\n'; wk '"0"'; } > "$T/in/bad.yaml"
bad "worker id quoted" "is not a worker id"
for v in '~' '{}' 0; do
    { prim "$K1"; printf '  workers: %s\n' "$v"; } > "$T/in/bad.yaml"
    bad "workers: ${v}" "write workers as a block"
done
{ prim "$K1"; printf '  workers:\n    - network_address: /ip4/203.0.113.10/udp/1/quic-v1\n      network_key: k\n'; } > "$T/in/bad.yaml"
bad "workers a sequence" "is not a worker id"
{ prim "$K1"; printf '  workers:\n'; } > "$T/in/bad.yaml"
bad "workers with no id" "name no worker id"
{ prim "$K1"; printf '  workers:\n'; hub "$K2" 11; } > "$T/in/bad.yaml"
bad "workers with no id, then the next entry" "name no worker id"
{ prim "$K1"; printf '  workers:\n'; wk 0; wk 0; } > "$T/in/bad.yaml"
bad "worker id twice" "has worker 0 twice"
{ prim "$K1"; printf '  workers:\n'; wk 0 | grep -v network_key; } > "$T/in/bad.yaml"
bad "worker without network_key" "worker 0 of"
{ prim "$K1"; printf '  workers:\n'; wk 0 | grep -v network_address; printf '  primary:\n'; } > "$T/in/bad.yaml"
bad "worker without network_address, then another field" "has no network_address"
{ prim "$K1"; printf '  workers:\n    0: {network_address: /ip4/203.0.113.10/udp/1/quic-v1, network_key: k}\n'; } > "$T/in/bad.yaml"
bad "worker in flow style" "write worker 0 of"
{ prim "$K1"; printf '  workers:\n'; wk 0 | sed 's|network_address: .*|network_address: ""|'; } > "$T/in/bad.yaml"
bad "worker with an empty network_address" "the network_address of worker 0 of"
# what the node takes: a 132-character key, several workers, the last id 65535
{ prim "${K1}a"; printf '  workers:\n'; wk 0; wk 1; printf '    65535:   # the last id\n      network_address: /ip4/203.0.113.10/udp/49599/quic-v1\n      network_key: 4XTTMhubx\n      rpc: {}\n'; } > "$T/in/good.yaml"
chmod 0644 "$T/in/good.yaml"
drv set "trusted_nodes=$T/in/good.yaml"
check "a 132-character key and workers 0, 1 and 65535: installed" "0 yes" "$RC $(cmp -s "$T/in/good.yaml" "$DEST" && echo yes)"
hub "$K1" 10 > "$T/in/bad.yaml"
chmod 0600 "$T/in/bad.yaml"
snap
drv set "trusted_nodes=$T/in/bad.yaml"
check "map other users cannot read: refused, nothing written" "1|yes||same" \
    "$RC|$(has "$OUT" "other users cannot read it")|$(calls)|$(same)"

# ---- the restart window and the rollback ----------------------------------------
reset ADMISSION_MODE=closed
drv set "trusted_nodes=$T/in/t1.yaml"
snap
export ECA_GUARD_RC=1 ECA_JSON=true
drv set admission=open
check "committee guard refuses: rc 1, no restart" "1 guard;" "$RC $(calls | sed 's/^render[^;]*;//')"
check "committee guard refuses: every file put back byte for byte" "same" "$(same)"
check "committee guard refuses: the done event says rolled back" yes \
    "$(has "$(logf "$T/events")" '"event":"done","ok":false,"rolled_back":true,"field":"admission"')"
unset ECA_GUARD_RC
export ECA_NO_WAIT=true
printf '1 0' > "$T/active.seq"
drv set "trusted_nodes=$T/in/t2.yaml"
check "failed verify: rc 1, the restart then the rollback restart, no epoch wait" \
    "1 render $DD closed $DEST none;guard;systemctl restart telcoin;systemctl restart telcoin;" "$RC $(calls)"
check "failed verify: network-config, the map and .node-meta rolled back byte for byte" "same" "$(same)"
check "failed verify: the done event" yes \
    "$(has "$(logf "$T/events")" '"event":"done","ok":false,"rolled_back":true,"field":"trusted_nodes","msg":"restart failed; rolled back to the previous configuration"')"
check "failed verify: network-config written back as the service user" yes \
    "$(has "$(logf "$T/calls.log")" "setpriv --reuid 991 --regid 991 --clear-groups --no-new-privs -- mv")"
printf '1 0' > "$T/active.seq"
drv set admission=grace
check "failed verify of a mode change: rolled back" "1|same|ADMISSION_MODE=closed" "$RC|$(same)|$(metakey ADMISSION_MODE)"
unset ECA_JSON ECA_NO_WAIT

# the watch: an edit that writes network-config is watched for
# TN_EDIT_VERIFY_TIMEOUT seconds (default 60) after the 3-second check, in 5 s
# polls of is-active and NRestarts; a failed poll rolls back like a failed check
sleeps() { grep '^sleep ' "$T/calls.log" | sed 's/^sleep //' | tr '\n' ' '; }
nact() { grep -c '^systemctl is-active' "$T/calls.log" || true; }
nshow() { grep -c '^systemctl show -p NRestarts --value telcoin$' "$T/calls.log" || true; }
reset
drv set admission=closed
check "watch: admission=closed sleeps 3s, then twelve polls of 5s" "3 5 5 5 5 5 5 5 5 5 5 5 5 " "$(sleeps)"
check "watch: is-active 13 times, NRestarts read after the restart and at each poll" "13 13" "$(nact) $(nshow)"
check "watch: the step names the window" yes "$(has "$OUT" "Watching telcoin for 60s")"
export TN_EDIT_VERIFY_TIMEOUT=12
reset
drv set admission=closed
check "watch: TN_EDIT_VERIFY_TIMEOUT=12 polls at 5, 5 and 2s" "0|3 5 5 2 |4" "$RC|$(sleeps)|$(nact)"
export TN_EDIT_VERIFY_TIMEOUT=0
reset
drv set admission=closed
check "watch: TN_EDIT_VERIFY_TIMEOUT=0 keeps the single check at 3s" "0|3 |1" "$RC|$(sleeps)|$(nact)"
unset TN_EDIT_VERIFY_TIMEOUT
reset
drv set state_export=unlimited
check "watch: an edit that leaves network-config alone keeps the single check" "0|3 |1|no" \
    "$RC|$(sleeps)|$(nact)|$(has "$OUT" "Watching")"
reset ADMISSION_MODE=closed
cp "$T/in/peers.yaml" "$PEERS"
launch peers
drv set bootstrap_peers=none
check "watch: bootstrap_peers=none with a mode writes network-config, so it is watched too" "0 13" "$RC $(nact)"
reset ADMISSION_MODE=closed
drv set "trusted_nodes=$T/in/t1.yaml"
snap
export ECA_JSON=true
printf '0 0 0 0 1' > "$T/nrestarts.seq"
drv set "trusted_nodes=$T/in/t2.yaml"
check "watch: NRestarts 0 to 1 at the fourth poll, the unit active: rc 1, rolled back byte for byte" "1 same" "$RC $(same)"
check "watch: the edit's restart, then the rollback restart" \
    "render $DD closed $DEST none;guard;wait;guard;systemctl restart telcoin;systemctl restart telcoin;" "$(calls)"
check "watch: the warning names the restarts" yes \
    "$(has "$(logf "$T/events")" 'restarted by itself within 23s of the restart (NRestarts 0 to 1)')"
check "watch: the done event" yes \
    "$(has "$(logf "$T/events")" '"rolled_back":true,"field":"trusted_nodes","msg":"restart failed; rolled back to the previous configuration"')"
printf '0 0 0 0 0 1 0' > "$T/active.seq"
drv set "trusted_nodes=$T/in/t2.yaml"
check "watch: inactive at the fifth poll: rc 1, rolled back byte for byte, said when" "1 same yes" \
    "$RC $(same) $(has "$(logf "$T/events")" 'is not active 28s after the restart')"
unset ECA_JSON

# ---- the menu --------------------------------------------------------------------
reset ADMISSION_MODE=open
DRV_IN="$T/in/menu.txt"
printf '3\nn\n\n' > "$DRV_IN"
drv menu-admission
check "menu: Closed chosen and saved, the restart left for later" "0|ADMISSION_MODE=closed||yes" \
    "$RC|$(metakey ADMISSION_MODE)|$(calls | sed 's/^render[^;]*;//')|$(has "$(cat "$NC")" "  mode: Closed")"
check "menu: shows the mode before the change" yes "$(has "$OUT" "Current: Open")"
printf '15\n' > "$DRV_IN"
drv menu
check "menu: items 11 and 12, exit at 15" "yes yes yes" \
    "$(has "$OUT" "11) Admission mode") $(has "$OUT" "12) Trusted nodes") $(has "$OUT" "15) Exit")"
DRV_IN=""
# a menu edit the node does not come back from is put back, as --set does
reset ADMISSION_MODE=closed
drv set "trusted_nodes=$T/in/t1.yaml"
snap
printf '1 0' > "$T/active.seq"
DRV_IN="$T/in/menu.txt"
printf '%s\ny\n\n' "$T/in/t2.yaml" > "$DRV_IN"
drv menu-trusted
check "menu: the node does not come back: every file put back byte for byte" same "$(same)"
check "menu: the restart, then the rollback restart without the epoch wait" \
    "render $DD closed $DEST none;guard;wait;guard;systemctl restart telcoin;systemctl restart telcoin;" "$(calls)"
check "menu: says the edit was put back" yes "$(has "$OUT" "Node failed to restart with the edit, so the edit was put back")"
printf '0 0 1' > "$T/nrestarts.seq"
printf '1\ny\n\n' > "$DRV_IN"
drv menu-admission
check "menu: watched too: NRestarts grows, the mode change is put back" "same|ADMISSION_MODE=closed|yes" \
    "$(same)|$(metakey ADMISSION_MODE)|$(has "$OUT" "restarted by itself within 13s")"
printf '1 1' > "$T/active.seq"
printf '%s\ny\n\n' "$T/in/t2.yaml" > "$DRV_IN"
drv menu-trusted
check "menu: the rollback restart fails too: files put back, said so" "same yes" \
    "$(same) $(has "$OUT" "and again after the edit was put back")"
DRV_IN=""

# ---- the library and --help -----------------------------------------------------
help="$(bash "$TN_TEST_REPO/edit-config.sh" --help 2>&1)"
check "--help names admission and trusted_nodes" "yes yes" \
    "$(has "$help" "admission=open|grace|closed") $(has "$help" "trusted_nodes=<path>|none")"
mkdir -p "$T/old"
cp -R "$TN_TEST_REPO/lib" "$T/old/lib"
sed 's/^tn_network_config_render() {/tn_ncr_gone() {/' "$TN_TEST_REPO/lib/common.sh" > "$T/old/lib/common.sh"
cp "$TN_TEST_REPO/edit-config.sh" "$T/old/edit-config.sh"
RC=0
OUT="$(bash "$T/old/edit-config.sh" --json --set admission=closed 2>&1)" || RC=$?
check "a library without the renderer: refused up front" "1 yes" "$RC $(has "$OUT" "is older than this edit-config.sh")"

finish
