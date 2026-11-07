#!/usr/bin/env bash
# =============================================================================
# tools/tests/host_baseline_test.sh -- the opt-in host baseline (#43): auditd
# watches and an AIDE baseline of the node's files.
#
#   lib/common.sh  tn_host_baseline_install, _refresh, _remove, _status and the
#                  lines tn_host_audit gains; a failed install leaves nothing;
#   setup-node.sh  --host-baseline (full setup, --json finalize and the
#                  baseline-only run on an installed node);
#   update-node.sh the refresh after a successful apply, never after a failed one;
#   edit-config.sh the refresh after a successful --set restart and menu restart;
#   remove-node.sh the teardown when the last node unit goes, none while
#                  another node unit remains (menu path and each --json scope);
#   install-caddy.sh, firewall-setup.sh, setup-vpn.sh, setup-observability.sh
#                  the refresh after an add-on change that went through.
#
#   bash tools/tests/host_baseline_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/host_baseline_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/host_baseline_test.sh
#
# apt-get, augenrules, auditctl and aide are stand-ins on PATH that record their
# arguments and make the files the real tools make, with the argument shapes
# checked against auditd 3.1.2 and aide 0.18.6 on Ubuntu 24.04: aide
# --config=FILE --init|--update writes database_out, --update without
# database_in exits 18 and leaves a partial database_out, exit 1 to 7 reports
# differences. As root (with GNU mv -T) the real root writers run and the modes
# are read back; as any other user tn_write_root_file is a recording stand-in.
# Maintainer tooling (not updater-tracked). bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
RB=""
trap 'tn_test_cleanup; if [[ -n "$RB" ]]; then rm -rf "${RB:?}"; fi' EXIT

eval "$(tn_test_source_common)"

IS_ROOT=0
[[ "$(id -u)" == 0 ]] && IS_ROOT=1
: > "$T/probe1"
HAVE_MV_T=0
"$(type -P mv)" -f -T -- "$T/probe1" "$T/probe2" 2>/dev/null && HAVE_MV_T=1
ROOT_OK=0
if [[ $IS_ROOT == 1 && $HAVE_MV_T == 1 ]]; then
    RB="$(mktemp -d /root/.tn-test.XXXXXX 2>/dev/null)" || RB=""
    if [[ -n "$RB" ]]; then
        chmod 0700 "$RB"
        if tn_root_dir_ok "$RB"; then
            ROOT_OK=1
        else
            rm -rf "${RB:?}"
            RB=""
        fi
    fi
fi
if [[ $ROOT_OK == 1 ]]; then
    FX="$RB/fx"
else
    FX="$T/fx"
fi
umask 022

# --- stand-ins on PATH ----------------------------------------------------------
HB_T="$T/state"
HB_LOG="$T/argv.log"
mkdir -p "$T/bin" "$HB_T"
export HB_T HB_LOG
cat > "$T/bin/apt-get" <<'STUB'
#!/bin/sh
printf 'apt-get %s\n' "$*" >> "$HB_LOG"
case "$*" in
    *install*) exit "$(cat "$HB_T/apt.rc" 2>/dev/null || echo 0)" ;;
esac
exit 0
STUB
cat > "$T/bin/augenrules" <<'STUB'
#!/bin/sh
printf 'augenrules %s\n' "$*" >> "$HB_LOG"
rc="$(cat "$HB_T/augenrules.rc" 2>/dev/null || echo 0)"
if [ "$1" = --load ] && [ "$rc" = 0 ]; then
    cat "${TN_ROOT_PREFIX}"/etc/audit/rules.d/*.rules > "$HB_T/kernel.rules" 2>/dev/null || : > "$HB_T/kernel.rules"
fi
exit "$rc"
STUB
cat > "$T/bin/auditctl" <<'STUB'
#!/bin/sh
printf 'auditctl %s\n' "$*" >> "$HB_LOG"
[ "$1" = -l ] && cat "$HB_T/kernel.rules" 2>/dev/null
[ "$1" = -W ] && exit "$(cat "$HB_T/auditctl.rc" 2>/dev/null || echo 0)"
exit 0
STUB
cat > "$T/bin/aide" <<'STUB'
#!/bin/sh
printf 'aide %s\n' "$*" >> "$HB_LOG"
conf="" mode=""
for a in "$@"; do
    case "$a" in
        --config=*) conf="${a#--config=}" ;;
        --init|--update|--check) mode="${a#--}" ;;
    esac
done
out="$(sed -n 's/^database_out=file://p' "$conf" 2>/dev/null)"
in="$(sed -n 's/^database_in=file://p' "$conf" 2>/dev/null)"
rc="$(cat "$HB_T/aide.rc" 2>/dev/null || echo 0)"
case "$mode" in
    init) printf 'db init\n' > "${TN_ROOT_PREFIX}${out}" ;;
    update)
        if [ ! -f "${TN_ROOT_PREFIX}${in}" ]; then
            printf 'partial\n' > "${TN_ROOT_PREFIX}${out}"
            printf '  ERROR: open (read-only) failed for file %s\n' "$in" >&2
            exit 18
        fi
        printf 'db update\n' > "${TN_ROOT_PREFIX}${out}" ;;
esac
[ "$rc" -le 7 ] || printf '  ERROR: stub aide failed\n' >&2
exit "$rc"
STUB
chmod 0755 "$T/bin/"*
PATH="$T/bin:$PATH"

TN_ROOT_PREFIX="$FX"
export TN_ROOT_PREFIX
WRITES="$T/writes.log"
if [[ $ROOT_OK != 1 ]]; then
    # Any user: record the destination and mode, write the content.
    tn_write_root_file() {
        if [[ -n "${HB_WRITE_REFUSE:-}" && "${1#"$FX"}" == "$HB_WRITE_REFUSE" ]]; then
            cat > /dev/null
            return 1
        fi
        printf '%s %s\n' "${1#"$FX"}" "$2" >> "$WRITES"
        cat > "$1"
    }
    cat > "$T/bin/install" <<'STUB'
#!/bin/sh
printf 'install %s\n' "$*" >> "$HB_LOG"
m="" prev="" last=""
for a in "$@"; do
    [ "$prev" = -m ] && m="$a"
    prev="$a"
    last="$a"
done
mkdir -p "$last" && { [ -z "$m" ] || chmod "$m" "$last"; }
STUB
    chmod 0755 "$T/bin/install"
fi
if [[ $ROOT_OK != 1 ]]; then
    # The fixture tree is not root-owned here: the ownership check of /var/lib/aide
    # and the database runs for real only as root (the cases below).
    _tn_hb_db_dir_ok() { return 0; }
fi

RULES="$FX/etc/audit/rules.d/telcoin-node.rules"
ACONF="$FX/etc/aide/telcoin-node.conf"
ADB="$FX/var/lib/aide/telcoin-node.db"
META="$FX/etc/telcoin/.node-meta"
UNIT="$FX/etc/systemd/system/telcoin.service"

fixture() {  # fixture -- a fresh node install under FX, no baseline
    rm -rf "${FX:?}"
    mkdir -p "$FX/etc/telcoin" "$FX/etc/systemd/system" "$FX/var/lib/telcoin/node-keys" \
        "$FX/etc/audit/rules.d" "$FX/opt/telcoin" "$FX/usr/local/libexec/telcoin"
    printf 'NETWORK=testnet\nDATA_DIR=/var/lib/telcoin\nINSTALL_METHOD=release\nBINARY_PATH=/opt/telcoin/telcoin-network\n' > "$META"
    chmod 0600 "$META"
    printf '[Service]\nExecStart=/usr/local/libexec/telcoin/tn-start\n' > "$UNIT"
    rm -f "${HB_T:?}"/* "${HB_LOG:?}" "${WRITES:?}"
}
mode_of() { stat -c '%U %a' -- "$1" 2>/dev/null; }
yn() { if "$@"; then echo yes; else echo no; fi; }
said() { grep -q -- "$1" "$T/say.log" 2>/dev/null && echo yes || echo no; }
say_log() { printf '%s|%s\n' "$1" "$2" >> "$T/say.log"; }

# =============================================================================
# tn_host_baseline_install
# =============================================================================
fixture
: > "$T/say.log"
rc=0; tn_host_baseline_install say_log > "$T/out" 2>&1 || rc=$?
check_rc "install: rc 0" 0 "$rc"
check_has "install: apt-get without recommended packages" \
    "apt-get install -y -q --no-install-recommends auditd aide" "$(cat "$HB_LOG")"
check "install: rules file" "## Telcoin node host baseline (setup-node.sh --host-baseline); remove-node.sh removes this file.
-w /var/lib/telcoin/node-keys -p rwxa -k telcoin-keys
-w /etc/telcoin -p wa -k telcoin-config
-w /etc/systemd/system/telcoin.service -p wa -k telcoin-unit" "$(cat "$RULES" 2>/dev/null)"
check_has "install: rules loaded with augenrules --load" "augenrules --load" "$(cat "$HB_LOG")"
check "install: the AIDE baseline first, the audit rules last" "aide --config=${FX}/etc/aide/telcoin-node.conf --init
augenrules --load" "$(grep -E '^(aide|augenrules) ' "$HB_LOG")"
check_has "install: aide init with the node config" "aide --config=${FX}/etc/aide/telcoin-node.conf --init" "$(cat "$HB_LOG")"
check_lacks "install: aideinit (the whole-system init) never runs" "aideinit" "$(cat "$HB_LOG")"
AC="$(cat "$ACONF" 2>/dev/null)"
check_has "install: aide config reads its own database" "database_in=file:/var/lib/aide/telcoin-node.db" "$AC"
check_has "install: aide config writes its own new database" "database_out=file:/var/lib/aide/telcoin-node.db.new" "$AC"
check_has "install: install dir, anchored" '/opt/telcoin(/|$) TnNode' "$AC"
check_has "install: start scripts, anchored" '/usr/local/libexec/telcoin(/|$) TnNode' "$AC"
check_has "install: config dir, anchored" '/etc/telcoin(/|$) TnNode' "$AC"
check_has "install: the unit alone" '=/etc/systemd/system/telcoin\.service$ TnNode' "$AC"
check_has "install: passphrase file and credential left out" '!/etc/telcoin/(.*/)?bls-passphrase(\.cred)?(\.new)?$' "$AC"
check_has "install: ingest token left out" '!/etc/telcoin/alloy/ingest-token$' "$AC"
check_lacks "install: a binary inside /opt/telcoin gets no rule of its own" "telcoin-network" "$AC"
check_lacks "install: no whole-system include" "@@x_include" "$AC"
check "install: database in place, no new file left" "db init no" \
    "$(cat "$ADB" 2>/dev/null) $(yn test -e "${ADB}.new")"
