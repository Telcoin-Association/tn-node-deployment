#!/usr/bin/env bash
# =============================================================================
# tools/tests/credential_test.sh -- the encrypted passphrase credential helpers
# in lib/common.sh: tn_store_credential, tn_migrate_credential,
# tn_migrate_embedded_passphrase, tn_has_embedded_passphrase, tn_pcrs_ok,
# tn_credential_key and tn_os_floor_check.
#
#   bash tools/tests/credential_test.sh
#
# systemd-creds, systemctl and shred are PATH shims that record their argv;
# the systemd-creds shim "encrypts" by rot13 behind a CRED: prefix and decrypts
# by undoing it, so a round trip can be checked and broken on purpose. The root
# writes, backups, the launch re-render, the committee guard, the restart window
# and the RPC probe are stubbed functions (they have their own tests). Every
# check that the passphrase reached no command line looks at the recorded argv.
#
# Maintainer tooling: not tracked by update-scripts.sh, no .sha256 sidecar.
# bash 3.2 safe.
# =============================================================================
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
REC="$T/rec"
export REC
TN_ROOT_PREFIX="$T/root"
ETC="$TN_ROOT_PREFIX/etc/telcoin"
UDIR="$TN_ROOT_PREFIX/etc/systemd/system"
UNIT="$UDIR/telcoin.service"
mkdir -p "$T/bin" "$REC" "$ETC" "$UDIR" "$T/bak"

cat > "$T/bin/systemd-creds" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$REC/creds.argv"
cmd="$1"
shift
case "$cmd" in
    has-tpm2) exit "${STUB_TPM:-1}" ;;
    encrypt)
        [ -z "${STUB_ENC_FAIL:-}" ] || exit 1
        tr 'A-Za-z' 'N-ZA-Mn-za-m' | sed 's/^/CRED:/'
        ;;
    decrypt)
        in=""
        for a in "$@"; do
            case "$a" in --*) ;; *) [ -n "$in" ] || in="$a" ;; esac
        done
        sed 's/^CRED://' "$in" | tr 'A-Za-z' 'N-ZA-Mn-za-m'
        [ -z "${STUB_CORRUPT:-}" ] || printf 'x\n'
        ;;
esac
exit 0
SH
cat > "$T/bin/systemctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$REC/systemctl.argv"
case "$1" in
    --version) printf 'systemd %s (%s.4-1ubuntu8)\n+PAM +AUDIT\n' "${STUB_SYSTEMD:-255}" "${STUB_SYSTEMD:-255}" ;;
esac
exit 0
SH
cat > "$T/bin/shred" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$REC/shred.argv"
for a in "$@"; do f="$a"; done
rm -f -- "$f"
SH
chmod 0755 "$T/bin/systemd-creds" "$T/bin/systemctl" "$T/bin/shred"
PATH="$T/bin:$PATH"

eval "$(tn_test_source_common)"
TN_BACKUP_DIR="$T/bak"

# Stubs for what other tests cover.
tn_write_root_file() { cat > "$1" && chmod "$2" "$1"; }
tn_backup_file() {
    local b
    b="$(mktemp "$T/bak/${2:-x}.XXXXXX")" || return 2
    cp -- "$1" "$b" || return 2
    printf '%s %s\n' "$b" "$(sha256sum < "$b" | cut -d' ' -f1)"
}
tn_restore_backup() {
    [[ "$(sha256sum < "$1" | cut -d' ' -f1)" == "$2" ]] || return 1
    cp -- "$1" "$3" && chmod "$4" "$3"
}
# The re-render records the method and legacy flag it saw and writes a unit for
# that method (no passphrase in it).
tn_rerender_node_launch() {
    printf '%s %s\n' "${PASSPHRASE_METHOD:-}" "${_TN_RERENDER_LEGACY:-0}" >> "$REC/rerender"
    [[ "${STUB_RERENDER_RC:-0}" == 0 ]] || return "$STUB_RERENDER_RC"
    if [[ "$PASSPHRASE_METHOD" == "credential" ]]; then
        printf '[Service]\nLoadCredentialEncrypted=bls-passphrase:/etc/telcoin/bls-passphrase.cred\nExecStart=/usr/local/libexec/telcoin/tn-start\n' > "$UNIT"
    else
        printf '[Service]\nLoadCredential=bls-passphrase:/etc/telcoin/bls-passphrase\nExecStart=/usr/local/libexec/telcoin/tn-start\n' > "$UNIT"
    fi
}
tn_committee_down_guard() { return "${STUB_GUARD_RC:-0}"; }
tn_wait_restart_window() { printf 'wait\n' >> "$REC/wait"; }
tn_local_rpc_url() { printf 'http://127.0.0.1:8545\n'; }
# The RPC probe fails STUB_RPC_FAILS times, then answers.
tn_rpc_call() {
    local n=0
    [[ -f "$REC/rpc.count" ]] && n="$(cat "$REC/rpc.count")"
    n=$((n + 1))
    printf '%s\n' "$n" > "$REC/rpc.count"
    (( n > ${STUB_RPC_FAILS:-0} ))
}
sleep() { :; }
# The test runs as any user: its fixture files stand in for root-owned ones.
_tn_cred_plain_ok() { [[ -f "$1" && ! -L "$1" ]]; }
tn_root_dir_ok() { [[ -d "$1" && ! -L "$1" ]]; }

