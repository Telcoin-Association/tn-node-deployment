#!/usr/bin/env bash
# =============================================================================
# tools/tests/network_hits_test.sh -- tools/check-network-hits.sh on fixture
# trees
#
#   bash tools/tests/network_hits_test.sh
#
# Builds a fixture tree under the test's temp dir with annotated and
# unannotated hits in each scanned file type (shell, Python, HTML with inline
# JavaScript and CSS, Alloy), the hub and monitor addresses taken from a stub
# lib/testnet-addons.env (addresses no real file names, so a hit proves they
# were read at run time), and an unannotated adiri line in every excluded path.
# Checks the exact findings and exit 1, the --list reasons, exit 0 and the
# count once every hit is annotated, the default root (the tree the lint lives
# in), the exit-2 errors, and last the repository itself: every hit of the
# shipped files must carry a reason. bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SH="${BASH:-bash}"
LINT="$TN_TEST_REPO/tools/check-network-hits.sh"
T="$TN_TEST_TMP"
M="$T/mixed"

# --- the mixed tree ------------------------------------------------------------

mkdir -p "$M/lib/wgvpn" "$M/ui/static" "$M/ui/tests" "$M/observability" \
    "$M/common" "$M/tools/tests" "$M/CHANGELOG" "$M/tasks" "$M/docs" "$M/sub"

# Upper case, single quotes, no export, a user@ and a port: the lint takes the
# bare host or address of each.
cat > "$M/lib/testnet-addons.env" <<'EOF'
# stub of the adiri add-on constants
export TESTNET_ADDONS_VERSION="1.0.0"
export TN_WG_HUB_ENDPOINT="203.0.113.7:51820"
export TN_KUMA_SRC="198.51.100.9/32"   # monitor
export OBS_PUSH_URL_TESTNET="https://Logs.Hub.Example/loki/api/v1/push"
OBS_METRICS_PUSH_URL_TESTNET='https://user@metrics.hub.example:8443/api/v1/write'
EOF

cat > "$M/lib/alpha.sh" <<'EOF'
#!/usr/bin/env bash
readonly RPC_A="https://rpc.adiri.tel"
readonly RPC_B="https://rpc.adiri.tel"  # network-gated: testnet constant, selected by NETWORK
# network-gated: testnet release tag form, checked per network
re='^v[0-9.]+-adiri$'
tag="V1.2.3-ADIRI"
hub="203.0.113.7:51820"
kuma="198.51.100.9"  # network-gated: monitor source of the testnet add-on
# network-gated:
echo "rpc.adiri.tel"
# network-gated: --
echo "rpc.adiri.tel"
# network-gated: hub address of the adiri testnet add-on
hub_again="203.0.113.7"
# network-gated: two lines above does not count

echo "Adiri Testnet"
echo "network-gated: not a comment" "adiri"
logs="https://logs.hub.example/loki/api/v1/push"
metrics="metrics.hub.example"
plain="no hit here"
EOF

cat > "$M/setup.sh" <<'EOF'
#!/usr/bin/env bash
# The testnet is adiri.
echo ok
EOF

cat > "$M/ui/server.py" <<'EOF'
STATUS = {"testnet": "https://status.adiri.telcoin.network/"}  # network-gated: status page per network
# network-gated: testnet chain name, selected by the network setting
CHAIN = "adiri"
HUB = "https://LOGS.HUB.EXAMPLE/x"
EOF

cat > "$M/ui/telcoin-ui-helper.sh" <<'EOF'
#!/usr/bin/env bash
# network-gated: example shown only when NETWORK=testnet
printf '%s\n' "v0.16.0-adiri"
printf '%s\n' "v0.16.0-adiri"
EOF

# The installer: a marker inside the heredoc it writes would land in that
# file, so the fixture has one hit there and one below a marker line.
cat > "$M/ui/install-ui.sh" <<'EOF'
#!/usr/bin/env bash
cat > "$f" <<SUDOERS
# update-prepare takes vX.Y.Z-adiri on testnet
SUDOERS
# network-gated: the testnet tag form, beside the mainnet one
tag="v0.16.0-adiri"
EOF