check "install: HOST_BASELINE=true" "true" "$(meta_get HOST_BASELINE "$META")"
if [[ $ROOT_OK == 1 ]]; then
    check "install: rules root 0640" "root 640" "$(mode_of "$RULES")"
    check "install: aide config root 0600" "root 600" "$(mode_of "$ACONF")"
    check "install: /etc/aide made root 0755" "root 755" "$(mode_of "$FX/etc/aide")"
    check "install: /var/lib/aide made root 0700" "root 700" "$(mode_of "$FX/var/lib/aide")"
    check "install: .node-meta stays root 0600" "root 600" "$(mode_of "$META")"
else
    check_has "install: rules written 0640" "/etc/audit/rules.d/telcoin-node.rules 0640" "$(cat "$WRITES")"
    check_has "install: aide config written 0600" "/etc/aide/telcoin-node.conf 0600" "$(cat "$WRITES")"
    check_has "install: /etc/aide made root 0755" "install -d -o root -g root -m 0755 -- ${FX}/etc/aide" "$(cat "$HB_LOG")"
    check_has "install: /var/lib/aide made root 0700" "install -d -o root -g root -m 0700 -- ${FX}/var/lib/aide" "$(cat "$HB_LOG")"
fi
check_has "install: says how to check the baseline" \
    "log|AIDE baseline made: /var/lib/aide/telcoin-node.db. Check the node's files against it with: sudo aide --config=/etc/aide/telcoin-node.conf --check" "$(cat "$T/say.log")"
check "install: no warning" no "$(said '^warn|')"

# A second run writes the same files and makes the baseline again.
cp "$RULES" "$T/rules1"; cp "$ACONF" "$T/aconf1"
: > "$HB_LOG"
rc=0; tn_host_baseline_install say_log > /dev/null 2>&1 || rc=$?
check_rc "install again: rc 0" 0 "$rc"
check "install again: same rules" "$(cat "$T/rules1")" "$(cat "$RULES")"
check "install again: same aide config" "$(cat "$T/aconf1")" "$(cat "$ACONF")"
check_has "install again: baseline made again" "aide --config=${FX}/etc/aide/telcoin-node.conf --init" "$(cat "$HB_LOG")"
check "install again: HOST_BASELINE once" "1" "$(grep -c '^HOST_BASELINE=' "$META")"

# A custom data dir and a binary outside /opt/telcoin.
fixture
mkdir -p "$FX/srv/tn/node-keys" "$FX/usr/local/bin"
: > "$FX/usr/local/bin/telcoin-network"
printf 'NETWORK=testnet\nDATA_DIR=/srv/tn\nINSTALL_METHOD=existing\nBINARY_PATH=/usr/local/bin/telcoin-network\n' > "$META"
tn_host_baseline_install say_log > /dev/null 2>&1
check_has "custom data dir: watched" "-w /srv/tn/node-keys -p rwxa -k telcoin-keys" "$(cat "$RULES" 2>/dev/null)"
check_has "binary outside /opt/telcoin: in the baseline" '=/usr/local/bin/telcoin-network$ TnNode' "$(cat "$ACONF" 2>/dev/null)"

# Rules that do not load now are a warning; the baseline is still made.
fixture
: > "$T/say.log"
printf '4\n' > "$HB_T/augenrules.rc"
rc=0; tn_host_baseline_install say_log > /dev/null 2>&1 || rc=$?
check "rules not loaded: rc 0, marker set" "0 true" "$rc $(meta_get HOST_BASELINE "$META")"
check "rules not loaded: warns, names the boot" yes \
    "$(said '^warn|The audit rules in /etc/audit/rules.d/telcoin-node.rules did not load now.*next boot')"

# Refusals: rc 1, no marker, and the reason said.
refused() {  # refused NAME EXPECTED-WARNING-FRAGMENT
    local rc=0
    : > "$T/say.log"
    tn_host_baseline_install say_log > /dev/null 2>&1 || rc=$?
    check "$1: rc 1, no marker" "1 none" "$rc $(meta_get HOST_BASELINE "$META" 2>/dev/null || echo none)"
    check "$1: says why" yes "$(grep -qF -- "$2" "$T/say.log" && echo yes || echo no)"
}
fixture
printf '100\n' > "$HB_T/apt.rc"
refused "apt-get fails" "apt-get could not install auditd and aide"
check "apt-get fails: retried after apt-get update" "apt-get install -y -q --no-install-recommends auditd aide
apt-get update -q
apt-get install -y -q --no-install-recommends auditd aide" "$(cat "$HB_LOG")"
check "apt-get fails: no rules, no aide config" "no no" "$(yn test -e "$RULES") $(yn test -e "$ACONF")"
fixture
rm -f "${UNIT:?}"
refused "no node unit" "No node unit is installed"
check "no node unit: apt-get not run" "" "$(cat "$HB_LOG" 2>/dev/null)"
fixture
printf '[Service]\nEnvironment="TN_BLS_PASSPHRASE=hunter2hunter2"\n' > "$UNIT"
refused "unit holds the passphrase" "edit-config.sh --migrate-credential"
check "unit holds the passphrase: apt-get not run" "" "$(cat "$HB_LOG" 2>/dev/null)"
fixture
printf 'NETWORK=testnet\nDATA_DIR=/var/lib/tel coin\n' > "$META"
refused "data dir with a space" "cannot name"
fixture
printf 'NETWORK=testnet\nDATA_DIR=/a\nDATA_DIR=/b\n' > "$META"
refused "DATA_DIR set twice" "DATA_DIR is set more than once"
fixture
rm -rf "${FX:?}/var/lib/telcoin/node-keys"
refused "no node keys" "No node keys at /var/lib/telcoin/node-keys"
# A failure once something is written takes the whole baseline away again: no
# rules, AIDE config, database or marker are left. The audit rules are written
# last, so a failed AIDE step never reaches the kernel.
gone4() { echo "$(yn test -e "$RULES") $(yn test -e "$ACONF") $(yn test -e "$ADB") $(yn test -e "${ADB}.new")"; }
ran() { grep -q "^$1 " "$HB_LOG" 2>/dev/null && echo yes || echo no; }
fixture
printf '8\n' > "$HB_T/aide.rc"
refused "aide --init fails (rc 8)" "no part of it is left"
check "aide --init fails: aide's error said, no command naming the removed config" "yes no" \
    "$(said '^warn|AIDE: aide --init failed (rc 8): ERROR: stub aide failed$') $(said 'see: sudo aide')"
check "aide --init fails: no rules, aide config, database or new database" "no no no no" "$(gone4)"
check "aide --init fails: the audit rules never loaded" "no " "$(ran augenrules) $(cat "$HB_T/kernel.rules" 2>/dev/null)"
check_has "aide --init fails: status says off" "info  host baseline: off (sudo ./setup-node.sh --host-baseline adds auditd watches and an AIDE baseline)" "$(tn_host_baseline_status 2>&1)"
# The same failure on a run over an earlier baseline whose rules the kernel has
# loaded: the rules file goes, then augenrules --load drops the watches.
fixture
tn_host_baseline_install say_log > /dev/null 2>&1
check_has "re-run: the earlier baseline's watches are loaded" "-w /var/lib/telcoin/node-keys -p rwxa -k telcoin-keys" "$(cat "$HB_T/kernel.rules" 2>/dev/null)"
printf '8\n' > "$HB_T/aide.rc"
: > "$HB_LOG"
refused "re-run, aide --init fails" "no part of it is left"
check "re-run, aide --init fails: augenrules --load after the failed init" "aide --config=${FX}/etc/aide/telcoin-node.conf --init
augenrules --load" "$(grep -E '^(aide|augenrules) ' "$HB_LOG")"
check "re-run, aide --init fails: no rules, aide config or database left" "no no no no" "$(gone4)"
check "re-run, aide --init fails: the watches are gone from the kernel" "" "$(cat "$HB_T/kernel.rules" 2>/dev/null)"
# The AIDE config refused (the first write): nothing written, nothing run.
fixture
cp "$META" "$T/meta0"
if [[ $ROOT_OK == 1 ]]; then
    mkdir -p "$FX/etc/aide"
    chown 65534 "$FX/etc/aide"
