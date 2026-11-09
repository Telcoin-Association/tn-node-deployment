#!/usr/bin/env bash
# =============================================================================
# tasks/verify-r2/V7-IMG/t_leak.sh -- does any IMG fixture reach the host's real
# docker binary? A fixture that stubs docker as a shell function does not catch
# `timeout 60 docker run ...` (timeout execs the first docker on PATH), so the
# feature check would run the real one. A sentinel docker is put first on PATH
# before each fixture starts (a fixture's own stand-ins, prepended later, still
# win); it logs its arguments and exits 1. Every fixture must still pass and the
# sentinel log must stay empty.
#
#   bash tasks/verify-r2/V7-IMG/t_leak.sh
#
# Verifier harness (round 2, V7-IMG). bash 3.2 safe.
# =============================================================================
# shellcheck source=tasks/verify-r2/V7-IMG/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
mkdir -p "$T/sentinel"
SLOG="$T/sentinel.log"
: > "$SLOG"
export SLOG
cat > "$T/sentinel/docker" <<'SH'
#!/bin/sh
printf '%s | %s\n' "${V7_FIXTURE:-?}" "$*" >> "$SLOG"
exit 1
SH
chmod 0755 "$T/sentinel/docker"
for f in docker_image network_detect setup_release release_fetch remove source_ref storage_migration update_guard helper; do
    if [[ "$f" == helper ]]; then p="ui/tests/helper_test.sh"; else p="tools/tests/${f}_test.sh"; fi
    rc=0
    ( cd "$V7_REPO" && V7_FIXTURE="$f" PATH="$T/sentinel:$PATH" "${BASH:-bash}" "$p" ) > "$T/$f.log" 2>&1 || rc=$?
    check_rc "fixture $f passes with the sentinel docker first on PATH" 0 "$rc"
    check "fixture $f: no call reached the host's docker" "" "$(grep "^${f} |" "$SLOG" | sort -u)"
done
finish
