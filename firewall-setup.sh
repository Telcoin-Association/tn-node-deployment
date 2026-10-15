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

readonly SCRIPT_VERSION="1.6.0"
readonly SSH_CONFIG="${TN_ROOT_PREFIX:-}/etc/ssh/sshd_config"

# Ports required for a fully working Telcoin node deployment.
# 43174/tcp is the Uptime Kuma health-monitoring endpoint used by the
# Telcoin Association across all nodes.
# The node P2P consensus ports (UDP; 49590 primary and 49594 worker unless the
# node was set up with others, see fw_p2p_ports) are opened on every install: the
# role is decided on-chain at each epoch, not by the firewall, and a node that
# stakes/activates behind a closed firewall would be unreachable for consensus.
readonly UPTIME_KUMA_PORT="43174"

# The Caddyfile install-caddy.sh writes. Rooted at TN_ROOT_PREFIX (empty in
# production, a temp tree under test), like the resolvers in lib/fallback.sh.
readonly FW_CADDYFILE="${TN_ROOT_PREFIX:-}/etc/caddy/Caddyfile"
# ufw keeps its rule files and enabled flag here; apply_recommended_firewall saves
# them before it changes anything and puts them back when a step fails.
readonly FW_UFW_DIR="${TN_ROOT_PREFIX:-}/etc/ufw"
readonly FW_UFW_DEFAULT="${TN_ROOT_PREFIX:-}/etc/default/ufw"
# The sshd hardening drop-in. The 00- prefix sorts before cloud-init's
# 50-cloud-init.conf, and sshd keeps the first value it reads for a keyword.
readonly FW_SSHD_DROPIN="${TN_ROOT_PREFIX:-}/etc/ssh/sshd_config.d/00-telcoin-hardening.conf"
# Google Cloud IAP TCP forwarding range: kept in the SSH source list on a GCE VM.
readonly FW_IAP_SSH_CIDR="35.235.240.0/20"

# Source lists for this run: --ssh-from / --p2p-from (comma lists or a file), and
# --ssh-anywhere / --p2p-anywhere (drop a stored list). Empty = not given.
FW_SSH_FROM=""
FW_P2P_FROM=""
FW_SSH_ANYWHERE=false
FW_P2P_ANYWHERE=false
# Filled by fw_preflight: the validated sshd ports and SSH sources, and (lazily,
# fw_load_p2p_srcs) the P2P sources. An empty source array means "anywhere".
FW_SSH_PORTS=()
FW_SSH_SRCS=()
FW_P2P_SRCS=()
FW_P2P_LOADED=false

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

# fw_sshd_effective KEYWORD DEFAULT -- the value sshd uses for KEYWORD (lowercase):
# `sshd -T` when it runs, else the first KEYWORD line of sshd_config, else DEFAULT.
fw_sshd_effective() {
    local key="$1" dflt="$2" bin out v=""
    bin="$(fw_sshd_bin)"
    if [[ -n "$bin" ]] && out="$("$bin" -T 2>/dev/null)"; then
        v="$(awk -v k="$key" 'tolower($1) == k { print $2; exit }' <<< "$out")"
    fi
    if [[ -z "$v" ]]; then
        v="$(awk -v k="$key" 'tolower($1) == k { print $2; exit }' "$SSH_CONFIG" 2>/dev/null)" || v=""
    fi
    printf '%s\n' "${v:-$dflt}"
}

get_ssh_password_auth() { fw_sshd_effective passwordauthentication yes; }
get_ssh_root_login()    { fw_sshd_effective permitrootlogin yes; }

# fw_sshd_reload -- reload sshd (ssh.service on Debian/Ubuntu, sshd.service elsewhere).
fw_sshd_reload() {
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null
}

# fw_sshd_harden "Keyword value"... -- set each directive in the drop-in
# FW_SSHD_DROPIN (directives already there for other keywords stay), written
# through tn_write_root_file (root 0644). `sshd -t` checks the result: on a failure
# the previous drop-in is put back (or the new one removed), nothing is reloaded and
# rc is 1. Then sshd is reloaded and each keyword is read back with `sshd -T`; a
# value that did not take is a warning (rc 3), as is a sshd_config without an
# Include line for sshd_config.d. rc 2 when the drop-in could not be written.
fw_sshd_harden() {
    local f="$FW_SSHD_DROPIN" bin had=false prev="" content kv key want got rc=0
    bin="$(fw_sshd_bin)"
    if [[ -z "$bin" ]]; then
        print_error "sshd not found; nothing was changed."
        return 1
    fi
    if [[ -L "$f" ]]; then
        print_error "${f} is a symlink; nothing was changed."
        return 1
    fi
    if [[ -f "$f" ]]; then
        had=true
        prev="$(cat -- "$f")" || return 2
    fi
    content="$prev"
    for kv in "$@"; do
        key="${kv%% *}"
        content="$(printf '%s\n' "$content" | awk -v k="$key" 'tolower($1) != tolower(k) && $0 != ""')"
        content="${content:+${content}
}${kv}"
    done
    if [[ "$had" != "true" ]]; then
        content="# Managed by firewall-setup.sh (Telcoin node scripts): sshd hardening.
# 00- sorts before other drop-ins; sshd keeps the first value it reads.
${content}"
    fi
    if [[ ! -d "${f%/*}" ]]; then
        install -d -m 0755 -o root -g root "${f%/*}" || return 2
    fi
    if ! tn_write_root_file "$f" 0644 <<< "$content"; then
        print_error "Could not write ${f}; nothing was changed."
        return 2
    fi
    if ! "$bin" -t >/dev/null 2>&1; then
        print_error "sshd -t rejected the new configuration; putting the previous one back."
        if [[ "$had" == "true" ]]; then
            tn_write_root_file "$f" 0644 <<< "$prev" || print_error "Could not restore ${f}; fix it by hand before the next sshd restart."
        else
            rm -f -- "$f"
        fi
        return 1
    fi
    if ! grep -qiE '^[[:space:]]*Include[[:space:]].*sshd_config\.d' "$SSH_CONFIG" 2>/dev/null; then
        print_warn "${SSH_CONFIG} has no 'Include /etc/ssh/sshd_config.d/*.conf' line, so sshd ignores ${f}."
        rc=3
    fi
    fw_sshd_reload || print_warn "sshd reload failed; the new settings apply at the next sshd restart."
    for kv in "$@"; do
        key="${kv%% *}"
        want="${kv#* }"
        got="$(fw_sshd_effective "$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')" "")"
        if [[ "$(printf '%s' "$got" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')" ]]; then
            print_warn "sshd still reports ${key} ${got:-unknown} (wanted ${want}); an earlier drop-in or a Match block sets it."
            rc=3
        fi
    done
    return "$rc"
}

get_current_ip() {
    local ssh_client="${SSH_CLIENT:-}"
    echo "${ssh_client%% *}"
}

detect_installed_nodes() {
    # A VM runs exactly one node. Print its systemd service ("telcoin.service", or
    # the unit of a legacy install), or "none". The shared resolver
    # tn_resolve_service (lib/fallback.sh) covers unified and legacy installs. A
    # node's role is decided on-chain each epoch, so there is no node type to show.
    local svc
    svc="$(tn_resolve_service 2>/dev/null)" || { echo "none"; return 0; }
    echo "${svc}.service"
}

# =============================================================================
# NODE P2P PORTS
# =============================================================================

