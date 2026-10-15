#!/usr/bin/env bash
# =============================================================================
# update-node.sh -- Telcoin Network Node Update
#
# Updates a running Telcoin node to a newer version. Auto-detects the
# install method (source build / docker) and offers a two-phase workflow:
#
#   1. PREPARE  -- build new binary or pull new image (zero service impact)
#   2. APPLY    -- stop service, swap, restart, verify (brief downtime)
#
# The two phases can be run together (prepare-and-apply) or split so the
# operator can pick a quiet maintenance window for the apply step. The
# prepared state survives between invocations via a pending-state file.
#
# When the target is v0.15.0 or newer, APPLY also removes the retired
# observer flag from the node's launch file (the start wrapper, or the unit
# on a legacy docker install): later releases refuse to start with it. The
# file is backed up first and restored if the update rolls back.
#
# Before APPLY stops a node that is voting in the current committee, it waits
# for the epoch to close and settle when the boundary is within five minutes,
# so the node is not down for the epoch change. The wait is capped at 30
# minutes. A rollback restart never waits.
#
# ONE-WAY UPDATES: when the node runs a release older than v0.16.0 and the
# target is v0.16.0 or newer (or a branch or a commit), APPLY cannot be undone
# by swapping the binary or image back. The new release migrates the consensus
# store in the data dir on its first start, and older releases cannot open it
# afterwards. Snapshot the data dir first. APPLY says so (and warns when free
# disk is under twice the largest consensus-db/epochs/epoch-N), asks you to
# confirm, and waits up to 600 seconds for the node to answer. If that check
# fails, APPLY does not roll back: the node keeps running (it may still be
# migrating) and the script prints how to restore the snapshot. A node whose
# running release cannot be read counts as older.
#
# USAGE:
#   sudo bash update-node.sh
#   sudo bash update-node.sh --discard        # drop any pending prepared update
#   sudo bash update-node.sh --no-epoch-wait  # restart without the epoch wait
#   sudo bash update-node.sh --allow-quorum-risk  # stop even when the committee
#                                             # check says too many members are down
#
# TN_SKIP_EPOCH_WAIT=1 skips the epoch wait the same way as --no-epoch-wait.
# TN_UPDATE_VERIFY_TIMEOUT=<seconds> sets the post-restart health window
# (default 45, or 600 on a one-way update).
#
# What is NEVER touched by this script:
#   - BLS / P2P keys in <data_dir>/node-keys/
#   - node-info.yaml (primary_network_key, multiaddrs)
#   - BLS passphrase at <config_dir>/bls-passphrase
#   - Chain config files (genesis/committee/parameters)
#   - Listener multiaddrs and other Environment= lines in the unit file
# =============================================================================
# --help prints the block above only. Not advertised there: --observer and
# --validator are still accepted and ignored, because the node's role is
# decided on-chain and older copies of the UI helper pass one of them on every
# --json call.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
# The library must be the one shipped with this script: an older one (a partial
# update) lacks helpers this script calls. Refuse up front with one message.
_tn_old=""
version_gte "${COMMON_VERSION:-0}" "1.6.0" || _tn_old=1
for _tn_fn in tn_migrate_ownership tn_passphrase_ok tn_update_lock_path tn_write_root_file \
              tn_detect_network tn_write_node_unit tn_remove_inflight_tmp; do
    declare -F "$_tn_fn" >/dev/null 2>&1 || _tn_old=1
done
if [[ -n "$_tn_old" ]]; then
    _tn_old="lib/common.sh ${COMMON_VERSION:-unknown} is older than this update-node.sh: run update-scripts.sh and try again."
    case " $* " in
        *" --json "*) printf '{"event":"error","msg":"%s"}\n{"event":"done","ok":false,"msg":"%s"}\n' "$_tn_old" "$_tn_old" ;;
        *) printf '[ERROR] %s\n' "$_tn_old" >&2 ;;
    esac
    exit 1
fi
unset _tn_fn _tn_old

# common.sh enables errexit for the setup scripts, but this script is
# deliberately `set -uo pipefail` ONLY (see above): every state-changing step
# in the apply/rollback flows does its own error handling, and an errexit
# abort between "service stopped" and "service restarted" would strand the
# node down and skip the health-verify -> rollback recovery that is the whole
# point of the two-phase design. Restore the intended semantics.
set +e

readonly SCRIPT_VERSION="1.2.1"
# GAR_TAGS_URL is provided by lib/common.sh (sourced above). Re-declaring it
# readonly here threw "GAR_TAGS_URL: readonly variable" to stderr, which the UI
# surfaced as "update checks aren't available on this host".
#
# Post-restart health-verify window (seconds). Overridable via
# TN_UPDATE_VERIFY_TIMEOUT for fleet-orchestrated updates: when every peer
# restarts at once (a wire-protocol-breaking upgrade), quorum takes longer to
# re-form than a single-node restart, and the default window would trigger a
# spurious auto-rollback. A numeric value always wins. Unset or non-numeric
# means the default: 45, or STORAGE_MIGRATION_VERIFY_SECONDS on a one-way
# update (see update_verify_window). The value feeds arithmetic under set -u.
VERIFY_TIMEOUT_EXPLICIT=false
if [[ "${TN_UPDATE_VERIFY_TIMEOUT:-}" =~ ^[0-9]+$ ]]; then
    # 10#: a leading zero (0900) would otherwise be read as octal by (( )).
    readonly VERIFY_TIMEOUT_SECONDS="$(( 10#${TN_UPDATE_VERIFY_TIMEOUT} ))"
    VERIFY_TIMEOUT_EXPLICIT=true
else
    readonly VERIFY_TIMEOUT_SECONDS=45
fi
readonly VERIFY_TIMEOUT_EXPLICIT
# The first release whose first start migrates the consensus store one way
# (epoch packs v1 -> v2); older releases cannot open the migrated data dir.
readonly STORAGE_MIGRATION_FLOOR="0.16.0"
# Health window for such an update: the first start migrates before it answers.
readonly STORAGE_MIGRATION_VERIFY_SECONDS=600
# Set by storage_migration_begin on each apply: true when this update is one way.
STORAGE_MIGRATION=false
# Set right before the first start of the new release on a one-way update, so
# the EXIT trap can tell a kill after that start (the data dir may be migrating)
# from one before it (nothing migrated yet).
STORAGE_MIGRATION_STARTED=false
# Set by verify_health_after_restart: true when its last run saw a healthy node.
UPDATE_HEALTH_OK=false

SERVICE_NAME=""
RPC_URL=""
DISCARD_PENDING=false
# --observer / --validator as passed (the last one wins). Both are retired and
# ignored: the node's role is decided on-chain. Older copies of the UI helper
# still pass one on every --json call, so they must keep parsing cleanly.
LEGACY_ROLE_FLAG=""

# --no-epoch-wait: restart without waiting for the epoch boundary.
NO_EPOCH_WAIT=false

# Non-interactive (--json) mode state. Drives the UI's Update feature via the
# root-owned telcoin-ui-helper. Empty/false here means classic interactive mode.
JSON_MODE=false
JSON_ACTION=""
JSON_REF=""
ASSUME_YES=false
# Set once the run has sent its final JSON answer (a done event, or the single
# --check status object), so update_on_exit never adds a second one.
JSON_DONE_SENT=false
# The last error event's message; update_on_exit reuses it as the done message.
JSON_LAST_ERROR=""
# EXIT-trap command of a lib/common.sh older than 1.5.0, kept by update_lock.
UPDATE_LOCK_CLEANUP=""

# =============================================================================
# DETECTION
# =============================================================================

# Resolve the installed node: SERVICE_NAME is the systemd unit BASE name
# (tn_resolve_service: "telcoin" on a unified install, the legacy unit name on a
# legacy one), and RPC_URL is the LOCAL endpoint used for the health probes and
# the on-chain status read. The node serves RPC on RPC_PORT from .node-meta
# (default DEFAULT_RPC_PORT = 8545). Exits when no node is installed.
detect_node() {
    SERVICE_NAME="$(tn_resolve_service)" || {
        if [[ "$JSON_MODE" == "true" ]]; then
            json_event error "no Telcoin node installation found on this server -- run setup-node.sh"
        fi
        print_error "No Telcoin node installation found on this server."
        print_info "Re-run setup-node.sh"
        exit 1
    }
    if [[ -z "$RPC_URL" ]]; then
        local rpc_port rc=0
        rpc_port="$(meta_get RPC_PORT 2>/dev/null)" || rc=$?
        if [[ $rc -eq 2 ]]; then
            # Two RPC_PORT lines: guessing one could probe (and later restart against)
            # the wrong port.
            if [[ "$JSON_MODE" == "true" ]]; then
                json_event error "RPC_PORT is set more than once in .node-meta; remove the extra lines and run again"
            fi
            print_error "RPC_PORT is set more than once in .node-meta; remove the extra lines and run again."
            exit 1
        fi
        [[ -n "$rpc_port" ]] || rpc_port="$DEFAULT_RPC_PORT"
        RPC_URL="http://127.0.0.1:${rpc_port}"
    fi
}

# Read INSTALL_METHOD from .node-meta (meta_get: CRLF-safe). Prints "source",
# "docker", "existing" or the stored value; nothing and rc 0 when there is no
# .node-meta or no such key; nothing and rc 2 when the key is listed more than
# once (meta_get has said so on stderr), so the caller stops instead of guessing.
detect_install_method() {
    local v rc=0
    v="$(meta_get INSTALL_METHOD)" || rc=$?
    case "$rc" in
        0) printf '%s\n' "$v" ;;
        1) ;;
        *) return 2 ;;
    esac
    return 0
}

