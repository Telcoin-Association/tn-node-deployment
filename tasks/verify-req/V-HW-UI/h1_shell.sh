#!/usr/bin/env bash
# =============================================================================
# tasks/verify-req/V-HW-UI/h1_shell.sh -- V-HW-UI parity harness, shell side.
#
#   bash h1_shell.sh HOSTS_TSV OUT_DIR [REPO]
#
# For every fake host in HOSTS_TSV it writes the fixtures both sides read
# (OUT_DIR/fx/<id>/: lscpu, cpuinfo, sysctl, nproc, meminfo, df, data/), puts
# stub lscpu, nproc, sysctl, getconf and df on PATH, points TN_PROC_MEMINFO and
# TN_PROC_CPUINFO at the fixtures, sources REPO/lib/common.sh the way
# tools/tests/os_floor_test.sh does and runs
#   check_hardware node <data dir> <network>
# for the networks testnet, mainnet, devnet, adiri and "" (none). Each run's
# output goes to OUT_DIR/sh/<id>.<net>.txt; the parsed verdicts to
# OUT_DIR/shell.tsv:
#   host net tierset role verdict dims spec
# verdict is pass, below or unknown (could not measure); dims lists the
# dimensions below the tier (cpu,ram,disk). OUT_DIR must not exist yet.
# REPO defaults to the worktree this file sits in. bash 3.2 safe.
# =============================================================================
set -u
if [[ $# -lt 2 ]]; then
    echo "usage: h1_shell.sh HOSTS_TSV OUT_DIR [REPO]" >&2
    exit 2
fi
HOSTS="$1"
OUT="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="${3:-$(cd "$HERE/../../.." && pwd)}"
mkdir "$OUT" || { echo "h1_shell.sh: $OUT exists or cannot be made" >&2; exit 2; }
mkdir "$OUT/fx" "$OUT/sh" "$OUT/bin"

# ---- stubs (POSIX sh, read the current host's fixtures from $STUB_FX) --------
printf '%s\n' '#!/bin/sh' '[ -f "$STUB_FX/lscpu" ] || exit 1' 'cat "$STUB_FX/lscpu"' > "$OUT/bin/lscpu"
printf '%s\n' '#!/bin/sh' '[ -f "$STUB_FX/nproc" ] || exit 1' 'cat "$STUB_FX/nproc"' > "$OUT/bin/nproc"
printf '%s\n' '#!/bin/sh' '[ "$1" = -n ] && [ "$2" = hw.physicalcpu ] && [ -f "$STUB_FX/sysctl" ] || exit 1' \
    'cat "$STUB_FX/sysctl"' > "$OUT/bin/sysctl"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$OUT/bin/getconf"
printf '%s\n' '#!/bin/sh' 'for a in "$@"; do last="$a"; done' 'printf "%s\n" "$last" >> "$STUB_FX/df.log"' \
    '[ -f "$STUB_FX/df" ] || exit 1' 'read t u a p < "$STUB_FX/df"' \
    'printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/fake %s %s %s %s%% /fake\n" "$t" "$u" "$a" "$p"' \
    > "$OUT/bin/df"
chmod 0755 "$OUT/bin/lscpu" "$OUT/bin/nproc" "$OUT/bin/sysctl" "$OUT/bin/getconf" "$OUT/bin/df"

# ---- fixture writers -----------------------------------------------------------
# gen_lscpu C T S -- lscpu --parse=CORE,SOCKET for S sockets x C cores x T threads.
gen_lscpu() {
    local c t s
    printf '# The following is the parsable format, which can be fed to other\n# Core,Socket\n'
    s=0
    while [[ $s -lt $3 ]]; do
        c=0
        while [[ $c -lt $1 ]]; do
            t=0
            while [[ $t -lt $2 ]]; do printf '%s,%s\n' "$c" "$s"; t=$((t + 1)); done
            c=$((c + 1))
        done
        s=$((s + 1))
    done
}
# gen_cpuinfo C T S -- an x86 /proc/cpuinfo with physical id and core id.
gen_cpuinfo() {
    local c t s n=0
    s=0
    while [[ $s -lt $3 ]]; do
        c=0
        while [[ $c -lt $1 ]]; do
            t=0
            while [[ $t -lt $2 ]]; do
                printf 'processor\t: %s\nmodel name\t: Fake CPU\nphysical id\t: %s\ncore id\t\t: %s\n\n' "$n" "$s" "$c"
                n=$((n + 1)); t=$((t + 1))
            done
            c=$((c + 1))
        done
        s=$((s + 1))
    done
}
gen_arm_cpuinfo() {
    printf 'processor\t: 0\nBogoMIPS\t: 50.00\n\nprocessor\t: 1\nBogoMIPS\t: 50.00\n\n'
}

# write_fixtures DIR CPU MEM DISK DIRMODE
write_fixtures() {
    local d="$1" cpu="$2" mem="$3" disk="$4" dmode="$5" kind a b c
    mkdir -p "$d/data"
    if [[ "$dmode" == "exists" ]]; then mkdir "$d/data/node"; fi
    printf '%s\n' "$d/data/node" > "$d/datadir"
    kind="${cpu%%:*}"
    a=""; b=""; c=""
    if [[ "$cpu" == *:*:*:* ]]; then
        a="$(printf '%s' "$cpu" | cut -d: -f2)"
        b="$(printf '%s' "$cpu" | cut -d: -f3)"
        c="$(printf '%s' "$cpu" | cut -d: -f4)"
    elif [[ "$cpu" == *:* ]]; then
        a="${cpu#*:}"
    fi
    case "$kind" in
        lscpu)
            gen_lscpu "$a" "$b" "$c" > "$d/lscpu"
            gen_cpuinfo "$a" "$b" "$c" > "$d/cpuinfo"
            printf '%s\n' "$((a * b * c))" > "$d/nproc" ;;
        cpuinfo)
            gen_cpuinfo "$a" "$b" "$c" > "$d/cpuinfo"
            printf '%s\n' "$((a * b * c))" > "$d/nproc" ;;
        sysctl)
            gen_arm_cpuinfo > "$d/cpuinfo"
            printf '%s\n' "$a" > "$d/sysctl"
            printf '2\n' > "$d/nproc" ;;
        nproc)
            gen_arm_cpuinfo > "$d/cpuinfo"
            printf '%s\n' "$a" > "$d/nproc" ;;
        raw)
            case "$a" in
                emptysock) printf '# Core,Socket\n0,\n1,\n0,\n1,\n' > "$d/lscpu" ;;
                nocore)    printf '# Core,Socket\n,0\n0,0\n1,0\n,0\n1,0\n' > "$d/lscpu" ;;
                *) echo "unknown raw fixture $a" >&2; exit 2 ;;
            esac
            gen_arm_cpuinfo > "$d/cpuinfo"
            printf '4\n' > "$d/nproc" ;;
        none) : ;;
        *) echo "unknown cpu spec $cpu" >&2; exit 2 ;;
    esac
    case "$mem" in
        none) : ;;
        zero) printf 'MemTotal:              0 kB\nMemFree:               0 kB\n' > "$d/meminfo" ;;
        nomemtotal) printf 'MemFree:         1000000 kB\nMemAvailable:    2000000 kB\n' > "$d/meminfo" ;;
        junk) printf 'MemTotal:        abc kB\n' > "$d/meminfo" ;;
        *) printf 'MemTotal:       %s kB\nMemFree:         1000000 kB\nMemAvailable:    2000000 kB\n' "$mem" > "$d/meminfo" ;;
    esac
    case "$disk" in
        none) : ;;
        zero) printf '0 0 0 0\n' > "$d/df" ;;
        *) printf '%s 0 %s 0\n' "$disk" "$disk" > "$d/df" ;;
    esac
}

