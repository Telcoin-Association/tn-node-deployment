#!/usr/bin/env bash
# shellcheck disable=SC2218  # cat is wrapped by a function later in this harness; the calls above it run the binary, as intended
# =============================================================================
# V2 independent harness, AUDIT package, library part: tn_host_baseline_install,
# _refresh, _remove, _status and the tn_host_audit lines, with recording stubs
# for apt-get, augenrules, auditctl, aide and systemctl (the real tools are hidden
# behind a PATH of symlinks that leaves them out). Files, modes, owners, paths,
# idempotence, the marker written before aide --init and removed on a failed
# init, refresh only with the marker, remove leaving the packages, the audit lines
# in each state as root and as a user. Adversarial: DATA_DIR with spaces, a
# duplicated HOST_BASELINE, aide without augenrules and the reverse, SIGTERM
# during aide --init, a library without tn_host_baseline_*.
#   V2_REPO=<repo root> bash tasks/verify-fup/V2/audit_v2.sh
# =============================================================================
set -u
V2_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2_REPO="${V2_REPO:-$(cd "$V2_DIR/../../.." && pwd)}"
# shellcheck source=/dev/null
. "$V2_REPO/tools/tests/lib.sh"
T="$TN_TEST_TMP"
IS_ROOT=0
[[ "$(id -u)" == 0 ]] && IS_ROOT=1
BASE=""
v2_cleanup() {
    tn_test_cleanup
    if [[ -n "$BASE" && "$BASE" != "$T"* && -d "$BASE" ]]; then rm -rf "${BASE:?}"; fi
}
trap v2_cleanup EXIT
if [[ $IS_ROOT == 1 ]]; then
    BASE="$(mktemp -d /root/.v2a.XXXXXX)"
    chmod 0700 "$BASE"
else
    BASE="$T/base"
    mkdir -p "$BASE"
fi
FX="$BASE/fx"
CTL="$BASE/ctl"
LOG="$BASE/log"
BIN="$BASE/bin"      # stubs always present (apt-get, systemctl)
IBIN="$BASE/ibin"    # what apt-get "installed" (augenrules, auditctl, aide)
SRC="$BASE/src"      # the stubs apt-get copies into IBIN
SYS="$BASE/sys"      # the system PATH without apt-get, aide, augenrules, auditctl
mkdir -p "$CTL" "$LOG" "$BIN" "$IBIN" "$SRC" "$SYS"
REAL_CAT="$(command -v cat)"
REAL_GREP="$(command -v grep)"
REAL_SLEEP="$(command -v sleep)"
REAL_MKDIR="$(command -v mkdir)"
REAL_CP="$(command -v cp)"
REAL_SED="$(command -v sed)"
IFS=: read -r -a _pd <<< "$PATH"
for d in "${_pd[@]}"; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do
        n="${f##*/}"
        case "$n" in apt-get|aide|aideinit|augenrules|auditctl|auditd) continue ;; esac
        [[ -e "$SYS/$n" || ! -x "$f" ]] || ln -s "$f" "$SYS/$n" 2>/dev/null
    done
done

# ---- stubs ---------------------------------------------------------------------
cat > "$BIN/apt-get" <<STUB
#!/bin/sh
printf '%s\n' "apt-get \$* DEBIAN_FRONTEND=\${DEBIAN_FRONTEND:-}" >> "$LOG/calls"
case "\$1" in
    install)
        [ -f "$CTL/apt_fail" ] && exit 100
        for t in \$("$REAL_CAT" "$CTL/apt_pkgs" 2>/dev/null || echo augenrules auditctl aide); do
            "$REAL_CP" "$SRC/\$t" "$IBIN/\$t"
        done
        [ -f "$CTL/no_rulesd" ] || "$REAL_MKDIR" -p "$FX/etc/audit/rules.d"
        exit 0 ;;
