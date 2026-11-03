#!/usr/bin/env bash
# =============================================================================
# tools/tests/run.sh -- run the fixture tests under the bash that runs this file
#
#   bash tools/tests/run.sh                         # every tools/tests/*_test.sh
#   bash tools/tests/run.sh tools/tests/x_test.sh   # only the named files
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/run.sh
#
# Each test file runs as its own process under this bash ($BASH), so one test
# cannot leak state into the next. Its output streams through, then one line
# "== <file>: exit <rc>". Exit status: 0 when every file exits 0, 1 when any
# fails or no test file was found, 2 when a named file does not exist.
#
# Maintainer tooling: update-scripts.sh does not track tools/ and this file has
# no .sha256 sidecar. bash 3.2 safe.
# =============================================================================

set -u

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sh="${BASH:-bash}"

files=()
if [ $# -gt 0 ]; then
    for f in "$@"; do
        if [ ! -f "$f" ]; then
            printf 'run.sh: no such test file: %s\n' "$f" >&2
            exit 2
        fi
        files+=("$f")
    done
else
    for f in "$dir"/*_test.sh; do
        [ -f "$f" ] && files+=("$f")
    done
fi

if [ "${#files[@]}" -eq 0 ]; then
    printf 'run.sh: no test files found in %s\n' "$dir" >&2
    exit 1
fi

failed=0
summary=()
for f in "${files[@]}"; do
    name="${f#"$dir"/}"
    printf '\n== %s (bash %s)\n' "$name" "$BASH_VERSION"
    "$sh" "$f"
    rc=$?
    printf '== %s: exit %s\n' "$name" "$rc"
    summary+=("$(printf '%-36s exit %s' "$name" "$rc")")
    [ "$rc" -eq 0 ] || failed=$((failed + 1))
done

printf '\n'
for line in "${summary[@]}"; do
    printf '%s\n' "$line"
done
printf '%s test file(s), %s failed (bash %s)\n' "${#files[@]}" "$failed" "$BASH_VERSION"
[ "$failed" -eq 0 ] || exit 1
exit 0