# existing_binary_path -- the binary an `existing` install runs: the path in the
# node command of its launch file (tn_launch_runner, lib/common.sh 1.6.0), else
# BINARY_PATH from .node-meta (recorded by setup-node 1.3.0), else the source
# build's path, which older installs used.
existing_binary_path() {
    local spec="" path="" rc
    if declare -F tn_launch_runner >/dev/null 2>&1; then
        spec="$(tn_launch_runner 2>/dev/null || true)"
    fi
    case "$spec" in
        binary:/*) path="${spec#binary:}" ;;
    esac
    if [[ -z "$path" ]]; then
        rc=0
        path="$(meta_get BINARY_PATH 2>/dev/null)" || rc=$?
        if [[ "$rc" -eq 2 ]]; then
            # Two BINARY_PATH lines: name neither, and never fall back to the
            # default path, which may not be the file this node runs.
            print_error "BINARY_PATH is set more than once in $(node_meta_path 2>/dev/null || echo .node-meta); remove the extra lines first." >&2
            printf '%s\n' "<the binary this node runs: fix BINARY_PATH in .node-meta>"
            return 2
        fi
        [[ "$path" == /* ]] || path=""
    fi
    if [[ -z "$path" ]]; then
        path="${DEFAULT_INSTALL_DIR}/telcoin-network"
    fi
    printf '%s\n' "$path"
}

# existing_update_refusal -- refuse an `existing` install, whose binary this
# script does not replace, and say how to update it by hand: stop the node,
# replace the file it runs, start it again; or replace the file while it runs
# and restart through edit-config.sh, which waits for the epoch boundary. An
# error event in --json mode, [ERROR] and info lines otherwise. The caller
# exits or returns 1.
existing_update_refusal() {
    local path svc
    path="$(existing_binary_path)"
    svc="${SERVICE_NAME:-telcoin}"
    if [[ "$JSON_MODE" == "true" ]]; then
        json_event error "install method 'existing': this node runs ${path}, which update-node.sh does not replace. To update it, stop the node, replace that file with the new release binary and start the node again (systemctl stop ${svc}; install -m 0755 <new binary> ${path}; systemctl start ${svc}). On a committee node, run only the install step while the node runs, then restart with edit-config.sh, menu item 12 (Restart node), which waits for the epoch boundary."
        return 0
    fi
    print_error "Install method is 'existing': this node runs ${path}, which update-node.sh does not replace."
    print_info "To update it, stop the node, replace that file with the new release binary, and start it again:"
    print_info "  sudo systemctl stop ${svc}"
    print_info "  sudo install -m 0755 <new binary> ${path}"
    print_info "  sudo systemctl start ${svc}"
    print_info "On a committee node, run only the install line instead (it replaces the file while the"
    print_info "node runs), then restart with edit-config.sh, menu item 12 (Restart node), which waits"
    print_info "for the epoch boundary: sudo bash ~/telcoin-node-scripts/edit-config.sh"
}

# detect_network -- print testnet or mainnet: NETWORK in .node-meta (CRLF-safe),
# else the chain id of the node's genesis (487 mainnet, 2017 testnet). A thin
# wrapper over tn_detect_network (lib/common.sh), kept for its callers. Prints
# nothing and returns 1 when the network cannot be told: a NETWORK listed more
# than once, any other value (devnet, a typo, empty), or no NETWORK and no known
# chain id. The reason goes to stderr, so --json stdout stays clean.
detect_network() {
    tn_detect_network
}

# Resolve the file that carries the docker image reference on this install:
# the start wrapper (${DEFAULT_INSTALL_DIR}/start-<svc>.sh) on current installs
# (the BLS LoadCredential change moved `docker run` out of the unit's ExecStart),
# or the systemd unit on legacy installs that still inline it. Delegates to
# tn_node_launch_target (lib/common.sh). Echoes the path; returns 1 if no node
# service is present or the file is missing.
docker_launch_file() {
    local line file
    line="$(tn_node_launch_target)" || return 1
    file="${line##* }"   # last field; install paths never contain spaces
    [[ -f "$file" ]] || return 1
    echo "$file"
}

detect_current_docker_image() {
    local file
    file="$(docker_launch_file)" || return 1
    grep -oE 'us-docker[^ ]+|gcr\.io[^ ]+|ghcr\.io[^ ]+' "$file" | head -1
}

# git describe-style summary of the current source ref + commit
detect_current_source_ref() {
    [[ -d "${TN_SOURCE_DIR}/.git" ]] || return 1
    git -C "$TN_SOURCE_DIR" describe --tags --always --dirty 2>/dev/null || \
        git -C "$TN_SOURCE_DIR" rev-parse --short HEAD 2>/dev/null
}

# =============================================================================
# PENDING-STATE FILE
# <config_dir>/.pending-update
# =============================================================================

pending_state_path() {
    echo "$(tn_resolve_config_dir)/.pending-update"
}

# pending_key_check KEY VALUE -- rc 0 when KEY is a key this script writes into
# the pending state and VALUE has that key's shape; rc 1 when VALUE does not;
# rc 3 when KEY is not one of them. Image references must pass
# validate_docker_image, refs and paths are plain words, hashes are 64 hex
# digits. Prints nothing.
pending_key_check() {
    local k="${1:-}" v="${2-}" re
    case "$k" in
        PHASE)
            [[ "$v" == "pull_complete" || "$v" == "build_complete" ]] ;;
        INSTALL_METHOD)
            [[ "$v" == "source" || "$v" == "docker" ]] ;;
        OLD_IMAGE)
            # The running image: its shape only (it may predate the release rule).
            tn_docker_ref_ok "$v" ;;
        NEW_IMAGE)
            [[ "$v" != -* ]] && validate_docker_image "$v" ;;
        PULLED_IMAGE_ID)
            re='^(sha256:[0-9a-f]{64})?$'
            [[ "$v" =~ $re ]] ;;
        OLD_REF)
            re='^[A-Za-z0-9._/+=@~^-]*$'
            [[ "$v" =~ $re ]] ;;
        NEW_REF)
            re='^[A-Za-z0-9._/+=@~^-]+$'
            [[ "$v" != -* && "$v" =~ $re ]] ;;
        NEW_VERSION)
            # Shown to the operator only; no control characters.
            [[ "$v" != *[[:cntrl:]]* ]] ;;
        BUILT_BINARY|BIN_BACKUP|UNIT_BACKUP|UNIT_FILE)
            re='^/[A-Za-z0-9._/+=-]+$'
            [[ "$v" =~ $re ]] ;;
        BUILT_HASH|BIN_BACKUP_SHA256|UNIT_BACKUP_SHA256)
            re='^[0-9a-f]{64}$'
            [[ "$v" =~ $re ]] ;;
        PREPARED_AT)
            re='^[0-9TZ:-]+$'
            [[ "$v" =~ $re ]] ;;
        *)
            return 3 ;;
    esac
}

# pending_parse -- read pending-state text on stdin and print its checked
# KEY=value lines. Data only: nothing is sourced or evaluated. One trailing CR
# per line is dropped and blank lines are skipped. A line that is not
# KEY=value with KEY matching ^[A-Z][A-Z0-9_]*$, or whose key this script
# does not write, is skipped with a warning. A known key with a malformed
# value, or a key on more than one line, refuses the whole state (rc 1,
# nothing printed). Values are never echoed in the messages.
pending_parse() {
    local line key val seen=" " out="" cr nl re
    cr=$'\r'
    nl=$'\n'
    re='^[A-Z][A-Z0-9_]*='
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%"$cr"}"
        [[ -n "$line" ]] || continue
        if [[ ! "$line" =~ $re ]]; then
            print_warn "pending state: skipping a line that is not KEY=value" >&2
            continue
        fi
        key="${line%%=*}"
        val="${line#*=}"
        pending_key_check "$key" "$val"
        case "$?" in
            0) ;;
            3)
                print_warn "pending state: ignoring unknown key ${key}" >&2
                continue
                ;;
            *)
                print_warn "pending state: ${key} has a malformed value; refusing the pending update" >&2
                return 1
                ;;
        esac
        case "$seen" in
            *" ${key} "*)
                print_warn "pending state: ${key} is listed more than once; refusing the pending update" >&2
                return 1
                ;;
        esac
        seen="${seen}${key} "
        out="${out}${key}=${val}${nl}"
    done
    printf '%s' "$out"
}

# read_pending_state -- print the pending state's checked KEY=value lines (see
# pending_parse). The file must be a regular file, not a symlink, owned by root
# and writable by root only, in a directory that passes tn_root_dir_ok;
# anything else is refused with the reason on stderr (rc 1). rc 1 and no
# message when there is no pending state.
read_pending_state() {
    local path st mode
    path="$(pending_state_path)"
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        return 1
    fi
    if [[ -L "$path" || ! -f "$path" ]]; then
        print_warn "Refusing the pending update ${path}: it is a symlink or not a regular file. Discard it (--discard) and prepare again." >&2
        return 1
    fi
    st="$(stat -c '%u %a' -- "$path" 2>/dev/null)" || st=""
    mode="${st##* }"
    case "$mode" in
        ""|*[!0-7]*|*[2367]?|*[2367]) mode="" ;;
    esac
    if [[ "${st%% *}" != "0" || -z "$mode" ]] || ! tn_root_dir_ok "${path%/*}"; then
        print_warn "Refusing the pending update ${path}: it must be owned by root, writable by root only, in a root-owned directory. Discard it (--discard) and prepare again." >&2
        return 1
    fi
    pending_parse < "$path"
}

# pending_field STATE KEY -- print KEY's value from STATE (read_pending_state
# output). rc 1 when KEY is absent.
pending_field() {
    local line
    while IFS= read -r line; do
        if [[ "${line%%=*}" == "${2:-}" ]]; then
            printf '%s\n' "${line#*=}"
            return 0
        fi
    done <<< "${1:-}"
    return 1
}

# write_pending_state -- replace the pending state with the KEY=value lines on
# stdin, root 0600, through tn_write_root_file (temp file and rename; a symlink
# in its place is refused, not followed). The lines pass pending_parse first,
# so the file never holds what read_pending_state would refuse. Returns
# non-zero when the state cannot be written (a refused directory, a full or
# read-only disk); callers must check -- reporting "pending update saved" on a
# write failure would strand the operator with a prepare they cannot apply.
write_pending_state() {
    local state
    state="$(pending_parse)" || return 1
    # A here-string, not a pipe: the write runs in this shell, never in a subshell
    # that could outlive a signal that ends the run (and the lock with it).
    tn_write_root_file "$(pending_state_path)" 0600 <<< "$state"
}

# pending_state_add KEY=VALUE... -- set these keys in the pending state (an
# earlier value of the same key is replaced) and write it back. rc 1 when the
# state cannot be read or written.
pending_state_add() {
    local state line kv keep out="" nl
    nl=$'\n'
    state="$(read_pending_state)" || return 1
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        keep=true
        for kv in "$@"; do
            if [[ "${line%%=*}" == "${kv%%=*}" ]]; then
                keep=false
            fi
        done
        if [[ "$keep" == "true" ]]; then
            out="${out}${line}${nl}"
        fi
    done <<< "$state"
    for kv in "$@"; do
        out="${out}${kv}${nl}"
    done
    write_pending_state <<< "$out"
}

# clear_pending_state -- remove the pending state (a symlink in its place too;
# rm removes the link, never its target).
clear_pending_state() {
    local path
    path=$(pending_state_path)
    if [[ -e "$path" || -L "$path" ]]; then
        rm -f -- "$path"
    fi
}

# =============================================================================
# HEALTH VERIFY (post-restart)
# =============================================================================

wait_for_service_stopped() {
    local unit="$1"
    local timeout="${2:-30}"
    local waited=0
    # 9>&-: a stop can block for the unit's stop timeout (see update_lock).
    systemctl stop "$unit" 9>&- 2>/dev/null || true
    while systemctl is-active --quiet "$unit" 2>/dev/null; do
        if (( waited >= timeout )); then
            print_warn "${unit} did not stop within ${timeout}s -- forcing kill"
            systemctl kill -s SIGKILL "$unit" 2>/dev/null || true
            sleep 2
            return
        fi
        sleep 1
        (( ++waited ))
    done
}

# Start the service after clearing any leftover failed state and the
# start-rate-limit counter. The unit sets StartLimitBurst=5 / 60s with
# Restart=on-failure; a failed update + rollback can stop/start the service
# enough times to trip that limit, after which `systemctl start` is refused
# and the node stays down even with a good binary. reset-failed (a no-op when
# nothing is wrong) prevents that.
start_service() {
    systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
    systemctl start "$SERVICE_NAME"
}

# Backups (unit or start script, and the installed binary) go to the root-only
# backup directory through tn_backup_file, never beside the live file. Each
# backup's path and sha256 are recorded in the pending state, and a restore
# goes through tn_restore_backup, which refuses a backup that no longer
# matches its sha256 and leaves the live file as it is.
UNIT_BK_PATH=""
UNIT_BK_SHA256=""
UNIT_BK_MODE=""
UNIT_BK_GROUP=""
BIN_BK_PATH=""
BIN_BK_SHA256=""

# backup_unit_file FILE -- back up a launch file (the unit or the start script)
# before an apply edits it, and record UNIT_FILE, UNIT_BACKUP and
# UNIT_BACKUP_SHA256 in the pending state. Sets UNIT_BK_PATH, UNIT_BK_SHA256
# and FILE's mode and group (UNIT_BK_MODE, UNIT_BK_GROUP) for
# restore_unit_file. Call it directly, not in $( ). rc 1 with a message on
# stderr when the copy or the record fails.
backup_unit_file() {
    local file="${1:-}" st out
    UNIT_BK_PATH=""
    UNIT_BK_SHA256=""
    UNIT_BK_MODE=""
    UNIT_BK_GROUP=""
    st="$(stat -c '%a %G' -- "$file" 2>/dev/null)" || st=""
    if [[ -z "$st" ]] || ! out="$(tn_backup_file "$file")"; then
        print_warn "Could not back up ${file}" >&2
        return 1
    fi
    if ! pending_state_add "UNIT_FILE=${file}" "UNIT_BACKUP=${out% *}" "UNIT_BACKUP_SHA256=${out##* }"; then
        print_warn "Could not record the backup of ${file} in the pending update" >&2
        rm -f -- "${out% *}"
        return 1
    fi
    UNIT_BK_PATH="${out% *}"
    UNIT_BK_SHA256="${out##* }"
    UNIT_BK_MODE="${st%% *}"
    UNIT_BK_GROUP="${st##* }"
    print_info "Launch config backup: ${UNIT_BK_PATH}" >&2
    return 0
}

# restore_unit_file FILE -- put FILE back from the backup_unit_file copy, with
# its old mode and group. Refused (rc 1, FILE unchanged) when the copy no
# longer matches its sha256.
restore_unit_file() {
    tn_restore_backup "$UNIT_BK_PATH" "$UNIT_BK_SHA256" "${1:-}" "$UNIT_BK_MODE" "$UNIT_BK_GROUP"
}

# backup_installed_binary FILE -- back up the installed binary before an apply
# replaces it, and record BIN_BACKUP and BIN_BACKUP_SHA256 in the pending
# state. Sets BIN_BK_PATH and BIN_BK_SHA256. Call it directly, not in $( ).
# rc 1 with a message on stderr when the copy or the record fails.
backup_installed_binary() {
    local file="${1:-}" out
    BIN_BK_PATH=""
    BIN_BK_SHA256=""
    if ! out="$(tn_backup_file "$file")"; then
        print_warn "Could not back up ${file}" >&2
        return 1
    fi
    if ! pending_state_add "BIN_BACKUP=${out% *}" "BIN_BACKUP_SHA256=${out##* }"; then
        print_warn "Could not record the backup of ${file} in the pending update" >&2
        rm -f -- "${out% *}"
        return 1
    fi
    BIN_BK_PATH="${out% *}"
    BIN_BK_SHA256="${out##* }"
    return 0
}

# restore_installed_binary FILE -- put the backup_installed_binary copy back as
# FILE, root:root 0755. Refused (rc 1, FILE unchanged) when the copy no longer
# matches its sha256.
restore_installed_binary() {
    tn_restore_backup "$BIN_BK_PATH" "$BIN_BK_SHA256" "${1:-}" 0755 root
}

# unit_restore_hint FILE / binary_restore_hint FILE -- the shell line an
# operator runs to put a backup back by hand: check its sha256, then install
# it with the right owner and mode.
unit_restore_hint() {
    printf "echo '%s  %s' | sha256sum -c - && install -o root -g %s -m %s %s %s" \
        "$UNIT_BK_SHA256" "$UNIT_BK_PATH" "$UNIT_BK_GROUP" "$UNIT_BK_MODE" "$UNIT_BK_PATH" "${1:-}"
}
binary_restore_hint() {
    printf "echo '%s  %s' | sha256sum -c - && install -o root -g root -m 0755 %s %s" \
        "$BIN_BK_SHA256" "$BIN_BK_PATH" "$BIN_BK_PATH" "${1:-}"
}

# apply_root_dir_refusal FILE -- rc 0, with the reason on stdout, when FILE's
# directory is not one tn_root_dir_ok accepts, so the root writes of an apply
# would be refused. Checked before the node is stopped.
apply_root_dir_refusal() {
    local dir="${1%/*}"
    [[ -n "$dir" ]] || dir=/
    if tn_root_dir_ok "$dir"; then
        return 1
    fi
    printf '%s\n' "${dir} (holding ${1}) is not a root-owned directory that only root can write, so ${1} cannot be replaced safely. Nothing was stopped or changed."
    return 0
}

# observer_strip_needed <file> <target text...> -- rc 0 when the launch file
# <file> still passes the retired --observer flag AND the update target (a tag,
# image or version string; see tn_target_drops_observer) no longer accepts it.
# v0.15.0-adiri takes the flag as a hidden no-op and later releases refuse to
# start with it, so the apply paths strip it before restarting. No output.
observer_strip_needed() {
    local file="${1:-}"
    shift
    [[ -n "$file" ]] || return 1
    tn_target_drops_observer "$@" || return 1
    tn_node_has_observer_flag "$file"
}

# =============================================================================
# ONE-WAY STORAGE MIGRATION (v0.16.0 and later)
#
# The first start of v0.16.0 or later migrates the consensus store
# (<data_dir>/consensus-db/epochs, epoch packs v1 -> v2) and older releases
# cannot open it afterwards. Swapping the binary or image back is then no
# rollback, so an update across that line warns first, waits longer for the
# first start, and never rolls back on its own: only a data dir snapshot taken
# before the update can undo it.
# =============================================================================

# installed_source_ref -- the ref of the source binary that runs now, from the
# marker that setup and verified applies write (write_source_version_marker).
# Empty when there is none: setup and verified applies have written it since
# well before v0.16.0, so a node without one runs an older release. `git
# describe` of the checkout is no use here: a prepare moves the checkout while
# the old binary keeps running. The marker is read only when it is a regular
# root-owned file (not a symlink) and its first line is a plain ref word;
# anything else reads as no marker.
installed_source_ref() {
    local f="${DEFAULT_INSTALL_DIR}/telcoin-network.version" ref re
    re='^[A-Za-z0-9._/+=@~^-]+$'
    [[ -f "$f" && ! -L "$f" ]] || return 0
    [[ "$(stat -c '%u' -- "$f" 2>/dev/null)" == "0" ]] || return 0
    ref="$(head -n 1 -- "$f" 2>/dev/null)" || ref=""
    if [[ "$ref" =~ $re ]]; then
        printf '%s\n' "$ref"
    fi
    return 0
}

# storage_migrating_upgrade <running> <target> -- rc 0 when going from <running>
# to <target> crosses STORAGE_MIGRATION_FLOOR one way: the target is at or above
# it (no x.y.z, such as a branch or a commit, counts as newest) and the running
# release is below it (no x.y.z counts as unknown, and so as older). Each side is
# judged on its first x.y.z, so pass docker images as name:tag (${image##*/}) or
# a registry host:port would be read as a version.
storage_migrating_upgrade() {
    local ver_re run_v new_v
    ver_re='([0-9]+\.[0-9]+\.[0-9]+)'
    run_v=""
    new_v=""
    if [[ "${2:-}" =~ $ver_re ]]; then
        new_v="${BASH_REMATCH[1]}"
    fi
    if [[ -n "$new_v" ]] && ! version_gte "$new_v" "$STORAGE_MIGRATION_FLOOR"; then
        return 1
    fi
    if [[ "${1:-}" =~ $ver_re ]]; then
        run_v="${BASH_REMATCH[1]}"
    fi
    [[ -n "$run_v" ]] || return 0
    ! version_gte "$run_v" "$STORAGE_MIGRATION_FLOOR"
}

