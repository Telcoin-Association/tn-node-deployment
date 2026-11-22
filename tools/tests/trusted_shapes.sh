# shellcheck shell=bash
# =============================================================================
# tools/tests/trusted_shapes.sh -- the trusted nodes map shapes that
# setup_node_admission_test.sh and edit_config_admission_test.sh both put
# through their script, so the two scripts are held to one table. Sourced.
#
#   shape_rows        one row per shape: CLASS NAME REASON. CLASS is
#                       kept  accepted: the node starts with the map and
#                             lists the hub as trusted
#                       was   refused by edit-config before and after (the
#                             node stops at start on it); setup-node took it
#                             before and refuses it now
#                       new   refused by both only now: an address the node
#                             cannot use (a DNS name, TCP or port 0, which it
#                             keeps and never dials, or a value it stops on),
#                             or worker ids other than those of the one worker
#                             this node runs, on which it stops at start
#                       node  passes the shape check; the node binary's parse
#                             of the map (tn_trusted_nodes_node_check) refuses
#                             it, and the node stops at start on it
#                       start passes both checks, and the node stops at start
#                             on it: a /p2p peer id that is not its
#                             network_key's, which the node checks only then
#                       strict refused by both, though the node starts with
#                             it: a layout the check does not read
#                     REASON, the rest of the line, is a part of the refusal
#                     (none for kept and start; for node, the node's reason).
#   shape_map NAME K1 K2
#                     the map of that shape on stdout: the hub K1 in the shape,
#                     the hub K2 well formed after it.
#
# The shapes are the malformed maps of a review of both scripts plus the
# entries the node itself was seen to refuse, keep undialed or take. The hubs
# carry the network keys and peer ids of two real hubs, so every row can be
# run on the node itself with K1 and K2 real BLS keys: each class above is
# what the node did with its row. Maintainer tooling (not updater-tracked).
# bash 3.2 safe.
# =============================================================================

