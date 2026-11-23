#!/usr/bin/env bash
# =============================================================================
# tools/tests/bootstrap_servers_test.sh -- the testnet bootstrap servers from
# the pinned chain-config tag. telcoin-network #1848 moved them out of
# committee.yaml into chain-configs/<network>/bootstrap_servers.yaml, which the
# node reads only with --chain; these scripts start it without. So:
#
#   the pin        TESTNET_BOOTSTRAP_SERVERS_SHA256 is empty while the pinned
#                  tag keeps the servers in committee.yaml, and the fixture
#                  files of that tag (genesis.d/testnet) have no such file;
#                  mainnet has no pin and its file is never read;
#   the fetch      tn_chain_configs_from_tag with no pin installs the three
#                  files exactly as before and refuses a tag that carries the
#                  file; with a pin it reads, checks and installs the file with
#                  the three, refuses a changed one and a tag without one, and
#                  runs no git once all four are in place;
#   setup          setup_default_bootstrap_peers, from step_write_config, makes
#                  the pinned copy the run's peers map when the run has none:
#                  prepare_node_extra_flags then has the release parse it,
#                  installs it as CONFIG_DIR/bootstrap-peers.yaml, records it
#                  and puts --bootstrap-peers "$(cat ...)" on the start line; a
#                  missing, changed, unreadable or rejected file stops setup
#                  before the copy; --bootstrap-peers, a map the host recorded
#                  and mainnet get no default; with no pin nothing changes.
#
# The pin is tn_bootstrap_servers_pin, replaced after the cases of the real
# (empty) one by a function that prints BS_PIN for testnet. git is a stand-in
# that records argv and serves the files of BS_BLOBS as the tag's
# chain-configs/testnet. A copy of setup-node.sh without its last line
# (main "$@") is sourced at the top level; the root writers write as this
# account, chown is a no-op and the release's parser is a stand-in.
#
#   bash tools/tests/bootstrap_servers_test.sh
#
# Maintainer tooling: not tracked by update-scripts.sh, no .sha256 sidecar.
# bash 3.2 safe.
# =============================================================================
# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
FX="$TN_TEST_DIR/genesis.d/testnet"
umask 022
mkdir -p "$T/sn" "$T/bin" "$T/stg" "$T/rec" "$T/pfx" "$T/src/.git" "$T/in" "$T/data"
chmod 0700 "$T/stg"
grep -v '^main "\$@"$' "$TN_TEST_REPO/setup-node.sh" > "$T/sn/setup-node.sh"
ln -s "$TN_TEST_REPO/lib" "$T/sn/lib"
TN_ROOT_PREFIX="$T/pfx"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/sn/setup-node.sh"
set +eu  # setup-node.sh makes SERVICE_NAME readonly; tn_test_post_common would assign it
# shellcheck disable=SC2034  # read by tn_staging_dir
TN_RELEASE_STAGING_DIR="$T/stg"
unset GIT_DIR GIT_WORK_TREE CONFIG_DIR TN_GENESIS_DIR
REC="$T/rec"
TAG="$TESTNET_CHAIN_CONFIGS_TAG"
D="$(tn_chain_configs_dir testnet)"
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# ---- the stand-ins --------------------------------------------------------------------
# git: argv to git.argv; fetch and rev-parse succeed; cat-file blob REF:PATH prints
# BS_BLOBS/<name> for chain-configs/testnet/<name>, or fails as git does; ls-tree
# prints its path when BS_BLOBS holds the name.
cat > "$T/bin/git" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$BS_REC/git.argv"
if [ "$1" = -C ]; then shift 2; fi
last=""
for a in "$@"; do last="$a"; done
case "$1" in
    cat-file)
        p="${3#*:}"
        case "$p" in chain-configs/testnet/*) ;; *) exit 128 ;; esac
        if [ -f "$BS_BLOBS/${p##*/}" ]; then cat "$BS_BLOBS/${p##*/}"; exit 0; fi
        printf "fatal: path '%s' does not exist in '%s'\n" "$p" "${3%%:*}" >&2
        exit 128
        ;;
    ls-tree)
        if [ -f "$BS_BLOBS/${last##*/}" ]; then printf '%s\n' "$last"; fi
        ;;