# update_verify_window -- the post-restart health window in seconds: an explicit
# TN_UPDATE_VERIFY_TIMEOUT, else STORAGE_MIGRATION_VERIFY_SECONDS on a one-way
# update, else 45.
update_verify_window() {
    if [[ "$STORAGE_MIGRATION" == "true" && "$VERIFY_TIMEOUT_EXPLICIT" != "true" ]]; then
        printf '%s\n' "$STORAGE_MIGRATION_VERIFY_SECONDS"
    else
        printf '%s\n' "$VERIFY_TIMEOUT_SECONDS"
    fi
}

# storage_migration_space_shortfall <data_dir> -- rc 0 with one line on stdout
# when the free space under <data_dir>/consensus-db/epochs is less than twice
# its largest epoch-N directory: the migration writes each pack again beside
# the old one (epoch-N.migrating) before it swaps them. Leftover epoch-N.* dirs
# are not counted. rc 1 when there is enough room or it cannot tell. A warning
# only: du is an estimate, and past epochs migrate later, while the node runs.
storage_migration_space_shortfall() {
    local epochs largest_kb avail_kb
    [[ -n "${1:-}" ]] || return 1
    epochs="${1}/consensus-db/epochs"
    [[ -d "$epochs" ]] || return 1
    largest_kb="$(du -sk "$epochs"/epoch-* 2>/dev/null | awk -F '\t' '$2 ~ /\/epoch-[0-9]+$/ && $1 > m { m = $1 } END { print m + 0 }')"
    avail_kb="$(df -Pk "$epochs" 2>/dev/null | awk 'NR == 2 { print $4 }')"
    [[ "$largest_kb" =~ ^[0-9]+$ && "$avail_kb" =~ ^[0-9]+$ ]] || return 1
    (( largest_kb > 0 && avail_kb < 2 * largest_kb )) || return 1
    printf 'Low disk: %s MiB free under %s; the migration needs at least %s MiB (twice the largest epoch-N).\n' \
        "$(( avail_kb / 1024 ))" "$epochs" "$(( largest_kb * 2 / 1024 ))"
}

# storage_migration_begin <running> <target> -- called by every apply path
# before it stops the node, and by the --json prepare paths before their done
# event. Sets STORAGE_MIGRATION. On a one-way update it warns (and warns about
# low disk); in interactive mode it then asks the operator to confirm they have
# a snapshot. rc 1 only when the operator declines; the prepared update is kept.
storage_migration_begin() {
    local dd short
    STORAGE_MIGRATION=false
    storage_migrating_upgrade "${1:-}" "${2:-}" || return 0
    STORAGE_MIGRATION=true
    dd="$(tn_resolve_data_dir 2>/dev/null || true)"
    update_wait_say warn "One-way update: ${2:-the new release} migrates the consensus store in ${dd:-the data dir} on its first start, and older releases cannot open it afterwards. Only a snapshot of the data dir taken before the update can undo it, so a failed health check will not roll back. The health check waits up to $(update_verify_window)s."
    if short="$(storage_migration_space_shortfall "$dd")"; then
        update_wait_say warn "$short"
    fi
    [[ "$JSON_MODE" == "true" ]] && return 0
    if ! confirm "Do you have a snapshot of ${dd:-the data dir}, and do you want this one-way update?"; then
        print_info "Cancelled. The prepared update is kept."
        return 1
    fi
    return 0
}

# storage_migration_verify_failed <target> <undo-cmd> -- the end of a one-way
# apply whose post-restart check failed. No rollback: the previous release
# cannot open the migrated data dir. The node is left running (it may still be
# migrating), the pending state is cleared, and the version marker keeps the
# previous ref until a verified apply. Prints how to go back; in --json mode an
# error event and then the done event. Always rc 1.
storage_migration_verify_failed() {
    local dd what state msg
    dd="$(tn_resolve_data_dir 2>/dev/null || true)"
    state="The node was left running and may still be migrating"
    if ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        state="The node is not running; it may have stopped before or during the migration"
    fi
    clear_pending_state
    if [[ "$UPDATE_HEALTH_OK" == "true" ]]; then
        what="${SERVICE_NAME} answered after starting ${1}, but it is not running the prepared update."
    else
        what="${SERVICE_NAME} did not answer within $(update_verify_window)s of starting ${1}."
    fi
    msg="${what} Not rolled back: the previous release cannot open the migrated data dir. ${state} (journalctl -u ${SERVICE_NAME} -f). To go back: systemctl stop ${SERVICE_NAME}; restore ${dd:-the data dir} from the pre-update snapshot; ${2}; systemctl start ${SERVICE_NAME}."
    if [[ "$JSON_MODE" == "true" ]]; then
        json_event error "$msg"
        json_emit "{\"event\":\"done\",\"ok\":false,\"phase\":\"apply\",\"rolled_back\":false,\"storage_migration\":true,\"msg\":\"$(json_escape "$msg")\"}"
    else
        print_error "$msg"
    fi
    return 1
}

# Returns 0 if service is active AND tn_latestConsensusHeader responds within
# update_verify_window seconds; non-zero otherwise. Records the answer in
# UPDATE_HEALTH_OK. A rollback restart gets the normal window: STORAGE_MIGRATION
# is never true when one runs.
verify_health_after_restart() {
    print_step "Verifying node health..."
    local waited=0 limit
    limit="$(update_verify_window)"
    UPDATE_HEALTH_OK=false
    while (( waited < limit )); do
        if ! systemctl is-active --quiet "$SERVICE_NAME"; then
            print_warn "  Service not active yet (${waited}s)..."
            sleep 3
            waited=$(( waited + 3 ))
            continue
        fi
        local resp
        resp=$(curl -sS --connect-timeout 3 --max-time 5 -X POST \
            -H 'Content-Type: application/json' \
            --data '{"jsonrpc":"2.0","method":"tn_latestConsensusHeader","params":[],"id":1}' \
            "$RPC_URL" 2>/dev/null || echo "")
        if echo "$resp" | grep -q '"result"'; then
            print_ok "Service active and consensus RPC responding (${waited}s)"
            UPDATE_HEALTH_OK=true
            return 0
        fi
        sleep 3
        waited=$(( waited + 3 ))
    done
    print_error "Service did not become healthy within ${limit}s"
    return 1
}

# The plain health probe above passes even when the node came back on the OLD
# artifact (no-op swap, stale unit definition after a failed daemon-reload,
# ...). The two checks below pin the post-APPLY verify to the artifact that
# prepare produced. Rollback verifies deliberately stay on the plain probe --
# after a rollback the old artifact is exactly what should be running.
# Both checks SKIP (warn, return 0) when the expected value is missing, so a
# pending state written by an older script version still applies cleanly.

# Source installs: the installed binary must hash to BUILT_HASH.
verify_installed_binary_hash() {
    local installed="$1" expected="$2"
    if [[ -z "$expected" ]]; then
        print_warn "No BUILT_HASH in pending state -- skipping binary identity check."
        return 0
    fi
    local actual
    actual=$(sha256sum "$installed" 2>/dev/null | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        print_error "Installed binary does not match the prepared build."
        print_info "  Expected: ${expected}"
        print_info "  Actual:   ${actual:-unreadable}"
        return 1
    fi
    print_ok "Installed binary matches the prepared build (${expected:0:12}...)"
}

# Docker installs: container name as launched (--name in the wrapper/unit;
# setup writes --name ${SERVICE_NAME}, so that is also the fallback).
docker_container_name() {
    local file name=""
    if file=$(docker_launch_file 2>/dev/null); then
        name=$(grep -oE -- '--name[= ][^ \\]+' "$file" 2>/dev/null | head -1 | sed -E 's/^--name[= ]//')
    fi
    echo "${name:-$SERVICE_NAME}"
}

# Docker installs: the running container's image ID must match the ID recorded
# at pull time (PULLED_IMAGE_ID). Catches "came back on the old image", e.g. a
# legacy unit install whose daemon-reload failed and restarted the stale unit.
verify_running_image_id() {
    local expected_id="$1"
    if [[ -z "$expected_id" ]]; then
        print_warn "No PULLED_IMAGE_ID in pending state -- skipping image identity check."
        return 0
    fi
    local cname running_id
    cname=$(docker_container_name)
    running_id=$(docker inspect --format '{{.Image}}' "$cname" 2>/dev/null || echo "")
    if [[ -z "$running_id" ]]; then
        # Health verify already passed, so the container is up; an empty read
        # here is a docker CLI hiccup -- do not trigger a false rollback.
        print_warn "Could not inspect container '${cname}' -- skipping image identity check."
        return 0
    fi
    if [[ "$running_id" != "$expected_id" ]]; then
        print_error "Running container image does not match the pulled update."
        print_info "  Expected: ${expected_id}"
        print_info "  Running:  ${running_id}"
        return 1
    fi
    print_ok "Running container is on the pulled image (${expected_id:0:19}...)"
}

# =============================================================================
# EPOCH WAIT
# =============================================================================

# update_wait_say <step|log|warn> <msg> -- progress printer for
# tn_wait_restart_window: a JSON event of the same name in --json mode, a
# print_* line otherwise.
update_wait_say() {
    if [[ "$JSON_MODE" == "true" ]]; then
        case "${1:-}" in
            step|warn) json_event "$1" "${2:-}" ;;
            *)         json_event log "${2:-}" ;;
        esac
    else
        case "${1:-}" in
            step) print_step "${2:-}" ;;
            warn) print_warn "${2:-}" ;;
            *)    print_info "${2:-}" ;;
        esac
    fi
    return 0
}

# update_quorum_guard -- the committee check before a stop (tn_committee_down_guard):
# rc 1 (with the reason) when stopping this node now would leave the committee one
# member short of a halt, or the count cannot be made on a staked mainnet node.
# --allow-quorum-risk (TN_ALLOW_QUORUM_RISK=1) overrides for a coordinated restart.
update_quorum_guard() {
    local rc=0
    if ! declare -F tn_committee_down_guard >/dev/null 2>&1; then
        update_wait_say warn "lib/common.sh ${COMMON_VERSION:-unknown} has no committee quorum check; run update-scripts.sh to get it."
        return 0
    fi
    tn_committee_down_guard "$(tn_local_rpc_url)" update_wait_say || rc=$?
    if [[ $rc -ne 0 ]]; then
        update_wait_say warn "Not stopping ${SERVICE_NAME}: the committee check refused it. Nothing was changed on the running node; run again later, or with --allow-quorum-risk for a coordinated restart."
        return 1
    fi
    return 0
}