shape_rows() {
    cat <<'ROWS'
kept well
kept no-peer-id
kept ipv6
kept quoted
kept quoted-fields
kept crlf
kept bom
was workers-list is not a worker id
was node-info-entry name is not a field of a trusted node
was no-network-key has no network_key
was no-workers has no workers
was short-key is not a BLS public key: it is 10 characters long
was key-only has no primary
was null-address is empty
was flow-json is not a BLS public key and a colon
was second-doc starts a second YAML document
was tab-indent is indented with a tab
was comment-only holds no BLS public key entries
new dns4 is a DNS name (/dns4/hub.example.org/udp/49590
new dns4-no-peer-id is a DNS name (/dns4/hub.example.org/udp/49590
new dns4-worker is a DNS name (/dns4/hub.example.org/udp/49594
new dns6 is a DNS name (/dns6/
new dns is a DNS name (/dns/
new dnsaddr is a DNS name (/dnsaddr/
new multiaddr-garbage (not-a-multiaddr) is not an address the node can dial
new peer-id-garbage is not an address the node can dial
new tcp-not-quic is not an address the node can dial
new port-zero is not an address the node can dial
new workers-three worker 1 of
new workers-one-zero worker 1 of
new worker-65535 worker 65535 of
new worker-1-only worker 1 of
new worker-00 00 is not a worker id
node ip4-leading-zero data did not match any variant
node ip6-garbage data did not match any variant
node ip6-short data did not match any variant
node peer-id-bad data did not match any variant
node network-key-bad data did not match any variant
node bls-not-a-key expected valid bls public key bytes
node field-twice data did not match any variant
node deeper-line mapping values are not allowed
node deeper-line-worker mapping values are not allowed
start peer-id-other
start keys-swapped
strict anchor is not an address the node can dial
strict flow-primary write primary as a block
strict value-next-line is empty
strict port-zero-padded is not an address the node can dial
ROWS
}

# _shape_hub KEY N -- a well-formed entry: primary and worker 0 on 203.0.113.N,
# with the network keys and peer ids of hub N (20 or 21)
_shape_hub() {
    local pp pk wp wk
    case "$2" in
        20) pp=12D3KooWCUNnqdQR5sTmUdHMmoiLTLJVzTxfeZAAUdyhEwCatAWk pk=4XTTM3o4SgmsVhEbRWHjmtqcAbvxAU8x7mmmQCrPTHAp7qwHr
            wp=12D3KooWMq14cS2eFZx8eFxTMEsubJk5PBVQTPHmCRVnFsGXEh3J wk=4XTTMD9giTaVirw5nfvQsUGmjjuPjrrUrabtzvduYJ6t4CTpQ ;;
        *) pp=12D3KooWN7mVkZwmMnL2xAShy6iEyP4a59bQL7MwsTD2bYg4UPiu pk=4XTTMDST9biQqy9Tgypu868c57yiEYparTKyBbfcndnHbSAW1
            wp=12D3KooWSohmh29sn1QbFmLT1Ap5KB9J8gBDtswYDFR3jpemXvJv wk=4XTTMJ8PRYAcxPNYFHRns8ChuTmnxcMAg26YmwTpon4GJVh62 ;;
    esac
    printf '%s:\n  primary:\n    network_address: /ip4/203.0.113.%s/udp/49590/quic-v1/p2p/%s\n    network_key: %s\n  workers:\n    0:\n      network_address: /ip4/203.0.113.%s/udp/49594/quic-v1/p2p/%s\n      network_key: %s\n' "$1" "$2" "$pp" "$pk" "$2" "$wp" "$wk"
}
# _shape_worker ID -- worker ID of hub 20, as the last lines of an entry
_shape_worker() {
    _shape_hub x 20 | sed -n '6,8p' | sed "s/^    0:/    ${1}:/"
}

shape_map() {
    local name="$1" k1="$2" k2="$3" p='/ip4/203.0.113.20/udp/49590/quic-v1'
    case "$name" in
        well) _shape_hub "$k1" 20 ;;
        no-peer-id) _shape_hub "$k1" 20 | sed 's|/p2p/[A-Za-z0-9]*$||' ;;
        ipv6) _shape_hub "$k1" 20 | sed 's|/ip4/203.0.113.20/|/ip6/2001:db8::20/|' ;;
        quoted) _shape_hub "$k1" 20 | sed 's|network_address: \(.*\)$|network_address: "\1"|' ;;
        quoted-fields) _shape_hub "$k1" 20 | sed -E 's/^( *)(primary|workers|network_address):/\1"\2":/' ;;
        bom) printf '\357\273\277'; _shape_hub "$k1" 20 ;;
        workers-list)
            _shape_hub "$k1" 20 | sed -e '/^    0:$/d' -e 's|^      network_address|    - network_address|' ;;
        node-info-entry)
            printf '%s:\n  name: hub-a\n  bls_public_key: %s\n  p2p_info:\n    primary:\n      network_address: %s\n      network_key: 4XTTMshape20p\n' "$k1" "$k1" "$p" ;;
        no-network-key) _shape_hub "$k1" 20 | grep -v '^    network_key' ;;
        no-workers) _shape_hub "$k1" 20 | head -n 4 ;;
        short-key) _shape_hub HubBLSkey1 20 ;;
        key-only) printf '%s:\n' "$k1" ;;
        null-address) _shape_hub "$k1" 20 | sed "s|^    network_address: .*|    network_address: ~|" ;;
        flow-json) printf '{"%s": {"primary": {"network_address": "%s", "network_key": "k"}, "workers": {}}}\n' "$k1" "$p" ;;
        second-doc) _shape_hub "$k1" 20; printf -- '---\n' ;;
        tab-indent) _shape_hub "$k1" 20 | awk '{ sub(/^    network_address/, "\tnetwork_address"); print }' ;;
        crlf) _shape_hub "$k1" 20 | awk '{ printf "%s\r\n", $0 }' ;;
        comment-only) printf '# no hubs yet\n' ;;
        dns4) _shape_hub "$k1" 20 | sed 's|/ip4/203.0.113.20/|/dns4/hub.example.org/|' ;;
        dns4-no-peer-id) _shape_hub "$k1" 20 | sed -e 's|/ip4/203.0.113.20/|/dns4/hub.example.org/|' -e 's|/p2p/[A-Za-z0-9]*$||' ;;
        dns4-worker) _shape_hub "$k1" 20 | sed 's|/ip4/203.0.113.20/udp/49594|/dns4/hub.example.org/udp/49594|' ;;
        dns6) _shape_hub "$k1" 20 | sed '3s|/ip4/203.0.113.20/|/dns6/hub.example.org/|' ;;
        dns) _shape_hub "$k1" 20 | sed '3s|/ip4/203.0.113.20/|/dns/hub.example.org/|' ;;
        dnsaddr) _shape_hub "$k1" 20 | sed '3s|/ip4/203.0.113.20/udp/49590/quic-v1|/dnsaddr/hub.example.org|' ;;
        multiaddr-garbage) _shape_hub "$k1" 20 | sed '3s|network_address: .*|network_address: not-a-multiaddr|' ;;
        peer-id-garbage) _shape_hub "$k1" 20 | sed '3s|/p2p/[A-Za-z0-9]*$|/p2p/not+a+peer+id|' ;;
        tcp-not-quic) _shape_hub "$k1" 20 | sed '3s|/udp/49590/quic-v1|/tcp/49590|' ;;
        port-zero) _shape_hub "$k1" 20 | sed '3s|/udp/49590/|/udp/0/|' ;;
        workers-three) _shape_hub "$k1" 20; _shape_worker 1; _shape_worker 2 ;;
        workers-one-zero) _shape_hub "$k1" 20 | head -n 5; _shape_worker 1; _shape_worker 0 ;;
        worker-65535) _shape_hub "$k1" 20 | sed 's/^    0:$/    65535:/' ;;
        worker-1-only) _shape_hub "$k1" 20 | sed 's/^    0:$/    1:/' ;;
        worker-00) _shape_hub "$k1" 20 | sed 's/^    0:$/    00:/' ;;
        ip4-leading-zero) _shape_hub "$k1" 20 | sed '3s|/ip4/203.0.113.20/|/ip4/203.0.113.020/|' ;;
        ip6-garbage) _shape_hub "$k1" 20 | sed '3s|/ip4/203.0.113.20/|/ip6/:::/|' ;;
        ip6-short) _shape_hub "$k1" 20 | sed '3s|/ip4/203.0.113.20/|/ip6/1:2/|' ;;
        peer-id-bad) _shape_hub "$k1" 20 | sed '3s|/p2p/[A-Za-z0-9]*$|/p2p/abc|' ;;
        network-key-bad) _shape_hub "$k1" 20 | sed '4s|network_key: .*|network_key: 4XTTMnotakey|' ;;
        bls-not-a-key) _shape_hub 22222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222 20 ;;
        field-twice) _shape_hub "$k1" 20 | sed '3p' ;;
        deeper-line) _shape_hub "$k1" 20 | awk '{ print } NR == 4 { print "      extra: 1" }' ;;
        deeper-line-worker) _shape_hub "$k1" 20; printf '        extra: 1\n' ;;
        peer-id-other) _shape_hub "$k1" 20 | sed "3s|/p2p/.*|/p2p/$(_shape_hub x 21 | sed -n '3s|.*/p2p/||p')|" ;;
        keys-swapped)
            _shape_hub "$k1" 20 | awk '{ l[NR] = $0 } END { a = l[4]; b = l[8]; sub(/.*: /, "", a); sub(/.*: /, "", b)
                sub(/: .*/, ": " b, l[4]); sub(/: .*/, ": " a, l[8]); for (i = 1; i <= NR; i++) print l[i] }' ;;
        anchor) _shape_hub "$k1" 20 | sed '3s|network_address: |network_address: \&pa |' ;;
        flow-primary)
            _shape_hub "$k1" 20 | awk 'NR == 3 || NR == 4 { v = $0; sub(/^ */, "", v); f = f (NR == 4 ? ", " : "") v; next }
                NR == 2 { next } NR == 5 { print "  primary: {" f "}" } { print }' ;;
        value-next-line) _shape_hub "$k1" 20 | awk 'NR == 3 { sub(/network_address: /, "network_address:\n      ") } { print }' ;;
        port-zero-padded) _shape_hub "$k1" 20 | sed '3s|/udp/49590/|/udp/049590/|' ;;
        *) return 1 ;;
    esac
    case "$name" in
        flow-json|comment-only|crlf) ;;
        *) _shape_hub "$k2" 21 ;;
    esac
}
