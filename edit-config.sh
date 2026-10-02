#!/usr/bin/env bash
# =============================================================================
# edit-config.sh -- Telcoin Network Node Configuration Editor
#
# Edit the configuration of the node installed on this server (the single
# resolved systemd service) without manually editing systemd service files.
# Changes take effect on the next restart. There is no role to pick: the
# node's role is decided on-chain each epoch, so every node is configured the
# same way.
#
# An edit is refused while update-node.sh is applying an update (the two share
# the update lock). Before restarting a node that votes in the current
# committee, the script waits for the epoch to close and settle when the
# boundary is within five minutes, at most 30 minutes. A rollback restart
# never waits.
#
# USAGE:
#   sudo bash edit-config.sh                          # interactive menu
#   sudo bash edit-config.sh --set <field>=<value>    # one edit, then restart
#   sudo bash edit-config.sh --json --set <field>=<value>
#                                                     # the same, as JSON events
#   --no-epoch-wait                                   # restart without the epoch wait
#
# TN_SKIP_EPOCH_WAIT=1 skips the epoch wait the same way as --no-epoch-wait.
#
# --set restarts the node after the edit and checks that it stays up. If it
# does not, every file the edit changed is put back and the node restarted.
# When the value is already in place nothing is written and the node is not
# restarted.
#
# Fields for --set:
#   primary_listener=<multiaddr>      /ip4/<addr>/udp/<port>/quic-v1 or /ip6/...
#   worker_listener=<multiaddr>
#   metrics=<IPv4:PORT>|off           add, change or remove --metrics
#   verbosity=-v|-vv|-vvv|-vvvv|-vvvvv
#   docker_image=<registry/path:tag>  Docker installs only; pulled first
#   bootstrap_peers=<path>|none       peers the node dials at start instead of
#                                     the bootstrap servers in its genesis: an
#                                     absolute path to a YAML or JSON map keyed
#                                     by BLS public key, at most 64 KiB. The
#                                     node binary checks it, then it is
#                                     installed as /etc/telcoin/bootstrap-peers.yaml.
#                                     Needs v0.15.0-adiri or later and a start
#                                     wrapper (a node started straight from its
#                                     systemd unit is refused). none removes
#                                     the flag and the file.
#   state_export=off|unlimited|N      write the execution state at each epoch
#                                     boundary (--enable-state-export,
#                                     v0.13.0-adiri or later); N keeps only the
#                                     last N epochs (1 to 999999,
#                                     --state-export-keep, v0.15.0-adiri or later)
#   allow_private_forward_targets=true|false
#                                     parameters.yaml: whether the node may
#                                     forward transactions to committee RPC
#                                     endpoints on private addresses. true is
#                                     refused on testnet and mainnet.
# =============================================================================
# --help prints the block above only. Not advertised there: --observer and
# --validator are still accepted and ignored, because the node's role is
# decided on-chain and older copies of the UI helper pass one of them on every
# --json call.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
if ! version_gte "${COMMON_VERSION:-0}" "1.6.0"; then
    _tn_old="lib/common.sh ${COMMON_VERSION:-unknown} is older than 1.6.0. Run update-scripts.sh and try again."
    case " $* " in
        *" --json "*) printf '{"event":"error","msg":"%s"}\n{"event":"done","ok":false,"msg":"%s"}\n' "$_tn_old" "$_tn_old" ;;
        *) printf '[ERROR] %s\n' "$_tn_old" >&2 ;;
    esac
    exit 1
fi

readonly SCRIPT_VERSION="1.3.0"

# The largest bootstrap peers file accepted. A map of a few dozen peers is a
# few KiB, and the whole map travels as one command-line argument.
readonly PEERS_MAX_BYTES=65536

# Build the systemd unit file path from a unit BASE name (e.g. "telcoin"). The
# path is rooted at TN_ROOT_PREFIX like the lib/fallback.sh resolvers (empty
# in production, a fixture tree under test).
service_file_for() {
    printf '%s/etc/systemd/system/%s.service' "${TN_ROOT_PREFIX:-}" "$1"
}

# Resolve the selected node's data dir from .node-meta (DATA_DIR=), falling back
# to the resolved data dir (unified /var/lib/telcoin, or legacy role dir) for
# older installs. Mirrors check-node.sh so all scripts agree on the path.
detect_data_dir() {
    local meta default dd
    meta="$(node_meta_path 2>/dev/null || true)"
    default="$(tn_resolve_data_dir)"
    if [[ -n "$meta" ]] && [[ -f "$meta" ]]; then
        dd=$(grep "^DATA_DIR=" "$meta" 2>/dev/null | cut -d= -f2 || true)
        if [[ -n "$dd" ]] && [[ -d "$dd" ]]; then
            echo "$dd"
            return 0
        fi
    fi
    echo "$default"
    return 0
}

TARGET_SERVICE=""
TARGET_SERVICE_FILE=""
# The file that actually carries the node-launch line (image, flags, listener
# values): the start wrapper on current installs, the unit only on legacy
# installs that still inline the command in ExecStart. Same resolution as
# update-node.sh (tn_node_launch_target, the 7b10e97 pattern) -- editing the
# unit on a wrapper install silently changes nothing the service reads.
TARGET_LAUNCH_FILE=""

# --no-epoch-wait: restart without waiting for the epoch boundary.
NO_EPOCH_WAIT=false

# --json: stdout carries JSON events only (see json_setup_fds). --set runs one
# edit without the menu, in either mode.
JSON_MODE=false
EDIT_SET_GIVEN=false
EDIT_SET_PAIR=""
# The field of the --set pair, for the done event edit_on_exit may have to send.
EDIT_SET_FIELD=""
# --observer / --validator as passed (the last one wins). Both are retired and
# ignored: the node's role is decided on-chain. Older copies of the UI helper
# still pass one on every --json call, so they must keep parsing cleanly.
LEGACY_ROLE_FLAG=""
# Set once the run has sent its done event, so edit_on_exit never adds another.
JSON_DONE_SENT=false
# The last error reported; the done event repeats it.
EDIT_LAST_ERROR=""

# The update lock this run holds (edit_lock), and whether it is the flock kind,
# which lives on file descriptor 9 until that is closed.
EDIT_LOCK_HELD=false
EDIT_LOCK_FLOCK=false

# Files the current edit changed, each with its backup (edit_backup). An empty
# backup means the file did not exist before, so a restore removes it.
EDIT_BK_FILES=()
EDIT_BK_COPIES=()

# True from the first edit_backup of an edit until the restart that applies it
# is issued (or, in the menu, the operator chooses to restart later). A run that
# ends in between puts the files back on its way out (edit_on_exit).
EDIT_PENDING=false
# True once a --set run has issued its restart.
EDIT_RESTARTED=false
# The signal that ended the run (TERM, INT or HUP), for the messages.
EDIT_SIGNAL=""
# A staged peers file or parameters.yaml not yet moved into place; edit_on_exit
# removes it.
EDIT_TMP=""
# true or false once the run has tried to put an edit back on its way out.
EDIT_ROLLED_BACK=""

# Output of edit_launch_spec: the runner spec of the node command.
EDIT_SPEC=""

# =============================================================================
# HELPERS
# =============================================================================

# Create a timestamped backup of the systemd unit file. Must succeed before any
# in-place edit. Echoes the backup path so the caller can show or roll back.
backup_service_file() {
    local file="$1"
    local ts backup
    ts=$(date -u '+%Y%m%d-%H%M%S')
    backup="${file}.bak.${ts}"
    if ! cp -p "$file" "$backup"; then
        print_error "Could not create backup of ${file}" >&2
        return 1
    fi
    # Info to stderr so callers capturing the path via $(...) still show it
    # to the operator (same convention as update-node.sh backup_unit_file).
    print_info "Backup written: ${backup}" >&2
    echo "$backup"
}

# Read a value from the service file Environment= lines
read_env_var() {
    local var_name="$1"
    local service_file="$2"
    grep "Environment=\"${var_name}=" "$service_file" 2>/dev/null | \
        sed "s/.*Environment=\"${var_name}=//;s/\"//"
}

# Read the ExecStart line from the service file
read_exec_start() {
    local service_file="$1"
    grep "^ExecStart=" "$service_file" 2>/dev/null | sed 's/^ExecStart=//'
}

# Resolve TARGET_LAUNCH_FILE for the detected service. Falls back to the unit
# file when tn_node_launch_target cannot resolve (or names a missing wrapper,
# e.g. a legacy install), which restores the old behaviour exactly.
resolve_launch_file() {
    local line
    line="$(tn_node_launch_target 2>/dev/null || true)"
    TARGET_LAUNCH_FILE="${line##* }"   # last field; install paths never contain spaces
    [[ -n "$TARGET_LAUNCH_FILE" && -f "$TARGET_LAUNCH_FILE" ]] || TARGET_LAUNCH_FILE="$TARGET_SERVICE_FILE"
}

# Effective node-launch text for image and listener inspection. Wrapper files
# carry the command across backslash-continued lines; join them so the readers
# see one logical line. Unit files keep the old ExecStart read.
read_launch_line() {
    local file="$1"
    if [[ "$file" == *.service ]]; then
        read_exec_start "$file"
    else
        sed -e 's/[[:space:]]*\\$//' "$file" 2>/dev/null | tr '\n' ' '
    fi
}

# launch_node_commands FILE -- the number of live commands in launch file FILE
# that run `node` with --http, which is what lib/common.sh takes as the node
# command. The file is read the same way: backslash-continued lines joined;
# # lines, and ; lines in a unit, skipped; in a shell wrapper a comment line
# ends a continued command. Words are split on blanks only, enough to count.
launch_node_commands() {
    local unit=0
    if [[ "$1" == *.service ]]; then
        unit=1
    fi
    awk -v u="$unit" '
        function flush(    n, i, w, seen) {
            n = split(cmd, w, /[ \t]+/)
            seen = 0
            for (i = 1; i <= n; i++) {
                if (w[i] == "node") seen = 1
                else if (seen && w[i] == "--http") { count++; break }
            }
            cmd = ""
        }
        /^[ \t]*#/ || (u == 1 && /^[ \t]*;/) {
            if (u != 1) flush()
            next
        }
        {
            line = $0
            more = sub(/\\$/, "", line)
            cmd = cmd " " line
            if (!more) flush()
        }
        END { flush(); print count + 0 }
    ' "$1" 2>/dev/null
}

# True when the resolved launch config runs the node via docker.
is_docker_install() {
    read_launch_line "$TARGET_LAUNCH_FILE" | grep -qF "docker run"
}

# Read VAR=value out of the launch text. Handles all three carrier forms:
# docker -e "VAR=..." (wrapper), export VAR="..." (binary wrapper), and the
# unquoted legacy inline-unit form. Strips the quotes the wrapper forms carry.
read_listener_from_launch() {
    local varname="$1"
    read_launch_line "$TARGET_LAUNCH_FILE" | \
        grep -oE "${varname}=\"?[^ \"]+" | head -1 | cut -d= -f2- | tr -d '"'
}

# Set one listener var everywhere the service can read it. Docker: the -e line
# in the launch config (wrapper or legacy unit). Binary/source: the unit's
# Environment= line AND the wrapper's export line -- the wrapper export is what
# the process actually sees on current installs, the unit line is kept in sync
# for legacy readers. The [^ \"] bound keeps the wrapper's closing quote.
set_listener_var() {
    local varname="$1" value="$2"
    if is_docker_install; then
        perl -i -pe "s|${varname}=[^ \"]+|${varname}=${value}|g" "$TARGET_LAUNCH_FILE"
    else
        set_env_var "$varname" "$value" "$TARGET_SERVICE_FILE"
        if [[ "$TARGET_LAUNCH_FILE" != "$TARGET_SERVICE_FILE" ]]; then
            perl -i -pe "s|^(export ${varname}=).*\$|\${1}\"${value}\"|" "$TARGET_LAUNCH_FILE"
        fi
    fi
}

