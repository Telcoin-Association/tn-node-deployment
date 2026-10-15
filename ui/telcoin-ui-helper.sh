#!/usr/bin/env bash
#
# telcoin-ui-helper -- privileged helper for the Telcoin Node Manager UI.
#
# Installed to /usr/local/sbin/telcoin-ui-helper (root:root, 0755, NOT writable
# by the telcoin-ui service user). This is the SINGLE privileged entry point the
# UI is allowed to invoke via sudo. Every privileged operation (Jaeger, the node
# start script and service, updates, config edits, setup, Caddy, the firewall)
# goes through here, so the sudoers whitelist written by install-ui.sh pins one
# binary and lists the subcommands it may run.
#
# Arguments: the dispatcher accepts only the subcommands in its `case`, refuses
# more arguments than a subcommand takes, and refuses any argument that is empty
# where a value is needed, holds whitespace or a control character, or starts
# with "-" (two documented values excepted: the "-" placeholder of rpc-enable and
# a -v.. verbosity, both checked again by their own pattern). Each subcommand then
# checks every argument against its own pattern. No argument reaches a shell
# string, and secrets (the BLS passphrase, the dashboard password) arrive on
# stdin, never in arguments or sudo's environment.
#
# Audit: each state-changing call is logged, after its arguments pass the
# generic check, to syslog (logger -t telcoin-ui-helper) and appended as one JSON
# line to the root-only /var/log/telcoin-ui/audit.log, with the subcommand, its
# arguments and the calling uid; a refusal adds a second line. Secrets are never
# logged because they never arrive as arguments.
#
# Library: helpers from the root-owned engine copy of lib/common.sh
# (/opt/telcoin-ui-update/lib) are called in a subshell, so the library never
# replaces a function of this file. The checks the engine owns (release tags,
# Docker images, the service account, the passphrase rule, log rotation, the
# committee guard) come only from the library: when it or the function is
# missing the call is refused with "run update-scripts.sh". The file-handling
# primitives keep a local copy of the same steps. An engine script without the
# stdin flags (--passphrase-stdin, --password-stdin) is refused the same way.
#
# Helper API 2 (printed by `helper-version`). The node subcommands take no
# observer|validator argument: the helper resolves the installed node the way
# lib/fallback.sh does (unit telcoin, then telcoin-validator, then
# telcoin-observer). ui/server.py before 1.9.0 still sends the role as the first
# argument; the helper drops a leading observer|validator when a call has one
# argument more than the subcommand takes.
#
# Usage:
#   telcoin-ui-helper helper-version
#   telcoin-ui-helper jaeger-start
#   telcoin-ui-helper jaeger-stop
#   telcoin-ui-helper jaeger-status
#   telcoin-ui-helper tracing-enable
#   telcoin-ui-helper tracing-disable
#   telcoin-ui-helper update-check
#   telcoin-ui-helper update-prepare  <release tag>
#   telcoin-ui-helper update-apply
#   telcoin-ui-helper update-discard
#   telcoin-ui-helper restart-count
#   telcoin-ui-helper quorum-check                              (read-only)
#   telcoin-ui-helper log-clear
#   telcoin-ui-helper journal-tail    <lines>                   (read-only)
#   telcoin-ui-helper journal-follow                            (read-only)
#   telcoin-ui-helper config-set      <field> <value>
#   telcoin-ui-helper set-hostname    <name>
#   telcoin-ui-helper set-logrotate   <size e.g. 1G>
#   telcoin-ui-helper logrotate-seed                            (root only; install-ui.sh)
#   telcoin-ui-helper clear-rotated
#   telcoin-ui-helper caddy-status
#   telcoin-ui-helper caddy-dns-check <domain> [inbound-public-ip]
#   telcoin-ui-helper caddy-enable    <domain> <username> [inbound-public-ip]   (password on stdin)
#   telcoin-ui-helper caddy-disable
#   telcoin-ui-helper rpc-status
#   telcoin-ui-helper rpc-dns-check   <domain> [inbound-public-ip]
#   telcoin-ui-helper rpc-enable      <domain> [inbound-public-ip|-] [dashboard-domain]   (public RPC -- no auth)
#   telcoin-ui-helper rpc-disable
#   telcoin-ui-helper firewall-status
#   telcoin-ui-helper firewall-port   <port>/<proto> <on|off>   (node ports only)
#   telcoin-ui-helper addons-status                             (read-only)
#   telcoin-ui-helper meta-cat                                  (read-only)
#   telcoin-ui-helper node-env-cat                              (read-only)
#   telcoin-ui-helper setup-keygen                              (settings via TN_SETUP_*, passphrase on stdin)
#   telcoin-ui-helper setup-finalize                            (settings via TN_SETUP_*)
#   telcoin-ui-helper docker-detect
#   telcoin-ui-helper docker-status    <container>
#   telcoin-ui-helper docker-logs      <container> [lines]
#   telcoin-ui-helper docker-logs-full <container>
#   telcoin-ui-helper docker-node-info <container>
#   telcoin-ui-helper docker-stats     <container>
#   telcoin-ui-helper docker-log-size  <container>
#   telcoin-ui-helper internal-ip
#
# Every path below is a plain assignment, and main runs only when this file is
# executed, so ui/tests/helper_test.sh can source it and point the paths at a
# temp tree.
#
set -euo pipefail

# Printed by `helper-version`. ui/server.py 1.9.0 and later need 2: node
# subcommands without the role argument, rpc-enable with a dashboard move, and
# setup reading TN_SETUP_RPC_DOMAIN.
HELPER_API=2

JAEGER_NAME="jaeger"
JAEGER_IMAGE="jaegertracing/all-in-one:latest"
TRACING_URL="http://127.0.0.1:4317"

# The node's layout, as lib/fallback.sh resolves it: systemd unit files, the
# config dir holding .node-meta (legacy installs keep one per role underneath),
# the default data dir, the node logs, and the install dir with the legacy
# wrapper script and the binary. Current installs start the node from a
# root-owned script in LIBEXEC_DIR (tn-start, or tn-start-docker for Docker).
UNIT_DIR="/etc/systemd/system"
ETC_DIR="/etc/telcoin"
VAR_DIR="/var/lib/telcoin"
LOG_DIR="/var/log/telcoin"
OPT_DIR="/opt/telcoin"
LIBEXEC_DIR="/usr/local/libexec/telcoin"

# update-node.sh + its lib/ are shipped here (root-owned) by install-ui.sh so the
# helper can drive updates without reaching into any user-writable location.
UPDATE_SCRIPT="/opt/telcoin-ui-update/update-node.sh"
# edit-config.sh is shipped to the same root-owned dir so config edits run the
# CLI's own --json mode rather than re-implementing unit-file editing here.
CONFIG_SCRIPT="/opt/telcoin-ui-update/edit-config.sh"
# firewall-setup.sh, same root-owned dir, same --json pattern.
FIREWALL_SCRIPT="/opt/telcoin-ui-update/firewall-setup.sh"
# setup-node.sh, same root-owned dir. Settings arrive in TN_SETUP_* variables
# (kept across sudo for the two setup subcommands only); the BLS passphrase
# arrives on stdin.
SETUP_SCRIPT="/opt/telcoin-ui-update/setup-node.sh"
# install-caddy.sh, same root-owned dir.
CADDY_SCRIPT="/opt/telcoin-ui-update/install-caddy.sh"
# The engine copy of the shared library. Used only when it and its directory
# are root-owned and not writable by group or others (LIB_REQUIRE_ROOT=1).
HELPER_LIB="/opt/telcoin-ui-update/lib/common.sh"
LIB_REQUIRE_ROOT=1

# Node-log rotation config (one for every node unit).
LOGROTATE_CONF="/etc/logrotate.d/telcoin"
# The group that may read node logs on current installs.
LOG_GROUP="telcoin-log"

# Audit trail of state-changing calls. AUDIT_LOGGER is the syslog command;
# empty turns syslog off (the tests do).
AUDIT_LOG="/var/log/telcoin-ui/audit.log"
AUDIT_LOGGER="logger"
# Subcommand and arguments of the running call, for the audit lines.
AUDIT_SUB=""
AUDIT_ARGS=""

die() {
    echo "$*" >&2
    if [[ -n "$AUDIT_SUB" ]]; then
        audit_line refused "$*"
    fi
    exit 1
}

# =============================================================================
# Argument checks and the audit trail
# =============================================================================

