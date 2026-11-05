#!/usr/bin/env bash
# =============================================================================
# tasks/verify-r2/V7/t_policy.sh -- V7 SIG items 1 and 2: the signature policy
# as the three verifiers apply it, with real gpg and gpgv.
#
# Builds a release from the worktree's tree with throwaway keys (valid,
# second, expired, revoked, old in lib/release-keys; foreign not shipped),
# prepares it with tools/release-scripts.sh, serves it over file:// and runs
# every MANIFEST.asc variant through:
#   R  bash tools/release-scripts.sh --check --require-sig --tag TAG
#   U  update-scripts.sh on a host with the release keys and no MANIFEST
#   I  the prepared install.sh (embedded keys) with --yes
# then the threshold-2 variants with TN_SIG_THRESHOLD=2 in scratch copies, and
# a host without gpgv.
#
#   bash tasks/verify-r2/V7/t_policy.sh            (host bash 5.3, gpg, gpgv)
# bash 3.2 safe.
# =============================================================================

set -u
# shellcheck source=tasks/verify-r2/V7/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v gpg >/dev/null 2>&1 && command -v gpgv >/dev/null 2>&1 || { echo "t_policy.sh needs gpg and gpgv"; exit 2; }

R="${V7_TMP}/repo"
SERVE="${V7_TMP}/serve"
BIN="${V7_TMP}/bin"
VAR="${V7_TMP}/var"
mkdir -p "$VAR"
TODAY="$(date -u +%Y-%m-%d)"

echo "== setup: keys, release repo, prepare, sign, serve"
v7_keys
v7_build_release "$R"
out="$(cd "$R" && HOME="${V7_TMP}/home" bash tools/release-scripts.sh --serial 1 --date "$TODAY" "$V7_TAG" 2>&1)"
chk "prepare: rc 0" 0 "$?"
chk_has "prepare: prints the signing command with the valid key's fingerprint" \
    "gpg --armor --detach-sign --local-user $(v7_fpr valid)! --output MANIFEST.asc MANIFEST" "$out"
chk "prepare: MANIFEST.asc absent after prepare" no "$([[ -e "$R/MANIFEST.asc" ]] && echo yes || echo no)"
chk "prepare: MANIFEST lists every key file" 5 "$(grep -c '^sha256  [0-9a-f]\{64\}  lib/release-keys/[a-z]*\.asc$' "$R/MANIFEST")"
chk "prepare: install.sh embeds the five keys" 5 "$(awk '/<<.TN_RELEASE_KEYS./{b=1;next} /^TN_RELEASE_KEYS$/{b=0} b' "$R/install.sh" | grep -c '^-----BEGIN PGP PUBLIC KEY BLOCK-----$')"
chk "prepare: install.sh names the tag" "readonly TN_SCRIPTS_TAG=\"${V7_TAG}\"   # written by tools/release-scripts.sh" "$(grep '^readonly TN_SCRIPTS_TAG=' "$R/install.sh")"
cp "$R/MANIFEST" "$VAR/MANIFEST.orig"
v7_sign "$R/MANIFEST.asc" valid "$R/MANIFEST"
out="$(cd "$R" && bash tools/release-scripts.sh --check --require-sig --tag "$V7_TAG" 2>&1)"
chk "control: release-scripts --check --require-sig passes" 0 "$?"
v7_git -C "$R" add MANIFEST MANIFEST.asc RELEASE install.sh
v7_git -C "$R" commit -q -m "release: ${V7_TAG}"
v7_serve_init "$SERVE" "$R"
v7_shim "$BIN" "$SERVE"
PACK="$SERVE/pack/tn-node-deployment-${V7_TAG}"