# update_node_log_dir -- an observability host set up before NODE_LOG_DIR still
# points the node's JSON logs (--log.file.directory) at the root-owned log dir,
# which the node can no longer write. Binary installs only: point the flag at
# NODE_LOG_DIR (default <log dir>/node; created <service user>:telcoin-log 0750
# inside the root-owned log dir) and record the key, so the unit written next
# lists the directory in ReadWritePaths=. Called while the node is stopped; a
# failure warns and changes nothing more.
update_node_log_dir() {
    local file line cur want user rc=0
    [[ "$(meta_get ENABLE_OBSERVABILITY 2>/dev/null || true)" == "true" ]] || return 0
    line="$(tn_node_launch_target 2>/dev/null)" || return 0
    file="${line##* }"
    [[ "$(_tn_launch_awk runner "$file" 2>/dev/null)" == binary\ * ]] || return 0
    cur="$(tn_launch_flag_get "$file" --log.file.directory 2>/dev/null)" || return 0
    [[ "${cur%/}" == "$DEFAULT_LOG_DIR" ]] || return 0
    want="$(meta_get NODE_LOG_DIR 2>/dev/null || true)"
    [[ -n "$want" ]] || want="${DEFAULT_LOG_DIR}/node"
    user="$(meta_get HOST_SERVICE_USER 2>/dev/null || true)"
    user="${user:-$SERVICE_USER}"
    if [[ "$want" != /* || -L "$want" ]] || ! tn_root_dir_ok "${want%/*}" \
        || ! getent group telcoin-log >/dev/null 2>&1 \
        || ! install -d -o "$user" -g telcoin-log -m 0750 -- "$want"; then
        update_wait_say warn "Could not prepare the node log dir ${want}; the node's JSON logs stay pointed at ${DEFAULT_LOG_DIR}, which it cannot write (re-enable observability to fix it)."
        return 0
    fi
    tn_launch_flag_set "$file" --log.file.directory "$want" >/dev/null 2>&1 || rc=$?
    if [[ $rc -gt 1 ]]; then
        update_wait_say warn "Could not point --log.file.directory at ${want} in ${file}; set it by hand."
        return 0
    fi
    meta_set NODE_LOG_DIR "$want" >/dev/null 2>&1 \
        || update_wait_say warn "Could not record NODE_LOG_DIR=${want} in .node-meta."
    update_wait_say log "The node's JSON logs now go to ${want}."
    return 0
}

# update_rerender_launch -- while the node is stopped, rewrite its start script and
# unit in the current form (tn_rerender_node_launch: the passphrase on stdin from
# the systemd credential, the unit sandbox) and reload systemd. A refusal or a
# failed write warns and leaves the files the node ran with; the update goes on.
update_rerender_launch() {
    local rc=0
    declare -F tn_rerender_node_launch >/dev/null 2>&1 || return 0
    update_node_log_dir
    tn_rerender_node_launch "" update_wait_say || rc=$?
    if [[ $rc -eq 0 ]]; then
        systemctl daemon-reload 9>&- || update_wait_say warn "systemctl daemon-reload failed; ${SERVICE_NAME} may start with its previous unit."
    else
        update_wait_say warn "The start script and unit of ${SERVICE_NAME} were not rewritten in the current form (see above); it starts with the files it ran with."
    fi
    return 0
}

# update_epoch_wait -- called by each apply path just before it stops the node,
# after the lock is held and the new binary or image is ready, and never before
# a rollback restart. When the node votes in the current committee and the
# epoch boundary is close, tn_wait_restart_window (lib/common.sh) holds the stop
# until the epoch has closed and settled, at most TN_EPOCH_WAIT_MAX seconds.
# --no-epoch-wait or TN_SKIP_EPOCH_WAIT=1 skips the wait, never the committee
# check before it (update_quorum_guard), which is the only way it returns 1.
update_epoch_wait() {
    update_quorum_guard || return 1
    if [[ "$NO_EPOCH_WAIT" == "true" ]]; then
        update_wait_say log "Not waiting for the epoch boundary (--no-epoch-wait)."
        return 0
    fi
    if [[ "${TN_SKIP_EPOCH_WAIT:-}" == "1" ]]; then
        update_wait_say log "Not waiting for the epoch boundary (TN_SKIP_EPOCH_WAIT=1)."
        return 0
    fi
    declare -F tn_wait_restart_window >/dev/null 2>&1 || {
        update_wait_say warn "lib/common.sh ${COMMON_VERSION:-unknown} cannot wait for the epoch boundary, so the node restarts now even if it is in the committee. Run update-scripts.sh to get the wait."
        return 0
    }
    tn_wait_restart_window "$(tn_local_rpc_url)" update_wait_say
    return 0
}

# =============================================================================
# DOCKER PATH
# =============================================================================

fetch_docker_tags() {
    # The heredoc below IS python3's stdin (its program source), so the tag JSON
    # cannot also arrive on stdin -- the old `curl ... | python3 <<EOF` fed the
    # script to itself and always returned nothing (SC2259). Pass the payload via
    # the environment instead: keeps the readable heredoc and parses for real.
    TN_TAGS_JSON="$(curl -sS --max-time 5 "$GAR_TAGS_URL" 2>/dev/null)" python3 <<'PYEOF' 2>/dev/null
import json, os, re
try:
    d = json.loads(os.environ.get('TN_TAGS_JSON', ''))
    tags = d.get('tags', [])
    parsed = []
    for t in tags:
        m = re.match(r'^v(\d+)\.(\d+)\.(\d+)(?:-(.+))?$', t)
        if m:
            parsed.append((tuple(int(x) for x in m.groups()[:3]), m.group(4) or '', t))
    parsed.sort()
    for _, _, tag in parsed[-15:]:
        print(tag)
except Exception:
    pass
PYEOF
}

# Compose the full image URL given a current image (with registry path) and a new tag.
compose_image_url() {
    local current_image="$1"
    local new_tag="$2"
    echo "${current_image%:*}:${new_tag}"
}

prepare_docker_update() {
    local new_image="$1"
    print_header "Prepare Update -- Docker Install"

    local current_image
    if ! validate_docker_image "$new_image"; then
        print_error "Image refused: ${new_image} is not this network's repository by digest or by a release tag."
        return 1
    fi
    current_image=$(detect_current_docker_image) || {
        print_error "Could not read current Docker image from the ${SERVICE_NAME} launch config (wrapper or unit)"
        return 1
    }
    print_info "Current image: ${current_image}"
    print_info "Target image:  ${new_image}"
    echo ""
    if ! confirm "Proceed with the pull?"; then
        print_info "Cancelled."
        return 1
    fi

    local current_tag="${current_image##*:}"
    print_step "Pulling image: ${new_image}"
    # 9>&-: the pull must not hold the update lock (see update_lock).
    if ! docker pull "$new_image" 9>&-; then
        print_error "Image pull failed. Service untouched."
        return 1
    fi
    print_ok "Image pulled. Service still running on ${current_tag}."

    # Image ID of what we just pulled -- apply verifies the restarted
    # container is actually running THIS image, not merely "something healthy".
    local pulled_image_id
    pulled_image_id=$(docker image inspect --format '{{.Id}}' "$new_image" 2>/dev/null || echo "")

    if ! write_pending_state <<EOF
PHASE=pull_complete
INSTALL_METHOD=docker
OLD_IMAGE=${current_image}
NEW_IMAGE=${new_image}
PULLED_IMAGE_ID=${pulled_image_id}
PREPARED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
    then
        print_error "Could not write pending state at $(pending_state_path)"
        return 1
    fi
    print_ok "Pending update saved: $(pending_state_path)"
}

apply_docker_update() {
    # Read pending state
    local state old_image new_image pulled_image_id
    if ! state="$(read_pending_state)"; then
        print_error "The pending update cannot be read (see above) -- cannot apply."
        return 1
    fi
    old_image="$(pending_field "$state" OLD_IMAGE)"
    new_image="$(pending_field "$state" NEW_IMAGE)"
    pulled_image_id="$(pending_field "$state" PULLED_IMAGE_ID)"
    if [[ -z "$old_image" ]] || [[ -z "$new_image" ]]; then
        print_error "Pending state is incomplete -- cannot apply."
        return 1
    fi

    print_header "Apply Update -- Docker Install"
    print_info "From: ${old_image}"
    print_info "To:   ${new_image}"
    echo ""
    # name:tag only, so a registry host:port is never read as a version. The
    # launch file names OLD_IMAGE (the substitution below fails otherwise), so
    # it is the running release.
    storage_migration_begin "${old_image##*/}" "${new_image##*/}" || return 1
    validator_downtime_warning_if_applicable || return 1

    # The image reference lives in the start wrapper on current installs and in
    # the systemd unit only on legacy ones -- resolve whichever this node uses.
    local launch_file
    launch_file=$(docker_launch_file) || {
        print_error "Could not resolve the docker launch config (wrapper or unit) for ${SERVICE_NAME}."
        return 1
    }
    local refusal
    if refusal="$(apply_root_dir_refusal "$launch_file")"; then
        print_error "$refusal"
        return 1
    fi
    update_swap_precheck "$launch_file" "$old_image" || return 1
    backup_unit_file "$launch_file" || return 1

    update_epoch_wait || return 1
    print_step "Stopping ${SERVICE_NAME}..."
    wait_for_service_stopped "$SERVICE_NAME"

    # The start script and unit are rendered again with the new image (and the
    # retired --observer flag dropped when the new release rejects it). The
    # backup above predates both, so the rollback below restores the old image.
    print_step "Writing ${new_image} into ${launch_file}..."
    if ! update_swap_image "$new_image" "$launch_file"; then
        print_error "The start script was not updated; restoring it from the backup."
        if ! restore_unit_file "$launch_file"; then
            print_error "Backup restore FAILED -- ${launch_file} may be in an edited state."
            print_info "  Restore manually: $(unit_restore_hint "$launch_file") && systemctl daemon-reload && systemctl start ${SERVICE_NAME}"
            return 1
        fi
        systemctl daemon-reload 2>/dev/null || true
        start_service 2>/dev/null || true
        return 1
    fi
    print_ok "Start script now runs ${new_image}"

    print_step "Starting ${SERVICE_NAME} on new image..."
    if [[ "$STORAGE_MIGRATION" == "true" ]]; then STORAGE_MIGRATION_STARTED=true; fi
    start_service

    if verify_health_after_restart && verify_running_image_id "$pulled_image_id"; then
        clear_pending_state
        if ! systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
            print_warn "Service is not enabled for auto-start on reboot."
            print_info "  Enable it: systemctl enable ${SERVICE_NAME}"
        fi
        print_ok "Update complete. Now running on: ${new_image}"
        print_info "Verify full health: bash ~/telcoin-node-scripts/check-node.sh"
        return 0
    fi

    # A one-way update is never rolled back, and the rollback is not offered:
    # the previous image cannot open the migrated data dir.
    if [[ "$STORAGE_MIGRATION" == "true" ]]; then
        storage_migration_verify_failed "$new_image" "$(unit_restore_hint "$launch_file") && systemctl daemon-reload"
        return 1
    fi

    # Health or image-identity verify failed -- offer rollback
    print_error "Post-update verification failed."
    echo ""
    if confirm "Roll back to previous image (${old_image})?"; then
        print_step "Rolling back..."
        wait_for_service_stopped "$SERVICE_NAME"
        # If the restore fails, do NOT start the service: it would come up on
        # the new image and the next health pass could misreport "rolled back".
        if ! restore_unit_file "$launch_file"; then
            print_error "Backup restore failed -- launch config still references ${new_image}."
            print_error "Node left STOPPED. Recover manually:"
            print_info "  $(unit_restore_hint "$launch_file") && systemctl daemon-reload && systemctl start ${SERVICE_NAME}"
            return 1
        fi
        systemctl daemon-reload 2>/dev/null || true
        start_service
        if verify_health_after_restart; then
            clear_pending_state
            print_ok "Rolled back to ${old_image}"
        else
            print_error "Rollback failed too. Inspect logs:"
            print_info "  journalctl -u ${SERVICE_NAME} --no-pager -n 50"
        fi
    else
        print_warn "Leaving node on new image. Pending state cleared."
        clear_pending_state
    fi
}

# =============================================================================
# SOURCE PATH
# =============================================================================

# _uc_built_binary_ok FILE [UID] -- rc 0 when the build output FILE is a
# regular file, not a symlink, owned by UID (default: the uid this script runs
# as, which ran the build). Read only after cargo has returned. Prints nothing.
_uc_built_binary_ok() {
    local f="${1:-}" want="${2:-}" uid
    [[ -n "$want" ]] || want="$(id -u)"
    [[ -n "$f" && -f "$f" && ! -L "$f" ]] || return 1
    uid="$(stat -c '%u' -- "$f" 2>/dev/null)" || return 1
    [[ "$uid" == "$want" ]]
}

# build_log_file -- create the cargo log for one prepare with mktemp (0600, a
# new name every time) and print its path. rc 1 when mktemp fails.
build_log_file() {
    mktemp "${TMPDIR:-/tmp}/tn-build.XXXXXX" 2>/dev/null
}

prepare_source_build() {
    local new_ref="$1" refusal
    print_header "Prepare Update -- Source Build"

    # A ref typed at the custom prompt goes to git as an argument: refuse one
    # that git would read as an option, before any git command runs.
    if refusal="$(update_ref_refusal "$new_ref")"; then
        print_error "$refusal"
        return 1
    fi

    # The network decides the build features (adiri on testnet, none on
    # mainnet). It must be known before the checkout moves or cargo runs: a
    # build for the wrong network refuses to start on this node's chain.
    local network cargo_features
    if ! network="$(detect_network)" || ! cargo_features="$(tn_cargo_features_for "$network")"; then
        print_error "Cannot tell which network this node runs, so the build features are unknown. Nothing was changed."
        print_info "Set NETWORK=testnet or NETWORK=mainnet, on one line, in $(node_meta_path 2>/dev/null || echo "$(tn_resolve_config_dir)/.node-meta")."
        return 1
    fi
    if [[ -n "$cargo_features" ]]; then
        print_info "Network: ${network} -- building with ${cargo_features}"
    else
        print_info "Network: ${network} -- building without the adiri feature"
    fi

    if [[ ! -d "${TN_SOURCE_DIR}/.git" ]]; then
        print_error "Source directory not found at ${TN_SOURCE_DIR}"
        print_info "This script can only update installs that built from /opt/telcoin-source."
        return 1
    fi

    local current_ref
    current_ref=$(detect_current_source_ref || echo "unknown")
    print_info "Current source ref: ${current_ref}"
    print_info "Target ref:         ${new_ref}"

    # Force-fetch tags BEFORE the checkout below: that flow prefers a local
    # ref, and release tags are occasionally re-cut at the same name (e.g. a
    # bad v0.13.0-adiri retagged to a corrected commit). Without --force the
    # stale local tag wins and the node silently rebuilds the OLD commit while
    # `git describe` still reports the right-looking version. Offline prepares
    # are tolerated (checkout proceeds against local refs). setup-node.sh
    # already refreshes reused clones with `fetch --all --tags --prune --force`
    # for exactly this reason. Network git and the build run with 9>&- (see
    # update_lock).
    git -C "$TN_SOURCE_DIR" fetch origin --tags --force 9>&- 2>/dev/null || true

    print_step "Checking out: ${new_ref}"
    if ! git -C "$TN_SOURCE_DIR" checkout "$new_ref" 2>/dev/null; then
        # Try fetching the ref explicitly then checking out
        if git -C "$TN_SOURCE_DIR" fetch origin "$new_ref" 9>&- 2>/dev/null && \
           git -C "$TN_SOURCE_DIR" checkout "$new_ref" 2>/dev/null; then
            print_ok "Checked out: ${new_ref}"
        else
            print_error "Could not check out '${new_ref}' -- branch or tag not found."
            return 1
        fi
    else
        print_ok "Checked out: ${new_ref}"
    fi
    # Pull if this is a branch (not a tag) so we get the latest commit on it
    git -C "$TN_SOURCE_DIR" pull --ff-only 9>&- 2>/dev/null || true

    # checkout/pull move the superproject only; sync submodules to the new ref
    # or the build fails on files the stale submodule doesn't have (this is
    # what broke v0.12.0-adiri source updates -- see tn_sync_submodules).
    # Runs before the disk check and build confirmation so the operator never
    # signs off on a 20-40 minute build against a broken tree.
    print_step "Syncing git submodules..."
    if ! tn_sync_submodules "$TN_SOURCE_DIR"; then
        print_error "git submodule sync failed."
        print_info "Manual fix, then re-run the update:"
        print_info "  git -C ${TN_SOURCE_DIR} submodule update --init --recursive --force"
        return 1
    fi
    print_ok "Submodules: $(git -C "$TN_SOURCE_DIR" submodule status 2>/dev/null | tr '\n' ' ')"

    # Disk-space pre-flight. A clean cargo build can produce a target/
    # directory of several GB. Refuse to start a build when we can already
    # see disk is tight -- cleaner than failing mid-compile with cryptic
    # "no space left on device" errors.
    local avail_gb min_required_gb=5
    avail_gb=$(df -BG --output=avail "$TN_SOURCE_DIR" 2>/dev/null | awk 'NR==2 {gsub("G",""); print $1}')
    if [[ -n "$avail_gb" ]] && [[ "$avail_gb" -lt "$min_required_gb" ]]; then
        print_error "Only ${avail_gb}G available on the mount holding ${TN_SOURCE_DIR}"
        print_error "A source build typically needs ${min_required_gb}G+ for cargo artefacts."
        print_info "Free up some space and try again:"
        print_info "  du -sh ${TN_SOURCE_DIR}/target 2>/dev/null"
        print_info "  cargo clean --manifest-path ${TN_SOURCE_DIR}/Cargo.toml"
        return 1
    fi
    [[ -n "$avail_gb" ]] && print_info "Disk free on source mount: ${avail_gb}G (>= ${min_required_gb}G required)"

    echo ""
    print_warn "Source build typically takes 20-40 minutes."
    print_info "Service stays running during the build -- only the apply step incurs downtime."
    echo ""
    if ! confirm "Start the build now?"; then
        print_info "Cancelled."
        return 1
    fi

    # Make cargo findable. Sudo's PATH usually does not include
    # ~/.cargo/bin, which is where rustup installs cargo. Mirror what
    # setup-{observer,validator}.sh do at install time. Look at three
    # plausible locations so this works whether rustup ran as root or as
    # the invoking user.
    local user_cargo_dir=""
    [[ -n "${SUDO_USER:-}" ]] && [[ -d "/home/${SUDO_USER}/.cargo/bin" ]] \
        && user_cargo_dir="/home/${SUDO_USER}/.cargo/bin"
    export PATH="${HOME}/.cargo/bin:/root/.cargo/bin:${user_cargo_dir}:${PATH}"
    [[ -f "${HOME}/.cargo/env" ]] && source "${HOME}/.cargo/env" 2>/dev/null || true
    [[ -n "$user_cargo_dir" ]] && [[ -f "/home/${SUDO_USER}/.cargo/env" ]] \
        && source "/home/${SUDO_USER}/.cargo/env" 2>/dev/null || true

    if ! command -v cargo >/dev/null 2>&1; then
        print_error "cargo not found in PATH. Looked in:"
        print_info "  \${HOME}/.cargo/bin"
        print_info "  /root/.cargo/bin"
        [[ -n "$user_cargo_dir" ]] && print_info "  ${user_cargo_dir}"
        print_info "Install Rust:"
        print_info "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
        return 1
    fi
    print_info "cargo: $(command -v cargo)"

    # Capture the pre-build binary hash so we can detect "cargo did nothing"
    # after the build runs.
    local built="${TN_SOURCE_DIR}/target/release/telcoin-network"
    local pre_build_hash=""
    [[ -f "$built" ]] && pre_build_hash=$(sha256sum "$built" | awk '{print $1}')

    # A fresh 0600 log per build (mktemp), never a fixed name in /tmp.
    local build_log
    if ! build_log="$(build_log_file)"; then
        print_error "Could not create a build log in ${TMPDIR:-/tmp}. Nothing was built."
        return 1
    fi
    print_info "Build log: ${build_log}"

    print_step "Building release binary (${new_ref}, ${cargo_features:-no features})..."
    # Use pushd/popd instead of a subshell so PIPESTATUS is captured from
    # the pipeline below. set -o pipefail (inherited from common.sh) makes
    # the pipeline return non-zero if cargo itself fails -- v1.1.40 and
    # earlier discarded that exit code by running the pipeline inside an
    # unchecked subshell, which let a failed build go undetected.
    pushd "$TN_SOURCE_DIR" >/dev/null
    # shellcheck disable=SC2086
    if ! cargo build --release $cargo_features 9>&- 2>&1 | tee "$build_log" 9>&-; then
        popd >/dev/null
        print_error "cargo build failed. See ${build_log} for the full output."
        print_info "  Last few lines:"
        tail -10 "$build_log" 2>/dev/null | sed 's/^/    /'
        return 1
    fi
    popd >/dev/null

    # The output is inspected only now that cargo has returned: a regular
    # file (not a symlink) owned by the account that ran the build.
    if ! _uc_built_binary_ok "$built"; then
        print_error "Build did not produce a regular file owned by the build account at ${built}. See ${build_log}"
        return 1
    fi

    # Sanity-check the new binary runs (catches the rare case where cargo
    # finishes but the resulting binary is broken).
    if ! "$built" --version &>/dev/null; then
        print_error "Built binary failed --version check. Build may be corrupt."
        return 1
    fi
    local new_version
    new_version=$("$built" --version 2>/dev/null | head -1)

    # Did cargo actually produce a new binary? If the hash hasn't changed,
    # cargo decided no rebuild was needed (or did nothing). That used to
    # silently install the unchanged old binary on top of itself.
    local binary_hash
    binary_hash=$(sha256sum "$built" | awk '{print $1}')
    if [[ -n "$pre_build_hash" ]] && [[ "$pre_build_hash" == "$binary_hash" ]]; then
        print_warn "Binary hash did not change after build."
        print_info "  Pre-build:  ${pre_build_hash:0:16}..."
        print_info "  Post-build: ${binary_hash:0:16}..."
        print_info "  This usually means cargo decided no rebuild was needed,"
        print_info "  even though the build command exited 0. Double-check your ref:"
        print_info "    git -C ${TN_SOURCE_DIR} log -1 --format='%h %s'"
        if ! confirm "Proceed anyway with the existing (unchanged) binary?"; then
            print_info "Cancelled."
            return 1
        fi
    fi
    print_ok "Build complete: ${new_version}"

    if ! write_pending_state <<EOF
PHASE=build_complete
INSTALL_METHOD=source
OLD_REF=${current_ref}
NEW_REF=${new_ref}
NEW_VERSION=${new_version}
BUILT_BINARY=${built}
BUILT_HASH=${binary_hash}
PREPARED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
    then
        print_error "Could not write pending state at $(pending_state_path)"
        return 1
    fi
    print_ok "Pending update saved: $(pending_state_path)"
}

apply_source_update() {
    local state built old_ref new_ref new_version expected_hash
    if ! state="$(read_pending_state)"; then
        print_error "The pending update cannot be read (see above) -- cannot apply."
        return 1
    fi
    built="$(pending_field "$state" BUILT_BINARY)"
    old_ref="$(pending_field "$state" OLD_REF)"
    new_ref="$(pending_field "$state" NEW_REF)"
    new_version="$(pending_field "$state" NEW_VERSION)"
    expected_hash="$(pending_field "$state" BUILT_HASH)"
    if [[ -z "$built" ]] || [[ ! -f "$built" ]]; then
        print_error "Pending built binary not found at ${built:-?}"
        return 1
    fi

    print_header "Apply Update -- Source Install"
    print_info "From: ${old_ref}"
    print_info "To:   ${new_ref}  (${new_version})"
    echo ""

    # Sanity: confirm the binary on disk still matches the one we built
    local actual_hash
    actual_hash=$(sha256sum "$built" | awk '{print $1}')
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        print_warn "Built binary hash has changed since prepare phase."
        print_info "  Expected: ${expected_hash}"
        print_info "  Actual:   ${actual_hash}"
        if ! confirm "Proceed anyway?"; then
            print_info "Cancelled."
            return 1
        fi
        # Operator approved installing the changed binary -- the post-restart
        # identity check must verify against what is actually being installed,
        # or it would force a rollback of an explicitly approved apply.
        expected_hash="$actual_hash"
    fi

    # The running release comes from the version marker, not from OLD_REF: that
    # is `git describe` at prepare time and names the wrong release after a
    # prepare, a discard and another prepare.
    storage_migration_begin "$(installed_source_ref)" "$new_ref" || return 1
    validator_downtime_warning_if_applicable || return 1

    local installed="${DEFAULT_INSTALL_DIR}/telcoin-network"
    if [[ ! -f "$installed" ]]; then
        print_error "Installed binary not found at ${installed}"
        return 1
    fi
    local refusal
    if refusal="$(apply_root_dir_refusal "$installed")"; then
        print_error "$refusal"
        return 1
    fi

    # Back up the current binary into the root-only backup directory; the
    # rollback below checks the copy's sha256 before it puts it back.
    if ! backup_installed_binary "$installed"; then
        print_error "Could not back up current binary."
        return 1
    fi
    print_info "Binary backup: ${BIN_BK_PATH}"

    # Hash the installed binary before we copy over it. If the cp does not
    # actually change anything (built and installed already identical), we
    # want to surface that as a "nothing happened" warning rather than
    # silently report success.
    local pre_install_hash
    pre_install_hash=$(sha256sum "$installed" | awk '{print $1}')

    update_epoch_wait || return 1
    print_step "Stopping ${SERVICE_NAME}..."
    wait_for_service_stopped "$SERVICE_NAME"

    print_step "Installing new binary..."
    # tn_install_root_binary installs root:root 0755 beside the live file and
    # renames it into place, so a failure (disk full, I/O error) leaves the
    # old binary untouched: start it again and stop here.
    if ! tn_install_root_binary "$built" "$installed"; then
        print_error "Failed to install ${built} as ${installed}; the previous binary is unchanged."
        print_info "  Checking disk: $(df -h "$installed" | tail -1)"
        start_service 2>/dev/null || true
        return 1
    fi

    local post_install_hash
    post_install_hash=$(sha256sum "$installed" | awk '{print $1}')
    # The file installed must be the one prepared (or the one the operator
    # approved above); anything else goes back before the node starts.
    if [[ "$post_install_hash" != "$expected_hash" ]]; then
        print_error "The installed binary does not match the prepared build (sha256 ${post_install_hash:0:12}..., expected ${expected_hash:0:12}...)."
        if restore_installed_binary "$installed"; then
            print_info "Previous binary put back; restarting it."
            start_service 2>/dev/null || true
        else
            print_error "Could not put the previous binary back. Node left STOPPED. Recover manually:"
            print_info "  $(binary_restore_hint "$installed") && systemctl start ${SERVICE_NAME}"
        fi
        return 1
    fi
    if [[ "$pre_install_hash" == "$post_install_hash" ]]; then
        print_warn "Installed binary is identical to what was already at ${installed}."
        print_warn "The build did not produce different output -- you may still be"
        print_warn "running the previous version after restart. Investigate before"
        print_warn "treating this as a successful update."
    else
        print_ok "Binary swapped: ${pre_install_hash:0:12}... -> ${post_install_hash:0:12}..."
    fi

    # Drop the retired --observer flag from the start wrapper when the new
    # release rejects it. The decision reads the ref only (a tag carries the
    # release version; a branch or SHA counts as newest). The built binary's
    # --version reports the crate version (0.1.0), not the release, so it must
    # not take part or a `main` build would never be stripped. The wrapper is
    # backed up first and the rollback below restores it with the old binary.
    # No backup, no strip: a wrapper that keeps the flag fails the health check
    # and rolls back cleanly.
    local wrapper wrapper_backed=false undo
    wrapper="$(tn_node_launch_target 2>/dev/null || true)"
    wrapper="${wrapper##* }"
    if observer_strip_needed "$wrapper" "$new_ref"; then
        if apply_root_dir_refusal "$wrapper" >/dev/null || ! backup_unit_file "$wrapper"; then
            print_warn "Could not back up ${wrapper} -- leaving the retired --observer flag in place."
        else
            wrapper_backed=true
            if tn_node_strip_observer_flag "$wrapper"; then
                print_info "Stripped the retired --observer flag from ${wrapper}"
            else
                print_warn "Could not strip the retired --observer flag from ${wrapper} -- continuing."
                print_info "  If ${SERVICE_NAME} fails to start, remove the flag from that file by hand."
            fi
        fi
    fi

    update_rerender_launch
    print_step "Starting ${SERVICE_NAME} on new binary..."
    if [[ "$STORAGE_MIGRATION" == "true" ]]; then STORAGE_MIGRATION_STARTED=true; fi
    start_service

    if verify_health_after_restart && verify_installed_binary_hash "$installed" "$expected_hash"; then
        clear_pending_state
        # Record the now-running ref so the UI reports the installed binary's
        # version (not the source checkout, which has moved to new_ref).
        write_source_version_marker "$DEFAULT_INSTALL_DIR" "$TN_SOURCE_DIR" "$new_ref"
        if ! systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
            print_warn "Service is not enabled for auto-start on reboot."
            print_info "  Enable it: systemctl enable ${SERVICE_NAME}"
        fi
        print_ok "Update complete. Now running: ${new_version}"
        print_info "Verify full health: bash ~/telcoin-node-scripts/check-node.sh"
        return 0
    fi

    undo="$(binary_restore_hint "$installed")"
    if [[ "$wrapper_backed" == "true" ]]; then
        undo="${undo} && $(unit_restore_hint "$wrapper")"
    fi
    # A one-way update is never rolled back, and the rollback is not offered:
    # the previous binary cannot open the migrated data dir.
    if [[ "$STORAGE_MIGRATION" == "true" ]]; then
        storage_migration_verify_failed "$new_ref" "$undo"
        return 1
    fi

    # Health or binary-identity verify failed -- rollback
    print_error "Post-update verification failed."
    echo ""
    if confirm "Roll back to previous binary?"; then
        print_step "Rolling back..."
        wait_for_service_stopped "$SERVICE_NAME"
        # If the restore fails, do NOT start the service: it would come up on
        # the new binary and the next health pass could misreport "rolled back".
        if ! restore_installed_binary "$installed"; then
            print_error "Backup restore failed -- ${installed} still holds the new binary."
            print_error "Node left STOPPED. Recover manually:"
            print_info "  ${undo} && systemctl start ${SERVICE_NAME}"
            return 1
        fi
        # The old binary goes back with the wrapper it ran under.
        if [[ "$wrapper_backed" == "true" ]] && ! restore_unit_file "$wrapper"; then
            print_warn "Could not restore ${wrapper} from ${UNIT_BK_PATH} -- the previous binary starts without the --observer flag."
        fi
        start_service
        if verify_health_after_restart; then
            clear_pending_state
            print_ok "Rolled back to previous binary"
        else
            print_error "Rollback failed too. Inspect logs:"
            print_info "  journalctl -u ${SERVICE_NAME} --no-pager -n 50"
        fi
    else
        print_warn "Leaving node on new binary. Pending state cleared."
        clear_pending_state
    fi
}

# =============================================================================
# VALIDATOR GUARD
# =============================================================================

# Best-effort runtime check: is this node a validator the protocol currently
# cares about? The protocol assigns a node's role per-epoch from on-chain
# committee membership, so the install-time role hint in .node-meta is NOT
# authoritative. Asks node_is_staked_validator (lib/common.sh) and returns 0
# (treat as validator) when the registry reports a REGISTERED validator (status
# 1-4) OR when the status cannot be determined (no address on file, bad address,
# RPC unreachable); returns 1 ONLY when the registry definitively reports a
# non-validator (status 0/5/6 or no NFT record). Erring toward 0 keeps the
# downtime warning when in doubt -- a missed warning on a live validator is
# worse than a needless prompt.
node_is_onchain_validator_or_unknown() {
    local addr rc
    addr="$(meta_get VALIDATOR_ADDRESS 2>/dev/null || true)"
    # No address on file -> cannot confirm; treat as unknown -> warn.
    [[ -n "$addr" ]] || return 0
    rc=0
    node_is_staked_validator "$addr" "$RPC_URL" || rc=$?
    # rc 1 = definite non-validator. rc 0 (validator) and rc 2 (unknown) warn.
    if [[ "$rc" -eq 1 ]]; then
        return 1
    fi
    return 0
}

validator_downtime_warning_if_applicable() {
    # Gate on RUNTIME on-chain status, not the install-time role hint: only SKIP
    # the warning when the registry confirms this node is NOT a validator.
    if ! node_is_onchain_validator_or_unknown; then
        return 0
    fi
    echo ""
    print_warn "================================================================"
    print_warn "  VALIDATOR DOWNTIME WARNING"
    print_warn "================================================================"
    print_warn "Stopping a validator during its committee window means missed"
    print_warn "consensus rounds and lost block rewards for the downtime period."
    print_warn "Apply updates during a planned maintenance window if possible."
    print_warn "================================================================"
    echo ""
    local input
    read -r -p "  Type CONFIRM to proceed with the validator restart: " input
    if [[ "$input" != "CONFIRM" ]]; then
        print_info "Cancelled."
        return 1
    fi
    return 0
}

# =============================================================================
# INTERACTIVE VERSION PICKER (Docker)
# Print informational messages to stderr; print only the chosen ref/image
# on stdout so the caller can capture it via $(...). Return 0 on selection,
# 1 on cancel or error.
# =============================================================================


pick_docker_version() {
    local current_image
    current_image=$(detect_current_docker_image) || {
        print_error "Could not read current Docker image from the ${SERVICE_NAME} launch config (wrapper or unit)" >&2
        return 1
    }
    local current_tag="${current_image##*:}"
    local registry_path="${current_image%:*}"

    print_step "Querying registry for available tags..." >&2
    local -a all_tags
    while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        all_tags+=("$t")
    done < <(fetch_docker_tags)

    echo "" >&2
    print_info "Current image:        ${current_image}" >&2

    # No tags = registry unreachable or returned nothing parseable.
    if [[ ${#all_tags[@]} -eq 0 ]]; then
        print_warn "Could not reach registry (or no parseable tags returned)." >&2
        echo "" >&2
        print_info "Falling back to manual entry." >&2
        local custom_tag
        read -r -p "  Enter target tag (e.g. ${current_tag}) or Enter to cancel: " custom_tag >&2
        [[ -z "$custom_tag" ]] && { print_info "Cancelled." >&2; return 1; }
        if ! [[ "$custom_tag" =~ ^[A-Za-z0-9._-]+$ ]]; then
            print_error "Tag contains unexpected characters: ${custom_tag}" >&2
            return 1
        fi
        if [[ "$custom_tag" == "$current_tag" ]]; then
            print_info "That is your current tag. Nothing to update." >&2
            return 1
        fi
        echo "${registry_path}:${custom_tag}"
        return 0
    fi

    # fetch_docker_tags returns oldest-first; reverse for newest-first menu.
    local -a tags_desc
    for ((i=${#all_tags[@]}-1; i>=0; i--)); do
        tags_desc+=("${all_tags[i]}")
    done
    local latest_tag="${tags_desc[0]}"

    if [[ "$current_tag" == "$latest_tag" ]]; then
        print_ok "You are on the latest published tag (${latest_tag})." >&2
    else
        print_info "Latest published tag: ${latest_tag}" >&2
    fi
    echo "" >&2

    print_info "Available image tags:" >&2
    local i=1
    for tag in "${tags_desc[@]}"; do
        local marker=""
        [[ "$tag" == "$current_tag" ]] && marker="  <-- current"
        [[ $i -eq 1 ]] && [[ -z "$marker" ]] && marker="  <-- latest"
        printf "  %2d) %s%s\n" "$i" "$tag" "$marker" >&2
        (( ++i ))
    done
    local tag_count=$(( i - 1 ))
    local custom_opt=$i; printf "  %2d) Custom tag\n" "$custom_opt" >&2; (( ++i ))
    local cancel_opt=$i; printf "  %2d) Cancel\n"     "$cancel_opt" >&2
    echo "" >&2

    local choice
    read -r -p "  Select [1-${cancel_opt}]: " choice >&2

    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        print_warn "Invalid selection." >&2
        return 1
    fi
    if (( choice == cancel_opt )); then
        print_info "Cancelled." >&2
        return 1
    fi
    if (( choice == custom_opt )); then
        local custom_tag
        read -r -p "  Enter target tag: " custom_tag >&2
        [[ -z "$custom_tag" ]] && { print_info "Cancelled." >&2; return 1; }
        if ! [[ "$custom_tag" =~ ^[A-Za-z0-9._-]+$ ]]; then
            print_error "Tag contains unexpected characters: ${custom_tag}" >&2
            return 1
        fi
        if [[ "$custom_tag" == "$current_tag" ]]; then
            print_info "That is your current tag. Nothing to update." >&2
            return 1
        fi
        echo "${registry_path}:${custom_tag}"
        return 0
    fi
    if (( choice >= 1 && choice <= tag_count )); then
        local selected="${tags_desc[$((choice - 1))]}"
        if [[ "$selected" == "$current_tag" ]]; then
            print_info "That is your current tag. Nothing to update." >&2
            return 1
        fi
        echo "${registry_path}:${selected}"
        return 0
    fi

    print_warn "Invalid selection." >&2
    return 1
}

# Ask the operator: prepare-only or prepare-and-apply or cancel.
# Echoes "prepare" | "prepare_and_apply" | "cancel".

# =============================================================================
# JSON / NON-INTERACTIVE MODE
#
# Reached only via `--json` (the interactive default is completely unaffected).
# Used by the Telcoin Node Manager UI through the root-owned telcoin-ui-helper.
#
# fd handling: json_setup_fds dups the real stdout to fd 3 and points stdout at
# stderr, so every human-readable print_* / build line is harmless noise on
# stderr while fd 3 carries newline-delimited JSON the caller can stream + parse.
# main does this, and installs update_on_exit, before it parses the arguments,
# so a run that stops early (a bad argument, not root, no node, the lock held)
# still prints JSON only and ends with a done event.
# Each emitted line is a self-contained JSON object: progress events
#   {"event":"step|log|warn|error","msg":"..."}
# and exactly one terminal result
#   {"event":"done","ok":true|false,"phase":"prepare|apply|discard",...}
# A one-way apply (see storage_migrating_upgrade) whose check fails is not
# rolled back and ends with
#   {"event":"done","ok":false,"phase":"apply","rolled_back":false,"storage_migration":true,"msg":"..."}
# --check prints one status object instead (see json_check) and nothing else;
# its "storage_migration" says whether updating to latest_ref is one way.
# =============================================================================

json_setup_fds() {
    exec 3>&1   # fd3 = original stdout: JSON is written here
    exec 1>&2   # stdout now aliases stderr: print_*/build output is benign noise
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"
    s="${s//$'\r'/ }"
    s="${s//$'\t'/ }"
    printf '%s' "$s"
}

# json_emit <json> -- write one JSON line to fd 3. A done event is recorded so
# update_on_exit does not send a second one.
json_emit() {
    case "$1" in
        '{"event":"done"'*) JSON_DONE_SENT=true ;;
    esac
    printf '%s\n' "$1" >&3
}

json_event() {
    # json_event <event> <msg>
    if [[ "$1" == "error" ]]; then
        JSON_LAST_ERROR="${2:-}"
    fi
    json_emit "{\"event\":\"${1}\",\"msg\":\"$(json_escape "${2:-}")\"}"
}

# update_on_exit -- the EXIT trap, installed by main before it parses anything.
# Releases the update lock and, in --json mode, sends
#   {"event":"done","ok":false,"phase":...,"msg":...}
# when the run is ending without having sent its final answer, so every --json
# run ends with exactly one done whichever way it stopped. The message is the
# last error event's, or a pointer to stderr when there was none.
update_on_exit() {
    local rc=$?
    local msg phase
    phase=""
    if declare -F tn_remove_inflight_tmp >/dev/null 2>&1; then
        tn_remove_inflight_tmp
    fi
    if [[ -n "$UPDATE_LOCK_CLEANUP" ]]; then
        eval "$UPDATE_LOCK_CLEANUP" 2>/dev/null || true
    fi
    if declare -F tn_release_update_lock >/dev/null 2>&1; then
        tn_release_update_lock
    fi
    if [[ "$JSON_MODE" == "true" && "$JSON_DONE_SENT" != "true" ]]; then
        msg="${JSON_LAST_ERROR:-update-node.sh stopped before reporting a result; the reason is on its stderr}"
        if [[ -n "$JSON_ACTION" ]]; then
            phase=",\"phase\":\"$(json_escape "$JSON_ACTION")\""
        fi
        # A one-way apply cut short after the new release started is never
        # rolled back either (see storage_migration_verify_failed); say so, as
        # its own done would. Before that start nothing has migrated.
        if [[ "$JSON_ACTION" == "apply" && "$STORAGE_MIGRATION_STARTED" == "true" ]]; then
            phase="${phase},\"rolled_back\":false,\"storage_migration\":true"
        fi
        json_emit "{\"event\":\"done\",\"ok\":false${phase},\"msg\":\"$(json_escape "$msg")\"}" 2>/dev/null || true
    fi
    return "$rc"
}

# update_lock -- take the update lock (tn_acquire_update_lock) with
# update_on_exit in charge of releasing it. A lib/common.sh older than 1.5.0
# ignores TN_EXIT_TRAP_OWNED and, where flock is missing, replaces the EXIT trap
# with its own cleanup: that command is kept for update_on_exit to run, and the
# trap is put back.
#
# On the flock path the lock is held on fd 9, which every child inherits, and a
# child that outlives this script (cargo still building after a SIGTERM, say)
# would keep the lock until it exits. So the long-running commands this script
# runs itself (git fetch and pull, cargo build and its tee, docker pull,
# systemctl stop) get 9>&-. Children started inside library functions (the
# epoch wait, the submodule sync) are the library's to close.
update_lock() {
    local cur
    TN_EXIT_TRAP_OWNED=1
    tn_acquire_update_lock || return 1
    cur="$(trap -p EXIT)"
    if [[ -n "$cur" && "$cur" != "trap -- 'update_on_exit' EXIT" ]]; then
        eval "set -- ${cur}"
        UPDATE_LOCK_CLEANUP="${3:-}"
        trap update_on_exit EXIT
    fi
    return 0
}

# update_migrate_ownership -- once the update lock is held and before anything
# else is written, bring an existing install to the root-owned file layout
# with tn_migrate_ownership (idempotent; it never restarts the node). rc 0
# when the layout is in place, rc 1 with the reason reported (an error event
# in --json mode) when the migration refuses: a symlink or an unexpected owner
# under the install trees, or a mainnet node that needs a fresh install.
update_migrate_ownership() {
    local rc=0 msg
    tn_migrate_ownership update_wait_say || rc=$?
    case "$rc" in
        0) return 0 ;;
        3) msg="This mainnet node still has the old file ownership layout and must be installed fresh; it is not migrated in place. Nothing was changed." ;;
        *) msg="The file ownership migration stopped (see the list above). Review those paths, then run the update again. Nothing else was changed." ;;
    esac
    if [[ "$JSON_MODE" == "true" ]]; then
        json_event error "$msg"
    else
        print_error "$msg"
    fi
    return 1
}

# update_legacy_refusal -- rc 1 (with the one command that fixes it) when the node's
# unit still holds the BLS passphrase, still carries the whole docker command inline,
# or the passphrase is still sealed with the old TPM method. Those installs move to
# the current unit, start script and encrypted credential with
# edit-config.sh --migrate-credential before they can be updated. Reads only.
update_legacy_refusal() {
    local unit="/etc/systemd/system/${SERVICE_NAME}.service" msg="" method="" file=""
    if tn_has_embedded_passphrase "$unit"; then
        msg="${unit} still holds the BLS passphrase."
    elif [[ "$(meta_get PASSPHRASE_METHOD 2>/dev/null || true)" == "tpm" ]]; then
        msg="The BLS passphrase is still sealed with the old TPM method, which these scripts no longer use."
    else
        method="$(meta_get INSTALL_METHOD 2>/dev/null || true)"
        if [[ "$method" == "docker" ]]; then
            file="$(docker_launch_file 2>/dev/null || true)"
            [[ "$file" == *.service ]] && msg="${file} still runs the docker command inline."
        fi
    fi
    [[ -n "$msg" ]] || return 0
    msg="${msg} Move it to the current unit, start script and encrypted credential first: sudo ./edit-config.sh --migrate-credential (nothing was changed)"
    if [[ "$JSON_MODE" == "true" ]]; then
        json_event error "$msg"
    else
        print_error "$msg"
    fi
    return 1
}

# update_swap_precheck FILE OLD_IMAGE -- rc 1 (with the reason) unless FILE, the
# docker launch file, is the current start script (tn_start_script_path docker) and
# runs OLD_IMAGE, the image the pending update was prepared against: the swap
# renders that script and the unit again, so an older launch file moves first.
# Reads only.
update_swap_precheck() {
    local file="${1:-}" old="${2:-}" want cur rc=0
    want="$(tn_start_script_path docker)"
    if [[ "$file" != "$want" ]]; then
        update_wait_say warn "${SERVICE_NAME} still starts from ${file}, not ${want}; move it first: sudo ./edit-config.sh --migrate-credential. Nothing was changed."
        return 1
    fi
    cur="$(_tn_launch_awk runner "$file" 2>/dev/null)" || rc=$?
    if [[ $rc -ne 10 || "$cur" != "docker ${old}" ]]; then
        update_wait_say warn "${file} does not run ${old}, the image this update was prepared against; discard the pending update and prepare it again. Nothing was changed."
        return 1
    fi
    return 0
}

# update_swap_image NEW_IMAGE FILE -- while the node is stopped, put NEW_IMAGE in the
# docker start script FILE by rendering the start script and unit again
# (tn_rerender_node_launch, which takes only this network's repository by digest or
# release tag): no text substitution on the file. The retired --observer flag is
# dropped first when the new release rejects it. rc 1 when the render refused or
# failed, or FILE does not run NEW_IMAGE afterwards; the caller restores the backup.
update_swap_image() {
    local new="${1:-}" file="${2:-}" rc=0 cur
    if observer_strip_needed "$file" "${new##*/}"; then
        if tn_node_strip_observer_flag "$file"; then
            update_wait_say log "Stripped the retired --observer flag from ${file}."
        else
            update_wait_say warn "Could not strip the retired --observer flag from ${file}."
            return 1
        fi
    fi
    update_node_log_dir
    tn_rerender_node_launch "$new" update_wait_say || rc=$?
    if [[ $rc -ne 0 ]]; then
        update_wait_say warn "The start script was not written for ${new} (see above)."
        return 1
    fi
    rc=0
    cur="$(_tn_launch_awk runner "$file" 2>/dev/null)" || rc=$?
    if [[ $rc -ne 10 || "$cur" != "docker ${new}" ]]; then
        update_wait_say warn "${file} does not run ${new} after the rewrite."
        return 1
    fi
    systemctl daemon-reload 9>&- || update_wait_say warn "systemctl daemon-reload failed; ${SERVICE_NAME} may start with its previous unit."
    return 0
}

# update_arg_error <msg> -- report a command-line error: an error event in
# --json mode, an [ERROR] line on stderr otherwise. The caller exits.
update_arg_error() {
    if [[ "$JSON_MODE" == "true" ]]; then
        json_event error "$1"
    else
        print_error "$1"
    fi
}

# update_ref_refusal <ref> -- rc 0, with the reason on stdout, when ref starts
# with "-": no tag, branch, commit or image tag does, and git or docker would
# read it as an option. Used by the --ref parser and by the interactive source
# prepare (the custom ref prompt), so both refuse with the same words.
update_ref_refusal() {
    case "${1:-}" in
        -*) printf 'Invalid ref "%s": a ref cannot start with "-".\n' "$1"; return 0 ;;
    esac
    return 1
}

# Newest tag for the operator's network (source installs). Echoes "" if none.
latest_source_ref() {
    [[ -d "${TN_SOURCE_DIR}/.git" ]] || return 0
    local network suffix=""
    network=$(detect_network)
    case "$network" in
        testnet) suffix="$NETWORK_TAG_SUFFIX_TESTNET" ;;
        mainnet) suffix="$NETWORK_TAG_SUFFIX_MAINNET" ;;
    esac
    # --force so a re-cut tag (same name, new commit) updates the local ref;
    # without it the newest-tag probe keeps reporting the stale commit's tag.
    git -C "$TN_SOURCE_DIR" fetch --tags --force --quiet 2>/dev/null || true
    local t
    while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        [[ -n "$suffix" && "$t" != *"$suffix"* ]] && continue
        echo "$t"
        return 0
    done < <(git -C "$TN_SOURCE_DIR" tag --sort=-creatordate 2>/dev/null)
    return 0
}

# Newest published docker tag. fetch_docker_tags emits oldest-first.
latest_docker_ref() {
    fetch_docker_tags | tail -1
}

json_check() {
    local install_method="$1"
    local current="" latest="" pending="null" avail="false" running="" mig="false"

    if [[ -f "$(pending_state_path)" ]]; then
        local phase
        phase=$(read_pending_state | grep '^PHASE=' | cut -d= -f2 || true)
        pending="\"$(json_escape "${phase:-pending}")\""
    fi

    case "$install_method" in
        source)
            current=$(detect_current_source_ref 2>/dev/null || echo "")
            latest=$(latest_source_ref 2>/dev/null || echo "")
            local exact_tag
            exact_tag=$(git -C "$TN_SOURCE_DIR" describe --tags --exact-match HEAD 2>/dev/null || echo "")
            [[ -n "$latest" && "$exact_tag" != "$latest" ]] && avail="true"
            running="$(installed_source_ref)"
            ;;
        docker)
            local img
            img=$(detect_current_docker_image 2>/dev/null || echo "")
            current="${img##*:}"
            latest=$(latest_docker_ref 2>/dev/null || echo "")
            [[ -n "$latest" && -n "$current" && "$current" != "$latest" ]] && avail="true"
            running="${img##*/}"
            ;;
        *)
            current=$(detect_current_source_ref 2>/dev/null || echo "")
            ;;
    esac
    # storage_migration: updating from the running release to latest_ref is one
    # way (see storage_migrating_upgrade). False when there is no latest_ref.
    if [[ -n "$latest" ]] && storage_migrating_upgrade "$running" "$latest"; then
        mig="true"
    fi

    json_emit "{\"install_method\":\"$(json_escape "$install_method")\",\"current_ref\":\"$(json_escape "$current")\",\"latest_ref\":\"$(json_escape "$latest")\",\"update_available\":${avail},\"pending\":${pending},\"storage_migration\":${mig}}"
    # This object is the whole answer: the UI reads the last JSON line of a
    # check, so no done event may follow it.
    JSON_DONE_SENT=true
}

