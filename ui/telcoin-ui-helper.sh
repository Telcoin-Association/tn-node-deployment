#!/usr/bin/env bash
#
# telcoin-ui-helper -- privileged helper for the Telcoin Node Manager UI.
#
# Installed to /usr/local/sbin/telcoin-ui-helper (root:root, 0755, NOT writable
# by the telcoin-ui service user). This is the SINGLE privileged entry point the
# UI is allowed to invoke via sudo. Every privileged observability operation
# (managing the Jaeger container, editing the tel-owned node wrapper script,
# restarting the node service) goes through here so the sudoers whitelist can
# pin one binary with explicit, no-wildcard argument lines.
#
# Usage:
#   telcoin-ui-helper jaeger-start
#   telcoin-ui-helper jaeger-stop
#   telcoin-ui-helper jaeger-status
#   telcoin-ui-helper tracing-enable  <observer|validator>
#   telcoin-ui-helper tracing-disable <observer|validator>
#   telcoin-ui-helper update-check    <observer|validator>
#   telcoin-ui-helper update-prepare  <observer|validator> <ref>
#   telcoin-ui-helper update-apply    <observer|validator>
#   telcoin-ui-helper update-discard  <observer|validator>
#   telcoin-ui-helper restart-count   <observer|validator>
#   telcoin-ui-helper log-clear       <observer|validator>
#   telcoin-ui-helper config-set      <observer|validator> <field> <value>
#   telcoin-ui-helper set-hostname    <observer|validator> <name>
#   telcoin-ui-helper set-logrotate   <size e.g. 1G>
#   telcoin-ui-helper caddy-status
#   telcoin-ui-helper caddy-dns-check <domain> [inbound-public-ip]
#   telcoin-ui-helper caddy-enable    <domain> <username> [inbound-public-ip]   (password via TN_CADDY_PASSWORD)
#   telcoin-ui-helper caddy-disable
#   telcoin-ui-helper firewall-status
#   telcoin-ui-helper firewall-port   <port>/<proto> <on|off>   (node ports only)
#   telcoin-ui-helper addons-status   <observer|validator>      (read-only)
#   telcoin-ui-helper docker-detect
#   telcoin-ui-helper docker-status    <container>
#   telcoin-ui-helper docker-logs      <container> [lines]
#   telcoin-ui-helper docker-logs-full <container>
#   telcoin-ui-helper docker-node-info <container>
#   telcoin-ui-helper docker-stats     <container>
#   telcoin-ui-helper docker-log-size  <container>
#   telcoin-ui-helper internal-ip
#
set -euo pipefail

JAEGER_NAME="jaeger"
JAEGER_IMAGE="jaegertracing/all-in-one:latest"
TRACING_URL="http://127.0.0.1:4317"

# update-node.sh + its lib/ are shipped here (root-owned) by install-ui.sh so the
# helper can drive updates without reaching into any user-writable location.
UPDATE_SCRIPT="/opt/telcoin-ui-update/update-node.sh"
# edit-config.sh is shipped to the same root-owned dir so config edits run the
# CLI's own --json mode rather than re-implementing unit-file editing here.
CONFIG_SCRIPT="/opt/telcoin-ui-update/edit-config.sh"
# firewall-setup.sh + remove-node.sh, same root-owned dir, same --json pattern.
FIREWALL_SCRIPT="/opt/telcoin-ui-update/firewall-setup.sh"
# setup-*.sh, same root-owned dir. Config arrives via TN_SETUP_* env vars (and
# the BLS passphrase via TN_BLS_PASSPHRASE) which the server sets and sudoers
# env_keeps -- so the sudoers lines stay fixed-arg and no secret touches argv.
SETUP_OBSERVER_SCRIPT="/opt/telcoin-ui-update/setup-observer.sh"
SETUP_VALIDATOR_SCRIPT="/opt/telcoin-ui-update/setup-validator.sh"

die() { echo "$*" >&2; exit 1; }

# Resolve the systemd unit BASE name for this node. New installs use the unified
# `telcoin` unit (no role suffix; node type lives in /etc/telcoin/.node-meta);
# legacy installs use the per-role telcoin-<role> unit. Prefer the unified unit
# when present, then the legacy per-role unit, else default to the unified name
# (the new-install happy path). Mirrors lib/fallback.sh's tn_resolve_service --
# inlined as a probe here because fallback.sh is not shipped beside this
# standalone helper (/usr/local/sbin/telcoin-ui-helper).
service_for() {
    local t="$1"
    if [[ -f /etc/systemd/system/telcoin.service ]]; then
        echo "telcoin"; return 0
    fi
    if [[ -f "/etc/systemd/system/telcoin-${t}.service" ]]; then
        echo "telcoin-${t}"; return 0
    fi
    echo "telcoin"
}

