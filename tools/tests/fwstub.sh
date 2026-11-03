#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# tools/tests/fwstub.sh -- PATH stubs for the firewall and sshd fixture tests.
#
#   fw_stub_install BIN_DIR    write ufw, sshd, systemctl and nft stubs into BIN_DIR
#
# ufw keeps its state in files under $TN_ROOT_PREFIX, like the real one:
# etc/ufw/user.rules (one normalized rule per line), etc/ufw/ufw.conf
# (ENABLED=yes|no) and etc/default/ufw (DEFAULT_INPUT_POLICY). Every call is
# appended to $UFW_LOG. UFW_FAIL_AT=N makes call N fail; UFW_FAIL_FROM=N makes
# every call from N on fail. `status` prints a ufw-like table.
#
# sshd: `-t` exits $SSHD_T_RC (default 0); `-T` prints the effective value of
# every keyword the fixture sets, first value wins, reading
# etc/ssh/sshd_config.d/*.conf in name order and then etc/ssh/sshd_config, the
# way sshd does when sshd_config starts with the Include line. $SSHD_PORT_LINE
# replaces the "port 22" line. systemctl appends to $SYSTEMCTL_LOG.
#
# nft keeps table inet tn_p2p in $TN_ROOT_PREFIX/.nft.table (the table block of
# the last program it applied; absent when there is no table). Every call appends
# "nft ARGV" to $NFT_LOG (default /dev/null) and, for -f, the program read, each
# line prefixed with "| ". `-f -` or `-f FILE` applies the program as one
# transaction: a program holding `table inet tn_p2p {` leaves exactly that block,
# one that only deletes the table leaves none, and the state file is replaced in
# one rename. `-c` checks only. NFT_FAIL=1 makes -f fail with nothing changed;
# NFT_LIST_FAIL=1 makes `list` fail. NFT_HOLD=1 makes -f wait, after reading the
# program and before applying it, until $TN_ROOT_PREFIX/.nft.release exists
# (it writes its pid to .nft.held first). `list tables` prints `table ip filter`
# and the tn_p2p table when present; `list table inet tn_p2p` prints the block,
# or fails as nft does when it is absent.
# Not updater-tracked. bash 3.2 safe.
# =============================================================================

fw_stub_install() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/ufw" <<'STUB'
#!/usr/bin/env bash
R="${TN_ROOT_PREFIX:?}"
n=0
[ -f "$R/.ufw.n" ] && n="$(cat "$R/.ufw.n")"
n=$((n + 1))
echo "$n" > "$R/.ufw.n"
printf '%s\n' "$*" >> "${UFW_LOG:?}"
if [ -n "${UFW_FAIL_AT:-}" ] && [ "$n" -eq "$UFW_FAIL_AT" ]; then exit 1; fi
if [ -n "${UFW_FAIL_FROM:-}" ] && [ "$n" -ge "$UFW_FAIL_FROM" ]; then exit 1; fi
mkdir -p "$R/etc/ufw" "$R/etc/default"
rules="$R/etc/ufw/user.rules"
touch "$rules"
case "$*" in
    status*)
        if grep -q '^ENABLED=yes' "$R/etc/ufw/ufw.conf" 2>/dev/null; then
            echo "Status: active"
            echo ""
            while IFS= read -r r; do
                case "$r" in
                    "allow from "*)
                        set -- $r
                        printf '%s/%s ALLOW %s\n' "$7" "$9" "$3" ;;
                    "allow "*) printf '%s ALLOW Anywhere\n' "${r#allow }" ;;
                esac
            done < "$rules"
        else
            echo "Status: inactive"
        fi ;;
    "--force reset") : > "$rules"; echo "ENABLED=no" > "$R/etc/ufw/ufw.conf" ;;
    "--force enable") echo "ENABLED=yes" > "$R/etc/ufw/ufw.conf" ;;
    "--force disable"|disable) echo "ENABLED=no" > "$R/etc/ufw/ufw.conf" ;;
    "default deny incoming") echo 'DEFAULT_INPUT_POLICY="DROP"' > "$R/etc/default/ufw" ;;
    "default allow outgoing") : ;;
    "delete "*)
        # ${*#...} would strip each word, not the joined line: join first.
        r="$*"
        r="${r#delete }"
        grep -vxF -- "$r" "$rules" > "$rules.tmp"; mv "$rules.tmp" "$rules" ;;
    allow*|limit*)
        grep -qxF -- "$*" "$rules" || printf '%s\n' "$*" >> "$rules" ;;