else
    HB_WRITE_REFUSE=/etc/aide/telcoin-node.conf
fi
refused "aide config refused" "Could not write /etc/aide/telcoin-node.conf; the host baseline was not made."
HB_WRITE_REFUSE=""
check "aide config refused: nothing written" "no no no no" "$(gone4)"
check "aide config refused: neither aide nor augenrules ran, .node-meta unchanged" "no no yes" \
    "$(ran aide) $(ran augenrules) $(cmp -s "$T/meta0" "$META" && echo yes || echo no)"
# The audit rules refused (the last write): the AIDE side goes again.
fixture
if [[ $ROOT_OK == 1 ]]; then
    chown 65534 "$FX/etc/audit/rules.d"
else
    HB_WRITE_REFUSE=/etc/audit/rules.d/telcoin-node.rules
fi
refused "audit rules refused" "Could not write /etc/audit/rules.d/telcoin-node.rules."
HB_WRITE_REFUSE=""
check "audit rules refused: the AIDE side taken away again" "yes yes" "$(ran aide) $(said 'no part of it is left')"
check "audit rules refused: no rules, aide config or database left, nothing loaded" "no no no no no" "$(gone4) $(ran augenrules)"
# meta_set fails: the AIDE config goes again, aide never runs.
fixture
eval "$(declare -f meta_set | sed '1s/^meta_set /_hb_meta_set_real /')"
meta_set() { return 1; }
refused "meta_set fails" "Could not record HOST_BASELINE=true in .node-meta."
eval "$(declare -f _hb_meta_set_real | sed '1s/^_hb_meta_set_real /meta_set /')"
check "meta_set fails: nothing left, aide and augenrules not run" "no no no no no no" "$(gone4) $(ran aide) $(ran augenrules)"
# /var/lib/aide taken over between the check before the writes and the init.
fixture
eval "$(declare -f _tn_hb_db_dir_ok | sed '1s/^_tn_hb_db_dir_ok /_hb_dbok_saved /')"
_tn_hb_db_dir_ok() {
    local n
    n="$(cat "$HB_T/dbok.n" 2>/dev/null || echo 0)"
    n=$((n + 1))
    printf '%s\n' "$n" > "$HB_T/dbok.n"
    [ "$n" -lt 2 ] && return 0
    _tn_hb_say warn "AIDE: /var/lib/aide stand-in refusal" "${1:-}"
    return 1
}
refused "/var/lib/aide taken over before the init" "no part of it is left"
eval "$(declare -f _hb_dbok_saved | sed '1s/^_hb_dbok_saved /_tn_hb_db_dir_ok /')"
check "/var/lib/aide taken over: checked twice, nothing left, aide not run" "2 no no no no no no" \
    "$(cat "$HB_T/dbok.n") $(gone4) $(ran aide) $(ran augenrules)"
if [[ $ROOT_OK == 1 ]]; then
    fixture
    mkdir -p "$FX/var/lib/aide"
    ln -s "$T/elsewhere" "${ADB}.new"
    refused "a symlink in place of the new database" "is a symlink, not a regular file, or not owned by root"
    check "symlink: aide never ran" no "$(grep -q '^aide ' "$HB_LOG" 2>/dev/null && echo yes || echo no)"
    rm -f "${ADB:?}.new"
    # /var/lib/aide owned by another account (aide-common: _aide:root 0700).
    fixture
    mkdir -p "$FX/var/lib/aide"
    chmod 0700 "$FX/var/lib/aide"
    chown 65534 "$FX/var/lib/aide"
    refused "/var/lib/aide owned by another account" "/var/lib/aide is not a directory owned and writable by root alone"
    check "/var/lib/aide owned by another account: refused before anything is written" "no no no" \
        "$(grep -q '^a' "$HB_LOG" 2>/dev/null && echo yes || echo no) $(yn test -e "$ACONF") $(yn test -e "$RULES")"
    chown 0 "$FX/var/lib/aide"
    tn_host_baseline_install say_log > /dev/null 2>&1
    chown 65534 "$FX/var/lib/aide"
    : > "$HB_LOG"; : > "$T/say.log"
    tn_host_baseline_refresh say_log > /dev/null 2>&1
    check "refresh, /var/lib/aide owned by another account: refused, database untouched" "yes no db init" \
        "$(said '/var/lib/aide is not a directory owned and writable by root alone') $(grep -q '^aide ' "$HB_LOG" && echo yes || echo no) $(cat "$ADB")"
    chown 0 "$FX/var/lib/aide"
    chown 65534 "$ADB"
    : > "$T/say.log"
    tn_host_baseline_refresh say_log > /dev/null 2>&1
    check "refresh, database owned by another account: refused" yes "$(said 'telcoin-node.db is a symlink, not a regular file, or not owned by root')"
else
    skip "a symlink in place of the new database" "needs root and GNU mv -T"
    skip "/var/lib/aide or the database owned by another account" "needs root and GNU mv -T"
fi
# No apt-get on PATH: a PATH of the plain tools the library needs, without the stubs.
mkdir -p "$T/noapt"
for c in sed cat grep awk mkdir chmod rm mv stat id date tr head cut dirname mktemp sort sh bash; do
    p="$(type -P "$c" 2>/dev/null)" && ln -sf "$p" "$T/noapt/$c"
done
fixture
PATH_SAVE="$PATH"
# shellcheck disable=SC2123  # a PATH without the stand-ins, on purpose
PATH="$T/noapt"
rc=0; : > "$T/say.log"; tn_host_baseline_install say_log > /dev/null 2>&1 || rc=$?
PATH="$PATH_SAVE"
check "no apt-get: rc 1, says so" "1 yes" "$rc $(said 'needs apt-get')"

# =============================================================================
# tn_host_baseline_refresh
# =============================================================================
fixture
tn_host_baseline_install say_log > /dev/null 2>&1
: > "$HB_LOG"; : > "$T/say.log"
rc=0; tn_host_baseline_refresh say_log > /dev/null 2>&1 || rc=$?
check_rc "refresh: rc 0" 0 "$rc"
check "refresh: aide --update with the node config" "aide --config=${FX}/etc/aide/telcoin-node.conf --update" "$(cat "$HB_LOG")"
check "refresh: new database moved into place" "db update no" "$(cat "$ADB" 2>/dev/null) $(yn test -e "${ADB}.new")"
printf '5\n' > "$HB_T/aide.rc"
printf 'db init\n' > "$ADB"
rc=0; tn_host_baseline_refresh say_log > /dev/null 2>&1 || rc=$?
check "refresh: differences found (aide rc 5) still refresh" "0 db update no" \
    "$rc $(cat "$ADB" 2>/dev/null) $(yn test -e "${ADB}.new")"
rm -f "${HB_T:?}/aide.rc"
# aide --update without database_in: rc 18, partial .new removed, warning, rc 0.
rm -f "${ADB:?}"; : > "$T/say.log"
rc=0; tn_host_baseline_refresh say_log > /dev/null 2>&1 || rc=$?
check_rc "refresh failure: rc 0 (never a failed apply)" 0 "$rc"
check "refresh failure: partial database removed, none renamed" "no no" "$(yn test -e "${ADB}.new") $(yn test -e "$ADB")"
check "refresh failure: warns" yes "$(said '^warn|AIDE: aide --update failed (rc 18)')"
# Without the marker: nothing runs.
fixture
: > "$HB_LOG"
tn_host_baseline_refresh say_log > /dev/null 2>&1
check "refresh without the marker: aide not run" "" "$(cat "$HB_LOG" 2>/dev/null)"
printf 'HOST_BASELINE=false\n' >> "$META"
tn_host_baseline_refresh say_log > /dev/null 2>&1
check "refresh with HOST_BASELINE=false: aide not run" "" "$(cat "$HB_LOG" 2>/dev/null)"
# The marker without the config: a warning, aide not run.
fixture
printf 'HOST_BASELINE=true\n' >> "$META"
: > "$T/say.log"
tn_host_baseline_refresh say_log > /dev/null 2>&1
check "refresh, config missing: warns, aide not run" "yes no" \
    "$(said '^warn|HOST_BASELINE=true, but /etc/aide/telcoin-node.conf is missing') $(grep -q '^aide ' "$HB_LOG" 2>/dev/null && echo yes || echo no)"
# Without FN the warning is a print_warn line.
out="$(tn_host_baseline_refresh 2>&1)"
check "refresh without FN: print_warn" yes "$([[ "$out" == *"[WARN]"*"is missing"* ]] && echo yes || echo no)"

# HOST_BASELINE on two lines: refresh and status warn, remove clears both.
fixture
tn_host_baseline_install say_log > /dev/null 2>&1
printf 'HOST_BASELINE=true\n' >> "$META"
: > "$HB_LOG"; : > "$T/say.log"
tn_host_baseline_refresh say_log > /dev/null 2>&1
check "refresh, marker twice: warns, aide not run" "yes no" \
    "$(said '^warn|HOST_BASELINE is set more than once in .node-meta') $(grep -q '^aide ' "$HB_LOG" && echo yes || echo no)"
out="$(tn_host_baseline_status)"; rc=$?
check "status, marker twice: one warning, rc 1" "1 yes 1" \
    "$rc $([[ "$out" == "warn  host baseline: HOST_BASELINE is set more than once in .node-meta"* ]] && echo yes || echo no) $(printf '%s\n' "$out" | grep -c .)"
