#!/usr/bin/env bash
# =============================================================================
# tools/tests/primitives_test.sh -- the root-write, validation, network and
# .node-meta primitives in lib/common.sh and lib/fallback.sh
#
#   bash tools/tests/primitives_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/primitives_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/primitives_test.sh
#
# As a normal user the root-only success paths print SKIP and the refusals run.
# As root (both containers run as root) the success paths run too, in a temp dir
# under /root, the one stock directory whose whole ancestry is root-owned and
# not group- or other-writable. A tool the host lacks (busybox: no
# `cp --no-preserve`, a setpriv without --reuid) turns its cases into SKIP.
# No network, no systemd, nothing outside the temp dirs.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
eval "$(tn_test_source_common)"

T="$TN_TEST_TMP"
RB=""
trap 'tn_test_cleanup; if [[ -n "$RB" ]]; then rm -rf "$RB"; fi' EXIT

# run CMD [ARG...] -- OUT, ERR and RC get the command's stdout, stderr and rc.
# Feed stdin with a redirection, not a pipe (a pipe would run this in a subshell).
run() {
    OUT="$("$@" 2>"$T/.err")"
    RC=$?
    ERR="$(cat "$T/.err")"
}

# count DIR GLOB -- how many entries of DIR match GLOB (dot files included).
count() {
    find "$1" -mindepth 1 -maxdepth 1 -name "$2" 2>/dev/null | wc -l | tr -d ' '
}

# has TEXT NEEDLE -- "yes" when NEEDLE occurs in TEXT, else "no". A function, because
# bash 3.2 cannot parse a case pattern's ")" inside $( ).
has() {
    case "$1" in
        *"$2"*) echo yes ;;
        *) echo no ;;
    esac
}

sha() { sha256sum < "$1" | cut -d' ' -f1; }
owner_mode() { stat -c '%u %g %a' -- "$1" 2>/dev/null; }

IS_ROOT=0
[[ "$(id -u)" == 0 ]] && IS_ROOT=1
if [[ $IS_ROOT == 1 ]]; then
    RB="$(mktemp -d /root/.tn-test.XXXXXX 2>/dev/null)" || RB=""
    if [[ -n "$RB" ]] && ! tn_root_dir_ok "$RB"; then
        rm -rf "$RB"
        RB=""
    fi
fi
NOT_ROOT_REASON="not root"
if [[ $IS_ROOT == 1 && -z "$RB" ]]; then
    NOT_ROOT_REASON="root, but no usable root-only temp dir under /root"
fi

: > "$T/probe1"
HAVE_MV_T=0
mv -f -T -- "$T/probe1" "$T/probe2" 2>/dev/null && HAVE_MV_T=1
HAVE_CP_NP=0
cp --no-preserve=all -- "$T/probe2" "$T/probe3" 2>/dev/null && HAVE_CP_NP=1
# tn_as_service_user takes setpriv whenever it is installed, else runuser.
DROP_TOOL=""
if command -v setpriv >/dev/null 2>&1; then
    if setpriv --help 2>&1 | grep -q -- '--reuid'; then DROP_TOOL="setpriv"; fi
elif command -v runuser >/dev/null 2>&1; then
    DROP_TOOL="runuser"
fi
NOBODY_UID="$(id -u nobody 2>/dev/null)" || NOBODY_UID=""
NOBODY_GID="$(id -g nobody 2>/dev/null)" || NOBODY_GID=""
NOBODY_GROUP="$(id -gn nobody 2>/dev/null)" || NOBODY_GROUP=""

