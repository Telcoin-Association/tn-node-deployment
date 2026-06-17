#!/usr/bin/env bash
# =============================================================================
# firewall-setup.sh -- Telcoin Network Server Firewall Setup
#
# Interactive firewall management and hardening for Telcoin Network nodes.
# Can be run at any time to view current status or apply changes.
#
# USAGE:
#   sudo bash firewall-setup.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

readonly SCRIPT_VERSION="1.4.0"
readonly SSH_CONFIG="/etc/ssh/sshd_config"

# Ports required for a fully working Telcoin node deployment.
# 43174/tcp is the Uptime Kuma health-monitoring endpoint used by the
# Telcoin Association across all nodes (observer AND validator).
# UDP 49590/49594 are validator-only (P2P consensus).
readonly UPTIME_KUMA_PORT="43174"

# =============================================================================
# HELPERS
# =============================================================================

# NOTE: get_ssh_port, ufw_active, ufw_has_allow and ufw_installed now live in
# lib/common.sh (COMMON_VERSION >= 1.2.0) so the standalone add-on scripts
# (setup-vpn.sh, setup-observability.sh) share one implementation. They are
# available here via the `source lib/common.sh` above.

# kuma_rule_state — classify the health-port (UPTIME_KUMA_PORT) ufw rule:
#   restricted  allowed only from specific source(s) (e.g. the Association monitor)
#   anywhere    open to any source IP
#   closed      no allow rule present
kuma_rule_state() {
    local allow
    # Only ALLOW rules count -- a lone DENY on the port means "closed" (blocked), not restricted.
    allow="$(ufw status 2>/dev/null | grep -E "^${UPTIME_KUMA_PORT}/tcp[[:space:]]" | grep -iE "[[:space:]]ALLOW[[:space:]]" || true)"
    [[ -n "$allow" ]] || { echo "closed"; return 0; }
    if echo "$allow" | grep -qiE "ALLOW[[:space:]]+Anywhere"; then
        echo "anywhere"
    else
        echo "restricted"
    fi
}

# kuma_restricted_desc — human description of the "restricted" health-port state. Notes
# any operator-chosen sources (kuma_extra_list) layered on top of the TA baseline so the
# status line stays accurate once the operator adds their own monitors.
kuma_restricted_desc() {
    local extras
    extras="$(kuma_extra_list)"
    if [[ -n "$extras" ]]; then
        local -a arr=($extras)
        printf 'restricted to TA (%s) + %d additional: %s' "${TN_KUMA_SRC}" "${#arr[@]}" "$extras"
    else
        printf 'open to the Association monitor only (%s)' "${TN_KUMA_SRC}"
    fi
}

# kuma_offer_anywhere_cleanup — if an open-to-Anywhere rule for the health port still
# exists it shadows the source restriction (ufw evaluates the broadest allow), so list
# the port's rules and offer to delete the offending one by number. No-op otherwise.
kuma_offer_anywhere_cleanup() {
    ufw status 2>/dev/null | grep -E "^${UPTIME_KUMA_PORT}/tcp[[:space:]]" | grep -qiE "ALLOW[[:space:]]+Anywhere" || return 0
    echo ""
    print_warn "An open-to-Anywhere rule for ${UPTIME_KUMA_PORT}/tcp still exists and overrides the restriction."
    print_info "Current ${UPTIME_KUMA_PORT}/tcp rules:"
    ufw status numbered 2>/dev/null | grep -E "${UPTIME_KUMA_PORT}/tcp" | while IFS= read -r line; do print_info "$line"; done
    local rnum
    read -r -p "  Enter the rule NUMBER of the Anywhere rule to delete (blank = skip): " rnum
    if [[ "$rnum" =~ ^[0-9]+$ ]]; then
        if confirm "Delete ufw rule ${rnum}?"; then
            ufw --force delete "$rnum" &>/dev/null
            print_ok "Rule ${rnum} removed (re-check numbers if there is also a (v6) duplicate)"
        fi
    fi
}

get_ssh_password_auth() {
    grep -E "^PasswordAuthentication " "$SSH_CONFIG" 2>/dev/null | awk '{print $2}' || echo "yes"
}

get_ssh_root_login() {
    grep -E "^PermitRootLogin " "$SSH_CONFIG" 2>/dev/null | awk '{print $2}' || echo "yes"
}

get_current_ip() {
    local ssh_client="${SSH_CLIENT:-}"
    echo "${ssh_client%% *}"
}

detect_installed_nodes() {
    local nodes=""
    [[ -f /etc/systemd/system/telcoin-observer.service ]]  && nodes="${nodes}observer "
    [[ -f /etc/systemd/system/telcoin-validator.service ]] && nodes="${nodes}validator "
    echo "${nodes:-none}"
}

# =============================================================================
# VIEW CURRENT STATUS
# =============================================================================

