#!/usr/bin/env bash
# =============================================================================
# tools/check-perl-interp.sh -- flag perl programs that expand a shell variable
#
# A perl program written in double quotes, such as
#     perl -i -pe "s|\Q${old}\E|${new}|g" "$file"
# is assembled by the shell before perl sees it, so the variable's value is
# parsed as perl code instead of being used as data (the @ of an image pinned
# by digest reads as a perl array). Pass values as data and keep the program in
# single quotes:
#     OLD="$old" NEW="$new" perl -i -pe 's|\Q$ENV{OLD}\E|$ENV{NEW}|g' "$file"
#     perl -e 'my ($old, $new) = @ARGV; ...' "$old" "$new"
#     perl -s -e 'print "$old\n"' -- -old="$old"
#
# Flagged, one report per perl command (reported at the line holding the word
# perl), or per line of a heredoc program:
#   - a program given to -e or -E, as the next word or attached (-e"...", in a
#     cluster such as -pe, -lne, -0777 -ne, -i.bak -pe), that contains a shell
#     expansion outside single quotes: an unescaped $ followed by a name
#     character, a digit, {, (, or one of @ * # ? ! $ -, or a backtick. So
#     "s/$x/y/", "s|${a}|b|", "$prog" and $prog are findings; "s/\$x/y/" and
#     "s/foo$/bar/" are not. Every -e of the command is checked.
#   - a program read from an unquoted heredoc (perl <<EOF, perl - ARGS <<EOF,
#     with no -e): each body line holding such an expansion. <<'EOF' is fine.
#     Likewise a here-string program (perl <<< "$prog").
# Not flagged: single-quoted programs ('...$ENV{X}...' reads the value at run
# time), $'...' strings, data passed as arguments (@ARGV, -s switches after --,
# the FILE operand "$file"; without the --, perl reads -new="$v" as its own
# -n -e switches, which is flagged), heredocs and here-strings given to a perl
# that has an -e program (they are data), and the word perl where no program
# follows (echo "perl missing", command -v perl, for c in perl docker).
#
# How a file is read (one awk pass per file): quotes, $( ), backticks and
# arithmetic are tracked across lines; any word that is exactly perl, or a path
# ending in /perl (with no expansion in it), starts a perl command, which ends
# at ; & | ( ) or a newline. Lines joined by a trailing backslash are one
# command. Comments (a # that starts a word, so whole comment lines and
# trailing comments) and heredoc bodies are skipped, except the body of a
# heredoc that feeds a perl program.
#
# Exemption: a perl command with "# perl-interp-ok" on any of its lines (or a
# heredoc body line carrying it) is not reported. Put the reason after it:
#     perl -e "print $$" # perl-interp-ok prints the shell pid on purpose
#
# Blind spots: perl inside a string another shell runs (bash -c '...', eval,
# ssh host "..."), perl written into a generated script through a heredoc, a
# program held in a variable and then passed through "$@", and a perl reached
# through a variable ("$PERL" -e ...). A file whose quotes or heredocs the lint
# cannot follow to the end is an error (exit 2), so a lint bug never passes a
# file it did not read.
#
# Maintainer tool: update-scripts.sh does not track it and it has no .sha256
# sidecar. It is bash 3.2 clean so it runs on stock macOS; its awk program is
# POSIX (tested with mawk, gawk --posix and busybox awk) and it never needs
# perl.
#
# USAGE:
#   tools/check-perl-interp.sh FILE...
#   tools/check-perl-interp.sh        # every tracked *.sh file (git ls-files
#                                     # from the repo root; find outside git)
#
# Each finding prints on standard output as
#   FILE:LINE: perl program expands a shell variable: <the trimmed line>
# and a summary line goes to standard error.
#
# Exit status: 0 clean, 1 findings, 2 usage error (a missing, unreadable or
# directory argument, an unknown option) or a file the lint could not read to
# the end.
# =============================================================================

set -u

usage() {
    cat <<'EOF'
usage: tools/check-perl-interp.sh [FILE...]

Report perl programs (-e/-E arguments or an unquoted heredoc program) whose text
expands a shell variable. With no FILE, check every tracked *.sh file from the
repository root. Each finding prints as
  FILE:LINE: perl program expands a shell variable: <the line>
Add "# perl-interp-ok <reason>" to a line of the command to accept it.

Exit status: 0 clean, 1 findings, 2 usage error or unreadable file.
EOF
}

