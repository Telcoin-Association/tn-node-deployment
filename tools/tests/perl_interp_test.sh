#!/usr/bin/env bash
# =============================================================================
# tools/tests/perl_interp_test.sh -- tools/check-perl-interp.sh on fixtures
# and on the tree
#
#   bash tools/tests/perl_interp_test.sh
#
# Every bad_* fixture in tools/tests/perl-interp.d/ exits 1 with exactly the
# FILE:LINE findings listed below; every good_* fixture exits 0 with no output.
# Then the argument errors (a missing file, a directory, an unknown option, a
# file the lint cannot read to the end: exit 2), the no-argument mode outside
# git (find fallback), and last the tree: no tracked *.sh file may hold a
# finding (skipped where git or the work tree is unavailable).
#
# The fixtures end in .fixture, not .sh, so the CI steps that sweep
# `git ls-files '*.sh'` (parse, bash32, shellcheck and this lint) never see the
# deliberately bad ones; a check below keeps it that way. bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SH="${BASH:-bash}"
LINT="$TN_TEST_REPO/tools/check-perl-interp.sh"
FX="$TN_TEST_REPO/tools/tests/perl-interp.d"
T="$TN_TEST_TMP"
MSG='perl program expands a shell variable'
MSG_O='perl program comes from stdin or <( ), which the lint cannot read'

# finding_lines OUTPUT -- the FILE:LINE part of each finding line, either kind.
finding_lines() {
    printf '%s\n' "$1" | sed -n -e "s/^\(.*:[0-9][0-9]*\): $MSG: .*/\1/p" \
        -e "s/^\(.*:[0-9][0-9]*\): $MSG_O: .*/\1/p"
}

# bad FIXTURE LINE... -- the lint exits 1 and reports exactly these lines.
listed=" "
bad() {
    local name="$1" f out rc want
    shift
    listed="$listed$name "
    f="$FX/$name"
    out="$("$SH" "$LINT" "$f" 2>/dev/null)"
    rc=$?
    check_rc "$name: exit 1" 1 "$rc"
    want="$(for l in "$@"; do printf '%s:%s\n' "$f" "$l"; done)"
    check "$name: findings" "$want" "$(finding_lines "$out")"
    check "$name: stdout holds only findings" "$#" "$(printf '%s\n' "$out" | grep -c .)"
}

# --- bad fixtures --------------------------------------------------------------

bad bad_braced.fixture 7 12
bad bad_plain.fixture 7 8 9 10 11
bad bad_slurp.fixture 6 7
bad bad_switches.fixture 7 8 9 10 11 12
bad bad_continued.fixture 7 11 15
bad bad_heredoc.fixture 8 13 14 17
bad bad_subst.fixture 7 8 9 10 11
bad bad_stdin_pipe.fixture 7 8 9 10 12 13 14 15 17
bad bad_dev_stdin.fixture 8 10 12 14 15
bad bad_procsub.fixture 7 8 9 10
bad bad_module.fixture 8 9 10 11 12 13
bad bad_versioned.fixture 7 8 9 10

unlisted=""
for f in "$FX"/bad_*; do
    [[ -f "$f" ]] || continue
    case "$listed" in
        *" ${f##*/} "*) ;;
        *) unlisted="$unlisted ${f##*/}" ;;
    esac