view_status() {
    print_header "Current Firewall Status"

    # UFW status
    print_step "Firewall (ufw)..."
    if ! ufw_installed; then
        print_warn "ufw is not installed"
    elif ufw_active; then
        print_ok "Firewall is active"
        local default_in
        default_in=$(ufw status verbose 2>/dev/null | grep "Default:" | grep -o "incoming: [a-z]*" | awk '{print $2}')
        if [[ "$default_in" == "deny" ]]; then
            print_ok "Default inbound policy: deny (recommended)"
        else
            print_warn "Default inbound policy: ${default_in} (recommend: deny)"
        fi
    else
        print_warn "Firewall is installed but NOT active"
    fi

    # Current rules
    echo ""
    print_step "Current firewall rules..."
    if ufw_active; then
        ufw status numbered 2>/dev/null | grep -v "^Status\|^To\|^--" | grep -v "^$" | \
            while IFS= read -r line; do
                print_info "$line"
            done
    else
        print_info "No active rules (firewall not enabled)"
    fi

    # SSH status
    echo ""
    print_step "SSH configuration..."
    local ssh_port password_auth root_login
    ssh_port=$(get_ssh_port)
    password_auth=$(get_ssh_password_auth)
    root_login=$(get_ssh_root_login)

    printf "  %-30s %s\n" "SSH port:" "$ssh_port"

    if [[ "$password_auth" == "no" ]]; then
        print_ok "Password authentication: disabled (keys only)"
    else
        print_warn "Password authentication: enabled (recommend: disable)"
    fi

    if [[ "$root_login" == "no" ]]; then
        print_ok "Root login: disabled"
    else
        print_warn "Root login: ${root_login} (recommend: disable)"
    fi

    # Check if SSH is open to world
    if ufw_active; then
        if ufw status 2>/dev/null | grep -q "${ssh_port}.*ALLOW.*Anywhere"; then
            print_warn "SSH (port ${ssh_port}) is open to the entire internet"
            print_info "Consider whitelisting specific IPs only"
        else
            print_ok "SSH access appears to be restricted"
        fi
    fi

    # Node ports
    echo ""
    print_step "Node ports..."
    local nodes
    nodes=$(detect_installed_nodes)

    if [[ "$nodes" == "none" ]]; then
        print_info "No Telcoin nodes detected on this server"
    else
        print_info "Installed nodes: ${nodes}"
        echo ""

        if echo "$nodes" | grep -q "observer"; then
            print_info "Observer node -- no inbound P2P ports required"
            if ufw_active && (ufw_has_allow 49590 udp || ufw_has_allow 49594 udp); then
                print_warn "UDP 49590/49594 appear open inbound -- not required for observer"
            elif ufw_active; then
                print_ok "No unnecessary inbound P2P ports open for observer"
            fi
        fi

        if echo "$nodes" | grep -q "validator"; then
            print_info "Validator node -- UDP 49590/49594 required inbound for P2P consensus"
            if ufw_active; then
                if ufw_has_allow 49590 udp; then
                    print_ok "UDP 49590 is open"
                else
                    print_error "UDP 49590 is CLOSED -- validator will not reach consensus"
                fi
                if ufw_has_allow 49594 udp; then
                    print_ok "UDP 49594 is open"
                else
                    print_error "UDP 49594 is CLOSED -- validator will not reach consensus"
                fi
            fi
        fi

        # Uptime Kuma is required across all node types (Telcoin Association
        # health monitoring runs against every deployed node).
        echo ""
        print_info "Uptime Kuma health monitoring -- TCP ${UPTIME_KUMA_PORT}"
        if ufw_active; then
            case "$(kuma_rule_state)" in
                restricted) print_ok    "TCP ${UPTIME_KUMA_PORT} $(kuma_restricted_desc)" ;;
                anywhere)   print_warn  "TCP ${UPTIME_KUMA_PORT} open to Anywhere -- consider restricting to ${TN_KUMA_SRC} (menu: Manage node ports)" ;;
                closed)     print_error "TCP ${UPTIME_KUMA_PORT} is CLOSED -- health monitoring will fail" ;;
            esac
        fi
    fi

    # Current session IP
    echo ""
    local current_ip
    current_ip=$(get_current_ip)
    if [[ -n "$current_ip" ]]; then
        print_info "Your current session IP: ${current_ip}"
        print_info "Make sure this IP is whitelisted before restricting SSH access"
    fi

    echo ""
    read -r -p "  Press Enter to return to menu..."
}

# =============================================================================
# ENABLE FIREWALL WITH RECOMMENDED DEFAULTS
# =============================================================================