# Resolve the active .node-meta path for type <t>: the unified install
# (/etc/telcoin/.node-meta) is checked first, then the legacy per-role path. Both
# setup scripts write the meta; new installs put it at /etc/telcoin, legacy installs
# under /etc/telcoin/<type>. Inlined here (mirrors lib/fallback.sh) because this
# standalone helper does not ship fallback.sh beside it.
meta_path_for() {
    local t="$1"
    if [[ -f /etc/telcoin/.node-meta ]]; then
        echo "/etc/telcoin/.node-meta"
    else
        echo "/etc/telcoin/${t}/.node-meta"
    fi
}

# Resolve the wrapper script the node service ExecStart points at, falling back
# to the conventional path. Mirrors server.py's wrapper_path().
wrapper_for() {
    local t="$1" svc
    svc="$(service_for "$t")"
    local unit="/etc/systemd/system/${svc}.service"
    if [[ -f "$unit" ]]; then
        local exec_line
        exec_line="$(grep -m1 '^ExecStart=' "$unit" 2>/dev/null || true)"
        local path="${exec_line#ExecStart=}"
        path="${path%% *}"
        if [[ "$path" == *.sh && -f "$path" ]]; then
            echo "$path"
            return 0
        fi
    fi
    echo "/opt/telcoin/start-${svc}.sh"
}

require_type() {
    case "${1:-}" in
        observer|validator) ;;
        *) die "invalid node type: ${1:-<empty>} (expected observer|validator)" ;;
    esac
}

# Validate a docker container name before it reaches `docker`. Docker's own name
# charset is [A-Za-z0-9][A-Za-z0-9_.-]*; reject anything else so a bad arg dies
# cleanly here rather than reaching the daemon.
require_container() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
        || die "invalid container name: ${1:-<empty>}"
}

# Resolve a node's main log file from its unit (StandardOutput=append:<path>),
# falling back to the conventional path. Mirrors server.py parse_service_file.
log_path_for() {
    local t="$1" svc p=""
    svc="$(service_for "$t")"
    local unit="/etc/systemd/system/${svc}.service"
    if [[ -f "$unit" ]]; then
        p="$(grep -m1 '^StandardOutput=append:' "$unit" 2>/dev/null | sed 's/^StandardOutput=append://' || true)"
    fi
    [[ -n "$p" ]] || p="/var/log/telcoin/${svc}.log"
    echo "$p"
}

