#!/usr/bin/env bash
# =============================================================================
# tools/tests/remove_test.sh -- remove-node.sh's teardown of the files beside a
# node: the unit's old backups and drop-in directory (also under older and
# legacy names), the key, passphrase and config files (shredded by find, as the
# service account where the tree is not this account's own, never through a
# symlink or a split name), the shared host files (start scripts, node.env,
# backups, logrotate, journald, needrestart and apt files, the lock directory,
# a symlinked libexec dir left alone), the log-reader group, the JSON path,
# finishing a removal that stopped part way (JSON and the menu's leftover
# path), the update lock, and the refusal to remove anything when .node-meta
# sets a key more than once.
#
#   bash tools/tests/remove_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/remove_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/remove_test.sh
#
# Every path lives under a fixture root (TN_ROOT_PREFIX). shred, systemctl,
# userdel, groupdel, gpasswd, getent, docker, id, setpriv and runuser are PATH
# stubs that log their arguments; nothing touches the host's units, groups or
# accounts. The shred stub overwrites what it opens (following a symlink, as
# shred does) and then unlinks it; id knows one account, KNOWN_USER (none when
# empty); setpriv and runuser run the command as the current user.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
R="$T/root"         # the fixture root
OUT="$T/outside"    # decoys outside the fixture root
CALLS="$T/calls.log"
GROUP_FILE="$T/group"
SHRED_RC=0
KNOWN_USER=""
ORIG_PATH="$PATH"
export CALLS GROUP_FILE SHRED_RC KNOWN_USER ORIG_PATH
mkdir -p "$T/h" "$T/bin" "$R" "$OUT"

# --- PATH stubs (bash only: no wrapped tool is looked up through PATH) -------
for tool in systemctl userdel gpasswd docker; do
    cat > "$T/bin/$tool" <<STUB
#!/usr/bin/env bash
printf '%s\n' "$tool \$*" >> "\$CALLS"
if [ "$tool" = systemctl ] && [ "\${1:-}" = is-active ]; then exit 3; fi
exit 0
STUB
done
cat > "$T/bin/shred" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "shred $*" >> "$CALLS"
[ "${SHRED_RC:-0}" = 0 ] || exit "$SHRED_RC"
unlink=""
for a in "$@"; do
    case "$a" in
        -u) unlink=1 ;;
        --) ;;
        *) [ -f "$a" ] && printf 'SHREDDED\n' > "$a"
           [ -n "$unlink" ] && rm -f -- "$a" ;;
    esac
done
exit 0
STUB
cat > "$T/bin/id" <<'STUB'
#!/usr/bin/env bash
if [ -n "${KNOWN_USER:-}" ]; then
    case "$*" in
        "-u $KNOWN_USER") echo 991; exit 0 ;;
        "-gn $KNOWN_USER") echo "$KNOWN_USER"; exit 0 ;;
        "$KNOWN_USER") echo "uid=991($KNOWN_USER) gid=991($KNOWN_USER)"; exit 0 ;;
    esac
fi
PATH="$ORIG_PATH" exec id "$@"
STUB
for tool in setpriv runuser; do
    cat > "$T/bin/$tool" <<STUB