# Back up every file an edit can touch: the launch file, plus the unit when
# they differ (listener edits keep both in sync). Must succeed before any edit.
# The backups are recorded (edit_backup), so a run stopped before the restart
# puts them back. Menu only: a launch file with more than one node command is
# refused here. Callers return 0 when it fails: the menu runs under errexit, so
# a non-zero return from an edit function would end the script.
backup_edit_targets() {
    if ! edit_launch_unambiguous; then
        echo ""
        read -r -p "  Press Enter to return to menu..." || true
        return 1
    fi
    edit_backup "$TARGET_LAUNCH_FILE" || return 1
    if [[ "$TARGET_LAUNCH_FILE" != "$TARGET_SERVICE_FILE" ]]; then
        edit_backup "$TARGET_SERVICE_FILE" || return 1
    fi
    edit_report_backups
}

# Replace or add an Environment= line in the service file
set_env_var() {
    local var_name="$1"
    local new_value="$2"
    local service_file="$3"

    if grep -q "Environment=\"${var_name}=" "$service_file"; then
        # Replace existing
        sed -i "s|Environment=\"${var_name}=.*\"|Environment=\"${var_name}=${new_value}\"|" "$service_file"
    else
        # Add after the last Environment= line
        sed -i "/^Environment=/a Environment=\"${var_name}=${new_value}\"" "$service_file"
    fi
}

# Replace the verbosity flag (-v .. -vvvvv) in a launch file. The old
# `sed s| -v\+ |...|` matched the FIRST " -v " on the line -- on a docker
# launch line that is the -v VOLUME flag, not verbosity, and on wrapper files
# the verbosity token sits at line start where the leading-space pattern never
# matched at all. Match -v{1,5} only when followed by a line continuation,
# another --flag, or end of line: a volume -v is always followed by a path
# (and `command -v tool` by a bare word), so neither can match.
set_verbosity() {
    local new_verbosity="$1"
    local service_file="$2"
    perl -i -pe "s/(^|\s)-v{1,5}(?=\s+(?:\\\\|--)|\s*\$)/\${1}${new_verbosity}/" "$service_file"
}

# Swap docker image OLD for NEW in a launch file. The images reach perl through
# the environment, so an image pinned by digest (name@sha256:...) is copied
# literally instead of being read as a perl array.
swap_docker_image() {
    local old="$1" new="$2" file="$3"
    TN_OLD_IMAGE="$old" TN_NEW_IMAGE="$new" \
        perl -i -pe 's/\Q$ENV{TN_OLD_IMAGE}\E/$ENV{TN_NEW_IMAGE}/g' "$file"
}

# The image a docker launch line runs: the first registry-looking word, else
# the last word with a tag. Empty when there is none.
launch_docker_image() {
    local exec_start="$1" image
    image="$(grep -oE 'us-docker[^ ]+|gcr\.io[^ ]+|ghcr\.io[^ ]+' <<<"$exec_start" | head -1 || true)"
    if [[ -z "$image" ]]; then
        image="$(awk '{for(i=1;i<=NF;i++) if($i ~ /:[a-z0-9]/) print $i}' <<<"$exec_start" | tail -1 || true)"
    fi
    printf '%s' "$image"
}

# =============================================================================
# JSON OUTPUT AND REPORTING
#
# fd handling mirrors update-node.sh: json_setup_fds dups the real stdout to
# fd 3 and points stdout at stderr, so every print_* line is harmless noise on
# stderr while fd 3 carries newline-delimited JSON the caller streams and
# parses. main does this, and installs edit_on_exit, before it parses the
# arguments, so a --json run that stops early (a bad argument, not root, no
# node, the lock held) still prints JSON only and ends with one done event.
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
# edit_on_exit does not send a second one.
json_emit() {
    case "$1" in
        '{"event":"done"'*) JSON_DONE_SENT=true ;;
    esac
    printf '%s\n' "$1" >&3
}

json_event() {
    # json_event <event> <msg>
    json_emit "{\"event\":\"${1}\",\"msg\":\"$(json_escape "${2:-}")\"}"
}

# Reporting for code the menu and --set share: a JSON event in --json mode, a
# print_* line otherwise. edit_error also keeps the message for the done event.
edit_step() {
    if [[ "$JSON_MODE" == "true" ]]; then json_event step "$1"; else print_step "$1"; fi
}
edit_log() {
    if [[ "$JSON_MODE" == "true" ]]; then json_event log "$1"; else print_info "$1"; fi
}
edit_ok() {
    if [[ "$JSON_MODE" == "true" ]]; then json_event log "$1"; else print_ok "$1"; fi
}
edit_warn() {
    if [[ "$JSON_MODE" == "true" ]]; then json_event warn "$1"; else print_warn "$1"; fi
}
edit_error() {
    EDIT_LAST_ERROR="$1"
    if [[ "$JSON_MODE" == "true" ]]; then json_event error "$1"; else print_error "$1"; fi
}

# edit_done <ok> <field> <value> <msg> [rolled_back] -- the result of a --set
# run: the done event in --json mode (value only when ok), a final [OK] or
# [ERROR] line otherwise.
edit_done() {
    local ok="$1" field="$2" value="$3" msg="$4" rb="${5:-}" rbpart="" valpart=""
    if [[ "$JSON_MODE" != "true" ]]; then
        if [[ "$ok" == "true" ]]; then print_ok "$msg"; else print_error "$msg"; fi
        return 0
    fi
    if [[ -n "$rb" ]]; then
        rbpart=",\"rolled_back\":${rb}"
    fi
    if [[ "$ok" == "true" ]]; then
        valpart=",\"value\":\"$(json_escape "$value")\""
    fi
    json_emit "{\"event\":\"done\",\"ok\":${ok}${rbpart},\"field\":\"$(json_escape "$field")\"${valpart},\"msg\":\"$(json_escape "$msg")\"}"
}

# edit_on_exit -- the EXIT trap, installed by main before it parses anything.
# When an edit was written and the restart that applies it was not issued (the
# run was stopped during the epoch wait, say), it first puts every changed file
# back (edit_abort_pending): left on disk, the edit would load at the next
# restart or reboot with no health check and no rollback. Then it removes a
# staged file, releases the update lock and, in --json mode, sends
#   {"event":"done","ok":false[,"rolled_back":...],"field":...,"msg":...}
# when the run is ending without having sent its done event, so every --json
# run ends with exactly one done whichever way it stopped. The message is the
# last error's, else the signal's, else a pointer to stderr.
edit_on_exit() {
    local rc=$?
    local msg field="" rb=""
    # The cleanup must finish: no errexit, no second signal, and a write to a
    # closed pipe fails instead of ending the run.
    set +e
    trap '' TERM INT HUP PIPE
    if [[ "$EDIT_PENDING" == "true" ]]; then
        edit_abort_pending "$rc"
    fi
    if [[ -n "$EDIT_TMP" ]]; then
        rm -f "$EDIT_TMP" 2>/dev/null
        EDIT_TMP=""
    fi
    tn_release_update_lock
    if [[ "$JSON_MODE" == "true" && "$JSON_DONE_SENT" != "true" ]]; then
        msg="$EDIT_LAST_ERROR"
        if [[ -z "$msg" && -n "$EDIT_SIGNAL" ]]; then
            if [[ "$EDIT_RESTARTED" == "true" ]]; then
                msg="stopped by SIG${EDIT_SIGNAL} after the restart was issued; the edit stays in place"
            else
                msg="stopped by SIG${EDIT_SIGNAL}; nothing was changed"
            fi
        fi
        msg="${msg:-edit-config.sh stopped before reporting a result; the reason is on its stderr}"
        if [[ -n "$EDIT_ROLLED_BACK" ]]; then
            rb=",\"rolled_back\":${EDIT_ROLLED_BACK}"
        fi
        if [[ -n "$EDIT_SET_FIELD" ]]; then
            field=",\"field\":\"$(json_escape "$EDIT_SET_FIELD")\""
        fi
        json_emit "{\"event\":\"done\",\"ok\":false${rb}${field},\"msg\":\"$(json_escape "$msg")\"}" 2>/dev/null
    fi
    return "$rc"
}

# edit_abort_pending RC -- the run is ending (status RC) after an edit was
# written and before the restart that applies it was issued. Put every file the
# edit changed back, and say so: an error event in --json mode, an [ERROR] line
# otherwise.
edit_abort_pending() {
    local why
    if [[ -n "$EDIT_SIGNAL" ]]; then
        why="Stopped by SIG${EDIT_SIGNAL} before the restart"
    else
        why="Stopped (exit status ${1}) before the restart"
    fi
    if edit_restore_backups; then
        EDIT_ROLLED_BACK=true
        edit_error "${why}, so the edit was rolled back: every file it changed is as it was before this run."
    else
        EDIT_ROLLED_BACK=false
        edit_error "${why}, and putting the files back failed (see the errors above): copy each .bak file over its original by hand."
    fi
}

# edit_require_root -- check_root, except that a --json run reports the
# refusal as an error event first (check_root itself only prints).
edit_require_root() {
    if [[ "$JSON_MODE" == "true" ]] && ! (check_root) >/dev/null 2>&1; then
        edit_error "edit-config.sh must run as root"
        exit 1
    fi
    check_root
}

# =============================================================================
# UPDATE LOCK, BACKUPS AND EPOCH WAIT
# =============================================================================

# edit_lock -- take the update lock (tn_acquire_update_lock) before an apply
# path changes anything. update-node.sh holds it while it applies an update: it
# backs up the launch file before its epoch wait and puts that copy back on a
# rollback, which would silently undo an edit saved in between. The lock is
# released by edit_unlock between menu edits and by edit_on_exit at the end of
# the run. Returns 0 at once when this run holds it already.
edit_lock() {
    if [[ "$EDIT_LOCK_HELD" == "true" ]]; then
        return 0
    fi
    TN_EXIT_TRAP_OWNED=1
    if ! tn_acquire_update_lock >/dev/null 2>&1; then
        edit_error "an update is in progress${TN_UPDATE_LOCK_HOLDER:+ (PID ${TN_UPDATE_LOCK_HOLDER})}; try again when it has finished"
        return 1
    fi
    EDIT_LOCK_HELD=true
    EDIT_LOCK_FLOCK=false
    if [[ -z "${TN_UPDATE_LOCK_DIR:-}" ]]; then
        EDIT_LOCK_FLOCK=true
    fi
    return 0
}

# edit_unlock -- release the update lock after a menu edit, so a menu left open
# does not hold up update-node.sh. tn_release_update_lock removes the mkdir
# lock; the flock lock goes when file descriptor 9 closes.
edit_unlock() {
    if [[ "$EDIT_LOCK_HELD" != "true" ]]; then
        return 0
    fi
    tn_release_update_lock
    if [[ "$EDIT_LOCK_FLOCK" == "true" ]]; then
        exec 9>&-
    fi
    EDIT_LOCK_HELD=false
    EDIT_LOCK_FLOCK=false
    return 0
}

