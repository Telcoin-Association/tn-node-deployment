#!/usr/bin/env bash
# V-AWS harness, part 2: the real check_hardware (lib/common.sh) on the AWS presets of
# aws/node.yaml, with lscpu, nproc, sysctl and df stubbed on PATH and a meminfo fixture.
# Written from the spec and the code under test, not from tools/tests/hardware_check_test.sh.
#
#   bash tasks/verify-req/V-AWS/hw_presets.sh              # from the worktree root
#   docker run --rm -v <W>:<W>:ro -w <W> bash:3.2 bash tasks/verify-req/V-AWS/hw_presets.sh
#
# Inputs, all from outside the code under test:
#   * CPU: AWS "compute optimized" page, Performance specifications: c7i.2xlarge 8 vCPUs,
#     4 CPU cores, 2 threads per core, 16.00 GiB; c7i.4xlarge 16 / 8 / 2, 32.00 GiB.
#     The lscpu stub prints one "core,socket" line per vCPU (two threads per core, socket 0).
#   * RAM: MemTotal fixtures. A 16 GiB guest shows about 15.4-15.6 GiB (16148070 and 16357786
#     kB are tried); a 32 GiB guest about 31.2 GiB (32715571 kB). The exact value on a c7i
#     running the Ubuntu 26.04 AMI was not measured (no instance launched).
#   * Disk: df totals from ext4_df.sh in ubuntu:26.04 (mke2fs 1.47.2, `mkfs.ext4 -q -E
#     nodiscard`, 4 KiB blocks, 256-byte inodes, one per 16 KiB, a 1 GiB journal), i.e.
#     (block count - overhead clusters) * 4 kB.
set -u

VAWS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAWS_REPO="$(cd "${VAWS_DIR}/../../.." && pwd)"
# shellcheck source=/dev/null
source "${VAWS_REPO}/tools/tests/lib.sh"
eval "$(tn_test_source_common)"

# df -Pk totals (kB) of ext4 on each volume size (GiB), from ext4_df.sh.
DF_315=323999324
DF_316=325031452
DF_350=360123532
DF_500=514937088
DF_2000=2063105424
DF_4000=4127329224

stub="${TN_TEST_TMP}/bin"
mkdir -p "$stub"

# lscpu --parse=CORE,SOCKET: VAWS_CORES cores, VAWS_TPC threads each, one socket.
cat > "${stub}/lscpu" <<'EOF'
#!/bin/sh
echo "# The following is the parsable format, which can be fed to other"
echo "# Core,Socket"
t=0
while [ "$t" -lt "${VAWS_TPC:-2}" ]; do
    c=0
    while [ "$c" -lt "${VAWS_CORES:-4}" ]; do
        echo "${c},0"
        c=$((c + 1))
    done
    t=$((t + 1))
done
EOF
cat > "${stub}/nproc" <<'EOF'
#!/bin/sh
echo $(( ${VAWS_CORES:-4} * ${VAWS_TPC:-2} ))
EOF
cat > "${stub}/sysctl" <<'EOF'
#!/bin/sh
exit 1
EOF
# df -Pk PATH: total VAWS_DF_KB, about 1 % used, mounted at /var/lib/telcoin.
cat > "${stub}/df" <<'EOF'
#!/bin/sh
total="${VAWS_DF_KB:-0}"
used=$(( total / 100 ))
avail=$(( total - used ))
echo "Filesystem     1024-blocks      Used Available Capacity Mounted on"
echo "/dev/nvme1n1 ${total} ${used} ${avail} 1% /var/lib/telcoin"
EOF
chmod +x "${stub}/lscpu" "${stub}/nproc" "${stub}/sysctl" "${stub}/df"
PATH="${stub}:${PATH}"
export PATH

meminfo="${TN_TEST_TMP}/meminfo"

