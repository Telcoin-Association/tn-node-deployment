#!/usr/bin/env bash
# =============================================================================
# setup-node.sh -- Telcoin Network Node Setup
#
# Sets up a single, unified Telcoin Network node. Every node is provisioned
# validator-capable; the protocol decides a node's role on-chain from committee
# membership at each epoch. Anyone can run a full node; validating is optional
# (Telcoin Association approval + stake + on-chain activation). setup-observer.sh
# and setup-validator.sh are kept as deprecated shims that forward here.
#
# USAGE:
#   sudo bash setup-node.sh [public RPC options] [node flags]
#
# PUBLIC RPC (optional): serve https://<domain>/ + wss://<domain>/ through Caddy and
# advertise both in node-info.yaml (worker.rpc), from the first install. reth stays on
# 127.0.0.1; Caddy (install-caddy.sh, in this repo) is the only public edge.
#   --rpc-domain <hostname>  Public RPC on this DNS name (implies public). Use the node's
#                            own public name, e.g. node7.adiri.telcoin.network; the
#                            dashboard, if enabled later, needs a different one
#                            (dashboard.<your-node-domain>). Point its A record at this
#                            server's INBOUND public IP, with TCP 80 + 443 open.
#   --public-ip <ip>         Inbound public IP the A record points at (NAT / multi-IP
#                            hosts); passed through to install-caddy.sh. In --json mode it
#                            is also the P2P public IP, as before. A value that is not an
#                            IPv4 or IPv6 address is ignored, with a warning.
#   --rpc-public [true]      Public RPC; needs --rpc-domain -- without one, RPC stays private
#                            and a warning prints the command to enable it later (no error:
#                            Node Manager UI releases before 1.9.0 send `--rpc-public
#                            true|false` and never a domain; 1.9.0 sends --rpc-domain when
#                            the operator picks Public, and never --rpc-public).
#                            `--rpc-public false` changes nothing.
#   --no-public-rpc          Private RPC (127.0.0.1 only), without the prompt.
# With none of these, interactive setup asks (Enter = private) and --json stays private.
# If DNS is not ready (or the enable fails), setup still completes, records the domain in
# .node-meta (PUBLIC_RPC_DOMAIN) and prints the install-caddy.sh command to finish later.
#
# RPC URLS (optional; --rpc-domain implies all four, so most installs pass none of them):
#   --rpc-http <url>         Worker HTTP RPC URL written to node-info.yaml at keygen
#                            (keytool --rpc-http) and published to the network.
#   --rpc-ws <url>           Worker WebSocket RPC URL for node-info.yaml (keytool --rpc-ws).
#                            Needs --rpc-http or --rpc-domain; alone it is ignored, with a
#                            warning.
#   --public-rpc-url <url>   This node's public HTTP RPC address, recorded in .node-meta
#                            (PUBLIC_RPC_URL) for the UI and tooling; never sent to the network.
#   --public-ws-url <url>    The WebSocket counterpart, recorded in .node-meta (PUBLIC_WS_URL).
# --rpc-http and --public-rpc-url take an http:// or https:// URL, --rpc-ws and --public-ws-url
# a ws:// or wss:// one. Setup stops on a malformed URL and warns when one points at a
# private address (loopback, RFC 1918, .local, .internal, ...) that wallets cannot reach.
# Precedence: an explicit --rpc-http / --rpc-ws is written to node-info.yaml as given, and an
# explicit --public-rpc-url / --public-ws-url to .node-meta as given. Any of the four left
# out is derived from --rpc-domain <d>: https://<d>/ + wss://<d>/ for node-info.yaml,
# https://<d> + wss://<d> for .node-meta. Derived URLs reach keygen only when the keytool
# knows --rpc-http (otherwise a warning says they follow at enable time). Enabling public
# RPC after the node starts (install-caddy.sh --phase=rpc-enable) advertises the same
# https://<d>/ + wss://<d>/ and does not restart the node when node-info.yaml already
# holds them; an explicit URL that differs is replaced then (a warning says so up front).
#
# NODE FLAGS (optional). Setup asks the installed release whether it knows each flag
# given, and stops when it does not.
#   --bootstrap-peers <file> The peers the node dials at start, replacing the genesis
#                            bootstrap servers (v0.15.0-adiri and later). The file holds
#                            a YAML or JSON map keyed by BLS public key; each entry is a
#                            node's primary and workers, as under p2p_info in its
#                            node-info.yaml. At most 64 KiB, and readable by other users
#                            (chmod 644): the map does not stay private. Setup checks it
#                            with the release's own parser and installs it, world-readable,
#                            as /etc/telcoin/bootstrap-peers.yaml; the start wrapper passes
#                            --bootstrap-peers "$(cat /etc/telcoin/bootstrap-peers.yaml)",
#                            so the file is read again at every start.
#   --enable-state-export    Export each epoch's final execution state under
#                            <datadir>/consensus-db/state_exports/epoch-N/ (v0.13.0-adiri
#                            and later). Each export is a full copy of the state, and
#                            without --state-export-keep none is ever deleted.
#   --state-export-keep <n>  Keep only the newest n exports, 1 to 999999; 2 or more keeps
#                            the previous export while the next one is written. Turns on
#                            --enable-state-export as well (v0.15.0-adiri and later).
# In a --json finalize run, a flag left out is read back from what keygen recorded in
# .node-meta: BOOTSTRAP_PEERS_FILE for --bootstrap-peers, STATE_EXPORT for the two state
# export flags.
#
#   -h, --help               Print this text and exit.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
if ! version_gte "${COMMON_VERSION:-0}" "1.6.0"; then
    _tn_old="lib/common.sh ${COMMON_VERSION:-unknown} is older than 1.6.0. Run update-scripts.sh and try again."
    case " $* " in
        *" --json "*) printf '{"event":"error","msg":"%s"}\n{"event":"done","ok":false,"msg":"%s"}\n' "$_tn_old" "$_tn_old" ;;
        *) printf '[ERROR] %s\n' "$_tn_old" >&2 ;;
    esac
    exit 1
fi

readonly SCRIPT_VERSION="1.3.0"
readonly SERVICE_NAME="telcoin"
# The node's role is decided on-chain from committee membership, and the dashboard's
# validator view follows the on-chain stake status (ConsensusRegistry getValidator).
# Setup records no role: .node-meta carries no NODE_TYPE, and the "node_type":"observer"
# in the --json done events is only the Node Manager UI's presentation slot.

NETWORK=""
CHAIN_ID=""
CHAIN_NAME=""
RPC_URL=""
# Public, operator-facing endpoints this node serves through its Caddy edge.
# Recorded in .node-meta so the UI, operators and tooling can read the node's own
# externally reachable RPC/WS addresses instead of inferring them from a hostname.
PUBLIC_RPC_URL=""
PUBLIC_WS_URL=""
# Advertised worker JSON-RPC endpoint, baked into node-info.yaml at KEYGEN time and carried
# from there into committee.yaml by the genesis build. Distinct from PUBLIC_* above, which
# are operator-facing .node-meta breadcrumbs only: THESE reach the network, published through
# the kademlia node record so wallets and dapps can discover where to submit transactions.
# telcoin-network attaches RpcInfo to the WORKER node only (primary stays null), and
# --rpc-ws requires --rpc-http. With --rpc-domain <d>, any of these two and PUBLIC_* above
# left empty is derived from <d> (derive_public_rpc_urls).
ADVERTISE_RPC_HTTP=""
ADVERTISE_RPC_WS=""
RPC_ADVERTISE_DERIVED=false # true: ADVERTISE_RPC_HTTP came from --rpc-domain, not --rpc-http
EXPLORER_URL=""
INSTALL_METHOD=""
# The node binary (source and existing installs) or image (docker). --binary-path or
# --docker-image set them; keygen records the one in use in .node-meta, and a finalize
# run without the flag reads it back from there.
BINARY_PATH=""
DOCKER_IMAGE=""
# Optional node flags (NODE FLAGS in the header). init_node_extra_flags checks the values
# before check_root; prepare_node_extra_flags asks the release about each flag, installs
# the peers file and builds NODE_EXTRA_FLAGS, the text for the launch line.
BOOTSTRAP_PEERS_SRC=""      # --bootstrap-peers FILE: the peers map to install ('' = none)
STATE_EXPORT_ENABLE=false   # --enable-state-export
STATE_EXPORT_KEEP=""        # --state-export-keep N
STATE_EXPORT=""             # off | unlimited | N (keep the newest N); '' = no flag given
NODE_EXTRA_FLAGS=""
NODE_EXTRA_FLAGS_SPEC=""    # the runner spec prepare_node_extra_flags last checked
NODE_FLAG_WARNINGS=()       # notes on the node flags, printed by node_flag_warnings
DATA_DIR="$DEFAULT_DATA_DIR"
CONFIG_DIR="$DEFAULT_CONFIG_DIR"
LOG_DIR="$DEFAULT_LOG_DIR"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
VALIDATOR_ADDRESS=""
ADVERTISED_NAME=""
PUBLIC_IP=""
# Public RPC (optional): a DNS name for this node that Caddy serves as https:// + wss://
# (install-caddy.sh, in this repo) and that is advertised in node-info.yaml (worker.rpc).
# Empty = private -- reth answers on 127.0.0.1 only, the default. Set by the step_config
# prompt or --rpc-domain; persisted to .node-meta as PUBLIC_RPC_DOMAIN.
ENABLE_PUBLIC_RPC="false"
PUBLIC_RPC_DOMAIN=""
RPC_INBOUND_IP=""           # inbound public IP the A record points at (--public-ip / prompt); '' = auto
RPC_PUBLIC_REQUESTED=false  # --rpc-public [true]: public RPC, which then needs --rpc-domain
NO_PUBLIC_RPC=false         # --no-public-rpc: private RPC, no prompt
PUBLIC_RPC_STATE=""         # set by step_public_rpc: enabled | pending ('' = no domain)
PUBLIC_RPC_REASON=""        # why public RPC is still pending (repeated in the summary)
NODE_STARTED=false          # true once step_create_service starts the node in THIS run
RPC_PRIVATE_NOTE=""         # why a public-RPC flag left RPC private (no usable hostname given)
RPC_DOMAIN_GIVEN=false      # --rpc-domain was passed (even with an empty value)
RPC_INPUT_WARNINGS=()       # notes on the RPC flags, printed by public_rpc_url_warnings
PRIMARY_MULTIADDR=""
WORKER_MULTIADDR=""
PRIMARY_LISTENER_MULTIADDR=""
WORKER_LISTENER_MULTIADDR=""
P2P_PORT="$DEFAULT_P2P_PORT"
WORKER_PORT="$DEFAULT_WORKER_PORT"
RPC_PORT="$DEFAULT_RPC_PORT"
METRICS_PORT="$DEFAULT_METRICS_PORT"
USE_LOAD_CREDENTIAL=false
PASSPHRASE_METHOD="loadcredential"  # loadcredential | tpm

# Testnet opt-in add-ons (see lib/common.sh / docs/testnet-addons.md). OFF by default;
# set by prompt_testnet_addons (interactive testnet only) and persisted to .node-meta.
ENABLE_HEALTHCHECK_MONITOR="false"
ENABLE_OBSERVABILITY="false"   # log shipping (Alloy -> Loki)
ENABLE_METRICS="false"         # metrics shipping (Alloy -> Prometheus); independent of logs
ENABLE_VPN="false"          # true | pending | false
VPN_OVERLAY_IP=""
VPN_NODE_PUBKEY=""
REGION=""

# =============================================================================
# STEPS
# =============================================================================

step_welcome() {
    clear
    echo ""
    echo "${BLUE}${BOLD}  ████████╗███████╗██╗      ██████╗ ██████╗ ██╗███╗   ██╗"
    echo "     ██╔══╝██╔════╝██║     ██╔════╝██╔═══██╗██║████╗  ██║"
    echo "     ██║   █████╗  ██║     ██║     ██║   ██║██║██╔██╗ ██║"
    echo "     ██║   ██╔══╝  ██║     ██║     ██║   ██║██║██║╚██╗██║"
    echo "     ██║   ███████╗███████╗╚██████╗╚██████╔╝██║██║ ╚████║"
    echo "     ╚═╝   ╚══════╝╚══════╝ ╚═════╝ ╚═════╝ ╚═╝╚═╝  ╚═══╝"
    echo "  ███╗   ██╗███████╗████████╗██╗    ██╗ ██████╗ ██████╗ ██╗  ██╗"
    echo "  ████╗  ██║██╔════╝╚══██╔══╝██║    ██║██╔═══██╗██╔══██╗██║ ██╔╝"
    echo "  ██╔██╗ ██║█████╗     ██║   ██║ █╗ ██║██║   ██║██████╔╝█████╔╝ "
    echo "  ██║╚██╗██║██╔══╝     ██║   ██║███╗██║██║   ██║██╔══██╗██╔═██╗ "
    echo "  ██║ ╚████║███████╗   ██║   ╚███╔███╔╝╚██████╔╝██║  ██║██║  ██╗"
    echo "  ╚═╝  ╚═══╝╚══════╝   ╚═╝    ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝${RESET}"
    echo ""
    echo "  ${BOLD}Telcoin Network -- Node Setup  v${SCRIPT_VERSION}${RESET}"
    echo ""
    print_sep
    echo ""
    print_info "This script sets up a Telcoin Network node. Anyone can run a full"
    print_info "node -- it follows consensus and serves RPC. Validating is optional and"
    print_info "additionally requires Telcoin Association approval, a stake, and on-chain"
    print_info "activation; until then the same node simply follows consensus."
    echo ""
    print_info "Prerequisites:"
    echo "    * A dedicated server meeting the baseline hardware requirements"
    echo "    * You are running this script as root (sudo)"
    echo ""
    print_info "To validate later you must be a GSMA-approved MNO with Telcoin"
    print_info "Association governance approval -- contact support@telcoin.org and see"
    print_info "the staking guide in the docs."
    echo ""
    print_sep
    echo ""

    if ! confirm "Ready to begin node setup?"; then
        print_info "Setup cancelled."
        exit 0
    fi
}

step_preflight() {
    print_header "Step 1 of 8: Pre-flight Checks"
    check_root
    detect_distro
    check_cve_2026_31431

    # Pick where node data lives BEFORE the disk check, so the check lands on the
    # right drive (a separate data mount, not the boot disk). Interactive only;
    # JSON/UI installs pre-set DATA_DIR via --data-dir (or use the default).
    if ! json_mode; then
        print_step "Available storage (mounted filesystems, largest first)..."
        echo ""
        # Filter on the real fstype column (not a path grep), drop pseudo/boot
        # mounts and sub-GB noise, and sort by free space so the biggest data
        # drive is listed first. Any real drive (ext4/xfs/zfs at /mnt, /data, ...)
        # is shown -- only pseudo filesystems are hidden.
        df -BG --output=fstype,target,avail,size 2>/dev/null \
            | awk 'NR>1 && ($3+0) >= 1 \
                   && $1 !~ /^(tmpfs|devtmpfs|udev|squashfs|overlay|efivarfs|vfat)$/ \
                   && $2 !~ /^\/boot/ { print ($3+0), $2, ($4+0) }' \
            | sort -rn \
            | awk '{printf "    %-28s %dG available / %dG total\n", $2, $1, $3}'
        echo ""
        # df only lists MOUNTED filesystems, so a data drive that hasn't been
        # mounted yet is invisible above. Show physical disks too (incl. unmounted).
        if command -v lsblk >/dev/null 2>&1; then
            print_info "Physical disks (a disk with no MOUNTPOINT is not mounted yet):"
            lsblk -e7 -o NAME,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null | sed 's/^/    /'
            echo ""
            print_info "If your data drive shows no MOUNTPOINT, mount it (and add it to"
            print_info "/etc/fstab) before pointing the node at it."
            echo ""
        fi
        print_step "Selecting data directory..."
        print_info "Where should node data be stored? If it's on a separate drive"
        print_info "(e.g. /mnt/data) enter the full path. Press Enter for the default."
        prompt_setup_path DATA_DIR "Data directory"
        print_ok "Data directory: ${DATA_DIR}"
    fi
    mkdir -p "$DATA_DIR" 2>/dev/null || true

    check_hardware "node" "$DATA_DIR"
    # --json: put the hardware result in the setup log too. Below-minimum hardware is not
    # an error (check_hardware warns and setup goes on), so the gaps go out as a `log`
    # line starting WARNING:, which the Node Manager UI styles as a warning.
    if json_mode; then
        json_event log "hardware: ${TN_HW_SUMMARY:-unknown}"
        if [[ -n "${TN_HW_GAPS:-}" ]]; then
            json_event log "WARNING: hardware below the minimum for: ${TN_HW_GAPS} (setup continues)"
        fi
    fi
    check_internet
    # Core node ports + the ports the optional features use (Caddy dashboard 80/443,
    # WireGuard VPN 51820, health monitor 43174) so conflicts surface up front.
    check_ports \
        "${P2P_PORT}/udp:P2P primary" \
        "${WORKER_PORT}/udp:P2P worker" \
        "${RPC_PORT}/tcp:RPC" \
        "${METRICS_PORT}/tcp:Metrics (loopback, only if metrics enabled)" \
        "80/tcp:Caddy HTTP (optional dashboard)" \
        "443/tcp:Caddy HTTPS (optional dashboard)" \
        "51820/udp:WireGuard VPN (optional)" \
        "43174/tcp:Health monitor (optional)"

    for tool in curl git; do
        if command_exists "$tool"; then
            print_ok "${tool} is installed"
        else
            install_package "$tool"
        fi
    done

    # Check systemd version -- LoadCredential requires 247+ (Ubuntu 22.04+)
    print_step "Checking systemd version..."
    local systemd_ver
    systemd_ver=$(systemctl --version 2>/dev/null | head -1 | awk '{print $2}')
    if [[ -z "$systemd_ver" ]] || [[ "$systemd_ver" -lt 247 ]]; then
        setup_fail "systemd ${systemd_ver:-unknown} detected -- version 247+ required. Upgrade to Ubuntu 22.04 LTS or later and try again."
    fi
    print_ok "systemd ${systemd_ver} detected (247+ required)"
    USE_LOAD_CREDENTIAL=true

    # Select network first so NETWORK is set before source build (needed for --features adiri).
    # In JSON mode network/method/passphrase are already set from flags by the orchestrator.
    echo ""
    print_step "Selecting network..."
    json_mode || select_network

    # Testnet opt-in add-ons: ask now ("ask early") so step_create_service can bake the
    # right node-launch flags on the first pass. Side-effect installs run later in
    # step_testnet_addons ("act late"). No-op off testnet / in JSON mode.
    json_mode || prompt_testnet_addons
    # Its region label is free text bound for .node-meta. Keep the part the telemetry
    # pipelines use (letters, digits, _ and -, at most 32), as lib/observability.sh does.
    if [[ -n "$REGION" ]]; then
        local region
        region="$(printf '%s' "$REGION" | tr -cd 'A-Za-z0-9_-' | cut -c1-32)"
        if [[ "$region" != "$REGION" ]]; then
            REGION="${region:-unknown}"
            print_warn "Region label kept as ${REGION} (letters, digits, _ and - only)."
        fi
    fi

    echo ""
    print_step "Selecting install method..."
    json_mode || _select_install_method_with_guard

    case "$INSTALL_METHOD" in
        source)   _preflight_source ;;
        docker)   _preflight_docker ;;
        existing) _preflight_existing ;;
    esac

    if [[ "$INSTALL_METHOD" != "docker" ]] && ! json_mode; then
        _select_passphrase_method
    fi

    print_ok "Pre-flight checks complete"
}