# menu_lock -- edit_lock for the menu: on refusal, hold the message on screen.
menu_lock() {
    if edit_lock; then
        return 0
    fi
    echo ""
    read -r -p "  Press Enter to return to menu..." || true
    return 1
}

# edit_reset_backups -- start a new edit with no files recorded.
edit_reset_backups() {
    EDIT_BK_FILES=()
    EDIT_BK_COPIES=()
    EDIT_PENDING=false
}

# edit_backup FILE -- before the first change to FILE in this edit, copy it to
# FILE.bak.<UTC time> and record the pair for edit_restore_backups. A FILE that
# does not exist yet is recorded as new, so the restore removes it. From here
# until the restart is issued the edit is pending (EDIT_PENDING). rc 1, with an
# error reported, when the copy fails.
edit_backup() {
    local file="$1" i copy
    i=0
    while [[ "$i" -lt "${#EDIT_BK_FILES[@]}" ]]; do
        if [[ "${EDIT_BK_FILES[$i]}" == "$file" ]]; then
            return 0
        fi
        i=$((i + 1))
    done
    copy=""
    if [[ -e "$file" ]]; then
        copy="${file}.bak.$(date -u '+%Y%m%d-%H%M%S')"
        if [[ -e "$copy" ]]; then
            copy="${copy}.$$"
        fi
        if ! cp -p "$file" "$copy" 2>/dev/null; then
            edit_error "could not back up ${file}"
            return 1
        fi
    fi
    EDIT_BK_FILES+=("$file")
    EDIT_BK_COPIES+=("$copy")
    EDIT_PENDING=true
    return 0
}

# edit_any_changed -- rc 0 when a file recorded by edit_backup now differs from
# its backup, a new file now exists, or a recorded file is gone.
edit_any_changed() {
    local i file copy
    i=0
    while [[ "$i" -lt "${#EDIT_BK_FILES[@]}" ]]; do
        file="${EDIT_BK_FILES[$i]}"
        copy="${EDIT_BK_COPIES[$i]}"
        if [[ -z "$copy" ]]; then
            if [[ -e "$file" ]]; then
                return 0
            fi
        elif [[ ! -e "$file" ]] || ! cmp -s "$copy" "$file"; then
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# edit_restore_backups -- undo the current edit: put back every file
# edit_backup recorded (a file that was new is removed), then reload systemd.
# Each file that cannot be restored is reported; rc 1 if there was one.
edit_restore_backups() {
    local i file copy bad=0
    EDIT_PENDING=false
    i=0
    while [[ "$i" -lt "${#EDIT_BK_FILES[@]}" ]]; do
        file="${EDIT_BK_FILES[$i]}"
        copy="${EDIT_BK_COPIES[$i]}"
        if [[ -z "$copy" ]]; then
            if ! rm -f "$file" 2>/dev/null; then
                edit_error "could not remove ${file}"
                bad=1
            fi
        elif ! cp -p "$copy" "$file" 2>/dev/null; then
            edit_error "could not restore ${file} from ${copy}"
            bad=1
        fi
        i=$((i + 1))
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
    return "$bad"
}

# edit_drop_backups -- delete the backups of an edit that changed nothing.
edit_drop_backups() {
    local c
    for c in ${EDIT_BK_COPIES[@]+"${EDIT_BK_COPIES[@]}"}; do
        if [[ -n "$c" ]]; then
            rm -f "$c" 2>/dev/null || true
        fi
    done
    edit_reset_backups
    return 0
}

# edit_report_backups -- name the backups of an edit that changed something.
edit_report_backups() {
    local c
    for c in ${EDIT_BK_COPIES[@]+"${EDIT_BK_COPIES[@]}"}; do
        if [[ -n "$c" ]]; then
            edit_log "Backup written: ${c}"
        fi
    done
    return 0
}

# edit_wait_say <step|log|warn> <msg> -- progress printer for
# tn_wait_restart_window: a JSON event of the same name in --json mode, a
# print_* line otherwise.
edit_wait_say() {
    case "${1:-}" in
        step) edit_step "${2:-}" ;;
        warn) edit_warn "${2:-}" ;;
        *)    edit_log "${2:-}" ;;
    esac
    return 0
}

# edit_epoch_wait -- called just before the node restarts (before it stops, for
# the BLS passphrase), after the lock is held, and never before a rollback
# restart. When the node votes in the current committee and the epoch boundary
# is close, tn_wait_restart_window (lib/common.sh) holds the restart until the
# epoch has closed and settled, at most TN_EPOCH_WAIT_MAX seconds.
# --no-epoch-wait or TN_SKIP_EPOCH_WAIT=1 skips it. Always returns 0.
edit_epoch_wait() {
    if [[ "$NO_EPOCH_WAIT" == "true" ]]; then
        edit_wait_say log "Not waiting for the epoch boundary (--no-epoch-wait)."
        return 0
    fi
    if [[ "${TN_SKIP_EPOCH_WAIT:-}" == "1" ]]; then
        edit_wait_say log "Not waiting for the epoch boundary (TN_SKIP_EPOCH_WAIT=1)."
        return 0
    fi
    tn_wait_restart_window "$(tn_local_rpc_url)" edit_wait_say
    return 0
}

# =============================================================================
# FIELD SETTERS
#
# One function per field that edits a launch flag or parameters.yaml, shared by
# the menu and --set. Each validates its value, records every file it is about
# to change with edit_backup, and makes the change. rc 0 saved (possibly
# nothing differed; the caller checks with edit_any_changed), rc 1 refused or
# failed, with the reason reported and the caller restoring the backups. The
# lock is held and the restart is left to the caller.
# =============================================================================

# edit_launch_unambiguous -- rc 0 unless TARGET_LAUNCH_FILE holds more than one
# node command with --http. Then it is not clear which one starts the node, and
# the tn_launch_flag_* helpers would edit only the first and leave the other
# stale, so every edit of the launch file is refused with the reason.
edit_launch_unambiguous() {
    local n
    n="$(launch_node_commands "$TARGET_LAUNCH_FILE")"
    if [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -gt 1 ]]; then
        edit_error "${TARGET_LAUNCH_FILE} has ${n} node commands with --http, so it is not clear which one starts the node. edit-config changes a launch file only when it has exactly one; remove or comment out the others and try again."
        return 1
    fi
    return 0
}

# edit_launch_spec -- set EDIT_SPEC to the runner spec (docker:<image> or
# binary:<path>) of the node command in TARGET_LAUNCH_FILE (tn_launch_runner).
# Every launch-flag edit starts here, so a launch file the parser cannot read,
# or one with more than one node command, is never edited.
edit_launch_spec() {
    local rc=0
    edit_launch_unambiguous || return 1
    EDIT_SPEC="$(tn_launch_runner "$TARGET_LAUNCH_FILE" 2>/dev/null)" || rc=$?
    case "$rc" in
        0) return 0 ;;
        1) edit_error "${TARGET_LAUNCH_FILE} starts the node with neither a docker image nor a node binary this script recognises; edit it by hand" ;;
        2) edit_error "${TARGET_LAUNCH_FILE} has no node command with --http; edit it by hand" ;;
        3) edit_error "the node command in ${TARGET_LAUNCH_FILE} cannot be parsed; edit it by hand" ;;
        *) edit_error "cannot read ${TARGET_LAUNCH_FILE}" ;;
    esac
    return 1
}

# edit_need_flag SPEC FLAG -- rc 0 when `node --help` of the installed release
# lists FLAG (tn_node_has_flag); otherwise report why and return 1.
edit_need_flag() {
    local rc=0
    tn_node_has_flag "$1" "$2" || rc=$?
    case "$rc" in
        0) return 0 ;;
        1) edit_error "the installed release has no $2; update the node first" ;;
        *) edit_error "could not run the node binary (${1}) to check for $2" ;;
    esac
    return 1
}

# edit_flag_change set|unset FLAG [VALUE] -- one tn_launch_flag_set or
# tn_launch_flag_unset on TARGET_LAUNCH_FILE. rc 0 when the flag is now as
# asked (the helper's "no change needed" included); 1, reported, when the
# helper refused or failed, in which case it left the file untouched.
edit_flag_change() {
    local op="$1" flag="$2" rc=0
    if [[ "$op" == "set" && $# -ge 3 ]]; then
        tn_launch_flag_set "$TARGET_LAUNCH_FILE" "$flag" "$3" || rc=$?
    elif [[ "$op" == "set" ]]; then
        tn_launch_flag_set "$TARGET_LAUNCH_FILE" "$flag" || rc=$?
    else
        tn_launch_flag_unset "$TARGET_LAUNCH_FILE" "$flag" || rc=$?
    fi
    case "$rc" in
        0|1) return 0 ;;
        2) edit_error "${TARGET_LAUNCH_FILE} has no node command with --http, so ${flag} cannot be changed there; edit it by hand" ;;
        3) edit_error "${TARGET_LAUNCH_FILE} cannot be edited automatically (the node command ends in a comment or cannot be parsed); change ${flag} by hand" ;;
        *) edit_error "could not write ${TARGET_LAUNCH_FILE}" ;;
    esac
    return 1
}

# set_metrics VALUE -- IPv4:PORT adds --metrics to the node command or changes
# it; off removes it.
set_metrics() {
    local value="$1"
    if [[ "$value" != "off" ]] && ! validate_ip_port "$value"; then
        edit_error "invalid metrics address (want IPv4:PORT or off): ${value}"
        return 1
    fi
    edit_launch_spec || return 1
    edit_backup "$TARGET_LAUNCH_FILE" || return 1
    if [[ "$value" == "off" ]]; then
        edit_flag_change unset --metrics || return 1
    else
        edit_flag_change set --metrics "$value" || return 1
    fi
    return 0
}

