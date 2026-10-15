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
    LIBEXEC_DIR="$T/root/usr/local/libexec/telcoin"
    # No shared library: every guarded library call takes its fallback. The
    # library cases below point HELPER_LIB at the checkout's lib/common.sh.
    HELPER_LIB="$T/nolib/common.sh"
    AUDIT_LOG="$T/audit/audit.log"
    AUDIT_LOGGER=""
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
# docker ps lists two Telcoin Network containers, tn-node and observer.
# shellcheck disable=SC2016
make_fake "$T/bin/docker" docker \
    '[ "$1" = ps ] && printf "tn-node\tus-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.16.0-adiri\nobserver\tus-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.16.0-adiri\nother\tbusybox:latest\n"; exit 0'
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

# The fake data and log dirs belong to the test user; the helper takes them for
# the node's service account "svc". Running a command as that account is
# recorded as "run_as [svc] [cmd] ..." and then runs as the test user.
path_owner() { echo "svc:svc"; }
_run_as() {
    local u="$1"
    shift 2
    { printf 'run_as [%s]' "$u"; for a in "$@"; do printf ' [%s]' "$a"; done; echo; } >> "$T/calls.log"
    "$@"
}

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
check_has "update-prepare with one argument takes it as the ref (and refuses it)" \
    "ref must be a release tag of testnet (vX.Y.Z-adiri); branches and commit ids are refused: observer" "$t"
fixture unified
t="$(trace docker-status observer)"
check_has "docker-status observer keeps its argument" \
    "docker [inspect] [--format] [${DOCKER_STATUS_FORMAT}] [observer]" "$t"
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

# ---- Setup: refusals, settings and the passphrase on stdin ------------------------
# Each export below lasts only for its own $(...) subshell. A fresh box (no unit,
# no .node-meta) unless a case says otherwise. The fake setup-node.sh has no
# --passphrase-stdin, so it gets the transitional environment form; the second
# fake has the flag and records the line it reads on stdin.
make_fake "$T/engine/setup-node-stdin.sh" setup-node-stdin \
    '# --passphrase-stdin
IFS= read -r p; printf "stdin [%s]\n" "$p" >> "'"$T"'/calls.log"; exit 0'
export TN_SETUP_NETWORK=testnet
FIN_ARGS="[--listener-primary] [/ip4/10.0.0.5/udp/49590/quic-v1] [--listener-worker] [/ip4/10.0.0.5/udp/49594/quic-v1]"
fixture none
t="$(printf 'a good passphrase\n' | trace setup-keygen)"
check_has "setup-keygen calls setup-node.sh directly" \
    "setup-node [--json] [--phase=keygen] [--network] [testnet]" "$t"
check_lacks "setup-keygen never puts the passphrase in an argument" "a good passphrase" "$t"
t="$(printf 'a good passphrase\n' | trace setup-keygen validator)"
check_has "setup-keygen token form" "setup-node [--json] [--phase=keygen] [--network] [testnet]" "$t"
t="$(SETUP_SCRIPT="$T/engine/setup-node-stdin.sh"; printf 'a good passphrase\n' | trace setup-keygen)"
check_has "setup-keygen sends --passphrase-stdin when the engine has it" \
    "setup-node-stdin [--json] [--phase=keygen] [--network] [testnet] [--passphrase-stdin]" "$t"
check_has "the engine reads the passphrase on its stdin" "stdin [a good passphrase]" "$t"
t="$(export TN_SETUP_LIS_PRIMARY=/ip4/10.0.0.5/udp/49590/quic-v1 TN_SETUP_LIS_WORKER=/ip4/10.0.0.5/udp/49594/quic-v1; trace setup-finalize </dev/null)"
check_has "setup-finalize calls setup-node.sh directly" \
    "setup-node [--json] [--phase=finalize] [--network] [testnet] ${FIN_ARGS}" "$t"