# _arg_ok <arg> -- the generic check every argument passes before dispatch: at
# most 512 bytes, no whitespace or control character, and no leading "-" except
# the rpc-enable placeholder "-" and a verbosity value -v .. -vvvvv.
_arg_ok() {
    local a="${1-}"
    [[ ${#a} -le 512 ]] || return 1
    case "$a" in
        *[[:space:]]*|*[[:cntrl:]]*) return 1 ;;
    esac
    if [[ "$a" == -* ]]; then
        [[ "$a" == "-" || "$a" =~ ^-v{1,5}$ ]] || return 1
    fi
    return 0
}

# Minimal JSON string escaper (this helper has no json lib): backslash and
# double quote escaped, every control character (a refused argument may hold
# one) written as a space.
_json_str() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "${s//[[:cntrl:]]/ }"; }

# The subcommands that change state; each is audited.
is_mutating() {
    case "${1:-}" in
        jaeger-start|jaeger-stop|tracing-enable|tracing-disable) return 0 ;;
        update-prepare|update-apply|update-discard|log-clear|config-set) return 0 ;;
        set-hostname|set-logrotate|logrotate-seed|clear-rotated) return 0 ;;
        caddy-enable|caddy-disable|rpc-enable|rpc-disable|firewall-port) return 0 ;;
        setup-keygen|setup-finalize) return 0 ;;
    esac
    return 1
}

# audit_line <phase> [detail] -- one JSON line for the running call to syslog and
# to AUDIT_LOG. The log directory must be a real directory owned by this uid;
# a write that fails is reported on stderr and does not stop the call.
audit_line() {
    local phase="$1" detail="${2:-}" dir line ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
    line="{\"ts\":\"${ts}\",\"sub\":\"$(_json_str "$AUDIT_SUB")\",\"args\":\"$(_json_str "$AUDIT_ARGS")\",\"phase\":\"${phase}\",\"sudo_uid\":\"$(_json_str "${SUDO_UID:-}")\""
    if [[ -n "$detail" ]]; then
        line="${line},\"detail\":\"$(_json_str "${detail:0:300}")\""
    fi
    line="${line}}"
    if [[ -n "$AUDIT_LOGGER" ]] && command -v "$AUDIT_LOGGER" >/dev/null 2>&1; then
        "$AUDIT_LOGGER" -t telcoin-ui-helper -- "$line" 2>/dev/null || true
    fi
    dir="${AUDIT_LOG%/*}"
    if [[ -L "$dir" || -L "$AUDIT_LOG" ]]; then
        echo "audit: ${AUDIT_LOG} or its directory is a symlink; not written" >&2
        return 0
    fi
    if [[ ! -d "$dir" ]]; then
        (umask 027; mkdir -p "$dir") 2>/dev/null || true
    fi
    if [[ "$(stat -c %u "$dir" 2>/dev/null)" != "$(id -u)" ]]; then
        echo "audit: ${dir} is not owned by uid $(id -u); not written" >&2
        return 0
    fi
    { (umask 077; printf '%s\n' "$line" >> "$AUDIT_LOG"); } 2>/dev/null \
        || echo "audit: could not append to ${AUDIT_LOG}" >&2
    return 0
}

# =============================================================================
# The shared library, called in a subshell
# =============================================================================

# _lib_usable -- rc 0 when HELPER_LIB may be sourced: a regular file (not a
# symlink) and, with LIB_REQUIRE_ROOT=1, it and its directory owned by uid 0
# and not writable by group or others.
_lib_usable() {
    local d st
    [[ -f "$HELPER_LIB" && ! -L "$HELPER_LIB" ]] || return 1
    [[ "$LIB_REQUIRE_ROOT" == 1 ]] || return 0
    d="${HELPER_LIB%/*}"
    [[ ! -L "$d" ]] || return 1
    for st in "$(stat -c '%u %a' "$HELPER_LIB" 2>/dev/null)" "$(stat -c '%u %a' "$d" 2>/dev/null)"; do
        [[ "${st%% *}" == 0 ]] || return 1
        case "${st##* }" in
            *[2367]?|*[2367]) return 1 ;;
        esac
    done
    return 0
}

# _lib_call <function> [args...] -- run a library function in a subshell and
# return its status; 127 when the library or the function is not there, so the
# caller uses its local copy, or refuses (_lib_req). SERVICE_USER/SERVICE_GROUP set by the caller (for
# tn_as_service_user) survive the library's own defaults.
_lib_call() {
    local fn="$1"
    shift
    _lib_usable || return 127
    (
        su_keep="${SERVICE_USER:-}"; sg_keep="${SERVICE_GROUP:-}"
        # shellcheck source=/dev/null
        source "$HELPER_LIB" >/dev/null 2>&1 || exit 127
        [[ -n "$su_keep" ]] && SERVICE_USER="$su_keep"
        [[ -n "$sg_keep" ]] && SERVICE_GROUP="$sg_keep"
        set +e
        declare -F "$fn" >/dev/null || exit 127
        "$fn" "$@"
    )
}

# lib_missing <function> -- refuse the running call: the engine library is
# missing, not root-owned, or older than this helper.
lib_missing() {
    die "the engine library (${HELPER_LIB}) is missing or has no ${1}: run update-scripts.sh, then try again"
}

# _lib_req <function> [args...] -- _lib_call for a check only the library holds:
# its status, or the call refused (lib_missing) when the function is not there.
# The refusal goes to stderr, so a caller may silence the function's stdout.
_lib_req() {
    local rc=0
    _lib_call "$@" || rc=$?
    [[ $rc -ne 127 ]] || lib_missing "$1"
    return $rc
}

# engine_has <script> <flag> -- refuse the running call when the engine copy of
# <script> does not know <flag> (it is older than this helper).
engine_has() {
    grep -q -- "$2" "$1" 2>/dev/null \
        || die "${1##*/} in the engine copy has no ${2} (it is older than this helper): run update-scripts.sh, then try again"
}

# _run_as <user> <group> <command...> -- run a command as an unprivileged account
# (never uid 0), with TN_BLS_PASSPHRASE stripped from its environment. Uses the
# library's tn_as_service_user; the fallback does the same with setpriv or runuser.
_run_as() {
    local u="$1" g="$2" uid rc
    shift 2
    uid="$(id -u "$u" 2>/dev/null || true)"
    [[ "$uid" =~ ^[0-9]+$ && ! "$uid" =~ ^0+$ ]] || { echo "refusing to run as '${u}'" >&2; return 126; }
    rc=0
    SERVICE_USER="$u" SERVICE_GROUP="$g" _lib_call tn_as_service_user "$@" || rc=$?
    [[ $rc -eq 127 ]] || return $rc
    if command -v setpriv >/dev/null 2>&1 && setpriv --help 2>&1 | grep -q -- '--reuid'; then
        env -u TN_BLS_PASSPHRASE setpriv --reuid "$uid" --regid "$(getent group "$g" | cut -d: -f3)" \
            --clear-groups --no-new-privs -- "$@"
        return
    fi
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$u" -g "$g" -- env -u TN_BLS_PASSPHRASE "$@"
        return
    fi
    echo "neither setpriv nor runuser is installed" >&2
    return 126
}