# peers_file_ok FILE -- rc 0 when FILE can be a bootstrap peers file: a
# readable, non-empty regular file of at most 64 KiB that its group and other
# users can read too. The read bits matter because the map does not stay
# private anyway: the installed copy is 0644, and the check passes the map on
# the command line of the node binary, where other local users can see it.
# Otherwise rc 1, with the reason on stdout. Mirrors setup-node.sh.
peers_file_ok() {
    local f="$1" mode size
    if [[ ! -f "$f" || ! -r "$f" ]]; then
        printf '%s is not a readable regular file' "$f"
        return 1
    fi
    # GNU stat, then BSD stat (macOS).
    mode="$(stat -L -c '%a' "$f" 2>/dev/null || true)"
    if [[ ! "$mode" =~ ^[0-7]+$ ]]; then
        mode="$(stat -L -f '%Lp' "$f" 2>/dev/null || true)"
    fi
    if [[ ! "$mode" =~ ^[0-7]+$ ]]; then
        printf 'could not read the permissions of %s' "$f"
        return 1
    fi
    if (( (8#$mode & 8#044) != 8#044 )); then
        printf '%s is mode %s: other users cannot read it. edit-config accepts only a peers file that others can already read, because the installed copy is world-readable (0644) and the check passes the map on the command line of the node binary, where other users can see it. Run chmod 644 %s first' "$f" "$mode" "$f"
        return 1
    fi
    size="$(wc -c < "$f" 2>/dev/null | tr -d '[:space:]')"
    if [[ ! "$size" =~ ^[0-9]+$ ]]; then
        printf 'could not read the size of %s' "$f"
        return 1
    fi
    if [[ "$size" -eq 0 ]]; then
        printf '%s is empty' "$f"
        return 1
    fi
    if [[ "$size" -gt "$PEERS_MAX_BYTES" ]]; then
        printf '%s is %s bytes; a bootstrap peers file can be at most 64 KiB' "$f" "$size"
        return 1
    fi
    return 0
}

# set_bootstrap_peers VALUE -- VALUE is an absolute path to a YAML or JSON map
# of peers keyed by BLS public key, which the node dials at start instead of
# the bootstrap servers in its genesis; or none. The installed release checks
# the map itself (tn_node_parse_check), the file is installed as
# <config dir>/bootstrap-peers.yaml (0644, root), and the node command gets
# --bootstrap-peers "$(cat <that file>)", which the start wrapper expands at
# each start. A systemd unit cannot run that $(cat ...), so a node started
# straight from its unit is refused. none removes the flag and the file. The
# parse check is the only time a run hands the map to a node binary, and it
# comes after every check on the file.
set_bootstrap_peers() {
    local value="$1" peers spec tmp msg rc
    peers="$(tn_resolve_config_dir)/bootstrap-peers.yaml"
    edit_launch_spec || return 1
    spec="$EDIT_SPEC"
    if [[ "$value" == "none" ]]; then
        edit_backup "$TARGET_LAUNCH_FILE" || return 1
        edit_flag_change unset --bootstrap-peers || return 1
        if [[ -e "$peers" ]]; then
            edit_backup "$peers" || return 1
            if ! rm -f "$peers"; then
                edit_error "could not remove ${peers}"
                return 1
            fi
        fi
        return 0
    fi
    if [[ "$TARGET_LAUNCH_FILE" == *.service ]]; then
        edit_error "bootstrap_peers needs a start wrapper: this node starts from the systemd unit ${TARGET_LAUNCH_FILE}, and systemd cannot run the \$(cat ...) that loads the peers file at each start. Convert the unit to a start wrapper first."
        return 1
    fi
    if [[ "$value" != /* ]]; then
        edit_error "bootstrap_peers takes an absolute path or none, not ${value}"
        return 1
    fi
    if ! msg="$(peers_file_ok "$value")"; then
        edit_error "${msg}."
        return 1
    fi
    edit_need_flag "$spec" --bootstrap-peers || return 1

    # Check the staged copy, so what gets installed is exactly what the node
    # accepted. cp -p gives the copy the mode of the file it actually read, so
    # a path swapped since the check above is caught before the map reaches a
    # process list. $(cat) drops trailing newlines here as it does in the
    # wrapper.
    tmp="${peers}.new.$$"
    EDIT_TMP="$tmp"
    if ! cp -p "$value" "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        edit_error "could not copy ${value} to ${tmp}"
        return 1
    fi
    if ! peers_file_ok "$tmp" >/dev/null; then
        rm -f "$tmp"
        edit_error "${value} changed while it was being copied. Check the file and try again."
        return 1
    fi
    edit_log "Checking ${value} with the node binary (${spec})"
    rc=0
    msg="$(tn_node_parse_check "$spec" --bootstrap-peers "$(cat "$tmp")")" || rc=$?
    msg="${msg#error: }"
    if [[ "$rc" -ne 0 ]]; then
        rm -f "$tmp"
        if [[ "$rc" -eq 1 ]]; then
            edit_error "the node rejects ${value} as a --bootstrap-peers map (${msg}). Each key must be a node's BLS public key and each value the primary and workers entries from that node's node-info.yaml."
        else
            edit_error "could not check ${value} with the node binary: ${msg}"
        fi
        return 1
    fi
    if [[ -f "$peers" ]] && cmp -s "$tmp" "$peers"; then
        rm -f "$tmp"
    else
        if ! chmod 0644 "$tmp" || ! chown 0:0 "$tmp"; then
            rm -f "$tmp"
            edit_error "could not give ${tmp} mode 0644 and owner root"
            return 1
        fi
        if ! edit_backup "$peers"; then
            rm -f "$tmp"
            return 1
        fi
        if ! mv -f "$tmp" "$peers"; then
            rm -f "$tmp"
            edit_error "could not install ${peers}"
            return 1
        fi
    fi
    EDIT_TMP=""
    edit_backup "$TARGET_LAUNCH_FILE" || return 1
    edit_flag_change set --bootstrap-peers "\"\$(cat ${peers})\"" || return 1
    return 0
}

# set_state_export VALUE -- off removes --enable-state-export and
# --state-export-keep; unlimited sets the first (the node writes the execution
# state at every epoch boundary and keeps every export) and removes the second;
# N sets both, so only the last N epochs are kept. The installed release must
# list each flag it gets.
set_state_export() {
    local value="$1" spec
    case "$value" in
        off|unlimited) ;;
        *)
            if [[ ! "$value" =~ ^[1-9][0-9]{0,5}$ ]]; then
                edit_error "state_export takes off, unlimited or a number of epochs from 1 to 999999, not ${value}"
                return 1
            fi
            ;;
    esac
    edit_launch_spec || return 1
    spec="$EDIT_SPEC"
    if [[ "$value" != "off" ]]; then
        edit_need_flag "$spec" --enable-state-export || return 1
        if [[ "$value" != "unlimited" ]]; then
            edit_need_flag "$spec" --state-export-keep || return 1
        fi
    fi
    edit_backup "$TARGET_LAUNCH_FILE" || return 1
    case "$value" in
        off)
            edit_flag_change unset --state-export-keep || return 1
            edit_flag_change unset --enable-state-export || return 1
            ;;
        unlimited)
            edit_flag_change set --enable-state-export || return 1
            edit_flag_change unset --state-export-keep || return 1
            ;;
        *)
            edit_flag_change set --enable-state-export || return 1
            edit_flag_change set --state-export-keep "$value" || return 1
            ;;
    esac
    return 0
}

# params_forward_value FILE -- the value of the top-level key
# allow_private_forward_targets in parameters.yaml FILE, lowercased, with
# quotes and any trailing comment removed. Nothing when the key is absent.
params_forward_value() {
    awk -v sq="'" '
        /^"?allow_private_forward_targets"?[ \t]*:/ {
            v = $0
            sub(/^[^:]*:[ \t]*/, "", v)
            sub(/[ \t]*#.*$/, "", v)
            gsub(/"/, "", v)
            gsub(sq, "", v)
            sub(/[ \t]+$/, "", v)
            print tolower(v)
            exit
        }' "$1" 2>/dev/null || true
}

# params_with_forward FILE VALUE -- print parameters.yaml FILE with the
# top-level key allow_private_forward_targets set to VALUE. The first
# occurrence is rewritten where it stands (with any indented lines under it),
# a repeat is dropped, and a missing key is added at the end. Every other line
# is copied unchanged.
params_with_forward() {
    awk -v val="$2" '
        skip && /^[ \t]+[^ \t]/ { next }
        { skip = 0 }
        /^"?allow_private_forward_targets"?[ \t]*:/ {
            if (!done) print "allow_private_forward_targets: " val
            done = 1
            skip = 1
            next
        }
        { print }
        END { if (!done) print "allow_private_forward_targets: " val }
    ' "$1"
}

# set_private_forward_targets VALUE -- true or false for the top-level key
# allow_private_forward_targets in <data dir>/parameters.yaml, which the node
# reads at start (there is no flag for it). A node outside the committee
# forwards the transactions it receives to the RPC endpoint a committee member
# advertises. With false (the default) it refuses endpoints on loopback,
# private and link-local addresses, so a committee member cannot aim this
# node's HTTP requests at hosts inside its network. true suits only a network
# where one operator runs every committee node, so it is refused unless the
# node's genesis declares a chain id, and refused on testnet and mainnet, whose
# committees have independent operators. tn_is_public_chain_id names the
# Association's networks; devnet is one of them, but its chain id (32285) is
# allowed here like any private chain.
set_private_forward_targets() {
    local value="$1" data_dir params genesis id name cur tmp
    case "$value" in
        true|false) ;;
        *)
            edit_error "allow_private_forward_targets takes true or false, not ${value}"
            return 1
            ;;
    esac
    data_dir="$(detect_data_dir)"
    params="${data_dir}/parameters.yaml"
    if [[ ! -f "$params" || ! -r "$params" ]]; then
        edit_error "${params} is missing or unreadable; the setting lives there"
        return 1
    fi
    if [[ "$value" == "true" ]]; then
        genesis="${data_dir}/genesis/genesis.yaml"
        if ! id="$(tn_genesis_chain_id "$genesis")"; then
            edit_error "cannot read the chain id from ${genesis}; allow_private_forward_targets=true is only for a private network, so it stays off"
            return 1
        fi
        if tn_is_public_chain_id "$id" && [[ "$id" != "$DEVNET_CHAIN_ID" ]]; then
            name="mainnet"
            if [[ "$id" == "$TESTNET_CHAIN_ID" ]]; then
                name="testnet"
            fi
            edit_error "this node runs chain ${id} (${name}), a public network; allow_private_forward_targets=true is only for a network where one operator runs every committee node"
            return 1
        fi
    fi
    # An absent key reads as false, the node's default, so false is then a no-op.
    cur="$(params_forward_value "$params")"
    if [[ "${cur:-false}" == "$value" ]]; then
        return 0
    fi
    edit_backup "$params" || return 1
    tmp="${params}.new.$$"
    EDIT_TMP="$tmp"
    if ! params_with_forward "$params" "$value" > "$tmp" 2>/dev/null \
        || [[ ! -s "$tmp" ]] \
        || [[ "$(params_forward_value "$tmp")" != "$value" ]]; then
        rm -f "$tmp"
        edit_error "could not prepare the new ${params}"
        return 1
    fi
    # cat > keeps the owner and mode of the file the node reads.
    if ! cat "$tmp" > "$params"; then
        rm -f "$tmp"
        edit_error "could not write ${params}"
        return 1
    fi
    rm -f "$tmp"
    EDIT_TMP=""
    if [[ "$(params_forward_value "$params")" != "$value" ]]; then
        edit_error "${params} does not read back allow_private_forward_targets: ${value}"
        return 1
    fi
    return 0
}

# set_docker_image IMAGE -- pull IMAGE and swap it into the launch file (Docker
# installs only). Mirrors edit_docker_image. The same image is a no-op.
set_docker_image() {
    local new_image="$1" exec_start current_image
    if ! validate_docker_image "$new_image"; then
        edit_error "invalid docker image reference: ${new_image}"
        return 1
    fi
    exec_start="$(read_launch_line "$TARGET_LAUNCH_FILE")"
    if ! grep -qF "docker run" <<<"$exec_start"; then
        edit_error "node is not a docker install"
        return 1
    fi
    current_image="$(launch_docker_image "$exec_start")"
    if [[ -z "$current_image" ]]; then
        edit_error "could not determine current docker image"
        return 1
    fi
    if [[ "$current_image" == "$new_image" ]]; then
        return 0
    fi
    edit_launch_unambiguous || return 1
    edit_step "Pulling image ${new_image}"
    if ! docker pull "$new_image" >&2; then
        edit_error "failed to pull image: ${new_image}"
        return 1
    fi
    edit_backup "$TARGET_LAUNCH_FILE" || return 1
    swap_docker_image "$current_image" "$new_image" "$TARGET_LAUNCH_FILE"
}

# The fields --set accepts.
edit_field_known() {
    case "$1" in
        primary_listener|worker_listener|metrics|verbosity|docker_image) return 0 ;;
        bootstrap_peers|state_export|allow_private_forward_targets) return 0 ;;
    esac
    return 1
}

# set_field FIELD VALUE -- validate and save one --set field (rc as for the
# setters above).
set_field() {
    local field="$1" value="$2"
    case "$field" in
        primary_listener|worker_listener)
            if ! validate_multiaddr "$value"; then
                edit_error "invalid multiaddr: ${value}"
                return 1
            fi
            edit_launch_unambiguous || return 1
            edit_backup "$TARGET_LAUNCH_FILE" || return 1
            edit_backup "$TARGET_SERVICE_FILE" || return 1
            if [[ "$field" == "primary_listener" ]]; then
                set_listener_var "PRIMARY_LISTENER_MULTIADDR" "$value"
            else
                set_listener_var "WORKER_LISTENER_MULTIADDR" "$value"
            fi
            ;;
        metrics)
            set_metrics "$value" ;;
        verbosity)
            if [[ ! "$value" =~ ^-v{1,5}$ ]]; then
                edit_error "verbosity must be -v .. -vvvvv"
                return 1
            fi
            edit_launch_unambiguous || return 1
            edit_backup "$TARGET_LAUNCH_FILE" || return 1
            set_verbosity "$value" "$TARGET_LAUNCH_FILE"
            ;;
        docker_image)
            set_docker_image "$value" ;;
        bootstrap_peers)
            set_bootstrap_peers "$value" ;;
        state_export)
            set_state_export "$value" ;;
        allow_private_forward_targets)
            set_private_forward_targets "$value" ;;
        *)
            edit_error "field not editable: ${field}"
            return 1
            ;;
    esac
}