TN_CRED_HEALTH_SECS=0

ORIG_UNIT='[Service]
LoadCredential=bls-passphrase:/etc/telcoin/bls-passphrase
ExecStart=/usr/local/libexec/telcoin/tn-start'

# fixture NETWORK METHOD -- a fresh tree: .node-meta, the unit, no recordings.
fixture() {
    rm -rf "${REC:?}"/* "${T:?}/bak"/* "${ETC:?}"/* "${UDIR:?}"/*
    printf 'NETWORK=%s\nPASSPHRASE_METHOD=%s\nINSTALL_METHOD=source\nRPC_PORT=8545\n' "$1" "$2" > "$ETC/.node-meta"
    printf '%s\n' "$ORIG_UNIT" > "$UNIT"
    unset STUB_TPM STUB_ENC_FAIL STUB_CORRUPT STUB_SYSTEMD STUB_RERENDER_RC STUB_GUARD_RC STUB_RPC_FAILS TN_ALLOW_NO_TPM TN_BIND_PCRS
    TN_CRED_PASS=""
}
decrypted() { systemd-creds decrypt --name=bls-passphrase "$ETC/bls-passphrase.cred" - 2>/dev/null; }
argv_all() { cat "$REC"/*.argv 2>/dev/null; }
exists() { [[ -e "$1" ]] && echo yes || echo no; }

# ---- tn_pcrs_ok, tn_systemd_version, tn_os_floor_check --------------------------------
for v in 7 0+7 "0,7" 23 "1+2+3"; do
    rc=0; tn_pcrs_ok "$v" || rc=$?
    check_rc "pcrs ok: ${v}" 0 "$rc"
done
for v in "" 24 "7+" "+7" "a" "7 8" "-1" "100"; do
    rc=0; tn_pcrs_ok "$v" || rc=$?
    check_rc "pcrs refused: '${v}'" 1 "$rc"
done
check "systemd version parsed" "255" "$(STUB_SYSTEMD=255 tn_systemd_version)"
for row in "255 mainnet 0" "254 mainnet 1" "249 mainnet 1" "249 testnet 0" "247 testnet 0" "246 testnet 1" "246 mainnet 1" "255 testnet 0" "249 '' 1"; do
    set -- $row
    net="${2//\'/}"
    rc=0; STUB_SYSTEMD="$1" tn_os_floor_check "$net" 2>/dev/null || rc=$?
    check_rc "os floor: systemd $1 on ${net:-unknown network}" "$3" "$rc"
done
out="$(STUB_SYSTEMD=249 tn_os_floor_check testnet 2>&1)"
check_has "os floor: testnet 249 warns about the plaintext file" "yes" "$(grep -q 'cannot encrypt credentials' <<< "$out" && echo yes)"

# ---- tn_credential_key ------------------------------------------------------------------
check "key: TPM present" "host+tpm2" "$(STUB_TPM=0 tn_credential_key mainnet)"
check "key: testnet without TPM" "host" "$(STUB_TPM=1 tn_credential_key testnet 2>/dev/null)"
rc=0; STUB_TPM=1 tn_credential_key mainnet >/dev/null 2>&1 || rc=$?
check_rc "key: mainnet without TPM refused" 1 "$rc"
rc=0; STUB_TPM=1 tn_credential_key "" >/dev/null 2>&1 || rc=$?
check_rc "key: unknown network without TPM refused" 1 "$rc"
check "key: mainnet without TPM, --allow-no-tpm" "host" "$(STUB_TPM=1 TN_ALLOW_NO_TPM=1 tn_credential_key mainnet 2>/dev/null)"

# ---- tn_store_credential ----------------------------------------------------------------
PASS='st0re-Pa$$ @c|d'
fixture testnet credential
TN_CRED_PASS="$PASS"
rc=0; tn_store_credential "$ETC/bls-passphrase.cred" host "" || rc=$?
check_rc "store: rc" 0 "$rc"
check "store: decrypts to the passphrase" "$PASS" "$(decrypted)"
check "store: mode 600" "600" "$(stat -c %a "$ETC/bls-passphrase.cred")"
check "store: no .new left" "no" "$(exists "$ETC/bls-passphrase.cred.new")"
check_has "store: encrypt argv" "encrypt --name=bls-passphrase --with-key=host - -" "$(cat "$REC/creds.argv")"
check_lacks "store: passphrase in no argv" "$PASS" "$(argv_all)"
rc=0; tn_store_credential "$ETC/x.cred" host 7 2>/dev/null || rc=$?
check_rc "store: PCRs without a TPM refused" 1 "$rc"
check "store: refused, nothing written" "no" "$(exists "$ETC/x.cred")"
rc=0; tn_store_credential "$ETC/x.cred" host+tpm2 "0+7" || rc=$?
check_rc "store: host+tpm2 with PCRs" 0 "$rc"
check_has "store: PCR argv" "encrypt --name=bls-passphrase --with-key=host+tpm2 --tpm2-pcrs=0+7 - -" "$(cat "$REC/creds.argv")"
fixture testnet credential
TN_CRED_PASS="$PASS"
rc=0; STUB_CORRUPT=1 tn_store_credential "$ETC/bls-passphrase.cred" host "" 2>/dev/null || rc=$?
check_rc "store: round-trip mismatch rc 2" 2 "$rc"
check "store: mismatch leaves no credential" "no no" "$(exists "$ETC/bls-passphrase.cred") $(exists "$ETC/bls-passphrase.cred.new")"
rc=0; STUB_ENC_FAIL=1 tn_store_credential "$ETC/bls-passphrase.cred" host "" 2>/dev/null || rc=$?
check_rc "store: encrypt failure rc 2" 2 "$rc"
check "store: encrypt failure leaves nothing" "no no" "$(exists "$ETC/bls-passphrase.cred") $(exists "$ETC/bls-passphrase.cred.new")"
rc=0; ( export TN_CRED_PASS; tn_store_credential "$ETC/bls-passphrase.cred" host "" ) 2>/dev/null || rc=$?
check_rc "store: an exported TN_CRED_PASS is refused" 1 "$rc"
# Destinations that cannot be written are refused (rc 1) before anything is encrypted.
fixture testnet credential
TN_CRED_PASS="$PASS"
mkdir -p "$T/real"
ln -s "$T/real" "$ETC/linkdir"
ln -s "$T/real/x" "$ETC/bls-passphrase.cred.new"
mkdir -p "$ETC/adir.cred"
for d in "$ETC/linkdir/c.cred" "$ETC/bls-passphrase.cred" "$ETC/adir.cred"; do
    rc=0; tn_store_credential "$d" host "" 2>/dev/null || rc=$?
    check_rc "store: refused destination ${d##*/etc/telcoin/} rc 1" 1 "$rc"
