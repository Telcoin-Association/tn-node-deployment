#!/usr/bin/env bash
# shellcheck shell=bash
# tasks/verify-fup/V4/v4lib.sh -- shared helpers of the V4 (REL) verifier harness.
# Sourced at the top level of every V4 test. V4_REPO names the tree whose
# scripts are under test (default: this worktree); the mutation driver points
# it at a mutated copy. bash 3.2 safe.

V4_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V4_WT="$(cd "$V4_DIR/../../.." && pwd)"
V4_REPO="${V4_REPO:-$V4_WT}"
V4_CACHE="$V4_DIR/cache"

# shellcheck source=/dev/null
. "$V4_WT/tools/tests/lib.sh"

T="$TN_TEST_TMP"
BIN="$T/bin"
RAW="$T/remote/raw"
mkdir -p "$BIN" "$RAW/main" "$T/archives"
unset TN_UPDATER_RELAUNCHED V4_TODAY V4_CURL_FAIL V4_CURL_FAIL_MATCH

ESC="$(printf '\033')"
plain() { printf '%s\n' "$1" | sed "s/${ESC}\[[0-9;]*m//g"; }

_h() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'
}

# has NAME PHRASE TEXT -- PHRASE (fixed string) appears in TEXT (colours stripped).
has() {
    check "$1" "yes" "$(plain "$3" | grep -qF -- "$2" && echo yes || echo "no; output was: $(plain "$3" | tail -n 12)")"
}
# hasnt NAME PHRASE TEXT
hasnt() {
    check "$1" "no" "$(plain "$3" | grep -qF -- "$2" && echo "yes: $(plain "$3" | grep -F -- "$2" | head -3)" || echo no)"
}
# count PHRASE TEXT -- number of lines holding PHRASE
count() { plain "$2" | grep -cF -- "$1" | tr -d ' '; }

# --- date shim: `date -u +%Y-%m-%d` answers V4_TODAY when it is set; a local
# `date +%Y-%m-%d` / `date +%F` is logged to $T/date-local.log. Other calls run
# the real date by absolute path (resolved before BIN goes on PATH).
REAL_DATE="$(type -P date)"
cat > "$BIN/date" <<STUB
#!/bin/sh
if [ "\$#" -eq 2 ] && [ "\$1" = "-u" ] && [ "\$2" = "+%Y-%m-%d" ] && [ -n "\${V4_TODAY:-}" ]; then
    echo "\$V4_TODAY"; exit 0
fi
if [ "\$#" -eq 1 ] && { [ "\$1" = "+%Y-%m-%d" ] || [ "\$1" = "+%F" ]; }; then
    echo "local-date \$*" >> "$T/date-local.log"
fi
exec "$REAL_DATE" "\$@"
STUB

# --- curl shim: raw.githubusercontent.com/<org>/<repo>/<path> -> $RAW/<path>,
# github archive tarballs -> $T/archives/<name>; rc 22 when absent; logs URLs.
# V4_CURL_FAIL=N: every call exits N. V4_CURL_FAIL_MATCH=S: calls whose URL
# contains S exit 7.
cat > "$BIN/curl" <<STUB
#!/bin/sh
out="" head=0 url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift ;;
        --proto|--max-time) shift ;;
        --*) ;;
        -*I*) head=1 ;;
        https://*) url="\$1" ;;
    esac
    shift
done
echo "\$url" >> "$T/curl.log"
[ -z "\${V4_CURL_FAIL:-}" ] || exit "\$V4_CURL_FAIL"
if [ -n "\${V4_CURL_FAIL_MATCH:-}" ]; then
    case "\$url" in *"\$V4_CURL_FAIL_MATCH"*) exit 7 ;; esac
fi
case "\$url" in
    https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/*)
        f="$RAW/\${url#https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/}" ;;
    https://github.com/Telcoin-Association/tn-node-deployment/archive/refs/tags/*.tar.gz)
        f="$T/archives/\${url##*/}" ;;
    *) exit 6 ;;
esac
[ -f "\$f" ] || exit 22
if [ "\$head" = 1 ]; then echo "HTTP/2 200"; exit 0; fi
if [ -n "\$out" ]; then cp "\$f" "\$out"; else cat "\$f"; fi
STUB
cat > "$BIN/sudo" <<STUB
#!/bin/sh
echo "sudo \$*" >> "$T/sudo.log"
exit 1
STUB
for tool in wget; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/curl.log"\nexit 1\n' "$tool" "$T" > "$BIN/$tool"
done
chmod +x "$BIN/date" "$BIN/curl" "$BIN/sudo" "$BIN/wget"

# shellcheck source=/dev/null
. "$V4_WT/tools/tests/signing.sh"
export PATH="$BIN:$PATH"
KEY1_LINE="$(newkey v4key1)"
KEY2_LINE="$(newkey v4key2)"
export KEY1_LINE KEY2_LINE

# dnum YYYY-MM-DD -- the day number from the python3 table (independent oracle).
dnum() { awk -v d="$1" '$1 == d {print $2; f = 1} END {if (!f) exit 1}' "$V4_DIR/dates_table.txt"; }
