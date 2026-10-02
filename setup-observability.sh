#!/usr/bin/env bash
# =============================================================================
# setup-observability.sh -- Telcoin testnet add-on: logs + metrics + health
#
# Opt-in, testnet-only. Independently enable/disable shipping this node's logs (Grafana
# Alloy -> central Loki) and its Prometheus metrics (Alloy -> central Prometheus), plus
# the health-monitor endpoint. Re-runnable at any time. Logs and metrics share ONE
# per-operator ingest token, pasted here (hidden) and stored ONLY in the mode-600 Alloy
# env file -- never in git/.node-meta.
#
# USAGE:
#   sudo bash setup-observability.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

readonly SCRIPT_VERSION="1.2.1"

pause() { echo ""; read -r -p "  Press Enter to return to menu..."; }

# addons_say <step|log|warn> <msg> -- progress printer for the epoch-boundary wait
# before a node restart: a JSON event of the same kind in --json mode, a print_*
# line otherwise.
addons_say() {
    if json_mode; then
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

# addons_lib_check -- before a status screen or an enable, warn when a library is
# older than this script expects. lib/observability.sh 1.0.2 brings obs_lib_check,
# obs_inject_flags and obs_restart_window; without them the flag edits and restarts
# behave as in 1.2.0 (no epoch wait). obs_lib_check then names what an older
# lib/common.sh lacks. Each warning comes once per run.
ADDONS_LIB_WARNED=false
addons_lib_check() {
    if declare -F obs_lib_check >/dev/null 2>&1; then
        obs_lib_check
    elif [[ "$ADDONS_LIB_WARNED" != "true" ]]; then
        ADDONS_LIB_WARNED=true
        print_warn "lib/observability.sh ${OBSERVABILITY_VERSION:-unknown} is older than 1.0.2, so a commented-out flag counts as present, a failed flag edit is not explained, and the node restarts without waiting for the epoch boundary. Run update-scripts.sh to update the library."
    fi
    return 0
}

# health_flag_add FILE -- add --healthcheck <port> to the node command in launch file
# FILE. rc 0 when FILE changed (the caller reloads and restarts). obs_inject_flags
# says why when it did not; an older lib/observability.sh keeps the 1.2.0 message.
health_flag_add() {
    local file="$1" rc=0
    if declare -F obs_inject_flags >/dev/null 2>&1; then
        obs_inject_flags "$file" '--healthcheck' "--healthcheck ${TN_KUMA_PORT}" || rc=$?
        return "$rc"
    fi
    tn_node_inject_flags "$file" "--healthcheck" "--healthcheck ${TN_KUMA_PORT}" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        print_ok "Node already has --healthcheck (or the launch line was not found)."
    fi
    return "$rc"
}

# health_flag_live FILE -- rc 0 when --healthcheck is on the node command in launch file
# FILE: tn_launch_flag_get (lib/common.sh 1.6.0), else any line that is not a comment.
health_flag_live() {
    if declare -F tn_launch_flag_get >/dev/null 2>&1; then
        tn_launch_flag_get "$1" --healthcheck >/dev/null 2>&1 || return 1
        return 0
    fi
    awk '/^[ \t]*[#;]/ { next } { s = " " $0 " "; if (s ~ /[ \t]--healthcheck[ \t=]/) f = 1 } END { exit !f }' "$1" 2>/dev/null
}

# health_restart_window -- right before the node restart that binds the health port:
# the epoch-boundary wait (obs_restart_window), reported through addons_say. Without
# lib/observability.sh 1.0.2 the restart does not wait (addons_lib_check said so).
health_restart_window() {
    if declare -F obs_restart_window >/dev/null 2>&1; then
        obs_restart_window addons_say
    fi
    return 0
}

# Load NETWORK + node context from .node-meta so require_testnet can gate.
load_node_context() {
    local meta
    meta="$(node_meta_path || true)"
    if [[ -z "$meta" ]]; then
        print_error "No Telcoin node detected (no .node-meta under /etc/telcoin)."
        print_info  "Run setup-node.sh first."
        exit 1
    fi
    NETWORK="$(meta_get NETWORK "$meta" 2>/dev/null || true)"
    INSTALL_METHOD="$(meta_get INSTALL_METHOD "$meta" 2>/dev/null || echo binary)"
    REGION="$(meta_get REGION "$meta" 2>/dev/null || true)"
}

# _obs_prompt_region — set REGION (shared identity label), defaulting to the current value.
_obs_prompt_region() {
    local region_in
    read -r -p "  Region label for your node (e.g. us-east, eu-west) [${REGION:-unknown}]: " region_in
    REGION="${region_in:-${REGION:-unknown}}"
}

# _obs_collect_token — populate _OBS_TOKEN: reuse the token already stored on this node
# (so enabling a second pipeline needs no re-paste), else prompt hidden. Returns 1 if the
# operator left it blank with no existing token.
_obs_collect_token() {
    _OBS_TOKEN="$(obs_existing_token)"
    if [[ -n "$_OBS_TOKEN" ]]; then
        print_info "Reusing the ingest token already stored on this node (one token covers logs + metrics)."
        return 0
    fi
    print_info "Paste the per-operator obs ingest token from the Association (input hidden):"
    read -r -s -p "  Token: " _OBS_TOKEN; echo ""
    [[ -n "$_OBS_TOKEN" ]] || { print_warn "No token entered -- aborting."; return 1; }
    return 0
}

# ENABLE_OBSERVABILITY / ENABLE_METRICS are set here as globals that obs_enable
# (lib/observability.sh) reads; shellcheck can't see that cross-file use.
# shellcheck disable=SC2034
enable_logging() {
    print_header "Enable log shipping"
    print_info "Ships this node's logs to the Telcoin Association's Loki:"
    print_info "  ${OBS_PUSH_URL_TESTNET}"
    print_info "You need a per-operator ingest token from the Association (docs/testnet-addons.md)."
    addons_lib_check
    echo ""
    # Turn logs on; preserve any existing metrics opt-in so obs_enable renders both.
    local meta; meta="$(node_meta_path || true)"
    ENABLE_METRICS="$(meta_get ENABLE_METRICS "$meta" 2>/dev/null || echo false)"
    ENABLE_OBSERVABILITY="true"
    _obs_prompt_region
    if _obs_collect_token; then
        if obs_enable "$_OBS_TOKEN" addons_say; then print_ok "Log shipping enabled."; else print_error "Could not enable logging (see messages above)."; fi
    fi
    _OBS_TOKEN=""
    pause
}

# ENABLE_OBSERVABILITY / ENABLE_METRICS are set here as globals that obs_enable
# (lib/observability.sh) reads; shellcheck can't see that cross-file use.
# shellcheck disable=SC2034
enable_metrics() {
    print_header "Enable metrics shipping"
    print_info "Ships this node's Prometheus metrics to the Association's central Prometheus:"
    print_info "  ${OBS_METRICS_PUSH_URL_TESTNET}"
    print_info "Reuses the SAME ingest token as logging (one token covers both)."
    addons_lib_check
    echo ""
    # Turn metrics on; preserve any existing logs opt-in so obs_enable renders both.
    local meta; meta="$(node_meta_path || true)"
    ENABLE_OBSERVABILITY="$(meta_get ENABLE_OBSERVABILITY "$meta" 2>/dev/null || echo false)"
    ENABLE_METRICS="true"
    _obs_prompt_region
    if _obs_collect_token; then
        if obs_enable "$_OBS_TOKEN" addons_say; then print_ok "Metrics shipping enabled."; else print_error "Could not enable metrics (see messages above)."; fi
    fi
    _OBS_TOKEN=""
    pause
}

disable_logging() {
    print_header "Disable log shipping"
    if confirm "Stop shipping logs (metrics, if on, keeps running)?"; then
        obs_disable_logs
    else
        print_info "Cancelled."
    fi
    pause
}

disable_metrics() {
    print_header "Disable metrics shipping"
    if confirm "Stop shipping metrics (logs, if on, keeps running)?"; then
        obs_disable_metrics
    else
        print_info "Cancelled."
    fi
    pause
}

enable_health() {
    print_header "Enable health monitoring"
    print_info "Adds --healthcheck ${TN_KUMA_PORT} to the node launch and source-restricts the"
    print_info "ufw rule to the Association monitor only (${TN_KUMA_SRC})."
    addons_lib_check
    echo ""
    local target svc method file live=true
    if target="$(tn_node_launch_target)"; then
        read -r svc method file <<< "$target"
        if health_flag_add "$file"; then
            [[ "$method" == "docker" ]] && systemctl daemon-reload
            print_ok "Added --healthcheck ${TN_KUMA_PORT} to ${file}"
            print_warn "The node must restart for the health endpoint to bind."
            if confirm "Restart ${svc} now?"; then
                health_restart_window
                systemctl restart "$svc" && print_ok "${svc} restarted." || print_warn "Restart manually: sudo systemctl restart ${svc}"
            else
                print_info "Restart later: sudo systemctl restart ${svc}"
            fi
        fi
        if ! health_flag_live "$file"; then
            live=false
        fi
    else
        print_warn "No node service detected; setting the firewall rule + flag only."
    fi

    if ufw_installed && ufw_active; then
        apply_kuma_rule && print_ok "ufw: ${TN_KUMA_SRC} -> ${TN_KUMA_PORT}/tcp (Association monitor only)"
        local extras; extras="$(kuma_extra_list)"
        [[ -n "$extras" ]] && print_ok "ufw: also restored your additional source(s): ${extras}"
    elif ufw_installed; then
        # ufw installed but INACTIVE: --healthcheck binds ${TN_KUMA_PORT} on all interfaces,
        # so with no active firewall the port is reachable from the internet.
        apply_kuma_rule >/dev/null 2>&1 || true   # stage the restricted rule for when ufw is enabled
        print_warn "ufw is INACTIVE -- once the node restarts, health port ${TN_KUMA_PORT} is reachable from the INTERNET."
        print_warn "Enable the firewall: run firewall-setup.sh (a source-restricted rule is already staged)."
    else
        print_warn "ufw is NOT installed -- health port ${TN_KUMA_PORT} will be exposed to the internet once the node restarts."
        print_warn "Install ufw + run firewall-setup.sh, or otherwise block ${TN_KUMA_PORT}/tcp."
    fi
    # Record the monitor as enabled only when the flag is on the node command, so status
    # readers (the UI's add-ons card reads .node-meta) never show a half-applied enable.
    if [[ "$live" == "true" ]]; then
        local meta; meta="$(node_meta_path || true)"
        if [[ -n "$meta" ]]; then
            meta_set ENABLE_HEALTHCHECK_MONITOR true "$meta"
        fi
        print_info "Verify once running: curl -s http://127.0.0.1:${TN_KUMA_PORT}  (expect OK)"
    else
        print_warn "Health monitoring is not recorded as enabled: --healthcheck is not on the node command. Add it as described above, then choose this option again."
    fi
    pause
}

disable_health() {
    print_header "Disable health monitoring"
    if ufw_installed && ufw_active; then
        ufw delete allow from "${TN_KUMA_SRC}" to any port "${TN_KUMA_PORT}" proto tcp &>/dev/null || true
        print_ok "Removed the ufw rule ${TN_KUMA_SRC} -> ${TN_KUMA_PORT}/tcp"
        # The port stops listening once --healthcheck is removed, so any operator-chosen
        # allow rules are pointless -- delete them. Keep the persisted KUMA_EXTRA_SRC meta
        # so re-enabling restores the operator's set automatically (via apply_kuma_rule).
        local esrc
        for esrc in $(kuma_extra_list); do
            ufw delete allow from "$esrc" to any port "${TN_KUMA_PORT}" proto tcp &>/dev/null || true
            print_ok "Removed the ufw rule ${esrc} -> ${TN_KUMA_PORT}/tcp"
        done
    fi
    local meta; meta="$(node_meta_path || true)"; [[ -n "$meta" ]] && meta_set ENABLE_HEALTHCHECK_MONITOR false "$meta"
    print_info "The --healthcheck flag stays in the node launch (harmless once the port is"
    print_info "firewalled). To remove it entirely, re-run node setup without health monitoring."
    pause
}

show_status() {
    print_header "Observability status"
    addons_lib_check
    obs_status
    echo ""
    print_step "Health monitor"
    local meta hc
    meta="$(node_meta_path || true)"
    hc="$(meta_get ENABLE_HEALTHCHECK_MONITOR "$meta" 2>/dev/null || echo false)"
    print_info "Configured: ENABLE_HEALTHCHECK_MONITOR=${hc:-false}"
    local extras; extras="$(kuma_extra_list)"
    [[ -n "$extras" ]] && print_info "Additional health-port sources (besides ${TN_KUMA_SRC}): ${extras}"
    if curl -fsS "http://127.0.0.1:${TN_KUMA_PORT}" >/dev/null 2>&1; then
        print_ok "Health endpoint responds on 127.0.0.1:${TN_KUMA_PORT}"
    else
        print_info "Health endpoint not responding (node down, or healthcheck not enabled)."
    fi
    pause
}

# =============================================================================
# NON-INTERACTIVE (--json) MODE
#
# Maps flags to the SAME lib functions the interactive menu uses, with no reads/
# prompts. Mirrors the fd-3 JSON contract of setup-node.sh / firewall-setup.sh:
# JSON objects on fd3 (original stdout); all print_*/systemctl noise redirected to
# stderr. When an enable restarts the node, the epoch-boundary wait before it reports
# through addons_say as step / log / warn events. The interactive default path below
# is untouched when --json is absent.
# =============================================================================

JSON_MODE=false
JSON_DONE_EMITTED=false

json_mode() { [[ "$JSON_MODE" == "true" ]]; }

json_setup_fds() {
    exec 3>&1   # fd3 = original stdout: JSON is written here
    exec 1>&2   # stdout now aliases stderr: print_*/systemctl output is benign noise
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/ }"; s="${s//$'\t'/ }"
    printf '%s' "$s"
}

json_emit() { printf '%s\n' "$1" >&3; }
json_event() { json_emit "{\"event\":\"${1}\",\"msg\":\"$(json_escape "${2:-}")\"}"; }
json_done() { JSON_DONE_EMITTED=true; json_emit "$1"; }

# Emitted on ANY exit if no terminal done was sent -- so an `exit 1` deep inside a
# toggle (token missing, empty push URL, obs_enable failure) still yields done:false.
json_on_exit() {
    local rc=$?
    [[ "$JSON_DONE_EMITTED" == "true" ]] && return
    json_emit "{\"event\":\"done\",\"ok\":false,\"msg\":\"observability setup exited early (rc=${rc}) -- see server logs / journalctl\"}"
}

# json error + nonzero exit. Shorthand for the many failure paths below.
json_fail() { json_event error "$1"; exit "${2:-1}"; }

# json_applied -- the JSON_DID items as the inside of a JSON array.
json_applied() {
    local out="" item
    for item in ${JSON_DID[@]+"${JSON_DID[@]}"}; do
        out+="${out:+,}\"$(json_escape "$item")\""
    done
    printf '%s' "$out"
}

# json_fail_flags WHAT -- an enable of WHAT stopped because a node flag it needs is not
# on the node command: one error event per reason (OBS_FLAG_ERROR, which
# lib/observability.sh 1.0.2 fills; a general reason otherwise), then done ok:false
# with what this call applied before, and exit 1. WHAT is not recorded as enabled.
json_fail_flags() {
    local what="$1" reasons="${OBS_FLAG_ERROR:-}" line
    if [[ -z "$reasons" ]]; then
        reasons="A node flag needed for ${what} is not on the node command, and it could not be added (see the server log)."
    fi
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            json_event error "$line"
        fi
    done <<< "$reasons"
    json_done "{\"event\":\"done\",\"ok\":false,\"applied\":[$(json_applied)],\"network\":\"$(json_escape "${NETWORK:-}")\",\"msg\":\"$(json_escape "${what} not enabled: the node launch file needs the change in the error event; run this again once it is made")\"}"
    exit 1
}

# json_need_node WHAT -- an enable puts flags on the node command, so it needs the node
# service's launch file. Without one: error + done ok:false before anything changes.
json_need_node() {
    tn_node_launch_target >/dev/null 2>&1 && return 0
    OBS_FLAG_ERROR="No node service found, so the node flags for ${1} have no launch file to go into. Nothing was changed."
    json_fail_flags "$1"
}

# --- non-interactive toggle actions (mirror the interactive enable_*/disable_*) ---

# json_enable_logs <token> — mirror enable_logging: logs on, preserve metrics opt-in.
# A node flag that could not be added ends the run with error events and done
# ok:false (json_fail_flags); logs are then not recorded as enabled.
json_enable_logs() {
    local token="$1"
    json_need_node "log shipping"
    local meta; meta="$(node_meta_path || true)"
    ENABLE_METRICS="$(meta_get ENABLE_METRICS "$meta" 2>/dev/null || echo false)"
    ENABLE_OBSERVABILITY="true"
    OBS_FLAG_ERROR=""
    if ! obs_enable "$token" addons_say; then
        if [[ -n "${OBS_FLAG_ERROR:-}" ]]; then
            json_fail_flags "log shipping"
        fi
        json_fail "could not enable log shipping (see server logs)"
    fi
    JSON_DID+=("logs:enabled")
}

# json_enable_metrics <token> — mirror enable_metrics: metrics on, preserve logs opt-in.
# Same failure handling as json_enable_logs.
json_enable_metrics() {
    local token="$1"
    json_need_node "metrics shipping"
    local meta; meta="$(node_meta_path || true)"
    ENABLE_OBSERVABILITY="$(meta_get ENABLE_OBSERVABILITY "$meta" 2>/dev/null || echo false)"
    ENABLE_METRICS="true"
    OBS_FLAG_ERROR=""
    if ! obs_enable "$token" addons_say; then
        if [[ -n "${OBS_FLAG_ERROR:-}" ]]; then
            json_fail_flags "metrics shipping"
        fi
        json_fail "could not enable metrics shipping (see server logs)"
    fi
    JSON_DID+=("metrics:enabled")
}

# json_enable_health — mirror enable_health (flag + firewall rule), no prompts. The
# node restart that binds the port is left to the operator, so there is no epoch wait
# here; a warn event says the restart is due. Without a node service, or when
# --healthcheck is not on the node command afterwards, nothing is changed (no ufw rule,
# no .node-meta) and the run ends with error events and done ok:false.
json_enable_health() {
    local target svc method file rc=0
    json_need_node "health monitoring"
    target="$(tn_node_launch_target)"
    read -r svc method file <<< "$target"
    OBS_FLAG_ERROR=""
    health_flag_add "$file" || rc=$?
    if ! health_flag_live "$file"; then
        if [[ -z "${OBS_FLAG_ERROR:-}" ]]; then
            OBS_FLAG_ERROR="--healthcheck ${TN_KUMA_PORT} is not on the node command in ${file}, and it could not be added. Add it by hand: --healthcheck ${TN_KUMA_PORT}"
        fi
        json_fail_flags "health monitoring"
    fi
    if [[ "$rc" -eq 0 ]]; then
        if [[ "$method" == "docker" ]]; then
            systemctl daemon-reload
        fi
        print_ok "Added --healthcheck ${TN_KUMA_PORT} to ${file} (restart ${svc} to bind it)."
        json_event warn "Added --healthcheck ${TN_KUMA_PORT} to ${file}; the health port opens when ${svc} restarts (sudo systemctl restart ${svc})."
    fi
    if ufw_installed && ufw_active; then
        apply_kuma_rule && print_ok "ufw: ${TN_KUMA_SRC} -> ${TN_KUMA_PORT}/tcp (Association monitor only)"
    elif ufw_installed; then
        apply_kuma_rule >/dev/null 2>&1 || true
        print_warn "ufw INACTIVE -- health port ${TN_KUMA_PORT} reachable from the internet once the node restarts."
    else
        print_warn "ufw NOT installed -- health port ${TN_KUMA_PORT} will be exposed once the node restarts."
    fi
    local meta; meta="$(node_meta_path || true)"; [[ -n "$meta" ]] && meta_set ENABLE_HEALTHCHECK_MONITOR true "$meta"
    JSON_DID+=("health:enabled")
}

# json_disable_health — mirror disable_health (drop the ufw rule(s), record off).
json_disable_health() {
    if ufw_installed && ufw_active; then
        ufw delete allow from "${TN_KUMA_SRC}" to any port "${TN_KUMA_PORT}" proto tcp &>/dev/null || true
        local esrc
        for esrc in $(kuma_extra_list); do
            ufw delete allow from "$esrc" to any port "${TN_KUMA_PORT}" proto tcp &>/dev/null || true
        done
        print_ok "Removed the ufw health rule(s) for ${TN_KUMA_PORT}/tcp"
    fi
    local meta; meta="$(node_meta_path || true)"; [[ -n "$meta" ]] && meta_set ENABLE_HEALTHCHECK_MONITOR false "$meta"
    JSON_DID+=("health:disabled")
}

# run_json_mode — bootstrap (root/distro/context/gate) then apply requested toggles.
# Enables need a token (--token or TN_OBS_TOKEN); a missing one is a clear json error.
run_json_mode() {
    json_setup_fds
    trap json_on_exit EXIT
    check_root
    detect_distro
    load_node_context
    require_testnet
    export TN_ASSUME_YES=true   # belt-and-braces: no lib confirm should block

    # In json mode set REGION from --region instead of prompting (mirrors _obs_prompt_region).
    [[ -n "${JSON_REGION:-}" ]] && REGION="$JSON_REGION"

    JSON_DID=()
    local enabling_pipe=false
    [[ "${JSON_ENABLE_LOGS:-false}" == "true" || "${JSON_ENABLE_METRICS:-false}" == "true" ]] && enabling_pipe=true
    if [[ "$enabling_pipe" == "true" || "${JSON_ENABLE_HEALTH:-false}" == "true" ]]; then
        addons_lib_check
    fi

    # Resolve the shared ingest token only when a pipeline is being ENABLED: --token,
    # else TN_OBS_TOKEN, else the token already stored on this node, else fail.
    local token=""
    if [[ "$enabling_pipe" == "true" ]]; then
        token="${JSON_TOKEN:-${TN_OBS_TOKEN:-}}"
        [[ -n "$token" ]] || token="$(obs_existing_token)"
        [[ -n "$token" ]] || json_fail "enabling logs/metrics requires an ingest token (--token or TN_OBS_TOKEN)"
    fi

    # Apply in a deterministic order. Disables first so a same-call enable wins; both
    # pipelines share one obs_enable call path so enabling both renders one config.
    [[ "${JSON_DISABLE_LOGS:-false}" == "true" ]]    && { obs_disable_logs;    JSON_DID+=("logs:disabled"); }
    [[ "${JSON_DISABLE_METRICS:-false}" == "true" ]] && { obs_disable_metrics; JSON_DID+=("metrics:disabled"); }
    [[ "${JSON_DISABLE_HEALTH:-false}" == "true" ]]  && json_disable_health
    [[ "${JSON_ENABLE_LOGS:-false}" == "true" ]]     && json_enable_logs "$token"
    [[ "${JSON_ENABLE_METRICS:-false}" == "true" ]]  && json_enable_metrics "$token"
    [[ "${JSON_ENABLE_HEALTH:-false}" == "true" ]]   && json_enable_health

    if [[ "${#JSON_DID[@]}" -eq 0 ]]; then
        json_fail "no observability action requested (use --enable-logs/--enable-metrics/--enable-health or the --disable-* variants)"
    fi

    # The done summary lists what changed.
    json_done "{\"event\":\"done\",\"ok\":true,\"applied\":[$(json_applied)],\"network\":\"$(json_escape "${NETWORK:-}")\",\"msg\":\"observability updated\"}"
}

main_menu() {
    while true; do
        clear
        print_header "Telcoin Network -- Observability Add-on  v${SCRIPT_VERSION}"
        print_info "Network: ${NETWORK:-unknown}   Install method: ${INSTALL_METHOD:-unknown}"
        echo ""
        echo "  1) Enable log shipping (Alloy -> Loki)"
        echo "  2) Disable log shipping"
        echo "  3) Enable metrics shipping (Alloy -> Prometheus)"
        echo "  4) Disable metrics shipping"
        echo "  5) Enable health monitoring (--healthcheck + firewall rule)"
        echo "  6) Disable health monitoring"
        echo "  7) Show status"
        echo "  8) Exit"
        echo ""
        local choice
        read -r -p "  Enter choice [1-8]: " choice
        case "$choice" in
            1) enable_logging ;;
            2) disable_logging ;;
            3) enable_metrics ;;
            4) disable_metrics ;;
            5) enable_health ;;
            6) disable_health ;;
            7) show_status ;;
            8) echo ""; print_info "Exiting."; exit 0 ;;
            *) print_warn "Please enter 1-8."; sleep 1 ;;
        esac
    done
}