done
check "store: refused destinations, nothing encrypted or written" "no no" \
    "$(grep -q '^encrypt' "$REC/creds.argv" 2>/dev/null && echo yes || echo no) $(exists "$T/real/x")"
rm -f "$ETC/linkdir" "$ETC/bls-passphrase.cred.new"
rmdir "$ETC/adir.cred"
# The writer runs in this shell with DEST.new named for the EXIT traps; the
# trap helper removes it.
tn_write_root_file() { printf '%s\n' "$TN_INFLIGHT_CRED" > "$REC/inflight"; cat > "$1" && chmod "$2" "$1"; }
rc=0; tn_store_credential "$ETC/bls-passphrase.cred" host "" || rc=$?
check "store: DEST.new named while it is written, cleared after" "$ETC/bls-passphrase.cred.new|" "$(cat "$REC/inflight")|${TN_INFLIGHT_CRED}"
tn_write_root_file() { cat > "$1" && chmod "$2" "$1"; }
printf 'x\n' > "$ETC/bls-passphrase.cred.new"
TN_INFLIGHT_CRED="$ETC/bls-passphrase.cred.new"
tn_remove_inflight_tmp
check "store: the EXIT helper removes an in-flight DEST.new" "no" "$(exists "$ETC/bls-passphrase.cred.new")"
TN_CRED_PASS=""