# =============================================================================
# APPLY CHANGES
# =============================================================================

# Apply changes from the menu: reload systemd and optionally restart. The epoch
# wait runs only when the operator chose to restart. Releases the update lock.
# The edit stops being pending (EDIT_PENDING) when the restart is issued or the
# operator chooses to restart later; a run stopped before either, at the
# prompt or during the wait, puts the files back (edit_on_exit).
apply_changes() {
    set +e  # Restart failure should not exit the script
    print_step "Applying changes..."
    systemctl daemon-reload
    print_ok "systemd reloaded"

    echo ""
    if confirm "Restart the node now to apply changes?"; then
        edit_epoch_wait
        EDIT_PENDING=false
        print_step "Restarting ${TARGET_SERVICE}..."
        systemctl restart "$TARGET_SERVICE" || true
        sleep 3
        if systemctl is-active --quiet "$TARGET_SERVICE"; then
            print_ok "Node restarted successfully"
        else
            print_error "Node failed to restart. Check logs:"
            print_info "  sudo tail -30 /var/log/telcoin/${TARGET_SERVICE}.log"
            print_info "  journalctl -u ${TARGET_SERVICE} --no-pager -n 30"
        fi
    else
        EDIT_PENDING=false
        print_info "Changes saved. Restart the node when ready:"
        print_info "  sudo systemctl restart ${TARGET_SERVICE}"
    fi
    edit_unlock
    echo ""
    read -r -p "  Press Enter to return to menu..."
    set -e
}

# menu_apply FN VALUE LABEL -- save one edit from the menu with a field setter:
# take the update lock, run FN VALUE, then offer the restart (apply_changes).
# A failed setter has its partial changes put back; an edit that changed
# nothing is not offered a restart.
menu_apply() {
    local fn="$1" value="$2" label="$3" rc=0
    menu_lock || return 0
    edit_reset_backups
    "$fn" "$value" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        edit_restore_backups || true
        edit_unlock
        echo ""
        read -r -p "  Press Enter to return to menu..." || true
        return 0
    fi
    if ! edit_any_changed; then
        edit_drop_backups
        edit_unlock
        print_info "${label} is already set that way; nothing changed."
        echo ""
        read -r -p "  Press Enter to return to menu..." || true
        return 0
    fi
    edit_report_backups
    print_ok "${label} saved"
    apply_changes
}

# edit_restart -- the --set restart: reload systemd, wait for the epoch
# boundary, restart, and report whether the service is active 3 seconds later.
# The edit stops being pending just before the restart is issued: a run stopped
# during the wait puts the files back, one stopped during a slow restart keeps
# the edit the restart is already applying.
edit_restart() {
    edit_step "Reloading systemd"
    if ! systemctl daemon-reload >&2 2>&1; then
        edit_warn "systemctl daemon-reload failed; restarting anyway"
    fi
    edit_epoch_wait
    EDIT_PENDING=false
    EDIT_RESTARTED=true
    edit_step "Restarting ${TARGET_SERVICE}"
    systemctl restart "$TARGET_SERVICE" >&2 2>&1 || true
    sleep 3
    systemctl is-active --quiet "$TARGET_SERVICE"
}

# =============================================================================
# NODE DETECTION
# =============================================================================

detect_node() {
    # Operators run one node per VM; resolve the single installed unit.
    if ! TARGET_SERVICE="$(tn_resolve_service)"; then
        print_error "No Telcoin node installation found."
        print_info "Run setup-node.sh first."
        exit 1
    fi
    TARGET_SERVICE_FILE="$(service_file_for "$TARGET_SERVICE")"
    resolve_launch_file
    print_ok "Detected node service: ${TARGET_SERVICE}"
}

# resolve_target -- TARGET_SERVICE, TARGET_SERVICE_FILE and TARGET_LAUNCH_FILE
# for --set. Reports and returns 1 when no node is installed.
resolve_target() {
    if ! TARGET_SERVICE="$(tn_resolve_service)"; then
        edit_error "no node installed"
        return 1
    fi
    TARGET_SERVICE_FILE="$(service_file_for "$TARGET_SERVICE")"
    if [[ ! -f "$TARGET_SERVICE_FILE" ]]; then
        edit_error "node not installed: ${TARGET_SERVICE}"
        return 1
    fi
    resolve_launch_file
}

# =============================================================================
# DISPLAY CURRENT CONFIG
# =============================================================================

show_current_config() {
    set +e  # Disable exit-on-error for config reading -- grep returning no match is fine
    print_header "Current Configuration -- ${TARGET_SERVICE}"

    # Inspect the file that actually launches the node (wrapper on current
    # installs) -- the unit's ExecStart is just the wrapper path there and
    # carries none of the flags below.
    local exec_start
    exec_start=$(read_launch_line "$TARGET_LAUNCH_FILE")

    local primary_multiaddr worker_multiaddr metrics verbosity rpc_enabled bls_pass_set
    local is_docker=false
    local docker_image=""

    # Detect if this is a Docker install
    if echo "$exec_start" | grep -qF "docker run"; then
        is_docker=true
        docker_image="$(launch_docker_image "$exec_start")"
    fi

    primary_multiaddr=$(read_env_var "PRIMARY_LISTENER_MULTIADDR" "$TARGET_SERVICE_FILE" || true)
    # No unit Environment= line (docker installs): value lives in the launch file
    if [[ -z "$primary_multiaddr" ]]; then
        primary_multiaddr=$(read_listener_from_launch "PRIMARY_LISTENER_MULTIADDR" || true)
    fi

    worker_multiaddr=$(read_env_var "WORKER_LISTENER_MULTIADDR" "$TARGET_SERVICE_FILE" || true)
    if [[ -z "$worker_multiaddr" ]]; then
        worker_multiaddr=$(read_listener_from_launch "WORKER_LISTENER_MULTIADDR" || true)
    fi

    metrics="$(tn_launch_flag_get "$TARGET_LAUNCH_FILE" --metrics 2>/dev/null)" || metrics="off"
    bls_pass_set="(set)"

    # Service user/group
    local svc_user svc_group
    svc_user=$(grep "^User=" "$TARGET_SERVICE_FILE" 2>/dev/null | cut -d= -f2)
    svc_group=$(grep "^Group=" "$TARGET_SERVICE_FILE" 2>/dev/null | cut -d= -f2)

    # Detect verbosity
    if echo "$exec_start" | grep -q "\-vvvvv"; then      verbosity="TRACE (-vvvvv)"
    elif echo "$exec_start" | grep -q "\-vvvv"; then     verbosity="DEBUG (-vvvv)"
    elif echo "$exec_start" | grep -q "\-vvv"; then      verbosity="INFO  (-vvv)"
    elif echo "$exec_start" | grep -q "\-vv"; then       verbosity="WARN  (-vv)"
    elif echo "$exec_start" | grep -q "\-v[^v]"; then    verbosity="ERROR (-v)"
    else                                                  verbosity="unknown"
    fi || true

    # RPC status: tn_launch_flag_get returns 2 when no live node line has --http.
    local rpc_addr rpc_rc=0
    rpc_addr="$(tn_launch_flag_get "$TARGET_LAUNCH_FILE" --http.addr 2>/dev/null)" || rpc_rc=$?
    case "$rpc_rc" in
        0|1)
            if [[ -z "$rpc_addr" ]] || [[ "$rpc_addr" == "127.0.0.1" ]]; then
                rpc_enabled="Enabled (private -- localhost only)"
            else
                rpc_enabled="Enabled (public -- ${rpc_addr})"
            fi
            ;;
        2) rpc_enabled="Disabled" ;;
        *) rpc_enabled="unknown" ;;
    esac

    # Bootstrap peers, state export and private forward targets.
    local peers_val peers_txt keep_val export_txt params fwd_txt
    if peers_val="$(tn_launch_flag_get "$TARGET_LAUNCH_FILE" --bootstrap-peers 2>/dev/null)"; then
        peers_txt="set: ${peers_val}"
    else
        peers_txt="none (the genesis bootstrap servers)"
    fi
    if tn_launch_flag_get "$TARGET_LAUNCH_FILE" --enable-state-export >/dev/null 2>&1; then
        if keep_val="$(tn_launch_flag_get "$TARGET_LAUNCH_FILE" --state-export-keep 2>/dev/null)"; then
            export_txt="on, keep the last ${keep_val} epochs"
        else
            export_txt="on, keep every epoch"
        fi
    else
        export_txt="off"
    fi
    params="$(detect_data_dir)/parameters.yaml"
    if [[ -r "$params" ]]; then
        fwd_txt="$(params_forward_value "$params")"
        fwd_txt="${fwd_txt:-false (default)}"
    else
        fwd_txt="unknown (no ${params})"
    fi

    # Service status
    local status
    if systemctl is-active --quiet "$TARGET_SERVICE" 2>/dev/null; then
        status="Running"
    else
        status="Stopped"
    fi

    echo ""
    printf "  %-28s %s\n" "Service status:"        "$status"
    printf "  %-28s %s\n" "Service name:"          "$TARGET_SERVICE"
    local install_method_label="Binary"
    [[ "$is_docker" == "true" ]] && install_method_label="Docker"
    printf "  %-28s %s\n" "Install method:"        "$install_method_label"
    [[ "$is_docker" == "true" ]] && printf "  %-28s %s\n" "Docker image:" "${docker_image:-unknown}" || true
    printf "  %-28s %s\n" "Service user:"          "${svc_user:-unknown}"
    printf "  %-28s %s\n" "Service group:"         "${svc_group:-unknown}"
    printf "  %-28s %s\n" "Metrics address:"       "${metrics:-unknown}"
    printf "  %-28s %s\n" "Primary listener:"      "${primary_multiaddr:-unknown}"
    printf "  %-28s %s\n" "Worker listener:"       "${worker_multiaddr:-unknown}"
    printf "  %-28s %s\n" "Log verbosity:"         "$verbosity"
    printf "  %-28s %s\n" "RPC:"                   "$rpc_enabled"
    printf "  %-28s %s\n" "BLS passphrase:"        "$bls_pass_set"
    printf "  %-28s %s\n" "Bootstrap peers:"       "$peers_txt"
    printf "  %-28s %s\n" "State export:"          "$export_txt"
    printf "  %-28s %s\n" "Private forward targets:" "$fwd_txt"
    echo ""
    set -e  # Restore exit-on-error
}