# Truncate (NOT delete) the node's log file, preserving the inode so the running
# service keeps writing to the same handle. Restricted to /var/log/telcoin/*.log.
cmd_log_clear() {
    local t="$1"; require_type "$t"
    local logf
    logf="$(log_path_for "$t")"
    case "$logf" in
        /var/log/telcoin/*.log) ;;
        *) die "refusing to clear non-standard log path: $logf" ;;
    esac
    [[ -f "$logf" ]] || die "log file not found: $logf"
    : > "$logf" 2>/dev/null || die "could not truncate $logf"
    echo "ok"
}

jaeger_state() {
    # Prints: running | stopped | absent
    if ! command -v docker >/dev/null 2>&1; then
        echo "absent"; return 0
    fi
    local running
    if running="$(docker inspect -f '{{.State.Running}}' "$JAEGER_NAME" 2>/dev/null)"; then
        [[ "$running" == "true" ]] && echo "running" || echo "stopped"
    else
        echo "absent"
    fi
}

cmd_jaeger_start() {
    command -v docker >/dev/null 2>&1 || die "docker not installed"
    local state
    state="$(jaeger_state)"
    case "$state" in
        running) echo "already running" ;;
        stopped) docker start "$JAEGER_NAME" >/dev/null || die "failed to start existing jaeger container" ;;
        absent)
            docker run -d --name "$JAEGER_NAME" --restart unless-stopped \
                -p 16686:16686 -p 4317:4317 "$JAEGER_IMAGE" >/dev/null \
                || die "failed to create jaeger container"
            ;;
    esac
    echo "ok"
}

cmd_jaeger_stop() {
    command -v docker >/dev/null 2>&1 || die "docker not installed"
    if [[ "$(jaeger_state)" == "running" ]]; then
        docker stop "$JAEGER_NAME" >/dev/null || die "failed to stop jaeger container"
    fi
    echo "ok"
}

cmd_jaeger_status() {
    jaeger_state
}

cmd_tracing_enable() {
    local t="$1"
    require_type "$t"
    local wrapper
    wrapper="$(wrapper_for "$t")"
    [[ -f "$wrapper" ]] || die "wrapper script not found: $wrapper"

    cp -p "$wrapper" "${wrapper}.bak.$(date +%s)" || die "failed to back up wrapper"

    if grep -q -- '--tracing-url' "$wrapper"; then
        echo "already enabled"
    else
        # Insert the tracing flags immediately after the `telcoin-network node`
        # token on the exec line. Anchored to the exec line so single-line and
        # backslash-continued multi-line wrappers are both handled.
        sed -i -E \
            "s#(^exec .*telcoin-network node)#\1 --tracing-url ${TRACING_URL} --node-name telcoin-${t}#" \
            "$wrapper" || die "failed to edit wrapper"
        grep -q -- '--tracing-url' "$wrapper" || die "tracing flags not inserted (no matching exec line?)"
    fi

    # Non-blocking: the durable change is the wrapper edit above. --no-block
    # returns as soon as the restart job is queued, so the caller never waits on
    # the node's stop window (TimeoutStopSec up to 90s). Fires only if enqueue fails.
    local svc; svc="$(service_for "$t")"
    systemctl restart --no-block "$svc" || die "failed to restart $svc"
    echo "ok"
}

cmd_tracing_disable() {
    local t="$1"
    require_type "$t"
    local wrapper
    wrapper="$(wrapper_for "$t")"
    [[ -f "$wrapper" ]] || die "wrapper script not found: $wrapper"

    cp -p "$wrapper" "${wrapper}.bak.$(date +%s)" || die "failed to back up wrapper"

    # Strip ` --tracing-url <nonspace>` and ` --node-name <nonspace>` wherever
    # they appear on the exec line. No-op if already absent.
    sed -i -E \
        -e 's# --tracing-url[[:space:]]+[^[:space:]\\]+##g' \
        -e 's# --node-name[[:space:]]+[^[:space:]\\]+##g' \
        "$wrapper" || die "failed to edit wrapper"

    # Non-blocking: the durable change is the wrapper edit above. --no-block
    # returns as soon as the restart job is queued, so the caller never waits on
    # the node's stop window (TimeoutStopSec up to 90s). Fires only if enqueue fails.
    local svc; svc="$(service_for "$t")"
    systemctl restart --no-block "$svc" || die "failed to restart $svc"
    echo "ok"
}

# =============================================================================
# Update subcommands -- thin wrappers around update-node.sh --json. They never
# embed update logic themselves; all the building/swapping/restarting lives in
# update-node.sh. <ref> is validated against a strict tag/branch/commit pattern
# (no wildcards reach the shell).
# =============================================================================

update_script_ready() {
    [[ -f "$UPDATE_SCRIPT" ]] || die "update script not found: $UPDATE_SCRIPT"
}

cmd_update_check() {
    local t="$1"; require_type "$t"; update_script_ready
    exec bash "$UPDATE_SCRIPT" "--${t}" --json --check
}

cmd_update_prepare() {
    local t="$1" ref="$2"
    require_type "$t"; update_script_ready
    [[ -n "$ref" ]] || die "missing ref"
    [[ "$ref" =~ ^[A-Za-z0-9._/-]+$ ]] || die "invalid ref: $ref"
    exec bash "$UPDATE_SCRIPT" "--${t}" --json --prepare --ref "$ref"
}

cmd_update_apply() {
    local t="$1"; require_type "$t"; update_script_ready
    # --yes: in JSON mode this stands in for the interactive typed CONFIRM and is
    # required for validators. The UI shows the downtime warning before calling.
    exec bash "$UPDATE_SCRIPT" "--${t}" --json --apply --yes
}

cmd_update_discard() {
    local t="$1"; require_type "$t"; update_script_ready
    exec bash "$UPDATE_SCRIPT" "--${t}" --json --discard
}

# Count service starts since the current install. The journal for a system unit
# is not readable by the unprivileged telcoin-ui user, so this runs as root via
# the helper. "Since current install" = build-info built_at if present, else the
# node binary's mtime. Prints a single integer (0 on any uncertainty).
cmd_restart_count() {
    local t="$1"; require_type "$t"
    local since=""
    if [[ -f /etc/telcoin/build-info ]]; then
        since="$(grep -E '^built_at=' /etc/telcoin/build-info 2>/dev/null | head -1 | cut -d= -f2- || true)"
        since="${since//T/ }"; since="${since%Z}"
    fi
    if [[ -z "$since" ]]; then
        local binp="/opt/telcoin/telcoin-network"
        if [[ ! -f "$binp" ]]; then
            binp="$(find /usr /opt -name telcoin-network -type f 2>/dev/null | head -1 || true)"
        fi
        if [[ -n "$binp" && -e "$binp" ]]; then
            since="$(stat -c %y "$binp" 2>/dev/null || true)"
        fi
    fi
    if [[ -z "$since" ]]; then
        echo 0; return 0
    fi
    local svc; svc="$(service_for "$t")"
    journalctl -u "$svc" --since "$since" --no-pager 2>/dev/null \
        | grep -c "Started ${svc}.service" || true
}

# =============================================================================
# Config subcommand -- thin wrapper around edit-config.sh --json. The field is
# checked against the editable allowlist and the value against a per-field regex
# HERE before the script runs (edit-config.sh re-validates with its own
# validators). The sudoers line wildcards only the value; field is fixed by this
# allowlist, so a bad field never reaches the script.
# =============================================================================

config_script_ready() {
    [[ -f "$CONFIG_SCRIPT" ]] || die "config script not found: $CONFIG_SCRIPT"
}

cmd_config_set() {
    local t="$1" field="$2" value="$3"
    require_type "$t"; config_script_ready
    [[ -n "$field" ]] || die "missing field"
    [[ -n "$value" ]] || die "missing value"

    # Per-field value validation (first line of defence; edit-config.sh repeats it).
    case "$field" in
        primary_listener|worker_listener)
            [[ "$value" =~ ^/(ip4|ip6)/[^/]+/udp/[0-9]+/quic-v1$ ]] \
                || die "invalid multiaddr: $value" ;;
        instance)
            [[ "$value" =~ ^[1-9]$ ]] || die "invalid instance (1-9): $value" ;;
        metrics)
            [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ]] \
                || die "invalid metrics address (IPv4:PORT): $value" ;;
        verbosity)
            [[ "$value" =~ ^-v{1,5}$ ]] || die "invalid verbosity: $value" ;;
        docker_image)
            [[ "$value" =~ ^[A-Za-z0-9._/:@-]+$ && "$value" == *:* ]] \
                || die "invalid docker image: $value" ;;
        *)
            die "field not editable: $field" ;;
    esac

    exec bash "$CONFIG_SCRIPT" "--${t}" --json --set "${field}=${value}"
}

# Resolve a node's data dir (where network-config + node-info.yaml live) from its
# .node-meta DATA_DIR, falling back to the conventional path.
data_dir_for() {
    local t="$1" meta dd=""
    meta="$(meta_path_for "$t")"
    if [[ -f "$meta" ]]; then
        dd="$(grep -m1 '^DATA_DIR=' "$meta" 2>/dev/null | cut -d= -f2- || true)"
    fi
    if [[ -z "$dd" ]]; then
        [[ -f /etc/telcoin/.node-meta ]] && dd="/var/lib/telcoin" || dd="/var/lib/telcoin/${t}"
    fi
    echo "$dd"
}

# Set the "Advertised Node Name" -- the `hostname` field in the node's
# network-config YAML -- and restart the node so it reads the new value. Name is
# charset-validated here (the server validates too). Mirrors the network-config
# created by the node itself; only the hostname line is touched.
cmd_set_hostname() {
    local t="$1" name="$2"
    require_type "$t"
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "invalid name: ${name:-<empty>}"

    local dd nc
    dd="$(data_dir_for "$t")"
    [[ -d "$dd" ]] || die "data dir not found: $dd"
    nc="${dd}/network-config"

    if [[ -f "$nc" ]]; then
        if grep -qE '^hostname:' "$nc"; then
            sed -i -E "s#^hostname:.*#hostname: \"${name}\"#" "$nc" || die "failed to edit $nc"
        else
            printf 'hostname: "%s"\n' "$name" >> "$nc" || die "failed to append to $nc"
        fi
    else
        # No file yet (node hasn't created it): a minimal file is fine -- the node
        # fills every other field from its serde defaults on read.
        printf 'hostname: "%s"\n' "$name" > "$nc" || die "failed to create $nc"
    fi

    # Keep ownership matching the data dir so the (unprivileged) node can read it.
    local owner
    owner="$(stat -c '%U:%G' "$dd" 2>/dev/null || true)"
    [[ -n "$owner" ]] && chown "$owner" "$nc" 2>/dev/null || true

    # Record in .node-meta as the persistent source of truth (survives data reads
    # and is available if a future version needs it re-applied on each start).
    local meta; meta="$(meta_path_for "$t")"
    if [[ -f "$meta" ]]; then
        sed -i '/^ADVERTISED_NODE_NAME=/d' "$meta" 2>/dev/null || true
        printf 'ADVERTISED_NODE_NAME=%s\n' "$name" >> "$meta"
    fi

    # Restart so the node reads the new network-config. --no-block returns once
    # the restart job is queued (validators have a long stop window).
    local svc; svc="$(service_for "$t")"
    systemctl restart --no-block "$svc" || die "failed to restart $svc"
    echo "ok"
}

# Node-log rotation. One config for both node types (the unit appends to
# /var/log/telcoin/*.log). copytruncate is required: the node holds the log open
# (StandardOutput=append:), so logrotate must copy-then-truncate in place rather
# than rename, or the node keeps writing to the rotated-away inode.
LOGROTATE_CONF="/etc/logrotate.d/telcoin"

write_logrotate_conf() {
    local size="$1"
    cat > "$LOGROTATE_CONF" <<EOF
# Managed by the Telcoin Node Manager. Node logs rotate when they reach 'size'.
/var/log/telcoin/*.log {
    size ${size}
    rotate 3
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
    chmod 644 "$LOGROTATE_CONF"
}

cmd_set_logrotate() {
    local size="$1"
    [[ "$size" =~ ^[0-9]+[KMG]$ ]] || die "invalid size: ${size:-<empty>} (e.g. 500M, 1G)"
    write_logrotate_conf "$size"
    echo "ok"
}

# Delete rotated node logs only (telcoin-*.log.1, telcoin-*.log.2.gz, ...).
# Never the live *.log: the node holds it open via StandardOutput=append:, so
# removing it wouldn't free space until a restart and would break logging. The
# fixed glob can't be steered to a non-standard path, so no path validation is
# needed. Prints the count removed.
cmd_clear_rotated() {
    local n=0 f
    shopt -s nullglob
    for f in /var/log/telcoin/*.log.[0-9]*; do
        [[ -f "$f" ]] && rm -f "$f" && n=$((n+1))
    done
    shopt -u nullglob
    echo "removed ${n}"
}

# =============================================================================
# External dashboard access (Caddy) -- thin wrappers around install-caddy.sh
# --json phases. status/check-dns emit one JSON object; enable/disable stream
# JSON events. The dashboard password arrives via TN_CADDY_PASSWORD (env only --
# env_keep'd by sudoers, never argv/logs), like the BLS passphrase.
# =============================================================================
CADDY_SCRIPT="/opt/telcoin-ui-update/install-caddy.sh"

caddy_script_ready() { [[ -f "$CADDY_SCRIPT" ]] || die "caddy script not found: $CADDY_SCRIPT"; }

cmd_caddy_status() { caddy_script_ready; exec bash "$CADDY_SCRIPT" --json --phase=status; }
cmd_caddy_disable() { caddy_script_ready; exec bash "$CADDY_SCRIPT" --json --phase=disable; }

# The optional trailing public_ip is the node's INBOUND public IP (where ACME hits
# 80/443), forwarded to install-caddy.sh as --public-ip for the multi-IP / 1:1-NAT
# case where it differs from the auto-detected egress IP. Empty = exact no-op (the
# script auto-detects egress, today's behavior). Loose char-class only -- the script
# re-validates semantically via validate_public_ip and falls back to egress on failure.
cmd_caddy_dns_check() {
    local domain="$1" public_ip="${2:-}"; caddy_script_ready
    [[ -n "$domain" && "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid domain: ${domain:-<empty>}"
    [[ -z "$public_ip" || "$public_ip" =~ ^[0-9a-fA-F.:]+$ ]] || die "invalid public ip"
    local -a args=( --json --phase=check-dns --domain "$domain" )
    [[ -n "$public_ip" ]] && args+=( --public-ip "$public_ip" )
    exec bash "$CADDY_SCRIPT" "${args[@]}"
}

cmd_caddy_enable() {
    local domain="$1" username="$2" public_ip="${3:-}"; caddy_script_ready
    [[ -n "$domain" && "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid domain: ${domain:-<empty>}"
    [[ -n "$username" && "$username" =~ ^[A-Za-z0-9._-]{2,32}$ ]] || die "invalid username"
    [[ -z "$public_ip" || "$public_ip" =~ ^[0-9a-fA-F.:]+$ ]] || die "invalid public ip"
    [[ -n "${TN_CADDY_PASSWORD:-}" ]] || die "TN_CADDY_PASSWORD not set"
    local -a args=( --json --phase=enable --domain "$domain" --username "$username" )
    [[ -n "$public_ip" ]] && args+=( --public-ip "$public_ip" )
    exec bash "$CADDY_SCRIPT" "${args[@]}"
}

# =============================================================================
# Firewall subcommands -- thin wrappers around firewall-setup.sh --json. Only
# the three node ports may be toggled; SSH/policy/etc are never reachable here.
# =============================================================================

firewall_script_ready() {
    [[ -f "$FIREWALL_SCRIPT" ]] || die "firewall script not found: $FIREWALL_SCRIPT"
}

cmd_firewall_status() {
    firewall_script_ready
    exec bash "$FIREWALL_SCRIPT" --json --status
}

cmd_firewall_port() {
    local spec="$1" pstate="$2"
    firewall_script_ready
    # Hard allowlist (the script re-checks). 49590/49594 udp = P2P, 43174/tcp = Kuma.
    case "$spec" in
        49590/udp|49594/udp|43174/tcp) ;;
        *) die "port not permitted: $spec" ;;
    esac
    case "$pstate" in on|off) ;; *) die "state must be on|off" ;; esac
    exec bash "$FIREWALL_SCRIPT" --json --port "$spec" "$pstate"
}

# =============================================================================
# Testnet add-ons status -- READ-ONLY. Surfaces the state of the dev team's opt-in
# add-ons (health monitor / centralized logging / VPN admin SSH) for the UI's
# management-side status card. Reads the .node-meta keys their setup scripts write
# (root-only, mode 600) and probes the running services. Mutates nothing; all
# enabling/disabling stays on the CLI (setup-observability.sh / setup-vpn.sh).
# =============================================================================

# Minimal JSON string escaper (this helper has no json lib; values here are simple).
_addons_json_str() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "${s//$'\n'/ }"; }

# Read KEY=value from the node's root-owned .node-meta. Empty when absent.
_addons_meta() {
    local meta="$1" key="$2"
    [[ -f "$meta" ]] || return 0
    grep -E "^${key}=" "$meta" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# Print the raw contents of the node's root-owned (mode 600) .node-meta so the
# unprivileged UI can read it -- it cannot open the file directly. READ-ONLY:
# this only cats an existing metadata file (KEY=VALUE operational data: data dir,
# network, region, addresses -- no secrets; the BLS passphrase is never stored
# here). Empty output (rc 0) when the file is absent.
cmd_meta_cat() {
    local t="$1"; require_type "$t"
    local meta; meta="$(meta_path_for "$t")"
    [[ -f "$meta" ]] && cat "$meta" || true
}

cmd_addons_status() {
    local t="$1"; require_type "$t"
    local meta; meta="$(meta_path_for "$t")"
    local network region hc obs vpn overlay pubkey extra
    network=$(_addons_meta "$meta" NETWORK)
    region=$(_addons_meta "$meta" REGION)
    hc=$(_addons_meta "$meta" ENABLE_HEALTHCHECK_MONITOR)
    obs=$(_addons_meta "$meta" ENABLE_OBSERVABILITY)
    vpn=$(_addons_meta "$meta" ENABLE_VPN)
    overlay=$(_addons_meta "$meta" VPN_OVERLAY_IP)
    pubkey=$(_addons_meta "$meta" VPN_NODE_PUBKEY)
    extra=$(_addons_meta "$meta" KUMA_EXTRA_SRC)
    [[ "$vpn" == "true" || "$vpn" == "pending" ]] || vpn="false"

    # Read-only probes.
    local hc_enabled=false hc_ok=false obs_enabled=false alloy=false wg_up=false wg_hs=false
    [[ "$hc" == "true" ]] && { hc_enabled=true; curl -fsS --max-time 3 "http://127.0.0.1:43174" >/dev/null 2>&1 && hc_ok=true; }
    [[ "$obs" == "true" ]] && { obs_enabled=true; systemctl is-active --quiet telcoin-alloy 2>/dev/null && alloy=true; }
    if [[ "$vpn" == "true" || "$vpn" == "pending" ]]; then
        ip link show wg0 >/dev/null 2>&1 && wg_up=true
        [[ "$wg_up" == "true" ]] && command -v wg >/dev/null 2>&1 && wg show wg0 2>/dev/null | grep -qE 'latest handshake' && wg_hs=true
    fi

    printf '{"network":"%s","region":"%s","health":{"enabled":%s,"responding":%s,"port":43174,"extra_src":"%s"},"logging":{"enabled":%s,"running":%s},"vpn":{"state":"%s","wg_up":%s,"handshake":%s,"overlay_ip":"%s","pubkey":"%s"}}\n' \
        "$(_addons_json_str "$network")" "$(_addons_json_str "$region")" \
        "$hc_enabled" "$hc_ok" "$(_addons_json_str "$extra")" \
        "$obs_enabled" "$alloy" \
        "$(_addons_json_str "$vpn")" "$wg_up" "$wg_hs" \
        "$(_addons_json_str "$overlay")" "$(_addons_json_str "$pubkey")"
}

# =============================================================================
# Setup subcommands -- thin wrappers around setup-<type>.sh --json --phase=...
# Config comes from TN_SETUP_* env (validated here); the BLS passphrase stays in
# TN_BLS_PASSPHRASE (env only, never argv) and is inherited by the exec'd script.
# =============================================================================

cmd_setup() {
    local phase="$1" t="$2"
    require_type "$t"
    local script
    case "$t" in
        observer)  script="$SETUP_OBSERVER_SCRIPT" ;;
        validator) script="$SETUP_VALIDATOR_SCRIPT" ;;
    esac
    [[ -f "$script" ]] || die "setup script not found: $script"

    local network="${TN_SETUP_NETWORK:-testnet}"
    local method="${TN_SETUP_INSTALL_METHOD:-}"
    local passm="${TN_SETUP_PASSPHRASE_METHOD:-loadcredential}"
    local addr="${TN_SETUP_ADDRESS:-}"
    local build_ref="${TN_SETUP_BUILD_REF:-}"
    local image="${TN_SETUP_DOCKER_IMAGE:-}"
    local ext_primary="${TN_SETUP_EXT_PRIMARY:-}"
    local ext_worker="${TN_SETUP_EXT_WORKER:-}"
    local lis_primary="${TN_SETUP_LIS_PRIMARY:-}"
    local lis_worker="${TN_SETUP_LIS_WORKER:-}"
    local public_ip="${TN_SETUP_PUBLIC_IP:-}"
    local rpc_public="${TN_SETUP_RPC_PUBLIC:-false}"
    local svc_user="${TN_SETUP_SERVICE_USER:-}"
    local svc_group="${TN_SETUP_SERVICE_GROUP:-}"
    local adv_name="${TN_SETUP_ADVERTISED_NAME:-}"
    local data_dir="${TN_SETUP_DATA_DIR:-}"

    # Validate every value before it reaches the setup script.
    case "$network" in testnet|adiri) ;; *) die "invalid network: $network" ;; esac
    case "$method" in source|docker|existing|"") ;; *) die "invalid install method: $method" ;; esac
    case "$passm" in loadcredential|tpm) ;; *) die "invalid passphrase method: $passm" ;; esac
    case "$rpc_public" in true|false) ;; *) die "invalid rpc_public: $rpc_public" ;; esac
    [[ -z "$addr"      || "$addr"      =~ ^0x[0-9a-fA-F]{40}$ ]]            || die "invalid address"
    [[ -z "$build_ref" || "$build_ref" =~ ^[A-Za-z0-9._/-]+$ ]]            || die "invalid build ref"
    [[ -z "$image"     || ( "$image"   =~ ^[A-Za-z0-9._/:@-]+$ && "$image" == *:* ) ]] || die "invalid docker image"
    local m
    for m in "$ext_primary" "$ext_worker" "$lis_primary" "$lis_worker"; do
        [[ -z "$m" || "$m" =~ ^/(ip4|ip6)/[^/]+/udp/[0-9]+/quic-v1$ ]] || die "invalid multiaddr: $m"
    done
    [[ -z "$public_ip" || "$public_ip" =~ ^[0-9a-fA-F.:]+$ ]] || die "invalid public ip"
    [[ -z "$svc_user"  || "$svc_user"  =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,31}$ ]] || die "invalid service user"
    [[ -z "$svc_group" || "$svc_group" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,31}$ ]] || die "invalid service group"
    [[ -z "$adv_name"  || "$adv_name"  =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "invalid advertised name"
    [[ -z "$data_dir"  || ( "$data_dir" =~ ^/[A-Za-z0-9._/-]+$ && "$data_dir" != *".."* ) ]] || die "invalid data directory"

    local -a args=( --json "--phase=${phase}" --network "$network" --passphrase-method "$passm" --rpc-public "$rpc_public" )
    [[ -n "$method" ]]      && args+=( --install-method "$method" )
    [[ -n "$addr" ]]        && args+=( --address "$addr" )
    [[ -n "$build_ref" ]]   && args+=( --build-ref "$build_ref" )
    [[ -n "$image" ]]       && args+=( --docker-image "$image" )
    [[ -n "$ext_primary" ]] && args+=( --external-primary "$ext_primary" )
    [[ -n "$ext_worker" ]]  && args+=( --external-worker "$ext_worker" )
    [[ -n "$lis_primary" ]] && args+=( --listener-primary "$lis_primary" )
    [[ -n "$lis_worker" ]]  && args+=( --listener-worker "$lis_worker" )
    [[ -n "$public_ip" ]]   && args+=( --public-ip "$public_ip" )
    [[ -n "$svc_user" ]]    && args+=( --service-user "$svc_user" )
    [[ -n "$svc_group" ]]   && args+=( --service-group "$svc_group" )
    [[ -n "$adv_name" ]]    && args+=( --advertised-name "$adv_name" )
    [[ -n "$data_dir" ]]    && args+=( --data-dir "$data_dir" )

    exec bash "$script" "${args[@]}"
}

cmd_setup_keygen()   { cmd_setup keygen   "$1"; }
cmd_setup_finalize() { cmd_setup finalize "$1"; }

# =============================================================================
# Docker detection subcommands -- READ-ONLY. These let the UI recognise and
# monitor a Telcoin Network node deployed as a dev-team docker container (not
# under systemd). Every one only inspects/reads (docker ps / inspect / logs /
# cat node-info.yaml); none can start, stop, or otherwise mutate a container or
# the host. The container name arg is charset-validated by require_container.
# =============================================================================

# Image substrings that identify a dev-team Telcoin Network container.
DOCKER_TN_IMAGE_RE='us-docker\.pkg\.dev/telcoin-network/tn-public|telcoin-network/tn-public|/tn-public/'

# Print the names of running Telcoin Network containers, one per line. Empty
# output (rc 0) when docker is absent or no matching container runs.
cmd_docker_detect() {
    command -v docker >/dev/null 2>&1 || return 0
    docker ps --no-trunc --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
        | grep -E "$DOCKER_TN_IMAGE_RE" \
        | cut -f1 || true
}

# Full `docker inspect` JSON for one container (a single-element array, as docker
# emits). Used by the server to read State/Config/HostConfig.
cmd_docker_status() {
    local name="$1"; require_container "$name"
    command -v docker >/dev/null 2>&1 || die "docker not installed"
    docker inspect "$name" 2>/dev/null || die "container not found: $name"
}

# Tail the container's stdout/stderr log (combined). Second arg = line count
# (default 100), validated as a bare integer.
cmd_docker_logs() {
    local name="$1" lines="${2:-100}"
    require_container "$name"
    [[ "$lines" =~ ^[0-9]+$ ]] || die "invalid line count: $lines"
    command -v docker >/dev/null 2>&1 || die "docker not installed"
    docker logs --tail "$lines" "$name" 2>&1 || die "could not read logs for $name"
}

# Full container log (no tail limit) -- backs the "Download full log" action.
cmd_docker_logs_full() {
    local name="$1"; require_container "$name"
    command -v docker >/dev/null 2>&1 || die "docker not installed"
    docker logs "$name" 2>&1 || die "could not read logs for $name"
}

# Print the container's node-info.yaml, prefixed with a classifying
# `node_type:` line. The file lives in a host bind-mount; we resolve the first
# bind whose host path holds node-info.yaml.
#
# Node type comes from config, NOT command-line flags (team deployments don't
# pass --validator): a non-empty proof_of_possession field means this node is a
# validator, otherwise it's an observer.
cmd_docker_node_info() {
    local name="$1"; require_container "$name"
    command -v docker >/dev/null 2>&1 || die "docker not installed"
    local binds host b info=""
    binds="$(docker inspect -f '{{range .HostConfig.Binds}}{{println .}}{{end}}' "$name" 2>/dev/null || true)"
    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        host="${b%%:*}"
        if [[ -f "${host}/node-info.yaml" ]]; then
            info="${host}/node-info.yaml"
            break
        fi
    done <<< "$binds"
    [[ -n "$info" ]] || die "node-info.yaml not found for container $name"

    local pop node_type="observer"
    pop="$(grep -m1 -E '^[[:space:]]*proof_of_possession[[:space:]]*:' "$info" 2>/dev/null | cut -d: -f2- || true)"
    pop="$(printf '%s' "$pop" | tr -d '[:space:]')"
    case "$pop" in
        ''|'""'|"''") node_type="observer" ;;
        *)            node_type="validator" ;;
    esac

    echo "node_type: ${node_type}"
    cat "$info"
}

# One-shot resource sample (CPU / mem / net / block IO) for the container. Tab-
# separated so the server can split cleanly. `--no-stream` takes ~1s to sample.
cmd_docker_stats() {
    local name="$1"; require_container "$name"
    command -v docker >/dev/null 2>&1 || die "docker not installed"
    docker stats "$name" --no-stream \
        --format '{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}' 2>/dev/null
}

# Primary internal/LAN IP of the host (first field of `hostname -I`). Shown in
# Node Details for every node type.
cmd_internal_ip() {
    hostname -I | awk '{print $1}'
}

# Size (bytes) of the container's json-file log on the host. The LogPath is
# root-owned, so the stat() must run here. Prints 0 when the file is missing.
cmd_docker_log_size() {
    local name="$1"; require_container "$name"
    command -v docker >/dev/null 2>&1 || die "docker not installed"
    local log_path
    log_path="$(docker inspect "$name" --format='{{.LogPath}}' 2>/dev/null)"
    [[ -n "$log_path" ]] || die "could not determine log path for $name"
    stat -c%s "$log_path" 2>/dev/null || echo 0
}

main() {
    local sub="${1:-}"
    case "$sub" in
        jaeger-start)    cmd_jaeger_start ;;
        jaeger-stop)     cmd_jaeger_stop ;;
        jaeger-status)   cmd_jaeger_status ;;
        tracing-enable)  shift; cmd_tracing_enable "${1:-}" ;;
        tracing-disable) shift; cmd_tracing_disable "${1:-}" ;;
        update-check)    shift; cmd_update_check   "${1:-}" ;;
        update-prepare)  shift; cmd_update_prepare "${1:-}" "${2:-}" ;;
        update-apply)    shift; cmd_update_apply   "${1:-}" ;;
        update-discard)  shift; cmd_update_discard "${1:-}" ;;
        restart-count)   shift; cmd_restart_count "${1:-}" ;;
        log-clear)       shift; cmd_log_clear "${1:-}" ;;
        config-set)      shift; cmd_config_set "${1:-}" "${2:-}" "${3:-}" ;;
        set-hostname)    shift; cmd_set_hostname "${1:-}" "${2:-}" ;;
        set-logrotate)   shift; cmd_set_logrotate "${1:-}" ;;
        clear-rotated)   cmd_clear_rotated ;;
        caddy-status)    cmd_caddy_status ;;
        caddy-dns-check) shift; cmd_caddy_dns_check "${1:-}" "${2:-}" ;;
        caddy-enable)    shift; cmd_caddy_enable "${1:-}" "${2:-}" "${3:-}" ;;
        caddy-disable)   cmd_caddy_disable ;;
        firewall-status) cmd_firewall_status ;;
        firewall-port)   shift; cmd_firewall_port "${1:-}" "${2:-}" ;;
        addons-status)   shift; cmd_addons_status "${1:-}" ;;
        meta-cat)        shift; cmd_meta_cat "${1:-}" ;;
        setup-keygen)    shift; cmd_setup_keygen   "${1:-}" ;;
        setup-finalize)  shift; cmd_setup_finalize "${1:-}" ;;
        docker-detect)    cmd_docker_detect ;;
        docker-status)    shift; cmd_docker_status    "${1:-}" ;;
        docker-logs)      shift; cmd_docker_logs      "${1:-}" "${2:-}" ;;
        docker-logs-full) shift; cmd_docker_logs_full "${1:-}" ;;
        docker-node-info) shift; cmd_docker_node_info "${1:-}" ;;
        docker-stats)     shift; cmd_docker_stats     "${1:-}" ;;
        docker-log-size)  shift; cmd_docker_log_size  "${1:-}" ;;
        internal-ip)      cmd_internal_ip ;;
        *) die "unknown subcommand: ${sub:-<empty>}" ;;
    esac
}

main "$@"
