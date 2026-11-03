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
# are uniform. The per-operator ingest token lives ONLY in ${OBS_ETC_DIR}/ingest-token
# (root:telcoin-alloy 0640), never in the environment, argv or a unit file.
# See docs/testnet-addons.md.
# =============================================================================

# Version (tracked by update-scripts.sh). Bump when observability/config.alloy or the
# lib/wgvpn bundle changes too, so the updater pulls the testnet-addons bundle alongside.
# Plain (not readonly) so re-sourcing common.sh can't trip on a readonly redefinition.
OBSERVABILITY_VERSION="2.0.0"

# Resolve the checked-in canonical config relative to this lib dir.
__OBS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
OBS_CONFIG_SRC="${__OBS_LIB_DIR}/../observability/config.alloy"

# Layout (remove-node.sh tears these down).
OBS_ETC_DIR="/etc/telcoin/alloy"          # config.alloy, the env file, the token file
OBS_DATA_DIR="/var/lib/telcoin-alloy"     # Alloy WAL / positions
OBS_ALLOY_UNIT="telcoin-alloy.service"
# The ingest token file is ${OBS_ETC_DIR}/${OBS_TOKEN_NAME}. config.alloy reads
# $CREDENTIALS_DIRECTORY/ingest-token: the native unit hands the file over with
# LoadCredential=, the docker sidecar sees it read-only in OBS_DOCKER_CRED_DIR.
OBS_TOKEN_NAME="ingest-token"
OBS_DOCKER_CRED_DIR="/run/credentials/telcoin-alloy"
# Seconds obs_restart_alloy watches the unit after a restart (one is-active read a second).
OBS_ALLOY_SETTLE_SECS=5
OBS_HTTP_ADDR="127.0.0.1:12345"           # Alloy's own metrics/UI (localhost only)

# Defaults mirror lib/testnet-addons.env for set -u safety if sourced standalone.
# network-gated: testnet hub default; obs_effective_push_url gives it only when NETWORK=testnet
: "${OBS_PUSH_URL_TESTNET:=https://obs.adiri.telcoin.network/loki/api/v1/push}"
# network-gated: testnet hub default; obs_effective_metrics_url gives it only when NETWORK=testnet
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
# Native Alloy runs as its own system account, never as the node's service user.
OBS_ALLOY_USER="telcoin-alloy"
# Node-written JSON logs (binary installs): a directory the node owns inside the
# root-owned log dir, group telcoin-log so Alloy can read it. Recorded as NODE_LOG_DIR.
: "${OBS_NODE_LOG_DIR_DEFAULT:=${DEFAULT_LOG_DIR}/node}"
# Primary fingerprint of Grafana's apt signing key (checked against
# https://apt.grafana.com/gpg.key and the Ubuntu keyserver, 2026-10-15).
OBS_GRAFANA_KEY_FPR="B53AE77BADB630A683046005963FA27710458545"

# -----------------------------------------------------------------------------
# Effective push-URL selection (testnet vs devnet, with explicit override)
# -----------------------------------------------------------------------------
#
# Precedence (same for logs + metrics):
#   1. an explicit OBS_PUSH_URL / OBS_METRICS_PUSH_URL (set by env, or by
#      setup-observability.sh --push-url / --metrics-push-url) — always wins
#   2. else NETWORK=devnet  -> OBS_*_PUSH_URL_DEVNET  (empty unless configured)
# network-gated: documents the testnet arm of the push URL precedence
#   3. else (testnet)       -> OBS_*_PUSH_URL_TESTNET (the adiri hub)
#
# For testnet with no override this resolves to exactly $OBS_PUSH_URL_TESTNET /
# $OBS_METRICS_PUSH_URL_TESTNET — i.e. the testnet render is byte-for-byte
# unchanged. Devnet with nothing configured yields EMPTY; obs_enable guards on
# that and refuses to write a config that ships nowhere. Any NETWORK other than
# testnet and devnet (mainnet, unset, unknown) yields EMPTY, override or not, so the
# add-on never ships a mainnet node's logs anywhere.
obs_effective_push_url() {
    case "${NETWORK:-}" in testnet|devnet) ;; *) return 0 ;; esac
    if [[ -n "${OBS_PUSH_URL:-}" ]]; then printf '%s' "${OBS_PUSH_URL}"
    elif [[ "${NETWORK:-}" == "devnet" ]]; then printf '%s' "${OBS_PUSH_URL_DEVNET:-}"
    else printf '%s' "${OBS_PUSH_URL_TESTNET}"; fi
}
obs_effective_metrics_url() {
    case "${NETWORK:-}" in testnet|devnet) ;; *) return 0 ;; esac
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
# binary writes the node log dir (obs_node_log_dir, /var/log/telcoin/node). reth
# appends telcoin-network-logs/ to whatever --log.file.directory is given
# (telcoin-network-cli/src/cli.rs). The docker sidecar mounts DATA_DIR/logs ->
# /var/log/telcoin, matching config.alloy's __path__; for native Alloy
# obs_render_config_alloy points __path__ at the node log dir.
obs_reth_log_flags() {
    local method="${1:-binary}" dir
    if [[ "$method" == "docker" ]]; then
        dir="/home/nonroot/logs"
    else
        dir="$(obs_node_log_dir)"
    fi
    printf '%s' "--log.file.format json --log.file.directory ${dir} --log.file.max-size 100 --log.file.max-files 5"
}

# obs_node_log_dir — where a binary install's node writes its JSON logs: NODE_LOG_DIR
# (global, else .node-meta), else /var/log/telcoin/node. A duplicated key falls back to
# the default (obs_enable and obs_render_config_alloy read the key strictly first).
obs_node_log_dir() {
    local d="${NODE_LOG_DIR:-}"
    [[ -n "$d" ]] || d="$(meta_get NODE_LOG_DIR 2>/dev/null)" || d=""
    printf '%s\n' "${d:-$OBS_NODE_LOG_DIR_DEFAULT}"
}

# obs_metrics_port — the node metrics port as configured: METRICS_PORT (global at install
# network-gated: the comment names the testnet fleet; 9101 is the default on every network
# time), else read back from .node-meta, else the default 9101 to match the adiri fleet.
# Always printed; rc 1 when it is not a port number (digits, 1-65535), so a value such as
# "9101;id" never reaches a launch file or the Alloy env file.
obs_metrics_port() {
    local port="${METRICS_PORT:-}"
    [[ -n "$port" ]] || port="$(meta_get METRICS_PORT "$(node_meta_path 2>/dev/null || true)" 2>/dev/null || true)"
    [[ -n "$port" ]] || port="${DEFAULT_METRICS_PORT:-9101}"
    printf '%s' "$port"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    (( 10#$port >= 1 && 10#$port <= 65535 ))
}

# obs_metrics_addr — the loopback host:port the node serves Prometheus metrics on AND
# the Alloy scrape target read into TN_METRICS_ADDR (port from obs_metrics_port).
# Loopback only → never firewalled, never public. rc 1, printing nothing, when the
# configured port is not a port number.
obs_metrics_addr() {
    local port
    port="$(obs_metrics_port)" || return 1
    printf '127.0.0.1:%s' "$((10#$port))"
}

# _obs_bad_port_msg — what to tell the operator when obs_metrics_port refuses the value.
_obs_bad_port_msg() {
    printf "METRICS_PORT is '%s', which is not a port number (1-65535). Set METRICS_PORT in .node-meta to the port the node should serve metrics on, then run this again." "$(obs_metrics_port || true)"
}

# obs_metrics_reth_flags — the reth flag that makes the node serve a Prometheus endpoint
# Alloy can scrape, as ONE string (parallel to obs_reth_log_flags; the addr is loopback so
# it does not branch on install method). Gated by ENABLE_METRICS in tn_node_launch_flags;
# absent → the node installs the zero-overhead noop recorder (telcoin-network-cli).
# rc 1, printing nothing, when METRICS_PORT is not a port number.
obs_metrics_reth_flags() {
    local addr
    addr="$(obs_metrics_addr)" || return 1
    printf -- '--metrics %s' "$addr"
}

# _obs_data_dir [meta-file] — the node data dir: DATA_DIR from .node-meta, else what
# tn_resolve_data_dir (lib/fallback.sh, which knows the unified and the legacy layouts)
# finds, else DEFAULT_DATA_DIR. Docker installs keep the reth logs under <data dir>/logs.
_obs_data_dir() {
    local dd rc=0
    dd="$(meta_get DATA_DIR "${1:-}" 2>/dev/null)" || rc=$?
    if [[ "$rc" -eq 2 ]]; then
        print_error "DATA_DIR is set more than once in .node-meta; remove the extra lines and run this again." >&2
        return 2
    fi
    if [[ -z "$dd" ]] && declare -F tn_resolve_data_dir >/dev/null 2>&1; then
        dd="$(tn_resolve_data_dir 2>/dev/null || true)"
    fi
    printf '%s\n' "${dd:-$DEFAULT_DATA_DIR}"
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
# from .node-meta (the address is blank when .node-meta records none), chain from the
# active network.
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
    # chain label tracks the active network (config.alloy reads it via sys.env("TN_CHAIN")).
    # network-gated: documents the testnet chain label
    # testnet + the empty/unknown fallback stay "adiri" so existing testnet telemetry is
    # byte-identical; devnet/mainnet map to their own chain names from lib/common.sh.
    case "${NETWORK:-}" in
        devnet)  TN_CHAIN="${DEVNET_CHAIN_NAME:-devnet}" ;;
        mainnet) TN_CHAIN="${MAINNET_CHAIN_NAME:-telcoin}" ;;
        # network-gated: chain label of testnet and of an unknown NETWORK; obs ships nothing unless NETWORK is testnet or devnet
        *)       TN_CHAIN="${TESTNET_CHAIN_NAME:-adiri}" ;;
    esac
    TN_IMAGE_VERSION="$(obs_image_version)"
}

# -----------------------------------------------------------------------------
# Config + env-file writers
# -----------------------------------------------------------------------------