# ---- tn_root_dir_ok -----------------------------------------------------------
run tn_root_dir_ok /usr;               check_rc "root_dir_ok: /usr" 0 "$RC"
run tn_root_dir_ok /;                  check_rc "root_dir_ok: /" 0 "$RC"
run tn_root_dir_ok /usr/;              check_rc "root_dir_ok: /usr/ (trailing slash)" 0 "$RC"
check "root_dir_ok prints nothing" "" "$OUT$ERR"
run tn_root_dir_ok "$T";               check_rc "root_dir_ok: the test temp dir (not root-only) rc 1" 1 "$RC"
ln -s /usr "$T/usrlink"
run tn_root_dir_ok "$T/usrlink";       check_rc "root_dir_ok: a symlink to /usr rc 1" 1 "$RC"
run tn_root_dir_ok usr;                check_rc "root_dir_ok: relative path rc 1" 1 "$RC"
run tn_root_dir_ok "";                 check_rc "root_dir_ok: empty rc 1" 1 "$RC"
run tn_root_dir_ok /usr/../usr;        check_rc "root_dir_ok: a .. component rc 1" 1 "$RC"
run tn_root_dir_ok /usr/./bin;         check_rc "root_dir_ok: a . component rc 1" 1 "$RC"
run tn_root_dir_ok /nonexistent-tn-test; check_rc "root_dir_ok: missing dir rc 1" 1 "$RC"
run tn_root_dir_ok "$(command -v env)"; check_rc "root_dir_ok: a file rc 1" 1 "$RC"
run tn_root_dir_ok /tmp;               check_rc "root_dir_ok: /tmp (1777) rc 1" 1 "$RC"
if [[ -n "$RB" ]]; then
    mkdir -m 0755 "$RB/d"
    run tn_root_dir_ok "$RB/d";        check_rc "root_dir_ok: root 0755 dir" 0 "$RC"
    chmod 775 "$RB/d"
    run tn_root_dir_ok "$RB/d";        check_rc "root_dir_ok: 0775 rc 1" 1 "$RC"
    chmod 757 "$RB/d"
    run tn_root_dir_ok "$RB/d";        check_rc "root_dir_ok: 0757 rc 1" 1 "$RC"
    chmod 2750 "$RB/d"
    run tn_root_dir_ok "$RB/d";        check_rc "root_dir_ok: 2750 (setgid, no g+w)" 0 "$RC"
    chmod 0755 "$RB/d"
    chown "${NOBODY_UID:-65534}" "$RB/d"
    run tn_root_dir_ok "$RB/d";        check_rc "root_dir_ok: owned by nobody rc 1" 1 "$RC"
    mkdir -p "$RB/real/sub"
    ln -s "$RB/real" "$RB/link"
    run tn_root_dir_ok "$RB/real/sub"; check_rc "root_dir_ok: real parent" 0 "$RC"
    run tn_root_dir_ok "$RB/link/sub"; check_rc "root_dir_ok: symlinked parent rc 1" 1 "$RC"
    mkdir -p "$RB/gw/sub"
    chmod 775 "$RB/gw"
    run tn_root_dir_ok "$RB/gw/sub";   check_rc "root_dir_ok: g+w parent rc 1" 1 "$RC"
else
    skip "root_dir_ok: root-owned dir, modes, owner, symlinked and g+w parents" "$NOT_ROOT_REASON"
fi

# ---- tn_write_root_file: refusals (any user) ----------------------------------
printf 'orig\n' > "$T/target"
ln -s "$T/target" "$T/dest-link"
run tn_write_root_file "$T/dest-link" 0644 <<< "new"
check_rc "write_root_file: symlink DEST rc 1" 1 "$RC"
check "write_root_file: symlink target unchanged" "orig" "$(cat "$T/target")"
check "write_root_file: refusal prints nothing on stdout" "" "$OUT"
mkdir "$T/ddir"
run tn_write_root_file "$T/ddir" 0644 <<< "new"
check_rc "write_root_file: directory DEST rc 1" 1 "$RC"
run tn_write_root_file "$T/plain" 0644 <<< "new"
check_rc "write_root_file: parent not root-only rc 1" 1 "$RC"
check "write_root_file: nothing created on refusal" "absent" "$([[ -e "$T/plain" ]] && echo present || echo absent)"
check "write_root_file: no .tn.* temp left on refusal" "0" "$(count "$T" '.tn.*')"
run tn_write_root_file relative/file 0644 <<< "new"
check_rc "write_root_file: relative DEST rc 1" 1 "$RC"
run tn_write_root_file /usr/ 0644 <<< "new"
check_rc "write_root_file: DEST ending in / rc 1" 1 "$RC"
run tn_write_root_file /usr/tn-test-never 08 <<< "new"
check_rc "write_root_file: mode 08 rc 1" 1 "$RC"
run tn_write_root_file /usr/tn-test-never 0644 '-x' <<< "new"
check_rc "write_root_file: group -x rc 1" 1 "$RC"
run tn_write_root_file /usr/tn-test-never 0644 'a b' <<< "new"
check_rc "write_root_file: group with a space rc 1" 1 "$RC"

# ---- tn_write_root_file: as root ---------------------------------------------
if [[ -z "$RB" ]]; then
    skip "write_root_file: writes content, owner, mode; planted symlink; failure cleanup" "$NOT_ROOT_REASON"
elif [[ $HAVE_MV_T == 0 ]]; then
    skip "write_root_file: writes content, owner, mode; planted symlink; failure cleanup" "mv -T absent"
