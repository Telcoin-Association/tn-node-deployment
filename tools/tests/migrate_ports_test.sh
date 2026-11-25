#!/usr/bin/env bash
# tools/tests/migrate_ports_test.sh -- migrate-node-naming.sh's open_consensus_ports:
# without P2P_ALLOW_FROM it opens UDP 49590 and 49594; with a source list it adds
# one rule per source and port and no open rule; a duplicated or invalid list
# adds nothing; a list the kill switch set aside (P2P_PER_SOURCE=off) opens both
# ports. The function is cut out of the script; ufw and meta_get are
# shims. Maintainer tooling (not updater-tracked). bash 3.2 safe.
# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
sed -n '/^open_consensus_ports() {/,/^}/p' "$TN_TEST_REPO/migrate-node-naming.sh" > "$T/ports.sh"
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "ufw $*" >> "%s/calls"\n' "$T" > "$T/bin/ufw"
chmod 0755 "$T/bin/ufw"
# ports META_RC META_VALUE [PER_SOURCE] -- the ufw calls of one run, joined by
# "; "; P2P_PER_SOURCE reads as PER_SOURCE (absent when empty).
ports() {
    (
        PATH="$T/bin:$PATH"
        eval "meta_get() { if [ \"\$1\" = P2P_PER_SOURCE ]; then [ -n '${3:-}' ] || return 1; printf '%s' '${3:-}'; return 0; fi; printf '%s' '$2'; return $1; }"
        print_step() { :; }
        print_ok() { :; }
        print_warn() { echo "warn $*" >> "$T/calls"; }
        # shellcheck source=/dev/null
        source "$T/ports.sh"
        : > "$T/calls"
        open_consensus_ports
        paste -sd';' "$T/calls" | sed 's/;/; /g'
    )
}
check "no source list: both ports open" "ufw allow 49590/udp; ufw allow 49594/udp" "$(ports 1 '')"
check "a source list: one rule per source and port, no open rule" \
    "ufw allow from 203.0.113.0/24 to any port 49590 proto udp; ufw allow from 2001:db8::1 to any port 49590 proto udp; ufw allow from 203.0.113.0/24 to any port 49594 proto udp; ufw allow from 2001:db8::1 to any port 49594 proto udp" \
    "$(ports 0 '203.0.113.0/24,2001:db8::1')"
check "a duplicated key: nothing opened" "no" "$(ports 2 '' | grep -q 'ufw allow' && echo yes || echo no)"
check "an invalid entry: nothing opened, said" "no yes" \
    "$(o="$(ports 0 '203.0.113.0/24,any')"; printf '%s %s' "$(grep -q 'ufw allow' <<<"$o" && echo yes || echo no)" "$(grep -q 'not an address or CIDR (any)' <<<"$o" && echo yes || echo no)")"
check "a list set aside by the kill switch: both ports open" "ufw allow 49590/udp; ufw allow 49594/udp" "$(ports 0 '203.0.113.0/24' off)"
check "a list set aside, the key set twice: both ports open" "ufw allow 49590/udp; ufw allow 49594/udp" "$(ports 2 '' off)"
check "P2P_PER_SOURCE other than off: the list applies" "ufw allow from 203.0.113.0/24 to any port 49590 proto udp; ufw allow from 203.0.113.0/24 to any port 49594 proto udp" "$(ports 0 '203.0.113.0/24' on)"
finish
