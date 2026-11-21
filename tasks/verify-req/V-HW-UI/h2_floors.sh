#!/usr/bin/env bash
# =============================================================================
# tasks/verify-req/V-HW-UI/h2_floors.sh -- the shell's pass floors against the
# server's integers.
#
#   bash h2_floors.sh REPO ram:GB:KB ... disk:GB:KB ...
#
# Each argument is a floor the server computed (h2_constants.py prints them on
# its FLOORS line). For ram:GB:KB, _tn_hw_role with a GB RAM tier must pass at
# KB and warn at KB-1; for disk:GB:KB the same with a GB disk tier. Also prints
# the shell's own formula result. Exit 1 on any mismatch. bash 3.2 safe.
# =============================================================================
set -u
REPO="$1"
shift
# shellcheck source=/dev/null
. "$REPO/tools/tests/lib.sh"
# shellcheck disable=SC2034  # read by lib/common.sh (fallback.sh probes)
TN_ROOT_PREFIX="$TN_TEST_TMP/root"
eval "$(tn_test_source_common)"
set +e
bad=0
for spec in "$@"; do
    kind="${spec%%:*}"
    rest="${spec#*:}"
    gb="${rest%%:*}"
    kb="${rest#*:}"
    if [[ "$kind" == "ram" ]]; then
        shell_floor=$(( gb * 1024 * 1024 * 95 / 100 ))
        _tn_hw_role X 1 "$gb" 1 1 "$kb" 999999999999 physical > /dev/null; at=$?
        _tn_hw_role X 1 "$gb" 1 1 "$((kb - 1))" 999999999999 physical > /dev/null; under=$?
    else
        shell_floor=$(( gb * 1000000000 * 95 / 100 / 1024 ))
        _tn_hw_role X 1 1 "$gb" 1 999999999999 "$kb" physical > /dev/null; at=$?
        _tn_hw_role X 1 1 "$gb" 1 999999999999 "$((kb - 1))" physical > /dev/null; under=$?
    fi
    verdict=ok
    if [[ "$at" != 0 || "$under" != 1 || "$shell_floor" != "$kb" ]]; then verdict=MISMATCH; bad=1; fi
    printf '%-4s %5s GB: server %s kB, shell formula %s kB, _tn_hw_role at=%s under=%s  %s\n' \
        "$kind" "$gb" "$kb" "$shell_floor" "$at" "$under" "$verdict"
done
exit "$bad"