json_prepare() {
    local install_method="$1" ref="$2"
    if [[ "$install_method" == "existing" ]]; then
        existing_update_refusal; return 1
    fi
    if [[ -z "$ref" ]]; then
        json_event error "no ref supplied"; return 1
    fi
    case "$install_method" in
        source) json_prepare_source "$ref" ;;
        docker) json_prepare_docker "$ref" ;;
        *) json_event error "install method '${install_method}' cannot be updated"; return 1 ;;
    esac
}

json_prepare_source() {
    local new_ref="$1"
    # Network and build features first: nothing is checked out or built for
    # a network that cannot be told (see prepare_source_build).
    local network cargo_features
    if ! network="$(detect_network)" || ! cargo_features="$(tn_cargo_features_for "$network")"; then
        json_event error "cannot tell which network this node runs, so the build features are unknown; set NETWORK=testnet or NETWORK=mainnet on one line in .node-meta. Nothing was changed."
        return 1
    fi
    if [[ ! -d "${TN_SOURCE_DIR}/.git" ]]; then
        json_event error "source directory not found at ${TN_SOURCE_DIR}"; return 1
    fi
    local current_ref
    current_ref=$(detect_current_source_ref || echo "unknown")

    # Force-fetch tags before checkout -- same stale re-cut-tag hazard as the
    # interactive path (see prepare_source_build); offline is tolerated.
    # Network git and the build run with 9>&- (see update_lock).
    git -C "$TN_SOURCE_DIR" fetch origin --tags --force 9>&- 2>/dev/null || true

    json_event step "Checking out ${new_ref}"
    if ! git -C "$TN_SOURCE_DIR" checkout "$new_ref" 2>/dev/null; then
        if ! { git -C "$TN_SOURCE_DIR" fetch origin "$new_ref" 9>&- 2>/dev/null && \
               git -C "$TN_SOURCE_DIR" checkout "$new_ref" 2>/dev/null; }; then
            json_event error "could not check out '${new_ref}' -- branch or tag not found"
            return 1
        fi
    fi
    git -C "$TN_SOURCE_DIR" pull --ff-only 9>&- 2>/dev/null || true

    # checkout/pull move the superproject only; sync submodules to the new ref
    # or the build fails on files the stale submodule doesn't have (this is
    # what broke v0.12.0-adiri source updates -- see tn_sync_submodules).
    json_event step "Syncing git submodules"
    if ! tn_sync_submodules "$TN_SOURCE_DIR"; then
        json_event error "git submodule sync failed -- run: git -C ${TN_SOURCE_DIR} submodule update --init --recursive --force"
        return 1
    fi
    json_event step "Submodules: $(git -C "$TN_SOURCE_DIR" submodule status 2>/dev/null | tr '\n' ' ')"

    # Make cargo findable under sudo's PATH (mirrors prepare_source_build).
    local user_cargo_dir=""
    [[ -n "${SUDO_USER:-}" ]] && [[ -d "/home/${SUDO_USER}/.cargo/bin" ]] \
        && user_cargo_dir="/home/${SUDO_USER}/.cargo/bin"
    export PATH="${HOME}/.cargo/bin:/root/.cargo/bin:${user_cargo_dir}:${PATH}"
    [[ -f "${HOME}/.cargo/env" ]] && source "${HOME}/.cargo/env" 2>/dev/null || true
    [[ -n "$user_cargo_dir" ]] && [[ -f "/home/${SUDO_USER}/.cargo/env" ]] \
        && source "/home/${SUDO_USER}/.cargo/env" 2>/dev/null || true
    if ! command -v cargo >/dev/null 2>&1; then
        json_event error "cargo not found in PATH -- install Rust on this host"; return 1
    fi

    local built="${TN_SOURCE_DIR}/target/release/telcoin-network"
    local pre_build_hash=""
    [[ -f "$built" ]] && pre_build_hash=$(sha256sum "$built" | awk '{print $1}')

    local build_log
    if ! build_log="$(build_log_file)"; then
        json_event error "could not create a build log in ${TMPDIR:-/tmp}; nothing was built"
        return 1
    fi
    json_event step "Building ${new_ref} (${cargo_features:-no features}) -- this can take 20-40 minutes; log: ${build_log}"
    pushd "$TN_SOURCE_DIR" >/dev/null
    # shellcheck disable=SC2086
    if ! cargo build --release $cargo_features 9>&- >"$build_log" 2>&1; then
        popd >/dev/null
        json_event error "cargo build failed -- see ${build_log} on the host"
        return 1
    fi
    popd >/dev/null

    # Inspected only after cargo returned (see prepare_source_build).
    _uc_built_binary_ok "$built" || { json_event error "build produced no regular file owned by the build account at ${built}"; return 1; }
    if ! "$built" --version >/dev/null 2>&1; then
        json_event error "built binary failed its --version check"; return 1
    fi
    local new_version binary_hash
    new_version=$("$built" --version 2>/dev/null | head -1)
    binary_hash=$(sha256sum "$built" | awk '{print $1}')
    if [[ -n "$pre_build_hash" && "$pre_build_hash" == "$binary_hash" ]]; then
        json_event step "Note: binary hash unchanged -- cargo decided no rebuild was needed for ${new_ref}"
    fi

    if ! write_pending_state <<EOF
PHASE=build_complete
INSTALL_METHOD=source
OLD_REF=${current_ref}
NEW_REF=${new_ref}
NEW_VERSION=${new_version}
BUILT_BINARY=${built}
BUILT_HASH=${binary_hash}
PREPARED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
    then
        json_event error "could not write pending state at $(pending_state_path)"
        return 1
    fi
    # The UI cannot ask at apply time, so a one-way target is announced here.
    storage_migration_begin "$(installed_source_ref)" "$new_ref"
    json_emit "{\"event\":\"done\",\"ok\":true,\"phase\":\"prepare\",\"new_ref\":\"$(json_escape "$new_ref")\",\"new_version\":\"$(json_escape "$new_version")\"}"
}

