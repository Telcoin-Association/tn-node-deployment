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
OBSERVABILITY_VERSION="1.0.1"

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
: "${OBS_METRICS_PUSH_URL_TESTNET:=https://obs.adiri.telcoin.network/api/v1/write}"
# Devnet push endpoints fail closed: no public devnet hub is hardcoded. Empty
# unless the operator sets them (env or setup-observability.sh --push-url /
# --metrics-push-url). obs_enable refuses to write a broken config if still empty.
: "${OBS_PUSH_URL_DEVNET:=}"
: "${OBS_METRICS_PUSH_URL_DEVNET:=}"
: "${DEFAULT_METRICS_PORT:=9101}"
: "${TN_ALLOY_IMAGE:=grafana/alloy:v1.5.1}"
: "${TN_ALLOY_NATIVE_VERSION:=1.5.1}"
: "${DEFAULT_LOG_DIR:=/var/log/telcoin}"
: "${DEFAULT_DATA_DIR:=/var/lib/telcoin}"
: "${DEFAULT_INSTALL_DIR:=/opt/telcoin}"
: "${SERVICE_USER:=telcoin}"
: "${SERVICE_GROUP:=telcoin}"

# -----------------------------------------------------------------------------
# Effective push-URL selection (testnet vs devnet, with explicit override)
# -----------------------------------------------------------------------------
#
# Precedence (same for logs + metrics):
#   1. an explicit OBS_PUSH_URL / OBS_METRICS_PUSH_URL (set by env, or by
#      setup-observability.sh --push-url / --metrics-push-url) — always wins
#   2. else NETWORK=devnet  -> OBS_*_PUSH_URL_DEVNET  (empty unless configured)
#   3. else (testnet)       -> OBS_*_PUSH_URL_TESTNET (the adiri hub)
#
# For testnet with no override this resolves to exactly $OBS_PUSH_URL_TESTNET /
# $OBS_METRICS_PUSH_URL_TESTNET — i.e. the testnet render is byte-for-byte
# unchanged. Devnet with nothing configured yields EMPTY; obs_enable guards on
# that and refuses to write a config that ships nowhere.
obs_effective_push_url() {
    if [[ -n "${OBS_PUSH_URL:-}" ]]; then printf '%s' "${OBS_PUSH_URL}"
    elif [[ "${NETWORK:-}" == "devnet" ]]; then printf '%s' "${OBS_PUSH_URL_DEVNET:-}"
    else printf '%s' "${OBS_PUSH_URL_TESTNET}"; fi
}
obs_effective_metrics_url() {
    if [[ -n "${OBS_METRICS_PUSH_URL:-}" ]]; then printf '%s' "${OBS_METRICS_PUSH_URL}"
    elif [[ "${NETWORK:-}" == "devnet" ]]; then printf '%s' "${OBS_METRICS_PUSH_URL_DEVNET:-}"
    else printf '%s' "${OBS_METRICS_PUSH_URL_TESTNET}"; fi
}

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

# obs_metrics_addr — the loopback host:port the node serves Prometheus metrics on AND
# the Alloy scrape target read into TN_METRICS_ADDR. One source of truth: the operator's
# METRICS_PORT (global at install time, else read back from .node-meta, else the default
# 9101 to match the adiri fleet). Loopback only → never firewalled, never public.
obs_metrics_addr() {
    local port="${METRICS_PORT:-}"
    [[ -n "$port" ]] || port="$(meta_get METRICS_PORT "$(node_meta_path 2>/dev/null || true)" 2>/dev/null || true)"
    [[ -n "$port" ]] || port="${DEFAULT_METRICS_PORT:-9101}"
    printf '127.0.0.1:%s' "$port"
}

