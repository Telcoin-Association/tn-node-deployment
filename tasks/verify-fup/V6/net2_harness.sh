#!/usr/bin/env bash
# V6 independent harness for tools/check-network-hits.sh (NET-2, issue #47).
# Builds its own fixture tree and checks the lint contract of
# tasks/spec-fup-NET-2.md. Usage: bash net2_harness.sh [LINT]
# Prints PASS/FAIL per case and a final count; exit 1 on any FAIL.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="${1:-$here/../../../tools/check-network-hits.sh}"
SH="${BASH:-bash}"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; if [ -n "${2:-}" ]; then printf '     %s\n' "$2"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2] got [$3]"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "missing [$2]" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1" "unexpected [$2]" ;; *) ok "$1" ;; esac; }

T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT
R="$T/root"

mk_tree() {
    rm -rf "${R:?}"
    mkdir -p "$R/lib/wgvpn" "$R/lib/sub" "$R/ui/static" "$R/observability" \
        "$R/common" "$R/tools/tests" "$R/tests" "$R/tasks" "$R/docs" "$R/CHANGELOG"
    # stub env: mixed case, quotes, no export, a port, a prefix, a trailing comment
    cat > "$R/lib/testnet-addons.env" <<'EOF'
# stub
export OBS_PUSH_URL_TESTNET="https://Logs.Hub.Test:8443/loki/api/v1/push"
OBS_METRICS_PUSH_URL_TESTNET='https://metrics.hub.test/api/v1/write'
export TN_WG_HUB_ENDPOINT=198.51.100.20:51820   # hub
export TN_KUMA_SRC="192.0.2.5/32"
EOF
    : > "$R/ui/server.py"
    : > "$R/ui/telcoin-ui-helper.sh"
    : > "$R/ui/static/index.html"
    : > "$R/observability/config.alloy"
}

run() { # run [args...] -> $out $err $rc
    out="$("$SH" "$LINT" "$@" 2> "$T/err")"
    rc=$?
    err="$(cat "$T/err")"
}

# ---- 1. shell file forms --------------------------------------------------
mk_tree
cat > "$R/lib/a.sh" <<'EOF'
#!/bin/bash
url="https://rpc.adiri.tel"
url2="https://rpc.adiri.tel"  # network-gated: trailing reason
# network-gated: marker above
tag="v0.16.0-adiri"
# network-gated: two lines above

x="ADIRI upper"
# network-gated: adiri marker line that names adiri
# network-gated:
y="empty reason above"
z="adiri after empty marker"
w="Adiri Testnet"  # network-gated:
# network-gated: --
v="adiri after punct-only reason"
hub="198.51.100.20"
port_only="51820"
kuma="192.0.2.5"
logs="https://logs.hub.test/x"
metrics="METRICS.HUB.TEST"
#network-gated:nospace reason
s="adiri after no-space marker"
c="adiri" # network-gated: trailing covers own
d="adiri next line not covered by trailing"
EOF
printf 'crlf="adiri"\r\n# network-gated: crlf marker\r\ncrlf2="adiri"\r\n' > "$R/lib/crlf.sh"
printf '# network-gated: last line of file\n' > "$R/lib/b.sh"
printf 'first="adiri first line of next file"\n' > "$R/lib/c.sh"
printf 'root="adiri at root"\n' > "$R/rootscript.sh"
# ---- python / helper / html / alloy -----------------------------------------
cat > "$R/ui/server.py" <<'EOF'
A = "https://status.adiri.telcoin.network/"  # network-gated: py trailing
# network-gated: py marker above
B = "rpc.adiri.tel"
C = "adiri bare"
EOF
cat > "$R/ui/telcoin-ui-helper.sh" <<'EOF'
net="adiri"
EOF
cat > "$R/ui/static/index.html" <<'EOF'
<!-- network-gated: html marker above -->
<a href="https://status.adiri.telcoin.network/">s</a>
<a href="https://status.adiri.telcoin.network/">t</a>  <!-- network-gated: html trailing -->
<a href="adiri">bare</a>
<!-- network-gated: -->
<p>adiri after empty html marker</p>
<script>
// network-gated: js marker above
const u = "adiri";
const v = "adiri"; // network-gated: js trailing
const w = "adiri js bare";
</script>
<!-- network-gated: code after close --> <b>adiri on marker line</b>
<p>adiri below a marker line that also holds code</p>
EOF
cat > "$R/observability/config.alloy" <<'EOF'
// network-gated: alloy marker above
url = "https://logs.hub.test/loki"
url2 = "https://metrics.hub.test/api"
EOF
# ---- excluded paths ---------------------------------------------------------
for f in lib/wgvpn/x.sh lib/sub/x.sh common/x.sh tools/x.sh tools/tests/x.sh tests/x.sh \
         tasks/x.sh docs/x.sh CHANGELOG/x.sh followup.md README.md ui/other.py \
         a.sh.sha256 lib/a.sh.sha256 lib/x.txt; do
    printf 'excl="adiri 198.51.100.20 excluded"\n' > "$R/$f"