_select_install_method_with_guard() {
    while true; do
        select_install_method
        case "$INSTALL_METHOD" in
            binary)
                echo ""
                print_warn "Pre-built binary downloads are coming soon."
                print_info "Official releases will be available at:"
                print_info "  https://github.com/Telcoin-Association/tn-node-deployment/releases"
                print_warn "This option is not yet available -- please choose another method."
                echo ""
                read -r -p "  Press Enter to return to the install method menu..."
                echo ""
                ;;
            *) break ;;
        esac
    done
}

_select_passphrase_method() {
    echo ""
    print_header "BLS Passphrase Protection"
    echo "  How would you like to protect the BLS passphrase?"
    echo ""
    echo "  1) systemd LoadCredential (default -- recommended for most operators)"
    echo "       Passphrase secured by systemd. Never appears in process listings."
    echo "       Works on any Ubuntu 22.04+ server. Easy to recover."
    echo ""
    echo "  2) TPM/vTPM sealing (advanced -- maximum security)"
    echo "       Passphrase sealed to this machine's TPM chip."
    echo "       Cannot be decrypted on any other machine, even with root access."
    echo "       Requires TPM2 chip (GCP Shielded VM, AWS Nitro, or bare metal TPM2)."
    echo "       Recovery requires your offline backup passphrase."
    echo ""

    local choice
    while true; do
        read -r -p "  Enter choice [1/2]: " choice
        case "$choice" in
            1)
                PASSPHRASE_METHOD="loadcredential"
                print_ok "Passphrase method: systemd LoadCredential"
                break
                ;;
            2)
                if tpm_check_available; then
                    PASSPHRASE_METHOD="tpm"
                    print_ok "Passphrase method: TPM sealing"
                    print_warn "You will need to store your passphrase securely offline."
                else
                    print_error "No TPM2 chip detected on this system."
                    print_info "TPM sealing requires /dev/tpm0 or /dev/tpmrm0."
                    print_info "Falling back to systemd LoadCredential."
                    PASSPHRASE_METHOD="loadcredential"
                fi
                break
                ;;
            *) print_warn "Please enter 1 or 2." ;;
        esac
    done
}

