#!/usr/bin/env bash
# =============================================================================
# migrate-node-naming.sh -- Migrate a LEGACY telcoin-{observer,validator} install
# to the unified `telcoin` layout (one node identity, validator-capable).
#
# WHY THIS EXISTS
# ---------------
# Early nodes were deployed under a per-role identity:
#     systemd unit   telcoin-observer            (telcoin-observer.service)
#     docker --name  telcoin-observer
#     config dir     /etc/telcoin/observer
#     data dir       /var/lib/telcoin/observer
#     wrapper        /opt/telcoin/start-telcoin-observer.sh
#     logs           /var/log/telcoin/telcoin-observer*.log
# Every NEW install (and every other script's happy path) now uses ONE name:
#     telcoin.service / --name telcoin / /etc/telcoin / /var/lib/telcoin /
#     /usr/local/libexec/telcoin/tn-start (tn-start-docker for Docker) /
#     /var/log/telcoin/telcoin*.log
# (.node-meta records no role). lib/fallback.sh keeps legacy installs WORKING
# but never migrates them. This script performs the one-time migration.
#
# SCOPE
# -----
# A node's role is decided DYNAMICALLY from on-chain committee membership each
# epoch, not from a static flag. A staked validator not currently in committee
# behaves identically to a never-staked observer -- they are the SAME node. The
# `--observer` flag has been removed from the node binary, so the legacy observer
# and validator wrappers now differ only in that one defunct line. This migration
# therefore collapses the per-role layout into ONE identity: it strips the removed
# `--observer` flag from a legacy wrapper and provisions the node validator-capable
# (including the P2P consensus UDP ports 49590 + 49594). It also removes the old
# NODE_TYPE presentation hint from .node-meta: nothing on the server records a role.
# The dashboard takes the validator view from the on-chain stake status
# (ConsensusRegistry getValidator, read by node_stake_status in lib/common.sh). The
# node keeps its existing BLS keypair, so no key changes are needed.
#
# Safe to run on ANY legacy telcoin-{observer,validator} install -- staked or not.
#
# DESIGN
# ------
# Deliberately does NOT re-run setup-*.sh --phase=finalize (that defaults NETWORK
# -> mainnet, pulls the wrong chain config, leaves legacy artifacts behind, and has
# surprised us with benign rc=1 / no-op starts). Instead it relocates the dirs and
# rewrites the unit + wrapper IN PLACE with targeted substitutions -- predictable
# and minimal. Idempotent (re-running on an already-migrated node is a no-op) and
# self-rolling-back: on any failure it stops the new unit, moves the dirs back,
# restores .node-meta from its backup, restarts the legacy service (without
# waiting), and exits non-zero with the backup paths. The legacy unit and wrapper
# are removed only once the new unit runs and answers on RPC, so a rollback never
# has to put them back. Backups are root-only copies in /var/backups/telcoin.
#
# The run holds the update lock (the one update-node.sh, edit-config.sh and
# setup-node.sh take) from the confirmation to the end, and waits for the restart
# window (tn_wait_restart_window) right before it stops the legacy node.
#
# Downtime is expected and acceptable (stop -> migrate -> start). The node
# rejoins consensus at the next epoch boundary when it is in committee.
#
# Node-side Linux bash. Run as root on the node:  sudo bash migrate-node-naming.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolvers (tn_resolve_*) + print helpers + check_root + _tn_meta_get, and the
# .node-meta writers meta_set / meta_unset. common.sh sources lib/fallback.sh, the
# only module that knows the legacy names/layout.
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# errtrace: WITHOUT -E the ERR trap (on_error) is NOT inherited by shell
# functions, so a failure inside a migration step would exit WITHOUT running
# rollback(). With -E the trap fires for in-function failures, so rollback always
# runs. (common.sh's own `set -euo pipefail` does not clear -E.)
set -E

# This script writes through the root-write helpers of the current library.
for _tn_fn in tn_backup_file tn_restore_backup tn_write_root_file tn_start_script_path \
              tn_wait_restart_window tn_update_lock_path _tn_root_layout_dir _tn_strip_gw; do
    if ! declare -F "$_tn_fn" >/dev/null 2>&1; then
        print_error "lib/common.sh ${COMMON_VERSION:-unknown} has no ${_tn_fn}. Run update-scripts.sh and try again."
        exit 1
    fi
done
unset _tn_fn

# Version, gated by update-scripts.sh like every other tracked file.
readonly SCRIPT_VERSION="1.2.1"

# Unified (target) identity -- mirrors lib/fallback.sh's canonical new-install names.
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly UNIFIED_SERVICE="telcoin"
readonly UNIFIED_UNIT="${SYSTEMD_DIR}/telcoin.service"
readonly UNIFIED_CONFIG_DIR="/etc/telcoin"
readonly UNIFIED_DATA_DIR="/var/lib/telcoin"
UNIFIED_WRAPPER=""      # tn_start_script_path for the install method (set by detect_legacy)

# --- Detection results (filled by detect_legacy) -----------------------------
ROLE=""                 # observer | validator (the legacy role being migrated)
LEGACY_UNIT=""          # /etc/systemd/system/telcoin-<role>.service
LEGACY_WRAPPER=""       # /opt/telcoin/start-telcoin-<role>.sh (read from ExecStart)
LEGACY_CONFIG_DIR=""    # /etc/telcoin/<role>
LEGACY_DATA_DIR=""      # /var/lib/telcoin/<role> (or .node-meta DATA_DIR)
EFFECTIVE_DATA_DIR=""   # where the data ENDS UP under the unified layout: /var/lib/telcoin for
                        # a default role-suffixed install, or the operator's custom mount kept
                        # AS-IS (a 2nd disk, e.g. /mnt/data) -- see detect_legacy.
CUSTOM_DATA_DIR=false   # true when the node lives on a custom mount (data preserved in place)
LEGACY_CONTAINER=""     # telcoin-<role>
RPC_PORT="${DEFAULT_RPC_PORT:-8545}"  # post-start verify port; the unified node runs with NO
                        # --instance, so it serves RPC on the protocol default (8545), not 8541.