tn_host_baseline_remove say_log > /dev/null 2>&1
check "remove, marker twice: both lines gone, files gone" "0 no" "$(grep -c '^HOST_BASELINE=' "$META") $(yn test -e "$RULES")"
# A .node-meta this user cannot read (root 0600 on a node, --audit without sudo).
if [[ $IS_ROOT == 1 ]]; then
    skip "status, unreadable .node-meta: not checked" "root reads every file"
else
    fixture
    printf 'HOST_BASELINE=true\n' >> "$META"
    chmod 000 "$META"
    out="$(tn_host_baseline_status)"; rc=$?
    chmod 0600 "$META"
    check "status, unreadable .node-meta: not checked, rc 0" "0 info  host baseline: not checked (.node-meta is readable by root only)" "$rc $out"
fi

# =============================================================================
# tn_host_baseline_status and tn_host_audit
# =============================================================================
fixture
out="$(tn_host_baseline_status)"; rc=$?
check "status, no marker: one info line, rc 0" "0 1" "$rc $(printf '%s\n' "$out" | grep -c .)"
check "status, no marker: says how to turn it on" yes \
    "$([[ "$out" == "info  host baseline: off"*"--host-baseline"* ]] && echo yes || echo no)"
tn_host_baseline_install say_log > /dev/null 2>&1
out="$(tn_host_baseline_status)"; rc=$?
check_rc "status, in place: rc 0" 0 "$rc"
check_has "status: marker" "ok    host baseline: HOST_BASELINE=true in .node-meta" "$out"
check_has "status: rules file" "ok    audit rules: /etc/audit/rules.d/telcoin-node.rules" "$out"
if [[ $IS_ROOT == 1 ]]; then
    check_has "status: rules loaded" "ok    audit rules loaded (auditctl -l lists telcoin-keys)" "$out"
else
    check_has "status: rules loaded not checked without root" "info  audit rules loaded: not checked (auditctl -l needs root)" "$out"
fi
check_has "status: baseline and its age" "ok    AIDE baseline: /var/lib/aide/telcoin-node.db, made 0 day(s) ago (check: sudo aide --config=/etc/aide/telcoin-node.conf --check)" "$out"
if [[ $IS_ROOT == 1 ]]; then
    : > "$HB_T/kernel.rules"
    out="$(tn_host_baseline_status)"; rc=$?
    check "status, rules not loaded: warn, rc 1" "1 yes" \
        "$rc $(printf '%s\n' "$out" | grep -q '^warn  audit rules not loaded' && echo yes || echo no)"
    tn_host_baseline_install say_log > /dev/null 2>&1
else
    skip "status, rules not loaded: warn" "not root"
fi
rm -f "${ADB:?}"
out="$(tn_host_baseline_status)"; rc=$?
check "status, database missing: warn, rc 1" "1 yes" \
    "$rc $(printf '%s\n' "$out" | grep -q '^warn  AIDE baseline: /var/lib/aide/telcoin-node.db is missing; make it again: sudo ./setup-node.sh --host-baseline' && echo yes || echo no)"
rm -f "${RULES:?}"
out="$(tn_host_baseline_status)"; rc=$?
check "status, rules missing: warn, rc 1" "1 yes" \
    "$rc $(printf '%s\n' "$out" | grep -q '^warn  audit rules: /etc/audit/rules.d/telcoin-node.rules is missing' && echo yes || echo no)"
rm -f "${ACONF:?}"
out="$(tn_host_baseline_status)"
check "status, aide config missing: warn" yes \
    "$(printf '%s\n' "$out" | grep -q '^warn  AIDE: /etc/aide/telcoin-node.conf is missing' && echo yes || echo no)"
# tn_host_audit carries the lines; a missing piece makes it warn (rc 1).
systemctl() { case "$*" in *LimitCORE*) echo 0 ;; esac; return 0; }
out="$(tn_host_audit 2>/dev/null)"; rc=$?
check "audit: host baseline lines included, rc 1 on the missing piece" "1 yes" \
    "$rc $(printf '%s\n' "$out" | grep -q '^ok    host baseline: HOST_BASELINE=true' && echo yes || echo no)"
fixture
out="$(tn_host_audit 2>/dev/null)"
check "audit, no marker: the info line" yes "$(printf '%s\n' "$out" | grep -q '^info  host baseline: off' && echo yes || echo no)"
unset -f systemctl

# =============================================================================
# tn_host_baseline_remove
# =============================================================================
fixture
tn_host_baseline_install say_log > /dev/null 2>&1
printf 'partial\n' > "${ADB}.new"
: > "$HB_LOG"; : > "$T/say.log"
rc=0; tn_host_baseline_remove say_log > /dev/null 2>&1 || rc=$?
check_rc "remove: rc 0" 0 "$rc"
check "remove: rules, aide config, database and new database gone" "no no no no" \
    "$(yn test -e "$RULES") $(yn test -e "$ACONF") $(yn test -e "$ADB") $(yn test -e "${ADB}.new")"
check "remove: audit rules reloaded" "augenrules --load" "$(cat "$HB_LOG")"
check "remove: watches gone from the kernel" "" "$(cat "$HB_T/kernel.rules")"
check "remove: HOST_BASELINE cleared, other keys kept" "none testnet" \
    "$(meta_get HOST_BASELINE "$META" 2>/dev/null || echo none) $(meta_get NETWORK "$META")"
check "remove: says the packages stay" yes "$(said 'auditd and aide packages stay installed')"
check "remove: AIDE directories stay" "yes yes" "$(yn test -d "$FX/etc/aide") $(yn test -d "$FX/var/lib/aide")"
: > "$HB_LOG"; : > "$T/say.log"
out="$(tn_host_baseline_remove say_log 2>&1)"
check "remove with nothing there: silent, nothing run" "||" "${out}|$(cat "$T/say.log")|$(cat "$HB_LOG")"
printf '4\n' > "$HB_T/augenrules.rc"
tn_host_baseline_install say_log > /dev/null 2>&1
: > "$T/say.log"
tn_host_baseline_remove say_log > /dev/null 2>&1
check "remove, reload fails: warns, files still gone" "yes no" \
    "$(said '^warn|augenrules --load failed') $(yn test -e "$RULES")"
rm -f "${HB_T:?}/augenrules.rc"
# Without augenrules: each watch is dropped with auditctl -W; a failed -W warns.
mkdir -p "$T/noaug"
for c in apt-get auditctl aide install; do
    if [[ -e "$T/bin/$c" ]]; then ln -sf "$T/bin/$c" "$T/noaug/$c"; fi
done
fixture
tn_host_baseline_install say_log > /dev/null 2>&1
: > "$HB_LOG"; : > "$T/say.log"
PATH_SAVE="$PATH"
PATH="$T/noaug:${PATH#"$T/bin:"}"
tn_host_baseline_remove say_log > /dev/null 2>&1
PATH="$PATH_SAVE"
check "remove without augenrules: each watch dropped with auditctl -W" "auditctl -W /var/lib/telcoin/node-keys -p rwxa -k telcoin-keys
auditctl -W /etc/telcoin -p wa -k telcoin-config
auditctl -W /etc/systemd/system/telcoin.service -p wa -k telcoin-unit" "$(cat "$HB_LOG")"
check "remove without augenrules: says so, rules file gone" "yes no" \
    "$(said '^log|augenrules is missing: the node.s audit watches were dropped one by one with auditctl -W') $(yn test -e "$RULES")"
tn_host_baseline_install say_log > /dev/null 2>&1
printf '1\n' > "$HB_T/auditctl.rc"
: > "$T/say.log"
PATH="$T/noaug:${PATH#"$T/bin:"}"
tn_host_baseline_remove say_log > /dev/null 2>&1
PATH="$PATH_SAVE"
rm -f "${HB_T:?}/auditctl.rc"
check "remove without augenrules, auditctl -W fails: warns about the next boot, rules file gone" "yes no" \
    "$(said '^warn|augenrules is missing and auditctl -W could not drop the node.s audit watches: they stay loaded until the next boot') $(yn test -e "$RULES")"

# =============================================================================
# The scripts, each in its own bash (each sources lib/common.sh once): a copy
# without its last line is sourced by a driver that stubs the library function
# and records the calls in $HB_T/calls.
# =============================================================================
for sc in setup-node update-node edit-config remove-node; do
    mkdir -p "$T/$sc"
    grep -v '^main "\$@"$' "$TN_TEST_REPO/${sc}.sh" > "$T/$sc/${sc}.sh"
    ln -s "$TN_TEST_REPO/lib" "$T/$sc/lib"
done
export HB_DRV="$T"
calls() { cat "$HB_T/calls" 2>/dev/null | tr '\n' ' '; }

# --- setup-node.sh --------------------------------------------------------------
cat > "$T/setup-node/drv.sh" <<'DRV'
source "$HB_DRV/setup-node/setup-node.sh"
set +e
rec() { printf '%s\n' "$*" >> "$HB_T/calls"; }
tn_host_baseline_install() { rec "install ${1:-}"; return "${HB_INSTALL_RC:-0}"; }
tn_host_audit() { rec "audit HOST_BASELINE=${HOST_BASELINE}"; return 0; }
check_root() { rec check_root; }
json_require_root() { rec check_root; }
setup_take_lock() { rec lock; }
setup_release_lock() { rec unlock; }
for f in setup_read_passphrase init_public_rpc_flags init_install_flags init_node_inputs init_node_extra_flags \
         json_check_install_flags json_refuse_installed finalize_install_inputs finalize_node_extra_flags \
         step_welcome step_preflight step_config step_create_infrastructure step_generate_keys \
         step_write_config step_create_service step_public_rpc step_testnet_addons step_alerts step_final_summary; do
    eval "${f}() { rec ${f}; return 0; }"
