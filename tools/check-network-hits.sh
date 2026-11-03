#!/usr/bin/env bash
# =============================================================================
# tools/check-network-hits.sh -- flag testnet names and addresses that do not
# say why they are safe on mainnet
#
# The scripts serve testnet (adiri), mainnet and devnet from one tree. A line
# that names the testnet, or one of the testnet add-on hosts, is safe only when
# the code around it is gated on the network: a testnet constant selected by
# NETWORK, a release tag form checked per network, an example printed only on
# testnet. This lint makes each such line say so, so a new testnet endpoint
# cannot reach a mainnet code path without a reviewer reading the reason.
#
# A hit is a line that contains, compared without regard to case:
#   - adiri anywhere (the word, a hostname such as rpc.adiri.tel, a release
#     tag such as v0.16.0-adiri, an image path ending in /adiri)
#   - the hub and monitor addresses of the testnet add-ons, read at run time
#     from lib/testnet-addons.env: the host of OBS_PUSH_URL_TESTNET and of
#     OBS_METRICS_PUSH_URL_TESTNET, the address of TN_WG_HUB_ENDPOINT (without
#     the port) and the address of TN_KUMA_SRC (without the prefix length).
#     The values are read as text, never sourced. A missing or non-literal
#     value is an error (exit 2), so the lint never runs with a pattern missing.
#
# Scanned, relative to the repository root: lib/*.sh (the top level only, so
# the vendored lib/wgvpn/ is not), the *.sh files at the root, ui/server.py,
# ui/telcoin-ui-helper.sh, ui/install-ui.sh, ui/static/index.html and
# observability/config.alloy.
# Everything else is out of scope: common/, tools/, the tests, CHANGELOG*,
# tasks/, followup.md, docs/, every *.md, lib/testnet-addons.env itself and the
# .sha256 sidecars. A named file that is missing is an error (exit 2), so a
# rename cannot drop a file from the scan.
#
# The marker is network-gated: right after a comment opener (#, //, <!-- or
# /*, spaces allowed between), followed by a reason with at least one letter
# or digit; a closing --> or */ is not part of the reason. A hit passes when
#   - the line itself carries the marker (a trailing comment, or a comment
#     line that names adiri and is itself the annotation), or
#   - the line right above it is a marker line: nothing but the comment that
#     holds the marker (a <!-- or /* marker closes on that line, and only
#     blanks follow the --> or */).
# A trailing marker covers its own line only, so a code line's reason never
# vouches for the line after it. The forms:
#     readonly TESTNET_RPC_URL="https://rpc.adiri.tel"  # network-gated: testnet constant, selected by NETWORK
#     # network-gated: testnet release tag form, checked by tn_release_tag_ok per network
#     re="^v${n}\.${n}\.${n}-adiri$"
#     // network-gated: example shown only when NETWORK=testnet
#     <!-- network-gated: status page per network (STATUS_PAGE_LINKS) -->
# A marker line is never reported, even when it names adiri. A marker with an
# empty reason (# network-gated: with nothing after it) covers nothing. Inside
# a JavaScript template literal an HTML marker is part of the rendered page and
# a // is no comment at all: move the testnet text out of the template, onto a
# line below a // marker line. Inside a heredoc a marker is written into the
# file the heredoc makes: reword the line instead.
#
# Blind spots, which review has to cover: a testnet name or address built from
# pieces ("rpc." + name + ".tel"), held in another variable or encoded; an
# address that lib/testnet-addons.env does not name (another node, a new hub);
# the files outside the scope above; and a marker whose reason is not true of
# the line. The addresses are matched as text, so a longer address that
# contains one (1.2.3.45 for 1.2.3.4) is a hit too.
#
# Maintainer tool: update-scripts.sh does not track it and it has no .sha256
# sidecar. It is bash 3.2 clean so it runs on stock macOS, its awk program is
# POSIX (tested with gawk, gawk --posix, mawk and busybox awk), it uses no grep,
# and it never needs git: the file list comes from the paths above, so it also
# runs on a copy of the tree without .git.
#
# USAGE:
#   tools/check-network-hits.sh [--list] [ROOT]
#   ROOT is the repository root; without it, the repository this tool lives in.
#
# Each unannotated hit prints on standard output as
#   FILE:LINE: <the trimmed line>
# with FILE relative to ROOT. With --list, every hit prints, annotated or not, as
#   FILE:LINE: <reason> -- <the trimmed line>
#   FILE:LINE: unannotated -- <the trimmed line>
# A summary line goes to standard error.
#
# Exit status: 0 clean (every hit annotated), 1 unannotated hits, 2 usage error
# (an unknown option, more than one ROOT, a ROOT that is not a directory), a
# scanned file that is missing or unreadable, or a lib/testnet-addons.env value
# the lint cannot read.
# =============================================================================

set -u