json_prepare_docker() {
    local arg="$1"
    local current_image
    current_image=$(detect_current_docker_image) || {
        json_event error "could not read current docker image from unit"; return 1; }
    # A bare release tag is composed against this network's repository; a full
    # reference must already be that repository by digest or by a release tag
    # (tn_docker_image_allowed). Nothing is pulled otherwise.
    local new_image net repo="" pull_log
    net="$(tn_detect_network 2>/dev/null)" || net=""
    if [[ "$arg" == *:* || "$arg" == */* || "$arg" == *@* ]]; then
        new_image="$arg"
    else
        if declare -F tn_docker_repo_for >/dev/null 2>&1; then
            repo="$(tn_docker_repo_for "$net" 2>/dev/null)" || repo=""
        elif [[ "$net" == "testnet" ]]; then
            repo="$GAR_IMAGE_BASE"
        fi
        if [[ -z "$repo" ]]; then
            json_event error "no image repository is known for network '${net:-unknown}'; nothing pulled"; return 1
        fi
        new_image="${repo}:${arg}"
    fi
    if ! validate_docker_image "$new_image" "$net"; then
        json_event error "image refused: ${new_image} is not this network's repository by digest or by a release tag; nothing pulled"; return 1
    fi

    json_event step "Pulling ${new_image}"
    # The pull log: a fresh root-only file, never a fixed name in /tmp.
    if ! pull_log="$(build_log_file)"; then
        json_event error "could not create a log file for the image pull"; return 1
    fi
    # 9>&-: the pull must not hold the update lock (see update_lock).
    if ! docker pull "$new_image" 9>&- >"$pull_log" 2>&1; then
        json_event error "image pull failed -- see ${pull_log} on the host"; return 1
    fi
    rm -f -- "$pull_log"

    # Image ID of what we just pulled -- apply verifies the restarted
    # container is actually running THIS image, not merely "something healthy".
    local pulled_image_id
    pulled_image_id=$(docker image inspect --format '{{.Id}}' "$new_image" 2>/dev/null || echo "")

    if ! write_pending_state <<EOF
PHASE=pull_complete
INSTALL_METHOD=docker
OLD_IMAGE=${current_image}
NEW_IMAGE=${new_image}
PULLED_IMAGE_ID=${pulled_image_id}
PREPARED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
    then
        json_event error "could not write pending state at $(pending_state_path)"
        return 1
    fi
    # The UI cannot ask at apply time, so a one-way target is announced here.
    storage_migration_begin "${current_image##*/}" "${new_image##*/}"
    json_emit "{\"event\":\"done\",\"ok\":true,\"phase\":\"prepare\",\"new_image\":\"$(json_escape "$new_image")\"}"
}

json_apply() {
    local install_method="$1"
    if [[ "$install_method" == "existing" ]]; then
        existing_update_refusal; return 1
    fi
    if [[ ! -f "$(pending_state_path)" ]]; then
        json_event error "no pending update to apply"; return 1
    fi
    local pending_method
    pending_method=$(read_pending_state | grep '^INSTALL_METHOD=' | cut -d= -f2 || true)
    if [[ -n "$pending_method" && "$pending_method" != "$install_method" ]]; then
        json_event error "pending update was prepared for '${pending_method}' but node is '${install_method}'"
        return 1
    fi
    # In JSON mode a validator restart needs an explicit --yes (replaces the typed
    # CONFIRM of interactive mode); never restart a validator implicitly. Gate on
    # RUNTIME on-chain status, not the install-time role hint: require --yes when the
    # registry reports a validator OR can't confirm otherwise (RPC down / unknown),
    # and skip it only when this node is definitively NOT a validator.
    if node_is_onchain_validator_or_unknown && [[ "$ASSUME_YES" != "true" ]]; then
        json_event error "validator apply requires explicit confirmation (--yes)"; return 1
    fi
    case "$install_method" in
        source) json_apply_source ;;
        docker) json_apply_docker ;;
        *) json_event error "install method '${install_method}' cannot be applied"; return 1 ;;
    esac
}