done
printf 'adiri\n' >> "$R/lib/testnet-addons.env"

run "$R"
eq "exit 1 with unannotated hits" 1 "$rc"
WANT='lib/a.sh:2: url="https://rpc.adiri.tel"
lib/a.sh:8: x="ADIRI upper"
lib/a.sh:12: z="adiri after empty marker"
lib/a.sh:13: w="Adiri Testnet"  # network-gated:
lib/a.sh:15: v="adiri after punct-only reason"
lib/a.sh:16: hub="198.51.100.20"
lib/a.sh:18: kuma="192.0.2.5"
lib/a.sh:19: logs="https://logs.hub.test/x"
lib/a.sh:20: metrics="METRICS.HUB.TEST"
lib/a.sh:24: d="adiri next line not covered by trailing"
lib/c.sh:1: first="adiri first line of next file"
lib/crlf.sh:1: crlf="adiri"
rootscript.sh:1: root="adiri at root"
ui/server.py:4: C = "adiri bare"
ui/telcoin-ui-helper.sh:1: net="adiri"
ui/static/index.html:4: <a href="adiri">bare</a>
ui/static/index.html:6: <p>adiri after empty html marker</p>
ui/static/index.html:11: const w = "adiri js bare";'
# index.html:14 (below a marker line that also holds code) is checked on its
# own below; the alloy lines too.
got_main="$(printf '%s\n' "$out" | grep -v '^ui/static/index.html:14:' | grep -v '^observability')"
eq "exact unannotated findings (scan order, trimmed text)" "$WANT" "$got_main"
has "alloy: url2 below a code line is reported" "observability/config.alloy:3: url2" "$out"
lacks "alloy: url below the marker passes" "observability/config.alloy:2:" "$out"
lacks "port alone (51820) is not a hit" "port_only" "$out"
lacks "a marker line naming adiri is not reported" "lib/a.sh:9:" "$out"
lacks "marker line itself not reported (b.sh)" "lib/b.sh" "$out"
lacks "CRLF marker line covers CRLF line below" "lib/crlf.sh:3:" "$out"
lacks "no-space #network-gated: marker accepted" "lib/a.sh:22:" "$out"
lacks "excluded paths not reported" "excluded" "$out"
lacks "testnet-addons.env not scanned" "testnet-addons.env" "$out"
if printf '%s\n' "$out" | grep -q '^ui/static/index.html:14:'; then
    ok "html: a marker line that also holds code does not cover the next line"
else
    bad "html: a marker line that also holds code does not cover the next line" \
        "contract: the line above must be nothing but the marker comment; index.html:14 passed"
fi
has "summary on stderr counts files" "in 9 file(s) scanned" "$err"

# ---- --list ---------------------------------------------------------------
run --list "$R"
eq "--list exit 1" 1 "$rc"
has "--list trailing reason" "lib/a.sh:3: trailing reason -- url2=" "$out"
has "--list above-line reason" "lib/a.sh:5: marker above -- tag=" "$out"
has "--list unannotated form" "lib/a.sh:2: unannotated -- url=" "$out"
has "--list marker line lists own reason" "lib/a.sh:9: adiri marker line that names adiri -- # network-gated: adiri marker line" "$out"
has "--list html closing --> stripped" "ui/static/index.html:3: html trailing -- <a" "$out"
has "--list js trailing" "ui/static/index.html:10: js trailing -- const v" "$out"
has "--list python above" "ui/server.py:3: py marker above -- B =" "$out"
has "--list patterns on stderr (port/prefix stripped, lower case)" \
    "patterns adiri, logs.hub.test, metrics.hub.test, 198.51.100.20, 192.0.2.5" "$err"