usage() {
    cat <<'EOF'
usage: tools/check-network-hits.sh [--list] [ROOT]

Report lines that name the testnet (adiri, compared without case) or a hub or
monitor address of lib/testnet-addons.env without saying why they are safe on
mainnet. Scans lib/*.sh, the root *.sh, ui/server.py, ui/telcoin-ui-helper.sh,
ui/install-ui.sh, ui/static/index.html and observability/config.alloy under
ROOT (default: the repository this tool lives in). Each unannotated hit prints as
  FILE:LINE: <the line>
A hit passes when it carries a marker with a reason, or when the line right
above it is nothing but the marker comment:
  # network-gated: <reason>        (shell, Python)
  // network-gated: <reason>       (JavaScript, Alloy)
  <!-- network-gated: <reason> --> (HTML)
--list prints every hit as FILE:LINE: <reason> -- <the line>, with the reason
"unannotated" for a hit without one.

Exit status: 0 clean, 1 unannotated hits, 2 usage error, a missing or
unreadable file, or a testnet-addons.env value the lint cannot read.
EOF
}

# The scanner: one pass over every file. ENVIRON["CNH_PATS"] holds the address
# patterns, one per line, lower case. For each line it keeps the reason of the
# line above when that line is a marker line (prev), resets it at the first
# line of each file, and reports a hit whose own reason and prev are both
# empty. Its last output line is the
# count "HITS UNANNOTATED".
# shellcheck disable=SC2016
AWK_PROG='
# marker_line S -- 1 when S is nothing but the comment that holds a marker:
# it starts with the marker, and a <!-- or /* comment closes on the line with
# only blanks after it.
function marker_line(s,    r, i) {
    if (!match(s, /^[ \t]*(#|\/\/|<!--|\/\*)[ \t]*network-gated:/)) return 0
    r = substr(s, RSTART + RLENGTH)
    if (s ~ /^[ \t]*<!--/) {
        i = index(r, "-->")
        return (i > 0 && substr(r, i + 3) ~ /^[ \t]*$/)
    }
    if (s ~ /^[ \t]*\/\*/) {
        i = index(r, "*/")
        return (i > 0 && substr(r, i + 2) ~ /^[ \t]*$/)
    }
    return 1
}
function reason_of(s,    r) {
    if (!match(s, /(#|\/\/|<!--|\/\*)[ \t]*network-gated:/)) return ""
    r = substr(s, RSTART + RLENGTH)
    sub(/-->.*$/, "", r)
    sub(/\*\/.*$/, "", r)
    sub(/^[ \t]+/, "", r)
    sub(/[ \t]+$/, "", r)
    if (r !~ /[A-Za-z0-9]/) return ""
    return r
}
BEGIN {
    np = split(ENVIRON["CNH_PATS"], pat, "\n")
    list = ENVIRON["CNH_LIST"] + 0
    hits = 0; bad = 0
}
FNR == 1 { prev = ""; name = FILENAME; sub(/^\.\//, "", name) }
{
    line = $0
    sub(/\r$/, "", line)
    own = reason_of(line)
    low = tolower(line)
    hit = (index(low, "adiri") > 0)
    for (i = 1; !hit && i <= np; i++)
        if (pat[i] != "" && index(low, pat[i]) > 0) hit = 1
    if (hit) {
        hits++
        why = own
        if (why == "") why = prev
        text = line
        sub(/^[ \t]+/, "", text)
        sub(/[ \t]+$/, "", text)
        if (why == "") {
            bad++
            if (list) printf "%s:%d: unannotated -- %s\n", name, FNR, text
            else printf "%s:%d: %s\n", name, FNR, text
        } else if (list) {
            printf "%s:%d: %s -- %s\n", name, FNR, why, text
        }
    }
    prev = ""
    if (own != "" && marker_line(line)) prev = own
}
END {
    printf "%d %d\n", hits, bad
}
'

list=0
root=""
root_set=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --list) list=1 ;;
        --) shift; break ;;
        -*) printf 'check-network-hits: unknown option %s\n' "$1" >&2; usage >&2; exit 2 ;;
        *)
            if [[ $root_set -eq 1 ]]; then
                printf 'check-network-hits: give one ROOT, not %s and %s\n' "$root" "$1" >&2
                exit 2
            fi
            root="$1"
            root_set=1
            ;;
    esac
    shift
done
if [[ $# -gt 0 ]]; then
    if [[ $root_set -eq 1 || $# -gt 1 ]]; then
        printf 'check-network-hits: give one ROOT\n' >&2
        exit 2
    fi
    root="$1"
    root_set=1
fi
if [[ $root_set -eq 0 ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
fi
if [[ ! -d "$root" ]]; then
    printf 'check-network-hits: %s is not a directory; give the repository root\n' "$root" >&2
    exit 2
fi
cd "$root" || exit 2
LC_ALL=C
export LC_ALL

# env_value NAME -- the literal value of NAME in lib/testnet-addons.env (an
# "export NAME=..." or "NAME=..." line; the last one wins, as when sourced),
# with one pair of surrounding quotes and a trailing comment removed. Prints
# nothing when NAME is absent.
env_value() {
    awk -v n="$1" -v SQ="'" '
        {
            s = $0
            sub(/\r$/, "", s)
            sub(/^[ \t]+/, "", s)
            sub(/^export[ \t]+/, "", s)
            if (index(s, n "=") != 1) next
            v = substr(s, length(n) + 2)
            q = substr(v, 1, 1)
            if (q == "\"" || q == SQ) {
                v = substr(v, 2)
                i = index(v, q)
                if (i > 0) v = substr(v, 1, i - 1)
            } else {
                sub(/[ \t]+#.*$/, "", v)
                sub(/[ \t]+$/, "", v)
            }
            val = v; seen = 1
        }
        END { if (seen) print val }
    ' lib/testnet-addons.env
}

# host_of VALUE -- the host or address part of a URL, a host:port endpoint or
# an address/prefix: the scheme, the path or prefix length, a user@ and the
# port go; an [IPv6] endpoint loses its brackets.
host_of() {
    local v="$1"
    v="${v#*://}"
    v="${v%%/*}"
    v="${v%%\?*}"
    v="${v##*@}"
    case "$v" in
        \[*) v="${v#\[}"; v="${v%%]*}" ;;
        *:*:*) ;;
        *:*) v="${v%:*}" ;;
    esac
    printf '%s' "$v"
}

envf="lib/testnet-addons.env"
if [[ ! -f "$envf" || ! -r "$envf" ]]; then
    printf 'check-network-hits: cannot read %s/%s, which names the hub and monitor addresses\n' "$root" "$envf" >&2
    exit 2
fi
nl='
'
pats=""
shown="adiri"
for var in OBS_PUSH_URL_TESTNET OBS_METRICS_PUSH_URL_TESTNET TN_WG_HUB_ENDPOINT TN_KUMA_SRC; do
    val="$(env_value "$var")"
    case "$val" in
        *'$'*|*'`'*)
            printf 'check-network-hits: %s in %s is not a literal value (%s); the lint reads it as text\n' "$var" "$envf" "$val" >&2
            exit 2
            ;;
    esac
    host="$(host_of "$val" | tr '[:upper:]' '[:lower:]')"
    if [[ -z "$host" ]]; then
        printf 'check-network-hits: no %s address in %s; the lint needs it to find the hub and monitor addresses\n' "$var" "$envf" >&2
        exit 2
    fi
    case "$nl$pats" in
        *"$nl$host$nl"*) ;;
        *) pats="${pats}${host}${nl}"; shown="${shown}, ${host}" ;;
    esac
done

files=()
for f in lib/*.sh *.sh ui/server.py ui/telcoin-ui-helper.sh ui/install-ui.sh ui/static/index.html observability/config.alloy; do
    case "$f" in
        'lib/*.sh'|'*.sh') continue ;;
    esac
    if [[ ! -f "$f" ]]; then
        printf 'check-network-hits: %s/%s is missing; the lint scans it by name\n' "$root" "$f" >&2
        exit 2
    fi
    if [[ ! -r "$f" ]]; then
        printf 'check-network-hits: cannot read %s/%s\n' "$root" "$f" >&2
        exit 2
    fi
    files+=("./$f")
done

# The last line of the scanner's output is the count; awk's own errors go to
# standard error and leave no such line.
out="$(CNH_PATS="$pats" CNH_LIST="$list" awk "$AWK_PROG" "${files[@]}")"
rc=$?
counts="${out##*"$nl"}"
report=""
case "$out" in
    *"$nl"*) report="${out%"$nl"*}" ;;
esac
case "$counts" in
    ''|*[!0-9' ']*) ok=0 ;;
    *[0-9]' '[0-9]*) ok=1 ;;
    *) ok=0 ;;
esac
if [[ $rc -ne 0 || $ok -ne 1 ]]; then
    printf 'check-network-hits: the awk scanner failed (exit %s); nothing was checked\n' "$rc" >&2
    exit 2
fi
if [[ -n "$report" ]]; then
    printf '%s\n' "$report"
fi
hits="${counts%% *}"
bad="${counts##* }"
scanned=${#files[@]}
if [[ $list -eq 1 ]]; then
    printf 'check-network-hits: patterns %s\n' "$shown" >&2
fi

if [[ $bad -eq 0 ]]; then
    printf 'check-network-hits: clean, %s annotated hit(s) in %s file(s) scanned\n' "$hits" "$scanned" >&2
    exit 0
fi
printf 'check-network-hits: %s of %s hit(s) in %s file(s) scanned have no network-gated: reason; mark each with "# network-gated: <reason>" (// or <!-- --> in JavaScript, Alloy and HTML) on the line or on a line of its own above\n' \
    "$bad" "$hits" "$scanned" >&2
exit 1