#!/usr/bin/env bash
printf '%s\n' "$tool \$*" >> "\$CALLS"
while [ \$# -gt 0 ] && [ "\$1" != -- ]; do shift; done
shift
exec "\$@"
STUB
done
cat > "$T/bin/getent" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "getent $*" >> "$CALLS"
[ "${1:-}" = group ] || exit 2
found=""
while IFS= read -r l; do
    if [ $# -lt 2 ] || [ "${l%%:*}" = "$2" ]; then
        printf '%s\n' "$l"
        found=1
    fi
done < "$GROUP_FILE"
[ -n "$found" ] || exit 2
exit 0
STUB
cat > "$T/bin/groupdel" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "groupdel $*" >> "$CALLS"
keep=""
while IFS= read -r l; do
    [ "${l%%:*}" = "$1" ] || keep="${keep}${l}
"
done < "$GROUP_FILE"
printf '%s' "$keep" > "$GROUP_FILE"
exit 0
STUB
chmod +x "$T/bin/"*
PATH="$T/bin:$PATH"

# --- source remove-node.sh without its trailing main call --------------------
grep -v '^main "\$@"$' "$TN_TEST_REPO/remove-node.sh" > "$T/h/remove-node.sh"
ln -s "$TN_TEST_REPO/lib" "$T/h/lib"
TN_ROOT_PREFIX="$R"
export TN_ROOT_PREFIX
unset TN_LOGROTATE_FILE TN_ASSUME_YES
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/h/remove-node.sh"
tn_test_post_common

# Prompts answer CONFIRM_ANSWER; the add-on teardown belongs to another test.
CONFIRM_ANSWER=no
confirm() { [[ "$CONFIRM_ANSWER" == "yes" ]]; }
remove_testnet_addons() { :; }

SD="$R/etc/systemd/system"
ETC="$R/etc/telcoin"
DATA="$R/var/lib/telcoin"
LX="$R/usr/local/libexec/telcoin"
BK="$R/var/backups/telcoin"

# mkfixture -- a fresh fixture tree: one source install with every file the
# removal handles, plus decoys that must survive.
mkfixture() {
    rm -rf "$R" "$OUT"
    mkdir -p "$SD/telcoin.service.d" "$ETC" "$DATA/node-keys/sub" "$DATA/db" "$LX" \
             "$BK" "$R/etc/logrotate.d" "$R/etc/systemd/journald.conf.d" "$R/run/telcoin" "$OUT" \
             "$R/etc/needrestart/conf.d" "$R/etc/apt/apt.conf.d"
    printf '[Service]\nUser=tnrmtest\n' > "$SD/telcoin.service"
    printf 'Environment=TN_BLS_PASSPHRASE=x\n' > "$SD/telcoin.service.bak.20240101"
    printf 'old\n' > "$SD/telcoin.bak.1"
    printf '[Service]\n' > "$SD/telcoin.service.d/override.conf"
    printf 'decoy\n' > "$SD/telcoin-alloy.service.bak.1"
    printf 'decoy\n' > "$SD/other.service"
    printf 'decoy\n' > "$OUT/unit-target"
    ln -s "$OUT/unit-target" "$SD/telcoin.service.bak.link"
    printf 'INSTALL_METHOD=source\nHOST_SERVICE_USER=tnrmtest\nHOST_SERVICE_GROUP=tnrmtest\n' > "$ETC/.node-meta"
    for f in bls-passphrase.cred bls-passphrase bls-tpm.pub bls-tpm.priv node.env; do
        printf 'secret\n' > "$ETC/$f"
    done
    printf 'decoy\n' > "$ETC/other.txt"
    printf 'k\n' > "$DATA/node-keys/bls.key"
    printf 'k\n' > "$DATA/node-keys/sub/worker.key"
    printf 'db\n' > "$DATA/db/data"
    printf '#!/bin/sh\n' > "$LX/tn-start"
    printf '#!/bin/sh\n' > "$LX/tn-start-docker"
    printf 'unit\n' > "$BK/telcoin.service.Ab12Cd"
    printf 'pass\n' > "$BK/bls-passphrase.Ef34Gh"
    printf 'decoy\n' > "$OUT/backup-target"
    ln -s "$OUT/backup-target" "$BK/linked"
    printf 'rotate\n' > "$R/etc/logrotate.d/telcoin"
    printf 'decoy\n' > "$R/etc/logrotate.d/other"
    printf '[Journal]\n' > "$R/etc/systemd/journald.conf.d/50-telcoin.conf"
    printf 'x\n' > "$R/etc/needrestart/conf.d/50-telcoin.conf"
    printf 'decoy\n' > "$R/etc/needrestart/conf.d/10-other.conf"
    printf 'x\n' > "$R/etc/apt/apt.conf.d/52telcoin-no-reboot"
    printf 'decoy\n' > "$R/etc/apt/apt.conf.d/50unattended-upgrades"
    printf 'temp\n' > "$ETC/.tn.AbCdEf"
    printf 'decoy\n' > "$R/etc/systemd/journald.conf.d/10-other.conf"
    : > "$R/run/telcoin/update.lock"
    mkdir -p "$R/var/lib/telcoin-staging/rel.Ab12Cd" "$R/var/lib/tn-build/target"
    printf 'tarball\n' > "$R/var/lib/telcoin-staging/rel.Ab12Cd/x.tar.gz"
    printf 'bin\n' > "$R/var/lib/tn-build/target/telcoin-network"
    printf 'telcoin-log:x:990:tnrmtest\ntnrmtest:x:991:\n' > "$GROUP_FILE"
    : > "$CALLS"
    _RM_SHRED_NOTED=false
    KEPT_GROUPS=()
}

exists() { if [[ -e "$1" || -L "$1" ]]; then echo yes; else echo no; fi; }
# snapshot -- every path under the fixture root and the outside decoys.
snapshot() { find "$R" "$OUT" 2>/dev/null | sort; }
gone() { check "$1: gone" no "$(exists "$2")"; }
kept() { check "$1: kept" yes "$(exists "$2")"; }
calls() { cat "$CALLS"; }

# --- stop_and_disable_service: unit, backups, drop-in -------------------------
mkfixture
stop_and_disable_service telcoin > "$T/out" 2>&1
gone "unit" "$SD/telcoin.service"
gone "unit .service.bak" "$SD/telcoin.service.bak.20240101"
gone "unit .bak" "$SD/telcoin.bak.1"
gone "drop-in dir" "$SD/telcoin.service.d"
gone "backup-named symlink" "$SD/telcoin.service.bak.link"
kept "symlink target outside the tree" "$OUT/unit-target"
kept "another unit's backup" "$SD/telcoin-alloy.service.bak.1"
kept "another unit" "$SD/other.service"
check_has "unit .service.bak shredded" "shred -u -- $SD/telcoin.service.bak.20240101" "$(calls)"
check_has "unit .bak shredded" "shred -u -- $SD/telcoin.bak.1" "$(calls)"
check_lacks "symlink never shredded" "telcoin.service.bak.link" "$(calls)"
check_has "systemctl stop" "systemctl stop telcoin" "$(calls)"
check_has "systemctl disable" "systemctl disable telcoin" "$(calls)"
check_has "systemctl daemon-reload" "systemctl daemon-reload" "$(calls)"

# A drop-in "directory" that is a symlink: the link goes, the target stays.
mkfixture
rm -rf "$SD/telcoin.service.d"
mkdir -p "$OUT/dropin"
printf 'x\n' > "$OUT/dropin/a.conf"
ln -s "$OUT/dropin" "$SD/telcoin.service.d"
remove_unit_leftovers telcoin > /dev/null 2>&1
gone "drop-in symlink" "$SD/telcoin.service.d"
kept "drop-in symlink target" "$OUT/dropin/a.conf"

# --- _rm_shred: failing shred, symlink, directory -----------------------------
mkfixture
SHRED_RC=1
_rm_shred "$ETC/other.txt" > /dev/null 2>&1
SHRED_RC=0
gone "failing shred still deletes" "$ETC/other.txt"
check_has "failing shred was tried" "shred -u -- $ETC/other.txt" "$(calls)"
_rm_shred "$SD/telcoin.service.bak.link" "$DATA/db" > /dev/null 2>&1
gone "_rm_shred unlinks a symlink" "$SD/telcoin.service.bak.link"
kept "_rm_shred leaves the link target" "$OUT/unit-target"
kept "_rm_shred leaves a directory" "$DATA/db/data"

# --- remove_keys: DELETE shreds keys and passphrase files ---------------------
mkfixture
remove_keys <<< "DELETE" > "$T/out" 2>&1
for f in bls-passphrase.cred bls-passphrase bls-tpm.pub bls-tpm.priv; do
    check_has "$f shredded" "shred -u -- $ETC/$f" "$(calls)"
done
check_has "node key shredded" "shred -u -- $DATA/node-keys/bls.key" "$(calls)"
check_has "nested node key shredded" "shred -u -- $DATA/node-keys/sub/worker.key" "$(calls)"
check_has "temp copy in the config dir shredded" "shred -u -- $ETC/.tn.AbCdEf" "$(calls)"
check_has ".node-meta shredded" "shred -u -- $ETC/.node-meta" "$(calls)"
gone "config dir" "$ETC"
gone "node-keys dir" "$DATA/node-keys"
kept "chain data (not the keys prompt's business)" "$DATA/db/data"
check "shred note printed once" 1 "$(grep -c 'best effort on SSDs, copy-on-write and cloud disks' "$T/out")"

mkfixture
remove_keys <<< "" > "$T/out" 2>&1
kept "keys kept without DELETE" "$DATA/node-keys/bls.key"
kept "passphrase kept without DELETE" "$ETC/bls-passphrase.cred"
check_lacks "nothing shredded without DELETE" "shred" "$(calls)"

# Legacy layout: config in /etc/telcoin/<role>, a credential in /etc/telcoin.
mkfixture
mkdir -p "$ETC/validator"
mv "$ETC/.node-meta" "$ETC/validator/.node-meta"
printf 'secret\n' > "$ETC/validator/bls-passphrase"
mkdir -p "$DATA/validator/node-keys"
printf 'k\n' > "$DATA/validator/node-keys/bls.key"
remove_keys <<< "DELETE" > "$T/out" 2>&1
check_has "legacy passphrase shredded" "shred -u -- $ETC/validator/bls-passphrase" "$(calls)"
check_has "legacy key shredded" "shred -u -- $DATA/validator/node-keys/bls.key" "$(calls)"
check_has "top-level credential shredded" "shred -u -- $ETC/bls-passphrase.cred" "$(calls)"
gone "legacy config dir" "$ETC/validator"

# --- remove_chain_data: the keys inside the data dir are shredded -------------
mkfixture
CONFIRM_ANSWER=yes
remove_chain_data > /dev/null 2>&1
CONFIRM_ANSWER=no
gone "data dir" "$DATA"
check_has "chain-data removal shreds node keys" "shred -u -- $DATA/node-keys/bls.key" "$(calls)"
check_lacks "chain-data removal does not shred the db" "$DATA/db/data" "$(calls)"

# --- node keys: odd names, symlinks, and the account that shreds them ---------
# mkkeys -- the fixture plus, inside node-keys, a file whose path carries a
# newline followed by the absolute path of a decoy outside the tree, and a
# symlink to a second decoy. Neither decoy may be overwritten or removed.
NL=$'\n'
mkkeys() {
    mkfixture
    printf 'decoy\n' > "$OUT/decoy-nl"
    printf 'decoy\n' > "$OUT/decoy-link"
    mkdir -p "$DATA/node-keys/k${NL}${OUT}"
    printf 'k\n' > "$DATA/node-keys/k${NL}${OUT}/decoy-nl"
    ln -s "$OUT/decoy-link" "$DATA/node-keys/link.key"
}
decoys_intact() {
    check "$1: decoy behind the newline name intact" "decoy" "$(cat "$OUT/decoy-nl" 2>/dev/null)"
    check "$1: symlink target intact" "decoy" "$(cat "$OUT/decoy-link" 2>/dev/null)"
}

# A data dir only this account can change: shredded here, by find.
mkkeys
if [[ -f "$DATA/node-keys/k${NL}${OUT}/decoy-nl" ]]; then
    CONFIRM_ANSWER=yes
    remove_chain_data tnrmtest tnrmtest > "$T/out" 2>&1
    CONFIRM_ANSWER=no
    decoys_intact "private tree"
    gone "private tree: data dir" "$DATA"
    check_has "private tree: key shredded" "shred -u -- $DATA/node-keys/bls.key" "$(calls)"
    check_has "private tree: nested key shredded" "shred -u -- $DATA/node-keys/sub/worker.key" "$(calls)"
    check_lacks "private tree: no account switch" "setpriv" "$(calls)"
    check_lacks "private tree: the symlink is never handed to shred" "link.key" "$(calls)"
else
    skip "private tree: newline file name" "this file system refuses a newline in a name"
fi

# A data dir another account can change (writable by others here; in production
# it belongs to the service account): find and shred run as that account.
mkkeys
chmod o+w "$DATA"
KNOWN_USER=tnrmtest
CONFIRM_ANSWER=yes
remove_chain_data tnrmtest tnrmtest > "$T/out" 2>&1
CONFIRM_ANSWER=no
KNOWN_USER=""
check_has "service-owned tree: find runs as the service account" \
    "setpriv --reuid 991 --regid 991 --clear-groups --no-new-privs -- find $DATA/node-keys -xdev -type f -exec shred -u -- {} ;" "$(calls)"
check_has "service-owned tree: key shredded" "shred -u -- $DATA/node-keys/bls.key" "$(calls)"
decoys_intact "service-owned tree"
gone "service-owned tree: data dir" "$DATA"

# The account is gone: nothing is overwritten as root in a tree it owned; the
# files are still deleted and a note says so.
mkkeys
chmod o+w "$DATA"
CONFIRM_ANSWER=yes
remove_chain_data tnrmtest tnrmtest > "$T/out" 2>&1
CONFIRM_ANSWER=no
check_lacks "account gone: nothing shredded" "shred" "$(calls)"
check_lacks "account gone: no account switch" "setpriv" "$(calls)"
check_has "account gone: note printed" "yes" "$(grep -q 'deleted without being overwritten first' "$T/out" && echo yes)"
decoys_intact "account gone"
gone "account gone: data dir" "$DATA"

# --json --scope keys: the keys are shredded as the account before it is removed.
mkkeys
chmod o+w "$DATA"
KNOWN_USER=tnrmtest
( set -e; json_remove validator keys ) 3> "$T/json" > "$T/out" 2>&1; rc=$?
KNOWN_USER=""
check_rc "json keys (service-owned tree) rc 0" 0 "$rc"
decoys_intact "json service-owned tree"
n_shred="$(grep -n "^setpriv .* find $DATA/node-keys " "$CALLS" | head -n 1 | cut -d: -f1)"
n_userdel="$(grep -n '^userdel tnrmtest' "$CALLS" | head -n 1 | cut -d: -f1)"
check "json: keys shredded before the account is removed" "yes" \
    "$([[ -n "$n_shred" && -n "$n_userdel" && $n_shred -lt $n_userdel ]] && echo yes)"

# --- remove_node_host_files ---------------------------------------------------
mkfixture
remove_node_host_files > "$T/out" 2>&1
gone "tn-start" "$LX/tn-start"
gone "tn-start-docker" "$LX/tn-start-docker"
gone "empty libexec dir" "$LX"
gone "node.env" "$ETC/node.env"
gone "backups dir" "$BK"
gone "logrotate file" "$R/etc/logrotate.d/telcoin"
gone "journald drop-in" "$R/etc/systemd/journald.conf.d/50-telcoin.conf"
gone "lock dir" "$R/run/telcoin"
gone "release staging dir" "$R/var/lib/telcoin-staging"
gone "build account home" "$R/var/lib/tn-build"
check_lacks "no userdel under a fixture root" "userdel" "$(calls)"
gone "needrestart rule" "$R/etc/needrestart/conf.d/50-telcoin.conf"
gone "apt rule" "$R/etc/apt/apt.conf.d/52telcoin-no-reboot"
kept "other needrestart rule" "$R/etc/needrestart/conf.d/10-other.conf"
kept "other apt rule" "$R/etc/apt/apt.conf.d/50unattended-upgrades"
kept "/etc/telcoin/other.txt" "$ETC/other.txt"
kept "passphrase (not a host file)" "$ETC/bls-passphrase.cred"
kept "other logrotate file" "$R/etc/logrotate.d/other"
kept "other journald drop-in" "$R/etc/systemd/journald.conf.d/10-other.conf"
kept "backup symlink target" "$OUT/backup-target"
check_has "backup shredded" "shred -u -- $BK/bls-passphrase.Ef34Gh" "$(calls)"
check_has "unit backup shredded" "shred -u -- $BK/telcoin.service.Ab12Cd" "$(calls)"
check_lacks "backup symlink never shredded" "$BK/linked" "$(calls)"

mkfixture
printf 'x\n' > "$LX/other-tool"
remove_node_host_files > /dev/null 2>&1
kept "libexec dir holding another file" "$LX/other-tool"
gone "tn-start beside another file" "$LX/tn-start"

# remove_shared_components runs it only when this is the last node.
mkfixture
INSTALLED_UNITS=(telcoin telcoin-validator)
remove_shared_components > /dev/null 2>&1
kept "host files kept while another node remains" "$LX/tn-start"
kept "backups kept while another node remains" "$BK/bls-passphrase.Ef34Gh"
INSTALLED_UNITS=(telcoin)
remove_shared_components > /dev/null 2>&1
gone "host files removed with the last node" "$LX/tn-start"
gone "backups removed with the last node" "$BK"
INSTALLED_UNITS=()

# The empty /etc/telcoin a legacy layout leaves once its role dir is gone.
mkfixture
find "$ETC" -mindepth 1 ! -name node.env -exec rm -rf {} + 2>/dev/null
remove_node_host_files > /dev/null 2>&1
gone "/etc/telcoin left empty" "$ETC"

# A symlinked /usr/local/libexec/telcoin: nothing is removed through it.
mkfixture
rm -rf "$LX"
mkdir -p "$OUT/lx"
printf 'keep\n' > "$OUT/lx/tn-start"
ln -s "$OUT/lx" "$LX"
remove_node_host_files > "$T/out" 2>&1
kept "symlinked libexec: file behind it" "$OUT/lx/tn-start"
kept "symlinked libexec: the link" "$LX"
check_has "symlinked libexec: warned" "yes" "$(grep -q 'libexec/telcoin is a symlink' "$T/out" && echo yes)"
mkfixture
rm -rf "$LX" "$ETC" "$DATA" "$BK" "$SD/telcoin.service" "$SD/telcoin.service.bak.20240101" "$SD/telcoin.bak.1" \
       "$SD/telcoin.service.d" "$SD/telcoin.service.bak.link"
mkdir -p "$OUT/lx"
printf 'keep\n' > "$OUT/lx/tn-start"
ln -s "$OUT/lx" "$LX"
( set -e; json_remove validator keys ) 3> "$T/json" > "$T/out" 2>&1; rc=$?
check_rc "only a symlinked libexec left: rc 1" 1 "$rc"
check_has "only a symlinked libexec left: no node installed" "yes" "$(grep -q 'no node installed' "$T/json" && echo yes)"

# Backups under the names older releases used, with or without a suffix, and
# those of the legacy unit names when that unit is not installed.
mkfixture
for f in telcoin.service.bak telcoin.bak telcoin-validator.service.bak.1 telcoin-observer.bak.2 \
         telcoin-observer.service.bak; do
    printf 'Environment=TN_BLS_PASSPHRASE=x\n' > "$SD/$f"
done
mkdir -p "$SD/telcoin-observer.service.d"
stop_and_disable_service telcoin > /dev/null 2>&1
for f in telcoin.service.bak telcoin.bak telcoin-validator.service.bak.1 telcoin-observer.bak.2 \
         telcoin-observer.service.bak; do
    gone "old backup $f" "$SD/$f"
    check_has "old backup $f shredded" "shred -u -- $SD/$f" "$(calls)"
done
gone "drop-in dir of a legacy name with no unit" "$SD/telcoin-observer.service.d"

mkfixture
printf '[Service]\n' > "$SD/telcoin-validator.service"
printf 'x\n' > "$SD/telcoin-validator.service.bak.1"
mkdir -p "$SD/telcoin-validator.service.d"
stop_and_disable_service telcoin > /dev/null 2>&1
kept "an installed unit's backup" "$SD/telcoin-validator.service.bak.1"
kept "an installed unit's drop-in dir" "$SD/telcoin-validator.service.d"
kept "the installed unit" "$SD/telcoin-validator.service"

# --- the update lock ------------------------------------------------------------
# hold_lock -- hold the fixture's update lock from a background shell until
# release_lock.
hold_lock() {
    rm -f "$T/held" "$T/release"
    # shellcheck disable=SC2034  # both are read by tn_acquire_update_lock
    ( TN_UPDATE_LOCK_FILE="$R/run/telcoin/update.lock"; TN_EXIT_TRAP_OWNED=1
      tn_acquire_update_lock > /dev/null 2>&1 || exit 1
      : > "$T/held"
      while [ ! -f "$T/release" ]; do sleep 1 9>&-; done
      tn_release_update_lock ) &
    HOLDER=$!
    local i=0
    while [[ ! -f "$T/held" && $i -lt 20 ]]; do sleep 1; i=$((i + 1)); done
}
release_lock() {
    : > "$T/release"
    wait "$HOLDER" 2>/dev/null
}

mkfixture
hold_lock
check "lock holder ready" "yes" "$([[ -f "$T/held" ]] && echo yes)"
before="$(snapshot)"
( set -e; json_remove validator keys ) 3> "$T/json" > "$T/out" 2>&1; rc=$?
check_rc "json while another run holds the lock: rc 1" 1 "$rc"
check_has "json names the lock" "yes" "$(grep -q '"event":"error".*holds the update lock' "$T/json" && echo yes)"
check "json while locked: nothing removed" "$before" "$(snapshot)"
check_lacks "json while locked: no call" "systemctl" "$(calls)"

detect_node_installs 2> /dev/null
set +e
( CONFIRM_ANSWER=yes; remove_all_nodes ) < /dev/null > "$T/out" 2>&1
check "menu while locked: nothing removed" "$before" "$(snapshot)"
check_has "menu while locked: said why" "yes" "$(grep -q 'holds the update lock' "$T/out" && echo yes)"
INSTALLED_UNITS=()

rm -f "$SD/telcoin.service"
before="$(snapshot)"
( CONFIRM_ANSWER=yes; remove_leftovers; echo "rc=$?" ) > "$T/out" 2>&1
check_has "leftovers while locked: rc 1" "rc=1" "$(cat "$T/out")"
check "leftovers while locked: nothing removed" "$before" "$(snapshot)"
release_lock

# The lock lives in /run/telcoin: that directory goes last, after the release.
mkfixture
( set -e; json_remove validator keys ) 3> "$T/json" > "$T/out" 2>&1; rc=$?
check_rc "json keys with the lock in /run/telcoin: rc 0" 0 "$rc"
check_has "json: /run/telcoin left for the end" "yes" "$(grep -q 'removed when the run ends' "$T/out" && echo yes)"
gone "json: /run/telcoin removed at the end" "$R/run/telcoin"
check_has "json: config temp copy shredded" "shred -u -- $ETC/.tn.AbCdEf" "$(calls)"

# --- remove_log_group / remove_service_user -----------------------------------
mkfixture
remove_service_user tnrmtest tnrmtest telcoin > "$T/out" 2>&1
check_has "telcoin-log removed" "groupdel telcoin-log" "$(calls)"
check_lacks "declined service group kept" "groupdel tnrmtest" "$(calls)"

# The service user is kept: removing telcoin-log is asked, not done silently.
# confirm answers from ANSWERS (one word each) and logs the prompts.
answer_confirm() {
    local a="${ANSWERS%% *}"
    ANSWERS="${ANSWERS#* }"
    printf '%s\n' "$1" >> "$T/prompts"
    [[ "$a" == "yes" ]]
}
mkfixture
: > "$T/prompts"
( KNOWN_USER=tnrmtest; ANSWERS="no no no "; confirm() { answer_confirm "$@"; }
  remove_service_user tnrmtest tnrmtest telcoin ) > "$T/out" 2>&1
check_has "kept user: telcoin-log question asked" "yes" "$(grep -q 'log-reader group .telcoin-log.' "$T/prompts" && echo yes)"
check_lacks "kept user, declined: telcoin-log kept" "groupdel telcoin-log" "$(calls)"
check_lacks "kept user: no userdel" "userdel" "$(calls)"
mkfixture
: > "$T/prompts"
( KNOWN_USER=tnrmtest; ANSWERS="no no yes "; confirm() { answer_confirm "$@"; }
  remove_service_user tnrmtest tnrmtest telcoin ) > "$T/out" 2>&1
check_has "kept user, accepted: telcoin-log removed" "groupdel telcoin-log" "$(calls)"
mkfixture
: > "$T/prompts"
( KNOWN_USER=tnrmtest; ANSWERS="yes yes "; confirm() { answer_confirm "$@"; }
  id() { if [[ "$*" == tnrmtest ]] && grep -q '^userdel tnrmtest' "$CALLS"; then return 1; fi; command id "$@"; }
  remove_service_user tnrmtest tnrmtest telcoin ) > "$T/out" 2>&1
check_lacks "user removed: no telcoin-log question" "log-reader group" "$(cat "$T/prompts")"
check_has "user removed: telcoin-log removed" "groupdel telcoin-log" "$(calls)"

mkfixture
printf 'telcoin-log:x:990:tnrmtest,alice\n' > "$GROUP_FILE"
remove_log_group tnrmtest telcoin > "$T/out" 2>&1
check_lacks "telcoin-log with another member kept" "groupdel" "$(calls)"
check "kept group recorded" "telcoin-log" "${KEPT_GROUPS[*]-}"
check_has "kept group reported" "yes" "$(grep -q 'other members (alice)' "$T/out" && echo yes)"

mkfixture
printf '[Service]\n' > "$SD/telcoin-validator.service"
remove_log_group tnrmtest telcoin > /dev/null 2>&1
check_lacks "telcoin-log kept while another node remains" "groupdel" "$(calls)"
check "kept group recorded (other node)" "telcoin-log" "${KEPT_GROUPS[*]-}"

mkfixture
printf 'tnrmtest:x:991:\n' > "$GROUP_FILE"
remove_log_group tnrmtest telcoin > /dev/null 2>&1; rc=$?
check_rc "absent telcoin-log rc 0" 0 "$rc"
check_lacks "absent telcoin-log: no groupdel" "groupdel" "$(calls)"

# --- duplicated .node-meta keys stop the removal -------------------------------

for key in HOST_SERVICE_USER HOST_SERVICE_GROUP INSTALL_METHOD DATA_DIR; do
    mkfixture
    printf '%s=a\n%s=b\n' "$key" "$key" >> "$ETC/.node-meta"
    before="$(snapshot)"
    detect_node_installs 2> "$T/err"
    set +e
    check "dup ${key}: unit blocked" "telcoin" "${BLOCKED_UNITS[*]-}"
    check_has "dup ${key}: error names the key" "yes" "$(grep -q "${key} is set more than once" "$T/err" && echo yes)"
    remove_node_unit telcoin > "$T/out" 2>&1; rc=$?
    check "dup ${key}: remove_node_unit refused" "yes" "$([[ $rc -ne 0 ]] && echo yes)"
    check "dup ${key}: nothing deleted (interactive)" "$before" "$(snapshot)"
    check_lacks "dup ${key}: no systemctl call" "systemctl stop" "$(calls)"

    : > "$CALLS"
    json_remove validator keys 3> "$T/json" > /dev/null 2>&1; rc=$?
    check_rc "dup ${key}: json_remove rc 1" 1 "$rc"
    check_has "dup ${key}: json error names the key" "yes" "$(grep -q "\"event\":\"error\".*${key} is set more than once" "$T/json" && echo yes)"
    check "dup ${key}: nothing deleted (json)" "$before" "$(snapshot)"
    check_lacks "dup ${key}: json made no call" "systemctl" "$(calls)"
    check_lacks "dup ${key}: json shredded nothing" "shred" "$(calls)"
done
INSTALLED_UNITS=()
BLOCKED_UNITS=()

mkfixture
printf 'DATA_DIR=%s\nDATA_DIR=%s\n' "$DATA" "$DATA" >> "$ETC/.node-meta"
out="$(detect_data_dir 2>/dev/null)"; rc=$?
check_rc "dup DATA_DIR: detect_data_dir rc 2" 2 "$rc"
check "dup DATA_DIR: detect_data_dir prints no path" "" "$out"

# --- json_remove --scope keys: the whole set, under set -e ---------------------
mkfixture
( set -e; json_remove validator keys ) 3> "$T/json" > "$T/out" 2>&1; rc=$?
check_rc "json keys rc 0 under set -e" 0 "$rc"
check_has "json done event" "yes" "$(grep -q '"event":"done","ok":true' "$T/json" && echo yes)"
for p in "$SD/telcoin.service" "$SD/telcoin.service.bak.20240101" "$SD/telcoin.bak.1" \
         "$SD/telcoin.service.d" "$SD/telcoin.service.bak.link" "$ETC" "$DATA" "$LX" "$BK" \
         "$R/etc/logrotate.d/telcoin" "$R/etc/systemd/journald.conf.d/50-telcoin.conf" "$R/run/telcoin"; do
    gone "json ${p#"$R"}" "$p"
done
kept "json: symlink target outside the tree" "$OUT/unit-target"
kept "json: backup symlink target" "$OUT/backup-target"
kept "json: another unit's backup" "$SD/telcoin-alloy.service.bak.1"
kept "json: other logrotate file" "$R/etc/logrotate.d/other"
kept "json: other journald drop-in" "$R/etc/systemd/journald.conf.d/10-other.conf"
for f in "$SD/telcoin.service.bak.20240101" "$ETC/bls-passphrase.cred" "$ETC/bls-passphrase" \
         "$ETC/bls-tpm.pub" "$ETC/bls-tpm.priv" "$DATA/node-keys/bls.key" "$BK/bls-passphrase.Ef34Gh"; do
    check_has "json shredded ${f#"$R"}" "shred -u -- $f" "$(calls)"
done
check_has "json telcoin-log removed" "groupdel telcoin-log" "$(calls)"
check_has "json reports the log group" "yes" "$(grep -q 'Group telcoin-log removed' "$T/json" && echo yes)"

# --- an interrupted removal can be finished ------------------------------------
# mkinterrupted -- the fixture after a removal stopped right after the unit file
# went: .node-meta, the keys, the backups, the start scripts and an unshredded
# unit backup are still here.
mkinterrupted() {
    mkfixture
    rm -f "$SD/telcoin.service"
}

mkinterrupted
( set -e; json_remove validator keys ) 3> "$T/json" > "$T/out" 2>&1; rc=$?
check_rc "resume json keys: rc 0" 0 "$rc"
check_has "resume json keys: done event" "yes" "$(grep -q '"event":"done","ok":true' "$T/json" && echo yes)"
check_lacks "resume json keys: no error event" '"event":"error"' "$(cat "$T/json")"
for p in "$SD/telcoin.service.bak.20240101" "$SD/telcoin.bak.1" "$SD/telcoin.service.d" "$ETC" "$DATA" \
         "$LX" "$BK" "$R/etc/logrotate.d/telcoin" "$R/etc/systemd/journald.conf.d/50-telcoin.conf"; do
    gone "resume json keys ${p#"$R"}" "$p"
done
for f in "$SD/telcoin.service.bak.20240101" "$ETC/bls-passphrase.cred" "$DATA/node-keys/bls.key" \
         "$BK/bls-passphrase.Ef34Gh"; do
    check_has "resume json keys shredded ${f#"$R"}" "shred -u -- $f" "$(calls)"
done
kept "resume json keys: another unit's backup" "$SD/telcoin-alloy.service.bak.1"
kept "resume json keys: symlink target outside the tree" "$OUT/unit-target"

# Run again with nothing left: there is no node.
: > "$CALLS"
( set -e; json_remove validator keys ) 3> "$T/json" > "$T/out" 2>&1; rc=$?
check_rc "nothing left: rc 1" 1 "$rc"
check_has "nothing left: no node installed" "yes" "$(grep -q '"event":"error","msg":"no node installed"' "$T/json" && echo yes)"
check_lacks "nothing left: no call" "systemctl" "$(calls)"

# Only the start scripts and the backups left: still finished.
mkinterrupted
rm -rf "$ETC" "$DATA" "$SD/telcoin.service.bak.20240101" "$SD/telcoin.bak.1" "$SD/telcoin.service.d" "$SD/telcoin.service.bak.link"
( set -e; json_remove observer keys ) 3> "$T/json" > "$T/out" 2>&1; rc=$?
check_rc "scripts and backups left: rc 0" 0 "$rc"
gone "scripts and backups left: start scripts" "$LX"
gone "scripts and backups left: backups" "$BK"

# --scope service with the unit gone: done, keys and data kept.
mkinterrupted
( set -e; json_remove validator service ) 3> "$T/json" > "$T/out" 2>&1; rc=$?
check_rc "resume json service: rc 0" 0 "$rc"
check_has "resume json service: done event" "yes" "$(grep -q '"event":"done","ok":true' "$T/json" && echo yes)"
gone "resume json service: unit backup" "$SD/telcoin.service.bak.20240101"
kept "resume json service: node key" "$DATA/node-keys/bls.key"
kept "resume json service: passphrase" "$ETC/bls-passphrase.cred"

# The menu with no unit: remove_leftovers lists and removes what is left,
# including a data dir .node-meta records outside /var/lib/telcoin.
mkleftover() {
    mkinterrupted
    CUST="$R/srv/tn-data"
    mkdir -p "$CUST/node-keys" "$CUST/db"
    printf 'k\n' > "$CUST/node-keys/bls.key"
    printf 'db\n' > "$CUST/db/data"
    printf 'DATA_DIR=%s\n' "$CUST" >> "$ETC/.node-meta"
    mkdir -p "$DATA/validator/node-keys"
    printf 'k\n' > "$DATA/validator/node-keys/bls.key"
    printf 'decoy\n' > "$R/srv/keep"
}
mkleftover
CONFIRM_ANSWER=yes
( remove_leftovers; echo "rc=$?" ) > "$T/out" 2>&1
CONFIRM_ANSWER=no
check_has "leftovers: rc 0" "rc=0" "$(cat "$T/out")"
for want in /var/lib/telcoin /srv/tn-data /etc/telcoin /usr/local/libexec/telcoin/tn-start \
            /usr/local/libexec/telcoin/tn-start-docker /var/backups/telcoin \
            "unit backups and drop-ins in /etc/systemd/system"; do
    check_has "leftovers: listed ${want}" "yes" "$(grep -qF -- "  ${want}" "$T/out" && echo yes)"
done
for p in "$DATA" "$CUST" "$ETC" "$LX" "$BK" "$SD/telcoin.service.bak.20240101" "$SD/telcoin.service.d" \
         "$R/etc/logrotate.d/telcoin" "$R/etc/systemd/journald.conf.d/50-telcoin.conf"; do
    gone "leftovers ${p#"$R"}" "$p"
done
for f in "$DATA/node-keys/bls.key" "$DATA/validator/node-keys/bls.key" "$CUST/node-keys/bls.key" \
         "$ETC/bls-passphrase.cred" "$ETC/bls-passphrase" "$ETC/.node-meta" "$BK/bls-passphrase.Ef34Gh" \
         "$SD/telcoin.service.bak.20240101"; do
    check_has "leftovers shredded ${f#"$R"}" "shred -u -- $f" "$(calls)"
done
check_lacks "leftovers: chain db not shredded" "$CUST/db/data" "$(calls)"
kept "leftovers: a file beside the custom data dir" "$R/srv/keep"
kept "leftovers: another unit's backup" "$SD/telcoin-alloy.service.bak.1"
kept "leftovers: backup symlink target" "$OUT/backup-target"

mkleftover
before="$(find "$R" "$OUT" | sort)"
( remove_leftovers; echo "rc=$?" ) > "$T/out" 2>&1
check_has "leftovers declined: rc 0" "rc=0" "$(cat "$T/out")"
check "leftovers declined: nothing removed" "$before" "$(find "$R" "$OUT" | sort)"

mkleftover
printf 'DATA_DIR=%s\n' "$CUST" >> "$ETC/.node-meta"
before="$(find "$R" "$OUT" | sort)"
CONFIRM_ANSWER=yes
( remove_leftovers; echo "rc=$?" ) > "$T/out" 2>&1
CONFIRM_ANSWER=no
check_has "leftovers with a duplicated key: rc 1" "rc=1" "$(cat "$T/out")"
check "leftovers with a duplicated key: nothing removed" "$before" "$(find "$R" "$OUT" | sort)"

rm -rf "$R"; mkdir -p "$R"
( remove_leftovers; echo "rc=$?" ) > "$T/out" 2>&1
check_has "no leftovers: rc 3" "rc=3" "$(cat "$T/out")"

# The menu reaches remove_leftovers when no node unit is installed.
mkleftover
( confirm() { case "$1" in Remove*) return 0 ;; *) return 1 ;; esac; }
  scan_custom_installs() { echo "SCAN"; }
  set -e; detect_node_installs; show_detected; echo "not reached" ) > "$T/out" 2>&1; rc=$?
check_rc "menu leftovers: exits 0" 0 "$rc"
gone "menu leftovers: config tree" "$ETC"
gone "menu leftovers: custom data dir" "$CUST"
gone "menu leftovers: start scripts" "$LX"
check_lacks "menu leftovers: scan declined" "SCAN" "$(cat "$T/out")"

# --scope service keeps keys, data and the shared host files.
mkfixture
( set -e; json_remove observer service ) 3> "$T/json" > /dev/null 2>&1; rc=$?
check_rc "json service rc 0" 0 "$rc"
gone "json service: unit backup" "$SD/telcoin.service.bak.20240101"
kept "json service: passphrase" "$ETC/bls-passphrase.cred"
kept "json service: start script" "$LX/tn-start"
kept "json service: backups" "$BK/bls-passphrase.Ef34Gh"
check_lacks "json service: no groupdel" "groupdel" "$(calls)"

finish