enable_firewall() {
    print_header "Enable Firewall with Recommended Defaults"

    if ! ufw_installed; then
        print_step "Installing ufw..."
        apt-get install -y ufw &>/dev/null
        print_ok "ufw installed"
    fi

    local ssh_port nodes
    ssh_port=$(get_ssh_port)
    nodes=$(detect_installed_nodes)

    echo ""
    print_info "This will apply the following settings:"
    echo "  - Default inbound policy: DENY"
    echo "  - Default outbound policy: ALLOW"
    echo "  - Allow established connections"
    echo "  - Allow SSH on port ${ssh_port}"
    echo "  - Allow TCP ${UPTIME_KUMA_PORT} (Uptime Kuma) from the Association monitor only (${TN_KUMA_SRC})"
    if echo "$nodes" | grep -q "validator"; then
        echo "  - Allow UDP 49590 and 49594 (validator P2P -- required)"
    fi
    if [[ "$nodes" == "none" ]]; then
        echo ""
        print_info "No Telcoin node installed yet. Re-run this option after running"
        print_info "setup-validator.sh to also open the validator P2P ports."
    fi
    echo ""
    print_warn "Ensure your SSH access IP is whitelisted (option 5) before enabling"
    print_warn "or you may lose access to this server."
    echo ""

    local current_ip
    current_ip=$(get_current_ip)
    if [[ -n "$current_ip" ]]; then
        print_info "Your current session IP is: ${current_ip}"
        print_info "Add it to the whitelist first if you haven't already."
        echo ""
    fi

    if ! confirm "Apply recommended firewall defaults?"; then
        print_info "Cancelled -- no changes made."
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi

    ufw --force reset &>/dev/null
    ufw default deny incoming &>/dev/null
    ufw default allow outgoing &>/dev/null
    ufw allow "${ssh_port}/tcp" &>/dev/null
    # Source-restrict the health port to the Association uptime monitor (the only
    # legitimate prober) rather than opening it to the whole internet.
    apply_kuma_rule &>/dev/null
    # Keep the VPN overlay reachable if admin SSH is active, so a firewall reset does not
    # sever the Association's recovery path (the operator's own SSH stays open above).
    if vpn_active; then allow_overlay_ssh &>/dev/null; fi
    if echo "$nodes" | grep -q "validator"; then
        ufw allow 49590/udp &>/dev/null
        ufw allow 49594/udp &>/dev/null
    fi
    ufw --force enable &>/dev/null

    print_ok "Firewall enabled with recommended defaults"
    print_ok "SSH port ${ssh_port}/tcp allowed"
    print_ok "Uptime Kuma port ${UPTIME_KUMA_PORT}/tcp allowed from ${TN_KUMA_SRC} (Association monitor)"
    if echo "$nodes" | grep -q "validator"; then
        print_ok "Validator P2P UDP 49590 and 49594 allowed"
    fi
    print_warn "Test your SSH connection in a new terminal before closing this one"
    echo ""
    read -r -p "  Press Enter to return to menu..."
}

# =============================================================================
# MANAGE SSH ACCESS
# =============================================================================

manage_ssh() {
    print_header "Manage SSH Access"

    local ssh_port password_auth root_login
    ssh_port=$(get_ssh_port)
    password_auth=$(get_ssh_password_auth)
    root_login=$(get_ssh_root_login)

    echo "  Current SSH configuration:"
    printf "  %-30s %s\n" "Port:" "$ssh_port"
    printf "  %-30s %s\n" "Password authentication:" "$password_auth"
    printf "  %-30s %s\n" "Root login:" "$root_login"
    echo ""
    echo "  1) Disable password authentication (keys only)"
    echo "  2) Disable root login"
    echo "  3) Change SSH port"
    echo "  4) Back to main menu"
    echo ""

    local choice
    read -r -p "  Enter choice [1-4]: " choice
    case "$choice" in
        1)
            if [[ "$password_auth" == "no" ]]; then
                print_ok "Password authentication is already disabled"
            else
                echo ""
                print_warn "Ensure you have SSH key access before disabling passwords"
                print_warn "You will be locked out if you only use password login"
                echo ""
                if confirm "Disable password authentication?"; then
                    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
                    systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null
                    print_ok "Password authentication disabled"
                else
                    print_info "Cancelled -- no changes made"
                fi
            fi
            ;;
        2)
            if [[ "$root_login" == "no" ]]; then
                print_ok "Root login is already disabled"
            else
                if confirm "Disable root login via SSH?"; then
                    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "$SSH_CONFIG"
                    systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null
                    print_ok "Root login disabled"
                else
                    print_info "Cancelled -- no changes made"
                fi
            fi
            ;;
        3)
            echo ""
            print_warn "Changing SSH port requires updating your firewall rules"
            print_warn "and reconnecting on the new port. Do not close this session"
            print_warn "until you have confirmed access on the new port."
            echo ""
            local new_port
            read -r -p "  New SSH port (current: ${ssh_port}): " new_port
            if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1 || new_port > 65535 )); then
                print_warn "Invalid port number"
                echo ""
                read -r -p "  Press Enter to return to menu..."
                return
            fi
            if [[ "$new_port" == "$ssh_port" ]]; then
                print_info "Already on port ${new_port}; nothing to do."
                echo ""
                read -r -p "  Press Enter to return to menu..."
                return
            fi
            if ! confirm "Change SSH port to ${new_port}?"; then
                print_info "Cancelled -- no changes made"
                echo ""
                read -r -p "  Press Enter to return to menu..."
                return
            fi

            # Atomic transition:
            #   1. Back up sshd_config.
            #   2. Make sshd listen on BOTH old and new ports.
            #   3. Open new port in ufw.
            #   4. Operator confirms a new SSH session works on the new port.
            #   5. Only then remove the old Port directive and old ufw rule.
            # If the operator cannot confirm we roll back to the original state.
            local ts backup
            ts=$(date -u '+%Y%m%d-%H%M%S')
            backup="${SSH_CONFIG}.bak.${ts}"
            if ! cp -p "$SSH_CONFIG" "$backup"; then
                print_error "Could not back up ${SSH_CONFIG}. Aborting."
                echo ""
                read -r -p "  Press Enter to return to menu..."
                return
            fi
            print_info "Backup written: ${backup}"

            # Add new Port directive (without removing the old one). Append
            # rather than replace so both ports listen during the transition.
            printf '\nPort %s\n' "$new_port" >> "$SSH_CONFIG"

            if ufw_active; then
                ufw allow "${new_port}/tcp" &>/dev/null
                print_ok "ufw: allowed ${new_port}/tcp"
            fi

            if ! systemctl reload sshd 2>/dev/null && ! service ssh reload 2>/dev/null; then
                print_error "sshd reload failed -- rolling back."
                cp -p "$backup" "$SSH_CONFIG"
                ufw_active && ufw delete allow "${new_port}/tcp" &>/dev/null
                echo ""
                read -r -p "  Press Enter to return to menu..."
                return
            fi
            print_ok "sshd now listening on BOTH port ${ssh_port} and port ${new_port}"

            echo ""
            print_warn "================================================================"
            print_warn "  ACTION REQUIRED -- TEST THE NEW PORT FROM A SECOND TERMINAL"
            print_warn "================================================================"
            print_info "Open a NEW terminal on your local machine and run:"
            print_info "    ssh -p ${new_port} <user>@<this-server>"
            print_info ""
            print_info "Only confirm CONFIRMED once that NEW session is logged in."
            print_info "If you cannot connect, type anything else to roll back."
            print_warn "================================================================"
            echo ""

            local confirm_text
            read -r -p "  Type CONFIRMED to finalise the port change: " confirm_text
            if [[ "$confirm_text" != "CONFIRMED" ]]; then
                print_warn "Rolling back to original sshd configuration..."
                cp -p "$backup" "$SSH_CONFIG"
                ufw_active && ufw delete allow "${new_port}/tcp" &>/dev/null
                systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null
                print_ok "Reverted. SSH still listening on port ${ssh_port} only."
                echo ""
                read -r -p "  Press Enter to return to menu..."
                return
            fi

            # Finalise: remove old Port directive(s) and old ufw rule.
            # Use a tmp file to safely remove the original Port lines while
            # keeping the appended new one.
            local tmp
            tmp=$(mktemp)
            awk -v keep="$new_port" '
                /^[[:space:]]*Port[[:space:]]/ {
                    n=$2
                    if (n == keep) { print; next } else { next }
                }
                { print }
            ' "$SSH_CONFIG" > "$tmp"
            mv "$tmp" "$SSH_CONFIG"
            chmod --reference="$backup" "$SSH_CONFIG" 2>/dev/null || chmod 644 "$SSH_CONFIG"

            if ufw_active; then
                ufw delete allow "${ssh_port}/tcp" &>/dev/null
                print_ok "ufw: removed allow rule for old port ${ssh_port}/tcp"
            fi
            systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null
            print_ok "SSH port changed to ${new_port} (old port ${ssh_port} closed)"
            ;;
        4) return ;;
        *) print_warn "Invalid choice" ;;
    esac

    echo ""
    read -r -p "  Press Enter to return to menu..."
}