LEGACY_RPC_PORT=""      # informational only: the pre-migration RPC port (observer's --instance 5 -> 8541)
STOP_RPC_URL=""         # the legacy node's RPC, read for the restart window before the stop
INSTALL_METHOD_L=""     # the legacy .node-meta INSTALL_METHOD (docker, or a binary form)
DETECT_SUM=""           # hash of the legacy unit + .node-meta at detection (re-checked under the lock)
META_VAL=""             # migrate_meta_read's result

# --- Rollback bookkeeping ----------------------------------------------------
UNIT_BAK=""             # root-only copies made by tn_backup_file, and their SHA-256
UNIT_SHA=""
WRAPPER_BAK=""
WRAPPER_SHA=""
META_BAK=""
META_SHA=""
UNIT_MODE=""            # the legacy unit's mode, kept for the unified unit
DATA_OWNER=""           # owner:group of the data dir at snapshot; reapplied to the unified datadir
                        # (relocate) and the recreated legacy datadir (rollback) so the non-root
                        # container node can write/rotate its DB (a root-owned datadir -> exit 1).
STOPPED_LEGACY=false
MOVED_CONFIG=false
MOVED_DATA=false
WROTE_UNIT=false
WROTE_WRAPPER=false
WROTE_META=false
ROLLED_BACK=false
declare -a CONFIG_MOVED=()   # basenames moved out of LEGACY_CONFIG_DIR
declare -a DATA_MOVED=()     # basenames moved out of LEGACY_DATA_DIR

ASSUME_YES="${TN_ASSUME_YES:-false}"

usage() {
    cat <<EOF
migrate-node-naming.sh v${SCRIPT_VERSION}

Migrate a legacy telcoin-{observer,validator} install to the unified 'telcoin'
layout: strips the removed --observer flag, removes the old NODE_TYPE hint from
.node-meta (the validator view follows the on-chain stake status), and opens the
P2P consensus ports so the node is validator-capable. Idempotent and
self-rolling-back.

USAGE:
  sudo bash migrate-node-naming.sh [--yes]

OPTIONS:
  -y, --yes    Do not prompt for confirmation (also honored via TN_ASSUME_YES=true).
  -h, --help   Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes) ASSUME_YES=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) print_error "Unknown argument: $1"; usage; exit 2 ;;
    esac
done

# =============================================================================
# UPDATE LOCK
# =============================================================================
# The run holds the update lock from the confirmation to the end, so no other
# script changes the unit, the start script or .node-meta meanwhile. This script
# owns its EXIT trap (TN_EXIT_TRAP_OWNED=1): migrate_on_exit releases the lock on
# every exit, a rollback included.
migrate_on_exit() {
    tn_release_update_lock 2>/dev/null || true
}

# migrate_detect_sum -- one SHA-256 over the legacy unit and .node-meta.
migrate_detect_sum() {
    { cat -- "$LEGACY_UNIT" "${LEGACY_CONFIG_DIR}/.node-meta" 2>/dev/null || true; } | sha256sum
}

# migrate_take_lock -- take the update lock or stop (nothing changed yet). The
# detection ran before it, so the confirmation prompt never holds the lock up;
# the run stops when the legacy unit or .node-meta changed in between.
migrate_take_lock() {
    local now
    TN_EXIT_TRAP_OWNED=1
    trap migrate_on_exit EXIT
    if ! tn_acquire_update_lock; then
        print_error "Another setup, update or edit holds the update lock ($(tn_update_lock_path))${TN_UPDATE_LOCK_HOLDER:+, PID ${TN_UPDATE_LOCK_HOLDER}}. Wait for it to finish, then run the migration again. Nothing was changed."
        exit 1
    fi
    now="$(migrate_detect_sum)"
    if [[ "$now" != "$DETECT_SUM" ]]; then
        print_error "The legacy unit or .node-meta changed while this run waited for the lock. Run the migration again. Nothing was changed."
        exit 1
    fi
}

# migrate_meta_read KEY -- KEY's value from the legacy .node-meta in META_VAL
# ("" when absent). A key set more than once has no single value: the run stops
# before anything is changed.
migrate_meta_read() {
    local rc=0
    META_VAL="$(_tn_meta_get "$1" "${LEGACY_CONFIG_DIR}/.node-meta")" || rc=$?
    if [[ $rc -eq 2 ]]; then
        print_error "${1} is set more than once in ${LEGACY_CONFIG_DIR}/.node-meta. Remove the extra lines, then run the migration again. Nothing was changed."
        exit 1
    fi
    [[ $rc -eq 0 ]] || META_VAL=""
    return 0
}