# The scanner. Frame stack st[]: N top level, C inside $( ), <( ), >( ) or
# (( )), B inside backticks (N, C and B are command contexts), D double quotes,
# S single quotes, A $'...' strings. cf[] maps each frame to its command
# context, which owns the word being built (wa/wv/wx/wl: active, value with
# quotes removed, holds an expansion, start line) and the perl command state:
#   ps 0 no perl command, 1 reading perl switches, 2 the next word is an -e
#   program, 3 past the switches (script name, @ARGV data)
# with pl (line of the word perl), pe (an -e was seen), pstd (the program could
# come from stdin), pdd (a -- ended the switches) and pf (a finding is
# pending; it is reported when the command ends, so a marker anywhere on the
# command's lines counts). rt marks that the next word is a redirection target
# (2: a here-string, which phs records when it expands).
# Heredocs queue in hq_*; their bodies start after the next newline that ends a
# command line. Exit status: 0 clean, 1 findings, 3 the file ended inside a
# quote, a substitution or a heredoc.
AWK_PROG='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

function ctx_init(f) {
    wa[f] = 0; wv[f] = ""; wx[f] = 0; wl[f] = 0
    ps[f] = 0; pf[f] = 0; rt[f] = 0; phs[f] = 0
}
function push(kind, depth) {
    sp++; st[sp] = kind; pd[sp] = depth; pa[sp] = 0
    if (kind == "N" || kind == "C" || kind == "B") { cf[sp] = sp; ctx_init(sp) }
    else cf[sp] = cf[sp - 1]
}
function pop() { if (sp > 1) sp-- }

function wstart(f) { if (!wa[f]) { wa[f] = 1; wv[f] = ""; wx[f] = 0; wl[f] = NR } }
function wadd(f, s) { wstart(f); wv[f] = wv[f] s }

# A whole word is complete: feed it to the perl state of its context.
function endword(f) {
    if (!wa[f]) return
    wa[f] = 0
    if (rt[f]) {
        # A here-string feeds stdin, which is the program when there is no -e.
        if (rt[f] == 2 && wx[f] && ps[f] > 0) phs[f] = 1
        rt[f] = 0
        return
    }
    perl_word(f, wv[f], wx[f], wl[f])
}

function perl_word(f, v, x, line,    n, i, c) {
    if (ps[f] == 0) {
        if (!x && (v == "perl" || v ~ /\/perl$/)) {
            ps[f] = 1; pid++; pi[f] = pid; pl[f] = line
            pe[f] = 0; pstd[f] = 1; pdd[f] = 0; pf[f] = 0; phs[f] = 0
        }
        return
    }
    if (ps[f] == 2) {
        if (x) pf[f] = 1
        ps[f] = 1
        return
    }
    if (ps[f] == 3) return
    # ps 1: a switch cluster, --, or the first argument that is not a switch.
    if (!pdd[f] && v == "--") { pdd[f] = 1; return }
    if (pdd[f] || v !~ /^-./) {
        if (!pe[f]) pstd[f] = (v == "-")
        ps[f] = 3
        return
    }
    n = length(v)
    i = 2
    while (i <= n) {
        c = substr(v, i, 1)
        if (c == "e" || c == "E") {
            pe[f] = 1
            if (i < n) { if (x) pf[f] = 1 }
            else ps[f] = 2
            return
        }
        # These switches take the rest of the cluster as their value.
        if (c ~ /[ixFIMmdDCV]/) return
        i++
        if (c == "0") {
            if (substr(v, i, 1) == "x") { i++; while (i <= n && substr(v, i, 1) ~ /[0-9A-Fa-f]/) i++ }
            else while (i <= n && substr(v, i, 1) ~ /[0-7]/) i++
        } else if (c == "l") {
            while (i <= n && substr(v, i, 1) ~ /[0-7]/) i++
        }
    }
}

# The command in context f ends (operator, newline, closing parenthesis).
function endcmd(f,    k, q, txt, t, id) {
    endword(f)
    if (ps[f] > 0) {
        id = pi[f]
        q = 0
        txt = ""
        for (k = pl[f]; k <= NR; k++) {
            if (index(lines[k], MARK)) q = 1
            t = trim(lines[k])
            if (k < NR) sub(/[ \t]*\\$/, "", t)
            txt = (txt == "") ? t : txt " " t
        }
        cmd_std[id] = (!pe[f] && pstd[f])
        cmd_q[id] = q
        if (phs[f] && cmd_std[id]) pf[f] = 1
        if (pf[f] && !q) {
            if (length(txt) > 240) txt = substr(txt, 1, 237) "..."
            printf "%s:%d: perl program expands a shell variable: %s\n", fname, pl[f], txt
            hits++
        }
    }
    ps[f] = 0; pf[f] = 0; rt[f] = 0; phs[f] = 0
}

