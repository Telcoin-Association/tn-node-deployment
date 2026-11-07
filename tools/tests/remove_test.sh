#!/usr/bin/env bash
# =============================================================================
# tools/tests/remove_test.sh -- remove-node.sh's teardown of the files beside a
# node: the unit's old backups and drop-in directory (also under older and
# legacy names), the key, passphrase and config files (shredded by find, as the
# service account where the tree is not this account's own, never through a
# symlink or a split name), the shared host files (start scripts, node.env,
# backups, logrotate, journald, needrestart and apt files; the lock directory and
# its lock file stay; a symlinked libexec dir left alone), the log-reader group,
# the JSON path, finishing a removal that stopped part way (JSON and the menu's
# leftover path), the update lock, the refusal to remove anything when
# .node-meta sets a key more than once, the Alloy ingest token file shredded
# by the add-on teardown, and the private alerts removed before the node stops
# (every scope, the menu, the leftover path; not the chain-data-only wipe; also
# with no lib/alerts.sh).
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
# nft: table inet tn_p2p is the file NFT_TABLE_FILE and table inet tn_p2p_allow
# the file NFT_ALLOW_FILE (no file: no table), so no real nft ever runs here.
# NFT_FAIL=1 makes `-f` fail, NFT_LIST_FAIL=1 `list tables`.
NFT_TABLE_FILE="$T/nft.table"
NFT_ALLOW_FILE="$T/nft.allow"
export NFT_TABLE_FILE NFT_ALLOW_FILE
cat > "$T/bin/nft" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "nft $*" >> "$CALLS"
case "$*" in
    "list tables")
        [ -z "${NFT_LIST_FAIL:-}" ] || exit 1
        if [ -f "$NFT_TABLE_FILE" ]; then echo "table inet tn_p2p"; fi
        if [ -f "$NFT_ALLOW_FILE" ]; then echo "table inet tn_p2p_allow"; fi
        exit 0 ;;
    "-f -")
        prog="$(cat)"
        printf '%s\n' "$prog" | sed 's/^/nft| /' >> "$CALLS"
        [ -z "${NFT_FAIL:-}" ] || exit 1
        if printf '%s\n' "$prog" | grep -qx 'delete table inet tn_p2p'; then rm -f "$NFT_TABLE_FILE"; fi
        if printf '%s\n' "$prog" | grep -qx 'delete table inet tn_p2p_allow'; then rm -f "$NFT_ALLOW_FILE"; fi
        exit 0 ;;
esac
exit 0
STUB
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
kept "lock dir stays" "$R/run/telcoin"
kept "lock file stays" "$R/run/telcoin/update.lock"
check_has "says /run/telcoin stays" "yes" "$(grep -q '/run/telcoin stays' "$T/out" && echo yes)"
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

# The lock lives in /run/telcoin: a removal leaves the directory and the lock
# file as they are (same inode), the library's EXIT trap is the one in place
# when the removal returns, and the lock is free once the run has ended.
ino_of() { ls -i -- "$1" | awk '{print $1}'; }
mkfixture
before="$(ino_of "$R/run/telcoin/update.lock")"
check "lock inode read" "yes" "$([[ "$before" =~ ^[0-9]+$ ]] && echo yes)"
rm -f "$T/trap"
( set -e; json_remove validator keys; trap -p EXIT > "$T/trap" ) 3> "$T/json" > "$T/out" 2>&1; rc=$?
check_rc "json keys with the lock in /run/telcoin: rc 0" 0 "$rc"
check "lock inode unchanged by a removal" "$before" "$(ino_of "$R/run/telcoin/update.lock")"
kept "json: lock dir stays" "$R/run/telcoin"
kept "json: lock file stays" "$R/run/telcoin/update.lock"
check_has "json: says /run/telcoin stays" "yes" "$(grep -q '/run/telcoin stays' "$T/out" && echo yes)"
check "json: the library EXIT trap releases the lock" "yes" \
    "$(grep -qE 'tn_release_update_lock|update\.lock\.d' "$T/trap" 2>/dev/null && echo yes)"
gone "json: no mkdir lock left behind" "$R/run/telcoin/update.lock.d"
hold_lock
check "json: the lock is free after the run" "yes" "$([[ -f "$T/held" ]] && echo yes)"
release_lock
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
         "$R/etc/logrotate.d/telcoin" "$R/etc/systemd/journald.conf.d/50-telcoin.conf"; do
    gone "json ${p#"$R"}" "$p"
done
kept "json: /run/telcoin stays" "$R/run/telcoin"
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

# _rm_build_account: the build account's processes are stopped before userdel, and
# OK is printed only when userdel succeeds.
for urc in 1 0; do
    : > "$T/order"
    ( id() { case "$*" in "-u tn-build"|"-g tn-build") echo 990 ;; *) command id "$@" ;; esac; }
      _tn_build_user_reap() { echo "REAP $*" >> "$T/order"; }
      userdel() { echo "USERDEL $*" >> "$T/order"; return "$urc"; }
      _rm_build_account ) > "$T/out" 2>&1
    check "build account, userdel rc $urc: processes stopped, then userdel" "REAP 990 990|USERDEL tn-build" \
        "$(tr '\n' '|' < "$T/order" | sed 's/|$//')"
    if [[ $urc -ne 0 ]]; then
        check_lacks "userdel failed: no OK" "Removed the tn-build account" "$(cat "$T/out")"
        check "userdel failed: a warning with the manual step" yes "$(grep -q 'Could not remove the tn-build account.*sudo userdel tn-build' "$T/out" && echo yes || echo no)"
    else
        check "userdel succeeded: OK" yes "$(grep -q 'Removed the tn-build account' "$T/out" && echo yes || echo no)"
    fi
done
( id() { case "$*" in *tn-build*) return 1 ;; *) command id "$@" ;; esac; }
  userdel() { echo "USERDEL $*" >> "$T/order"; }
  : > "$T/order"
  _rm_build_account ) > "$T/out" 2>&1
