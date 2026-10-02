#!/usr/bin/env bash
# =============================================================================
# tools/check-bash32.sh -- flag bash 4+ syntax that macOS /bin/bash 3.2 cannot run
#
# Operators run these scripts on macOS, where /bin/bash is 3.2. CI parse-checks
# every script under 3.2, but `bash -n` accepts most bash-4 constructs because
# they fail only when the line runs: `declare -A` is a runtime error there, and
# ${var,,} is a "bad substitution" at the moment it expands. This lint finds them
# by pattern instead.
#
# Flagged, one report per construct per line:
#   declare, typeset or local with -A, -g, -n, -l or -u (bundled clusters such
#     as -gA count); readonly -A
#   case modification: ${v,,} ${v,} ${v^^} ${v^} ${v~~} ${v~}, on arrays too
#   mapfile, readarray and coproc in command position
#   &>>   |&   [[ -v   [ -v and test -v   wait with any option (wait -n)
#   negative subscripts: ${a[-1]}, a[-1]= and a[-1] inside (( )) or $(( ))
#   negative substring lengths: ${v:0:-1} (bash 4.2)
#   named file-descriptor redirections: exec {fd}>file (bash 4.1)
#   ${v@Q} and the other @ transformations
#   printf with a %(...)T time format
#   the ;;& and ;& case terminators
#
# How a file is read (one awk pass per file):
#   - Quotes are tracked the way bash tracks them, across lines. Command-style
#     constructs count only outside quotes and in command position (line start,
#     after ; & | ( ) { ! or a backtick, so one-line case arms are covered).
#     Expansions count outside single quotes too, because "${v,,}" still expands.
#     Text inside $( ) and backticks is code even within double quotes.
#   - Lines joined by a trailing backslash are checked as one line and reported
#     at the first of them.
#   - Comments are skipped: a # that starts a word begins one, which covers
#     whole comment lines and trailing comments.
#   - Heredoc bodies are skipped, with one exception: in an unquoted heredoc
#     (<<EOF, not <<'EOF') the running shell expands ${...}, so the expansion
#     checks still apply there. Escape the dollar sign (\${v,,}) when the text is
#     meant for another program. Inside (( )) and $(( )), including for((...))
#     written without a space, << is a shift, not a heredoc.
#   - A line containing "# bash32-ok" is never reported. Put the reason after
#     the marker.
#
# Blind spots: a construct inside a string that another shell evaluates
# (bash -c '...', eval "..."), and the deprecated $[ ] arithmetic. A file whose
# quotes or heredocs the lint cannot follow to the end is an error (exit 2), so a
# lint bug never passes a file it did not read.
#
# Maintainer tool: update-scripts.sh does not track it and it has no .sha256
# sidecar. It is bash 3.2 clean so it runs on stock macOS, and its awk program is
# POSIX (tested with macOS awk and mawk).
#
# USAGE:
#   tools/check-bash32.sh FILE...
#   tools/check-bash32.sh *.sh lib/*.sh ui/*.sh ui/tests/*.sh tools/*.sh lib/wgvpn/*.sh
#
# Exit status: 0 clean, 1 constructs found, 2 usage error (no files, a
# directory, an unreadable file) or a file the lint could not read reliably.
# =============================================================================

set -u

usage() {
    cat <<'EOF'
usage: tools/check-bash32.sh FILE...

Report bash 4+ syntax that macOS /bin/bash 3.2 cannot run. Each hit prints as
  FILE:LINE: <construct> -- <the line>
followed by a summary line. Add "# bash32-ok" to a line to accept it.

Exit status: 0 clean, 1 constructs found, 2 usage error or unreadable file.
EOF
}

