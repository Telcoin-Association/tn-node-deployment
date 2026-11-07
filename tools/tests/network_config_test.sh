#!/usr/bin/env bash
# =============================================================================
# tools/tests/network_config_test.sh -- the node admission settings in the data
# dir's network-config (tn_network_config_render) and the first node release
# that reads them (tn_node_supports_admission against MIN_ADMISSION_VERSION).
#
#   bash tools/tests/network_config_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/network_config_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/network_config_test.sh
#
# The renderer edits the file through the library's own tn_as_service_user.
# setpriv, id and getent are PATH stubs: id and getent know one account,
# telcoin (uid and gid 991), and setpriv logs its account options and runs the
# command as the current user, so the edit cases run anywhere. As root with a
# real setpriv and useradd (the ubuntu container) a throwaway system account
# owns a real data dir, and the owner of the file it gets back, a trusted file
# only root can read and a data dir only root can write are checked as that
# account; elsewhere those cases are skipped. Where python3 has PyYAML, every
# rendered file is loaded with duplicate keys refused, as the node refuses them.
# Maintainer tooling (not updater-tracked). bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T="$TN_TEST_TMP"
TN_ROOT_PREFIX="$T/empty"
mkdir -p "$TN_ROOT_PREFIX"
eval "$(tn_test_source_common)"

ESC="$(printf '\033')"
ORIG_PATH="$PATH"
FX="$T/fx"
mkdir -p "$FX" "$T/bin" "$T/parsed"

# the real-account cases need root, a setpriv that clears groups, and useradd;
# decided before the stubs go on PATH
REAL=no
if [[ "$(id -u)" == 0 ]] && command -v useradd >/dev/null 2>&1 \
    && grep -q -- '--clear-groups' <<< "$(setpriv --help 2>&1)"; then
    REAL=yes
fi