# =============================================================================
# ROLLBACK
# =============================================================================
# Reverse the mutations that completed, based on the *_MOVED / WROTE_* flags, so a
# partial migration leaves the node as it was found. Dir moves are renames on the
# same filesystem, so they reverse instantly; the big db/ is never copied. The
# legacy unit and wrapper are removed only after the new unit is verified, so
# they are still in place here. Never raises (runs with set +e). The restart of
# the legacy service at the end never waits for the epoch boundary.
rollback() {
    [[ "$ROLLED_BACK" == true ]] && return 0
    ROLLED_BACK=true
    # Maximally defensive: no errexit (rollback must run to completion) and no
    # nounset. The *_MOVED loops below are also written to survive an empty array
    # under `set -u`, which is an error before bash 4.4 (macOS /bin/bash 3.2 too).
    set +eu
    print_warn "Restoring the previous (legacy) layout..."
    local base created problems=""

    # The new unit is stopped before anything moves back, so no node writes the
    # data dir meanwhile; then it and the new start script go.
    if [[ "$WROTE_UNIT" == true ]]; then
        systemctl stop "$UNIFIED_SERVICE" 2>/dev/null
        systemctl disable "$UNIFIED_SERVICE" 2>/dev/null
        if [[ "$INSTALL_METHOD_L" == docker ]] && command -v docker >/dev/null 2>&1; then
            docker rm -f "$UNIFIED_SERVICE" >/dev/null 2>&1
        fi
        rm -f -- "$UNIFIED_UNIT"
    fi
    [[ "$WROTE_WRAPPER" == true ]] && rm -f -- "$UNIFIED_WRAPPER"

    if [[ "$MOVED_DATA" == true ]]; then
        # Root takes the data dir (EFFECTIVE_DATA_DIR, where the entries went) back
        # before moving anything out of it. A link planted at the role dir's name is
        # removed, never followed; the role dir is made afresh (0750) and each entry
        # renamed into it with mv -T, which never moves into a directory or a link.
        if _tn_root_layout_dir "$EFFECTIVE_DATA_DIR" root 0700; then
            created=false
            if [[ -L "$LEGACY_DATA_DIR" ]]; then
                rm -f -- "$LEGACY_DATA_DIR"
            fi
            if [[ ! -e "$LEGACY_DATA_DIR" ]] && mkdir -m 0750 -- "$LEGACY_DATA_DIR"; then
                created=true
            fi
            if [[ -d "$LEGACY_DATA_DIR" && ! -L "$LEGACY_DATA_DIR" ]]; then
                for base in ${DATA_MOVED[@]+"${DATA_MOVED[@]}"}; do
                    if [[ -e "${EFFECTIVE_DATA_DIR}/${base}" || -L "${EFFECTIVE_DATA_DIR}/${base}" ]]; then
                        mv -T -- "${EFFECTIVE_DATA_DIR}/${base}" "${LEGACY_DATA_DIR}/${base}" \
                            || problems="${problems} ${LEGACY_DATA_DIR}/${base}"
                    fi
                done
                # The node runs as the service account and must own its data dir:
                # only the directory made here gets that owner back (chown -h, never
                # recursive, never a directory that already existed).
                if [[ "$created" == true && -n "$DATA_OWNER" ]]; then
                    chown -h -- "$DATA_OWNER" "$LEGACY_DATA_DIR" || problems="${problems} ${LEGACY_DATA_DIR}"
                fi
            else
                problems="${problems} ${LEGACY_DATA_DIR}"
            fi
            # A root directory again that the service account can pass through.
            chmod 0755 -- "$EFFECTIVE_DATA_DIR" || problems="${problems} ${EFFECTIVE_DATA_DIR}"
        else
            problems="${problems} ${EFFECTIVE_DATA_DIR}"
        fi
    fi
    if [[ "$MOVED_CONFIG" == true ]]; then
        # The same for the config entries; the role dir is made root 0755 (the node
        # only reads it), so .node-meta can be put back from its backup below.
        if _tn_root_layout_dir "$UNIFIED_CONFIG_DIR" root 0755; then
            if [[ -L "$LEGACY_CONFIG_DIR" ]]; then
                rm -f -- "$LEGACY_CONFIG_DIR"
            fi
            if [[ ! -e "$LEGACY_CONFIG_DIR" ]]; then
                install -d -o root -g root -m 0755 -- "$LEGACY_CONFIG_DIR"
            fi
            if [[ -d "$LEGACY_CONFIG_DIR" && ! -L "$LEGACY_CONFIG_DIR" ]]; then
                for base in ${CONFIG_MOVED[@]+"${CONFIG_MOVED[@]}"}; do
                    if [[ -e "${UNIFIED_CONFIG_DIR}/${base}" || -L "${UNIFIED_CONFIG_DIR}/${base}" ]]; then
                        mv -T -- "${UNIFIED_CONFIG_DIR}/${base}" "${LEGACY_CONFIG_DIR}/${base}" \
                            || problems="${problems} ${LEGACY_CONFIG_DIR}/${base}"
                    fi
                done
                # The original .node-meta (NODE_TYPE, DATA_DIR and the ports may have
                # been rewritten), from the root-only backup when its hash matches.
                if [[ "$WROTE_META" == true && -n "$META_BAK" ]]; then
                    tn_restore_backup "$META_BAK" "$META_SHA" "${LEGACY_CONFIG_DIR}/.node-meta" 0600 \
                        || problems="${problems} ${LEGACY_CONFIG_DIR}/.node-meta"
                fi
            else
                problems="${problems} ${LEGACY_CONFIG_DIR}"
            fi
        else
            problems="${problems} ${UNIFIED_CONFIG_DIR}"
        fi
    fi

    systemctl daemon-reload 2>/dev/null || true
    if [[ "$STOPPED_LEGACY" == true && -n "$ROLE" ]]; then
        systemctl enable "telcoin-${ROLE}" 2>/dev/null || true
        systemctl start  "telcoin-${ROLE}" 2>/dev/null || true
    fi

    print_error "Rolled back to the legacy layout. Backups kept (root-only; safe to delete once verified):"
    [[ -n "$UNIT_BAK"    ]] && print_info "  unit:    ${UNIT_BAK}"
    [[ -n "$WRAPPER_BAK" ]] && print_info "  wrapper: ${WRAPPER_BAK}"
    [[ -n "$META_BAK"    ]] && print_info "  meta:    ${META_BAK}"
    if [[ -n "$problems" ]]; then
        print_warn "These paths could not be put back; check them by hand:${problems}"
    fi
}

# ERR trap: any unguarded non-zero command after arm_rollback() triggers a full
# rollback + non-zero exit. Armed only after the snapshot exists (detection-phase
# failures have nothing to undo, so they just exit).
on_error() {
    local rc=$?
    trap - ERR
    print_error "Migration step failed (rc=${rc}). Rolling back..."
    rollback
    exit 1
}
arm_rollback() { trap on_error ERR; }