# ---- tn_has_embedded_passphrase ---------------------------------------------------------
printf '[Service]\nUnsetEnvironment=TN_BLS_PASSPHRASE\n# Environment="TN_BLS_PASSPHRASE=x"\n' > "$T/u1"
rc=0; tn_has_embedded_passphrase "$T/u1" || rc=$?
check_rc "embedded: guard line and comment do not count" 1 "$rc"
printf '[Service]\nEnvironment="TN_BLS_PASSPHRASE=abc"\n' > "$T/u2"
rc=0; tn_has_embedded_passphrase "$T/u2" || rc=$?
check_rc "embedded: Environment= line" 0 "$rc"

# ---- tn_migrate_credential from the plaintext file -------------------------------------
PASS="file-Secret-77"
fixture testnet loadcredential
printf '%s\n' "$PASS" > "$ETC/bls-passphrase"
printf '[Service]\nEnvironment="TN_BLS_PASSPHRASE=%s"\n' "$PASS" > "$UDIR/telcoin.service.bak.1700000000"
printf '[Service]\nEnvironment="TN_BLS_PASSPHRASE=other"\n' > "$UDIR/other.service.bak.1700000000"
printf 'unrelated\n' > "$T/bak/caddy-launch.ABCDEF"
rc=0; tn_migrate_credential 2>/dev/null || rc=$?
check_rc "migrate file: rc" 0 "$rc"
check "migrate file: credential decrypts to the passphrase" "$PASS" "$(decrypted)"
check "migrate file: plaintext file gone" "no" "$(exists "$ETC/bls-passphrase")"
check "migrate file: old unit backup with the passphrase gone" "no" "$(exists "$UDIR/telcoin.service.bak.1700000000")"
check "migrate file: another unit's backup kept" "yes" "$(exists "$UDIR/other.service.bak.1700000000")"
check "migrate file: unrelated backup kept" "yes" "$(exists "$T/bak/caddy-launch.ABCDEF")"
check_has "migrate file: shred ran on the plaintext file" "-u -- $ETC/bls-passphrase" "$(cat "$REC/shred.argv")"
check "migrate file: method recorded" "credential" "$(meta_get PASSPHRASE_METHOD 2>/dev/null)"
check "migrate file: key recorded" "host" "$(meta_get CREDENTIAL_KEY 2>/dev/null)"
check "migrate file: re-render saw credential, legacy mode" "credential 1" "$(cat "$REC/rerender")"
check_has "migrate file: daemon-reload" "daemon-reload" "$(cat "$REC/systemctl.argv")"
check_has "migrate file: restart" "restart telcoin" "$(cat "$REC/systemctl.argv")"
check "migrate file: waited for the restart window" "wait" "$(cat "$REC/wait")"
check "migrate file: backups shredded" "1" "$(ls "$T/bak" | wc -l | tr -d ' ')"
check_lacks "migrate file: passphrase in no argv" "$PASS" "$(argv_all)"
check "migrate file: TN_CRED_PASS cleared" "" "$TN_CRED_PASS"
rc=0; tn_migrate_credential 2>/dev/null || rc=$?
check_rc "migrate file: second run is a no-op" 0 "$rc"

# TPM present: host+tpm2; PCRs from TN_BIND_PCRS.
fixture testnet stdin
printf '%s\n' "$PASS" > "$ETC/bls-passphrase"
rc=0; STUB_TPM=0 TN_BIND_PCRS=7 tn_migrate_credential 2>/dev/null || rc=$?
check_rc "migrate tpm2: rc" 0 "$rc"
check "migrate tpm2: key" "host+tpm2" "$(meta_get CREDENTIAL_KEY 2>/dev/null)"
check "migrate tpm2: pcrs" "7" "$(meta_get CREDENTIAL_PCRS 2>/dev/null)"