cat > "$M/ui/static/index.html" <<'EOF'
<!doctype html>
<!-- network-gated: status page per network (STATUS_PAGE_LINKS) -->
<a href="https://status.adiri.telcoin.network/">status</a>
<!-- network-gated: -->
<p>Adiri Testnet</p>
<script>
// network-gated: testnet label, shown only when the server reports testnet
const label = "Adiri";
const other = "adiri"; // network-gated: same label for the badge
</script>
<style>.adiri { color: red; } /* network-gated: testnet badge colour */</style>
EOF
# A marker line is nothing but the marker comment: code after the close of a
# <!-- or /* marker, or no close at all, leaves the next line uncovered.
{
    printf '<p>adiri</p>\r\n'
    cat <<'EOF'
<!-- network-gated: code follows the close --> <b>adiri on the marker line</b>
<p>adiri below a marker line that also holds code</p>
/* network-gated: code follows the close */ .x { color: red; }
.adiri { color: blue; }
EOF
    printf '/* network-gated: only blanks after the close */ \t \n'
    cat <<'EOF'
.adiri-ok { color: green; }
<!-- network-gated: the close is missing
<p>adiri below an unclosed marker</p>
EOF
} >> "$M/ui/static/index.html"

cat > "$M/observability/config.alloy" <<'EOF'
// vendored from adiri-genesis
// network-gated: header note naming the testnet source repository
// mirrored from adiri-genesis
endpoint { url = sys.env("OBS_PUSH_URL") }
EOF

# Out of scope: each holds an unannotated hit that must not be reported.
for f in lib/wgvpn/hub.sh common/c.sh tools/t.sh tools/tests/x_test.sh \
    ui/tests/helper_test.sh ui/test_server.py \
    CHANGELOG/scripts-v9.md CHANGELOG.md tasks/plan.md followup.md \
    docs/guide.md docs/build.sh README.md lib/notes.md setup-node.sh.sha256 \
    lib/alpha.sh.sha256 sub/deep.sh; do
    printf 'echo "rpc.adiri.tel 203.0.113.7"\n' > "$M/$f"
done

# --- findings and exit 1 -------------------------------------------------------

WANT="lib/alpha.sh:2: readonly RPC_A=\"https://rpc.adiri.tel\"
lib/alpha.sh:6: tag=\"V1.2.3-ADIRI\"
lib/alpha.sh:7: hub=\"203.0.113.7:51820\"
lib/alpha.sh:10: echo \"rpc.adiri.tel\"
lib/alpha.sh:12: echo \"rpc.adiri.tel\"
lib/alpha.sh:17: echo \"Adiri Testnet\"
lib/alpha.sh:18: echo \"network-gated: not a comment\" \"adiri\"
lib/alpha.sh:19: logs=\"https://logs.hub.example/loki/api/v1/push\"
lib/alpha.sh:20: metrics=\"metrics.hub.example\"
setup.sh:2: # The testnet is adiri.
ui/server.py:4: HUB = \"https://LOGS.HUB.EXAMPLE/x\"
ui/telcoin-ui-helper.sh:4: printf '%s\\n' \"v0.16.0-adiri\"
ui/install-ui.sh:3: # update-prepare takes vX.Y.Z-adiri on testnet
ui/static/index.html:5: <p>Adiri Testnet</p>
ui/static/index.html:12: <p>adiri</p>
ui/static/index.html:14: <p>adiri below a marker line that also holds code</p>
ui/static/index.html:16: .adiri { color: blue; }
ui/static/index.html:20: <p>adiri below an unclosed marker</p>
observability/config.alloy:1: // vendored from adiri-genesis"

