#!/usr/bin/env bash
# =============================================================================
# tools/tests/passphrase_print_test.sh -- no script prints a passphrase variable
#
#   bash tools/tests/passphrase_print_test.sh
#
# Flags any echo or printf, in command position, whose arguments expand
# TN_BLS_PASSPHRASE, TN_SETUP_PASS or TN_KEYTOOL_PASS ($NAME or ${NAME...},
# escaped \$NAME in generated scripts included), in every tracked *.sh file
# outside tools/tests/ (test fixtures and recorders are not shipped).
#
# Exceptions (not flagged):
#   - the output is piped into a command's standard input:
#       printf '%s\n' "$TN_KEYTOOL_PASS" | "$bin" keytool --bls-passphrase-source stdin
#     unless that command is tee, cat, logger, echo, printf or xargs, which
#     would print or copy the value onward;
#   - a line carrying the marker "# passphrase-stdin-ok REASON" (REASON not
#     empty) whose code is one printf '%s' or '%s\n' of the bare variable to
#     standard output, with no redirection other than 2>/dev/null, no command
#     substitution, no echo/tee/cat/logger/xargs and no second expansion of a
#     passphrase name. It is for a feed function whose standard output the
#     caller pipes into the consumer (lib/common.sh _tn_feed_pass);
#   - comment lines;
#   - a read -s prompt never expands the variable, so it never matches;
#   - names that merely start with one of these (TN_SETUP_PASSPHRASE_METHOD).
# Still flagged: redirection to a file or stderr, command substitution, a
# `||` after the value, and a marked line of any other shape. Feed the secret
# to stdin of the consumer, or to tn_write_root_file.
#
# The test first checks the rule on fixed lines, then scans the tree. CI runs
# it in the hardening-lint job; tools/tests/run.sh runs it too. bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
REPO="$TN_TEST_REPO"

