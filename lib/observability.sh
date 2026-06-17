#!/usr/bin/env bash
# =============================================================================
# lib/observability.sh — centralized logging add-on (Grafana Alloy -> Loki).
#
# Sourced by lib/common.sh (so every script gets obs_* + obs_reth_log_flags is
# available to tn_node_launch_flags). Pure function definitions + constants; no
# top-level side effects (it is sourced under the inherited `set -euo pipefail`).
#
# The node writes structured JSON logs to <dir>/telcoin-network-logs/reth.log* and
# Alloy tails + ships them to the central Loki. Two runtimes:
#   docker installs -> Alloy as a docker sidecar (container telcoin-alloy)
#   binary/source   -> native Alloy binary under systemd
# Both are supervised by one systemd unit (telcoin-alloy.service) so status/teardown
# are uniform. The per-operator ingest token lives ONLY in the mode-600 env file.
# See docs/testnet-addons.md.
# =============================================================================

# Version (tracked by update-scripts.sh). Bump when observability/config.alloy or the
# lib/wgvpn bundle changes too, so the updater pulls the testnet-addons bundle alongside.
# Plain (not readonly) so re-sourcing common.sh can't trip on a readonly redefinition.
OBSERVABILITY_VERSION="1.0.0"

# Resolve the checked-in canonical config relative to this lib dir.
__OBS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
OBS_CONFIG_SRC="${__OBS_LIB_DIR}/../observability/config.alloy"

# Layout (remove-node.sh tears these down).
OBS_ETC_DIR="/etc/telcoin/alloy"          # config.alloy + mode-600 env file
OBS_DATA_DIR="/var/lib/telcoin-alloy"     # Alloy WAL / positions
OBS_ALLOY_UNIT="telcoin-alloy.service"
OBS_HTTP_ADDR="127.0.0.1:12345"           # Alloy's own metrics/UI (localhost only)

# Defaults mirror lib/testnet-addons.env for set -u safety if sourced standalone.
: "${OBS_PUSH_URL_TESTNET:=https://obs.adiri.telcoin.network/loki/api/v1/push}"
: "${TN_ALLOY_IMAGE:=grafana/alloy:v1.5.1}"
: "${TN_ALLOY_NATIVE_VERSION:=1.5.1}"
: "${DEFAULT_LOG_DIR:=/var/log/telcoin}"
: "${DEFAULT_DATA_DIR:=/var/lib/telcoin}"
: "${DEFAULT_INSTALL_DIR:=/opt/telcoin}"
: "${SERVICE_USER:=telcoin}"
: "${SERVICE_GROUP:=telcoin}"

# -----------------------------------------------------------------------------
# reth launch flags + identity labels
# -----------------------------------------------------------------------------

# obs_reth_log_flags <docker|binary> — the reth flags that make the node write a
# JSON appender Alloy can tail, as ONE space-joined string. The log dir differs by
# runtime: docker writes the container path /home/nonroot/logs (= host DATA_DIR/logs);
# binary writes the host path /var/log/telcoin. reth appends telcoin-network-logs/ to
# whatever --log.file.directory is given (telcoin-network-cli/src/cli.rs), so the
# config.alloy __path__ (/var/log/telcoin/telcoin-network-logs/reth.log*) matches both:
# the docker sidecar mounts DATA_DIR/logs -> /var/log/telcoin, native reads it directly.
obs_reth_log_flags() {
    local method="${1:-binary}" dir
    if [[ "$method" == "docker" ]]; then
        dir="/home/nonroot/logs"
    else
        dir="${DEFAULT_LOG_DIR}"
    fi
    printf '%s' "--log.file.format json --log.file.directory ${dir} --log.file.max-size 100 --log.file.max-files 5"
}

# obs_image_version — TN_IMAGE_VERSION label, derived locally (no GCP metadata):
# the docker image tag, else /etc/telcoin/build-info, else "unknown".
obs_image_version() {
    local meta img ver
    meta="$(node_meta_path || true)"
    img="$(meta_get DOCKER_IMAGE "$meta" 2>/dev/null || true)"
    if [[ -n "$img" && "$img" == *:* ]]; then echo "${img##*:}"; return 0; fi
    if [[ -f /etc/telcoin/build-info ]]; then
        ver="$(grep -iE '^version=' /etc/telcoin/build-info 2>/dev/null | head -1 | cut -d= -f2 || true)"
        [[ -n "$ver" ]] && { echo "$ver"; return 0; }
    fi
    echo "unknown"
}