out="$("$SH" "$LINT" "$M" 2> "$T/err")"
rc=$?
check_rc "mixed tree: exit 1" 1 "$rc"
check "mixed tree: exactly the unannotated hits, in scan order" "$WANT" "$out"
check "mixed tree: the summary counts them" \
    'check-network-hits: 19 of 35 hit(s) in 7 file(s) scanned have no network-gated: reason; mark each with "# network-gated: <reason>" (// or <!-- --> in JavaScript, Alloy and HTML) on the line or on a line of its own above' \
    "$(cat "$T/err")"
check_lacks "excluded paths are never reported" 'rpc.adiri.tel 203.0.113.7' "$out"
check_lacks "lib/testnet-addons.env itself is not scanned" "testnet-addons.env" "$out"

# --- --list --------------------------------------------------------------------

lst="$("$SH" "$LINT" --list "$M" 2> "$T/err")"
rc=$?
check_rc "--list: exit 1 while hits are unannotated" 1 "$rc"
check "--list: one line per hit" 35 "$(printf '%s\n' "$lst" | grep -c .)"
check "--list: the unannotated hits are the findings" \
    "$(printf '%s\n' "$WANT" | sed 's/^\([^:]*:[0-9]*\):.*/\1/')" \
    "$(printf '%s\n' "$lst" | sed -n 's/^\([^:]*:[0-9]*\): unannotated -- .*/\1/p')"
check_has "--list: a trailing marker gives its own line's reason" \
    'lib/alpha.sh:3: testnet constant, selected by NETWORK -- readonly RPC_B="https://rpc.adiri.tel"  # network-gated: testnet constant, selected by NETWORK' "$lst"
check_has "--list: a marker line covers the line below it" \
    "lib/alpha.sh:5: testnet release tag form, checked per network -- re='^v[0-9.]+-adiri\$'" "$lst"
check_has "--list: a marker line that names adiri is itself annotated" \
    'lib/alpha.sh:13: hub address of the adiri testnet add-on -- # network-gated: hub address of the adiri testnet add-on' "$lst"
check_has "--list: the hub address below that marker line" \
    'lib/alpha.sh:14: hub address of the adiri testnet add-on -- hub_again="203.0.113.7"' "$lst"
check_has "--list: the monitor address from the stub env" \
    'lib/alpha.sh:8: monitor source of the testnet add-on -- kuma="198.51.100.9"  # network-gated: monitor source of the testnet add-on' "$lst"
check_has "--list: an empty reason covers nothing" \
    'lib/alpha.sh:10: unannotated -- echo "rpc.adiri.tel"' "$lst"
check_has "--list: a reason without a letter or digit covers nothing" \
    'lib/alpha.sh:12: unannotated -- echo "rpc.adiri.tel"' "$lst"
check_has "--list: upper case ADIRI is a hit" \
    'lib/alpha.sh:6: unannotated -- tag="V1.2.3-ADIRI"' "$lst"
check_has "--list: Python, the marker line above" \
    'ui/server.py:3: testnet chain name, selected by the network setting -- CHAIN = "adiri"' "$lst"
check_has "--list: one marker line covers one line only" \
    "ui/telcoin-ui-helper.sh:4: unannotated -- printf '%s\\n' \"v0.16.0-adiri\"" "$lst"
check_has "--list: HTML, the closing --> is not part of the reason" \
    'ui/static/index.html:3: status page per network (STATUS_PAGE_LINKS) -- <a href="https://status.adiri.telcoin.network/">status</a>' "$lst"
check_has "--list: HTML, an empty <!-- network-gated: --> covers nothing" \
    'ui/static/index.html:5: unannotated -- <p>Adiri Testnet</p>' "$lst"
check_has "--list: JavaScript, the marker line above" \
    'ui/static/index.html:8: testnet label, shown only when the server reports testnet -- const label = "Adiri";' "$lst"
check_has "--list: JavaScript, a trailing marker" \
    'ui/static/index.html:9: same label for the badge -- const other = "adiri"; // network-gated: same label for the badge' "$lst"
