# shellcheck shell=bash
# =============================================================================
# terraform/first-boot/first-boot-lib.sh -- shared by first-boot-validator.sh
# and first-boot-gateway.sh, the scripts cloud-init runs once, as root, on a
# host the Terraform roots under terraform/ create
#
# The role scripts source this file from their own directory
# (/usr/local/libexec/telcoin-first-boot on the host). It reads
# /etc/telcoin-first-boot/first-boot.env and checks every value before anything
# on the host changes; logs each step to /var/log/telcoin-first-boot.log, to
# standard output (cloud-init's output log) and to the journal (logger -t
# telcoin-first-boot); and ends every run with one marker in
# /var/lib/telcoin-first-boot, done or failed (with the step and the reason),
# and one console line:
#   TELCOIN-FIRST-BOOT <role>: ok
#   TELCOIN-FIRST-BOOT <role>: FAILED at <step>
# Every step can run again: a run after a fix starts at the top and repeats
# nothing destructive.
#
# The env file holds KEY='value' lines. It is parsed, never sourced: a line of
# another form, a value with a character outside letters, digits and . _ : / ,
# @ -, or a key given twice is refused. Nothing in it is secret, and nothing
# these scripts read, write or log is.
#
# Test hooks (the fixture tests set them; cloud-init does not):
#   TN_FB_ROOT            prefix of every absolute path the scripts touch
#                         (default empty). With it set, a regular file stands in
#                         for the data device.
#   TN_FB_WAIT_STEP       seconds every wait or retry sleeps instead of its own
#                         interval; the number of tries stays the same, except
#                         in the DNS wait, which ends on the clock
#   TN_FB_DEVICE_TIMEOUT  seconds to wait for the data device (default 600)
#   TN_FB_DNS_TIMEOUT     seconds to wait for the gateway's name (default 1800)
# Each of the last three is a whole number of seconds; anything else is refused
# before any change.
#
# terraform/ is not shipped to node hosts: update-scripts.sh does not track
# these files and they have no .sha256 sidecar. bash 3.2 safe.
# =============================================================================

FB_ROOT="${TN_FB_ROOT:-}"
FB_ROOT="${FB_ROOT%/}"
readonly FB_LIBEXEC=/usr/local/libexec/telcoin-first-boot
readonly FB_ENV_PATH=/etc/telcoin-first-boot/first-boot.env
readonly FB_LOG_PATH=/var/log/telcoin-first-boot.log
readonly FB_ENV="${FB_ROOT}${FB_ENV_PATH}"
readonly FB_LOG="${FB_ROOT}${FB_LOG_PATH}"
readonly FB_STATE="${FB_ROOT}/var/lib/telcoin-first-boot"
readonly FB_CONSOLE="${FB_ROOT}/dev/console"

FB_ROLE=""          # validator or gateway (fb_init)
FB_STEP="start"     # the step running now, named in the failed marker
FB_FINISHED=0       # 1 once fb_done or fb_fail has written the result
FB_SCRIPTS_DIR=""   # the node scripts the installer puts in the login user's home

# The env file's keys: the contract with terraform/modules/host-plan, which
# renders the file. Assigned here so nothing from the caller's environment
# stands in for a key the file leaves out.
TN_FB_ROLE=""
TN_FB_NETWORK=""
TN_FB_CLOUD=""
TN_FB_LOGIN_USER=""
TN_FB_INSTALLER_URL=""
TN_FB_MIN_RELEASE=""
TN_FB_DATA_DEVICE=""
TN_FB_TRUSTED_NODES=""
TN_FB_UPSTREAM=""
TN_FB_DOMAIN=""
TN_FB_PUBLIC_IP=""
TN_FB_REDIRECT_QUERIES=""
TN_FB_RATE_LIMIT_SUBMISSIONS=""
TN_FB_SSH_FROM=""
readonly FB_KEYS="TN_FB_ROLE TN_FB_NETWORK TN_FB_CLOUD TN_FB_LOGIN_USER TN_FB_INSTALLER_URL TN_FB_MIN_RELEASE TN_FB_DATA_DEVICE TN_FB_TRUSTED_NODES TN_FB_UPSTREAM TN_FB_DOMAIN TN_FB_PUBLIC_IP TN_FB_REDIRECT_QUERIES TN_FB_RATE_LIMIT_SUBMISSIONS TN_FB_SSH_FROM"