# fw_listener_port VAR FILE... -- print the UDP port of the last VAR=<multiaddr>
# assignment on a live line of the FILEs, read in order so a later file wins. The
# forms setup-node.sh writes all match: `-e "VAR=..."` in a docker command,
# `export VAR="..."` in a start wrapper, `Environment="VAR=..."` in a unit. A line
# whose first non-blank character is # is a comment (; too in a .service file),
# and in a wrapper so is the rest of a line from an unquoted # word. rc 1 when no
# FILE gives VAR a multiaddr with a UDP port.
fw_listener_port() {
    local var="$1" f unit port="" p
    shift
    for f in "$@"; do
        [[ -n "$f" && -f "$f" && -r "$f" ]] || continue
        unit=0
        if [[ "$f" == *.service ]]; then
            unit=1
        fi
        p="$(awk -v var="$var" -v unit="$unit" '
            # The line up to an unquoted # word: the shell ignores the rest.
            function code(s,    i, c, q, n) {
                q = ""; n = length(s)
                for (i = 1; i <= n; i++) {
                    c = substr(s, i, 1)
                    if (q != "") { if (c == q) q = ""; continue }
                    if (c == "\\") { i++; continue }
                    if (c == DQ || c == SQ) { q = c; continue }
                    if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t]/)) return substr(s, 1, i - 1)
                }
                return s
            }
            BEGIN { SQ = sprintf("%c", 39); DQ = "\""; re = "[ \t" DQ SQ "=]" var "="; found = "" }
            /^[ \t]*#/ { next }
            unit == 1 && /^[ \t]*;/ { next }
            {
                s = " " (unit == 1 ? $0 : code($0))
                while (match(s, re)) {
                    s = substr(s, RSTART + RLENGTH)
                    v = s
                    if (substr(v, 1, 1) == DQ || substr(v, 1, 1) == SQ) v = substr(v, 2)
                    if (match(v, /[ \t\\"]/)) v = substr(v, 1, RSTART - 1)
                    i = index(v, SQ); if (i > 0) v = substr(v, 1, i - 1)
                    if (match(v, /\/udp\/[0-9]+/)) {
                        p = substr(v, RSTART + 5, RLENGTH - 5)
                        rest = substr(v, RSTART + RLENGTH, 1)
                        if ((rest == "" || rest == "/") && length(p) <= 5 && p + 0 >= 1 && p + 0 <= 65535) found = p + 0
                    }
                }
            }
            END { if (found != "") print found }
        ' "$f" 2>/dev/null)" || p=""
        if [[ -n "$p" ]]; then
            port="$p"
        fi
    done
    [[ -n "$port" ]] || return 1
    printf '%s\n' "$port"
}

# fw_p2p_ports -- print the node's inbound P2P ports (UDP), one "<port> <label>"
# line each: primary, worker-0, worker-1, ... in worker order. Primary and worker
# 0 come from the listener addresses the node is started with
# (PRIMARY_LISTENER_MULTIADDR, WORKER_LISTENER_MULTIADDR in the start wrapper, or
# in the unit when the wrapper does not set them), because that is the port the
# node binds; else from node-info.yaml; else 49590 and 49594. Workers 1 and up
# come from node-info.yaml only (worker N is line N+1 of
# tn_node_info_worker_ports). Always prints at least the primary and worker-0
# lines, so a box with no node, or with a lib/common.sh older than 1.6.0 (see
# fw_lib_check), gets the defaults.
fw_p2p_ports() {
    local target svc file unit ni primary="" w0="" workers="" p i
    if target="$(tn_node_launch_target 2>/dev/null)"; then
        read -r svc _ file <<< "$target"
        unit="${TN_ROOT_PREFIX:-}/etc/systemd/system/${svc}.service"
        primary="$(fw_listener_port PRIMARY_LISTENER_MULTIADDR "$unit" "${TN_ROOT_PREFIX:-}/etc/telcoin/node.env" "$file")" || primary=""
        w0="$(fw_listener_port WORKER_LISTENER_MULTIADDR "$unit" "${TN_ROOT_PREFIX:-}/etc/telcoin/node.env" "$file")" || w0=""
    fi
    ni="$(tn_resolve_data_dir 2>/dev/null || true)/node-info.yaml"
    if [[ -z "$primary" ]] && declare -F tn_node_info_field >/dev/null 2>&1; then
        primary="$(tn_node_info_field "$ni" primary_port 2>/dev/null)" || primary=""
    fi
    if declare -F tn_node_info_worker_ports >/dev/null 2>&1; then
        workers="$(tn_node_info_worker_ports "$ni" 2>/dev/null)" || workers=""
    fi
    if [[ -z "$w0" ]]; then
        w0="$(printf '%s\n' "$workers" | sed -n 1p)"
    fi
    printf '%s primary\n' "${primary:-$DEFAULT_P2P_PORT}"
    printf '%s worker-0\n' "${w0:-$DEFAULT_WORKER_PORT}"
    i=0
    while IFS= read -r p; do
        if (( i > 0 )) && [[ -n "$p" ]]; then
            printf '%s worker-%s\n' "$p" "$i"
        fi
        i=$((i + 1))
    done <<< "$workers"
}

# fw_p2p_what LABEL WORKERS -- the words for an fw_p2p_ports label in messages and
# rule labels: "primary", "worker" when the node has one worker, else "worker N".
fw_p2p_what() {
    case "$1" in
        primary)  printf 'primary' ;;
        worker-*) if [[ "${2:-1}" -gt 1 ]]; then printf 'worker %s' "${1#worker-}"; else printf 'worker'; fi ;;
        *)        printf '%s' "$1" ;;
    esac
}

