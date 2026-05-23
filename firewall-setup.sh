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

readonly SCRIPT_VERSION="1.1.31"
readonly SSH_CONFIG="/etc/ssh/sshd_config"

# Ports required for a fully working Telcoin node deployment.
# 43174/tcp is the Uptime Kuma health-monitoring endpoint used by the
# Telcoin Association across all nodes (observer AND validator).
# UDP 49590/49594 are validator-only (P2P consensus).
readonly UPTIME_KUMA_PORT="43174"

# =============================================================================
# HELPERS
# =============================================================================

get_ssh_port() {
    grep -E "^Port " "$SSH_CONFIG" 2>/dev/null | awk '{print $2}' || echo "22"
}

get_ssh_password_auth() {
    grep -E "^PasswordAuthentication " "$SSH_CONFIG" 2>/dev/null | awk '{print $2}' || echo "yes"
}

get_ssh_root_login() {
    grep -E "^PermitRootLogin " "$SSH_CONFIG" 2>/dev/null | awk '{print $2}' || echo "yes"
}

ufw_active() {
    ufw status 2>/dev/null | grep -q "Status: active"
}

# Return 0 if ufw has an ALLOW rule for the given port/proto. Matches the
# protocol explicitly so a TCP rule on the same number doesn't get
# misreported as a UDP rule open (and vice versa). Matches both regular
# and (v6) entries.
ufw_has_allow() {
    local port="$1"
    local proto="$2"  # tcp | udp
    ufw status 2>/dev/null | \
        grep -qE "^${port}/${proto}([[:space:]]+\(v6\))?[[:space:]]+ALLOW"
}

ufw_installed() {
    command -v ufw &>/dev/null
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
        print_info "Uptime Kuma health monitoring -- TCP ${UPTIME_KUMA_PORT} required for all nodes"
        if ufw_active; then
            if ufw_has_allow "$UPTIME_KUMA_PORT" tcp; then
                print_ok "TCP ${UPTIME_KUMA_PORT} is open"
            else
                print_error "TCP ${UPTIME_KUMA_PORT} is CLOSED -- health monitoring will fail"
            fi
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
    echo "  - Allow TCP ${UPTIME_KUMA_PORT} (Uptime Kuma -- required for all nodes)"
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
    ufw allow "${UPTIME_KUMA_PORT}/tcp" &>/dev/null
    if echo "$nodes" | grep -q "validator"; then
        ufw allow 49590/udp &>/dev/null
        ufw allow 49594/udp &>/dev/null
    fi
    ufw --force enable &>/dev/null

    print_ok "Firewall enabled with recommended defaults"
    print_ok "SSH port ${ssh_port}/tcp allowed"
    print_ok "Uptime Kuma port ${UPTIME_KUMA_PORT}/tcp allowed"
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
    print_info "Uptime Kuma health monitoring -- TCP ${UPTIME_KUMA_PORT} is required for all nodes."
    print_info "(Used by Telcoin Association monitoring against every deployed node.)"
    if ufw_has_allow "$UPTIME_KUMA_PORT" tcp; then
        print_ok "TCP ${UPTIME_KUMA_PORT} is already open"
    else
        if confirm "Open TCP ${UPTIME_KUMA_PORT} for Uptime Kuma health monitoring?"; then
            ufw allow "${UPTIME_KUMA_PORT}/tcp" &>/dev/null
            print_ok "TCP ${UPTIME_KUMA_PORT} opened"
        else
            print_warn "TCP ${UPTIME_KUMA_PORT} left closed -- node will show as DOWN in monitoring."
        fi
    fi

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
        echo "  6) Exit"
        echo ""

        local choice
        read -r -p "  Enter choice [1-6]: " choice
        case "$choice" in
            1) view_status ;;
            2) enable_firewall ;;
            3) manage_ssh ;;
            4) manage_node_ports ;;
            5) manage_whitelist ;;
            6) echo ""; print_info "Exiting."; exit 0 ;;
            *) print_warn "Please enter 1-6." ;;
        esac
    done
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    check_root
    main_menu
}

main "$@"