_preflight_source() {
    print_step "Installing source build dependencies..."

    if ! check_rust; then
        print_info "Installing Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
        export PATH="${HOME}/.cargo/bin:${PATH}"
        [[ -f "${HOME}/.cargo/env" ]] && source "${HOME}/.cargo/env" 2>/dev/null || true
        if ! check_rust; then
            setup_fail "Rust installation failed. Cannot continue."
        fi
    fi

    # Test for the file first: under set -e, bash 3.2 exits on a `source` of a missing
    # file even with `|| true` (bash 5 does not), as update-node.sh already guards.
    export PATH="${HOME}/.cargo/bin:/root/.cargo/bin:${PATH}"
    [[ -f "${HOME}/.cargo/env" ]] && source "${HOME}/.cargo/env" 2>/dev/null || true

    local build_deps=("build-essential" "cmake" "clang" "libclang-dev" "libclang-16-dev" "pkg-config" "libssl-dev" "libapr1-dev")
    local missing_deps=()
    for _dep in "${build_deps[@]}"; do
        if ! dpkg -l "$_dep" 2>/dev/null | grep -q "^ii"; then
            missing_deps+=("$_dep")
        fi
    done
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_warn "Missing build dependencies: ${missing_deps[*]}"
        if json_mode || confirm "Install missing packages now?"; then
            update_package_index
            for _dep in "${missing_deps[@]}"; do
                install_package "$_dep"
            done
        else
            setup_fail "Required build dependencies not installed. Cannot build from source."
        fi
    else
        print_ok "Build dependencies present"
    fi

    local source_dir="/opt/telcoin-source"
    if [[ -d "$source_dir/.git" ]]; then
        # Refresh a reused clone THOROUGHLY so it is never stale across
        # remove/reinstall cycles: all branches + ALL tags (incl. re-pointed
        # ones), and prune deleted refs. A bare `fetch --all` does NOT reliably
        # fetch tags -- that is how clones ended up missing newer -adiri release
        # tags (e.g. showing v0.6.0-adiri-101 instead of v0.10.0-adiri).
        print_info "Refreshing existing source clone (all branches + tags)..."
        run_streamed git -C "$source_dir" fetch --all --tags --prune --force
    else
        print_info "Cloning Telcoin Network repository..."
        run_streamed git clone --recurse-submodules "$TN_REPO" "$source_dir"
    fi

    echo ""
    print_header "Source Branch / Tag Selection"
    print_info "Per the Telcoin dev team, the general case for testnet is to build"
    print_info "from the latest -adiri tag. main works too and is the right default"
    print_info "for devnet. mainnet will have its own tag set when it launches."
    echo ""

    local build_ref
    if json_mode; then
        # Already held to the release floor in run_json_mode, before check_root.
        build_ref="$JSON_BUILD_REF"
        [[ -n "$build_ref" ]] || setup_fail "No --build-ref supplied for source build."
    else
        build_ref=$(pick_source_version "$NETWORK") || setup_fail "No source ref selected -- cannot continue setup."
        # The picker lists only supported tags, but main or a typed ref can be anything.
        check_release_floor "$build_ref"
    fi

    print_step "Checking out: ${build_ref}..."
    if ! git -C "$source_dir" checkout --force "$build_ref" 2>/dev/null; then
        if ! { git -C "$source_dir" fetch origin "$build_ref" 2>/dev/null && \
               git -C "$source_dir" checkout --force "$build_ref" 2>/dev/null; }; then
            setup_fail "Branch or tag '${build_ref}' not found in repository."
        fi
    fi
    # If build_ref is a branch (e.g. main), hard-reset to the remote tip so we
    # never build a stale local branch. No-op for tags/commits (immutable).
    if git -C "$source_dir" show-ref --verify --quiet "refs/remotes/origin/${build_ref}"; then
        git -C "$source_dir" reset --hard "origin/${build_ref}" 2>/dev/null || true
    fi
    # Sync submodules to the checked-out ref so a reused clone never builds with
    # stale submodule state.
    run_streamed git -C "$source_dir" submodule update --init --recursive --force \
        || print_warn "submodule sync reported an issue -- build may fail"
    print_ok "Checked out: ${build_ref}"

    if [[ -f "${source_dir}/rust-toolchain.toml" ]]; then
        local required_toolchain
        required_toolchain=$(grep "channel" "${source_dir}/rust-toolchain.toml" 2>/dev/null | head -1 | cut -d'"' -f2)
        if [[ -n "$required_toolchain" ]]; then
            print_info "Installing required Rust toolchain: ${required_toolchain}..."
            rustup toolchain install "$required_toolchain" 2>/dev/null || true
            print_ok "Rust toolchain ready: ${required_toolchain}"
        fi
    fi

    local cargo_features=""
    if [[ "${NETWORK:-}" == "testnet" ]]; then
        cargo_features="--features adiri"
        print_info "Building with testnet features: adiri"
    fi

    print_info "Building release binary (this takes 20-40 minutes)..."
    cd "$source_dir"
    if json_mode; then
        # Stream each build line to the UI (and keep the full log on disk) so the
        # operator sees compile progress instead of a frozen screen.
        cargo build --release $cargo_features 2>&1 | tee /tmp/tn-build.log | while IFS= read -r _line; do
            json_emit "{\"event\":\"log\",\"msg\":\"$(json_escape "$_line")\"}"
        done
    else
        cargo build --release $cargo_features 2>&1 | tee /tmp/tn-build.log
    fi

    local built="${source_dir}/target/release/telcoin-network"
    if [[ ! -f "$built" ]]; then
        setup_fail "Build failed. See /tmp/tn-build.log"
    fi

    mkdir -p "$INSTALL_DIR"
    cp "$built" "${INSTALL_DIR}/telcoin-network"
    chmod +x "${INSTALL_DIR}/telcoin-network"
    BINARY_PATH="${INSTALL_DIR}/telcoin-network"
    # Record the installed ref so the UI reports the running binary's version.
    write_source_version_marker "$INSTALL_DIR" "$source_dir" "$build_ref"
    print_ok "Binary installed: ${BINARY_PATH}"

    # Write build info for Node Manager UI
    mkdir -p /etc/telcoin
    {
        echo "build_ref=${build_ref}"
        echo "commit=$(git -C "$source_dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
        echo "branch=$(git -C "$source_dir" symbolic-ref --short HEAD 2>/dev/null || echo "detached")"
        echo "built_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    } > /etc/telcoin/build-info
    print_ok "Build info written: /etc/telcoin/build-info"
}

_preflight_docker() {
    print_step "Setting up Docker..."

    if ! command -v docker &>/dev/null; then
        print_info "Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        if ! command -v docker &>/dev/null; then
            setup_fail "Docker installation failed. Please install Docker manually."
        fi
        print_ok "Docker installed"
    else
        print_ok "Docker is installed"
    fi

    echo ""
    print_info "The official Telcoin Network Docker image is hosted at:"
    print_info "  ${GAR_IMAGE_BASE}"
    echo ""
    print_info "Enter the full image URL including tag (default is the latest"
    print_info "published -adiri tag, auto-detected from the registry)."
    echo ""

    # The image is written unquoted into the root-run start wrapper, so it must be a plain
    # image reference (validate_docker_image), whether typed, auto-detected or passed.
    local input
    if json_mode; then
        # The UI passes --docker-image, already checked in run_json_mode before
        # check_root; only auto-detect, and check, when it didn't.
        if [[ -z "${DOCKER_IMAGE:-}" ]]; then
            DOCKER_IMAGE="$(latest_docker_image)"
            if ! validate_docker_image "$DOCKER_IMAGE"; then
                setup_fail "The registry gave an image reference setup cannot use: ${DOCKER_IMAGE}. Pass --docker-image with the full image and tag."
            fi
            check_release_floor "$DOCKER_IMAGE"
        fi
    else
        local default_image
        default_image="$(latest_docker_image)"
        while true; do
            read -r -p "  Docker image (press Enter to accept default)
  [${default_image}]: " input
            DOCKER_IMAGE="${input:-$default_image}"
            validate_docker_image "$DOCKER_IMAGE" && break
            print_warn "Not an image reference: ${DOCKER_IMAGE}. Give the full image with its tag, such as ${DEFAULT_DOCKER_IMAGE}."
        done
        check_release_floor "$DOCKER_IMAGE"
    fi

    print_step "Pulling Docker image: ${DOCKER_IMAGE}..."
    if ! docker pull "$DOCKER_IMAGE"; then
        setup_fail "Failed to pull Docker image: ${DOCKER_IMAGE}"
    fi
    print_ok "Docker image pulled: ${DOCKER_IMAGE}"

    DOCKER_UID=1101
    print_info "Note: Docker install requires service user UID ${DOCKER_UID}"

    local existing_user
    existing_user=$(getent passwd "$DOCKER_UID" | cut -d: -f1 2>/dev/null || echo "")
    if [[ -n "$existing_user" ]] && [[ "$existing_user" != "$SERVICE_USER" ]]; then
        setup_fail "UID ${DOCKER_UID} is already in use by user '${existing_user}'"
    fi

    BINARY_PATH="docker"
}

_preflight_existing() {
    print_step "Locating existing binary..."

    local found input msg
    # --binary-path names it. Otherwise look for one, then ask (interactive only: a
    # --json run has no stdin to answer from).
    if [[ -z "${BINARY_PATH:-}" ]]; then
        found=$(command -v telcoin-network 2>/dev/null || \
                find /usr/local/bin /opt /home -name "telcoin-network" -type f 2>/dev/null | head -1 || \
                echo "")

        if [[ -n "$found" ]]; then
            print_info "Found: ${found}"
            if confirm "Use this binary?"; then
                BINARY_PATH="$found"
            fi
        fi
    fi

    if [[ -z "${BINARY_PATH:-}" ]]; then
        if json_mode; then
            setup_fail "--install-method existing needs --binary-path PATH: no telcoin-network binary was found on PATH or under /usr/local/bin, /opt or /home."
        fi
        while true; do
            read -r -p "  Full path to telcoin binary: " input
            BINARY_PATH="$input"
            msg="$(binary_path_ok)" && break
            print_warn "$msg"
        done
    fi

    check_binary_path
    if ! verify_binary "$BINARY_PATH"; then
        setup_fail "Cannot verify binary at ${BINARY_PATH}."
    fi
}

# 0 when BINARY_PATH can go into the start wrapper: an absolute path of letters, digits
# and . _ / - (the wrapper holds it unquoted and runs as root) naming an executable file
# (the wrapper execs it from systemd, where a relative path or a missing file only shows
# up as a crash loop). Otherwise 1, with the reason on stdout.
binary_path_ok() {
    case "${BINARY_PATH:-}" in
        /*) ;;
        *) printf 'The node binary path must be absolute: %s' "${BINARY_PATH:-(empty)}"; return 1 ;;
    esac
    if ! validate_setup_path "$BINARY_PATH"; then
        printf 'The node binary path may hold only letters, digits and . _ / -, because the start wrapper runs it: %s' "$BINARY_PATH"
        return 1
    fi
    if [[ ! -f "$BINARY_PATH" || ! -x "$BINARY_PATH" ]]; then
        printf 'No executable node binary at %s.' "$BINARY_PATH"
        return 1
    fi
    return 0
}

# Stop setup unless binary_path_ok accepts BINARY_PATH.
check_binary_path() {
    local msg=""
    msg="$(binary_path_ok)" || setup_fail "$msg"
    return 0
}

step_network() {
    print_header "Step 2 of 8: Network Selection"
    select_network
}

step_config() {
    print_header "Step 3 of 8: Node Configuration"

    # JSON mode: ports and directory paths come from flags/defaults set by the
    # orchestrator (the validator's addresses + multiaddrs are handled in
    # step_generate_keys). Run the same step, non-interactively.
    if json_mode; then
        print_ok "Configuration set (non-interactive)"
        print_info "RPC access:  $([[ "$ENABLE_PUBLIC_RPC" == "true" ]] && echo "public (https://${PUBLIC_RPC_DOMAIN}/ + wss://${PUBLIC_RPC_DOMAIN}/)" || echo private)"
        print_info "Ports: P2P ${P2P_PORT} / worker ${WORKER_PORT} / RPC ${RPC_PORT} / metrics ${METRICS_PORT}"
        return 0
    fi

    # RPC access: a flag decides it up front (no prompt); otherwise ask.
    if [[ "$NO_PUBLIC_RPC" == "true" ]]; then
        print_ok "RPC access: private (--no-public-rpc)"
    elif [[ -n "$PUBLIC_RPC_DOMAIN" ]]; then
        print_ok "RPC access: public -- https://${PUBLIC_RPC_DOMAIN}/ + wss://${PUBLIC_RPC_DOMAIN}/ (--rpc-domain)"
    elif [[ -n "$RPC_PRIVATE_NOTE" ]]; then
        public_rpc_no_domain_notice
    else
        prompt_public_rpc
    fi
    public_rpc_url_warnings

    echo ""
    echo "  Port configuration (press Enter to accept defaults):"
    echo ""

    # Each answer is checked where it is read: the metrics port goes into the root-run
    # start wrapper, the RPC port into .node-meta.
    prompt_port P2P_PORT "P2P primary port"
    prompt_port WORKER_PORT "P2P worker port "
    prompt_port RPC_PORT "RPC port        "
    prompt_port METRICS_PORT "Metrics port    "

    echo ""
    print_info "Data dir:    ${DATA_DIR}"
    print_info "Config dir:  ${CONFIG_DIR}"
    print_info "Log dir:     ${LOG_DIR}"
    print_info "Install dir: ${INSTALL_DIR}"
    echo ""

    if ! confirm "Use these default paths?"; then
        prompt_setup_path CONFIG_DIR "Config directory "
        prompt_setup_path LOG_DIR "Log directory    "
        prompt_setup_path INSTALL_DIR "Install directory"
    fi

    echo ""
    print_info "Advertised node name (optional) -- a public label for this node."
    print_info "Leave blank for none; you can set or change it later in the dashboard."
    read -r -p "  Advertised node name [none]: " ADVERTISED_NAME
    ADVERTISED_NAME="$(printf '%s' "$ADVERTISED_NAME" | tr -d '[:space:]')"
    if [[ -n "$ADVERTISED_NAME" && ! "$ADVERTISED_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
        print_warn "Invalid name -- ignoring (set it later in the dashboard)."
        ADVERTISED_NAME=""
    fi

    print_ok "Configuration set"
}

# Interactive RPC-access choice (step_config). Public = a DNS name for this node that
# Caddy serves as https:// + wss:// and that is advertised in node-info.yaml, so gateways
# and wallets can discover it; reth itself stays on 127.0.0.1 either way. Sets
# ENABLE_PUBLIC_RPC / PUBLIC_RPC_DOMAIN / RPC_INBOUND_IP. The enable runs at the end of
# setup (step_public_rpc), once the node is up.
prompt_public_rpc() {
    echo "  RPC access:"
    echo ""
    echo "  1) Private (default) -- RPC reachable from this server only (127.0.0.1)."
    echo "              No DNS or firewall changes needed. Best for personal use,"
    echo "              development, and internal tooling."
    echo ""
    echo "  2) Public            -- https://<domain>/ and wss://<domain>/ served by"
    echo "              Caddy (automatic TLS) and advertised to the network in"
    echo "              node-info.yaml. reth itself stays on 127.0.0.1."
    echo ""
    local rpc_choice input
    while true; do
        read -r -p "  Enter choice [1]: " rpc_choice
        rpc_choice="${rpc_choice:-1}"
        case "$rpc_choice" in
            1|2) break ;;
            *) print_warn "Please enter 1 or 2." ;;
        esac
    done
    if [[ "$rpc_choice" != "2" ]]; then
        ENABLE_PUBLIC_RPC="false"
        return 0
    fi

    echo ""
    print_info "Public RPC needs a DNS name for THIS node. Use the node's own public name"
    print_info "for the RPC endpoint, e.g. node7.adiri.telcoin.network."
    print_info "The Node Manager dashboard, if you enable it later, needs a DIFFERENT hostname:"
    print_info "dashboard.<your-node-domain> (e.g. dashboard.node7.adiri.telcoin.network) --"
    print_info "one name cannot serve both."
    print_info "Before setup finishes, point the name's DNS A record at this server's INBOUND"
    print_info "public IP and allow inbound TCP 80 + 443 (Caddy gets its TLS certificate over"
    print_info "them). If DNS is not ready in time, setup still completes and prints the one"
    print_info "command that enables public RPC later. Leave blank to stay private."
    echo ""
    while true; do
        read -r -p "  Public RPC domain [none = private]: " input
        input="$(normalize_rpc_domain "$input")"
        if [[ -z "$input" ]]; then
            print_info "No domain entered -- RPC stays private."
            ENABLE_PUBLIC_RPC="false"
            PUBLIC_RPC_DOMAIN=""
            return 0
        fi
        validate_rpc_domain "$input" && break
        print_warn "Not a bare hostname: ${input}. Enter just the name, e.g. node7.adiri.telcoin.network (no https://, no path, no IP address)."
    done
    PUBLIC_RPC_DOMAIN="$input"
    ENABLE_PUBLIC_RPC="true"

    echo ""
    print_info "Inbound public IP the A record points at. Only needed behind NAT or on a"
    print_info "multi-IP server, where it can differ from the auto-detected (egress) IP."
    while true; do
        read -r -p "  Inbound public IP [${RPC_INBOUND_IP:-auto-detect}]: " input
        input="$(printf '%s' "$input" | tr -d '[:space:]')"
        if [[ -z "$input" ]]; then
            break
        elif validate_public_ip "$input"; then
            RPC_INBOUND_IP="$input"
            break
        fi
        print_warn "Not a valid IPv4/IPv6 address -- try again, or press Enter to auto-detect."
    done
    print_ok "RPC access: public -- https://${PUBLIC_RPC_DOMAIN}/ + wss://${PUBLIC_RPC_DOMAIN}/"
    derive_public_rpc_urls
}

# Canonical form of an RPC domain: whitespace removed, lowercased, one trailing dot (FQDN
# form) dropped. tr, not ${var,,}, to stay bash 3.2 safe.
normalize_rpc_domain() {
    local d
    d="$(printf '%s' "${1:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    printf '%s' "${d%.}"
}

# 0 when <hostname> is a bare DNS name Caddy can get a certificate for: two or more
# dot-separated labels of [A-Za-z0-9-] (no leading/trailing hyphen, at most 63 chars
# each), at most 253 chars in all, no scheme, port or path, and not an IPv4 address.
# The label regex is install-caddy.sh's caddy_validate_domain, so a name accepted here
# is accepted there.
validate_rpc_domain() {
    local d="${1:-}"
    [[ -n "$d" && "${#d}" -le 253 ]] || return 1
    if [[ "$d" =~ ^[0-9.]+$ ]]; then
        return 1
    fi
    if [[ "$d" =~ [^.]{64} ]]; then     # a DNS label is at most 63 characters
        return 1
    fi
    [[ "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]
}

# Validate the public-RPC flags once, before any step touches the box, and derive
# ENABLE_PUBLIC_RPC. A bad combination or a malformed URL stops setup (setup_fail). A
# public-RPC flag without a usable hostname is not an error: RPC stays private and
# public_rpc_no_domain_notice says how to enable it later (--json: here; interactive: in
# step_config, after the welcome screen clears). A URL on a private address and an invalid
# --public-ip (dropped from both PUBLIC_IP and the Caddy pass-through) only warn, through
# public_rpc_url_warnings, at the same point.
init_public_rpc_flags() {
    local err="" flag url kind
    if [[ "$NO_PUBLIC_RPC" == "true" ]]; then
        if [[ -n "$PUBLIC_RPC_DOMAIN" || "$RPC_PUBLIC_REQUESTED" == "true" ]]; then
            err="--no-public-rpc conflicts with --rpc-domain / --rpc-public -- pick one."
        fi
    elif [[ -n "$PUBLIC_RPC_DOMAIN" ]] && ! validate_rpc_domain "$PUBLIC_RPC_DOMAIN"; then
        err="invalid --rpc-domain ${PUBLIC_RPC_DOMAIN} -- give a bare hostname such as node7.adiri.telcoin.network (no https://, no path, no IP address)."
    elif [[ "$RPC_DOMAIN_GIVEN" == "true" && -z "$PUBLIC_RPC_DOMAIN" ]]; then
        RPC_PRIVATE_NOTE="no public RPC domain given (--rpc-domain was empty)"
    elif [[ "$RPC_PUBLIC_REQUESTED" == "true" && -z "$PUBLIC_RPC_DOMAIN" ]]; then
        RPC_PRIVATE_NOTE="no public RPC domain given (--rpc-public without --rpc-domain <hostname>)"
    fi
    if [[ -n "$err" ]]; then
        setup_fail "$err"
    fi
    # The four URL flags as given. derive_public_rpc_urls fills only the empty ones, from a
    # domain validate_rpc_domain accepted, so it needs no second check.
    for flag in --rpc-http --rpc-ws --public-rpc-url --public-ws-url; do
        case "$flag" in
            --rpc-http)       url="$ADVERTISE_RPC_HTTP"; kind=http ;;
            --rpc-ws)         url="$ADVERTISE_RPC_WS"; kind=ws ;;
            --public-rpc-url) url="$PUBLIC_RPC_URL"; kind=http ;;
            *)                url="$PUBLIC_WS_URL"; kind=ws ;;
        esac
        [[ -n "$url" ]] || continue
        if ! validate_rpc_url "$url" "$kind"; then
            setup_fail "invalid ${flag} ${url} -- give a ${kind}:// or ${kind}s:// URL with a host name or IP address, such as ${kind}s://node7.adiri.telcoin.network/ (no spaces, quotes or user@ part)."
        fi
        if rpc_url_is_private "$url"; then
            RPC_INPUT_WARNINGS+=("${flag} ${url} is on a private address or name: wallets on the internet cannot reach it.")
        fi
    done
    if [[ -n "$RPC_INBOUND_IP" ]] && ! validate_public_ip "$RPC_INBOUND_IP"; then
        RPC_INPUT_WARNINGS+=("--public-ip ${RPC_INBOUND_IP} is not an IPv4 or IPv6 address; ignoring it.")
        RPC_INBOUND_IP=""
        PUBLIC_IP=""
    fi
    if [[ -n "$RPC_PRIVATE_NOTE" ]] && json_mode; then
        public_rpc_no_domain_notice
    fi
    if [[ -n "$PUBLIC_RPC_DOMAIN" ]]; then
        ENABLE_PUBLIC_RPC="true"
    fi
    derive_public_rpc_urls
    # --json: the flags are final here. Interactive: step_config warns, once the welcome
    # screen has cleared and the prompt may have supplied a domain.
    if json_mode; then
        public_rpc_url_warnings
    fi
    return 0
}

# --binary-path names the binary of an existing install, and in --json mode implies
# --install-method existing. It must be absolute: the start wrapper runs it from
# systemd. Source and docker installs bring their own binary, so there it is ignored,
# with a warning. Whether the file runs is checked after check_root.
init_install_flags() {
    [[ -n "$BINARY_PATH" ]] || return 0
    if [[ -z "$INSTALL_METHOD" ]] && json_mode; then
        INSTALL_METHOD="existing"
    fi
    case "$INSTALL_METHOD" in
        ""|existing) ;;
        *)
            setup_warn "--binary-path is used only with --install-method existing; ignoring it."
            BINARY_PATH=""
            return 0
            ;;
    esac
    case "$BINARY_PATH" in
        /*) ;;
        *) setup_fail "--binary-path must be an absolute path: ${BINARY_PATH}" ;;
    esac
    return 0
}

# Check the node flags before anything touches the box: --bootstrap-peers must name a
# readable regular file of at most 64 KiB, --state-export-keep a whole number from 1 to
# 999999. --state-export-keep turns state export on, and a warning says so. Whether the
# release knows each flag, and whether it accepts the peers map, is asked later by
# prepare_node_extra_flags, once the binary or image is known. Warnings wait in
# NODE_FLAG_WARNINGS: --json prints them here, interactive setup after the welcome screen.
init_node_extra_flags() {
    local msg=""
    if [[ -n "$BOOTSTRAP_PEERS_SRC" ]]; then
        msg="$(peers_file_ok "$BOOTSTRAP_PEERS_SRC")" || setup_fail "--bootstrap-peers: ${msg}."
    fi
    if [[ -n "$STATE_EXPORT_KEEP" ]]; then
        if [[ ! "$STATE_EXPORT_KEEP" =~ ^[1-9][0-9]{0,5}$ ]]; then
            setup_fail "--state-export-keep needs a whole number from 1 to 999999, not ${STATE_EXPORT_KEEP}."
        fi
        if [[ "$STATE_EXPORT_ENABLE" != "true" ]]; then
            NODE_FLAG_WARNINGS+=("--state-export-keep ${STATE_EXPORT_KEEP} turns state export on: the node also gets --enable-state-export.")
        fi
        STATE_EXPORT="$STATE_EXPORT_KEEP"
    elif [[ "$STATE_EXPORT_ENABLE" == "true" ]]; then
        STATE_EXPORT="unlimited"
        NODE_FLAG_WARNINGS+=("--enable-state-export without --state-export-keep keeps every export, each a full copy of the execution state, until the data volume fills. Add --state-export-keep N to keep only the newest N.")
    fi
    if json_mode; then
        node_flag_warnings
    fi
    return 0
}

# Print the notes init_node_extra_flags collected, once.
node_flag_warnings() {
    local note
    for note in ${NODE_FLAG_WARNINGS[@]+"${NODE_FLAG_WARNINGS[@]}"}; do
        setup_warn "$note"
    done
    NODE_FLAG_WARNINGS=()
    return 0
}

# 0 when FILE can hold a peers map: a readable regular file of at most 64 KiB that its
# group and other users can read too. The map reaches the node as one command-line
# argument, and Linux allows 128 KiB for one. The read bits matter because the map does
# not stay private anyway: the installed copy is 0644, and the parse check passes the map
# on the command line of the node binary, where other local users can see it. Otherwise
# 1, with the reason on stdout.
peers_file_ok() {
    local f="$1" size="" mode=""
    if [[ ! -e "$f" ]]; then
        printf '%s does not exist' "$f"
        return 1
    fi
    if [[ ! -f "$f" ]]; then
        printf '%s is not a regular file' "$f"
        return 1
    fi
    if [[ ! -r "$f" ]]; then
        printf '%s is not readable' "$f"
        return 1
    fi
    # GNU stat, then BSD stat (macOS).
    mode="$(stat -L -c '%a' "$f" 2>/dev/null || true)"
    if [[ ! "$mode" =~ ^[0-7]+$ ]]; then
        mode="$(stat -L -f '%Lp' "$f" 2>/dev/null || true)"
    fi
    if [[ ! "$mode" =~ ^[0-7]+$ ]]; then
        printf 'could not read the permissions of %s' "$f"
        return 1
    fi
    if (( (8#$mode & 8#044) != 8#044 )); then
        printf '%s is mode %s: other users cannot read it. Setup accepts only a peers file that others can already read, because the installed copy is world-readable (0644) and the check passes the map on the command line of the node binary, where other users can see it. Run chmod 644 %s first' "$f" "$mode" "$f"
        return 1
    fi
    size="$(wc -c < "$f" 2>/dev/null)" || size=""
    size="${size//[[:space:]]/}"
    if [[ ! "$size" =~ ^[0-9]+$ ]]; then
        printf 'could not read the size of %s' "$f"
        return 1
    fi
    if [[ "$size" -gt 65536 ]]; then
        printf '%s is %s bytes; a peers map may have at most 65536 (64 KiB)' "$f" "$size"
        return 1
    fi
    return 0
}

# A --json finalize is a new process, so the node flags it is not given come from what
# keygen recorded in .node-meta: BOOTSTRAP_PEERS_FILE names the installed peers map (empty
# or absent: none) and STATE_EXPORT is off, unlimited or N (absent: off). A recorded value
# that no longer holds stops the run before anything is written.
finalize_node_extra_flags() {
    local meta="${CONFIG_DIR}/.node-meta" v msg=""
    if [[ -z "$BOOTSTRAP_PEERS_SRC" ]]; then
        v="$(meta_get BOOTSTRAP_PEERS_FILE "$meta" 2>/dev/null || true)"
        if [[ -n "$v" ]]; then
            msg="$(peers_file_ok "$v")" || setup_fail "BOOTSTRAP_PEERS_FILE in ${meta}: ${msg}. Put the file back, or pass --bootstrap-peers FILE."
            BOOTSTRAP_PEERS_SRC="$v"
        fi
    fi
    if [[ -z "$STATE_EXPORT" ]]; then
        v="$(meta_get STATE_EXPORT "$meta" 2>/dev/null || true)"
        case "$v" in
            ""|off|unlimited) ;;
            *)
                if [[ ! "$v" =~ ^[1-9][0-9]{0,5}$ ]]; then
                    setup_fail "STATE_EXPORT=${v} in ${meta} is not off, unlimited or a number from 1 to 999999."
                fi
                ;;
        esac
        STATE_EXPORT="${v:-off}"
    fi
    return 0
}

# --rpc-domain <d> is the same information as --rpc-http https://<d>/ --rpc-ws wss://<d>/
# --public-rpc-url https://<d> --public-ws-url wss://<d>, so fill whichever of those is
# still EMPTY from PUBLIC_RPC_DOMAIN: an explicit flag always wins. The advertised pair
# (node-info.yaml, keygen) keeps the trailing slash that install-caddy.sh rpc-enable writes;
# the .node-meta pair has none, as the fleet records it. RPC_ADVERTISE_DERIVED marks an
# --rpc-http supplied here, which step_generate_keys checks the keytool supports before
# passing it. No domain: nothing changes. Safe to call more than once.
derive_public_rpc_urls() {
    local d="$PUBLIC_RPC_DOMAIN"
    [[ -n "$d" ]] || return 0
    if [[ -z "$ADVERTISE_RPC_HTTP" ]]; then
        ADVERTISE_RPC_HTTP="https://${d}/"
        RPC_ADVERTISE_DERIVED=true
    fi
    [[ -n "$ADVERTISE_RPC_WS" ]] || ADVERTISE_RPC_WS="wss://${d}/"
    [[ -n "$PUBLIC_RPC_URL" ]] || PUBLIC_RPC_URL="https://${d}"
    [[ -n "$PUBLIC_WS_URL" ]] || PUBLIC_WS_URL="wss://${d}"
    return 0
}

# Stop setup with MSG: an [ERROR] line on stderr, plus (--json) an error event and the
# run's done event, ok:false, with the same message. Once a done event has gone out,
# stdout gets nothing more. Exits 1.
setup_fail() {
    print_error "$1"
    if json_mode && [[ "$JSON_DONE_EMITTED" != "true" ]]; then
        json_event error "$1"
        json_done "{\"event\":\"done\",\"ok\":false,\"msg\":\"$(json_escape "$1")\"}"
    fi
    exit 1
}

# A warning for the operator: print_warn, plus (--json) a `log` event that starts with
# "WARNING:", which the Node Manager UI styles as a warning.
setup_warn() {
    print_warn "$1"
    if json_mode; then
        json_event log "WARNING: $1"
    fi
    return 0
}

# Hold REF, a source ref or a docker image, to the oldest release these scripts support
# on NETWORK (tn_ref_min_check). An older release tag stops setup. A ref that is not a
# release tag (main, a commit, an image digest) cannot be checked, so it only warns.
check_release_floor() {
    local msg="" rc=0
    msg="$(tn_ref_min_check "$1" "$NETWORK")" || rc=$?
    case "$rc" in
        0) ;;
        1) setup_fail "$msg" ;;
        *) setup_warn "$msg" ;;
    esac
    return 0
}

# Warn about the RPC inputs: each note init_public_rpc_flags collected (a URL on a private
# address, a dropped --public-ip), a domain only a private network resolves, and an
# advertised-RPC flag that will not end up in node-info.yaml as given. Run after
# derive_public_rpc_urls, once the domain is final.
public_rpc_url_warnings() {
    local d="$PUBLIC_RPC_DOMAIN" given="" note
    for note in ${RPC_INPUT_WARNINGS[@]+"${RPC_INPUT_WARNINGS[@]}"}; do
        setup_warn "$note"
    done
    if [[ -n "$d" ]] && rpc_url_is_private "https://${d}/"; then
        setup_warn "${d} is a private name (.local, .localhost or .internal): wallets on the internet cannot reach https://${d}/."
    fi
    if [[ -z "$d" ]]; then
        if [[ -n "$ADVERTISE_RPC_WS" && -z "$ADVERTISE_RPC_HTTP" ]]; then
            setup_warn "--rpc-ws ${ADVERTISE_RPC_WS} is ignored: the keytool accepts --rpc-ws only together with --rpc-http (pass --rpc-http too, or --rpc-domain)."
        fi
        return 0
    fi
    if [[ "$ADVERTISE_RPC_HTTP" != "https://${d}/" ]]; then
        given="--rpc-http ${ADVERTISE_RPC_HTTP}"
    fi
    if [[ "$ADVERTISE_RPC_WS" != "wss://${d}/" ]]; then
        given="${given:+${given} and }--rpc-ws ${ADVERTISE_RPC_WS}"
    fi
    if [[ -n "$given" ]]; then
        setup_warn "${given} differs from --rpc-domain ${d}: keygen writes it to node-info.yaml as given, but enabling public RPC (install-caddy.sh --phase=rpc-enable) replaces it with https://${d}/ + wss://${d}/ once the node starts."
    fi
    return 0
}

validate_service_name() {
    local name="$1"
    local label="$2"
    if [[ ! "$name" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,31}$ ]]; then
        print_error "${label} name '${name}' is invalid."
        print_info "Must start with a letter, contain only letters/numbers/hyphens/underscores, max 32 chars."
        return 1
    fi
    return 0
}

# 0 when PATH is an absolute path of letters, digits and . _ / - with no ".." in it. The
# data, config, log and install directories and the node binary are written unquoted into
# the start wrapper and the unit, which run as root, so nothing else may get through.
# Same rule as the Node Manager UI's data directory check.
validate_setup_path() {
    [[ "${1:-}" =~ ^/[A-Za-z0-9._/-]+$ && "${1:-}" != *..* ]]
}

# 0 when ADDR is an execution address: 0x and 40 hex digits.
validate_exec_address() {
    [[ "${1:-}" =~ ^0x[0-9a-fA-F]{40}$ ]]
}

# Ask for the port in variable VAR ("LABEL [current]: ", Enter keeps it) until the answer
# is a port, 1 to 65535.
prompt_port() {
    local var="$1" label="$2" input
    while true; do
        read -r -p "  ${label} [${!var}]: " input
        input="${input:-${!var}}"
        if validate_port "$input"; then
            printf -v "$var" '%s' "$input"
            return 0
        fi
        print_warn "Not a port: ${input}. Enter a number from 1 to 65535."
    done
}

# Ask for the directory in variable VAR the same way, until validate_setup_path accepts it.
prompt_setup_path() {
    local var="$1" label="$2" input
    while true; do
        read -r -p "  ${label} [${!var}]: " input
        input="${input:-${!var}}"
        if validate_setup_path "$input"; then
            printf -v "$var" '%s' "$input"
            return 0
        fi
        print_warn "Not a usable path: ${input}. Use an absolute path of letters, digits and . _ / - only."
    done
}

# Check the values that reach the start wrapper, the unit or .node-meta, before anything
# touches the box; the prompts check what they read the same way. The Node Manager UI
# builds these flags from its TN_SETUP_* settings and checks them first; this holds a
# hand-run --json call to the same rules. An empty multiaddr or address is left to the
# step that needs it.
init_node_inputs() {
    local pair flag var val
    if ! validate_setup_path "$DATA_DIR"; then
        setup_fail "invalid --data-dir ${DATA_DIR} -- give an absolute path of letters, digits and . _ / - only."
    fi
    for pair in --external-primary:PRIMARY_MULTIADDR --external-worker:WORKER_MULTIADDR \
                --listener-primary:PRIMARY_LISTENER_MULTIADDR --listener-worker:WORKER_LISTENER_MULTIADDR; do
        flag="${pair%%:*}"
        var="${pair#*:}"
        val="${!var}"
        if [[ -n "$val" ]] && ! validate_multiaddr "$val"; then
            setup_fail "invalid ${flag} ${val} -- expected /ip4/<address>/udp/<port>/quic-v1 or /ip6/<address>/udp/<port>/quic-v1."
        fi
    done
    if [[ -n "$VALIDATOR_ADDRESS" ]] && ! validate_exec_address "$VALIDATOR_ADDRESS"; then
        setup_fail "invalid --address ${VALIDATOR_ADDRESS} -- expected 0x followed by 40 hex digits."
    fi
    case "$PASSPHRASE_METHOD" in
        loadcredential|tpm) ;;
        *) setup_fail "unknown --passphrase-method ${PASSPHRASE_METHOD} (expected loadcredential or tpm)" ;;
    esac
    if ! validate_service_name "$SERVICE_USER" "Service user" >/dev/null 2>&1; then
        setup_fail "invalid --service-user ${SERVICE_USER} -- a letter, then up to 31 letters, digits, _ or -."
    fi
    if ! validate_service_name "$SERVICE_GROUP" "Service group" >/dev/null 2>&1; then
        setup_fail "invalid --service-group ${SERVICE_GROUP} -- a letter, then up to 31 letters, digits, _ or -."
    fi
    return 0
}

# Write KEY=VALUE pairs to ${CONFIG_DIR}/.node-meta with one meta_set per key, so the
# keys other scripts keep there survive. NODE_TYPE, the role hint older releases wrote,
# is removed: the role is decided on-chain. Stops setup when a key cannot be written.
write_node_meta() {
    local meta="${CONFIG_DIR}/.node-meta" kv
    for kv in "$@"; do
        meta_set "${kv%%=*}" "${kv#*=}" "$meta" || setup_fail "Could not write ${kv%%=*} to ${meta}."
    done
    meta_unset NODE_TYPE "$meta" || setup_fail "Could not remove NODE_TYPE from ${meta}."
    return 0
}

# Record what runs the node: DOCKER_IMAGE for a docker install, removing any BINARY_PATH
# an earlier install left; otherwise BINARY_PATH, with DOCKER_IMAGE written empty as before.
write_node_meta_runner() {
    if [[ "${INSTALL_METHOD:-}" == "docker" ]]; then
        write_node_meta "DOCKER_IMAGE=${DOCKER_IMAGE:-}"
        meta_unset BINARY_PATH "${CONFIG_DIR}/.node-meta" || setup_fail "Could not remove BINARY_PATH from ${CONFIG_DIR}/.node-meta."
    else
        write_node_meta "DOCKER_IMAGE=" "BINARY_PATH=${BINARY_PATH:-}"
    fi
    return 0
}

step_create_infrastructure() {
    print_header "Step 4 of 8: Creating System Infrastructure"

    echo "  The node runs as a dedicated system user for security."
    echo "  Press Enter to accept defaults."
    echo ""
    local input
    # JSON mode keeps the default SERVICE_USER/SERVICE_GROUP (telcoin) -- no prompts.
    while ! json_mode; do
        read -r -p "  Service user name  [${SERVICE_USER}]: " input
        local proposed_user="${input:-$SERVICE_USER}"
        if validate_service_name "$proposed_user" "Service user"; then
            if id "$proposed_user" &>/dev/null && [[ $(id -u "$proposed_user") -lt 1000 ]] || ! id "$proposed_user" &>/dev/null; then
                SERVICE_USER="$proposed_user"
                break
            else
                print_error "User '${proposed_user}' already exists as a regular user (UID $(id -u "$proposed_user"))."
                print_info "Please choose a different name or press Enter to use the default."
            fi
        fi
    done

    while ! json_mode; do
        read -r -p "  Service group name [${SERVICE_GROUP}]: " input
        local proposed_group="${input:-$SERVICE_GROUP}"
        if validate_service_name "$proposed_group" "Service group"; then
            SERVICE_GROUP="$proposed_group"
            break
        fi
    done
    echo ""

    # Remove stale groupadd/useradd lock files if present. A crashed process can
    # leave these behind (notably /etc/.pwd.lock, the lckpwdf() lock), making
    # groupadd fail with "cannot lock /etc/group; try again later". This runs
    # unconditionally before any user/group creation -- safe because setup runs
    # as root in a controlled context and no legitimate concurrent process holds
    # these locks during a node install.
    rm -f /etc/.pwd.lock /etc/group.lock /etc/gshadow.lock /etc/passwd.lock /etc/shadow.lock
    print_info "Cleared any stale user/group lock files"

    create_service_user

    # Record the service account in .node-meta NOW (not just at the end), so an
    # install interrupted after this point still leaves remove-node.sh enough to
    # clean up the user/group. The install method and the image or binary go in too:
    # a --json finalize is a new process and reads them back from here when its
    # flags leave them out. step_create_service later adds the full metadata.
    mkdir -p "$CONFIG_DIR"
    write_node_meta \
        "HOST_SERVICE_USER=${SERVICE_USER}" \
        "HOST_SERVICE_GROUP=${SERVICE_GROUP}" \
        "INSTALL_METHOD=${INSTALL_METHOD:-binary}"
    write_node_meta_runner
    print_ok "Recorded service account in ${CONFIG_DIR}/.node-meta (${SERVICE_USER}:${SERVICE_GROUP})"

    print_step "Creating reth cache directory..."
    mkdir -p "/home/${SERVICE_USER}/.cache/reth/logs/telcoin-network-logs"
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "/home/${SERVICE_USER}"
    print_ok "Reth cache directory created"

    create_directories "$INSTALL_DIR" "$DATA_DIR" "$LOG_DIR" "$CONFIG_DIR"
    verify_binary "$BINARY_PATH"
    # Node flags: asked of the release now, before any key exists, and recorded for a
    # --json finalize. After create_directories, whose chown -R of CONFIG_DIR would hand
    # the peers file to the service user.
    prepare_node_extra_flags
    ensure_chain_configs_available
    print_ok "Infrastructure ready"
}

# 0 when this release's `keytool generate validator` takes --rpc-http (older releases do
# not, and clap would reject the whole keygen over it). Asks the keytool keygen is about
# to run, the docker image or the installed binary, through tn_keytool_has, which reads
# only the option lines of the help. A probe that cannot run (rc 4) reads as "no", like
# a release without the flag: keygen then goes ahead without the advertisement instead
# of failing.
keytool_supports_rpc_args() {
    tn_keytool_has "$(node_runner_spec)" --rpc-http generate validator
}

step_generate_keys() {
    print_header "Step 5 of 8: Node Key Management"

    print_info "Your node needs a BLS key for consensus signing."
    echo ""

    if [[ -d "${DATA_DIR}/node-keys" ]]; then
        if json_mode; then
            setup_fail "node-keys already exist at ${DATA_DIR}/node-keys -- refusing to overwrite in non-interactive mode"
        fi
        print_warn "Key files already exist in ${DATA_DIR}/node-keys/"
        if ! confirm "Overwrite existing keys?"; then
            print_ok "Keeping existing keys"
            return 0
        fi
    fi

    local input bls_passphrase bls_passphrase_confirm
    if json_mode; then
        # Address + multiaddrs come from flags (init_node_inputs checked their form);
        # passphrase from TN_BLS_PASSPHRASE (env only). json_check_keygen_inputs already
        # refused a missing one before check_root; these checks stay as a safety net.
        [[ -n "$VALIDATOR_ADDRESS" ]] || setup_fail "--address is missing: keygen needs the node's execution address (0x followed by 40 hex digits)."
        for v in PRIMARY_MULTIADDR WORKER_MULTIADDR PRIMARY_LISTENER_MULTIADDR WORKER_LISTENER_MULTIADDR; do
            [[ -n "${!v}" ]] || setup_fail "missing multiaddr: ${v}"
        done
        bls_passphrase="${TN_BLS_PASSPHRASE:-}"
        [[ -n "$bls_passphrase" ]] || setup_fail "TN_BLS_PASSPHRASE not set -- cannot generate keys."
    else
        # The keytool refuses anything else, and the address goes into .node-meta.
        while true; do
            read -r -p "  Node execution address (0x...): " VALIDATOR_ADDRESS
            validate_exec_address "$VALIDATOR_ADDRESS" && break
            print_warn "Not an execution address: ${VALIDATOR_ADDRESS}. Enter 0x followed by 40 hex digits."
        done

        local public_ip
        public_ip=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null || echo "")
        if [[ -n "$public_ip" ]] && ! validate_public_ip "$public_ip"; then
            print_warn "Auto-detected public IP looks invalid: ${public_ip} -- will prompt instead."
            public_ip=""
        fi
        if [[ -z "$public_ip" ]]; then
            print_warn "Could not auto-detect public IP."
            prompt_with_validation "Enter your public/external IP address" validate_public_ip public_ip || exit 1
        else
            print_info "Detected public IP: ${public_ip}"
        fi
        # Persist for the .node-meta record (read back by the Node Manager UI).
        PUBLIC_IP="$public_ip"

        echo ""
        echo "  External addresses (advertised to peers -- use your public/external IP):"
        local default_primary="/ip4/${public_ip}/udp/${P2P_PORT}/quic-v1"
        while true; do
            read -r -p "  External primary addr [${default_primary}]: " input
            PRIMARY_MULTIADDR="${input:-$default_primary}"
            validate_multiaddr "$PRIMARY_MULTIADDR" && break
            print_warn "Invalid multiaddr. Expected /ip4/<addr>/udp/<port>/quic-v1 or /ip6/..."
        done

        local default_worker="/ip4/${public_ip}/udp/${WORKER_PORT}/quic-v1"
        while true; do
            read -r -p "  External worker addr  [${default_worker}]: " input
            WORKER_MULTIADDR="${input:-$default_worker}"
            validate_multiaddr "$WORKER_MULTIADDR" && break
            print_warn "Invalid multiaddr. Expected /ip4/<addr>/udp/<port>/quic-v1 or /ip6/..."
        done

        local internal_ip
        internal_ip=$(detect_internal_ip)
        if [[ -n "$internal_ip" ]] && ! validate_ipv4 "$internal_ip" && ! validate_ipv6 "$internal_ip"; then
            print_warn "Auto-detected internal IP looks invalid: ${internal_ip} -- will prompt instead."
            internal_ip=""
        fi
        if [[ -z "$internal_ip" ]]; then
            print_warn "Could not auto-detect internal IP."
            read -r -p "  Enter your internal/NIC IP address [0.0.0.0]: " internal_ip
            internal_ip="${internal_ip:-0.0.0.0}"
            if ! validate_ipv4 "$internal_ip" && ! validate_ipv6 "$internal_ip"; then
                setup_fail "Invalid IP: ${internal_ip}"
            fi
        else
            print_info "Detected internal IP: ${internal_ip}"
        fi

        echo ""
        echo "  Listener addresses (what the node binds to -- use your internal/NIC IP):"
        local default_listener_primary="/ip4/${internal_ip}/udp/${P2P_PORT}/quic-v1"
        while true; do
            read -r -p "  Listener primary addr [${default_listener_primary}]: " input
            PRIMARY_LISTENER_MULTIADDR="${input:-$default_listener_primary}"
            validate_multiaddr "$PRIMARY_LISTENER_MULTIADDR" && break
            print_warn "Invalid multiaddr. Expected /ip4/<addr>/udp/<port>/quic-v1 or /ip6/..."
        done

        local default_listener_worker="/ip4/${internal_ip}/udp/${WORKER_PORT}/quic-v1"
        while true; do
            read -r -p "  Listener worker addr  [${default_listener_worker}]: " input
            WORKER_LISTENER_MULTIADDR="${input:-$default_listener_worker}"
            validate_multiaddr "$WORKER_LISTENER_MULTIADDR" && break
            print_warn "Invalid multiaddr. Expected /ip4/<addr>/udp/<port>/quic-v1 or /ip6/..."
        done

        echo ""
        print_warn "Set a passphrase to encrypt your BLS validator key."
        print_warn "Store this securely -- you need it every time the node starts."
        echo ""

        while true; do
            read -r -s -p "  Enter BLS key passphrase: " bls_passphrase
            echo ""
            read -r -s -p "  Confirm BLS key passphrase: " bls_passphrase_confirm
            echo ""
            if [[ "$bls_passphrase" == "$bls_passphrase_confirm" ]]; then
                if [[ -z "$bls_passphrase" ]]; then
                    print_warn "Empty passphrase is not recommended."
                    if ! confirm "Continue with no passphrase?"; then continue; fi
                fi
                break
            fi
            print_warn "Passphrases do not match -- try again."
        done
    fi

    # Advertised-RPC args, built once for both keytool calls below and emitted ONLY when
    # set, so a caller that passes neither gets a byte-identical keytool command line to
    # before. --rpc-ws is gated behind --rpc-http because clap declares
    # `requires = "rpc_http"` and would reject --rpc-ws on its own. Explicit --rpc-http /
    # --rpc-ws pass through as given (the fleet path); URLs derived from --rpc-domain are
    # passed only when this release's keytool knows --rpc-http. Otherwise keygen goes
    # ahead without them and rpc-enable advertises them after the node starts.
    local probe_rc=0 probe_note
    if [[ "$RPC_ADVERTISE_DERIVED" == "true" && -n "$ADVERTISE_RPC_HTTP" ]]; then
        keytool_supports_rpc_args || probe_rc=$?
    fi
    if [[ "$probe_rc" -ne 0 ]]; then
        probe_note="This telcoin release's keytool cannot advertise RPC at keygen (it has no --rpc-http)"
        if [[ "$probe_rc" -eq 4 ]]; then
            probe_note="Could not ask the keytool whether it can advertise RPC at keygen (its --help did not run)"
        fi
        setup_warn "${probe_note}, so ${ADVERTISE_RPC_HTTP} + ${ADVERTISE_RPC_WS} reach node-info.yaml when public RPC is enabled after the node starts (install-caddy.sh --phase=rpc-enable)."
        ADVERTISE_RPC_HTTP=""
        ADVERTISE_RPC_WS=""
        RPC_ADVERTISE_DERIVED=false
    fi
    local rpc_args=()
    if [[ -n "$ADVERTISE_RPC_HTTP" ]]; then
        rpc_args+=(--rpc-http "$ADVERTISE_RPC_HTTP")
        if [[ -n "$ADVERTISE_RPC_WS" ]]; then
            rpc_args+=(--rpc-ws "$ADVERTISE_RPC_WS")
        fi
    fi

    print_step "Generating validator keys..."
    # Exported for BOTH branches below: the binary keytool reads it directly,
    # and the docker branch pass-throughs it with `-e TN_BLS_PASSPHRASE` (NAME
    # only, value taken from this environment -- same convention as the runtime
    # wrapper). Never put the value in the docker argv: the full command line
    # is world-readable in /proc/<pid>/cmdline for the life of the keygen.
    export TN_BLS_PASSPHRASE="$bls_passphrase"

    if [[ "${INSTALL_METHOD:-}" == "docker" ]]; then
        # Run keygen as the host service account that OWNS DATA_DIR (bind-mounted as the
        # container HOME /home/nonroot) -- NOT the image's default nonroot UID -- so reth
        # can write the generated keys. Mirrors the runtime ExecStart's --user. A numeric
        # --user has no passwd entry in the image, so $HOME would fall back to "/" and
        # reth's default log dir ($HOME/.cache/reth/logs) would be unwritable; pin
        # HOME=/home/nonroot (the writable bind-mounted datadir) so reth logs land there.
        local docker_uid docker_gid
        docker_uid=$(id -u "$SERVICE_USER" 2>/dev/null || echo "1101")
        docker_gid=$(id -g "$SERVICE_GROUP" 2>/dev/null || echo "1101")
        if docker run --rm \
            --user "${docker_uid}:${docker_gid}" \
            -e HOME=/home/nonroot \
            -e TN_BLS_PASSPHRASE \
            -v "${DATA_DIR}:/home/nonroot" \
            "$DOCKER_IMAGE" \
            telcoin keytool generate validator \
            --datadir /home/nonroot \
            --address "$VALIDATOR_ADDRESS" \
            --external-primary-addr "$PRIMARY_MULTIADDR" \
            --external-worker-addrs "$WORKER_MULTIADDR" \
            ${rpc_args[@]+"${rpc_args[@]}"}; then
            print_ok "Node keys generated in: ${DATA_DIR}/node-keys/"
        else
            setup_fail "Key generation failed."
        fi
    else
        if "$BINARY_PATH" keytool generate validator \
            --datadir "$DATA_DIR" \
            --address "$VALIDATOR_ADDRESS" \
            --external-primary-addr "$PRIMARY_MULTIADDR" \
            --external-worker-addrs "$WORKER_MULTIADDR" \
            ${rpc_args[@]+"${rpc_args[@]}"}; then
            print_ok "Node keys generated in: ${DATA_DIR}/node-keys/"
        else
            setup_fail "Key generation failed."
        fi
    fi

    unset TN_BLS_PASSPHRASE
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "$DATA_DIR"

    local passphrase_file="${CONFIG_DIR}/bls-passphrase"
    # Create 0600 from the first byte (umask in a subshell, like
    # lib/observability.sh does for its token file): write-then-chmod left a
    # window where the passphrase was readable under the default umask. The
    # chmod stays for re-runs -- umask does not tighten a pre-existing file.
    ( umask 077; printf '%s\n' "$bls_passphrase" > "$passphrase_file" )
    chmod 600 "$passphrase_file"
    chown "${SERVICE_USER}:${SERVICE_GROUP}" "$passphrase_file"

    if [[ "$PASSPHRASE_METHOD" == "tpm" ]]; then
        tpm_seal_passphrase "$passphrase_file" "$CONFIG_DIR" "$bls_passphrase"
    else
        print_ok "Passphrase stored via LoadCredential (mode 600): ${passphrase_file}"
    fi

    bls_passphrase=""
    bls_passphrase_confirm=""

    display_node_info "$DATA_DIR" "$VALIDATOR_ADDRESS"

    echo ""
    print_warn "BACK UP YOUR KEYS NOW."
    print_info "If ${DATA_DIR}/node-keys/ is lost, you must re-register with the Association."
    echo ""
    # JSON mode: the UI enforces the "BACKED UP" gate between keygen and finalize,
    # so no blocking prompt here.
    json_mode || read -r -p "  Press Enter to confirm you have backed up your keys: "
}

step_write_config() {
    print_header "Step 6 of 8: Writing Configuration"

    local genesis_dir="${DATA_DIR}/genesis"
    mkdir -p "$genesis_dir"
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "$genesis_dir"

    local chain_subdir
    case "$NETWORK" in
        testnet) chain_subdir="testnet" ;;
        devnet)  chain_subdir="devnet" ;;
        *)       chain_subdir="mainnet" ;;
    esac

    local chain_configs_found=false
    # TN_GENESIS_DIR (optional) points DIRECTLY at the dir holding genesis.yaml/
    # committee.yaml/parameters.yaml and is checked FIRST. Expands to nothing when
    # unset, so the existing search order is unchanged.
    local search_paths=(
        ${TN_GENESIS_DIR:+"$TN_GENESIS_DIR"}
        "${TN_SOURCE_DIR}/chain-configs/${chain_subdir}"
        "/opt/telcoin-source/chain-configs/${chain_subdir}"
        "./chain-configs/${chain_subdir}"
        "${CONFIG_DIR}/chain-configs/${chain_subdir}"
    )

    for search_path in "${search_paths[@]}"; do
        if [[ -f "${search_path}/genesis.yaml" ]] && \
           [[ -f "${search_path}/committee.yaml" ]] && \
           [[ -f "${search_path}/parameters.yaml" ]]; then
            print_ok "Found chain-configs at: ${search_path}"
            cp "${search_path}/genesis.yaml"    "${genesis_dir}/genesis.yaml"
            cp "${search_path}/committee.yaml"  "${genesis_dir}/committee.yaml"
            cp "${search_path}/parameters.yaml" "${DATA_DIR}/parameters.yaml"
            chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "$genesis_dir" "${DATA_DIR}/parameters.yaml"
            print_ok "Chain config files copied"
            chain_configs_found=true
            break
        fi
    done

    if [[ "$chain_configs_found" == "false" ]]; then
        print_warn "Chain config files not found automatically."
        print_info "Copy from: https://github.com/Telcoin-Association/telcoin-network/tree/main/chain-configs/${chain_subdir}/"
        echo ""
        if json_mode; then
            setup_fail "Chain config files missing and cannot prompt in non-interactive mode."
        fi
        read -r -p "  Press Enter once you have copied the chain config files: "
    fi

    # Optional advertised node name -> data dir's network-config (no-op if blank).
    write_advertised_name "$DATA_DIR" "$ADVERTISED_NAME" "${SERVICE_USER}:${SERVICE_GROUP}"

    print_ok "Configuration ready under: ${DATA_DIR}"
}

# Build NODE_EXTRA_FLAGS, the node flags for the launch line, and record the choices in
# .node-meta (BOOTSTRAP_PEERS_FILE, STATE_EXPORT). Each flag in use must be listed by the
# `node --help` of the release this run installs: the flags are opt-in, and a node given
# a flag its release does not know refuses to start, so a missing one stops setup. The
# peers map is checked by the release's own parser and installed root-owned 0644 as
# CONFIG_DIR/bootstrap-peers.yaml. The launch line gets --bootstrap-peers "$(cat <file>)"
# as text: the host reads the file at each start, never during setup. Runs from
# step_create_infrastructure, so keygen stops before it makes keys, and again before the
# start wrapper is written (a --json finalize is a new process); a second run in one
# process, for the same release, does nothing.
prepare_node_extra_flags() {
    local spec flags="" peers="${CONFIG_DIR}/bootstrap-peers.yaml" path_re='^/[A-Za-z0-9._/+-]+$'
    spec="$(node_runner_spec)"
    if [[ "$NODE_EXTRA_FLAGS_SPEC" == "$spec" ]]; then
        return 0
    fi
    node_flag_warnings
    if [[ -n "$BOOTSTRAP_PEERS_SRC" ]]; then
        # The path lands in the wrapper unquoted, inside "$(cat ...)". Only a config
        # directory chosen at the prompt can fail this; the default always passes.
        if [[ ! "$peers" =~ $path_re ]]; then
            setup_fail "The custom config directory ${CONFIG_DIR} cannot be used with --bootstrap-peers: the start wrapper reads the peers file through this path unquoted, so it may hold only letters, digits and . _ / + -. Choose another config directory, or leave --bootstrap-peers out."
        fi
        require_node_flag "$spec" --bootstrap-peers v0.15.0-adiri
        flags="--bootstrap-peers \"\$(cat ${peers})\""
    fi
    case "${STATE_EXPORT:-off}" in
        off) ;;
        unlimited)
            require_node_flag "$spec" --enable-state-export v0.13.0-adiri
            flags="${flags:+${flags} }--enable-state-export"
            ;;
        *)
            require_node_flag "$spec" --enable-state-export v0.13.0-adiri
            require_node_flag "$spec" --state-export-keep v0.15.0-adiri
            flags="${flags:+${flags} }--enable-state-export --state-export-keep ${STATE_EXPORT}"
            ;;
    esac
    # The release knows every flag in use; now the map itself.
    if [[ -n "$BOOTSTRAP_PEERS_SRC" ]]; then
        install_bootstrap_peers "$spec" "$BOOTSTRAP_PEERS_SRC" "$peers"
        BOOTSTRAP_PEERS_SRC="$peers"
    fi
    NODE_EXTRA_FLAGS="$flags"
    write_node_meta "BOOTSTRAP_PEERS_FILE=${BOOTSTRAP_PEERS_SRC:+${peers}}" "STATE_EXPORT=${STATE_EXPORT:-off}"
    if [[ -n "$flags" ]]; then
        print_ok "Node flags: ${flags}"
        if json_mode; then
            json_event log "node flags: ${flags}"
        fi
    fi
    NODE_EXTRA_FLAGS_SPEC="$spec"
    return 0
}

# The runner spec (lib/common.sh) of the node this run installs: docker:<image> or
# binary:<path>, the same thing the start wrapper runs.
node_runner_spec() {
    if [[ "${INSTALL_METHOD:-}" == "docker" ]]; then
        printf 'docker:%s\n' "${DOCKER_IMAGE:-}"
    else
        printf 'binary:%s\n' "${BINARY_PATH:-}"
    fi
}

# The release this run installs, as messages name it: "the image <ref>", or "the node
# binary at <path>" plus the source ref setup recorded beside it, when there is one.
node_release_label() {
    local ver=""
    if [[ "${INSTALL_METHOD:-}" == "docker" ]]; then
        printf 'the image %s' "${DOCKER_IMAGE:-}"
        return 0
    fi
    if [[ -f "${BINARY_PATH:-}.version" ]]; then
        ver="$(head -n 1 "${BINARY_PATH}.version" 2>/dev/null || true)"
    fi
    printf 'the node binary at %s%s' "${BINARY_PATH:-}" "${ver:+ (${ver})}"
}

# Stop setup when the `node --help` of runner SPEC does not list FLAG; SINCE is the first
# release that has it. When the release cannot be asked (its --help did not run), warn and
# go on: a node that then rejects the flag fails the start check.
require_node_flag() {
    local spec="$1" flag="$2" since="$3" rc=0
    tn_node_has_flag "$spec" "$flag" || rc=$?
    case "$rc" in
        0) ;;
        1) setup_fail "${flag} needs telcoin-network ${since} or later, and $(node_release_label) does not have it. Pick a newer release or leave ${flag} out." ;;
        *) setup_warn "Could not ask $(node_release_label) whether it has ${flag} (its node --help did not run); adding the flag anyway." ;;
    esac
    return 0
}

# Install the peers map SRC as DEST, root-owned 0644, once the release of runner SPEC
# accepts it: tn_node_parse_check has clap parse the value and print help, which starts
# nothing. That check is the one time a run hands the map to a node binary. SRC is
# checked again just before it is read (setup may have spent a long build since the
# first check), then copied to a temp file next to DEST; that copy is what gets checked
# and renamed into place, so the node reads exactly the bytes that were checked and an
# existing DEST changes only after the check passes. A rejected map stops setup with the
# library's one-line reason, in which the map itself is replaced by '…'. A check that
# cannot run warns, and the map is installed unchecked.
install_bootstrap_peers() {
    local spec="$1" src="$2" dest="$3" tmp msg="" rc=0
    msg="$(peers_file_ok "$src")" || setup_fail "--bootstrap-peers: ${msg}."
    tmp="$(mktemp "${dest}.XXXXXX" 2>/dev/null)" || setup_fail "Could not create a temp file next to ${dest}."
    if ! { cat "$src" > "$tmp" && chmod 0644 "$tmp"; } 2>/dev/null; then
        rm -f "$tmp"
        setup_fail "Could not copy ${src} to ${tmp}."
    fi
    # The copy as well: the file may have changed since it was checked.
    if ! msg="$(peers_file_ok "$tmp")"; then
        rm -f "$tmp"
        setup_fail "--bootstrap-peers: the copy of ${src} failed its check: ${msg}."
    fi
    msg="$(tn_node_parse_check "$spec" --bootstrap-peers "$(cat "$tmp")")" || rc=$?
    case "$rc" in
        0) ;;
        1)
            rm -f "$tmp"
            setup_fail "The bootstrap peers map in ${src} is not valid for $(node_release_label) (${msg}). Each key must be a node's BLS public key and each value the primary and workers entries from that node's node-info.yaml."
            ;;
        *)
            setup_warn "Could not check the bootstrap peers map in ${src} with $(node_release_label) (${msg}); installing it unchecked."
            ;;
    esac
    if ! { chown root:root "$tmp" && mv -f "$tmp" "$dest"; }; then
        rm -f "$tmp"
        setup_fail "Could not install ${dest}."
    fi
    print_ok "Bootstrap peers map installed: ${dest}"
    return 0
}

# The flags appended to the node launch line for METHOD (docker | binary): the testnet
# add-on flags (tn_node_launch_flags), then NODE_EXTRA_FLAGS. The wrapper heredocs expand
# this text once, so a "$(cat FILE)" inside it lands in the wrapper as written and runs
# at each start, not during setup. With no extra flags the line is exactly as before.
node_launch_flags() {
    local flags
    flags="$(tn_node_launch_flags "$1")"
    if [[ -n "$NODE_EXTRA_FLAGS" ]]; then
        flags="${flags:+${flags} }${NODE_EXTRA_FLAGS}"
    fi
    printf '%s' "$flags"
}

step_create_service() {
    print_header "Step 7 of 8: Creating Systemd Service"

    # RPC_PORT is already set/defaulted (validators default to 8545). WS port is the
    # reth base 8546. The launch heredocs below enable --ws and pin both --http.addr/
    # --ws.addr to 127.0.0.1 so RPC + WS are reachable ONLY via the Caddy TLS edge (reth
    # already defaults to loopback; pinning makes the intent explicit + immune to a future
    # default change). WS_PORT is persisted to .node-meta so install-caddy.sh (this repo;
    # write_rpc_block) proxies wss:// to the right port -- verify the real bind with
    # `ss -tlnp` at rollout. (Provenance, maintainer-only: common/config-caddy.sh on the
    # maintainer fleet reads the same key; it is not shipped to operators.)
    WS_PORT=8546
    print_ok "RPC port: ${RPC_PORT}, WS port: ${WS_PORT}"

    local primary_multiaddr="$PRIMARY_LISTENER_MULTIADDR"
    local worker_multiaddr="$WORKER_LISTENER_MULTIADDR"
    print_info "P2P listener (internal): ${primary_multiaddr}"

    local passphrase_file="${CONFIG_DIR}/bls-passphrase"
    local service_file="/etc/systemd/system/${SERVICE_NAME}.service"

    # The UI runs setup as two separate processes (keygen, then finalize). The
    # source build that sets BINARY_PATH happens in keygen; finalize reads it back
    # from .node-meta (finalize_install_inputs). An install whose keygen predates
    # that record has none, and an empty BINARY_PATH would make the wrapper run the
    # system `node` (Node.js) instead of the Telcoin binary. Source builds always
    # install to ${INSTALL_DIR}/telcoin-network, so re-derive it.
    if [[ "${INSTALL_METHOD:-}" != "docker" && "${INSTALL_METHOD:-}" != "existing" && -z "${BINARY_PATH:-}" ]]; then
        BINARY_PATH="${INSTALL_DIR}/telcoin-network"
    fi

    prepare_node_extra_flags

    if [[ "${INSTALL_METHOD:-}" == "docker" ]]; then
        # Guard: never write a wrapper without an image (docker would take the next
        # word, `telcoin`, for the image name).
        if [[ -z "${DOCKER_IMAGE:-}" ]]; then
            setup_fail "No docker image to run (--docker-image) -- cannot write start wrapper."
        fi
        local docker_uid docker_gid
        docker_uid=$(id -u "$SERVICE_USER" 2>/dev/null || echo "1101")
        docker_gid=$(id -g "$SERVICE_GROUP" 2>/dev/null || echo "1101")

        # Testnet opt-in launch flags (healthcheck + JSON log shipping) and the node flags
        # (bootstrap peers, state export) as ONE line, so an empty tail can't leave a
        # dangling backslash. Docker reth log dir is the container path
        # /home/nonroot/logs (= host ${DATA_DIR}/logs). The peers map is read on the host,
        # where "$(cat ...)" runs, and reaches the container as one argument.
        local launch_flags; launch_flags="$(node_launch_flags docker)"

        # BLS passphrase is injected at RUNTIME, mirroring the source/binary path below: a
        # root-owned wrapper reads it (TPM, else the systemd LoadCredential dir) and
        # pass-throughs it to the container with `-e TN_BLS_PASSPHRASE` (NAME only -- the
        # value is NEVER written into the unit, so `systemctl cat`/`show` stay clean). The
        # value still lives in the container's env (inherent to Docker; see the README
        # security note) -- keeping it out of the persisted unit is the meaningful win.
        #
        # Pin HOME=/home/nonroot in the docker run: a numeric --user has no passwd entry in
        # the image, so $HOME would default to "/" and reth's default log dir
        # ($HOME/.cache/reth/logs) would be unwritable -> the node crash-loops on boot unless
        # obs logging happens to add --log.file.directory. The datadir is bind-mounted at
        # /home/nonroot and owned by --user, so logs/keys land writable. (Same root cause as
        # the keygen docker run.)
        local wrapper="${INSTALL_DIR}/start-${SERVICE_NAME}.sh"
        install -d -m 0755 "${INSTALL_DIR}"
        if [[ "$PASSPHRASE_METHOD" == "tpm" ]]; then
            cat > "$wrapper" <<EOF
#!/usr/bin/env bash
# Auto-generated by setup-node.sh v${SCRIPT_VERSION}
# Reads BLS passphrase from TPM (with LoadCredential fallback) and starts the node container.
if command -v tpm2_unseal &>/dev/null && \
   [[ -f ${CONFIG_DIR}/bls-tpm.pub ]] && \
   [[ -f ${CONFIG_DIR}/bls-tpm.priv ]]; then
    tpm2_createprimary -Q -C e -c /tmp/tn-tpm-primary.ctx 2>/dev/null
    tpm2_load -Q -C /tmp/tn-tpm-primary.ctx \
        -u ${CONFIG_DIR}/bls-tpm.pub \
        -r ${CONFIG_DIR}/bls-tpm.priv \
        -c /tmp/tn-tpm-sealed.ctx 2>/dev/null
    export TN_BLS_PASSPHRASE=\$(tpm2_unseal -Q -c /tmp/tn-tpm-sealed.ctx 2>/dev/null)
    rm -f /tmp/tn-tpm-primary.ctx /tmp/tn-tpm-sealed.ctx
fi
if [[ -z "\${TN_BLS_PASSPHRASE:-}" ]]; then
    export TN_BLS_PASSPHRASE=\$(cat "\${CREDENTIALS_DIRECTORY}/bls-passphrase" 2>/dev/null || echo "")
fi
exec docker run --rm \
--name ${SERVICE_NAME} \
--user ${docker_uid}:${docker_gid} \
-e "HOME=/home/nonroot" \
--network=host \
-e TN_BLS_PASSPHRASE \
-e "PRIMARY_LISTENER_MULTIADDR=${primary_multiaddr}" \
-e "WORKER_LISTENER_MULTIADDR=${worker_multiaddr}" \
-v ${DATA_DIR}:/home/nonroot \
-v ${CONFIG_DIR}:/etc/telcoin:ro \
${DOCKER_IMAGE} \
telcoin node \
--datadir /home/nonroot \
--log.stdout.format log-fmt \
-vvv \
--http --http.addr 127.0.0.1 --ws --ws.addr 127.0.0.1 ${launch_flags}
EOF
        else
            cat > "$wrapper" <<EOF
#!/usr/bin/env bash
# Auto-generated by setup-node.sh v${SCRIPT_VERSION}
# Reads BLS passphrase from the systemd credential directory and starts the node container.
export TN_BLS_PASSPHRASE=\$(cat "\${CREDENTIALS_DIRECTORY}/bls-passphrase")
exec docker run --rm \
--name ${SERVICE_NAME} \
--user ${docker_uid}:${docker_gid} \
-e "HOME=/home/nonroot" \
--network=host \
-e TN_BLS_PASSPHRASE \
-e "PRIMARY_LISTENER_MULTIADDR=${primary_multiaddr}" \
-e "WORKER_LISTENER_MULTIADDR=${worker_multiaddr}" \
-v ${DATA_DIR}:/home/nonroot \
-v ${CONFIG_DIR}:/etc/telcoin:ro \
${DOCKER_IMAGE} \
telcoin node \
--datadir /home/nonroot \
--log.stdout.format log-fmt \
-vvv \
--http --http.addr 127.0.0.1 --ws --ws.addr 127.0.0.1 ${launch_flags}
EOF
        fi
        # Root-owned + non-writable by SERVICE_USER: the unit runs ExecStart as root, so a
        # service-user-writable wrapper would be a root-escalation vector.
        chmod 0750 "$wrapper"
        chown root:root "$wrapper"
        print_ok "Wrapper script written: ${wrapper}"

        {
            cat <<EOF
[Unit]
Description=Telcoin Network Node (${CHAIN_NAME}) [Docker]
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=root
EOF
            # Only include LoadCredential for the loadcredential method (TPM manages the
            # passphrase itself -- the credential file may not exist).
            if [[ "$PASSPHRASE_METHOD" != "tpm" ]]; then
                echo "LoadCredential=bls-passphrase:${passphrase_file}"
            fi
            cat <<EOF
ExecStartPre=-/usr/bin/docker rm -f ${SERVICE_NAME}
ExecStart=${wrapper}
ExecStop=docker stop ${SERVICE_NAME}
Restart=on-failure
RestartSec=10
StandardOutput=append:${LOG_DIR}/${SERVICE_NAME}.log
StandardError=append:${LOG_DIR}/${SERVICE_NAME}-error.log

[Install]
WantedBy=multi-user.target
EOF
        } > "$service_file"

    else
        # Guard: never write a wrapper with an empty binary path (it would exec
        # the system `node` and fail with "node: bad option: --datadir").
        if [[ -z "${BINARY_PATH:-}" || ! -x "${BINARY_PATH}" ]]; then
            setup_fail "Node binary not found at '${BINARY_PATH:-<unset>}' -- cannot write start wrapper. A source build installs it at ${INSTALL_DIR}/telcoin-network; an existing install needs --binary-path."
        fi
        local wrapper="${INSTALL_DIR}/start-${SERVICE_NAME}.sh"

        # Testnet opt-in launch flags (healthcheck + JSON log shipping) and the node flags
        # (bootstrap peers, state export) as ONE line, so an empty tail can't leave a
        # dangling backslash. Binary reth log dir is the host path /var/log/telcoin
        # (already in the unit's ReadWritePaths, owned telcoin:telcoin).
        local launch_flags; launch_flags="$(node_launch_flags binary)"

        if [[ "$PASSPHRASE_METHOD" == "tpm" ]]; then
            cat > "$wrapper" <<EOF
#!/usr/bin/env bash
# Auto-generated by setup-node.sh v${SCRIPT_VERSION}
# Reads BLS passphrase from TPM (with LoadCredential fallback) and starts the node
if command -v tpm2_unseal &>/dev/null && \
   [[ -f ${CONFIG_DIR}/bls-tpm.pub ]] && \
   [[ -f ${CONFIG_DIR}/bls-tpm.priv ]]; then
    tpm2_createprimary -Q -C e -c /tmp/tn-tpm-primary.ctx 2>/dev/null
    tpm2_load -Q -C /tmp/tn-tpm-primary.ctx \
        -u ${CONFIG_DIR}/bls-tpm.pub \
        -r ${CONFIG_DIR}/bls-tpm.priv \
        -c /tmp/tn-tpm-sealed.ctx 2>/dev/null
    export TN_BLS_PASSPHRASE=\$(tpm2_unseal -Q -c /tmp/tn-tpm-sealed.ctx 2>/dev/null)
    rm -f /tmp/tn-tpm-primary.ctx /tmp/tn-tpm-sealed.ctx
fi
if [[ -z "\${TN_BLS_PASSPHRASE:-}" ]]; then
    export TN_BLS_PASSPHRASE=\$(cat "\${CREDENTIALS_DIRECTORY}/bls-passphrase" 2>/dev/null || echo "")
fi
export PRIMARY_LISTENER_MULTIADDR="${primary_multiaddr}"
export WORKER_LISTENER_MULTIADDR="${worker_multiaddr}"
exec ${BINARY_PATH} node \
  --datadir ${DATA_DIR} \
  --log.stdout.format log-fmt \
  -vvv \
  --http --http.addr 127.0.0.1 --ws --ws.addr 127.0.0.1 ${launch_flags}
EOF
        else
            cat > "$wrapper" <<EOF
#!/usr/bin/env bash
# Auto-generated by setup-node.sh v${SCRIPT_VERSION}
# Reads BLS passphrase from systemd credential directory and starts the node
export TN_BLS_PASSPHRASE=\$(cat "\${CREDENTIALS_DIRECTORY}/bls-passphrase")
export PRIMARY_LISTENER_MULTIADDR="${primary_multiaddr}"
export WORKER_LISTENER_MULTIADDR="${worker_multiaddr}"
exec ${BINARY_PATH} node \
  --datadir ${DATA_DIR} \
  --log.stdout.format log-fmt \
  -vvv \
  --http --http.addr 127.0.0.1 --ws --ws.addr 127.0.0.1 ${launch_flags}
EOF
        fi

        chmod +x "$wrapper"
        chown "${SERVICE_USER}:${SERVICE_GROUP}" "$wrapper"
        print_ok "Wrapper script written: ${wrapper}"

        {
            cat <<EOF
[Unit]
Description=Telcoin Network Node (${CHAIN_NAME})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
EOF
            # Only include LoadCredential for loadcredential method
            # TPM method manages passphrase directly -- file may not exist
            if [[ "$PASSPHRASE_METHOD" != "tpm" ]]; then
                echo "LoadCredential=bls-passphrase:${passphrase_file}"
            fi
            cat <<EOF
Environment="PRIMARY_LISTENER_MULTIADDR=${primary_multiaddr}"
Environment="WORKER_LISTENER_MULTIADDR=${worker_multiaddr}"
ExecStart=${wrapper}
Restart=on-failure
RestartSec=10
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=${DATA_DIR} ${LOG_DIR}
LimitNOFILE=65536
StandardOutput=append:${LOG_DIR}/${SERVICE_NAME}.log
StandardError=append:${LOG_DIR}/${SERVICE_NAME}-error.log

[Install]
WantedBy=multi-user.target
EOF
        } > "$service_file"
    fi

    systemctl daemon-reload
    print_ok "Service file written: ${service_file}"

    # PUBLIC_RPC_DOMAIN: the public RPC hostname ('' = private). Written even when the
    # enable at the end of setup is still pending, so a later install-caddy.sh run and
    # check-node.sh know which name this node is meant to serve. Each key is set on its
    # own (write_node_meta), so keys other scripts keep in the file survive a re-run.
    local meta_file="${CONFIG_DIR}/.node-meta"
    mkdir -p "$CONFIG_DIR"
    write_node_meta \
        "HOST_SERVICE_USER=${SERVICE_USER}" \
        "HOST_SERVICE_GROUP=${SERVICE_GROUP}" \
        "INSTALL_METHOD=${INSTALL_METHOD:-binary}" \
        "PASSPHRASE_METHOD=${PASSPHRASE_METHOD}" \
        "NETWORK=${NETWORK}" \
        "DATA_DIR=${DATA_DIR}" \
        "RPC_PORT=${RPC_PORT}" \
        "WS_PORT=${WS_PORT}" \
        "PUBLIC_RPC_DOMAIN=${PUBLIC_RPC_DOMAIN:-}" \
        "PUBLIC_IP=${PUBLIC_IP:-}" \
        "EXTERNAL_PRIMARY_ADDR=${PRIMARY_MULTIADDR:-}" \
        "EXTERNAL_WORKER_ADDR=${WORKER_MULTIADDR:-}" \
        "VALIDATOR_ADDRESS=${VALIDATOR_ADDRESS:-}" \
        "REGION=${REGION:-}" \
        "ENABLE_HEALTHCHECK_MONITOR=${ENABLE_HEALTHCHECK_MONITOR:-false}" \
        "ENABLE_OBSERVABILITY=${ENABLE_OBSERVABILITY:-false}" \
        "ENABLE_METRICS=${ENABLE_METRICS:-false}" \
        "METRICS_PORT=${METRICS_PORT:-9101}" \
        "ENABLE_VPN=${ENABLE_VPN:-false}" \
        "VPN_OVERLAY_IP=${VPN_OVERLAY_IP:-}" \
        "VPN_NODE_PUBKEY=${VPN_NODE_PUBKEY:-}" \
        "PUBLIC_RPC_URL=${PUBLIC_RPC_URL:-}" \
        "PUBLIC_WS_URL=${PUBLIC_WS_URL:-}"
    write_node_meta_runner
    print_ok "Node metadata written: ${meta_file}"

    # Start each install with a clean log. The unit appends
    # (StandardOutput=append:), so a re-install would otherwise concatenate its
    # output onto the previous install's log -- mixing old + new runs in the file
    # the UI's "download full log" serves. Truncate in place (preserves the
    # service-user ownership); systemd recreates a fresh file for a new install.
    [[ -f "${LOG_DIR}/${SERVICE_NAME}.log" ]] && : > "${LOG_DIR}/${SERVICE_NAME}.log" || true
    [[ -f "${LOG_DIR}/${SERVICE_NAME}-error.log" ]] && : > "${LOG_DIR}/${SERVICE_NAME}-error.log" || true

    echo ""
    if json_mode || confirm "Start the node now?"; then
        systemctl start "$SERVICE_NAME"
        sleep 3

        if systemctl is-active --quiet "$SERVICE_NAME"; then
            print_ok "Service is running"
            NODE_STARTED=true
        else
            systemctl status "$SERVICE_NAME" --no-pager || true
            setup_fail "Service failed to start. Check logs: journalctl -u ${SERVICE_NAME} --no-pager -n 50"
        fi

        local local_rpc="http://127.0.0.1:${RPC_PORT}"
        check_rpc_alive "$local_rpc" 15 6 || print_warn "RPC not yet responding -- normal during startup."

        echo ""
        # `|| true` is REQUIRED, not defensive. This is a purely informational probe, but
        # it returns 1 whenever the address is missing or malformed ("Invalid validator
        # address -- skipping on-chain check", in lib/common.sh) and this file runs
        # under `set -e`. Bare, it aborts finalize AFTER the service is already up but
        # BEFORE the `systemctl enable` below -- leaving a node that runs now and never
        # comes back from a reboot, while the caller sees only {"ok":false,"rc":1}.
        # The other callers already guard it with `|| true`; this one was the outlier.
        check_validator_onchain_status "$VALIDATOR_ADDRESS" "$local_rpc" || true

        if json_mode || confirm "Enable auto-start on server reboot?"; then
            systemctl enable "$SERVICE_NAME"
            print_ok "Auto-start enabled"
        fi
    fi
}

# =============================================================================
# PUBLIC RPC  (optional -- runs only when a domain was chosen)
#
# Serves https://<domain>/ + wss://<domain>/ through Caddy and advertises both in
# node-info.yaml (worker.rpc) using install-caddy.sh from this repo. It never fails
# setup: if the node is not running, DNS does not point here yet, or the enable does not
# finish, PUBLIC_RPC_STATE=pending records why and the summary prints the exact command
# to finish later. PUBLIC_RPC_DOMAIN is already in .node-meta (step_create_service).
# =============================================================================

# The install-caddy.sh command for <phase> (rpc-enable | rpc-check-dns) on [<domain>]
# (default: this node's PUBLIC_RPC_DOMAIN), as the operator should run it by hand when
# setup could not finish the enable.
public_rpc_cmd() {
    printf 'sudo bash %s/install-caddy.sh --phase=%s --rpc-domain %s%s' \
        "$SCRIPT_DIR" "$1" "${2:-$PUBLIC_RPC_DOMAIN}" "${RPC_INBOUND_IP:+ --public-ip ${RPC_INBOUND_IP}}"
}

# A public-RPC flag came without a usable hostname (RPC_PRIVATE_NOTE says which). Not an
# error -- Node Manager UI releases before 1.9.0 send `--rpc-public true` and never a
# domain -- so RPC stays private and this says how to enable it later. --json: a `log`
# event, never `error`, so the run still ends with done ok:true.
public_rpc_no_domain_notice() {
    local cmd
    cmd="$(public_rpc_cmd rpc-enable '<hostname>')"
    print_warn "Public RPC not enabled: ${RPC_PRIVATE_NOTE} -- RPC stays private (127.0.0.1 only)."
    print_info "To serve public RPC later, point a DNS name at this server and run:"
    echo "    ${cmd}"
    if json_mode; then
        json_event log "public RPC not enabled: ${RPC_PRIVATE_NOTE} -- RPC stays private (127.0.0.1 only). To enable it later, point a DNS name at this server and run: ${cmd}"
    fi
    return 0
}

# Record that public RPC is not enabled yet (and why), and say how to finish.
public_rpc_pending() {
    PUBLIC_RPC_STATE="pending"
    PUBLIC_RPC_REASON="$1"
    local d="$PUBLIC_RPC_DOMAIN" live=""
    echo ""
    print_warn "Public RPC not enabled yet: ${PUBLIC_RPC_REASON}"
    print_info "When that is fixed, run:"
    echo "    $(public_rpc_cmd rpc-enable)"
    # Keygen may already have written the URL into node-info.yaml (--rpc-domain / --rpc-http),
    # so the node record can advertise an endpoint Caddy does not serve yet. Say so, and how
    # to withdraw it if the operator does not mean to finish.
    if grep -qF "https://${d}/" "$(public_rpc_node_info)" 2>/dev/null; then
        live="node-info.yaml already advertises https://${d}/: the advertisement is live in the node record and will serve once rpc-enable completes. To withdraw it instead, run: sudo bash ${SCRIPT_DIR}/install-caddy.sh --phase=rpc-disable"
        print_info "$live"
    fi
    if json_mode; then
        json_event log "public RPC not enabled yet: ${PUBLIC_RPC_REASON} -- to finish, run: $(public_rpc_cmd rpc-enable)"
        if [[ -n "$live" ]]; then
            json_event log "$live"
        fi
    fi
    return 0
}

# The node-info.yaml rpc-enable advertises in. install-caddy.sh resolves it through the lib
# (caddy_node_info_path -> tn_resolve_data_dir), not from --data-dir, so read that same
# file -- otherwise a custom --data-dir would read as permanently pending.
public_rpc_node_info() {
    printf '%s/node-info.yaml' "$(tn_resolve_data_dir 2>/dev/null || echo /var/lib/telcoin)"
}

step_public_rpc() {
    [[ -n "$PUBLIC_RPC_DOMAIN" ]] || return 0
    local d="$PUBLIC_RPC_DOMAIN" caddy="${SCRIPT_DIR}/install-caddy.sh"
    local dns_json="" note="" ni propagated_re='"propagated"[[:space:]]*:[[:space:]]*true'
    ni="$(public_rpc_node_info)"

    print_header "Public RPC -- https://${d}/ + wss://${d}/"

    if [[ ! -f "$caddy" ]]; then
        public_rpc_pending "install-caddy.sh is missing (${caddy}) -- restore it with update-scripts.sh."
        return 0
    fi
    # rpc-enable restarts the node to apply the advertisement, so only enable a node this
    # run started (--json, or a yes to "Start the node now?"). Gating on the operator's
    # answer, not `systemctl is-active`, keeps a declined start declined on a re-run over
    # an existing install, whose old unit is still running.
    if [[ "$NODE_STARTED" != "true" ]]; then
        public_rpc_pending "you chose not to start the node now, and enabling public RPC restarts it -- run the command below once the ${SERVICE_NAME} service may be (re)started."
        return 0
    fi

    # DNS gate. The --json check-dns phase is the stable machine contract (the Node Manager
    # UI uses it too): one JSON object whose "propagated" is true only when the A record
    # reaches this host -- its public IP, the --public-ip override, or a bound local IP.
    # Keying on that field (not an exit code or prose) keeps this robust to wording
    # changes. A pass means DNS targets this box, not that 80/443 are open.
    print_step "Checking that ${d} resolves to this server..."
    dns_json="$(TN_ASSUME_YES=false bash "$caddy" --json --phase=rpc-check-dns --rpc-domain "$d" ${RPC_INBOUND_IP:+--public-ip "$RPC_INBOUND_IP"} </dev/null 3>&-)" || true
    note="$(printf '%s\n' "$dns_json" | sed -n 's/.*"note":"\(.*\)"}.*$/\1/p' | head -n1)" || true
    if [[ ! "$dns_json" =~ $propagated_re ]]; then
        public_rpc_pending "DNS for ${d} does not point at this server yet. ${note:-The DNS check returned no result.}"
        return 0
    fi
    print_ok "${note:-${d} resolves to this server.}"

    # Enable: installs Caddy, writes the tn-rpc vhost, checks reth's WebSocket listener,
    # advertises https:// + wss:// in node-info.yaml and restarts the node under
    # install-caddy's brick guard. Run as the human-readable, non-interactive phase (no
    # --json) so its progress shows here. stdin is /dev/null and TN_ASSUME_YES is forced
    # off, so nothing can block on a prompt or auto-accept one (e.g. replacing a Caddyfile
    # this repo did not write); fd3 (the --json event stream) is closed for the child.
    print_step "Enabling public RPC for ${d} (Caddy + node-info.yaml advertisement)..."
    if ! TN_ASSUME_YES=false bash "$caddy" --phase=rpc-enable --rpc-domain "$d" ${RPC_INBOUND_IP:+--public-ip "$RPC_INBOUND_IP"} </dev/null 3>&-; then
        public_rpc_pending "install-caddy.sh did not finish enabling it (see the messages above)."
        return 0
    fi
    # rpc-enable exits 0 even when it could only warn about advertising (no python3 / no
    # node-info.yaml), so confirm the advertisement itself -- both URLs -- before calling
    # it done.
    local missing=""
    if ! grep -qF "https://${d}/" "$ni" 2>/dev/null; then missing="https://${d}/"; fi
    if ! grep -qF "wss://${d}/" "$ni" 2>/dev/null; then missing="${missing:+${missing} and }wss://${d}/"; fi
    if [[ -n "$missing" ]]; then
        public_rpc_pending "Caddy serves ${d}, but ${ni} does not advertise ${missing} yet (see the messages above)."
        return 0
    fi
    PUBLIC_RPC_STATE="enabled"
    print_ok "Public RPC enabled: https://${d}/ + wss://${d}/, advertised in node-info.yaml (worker.rpc)."
    if json_mode; then
        json_event log "public RPC enabled: https://${d}/ + wss://${d}/, advertised in node-info.yaml (worker.rpc)"
    fi
    print_info "Caddy obtains the TLS certificate for ${d} when it loads the config; issuance can take a minute."
    return 0
}

step_final_summary() {
    # The P2P ports node-info.yaml advertises (keytool wrote them at keygen, one per
    # worker), or the configured ports when the file cannot be read.
    local ni="${DATA_DIR}/node-info.yaml" p2p_port ports workers="" p worker_label="P2P worker port"
    p2p_port="$(tn_node_info_field "$ni" primary_port 2>/dev/null)" || p2p_port="$P2P_PORT"
    ports="$(tn_node_info_worker_ports "$ni" 2>/dev/null)" || ports=""
    for p in $ports; do
        workers="${workers:+${workers}, }${p}"
    done
    if [[ -z "$workers" ]]; then
        workers="$WORKER_PORT"
    elif [[ "$workers" == *,* ]]; then
        worker_label="P2P worker ports"
    fi
    # Every P2P port for the firewall reminder: "41000 and 41004", or with more workers
    # "41000, 41004 and 41008".
    local udp_all="${p2p_port}, ${workers}" udp_list
    udp_list="${udp_all%, *} and ${udp_all##*, }"
    # The node flags, when any are in use.
    local node_flags=()
    if [[ -n "$BOOTSTRAP_PEERS_SRC" ]]; then
        node_flags+=("Bootstrap peers=${BOOTSTRAP_PEERS_SRC}")
    fi
    case "${STATE_EXPORT:-off}" in
        off) ;;
        unlimited) node_flags+=("State export=every epoch, none deleted") ;;
        *) node_flags+=("State export=every epoch, newest ${STATE_EXPORT} kept") ;;
    esac

    print_summary "Node Setup Complete" \
        "Network=${NETWORK} (Chain ID: ${CHAIN_ID})" \
        "Role=decided on-chain (full node until you stake + activate)" \
        "Binary=${BINARY_PATH}" \
        "Data directory=${DATA_DIR}" \
        "Config directory=${CONFIG_DIR}" \
        "Log directory=${LOG_DIR}" \
        "P2P primary port=${p2p_port}" \
        "${worker_label}=${workers}" \
        "RPC port=${RPC_PORT}" \
        "Metrics port=${METRICS_PORT}" \
        "Systemd service=${SERVICE_NAME}" \
        "Explorer=${EXPLORER_URL}" \
        ${node_flags[@]+"${node_flags[@]}"}

    if [[ "${INSTALL_METHOD:-}" != "docker" ]]; then
        if [[ "$PASSPHRASE_METHOD" == "tpm" ]]; then
            print_info "BLS passphrase sealed to TPM chip."
        else
            print_info "BLS passphrase secured via systemd LoadCredential (not exposed in service file)."
        fi
    fi

    # Public RPC (only when a domain was chosen): the endpoints, and either the enabled +
    # advertised state or the one command that finishes the job.
    if [[ -n "$PUBLIC_RPC_DOMAIN" ]]; then
        echo ""
        echo "  Public RPC endpoints:"
        echo "    https://${PUBLIC_RPC_DOMAIN}/"
        echo "    wss://${PUBLIC_RPC_DOMAIN}/"
        if [[ "$PUBLIC_RPC_STATE" == "enabled" ]]; then
            print_ok "Enabled via Caddy and advertised in node-info.yaml (worker.rpc)."
        else
            print_warn "Not enabled yet: ${PUBLIC_RPC_REASON:-setup did not reach the public RPC step.}"
            print_info "Once that is fixed (usually: the A record points at this server), run:"
            echo "    $(public_rpc_cmd rpc-enable)"
            print_info "To check DNS first (no changes made):"
            echo "    $(public_rpc_cmd rpc-check-dns)"
            if [[ -z "$RPC_INBOUND_IP" ]]; then
                print_info "Behind NAT or on a multi-IP server? Add --public-ip <inbound-ip>."
            fi
        fi
        print_info "Keep inbound TCP 80 + 443 open to this server (cloud firewall too): Caddy"
        print_info "uses them to obtain and renew the TLS certificate."
    fi
    echo ""
    echo "  Useful commands:"
    echo ""
    echo "  View logs:"
    echo "    journalctl -u ${SERVICE_NAME} -f"
    echo ""
    echo "  Check RPC:"
    echo "    curl -s -X POST -H 'Content-Type: application/json' \\"
    echo "      --data '{\"jsonrpc\":\"2.0\",\"method\":\"eth_chainId\",\"params\":[],\"id\":1}' \\"
    echo "      http://127.0.0.1:${RPC_PORT}"
    echo ""
    echo "  Stop / restart:"
    echo "    systemctl stop ${SERVICE_NAME}"
    echo "    systemctl restart ${SERVICE_NAME}"
    echo ""
    print_sep
    echo ""
    print_info "Your node is set up and will follow consensus as a full node."
    print_info "Make sure inbound UDP ${udp_list} are open (run firewall-setup.sh)."
    echo ""
    print_info "Becoming a validator is optional. To validate:"
    echo "  1. Get governance approval from the Telcoin Association (GSMA-approved MNOs)"
    echo "  2. Once approved and your NFT is minted, stake TEL via the ConsensusRegistry contract"
    echo "  3. After your node syncs, call activate()"
    echo "  The dashboard switches to the validator view automatically once activation is on-chain."
    echo ""
    print_info "Health check:     bash check-node.sh --address ${VALIDATOR_ADDRESS}"
    print_info "Operator runbook: ${TN_OPERATOR_GUIDE_URL}"
    print_info "Staking guide:    https://docs.telcoin.network/telcoin-network/staking/how-to-stake"
    echo ""
}

# =============================================================================
# JSON / NON-INTERACTIVE MODE  (phased, driven by the Node Manager UI)
#
# Reached only via `--json` (the interactive default is completely unaffected).
# Two phases, mirroring the UI's forced key-backup gate:
#   --json --phase=keygen   -> preflight + infrastructure + key generation only;
#                              writes NO unit and starts NOTHING. Emits the full
#                              node-info.yaml so the operator can back it up.
#   --json --phase=finalize -> write config + create service + start + verify.
#                              The install method and the docker image or binary
#                              path come from its flags or, when a flag is left
#                              out, from what keygen recorded in .node-meta.
#
# fd handling mirrors update-node.sh: stdout -> fd3 (newline-delimited JSON),
# real stdout -> stderr. main finds --json and swaps the fds before it parses
# anything, and installs json_on_exit, so every --json run prints only JSON on
# stdout and ends with exactly one done event, however it stops. BLS passphrase
# arrives via TN_BLS_PASSPHRASE env ONLY.
#
# Note: on-chain validator registration (governance approval, staking,
# activate()) is intentionally NOT performed here -- the UI surfaces the
# next-step guidance the interactive summary prints.
# =============================================================================

JSON_MODE=false
JSON_PHASE=""
JSON_BUILD_REF=""
JSON_NETWORK_INPUT="testnet"
JSON_DONE_EMITTED=false
JSON_LAST_ERROR=""   # the last error event's message; json_on_exit reuses it for done
# Optional override: dir holding genesis.yaml/committee.yaml/parameters.yaml,
# checked first by step_write_config. Preserve any env value; default empty so
# `set -u` never trips and the ${TN_GENESIS_DIR:+...} expansion is a no-op.
TN_GENESIS_DIR="${TN_GENESIS_DIR:-}"

json_mode() { [[ "$JSON_MODE" == "true" ]]; }

json_setup_fds() {
    exec 3>&1   # fd3 = original stdout: JSON is written here
    exec 1>&2   # stdout now aliases stderr: print_*/build output is benign noise
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/ }"; s="${s//$'\t'/ }"
    printf '%s' "$s"
}

json_emit() { printf '%s\n' "$1" >&3; }
json_event() {
    if [[ "$1" == "error" ]]; then
        JSON_LAST_ERROR="${2:-}"
    fi
    json_emit "{\"event\":\"${1}\",\"msg\":\"$(json_escape "${2:-}")\"}"
}
json_done() { JSON_DONE_EMITTED=true; json_emit "$1"; }

# A JSON string for VALUE, or null when VALUE is empty.
json_str_or_null() {
    if [[ -n "${1:-}" ]]; then
        printf '"%s"' "$(json_escape "$1")"
    else
        printf 'null'
    fi
}

# Run a command, streaming each combined-output line to the UI as a JSON `log`
# event (JSON mode only) so the long, otherwise-silent steps -- the git clone and
# the 20-40 min cargo build -- show live progress instead of looking frozen. In
# interactive mode the command just runs normally. Returns the command's status.
run_streamed() {
    if json_mode; then
        "$@" 2>&1 | while IFS= read -r _line; do
            json_emit "{\"event\":\"log\",\"msg\":\"$(json_escape "$_line")\"}"
        done
        return "${PIPESTATUS[0]}"
    fi
    "$@"
}

# The EXIT trap, installed by main before it parses anything. In --json mode it
# sends {"event":"done","ok":false,...} when the run is ending without its done
# event, with the last error event's message, or a pointer to stderr when there
# was none. Human mode: nothing.
json_on_exit() {
    local rc=$?
    if json_mode && [[ "$JSON_DONE_EMITTED" != "true" ]]; then
        json_done "{\"event\":\"done\",\"ok\":false,\"msg\":\"$(json_escape "${JSON_LAST_ERROR:-setup exited early (rc=${rc}) -- see server logs / journalctl}")\"}" 2>/dev/null || true
    fi
    return "$rc"
}

json_set_network() {
    case "${1:-testnet}" in
        testnet|adiri)
            NETWORK="testnet"; CHAIN_ID="$TESTNET_CHAIN_ID"; CHAIN_NAME="$TESTNET_CHAIN_NAME"
            RPC_URL="${TESTNET_RPC_URL:-}"; EXPLORER_URL="${TESTNET_EXPLORER:-}" ;;
        devnet)
            NETWORK="devnet"; CHAIN_ID="$DEVNET_CHAIN_ID"; CHAIN_NAME="$DEVNET_CHAIN_NAME"
            RPC_URL="${DEVNET_RPC_URL:-}"; EXPLORER_URL="${DEVNET_EXPLORER:-}" ;;
        *) setup_fail "unsupported network: ${1} (expected testnet or devnet)" ;;
    esac
}

