#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# tools/tests/fwstub.sh -- PATH stubs for the firewall and sshd fixture tests.
#
#   fw_stub_install BIN_DIR    write ufw, sshd and systemctl stubs into BIN_DIR
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
    chmod +x "$bin/ufw" "$bin/sshd" "$bin/systemctl"
}
