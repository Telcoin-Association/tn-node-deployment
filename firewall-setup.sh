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

readonly SCRIPT_VERSION="1.1.7"
readonly SSH_CONFIG="/etc/ssh/sshd_config"

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
            print_info "Observer node -- no inbound ports required"
            if ufw_active && ufw status 2>/dev/null | grep -q "49590\|49594"; then
                print_warn "Ports 49590/49594 appear open inbound -- not required for observer"
            else
                print_ok "No unnecessary inbound P2P ports open for observer"
            fi
        fi

        if echo "$nodes" | grep -q "validator"; then
            print_info "Validator node -- UDP 49590/49594 required inbound"
            if ufw_active; then
                ufw status 2>/dev/null | grep -q "49590" && \
                    print_ok "Port 49590 is open" || \
                    print_warn "Port 49590 not open -- validator P2P may not work"
                ufw status 2>/dev/null | grep -q "49594" && \
                    print_ok "Port 49594 is open" || \
                    print_warn "Port 49594 not open -- validator P2P may not work"
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

    echo ""
    print_info "This will apply the following settings:"
    echo "  - Default inbound policy: DENY"
    echo "  - Default outbound policy: ALLOW"
    echo "  - Allow established connections"
    echo "  - Allow SSH on port $(get_ssh_port)"
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

    local ssh_port
    ssh_port=$(get_ssh_port)

    ufw --force reset &>/dev/null
    ufw default deny incoming &>/dev/null
    ufw default allow outgoing &>/dev/null
    ufw allow "${ssh_port}/tcp" &>/dev/null
    ufw --force enable &>/dev/null

    print_ok "Firewall enabled with recommended defaults"
    print_ok "SSH port ${ssh_port} allowed"
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
            if [[ "$new_port" =~ ^[0-9]+$ ]] && [[ $new_port -gt 0 ]] && [[ $new_port -lt 65536 ]]; then
                if confirm "Change SSH port to ${new_port}?"; then
                    sed -i "s/^#*Port.*/Port ${new_port}/" "$SSH_CONFIG"
                    if ufw_active; then
                        ufw allow "${new_port}/tcp" &>/dev/null
                        ufw delete allow "${ssh_port}/tcp" &>/dev/null
                    fi
                    systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null
                    print_ok "SSH port changed to ${new_port}"
                    print_warn "Test access on port ${new_port} before closing this session"
                fi
            else
                print_warn "Invalid port number"
            fi
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
        print_info "Observer nodes do not require any inbound ports."
        print_info "P2P connections are outbound only."

        if ufw status 2>/dev/null | grep -q "49590\|49594"; then
            echo ""
            if confirm "Close inbound ports 49590/49594 (not needed for observer)?"; then
                ufw delete allow 49590/udp &>/dev/null
                ufw delete allow 49594/udp &>/dev/null
                print_ok "Inbound P2P ports closed"
            fi
        fi
    fi

    echo ""
    print_info "Public RPC (nginx on port 443):"
    if ufw status 2>/dev/null | grep -q "443"; then
        print_ok "Port 443 is already open"
    else
        if confirm "Open port 443 for public RPC via nginx?"; then
            ufw allow 443/tcp &>/dev/null
            print_ok "Port 443 opened"
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