# -----------------------------------------------------------------------------
# Logging, markers, the end of a run
# -----------------------------------------------------------------------------

fb_ts() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# fb_log MSG -- one line to standard output, the log file and the journal. A log
# that cannot be written never stops the run.
fb_log() {
    printf '%s %s\n' "$(fb_ts)" "$1" | tee -a "$FB_LOG" || true
    if command -v logger >/dev/null 2>&1; then
        logger -t telcoin-first-boot -- "$1" 2>/dev/null || true
    fi
}

# fb_console LINE -- fb_log, and LINE on the console as well: cloud-init sends
# its output there on most images, but not on all, and the console is what the
# serial log of every cloud shows.
fb_console() {
    fb_log "$1"
    if [ -c "$FB_CONSOLE" ] || { [ -n "$FB_ROOT" ] && [ -f "$FB_CONSOLE" ]; }; then
        printf '%s\n' "$1" >> "$FB_CONSOLE" 2>/dev/null || true
    fi
}

# fb_marker done|failed [REASON] -- replace the result marker.
fb_marker() {
    mkdir -p "$FB_STATE" 2>/dev/null || true
    rm -f "${FB_STATE}/done" "${FB_STATE}/failed" 2>/dev/null || true
    {
        printf 'role=%s\n' "$FB_ROLE"
        if [ "$1" = failed ]; then
            printf 'step=%s\n' "$FB_STEP"
            printf 'reason=%s\n' "${2:-}"
        fi
        printf 'time=%s\n' "$(fb_ts)"
    } > "${FB_STATE}/$1" 2>/dev/null || true
}

# fb_fail MSG [nochange] -- end the run at the current step: the reason, the
# command that runs it again, the failed marker and the console line. Exit 1.
fb_fail() {
    local msg="$1"
    FB_FINISHED=1
    trap - EXIT
    [ "${2:-}" != nochange ] || msg="${msg} Nothing was changed."
    fb_log "First boot stopped at step ${FB_STEP}: ${msg}"
    fb_log "After the fix, run it again: sudo bash ${FB_LIBEXEC}/first-boot-${FB_ROLE}.sh"
    fb_marker failed "$1"
    fb_console "TELCOIN-FIRST-BOOT ${FB_ROLE}: FAILED at ${FB_STEP}"
    exit 1
}

# fb_done MSG -- end a run that went through. Exit 0.
fb_done() {
    FB_FINISHED=1
    trap - EXIT
    fb_log "$1"
    fb_marker "done"
    fb_console "TELCOIN-FIRST-BOOT ${FB_ROLE}: ok"
    exit 0
}

# fb_on_exit -- the EXIT trap: a run that ends any other way (set -e, a signal)
# still leaves the failed marker and the console line.
fb_on_exit() {
    local rc=$?
    [ "$FB_FINISHED" = 1 ] && return 0
    fb_fail "The script ended unexpectedly (exit ${rc}); the lines above in ${FB_LOG_PATH} show where."
}

# fb_step NAME WHAT -- start a step.
fb_step() {
    FB_STEP="$1"
    fb_log "== ${1}: ${2}"
}

# fb_sleep SECONDS -- a wait or retry interval (TN_FB_WAIT_STEP shortens it).
fb_sleep() {
    sleep "${TN_FB_WAIT_STEP:-$1}"
}

# fb_try TRIES DELAY CMD... -- run CMD up to TRIES times, DELAY seconds apart,
# its output to standard output and the log. rc 0 once it succeeds, 1 after the
# last failure.
fb_try() {
    local tries="$1" delay="$2" n=1
    shift 2
    while :; do
        if "$@" 2>&1 | tee -a "$FB_LOG"; then
            return 0
        fi
        [ "$n" -lt "$tries" ] || return 1
        fb_log "Attempt ${n} of ${tries} failed; trying again in ${delay} s."
        fb_sleep "$delay"
        n=$((n + 1))
    done
}

# -----------------------------------------------------------------------------
# The env file
# -----------------------------------------------------------------------------

# fb_env_bad KEY WHY -- refuse the env file over one key.
fb_env_bad() {
    local v="${!1-}"
    fb_fail "${1} in ${FB_ENV_PATH} ${2} (it is '${v}')." nochange
}

# fb_ipv4_ok V -- V is a dotted-quad IPv4 address without leading zeros.
fb_ipv4_ok() {
    local re='^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$' i
    [[ "$1" =~ $re ]] || return 1
    for i in 1 2 3 4; do
        [ "${BASH_REMATCH[$i]}" -le 255 ] || return 1
    done
    return 0
}