else
    mkdir -m 0755 "$RB/w"
    run tn_write_root_file "$RB/w/file" 0640 <<< "hello"
    check_rc "write_root_file: rc 0" 0 "$RC"
    check "write_root_file: content" "hello" "$(cat "$RB/w/file")"
    check "write_root_file: root:root 0640" "0 0 640" "$(owner_mode "$RB/w/file")"
    check "write_root_file: no .tn.* temp left" "0" "$(count "$RB/w" '.tn.*')"
    if [[ -n "$NOBODY_GROUP" ]]; then
        run tn_write_root_file "$RB/w/file" 0644 "$NOBODY_GROUP" <<< "again"
        check_rc "write_root_file: replace with a group rc 0" 0 "$RC"
        check "write_root_file: replaced content" "again" "$(cat "$RB/w/file")"
        check "write_root_file: root:<group> 0644" "0 ${NOBODY_GID} 644" "$(owner_mode "$RB/w/file")"
    else
        skip "write_root_file: GROUP argument" "no nobody user"
    fi
    printf 'canary\n' > "$RB/canary"
    ln -s "$RB/canary" "$RB/w/planted"
    run tn_write_root_file "$RB/w/planted" 0644 <<< "evil"
    check_rc "write_root_file: planted symlink rc 1" 1 "$RC"
    check "write_root_file: symlink target unchanged" "canary" "$(cat "$RB/canary")"
    check "write_root_file: planted symlink still a symlink" "link" "$([[ -L "$RB/w/planted" ]] && echo link || echo other)"
    mkdir "$RB/w/adir"
    run tn_write_root_file "$RB/w/adir" 0644 <<< "x"
    check_rc "write_root_file: directory DEST rc 1" 1 "$RC"
    mkdir -p "$RB/gw2/sub"
    chmod 775 "$RB/gw2"
    run tn_write_root_file "$RB/gw2/sub/file" 0644 <<< "x"
    check_rc "write_root_file: g+w grandparent rc 1" 1 "$RC"
    check "write_root_file: nothing written under a g+w grandparent" "0" "$(count "$RB/gw2/sub" '*')"
    printf 'keep\n' > "$RB/w/keep"
    run tn_write_root_file "$RB/w/keep" 0644 tn-no-such-group-x <<< "lost"
    check_rc "write_root_file: chown failure rc 2" 2 "$RC"
    check "write_root_file: DEST unchanged after a failure" "keep" "$(cat "$RB/w/keep")"
    check "write_root_file: no .tn.* temp left after a failure" "0" "$(count "$RB/w" '.tn.*')"
    check "write_root_file: never prints on stdout" "" "$OUT"
fi

# ---- tn_backup_file / tn_restore_backup ----------------------------------------
printf 'conf\n' > "$T/src.conf"
ln -s "$T/src.conf" "$T/src-link"
TN_BACKUP_DIR="$T/bk"
export TN_BACKUP_DIR
run tn_backup_file "$T/src-link"
check_rc "backup_file: symlink SRC rc 1" 1 "$RC"
run tn_backup_file "$T/missing"
check_rc "backup_file: missing SRC rc 1" 1 "$RC"
run tn_backup_file "$T"
check_rc "backup_file: directory SRC rc 1" 1 "$RC"
ln -s "$T/ddir" "$T/bk-link"
TN_BACKUP_DIR="$T/bk-link"
run tn_backup_file "$T/src.conf"
check_rc "backup_file: symlinked backup dir rc 1" 1 "$RC"
TN_BACKUP_DIR="relative/bk"
run tn_backup_file "$T/src.conf"
check_rc "backup_file: relative backup dir rc 1" 1 "$RC"
TN_BACKUP_DIR="$T/bk"
run tn_backup_file "$T/src.conf"
check_rc "backup_file: backup dir under the test temp dir (not root-only) rc 1" 1 "$RC"
check "backup_file: refusal prints nothing on stdout" "" "$OUT"
check "backup_file: no backup file left on refusal" "0" "$(count "$T/bk" '*')"
check "backup_file: a refused backup dir is not created" "absent" \
    "$([[ -e "$T/bk" ]] && echo present || echo absent)"

# Restore: refusals that need no root.
printf 'restore-me\n' > "$T/bk-file"
printf 'untouched\n' > "$T/dest-r"
run tn_restore_backup "$T/bk-file" "$(sha "$T/bk-file")" "$T/dest-r" 0644
check_rc "restore_backup: backup in a non-root-only dir rc 1" 1 "$RC"
check "restore_backup: DEST untouched" "untouched" "$(cat "$T/dest-r")"
run tn_restore_backup "$T/bk-file" abc "$T/dest-r" 0644
check_rc "restore_backup: malformed sha256 rc 1" 1 "$RC"
ln -s "$T/bk-file" "$T/bk-file-link"
run tn_restore_backup "$T/bk-file-link" "$(sha "$T/bk-file")" "$T/dest-r" 0644
check_rc "restore_backup: symlink BACKUP rc 1" 1 "$RC"

