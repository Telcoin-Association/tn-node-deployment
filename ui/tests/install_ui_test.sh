#!/usr/bin/env bash
#
# install_ui_test.sh -- the checks install-ui.sh makes before it reads anything
# from its checkout.
#
#   bash ui/tests/install_ui_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash ui/tests/install_ui_test.sh
#
# Each case copies install-ui.sh into a throwaway checkout whose lib/common.sh
# only records that it ran and exits 42. A refused run exits 1 and leaves no
# record; a run that passes every check sources the library, which stops the
# installer with 42 before it changes anything. The ownership and mode cases
# need root (the bash:3.2 container runs as root); as another user only the
# root check is tested.
set -u
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${TEST_DIR}/../install-ui.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/install_ui_test.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
CHECKS=0; FAILS=0
check() {
    CHECKS=$((CHECKS + 1))
    if [[ "$2" == "$3" ]]; then printf 'ok    %s\n' "$1"; return 0; fi
    FAILS=$((FAILS + 1)); printf 'FAIL  %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"
    sed 's/^/      | /' "$T/out"
}

# checkout <name> -- a fresh checkout at $T/<name>, nothing writable by group
# or others.
checkout() {
    local co="$T/$1"
    rm -rf "$co"
    mkdir -p "$co/ui" "$co/lib"
    cp "$INSTALLER" "$co/ui/install-ui.sh"
    printf 'touch "%s"\nexit 42\n' "$co/ran" > "$co/lib/common.sh"
    chmod -R go-w "$co"
}

# run_case <name> <rc> <yes|no> <checkout> [VAR=value...] -- run the installer
# from the checkout with only the given sudo variables, and check its exit
# status and whether the checkout's library ran.
run_case() {
    local name="$1" want_rc="$2" want_ran="$3" co="$T/$4" rc ran=no
    shift 4
    rm -f "$co/ran"
    env -u SUDO_USER -u SUDO_UID -u SUDO_GID "$@" \
        bash "$co/ui/install-ui.sh" --update </dev/null >"$T/out" 2>&1
    rc=$?
    [[ -e "$co/ran" ]] && ran=yes
    check "$name" "rc=${want_rc} library-ran=${want_ran}" "rc=${rc} library-ran=${ran}"
}

if [[ $EUID -ne 0 ]]; then
    checkout plain
    run_case "not root: refused before the library is read" 1 no plain
    printf 'SKIP  ownership and mode cases (need root)\n'
else
    checkout plain
    run_case "a root-owned checkout reaches the library" 42 yes plain
    run_case "sudo from the UI account: refused before the library is read" 1 no plain SUDO_USER=telcoin-ui

    checkout ow; chmod o+w "$T/ow/lib/common.sh"
    run_case "a world-writable library: refused, not read" 1 no ow
    checkout owdir; chmod o+w "$T/owdir/lib"
    run_case "a world-writable lib/ directory: refused, library not read" 1 no owdir
    checkout gw; chgrp 65534 "$T/gw/lib/common.sh"; chmod g+w "$T/gw/lib/common.sh"
    run_case "a library writable by a foreign group: refused, not read" 1 no gw
    checkout gwroot; chmod g+w "$T/gwroot/lib/common.sh"
    run_case "a library writable by root's group is accepted" 42 yes gwroot
    checkout foreign; chown 65534 "$T/foreign/lib/common.sh"
    run_case "a library owned by another account: refused, not read" 1 no foreign
    checkout link; mv "$T/link/lib/common.sh" "$T/link-common.sh"
    ln -s "$T/link-common.sh" "$T/link/lib/common.sh"
    run_case "a symlinked library: refused, not read" 1 no link

    checkout op; chown -R 4242:4242 "$T/op"
    run_case "a checkout owned by the operator who ran sudo is accepted" 42 yes op \
        SUDO_USER=op SUDO_UID=4242 SUDO_GID=4242
    chmod g+w "$T/op/lib/common.sh"
    run_case "group write for the operator's own group is accepted" 42 yes op \
        SUDO_USER=op SUDO_UID=4242 SUDO_GID=4242
    run_case "the same checkout without that sudo: refused, not read" 1 no op
    checkout op2; chown -R 4242:4242 "$T/op2"; chown 4343 "$T/op2/lib/common.sh"
    run_case "an operator checkout with a file of another account: refused" 1 no op2 \
        SUDO_USER=op SUDO_UID=4242 SUDO_GID=4242
    run_case "non-numeric sudo ids: refused, library not read" 1 no plain \
        SUDO_USER=op 'SUDO_UID=0 -o -user 1' SUDO_GID=0
fi

printf '\n%s checks, %s failed (bash %s)\n' "$CHECKS" "$FAILS" "$BASH_VERSION"
[[ $FAILS -eq 0 ]]