# fb_url_ok SCHEMES V -- V is SCHEMES://host[:port][/path] (SCHEMES an ERE such
# as https?) as setup-gateway.sh takes --redirect-queries: labels joined by
# single dots, a port 1-65535.
fb_url_ok() {
    local l='[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?' re hp
    re="^${1}://${l}(\\.${l})*(:[1-9][0-9]{0,4})?(/[A-Za-z0-9._/-]*)?\$"
    [[ "$2" =~ $re ]] || return 1
    hp="${2#*://}"
    hp="${hp%%/*}"
    case "$hp" in *:*) [ "${hp##*:}" -le 65535 ] ;; esac
}

# fb_release_num V -- V, a node scripts release scripts-vMAJOR.MINOR.PATCH, as
# one number that orders releases; rc 1 for any other form.
fb_release_num() {
    local re='^scripts-v(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})$'
    [[ "$1" =~ $re ]] || return 1
    printf '%s' $(( BASH_REMATCH[1] * 100000000 + BASH_REMATCH[2] * 10000 + BASH_REMATCH[3] ))
}

# fb_abs_path_ok V -- V is an absolute path that never climbs (no ..).
fb_abs_path_ok() {
    case "$1" in
        /*) ;;
        *) return 1 ;;
    esac
    case "$1" in
        *..*) return 1 ;;
    esac
    return 0
}

# fb_load_env -- read the env file into the TN_FB_* keys.
fb_load_env() {
    local line key val n=0 seen=" " q="'" re
    re="^(TN_FB_[A-Z0-9_]+)=${q}([A-Za-z0-9._:/,@-]*)${q}\$"
    if [ ! -f "$FB_ENV" ] || [ ! -r "$FB_ENV" ]; then
        fb_fail "${FB_ENV_PATH} is missing or unreadable; cloud-init writes it from the instance's user data." nochange
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        case "$line" in
            ''|'#'*) continue ;;
        esac
        if ! [[ "$line" =~ $re ]]; then
            fb_fail "Line ${n} of ${FB_ENV_PATH} is not a KEY='value' line whose value holds only letters, digits and . _ : / , @ -." nochange
        fi
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        case " ${FB_KEYS} " in
            *" ${key} "*) ;;
            *) fb_log "Line ${n} of ${FB_ENV_PATH}: ${key} is not a key of this script; it is ignored."
               continue ;;
        esac
        case "$seen" in
            *" ${key} "*) fb_fail "${key} is set more than once in ${FB_ENV_PATH}." nochange ;;
        esac
        seen="${seen}${key} "
        printf -v "$key" '%s' "$val"
    done < "$FB_ENV"
}

# fb_validate_env -- every key this role needs, checked again on the host.
fb_validate_env() {
    local re s
    [ "$TN_FB_ROLE" = "$FB_ROLE" ] || fb_env_bad TN_FB_ROLE "must be ${FB_ROLE} for first-boot-${FB_ROLE}.sh"
    case "$TN_FB_NETWORK" in
        testnet|mainnet) ;;
        *) fb_env_bad TN_FB_NETWORK "must be testnet or mainnet" ;;
    esac
    case "$TN_FB_CLOUD" in
        aws|gcp|azure) ;;
        *) fb_env_bad TN_FB_CLOUD "must be aws, gcp or azure" ;;
    esac
    re='^[a-z_][a-z0-9_-]{0,31}$'
    [[ "$TN_FB_LOGIN_USER" =~ $re ]] || fb_env_bad TN_FB_LOGIN_USER "must be a login name"
    fb_url_ok https "$TN_FB_INSTALLER_URL" || fb_env_bad TN_FB_INSTALLER_URL "must be an https URL"
    fb_release_num "$TN_FB_MIN_RELEASE" >/dev/null \
        || fb_env_bad TN_FB_MIN_RELEASE "must be a node scripts release, scripts-vMAJOR.MINOR.PATCH"
    case "$FB_ROLE" in
        validator)
            case "$TN_FB_DATA_DEVICE" in
                /dev/?*) fb_abs_path_ok "$TN_FB_DATA_DEVICE" || fb_env_bad TN_FB_DATA_DEVICE "must be a device path under /dev" ;;
                *) fb_env_bad TN_FB_DATA_DEVICE "must be a device path under /dev" ;;
            esac
            if [ -n "$TN_FB_TRUSTED_NODES" ]; then
                fb_abs_path_ok "$TN_FB_TRUSTED_NODES" || fb_env_bad TN_FB_TRUSTED_NODES "must be empty or an absolute path"
            fi
            ;;
        gateway)
            # As setup-gateway.sh and firewall-setup.sh check them (fbg_* are in
            # first-boot-gateway.sh).
            fbg_upstream_ok "$TN_FB_UPSTREAM" \
                || fb_env_bad TN_FB_UPSTREAM "must be the validator's private IPv4 address (10/8, 172.16/12, 192.168/16, 100.64/10 or 169.254/16)"
            re='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
            if ! [[ "$TN_FB_DOMAIN" =~ $re ]] || [ "${#TN_FB_DOMAIN}" -gt 253 ]; then
                fb_env_bad TN_FB_DOMAIN "must be a DNS name"
            fi
            fb_ipv4_ok "$TN_FB_PUBLIC_IP" || fb_env_bad TN_FB_PUBLIC_IP "must be the gateway's public IPv4 address"
            fb_url_ok 'https?' "$TN_FB_REDIRECT_QUERIES" \
                || fb_env_bad TN_FB_REDIRECT_QUERIES "must be http(s)://host[:port][/path], with a port 1-65535"
            if fbg_redirect_loops "$TN_FB_REDIRECT_QUERIES" "$TN_FB_UPSTREAM"; then
                fb_env_bad TN_FB_REDIRECT_QUERIES "points at the validator's own RPC or readiness port, or at this host's gateway, and setup-gateway.sh refuses that: give a node that answers queries"
            fi
            re='^(0|[1-9][0-9]{0,5})$'
            [[ "$TN_FB_RATE_LIMIT_SUBMISSIONS" =~ $re ]] || fb_env_bad TN_FB_RATE_LIMIT_SUBMISSIONS "must be a whole number"
            s="must be a comma list of addresses or CIDRs of /8 or narrower, none of them 0.0.0.0 or ::"
            case ",${TN_FB_SSH_FROM}," in
                ,,|*,,*) fb_env_bad TN_FB_SSH_FROM "$s" ;;
            esac
            for re in $(printf '%s' "$TN_FB_SSH_FROM" | tr ',' ' '); do
                fbg_src_ok "$re" || fb_env_bad TN_FB_SSH_FROM "$s"
            done
            ;;
    esac
    FB_SCRIPTS_DIR="${FB_ROOT}/home/${TN_FB_LOGIN_USER}/telcoin-node-scripts"
}

# fb_check_hooks -- the test hooks are whole numbers when set.
fb_check_hooks() {
    local h v re='^[0-9]{1,6}$'
    for h in TN_FB_WAIT_STEP TN_FB_DEVICE_TIMEOUT TN_FB_DNS_TIMEOUT; do
        v="${!h-}"
        if [ -n "$v" ] && ! [[ "$v" =~ $re ]]; then
            fb_fail "${h} must be a whole number of seconds (it is '${v}')." nochange
        fi
    done
}

# fb_init ROLE -- the start of every run: traps, the state directory, the hooks
# and the env file. Nothing on the host changes before it returns.
fb_init() {
    FB_ROLE="$1"
    case "$FB_ROOT" in
        ''|/*) ;;
        *) printf 'first-boot-%s.sh: TN_FB_ROOT must be an absolute path. Nothing was changed.\n' "$FB_ROLE" >&2
           exit 1 ;;
    esac
    if ! mkdir -p "${FB_LOG%/*}" "$FB_STATE" || ! chmod 0700 "$FB_STATE"; then
        printf 'first-boot-%s.sh: could not create %s or %s. Nothing was changed.\n' "$FB_ROLE" "${FB_LOG_PATH%/*}" "${FB_STATE#"$FB_ROOT"}" >&2
        exit 1
    fi
    trap fb_on_exit EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    trap 'exit 129' HUP
    rm -f "${FB_STATE}/done" "${FB_STATE}/failed"
    fb_step env "check ${FB_ENV_PATH} (first boot of the ${FB_ROLE} host)"
    fb_check_hooks
    fb_load_env
    fb_validate_env
}

# -----------------------------------------------------------------------------
# Steps both roles run
# -----------------------------------------------------------------------------

# fb_apt_lock_timeout -- unattended-upgrades runs at first boot too, and the
# node scripts' apt calls set no lock timeout of their own.
fb_apt_lock_timeout() {
    local f="${FB_ROOT}/etc/apt/apt.conf.d/50telcoin-first-boot"
    fb_step apt-lock "apt waits up to 15 minutes for the dpkg lock"
    if ! { mkdir -p "${f%/*}" && printf 'DPkg::Lock::Timeout "900";\n' > "$f" && chmod 0644 "$f"; }; then
        fb_fail "Could not write ${f#"$FB_ROOT"}."
    fi
}

# fb_cve_2026_31431 -- CVE-2026-31431 (Copy Fail). setup-node.sh stops unless a
# file under /etc/modprobe.d holds this exact line and algif_aead is not loaded
# (check_cve_2026_31431 in lib/common.sh). Nothing loads the module on a fresh
# boot; if something did, unload it.
fb_cve_2026_31431() {
    local f="${FB_ROOT}/etc/modprobe.d/telcoin-algif-aead.conf"
    fb_step cve-2026-31431 "keep the algif_aead module from loading"
    if ! { mkdir -p "${f%/*}" && printf 'install algif_aead /bin/false\n' > "$f"; }; then
        fb_fail "Could not write ${f#"$FB_ROOT"}."
    fi
    if grep -q '^algif_aead ' "${FB_ROOT}/proc/modules" 2>/dev/null; then
        modprobe -r algif_aead || fb_fail "algif_aead is loaded and could not be unloaded."
    fi
}

# fb_swap_off -- swap off, as the node's hardware requirements ask. The cloud
# images ship no swap.
fb_swap_off() {
    fb_step swap "swap off"
    swapoff -a || fb_fail "swapoff -a failed."
    if [ -n "$(swapon --show --noheadings)" ]; then
        fb_fail "Swap is still on after swapoff -a."
    fi
}

# fb_install_node_scripts FILE... -- the signed release the published installer
# names, installed as the login user the way the runbook installs it; then each
# FILE must be in the install, and the release must be TN_FB_MIN_RELEASE or
# newer. pipefail turns a failed download into a failed attempt.
fb_install_node_scripts() {
    local f
    fb_step node-scripts "the node scripts from ${TN_FB_INSTALLER_URL}, installed as ${TN_FB_LOGIN_USER}"
    id -u "$TN_FB_LOGIN_USER" >/dev/null 2>&1 \
        || fb_fail "The login user ${TN_FB_LOGIN_USER} does not exist on this host; TN_FB_LOGIN_USER in ${FB_ENV_PATH} must name the image's login user."
    # shellcheck disable=SC2016  # $1 is the URL, expanded by the login user's bash
    fb_try 3 30 sudo -u "$TN_FB_LOGIN_USER" -H bash -c \
        'set -o pipefail; curl --proto "=https" --tlsv1.2 -fsSL --url "$1" | bash -s -- --yes' \
        first-boot-installer "$TN_FB_INSTALLER_URL" \
        || fb_fail "The node scripts installer failed three times."
    for f in "$@"; do
        [ -f "${FB_SCRIPTS_DIR}/${f}" ] || fb_fail "The installer left no ${FB_SCRIPTS_DIR#"$FB_ROOT"}/${f}."
    done
    fb_check_release
}

# fb_check_release -- later steps pass flags an older release does not know. The
# release is in the MANIFEST the installer verified and installed.
fb_check_release() {
    local m="${FB_SCRIPTS_DIR}/MANIFEST" rel have want got
    fb_step scripts-release "the node scripts are ${TN_FB_MIN_RELEASE} or newer"
    want="$(fb_release_num "$TN_FB_MIN_RELEASE")"
    rel="$(sed -n 's/^release=//p' "$m" 2>/dev/null)" || rel=""
    if have="$(fb_release_num "$rel")"; then
        if [ "$have" -ge "$want" ]; then
            fb_log "The node scripts are ${rel}."
            return 0
        fi
        got="The installer put the node scripts ${rel} on this host"
    else
        got="The node scripts the installer put on this host name no release (no release= line in ${m#"$FB_ROOT"})"
    fi
    fb_fail "${got}; this deployment needs ${TN_FB_MIN_RELEASE} or newer. Once ${TN_FB_INSTALLER_URL} serves ${TN_FB_MIN_RELEASE} or newer, run this script again: sudo bash ${FB_LIBEXEC}/first-boot-${FB_ROLE}.sh"
}