# =============================================================================
# STEP 1 -- DETECT & GUARD
# =============================================================================
detect_legacy() {
    check_root

    # Scan for the legacy unit DIRECTLY rather than via tn_resolve_service: the
    # resolver prefers the unified name (correct for consumers, wrong bias for a
    # migration tool, which specifically wants the OLD artifacts). Validator first.
    local r
    for r in validator observer; do
        if [[ -f "${SYSTEMD_DIR}/telcoin-${r}.service" ]]; then
            ROLE="$r"
            LEGACY_UNIT="${SYSTEMD_DIR}/telcoin-${r}.service"
            break
        fi
    done

    # Idempotency: unified unit present and no legacy unit -> already migrated.
    if [[ -f "$UNIFIED_UNIT" && -z "$ROLE" ]]; then
        print_ok "Already migrated: ${UNIFIED_UNIT} present, no legacy telcoin-{observer,validator}.service."
        print_info "Nothing to do."
        exit 0
    fi

    [[ -z "$ROLE" ]] && { print_error "No legacy telcoin-{observer,validator}.service found -- nothing to migrate."; exit 1; }

    LEGACY_CONTAINER="telcoin-${ROLE}"
    LEGACY_CONFIG_DIR="${UNIFIED_CONFIG_DIR}/${ROLE}"

    # The standard legacy config dir carries a .node-meta. Its absence means a
    # custom config dir or a pre-.node-meta install -- neither of which this tool
    # can migrate safely (the path substitutions only rewrite the default layout).
    if [[ ! -f "${LEGACY_CONFIG_DIR}/.node-meta" ]]; then
        print_error "Expected ${LEGACY_CONFIG_DIR}/.node-meta not found -- non-standard layout."
        print_info  "This migration only handles the default /etc/telcoin/<role> layout."
        print_info  "Migrate this node manually."
        exit 1
    fi

    # Data dir: trust the legacy .node-meta DATA_DIR if present, else convention.
    local meta_data
    migrate_meta_read DATA_DIR
    meta_data="$META_VAL"
    if [[ -n "$meta_data" ]]; then
        LEGACY_DATA_DIR="$meta_data"
    else
        LEGACY_DATA_DIR="${UNIFIED_DATA_DIR}/${ROLE}"
    fi

    # Where the data ENDS UP under the unified layout:
    #  - Default role-suffixed (/var/lib/telcoin/<role>) or already-unified
    #    (/var/lib/telcoin): collapse onto /var/lib/telcoin (the relocate below moves it).
    #  - CUSTOM mount (a 2nd disk/SSD, e.g. /mnt/data -- setup-node.sh records the
    #    operator's exact path as DATA_DIR, no role suffix): PRESERVE it in place. The
    #    data never leaves its disk (no slow/risky cross-fs copy onto the boot disk),
    #    and relocate_dir() no-ops it because src == dst. Only the NAMING is unified.
    if [[ "$LEGACY_DATA_DIR" == "$UNIFIED_DATA_DIR" \
       || "$LEGACY_DATA_DIR" == "${UNIFIED_DATA_DIR}/${ROLE}" ]]; then
        EFFECTIVE_DATA_DIR="$UNIFIED_DATA_DIR"
    else
        EFFECTIVE_DATA_DIR="$LEGACY_DATA_DIR"
        CUSTOM_DATA_DIR=true
    fi

    # Wrapper path: read the unit's ExecStart= (authoritative), else convention.
    local exec_start
    exec_start="$(grep -E '^ExecStart=' "$LEGACY_UNIT" 2>/dev/null | head -n1 | sed 's/^ExecStart=//' | awk '{print $1}' || true)"
    if [[ -n "$exec_start" && -f "$exec_start" ]]; then
        LEGACY_WRAPPER="$exec_start"
    else
        LEGACY_WRAPPER="/opt/telcoin/start-telcoin-${ROLE}.sh"
    fi

    # The legacy RPC port (informational) was derived from reth `--instance` (the observer's
    # `--instance 5` -> 8541). The migration STRIPS --instance, so the unified node serves RPC
    # on the protocol default (DEFAULT_RPC_PORT=8545) -- that is what we verify and record in
    # .node-meta. Verifying the legacy 8541 against a healthy unified node would time out and
    # trigger a false rollback (the mismatch the sibling check-node/update-node tools warn of).
    migrate_meta_read RPC_PORT
    LEGACY_RPC_PORT="${META_VAL:-unknown}"
    RPC_PORT="${DEFAULT_RPC_PORT:-8545}"
    # The restart window before the stop is read from the legacy node itself, on
    # its own port while it still runs (tn_local_rpc_url reads the same file when
    # the port is not recorded).
    if validate_port "$LEGACY_RPC_PORT"; then
        STOP_RPC_URL="http://127.0.0.1:$((10#$LEGACY_RPC_PORT))"
    elif ! STOP_RPC_URL="$(tn_local_rpc_url)"; then
        print_error "Cannot tell the legacy node's RPC port. Nothing was changed."
        exit 1
    fi

    # The unified start script lives in the root-owned /usr/local/libexec/telcoin:
    # tn-start-docker for a Docker install, tn-start otherwise. A .node-meta
    # without INSTALL_METHOD is told by the wrapper (a docker run line).
    migrate_meta_read INSTALL_METHOD
    INSTALL_METHOD_L="$META_VAL"
    if [[ -z "$INSTALL_METHOD_L" ]] && grep -q 'docker run' "$LEGACY_WRAPPER" 2>/dev/null; then
        INSTALL_METHOD_L="docker"
    fi
    if [[ "$INSTALL_METHOD_L" == "docker" ]]; then
        UNIFIED_WRAPPER="$(tn_start_script_path docker)"
    else
        UNIFIED_WRAPPER="$(tn_start_script_path source)"
    fi
    migrate_meta_read HOST_SERVICE_GROUP
    if [[ -n "$META_VAL" ]]; then
        SERVICE_GROUP="$META_VAL"
    fi

    print_header "Telcoin Node Naming Migration v${SCRIPT_VERSION}"
    print_info "Detected LEGACY install:"
    print_info "  role:       ${ROLE}"
    print_info "  unit:       ${LEGACY_UNIT}"
    print_info "  wrapper:    ${LEGACY_WRAPPER}"
    print_info "  config dir: ${LEGACY_CONFIG_DIR}"
    print_info "  data dir:   ${LEGACY_DATA_DIR}"
    print_info "  container:  ${LEGACY_CONTAINER} (docker installs only)"
    print_info "  RPC port:   ${LEGACY_RPC_PORT} (legacy; from --instance)"
    echo ""
    print_info "Will migrate to the UNIFIED layout:"
    print_info "  unit:       ${UNIFIED_UNIT}"
    print_info "  wrapper:    ${UNIFIED_WRAPPER}"
    print_info "  config dir: ${UNIFIED_CONFIG_DIR}"
    if [[ "$CUSTOM_DATA_DIR" == true ]]; then
        print_info "  data dir:   ${EFFECTIVE_DATA_DIR} (custom mount -- preserved in place, no data moved)"
    else
        print_info "  data dir:   ${EFFECTIVE_DATA_DIR}"
    fi
    print_info "  RPC port:   ${RPC_PORT} (default; --observer/--instance removed)"
    echo ""

    DETECT_SUM="$(migrate_detect_sum)"
    if [[ "$ASSUME_YES" != "true" ]]; then
        confirm "Stop the node, migrate, and restart? (downtime expected)" || {
            print_info "Aborted by operator -- no changes made."
            exit 0
        }
    fi
}

