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
#   telcoin-ui-helper config-set      <observer|validator> <field> <value>
#   telcoin-ui-helper firewall-status
#   telcoin-ui-helper firewall-port   <port>/<proto> <on|off>   (node ports only)
#   telcoin-ui-helper node-remove     <observer|validator> <service|data|keys>
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
REMOVE_SCRIPT="/opt/telcoin-ui-update/remove-node.sh"
# setup-*.sh, same root-owned dir. Config arrives via TN_SETUP_* env vars (and
# the BLS passphrase via TN_BLS_PASSPHRASE) which the server sets and sudoers
# env_keeps -- so the sudoers lines stay fixed-arg and no secret touches argv.
SETUP_OBSERVER_SCRIPT="/opt/telcoin-ui-update/setup-observer.sh"
SETUP_VALIDATOR_SCRIPT="/opt/telcoin-ui-update/setup-validator.sh"

die() { echo "$*" >&2; exit 1; }

# Resolve the wrapper script the node service ExecStart points at, falling back
# to the conventional path. Mirrors server.py's wrapper_path().
wrapper_for() {
    local t="$1"
    local unit="/etc/systemd/system/telcoin-${t}.service"
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
    echo "/opt/telcoin/start-telcoin-${t}.sh"
}

require_type() {
    case "${1:-}" in
        observer|validator) ;;
        *) die "invalid node type: ${1:-<empty>} (expected observer|validator)" ;;
    esac
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
    systemctl restart --no-block "telcoin-${t}" || die "failed to restart telcoin-${t}"
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
    systemctl restart --no-block "telcoin-${t}" || die "failed to restart telcoin-${t}"
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
# Node-remove subcommand -- thin wrapper around remove-node.sh --json. The
# server gates this behind a typed "DELETE" confirmation; --yes is always passed
# here because the helper is only reached after that gate.
# =============================================================================

remove_script_ready() {
    [[ -f "$REMOVE_SCRIPT" ]] || die "remove script not found: $REMOVE_SCRIPT"
}

cmd_node_remove() {
    local t="$1" scope="$2"
    require_type "$t"; remove_script_ready
    case "$scope" in service|data|keys) ;; *) die "invalid scope: $scope (expected service|data|keys)" ;; esac
    exec bash "$REMOVE_SCRIPT" --json --remove "$t" --scope "$scope" --yes
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
    local instance="${TN_SETUP_INSTANCE:-}"
    local ext_primary="${TN_SETUP_EXT_PRIMARY:-}"
    local ext_worker="${TN_SETUP_EXT_WORKER:-}"
    local lis_primary="${TN_SETUP_LIS_PRIMARY:-}"
    local lis_worker="${TN_SETUP_LIS_WORKER:-}"
    local public_ip="${TN_SETUP_PUBLIC_IP:-}"

    # Validate every value before it reaches the setup script.
    case "$network" in testnet|adiri) ;; *) die "invalid network: $network" ;; esac
    case "$method" in source|docker|existing|"") ;; *) die "invalid install method: $method" ;; esac
    case "$passm" in loadcredential|tpm) ;; *) die "invalid passphrase method: $passm" ;; esac
    [[ -z "$addr"      || "$addr"      =~ ^0x[0-9a-fA-F]{40}$ ]]            || die "invalid address"
    [[ -z "$build_ref" || "$build_ref" =~ ^[A-Za-z0-9._/-]+$ ]]            || die "invalid build ref"
    [[ -z "$image"     || ( "$image"   =~ ^[A-Za-z0-9._/:@-]+$ && "$image" == *:* ) ]] || die "invalid docker image"
    [[ -z "$instance"  || "$instance"  =~ ^[1-9]$ ]]                       || die "invalid instance"
    local m
    for m in "$ext_primary" "$ext_worker" "$lis_primary" "$lis_worker"; do
        [[ -z "$m" || "$m" =~ ^/(ip4|ip6)/[^/]+/udp/[0-9]+/quic-v1$ ]] || die "invalid multiaddr: $m"
    done
    [[ -z "$public_ip" || "$public_ip" =~ ^[0-9a-fA-F.:]+$ ]] || die "invalid public ip"

    local -a args=( --json "--phase=${phase}" --network "$network" --passphrase-method "$passm" )
    [[ -n "$method" ]]      && args+=( --install-method "$method" )
    [[ -n "$addr" ]]        && args+=( --address "$addr" )
    [[ -n "$build_ref" ]]   && args+=( --build-ref "$build_ref" )
    [[ -n "$image" ]]       && args+=( --docker-image "$image" )
    [[ -n "$instance" ]]    && args+=( --instance "$instance" )
    [[ -n "$ext_primary" ]] && args+=( --external-primary "$ext_primary" )
    [[ -n "$ext_worker" ]]  && args+=( --external-worker "$ext_worker" )
    [[ -n "$lis_primary" ]] && args+=( --listener-primary "$lis_primary" )
    [[ -n "$lis_worker" ]]  && args+=( --listener-worker "$lis_worker" )
    [[ -n "$public_ip" ]]   && args+=( --public-ip "$public_ip" )

    exec bash "$script" "${args[@]}"
}

cmd_setup_keygen()   { cmd_setup keygen   "$1"; }
cmd_setup_finalize() { cmd_setup finalize "$1"; }

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
        config-set)      shift; cmd_config_set "${1:-}" "${2:-}" "${3:-}" ;;
        firewall-status) cmd_firewall_status ;;
        firewall-port)   shift; cmd_firewall_port "${1:-}" "${2:-}" ;;
        node-remove)     shift; cmd_node_remove "${1:-}" "${2:-}" ;;
        setup-keygen)    shift; cmd_setup_keygen   "${1:-}" ;;
        setup-finalize)  shift; cmd_setup_finalize "${1:-}" ;;
        *) die "unknown subcommand: ${sub:-<empty>}" ;;
    esac
}

main "$@"