# obs_label_sourcing — set the low-cardinality identity labels (globals) for the env
# file. No GCP metadata: node from advertised name/hostname, region + validator address
# from .node-meta (validator address blank for observers), chain fixed to adiri.
obs_label_sourcing() {
    local meta; meta="$(node_meta_path || true)"
    TN_NODE="${ADVERTISED_NAME:-}"
    [[ -n "$TN_NODE" ]] || TN_NODE="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo node)"
    TN_REGION="${REGION:-}"
    [[ -n "$TN_REGION" ]] || TN_REGION="$(meta_get REGION "$meta" 2>/dev/null || true)"
    [[ -n "$TN_REGION" ]] || TN_REGION="unknown"
    # Sanitize operator-supplied labels to a safe Loki charset (avoid cardinality/
    # injection issues on the shared Loki): keep [A-Za-z0-9_-], cap at 32 chars.
    TN_NODE="$(printf '%s' "$TN_NODE" | tr -cd 'A-Za-z0-9_-' | cut -c1-32)"; [[ -n "$TN_NODE" ]] || TN_NODE="node"
    TN_REGION="$(printf '%s' "$TN_REGION" | tr -cd 'A-Za-z0-9_-' | cut -c1-32)"; [[ -n "$TN_REGION" ]] || TN_REGION="unknown"
    TN_VALIDATOR_ADDRESS="$(meta_get VALIDATOR_ADDRESS "$meta" 2>/dev/null || true)"
    TN_CHAIN="adiri"
    TN_IMAGE_VERSION="$(obs_image_version)"
}

# -----------------------------------------------------------------------------
# Config + env-file writers
# -----------------------------------------------------------------------------

# obs_write_config_alloy [dest] — deploy the Alloy config. Primary path COPIES the
# checked-in observability/config.alloy (so the deployed config is byte-identical to
# the canonical, adiri-matching copy — no drift). Falls back to a self-contained,
# functionally-identical heredoc only if that file is somehow missing.
obs_write_config_alloy() {
    local dest="${1:-${OBS_ETC_DIR}/config.alloy}"
    install -d -m 0750 "$(dirname "$dest")"
    if [[ -f "$OBS_CONFIG_SRC" ]]; then
        install -m 0644 "$OBS_CONFIG_SRC" "$dest"
        return 0
    fi
    print_warn "observability/config.alloy missing; writing embedded fallback (functionally identical)."
    cat > "$dest" <<'ALLOY_EOF'
// Fallback copy. Canonical: observability/config.alloy (byte-identical to adiri).
local.file_match "tn_logs" {
  path_targets = [{
    __path__ = "/var/log/telcoin/telcoin-network-logs/reth.log*",
    job      = "telcoin-node",
  }]
}

loki.source.file "tn" {
  targets    = local.file_match.tn_logs.targets
  forward_to = [loki.process.tn.receiver]
}

loki.process "tn" {
  forward_to = [loki.write.central.receiver]

  stage.static_labels {
    values = {
      node              = sys.env("TN_NODE"),
      region            = sys.env("TN_REGION"),
      validator_address = sys.env("TN_VALIDATOR_ADDRESS"),
      chain             = sys.env("TN_CHAIN"),
      image_version     = sys.env("TN_IMAGE_VERSION"),
    }
  }

  stage.json {
    expressions = {
      level     = "level",
      timestamp = "timestamp",
    }
  }

  stage.labels {
    values = {
      level = "",
    }
  }

  stage.timestamp {
    source = "timestamp"
    format = "RFC3339Nano"
  }
}

loki.write "central" {
  endpoint {
    url          = sys.env("OBS_PUSH_URL")
    bearer_token = sys.env("OBS_INGEST_TOKEN")
  }
}
ALLOY_EOF
    chmod 0644 "$dest"
}