esac
exit 0
EOF
chmod 0755 "$T/bin/git"
PATH="$T/bin:$PATH"
BS_REC="$REC"
BS_BLOBS="$T/blobs"
export BS_REC BS_BLOBS
tn_write_root_file() { printf '%s %s\n' "$1" "$2" >> "$REC/rootw"; cat > "$1" && chmod "$2" "$1"; }
_tn_root_layout_dir() { mkdir -p -- "$1" && chmod "$3" "$1"; }
chown() { :; }
tn_as_service_user() { "$@"; }
write_advertised_name() { :; }
node_runner_spec() { printf 'binary:/opt/telcoin/telcoin-network\n'; }
tn_node_has_flag() { printf '%s\n' "$2" >> "$REC/hasflag"; return 0; }
# the release's parser: logs the map it was given; PARSE_RC 1 rejects it
PARSE_RC=0
tn_node_parse_check() {
    printf '%s\n' "$3" > "$REC/parsed"
    [[ "$PARSE_RC" == 0 ]] && return 0
    printf 'expected valid bls public key bytes'
    return 1
}
# shellcheck disable=SC2034  # read by the sourced setup-node.sh and lib/common.sh
{
    JSON_MODE=true
    SERVICE_USER="$(id -un)"
    NETWORK=testnet
    INSTALL_METHOD=existing
    BINARY_PATH=/opt/telcoin/telcoin-network
    PASSPHRASE_METHOD=stdin
    LOG_TARGET="file"
}
exec 3>/dev/null
CFG="$T/cfg"
DATA_DIR="$T/data"

