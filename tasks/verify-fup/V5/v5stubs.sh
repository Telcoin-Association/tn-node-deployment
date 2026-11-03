#!/usr/bin/env bash
# shellcheck shell=bash
# tasks/verify-fup/V5/v5stubs.sh -- V5's own PATH stubs (nft, systemctl, a ufw
# wrapper) and fixture overrides for the FW checks. ufw and sshd come from
# tools/tests/fwstub.sh (installed into FWBIN); the ufw wrapper here logs each
# call to V5_SEQ (one ordered log of ufw, nft and systemctl calls) and then runs
# the fwstub ufw by absolute path.
#
# nft: table inet tn_p2p is $TN_ROOT_PREFIX/.v5nft.table (the last program's
# table block). V5_NFT_FAIL=1 refuses a program that writes the table,
# V5_NFT_DEL_FAIL=1 one that only deletes it, V5_NFT_LIST_FAIL=1 every list.
# V5_NFT_HOLD_TAG=X with V5_TAG=X: after applying a write, wait until
# $TN_ROOT_PREFIX/.release.X exists (pid in .held.X first).
# systemctl: enabled units in $TN_ROOT_PREFIX/.v5sc.enabled; V5_SC_FAIL=enable
# makes enable fail; V5_SC_ABSENT=1 makes every call rc 127 ("not found").
# bash 3.2 safe.

v5_stubs_install() {
    local bin="$1" fwbin="$2"
    mkdir -p "$bin"
    cat > "$bin/ufw" <<V5S
#!/usr/bin/env bash
printf 'ufw %s\n' "\$*" >> "\${V5_SEQ:-/dev/null}"
exec "${fwbin}/ufw" "\$@"
V5S
    cat > "$bin/sshd" <<V5S
#!/usr/bin/env bash
exec "${fwbin}/sshd" "\$@"
V5S
    cat > "$bin/systemctl" <<'V5S'
#!/usr/bin/env bash
if [ -n "${V5_SC_ABSENT:-}" ]; then echo "systemctl: command not found" >&2; exit 127; fi
printf 'systemctl %s\n' "$*" >> "${V5_SEQ:-/dev/null}"
printf '%s\n' "$*" >> "${V5_SC_LOG:-/dev/null}"
en="${TN_ROOT_PREFIX:?}/.v5sc.enabled"
touch "$en"
case "${1:-}" in
    enable)
        [ "${V5_SC_FAIL:-}" = enable ] && exit 1
        shift
        for u in "$@"; do grep -qxF -- "$u" "$en" || printf '%s\n' "$u" >> "$en"; done ;;
    disable)
        shift; [ "${1:-}" = --now ] && shift
        for u in "$@"; do grep -vxF -- "$u" "$en" > "$en.tmp"; mv "$en.tmp" "$en"; done ;;
    is-enabled)
        shift; [ "${1:-}" = --quiet ] && shift
        if grep -qxF -- "${1:-}" "$en"; then echo enabled; exit 0; fi
        echo disabled; exit 1 ;;
esac
exit 0
V5S
    cat > "$bin/nft" <<'V5S'
#!/usr/bin/env bash
R="${TN_ROOT_PREFIX:?}"
st="$R/.v5nft.table"
printf 'nft %s\n' "$*" >> "${V5_NFT_LOG:-/dev/null}"
printf 'nft %s\n' "$*" >> "${V5_SEQ:-/dev/null}"
check=false file=""
case "$*" in
    "list tables")
        [ -n "${V5_NFT_LIST_FAIL:-}" ] && { echo "Error: Operation not permitted" >&2; exit 1; }
        echo "table ip filter"; echo "table ip6 filter"
        [ -f "$st" ] && echo "table inet tn_p2p"
        exit 0 ;;
    "list table inet tn_p2p")
        [ -n "${V5_NFT_LIST_FAIL:-}" ] && exit 1
        [ -f "$st" ] && { cat "$st"; exit 0; }
        echo "Error: No such file or directory" >&2; exit 1 ;;
    "delete table inet tn_p2p")
        [ -f "$st" ] || { echo "Error: No such file or directory" >&2; exit 1; }
        rm -f "$st"; exit 0 ;;
    "-f -") file="-" ;;
    "-c -f -") check=true; file="-" ;;
    "-f "*) file="${2:-}" ;;
    *) echo "v5 nft stub: unsupported: $*" >&2; exit 1 ;;