# =============================================================================
# EDIT FUNCTIONS
# =============================================================================

edit_listener_addresses() {
    set +e
    print_header "Edit Listener Addresses"

    local current_primary current_worker
    current_primary=$(read_env_var "PRIMARY_LISTENER_MULTIADDR" "$TARGET_SERVICE_FILE" || true)
    if [[ -z "$current_primary" ]]; then
        current_primary=$(read_listener_from_launch "PRIMARY_LISTENER_MULTIADDR" || true)
    fi
    current_worker=$(read_env_var "WORKER_LISTENER_MULTIADDR" "$TARGET_SERVICE_FILE" || true)
    if [[ -z "$current_worker" ]]; then
        current_worker=$(read_listener_from_launch "WORKER_LISTENER_MULTIADDR" || true)
    fi

    print_info "Current primary: ${current_primary:-unknown}"
    print_info "Current worker:  ${current_worker:-unknown}"
    echo ""
    print_info "Choose new binding:"
    echo ""
    echo "  1) IPv6   -- listen on all IPv6 interfaces (NAT-free, recommended for cloud)"
    echo "  2) IPv4   -- listen on IPv4 (home/NAT or dedicated server)"
    echo "  3) Custom -- enter multiaddrs manually"
    echo ""

    local new_primary new_worker
    local choice
    while true; do
        read -r -p "  Enter choice [1/2/3]: " choice
        case "$choice" in
            1)
                new_primary="/ip6/::/udp/${DEFAULT_P2P_PORT}/quic-v1"
                new_worker="/ip6/::/udp/${DEFAULT_WORKER_PORT}/quic-v1"
                print_ok "Binding: IPv6"
                break
                ;;
            2)
                new_primary="/ip4/0.0.0.0/udp/${DEFAULT_P2P_PORT}/quic-v1"
                new_worker="/ip4/0.0.0.0/udp/${DEFAULT_WORKER_PORT}/quic-v1"
                print_ok "Binding: IPv4 all interfaces (0.0.0.0)"
                print_info "Node will accept connections on all IPv4 interfaces."
                break
                ;;
            3)
                print_info "Expected form: /ip4/<addr>/udp/<port>/quic-v1 or /ip6/<addr>/udp/<port>/quic-v1"
                prompt_with_validation "Primary listener multiaddr" validate_multiaddr new_primary || { set -e; return; }
                prompt_with_validation "Worker listener multiaddr " validate_multiaddr new_worker || { set -e; return; }
                break
                ;;
            *) print_warn "Please enter 1, 2, or 3." ;;
        esac
    done

    menu_lock || { set -e; return; }
    backup_edit_targets || { set -e; return 0; }

    # Write wherever the service actually reads (launch file for docker,
    # unit Environment= plus wrapper export for binary/source). Multiaddrs
    # are already validated above, so the substitutions are safe.
    set_listener_var "PRIMARY_LISTENER_MULTIADDR" "$new_primary"
    set_listener_var "WORKER_LISTENER_MULTIADDR"  "$new_worker"

    print_ok "Listener addresses updated"
    print_info "Primary: ${new_primary}"
    print_info "Worker:  ${new_worker}"
    set -e
    apply_changes
}

edit_metrics() {
    print_header "Edit Metrics Address"

    local current_metrics input new_metrics
    current_metrics="$(tn_launch_flag_get "$TARGET_LAUNCH_FILE" --metrics 2>/dev/null || true)"

    print_info "Current metrics address: ${current_metrics:-none (metrics off)}"
    print_info "Format: IP:PORT (e.g. 127.0.0.1:${DEFAULT_METRICS_PORT}), or off to remove the flag"
    echo ""

    read -r -p "  New metrics address [${current_metrics:-off}]: " input || true
    new_metrics="${input:-${current_metrics:-off}}"
    menu_apply set_metrics "$new_metrics" "Metrics address"
}

edit_verbosity() {
    print_header "Edit Log Verbosity"

    print_info "Higher verbosity means more log output."
    print_info "Use INFO for normal operation, DEBUG for troubleshooting."
    echo ""
    echo "  1) ERROR  (-v)      -- errors only"
    echo "  2) WARN   (-vv)     -- warnings and errors"
    echo "  3) INFO   (-vvv)    -- recommended for production"
    echo "  4) DEBUG  (-vvvv)   -- detailed output for troubleshooting"
    echo "  5) TRACE  (-vvvvv)  -- very verbose, use sparingly"
    echo ""

    local choice
    while true; do
        read -r -p "  Enter choice [1-5]: " choice
        case "$choice" in
            1) local new_verbosity="-v";     break ;;
            2) local new_verbosity="-vv";    break ;;
            3) local new_verbosity="-vvv";   break ;;
            4) local new_verbosity="-vvvv";  break ;;
            5) local new_verbosity="-vvvvv"; break ;;
            *) print_warn "Please enter 1-5." ;;
        esac
    done

    menu_lock || return 0
    backup_edit_targets || return 0

    set_verbosity "$new_verbosity" "$TARGET_LAUNCH_FILE"
    print_ok "Log verbosity updated to: ${new_verbosity}"
    apply_changes
}

edit_rpc() {
    print_header "Edit RPC Access"

    # The --http flags live in the start wrapper on current installs, and the
    # ExecStart rewrite below only works on legacy inline units. Refuse loudly
    # instead of appending junk arguments to the unit's wrapper path.
    if [[ "$TARGET_LAUNCH_FILE" != "$TARGET_SERVICE_FILE" ]]; then
        print_warn "This install launches via a start wrapper -- RPC editing here"
        print_warn "is not supported yet for wrapper installs."
        print_info "Edit the --http flags on the last line of:"
        print_info "  ${TARGET_LAUNCH_FILE}"
        print_info "then restart: sudo systemctl restart ${TARGET_SERVICE}"
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi

    local exec_start
    exec_start=$(read_exec_start "$TARGET_SERVICE_FILE")

    echo "  1) Private (recommended) -- RPC accessible from this server only"
    echo "              No firewall changes needed. Best for personal use,"
    echo "              development, and internal tooling."
    echo ""
    echo "  2) Public                -- RPC endpoint accessible from the internet"
    echo "              Requires nginx on port 443 (HTTPS)."
    echo "              You will need to open port 443 on your firewall"
    echo "              and router. An example nginx config will be"
    echo "              generated for you to configure."
    echo ""
    echo "  3) Disabled              -- RPC completely off"
    echo ""

    # Strip every --http* flag (with or without a value) from an ExecStart line.
    # Captures --http, --http.addr, --http.port, --http.api, --http.corsdomain,
    # --http.vhosts, --http.maxconnections and any future --http.* variants.
    _strip_http_flags() {
        local exec="$1"
        # Two-pass: first remove flags that take a value, then bare --http.
        echo "$exec" | \
            sed -E 's/ --http\.[a-zA-Z.]+( +[^ -][^ ]*)?//g' | \
            sed -E 's/ --http( |$)/\1/g'
    }

    local choice
    while true; do
        read -r -p "  Enter choice [1/2/3]: " choice
        case "$choice" in
            1|2|3) break ;;
            *) print_warn "Please enter 1, 2, or 3." ;;
        esac
    done

    menu_lock || return 0
    if ! edit_launch_unambiguous; then
        echo ""
        read -r -p "  Press Enter to return to menu..." || true
        return 0
    fi
    edit_backup "$TARGET_SERVICE_FILE" || return 0
    edit_report_backups

    local current_exec clean_exec
    current_exec=$(grep "^ExecStart=" "$TARGET_SERVICE_FILE" | sed 's/^ExecStart=//')
    clean_exec=$(_strip_http_flags "$current_exec")

    case "$choice" in
        1)
            sed -i "s|^ExecStart=.*$|ExecStart=${clean_exec} --http --http.addr 127.0.0.1|" "$TARGET_SERVICE_FILE"
            print_ok "RPC set to private (localhost only)"
            ;;
        2)
            sed -i "s|^ExecStart=.*$|ExecStart=${clean_exec} --http --http.addr 0.0.0.0|" "$TARGET_SERVICE_FILE"
            print_ok "RPC set to public (0.0.0.0)"
            print_warn "Ensure you have an nginx reverse proxy configured before"
            print_warn "opening this port on your firewall."
            ;;
        3)
            sed -i "s|^ExecStart=.*$|ExecStart=${clean_exec}|" "$TARGET_SERVICE_FILE"
            print_ok "RPC disabled"
            ;;
    esac

    apply_changes
}

edit_bls_passphrase() {
    print_header "Edit BLS Passphrase"

    local passphrase_file
    passphrase_file="$(tn_resolve_config_dir)/bls-passphrase"

    if [[ ! -f "$passphrase_file" ]]; then
        print_error "Passphrase file not found at: ${passphrase_file}"
        return 1
    fi

    print_warn "Changing the BLS passphrase updates the stored passphrase used"
    print_warn "to decrypt your keys at startup. This does NOT re-encrypt your"
    print_warn "key files -- your keys must have been generated with this passphrase."
    print_warn "Only use this if you know your keys match the new passphrase."
    echo ""

    if ! confirm "Are you sure you want to change the stored passphrase?"; then
        print_info "Passphrase unchanged."
        return 0
    fi

    local new_pass new_pass_confirm
    while true; do
        read -r -s -p "  Enter new BLS passphrase: " new_pass
        echo ""
        read -r -s -p "  Confirm new BLS passphrase: " new_pass_confirm
        echo ""
        if [[ "$new_pass" == "$new_pass_confirm" ]]; then
            break
        fi
        print_warn "Passphrases do not match -- try again."
    done

    # Nothing is stopped or written before the update lock is held.
    if ! menu_lock; then
        new_pass=""
        new_pass_confirm=""
        return 0
    fi

    # Stop the service before rewriting the passphrase file so we never race
    # against a node that may have the old file mapped in its credential dir.
    # A committee node waits for the epoch boundary first: this stop is the
    # start of its restart.
    local was_active="no"
    if systemctl is-active --quiet "$TARGET_SERVICE" 2>/dev/null; then
        was_active="yes"
        edit_epoch_wait
        print_step "Stopping ${TARGET_SERVICE} before passphrase rewrite..."
        systemctl stop "$TARGET_SERVICE"
        local stop_attempts=0
        while systemctl is-active --quiet "$TARGET_SERVICE" 2>/dev/null && (( stop_attempts < 15 )); do
            sleep 1
            (( ++stop_attempts ))
        done
        if systemctl is-active --quiet "$TARGET_SERVICE" 2>/dev/null; then
            print_error "Service did not stop within 15s. Aborting passphrase rewrite."
            new_pass=""
            new_pass_confirm=""
            echo ""
            read -r -p "  Press Enter to return to menu..."
            return 1
        fi
        print_ok "Service stopped"
    fi

    # For Docker installs the passphrase is also embedded in the unit file,
    # so back up the unit before any write.
    local exec_start backup=""
    exec_start=$(grep "^ExecStart=" "$TARGET_SERVICE_FILE" 2>/dev/null || echo "")
    if echo "$exec_start" | grep -qF "docker run"; then
        backup=$(backup_service_file "$TARGET_SERVICE_FILE") || {
            [[ "$was_active" == "yes" ]] && systemctl start "$TARGET_SERVICE"
            return 1
        }
    fi

    # Update the passphrase file
    echo "$new_pass" > "$passphrase_file"
    chmod 600 "$passphrase_file"
    chown "${SERVICE_USER}:${SERVICE_USER}" "$passphrase_file" 2>/dev/null || true
    print_ok "Passphrase file updated"

    # Binary/source installs use LoadCredential -- passphrase read from file at
    # runtime, no service file change needed.
    # Docker installs embed passphrase in ExecStart -- update it.
    if echo "$exec_start" | grep -qF "docker run"; then
        local bls_pass
        bls_pass=$(cat "$passphrase_file")
        perl -i -pe "s|TN_BLS_PASSPHRASE=[^ ]+|TN_BLS_PASSPHRASE=${bls_pass}|g" "$TARGET_SERVICE_FILE"
        print_ok "Docker service file updated with new passphrase"
    else
        print_ok "Binary install -- passphrase file updated (LoadCredential reads it at runtime)"
    fi

    new_pass=""
    new_pass_confirm=""

    # Restart the service if it was running before
    if [[ "$was_active" == "yes" ]]; then
        print_step "Restarting ${TARGET_SERVICE}..."
        systemctl daemon-reload
        systemctl start "$TARGET_SERVICE"
        sleep 3
        if systemctl is-active --quiet "$TARGET_SERVICE"; then
            print_ok "Service restarted successfully"
        else
            print_error "Service failed to restart. Check logs:"
            print_info "  journalctl -u ${TARGET_SERVICE} --no-pager -n 30"
        fi
        edit_unlock
        echo ""
        read -r -p "  Press Enter to return to menu..."
    else
        apply_changes
    fi
}