# _obs_write_env_file <dest> <token> — mode-600 file with identity labels + push URL +
# ingest token. Consumed by the native unit (EnvironmentFile=) and the docker unit
# (--env-file). The token lives ONLY here (never in git or .node-meta). Created inside
# a umask-077 subshell so it is never briefly world-readable.
_obs_write_env_file() {
    local dest="$1" token="$2"
    obs_label_sourcing
    install -d -m 0750 "$(dirname "$dest")"
    ( umask 077; cat > "$dest" <<EOF
TN_NODE=${TN_NODE}
TN_REGION=${TN_REGION}
TN_VALIDATOR_ADDRESS=${TN_VALIDATOR_ADDRESS}
TN_CHAIN=${TN_CHAIN}
TN_IMAGE_VERSION=${TN_IMAGE_VERSION}
OBS_PUSH_URL=${OBS_PUSH_URL_TESTNET}
OBS_INGEST_TOKEN=${token}
EOF
    )
    chmod 600 "$dest"
}

# -----------------------------------------------------------------------------
# Native Alloy install (apt pin, tarball fallback)
# -----------------------------------------------------------------------------

_obs_disable_packaged_alloy() {
    # The apt `alloy` package ships its own alloy.service; we run telcoin-alloy.service
    # with our config instead, so stop/disable the packaged one to avoid a double tail.
    systemctl disable --now alloy.service >/dev/null 2>&1 || true
}

_obs_install_alloy_apt() {
    command -v gpg >/dev/null 2>&1 || apt-get install -y gnupg >/dev/null 2>&1 || true
    local key=/etc/apt/keyrings/grafana.gpg
    install -d -m 0755 /etc/apt/keyrings
    if [[ ! -f "$key" ]]; then
        curl --proto '=https' --tlsv1.2 -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o "$key" 2>/dev/null || return 1
    fi
    echo "deb [signed-by=${key}] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
    apt-get update -y >/dev/null 2>&1 || return 1
    # Install the pinned version only. If the pin is unavailable, fail here so the
    # dispatcher falls back to the pinned release tarball — never silently install
    # whatever unpinned version the repo happens to offer.
    if ! apt-get install -y "alloy=${TN_ALLOY_NATIVE_VERSION}" >/dev/null 2>&1; then
        print_warn "Pinned alloy=${TN_ALLOY_NATIVE_VERSION} unavailable via apt; will try the pinned release tarball."
        return 1
    fi
    return 0
}

_obs_install_alloy_tarball() {
    local arch url tmp bin
    case "$(uname -m)" in
        x86_64|amd64)  arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) print_error "Unsupported architecture $(uname -m) for the Alloy tarball."; return 1 ;;
    esac
    command -v unzip >/dev/null 2>&1 || apt-get install -y unzip >/dev/null 2>&1 || true
    url="https://github.com/grafana/alloy/releases/download/v${TN_ALLOY_NATIVE_VERSION}/alloy-linux-${arch}.zip"
    tmp="$(mktemp -d)"
    print_info "Downloading ${url}"
    if curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "${tmp}/alloy.zip" 2>/dev/null; then
        # Verify the download against the official checksum sidecar before installing.
        local want got
        want="$(curl --proto '=https' --tlsv1.2 -fsSL --max-time 15 "${url}.sha256" 2>/dev/null | awk '{print $1}')"
        if [[ -n "$want" ]]; then
            got="$(sha256sum "${tmp}/alloy.zip" 2>/dev/null | awk '{print $1}')"
            if [[ "$want" != "$got" ]]; then
                print_error "Alloy tarball checksum mismatch — refusing to install."
                rm -rf "$tmp"
                return 1
            fi
            print_ok "Alloy tarball checksum verified."
        else
            print_warn "Could not fetch Alloy checksum sidecar; installing unverified (TLS only)."
        fi
    fi
    if [[ -f "${tmp}/alloy.zip" ]] && ( cd "$tmp" && unzip -o -q alloy.zip ) 2>/dev/null; then
        bin="$(find "$tmp" -maxdepth 1 -type f -name 'alloy-linux-*' ! -name '*.zip' | head -1)"
        [[ -n "$bin" ]] || bin="$(find "$tmp" -maxdepth 1 -type f -name 'alloy*' ! -name '*.zip' | head -1)"
        if [[ -n "$bin" ]]; then
            install -m 0755 "$bin" /usr/local/bin/alloy
            rm -rf "$tmp"
            command -v alloy >/dev/null 2>&1 && { print_ok "alloy installed to /usr/local/bin/alloy"; return 0; }
        fi
    fi
    rm -rf "$tmp"
    return 1
}

