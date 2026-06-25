#!/usr/bin/env bash
# =============================================================================
# lib/fallback.sh — Legacy-install compatibility shim.
#
# THIS IS THE ONLY FILE PERMITTED to mention the old per-role identity
# (telcoin-observer / telcoin-validator) and the old per-role directory layout
# (/etc/telcoin/{observer,validator}, /var/lib/telcoin/{observer,validator}).
# Keeping that knowledge quarantined here lets every other script stay on the
# single, unified happy path.
#
# Background: operators run ONE node per VM, so the historical dual identity is
# needless. New installs use a single name everywhere:
#     systemd unit   telcoin            (telcoin.service)
#     docker --name  telcoin
#     config dir     /etc/telcoin       (.node-meta carries NODE_TYPE=)
#     data dir       /var/lib/telcoin
# Nodes deployed under the OLD names keep working untouched: these resolvers
# short-circuit to the new values on the happy path and only fall through to
# legacy detection when the new layout is absent ("fall back if there are
# issues"). They never rename or migrate an existing install.
#
# lib/common.sh sources this once near the top, so every script that sources
# common.sh gets the resolvers for free. Scripts that do NOT source common.sh
# must source this file directly.
#
# Testability: every filesystem probe is rooted at ${TN_ROOT_PREFIX} (empty in
# production), so the resolvers can be unit-tested against a temp tree without
# root. Set TN_ROOT_PREFIX=/tmp/fixture before sourcing to redirect all probes.
# =============================================================================

# Idempotent: safe to source more than once (common.sh + a direct source).
[[ -n "${_TN_FALLBACK_SH:-}" ]] && return 0
_TN_FALLBACK_SH=1

# Version, gated by update-scripts.sh like every other tracked file.
readonly FALLBACK_VERSION="1.0.0"

# Root prepended to every absolute probe path. Empty in production; a temp dir
# under test. `:=` leaves a caller-provided value (the test harness) untouched.
: "${TN_ROOT_PREFIX:=}"

# Canonical new-install identity.
readonly TN_SERVICE_NEW="telcoin"
readonly TN_CONTAINER_NEW="telcoin"
# Legacy unit / container base names. Validator is listed first so it is
# preferred when a host (improbably) has both.
readonly TN_LEGACY_NAMES=("telcoin-validator" "telcoin-observer")

# --- internal path helpers (prefix-aware) ------------------------------------
_tn_unit_dir() { printf '%s/etc/systemd/system' "${TN_ROOT_PREFIX}"; }
_tn_etc()      { printf '%s/etc/telcoin'        "${TN_ROOT_PREFIX}"; }
_tn_var()      { printf '%s/var/lib/telcoin'    "${TN_ROOT_PREFIX}"; }
_tn_install()  { printf '%s/opt/telcoin'        "${TN_ROOT_PREFIX}"; }

# _tn_meta_get <key> <file> — echo KEY's value from a .node-meta file. Returns 1
# if the file/key is absent. Self-contained (does not rely on common.sh's
# meta_get, which is defined later in common.sh than this file is sourced).
_tn_meta_get() {
    local key="$1" file="$2" line
    [[ -f "$file" ]] || return 1
    line="$(grep -E "^${key}=" "$file" 2>/dev/null | head -n1)" || true
    [[ -n "$line" ]] || return 1
    printf '%s\n' "${line#*=}"
}

# --- public resolver API (called by the consumer scripts) --------------------

# tn_resolve_service — echo the systemd unit BASE name for the installed node.
#   telcoin.service present            -> telcoin                (new install)
#   else first existing legacy unit    -> telcoin-validator / telcoin-observer
#   else                               -> return 1 (nothing installed)
tn_resolve_service() {
    local dir n
    dir="$(_tn_unit_dir)"
    if [[ -f "${dir}/${TN_SERVICE_NEW}.service" ]]; then
        printf '%s\n' "$TN_SERVICE_NEW"; return 0
    fi
    for n in "${TN_LEGACY_NAMES[@]}"; do
        [[ -f "${dir}/${n}.service" ]] && { printf '%s\n' "$n"; return 0; }
    done
    return 1
}

