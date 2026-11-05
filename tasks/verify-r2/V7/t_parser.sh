#!/usr/bin/env bash
# =============================================================================
# tasks/verify-r2/V7/t_parser.sh -- V7 SIG: the RELEASE SIGNATURES block, its
# three copies, and its status parser against _tn_gpg_status_verdict in
# lib/common.sh, with status lines in the shapes real gpgv 2.4 prints (taken
# from the t_policy.sh runs). Needs no gpg: runs under the host bash, bash:3.2
# and ubuntu:24.04.
#
#   bash tasks/verify-r2/V7/t_parser.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tasks/verify-r2/V7/t_parser.sh
# bash 3.2 safe.
# =============================================================================

set -u
# shellcheck source=tasks/verify-r2/V7/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd "$V7_WT" || exit 2

block_of() {
    awk '$0 == "# RELEASE SIGNATURES" { on = 1 } /^# --- end of RELEASE SIGNATURES/ { on = 0 } on' "$1"
}

echo "== the three copies (bash ${BASH_VERSION})"
block_of update-scripts.sh > "$V7_TMP/b.u"
block_of install.sh > "$V7_TMP/b.i"
block_of tools/release-scripts.sh > "$V7_TMP/b.r"
chk "block: update-scripts.sh has the block" yes "$([[ -s "$V7_TMP/b.u" ]] && echo yes || echo no)"
chk "block: install.sh copy is identical" "" "$(diff "$V7_TMP/b.u" "$V7_TMP/b.i")"
chk "block: release-scripts.sh copy is identical" "" "$(diff "$V7_TMP/b.u" "$V7_TMP/b.r")"
chk "block: one end marker per script" "1 1 1" "$(printf '%s %s %s' "$(grep -c '^# --- end of RELEASE SIGNATURES' update-scripts.sh)" \
    "$(grep -c '^# --- end of RELEASE SIGNATURES' install.sh)" "$(grep -c '^# --- end of RELEASE SIGNATURES' tools/release-scripts.sh)")"
chk "block: TN_SIG_FILE, TN_SIG_THRESHOLD, TN_KEYS_DIR" 'readonly TN_SIG_FILE="MANIFEST.asc"|readonly TN_SIG_THRESHOLD=1|readonly TN_KEYS_DIR="lib/release-keys"' \
    "$(grep -E '^readonly TN_(SIG_FILE|SIG_THRESHOLD|KEYS_DIR)=' "$V7_TMP/b.u" | tr '\n' '|' | sed 's/|$//')"
