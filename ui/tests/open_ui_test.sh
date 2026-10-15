#!/usr/bin/env bash
#
# open_ui_test.sh -- tests for open-ui.sh with a fake ssh and browser opener.
#
#   bash ui/tests/open_ui_test.sh
#
# The fake ssh answers the token read with FAKE_TOKEN, fails the tunnel when
# FAKE_TUNNEL=fail (as ExitOnForwardFailure does when port 8080 is taken), and
# reports the control socket closed at once otherwise. The fake opener records
# the URL it was given.
set -u
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPEN_UI="${TEST_DIR}/../../open-ui.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/open_ui_test.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
CHECKS=0; FAILS=0
check() {
    CHECKS=$((CHECKS + 1))
    if [[ "$2" == "$3" ]]; then printf 'ok    %s\n' "$1"; return 0; fi
    FAILS=$((FAILS + 1)); printf 'FAIL  %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"
}
mkdir -p "$T/bin"
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' \
  'echo "ssh $*" >> "$T_DIR/ssh.log"' \
  'case "$*" in' \
  '  *"sudo -n cat /etc/telcoin-ui/token"*) printf "%s\n" "$FAKE_TOKEN"; exit 0 ;;' \
  '  *"-f -N -M"*) [ "${FAKE_TUNNEL:-ok}" = fail ] && exit 255; exit 0 ;;' \
  '  *"-O check"*) exit 1 ;;' \
  'esac' 'exit 0' > "$T/bin/ssh"
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' 'echo "$1" >> "$T_DIR/opened.log"' > "$T/bin/xdg-open"
cp "$T/bin/xdg-open" "$T/bin/open"
chmod +x "$T/bin/ssh" "$T/bin/xdg-open" "$T/bin/open"
export PATH="$T/bin:$PATH" T_DIR="$T"
TOK="$(printf '%064d' 0 | tr 0 a)"

: > "$T/opened.log"
FAKE_TOKEN="$TOK" bash "$OPEN_UI" user@host >/dev/null 2>&1; rc=$?
check "a good run exits 0" "0" "$rc"
check "the browser gets the token in the fragment" "http://localhost:8080/#t=${TOK}" "$(cat "$T/opened.log")"
check "the tunnel asks ssh to fail on a busy port" "1" "$(grep -c 'ExitOnForwardFailure=yes' "$T/ssh.log")"

: > "$T/opened.log"
FAKE_TOKEN="$TOK" FAKE_TUNNEL=fail bash "$OPEN_UI" user@host >/dev/null 2>&1; rc=$?
check "a busy local port makes open-ui.sh fail" "1" "$rc"
check "no browser opens when the tunnel fails" "" "$(cat "$T/opened.log")"

: > "$T/opened.log"
FAKE_TOKEN="not-a-token" bash "$OPEN_UI" user@host </dev/null >/dev/null 2>&1; rc=$?
check "an unreadable token stops before the tunnel" "1" "$rc"
check "no browser opens without a token" "" "$(cat "$T/opened.log")"

bash "$OPEN_UI" -oProxyCommand=x </dev/null >/dev/null 2>&1; rc=$?
check "a target starting with - is refused" "1" "$rc"

printf '\n%s checks, %s failed (bash %s)\n' "$CHECKS" "$FAILS" "$BASH_VERSION"
[[ $FAILS -eq 0 ]]