# =============================================================================
# MANAGE NODE PORTS
# =============================================================================

manage_node_ports() {
    print_header "Manage Node Ports"

    local nodes
    nodes=$(detect_installed_nodes)

    if [[ "$nodes" == "none" ]]; then
        print_warn "No Telcoin nodes detected on this server"
        print_info "Run setup-observer.sh or setup-validator.sh first"
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi

    if ! ufw_installed || ! ufw_active; then
        print_warn "Firewall is not active -- enable it first (option 2)"
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi

    print_info "Detected nodes: ${nodes}"
    echo ""

    if echo "$nodes" | grep -q "validator"; then
        echo "  Validator node requires UDP ports 49590 and 49594 open inbound."
        echo ""
        if confirm "Open UDP ports 49590 and 49594 for validator P2P?"; then
            ufw allow 49590/udp &>/dev/null
            ufw allow 49594/udp &>/dev/null
            print_ok "UDP ports 49590 and 49594 opened"
        fi
        echo ""
    fi

    if echo "$nodes" | grep -q "observer"; then
        print_info "Observer nodes do not require inbound P2P ports."
        print_info "P2P connections are outbound only."

        if ufw_has_allow 49590 udp || ufw_has_allow 49594 udp; then
            echo ""
            if confirm "Close inbound UDP 49590/49594 (not needed for observer)?"; then
                ufw delete allow 49590/udp &>/dev/null
                ufw delete allow 49594/udp &>/dev/null
                print_ok "Inbound P2P UDP ports closed"
            fi
        fi
    fi

    echo ""
    print_info "Uptime Kuma health monitoring -- TCP ${UPTIME_KUMA_PORT}."
    print_info "The Telcoin Association uptime monitor probes this port to confirm your node is up."
    local kstate; kstate="$(kuma_rule_state)"
    case "$kstate" in
        restricted) print_ok   "TCP ${UPTIME_KUMA_PORT} is $(kuma_restricted_desc)" ;;
        anywhere)   print_warn "TCP ${UPTIME_KUMA_PORT} is open to ANYWHERE (any host can probe it)" ;;
        closed)     print_info "TCP ${UPTIME_KUMA_PORT} is currently closed" ;;
    esac
    echo ""
    echo "  How should the health port be reachable?"
    echo "    1) Association monitor only        -- from ${TN_KUMA_SRC}  [recommended]"
    echo "    2) Association monitor + your IPs  -- TA plus a list you manage"
    echo "    3) Open to anyone                  -- any source IP"
    echo "    4) Leave as-is"
    echo ""
    local kchoice
    read -r -p "  Enter choice [1-4]: " kchoice
    case "$kchoice" in
        1)
            apply_kuma_rule &>/dev/null
            print_ok "TCP ${UPTIME_KUMA_PORT} restricted to ${TN_KUMA_SRC}"
            # An open-to-Anywhere rule, if present, shadows the restriction -- offer to delete it.
            kuma_offer_anywhere_cleanup
            ;;
        2)
            # TA stays the always-on baseline; operator-chosen sources layer on top and
            # are persisted so they survive a `ufw --force reset` (see apply_kuma_rule).
            apply_kuma_rule &>/dev/null
            print_ok "TCP ${UPTIME_KUMA_PORT} restricted to ${TN_KUMA_SRC} (Association baseline)"
            manage_health_extra_ips
            # A lingering open-to-Anywhere rule would still override the restriction.
            kuma_offer_anywhere_cleanup
            ;;
        3)
            ufw allow "${UPTIME_KUMA_PORT}/tcp" &>/dev/null
            print_ok "TCP ${UPTIME_KUMA_PORT} opened to anyone"
            print_info "Any persisted operator sources become redundant (but stay harmless)."
            ;;
        *)
            print_info "Left ${UPTIME_KUMA_PORT}/tcp as-is."
            ;;
    esac

    echo ""
    print_info "Public RPC (nginx on port 443) -- optional, only if you serve public RPC:"
    if ufw_has_allow 443 tcp; then
        print_ok "TCP 443 is already open"
    else
        if confirm "Open TCP 443 for public RPC via nginx?"; then
            ufw allow 443/tcp &>/dev/null
            print_ok "TCP 443 opened"
            print_info "Configure nginx to proxy to your RPC port"
        fi
    fi

    echo ""
    read -r -p "  Press Enter to return to menu..."
}