check "no build account: nothing done" "" "$(cat "$T/out" "$T/order")"

# KEYS
# --- the shred note: shred is not decommissioning, said once per run ----------
mkfixture
remove_keys <<< "DELETE" > "$T/out" 2>&1
check "shred note: the destruction sentence, once" 1 \
    "$(grep -c 'Decommissioning a host that held a validator key means destroying or crypto-erasing its disk and deleting every snapshot and image taken from it; shred alone does not do that.' "$T/out")"
check "shred note: the best-effort sentence still once" 1 "$(grep -c 'best effort on SSDs, copy-on-write and cloud disks' "$T/out")"
check "shred note: several files were shredded in that run" yes \
    "$([[ "$(grep -c '^shred -u' "$CALLS")" -gt 1 ]] && echo yes || echo no)"
# A later shred in the same run prints nothing more.
printf 'x\n' > "$R/etc/second.txt"
_rm_shred "$R/etc/second.txt" > "$T/out2" 2>&1
check_has "shred note: the later file was shredded" "shred -u -- $R/etc/second.txt" "$(calls)"
check "shred note: not repeated later in the run" "0 0" \
    "$(grep -c 'Decommissioning a host' "$T/out2") $(grep -c 'best effort on SSDs' "$T/out2")"

# OBS
# --- the add-on teardown shreds the Alloy ingest token file -----------------------
# The real remove_testnet_addons (stubbed above for the other cases), taken from the
# sourced copy; ufw is reported absent so no host firewall rule is touched.
REAL_RTA="$(awk '/^remove_testnet_addons\(\) \{/,/^}/' "$T/h/remove-node.sh")"
AL="$R/etc/telcoin/alloy"
mkdir -p "$AL" "$SD"
printf 'obs-token-0123456789abcdef\n' > "$AL/ingest-token"
printf 'TN_NODE=n\nOBS_INGEST_TOKEN=legacy-token-0123456789\n' > "$AL/telcoin-alloy.env"
printf 'loki.write "central" {}\n' > "$AL/config.alloy"
printf '[Service]\n' > "$SD/telcoin-alloy.service"
: > "$CALLS"
( ufw_installed() { return 1; }; eval "$REAL_RTA"; remove_testnet_addons ) > "$T/out" 2>&1
check_rc "add-on teardown: rc 0" 0 $?
check_has "add-on teardown: the token file shredded" "shred -u -- $AL/ingest-token" "$(calls)"
check_has "add-on teardown: the env file (may hold an older token) shredded" "shred -u -- $AL/telcoin-alloy.env" "$(calls)"
check_lacks "add-on teardown: config.alloy is removed, not shredded" "$AL/config.alloy" "$(calls)"
gone "add-on teardown: the token file" "$AL/ingest-token"
gone "add-on teardown: the Alloy config dir" "$AL"
gone "add-on teardown: the Alloy unit" "$SD/telcoin-alloy.service"
check_lacks "add-on teardown: the token is not printed" "obs-token-0123456789abcdef" "$(cat "$T/out")"

# --- the P2P committee allowlist goes with the last node: units, table, binary, state
AL_DIR="$R/var/lib/telcoin-p2p-allow"
AL_BIN="$LX/tn-p2p-allow-sync"
AL_UNITS="telcoin-p2p-allow.service telcoin-p2p-allow-sync.service telcoin-p2p-allow-sync.timer"
# A firewall-setup.sh beside the sourced copy and the tool binary log a line if
# they ever run: the teardown runs neither.
printf '#!/bin/sh\necho "FWSETUP-RAN $*" >> "$CALLS"\n' > "$T/h/firewall-setup.sh"
# p2p_allow_fixture -- what firewall-setup.sh --p2p-committee on leaves: the three
# units, the state dir, the tool binary and the table.
p2p_allow_fixture() {
    local u
    mkdir -p "$SD" "$LX" "$AL_DIR"
    for u in $AL_UNITS; do
        printf '[Unit]\nDescription=allow\n' > "$SD/$u"
    done
    printf 'RPC_PORT=8545\n' > "$AL_DIR/config"
    printf 'table inet tn_p2p_allow {\n}\n' > "$AL_DIR/current.nft"
    : > "$AL_DIR/lock"
    printf '#!/bin/sh\necho "TOOL-RAN $*" >> "$CALLS"\n' > "$AL_BIN"
    chmod 0755 "$AL_BIN"
    printf 'table inet tn_p2p_allow {\n}\n' > "$NFT_ALLOW_FILE"
    : > "$CALLS"
}
# allow_said -- the teardown's own lines from the last output, in order.
allow_said() {
    awk '/p2p-allow|tn_p2p_allow/ { i = index($0, "Removed /"); if (!i) i = index($0, "Deleted the P2P"); if (i) print substr($0, i) }' "$T/out"
}
mkfixture; p2p_allow_fixture
remove_node_host_files > "$T/out" 2>&1
for u in $AL_UNITS; do
    gone "p2p allow unit $u" "$SD/$u"
done
gone "p2p allow state dir" "$AL_DIR"
gone "p2p allow binary" "$AL_BIN"
gone "p2p allow: libexec dir removed once empty" "$LX"
check "p2p allow: table deleted" "no" "$(exists "$NFT_ALLOW_FILE")"
check "p2p allow: units stopped, the timer first, the sync service only stopped" "systemctl disable --now telcoin-p2p-allow-sync.timer
systemctl stop telcoin-p2p-allow-sync.service
systemctl disable --now telcoin-p2p-allow.service" "$(grep 'telcoin-p2p-allow' "$CALLS")"
check "p2p allow: daemon-reload after the units" "systemctl daemon-reload" \
    "$(awk 'p { print; exit } $0 == "systemctl disable --now telcoin-p2p-allow.service" { p = 1 }' "$CALLS")"
