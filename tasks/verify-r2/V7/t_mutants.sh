#!/usr/bin/env bash
# =============================================================================
# tasks/verify-r2/V7/t_mutants.sh -- V7 SIG item 8: break each policy branch,
# threshold and call site in a scratch clone of the worktree (never the tree),
# then record which checks catch it:
#   fixtures (real gpg)   tools/tests/run.sh on the four SIG fixtures
#   fixtures (fakes)      the same with TN_TEST_FAKE_GPG=1
#   V7 harness            t_parser, t_dearmor, t_policy, t_bootstrap_install
#
#   bash tasks/verify-r2/V7/t_mutants.sh            every mutant, 6 at a time
#   bash tasks/verify-r2/V7/t_mutants.sh --one ID   one mutant (M00: none)
#   bash tasks/verify-r2/V7/t_mutants.sh --list     the table
# Results: one line per mutant in $V7_SCRATCH_ROOT/mut/results.tsv.
# bash 3.2 safe.
# =============================================================================

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT="$(cd "${HERE}/../../.." && pwd)"
ROOT="${V7_SCRATCH_ROOT:-/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/a63179cc-f715-4653-8076-ca7024820f15/scratchpad/V7}/mut"
mkdir -p "$ROOT"
PY="${ROOT}/mutate.py"
FIX="tools/tests/release_scripts_test.sh tools/tests/updater_manifest_test.sh tools/tests/install_test.sh tools/tests/cut_release_test.sh"
HARNESS="t_parser.sh t_dearmor.sh t_policy.sh t_bootstrap_install.sh"
REF_SHA="${V7_GRANTKEE_DEARMOR_SHA:-9ff0b95ddaa06d41501ae0d13c8a3c55996e7a6510846462e2e076d3334dcfd5}"

