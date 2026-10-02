#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
#
# helper_test.sh -- tests for ui/telcoin-ui-helper.sh (helper API 2).
#
#   /bin/bash ui/tests/helper_test.sh     # macOS bash 3.2
#   bash ui/tests/helper_test.sh          # bash 5
#
# No network, no root, no sudo; everything happens in one temp dir. The test
# sources the helper (sourcing must not run a subcommand), points the helper's
# path variables at a fake node tree, replaces the engine scripts with fakes
# that record their argv, and puts recording shims for systemctl, journalctl and
# docker first on PATH. Each call runs the helper's main in a subshell under
# set -euo pipefail, as the executed helper does. Exits 1 on any failure and
# prints expected (<) against actual (>) for each one.
#
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_SRC="${TEST_DIR}/../telcoin-ui-helper.sh"

CHECKS=0
FAILS=0

T="$(mktemp -d "${TMPDIR:-/tmp}/helper_test.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

# check <name> <expected> <actual>
check() {
    CHECKS=$((CHECKS + 1))
    if [[ "$2" == "$3" ]]; then
        printf 'ok    %s\n' "$1"
        return 0
    fi
    FAILS=$((FAILS + 1))
    printf 'FAIL  %s\n      expected (<) vs actual (>):\n' "$1"
    printf '%s\n' "$2" > "$T/expected"
    printf '%s\n' "$3" > "$T/actual"
    diff "$T/expected" "$T/actual" | sed 's/^/      /'
    return 1
}

# check_has <name> <line> <text> -- <text> contains <line> as a whole line.
check_has() {
    CHECKS=$((CHECKS + 1))
    if printf '%s\n' "$3" | grep -qxF -- "$2"; then
        printf 'ok    %s\n' "$1"
        return 0
    fi
    FAILS=$((FAILS + 1))
    printf 'FAIL  %s\n      missing line: %s\n      in:\n' "$1" "$2"
    printf '%s\n' "$3" | sed 's/^/        /'
    return 1
}

# check_lacks <name> <string> <text> -- <string> appears nowhere in <text>.
check_lacks() {
    CHECKS=$((CHECKS + 1))
    if ! printf '%s\n' "$3" | grep -qF -- "$2"; then
        printf 'ok    %s\n' "$1"
        return 0
    fi
    FAILS=$((FAILS + 1))
    printf 'FAIL  %s\n      unexpected: %s\n      in:\n' "$1" "$2"
    printf '%s\n' "$3" | sed 's/^/        /'
    return 1
}

# ---- Sourcing runs nothing ----------------------------------------------------
# If main ran, `helper-version` would print 2, and a call without arguments would
# die with "unknown subcommand".
# shellcheck source=../telcoin-ui-helper.sh
out="$(source "$HELPER_SRC" helper-version 2>&1; echo "rc=$?")"
check "sourcing with arguments runs nothing" "rc=0" "$out"
# shellcheck source=../telcoin-ui-helper.sh
out="$(source "$HELPER_SRC" 2>&1; echo "rc=$?")"
check "sourcing without arguments runs nothing" "rc=0" "$out"

# Top level, not inside a function: bash 3.2 loses some globals otherwise.
# shellcheck source=../telcoin-ui-helper.sh
source "$HELPER_SRC"
# The helper turns on errexit and pipefail. This harness checks every status
# itself; the helper calls get them back inside trace.
set +e +o pipefail

# ---- Fake node tree, engines and shims ------------------------------------------
# The helper reads these paths at call time (they are plain assignments).
# shellcheck disable=SC2034
{
    UNIT_DIR="$T/root/etc/systemd/system"
    ETC_DIR="$T/root/etc/telcoin"
    VAR_DIR="$T/root/var/lib/telcoin"
    LOG_DIR="$T/root/var/log/telcoin"
    OPT_DIR="$T/root/opt/telcoin"
    UPDATE_SCRIPT="$T/engine/update-node.sh"
    CONFIG_SCRIPT="$T/engine/edit-config.sh"
    SETUP_SCRIPT="$T/engine/setup-node.sh"
    CADDY_SCRIPT="$T/engine/install-caddy.sh"
    FIREWALL_SCRIPT="$T/engine/firewall-setup.sh"
    LOGROTATE_CONF="$T/root/etc/logrotate.d/telcoin"
}
mkdir -p "$T/bin" "$T/engine"
: > "$T/all-calls.log"