lacks "--list excluded never listed" "excluded" "$out"
nl_count="$(printf '%s\n' "$out" | grep -c .)"
hits_err="$(printf '%s\n' "$err" | sed -n 's/.* of \([0-9]*\) hit(s).*/\1/p')"
eq "--list prints one line per hit" "$hits_err" "$nl_count"

# ---- -- ROOT, argument order, --help ----------------------------------------
run --list -- "$R"
eq "-- ROOT form exit 1" 1 "$rc"
out1="$out"
run "$R" --list
eq "ROOT before --list same output" "$out1" "$out"
run --help
eq "--help exit 0" 0 "$rc"
has "--help usage line" "usage: tools/check-network-hits.sh [--list] [ROOT]" "$out"
run -h
eq "-h exit 0" 0 "$rc"

# ---- exit 0 when clean -----------------------------------------------------
mk_tree
printf 'a="adiri"  # network-gated: ok\n' > "$R/lib/a.sh"
run "$R"
eq "clean: exit 0" 0 "$rc"
eq "clean: stdout empty" "" "$out"
eq "clean: count on stderr" "check-network-hits: clean, 1 annotated hit(s) in 5 file(s) scanned" "$err"
mk_tree
printf 'a="nothing here"\n' > "$R/lib/a.sh"
run "$R"
eq "no hits: exit 0" 0 "$rc"
has "no hits: count 0" "clean, 0 annotated hit(s)" "$err"

# ---- exit 2 cases ---------------------------------------------------------
run --bogus "$R"
eq "unknown option: exit 2" 2 "$rc"
run "$R" "$R"
eq "two ROOTs: exit 2" 2 "$rc"
run "$T/nope"
eq "ROOT not a directory: exit 2" 2 "$rc"
for f in ui/server.py ui/telcoin-ui-helper.sh ui/static/index.html observability/config.alloy; do
    mk_tree
    rm -f "${R:?}/${f:?}"
    run "$R"
    eq "missing $f: exit 2" 2 "$rc"
    has "missing $f: named" "$f is missing" "$err"
done
mk_tree
rm -f "${R:?}/lib/testnet-addons.env"
run "$R"
eq "missing testnet-addons.env: exit 2" 2 "$rc"
for v in OBS_PUSH_URL_TESTNET OBS_METRICS_PUSH_URL_TESTNET TN_WG_HUB_ENDPOINT TN_KUMA_SRC; do
    mk_tree
    grep -v "$v=" "$R/lib/testnet-addons.env" > "$T/e"
    cat "$T/e" > "$R/lib/testnet-addons.env"
    run "$R"
    eq "env without $v: exit 2" 2 "$rc"
done
mk_tree
# shellcheck disable=SC2016 # literal $ written into the stub
printf 'export TN_KUMA_SRC="${KUMA:-1.2.3.4/32}"\n' >> "$R/lib/testnet-addons.env"
run "$R"
eq "non-literal env value: exit 2" 2 "$rc"
mk_tree
printf 'a="adiri"\n' > "$R/lib/a.sh"
if [ "$(id -u)" != 0 ]; then
    chmod 000 "$R/ui/server.py"
    run "$R"
    eq "unreadable scanned file: exit 2" 2 "$rc"
    chmod 644 "$R/ui/server.py"
else
    printf 'SKIP unreadable file (running as root)\n'
fi

# ---- informational: marker inside a string is accepted (blind spot) --------
mk_tree
printf 'echo "# network-gated: inside a string"; curl https://rpc.adiri.tel\n' > "$R/lib/a.sh"
run "$R"
printf 'INFO marker inside a string: rc=%s (0 = accepted)\n' "$rc"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
