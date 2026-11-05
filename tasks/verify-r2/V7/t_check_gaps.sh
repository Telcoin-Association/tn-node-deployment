#!/usr/bin/env bash
# =============================================================================
# tasks/verify-r2/V7/t_check_gaps.sh -- V7 SIG: the two mutants no check
# caught (t_mutants.sh U04, U06), pinned against the tree's update-scripts.sh
# and run again on the two mutated copies.
#   U04  --check on an installed host when the newest release's MANIFEST.asc
#        does not verify: rc 2 and the reason, not "Update pending".
#   U06  a signed MANIFEST that lists MANIFEST.asc as a file: refused as a
#        bad path.
#
#   bash tasks/verify-r2/V7/t_check_gaps.sh     (host: gpg and gpgv)
# bash 3.2 safe.
# =============================================================================

set -u
# shellcheck source=tasks/verify-r2/V7/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
R="${V7_TMP}/repo"
S="${V7_TMP}/serve"
BIN="${V7_TMP}/bin"
v7_keys
v7_build_release "$R"
(cd "$R" && HOME="${V7_TMP}/home" bash tools/release-scripts.sh --serial 1 "$V7_TAG" >/dev/null 2>&1)
v7_sign "$R/MANIFEST.asc" valid "$R/MANIFEST"
v7_git -C "$R" add MANIFEST MANIFEST.asc RELEASE install.sh
v7_git -C "$R" commit -q -m release
v7_serve_init "$S" "$R"
v7_serve_pack "$S"
v7_shim "$BIN" "$S"
mkdir -p "${V7_TMP}/ih"
PATH="$BIN:$PATH" HOME="${V7_TMP}/ih" bash "$R/install.sh" --yes >/dev/null 2>&1
H="${V7_TMP}/ih/telcoin-node-scripts"
chk "setup: installed release 1" yes "$([[ -f "$H/MANIFEST.asc" ]] && echo yes || echo no)"

# The two mutated copies of the installed updater.
sed 's/^    verify_manifest "${STAGE}\/MANIFEST" "${STAGE}\/${TN_SIG_FILE}" "$KEYS_DIR" quiet || return 2$/    : verify_manifest/' "$H/update-scripts.sh" > "${V7_TMP}/u04.sh"
sed 's/^        MANIFEST|MANIFEST.asc) return 1 ;;$/        MANIFEST) return 1 ;;/' "$H/update-scripts.sh" > "${V7_TMP}/u06.sh"
chk "mutant copies differ in one line each" "1 1" "$(diff "$H/update-scripts.sh" "${V7_TMP}/u04.sh" | grep -c '^>') $(diff "$H/update-scripts.sh" "${V7_TMP}/u06.sh" | grep -c '^>')"

# U04: RELEASE names scripts-v2.1.1 (serial 2) whose MANIFEST.asc is by a foreign key.
T2="scripts-v2.1.1"
mkdir -p "$S/pack2"
cp -R "$S/pack/tn-node-deployment-${V7_TAG}/." "$S/pack2/"
sed -e "s/^release=.*/release=${T2}/" -e 's/^serial=.*/serial=2/' "$R/MANIFEST" > "$S/pack2/MANIFEST"
: > "$S/pack2/MANIFEST.asc"; v7_sign "$S/pack2/MANIFEST.asc" foreign "$S/pack2/MANIFEST"
ln -s "$S/pack2" "$S/tags/$T2"
printf '%s %s\n' "$T2" "$(date -u +%Y-%m-%d)" > "$S/main/RELEASE"
for u in tree u04; do
    f="$H/update-scripts.sh"; [[ "$u" == tree ]] || f="${V7_TMP}/$u.sh"
    cp "$f" "$H/update-scripts.check.sh"
    RC=0; OUT="$(PATH="$BIN:$PATH" bash "$H/update-scripts.check.sh" --check 2>&1)" || RC=$?
    printf '   U04 %s: rc %s, %s\n' "$u" "$RC" "$(printf '%s\n' "$OUT" | grep -E 'ERROR|WARN|Update pending|No update' | head -1 | sed 's/\x1b\[[0-9;]*m//g')"
    if [[ "$u" == tree ]]; then
        chk "U04 tree: --check with a forged newest release: rc 2" 2 "$RC"
        chk_has "U04 tree: names the reason" "is not signed by a Telcoin release key (no release key in lib/release-keys made a good signature)" "$OUT"
    else
        chk "U04 mutant: this check catches it (rc is not 2)" yes "$([[ $RC -ne 2 ]] && echo yes || echo no)"
    fi
done
rm -f "$H/update-scripts.check.sh"

# U06: a signed MANIFEST listing MANIFEST.asc, on a host with the keys and no record.
cp "$R/RELEASE" "$S/main/RELEASE"
P="$S/pack/tn-node-deployment-${V7_TAG}"
cp "$R/MANIFEST" "${V7_TMP}/M.orig"
{ cat "${V7_TMP}/M.orig"; printf 'sha256  %064d  MANIFEST.asc\n' 0; } > "$P/MANIFEST"
: > "$P/MANIFEST.asc"; v7_sign "$P/MANIFEST.asc" valid "$P/MANIFEST"
for u in tree u06; do
    h="${V7_TMP}/u06host-$u"
    mkdir -p "$h/lib/release-keys"
    cp "$R"/lib/release-keys/*.asc "$h/lib/release-keys/"
    if [[ "$u" == tree ]]; then cp "$R/update-scripts.sh" "$h/"; else
        sed 's/^        MANIFEST|MANIFEST.asc) return 1 ;;$/        MANIFEST) return 1 ;;/' "$R/update-scripts.sh" > "$h/update-scripts.sh"; fi
    RC=0; OUT="$(printf 'y\n' | PATH="$BIN:$PATH" TERM=dumb bash "$h/update-scripts.sh" 2>&1)" || RC=$?
    printf '   U06 %s: rc %s, %s\n' "$u" "$RC" "$(printf '%s\n' "$OUT" | grep -E 'ERROR|FAILED' | head -1 | sed 's/\x1b\[[0-9;]*m//g')"
    if [[ "$u" == tree ]]; then
        chk "U06 tree: a MANIFEST listing MANIFEST.asc is refused as a bad path" "1 yes" "$RC $([[ "$OUT" == *"bad path: MANIFEST.asc"* ]] && echo yes || echo no)"
    else
        chk "U06 mutant: still refused (the listed hash cannot be the signature's own)" 1 "$RC"
        chk "U06 mutant: this check catches it (the bad-path message is gone)" yes "$([[ "$OUT" != *"bad path: MANIFEST.asc"* ]] && echo yes || echo no)"
    fi
done
v7_finish