# make_fake <path> <label> [shell line] -- a command that appends
# "<label> [arg] [arg] ..." to calls.log, then runs the optional line.
make_fake() {
    # shellcheck disable=SC2016
    {
        printf '#!/bin/sh\n'
        printf '{ printf %%s %s; for a in "$@"; do printf " [%%s]" "$a"; done; echo; } >> "%s"\n' "$2" "$T/calls.log"
        printf '%s\n' "${3:-exit 0}"
    } > "$1"
    chmod +x "$1"
}
make_fake "$T/engine/update-node.sh"    update-node
make_fake "$T/engine/edit-config.sh"    edit-config
make_fake "$T/engine/setup-node.sh"     setup-node
make_fake "$T/engine/install-caddy.sh"  install-caddy
make_fake "$T/engine/firewall-setup.sh" firewall-setup
make_fake "$T/bin/systemctl" systemctl
make_fake "$T/bin/docker" docker
# The journal reports two starts of whatever unit it is asked about.
# shellcheck disable=SC2016
make_fake "$T/bin/journalctl" journalctl \
    '[ "$1" = "-u" ] && printf "Started %s.service\nStarted %s.service\n" "$2" "$2"; exit 0'

# The helper edits files with GNU `sed -i`, which takes no suffix argument. BSD
# sed (macOS) reads the next argument as the backup suffix, so give it an empty one.
REAL_SED="$(command -v sed)"
if ! "$REAL_SED" --version >/dev/null 2>&1; then
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nif [ "$1" = "-i" ]; then shift; exec "%s" -i "" "$@"; fi\nexec "%s" "$@"\n' \
        "$REAL_SED" "$REAL_SED" > "$T/bin/sed"
    chmod +x "$T/bin/sed"
fi
PATH="$T/bin:$PATH"

unset TN_SETUP_NETWORK TN_SETUP_INSTALL_METHOD TN_SETUP_PASSPHRASE_METHOD TN_SETUP_ADDRESS \
      TN_SETUP_BUILD_REF TN_SETUP_DOCKER_IMAGE TN_SETUP_EXT_PRIMARY TN_SETUP_EXT_WORKER \
      TN_SETUP_LIS_PRIMARY TN_SETUP_LIS_WORKER TN_SETUP_PUBLIC_IP TN_SETUP_RPC_DOMAIN \
      TN_SETUP_RPC_PUBLIC TN_SETUP_INSTANCE TN_SETUP_SERVICE_USER TN_SETUP_SERVICE_GROUP \
      TN_SETUP_ADVERTISED_NAME TN_SETUP_DATA_DIR TN_CADDY_PASSWORD TN_BLS_PASSPHRASE

# add_unit <unit> [traced] -- a unit file, the wrapper its ExecStart names (with
# tracing flags when "traced"), and the log its StandardOutput appends to.
add_unit() {
    local u="$1" flags=""
    if [[ "${2:-}" == traced ]]; then
        flags=" --tracing-url http://127.0.0.1:4317 --node-name telcoin-observer"
    fi
    mkdir -p "$UNIT_DIR" "$OPT_DIR" "$LOG_DIR"
    printf '[Service]\nExecStart=%s\nStandardOutput=append:%s\n' \
        "${OPT_DIR}/start-${u}.sh" "${LOG_DIR}/${u}.log" > "${UNIT_DIR}/${u}.service"
    printf '#!/bin/bash\nexec /opt/telcoin/telcoin-network node%s --datadir /var/lib/telcoin\n' \
        "$flags" > "${OPT_DIR}/start-${u}.sh"
    printf 'a log line\n' > "${LOG_DIR}/${u}.log"
}

# add_meta <role|-> [data-dir] -- a .node-meta: the unified one for "-", else the
# one in the legacy role dir, with DATA_DIR when given.
add_meta() {
    local dir="$ETC_DIR"
    if [[ "$1" != "-" ]]; then
        dir="${ETC_DIR}/$1"
    fi
    mkdir -p "$dir"
    printf 'NETWORK=testnet\nREGION=us-east1\n' > "${dir}/.node-meta"
    if [[ -n "${2:-}" ]]; then
        printf 'DATA_DIR=%s\n' "$2" >> "${dir}/.node-meta"
    fi
}