if [[ -z "$RB" ]]; then
    skip "backup_file / restore_backup: success paths, dir mode and owner refusals, hash mismatch" "$NOT_ROOT_REASON"
else
    TN_BACKUP_DIR="$RB/bk"
    printf 'unit-content\n' > "$RB/src.conf"
    chmod 0644 "$RB/src.conf"
    chown "${NOBODY_UID:-65534}" "$RB/src.conf"
    if [[ $HAVE_CP_NP == 0 ]]; then
        run tn_backup_file "$RB/src.conf"
        check_rc "backup_file: cp without --no-preserve fails closed rc 2" 2 "$RC"
        check "backup_file: no partial backup left" "0" "$(count "$RB/bk" '*')"
        skip "backup_file: success path" "cp --no-preserve absent"
    else
        run tn_backup_file "$RB/src.conf"
        check_rc "backup_file: rc 0" 0 "$RC"
        bpath="${OUT% *}"
        bsum="${OUT##* }"
        check "backup_file: path in the backup dir, named after SRC" "$RB/bk/src.conf." "${bpath%.*}."
        check "backup_file: sha256 of the content" "$(sha "$RB/src.conf")" "$bsum"
        check "backup_file: copy has the content" "unit-content" "$(cat "$bpath")"
        check "backup_file: copy is root 0600, not the source owner and mode" "0 0 600" "$(owner_mode "$bpath")"
        check "backup_file: backup dir created root 0700" "0 0 700" "$(owner_mode "$RB/bk")"
        run tn_backup_file "$RB/src.conf" "etc/telcoin/unit file"
        check_rc "backup_file: NAME with / and space rc 0" 0 "$RC"
        nm="${OUT% *}"
        nm="${nm##*/}"
        check "backup_file: NAME characters outside [A-Za-z0-9._-] become _" "etc_telcoin_unit_file." "${nm%.*}."
        chmod 0755 "$RB/bk"
        run tn_backup_file "$RB/src.conf"
        check_rc "backup_file: backup dir 0755 rc 1" 1 "$RC"
        chmod 0700 "$RB/bk"
        chown "${NOBODY_UID:-65534}" "$RB/bk"
        run tn_backup_file "$RB/src.conf"
        check_rc "backup_file: backup dir owned by nobody rc 1" 1 "$RC"
        chown 0 "$RB/bk"
        # A missing backup dir under a directory another account owns: refused
        # before anything is created.
        mkdir -m 0755 "$RB/n"
        chown "${NOBODY_UID:-65534}" "$RB/n"
        TN_BACKUP_DIR="$RB/n/x/bk"
        run tn_backup_file "$RB/src.conf"
        check_rc "backup_file: missing dir under an account's directory rc 1" 1 "$RC"
        check "backup_file: nothing created under that directory" "0" "$(count "$RB/n" '*')"
        TN_BACKUP_DIR="$RB/deep/er/bk"
        run tn_backup_file "$RB/src.conf"
        check_rc "backup_file: missing parents under a root-only dir rc 0" 0 "$RC"
        check "backup_file: parents and dir created root 0700" "0 0 700 0 0 700" \
            "$(owner_mode "$RB/deep") $(owner_mode "$RB/deep/er/bk")"
        TN_BACKUP_DIR="$RB/bk"
    fi

    # Restore from a backup in a root-only dir (made by hand, so busybox runs it too).
    if [[ $HAVE_MV_T == 0 ]]; then
        skip "restore_backup: success path and hash mismatch" "mv -T absent"
    else
        mkdir -m 0700 "$RB/bk2"
        printf 'from-backup\n' > "$RB/bk2/unit.bak"
        mkdir -m 0755 "$RB/r"
        printf 'current\n' > "$RB/r/unit"
        run tn_restore_backup "$RB/bk2/unit.bak" "$(printf '%064d' 0)" "$RB/r/unit" 0644
        check_rc "restore_backup: hash mismatch rc 1" 1 "$RC"
        check "restore_backup: DEST untouched on mismatch" "current" "$(cat "$RB/r/unit")"
        run tn_restore_backup "$RB/bk2/unit.bak" "$(sha "$RB/bk2/unit.bak")" "$RB/r/unit" 0640
        check_rc "restore_backup: rc 0" 0 "$RC"
        check "restore_backup: content restored" "from-backup" "$(cat "$RB/r/unit")"
        check "restore_backup: root:root 0640" "0 0 640" "$(owner_mode "$RB/r/unit")"
    fi
fi
TN_BACKUP_DIR="$T/bk"