# ---------------------------------------------------------------------------
# The MANIFEST.asc variants. Each is VAR/NAME.asc; tamper also VAR/tamper.manifest.
M="$VAR/MANIFEST.orig"
v() { : > "$VAR/$1.asc"; }
v good;        v7_sign "$VAR/good.asc" valid "$M"
v good2;       v7_sign "$VAR/good2.asc" valid "$M"; v7_sign "$VAR/good2.asc" second "$M"
v goodtwice;   v7_sign "$VAR/goodtwice.asc" valid "$M"; v7_sign "$VAR/goodtwice.asc" valid "$M"
v tamper;      v7_sign "$VAR/tamper.asc" valid "$M"
awk 'NR == 1 { print; print "note=tampered"; next } { print }' "$M" > "$VAR/tamper.manifest"
v expkey;      v7_sign "$VAR/expkey.asc" expired "$M"
v revkey;      v7_sign "$VAR/revkey.asc" revoked "$M"
v expsig;      v7_sign "$VAR/expsig.asc" old "$M" expsig
v foreign;     v7_sign "$VAR/foreign.asc" foreign "$M"
v errsig4;     v7_sign_errsig "$VAR/errsig4.asc" valid "$M"
v empty
printf 'this is not a signature\n' > "$VAR/garbage.asc"
printf 'other content\n' > "$VAR/other"
v goodbad;     v7_sign "$VAR/goodbad.asc" valid "$M"; v7_sign "$VAR/goodbad.asc" valid "$VAR/other"
v goodforeign; v7_sign "$VAR/goodforeign.asc" valid "$M"; v7_sign "$VAR/goodforeign.asc" foreign "$M"
v goodexp;     v7_sign "$VAR/goodexp.asc" valid "$M"; v7_sign "$VAR/goodexp.asc" expired "$M"
v goodrev;     v7_sign "$VAR/goodrev.asc" valid "$M"; v7_sign "$VAR/goodrev.asc" revoked "$M"
v goodexpsig;  v7_sign "$VAR/goodexpsig.asc" valid "$M"; v7_sign "$VAR/goodexpsig.asc" old "$M" expsig
v gooderr;     v7_sign "$VAR/gooderr.asc" valid "$M"; v7_sign_errsig "$VAR/gooderr.asc" valid "$M"