# fixture <layout> -- rebuild the fake node tree from scratch.
fixture() {
    rm -rf "$T/root"
    mkdir -p "$ETC_DIR" "$VAR_DIR/observer" "$VAR_DIR/validator" "$T/root/data/custom" \
        "${LOGROTATE_CONF%/*}"
    printf 'built_at=2026-09-30T12:00:00Z\n' > "${ETC_DIR}/build-info"
    case "$1" in
        unified)        add_unit telcoin; add_meta - ;;
        unified-traced) add_unit telcoin traced; add_meta - ;;
        observer)       add_unit telcoin-observer; add_meta observer ;;
        validator)      add_unit telcoin-validator; add_meta validator ;;
        both)           add_unit telcoin-observer; add_unit telcoin-validator
                        add_meta observer; add_meta validator ;;
        mixed)          add_unit telcoin-observer; add_meta - "$T/root/data/custom" ;;
        mixed-meta)     add_unit telcoin; add_meta observer ;;
        none)           ;;
        *)              echo "unknown fixture: $1" >&2; exit 2 ;;
    esac
}

# trace <args...> -- run `telcoin-ui-helper <args>` and print what it did: the
# exit status, its output, the recorded engine and shim calls, and every file in
# the fake node tree (wrapper backups left out; their names carry the time).
trace() {
    local out rc f
    : > "$T/calls.log"
    out="$( (set -euo pipefail; main "$@") 2>&1 )"
    rc=$?
    cat "$T/calls.log" >> "$T/all-calls.log"
    printf 'rc=%s\n%s\n--- calls\n' "$rc" "$out"
    cat "$T/calls.log"
    printf -- '--- files\n'
    find "$T/root" -type f ! -name '*.bak.*' | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s:\n' "${f#"$T/root"}"
        cat "$f"
    done
}

# refused <name> <args...> -- the call exits non-zero and runs no engine or shim.
refused() {
    local name="$1" t
    shift
    t="$(trace "$@")"
    CHECKS=$((CHECKS + 1))
    if [[ "$(printf '%s\n' "$t" | head -1)" != "rc=0" && ! -s "$T/calls.log" ]]; then
        printf 'ok    %s\n' "$name"
        return 0
    fi
    FAILS=$((FAILS + 1))
    printf 'FAIL  %s\n      expected a refusal with no calls, got:\n' "$name"
    printf '%s\n' "$t" | sed 's/^/        /'
    return 1
}

# same_with_tokens <layout> <subcommand> [args...] -- run the call on a fresh
# tree, then again with observer and with validator in front of the arguments
# (the form ui/server.py before 1.9.0 sends), and check the three traces are
# identical. Leaves the token-free trace in BASE.
BASE=""
same_with_tokens() {
    local layout="$1" sub="$2" tok other
    shift 2
    fixture "$layout"
    BASE="$(trace "$sub" "$@")"
    for tok in observer validator; do
        fixture "$layout"
        other="$(trace "$sub" "$tok" "$@")"
        check "$sub: '$tok' in front changes nothing ($layout)" "$BASE" "$other"
    done
}

# resolve -- what the helper resolves on the current tree: unit|meta|data dir.
resolve() {
    local u m d
    u="$(node_service)"
    m="$(node_meta_path)"
    d="$(node_data_dir)"
    printf '%s|%s|%s' "$u" "${m#"$T/root"}" "${d#"$T/root"}"
}

# ---- helper-version --------------------------------------------------------------
fixture none
check "helper-version prints 2" "2" "$( (set -euo pipefail; main helper-version) 2>&1 )"
refused "an unknown subcommand is refused" bogus-subcommand

# ---- The 14 node subcommands: the old role argument changes nothing ------------
same_with_tokens unified tracing-enable
check_has "tracing-enable restarts the resolved unit" "systemctl [restart] [--no-block] [telcoin]" "$BASE"
check_has "tracing-enable writes --node-name telcoin" \
    "exec /opt/telcoin/telcoin-network node --tracing-url http://127.0.0.1:4317 --node-name telcoin --datadir /var/lib/telcoin" "$BASE"

same_with_tokens unified-traced tracing-disable
check_has "tracing-disable strips the tracing flags" \
    "exec /opt/telcoin/telcoin-network node --datadir /var/lib/telcoin" "$BASE"
check_has "tracing-disable restarts the resolved unit" "systemctl [restart] [--no-block] [telcoin]" "$BASE"

same_with_tokens unified update-check
check_has "update-check argv" "update-node [--json] [--check]" "$BASE"