esac
if [ "$file" = "-" ]; then prog="$(cat)"; else prog="$(cat "$file")" || exit 1; fi
printf '%s\n' "$prog" | sed 's/^/| /' >> "${V5_NFT_LOG:-/dev/null}"
block="$(printf '%s\n' "$prog" | awk '/^table inet tn_p2p \{/ { on = 1 } on { print }')"
if [ -n "$block" ] && [ -n "${V5_NFT_FAIL:-}" ]; then
    echo "Error: Could not process rule: Operation not supported" >&2; exit 1
fi
if [ -z "$block" ] && [ -n "${V5_NFT_DEL_FAIL:-}" ]; then
    echo "Error: Could not process rule: Device or resource busy" >&2; exit 1
fi
[ "$check" = true ] && exit 0
if [ -n "$block" ]; then
    printf '%s\n' "$block" > "$st.tmp" && mv "$st.tmp" "$st"
    if [ -n "${V5_NFT_HOLD_TAG:-}" ] && [ "${V5_NFT_HOLD_TAG}" = "${V5_TAG:-}" ]; then
        echo "$$" > "$R/.held.${V5_TAG}"
        n=0
        while [ ! -e "$R/.release.${V5_TAG}" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
    fi
elif printf '%s\n' "$prog" | grep -qx 'delete table inet tn_p2p'; then
    rm -f "$st"
fi
exit 0
V5S
    chmod +x "$bin/ufw" "$bin/sshd" "$bin/systemctl" "$bin/nft"
}

# v5_overrides_text -- the fixture overrides, sourced after firewall-setup.sh by
# the test and by the driver: one node with the ports in V5_PORTS (default the
# two), V5_NODES (default telcoin.service), no Caddy, no VPN, not on GCE, and
# tn_write_root_file into the fixture unless V5_REAL_WRITER=1 (root, with a
# prefix tn_root_dir_ok accepts: the library's writer runs for real).
v5_overrides_text() {
    cat <<'V5O'
detect_installed_nodes() { echo "${V5_NODES:-telcoin.service}"; }
tn_resolve_service() { [[ "${V5_NODES:-telcoin.service}" != none ]] || return 1; echo telcoin; }
fw_p2p_ports() { printf '%b' "${V5_PORTS:-49590 primary\n49594 worker-0\n}"; }
caddy_serves_public_edge() { return 1; }
fw_on_gce() { return 1; }
ip() { return 1; }
if [[ "${V5_REAL_WRITER:-0}" != "1" ]]; then
tn_write_root_file() {
    printf '%s %s\n' "$1" "$2" >> "${V5_WRITES:-/dev/null}"
    if [[ -n "${V5_WRITE_FAIL:-}" && "$1" == "$V5_WRITE_FAIL" ]]; then
        cat > /dev/null
        return 2
    fi
    mkdir -p "${1%/*}"
    cat > "$1"
    chmod "$2" "$1"
}
else
eval "_v5_real_$(declare -f tn_write_root_file)"
tn_write_root_file() {
    printf '%s %s\n' "$1" "$2" >> "${V5_WRITES:-/dev/null}"
    if [[ -n "${V5_WRITE_FAIL:-}" && "$1" == "$V5_WRITE_FAIL" ]]; then
        cat > /dev/null
        return 2
    fi
    _v5_real_tn_write_root_file "$@"
}
fi
V5O
}

# check_sub <name> <substring> <text> -- <text> contains <substring> anywhere
# (tools/tests/lib.sh check_has wants a whole line). Counts in the caller's shell.
check_sub() {
    CHECKS=$((CHECKS + 1))
    if printf '%s\n' "$3" | grep -qF -- "$2"; then
        printf 'ok    %s\n' "$1"
        return 0
    fi
    FAILS=$((FAILS + 1))
    printf 'FAIL  %s\n      missing: %s\n      in:\n' "$1" "$2"
    printf '%s\n' "$3" | sed 's/^/        /' | head -n 40
    return 1
}