esac
exit 0
STUB
cat > "$BIN/systemctl" <<STUB
#!/bin/sh
printf '%s\n' "systemctl \$*" >> "$LOG/calls"
exit 0
STUB
# augenrules --load: the kernel gets every rules.d file (CTL/loaded), unless CTL/augen_fail.
cat > "$SRC/augenrules" <<STUB
#!/bin/sh
printf '%s\n' "augenrules \$*" >> "$LOG/calls"
[ -f "$CTL/augen_fail" ] && exit 1
"$REAL_CAT" "$FX"/etc/audit/rules.d/*.rules > "$CTL/loaded" 2>/dev/null || : > "$CTL/loaded"
exit 0
STUB
cat > "$SRC/auditctl" <<STUB
#!/bin/sh
printf '%s\n' "auditctl \$*" >> "$LOG/calls"
[ -f "$CTL/auditctl_fail" ] && exit 1
"$REAL_CAT" "$CTL/loaded" 2>/dev/null || echo "No rules"
exit 0
STUB
# aide --config=FILE --init|--update|--check: writes database_out (under FX) unless
# CTL/aide_nowrite; exit CTL/aide_rc; CTL/aide_sleep makes --init hang (SIGTERM case).
# Records whether .node-meta holds HOST_BASELINE=true at that moment.
cat > "$SRC/aide" <<STUB
#!/bin/sh
conf=""; mode=""
for a in "\$@"; do case "\$a" in --config=*) conf="\${a#--config=}" ;; --init|--update|--check) mode="\$a" ;; esac; done
m=no; "$REAL_GREP" -qx 'HOST_BASELINE=true' "$FX/etc/telcoin/.node-meta" 2>/dev/null && m=yes
printf '%s\n' "aide \$* marker=\$m" >> "$LOG/calls"
[ -f "$CTL/aide_sleep" ] && [ "\$mode" = --init ] && "$REAL_SLEEP" 30
out="\$("$REAL_SED" -n 's/^database_out=file://p' "\$conf" 2>/dev/null)"
if [ -n "\$out" ] && [ ! -f "$CTL/aide_nowrite" ] && [ "\$mode" != --check ]; then
    printf 'aide-db %s\n' "\$mode" > "$FX\$out"
fi
exit "\$("$REAL_CAT" "$CTL/aide_rc" 2>/dev/null || echo 0)"
STUB
chmod 0755 "$BIN"/* "$SRC"/*
export PATH="$BIN:$IBIN:$SYS"

# ---- the library ---------------------------------------------------------------
TN_ROOT_PREFIX="$FX"
eval "$(tn_test_source_common)"
PATH="$BIN:$IBIN:$SYS"
export TN_UPDATE_LOCK_FILE="$BASE/update.lock"

DDH="/var/lib/telcoin"
RULES="$FX/etc/audit/rules.d/telcoin-node.rules"
ACONF="$FX/etc/aide/telcoin-node.conf"
ADB="$FX/var/lib/aide/telcoin-node.db"

# fx [DATA_DIR] -- a node tree under FX: .node-meta, the unit (credential form),
# node keys, /etc/telcoin files, an empty IBIN (nothing installed yet).
fx() {
    local dd="${1:-$DDH}"
    if [[ -d "$FX" ]]; then rm -rf "${FX:?}"; fi
    rm -f "${IBIN:?}"/* "${CTL:?}"/* "${LOG:?}/calls"
    hash -r
    mkdir -p "$FX/etc/telcoin/alloy" "$FX/etc/systemd/system" "$FX${dd}/node-keys" "$FX/opt/telcoin" \
        "$FX/usr/local/libexec/telcoin" "$FX/run/telcoin"
    chmod 0755 "$FX" "$FX/etc" "$FX/etc/telcoin" "$FX/etc/systemd" "$FX/etc/systemd/system" "$FX/opt" "$FX/usr" \
        "$FX/usr/local" "$FX/usr/local/libexec"
    printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nINSTALL_METHOD=docker\nDATA_DIR=%s\nPASSPHRASE_METHOD=credential\n' "$dd" \
        > "$FX/etc/telcoin/.node-meta"
    chmod 0600 "$FX/etc/telcoin/.node-meta"
    printf '[Service]\nLoadCredentialEncrypted=bls-passphrase:/etc/telcoin/bls-passphrase.cred\nExecStart=/usr/local/libexec/telcoin/tn-start-docker\n' \
        > "$FX/etc/systemd/system/telcoin.service"
    : > "$LOG/calls"
}
calls() { "$REAL_CAT" "$LOG/calls" 2>/dev/null; }
meta_lines() { "$REAL_GREP" -c '^HOST_BASELINE=' "$FX/etc/telcoin/.node-meta" 2>/dev/null || true; }
omode() { stat -c '%U:%G %a' -- "$1" 2>/dev/null || echo absent; }
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

echo "== AUDIT library (user $(id -un))"

# ---- refusals before anything is installed (all environments) ------------------
fx
out="$(PATH="$BIN:$IBIN:$SYS"; mv "${BIN:?}/apt-get" "${BIN:?}/apt-get.off"; tn_host_baseline_install 2>&1)"; rc=$?
mv "$BIN/apt-get.off" "$BIN/apt-get"
check_rc "install without apt-get: rc 1" 1 "$rc"
check "install without apt-get: says so" yes "$(has "$out" "The host baseline needs apt-get (Ubuntu or Debian)")"
check "install without apt-get: no marker" 0 "$(meta_lines)"

fx; rm -f "${FX:?}/etc/systemd/system/telcoin.service"
out="$(tn_host_baseline_install 2>&1)"; rc=$?
check_rc "install without a node unit: rc 1" 1 "$rc"
check "install without a node unit: message" yes "$(has "$out" "No node unit is installed")"
check "install without a node unit: apt-get not run" no "$(has "$(calls)" "apt-get install")"

fx; rm -rf "${FX:?}${DDH}/node-keys"
out="$(tn_host_baseline_install 2>&1)"; rc=$?
check_rc "install without node keys: rc 1" 1 "$rc"
check "install without node keys: message" yes "$(has "$out" "No node keys at ${DDH}/node-keys")"

fx; printf '[Service]\nEnvironment="TN_BLS_PASSPHRASE=V2-embedded-Secret-1"\nExecStart=/usr/bin/docker run --rm img telcoin node --http\n' > "$FX/etc/systemd/system/telcoin.service"
out="$(tn_host_baseline_install 2>&1)"; rc=$?
check_rc "install over a unit that holds the passphrase: rc 1" 1 "$rc"
check "install over a unit that holds the passphrase: points at --migrate-credential" yes "$(has "$out" "edit-config.sh --migrate-credential")"
check "install over a unit that holds the passphrase: secret not printed" no "$(has "$out" "V2-embedded-Secret-1")"

# Adversarial: DATA_DIR with a space.
fx "/var/lib/tel coin"
out="$(tn_host_baseline_install 2>&1)"; rc=$?
check_rc "install, DATA_DIR with a space: rc 1" 1 "$rc"
check "install, DATA_DIR with a space: names the path" yes "$(has "$out" "/var/lib/tel coin holds characters the audit rules and the AIDE config cannot name")"
check "install, DATA_DIR with a space: no rules file, no marker" "absent 0" "$(omode "$RULES") $(meta_lines)"

# Adversarial: DATA_DIR set twice.
fx; printf 'DATA_DIR=%s\n' "$DDH" >> "$FX/etc/telcoin/.node-meta"
out="$(tn_host_baseline_install 2>&1)"; rc=$?
check_rc "install, DATA_DIR twice: rc 1" 1 "$rc"
check "install, DATA_DIR twice: message" yes "$(has "$out" "DATA_DIR is set more than once in .node-meta")"

fx; : > "$CTL/apt_fail"
out="$(tn_host_baseline_install 2>&1)"; rc=$?
check_rc "install, apt-get fails: rc 1" 1 "$rc"
check "install, apt-get fails: retried after apt-get update" "apt-get install -y -q --no-install-recommends auditd aide DEBIAN_FRONTEND=noninteractive
apt-get update -q DEBIAN_FRONTEND=
apt-get install -y -q --no-install-recommends auditd aide DEBIAN_FRONTEND=noninteractive" "$(calls)"
check "install, apt-get fails: no marker" 0 "$(meta_lines)"

# Adversarial: aide installed but augenrules missing, and the reverse.
fx; printf 'auditctl aide\n' > "$CTL/apt_pkgs"
out="$(tn_host_baseline_install 2>&1)"; rc=$?
check_rc "install, aide without augenrules: rc 1" 1 "$rc"
check "install, aide without augenrules: names augenrules" yes "$(has "$out" "augenrules is missing after the install of auditd and aide")"
check "install, aide without augenrules: no marker, no rules" "0 absent" "$(meta_lines) $(omode "$RULES")"
fx; printf 'augenrules auditctl\n' > "$CTL/apt_pkgs"
out="$(tn_host_baseline_install 2>&1)"; rc=$?
check_rc "install, augenrules without aide: rc 1" 1 "$rc"
check "install, augenrules without aide: names aide" yes "$(has "$out" "aide is missing after the install of auditd and aide")"
check "install, augenrules without aide: no marker" 0 "$(meta_lines)"

# ---- the happy path (root: tn_write_root_file needs a root-owned tree) ---------
if [[ $IS_ROOT == 1 ]]; then
    fx
    out="$(tn_host_baseline_install 2>&1)"; rc=$?
    check_rc "install: rc 0" 0 "$rc"
    check "install: apt-get once, no recommends, noninteractive" "apt-get install -y -q --no-install-recommends auditd aide DEBIAN_FRONTEND=noninteractive" "$(calls | "$REAL_GREP" '^apt-get')"
    check "install: rules file root:root 0640" "root:root 640" "$(omode "$RULES")"
    check "install: rules text" "## Telcoin node host baseline (setup-node.sh --host-baseline); remove-node.sh removes this file.
-w /var/lib/telcoin/node-keys -p rwxa -k telcoin-keys
-w /etc/telcoin -p wa -k telcoin-config
-w /etc/systemd/system/telcoin.service -p wa -k telcoin-unit" "$("$REAL_CAT" "$RULES")"
    check "install: augenrules --load ran" yes "$(has "$(calls)" "augenrules --load")"
    check "install: AIDE config root:root 0600" "root:root 600" "$(omode "$ACONF")"
    acfg="$("$REAL_CAT" "$ACONF")"
    check_has "install: AIDE database_in" "database_in=file:/var/lib/aide/telcoin-node.db" "$acfg"
    check_has "install: AIDE database_out" "database_out=file:/var/lib/aide/telcoin-node.db.new" "$acfg"
    check_has "install: AIDE watches /opt/telcoin (anchored)" '/opt/telcoin(/|$) TnNode' "$acfg"
    check_has "install: AIDE watches the start scripts" '/usr/local/libexec/telcoin(/|$) TnNode' "$acfg"
    check_has "install: AIDE watches /etc/telcoin" '/etc/telcoin(/|$) TnNode' "$acfg"
    check_has "install: AIDE leaves out the passphrase file and credential" '!/etc/telcoin/(.*/)?bls-passphrase(\.cred)?(\.new)?$' "$acfg"
    check_has "install: AIDE leaves out the ingest token" '!/etc/telcoin/alloy/ingest-token$' "$acfg"
    check_has "install: AIDE watches the unit" '=/etc/systemd/system/telcoin\.service$ TnNode' "$acfg"
    check "install: aide --init ran once with the marker already set" "aide --config=${ACONF} --init marker=yes" "$(calls | "$REAL_GREP" '^aide')"
    check "install: database in place, .new gone" "aide-db --init absent" "$("$REAL_CAT" "$ADB") $(omode "$ADB.new")"
    check "install: /var/lib/aide made root 0700" "root:root 700" "$(omode "$FX/var/lib/aide")"
    check "install: /etc/aide made root 0755" "root:root 755" "$(omode "$FX/etc/aide")"
    check "install: one HOST_BASELINE=true line" "HOST_BASELINE=true" "$("$REAL_GREP" '^HOST_BASELINE=' "$FX/etc/telcoin/.node-meta")"
    check "install: .node-meta still root 0600" "root:root 600" "$(omode "$FX/etc/telcoin/.node-meta")"
    check "install: no loaded-rules warning (rules loaded)" no "$(has "$out" "did not load now")"
    r1="$("$REAL_CAT" "$RULES")"; a1="$("$REAL_CAT" "$ACONF")"
    : > "$LOG/calls"
    out="$(tn_host_baseline_install 2>&1)"; rc=$?
    check_rc "install again: rc 0" 0 "$rc"
    check "install again: same rules and AIDE config" "same same" "$([[ "$("$REAL_CAT" "$RULES")" == "$r1" ]] && echo same) $([[ "$("$REAL_CAT" "$ACONF")" == "$a1" ]] && echo same)"
    check "install again: baseline made again" "aide --config=${ACONF} --init marker=yes" "$(calls | "$REAL_GREP" '^aide')"
    check "install again: still one HOST_BASELINE line" 1 "$(meta_lines)"

    # status as root, all in place.
    out="$(tn_host_baseline_status)"; rc=$?
    check_rc "status, all in place: rc 0" 0 "$rc"
    check_has "status: marker line" "ok    host baseline: HOST_BASELINE=true in .node-meta" "$out"
    check_has "status: rules line" "ok    audit rules: /etc/audit/rules.d/telcoin-node.rules" "$out"
    check_has "status: rules loaded line" "ok    audit rules loaded (auditctl -l lists telcoin-keys)" "$out"
    check "status: baseline line with an age" yes "$(has "$out" "ok    AIDE baseline: /var/lib/aide/telcoin-node.db, made 0 day(s) ago")"
    out="$(tn_host_audit 2>&1)"
    check "tn_host_audit carries the baseline lines" yes "$(has "$out" "host baseline: HOST_BASELINE=true in .node-meta")"
    : > "$CTL/loaded"
    out="$(tn_host_baseline_status)"; rc=$?
    check_rc "status, rules not loaded: rc 1" 1 "$rc"
    check_has "status, rules not loaded: warn" "warn  audit rules not loaded (auditctl -l lists no telcoin-keys): sudo augenrules --load, and check that auditd runs" "$out"
    out="$(tn_host_audit 2>&1)"; rc=$?
    check_rc "tn_host_audit rc 1 when the baseline warns" 1 "$rc"
    "$REAL_CAT" "$RULES" > "$CTL/loaded"

    # refresh: aide --update, rename; exit 1-7 still counts; 14+ is a warning.
    : > "$LOG/calls"
    out="$(tn_host_baseline_refresh 2>&1)"; rc=$?
    check_rc "refresh: rc 0" 0 "$rc"
    check "refresh: aide --update ran" "aide --config=${ACONF} --update marker=yes" "$(calls | "$REAL_GREP" '^aide')"
    check "refresh: new database in place" "aide-db --update absent" "$("$REAL_CAT" "$ADB") $(omode "$ADB.new")"
    for arc in 1 5 7; do
        printf '%s\n' "$arc" > "$CTL/aide_rc"; printf 'old\n' > "$ADB"
        out="$(tn_host_baseline_refresh 2>&1)"; rc=$?
        check "refresh, aide exit ${arc} (differences): database replaced, rc 0" "aide-db --update rc=0" "$("$REAL_CAT" "$ADB") rc=$rc"
    done
    printf '17\n' > "$CTL/aide_rc"; printf 'old\n' > "$ADB"
    out="$(tn_host_baseline_refresh 2>&1)"; rc=$?
    check "refresh, aide exit 17: old database kept, .new removed, rc 0" "old absent rc=0" "$("$REAL_CAT" "$ADB") $(omode "$ADB.new") rc=$rc"
    check "refresh, aide exit 17: warns that the baseline describes the old files" yes "$(has "$out" "The AIDE baseline still describes the files from before this change; the change itself is in place.")"
    rm -f "${CTL:?}/aide_rc"
    : > "$CTL/aide_nowrite"; printf 'old\n' > "$ADB"
    out="$(tn_host_baseline_refresh 2>&1)"; rc=$?
    check "refresh, aide wrote no database: old kept, warning, rc 0" "old yes rc=0" "$("$REAL_CAT" "$ADB") $(has "$out" "aide --update failed (rc 0)") rc=$rc"
    rm -f "${CTL:?}/aide_nowrite"

    # install with a failed aide --init: marker removed again.
    fx; printf '17\n' > "$CTL/aide_rc"
    out="$(tn_host_baseline_install 2>&1)"; rc=$?
    check_rc "install, aide --init fails: rc 1" 1 "$rc"
    check "install, aide --init fails: init ran with the marker set" "aide --config=${ACONF} --init marker=yes" "$(calls | "$REAL_GREP" '^aide')"
    check "install, aide --init fails: marker removed, no database" "0 absent absent" "$(meta_lines) $(omode "$ADB") $(omode "$ADB.new")"
    check "install, aide --init fails: says HOST_BASELINE stays unset" yes "$(has "$out" "The AIDE baseline was not made, so HOST_BASELINE stays unset.")"
    rm -f "${CTL:?}/aide_rc"

    # augenrules --load fails: a warning, the baseline is still made.
    fx; : > "$CTL/augen_fail"
    out="$(tn_host_baseline_install 2>&1)"; rc=$?
    check_rc "install, augenrules --load fails: rc 0" 0 "$rc"
    check "install, augenrules --load fails: warns the rules load at the next boot" yes "$(has "$out" "auditd loads them at the next boot")"
    rm -f "${CTL:?}/augen_fail"

    # remove: everything goes but the packages and the directories.
    fx; tn_host_baseline_install >/dev/null 2>&1
    : > "$LOG/calls"
    out="$(tn_host_baseline_remove 2>&1)"; rc=$?
    check_rc "remove: rc 0" 0 "$rc"
    check "remove: rules, AIDE config and databases gone" "absent absent absent absent" "$(omode "$RULES") $(omode "$ACONF") $(omode "$ADB") $(omode "$ADB.new")"
    check "remove: rules reloaded" yes "$(has "$(calls)" "augenrules --load")"
    check "remove: marker gone" 0 "$(meta_lines)"
    check "remove: other .node-meta keys kept" yes "$(has "$("$REAL_CAT" "$FX/etc/telcoin/.node-meta")" "NETWORK=testnet")"
    check "remove: packages not purged" no "$(has "$(calls)" "apt-get")"
    check "remove: says the packages stay" yes "$(has "$out" "The auditd and aide packages stay installed; remove them with: sudo apt-get purge auditd aide")"
    check "remove: /etc/aide and /var/lib/aide stay" "root:root 755 root:root 700" "$(omode "$FX/etc/aide") $(omode "$FX/var/lib/aide")"
    out="$(tn_host_baseline_remove 2>&1)"; rc=$?
    check "remove again: silent, rc 0" "rc=0 " "rc=$rc $out"

    # Adversarial: augenrules gone at remove time (aide stays): the rules file goes,
    # and the kernel watches stay loaded until reboot.
    fx; tn_host_baseline_install >/dev/null 2>&1; rm -f "${IBIN:?}/augenrules"; hash -r; : > "$LOG/calls"
    out="$(tn_host_baseline_remove 2>&1)"; rc=$?
    check "remove without augenrules: rules file gone, rc 0" "absent rc=0" "$(omode "$RULES") rc=$rc"
    V2_REMOVE_NO_AUGEN_OUT="$out"
    check "[finding A-6] remove without augenrules: says the watches stay loaded until reboot" yes "$(has "$out" "stay loaded until the next boot")"
