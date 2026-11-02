#!/usr/bin/env bash
# tools/tests/service_user_test.sh -- tn_service_user_ok, the rule for the
# account the node runs as. Functions shadow id and getent with a fixed set of
# accounts, so the result does not depend on the host. Then, as root inside a
# container only, create_service_user for a Docker install: the account it
# makes is a system account (no fixed UID), and an account at UID 1101 an older
# setup made passes on a re-run. Maintainer tooling (not updater-tracked).
# bash 3.2 safe.
# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
eval "$(tn_test_source_common)"

# name uid groups (the first group is the primary one)
ACCOUNTS='telcoin 998 telcoin
tn2 997 tn2
alice 1000 alice
op 990 op sudo
logger 991 logger adm
dock 992 dock docker
whl 993 whl wheel
zero 0 root
olddock 1101 olddock
oldsh 1101 oldsh
oldadm 1101 oldadm sudo'
# name shell (getent passwd)
SHELLS='olddock /usr/sbin/nologin
oldsh /bin/bash
oldadm /bin/false'
GROUPS_DB='telcoin 998
tn2 997
rootish 0
alice 1000'

id() {
    local flag="$1" name="${2:-}" line
    line="$(printf '%s\n' "$ACCOUNTS" | awk -v n="$name" '$1 == n')"
    [[ -n "$line" ]] || return 1
    case "$flag" in
        -u)  printf '%s\n' "$(printf '%s' "$line" | awk '{print $2}')" ;;
        -nG) printf '%s\n' "$(printf '%s' "$line" | cut -d' ' -f3-)" ;;
        *)   return 1 ;;
    esac
}
getent() {
    local line
    if [[ "${1:-}" == passwd ]]; then
        line="$(printf '%s\n' "$SHELLS" | awk -v n="${2:-}" '$1 == n')"
        [[ -n "$line" ]] || return 2
        printf '%s:x:1101:1101::/nonexistent:%s\n' "${line%% *}" "${line##* }"
        return 0
    fi
    [[ "${1:-}" == group ]] || return 2
    line="$(printf '%s\n' "$GROUPS_DB" | awk -v n="${2:-}" '$1 == n')"
    [[ -n "$line" ]] || return 2
    printf '%s:x:%s:\n' "${line%% *}" "${line##* }"
}

ok_case() {  # ok_case NAME EXPECTED-RC USER [GROUP]
    local rc=0
    tn_service_user_ok "$3" "${4:-}" 2>/dev/null || rc=$?
    check_rc "$1" "$2" "$rc"
}

ok_case "existing system account passes" 0 telcoin telcoin
ok_case "existing system account, no group" 0 telcoin
ok_case "another system account passes" 0 tn2 tn2
ok_case "an account that does not exist yet passes" 0 newsvc newsvc
ok_case "not-yet-existing user with an existing group" 0 newsvc telcoin
ok_case "root refused" 1 root
ok_case "uid 0 under another name refused" 1 zero
ok_case "telcoin-ui refused" 1 telcoin-ui
ok_case "UID 1000 refused" 1 alice
ok_case "sudo member refused" 1 op
ok_case "adm member refused" 1 logger
ok_case "docker member refused" 1 dock
ok_case "wheel member refused" 1 whl
ok_case "group root refused" 1 telcoin root
ok_case "group telcoin-ui refused" 1 telcoin telcoin-ui
ok_case "group sudo refused" 1 telcoin sudo
ok_case "group docker refused" 1 newsvc docker
ok_case "group with GID 0 refused" 1 telcoin rootish
ok_case "upper case name refused" 1 Telcoin
ok_case "leading digit refused" 1 1telcoin
ok_case "leading dash refused" 1 -telcoin
ok_case "33 characters refused" 1 "$(printf 'a%.0s' $(seq 1 33))"
ok_case "32 characters pass" 0 "$(printf 'a%.0s' $(seq 1 32))"
ok_case "space refused" 1 "tel coin"
ok_case "empty refused" 1 ""
ok_case "bad group name refused" 1 telcoin 'tel;coin'
ok_case "UID 1101 from an older Docker setup, no login shell: passes" 0 olddock olddock
ok_case "UID 1101 with a login shell refused" 1 oldsh
ok_case "UID 1101 in sudo refused" 1 oldadm
msg="$(tn_service_user_ok op 2>&1 >/dev/null)"
check_has "refusal names the group" "yes" "$(printf '%s' "$msg" | grep -q sudo && echo yes)"
check "nothing on stdout" "" "$(tn_service_user_ok root 2>/dev/null)"
unset -f id getent

# --- create_service_user, for real (root in a container only) ---------------------
why=""
if [[ "$(id -u)" != 0 ]]; then
    why="not root"
elif [[ ! -e /.dockerenv ]]; then
    why="creates accounts; runs only inside a container"
else
    for c in useradd userdel groupadd groupdel getent; do
        command -v "$c" >/dev/null 2>&1 || why="${c} absent"
    done
fi
if [[ -n "$why" ]]; then
    skip "create_service_user for a Docker install" "$why"
    finish
fi
MADE_LOG_GROUP=0
getent group "$TN_LOG_GROUP" >/dev/null 2>&1 || MADE_LOG_GROUP=1
cleanup_accounts() {
    userdel tnsvcdock >/dev/null 2>&1
    userdel tnsvcold >/dev/null 2>&1
    groupdel tnsvcdock >/dev/null 2>&1
    groupdel tnsvcold >/dev/null 2>&1
    [[ $MADE_LOG_GROUP == 1 ]] && groupdel "$TN_LOG_GROUP" >/dev/null 2>&1
    tn_test_cleanup
}
trap cleanup_accounts EXIT
rc=0
SERVICE_USER=tnsvcdock SERVICE_GROUP=tnsvcdock INSTALL_METHOD=docker create_service_user >/dev/null 2>&1 || rc=$?
check_rc "fresh Docker install: account created" 0 "$rc"
uid="$(id -u tnsvcdock 2>/dev/null || echo none)"
check "fresh Docker install: a system UID, not 1101" "yes" \
    "$([[ "$uid" =~ ^[0-9]+$ ]] && (( uid >= 1 && uid <= 999 )) && echo yes || echo "no (${uid})")"
ok_case "fresh Docker install: the account passes on a re-run" 0 tnsvcdock tnsvcdock
if getent passwd 1101 >/dev/null 2>&1; then
    skip "re-run with an older setup's UID 1101 account" "UID 1101 already in use here"
else
    groupadd --system tnsvcold
    useradd --uid 1101 --system --no-create-home --shell /bin/false --gid tnsvcold tnsvcold 2>/dev/null
    ok_case "older setup's UID 1101 account: passes on a re-run" 0 tnsvcold tnsvcold
    rc=0
    SERVICE_USER=tnsvcold SERVICE_GROUP=tnsvcold INSTALL_METHOD=docker create_service_user >/dev/null 2>&1 || rc=$?
    check "older setup's UID 1101 account: kept as it is" "0 1101" "$rc $(id -u tnsvcold)"
fi
finish