json_phase_keygen() {
    json_event step "Running preflight checks and installing dependencies"
    step_preflight
    json_event step "Applying node configuration"
    step_config
    json_event step "Creating system infrastructure"
    step_create_infrastructure
    json_event step "Generating node keys"
    step_generate_keys

    local info="${DATA_DIR}/node-info.yaml" info_content=""
    [[ -f "$info" ]] && info_content="$(json_escape "$(cat "$info")")"
    json_done "{\"event\":\"done\",\"ok\":true,\"phase\":\"keygen\",\"node_type\":\"observer\",\"node_info_path\":\"$(json_escape "$info")\",\"keys_dir\":\"$(json_escape "${DATA_DIR}/node-keys")\",\"node_info\":\"${info_content}\",\"msg\":\"keys generated -- BACK THEM UP before finalizing\"}"
}

# Finalize is a new process. The install method and the docker image or binary come from
# its flags or, for any the flags leave out, from what keygen recorded in .node-meta.
# Stops when the node would have nothing to run, before anything is written.
finalize_install_inputs() {
    local meta="${CONFIG_DIR}/.node-meta"
    if [[ -z "$INSTALL_METHOD" ]]; then
        INSTALL_METHOD="$(meta_get INSTALL_METHOD "$meta" 2>/dev/null || true)"
    fi
    # Values read back from .node-meta get the checks the flags got: the image and the
    # binary path go into the root-run start wrapper.
    case "$INSTALL_METHOD" in
        ""|source|docker|existing) ;;
        *) setup_fail "INSTALL_METHOD=${INSTALL_METHOD} in ${meta} is not source, docker or existing." ;;
    esac
    if [[ "$INSTALL_METHOD" == "docker" ]]; then
        if [[ -z "$DOCKER_IMAGE" ]]; then
            DOCKER_IMAGE="$(meta_get DOCKER_IMAGE "$meta" 2>/dev/null || true)"
        fi
        if [[ -z "$DOCKER_IMAGE" ]]; then
            setup_fail "No docker image to run: pass --docker-image, or run --phase=keygen first (it records the image in ${meta})."
        fi
        if ! validate_docker_image "$DOCKER_IMAGE"; then
            setup_fail "DOCKER_IMAGE=${DOCKER_IMAGE} in ${meta} is not an image reference such as ${DEFAULT_DOCKER_IMAGE}; pass --docker-image."
        fi
        return 0
    fi
    if [[ -z "$BINARY_PATH" ]]; then
        BINARY_PATH="$(meta_get BINARY_PATH "$meta" 2>/dev/null || true)"
    fi
    if [[ -n "$BINARY_PATH" ]] && ! validate_setup_path "$BINARY_PATH"; then
        setup_fail "BINARY_PATH=${BINARY_PATH} in ${meta} may hold only letters, digits and . _ / -, because the start wrapper runs it; pass --binary-path."
    fi
    if [[ "$INSTALL_METHOD" == "existing" ]]; then
        if [[ -z "$BINARY_PATH" ]]; then
            setup_fail "No node binary to run: pass --binary-path PATH, or run --phase=keygen first (it records the binary in ${meta})."
        fi
        check_binary_path
    fi
    return 0
}