t="$(export TN_SETUP_RPC_DOMAIN=x.example.org; printf 'a good passphrase\n' | trace setup-keygen)"
check_has "TN_SETUP_RPC_DOMAIN becomes --rpc-domain" \
    "setup-node [--json] [--phase=keygen] [--network] [testnet] [--rpc-domain] [x.example.org]" "$t"
t="$(export TN_SETUP_RPC_DOMAIN=x.example.org TN_SETUP_RPC_PUBLIC=true TN_SETUP_LIS_PRIMARY=/ip4/10.0.0.5/udp/49590/quic-v1 TN_SETUP_LIS_WORKER=/ip4/10.0.0.5/udp/49594/quic-v1; trace setup-finalize validator </dev/null)"
check_has "token form with TN_SETUP_RPC_DOMAIN" \
    "setup-node [--json] [--phase=finalize] [--network] [testnet] ${FIN_ARGS} [--rpc-domain] [x.example.org]" "$t"
t="$(export TN_SETUP_RPC_PUBLIC=true TN_SETUP_INSTANCE=3 TN_SETUP_PASSPHRASE_METHOD=tpm TN_SETUP_LIS_PRIMARY=/ip4/10.0.0.5/udp/49590/quic-v1 TN_SETUP_LIS_WORKER=/ip4/10.0.0.5/udp/49594/quic-v1; trace setup-finalize </dev/null)"
check_has "TN_SETUP_RPC_PUBLIC, TN_SETUP_INSTANCE, TN_SETUP_PASSPHRASE_METHOD from an old server are ignored" \
    "setup-node [--json] [--phase=finalize] [--network] [testnet] ${FIN_ARGS}" "$t"
t="$(export TN_SETUP_RPC_DOMAIN=localhost; printf 'a good passphrase\n' | trace setup-keygen)"
check_has "an invalid TN_SETUP_RPC_DOMAIN is refused" "invalid rpc domain: localhost" "$t"
setup_calls="$(grep '^setup-node' "$T/all-calls.log")"
check "setup-node.sh ran for every accepted setup call" "7" "$(printf '%s\n' "$setup_calls" | grep -c .)"
check_lacks "--rpc-public never appears in a setup argv" "--rpc-public" "$setup_calls"
check_lacks "--passphrase-method never appears in a setup argv" "--passphrase-method" "$setup_calls"

