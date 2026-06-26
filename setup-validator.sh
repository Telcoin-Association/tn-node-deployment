#!/usr/bin/env bash
# =============================================================================
# setup-validator.sh -- DEPRECATED shim.
#
# The observer/validator split has been collapsed into a single node identity:
# the protocol decides a node's role on-chain from committee membership at each
# epoch, not from a static flag. This forwards to the unified setup-node.sh so
# existing installs, docs, and the UI's setup dispatch keep working unchanged.
# It will be removed in a future release -- use setup-node.sh directly.
# =============================================================================
set -euo pipefail

readonly SCRIPT_VERSION="1.2.22"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "NOTE: setup-validator.sh is deprecated -- forwarding to the unified setup-node.sh." >&2
exec bash "${SCRIPT_DIR}/setup-node.sh" "$@"