# obs_write_config_alloy [dest] — deploy the Alloy config, rendering ONLY the pipeline(s)
# the operator opted into: ENABLE_OBSERVABILITY → loki.* (logs), ENABLE_METRICS →
# network-gated: names the upstream node agent config, not an endpoint
# prometheus.* (metrics). With both on it is byte-identical to the canonical, adiri-
# matching observability/config.alloy. The per-pipeline blocks are sliced straight out of
# that single checked-in source (no drift); a missing source falls back to an embedded,
# functionally-identical copy that the same slicer renders.
# <logdir> (optional, native installs): the directory reth writes telcoin-network-logs/
# under; __path__ is pointed there. The file is root-owned, group <group> (default
# root), mode 0640, so only Alloy's account can read it. rc 1 (said) when the slice,
# the chown or the chmod fails. Callers use obs_render_config_alloy, which picks
# <logdir> and <group> for this installation.
obs_write_config_alloy() {
    local dest="${1:-${OBS_ETC_DIR}/config.alloy}" logdir="${2:-}" group="${3:-root}"
    local src="$OBS_CONFIG_SRC" tmp="" rc=0
    install -d -m 0750 "$(dirname "$dest")" || rc=1
    if [[ ! -f "$src" ]]; then
        print_warn "observability/config.alloy missing; using the embedded fallback (functionally identical)."
        tmp="$(mktemp)"; _obs_alloy_fallback > "$tmp"; src="$tmp"
    fi
    if [[ "$rc" -ne 0 ]] || ! _obs_slice_alloy "$src" "$dest" "$logdir" \
        || ! chown "root:${group}" "$dest" || ! chmod 0640 "$dest"; then
        rc=1
    fi
    [[ -z "$tmp" ]] || rm -f "$tmp"
    if [[ "$rc" -ne 0 ]]; then
        print_error "Could not write ${dest} as root:${group} 0640."
        return 1
    fi
    return 0
}

# obs_render_config_alloy — write ${OBS_ETC_DIR}/config.alloy for this installation; the
# one entry point obs_enable and both partial disables use, so every path renders the
# same file. The pipelines follow ENABLE_OBSERVABILITY / ENABLE_METRICS (set them first).
# Docker: root:root with the vendored __path__ (the sidecar mounts the logs there).
# Native: group telcoin-alloy, and while logs ship __path__ points at the node log dir
# (obs_node_log_dir; the NODE_LOG_DIR global wins over .node-meta). rc 1 when
# INSTALL_METHOD, or NODE_LOG_DIR when it is read, is set twice in .node-meta (said,
# nothing written), or when the write fails (said).
obs_render_config_alloy() {
    local method logdir=""
    method="$(addon_meta_get INSTALL_METHOD binary)" || return 1
    [[ -n "$method" ]] || method="binary"
    if [[ "$method" == "docker" ]]; then
        obs_write_config_alloy "${OBS_ETC_DIR}/config.alloy"
        return
    fi
    if [[ "${ENABLE_OBSERVABILITY:-false}" == "true" ]]; then
        if [[ -z "${NODE_LOG_DIR:-}" ]]; then
            addon_meta_get NODE_LOG_DIR "" >/dev/null || return 1
        fi
        logdir="$(obs_node_log_dir)"
    fi
    obs_write_config_alloy "${OBS_ETC_DIR}/config.alloy" "$logdir" "$OBS_ALLOY_USER"
}

# obs_restart_alloy — restart the Alloy unit, then read its state once a second,
# OBS_ALLOY_SETTLE_SECS reads in all: rc 0 when every read says active. rc 1 (said) when
# the restart fails or a read says anything else; "activating" is systemd restarting a
# unit that keeps exiting (Restart=), so it counts as down.
obs_restart_alloy() {
    local n="${OBS_ALLOY_SETTLE_SECS:-5}" i=1 state
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || n=5
    if ! systemctl restart "$OBS_ALLOY_UNIT" >/dev/null 2>&1; then
        print_error "Failed to start ${OBS_ALLOY_UNIT}. Check: journalctl -u ${OBS_ALLOY_UNIT} -n 50"
        return 1
    fi
    while :; do
        state="$(systemctl is-active "$OBS_ALLOY_UNIT" 2>/dev/null || true)"
        if [[ "$state" != "active" ]]; then
            print_error "${OBS_ALLOY_UNIT} did not stay running after the restart (state: ${state:-unknown}). Check: journalctl -u ${OBS_ALLOY_UNIT} -n 50"
            return 1
        fi
        [[ "$i" -lt "$n" ]] || break
        sleep 1
        i=$((i + 1))
    done
    return 0
}

# _obs_slice_alloy <src> <dest> — copy src to dest keeping only the enabled pipeline
# blocks. Regions are delimited by River anchors that never move: the logs pipeline
# begins at `local.file_match`, the metrics pipeline at the `// --- Metrics pipeline`
# divider; everything before the first anchor is the shared header (always kept). Both
# pipelines enabled → byte-identical to src.
_obs_slice_alloy() {
    local src="$1" dest="$2" logdir="${3:-}" logs=0 metrics=0
    [[ "${ENABLE_OBSERVABILITY:-false}" == "true" ]] && logs=1
    [[ "${ENABLE_METRICS:-false}" == "true" ]] && metrics=1
    TN_OBS_LOGDIR="$logdir" awk -v logs="$logs" -v metrics="$metrics" '
        BEGIN { region = "header"; nd = ENVIRON["TN_OBS_LOGDIR"]; od = "/var/log/telcoin/telcoin-network-logs/" }
        nd != "" && /__path__/ && (i = index($0, od)) > 0 {
            $0 = substr($0, 1, i - 1) nd "/telcoin-network-logs/" substr($0, i + length(od))
        }
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
# network-gated: names the upstream node agent config, not an endpoint
# in sync with observability/config.alloy (and thus adiri).
_obs_alloy_fallback() {
    cat <<'ALLOY_EOF'
// network-gated: names the upstream node agent config, not an endpoint
// Fallback copy (canonical: observability/config.alloy, byte-identical to adiri).
// Env: TN_NODE TN_REGION TN_VALIDATOR_ADDRESS TN_CHAIN TN_IMAGE_VERSION
//      OBS_PUSH_URL OBS_PUSH_HOST TN_METRICS_ADDR OBS_METRICS_PUSH_URL
//      OBS_METRICS_PUSH_HOST CREDENTIALS_DIRECTORY (token: $CREDENTIALS_DIRECTORY/ingest-token)
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
    url               = sys.env("OBS_PUSH_URL")
    bearer_token_file = sys.env("CREDENTIALS_DIRECTORY") + "/ingest-token"

    tls_config {
      server_name = sys.env("OBS_PUSH_HOST")
      min_version = "TLS13"
    }
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
    url               = sys.env("OBS_METRICS_PUSH_URL")
    bearer_token_file = sys.env("CREDENTIALS_DIRECTORY") + "/ingest-token"

    tls_config {
      server_name = sys.env("OBS_METRICS_PUSH_HOST")
      min_version = "TLS13"
    }
  }
}
ALLOY_EOF
}

# obs_token_file -- the path of the ingest token file.
obs_token_file() {
    printf '%s\n' "${OBS_ETC_DIR}/${OBS_TOKEN_NAME}"
}