# Refusals, each before setup-node.sh runs.
refused_in() { local name="$1"; shift; refused "$name" "$@" < "$T/pass-in"; }
printf 'a good passphrase\n' > "$T/pass-in"
fixture none
unset TN_SETUP_NETWORK; refused_in "setup-keygen without a network" setup-keygen; export TN_SETUP_NETWORK=testnet
export TN_SETUP_NETWORK=devnet; refused_in "setup-keygen on devnet" setup-keygen; export TN_SETUP_NETWORK=testnet
export TN_SETUP_SERVICE_USER=root; refused_in "setup-keygen as root" setup-keygen; unset TN_SETUP_SERVICE_USER
export TN_SETUP_SERVICE_USER=telcoin-ui; refused_in "setup-keygen as telcoin-ui" setup-keygen; unset TN_SETUP_SERVICE_USER
export TN_SETUP_SERVICE_GROUP=root; refused_in "setup-keygen with group root" setup-keygen; unset TN_SETUP_SERVICE_GROUP
export TN_SETUP_SERVICE_USER=Bad; refused_in "setup-keygen with an upper-case user" setup-keygen; unset TN_SETUP_SERVICE_USER
export TN_SETUP_DATA_DIR=/usr/local/sbin; refused_in "setup-keygen data dir /usr/local/sbin" setup-keygen; unset TN_SETUP_DATA_DIR
export TN_SETUP_DATA_DIR=/etc/telcoin; refused_in "setup-keygen data dir /etc/telcoin" setup-keygen; unset TN_SETUP_DATA_DIR
export TN_SETUP_DATA_DIR=/var/lib/telcoin/../x; refused_in "setup-keygen data dir with .." setup-keygen; unset TN_SETUP_DATA_DIR
export TN_SETUP_INSTALL_METHOD=source TN_SETUP_BUILD_REF=main; refused_in "setup-keygen build ref main" setup-keygen; unset TN_SETUP_INSTALL_METHOD; unset TN_SETUP_BUILD_REF
export TN_SETUP_INSTALL_METHOD=source TN_SETUP_BUILD_REF=v0.16.0; refused_in "setup-keygen mainnet tag on testnet" setup-keygen; unset TN_SETUP_INSTALL_METHOD; unset TN_SETUP_BUILD_REF
export TN_SETUP_INSTALL_METHOD=docker TN_SETUP_DOCKER_IMAGE=docker.io/library/busybox:latest; refused_in "setup-keygen foreign image" setup-keygen; unset TN_SETUP_INSTALL_METHOD; unset TN_SETUP_DOCKER_IMAGE
export TN_SETUP_INSTALL_METHOD=docker TN_SETUP_DOCKER_IMAGE=us-docker.pkg.dev/telcoin-network/tn-public/adiri:latest; refused_in "setup-keygen image tag latest" setup-keygen; unset TN_SETUP_INSTALL_METHOD; unset TN_SETUP_DOCKER_IMAGE
export TN_SETUP_INSTALL_METHOD=docker TN_SETUP_DOCKER_IMAGE=us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.16.0-devnet; refused_in "setup-keygen devnet image tag" setup-keygen; unset TN_SETUP_INSTALL_METHOD; unset TN_SETUP_DOCKER_IMAGE
refused "setup-keygen without a passphrase on stdin" setup-keygen < /dev/null
printf ' padded \n' > "$T/pass-bad"
refused "setup-keygen with a padded passphrase" setup-keygen < "$T/pass-bad"
export TN_SETUP_NETWORK=mainnet; printf 'short-pass\n' > "$T/pass-short"
refused "mainnet setup-keygen with a 10-byte passphrase" setup-keygen < "$T/pass-short"
export TN_SETUP_NETWORK=testnet
refused "setup-finalize without listener multiaddrs (NC-2)" setup-finalize < /dev/null
DIGEST="$(printf '%064d' 0 | tr 0 a)"
t="$(export TN_SETUP_INSTALL_METHOD=docker TN_SETUP_DOCKER_IMAGE="us-docker.pkg.dev/telcoin-network/tn-public/adiri@sha256:${DIGEST}"; trace setup-keygen < "$T/pass-in")"
check_has "setup-keygen accepts the testnet image by digest" "rc=0" "$t"
fixture unified
refused_in "setup-keygen refused on an installed node" setup-keygen
export TN_SETUP_LIS_PRIMARY=/ip4/10.0.0.5/udp/49590/quic-v1 TN_SETUP_LIS_WORKER=/ip4/10.0.0.5/udp/49594/quic-v1
refused "setup-finalize refused on an installed node" setup-finalize < /dev/null
unset TN_SETUP_LIS_PRIMARY TN_SETUP_LIS_WORKER
for layout in validator observer; do
    fixture "$layout"
    refused_in "setup-keygen refused on a legacy ${layout} node" setup-keygen
    export TN_SETUP_LIS_PRIMARY=/ip4/10.0.0.5/udp/49590/quic-v1 TN_SETUP_LIS_WORKER=/ip4/10.0.0.5/udp/49594/quic-v1
    refused "setup-finalize refused on a legacy ${layout} node" setup-finalize < /dev/null
    unset TN_SETUP_LIS_PRIMARY TN_SETUP_LIS_WORKER
done
fixture none
add_unit telcoin-validator
refused_in "setup-keygen refused on a legacy unit without .node-meta" setup-keygen
fixture none
add_meta validator
refused_in "setup-keygen refused on a legacy .node-meta without a unit" setup-keygen
fixture none
add_meta -
refused_in "setup-keygen refused once keygen wrote .node-meta" setup-keygen
t="$(export TN_SETUP_LIS_PRIMARY=/ip4/10.0.0.5/udp/49590/quic-v1 TN_SETUP_LIS_WORKER=/ip4/10.0.0.5/udp/49594/quic-v1; trace setup-finalize </dev/null)"
check_has "setup-finalize runs after keygen wrote .node-meta" "rc=0" "$t"
unset TN_SETUP_NETWORK

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