# run_check CORES MEMTOTAL_KB DF_KB NETWORK -- check_hardware's output in OUT, gaps in GAPS
OUT=""
GAPS=""
run_check() {
    VAWS_CORES="$1"
    VAWS_TPC=2
    VAWS_DF_KB="$3"
    export VAWS_CORES VAWS_TPC VAWS_DF_KB
    printf 'MemTotal:       %s kB\nMemFree:        1000000 kB\n' "$2" > "$meminfo"
    TN_PROC_MEMINFO="$meminfo"
    TN_PROC_CPUINFO="${TN_TEST_TMP}/no-cpuinfo"
    export TN_PROC_MEMINFO TN_PROC_CPUINFO
    OUT="$(check_hardware node /var/lib/telcoin "$4"; printf 'rc=%s gaps=%s\n' "$?" "$TN_HW_GAPS")"
    GAPS="$(printf '%s\n' "$OUT" | sed -n 's/^rc=0 gaps=//p')"
}

# rec_role CORES MEMTOTAL_KB DF_KB -- the testnet recommended tier (4 / 16 / 500), which
# check_hardware only prints, judged with the same rule and slack as the minimum tiers.
REC=""
rec_role() {
    REC="$(_tn_hw_role "Validator (recommended)" "$HW_TESTNET_VAL_REC_CPU" "$HW_TESTNET_VAL_REC_RAM_GB" \
        "$HW_TESTNET_VAL_REC_DISK_GB" "$1" "$2" "$3" physical; printf 'rc=%s\n' "$?")"
}

C2_CORES=4
C4_CORES=8
MEM16_LO=16148070
MEM16_HI=16357786
MEM32=32715571

# 1. FullNode and Validator presets: c7i.2xlarge, every allowed size, both RAM fixtures.
for mem in "$MEM16_LO" "$MEM16_HI"; do
    for size in 350 500 2000 4000; do
        eval "dfk=\$DF_${size}"
        # shellcheck disable=SC2154
        run_check "$C2_CORES" "$mem" "$dfk" testnet
        name="c7i.2xlarge mem ${mem} ${size} GiB testnet"
        check_has "${name}: tier line" "  ->  Comparing with the testnet hardware tiers." "$OUT"
        check_has "${name}: follower" "  [OK]  Full node (follower): meets minimum (2 cores (4 vCPU) / 8 GB / 350 GB)" "$OUT"
        check_has "${name}: rpc" "  [OK]  Public RPC node: meets minimum (4 cores (8 vCPU) / 16 GB / 350 GB)" "$OUT"
        check_has "${name}: validator" "  [OK]  Validator (minimum): meets minimum (3 cores (6 vCPU) / 16 GB / 350 GB)" "$OUT"
        check "${name}: no gaps" "" "$GAPS"
        check_has "${name}: rc 0" "rc=0 gaps=" "$OUT"
        check_has "${name}: detected" "  ->  Detected: 4 physical cores, $(( (mem + 524288) / 1048576 )) GB RAM, $(( (dfk * 1024 + 500000000) / 1000000000 )) GB disk on /var/lib/telcoin ($(( ((dfk - dfk / 100) * 1024 + 500000000) / 1000000000 )) GB free)" "$OUT"
    done
done

# 2. Validator recommended (4 cores / 16 GB / 500 GB): met on 500, 2000 and 4000 GiB, not on
#    350 GiB (368.8 GB of filesystem against a 475 GB floor).
for size in 500 2000 4000; do
    eval "dfk=\$DF_${size}"
    rec_role "$C2_CORES" "$MEM16_LO" "$dfk"
    check_has "c7i.2xlarge ${size} GiB: recommended met" "  [OK]  Validator (recommended): meets minimum (4 cores (8 vCPU) / 16 GB / 500 GB)" "$REC"
done
rec_role "$C2_CORES" "$MEM16_LO" "$DF_350"
check_has "c7i.2xlarge 350 GiB: recommended disk short" "  [WARN] Validator (recommended): below minimum — needs ≥ 500 GB disk (have 369 GB disk)" "$REC"