esac
exit 0
STUB
    cat > "$bin/sshd" <<'STUB'
#!/usr/bin/env bash
R="${TN_ROOT_PREFIX:?}"
case "$1" in
    -t) exit "${SSHD_T_RC:-0}" ;;
    -T)
        echo "${SSHD_PORT_LINE:-port 22}"
        files=""
        for f in "$R"/etc/ssh/sshd_config.d/*.conf; do [ -f "$f" ] && files="$files $f"; done
        # shellcheck disable=SC2086
        cat $files "$R/etc/ssh/sshd_config" 2>/dev/null \
            | awk 'NF >= 2 && $1 !~ /^#/ && tolower($1) != "include" && tolower($1) != "port" {
                       k = tolower($1); if (!(k in seen)) { seen[k] = 1; print k, $2 } }'
        ;;
esac
exit 0
STUB
    cat > "$bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:-/dev/null}"
exit 0
STUB
    cat > "$bin/nft" <<'STUB'
#!/usr/bin/env bash
R="${TN_ROOT_PREFIX:?}"
log="${NFT_LOG:-/dev/null}"
st="$R/.nft.table"
printf 'nft %s\n' "$*" >> "$log"
check=false
file=""
while [ $# -gt 0 ]; do
    case "$1" in
        -c|--check) check=true; shift ;;
        -f|--file) file="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
        list)
            [ -n "${NFT_LIST_FAIL:-}" ] && { echo "Error: Operation not permitted" >&2; exit 1; }
            if [ "${2:-}" = tables ]; then
                echo "table ip filter"
                [ -f "$st" ] && echo "table inet tn_p2p"
                exit 0
            fi
            if [ "${2:-} ${3:-} ${4:-}" = "table inet tn_p2p" ]; then
                [ -f "$st" ] && { cat "$st"; exit 0; }
                echo "Error: No such file or directory" >&2
                exit 1
            fi
            echo "nft stub: unsupported list $*" >&2
            exit 1 ;;
        *) echo "nft stub: unsupported argument $1" >&2; exit 1 ;;
    esac
done
[ -n "$file" ] || { echo "nft stub: nothing to do" >&2; exit 1; }
if [ "$file" = "-" ]; then
    prog="$(cat)"
else
    prog="$(cat "$file")" || exit 1
fi
printf '%s\n' "$prog" | sed 's/^/| /' >> "$log"
if [ -n "${NFT_FAIL:-}" ]; then
    echo "Error: Could not process rule: Operation not supported" >&2
    exit 1
fi
[ "$check" = true ] && exit 0
if [ -n "${NFT_HOLD:-}" ]; then
    echo "$$" > "$R/.nft.held"
    while [ ! -e "$R/.nft.release" ]; do sleep 0.1; done
fi
block="$(printf '%s\n' "$prog" | awk '/^table inet tn_p2p \{/ { on = 1 } on { print }')"
if [ -n "$block" ]; then
    printf '%s\n' "$block" > "$st.tmp" && mv "$st.tmp" "$st"
elif printf '%s\n' "$prog" | grep -qx 'delete table inet tn_p2p'; then
    rm -f "$st"
fi
exit 0
STUB
    chmod +x "$bin/ufw" "$bin/sshd" "$bin/systemctl" "$bin/nft"
}