# =============================================================================
# STEP 2 -- SNAPSHOT FOR ROLLBACK
# =============================================================================
# Root-only copies (tn_backup_file: /var/backups/telcoin, 0600, SHA-256 kept);
# nothing is written beside the live files. The rewrites below read these
# copies, and a rollback puts .node-meta back only when its hash still matches.
snapshot() {
    local out
    print_step "Backing up the legacy unit, wrapper and .node-meta..."
    if [[ -L "$LEGACY_WRAPPER" || ! -f "$LEGACY_WRAPPER" ]]; then
        # No wrapper (unexpected): a bare ExecStart unit. Abort -- we cannot
        # safely rewrite a launch we cannot see.
        print_error "Legacy wrapper not found at ${LEGACY_WRAPPER} (or it is a symlink) -- cannot migrate safely. Nothing was changed."
        exit 1
    fi
    out="$(tn_backup_file "$LEGACY_UNIT" "telcoin-${ROLE}.service")" || migrate_backup_failed "$LEGACY_UNIT"
    UNIT_BAK="${out% *}"
    UNIT_SHA="${out##* }"
    UNIT_MODE="$(stat -c '%a' -- "$LEGACY_UNIT")"
    print_ok "  ${UNIT_BAK}"
    out="$(tn_backup_file "$LEGACY_WRAPPER" "start-telcoin-${ROLE}.sh")" || migrate_backup_failed "$LEGACY_WRAPPER"
    WRAPPER_BAK="${out% *}"
    WRAPPER_SHA="${out##* }"
    print_ok "  ${WRAPPER_BAK}"
    out="$(tn_backup_file "${LEGACY_CONFIG_DIR}/.node-meta" "node-meta-${ROLE}")" \
        || migrate_backup_failed "${LEGACY_CONFIG_DIR}/.node-meta"
    META_BAK="${out% *}"
    META_SHA="${out##* }"
    print_ok "  ${META_BAK}"

    # Capture the data dir's owner BEFORE we touch anything. relocate (-> unified dir) and
    # rollback (-> recreated legacy dir) reapply it: the node runs as a non-root container
    # user and must OWN its datadir to write/rotate its DB. mkdir/relocate run as root and
    # would otherwise leave a root-owned datadir, which makes the node exit 1 on startup.
    DATA_OWNER="$(stat -c '%U:%G' "$LEGACY_DATA_DIR" 2>/dev/null || true)"
    [[ -n "$DATA_OWNER" ]] && print_ok "  data dir owner: ${DATA_OWNER} (preserved across migrate/rollback)"

    # From here on, any failure rolls back.
    arm_rollback
}

# migrate_backup_ok FILE SHA256 -- rc 0 when the backup still hashes to SHA256
# (the rewrites below read the copies, not the live files).
migrate_backup_ok() {
    local got
    got="$(sha256sum < "$1")" || return 1
    if [[ "${got%% *}" != "$2" ]]; then
        print_error "The backup ${1} changed since it was made -- aborting."
        return 1
    fi
}

# migrate_backup_failed PATH -- stop before anything changed (rollback not armed).
migrate_backup_failed() {
    print_error "Could not back up ${1} (see above). Nothing was changed."
    exit 1
}

# =============================================================================
# STEP 3 -- STOP THE LEGACY SERVICE
# =============================================================================
stop_legacy() {
    # A committee node is not stopped just before the epoch boundary: wait for the
    # restart window first (it returns at once for any other node, never fails).
    tn_wait_restart_window "$STOP_RPC_URL"
    print_step "Stopping the legacy service (telcoin-${ROLE})..."
    systemctl stop "telcoin-${ROLE}" 2>/dev/null || true
    systemctl disable "telcoin-${ROLE}" 2>/dev/null || true
    STOPPED_LEGACY=true
    # The wrapper uses `docker run --rm`, so the container is usually already gone;
    # remove any lingering one so the unified container name is free.
    if command -v docker >/dev/null 2>&1; then
        docker rm -f "$LEGACY_CONTAINER" >/dev/null 2>&1 || true
    fi
    print_ok "Legacy service stopped and disabled."
}

