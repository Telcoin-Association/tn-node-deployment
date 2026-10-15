#!/usr/bin/env bash
# =============================================================================
# tools/tests/os_floor_test.sh -- the systemd floor (tn_os_floor_check) and
# setup-node.sh's choice of passphrase storage (setup_passphrase_method) with a
# systemctl --version shim at 246, 249, 250 and 255 and a systemd-creds shim
# with and without a TPM2.
#
#   bash tools/tests/os_floor_test.sh
#
# Maintainer tooling: not tracked by update-scripts.sh, no .sha256 sidecar.
# bash 3.2 safe.
# =============================================================================
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
mkdir -p "$T/bin" "$T/sn"
printf '#!/bin/sh\n[ "$1" = --version ] && printf "systemd %%s (%%s.1)\\n" "${STUB_SYSTEMD:-255}" "${STUB_SYSTEMD:-255}"\nexit 0\n' > "$T/bin/systemctl"
printf '#!/bin/sh\n[ "$1" = has-tpm2 ] && exit "${STUB_TPM:-1}"\nexit 0\n' > "$T/bin/systemd-creds"
chmod 0755 "$T/bin/systemctl" "$T/bin/systemd-creds"
PATH="$T/bin:$PATH"
grep -v '^main "\$@"$' "$TN_TEST_REPO/setup-node.sh" > "$T/sn/setup-node.sh"
ln -s "$TN_TEST_REPO/lib" "$T/sn/lib"
TN_ROOT_PREFIX="$T/root"
tn_test_pre_common
source "$T/sn/setup-node.sh"
set +e

# floor VERSION NETWORK -- rc of tn_os_floor_check, its messages on $T/err.
floor() {
    local rc=0
    STUB_SYSTEMD="$1" tn_os_floor_check "$2" 2> "$T/err" || rc=$?
    printf '%s\n' "$rc"
}
check_rc "mainnet, systemd 255: ok" 0 "$(floor 255 mainnet)"
check_rc "mainnet, systemd 250: ok" 0 "$(floor 250 mainnet)"
check_rc "mainnet, systemd 249: refused" 1 "$(floor 249 mainnet)"
check_has "mainnet, 249: names the floor" "yes" "$(grep -q 'below the mainnet floor' "$T/err" && echo yes)"
check_rc "testnet, systemd 249: ok" 0 "$(floor 249 testnet)"
check_has "testnet, 249: warns" "yes" "$(grep -q 'cannot encrypt credentials' "$T/err" && echo yes)"
check_rc "testnet, systemd 255: ok" 0 "$(floor 255 testnet)"
check "testnet, 255: no warning" "" "$(cat "$T/err")"
check_rc "testnet, systemd 246: refused" 1 "$(floor 246 testnet)"
check_rc "unknown network, 249: refused like mainnet" 1 "$(floor 249 "")"

# method VERSION TPM NETWORK [VAR=VALUE...] -- run setup_passphrase_method in a
# subshell; prints "<rc> <PASSPHRASE_METHOD> <CREDENTIAL_KEY>".
method() {
    local v="$1" tpm="$2" net="$3"
    shift 3
    (
        PASSPHRASE_METHOD="" CREDENTIAL_KEY="" BIND_PCRS="" ALLOW_NO_TPM=false NETWORK="$net"
        for a in "$@"; do eval "$a"; done
        export STUB_SYSTEMD="$v" STUB_TPM="$tpm"
        setup_passphrase_method > "$T/out" 2>&1
        printf '0 %s %s\n' "$PASSPHRASE_METHOD" "${CREDENTIAL_KEY:--}"
    ) || printf '1\n'
}
check "255 + TPM, mainnet: credential host+tpm2" "0 credential host+tpm2" "$(method 255 0 mainnet)"
check "255, no TPM, testnet: credential host" "0 credential host" "$(method 255 1 testnet)"
check "255, no TPM, mainnet: refused" "1" "$(method 255 1 mainnet)"
check_has "255, no TPM, mainnet: names --allow-no-tpm" "yes" "$(grep -q -- '--allow-no-tpm' "$T/out" && echo yes)"
check "255, no TPM, mainnet, --allow-no-tpm: host" "0 credential host" "$(method 255 1 mainnet ALLOW_NO_TPM=true)"
check "249, testnet: stdin" "0 stdin -" "$(method 249 1 testnet)"
check_has "249, testnet: warns about the file" "yes" "$(grep -q 'root-only file' "$T/out" && echo yes)"
check "249, mainnet: refused" "1" "$(method 249 1 mainnet)"
check "249, explicit credential: refused" "1" "$(method 249 1 testnet PASSPHRASE_METHOD=credential)"
check "255, explicit stdin on testnet: kept" "0 stdin -" "$(method 255 0 testnet PASSPHRASE_METHOD=stdin)"
check "255, explicit stdin on mainnet: refused" "1" "$(method 255 0 mainnet PASSPHRASE_METHOD=stdin)"
check "--bind-pcrs with a TPM" "0 credential host+tpm2" "$(method 255 0 testnet BIND_PCRS=7)"
check "--bind-pcrs without a TPM: refused" "1" "$(method 255 1 testnet BIND_PCRS=7)"
check "--bind-pcrs below 250: refused" "1" "$(method 249 0 testnet BIND_PCRS=7)"
finish