check_has "--list: CSS, the closing */ is not part of the reason" \
    'ui/static/index.html:11: testnet badge colour -- <style>.adiri { color: red; } /* network-gated: testnet badge colour */</style>' "$lst"
check_has "--list: a trailing marker covers its own line only, not the next" \
    'ui/static/index.html:12: unannotated -- <p>adiri</p>' "$lst"
check_has "--list: a marker line that also holds code covers its own line" \
    'ui/static/index.html:13: code follows the close -- <!-- network-gated: code follows the close --> <b>adiri on the marker line</b>' "$lst"
check_has "--list: code after the --> of a marker: the next line is not covered" \
    'ui/static/index.html:14: unannotated -- <p>adiri below a marker line that also holds code</p>' "$lst"
check_has "--list: code after the */ of a marker: the next line is not covered" \
    'ui/static/index.html:16: unannotated -- .adiri { color: blue; }' "$lst"
check_has "--list: only blanks after the */: a marker line" \
    'ui/static/index.html:18: only blanks after the close -- .adiri-ok { color: green; }' "$lst"
check_has "--list: a <!-- marker that does not close: the next line is not covered" \
    'ui/static/index.html:20: unannotated -- <p>adiri below an unclosed marker</p>' "$lst"
check_has "--list: ui/install-ui.sh is scanned, the marker line above" \
    'ui/install-ui.sh:6: the testnet tag form, beside the mainnet one -- tag="v0.16.0-adiri"' "$lst"
check_has "--list: Alloy, the marker line above" \
    'observability/config.alloy:3: header note naming the testnet source repository -- // mirrored from adiri-genesis' "$lst"
check_has "--list: stderr names the patterns read from the stub env" \
    'check-network-hits: patterns adiri, logs.hub.example, metrics.hub.example, 203.0.113.7, 198.51.100.9' "$(cat "$T/err")"
check_lacks "--list: excluded paths are never listed" 'rpc.adiri.tel 203.0.113.7' "$lst"
lst2="$("$SH" "$LINT" "$M" --list 2>/dev/null)"
check "--list after ROOT: the same output" "$lst" "$lst2"

# --- every hit annotated: exit 0 with the count ---------------------------------

C="$T/clean"
cp -R "$M" "$C"
# Annotate each finding with the marker form of its file type.
printf '%s\n' "$out" | sed 's/^\([^:]*\):\([0-9]*\):.*/\1 \2/' > "$T/findings"
while read -r f n; do
    case "$f" in
        *.html) m=' <!-- network-gated: fixture -->' ;;
        *.alloy) m=' // network-gated: fixture' ;;
        *) m=' # network-gated: fixture' ;;
    esac
    awk -v n="$n" -v m="$m" 'FNR == n { sub(/\r$/, ""); $0 = $0 m } { print }' "$C/$f" > "$C/$f.new"
    mv "$C/$f.new" "$C/$f"
done < "$T/findings"
out="$("$SH" "$LINT" "$C" 2> "$T/err")"
rc=$?
check_rc "clean tree: exit 0" 0 "$rc"
check "clean tree: nothing on stdout" "" "$out"
check "clean tree: the count of annotated hits" \
    "check-network-hits: clean, 35 annotated hit(s) in 7 file(s) scanned" "$(cat "$T/err")"

# The default root is the tree the lint lives in, from its root or elsewhere.
# The copy under tools/ names adiri itself and is out of scope.
cp "$LINT" "$C/tools/check-network-hits.sh"
out="$(cd "$C" && "$SH" tools/check-network-hits.sh 2> "$T/err")"
rc=$?
check_rc "no ROOT, run from the tree root: exit 0" 0 "$rc"
check "no ROOT, run from the tree root: the same count" \
    "check-network-hits: clean, 35 annotated hit(s) in 7 file(s) scanned" "$(cat "$T/err")"