# ---- tn_install_root_binary ------------------------------------------------------
printf '#!/bin/sh\necho v1\n' > "$T/bin-src"
ln -s "$T/bin-src" "$T/bin-src-link"
run tn_install_root_binary "$T/bin-src-link" /usr/tn-test-never
check_rc "install_root_binary: symlink SRC rc 1" 1 "$RC"
run tn_install_root_binary "$T/missing" /usr/tn-test-never
check_rc "install_root_binary: missing SRC rc 1" 1 "$RC"
run tn_install_root_binary "$T/bin-src" "$T/bin-dest"
check_rc "install_root_binary: DEST dir not root-only rc 1" 1 "$RC"
check "install_root_binary: nothing installed on refusal" "absent" "$([[ -e "$T/bin-dest" ]] && echo present || echo absent)"
check "install_root_binary: no .new.* left on refusal" "0" "$(count "$T" 'bin-dest.new.*')"
run tn_install_root_binary "$T/bin-src" "$T/dest-link"
check_rc "install_root_binary: symlink DEST rc 1" 1 "$RC"
check "install_root_binary: symlink target unchanged" "orig" "$(cat "$T/target")"
run tn_install_root_binary "$T/bin-src" "$T/ddir"
check_rc "install_root_binary: directory DEST rc 1" 1 "$RC"
run tn_install_root_binary "$T/bin-src" relative/bin
check_rc "install_root_binary: relative DEST rc 1" 1 "$RC"
if [[ -z "$RB" ]]; then
    skip "install_root_binary: installs root:root 0755, replaces, leaves no .new.*" "$NOT_ROOT_REASON"
elif [[ $HAVE_MV_T == 0 ]]; then
    skip "install_root_binary: installs root:root 0755, replaces, leaves no .new.*" "mv -T absent"
else
    mkdir -m 0755 "$RB/bin"
    printf '#!/bin/sh\necho v1\n' > "$RB/bin-src"
    chmod 0600 "$RB/bin-src"
    chown "${NOBODY_UID:-65534}" "$RB/bin-src"
    run tn_install_root_binary "$RB/bin-src" "$RB/bin/tool"
    check_rc "install_root_binary: rc 0" 0 "$RC"
    check "install_root_binary: root:root 0755" "0 0 755" "$(owner_mode "$RB/bin/tool")"
    check "install_root_binary: content" "$(sha "$RB/bin-src")" "$(sha "$RB/bin/tool")"
    check "install_root_binary: no .new.* left" "0" "$(count "$RB/bin" 'tool.new.*')"
    printf '#!/bin/sh\necho v2\n' > "$RB/bin-src2"
    run tn_install_root_binary "$RB/bin-src2" "$RB/bin/tool"
    check_rc "install_root_binary: replace rc 0" 0 "$RC"
    check "install_root_binary: replaced content" "$(sha "$RB/bin-src2")" "$(sha "$RB/bin/tool")"
    ln -s "$RB/canary" "$RB/bin/planted"
    run tn_install_root_binary "$RB/bin-src2" "$RB/bin/planted"
    check_rc "install_root_binary: planted symlink rc 1" 1 "$RC"
    check "install_root_binary: symlink target unchanged" "canary" "$(cat "$RB/canary" 2>/dev/null || echo canary)"
fi

# ---- tn_as_service_user ---------------------------------------------------------
saved_user="$SERVICE_USER"
saved_group="$SERVICE_GROUP"
SERVICE_USER=""
run tn_as_service_user touch "$T/ran-empty"
check_rc "as_service_user: empty SERVICE_USER rc 126" 126 "$RC"
check "as_service_user: empty user ran nothing" "absent" "$([[ -e "$T/ran-empty" ]] && echo present || echo absent)"
SERVICE_USER=root
SERVICE_GROUP=root
run tn_as_service_user touch "$T/ran-root"
check_rc "as_service_user: SERVICE_USER=root rc 126" 126 "$RC"
check "as_service_user: root user ran nothing" "absent" "$([[ -e "$T/ran-root" ]] && echo present || echo absent)"
SERVICE_USER="-x"
run tn_as_service_user touch "$T/ran-dash"
check_rc "as_service_user: user -x rc 126" 126 "$RC"
SERVICE_USER="tn-no-such-user-x"
run tn_as_service_user touch "$T/ran-unknown"
check_rc "as_service_user: unknown user rc 126" 126 "$RC"
if [[ -n "$NOBODY_UID" && "$NOBODY_UID" != 0 ]]; then
    SERVICE_USER=nobody
    SERVICE_GROUP=root
    run tn_as_service_user touch "$T/ran-gid0"
    check_rc "as_service_user: group root rc 126" 126 "$RC"
    check "as_service_user: gid 0 ran nothing" "absent" "$([[ -e "$T/ran-gid0" ]] && echo present || echo absent)"
    SERVICE_GROUP="${NOBODY_GROUP:-nogroup}"
    run tn_as_service_user
    check_rc "as_service_user: no command rc 126" 126 "$RC"