for fn in tn_dearmor_keys tn_sig_verdict tn_verify_manifest tn_sig_reason; do
    chk "block: defines ${fn}" 1 "$(grep -c "^${fn}() {" "$V7_TMP/b.u")"
done
chk "block: no copy sources lib/common.sh" "" "$(grep -nE '^[^#]*(source|\.) [^ ]*common\.sh' update-scripts.sh install.sh tools/release-scripts.sh)"
awk '/^_tn_gpg_status_verdict\(\) \{/ { on = 1 } on { print } on && /^\}/ { exit }' lib/common.sh > "$V7_TMP/lib.fn"
chk "library: _tn_gpg_status_verdict extracted" yes "$([[ -s "$V7_TMP/lib.fn" ]] && echo yes || echo no)"

# shellcheck disable=SC1090
source "$V7_TMP/b.u"
# shellcheck disable=SC1090
source "$V7_TMP/lib.fn"

K1=FAE3A316677A11D33C438DB5EEB4D334AC0A6E0F
K2=EEEA6B6AE9EBF737FCF7077933673B95F7F305DF
FX=81FEE7937DCE617633B90C61535D75B21E2FD8CD
printf '%s\n%s\n' "$K1" "$K2" > "$V7_TMP/allow"

# The status records of one signature, as gpgv 2.4.8 prints them.
rec() {
    local k="$1" id
    id="${k:24}"
    case "$2" in
        good) printf '[GNUPG:] NEWSIG\n[GNUPG:] KEY_CONSIDERED %s 0\n[GNUPG:] SIG_ID x 2026-11-04 1793834567\n[GNUPG:] GOODSIG %s Valid <v@example.invalid>\n[GNUPG:] VALIDSIG %s 2026-11-04 1793834567 0 4 0 22 10 00 %s\n' "$k" "$id" "$k" "$k" ;;
        expkey) printf '[GNUPG:] NEWSIG\n[GNUPG:] KEY_CONSIDERED %s 0\n[GNUPG:] KEYEXPIRED 1578009600\n[GNUPG:] SIG_ID x 2020-01-01 1577836860\n[GNUPG:] EXPKEYSIG %s Exp <e@example.invalid>\n[GNUPG:] VALIDSIG %s 2020-01-01 1577836860 0 4 0 22 10 00 %s\n' "$k" "$id" "$k" "$k" ;;
        revkey) printf '[GNUPG:] NEWSIG\n[GNUPG:] KEY_CONSIDERED %s 0\n[GNUPG:] SIG_ID x 2026-11-04 1793834567\n[GNUPG:] REVKEYSIG %s Rev <r@example.invalid>\n[GNUPG:] VALIDSIG %s 2026-11-04 1793834567 0 4 0 22 10 00 %s\n' "$k" "$id" "$k" "$k" ;;
        expsig) printf '[GNUPG:] NEWSIG\n[GNUPG:] KEY_CONSIDERED %s 0\n[GNUPG:] SIG_ID x 2021-01-01 1609459200\n[GNUPG:] EXPSIG %s Old <o@example.invalid>\n[GNUPG:] VALIDSIG %s 2021-01-01 1609459200 1609545600 4 0 22 10 00 %s\n' "$k" "$id" "$k" "$k" ;;
        bad) printf '[GNUPG:] NEWSIG\n[GNUPG:] KEY_CONSIDERED %s 0\n[GNUPG:] BADSIG %s Valid <v@example.invalid>\n' "$k" "$id" ;;
        foreign) printf '[GNUPG:] NEWSIG\n[GNUPG:] ERRSIG %s 22 10 00 1793834567 9 %s\n[GNUPG:] NO_PUBKEY %s\n' "$id" "$k" "$id" ;;
        errsig4) printf '[GNUPG:] NEWSIG\n[GNUPG:] ERRSIG %s 99 10 00 1793834579 4 %s\n' "$id" "$k" ;;
        nodata) printf '[GNUPG:] NODATA 2\n' ;;
    esac
}

# verdict_both THRESHOLD -- stdin through tn_sig_verdict (threshold 1 or a
# scratch copy with 2) and _tn_gpg_status_verdict: "<block> | <library>".
verdict_both() {
    local in b l
    in="$(cat)"
    if [[ "$1" == 1 ]]; then
        b="$(printf '%s\n' "$in" | tn_sig_verdict 2>/dev/null)"
    else
        sed 's/^readonly TN_SIG_THRESHOLD=1$/readonly TN_SIG_THRESHOLD=2/' "$V7_TMP/b.u" > "$V7_TMP/b.t2"
        # A fresh bash: this one holds the threshold-1 constants read-only.
        # shellcheck disable=SC2016
        b="$(printf '%s\n' "$in" | "$BASH" -c 'source "$1"; tn_sig_verdict' _ "$V7_TMP/b.t2" 2>/dev/null)"
    fi
    l="$(printf '%s\n' "$in" | _tn_gpg_status_verdict "$V7_TMP/allow")"
    printf '%s | %s\n' "$b" "$l"
}

case_() {
    local name="$1" t="$2" want="$3"
    shift 3
    chk "parser ${name} (threshold ${t})" "$want" "$("$@" | verdict_both "$t")"
}
one() { rec "$1" "$2"; }
two() { rec "$1" "$2"; rec "$3" "$4"; }