# obs_metrics_reth_flags — the reth flag that makes the node serve a Prometheus endpoint
# Alloy can scrape, as ONE string (parallel to obs_reth_log_flags; the addr is loopback so
# it does not branch on install method). Gated by ENABLE_METRICS in tn_node_launch_flags;
# absent → the node installs the zero-overhead noop recorder (telcoin-network-cli).
obs_metrics_reth_flags() {
    printf -- '--metrics %s' "$(obs_metrics_addr)"
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

# obs_write_config_alloy [dest] — deploy the Alloy config, rendering ONLY the pipeline(s)
# the operator opted into: ENABLE_OBSERVABILITY → loki.* (logs), ENABLE_METRICS →
# prometheus.* (metrics). With both on it is byte-identical to the canonical, adiri-
# matching observability/config.alloy. The per-pipeline blocks are sliced straight out of
# that single checked-in source (no drift); a missing source falls back to an embedded,
# functionally-identical copy that the same slicer renders.
obs_write_config_alloy() {
    local dest="${1:-${OBS_ETC_DIR}/config.alloy}"
    install -d -m 0750 "$(dirname "$dest")"
    local src="$OBS_CONFIG_SRC" tmp=""
    if [[ ! -f "$src" ]]; then
        print_warn "observability/config.alloy missing; using the embedded fallback (functionally identical)."
        tmp="$(mktemp)"; _obs_alloy_fallback > "$tmp"; src="$tmp"
    fi
    _obs_slice_alloy "$src" "$dest"
    [[ -n "$tmp" ]] && rm -f "$tmp"
    chmod 0644 "$dest"
}

# _obs_slice_alloy <src> <dest> — copy src to dest keeping only the enabled pipeline
# blocks. Regions are delimited by River anchors that never move: the logs pipeline
# begins at `local.file_match`, the metrics pipeline at the `// --- Metrics pipeline`
# divider; everything before the first anchor is the shared header (always kept). Both
# pipelines enabled → byte-identical to src.
_obs_slice_alloy() {
    local src="$1" dest="$2" logs=0 metrics=0
    [[ "${ENABLE_OBSERVABILITY:-false}" == "true" ]] && logs=1
    [[ "${ENABLE_METRICS:-false}" == "true" ]] && metrics=1
    awk -v logs="$logs" -v metrics="$metrics" '
        BEGIN { region = "header" }
        /^local\.file_match/         { region = "logs" }
        /^\/\/ --- Metrics pipeline/ { region = "metrics" }
        region == "header"                  { print; next }
        region == "logs"    && logs    == 1 { print; next }
        region == "metrics" && metrics == 1 { print; next }
    ' "$src" > "$dest"
}

# _obs_alloy_fallback — the full canonical config (BOTH pipelines), emitted only when the
# checked-in observability/config.alloy is missing. _obs_slice_alloy slices it the same
# way, so all four toggle states still render correctly. The relabel rule{} blocks are
# MULTI-LINE on purpose — the one-line form is invalid River and crash-loops Alloy. Keep
# in sync with observability/config.alloy (and thus adiri).
_obs_alloy_fallback() {
    cat <<'ALLOY_EOF'
// Fallback copy (canonical: observability/config.alloy, byte-identical to adiri).
// Env: TN_NODE TN_REGION TN_VALIDATOR_ADDRESS TN_CHAIN TN_IMAGE_VERSION
//      OBS_PUSH_URL OBS_INGEST_TOKEN TN_METRICS_ADDR OBS_METRICS_PUSH_URL
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

// --- Metrics pipeline --------------------------------------------------------
prometheus.scrape "tn" {
  targets = [{
    __address__ = sys.env("TN_METRICS_ADDR"),
    instance    = sys.env("TN_NODE"),
  }]
  job_name        = "telcoin-node"
  scrape_interval = "15s"
  forward_to      = [prometheus.relabel.tn.receiver]
}

prometheus.relabel "tn" {
  forward_to = [prometheus.remote_write.central.receiver]

  rule {
    target_label = "node"
    replacement  = sys.env("TN_NODE")
  }

  rule {
    target_label = "region"
    replacement  = sys.env("TN_REGION")
  }

  rule {
    target_label = "validator_address"
    replacement  = sys.env("TN_VALIDATOR_ADDRESS")
  }

  rule {
    target_label = "chain"
    replacement  = sys.env("TN_CHAIN")
  }

  rule {
    target_label = "network"
    replacement  = sys.env("TN_CHAIN")
  }

  rule {
    target_label = "image_version"
    replacement  = sys.env("TN_IMAGE_VERSION")
  }
}

prometheus.remote_write "central" {
  endpoint {
    url          = sys.env("OBS_METRICS_PUSH_URL")
    bearer_token = sys.env("OBS_INGEST_TOKEN")
  }
}
ALLOY_EOF
}

# _obs_write_env_file <dest> <token> — mode-600 file with identity labels + push URL +
# ingest token. Consumed by the native unit (EnvironmentFile=) and the docker unit
# (--env-file). When metrics is enabled it ALSO emits TN_METRICS_ADDR (the scrape target)
# and OBS_METRICS_PUSH_URL — the metrics pipeline reuses OBS_INGEST_TOKEN (one shared
# token, by hub design). The token lives ONLY here (never in git or .node-meta). Created
# inside a umask-077 subshell so it is never briefly world-readable.
_obs_write_env_file() {
    local dest="$1" token="$2"
    obs_label_sourcing
    install -d -m 0750 "$(dirname "$dest")"
    # Effective push URLs: explicit OBS_PUSH_URL/OBS_METRICS_PUSH_URL override wins,
    # else _DEVNET when NETWORK=devnet, else _TESTNET (unchanged for testnet).
    local push_url metrics_url
    push_url="$(obs_effective_push_url)"
    metrics_url="$(obs_effective_metrics_url)"
    ( umask 077
      {
        cat <<EOF
TN_NODE=${TN_NODE}
TN_REGION=${TN_REGION}
TN_VALIDATOR_ADDRESS=${TN_VALIDATOR_ADDRESS}
TN_CHAIN=${TN_CHAIN}
TN_IMAGE_VERSION=${TN_IMAGE_VERSION}
OBS_PUSH_URL=${push_url}
OBS_INGEST_TOKEN=${token}
EOF
        if [[ "${ENABLE_METRICS:-false}" == "true" ]]; then
            cat <<EOF
TN_METRICS_ADDR=$(obs_metrics_addr)
OBS_METRICS_PUSH_URL=${metrics_url}
EOF
        fi
      } > "$dest"
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
    # Install the pinned version only. Grafana packages Alloy with a Debian
    # revision (e.g. 1.5.1-1), so an exact "=1.5.1" pin never matches -- resolve
    # the full candidate whose upstream version equals our pin and install that
    # exact string. If none matches, fail here so the dispatcher falls back to
    # the pinned release tarball -- never silently install whatever unpinned
    # version the repo happens to offer.
    local full
    full="$(apt-cache madison alloy 2>/dev/null \
        | awk -v v="${TN_ALLOY_NATIVE_VERSION}" '$3 ~ ("^" v "(-|$)") {print $3; exit}')"
    if [[ -z "$full" ]]; then
        print_warn "Pinned alloy ${TN_ALLOY_NATIVE_VERSION} unavailable via apt; will try the pinned release tarball."
        return 1
    fi
    if ! apt-get install -y "alloy=${full}" >/dev/null 2>&1; then
        print_warn "Pinned alloy=${full} install failed via apt; will try the pinned release tarball."
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
        # Verify the download against the release SHA256SUMS before installing.
        # Grafana ships a single SHA256SUMS per release (not a per-asset .sha256
        # sidecar), so pull our asset's line out of it. Handles both the plain
        # ("hash  asset") and binary ("hash *asset") sums formats.
        local want got asset sums_url
        asset="alloy-linux-${arch}.zip"
        sums_url="https://github.com/grafana/alloy/releases/download/v${TN_ALLOY_NATIVE_VERSION}/SHA256SUMS"
        want="$(curl --proto '=https' --tlsv1.2 -fsSL --max-time 15 "$sums_url" 2>/dev/null \
            | awk -v a="$asset" '{f=$2; sub(/^\*/,"",f); if (f==a){print $1; exit}}')"
        if [[ -n "$want" ]]; then
            got="$(sha256sum "${tmp}/alloy.zip" 2>/dev/null | awk '{print $1}')"
            if [[ "$want" != "$got" ]]; then
                print_error "Alloy tarball checksum mismatch — refusing to install."
                rm -rf "$tmp"
                return 1
            fi
            print_ok "Alloy tarball checksum verified."
        else
            print_warn "Could not fetch Alloy checksum (SHA256SUMS); installing unverified (TLS only)."
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

# obs_ensure_reth_flags — when obs is enabled AFTER setup (setup-observability.sh) the
# node may already be running WITHOUT the reth flags the enabled pipelines need: the
# JSON-log flags (logs → Alloy has something to tail) and/or --metrics (metrics → a
# registry to scrape). Idempotently inject whichever are missing into the correct launch
# config (docker: systemd ExecStart; binary: the start wrapper) and offer ONE restart for
# all of them. In the first-pass setup the flags are already baked (ask-early), so this is
# a no-op there. Reads ENABLE_OBSERVABILITY / ENABLE_METRICS.
obs_ensure_reth_flags() {
    local target svc method file changed=0
    target="$(tn_node_launch_target)" || { print_warn "No telcoin node service detected; skipping reth flag check."; return 0; }
    read -r svc method file <<< "$target"

    if [[ "${ENABLE_OBSERVABILITY:-false}" == "true" ]]; then
        if grep -q -- '--log.file.format json' "$file" 2>/dev/null; then
            print_ok "Node already writes JSON logs."
        else
            print_step "Enabling JSON node logs"
            if tn_node_inject_flags "$file" '--log.file.format json' "$(obs_reth_log_flags "$method")"; then
                changed=1
            else
                print_warn "Could not find the node launch line in ${file}; add manually: $(obs_reth_log_flags "$method")"
            fi
        fi
    fi

    if [[ "${ENABLE_METRICS:-false}" == "true" ]]; then
        if grep -q -- '--metrics' "$file" 2>/dev/null; then
            print_ok "Node already serves a metrics endpoint (--metrics)."
        else
            print_step "Enabling node metrics endpoint"
            if tn_node_inject_flags "$file" '--metrics' "$(obs_metrics_reth_flags)"; then
                changed=1
            else
                print_warn "Could not find the node launch line in ${file}; add manually: $(obs_metrics_reth_flags)"
            fi
        fi
    fi

    [[ "$changed" -eq 1 ]] || return 0
    [[ "$method" == "docker" ]] && systemctl daemon-reload

    print_warn "The node must restart to pick up the new reth flags."
    if confirm "Restart ${svc} now?"; then
        if systemctl restart "$svc"; then print_ok "${svc} restarted."; else print_warn "Restart failed; run: sudo systemctl restart ${svc}"; fi
    else
        print_info "Restart later: sudo systemctl restart ${svc}"
    fi
}

# -----------------------------------------------------------------------------
# enable / disable / status
# -----------------------------------------------------------------------------

# obs_enable <token> — set up + start the Alloy shipper for whichever pipelines the caller
# has enabled (ENABLE_OBSERVABILITY = logs, ENABLE_METRICS = metrics; set them to the
# desired FINAL state before calling), render config.alloy + the mode-600 env file to
# match, ensure the node carries the matching reth flags, and record state. Idempotent —
# safe to re-run to flip one pipeline on/off (it restarts Alloy to load the new config).
# The single ingest token serves BOTH pipelines (one obs-hub gate).
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

    local logs_on="${ENABLE_OBSERVABILITY:-false}" metrics_on="${ENABLE_METRICS:-false}"
    if [[ "$logs_on" != "true" && "$metrics_on" != "true" ]]; then
        print_error "obs_enable: neither pipeline enabled (set ENABLE_OBSERVABILITY and/or ENABLE_METRICS)."
        return 1
    fi

    # Fail closed: refuse to write an Alloy config that ships nowhere. On devnet the
    # push URLs default to empty (no public hub baked in) — the operator must set
    # OBS_PUSH_URL/OBS_METRICS_PUSH_URL (env or --push-url/--metrics-push-url) first.
    # On testnet the effective URLs resolve to the adiri hub, so this never trips.
    if [[ "$logs_on" == "true" && -z "$(obs_effective_push_url)" ]]; then
        print_error "obs_enable: no logs push URL configured for network '${NETWORK:-unset}'."
        print_info  "Set OBS_PUSH_URL (or pass --push-url to setup-observability.sh) before enabling logs."
        return 1
    fi
    if [[ "$metrics_on" == "true" && -z "$(obs_effective_metrics_url)" ]]; then
        print_error "obs_enable: no metrics push URL configured for network '${NETWORK:-unset}'."
        print_info  "Set OBS_METRICS_PUSH_URL (or pass --metrics-push-url to setup-observability.sh) before enabling metrics."
        return 1
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

    # enable (boot) + restart (now): restart also reloads a rewritten config/env when the
    # unit is already running (e.g. flipping metrics on while logs already ship).
    systemctl enable "$OBS_ALLOY_UNIT" >/dev/null 2>&1 || true
    if systemctl restart "$OBS_ALLOY_UNIT" >/dev/null 2>&1; then
        print_ok "Telemetry shipper running (${OBS_ALLOY_UNIT})."
    else
        print_error "Failed to start ${OBS_ALLOY_UNIT}. Check: journalctl -u ${OBS_ALLOY_UNIT} -n 50"
        return 1
    fi

    obs_ensure_reth_flags

    if [[ -n "$meta" ]]; then
        meta_set ENABLE_OBSERVABILITY "$logs_on" "$meta"
        meta_set ENABLE_METRICS "$metrics_on" "$meta"
        [[ -n "${REGION:-}" ]] && meta_set REGION "$REGION" "$meta"
    fi

    local what=""
    [[ "$logs_on" == "true" ]] && what="logs → $(obs_effective_push_url)"
    [[ "$metrics_on" == "true" ]] && what="${what:+$what, }metrics → $(obs_effective_metrics_url)"
    print_ok "Observability enabled (${what})."
    [[ "$logs_on" == "true" ]] && print_info "Verify logs:    curl -s ${OBS_HTTP_ADDR}/metrics | grep loki_write_sent_bytes_total"
    [[ "$metrics_on" == "true" ]] && print_info "Verify metrics: curl -s ${OBS_HTTP_ADDR}/metrics | grep prometheus_remote_storage_samples_total"
    return 0
}

# obs_existing_token — echo the OBS_INGEST_TOKEN already stored in the mode-600 Alloy env
# file, if any, so a second pipeline can be enabled without re-pasting the shared token.
# Stays local (returned to the caller, never logged). Empty if no env file / no token.
obs_existing_token() {
    local envf="${OBS_ETC_DIR}/telcoin-alloy.env"
    [[ -r "$envf" ]] || return 0
    sed -n 's/^OBS_INGEST_TOKEN=//p' "$envf" 2>/dev/null | head -1
}

# obs_disable — FULL teardown: stop + disable the shipper, record BOTH pipelines off.
# Leaves the node writing JSON logs / serving --metrics locally (harmless); remove-node.sh
# fully cleans config + data dirs + the node flags.
obs_disable() {
    print_step "Disabling observability (logs + metrics shipping)"
    systemctl disable --now "$OBS_ALLOY_UNIT" >/dev/null 2>&1 || true
    docker rm -f telcoin-alloy >/dev/null 2>&1 || true
    local meta; meta="$(node_meta_path || true)"
    if [[ -n "$meta" ]]; then
        meta_set ENABLE_OBSERVABILITY false "$meta"
        meta_set ENABLE_METRICS false "$meta"
    fi
    print_ok "Telemetry shipper stopped + disabled (${OBS_ALLOY_UNIT})."
    print_info "The node keeps writing JSON logs / serving --metrics locally (harmless). remove-node.sh removes all obs files."
    return 0
}

# obs_disable_logs — turn OFF log shipping but KEEP metrics if it is on: re-render the
# Alloy config to metrics-only and reload it. If metrics is also off, fall through to the
# full teardown. The node keeps writing JSON logs locally (harmless).
obs_disable_logs() {
    local meta metrics_on
    meta="$(node_meta_path || true)"
    metrics_on="$(meta_get ENABLE_METRICS "$meta" 2>/dev/null || echo false)"
    if [[ "$metrics_on" == "true" ]]; then
        print_step "Disabling log shipping (metrics stays on)"
        ENABLE_OBSERVABILITY=false; ENABLE_METRICS=true
        obs_write_config_alloy "${OBS_ETC_DIR}/config.alloy"
        systemctl restart "$OBS_ALLOY_UNIT" >/dev/null 2>&1 || true
        [[ -n "$meta" ]] && meta_set ENABLE_OBSERVABILITY false "$meta"
        print_ok "Log shipping stopped; metrics still shipping → $(obs_effective_metrics_url)."
        print_info "The node keeps writing JSON logs locally (harmless)."
    else
        obs_disable
    fi
    return 0
}

# obs_disable_metrics — turn OFF metrics shipping but KEEP logs if it is on: re-render the
# Alloy config to logs-only and reload it. If logs is also off, fall through to the full
# teardown. The node keeps serving its loopback --metrics endpoint (harmless; unscraped).
obs_disable_metrics() {
    local meta logs_on
    meta="$(node_meta_path || true)"
    logs_on="$(meta_get ENABLE_OBSERVABILITY "$meta" 2>/dev/null || echo false)"
    if [[ "$logs_on" == "true" ]]; then
        print_step "Disabling metrics shipping (logs stays on)"
        ENABLE_OBSERVABILITY=true; ENABLE_METRICS=false
        obs_write_config_alloy "${OBS_ETC_DIR}/config.alloy"
        systemctl restart "$OBS_ALLOY_UNIT" >/dev/null 2>&1 || true
        [[ -n "$meta" ]] && meta_set ENABLE_METRICS false "$meta"
        print_ok "Metrics shipping stopped; logs still shipping → $(obs_effective_push_url)."
        print_info "The node keeps serving its loopback --metrics endpoint (harmless; nothing scrapes it now)."
    else
        obs_disable
    fi
    return 0
}

# obs_status — human-readable status: configured flags (logs + metrics), Alloy unit state,
# per-pipeline shipping progress, the node metrics endpoint, and reth JSON-log
# freshness/validity. Used by setup-observability.sh and check-node.sh.
obs_status() {
    print_step "Observability (logs + metrics shipping)"
    local meta logs_enabled metrics_enabled method
    meta="$(node_meta_path || true)"
    logs_enabled="$(meta_get ENABLE_OBSERVABILITY "$meta" 2>/dev/null || echo false)"
    metrics_enabled="$(meta_get ENABLE_METRICS "$meta" 2>/dev/null || echo false)"
    method="$(meta_get INSTALL_METHOD "$meta" 2>/dev/null || echo binary)"
    print_info "Configured: ENABLE_OBSERVABILITY=${logs_enabled:-false} (logs), ENABLE_METRICS=${metrics_enabled:-false} (metrics)"

    if ! systemctl list-unit-files 2>/dev/null | grep -q "^${OBS_ALLOY_UNIT}"; then
        print_info "${OBS_ALLOY_UNIT} not installed (run setup-observability.sh to enable)."
        return 0
    fi
    if systemctl is-active --quiet "$OBS_ALLOY_UNIT"; then
        print_ok "${OBS_ALLOY_UNIT} is active"
    else
        print_warn "${OBS_ALLOY_UNIT} is installed but NOT active (journalctl -u ${OBS_ALLOY_UNIT})"
    fi

    # Pull Alloy's own /metrics once; read both pipelines' progress out of it.
    local alloy_metrics
    alloy_metrics="$(curl -fsS "${OBS_HTTP_ADDR}/metrics" 2>/dev/null || true)"

    if [[ "$logs_enabled" == "true" ]]; then
        local sent
        sent="$(printf '%s\n' "$alloy_metrics" | grep -E '^loki_write_sent_bytes_total' | awk '{s+=$2} END{printf "%d", s+0}')"
        if [[ -n "$sent" && "$sent" != "0" ]]; then
            print_ok "Alloy has shipped ${sent} log bytes to Loki (loki_write_sent_bytes_total)"
        else
            print_warn "Alloy up but 0 log bytes shipped yet (node starting, or no logs to tail yet)"
        fi
    fi

    if [[ "$metrics_enabled" == "true" ]]; then
        local samples maddr
        samples="$(printf '%s\n' "$alloy_metrics" | grep -E '^prometheus_remote_storage_samples_total' | awk '{s+=$2} END{printf "%d", s+0}')"
        if [[ -n "$samples" && "$samples" != "0" ]]; then
            print_ok "Alloy has remote-written ${samples} metric samples (prometheus_remote_storage_samples_total)"
        else
            print_warn "Alloy up but 0 metric samples shipped yet (node starting, or --metrics not serving yet)"
        fi
        maddr="$(obs_metrics_addr)"
        if curl -fsS "http://${maddr}/metrics" 2>/dev/null | grep -qE '^(tn_|reth_)'; then
            print_ok "Node metrics endpoint serving tn_*/reth_* series on ${maddr}"
        else
            print_warn "Node metrics endpoint ${maddr} not serving yet (node down, or --metrics not enabled/restarted)"
        fi
    fi

    if [[ "$logs_enabled" == "true" ]]; then
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
    fi
}

: # observability.sh sources with status 0