json_phase_finalize() {
    finalize_install_inputs
    finalize_node_extra_flags
    json_event step "Writing configuration"
    step_write_config
    json_event step "Creating service and starting node"
    step_create_service
    if [[ -n "$PUBLIC_RPC_DOMAIN" ]]; then
        json_event step "Enabling public RPC for ${PUBLIC_RPC_DOMAIN}"
        step_public_rpc
    fi
    json_done "{\"event\":\"done\",\"ok\":true,\"phase\":\"finalize\",\"node_type\":\"observer\",\"service\":\"${SERVICE_NAME}\",\"rpc_port\":\"${RPC_PORT}\",\"operator_guide\":\"$(json_escape "$TN_OPERATOR_GUIDE_URL")\",\"public_rpc\":$(public_rpc_json),\"msg\":\"${SERVICE_NAME} finalized and started -- following consensus as a full node; staking to validate is optional (see docs)\"}"
}

# The public RPC this run set up, as finalize's done event carries it: "enabled" is
# true only when step_public_rpc finished the enable (Caddy serves the domain and
# node-info.yaml advertises it); domain, http and ws are the configured values
# (.node-meta PUBLIC_RPC_DOMAIN, PUBLIC_RPC_URL, PUBLIC_WS_URL), null when unset.
public_rpc_json() {
    local enabled=false
    if [[ "$PUBLIC_RPC_STATE" == "enabled" ]]; then
        enabled=true
    fi
    printf '{"enabled":%s,"domain":%s,"http":%s,"ws":%s}' "$enabled" \
        "$(json_str_or_null "$PUBLIC_RPC_DOMAIN")" \
        "$(json_str_or_null "$PUBLIC_RPC_URL")" \
        "$(json_str_or_null "$PUBLIC_WS_URL")"
}