same_with_tokens unified update-prepare v0.15.0-adiri
check_has "update-prepare argv" "update-node [--json] [--prepare] [--ref] [v0.15.0-adiri]" "$BASE"

same_with_tokens unified update-apply
check_has "update-apply argv" "update-node [--json] [--apply] [--yes]" "$BASE"

same_with_tokens unified update-discard
check_has "update-discard argv" "update-node [--json] [--discard]" "$BASE"

same_with_tokens unified restart-count
check_has "restart-count asks the journal about the resolved unit" \
    "journalctl [-u] [telcoin] [--since] [2026-09-30 12:00:00] [--no-pager]" "$BASE"
check_has "restart-count prints the count" "2" "$BASE"

same_with_tokens unified log-clear
check_has "log-clear prints ok" "ok" "$BASE"
check "log-clear empties the unit's log" "0" "$(wc -c < "${LOG_DIR}/telcoin.log" | tr -d ' ')"

same_with_tokens unified config-set verbosity -vvv
check_has "config-set argv" "edit-config [--json] [--set] [verbosity=-vvv]" "$BASE"

same_with_tokens unified set-hostname mynode
check_has "set-hostname writes network-config" 'hostname: "mynode"' "$BASE"
check_has "set-hostname records the name in .node-meta" "ADVERTISED_NODE_NAME=mynode" "$BASE"
check_has "set-hostname restarts the resolved unit" "systemctl [restart] [--no-block] [telcoin]" "$BASE"

same_with_tokens unified addons-status
check_has "addons-status reads the resolved meta" \
    '{"network":"testnet","region":"us-east1","health":{"enabled":false,"responding":false,"port":43174,"extra_src":""},"logging":{"enabled":false,"running":false},"vpn":{"state":"false","wg_up":false,"handshake":false,"overlay_ip":"","pubkey":""}}' "$BASE"

same_with_tokens unified meta-cat
check_has "meta-cat prints the resolved meta" "REGION=us-east1" "$BASE"

same_with_tokens unified setup-keygen
check_has "setup-keygen calls setup-node.sh directly" \
    "setup-node [--json] [--phase=keygen] [--network] [testnet] [--passphrase-method] [loadcredential]" "$BASE"

same_with_tokens unified setup-finalize
check_has "setup-finalize calls setup-node.sh directly" \
    "setup-node [--json] [--phase=finalize] [--network] [testnet] [--passphrase-method] [loadcredential]" "$BASE"

# The token never steers resolution on a legacy box either.
same_with_tokens observer tracing-enable
check_has "observer-only box: tracing-enable restarts telcoin-observer" \
    "systemctl [restart] [--no-block] [telcoin-observer]" "$BASE"
same_with_tokens both set-hostname node-b
check_has "both legacy units: set-hostname restarts telcoin-validator" \
    "systemctl [restart] [--no-block] [telcoin-validator]" "$BASE"
check_has "both legacy units: the name lands in the validator data dir" \
    "/var/lib/telcoin/validator/network-config:" "$BASE"

# ---- Only a surplus leading role argument is dropped -----------------------------
fixture unified
t="$(trace set-hostname validator)"
check_has "set-hostname validator keeps its argument" 'hostname: "validator"' "$t"
check_has "set-hostname validator succeeds" "rc=0" "$t"
fixture unified
t="$(trace update-prepare observer)"
check_has "update-prepare with one argument takes it as the ref" \
    "update-node [--json] [--prepare] [--ref] [observer]" "$t"
fixture unified
t="$(trace docker-status observer)"
check_has "docker-status observer keeps its argument" "docker [inspect] [observer]" "$t"
fixture unified
t="$(trace tracing-enable observer extra)"
check_has "a surplus argument after the token is refused" "too many arguments for tracing-enable: extra" "$t"
refused "tracing-enable observer extra runs nothing" tracing-enable observer extra
refused "tracing-enable with a non-role argument is refused" tracing-enable foo
refused "config-set with a third argument is refused" config-set verbosity -vvv extra
refused "config-set with a token and a third argument is refused" config-set observer verbosity -vvv extra

# ---- Node resolution matrix ------------------------------------------------------
fixture unified
check "resolve: unified only" "telcoin|/etc/telcoin/.node-meta|/var/lib/telcoin" "$(resolve)"
fixture observer
check "resolve: observer only" \
    "telcoin-observer|/etc/telcoin/observer/.node-meta|/var/lib/telcoin/observer" "$(resolve)"
