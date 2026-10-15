#!/usr/bin/env bash
# =============================================================================
# tools/tests/root_write_pipe_test.sh -- no script feeds a root write through a
# pipe
#
#   bash tools/tests/root_write_pipe_test.sh
#
# The right-hand side of a pipe runs in a forked subshell. When a signal ends the
# script (and releases the update lock with it), that subshell carries on and
# finishes its write after the lock is free. So tn_write_root_file,
# write_pending_state and _tn_meta_write take their content from a here-string,
# a here-document or a file, never from `cmd | tn_write_root_file ...`.
#
# Scans the shipped *.sh files (the repo root, lib/, lib/wgvpn/ excluded as
# vendored) for a pipe into one of those writers, on one line or across a line
# that ends in `|` or starts with `|`. Allowed: the two writes of the BLS key
# passphrase file (setup-node.sh step_generate_keys, edit-config.sh
# edit_bls_passphrase): a here-string would put the secret in a temp file under
# bash 3.2. bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO="$TN_TEST_REPO"

# scan FILE... -- print "file:line:function" for each pipe into a root writer.
scan() {
    awk '
        FNR == 1 { fn = ""; prev = "" }
        /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ { fn = $1; sub(/\(\).*/, "", fn) }
        {
            line = $0
            hit = 0
            if (line ~ /^[[:space:]]*#/) { prev = ""; next }
            if (line ~ /\|[[:space:]]*(tn_write_root_file|write_pending_state|_tn_meta_write)([[:space:]]|$)/) hit = 1
            if (prev ~ /\|[[:space:]]*\\?[[:space:]]*$/ && prev !~ /\|\|[[:space:]]*\\?[[:space:]]*$/ \
                && line ~ /^[[:space:]]*(tn_write_root_file|write_pending_state|_tn_meta_write)([[:space:]]|$)/) hit = 1
            if (hit) printf "%s:%d:%s\n", FILENAME, FNR, fn
            prev = line
        }' "$@"
}

ALLOWED="setup-node.sh:step_generate_keys edit-config.sh:edit_bls_passphrase"

# The rule on fixed lines first.
FX="$TN_TEST_TMP/fx.sh"
cat > "$FX" <<'FIX'
a() {
    printf '%s\n' "$x" | tn_write_root_file /etc/a 0644
    printf '%s\n' "$x" \
        | tn_write_root_file /etc/b 0644
    { printf 'x\n'; } |
        write_pending_state
    printf '%s' "$out" | _tn_meta_write /etc/c
    tn_write_root_file /etc/d 0644 <<< "$x"
    tn_write_root_file /etc/e 0644 < /dev/null || true
    false ||
        tn_write_root_file /etc/f 0644 <<< "$x"
    # printf x | tn_write_root_file /etc/g 0644
}
FIX
got="$(scan "$FX" | sed 's/^.*fx\.sh://')"
check "fixture: pipes flagged, here-strings and || not" "$(printf '2:a\n4:a\n6:a\n7:a')" "$got"

files=()
for f in "$REPO"/*.sh "$REPO"/lib/*.sh; do
    [[ -f "$f" ]] && files+=("$f")
done
bad=""
while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    rel="${hit#"$REPO"/}"
    key="${rel%%:*}:${rel##*:}"
    case " $ALLOWED " in
        *" $key "*) continue ;;
    esac
    bad="${bad}${rel}"$'\n'
done <<< "$(scan "${files[@]}")"
check "no pipe into a root writer in the shipped scripts" "" "${bad%$'\n'}"

finish