# =============================================================================
# MAIN
#
# Default (no --json): the interactive menu, byte-identical to before. With --json:
# parse the toggle flags and run the non-interactive path. --push-url/--metrics-push-url
# set OBS_PUSH_URL/OBS_METRICS_PUSH_URL so obs ships there (PR1 effective-URL selection).
# =============================================================================
main() {
    local json_mode=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)              json_mode=true; shift ;;
            --enable-logs)       JSON_ENABLE_LOGS=true; shift ;;
            --enable-metrics)    JSON_ENABLE_METRICS=true; shift ;;
            --enable-health)     JSON_ENABLE_HEALTH=true; shift ;;
            --disable-logs)      JSON_DISABLE_LOGS=true; shift ;;
            --disable-metrics)   JSON_DISABLE_METRICS=true; shift ;;
            --disable-health)    JSON_DISABLE_HEALTH=true; shift ;;
            --region)            JSON_REGION="${2:-}"; shift 2 ;;
            --token)             JSON_TOKEN="${2:-}"; shift 2 ;;
            --push-url)          OBS_PUSH_URL="${2:-}"; shift 2 ;;
            --metrics-push-url)  OBS_METRICS_PUSH_URL="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ "$json_mode" == "true" ]]; then
        JSON_MODE=true
        run_json_mode
        exit $?
    fi

    check_root
    detect_distro
    load_node_context
    require_testnet
    main_menu
}

main "$@"