fixture validator
check "resolve: validator only" \
    "telcoin-validator|/etc/telcoin/validator/.node-meta|/var/lib/telcoin/validator" "$(resolve)"
fixture both
check "resolve: both legacy units -> validator" \
    "telcoin-validator|/etc/telcoin/validator/.node-meta|/var/lib/telcoin/validator" "$(resolve)"
fixture mixed
check "resolve: legacy unit with the unified meta and its DATA_DIR" \
    "telcoin-observer|/etc/telcoin/.node-meta|/data/custom" "$(resolve)"
fixture mixed-meta
check "resolve: unified unit with a legacy meta" \
    "telcoin|/etc/telcoin/observer/.node-meta|/var/lib/telcoin/observer" "$(resolve)"
fixture none
check "resolve: nothing installed" "telcoin|/etc/telcoin/.node-meta|/var/lib/telcoin" "$(resolve)"

# The subcommands act on what resolve reports: the unit restarted and the
# wrapper edited are the resolved unit's.
for c in "unified telcoin" "observer telcoin-observer" "validator telcoin-validator" \
         "both telcoin-validator" "mixed telcoin-observer" "mixed-meta telcoin"; do
    layout="${c% *}"
    unit="${c#* }"
    fixture "$layout"
    t="$(trace tracing-enable)"
    check_has "tracing-enable on '$layout' restarts $unit" "systemctl [restart] [--no-block] [$unit]" "$t"
    check_has "tracing-enable on '$layout' edits the $unit wrapper" \
        "exec /opt/telcoin/telcoin-network node --tracing-url http://127.0.0.1:4317 --node-name telcoin --datadir /var/lib/telcoin" \
        "$(cat "${OPT_DIR}/start-${unit}.sh")"
done
fixture both
t="$(trace tracing-enable)"
check_lacks "both legacy units: the observer wrapper is left alone" "--tracing-url" \
    "$(cat "${OPT_DIR}/start-telcoin-observer.sh")"
fixture mixed
t="$(trace set-hostname node-m)"
check_has "mixed: set-hostname writes to the DATA_DIR of the unified meta" "/data/custom/network-config:" "$t"
fixture unified
printf 'DATA_DIR=%s\n' "$T/root/data/missing" >> "${ETC_DIR}/.node-meta"
t="$(trace set-hostname node-x)"
check_has "a recorded DATA_DIR that does not exist is reported, not replaced" \
    "data dir not found: $T/root/data/missing" "$t"

# ---- Setup: TN_SETUP_RPC_DOMAIN, never --rpc-public -----------------------------
# Each export below lasts only for its own $(...) subshell.
fixture unified
t="$(export TN_SETUP_RPC_DOMAIN=x.example.org; trace setup-keygen)"
check_has "TN_SETUP_RPC_DOMAIN becomes --rpc-domain" \
    "setup-node [--json] [--phase=keygen] [--network] [testnet] [--passphrase-method] [loadcredential] [--rpc-domain] [x.example.org]" "$t"
t="$(export TN_SETUP_RPC_DOMAIN=x.example.org TN_SETUP_RPC_PUBLIC=true; trace setup-finalize validator)"
check_has "token form with TN_SETUP_RPC_DOMAIN" \
    "setup-node [--json] [--phase=finalize] [--network] [testnet] [--passphrase-method] [loadcredential] [--rpc-domain] [x.example.org]" "$t"
t="$(export TN_SETUP_RPC_PUBLIC=true TN_SETUP_INSTANCE=3; trace setup-finalize)"
check_has "TN_SETUP_RPC_PUBLIC and TN_SETUP_INSTANCE from an old server are ignored" \
    "setup-node [--json] [--phase=finalize] [--network] [testnet] [--passphrase-method] [loadcredential]" "$t"
t="$(export TN_SETUP_RPC_DOMAIN=localhost; trace setup-keygen)"
check_has "an invalid TN_SETUP_RPC_DOMAIN is refused" "invalid rpc domain: localhost" "$t"
setup_calls="$(grep '^setup-node' "$T/all-calls.log")"
# 3 + 3 from the two token comparisons above, then the three accepted calls here.
check "setup-node.sh ran for every accepted setup call" "9" "$(printf '%s\n' "$setup_calls" | grep -c .)"
check_lacks "--rpc-public never appears in a setup argv" "--rpc-public" "$setup_calls"