echo "== parser cases"
case_ good 1 "GOOD ${K1} | GOOD" one "$K1" good
case_ expkey 1 "EXPKEYSIG ${K1:24} | EXPKEYSIG" one "$K1" expkey
case_ revkey 1 "REVKEYSIG ${K1:24} | REVKEYSIG" one "$K1" revkey
case_ expsig 1 "EXPSIG ${K1:24} | EXPSIG" one "$K1" expsig
case_ badsig 1 "BADSIG ${K1:24} | BADSIG" one "$K1" bad
case_ foreign 1 "NOSIG | NOSIG ${FX:24}" one "$FX" foreign
case_ errsig4 1 "ERRSIG ${K1:24} 4 | ERRSIG" one "$K1" errsig4
case_ nodata 1 "NOSIG | NOSIG" one "$K1" nodata
case_ good+foreign 1 "GOOD ${K1} | GOOD ${FX:24}" two "$K1" good "$FX" foreign
case_ foreign+good 1 "GOOD ${K1} | GOOD ${FX:24}" two "$FX" foreign "$K1" good
case_ good+bad 1 "BADSIG ${K1:24} | BADSIG" two "$K1" good "$K1" bad
case_ bad+good 1 "BADSIG ${K1:24} | BADSIG" two "$K1" bad "$K1" good
case_ good+expkey 1 "EXPKEYSIG ${K2:24} | EXPKEYSIG" two "$K1" good "$K2" expkey
case_ good+revkey 1 "REVKEYSIG ${K2:24} | REVKEYSIG" two "$K1" good "$K2" revkey
case_ good+expsig 1 "EXPSIG ${K2:24} | EXPSIG" two "$K1" good "$K2" expsig
case_ good+errsig4 1 "ERRSIG ${K1:24} 4 | ERRSIG" two "$K1" good "$K1" errsig4
case_ good+good2 1 "GOOD ${K1} ${K2} | GOOD" two "$K1" good "$K2" good
case_ good+same 1 "GOOD ${K1} | GOOD" two "$K1" good "$K1" good
case_ t2-good 2 "THRESHOLD 1 ${K1} | GOOD" one "$K1" good
case_ t2-good+good2 2 "GOOD ${K1} ${K2} | GOOD" two "$K1" good "$K2" good
case_ t2-good+same 2 "THRESHOLD 1 ${K1} | GOOD" two "$K1" good "$K1" good
case_ t2-good+foreign 2 "THRESHOLD 1 ${K1} | GOOD ${FX:24}" two "$K1" good "$FX" foreign
case_ t2-good2+bad 2 "BADSIG ${K1:24} | BADSIG" eval 'rec "$K1" good; rec "$K2" good; rec "$K1" bad'
synth() { printf '%s\n' "$@"; }
case_ validsig-without-goodsig 1 "NOSIG | NOSIG" synth "[GNUPG:] VALIDSIG $K1 2026-11-04 1 0 4 0 22 10 00 $K1"
case_ v5-fingerprint 1 "NOSIG | NOSIG" synth "[GNUPG:] GOODSIG ${K1:24} x" "[GNUPG:] VALIDSIG ${K1}${K1:0:24} 2026-11-04 1 0 4 0 22 10 00 ${K1}${K1:0:24}"
case_ lowercase-fingerprint 1 "NOSIG | NOSIG" synth "[GNUPG:] GOODSIG ${K1:24} x" "[GNUPG:] VALIDSIG $K1 2026-11-04 1 0 4 0 22 10 00 $(printf '%s' "$K1" | tr 'A-F' 'a-f')"
case_ no-status-prefix 1 "NOSIG | NOSIG" synth "GOODSIG ${K1:24} x" "VALIDSIG $K1 2026-11-04 1 0 4 0 22 10 00 $K1"
case_ errsig9-nonhex-id 1 "ERRSIG ZZZZ 9 | ERRSIG" synth "[GNUPG:] ERRSIG ZZZZ 22 10 00 1 9"
case_ errsig-truncated 1 "ERRSIG ${K1:24}  | ERRSIG" synth "[GNUPG:] ERRSIG ${K1:24} 22 10"
case_ no_pubkey-alone 1 "NOSIG | NOSIG ${FX:24}" synth "[GNUPG:] NO_PUBKEY ${FX:24}"
case_ goodsig-uid-with-VALIDSIG-text 1 "NOSIG | NOSIG" synth "[GNUPG:] GOODSIG ${K1:24} [GNUPG:] VALIDSIG x $K1"
case_ empty-input 1 "NOSIG | NOSIG" synth ""