json_apply_source() {
    local state built old_ref new_ref new_version expected_hash
    if ! state="$(read_pending_state)"; then
        json_event error "the pending update cannot be read (see stderr) -- discard it and prepare again"
        return 1
    fi
    built="$(pending_field "$state" BUILT_BINARY)"
    old_ref="$(pending_field "$state" OLD_REF)"
    new_ref="$(pending_field "$state" NEW_REF)"
    new_version="$(pending_field "$state" NEW_VERSION)"
    expected_hash="$(pending_field "$state" BUILT_HASH)"
    if [[ -z "$built" || ! -f "$built" ]]; then
        json_event error "prepared binary not found at ${built:-?}"; return 1
    fi
    local installed="${DEFAULT_INSTALL_DIR}/telcoin-network"
    if [[ ! -f "$installed" ]]; then
        json_event error "installed binary not found at ${installed}"; return 1
    fi
    local refusal
    if refusal="$(apply_root_dir_refusal "$installed")"; then
        json_event error "$refusal"; return 1
    fi
    # Warn-only in --json mode (see apply_source_update for the running ref).
    storage_migration_begin "$(installed_source_ref)" "$new_ref" || return 1

    # Root-only backup; the rollback checks its sha256 before putting it back.
    backup_installed_binary "$installed" || { json_event error "could not back up current binary"; return 1; }

    update_epoch_wait || { json_event error "the committee quorum check refused the stop; nothing was changed on the running node"; return 1; }
    json_event step "Stopping ${SERVICE_NAME}"
    wait_for_service_stopped "$SERVICE_NAME"

    json_event step "Installing new binary"
    # A failed install leaves the previous binary in place (see
    # apply_source_update).
    if ! tn_install_root_binary "$built" "$installed"; then
        json_event error "failed to install the new binary; the previous binary is unchanged and was restarted"
        start_service 2>/dev/null || true
        return 1
    fi
    if [[ "$(sha256sum "$installed" | awk '{print $1}')" != "$expected_hash" ]]; then
        if restore_installed_binary "$installed"; then
            json_event error "the installed binary does not match the prepared build; the previous binary was put back and restarted"
            start_service 2>/dev/null || true
        else
            json_event error "the installed binary does not match the prepared build and the previous binary could not be put back; service left stopped -- $(binary_restore_hint "$installed")"
        fi
        return 1
    fi

    # Drop the retired --observer flag from the start wrapper (see
    # apply_source_update): back up, strip, and restore on rollback below.
    local wrapper wrapper_backed=false undo
    wrapper="$(tn_node_launch_target 2>/dev/null || true)"
    wrapper="${wrapper##* }"
    if observer_strip_needed "$wrapper" "$new_ref"; then
        if apply_root_dir_refusal "$wrapper" >/dev/null || ! backup_unit_file "$wrapper"; then
            json_event warn "could not back up ${wrapper} -- leaving the retired --observer flag in place"
        else
            wrapper_backed=true
            if tn_node_strip_observer_flag "$wrapper"; then
                json_event step "stripped retired --observer flag from ${wrapper}"
            else
                json_event warn "could not strip the retired --observer flag from ${wrapper} -- continuing"
            fi
        fi
    fi

    update_rerender_launch
    json_event step "Starting ${SERVICE_NAME} on new binary"
    if [[ "$STORAGE_MIGRATION" == "true" ]]; then STORAGE_MIGRATION_STARTED=true; fi
    start_service

    json_event step "Verifying node health"
    local verify_ok=false
    if verify_health_after_restart; then
        if verify_installed_binary_hash "$installed" "$expected_hash"; then
            verify_ok=true
        else
            json_event step "installed binary does not match the prepared build -- failing verify"
        fi
    fi
    if [[ "$verify_ok" == "true" ]]; then
        clear_pending_state
        # Record the now-running ref so the UI reports the installed binary's
        # version (not the source checkout, which has moved to new_ref).
        write_source_version_marker "$DEFAULT_INSTALL_DIR" "$TN_SOURCE_DIR" "$new_ref"
        json_emit "{\"event\":\"done\",\"ok\":true,\"phase\":\"apply\",\"new_ref\":\"$(json_escape "$new_ref")\",\"new_version\":\"$(json_escape "$new_version")\"}"
        return 0
    fi

    undo="$(binary_restore_hint "$installed")"
    if [[ "$wrapper_backed" == "true" ]]; then
        undo="${undo} && $(unit_restore_hint "$wrapper")"
    fi
    # One-way update: no rollback (see apply_source_update).
    if [[ "$STORAGE_MIGRATION" == "true" ]]; then
        storage_migration_verify_failed "$new_ref" "$undo"
        return 1
    fi

    json_event step "Post-update verification failed -- rolling back to previous binary"
    wait_for_service_stopped "$SERVICE_NAME"
    # If the restore fails, do NOT start the service: it would come up on the
    # new binary and a passing re-verify would misreport "rolled back".
    if ! restore_installed_binary "$installed"; then
        json_emit "{\"event\":\"done\",\"ok\":false,\"phase\":\"apply\",\"rolled_back\":false,\"msg\":\"$(json_escape "health check failed AND backup restore failed; service left stopped -- restore by hand: ${undo}")\"}"
        return 1
    fi
    # The old binary goes back with the wrapper it ran under.
    if [[ "$wrapper_backed" == "true" ]] && ! restore_unit_file "$wrapper"; then
        json_event warn "could not restore ${wrapper} from ${UNIT_BK_PATH}"
    fi
    start_service
    if verify_health_after_restart; then
        clear_pending_state
        json_emit "{\"event\":\"done\",\"ok\":false,\"phase\":\"apply\",\"rolled_back\":true,\"msg\":\"health check failed; rolled back to previous binary\"}"
    else
        json_emit "{\"event\":\"done\",\"ok\":false,\"phase\":\"apply\",\"rolled_back\":false,\"msg\":\"health check failed and rollback failed; inspect journalctl -u ${SERVICE_NAME}\"}"
    fi
    return 1
}

