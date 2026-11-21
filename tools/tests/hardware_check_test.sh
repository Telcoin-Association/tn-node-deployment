#!/usr/bin/env bash
# =============================================================================
# tools/tests/hardware_check_test.sh -- the advisory hardware check
# (check_hardware in lib/common.sh) against the per-network tiers, on stub
# lscpu, nproc, getconf, sysctl and df and TN_PROC_MEMINFO / TN_PROC_CPUINFO
# fixtures, plus the HW_* constants and the call in setup-node.sh step_preflight.
#
#   bash tools/tests/hardware_check_test.sh
#
# Each case runs check_hardware in a subshell under set -euo pipefail, as
# setup-node.sh runs it, so a command that fails inside it shows up as a missing
# rc instead of ending the test. Output is compared with the colour codes
# stripped and the print prefixes written as "OK: ", "WARN: ", "INFO: ".
#
# Maintainer tooling: not tracked by update-scripts.sh, no .sha256 sidecar.
# bash 3.2 safe.
# =============================================================================
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
S="$T/state"
mkdir -p "$T/bin" "$S" "$T/data"
export TN_HWT_STATE="$S"

# Stubs: each answers from a file under $S and fails (no output) when the file
# is missing, so a case says exactly which sources answer.
printf '#!/bin/sh\n[ -f "$TN_HWT_STATE/lscpu" ] || exit 1\ncat "$TN_HWT_STATE/lscpu"\n' > "$T/bin/lscpu"
printf '#!/bin/sh\n[ -f "$TN_HWT_STATE/nproc" ] || exit 1\ncat "$TN_HWT_STATE/nproc"\n' > "$T/bin/nproc"
printf '#!/bin/sh\nk=""\nfor a in "$@"; do k="$a"; done\n[ -f "$TN_HWT_STATE/getconf.$k" ] || exit 1\ncat "$TN_HWT_STATE/getconf.$k"\n' > "$T/bin/getconf"
printf '#!/bin/sh\nk=""\nfor a in "$@"; do k="$a"; done\n[ -f "$TN_HWT_STATE/sysctl.$k" ] || exit 1\ncat "$TN_HWT_STATE/sysctl.$k"\n' > "$T/bin/sysctl"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> "$TN_HWT_STATE/df.args"\nif [ ! -f "$TN_HWT_STATE/df" ]; then echo "df: stub: no file system" >&2; exit 1; fi\nprintf "Filesystem     1024-blocks      Used Available Capacity Mounted on\\n"\ncat "$TN_HWT_STATE/df"\n' > "$T/bin/df"
chmod 0755 "$T/bin/lscpu" "$T/bin/nproc" "$T/bin/getconf" "$T/bin/sysctl" "$T/bin/df"
PATH="$T/bin:$PATH"

# shellcheck disable=SC2034  # read by tn_test_pre_common and fallback.sh
TN_ROOT_PREFIX="$T/root"
eval "$(tn_test_source_common)"

ESC="$(printf '\033')"
SINGLE="INFO: Prioritise single-core performance: EVM execution is single-threaded, so a high clock speed matters more than extra cores."
REC_TESTNET="INFO: Validator (recommended): 4 cores (8 vCPU) / 16 GB / 500 GB NVMe — NVMe is not checked here."
REC_MAINNET="INFO: Validator (recommended): 16 cores (32 vCPU) / 64 GB ECC / 4 TB NVMe — ECC and NVMe are not checked here."
INFO_TESTNET="INFO: Comparing with the testnet hardware tiers."
INFO_DEVNET="INFO: Comparing with the testnet hardware tiers (devnet uses them)."
INFO_MAINNET="INFO: Comparing with the mainnet hardware tiers."
INFO_NONE="INFO: Comparing with the mainnet hardware tiers (no network given)."
T_NODE_OK="OK: Full node (follower): meets minimum (2 cores (4 vCPU) / 8 GB / 350 GB)"
T_RPC_OK="OK: Public RPC node: meets minimum (4 cores (8 vCPU) / 16 GB / 350 GB)"
T_VAL_OK="OK: Validator (minimum): meets minimum (3 cores (6 vCPU) / 16 GB / 350 GB)"
M_NODE_OK="OK: Full node (follower): meets minimum (2 cores (4 vCPU) / 8 GB / 2 TB)"
M_RPC_OK="OK: Public RPC node: meets minimum (4 cores (8 vCPU) / 16 GB / 2 TB)"
M_VAL_OK="OK: Validator (minimum): meets minimum (8 cores (16 vCPU) / 32 GB / 2 TB)"
C3_HAVE="(have 4 physical cores, 16 GB RAM, 350 GB disk)"
# The "have" part lists the measured values of the short dimensions only.
M_NODE_C3="WARN: Full node (follower): below minimum — needs ≥ 2 TB disk (have 350 GB disk)"
M_RPC_C3="WARN: Public RPC node: below minimum — needs ≥ 2 TB disk (have 350 GB disk)"
M_VAL_C3="WARN: Validator (minimum): below minimum — needs ≥ 8 cores (16 vCPU), 32 GB RAM, 2 TB disk $C3_HAVE"