done
main "$@"
DRV
snrun() {  # snrun ARGS... -- run setup-node's main under the driver; OUT, RC
    rm -f "${HB_T:?}/calls"
    RC=0
    OUT="$(bash "$T/setup-node/drv.sh" "$@" 2> "$T/sn.err")" || RC=$?
}
fixture
rm -f "${UNIT:?}"
snrun --host-baseline --audit
# (the last unlock is the EXIT trap, json_on_exit)
check "setup-node: --host-baseline is parsed" "audit HOST_BASELINE=true unlock " "$(calls)"
snrun --host-baseline
check "setup-node: full setup runs the baseline last, under the lock, before the summary" \
    "setup_read_passphrase init_public_rpc_flags init_install_flags init_node_inputs init_node_extra_flags step_welcome step_preflight step_config step_create_infrastructure step_generate_keys step_write_config step_create_service unlock step_public_rpc step_testnet_addons step_alerts lock install setup_progress unlock step_final_summary unlock " \
    "$(calls)"
snrun
check "setup-node: without the flag no baseline" no "$([[ "$(calls)" == *"install setup_progress"* ]] && echo yes || echo no)"
export HB_INSTALL_RC=1
snrun --host-baseline
unset HB_INSTALL_RC
check "setup-node: a failed baseline warns and setup goes on" "0 yes yes" \
    "$RC $([[ "$(calls)" == *"step_final_summary"* ]] && echo yes || echo no) $([[ "$OUT" == *"The host baseline was not made"* ]] && echo yes || echo no)"
LP="/ip4/0.0.0.0/udp/49590/quic-v1"
LW="/ip4/0.0.0.0/udp/49594/quic-v1"
snrun --json --phase=finalize --network testnet --listener-primary "$LP" --listener-worker "$LW" --host-baseline
check "setup-node --json finalize: baseline made after the node, done says host_baseline true" "0 yes yes" \
    "$RC $([[ "$(calls)" == *"step_create_service unlock lock install setup_progress unlock"* ]] && echo yes || echo no) $(printf '%s\n' "$OUT" | tail -n 1 | grep -q '"event":"done","ok":true,.*"host_baseline":true' && echo yes || echo no)"
export HB_INSTALL_RC=1
snrun --json --phase=finalize --network testnet --listener-primary "$LP" --listener-worker "$LW" --host-baseline
unset HB_INSTALL_RC
check "setup-node --json finalize, baseline failed: warning log event, done ok with host_baseline false" "0 yes yes" \
    "$RC $(printf '%s\n' "$OUT" | grep -q '"event":"log","msg":"WARNING: The host baseline was not made' && echo yes || echo no) $(printf '%s\n' "$OUT" | tail -n 1 | grep -q '"ok":true,.*"host_baseline":false' && echo yes || echo no)"
snrun --json --phase=finalize --network testnet --listener-primary "$LP" --listener-worker "$LW"
check "setup-node --json finalize without the flag: no baseline, host_baseline false" "no yes" \
    "$([[ "$(calls)" == *"install setup_progress"* ]] && echo yes || echo no) $(printf '%s\n' "$OUT" | tail -n 1 | grep -q '"host_baseline":false' && echo yes || echo no)"
fixture
snrun --host-baseline
check "setup-node --host-baseline on an installed node: the baseline alone" "0 check_root lock install setup_progress unlock unlock " "$RC $(calls)"
export HB_INSTALL_RC=1
snrun --host-baseline
unset HB_INSTALL_RC
check_rc "setup-node --host-baseline on an installed node: a failure is rc 1" 1 "$RC"

# --- update-node.sh: the refresh after a verified apply, never after a failed one ---
cat > "$T/update-node/drv.sh" <<'DRV'
source "$HB_DRV/update-node/update-node.sh"
set +e
rec() { printf '%s\n' "$*" >> "$HB_T/calls"; }
tn_host_baseline_refresh() { rec "refresh ${1:-}"; }
read_pending_state() { printf 'PHASE=pull_complete\nINSTALL_METHOD=docker\nOLD_IMAGE=r@sha256:aa\nNEW_IMAGE=r@sha256:bb\nPULLED_IMAGE_ID=sha256:cc\n'; }
docker_launch_file() { printf '%s\n' "$HB_T/launch"; }
apply_root_dir_refusal() { return 1; }
verify_health_after_restart() { return "${HB_VERIFY_RC:-0}"; }
docker_record_meta() { rec record; }
confirm() { return 1; }
for f in update_swap_precheck storage_migration_begin validator_downtime_warning_if_applicable backup_unit_file \
         update_epoch_wait wait_for_service_stopped update_swap_image storage_migration_mark_started start_service \
         verify_running_image_id verify_consensus_participation clear_pending_state update_vote_note systemctl; do
    eval "${f}() { return 0; }"
done
update_vote_field() { :; }
SERVICE_NAME=telcoin STORAGE_MIGRATION=false
if [[ "$1" == json ]]; then
    JSON_MODE=true
    exec 3>>"$HB_T/json"
    json_apply_docker
else
    apply_docker_update
fi
DRV
unrun() {  # unrun json|human
    rm -f "${HB_T:?}/calls" "${HB_T:?}/json"
    RC=0
    bash "$T/update-node/drv.sh" "$1" > "$T/un.out" 2>&1 || RC=$?
}
unrun human
check "update-node apply: refresh after the verify, with the progress printer" "0 record refresh update_wait_say " "$RC $(calls)"
unrun json
check "update-node --json apply: refresh before the done event" "0 record refresh update_wait_say " "$RC $(calls)"
export HB_VERIFY_RC=1
unrun human
check "update-node apply, verify failed: no refresh" "" "$(calls)"
unrun json
check "update-node --json apply, verify failed: no refresh" "" "$(calls)"
unset HB_VERIFY_RC
check "update-node: every verified apply refreshes (docker, source, both modes)" "4" \
    "$(grep -c '^        update_baseline_refresh$' "$TN_TEST_REPO/update-node.sh")"

# --- edit-config.sh: the refresh after a restart that came back -------------------
cat > "$T/edit-config/drv.sh" <<'DRV'
source "$HB_DRV/edit-config/edit-config.sh"
set +e
rec() { printf '%s\n' "$*" >> "$HB_T/calls"; }
tn_host_baseline_refresh() { rec "refresh ${1:-}"; }
edit_done() { rec "done $1"; }
edit_restart() { return "${HB_RESTART_RC:-0}"; }
edit_epoch_wait() { return "${HB_RESTART_RC:-0}"; }
systemctl() { case "$1" in is-active) return "${HB_RESTART_RC:-0}" ;; esac; return 0; }
confirm() { return 0; }
sleep() { :; }
for f in edit_require_root resolve_target edit_lock edit_reset_backups set_field edit_any_changed \
         edit_report_backups edit_restore_backups edit_unlock; do
    eval "${f}() { return 0; }"
done
edit_field_known() { return 0; }
TARGET_SERVICE=telcoin
menu_lock() { return 0; }
if [[ "$1" == set ]]; then
    EDIT_SET_PAIR="metrics=127.0.0.1:9101"
    run_set
elif [[ "$1" == restart ]]; then
    restart_node < /dev/null
elif [[ "$1" == cred ]]; then
    edit_cred_report "$2" "credential moved"
else
    apply_changes < /dev/null
fi
DRV
ecrun() {  # ecrun set|menu
    rm -f "${HB_T:?}/calls"
    RC=0
    bash "$T/edit-config/drv.sh" "$1" > "$T/ec.out" 2>&1 || RC=$?
}
ecrun set
check "edit-config --set: refresh after a healthy restart, before done" "refresh edit_wait_say done true " "$(calls)"
ecrun restart
check "edit-config menu Restart node: refresh after a successful restart" "refresh edit_wait_say " "$(calls)"
ecrun menu
check "edit-config menu: refresh after a successful restart" "refresh edit_wait_say " "$(calls)"
export HB_RESTART_RC=1
ecrun set
check "edit-config --set, restart failed: no refresh" "done false " "$(calls)"
ecrun menu
check "edit-config menu, restart failed: no refresh" "" "$(calls)"
ecrun restart
check "edit-config menu Restart node, restart failed: no refresh" "" "$(calls)"
export HB_RESTART_RC=2
ecrun set
check "edit-config --set, committee refused the restart: no refresh" "done false " "$(calls)"
unset HB_RESTART_RC
# A passphrase move (edit_cred_report: --migrate-credential, --reseal, the passphrase
# change) rewrote the unit, the start script and .node-meta when its rc is 0.
rm -f "${HB_T:?}/calls"; bash "$T/edit-config/drv.sh" cred 0 > "$T/ec.out" 2>&1 || true
check "edit-config credential move done: refresh" "refresh edit_wait_say " "$(calls)"
rm -f "${HB_T:?}/calls"; bash "$T/edit-config/drv.sh" cred 2 > "$T/ec.out" 2>&1 || true
check "edit-config credential move rolled back: no refresh" "" "$(calls)"

