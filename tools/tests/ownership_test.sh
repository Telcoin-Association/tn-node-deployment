#!/usr/bin/env bash
# tools/tests/ownership_test.sh -- tn_migrate_ownership on a fixture tree rooted
# at TN_ROOT_PREFIX. The early refusals (mainnet, unknown network, layout already
# 2) run as any user; the migration itself needs root and GNU tools, and runs in
# a temp dir under /root with "nobody" as the service user. Maintainer tooling
# (not updater-tracked). bash 3.2 safe.
# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
eval "$(tn_test_source_common)"
T="$TN_TEST_TMP"
quiet() { :; }

# fixture PRE NETWORK -- the bare tree a release before this one left behind.
fixture() {
    local pre="$1" net="$2"
    mkdir -p "$pre/opt/telcoin" "$pre/etc/telcoin" "$pre/etc/systemd/system" \
        "$pre/var/log/telcoin" "$pre/var/lib/telcoin" "$pre/usr/local"
    printf 'NETWORK=%s\nINSTALL_METHOD=source\nHOST_SERVICE_USER=%s\nHOST_SERVICE_GROUP=%s\n' \
        "$net" "$SU" "$SG" > "$pre/etc/telcoin/.node-meta"
}

# Unprivileged cases: refusals before anything changes.
P="$T/fx-main"
SU="$(id -un)"; SG="$(id -gn)"
fixture "$P" mainnet
before="$(ls -la "$P/opt/telcoin" "$P/etc/telcoin")"
rc=0; TN_ROOT_PREFIX="$P" tn_migrate_ownership quiet || rc=$?
check_rc "migrate: mainnet refused" 3 "$rc"
check "migrate: mainnet left the tree alone" "$before" "$(ls -la "$P/opt/telcoin" "$P/etc/telcoin")"
P="$T/fx-unknown"
fixture "$P" foo
rc=0; TN_ROOT_PREFIX="$P" tn_migrate_ownership quiet || rc=$?
check_rc "migrate: unknown network refused" 1 "$rc"
P="$T/fx-done"
fixture "$P" testnet
printf 'OWNERSHIP_LAYOUT=2\n' >> "$P/etc/telcoin/.node-meta"
rc=0; TN_ROOT_PREFIX="$P" tn_migrate_ownership quiet || rc=$?
check_rc "migrate: layout 2 already" 0 "$rc"
P="$T/fx-dup"
fixture "$P" testnet
printf 'OWNERSHIP_LAYOUT=1\nOWNERSHIP_LAYOUT=2\n' >> "$P/etc/telcoin/.node-meta"
rc=0; TN_ROOT_PREFIX="$P" tn_migrate_ownership quiet || rc=$?
check_rc "migrate: duplicated OWNERSHIP_LAYOUT refused" 1 "$rc"
rc=0; TN_ROOT_PREFIX="$T/none" tn_migrate_ownership quiet || rc=$?
check_rc "migrate: no .node-meta is nothing to do" 0 "$rc"

RB=""
if [[ "$(id -u)" == 0 ]]; then
    RB="$(mktemp -d /root/.tn-own.XXXXXX 2>/dev/null)" || RB=""
    [[ -n "$RB" ]] && ! tn_root_dir_ok "$RB" && { rm -rf "$RB"; RB=""; }
fi
: > "$T/p1"
HAVE_GNU=0
mv -f -T -- "$T/p1" "$T/p2" 2>/dev/null && find "$T" -maxdepth 0 -print0 >/dev/null 2>&1 && HAVE_GNU=1
SU=nobody
SG="$(id -gn nobody 2>/dev/null)" || SG=""
if [[ -z "$RB" ]]; then
    skip "migrate: root migration cases" "not root"
elif [[ "$HAVE_GNU" != 1 ]]; then
    skip "migrate: root migration cases" "mv -T absent"
elif [[ -z "$SG" ]] || ! { command getent group telcoin-log >/dev/null 2>&1 || groupadd --system telcoin-log 2>/dev/null; }; then
    skip "migrate: root migration cases" "no nobody user or no telcoin-log group"