# passphrase_print_lint FILE... -- print "file:line: text" for each violation.
passphrase_print_lint() {
    awk -v q="'" '
        # The marker exception: one printf of the bare value, to stdout only.
        function marked_ok(s,    i, code, re, tmp) {
            i = index(s, "# passphrase-stdin-ok ")
            if (i == 0) return 0
            if (substr(s, i + 22) !~ /[^[:space:]]/) return 0
            code = substr(s, 1, i - 1)
            re = "printf[[:space:]]+" q "%s(\\\\n)?" q "[[:space:]]+\"\\$\\{?(TN_BLS_PASSPHRASE|TN_SETUP_PASS|TN_KEYTOOL_PASS)\\}?\""
            if (code !~ re) return 0
            tmp = code
            if (gsub(/printf/, "", tmp) != 1) return 0
            tmp = code
            if (gsub(/(TN_BLS_PASSPHRASE|TN_SETUP_PASS|TN_KEYTOOL_PASS)/, "", tmp) != 1) return 0
            gsub(/2>\/dev\/null/, "", code)
            if (code ~ /[>`]|\$\(|(^|[^A-Za-z0-9_])(echo|tee|cat|logger|xargs)([^A-Za-z0-9_]|$)/) return 0
            return 1
        }
        function flag(s,    pre, rest, m, cmd) {
            # echo/printf in command position, later expanding a passphrase name.
            if (s !~ /(^|[;&|({`]|\$\(|[[:space:]](then|do|else))[[:space:]]*(echo|printf)[[:space:]]/) return 0
            if (!match(s, /\\?\$\{?(TN_BLS_PASSPHRASE|TN_SETUP_PASS|TN_KEYTOOL_PASS)([^A-Za-z0-9_]|$)/)) return 0
            rest = substr(s, RSTART + RLENGTH - 1)
            # A single | (not ||) after the value, into a command that consumes it.
            while (match(rest, /\|/)) {
                pre = substr(rest, RSTART - 1, 1)
                m = substr(rest, RSTART + 1)
                rest = m
                if (substr(m, 1, 1) == "|") { rest = substr(m, 2); continue }
                if (pre == "|") continue
                sub(/^[[:space:]]*/, "", m)
                cmd = m
                sub(/[^A-Za-z0-9_.\/"$-].*$/, "", cmd)
                gsub(/"/, "", cmd)
                sub(/^.*\//, "", cmd)
                if (cmd == "tee" || cmd == "cat" || cmd == "logger" || cmd == "echo" || cmd == "printf" || cmd == "xargs" || cmd == "") return 1
                return 0
            }
            return 1
        }
        FNR == 1 { buf = ""; start = 0 }
        {
            line = $0
            if (buf == "") start = FNR
            if (line ~ /\\$/) { buf = buf substr(line, 1, length(line) - 1) " "; next }
            s = buf line
            buf = ""
            if (s ~ /^[[:space:]]*#/) next
            if (flag(s) && !marked_ok(s)) print FILENAME ":" start ": " s
        }
    ' "$@"
}

# --- the rule on fixed lines ------------------------------------------------------
cat > "$T/bad.sh" <<'EOF'
echo "$TN_BLS_PASSPHRASE"
printf '%s\n' "${TN_SETUP_PASS}" > "$f"
echo "pass=$TN_KEYTOOL_PASS" >&2
printf '%s' "$TN_BLS_PASSPHRASE" | tee /tmp/x
x="$(printf '%s' "$TN_KEYTOOL_PASS")"
[ -n "$a" ] && echo "$TN_SETUP_PASS"
printf '%s' "$TN_BLS_PASSPHRASE" || true
if true; then echo "${TN_SETUP_PASS:-}"; fi
printf '%s\n' \
    "$TN_KEYTOOL_PASS"
printf '%s' "\$TN_BLS_PASSPHRASE" | cat
printf '%s' "$TN_BLS_PASSPHRASE" | /usr/bin/logger
printf '%s\n' "$TN_KEYTOOL_PASS" > "$f"  # passphrase-stdin-ok to a file
echo "$TN_KEYTOOL_PASS"  # passphrase-stdin-ok echo
printf '%s\n' "$TN_KEYTOOL_PASS"  # passphrase-stdin-ok   
x="$(printf '%s' "$TN_KEYTOOL_PASS")"  # passphrase-stdin-ok capture
printf 'pass=%s\n' "$TN_KEYTOOL_PASS"  # passphrase-stdin-ok format
printf '%s\n' "$TN_KEYTOOL_PASS" >&2  # passphrase-stdin-ok stderr
printf '%s\n' "$TN_KEYTOOL_PASS"; printf '%s' "$TN_SETUP_PASS"  # passphrase-stdin-ok two
printf '%s\n' "$TN_KEYTOOL_PASS" | tee /tmp/x  # passphrase-stdin-ok tee
EOF
cat > "$T/good.sh" <<'EOF'
printf '%s\n' "$TN_KEYTOOL_PASS" | "$bin" keytool --bls-passphrase-source stdin
# echo "$TN_BLS_PASSPHRASE"
read -rs TN_SETUP_PASS; echo
echo "TN_SETUP_PASSPHRASE_METHOD=$TN_SETUP_PASSPHRASE_METHOD"
printf '%s' "$TN_SETUP_PASS" | tn_write_root_file /etc/telcoin/x 0600
echo "set TN_BLS_PASSPHRASE first"
printf '%s\n' "\$TN_BLS_PASSPHRASE" | exec /usr/local/bin/telcoin-network node
printf '%s' "$TN_BLS_PASSPHRASE" | systemd-creds encrypt --name=bls - out.cred
unset TN_BLS_PASSPHRASE
    ( trap '' PIPE; printf '%s\n' "$TN_KEYTOOL_PASS" ) 2>/dev/null || true  # passphrase-stdin-ok feed: the caller pipes stdout to keytool
printf '%s' "${TN_SETUP_PASS}"  # passphrase-stdin-ok the caller pipes this function into the consumer
EOF
bad_hits="$(passphrase_print_lint "$T/bad.sh" | sed 's|^.*/bad.sh:||' | cut -d: -f1 | tr '\n' ' ')"
check "rule: every bad line flagged" "1 2 3 4 5 6 7 8 9 11 12 13 14 15 16 17 18 19 20 " "$bad_hits"
check "rule: no good line flagged" "" "$(passphrase_print_lint "$T/good.sh")"

# --- the tree ------------------------------------------------------------------------
files=()
if command -v git >/dev/null 2>&1 && git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r f; do
        files+=("$REPO/$f")
    done < <(git -C "$REPO" ls-files '*.sh' | grep -v '^tools/tests/')
else
    while IFS= read -r f; do
        files+=("$f")
    done < <(find "$REPO" -name '*.sh' -type f ! -path '*/.git/*' ! -path "$REPO/tools/tests/*" | LC_ALL=C sort)
fi
check "tree: scripts found" "yes" "$([[ ${#files[@]} -gt 10 ]] && echo yes || echo no)"
check "tree: no script prints a passphrase variable" "" "$(passphrase_print_lint "${files[@]}" | sed "s|^${REPO}/||")"

finish
