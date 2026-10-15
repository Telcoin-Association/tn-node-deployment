#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# tools/tests/vm.d/vm_lib.sh -- prelude for the VM assertions in this directory
#
# Each tools/tests/vm.d/P0-<nn>.sh checks one hardening item on the host it
# runs on: it creates users, writes under /etc, /opt and /usr/local and changes
# the firewall, so it runs only as root on a disposable VM and only with
# TN_VM_TEST=1 (.github/workflows/integration.yml sets both). An item whose
# code is not in the tree yet reports SKIP and exits 0.
#
# Sourced at the top level of each file; provides check/skip/finish from
# tools/tests/lib.sh, VM_REPO (the repository root) and have_fn NAME.
# Maintainer tooling: not tracked by the updater, no sidecar.
# =============================================================================

if [ "${TN_VM_TEST:-}" != "1" ]; then
    echo "refusing: VM assertions change this host; run them as root on a disposable VM with TN_VM_TEST=1" >&2
    exit 2
fi
if [ "$(id -u)" != "0" ]; then
    echo "refusing: VM assertions run as root" >&2
    exit 2
fi

# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck disable=SC2034  # used by the files that source this one
VM_REPO="$TN_TEST_REPO"

have_fn() {
    declare -F "$1" >/dev/null 2>&1
}