# obs_url_host <url> -- the host of a push URL (no scheme, user, port or path), the TLS
# server name config.alloy pins; empty for an empty URL.
obs_url_host() {
    local h="${1#*://}"
    h="${h%%/*}"
    h="${h%%\?*}"
    h="${h%%#*}"
    h="${h##*@}"
    if [[ "$h" == \[* ]]; then
        h="${h#\[}"
        h="${h%%\]*}"
    else
        h="${h%%:*}"
    fi
    printf '%s\n' "$h"
}

# _obs_trim_token <value> -- the value without leading and trailing whitespace (a stray
# paste newline otherwise yields silent 401s).
_obs_trim_token() {
    local t="$1"
    t="${t#"${t%%[![:space:]]*}"}"
    t="${t%"${t##*[![:space:]]}"}"
    printf '%s' "$t"
}

# _obs_token_warn <token> -- warn about a token that looks mistyped (internal
# whitespace, fewer than 16 characters). Never prints the token.
_obs_token_warn() {
    if [[ "$1" =~ [[:space:]] ]]; then
        print_warn "Ingest token contains internal whitespace — check you pasted it correctly."
    elif (( ${#1} < 16 )); then
        print_warn "Ingest token looks short (${#1} chars) — check you pasted the full token."
    fi
    return 0
}

# obs_write_token_file <token> -- write the ingest token, one line, to obs_token_file as
# root:telcoin-alloy 0640 (tn_write_root_file). The value reaches the writer on a
# process substitution run in this shell, never on argv, a pipe or a here-string (bash
# before 5.1 keeps a here-string in a temporary file). rc 1 (said) when it fails.
obs_write_token_file() {
    local f
    f="$(obs_token_file)"
    if ! tn_write_root_file "$f" 0640 "$OBS_ALLOY_USER" < <(trap - ERR; printf '%s\n' "$1"); then
        print_error "Could not write the ingest token file ${f} as root:${OBS_ALLOY_USER} 0640."
        return 1
    fi
    return 0
}

# _obs_env_token -- the OBS_INGEST_TOKEN value an env file written before the token
# file existed still holds; empty when there is none.
_obs_env_token() {
    local envf="${OBS_ETC_DIR}/telcoin-alloy.env"
    [[ -f "$envf" && -r "$envf" ]] || return 0
    sed -n 's/^OBS_INGEST_TOKEN=//p' "$envf" 2>/dev/null | head -n 1
}

OBS_TOKEN_MOVED_SAID=false

# _obs_write_env_file -- write ${OBS_ETC_DIR}/telcoin-alloy.env (root 0600) for this
# installation: identity labels, OBS_PUSH_URL and OBS_PUSH_HOST (the TLS server name),
# and with ENABLE_METRICS=true TN_METRICS_ADDR, OBS_METRICS_PUSH_URL and
# OBS_METRICS_PUSH_HOST. A docker install (INSTALL_METHOD from .node-meta) also gets
# CREDENTIALS_DIRECTORY, where the sidecar sees the token file; systemd sets it for the
# native unit. The token is never written here. An env file from before the token file
# that still holds OBS_INGEST_TOKEN= is migrated: its value goes to the token file when
# there is none yet, the rewrite drops the line, and one line per run says so. rc 1
# (said) when INSTALL_METHOD is set twice in .node-meta or a write fails.
_obs_write_env_file() {
    local envf="${OBS_ETC_DIR}/telcoin-alloy.env" method legacy tokf
    local push_url metrics_url text
    method="$(addon_meta_get INSTALL_METHOD binary)" || return 1
    obs_label_sourcing
    install -d -m 0750 "$OBS_ETC_DIR"
    tokf="$(obs_token_file)"
    legacy="$(_obs_env_token)"
    if [[ -n "$legacy" && ! -s "$tokf" ]]; then
        obs_write_token_file "$legacy" || return 1
    fi
    legacy="${legacy:+yes}"
    # Effective push URLs: explicit OBS_PUSH_URL/OBS_METRICS_PUSH_URL override wins,
    # else _DEVNET when NETWORK=devnet, else _TESTNET (unchanged for testnet).
    push_url="$(obs_effective_push_url)"
    metrics_url="$(obs_effective_metrics_url)"
    text="TN_NODE=${TN_NODE}
TN_REGION=${TN_REGION}
TN_VALIDATOR_ADDRESS=${TN_VALIDATOR_ADDRESS}
TN_CHAIN=${TN_CHAIN}
TN_IMAGE_VERSION=${TN_IMAGE_VERSION}
OBS_PUSH_URL=${push_url}
OBS_PUSH_HOST=$(obs_url_host "$push_url")"
    if [[ "${ENABLE_METRICS:-false}" == "true" ]]; then
        text="${text}
TN_METRICS_ADDR=$(obs_metrics_addr)
OBS_METRICS_PUSH_URL=${metrics_url}
OBS_METRICS_PUSH_HOST=$(obs_url_host "$metrics_url")"
    fi
    if [[ "$method" == "docker" ]]; then
        text="${text}
CREDENTIALS_DIRECTORY=${OBS_DOCKER_CRED_DIR}"
    fi
    if ! tn_write_root_file "$envf" 0600 <<< "$text"; then
        print_error "Could not write ${envf}."
        return 1
    fi
    if [[ -n "$legacy" && "$OBS_TOKEN_MOVED_SAID" != "true" ]]; then
        OBS_TOKEN_MOVED_SAID=true
        print_info "${envf} no longer holds the ingest token: it is in ${tokf} (root:${OBS_ALLOY_USER} 0640), which Alloy reads as a file, not from its environment."
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Native Alloy install (apt pin, tarball fallback)
# -----------------------------------------------------------------------------

_obs_disable_packaged_alloy() {
    # The apt `alloy` package ships its own alloy.service; we run telcoin-alloy.service
    # with our config instead, so stop/disable the packaged one to avoid a double tail.
    systemctl disable --now alloy.service >/dev/null 2>&1 || true
}

# _obs_key_fpr <keyring> <gpg-home> — the primary fingerprint of a binary keyring that
# holds exactly one primary key; rc 1 otherwise.
_obs_key_fpr() {
    local out
    out="$(gpg --homedir "$2" --batch --with-colons --show-keys "$1" 2>/dev/null)" || return 1
    printf '%s\n' "$out" | awk -F: '
        $1 == "pub" { n++; want = 1; next }
        $1 == "fpr" && want { fpr = $10 }
        { want = 0 }
        END { if (n != 1 || fpr == "") exit 1; print fpr }'
}

# _obs_grafana_key <dest> — install Grafana's apt key at <dest> (root 0644) only when
# it holds one primary key with OBS_GRAFANA_KEY_FPR. An existing <dest> with that
# fingerprint is kept; any other is replaced by a verified download. rc 1 on a failed
# download or another fingerprint (nothing installed).
_obs_grafana_key() {
    local dest="$1" tmp fpr rc=0
    tmp="$(mktemp -d)" || return 1
    mkdir -m 0700 "${tmp}/gpg" || { rm -rf "$tmp"; return 1; }
    if [[ -f "$dest" && ! -L "$dest" ]] && fpr="$(_obs_key_fpr "$dest" "${tmp}/gpg")" \
        && [[ "$fpr" == "$OBS_GRAFANA_KEY_FPR" ]]; then
        rm -rf "$tmp"
        return 0
    fi
    if ! curl --proto '=https' --tlsv1.2 -fsSL -o "${tmp}/key.asc" https://apt.grafana.com/gpg.key \
        || ! gpg --homedir "${tmp}/gpg" --batch --yes --dearmor -o "${tmp}/key.gpg" "${tmp}/key.asc" >/dev/null 2>&1; then
        print_warn "Could not download Grafana's apt key."
        rc=1
    elif ! fpr="$(_obs_key_fpr "${tmp}/key.gpg" "${tmp}/gpg")" || [[ "$fpr" != "$OBS_GRAFANA_KEY_FPR" ]]; then
        print_error "Grafana's apt key has fingerprint ${fpr:-unreadable}, not the expected ${OBS_GRAFANA_KEY_FPR}; not using the Grafana repository."
        rc=1
    elif ! tn_write_root_file "$dest" 0644 < "${tmp}/key.gpg"; then
        rc=1
    fi
    rm -rf "$tmp"
    return "$rc"
}

_obs_install_alloy_apt() {
    command -v gpg >/dev/null 2>&1 || apt-get install -y gnupg >/dev/null 2>&1 || true
    local key=/etc/apt/keyrings/grafana.gpg
    install -d -m 0755 /etc/apt/keyrings
    _obs_grafana_key "$key" || return 1
    tn_write_root_file /etc/apt/sources.list.d/grafana.list 0644 <<< "deb [signed-by=${key}] https://apt.grafana.com stable main" || return 1
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
    if ! curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "${tmp}/alloy.zip" 2>/dev/null; then
        print_error "Could not download ${url}; Alloy was not installed."
        rm -rf "$tmp"
        return 1
    fi
    # Verify the download against the release SHA256SUMS before installing; no
    # checksum, no install. Grafana ships a single SHA256SUMS per release (not a
    # per-asset .sha256 sidecar), so pull our asset's line out of it. Handles both the
    # plain ("hash  asset") and binary ("hash *asset") sums formats.
    local want got asset sums_url
    asset="alloy-linux-${arch}.zip"
    sums_url="https://github.com/grafana/alloy/releases/download/v${TN_ALLOY_NATIVE_VERSION}/SHA256SUMS"
    if ! curl --proto '=https' --tlsv1.2 -fsSL --max-time 15 "$sums_url" -o "${tmp}/SHA256SUMS" 2>/dev/null; then
        print_error "Could not fetch the Alloy checksum file (${sums_url}); Alloy was not installed."
        rm -rf "$tmp"
        return 1
    fi
    want="$(awk -v a="$asset" '{f=$2; sub(/^\*/,"",f); if (f==a){print $1; exit}}' "${tmp}/SHA256SUMS")"
    got="$(sha256sum "${tmp}/alloy.zip" 2>/dev/null | awk '{print $1}')"
    if [[ ! "$want" =~ ^[0-9a-f]{64}$ || "$want" != "$got" ]]; then
        print_error "Alloy tarball checksum ${want:+mismatch}${want:-missing for ${asset}} — refusing to install."
        rm -rf "$tmp"
        return 1
    fi
    print_ok "Alloy tarball checksum verified."
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

# obs_alloy_account — make sure the system account native Alloy runs as exists
# (OBS_ALLOY_USER, no home, no login shell). rc 1 when it cannot be created.
obs_alloy_account() {
    getent passwd "$OBS_ALLOY_USER" >/dev/null 2>&1 && return 0
    if ! useradd --system --user-group --no-create-home --home-dir "$OBS_DATA_DIR" \
        --shell /usr/sbin/nologin "$OBS_ALLOY_USER" >/dev/null 2>&1; then
        print_error "Could not create the system account ${OBS_ALLOY_USER} for Alloy."
        return 1
    fi
    return 0
}

# obs_alloy_unit_text <alloy-binary> <env-file> <supplementary-group|""> [dir...] —
# print the native unit. Alloy runs as OBS_ALLOY_USER with its state in
# StateDirectory= (systemd re-owns an older state dir to that account), reads the
# node logs through the supplementary group (telcoin-log), gets the ingest token file
# as the credential ingest-token (LoadCredential=; config.alloy reads it from
# $CREDENTIALS_DIRECTORY), writes no core dump, and cannot see the node's data dir(s)
# given as [dir...], /var/lib/telcoin, the BLS passphrase credential or the passphrase
# file.
obs_alloy_unit_text() {
    local bin="$1" envf="$2" grp="${3:-}" hidden d
    shift 3
    hidden="-/var/lib/telcoin -/etc/telcoin/bls-passphrase.cred -/etc/telcoin/bls-passphrase"
    for d in "$@"; do
        if [[ -n "$d" && "$d" != /var/lib/telcoin ]]; then
            hidden="${hidden} -${d}"
        fi
    done
    printf '%s\n' \
        '[Unit]' \
        'Description=Telcoin node log shipper (Grafana Alloy -> central Loki)' \
        'After=network-online.target' \
        'Wants=network-online.target' \
        'StartLimitIntervalSec=300' \
        'StartLimitBurst=5' \
        '' \
        '[Service]' \
        'Type=simple' \
        "User=${OBS_ALLOY_USER}" \
        "Group=${OBS_ALLOY_USER}"
    if [[ -n "$grp" ]]; then
        printf 'SupplementaryGroups=%s\n' "$grp"
    fi
    printf '%s\n' \
        "EnvironmentFile=${envf}" \
        "LoadCredential=${OBS_TOKEN_NAME}:$(obs_token_file)" \
        "ExecStart=${bin} run --server.http.listen-addr=${OBS_HTTP_ADDR} --storage.path=${OBS_DATA_DIR} ${OBS_ETC_DIR}/config.alloy" \
        "StateDirectory=${OBS_DATA_DIR##*/}" \
        'StateDirectoryMode=0750' \
        'ProtectSystem=strict' \
        "ReadWritePaths=${OBS_DATA_DIR}" \
        "InaccessiblePaths=${hidden}" \
        'ProtectHome=yes' \
        'PrivateTmp=yes' \
        'PrivateDevices=yes' \
        'NoNewPrivileges=yes' \
        'CapabilityBoundingSet=' \
        'ProtectProc=invisible' \
        'RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX' \
        'Restart=on-failure' \
        'RestartSec=10' \
        'MemoryMax=512M' \
        'CPUQuota=50%' \
        'TasksMax=256' \
        'LimitCORE=0' \
        '' \
        '[Install]' \
        'WantedBy=multi-user.target'
}

# obs_write_alloy_native_unit -- native unit (obs_alloy_unit_text, root 0644) + its env
# file (_obs_write_env_file), which systemd reads as root. Alloy joins the telcoin-log
# group when it exists. rc 1 when the env file or the unit could not be written.
obs_write_alloy_native_unit() {
    local grp="" dd text
    local envf="${OBS_ETC_DIR}/telcoin-alloy.env"
    local bin; bin="$(command -v alloy 2>/dev/null || echo /usr/bin/alloy)"
    _obs_write_env_file || return 1
    if getent group telcoin-log >/dev/null 2>&1; then
        grp="telcoin-log"
    fi
    dd="$(_obs_data_dir 2>/dev/null)" || dd=""
    text="$(obs_alloy_unit_text "$bin" "$envf" "$grp" "$dd")" || return 1
    tn_write_root_file "${TN_ROOT_PREFIX:-}/etc/systemd/system/${OBS_ALLOY_UNIT}" 0644 <<< "$text" || return 1
    systemctl daemon-reload
}

# obs_alloy_docker_unit_text <env-file> <log_host_dir> <gid> -- print the docker-sidecar
# network-gated: names the core team's testnet sidecar this unit copies; no endpoint
# unit. Mirrors the adiri start-validator-node.sh sidecar (container telcoin-alloy, host
# network, RO config + logs), but supervised by systemd so it is greppable and restarts
# with the host. The ExecStart uses backslash continuations that bash collapses to one
# line on render (same as the node units), which systemd accepts.
#
# The ingest token file is bind-mounted read-only at ${OBS_DOCKER_CRED_DIR}/ingest-token
# (the env file sets CREDENTIALS_DIRECTORY there, so the one config.alloy serves both
# runtimes). --mount, not -v: a missing source file stops the start instead of docker
# creating a directory in its place. The image runs as uid 0 with every capability
# dropped, which reads the root-owned 0640 file as its owner; --group-add <gid of
# telcoin-alloy> also lets an image that runs as its own alloy user (473) read it. No
# core dumps: LimitCORE=0 covers the docker client, --ulimit core=0 the container.
#
# Storage dir is bind-mounted at the SAME absolute path inside the container
# (${OBS_DATA_DIR}:${OBS_DATA_DIR}) and passed verbatim to --storage.path, matching the
# native unit. Do NOT mount it under the image's /var/lib/alloy: that dir is owned by the
# image's alloy user (473:473, mode 0770) and --cap-drop=ALL strips CAP_DAC_OVERRIDE, so
# container-root cannot traverse it -> Alloy dies with "mkdir /var/lib/alloy/data:
# permission denied". /var/lib (root:root) is traversable, so this placement keeps every
# hardening flag intact.
obs_alloy_docker_unit_text() {
    local envf="$1" log_host_dir="$2" gid="$3"
    cat <<EOF
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
--ulimit core=0 \
--cap-drop=ALL \
--security-opt=no-new-privileges \
--group-add ${gid} \
--env-file ${envf} \
-v ${OBS_ETC_DIR}/config.alloy:/etc/alloy/config.alloy:ro \
--mount type=bind,source=$(obs_token_file),target=${OBS_DOCKER_CRED_DIR}/${OBS_TOKEN_NAME},readonly \
-v ${log_host_dir}:/var/log/telcoin:ro \
-v ${OBS_DATA_DIR}:${OBS_DATA_DIR} \
${TN_ALLOY_IMAGE} run \
--server.http.listen-addr=${OBS_HTTP_ADDR} \
--storage.path=${OBS_DATA_DIR} \
/etc/alloy/config.alloy
ExecStop=/usr/bin/docker stop telcoin-alloy
Restart=on-failure
RestartSec=10
LimitCORE=0

[Install]
WantedBy=multi-user.target
EOF
}

# obs_run_alloy_docker <log_host_dir> -- the docker-sidecar unit
# (obs_alloy_docker_unit_text, root 0644) + its env file (_obs_write_env_file). rc 1
# (said) when the telcoin-alloy group is missing or a write fails.
obs_run_alloy_docker() {
    local log_host_dir="$1" gid text
    local envf="${OBS_ETC_DIR}/telcoin-alloy.env"
    _obs_write_env_file || return 1
    gid="$(getent group "$OBS_ALLOY_USER" 2>/dev/null | cut -d: -f3)"
    if [[ ! "$gid" =~ ^[0-9]+$ ]]; then
        print_error "There is no ${OBS_ALLOY_USER} group, so the Alloy sidecar could not read the ingest token file."
        return 1
    fi
    text="$(obs_alloy_docker_unit_text "$envf" "$log_host_dir" "$gid")"
    tn_write_root_file "${TN_ROOT_PREFIX:-}/etc/systemd/system/${OBS_ALLOY_UNIT}" 0644 <<< "$text" || return 1
    systemctl daemon-reload
}

# obs_write_alloy_units -- the env file and the unit for this installation
# (INSTALL_METHOD from .node-meta): the sidecar unit for docker (logs from
# <data dir>/logs), the native unit otherwise. rc 1 (said) when .node-meta repeats
# INSTALL_METHOD or DATA_DIR, or a write fails.
obs_write_alloy_units() {
    local method dd
    method="$(addon_meta_get INSTALL_METHOD binary)" || return 1
    if [[ "$method" == "docker" ]]; then
        dd="$(_obs_data_dir "$(node_meta_path || true)")" || return 1
        obs_run_alloy_docker "${dd}/logs"
        return
    fi
    obs_write_alloy_native_unit
}

# obs_render_alloy -- every file Alloy runs from, for this installation: config.alloy
# (obs_render_config_alloy, following ENABLE_OBSERVABILITY / ENABLE_METRICS), the env
# file and the unit (obs_write_alloy_units, which also moves a token still in the env
# file into the token file), after making sure the telcoin-alloy account exists (its
# group owns the token file on docker installs too). The partial disables and
# --rotate-token use it, so a host still on the env-file token is migrated whenever
# Alloy is restarted. rc 1 (said) when a step fails.
obs_render_alloy() {
    obs_alloy_account || return 1
    obs_render_config_alloy || return 1
    if ! obs_write_alloy_units; then
        print_error "Could not write the ${OBS_ALLOY_UNIT} unit or its env file."
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Launch-file edits and node restarts (lib/common.sh helpers, soft-guarded)
# -----------------------------------------------------------------------------
#
# Helpers from a lib/common.sh newer than 1.4.0, used when present. On an older
# library each one falls back to the behaviour of lib/observability.sh 1.0.1, with
# one warning per run naming what is lost (a box half-way through update-scripts.sh
# keeps working):
#   tn_launch_flag_get (1.6.0)      reads one flag of the live node command, so a
#                                   commented-out flag no longer counts as present.
#                                   Its arrival also brings the return codes of
#                                   tn_node_inject_flags that obs_inject_flags reports.
#   tn_wait_restart_window (1.5.0)  holds the restart of a committee node until the
#                                   current epoch has closed and settled.

OBS_LIB_WARNED=""

# OBS_FLAG_ERROR -- why the last obs_enable / obs_ensure_reth_flags / obs_inject_flags
# call left a flag the node needs off its launch line, one reason per line; empty when
# nothing is missing. setup-observability.sh --json reports it as error events.
OBS_FLAG_ERROR=""

# OBS_ALLOY_TOUCHED -- obs_enable sets it to true once it starts rewriting Alloy's config;
# false means a failed obs_enable changed nothing.
OBS_ALLOY_TOUCHED=false
_OBS_FLAGS_CHANGED=0

# _obs_flag_error MSG -- warn MSG and add it to OBS_FLAG_ERROR.
_obs_flag_error() {
    print_warn "$1"
    if [[ -n "$OBS_FLAG_ERROR" ]]; then
        OBS_FLAG_ERROR="${OBS_FLAG_ERROR}"$'\n'"$1"
    else
        OBS_FLAG_ERROR="$1"
    fi
    return 0
}

# _obs_lib_has FN CONSEQUENCE [SAY-FN] -- rc 0 when lib/common.sh defines FN. Otherwise
# warn, once per run for each FN, that CONSEQUENCE, and return 1. The warning goes
# through SAY-FN (`fn warn MSG`, so a --json caller turns it into a warn event) when
# one is given, else print_warn.
_obs_lib_has() {
    local fn="$1" consequence="$2" say="${3:-}" msg
    if declare -F "$fn" >/dev/null 2>&1; then
        return 0
    fi
    case " ${OBS_LIB_WARNED} " in
        *" ${fn} "*) return 1 ;;
    esac
    OBS_LIB_WARNED="${OBS_LIB_WARNED} ${fn}"
    msg="lib/common.sh ${COMMON_VERSION:-unknown} has no ${fn}, so ${consequence}. Run update-scripts.sh to update the library."
    if [[ -n "$say" ]] && declare -F "$say" >/dev/null 2>&1; then
        "$say" warn "$msg" || true
    else
        print_warn "$msg"
    fi
    return 1
}

_OBS_NO_FLAG_GET="a commented-out flag counts as present and a failed flag edit is not explained"
_OBS_NO_WAIT="the node restarts without waiting for the epoch boundary, even when it is in the committee"

# obs_lib_check [SAY-FN] -- warn now (once per run each) about the lib/common.sh helpers
# this file is falling back without, through SAY-FN as in _obs_lib_has. For a status
# screen, and for the start of an enable, so the operator hears it before anything
# changes. Always rc 0.
obs_lib_check() {
    _obs_lib_has tn_launch_flag_get "$_OBS_NO_FLAG_GET" "${1:-}" || true
    _obs_lib_has tn_wait_restart_window "$_OBS_NO_WAIT" "${1:-}" || true
    return 0
}

# obs_wait_say <step|log|warn> <msg> -- the default progress printer for the epoch
# wait: print_* lines, like everything else this file prints.
obs_wait_say() {
    case "${1:-}" in
        step) print_step "${2:-}" ;;
        warn) print_warn "${2:-}" ;;
        *)    print_info "${2:-}" ;;
    esac
    return 0
}

# obs_restart_window [progress-fn] -- call right before restarting the NODE (not the
# Alloy shipper, which takes no part in consensus). First the committee guard
# (obs_quorum_guard), then, when the node votes in the current committee and the
# epoch boundary is close, tn_wait_restart_window (lib/common.sh) holds the restart
# until the epoch has closed and settled, at most TN_EPOCH_WAIT_MAX seconds, and
# the guard runs again after it;
# TN_SKIP_EPOCH_WAIT=1 skips it, and a lib/common.sh without it skips it with a
# warning (the guard still runs). progress-fn is called as `fn step|log|warn MSG`
# (default obs_wait_say). rc 0 restart now; rc 1 the guard refused or the wait
# failed (said; the caller does not restart).
obs_restart_window() {
    local fn="${1:-}" rc=0
    if [[ -z "$fn" ]] || ! declare -F "$fn" >/dev/null 2>&1; then
        fn="obs_wait_say"
    fi
    obs_quorum_guard "$fn" || return 1
    _obs_lib_has tn_wait_restart_window "$_OBS_NO_WAIT" "$fn" || return 0
    tn_wait_restart_window "" "$fn" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        "$fn" warn "Not restarting: the epoch-boundary wait failed (rc ${rc})." || true
        return 1
    fi
    # The wait can last up to TN_EPOCH_WAIT_MAX: the guard again, right before
    # the restart.
    obs_quorum_guard "$fn" || return 1
    return 0
}

# obs_quorum_guard [progress-fn] — rc 0 when a node restart may go ahead now: the
# committee guard (tn_committee_down_guard) passes. It warns and passes on testnet,
# on devnet and for a node that is not staked when the committee cannot be read, and
# passes with TN_ALLOW_QUORUM_RISK=1. rc 1 (said; the caller does not restart) when
# the restart would leave the committee without a quorum (guard rc 1), or the
# committee cannot be read on a staked mainnet node or an unknown network (rc 2).
# TN_ALLOW_QUORUM_RISK=1 (which the guard honours itself) lets either through.
obs_quorum_guard() {
    local fn="${1:-obs_wait_say}" rc=0
    declare -F "$fn" >/dev/null 2>&1 || fn="obs_wait_say"
    tn_committee_down_guard "" "$fn" || rc=$?
    if [[ "$rc" -ne 0 && "${TN_ALLOW_QUORUM_RISK:-}" == "1" ]]; then
        "$fn" warn "TN_ALLOW_QUORUM_RISK=1: restarting although the committee check did not pass." || true
        return 0
    fi
    case "$rc" in
        0) return 0 ;;
        2) "$fn" warn "Not restarting: the committee could not be read on a node whose vote counts (see above). Restart later, or set TN_ALLOW_QUORUM_RISK=1 once the other members are confirmed up." || true ;;
        *) "$fn" warn "Not restarting: the committee could lose its quorum (see above). Restart later, or set TN_ALLOW_QUORUM_RISK=1 for a coordinated restart." || true ;;
    esac
    return 1
}

# obs_restart_hint SVC -- how to restart the node later without landing on an epoch
# change: edit-config.sh's Restart node waits for the boundary first.
obs_restart_hint() {
    printf 'Restart %s with edit-config.sh, menu item 12 (Restart node): sudo bash %s/edit-config.sh. It waits for the epoch boundary first when the node is in the committee. A plain systemctl restart does not wait: use one (or TN_SKIP_EPOCH_WAIT=1) only if you accept restarting the node at an epoch change.' "${1:-telcoin}" "${SCRIPT_DIR:-.}"
}

# obs_inject_flags FILE MARKER_ERE FLAGS [SHOWN] -- add FLAGS to the node command in
# launch file FILE with tn_node_inject_flags (lib/common.sh) unless MARKER_ERE is already
# on a live line, and say what happened, naming the file SHOWN (default FILE; a dry run
# edits a scratch copy). A failure message also goes to OBS_FLAG_ERROR. Returns the
# helper's rc: 0 added (the caller reloads and restarts), 1 MARKER_ERE already on a live
# line (reported as present only when the first flag of FLAGS is on the node command;
# a match in a trailing comment or another command is reported as a failure), 2 no node
# launch line in FILE, 3 refused (the line ends in a comment, or the command cannot be
# edited safely), 4 FILE could not be read or written. FILE is unchanged unless rc is 0.
# A lib/common.sh older than 1.6.0 returns 1 both for "already there" and for "no
# launch line", and the message says so; callers that must know check the flag after.
obs_inject_flags() {
    local file="$1" marker="$2" flags="$3" shown="${4:-$1}" rc=0 err reason
    err="$(tn_node_inject_flags "$file" "$marker" "$flags" 2>&1 >/dev/null)" || rc=$?
    if [[ "$rc" -ne 0 ]] && ! declare -F tn_launch_flag_get >/dev/null 2>&1; then
        _obs_flag_error "Did not add ${flags%% *} to ${shown}: it is already there, or the file has no node launch line. If it is missing, add it to the node command by hand: ${flags}"
        return "$rc"
    fi
    case "$rc" in
        0) ;;
        1) if tn_launch_flag_get "$file" "${flags%% *}" >/dev/null 2>&1; then
               print_info "${flags%% *} is already on the node command in ${shown}; nothing to add."
           else
               _obs_flag_error "${flags%% *} appears in ${shown} only outside the node command (in a comment or on another line), so it was not added. Add it to the node command by hand: ${flags}"
           fi ;;
        2) _obs_flag_error "${shown} has no live node command (an uncommented line that runs node with --http), so ${flags%% *} was not added. Add it by hand to the command that starts the node: ${flags}" ;;
        3) reason="$(printf '%s\n' "$err" | sed -n '1s/^tn_node_inject_flags: //p')"
           [[ -n "$reason" ]] || reason="the node command ends in a # comment, or is not one simple command that can be edited safely"
           _obs_flag_error "Edit the launch file by hand: ${reason}. Add to the node command in ${shown}: ${flags}" ;;
        *) _obs_flag_error "Could not read or write ${shown}; nothing was changed. Add to the node command by hand: ${flags}" ;;
    esac
    return "$rc"
}