else
    skip "install happy path, refresh, remove (rename-based writes)" "tn_write_root_file needs a root-owned tree"
fi

# ---- refresh and status without root writes (all environments) ------------------
fx
"$REAL_MKDIR" -p "$FX/etc/aide" "$FX/var/lib/aide"
: > "$LOG/calls"
out="$(tn_host_baseline_refresh 2>&1)"; rc=$?
check "refresh without the marker: nothing, rc 0" "rc=0 calls= out=" "rc=$rc calls=$(calls) out=$out"
out="$(tn_host_baseline_status)"; rc=$?
check "status without the marker: one info line, rc 0" "rc=0 info  host baseline: off (sudo ./setup-node.sh --host-baseline adds auditd watches and an AIDE baseline)" "rc=$rc $out"
printf 'HOST_BASELINE=true\n' >> "$FX/etc/telcoin/.node-meta"
out="$(tn_host_baseline_refresh 2>&1)"; rc=$?
check "refresh, marker but aide not installed: warning, rc 0" "rc=0 yes" "rc=$rc $(has "$out" "HOST_BASELINE=true, but aide is not installed")"
"$REAL_CP" "$SRC/aide" "$IBIN/aide"
out="$(tn_host_baseline_refresh 2>&1)"; rc=$?
check "refresh, marker but no AIDE config: warning, rc 0" "rc=0 yes" "rc=$rc $(has "$out" "/etc/aide/telcoin-node.conf is missing")"
_tn_hb_aide_text /etc/systemd/system/telcoin.service > "$ACONF"
printf 'old\n' > "$ADB"
: > "$LOG/calls"
out="$(tn_host_baseline_refresh 2>&1)"; rc=$?
check "refresh with the marker (as $(id -un)): aide --update and rename" "rc=0 aide-db --update absent" "rc=$rc $("$REAL_CAT" "$ADB") $(omode "$ADB.new")"
# status with the marker: missing pieces are warnings.
out="$(tn_host_baseline_status)"; rc=$?
check_rc "status, marker but no rules file: rc 1" 1 "$rc"
check "status, marker but no rules file: warn line" yes "$(has "$out" "warn  audit rules: /etc/audit/rules.d/telcoin-node.rules is missing; make it again: sudo ./setup-node.sh --host-baseline")"
if [[ $IS_ROOT == 0 ]]; then
    "$REAL_MKDIR" -p "$FX/etc/audit/rules.d"; : > "$RULES"
    out="$(tn_host_baseline_status)"
    check_has "status as a user: auditctl not checked" "info  audit rules loaded: not checked (auditctl -l needs root)" "$out"
    chmod 0700 "$FX/var/lib/aide"; chmod 0600 "$ADB"; chmod 0000 "$FX/var/lib/aide"
    out="$(tn_host_baseline_status)"
    check_has "status as a user: /var/lib/aide unreadable is info, not missing" "info  AIDE baseline: not checked (/var/lib/aide is readable by root only)" "$out"
    chmod 0700 "$FX/var/lib/aide"
    # Adversarial: .node-meta root 0600 is unreadable to a user; the marker is set.
    chmod 0000 "$FX/etc/telcoin/.node-meta"
    out="$(tn_host_baseline_status)"; rc=$?
    V2_UNREADABLE_META_OUT="$out"
    check "[finding A-3] status as a user, .node-meta unreadable: not reported as off" no "$(has "$out" "host baseline: off")"
    chmod 0600 "$FX/etc/telcoin/.node-meta"