# Refusals: nothing changes.
for case_ in "249 testnet sys 1" "255 mainnet notpm 1" "252 mainnet floor 0"; do
    set -- $case_
    fixture "$2" stdin
    printf '%s\n' "$PASS" > "$ETC/bls-passphrase"
    rc=0; STUB_SYSTEMD="$1" STUB_TPM="$4" tn_migrate_credential 2>/dev/null || rc=$?
    check_rc "migrate refused ($3): rc 1" 1 "$rc"
    check "migrate refused ($3): plaintext kept, no credential" "yes no" "$(exists "$ETC/bls-passphrase") $(exists "$ETC/bls-passphrase.cred")"
    check "migrate refused ($3): method unchanged" "stdin" "$(meta_get PASSPHRASE_METHOD 2>/dev/null)"
    check "migrate refused ($3): no restart" "" "$(grep restart "$REC/systemctl.argv" 2>/dev/null)"
done
fixture mainnet stdin
printf '%s\n' "$PASS" > "$ETC/bls-passphrase"
rc=0; STUB_TPM=1 TN_ALLOW_NO_TPM=1 tn_migrate_credential 2>/dev/null || rc=$?
check_rc "migrate mainnet --allow-no-tpm: rc 0" 0 "$rc"
fixture testnet stdin
printf 'ends-in-space \n' > "$ETC/bls-passphrase"
rc=0; tn_migrate_credential 2>/dev/null || rc=$?
check_rc "migrate: trailing whitespace refused" 1 "$rc"
check "migrate: whitespace, file kept" "yes" "$(exists "$ETC/bls-passphrase")"
fixture testnet stdin
rc=0; tn_migrate_credential 2>/dev/null || rc=$?
check_rc "migrate: no stored passphrase refused" 1 "$rc"
fixture testnet stdin
printf '%s\n' "$PASS" > "$ETC/bls-passphrase"
rc=0; STUB_CORRUPT=1 tn_migrate_credential 2>/dev/null || rc=$?
check_rc "migrate: round-trip mismatch rc 2" 2 "$rc"
check "migrate: mismatch, no credential, plaintext kept" "no yes" "$(exists "$ETC/bls-passphrase.cred") $(exists "$ETC/bls-passphrase")"
check "migrate: mismatch, unit untouched" "$ORIG_UNIT" "$(cat "$UNIT")"

# The committee guard refuses: everything goes back, no restart.
fixture testnet stdin
printf '%s\n' "$PASS" > "$ETC/bls-passphrase"
rc=0; STUB_GUARD_RC=1 tn_migrate_credential 2>/dev/null || rc=$?
check_rc "guard refuses: rc 1" 1 "$rc"
check "guard refuses: unit restored" "$ORIG_UNIT" "$(cat "$UNIT")"
check "guard refuses: no credential, plaintext kept" "no yes" "$(exists "$ETC/bls-passphrase.cred") $(exists "$ETC/bls-passphrase")"
check "guard refuses: method restored" "stdin" "$(meta_get PASSPHRASE_METHOD 2>/dev/null)"
check "guard refuses: no CREDENTIAL_KEY" "" "$(meta_get CREDENTIAL_KEY 2>/dev/null)"
check "guard refuses: no restart" "" "$(grep restart "$REC/systemctl.argv" 2>/dev/null)"
check "guard refuses: refused before any write or reload (reload, backups, re-render)" "0 0 no" \
    "$(grep -c daemon-reload "$REC/systemctl.argv" 2>/dev/null) $(ls "$T/bak" | wc -l | tr -d ' ') $(exists "$REC/rerender")"

# A run stopped inside the move: the EXIT trap (tn_remove_inflight_tmp) finishes
# or undoes it. stopped_in WHERE runs the migration in a subshell whose EXIT trap
# is the library's, and exits 143 from the stub named by WHERE.
stopped_in() {
    (
        trap 'tn_remove_inflight_tmp; printf "%s\n" "$TN_CRED_EXIT_MSG" > "$REC/exitmsg"' EXIT
        case "$1" in
            backup) tn_backup_file() { exit 143; } ;;
            wait) tn_wait_restart_window() { exit 143; } ;;
            confirm) tn_rpc_call() { exit 143; } ;;
            shred) _tn_cred_old_copies() { printf '%s\n' "$ETC/bls-passphrase"; exit 143; } ;;
        esac
        tn_migrate_credential
    ) >/dev/null 2>&1
}
fixture testnet stdin
printf '%s\n' "$PASS" > "$ETC/bls-passphrase"
stopped_in wait
check "stopped before the restart: unit, files and method back" "yes no yes stdin" \
    "$([[ "$(cat "$UNIT")" == "$ORIG_UNIT" ]] && echo yes) $(exists "$ETC/bls-passphrase.cred") $(exists "$ETC/bls-passphrase") $(meta_get PASSPHRASE_METHOD 2>/dev/null)"
