#!/usr/bin/env bash
# V2 driver for keys_v2.sh: one credential action of edit-config.sh in a fresh
# process. Inputs (environment, none secret): V2_REPO, V2_EDIT (edit-config.sh to
# test), V2_LIBDIR (lib/ to use), V2_FX (TN_ROOT_PREFIX), V2_LOG (logs), V2_CTL
# (stub control), V2_LAUNCH (TARGET_LAUNCH_FILE), V2_SU/V2_SG (service user and
# group), V2_DOWN (stub|real: the downstream writers). Typed passphrases arrive on
# stdin, as an operator types them. Writes V2_LOG/rc, V2_LOG/post, V2_LOG/calls.
set -u
CASE="$1"
# keys_v2.sh made H (edit-config.sh without its main line, lib -> V2_LIBDIR)
# before PATH got the recording wrappers.
H="${V2_HDIR:-$V2_LOG/h}"
TN_ROOT_PREFIX="$V2_FX"
CALLS="$V2_LOG/calls"
: > "$CALLS"
# shellcheck source=/dev/null
source "$H/edit-config.sh"
set +e
SERVICE_USER="$V2_SU"
SERVICE_GROUP="$V2_SG"
TARGET_SERVICE=telcoin
TARGET_SERVICE_FILE="$V2_FX/etc/systemd/system/telcoin.service"
TARGET_LAUNCH_FILE="$V2_LAUNCH"
TN_UPDATE_LOCK_FILE="$V2_LOG/update.lock"
TN_BACKUP_DIR="$V2_FX/backups"

v2_call() { printf '%s\n' "$*" >> "$CALLS"; }
# v2_passcheck NAME -- record whether TN_CRED_PASS holds the passphrase the action
# should keep (V2_CTL/keep), compared in this shell, and whether TN_KEYTOOL_PASS is
# still set or anything is exported. Never records a value.
v2_passcheck() {
    local keep="" st=empty kp=unset ex=no d
    IFS= read -r keep < "$V2_CTL/keep" 2>/dev/null || true
    if [[ -n "${TN_CRED_PASS:-}" ]]; then
        if [[ "$TN_CRED_PASS" == "$keep" ]]; then st=match; else st=other; fi
    fi
    keep=""
    declare -p TN_KEYTOOL_PASS >/dev/null 2>&1 && kp=set
    d="$(declare -p TN_CRED_PASS 2>/dev/null)" || d=""
    d="${d#declare -}"; d="${d%% *}"
    [[ "$d" != *x* ]] || ex=yes
    printf '%s pass=%s keytoolpass=%s exported=%s\n' "$1" "$st" "$kp" "$ex" >> "$CALLS"
}
# v2_wrap NAME -- record every call of library/script function NAME, then run it.
v2_wrap() {
    local n="$1" body
    declare -F "$n" >/dev/null 2>&1 || return 0
    body="$(declare -f "$n")"
    eval "_v2_orig_${body}"
    eval "${n}() { v2_call \"W ${n} \$*\"; _v2_orig_${n} \"\$@\"; }"
}
for f in tn_write_root_file _tn_meta_write meta_set meta_unset tn_backup_file tn_restore_backup \
         tn_rerender_node_launch tn_store_credential _tn_shred tn_write_start_script tn_write_node_unit \
         tn_write_node_env; do
    v2_wrap "$f"
done
if [[ "${V2_DOWN:-stub}" == "stub" ]]; then
    _tn_cred_switch() {
        v2_call "D _tn_cred_switch $*"
        v2_passcheck "D-pass _tn_cred_switch"
        return "$(cat "$V2_CTL/down_rc" 2>/dev/null || echo 0)"
    }
    tn_migrate_credential() {
        v2_call "D tn_migrate_credential $*"
        v2_passcheck "D-pass tn_migrate_credential"
        return "$(cat "$V2_CTL/down_rc" 2>/dev/null || echo 0)"
    }
    tn_migrate_embedded_passphrase() {
        v2_call "D tn_migrate_embedded_passphrase $*"
        v2_passcheck "D-pass tn_migrate_embedded_passphrase"
        return "$(cat "$V2_CTL/down_rc" 2>/dev/null || echo 0)"
    }
else
    for f in _tn_cred_switch tn_migrate_credential tn_migrate_embedded_passphrase; do
        _v2_body="$(declare -f "$f")"
        eval "_v2_orig_${_v2_body}"
        eval "${f}() { v2_call \"REAL ${f} \$*\"; _v2_orig_${f} \"\$@\"; }"
    done
fi
confirm() { return 0; }
edit_epoch_wait() { return 0; }
edit_pause() { edit_unlock; }
edit_require_root() { return 0; }
check_root() { return 0; }
tn_creds_supported() { return 0; }
tn_credential_key() { printf 'host\n'; }
tn_host_baseline_refresh() { v2_call "R tn_host_baseline_refresh $*"; return 0; }

# main exits through its EXIT trap: record the end state there first.
_v2_body="$(declare -f edit_on_exit)"
eval "_v2_orig_${_v2_body}"
edit_on_exit() {
    local r=$?
    printf '%s\n' "$r" > "$V2_LOG/rc"
    v2_passcheck "POST"
    ( exit "$r" )
    _v2_orig_edit_on_exit
}
rc=0
case "$CASE" in
    change)        edit_change_passphrase || rc=$? ;;
    reseal|reseal_typed) edit_reseal || rc=$? ;;
    mig_unit|mig_typed|mig_file) edit_migrate_credential || rc=$? ;;
    menu)          edit_bls_passphrase || rc=$? ;;
    main_mig_json) main --json --migrate-credential || rc=$? ;;
    main_mig)      main --migrate-credential || rc=$? ;;
    main_reseal)   main --reseal || rc=$? ;;
    *) echo "unknown case $CASE" >&2; rc=99 ;;
esac
printf '%s\n' "$rc" > "$V2_LOG/rc"
v2_passcheck "POST" 
exit 0