# The three fixture files at the tag, and the node's form of bootstrap_servers.yaml: a
# comment header, a document marker, then the map.
blobs() {  # blobs [bootstrap_servers.yaml source] -- what the tag holds
    rm -rf "$BS_BLOBS"
    mkdir -p "$BS_BLOBS"
    cp "$FX"/*.yaml "$BS_BLOBS/"
    [[ -z "${1:-}" ]] || cp "$1" "$BS_BLOBS/bootstrap_servers.yaml"
}
cat > "$T/in/bs.yaml" <<'BS'
# Bootstrap servers for the test network, built into the binary.
#
# `network-config`'s `bootstrap_peers` and the node's `--bootstrap-peers` flag override it.
---
ServerBLSkey1:
  primary:
    network_address: /ip4/198.51.100.31/udp/49590/quic-v1/p2p/12D3KooWServer1P
    network_key: 4XTTMserver1p
  workers:
    - network_address: /ip4/198.51.100.31/udp/49594/quic-v1/p2p/12D3KooWServer1W
      network_key: 4XTTMserver1w
BS
sed 's/198.51.100.31/198.51.100.99/' "$T/in/bs.yaml" > "$T/in/bs-other.yaml"
cat > "$T/in/own.yaml" <<'OWN'
OwnBLSkey1:
  primary:
    network_address: /ip4/203.0.113.41/udp/49590/quic-v1/p2p/12D3KooWOwn1P
    network_key: 4XTTMown1p
  workers:
    - network_address: /ip4/203.0.113.41/udp/49594/quic-v1/p2p/12D3KooWOwn1W
      network_key: 4XTTMown1w
OWN
chmod 0644 "$T/in"/*.yaml
BS_SHA="$(sha256sum < "$T/in/bs.yaml")"
BS_SHA="${BS_SHA%% *}"
OTHER_SHA="$(sha256sum < "$T/in/bs-other.yaml")"
OTHER_SHA="${OTHER_SHA%% *}"

reset() { rm -rf "${T:?}/pfx" "$REC" "$CFG" "$DATA_DIR"; mkdir -p "$T/pfx" "$REC" "$CFG" "$DATA_DIR"; }
verbs() { awk '{ i = 1; if ($1 == "-C") i = 3; s = s (NR > 1 ? " " : "") $i } END { print s }' "$REC/git.argv" 2>/dev/null; }
listing() { ls -A "$1" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'; }
# ft -- tn_chain_configs_from_tag on $T/src in a subshell: FT_RC, FT_OUT (stdout,
# stderr and the progress lines).
pf() { printf '%s|%s\n' "$1" "$2" >> "$REC/pf"; }
ft() {
    local rc=0
    ( tn_chain_configs_from_tag "$T/src" "${1:-testnet}" pf; printf 'returned %s\n' "$?" ) > "$T/out" 2>&1 || rc=$?
    FT_RC="$(sed -n 's/^returned //p' "$T/out")"
    [[ -n "$FT_RC" ]] || FT_RC="exit $rc"
    FT_OUT="$(grep -v '^returned ' "$T/out"; cat "$REC/pf" 2>/dev/null)"
}
# sn STEPS... -- run setup-node functions in a subshell (setup_fail exits it), then
# print SRC, the flags and BOOTSTRAP_PEERS_FILE of .node-meta: SN_RC, SN_OUT, SN_VARS.
sn() {
    local rc=0
    ( set +u
      CONFIG_DIR="$CFG"
      for step in "$@"; do $step; done
      printf 'SRC=%s\nFLAGS=%s\nMETA=%s\n' "$BOOTSTRAP_PEERS_SRC" "$NODE_EXTRA_FLAGS" \
          "$(grep '^BOOTSTRAP_PEERS_FILE=' "$CFG/.node-meta" 2>/dev/null)" > "$T/vars"
    ) > "$T/out" 2>&1 || rc=$?
    SN_RC="$rc"
    SN_OUT="$(cat "$T/out")"
    SN_VARS="$(cat "$T/vars" 2>/dev/null)"
    rm -f "$T/vars"
}
# the steps sn runs: the chain configs from a directory (--genesis-dir), then the
# node flags as step_create_service builds them
write_from_bs() { TN_GENESIS_DIR="$T/gd" step_write_config; }
prepare() { prepare_node_extra_flags; }
# shellcheck disable=SC2034  # read by json_mode
interactive() { JSON_MODE=false; }
# gd [bootstrap_servers.yaml source] -- the --genesis-dir: the three files, and the
# bootstrap servers file when given
gd() { rm -rf "$T/gd"; mkdir -p "$T/gd"; cp "$FX"/*.yaml "$T/gd/"; [[ -z "${1:-}" ]] || cp "$1" "$T/gd/bootstrap_servers.yaml"; }
PEERS_LINE="--bootstrap-peers \"\$(cat ${CFG}/bootstrap-peers.yaml)\""
start_line_peers() {  # the --bootstrap-peers value the start script renders for FLAGS
    CONFIG_DIR="$CFG" _tn_start_script_text source /opt/telcoin/telcoin-network "--datadir ${DATA_DIR} --http --http.addr 127.0.0.1 $1" > "$T/tn-start" 2>/dev/null \
        && tn_launch_flag_get "$T/tn-start" --bootstrap-peers 2>/dev/null
}

# ---- the pin as shipped ----------------------------------------------------------------
check "pin: the testnet pin is empty while ${TAG} keeps the servers in committee.yaml" "" "$TESTNET_BOOTSTRAP_SERVERS_SHA256"
check "pin: the fixture files of ${TAG} carry no bootstrap_servers.yaml" no \
    "$([[ -e "$FX/bootstrap_servers.yaml" ]] && echo yes || echo no)"
rc=0; out="$(tn_bootstrap_servers_pin testnet)" || rc=$?
check "pin: testnet, nothing pinned (rc 0)" "0 " "$rc $out"
for n in mainnet devnet garbage ""; do
    rc=0; out="$(tn_bootstrap_servers_pin "$n")" || rc=$?
    check "pin: '${n}' is never read (rc 1)" "1 " "$rc $out"
done
check "pin: lib/common.sh has no mainnet bootstrap servers pin" no \
    "$(grep -q 'MAINNET_BOOTSTRAP' "$TN_TEST_REPO/lib/common.sh" && echo yes || echo no)"
check "files: testnet, nothing pinned: the three" "genesis.yaml committee.yaml parameters.yaml" \
    "$(_tn_chain_configs_files testnet | tr '\n' ' ' | sed 's/ $//')"
mkdir -p "$T/junk"
printf 'not the servers\n' > "$T/junk/bootstrap_servers.yaml"
rc=0; tn_bootstrap_servers_check "$T/junk" testnet pf || rc=$?
check_rc "check: nothing pinned, nothing to check" 0 "$rc"

# ---- the fetch as shipped: no pin -----------------------------------------------------
reset; blobs
ft
check "no pin, tag without the file: rc 0, git fetches, reads three and lists one" "0|fetch rev-parse cat-file cat-file cat-file ls-tree" \
    "$FT_RC|$(verbs)"
check "no pin, tag without the file: the three installed, nothing else" "committee.yaml genesis.yaml parameters.yaml" "$(listing "$D")"
check "no pin, tag without the file: the messages are the ones before" \
"step|Fetching ${TAG} from origin for the chain configs...
log|Installed the testnet chain configs from ${TAG} into ${D}." "$FT_OUT"
reset; blobs "$T/in/bs.yaml"
ft
check "no pin, the tag carries the file: refused (rc 1)" 1 "$FT_RC"
check_has "no pin, the tag carries the file: the reason" \
    "warn|${TAG} carries chain-configs/testnet/bootstrap_servers.yaml, but these scripts pin no sha256 for it; nothing was installed." "$FT_OUT"
check "no pin, the tag carries the file: nothing installed" "" "$(listing "$D")"
check "no pin: staging is empty" "" "$(listing "$T/stg")"

# ---- the setup side as shipped: no pin ---------------------------------------------------
reset; gd "$T/in/bs.yaml"
sn write_from_bs prepare
check "setup, no pin: the run goes on with no peers map" "0
SRC=
FLAGS=
META=BOOTSTRAP_PEERS_FILE=" "$SN_RC
$SN_VARS"
check_lacks "setup, no pin: no bootstrap servers line" "Bootstrap peers:" "$SN_OUT"
check "setup, no pin: no peers map installed" no "$([[ -e "$CFG/bootstrap-peers.yaml" ]] && echo yes || echo no)"
# A re-run over a host whose map is recorded, with no admission mode, drops it as before.
reset; gd; cp "$T/in/own.yaml" "$CFG/bootstrap-peers.yaml"
printf 'BOOTSTRAP_PEERS_FILE=%s\n' "$CFG/bootstrap-peers.yaml" > "$CFG/.node-meta"
sn interactive prepare write_from_bs
check "setup, no pin: an interactive re-run without an admission mode reads no map back, as before" "0
SRC=
FLAGS=
META=BOOTSTRAP_PEERS_FILE=" "$SN_RC
$SN_VARS"

# ---- from here on testnet pins BS_PIN ------------------------------------------------------
BS_PIN="$BS_SHA"
tn_bootstrap_servers_pin() {
    case "${1:-}" in
        testnet) [[ -z "$BS_PIN" ]] || printf '%s\n' "$BS_PIN" ;;
        *) return 1 ;;
    esac
    return 0
}
check "files: testnet with a pin: four" "genesis.yaml committee.yaml parameters.yaml bootstrap_servers.yaml" \
    "$(_tn_chain_configs_files testnet | tr '\n' ' ' | sed 's/ $//')"
check "files: mainnet stays three" "genesis.yaml committee.yaml parameters.yaml" \
    "$(_tn_chain_configs_files mainnet | tr '\n' ' ' | sed 's/ $//')"

reset; blobs "$T/in/bs.yaml"
ft
check "pin, the tag carries the file: rc 0, read with the three" "0|fetch rev-parse cat-file cat-file cat-file cat-file" "$FT_RC|$(verbs)"
check "pin: four files installed" "bootstrap_servers.yaml committee.yaml genesis.yaml parameters.yaml" "$(listing "$D")"
check "pin: the file installed byte for byte, root 0644" "yes ${D}/bootstrap_servers.yaml 0644" \
    "$(cmp -s "$T/in/bs.yaml" "$D/bootstrap_servers.yaml" && echo yes || echo no) $(grep bootstrap_servers "$REC/rootw")"
: > "$REC/git.argv"; : > "$REC/pf"
ft
check "pin, all four in place: rc 0, no git" "0|" "$FT_RC|$(verbs)"
rm -f "$D/bootstrap_servers.yaml"; : > "$REC/git.argv"; : > "$REC/pf"
ft
check "pin, the three in place without the file: fetched again" "0|fetch rev-parse cat-file cat-file cat-file cat-file|yes" \
    "$FT_RC|$(verbs)|$(cmp -s "$T/in/bs.yaml" "$D/bootstrap_servers.yaml" && echo yes || echo no)"
reset; blobs "$T/in/bs-other.yaml"
ft
check "pin, a changed file at the tag: refused (rc 1)" 1 "$FT_RC"
check_has "pin, changed: the file named by tag, with both hashes" \
    "warn|chain-configs/testnet/bootstrap_servers.yaml at ${TAG}: sha256 ${OTHER_SHA}, expected ${BS_SHA} (testnet)." "$FT_OUT"
check_has "pin, changed: nothing installed" "warn|The testnet chain configs at ${TAG} do not match the pins; nothing was installed." "$FT_OUT"
check "pin, changed: the destination is untouched" "" "$(listing "$D")"
reset; blobs
ft
check "pin, the tag has no file: rc 2, named" "2 yes" "$FT_RC $(has "$FT_OUT" "warn|${TAG} has no chain-configs/testnet/bootstrap_servers.yaml.")"
check "pin, no file: nothing installed" "" "$(listing "$D")"
reset; blobs "$T/in/bs.yaml"; mkdir -p "$D/bootstrap_servers.yaml"
ft
check "pin: a directory in the file's place is refused before any git (rc 2)" "2|" "$FT_RC|$(verbs)"
check "pin: staging is empty" "" "$(listing "$T/stg")"
# Mainnet: no tag, and no bootstrap servers file is ever asked for.
reset; blobs "$T/in/bs.yaml"
ft mainnet
check "mainnet: refused as before, no git" "1|" "$FT_RC|$(verbs)"
rc=0; tn_bootstrap_servers_check "$T/junk" mainnet pf || rc=$?
check_rc "mainnet: nothing to check" 0 "$rc"

# ---- setup with a pin -------------------------------------------------------------------------
# A new node with no map: the copy beside the chain configs becomes its map.
reset; gd "$T/in/bs.yaml"
sn write_from_bs prepare
check "setup, pin, no map: the default is installed, recorded and on the start line" "0
SRC=${CFG}/bootstrap-peers.yaml
FLAGS=${PEERS_LINE}
META=BOOTSTRAP_PEERS_FILE=${CFG}/bootstrap-peers.yaml" "$SN_RC
$SN_VARS"
check "setup, pin, no map: one line says where the peers come from" yes \
    "$(has "$SN_OUT" "Bootstrap peers: the testnet bootstrap servers at ${TAG} (no --bootstrap-peers given)")"
check "setup, pin, no map: the installed map is the pinned file, byte for byte" yes \
    "$(cmp -s "$T/in/bs.yaml" "$CFG/bootstrap-peers.yaml" && echo yes || echo no)"
check "setup, pin, no map: the release parsed the map and has the flag" "yes --bootstrap-peers" \
    "$(cmp -s "$T/in/bs.yaml" "$REC/parsed" && echo yes || echo no) $(cat "$REC/hasflag")"
check "setup, pin, no map: the chain configs were copied" yes \
    "$(cmp -s "$FX/committee.yaml" "$DATA_DIR/genesis/committee.yaml" && echo yes || echo no)"
check "setup, pin, no map: the start script passes the installed file" "\$(cat ${CFG}/bootstrap-peers.yaml) yes" \
    "$(start_line_peers "$PEERS_LINE") $(grep -q -F -- " ${PEERS_LINE}" "$T/tn-start" && echo yes || echo no)"
# The interactive order: the flags first (step_create_infrastructure), then the copy
# (step_write_config), then the flags again (step_create_service).
reset; gd "$T/in/bs.yaml"
sn interactive prepare write_from_bs prepare
check "setup, pin, interactive: the second flags pass takes the default" "0
SRC=${CFG}/bootstrap-peers.yaml
FLAGS=${PEERS_LINE}
META=BOOTSTRAP_PEERS_FILE=${CFG}/bootstrap-peers.yaml" "$SN_RC
$SN_VARS"
# Refusals, each before the copy.
REFUSE_MISSING="The testnet chain configs at ${TAG} keep the bootstrap servers in bootstrap_servers.yaml, not in committee.yaml, and ${T}/gd has no pinned copy of it (see above). Put chain-configs/testnet/bootstrap_servers.yaml of ${TAG} there, or pass --bootstrap-peers FILE; nothing was copied."
reset; gd "$T/in/bs-other.yaml"
sn write_from_bs prepare
check "setup, pin, a changed file: stops (rc 1)" 1 "$SN_RC"
check "setup, pin, changed: the hashes, then the refusal" "yes yes" \
    "$(has "$SN_OUT" "${T}/gd/bootstrap_servers.yaml: sha256 ${OTHER_SHA}, expected ${BS_SHA} (testnet).") $(has "$SN_OUT" "$REFUSE_MISSING")"
check "setup, pin, changed: nothing copied, no map installed" "no no" \
    "$([[ -e "$DATA_DIR/genesis/committee.yaml" ]] && echo yes || echo no) $([[ -e "$CFG/bootstrap-peers.yaml" ]] && echo yes || echo no)"
reset; gd
sn write_from_bs prepare
check "setup, pin, no file beside the chain configs: stops (rc 1), named" "1 yes yes" \
    "$SN_RC $(has "$SN_OUT" "${T}/gd/bootstrap_servers.yaml is missing or not a regular file.") $(has "$SN_OUT" "$REFUSE_MISSING")"
check "setup, pin, no file: nothing copied" no "$([[ -e "$DATA_DIR/genesis/committee.yaml" ]] && echo yes || echo no)"
reset; gd "$T/in/bs.yaml"; chmod 0600 "$T/gd/bootstrap_servers.yaml"
sn write_from_bs prepare
check "setup, pin, a file other users cannot read: stops with the peers-file reason" "1 yes" \
    "$SN_RC $(has "$SN_OUT" "The testnet bootstrap servers: ${T}/gd/bootstrap_servers.yaml is mode 600: other users cannot read it.")"
check "setup, pin, unreadable: nothing copied" no "$([[ -e "$DATA_DIR/genesis/committee.yaml" ]] && echo yes || echo no)"
reset; gd "$T/in/bs.yaml"; PARSE_RC=1
sn write_from_bs prepare
PARSE_RC=0
check "setup, pin, a map the release rejects: stops with the parser's reason" "1 yes" \
    "$SN_RC $(has "$SN_OUT" "The bootstrap peers map in ${T}/gd/bootstrap_servers.yaml is not valid for the node binary at /opt/telcoin/telcoin-network (expected valid bls public key bytes).")"
check "setup, pin, rejected: no map installed" no "$([[ -e "$CFG/bootstrap-peers.yaml" ]] && echo yes || echo no)"
# The operator's own map wins: no default is checked, announced or installed.
reset; gd
own() { BOOTSTRAP_PEERS_SRC="$T/in/own.yaml"; }
sn own write_from_bs prepare
check "setup, pin, --bootstrap-peers: the operator's map is installed and passed" "0
SRC=${CFG}/bootstrap-peers.yaml
FLAGS=${PEERS_LINE}
META=BOOTSTRAP_PEERS_FILE=${CFG}/bootstrap-peers.yaml" "$SN_RC
$SN_VARS"
check "setup, pin, --bootstrap-peers: it is the operator's file, and no default was asked for" "yes no no" \
    "$(cmp -s "$T/in/own.yaml" "$CFG/bootstrap-peers.yaml" && echo yes || echo no) $(has "$SN_OUT" "Bootstrap peers: the testnet") $(has "$SN_OUT" "bootstrap_servers.yaml")"
# A map the host recorded wins: an interactive re-run without an admission mode keeps it.
reset; gd "$T/in/bs.yaml"; cp "$T/in/own.yaml" "$CFG/bootstrap-peers.yaml"
printf 'BOOTSTRAP_PEERS_FILE=%s\n' "$CFG/bootstrap-peers.yaml" > "$CFG/.node-meta"
sn interactive prepare write_from_bs prepare
check "setup, pin, a recorded map, interactive re-run: kept and passed" "0
SRC=${CFG}/bootstrap-peers.yaml
FLAGS=${PEERS_LINE}
META=BOOTSTRAP_PEERS_FILE=${CFG}/bootstrap-peers.yaml" "$SN_RC
$SN_VARS"
check "setup, pin, a recorded map: still the operator's file, no default line" "yes no" \
    "$(cmp -s "$T/in/own.yaml" "$CFG/bootstrap-peers.yaml" && echo yes || echo no) $(has "$SN_OUT" "Bootstrap peers: the testnet")"
# A --json finalize reads keygen's record back (finalize_node_extra_flags) first.
reset; gd "$T/in/bs.yaml"; cp "$T/in/own.yaml" "$CFG/bootstrap-peers.yaml"
printf 'BOOTSTRAP_PEERS_FILE=%s\n' "$CFG/bootstrap-peers.yaml" > "$CFG/.node-meta"
readback() { CONFIG_DIR="$CFG" peers_read_back; }
sn readback write_from_bs prepare
check "setup, pin, a --json finalize after a keygen with a map: kept" "0 yes no" \
    "$SN_RC $(cmp -s "$T/in/own.yaml" "$CFG/bootstrap-peers.yaml" && echo yes || echo no) $(has "$SN_OUT" "Bootstrap peers: the testnet")"
# Mainnet gets no default, whatever the directory holds.
reset; gd "$T/in/bs.yaml"
rc=0
# shellcheck disable=SC2034  # read by setup_default_bootstrap_peers
( set +u; CONFIG_DIR="$CFG"; NETWORK=mainnet; setup_default_bootstrap_peers "$T/gd"; printf 'SRC=%s\n' "$BOOTSTRAP_PEERS_SRC" ) > "$T/out" 2>&1 || rc=$?
check "setup, mainnet: no default, no message" "0 SRC=" "$rc $(cat "$T/out")"

finish
