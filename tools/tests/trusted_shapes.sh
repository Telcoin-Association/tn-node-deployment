# shellcheck shell=bash
# =============================================================================
# tools/tests/trusted_shapes.sh -- the trusted nodes map shapes that
# setup_node_admission_test.sh and edit_config_admission_test.sh both put
# through their script, so the two scripts are held to one table. Sourced.
#
#   shape_rows        one row per shape: CLASS NAME REASON. CLASS is
#                       kept  accepted before and after: the node starts with
#                             the map and dials the hub
#                       was   refused by edit-config before and after (the
#                             node stops at start on it); setup-node took it
#                             before and refuses it now
#                       new   refused by both only now: an address the node
#                             cannot use (a DNS name or TCP, which it keeps and
#                             never dials, or a value it stops on)
#                     REASON, the rest of the line, is a part of the refusal
#                     (none for kept).
#   shape_map NAME K1 K2
#                     the map of that shape on stdout: the hub K1 in the shape,
#                     the hub K2 well formed after it.
#
# The shapes are the malformed maps of a review of both scripts plus the
# entries the node itself was seen to refuse or keep undialed. Maintainer
# tooling (not updater-tracked). bash 3.2 safe.
# =============================================================================

shape_rows() {
    cat <<'ROWS'
kept well
kept no-peer-id
kept ipv6
kept quoted
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
was crlf ends in a carriage return
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
ROWS
}

# _shape_hub KEY N -- a well-formed entry: primary and worker 0 on 203.0.113.N
_shape_hub() {
    printf '%s:\n  primary:\n    network_address: /ip4/203.0.113.%s/udp/49590/quic-v1/p2p/12D3KooWShape%sP\n    network_key: 4XTTMshape%sp\n  workers:\n    0:\n      network_address: /ip4/203.0.113.%s/udp/49594/quic-v1/p2p/12D3KooWShape%sW\n      network_key: 4XTTMshape%sw\n' "$1" "$2" "$2" "$2" "$2" "$2" "$2"
}

shape_map() {
    local name="$1" k1="$2" k2="$3" p='/ip4/203.0.113.20/udp/49590/quic-v1'
    case "$name" in
        well) _shape_hub "$k1" 20 ;;
        no-peer-id) _shape_hub "$k1" 20 | sed 's|/p2p/[A-Za-z0-9]*$||' ;;
        ipv6) _shape_hub "$k1" 20 | sed 's|/ip4/203.0.113.20/|/ip6/2001:db8::20/|' ;;
        quoted) _shape_hub "$k1" 20 | sed 's|network_address: \(.*\)$|network_address: "\1"|' ;;
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
        *) return 1 ;;
    esac
    case "$name" in
        flow-json|comment-only|crlf) ;;
        *) _shape_hub "$k2" 21 ;;
    esac
}