# manage_health_extra_ips -- add/remove operator-chosen sources for the health port.
# The Association monitor stays the always-on baseline (apply_kuma_rule); these layer on
# top and are persisted in .node-meta (KUMA_EXTRA_SRC), so they survive the ufw reset
# that "Enable recommended defaults" performs. Modeled on manage_whitelist.
manage_health_extra_ips() {
    while true; do
        echo ""
        print_step "Additional health-port (${UPTIME_KUMA_PORT}/tcp) sources"
        local extras; extras="$(kuma_extra_list)"
        if [[ -n "$extras" ]]; then
            print_info "Allowed in addition to the Association monitor (${TN_KUMA_SRC}):"
            local s
            for s in $extras; do print_info "  - ${s}"; done
        else
            print_info "No additional sources yet -- only the Association monitor (${TN_KUMA_SRC}) can probe."
        fi
        echo ""
        echo "  1) Add an IP / CIDR"
        echo "  2) Remove an IP / CIDR"
        echo "  3) Done"
        echo ""
        local c; read -r -p "  Enter choice [1-3]: " c
        case "$c" in
            1)
                echo ""
                local current_ip; current_ip="$(get_current_ip)"
                [[ -n "$current_ip" ]] && print_info "Your current session IP: ${current_ip}"
                print_info "Accepts a single IPv4, IPv6, or CIDR (e.g. 203.0.113.5 or 203.0.113.0/24)."
                local new_src
                read -r -p "  Enter IP/CIDR to allow on ${UPTIME_KUMA_PORT}/tcp: " new_src
                if [[ -z "$new_src" ]]; then
                    print_warn "No input -- nothing added."
                elif kuma_extra_add "$new_src"; then
                    print_ok "Allowed ${new_src} -> ${UPTIME_KUMA_PORT}/tcp (persisted)"
                else
                    print_warn "Invalid IP/CIDR: ${new_src} -- not added."
                fi
                ;;
            2)
                local extras2; extras2="$(kuma_extra_list)"
                if [[ -z "$extras2" ]]; then
                    print_info "No additional sources to remove."
                else
                    echo ""
                    local del_src
                    read -r -p "  Enter the exact IP/CIDR to remove: " del_src
                    if [[ -n "$del_src" ]] && printf '%s\n' $extras2 | grep -qxF "$del_src"; then
                        kuma_extra_remove "$del_src"
                        print_ok "Removed ${del_src} from ${UPTIME_KUMA_PORT}/tcp"
                    else
                        print_warn "Not in the list: ${del_src}"
                    fi
                fi
                ;;
            3) return ;;
            *) print_warn "Invalid choice" ;;
        esac
    done
}

# =============================================================================
# MANAGE TRUSTED IP WHITELIST
# =============================================================================