# host CORES MEM_KB DISK_KB AVAIL_KB [MOUNT] -- the stub state for one host:
# lscpu lists CORES cores with two threads each on socket 0 (CORES 0: lscpu
# fails), MemTotal MEM_KB (empty: no meminfo), df prints DISK_KB total and
# AVAIL_KB available on MOUNT (DISK_KB empty: df fails). cpuinfo is never
# readable, sysctl, nproc and getconf never answer, unless a case adds them.
host() {
    local cores="$1" mem="$2" disk="$3" avail="$4" mount="${5:-/mnt/data}" c
    rm -f "$S/lscpu" "$S/nproc" "$S/getconf._NPROCESSORS_ONLN" "$S/sysctl.hw.physicalcpu" \
        "$S/sysctl.hw.memsize" "$S/df" "$S/df.args" "$T/meminfo"
    if [[ "$cores" -gt 0 ]]; then
        printf '# The following is the parsable format, which can be fed to other\n# programs.\n# Core,Socket\n' > "$S/lscpu"
        for _ in 0 1; do
            c=0
            while [[ $c -lt $cores ]]; do
                printf '%s,0\n' "$c" >> "$S/lscpu"
                c=$((c + 1))
            done
        done
    fi
    if [[ -n "$mem" ]]; then
        printf 'MemTotal:       %s kB\nMemFree:         1000000 kB\nMemAvailable:    2000000 kB\n' "$mem" > "$T/meminfo"
    fi
    if [[ -n "$disk" ]]; then
        printf '/dev/nvme0n1p1 %s 1000 %s 1%% %s\n' "$disk" "$avail" "$mount" > "$S/df"
    fi
    TN_PROC_MEMINFO="$T/meminfo"
    TN_PROC_CPUINFO="$T/no-cpuinfo"
    export TN_PROC_MEMINFO TN_PROC_CPUINFO
}

# hw ARGS... -- run check_hardware ARGS in a subshell under set -euo pipefail
# (with PATH set to $HWT_PATH there when that is set). Sets OUT (normalised
# output, also in $T/out), RC ("died(<n>)" when the subshell ended before
# check_hardware returned), GAPS and SUMMARY. The subshell is a plain statement,
# never the left side of || or an if: there bash would ignore its set -e. Call
# hw itself as a plain statement for the same reason.
hw() {
    rm -f "$T/rc" "$T/gaps" "$T/summary" "$T/raw"
    local sub
    (
        set -euo pipefail
        if [[ -n "${HWT_PATH:-}" ]]; then PATH="$HWT_PATH"; fi
        unset TN_HW_GAPS TN_HW_SUMMARY
        check_hardware "$@" > "$T/raw" 2>&1
        printf '0\n' > "$T/rc"
        printf '%s' "${TN_HW_GAPS-(unset)}" > "$T/gaps"
        printf '%s' "${TN_HW_SUMMARY-(unset)}" > "$T/summary"
    )
    sub=$?
    if [[ -f "$T/rc" ]]; then RC="$(cat "$T/rc")"; else RC="died($sub)"; fi
    GAPS="$(cat "$T/gaps" 2>/dev/null)"
    SUMMARY="$(cat "$T/summary" 2>/dev/null)"
    sed -e "s/${ESC}\[[0-9;]*m//g" -e 's/^  \[OK\]  /OK: /' -e 's/^  \[WARN\] /WARN: /' \
        -e 's/^  ->  /INFO: /' "$T/raw" > "$T/out"
    OUT="$(cat "$T/out")"
}

# at TEXT -- the number of the first output line that contains TEXT, 0 when none.
at() {
    awk -v p="$1" 'index($0, p) { print NR; f = 1; exit } END { if (!f) print 0 }' "$T/out"
}

# order -- "in order" when the first line holding each landmark comes after the
# first line holding the one before it.
order() {
    local prev=0 n p
    for p in "Detected:" "Comparing with the " "Full node (follower): " "Public RPC node: " \
        "Validator (minimum): " "Validator (recommended): " "Prioritise single-core performance:" \
        "Hardware checks never block setup;"; do
        n="$(at "$p")"
        if [[ "$n" -le "$prev" ]]; then
            printf 'missing or out of order: %s\n' "$p"
            return 0
        fi
        prev="$n"
    done
    printf 'in order\n'
}