# --- remove-node.sh: the teardown goes with the node unit --------------------------
cat > "$T/remove-node/drv.sh" <<'DRV'
source "$HB_DRV/remove-node/remove-node.sh"
set +e
rec() { printf '%s\n' "$*" >> "$HB_T/calls"; }
tn_host_baseline_remove() { rec "baseline_remove"; }
systemctl() { rec "systemctl $1"; return 0; }
remove_unit_leftovers() { rec leftovers; }
stop_and_disable_service "$@"
DRV
rmrun() {
    rm -f "${HB_T:?}/calls"
    bash "$T/remove-node/drv.sh" "$@" > "$T/rm.out" 2>&1
}
fixture
rmrun telcoin
check "remove-node: the baseline goes first, then the unit" "baseline_remove systemctl stop systemctl disable leftovers systemctl daemon-reload " "$(calls)"
check "remove-node: the unit file is removed" no "$(yn test -e "$UNIT")"
rmrun ""
check "remove-node, no unit left: the baseline goes too" "baseline_remove" "$(calls | awk '{ print $1 }')"
# The real teardown under remove-node: everything the install made is gone.
fixture
tn_host_baseline_install say_log > /dev/null 2>&1
cat > "$T/remove-node/drv2.sh" <<'DRV'
source "$HB_DRV/remove-node/remove-node.sh"
set +e
systemctl() { return 0; }
if [[ -n "${HB_FAKE_WRITE:-}" ]]; then
    tn_write_root_file() { cat > "$1"; }
fi
stop_and_disable_service telcoin
DRV
if [[ $ROOT_OK != 1 ]]; then
    export HB_FAKE_WRITE=1
fi
bash "$T/remove-node/drv2.sh" > "$T/rm.out" 2>&1
unset HB_FAKE_WRITE
check "remove-node, real teardown: rules, aide config, database and marker gone" "no no no none" \
    "$(yn test -e "$RULES") $(yn test -e "$ACONF") $(yn test -e "$ADB") $(meta_get HOST_BASELINE "$META" 2>/dev/null || echo none)"
check "remove-node, real teardown: says the packages stay" yes "$(grep -q 'auditd and aide packages stay installed' "$T/rm.out" && echo yes || echo no)"
# --json: the teardown's lines are events on the JSON stream.
fixture
tn_host_baseline_install say_log > /dev/null 2>&1
cat > "$T/remove-node/drv3.sh" <<'DRV'
source "$HB_DRV/remove-node/remove-node.sh"
set +e
systemctl() { return 0; }
if [[ -n "${HB_FAKE_WRITE:-}" ]]; then
    tn_write_root_file() { cat > "$1"; }
fi
exec 3>> "$HB_T/rm.json"
RM_JSON=true
stop_and_disable_service telcoin
DRV
if [[ $ROOT_OK != 1 ]]; then
    export HB_FAKE_WRITE=1
fi
bash "$T/remove-node/drv3.sh" > /dev/null 2>&1
unset HB_FAKE_WRITE
RJ="$(cat "$HB_T/rm.json" 2>/dev/null)"
check_has "remove-node --json: the teardown step is an event" '{"event":"step","msg":"Removing the host baseline (audit rules and AIDE baseline)"}' "$RJ"
check_has "remove-node --json: the packages line is an event" '{"event":"log","msg":"Host baseline removed. The auditd and aide packages stay installed; remove them with: sudo apt-get purge auditd aide"}' "$RJ"
check "remove-node --json: files and marker gone" "no none" "$(yn test -e "$RULES") $(meta_get HOST_BASELINE "$META" 2>/dev/null || echo none)"
# Another node unit remains (a legacy two-unit host, or any sibling unit file):
# the baseline stays for that node, and the run says so. It goes with the last.
OBS_UNIT="$FX/etc/systemd/system/telcoin-observer.service"
fixture
printf '[Service]\n' > "$OBS_UNIT"
rmrun telcoin
check "remove-node, another unit remains: no teardown" "systemctl stop systemctl disable leftovers systemctl daemon-reload " "$(calls)"
check "remove-node, another unit remains, no baseline here: nothing said about one" no \
    "$(grep -q 'Host baseline' "$T/rm.out" && echo yes || echo no)"
cat > "$T/remove-node/drv4.sh" <<'DRV'
source "$HB_DRV/remove-node/remove-node.sh"
set +e
systemctl() { return 0; }
if [[ -n "${HB_FAKE_WRITE:-}" ]]; then
    tn_write_root_file() { cat > "$1"; }
fi
stop_and_disable_service "$1"
DRV
kept4() { echo "$(yn test -e "$RULES") $(yn test -e "$ACONF") $(yn test -e "$ADB") $(meta_get HOST_BASELINE "$META" 2>/dev/null || echo none)"; }
if [[ $ROOT_OK != 1 ]]; then
    export HB_FAKE_WRITE=1
fi
fixture
tn_host_baseline_install say_log > /dev/null 2>&1
printf '[Service]\n' > "$OBS_UNIT"
bash "$T/remove-node/drv4.sh" telcoin > "$T/rm.out" 2>&1
check "two units, one removed: rules, aide config, database and marker kept" "yes yes yes true" "$(kept4)"
check "two units, one removed: says the baseline stays, removes the unit" "yes no yes" \
    "$(grep -q 'Host baseline kept: another node unit remains here' "$T/rm.out" && echo yes || echo no) $(yn test -e "$UNIT") $(yn test -e "$OBS_UNIT")"
check_lacks "two units, one removed: no teardown step" "Removing the host baseline" "$(cat "$T/rm.out")"
bash "$T/remove-node/drv4.sh" telcoin-observer > "$T/rm.out" 2>&1
check "the last unit removed: rules, aide config, database and marker gone" "no no no none" "$(kept4)"
check "the last unit removed: says the packages stay, nothing kept" "yes no" \
    "$(grep -q 'auditd and aide packages stay installed' "$T/rm.out" && echo yes || echo no) $(grep -q 'Host baseline kept' "$T/rm.out" && echo yes || echo no)"
# --json, every scope: json_remove keeps the baseline while another unit remains
# (the kept line a log event) and tears it down with the last unit. The account,
# lock, shredding and shared host files are stand-ins here (remove_test.sh drives
# them); the service account named in .node-meta does not exist.
cat > "$T/remove-node/drv5.sh" <<'DRV'
source "$HB_DRV/remove-node/remove-node.sh"
set +e
systemctl() { return 0; }
if [[ -n "${HB_FAKE_WRITE:-}" ]]; then
    tn_write_root_file() { cat > "$1"; }
fi
rm_take_lock() { return 0; }
detect_data_dir() { printf '%s\n' "${TN_ROOT_PREFIX}/var/lib/telcoin"; }
_rm_shred_tree() { :; }
shred_key_files() { :; }
remove_testnet_addons() { :; }
remove_log_group() { RM_LOG_GROUP_MSG=""; }
remove_node_host_files() { :; }
userdel() { :; }
groupdel() { :; }
RM_JSON=true
json_remove validator "$1" 3>> "$HB_T/rm.json"
DRV
rj() { cat "$HB_T/rm.json" 2>/dev/null; }
for scope in service data keys; do
    fixture
    printf 'HOST_SERVICE_USER=tn-hb-nouser\nHOST_SERVICE_GROUP=tn-hb-nogroup\n' >> "$META"
    tn_host_baseline_install say_log > /dev/null 2>&1
    printf '[Service]\n' > "$OBS_UNIT"
    bash "$T/remove-node/drv5.sh" "$scope" > /dev/null 2>&1
    check "--json ${scope}, another unit remains: rules, aide config and database kept" "yes yes yes" \
        "$(yn test -e "$RULES") $(yn test -e "$ACONF") $(yn test -e "$ADB")"
    check_has "--json ${scope}, another unit remains: the kept line is a log event" \
        '{"event":"log","msg":"Host baseline kept: another node unit remains here"}' "$(rj)"
    check_lacks "--json ${scope}, another unit remains: no teardown event" "Removing the host baseline" "$(rj)"
    check "--json ${scope}, another unit remains: done ok" yes "$(rj | grep -q '"event":"done","ok":true' && echo yes || echo no)"
    if [[ "$scope" != "keys" ]]; then
        check "--json ${scope}, another unit remains: marker kept" true "$(meta_get HOST_BASELINE "$META" 2>/dev/null || echo none)"
    fi
    fixture
    printf 'HOST_SERVICE_USER=tn-hb-nouser\nHOST_SERVICE_GROUP=tn-hb-nogroup\n' >> "$META"
    tn_host_baseline_install say_log > /dev/null 2>&1
    bash "$T/remove-node/drv5.sh" "$scope" > /dev/null 2>&1
    check "--json ${scope}, the last unit: rules, aide config, database and marker gone" "no no no none" "$(kept4)"
    check_has "--json ${scope}, the last unit: the teardown step is an event" \
        '{"event":"step","msg":"Removing the host baseline (audit rules and AIDE baseline)"}' "$(rj)"
    check "--json ${scope}, the last unit: nothing kept, done ok" "no yes" \
        "$(rj | grep -q 'Host baseline kept' && echo yes || echo no) $(rj | grep -q '"event":"done","ok":true' && echo yes || echo no)"
done
unset HB_FAKE_WRITE