else
    skip "as_service_user: gid 0 and no-command refusals" "no nobody user"
fi
if [[ $IS_ROOT == 0 ]]; then
    skip "as_service_user: runs as nobody without TN_BLS_PASSPHRASE" "not root"
elif [[ -z "$DROP_TOOL" ]]; then
    skip "as_service_user: runs as nobody without TN_BLS_PASSPHRASE" "no setpriv with --reuid, no runuser"
elif [[ -z "$NOBODY_UID" || -z "$NOBODY_GROUP" ]]; then
    skip "as_service_user: runs as nobody without TN_BLS_PASSPHRASE" "no nobody user"
else
    SERVICE_USER=nobody
    SERVICE_GROUP="$NOBODY_GROUP"
    export TN_BLS_PASSPHRASE="tn-test-secret"
    run tn_as_service_user env
    check_rc "as_service_user ($DROP_TOOL): env rc 0" 0 "$RC"
    check_lacks "as_service_user: TN_BLS_PASSPHRASE stripped" "TN_BLS_PASSPHRASE" "$OUT"
    check_lacks "as_service_user: the passphrase value absent" "tn-test-secret" "$OUT"
    unset TN_BLS_PASSPHRASE
    run tn_as_service_user id -u
    check "as_service_user: runs as nobody's uid" "$NOBODY_UID" "$OUT"
    run tn_as_service_user id -G
    check "as_service_user: only the service group, no supplementary groups" "$NOBODY_GID" "$OUT"
    run tn_as_service_user printf '%s|' "a b" "c"
    check "as_service_user: arguments stay separate words" "a b|c|" "$OUT"
    run tn_as_service_user sh -c 'exit 3'
    check_rc "as_service_user: the command's rc passes through" 3 "$RC"
    exec 9>>"$T/fd9"
    run tn_as_service_user sh -c 'if [ -e /proc/self/fd/9 ]; then echo open; else echo closed; fi'
    exec 9>&-
    check "as_service_user: fd 9 (the update lock) closed for the child" "closed" "$OUT"
fi
SERVICE_USER="$saved_user"
SERVICE_GROUP="$saved_group"

# ---- tn_passphrase_ok -------------------------------------------------------------
# name|value|testnet rc|mainnet rc
pp_case() {
    run tn_passphrase_ok "$2" testnet
    check_rc "passphrase_ok testnet: $1" "$3" "$RC"
    run tn_passphrase_ok "$2" mainnet
    check_rc "passphrase_ok mainnet: $1" "$4" "$RC"
    check "passphrase_ok prints nothing: $1" "" "$OUT$ERR"
}
pp_case 'empty'                     ''                     1 1
pp_case 'abc'                       'abc'                  0 1
pp_case 'leading space'             ' abc'                 1 1
pp_case 'trailing space'            'abc '                 1 1
pp_case 'trailing LF'               $'abc\n'               1 1
pp_case 'interior CR'               $'ab\rc'               1 1
pp_case 'interior LF'               $'ab\nc'               1 1
pp_case '16 characters'             'abcdefghijklmnop'     0 0
pp_case '15 characters'             'abcdefghijklmno'      0 1
pp_case 'interior spaces, 17 chars' 'a b c d e f g h i'    0 0
pp_case 'leading tab'               $'\tabc'               1 1
pp_case 'trailing VT'               $'abcdefghijklmnopq\v' 1 1
pp_case 'interior tab'              $'abcdefgh\tijklmnop'  0 0
pp_case '8 two-byte chars (16 bytes)' 'éééééééé'           0 0
pp_case '7 two-byte chars (14 bytes)' 'ééééééé'            0 1
run tn_passphrase_ok 'abc'
check_rc "passphrase_ok: no NETWORK, base rules only" 0 "$RC"
run tn_passphrase_ok 'abc' devnet
check_rc "passphrase_ok: devnet, base rules only" 0 "$RC"