# ---- Strict hostname rule ---------------------------------------------------------
l61="$(printf '%061d' 0 | tr 0 a)"
l62="$(printf '%062d' 0 | tr 0 a)"
l63="$(printf '%063d' 0 | tr 0 a)"
l64="$(printf '%064d' 0 | tr 0 a)"
h253="${l63}.${l63}.${l63}.${l61}"
h254="${l63}.${l63}.${l63}.${l62}"
check "the 253-character name is 253 long" "253" "${#h253}"
check "the 254-character name is 254 long" "254" "${#h254}"

# label <host> -- a short name for a host in check names.
label() {
    if [[ ${#1} -gt 40 ]]; then
        printf '%s... (%s chars)' "${1:0:12}" "${#1}"
    else
        printf "'%s'" "$1"
    fi
}

bad_hosts=( localhost 1.2.3.4 a..b -x.example "$h254" "${l64}.example.org" ""
            x.example.org. under_score.example.org x-.example.org https://x.example.org
            x.example.org:443 10.0.0.1 )
good_hosts=( node7.adiri.telcoin.network a.b "${l63}.example.org" "$h253" Node7.Example.ORG
             123.example.org x-1.example.org )

for h in "${bad_hosts[@]}"; do
    r=accepted
    valid_hostname "$h" || r=refused
    check "valid_hostname refuses $(label "$h")" refused "$r"
done
for h in "${good_hosts[@]}"; do
    r=refused
    valid_hostname "$h" && r=accepted
    check "valid_hostname accepts $(label "$h")" accepted "$r"
done

export TN_CADDY_PASSWORD=secret-pass
fixture none
for h in localhost 1.2.3.4 a..b -x.example "$h254" "${l64}.example.org"; do
    refused "caddy-dns-check refuses $(label "$h")" caddy-dns-check "$h"
    refused "rpc-dns-check refuses $(label "$h")" rpc-dns-check "$h"
    refused "caddy-enable refuses $(label "$h")" caddy-enable "$h" admin
    refused "rpc-enable refuses $(label "$h")" rpc-enable "$h"
done
for h in node7.adiri.telcoin.network "$h253"; do
    t="$(trace caddy-dns-check "$h")"
    check_has "caddy-dns-check accepts $(label "$h")" \
        "install-caddy [--json] [--phase=check-dns] [--domain] [$h]" "$t"
    t="$(trace rpc-dns-check "$h" 203.0.113.7)"
    check_has "rpc-dns-check accepts $(label "$h")" \
        "install-caddy [--json] [--phase=rpc-check-dns] [--rpc-domain] [$h] [--public-ip] [203.0.113.7]" "$t"
    t="$(trace caddy-enable "$h" admin)"
    check_has "caddy-enable accepts $(label "$h")" \
        "install-caddy [--json] [--phase=enable] [--domain] [$h] [--username] [admin]" "$t"
done
unset TN_CADDY_PASSWORD

# ---- rpc-enable argv shapes ---------------------------------------------------------
fixture none
t="$(trace rpc-enable node7.example.org)"
check_has "rpc-enable <host>" \
    "install-caddy [--json] [--phase=rpc-enable] [--rpc-domain] [node7.example.org]" "$t"
t="$(trace rpc-enable node7.example.org 203.0.113.7)"
check_has "rpc-enable <host> <ip>" \
    "install-caddy [--json] [--phase=rpc-enable] [--rpc-domain] [node7.example.org] [--public-ip] [203.0.113.7]" "$t"
t="$(trace rpc-enable node7.example.org - dashboard.node7.example.org)"
check_has "rpc-enable <host> - <dash>" \
    "install-caddy [--json] [--phase=rpc-enable] [--rpc-domain] [node7.example.org] [--move-dashboard-to] [dashboard.node7.example.org]" "$t"
t="$(trace rpc-enable node7.example.org 203.0.113.7 dashboard.node7.example.org)"
check_has "rpc-enable <host> <ip> <dash>" \
    "install-caddy [--json] [--phase=rpc-enable] [--rpc-domain] [node7.example.org] [--public-ip] [203.0.113.7] [--move-dashboard-to] [dashboard.node7.example.org]" "$t"
t="$(trace rpc-enable node7.example.org -)"
check_has "rpc-enable <host> - (no dash) is the plain call" \
    "install-caddy [--json] [--phase=rpc-enable] [--rpc-domain] [node7.example.org]" "$t"
refused "rpc-enable refuses a dashboard host equal to the RPC host" \
    rpc-enable node7.example.org - node7.example.org
refused "rpc-enable compares the two hosts without case" \
    rpc-enable node7.example.org 203.0.113.7 NODE7.Example.org
refused "rpc-enable refuses an invalid dashboard host" rpc-enable node7.example.org - localhost
refused "rpc-enable refuses an invalid inbound IP" rpc-enable node7.example.org not-an-ip
refused "rpc-enable refuses a fourth argument" rpc-enable node7.example.org - dash.example.org extra

# ---- config-set fields (edit-config 1.3.0) ------------------------------------------
# The same rows as ConfigSetTest in ui/test_server_contract.py. An accepted value
# reaches edit-config.sh as field=value; a refused one runs nothing.
fixture unified
for fv in "primary_listener=/ip4/0.0.0.0/udp/49590/quic-v1" \
          "worker_listener=/ip6/::/udp/49594/quic-v1" \
          "metrics=127.0.0.1:9101" "metrics=off" "verbosity=-vvvvv" \
          "docker_image=us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.15.0-adiri" \
          "bootstrap_peers=none" "bootstrap_peers=/home/ubuntu/peers.yaml" \
          "state_export=off" "state_export=unlimited" "state_export=1" "state_export=999999" \
          "allow_private_forward_targets=true" "allow_private_forward_targets=false"; do
    t="$(trace config-set "${fv%%=*}" "${fv#*=}")"
    check_has "config-set accepts ${fv}" "edit-config [--json] [--set] [${fv}]" "$t"
done
for fv in "metrics=on" "metrics=OFF" "metrics=127.0.0.1" "verbosity=-vvvvvv" "docker_image=adiri" \
          "bootstrap_peers=peers.yaml" "bootstrap_peers=None" "bootstrap_peers=/tmp/peers file.yaml" \
          'bootstrap_peers=/tmp/$(id).yaml' "bootstrap_peers=" \
          "state_export=0" "state_export=01" "state_export=1000000" "state_export=-1" \
          "state_export=Unlimited" \
          "allow_private_forward_targets=yes" "allow_private_forward_targets=1" \
          "allow_private_forward_targets=TRUE" "not_a_field=1"; do
    refused "config-set refuses ${fv}" config-set "${fv%%=*}" "${fv#*=}"
done
same_with_tokens unified config-set state_export 5
check_has "config-set state_export 5 argv" "edit-config [--json] [--set] [state_export=5]" "$BASE"

# ---- Other subcommands keep working -------------------------------------------------
fixture unified
t="$(trace firewall-port 49590/udp on)"
check_has "firewall-port argv" "firewall-setup [--json] [--port] [49590/udp] [on]" "$t"
refused "firewall-port refuses a port outside the list" firewall-port 22/tcp on
t="$(trace firewall-status)"
check_has "firewall-status argv" "firewall-setup [--json] [--status]" "$t"
t="$(trace caddy-status)"
check_has "caddy-status argv" "install-caddy [--json] [--phase=status]" "$t"
t="$(trace rpc-disable)"
check_has "rpc-disable argv" "install-caddy [--json] [--phase=rpc-disable]" "$t"
t="$(trace docker-logs tn-node 50)"
check_has "docker-logs argv" "docker [logs] [--tail] [50] [tn-node]" "$t"
t="$(trace set-logrotate 2G)"
check_has "set-logrotate writes the size" "    size 2G" "$t"
printf 'old\n' > "${LOG_DIR}/telcoin.log.1"
t="$(trace clear-rotated)"
check_has "clear-rotated removes rotated logs only" "removed 1" "$t"
check_has "clear-rotated leaves the live log" "/var/log/telcoin/telcoin.log:" "$t"

# ---- No engine call carries a role flag ---------------------------------------------
all_calls="$(cat "$T/all-calls.log")"
check_lacks "no recorded call carries --observer" "[--observer]" "$all_calls"
check_lacks "no recorded call carries --validator" "[--validator]" "$all_calls"

printf '\n%s checks, %s failed (bash %s)\n' "$CHECKS" "$FAILS" "$BASH_VERSION"
if [[ $FAILS -ne 0 ]]; then
    exit 1
fi
