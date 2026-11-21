#!/usr/bin/env bash
# =============================================================================
# tasks/verify-req/V-HW-UI/h6_preflight.sh -- setup-node.sh step_preflight,
# run for real up to the systemd floor, in --json mode and interactively.
#
#   bash h6_preflight.sh RUN_DIR [REPO]
#
# RUN_DIR is an h1_shell.sh run (its bin/ stubs and the fixture of host tnval are
# used). setup-node.sh is sourced as tools/tests/os_floor_test.sh sources it; the
# steps around the hardware check that touch the box (check_root, the lock,
# restart guards, ports, packages, check_internet) are replaced by no-ops, and
# tn_os_floor_check (the first step after the hardware block) prints STOP and
# ends the run. Prints, per mode and network, the "Comparing with" line and the
# --json log events (fd 3). bash 3.2 safe.
# =============================================================================
set -u
RUN="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="${2:-$(cd "$HERE/../../.." && pwd)}"
# shellcheck source=/dev/null
. "$REPO/tools/tests/lib.sh"
T="$TN_TEST_TMP"
mkdir -p "$T/sn"
grep -v '^main "\$@"$' "$REPO/setup-node.sh" > "$T/sn/setup-node.sh"
ln -s "$REPO/lib" "$T/sn/lib"
# shellcheck disable=SC2034  # read by lib/common.sh (fallback.sh probes)
TN_ROOT_PREFIX="$T/root"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/sn/setup-node.sh"
set +e
PATH="$RUN/bin:$PATH"
export STUB_FX="$RUN/fx/tnval"
# shellcheck disable=SC2034  # read by check_hardware
TN_PROC_MEMINFO="$STUB_FX/meminfo"
# shellcheck disable=SC2034
TN_PROC_CPUINFO="$STUB_FX/cpuinfo"

check_root() { :; }
setup_take_lock() { :; }
detect_distro() { :; }
setup_write_restart_guards() { :; }
check_cve_2026_31431() { :; }
check_ports() { :; }
install_package() { :; }
tn_mainnet_enabled() { return 0; }
check_internet() { echo "STUB check_internet NETWORK=${NETWORK}"; }
tn_os_floor_check() { echo "STOP at tn_os_floor_check NETWORK=${1}"; exit 0; }

run_one() {   # MODE NET
    local mode="$1" net="$2"
    (
        DATA_DIR="$STUB_FX/data/node"
        if [[ "$mode" == "json" ]]; then
            JSON_MODE=true
            json_set_network "$net"
            ( step_preflight ) 3> "$T/fd3" > "$T/out" 2>&1
        else
            # shellcheck disable=SC2034  # read by json_mode in setup-node.sh
            JSON_MODE=false
            NETWORK=""
            # select_network: 1 = testnet, 2 = mainnet (enabled by the stub); the data
            # dir prompt takes the default.
            if [[ "$net" == "mainnet" ]]; then c=2; else c=1; fi
            printf '%s\n%s\n' "$DATA_DIR" "$c" | step_preflight 3> "$T/fd3" > "$T/out" 2>&1
        fi
        echo "--- ${mode} ${net}"
        grep -E 'STUB check_internet|Comparing with|Validator \(minimum\)|STOP' "$T/out"
        sed 's/^/  fd3: /' "$T/fd3"
    )
}
for net in testnet adiri devnet mainnet; do run_one json "$net"; done
for net in testnet mainnet; do run_one interactive "$net"; done
# The order inside step_preflight, statically: select_network, check_internet, check_hardware.
awk '/^step_preflight\(\)/,/^}/' "$REPO/setup-node.sh" | grep -n -E 'select_network|check_internet$|check_hardware|mkdir -p "\$DATA_DIR"|json_event log'