cat > "$PY" <<'PYEOF'
import sys
B3 = ["update-scripts.sh", "install.sh", "tools/release-scripts.sh"]
U, I, R = ["update-scripts.sh"], ["install.sh"], ["tools/release-scripts.sh"]
M = [
 ("M01", "block: BADSIG does not refuse", B3, "            BADSIG|EXPKEYSIG|REVKEYSIG|EXPSIG)", "            EXPKEYSIG|REVKEYSIG|EXPSIG)"),
 ("M02", "block: EXPKEYSIG does not refuse", B3, "            BADSIG|EXPKEYSIG|REVKEYSIG|EXPSIG)", "            BADSIG|REVKEYSIG|EXPSIG)"),
 ("M03", "block: REVKEYSIG does not refuse", B3, "            BADSIG|EXPKEYSIG|REVKEYSIG|EXPSIG)", "            BADSIG|EXPKEYSIG|EXPSIG)"),
 ("M04", "block: EXPSIG does not refuse", B3, "            BADSIG|EXPKEYSIG|REVKEYSIG|EXPSIG)", "            BADSIG|EXPKEYSIG|REVKEYSIG)"),
 ("M05", "block: ERRSIG with another code counts as an unknown key", B3, 'if [[ "$code" != 9 || ! "$id" =~ ^[0-9A-F]{16,40}$ ]]; then', 'if [[ ! "$id" =~ ^[0-9A-F]{16,40}$ ]]; then'),
 ("M06", "block: ERRSIG 9 / NO_PUBKEY refuses (over-strict)", B3, 'if [[ "$code" != 9 || ! "$id" =~ ^[0-9A-F]{16,40}$ ]]; then', 'if true; then'),
 ("M07", "block: VALIDSIG counts without GOODSIG", B3, 'if [[ "$good" -eq 1 && "$fpr" =~ ^[0-9A-F]{40}$ ]]; then', 'if [[ "$fpr" =~ ^[0-9A-F]{40}$ ]]; then'),
 ("M08", "block: VALIDSIG fingerprint shape not checked", B3, 'if [[ "$good" -eq 1 && "$fpr" =~ ^[0-9A-F]{40}$ ]]; then', 'if [[ "$good" -eq 1 ]]; then'),
 ("M09", "block: a repeated key counts again (not distinct)", B3, '*" ${fpr} "*) ;;', '*" ${fpr} "*) n=$((n + 1)) ;;'),
 ("M10", "block: threshold not enforced", B3, 'if [[ $n -lt $TN_SIG_THRESHOLD ]]; then', 'if false; then'),
 ("M11", "block: threshold off by one (-le)", B3, 'if [[ $n -lt $TN_SIG_THRESHOLD ]]; then', 'if [[ $n -le $TN_SIG_THRESHOLD ]]; then'),
 ("M12", "block: NOSIG branch removed (falls to THRESHOLD)", B3, "    if [[ $n -eq 0 ]]; then\n        printf 'NOSIG\\n'", "    if false; then\n        printf 'NOSIG\\n'"),
 ("M13", "block: a refusing keyword returns 0", B3, "        printf '%s\\n' \"$bad\"\n        return 1", "        printf '%s\\n' \"$bad\"\n        return 0"),
 ("M14", "block: tn_verify_manifest ignores the verdict rc", B3, "printf '%s\\n' \"$out\" | tn_sig_verdict || rc=$?", "printf '%s\\n' \"$out\" | tn_sig_verdict || true"),
 ("M15", "block: dearmor skips a file that is not a key", B3, "                printf '%s is not an ASCII-armored OpenPGP public key\\n' \"$f\" >&2\n                return 1", "                printf '%s is not an ASCII-armored OpenPGP public key\\n' \"$f\" >&2\n                continue"),
 ("M16", "block: dearmor does not strip CR", B3, '        { sub(/\\r$/, "") }', '        { }'),
 ("M17", "block: dearmor reads armor headers as body", B3, "        st == 1 { next }", "        st == 1 { print; body++; next }"),
 ("M18", "block: dearmor keeps the CRC line", B3, "        /^=/ && length($0) == 5 { next }\n", ""),
 ("M19", "block: dearmor does not check the decode", B3, '                if ! _tn_armor_body "$i" < "$f" | _tn_b64d; then', '                _tn_armor_body "$i" < "$f" | _tn_b64d || true\n                if false; then'),
 ("M20", "block: dearmor accepts no key file at all", B3, "    if [[ $n -eq 0 ]]; then\n        printf 'no release key file", "    if false; then\n        printf 'no release key file"),
 ("M21", "one copy only: BADSIG does not refuse in install.sh", I, "            BADSIG|EXPKEYSIG|REVKEYSIG|EXPSIG)", "            EXPKEYSIG|REVKEYSIG|EXPSIG)"),
 ("U01", "update-scripts: verify_manifest ignores the verdict", U, 'verdict="$(tn_verify_manifest "$kr" "$2" "$1")" || rc=$?', 'verdict="$(tn_verify_manifest "$kr" "$2" "$1")" || true'),
 ("U02", "update-scripts: bootstrap keys not checked against MANIFEST", U, "        check_boot_keys || exit 1", "        : check_boot_keys"),
 ("U03", "update-scripts: bootstrap key sidecar not compared", U, '        if [[ "$want" != "$(_sha256 "${BOOT_KEYS}/${p##*/}")" ]]; then', '        if false; then'),
 ("U04", "update-scripts: --check does not verify the newest release", U, '    verify_manifest "${STAGE}/MANIFEST" "${STAGE}/${TN_SIG_FILE}" "$KEYS_DIR" quiet || return 2', '    : verify_manifest'),
 ("U05", "update-scripts: --check does not verify the installed record", U, '    elif ! verify_manifest "$INSTALLED_MANIFEST" "$INSTALLED_SIG" "$KEYS_DIR" quiet \\', '    elif false \\'),
 ("U06", "update-scripts: path_ok lets MANIFEST.asc be a listed file", U, "        MANIFEST|MANIFEST.asc) return 1 ;;", "        MANIFEST) return 1 ;;"),
 ("U07", "update-scripts: bootstraps although a MANIFEST is installed", U, '        if [[ -f "$INSTALLED_MANIFEST" ]]; then\n            print_error "${TN_KEYS_DIR} holds no release key', '        if false; then\n            print_error "${TN_KEYS_DIR} holds no release key'),
 ("U08", "update-scripts: bootstrap uses the keys without verifying MANIFEST.asc", U, '    verify_manifest "${STAGE}/MANIFEST" "${STAGE}/${TN_SIG_FILE}" "$keys" || exit 1', '    [[ "$keys" == "$BOOT_KEYS" ]] || verify_manifest "${STAGE}/MANIFEST" "${STAGE}/${TN_SIG_FILE}" "$keys" || exit 1'),
 ("I01", "install.sh: verdict ignored", I, '    if ! verdict="$(tn_verify_manifest "$kr" "${src}/${TN_SIG_FILE}" "${src}/MANIFEST")"; then', '    verdict="$(tn_verify_manifest "$kr" "${src}/${TN_SIG_FILE}" "${src}/MANIFEST")" || true\n    if false; then'),
 ("I02", "install.sh: also trusts the archive's own keys", I, '    if ! err="$(tn_dearmor_keys "$kdir" 2>&1 > "$kr")"; then', '    if ! err="$(tn_dearmor_keys "$kdir" "${src}/lib/release-keys" 2>&1 > "$kr")"; then'),
 ("I03", "install.sh: file hashes not compared", I, '                [[ "$have" == "$hash" ]] || fail', '                true || fail'),
 ("I04", "install.sh: a release without a key file installs", I, '    grep -q "^p:${TN_KEYS_DIR}/[^/]*\\.asc\\$" "$seen" || fail', '    true || fail'),
 ("R01", "release-scripts: --require-sig without MANIFEST.asc passes", R, '        echo "FAIL no ${TN_SIG_FILE}" >&2\n        bad=1', '        echo "FAIL no ${TN_SIG_FILE}" >&2'),
 ("R02", "release-scripts: a signature that does not verify passes", R, '            echo "FAIL ${TN_SIG_FILE} does not verify against ${TN_KEYS_DIR}: $(tn_sig_reason "$v")" >&2\n            bad=1', '            echo "FAIL ${TN_SIG_FILE} does not verify against ${TN_KEYS_DIR}: $(tn_sig_reason "$v")" >&2'),
 ("R03", "release-scripts: embedded keys not compared", R, '    if [[ "$(embedded_keys)" != "$(keys_concat)" ]]; then', '    if false; then'),
 ("R04", "release-scripts: rewrite_installer drops the keys", R, "            while ((getline line < sf) > 0) print line\n", ""),
 ("R05", "release-scripts: prepare keeps a stale MANIFEST.asc", R, '    mv -f "$tmp" MANIFEST\n    rm -f "$TN_SIG_FILE"', '    mv -f "$tmp" MANIFEST'),
 ("R06", "release-scripts: a key file outside the updater arrays passes", R, "        if ! printf '%s\\n' \"$tracked\" | grep -qxF -- \"$f\"; then", "        if false; then"),
]
def table():
    for m in M: print(m[0] + "\t" + m[1])