json_apply_docker() {
    local state old_image new_image pulled_image_id
    if ! state="$(read_pending_state)"; then
        json_event error "the pending update cannot be read (see stderr) -- discard it and prepare again"
        return 1
    fi
    old_image="$(pending_field "$state" OLD_IMAGE)"
    new_image="$(pending_field "$state" NEW_IMAGE)"
    pulled_image_id="$(pending_field "$state" PULLED_IMAGE_ID)"
    if [[ -z "$old_image" || -z "$new_image" ]]; then
        json_event error "pending state is incomplete -- cannot apply"; return 1
    fi
    # The image reference lives in the start wrapper on current installs and in
    # the systemd unit only on legacy ones -- resolve whichever this node uses.
    local launch_file
    launch_file=$(docker_launch_file) || {
        json_event error "could not resolve docker launch config (wrapper or unit)"; return 1; }
    local refusal
    if refusal="$(apply_root_dir_refusal "$launch_file")"; then
        json_event error "$refusal"; return 1
    fi
    update_swap_precheck "$launch_file" "$old_image" || { json_event error "the launch file is not the current start script; nothing was changed"; return 1; }
    # Warn-only in --json mode (see apply_docker_update).
    storage_migration_begin "${old_image##*/}" "${new_image##*/}" || return 1
    backup_unit_file "$launch_file" || { json_event error "could not back up launch config"; return 1; }

    update_epoch_wait || { json_event error "the committee quorum check refused the stop; nothing was changed on the running node"; return 1; }
    json_event step "Stopping ${SERVICE_NAME}"
    wait_for_service_stopped "$SERVICE_NAME"

    # Rendered again with the new image (see apply_docker_update).
    json_event step "Writing ${new_image} into ${launch_file}"
    if ! update_swap_image "$new_image" "$launch_file"; then
        json_event error "launch config image not updated -- restoring backup"
        restore_unit_file "$launch_file" 2>/dev/null || \
            json_event error "backup restore also failed -- restore by hand: $(unit_restore_hint "$launch_file")"
        systemctl daemon-reload 2>/dev/null || true
        start_service 2>/dev/null || true
        return 1
    fi

    json_event step "Starting ${SERVICE_NAME} on new image"

    if [[ "$STORAGE_MIGRATION" == "true" ]]; then STORAGE_MIGRATION_STARTED=true; fi
    start_service

    json_event step "Verifying node health"
    local verify_ok=false
    if verify_health_after_restart; then
        if verify_running_image_id "$pulled_image_id"; then
            verify_ok=true
        else
            json_event step "running container is not on the pulled image -- failing verify"
        fi
    fi
    if [[ "$verify_ok" == "true" ]]; then
        clear_pending_state
        json_emit "{\"event\":\"done\",\"ok\":true,\"phase\":\"apply\",\"new_image\":\"$(json_escape "$new_image")\"}"
        return 0
    fi

    # One-way update: no rollback (see apply_docker_update).
    if [[ "$STORAGE_MIGRATION" == "true" ]]; then
        storage_migration_verify_failed "$new_image" "$(unit_restore_hint "$launch_file") && systemctl daemon-reload"
        return 1
    fi

    json_event step "Post-update verification failed -- rolling back to previous image"
    wait_for_service_stopped "$SERVICE_NAME"
    # If the restore fails, do NOT start the service: it would come up on the
    # new image and a passing re-verify would misreport "rolled back".
    if ! restore_unit_file "$launch_file"; then
        json_emit "{\"event\":\"done\",\"ok\":false,\"phase\":\"apply\",\"rolled_back\":false,\"msg\":\"$(json_escape "health check failed AND backup restore failed; service left stopped -- restore by hand: $(unit_restore_hint "$launch_file")")\"}"
        return 1
    fi
    systemctl daemon-reload 2>/dev/null || true
    start_service
    if verify_health_after_restart; then
        clear_pending_state
        json_emit "{\"event\":\"done\",\"ok\":false,\"phase\":\"apply\",\"rolled_back\":true,\"msg\":\"health check failed; rolled back to previous image\"}"
    else
        json_emit "{\"event\":\"done\",\"ok\":false,\"phase\":\"apply\",\"rolled_back\":false,\"msg\":\"health check and rollback failed; inspect journalctl -u ${SERVICE_NAME}\"}"
    fi
    return 1
}

json_discard() {
    if [[ -f "$(pending_state_path)" ]]; then
        clear_pending_state
        json_emit "{\"event\":\"done\",\"ok\":true,\"phase\":\"discard\",\"msg\":\"pending update cleared\"}"
    else
        json_emit "{\"event\":\"done\",\"ok\":true,\"phase\":\"discard\",\"msg\":\"no pending update to discard\"}"
    fi
}

# check_root for a --json run, which must say why it stops: check_root exits 1
# with only an [ERROR] line on stderr. Ask it in a subshell first and, when it
# says no, send the reason as an error event, which update_on_exit repeats in
# the done; then the real check_root. Same as setup-node's json_require_root.
json_require_root() {
    local rc=0
    (check_root) >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -eq 1 ]]; then
        json_event error "update-node.sh must run as root"
    fi
    check_root
}

# The fds are already swapped (main), so check_root and detect_node print on
# stderr; when they exit, they have sent an error event naming the cause and
# update_on_exit sends the done event.
run_json_mode() {
    json_require_root
    detect_node
    # Serialize mutating runs (a UI apply racing a CLI apply double-stops the
    # service and races the pending-state/binary swap). Read-only check runs
    # stay lock-free so the dashboard poll never blocks a real update.
    case "$JSON_ACTION" in
        prepare|apply|discard)
            if ! update_lock; then
                json_event error "another update is already running${TN_UPDATE_LOCK_HOLDER:+ (PID ${TN_UPDATE_LOCK_HOLDER})} -- wait for it to finish"
                return 1
            fi
            update_migrate_ownership || return 1
            ;;
    esac
    case "$JSON_ACTION" in
        prepare|apply) update_legacy_refusal || return 1 ;;
    esac
    local install_method
    if ! install_method=$(detect_install_method); then
        json_event error "INSTALL_METHOD is set more than once in .node-meta -- remove the extra lines, then try again"
        return 1
    fi
    case "$JSON_ACTION" in
        check)   json_check   "$install_method" ;;
        prepare) json_prepare "$install_method" "$JSON_REF" ;;
        apply)   json_apply   "$install_method" ;;
        discard) json_discard ;;
        *)       json_event error "unknown or missing --json action"; return 1 ;;
    esac
}

# =============================================================================
# MAIN MENU
# =============================================================================

# show_pending_summary STATE -- show a pending state read by read_pending_state.
show_pending_summary() {
    local state="${1:-}" phase prepared_at
    phase="$(pending_field "$state" PHASE)"
    prepared_at="$(pending_field "$state" PREPARED_AT)"
    print_header "Pending update detected"
    printf '%s\n' "$state" | sed 's/^/    /'
    echo ""
    print_info "Prepared at: ${prepared_at}  (phase: ${phase})"
    echo ""
}

main() {
    local arg refusal
    # --json is found before anything prints: from here on stdout carries JSON
    # events only. The trap releases the update lock on every exit and closes a
    # --json run with a done event when nothing else did.
    for arg in "$@"; do
        if [[ "$arg" == "--json" ]]; then
            JSON_MODE=true
        fi
    done
    if [[ "$JSON_MODE" == "true" ]]; then
        json_setup_fds
    fi
    trap update_on_exit EXIT

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --validator|--observer) LEGACY_ROLE_FLAG="$1"; shift ;;
            --discard)   DISCARD_PENDING=true; JSON_ACTION="discard"; shift ;;
            --json)      JSON_MODE=true; shift ;;
            --check)     JSON_ACTION="check"; shift ;;
            --prepare)   JSON_ACTION="prepare"; shift ;;
            --apply)     JSON_ACTION="apply"; shift ;;
            --ref)
                # No version floor: an older ref is a legitimate rollback. A word
                # starting with "--" is the next flag, not a value; any other
                # word starting with "-" is refused as a ref.
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    update_arg_error "--ref needs a value: a release tag, branch, commit or image tag."
                    exit 1
                fi
                if refusal="$(update_ref_refusal "$2")"; then
                    update_arg_error "$refusal"
                    exit 1
                fi
                JSON_REF="$2"; shift 2
                ;;
            --yes)       ASSUME_YES=true; shift ;;
            --no-epoch-wait) NO_EPOCH_WAIT=true; shift ;;
            --allow-quorum-risk) TN_ALLOW_QUORUM_RISK=1; shift ;;
            -h|--help)
                # The header block only: everything up to its closing rule.
                awk 'NR == 1 { next } /^# =+$/ { if (++rules == 2) exit; next } { sub(/^# ?/, ""); print }' "$0"
                if [[ "$JSON_MODE" == "true" ]]; then
                    json_emit '{"event":"done","ok":true,"phase":"help","msg":"usage printed on stderr"}'
                fi
                exit 0
                ;;
            *) print_warn "Unknown argument: $1" >&2; shift ;;
        esac
    done

    # The role flags are accepted for old callers and ignored. One stderr line
    # in human mode; nothing in --json mode, whose stdout stays pure JSON.
    if [[ -n "$LEGACY_ROLE_FLAG" && "$JSON_MODE" != "true" ]]; then
        print_info "Ignoring ${LEGACY_ROLE_FLAG}: the node's role is decided on-chain, not by a flag." >&2
    fi

    # Non-interactive JSON mode short-circuits the whole interactive flow.
    if [[ "$JSON_MODE" == "true" ]]; then
        run_json_mode
        exit $?
    fi

    check_root
    print_header "Telcoin Network Node Update  v${SCRIPT_VERSION}"
    detect_node
    print_info "Service:       ${SERVICE_NAME}"

    local install_method
    if ! install_method=$(detect_install_method); then
        print_error "INSTALL_METHOD is set more than once in $(node_meta_path 2>/dev/null || echo .node-meta) -- remove the extra lines, then run this again."
        exit 1
    fi
    print_info "Install method: ${install_method:-unknown (no .node-meta found)}"

    case "$install_method" in
        existing)
            existing_update_refusal
            exit 1
            ;;
        source|docker)
            ;;
        *)
            print_error "Install method is unknown -- cannot proceed safely."
            print_info "Re-run setup-node.sh to rewrite .node-meta, or supply"
            print_info "INSTALL_METHOD={source|docker} manually in $(node_meta_path || echo "$(tn_resolve_config_dir)/.node-meta")"
            exit 1
            ;;
    esac

    # Everything past this point can mutate node state (discard, prepare,
    # apply) -- one update at a time. See tn_acquire_update_lock. The
    # ownership migration runs first, under the lock.
    update_lock || exit 1
    update_migrate_ownership || exit 1
    update_legacy_refusal || exit 1

    # Handle --discard flag. A pending state that cannot be read (a symlink, a
    # wrong owner, a malformed value) can still be discarded.
    local pstate=""
    if [[ "$DISCARD_PENDING" == "true" ]]; then
        if [[ -e "$(pending_state_path)" || -L "$(pending_state_path)" ]]; then
            pstate="$(read_pending_state)" || pstate="(cannot be read; see above)"
            show_pending_summary "$pstate"
            if confirm "Discard this pending update?"; then
                clear_pending_state
                print_ok "Pending state cleared."
            else
                print_info "Kept."
            fi
        else
            print_info "No pending update to discard."
        fi
        exit 0
    fi

    # Pending state present -> offer apply/discard
    if [[ -e "$(pending_state_path)" || -L "$(pending_state_path)" ]]; then
        if ! pstate="$(read_pending_state)"; then
            print_error "The pending update in $(pending_state_path) cannot be used (see above)."
            print_info "Use --discard to clear it, then prepare again."
            exit 1
        fi
        show_pending_summary "$pstate"

        # Sanity check: install method in pending state must match current
        local pending_method
        pending_method="$(pending_field "$pstate" INSTALL_METHOD)"
        if [[ "$pending_method" != "$install_method" ]]; then
            print_warn "Pending state was prepared for install method '${pending_method}',"
            print_warn "but this node is now '${install_method}'. Refusing to apply."
            print_info "Use --discard to clear the pending state."
            exit 1
        fi

        echo "  1) Apply now"
        echo "  2) Discard and prepare a different update"
        echo "  3) Exit (leave pending for later)"
        echo ""
        local choice
        read -r -p "  Enter choice [1-3]: " choice
        case "$choice" in
            1)
                if [[ "$install_method" == "source" ]]; then
                    apply_source_update
                else
                    apply_docker_update
                fi
                ;;
            2)
                clear_pending_state
                print_info "Pending state cleared."
                echo ""
                # Fall through to the no-pending-state flow below
                ;;
            *) print_info "Exiting. Pending update remains; run this script again to apply."; exit 0 ;;
        esac
        # If choice was 2, continue to the picker flow
        if [[ "$choice" != "2" ]]; then
            exit 0
        fi
    fi

    # No pending state (or pending state was just discarded) -> show what is
    # available, let the operator pick a version, then ask prepare vs apply.
    local target=""
    if [[ "$install_method" == "source" ]]; then
        target=$(pick_source_version "$(detect_network)") || { print_info "No update prepared."; exit 0; }
    else
        target=$(pick_docker_version) || { print_info "No update prepared."; exit 0; }
    fi

    local action
    action=$(pick_action)
    case "$action" in
        prepare)
            if [[ "$install_method" == "source" ]]; then
                prepare_source_build "$target"
            else
                prepare_docker_update "$target"
            fi
            print_info "Run this script again when you are ready to apply."
            ;;
        prepare_and_apply)
            if [[ "$install_method" == "source" ]]; then
                prepare_source_build "$target" && apply_source_update
            else
                prepare_docker_update "$target" && apply_docker_update
            fi
            ;;
        cancel) print_info "Cancelled." ;;
    esac
}

main "$@"