else
    SERVICE_USER=nobody
    SERVICE_GROUP="$SG"
    P="$RB/fx"
    ( umask 022; fixture "$P" testnet )
    printf 'ELF' > "$P/opt/telcoin/telcoin-network"; chmod 0755 "$P/opt/telcoin/telcoin-network"
    printf 'v0.16.0-adiri\n' > "$P/opt/telcoin/telcoin-network.version"
    printf '#!/usr/bin/env bash\nexec /opt/telcoin/telcoin-network node --http\n' > "$P/opt/telcoin/start-telcoin.sh"
    chmod 0775 "$P/opt/telcoin/start-telcoin.sh"
    printf 'pw\n' > "$P/etc/telcoin/bls-passphrase"; chmod 0600 "$P/etc/telcoin/bls-passphrase"
    mkdir -p "$P/etc/telcoin/chain-configs/adiri"; printf 'g\n' > "$P/etc/telcoin/chain-configs/adiri/genesis.yaml"
    printf '[Service]\nExecStart=/opt/telcoin/start-telcoin.sh\n' > "$P/etc/systemd/system/telcoin.service"
    printf 'log\n' > "$P/var/log/telcoin/telcoin.log"
    printf 'canary\n' > "$RB/canary"; chmod 0600 "$RB/canary"
    ln -s "$RB/canary" "$P/var/log/telcoin/telcoin-error.log"
    chown -R nobody:"$SG" "$P/opt/telcoin" "$P/etc/telcoin" "$P/var/log/telcoin"
    chown -h nobody:"$SG" "$P/var/log/telcoin/telcoin-error.log"
    ln -s /etc/shadow "$P/opt/telcoin/evil"
    chown -h nobody:"$SG" "$P/opt/telcoin/evil"

    rc=0; TN_ROOT_PREFIX="$P" tn_migrate_ownership quiet 2>"$T/err" || rc=$?
    check_rc "migrate: planted symlink refused" 1 "$rc"
    check_has "migrate: symlink listed" "symlink: $P/opt/telcoin/evil" "$(cat "$T/err")"
    check "migrate: refusal re-owned only the top dirs" "nobody nobody" \
        "$(stat -c %U "$P/etc/telcoin/.node-meta") $(stat -c %U "$P/opt/telcoin/telcoin-network")"
    check "migrate: top dirs root 0755 after step 1" "root 755 root 755" \
        "$(stat -c '%U %a' "$P/opt/telcoin") $(stat -c '%U %a' "$P/etc/telcoin")"
    check "migrate: symlink not followed" "yes" "$([[ -L "$P/opt/telcoin/evil" ]] && echo yes)"

    rm -f "$P/opt/telcoin/evil"
    rc=0; TN_ROOT_PREFIX="$P" tn_migrate_ownership quiet 2>"$T/err" || rc=$?
    check_rc "migrate: runs once the link is gone" 0 "$rc"
    check "migrate: nothing left service-user-owned" "" \
        "$(find "$P/opt/telcoin" "$P/etc/telcoin" "$P/usr/local/libexec/telcoin" ! -user root)"
    check "migrate: .node-meta root 0600" "root 600" "$(stat -c '%U %a' "$P/etc/telcoin/.node-meta")"
    check "migrate: passphrase root 0600" "root 600" "$(stat -c '%U %a' "$P/etc/telcoin/bls-passphrase")"
    check "migrate: binary root 0755" "root 755" "$(stat -c '%U %a' "$P/opt/telcoin/telcoin-network")"
    check "migrate: nested dir root 0755" "root 755" "$(stat -c '%U %a' "$P/etc/telcoin/chain-configs/adiri")"
    check "migrate: start script moved" "no root 755" \
        "$([[ -e "$P/opt/telcoin/start-telcoin.sh" ]] && echo yes || echo no) $(stat -c '%U %a' "$P/usr/local/libexec/telcoin/tn-start")"
    check "migrate: start script content kept" "exec /opt/telcoin/telcoin-network node --http" \
        "$(tail -1 "$P/usr/local/libexec/telcoin/tn-start")"
    check_has "migrate: unit points at the new script" "ExecStart=/usr/local/libexec/telcoin/tn-start" \
        "$(cat "$P/etc/systemd/system/telcoin.service")"
    check "migrate: log dir root:telcoin-log 0750" "root telcoin-log 750" "$(stat -c '%U %G %a' "$P/var/log/telcoin")"
    check "migrate: log kept, root:telcoin-log 0640" "log root telcoin-log 640" \
        "$(cat "$P/var/log/telcoin/telcoin.log") $(stat -c '%U %G %a' "$P/var/log/telcoin/telcoin.log")"
    check "migrate: log symlink replaced, target untouched" "file canary" \
        "$([[ -L "$P/var/log/telcoin/telcoin-error.log" ]] && echo link || echo file) $(cat "$RB/canary")"
    check "migrate: layout recorded" "2" "$(meta_get OWNERSHIP_LAYOUT "$P/etc/telcoin/.node-meta")"
    check_has "migrate: OWNERSHIP_LAYOUT removed to force a full re-run" "yes" \
        "$(TN_ROOT_PREFIX="$P" meta_unset OWNERSHIP_LAYOUT "$P/etc/telcoin/.node-meta"; echo yes)"
    snap="$(find "$P" -printf '%p %u %g %m\n' | sort)"
    rc=0; TN_ROOT_PREFIX="$P" tn_migrate_ownership quiet 2>/dev/null || rc=$?
    check_rc "migrate: second run rc" 0 "$rc"
    check "migrate: second run changes nothing" "$snap" "$(find "$P" -printf '%p %u %g %m\n' | sort)"
    check "migrate: layout recorded again" "2" "$(meta_get OWNERSHIP_LAYOUT "$P/etc/telcoin/.node-meta")"

    P2="$RB/fx2"
    ( umask 022; fixture "$P2" testnet )
    printf 'x\n' > "$P2/etc/telcoin/stray"
    chown -R nobody:"$SG" "$P2/etc/telcoin"
    chown 4242 "$P2/etc/telcoin/stray"
    rc=0; TN_ROOT_PREFIX="$P2" tn_migrate_ownership quiet 2>"$T/err" || rc=$?
    check_rc "migrate: foreign owner refused" 1 "$rc"
    check_has "migrate: foreign owner listed" "owned by uid 4242: $P2/etc/telcoin/stray" "$(cat "$T/err")"
    rm -rf "$RB"
fi

finish