# 3. PublicRPC preset: c7i.4xlarge, every allowed size.
for size in 350 500 2000 4000; do
    eval "dfk=\$DF_${size}"
    run_check "$C4_CORES" "$MEM32" "$dfk" testnet
    name="c7i.4xlarge ${size} GiB testnet"
    check_has "${name}: follower" "  [OK]  Full node (follower): meets minimum (2 cores (4 vCPU) / 8 GB / 350 GB)" "$OUT"
    check_has "${name}: rpc" "  [OK]  Public RPC node: meets minimum (4 cores (8 vCPU) / 16 GB / 350 GB)" "$OUT"
    check_has "${name}: validator" "  [OK]  Validator (minimum): meets minimum (3 cores (6 vCPU) / 16 GB / 350 GB)" "$OUT"
    check "${name}: no gaps" "" "$GAPS"
done
# The RPC recommended row (8 cores / 32 GB) has no check in the code; judge it by hand with
# the same rule: 8 >= 8 cores, 32715571 kB >= 32 GiB * 95 % = 31876710 kB.
check_rc "c7i.4xlarge RAM >= 95 % of 32 GB" 0 "$([ "$MEM32" -ge $(( 32 * 1024 * 1024 * 95 / 100 )) ]; echo $?)"

# 4. The disk floor (350 GB with 5 % slack = 324707031 kB) by volume size: 316 GiB is the
#    smallest whole GiB that passes, 315 GiB warns. 350 GiB clears it by about 36 GB.
run_check "$C2_CORES" "$MEM16_LO" "$DF_316" testnet
check "316 GiB: no gaps" "" "$GAPS"
run_check "$C2_CORES" "$MEM16_LO" "$DF_315" testnet
check "315 GiB: every role below on disk" "node,rpc,validator" "$GAPS"
check_has "315 GiB: validator line" "  [WARN] Validator (minimum): below minimum — needs ≥ 350 GB disk (have 332 GB disk)" "$OUT"
check_rc "floor is 324707031 kB" 0 "$([ $(( 350 * 1000000000 * 95 / 100 / 1024 )) -eq 324707031 ]; echo $?)"

# 5. RAM margin on a 16 GiB instance: the floor is 16 GiB * 95 % = 15938355 kB (15.2 GiB),
#    so up to 838861 kB (819 MiB) of the 16 GiB may be reserved. A 512 MiB crashkernel on
#    top of about 400 MiB of kernel reservations would cross it.
run_check "$C2_CORES" 15938355 "$DF_500" testnet
check "MemTotal 15938355: no gaps" "" "$GAPS"
run_check "$C2_CORES" 15938354 "$DF_500" testnet
check "MemTotal 15938354: rpc and validator below" "rpc,validator" "$GAPS"
run_check "$C2_CORES" $(( 16777216 - 524288 - 409600 )) "$DF_500" testnet
check "16 GiB - 512 MiB crashkernel - 400 MiB: rpc and validator below" "rpc,validator" "$GAPS"
check_has "crashkernel case: validator line" "  [WARN] Validator (minimum): below minimum — needs ≥ 16 GB RAM (have 15 GB RAM)" "$OUT"

# 6. For the docs (F7/F9): the same c7i.2xlarge on mainnet is below the validator minimum,
#    and the PublicRPC c7i.4xlarge is too (8 cores, 32 GiB, but 500 GiB < 2 TB).
run_check "$C2_CORES" "$MEM16_LO" "$DF_500" mainnet
check "c7i.2xlarge 500 GiB mainnet gaps" "node,rpc,validator" "$GAPS"
run_check "$C4_CORES" "$MEM32" "$DF_2000" mainnet
check "c7i.4xlarge 2000 GiB mainnet gaps" "" "$GAPS"

finish