# _obs_log_format FILE HAVE_GET -- print the --log.file.format value of the node
# command in launch file FILE (empty for a bare flag); rc 1 when it has none. With
# HAVE_GET false (lib/common.sh older than 1.6.0) it is the 1.0.1 test: the text
# "--log.file.format json" anywhere in FILE, comment lines included, prints json.
_obs_log_format() {
    if [[ "${2:-false}" == "true" ]]; then
        tn_launch_flag_get "$1" --log.file.format 2>/dev/null || return 1
        return 0
    fi
    grep -q -- '--log.file.format json' "$1" 2>/dev/null || return 1
    printf 'json\n'
}

# _obs_has_metrics FILE HAVE_GET -- rc 0 when the node command in launch file FILE
# has --metrics; with HAVE_GET false, the 1.0.1 test (the text anywhere in FILE).
_obs_has_metrics() {
    if [[ "${2:-false}" == "true" ]]; then
        tn_launch_flag_get "$1" --metrics >/dev/null 2>&1 || return 1
        return 0
    fi
    grep -q -- '--metrics' "$1" 2>/dev/null || return 1
    return 0
}

# -----------------------------------------------------------------------------
# Ensure the running node actually writes JSON logs (standalone-enable path)
# -----------------------------------------------------------------------------

# _obs_flags_apply FILE SHOWN SVC METHOD HAVE_GET -- put the flags the enabled pipelines
# need on the node command in launch file FILE, naming it SHOWN in messages (FILE is a
# scratch copy during obs_check_reth_flags). Sets _OBS_FLAGS_CHANGED to 1 when FILE
# changed. rc 1 when a needed flag is still missing afterwards, the reasons added to
# OBS_FLAG_ERROR. HAVE_GET false means a lib/common.sh older than 1.6.0 (1.0.1 tests).
_obs_flags_apply() {
    local file="$1" shown="$2" svc="$3" method="$4" have_get="$5" rc val errs flags failed=0
    _OBS_FLAGS_CHANGED=0
    if [[ "${ENABLE_OBSERVABILITY:-false}" == "true" ]]; then
        flags="$(obs_reth_log_flags "$method")"
        rc=0
        val="$(_obs_log_format "$file" "$have_get")" || rc=$?
        if [[ "$rc" -eq 0 && "$val" == "json" ]]; then
            print_ok "Node already writes JSON logs."
        elif [[ "$rc" -eq 0 ]]; then
            # Adding a second --log.file.format would leave the command with two.
            _obs_flag_error "The node command in ${shown} has --log.file.format ${val:-with no value}, and log shipping needs json. Change it to json by hand, then run this enable again."
            failed=1
        else
            print_step "Enabling JSON node logs"
            errs="$OBS_FLAG_ERROR"
            if obs_inject_flags "$file" '--log.file.format json' "$flags" "$shown"; then
                _OBS_FLAGS_CHANGED=1
            fi
            rc=0
            val="$(_obs_log_format "$file" "$have_get")" || rc=$?
            if [[ "$rc" -ne 0 || "$val" != "json" ]]; then
                if [[ "$OBS_FLAG_ERROR" == "$errs" ]]; then
                    _obs_flag_error "--log.file.format json is not on the node command in ${shown}. Add it by hand: ${flags}"
                fi
                failed=1
            fi
        fi
        # Binary installs write their JSON logs to the node log dir (NODE_LOG_DIR), not
        # to the root-owned log dir an older release named.
        if [[ "$method" != "docker" && "$have_get" == "true" && "$failed" -eq 0 ]]; then
            local want_dir cur_dir
            want_dir="$(obs_node_log_dir)"
            cur_dir="$(tn_launch_flag_get "$file" --log.file.directory 2>/dev/null)" || cur_dir=""
            if [[ "$cur_dir" != "$want_dir" ]]; then
                rc=0
                tn_launch_flag_set "$file" --log.file.directory "$want_dir" >/dev/null 2>&1 || rc=$?
                case "$rc" in
                    0) print_step "Pointing the node's JSON logs at ${want_dir}"; _OBS_FLAGS_CHANGED=1 ;;
                    1) ;;
                    *) _obs_flag_error "Could not set --log.file.directory ${want_dir} on the node command in ${shown}. Set it by hand, then run this enable again."
                       failed=1 ;;
                esac
            fi
        fi
    fi

    if [[ "${ENABLE_METRICS:-false}" == "true" ]]; then
        if _obs_has_metrics "$file" "$have_get"; then
            print_ok "Node already serves a metrics endpoint (--metrics)."
        elif ! flags="$(obs_metrics_reth_flags)"; then
            _obs_flag_error "$(_obs_bad_port_msg)"
            failed=1
        else
            print_step "Enabling node metrics endpoint"
            errs="$OBS_FLAG_ERROR"
            if obs_inject_flags "$file" '--metrics' "$flags" "$shown"; then
                _OBS_FLAGS_CHANGED=1
            fi
            if ! _obs_has_metrics "$file" "$have_get"; then
                if [[ "$OBS_FLAG_ERROR" == "$errs" ]]; then
                    _obs_flag_error "--metrics is not on the node command in ${shown}. Add it by hand: ${flags}"
                fi
                failed=1
            fi
        fi
    fi
    return "$failed"
}