# fw_p2p_port_text [/] -- the P2P port numbers as one phrase: "49590 and 49594"
# ("49590, 49594 and 49595" for three), or "49590/49594" with the / argument.
fw_p2p_port_text() {
    local style="${1:-and}" port label n i out=""
    local -a ports=()
    while read -r port label; do
        if [[ -n "$port" ]]; then
            ports+=("$port")
        fi
    done < <(fw_p2p_ports)
    n=${#ports[@]}
    i=0
    while (( i < n )); do
        if (( i > 0 )); then
            if [[ "$style" == "/" ]]; then
                out+="/"
            elif (( i == n - 1 )); then
                out+=" and "
            else
                out+=", "
            fi
        fi
        out+="${ports[$i]}"
        i=$((i + 1))
    done
    printf '%s' "$out"
}

# fw_p2p_all_open -- 0 when ufw has an ALLOW rule for every P2P port.
fw_p2p_all_open() {
    local port label
    while read -r port label; do
        [[ -n "$port" ]] || continue
        ufw_has_allow "$port" udp || return 1
    done < <(fw_p2p_ports)
    return 0
}

# fw_p2p_allow -- add an ALLOW rule for every P2P port (ufw skips existing ones).
# With a P2P source list (--p2p-from, or P2P_ALLOW_FROM in .node-meta) it adds one
# rule per source and port and then deletes the open rule of that port (IPv4 and
# IPv6 together). The first ufw call that fails is reported (fw_try) and ends it
# with rc 1, so the caller stops there; an unreadable source list is rc 1 too.
fw_p2p_allow() {
    local port label s
    fw_load_p2p_srcs || return 1
    while read -r port label; do
        [[ -n "$port" ]] || continue
        if [[ ${#FW_P2P_SRCS[@]} -gt 0 ]]; then
            for s in "${FW_P2P_SRCS[@]}"; do
                fw_try "ufw allow from ${s} to any port ${port} proto udp" ufw allow from "$s" to any port "$port" proto udp || return 1
            done
            fw_try "ufw delete allow ${port}/udp" ufw delete allow "${port}/udp" || return 1
        else
            fw_try "ufw allow ${port}/udp" ufw allow "${port}/udp" || return 1
        fi
    done < <(fw_p2p_ports)
    return 0
}

# fw_port_ok VALUE -- 0 when VALUE is a decimal port 1-65535 without leading zeros.
fw_port_ok() {
    [[ "${1:-}" =~ ^[1-9][0-9]{0,4}$ ]] && (( ${1} <= 65535 ))
}

# fw_src_list SPEC -- print the sources in SPEC one per line. SPEC is a comma list
# of addresses or CIDRs, or the path of a readable file holding them (one or more
# per line, comma separated; # starts a comment). Every entry must pass
# validate_health_src, which refuses /0 and the unspecified address. rc 1 (message
# on stderr) on the first bad entry or an empty list.
fw_src_list() {
    local spec="${1:-}" raw s n=0
    if [[ -f "$spec" ]]; then
        raw="$(sed -e 's/#.*//' "$spec" | tr ',' '\n')" || return 1
    else
        raw="$(printf '%s\n' "$spec" | tr ',' '\n')"
    fi
    while IFS= read -r s; do
        s="${s//[[:space:]]/}"
        [[ -n "$s" ]] || continue
        if ! validate_health_src "$s"; then
            print_error "Not an address or a CIDR narrower than /0: '${s}'" >&2
            return 1
        fi
        printf '%s\n' "$s"
        n=$((n + 1))
    done <<< "$raw"
    if [[ "$n" -eq 0 ]]; then
        print_error "The source list is empty." >&2
        return 1
    fi
    return 0
}

# fw_sources ssh|p2p -- the effective source list, one per line: the --ssh-from /
# --p2p-from value of this run, else SSH_ALLOW_FROM / P2P_ALLOW_FROM in .node-meta,
# else nothing (anywhere). --ssh-anywhere / --p2p-anywhere print nothing. rc 1 on
# an invalid entry or a key set more than once (message on stderr).
fw_sources() {
    local kind="$1" given anywhere key stored
    if [[ "$kind" == "ssh" ]]; then
        given="$FW_SSH_FROM"; anywhere="$FW_SSH_ANYWHERE"; key="SSH_ALLOW_FROM"
    else
        given="$FW_P2P_FROM"; anywhere="$FW_P2P_ANYWHERE"; key="P2P_ALLOW_FROM"
    fi
    [[ "$anywhere" == "true" ]] && return 0
    if [[ -n "$given" ]]; then
        fw_src_list "$given"
        return
    fi
    stored="$(addon_meta_get "$key")" || return 1
    [[ -n "$stored" ]] || return 0
    if ! fw_src_list "$stored"; then
        print_error "${key} in .node-meta holds an invalid entry; pass --${kind}-from again." >&2
        return 1
    fi
}

# fw_load_p2p_srcs -- fill FW_P2P_SRCS from fw_sources p2p once per run.
fw_load_p2p_srcs() {
    local list s
    [[ "$FW_P2P_LOADED" == "true" ]] && return 0
    list="$(fw_sources p2p)" || return 1
    FW_P2P_SRCS=()
    while IFS= read -r s; do
        [[ -n "$s" ]] && FW_P2P_SRCS+=("$s")
    done <<< "$list"
    FW_P2P_LOADED=true
}

# fw_on_gce -- 0 on a Google Compute Engine VM (DMI product name), where IAP TCP
# forwarding is the console SSH path.
fw_on_gce() {
    grep -qi "Google Compute Engine" "${TN_ROOT_PREFIX:-}/sys/class/dmi/id/product_name" 2>/dev/null
}

# fw_sshd_bin -- the sshd binary, or nothing.
fw_sshd_bin() {
    if command -v sshd >/dev/null 2>&1; then
        command -v sshd
    elif [[ -x /usr/sbin/sshd ]]; then
        printf '%s\n' /usr/sbin/sshd
    fi
}

# fw_ssh_ports -- the ports sshd listens on, one per line: `sshd -T` (the
# effective configuration), else the Port lines of sshd_config, else 22. rc 1 when
# a value is not a port 1-65535.
fw_ssh_ports() {
    local bin out ports="" p
    bin="$(fw_sshd_bin)"
    if [[ -n "$bin" ]] && out="$("$bin" -T 2>/dev/null)"; then
        ports="$(awk 'tolower($1) == "port" { print $2 }' <<< "$out")"
    fi
    [[ -n "$ports" ]] || ports="$(get_ssh_port)"
    [[ -n "$ports" ]] || ports=22
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        fw_port_ok "$p" || return 1
        printf '%s\n' "$p"
    done <<< "$(printf '%s\n' "$ports" | sort -un)"
}

# fw_preflight -- check everything apply_recommended_firewall needs before it
# changes anything: ufw present, sshd ports valid, SSH and P2P source lists valid,
# the stored health sources valid on testnet, every P2P port valid, and on mainnet
# an SSH source list (or --ssh-anywhere). Fills FW_SSH_PORTS, FW_SSH_SRCS and
# FW_P2P_SRCS. rc 1 with an error (fw_error) when anything is wrong.
fw_preflight() {
    local list s port label
    if ! command -v ufw >/dev/null 2>&1; then
        fw_error "ufw is not installed; nothing was changed."
        return 1
    fi
    if ! list="$(fw_ssh_ports)"; then
        fw_error "sshd reports a listen port outside 1-65535; nothing was changed."
        return 1
    fi
    FW_SSH_PORTS=()
    while IFS= read -r s; do
        [[ -n "$s" ]] && FW_SSH_PORTS+=("$s")
    done <<< "$list"
    if ! list="$(fw_sources ssh)"; then
        fw_error "The SSH source list is not usable; nothing was changed."
        return 1
    fi
    FW_SSH_SRCS=()
    while IFS= read -r s; do
        [[ -n "$s" ]] && FW_SSH_SRCS+=("$s")
    done <<< "$list"
    FW_P2P_LOADED=false
    if ! fw_load_p2p_srcs; then
        fw_error "The P2P source list is not usable; nothing was changed."
        return 1
    fi
    if [[ "${NETWORK:-}" == "mainnet" && ${#FW_SSH_SRCS[@]} -eq 0 && "$FW_SSH_ANYWHERE" != "true" ]]; then
        fw_error "Mainnet: give the SSH sources with --ssh-from CIDR[,CIDR] (or --ssh-anywhere to keep SSH open to every address); nothing was changed."
        return 1
    fi
    if is_testnet_like; then
        if ! list="$(kuma_extra_list)"; then
            fw_error "KUMA_EXTRA_SRC cannot be read; nothing was changed."
            return 1
        fi
        local -a extras=()
        read -r -a extras <<< "$list" || true
        for s in ${extras[@]+"${extras[@]}"}; do
            if ! validate_health_src "$s"; then
                fw_error "KUMA_EXTRA_SRC holds '${s}', which is not an address or a CIDR narrower than /0; remove it (Manage node ports) first. Nothing was changed."
                return 1
            fi
        done
    fi
    while read -r port label; do
        [[ -n "$port" ]] || continue
        if ! fw_port_ok "$port"; then
            fw_error "The ${label} P2P port '${port}' is not 1-65535; nothing was changed."
            return 1
        fi
    done < <(fw_p2p_ports)
    return 0
}

# fw_snapshot -- copy ufw's rule files, ufw.conf and /etc/default/ufw into a new
# root-only directory (mktemp -d under TN_FW_SNAP_PARENT, default /run) and print
# its path. rc 1 when the copy fails.
fw_snapshot() {
    local d f
    d="$(mktemp -d "${TN_FW_SNAP_PARENT:-/run}/tn-fw.XXXXXX")" || return 1
    for f in "$FW_UFW_DIR"/*.rules "$FW_UFW_DIR"/ufw.conf; do
        [[ -f "$f" ]] || continue
        cp -p -- "$f" "$d/" || { rm -rf -- "$d"; return 1; }
    done
    if [[ -f "$FW_UFW_DEFAULT" ]]; then
        cp -p -- "$FW_UFW_DEFAULT" "$d/default-ufw" || { rm -rf -- "$d"; return 1; }
    fi
    printf '%s\n' "$d"
}

# fw_restore SNAPSHOT WAS_ACTIVE -- put the saved files back, then return ufw to
# the state it had: `ufw --force enable` (which reloads the restored rules) when it
# was active or the restored ufw.conf says ENABLED=yes, `ufw --force disable`
# otherwise. rc 1 when any step fails.
fw_restore() {
    local d="$1" was_active="$2" f rc=0
    for f in "$d"/*; do
        [[ -f "$f" ]] || continue
        if [[ "${f##*/}" == "default-ufw" ]]; then
            cp -p -- "$f" "$FW_UFW_DEFAULT" || rc=1
        else
            cp -p -- "$f" "$FW_UFW_DIR/" || rc=1
        fi
    done
    [[ "$rc" -eq 0 ]] || return 1
    if [[ "$was_active" == "true" ]] || grep -q '^ENABLED=yes' "$FW_UFW_DIR/ufw.conf" 2>/dev/null; then
        ufw --force enable >/dev/null 2>&1 || return 1
    else
        ufw --force disable >/dev/null 2>&1 || return 1
    fi
    return 0
}

# fw_error MSG -- report a failure: an error event in --json mode (fw_on_exit and the
# done event repeat it), an [ERROR] line otherwise.
fw_error() {
    if [[ "${JSON_MODE:-false}" == "true" ]]; then
        json_event error "$1"
    else
        print_error "$1"
    fi
}

# fw_try DESC CMD... -- run CMD with its output dropped. When it fails, report "DESC
# failed (exit N)." with fw_error and return N. apply_recommended_firewall runs every
# rule through this, so a rule that cannot be added stops it before
# `ufw --force enable`, whatever the errexit state of its caller.
fw_try() {
    local desc="$1" rc=0
    shift
    "$@" &>/dev/null || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        fw_error "${desc} failed (exit ${rc})."
    fi
    return "$rc"
}

# fw_lib_check -- warn when lib/common.sh is older than 1.6.0: without its
# node-info.yaml readers fw_p2p_ports finds the primary and worker 0 ports in the
# launch files only (else 49590 and 49594) and cannot see workers 1 and up. Called
# once per screen and once per --json run; prints nothing on a current library.
fw_lib_check() {
    if declare -F tn_node_info_field >/dev/null 2>&1 && declare -F tn_node_info_worker_ports >/dev/null 2>&1; then
        return 0
    fi
    print_warn "lib/common.sh ${COMMON_VERSION:-unknown} cannot read node-info.yaml, so only the primary and worker 0 P2P ports are checked (from the launch file, else ${DEFAULT_P2P_PORT} and ${DEFAULT_WORKER_PORT}). Run update-scripts.sh to update the library."
    return 0
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
        # Real ufw verbose form: "Default: deny (incoming), allow (outgoing), ...". A
        # pattern that finds nothing must not end the script (set -e with pipefail).
        default_in=$(ufw status verbose 2>/dev/null | grep -oE '(deny|allow|reject) \(incoming\)' | awk '{print $1}' | head -1 || true)
        if [[ "$default_in" == "deny" ]]; then
            print_ok "Default inbound policy: deny (recommended)"
        else
            print_warn "Default inbound policy: ${default_in:-unknown} (recommend: deny)"
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
        print_info "Installed node: ${nodes}"
        fw_lib_check
        echo ""

        # Every node binds its P2P listen ports at the initial epoch, and no new
        # networking is provisioned when a node joins the committee -- so a node
        # that stakes/activates behind a closed firewall is unreachable. The role is
        # decided on-chain, not here, so we expect these open on every install.
        local p2p port label what nworkers
        p2p="$(fw_p2p_ports)"
        nworkers="$(grep -c ' worker-' <<< "$p2p" || true)"
        print_info "Node P2P -- UDP $(fw_p2p_port_text /) required inbound for consensus"
        if ufw_active; then
            while read -r port label; do
                [[ -n "$port" ]] || continue
                what="$(fw_p2p_what "$label" "$nworkers")"
                if ufw_has_allow "$port" udp; then
                    print_ok "UDP ${port} is open (${what})"
                else
                    print_error "UDP ${port} (${what}) is CLOSED -- node will be unreachable for consensus P2P"
                fi
            done <<< "$p2p"
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

    # Expected configuration (desired-state) + drift -- only meaningful with ufw active.
    if ufw_active; then
        echo ""
        print_step "Expected configuration for this node..."
        local spec label source missing=0 unexpected=0
        while IFS=$'\t' read -r spec label source; do
            [[ -n "$spec" ]] || continue
            if fw_rule_satisfied "$spec"; then
                print_ok "${label} (${spec})"
            else
                print_warn "${label} (${spec}) -- MISSING (expected${source:+ from $source})"
                missing=$((missing+1))
            fi
        done < <(desired_firewall_rules)

        local ureason
        while IFS=$'\t' read -r spec ureason; do
            [[ -n "$spec" ]] || continue
            print_warn "Unexpected: ${spec} -- ${ureason}"
            unexpected=$((unexpected+1))
        done < <(fw_unexpected_rules)

        if (( missing == 0 && unexpected == 0 )); then
            print_ok "Firewall matches the expected configuration"
        else
            print_info "Drift detected -- re-run 'Enable recommended defaults' to reconcile (it keeps your custom rules)."
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

# apply_recommended_firewall [--reset] — stage the lockout-safe ruleset and enable
# ufw, with NO prompt. Shared by the interactive enable_firewall, `--enable`,
# `--reset` and `--json --enable`.
#
# Before anything changes, fw_preflight checks every input (ufw present, sshd
# ports from `sshd -T`, the SSH and P2P source lists, the stored health sources,
# the P2P ports; on mainnet an SSH source list or --ssh-anywhere); a failure
# there is rc 1 with nothing changed. Then ufw's rule files are saved
# (fw_snapshot) and the rules go in this order: SSH (per source when a list is
# set, the IAP range on GCE and the overlay admin range on a VPN host first; else
# the blanket port rule), the health port (testnet and devnet only; on any other
# network an old monitor rule is deleted), the load-balancer health ranges, the
# overlay SSH rule, the node P2P ports (per source with P2P_ALLOW_FROM), 80/443
# when Caddy serves the public edge here, and only then the default policies,
# the deletion of the blanket SSH rule (with a source list) and
# `ufw --force enable`. Every allow comes before the default deny, so there is
# never a window with SSH closed.
#
# RECONCILE by default: it only ENSURES the managed rules + policies exist, so a
# re-run keeps an operator's custom rules. "--reset" first runs `ufw --force
# reset` for a clean slate (all rules removed, except that 80/443 come back when
# Caddy serves the public edge here).
#
# rc 0 done; 1 refused by the preflight (nothing changed); 2 a step failed and the
# previous rule files and ufw state were put back; 3 a step failed and putting
# them back failed too: ufw may now be DISABLED (the message says where the saved
# files are).
apply_recommended_firewall() {
    local do_reset="${1:-}"
    local nodes keep_web=false web_was_open=false was_active=false snap
    fw_preflight || return 1
    nodes=$(detect_installed_nodes)
    # Before a reset wipes the rules: is Caddy serving the public edge on this box, and
    # does the running firewall already let it in?
    if caddy_serves_public_edge; then
        keep_web=true
        if ufw_active && ufw_has_allow 80 tcp && ufw_has_allow 443 tcp; then
            web_was_open=true
        fi
    fi
    if ufw_active; then
        was_active=true
    fi
    if ! snap="$(fw_snapshot)"; then
        fw_error "Could not save the current ufw rule files; nothing was changed."
        return 1
    fi
    if ! fw_apply_rules "$do_reset" "$nodes" "$keep_web"; then
        if fw_restore "$snap" "$was_active"; then
            rm -rf -- "$snap"
            if [[ "$was_active" == "true" ]]; then
                fw_error "Stopped at that step; the previous ufw rules were put back and ufw is active again."
            else
                fw_error "Stopped at that step; the previous ufw rules were put back and ufw stays inactive, as it was."
            fi
            return 2
        fi
        fw_error "Stopped at that step, and the previous ufw rules could not be put back: ufw may now be DISABLED. The saved rule files are in ${snap}. Fix the cause and run: sudo bash ${SCRIPT_DIR}/firewall-setup.sh --reset"
        return 3
    fi
    rm -rf -- "$snap"
    if [[ "$keep_web" == "true" ]]; then
        if [[ "$web_was_open" == "true" ]]; then
            print_info "Kept TCP 80/443 open -- Caddy serves the public RPC/dashboard on this box."
        else
            print_info "Allowed TCP 80/443 -- Caddy serves the public RPC/dashboard on this box."
        fi
        print_info "To close them, turn that access off with install-caddy.sh (sudo bash ${SCRIPT_DIR}/install-caddy.sh);"
        print_info "  it closes 80/443 once no site remains."
    fi
    return 0
}

# fw_apply_rules RESET NODES KEEP_WEB -- the rule sequence of
# apply_recommended_firewall (see there for the order). Needs fw_preflight first.
# rc 1 at the first step that fails (reported by fw_try).
fw_apply_rules() {
    local do_reset="$1" nodes="$2" keep_web="$3" p s
    local -a fixed=()
    if [[ "$do_reset" == "--reset" || "$do_reset" == "reset" ]]; then
        fw_try "ufw --force reset" ufw --force reset || return 1
    fi
    if [[ ${#FW_SSH_SRCS[@]} -gt 0 ]]; then
        if fw_on_gce; then
            fixed+=("$FW_IAP_SSH_CIDR")
        fi
        if is_testnet_like && vpn_active; then
            fixed+=("$TN_OVERLAY_ADMIN_CIDR")
        fi
    fi
    for p in "${FW_SSH_PORTS[@]}"; do
        if [[ ${#FW_SSH_SRCS[@]} -gt 0 ]]; then
            for s in ${fixed[@]+"${fixed[@]}"} "${FW_SSH_SRCS[@]}"; do
                fw_try "ufw allow from ${s} to any port ${p} proto tcp" ufw allow from "$s" to any port "$p" proto tcp || return 1
            done
        else
            fw_try "ufw allow ${p}/tcp" ufw allow "${p}/tcp" || return 1
        fi
    done
    if is_testnet_like; then
        fw_try "The health-port rule (${UPTIME_KUMA_PORT}/tcp from ${TN_KUMA_SRC})" apply_kuma_rule || return 1
        # LB health-check ranges (no-op unless TN_LB_HC_RANGES set)
        fw_try "The load-balancer health-check rules" apply_lb_hc_rule || return 1
        if vpn_active; then
            fw_try "The overlay SSH rule (from ${TN_OVERLAY_ADMIN_CIDR})" allow_overlay_ssh || return 1
        fi
    else
        # Not a testnet: the health port stays closed; delete a monitor rule left from before.
        apply_kuma_rule >/dev/null 2>&1 || true
    fi
    # Every installed node needs P2P open inbound: the role is decided on-chain at
    # each epoch and no networking is provisioned when a node joins the committee,
    # so a node that activates behind a closed firewall would be unreachable.
    if [[ "$nodes" != "none" ]]; then
        fw_p2p_allow || return 1
    fi
    # Allow the public edge BEFORE enable, so neither a plain enable (ufw off until now,
    # with no 80/443 rules staged) nor --reset leaves a site Caddy serves unreachable.
    if [[ "$keep_web" == "true" ]]; then
        fw_try "ufw allow 80/tcp" ufw allow 80/tcp || return 1
        fw_try "ufw allow 443/tcp" ufw allow 443/tcp || return 1
    fi
    fw_try "ufw default deny incoming" ufw default deny incoming || return 1
    fw_try "ufw default allow outgoing" ufw default allow outgoing || return 1
    # With a source list, drop the blanket rule (one delete removes the IPv4 and IPv6
    # rules) after the per-source rules are in, so SSH is never closed in between.
    if [[ ${#FW_SSH_SRCS[@]} -gt 0 ]]; then
        for p in "${FW_SSH_PORTS[@]}"; do
            fw_try "ufw delete allow ${p}/tcp" ufw delete allow "${p}/tcp" || return 1
        done
    fi
    fw_try "ufw --force enable" ufw --force enable || return 1
    return 0
}

# fw_persist_sources -- record the source lists given on this run in .node-meta
# (SSH_ALLOW_FROM, P2P_ALLOW_FROM as comma lists; --ssh-anywhere / --p2p-anywhere
# remove the key), so a later enable keeps them. Call fw_meta_lock first. rc 1
# when a write failed (warned).
fw_persist_sources() {
    local rc=0 v
    if [[ -n "$FW_SSH_FROM" ]]; then
        v="$(printf '%s\n' ${FW_SSH_SRCS[@]+"${FW_SSH_SRCS[@]}"} | paste -sd, -)"
        meta_set SSH_ALLOW_FROM "$v" || rc=1
    elif [[ "$FW_SSH_ANYWHERE" == "true" ]]; then
        meta_unset SSH_ALLOW_FROM || rc=1
    fi
    if [[ -n "$FW_P2P_FROM" ]]; then
        v="$(printf '%s\n' ${FW_P2P_SRCS[@]+"${FW_P2P_SRCS[@]}"} | paste -sd, -)"
        meta_set P2P_ALLOW_FROM "$v" || rc=1
    elif [[ "$FW_P2P_ANYWHERE" == "true" ]]; then
        meta_unset P2P_ALLOW_FROM || rc=1
    fi
    if [[ "$rc" -ne 0 ]]; then
        print_warn "The source lists could not be saved in .node-meta; give the same flags again on the next run." >&2
    fi
    return "$rc"
}

# fw_wants_meta_write -- 0 when this run will change a stored source list.
fw_wants_meta_write() {
    [[ -n "$FW_SSH_FROM" || -n "$FW_P2P_FROM" || "$FW_SSH_ANYWHERE" == "true" || "$FW_P2P_ANYWHERE" == "true" ]] || return 1
    node_meta_path >/dev/null 2>&1
}

# fw_meta_lock -- when this run will write .node-meta: take the update lock and
# migrate an old ownership layout (addon_meta_write_begin). rc 1 when refused.
fw_meta_lock() {
    fw_wants_meta_write || return 0
    addon_meta_write_begin
}

enable_firewall() {
    print_header "Enable Firewall with Recommended Defaults"

    if ! ufw_installed; then
        print_step "Installing ufw..."
        apt-get install -y ufw &>/dev/null
        print_ok "ufw installed"
    fi

    local ssh_port nodes p2p_text=""
    ssh_port=$(get_ssh_port)
    nodes=$(detect_installed_nodes)
    if [[ "$nodes" != "none" ]]; then
        fw_lib_check
        p2p_text="$(fw_p2p_port_text)"
    fi

    # SSH sources: a stored list is kept unless a new one is typed. On mainnet SSH
    # open to every address needs an explicit yes.
    local cur_src new_src
    cur_src="$(fw_sources ssh | paste -sd, -)" || cur_src=""
    echo ""
    print_info "SSH is allowed from: ${cur_src:-anywhere}"
    read -r -p "  Restrict SSH to these sources (comma-separated IPs/CIDRs; Enter keeps the current setting): " new_src
    if [[ -n "$new_src" ]]; then
        if ! fw_src_list "$new_src" >/dev/null; then
            echo ""; read -r -p "  Press Enter to return to menu..."
            return
        fi
        FW_SSH_FROM="$new_src"
        cur_src="$(fw_src_list "$new_src" | paste -sd, -)"
    elif [[ -z "$cur_src" && "${NETWORK:-}" == "mainnet" ]]; then
        print_warn "Mainnet: SSH open to every address is not the default."
        if confirm "Keep SSH open to every address anyway?"; then
            FW_SSH_ANYWHERE=true
        else
            print_info "Cancelled -- no changes made."
            echo ""; read -r -p "  Press Enter to return to menu..."
            return
        fi
    fi

    echo ""
    print_info "This will apply the following settings:"
    echo "  - Default inbound policy: DENY"
    echo "  - Default outbound policy: ALLOW"
    echo "  - Allow established connections"
    if [[ -n "$cur_src" ]]; then
        echo "  - Allow SSH on port ${ssh_port} from ${cur_src} only (the open SSH rule is removed)"
    else
        echo "  - Allow SSH on port ${ssh_port}"
    fi
    if is_testnet_like; then
        echo "  - Allow TCP ${UPTIME_KUMA_PORT} (Uptime Kuma) from the Association monitor only (${TN_KUMA_SRC})"
    fi
    if [[ "$nodes" != "none" ]]; then
        echo "  - Allow UDP ${p2p_text} (node P2P -- required for consensus)"
    fi
    if caddy_serves_public_edge; then
        echo "  - Allow TCP 80 and 443 (Caddy serves the public RPC/dashboard on this server)"
    fi
    if [[ "$nodes" == "none" ]]; then
        echo ""
        print_info "No Telcoin node installed yet. Re-run this option after running"
        print_info "setup-node.sh to also open the node P2P ports."
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

    # Reconcile by default (keeps any custom rules). Offer a clean-slate reset as an
    # explicit, gated choice -- it removes ALL existing rules, including ones you added
    # by hand (e.g. a manual 443). Default is No.
    local reset_arg=""
    print_warn "Reset wipes ALL existing ufw rules (including custom ones you added)."
    if confirm "Reset to a clean slate first? (No keeps existing custom rules)"; then
        reset_arg="--reset"
    fi

    # Stage the lockout-safe ruleset + enable (shared with --json --enable). SSH + overlay +
    # kuma are allowed before enable, so this can't sever the IAP door or the overlay.
    if ! fw_meta_lock || ! apply_recommended_firewall "$reset_arg"; then
        echo ""
        read -r -p "  Press Enter to return to menu..."
        return
    fi
    if fw_wants_meta_write; then
        fw_persist_sources || true
    fi

    print_ok "Firewall enabled with recommended defaults"
    [[ -n "$reset_arg" ]] && print_info "Existing rules were reset to a clean slate"
    print_ok "SSH port ${ssh_port}/tcp allowed from ${cur_src:-anywhere}"
    if is_testnet_like; then
        print_ok "Uptime Kuma port ${UPTIME_KUMA_PORT}/tcp allowed from ${TN_KUMA_SRC} (Association monitor)"
    fi
    if [[ "$nodes" != "none" ]]; then
        print_ok "Node P2P UDP ${p2p_text} allowed"
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
                    if fw_sshd_harden "PasswordAuthentication no" "KbdInteractiveAuthentication no"; then
                        print_ok "Password authentication disabled (${FW_SSHD_DROPIN})"
                    fi
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
                    if fw_sshd_harden "PermitRootLogin no"; then
                        print_ok "Root login disabled (${FW_SSHD_DROPIN})"
                    fi
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
        print_info "Run setup-node.sh first"
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

    print_info "Detected node: ${nodes}"
    fw_lib_check
    echo ""

    local p2p_text
    p2p_text="$(fw_p2p_port_text)"
    echo "  Every node needs UDP ports ${p2p_text} open inbound for consensus P2P."
    echo "  The role is decided on-chain -- a node that stakes must already be reachable."
    echo ""
    if fw_p2p_all_open; then
        print_ok "UDP ports ${p2p_text} are already open"
    elif confirm "Open UDP ports ${p2p_text} for node P2P?"; then
        if fw_p2p_allow; then
            print_ok "UDP ports ${p2p_text} opened"
        fi
    fi
    echo ""

    echo ""
    print_info "Uptime Kuma health monitoring -- TCP ${UPTIME_KUMA_PORT}."
    if ! is_testnet_like; then
        # Mainnet (or no node yet): the health port is never opened.
        apply_kuma_rule >/dev/null 2>&1 || true
        print_info "Health monitoring is a testnet-only add-on; TCP ${UPTIME_KUMA_PORT} stays closed here."
        manage_node_ports_web
        return
    fi
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
    echo "    3) Leave as-is"
    echo "  (The health port is never opened to every address.)"
    echo ""
    local kchoice
    read -r -p "  Enter choice [1-3]: " kchoice
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
        *)
            print_info "Left ${UPTIME_KUMA_PORT}/tcp as-is."
            ;;
    esac
    manage_node_ports_web
}

# manage_node_ports_web -- the 80/443 part of manage_node_ports.
manage_node_ports_web() {
    echo ""
    print_info "Public dashboard (HTTP/HTTPS -- TCP 80/443):"
    # 443 is owned by Caddy now (install-caddy.sh opens/closes 80+443 with the
    # reverse proxy). The firewall only REFLECTS that state here -- no independent
    # toggle, so the two can't drift.
    if caddy_managed_active; then
        print_ok "Caddy is active -- TCP 80/443 are managed by Caddy (install-caddy.sh)."
    elif ufw_has_allow 443 tcp || ufw_has_allow 80 tcp; then
        print_warn "TCP 80/443 are open but Caddy is not managing them."
        print_info "80/443 are owned by Caddy now. Enable/disable external access with"
        print_info "  sudo bash install-caddy.sh   (it opens/closes these ports)."
    else
        print_info "Not enabled. Run install-caddy.sh to serve the dashboard over HTTPS;"
        print_info "it opens 80/443 itself. The firewall no longer toggles them here."
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
# vpn_active -- wg0 is up, or ENABLE_VPN=true in .node-meta. A duplicated
# ENABLE_VPN counts as not active (no overlay rule is added) and is reported.
vpn_active() {
    local v
    ip link show wg0 >/dev/null 2>&1 && return 0
    v="$(addon_meta_get ENABLE_VPN false)" || return 1
    [[ "$v" == "true" ]]
}

# fw_is_testnet -- this host runs a testnet node (gates the add-on menu item).
fw_is_testnet() {
    [[ "${NETWORK:-}" == "testnet" ]]
}

# =============================================================================
# DESIRED-STATE / DRIFT
#
# One source of truth for "what ports SHOULD be open on THIS node", derived from
# the node type, VPN state and Caddy state. Shared by view_status (CLI) and the
# JSON status the dashboard renders, so both report the same expected-vs-actual.
# =============================================================================

# caddy_managed_active -- 0 (true) when OUR Caddy reverse proxy is the active web
# server and owns 80/443. Distinguishes a Telcoin-managed Caddyfile (carries our
# marker) from a foreign one. 443 is owned by Caddy now, so the firewall treats
# 80/443 as "expected open" only when this is true.
caddy_managed_active() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl is-active --quiet caddy 2>/dev/null || return 1
    [[ -f "$FW_CADDYFILE" ]] || return 1
    grep -q "Managed by the Telcoin Node Manager" "$FW_CADDYFILE" 2>/dev/null
}

# caddy_serves_public_edge -- 0 (true) when Caddy fronts the public RPC and/or dashboard
# here, so every enable (plain or --reset) must allow 80/443. Detects the managed Caddyfile
# the way install-caddy.sh writes it (our marker as the FIRST line, or a tn-rpc /
# tn-dashboard fence per vhost) with Caddy installed. Unlike caddy_managed_active it
# additionally requires `caddy` on PATH and does not look at the service state, so an
# enable while Caddy is briefly down/restarting cannot close the edge. The marker only
# counts on line 1, so an operator's own Caddyfile that merely mentions the phrase in a
# comment is not treated as ours. Deliberately NOT "caddy is active" alone: after
# install-caddy.sh disables the last vhost Caddy keeps running on a disabled stub (no
# marker), and a foreign Caddy config is a custom rule that --reset is documented to wipe.
caddy_serves_public_edge() {
    command -v caddy >/dev/null 2>&1 || return 1
    local first_line
    first_line="$(head -n 1 "$FW_CADDYFILE" 2>/dev/null || true)"
    [[ "$first_line" == *"Managed by the Telcoin Node Manager"* ]] && return 0
    grep -qF -e "# >>> tn-rpc >>>" -e "# >>> tn-dashboard >>>" "$FW_CADDYFILE" 2>/dev/null
}

# desired_firewall_rules -- print the rule set THIS host should have, one per line:
#   <spec>\t<label>\t<source>
# <spec> is "<port>/<proto>" or the literal "overlay-ssh"; <source> is a hint
# (anywhere|restricted|<cidr>). Node P2P (one rule per fw_p2p_ports line) on every
# install; overlay SSH only when the VPN is active; 80/443 only when Caddy manages
# the dashboard.
desired_firewall_rules() {
    local ssh_port has_node=false p2p port label nworkers
    ssh_port="$(get_ssh_port)"
    if tn_resolve_service >/dev/null 2>&1; then
        has_node=true
    fi

    local ssh_src
    ssh_src="$(fw_sources ssh 2>/dev/null | paste -sd, -)" || ssh_src=""
    printf '%s\t%s\t%s\n' "${ssh_port}/tcp"         "SSH"                "${ssh_src:-anywhere}"
    if is_testnet_like; then
        printf '%s\t%s\t%s\n' "${UPTIME_KUMA_PORT}/tcp" "Uptime Kuma health" "restricted"
    fi
    if [[ "$has_node" == "true" ]]; then
        p2p="$(fw_p2p_ports)"
        nworkers="$(grep -c ' worker-' <<< "$p2p" || true)"
        while read -r port label; do
            [[ -n "$port" ]] || continue
            printf '%s\t%s\t%s\n' "${port}/udp" "Node P2P ($(fw_p2p_what "$label" "$nworkers"))" "anywhere"
        done <<< "$p2p"
    fi
    if vpn_active; then
        printf '%s\t%s\t%s\n' "overlay-ssh" "SSH from WireGuard overlay" "${TN_OVERLAY_ADMIN_CIDR}"
    fi
    if caddy_managed_active; then
        printf '%s\t%s\t%s\n' "80/tcp"  "Caddy HTTP (ACME)"       "anywhere"
        printf '%s\t%s\t%s\n' "443/tcp" "Caddy HTTPS (dashboard)" "anywhere"
    fi
}

# fw_rule_satisfied <spec> -- 0 if the live ufw config already provides <spec>.
# kuma counts as satisfied when restricted OR anywhere (just not closed); overlay
# SSH is matched on the overlay CIDR.
fw_rule_satisfied() {
    local spec="$1"
    case "$spec" in
        overlay-ssh)
            ufw status 2>/dev/null | grep -F "$TN_OVERLAY_ADMIN_CIDR" | grep -q ALLOW ;;
        "${UPTIME_KUMA_PORT}/tcp")
            [[ "$(kuma_rule_state)" != "closed" ]] ;;
        */tcp|*/udp)
            ufw_has_allow "${spec%/*}" "${spec#*/}" ;;
        *) return 1 ;;
    esac
}

# fw_unexpected_rules -- print managed ports OPEN but NOT desired here, one per
# line "<spec>\t<reason>": 80/443 open without Caddy managing them (now that Caddy
# owns 443). Node P2P (fw_p2p_ports) is desired on every install, so it is never
# flagged here.
fw_unexpected_rules() {
    if ! caddy_managed_active; then
        ufw_has_allow 443 tcp && printf '%s\t%s\n' "443/tcp" "open but Caddy is not managing it"
        ufw_has_allow 80  tcp && printf '%s\t%s\n' "80/tcp"  "open but Caddy is not managing it"
    fi
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
    if ufw status 2>/dev/null | grep -qF "${TN_OVERLAY_CIDR}"; then
        print_warn "Overlay SSH: allowed from the whole overlay ${TN_OVERLAY_CIDR}; option 1 narrows it to ${TN_OVERLAY_ADMIN_CIDR}."
    elif ufw status 2>/dev/null | grep -qF "${TN_OVERLAY_ADMIN_CIDR}"; then
        print_ok "Overlay SSH: allowed from ${TN_OVERLAY_ADMIN_CIDR}"
    else
        print_info "Overlay SSH: not allowed"
        vpn_active && print_warn "VPN is active but overlay SSH is missing -- option 1 restores core-team access."
    fi
    echo ""
    echo "  1) Allow SSH from the maintainer overlay range (${TN_OVERLAY_ADMIN_CIDR})"
    echo "  2) Restrict health port ${UPTIME_KUMA_PORT}/tcp to the Association monitor (${TN_KUMA_SRC})"
    echo "  3) Remove the overlay SSH allowance"
    echo "  4) Back"
    echo ""
    print_info "To allow your OWN monitoring hosts on ${UPTIME_KUMA_PORT}/tcp, use main menu -> Manage node ports."
    echo ""
    local c; read -r -p "  Enter choice [1-4]: " c
    case "$c" in
        1) allow_overlay_ssh &>/dev/null && print_ok "Allowed SSH from ${TN_OVERLAY_ADMIN_CIDR}" ;;
        2) apply_kuma_rule  &>/dev/null && print_ok "Restricted ${UPTIME_KUMA_PORT}/tcp to ${TN_KUMA_SRC}" ;;
        3)
            vpn_active && print_warn "VPN is active -- removing overlay SSH cuts off Association admin access."
            if confirm "Remove the overlay SSH allowance (${TN_OVERLAY_ADMIN_CIDR} -> ${ssh_port})?"; then
                ufw delete allow from "${TN_OVERLAY_CIDR}" to any port "${ssh_port}" proto tcp &>/dev/null || true
                ufw delete allow from "${TN_OVERLAY_ADMIN_CIDR}" to any port "${ssh_port}" proto tcp &>/dev/null \
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
# Scope is deliberately narrow: read-only STATUS, open/close for ONLY the three
# node ports below, and a lockout-safe ENABLE that applies the FIXED recommended
# defaults (it cannot set arbitrary rules, change SSH/password/root policy, or
# disable the firewall -- SSH + overlay + kuma are pre-allowed before enable, so it
# still can never lock an operator out).
#
#   firewall-setup.sh --json --status
#   firewall-setup.sh --json --enable                         (recommended lockout-safe defaults)
#   firewall-setup.sh --json --port <port>/<proto> <on|off>   (node ports only)
# =============================================================================

# The only ports the UI is allowed to toggle. 49590/49594 udp = node P2P,
# 43174/tcp = Uptime Kuma health endpoint. Anything else is refused. These are
# also the keys of the status "ports" object; the node's actual P2P ports, which
# differ on a node set up with other ports or more workers, are reported in
# "p2p_ports" (fw_p2p_ports) and opened by --enable.
readonly -a JSON_NODE_PORTS=( "49590/udp" "49594/udp" "${UPTIME_KUMA_PORT}/tcp" )

# Set by main for a --json run. JSON_DONE_SENT records that the final answer went out
# (the status object, or a done event), so fw_on_exit never adds a second one;
# JSON_LAST_ERROR is the last error event, which fw_on_exit repeats.
JSON_MODE=false
JSON_DONE_SENT=false
JSON_LAST_ERROR=""

json_setup_fds() {
    exec 3>&1   # fd3 = original stdout: JSON is written here
    exec 1>&2   # stdout now aliases stderr: print_*/ufw output is benign noise
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/ }"; s="${s//$'\r'/ }"; s="${s//$'\t'/ }"
    printf '%s' "$s"
}

json_emit() {
    case "$1" in
        '{"event":"done"'*) JSON_DONE_SENT=true ;;
    esac
    printf '%s\n' "$1" >&3
}
json_event() {
    if [[ "$1" == "error" ]]; then
        JSON_LAST_ERROR="${2:-}"
    fi
    json_emit "{\"event\":\"${1}\",\"msg\":\"$(json_escape "${2:-}")\"}"
}

# fw_on_exit -- the EXIT trap of a --json run, installed by main right after the fd
# swap. When the run ends without its final answer (a failing command under set -e,
# not root), send {"event":"done","ok":false,"error":...,"msg":...} with the last
# error event's message, so every --json run ends with one parseable answer; the
# "error" key is what the UI's firewall card shows when status is unavailable.
fw_on_exit() {
    local rc=$? msg
    if [[ -n "${TN_UPDATE_LOCK_KIND:-}" ]]; then
        tn_release_update_lock 2>/dev/null || true
    fi
    if [[ "$JSON_MODE" == "true" && "$JSON_DONE_SENT" != "true" ]]; then
        msg="$JSON_LAST_ERROR"
        if [[ -z "$msg" ]]; then
            msg="firewall-setup.sh stopped before reporting a result (exit ${rc}); the reason is on its stderr."
        fi
        json_emit "{\"event\":\"done\",\"ok\":false,\"error\":\"$(json_escape "$msg")\",\"msg\":\"$(json_escape "$msg")\"}" 2>/dev/null || true
    fi
    return "$rc"
}

# Single-object status: installed/active, default inbound policy, ssh port (read
# only -- shown for context, never changed), the open/closed state of each
# JSON_NODE_PORTS port, and "p2p_ports": one object per fw_p2p_ports line, in
# order, {"port":49590,"proto":"udp","label":"primary","allowed":true}, where
# allowed is true/false from the ufw rule table, or null when ufw is inactive or
# not installed (the table cannot be read then) or when no node is installed (the
# default ports are listed; nothing is expected to be allowed yet). A default
# policy that cannot be read is "unknown".
json_fw_status() {
    local installed=false active=false default_in="" ssh_port
    if ufw_installed; then installed=true; fi
    if ufw_active;    then active=true;    fi
    if [[ "$active" == "true" ]]; then
        # Real ufw verbose form: "Default: deny (incoming), allow (outgoing), ...". A
        # pattern that finds nothing must not end the run (set -e with pipefail).
        default_in=$(ufw status verbose 2>/dev/null | grep -oE '(deny|allow|reject) \(incoming\)' | awk '{print $1}' | head -1 || true)
        [[ -n "$default_in" ]] || default_in="unknown"
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

    local p2p_json="" pfirst=true plabel allowed has_node=false
    if tn_resolve_service >/dev/null 2>&1; then
        has_node=true
    fi
    while read -r port plabel; do
        [[ -n "$port" ]] || continue
        allowed=null
        if [[ "$active" == "true" && "$has_node" == "true" ]]; then
            if ufw_has_allow "$port" udp; then allowed=true; else allowed=false; fi
        fi
        [[ "$pfirst" == "true" ]] || p2p_json+=","
        p2p_json+="{\"port\":${port},\"proto\":\"udp\",\"label\":\"$(json_escape "$plabel")\",\"allowed\":${allowed}}"
        pfirst=false
    done < <(fw_p2p_ports)

    # Desired-state manifest + drift (single source of truth: desired_firewall_rules).
    # Computed only when active; otherwise empty (nothing is enforced).
    local desired_json="" unexpected_json="" caddy_managed=false
    if [[ "$active" == "true" ]]; then
        caddy_managed_active && caddy_managed=true
        local dfirst=true dspec dlabel dsource dok
        while IFS=$'\t' read -r dspec dlabel dsource; do
            [[ -n "$dspec" ]] || continue
            if fw_rule_satisfied "$dspec"; then dok=true; else dok=false; fi
            [[ "$dfirst" == "true" ]] || desired_json+=","
            desired_json+="{\"spec\":\"$(json_escape "$dspec")\",\"label\":\"$(json_escape "$dlabel")\",\"source\":\"$(json_escape "$dsource")\",\"ok\":${dok}}"
            dfirst=false
        done < <(desired_firewall_rules)

        local ufirst=true uspec ureason
        while IFS=$'\t' read -r uspec ureason; do
            [[ -n "$uspec" ]] || continue
            [[ "$ufirst" == "true" ]] || unexpected_json+=","
            unexpected_json+="{\"spec\":\"$(json_escape "$uspec")\",\"reason\":\"$(json_escape "$ureason")\"}"
            ufirst=false
        done < <(fw_unexpected_rules)
    fi

    local kuma_state="closed"
    [[ "$active" == "true" ]] && kuma_state="$(kuma_rule_state)"

    # Operator-chosen health sources (layered on top of the TA baseline), as a JSON array.
    local kuma_extra_json="" efirst=true esrc
    for esrc in $(kuma_extra_list); do
        [[ "$efirst" == "true" ]] || kuma_extra_json+=","
        kuma_extra_json+="\"$(json_escape "$esrc")\""
        efirst=false
    done

    json_emit "{\"installed\":${installed},\"active\":${active},\"default_incoming\":\"$(json_escape "${default_in}")\",\"ssh_port\":\"$(json_escape "${ssh_port}")\",\"kuma\":\"$(json_escape "${kuma_state}")\",\"kuma_extra\":[${kuma_extra_json}],\"caddy_managed\":${caddy_managed},\"desired\":[${desired_json}],\"unexpected\":[${unexpected_json}],\"ports\":{${ports_json}},\"p2p_ports\":[${p2p_json}]}"
    JSON_DONE_SENT=true
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
            is_testnet_like || { json_emit "{\"event\":\"done\",\"ok\":false,\"msg\":\"the health port is a testnet-only add-on and stays closed on this network\"}"; return 1; }
            # The health port must NEVER be open to the world: source-restrict it to the
            # Association monitor (TN_KUMA_SRC) instead of `ufw allow 43174/tcp` (Anywhere).
            apply_kuma_rule >/dev/null 2>&1 || { json_emit "{\"event\":\"done\",\"ok\":false,\"msg\":\"ufw allow failed for $(json_escape "$spec")\"}"; return 1; }
        else
            fw_load_p2p_srcs 2>/dev/null || { json_emit "{\"event\":\"done\",\"ok\":false,\"msg\":\"P2P_ALLOW_FROM in .node-meta cannot be read\"}"; return 1; }
            if [[ ${#FW_P2P_SRCS[@]} -gt 0 ]]; then
                json_emit "{\"event\":\"done\",\"ok\":false,\"msg\":\"the P2P ports are limited to P2P_ALLOW_FROM; run firewall-setup.sh --enable on the server to apply that list\"}"
                return 1
            fi
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

# Enable ufw non-interactively with the recommended lockout-safe defaults (automation /
# scripted node bring-up). Applies the SAME fixed ruleset as the interactive enable -- it
# cannot set arbitrary rules or disable SSH, and SSH + overlay + kuma are pre-allowed before
# enable, so it preserves the "can never lock an operator out" guarantee. 80/443 are allowed
# here only when Caddy already serves the public RPC/dashboard (caddy_serves_public_edge);
# otherwise install-caddy.sh (this repo) adds them when it enables that access.
json_fw_enable() {
    local ssh_port active=false rc
    if ! ufw_installed; then
        fw_try "apt-get install -y ufw" apt-get install -y ufw || return 1
    fi
    ssh_port=$(get_ssh_port)
    fw_meta_lock || return 1
    rc=0
    apply_recommended_firewall || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        if ufw_active; then
            active=true
        fi
        json_emit "{\"event\":\"done\",\"ok\":false,\"action\":\"enable\",\"rc\":${rc},\"ssh_port\":\"$(json_escape "${ssh_port}")\",\"active\":${active},\"msg\":\"$(json_escape "${JSON_LAST_ERROR:-A firewall rule could not be added.}")\"}"
        return "$rc"
    fi
    if fw_wants_meta_write; then
        fw_persist_sources || true
    fi
    ufw_active && active=true
    json_emit "{\"event\":\"done\",\"ok\":${active},\"action\":\"enable\",\"ssh_port\":\"$(json_escape "${ssh_port}")\",\"active\":${active},\"msg\":\"ufw enabled with recommended lockout-safe defaults (SSH + overlay + kuma pre-allowed)\"}"
}

# =============================================================================
# MAIN
# =============================================================================

# fw_load_network -- set NETWORK from .node-meta ("" when no node is installed).
# rc 1 when the key is set more than once.
fw_load_network() {
    local n
    if ! n="$(addon_meta_get NETWORK 2>/dev/null)"; then
        fw_error "NETWORK is set more than once in .node-meta; remove the extra lines and run this again."
        return 1
    fi
    NETWORK="$n"
}

main() {
    local json_mode=false action="" fw_port="" fw_state="" reset_mode=false rc
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)   json_mode=true; shift ;;
            --status) action="status"; shift ;;
            --enable) action="enable"; shift ;;
            --reset)  reset_mode=true; shift ;;
            --port)   action="port"; fw_port="${2:-}"; fw_state="${3:-}"
                      shift; [[ $# -gt 0 ]] && shift; [[ $# -gt 0 ]] && shift ;;
            --ssh-from)     FW_SSH_FROM="${2:-}"; shift; [[ $# -gt 0 ]] && shift ;;
            --ssh-from=*)   FW_SSH_FROM="${1#*=}"; shift ;;
            --p2p-from)     FW_P2P_FROM="${2:-}"; shift; [[ $# -gt 0 ]] && shift ;;
            --p2p-from=*)   FW_P2P_FROM="${1#*=}"; shift ;;
            --ssh-anywhere) FW_SSH_ANYWHERE=true; shift ;;
            --p2p-anywhere) FW_P2P_ANYWHERE=true; shift ;;
            *) shift ;;
        esac
    done
    if [[ -n "$FW_SSH_FROM" && "$FW_SSH_ANYWHERE" == "true" ]] || [[ -n "$FW_P2P_FROM" && "$FW_P2P_ANYWHERE" == "true" ]]; then
        print_error "--ssh-from/--p2p-from and --ssh-anywhere/--p2p-anywhere cannot be combined."
        exit 1
    fi

    if [[ "$json_mode" == "true" ]]; then
        JSON_MODE=true
        json_setup_fds
        # The update lock (taken only when a source list is stored) must not replace
        # fw_on_exit; fw_on_exit releases it.
        TN_EXIT_TRAP_OWNED=1
        trap fw_on_exit EXIT
        check_root
        fw_load_network || exit 1
        case "$action" in
            status) fw_lib_check; json_fw_status ;;
            enable) fw_lib_check; json_fw_enable ;;
            port)   json_fw_port "$fw_port" "$fw_state" ;;
            *)      json_emit "{\"event\":\"done\",\"ok\":false,\"msg\":\"unknown or missing --json action\"}"; exit 1 ;;
        esac
        exit $?
    fi

    # Non-interactive CLI: --reset (clean slate) or --enable (reconcile) re-apply the
    # lockout-safe recommended defaults. Exit codes are apply_recommended_firewall's.
    if [[ "$reset_mode" == "true" || "$action" == "enable" ]]; then
        check_root
        fw_load_network || exit 1
        fw_lib_check
        fw_meta_lock || exit 1
        if [[ "$reset_mode" == "true" ]]; then
            print_warn "Resetting ufw -- ALL existing rules (including custom ones) will be removed."
            rc=0
            apply_recommended_firewall --reset || rc=$?
        else
            rc=0
            apply_recommended_firewall || rc=$?
        fi
        if [[ "$rc" -ne 0 ]]; then
            exit "$rc"
        fi
        if fw_wants_meta_write; then
            fw_persist_sources || true
        fi
        if [[ "$reset_mode" == "true" ]]; then
            print_ok "Firewall reset to a clean slate and re-enabled with recommended defaults"
        else
            print_ok "Firewall enabled with recommended defaults"
        fi
        exit 0
    fi
    if [[ -n "$FW_SSH_FROM$FW_P2P_FROM" || "$FW_SSH_ANYWHERE" == "true" || "$FW_P2P_ANYWHERE" == "true" ]]; then
        print_error "--ssh-from, --p2p-from, --ssh-anywhere and --p2p-anywhere go with --enable or --reset."
        exit 1
    fi

    check_root
    fw_load_network || exit 1
    main_menu
}

main "$@"