# common NAME -- the checks every case shares.
common() {
    local last
    check_rc "$1: rc 0" 0 "$RC"
    check "$1: line order" "in order" "$(order)"
    check_has "$1: single-core sentence" "$SINGLE" "$OUT"
    last="$(awk '{ l = $0 } END { print l }' "$T/out")"
    last="${last#INFO: }"
    check "$1: never-block line is last" "Hardware checks never block setup;" "${last%%;*};"
}

# --- c3-highcpu-8 (4 physical cores, 16 GB, 350 GB) on testnet ---------------
C3_MEM=16777216 C3_DISK=341796875 C3_AVAIL=332031250
host 4 "$C3_MEM" "$C3_DISK" "$C3_AVAIL"
hw "node" "$T/data" testnet
common "c3 testnet"
check_has "c3 testnet: info line" "$INFO_TESTNET" "$OUT"
check_has "c3 testnet: node meets" "$T_NODE_OK" "$OUT"
check_has "c3 testnet: rpc meets" "$T_RPC_OK" "$OUT"
check_has "c3 testnet: validator line exact" "$T_VAL_OK" "$OUT"
check_has "c3 testnet: recommended line" "$REC_TESTNET" "$OUT"
check "c3 testnet: TN_HW_GAPS empty" "" "$GAPS"
check "c3 testnet: TN_HW_SUMMARY" "4 physical cores, 16 GB RAM, 350 GB disk on /mnt/data (340 GB free)" "$SUMMARY"
check_lacks "c3 testnet: no warning" "WARN:" "$OUT"
check_lacks "c3 testnet: no mainnet recommended line" "ECC" "$OUT"
check "c3 testnet: only the Detected line says logical" "0" "$(grep -v 'Detected:' "$T/out" | grep -c -i logical)"
check_lacks "c3 testnet: no mainnet info line" "mainnet" "$OUT"

# --- the same host on mainnet -----------------------------------------------
hw "node" "$T/data" mainnet
common "c3 mainnet"
check_has "c3 mainnet: info line" "$INFO_MAINNET" "$OUT"
check_has "c3 mainnet: node below (disk)" "$M_NODE_C3" "$OUT"
check_has "c3 mainnet: rpc below (disk)" "$M_RPC_C3" "$OUT"
check_has "c3 mainnet: validator below, cores, RAM and disk" "$M_VAL_C3" "$OUT"
check_has "c3 mainnet: recommended line" "$REC_MAINNET" "$OUT"
check "c3 mainnet: TN_HW_GAPS" "node,rpc,validator" "$GAPS"
check_lacks "c3 mainnet: no meets line" "meets minimum" "$OUT"
check "c3 mainnet: TN_HW_SUMMARY" "4 physical cores, 16 GB RAM, 350 GB disk on /mnt/data (340 GB free)" "$SUMMARY"

# --- devnet uses the testnet tiers ------------------------------------------
hw "node" "$T/data" devnet
common "c3 devnet"
check_has "c3 devnet: info line" "$INFO_DEVNET" "$OUT"
check_has "c3 devnet: node meets" "$T_NODE_OK" "$OUT"
check_has "c3 devnet: rpc meets" "$T_RPC_OK" "$OUT"
check_has "c3 devnet: validator meets" "$T_VAL_OK" "$OUT"
check_has "c3 devnet: testnet recommended line" "$REC_TESTNET" "$OUT"
check "c3 devnet: TN_HW_GAPS empty" "" "$GAPS"

# --- no network, an unknown one, the old two-argument call: mainnet tiers ----
for net in "(empty)" foonet "(two arguments)"; do
    case "$net" in
        "(empty)") hw "node" "$T/data" "" ;;
        "(two arguments)") hw "node" "$T/data" ;;
        *) hw "node" "$T/data" "$net" ;;
    esac
    common "c3 $net"
    check_has "c3 $net: info line" "$INFO_NONE" "$OUT"
    check_has "c3 $net: validator below (mainnet tier)" "$M_VAL_C3" "$OUT"
    check_has "c3 $net: node below (mainnet tier)" "$M_NODE_C3" "$OUT"
    check_has "c3 $net: mainnet recommended line" "$REC_MAINNET" "$OUT"
    check "c3 $net: TN_HW_GAPS" "node,rpc,validator" "$GAPS"
done

