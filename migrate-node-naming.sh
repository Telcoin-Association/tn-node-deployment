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
#     /opt/telcoin/start-telcoin.sh / /var/log/telcoin/telcoin*.log
# (.node-meta carries NODE_TYPE=). lib/fallback.sh keeps legacy installs WORKING
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
# (including the P2P consensus UDP ports 49590 + 49594). NODE_TYPE is written as a
# non-authoritative presentation HINT (observer); the real authority is on-chain
# tn_isValidator, from which the dashboard auto-selects the validator view. The
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
# self-rolling-back: on any failure it restores the legacy unit/wrapper, moves the
# dirs back, restarts the legacy service, and exits non-zero with the backup paths.
#
# Downtime is expected and acceptable (stop -> migrate -> start). The node
# rejoins consensus at the next epoch boundary when it is in committee.
#
# Node-side Linux bash. Run as root on the node:  sudo bash migrate-node-naming.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolvers (tn_resolve_*) + print helpers + check_root + _tn_meta_get. common.sh
# sources lib/fallback.sh, the only module that knows the legacy names/layout.
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# errtrace: WITHOUT -E the ERR trap (on_error) is NOT inherited by shell
# functions, so a failure inside a migration step would exit WITHOUT running
# rollback(). With -E the trap fires for in-function failures, so rollback always
# runs. (common.sh's own `set -euo pipefail` does not clear -E.)
set -E

# Version, gated by update-scripts.sh like every other tracked file.
readonly SCRIPT_VERSION="1.0.1"

# Unified (target) identity -- mirrors lib/fallback.sh's canonical new-install names.
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly UNIFIED_SERVICE="telcoin"
readonly UNIFIED_UNIT="${SYSTEMD_DIR}/telcoin.service"
readonly UNIFIED_CONFIG_DIR="/etc/telcoin"
readonly UNIFIED_DATA_DIR="/var/lib/telcoin"
readonly UNIFIED_WRAPPER="/opt/telcoin/start-telcoin.sh"

# --- Detection results (filled by detect_legacy) -----------------------------
ROLE=""                 # observer | validator (the legacy role being migrated)
LEGACY_UNIT=""          # /etc/systemd/system/telcoin-<role>.service
LEGACY_WRAPPER=""       # /opt/telcoin/start-telcoin-<role>.sh (read from ExecStart)
LEGACY_CONFIG_DIR=""    # /etc/telcoin/<role>
LEGACY_DATA_DIR=""      # /var/lib/telcoin/<role> (or .node-meta DATA_DIR)
LEGACY_CONTAINER=""     # telcoin-<role>
RPC_PORT="8545"         # for the post-start verify (read from .node-meta; node5 = 8541)

# --- Rollback bookkeeping ----------------------------------------------------
TS=""
UNIT_BAK=""
WRAPPER_BAK=""
META_BAK=""
STOPPED_LEGACY=false
MOVED_CONFIG=false
MOVED_DATA=false
WROTE_UNIT=false
WROTE_WRAPPER=false
ROLLED_BACK=false
declare -a CONFIG_MOVED=()   # basenames moved out of LEGACY_CONFIG_DIR
declare -a DATA_MOVED=()     # basenames moved out of LEGACY_DATA_DIR

ASSUME_YES="${TN_ASSUME_YES:-false}"