check "p2p allow: one delete transaction" "nft| table inet tn_p2p_allow
nft| delete table inet tn_p2p_allow" "$(grep '^nft| ' "$CALLS")"
check "p2p allow: said, in order, the state dir last" "Removed /etc/systemd/system/telcoin-p2p-allow-sync.timer
Removed /etc/systemd/system/telcoin-p2p-allow-sync.service
Removed /etc/systemd/system/telcoin-p2p-allow.service
Deleted the P2P committee allowlist (nftables table inet tn_p2p_allow)
Removed /usr/local/libexec/telcoin/tn-p2p-allow-sync
Removed /var/lib/telcoin-p2p-allow" "$(allow_said)"
check_lacks "p2p allow: the tool never runs" "TOOL-RAN" "$(calls)"
check_lacks "p2p allow: firewall-setup.sh never runs" "FWSETUP-RAN" "$(calls)"
kept "p2p allow: other unit" "$SD/telcoin.service"
# Nothing of it here: no unit call and no delete transaction for it.
mkfixture; : > "$CALLS"; rm -f "$NFT_ALLOW_FILE"
remove_node_host_files > /dev/null 2>&1
check_lacks "p2p allow absent: no unit call" "telcoin-p2p-allow" "$(calls)"
check_lacks "p2p allow absent: no delete transaction" "tn_p2p_allow" "$(calls)"
# nft refuses the delete: a warning, the rest goes, and the state dir stays for a later run.
mkfixture; p2p_allow_fixture
NFT_FAIL=1 remove_node_host_files > "$T/out" 2>&1
check_has "p2p allow: refused delete warned" "yes" \
    "$(grep -qF 'Could not delete the nftables table inet tn_p2p_allow, so /var/lib/telcoin-p2p-allow stays for a later removal to try again; remove the table with: sudo nft delete table inet tn_p2p_allow' "$T/out" && echo yes)"
kept "p2p allow, refused delete: state dir" "$AL_DIR"
gone "p2p allow, refused delete: timer still removed" "$SD/telcoin-p2p-allow-sync.timer"
gone "p2p allow, refused delete: binary still removed" "$AL_BIN"
gone "p2p allow, refused delete: node.env still removed" "$ETC/node.env"
# A listing that fails is not read as "no table": the delete is tried.
mkfixture; p2p_allow_fixture
NFT_LIST_FAIL=1 remove_node_host_files > "$T/out" 2>&1
check "p2p allow, listing failed: table deleted" "no" "$(exists "$NFT_ALLOW_FILE")"
gone "p2p allow, listing failed: state dir" "$AL_DIR"
# ... but only where the allowlist left a unit, the state dir or the binary: with
# none of them the delete would print a result that says nothing.
mkfixture; : > "$CALLS"; rm -f "$NFT_ALLOW_FILE"
NFT_LIST_FAIL=1 remove_node_host_files > "$T/out" 2>&1
check_lacks "p2p allow absent, listing failed: no delete transaction" "tn_p2p_allow" "$(calls)"
check_lacks "p2p allow absent, listing failed: nothing said of the table" "tn_p2p_allow" "$(cat "$T/out")"
mkfixture; : > "$CALLS"; rm -f "$NFT_ALLOW_FILE"
NFT_LIST_FAIL=1 NFT_FAIL=1 remove_node_host_files > "$T/out" 2>&1
check_lacks "p2p allow absent, listing and delete failing: no false warning" "Could not delete the nftables table inet tn_p2p_allow" "$(cat "$T/out")"
for part in "$AL_DIR" "$AL_BIN"; do
    mkfixture; p2p_allow_fixture
    for u in $AL_UNITS; do rm -f "$SD/$u"; done
    [[ "$part" == "$AL_DIR" ]] && rm -f "$AL_BIN"
    [[ "$part" == "$AL_BIN" ]] && rm -rf "$AL_DIR"
    NFT_LIST_FAIL=1 remove_node_host_files > "$T/out" 2>&1
    check "p2p allow, listing failed, only ${part#"$R"} left: the delete is tried" "nft| table inet tn_p2p_allow
nft| delete table inet tn_p2p_allow|no" "$(grep '^nft| ' "$CALLS")|$(exists "$NFT_ALLOW_FILE")"
done
# A symlinked state dir is left, its target untouched, with a warning.
mkfixture; p2p_allow_fixture
rm -rf "$AL_DIR"; mkdir -p "$OUT/allow-target"; printf 'x\n' > "$OUT/allow-target/config"
ln -s "$OUT/allow-target" "$AL_DIR"
remove_node_host_files > "$T/out" 2>&1
kept "p2p allow, symlinked state dir: the link" "$AL_DIR"
kept "p2p allow, symlinked state dir: its target's file" "$OUT/allow-target/config"
check_has "p2p allow, symlinked state dir: warned" "yes" \
    "$(grep -qF '/var/lib/telcoin-p2p-allow is a symlink: it is left in place.' "$T/out" && echo yes)"
