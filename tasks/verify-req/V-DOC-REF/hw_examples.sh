#!/usr/bin/env bash
# =============================================================================
# tasks/verify-req/V-DOC-REF/hw_examples.sh -- print what check_hardware in
# lib/common.sh says for the hosts the documents quote, so a quoted line can be
# compared with the real output (V-DOC-REF R1).
#
#   bash tasks/verify-req/V-DOC-REF/hw_examples.sh
#
# Stubs lscpu and df on PATH and points TN_PROC_MEMINFO / TN_PROC_CPUINFO at
# fixtures, as tools/tests/hardware_check_test.sh does. Read-only on the tree.
# bash 3.2 safe.
# =============================================================================
. "$(cd "$(dirname "$0")/../../../tools/tests" && pwd)/lib.sh"
T="$TN_TEST_TMP"
S="$T/state"
mkdir -p "$T/bin" "$S"
export TN_DXR_STATE="$S"

printf '#!/bin/sh\n[ -f "$TN_DXR_STATE/lscpu" ] || exit 1\ncat "$TN_DXR_STATE/lscpu"\n' > "$T/bin/lscpu"
printf '#!/bin/sh\n[ -f "$TN_DXR_STATE/nproc" ] || exit 1\ncat "$TN_DXR_STATE/nproc"\n' > "$T/bin/nproc"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/sysctl"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/getconf"
printf '#!/bin/sh\nprintf "Filesystem     1024-blocks      Used Available Capacity Mounted on\\n"\ncat "$TN_DXR_STATE/df"\n' > "$T/bin/df"
chmod 0755 "$T/bin/lscpu" "$T/bin/nproc" "$T/bin/sysctl" "$T/bin/getconf" "$T/bin/df"
PATH="$T/bin:$PATH"

# shellcheck disable=SC2034  # read by tn_test_pre_common and the library
TN_ROOT_PREFIX="$T/root"
eval "$(tn_test_source_common)"

# host CORES MEM_KB DISK_KB -- lscpu lists CORES cores, two threads each (0: no
# lscpu, nproc answers 8 logical CPUs); MemTotal MEM_KB; df total DISK_KB.
host() {
    local cores="$1" mem="$2" disk="$3" c t
    rm -f "$S/lscpu" "$S/nproc"
    if [[ "$cores" -gt 0 ]]; then
        printf '# Core,Socket\n' > "$S/lscpu"
        for t in 0 1; do
            c=0
            while [[ $c -lt $cores ]]; do
                printf '%s,0\n' "$c" >> "$S/lscpu"
                c=$((c + 1))
            done
            : "$t"
        done
    else
        printf '8\n' > "$S/nproc"
    fi
    printf 'MemTotal:       %s kB\n' "$mem" > "$T/meminfo"
    printf '/dev/nvme1n1 %s 1000 %s 1%% /var/lib/telcoin\n' "$disk" "$disk" > "$S/df"
    TN_PROC_MEMINFO="$T/meminfo"
    TN_PROC_CPUINFO="$T/no-cpuinfo"
    export TN_PROC_MEMINFO TN_PROC_CPUINFO
}

run() {
    echo "=== $1"
    shift
    ( check_hardware node /var/lib/telcoin "$@" ) 2>&1 | sed -e 's/\x1b\[[0-9;]*m//g'
}

# c3-highcpu-8: 4 cores, about 15.6 GiB, a 350 GB disk (df total in kB).
host 4 16375000 360000000
run "c3-highcpu-8, testnet" testnet
run "c3-highcpu-8, mainnet" mainnet
# The OPERATOR.md 1.1 example: short of the mainnet validator tier in CPU only.
host 4 33554432 2000000000
run "4 cores, 32 GiB, 2 TB disk, mainnet" mainnet
# The logical-CPU fallback.
host 0 16375000 360000000
run "no lscpu, 8 logical CPUs, testnet" testnet