TN_NC_CALLS="$T/calls.log"
TN_NC_REAL_ID="$(command -v id)"
export TN_NC_CALLS TN_NC_REAL_ID
: > "$TN_NC_CALLS"
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
# log the account options and the command, then run the command as the
# current user
opts=""
while [ $# -gt 0 ] && [ "$1" != -- ]; do opts="$opts $1"; shift; done
[ $# -gt 0 ] && shift
pass=absent
[ -n "${TN_BLS_PASSPHRASE+x}" ] && pass=present
printf 'setpriv%s -- %s, passphrase %s\n' "$opts" "${1:-}" "$pass" >> "$TN_NC_CALLS"
exec "$@"
STUB
chmod 0755 "$T/bin/id" "$T/bin/getent" "$T/bin/setpriv"
PATH="$T/bin:$ORIG_PATH"

# ---- fixture files -------------------------------------------------------------
# the node's default network-config: the top-level keys in the order the node
# writes them, the three admission entries as serde_yaml writes them, the other
# entries abridged
cat > "$FX/default.yaml" <<'DEF'
libp2p_config:
  max_rpc_message_size: 1048576
  max_idle_connection_timeout:
    secs: 60
    nanos: 0
  max_px_disconnects: 10
  px_disconnect_timeout:
    secs: 3
    nanos: 0
sync_config:
  max_skip_rounds_for_missing_certs: 1000
  max_db_read_time_for_fetching_certificates:
    secs: 10
    nanos: 0
quic_config:
  handshake_timeout:
    secs: 10
    nanos: 0
  max_idle_timeout: 30000
process_budget: null
serve_budget:
  vote: 0
  epoch_record: 0
peer_config:
  heartbeat_interval: 30
  target_num_peers: 50
admission:
  mode: Open
  snapshot_max_age_secs: 300
source_admission: null
peer_readiness_timeout:
  secs: 120
  nanos: 0
hostname: ''
bootstrap_peers: {}
trusted_nodes: {}
committee_peers: {}
endpoints:
  primary: null
  workers: {}
DEF
# trusted_nodes input: BLS key to {primary, workers: {<id>: ...}}
cat > "$FX/trusted.yaml" <<'TRU'
# hub for the closed validator
HubBLSkey1:
  primary:
    network_address: /ip4/203.0.113.10/udp/49590/quic-v1/p2p/12D3KooWHubPrimary
    network_key: 4XTTMhubprimary
    rpc: ~
  workers:
    0:
      network_address: /ip4/203.0.113.10/udp/49594/quic-v1/p2p/12D3KooWHubWorker
      network_key: 4XTTMhubworker
      rpc: ~
TRU
# committee_peers input in the bootstrap-peers.yaml shape: BLS key to
# {primary, workers: [...]}, a leading document marker and blank lines
cat > "$FX/committee.yaml" <<'COM'
---
PeerBLSkey1:
  primary:
    network_address: /ip4/198.51.100.21/udp/49590/quic-v1/p2p/12D3KooWPeer1P
    network_key: 4XTTMpeer1p
    rpc: ~
  workers:
    - network_address: /ip4/198.51.100.21/udp/49594/quic-v1/p2p/12D3KooWPeer1W
      network_key: 4XTTMpeer1w
      rpc: ~

PeerBLSkey2:
  primary:
    network_address: /ip4/198.51.100.22/udp/49590/quic-v1/p2p/12D3KooWPeer2P
    network_key: 4XTTMpeer2p
    rpc: ~
  workers:
  - network_address: /ip4/198.51.100.22/udp/49594/quic-v1/p2p/12D3KooWPeer2W
    network_key: 4XTTMpeer2w
    rpc: ~

COM
# a file that already holds the three entries, with comments and a blank line
cat > "$FX/three.yaml" <<'THR'
hostname: "validator-3"
admission:
  mode: Grace
# hubs below were set by hand
trusted_nodes:
  OldHubBLSkey:
    primary:
      network_address: /ip4/203.0.113.99/udp/49590/quic-v1/p2p/12D3KooWOldHubP
      network_key: 4XTTMoldhubp
    # an inner note
    workers:
      0:
        network_address: /ip4/203.0.113.99/udp/49594/quic-v1/p2p/12D3KooWOldHubW
        network_key: 4XTTMoldhubw

committee_peers: {}
endpoints:
  primary: null
  workers: {}
THR
# an admission entry with its lease before the mode
cat > "$FX/snapshot.yaml" <<'SNP'
hostname: "validator-7"
admission:
  snapshot_max_age_secs: 900
  mode: Grace
SNP
# the two input files as they appear under their keys
cat > "$FX/trusted.nested" <<'WTR'
trusted_nodes:
  # hub for the closed validator
  HubBLSkey1:
    primary:
      network_address: /ip4/203.0.113.10/udp/49590/quic-v1/p2p/12D3KooWHubPrimary
      network_key: 4XTTMhubprimary
      rpc: ~
    workers:
      0:
        network_address: /ip4/203.0.113.10/udp/49594/quic-v1/p2p/12D3KooWHubWorker
        network_key: 4XTTMhubworker
        rpc: ~
WTR
cat > "$FX/committee.nested" <<'WCO'
committee_peers:
  PeerBLSkey1:
    primary:
      network_address: /ip4/198.51.100.21/udp/49590/quic-v1/p2p/12D3KooWPeer1P
      network_key: 4XTTMpeer1p
      rpc: ~
    workers:
      - network_address: /ip4/198.51.100.21/udp/49594/quic-v1/p2p/12D3KooWPeer1W
        network_key: 4XTTMpeer1w
        rpc: ~
  PeerBLSkey2:
    primary:
      network_address: /ip4/198.51.100.22/udp/49590/quic-v1/p2p/12D3KooWPeer2P
      network_key: 4XTTMpeer2p
      rpc: ~
    workers:
    - network_address: /ip4/198.51.100.22/udp/49594/quic-v1/p2p/12D3KooWPeer2W
      network_key: 4XTTMpeer2w
      rpc: ~
WCO
printf '  mode: Open\n' > "$FX/m.open"
printf '  mode: Grace\n' > "$FX/m.grace"
printf '  mode: Closed\n' > "$FX/m.closed"
TF="$FX/trusted.yaml"
CF="$FX/committee.yaml"

# ---- helpers -------------------------------------------------------------------
# cat_file FILE: the bytes of FILE and an end marker, so trailing newlines count
cat_file() { cat -- "$1"; printf '|EOF'; }
# plain FILE: FILE without colour codes
plain() { sed "s/${ESC}\[[0-9;]*m//g" "$1"; }
# top_keys FILE: the top-level keys of FILE in file order, one per line
top_keys() { sed -n 's/^\([A-Za-z0-9_][A-Za-z0-9_.-]*\):.*$/\1/p' "$1"; }
# dup_keys FILE: the top-level keys FILE holds more than once
dup_keys() { top_keys "$1" | sort | uniq -d; }
# key_counts FILE: how many lines of FILE start each of the three entries
key_counts() {
    local k n out=""
    for k in admission trusted_nodes committee_peers; do
        n="$(grep -c "^${k}:" "$1")"
        out="${out}${out:+ }${k}=${n}"
    done
    printf '%s\n' "$out"
}
# leftovers DIR: what DIR holds besides network-config (a temp file, say)
leftovers() { ls -A "$1" | sed '/^network-config$/d'; }

# subst FILE OLDLINE NEWFILE...: FILE with each whole line OLDLINE replaced by
# the content of NEWFILE (pairs, in file order; /dev/null drops the line)
subst() {
    local f="$1" line
    shift
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ $# -ge 2 && "$line" == "$1" ]]; then
            cat -- "$2"
            shift 2
            continue
        fi
        printf '%s\n' "$line"
    done < "$f"
}

# render NAME SRC MODE TRUSTED COMMITTEE: a fresh data dir $T/NAME/data holding
# a copy of SRC as network-config (no file when SRC is -), then the renderer;
# sets RC, NC (the file) and OUT (the output without colour codes)
render() {
    local name="$1" src="$2"
    shift 2
    mkdir -p "$T/$name/data"
    if [[ "$src" != - ]]; then
        cp -- "$src" "$T/$name/data/network-config"
    fi
    again "$name" "$@"
}
# again NAME MODE TRUSTED COMMITTEE: the renderer on the data dir of NAME
again() {
    local name="$1"
    shift
    NC="$T/$name/data/network-config"
    RC=0
    tn_network_config_render "$T/$name/data" "$@" > "$T/$name/out" 2>&1 || RC=$?
    OUT="$(plain "$T/$name/out")"
}
# keep NAME: save the rendered file for the YAML load at the end
keep() { cp -- "$NC" "$T/parsed/$1.yaml"; }

# ---- the release floor ---------------------------------------------------------
echo "== version gate (MIN_ADMISSION_VERSION=${MIN_ADMISSION_VERSION})"
check "floor value" "0.17.0" "$MIN_ADMISSION_VERSION"
rc=0; tn_node_supports_admission "$MIN_ADMISSION_VERSION" || rc=$?
check_rc "at the floor: supported" 0 "$rc"
rc=0; tn_node_supports_admission 0.16.9 || rc=$?
check_rc "one below the floor (0.16.9): not supported" 1 "$rc"
rc=0; tn_node_supports_admission 0.17.1 || rc=$?
check_rc "one above the floor (0.17.1): supported" 0 "$rc"
# the gate answers as version_gte does for every plain release
for v in 0.9.99 0.16.0 0.16.9 0.17.0 0.17.1 0.18.0 0.100.0 1.0.0; do
    want=1
    if version_gte "$v" "$MIN_ADMISSION_VERSION"; then want=0; fi
    rc=0; tn_node_supports_admission "$v" || rc=$?
    check_rc "same answer as version_gte: ${v}" "$want" "$rc"
done
for v in v0.17.0 v0.17.0-rc1 v0.17.0-suffix-rc2 v0.18.2 \
    registry.example/tn/node:v0.17.0 registry.example:5000/node:v0.17.1-suffix; do
    rc=0; tn_node_supports_admission "$v" || rc=$?
    check_rc "supported: ${v}" 0 "$rc"
done
for v in v0.16.0 v0.16.0-suffix registry.example/node:v0.16.0; do
    rc=0; tn_node_supports_admission "$v" || rc=$?
    check_rc "below the floor: ${v}" 1 "$rc"
done
for v in "" main abc1234 v0.17.0-3-gdeadbee v0.17.0-suffix-12-g0123abc-dirty v0.17.0-dirty \
    node@sha256:0123abcd 0.17 0.17.0.1 v; do
    rc=0; tn_node_supports_admission "$v" || rc=$?
    check_rc "unknown, not a no: '${v}'" 2 "$rc"
done
check "the gate prints nothing" "" "$(tn_node_supports_admission 0.17.0 2>&1)"

# ---- the node's default file ---------------------------------------------------
echo "== the node default network-config: Closed, trusted_nodes and committee_peers from files"
subst "$FX/default.yaml" "  mode: Open" "$FX/m.closed" "trusted_nodes: {}" "$FX/trusted.nested" \
    "committee_peers: {}" "$FX/committee.nested" > "$T/a.want"
: > "$TN_NC_CALLS"
export TN_BLS_PASSPHRASE=fixture-only
render a "$FX/default.yaml" closed "$TF" "$CF"
unset TN_BLS_PASSPHRASE
check_rc "default closed: rc" 0 "$RC"
check "default closed: the entries replaced in place" "$(cat_file "$T/a.want")" "$(cat_file "$NC")"
check "default closed: top-level keys unchanged, in the same order" \
    "$(top_keys "$FX/default.yaml")" "$(top_keys "$NC")"
check "default closed: each entry once" "admission=1 trusted_nodes=1 committee_peers=1" "$(key_counts "$NC")"
check "default closed: no top-level key twice" "" "$(dup_keys "$NC")"
check "default closed: no temp file left" "" "$(leftovers "$T/a/data")"
check_has "default closed: ok line" "  [OK]  Admission settings written to ${NC} (mode Closed)" "$OUT"
check "default closed: edited once, as the service user, without the passphrase" \
    "setpriv --reuid 991 --regid 991 --clear-groups --no-new-privs -- sh, passphrase absent" \
    "$(cat "$TN_NC_CALLS")"
keep a
cp -- "$NC" "$T/a/after"
again a closed "$TF" "$CF"
check_rc "default closed again: rc" 0 "$RC"
check "default closed again: nothing changes" "$(cat_file "$T/a/after")" "$(cat_file "$NC")"

echo "== trusted_nodes removed with none"
subst "$FX/default.yaml" "  mode: Open" "$FX/m.closed" "trusted_nodes: {}" /dev/null \
    "committee_peers: {}" "$FX/committee.nested" > "$T/a2.want"
again a closed none "$CF"
check_rc "trusted none: rc" 0 "$RC"
check "trusted none: the entry is gone, the rest as before" "$(cat_file "$T/a2.want")" "$(cat_file "$NC")"
check "trusted none: entry counts" "admission=1 trusted_nodes=0 committee_peers=1" "$(key_counts "$NC")"
keep a-trusted-none

echo "== Grace on the node default, both maps none"
subst "$FX/default.yaml" "  mode: Open" "$FX/m.grace" "trusted_nodes: {}" /dev/null \
    "committee_peers: {}" /dev/null > "$T/g.want"
render g "$FX/default.yaml" grace none none
check_rc "default grace: rc" 0 "$RC"
check "default grace: mode Grace, the lease kept, the two maps left out" "$(cat_file "$T/g.want")" "$(cat_file "$NC")"
check "default grace: the other top-level keys unchanged, in the same order" \
    "$(top_keys "$FX/default.yaml" | sed -e '/^trusted_nodes$/d' -e '/^committee_peers$/d')" "$(top_keys "$NC")"
check_has "default grace: ok line" "  [OK]  Admission settings written to ${NC} (mode Grace)" "$OUT"
keep g

# ---- a file that holds the entries already ----------------------------------------
echo "== a file already holding the three entries"
render b "$FX/three.yaml" Closed "$TF" "$CF"
check_rc "three entries: rc" 0 "$RC"
{
    printf '%s\n' 'hostname: "validator-3"' 'admission:' '  mode: Closed' '# hubs below were set by hand'
    cat -- "$FX/trusted.nested"
    printf '\n'
    cat -- "$FX/committee.nested"
    printf '%s\n' 'endpoints:' '  primary: null' '  workers: {}'
} > "$T/b.want"
check "three entries: replaced, the comment and the blank line between them kept" \
    "$(cat_file "$T/b.want")" "$(cat_file "$NC")"
check "three entries: top-level keys" \
    "$(printf '%s\n' hostname admission trusted_nodes committee_peers endpoints)" "$(top_keys "$NC")"
check "three entries: each entry once" "admission=1 trusted_nodes=1 committee_peers=1" "$(key_counts "$NC")"
check "three entries: no top-level key twice" "" "$(dup_keys "$NC")"
check_lacks "three entries: the old hub is gone" "OldHubBLSkey" "$(cat "$NC")"
keep b
cp -- "$NC" "$T/b/after"
again b closed "$TF" "$CF"
check "three entries again: nothing changes" "$(cat_file "$T/b/after")" "$(cat_file "$NC")"

echo "== duplicate entries in the file"
mkdir -p "$T/dup/data"
printf '%s\n' 'admission:' '  mode: Open' 'hostname: a' 'admission: {mode: Grace, snapshot_max_age_secs: 600}' \
    'trusted_nodes: {}' 'list_key:' '- one' '- two' 'trusted_nodes:' '  X: 1' > "$T/dup/data/network-config"
again dup closed none none
check_rc "duplicates: rc" 0 "$RC"
check "duplicates: one entry each, at the first place; a column-0 list stays with its key" \
    "$(printf '%s\n' 'admission:' '  mode: Closed' '  snapshot_max_age_secs: 600' 'hostname: a' 'list_key:' '- one' '- two' '|EOF')" \
    "$(cat_file "$NC")"
check "duplicates: no top-level key twice" "" "$(dup_keys "$NC")"
keep dup

# ---- snapshot_max_age_secs -----------------------------------------------------
echo "== an existing snapshot_max_age_secs is kept"
render c "$FX/snapshot.yaml" closed "$TF" "$CF"
check_rc "lease 900: rc" 0 "$RC"
{
    printf '%s\n' 'hostname: "validator-7"' 'admission:' '  mode: Closed' '  snapshot_max_age_secs: 900'
    cat -- "$FX/trusted.nested" "$FX/committee.nested"
} > "$T/c.want"
check "lease 900: kept under the new mode; missing maps added at the end" "$(cat_file "$T/c.want")" "$(cat_file "$NC")"
keep c

mkdir -p "$T/flow/data"
printf '%s\n' 'admission: {mode: Open, snapshot_max_age_secs: 45}  # lease' 'hostname: b' > "$T/flow/data/network-config"
again flow Grace none none
check_rc "flow admission: rc" 0 "$RC"
check "flow admission: the lease kept, the entry written in block form" \
    "$(printf '%s\n' 'admission:' '  mode: Grace' '  snapshot_max_age_secs: 45' 'hostname: b' '|EOF')" \
    "$(cat_file "$NC")"
keep flow

mkdir -p "$T/inner/data"
printf '%s\n' 'admission:' '  mode: Open' '# inside, more lines follow' '  snapshot_max_age_secs: 70' '# between' '' 'hostname: c' \
    > "$T/inner/data/network-config"
again inner closed none none
check "a column-0 comment inside an entry goes with it, one before the next key stays" \
    "$(printf '%s\n' 'admission:' '  mode: Closed' '  snapshot_max_age_secs: 70' '# between' '' 'hostname: c' '|EOF')" \
    "$(cat_file "$NC")"
keep inner

echo "== a comment is not a lease"
mkdir -p "$T/leasenote/data"
printf '%s\n' 'admission:' '  mode: Open # was snapshot_max_age_secs: 5' "hostname: ''" > "$T/leasenote/data/network-config"
again leasenote closed none none
check_rc "lease in a comment: rc" 0 "$RC"
check "lease in a comment: not taken, no lease written" \
    "$(printf '%s\n' 'admission:' '  mode: Closed' "hostname: ''" '|EOF')" "$(cat_file "$NC")"
keep leasenote
mkdir -p "$T/leasetail/data"
printf '%s\n' 'admission:' '  mode: Open' '  snapshot_max_age_secs: 120 # two minutes' > "$T/leasetail/data/network-config"
again leasetail grace none none
check "a lease with a comment after it: kept" \
    "$(printf '%s\n' 'admission:' '  mode: Grace' '  snapshot_max_age_secs: 120' '|EOF')" "$(cat_file "$NC")"
keep leasetail

# ---- other inputs --------------------------------------------------------------
echo "== no network-config yet, a JSON committee file"
render new - open none "$CF"
check_rc "missing file: rc" 0 "$RC"
check "missing file: created with the entries alone" \
    "$(printf '%s\n' 'admission:' '  mode: Open'; cat "$FX/committee.nested"; printf '|EOF')" "$(cat_file "$NC")"
keep new

printf '{\n  "PeerBLSkey9": {"primary": {"network_address": "/ip4/198.51.100.9/udp/1/quic-v1", "network_key": "k"}, "workers": []}\n}\n' \
    > "$T/committee.json"
render json - closed none "$T/committee.json"
check_rc "JSON committee file: rc" 0 "$RC"
check "JSON committee file: nested two spaces deeper" \
    "$(printf '%s\n' 'admission:' '  mode: Closed' 'committee_peers:' '  {' '    "PeerBLSkey9": {"primary": {"network_address": "/ip4/198.51.100.9/udp/1/quic-v1", "network_key": "k"}, "workers": []}' '  }' '|EOF')" \
    "$(cat_file "$NC")"
keep json

echo "== maps saved on Windows: a byte order mark, CRLF line ends"
{ printf '\357\273\277'; cat -- "$TF"; } > "$T/trusted.bom"
awk '{ printf("%s\r\n", $0) }' "$CF" > "$T/committee.crlf"
{ printf '\357\273\277'; awk '{ printf("%s\r\n", $0) }' "$TF"; } > "$T/trusted.bomcrlf"
render bomcrlf "$FX/default.yaml" closed "$T/trusted.bom" "$T/committee.crlf"
check_rc "BOM trusted, CRLF committee: rc" 0 "$RC"
check "BOM trusted, CRLF committee: written as the plain maps are" "$(cat_file "$T/a.want")" "$(cat_file "$NC")"
keep bomcrlf
render bomcrlf2 "$FX/default.yaml" closed "$T/trusted.bomcrlf" "$CF"
check "BOM and CRLF in one map: written as the plain map is" "$(cat_file "$T/a.want")" "$(cat_file "$NC")"

echo "== flow values over several lines, a brace in a plain scalar, a leading marker"
mkdir -p "$T/flowok/data"
printf '%s\n' '---' 'endpoints: {primary: null,' '  workers: {}}' 'hostname: a{b' 'note: [x, "]"]  # [' \
    > "$T/flowok/data/network-config"
again flowok closed none none
check_rc "flow over lines: rc" 0 "$RC"
check "flow over lines: kept line for line, the entry added at the end" \
    "$(printf '%s\n' '---' 'endpoints: {primary: null,' '  workers: {}}' 'hostname: a{b' 'note: [x, "]"]  # [' 'admission:' '  mode: Closed' '|EOF')" \
    "$(cat_file "$NC")"
keep flowok

# ---- the write: network-config.tn-new, then one rename ---------------------------
echo "== the write goes to network-config.tn-new and one rename"
mkdir -p "$T/stale/data"
cp -- "$FX/default.yaml" "$T/stale/data/network-config"
printf 'admission:\n  mode: Clo' > "$T/stale/data/network-config.tn-new"
again stale closed "$TF" "$CF"
check_rc "stale temp file: rc" 0 "$RC"
check "stale temp file: a fresh write, not an append to it" "$(cat_file "$T/a.want")" "$(cat_file "$NC")"
check "stale temp file: gone" "" "$(leftovers "$T/stale/data")"

mkdir -p "$T/symnew/data"
cp -- "$FX/default.yaml" "$T/symnew/data/network-config"
printf 'decoy\n' > "$T/decoy"
ln -s "$T/decoy" "$T/symnew/data/network-config.tn-new"
again symnew closed "$TF" "$CF"
check_rc "temp name a symlink: rc" 0 "$RC"
check "temp name a symlink: its target untouched" "$(printf 'decoy\n|EOF')" "$(cat_file "$T/decoy")"
check "temp name a symlink: network-config written" "$(cat_file "$T/a.want")" "$(cat_file "$NC")"
check "temp name a symlink: gone" "" "$(leftovers "$T/symnew/data")"

mkdir -p "$T/hard/data"
cp -- "$FX/default.yaml" "$T/hard/data/network-config"
ln "$T/hard/data/network-config" "$T/hard/old"
again hard closed "$TF" "$CF"
check_rc "rename: rc" 0 "$RC"
check "rename: a hard link to the old file keeps the old text" "$(cat_file "$FX/default.yaml")" "$(cat_file "$T/hard/old")"
check "rename: network-config is the new file" "$(cat_file "$T/a.want")" "$(cat_file "$NC")"

echo "== the edit cannot run or its write fails: rc 2, network-config unchanged"
mkdir -p "$T/failawk" "$T/failmv"
printf '#!/bin/sh\nprintf "admission:\\n  mode: Clo"\nexit 2\n' > "$T/failawk/awk"
printf '#!/bin/sh\nexit 1\n' > "$T/failmv/mv"
chmod 0755 "$T/failawk/awk" "$T/failmv/mv"
mkdir -p "$T/norun/data"
cp -- "$FX/default.yaml" "$T/norun/data/network-config"
PATH="$T/failawk:$T/bin:$ORIG_PATH"
again norun closed "$TF" "$CF"
PATH="$T/bin:$ORIG_PATH"
check_rc "awk fails after a partial write: rc 2" 2 "$RC"
check "awk fails: unchanged" "$(cat_file "$FX/default.yaml")" "$(cat_file "$NC")"
check "awk fails: the partial temp file removed" "" "$(leftovers "$T/norun/data")"
check_has "awk fails: says so" "  [ERROR] Could not write the admission settings to ${NC}" "$OUT"
PATH="$T/failmv:$T/bin:$ORIG_PATH"
again norun closed "$TF" "$CF"
PATH="$T/bin:$ORIG_PATH"
check_rc "rename fails: rc 2" 2 "$RC"
check "rename fails: unchanged" "$(cat_file "$FX/default.yaml")" "$(cat_file "$NC")"
check "rename fails: the temp file removed" "" "$(leftovers "$T/norun/data")"
: > "$TN_NC_CALLS"
SERVICE_USER=tnnc-nosuch
again norun closed "$TF" "$CF"
SERVICE_USER=telcoin
check_rc "unknown service account: rc 2" 2 "$RC"
check "unknown service account: nothing ran" "" "$(cat "$TN_NC_CALLS")"
check "unknown service account: unchanged" "$(cat_file "$FX/default.yaml")" "$(cat_file "$NC")"

# ---- refusals ------------------------------------------------------------------
echo "== refusals: rc 1, network-config unchanged, no temp file"
# refuse NAME MODE TRUSTED COMMITTEE CONTENT: network-config holds CONTENT (a
# printf format); sets REFUSE_OUT
refuse() {
    local name="$1" rc=0 d="$T/refuse/$1"
    shift
    mkdir -p "$d/data"
    # shellcheck disable=SC2059  # CONTENT is a printf format on purpose
    printf "$4" > "$d/data/network-config"
    cp -- "$d/data/network-config" "$d/before"
    tn_network_config_render "$d/data" "$1" "$2" "$3" > "$d/out" 2>&1 || rc=$?
    check_rc "refused: ${name}" 1 "$rc"
    check "refused: ${name}: unchanged" "$(cat_file "$d/before")" "$(cat_file "$d/data/network-config")"
    check "refused: ${name}: no temp file" "" "$(leftovers "$d/data")"
    REFUSE_OUT="$(plain "$d/out")"
}
# why NAME REASON: the error line of the refuse case NAME
why() { printf '  [ERROR] The admission settings were not written to %s/refuse/%s/data/network-config: %s' "$T" "$1" "$2"; }
printf '' > "$T/empty.yaml"
printf '# only a comment\n\n---\n' > "$T/comment-only.yaml"
printf -- '- a\n- b\n' > "$T/list.yaml"
printf '  Indented: 1\n' > "$T/indented.yaml"
printf 'A:\n  primary: 1\n---\nB:\n  primary: 2\n' > "$T/twodocs.yaml"
printf 'none\n' > "$T/scalar.yaml"
mkdir -p "$T/srcdir"
refuse "bad mode" Strict none none 'hostname: x\n'
check_has "bad mode: message" "  [ERROR] Admission mode 'Strict' is not one of open, grace or closed." "$REFUSE_OUT"
refuse "relative trusted path" closed trusted.yaml none 'hostname: x\n'
refuse "missing trusted file" closed "$T/no-such.yaml" none 'hostname: x\n'
check_has "missing trusted file: message" \
    "  [ERROR] The admission settings were not written to $T/refuse/missing trusted file/data/network-config: cannot read $T/no-such.yaml" \
    "$REFUSE_OUT"
refuse "empty trusted file" closed "$T/empty.yaml" none 'hostname: x\n'
refuse "comment-only committee file" closed none "$T/comment-only.yaml" 'hostname: x\n'
refuse "list trusted file" closed "$T/list.yaml" none 'hostname: x\n'
refuse "indented trusted file" closed "$T/indented.yaml" none 'hostname: x\n'
refuse "two documents" closed none "$T/twodocs.yaml" 'hostname: x\n'
check_has "two documents: message" \
    "  [ERROR] The admission settings were not written to $T/refuse/two documents/data/network-config: $T/twodocs.yaml holds more than one YAML document" \
    "$REFUSE_OUT"
refuse "scalar file" closed none "$T/scalar.yaml" 'hostname: x\n'
refuse "trusted file a directory" closed "$T/srcdir" none 'hostname: x\n'
refuse "flow document" closed none none '{admission: {mode: Open}}\n'
refuse "quoted key" closed none none '"admission":\n  mode: Open\n'
refuse "space before colon" closed none none 'admission :\n  mode: Open\n'
refuse "CRLF" closed none none 'admission:\r\n  mode: Open\r\n'
check_has "CRLF: message names the line ends" \
    "$(why CRLF 'line 1 ends in a carriage return (CRLF line ends); save the file with LF line ends')" "$REFUSE_OUT"
refuse "CRLF, every line a key" closed "$TF" "$CF" "hostname: 'x'\r\nadmission: {mode: Open, snapshot_max_age_secs: 300}\r\ntrusted_nodes: {}\r\n"
check_has "CRLF, every line a key: message names the line ends" \
    "$(why 'CRLF, every line a key' 'line 1 ends in a carriage return (CRLF line ends); save the file with LF line ends')" "$REFUSE_OUT"
refuse "byte order mark" closed none none '\357\273\277hostname: x\nadmission:\n  mode: Open\n'
check_has "byte order mark: message names it" \
    "$(why 'byte order mark' 'the file starts with a byte order mark; save it as UTF-8 without one')" "$REFUSE_OUT"
refuse "whole document indented" closed none none '  hostname: x\n  admission:\n    mode: Open\n'
check_has "whole document indented: message" \
    "$(why 'whole document indented' 'line 1 comes before the first top-level key, so its entries cannot be told apart')" "$REFUSE_OUT"
refuse "key inside an open flow value" closed "$TF" none 'endpoints: {primary: null,\ntrusted_nodes: {}}\nhostname: x\n'
check_has "key inside an open flow value: message" \
    "$(why 'key inside an open flow value' 'line 2 starts a top-level key inside the flow value that line 1 leaves open, so its entries cannot be told apart')" \
    "$REFUSE_OUT"
refuse "key inside a nested open flow value" closed none none 'endpoints:\n  primary: {a: [1,\nhostname: x]}\n'
refuse "flow value never closed" closed none none 'hostname: x\nendpoints: {primary: null,\n  workers: {}\n'
check_has "flow value never closed: message" \
    "$(why 'flow value never closed' 'the flow value that line 2 opens is never closed')" "$REFUSE_OUT"
refuse "document marker inside an entry" closed none none "hostname: 'a'\nadmission:\n  mode: Open\n---\nhostname: 'b'\n"
check_has "document marker inside an entry: message" \
    "$(why 'document marker inside an entry' 'line 4 is a document marker (--- or ...) after the document has started: network-config must hold one YAML document')" \
    "$REFUSE_OUT"
refuse "document end marker" closed none none 'hostname: a\n...\n'
refuse "two leading markers" closed none none '# two empty starts\n---\n---\nhostname: x\n'
refuse "directive" closed none none '%%YAML 1.2\n---\nhostname: x\n'
refuse "lease not a number" closed none none 'admission:\n  mode: Open\n  snapshot_max_age_secs: soon\n'
check_has "lease not a number: message" \
    "  [ERROR] The admission settings were not written to $T/refuse/lease not a number/data/network-config: snapshot_max_age_secs of the admission entry is not a whole number: soon" \
    "$REFUSE_OUT"
refuse "lease empty" closed none none 'admission:\n  snapshot_max_age_secs:\n'
rc=0; tn_network_config_render "$T/refuse" closed none >/dev/null 2>&1 || rc=$?
check_rc "three arguments refused" 1 "$rc"
rc=0; tn_network_config_render "relative/dir" closed none none >/dev/null 2>&1 || rc=$?
check_rc "relative data dir refused" 1 "$rc"
mkdir -p "$T/real" && ln -s "$T/real" "$T/link"
rc=0; tn_network_config_render "$T/link" closed none none >/dev/null 2>&1 || rc=$?
check_rc "symlinked data dir refused" 1 "$rc"
check "symlinked data dir: nothing written behind it" "" "$(ls -A "$T/real")"
mkdir -p "$T/isdir/data/network-config"
rc=0; tn_network_config_render "$T/isdir/data" closed none none >/dev/null 2>&1 || rc=$?
check_rc "network-config a directory refused" 1 "$rc"
check "network-config a directory: nothing inside" "" "$(ls -A "$T/isdir/data/network-config")"

# ---- a real service account ----------------------------------------------------
echo "== a real service account owns the data dir"
if [[ "$REAL" == yes ]]; then
    PATH="$ORIG_PATH"
    SVC=tnncsvc
    SVC_MADE=""
    if ! id -u "$SVC" >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin "$SVC" && SVC_MADE=1
    fi
    # a root-owned dir the account can traverse (TN_TEST_TMP is root 0700)
    F="$(mktemp -d /run/tn_nc.XXXXXX)"
    chmod 0755 "$F"
    trap 'rm -rf "$F"; if [[ -n "$SVC_MADE" ]]; then userdel "$SVC" 2>/dev/null; fi; tn_test_cleanup' EXIT
    SERVICE_USER="$SVC"
    SERVICE_GROUP="$SVC"
    D="$F/data"
    mkdir -m 0700 "$D"
    chown "$SVC:$SVC" "$D"
    cp -- "$FX/default.yaml" "$D/network-config"
    chown "$SVC:$SVC" "$D/network-config"
    chmod 0640 "$D/network-config"
    cp -- "$TF" "$F/trusted.yaml"
    cp -- "$CF" "$F/committee.yaml"
    chmod 0644 "$F/trusted.yaml" "$F/committee.yaml"
    rc=0; tn_network_config_render "$D" closed "$F/trusted.yaml" "$F/committee.yaml" > "$T/real.out" 2>&1 || rc=$?
    check_rc "real account: rc" 0 "$rc"
    check "real account: the file belongs to the service account" "${SVC}:${SVC}" "$(stat -c '%U:%G' "$D/network-config")"
    check "real account: the same text as the stubbed edit" "$(cat_file "$T/a.want")" "$(cat_file "$D/network-config")"
    check "real account: no temp file" "" "$(leftovers "$D")"
    chmod 0600 "$F/trusted.yaml"
    cp -- "$D/network-config" "$T/real.before"
    rc=0; tn_network_config_render "$D" grace "$F/trusted.yaml" none > "$T/real.out" 2>&1 || rc=$?
    check_rc "real account: a trusted file only root can read is refused" 1 "$rc"
    check_has "real account: says it cannot read it" \
        "  [ERROR] The admission settings were not written to $D/network-config: cannot read $F/trusted.yaml" \
        "$(plain "$T/real.out")"
    check "real account: unreadable trusted file, network-config unchanged" \
        "$(cat_file "$T/real.before")" "$(cat_file "$D/network-config")"
    R="$F/rootdata"
    mkdir -m 0755 "$R"
    cp -- "$FX/default.yaml" "$R/network-config"
    chmod 0644 "$R/network-config"
    rc=0; tn_network_config_render "$R" closed none none > "$T/real.out" 2>&1 || rc=$?
    check_rc "real account: a data dir only root can write fails (the edit is not root's)" 2 "$rc"
    check "real account: root-owned data dir, unchanged" "$(cat_file "$FX/default.yaml")" "$(cat_file "$R/network-config")"
    check "real account: root-owned data dir, no temp file" "" "$(leftovers "$R")"
    SERVICE_USER=telcoin
    SERVICE_GROUP=telcoin
    PATH="$T/bin:$ORIG_PATH"
else
    skip "real account: the rendered file belongs to the service account" "needs root, setpriv and useradd (ubuntu container)"
    skip "real account: a trusted file only root can read is refused" "needs root, setpriv and useradd (ubuntu container)"
    skip "real account: a data dir only root can write fails" "needs root, setpriv and useradd (ubuntu container)"
fi

# ---- the node's view: a strict YAML load -----------------------------------------
echo "== every rendered file loads as YAML with no duplicate key"
# the node refuses a duplicate key; PyYAML takes the last one unless told not to
PY='
import sys
import yaml

class Strict(yaml.SafeLoader):
    pass

def mapping(loader, node, deep=False):
    seen = set()
    for k, _ in node.value:
        key = loader.construct_object(k, deep=deep)
        if key in seen:
            raise SystemExit("duplicate key %r" % (key,))
        seen.add(key)
    return loader.construct_mapping(node, deep=deep)

Strict.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)
with open(sys.argv[1]) as f:
    doc = yaml.load(f, Loader=Strict)
for key in ("admission", "trusted_nodes", "committee_peers"):
    if key in doc and not isinstance(doc[key], dict):
        raise SystemExit("%s is not a map: %r" % (key, doc[key]))
if doc["admission"]["mode"] not in ("Open", "Grace", "Closed"):
    raise SystemExit("bad mode %r" % (doc["admission"]["mode"],))
print("ok")
'
if command -v python3 >/dev/null 2>&1 && python3 -I -c 'import yaml' >/dev/null 2>&1; then
    for f in "$T"/parsed/*.yaml; do
        res="$(python3 -I -c "$PY" "$f" 2>&1)" || res="FAIL: $res"
        check "loads: ${f##*/}" "ok" "$res"
    done
else
    skip "every rendered file loads as YAML with no duplicate key" "no python3 with PyYAML here"
fi

finish