# The install inputs, checked before check_root so a bad one stops the run before it
# touches the box: the install method (keygen needs one; finalize can read keygen's
# back from .node-meta), --build-ref (keygen of a source install needs one) and
# --docker-image, both held to the network's oldest supported release.
json_check_install_flags() {
    case "$INSTALL_METHOD" in
        ""|source|docker|existing) ;;
        *) setup_fail "unknown --install-method ${INSTALL_METHOD} (expected source, docker or existing)" ;;
    esac
    if [[ "$JSON_PHASE" == "keygen" && -z "$INSTALL_METHOD" ]]; then
        setup_fail "--install-method is missing (expected source, docker or existing)"
    fi
    if [[ "$INSTALL_METHOD" == "source" && "$JSON_PHASE" == "keygen" && -z "$JSON_BUILD_REF" ]]; then
        setup_fail "No --build-ref supplied for source build."
    fi
    if [[ -n "$JSON_BUILD_REF" ]]; then
        check_release_floor "$JSON_BUILD_REF"
    fi
    if [[ -n "$DOCKER_IMAGE" ]]; then
        if ! validate_docker_image "$DOCKER_IMAGE"; then
            setup_fail "invalid --docker-image ${DOCKER_IMAGE} -- give the full image reference with its tag, such as ${DEFAULT_DOCKER_IMAGE}"
        fi
        check_release_floor "$DOCKER_IMAGE"
    fi
    return 0
}