# =============================================================================
# STEPS 4 & 5 -- RELOCATE DIRECTORIES (config then data)
# =============================================================================
# Move every entry (incl. dotfiles) of <src role dir> up into its unified parent,
# then rmdir the role dir. The destination is made root's first (config: root
# 0755 for good; data: root 0700 while entries move, then the data owner), so the
# service account cannot add or swap names in it meanwhile, and each entry moves
# with mv -T, never into a directory or a link. Collision-guarded: aborts
# (-> rollback) if a same-named entry already exists in the destination, so
# nothing is ever clobbered. Records moved basenames in the named array
# (CONFIG_MOVED or DATA_MOVED) for precise rollback.
relocate_dir() {
    local src="$1" dst="$2" arr_name="$3" label="$4"
    local moved=0

    # The moved list is one of two known globals, appended through a case below
    # rather than a nameref so this runs on bash 3.2. Any other name is refused
    # before anything moves.
    case "$arr_name" in
        CONFIG_MOVED|DATA_MOVED) ;;
        *) print_error "relocate_dir: unknown moved-list name '${arr_name}'"; return 1 ;;
    esac

    if [[ "$src" == "$dst" ]]; then
        print_info "${label} already unified (${dst}) -- skipping."
        return 0
    fi
    if [[ ! -d "$src" ]]; then
        print_warn "${label} source ${src} not found -- skipping."
        return 0
    fi

    print_step "Relocating ${label}: ${src}/* -> ${dst}/"
    # Flag first: a rollback then also hands a data destination back to the
    # service account's reach, even when nothing moved.
    case "$label" in config) MOVED_CONFIG=true ;; data) MOVED_DATA=true ;; esac
    if [[ "$label" == data ]]; then
        _tn_root_layout_dir "$dst" root 0700 || return 1
    else
        _tn_root_layout_dir "$dst" root 0755 || return 1
    fi
    shopt -s dotglob nullglob
    local item base
    # Pass 1: collision check (before moving anything).
    for item in "$src"/*; do
        base="$(basename "$item")"
        if [[ -e "${dst}/${base}" ]]; then
            shopt -u dotglob nullglob
            print_error "Refusing to migrate: ${dst}/${base} already exists (would clobber)."
            return 1
        fi
    done
    # Pass 2: move.
    for item in "$src"/*; do
        base="$(basename "$item")"
        mv -T -- "$item" "${dst}/${base}"
        case "$arr_name" in
            CONFIG_MOVED) CONFIG_MOVED+=("$base") ;;
            DATA_MOVED)   DATA_MOVED+=("$base") ;;
        esac
        moved=$((moved + 1))
    done
    shopt -u dotglob nullglob

    rmdir "$src" 2>/dev/null || print_warn "Could not rmdir ${src} (not empty?) -- left in place."

    # The DATA dir is bind-mounted read-WRITE and the node runs as a non-root container user,
    # so it must OWN this dir to create/rotate its DB files. We just moved the contents into
    # ${dst} (a root-owned parent), so reassert the captured owner on it; otherwise the node
    # hits "Permission denied" rotating its LOG and exits 1. (CONFIG is mounted read-only, so
    # its dir ownership is left untouched.)
    if [[ "$label" == data && -n "$DATA_OWNER" ]]; then
        chown -h -- "$DATA_OWNER" "$dst" 2>/dev/null \
            || print_warn "Could not chown ${dst} to ${DATA_OWNER} -- node may fail to start."
    fi
    print_ok "Relocated ${label} (${moved} entries)."
}

# =============================================================================
# STEP 6 -- REWRITE THE SYSTEMD UNIT
# =============================================================================
# Targeted substitutions on the .bak copy (order matters): role-suffixed paths
# first, then the role-suffixed name (catches --name, ExecStart/Stop, Description,
# SyslogIdentifier, log paths). The container/host log dir (/var/log/telcoin) is
# shared and stays put; only the telcoin-<role> filename part is rewritten.
# Cosmetic: the role is dropped from Description (-> "Telcoin Network Node"). The
# legacy wrapper path is replaced first, literally, by the unified start script.
# The unit is written root-owned, with the legacy unit's mode minus group/other
# write, through tn_write_root_file; it must then start the unified script.
rewrite_unit() {
    local mode body
    print_step "Rewriting systemd unit -> ${UNIFIED_UNIT}"
    migrate_backup_ok "$UNIT_BAK" "$UNIT_SHA"
    mode="$(_tn_strip_gw "${UNIT_MODE:-644}")"
    body="$(TN_OLD="$LEGACY_WRAPPER" TN_NEW="$UNIFIED_WRAPPER" awk '
        { out = ""; line = $0
          while ((i = index(line, ENVIRON["TN_OLD"])) > 0) {
              out = out substr(line, 1, i - 1) ENVIRON["TN_NEW"]
              line = substr(line, i + length(ENVIRON["TN_OLD"]))
          }
          print out line }' "$UNIT_BAK" | sed -E \
        -e "s#/etc/telcoin/${ROLE}#/etc/telcoin#g" \
        -e "s#/var/lib/telcoin/${ROLE}#/var/lib/telcoin#g" \
        -e "s#telcoin-${ROLE}#telcoin#g" \
        -e 's#Network (Observer|Validator) Node#Network Node#g')"
    printf '%s\n' "$body" | tn_write_root_file "$UNIFIED_UNIT" "$mode"
    WROTE_UNIT=true
    if ! grep -E '^ExecStart=' "$UNIFIED_UNIT" | grep -qF -- "$UNIFIED_WRAPPER"; then
        print_error "The rewritten unit does not start ${UNIFIED_WRAPPER} -- aborting."
        return 1
    fi
    print_ok "Wrote ${UNIFIED_UNIT}"
}

# =============================================================================
# STEP 7 -- REWRITE THE WRAPPER (strip --observer and --instance)
# =============================================================================
# Same path substitutions as the unit, PLUS strip BOTH `--observer` and `--instance N`.
# The unified node auto-detects its role (so `--observer` must not be passed) and must run
# on the protocol-default ports (so `--instance`, which offsets every port -- and is mutually
# exclusive with the role flags -- must be removed). Neither may appear in any launch command.
# Two wrapper shapes exist in the wild and BOTH are handled for each flag:
#   1. Multi-line heredoc wrappers (setup-*.sh >= v1.2.22): the flag sits on a line by itself
#      (`--observer \` / `--instance 5 \`). The line-delete removes it whole, keeping the
#      backslash-continuation chain intact (the previous line keeps its `\`).
#   2. Single-line `exec docker run ... telcoin node ... --observer --instance N ...` wrappers
#      (older setup-observer.sh, e.g. v1.2.21 -- the format deployed on the devnet observer):
#      the flags are INLINE. The token-strip removes the flag (and --instance's value) plus
#      one adjacent separator, leaving the rest of the command intact.
# The post-condition guard below fails the migration (-> rollback) if either token survives.
rewrite_wrapper() {
    local mode=0755 group=root
    print_step "Normalizing start wrapper -> ${UNIFIED_WRAPPER} (stripping --observer and --instance)"
    # Written root-owned in the root-owned /usr/local/libexec/telcoin through
    # tn_write_root_file: root 0755 for a binary install, root:<service group>
    # 0750 for Docker, as setup-node.sh writes them.
    if [[ "$INSTALL_METHOD_L" == "docker" ]]; then
        mode=0750
        group="${SERVICE_GROUP:-root}"
        getent group "$group" >/dev/null 2>&1 || group=root
    fi
    migrate_backup_ok "$WRAPPER_BAK" "$WRAPPER_SHA"
    _tn_root_layout_dir "${UNIFIED_WRAPPER%/*}" root 0755
    sed -E \
        -e "s#/etc/telcoin/${ROLE}#/etc/telcoin#g" \
        -e "s#/var/lib/telcoin/${ROLE}#/var/lib/telcoin#g" \
        -e "s#telcoin-${ROLE}#telcoin#g" \
        -e '/^[[:space:]]*--observer[[:space:]]*\\?[[:space:]]*$/d' \
        -e 's/(^|[[:space:]])--observer([[:space:]]|$)/\2/g' \
        -e '/^[[:space:]]*--instance([[:space:]]+|=)[0-9]+[[:space:]]*\\?[[:space:]]*$/d' \
        -e 's/(^|[[:space:]])--instance([[:space:]]+|=)[0-9]+([[:space:]]|$)/\3/g' \
        "$WRAPPER_BAK" | tn_write_root_file "$UNIFIED_WRAPPER" "$mode" "$group"
    WROTE_WRAPPER=true

    # Safety check: the normalized wrapper must NOT still pass --observer or --instance.
    if grep -qE '(^|[[:space:]])--(observer|instance)([[:space:]]|=|$)' "$UNIFIED_WRAPPER"; then
        print_error "Normalized wrapper still contains --observer/--instance -- aborting."
        return 1
    fi
    print_ok "Wrote ${UNIFIED_WRAPPER} (no --observer/--instance)"
}

# =============================================================================
# STEP 8 -- UPDATE .node-meta
# =============================================================================
# Keys are written with lib/common.sh's meta_set KEY VALUE FILE. It rewrites the
# file without sed, so a value holding #, &, = or spaces (a custom data mount, say)
# is stored exactly as given, and every other key in the file is kept; the file is
# written root:root 0600 through tn_write_root_file (meta_set creates it when
# absent).
update_meta() {
    local meta="${UNIFIED_CONFIG_DIR}/.node-meta"
    WROTE_META=true
    if [[ ! -f "$meta" ]]; then
        print_warn "No ${meta} after relocation -- writing a minimal one."
    fi
    local ws_port=8546   # reth WS default with no --instance (legacy --instance 5 -> 8554)
    print_step "Updating ${meta} (NODE_TYPE removed, DATA_DIR=${EFFECTIVE_DATA_DIR}, RPC_PORT=${RPC_PORT}, WS_PORT=${ws_port})"
    # No role is recorded on the server, so the old NODE_TYPE hint goes. The
    # validator view comes from the on-chain stake status (node_stake_status in
    # lib/common.sh); a .node-meta without NODE_TYPE reads as the plain full-node
    # view everywhere.
    meta_unset NODE_TYPE "$meta"
    # EFFECTIVE_DATA_DIR: /var/lib/telcoin for a default install, or the operator's
    # preserved custom mount (2nd disk) -- so the node keeps finding its data.
    meta_set DATA_DIR "$EFFECTIVE_DATA_DIR" "$meta"
    # RPC + WS revert to their protocol defaults now that --instance is stripped (the legacy
    # observer's --instance 5 put them on 8541/8554). RPC_PORT/WS_PORT in .node-meta are read by
    # the local Node Manager UI, check-node.sh, and install-caddy.sh (operator-facing, this repo)
    # -- and SEPARATELY by the maintainer fleet's common/config-caddy.sh (maintainer-only, never
    # on an operator box) -- so a stale value breaks the public RPC/WS proxy + health probes.
    # (Matches setup-node.sh, which persists RPC_PORT=8545 / WS_PORT=8546 for fresh installs --
    # the migration is the only path that would otherwise leave them stale.)
    meta_set RPC_PORT "$RPC_PORT" "$meta"
    meta_set WS_PORT "$ws_port" "$meta"

    # Optional: record VALIDATOR_ADDRESS from node-info.yaml execution_address for
    # the UI's on-chain status card. NOT consumed at node launch (only by keygen /
    # staking and the post-start status check), so it is purely informational here.
    local ni="${EFFECTIVE_DATA_DIR}/node-info.yaml" exec_addr=""
    if [[ -f "$ni" ]]; then
        exec_addr="$(grep -E '^[[:space:]]*execution_address[[:space:]]*:' "$ni" 2>/dev/null \
            | head -n1 | sed -E 's/.*:[[:space:]]*"?([0-9a-fA-Fx]+)"?.*/\1/' || true)"
    fi
    if [[ "$exec_addr" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        meta_set VALIDATOR_ADDRESS "$exec_addr" "$meta"
        print_ok "Recorded VALIDATOR_ADDRESS=${exec_addr}"
    fi

    print_ok "Updated .node-meta (root 0600; the UI reads it through its privileged helper)."
}

# =============================================================================
# STEP 9 -- RELOAD/ENABLE
# =============================================================================
# The legacy unit (stopped and disabled) and wrapper stay until the new unit is
# verified (remove_legacy_units), so a rollback finds them in place.
finalize_units() {
    print_step "Enabling ${UNIFIED_SERVICE}..."
    systemctl daemon-reload
    systemctl enable "$UNIFIED_SERVICE" 2>/dev/null || true
    print_ok "${UNIFIED_SERVICE}.service enabled."
}

# =============================================================================
# STEP 10 -- START & VERIFY
# =============================================================================
start_and_verify() {
    print_step "Starting ${UNIFIED_SERVICE} and verifying..."
    systemctl start "$UNIFIED_SERVICE"

    # is-active (give it a moment; docker pull/boot can take a bit).
    local i active=false
    for i in $(seq 1 30); do
        if systemctl is-active --quiet "$UNIFIED_SERVICE"; then active=true; break; fi
        sleep 2
    done
    [[ "$active" == true ]] || { print_error "${UNIFIED_SERVICE} did not become active."; return 1; }
    print_ok "${UNIFIED_SERVICE} is active."

    # RPC liveness (eth_chainId) on the node's RPC port.
    local rpc_ok=false
    for i in $(seq 1 30); do
        if curl -s --max-time 5 -X POST -H 'Content-Type: application/json' \
               --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
               "http://127.0.0.1:${RPC_PORT}" 2>/dev/null | grep -q '"result"'; then
            rpc_ok=true; break
        fi
        sleep 2
    done
    if [[ "$rpc_ok" == true ]]; then
        print_ok "RPC responding on 127.0.0.1:${RPC_PORT} (eth_chainId)."
    else
        # Active but RPC not up yet is suspicious -- treat as failure so we roll back
        # rather than leave a half-working node.
        print_error "RPC did not respond on 127.0.0.1:${RPC_PORT} after ~60s."
        return 1
    fi
}

# =============================================================================
# STEP 10.5 -- REMOVE THE LEGACY UNIT AND WRAPPER
# =============================================================================
# Only after the new unit runs and answers. NON-FATAL by design, like the steps
# after it: the ERR trap is still armed, so every command is guarded and the step
# returns 0 (a leftover legacy file must never roll back a healthy node).
remove_legacy_units() {
    print_step "Removing the legacy unit and wrapper..."
    rm -f -- "$LEGACY_UNIT" 2>/dev/null || print_warn "Could not remove ${LEGACY_UNIT}; remove it by hand."
    if [[ -e "$LEGACY_WRAPPER" || -L "$LEGACY_WRAPPER" ]]; then
        rm -f -- "$LEGACY_WRAPPER" 2>/dev/null || print_warn "Could not remove ${LEGACY_WRAPPER}; remove it by hand."
    fi
    systemctl daemon-reload 2>/dev/null || true
    print_ok "Legacy unit and wrapper removed."
    return 0
}

# =============================================================================
# STEP 11 -- OPEN P2P CONSENSUS PORTS (validator-capable)
# =============================================================================
# Every unified node is provisioned validator-capable, which includes the P2P
# consensus UDP ports: 49590 (primary) and 49594 (worker). Open them via ufw if
# present. NON-FATAL by design: the ERR trap is still armed here (report disarms
# it), so every command is guarded and the step always returns 0 -- a firewall
# hiccup must never roll back an otherwise-healthy migration. Idempotent (ufw
# dedups identical rules; re-running the migration re-asserts the same two rules).
open_consensus_ports() {
    print_step "Opening P2P consensus UDP ports (49590 primary, 49594 worker)..."
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 49590/udp >/dev/null 2>&1 || true
        ufw allow 49594/udp >/dev/null 2>&1 || true
        print_ok "ufw rules ensured for 49590/udp and 49594/udp."
    else
        print_warn "ufw not present -- open UDP 49590 and 49594 by other means so this"
        print_warn "node can receive consensus traffic when it joins the committee."
    fi
    return 0
}

# =============================================================================
# STEP 11.5 -- REFRESH THE LOCAL NODE MANAGER UI
# =============================================================================
# The migration rewrote .node-meta (new RPC_PORT/WS_PORT + unified role labels).
# The local Node Manager UI (telcoin-ui) caches those at startup, so restart it --
# when installed -- to force a re-read. NON-FATAL by design, exactly like
# open_consensus_ports above: the ERR trap is still armed (report disarms it), so
# every command is guarded and the step always returns 0 -- a UI hiccup must never
# roll back an otherwise-healthy migration. A node with no UI installed is a no-op.
restart_ui_if_present() {
    print_step "Refreshing the local Node Manager UI (telcoin-ui)..."
    if [[ -f /etc/systemd/system/telcoin-ui.service ]] \
       || systemctl list-unit-files telcoin-ui.service 2>/dev/null | grep -q '^telcoin-ui\.service'; then
        systemctl restart --no-block telcoin-ui 2>/dev/null || true
        print_ok "telcoin-ui restarted -- it re-reads .node-meta (new RPC/WS ports + unified labels)."
        print_info "If the dashboard still shows stale ports/role labels, refresh the UI bundle with update-scripts.sh (redeploys the UI)."
    else
        print_info "telcoin-ui not installed -- skipping UI refresh."
    fi
    return 0
}

# =============================================================================
# STEP 12 -- REPORT
# =============================================================================
report() {
    # Migration succeeded -- disarm the rollback trap.
    trap - ERR
    print_header "Migration complete"
    print_ok "Unified layout now in place:"
    print_info "  unit:       ${UNIFIED_UNIT}"
    print_info "  wrapper:    ${UNIFIED_WRAPPER}"
    print_info "  config dir: ${UNIFIED_CONFIG_DIR}"
    print_info "  data dir:   ${EFFECTIVE_DATA_DIR}$([[ "$CUSTOM_DATA_DIR" == true ]] && echo ' (custom mount, preserved)')"
    print_info "  NODE_TYPE:  removed (the validator view follows the on-chain stake status)"
    echo ""
    print_info "Node RPC/WS now on ${RPC_PORT}/8546 (was 8541/8554 under --instance). The local"
    print_info "Node Manager UI reads both from .node-meta and was restarted just now (when"
    print_info "installed), so its cached ports + unified role labels refresh automatically."
    print_warn "ONLY if you expose a PUBLIC RPC endpoint: re-run install-caddy.sh (this repo) to"
    print_warn "repoint the reverse-proxy at ${RPC_PORT}/8546, else that public endpoint will 502."
    echo ""
    print_info "Backups kept (delete once you've confirmed the node is healthy):"
    [[ -n "$UNIT_BAK"    ]] && print_info "  ${UNIT_BAK}"
    [[ -n "$WRAPPER_BAK" ]] && print_info "  ${WRAPPER_BAK}"
    [[ -n "$META_BAK"    ]] && print_info "  ${META_BAK}"
    echo ""
    print_info "Unified layout in place; this node is validator-capable. The dashboard"
    print_info "switches to the validator view once the on-chain stake status"
    print_info "(ConsensusRegistry getValidator) shows this node staked. When this node is"
    print_info "in committee it participates in consensus at the next epoch boundary"
    print_info "(watch tn_latestConsensusHeader advancing)."
    print_info "Logs:   journalctl -u ${UNIFIED_SERVICE} -f"
    print_info "Status: systemctl status ${UNIFIED_SERVICE}"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    detect_legacy        # step 1 (may exit 0 if already migrated / declined)
    migrate_take_lock    # held to the end; the EXIT trap releases it
    snapshot             # step 2 (arms rollback)
    stop_legacy          # step 3 (waits for the restart window first)
    relocate_dir "$LEGACY_CONFIG_DIR" "$UNIFIED_CONFIG_DIR" CONFIG_MOVED config   # step 4
    relocate_dir "$LEGACY_DATA_DIR"   "$EFFECTIVE_DATA_DIR" DATA_MOVED   data     # step 5 (no-op for a custom mount: src==dst)
    rewrite_unit         # step 6
    rewrite_wrapper      # step 7 (strip --observer and --instance)
    update_meta          # step 8
    finalize_units       # step 9
    start_and_verify      # step 10 (failure -> rollback via ERR trap)
    remove_legacy_units   # step 10.5 (non-fatal; only after a verified start)
    open_consensus_ports  # step 11 (non-fatal; validator-capable P2P ports)
    restart_ui_if_present # step 11.5 (non-fatal; refresh local Node Manager UI)
    report                # step 12
}

# Run only when executed directly; sourcing (e.g. for unit tests) just defines the
# functions without performing the migration.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