check "stopped before the restart: backups shredded, reloaded, no restart" "0 2 0" \
    "$(ls "$T/bak" | wc -l | tr -d ' ') $(grep -c daemon-reload "$REC/systemctl.argv") $(grep -c '^restart' "$REC/systemctl.argv")"
check_has "stopped before the restart: the message says so" "stopped during the passphrase move, before the restart: every file it changed and .node-meta are back as they were" "$(cat "$REC/exitmsg")"
fixture testnet stdin
printf '%s\n' "$PASS" > "$ETC/bls-passphrase"
stopped_in backup
check "stopped while backing up: nothing changed" "yes yes no" \
    "$([[ "$(cat "$UNIT")" == "$ORIG_UNIT" ]] && echo yes) $(exists "$ETC/bls-passphrase") $(exists "$ETC/bls-passphrase.cred")"
fixture testnet stdin
printf '%s\n' "$PASS" > "$ETC/bls-passphrase"
stopped_in confirm
check "stopped after the restart was issued: new files stay, backups kept" "credential yes 2" \
    "$(meta_get PASSPHRASE_METHOD 2>/dev/null) $(exists "$ETC/bls-passphrase.cred") $(ls "$T/bak" | wc -l | tr -d ' ')"
check "stopped after the restart was issued: the message names the backups" "yes" \
    "$(grep -q "previous ones are kept (root only): $T/bak/" "$REC/exitmsg" && echo yes)"
fixture testnet stdin
printf '%s\n' "$PASS" > "$ETC/bls-passphrase"
stopped_in shred
check "stopped while shredding: the trap finishes (plaintext and backups gone)" "no 0 credential" \
    "$(exists "$ETC/bls-passphrase") $(ls "$T/bak" | wc -l | tr -d ' ') $(meta_get PASSPHRASE_METHOD 2>/dev/null)"

# After the node came back on the new files, the start wrapper an older release
# ran is removed.
fixture testnet stdin
printf '%s\n' "$PASS" > "$ETC/bls-passphrase"
mkdir -p "$TN_ROOT_PREFIX$DEFAULT_INSTALL_DIR"
printf '#!/bin/sh\n' > "$TN_ROOT_PREFIX$DEFAULT_INSTALL_DIR/start-telcoin.sh"
rc=0; tn_migrate_credential 2>/dev/null || rc=$?
check "migrate: the old start wrapper is removed" "0 no" "${rc} $(exists "$TN_ROOT_PREFIX$DEFAULT_INSTALL_DIR/start-telcoin.sh")"

# The node does not come back: rollback, rc 2; rollback fails too: rc 3.
fixture testnet stdin
printf '%s\n' "$PASS" > "$ETC/bls-passphrase"
rc=0; STUB_RPC_FAILS=1 tn_migrate_credential 2>/dev/null || rc=$?
check_rc "no unlock: rc 2" 2 "$rc"
check "no unlock: unit restored" "$ORIG_UNIT" "$(cat "$UNIT")"
check "no unlock: credential removed, plaintext kept" "no yes" "$(exists "$ETC/bls-passphrase.cred") $(exists "$ETC/bls-passphrase")"
check "no unlock: method restored" "stdin" "$(meta_get PASSPHRASE_METHOD 2>/dev/null)"
check "no unlock: two restarts" "2" "$(grep -c '^restart telcoin' "$REC/systemctl.argv")"
fixture testnet stdin
printf '%s\n' "$PASS" > "$ETC/bls-passphrase"
rc=0; STUB_RPC_FAILS=5 tn_migrate_credential 2>/dev/null || rc=$?
check_rc "rollback fails too: rc 3" 3 "$rc"
check "rollback fails too: unit restored anyway" "$ORIG_UNIT" "$(cat "$UNIT")"