edit_p2p_ports() {
    print_header "Edit P2P Ports"

    # if/fi (not `[[ ]] &&`): this function runs under errexit, and the &&
    # form returns 1 when the first read already found a value.
    local current_primary current_worker
    current_primary=$(read_env_var "PRIMARY_LISTENER_MULTIADDR" "$TARGET_SERVICE_FILE" || true)
    if [[ -z "$current_primary" ]]; then
        current_primary=$(read_listener_from_launch "PRIMARY_LISTENER_MULTIADDR" || true)
    fi
    current_worker=$(read_env_var "WORKER_LISTENER_MULTIADDR" "$TARGET_SERVICE_FILE" || true)
    if [[ -z "$current_worker" ]]; then
        current_worker=$(read_listener_from_launch "WORKER_LISTENER_MULTIADDR" || true)
    fi

    print_info "Current primary listener: ${current_primary:-unknown}"
    print_info "Current worker listener:  ${current_worker:-unknown}"
    echo ""
    print_info "Default ports are 49590 (primary) and 49594 (worker)."
    print_info "Only change these if you have a port conflict."
    echo ""

    local new_primary_port new_worker_port
    read -r -p "  Primary P2P port [49590]: " input
    new_primary_port="${input:-49590}"
    read -r -p "  Worker P2P port  [49594]: " input
    new_worker_port="${input:-49594}"

    if ! validate_port "$new_primary_port"; then
        print_error "Invalid primary port: ${new_primary_port}. Must be 1-65535."
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi
    if ! validate_port "$new_worker_port"; then
        print_error "Invalid worker port: ${new_worker_port}. Must be 1-65535."
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi
    if [[ "$new_primary_port" == "$new_worker_port" ]]; then
        print_error "Primary and worker ports cannot be the same."
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi

    menu_lock || return 0
    backup_edit_targets || return 0

    # Rebuild multiaddrs with new ports keeping same IP/protocol
    local new_primary new_worker
    if [[ -n "$current_primary" ]]; then
        new_primary=$(echo "$current_primary" | sed "s|/udp/[0-9]*/|/udp/${new_primary_port}/|")
        new_worker=$(echo "$current_worker" | sed "s|/udp/[0-9]*/|/udp/${new_worker_port}/|")
    else
        new_primary="/ip4/0.0.0.0/udp/${new_primary_port}/quic-v1"
        new_worker="/ip4/0.0.0.0/udp/${new_worker_port}/quic-v1"
    fi

    set_listener_var "PRIMARY_LISTENER_MULTIADDR" "$new_primary"
    set_listener_var "WORKER_LISTENER_MULTIADDR"  "$new_worker"
    print_ok "P2P ports updated"
    print_info "Primary: ${new_primary}"
    print_info "Worker:  ${new_worker}"
    apply_changes
}

edit_docker_image() {
    print_header "Update Docker Image"

    local exec_start
    exec_start=$(read_launch_line "$TARGET_LAUNCH_FILE")

    if ! echo "$exec_start" | grep -qF "docker run"; then
        print_warn "This node is not running via Docker."
        print_info "Docker image updates only apply to Docker installs."
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi

    local current_image
    current_image="$(launch_docker_image "$exec_start")"

    print_info "Current image: ${current_image:-unknown}"
    echo ""
    print_info "Enter the new image URL and tag."
    print_info "Check for latest tags at:"
    print_info "  https://console.cloud.google.com/artifacts/docker/telcoin-network/us/tn-public/adiri"
    echo ""

    local new_image
    read -r -p "  New Docker image [${current_image}]: " input
    new_image="${input:-$current_image}"

    if [[ "$new_image" == "$current_image" ]]; then
        print_info "Image unchanged."
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi

    if ! validate_docker_image "$new_image"; then
        print_error "Image reference looks invalid: ${new_image}"
        print_info "Expected format: registry/path:tag (e.g. us-docker.pkg.dev/.../adiri:v0.9.2)."
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi

    print_step "Pulling new image: ${new_image}..."
    if ! docker pull "$new_image"; then
        print_error "Failed to pull image: ${new_image}"
        print_info "Check the image URL and tag and try again."
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi
    print_ok "Image pulled successfully"

    menu_lock || return 0
    backup_edit_targets || return 0

    # Replace old image with new image in the launch file (wrapper or unit)
    swap_docker_image "$current_image" "$new_image" "$TARGET_LAUNCH_FILE"
    print_ok "Launch config updated to use: ${new_image}"
    apply_changes
}

edit_bootstrap_peers() {
    print_header "Edit Bootstrap Peers"

    local peers current input
    peers="$(tn_resolve_config_dir)/bootstrap-peers.yaml"
    if current="$(tn_launch_flag_get "$TARGET_LAUNCH_FILE" --bootstrap-peers 2>/dev/null)"; then
        print_info "Current: --bootstrap-peers ${current}"
    else
        print_info "Current: none (the node dials the bootstrap servers in its genesis)"
    fi
    echo ""
    print_info "A bootstrap peers file is a YAML or JSON map of peers keyed by BLS public"
    print_info "key, at most 64 KiB. The node dials them at start instead of the genesis"
    print_info "bootstrap servers. The node binary checks the file, then it is installed"
    print_info "as ${peers}. Needs v0.15.0-adiri or later."
    echo ""

    read -r -p "  Absolute path to the peers file, or none to remove (Enter to cancel): " input || true
    if [[ -z "$input" ]]; then
        print_info "Unchanged."
        echo ""
        read -r -p "  Press Enter to return to menu..." || true
        return 0
    fi
    menu_apply set_bootstrap_peers "$input" "Bootstrap peers"
}

edit_state_export() {
    print_header "Edit State Export"

    local current="off" keep choice value input
    if tn_launch_flag_get "$TARGET_LAUNCH_FILE" --enable-state-export >/dev/null 2>&1; then
        current="on, keep every epoch"
        if keep="$(tn_launch_flag_get "$TARGET_LAUNCH_FILE" --state-export-keep 2>/dev/null)"; then
            current="on, keep the last ${keep} epochs"
        fi
    fi
    print_info "Current: ${current}"
    echo ""
    print_info "With state export on, the node writes the execution state at each epoch"
    print_info "boundary to <data dir>/consensus-db/state_exports/epoch-N/."
    echo ""
    echo "  1) Off"
    echo "  2) On, keep every epoch's export     (v0.13.0-adiri or later)"
    echo "  3) On, keep only the last N epochs   (v0.15.0-adiri or later)"
    echo ""

    while true; do
        read -r -p "  Enter choice [1/2/3]: " choice || true
        case "$choice" in
            1) value="off"; break ;;
            2) value="unlimited"; break ;;
            3)
                read -r -p "  Number of epochs to keep [1-999999]: " input || true
                if [[ ! "$input" =~ ^[1-9][0-9]{0,5}$ ]]; then
                    print_error "Enter a whole number from 1 to 999999."
                    echo ""
                    read -r -p "  Press Enter to return to menu..." || true
                    return 0
                fi
                value="$input"
                break
                ;;
            "") print_info "Unchanged."; return 0 ;;
            *) print_warn "Please enter 1, 2, or 3." ;;
        esac
    done
    menu_apply set_state_export "$value" "State export"
}

edit_private_forward_targets() {
    print_header "Edit Private Forward Targets"

    local params current choice value
    params="$(detect_data_dir)/parameters.yaml"
    current="$(params_forward_value "$params")"
    print_info "Current: allow_private_forward_targets: ${current:-false (default)}"
    echo ""
    print_info "A node outside the committee forwards the transactions it receives to the"
    print_info "RPC endpoint a committee member advertises. With false (the default) it"
    print_info "refuses endpoints on loopback, private and link-local addresses. Set true"
    print_info "only on a network where you run every committee node; it is refused on"
    print_info "testnet and mainnet. The setting lives in ${params}."
    echo ""
    echo "  1) false  (default)"
    echo "  2) true   (private networks only)"
    echo ""

    while true; do
        read -r -p "  Enter choice [1/2]: " choice || true
        case "$choice" in
            1) value="false"; break ;;
            2) value="true"; break ;;
            "") print_info "Unchanged."; return 0 ;;
            *) print_warn "Please enter 1 or 2." ;;
        esac
    done
    menu_apply set_private_forward_targets "$value" "allow_private_forward_targets"
}

# Chain-config directory under the source checkout for a .node-meta NETWORK
# value; nothing for an unknown value.
chain_config_subdir() {
    case "$1" in
        testnet) printf 'testnet' ;;
        mainnet) printf 'mainnet' ;;
        devnet)  printf 'devnet' ;;
    esac
}