else
    skip "status as a user" "this run is root (the user run is the bash 5.3 host run)"
fi

# Adversarial: HOST_BASELINE twice in .node-meta.
fx
"$REAL_MKDIR" -p "$FX/etc/aide" "$FX/var/lib/aide" "$FX/etc/audit/rules.d"
"$REAL_CP" "$SRC/aide" "$SRC/augenrules" "$SRC/auditctl" "$IBIN/"
_tn_hb_aide_text /etc/systemd/system/telcoin.service > "$ACONF"; printf 'old\n' > "$ADB"; : > "$RULES"
printf 'HOST_BASELINE=true\nHOST_BASELINE=true\n' >> "$FX/etc/telcoin/.node-meta"
: > "$LOG/calls"
out="$(tn_host_baseline_refresh 2>&1)"; rc=$?
V2_DUP_REFRESH_OUT="$out"
check "[finding A-2] duplicated HOST_BASELINE: refresh says why it did nothing" yes "$(has "$out" "HOST_BASELINE")"
out="$(tn_host_baseline_status)"; rc=$?
V2_DUP_STATUS_OUT="$out"
check "[finding A-2] duplicated HOST_BASELINE: status does not say off" no "$(has "$out" "host baseline: off")"
out="$(tn_host_baseline_remove 2>&1)"; rc=$?
check "duplicated HOST_BASELINE: remove takes the files" "absent absent absent" "$(omode "$RULES") $(omode "$ACONF") $(omode "$ADB")"
if [[ $IS_ROOT == 1 ]]; then
    check "[finding A-2] duplicated HOST_BASELINE: remove clears the marker lines" 0 "$(meta_lines)"