manage_whitelist() {
    print_header "Manage Trusted IP Whitelist"

    if ! ufw_installed || ! ufw_active; then
        print_warn "Firewall is not active -- enable it first (option 2)"
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi

    local ssh_port
    ssh_port=$(get_ssh_port)

    echo "  Current SSH whitelist entries:"
    echo ""
    local entries
    entries=$(ufw status numbered 2>/dev/null | grep "${ssh_port}" | grep -v "Anywhere on")
    if [[ -z "$entries" ]]; then
        print_info "No specific IP whitelist entries for SSH (port ${ssh_port})"
        print_info "SSH is either open to all or blocked"
    else
        echo "$entries" | while IFS= read -r line; do
            print_info "$line"
        done
    fi

    echo ""
    echo "  1) Add trusted IP for SSH access"
    echo "  2) Remove a whitelist entry"
    echo "  3) Show all firewall rules"
    echo "  4) Back to main menu"
    echo ""

    local choice
    read -r -p "  Enter choice [1-4]: " choice
    case "$choice" in
        1)
            echo ""
            local current_ip
            current_ip=$(get_current_ip)
            [[ -n "$current_ip" ]] && print_info "Your current session IP: ${current_ip}"
            echo ""
            read -r -p "  Enter IP address or CIDR range to whitelist: " new_ip
            if [[ -n "$new_ip" ]]; then
                if confirm "Allow SSH access from ${new_ip}?"; then
                    ufw allow from "$new_ip" to any port "$ssh_port" proto tcp &>/dev/null
                    print_ok "Whitelisted: ${new_ip} -> SSH port ${ssh_port}"
                    # If the VPN overlay is active, keep it allowed so restricting SSH to
                    # specific IPs doesn't lock out the Association's admin access.
                    if vpn_active && ! ufw status 2>/dev/null | grep -q "${TN_OVERLAY_CIDR}"; then
                        if allow_overlay_ssh &>/dev/null; then
                            print_info "Kept overlay SSH (${TN_OVERLAY_CIDR}) so VPN admin access survives the whitelist."
                        fi
                    fi
                fi
            else
                print_warn "No IP entered"
            fi
            ;;
        2)
            echo ""
            print_info "Current rules (with numbers):"
            ufw status numbered 2>/dev/null | while IFS= read -r line; do
                print_info "$line"
            done
            echo ""
            local rule_num
            read -r -p "  Enter rule number to remove: " rule_num
            if [[ "$rule_num" =~ ^[0-9]+$ ]]; then
                print_warn "Removing rule ${rule_num}. Ensure you won't lose SSH access."
                # Extra guard: removing the overlay rule while VPN is active cuts off the
                # Telcoin Association's admin path -- call it out explicitly first.
                local rule_line
                rule_line="$(ufw status numbered 2>/dev/null | grep -E "^\[ *${rule_num}\]" || true)"
                if vpn_active && printf '%s' "$rule_line" | grep -q "${TN_OVERLAY_CIDR}"; then
                    print_warn "Rule ${rule_num} is the WireGuard overlay (${TN_OVERLAY_CIDR})."
                    print_warn "Removing it cuts off the Telcoin Association's VPN admin access to this node."
                fi
                if confirm "Remove rule ${rule_num}?"; then
                    ufw --force delete "$rule_num" &>/dev/null
                    print_ok "Rule ${rule_num} removed"
                fi
            else
                print_warn "Invalid rule number"
            fi
            ;;
        3)
            echo ""
            ufw status verbose 2>/dev/null | while IFS= read -r line; do
                print_info "$line"
            done
            ;;
        4) return ;;
        *) print_warn "Invalid choice" ;;
    esac

    echo ""
    read -r -p "  Press Enter to return to menu..."
}

# =============================================================================
# MAIN MENU
# =============================================================================

# vpn_active -- the WireGuard overlay is configured on this node (wg0 exists, or
# .node-meta records ENABLE_VPN=true). Used to keep overlay SSH from being locked out.
vpn_active() {
    ip link show wg0 >/dev/null 2>&1 && return 0
    local meta; meta="$(node_meta_path 2>/dev/null || true)"
    [[ -n "$meta" ]] && [[ "$(meta_get ENABLE_VPN "$meta" 2>/dev/null || echo false)" == "true" ]]
}

# fw_is_testnet -- this host runs a testnet node (gates the add-on menu item).
fw_is_testnet() {
    local meta; meta="$(node_meta_path 2>/dev/null || true)"
    [[ -n "$meta" ]] || return 1
    [[ "$(meta_get NETWORK "$meta" 2>/dev/null || true)" == "testnet" ]]
}