# setup-node.sh with a lib/common.sh that lacks tn_host_baseline_install: the
# one-message refusal of the version gate, not "command not found" later.
mkdir -p "$T/skew"
cp "$TN_TEST_REPO/setup-node.sh" "$T/skew/setup-node.sh"
cp -R "$TN_TEST_REPO/lib" "$T/skew/lib"
sed 's/^tn_host_baseline_install() {/_tn_gone_install() {/' "$TN_TEST_REPO/lib/common.sh" > "$T/skew/lib/common.sh"
rc=0; bash "$T/skew/setup-node.sh" --help > /dev/null 2> "$T/skew.err" < /dev/null || rc=$?
check "setup-node with a lib lacking tn_host_baseline_install: refused up front" "1 yes" \
    "$rc $(grep -q 'is older than this setup-node.sh: run update-scripts.sh' "$T/skew.err" && echo yes || echo no)"


# =============================================================================
# AUDIT-2 add-on refresh
# The add-ons make the host baseline again after a change that went through
# (tn_host_baseline_refresh with the script's own printer), never after a refused
# or failed one, and do nothing with a lib/common.sh that lacks the function.
# Each driver sources a copy without its `main "$@"` line, stubs what the
# operation runs and records the calls in $HB_T/calls. The firewall's --reset and
# --json --enable runs are checked in firewall_signal_test.sh and Manage node
# ports in firewall_reset_test.sh, whose drivers run those paths already.
# =============================================================================
for sc in install-caddy firewall-setup setup-vpn setup-observability; do
    mkdir -p "$T/$sc"
    grep -v '^main "\$@"$' "$TN_TEST_REPO/${sc}.sh" > "$T/$sc/${sc}.sh"
    ln -s "$TN_TEST_REPO/lib" "$T/$sc/lib"
done
# The recording stand-in of every driver. It says one warning through the printer
# it was given, so a --json run shows where that line lands. HB_NOLIB=1: no
# tn_host_baseline_refresh at all, as with an older lib/common.sh.
cat > "$T/hbstub.sh" <<'STUB'
rec() { printf '%s\n' "$*" >> "$HB_T/calls"; }
if [[ "${HB_NOLIB:-0}" == 1 ]]; then
    unset -f tn_host_baseline_refresh
else
    tn_host_baseline_refresh() {
        rec "refresh${1:+ $1}"
        if [[ -n "${1:-}" ]]; then
            "$1" warn "hb stub warning"
        else
            print_warn "hb stub warning"
        fi
        return 0
    }
fi
STUB
answers() { printf '%s\n' "$@" > "$T/addon.in"; }
addon_run() {  # addon_run SCRIPT ARGS... -- RC, JS (stdout: the JSON stream in --json runs), ERR
    local sc="$1"
    shift
    rm -f "${HB_T:?}/calls"
    RC=0
    bash "$T/$sc/drv.sh" "$@" > "$T/addon.stdout" 2> "$T/addon.err" < "$T/addon.in" || RC=$?
    JS="$(cat "$T/addon.stdout")"
    ERR="$(cat "$T/addon.err")"
    : > "$T/addon.in"
}
: > "$T/addon.in"
# warn_then_done -- yes when the stub's warning is a warn event before the one done
# event, the done event is the last line and every line is a JSON event.
warn_then_done() {
    printf '%s\n' "$JS" | awk '
        !/^\{"event":/ { bad = 1 }
        /^\{"event":"warn","msg":"hb stub warning"\}$/ { w = NR }
        /^\{"event":"done"/ { d = NR; n++ }
        END { print ((!bad && w && n == 1 && w < d && d == NR) ? "yes" : "no") }'
}
done_ok() { printf '%s\n' "$JS" | tail -n 1 | grep -q '^{"event":"done","ok":true' && echo yes || echo no; }
no_cnf() { [[ "$ERR" == *"command not found"* ]] && echo no || echo yes; }

# --- install-caddy.sh: rpc-enable and rpc-disable ------------------------------------
cat > "$T/install-caddy/drv.sh" <<'DRV'
source "$HB_DRV/install-caddy/install-caddy.sh"
set +e
source "$HB_DRV/hbstub.sh"
for f in check_root caddy_rpc_enable_precheck caddy_rpc_confirm caddy_assert_ports_free caddy_assert_not_foreign \
         caddy_meta_ready install_caddy_pkg caddy_ws_plan caddy_node_lock write_rpc_block caddy_write_managed \
         caddy_open_ports caddy_reload caddy_ws_inject caddy_ws_verify caddy_teardown; do
    eval "${f}() { return 0; }"
done
caddy_current_dashboard_block() { :; }
caddy_extract_block() { :; }
caddy_ws_port() { echo 8546; }
caddy_node_port() { echo 8545; }
caddy_node_info_needs_edit() { return 1; }
caddy_meta_record() { rec meta; }
caddy_node_info_advertise() {
    rec advertise
    [[ -z "${HB_FAIL:-}" ]] || die "node-info.yaml could not be edited"
}
caddy_node_unlock() { rec unlock; }
JSON_RPC_DOMAIN=rpc.example.org
JSON_MOVE_DASH=""
case "$1" in
    json-rpc-enable)  run_json_rpc_enable ;;
    json-rpc-disable) run_json_rpc_disable ;;
    json-disable)     run_json_disable ;;
    rpc-enable)       do_rpc_enable rpc.example.org "" ;;
    rpc-disable)      do_rpc_disable ;;
esac
DRV
fixture
# (in --json runs the last unlock is the EXIT trap's, caddy_exit_cleanup)
addon_run install-caddy json-rpc-enable
check "install-caddy --json rpc-enable: refresh after the last write, under the lock" "0 advertise meta refresh caddy_wait_say unlock unlock " "$RC $(calls)"
check "install-caddy --json rpc-enable: the refresh warning is an event before done, done ok" "yes yes" "$(warn_then_done) $(done_ok)"
addon_run install-caddy json-rpc-disable
check "install-caddy --json rpc-disable: refresh before the lock goes" "0 meta advertise refresh caddy_wait_say unlock unlock " "$RC $(calls)"
check "install-caddy --json rpc-disable: warning event before done" "yes yes" "$(warn_then_done) $(done_ok)"
addon_run install-caddy rpc-enable
check "install-caddy rpc-enable (menu): refresh, its warning a printed line" "0 advertise meta refresh caddy_wait_say unlock  yes" \
    "$RC $(calls) $([[ "$JS$ERR" == *"hb stub warning"* && "$JS" != *'"event"'* ]] && echo yes || echo no)"
addon_run install-caddy rpc-disable
check "install-caddy rpc-disable (menu): refresh" "0 meta advertise refresh caddy_wait_say unlock " "$RC $(calls)"
export HB_FAIL=1
addon_run install-caddy json-rpc-enable
check "install-caddy --json rpc-enable, node-info edit failed: no refresh, done ok:false" "1 advertise unlock  yes" \
    "$RC $(calls) $(printf '%s\n' "$JS" | tail -n 1 | grep -q '"event":"done","ok":false' && echo yes || echo no)"
addon_run install-caddy rpc-disable
check "install-caddy rpc-disable, node-info edit failed: no refresh" "1 meta advertise " "$RC $(calls)"
unset HB_FAIL
addon_run install-caddy json-disable
check "install-caddy --json dashboard disable: no refresh (nothing the baseline covers)" "0 unlock  yes" "$RC $(calls) $(done_ok)"
export HB_NOLIB=1
addon_run install-caddy json-rpc-enable
check "install-caddy --json rpc-enable, lib without tn_host_baseline_refresh: rc 0, done ok, silent" "0 yes yes" "$RC $(done_ok) $(no_cnf)"
unset HB_NOLIB
check "install-caddy: the refresh sits in do_rpc_enable and do_rpc_disable only" "2" \
    "$(grep -c '^    caddy_baseline_refresh$' "$TN_TEST_REPO/install-caddy.sh")"

# --- firewall-setup.sh: the menu enable, --json --enable, the health sources --------
cat > "$T/firewall-setup/drv.sh" <<'DRV'
source "$HB_DRV/firewall-setup/firewall-setup.sh"
set +e
source "$HB_DRV/hbstub.sh"
apply_recommended_firewall() { rec apply; return "${HB_APPLY_RC:-0}"; }
for f in fw_meta_lock fw_wants_meta_write ufw_installed ufw_active print_header; do
    eval "${f}() { return 0; }"
done
fw_persist_sources() { rec persist; }
get_ssh_port() { echo 22; }
detect_installed_nodes() { echo none; }
fw_sources() { :; }
get_current_ip() { :; }
confirm() { return "${HB_CONFIRM:-0}"; }
is_testnet_like() { return 1; }
caddy_serves_public_edge() { return 1; }
kuma_extra_list() { printf '%s\n' "${HB_EXTRAS:-}"; }
kuma_extra_add() { rec "extra_add $1"; return "${HB_EXTRA_RC:-0}"; }
kuma_extra_remove() { rec "extra_remove $1"; }
case "$1" in
    json)  JSON_MODE=true; json_setup_fds; json_fw_enable ;;
    menu)  enable_firewall ;;
    extra) manage_health_extra_ips ;;