fi

# Adversarial: SIGTERM while aide --init runs (root: the writes before it must work).
if [[ $IS_ROOT == 1 ]]; then
    fx; : > "$CTL/aide_sleep"
    tn_host_baseline_install > "$LOG/sig.out" 2>&1 &
    pid=$!
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        "$REAL_GREP" -q -- '--init' "$LOG/calls" 2>/dev/null && break
        "$REAL_SLEEP" 0.5
    done
    kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    pkill -f "$IBIN/aide" 2>/dev/null || true
    rm -f "${CTL:?}/aide_sleep"
    V2_SIG_STATE="marker=$(meta_lines) rules=$(omode "$RULES") conf=$(omode "$ACONF") db=$(omode "$ADB") new=$(omode "$ADB.new") tmp=$(ls -A "$FX/etc/telcoin" | "$REAL_GREP" -c '^\.tn\.' || true)"
    printf 'SIGTERM during aide --init leaves: %s\n' "$V2_SIG_STATE"
    check "SIGTERM during aide --init: no root-writer temp file left in /etc/telcoin" "0" "${V2_SIG_STATE##*tmp=}"
    out="$(tn_host_baseline_status)"; rc=$?
    check "SIGTERM during aide --init: status warns (marker set, database missing)" "1 yes" "$rc $(has "$out" "AIDE baseline: /var/lib/aide/telcoin-node.db is missing")"