printf 'a-dashboard-password-1\n' > "$T/caddy-pass"
fixture none
for h in localhost 1.2.3.4 a..b -x.example "$h254" "${l64}.example.org"; do
    refused "caddy-dns-check refuses $(label "$h")" caddy-dns-check "$h"
    refused "rpc-dns-check refuses $(label "$h")" rpc-dns-check "$h"
    refused "caddy-enable refuses $(label "$h")" caddy-enable "$h" admin < "$T/caddy-pass"
    refused "rpc-enable refuses $(label "$h")" rpc-enable "$h"
done
for h in node7.adiri.telcoin.network "$h253"; do
    t="$(trace caddy-dns-check "$h")"
    check_has "caddy-dns-check accepts $(label "$h")" \
        "install-caddy [--json] [--phase=check-dns] [--domain] [$h]" "$t"
    t="$(trace rpc-dns-check "$h" 203.0.113.7)"
    check_has "rpc-dns-check accepts $(label "$h")" \
        "install-caddy [--json] [--phase=rpc-check-dns] [--rpc-domain] [$h] [--public-ip] [203.0.113.7]" "$t"
    t="$(trace caddy-enable "$h" admin < "$T/caddy-pass")"
    check_has "caddy-enable accepts $(label "$h")" \
        "install-caddy [--json] [--phase=enable] [--domain] [$h] [--username] [admin]" "$t"