out="$(cd "$T" && "$SH" "$C/tools/check-network-hits.sh" 2> "$T/err")"
rc=$?
check_rc "no ROOT, run from another directory: exit 0" 0 "$rc"
check "no ROOT, run from another directory: the same count" \
    "check-network-hits: clean, 35 annotated hit(s) in 7 file(s) scanned" "$(cat "$T/err")"
out="$(cd "$M" && "$SH" "$C/tools/check-network-hits.sh" 2>/dev/null)"
rc=$?
check_rc "no ROOT: the current directory is not the root" 0 "$rc"

# --- usage and input errors: exit 2 ---------------------------------------------

out="$("$SH" "$LINT" --help 2>&1)"
rc=$?
check_rc "--help: exit 0" 0 "$rc"
check_has "--help: the usage line" "usage: tools/check-network-hits.sh [--list] [ROOT]" "$out"

out="$("$SH" "$LINT" --bogus "$C" 2>&1)"
rc=$?
check_rc "unknown option: exit 2" 2 "$rc"
check_has "unknown option: named" "check-network-hits: unknown option --bogus" "$out"

out="$("$SH" "$LINT" "$C" "$M" 2>&1)"
rc=$?
check_rc "two roots: exit 2" 2 "$rc"

out="$("$SH" "$LINT" "$T/no-such-dir" 2>&1)"
rc=$?
check_rc "a ROOT that is not a directory: exit 2" 2 "$rc"
check_has "a ROOT that is not a directory: said" \
    "check-network-hits: $T/no-such-dir is not a directory; give the repository root" "$out"

E="$T/err-tree"
cp -R "$C" "$E"
rm -f "$E/lib/testnet-addons.env"
out="$("$SH" "$LINT" "$E" 2>&1)"
rc=$?
check_rc "no lib/testnet-addons.env: exit 2" 2 "$rc"
check_has "no lib/testnet-addons.env: said" \
    "check-network-hits: cannot read $E/lib/testnet-addons.env, which names the hub and monitor addresses" "$out"

grep -v TN_KUMA_SRC "$C/lib/testnet-addons.env" > "$E/lib/testnet-addons.env"
out="$("$SH" "$LINT" "$E" 2>&1)"
rc=$?
check_rc "no TN_KUMA_SRC in the env: exit 2" 2 "$rc"
check_has "no TN_KUMA_SRC in the env: said" \
    "check-network-hits: no TN_KUMA_SRC address in lib/testnet-addons.env; the lint needs it to find the hub and monitor addresses" "$out"

# shellcheck disable=SC2016 # the ${...} is the text written into the stub env
sed 's|^export TN_WG_HUB_ENDPOINT=.*|export TN_WG_HUB_ENDPOINT="${TN_WG_HUB_ENDPOINT:-203.0.113.7:51820}"|' \
    "$C/lib/testnet-addons.env" > "$E/lib/testnet-addons.env"
out="$("$SH" "$LINT" "$E" 2>&1)"
rc=$?
check_rc "a value that is not literal: exit 2" 2 "$rc"
check_has "a value that is not literal: said" \
    "check-network-hits: TN_WG_HUB_ENDPOINT in lib/testnet-addons.env is not a literal value (\${TN_WG_HUB_ENDPOINT:-203.0.113.7:51820}); the lint reads it as text" "$out"

cp "$C/lib/testnet-addons.env" "$E/lib/testnet-addons.env"
rm -f "$E/ui/server.py"
out="$("$SH" "$LINT" "$E" 2>&1)"
rc=$?
check_rc "a scanned file is missing: exit 2" 2 "$rc"
check_has "a scanned file is missing: said" \
    "check-network-hits: $E/ui/server.py is missing; the lint scans it by name" "$out"

# --- the tree --------------------------------------------------------------------

# Every testnet name and hub address of the shipped files carries a reason.
out="$("$SH" "$LINT" "$TN_TEST_REPO" 2> "$T/err")"
rc=$?
check_rc "the tree: exit 0" 0 "$rc"
check "the tree: no unannotated hit" "" "$out"

finish