# obs_install_alloy_native — idempotent. apt (pinned) first, tarball fallback.
obs_install_alloy_native() {
    if command -v alloy >/dev/null 2>&1; then
        print_ok "alloy already installed ($(command -v alloy))"
        return 0
    fi
    print_step "Installing Grafana Alloy (native binary)"
    if command -v apt-get >/dev/null 2>&1 && _obs_install_alloy_apt && command -v alloy >/dev/null 2>&1; then
        _obs_disable_packaged_alloy
        print_ok "alloy installed via apt ($(command -v alloy))"
        return 0
    fi
    print_warn "apt install unavailable/failed; trying the release tarball."
    _obs_install_alloy_tarball
}

# -----------------------------------------------------------------------------
# systemd unit writers
# -----------------------------------------------------------------------------

# obs_write_alloy_native_unit <token> — native unit + its mode-600 env file. Runs as
# the telcoin service user (can read /var/log/telcoin, write /var/lib/telcoin-alloy).
obs_write_alloy_native_unit() {
    local token="$1"
    local envf="${OBS_ETC_DIR}/telcoin-alloy.env"
    local bin; bin="$(command -v alloy 2>/dev/null || echo /usr/bin/alloy)"
    _obs_write_env_file "$envf" "$token"
    cat > "/etc/systemd/system/${OBS_ALLOY_UNIT}" <<EOF
[Unit]
Description=Telcoin node log shipper (Grafana Alloy -> central Loki)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
EnvironmentFile=${envf}
ExecStart=${bin} run --server.http.listen-addr=${OBS_HTTP_ADDR} --storage.path=${OBS_DATA_DIR} ${OBS_ETC_DIR}/config.alloy
Restart=on-failure
RestartSec=10
MemoryMax=512M
CPUQuota=50%
TasksMax=256

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# obs_run_alloy_docker <token> <log_host_dir> — docker-sidecar unit + its mode-600 env
# file. Mirrors the adiri start-validator-node.sh sidecar (container telcoin-alloy,
# host network, RO config + logs), but supervised by systemd so it is greppable and
# restarts with the host. The ExecStart uses backslash continuations that bash collapses
# to one line on render (same as the node units) — valid for systemd.
obs_run_alloy_docker() {
    local token="$1" log_host_dir="$2"
    local envf="${OBS_ETC_DIR}/telcoin-alloy.env"
    _obs_write_env_file "$envf" "$token"
    cat > "/etc/systemd/system/${OBS_ALLOY_UNIT}" <<EOF
[Unit]
Description=Telcoin node log shipper (Grafana Alloy sidecar -> central Loki)
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
ExecStartPre=-/usr/bin/docker rm -f telcoin-alloy
ExecStart=/usr/bin/docker run --rm --name telcoin-alloy \
--network=host \
--memory=512m \
--cpus=0.50 \
--pids-limit=256 \
--cap-drop=ALL \
--security-opt=no-new-privileges \
--env-file ${envf} \
-v ${OBS_ETC_DIR}/config.alloy:/etc/alloy/config.alloy:ro \
-v ${log_host_dir}:/var/log/telcoin:ro \
-v ${OBS_DATA_DIR}:/var/lib/alloy/data \
${TN_ALLOY_IMAGE} run \
--server.http.listen-addr=${OBS_HTTP_ADDR} \
--storage.path=/var/lib/alloy/data \
/etc/alloy/config.alloy
ExecStop=/usr/bin/docker stop telcoin-alloy
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# -----------------------------------------------------------------------------
# Ensure the running node actually writes JSON logs (standalone-enable path)
# -----------------------------------------------------------------------------

# obs_ensure_reth_logs — when obs is enabled AFTER setup (setup-observability.sh) the
# node may already be running WITHOUT the reth JSON-log flags, so Alloy would have
# nothing to tail. Idempotently inject the flags into the correct launch config (docker:
# systemd ExecStart; binary: the start wrapper) and offer to restart. In the first-pass
# setup the flags are already baked (ask-early), so this is a no-op there.
obs_ensure_reth_logs() {
    local target svc method file flags
    target="$(tn_node_launch_target)" || { print_warn "No telcoin node service detected; skipping reth log-flag check."; return 0; }
    read -r svc method file <<< "$target"
    flags="$(obs_reth_log_flags "$method")"

    if grep -q -- '--log.file.format json' "$file" 2>/dev/null; then
        print_ok "Node already configured to write JSON logs."
        return 0
    fi
    print_step "Enabling JSON node logs"
    print_info "Appending reth JSON-log flags to ${file} so Alloy has logs to ship."
    if ! tn_node_inject_flags "$file" '--log.file.format json' "$flags"; then
        print_warn "Could not find the node launch line in ${file}; left unchanged."
        print_info "Add these flags to the node launch manually: ${flags}"
        return 0
    fi
    [[ "$method" == "docker" ]] && systemctl daemon-reload

    print_warn "The node must restart to begin writing JSON logs."
    if confirm "Restart ${svc} now?"; then
        if systemctl restart "$svc"; then print_ok "${svc} restarted."; else print_warn "Restart failed; run: sudo systemctl restart ${svc}"; fi
    else
        print_info "Restart later: sudo systemctl restart ${svc}"
    fi
}

# -----------------------------------------------------------------------------
# enable / disable / status
# -----------------------------------------------------------------------------

# obs_enable <token> — set up + start the Alloy log shipper for this node's install
# method, ensure the node writes JSON logs, and record state. Idempotent.
obs_enable() {
    local token="${1:-}"
    # Trim leading/trailing whitespace (a stray paste newline otherwise yields silent 401s).
    token="${token#"${token%%[![:space:]]*}"}"
    token="${token%"${token##*[![:space:]]}"}"
    [[ -n "$token" ]] || { print_error "obs_enable: empty ingest token."; return 1; }
    if [[ "$token" =~ [[:space:]] ]]; then
        print_warn "Ingest token contains internal whitespace — check you pasted it correctly."
    elif (( ${#token} < 16 )); then
        print_warn "Ingest token looks short (${#token} chars) — check you pasted the full token."
    fi
    local meta method datadir
    meta="$(node_meta_path || true)"
    method="$(meta_get INSTALL_METHOD "$meta" 2>/dev/null || echo binary)"; [[ -n "$method" ]] || method="binary"
    datadir="$(meta_get DATA_DIR "$meta" 2>/dev/null || true)"

    install -d -m 0750 "$OBS_ETC_DIR"
    obs_write_config_alloy "${OBS_ETC_DIR}/config.alloy"

    if [[ "$method" == "docker" ]]; then
        local log_host_dir="${datadir:-${DEFAULT_DATA_DIR}/validator}/logs"
        install -d -m 0755 "$log_host_dir"
        chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "$log_host_dir" 2>/dev/null || true
        install -d -m 0750 "$OBS_DATA_DIR"
        obs_run_alloy_docker "$token" "$log_host_dir"
    else
        install -d -m 0755 "$DEFAULT_LOG_DIR"
        chown "${SERVICE_USER}:${SERVICE_GROUP}" "$DEFAULT_LOG_DIR" 2>/dev/null || true
        install -d -m 0750 "$OBS_DATA_DIR"
        chown "${SERVICE_USER}:${SERVICE_GROUP}" "$OBS_DATA_DIR" 2>/dev/null || true
        if ! obs_install_alloy_native; then
            print_error "Could not install Alloy natively (apt + tarball both failed)."
            return 1
        fi
        obs_write_alloy_native_unit "$token"
    fi

    if systemctl enable --now "$OBS_ALLOY_UNIT" >/dev/null 2>&1; then
        print_ok "Log shipper running (${OBS_ALLOY_UNIT})."
    else
        print_error "Failed to start ${OBS_ALLOY_UNIT}. Check: journalctl -u ${OBS_ALLOY_UNIT} -n 50"
        return 1
    fi

    obs_ensure_reth_logs

    if [[ -n "$meta" ]]; then
        meta_set ENABLE_OBSERVABILITY true "$meta"
        [[ -n "${REGION:-}" ]] && meta_set REGION "$REGION" "$meta"
    fi
    print_ok "Observability enabled. Logs -> ${OBS_PUSH_URL_TESTNET}"
    print_info "Verify shipping: curl -s ${OBS_HTTP_ADDR}/metrics | grep loki_write_sent_bytes_total"
    return 0
}

# obs_disable — stop + disable the shipper and record state. Leaves the node writing
# JSON logs locally (harmless); remove-node.sh fully cleans config + data dirs.
obs_disable() {
    print_step "Disabling observability (log shipping)"
    systemctl disable --now "$OBS_ALLOY_UNIT" >/dev/null 2>&1 || true
    docker rm -f telcoin-alloy >/dev/null 2>&1 || true
    local meta; meta="$(node_meta_path || true)"
    [[ -n "$meta" ]] && meta_set ENABLE_OBSERVABILITY false "$meta"
    print_ok "Log shipper stopped + disabled (${OBS_ALLOY_UNIT})."
    print_info "The node keeps writing JSON logs locally (harmless). remove-node.sh removes all obs files."
    return 0
}

# obs_status — human-readable status: configured flag, Alloy unit state, bytes shipped,
# and reth JSON-log freshness/validity. Used by setup-observability.sh and check-node.sh.
obs_status() {
    print_step "Observability (log shipping)"
    local meta enabled method
    meta="$(node_meta_path || true)"
    enabled="$(meta_get ENABLE_OBSERVABILITY "$meta" 2>/dev/null || echo false)"
    method="$(meta_get INSTALL_METHOD "$meta" 2>/dev/null || echo binary)"
    print_info "Configured: ENABLE_OBSERVABILITY=${enabled:-false}"

    if ! systemctl list-unit-files 2>/dev/null | grep -q "^${OBS_ALLOY_UNIT}"; then
        print_info "${OBS_ALLOY_UNIT} not installed (run setup-observability.sh to enable)."
        return 0
    fi
    if systemctl is-active --quiet "$OBS_ALLOY_UNIT"; then
        print_ok "${OBS_ALLOY_UNIT} is active"
    else
        print_warn "${OBS_ALLOY_UNIT} is installed but NOT active (journalctl -u ${OBS_ALLOY_UNIT})"
    fi

    local sent
    sent="$(curl -fsS "${OBS_HTTP_ADDR}/metrics" 2>/dev/null | grep -E '^loki_write_sent_bytes_total' | awk '{s+=$2} END{printf "%d", s+0}')" || sent=""
    if [[ -n "$sent" ]]; then
        if [[ "$sent" != "0" ]]; then
            print_ok "Alloy has shipped ${sent} log bytes to Loki (loki_write_sent_bytes_total)"
        else
            print_warn "Alloy up but 0 bytes shipped yet (node starting, or no logs to tail yet)"
        fi
    fi

    local logdir logf
    if [[ "$method" == "docker" ]]; then
        local dd; dd="$(meta_get DATA_DIR "$meta" 2>/dev/null || echo "${DEFAULT_DATA_DIR}/validator")"
        logdir="${dd}/logs/telcoin-network-logs"
    else
        logdir="${DEFAULT_LOG_DIR}/telcoin-network-logs"
    fi
    logf="${logdir}/reth.log"
    if [[ -f "$logf" ]]; then
        if head -1 "$logf" 2>/dev/null | grep -q '"level"'; then
            print_ok "reth JSON log present + valid: ${logf}"
        else
            print_warn "reth log at ${logf} but first line isn't JSON — is --log.file.format json set?"
        fi
    else
        print_warn "reth JSON log not found at ${logf} (node not started yet, or JSON logs not enabled)"
    fi
}

: # observability.sh sources with status 0