usage() {
    cat <<EOF
migrate-node-naming.sh v${SCRIPT_VERSION}

Migrate a legacy telcoin-{observer,validator} install to the unified 'telcoin'
layout: strips the removed --observer flag, sets NODE_TYPE=observer (a non-
authoritative hint), and opens the P2P consensus ports so the node is
validator-capable. Idempotent and self-rolling-back.

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
# ROLLBACK
# =============================================================================
# Reverse the mutations that completed, based on the *_MOVED / WROTE_* flags, so a
# partial migration leaves the node exactly as it was found. Dir moves are `mv`
# (rename on the same filesystem) so they reverse instantly; the big db/ is never
# copied. Never raises (runs with set +e).
rollback() {
    [[ "$ROLLED_BACK" == true ]] && return 0
    ROLLED_BACK=true
    # Maximally defensive: no errexit (rollback must run to completion) and no
    # nounset (expanding an empty *_MOVED array under `set -u` errors on bash 4.3).
    set +eu
    print_warn "Restoring the previous (legacy) layout..."

    # Undo, newest mutation first.
    [[ "$WROTE_UNIT" == true ]]    && rm -f "$UNIFIED_UNIT"
    [[ "$WROTE_WRAPPER" == true ]] && rm -f "$UNIFIED_WRAPPER"

    local base
    if [[ "$MOVED_DATA" == true ]]; then
        mkdir -p "$LEGACY_DATA_DIR"
        for base in "${DATA_MOVED[@]}"; do
            [[ -e "${UNIFIED_DATA_DIR}/${base}" ]] && \
                mv "${UNIFIED_DATA_DIR}/${base}" "${LEGACY_DATA_DIR}/${base}"
        done
    fi
    if [[ "$MOVED_CONFIG" == true ]]; then
        mkdir -p "$LEGACY_CONFIG_DIR"
        for base in "${CONFIG_MOVED[@]}"; do
            [[ -e "${UNIFIED_CONFIG_DIR}/${base}" ]] && \
                mv "${UNIFIED_CONFIG_DIR}/${base}" "${LEGACY_CONFIG_DIR}/${base}"
        done
    fi

    # Restore the original .node-meta (we may have rewritten NODE_TYPE/DATA_DIR).
    if [[ -n "$META_BAK" && -f "$META_BAK" && -d "$LEGACY_CONFIG_DIR" ]]; then
        cp -a "$META_BAK" "${LEGACY_CONFIG_DIR}/.node-meta"
    fi

    # Restore the legacy unit + wrapper from their backups (we may have rm'd them).
    [[ -n "$UNIT_BAK"    && -f "$UNIT_BAK"    ]] && cp -a "$UNIT_BAK"    "$LEGACY_UNIT"
    [[ -n "$WRAPPER_BAK" && -f "$WRAPPER_BAK" ]] && cp -a "$WRAPPER_BAK" "$LEGACY_WRAPPER"

    systemctl daemon-reload 2>/dev/null || true
    if [[ "$STOPPED_LEGACY" == true && -n "$ROLE" ]]; then
        systemctl enable "telcoin-${ROLE}" 2>/dev/null || true
        systemctl start  "telcoin-${ROLE}" 2>/dev/null || true
    fi

    print_error "Rolled back to the legacy layout. Backups kept (safe to delete once verified):"
    [[ -n "$UNIT_BAK"    ]] && print_info "  unit:    ${UNIT_BAK}"
    [[ -n "$WRAPPER_BAK" ]] && print_info "  wrapper: ${WRAPPER_BAK}"
    [[ -n "$META_BAK"    ]] && print_info "  meta:    ${META_BAK}"
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
        local nt
        nt="$(tn_resolve_node_type 2>/dev/null || echo '?')"
        print_info "NODE_TYPE=${nt}. Nothing to do."
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
    meta_data="$(_tn_meta_get DATA_DIR "${LEGACY_CONFIG_DIR}/.node-meta" 2>/dev/null || true)"
    if [[ -n "$meta_data" ]]; then
        LEGACY_DATA_DIR="$meta_data"
    else
        LEGACY_DATA_DIR="${UNIFIED_DATA_DIR}/${ROLE}"
    fi

    # Only the role-suffixed default (or an already-unified dir) is auto-relocated.
    # A custom DATA_DIR (the setup wizard allows one) is NOT moved: it could be a
    # slow, risky cross-filesystem copy of the multi-GB db, and the path subs only
    # rewrite the default. Abort and let the operator handle it.
    if [[ "$LEGACY_DATA_DIR" != "$UNIFIED_DATA_DIR" \
       && "$LEGACY_DATA_DIR" != "${UNIFIED_DATA_DIR}/${ROLE}" ]]; then
        print_error "Custom data dir detected: ${LEGACY_DATA_DIR}"
        print_info  "This migration only relocates the default ${UNIFIED_DATA_DIR}/${ROLE} layout."
        print_info  "Move the data to ${UNIFIED_DATA_DIR}/${ROLE} first, or migrate manually."
        exit 1
    fi

    # Wrapper path: read the unit's ExecStart= (authoritative), else convention.
    local exec_start
    exec_start="$(grep -E '^ExecStart=' "$LEGACY_UNIT" 2>/dev/null | head -n1 | sed 's/^ExecStart=//' | awk '{print $1}' || true)"
    if [[ -n "$exec_start" && -f "$exec_start" ]]; then
        LEGACY_WRAPPER="$exec_start"
    else
        LEGACY_WRAPPER="/opt/telcoin/start-telcoin-${ROLE}.sh"
    fi

    # RPC port for the post-start verify (role-independent; tied to reth --instance).
    local meta_rpc
    meta_rpc="$(_tn_meta_get RPC_PORT "${LEGACY_CONFIG_DIR}/.node-meta" 2>/dev/null || true)"
    [[ -n "$meta_rpc" ]] && RPC_PORT="$meta_rpc"

    print_header "Telcoin Node Naming Migration v${SCRIPT_VERSION}"
    print_info "Detected LEGACY install:"
    print_info "  role:       ${ROLE}"
    print_info "  unit:       ${LEGACY_UNIT}"
    print_info "  wrapper:    ${LEGACY_WRAPPER}"
    print_info "  config dir: ${LEGACY_CONFIG_DIR}"
    print_info "  data dir:   ${LEGACY_DATA_DIR}"
    print_info "  container:  ${LEGACY_CONTAINER} (docker installs only)"
    print_info "  RPC port:   ${RPC_PORT}"
    echo ""
    print_info "Will migrate to the UNIFIED layout:"
    print_info "  unit:       ${UNIFIED_UNIT}"
    print_info "  wrapper:    ${UNIFIED_WRAPPER}"
    print_info "  config dir: ${UNIFIED_CONFIG_DIR}"
    print_info "  data dir:   ${UNIFIED_DATA_DIR}"
    echo ""

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
snapshot() {
    TS="$(date +%Y%m%d-%H%M%S)"
    UNIT_BAK="${LEGACY_UNIT}.bak.${TS}"
    WRAPPER_BAK="${LEGACY_WRAPPER}.bak.${TS}"
    META_BAK="${LEGACY_CONFIG_DIR}/.node-meta.bak.${TS}"

    print_step "Backing up legacy unit, wrapper, and .node-meta..."
    cp -a "$LEGACY_UNIT" "$UNIT_BAK"
    print_ok "  ${UNIT_BAK}"
    if [[ -f "$LEGACY_WRAPPER" ]]; then
        cp -a "$LEGACY_WRAPPER" "$WRAPPER_BAK"
        print_ok "  ${WRAPPER_BAK}"
    else
        # No wrapper (unexpected): a bare ExecStart unit. Abort -- we cannot
        # safely rewrite a launch we cannot see.
        print_error "Legacy wrapper not found at ${LEGACY_WRAPPER} -- cannot migrate safely."
        exit 1
    fi
    if [[ -f "${LEGACY_CONFIG_DIR}/.node-meta" ]]; then
        cp -a "${LEGACY_CONFIG_DIR}/.node-meta" "$META_BAK"
        print_ok "  ${META_BAK}"
    else
        META_BAK=""   # nothing to restore
        print_warn "  no ${LEGACY_CONFIG_DIR}/.node-meta to back up (continuing)"
    fi

    # From here on, any failure rolls back.
    arm_rollback
}

# =============================================================================
# STEP 3 -- STOP THE LEGACY SERVICE
# =============================================================================
stop_legacy() {
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
# then rmdir the role dir. Collision-guarded: aborts (-> rollback) if a same-named
# entry already exists in the destination, so nothing is ever clobbered. Records
# moved basenames in the named array for precise rollback.
relocate_dir() {
    local src="$1" dst="$2" arr_name="$3" label="$4"
    local -n moved_ref="$arr_name"   # nameref (bash 4.3+; node is Linux bash 4+)

    if [[ "$src" == "$dst" ]]; then
        print_info "${label} already unified (${dst}) -- skipping."
        return 0
    fi
    if [[ ! -d "$src" ]]; then
        print_warn "${label} source ${src} not found -- skipping."
        return 0
    fi

    print_step "Relocating ${label}: ${src}/* -> ${dst}/"
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
    # Pass 2: move. Mark the flag BEFORE the loop so even a partial move rolls back.
    case "$label" in config) MOVED_CONFIG=true ;; data) MOVED_DATA=true ;; esac
    for item in "$src"/*; do
        base="$(basename "$item")"
        mv "$item" "${dst}/${base}"
        moved_ref+=("$base")
    done
    shopt -u dotglob nullglob

    rmdir "$src" 2>/dev/null || print_warn "Could not rmdir ${src} (not empty?) -- left in place."
    print_ok "Relocated ${label} (${#moved_ref[@]} entries)."
}

# =============================================================================
# STEP 6 -- REWRITE THE SYSTEMD UNIT
# =============================================================================
# Targeted substitutions on the .bak copy (order matters): role-suffixed paths
# first, then the role-suffixed name (catches --name, ExecStart/Stop, Description,
# SyslogIdentifier, log paths, start-telcoin-<role>.sh). The container/host log dir
# (/var/log/telcoin) is shared and stays put; only the telcoin-<role> filename part
# is rewritten. Cosmetic: the role is dropped from Description (-> "Telcoin Network Node").
rewrite_unit() {
    print_step "Rewriting systemd unit -> ${UNIFIED_UNIT}"
    # cp -a the pristine snapshot to the unified PATH first (carries the legacy
    # unit's owner + mode), then transform in place -- so we never have to
    # reconstruct permissions by hand.
    cp -a "$UNIT_BAK" "$UNIFIED_UNIT"
    sed -i -E \
        -e "s#/etc/telcoin/${ROLE}#/etc/telcoin#g" \
        -e "s#/var/lib/telcoin/${ROLE}#/var/lib/telcoin#g" \
        -e "s#telcoin-${ROLE}#telcoin#g" \
        -e 's#Network (Observer|Validator) Node#Network Node#g' \
        "$UNIFIED_UNIT"
    WROTE_UNIT=true
    print_ok "Wrote ${UNIFIED_UNIT}"
}

# =============================================================================
# STEP 7 -- REWRITE THE WRAPPER (strip the removed --observer flag)
# =============================================================================
# Same path substitutions as the unit, PLUS delete the lone `--observer` launch
# line. That flag has been removed from the node binary, so a legacy wrapper still
# passing it would fail to launch -- stripping it normalizes the wrapper. The
# delete matches a line that is only `--observer`, with optional leading indent
# (docker form is column-0 `--observer \`; binary form is 2-space `  --observer \`)
# and an optional trailing backslash. Deleting the whole line preserves the
# backslash-continuation chain (the previous line keeps its own trailing `\`).
rewrite_wrapper() {
    print_step "Normalizing start wrapper -> ${UNIFIED_WRAPPER} (stripping the removed --observer flag)"
    # cp -a preserves the original (security-sensitive) owner + mode: docker
    # wrappers are root:root 0750 (run as root); binary wrappers telcoin:telcoin
    # 0755. Then transform + strip --observer in place.
    cp -a "$WRAPPER_BAK" "$UNIFIED_WRAPPER"
    sed -i -E \
        -e "s#/etc/telcoin/${ROLE}#/etc/telcoin#g" \
        -e "s#/var/lib/telcoin/${ROLE}#/var/lib/telcoin#g" \
        -e "s#telcoin-${ROLE}#telcoin#g" \
        -e '/^[[:space:]]*--observer[[:space:]]*\\?[[:space:]]*$/d' \
        "$UNIFIED_WRAPPER"
    WROTE_WRAPPER=true

    # Safety check: the normalized wrapper must NOT still pass --observer.
    if grep -qE '(^|[[:space:]])--observer([[:space:]]|$)' "$UNIFIED_WRAPPER"; then
        print_error "Normalized wrapper still contains --observer -- aborting."
        return 1
    fi
    print_ok "Wrote ${UNIFIED_WRAPPER} (no --observer)"
}

# =============================================================================
# STEP 8 -- UPDATE .node-meta
# =============================================================================
# meta_set KEY VALUE FILE -- replace an existing KEY= line or append it.
meta_set() {
    local key="$1" val="$2" file="$3"
    if grep -qE "^${key}=" "$file" 2>/dev/null; then
        sed -i -E "s#^${key}=.*#${key}=${val}#" "$file"
    else
        printf '%s=%s\n' "$key" "$val" >> "$file"
    fi
}

update_meta() {
    local meta="${UNIFIED_CONFIG_DIR}/.node-meta"
    if [[ ! -f "$meta" ]]; then
        print_warn "No ${meta} after relocation -- writing a minimal one."
        : > "$meta"
    fi
    print_step "Updating ${meta} (NODE_TYPE=observer, DATA_DIR=${UNIFIED_DATA_DIR})"
    # NODE_TYPE is only the default-view HINT; the UI promotes to the validator view
    # from on-chain tn_isValidator. Every migrated node is the same identity.
    meta_set NODE_TYPE observer "$meta"
    meta_set DATA_DIR "$UNIFIED_DATA_DIR" "$meta"

    # Optional: record VALIDATOR_ADDRESS from node-info.yaml execution_address for
    # the UI's on-chain status card. NOT consumed at node launch (only by keygen /
    # staking and the post-start status check), so it is purely informational here.
    local ni="${UNIFIED_DATA_DIR}/node-info.yaml" exec_addr=""
    if [[ -f "$ni" ]]; then
        exec_addr="$(grep -E '^[[:space:]]*execution_address[[:space:]]*:' "$ni" 2>/dev/null \
            | head -n1 | sed -E 's/.*:[[:space:]]*"?([0-9a-fA-Fx]+)"?.*/\1/' || true)"
    fi
    if [[ "$exec_addr" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        meta_set VALIDATOR_ADDRESS "$exec_addr" "$meta"
        print_ok "Recorded VALIDATOR_ADDRESS=${exec_addr}"
    fi

    # .node-meta is root-owned mode 0600 (the UI reads it via a privileged helper).
    chown root:root "$meta" 2>/dev/null || true
    chmod 600 "$meta" 2>/dev/null || true
    print_ok "Updated .node-meta."
}

# =============================================================================
# STEP 9 -- REMOVE LEGACY ARTIFACTS + RELOAD/ENABLE
# =============================================================================
finalize_units() {
    print_step "Removing legacy unit + wrapper; enabling ${UNIFIED_SERVICE}..."
    rm -f "$LEGACY_UNIT"
    [[ -f "$LEGACY_WRAPPER" ]] && rm -f "$LEGACY_WRAPPER"
    systemctl daemon-reload
    systemctl enable "$UNIFIED_SERVICE" 2>/dev/null || true
    print_ok "Legacy artifacts removed; ${UNIFIED_SERVICE}.service enabled."
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
    print_info "  data dir:   ${UNIFIED_DATA_DIR}"
    print_info "  NODE_TYPE:  observer (presentation hint; on-chain tn_isValidator is authoritative)"
    echo ""
    print_info "Backups kept (delete once you've confirmed the node is healthy):"
    [[ -n "$UNIT_BAK"    ]] && print_info "  ${UNIT_BAK}"
    [[ -n "$WRAPPER_BAK" ]] && print_info "  ${WRAPPER_BAK}"
    [[ -n "$META_BAK"    ]] && print_info "  ${META_BAK}"
    echo ""
    print_info "Unified layout in place; this node is validator-capable. The dashboard"
    print_info "auto-selects the validator view once tn_isValidator is true on-chain. When"
    print_info "this node is in committee it participates in consensus at the next epoch"
    print_info "boundary (watch tn_latestConsensusHeader advancing)."
    print_info "Logs:   journalctl -u ${UNIFIED_SERVICE} -f"
    print_info "Status: systemctl status ${UNIFIED_SERVICE}"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    detect_legacy        # step 1 (may exit 0 if already migrated / declined)
    snapshot             # step 2 (arms rollback)
    stop_legacy          # step 3
    relocate_dir "$LEGACY_CONFIG_DIR" "$UNIFIED_CONFIG_DIR" CONFIG_MOVED config   # step 4
    relocate_dir "$LEGACY_DATA_DIR"   "$UNIFIED_DATA_DIR"   DATA_MOVED   data     # step 5
    rewrite_unit         # step 6
    rewrite_wrapper      # step 7 (strip the removed --observer flag)
    update_meta          # step 8
    finalize_units       # step 9
    start_and_verify     # step 10 (failure -> rollback via ERR trap)
    open_consensus_ports # step 11 (non-fatal; validator-capable P2P ports)
    report               # step 12
}

# Run only when executed directly; sourcing (e.g. for unit tests) just defines the
# functions without performing the migration.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