done
check "every bad fixture has its expected findings here" "" "$unlisted"
check "no fixture is a *.sh file (CI sweeps those)" "" \
    "$(for f in "$FX"/*.sh; do [[ -e "$f" ]] && printf '%s\n' "${f##*/}"; done)"

out="$("$SH" "$LINT" "$FX/bad_braced.fixture" 2>/dev/null)"
check_has "a finding prints FILE:LINE, the message and the trimmed line" \
    "$FX/bad_braced.fixture:7: $MSG: "'perl -i -pe "s|\Q${old_image}\E|${new_image}|g" "$launch_file"' "$out"
out="$("$SH" "$LINT" "$FX/bad_continued.fixture" 2>/dev/null)"
check_has "a continued command prints as one line at the line of perl" \
    "$FX/bad_continued.fixture:7: $MSG: "'perl -i -pe "s/$old/$new/g" "$3"' "$out"
out="$("$SH" "$LINT" "$FX/bad_heredoc.fixture" 2>/dev/null)"
check_has "a heredoc program prints the body line" \
    "$FX/bad_heredoc.fixture:8: $MSG: s/old/\$new/;" "$out"
out="$("$SH" "$LINT" "$FX/bad_stdin_pipe.fixture" 2>/dev/null)"
check_has "a piped program prints the second message" \
    "$FX/bad_stdin_pipe.fixture:7: $MSG_O: printf '%s\n' \"\$prog\" | perl" "$out"
check_has "a pipe on the line before prints at the line of perl" \
    "$FX/bad_stdin_pipe.fixture:12: $MSG_O: perl -w" "$out"
out="$("$SH" "$LINT" "$FX/bad_module.fixture" 2>/dev/null)"
check_has "a module from the shell prints the first message" \
    "$FX/bad_module.fixture:8: $MSG: perl -M\"\$mod\" -e 'print 1'" "$out"

# --- good fixtures -------------------------------------------------------------

goods=0
for f in "$FX"/good_*; do
    [[ -f "$f" ]] || continue
    goods=$((goods + 1))
    out="$("$SH" "$LINT" "$f" 2>/dev/null)"
    rc=$?
    check_rc "${f##*/}: exit 0" 0 "$rc"
    check "${f##*/}: no findings" "" "$out"
done
check "good fixtures found" yes "$([[ $goods -ge 8 ]] && echo yes || echo no)"

# --- several files, arguments and errors ---------------------------------------

out="$("$SH" "$LINT" "$FX/good_env.fixture" "$FX/bad_slurp.fixture" 2>"$T/err")"
rc=$?
check_rc "good + bad files: exit 1" 1 "$rc"
check "good + bad files: the bad file's findings" \
    "$(printf '%s\n' "$FX/bad_slurp.fixture:6" "$FX/bad_slurp.fixture:7")" "$(finding_lines "$out")"
check_has "good + bad files: summary on stderr" \
    "check-perl-interp: 2 perl program(s) expanding a shell variable in 1 of 2 file(s)" "$(cat "$T/err")"
"$SH" "$LINT" "$FX/good_env.fixture" "$FX/good_words.fixture" 2>"$T/err"
check_rc "two good files: exit 0" 0 "$?"
check_has "two good files: clean summary on stderr" "check-perl-interp: clean, 2 file(s) scanned" "$(cat "$T/err")"

"$SH" "$LINT" "$T/missing.sh" >/dev/null 2>&1
check_rc "missing file: exit 2" 2 "$?"
out="$("$SH" "$LINT" "$FX/bad_braced.fixture" "$T/missing.sh" 2>/dev/null)"
check_rc "missing file after a bad one: exit 2" 2 "$?"
check "missing file after a bad one: nothing scanned" "" "$out"
"$SH" "$LINT" "$FX" >/dev/null 2>&1
check_rc "directory argument: exit 2" 2 "$?"
"$SH" "$LINT" -x >/dev/null 2>&1
check_rc "unknown option: exit 2" 2 "$?"
"$SH" "$LINT" --help >/dev/null 2>&1
check_rc "--help: exit 0" 0 "$?"
printf 'perl -e "print 1\n' > "$T/open_quote.sh"
"$SH" "$LINT" "$T/open_quote.sh" >/dev/null 2>&1
check_rc "file ending inside a quote: exit 2" 2 "$?"
printf 'perl <<EOF\nprint 1;\n' > "$T/open_heredoc.sh"
"$SH" "$LINT" "$T/open_heredoc.sh" >/dev/null 2>&1
check_rc "heredoc never closed: exit 2" 2 "$?"

# --- no arguments outside git: every *.sh under the root, found with find ------

mkdir -p "$T/tree/tools" "$T/tree/sub"
cp "$LINT" "$T/tree/tools/"
cp "$FX/bad_braced.fixture" "$T/tree/sub/a.sh"
cp "$FX/good_env.fixture" "$T/tree/b.sh"
cp "$FX/bad_slurp.fixture" "$T/tree/c.txt"
out="$(cd / && GIT_CEILING_DIRECTORIES="$T" "$SH" "$T/tree/tools/check-perl-interp.sh" 2>"$T/err")"
rc=$?
check_rc "no arguments outside git: exit 1" 1 "$rc"
check "no arguments outside git: findings in *.sh files only" \
    "$(printf '%s\n' ./sub/a.sh:7 ./sub/a.sh:12)" "$(finding_lines "$out")"
check_has "no arguments outside git: three *.sh files scanned" \
    "check-perl-interp: 2 perl program(s) expanding a shell variable in 1 of 3 file(s)" "$(cat "$T/err")"

# --- the tree ------------------------------------------------------------------

if ! command -v git >/dev/null 2>&1; then
    skip "tree passes" "git absent"
elif ! git -C "$TN_TEST_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    skip "tree passes" "not a git work tree"
else
    # No arguments: the lint checks git ls-files '*.sh' from the repo root, the
    # same set CI passes it. The .fixture files above are not part of it.
    out="$(cd "$TN_TEST_REPO" && "$SH" "$LINT" 2>&1)"
    rc=$?
    check_rc "tree passes" 0 "$rc" || printf '%s\n' "$out" | sed 's/^/      /'
fi

finish
