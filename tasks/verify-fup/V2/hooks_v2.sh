#!/usr/bin/env bash
# =============================================================================
# V2 independent harness, AUDIT package, script part: where the scripts call the
# host-baseline library. update-node refreshes on every apply that verified
# (docker, source, release; interactive and --json) and not on a failed verify,
# a rollback, a kept unverified release, a committee refusal or a one-way verify
# failure; edit-config on --set and menu restarts that came back healthy and on a
# passphrase move with rc 0 (c4322d4), not on a refusal, an unhealthy restart or
# "restart later"; remove-node tears down before the directories go on every
# path; setup-node --host-baseline (step, --json finalize done key, the
# baseline-only re-run). Older-library skew: a lib/common.sh without
# tn_host_baseline_* behind the new scripts, and the real lib of 0a9db45.
#   V2_REPO=<repo root> bash tasks/verify-fup/V2/hooks_v2.sh
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
ORIG_PATH="$PATH"
v2_cleanup() {
    PATH="$ORIG_PATH"
    tn_test_cleanup
    if [[ -n "$BASE" && "$BASE" != "$T"* && -d "$BASE" ]]; then rm -rf "${BASE:?}"; fi
}
trap v2_cleanup EXIT
if [[ $IS_ROOT == 1 ]]; then
    BASE="$(mktemp -d /root/.v2h.XXXXXX)"
    chmod 0700 "$BASE"
else
    BASE="$T/base"
    mkdir -p "$BASE"
fi
FX="$BASE/fx"
LOG="$BASE/log"
BIN="$BASE/bin"
mkdir -p "$LOG" "$BIN"
export V2_FX="$FX" V2_LOG="$LOG"
REAL_CAT="$(command -v cat)"
for c in systemctl sleep docker userdel groupdel deluser delgroup gpasswd journalctl ufw; do
    printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "%s/calls"\ncase "%s:$1" in systemctl:is-active) exit "$(cat "%s/active" 2>/dev/null || echo 0)" ;; esac\nexit 0\n' \
        "$c" "$LOG" "$c" "$LOG" > "$BIN/$c"
    chmod 0755 "$BIN/$c"
done
export PATH="$BIN:$PATH"