# The real status lines of the crafted variants, so the record shows them.
for n in expkey revkey expsig foreign errsig4 empty goodbad; do
    h="${V7_TMP}/gpgv-home-$n"
    mkdir -p "$h"
    chmod 700 "$h"
    cat "$R"/lib/release-keys/*.asc | g --dearmor > "${V7_TMP}/kr-all.gpg"
    printf '   gpgv %-8s: %s\n' "$n" "$(GNUPGHOME="$h" gpgv --status-fd 1 --keyring "${V7_TMP}/kr-all.gpg" "$VAR/$n.asc" "$M" 2>/dev/null \
        | grep -E 'GOODSIG|BADSIG|EXPKEYSIG|REVKEYSIG|EXPSIG|ERRSIG|NO_PUBKEY|NODATA' | awk '{print $2, ($2 == "ERRSIG" ? $8 : "")}' | tr '\n' ';')"
done

# reason_kw TEXT -- the verdict keyword a refusal message names.
reason_kw() {
    case "$1" in
        *"does not match MANIFEST"*) echo BADSIG ;;
        *"which has expired"*) echo EXPKEYSIG ;;
        *"which has been revoked"*) echo REVKEYSIG ;;
        *"the signature by key "*" has expired"*) echo EXPSIG ;;
        *"could not check the signature by key"*) echo ERRSIG ;;
        *"made a good signature"*) echo NOSIG ;;
        *"release key(s), 2 needed"*) echo THRESHOLD ;;
        *"gpgv is not installed"*|*"gpgv (GnuPG) is needed"*|*"Need gpgv"*) echo NOGPGV ;;
        *"has no MANIFEST.asc"*|*"FAIL no MANIFEST.asc"*) echo MISSING ;;
        *) echo UNKNOWN ;;
    esac
}

# put_variant NAME -- serve and place variant NAME (missing: no MANIFEST.asc).
put_variant() {
    cp "$M" "$PACK/MANIFEST"
    cp "$M" "$R/MANIFEST"
    rm -f "$PACK/MANIFEST.asc" "$R/MANIFEST.asc"
    if [[ "$1" != missing ]]; then
        cp "$VAR/$1.asc" "$PACK/MANIFEST.asc"
        cp "$VAR/$1.asc" "$R/MANIFEST.asc"
    fi
    if [[ -f "$VAR/$1.manifest" ]]; then
        cp "$VAR/$1.manifest" "$PACK/MANIFEST"
        cp "$VAR/$1.manifest" "$R/MANIFEST"
    fi
    v7_serve_pack "$SERVE"
}

# run_R / run_U / run_I [PATHVAR] -- one verifier on the served variant; print
# "accept", "refuse:<KW>" or "other:rc=<rc>". Side effects are checked inside.
LAST_OUT=""
RES=""
LEFT=""
run_R() {
    local rc=0
    LAST_OUT="$(cd "$R" && PATH="${1:-$PATH}" bash tools/release-scripts.sh --check --require-sig --tag "$V7_TAG" 2>&1)" || rc=$?
    if [[ $rc -eq 0 && "$LAST_OUT" == *"MANIFEST.asc verifies: signed by"* ]]; then RES=accept
    elif [[ $rc -eq 1 ]]; then RES="refuse:$(reason_kw "$LAST_OUT")"
    else RES="other:rc=$rc"; fi
}
HOSTN=0
run_U() {
    local rc=0 h before after updater="${2:-$R/update-scripts.sh}"
    HOSTN=$((HOSTN + 1))
    h="${V7_TMP}/host$HOSTN"
    mkdir -p "$h/lib/release-keys"
    cp "$updater" "$h/update-scripts.sh"
    cp "$R"/lib/release-keys/*.asc "$h/lib/release-keys/"
    before="$(cd "$h" && find . | LC_ALL=C sort)"
    LAST_OUT="$(printf 'n\n' | PATH="$BIN:${1:-$PATH}" TERM=dumb bash "$h/update-scripts.sh" 2>&1)" || rc=$?
    after="$(cd "$h" && find . | LC_ALL=C sort)"
    if [[ $rc -eq 0 && "$LAST_OUT" == *"Release manifest signed by release key"* && "$LAST_OUT" == *"Update cancelled"* ]]; then
        RES=accept
    elif [[ $rc -eq 1 ]]; then
        if [[ "$before" != "$after" ]]; then RES="refuse-but-tree-changed"; return; fi
        RES="refuse:$(reason_kw "$LAST_OUT")"
    else RES="other:rc=$rc"; fi
}
run_I() {
    local rc=0 home installer="${2:-$R/install.sh}"
    HOSTN=$((HOSTN + 1))
    home="${V7_TMP}/ihome$HOSTN"
    mkdir -p "$home"
    LAST_OUT="$(PATH="$BIN:${1:-$PATH}" HOME="$home" bash "$installer" --yes 2>&1)" || rc=$?
    if [[ $rc -eq 0 && "$LAST_OUT" == *"Release signature verified"* && -f "$home/telcoin-node-scripts/MANIFEST.asc" ]]; then
        RES=accept
    elif [[ $rc -eq 1 ]]; then
        LEFT="$(cd "$home" && find . -mindepth 1 -maxdepth 2 | LC_ALL=C sort | tr '\n' ' ')"
        if [[ -n "$LEFT" ]]; then RES="refuse-but-left-files"; return; fi
        RES="refuse:$(reason_kw "$LAST_OUT")"
    else RES="other:rc=$rc"; fi
}

matrix() {
    local name="$1" want="$2" pv="${3:-}" a
    put_variant "$name"
    run_R "$pv"; a="$RES"; chk "policy ${name} (threshold 1) release-scripts" "$want" "$a"
    [[ "$a" != accept || "$name" != goodforeign ]] || chk_has "policy goodforeign release-scripts warns about the foreign key" "which is not a release key, was not checked" "$LAST_OUT"
    run_U "$pv"; a="$RES"; chk "policy ${name} (threshold 1) update-scripts" "$want" "$a"
    if [[ "$name" == errsig4 ]]; then chk_has "policy errsig4 update-scripts names error 4" "(error 4)" "$LAST_OUT"; fi
    if [[ "$name" == good2 ]]; then chk_has "policy good2 update-scripts names both keys" "$(v7_fpr valid) $(v7_fpr second)" "$LAST_OUT"; fi
    run_I "$pv"; a="$RES"; chk "policy ${name} (threshold 1) install.sh" "$want" "$a"
}

echo "== policy matrix, threshold 1"
matrix good accept
matrix good2 accept
matrix goodtwice accept
matrix goodforeign accept
matrix tamper refuse:BADSIG
matrix expkey refuse:EXPKEYSIG
matrix revkey refuse:REVKEYSIG
matrix expsig refuse:EXPSIG
matrix foreign refuse:NOSIG
matrix errsig4 refuse:ERRSIG
matrix empty refuse:NOSIG
matrix garbage refuse:NOSIG
matrix goodbad refuse:BADSIG
matrix goodexp refuse:EXPKEYSIG
matrix goodrev refuse:REVKEYSIG
matrix goodexpsig refuse:EXPSIG
matrix gooderr refuse:ERRSIG
matrix missing refuse:MISSING

echo "== policy matrix, threshold 2 (scratch copies)"
cp "$R/tools/release-scripts.sh" "$VAR/release-scripts.sh.orig"
sed 's/^readonly TN_SIG_THRESHOLD=1$/readonly TN_SIG_THRESHOLD=2/' "$VAR/release-scripts.sh.orig" > "$R/tools/release-scripts.sh"
sed 's/^readonly TN_SIG_THRESHOLD=1$/readonly TN_SIG_THRESHOLD=2/' "$R/update-scripts.sh" > "$VAR/update-t2.sh"
sed 's/^readonly TN_SIG_THRESHOLD=1$/readonly TN_SIG_THRESHOLD=2/' "$R/install.sh" > "$VAR/install-t2.sh"
chk "threshold-2 copies differ in one line each" "1 1 1" "$(printf '%s %s %s' "$(diff "$VAR/release-scripts.sh.orig" "$R/tools/release-scripts.sh" | grep -c '^>')" \
        "$(diff "$R/update-scripts.sh" "$VAR/update-t2.sh" | grep -c '^>')" "$(diff "$R/install.sh" "$VAR/install-t2.sh" | grep -c '^>')")"
t2() {
    local name="$1" want="$2" a
    put_variant "$name"
    run_R; a="$RES"; chk "policy ${name} (threshold 2) release-scripts" "$want" "$a"
    run_U "" "$VAR/update-t2.sh"; a="$RES"; chk "policy ${name} (threshold 2) update-scripts" "$want" "$a"
    run_I "" "$VAR/install-t2.sh"; a="$RES"; chk "policy ${name} (threshold 2) install.sh" "$want" "$a"
}
t2 good refuse:THRESHOLD
t2 good2 accept
t2 goodtwice refuse:THRESHOLD
t2 goodforeign refuse:THRESHOLD
cp "$VAR/release-scripts.sh.orig" "$R/tools/release-scripts.sh"

echo "== no gpgv on PATH"
NOG="${V7_TMP}/nogpgv"
mkdir -p "$NOG"
for d in /usr/local/bin /usr/bin /bin; do
    for f in "$d"/*; do
        n="${f##*/}"
        [[ "$n" != gpgv && ! -e "$NOG/$n" ]] || continue
        ln -s "$f" "$NOG/$n" 2>/dev/null || true
    done