# ---- an embedded passphrase -------------------------------------------------------------
EMB="emb-Secret-91"
fixture testnet loadcredential
printf '[Service]\nEnvironment="TN_BLS_PASSPHRASE=%s"\nExecStart=/opt/telcoin/start-telcoin.sh\n' "$EMB" > "$UNIT"
cp "$UNIT" "$UDIR/telcoin.service.bak.1"
rc=0; tn_migrate_credential 2>/dev/null || rc=$?
check_rc "embedded (Environment=): rc" 0 "$rc"
check "embedded: credential holds the unit's value" "$EMB" "$(decrypted)"
check_lacks "embedded: unit no longer holds it" "TN_BLS_PASSPHRASE=" "$(cat "$UNIT")"
check "embedded: re-render in legacy mode" "credential 1" "$(cat "$REC/rerender")"
check "embedded: old unit backup shredded" "no" "$(exists "$UDIR/telcoin.service.bak.1")"
check_lacks "embedded: value in no argv" "$EMB" "$(argv_all)"

fixture testnet loadcredential
printf '[Service]\nExecStart=/usr/bin/docker run --rm --name telcoin -e TN_BLS_PASSPHRASE=%s -e PRIMARY_LISTENER_MULTIADDR=/ip4/0.0.0.0/udp/49590/quic-v1 img:v1 telcoin node --http\n' "dock-Secret-2" > "$UNIT"
rc=0; tn_migrate_embedded_passphrase "$UNIT" 2>/dev/null || rc=$?
check_rc "embedded (docker -e): rc" 0 "$rc"
check "embedded (docker -e): value" "dock-Secret-2" "$(decrypted)"
check_lacks "embedded (docker -e): value in no argv" "dock-Secret-2" "$(argv_all)"

fixture testnet loadcredential
printf '[Service]\nEnvironment="TN_BLS_PASSPHRASE=a$b"\n' > "$UNIT"
rc=0; tn_migrate_embedded_passphrase "$UNIT" 2>/dev/null || rc=$?
check_rc "embedded: a value systemd would change is refused" 1 "$rc"
fixture testnet loadcredential
printf '[Service]\nEnvironment="TN_BLS_PASSPHRASE=one"\nEnvironment="TN_BLS_PASSPHRASE=two"\n' > "$UNIT"
rc=0; tn_migrate_embedded_passphrase "$UNIT" 2>/dev/null || rc=$?
check_rc "embedded: two different values refused" 1 "$rc"
check "embedded: refused, no credential" "no" "$(exists "$ETC/bls-passphrase.cred")"
# The operator typed it: TN_CRED_PASS wins over the unreadable unit.
TN_CRED_PASS="typed-Secret-3"
rc=0; tn_migrate_embedded_passphrase "$UNIT" 2>/dev/null || rc=$?
check_rc "embedded: typed value used" 0 "$rc"
check "embedded: typed value stored" "typed-Secret-3" "$(decrypted)"

# Below systemd 250 (testnet): a root-only file instead; mainnet refuses.
fixture testnet loadcredential
printf '[Service]\nEnvironment=TN_BLS_PASSPHRASE=%s\n' "$EMB" > "$UNIT"
rc=0; STUB_SYSTEMD=249 tn_migrate_embedded_passphrase "$UNIT" 2>/dev/null || rc=$?
check_rc "embedded below 250, testnet: rc" 0 "$rc"
check "embedded below 250: file holds the value" "$EMB" "$(cat "$ETC/bls-passphrase")"
check "embedded below 250: method stdin" "stdin" "$(meta_get PASSPHRASE_METHOD 2>/dev/null)"
check "embedded below 250: re-render saw stdin" "stdin 1" "$(cat "$REC/rerender")"
fixture mainnet loadcredential
printf '[Service]\nEnvironment=TN_BLS_PASSPHRASE=%s\n' "$EMB" > "$UNIT"
rc=0; STUB_SYSTEMD=249 tn_migrate_embedded_passphrase "$UNIT" 2>/dev/null || rc=$?
check_rc "embedded below 250, mainnet: refused" 1 "$rc"
check_has "embedded below 250, mainnet: unit untouched" "Environment=TN_BLS_PASSPHRASE=${EMB}" "$(cat "$UNIT")"

# ---- tn_host_audit prints no secret -----------------------------------------------------
fixture testnet credential
TN_CRED_PASS="audit-Secret-5"
tn_store_credential "$ETC/bls-passphrase.cred" host "" 2>/dev/null
TN_CRED_PASS=""
out="$(tn_host_audit 2>&1)"
check_has "audit: credential method line" "yes" "$(grep -q 'BLS passphrase: encrypted credential' <<< "$out" && echo yes)"
check_lacks "audit: no secret" "audit-Secret-5" "$out"

finish