# tn_all_node_services — echo every candidate unit base name (new + both legacy)
# so remove-node.sh can tear down whatever is present, including legacy installs.
# Order: telcoin, telcoin-validator, telcoin-observer.
tn_all_node_services() {
    printf '%s\n' "$TN_SERVICE_NEW" "${TN_LEGACY_NAMES[@]}"
}

# tn_resolve_container — echo the docker container name present (running OR
# stopped). Prefers `telcoin`, falls back to the legacy names. Returns 1 when
# docker is unavailable or no matching container exists. (Hits real docker, so
# it is not exercised by the TN_ROOT_PREFIX unit tests.)
tn_resolve_container() {
    command -v docker >/dev/null 2>&1 || return 1
    local names n
    names="$(docker ps -a --format '{{.Names}}' 2>/dev/null)" || return 1
    for n in "$TN_CONTAINER_NEW" "${TN_LEGACY_NAMES[@]}"; do
        grep -qx "$n" <<<"$names" && { printf '%s\n' "$n"; return 0; }
    done
    return 1
}

# tn_legacy_node_meta_path — echo the first existing legacy role-dir .node-meta
# (/etc/telcoin/{validator,observer}/.node-meta). Returns 1 if neither exists.
# common.sh's node_meta_path() checks the unified path first, then delegates the
# legacy scan here.
tn_legacy_node_meta_path() {
    local etc t
    etc="$(_tn_etc)"
    for t in validator observer; do
        [[ -f "${etc}/${t}/.node-meta" ]] && { printf '%s\n' "${etc}/${t}/.node-meta"; return 0; }
    done
    return 1
}

# tn_resolve_config_dir — echo the config dir for the installed node.
#   unified .node-meta present  -> /etc/telcoin           (new install)
#   else legacy role dir whose .node-meta exists -> /etc/telcoin/<role>
#   else                        -> /etc/telcoin           (new-install default)
tn_resolve_config_dir() {
    local etc t
    etc="$(_tn_etc)"
    [[ -f "${etc}/.node-meta" ]] && { printf '%s\n' "$etc"; return 0; }
    for t in validator observer; do
        [[ -f "${etc}/${t}/.node-meta" ]] && { printf '%s\n' "${etc}/${t}"; return 0; }
    done
    printf '%s\n' "$etc"
}

# tn_resolve_data_dir — symmetric to tn_resolve_config_dir, for /var/lib/telcoin.
# Keyed off the CONFIG .node-meta (the authoritative install marker).
tn_resolve_data_dir() {
    local etc var t
    etc="$(_tn_etc)"
    var="$(_tn_var)"
    [[ -f "${etc}/.node-meta" ]] && { printf '%s\n' "$var"; return 0; }
    for t in validator observer; do
        [[ -f "${etc}/${t}/.node-meta" ]] && { printf '%s\n' "${var}/${t}"; return 0; }
    done
    printf '%s\n' "$var"
}

# _tn_wrapper_has_observer — true if a start wrapper passes --observer (last-ditch
# node-type signal for a legacy install with no role-dir .node-meta).
_tn_wrapper_has_observer() {
    local inst f
    inst="$(_tn_install)"
    for f in "${inst}/start-${TN_SERVICE_NEW}.sh" "${inst}/start-telcoin-validator.sh" "${inst}/start-telcoin-observer.sh"; do
        [[ -f "$f" ]] && grep -q -- '--observer' "$f" 2>/dev/null && return 0
    done
    return 1
}

# tn_resolve_node_type — echo observer|validator.
#   new install  -> NODE_TYPE= from the unified /etc/telcoin/.node-meta
#   legacy       -> the role dir that has a .node-meta
#   last resort  -> --observer in the start wrapper, else validator
tn_resolve_node_type() {
    local etc nt t
    etc="$(_tn_etc)"
    if [[ -f "${etc}/.node-meta" ]]; then
        nt="$(_tn_meta_get NODE_TYPE "${etc}/.node-meta" || true)"
        [[ -n "$nt" ]] && { printf '%s\n' "$nt"; return 0; }
    fi
    for t in validator observer; do
        [[ -f "${etc}/${t}/.node-meta" ]] && { printf '%s\n' "$t"; return 0; }
    done
    if _tn_wrapper_has_observer; then printf 'observer\n'; else printf 'validator\n'; fi
}