# parse_out FILE -- the verdict rows of one check_hardware output (no host/net).
parse_out() {
    awk '
    function role_of(line,   r) {
        r = ""
        if (index(line, "Full node (follower): ")) r = "node"
        else if (index(line, "Public RPC node: ")) r = "rpc"
        else if (index(line, "Validator (minimum): ")) r = "validator"
        return r
    }
    /Comparing with the / { s = $0; sub(/.*Comparing with the /, "", s); sub(/ hardware tiers.*/, "", s); tierset = s }
    {
        r = role_of($0)
        if (r == "") next
        if (index($0, ": below minimum")) {
            n = index($0, "needs "); rest = substr($0, n + 6); sub(/^[^ ]* /, "", rest)
            h = index(rest, " (have "); need = substr(rest, 1, h - 1)
            k = split(need, parts, ", "); dl = ""
            for (i = 1; i <= k; i++) {
                if (parts[i] ~ /vCPU\)$/) dm = "cpu"
                else if (parts[i] ~ / GB RAM$/) dm = "ram"
                else if (parts[i] ~ / disk$/) dm = "disk"
                else dm = "?" parts[i]
                dl = dl (dl == "" ? "" : ",") dm
            }
            v[r] = "below"; dims[r] = dl
        } else if (index($0, ": meets minimum (")) {
            sp = $0; sub(/.*: meets minimum \(/, "", sp); sub(/\)$/, "", sp)
            if (v[r] == "") v[r] = "pass"; spec[r] = sp
        } else if (index($0, ": could not check ")) {
            sp = $0; sub(/.*; minimum is /, "", sp)
            if (v[r] == "") v[r] = "unknown"; spec[r] = sp
        }
    }
    END {
        split("node rpc validator", roles, " ")
        for (i = 1; i <= 3; i++) {
            r = roles[i]
            printf "%s\t%s\t%s\t%s\t%s\n", tierset, r, (v[r] == "" ? "MISSING" : v[r]), (dims[r] == "" ? "-" : dims[r]), (spec[r] == "" ? "-" : spec[r])
        }
    }' "$1"
}

