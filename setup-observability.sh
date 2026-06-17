#!/usr/bin/env bash
# =============================================================================
# setup-observability.sh -- Telcoin testnet add-on: centralized logging + health
#
# Opt-in, testnet-only. Enable/disable shipping this node's logs to the Telcoin
# Association's central Loki (via Grafana Alloy), and enable/disable the health-
# monitor endpoint. Re-runnable at any time. The obs ingest token is pasted here
# (hidden) and stored ONLY in the mode-600 Alloy env file -- never in git/.node-meta.
#
# USAGE:
#   sudo bash setup-observability.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

readonly SCRIPT_VERSION="1.0.0"

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

enable_logging() {
    print_header "Enable centralized logging"
    print_info "Ships this node's logs to the Telcoin Association's Loki:"
    print_info "  ${OBS_PUSH_URL_TESTNET}"
    print_info "You need a per-operator ingest token from the Association (docs/testnet-addons.md)."
    echo ""
    local region_in
    read -r -p "  Region label for your node (e.g. us-east, eu-west) [${REGION:-unknown}]: " region_in
    REGION="${region_in:-${REGION:-unknown}}"
    local token=""
    print_info "Paste the obs ingest token (input hidden):"
    read -r -s -p "  Token: " token; echo ""
    if [[ -z "$token" ]]; then
        print_warn "No token entered -- aborting."
        pause; return
    fi
    if obs_enable "$token"; then
        print_ok "Centralized logging enabled."
    else
        print_error "Could not enable logging (see messages above)."
    fi
    pause
}

disable_logging() {
    print_header "Disable centralized logging"
    if confirm "Stop shipping logs and disable the Alloy unit?"; then
        obs_disable
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
    else
        print_info "ufw not active -- run firewall-setup.sh to source-restrict ${TN_KUMA_PORT}/tcp."
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
        echo "  1) Enable centralized logging (Alloy -> Loki)"
        echo "  2) Disable centralized logging"
        echo "  3) Enable health monitoring (--healthcheck + firewall rule)"
        echo "  4) Disable health monitoring"
        echo "  5) Show status"
        echo "  6) Exit"
        echo ""
        local choice
        read -r -p "  Enter choice [1-6]: " choice
        case "$choice" in
            1) enable_logging ;;
            2) disable_logging ;;
            3) enable_health ;;
            4) disable_health ;;
            5) show_status ;;
            6) echo ""; print_info "Exiting."; exit 0 ;;
            *) print_warn "Please enter 1-6."; sleep 1 ;;
        esac
    done
}

check_root
detect_distro
load_node_context
require_testnet
main_menu