# --- disk boundary at 350 GB: floor 350*1e9*95/100/1024 = 324707031 kB ------
host 4 "$C3_MEM" 324707031 300000000
hw "node" "$T/data" testnet
common "disk 324707031 kB"
check_has "disk 324707031 kB: validator meets" "$T_VAL_OK" "$OUT"
check_has "disk 324707031 kB: node meets" "$T_NODE_OK" "$OUT"
check "disk 324707031 kB: TN_HW_GAPS empty" "" "$GAPS"
host 4 "$C3_MEM" 324707030 300000000
hw "node" "$T/data" testnet
common "disk 324707030 kB"
# 324707030 kB is 332.49999872 GB, shown rounded.
for role in "Full node (follower)" "Public RPC node" "Validator (minimum)"; do
    check_has "disk 324707030 kB: $role needs 350 GB disk" \
        "WARN: $role: below minimum — needs ≥ 350 GB disk (have 332 GB disk)" "$OUT"
done
check "disk 324707030 kB: TN_HW_GAPS" "node,rpc,validator" "$GAPS"

# --- RAM boundary at 16 GB: floor 16*1024*1024*95/100 = 15938355 kB ----------
host 4 15938355 "$C3_DISK" "$C3_AVAIL"
hw "node" "$T/data" testnet
common "RAM 15938355 kB"
check_has "RAM 15938355 kB: validator meets" "$T_VAL_OK" "$OUT"
check "RAM 15938355 kB: TN_HW_GAPS empty" "" "$GAPS"
host 4 15938354 "$C3_DISK" "$C3_AVAIL"
hw "node" "$T/data" testnet
common "RAM 15938354 kB"
check_has "RAM 15938354 kB: node meets" "$T_NODE_OK" "$OUT"
check_has "RAM 15938354 kB: validator needs 16 GB RAM" \
    "WARN: Validator (minimum): below minimum — needs ≥ 16 GB RAM (have 15 GB RAM)" "$OUT"
check_has "RAM 15938354 kB: rpc needs 16 GB RAM" \
    "WARN: Public RPC node: below minimum — needs ≥ 16 GB RAM (have 15 GB RAM)" "$OUT"
check "RAM 15938354 kB: TN_HW_GAPS" "rpc,validator" "$GAPS"

# --- a 2-core host on testnet -------------------------------------------------
host 2 "$C3_MEM" "$C3_DISK" "$C3_AVAIL"
hw "node" "$T/data" testnet
common "2 cores testnet"
check_has "2 cores testnet: node meets" "$T_NODE_OK" "$OUT"
check_has "2 cores testnet: rpc needs 4 cores" \
    "WARN: Public RPC node: below minimum — needs ≥ 4 cores (8 vCPU) (have 2 physical cores)" "$OUT"
check_has "2 cores testnet: validator needs 3 cores" \
    "WARN: Validator (minimum): below minimum — needs ≥ 3 cores (6 vCPU) (have 2 physical cores)" "$OUT"
check "2 cores testnet: TN_HW_GAPS" "rpc,validator" "$GAPS"

# --- the mainnet validator minimum: 8 cores, 32 GB, 2 TB ----------------------
host 8 33554432 1953125000 1900000000
hw "node" "$T/data" mainnet
common "mainnet minimum host"
check_has "mainnet minimum host: node meets" "$M_NODE_OK" "$OUT"
check_has "mainnet minimum host: rpc meets" "$M_RPC_OK" "$OUT"
check_has "mainnet minimum host: validator meets" "$M_VAL_OK" "$OUT"
check "mainnet minimum host: TN_HW_GAPS empty" "" "$GAPS"
check "mainnet minimum host: TN_HW_SUMMARY" "8 physical cores, 32 GB RAM, 2000 GB disk on /mnt/data" "${SUMMARY%% (*}"
check_lacks "mainnet minimum host: no warning" "WARN:" "$OUT"
# One core short of it.
host 7 33554432 1953125000 1900000000
hw "node" "$T/data" mainnet
common "7 cores mainnet"
check_has "7 cores mainnet: validator needs 8 cores" \
    "WARN: Validator (minimum): below minimum — needs ≥ 8 cores (16 vCPU) (have 7 physical cores)" "$OUT"
check "7 cores mainnet: TN_HW_GAPS" "validator" "$GAPS"

# --- the mainnet recommended size: 16 cores, 64 GB, 4 TB ----------------------
host 16 67108864 3906250000 3900000000
for net in mainnet testnet; do
    hw "node" "$T/data" "$net"
    common "recommended host $net"
    check "recommended host $net: three meets" "3" "$(grep -c '^OK: .*: meets minimum (' "$T/out")"
    check "recommended host $net: TN_HW_GAPS empty" "" "$GAPS"
    check_lacks "recommended host $net: no warning" "WARN:" "$OUT"
