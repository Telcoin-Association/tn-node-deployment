#!/usr/bin/env bash
# tools/tests/service_user_test.sh -- tn_service_user_ok, the rule for the
# account the node runs as. Functions shadow id and getent with a fixed set of
# accounts, so the result does not depend on the host. Maintainer tooling (not
# updater-tracked). bash 3.2 safe.
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
zero 0 root'
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
msg="$(tn_service_user_ok op 2>&1 >/dev/null)"
check_has "refusal names the group" "yes" "$(printf '%s' "$msg" | grep -q sudo && echo yes)"
check "nothing on stdout" "" "$(tn_service_user_ok root 2>/dev/null)"
finish