# ---- source the library under test --------------------------------------------
# shellcheck source=/dev/null
. "$REPO/tools/tests/lib.sh"
# shellcheck disable=SC2034  # read by lib/common.sh (fallback.sh probes)
TN_ROOT_PREFIX="$TN_TEST_TMP/root"
eval "$(tn_test_source_common)"
set +e
PATH="$OUT/bin:$PATH"
export PATH

printf 'host\tnet\ttierset\trole\tverdict\tdims\tspec\n' > "$OUT/shell.tsv"
printf 'host\tnet\trc\tgaps\tlogical_note\tdf_path\n' > "$OUT/shell-meta.tsv"
while IFS="$(printf '\t')" read -r id cpu mem disk dmode _note; do
    case "$id" in ''|'#'*) continue ;; esac
    fx="$OUT/fx/$id"
    mkdir "$fx"
    write_fixtures "$fx" "$cpu" "$mem" "$disk" "$dmode"
    datadir="$(cat "$fx/datadir")"
    for net in testnet mainnet devnet adiri none; do
        arg="$net"
        if [[ "$net" == "none" ]]; then arg=""; fi
        o="$OUT/sh/$id.$net.txt"
        : > "$fx/df.log"
        (
            export STUB_FX="$fx"
            # shellcheck disable=SC2034  # read by check_hardware in lib/common.sh
            TN_PROC_MEMINFO="$fx/meminfo"
            # shellcheck disable=SC2034
            TN_PROC_CPUINFO="$fx/cpuinfo"
            rc=0
            check_hardware node "$datadir" "$arg" || rc=$?
            printf 'RC=%s\nGAPS=%s\nSUMMARY=%s\n' "$rc" "$TN_HW_GAPS" "$TN_HW_SUMMARY"
        ) > "$o" 2>&1
        parse_out "$o" | while IFS="$(printf '\t')" read -r ts role verdict dims spec; do
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$net" "$ts" "$role" "$verdict" "$dims" "$spec"
        done >> "$OUT/shell.tsv"
        rcv="$(sed -n 's/^RC=//p' "$o")"
        gaps="$(sed -n 's/^GAPS=//p' "$o")"
        note=no
        if grep -q 'compared with logical CPUs' "$o"; then note=yes; fi
        dfp="$(head -n 1 "$fx/df.log")"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$net" "${rcv:-?}" "${gaps:--}" "$note" "${dfp:--}" >> "$OUT/shell-meta.tsv"
    done
done < "$HOSTS"
echo "h1_shell.sh: $(($(wc -l < "$OUT/shell.tsv") - 1)) rows in $OUT/shell.tsv"
finish >/dev/null 2>&1 || true