done
chk "the no-gpgv PATH has no gpgv" "" "$(PATH="$NOG" command -v gpgv || true)"
put_variant good
run_R "$NOG"; a="$RES"; chk "no gpgv: release-scripts refuses" refuse:NOGPGV "$a"
run_U "$NOG"; a="$RES"; chk "no gpgv: update-scripts refuses" refuse:NOGPGV "$a"
chk_has "no gpgv: update-scripts names the packages" "apt-get install -y gpgv     macOS: brew install gnupg" "$LAST_OUT"
run_I "$NOG"; a="$RES"; chk "no gpgv: install.sh refuses" refuse:NOGPGV "$a"
chk_has "no gpgv: install.sh names the packages" "sudo apt-get install -y gpgv. macOS: brew install gnupg" "$LAST_OUT"

echo "== an installed host checks the installed record (--check)"
put_variant good
run_I; a="$RES"
chk "install for --check: accepted" accept "$a"
IH="${V7_TMP}/ihome${HOSTN}/telcoin-node-scripts"
rc=0; out="$(PATH="$BIN:$PATH" bash "$IH/update-scripts.sh" --check 2>&1)" || rc=$?
chk "--check on the fresh install: rc 0" 0 "$rc"
chk_has "--check: installed record verified" "(signature verified)" "$out"
v7_sign "$VAR/inst-bad.asc" valid "$VAR/other"
cp "$VAR/inst-bad.asc" "$IH/MANIFEST.asc"
rc=0; out="$(PATH="$BIN:$PATH" bash "$IH/update-scripts.sh" --check 2>&1)" || rc=$?
chk "--check with a bad installed MANIFEST.asc: rc 2" 2 "$rc"
chk_has "--check with a bad installed MANIFEST.asc: says why" "does not match MANIFEST" "$out"
chk "the installed tree has no lib/allowed_signers" no "$([[ -e "$IH/lib/allowed_signers" ]] && echo yes || echo no)"

v7_finish