# Nothing is removed through a symlinked libexec dir.
mkfixture; p2p_allow_fixture
mkdir -p "$OUT/lx"; mv "$AL_BIN" "$OUT/lx/"; rm -rf "$LX"; ln -s "$OUT/lx" "$LX"
remove_node_host_files > "$T/out" 2>&1
kept "p2p allow, symlinked libexec: the binary behind it" "$OUT/lx/tn-p2p-allow-sync"
kept "p2p allow, symlinked libexec: the link" "$LX"
gone "p2p allow, symlinked libexec: the state dir still goes" "$AL_DIR"
# Another node remains: the allowlist stays (its P2P ports are still served).
mkfixture; p2p_allow_fixture
INSTALLED_UNITS=(telcoin telcoin-validator)
remove_shared_components > /dev/null 2>&1
kept "p2p allow while another node remains: timer" "$SD/telcoin-p2p-allow-sync.timer"
kept "p2p allow while another node remains: state dir" "$AL_DIR"
kept "p2p allow while another node remains: binary" "$AL_BIN"
check "p2p allow while another node remains: table" "yes" "$(exists "$NFT_ALLOW_FILE")"
INSTALLED_UNITS=()
# The leftover path: only the timer unit and the table are left.
rm -rf "$R"; mkdir -p "$SD" "$R/run/telcoin"
printf '[Unit]\nDescription=allow\n' > "$SD/telcoin-p2p-allow-sync.timer"
printf 'table inet tn_p2p_allow {\n}\n' > "$NFT_ALLOW_FILE"
: > "$CALLS"
check_rc "leftovers, only the allowlist timer: found" 0 "$(rm_leftovers_present; echo $?)"
CONFIRM_ANSWER=yes
( remove_leftovers; echo "rc=$?" ) > "$T/out" 2>&1
CONFIRM_ANSWER=no
check_has "leftovers, only the allowlist timer: rc 0" "rc=0" "$(cat "$T/out")"
check_has "leftovers, only the allowlist timer: listed" "yes" \
    "$(grep -qF '  /etc/systemd/system/telcoin-p2p-allow-sync.timer (the P2P committee allowlist, its units and its nftables table)' "$T/out" && echo yes)"
gone "leftovers, only the allowlist timer: timer" "$SD/telcoin-p2p-allow-sync.timer"
check "leftovers, only the allowlist timer: table deleted" "no" "$(exists "$NFT_ALLOW_FILE")"
# Only the state dir, kept by a refused delete: found, and the next run removes it.
rm -rf "$R"; mkdir -p "$R/run/telcoin"
p2p_allow_fixture
NFT_FAIL=1 remove_node_host_files > /dev/null 2>&1
check "leftovers, after a refused delete: the state dir stays, units and binary gone" "yes no no" \
    "$(exists "$AL_DIR") $(exists "$SD/telcoin-p2p-allow-sync.timer") $(exists "$AL_BIN")"