# obs_check_reth_flags -- before obs_enable touches Alloy: would every flag the enabled
# pipelines need end up on the node command? The same edits run on a scratch copy of the
# launch file (same file name, so a unit is read as a unit; made read-only when the real
# file cannot be written). Prints nothing when they would; otherwise warns with each
# reason (naming the real file) and returns 1, the reasons in OBS_FLAG_ERROR. rc 0 when
# no node service is found (obs_ensure_reth_flags says so later) or no scratch copy can
# be made (the real edit then reports its own failure).
obs_check_reth_flags() {
    local target svc method file have_get=false tmpd="" copy failed=0 line
    OBS_FLAG_ERROR=""
    target="$(tn_node_launch_target 2>/dev/null)" || return 0
    read -r svc method file <<< "$target"
    if declare -F tn_launch_flag_get >/dev/null 2>&1; then
        have_get=true
    fi
    copy="$file"     # a missing file: every read and edit fails the same way, nothing is written
    if [[ -f "$file" ]]; then
        # Under /run (root-owned, closed to others): the launch writer refuses a copy
        # in a directory such as /tmp.
        tmpd="$(mktemp -d "${TN_OBS_RUN_PARENT:-/run}/tn-obs.XXXXXX" 2>/dev/null || true)"
        [[ -n "$tmpd" && -d "$tmpd" ]] || return 0
        copy="${tmpd}/${file##*/}"
        if ! cp "$file" "$copy" 2>/dev/null; then
            rm -rf "$tmpd"
            return 0
        fi
        if [[ ! -w "$file" ]]; then
            chmod a-w "$copy" 2>/dev/null || true
        fi
    fi
    _obs_flags_apply "$copy" "$file" "$svc" "$method" "$have_get" >/dev/null 2>&1 || failed=1
    if [[ -n "$tmpd" ]]; then
        rm -rf "$tmpd"
    fi
    _OBS_FLAGS_CHANGED=0
    if [[ "$failed" -eq 1 ]]; then
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                print_warn "$line"
            fi
        done <<< "$OBS_FLAG_ERROR"
        return 1
    fi
    return 0
}

