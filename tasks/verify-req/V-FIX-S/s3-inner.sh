#!/usr/bin/env bash
# =============================================================================
# s3-inner.sh -- V-FIX-S S3: version skew, run for real as root in a
# disposable ubuntu:26.04 container (through vrun.sh). /s = scripts at the
# tip, /old = scripts at 01664cc.
#   A: the new setup-node.sh beside the library of 01664cc: must refuse up
#      front (plain and --json), writing nothing.
#   B: the setup-node.sh of 01664cc beside the new library, through
#      s2-case.sh (S2_SN/S2_LIB): fresh host; then a host whose checkout sits
#      on the diverged default branch (pinned dir kept, then emptied).
# =============================================================================
set -u
# shellcheck source=tasks/verify-req/V-FIX-S/vcommon.sh
. /h/vcommon.sh
v_setup

say "== A: new setup-node.sh ($(grep -m1 '^readonly SCRIPT_VERSION=' /s/setup-node.sh)) + old lib ($(grep -m1 '^readonly COMMON_VERSION=' /old/lib/common.sh)) =="
mkdir -p /opt/skewA/lib
cp /s/setup-node.sh /opt/skewA/setup-node.sh
cp -R /old/lib/. /opt/skewA/lib/
touch /opt/skew-marker
sleep 1
rc=0
env -i PATH="$WRAPPATH" HOME=/root bash /opt/skewA/setup-node.sh > "${OUT}/A-plain.out" 2> "${OUT}/A-plain.err" < /dev/null || rc=$?
say "[A-plain] rc=${rc} stdout-lines=$(wc -l < "${OUT}/A-plain.out")"
sed 's/^/[A-plain]   err| /' "${OUT}/A-plain.err" >> "$DEC"
rc=0
env -i PATH="$WRAPPATH" HOME=/root bash /opt/skewA/setup-node.sh --json --phase=keygen --network testnet \
    > "${OUT}/A-json.out" 2> "${OUT}/A-json.err" < /dev/null || rc=$?
say "[A-json] rc=${rc} stderr-lines=$(wc -l < "${OUT}/A-json.err")"
sed 's/^/[A-json]   out| /' "${OUT}/A-json.out" >> "$DEC"
rc=0
env -i PATH="$WRAPPATH" HOME=/root bash /opt/skewA/setup-node.sh --network testnet --json --phase=finalize \
    > "${OUT}/A-json2.out" 2> "${OUT}/A-json2.err" < /dev/null || rc=$?
say "[A-json-finalize] rc=${rc} out-lines=$(wc -l < "${OUT}/A-json2.out")"
say "[A] files written since the marker (outside /opt/skewA, /out, /proc, /sys, /dev, /tmp): $(find / -xdev -newer /opt/skew-marker ! -path '/opt/skewA*' ! -path '/out*' ! -path '/proc*' ! -path '/sys*' ! -path '/dev*' ! -path '/tmp*' 2>/dev/null | wc -l)"
find / -xdev -newer /opt/skew-marker ! -path '/opt/skewA*' ! -path '/out*' ! -path '/proc*' ! -path '/sys*' ! -path '/dev*' ! -path '/tmp*' 2>/dev/null | head -5 | sed 's/^/[A]   new: /' >> "$DEC"
say "[A] git calls: $(wc -l < /out/gitwrap.log)"

say "== B1: old setup-node.sh ($(grep -m1 '^readonly SCRIPT_VERSION=' /old/setup-node.sh)) + new lib, fresh host =="
run_case B1-infra infra plain '\n\ny\n' S2_SN=/old/setup-node.sh S2_LIB=/s/lib
say "[B1] HEAD=$(git -C "$SRC" rev-parse HEAD 2>/dev/null) pinned files: $(find "$PIN" -type f 2>/dev/null | wc -l)"
run_case B1-write write plain '' S2_SN=/old/setup-node.sh S2_LIB=/s/lib
say "[B1] copies: $(sha256sum /var/lib/telcoin/genesis/committee.yaml 2>&1 | cut -c1-16)"

say "== B2: old setup-node.sh + new lib, checkout on the diverged default branch, pinned dir in place =="
git -C "$SRC" checkout -q -B main origin/main
rm -f /var/lib/telcoin/genesis/genesis.yaml /var/lib/telcoin/genesis/committee.yaml /var/lib/telcoin/parameters.yaml
run_case B2-infra infra plain '\n\n' S2_SN=/old/setup-node.sh S2_LIB=/s/lib
run_case B2-write write plain '' S2_SN=/old/setup-node.sh S2_LIB=/s/lib
run_case B2-finalize write json '' S2_SN=/old/setup-node.sh S2_LIB=/s/lib
say "[B2] data dir copies left: $(find /var/lib/telcoin -name '*.yaml' | wc -l)"

say "== B3: old setup-node.sh + new lib, diverged checkout, pinned dir emptied (UI keygen then finalize) =="
empty_pin
run_case B3-keygen infra json '' S2_SN=/old/setup-node.sh S2_LIB=/s/lib
say "[B3] pinned files: $(find "$PIN" -type f | wc -l); HEAD=$(git -C "$SRC" rev-parse --abbrev-ref HEAD)"
run_case B3-finalize write json '' S2_SN=/old/setup-node.sh S2_LIB=/s/lib

say "== B4: control, new setup-node.sh + new lib on the same diverged host =="
run_case B4-finalize write json ''

chown -R 1000:1000 "$OUT" 2>/dev/null || true
exit 0