else
    skip "SIGTERM during aide --init" "needs root"
fi

# tn_host_audit's rc follows the baseline lines: the rest of the audit is made clean
# (systemd 259, sysctls 0/1, no unit), then the status is stubbed ok and warn.
fx; rm -f "${FX:?}/etc/systemd/system/telcoin.service"
tn_systemd_version() { printf '259\n'; }
cat() {
    case "${1:-}" in
        /proc/sys/fs/suid_dumpable) printf '0\n' ;;
        /proc/sys/kernel/yama/ptrace_scope) printf '1\n' ;;
        /proc/sys/kernel/core_pattern) printf 'core\n' ;;
        *) "$REAL_CAT" "$@" ;;
    esac
}
tn_host_baseline_status() { printf '%-5s %s\n' ok "stub"; return 0; }
out="$(tn_host_audit 2>&1)"; rc_ok=$?
tn_host_baseline_status() { printf '%-5s %s\n' warn "stub"; return 1; }
out="$(tn_host_audit 2>&1)"; rc_warn=$?
unset -f cat
check "tn_host_audit: rc 0 with a clean baseline, rc 1 when only the baseline warns" "0 1" "$rc_ok $rc_warn"

# A library without tn_host_baseline_*: the script hooks are no-ops (see hooks_v2.sh).
check "the library defines the four entry points" "4" "$(declare -F | "$REAL_GREP" -cE ' tn_host_baseline_(install|refresh|remove|status)$')"
finish