# check_root for a --json run, which must say why it stops: check_root exits 1 with
# only an [ERROR] line on stderr, which would leave the UI a bare "setup exited early".
# So ask it in a subshell first, and when it says no (exit 1), send the reason as an
# error event before the done, as edit-config's edit_require_root does. Then the real
# check_root.
json_require_root() {
    local rc=0
    (check_root) >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -eq 1 ]]; then
        setup_fail "setup-node.sh must run as root"
    fi
    check_root
}

# What a keygen needs and would otherwise find missing only in step_generate_keys, after
# the preflight (for a source install, a 20-40 minute build): the execution address, the
# four multiaddrs and the BLS passphrase, which arrives in TN_BLS_PASSPHRASE only. Their
# form is checked in init_node_inputs; step_generate_keys keeps its own checks as a safety
# net. Finalize needs none of them.
json_check_keygen_inputs() {
    local pair flag var
    [[ "$JSON_PHASE" == "keygen" ]] || return 0
    if [[ -z "$VALIDATOR_ADDRESS" ]]; then
        setup_fail "--address is missing: keygen needs the node's execution address (0x followed by 40 hex digits)."
    fi
    for pair in --external-primary:PRIMARY_MULTIADDR --external-worker:WORKER_MULTIADDR \
                --listener-primary:PRIMARY_LISTENER_MULTIADDR --listener-worker:WORKER_LISTENER_MULTIADDR; do
        flag="${pair%%:*}"
        var="${pair#*:}"
        if [[ -z "${!var}" ]]; then
            setup_fail "${flag} is missing: keygen needs all four multiaddrs (--external-primary, --external-worker, --listener-primary, --listener-worker)."
        fi
    done
    if [[ -z "${TN_BLS_PASSPHRASE:-}" ]]; then
        setup_fail "TN_BLS_PASSPHRASE is not set: keygen takes the BLS key passphrase from that environment variable only."
    fi
    return 0
}

