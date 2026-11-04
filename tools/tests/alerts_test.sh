#!/usr/bin/env bash
# =============================================================================
# tools/tests/alerts_test.sh -- lib/alerts.sh, the private alerts library: the
# unit and timer texts line by line (and systemd-analyze verify where it runs),
# the target validation table, alerts_rpc_url's address mapping, alerts.env, the
# targets file written 0600 through a logged tn_write_root_file, the enable
# refusals, an enable that no target accepts rolled back to nothing, a target
# change put back byte for byte, the order of the disable steps, the status
# issue counts (a symlinked state file ignored), and no monitor token in any
# output.
#
#   bash tools/tests/alerts_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/alerts_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/alerts_test.sh
#
# systemctl and hostname are PATH stubs: `systemctl start telcoin-heartbeat.service`
# runs a stand-in runner that writes a state file per $T/scenario (ok, allfail,
# mixed, stale, nostate). tn_write_root_file is wrapped to log every write. As root
# (with a root-only temp dir under /root) the real root primitives write the files
# and their owners and modes are checked; elsewhere stand-ins write them and the
# owner and mode checks print SKIP.
# =============================================================================

set -u
umask 022

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T="$TN_TEST_TMP"

IS_ROOT=0
RB=""
if [[ "$(id -u)" == 0 && -d /root ]]; then
    RB="$(mktemp -d /root/.tn-alerts.XXXXXX 2>/dev/null)" || RB=""
fi
if [[ -n "$RB" ]]; then
    IS_ROOT=1
    RP="$RB/root"
else
    RP="$T/root"
fi
cleanup() {
    tn_test_cleanup
    if [[ -n "$RB" && -d "$RB" ]]; then rm -rf "$RB"; fi
}
trap cleanup EXIT

export TN_ROOT_PREFIX="$RP"
export TN_UPDATE_LOCK_FILE="$T/update.lock"
export ATEST_T="$T" ATEST_RP="$RP"
mkdir -p "$RP/etc/telcoin" "$RP/etc/systemd/system" "$RP/usr/local/libexec/telcoin" \
    "$RP/var/lib/private" "$T/bin"

# --- stubs ----------------------------------------------------------------------
cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ATEST_T/calls"
cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
    --version) printf 'systemd %s (stub)\n' "$(cat "$ATEST_T/sysver" 2>/dev/null || echo 255)"; exit 0 ;;
    start) [ "${1:-}" = telcoin-heartbeat.service ] && exec bash "$ATEST_T/stub-runner"; exit 0 ;;
    is-active) [ -f "$ATEST_T/timer-active" ]; exit $? ;;
    is-enabled) [ -f "$ATEST_T/timer-enabled" ]; exit $? ;;
    list-timers)
        [ -f "$ATEST_T/timer-active" ] && printf '%s\n' "Wed 2026-11-04 12:00:00 UTC 30s left Wed 2026-11-04 11:59:00 UTC 30s ago telcoin-heartbeat.timer telcoin-heartbeat.service"
        exit 0 ;;
    enable)
        [ -f "$ATEST_T/enable-fails" ] && exit 1
        : > "$ATEST_T/timer-enabled"
        for a in "$@"; do [ "$a" = --now ] && : > "$ATEST_T/timer-active"; done
        exit 0 ;;
    disable) rm -f "$ATEST_T/timer-active" "$ATEST_T/timer-enabled"; exit 0 ;;
    restart)
        [ -f "$ATEST_T/restart-fails" ] && exit 1
        : > "$ATEST_T/timer-active"; exit 0 ;;
    clean)
        [ -f "$ATEST_T/clean-fails" ] && exit 1
        rm -rf "$ATEST_RP/var/lib/private/telcoin-heartbeat"
        rm -f "$ATEST_RP/var/lib/telcoin-heartbeat"
        exit 0 ;;
    *) exit 0 ;;
esac
STUB
cat > "$T/bin/hostname" <<'STUB'
#!/usr/bin/env bash
cat "$ATEST_T/hostname" 2>/dev/null || echo testhost
STUB
# The stand-in runner: one push line per target of the targets file, per scenario.
cat > "$T/stub-runner" <<'STUB'
#!/usr/bin/env bash
sc="$(cat "$ATEST_T/scenario" 2>/dev/null || echo ok)"
d="$ATEST_RP/var/lib/private/telcoin-heartbeat"
tf="$ATEST_RP/etc/telcoin/alerts/targets"
cp "$tf" "$ATEST_T/runner-saw" 2>/dev/null || : > "$ATEST_T/runner-saw"
[ "$sc" = nostate ] && exit 2
mkdir -p "$d"
now="$(date +%s)"
[ "$sc" = stale ] && now=$((now - 1000))
out="version=2.1.0
last_run=${now}
mono=500
last_status=up
status_since=100
last_reason=CvvActive block 1234567 epoch 42
last_mode=CvvActive
last_block=1234567
last_epoch=42
last_header=10
header_since=400
inactive_since=
started=100
svc_since=50
svc_restarts=0
push_total=1
push_ok=1"
n=0
while read -r kind url; do
    [ -n "$kind" ] || continue
    n=$((n + 1))
    host="$(printf '%s' "$url" | sed -e 's#^[a-z]*://##' -e 's#[/?].*##' -e 's#.*@##')"
    case "$sc" in
        allfail) res="fail 000 timeout" ;;
        mixed) if [ "$n" -eq 1 ]; then res="fail 503 http"; else res="ok 200"; fi ;;
        *) res="ok 200" ;;
    esac
    out="${out}
push_${n}=${kind} ${res} ${host}"
done < "$tf"
printf '%s\n' "$out" > "$d/.state.tmp.$$" && mv -f "$d/.state.tmp.$$" "$d/state"
[ "$sc" = allfail ] && exit 1
exit 0
STUB
chmod 0755 "$T/bin/systemctl" "$T/bin/hostname" "$T/stub-runner"
export PATH="$T/bin:$PATH"

# --- the fixture node -------------------------------------------------------------
META="$RP/etc/telcoin/.node-meta"
START="$RP/usr/local/libexec/telcoin/tn-start"
base_meta() {
    printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nINSTALL_METHOD=binary\nDATA_DIR=/var/lib/telcoin\n' > "$META"
    chmod 0600 "$META"
}
# start_script FLAGS -- the node's launch file with FLAGS after the data dir.
start_script() {
    printf '#!/bin/bash\nset -euo pipefail\nexec /opt/telcoin/telcoin-network node --datadir /var/lib/telcoin %s\n' "$1" > "$START"
    chmod 0755 "$START"
}
FLAGS_STD="--http --http.addr 0.0.0.0 --http.port 8545 --healthcheck 127.0.0.1:43180"
base_meta
start_script "$FLAGS_STD"
printf '[Service]\nExecStart=/usr/local/libexec/telcoin/tn-start\n' > "$RP/etc/systemd/system/telcoin.service"

eval "$(tn_test_source_common)"

if ! declare -F alerts_enable >/dev/null 2>&1; then
    echo "lib/alerts.sh was not sourced by lib/common.sh" >&2
    exit 1
fi

