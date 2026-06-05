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
#
set -euo pipefail

JAEGER_NAME="jaeger"
JAEGER_IMAGE="jaegertracing/all-in-one:latest"
TRACING_URL="http://127.0.0.1:4317"

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

    systemctl restart "telcoin-${t}" || die "failed to restart telcoin-${t}"
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

    systemctl restart "telcoin-${t}" || die "failed to restart telcoin-${t}"
    echo "ok"
}

main() {
    local sub="${1:-}"
    case "$sub" in
        jaeger-start)    cmd_jaeger_start ;;
        jaeger-stop)     cmd_jaeger_stop ;;
        jaeger-status)   cmd_jaeger_status ;;
        tracing-enable)  shift; cmd_tracing_enable "${1:-}" ;;
        tracing-disable) shift; cmd_tracing_disable "${1:-}" ;;
        *) die "unknown subcommand: ${sub:-<empty>}" ;;
    esac
}

main "$@"