refresh_chain_configs() {
    print_header "Refresh Chain Configs"

    local source_dir="$TN_SOURCE_DIR"
    local node_data_dir network subdir chain_config_src node_genesis node_id src_id
    node_data_dir=$(detect_data_dir)

    # The network comes from .node-meta. Copying another network's files would
    # move the node to that chain, so an unknown network is refused.
    network="$(meta_get NETWORK 2>/dev/null || true)"
    subdir="$(chain_config_subdir "$network")"
    if [[ -z "$subdir" ]]; then
        if [[ -z "$network" ]]; then
            print_error "Cannot tell which network this node runs: .node-meta has no NETWORK. Chain configs unchanged."
        else
            print_error "Cannot refresh chain configs for NETWORK=${network} (.node-meta); expected testnet, mainnet or devnet."
        fi
        print_info "Set NETWORK=testnet (or mainnet) in $(node_meta_path 2>/dev/null || echo .node-meta) and try again."
        echo ""
        read -r -p "  Press Enter to return to menu..." || true
        return 0
    fi

    print_info "This pulls the latest ${network} chain configs from the repository and"
    print_info "copies them to your node data directory."
    print_info "Use this when the network restarts with new genesis/committee/parameters."
    echo ""
    print_warn "The node will be restarted to apply the new configs."
    echo ""

    if ! confirm "Refresh chain configs for ${TARGET_SERVICE}?"; then
        print_info "Cancelled."
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi

    # update-node.sh builds from the same checkout, so the pull waits for it too.
    menu_lock || return 0

    # Pull latest from repo
    if [[ -d "${source_dir}/.git" ]]; then
        print_step "Pulling latest chain configs..."
        if ! git -C "$source_dir" pull; then
            print_error "git pull failed in ${source_dir}. Chain configs unchanged."
            echo ""
            read -r -p "  Press Enter to return to menu..." || true
            return 0
        fi
        print_ok "Repository updated"
        # Warn-only: chain configs live in the superproject; keep submodules in
        # step anyway so a later source build starts from a consistent tree.
        tn_sync_submodules "$source_dir" || \
            print_warn "submodule sync reported an issue -- chain configs are unaffected"
    else
        print_warn "Source directory not found at ${source_dir}"
        print_info "Cannot refresh chain configs without the cloned repository."
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi

    # Copy updated configs
    chain_config_src="${source_dir}/chain-configs/${subdir}"
    if [[ ! -d "$chain_config_src" ]]; then
        print_warn "Chain config directory not found at ${chain_config_src}"
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi

    # Verify source files exist before any copy so we never wipe live state
    # with empty/missing sources.
    local missing=()
    [[ -f "${chain_config_src}/genesis.yaml"    ]] || missing+=("genesis.yaml")
    [[ -f "${chain_config_src}/committee.yaml"  ]] || missing+=("committee.yaml")
    [[ -f "${chain_config_src}/parameters.yaml" ]] || missing+=("parameters.yaml")
    if (( ${#missing[@]} > 0 )); then
        print_error "Missing chain config files at ${chain_config_src}:"
        for f in "${missing[@]}"; do print_info "  ${f}"; done
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi

    # Same chain or nothing: the node's current genesis and the new one must
    # both declare a chain id, and the same one.
    node_genesis="${node_data_dir}/genesis/genesis.yaml"
    node_id="$(tn_genesis_chain_id "$node_genesis" 2>/dev/null || true)"
    src_id="$(tn_genesis_chain_id "${chain_config_src}/genesis.yaml" 2>/dev/null || true)"
    if [[ -z "$node_id" || -z "$src_id" || "$node_id" != "$src_id" ]]; then
        print_error "Not refreshing: the node's genesis (${node_genesis}) is chain ${node_id:-unknown} and ${chain_config_src}/genesis.yaml is chain ${src_id:-unknown}. Both must be known and equal. Chain configs unchanged."
        echo ""
        read -r -p "  Press Enter to return to menu..." || true
        return 0
    fi
    print_ok "Chain id ${src_id} matches the node's genesis"

    print_step "Copying chain configs to ${node_data_dir}..."
    mkdir -p "${node_data_dir}/genesis"
    cp "${chain_config_src}/genesis.yaml"    "${node_data_dir}/genesis/"
    cp "${chain_config_src}/committee.yaml"  "${node_data_dir}/genesis/"
    cp "${chain_config_src}/parameters.yaml" "${node_data_dir}/"

    local svc_user
    svc_user=$(grep "^User=" "$TARGET_SERVICE_FILE" 2>/dev/null | cut -d= -f2 || echo "root")
    local svc_group
    svc_group=$(grep "^Group=" "$TARGET_SERVICE_FILE" 2>/dev/null | cut -d= -f2 || echo "")

    if [[ -n "$svc_group" ]] && getent group "$svc_group" &>/dev/null; then
        chown -R "${svc_user}:${svc_group}" "$node_data_dir" 2>/dev/null || \
            chown -R "${svc_user}" "$node_data_dir" 2>/dev/null || true
    else
        chown -R "${svc_user}" "$node_data_dir" 2>/dev/null || true
    fi
    print_ok "Chain configs updated"

    apply_changes
}

restart_node() {
    print_header "Restart Node"

    local status
    if systemctl is-active --quiet "$TARGET_SERVICE" 2>/dev/null; then
        status="running"
    else
        status="stopped"
    fi

    print_info "Service: ${TARGET_SERVICE} (${status})"
    echo ""

    if confirm "Restart ${TARGET_SERVICE} now?"; then
        menu_lock || return 0
        edit_epoch_wait
        print_step "Restarting ${TARGET_SERVICE}..."
        systemctl restart "$TARGET_SERVICE" || true
        sleep 3
        if systemctl is-active --quiet "$TARGET_SERVICE"; then
            print_ok "Node restarted successfully"
        else
            print_error "Node failed to restart. Check logs:"
            print_info "  journalctl -u ${TARGET_SERVICE} --no-pager -n 30"
        fi
        edit_unlock
    else
        print_info "Cancelled."
    fi

    echo ""
    read -r -p "  Press Enter to return to menu..."
}

# =============================================================================
# MAIN MENU
# =============================================================================

main_menu() {
    while true; do
        # Every edit releases the lock when it is done; this covers any early
        # return. A finished edit is no longer one to put back on exit.
        edit_unlock
        edit_reset_backups
        show_current_config

        echo "  What would you like to change?"
        echo ""
        echo "  1) Listener addresses      (PRIMARY/WORKER_LISTENER_MULTIADDR)"
        echo "  2) Metrics address"
        echo "  3) Log verbosity"
        echo "  4) RPC access              (private / public / disabled)"
        echo "  5) BLS passphrase"
        echo "  6) P2P ports               (49590/49594)"
        echo "  7) Docker image            (Docker installs only)"
        echo "  8) Bootstrap peers         (a peers file instead of the genesis list)"
        echo "  9) State export            (off / every epoch / the last N epochs)"
        echo " 10) Private forward targets (private networks only)"
        echo " 11) Refresh chain configs   (pull latest genesis/committee/parameters)"
        echo " 12) Restart node"
        echo " 13) Exit"
        echo ""

        local choice
        read -r -p "  Enter choice [1-13]: " choice
        case "$choice" in
            1)  edit_listener_addresses      ;;
            2)  edit_metrics                 ;;
            3)  edit_verbosity               ;;
            4)  edit_rpc                     ;;
            5)  edit_bls_passphrase          ;;
            6)  edit_p2p_ports               ;;
            7)  edit_docker_image            ;;
            8)  edit_bootstrap_peers         ;;
            9)  edit_state_export            ;;
            10) edit_private_forward_targets ;;
            11) refresh_chain_configs        ;;
            12) restart_node                 ;;
            13) echo ""; print_info "Exiting."; exit 0 ;;
            *) print_warn "Please enter 1-13." ;;
        esac
    done
}

# =============================================================================
# --set: ONE EDIT WITHOUT THE MENU
#
# Used by the Telcoin Node Manager UI through the root-owned telcoin-ui-helper,
# which calls:  edit-config.sh --json --set <field>=<value>
# Without --json the same steps print human-readable lines.
#
# --json events on stdout:
#   {"event":"step|log|warn|error","msg":"..."}
#   {"event":"done","ok":true|false[,"rolled_back":true|false],"field":"..."[,"value":"..."],"msg":"..."}
#
# Fields (the header lists their values): primary_listener worker_listener
# metrics verbosity docker_image bootstrap_peers state_export
# allow_private_forward_targets. Each value is validated here with the same
# validators the menu uses.
# =============================================================================

# run_set -- validate, take the update lock, save the edit, wait for the epoch
# boundary when the node is in the committee, restart, and check that the
# service stays up. A failed restart puts every changed file back and restarts
# once more, without waiting. An edit that changes nothing ends there, with no
# restart.
run_set() {
    local field value rc err
    edit_require_root
    if [[ "$EDIT_SET_PAIR" != *=* || -z "${EDIT_SET_PAIR%%=*}" ]]; then
        edit_error "--set needs field=value, for example --set state_export=unlimited"
        return 1
    fi
    field="${EDIT_SET_PAIR%%=*}"
    value="${EDIT_SET_PAIR#*=}"
    EDIT_SET_FIELD="$field"
    if ! edit_field_known "$field"; then
        edit_error "field not editable: ${field}"
        return 1
    fi
    if [[ -z "$value" ]]; then
        edit_error "--set ${field}= has no value"
        return 1
    fi
    resolve_target || return 1
    edit_lock || return 1
    edit_reset_backups

    edit_step "Setting ${field}=${value}"
    rc=0
    set_field "$field" "$value" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        err="${EDIT_LAST_ERROR:-edit rejected}"
        err="${err%.}"
        if edit_restore_backups; then
            edit_done false "$field" "" "${err}; nothing was changed"
        else
            edit_done false "$field" "" "${err}; some files could not be restored, see the errors above"
        fi
        return 1
    fi
    if ! edit_any_changed; then
        edit_drop_backups
        edit_done true "$field" "$value" "${field} is already ${value}; nothing changed and ${TARGET_SERVICE} was not restarted"
        return 0
    fi
    edit_report_backups

    if edit_restart; then
        edit_done true "$field" "$value" "applied and ${TARGET_SERVICE} healthy"
        return 0
    fi

    # No epoch wait here: the node is already down or failing.
    edit_step "Service did not come back healthy -- rolling back"
    edit_restore_backups || true
    systemctl restart "$TARGET_SERVICE" >&2 2>&1 || true
    sleep 3
    if systemctl is-active --quiet "$TARGET_SERVICE"; then
        edit_done false "$field" "" "restart failed; rolled back to the previous configuration" true
    else
        edit_done false "$field" "" "restart and rollback failed; inspect journalctl -u ${TARGET_SERVICE}" false
    fi
    return 1
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local arg
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
    trap edit_on_exit EXIT
    # A signal ends the run through the EXIT trap with the usual status (128 +
    # the signal number), so a pending edit is put back and --json still ends
    # with a done. The UI sends TERM when its page goes away. A trap runs once
    # the command in progress returns, so during the epoch wait that can take
    # up to one poll interval.
    trap 'EDIT_SIGNAL=TERM; exit 143' TERM
    trap 'EDIT_SIGNAL=INT; exit 130' INT
    trap 'EDIT_SIGNAL=HUP; exit 129' HUP

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)      JSON_MODE=true; shift ;;
            # Legacy Node Manager UI helpers pass a role flag on every call. The
            # role is decided on-chain, so the flag is accepted and ignored.
            --observer|--validator) LEGACY_ROLE_FLAG="$1"; shift ;;
            --set)
                # A field=value pair starts with the field name, so a word
                # starting with "-" is the next flag: --set has no value.
                if [[ $# -lt 2 || "$2" == -* ]]; then
                    edit_error "--set needs field=value, for example --set state_export=unlimited"
                    exit 1
                fi
                EDIT_SET_GIVEN=true
                EDIT_SET_PAIR="$2"
                shift 2
                ;;
            --no-epoch-wait) NO_EPOCH_WAIT=true; shift ;;
            -h|--help)
                # The header block only: everything up to its closing rule. Read
                # from this file, not "$0", which names the caller when sourced.
                awk 'NR == 1 { next } /^# =+$/ { if (++rules == 2) exit; next } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
                if [[ "$JSON_MODE" == "true" ]]; then
                    json_emit '{"event":"done","ok":true,"msg":"usage printed on stderr"}'
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

    if [[ "$JSON_MODE" == "true" || "$EDIT_SET_GIVEN" == "true" ]]; then
        run_set
        exit $?
    fi

    clear 2>/dev/null || true
    print_header "Telcoin Network Node Configuration Editor  v${SCRIPT_VERSION}"
    check_root
    detect_node
    main_menu
}

main "$@"