# One line of a heredoc body: its terminator, a perl program line, or data.
function body(    t, id) {
    t = raw
    if (hq_strip[hq_head]) sub(/^\t+/, "", t)
    if (t == hq_word[hq_head]) { hq_head++; return }
    id = hq_pid[hq_head]
    if (!hq_live[hq_head] || !id || !cmd_std[id] || cmd_q[id]) return
    if (index(raw, MARK)) return
    t = raw
    gsub(/\\\\/, "xx", t)
    gsub(/\\[$`]/, "xx", t)
    if (t ~ /[$][A-Za-z0-9_{(@*#?!$-]/ || index(t, "`")) {
        printf "%s:%d: perl program expands a shell variable: %s\n", fname, NR, trim(raw)
        hits++
    }
}

function scan(    n, i, c, nx, top, f, inar, j, k, d, word, quoted, strip) {
    cont = 0
    n = length(raw)
    i = 1
    while (i <= n) {
        c = substr(raw, i, 1)
        nx = substr(raw, i + 1, 1)
        top = st[sp]
        f = cf[sp]
        if (top == "S") {
            if (c == SQ) pop(); else wadd(f, c)
            i++
            continue
        }
        if (top == "A") {
            if (c == "\\") { wadd(f, c nx); i += 2; continue }
            if (c == SQ) pop(); else wadd(f, c)
            i++
            continue
        }
        if (top == "D") {
            if (c == "\\" && i == n) { cont = 1; i++; continue }
            if (c == "\\") { wadd(f, (nx ~ /[$`"\\]/) ? nx : c nx); i += 2; continue }
            if (c == "\"") { pop(); i++; continue }
            if (c == "$" && nx == "(") {
                wadd(f, "$("); wx[f] = 1
                push("C", 1); pa[sp] = (substr(raw, i + 2, 1) == "(")
                i += 2; continue
            }
            if (c == "$" && nx ~ /[A-Za-z0-9_{@*#?!$-]/) { wadd(f, c nx); wx[f] = 1; i += 2; continue }
            if (c == "`") { wadd(f, c); wx[f] = 1; push("B", 0); i++; continue }
            wadd(f, c)
            i++
            continue
        }
        # Code: N, C or B.
        inar = (top == "C" && pa[sp])
        if (c == "\\" && i == n) { cont = 1; i++; continue }
        if (c == "\\") { wadd(f, nx); i += 2; continue }
        if (c == "#" && !wa[f]) break
        if (c == SQ) { wstart(f); push("S", 0); i++; continue }
        if (c == "\"") { wstart(f); push("D", 0); i++; continue }
        if (c == "$" && nx == SQ) { wstart(f); push("A", 0); i += 2; continue }
        if (c == "$" && nx == "\"") { wstart(f); push("D", 0); i += 2; continue }
        if (c == "$" && nx == "(") {
            wadd(f, "$("); wx[f] = 1
            push("C", 1); pa[sp] = (substr(raw, i + 2, 1) == "(")
            i += 2; continue
        }
        if (c == "$" && nx ~ /[A-Za-z0-9_{@*#?!$-]/) { wadd(f, c nx); wx[f] = 1; i += 2; continue }
        if (c == "`") {
            if (top == "B") { endcmd(f); pop(); i++; continue }
            wadd(f, c); wx[f] = 1; push("B", 0); i++; continue
        }
        if ((c == "<" || c == ">") && nx == "(" && !inar) {
            wadd(f, c "("); wx[f] = 1
            push("C", 1)
            i += 2; continue
        }
        if (c == "(" && nx == "(" && !wa[f] && top != "B") {
            endcmd(f)
            push("C", 2); pa[sp] = 1
            i += 2; continue
        }
        if (c == "(" || c == ")") {
            endcmd(f)
            if (top == "C") {
                if (c == "(") pd[sp]++
                else { pd[sp]--; if (pd[sp] <= 0) pop() }
            }
            i++; continue
        }
        if (c == "<" || c == ">" || (c == "&" && nx == ">")) {
            # 2>file: the digits are a descriptor, not a word.
            if (wa[f] && !wx[f] && wv[f] ~ /^[0-9]+$/) wa[f] = 0
            else endword(f)
            if (inar) { i++; continue }
            if (c == "<" && nx == "<" && substr(raw, i + 2, 1) == "<") { rt[f] = 2; i += 3; continue }
            if (c == "<" && nx == "<") {
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
                    hq_pid[hq_tail] = (ps[f] > 0) ? pi[f] : 0
                }
                i = j
                continue
            }
            j = i + 1
            while (j <= n && substr(raw, j, 1) ~ /[<>&|]/) j++
            rt[f] = 1
            i = j
            continue
        }
        if (c == " " || c == "\t") { endword(f); i++; continue }
        if (c == ";" || c == "&" || c == "|") { endcmd(f); i++; continue }
        wadd(f, c)
        i++
    }
    if (cont) return
    top = st[sp]
    if (top == "S" || top == "D" || top == "A") { wadd(cf[sp], "\n"); return }
    endcmd(cf[sp])
    bodies = 1
}

BEGIN {
    sp = 0
    push("N", 0)
    hq_head = 1; hq_tail = 0
    hits = 0
    pid = 0
    bodies = 0
    fname = ENVIRON["CPI_FILE"]
    MARK = "# perl-interp-ok"
}

{
    raw = $0
    sub(/\r$/, "", raw)
    lines[NR] = raw
    if (bodies && hq_head <= hq_tail) { body(); next }
    bodies = 0
    scan()
}

END {
    if (sp == 1) endcmd(1)
    broken = 0
    if (hq_head <= hq_tail) {
        printf "check-perl-interp: %s: heredoc %s is never closed\n", fname, hq_word[hq_head] > "/dev/stderr"
        broken = 1
    }
    if (sp > 1) {
        printf "check-perl-interp: %s: the file ends inside an open quote or substitution\n", fname > "/dev/stderr"
        broken = 1
    }
    if (broken) exit 3
    exit (hits > 0)
}
'

files=()
if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --) shift ;;
        -*) printf 'check-perl-interp: unknown option %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    if [[ $# -eq 0 ]]; then
        usage >&2
        exit 2
    fi
    # Check every argument before scanning any, so a typo fails fast.
    for f in "$@"; do
        if [[ -d "$f" ]]; then
            printf 'check-perl-interp: %s is a directory; pass the script files instead\n' "$f" >&2
            exit 2
        fi
        if [[ ! -f "$f" || ! -r "$f" ]]; then
            printf 'check-perl-interp: cannot read %s\n' "$f" >&2
            exit 2
        fi
        files+=("$f")
    done
else
    # No arguments: every *.sh file of the repository this tool lives in, with
    # paths relative to its root. Nothing is excluded; use the marker.
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
    cd "$root" || exit 2
    if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        while IFS= read -r -d '' f; do
            if [[ -f "$f" ]]; then files+=("$f"); fi
        done < <(git ls-files -z -- '*.sh')
    else
        while IFS= read -r f; do
            files+=("$f")
        done < <(find . -name .git -prune -o -type f -name '*.sh' -print | LC_ALL=C sort)
    fi
fi

scanned=0
flagged=0
hits=0
unreadable=0
if [[ ${#files[@]} -gt 0 ]]; then
    for f in "${files[@]}"; do
        scanned=$((scanned + 1))
        # The file goes in on stdin and its name through the environment, so awk
        # never treats a name as an assignment or processes backslashes in it.
        out="$(CPI_FILE="$f" LC_ALL=C awk -v SQ="'" "$AWK_PROG" < "$f")"
        rc=$?
        if [[ -n "$out" ]]; then
            printf '%s\n' "$out"
            n="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
            hits=$((hits + n))
            flagged=$((flagged + 1))
        fi
        case "$rc" in
            0) ;;
            1) if [[ -z "$out" ]]; then printf 'check-perl-interp: awk failed on %s\n' "$f" >&2; exit 2; fi ;;
            3) unreadable=$((unreadable + 1)) ;;
            *) printf 'check-perl-interp: awk failed on %s (exit %s)\n' "$f" "$rc" >&2; exit 2 ;;
        esac
    done
fi

if [[ $unreadable -gt 0 ]]; then
    printf 'check-perl-interp: %s finding(s), and %s of %s file(s) could not be read to the end (see above)\n' \
        "$hits" "$unreadable" "$scanned" >&2
    exit 2
fi
if [[ $hits -eq 0 ]]; then
    printf 'check-perl-interp: clean, %s file(s) scanned\n' "$scanned" >&2
    exit 0
fi
printf 'check-perl-interp: %s perl program(s) expanding a shell variable in %s of %s file(s)\n' \
    "$hits" "$flagged" "$scanned" >&2
exit 1