done
check_lacks "the dashboard password never reaches an argument" "a-dashboard-password-1" "$(cat "$T/all-calls.log")"
refused "caddy-enable without a password on stdin" caddy-enable node7.example.org admin < /dev/null
printf 'short-pass\n' > "$T/caddy-short"
refused "caddy-enable with a password under 16 characters" caddy-enable node7.example.org admin < "$T/caddy-short"

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
          "metrics=127.0.0.1:9101" "metrics=off" "verbosity=-v" "verbosity=-vvv" \
          "bootstrap_peers=none" "bootstrap_peers=/home/ubuntu/peers.yaml" \
          "state_export=off" "state_export=unlimited" "state_export=1" "state_export=999999" \
          "allow_private_forward_targets=true" "allow_private_forward_targets=false"; do
    t="$(trace config-set "${fv%%=*}" "${fv#*=}")"
    check_has "config-set accepts ${fv}" "edit-config [--json] [--set] [${fv}]" "$t"
done
for fv in "metrics=on" "metrics=OFF" "metrics=127.0.0.1" "verbosity=-vvvvvv" "docker_image=adiri" \
          "metrics=0.0.0.0:9101" "metrics=10.0.0.5:9101" "verbosity=-vvvv" "verbosity=-vvvvv" \
          "docker_image=us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.15.0-adiri" \
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

# ---- Generic argument check ----------------------------------------------------------
fixture unified
refused "an argument with a space is refused" set-hostname "a b"
refused "an argument with a newline is refused" set-hostname "$(printf 'a\nb')"
refused "an argument with a tab is refused" config-set state_export "$(printf '5\t')"
refused "a leading dash is refused" update-prepare --force
refused "a leading dash is refused (set-hostname)" set-hostname -x
refused "a surplus argument is refused (journal-tail)" journal-tail 5 6
refused "an argument to a no-argument subcommand is refused" quorum-check extra
long="$(printf '%0600d' 0)"
refused "an argument over 512 bytes is refused" set-hostname "$long"

# ---- update-prepare takes only a release tag of the node's network -------------------
fixture unified
t="$(trace update-prepare v0.16.0-adiri)"
check_has "update-prepare accepts a testnet release tag" \
    "update-node [--json] [--prepare] [--ref] [v0.16.0-adiri]" "$t"
for r in main feature/x v0.16.0 v0.16.0-adiri-hotfix v0.16-adiri 5535ef1f0425973bd81ef3162f3d07219c3456d0 \
         V0.16.0-adiri "v0.16.0-adiri/../x"; do
    refused "update-prepare refuses $r on testnet" update-prepare "$r"
done
printf 'NETWORK=mainnet\n' > "${ETC_DIR}/.node-meta"
t="$(trace update-prepare v1.0.0)"
check_has "update-prepare accepts a mainnet release tag" "update-node [--json] [--prepare] [--ref] [v1.0.0]" "$t"
refused "update-prepare refuses a testnet tag on mainnet" update-prepare v1.0.0-adiri
printf 'NETWORK=devnet\n' > "${ETC_DIR}/.node-meta"
refused "update-prepare refuses on devnet" update-prepare v1.0.0
printf 'NETWORK=testnet\nNETWORK=mainnet\n' > "${ETC_DIR}/.node-meta"
refused "update-prepare refuses a duplicated NETWORK" update-prepare v1.0.0

# ---- Audit trail ---------------------------------------------------------------------
rm -rf "$T/audit"
fixture unified
trace config-set state_export 7 >/dev/null
trace config-set metrics 0.0.0.0:9101 >/dev/null
trace meta-cat >/dev/null
audit="$(cat "$T/audit/audit.log" 2>/dev/null)"
check "audit: one start line per mutating call, one refused line per refusal" "3" "$(printf '%s\n' "$audit" | grep -c .)"
check_has "audit: the accepted call" \
    "$(printf '%s\n' "$audit" | grep '"args":"state_export 7","phase":"start"')" "$audit"
check "audit: the refusal names its reason" "1" \
    "$(printf '%s\n' "$audit" | grep -c '"phase":"refused","sudo_uid":"[^"]*","detail":"invalid metrics address')"
check_lacks "audit: read-only calls are not logged" '"sub":"meta-cat"' "$audit"
check "audit: the log is not group or world readable" "600" "$(stat -c %a "$T/audit/audit.log" 2>/dev/null)"

# ---- Read-only views --------------------------------------------------------------------
fixture unified
printf 'PRIMARY_LISTENER_MULTIADDR=/ip4/10.0.0.5/udp/49590/quic-v1\nWORKER_LISTENER_MULTIADDR=/ip4/10.0.0.5/udp/49594/quic-v1\nTN_RPC_ADDR=127.0.0.1\nOTHER=x\n' > "${ETC_DIR}/node.env"
t="$(trace node-env-cat)"
check_has "node-env-cat prints the primary listener" "PRIMARY_LISTENER_MULTIADDR=/ip4/10.0.0.5/udp/49590/quic-v1" "$t"
check_has "node-env-cat prints TN_RPC_ADDR" "TN_RPC_ADDR=127.0.0.1" "$t"
check "node-env-cat prints only the three keys" "3" "$( (set -euo pipefail; main node-env-cat) | grep -c .)"
t="$(trace journal-tail 50)"
check_has "journal-tail argv" "journalctl [-u] [telcoin] [-o] [cat] [-n] [50] [--no-pager]" "$t"
t="$(trace journal-follow)"
check_has "journal-follow argv" "journalctl [-u] [telcoin] [-o] [cat] [-n] [0] [-f] [--no-pager]" "$t"
for n in 0 abc 200001 01; do
    refused "journal-tail refuses $n" journal-tail "$n"
done
t="$(trace quorum-check)"
check_has "quorum-check without the library check says so" '{"available":false}' "$t"

# ---- Start-script resolution (current layout) ---------------------------------------
fixture none
mkdir -p "$UNIT_DIR" "$LIBEXEC_DIR"
printf '[Service]\nExecStart=%s\n' "${LIBEXEC_DIR}/tn-start" > "${UNIT_DIR}/telcoin.service"
printf '#!/bin/bash\nexec /usr/local/bin/telcoin-network node --http\n' > "${LIBEXEC_DIR}/tn-start"
check "node_wrapper resolves the libexec start script" "${LIBEXEC_DIR}/tn-start" "$(node_wrapper)"
printf '[Service]\nExecStart=%s\n' "${LIBEXEC_DIR}/tn-start-docker" > "${UNIT_DIR}/telcoin.service"
printf '#!/bin/bash\nexec docker run x\n' > "${LIBEXEC_DIR}/tn-start-docker"
check "node_wrapper resolves the Docker start script" "${LIBEXEC_DIR}/tn-start-docker" "$(node_wrapper)"
printf '[Service]\nExecStart=/usr/bin/evil\n' > "${UNIT_DIR}/telcoin.service"
check "node_wrapper ignores another ExecStart" "${OPT_DIR}/start-telcoin.sh" "$(node_wrapper)"

# ---- Logs: clear, rotation ---------------------------------------------------------------
fixture unified
mv "${LOG_DIR}/telcoin.log" "${LOG_DIR}/real.log"
ln -s "${LOG_DIR}/real.log" "${LOG_DIR}/telcoin.log"
refused "log-clear refuses a symlinked log file" log-clear
check "log-clear left the symlink target alone" "a log line" "$(cat "${LOG_DIR}/real.log")"
fixture unified
t="$(trace log-clear)"
check_has "log-clear in a dir the root check refuses runs as its owner" \
    "run_as [svc] [truncate] [-s] [0] [--] [${LOG_DIR}/telcoin.log]" "$t"
refused "set-logrotate refuses 10X" set-logrotate 10X
refused "set-logrotate refuses 1g" set-logrotate 1g
refused "set-logrotate refuses an empty size" set-logrotate ""
fixture unified
t="$(trace logrotate-seed)"
check_has "logrotate-seed writes the default size" "    size 100M" "$t"
check_has "logrotate-seed keeps copytruncate" "    copytruncate" "$t"
trace set-logrotate 3G >/dev/null
t="$(trace logrotate-seed)"
check_has "logrotate-seed keeps an existing size" "    size 3G" "$t"
ln -s /etc/passwd "$T/root/etc/logrotate.d/evil"
LOGROTATE_CONF="$T/root/etc/logrotate.d/evil" refused "set-logrotate refuses a symlinked config" set-logrotate 1G
check_lacks "the symlink target was not written" "size 1G" "$(cat /etc/passwd)"

# ---- set-hostname writes as the service account ------------------------------------------
fixture unified
printf 'listen: x\nhostname: "old"\nother: y\n' > "${VAR_DIR}/network-config"
t="$(trace set-hostname newname)"
check_has "set-hostname reads network-config as the service account" \
    "run_as [svc] [cat] [--] [${VAR_DIR}/network-config]" "$t"
check_has "set-hostname writes network-config as the service account" \
    "run_as [svc] [mv] [-f] [--] [${VAR_DIR}/network-config.tn-new] [${VAR_DIR}/network-config]" "$t"
check "set-hostname replaces only the hostname line" \
    "$(printf 'listen: x\nhostname: "newname"\nother: y')" "$(cat "${VAR_DIR}/network-config")"
path_owner() { echo "root:root"; }
refused "set-hostname refuses a root-owned data dir" set-hostname other
path_owner() { echo "svc:svc"; }

# ---- Docker views: only a detected Telcoin Network container ----------------------------
fixture unified
# refused_after_ps <name> <args...> -- refused, with docker ps the only call.
refused_after_ps() {
    local name="$1" t
    shift
    t="$(trace "$@")"
    CHECKS=$((CHECKS + 1))
    if [[ "$(printf '%s\n' "$t" | head -1)" != "rc=0" ]] && ! grep -v '^docker \[ps\]' "$T/calls.log" | grep -q .; then
        printf 'ok    %s\n' "$name"
        return 0
    fi
    FAILS=$((FAILS + 1))
    printf 'FAIL  %s\n' "$name"
    printf '%s\n' "$t" | sed 's/^/        /'
    return 1
}
refused_after_ps "docker-status refuses a container docker-detect does not list" docker-status other
refused_after_ps "docker-logs refuses an unknown container" docker-logs nope 10
refused_after_ps "docker-logs refuses a zero line count" docker-logs tn-node 0
t="$(trace docker-status tn-node)"
check_lacks "docker-status never asks for Config.Env" "Env" "$t"
t="$(trace docker-logs-full tn-node)"
check_has "docker-logs-full is capped" "docker [logs] [--tail] [200000] [tn-node]" "$t"

# ---- Jaeger publishes on loopback only ---------------------------------------------------
fixture none
t="$(trace jaeger-start)"
check_has "jaeger-start binds loopback ports, drops capabilities" \
    "docker [run] [-d] [--name] [jaeger] [--restart] [no] [-p] [127.0.0.1:16686:16686] [-p] [127.0.0.1:4317:4317] [--memory] [512m] [--pids-limit] [256] [--cap-drop] [ALL] [--security-opt] [no-new-privileges] [${JAEGER_IMAGE}]" "$t"

# ---- The shared library, when it is there --------------------------------------------------
LIB_SAVE="$HELPER_LIB"
HELPER_LIB="${TEST_DIR}/../../lib/common.sh"
check "a library not owned by root is not used" "unusable" "$(_lib_usable && echo usable || echo unusable)"
LIB_REQUIRE_ROOT=0
check "_lib_call reports a missing function as 127" "127" "$(_lib_call tn_no_such_function; echo $?)"
# shellcheck source=/dev/null
if (source "$HELPER_LIB" >/dev/null 2>&1 && declare -F tn_release_tag_ok >/dev/null); then
    fixture unified
    t="$(trace update-prepare v0.16.0-adiri)"
    check_has "with the library: update-prepare accepts a testnet tag" \
        "update-node [--json] [--prepare] [--ref] [v0.16.0-adiri]" "$t"
    refused "with the library: update-prepare refuses main" update-prepare main
    check "with the library: passphrase_ok refuses a 15-byte mainnet value" "1" \
        "$(passphrase_ok abcdefghijklmno mainnet; echo $?)"
else
    printf 'SKIP  library cases (lib/common.sh does not source here)\n'
fi
# One writer for the rotation config: once the library has tn_install_logrotate,
# set-logrotate must produce exactly what a direct call writes. The library writes
# /etc/logrotate.d/telcoin itself, so this runs only as root in a throwaway
# container (TN_UI_TEST_ROOT=1).
# shellcheck source=/dev/null
if (source "$HELPER_LIB" >/dev/null 2>&1 && declare -F tn_install_logrotate >/dev/null) \
    && [[ $EUID -eq 0 && "${TN_UI_TEST_ROOT:-}" == 1 ]]; then
    LOGROTATE_CONF=/etc/logrotate.d/telcoin
    (set -euo pipefail; main set-logrotate 2G) >/dev/null 2>&1
    via_helper="$(cat /etc/logrotate.d/telcoin 2>/dev/null)"
    rm -f /etc/logrotate.d/telcoin
    # shellcheck source=/dev/null
    (source "$HELPER_LIB" >/dev/null 2>&1; tn_install_logrotate 2G) >/dev/null 2>&1
    check "set-logrotate writes what tn_install_logrotate writes" "$(cat /etc/logrotate.d/telcoin 2>/dev/null)" "$via_helper"
    LOGROTATE_CONF="$T/root/etc/logrotate.d/telcoin"
else
    printf 'SKIP  set-logrotate vs tn_install_logrotate (needs the library function and TN_UI_TEST_ROOT=1 as root)\n'
fi
HELPER_LIB="$LIB_SAVE"
LIB_REQUIRE_ROOT=1

# ---- No engine call carries a role flag ---------------------------------------------
all_calls="$(cat "$T/all-calls.log")"
check_lacks "no recorded call carries --observer" "[--observer]" "$all_calls"
check_lacks "no recorded call carries --validator" "[--validator]" "$all_calls"

printf '\n%s checks, %s failed (bash %s)\n' "$CHECKS" "$FAILS" "$BASH_VERSION"
if [[ $FAILS -ne 0 ]]; then
    exit 1
fi