# ---- tn_release_tag_ok -------------------------------------------------------------
tag_case() {
    run tn_release_tag_ok "$2" "$3"
    check_rc "release_tag_ok: $1" "$4" "$RC"
}
tag_case 'v0.16.0-adiri testnet'      testnet 'v0.16.0-adiri'  0
tag_case 'v0.16.0-adiri mainnet'      mainnet 'v0.16.0-adiri'  1
tag_case 'v1.0.0 mainnet'             mainnet 'v1.0.0'         0
tag_case 'v1.0.0 testnet'             testnet 'v1.0.0'         1
tag_case 'v1.0.0-rc1 testnet'         testnet 'v1.0.0-rc1'     1
tag_case 'v1.0.0-rc1 mainnet'         mainnet 'v1.0.0-rc1'     1
tag_case 'main'                       testnet 'main'           1
tag_case 'latest'                     mainnet 'latest'         1
tag_case 'v1.0'                       mainnet 'v1.0'           1
tag_case '1.0.0'                      mainnet '1.0.0'          1
tag_case 'trailing space'             testnet 'v1.0.0-adiri '  1
tag_case 'trailing LF'                mainnet $'v1.0.0\n'      1
tag_case 'leading text'               mainnet 'xv1.0.0'        1
tag_case 'suffix after -adiri'        testnet 'v1.0.0-adiri-x' 1
tag_case 'empty tag'                  mainnet ''               1
tag_case 'devnet network'             devnet  'v1.0.0'         1
tag_case 'empty network'              ''      'v1.0.0'         1

# ---- tn_cargo_features_for ----------------------------------------------------------
run tn_cargo_features_for testnet
check_rc "cargo_features_for testnet rc 0" 0 "$RC"
check "cargo_features_for testnet prints --features adiri" "--features adiri" "$OUT"
run tn_cargo_features_for mainnet
check_rc "cargo_features_for mainnet rc 0" 0 "$RC"
check "cargo_features_for mainnet prints nothing" "" "$OUT"
for n in devnet foo ""; do
    run tn_cargo_features_for "$n"
    check_rc "cargo_features_for '${n}' rc 1" 1 "$RC"
    check "cargo_features_for '${n}' prints nothing" "" "$OUT"
done

# ---- meta_get / _tn_meta_get ---------------------------------------------------------
printf 'NETWORK=testnet\nURL=a=b\nFOO_BAR=1\n' > "$T/meta-one"
printf 'NETWORK=mainnet\r\nOTHER=x\r\n' > "$T/meta-crlf"
printf 'NETWORK=testnet\nOTHER=x\nNETWORK=mainnet\n' > "$T/meta-dup"
printf 'NETWORK=testnet\r\nNETWORK=testnet\n' > "$T/meta-dup-crlf"
for fn in meta_get _tn_meta_get; do
    run "$fn" NETWORK "$T/meta-one"
    check_rc "${fn}: single key rc 0" 0 "$RC"
    check "${fn}: single key value" "testnet" "$OUT"
    run "$fn" URL "$T/meta-one"
    check "${fn}: value is everything after the first =" "a=b" "$OUT"
    run "$fn" NETWORK "$T/meta-crlf"
    check "${fn}: CR stripped" "mainnet" "$OUT"
    run "$fn" NETWORK "$T/meta-dup"
    check_rc "${fn}: duplicate key rc 2" 2 "$RC"
    check "${fn}: duplicate key prints nothing on stdout" "" "$OUT"
    check "${fn}: duplicate warning names the key" "yes" "$(has "$ERR" NETWORK)"
    check "${fn}: duplicate warning names the file" "yes" "$(has "$ERR" "$T/meta-dup")"
    run "$fn" NETWORK "$T/meta-dup-crlf"
    check_rc "${fn}: duplicate with and without CR rc 2" 2 "$RC"
    run "$fn" FOO "$T/meta-one"
    check_rc "${fn}: absent key (a longer key is not a match) rc 1" 1 "$RC"
    check "${fn}: absent key prints nothing" "" "$OUT"
    run "$fn" NETWORK "$T/no-such-meta"
    check_rc "${fn}: absent file rc 1" 1 "$RC"
done

