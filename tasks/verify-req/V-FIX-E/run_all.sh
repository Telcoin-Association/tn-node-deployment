#!/usr/bin/env bash
# =============================================================================
# tasks/verify-req/V-FIX-E/run_all.sh OUT_DIR -- build the comparison trees and
# run menu13_test.sh on the host and as root in ubuntu:26.04, plus the E6 and
# E7 runs. OUT_DIR must not exist yet. Nothing is written in the worktree.
#
#   trees: old    edit-config.sh + lib of 01664cc
#          skew1  this edit-config.sh + the lib of 01664cc  (E7a)
#          skew2  the edit-config.sh of 01664cc + this lib  (E7b)
# =============================================================================

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT="$(cd "${HERE}/../../.." && pwd)"
OUT="${1:?usage: run_all.sh OUT_DIR (a directory that does not exist yet)}"
if [[ -e "$OUT" ]]; then
    echo "run_all.sh: ${OUT} exists; give a new directory" >&2
    exit 2
fi
mkdir -p "$OUT/trees/old" "$OUT/trees/skew1" "$OUT/trees/skew2"
BASE=01664cc
git -C "$WT" show "${BASE}:edit-config.sh" > "$OUT/trees/old/edit-config.sh"
git -C "$WT" archive "$BASE" lib | tar -x -C "$OUT/trees/old"
cp "$WT/edit-config.sh" "$OUT/trees/skew1/edit-config.sh"
ln -s ../old/lib "$OUT/trees/skew1/lib"
cp "$OUT/trees/old/edit-config.sh" "$OUT/trees/skew2/edit-config.sh"
ln -s "$WT/lib" "$OUT/trees/skew2/lib"

echo "== host: main"
bash "$HERE/menu13_test.sh" main > "$OUT/host-main.txt" 2>&1
echo "rc=$?  $(tail -n 1 "$OUT/host-main.txt")"

echo "== host: E7a (this edit-config.sh, the 01664cc lib)"
bash "$OUT/trees/skew1/edit-config.sh" > "$OUT/e7a-human.txt" 2>&1
echo "rc=$? $(cat "$OUT/e7a-human.txt")"
bash "$OUT/trees/skew1/edit-config.sh" --json --set verbosity=-v > "$OUT/e7a-json.txt" 2>&1
echo "rc=$? $(cat "$OUT/e7a-json.txt")"

echo "== host: E6 existing tests"
bash "$WT/tools/tests/run.sh" "$WT/tools/tests/edit_backup_test.sh" "$WT/tools/tests/edit_config_resync_test.sh" > "$OUT/host-e6.txt" 2>&1
echo "rc=$?  $(tail -n 3 "$OUT/host-e6.txt" | tr '\n' ' ')"

# The docker runs: the worktree read-only, the trees read-only, output in OUT.
D="docker run --rm -v ${WT}:${WT}:ro -v ${OUT}/trees:${OUT}/trees:ro -v ${OUT}:/out -e TMPDIR=/vfe ubuntu:26.04 bash -c"
PRE="mkdir -m 0755 /vfe && apt-get update -qq >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git >/dev/null 2>&1"
echo "== ubuntu:26.04 (root): main, cmp new/old, oldscript, E6"
$D "$PRE
bash ${HERE}/menu13_test.sh main > /out/docker-main.txt 2>&1; echo \"main rc=\$?\"
V_OLD_SRC=1 bash ${HERE}/menu13_test.sh cmp > /out/docker-cmp-new.txt 2>&1; echo \"cmp-new rc=\$?\"
V_OLD_SRC=1 V_TREE=${OUT}/trees/old bash ${HERE}/menu13_test.sh cmp > /out/docker-cmp-old.txt 2>&1; echo \"cmp-old rc=\$?\"
V_OLD_SRC=1 V_TREE=${OUT}/trees/skew2 bash ${HERE}/menu13_test.sh oldscript > /out/docker-oldscript.txt 2>&1; echo \"oldscript rc=\$?\"
bash ${WT}/tools/tests/run.sh ${WT}/tools/tests/edit_backup_test.sh ${WT}/tools/tests/edit_config_resync_test.sh > /out/docker-e6.txt 2>&1; echo \"e6 rc=\$?\"
chown -R $(id -u):$(id -g) /out"
for f in docker-main docker-cmp-new docker-cmp-old docker-oldscript docker-e6; do
    echo "$f: $(tail -n 1 "$OUT/$f.txt")"
done
echo "== cmp diff (old vs new), apply path"
diff "$OUT/docker-cmp-old.txt" "$OUT/docker-cmp-new.txt" > "$OUT/cmp.diff"
echo "diff rc=$? (see $OUT/cmp.diff)"
