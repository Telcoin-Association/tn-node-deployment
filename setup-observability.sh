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

readonly SCRIPT_VERSION="1.2.0"

pause() { echo ""; read -r -p "  Press Enter to return to menu..."; }

# Load NETWORK + node context from .node-meta so require_testnet can gate.
load_node_context() {
    local meta
    meta="$(node_meta_path || true)"
    if [[ -z "$meta" ]]; then
        print_error "No Telcoin node detected (no /etc/telcoin/{validator,observer}/.node-meta)."
        print_info  "Run setup-validator.sh or setup-observer.sh first."
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
    echo ""
    # Turn logs on; preserve any existing metrics opt-in so obs_enable renders both.
    local meta; meta="$(node_meta_path || true)"
    ENABLE_METRICS="$(meta_get ENABLE_METRICS "$meta" 2>/dev/null || echo false)"
    ENABLE_OBSERVABILITY="true"
    _obs_prompt_region
    if _obs_collect_token; then
        if obs_enable "$_OBS_TOKEN"; then print_ok "Log shipping enabled."; else print_error "Could not enable logging (see messages above)."; fi
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
    echo ""
    # Turn metrics on; preserve any existing logs opt-in so obs_enable renders both.
    local meta; meta="$(node_meta_path || true)"
    ENABLE_OBSERVABILITY="$(meta_get ENABLE_OBSERVABILITY "$meta" 2>/dev/null || echo false)"
    ENABLE_METRICS="true"
    _obs_prompt_region
    if _obs_collect_token; then
        if obs_enable "$_OBS_TOKEN"; then print_ok "Metrics shipping enabled."; else print_error "Could not enable metrics (see messages above)."; fi
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
    echo ""
    local target svc method file
    if target="$(tn_node_launch_target)"; then
        read -r svc method file <<< "$target"
        if tn_node_inject_flags "$file" "--healthcheck" "--healthcheck ${TN_KUMA_PORT}"; then
            [[ "$method" == "docker" ]] && systemctl daemon-reload
            print_ok "Added --healthcheck ${TN_KUMA_PORT} to ${file}"
            print_warn "The node must restart for the health endpoint to bind."
            if confirm "Restart ${svc} now?"; then
                systemctl restart "$svc" && print_ok "${svc} restarted." || print_warn "Restart manually: sudo systemctl restart ${svc}"
            else
                print_info "Restart later: sudo systemctl restart ${svc}"
            fi
        else
            print_ok "Node already has --healthcheck (or the launch line was not found)."
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
    local meta; meta="$(node_meta_path || true)"; [[ -n "$meta" ]] && meta_set ENABLE_HEALTHCHECK_MONITOR true "$meta"
    print_info "Verify once running: curl -s http://127.0.0.1:${TN_KUMA_PORT}  (expect OK)"
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

check_root
detect_distro
load_node_context
require_testnet
main_menu