# _obs_unit_has_log_dir SVC DIR -- rc 0 when the unit of SVC joins the telcoin-log
# group and lists DIR in ReadWritePaths=.
_obs_unit_has_log_dir() {
    local unit="${TN_ROOT_PREFIX:-}/etc/systemd/system/${1}.service"
    [[ -r "$unit" ]] || return 1
    grep -qxF "SupplementaryGroups=telcoin-log" "$unit" || return 1
    TN_OBS_D="${2%/}" awk 'index($0, "ReadWritePaths=") == 1 {
        n = split(substr($0, 16), w, " ")
        for (i = 1; i <= n; i++) if (w[i] == ENVIRON["TN_OBS_D"]) f = 1
    } END { exit f ? 0 : 1 }' "$unit"
}

# obs_ensure_reth_flags [progress-fn] — when obs is enabled AFTER setup
# (setup-observability.sh) the node may already be running WITHOUT the reth flags the
# enabled pipelines need: the JSON-log flags (logs → Alloy has something to tail) and/or
# --metrics (metrics → a registry to scrape). Idempotently inject whichever are missing
# into the node's launch file (tn_node_launch_target: the start wrapper, or the systemd
# unit of an old docker install) and offer ONE restart for all of them, after the epoch
# wait (obs_restart_window; progress-fn as there). Presence is read from the live node
# command (tn_launch_flag_get), so a commented-out flag does not count. In the first-pass
# setup the flags are already baked (ask-early), so this is a no-op there. Reads
# ENABLE_OBSERVABILITY / ENABLE_METRICS.
# rc 0 when every flag the enabled pipelines need is on the node command afterwards (or
# no node service was found: nothing to check). rc 1 when one is still missing; each
# reason is in OBS_FLAG_ERROR, and the node is not restarted, since the operator has to
# edit the launch file and restart it anyway.
obs_ensure_reth_flags() {
    local fn="${1:-}" target svc method file have_get=false failed=0 unit_changed=0
    OBS_FLAG_ERROR=""
    _OBS_FLAGS_CHANGED=0
    target="$(tn_node_launch_target)" || { print_warn "No telcoin node service detected; skipping reth flag check."; return 0; }
    read -r svc method file <<< "$target"
    # A binary node that writes JSON logs runs from a unit that lets it reach
    # NODE_LOG_DIR (ReadWritePaths= and the telcoin-log group): re-render the
    # start script and unit first (the node arguments are kept), or refuse with
    # nothing changed.
    if [[ "$method" != "docker" && "${ENABLE_OBSERVABILITY:-false}" == "true" && -n "${NODE_LOG_DIR:-}" ]] \
        && ! _obs_unit_has_log_dir "$svc" "$NODE_LOG_DIR"; then
        if ! declare -F tn_rerender_node_launch >/dev/null 2>&1 || ! tn_rerender_node_launch "" "$fn"; then
            _obs_flag_error "Could not rewrite the ${svc} unit so the node can write its JSON logs to ${NODE_LOG_DIR} (see above; run update-scripts.sh, then update-node.sh or edit-config.sh --migrate-credential to move the unit to the current form), then run this enable again."
            return 1
        fi
        unit_changed=1
        target="$(tn_node_launch_target)" || { print_warn "No telcoin node service detected after the rewrite."; return 1; }
        read -r svc method file <<< "$target"
    fi
    if _obs_lib_has tn_launch_flag_get "$_OBS_NO_FLAG_GET" "$fn"; then
        have_get=true
    fi
    _obs_flags_apply "$file" "$file" "$svc" "$method" "$have_get" || failed=1

    if [[ "$unit_changed" -eq 1 ]] || [[ "$_OBS_FLAGS_CHANGED" -eq 1 && "$method" == "docker" ]]; then
        systemctl daemon-reload
    fi
    if [[ "$failed" -eq 1 ]]; then
        if [[ "$_OBS_FLAGS_CHANGED" -eq 1 || "$unit_changed" -eq 1 ]]; then
            print_info "Not restarting ${svc} yet: fix its launch file as described above, then run this enable again."
        fi
        return 1
    fi
    [[ "$_OBS_FLAGS_CHANGED" -eq 1 || "$unit_changed" -eq 1 ]] || return 0

    print_warn "The node must restart to pick up the new reth flags."
    if confirm "Restart ${svc} now?"; then
        if ! obs_restart_window "$fn"; then
            print_info "Restart later. $(obs_restart_hint "$svc")"
        elif systemctl restart "$svc"; then
            print_ok "${svc} restarted."
        else
            print_warn "Restart failed; check journalctl -u ${svc} -n 50. $(obs_restart_hint "$svc")"
        fi
    else
        print_info "Restart later. $(obs_restart_hint "$svc")"
    fi
}

# -----------------------------------------------------------------------------
# enable / disable / status
# -----------------------------------------------------------------------------