# The scanner. Context stack st[]: N top level, C inside $( ) or (( )), B inside
# backticks, D double quotes, S single quotes, A $'...' strings. pd[] counts open
# parentheses in a C frame and pa[] marks arithmetic frames, where << is a shift.
# For each line it builds four views: code (all quoted text blanked), expn (only
# single-quoted text blanked), full (quotes kept, for the printf format check) and
# arith (text inside arithmetic frames). A line ending in a backslash outside a
# comment sets cont, and its views are carried into the next line before checking.
# Pending heredocs queue in hq_*; their bodies start after the logical line ends.
# Exit status: 0 clean, 1 hits, 3 the file ended inside a quote, a substitution
# or a heredoc, so the rest of it was not read as code.
AWK_PROG='
function push(kind, depth) { sp++; st[sp] = kind; pd[sp] = depth; pa[sp] = 0 }
function pop() { if (sp > 1) sp-- }
function emit(c, cc, ce) { code = code cc; expn = expn ce; full = full c }
function wordstart(i) { return (i <= 1) || (substr(raw, i - 1, 1) ~ /[ \t;&|(]/) }
# (( straight after for, if, elif, while or until opens arithmetic too.
function kwbefore(i) { return substr(raw, 1, i - 1) ~ /(^|[^A-Za-z0-9_])(for|if|elif|while|until)$/ }
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

function report(label) {
    if (rep_quiet || (label in seen)) return
    seen[label] = 1
    printf "%s:%d: %s -- %s\n", fname, rep_nr, label, rep_text
    hits++
}

# Expansion checks on text the running shell expands.
function check_expansions(s, where) {
    if (s ~ /[$][{]!?([A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*])(\[[^]]*\])?[,^~]/)
        report("case-modification expansion" where)
    if (s ~ /[$][{]!?([A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*])(\[[^]]*\])?@[A-Za-z][}]/)
        report("${var@X} transformation" where)
    if (s ~ /[$][{][#!]?[A-Za-z_][A-Za-z0-9_]*\[[ \t]*-[^-]/)
        report("negative array subscript" where)
    if (s ~ /[$][{]([A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*])(\[[^]]*\])?:([ \t]*[0-9A-Za-z_$(][^:}]*|[ \t]+-[^:}]*)?:[ \t]*-[ \t]*[0-9A-Za-z_$(]/)
        report("negative substring length" where)
}

# Command and operator checks on code with every quoted string blanked.
function check_code(s,    rest, cmd, cl, m) {
    rest = s
    while (match(rest, CMDPOS "(declare|typeset|local|readonly)[ \t]+[-+]")) {
        cmd = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH - 1)
        sub(/[ \t]+[-+]$/, "", cmd)
        sub(/^.*[^A-Za-z]/, "", cmd)
        while (match(rest, /^[-+][A-Za-z]+/)) {
            cl = substr(rest, 1, RLENGTH)
            rest = substr(rest, RLENGTH + 1)
            if (cmd == "readonly") {
                if (cl ~ /A/) report(cmd " " cl)
            } else if (cl ~ /[Agnlu]/) {
                report(cmd " " cl)
            }
            if (!match(rest, /^[ \t]+[-+]/)) break
            sub(/^[ \t]+/, "", rest)
        }
    }
    if (s ~ (CMDPOS "mapfile" CMDEND)) report("mapfile")
    if (s ~ (CMDPOS "readarray" CMDEND)) report("readarray")
    if (s ~ (CMDPOS "coproc" CMDEND)) report("coproc")
    if (index(s, "&>>")) report("&>>")
    if (index(s, "|&")) report("|&")
    if (s ~ /\[\[[ \t]+(![ \t]+)?-v[ \t]/ || s ~ /(&&|[|][|])[ \t]+(![ \t]+)?-v[ \t]/)
        report("[[ -v")
    if (s ~ (CMDPOS "(\\[|test)[ \t]+(![ \t]+)?-v[ \t]")) report("test -v")
    if (match(s, CMDPOS "wait[ \t]+-[A-Za-z]+")) {
        m = substr(s, RSTART, RLENGTH)
        sub(/^.*wait[ \t]+/, "", m)
        report("wait " m)
    }
    if (s ~ /(^|[^A-Za-z0-9_$])[A-Za-z_][A-Za-z0-9_]*\[[ \t]*-[^]-][^]]*\][+]?=/)
        report("negative array subscript")
    if (s ~ /(^|[^$])[{][A-Za-z_][A-Za-z0-9_]*[}][<>]/)
        report("named fd redirection {var}>")
    if (index(s, ";;&")) report(";;&")
    else if (s ~ /(^|[^;]);&/) report(";&")
}

# All checks for one logical line (the a_* views).
function run_checks() {
    split("", seen)
    rep_quiet = a_quiet
    rep_nr = a_nr
    rep_text = a_text
    check_code(a_code)
    check_expansions(a_expn, "")
    if (a_arith ~ /[A-Za-z_][A-Za-z0-9_]*\[[ \t]*-[^-]/)
        report("negative array subscript")
    # The format string is normally quoted, so the format is matched on full,
    # while printf itself must be an unquoted command.
    if (a_code ~ (CMDPOS "printf" CMDEND) && a_full ~ /%[-+ #0]*[0-9]*([.][0-9]*)?[(][^)]*[)]T/)
        report("printf %(...)T")
}

# One line of a heredoc body: either its terminator or text to skip.
function body(    t) {
    t = raw
    if (hq_strip[hq_head]) sub(/^\t+/, "", t)
    if (t == hq_word[hq_head]) { hq_head++; return }
    if (hq_live[hq_head]) {
        split("", seen)
        rep_quiet = (index(raw, "# bash32-ok") > 0)
        rep_nr = NR
        rep_text = trim(raw)
        t = raw
        gsub(/\\\\/, "xx", t)
        gsub(/\\[$]/, "xx", t)
        check_expansions(t, " in an unquoted heredoc")
    }
}

function scan(    n, i, c, nx, top, inar, j, k, d, t, word, quoted, strip) {
    code = ""; expn = ""; full = ""; arith = ""; cont = 0
    n = length(raw)
    i = 1
    while (i <= n) {
        c = substr(raw, i, 1)
        nx = substr(raw, i + 1, 1)
        top = st[sp]
        if (top == "S") {
            if (c == SQ) { pop(); emit(c, c, c) } else emit(c, "x", "x")
            i++
            continue
        }
        if (top == "A") {
            if (c == "\\") { emit(c nx, "xx", "xx"); i += 2; continue }
            if (c == SQ) { pop(); emit(c, c, c) } else emit(c, "x", "x")
            i++
            continue
        }
        if (top == "D") {
            if (c == "\\" && i == n) { cont = 1; i++; continue }
            if (c == "\\") { emit(c nx, "xx", "xx"); i += 2; continue }
            if (c == "\"") { pop(); emit(c, c, c); i++; continue }
            if (c == "$" && nx == "(") {
                push("C", 1); pa[sp] = (substr(raw, i + 2, 1) == "(")
                if (pa[sp]) arith = arith " "
                emit("$(", "$(", "$("); i += 2; continue
            }
            if (c == "`") { push("B", 0); emit(c, c, c); i++; continue }
            emit(c, "x", c)
            i++
            continue
        }
        # Code: N, C or B.
        inar = (top == "C" && pa[sp])
        if (c == "\\" && i == n) { cont = 1; i++; continue }
        if (c == "\\") { emit(c nx, "xx", "xx"); i += 2; continue }
        if (c == "#" && wordstart(i)) break
        if (c == SQ) { push("S", 0); emit(c, c, c); i++; continue }
        if (c == "\"") { push("D", 0); emit(c, c, c); i++; continue }
        if (c == "$" && nx == SQ) { push("A", 0); emit(c nx, c nx, c nx); i += 2; continue }
        if (c == "$" && nx == "(") {
            push("C", 1); pa[sp] = (substr(raw, i + 2, 1) == "(")
            if (pa[sp]) arith = arith " "
            emit("$(", "$(", "$("); i += 2; continue
        }
        if (c == "`") {
            if (top == "B") pop(); else push("B", 0)
            emit(c, c, c); i++; continue
        }
        if (c == "(" && nx == "(" && top != "B" && (wordstart(i) || kwbefore(i))) {
            push("C", 2); pa[sp] = 1
            arith = arith " "
            emit("((", "((", "(("); i += 2; continue
        }
        if (top == "C" && c == "(") pd[sp]++
        if (top == "C" && c == ")") { pd[sp]--; if (pd[sp] <= 0) pop() }
        if (c == "<" && nx == "<" && !inar) {
            if (substr(raw, i + 2, 1) == "<") { emit("<<<", "<<<", "<<<"); i += 3; continue }
            j = i + 2
            strip = 0
            if (substr(raw, j, 1) == "-") { strip = 1; j++ }
            while (substr(raw, j, 1) == " " || substr(raw, j, 1) == "\t") j++
            word = ""
            quoted = 0
            while (j <= n) {
                d = substr(raw, j, 1)
                if (d == SQ || d == "\"") {
                    k = index(substr(raw, j + 1), d)
                    if (k == 0) k = n - j + 1
                    word = word substr(raw, j + 1, k - 1)
                    j += k + 1
                    quoted = 1
                    continue
                }
                if (d == "\\") { word = word substr(raw, j + 1, 1); j += 2; quoted = 1; continue }
                if (d ~ /[ \t;&|()<>`]/) break
                word = word d
                j++
            }
            if (word != "") {
                hq_tail++
                hq_word[hq_tail] = word
                hq_strip[hq_tail] = strip
                hq_live[hq_tail] = !quoted
            }
            t = substr(raw, i, j - i)
            emit(t, t, t)
            i = j
            continue
        }
        if (inar) arith = arith c
        emit(c, c, c)
        i++
    }
}

BEGIN {
    sp = 1; st[1] = "N"; pd[1] = 0; pa[1] = 0
    hq_head = 1; hq_tail = 0
    hits = 0
    acc = 0
    fname = ENVIRON["CB32_FILE"]
    # Command position: line start or after ; & | ( ) { ! or a backtick, then any
    # keywords (then, do, command, ...) and prefix assignments (IFS= ...).
    # So "command -v mapfile" and "echo mapfile" are not calls, while the body of
    # a one-line case arm "a) mapfile ..." is.
    CMDPOS = "(^|[;&|()!{`])[ \t]*((if|then|do|else|elif|while|until|time|command|builtin|exec|!)[ \t]+|[A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]+)*"
    CMDEND = "([ \t;&|)]|$)"
}

{
    raw = $0
    sub(/\r$/, "", raw)
    if (!acc && hq_head <= hq_tail) { body(); next }
    scan()
    t = trim(raw)
    if (cont) sub(/[ \t]*\\$/, "", t)
    if (acc) {
        a_code = a_code code; a_expn = a_expn expn; a_full = a_full full
        a_arith = a_arith " " arith
        a_text = a_text " " t
        if (index(raw, "# bash32-ok") > 0) a_quiet = 1
    } else {
        a_code = code; a_expn = expn; a_full = full; a_arith = arith
        a_text = t
        a_nr = NR
        a_quiet = (index(raw, "# bash32-ok") > 0)
    }
    if (cont) { acc = 1; next }
    acc = 0
    run_checks()
}

END {
    if (acc) run_checks()
    broken = 0
    if (hq_head <= hq_tail) {
        printf "check-bash32: %s: heredoc %s is never closed\n", fname, hq_word[hq_head] > "/dev/stderr"
        broken = 1
    }
    if (sp > 1) {
        printf "check-bash32: %s: the file ends inside an open quote or substitution\n", fname > "/dev/stderr"
        broken = 1
    }
    if (broken) exit 3
    exit (hits > 0)
}
'

if [[ $# -eq 0 ]]; then
    usage >&2
    exit 2
fi
case "$1" in
    -h|--help) usage; exit 0 ;;
    --) shift ;;
    -*) printf 'check-bash32: unknown option %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac
if [[ $# -eq 0 ]]; then
    usage >&2
    exit 2
fi

# Check every argument before scanning any, so a typo fails fast.
for f in "$@"; do
    if [[ -d "$f" ]]; then
        printf 'check-bash32: %s is a directory; pass the script files instead (for example %s/*.sh)\n' "$f" "${f%/}" >&2
        exit 2
    fi
    if [[ ! -f "$f" || ! -r "$f" ]]; then
        printf 'check-bash32: cannot read %s\n' "$f" >&2
        exit 2
    fi
done

scanned=0
flagged=0
hits=0
unreadable=0
for f in "$@"; do
    scanned=$((scanned + 1))
    # The file goes in on stdin and its name through the environment, so awk
    # never treats a name as an assignment or processes backslashes in it.
    out="$(CB32_FILE="$f" LC_ALL=C awk -v SQ="'" "$AWK_PROG" < "$f")"
    rc=$?
    if [[ -n "$out" ]]; then
        printf '%s\n' "$out"
        n="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
        hits=$((hits + n))
        flagged=$((flagged + 1))
    fi
    case "$rc" in
        0) ;;
        1) if [[ -z "$out" ]]; then printf 'check-bash32: awk failed on %s\n' "$f" >&2; exit 2; fi ;;
        3) unreadable=$((unreadable + 1)) ;;
        *) printf 'check-bash32: awk failed on %s (exit %s)\n' "$f" "$rc" >&2; exit 2 ;;
    esac
done

if [[ $unreadable -gt 0 ]]; then
    printf 'check-bash32: %s construct(s) found, and %s of %s file(s) could not be read to the end (see above)\n' \
        "$hits" "$unreadable" "$scanned"
    exit 2
fi
if [[ $hits -eq 0 ]]; then
    printf 'check-bash32: clean, %s file(s) scanned\n' "$scanned"
    exit 0
fi
printf 'check-bash32: %s bash-4 construct(s) in %s of %s file(s)\n' "$hits" "$flagged" "$scanned"
exit 1