# mkh NAME LIBDIR -- the four scripts without their main line, lib -> LIBDIR.
mkh() {
    local h="$BASE/h-$1" s
    mkdir -p "$h"
    for s in update-node.sh edit-config.sh remove-node.sh setup-node.sh; do
        grep -v '^main "\$@"$' "$V2_REPO/$s" > "$h/$s"
    done
    # Seam: the source apply's installed binary lives in the fixture (DEFAULT_INSTALL_DIR is readonly /opt/telcoin).
    sed -i.bak 's|local installed="${DEFAULT_INSTALL_DIR}/telcoin-network"|local installed="${V2_INSTALLED}"|' "$h/update-node.sh"
    rm -f "${h:?}/update-node.sh.bak"
    ln -s "$2" "$h/lib"
    printf '%s\n' "$h"
}
H_NEW="$(mkh new "$V2_REPO/lib")"
# A library without tn_host_baseline_* (and without its call in tn_host_audit).
mkdir -p "$BASE/lib-nohb"
for f in "$V2_REPO"/lib/*; do
    [[ "${f##*/}" == common.sh ]] || ln -s "$f" "$BASE/lib-nohb/${f##*/}"
done
awk '
    /^tn_host_baseline_(install|refresh|remove|status)\(\) \{$/ { skip = 1; next }
    skip && /^\}$/ { skip = 0; next }
    skip { next }
    /^    tn_host_baseline_status \|\| warn=1$/ { next }
    { print }
' "$V2_REPO/lib/common.sh" > "$BASE/lib-nohb/common.sh"
H_NOHB="$(mkh nohb "$BASE/lib-nohb")"
H_OLD=""
if [[ -n "${V2_OLDLIB:-}" && -d "${V2_OLDLIB:-}" ]]; then
    H_OLD="$(mkh old "$V2_OLDLIB")"
fi

fx() {
    if [[ -d "$FX" ]]; then rm -rf "${FX:?}"; fi
    mkdir -p "$FX/etc/telcoin" "$FX/etc/systemd/system" "$FX/var/lib/telcoin/node-keys" "$FX/opt/telcoin" "$FX/run/telcoin"
    chmod 0755 "$FX" "$FX/etc" "$FX/etc/telcoin" "$FX/etc/systemd" "$FX/etc/systemd/system"
    printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nINSTALL_METHOD=docker\nDATA_DIR=%s\nHOST_BASELINE=true\n' "$FX/var/lib/telcoin" > "$FX/etc/telcoin/.node-meta"
    chmod 0600 "$FX/etc/telcoin/.node-meta"
    printf '[Service]\nExecStart=/usr/local/libexec/telcoin/tn-start-docker\n' > "$FX/etc/systemd/system/telcoin.service"
    rm -f "${LOG:?}/calls" "${LOG:?}/rc" "${LOG:?}/vh" "${LOG:?}/active"
    : > "$LOG/calls"
}
# drv H SCRIPT CASE -- run one case; OUT (stdout: the JSON stream in --json mode),
# ERR, CALLS, RC.
drv() {
    V2_H="$1" bash "$V2_DIR/hooks_drv.sh" "$2" "$3" > "$LOG/out" 2> "$LOG/err"
    DRV_RC=$?
    OUT="$("$REAL_CAT" "$LOG/out")"
    ERR="$("$REAL_CAT" "$LOG/err")"
    CALLS="$("$REAL_CAT" "$LOG/calls")"
    RC="$("$REAL_CAT" "$LOG/rc" 2>/dev/null || echo none)"
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
nref() { printf '%s\n' "$CALLS" | grep -c '^REFRESH' || true; }
# json_only TEXT -- the lines of TEXT that are not JSON events (empty: all are).
json_only() { printf '%s\n' "$1" | grep -v '^{"event":"' | grep -v '^$' || true; }

# ---- update-node ---------------------------------------------------------------
echo "== AUDIT hooks: update-node"
built="$BASE/built-bin"; printf 'new binary\n' > "$built"
export V2_BUILT="$built" V2_BUILT_HASH="$(sha256sum "$built" | awk '{print $1}')" V2_INSTALLED="$BASE/installed-bin"
for method in docker source release; do
    fn=docker; [[ "$method" == docker ]] || fn=source
    export V2_METHOD="$method"
    for mode in interactive json; do
        c="$fn"; jm=0
        if [[ "$mode" == json ]]; then c="json_$fn"; jm=1; fi
        export V2_JSON=$jm
        lbl="update-node ${method} ${mode}"
        # success
        fx; printf 'old binary\n' > "$V2_INSTALLED"
        unset V2_VERIFY V2_EPOCH V2_SM V2_RBHEALTH V2_CONFIRM
        drv "$H_NEW" un "$c"
        check "${lbl}, verified: rc 0" 0 "$RC"
        check "${lbl}, verified: refreshed once with the script's printer" "REFRESH update_wait_say" "$(printf '%s\n' "$CALLS" | grep '^REFRESH')"
        check "${lbl}, verified: refresh after the new release is recorded" yes \
            "$(printf '%s\n' "$CALLS" | awk '/^record-(meta|ref)/ { r = 1 } /^REFRESH/ { print (r ? "yes" : "no"); exit }')"
        if [[ $jm == 1 ]]; then
            check "${lbl}, verified: stdout is JSON events only" "" "$(json_only "$OUT")"
            check "${lbl}, verified: the refresh warning is an event before done" yes \
                "$(printf '%s\n' "$OUT" | awk '/V2-REFRESH-MARK/ { w = 1 } /"event":"done"/ { print (w ? "yes" : "no"); exit }')"
            check "${lbl}, verified: done ok true" yes "$(has "$OUT" '"event":"done","ok":true,"phase":"apply"')"
        else
            check "${lbl}, verified: the refresh warning printed" yes "$(has "$ERR$OUT" "V2-REFRESH-MARK")"
        fi
        # verify fails, rollback (json: always; interactive: confirmed)
        fx; printf 'old binary\n' > "$V2_INSTALLED"
        export V2_VERIFY=fail V2_CONFIRM=yes
        drv "$H_NEW" un "$c"
        check "${lbl}, verify failed and rolled back: no refresh" "0 yes" "$(nref) $(has "$CALLS" restore)"
        if [[ $jm == 0 ]]; then
            fx; printf 'old binary\n' > "$V2_INSTALLED"
            export V2_CONFIRM=no
            drv "$H_NEW" un "$c"
            check "${lbl}, verify failed, operator keeps the new release: no refresh" 0 "$(nref)"
            V2_KEEP_OUT="$OUT$ERR"
        fi
        # committee refusal before the stop
        fx; printf 'old binary\n' > "$V2_INSTALLED"
        unset V2_VERIFY V2_CONFIRM; export V2_EPOCH=refuse
        drv "$H_NEW" un "$c"
        check "${lbl}, committee refused the stop: rc 1, no stop, no refresh" "1 no 0" "$RC $(has "$CALLS" stop) $(nref)"
        # one-way update whose verify failed
        fx; printf 'old binary\n' > "$V2_INSTALLED"
        unset V2_EPOCH; export V2_VERIFY=fail V2_SM=true
        drv "$H_NEW" un "$c"
        check "${lbl}, one-way verify failed: no refresh" "1 0" "$RC $(nref)"
        unset V2_VERIFY V2_SM
        # older library: the hook is a no-op, not an error
        fx; printf 'old binary\n' > "$V2_INSTALLED"
        V2_NOSTUB=1 drv "$H_NOHB" un "$c"
        check "${lbl}, library without tn_host_baseline_*: rc 0, no error" "0 no" "$RC $(has "$ERR$OUT" "command not found")"
    done
done
unset V2_JSON V2_METHOD

# ---- edit-config ---------------------------------------------------------------
echo "== AUDIT hooks: edit-config"
for jm in 0 1; do
    export V2_JSON=$jm
    lbl="edit-config --set$([[ $jm == 1 ]] && echo ' --json')"
    fx; printf '0\n' > "$LOG/active"
    drv "$H_NEW" ec set
    check "${lbl}, healthy restart: refreshed once" "0 REFRESH edit_wait_say" "$RC $(printf '%s\n' "$CALLS" | grep '^REFRESH')"
    if [[ $jm == 1 ]]; then
        check "${lbl}: stdout JSON only" "" "$(json_only "$OUT")"
        check "${lbl}: refresh warning before done" yes "$(printf '%s\n' "$OUT" | awk '/V2-REFRESH-MARK/ { w = 1 } /"event":"done"/ { print (w ? "yes" : "no"); exit }')"
    fi
    fx; printf '3\n' > "$LOG/active"
    drv "$H_NEW" ec set
    check "${lbl}, unhealthy restart rolled back: no refresh" "1 0 yes" "$RC $(nref) $(has "$CALLS" restore-backups)"
    fx; printf '0\n' > "$LOG/active"; export V2_EPOCH=refuse
    drv "$H_NEW" ec set
    check "${lbl}, committee refused: no refresh, put back" "1 0 yes" "$RC $(nref) $(has "$CALLS" restore-backups)"
    unset V2_EPOCH
    fx; printf '0\n' > "$LOG/active"
    V2_NOSTUB=1 drv "$H_NOHB" ec set
    check "${lbl}, library without tn_host_baseline_*: rc 0, no error" "0 no" "$RC $(has "$ERR$OUT" "command not found")"
done
export V2_JSON=0
fx; printf '0\n' > "$LOG/active"; export V2_CONFIRM=yes
drv "$H_NEW" ec menu
check "edit-config menu restart, active: refreshed once" "REFRESH edit_wait_say" "$(printf '%s\n' "$CALLS" | grep '^REFRESH')"
fx; printf '3\n' > "$LOG/active"
drv "$H_NEW" ec menu
check "edit-config menu restart, not active: no refresh" 0 "$(nref)"
fx; printf '0\n' > "$LOG/active"; export V2_CONFIRM=no
drv "$H_NEW" ec menu
check "edit-config menu 'restart later': no refresh" "0 yes" "$(nref) $(has "$ERR$OUT" "Restart the node when ready")"
export V2_CONFIRM=yes V2_EPOCH=refuse
fx; drv "$H_NEW" ec menu
check "edit-config menu, committee refused (no backups): no refresh" 0 "$(nref)"
fx; drv "$H_NEW" ec menu_bk
check "edit-config menu, committee refused (put back): no refresh" 0 "$(nref)"
unset V2_EPOCH
# The menu's Restart node after a 'restart later' edit: the restarted node runs the
# edit, and the baseline is not made again.
fx; printf '0\n' > "$LOG/active"
drv "$H_NEW" ec restart_node
V2_RESTART_NODE_REFRESH="$(nref)"
check "[finding A-5] edit-config menu Restart node (after a 'restart later' edit): refresh" 1 "$(nref)"
for crc in 0 1 2 3; do
    fx; export V2_CRED_RC=$crc
    drv "$H_NEW" ec cred
    exp=0; [[ $crc != 0 ]] || exp=1
    check "edit-config passphrase move rc ${crc} (c4322d4): refreshes ${exp}" "$exp" "$(nref)"
done
fx; export V2_CRED_RC=0
V2_NOSTUB=1 drv "$H_NOHB" ec cred
check "edit-config passphrase move, library without tn_host_baseline_*: no error" no "$(has "$ERR$OUT" "command not found")"
unset V2_CRED_RC V2_CONFIRM

# ---- remove-node ---------------------------------------------------------------
echo "== AUDIT hooks: remove-node"
export V2_DD="$FX/var/lib/telcoin"
fx; drv "$H_NEW" rm stop
check "remove-node stop_and_disable_service: teardown first, unit and dirs still there" \
    "TEARDOWN fn= unit=yes conf=yes data=yes" "$(printf '%s\n' "$CALLS" | grep '^TEARDOWN')"
check "remove-node stop_and_disable_service: teardown before the stop" yes \
    "$(printf '%s\n' "$CALLS" | awk '/^TEARDOWN/ { t = 1 } /^systemctl stop/ { print (t ? "yes" : "no"); exit }')"
fx; drv "$H_NEW" rm stop_empty
check "remove-node stop_and_disable_service '' (leftovers): teardown" 1 "$(printf '%s\n' "$CALLS" | grep -c '^TEARDOWN' || true)"
fx; V2_NOSTUB=1 drv "$H_NOHB" rm stop
check "remove-node, library without tn_host_baseline_*: no error" "0 no" "$RC $(has "$ERR$OUT" "command not found")"
if [[ $IS_ROOT == 1 ]]; then
    for sc in service data keys; do
        fx; export V2_JSON=1
        drv "$H_NEW" rm "json_${sc}"
        check "remove-node --json --scope ${sc}: teardown once, before the dirs go" "TEARDOWN fn= unit=yes conf=yes data=yes" "$(printf '%s\n' "$CALLS" | grep '^TEARDOWN')"
        check "remove-node --json --scope ${sc}: stdout JSON only" "" "$(json_only "$OUT")"
    done
    # The real teardown in --json mode: what the event stream says about it.
    fx; mkdir -p "$FX/etc/audit/rules.d" "$FX/etc/aide" "$FX/var/lib/aide"
    printf -- '-w x\n' > "$FX/etc/audit/rules.d/telcoin-node.rules"; : > "$FX/etc/aide/telcoin-node.conf"; : > "$FX/var/lib/aide/telcoin-node.db"
    V2_NOSTUB=1 drv "$H_NEW" rm json_service
    check "remove-node --json (real teardown): baseline files gone" "no no no" \
        "$([[ -e "$FX/etc/audit/rules.d/telcoin-node.rules" ]] && echo yes || echo no) $([[ -e "$FX/etc/aide/telcoin-node.conf" ]] && echo yes || echo no) $([[ -e "$FX/var/lib/aide/telcoin-node.db" ]] && echo yes || echo no)"
    check "remove-node --json (real teardown): marker gone" no "$(has "$("$REAL_CAT" "$FX/etc/telcoin/.node-meta" 2>/dev/null)" HOST_BASELINE)"
    V2_RM_JSON_OUT="$OUT"
    check "[finding A-4] remove-node --json (real teardown): the event stream says the packages stay" yes "$(has "$OUT" "packages stay installed")"
    export V2_JSON=0
    fx; drv "$H_NEW" rm menu
    check "remove-node menu removal: teardown before the dirs go" "TEARDOWN fn= unit=yes conf=yes data=yes" "$(printf '%s\n' "$CALLS" | grep '^TEARDOWN' | head -1)"
    fx; rm -f "${FX:?}/etc/systemd/system/telcoin.service"; export V2_CONFIRM=yes
    drv "$H_NEW" rm leftovers
    check "remove-node leftovers: teardown runs" 1 "$(printf '%s\n' "$CALLS" | grep -c '^TEARDOWN' || true)"
    V2_LEFTOVERS_TEARDOWN="$(printf '%s\n' "$CALLS" | grep '^TEARDOWN')"
    unset V2_CONFIRM
else
    skip "remove-node --json scopes, menu, leftovers" "they delete under the fixture and run userdel stubs: root containers only"
fi

# ---- setup-node ----------------------------------------------------------------
echo "== AUDIT hooks: setup-node"
export V2_JSON=0
fx; export V2_INSTALL_RC=0
drv "$H_NEW" sn step
check "setup-node step_host_baseline: install called with setup_progress" "INSTALL setup_progress" "$(printf '%s\n' "$CALLS" | grep '^INSTALL')"
check "setup-node step_host_baseline: state installed, lock released" "STATE installed lock=false" "$(printf '%s\n' "$CALLS" | grep '^STATE')"
fx; export V2_INSTALL_RC=1
drv "$H_NEW" sn step
check "setup-node step_host_baseline, install failed: state failed, setup goes on" "STATE failed lock=false 0" "$(printf '%s\n' "$CALLS" | grep '^STATE') $RC"
check "setup-node step_host_baseline, install failed: warns with the re-run" yes "$(has "$ERR$OUT" "Try again with: sudo ./setup-node.sh --host-baseline")"
fx; export V2_HB=false
drv "$H_NEW" sn step
check "setup-node without --host-baseline: install not called" 0 "$(printf '%s\n' "$CALLS" | grep -c '^INSTALL' || true)"
unset V2_HB
export V2_JSON=1
for irc in 0 1; do
    fx; export V2_INSTALL_RC=$irc
    drv "$H_NEW" sn finalize
    want=true; [[ $irc == 0 ]] || want=false
    check "setup-node --json finalize, install rc ${irc}: done carries host_baseline ${want}" yes "$(has "$OUT" "\"host_baseline\":${want},")"
    check "setup-node --json finalize, install rc ${irc}: stdout JSON only" "" "$(json_only "$OUT")"
    check "setup-node --json finalize, install rc ${irc}: install after the service exists" yes \
        "$(printf '%s\n' "$CALLS" | awk '/^create-service/ { c = 1 } /^INSTALL/ { print (c ? "yes" : "no"); exit }')"
    if [[ $irc == 1 ]]; then
        check "setup-node --json finalize, install failed: WARNING log event" yes "$(has "$OUT" '"event":"log","msg":"WARNING: The host baseline was not made')"
    fi
done
fx; export V2_HB=false V2_INSTALL_RC=0
drv "$H_NEW" sn finalize
check "setup-node --json finalize without the flag: host_baseline false, no install" "yes 0" "$(has "$OUT" '"host_baseline":false,') $(printf '%s\n' "$CALLS" | grep -c '^INSTALL' || true)"
unset V2_HB
export V2_JSON=0
fx; export V2_INSTALL_RC=0
drv "$H_NEW" sn main_only
check "setup-node --host-baseline on an installed node: baseline only" "rc=0 INSTALL setup_progress no" "rc=$DRV_RC $(printf '%s\n' "$CALLS" | grep '^INSTALL') $(has "$CALLS" FULL-SETUP)"
fx; export V2_INSTALL_RC=1
drv "$H_NEW" sn main_only
check "setup-node --host-baseline on an installed node, failed: rc 1, says nothing else changed" "rc=1 yes" "rc=$DRV_RC $(has "$ERR$OUT" "Nothing else on this host was changed.")"
fx; rm -f "${FX:?}/etc/systemd/system/telcoin.service"; export V2_INSTALL_RC=0
drv "$H_NEW" sn main_only
check "setup-node --host-baseline with no node: the full setup runs" "yes 0" "$(has "$CALLS" FULL-SETUP) $(printf '%s\n' "$CALLS" | grep -c '^INSTALL' || true)"
unset V2_INSTALL_RC

# ---- the real 0a9db45 library behind the new scripts ----------------------------
if [[ -n "$H_OLD" ]]; then
    echo "== the library of 0a9db45 behind the new scripts"
    for s in un ec rm; do
        fx
        case "$s" in un) c=docker ;; ec) c=cred ;; rm) c=stop ;; esac
        export V2_METHOD=docker V2_CRED_RC=0
        V2_NOSTUB=1 drv "$H_OLD" "$s" "$c"
        printf 'old lib, %s %s: driver rc %s, case rc %s, first error: %s\n' "$s" "$c" "$DRV_RC" "$RC" "$(printf '%s\n' "$ERR$OUT" | grep -m1 -E 'ERROR|error|not found' || true)"
        check "old lib 0a9db45 behind new ${s}: no 'command not found' from the hooks" no "$(has "$ERR$OUT" "tn_host_baseline")"
    done
    unset V2_METHOD V2_CRED_RC
fi
finish