done
check_has "recommended host testnet: testnet recommended line" "$REC_TESTNET" "$OUT"

# --- logical-CPU fallback: no lscpu answer, no cpuinfo, no sysctl -------------
host 0 "$C3_MEM" "$C3_DISK" "$C3_AVAIL"
printf '8\n' > "$S/nproc"
hw "node" "$T/data" testnet
common "nproc 8"
check "nproc 8: summary counts logical CPUs" "8 logical CPUs, 16 GB RAM, 350 GB disk on /mnt/data (340 GB free)" "$SUMMARY"
n_det="$(at "Detected:")"
n_cmp="$(at "Comparing with the ")"
n_note="$(awk -v d="$n_det" 'NR != d && tolower($0) ~ /logical/ { print NR; exit }' "$T/out")"
check "nproc 8: a logical-CPU note between Detected and Comparing" "yes" \
    "$([[ -n "$n_note" && "$n_note" -gt "$n_det" && "$n_note" -lt "$n_cmp" ]] && echo yes || echo "no (note line ${n_note:-none})")"
check_has "nproc 8: validator meets" "$T_VAL_OK" "$OUT"
check "nproc 8: TN_HW_GAPS empty" "" "$GAPS"
printf '2\n' > "$S/nproc"
hw "node" "$T/data" testnet
common "nproc 2"
check_has "nproc 2: node meets" "$T_NODE_OK" "$OUT"
check_has "nproc 2: validator compared with 2 logical CPUs" \
    "WARN: Validator (minimum): below minimum — needs ≥ 3 cores (6 vCPU) (have 2 logical CPUs)" "$OUT"
check "nproc 2: TN_HW_GAPS" "rpc,validator" "$GAPS"
# nproc fails too: getconf _NPROCESSORS_ONLN answers.
rm -f "$S/nproc"
printf '4\n' > "$S/getconf._NPROCESSORS_ONLN"
hw "node" "$T/data" testnet
common "getconf 4"
check "getconf 4: summary counts logical CPUs" "4 logical CPUs" "${SUMMARY%%, *}"
check "getconf 4: a logical-CPU note" "1" "$(grep -v 'Detected:' "$T/out" | grep -c -i logical)"
check "getconf 4: TN_HW_GAPS empty" "" "$GAPS"

# --- values that cannot be measured: no meminfo, df failing -------------------
host 4 "" "" ""
hw "node" "$T/data" testnet
common "unmeasured"
check "unmeasured: TN_HW_GAPS empty" "" "$GAPS"
check_lacks "unmeasured: no needs" "needs ≥" "$OUT"
check_lacks "unmeasured: no meets claim" "meets minimum" "$OUT"
host 2 "" "" ""
hw "node" "$T/data" testnet
common "unmeasured, 2 cores"
check "unmeasured, 2 cores: TN_HW_GAPS" "rpc,validator" "$GAPS"
check_has "unmeasured, 2 cores: validator needs cores only" \
    "WARN: Validator (minimum): below minimum — needs ≥ 3 cores (6 vCPU) (have 2 physical cores)" "$OUT"
check_lacks "unmeasured, 2 cores: no RAM need" "GB RAM (have" "$OUT"
check_lacks "unmeasured, 2 cores: no disk need" "disk (have" "$OUT"

# --- edge cases found by reading the implementation ---------------------------
# A real c3-highcpu-8 reports MemTotal a little under 16 GiB: shown as 16 GB, passes.
host 4 16365288 "$C3_DISK" "$C3_AVAIL"
hw "node" "$T/data" testnet
common "c3 MemTotal 16365288 kB"
check_has "c3 MemTotal 16365288 kB: validator meets" "$T_VAL_OK" "$OUT"
check "c3 MemTotal 16365288 kB: shown as 16 GB" "16 GB RAM" "$(printf '%s' "$SUMMARY" | awk -F', ' '{ print $2 }')"

# One core: the singular wording, below every tier.
host 1 "$C3_MEM" "$C3_DISK" "$C3_AVAIL"
hw "node" "$T/data" testnet
common "1 core"
check_has "1 core: node needs 2 cores, singular have" \
    "WARN: Full node (follower): below minimum — needs ≥ 2 cores (4 vCPU) (have 1 physical core)" "$OUT"
check "1 core: summary" "1 physical core" "${SUMMARY%%, *}"
check "1 core: TN_HW_GAPS" "node,rpc,validator" "$GAPS"