check_rc "leftovers, after a refused delete: found" 0 "$(rm_leftovers_present; echo $?)"
CONFIRM_ANSWER=yes
( remove_leftovers; echo "rc=$?" ) > "$T/out" 2>&1
CONFIRM_ANSWER=no
check_has "leftovers, only the state dir: rc 0" "rc=0" "$(cat "$T/out")"
check_has "leftovers, only the state dir: listed" "yes" \
    "$(grep -qF "  /var/lib/telcoin-p2p-allow (the P2P committee allowlist's state)" "$T/out" && echo yes)"
gone "leftovers, only the state dir: state dir" "$AL_DIR"
check "leftovers, only the state dir: table deleted on the second try" "no" "$(exists "$NFT_ALLOW_FILE")"
# A symlinked state dir alone is not a leftover: the removal would leave it.
rm -rf "$R" "$OUT"; mkdir -p "$R/var/lib" "$R/run/telcoin" "$OUT/allow-target"
ln -s "$OUT/allow-target" "$AL_DIR"
check_rc "leftovers, only a symlinked state dir: not found" 1 "$(rm_leftovers_present; echo $?)"
# The JSON full removal takes it too.
mkfixture; p2p_allow_fixture
( set -e; json_remove validator keys ) 3> "$T/json" > "$T/out" 2>&1; rc=$?
check_rc "p2p allow: json keys rc 0" 0 "$rc"
gone "p2p allow: json timer" "$SD/telcoin-p2p-allow-sync.timer"
gone "p2p allow: json state dir" "$AL_DIR"
gone "p2p allow: json binary" "$AL_BIN"
check "p2p allow: json table deleted" "no" "$(exists "$NFT_ALLOW_FILE")"
rm -f "$NFT_ALLOW_FILE" "$T/h/firewall-setup.sh"
unset -f p2p_allow_fixture allow_said

# FW
# --- the P2P new-flow limit goes with the last node: unit, ruleset, table -------
# p2p_limit_fixture -- the boot unit and ruleset firewall-setup.sh writes, and the table.
p2p_limit_fixture() {
    mkdir -p "$SD" "$ETC"
    printf '[Unit]\nDescription=limit\n' > "$SD/telcoin-p2p-limit.service"
    printf 'table inet tn_p2p\ndelete table inet tn_p2p\n' > "$ETC/p2p-limit.nft"
    printf 'table inet tn_p2p {\n}\n' > "$NFT_TABLE_FILE"
    : > "$CALLS"
}
mkfixture; p2p_limit_fixture
remove_node_host_files > "$T/out" 2>&1
gone "p2p limit unit" "$SD/telcoin-p2p-limit.service"
gone "p2p limit ruleset" "$ETC/p2p-limit.nft"
check "p2p limit: table deleted" "no" "$(exists "$NFT_TABLE_FILE")"
check_has "p2p limit: unit disabled and stopped" "systemctl disable --now telcoin-p2p-limit.service" "$(calls)"
check_has "p2p limit: daemon-reload" "systemctl daemon-reload" "$(calls)"
check "p2p limit: one delete transaction" "nft| table inet tn_p2p
nft| delete table inet tn_p2p" "$(grep '^nft| ' "$CALLS")"
check_has "p2p limit: said" "yes" "$(grep -q 'Deleted the P2P new-flow limit (nftables table inet tn_p2p)' "$T/out" && echo yes)"
kept "p2p limit: other unit" "$SD/telcoin.service"
# Nothing of it here: no systemctl call for it and no nft transaction.
mkfixture; : > "$CALLS"; rm -f "$NFT_TABLE_FILE"
remove_node_host_files > /dev/null 2>&1
check_lacks "p2p limit absent: no unit call" "telcoin-p2p-limit" "$(calls)"
check_lacks "p2p limit absent: no nft transaction" "nft -f" "$(calls)"
# nft refuses the delete: a warning, and the rest of the removal goes on.
mkfixture; p2p_limit_fixture
NFT_FAIL=1 remove_node_host_files > "$T/out" 2>&1
check_has "p2p limit: refused delete warned" "yes" "$(grep -q 'Could not delete the nftables table inet tn_p2p; remove it with: sudo nft delete table inet tn_p2p' "$T/out" && echo yes)"
gone "p2p limit: refused delete, unit still removed" "$SD/telcoin-p2p-limit.service"
gone "p2p limit: refused delete, node.env still removed" "$ETC/node.env"
# Without nft the files still go (a PATH without the sbin directories).
mv "$T/bin/nft" "$T/bin/nft.off"
SAVED_PATH="$PATH"
PATH="$T/bin:/usr/local/bin:/usr/bin:/bin"
hash -r
if command -v nft >/dev/null 2>&1; then
    skip "p2p limit without nft" "an nft other than the stub is on PATH ($(command -v nft))"
else
    mkfixture; p2p_limit_fixture
    remove_node_host_files > /dev/null 2>&1
    gone "p2p limit without nft: unit" "$SD/telcoin-p2p-limit.service"
    gone "p2p limit without nft: ruleset" "$ETC/p2p-limit.nft"
    check_lacks "p2p limit without nft: no nft call" "nft " "$(calls)"
fi
PATH="$SAVED_PATH"
mv "$T/bin/nft.off" "$T/bin/nft"; hash -r
# Another node remains: the limit stays (its P2P ports are still open).
mkfixture; p2p_limit_fixture
INSTALLED_UNITS=(telcoin telcoin-validator)
remove_shared_components > /dev/null 2>&1
kept "p2p limit while another node remains: unit" "$SD/telcoin-p2p-limit.service"
check "p2p limit while another node remains: table" "yes" "$(exists "$NFT_TABLE_FILE")"
INSTALLED_UNITS=()
# The JSON keys removal with another node unit left keeps the limit whole: the
# ruleset stays (not shredded), so do the boot unit and the table.
mkfixture; p2p_limit_fixture
printf '[Service]\n' > "$SD/telcoin-validator.service"
( set -e; json_remove validator keys ) 3> "$T/json" > "$T/out" 2>&1; rc=$?
check_rc "p2p limit, another node left: json keys rc 0" 0 "$rc"
kept "p2p limit, another node left: ruleset" "$ETC/p2p-limit.nft"
check "p2p limit, another node left: ruleset untouched" "table inet tn_p2p
delete table inet tn_p2p" "$(cat "$ETC/p2p-limit.nft" 2>/dev/null)"
check_lacks "p2p limit, another node left: ruleset not shredded" "$ETC/p2p-limit.nft" "$(calls)"
kept "p2p limit, another node left: boot unit" "$SD/telcoin-p2p-limit.service"
check "p2p limit, another node left: table" "yes" "$(exists "$NFT_TABLE_FILE")"
gone "p2p limit, another node left: the passphrase still goes" "$ETC/bls-passphrase.cred"
gone "p2p limit, another node left: .node-meta still goes" "$ETC/.node-meta"
check_has "p2p limit, another node left: said in the log" "yes" \
    "$(grep -q 'Keeping /etc/telcoin/p2p-limit.nft: another node unit remains here, and the P2P new-flow limit stays whole for it' "$T/json" && echo yes)"
rm -f "$SD/telcoin-validator.service"
# Only the boot unit and the table are left: the leftover path finds and removes them.
rm -rf "$R"; mkdir -p "$SD" "$R/run/telcoin"
printf '[Unit]\nDescription=limit\n' > "$SD/telcoin-p2p-limit.service"
printf 'table inet tn_p2p {\n}\n' > "$NFT_TABLE_FILE"
: > "$CALLS"
check_rc "leftovers, only the limit: found" 0 "$(rm_leftovers_present; echo $?)"
CONFIRM_ANSWER=yes
( remove_leftovers; echo "rc=$?" ) > "$T/out" 2>&1
CONFIRM_ANSWER=no
check_has "leftovers, only the limit: rc 0" "rc=0" "$(cat "$T/out")"
check_has "leftovers, only the limit: listed" "yes" \
    "$(grep -qF '  /etc/systemd/system/telcoin-p2p-limit.service (the P2P new-flow limit, and its nftables table)' "$T/out" && echo yes)"
gone "leftovers, only the limit: boot unit" "$SD/telcoin-p2p-limit.service"
check "leftovers, only the limit: table deleted" "no" "$(exists "$NFT_TABLE_FILE")"
# The menu removes one node of two: its keys removal keeps the ruleset (not
# shredded, not removed), so the remaining node's boot unit still finds it; the
# removal of the last node then takes the unit, the ruleset and the table.
mkfixture; p2p_limit_fixture
printf '[Service]\n' > "$SD/telcoin-validator.service"
INSTALLED_UNITS=(telcoin telcoin-validator)
remove_node_unit telcoin <<< "DELETE" > "$T/out" 2>&1
check "p2p limit, menu, one of two: ruleset kept as it was" "table inet tn_p2p
delete table inet tn_p2p" "$(cat "$ETC/p2p-limit.nft" 2>/dev/null)"
check_lacks "p2p limit, menu, one of two: ruleset not shredded" "$ETC/p2p-limit.nft" "$(calls)"
kept "p2p limit, menu, one of two: boot unit" "$SD/telcoin-p2p-limit.service"
check "p2p limit, menu, one of two: table" "yes" "$(exists "$NFT_TABLE_FILE")"
gone "p2p limit, menu, one of two: the passphrase still goes" "$ETC/bls-passphrase.cred"
gone "p2p limit, menu, one of two: the removed unit" "$SD/telcoin.service"
check_has "p2p limit, menu, one of two: said" "yes" \
    "$(grep -q 'Keeping /etc/telcoin/p2p-limit.nft: another node unit remains here, and the P2P new-flow limit stays whole for it' "$T/out" && echo yes)"
INSTALLED_UNITS=(telcoin-validator)
remove_node_unit telcoin-validator <<< "DELETE" > "$T/out" 2>&1
gone "p2p limit, menu, the last node: ruleset" "$ETC/p2p-limit.nft"
gone "p2p limit, menu, the last node: boot unit" "$SD/telcoin-p2p-limit.service"
check "p2p limit, menu, the last node: table deleted" "no" "$(exists "$NFT_TABLE_FILE")"
INSTALLED_UNITS=()
# The JSON full removal takes it too.
mkfixture; p2p_limit_fixture
( set -e; json_remove validator keys ) 3> "$T/json" > "$T/out" 2>&1; rc=$?
check_rc "p2p limit: json keys rc 0" 0 "$rc"
gone "p2p limit: json unit" "$SD/telcoin-p2p-limit.service"
check "p2p limit: json table deleted" "no" "$(exists "$NFT_TABLE_FILE")"
rm -f "$NFT_TABLE_FILE"

# ALERTS
# --- the private alerts go before the node stops, at every scope -----------------
# mkalerts -- add to the fixture what setup-alerts.sh installs: both heartbeat
# units, the runner, the config dir with the targets (holding a push token) and
# env files, the runner's state dir and the link systemd keeps beside it, the
# service-state file (and the .tmp of an interrupted write) the unit's root
# ExecStartPre= leaves in /run/telcoin beside the update lock, and
# ENABLE_ALERTS=true in .node-meta.
HB_TOKEN="hbtok0123456789abcdefXYZ"
# One line: BSD awk refuses a -v value that holds a newline.
ALERT_PATHS="/etc/systemd/system/telcoin-heartbeat.timer /etc/systemd/system/telcoin-heartbeat.service /usr/local/libexec/telcoin/tn-heartbeat /etc/telcoin/alerts /var/lib/private/telcoin-heartbeat /var/lib/telcoin-heartbeat /run/telcoin/heartbeat-service /run/telcoin/heartbeat-service.tmp"
HB_HINT="Pause or delete this node's monitor: a push monitor alerts on silence."
mkalerts() {
    mkdir -p "$SD" "$LX" "$ETC/alerts" "$R/var/lib/private/telcoin-heartbeat" "$R/run/telcoin"
    printf 'ActiveState=active\nSubState=running\n' > "$R/run/telcoin/heartbeat-service"
    printf 'ActiveState=active\n' > "$R/run/telcoin/heartbeat-service.tmp"
    printf '[Timer]\nOnUnitActiveSec=60\n' > "$SD/telcoin-heartbeat.timer"
    printf '[Service]\nDynamicUser=yes\n' > "$SD/telcoin-heartbeat.service"
    printf '#!/usr/bin/env bash\nHEARTBEAT_VERSION="2.1.0"\n' > "$LX/tn-heartbeat"
    printf 'kuma https://kuma.example.org/api/push/%s\n' "$HB_TOKEN" > "$ETC/alerts/targets"
    printf 'ALERTS_SERVICE=telcoin\nALERTS_INTERVAL=60\n' > "$ETC/alerts/alerts.env"
    printf 'last_status=up\n' > "$R/var/lib/private/telcoin-heartbeat/state"
    ln -s private/telcoin-heartbeat "$R/var/lib/telcoin-heartbeat"
    if [[ -f "$ETC/.node-meta" ]]; then printf 'ENABLE_ALERTS=true\n' >> "$ETC/.node-meta"; fi
    : > "$CALLS"
}
# alerts_gone NAME -- every alerts path is gone.
alerts_gone() {
    local p
    for p in $ALERT_PATHS; do
        gone "$1: ${p}" "$R$p"
    done
}
# drop_alerts -- the snapshot on stdin without the alerts paths: the tree the
# shared contract's alerts_disable leaves (everything else as it was).
drop_alerts() {
    awk -v r="$R" -v l="$ALERT_PATHS" '
        BEGIN { n = split(l, a, " ") }
        { for (i = 1; i <= n; i++) { p = r a[i]; if ($0 == p || index($0, p "/") == 1) next } print }'
}
# alerts_before_stop NAME -- in the call log, the timer was disabled before the
# node unit was stopped.
alerts_before_stop() {
    local a s
    a="$(grep -n -x 'systemctl disable --now telcoin-heartbeat.timer' "$CALLS" | head -n 1 | cut -d: -f1)"
    s="$(grep -n -x 'systemctl stop telcoin' "$CALLS" | head -n 1 | cut -d: -f1)"
    check "$1: alerts removed before the node stops" yes \
        "$([[ -n "$a" && -n "$s" && $a -lt $s ]] && echo yes || echo "no (alerts at ${a:-none}, stop at ${s:-none})")"
}
# meta_set logs instead of writing: the fixture tree is not root-owned, so the
# real one refuses; remove_alerts' best-effort write is checked in the call log.
meta_set() { printf 'meta_set %s\n' "$*" >> "$CALLS"; }

# remove_alerts alone: the contract's remaining tree, the order of the calls,
# the targets file shredded, the meta value, one hint and no token printed.
mkfixture; mkalerts
before="$(snapshot)"
remove_alerts > "$T/out" 2>&1; rc=$?
check_rc "remove_alerts: rc 0" 0 "$rc"
alerts_gone "remove_alerts"
check "remove_alerts: the rest of the tree as it was" "$(printf '%s\n' "$before" | drop_alerts)" "$(snapshot)"
kept "remove_alerts: /var/lib/private stays" "$R/var/lib/private"
kept "remove_alerts: /run/telcoin stays" "$R/run/telcoin"
kept "remove_alerts: the update lock stays" "$R/run/telcoin/update.lock"
check "remove_alerts: systemctl calls in order" "systemctl disable --now telcoin-heartbeat.timer
systemctl stop telcoin-heartbeat.service
systemctl clean --what=state telcoin-heartbeat.service
systemctl daemon-reload
systemctl reset-failed telcoin-heartbeat.service" "$(grep '^systemctl ' "$CALLS")"
check_has "remove_alerts: targets shredded" "shred -u -- $ETC/alerts/targets" "$(calls)"
check_has "remove_alerts: ENABLE_ALERTS=false written" "meta_set ENABLE_ALERTS false $ETC/.node-meta" "$(calls)"
check "remove_alerts: the hint once" 1 "$(grep -cF "$HB_HINT" "$T/out")"
check "remove_alerts: says what it removes" yes "$(grep -qF 'Removing private alerts (telcoin-heartbeat)' "$T/out" && echo yes || echo no)"
check_lacks "remove_alerts: the token is not printed" "$HB_TOKEN" "$(cat "$T/out")"

# The library's alerts_disable, where this tree has it, leaves the same tree.
after="$(snapshot)"
if declare -F alerts_disable >/dev/null 2>&1; then
    mkfixture; mkalerts
    ( alerts_disable "" no-hint ) > "$T/out" 2>&1
    check "alerts_disable leaves the tree remove_alerts leaves" "$after" "$(snapshot)"
else
    skip "alerts_disable leaves the tree remove_alerts leaves" "lib/alerts.sh is not in this tree"
fi

# Only the service-state file is left (the units already gone): it counts as
# alerts, and it goes without the lock dir.
mkfixture
printf 'ActiveState=active\n' > "$R/run/telcoin/heartbeat-service"
: > "$CALLS"
check_rc "only the service-state file: alerts present" 0 "$(rm_alerts_present; echo $?)"
remove_alerts > "$T/out" 2>&1
gone "only the service-state file: removed" "$R/run/telcoin/heartbeat-service"
kept "only the service-state file: /run/telcoin stays" "$R/run/telcoin"
kept "only the service-state file: the update lock stays" "$R/run/telcoin/update.lock"

# Nothing of it here: nothing said, nothing called.
mkfixture
remove_alerts > "$T/out" 2>&1; rc=$?
check_rc "no alerts: rc 0" 0 "$rc"
check "no alerts: prints nothing" "" "$(cat "$T/out")"
check_lacks "no alerts: no heartbeat call" "heartbeat" "$(calls)"
check_lacks "no alerts: no meta write" "meta_set" "$(calls)"

# A symlinked config dir: the link goes, what it points at stays.
mkfixture
mkdir -p "$OUT/alerts"
printf 'kuma https://kuma.example.org/api/push/%s\n' "$HB_TOKEN" > "$OUT/alerts/targets"
ln -s "$OUT/alerts" "$ETC/alerts"
: > "$CALLS"
remove_alerts > /dev/null 2>&1
gone "symlinked alerts dir: the link" "$ETC/alerts"
check "symlinked alerts dir: the target file intact" "kuma https://kuma.example.org/api/push/${HB_TOKEN}" "$(cat "$OUT/alerts/targets" 2>/dev/null)"
check_lacks "symlinked alerts dir: nothing shredded through it" "shred" "$(calls)"

# --json, every scope: the step comes before the stop, the hint is a log event
# (RM_JSON is what run_json_mode sets before it calls json_remove).
for scope in service data keys; do
    mkfixture; mkalerts
    ( set -e; RM_JSON=true; json_remove validator "$scope" ) 3> "$T/json" > "$T/out" 2>&1; rc=$?
    check_rc "alerts json ${scope}: rc 0" 0 "$rc"
    alerts_gone "alerts json ${scope}"
    alerts_before_stop "alerts json ${scope}"
    check_has "alerts json ${scope}: step event" '{"event":"step","msg":"Removing private alerts (telcoin-heartbeat)"}' "$(cat "$T/json")"
    check_has "alerts json ${scope}: hint event" "{\"event\":\"log\",\"msg\":\"${HB_HINT}\"}" "$(cat "$T/json")"
    n_a="$(grep -n 'Removing private alerts' "$T/json" | head -n 1 | cut -d: -f1)"
    n_s="$(grep -n 'Stopping and disabling telcoin' "$T/json" | head -n 1 | cut -d: -f1)"
    check "alerts json ${scope}: the alerts step before the stop step" yes \
        "$([[ -n "$n_a" && -n "$n_s" && $n_a -lt $n_s ]] && echo yes || echo no)"
    check_has "alerts json ${scope}: targets shredded" "shred -u -- $ETC/alerts/targets" "$(calls)"
    check_lacks "alerts json ${scope}: the token is not in the JSON" "$HB_TOKEN" "$(cat "$T/json")"
    check_lacks "alerts json ${scope}: the token is not printed" "$HB_TOKEN" "$(cat "$T/out")"
done
kept "alerts json keys: /var/lib/private stays" "$R/var/lib/private"

# The menu's removal of a node.
mkfixture; mkalerts
remove_node_unit telcoin <<< "" > "$T/out" 2>&1
alerts_gone "alerts menu"
alerts_before_stop "alerts menu"
check "alerts menu: the hint once" 1 "$(grep -cF "$HB_HINT" "$T/out")"
check_has "alerts menu: ENABLE_ALERTS=false written" "meta_set ENABLE_ALERTS false $ETC/.node-meta" "$(calls)"
check_lacks "alerts menu: the token is not printed" "$HB_TOKEN" "$(cat "$T/out")"
INSTALLED_UNITS=()

# The leftover path: listed, removed before the node units are stopped.
mkinterrupted; mkalerts
CONFIRM_ANSWER=yes
( remove_leftovers; echo "rc=$?" ) > "$T/out" 2>&1
CONFIRM_ANSWER=no
check_has "alerts leftovers: rc 0" "rc=0" "$(cat "$T/out")"
check_has "alerts leftovers: the timer listed" "yes" \
    "$(grep -qF '  /etc/systemd/system/telcoin-heartbeat.timer (private alerts)' "$T/out" && echo yes)"
alerts_gone "alerts leftovers"
alerts_before_stop "alerts leftovers"
check "alerts leftovers: the hint once" 1 "$(grep -cF "$HB_HINT" "$T/out")"

# Only the timer is left: it is a leftover, and the leftover path removes it.
rm -rf "$R"; mkdir -p "$SD" "$R/run/telcoin"
printf '[Timer]\n' > "$SD/telcoin-heartbeat.timer"
: > "$CALLS"
check_rc "only the timer left: a leftover" 0 "$(rm_leftovers_present; echo $?)"
CONFIRM_ANSWER=yes
( remove_leftovers; echo "rc=$?" ) > "$T/out" 2>&1
CONFIRM_ANSWER=no
check_has "only the timer left: rc 0" "rc=0" "$(cat "$T/out")"
gone "only the timer left: the timer" "$SD/telcoin-heartbeat.timer"
check_has "only the timer left: disabled" "systemctl disable --now telcoin-heartbeat.timer" "$(calls)"
rm -rf "$R"; mkdir -p "$R"
check_rc "nothing left: no leftover" 1 "$(rm_leftovers_present; echo $?)"

# The chain-data-only wipe keeps the node, so it keeps the alerts too.
mkfixture; mkalerts
before="$(snapshot)"
( INSTALLED_UNITS=(telcoin); CONFIRM_ANSWER=yes; wipe_chain_data_only ) < /dev/null > "$T/out" 2>&1
check_has "chain-data wipe: the node restarted" "systemctl start telcoin" "$(calls)"
check_lacks "chain-data wipe: no heartbeat call" "heartbeat" "$(calls)"
for p in $ALERT_PATHS; do
    kept "chain-data wipe: ${p}" "$R$p"
done
gone "chain-data wipe: the chain db" "$DATA/db"

# A refusal before the lock (a key set twice) leaves the alerts as they are.
mkfixture; mkalerts
printf 'HOST_SERVICE_USER=a\nHOST_SERVICE_USER=b\n' >> "$ETC/.node-meta"
before="$(snapshot)"
json_remove validator keys 3> "$T/json" > /dev/null 2>&1; rc=$?
check_rc "alerts, dup key: json refused" 1 "$rc"
check "alerts, dup key: nothing removed" "$before" "$(snapshot)"
check_lacks "alerts, dup key: no heartbeat call" "heartbeat" "$(calls)"

# Without lib/alerts.sh: remove-node.sh calls nothing of it (or of the runner),
# so a removal with every alerts_* and hb_* function gone still takes the alerts.
check "remove-node.sh calls no alerts_* or hb_* function" "" \
    "$(grep -v '^[[:space:]]*#' "$TN_TEST_REPO/remove-node.sh" | grep -oE '(^|[^A-Za-z0-9_])(alerts|hb)_[A-Za-z0-9_]+' | sort -u)"
mkfixture; mkalerts
( for f in $(declare -F | awk '{print $3}' | grep -E '^(alerts|hb)_'); do unset -f "$f"; done
  set -e; RM_JSON=true; json_remove validator keys ) 3> "$T/json" > "$T/out" 2>&1; rc=$?
check_rc "no alerts library: json keys rc 0" 0 "$rc"
alerts_gone "no alerts library"
check_has "no alerts library: hint event" "{\"event\":\"log\",\"msg\":\"${HB_HINT}\"}" "$(cat "$T/json")"
unset -f meta_set

# NET-2 gap: the custom-container scan must also see a node running a ghcr.io
# image, not only the testnet repositories: the old single package (by digest or
# by tag), the testnet package, the mainnet package and the dev package devnet
# nodes run from.
custom_container_lines_drv() {
    docker() {
        printf 'tn-old\tus-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.15.0-adiri\tExited (0)\n'
        printf 'tn-main\tghcr.io/telcoin-association/telcoin-network@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\tUp 3 days\n'
        printf 'tn-tag\tghcr.io/telcoin-association/telcoin-network:v1.0.0\tUp 1 hour\n'
        printf 'tn-testnet-pkg\tghcr.io/telcoin-association/tn-testnet:v0.17.0-adiri\tUp 1 hour\n'
        printf 'tn-testnet-dig\tghcr.io/telcoin-association/tn-testnet@sha256:1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\tUp 5 hours\n'
        printf 'tn-mainnet-pkg\tghcr.io/telcoin-association/tn-mainnet@sha256:2123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\tUp 2 hours\n'
        printf 'tn-mainnet-tag\tghcr.io/telcoin-association/tn-mainnet:v1.0.0\tExited (0)\n'
        printf 'tn-devnet\tghcr.io/telcoin-association/tn-dev@sha256:3123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\tUp 4 hours\n'
        printf 'other-ghcr\tghcr.io/someone-else/telcoin-network:v1.0.0\tUp 1 hour\n'
        printf 'web\tnginx:1.27\tUp 2 days\n'
    }
    timeout() { shift 3; "$@"; }
    custom_container_lines
}
CTR="$(custom_container_lines_drv)"
listed() { printf '%s\n' "$CTR" | awk -F '\t' -v n="$1" '$1 == n { f = 1 } END { print f ? "yes" : "no" }'; }
check "custom scan: the legacy adiri container is listed" yes "$(listed tn-old)"
check "custom scan: an old ghcr package image by digest is listed" yes "$(listed tn-main)"
check "custom scan: an old ghcr package image by mainnet tag is listed" yes "$(listed tn-tag)"
check "custom scan: a testnet package image by tag is listed" yes "$(listed tn-testnet-pkg)"
check "custom scan: a testnet package image by digest is listed" yes "$(listed tn-testnet-dig)"
check "custom scan: a mainnet package image by digest is listed" yes "$(listed tn-mainnet-pkg)"
check "custom scan: a mainnet package image by tag is listed" yes "$(listed tn-mainnet-tag)"
check "custom scan: a dev package image (a devnet node) is listed" yes "$(listed tn-devnet)"
check "custom scan: another owner's ghcr.io image is not listed" no "$(listed other-ghcr)"
check "custom scan: an unrelated container is not listed" no "$(listed web)"
unset -f listed

finish