esac
DRV
addon_run firewall-setup json
check "firewall-setup --json --enable: refresh after the source lists are stored" "0 apply persist refresh fw_baseline_say " "$RC $(calls)"
check "firewall-setup --json --enable: warning event before done, done ok" "yes yes" "$(warn_then_done) $(done_ok)"
export HB_APPLY_RC=2
addon_run firewall-setup json
unset HB_APPLY_RC
check "firewall-setup --json --enable, apply failed: no refresh, done ok:false" "2 apply  yes" \
    "$RC $(calls) $(printf '%s\n' "$JS" | tail -n 1 | grep -q '"event":"done","ok":false' && echo yes || echo no)"
answers "" ""
addon_run firewall-setup menu
check "firewall-setup menu enable: refresh after the apply, its warning printed" "0 apply persist refresh fw_baseline_say  yes" \
    "$RC $(calls) $([[ "$JS$ERR" == *"hb stub warning"* ]] && echo yes || echo no)"
export HB_CONFIRM=1
answers "" ""
addon_run firewall-setup menu
unset HB_CONFIRM
check "firewall-setup menu enable cancelled: no refresh" "" "$(calls)"
answers 1 203.0.113.9 3
addon_run firewall-setup extra
check "firewall-setup health source added: refresh" "extra_add 203.0.113.9 refresh fw_baseline_say " "$(calls)"
export HB_EXTRA_RC=1
answers 1 bogus 3
addon_run firewall-setup extra
unset HB_EXTRA_RC
check "firewall-setup health source refused: no refresh" "extra_add bogus " "$(calls)"
export HB_EXTRAS=203.0.113.9
answers 2 203.0.113.9 3
addon_run firewall-setup extra
unset HB_EXTRAS
check "firewall-setup health source removed: refresh" "extra_remove 203.0.113.9 refresh fw_baseline_say " "$(calls)"
export HB_NOLIB=1
addon_run firewall-setup json
unset HB_NOLIB
check "firewall-setup --json --enable, lib without tn_host_baseline_refresh: rc 0, done ok, silent" "0 yes yes" "$RC $(done_ok) $(no_cnf)"
check "firewall-setup: every change that writes a covered file refreshes (menu, --json, CLI, node ports, health sources, P2P committee on, sync and off)" "10" \
    "$(grep -c '^ *fw_baseline_refresh$' "$TN_TEST_REPO/firewall-setup.sh")"

# --- setup-vpn.sh: enable, --sync-keys with a root flag, --disable -----------------
cat > "$T/setup-vpn/drv.sh" <<'DRV'
source "$HB_DRV/setup-vpn/setup-vpn.sh"
set +e
source "$HB_DRV/hbstub.sh"
for f in print_header consent_gate addon_meta_write_begin addon_meta_lock prompt_overlay_ip vpn_tnadmin_home_safe \
         capture_sshd_posture run_bootstrap write_tnadmin_keys write_scoped_sshd verify_sshd_unchanged \
         do_apply_firewall nudge_handshake print_enrollment write_tnadmin_sudoers vpn_remove_selfheal \
         systemctl sshd userdel getent; do
    eval "${f}() { return 0; }"
done
wg-quick() { return 0; }
ufw_installed() { return 1; }
vpn_root_grant_wanted() { echo false; }
assemble_pubkeys() { TNADMIN_INSTALL="${HB_KEYS-key}"; }
persist_state() { rec persist; }
install_selfheal_units() { rec selfheal; }
meta_set() { rec "meta $1=$2"; }
confirm() { return "${HB_CONFIRM:-0}"; }
vpn_init_paths
VPN_META="$TN_ROOT_PREFIX/etc/telcoin/.node-meta"
case "$1" in
    enable)    do_enable ;;
    sync-keys) ROOT_GRANT="${2:-}"; do_sync_keys ;;
    disable)   do_disable ;;
esac
DRV
addon_run setup-vpn enable
check "setup-vpn enable: refresh after the last write, its warning printed" "0 persist selfheal refresh yes" \
    "$RC $(calls)$([[ "$JS$ERR" == *"hb stub warning"* ]] && echo yes || echo no)"
export HB_KEYS=""
addon_run setup-vpn enable
unset HB_KEYS
check "setup-vpn enable refused (every key blocked): no refresh" "1 " "$RC $(calls)"
addon_run setup-vpn sync-keys
check "setup-vpn --sync-keys without a root flag: no refresh (no covered file)" "0 selfheal " "$RC $(calls)"
addon_run setup-vpn sync-keys grant
check "setup-vpn --sync-keys --grant-maintainer-root: refresh after the .node-meta write" "0 meta VPN_MAINTAINER_ROOT=false refresh selfheal " "$RC $(calls)"
addon_run setup-vpn disable
check "setup-vpn --disable: refresh after ENABLE_VPN=false" "0 meta ENABLE_VPN=false refresh " "$RC $(calls)"
export HB_CONFIRM=1
addon_run setup-vpn disable
unset HB_CONFIRM
check "setup-vpn --disable cancelled: no refresh" "0 " "$RC $(calls)"
export HB_NOLIB=1
addon_run setup-vpn enable
unset HB_NOLIB
check "setup-vpn enable, lib without tn_host_baseline_refresh: rc 0, silent" "0 yes" "$RC $(no_cnf)"

# --- setup-observability.sh: --json, --rotate-token, the menu actions ---------------
cat > "$T/setup-observability/drv.sh" <<'DRV'
source "$HB_DRV/setup-observability/setup-observability.sh"
set +e
source "$HB_DRV/hbstub.sh"
for f in check_root detect_distro load_node_context require_testnet so_write_begin addon_meta_write_begin \
         addons_lib_check so_meta_check _obs_prompt_region pause print_header json_need_node \
         health_firewall_ready health_restart_window systemctl; do
    eval "${f}() { return 0; }"
done
ufw_installed() { return 1; }
so_meta() { echo false; }
_obs_collect_token() { _OBS_TOKEN=tok; }
confirm() { return 0; }
obs_enable() { rec enable; return "${HB_RC:-0}"; }
obs_disable_logs() { rec disable_logs; return "${HB_RC:-0}"; }
obs_rotate_token() { rec rotate; return "${HB_RC:-0}"; }
tn_node_launch_target() { printf 'telcoin release %s\n' "$HB_T/launch"; }
health_flag_add() { rec flag; return 0; }
health_flag_live() { return "${HB_RC:-0}"; }
meta_set() { rec "meta $1=$2"; }
node_meta_path() { printf '%s\n' "$TN_ROOT_PREFIX/etc/telcoin/.node-meta"; }
case "$1" in
    json|json-rotate)
        JSON_MODE=true
        json_setup_fds
        trap json_on_exit EXIT
        if [[ "$1" == json ]]; then
            JSON_DISABLE_LOGS=true
        else
            JSON_ROTATE_TOKEN=true
            JSON_TOKEN=newtok
        fi
        run_json_mode
        ;;
    rotate-cli) JSON_TOKEN=newtok; run_rotate_cli ;;
    *) "$1" ;;
esac
DRV
addon_run setup-observability json
check "setup-observability --json: refresh after the actions, before done" "0 disable_logs refresh addons_say " "$RC $(calls)"
check "setup-observability --json: warning event before done, done ok" "yes yes" "$(warn_then_done) $(done_ok)"
addon_run setup-observability json-rotate
check "setup-observability --json --rotate-token: refresh" "0 rotate refresh addons_say  yes" "$RC $(calls) $(done_ok)"
addon_run setup-observability rotate-cli
check "setup-observability --rotate-token: refresh, rc 0" "0 rotate refresh addons_say " "$RC $(calls)"
for a in enable_logging disable_logging rotate_token; do
    answers newtok
    addon_run setup-observability "$a"
    check "setup-observability menu ${a}: refresh after it went through" "refresh addons_say " "$(calls | sed 's/^[a-z_]* //')"
done
addon_run setup-observability enable_health
check "setup-observability menu enable_health: refresh once the flag is on and recorded" "flag meta ENABLE_HEALTHCHECK_MONITOR=true refresh addons_say " "$(calls)"
addon_run setup-observability disable_health
check "setup-observability menu disable_health: refresh" "meta ENABLE_HEALTHCHECK_MONITOR=false refresh addons_say " "$(calls)"
export HB_RC=1
addon_run setup-observability json
check "setup-observability --json, the disable failed: no refresh, done ok:false" "1 disable_logs  yes" \
    "$RC $(calls) $(printf '%s\n' "$JS" | tail -n 1 | grep -q '"event":"done","ok":false' && echo yes || echo no)"
addon_run setup-observability rotate-cli
check "setup-observability --rotate-token refused: no refresh, rc 1" "1 rotate " "$RC $(calls)"
for a in enable_logging disable_logging rotate_token; do
    answers newtok
    addon_run setup-observability "$a"
    check "setup-observability menu ${a} failed: no refresh" "" "$(calls | sed 's/^[a-z_]* //')"
done
addon_run setup-observability enable_health
check "setup-observability menu enable_health, flag not on the command: no refresh" "flag " "$(calls)"
unset HB_RC
export HB_NOLIB=1
addon_run setup-observability json
unset HB_NOLIB
check "setup-observability --json, lib without tn_host_baseline_refresh: rc 0, done ok, silent" "0 yes yes" "$RC $(done_ok) $(no_cnf)"
check "setup-observability: --json, --rotate-token and seven menu actions refresh" "9" \
    "$(grep -cE '^ *so_baseline_refresh$|; so_baseline_refresh; else ' "$TN_TEST_REPO/setup-observability.sh")"

finish