# manage_addon_rules -- testnet add-on firewall rules: overlay SSH + Kuma health port.
manage_addon_rules() {
    print_header "Manage testnet add-on firewall rules"
    if ! ufw_installed || ! ufw_active; then
        print_warn "Firewall is not active -- enable it first (option 2)."
        echo ""; read -r -p "  Press Enter to return to menu..."; return
    fi
    local ssh_port; ssh_port="$(get_ssh_port)"

    print_step "Current add-on rule status"
    case "$(kuma_rule_state)" in
        restricted) print_ok   "Health ${UPTIME_KUMA_PORT}/tcp: $(kuma_restricted_desc)" ;;
        anywhere)   print_warn "Health ${UPTIME_KUMA_PORT}/tcp: open to Anywhere" ;;
        closed)     print_info "Health ${UPTIME_KUMA_PORT}/tcp: closed" ;;
    esac
    if ufw status 2>/dev/null | grep -q "${TN_OVERLAY_CIDR}"; then
        print_ok "Overlay SSH: allowed from ${TN_OVERLAY_CIDR}"
    else
        print_info "Overlay SSH: not allowed"
        vpn_active && print_warn "VPN is active but overlay SSH is missing -- option 1 restores core-team access."
    fi
    echo ""
    echo "  1) Allow SSH from the WireGuard overlay (${TN_OVERLAY_CIDR})"
    echo "  2) Restrict health port ${UPTIME_KUMA_PORT}/tcp to the Association monitor (${TN_KUMA_SRC})"
    echo "  3) Remove the overlay SSH allowance"
    echo "  4) Back"
    echo ""
    print_info "To allow your OWN monitoring hosts on ${UPTIME_KUMA_PORT}/tcp, use main menu -> Manage node ports."
    echo ""
    local c; read -r -p "  Enter choice [1-4]: " c
    case "$c" in
        1) allow_overlay_ssh &>/dev/null && print_ok "Allowed SSH from ${TN_OVERLAY_CIDR}" ;;
        2) apply_kuma_rule  &>/dev/null && print_ok "Restricted ${UPTIME_KUMA_PORT}/tcp to ${TN_KUMA_SRC}" ;;
        3)
            vpn_active && print_warn "VPN is active -- removing overlay SSH cuts off Association admin access."
            if confirm "Remove the overlay SSH allowance (${TN_OVERLAY_CIDR} -> ${ssh_port})?"; then
                ufw delete allow from "${TN_OVERLAY_CIDR}" to any port "${ssh_port}" proto tcp &>/dev/null \
                    && print_ok "Removed" || print_warn "No matching rule found"
            fi
            ;;
        4) return ;;
        *) print_warn "Invalid choice" ;;
    esac
    echo ""; read -r -p "  Press Enter to return to menu..."
}

main_menu() {
    while true; do
        clear
        print_header "Telcoin Network -- Server Firewall Setup  v${SCRIPT_VERSION}"

        # Quick status summary at top of menu
        if ufw_active; then
            print_ok "Firewall: active"
        else
            print_warn "Firewall: inactive"
        fi

        local ssh_port
        ssh_port=$(get_ssh_port)
        if ufw_active && ufw status 2>/dev/null | grep -q "${ssh_port}.*ALLOW.*Anywhere"; then
            print_warn "SSH (port ${ssh_port}): open to internet"
        elif ufw_active; then
            print_ok "SSH (port ${ssh_port}): restricted"
        else
            print_info "SSH (port ${ssh_port}): firewall not active"
        fi

        echo ""
        echo "  1) View current firewall status"
        echo "  2) Enable firewall with recommended defaults"
        echo "  3) Manage SSH access"
        echo "  4) Manage node ports"
        echo "  5) Manage trusted IP whitelist"
        local max_choice=6
        if fw_is_testnet; then
            echo "  6) Manage testnet add-on rules (VPN overlay / health port)"
            echo "  7) Exit"
            max_choice=7
        else
            echo "  6) Exit"
        fi
        echo ""

        local choice
        read -r -p "  Enter choice [1-${max_choice}]: " choice
        case "$choice" in
            1) view_status ;;
            2) enable_firewall ;;
            3) manage_ssh ;;
            4) manage_node_ports ;;
            5) manage_whitelist ;;
            6) if [[ "$max_choice" == "7" ]]; then manage_addon_rules; else echo ""; print_info "Exiting."; exit 0; fi ;;
            7) if [[ "$max_choice" == "7" ]]; then echo ""; print_info "Exiting."; exit 0; else print_warn "Please enter 1-${max_choice}."; fi ;;
            *) print_warn "Please enter 1-${max_choice}." ;;
        esac
    done
}

# =============================================================================
# MAIN
# =============================================================================

# =============================================================================
# JSON / NON-INTERACTIVE MODE
#
# Reached only via `--json` (the interactive default is completely unaffected).
# Used by the Telcoin Node Manager UI through the root-owned telcoin-ui-helper.
#
# Scope is deliberately narrow: read-only STATUS, and open/close for ONLY the
# three node ports below -- never SSH, password auth, root login, or the default
# policy (those stay CLI-only so the UI can never lock an operator out).
#
#   firewall-setup.sh --json --status
#   firewall-setup.sh --json --port <port>/<proto> <on|off>   (node ports only)
# =============================================================================

# The only ports the UI is allowed to toggle. 49590/49594 udp = validator P2P,
# 43174/tcp = Uptime Kuma health endpoint. Anything else is refused.
readonly -a JSON_NODE_PORTS=( "49590/udp" "49594/udp" "${UPTIME_KUMA_PORT}/tcp" )

json_setup_fds() {
    exec 3>&1   # fd3 = original stdout: JSON is written here
    exec 1>&2   # stdout now aliases stderr: print_*/ufw output is benign noise
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/ }"; s="${s//$'\r'/ }"; s="${s//$'\t'/ }"
    printf '%s' "$s"
}

json_emit() { printf '%s\n' "$1" >&3; }
json_event() { json_emit "{\"event\":\"${1}\",\"msg\":\"$(json_escape "${2:-}")\"}"; }