# obs_enable <token> [progress-fn] — set up + start the Alloy shipper for whichever
# pipelines the caller has enabled (ENABLE_OBSERVABILITY = logs, ENABLE_METRICS = metrics;
# set them to the desired FINAL state before calling), render config.alloy + the mode-600
# env file to match, ensure the node carries the matching reth flags, and record state.
# Idempotent — safe to re-run to flip one pipeline on/off (it restarts Alloy to load the
# new config; Alloy restarts never wait for the epoch boundary). progress-fn reports the
# epoch wait before a node restart (see obs_restart_window). After the restart Alloy
# must stay active for OBS_ALLOY_SETTLE_SECS seconds (obs_restart_alloy). The single
# ingest token serves BOTH pipelines (one obs-hub gate). rc 1 on any failure; when the
# cause is a node flag that could not be added, OBS_FLAG_ERROR says why and .node-meta
# is left as it was.
# obs_prepare_node_log_dir — create the node log dir (NODE_LOG_DIR from .node-meta,
# else /var/log/telcoin/node) as SERVICE_USER:telcoin-log 2750 with install -d (no
# recursive chown; an existing dir gets that owner and mode) and print it. The
# setgid bit gives what the node writes there group telcoin-log, readable by
# Alloy under the unit's UMask=0027. Refused (rc 1, said): a duplicated NODE_LOG_DIR, no
# telcoin-log group, a path that is not absolute or is a symlink, or a parent that is
# not a root-owned directory closed to others.
obs_prepare_node_log_dir() {
    local d parent
    d="$(addon_meta_get NODE_LOG_DIR "$OBS_NODE_LOG_DIR_DEFAULT")" || return 1
    [[ -n "$d" ]] || d="$OBS_NODE_LOG_DIR_DEFAULT"
    if ! getent group telcoin-log >/dev/null 2>&1; then
        print_error "There is no telcoin-log group, so the node log dir ${d} cannot be created. Run update-node.sh or edit-config.sh once (they move the host to the root-owned layout), then this enable again."
        return 1
    fi
    parent="${d%/*}"
    if [[ "$d" != /* || -L "$d" || -z "$parent" ]] || ! tn_root_dir_ok "$parent"; then
        print_error "Refusing the node log dir ${d}: it must be an absolute path that is not a symlink, inside a root-owned directory closed to others."
        return 1
    fi
    if ! install -d -o "$SERVICE_USER" -g telcoin-log -m 2750 -- "$d"; then
        print_error "Could not create the node log dir ${d}."
        return 1
    fi
    printf '%s\n' "$d"
}

obs_enable() {
    local token="${1:-}" progress="${2:-}"
    OBS_FLAG_ERROR=""
    OBS_ALLOY_TOUCHED=false
    token="$(_obs_trim_token "$token")"
    [[ -n "$token" ]] || { print_error "obs_enable: empty ingest token."; return 1; }
    _obs_token_warn "$token"

    local logs_on="${ENABLE_OBSERVABILITY:-false}" metrics_on="${ENABLE_METRICS:-false}"
    if [[ "$logs_on" != "true" && "$metrics_on" != "true" ]]; then
        print_error "obs_enable: neither pipeline enabled (set ENABLE_OBSERVABILITY and/or ENABLE_METRICS)."
        return 1
    fi

    # Fail closed: refuse to write an Alloy config that ships nowhere. On devnet the
    # push URLs default to empty (no public hub baked in) — the operator must set
    # OBS_PUSH_URL/OBS_METRICS_PUSH_URL (env or --push-url/--metrics-push-url) first.
    # network-gated: documents the testnet case of the fail-closed check
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
    if [[ "$metrics_on" == "true" ]] && ! obs_metrics_addr >/dev/null; then
        _obs_flag_error "$(_obs_bad_port_msg)"
        return 1
    fi
    # Before Alloy is touched: every flag the enabled pipelines need must be able to go
    # on the node command, so a launch file that cannot take them changes nothing.
    if ! obs_check_reth_flags; then
        print_info "Nothing was changed. Fix the node launch file as described above, then run this enable again."
        return 1
    fi

    local meta method nld="" dd
    meta="$(node_meta_path || true)"
    method="$(addon_meta_get INSTALL_METHOD binary)" || return 1
    [[ -n "$method" ]] || method="binary"

    if [[ "$method" != "docker" ]]; then
        # Native Alloy reads the node log dir through the telcoin-log group.
        if [[ "$logs_on" == "true" ]]; then
            nld="$(obs_prepare_node_log_dir)" || return 1
            NODE_LOG_DIR="$nld"
            # Recorded before the node's unit is re-rendered for it (obs_ensure_reth_flags).
            [[ -z "$meta" ]] || meta_set NODE_LOG_DIR "$nld" "$meta"
        fi
        if ! getent group telcoin-log >/dev/null 2>&1; then
            print_warn "There is no telcoin-log group on this host, so Alloy cannot read the node logs. Run update-node.sh or edit-config.sh once (they move the host to the root-owned layout and create the group), then this enable again."
        fi
    fi
    # Native Alloy runs as this account; on docker its group owns the token file.
    obs_alloy_account || return 1

    OBS_ALLOY_TOUCHED=true
    if [[ "$method" == "docker" ]]; then
        install -d -m 0750 "$OBS_ETC_DIR"
        obs_render_config_alloy || return 1
        obs_write_token_file "$token" || return 1
        local log_host_dir
        dd="$(_obs_data_dir "$meta")" || return 1
        log_host_dir="${dd}/logs"
        # Inside the data dir: created by the service user, never chowned by root.
        if ! tn_as_service_user mkdir -p -m 0755 -- "$log_host_dir"; then
            print_error "Could not create ${log_host_dir} as ${SERVICE_USER}."
            return 1
        fi
        install -d -m 0750 "$OBS_DATA_DIR"
        obs_run_alloy_docker "$log_host_dir" || { print_error "Could not write the ${OBS_ALLOY_UNIT} unit."; return 1; }
    else
        install -d -m 0750 -o root -g "$OBS_ALLOY_USER" "$OBS_ETC_DIR"
        chgrp "$OBS_ALLOY_USER" "$OBS_ETC_DIR" 2>/dev/null || true
        obs_render_config_alloy || return 1
        obs_write_token_file "$token" || return 1
        if ! obs_install_alloy_native; then
            print_error "Could not install Alloy natively (apt + tarball both failed, or the download did not verify)."
            return 1
        fi
        obs_write_alloy_native_unit || { print_error "Could not write the ${OBS_ALLOY_UNIT} unit."; return 1; }
    fi

    # enable (boot) + restart (now): restart also reloads a rewritten config/env when the
    # unit is already running (e.g. flipping metrics on while logs already ship).
    systemctl enable "$OBS_ALLOY_UNIT" >/dev/null 2>&1 || true
    obs_restart_alloy || return 1
    print_ok "Telemetry shipper running (${OBS_ALLOY_UNIT})."

    # A pipeline whose node flags are missing is not recorded as enabled, so status
    # readers (the UI's add-ons card reads .node-meta) never show a half-applied enable.
    # obs_check_reth_flags made this rare (the launch file changed in between, or the
    # real write failed); Alloy then keeps the config rendered above and ships nothing
    # for that pipeline until the launch file is fixed and this enable is run again.
    if ! obs_ensure_reth_flags "$progress"; then
        print_info "Not recorded as enabled until the node launch file has the flags above; fix it, then run this enable again."
        return 1
    fi

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

# obs_existing_token -- echo the ingest token already stored on this node, so a second
# pipeline can be enabled without re-pasting the shared token: the first line of the
# token file, else the OBS_INGEST_TOKEN line of an env file written before the token
# file existed. Stays local (returned to the caller, never logged). Empty if neither
# holds one.
obs_existing_token() {
    local f t=""
    f="$(obs_token_file)"
    if [[ -f "$f" && ! -L "$f" && -r "$f" ]]; then
        t="$(head -n 1 -- "$f" 2>/dev/null)" || t=""
    fi
    [[ -n "$t" ]] || t="$(_obs_env_token)"
    [[ -z "$t" ]] || printf '%s\n' "$t"
    return 0
}

# _obs_snapshot FILE... -- remember each FILE's content, mode and group, or that it is
# absent, for _obs_restore (the files obs_rotate_token rewrites). Held in shell
# variables only. rc 1 when a file cannot be read.
_OBS_SNAP_PATH=()
_OBS_SNAP_MODE=()
_OBS_SNAP_GRP=()
_OBS_SNAP_BODY=()
_obs_snapshot() {
    local f st body
    _OBS_SNAP_PATH=()
    _OBS_SNAP_MODE=()
    _OBS_SNAP_GRP=()
    _OBS_SNAP_BODY=()
    for f in "$@"; do
        _OBS_SNAP_PATH+=("$f")
        if [[ -f "$f" && ! -L "$f" ]]; then
            st="$(stat -c '%a %G' -- "$f" 2>/dev/null)" || return 1
            body="$(cat -- "$f")" || return 1
            _OBS_SNAP_MODE+=("${st%% *}")
            _OBS_SNAP_GRP+=("${st#* }")
            _OBS_SNAP_BODY+=("$body")
        else
            _OBS_SNAP_MODE+=("-")
            _OBS_SNAP_GRP+=("")
            _OBS_SNAP_BODY+=("")
        fi
    done
    return 0
}

# _obs_restore -- put back every file _obs_snapshot remembered, with its mode and group
# (tn_write_root_file, fed like obs_write_token_file), shred one that was absent, then
# reload systemd and forget the copies. rc 1 when a write failed.
_obs_restore() {
    local i=0 rc=0
    while [[ "$i" -lt "${#_OBS_SNAP_PATH[@]}" ]]; do
        if [[ "${_OBS_SNAP_MODE[$i]}" == "-" ]]; then
            _tn_shred "${_OBS_SNAP_PATH[$i]}"
        elif ! tn_write_root_file "${_OBS_SNAP_PATH[$i]}" "${_OBS_SNAP_MODE[$i]}" "${_OBS_SNAP_GRP[$i]}" \
                < <(trap - ERR; printf '%s\n' "${_OBS_SNAP_BODY[$i]}"); then
            print_error "Could not put ${_OBS_SNAP_PATH[$i]} back."
            rc=1
        fi
        i=$((i + 1))
    done
    _OBS_SNAP_BODY=()
    systemctl daemon-reload >/dev/null 2>&1 || true
    return "$rc"
}

# obs_rotate_token <token> -- replace the ingest token in place: write the token file,
# render every Alloy file for this installation (obs_render_alloy, which also moves a
# token still in the env file out of it), then restart Alloy and watch it
# (obs_restart_alloy). Only Alloy restarts, never the node, so there is no committee
# guard or epoch wait. When a write fails, or Alloy does not stay running, the token
# file, the env file, config.alloy and the unit are put back as they were and Alloy is
# restarted on them (rollback). Pipelines follow .node-meta. rc 0 rotated; rc 1 (said)
# refused with nothing changed, or rolled back; OBS_ROTATE_MSG then says which in one
# sentence (setup-observability.sh --json reports it).
OBS_ROTATE_MSG=""
obs_rotate_token() {
    local token unitf
    OBS_ROTATE_MSG="nothing was changed (see the messages above)"
    token="$(_obs_trim_token "${1:-}")"
    if [[ -z "$token" ]]; then
        OBS_ROTATE_MSG="no ingest token was given; nothing was changed"
        print_error "No ingest token given; nothing was changed."
        return 1
    fi
    _obs_token_warn "$token"
    ENABLE_OBSERVABILITY="$(addon_meta_get ENABLE_OBSERVABILITY false)" || return 1
    ENABLE_METRICS="$(addon_meta_get ENABLE_METRICS false)" || return 1
    if [[ "$ENABLE_OBSERVABILITY" != "true" && "$ENABLE_METRICS" != "true" ]]; then
        OBS_ROTATE_MSG="log and metrics shipping are both off on this node; nothing was changed"
        print_error "Log and metrics shipping are both off on this node, so there is no token to rotate; enable logs or metrics instead. Nothing was changed."
        return 1
    fi
    unitf="${TN_ROOT_PREFIX:-}/etc/systemd/system/${OBS_ALLOY_UNIT}"
    if [[ ! -f "$unitf" ]]; then
        OBS_ROTATE_MSG="${OBS_ALLOY_UNIT} is not installed; nothing was changed"
        print_error "${OBS_ALLOY_UNIT} is not installed; enable logs or metrics first. Nothing was changed."
        return 1
    fi
    obs_alloy_account || return 1
    if ! _obs_snapshot "$(obs_token_file)" "${OBS_ETC_DIR}/telcoin-alloy.env" "${OBS_ETC_DIR}/config.alloy" "$unitf"; then
        _OBS_SNAP_BODY=()
        OBS_ROTATE_MSG="the current Alloy files could not be read; nothing was changed"
        print_error "Could not read the current Alloy files; nothing was changed."
        return 1
    fi
    print_step "Rotating the ingest token"
    if ! obs_write_token_file "$token" || ! obs_render_alloy; then
        OBS_ROTATE_MSG="the new token could not be written; the previous files were put back and Alloy was not restarted"
        print_error "The new token could not be put in place; putting the previous files back (Alloy was not restarted)."
        _obs_restore || OBS_ROTATE_MSG="the new token could not be written, and a previous file could not be put back (see the server log)"
        return 1
    fi
    if obs_restart_alloy; then
        _OBS_SNAP_BODY=()
        OBS_ROTATE_MSG=""
        print_ok "Ingest token rotated: ${OBS_ALLOY_UNIT} restarted on the new token and stayed running. The node was not restarted."
        return 0
    fi
    print_error "${OBS_ALLOY_UNIT} did not stay running on the new token; putting the previous token and files back."
    _obs_restore || true
    if obs_restart_alloy; then
        OBS_ROTATE_MSG="${OBS_ALLOY_UNIT} did not stay running on the new token; the previous token was put back and Alloy runs on it again"
        print_warn "Rolled back: ${OBS_ALLOY_UNIT} runs on the previous token again. Check journalctl -u ${OBS_ALLOY_UNIT} -n 50, then rotate again."
    else
        OBS_ROTATE_MSG="${OBS_ALLOY_UNIT} did not stay running on the new token, and does not stay running on the previous token either; check journalctl -u ${OBS_ALLOY_UNIT}"
        print_error "Rolled back the files, but ${OBS_ALLOY_UNIT} does not stay running on the previous token either. Check: journalctl -u ${OBS_ALLOY_UNIT} -n 50"
    fi
    return 1
}

# obs_disable -- FULL teardown: stop + disable the shipper, record BOTH pipelines off,
# shred the ingest token file (and an env file that still holds the token).
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
    # The ingest token goes with the shipper (and an env file that still holds it).
    if [[ -n "$(_obs_env_token)" ]]; then
        _tn_shred "${OBS_ETC_DIR}/telcoin-alloy.env"
    fi
    _tn_shred "$(obs_token_file)"
    print_ok "Telemetry shipper stopped + disabled (${OBS_ALLOY_UNIT})."
    print_info "The ingest token file was shredded; enabling logs or metrics again asks for the token."
    print_info "The node keeps writing JSON logs / serving --metrics locally (harmless). remove-node.sh removes all obs files."
    return 0
}

# obs_disable_logs — turn OFF log shipping but KEEP metrics if it is on: render
# config.alloy metrics-only exactly as obs_enable renders it, with the env file and the
# unit (obs_render_alloy: same owner, group and paths), record ENABLE_OBSERVABILITY=false in .node-meta, then
# restart Alloy and watch it (obs_restart_alloy). The choice is recorded before the
# restart because the next render reads it back. rc 1 (said) when the render fails
# (nothing recorded, no restart), when .node-meta cannot be written, or when Alloy does
# not stay running. If metrics is also off, fall through to the full teardown. The node
# keeps writing JSON logs locally (harmless).
obs_disable_logs() {
    local meta metrics_on rc=0 where="config.alloy"
    meta="$(node_meta_path || true)"
    metrics_on="$(addon_meta_get ENABLE_METRICS false)" || return 1
    if [[ "$metrics_on" == "true" ]]; then
        print_step "Disabling log shipping (metrics stays on)"
        ENABLE_OBSERVABILITY=false; ENABLE_METRICS=true
        obs_render_alloy || return 1
        if [[ -n "$meta" ]]; then
            if meta_set ENABLE_OBSERVABILITY false "$meta"; then
                where="config.alloy and .node-meta"
            else
                print_error "Could not record ENABLE_OBSERVABILITY=false in .node-meta."
                rc=1
            fi
        fi
        if ! obs_restart_alloy; then
            rc=1
            print_error "Log shipping is off in ${where}; metrics shipping resumes once ${OBS_ALLOY_UNIT} runs (fix it, then run this disable again or restart the unit)."
        fi
        if [[ "$rc" -eq 0 ]]; then
            print_ok "Log shipping stopped; metrics still shipping → $(obs_effective_metrics_url)."
            print_info "The node keeps writing JSON logs locally (harmless)."
        fi
        return "$rc"
    fi
    obs_disable
}

# obs_disable_metrics — turn OFF metrics shipping but KEEP logs if it is on: render
# config.alloy logs-only exactly as obs_enable renders it, with the env file and the
# unit (obs_render_alloy: same owner, group and node log path), record ENABLE_METRICS=false in .node-meta, then
# restart Alloy and watch it (obs_restart_alloy). The choice is recorded before the
# restart because the next render reads it back. rc 1 (said) when the render fails
# (nothing recorded, no restart), when .node-meta cannot be written, or when Alloy does
# not stay running. If logs is also off, fall through to the full teardown. The node
# keeps serving its loopback --metrics endpoint (harmless; unscraped).
obs_disable_metrics() {
    local meta logs_on rc=0 where="config.alloy"
    meta="$(node_meta_path || true)"
    logs_on="$(addon_meta_get ENABLE_OBSERVABILITY false)" || return 1
    if [[ "$logs_on" == "true" ]]; then
        print_step "Disabling metrics shipping (logs stays on)"
        ENABLE_OBSERVABILITY=true; ENABLE_METRICS=false
        obs_render_alloy || return 1
        if [[ -n "$meta" ]]; then
            if meta_set ENABLE_METRICS false "$meta"; then
                where="config.alloy and .node-meta"
            else
                print_error "Could not record ENABLE_METRICS=false in .node-meta."
                rc=1
            fi
        fi
        if ! obs_restart_alloy; then
            rc=1
            print_error "Metrics shipping is off in ${where}; log shipping resumes once ${OBS_ALLOY_UNIT} runs (fix it, then run this disable again or restart the unit)."
        fi
        if [[ "$rc" -eq 0 ]]; then
            print_ok "Metrics shipping stopped; logs still shipping → $(obs_effective_push_url)."
            print_info "The node keeps serving its loopback --metrics endpoint (harmless; nothing scrapes it now)."
        fi
        return "$rc"
    fi
    obs_disable
}

# _obs_token_status -- one status line about the ingest token file: present with the
# expected owner and mode, wrong owner or mode, still in the env file, or missing; not
# checked when this account cannot enter ${OBS_ETC_DIR} (check-node.sh without sudo).
# Never prints the token.
_obs_token_status() {
    local f st envf="${OBS_ETC_DIR}/telcoin-alloy.env"
    f="$(obs_token_file)"
    if [[ -d "$OBS_ETC_DIR" && ! -x "$OBS_ETC_DIR" ]]; then
        print_info "Ingest token file not checked: ${OBS_ETC_DIR} is closed to this account (run this with sudo)."
        return 0
    fi
    if [[ -f "$f" && ! -L "$f" ]]; then
        st="$(stat -c '%a %U:%G' -- "$f" 2>/dev/null)" || st="unreadable"
        if [[ "$st" == "640 root:${OBS_ALLOY_USER}" ]]; then
            print_ok "Ingest token file present (0640 root:${OBS_ALLOY_USER}): ${f}"
        else
            print_warn "Ingest token file ${f} is ${st}, not 0640 root:${OBS_ALLOY_USER}; run setup-observability.sh --rotate-token to write it again."
        fi
    elif [[ -n "$(_obs_env_token)" ]]; then
        print_warn "The ingest token is still in ${envf}; run setup-observability.sh --rotate-token (the same token is fine) to move it into ${f}."
    else
        print_warn "No ingest token file at ${f}, so Alloy cannot authenticate to the hub; run setup-observability.sh --rotate-token."
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
    logs_enabled="$(addon_meta_get ENABLE_OBSERVABILITY false)" || return 1
    metrics_enabled="$(addon_meta_get ENABLE_METRICS false)" || return 1
    method="$(addon_meta_get INSTALL_METHOD binary)" || return 1
    print_info "Configured: ENABLE_OBSERVABILITY=${logs_enabled:-false} (logs), ENABLE_METRICS=${metrics_enabled:-false} (metrics)"

    # Captured first and read from a here-string: `cmd | grep -q` under pipefail fails when
    # grep stops early and the writer gets SIGPIPE, and set -e would end the status there.
    local units
    units="$(systemctl list-unit-files 2>/dev/null || true)"
    if ! grep -q "^${OBS_ALLOY_UNIT}" <<< "$units"; then
        print_info "${OBS_ALLOY_UNIT} not installed (run setup-observability.sh to enable)."
        return 0
    fi
    if systemctl is-active --quiet "$OBS_ALLOY_UNIT"; then
        print_ok "${OBS_ALLOY_UNIT} is active"
    else
        print_warn "${OBS_ALLOY_UNIT} is installed but NOT active (journalctl -u ${OBS_ALLOY_UNIT})"
    fi
    _obs_token_status

    # Pull Alloy's own /metrics once; read both pipelines' progress out of it.
    local alloy_metrics
    alloy_metrics="$(curl -fsS "${OBS_HTTP_ADDR}/metrics" 2>/dev/null || true)"

    if [[ "$logs_enabled" == "true" ]]; then
        local sent
        sent="$(printf '%s\n' "$alloy_metrics" | awk '/^loki_write_sent_bytes_total/ { s += $2 } END { printf "%d", s + 0 }')"
        if [[ -n "$sent" && "$sent" != "0" ]]; then
            print_ok "Alloy has shipped ${sent} log bytes to Loki (loki_write_sent_bytes_total)"
        else
            print_warn "Alloy up but 0 log bytes shipped yet (node starting, or no logs to tail yet)"
        fi
    fi

    if [[ "$metrics_enabled" == "true" ]]; then
        local samples maddr node_metrics
        samples="$(printf '%s\n' "$alloy_metrics" | awk '/^prometheus_remote_storage_samples_total/ { s += $2 } END { printf "%d", s + 0 }')"
        if [[ -n "$samples" && "$samples" != "0" ]]; then
            print_ok "Alloy has remote-written ${samples} metric samples (prometheus_remote_storage_samples_total)"
        else
            print_warn "Alloy up but 0 metric samples shipped yet (node starting, or --metrics not serving yet)"
        fi
        if maddr="$(obs_metrics_addr)"; then
            node_metrics="$(curl -fsS "http://${maddr}/metrics" 2>/dev/null || true)"
            if grep -qE '^(tn_|reth_)' <<< "$node_metrics"; then
                print_ok "Node metrics endpoint serving tn_*/reth_* series on ${maddr}"
            else
                print_warn "Node metrics endpoint ${maddr} not serving yet (node down, or --metrics not enabled/restarted)"
            fi
        else
            print_warn "$(_obs_bad_port_msg)"
        fi
    fi

    if [[ "$logs_enabled" == "true" ]]; then
        local logdir logf
        if [[ "$method" == "docker" ]]; then
            logdir="$(_obs_data_dir "$meta")/logs/telcoin-network-logs"
        else
            logdir="$(obs_node_log_dir)/telcoin-network-logs"
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