# No CPU source answers at all: unknown, never a gap, no logical note.
host 0 "$C3_MEM" "$C3_DISK" "$C3_AVAIL"
hw "node" "$T/data" testnet
common "no CPU count"
check "no CPU count: summary" "unknown CPUs, 16 GB RAM, 350 GB disk on /mnt/data (340 GB free)" "$SUMMARY"
check_has "no CPU count: validator could not check CPU" \
    "INFO: Validator (minimum): could not check CPU; minimum is 3 cores (6 vCPU) / 16 GB / 350 GB" "$OUT"
check "no CPU count: no logical note" "0" "$(grep -v 'Detected:' "$T/out" | grep -c -i logical)"
check "no CPU count: TN_HW_GAPS empty" "" "$GAPS"

# Nothing measurable: three "could not check" lines, mainnet wording of the tiers.
host 0 "" "" ""
hw "node" "$T/data" mainnet
common "nothing measured"
check_has "nothing measured: validator line" \
    "INFO: Validator (minimum): could not check CPU, RAM, disk; minimum is 8 cores (16 vCPU) / 32 GB / 2 TB" "$OUT"
check "nothing measured: summary" "unknown CPUs, unknown RAM, unknown disk on $T/data" "$SUMMARY"
check "nothing measured: TN_HW_GAPS empty" "" "$GAPS"

# Short on some values, others unmeasured: a warning plus a could-not-check line.
host 4 "$C3_MEM" "" ""
hw "node" "$T/data" mainnet
common "mainnet, df failing"
check_has "mainnet, df failing: validator warns on CPU and RAM" \
    "WARN: Validator (minimum): below minimum — needs ≥ 8 cores (16 vCPU), 32 GB RAM (have 4 physical cores, 16 GB RAM)" "$OUT"
check_has "mainnet, df failing: and says the disk was not checked" \
    "INFO: Validator (minimum): could not check disk; minimum is 8 cores (16 vCPU) / 32 GB / 2 TB" "$OUT"
check_has "mainnet, df failing: node could not check disk" \
    "INFO: Full node (follower): could not check disk; minimum is 2 cores (4 vCPU) / 8 GB / 2 TB" "$OUT"
check "mainnet, df failing: TN_HW_GAPS" "validator" "$GAPS"

# Zeros and garbage are "could not measure", not 0 and not an error under set -e.
host 0 0 0 0
printf '8x\n' > "$S/nproc"
printf '4\n' > "$S/getconf._NPROCESSORS_ONLN"
hw "node" "$T/data" testnet
common "zero and garbage values"
check "zero and garbage values: nproc 8x skipped for getconf, 0 kB unknown" \
    "4 logical CPUs, unknown RAM, unknown disk on /mnt/data" "$SUMMARY"
check "zero and garbage values: TN_HW_GAPS empty" "" "$GAPS"
host 4 abc "$C3_DISK" "$C3_AVAIL"
printf '/dev/x %s 1000 %s - /mnt/data\n' "$C3_DISK" "$C3_AVAIL" > "$S/df"
hw "node" "$T/data" testnet
common "MemTotal abc, no capacity column"
check "MemTotal abc, no capacity column: summary" "4 physical cores, unknown RAM, unknown disk on $T/data" "$SUMMARY"
check "MemTotal abc, no capacity column: TN_HW_GAPS empty" "" "$GAPS"

# Very large hosts: no overflow in the kB arithmetic.
host 1024 4294967296 976562500000 976000000000
hw "node" "$T/data" mainnet
common "huge host"
check "huge host: summary" "1024 physical cores, 4096 GB RAM, 1000000 GB disk on /mnt/data (999424 GB free)" "$SUMMARY"
check "huge host: three meets" "3" "$(grep -c '^OK: .*: meets minimum (' "$T/out")"
check "huge host: TN_HW_GAPS empty" "" "$GAPS"

# A device and a mount point with spaces: the fields are found from the capacity column.
host 4 "$C3_MEM" "$C3_DISK" "$C3_AVAIL"
printf 'my dev %s 1000 %s 1%% /mnt/my data\n' "$C3_DISK" "$C3_AVAIL" > "$S/df"
hw "node" "$T/data" testnet
common "mount with spaces"
check "mount with spaces: summary" "4 physical cores, 16 GB RAM, 350 GB disk on /mnt/my data (340 GB free)" "$SUMMARY"
check_has "mount with spaces: validator meets" "$T_VAL_OK" "$OUT"
# A quote, a backslash and a control character are dropped (the summary goes into JSON).
printf '/dev/x %s 1000 %s 1%% /mnt/a"b\\c\001d\n' "$C3_DISK" "$C3_AVAIL" > "$S/df"
hw "node" "$T/data" testnet
common "mount with quote"
check "mount with quote: summary" "4 physical cores, 16 GB RAM, 350 GB disk on /mnt/abcd (340 GB free)" "$SUMMARY"