if sys.argv[1] == "--list":
    table(); sys.exit(0)
mid, root = sys.argv[1], sys.argv[2]
for m in M:
    if m[0] != mid: continue
    for f in m[2]:
        p = root + "/" + f
        s = open(p).read()
        n = s.count(m[3])
        if n != 1:
            print("anchor count %d in %s for %s" % (n, f, mid)); sys.exit(3)
        open(p, "w").write(s.replace(m[3], m[4]))
    sys.exit(0)
if mid != "M00":
    print("no mutant " + mid); sys.exit(3)
PYEOF

if [[ "${1:-}" == --list ]]; then
    python3 -I "$PY" --list
    exit 0
fi

# failing FILE -- "name name" of the fixture files run.sh reports with exit != 0.
failing_fixtures() {
    awk '/^== tools\/tests\/[a-z_0-9]*_test\.sh: exit [0-9]+$/ { split($2, a, "/"); sub(/_test\.sh:$/, "", a[3]); if ($4 != 0) printf "%s ", a[3] }' "$1"
}

one() {
    local id="$1" d out base f n new
    d="${ROOT}/${id}"
    out="${ROOT}/${id}.out"
    rm -rf "$d" "$out"
    mkdir -p "$out"
    git clone -q --depth 1 "file://$WT" "$d" 2>/dev/null || { echo "${id}	clone failed"; return; }
    if ! python3 -I "$PY" "$id" "$d" > "$out/mutate.log" 2>&1; then
        printf '%s\tMUTATION NOT APPLIED: %s\n' "$id" "$(cat "$out/mutate.log")"
        return
    fi
    (cd "$d" && HOME="${ROOT}/home" GIT_CONFIG_NOSYSTEM=1 git -c user.name=v7 -c user.email=v7@example.invalid -c commit.gpgsign=false commit -q -am "mutant ${id}" --allow-empty)
    mkdir -p "$d/tasks/verify-r2/V7"
    cp "$HERE"/*.sh "$d/tasks/verify-r2/V7/"
    (cd "$d" && bash tools/tests/run.sh $FIX > "$out/fx-real.log" 2>&1)
    (cd "$d" && TN_TEST_FAKE_GPG=1 bash tools/tests/run.sh $FIX > "$out/fx-fake.log" 2>&1)
    new=""
    for f in $HARNESS; do
        (cd "$d" && V7_GRANTKEE_DEARMOR_SHA="$REF_SHA" bash "tasks/verify-r2/V7/$f" > "$out/$f.log" 2>&1)
        base="${ROOT}/M00.out/$f.log"
        n=0
        if [[ -f "$base" ]]; then
            n="$(grep '^FAIL  ' "$out/$f.log" | sort -u | comm -23 - <(grep '^FAIL  ' "$base" | sort -u) | wc -l | tr -d ' ')"
        else
            n="$(grep -c '^FAIL  ' "$out/$f.log")"
        fi
        [[ "$n" == 0 ]] || new="${new}${f%.sh}:${n} "
    done
    printf '%s\treal: %s\tfake: %s\tv7: %s\n' "$id" "$(failing_fixtures "$out/fx-real.log")" "$(failing_fixtures "$out/fx-fake.log")" "$new"
    rm -rf "$d"
}

if [[ "${1:-}" == --one ]]; then
    one "$2"
    exit 0
fi

: > "${ROOT}/results.tsv"
one M00 | tee -a "${ROOT}/results.tsv"
python3 -I "$PY" --list | cut -f1 | xargs -P 6 -I{} bash "${BASH_SOURCE[0]}" --one {} | tee -a "${ROOT}/results.tsv"
