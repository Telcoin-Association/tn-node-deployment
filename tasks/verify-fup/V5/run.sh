#!/usr/bin/env bash
# tasks/verify-fup/V5/run.sh -- run V5's harness in every environment and keep
# the output under tasks/verify-fup/V5/records/. From the repository root:
#   bash tasks/verify-fup/V5/run.sh [bash5|bash32|ubuntu|realnft|pytest|node|units]...
# No argument runs all of them. Exit 0 only when every part passes.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit 2
D=tasks/verify-fup/V5
REC="$D/records"
mkdir -p "$REC"
BASH_PARTS="fw_v5_test.sh fwjson_v5_test.sh rm_v5_test.sh helper_v5_test.sh"
overall=0
part() {   # part NAME CMD... -- run, keep the output, print the summary line
    local name="$1" rc
    shift
    "$@" > "$REC/$name.txt" 2>&1
    rc=$?
    printf '%-22s rc=%s  %s\n' "$name" "$rc" "$(grep -E 'checks,|passed|failed' "$REC/$name.txt" | tail -n1)"
    [[ $rc -eq 0 ]] || overall=1
}
want() { [[ $# -eq 0 ]] && return 0; local w; for w in $SEL; do [[ "$w" == "$1" ]] && return 0; done; return 1; }
SEL="${*:-bash5 bash32 ubuntu realnft pytest node units}"
for p in $BASH_PARTS; do
    want bash5 && part "bash5-${p%.sh}" bash "$D/$p"
    want bash32 && part "bash32-${p%.sh}" docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash "$D/$p"
    want ubuntu && part "ubuntu-${p%.sh}" docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash "$D/$p"
done
want realnft && part realnft docker run --rm --cap-add NET_ADMIN --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    --sysctl net.ipv6.conf.lo.disable_ipv6=0 -v "$PWD:/w" -w /w ubuntu:24.04 bash "$D/realnft_v5.sh"
want pytest && part pytest docker run --rm -v "$PWD:/w" -w /w python:3.10-slim sh -c \
    'pip install -q --require-hashes -r ui/requirements.txt -r ui/tests/requirements-dev.txt >/dev/null 2>&1 && python -m pytest -q -p no:cacheprovider tasks/verify-fup/V5 2>&1 | grep -v "tn-ui\]"'
want node && part node docker run --rm -v "$PWD:/w" -w /w node:22-slim node "$D/render_v5.js"
if want units; then
    u="$(mktemp -d)"
    cp "$REC/telcoin-p2p-limit.service.rendered" "$u/telcoin-p2p-limit.service"
    cp ui/telcoin-ui.service "$u/telcoin-ui.service"
    part units-analyze sh -c "systemd-analyze verify --man=no '$u/telcoin-p2p-limit.service'; echo \"p2p-limit rc=\$?\"; systemd-analyze verify --man=no '$u/telcoin-ui.service'; echo \"ui rc=\$?\""
    rm -rf "$u"
fi
exit "$overall"