# Stand-ins for the runner's helpers while lib/tn-heartbeat.sh is absent (the real
# pair runs in the verification round).
if ! declare -F hb_target_normalize >/dev/null 2>&1; then
    hb_url_host() {
        local u="${1#*://}"
        u="${u%%[/?#]*}"
        printf '%s\n' "${u##*@}"
    }
    # shellcheck disable=SC2034  # HB_ERR is read by lib/alerts.sh
    hb_target_normalize() {
        local kind="$1" url="$2" allow="${3:-0}" host re
        HB_ERR=""
        HB_URL=""
        case "$kind" in kuma|healthchecks|webhook) ;; *) HB_ERR="unknown provider '${kind}' (kuma, healthchecks or webhook)"; return 1 ;; esac
        [[ -n "$url" ]] || { HB_ERR="empty url"; return 1; }
        [[ ${#url} -le 512 ]] || { HB_ERR="url longer than 512 characters"; return 1; }
        if [[ "$url" == *[[:space:][:cntrl:]\"\\]* ]]; then HB_ERR="url holds a quote, backslash, space or control character"; return 1; fi
        host="$(hb_url_host "$url")"
        case "$url" in
            https://*) ;;
            http://*) case "${host%%:*}" in 127.0.0.1|localhost) ;; *) [[ "$allow" == 1 ]] || { HB_ERR="http needs --allow-http (the token travels in clear text)"; return 1; } ;; esac ;;
            *) HB_ERR="url must start with https://"; return 1 ;;
        esac
        case "$kind" in
            kuma)
                url="${url%%[?#]*}"
                while [[ "$url" == */ ]]; do url="${url%/}"; done
                re='/api/push/[A-Za-z0-9_-]{4,128}$'
                [[ "$url" =~ $re ]] || { HB_ERR="kuma: not an /api/push/<token> URL"; return 1; }
                ;;
            healthchecks)
                [[ "$url" != *[?#]* ]] || { HB_ERR="healthchecks: a query string or fragment is not allowed"; return 1; }
                url="${url%/}"; url="${url%/fail}"; url="${url%/start}"; url="${url%/log}"
                ;;
        esac
        HB_URL="$url"
        printf '%s\n' "$url"
    }
    hb_state_get() {
        local line
        [[ -f "$1" && ! -L "$1" ]] || return 1
        line="$(grep -m1 -E "^${2}=" "$1")" || return 1
        printf '%s\n' "${line#*=}"
    }
    skip "lib/tn-heartbeat.sh helpers" "the file is absent; stand-ins used"
fi

# --- root primitives: logged; real as root, stand-ins elsewhere ---------------------
: > "$T/writes"
eval "$(declare -f tn_write_root_file | sed '1s/^tn_write_root_file /_real_tn_write_root_file /')"
eval "$(declare -f tn_install_root_binary | sed '1s/^tn_install_root_binary /_real_tn_install_root_binary /')"
eval "$(declare -f _tn_root_layout_dir | sed '1s/^_tn_root_layout_dir /_real_tn_root_layout_dir /')"
eval "$(declare -f _tn_shred | sed '1s/^_tn_shred /_real_tn_shred /')"
tn_write_root_file() {
    printf '%s %s %s\n' "${1#"$RP"}" "${2:-}" "${3:-root}" >> "$T/writes"
    if [[ $IS_ROOT == 1 ]]; then
        _real_tn_write_root_file "$@"
        return
    fi
    local tmp
    tmp="$(mktemp "${1%/*}/.tn.XXXXXX")" || return 2
    if ! cat > "$tmp" || ! chmod "$2" "$tmp" || ! mv -f "$tmp" "$1"; then
        rm -f "$tmp"
        return 2
    fi
}
tn_install_root_binary() {
    printf 'install %s\n' "${2#"$RP"}" >> "$T/writes"
    if [[ $IS_ROOT == 1 ]]; then
        _real_tn_install_root_binary "$@"
        return
    fi
    cp "$1" "$2.new" && chmod 0755 "$2.new" && mv -f "$2.new" "$2"
}
_tn_root_layout_dir() {
    if [[ $IS_ROOT == 1 ]]; then
        _real_tn_root_layout_dir "$@"
        return
    fi
    mkdir -p "$1" && chmod "$3" "$1"
}
_tn_shred() { _real_tn_shred "$@"; }
MYIDS="$(id -u):$(id -g)"
if [[ $IS_ROOT != 1 ]]; then
    tn_root_dir_ok() { [[ -d "$1" && ! -L "$1" ]]; }
    _tn_root_file_ok() { [[ ! -L "$1" ]]; }
    _alerts_is_root() { return 0; }
    # The fixture files belong to this user: report them as root's.
    _alerts_owner_mode() {
        local om
        om="$(stat -c '%u:%g %a' -- "$1" 2>/dev/null)" || return 0
        printf '%s\n' "${om/#"$MYIDS" /0:0 }"
    }
fi

# --- helpers --------------------------------------------------------------------
# run CMD... -- run CMD in this shell; OUT (stdout and stderr) and RC. Every output
# is kept in $T/allout for the token check at the end.
run() {
    "$@" > "$T/out" 2>&1
    RC=$?
    OUT="$(cat "$T/out")"
    cat "$T/out" >> "$T/allout"
}
# has TEXT NEEDLE -- yes when NEEDLE occurs in TEXT (a function: bash 3.2 cannot
# parse a case pattern's ")" inside $( )).
has() {
    case "$1" in
        *"$2"*) echo yes ;;
        *) echo no ;;
    esac
}
exists() { if [[ -e "$1" || -L "$1" ]]; then echo yes; else echo no; fi; }
om() { stat -c '%u:%g %a' -- "$1" 2>/dev/null; }
meta_val() { grep -E "^${1}=" "$META" | sed 's/^[^=]*=//'; }
STATE_D="$RP/var/lib/private/telcoin-heartbeat"
STATE="$STATE_D/state"
ALERTS_D="$RP/etc/telcoin/alerts"
UNIT_F="$RP/etc/systemd/system/telcoin-heartbeat.service"
TIMER_F="$RP/etc/systemd/system/telcoin-heartbeat.timer"
RUNNER_F="$RP/usr/local/libexec/telcoin/tn-heartbeat"
# off -- a host with no alerts files, the base .node-meta, the standard launch file.
off() {
    rm -rf "$ALERTS_D" "$STATE_D" "$RP/var/lib/telcoin-heartbeat"
    rm -f "$UNIT_F" "$TIMER_F" "$RUNNER_F" "$T/timer-active" "$T/timer-enabled" "$T/enable-fails" \
        "$T/clean-fails" "$T/restart-fails" "$T/sysver"
    base_meta
    start_script "$FLAGS_STD"
    printf '[Service]\nExecStart=/usr/local/libexec/telcoin/tn-start\n' > "$RP/etc/systemd/system/telcoin.service"
    echo ok > "$T/scenario"
    : > "$T/calls"
    : > "$T/writes"
    # shellcheck disable=SC2034  # read by lib/alerts.sh
    ALERTS_LABEL_REQ="node-1"
}
no_alerts_files() {
    printf '%s %s %s %s %s\n' "$(exists "$ALERTS_D")" "$(exists "$UNIT_F")" "$(exists "$TIMER_F")" \
        "$(exists "$RUNNER_F")" "$(exists "$STATE_D")"
}

TOK1="AbCdEf0123456789kumaTok"
TOK2="SECRETwebhook42xyz"
TOK3="5f3c0f7a-9d1e-4c2b-SECRET-hc"
TOK4="ZyXwVu9876newKumaTok"
URL1="https://kuma.example.org/api/push/${TOK1}"
URL2="https://hooks.example.net/hook/${TOK2}"
URL3="https://hc-ping.com/${TOK3}"
URL4="https://kuma2.example.org/api/push/${TOK4}"
TARGETS2="kuma ${URL1}
webhook ${URL2}
"

# =============================================================================
# Unit texts (section 6)
# =============================================================================
EXP_UNIT="$(cat <<'EOF'
[Unit]
Description=Telcoin node heartbeat (private alerts)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/telcoin/tn-heartbeat
DynamicUser=yes
EnvironmentFile=/etc/telcoin/alerts/alerts.env
LoadCredential=targets:/etc/telcoin/alerts/targets
UnsetEnvironment=TN_BLS_PASSPHRASE
StateDirectory=telcoin-heartbeat
StateDirectoryMode=0700
UMask=0077
TimeoutStartSec=150
SyslogIdentifier=tn-heartbeat
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
NoNewPrivileges=yes
CapabilityBoundingSet=
ProtectProc=invisible
InaccessiblePaths=-/var/lib/telcoin -/etc/telcoin/bls-passphrase.cred -/etc/telcoin/bls-passphrase
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictNamespaces=yes
RestrictRealtime=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
MemoryMax=64M
CPUQuota=20%
TasksMax=32
LimitCORE=0
EOF
)"
UNIT="$(alerts_unit_text /usr/local/libexec/telcoin/tn-heartbeat)"
check "unit text: exactly the section 6 lines" "$EXP_UNIT" "$UNIT"
while IFS= read -r l; do
    check_has "unit has: ${l:-<blank>}" "$l" "$UNIT"
done <<< "$EXP_UNIT"
for bad in 'User=' 'Group=' 'IPAddressDeny' 'PrivateNetwork' 'ProcSubset' 'Persistent' 'ReadWritePaths' \
    'Restart=' 'StartLimit' '[Install]' 'WantedBy'; do
    check "unit has no ${bad} line" "0" "$(grep -c -F -e "$bad" <<< "$(grep -v '^DynamicUser=' <<< "$UNIT")")"
done
check "unit: data dir /var/lib/telcoin adds nothing" "$EXP_UNIT" "$(alerts_unit_text /usr/local/libexec/telcoin/tn-heartbeat /var/lib/telcoin)"
check "unit: a data dir under /var/lib/telcoin adds nothing" "$EXP_UNIT" "$(alerts_unit_text /usr/local/libexec/telcoin/tn-heartbeat /var/lib/telcoin/sub/)"
check "unit: a data dir elsewhere is hidden too" \
    "InaccessiblePaths=-/var/lib/telcoin -/etc/telcoin/bls-passphrase.cred -/etc/telcoin/bls-passphrase -/srv/tn-data" \
    "$(alerts_unit_text /x /srv/tn-data/ | grep '^InaccessiblePaths=')"
check "unit: /var/lib/telcoinx is not under /var/lib/telcoin" \
    "InaccessiblePaths=-/var/lib/telcoin -/etc/telcoin/bls-passphrase.cred -/etc/telcoin/bls-passphrase -/var/lib/telcoinx" \
    "$(alerts_unit_text /x /var/lib/telcoinx | grep '^InaccessiblePaths=')"

EXP_TIMER="$(cat <<'EOF'
[Unit]
Description=Telcoin node heartbeat timer (private alerts)

[Timer]
OnBootSec=120
OnUnitActiveSec=90
AccuracySec=5
Unit=telcoin-heartbeat.service

[Install]
WantedBy=timers.target
EOF
)"
TIMER="$(alerts_timer_text 90)"
check "timer text: exactly the section 6 lines" "$EXP_TIMER" "$TIMER"
check "timer has no Persistent=" "no" "$(has "$TIMER" "Persistent")"

# systemd-analyze verify (skipped where it does not run, such as the containers).
if command -v systemd-analyze >/dev/null 2>&1 && systemd-analyze --version >/dev/null 2>&1; then
    mkdir -p "$T/verify"
    alerts_unit_text "$(type -P true)" /srv/tn-data > "$T/verify/telcoin-heartbeat.service"
    alerts_timer_text 60 > "$T/verify/telcoin-heartbeat.timer"
    for u in telcoin-heartbeat.service telcoin-heartbeat.timer; do
        vout="$(cd "$T/verify" && PATH="${PATH#"$T/bin:"}" systemd-analyze verify "$T/verify/$u" 2>&1)"
        check_rc "systemd-analyze verify: $u" 0 "$?" || printf '%s\n' "$vout" | sed 's/^/      /'
        check_lacks "systemd-analyze verify: $u has no complaint" "telcoin-heartbeat" "$vout"
    done
else
    skip "systemd-analyze verify: the heartbeat units" "no systemd-analyze here"
fi

# =============================================================================
# Target validation (alerts_targets_validate, through hb_target_normalize)
# =============================================================================
# val ALLOW TEXT -- run the validator in this shell on TEXT: VOUT, VRC, VERR.
val() {
    VOUT="$(alerts_targets_validate "$1" < <(printf '%s' "$2"))"
    VRC=$?
    alerts_targets_validate "$1" >/dev/null < <(printf '%s' "$2")
    VERR="$ALERTS_ERR"
    printf '%s\n' "$VERR" >> "$T/allout-validate"
}
val 0 "kuma https://kuma.example.org/api/push/${TOK1}?status=up&msg=OK&ping="
check_rc "validate: the Kuma UI form" 0 "$VRC"
check "validate: the Kuma query is cut" "kuma https://kuma.example.org/api/push/${TOK1}" "$VOUT"
check "validate: ALERTS_VALID holds the same lines, newline-terminated" "kuma https://kuma.example.org/api/push/${TOK1}
x" "${ALERTS_VALID}x"
val 0 "kuma https://kuma.example.org/api/push/${TOK1}/"
check "validate: a trailing / on a Kuma URL is dropped" "kuma https://kuma.example.org/api/push/${TOK1}" "$VOUT"
val 0 "healthchecks ${URL3}/fail"
check "validate: healthchecks /fail is dropped" "healthchecks ${URL3}" "$VOUT"
val 0 "healthchecks ${URL3}?x=1"
check "validate: healthchecks with a query refused" "1 line 1 (healthchecks@hc-ping.com): healthchecks: a query string or fragment is not allowed" "$VRC $VERR"
val 0 "healthchecks ${URL3}#x"
check "validate: healthchecks with a fragment refused" "1 line 1 (healthchecks@hc-ping.com): healthchecks: a query string or fragment is not allowed" "$VRC $VERR"
val 0 "webhook https://hooks.example.net/a\"b"
check "validate: a quote refused" "1 line 1 (webhook@hooks.example.net): url holds a quote, backslash, space or control character" "$VRC $VERR"
val 0 "webhook http://hooks.example.net/hook/${TOK2}"
check "validate: http to a remote host needs --allow-http" "1 line 1 (webhook@hooks.example.net): http needs --allow-http (the token travels in clear text)" "$VRC $VERR"
val 1 "webhook http://hooks.example.net/hook/${TOK2}"
check "validate: http to a remote host with --allow-http" "0 webhook http://hooks.example.net/hook/${TOK2}" "$VRC $VOUT"
val 0 "kuma http://127.0.0.1:18080/api/push/vmtest1"
check "validate: http to loopback is fine" "0 kuma http://127.0.0.1:18080/api/push/vmtest1" "$VRC $VOUT"
long="https://hooks.example.net/$(printf '%0487d' 0)"
check "validate: fixture URL is 513 characters" "513" "${#long}"
val 0 "webhook ${long}"
check "validate: 513 characters refused" "1 line 1 (webhook@hooks.example.net): url longer than 512 characters" "$VRC $VERR"
val 0 "kuma https://kuma.example.org/status/${TOK1}"
check "validate: a Kuma URL without /api/push/" "1 line 1 (kuma@kuma.example.org): kuma: not an /api/push/<token> URL" "$VRC $VERR"
val 0 "kuma ftp://kuma.example.org/api/push/${TOK1}"
check "validate: another scheme refused, no host named" "1 line 1 (kuma): url must start with https://" "$VRC $VERR"
val 0 "pager https://kuma.example.org/api/push/${TOK1}"
check "validate: unknown provider" "1 line 1: unknown provider 'pager' (kuma, healthchecks or webhook)" "$VRC $VERR"
val 0 "${URL1} kuma"
check "validate: a URL where the provider goes is not echoed" "1 line 1: unknown provider (kuma, healthchecks or webhook)" "$VRC $VERR"
val 0 "kuma"
check "validate: a provider without a URL" "1 line 1: expected '<kind> <url>'" "$VRC $VERR"
val 0 "$(printf 'kuma %s\r\n\n   \nwebhook  %s  \r\nkuma https://x.example.org/nope\n' "$URL1" "$URL2")"
check "validate: CRLF and blank lines ignored, line numbers kept" "1 line 5 (kuma@x.example.org): kuma: not an /api/push/<token> URL" "$VRC $VERR"
val 0 "$(printf 'kuma %s\r\n\nwebhook\t%s  \r\n' "$URL1" "$URL2")"
check "validate: two targets, CR and blanks trimmed" "0 kuma ${URL1}
webhook ${URL2}" "$VRC $VOUT"
six=""
for i in 1 2 3 4 5 6; do six="${six}webhook https://h${i}.example.net/${TOK2}
"; done
val 0 "$six"
check "validate: six targets refused" "1 more than 5 targets (at most 5)" "$VRC $VERR"
val 0 $'\n  \n'
check "validate: no targets refused" "1 no targets given" "$VRC $VERR"
check_lacks "validate: no reason holds a token (kuma)" "$TOK1" "$(cat "$T/allout-validate")"
check_lacks "validate: no reason holds a token (webhook)" "$TOK2" "$(cat "$T/allout-validate")"
check_lacks "validate: no reason holds a token (healthchecks)" "$TOK3" "$(cat "$T/allout-validate")"

# =============================================================================
# alerts_rpc_url and alerts.env
# =============================================================================
off
rpc_case() {
    start_script "$2"
    local u rc=0
    u="$(alerts_rpc_url 2>/dev/null)" || rc=$?
    check "rpc url: $1" "$3" "$rc $u"
}
rpc_case "0.0.0.0 -> 127.0.0.1" "--http --http.addr 0.0.0.0 --http.port 8545" "0 http://127.0.0.1:8545"
rpc_case "no --http.addr -> 127.0.0.1" "--http --http.port 9000" "0 http://127.0.0.1:9000"
rpc_case ":: -> [::1]" "--http --http.addr :: --http.port 8545" "0 http://[::1]:8545"
rpc_case "an IPv6 address is bracketed" "--http --http.addr fe80::1 --http.port 8545" "0 http://[fe80::1]:8545"
rpc_case "another address as given" "--http --http.addr 10.0.0.5 --http.port 8545" "0 http://10.0.0.5:8545"
rpc_case "a quoted address" "--http --http.addr '127.0.0.1' --http.port 8545" "0 http://127.0.0.1:8545"
printf 'RPC_PORT=8600\n' >> "$META"
rpc_case "no --http.port -> RPC_PORT of .node-meta" "--http --http.addr 127.0.0.1" "0 http://127.0.0.1:8600"
base_meta
rpc_case "no --http.port, no RPC_PORT -> 8545" "--http" "0 http://127.0.0.1:8545"
rpc_case "no --http -> rc 1" "--datadir2 x" "1 "
rpc_case "a port that is not a number -> rc 2" "--http --http.port \$PORT" "2 "
off

# env NAME EXPECTED-LINES -- alerts_write_env 60 180 900, then compare the file.
run alerts_write_env 60 180 900 node-1
check_rc "env: written" 0 "$RC"
EXP_ENV="# Written by setup-alerts.sh. Change it with setup-alerts.sh, not by hand.
ALERTS_SERVICE=telcoin
ALERTS_RPC_URL=http://127.0.0.1:8545
ALERTS_NETWORK=testnet
ALERTS_CHAIN_ID=2017
ALERTS_LABEL=node-1
ALERTS_HEALTH_PORT=43180
ALERTS_INTERVAL=60
ALERTS_STALL_AFTER=180
ALERTS_INACTIVE_AFTER=900
ALERTS_RESTART_GRACE=120"
check "env: the section 2 keys" "$EXP_ENV" "$(cat "$ALERTS_D/alerts.env")"
check_has "env: written 0644 through tn_write_root_file" "/etc/telcoin/alerts/alerts.env 0644 root" "$(cat "$T/writes")"
if [[ $IS_ROOT == 1 ]]; then
    check "env: root:root 0644" "0:0 644" "$(om "$ALERTS_D/alerts.env")"
    check "env: the alerts dir is root:root 0755" "0:0 755" "$(om "$ALERTS_D")"
else
    skip "env and dir owner and mode" "not root"
fi
sed -i.bak 's/^NETWORK=.*/NETWORK=mainnet/' "$META"
alerts_write_env 060 0240 900 >/dev/null 2>&1
check "env: mainnet chain id; leading zeros read as decimal" "487 240 60" \
    "$(_alerts_env_value ALERTS_CHAIN_ID) $(_alerts_env_value ALERTS_STALL_AFTER) $(_alerts_env_value ALERTS_INTERVAL)"
sed -i.bak 's/^NETWORK=.*/NETWORK=devnet/' "$META"
alerts_write_env 60 180 900 >/dev/null 2>&1
check "env: devnet chain id" "32285" "$(_alerts_env_value ALERTS_CHAIN_ID)"
sed -i.bak 's/^NETWORK=.*/NETWORK=localnet/' "$META"
alerts_write_env 60 180 900 >/dev/null 2>&1
check "env: another network leaves the chain id empty" "localnet|" "$(_alerts_env_value ALERTS_NETWORK)|$(_alerts_env_value ALERTS_CHAIN_ID)"
base_meta
printf 'My_Host.example!x\n' > "$T/hostname"
alerts_write_env 60 180 900 >/dev/null 2>&1
check "env: the label from the host name, filtered" "My_Host.examplex" "$(_alerts_env_value ALERTS_LABEL)"
printf -- '-._weird*host\n' > "$T/hostname"
alerts_write_env 60 180 900 >/dev/null 2>&1
check "env: a host name starting with punctuation" "weirdhost" "$(_alerts_env_value ALERTS_LABEL)"
printf '%s\n' '***' > "$T/hostname"
alerts_write_env 60 180 900 >/dev/null 2>&1
check "env: nothing usable in the host name -> node" "node" "$(_alerts_env_value ALERTS_LABEL)"
printf 'h%070d\n' 0 > "$T/hostname"
alerts_write_env 60 180 900 >/dev/null 2>&1
check "env: the label is cut to 64" "64" "$(_alerts_env_value ALERTS_LABEL | tr -d '\n' | wc -c | tr -d ' ')"
rm -f "$T/hostname"
start_script "--http --http.addr 0.0.0.0"
alerts_write_env 60 180 900 >/dev/null 2>&1
check "env: no --healthcheck -> 43174" "43174" "$(_alerts_env_value ALERTS_HEALTH_PORT)"
start_script "$FLAGS_STD"
before="$(cat "$ALERTS_D/alerts.env")"
for bad in "29 180 900" "3601 3631 3631" "60 89 900" "60 180 179" "60 180 86401" "abc 180 900"; do
    # shellcheck disable=SC2086
    run alerts_write_env $bad
    check_rc "env: timing '${bad}' refused" 1 "$RC"
done
run alerts_write_env 60 180 900 "-bad"
check "env: a bad label refused" "1 the label must be 1 to 64 letters, digits, dots, underscores or dashes, starting with a letter or a digit" "$RC $ALERTS_ERR"
check "env: refusals leave the file as it was" "$before" "$(cat "$ALERTS_D/alerts.env")"
start_script "--datadir2 x"
run alerts_write_env 60 180 900
check "env: no --http refused" "1 yes" "$RC $(has "$ALERTS_ERR" "has no --http")"
off

# =============================================================================
# Writers: the targets file 0600, the runner, the units
# =============================================================================
run alerts_write_targets < <(printf '%s' "$TARGETS2")
check_rc "targets: written" 0 "$RC"
check "targets: the lines as given" "${TARGETS2}x" "$(cat "$ALERTS_D/targets"; printf x)"
check "targets: one write, 0600 through tn_write_root_file" "/etc/telcoin/alerts/targets 0600 root" "$(cat "$T/writes")"
if [[ $IS_ROOT == 1 ]]; then
    check "targets: root:root 0600 on disk" "0:0 600" "$(om "$ALERTS_D/targets")"
    left=0
    for f in "$ALERTS_D"/.tn.*; do [[ -e "$f" ]] && left=$((left + 1)); done
    check "targets: no temp file left in the dir" "0" "$left"
else
    check "targets: mode 0600 on disk" "600" "$(stat -c %a "$ALERTS_D/targets")"
    skip "targets: root:root owner on disk" "not root"
fi
: > "$T/writes"
run alerts_install_runner
check_rc "runner: installed" 0 "$RC"
check "runner: the checkout's file" "yes" "$(cmp -s "$TN_TEST_REPO/lib/tn-heartbeat.sh" "$RUNNER_F" && echo yes)"
check "runner: through tn_install_root_binary" "install /usr/local/libexec/telcoin/tn-heartbeat" "$(cat "$T/writes")"
if [[ $IS_ROOT == 1 ]]; then
    check "runner: root:root 0755" "0:0 755" "$(om "$RUNNER_F")"
else
    check "runner: mode 0755" "755" "$(stat -c %a "$RUNNER_F")"
fi
: > "$T/writes"
: > "$T/calls"
sed -i.bak 's#^DATA_DIR=.*#DATA_DIR=/srv/tn data#' "$META"
run alerts_write_units 45
check_rc "units: written" 0 "$RC"
check "units: a data dir with a space stays out of the unit" "InaccessiblePaths=-/var/lib/telcoin -/etc/telcoin/bls-passphrase.cred -/etc/telcoin/bls-passphrase" "$(grep '^InaccessiblePaths=' "$UNIT_F")"
sed -i.bak 's#^DATA_DIR=.*#DATA_DIR=/srv/tn-data#' "$META"
run alerts_write_units 45
check "units: DATA_DIR of .node-meta hidden" "InaccessiblePaths=-/var/lib/telcoin -/etc/telcoin/bls-passphrase.cred -/etc/telcoin/bls-passphrase -/srv/tn-data" "$(grep '^InaccessiblePaths=' "$UNIT_F")"
check "units: the timer interval" "OnUnitActiveSec=45" "$(grep '^OnUnitActiveSec=' "$TIMER_F")"
check "units: both written 0644, then daemon-reload" "/etc/systemd/system/telcoin-heartbeat.service 0644 root
/etc/systemd/system/telcoin-heartbeat.timer 0644 root
daemon-reload" "$(tail -n 2 "$T/writes"; tail -n 1 "$T/calls")"
run alerts_write_units 20
check_rc "units: an interval under 30 refused" 1 "$RC"
off

# =============================================================================
# alerts_enable: refusals (nothing changed)
# =============================================================================
# refused NAME NEEDLE -- run alerts_enable 60 180 900 with two targets; rc 1, the
# message holds NEEDLE and "Nothing was changed.", no alerts file and no write.
refused() {
    run alerts_enable 60 180 900 < <(printf '%s' "$TARGETS2")
    check "enable refused: $1" "1 yes yes" "$RC $(has "$OUT" "$2") $(has "$OUT" "Nothing was changed.")"
    check "enable refused: $1: no file" "no no no no no" "$(no_alerts_files)"
    check "enable refused: $1: nothing written" "" "$(cat "$T/writes")"
}
echo 246 > "$T/sysver"
refused "systemd 246" "need systemd 247 or later"
echo "x" > "$T/sysver"
refused "systemd version unreadable" "need systemd 247 or later"
rm -f "$T/sysver"
rm -f "$RP/etc/systemd/system/telcoin.service"
refused "no node unit" "No node service is installed"
off
start_script "--datadir2 x"
refused "no --http" "The node command has no --http, so the runner cannot read the local RPC; add it with edit-config.sh and run this again."
off
printf 'ENABLE_ALERTS=pending\nENABLE_ALERTS=true\n' >> "$META"
refused "ENABLE_ALERTS twice" "ENABLE_ALERTS is set more than once in .node-meta"
off
rm -f "$META"
refused "no .node-meta" "There is no .node-meta on this host"
off
run alerts_enable 20 180 900 < <(printf '%s' "$TARGETS2")
check "enable refused: a bad interval" "1 yes" "$RC $(has "$OUT" "Refused: the interval must be")"
check "enable refused: a bad interval: no file" "no no no no no" "$(no_alerts_files)"
run alerts_enable 60 180 900 < <(printf 'kuma https://kuma.example.org/x/%s\n' "$TOK1")
check "enable refused: a bad target names kind@host only" "1 yes" "$RC $(has "$OUT" "Refused: line 1 (kuma@kuma.example.org): kuma: not an /api/push/<token> URL. Nothing was changed.")"
check "enable refused: a bad target: no file" "no no no no no" "$(no_alerts_files)"
run alerts_enable 60 180 900 < /dev/null
check "enable refused: no targets on a node without alerts" "1 yes" "$RC $(has "$OUT" "No targets were given")"
check "enable refused: no targets: no file" "no no no no no" "$(no_alerts_files)"
if [[ $IS_ROOT != 1 ]]; then
    _alerts_is_root() { return 1; }
    run alerts_enable 60 180 900 < <(printf '%s' "$TARGETS2")
    check "enable refused: not root" "1 yes" "$RC $(has "$OUT" "set up as root")"
    _alerts_is_root() { return 0; }
fi

# =============================================================================
# alerts_enable: a target accepts the test heartbeat
# =============================================================================
off
run alerts_enable 60 180 900 < <(printf '%s' "$TARGETS2")
check_rc "enable: rc 0" 0 "$RC"
check "enable: ALERTS_APPLIED" "enabled" "$ALERTS_APPLIED"
check "enable: every file in place" "yes yes yes yes yes" \
    "$(exists "$ALERTS_D/targets") $(exists "$ALERTS_D/alerts.env") $(exists "$RUNNER_F") $(exists "$UNIT_F") $(exists "$TIMER_F")"
check "enable: the targets file holds the targets" "${TARGETS2}x" "$(cat "$ALERTS_D/targets"; printf x)"
check "enable: the runner saw them at the test" "${TARGETS2}x" "$(cat "$T/runner-saw"; printf x)"
check "enable: systemctl steps" "daemon-reload
start telcoin-heartbeat.service
enable --now telcoin-heartbeat.timer" "$(grep -v -e '^--version' "$T/calls")"
check "enable: ENABLE_ALERTS=true" "true" "$(meta_val ENABLE_ALERTS)"
check "enable: results" "1 kuma kuma.example.org ok 200
2 webhook hooks.example.net ok 200" "$ALERTS_RESULTS"
check "enable: node status" "up|CvvActive block 1234567 epoch 42" "${ALERTS_NODE_STATUS}|${ALERTS_NODE_REASON}"
check "enable: says each target as kind@host" "yes yes" "$(has "$OUT" "Target 1 kuma@kuma.example.org: accepted (200)") $(has "$OUT" "Target 2 webhook@hooks.example.net: accepted (200)")"
check "enable: the env file has the label" "node-1" "$(_alerts_env_value ALERTS_LABEL)"
if [[ $IS_ROOT == 1 ]]; then
    check "enable: owners and modes" "0:0 755|0:0 600|0:0 644|0:0 755|0:0 644|0:0 644" \
        "$(om "$ALERTS_D")|$(om "$ALERTS_D/targets")|$(om "$ALERTS_D/alerts.env")|$(om "$RUNNER_F")|$(om "$UNIT_F")|$(om "$TIMER_F")"
    check ".node-meta stays root:root 0600" "0:0 600" "$(om "$META")"
else
    skip "enable: owners and modes" "not root"
fi

# A mixed run: one of two accepted is enough.
off
echo mixed > "$T/scenario"
run alerts_enable 60 180 900 < <(printf '%s' "$TARGETS2")
check "enable: one target of two accepting is enough" "0 enabled" "$RC $ALERTS_APPLIED"
check "enable: the failed one is said" "yes" "$(has "$OUT" "Target 1 kuma@kuma.example.org: failed (503 http)")"

# =============================================================================
# alerts_enable: no target accepts -> everything removed again
# =============================================================================
# meta_writes -- the .node-meta writes tn_write_root_file logged.
meta_writes() { grep -c '^/etc/telcoin/.node-meta ' "$T/writes"; }
off
echo allfail > "$T/scenario"
cp -p "$META" "$T/meta-before"
run alerts_enable 60 180 900 < <(printf '%s' "$TARGETS2")
check_rc "enable all-fail: rc 1" 1 "$RC"
check "enable all-fail: the message" "yes" "$(has "$OUT" "No target accepted the test heartbeat; private alerts were not enabled. Check the URLs and run this again.")"
check "enable all-fail: no file left" "no no no no no" "$(no_alerts_files)"
check "enable all-fail: no ENABLE_ALERTS line, as before the enable" "0" "$(grep -c '^ENABLE_ALERTS=' "$META")"
check "enable all-fail: .node-meta byte for byte as it was, never written" "yes 0" \
    "$(cmp -s "$T/meta-before" "$META" && echo yes) $(meta_writes)"
check "enable all-fail: the timer was never enabled" "" "$(grep '^enable' "$T/calls")"
check "enable all-fail: no monitor hint" "no" "$(has "$OUT" "Pause or delete this node's monitor")"
off
echo nostate > "$T/scenario"
printf 'ENABLE_ALERTS=pending\n' >> "$META"
cp -p "$META" "$T/meta-before"
run alerts_enable 60 180 900 < <(printf '%s' "$TARGETS2")
check "enable without a recorded run: rc 1, the journal hint" "1 yes" "$RC $(has "$OUT" "journalctl -u telcoin-heartbeat -n 20")"
check "enable without a recorded run: no file left" "no no no no no" "$(no_alerts_files)"
check "enable rolled back: a pending ENABLE_ALERTS stays pending" "pending" "$(meta_val ENABLE_ALERTS)"
check "enable rolled back from pending: .node-meta never written" "yes 0" \
    "$(cmp -s "$T/meta-before" "$META" && echo yes) $(meta_writes)"
off
echo allfail > "$T/scenario"
printf 'ENABLE_ALERTS=false\n' >> "$META"
run alerts_enable 60 180 900 < <(printf '%s' "$TARGETS2")
check "enable rolled back: ENABLE_ALERTS=false stays, not written" "false 1 0" \
    "$(meta_val ENABLE_ALERTS) $(grep -c '^ENABLE_ALERTS=' "$META") $(meta_writes)"
off
echo allfail > "$T/scenario"
printf 'ENABLE_ALERTS=true\n' >> "$META"
run alerts_enable 60 180 900 < <(printf '%s' "$TARGETS2")
check "enable over ENABLE_ALERTS=true without a timer: a fresh install, rolled back" "1 no no no no no" "$RC $(no_alerts_files)"
check "enable rolled back: ENABLE_ALERTS goes back to the value it had" "true" "$(meta_val ENABLE_ALERTS)"
off
touch "$T/enable-fails"
run alerts_enable 60 180 900 < <(printf '%s' "$TARGETS2")
check "enable: the timer does not start -> rc 1, nothing left" "1 no no no no no" "$RC $(no_alerts_files)"
check "enable: the timer does not start -> still no ENABLE_ALERTS line" "0 0" \
    "$(grep -c '^ENABLE_ALERTS=' "$META") $(meta_writes)"
rm -f "$T/enable-fails"
# .node-meta refuses ENABLE_ALERTS=true: rolled back, the key stays absent.
off
eval "$(declare -f meta_set | sed '1s/^meta_set /_real_meta_set /')"
meta_set() { if [[ "${1:-}" == ENABLE_ALERTS && "${2:-}" == true ]]; then return 2; fi; _real_meta_set "$@"; }
run alerts_enable 60 180 900 < <(printf '%s' "$TARGETS2")
check "enable: ENABLE_ALERTS=true not recorded -> rc 1, nothing left, no line" "1 no no no no no 0" \
    "$RC $(no_alerts_files) $(grep -c '^ENABLE_ALERTS=' "$META")"
eval "$(declare -f _real_meta_set | sed '1s/^_real_meta_set /meta_set /')"

# =============================================================================
# alerts_set_targets: a failed test puts the old file back byte for byte
# =============================================================================
off
alerts_enable 60 180 900 < <(printf '%s' "$TARGETS2") > /dev/null 2>&1
# An old file with bytes a normalised write would not produce.
OLD="$(printf 'kuma %s\n\nwebhook %s' "$URL1" "$URL2"; printf x)"
OLD="${OLD%x}"
tn_write_root_file "$ALERTS_D/targets" 0600 < <(printf '%s' "$OLD")
cp "$ALERTS_D/targets" "$T/old-targets"
echo allfail > "$T/scenario"
: > "$T/writes"
run alerts_set_targets < <(printf 'kuma %s\n' "$URL4")
check "set-targets fail: rc 1, the message" "1 yes" "$RC $(has "$OUT" "No target accepted the test heartbeat; the previous targets were put back.")"
check "set-targets fail: the runner tested the new targets" "kuma ${URL4}" "$(cat "$T/runner-saw")"
check "set-targets fail: the old file back byte for byte" "yes" "$(cmp -s "$T/old-targets" "$ALERTS_D/targets" && echo yes)"
check "set-targets fail: written twice, 0600 both times" "/etc/telcoin/alerts/targets 0600 root
/etc/telcoin/alerts/targets 0600 root" "$(cat "$T/writes")"
if [[ $IS_ROOT == 1 ]]; then
    check "set-targets fail: still root:root 0600" "0:0 600" "$(om "$ALERTS_D/targets")"
fi
echo ok > "$T/scenario"
run alerts_set_targets < <(printf 'kuma %s\nhealthchecks %s/fail\n' "$URL4" "$URL3")
check_rc "set-targets: rc 0" 0 "$RC"
check "set-targets: the new targets in place (normalised)" "kuma ${URL4}
healthchecks ${URL3}" "$(cat "$ALERTS_D/targets")"
check "set-targets: results of the new pair" "1 kuma kuma2.example.org ok 200
2 healthchecks hc-ping.com ok 200" "$ALERTS_RESULTS"
run alerts_set_targets < /dev/null
check "set-targets: no targets refused" "1 yes" "$RC $(has "$OUT" "No targets were given")"
run alerts_set_targets < <(printf 'kuma https://kuma.example.org/x\n')
check "set-targets: a bad line refused, file unchanged" "1 kuma ${URL4}
healthchecks ${URL3}" "$RC $(cat "$ALERTS_D/targets")"

# alerts_enable on a node with alerts on: targets -> set_targets, none -> refresh;
# the values given (empty = keep the stored one) and ALERTS_LABEL_REQ go through
# alerts_refresh, after the targets when there are some.
# timing -- interval, stall, inactive and label of alerts.env, and the timer interval.
timing() {
    printf '%s %s %s %s %s\n' "$(_alerts_env_value ALERTS_INTERVAL)" "$(_alerts_env_value ALERTS_STALL_AFTER)" \
        "$(_alerts_env_value ALERTS_INACTIVE_AFTER)" "$(_alerts_env_value ALERTS_LABEL)" \
        "$(grep '^OnUnitActiveSec=' "$TIMER_F" | sed 's/^[^=]*=//')"
}
# shellcheck disable=SC2034  # read by lib/alerts.sh
ALERTS_LABEL_REQ=""
: > "$T/calls"
run alerts_enable "" "" "" < <(printf 'kuma %s\n' "$URL1")
check "enable on an enabled node with targets: targets changed" "0 targets-changed kuma ${URL1}" "$RC $ALERTS_APPLIED $(cat "$ALERTS_D/targets")"
check "enable on an enabled node with targets only: no refresh" "no 60 180 900 node-1 60" \
    "$(grep -qx 'restart telcoin-heartbeat.timer' "$T/calls" && echo yes || echo no) $(timing)"
: > "$T/calls"
run alerts_enable "" "" "" < /dev/null
check "enable on an enabled node without targets: refreshed" "0 refreshed" "$RC $ALERTS_APPLIED"
check "enable on an enabled node without targets: the timer restarted" "yes" "$(grep -qx 'restart telcoin-heartbeat.timer' "$T/calls" && echo yes)"
check "enable on an enabled node without values: the stored ones kept" "60 180 900 node-1 60" "$(timing)"
run alerts_enable 120 360 900 < /dev/null
check "enable on an enabled node, an interval and thresholds given: applied" "0 refreshed 120 360 900 node-1 120" \
    "$RC $ALERTS_APPLIED $(timing)"
run alerts_enable "" 400 "" < /dev/null
check "enable on an enabled node, a stall time alone: the others stay" "0 refreshed 120 400 900 node-1 120" \
    "$RC $ALERTS_APPLIED $(timing)"
: > "$T/calls"
run alerts_enable 90 270 900 < <(printf 'kuma %s\n' "$URL4")
check "enable on an enabled node, targets and values: both applied" "0 targets-changed refreshed kuma ${URL4} 90 270 900 node-1 90" \
    "$RC $ALERTS_APPLIED $(cat "$ALERTS_D/targets") $(timing)"
check "enable on an enabled node, targets and values: the test, then the restart" "start telcoin-heartbeat.service
restart telcoin-heartbeat.timer" "$(grep -E '^(start|restart) ' "$T/calls")"
ALERTS_LABEL_REQ="edge-9"
run alerts_enable "" "" "" < <(printf 'kuma %s\n' "$URL1")
check "enable on an enabled node, targets and a label: both applied" "0 targets-changed refreshed 90 270 900 edge-9 90" \
    "$RC $ALERTS_APPLIED $(timing)"
ALERTS_LABEL_REQ=""
# A value that does not fit the stored ones is refused before anything changes.
cp "$ALERTS_D/targets" "$T/targets-before"
cp "$ALERTS_D/alerts.env" "$T/env-before"
: > "$T/writes"
: > "$T/calls"
run alerts_enable "" 5000 "" < <(printf 'kuma %s\n' "$URL4")
check "enable on an enabled node, a stall time above the stored inactive time: refused" "1 yes" \
    "$RC $(has "$OUT" "Refused: --inactive-after must be a whole number of seconds from 5000 (the stall time) to 86400. Nothing was changed.")"
check "enable on an enabled node, refused: nothing written, nothing run" "yes yes||" \
    "$(cmp -s "$T/targets-before" "$ALERTS_D/targets" && echo yes) $(cmp -s "$T/env-before" "$ALERTS_D/alerts.env" && echo yes)|$(cat "$T/writes")|$(grep -v '^--version' "$T/calls")"
run alerts_enable 20 "" "" < /dev/null
check "enable on an enabled node, a bad interval: refused" "1 yes yes" \
    "$RC $(has "$OUT" "Refused: the interval must be") $(cmp -s "$T/env-before" "$ALERTS_D/alerts.env" && echo yes)"
# The targets change fails: the old targets are back and the values are not applied.
echo allfail > "$T/scenario"
run alerts_enable 120 360 900 < <(printf 'kuma %s\n' "$URL4")
check "enable on an enabled node, the new targets fail: put back, values not applied" "1 yes yes" \
    "$RC $(cmp -s "$T/targets-before" "$ALERTS_D/targets" && echo yes) $(cmp -s "$T/env-before" "$ALERTS_D/alerts.env" && echo yes)"
echo ok > "$T/scenario"
# The targets change goes through but the refresh after it does not: rc 2, said.
touch "$T/restart-fails"
run alerts_enable 120 360 900 < <(printf 'kuma %s\n' "$URL4")
check "enable on an enabled node, the refresh after the targets fails: rc 2" "2 targets-changed kuma ${URL4}" \
    "$RC $ALERTS_APPLIED $(cat "$ALERTS_D/targets")"
check "enable on an enabled node, the refresh fails: said" "yes yes" \
    "$(has "$OUT" "The heartbeat timer did not restart") $(has "$OUT" "The new targets are in place, but the new settings were not fully applied; run setup-alerts.sh --refresh with the same options again.")"
rm -f "$T/restart-fails"

# =============================================================================
# alerts_refresh
# =============================================================================
off
run alerts_refresh
check "refresh: off -> nothing to do" "0 yes" "$RC $(has "$OUT" "Private alerts are off; nothing to refresh.")"
check "refresh: off -> no write, no systemctl call" "|" "$(cat "$T/writes")|$(cat "$T/calls")"
alerts_enable 120 400 1000 < <(printf '%s' "$TARGETS2") > /dev/null 2>&1
printf '#!/bin/bash\nHEARTBEAT_VERSION="1.0.0"\n' > "$RUNNER_F"
start_script "--http --http.addr 127.0.0.1 --http.port 8547 --healthcheck 43190"
# shellcheck disable=SC2034  # read by lib/alerts.sh
ALERTS_LABEL_REQ=""
: > "$T/calls"
run alerts_refresh
check_rc "refresh: rc 0" 0 "$RC"
check "refresh: the runner installed again" "yes" "$(cmp -s "$TN_TEST_REPO/lib/tn-heartbeat.sh" "$RUNNER_F" && echo yes)"
check "refresh: the stored timing and label kept, the RPC and health port read again" \
    "120 400 1000 node-1 http://127.0.0.1:8547 43190" \
    "$(_alerts_env_value ALERTS_INTERVAL) $(_alerts_env_value ALERTS_STALL_AFTER) $(_alerts_env_value ALERTS_INACTIVE_AFTER) $(_alerts_env_value ALERTS_LABEL) $(_alerts_env_value ALERTS_RPC_URL) $(_alerts_env_value ALERTS_HEALTH_PORT)"
check "refresh: the timer keeps the interval" "OnUnitActiveSec=120" "$(grep '^OnUnitActiveSec=' "$TIMER_F")"
check "refresh: systemctl steps" "daemon-reload
enable telcoin-heartbeat.timer
restart telcoin-heartbeat.timer" "$(cat "$T/calls")"
check "refresh: the targets untouched" "${TARGETS2}x" "$(cat "$ALERTS_D/targets"; printf x)"
# Values given replace the stored ones; the others stay.
: > "$T/calls"
run alerts_refresh "" 90
check "refresh with an interval: the interval and the timer change, the thresholds stay" "0 90 400 1000 node-1 90" \
    "$RC $(timing)"
check "refresh with an interval: the timer restarted" "yes" "$(grep -qx 'restart telcoin-heartbeat.timer' "$T/calls" && echo yes)"
run alerts_refresh "" "" "" 1200
check "refresh with an inactive time: only it changes" "0 90 400 1200 node-1 90" "$RC $(timing)"
ALERTS_LABEL_REQ="edge-3"
run alerts_refresh "" 300 600 1800
check "refresh with all three and a label" "0 300 600 1800 edge-3 300" "$RC $(timing)"
ALERTS_LABEL_REQ=""
cp "$ALERTS_D/alerts.env" "$T/env-before"
: > "$T/writes"
: > "$T/calls"
run alerts_refresh "" "" 99999
check "refresh: a stall time out of range refused" "1 yes" \
    "$RC $(has "$OUT" "Refused: --stall-after must be a whole number of seconds from 330 (the interval plus 30) to 86400. Nothing was changed.")"
check "refresh refused: nothing written, nothing run" "yes||" \
    "$(cmp -s "$T/env-before" "$ALERTS_D/alerts.env" && echo yes)|$(cat "$T/writes")|$(cat "$T/calls")"
ALERTS_LABEL_REQ="-bad"
run alerts_refresh
check "refresh: a bad label refused, nothing written" "1 yes yes" \
    "$RC $(has "$OUT" "Refused: the label must be") $(cmp -s "$T/env-before" "$ALERTS_D/alerts.env" && echo yes)"
# shellcheck disable=SC2034  # read by lib/alerts.sh
ALERTS_LABEL_REQ=""
touch "$T/restart-fails"
run alerts_refresh
check "refresh: the timer does not restart -> rc 2" "2 yes" "$RC $(has "$OUT" "The heartbeat timer did not restart")"
rm -f "$T/restart-fails"

# =============================================================================
# alerts_status: the issue count
# =============================================================================
# say_rec KIND MSG -- an FN that prints what it is told, one "KIND|MSG" line.
say_rec() { printf '%s|%s\n' "$1" "$2"; }
off
run alerts_status say_rec
check "status off (no key): one plain line, rc 0" "0 log|Private alerts: off (enable them with setup-alerts.sh)" "$RC $OUT"
check "status off: ALERTS_ST_*" "false absent" "$ALERTS_ST_ENABLED $ALERTS_ST_TIMER"
run alerts_status
check "status off without FN: one print_info line" "  ->  Private alerts: off (enable them with setup-alerts.sh)" "$OUT"
printf 'ENABLE_ALERTS=false\n' >> "$META"
run alerts_status say_rec
check "status off (ENABLE_ALERTS=false): one plain line, rc 0" "0 log|Private alerts: off (enable them with setup-alerts.sh)" "$RC $OUT"
alerts_timer_text 60 > "$TIMER_F"
run alerts_status say_rec
check "status off with a timer unit left: the full block" "yes yes yes" \
    "$(has "$OUT" "step|Private alerts (heartbeat to your own monitor)") $(has "$OUT" "log|Private alerts: off") $(has "$OUT" "log|timer inactive")"
rm -f "$TIMER_F"
base_meta
printf 'ENABLE_ALERTS=pending\n' >> "$META"
run alerts_status
check "status pending: no issue" "0 yes pending" "$RC $(has "$OUT" "Private alerts: pending") $ALERTS_ST_ENABLED"
check "status pending: the full block" "yes yes" "$(has "$OUT" "Private alerts (heartbeat to your own monitor)") $(has "$OUT" "timer not installed")"
off
alerts_enable 60 180 900 < <(printf '%s' "$TARGETS2") > /dev/null 2>&1
run alerts_status
check "status on: no issue" "0" "$RC" || printf '%s\n' "$OUT" | sed 's/^/      /'
check "status on: the lines" "yes yes yes yes yes" \
    "$(has "$OUT" "Private alerts: on") $(has "$OUT" "timer active, next run Wed 2026-11-04 12:00:00 UTC") $(has "$OUT" "s ago: up, CvvActive block 1234567 epoch 42") $(has "$OUT" "target 1 kuma@kuma.example.org ok 200") $(has "$OUT" "target 2 webhook@hooks.example.net ok 200")"
check "status on: ALERTS_ST_*" "true active up 2.1.0" "$ALERTS_ST_ENABLED $ALERTS_ST_TIMER $ALERTS_ST_LAST_STATUS $ALERTS_ST_RUNNER_VERSION"
check "status on: last run recorded" "yes" "$([[ "$ALERTS_ST_LAST_RUN" =~ ^[0-9]+$ ]] && echo yes)"
rm -f "$T/timer-active"
run alerts_status
check "status: timer inactive -> 1 issue" "1 inactive yes" "$RC $ALERTS_ST_TIMER $(has "$OUT" "is not running")"
: > "$T/timer-active"
echo stale > "$T/scenario"
systemctl start telcoin-heartbeat.service
run alerts_status
check "status: a stale run -> 1 issue" "1 yes" "$RC $(has "$OUT" "more than 3 x the 60 s interval")"
echo allfail > "$T/scenario"
systemctl start telcoin-heartbeat.service
run alerts_status
check "status: every push failed -> 1 issue" "1 yes" "$RC $(has "$OUT" "Every push of the last run failed")"
echo ok > "$T/scenario"
systemctl start telcoin-heartbeat.service
chmod 0644 "$ALERTS_D/targets"
run alerts_status
check "status: targets 0644 -> 1 issue" "1 yes" "$RC $(has "$OUT" "must be root:root 0600")"
chmod 0600 "$ALERTS_D/targets"
# A symlinked state file is not read.
mkdir -p "$T/elsewhere"
cp "$STATE" "$T/elsewhere/state"
rm -f "$STATE"
ln -s "$T/elsewhere/state" "$STATE"
run alerts_status
check "status: a symlinked state file is ignored -> 1 issue" "1 yes|" "$RC $(has "$OUT" "No heartbeat run is recorded")|$ALERTS_ST_LAST_RUN"
rm -f "$STATE"
systemctl start telcoin-heartbeat.service
printf '#!/bin/bash\nHEARTBEAT_VERSION="2.0.9"\n' > "$RUNNER_F"
run alerts_status
check "status: another runner version -> 1 issue" "1 yes 2.0.9" "$RC $(has "$OUT" "run: sudo bash setup-alerts.sh --refresh") $ALERTS_ST_RUNNER_VERSION"
cp "$TN_TEST_REPO/lib/tn-heartbeat.sh" "$RUNNER_F"
start_script "--http --http.addr 127.0.0.1 --http.port 8547"
run alerts_status
check "status: alerts.env out of step with the node -> 1 issue" "1 yes" "$RC $(has "$OUT" "but the node serves it at http://127.0.0.1:8547")"
start_script "$FLAGS_STD"
printf 'ENABLE_ALERTS=true\n' >> "$META"
run alerts_status
check "status: ENABLE_ALERTS twice -> 1 issue" "1 yes" "$RC $(has "$OUT" "ENABLE_ALERTS is set more than once")"
base_meta
printf 'ENABLE_ALERTS=true\n' >> "$META"
rm -f "$T/timer-active"
echo allfail > "$T/scenario"
systemctl start telcoin-heartbeat.service
chmod 0640 "$ALERTS_D/targets"
printf '#!/bin/bash\nHEARTBEAT_VERSION="2.0.9"\n' > "$RUNNER_F"
run alerts_status
check "status: four issues add up" "4" "$RC"
if [[ $IS_ROOT != 1 ]]; then
    _alerts_is_root() { return 1; }
    run alerts_status
    check "status without root: the run is not read" "yes |" "$(has "$OUT" "last run not checked (run with sudo)") |$ALERTS_ST_LAST_RUN"
    _alerts_is_root() { return 0; }
fi
cp "$TN_TEST_REPO/lib/tn-heartbeat.sh" "$RUNNER_F"
chmod 0600 "$ALERTS_D/targets"

# .node-meta that cannot be read (root 0600, read by another user): its value is
# unknown, and the timer's enablement decides whether the alerts count as on.
if [[ $IS_ROOT != 1 ]]; then
    base_meta
    printf 'ENABLE_ALERTS=true\n' >> "$META"
    echo ok > "$T/scenario"
    systemctl start telcoin-heartbeat.service
    : > "$T/timer-active"
    : > "$T/timer-enabled"
    chmod 000 "$META"
    run alerts_status say_rec
    check "status, .node-meta unreadable: the value is unknown" "yes no|" \
        "$(has "$OUT" "log|Private alerts: unknown (run with sudo)") $(has "$OUT" "log|Private alerts: off")|$ALERTS_ST_ENABLED"
    check "status, .node-meta unreadable, the timer enabled and running: no issue" "0" "$RC" \
        || printf '%s\n' "$OUT" | sed 's/^/      /'
    # The node's RPC address needs .node-meta: alerts.env is not compared with it.
    start_script "--datadir2 x"
    run alerts_status say_rec
    check "status, .node-meta unreadable: alerts.env not compared with the node" "0 yes" \
        "$RC $(has "$OUT" "log|alerts.env not compared with the node (run with sudo)")"
    start_script "$FLAGS_STD"
    rm -f "$T/timer-active"
    run alerts_status say_rec
    check "status, .node-meta unreadable, the timer enabled but stopped: on, 1 issue" "1 yes" \
        "$RC $(has "$OUT" "warn|Private alerts are on, but telcoin-heartbeat.timer is not running")"
    echo stale > "$T/scenario"
    systemctl start telcoin-heartbeat.service
    : > "$T/timer-active"
    run alerts_status say_rec
    check "status, .node-meta unreadable, enabled: a stale run counts" "1 yes" "$RC $(has "$OUT" "more than 3 x the 60 s interval")"
    rm -f "$T/timer-enabled"
    run alerts_status say_rec
    check "status, .node-meta unreadable, the timer not enabled: off, no on-only issue" "0 no" \
        "$RC $(has "$OUT" "more than 3 x")"
    echo ok > "$T/scenario"
    systemctl start telcoin-heartbeat.service
    mv "$TIMER_F" "$T/timer-saved"
    run alerts_status say_rec
    check "status, .node-meta unreadable, no timer unit: the one plain line" \
        "0 log|Private alerts: off (enable them with setup-alerts.sh)|" "$RC $OUT|$ALERTS_ST_ENABLED"
    mv "$T/timer-saved" "$TIMER_F"
    chmod 0600 "$META"
    run alerts_status say_rec
    check "status, .node-meta readable again: on" "true yes" "$ALERTS_ST_ENABLED $(has "$OUT" "log|Private alerts: on")"
else
    skip "status with an unreadable .node-meta" "root reads every file"
fi

# =============================================================================
# alerts_disable
# =============================================================================
echo ok > "$T/scenario"
ln -s private/telcoin-heartbeat "$RP/var/lib/telcoin-heartbeat"
# A temp copy an interrupted write left: it holds the URLs and would stop the rmdir.
cp "$ALERTS_D/targets" "$ALERTS_D/.tn.AbC123"
: > "$T/calls"
run alerts_disable
check_rc "disable: rc 0" 0 "$RC"
check "disable: the interrupted write's temp copy is gone" "no" "$(exists "$ALERTS_D/.tn.AbC123")"
check "disable: systemctl steps in order" "disable --now telcoin-heartbeat.timer
stop telcoin-heartbeat.service
clean --what=state telcoin-heartbeat.service
daemon-reload
reset-failed telcoin-heartbeat.service" "$(cat "$T/calls")"
check "disable: no file left" "no no no no no" "$(no_alerts_files)"
check "disable: the state link gone" "no" "$(exists "$RP/var/lib/telcoin-heartbeat")"
check "disable: ENABLE_ALERTS=false" "false" "$(meta_val ENABLE_ALERTS)"
check "disable: the monitor hint" "yes" "$(has "$OUT" "Pause or delete this node's monitor: a push monitor alerts on silence.")"
# systemctl clean fails (an older systemd, or the unit gone): the fallback removes the state.
alerts_enable 60 180 900 < <(printf '%s' "$TARGETS2") > /dev/null 2>&1
check "disable, clean failing: enabled again first" "yes yes" "$(exists "$STATE_D") $(exists "$ALERTS_D/targets")"
ln -s private/telcoin-heartbeat "$RP/var/lib/telcoin-heartbeat"
touch "$T/clean-fails"
run alerts_disable "" no-hint
check "disable, clean failing: the state dir and link removed" "0 no no" "$RC $(exists "$STATE_D") $(exists "$RP/var/lib/telcoin-heartbeat")"
check "disable no-hint: no monitor hint" "no" "$(has "$OUT" "Pause or delete")"
rm -f "$T/clean-fails"
# keep-meta: everything goes, .node-meta stays as it is (the enable rollback's mode).
alerts_enable 60 180 900 < <(printf '%s' "$TARGETS2") > /dev/null 2>&1
: > "$T/writes"
run alerts_disable "" keep-meta
check "disable keep-meta: everything removed, .node-meta not written" "0 no no no no no true 0" \
    "$RC $(no_alerts_files) $(meta_val ENABLE_ALERTS) $(meta_writes)"
check "disable keep-meta: the monitor hint all the same" "yes" "$(has "$OUT" "Pause or delete")"
alerts_enable 60 180 900 < <(printf '%s' "$TARGETS2") > /dev/null 2>&1
: > "$T/writes"
run alerts_disable "" keep-meta no-hint
check "disable keep-meta no-hint: either order, no hint, no write" "0 no 0" \
    "$RC $(has "$OUT" "Pause or delete") $(meta_writes)"
meta_set ENABLE_ALERTS false "$META" >/dev/null 2>&1
# The targets file survives: rc 1, said.
alerts_enable 60 180 900 < <(printf '%s' "$TARGETS2") > /dev/null 2>&1
check "disable, targets surviving: enabled again first" "yes" "$(exists "$ALERTS_D/targets")"
_tn_shred() { :; }
run alerts_disable
check "disable: the targets file survives -> rc 1" "1 yes" "$RC $(has "$OUT" "which holds the monitor URLs; remove it by hand")"
check "disable: the timer is gone all the same" "no no false" "$(exists "$TIMER_F") $(exists "$UNIT_F") $(meta_val ENABLE_ALERTS)"
_tn_shred() { _real_tn_shred "$@"; }
alerts_disable >/dev/null 2>&1
check "disable again: the targets file gone" "no" "$(exists "$ALERTS_D/targets")"

# =============================================================================
# No monitor token anywhere in the output
# =============================================================================
for tok in "$TOK1" "$TOK2" "$TOK3" "$TOK4"; do
    check_lacks "no output holds the token ${tok:0:6}..." "$tok" "$(cat "$T/allout")"
done

finish
