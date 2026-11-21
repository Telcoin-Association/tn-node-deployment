#!/usr/bin/env bash
# =============================================================================
# s2-case.sh STEP MODE -- one setup-node.sh process, fixture style (a copy of
# setup-node.sh without its last line, sourced at the top level, as
# tools/tests/finalize_inputs_test.sh does), run as root inside a disposable
# container by s2-inner.sh / s3-inner.sh. STEP: infra (step_create_infrastructure,
# under the update lock, as step_preflight takes it) or write (step_write_config).
# MODE: plain or json (JSON_MODE, json_setup_fds and TN_ASSUME_YES as
# run_json_mode sets them). The EXIT trap is json_on_exit, as main installs it.
# S2_SN: setup-node.sh to use (default /s/setup-node.sh); S2_LIB: its lib dir
# (default /s/lib). set -euo pipefail stays as the library leaves it.
# =============================================================================
step="${1:-}"
mode="${2:-plain}"
sn_src="${S2_SN:-/s/setup-node.sh}"
lib_src="${S2_LIB:-/s/lib}"
SN="/tmp/s2-sn-$$"
mkdir -p "$SN"
grep -v '^main "\$@"$' "$sn_src" > "${SN}/setup-node.sh"
ln -s "$lib_src" "${SN}/lib"
# shellcheck source=/dev/null
source "${SN}/setup-node.sh"

# shellcheck disable=SC2034  # read by setup-node.sh
NETWORK=testnet
# shellcheck disable=SC2034
CHAIN_ID="$TESTNET_CHAIN_ID"
# shellcheck disable=SC2034
CHAIN_NAME="$TESTNET_CHAIN_NAME"
# shellcheck disable=SC2034
INSTALL_METHOD=docker
# shellcheck disable=SC2034
DOCKER_IMAGE="${GAR_IMAGE_BASE:-img}@sha256:1111111111111111111111111111111111111111111111111111111111111111"
# The node-flag probe asks the release (not installed here).
prepare_node_extra_flags() { return 0; }

if [[ "$mode" == "json" ]]; then
    # shellcheck disable=SC2034
    JSON_MODE=true
    json_setup_fds
    export TN_ASSUME_YES=true
fi
# shellcheck disable=SC2034
TN_EXIT_TRAP_OWNED=1
trap json_on_exit EXIT
# shellcheck disable=SC2034
trap 'SETUP_SIGNAL=TERM; exit 143' TERM
# shellcheck disable=SC2034
trap 'SETUP_SIGNAL=INT; exit 130' INT

case "$step" in
    infra)
        setup_take_lock
        step_create_infrastructure
        ;;
    write)
        step_write_config
        ;;
    *)
        echo "usage: s2-case.sh infra|write plain|json" >&2
        exit 2
        ;;
esac
echo "S2_STEP_COMPLETED ${step}"
if json_mode; then
    json_done '{"event":"done","ok":true,"msg":"s2 step completed"}'
fi
exit 0