# A disk 90 % used or more: a warning of its own, not a role gap.
host 4 "$C3_MEM" "$C3_DISK" 17089844
printf '/dev/x %s 324707031 17089844 95%% /mnt/data\n' "$C3_DISK" > "$S/df"
hw "node" "$T/data" testnet
common "disk 95% used"
check_has "disk 95% used: warning" "WARN: Disk /mnt/data is 95% used (18 GB free)." "$OUT"
check "disk 95% used: TN_HW_GAPS empty" "" "$GAPS"

# The data dir: the nearest existing parent is measured; spaces stay one argument.
host 4 "$C3_MEM" "$C3_DISK" "$C3_AVAIL"
hw "node" "$T/data/not/yet" testnet
common "data dir not created yet"
check "data dir not created yet: df measures the parent" "-Pk
$T/data" "$(cat "$S/df.args")"
mkdir -p "$T/my data"
rm -f "$S/df.args"
hw "node" "$T/my data/node" testnet
check "data dir with a space: one df argument" "-Pk
$T/my data" "$(cat "$S/df.args")"
check_rc "data dir with a space: rc 0" 0 "$RC"
rm -f "$S/df.args"
hw
common "no arguments"
check "no arguments: df measures /" "-Pk
/" "$(cat "$S/df.args")"
check_has "no arguments: mainnet tiers" "$INFO_NONE" "$OUT"
check "no arguments: TN_HW_GAPS" "node,rpc,validator" "$GAPS"

# The network is matched exactly: other spellings get the mainnet tiers.
for net in Testnet "testnet " "*" "-n"; do
    hw "node" "$T/data" "$net"
    common "network [$net]"
    check_has "network [$net]: mainnet tiers" "$INFO_NONE" "$OUT"
    check "network [$net]: TN_HW_GAPS" "node,rpc,validator" "$GAPS"
done

# lscpu and sysctl absent from PATH (not just silent): the logical fallback.
mkdir -p "$T/minbin"
for tool in awk cat dirname; do
    ln -s "$(type -P "$tool")" "$T/minbin/$tool"
done
for tool in nproc getconf df; do
    ln -s "$T/bin/$tool" "$T/minbin/$tool"
done
host 4 "$C3_MEM" "$C3_DISK" "$C3_AVAIL"
printf '8\n' > "$S/nproc"
HWT_PATH="$T/minbin"
hw "node" "$T/data" testnet
HWT_PATH=""
common "no lscpu or sysctl on PATH"
check "no lscpu or sysctl on PATH: logical count" "8 logical CPUs" "${SUMMARY%%, *}"
check_has "no lscpu or sysctl on PATH: the note" \
    "INFO: Physical cores could not be counted, so the tiers below are compared with logical CPUs; with hyperthreading that is up to twice the physical cores." "$OUT"
check "no lscpu or sysctl on PATH: TN_HW_GAPS empty" "" "$GAPS"

# --- the constants ------------------------------------------------------------
want="HW_MAINNET_NODE_MIN_CPU=2
HW_MAINNET_NODE_MIN_DISK_GB=2000
HW_MAINNET_NODE_MIN_RAM_GB=8
HW_MAINNET_RPC_MIN_CPU=4
HW_MAINNET_RPC_MIN_DISK_GB=2000
HW_MAINNET_RPC_MIN_RAM_GB=16
HW_MAINNET_VAL_MIN_CPU=8
HW_MAINNET_VAL_MIN_DISK_GB=2000
HW_MAINNET_VAL_MIN_RAM_GB=32
HW_MAINNET_VAL_REC_CPU=16
HW_MAINNET_VAL_REC_DISK_GB=4000
HW_MAINNET_VAL_REC_RAM_GB=64
HW_TESTNET_NODE_MIN_CPU=2
HW_TESTNET_NODE_MIN_DISK_GB=350
HW_TESTNET_NODE_MIN_RAM_GB=8
HW_TESTNET_RPC_MIN_CPU=4
HW_TESTNET_RPC_MIN_DISK_GB=350
HW_TESTNET_RPC_MIN_RAM_GB=16
HW_TESTNET_VAL_MIN_CPU=3
HW_TESTNET_VAL_MIN_DISK_GB=350
HW_TESTNET_VAL_MIN_RAM_GB=16
HW_TESTNET_VAL_REC_CPU=4
HW_TESTNET_VAL_REC_DISK_GB=500
HW_TESTNET_VAL_REC_RAM_GB=16"
# The UI mirror test reads them with readonly (HW_(TESTNET|MAINNET)_[A-Z_]+)=([0-9]+).
got="$(grep -o -E 'readonly HW_(TESTNET|MAINNET)_[A-Z_]+=[0-9]+' "$TN_TEST_REPO/lib/common.sh" | sed 's/^readonly //' | LC_ALL=C sort)"
check "constants: names and values as the UI mirror reads them" "$want" "$got"
rt=""
while IFS='=' read -r name _; do
    rt="${rt}${name}=${!name-(unset)}