echo "== random differential: accept/refuse agree with _tn_gpg_status_verdict (threshold 1)"
kinds="good good good expkey revkey expsig bad foreign errsig4 nodata"
set -f
# shellcheck disable=SC2206
KA=($kinds)
set +f
agree=0
disagree=0
first=""
i=0
while [[ $i -lt 400 ]]; do
    n=$((RANDOM % 4 + 1))
    j=0
    : > "$V7_TMP/seq"
    desc=""
    while [[ $j -lt $n ]]; do
        k="${KA[$((RANDOM % ${#KA[@]}))]}"
        case $((RANDOM % 2)) in
            0) key="$K1" ;;
            *) key="$K2" ;;
        esac
        [[ "$k" != foreign ]] || key="$FX"
        rec "$key" "$k" >> "$V7_TMP/seq"
        desc="${desc}${k} "
        j=$((j + 1))
    done
    r="$(verdict_both 1 < "$V7_TMP/seq")"
    b="${r%% | *}"
    l="${r#* | }"
    ba=refuse
    la=refuse
    [[ "$b" != GOOD* ]] || ba=accept
    [[ "$l" != GOOD* ]] || la=accept
    if [[ "$ba" == "$la" && "${b%% *}" == "${l%% *}" ]]; then
        agree=$((agree + 1))
    else
        disagree=$((disagree + 1))
        [[ -n "$first" ]] || first="${desc}=> ${r}"
    fi
    i=$((i + 1))
done
chk "differential: 400 random sequences agree (verdict keyword and accept/refuse)" "400 0" "${agree} ${disagree}"
[[ -z "$first" ]] || echo "   first disagreement: $first"

echo "== dearmor portability (bash ${BASH_VERSION})"
tn_dearmor_keys lib/release-keys > "$V7_TMP/kr.bin" 2> "$V7_TMP/kr.err"
chk "dearmor of lib/release-keys: rc 0" 0 "$?"
# gpg --dearmor of grantkee.asc on the host (bash 5.3, gpg 2.4.8), recorded:
chk "dearmor of lib/release-keys: the bytes gpg --dearmor makes" "${V7_GRANTKEE_DEARMOR_SHA:-$(v7_sha "$V7_TMP/kr.bin")}" "$(v7_sha "$V7_TMP/kr.bin")"
mkdir -p "$V7_TMP/fakeb64"
cat > "$V7_TMP/fakeb64/base64" <<EOF
#!/bin/sh
# An older macOS base64: decodes only with -D.
case "\$1" in
    -d) echo "base64: invalid option -- d" >&2; exit 64 ;;
    -D) shift; exec $(command -v base64) -d "\$@" ;;
esac
exec $(command -v base64) "\$@"
EOF
chmod +x "$V7_TMP/fakeb64/base64"
PATH="$V7_TMP/fakeb64:$PATH" tn_dearmor_keys lib/release-keys > "$V7_TMP/kr-D.bin" 2>/dev/null
chk "dearmor with a base64 that only takes -D: rc 0" 0 "$?"
chk "dearmor with a base64 that only takes -D: same bytes" "$(v7_sha "$V7_TMP/kr.bin")" "$(v7_sha "$V7_TMP/kr-D.bin")"

v7_finish