# Every input is checked before check_root, so a bad phase, network or release ref, or
# a keygen input left out, stops the run before it touches the box.
run_json_mode() {
    case "$JSON_PHASE" in
        keygen|finalize) ;;
        *) setup_fail "unknown or missing --phase (expected keygen|finalize)" ;;
    esac
    json_set_network "$JSON_NETWORK_INPUT"
    json_check_install_flags
    json_check_keygen_inputs
    json_require_root
    export TN_ASSUME_YES=true   # non-interactive: auto-accept confirms (no stdin)
    case "$JSON_PHASE" in
        keygen)   json_phase_keygen ;;
        finalize) json_phase_finalize ;;
    esac
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local arg
    # --json is found before anything prints: from here on stdout carries JSON
    # events only, and json_on_exit ends the run with a done event when nothing
    # else did (a missing value, a bad flag, not root, a failed step).
    for arg in "$@"; do
        if [[ "$arg" == "--json" ]]; then
            JSON_MODE=true
        fi
    done
    if json_mode; then
        json_setup_fds
    fi
    trap json_on_exit EXIT

    while [[ $# -gt 0 ]]; do
        # Every option below that ends in `shift 2` needs a value. As the last argument it
        # has none and `shift 2` fails (a silent exit under the inherited `set -e`), so
        # stop here with a clear message instead. No value of these starts with "-", so
        # such a word is the next option, not a value. (--rpc-public may stand alone.)
        case "$1" in
            --phase|--network|--install-method|--passphrase-method|--address|--build-ref|\
            --docker-image|--binary-path|--external-primary|--external-worker|\
            --listener-primary|--listener-worker|--public-ip|--public-rpc-url|\
            --public-ws-url|--rpc-http|--rpc-ws|--rpc-domain|--advertised-name|--data-dir|\
            --service-user|--service-group|--genesis-dir)
                if [[ $# -lt 2 || "$2" == -* ]]; then
                    setup_fail "$1 requires a value"
                fi
                ;;
            # An empty value is a mistake here too, not a way of saying "none".
            --bootstrap-peers|--state-export-keep)
                if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                    setup_fail "$1 requires a value"
                fi
                ;;
        esac
        case "$1" in
            --json)                shift ;;   # found by the scan above
            --phase)               JSON_PHASE="${2:-}"; shift 2 ;;
            --phase=*)             JSON_PHASE="${1#*=}"; shift ;;
            --network)             JSON_NETWORK_INPUT="${2:-}"; shift 2 ;;
            --install-method)      INSTALL_METHOD="${2:-}"; shift 2 ;;
            --passphrase-method)   PASSPHRASE_METHOD="${2:-}"; shift 2 ;;
            --address)             VALIDATOR_ADDRESS="${2:-}"; shift 2 ;;
            --build-ref)           JSON_BUILD_REF="${2:-}"; shift 2 ;;
            --docker-image)        DOCKER_IMAGE="${2:-}"; shift 2 ;;
            # The node binary for --install-method existing: an absolute path to an
            # executable file. Skips the search and the prompt in _preflight_existing.
            --binary-path)         BINARY_PATH="${2:-}"; shift 2 ;;
            --external-primary)    PRIMARY_MULTIADDR="${2:-}"; shift 2 ;;
            --external-worker)     WORKER_MULTIADDR="${2:-}"; shift 2 ;;
            --listener-primary)    PRIMARY_LISTENER_MULTIADDR="${2:-}"; shift 2 ;;
            --listener-worker)     WORKER_LISTENER_MULTIADDR="${2:-}"; shift 2 ;;
            # Public IP: the P2P multiaddr IP in --json mode (as before) and, for public RPC,
            # the inbound IP the A record points at (passed to install-caddy.sh --public-ip).
            --public-ip)           PUBLIC_IP="${2:-}"; RPC_INBOUND_IP="${2:-}"; shift 2 ;;
            # Public RPC via Caddy (see the header). --rpc-public keeps the value form that Node
            # Manager UI releases before 1.9.0 send (`--rpc-public true|false`, any case); a
            # bare --rpc-public means true. Only true asks for public RPC, which needs
            # --rpc-domain (without one: a warning, RPC stays private) -- false is a no-op,
            # exactly as before.
            --rpc-public)
                case "$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')" in
                    true|yes|1)  RPC_PUBLIC_REQUESTED=true; shift 2 ;;
                    false|no|0)  shift 2 ;;
                    *)           RPC_PUBLIC_REQUESTED=true; shift ;;
                esac ;;
            --public-rpc-url)      PUBLIC_RPC_URL="${2:-}"; shift 2 ;;
            --public-ws-url)       PUBLIC_WS_URL="${2:-}"; shift 2 ;;
            --rpc-http)            ADVERTISE_RPC_HTTP="${2:-}"; shift 2 ;;
            --rpc-ws)              ADVERTISE_RPC_WS="${2:-}"; shift 2 ;;
            --rpc-domain)          PUBLIC_RPC_DOMAIN="$(normalize_rpc_domain "${2:-}")"; RPC_DOMAIN_GIVEN=true; shift 2 ;;
            --rpc-domain=*)        PUBLIC_RPC_DOMAIN="$(normalize_rpc_domain "${1#*=}")"; RPC_DOMAIN_GIVEN=true; shift ;;
            --no-public-rpc)       NO_PUBLIC_RPC=true; shift ;;
            --advertised-name)     ADVERTISED_NAME="${2:-}"; shift 2 ;;
            --data-dir)            DATA_DIR="${2:-$DATA_DIR}"; shift 2 ;;
            --service-user)        SERVICE_USER="${2:-}"; shift 2 ;;
            --service-group)       SERVICE_GROUP="${2:-}"; shift 2 ;;
            --genesis-dir)         TN_GENESIS_DIR="${2:-}"; shift 2 ;;
            # Opt in to the healthcheck TCP listener (bakes --healthcheck into the launch
            # command via tn_node_launch_flags). Overrides the ENABLE_HEALTHCHECK_MONITOR
            # default; needed in --json/finalize where prompt_testnet_addons is skipped.
            --enable-healthcheck-monitor) ENABLE_HEALTHCHECK_MONITOR=true; shift ;;
            # Optional node flags, checked by init_node_extra_flags (NODE FLAGS in the header).
            --bootstrap-peers)     BOOTSTRAP_PEERS_SRC="${2:-}"; shift 2 ;;
            --enable-state-export) STATE_EXPORT_ENABLE=true; shift ;;
            --state-export-keep)   STATE_EXPORT_KEEP="${2:-}"; shift 2 ;;
            -h|--help)
                # The header block only: everything up to its closing rule.
                awk 'NR == 1 { next } /^# =+$/ { if (++rules == 2) exit; next } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
                if json_mode; then
                    json_done '{"event":"done","ok":true,"msg":"usage printed on stderr"}'
                fi
                exit 0
                ;;
            # Ignored, with a warning on stderr (so a --json stdout stays pure JSON).
            *) print_warn "Unknown argument: $1" >&2; shift ;;
        esac
    done

    init_public_rpc_flags       # bad public-RPC flags or URLs stop here, before any work
    init_install_flags
    init_node_inputs
    init_node_extra_flags

    if json_mode; then
        run_json_mode
        exit $?
    fi

    step_welcome
    step_preflight
    step_config
    step_create_infrastructure
    step_generate_keys
    step_write_config
    step_create_service
    step_public_rpc
    step_testnet_addons
    step_final_summary
}

main "$@"