# ---- tn_detect_network ---------------------------------------------------------------
mkdir -p "$T/bin" "$T/dd487/genesis" "$T/dd2017/genesis" "$T/dddev/genesis" "$T/ddnone"
printf '#!/bin/sh\n: > "%s/cargo-called"\n' "$T" > "$T/bin/cargo"
chmod +x "$T/bin/cargo"
printf 'config:\n  chainId: 487\n' > "$T/dd487/genesis/genesis.yaml"
printf 'config:\n  chainId: 2017\n' > "$T/dd2017/genesis/genesis.yaml"
printf 'config:\n  chainId: 32285\n' > "$T/dddev/genesis/genesis.yaml"
mkmeta() { local f="$T/$1"; shift; printf '%s\n' "$@" > "$f"; }
mkmeta net-testnet NETWORK=testnet "DATA_DIR=$T/dd487"
mkmeta net-mainnet NETWORK=mainnet "DATA_DIR=$T/dd2017"
printf 'NETWORK=mainnet\r\nDATA_DIR=%s\r\n' "$T/dd2017" > "$T/net-crlf"
mkmeta net-devnet NETWORK=devnet "DATA_DIR=$T/dd487"
mkmeta net-foo NETWORK=foo "DATA_DIR=$T/dd487"
mkmeta net-empty NETWORK= "DATA_DIR=$T/dd487"
mkmeta gen-487 "DATA_DIR=$T/dd487"
mkmeta gen-2017 "DATA_DIR=$T/dd2017"
mkmeta gen-dev "DATA_DIR=$T/dddev"
mkmeta gen-none "DATA_DIR=$T/ddnone"
mkmeta dup-nogen NETWORK=testnet NETWORK=testnet "DATA_DIR=$T/ddnone"
mkmeta dup-gen487 NETWORK=testnet NETWORK=mainnet "DATA_DIR=$T/dd487"
saved_path="$PATH"
PATH="$T/bin:$PATH"
saved_prefix="$TN_ROOT_PREFIX"
# DATA_DIR in an explicit META is a real path here (no prefix); every case below
# either stops before the data dir or names an existing one.
TN_ROOT_PREFIX=""
net_case() {
    run tn_detect_network "$T/$2"
    check_rc "detect_network: $1 rc" "$3" "$RC"
    check "detect_network: $1 output" "$4" "$OUT"
}
net_case 'NETWORK=testnet (genesis says 487)'  net-testnet 0 testnet
net_case 'NETWORK=mainnet (genesis says 2017)' net-mainnet 0 mainnet
net_case 'CRLF file'                           net-crlf    0 mainnet
net_case 'NETWORK=devnet'                      net-devnet  1 ''
net_case 'NETWORK=foo'                         net-foo     1 ''
net_case 'NETWORK= (empty)'                    net-empty   1 ''
net_case 'no key, genesis 487'                 gen-487     0 mainnet
net_case 'no key, genesis 2017'                gen-2017    0 testnet
net_case 'no key, devnet genesis 32285'        gen-dev     1 ''
net_case 'no key, no genesis'                  gen-none    1 ''
net_case 'duplicate NETWORK, no genesis'       dup-nogen   1 ''
net_case 'duplicate NETWORK, genesis 487 (no fallback)' dup-gen487 1 ''
check "detect_network: duplicate warning names NETWORK" "yes" "$(has "$ERR" NETWORK)"
# Default .node-meta, through TN_ROOT_PREFIX.
TN_ROOT_PREFIX="$T/root1"
mkdir -p "$T/root1/etc/telcoin"
printf 'NETWORK=mainnet\n' > "$T/root1/etc/telcoin/.node-meta"
run tn_detect_network
check "detect_network: default .node-meta under TN_ROOT_PREFIX" "mainnet" "$OUT"
TN_ROOT_PREFIX="$T/root2"
mkdir -p "$T/root2/var/lib/telcoin/genesis"
printf 'chain_id: 2017\n' > "$T/root2/var/lib/telcoin/genesis/genesis.yaml"
run tn_detect_network
check "detect_network: no .node-meta, default data dir genesis 2017" "testnet" "$OUT"
TN_ROOT_PREFIX="$T/root3"
mkdir -p "$T/root3/etc/telcoin" "$T/root3/srv/tn/genesis"
printf 'DATA_DIR=/srv/tn\n' > "$T/root3/etc/telcoin/.node-meta"
printf 'chainId: 487\n' > "$T/root3/srv/tn/genesis/genesis.yaml"
run tn_detect_network
check "detect_network: DATA_DIR from .node-meta, under TN_ROOT_PREFIX" "mainnet" "$OUT"
check "detect_network: never runs cargo" "absent" "$([[ -e "$T/cargo-called" ]] && echo present || echo absent)"
PATH="$saved_path"
TN_ROOT_PREFIX="$saved_prefix"

# ---- tn_start_script_path -------------------------------------------------------------
run tn_start_script_path source
check "start_script_path source" "/usr/local/libexec/telcoin/tn-start" "$OUT"
run tn_start_script_path release
check "start_script_path release" "/usr/local/libexec/telcoin/tn-start" "$OUT"
run tn_start_script_path docker
check "start_script_path docker" "/usr/local/libexec/telcoin/tn-start-docker" "$OUT"
for m in foo "" binary existing; do
    run tn_start_script_path "$m"
    check_rc "start_script_path '${m}' rc 1" 1 "$RC"
    check "start_script_path '${m}' prints nothing" "" "$OUT"
done

finish