"
done <<< "$want"
check "constants: the same values at run time" "$want" "${rt%?}"
ro=""
while IFS='=' read -r name _; do
    if ( eval "$name=0" ) 2>/dev/null; then ro="${ro} ${name}"; fi
done <<< "$want"
check "constants: all readonly" "" "$ro"
check "constants: no HW_NODE_, HW_RPC_ or HW_VAL_ name left in lib/common.sh" "" \
    "$(grep -n -E '(^|[^A-Za-z0-9_])HW_(NODE|RPC|VAL)_' "$TN_TEST_REPO/lib/common.sh")"
hw_comment="$(awk '/^[ \t]*#/ { buf = buf $0 "\n"; next } /readonly HW_(TESTNET|MAINNET)_/ { printf "%s", buf; exit } { buf = "" }' "$TN_TEST_REPO/lib/common.sh" | tr 'A-Z' 'a-z')"
check "constants: a comment sits above them" "yes" "$([[ -n "$hw_comment" ]] && echo yes || echo no)"
check_lacks "constants: the comment does not say adiri" "adiri" "$hw_comment"
check_has "constants: the comment names the benchmarks" "yes" "$(grep -q benchmark <<< "$hw_comment" && echo yes)"

# --- setup-node.sh step_preflight: the call follows the network choice --------
# Code lines of the function (comments dropped), as "LINE<TAB>trimmed text".
awk '
    /^step_preflight\(\)[ \t]*\{/ { on = 1 }
    on {
        t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
        if (t != "" && substr(t, 1, 1) != "#") print NR "\t" t
        if ($0 ~ /^}/) exit
    }
' "$TN_TEST_REPO/setup-node.sh" > "$T/preflight"
# pf TEXT -- the line number of the first code line of step_preflight containing TEXT, 0 when none.
pf() {
    awk -F '\t' -v p="$1" 'index($2, p) { print $1; f = 1; exit } END { if (!f) print 0 }' "$T/preflight"
}
n_call="$(pf "check_hardware")"
check "step_preflight: one check_hardware call" "1" "$(awk -F '\t' 'index($2, "check_hardware") { c++ } END { print c + 0 }' "$T/preflight")"
check "step_preflight: the call passes the network" 'check_hardware "node" "$DATA_DIR" "$NETWORK"' \
    "$(awk -F '\t' -v n="$n_call" '$1 == n { print $2 }' "$T/preflight")"
n_sel="$(pf "select_network")"
n_inet="$(pf "check_internet")"
n_json="$(pf 'json_event log "hardware: ${TN_HW_SUMMARY:-unknown}"')"
n_gaps="$(pf 'hardware below the minimum for: ${TN_HW_GAPS}')"
n_mkdir="$(pf 'mkdir -p "$DATA_DIR"')"
check "step_preflight: select_network precedes the call" "yes" \
    "$([[ "$n_sel" -gt 0 && "$n_sel" -lt "$n_call" ]] && echo yes || echo "no ($n_sel vs $n_call)")"
check "step_preflight: check_internet precedes the call" "yes" \
    "$([[ "$n_inet" -gt 0 && "$n_inet" -lt "$n_call" ]] && echo yes || echo "no ($n_inet vs $n_call)")"
check "step_preflight: mkdir of the data dir precedes the call" "yes" \
    "$([[ "$n_mkdir" -gt 0 && "$n_mkdir" -lt "$n_call" ]] && echo yes || echo "no ($n_mkdir vs $n_call)")"
check "step_preflight: the --json hardware log follows the call" "yes" \
    "$([[ "$n_json" -gt "$n_call" && "$n_gaps" -gt "$n_json" ]] && echo yes || echo "no ($n_call, $n_json, $n_gaps)")"
check "setup-node.sh: check_hardware is called only once" "1" \
    "$(awk '{ t = $0; sub(/^[ \t]+/, "", t) } substr(t, 1, 1) != "#" && index(t, "check_hardware") { c++ } END { print c + 0 }' "$TN_TEST_REPO/setup-node.sh")"

finish