# _root_dir_ok <dir> -- the library's tn_root_dir_ok: DIR and every parent are
# real directories owned by uid 0 and not group/other-writable. Fallback: the
# same walk.
_root_dir_ok() {
    local d="$1" rc=0 st
    _lib_call tn_root_dir_ok "$d" || rc=$?
    [[ $rc -eq 127 ]] || return $rc
    [[ "$d" == /* ]] || return 1
    while :; do
        [[ -L "$d" || ! -d "$d" ]] && return 1
        st="$(stat -c '%u %a' "$d" 2>/dev/null)" || return 1
        [[ "${st%% *}" == 0 ]] || return 1
        case "${st##* }" in
            *[2367]?|*[2367]) return 1 ;;
        esac
        [[ "$d" == / ]] && return 0
        d="${d%/*}"
        [[ -n "$d" ]] || d=/
    done
}

# Run a long engine job (update, setup) in its own transient systemd scope, so
# the UI unit's resource caps (MemoryMax, TasksMax, CPUQuota) do not hold a
# source build. Without systemd-run (tests, containers) it runs directly. Never
# returns.
exec_job() {
    if [[ $EUID -eq 0 ]] && command -v systemd-run >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        exec systemd-run --scope --quiet --collect --description="Telcoin UI job" -- "$@"
    fi
    exec "$@"
}

# =============================================================================
# Node resolution. The helper never takes the node's role from its caller: a box
# runs one node, and its role follows on-chain committee membership.
# =============================================================================

# The node's systemd unit (base name), in tn_resolve_service order: the unified
# `telcoin` unit, then the legacy telcoin-validator, then telcoin-observer. A box
# with both legacy units gets telcoin-validator. With no unit installed the
# answer is `telcoin`, the name a new install uses.
node_service() {
    local n
    for n in telcoin telcoin-validator telcoin-observer; do
        if [[ -f "${UNIT_DIR}/${n}.service" ]]; then
            echo "$n"; return 0
        fi
    done
    echo "telcoin"
}

# The node's .node-meta, in common.sh node_meta_path order: the unified
# /etc/telcoin/.node-meta, then the legacy role dirs (validator first). Prints the
# unified path when none exists; callers check that the file is there.
node_meta_path() {
    local t
    if [[ -f "${ETC_DIR}/.node-meta" ]]; then
        echo "${ETC_DIR}/.node-meta"; return 0
    fi
    for t in validator observer; do
        if [[ -f "${ETC_DIR}/${t}/.node-meta" ]]; then
            echo "${ETC_DIR}/${t}/.node-meta"; return 0
        fi
    done
    echo "${ETC_DIR}/.node-meta"
}

# meta_value <KEY> -- the value of KEY in the node's .node-meta, CR stripped.
# Empty when the file or the key is absent; a key set more than once is an
# error (rc 2, nothing printed), as in lib/common.sh meta_get.
meta_value() {
    local meta n line cr
    meta="$(node_meta_path)"
    [[ -f "$meta" ]] || return 0
    n="$(grep -c -E "^${1}=" "$meta" 2>/dev/null || true)"
    case "$n" in
        ""|0) return 0 ;;
        1) ;;
        *) echo "${1} is set ${n} times in ${meta}" >&2; return 2 ;;
    esac
    line="$(grep -m1 -E "^${1}=" "$meta" 2>/dev/null || true)"
    cr=$'\r'
    line="${line%"$cr"}"
    printf '%s\n' "${line#*=}"
}

# The node's data dir (where network-config + node-info.yaml live): the DATA_DIR=
# its .node-meta records when that is an absolute path, else /var/lib/telcoin for
# a unified meta (or none) and /var/lib/telcoin/<role> for a legacy role meta.
# Unlike tn_resolve_data_dir, a recorded DATA_DIR that does not exist is still
# returned, so set-hostname reports it instead of writing to a directory the node
# does not read.
node_data_dir() {
    local meta dd=""
    meta="$(node_meta_path)"
    dd="$(meta_value DATA_DIR)" || die "cannot resolve the data dir: DATA_DIR is set more than once in ${meta}"
    if [[ "$dd" == /* ]]; then
        echo "$dd"; return 0
    fi
    case "$meta" in
        "${ETC_DIR}/validator/.node-meta") echo "${VAR_DIR}/validator" ;;
        "${ETC_DIR}/observer/.node-meta")  echo "${VAR_DIR}/observer" ;;
        *)                                 echo "${VAR_DIR}" ;;
    esac
}

# The start script the node unit's ExecStart points at: a legacy wrapper ending
# in .sh, or the root-owned tn-start / tn-start-docker in LIBEXEC_DIR. Falls back
# to the conventional legacy path. Mirrors server.py's wrapper_path().
node_wrapper() {
    local svc unit exec_line path
    svc="$(node_service)"
    unit="${UNIT_DIR}/${svc}.service"
    if [[ -f "$unit" ]]; then
        exec_line="$(grep -m1 '^ExecStart=' "$unit" 2>/dev/null || true)"
        path="${exec_line#ExecStart=}"
        path="${path%% *}"
        case "$path" in
            *.sh|"${LIBEXEC_DIR}/tn-start"|"${LIBEXEC_DIR}/tn-start-docker")
                if [[ -f "$path" ]]; then
                    echo "$path"
                    return 0
                fi
                ;;
        esac
    fi
    echo "${OPT_DIR}/start-${svc}.sh"
}

# path_owner <path> -- "user:group" owning PATH (stat), empty when unknown.
path_owner() {
    stat -c '%U:%G' "$1" 2>/dev/null || true
}

# The node's main log file, from its unit (StandardOutput=append:<path>), falling
# back to the conventional path. Mirrors server.py parse_service_file.
node_log_path() {
    local svc unit p=""
    svc="$(node_service)"
    unit="${UNIT_DIR}/${svc}.service"
    if [[ -f "$unit" ]]; then
        p="$(grep -m1 '^StandardOutput=append:' "$unit" 2>/dev/null | sed 's/^StandardOutput=append://' || true)"
    fi
    [[ -n "$p" ]] || p="${LOG_DIR}/${svc}.log"
    echo "$p"
}

# Validate a docker container name before it reaches `docker`: docker's own name
# charset, and one of the Telcoin Network containers docker-detect reports, so
# the read-only docker subcommands can only look at the node's own container.
require_container() {
    local name="${1:-}"
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
        || die "invalid container name: ${name:-<empty>}"
    command -v docker >/dev/null 2>&1 || die "docker not installed"
    cmd_docker_detect | grep -qxF -- "$name" \
        || die "not a Telcoin Network container: $name"
}

# Strict hostname rule, the same in ui/server.py and the browser: at most 253
# characters, two or more dot-separated labels of letters, digits and inner
# hyphens (1 to 63 characters each), and not only digits and dots (an IPv4
# address). The server and the browser trim, lowercase and drop one trailing dot
# before they check; the helper checks the name as given, so it refuses a
# trailing dot.
valid_hostname() {
    local h="${1:-}" re
    re='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$'
    [[ ${#h} -le 253 && "$h" =~ $re ]] || return 1
    [[ ! "$h" =~ ^[0-9.]+$ ]]
}

# 0 when two hostnames name the same host. DNS names are case-insensitive;
# valid_hostname has already refused a trailing dot.
same_host() {
    local a b
    a="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    b="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
    [[ -n "$a" && "$a" == "$b" ]]
}

# node_network -- testnet or mainnet, from the library's tn_detect_network (meta
# NETWORK, else the genesis chain id); the fallback reads NETWORK from .node-meta
# (adiri counts as testnet). Prints nothing and returns 1 for anything else.
node_network() {
    local net rc=0
    net="$(_lib_call tn_detect_network "$(node_meta_path)" 2>/dev/null)" || rc=$?
    if [[ $rc -eq 0 ]]; then
        case "$net" in testnet|mainnet) echo "$net"; return 0 ;; esac
        return 1
    fi
    [[ $rc -eq 127 ]] || return 1
    net="$(meta_value NETWORK 2>/dev/null)" || return 1
    case "$net" in
        testnet|adiri) echo testnet ;;
        mainnet) echo mainnet ;;
        *) return 1 ;;
    esac
}

# release_tag_ok <network> <tag> -- the library's tn_release_tag_ok (testnet
# vX.Y.Z-adiri, mainnet vX.Y.Z).
release_tag_ok() {
    _lib_req tn_release_tag_ok "$1" "$2"
}

cmd_helper_version() {
    echo "$HELPER_API"
}

# =============================================================================
# Node logs
# =============================================================================

# Truncate (NOT delete) the node's log file, keeping the inode so the running
# service keeps writing to the same handle. Only a regular file directly in
# LOG_DIR named *.log, never a symlink. In a root-owned log dir root truncates
# it; in a legacy dir owned by the service user the truncate runs as that
# account, so a planted symlink can never point root at another file.
cmd_log_clear() {
    local logf owner
    logf="$(node_log_path)"
    case "$logf" in
        "${LOG_DIR}"/*/*) die "refusing to clear non-standard log path: $logf" ;;
        "${LOG_DIR}"/*.log) ;;
        *) die "refusing to clear non-standard log path: $logf" ;;
    esac
    [[ ! -L "$LOG_DIR" ]] || die "refusing: ${LOG_DIR} is a symlink"
    [[ ! -L "$logf" ]] || die "refusing: $logf is a symlink"
    [[ -f "$logf" ]] || die "log file not found: $logf"
    if _root_dir_ok "$LOG_DIR"; then
        : > "$logf" 2>/dev/null || die "could not truncate $logf"
    else
        owner="$(path_owner "$LOG_DIR")"
        [[ -n "$owner" && "$owner" != root:* ]] || die "refusing: ${LOG_DIR} is neither root-only nor owned by the node's account"
        _run_as "${owner%%:*}" "${owner#*:}" truncate -s 0 -- "$logf" \
            || die "could not truncate $logf as ${owner%%:*}"
    fi
    echo "ok"
}

# The node unit's journal, for installs that log there (LOG_TARGET=journal):
# the last <lines> lines (1 to 200000), or a live follow that ends when the
# caller closes it.
cmd_journal_tail() {
    local lines="${1:-}"
    [[ "$lines" =~ ^[1-9][0-9]{0,5}$ && "$lines" -le 200000 ]] \
        || die "invalid line count: ${lines:-<empty>} (1 to 200000)"
    exec journalctl -u "$(node_service)" -o cat -n "$lines" --no-pager
}

cmd_journal_follow() {
    exec journalctl -u "$(node_service)" -o cat -n 0 -f --no-pager
}

jaeger_state() {
    # Prints: running | stopped | absent
    if ! command -v docker >/dev/null 2>&1; then
        echo "absent"; return 0
    fi
    local running
    if running="$(docker inspect -f '{{.State.Running}}' "$JAEGER_NAME" 2>/dev/null)"; then
        [[ "$running" == "true" ]] && echo "running" || echo "stopped"
    else
        echo "absent"
    fi
}

# Create the Jaeger container. --restart no: Jaeger is an on-demand tracing
# tool, NOT a service. It must not auto-start on boot or linger -- it runs only
# while explicitly enabled from the Tracing tab, and stays down after a reboot.
# Ports are published on loopback only; the container gets no capabilities and
# bounded memory and pids.
jaeger_run() {
    docker run -d --name "$JAEGER_NAME" --restart no \
        -p 127.0.0.1:16686:16686 -p 127.0.0.1:4317:4317 \
        --memory 512m --pids-limit 256 --cap-drop ALL \
        --security-opt no-new-privileges "$JAEGER_IMAGE" >/dev/null \
        || die "failed to create jaeger container"
}

cmd_jaeger_start() {
    command -v docker >/dev/null 2>&1 || die "docker not installed"
    local state
    state="$(jaeger_state)"
    case "$state" in
        running) echo "already running" ;;
        stopped)
            # Recreate rather than restart, so a container an older helper made
            # (published on every interface) never comes back.
            docker rm -f "$JAEGER_NAME" >/dev/null || die "failed to remove the old jaeger container"
            jaeger_run ;;
        absent) jaeger_run ;;
    esac
    echo "ok"
}

cmd_jaeger_stop() {
    command -v docker >/dev/null 2>&1 || die "docker not installed"
    # Remove (not just stop) so Jaeger never lingers as a stopped container -- a
    # fresh Start recreates it with --restart no. This also transitions any legacy
    # container that was created with --restart unless-stopped off that policy.
    if [[ "$(jaeger_state)" != "absent" ]]; then
        docker rm -f "$JAEGER_NAME" >/dev/null || die "failed to remove jaeger container"
    fi
    echo "ok"
}

cmd_jaeger_status() {
    jaeger_state
}

cmd_tracing_enable() {
    local wrapper svc
    wrapper="$(node_wrapper)"
    [[ -f "$wrapper" ]] || die "wrapper script not found: $wrapper"

    cp -p "$wrapper" "${wrapper}.bak.$(date +%s)" || die "failed to back up wrapper"

    if grep -q -- '--tracing-url' "$wrapper"; then
        echo "already enabled"
    else
        # Insert the tracing flags immediately after the `telcoin-network node`
        # token on the exec line. Anchored to the exec line so single-line and
        # backslash-continued multi-line wrappers are both handled. The node name
        # is `telcoin` whatever the node's role, which changes with committee
        # membership.
        sed -i -E \
            "s#(^exec .*telcoin-network node)#\1 --tracing-url ${TRACING_URL} --node-name telcoin#" \
            "$wrapper" || die "failed to edit wrapper"
        grep -q -- '--tracing-url' "$wrapper" || die "tracing flags not inserted (no matching exec line?)"
    fi

    # Non-blocking: the durable change is the wrapper edit above. --no-block
    # returns as soon as the restart job is queued, so the caller never waits on
    # the node's stop window (TimeoutStopSec up to 90s). Fires only if enqueue fails.
    svc="$(node_service)"
    systemctl restart --no-block "$svc" || die "failed to restart $svc"
    echo "ok"
}

cmd_tracing_disable() {
    local wrapper svc
    wrapper="$(node_wrapper)"
    [[ -f "$wrapper" ]] || die "wrapper script not found: $wrapper"

    cp -p "$wrapper" "${wrapper}.bak.$(date +%s)" || die "failed to back up wrapper"

    # Strip ` --tracing-url <nonspace>` and ` --node-name <nonspace>` wherever
    # they appear on the exec line. No-op if already absent.
    sed -i -E \
        -e 's# --tracing-url[[:space:]]+[^[:space:]\\]+##g' \
        -e 's# --node-name[[:space:]]+[^[:space:]\\]+##g' \
        "$wrapper" || die "failed to edit wrapper"

    # Non-blocking: the durable change is the wrapper edit above. --no-block
    # returns as soon as the restart job is queued, so the caller never waits on
    # the node's stop window (TimeoutStopSec up to 90s). Fires only if enqueue fails.
    svc="$(node_service)"
    systemctl restart --no-block "$svc" || die "failed to restart $svc"
    echo "ok"
}


# =============================================================================
# Update subcommands -- thin wrappers around update-node.sh --json. They never
# embed update logic themselves; all the building/swapping/restarting lives in
# update-node.sh, which finds the node itself. The ref must be a release tag of
# the node's network; branch names and commit ids are refused.
# =============================================================================

update_script_ready() {
    [[ -f "$UPDATE_SCRIPT" ]] || die "update script not found: $UPDATE_SCRIPT"
}

cmd_update_check() {
    update_script_ready
    exec bash "$UPDATE_SCRIPT" --json --check
}

cmd_update_prepare() {
    local ref="$1" net
    update_script_ready
    [[ -n "$ref" ]] || die "missing ref"
    net="$(node_network)" || die "cannot tell this node's network (NETWORK in .node-meta must be testnet or mainnet)"
    release_tag_ok "$net" "$ref" \
        || die "ref must be a release tag of ${net} (vX.Y.Z$([[ "$net" == testnet ]] && echo -adiri)); branches and commit ids are refused: $ref"
    exec_job bash "$UPDATE_SCRIPT" --json --prepare --ref "$ref"
}

cmd_update_apply() {
    update_script_ready
    # --yes: in JSON mode this stands in for the interactive typed CONFIRM and is
    # required for validators. The UI shows the downtime warning before calling.
    exec_job bash "$UPDATE_SCRIPT" --json --apply --yes
}

cmd_update_discard() {
    update_script_ready
    exec bash "$UPDATE_SCRIPT" --json --discard
}

# Count service starts since the current install. The journal for a system unit
# is not readable by the unprivileged telcoin-ui user, so this runs as root via
# the helper. "Since current install" = build-info built_at if present, else the
# node binary's mtime. Prints a single integer (0 on any uncertainty).
cmd_restart_count() {
    local since="" binp svc
    if [[ -f "${ETC_DIR}/build-info" ]]; then
        since="$(grep -E '^built_at=' "${ETC_DIR}/build-info" 2>/dev/null | head -1 | cut -d= -f2- || true)"
        since="${since//T/ }"; since="${since%Z}"
    fi
    if [[ -z "$since" ]]; then
        binp="${OPT_DIR}/telcoin-network"
        if [[ ! -f "$binp" ]]; then
            binp="$(find /usr /opt -name telcoin-network -type f 2>/dev/null | head -1 || true)"
        fi
        if [[ -n "$binp" && -e "$binp" ]]; then
            since="$(stat -c %y "$binp" 2>/dev/null || true)"
        fi
    fi
    if [[ -z "$since" ]]; then
        echo 0; return 0
    fi
    svc="$(node_service)"
    journalctl -u "$svc" --since "$since" --no-pager 2>/dev/null \
        | grep -c "Started ${svc}.service" || true
}

# Committee quorum check behind the UI's restart badge: the library's
# tn_committee_down_guard against the node's local RPC. Prints one JSON line,
# {"available":true,"rc":N,"detail":"..."}: rc 0 a restart is safe, 1 it would
# put the committee at risk, 2 the committee could not be read. Refused when the
# library has no such check. Read-only.
cmd_quorum_check() {
    local port url rc=0 detail
    port="$(meta_value RPC_PORT 2>/dev/null || true)"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || port=8545
    url="http://127.0.0.1:${port}"
    detail="$(TN_ALLOW_QUORUM_RISK=0 _lib_call tn_committee_down_guard "$url" 2>&1 >/dev/null)" || rc=$?
    [[ $rc -ne 127 ]] || lib_missing tn_committee_down_guard
    detail="$(printf '%s' "$detail" | tr '\n' ' ' | sed 's/\x1b\[[0-9;]*m//g')"
    printf '{"available":true,"rc":%d,"detail":"%s"}\n' "$rc" "$(_json_str "${detail:0:300}")"
}

# =============================================================================
# Config subcommand -- thin wrapper around edit-config.sh --json. The field is
# checked against the editable allowlist and the value against a per-field regex
# HERE before the script runs (edit-config.sh re-validates with its own
# validators). The Docker image is not editable from the UI: it changes only
# through a verified update or the root menu.
# =============================================================================

config_script_ready() {
    [[ -f "$CONFIG_SCRIPT" ]] || die "config script not found: $CONFIG_SCRIPT"
}

cmd_config_set() {
    local field="$1" value="$2"
    config_script_ready
    [[ -n "$field" ]] || die "missing field"
    [[ -n "$value" ]] || die "missing value"

    # Per-field value validation (first line of defence; edit-config.sh repeats it).
    case "$field" in
        primary_listener|worker_listener)
            [[ "$value" =~ ^/(ip4|ip6)/[^/]+/udp/[0-9]+/quic-v1$ ]] \
                || die "invalid multiaddr: $value" ;;
        metrics)
            # off removes --metrics. The endpoint stays on loopback; a public
            # bind needs a root operator (edit-config.sh --allow-public-metrics).
            [[ "$value" =~ ^(off|127\.0\.0\.1:[0-9]{1,5})$ ]] \
                || die "invalid metrics address (127.0.0.1:PORT or off): $value" ;;
        verbosity)
            [[ "$value" =~ ^-v{1,3}$ ]] || die "invalid verbosity (-v to -vvv): $value" ;;
        bootstrap_peers)
            # An absolute path to a peers file already on the node (this helper
            # cannot upload one), or none to remove the flag and the file.
            # edit-config.sh has the node binary check the file before it installs
            # it as /etc/telcoin/bootstrap-peers.yaml.
            [[ "$value" =~ ^(none|/[A-Za-z0-9._/-]+)$ ]] \
                || die "invalid bootstrap_peers (an absolute path or none): $value" ;;
        state_export)
            # off, unlimited, or how many epochs of exports to keep.
            [[ "$value" =~ ^(off|unlimited|[1-9][0-9]{0,5})$ ]] \
                || die "invalid state_export (off, unlimited or 1 to 999999): $value" ;;
        allow_private_forward_targets)
            # edit-config.sh refuses true on testnet and mainnet.
            [[ "$value" =~ ^(true|false)$ ]] \
                || die "invalid allow_private_forward_targets (true or false): $value" ;;
        *)
            die "field not editable: $field" ;;
    esac

    exec bash "$CONFIG_SCRIPT" --json --set "${field}=${value}"
}

# Set the "Advertised Node Name" -- the `hostname` field in the node's
# network-config YAML -- and restart the node so it reads the new value. The data
# dir belongs to the node's service account, so every read and write of
# network-config runs as that account (never root); .node-meta, root-owned in
# /etc/telcoin, is updated by root through the library's meta_set.
cmd_set_hostname() {
    local name="$1" dd nc owner u g old="" new="" line done_line=0 svc rc=0 meta
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "invalid name: ${name:-<empty>}"

    dd="$(node_data_dir)"
    [[ -d "$dd" && ! -L "$dd" ]] || die "data dir not found: $dd"
    nc="${dd}/network-config"
    owner="$(path_owner "$dd")"
    u="${owner%%:*}"; g="${owner#*:}"
    [[ -n "$owner" && "$u" != root && "$u" != "UNKNOWN" ]] \
        || die "refusing: ${dd} is not owned by the node's service account"

    if _run_as "$u" "$g" test -e "$nc"; then
        old="$(_run_as "$u" "$g" cat -- "$nc")" || die "could not read $nc as $u"
    fi
    # The first hostname: line is replaced, or one is added at the end.
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == hostname:* ]]; then
            [[ $done_line -eq 0 ]] && new="${new}hostname: \"${name}\""$'\n'
            done_line=1
            continue
        fi
        new="${new}${line}"$'\n'
    done <<< "$old"
    [[ -z "$old" ]] && new=""
    [[ $done_line -eq 1 ]] || new="${new}hostname: \"${name}\""$'\n'
    printf '%s' "$new" | _run_as "$u" "$g" tee -- "${nc}.tn-new" >/dev/null \
        || die "could not write ${nc}.tn-new as $u"
    _run_as "$u" "$g" mv -f -- "${nc}.tn-new" "$nc" || die "could not replace $nc as $u"

    # Record in .node-meta as the persistent source of truth.
    meta="$(node_meta_path)"
    if [[ -f "$meta" && ! -L "$meta" ]]; then
        _lib_call meta_set ADVERTISED_NODE_NAME "$name" "$meta" >/dev/null 2>&1 || rc=$?
        if [[ $rc -eq 127 ]]; then
            sed -i '/^ADVERTISED_NODE_NAME=/d' "$meta" 2>/dev/null || true
            printf 'ADVERTISED_NODE_NAME=%s\n' "$name" >> "$meta"
        elif [[ $rc -ne 0 ]]; then
            echo "warning: could not record ADVERTISED_NODE_NAME in $meta" >&2
        fi
    fi

    # Restart so the node reads the new network-config. --no-block returns once
    # the restart job is queued (validators have a long stop window).
    svc="$(node_service)"
    systemctl restart --no-block "$svc" || die "failed to restart $svc"
    echo "ok"
}

# Node-log rotation. One config for every node unit (copytruncate: the node
# holds the log open). The library's tn_install_logrotate is the only writer; it
# writes LOGROTATE_CONF (passed as TN_LOGROTATE_FILE).

# logrotate_refused RC -- stop a logrotate write that failed with RC. The
# library refuses (rc 1) while the log group does not exist yet, which means the
# node's file-ownership migration has not run on this host; say how to run it.
logrotate_refused() {
    local rc="$1"
    if [[ "$rc" -eq 1 ]] && ! getent group "$LOG_GROUP" >/dev/null 2>&1; then
        die "could not write ${LOGROTATE_CONF}: the ${LOG_GROUP} group does not exist yet. Run update-node.sh or edit-config.sh once (as root) to migrate the node's file ownership, then try again."
    fi
    die "could not write ${LOGROTATE_CONF} (rc ${rc})"
}

# set-logrotate SIZE: rewrite the config with SIZE. logrotate-seed (root only,
# install-ui.sh): keep an existing config, else write the default (100M).
cmd_set_logrotate() {
    local size="$1" rc=0
    [[ "$size" =~ ^[0-9]+[KMG]$ ]] || die "invalid size: ${size:-<empty>} (e.g. 500M, 1G)"
    TN_LOGROTATE_FILE="$LOGROTATE_CONF" _lib_req tn_install_logrotate "$size" >/dev/null || rc=$?
    [[ $rc -eq 0 ]] || logrotate_refused "$rc"
    echo "ok"
}

cmd_logrotate_seed() {
    local rc=0
    TN_LOGROTATE_FILE="$LOGROTATE_CONF" _lib_req tn_install_logrotate >/dev/null || rc=$?
    [[ $rc -eq 0 ]] || logrotate_refused "$rc"
    echo "ok"
}

# Delete rotated node logs only (telcoin-*.log.1, telcoin-*.log.2.gz, ...).
# Never the live *.log: the node holds it open via StandardOutput=append:, so
# removing it wouldn't free space until a restart and would break logging. The
# fixed glob can't be steered to a non-standard path, and rm removes a symlink
# itself, never its target. Prints the count removed.
cmd_clear_rotated() {
    local n=0 f
    [[ ! -L "$LOG_DIR" ]] || die "refusing: ${LOG_DIR} is a symlink"
    shopt -s nullglob
    for f in "${LOG_DIR}"/*.log.[0-9]*; do
        if [[ -f "$f" || -L "$f" ]]; then
            rm -f -- "$f" && n=$((n+1))
        fi
    done
    shopt -u nullglob
    echo "removed ${n}"
}

# read_secret -- one line from stdin (the server writes the secret and closes
# the pipe), into the global SECRET. Never echoed, never an argument.
SECRET=""
read_secret() {
    SECRET=""
    IFS= read -r SECRET || [[ -n "$SECRET" ]] || return 1
    [[ -n "$SECRET" ]]
}

# =============================================================================
# External dashboard access (Caddy) -- thin wrappers around install-caddy.sh
# --json phases. status/check-dns emit one JSON object; enable/disable stream
# JSON events. The dashboard password arrives on the helper's stdin and goes to
# install-caddy.sh on its stdin (--password-stdin).
# =============================================================================

caddy_script_ready() { [[ -f "$CADDY_SCRIPT" ]] || die "caddy script not found: $CADDY_SCRIPT"; }

cmd_caddy_status() { caddy_script_ready; exec bash "$CADDY_SCRIPT" --json --phase=status; }
cmd_caddy_disable() { caddy_script_ready; exec bash "$CADDY_SCRIPT" --json --phase=disable; }

# The optional trailing public_ip is the node's INBOUND public IP (where ACME hits
# 80/443), forwarded to install-caddy.sh as --public-ip for the multi-IP / 1:1-NAT
# case where it differs from the auto-detected egress IP. Empty = exact no-op (the
# script auto-detects egress, today's behavior). Loose char-class only -- the script
# re-validates semantically via validate_public_ip and falls back to egress on failure.
cmd_caddy_dns_check() {
    local domain="$1" public_ip="${2:-}"; caddy_script_ready
    valid_hostname "$domain" || die "invalid domain: ${domain:-<empty>}"
    [[ -z "$public_ip" || "$public_ip" =~ ^[0-9a-fA-F.:]+$ ]] || die "invalid public ip"
    local -a args=( --json --phase=check-dns --domain "$domain" )
    [[ -n "$public_ip" ]] && args+=( --public-ip "$public_ip" )
    exec bash "$CADDY_SCRIPT" "${args[@]}"
}

cmd_caddy_enable() {
    local domain="$1" username="$2" public_ip="${3:-}"; caddy_script_ready
    valid_hostname "$domain" || die "invalid domain: ${domain:-<empty>}"
    [[ -n "$username" && "$username" =~ ^[A-Za-z0-9._-]{2,32}$ ]] || die "invalid username"
    [[ -z "$public_ip" || "$public_ip" =~ ^[0-9a-fA-F.:]+$ ]] || die "invalid public ip"
    read_secret || die "the dashboard password must arrive on stdin"
    # install-caddy.sh's rule: at least 16 bytes, no control characters.
    local n
    n="$(printf '%s' "$SECRET" | LC_ALL=C wc -c | tr -d ' ')"
    [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 16 )) || die "the dashboard password must be at least 16 characters"
    case "$SECRET" in
        *[[:cntrl:]]*) die "the dashboard password must not contain control characters" ;;
    esac
    local -a args=( --json --phase=enable --domain "$domain" --username "$username" )
    [[ -n "$public_ip" ]] && args+=( --public-ip "$public_ip" )
    engine_has "$CADDY_SCRIPT" --password-stdin
    exec bash "$CADDY_SCRIPT" "${args[@]}" --password-stdin <<< "$SECRET"
}

# =============================================================================
# Public RPC endpoint (Caddy) -- thin wrappers around the SAME install-caddy.sh,
# its rpc-* --json phases. rpc-status/rpc-check-dns emit one JSON object;
# rpc-enable/rpc-disable stream JSON events. Unlike the dashboard there is NO
# password (a public RPC endpoint has no auth), and the flag is --rpc-domain (not
# --domain). The node-info.yaml edit + node restart happen inside install-caddy.sh.
# =============================================================================
cmd_rpc_status()  { caddy_script_ready; exec bash "$CADDY_SCRIPT" --json --phase=rpc-status; }
cmd_rpc_disable() { caddy_script_ready; exec bash "$CADDY_SCRIPT" --json --phase=rpc-disable; }

cmd_rpc_dns_check() {
    local domain="$1" public_ip="${2:-}"; caddy_script_ready
    valid_hostname "$domain" || die "invalid domain: ${domain:-<empty>}"
    [[ -z "$public_ip" || "$public_ip" =~ ^[0-9a-fA-F.:]+$ ]] || die "invalid public ip"
    local -a args=( --json --phase=rpc-check-dns --rpc-domain "$domain" )
    [[ -n "$public_ip" ]] && args+=( --public-ip "$public_ip" )
    exec bash "$CADDY_SCRIPT" "${args[@]}"
}

# rpc-enable <domain> [<inbound-public-ip>|-] [<dashboard-domain>]. "-" stands for
# no inbound IP, so a dashboard domain can follow without one. When the dashboard
# is served on <domain>, install-caddy.sh first moves it (same login) to
# <dashboard-domain>, which must be a different host.
cmd_rpc_enable() {
    local domain="$1" public_ip="${2:-}" move_to="${3:-}"; caddy_script_ready
    valid_hostname "$domain" || die "invalid domain: ${domain:-<empty>}"
    if [[ "$public_ip" == "-" ]]; then
        public_ip=""
    fi
    [[ -z "$public_ip" || "$public_ip" =~ ^[0-9a-fA-F.:]+$ ]] || die "invalid public ip"
    if [[ -n "$move_to" ]]; then
        valid_hostname "$move_to" || die "invalid dashboard domain: ${move_to}"
        if same_host "$domain" "$move_to"; then
            die "the dashboard domain must differ from the RPC domain (both are ${domain})"
        fi
    fi
    local -a args=( --json --phase=rpc-enable --rpc-domain "$domain" )
    [[ -n "$public_ip" ]] && args+=( --public-ip "$public_ip" )
    [[ -n "$move_to" ]] && args+=( --move-dashboard-to "$move_to" )
    exec bash "$CADDY_SCRIPT" "${args[@]}"
}

# =============================================================================
# Firewall subcommands -- thin wrappers around firewall-setup.sh --json. Only
# the three node ports may be toggled; SSH/policy/etc are never reachable here.
# =============================================================================

firewall_script_ready() {
    [[ -f "$FIREWALL_SCRIPT" ]] || die "firewall script not found: $FIREWALL_SCRIPT"
}

cmd_firewall_status() {
    firewall_script_ready
    exec bash "$FIREWALL_SCRIPT" --json --status
}

cmd_firewall_port() {
    local spec="$1" pstate="$2"
    firewall_script_ready
    # Hard allowlist (the script re-checks). 49590/49594 udp = P2P, 43174/tcp = Kuma.
    case "$spec" in
        49590/udp|49594/udp|43174/tcp) ;;
        *) die "port not permitted: $spec" ;;
    esac
    case "$pstate" in on|off) ;; *) die "state must be on|off" ;; esac
    exec bash "$FIREWALL_SCRIPT" --json --port "$spec" "$pstate"
}

# =============================================================================
# Read-only views: testnet add-ons status, .node-meta, node.env.
# =============================================================================

# Read KEY=value from the node's root-owned .node-meta. Empty when absent.
_addons_meta() {
    local meta="$1" key="$2"
    [[ -f "$meta" ]] || return 0
    grep -E "^${key}=" "$meta" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# Print the raw contents of the node's root-owned (mode 600) .node-meta so the
# unprivileged UI can read it -- it cannot open the file directly. READ-ONLY:
# this only cats an existing metadata file (KEY=VALUE operational data: data dir,
# network, region, addresses -- no secrets; the BLS passphrase is never stored
# here). Empty output (rc 0) when the file is absent.
cmd_meta_cat() {
    local meta
    meta="$(node_meta_path)"
    [[ -f "$meta" && ! -L "$meta" ]] && cat "$meta" || true
}

# The node's listener addresses and RPC address from /etc/telcoin/node.env
# (current installs keep them there, outside the start script). Only the three
# known keys are printed. Empty output (rc 0) when the file is absent.
cmd_node_env_cat() {
    local f="${ETC_DIR}/node.env"
    [[ -f "$f" && ! -L "$f" ]] || return 0
    grep -E '^(PRIMARY_LISTENER_MULTIADDR|WORKER_LISTENER_MULTIADDR|TN_RPC_ADDR)=' "$f" 2>/dev/null || true
}

cmd_addons_status() {
    local meta
    meta="$(node_meta_path)"
    local network region hc obs vpn overlay pubkey extra
    network=$(_addons_meta "$meta" NETWORK)
    region=$(_addons_meta "$meta" REGION)
    hc=$(_addons_meta "$meta" ENABLE_HEALTHCHECK_MONITOR)
    obs=$(_addons_meta "$meta" ENABLE_OBSERVABILITY)
    vpn=$(_addons_meta "$meta" ENABLE_VPN)
    overlay=$(_addons_meta "$meta" VPN_OVERLAY_IP)
    pubkey=$(_addons_meta "$meta" VPN_NODE_PUBKEY)
    extra=$(_addons_meta "$meta" KUMA_EXTRA_SRC)
    [[ "$vpn" == "true" || "$vpn" == "pending" ]] || vpn="false"

    # Read-only probes.
    local hc_enabled=false hc_ok=false obs_enabled=false alloy=false wg_up=false wg_hs=false
    [[ "$hc" == "true" ]] && { hc_enabled=true; curl -fsS --max-time 3 "http://127.0.0.1:43174" >/dev/null 2>&1 && hc_ok=true; }
    [[ "$obs" == "true" ]] && { obs_enabled=true; systemctl is-active --quiet telcoin-alloy 2>/dev/null && alloy=true; }
    if [[ "$vpn" == "true" || "$vpn" == "pending" ]]; then
        ip link show wg0 >/dev/null 2>&1 && wg_up=true
        [[ "$wg_up" == "true" ]] && command -v wg >/dev/null 2>&1 && wg show wg0 2>/dev/null | grep -qE 'latest handshake' && wg_hs=true
    fi

    printf '{"network":"%s","region":"%s","health":{"enabled":%s,"responding":%s,"port":43174,"extra_src":"%s"},"logging":{"enabled":%s,"running":%s},"vpn":{"state":"%s","wg_up":%s,"handshake":%s,"overlay_ip":"%s","pubkey":"%s"}}\n' \
        "$(_json_str "$network")" "$(_json_str "$region")" \
        "$hc_enabled" "$hc_ok" "$(_json_str "$extra")" \
        "$obs_enabled" "$alloy" \
        "$(_json_str "$vpn")" "$wg_up" "$wg_hs" \
        "$(_json_str "$overlay")" "$(_json_str "$pubkey")"
}

# =============================================================================
# Setup subcommands -- thin wrappers around setup-node.sh --json --phase=...
# Settings come from TN_SETUP_* (validated here); the BLS passphrase arrives on
# stdin (keygen only) and goes to setup-node.sh on its stdin
# (--passphrase-stdin). Public RPC is requested by TN_SETUP_RPC_DOMAIN alone: a
# hostname becomes --rpc-domain, and --rpc-public is never sent.
# =============================================================================

# service_account_ok <user> <group> -- the library's tn_service_user_ok: a plain
# lowercase name, never root or telcoin-ui, an existing account a system account
# without admin groups (its reason goes to stderr).
service_account_ok() {
    _lib_req tn_service_user_ok "$1" "$2" >/dev/null
}

# docker_image_ok <image> <network> -- the library's tn_docker_image_allowed:
# the network's repository by digest.
docker_image_ok() {
    _lib_req tn_docker_image_allowed "$1" "$2" >/dev/null
}

# passphrase_ok <value> <network> -- the library's tn_passphrase_ok (no CR/LF,
# no whitespace at either end, 16 bytes or more on mainnet).
passphrase_ok() {
    _lib_req tn_passphrase_ok "$1" "$2"
}

cmd_setup() {
    local phase="$1"
    [[ -f "$SETUP_SCRIPT" ]] || die "setup script not found: $SETUP_SCRIPT"

    local network="${TN_SETUP_NETWORK:-}"
    local method="${TN_SETUP_INSTALL_METHOD:-}"
    local addr="${TN_SETUP_ADDRESS:-}"
    local build_ref="${TN_SETUP_BUILD_REF:-}"
    local image="${TN_SETUP_DOCKER_IMAGE:-}"
    local ext_primary="${TN_SETUP_EXT_PRIMARY:-}"
    local ext_worker="${TN_SETUP_EXT_WORKER:-}"
    local lis_primary="${TN_SETUP_LIS_PRIMARY:-}"
    local lis_worker="${TN_SETUP_LIS_WORKER:-}"
    local public_ip="${TN_SETUP_PUBLIC_IP:-}"
    local rpc_domain="${TN_SETUP_RPC_DOMAIN:-}"
    local svc_user="${TN_SETUP_SERVICE_USER:-}"
    local svc_group="${TN_SETUP_SERVICE_GROUP:-}"
    local adv_name="${TN_SETUP_ADVERTISED_NAME:-}"
    local data_dir="${TN_SETUP_DATA_DIR:-}"
    local net_rule

    # An installed node is never set up again from the UI: both phases stop when
    # a node unit exists (unified or legacy), and keygen also when any
    # .node-meta exists (finalize reads the one keygen wrote).
    local unit meta
    for unit in telcoin telcoin-validator telcoin-observer; do
        if [[ -e "${UNIT_DIR}/${unit}.service" || -L "${UNIT_DIR}/${unit}.service" ]]; then
            die "a node is already installed (${UNIT_DIR}/${unit}.service); use edit-config.sh, or remove-node.sh first"
        fi
    done
    meta="$(node_meta_path)"
    if [[ "$phase" == keygen && ( -e "$meta" || -L "$meta" ) ]]; then
        die "a node install already started (${meta}); finish it with setup-finalize, or remove-node.sh first"
    fi

    # Validate every value before it reaches the setup script.
    case "$network" in
        testnet|adiri) net_rule=testnet ;;
        mainnet) net_rule=mainnet ;;
        "") die "missing network (TN_SETUP_NETWORK)" ;;
        *) die "invalid network: $network" ;;
    esac
    case "$method" in source|docker|existing|release|"") ;; *) die "invalid install method: $method" ;; esac
    [[ -z "$addr"      || "$addr"      =~ ^0x[0-9a-fA-F]{40}$ ]]            || die "invalid address"
    [[ -z "$build_ref" ]] || release_tag_ok "$net_rule" "$build_ref" \
        || die "invalid build ref (a ${net_rule} release tag): $build_ref"
    [[ -z "$image" ]] || docker_image_ok "$image" "$net_rule" \
        || die "invalid docker image for ${net_rule}: $image"
    # These values skip _arg_ok (they arrive in TN_SETUP_*), so the address
    # part refuses whitespace and control characters itself.
    local m ma_re='^/(ip4|ip6)/[^/[:space:][:cntrl:]]+/udp/[0-9]+/quic-v1$'
    for m in "$ext_primary" "$ext_worker" "$lis_primary" "$lis_worker"; do
        [[ -z "$m" || "$m" =~ $ma_re ]] || die "invalid multiaddr: $m"
    done
    if [[ "$phase" == finalize ]]; then
        [[ -n "$lis_primary" && -n "$lis_worker" ]] \
            || die "finalize needs both listener multiaddrs (TN_SETUP_LIS_PRIMARY, TN_SETUP_LIS_WORKER)"
    fi
    [[ -z "$public_ip" || "$public_ip" =~ ^[0-9a-fA-F.:]+$ ]] || die "invalid public ip"
    [[ -z "$rpc_domain" ]] || valid_hostname "$rpc_domain" || die "invalid rpc domain: $rpc_domain"
    service_account_ok "${svc_user:-telcoin}" "${svc_group:-${svc_user:-telcoin}}" \
        || die "invalid service account: ${svc_user:-telcoin}:${svc_group:-} (not root or telcoin-ui, no login account, not in sudo, adm or docker)"
    [[ -z "$adv_name"  || "$adv_name"  =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "invalid advertised name"
    if [[ -n "$data_dir" ]]; then
        [[ "$data_dir" =~ ^/var/lib/telcoin(/[A-Za-z0-9._-]+)*$ && "$data_dir" != *".."* ]] \
            || die "invalid data directory (/var/lib/telcoin or a path under it): $data_dir"
    fi

    local -a args=( --json "--phase=${phase}" --network "$network" )
    [[ -n "$method" ]]      && args+=( --install-method "$method" )
    [[ -n "$addr" ]]        && args+=( --address "$addr" )
    [[ -n "$build_ref" ]]   && args+=( --build-ref "$build_ref" )
    [[ -n "$image" ]]       && args+=( --docker-image "$image" )
    [[ -n "$ext_primary" ]] && args+=( --external-primary "$ext_primary" )
    [[ -n "$ext_worker" ]]  && args+=( --external-worker "$ext_worker" )
    [[ -n "$lis_primary" ]] && args+=( --listener-primary "$lis_primary" )
    [[ -n "$lis_worker" ]]  && args+=( --listener-worker "$lis_worker" )
    [[ -n "$public_ip" ]]   && args+=( --public-ip "$public_ip" )
    [[ -n "$rpc_domain" ]]  && args+=( --rpc-domain "$rpc_domain" )
    [[ -n "$svc_user" ]]    && args+=( --service-user "$svc_user" )
    [[ -n "$svc_group" ]]   && args+=( --service-group "$svc_group" )
    [[ -n "$adv_name" ]]    && args+=( --advertised-name "$adv_name" )
    [[ -n "$data_dir" ]]    && args+=( --data-dir "$data_dir" )

    if [[ "$phase" != keygen ]]; then
        exec_job bash "$SETUP_SCRIPT" "${args[@]}" </dev/null
    fi
    read_secret || die "the BLS passphrase must arrive on stdin"
    passphrase_ok "$SECRET" "$net_rule" \
        || die "the BLS passphrase is not usable (no line breaks, no spaces or tabs at either end$([[ "$net_rule" == mainnet ]] && echo ', 16 bytes or more on mainnet'))"
    engine_has "$SETUP_SCRIPT" --passphrase-stdin
    exec_job bash "$SETUP_SCRIPT" "${args[@]}" --passphrase-stdin <<< "$SECRET"
}

cmd_setup_keygen()   { cmd_setup keygen; }
cmd_setup_finalize() { cmd_setup finalize; }

# =============================================================================
# Docker detection subcommands -- READ-ONLY. These let the UI recognise and
# monitor a Telcoin Network node deployed as a dev-team docker container (not
# under systemd). Every one only inspects/reads (docker ps / inspect / logs /
# cat node-info.yaml); none can start, stop, or otherwise mutate a container or
# the host. The container argument must be one docker-detect reports.
# =============================================================================

# Image substrings that identify a dev-team Telcoin Network container.
DOCKER_TN_IMAGE_RE='us-docker\.pkg\.dev/telcoin-network/tn-public|telcoin-network/tn-public|/tn-public/'

# Print the names of running Telcoin Network containers, one per line. Empty
# output (rc 0) when docker is absent or no matching container runs.
cmd_docker_detect() {
    command -v docker >/dev/null 2>&1 || return 0
    docker ps --no-trunc --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
        | grep -E "$DOCKER_TN_IMAGE_RE" \
        | cut -f1 || true
}

# The fields of `docker inspect` the UI reads, as a one-element JSON array in
# docker's own shape: Name, State, RestartCount, Config.Image, Config.Cmd,
# HostConfig.Binds, HostConfig.NetworkMode, NetworkSettings.Ports. Never
# Config.Env, which can hold secrets.
DOCKER_STATUS_FORMAT='[{"Name":{{json .Name}},"State":{{json .State}},"RestartCount":{{json .RestartCount}},"Config":{"Image":{{json .Config.Image}},"Cmd":{{json .Config.Cmd}}},"HostConfig":{"Binds":{{json .HostConfig.Binds}},"NetworkMode":{{json .HostConfig.NetworkMode}}},"NetworkSettings":{"Ports":{{json .NetworkSettings.Ports}}}}]'

cmd_docker_status() {
    local name="$1"; require_container "$name"
    docker inspect --format "$DOCKER_STATUS_FORMAT" "$name" 2>/dev/null || die "container not found: $name"
}

# Tail the container's stdout/stderr log (combined). Second arg = line count
# (default 100, at most 200000), validated as a bare integer.
cmd_docker_logs() {
    local name="$1" lines="${2:-100}"
    require_container "$name"
    [[ "$lines" =~ ^[1-9][0-9]{0,5}$ && "$lines" -le 200000 ]] || die "invalid line count: $lines"
    docker logs --tail "$lines" "$name" 2>&1 || die "could not read logs for $name"
}

# The container log for the "Download full log" action, capped at the last
# 200000 lines.
cmd_docker_logs_full() {
    local name="$1"; require_container "$name"
    docker logs --tail 200000 "$name" 2>&1 || die "could not read logs for $name"
}

# Print the container's node-info.yaml, prefixed with a classifying
# `node_type:` line. The file lives in a host bind-mount; we resolve the first
# bind whose host path holds node-info.yaml (a regular file, not a symlink).
#
# Node type comes from config, NOT command-line flags (team deployments don't
# pass --validator): a non-empty proof_of_possession field means this node is a
# validator, otherwise it's an observer.
cmd_docker_node_info() {
    local name="$1"; require_container "$name"
    local binds host b info=""
    binds="$(docker inspect -f '{{range .HostConfig.Binds}}{{println .}}{{end}}' "$name" 2>/dev/null || true)"
    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        host="${b%%:*}"
        if [[ "$host" == /* && -f "${host}/node-info.yaml" && ! -L "${host}/node-info.yaml" ]]; then
            info="${host}/node-info.yaml"
            break
        fi
    done <<< "$binds"
    [[ -n "$info" ]] || die "node-info.yaml not found for container $name"

    local pop node_type="observer"
    pop="$(grep -m1 -E '^[[:space:]]*proof_of_possession[[:space:]]*:' "$info" 2>/dev/null | cut -d: -f2- || true)"
    pop="$(printf '%s' "$pop" | tr -d '[:space:]')"
    case "$pop" in
        ''|'""'|"''") node_type="observer" ;;
        *)            node_type="validator" ;;
    esac

    echo "node_type: ${node_type}"
    cat "$info"
}

# One-shot resource sample (CPU / mem / net / block IO) for the container. Tab-
# separated so the server can split cleanly. `--no-stream` takes ~1s to sample.
cmd_docker_stats() {
    local name="$1"; require_container "$name"
    docker stats "$name" --no-stream \
        --format '{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}' 2>/dev/null
}

# Primary internal/LAN IP of the host (first field of `hostname -I`). Shown in
# Node Details for every node type.
cmd_internal_ip() {
    hostname -I | awk '{print $1}'
}

# Size (bytes) of the container's json-file log on the host. The LogPath is
# root-owned, so the stat() must run here. Prints 0 when the file is missing.
cmd_docker_log_size() {
    local name="$1"; require_container "$name"
    local log_path
    log_path="$(docker inspect "$name" --format='{{.LogPath}}' 2>/dev/null)"
    [[ -n "$log_path" ]] || die "could not determine log path for $name"
    stat -c%s "$log_path" 2>/dev/null || echo 0
}

# How many arguments a node subcommand takes once the old role argument is gone.
# Fails for every other subcommand, whose arguments are never touched.
legacy_arity() {
    case "${1:-}" in
        tracing-enable|tracing-disable|update-check|update-apply|update-discard) echo 0 ;;
        restart-count|log-clear|addons-status|meta-cat|setup-keygen|setup-finalize) echo 0 ;;
        update-prepare|set-hostname) echo 1 ;;
        config-set) echo 2 ;;
        *) return 1 ;;
    esac
}

# The most arguments each subcommand takes. Unknown subcommands fail.
max_args() {
    case "${1:-}" in
        helper-version|jaeger-start|jaeger-stop|jaeger-status) echo 0 ;;
        tracing-enable|tracing-disable|update-check|update-apply|update-discard) echo 0 ;;
        restart-count|quorum-check|log-clear|journal-follow|clear-rotated) echo 0 ;;
        logrotate-seed|caddy-status|caddy-disable|rpc-status|rpc-disable) echo 0 ;;
        firewall-status|addons-status|meta-cat|node-env-cat) echo 0 ;;
        setup-keygen|setup-finalize|docker-detect|internal-ip) echo 0 ;;
        update-prepare|journal-tail|set-hostname|set-logrotate) echo 1 ;;
        docker-status|docker-logs-full|docker-node-info|docker-stats|docker-log-size) echo 1 ;;
        config-set|caddy-dns-check|rpc-dns-check|firewall-port|docker-logs) echo 2 ;;
        caddy-enable|rpc-enable) echo 3 ;;
        *) return 1 ;;
    esac
}

main() {
    local sub="${1:-}" arity max a
    if [[ $# -gt 0 ]]; then
        shift
    fi
    max="$(max_args "$sub")" || die "unknown subcommand: ${sub:-<empty>}"
    # A state-changing call is audited from here on, so a refusal by the checks
    # below leaves a "refused" line too. Its arguments are recorded once they
    # have passed those checks.
    if is_mutating "$sub"; then
        AUDIT_SUB="$sub"
    fi

    # ui/server.py before 1.9.0 puts observer|validator in front of a node
    # subcommand's arguments. Drop it only when the call has more arguments than
    # the subcommand takes, so `set-hostname validator` still names the node
    # "validator". Anything left over is an error.
    if arity="$(legacy_arity "$sub")"; then
        if [[ $# -gt $arity ]]; then
            case "$1" in observer|validator) shift ;; esac
        fi
    fi
    [[ $# -le $max ]] || die "too many arguments for ${sub}: $*"
    for a in "$@"; do
        _arg_ok "$a" || die "invalid argument for ${sub}"
    done
    if [[ -n "$AUDIT_SUB" ]]; then
        AUDIT_ARGS="$*"
        audit_line start
    fi

    case "$sub" in
        helper-version)  cmd_helper_version ;;
        jaeger-start)    cmd_jaeger_start ;;
        jaeger-stop)     cmd_jaeger_stop ;;
        jaeger-status)   cmd_jaeger_status ;;
        tracing-enable)  cmd_tracing_enable ;;
        tracing-disable) cmd_tracing_disable ;;
        update-check)    cmd_update_check ;;
        update-prepare)  cmd_update_prepare "${1:-}" ;;
        update-apply)    cmd_update_apply ;;
        update-discard)  cmd_update_discard ;;
        restart-count)   cmd_restart_count ;;
        quorum-check)    cmd_quorum_check ;;
        log-clear)       cmd_log_clear ;;
        journal-tail)    cmd_journal_tail "${1:-}" ;;
        journal-follow)  cmd_journal_follow ;;
        config-set)      cmd_config_set "${1:-}" "${2:-}" ;;
        set-hostname)    cmd_set_hostname "${1:-}" ;;
        set-logrotate)   cmd_set_logrotate "${1:-}" ;;
        logrotate-seed)  cmd_logrotate_seed ;;
        clear-rotated)   cmd_clear_rotated ;;
        caddy-status)    cmd_caddy_status ;;
        caddy-dns-check) cmd_caddy_dns_check "${1:-}" "${2:-}" ;;
        caddy-enable)    cmd_caddy_enable "${1:-}" "${2:-}" "${3:-}" ;;
        caddy-disable)   cmd_caddy_disable ;;
        rpc-status)      cmd_rpc_status ;;
        rpc-dns-check)   cmd_rpc_dns_check "${1:-}" "${2:-}" ;;
        rpc-enable)      cmd_rpc_enable "${1:-}" "${2:-}" "${3:-}" ;;
        rpc-disable)     cmd_rpc_disable ;;
        firewall-status) cmd_firewall_status ;;
        firewall-port)   cmd_firewall_port "${1:-}" "${2:-}" ;;
        addons-status)   cmd_addons_status ;;
        meta-cat)        cmd_meta_cat ;;
        node-env-cat)    cmd_node_env_cat ;;
        setup-keygen)    cmd_setup_keygen ;;
        setup-finalize)  cmd_setup_finalize ;;
        docker-detect)    cmd_docker_detect ;;
        docker-status)    cmd_docker_status    "${1:-}" ;;
        docker-logs)      cmd_docker_logs      "${1:-}" "${2:-}" ;;
        docker-logs-full) cmd_docker_logs_full "${1:-}" ;;
        docker-node-info) cmd_docker_node_info "${1:-}" ;;
        docker-stats)     cmd_docker_stats     "${1:-}" ;;
        docker-log-size)  cmd_docker_log_size  "${1:-}" ;;
        internal-ip)      cmd_internal_ip ;;
        *) die "unknown subcommand: ${sub:-<empty>}" ;;
    esac
}

# Run only when executed. ui/tests/helper_test.sh sources this file to test the
# functions above, and sourcing must not run a subcommand.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