# Single-object status: installed/active, default inbound policy, ssh port (read
# only -- shown for context, never changed) and the open/closed state of each
# node port.
json_fw_status() {
    local installed=false active=false default_in="" ssh_port
    if ufw_installed; then installed=true; fi
    if ufw_active;    then active=true;    fi
    if [[ "$active" == "true" ]]; then
        # Real ufw verbose form: "Default: deny (incoming), allow (outgoing), ..."
        default_in=$(ufw status verbose 2>/dev/null | grep -oE '(deny|allow|reject) \(incoming\)' | awk '{print $1}' | head -1)
    fi
    ssh_port=$(get_ssh_port)

    local ports_json="" first=true pp port proto open
    for pp in "${JSON_NODE_PORTS[@]}"; do
        port="${pp%/*}"; proto="${pp#*/}"; open=false
        if [[ "$active" == "true" ]] && ufw_has_allow "$port" "$proto"; then open=true; fi
        [[ "$first" == "true" ]] || ports_json+=","
        ports_json+="\"${pp}\":${open}"
        first=false
    done

    local kuma_state="closed"
    [[ "$active" == "true" ]] && kuma_state="$(kuma_rule_state)"

    # Operator-chosen health sources (layered on top of the TA baseline), as a JSON array.
    local kuma_extra_json="" efirst=true esrc
    for esrc in $(kuma_extra_list); do
        [[ "$efirst" == "true" ]] || kuma_extra_json+=","
        kuma_extra_json+="\"$(json_escape "$esrc")\""
        efirst=false
    done

    json_emit "{\"installed\":${installed},\"active\":${active},\"default_incoming\":\"$(json_escape "${default_in}")\",\"ssh_port\":\"$(json_escape "${ssh_port}")\",\"kuma\":\"$(json_escape "${kuma_state}")\",\"kuma_extra\":[${kuma_extra_json}],\"ports\":{${ports_json}}}"
}

# Open/close ONE node port. Refuses any port not in JSON_NODE_PORTS.
json_fw_port() {
    local spec="$1" pstate="$2" allowed=false pp
    for pp in "${JSON_NODE_PORTS[@]}"; do [[ "$pp" == "$spec" ]] && allowed=true; done
    [[ "$allowed" == "true" ]] || { json_emit "{\"event\":\"done\",\"ok\":false,\"msg\":\"port not permitted from UI: $(json_escape "$spec") (allowed: ${JSON_NODE_PORTS[*]})\"}"; return 1; }
    case "$pstate" in on|off) ;; *) json_emit "{\"event\":\"done\",\"ok\":false,\"msg\":\"state must be on|off\"}"; return 1 ;; esac
    ufw_installed || { json_emit "{\"event\":\"done\",\"ok\":false,\"msg\":\"ufw not installed\"}"; return 1; }
    ufw_active    || { json_emit "{\"event\":\"done\",\"ok\":false,\"msg\":\"ufw is not active -- enable it via firewall-setup.sh on the server first\"}"; return 1; }

    if [[ "$pstate" == "on" ]]; then
        json_event step "Opening ${spec}"
        if [[ "$spec" == "${UPTIME_KUMA_PORT}/tcp" ]]; then
            # The health port must NEVER be open to the world: source-restrict it to the
            # Association monitor (TN_KUMA_SRC) instead of `ufw allow 43174/tcp` (Anywhere).
            apply_kuma_rule >/dev/null 2>&1 || { json_emit "{\"event\":\"done\",\"ok\":false,\"msg\":\"ufw allow failed for $(json_escape "$spec")\"}"; return 1; }
        else
            ufw allow "$spec" >/dev/null 2>&1 || { json_emit "{\"event\":\"done\",\"ok\":false,\"msg\":\"ufw allow failed for $(json_escape "$spec")\"}"; return 1; }
        fi
    else
        json_event step "Closing ${spec}"
        if [[ "$spec" == "${UPTIME_KUMA_PORT}/tcp" ]]; then
            # Remove the source-restricted rule (and any stale Anywhere rule) for the health port.
            ufw delete allow from "${TN_KUMA_SRC}" to any port "${UPTIME_KUMA_PORT}" proto tcp >/dev/null 2>&1 || true
            ufw delete allow "$spec" >/dev/null 2>&1 || true
        else
            ufw delete allow "$spec" >/dev/null 2>&1 || { json_emit "{\"event\":\"done\",\"ok\":false,\"msg\":\"ufw delete failed for $(json_escape "$spec")\"}"; return 1; }
        fi
    fi
    json_emit "{\"event\":\"done\",\"ok\":true,\"port\":\"$(json_escape "$spec")\",\"state\":\"$(json_escape "$pstate")\",\"msg\":\"firewall updated\"}"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local json_mode=false action="" fw_port="" fw_state=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)   json_mode=true; shift ;;
            --status) action="status"; shift ;;
            --port)   action="port"; fw_port="${2:-}"; fw_state="${3:-}"
                      shift; [[ $# -gt 0 ]] && shift; [[ $# -gt 0 ]] && shift ;;
            *) shift ;;
        esac
    done

    if [[ "$json_mode" == "true" ]]; then
        json_setup_fds
        check_root
        case "$action" in
            status) json_fw_status ;;
            port)   json_fw_port "$fw_port" "$fw_state" ;;
            *)      json_emit "{\"event\":\"done\",\"ok\":false,\"msg\":\"unknown or missing --json action\"}"; exit 1 ;;
        esac
        exit $?
    fi

    check_root
    main_menu
}

main "$@"
