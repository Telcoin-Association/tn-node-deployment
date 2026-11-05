#!/bin/bash
# =============================================================================
# lib/tn-heartbeat.sh -- the private-alerts heartbeat runner
#
# setup-alerts.sh installs this file as /usr/local/libexec/telcoin/tn-heartbeat
# (root 0755). telcoin-heartbeat.timer starts telcoin-heartbeat.service every
# ALERTS_INTERVAL seconds; the service runs this file once as a dynamic user
# (DynamicUser=yes) and it exits. Each run checks the local node and pushes one
# heartbeat, up or down with a short reason, to every target the operator set
# up: an Uptime Kuma push URL, a healthchecks.io ping URL or a JSON webhook.
#
# What systemd hands it:
#   the ALERTS_* variables      from /etc/telcoin/alerts/alerts.env
#                               (EnvironmentFile=): the node's service name, its
#                               local RPC URL, network, chain id, label, health
#                               port, interval and the stall, inactive and
#                               restart-grace limits in seconds
#   $CREDENTIALS_DIRECTORY/targets
#                               /etc/telcoin/alerts/targets (LoadCredential=):
#                               one "<kind> <url>" line per target, at most 5
#   $STATE_DIRECTORY/state      what the last run saw (StateDirectory=); written
#                               by this runner only, never sourced
#   /run/telcoin/heartbeat-service
#                               the node service's systemctl show, root 0644,
#                               rewritten before each run by the unit's root
#                               ExecStartPre= (a dynamic user cannot reach the
#                               system bus); read only, never sourced. When it
#                               is absent the runner asks systemctl itself.
#
# A target URL holds the monitor's token. It reaches curl only in a config file
# read from a process substitution (-K), never on a command line or in the
# environment of a child, and it is shown and logged only as kind@host.
#
# The checks run in this order and the first one that finds a problem decides
# the reason of a down heartbeat: the node's systemd service (the state file
# above, or systemctl show),
# the local RPC (eth_chainId, and the chain id when ALERTS_CHAIN_ID is set), the
# consensus header advancing within ALERTS_STALL_AFTER seconds, a committee
# member not left CvvInactive for ALERTS_INACTIVE_AFTER seconds, and the node's
# health endpoint not reporting the network unreachable. A restart of the node
# within ALERTS_RESTART_GRACE seconds counts as up.
#
# Output: one line per run on stdout with a journald priority prefix
# ("<6>up: CvvActive block 1234567 epoch 42 | 1 kuma@kuma.example.org ok 200"),
# a "<5>status" line when the status changes, "<4>every target failed" when no
# target took the heartbeat, "<3>config: ..." for a configuration error.
#
# Exit status: 0 when at least one target accepted the heartbeat, 1 when every
# target failed (the unit shows failed and the timer keeps firing), 2 for a
# configuration error: no targets credential, a bad targets line, a bad ALERTS_*
# value or no state directory. On 2 nothing is pushed and the state is not
# written.
#
# Sourcing: lib/alerts.sh sources this file for hb_target_normalize,
# hb_url_host, hb_header_number and hb_state_get. Sourcing defines the hb_*
# functions and the version only; hb_main runs only when the file is executed.
# This file sources nothing.
#
# Test hooks (tools/tests/heartbeat_test.sh): TN_HB_NOW (epoch seconds of the
# run), TN_HB_MONO (seconds since boot), TN_HB_SERVICE_STATE (the service-state
# file, default /run/telcoin/heartbeat-service), STATE_DIRECTORY,
# CREDENTIALS_DIRECTORY, and curl and systemctl stand-ins first on PATH.
#
# bash 3.2 safe; POSIX awk; no python.
# =============================================================================

# Version (tracked by update-scripts.sh). Plain, not readonly, so a second
# source of this file cannot trip on a readonly redefinition.
HEARTBEAT_VERSION="2.1.0"

# The keys the state file may hold, in the order the runner writes them.
HB_STATE_KEYS=(version last_run mono last_status status_since last_reason last_mode
    last_block last_epoch last_header header_since inactive_since started svc_since
    svc_restarts push_total push_ok push_1 push_2 push_3 push_4 push_5)

# hb_log PRIO MSG -- one journal line on stdout: <PRIO>MSG.
hb_log() {
    printf '<%s>%s\n' "${1:-6}" "${2:-}"
}

# hb_clean TEXT -- TEXT with every character outside [A-Za-z0-9 ._:/()=,+-]
# removed, cut to 200 characters. Node-supplied text goes through it before it
# reaches a message, the state or a push.
hb_clean() {
    local t
    t="$(printf '%s' "${1:-}" | LC_ALL=C tr -cd 'A-Za-z0-9 ._:/()=,+-')"
    printf '%s\n' "${t:0:200}"
}

# hb_url_host URL -- the host of URL with its port when one is given, IPv6
# brackets kept (kuma.example.org, 127.0.0.1:18080, [::1]:8080). Userinfo is
# dropped, and only the characters [A-Za-z0-9.:_-] and the brackets are kept,
# at most 253. kind@host is the only form in which a target is ever displayed.
hb_url_host() {
    local u="${1:-}" a
    case "$u" in
        *://*) u="${u#*://}" ;;
    esac
    a="${u%%[/?#]*}"
    a="${a##*@}"
    a="$(printf '%s' "$a" | LC_ALL=C sed 's/[^][A-Za-z0-9.:_-]//g')"
    printf '%s\n' "${a:0:253}"
}

# hb_target_normalize KIND URL [ALLOW_HTTP] -- check one target and print its
# normalised URL (rc 0; HB_URL holds it too, for a caller that cannot use a
# command substitution and still needs HB_ERR). On a refusal it prints nothing,
# sets HB_ERR to a reason that never holds the URL and returns 1. KIND is kuma,
# healthchecks or webhook. http:// is allowed for 127.0.0.1, [::1] and
# localhost, and for any host when ALLOW_HTTP is 1. A kuma URL is cut at its
# query (the Kuma UI shows .../api/push/<token>?status=up&msg=OK&ping=) and must
# end in /api/push/<token>; a healthchecks URL loses a trailing /, /fail,
# /start and /log and may hold neither a query nor a fragment (a down ping to
# <url>#x/fail would reach the up URL); a webhook URL is kept as given.
hb_target_normalize() {
    local kind="${1:-}" url="${2:-}" allow="${3:-0}" host bare rest path re
    HB_ERR=""
    HB_URL=""
    case "$kind" in
        kuma|healthchecks|webhook) ;;
        *)
            if [[ "$kind" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; then
                HB_ERR="unknown provider '${kind}' (kuma, healthchecks or webhook)"
            else
                HB_ERR="unknown provider (kuma, healthchecks or webhook)"
            fi
            return 1
            ;;
    esac
    if [[ -z "$url" ]]; then
        HB_ERR="empty url"
        return 1
    fi
    if [[ ${#url} -gt 512 ]]; then
        HB_ERR="url longer than 512 characters"
        return 1
    fi
    if [[ "$url" == *[[:space:][:cntrl:]\"\\]* ]]; then
        HB_ERR="url holds a quote, backslash, space or control character"
        return 1
    fi
    host="$(hb_url_host "$url")"
    case "$url" in
        https://*) ;;
        http://*)
            if [[ "$host" == \[* ]]; then
                bare="${host%%]*}]"
            else
                bare="${host%%:*}"
            fi
            if [[ "$bare" != "127.0.0.1" && "$bare" != "[::1]" && "$bare" != "localhost" \
                && "$allow" != "1" ]]; then
                HB_ERR="http needs --allow-http (the token travels in clear text)"
                return 1
            fi
            ;;
        *)
            HB_ERR="url must start with https://"
            return 1
            ;;
    esac
    if [[ -z "$host" ]]; then
        HB_ERR="url has no host"
        return 1
    fi
    case "$kind" in
        kuma)
            url="${url%%[?#]*}"
            while [[ "$url" == */ ]]; do
                url="${url%/}"
            done
            rest="${url#*://}"
            path=""
            if [[ "$rest" == */* ]]; then
                path="/${rest#*/}"
            fi
            re='/api/push/[A-Za-z0-9_-]{4,128}$'
            if [[ ! "$path" =~ $re ]]; then
                HB_ERR="kuma: not an /api/push/<token> URL"
                return 1
            fi
            ;;
        healthchecks)
            if [[ "$url" == *[?#]* ]]; then
                HB_ERR="healthchecks: a query string or fragment is not allowed"
                return 1
            fi
            url="${url%/}"
            url="${url%/fail}"
            url="${url%/start}"
            url="${url%/log}"
            ;;
    esac
    HB_URL="$url"
    printf '%s\n' "$url"
    return 0
}

# hb_header_number JSON -- the top-level "number" of the result object of a
# tn_latestConsensusHeader answer. One pass of POSIX awk over the text, aware of
# strings (braces inside a string do not count): the answer object is depth 1,
# the result object depth 2, and the sub_dag (serialised before the header's own
# number, with latest_execution_block.number inside) depth 3 or deeper; arrays
# count as a level too. rc 1, never a wrong number, when the braces do not
# balance, the result is not an object or its number is not a whole number.
hb_header_number() {
    local n
    n="$(printf '%s' "${1:-}" | LC_ALL=C awk '
{ s = s $0 }
END {
    gsub(/\r/, "", s)
    n = length(s)
    depth = 0; instr = 0; esc = 0; start = 0; key1 = ""; inres = 0
    seen = 0; num = ""; bad = 0
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (instr) {
            if (esc) { esc = 0; continue }
            if (c == "\\") { esc = 1; continue }
            if (c != "\"") continue
            instr = 0
            len = i - start
            if (depth == 1) key1 = substr(s, start, len)
            if (depth == 2 && inres && !seen && len == 6 && substr(s, start, len) == "number") {
                j = i + 1
                while (j <= n && (substr(s, j, 1) == " " || substr(s, j, 1) == "\t")) j++
                if (substr(s, j, 1) == ":") {
                    seen = 1
                    j++
                    while (j <= n && (substr(s, j, 1) == " " || substr(s, j, 1) == "\t")) j++
                    d = ""
                    while (j <= n && index("0123456789", substr(s, j, 1)) > 0) {
                        d = d substr(s, j, 1)
                        j++
                    }
                    t = substr(s, j, 1)
                    if (d != "" && length(d) <= 19 && (t == "," || t == "}" || t == " " || t == "\t"))
                        num = d
                }
            }
            continue
        }
        if (c == "\"") { instr = 1; start = i + 1; continue }
        if (c == "{" || c == "[") {
            depth++
            if (depth == 2) inres = (c == "{" && key1 == "result")
            continue
        }
        if (c == "}" || c == "]") {
            depth--
            if (depth < 0) { bad = 1; break }
            if (depth < 2) inres = 0
        }
    }
    if (bad || depth != 0 || instr || num == "") exit 1
    print num
}' 2>/dev/null)" || return 1
    [[ "$n" =~ ^[0-9]{1,19}$ ]] || return 1
    printf '%s\n' "$n"
}

# hb_hex2dec HEX -- a 0x-prefixed (or bare) hex number of up to 16 digits in
# decimal. rc 1 for anything else, or a value above the signed 64-bit range.
hb_hex2dec() {
    local h="${1:-}"
    h="${h#0[xX]}"
    [[ "$h" =~ ^[0-9a-fA-F]{1,16}$ ]] || return 1
    while [[ ${#h} -gt 1 && "$h" == 0* ]]; do
        h="${h#0}"
    done
    if [[ ${#h} -eq 16 && "$h" != [0-7]* ]]; then
        return 1
    fi
    printf '%s\n' "$((16#$h))"
}

# hb_json_str TEXT -- TEXT as a JSON string, quotes included: backslash and
# double quote escaped, control characters dropped.
hb_json_str() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//[[:cntrl:]]/}"
    printf '"%s"\n' "$s"
}

# hb_curl_why RC [rpc] -- one word for a curl exit status: refused (7), timeout
# (28), dns (6); for a push also tls (35, 51, 58, 60) and too-large (63), else
# curl-N; with "rpc" anything else is "curl N".
hb_curl_why() {
    case "${1:-}" in
        7) printf 'refused\n' ;;
        28) printf 'timeout\n' ;;
        6) printf 'dns\n' ;;
        *)
            if [[ "${2:-}" == "rpc" ]]; then
                printf 'curl %s\n' "${1:-0}"
                return 0
            fi
            case "${1:-}" in
                35|51|58|60) printf 'tls\n' ;;
                63) printf 'too-large\n' ;;
                *) printf 'curl-%s\n' "${1:-0}" ;;
            esac
            ;;
    esac
}

# _hb_state_re KEY -- set HB_RE to the regex a value of KEY must match; rc 1
# for a key the state file may not hold.
_hb_state_re() {
    case "${1:-}" in
        version) HB_RE='^[0-9]+\.[0-9]+\.[0-9]+$' ;;
        last_run|mono|status_since|header_since|started|push_total|push_ok)
            HB_RE='^[0-9]{1,19}$' ;;
        last_status) HB_RE='^(up|down)$' ;;
        last_reason) HB_RE='^[A-Za-z0-9 ._:/()=,+-]{0,200}$' ;;
        last_mode) HB_RE='^(CvvActive|CvvInactive|Observer|unknown)$' ;;
        last_block|last_epoch|last_header|inactive_since|svc_since)
            HB_RE='^[0-9]{0,19}$' ;;
        svc_restarts) HB_RE='^[0-9]{0,10}$' ;;
        push_1|push_2|push_3|push_4|push_5)
            HB_RE='^(kuma|healthchecks|webhook) (ok|fail) [0-9]{3}( [a-z0-9-]{1,16})? [][A-Za-z0-9.:_-]{1,253}$' ;;
        *) return 1 ;;
    esac
    return 0
}

# _hb_state_clear -- unset every HB_S_<key>.
_hb_state_clear() {
    local k
    for k in "${HB_STATE_KEYS[@]}"; do
        unset "HB_S_${k}"
    done
}

# _hb_state_read FILE -- read FILE into HB_S_<key>, one variable per line.
# rc 0 valid; 1 absent, unreadable or a symlink (never followed); 2 invalid: a
# line that is not key=value, an unknown or repeated key, a value failing its
# regex, or more than 64 lines. The file is only read, never sourced.
_hb_state_read() {
    local file="${1:-}" line key val n=0 seen=" "
    _hb_state_clear
    if [[ -z "$file" || -L "$file" || ! -f "$file" || ! -r "$file" ]]; then
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        if [[ $n -gt 64 || "$line" != *=* ]]; then
            _hb_state_clear
            return 2
        fi
        key="${line%%=*}"
        val="${line#*=}"
        if ! _hb_state_re "$key" || [[ "$seen" == *" ${key} "* ]] || [[ ! "$val" =~ $HB_RE ]]; then
            _hb_state_clear
            return 2
        fi
        seen="${seen}${key} "
        printf -v "HB_S_${key}" '%s' "$val"
    done < "$file"
    return 0
}

# hb_state_get FILE KEY -- print the value of KEY in the state file FILE. rc 1
# when KEY is absent, the file is missing, invalid or a symlink.
hb_state_get() {
    local key="${2:-}" v
    _hb_state_re "$key" || return 1
    _hb_state_read "${1:-}" || return 1
    v="HB_S_${key}"
    [[ -n "${!v+x}" ]] || return 1
    printf '%s\n' "${!v}"
}

# hb_state_load FILE -- read the state into HB_S_<key>; an invalid file is
# logged once and dropped, so the run starts from first-run defaults.
hb_state_load() {
    local rc=0
    _hb_state_read "${1:-}" || rc=$?
    if [[ $rc -eq 2 ]]; then
        hb_log 4 "state file invalid; starting fresh"
    fi
    return 0
}

# hb_state_save FILE -- write HB_S_<key> to FILE: a temp file beside it, then
# mv -f over it. A symlink at FILE is removed first, never followed. A value
# that fails its regex is left out, so the next run reads the default.
hb_state_save() {
    local file="${1:-}" tmp k v out=""
    tmp="${file%/*}/.state.tmp.$$"
    for k in "${HB_STATE_KEYS[@]}"; do
        v="HB_S_${k}"
        [[ -n "${!v+x}" ]] || continue
        _hb_state_re "$k" || continue
        if [[ "${!v}" =~ $HB_RE ]]; then
            out="${out}${k}=${!v}"$'\n'
        else
            hb_log 4 "state: ${k} left out (invalid value)"
        fi
    done
    rm -f "$tmp" 2>/dev/null
    if ! printf '%s' "$out" > "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        hb_log 4 "state not saved: cannot write ${tmp##*/}"
        return 1
    fi
    if [[ -L "$file" ]]; then
        rm -f "$file" 2>/dev/null
    fi
    if [[ -d "$file" ]] || ! mv -f "$tmp" "$file" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        hb_log 4 "state not saved: cannot replace the state file"
        return 1
    fi
    return 0
}

# _hb_set KEY VALUE -- set HB_S_<KEY>, the value hb_state_save writes for KEY.
_hb_set() {
    printf -v "HB_S_${1}" '%s' "${2:-}"
}

# _hb_age SINCE -- seconds from SINCE to this run's mono, never below 0.
_hb_age() {
    local a=0
    if [[ "${1:-}" =~ ^[0-9]{1,19}$ ]]; then
        a=$(( mono - 10#$1 ))
    fi
    if [[ $a -lt 0 ]]; then
        a=0
    fi
    printf '%s\n' "$a"
}

# _hb_down MSG -- record a down reason; only the first one counts.
_hb_down() {
    if [[ -z "$down_msg" ]]; then
        down_msg="${1:-down}"
    fi
}

# _hb_env_ok NAME REGEX [MIN MAX] -- the variable NAME matches REGEX (and as a
# number lies in MIN..MAX); else log the config error and return 1.
_hb_env_ok() {
    local name="$1" re="$2" v
    v="${!name-}"
    if [[ "$v" =~ $re ]]; then
        if [[ $# -lt 4 ]] || (( 10#$v >= $3 && 10#$v <= $4 )); then
            return 0
        fi
    fi
    hb_log 3 "config: ${name} invalid"
    return 1
}

# _hb_svc_field KEY VALUE -- keep one Key=Value line of systemctl show (or of
# the service-state file); any other key is ignored.
_hb_svc_field() {
    case "$1" in
        LoadState) s_load="$2" ;;
        ActiveState) s_active="$2" ;;
        SubState) s_sub="$2" ;;
        NRestarts) s_nrestarts="$2" ;;
        ActiveEnterTimestampMonotonic) s_aet="$2" ;;
        StateChangeTimestampMonotonic) s_sct="$2" ;;
    esac
}

# _hb_check_service -- step 1: the node's systemd unit. Its state comes from the
# file the unit's root ExecStartPre= wrote just before this run
# (TN_HB_SERVICE_STATE, default /run/telcoin/heartbeat-service), used only when
# it is a regular file, not a symlink, that this user can read and that is not
# empty. Otherwise the runner asks systemctl show itself, which works for the
# fixture tests and a static user but fails under DynamicUser= (no bus). Skipped
# (the RPC checks decide) when neither gives an answer.
_hb_check_service() {
    local out="" rc=0 line s_load="" s_active="" s_sub="" s_nrestarts="" s_aet="" s_sct=""
    local since="" age sf
    sf="${TN_HB_SERVICE_STATE:-/run/telcoin/heartbeat-service}"
    if [[ -f "$sf" && ! -L "$sf" && -r "$sf" ]]; then
        { out="$(< "$sf")"; } 2>/dev/null || out=""
    fi
    if [[ -z "$out" ]]; then
        out="$(systemctl show --no-pager -p LoadState -p ActiveState -p SubState -p NRestarts \
            -p ActiveEnterTimestampMonotonic -p StateChangeTimestampMonotonic "${svc_base}.service" \
            2>/dev/null)" || rc=$?
    fi
    if [[ $rc -ne 0 || -z "$out" ]]; then
        return 0
    fi
    while IFS= read -r line; do
        _hb_svc_field "${line%%=*}" "${line#*=}"
    done <<< "$out"
    if [[ "$s_load" == "not-found" ]]; then
        _hb_down "service ${svc_base} not found"
        return 0
    fi
    # ActiveEnterTimestampMonotonic is in microseconds; 0 means never active.
    if [[ "$s_aet" =~ ^[0-9]{1,19}$ ]] && (( 10#$s_aet >= 1000000 )); then
        since=$(( 10#$s_aet / 1000000 ))
    fi
    if [[ "$since" != "$svc_since" ]]; then
        started="$mono"
        header_since="$mono"
        inactive_since=""
        svc_since="$since"
    fi
    if [[ "$s_nrestarts" =~ ^[0-9]{1,10}$ ]]; then
        if [[ -n "$svc_restarts" ]] && (( 10#$s_nrestarts > 10#$svc_restarts )); then
            _hb_down "service ${svc_base} restarted after a failure (NRestarts $((10#$s_nrestarts)))"
        fi
        svc_restarts=$((10#$s_nrestarts))
    fi
    if [[ "$s_active" == "failed" || "$s_active" == "inactive" || "$s_sub" == auto-restart* ]]; then
        _hb_down "service ${svc_base} inactive (${s_sub:-dead})"
    elif [[ "$s_active" == "activating" || "$s_active" == "deactivating" ]]; then
        # How long the unit has been in its current state. ActiveEnterTimestamp
        # still names the previous activation while a restart is under way, so
        # StateChangeTimestamp measures the transition when systemd gives it.
        if [[ "$s_sct" =~ ^[0-9]{1,19}$ ]] && (( 10#$s_sct >= 1000000 )); then
            age="$(_hb_age "$(( 10#$s_sct / 1000000 ))")"
        elif [[ -n "$svc_since" ]]; then
            age="$(_hb_age "$svc_since")"
        else
            age="$(_hb_age "$started")"
        fi
        if [[ $age -lt $grace ]]; then
            up_msg="service ${svc_base} restarting (${s_active}, ${age}s)"
        else
            _hb_down "service ${svc_base} ${s_active} for ${age}s"
        fi
    elif [[ "$s_active" == "active" || "$s_active" == "reloading" ]]; then
        svc_active=1
    fi
    return 0
}

# _hb_rpc METHOD -- one JSON-RPC call to the local node. Sets r_rc (curl's
# exit status), r_code (HTTP status, 000 when none), r_time (time_total) and
# r_body (the answer on one line).
_hb_rpc() {
    local raw rest nl=$'\n'
    r_rc=0
    raw="$(curl -q -sS --connect-timeout 2 --max-time 5 --max-filesize 8388608 -X POST \
        -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"${1}\",\"params\":[],\"id\":1}" \
        -w '\n%{http_code}\n%{time_total}' --url "$rpc_url" 2>/dev/null)" || r_rc=$?
    r_time="${raw##*"$nl"}"
    rest=""
    if [[ "$raw" == *"$nl"* ]]; then
        rest="${raw%"$nl"*}"
    fi
    r_code="${rest##*"$nl"}"
    r_body=""
    if [[ "$rest" == *"$nl"* ]]; then
        r_body="${rest%"$nl"*}"
    fi
    r_body="${r_body//$'\r'/}"
    r_body="${r_body//$nl/}"
    if [[ ! "$r_code" =~ ^[0-9]{3}$ ]]; then
        r_code="000"
    fi
}

# _hb_rpc_ok -- the last _hb_rpc call got a 2xx answer.
_hb_rpc_ok() {
    [[ $r_rc -eq 0 && "$r_code" == 2[0-9][0-9] ]]
}

# _hb_ms SECONDS -- curl's time_total (0.012345) in whole milliseconds.
_hb_ms() {
    local t="${1:-}" i f=""
    [[ "$t" =~ ^[0-9]{1,9}(\.[0-9]+)?$ ]] || return 1
    i="${t%%.*}"
    if [[ "$t" == *.* ]]; then
        f="${t#*.}"
    fi
    f="${f}000"
    f="${f:0:3}"
    printf '%s\n' "$(( 10#$i * 1000 + 10#$f ))"
}

# _hb_check_rpc -- step 2: the local RPC answers eth_chainId with the right chain.
_hb_check_rpc() {
    local why="" re hex="" chain age
    _hb_rpc eth_chainId
    re='"result"[[:space:]]*:[[:space:]]*"0x([0-9a-fA-F]{1,16})"'
    if [[ $r_rc -ne 0 ]]; then
        why="$(hb_curl_why "$r_rc" rpc)"
    elif ! _hb_rpc_ok; then
        why="http ${r_code}"
    elif [[ "$r_body" =~ $re ]]; then
        hex="${BASH_REMATCH[1]}"
    else
        why="malformed"
    fi
    if [[ -n "$why" ]]; then
        if [[ $svc_active -eq 1 ]]; then
            if [[ -n "$svc_since" ]]; then
                age="$(_hb_age "$svc_since")"
            else
                age="$(_hb_age "$started")"
            fi
            if [[ $age -lt $grace ]]; then
                up_msg="starting: rpc not answering yet"
                return 0
            fi
        fi
        _hb_down "rpc $(hb_url_host "$rpc_url") not answering (${why})"
        return 0
    fi
    rpc_up=1
    ping="$(_hb_ms "$r_time")" || ping=""
    chain="$(hb_hex2dec "$hex")" || chain="0x${hex}"
    if [[ -n "$chain_id" && "$chain" != "$chain_id" ]]; then
        _hb_down "wrong chain: rpc reports ${chain}, expected ${chain_id}"
    fi
    return 0
}

# _hb_check_header -- step 3: the consensus header advances.
_hb_check_header() {
    local n="" re age
    _hb_rpc tn_latestConsensusHeader
    if _hb_rpc_ok; then
        # A node without the method (-32601) skips the check.
        re='"error"[[:space:]]*:[[:space:]]*[{][^}]*"code"[[:space:]]*:[[:space:]]*-32601([^0-9]|$)'
        if [[ "$r_body" =~ $re ]]; then
            return 0
        fi
        n="$(hb_header_number "$r_body")" || n=""
    fi
    if [[ -n "$n" && "$n" != "$last_header" ]]; then
        last_header="$n"
        header_since="$mono"
        return 0
    fi
    age="$(_hb_age "$header_since")"
    if [[ $age -ge $stall_after ]]; then
        if [[ -n "$last_header" ]]; then
            _hb_down "consensus stalled at header ${last_header} for ${age}s"
        else
            _hb_down "consensus header unreadable for ${age}s"
        fi
    fi
    return 0
}

# _hb_check_mode -- step 4: node mode (CvvInactive too long is down), block, epoch.
_hb_check_mode() {
    local re age
    _hb_rpc tn_nodeMode
    re='"result"[[:space:]]*:[[:space:]]*"(CvvActive|CvvInactive|Observer)"'
    if _hb_rpc_ok && [[ "$r_body" =~ $re ]]; then
        mode="${BASH_REMATCH[1]}"
    fi
    if [[ "$mode" == "CvvInactive" ]]; then
        if [[ -z "$inactive_since" ]]; then
            inactive_since="$mono"
        fi
        age="$(_hb_age "$inactive_since")"
        if [[ $age -ge $inactive_after ]]; then
            _hb_down "CvvInactive for ${age}s: committee member not voting"
        fi
    elif [[ "$mode" == "CvvActive" || "$mode" == "Observer" ]]; then
        inactive_since=""
    fi
    _hb_rpc eth_blockNumber
    re='"result"[[:space:]]*:[[:space:]]*"0x([0-9a-fA-F]{1,16})"'
    if _hb_rpc_ok && [[ "$r_body" =~ $re ]]; then
        block="$(hb_hex2dec "${BASH_REMATCH[1]}")" || block=""
    fi
    _hb_rpc tn_getCurrentEpochInfo
    re='"epoch"[[:space:]]*:[[:space:]]*([0-9]{1,10})'
    if _hb_rpc_ok && [[ "$r_body" =~ $re ]]; then
        epoch="$((10#${BASH_REMATCH[1]}))"
    fi
    return 0
}

# _hb_check_health -- step 5: the node's health endpoint. Not listening:
# skipped; 503: down; anything but 200: noted in the up message.
_hb_check_health() {
    local out rc=0
    out="$(curl -q -sS --connect-timeout 2 --max-time 5 --max-filesize 65536 -o /dev/null \
        -w '%{http_code}' --url "http://127.0.0.1:${health_port}/health/network" 2>/dev/null)" || rc=$?
    if [[ $rc -eq 7 ]]; then
        return 0
    fi
    if [[ $rc -eq 28 ]]; then
        health_note=" (health timeout)"
        return 0
    fi
    if [[ ! "$out" =~ ^[0-9]{3}$ ]]; then
        out="000"
    fi
    if [[ "$out" == "503" ]]; then
        _hb_down "health 503: node reports the network unreachable"
    elif [[ "$out" != "200" ]]; then
        health_note=" (health ${out})"
    fi
    return 0
}

# _hb_push I -- push the heartbeat to target I (0-based). Sets p_line (the log
# part), p_rec (the state record) and p_ok (1 when the target accepted it).
_hb_push() {
    local i="$1" kind url host raw rc=0 code body why="" nl=$'\n' re
    local -a opt
    kind="${t_kind[$i]}"
    url="${t_url[$i]}"
    host="${t_host[$i]}"
    case "$kind" in
        kuma)
            opt=(-G --data-urlencode "status=${status}" --data-urlencode "msg=${reason}")
            if [[ -n "$ping" ]]; then
                opt[${#opt[@]}]="--data-urlencode"
                opt[${#opt[@]}]="ping=${ping}"
            fi
            ;;
        healthchecks)
            if [[ "$status" == "down" ]]; then
                url="${url}/fail"
            fi
            opt=(--data-raw "${status}: ${reason}")
            ;;
        *)
            opt=(-H 'Content-Type: application/json' --data-binary "$webhook_json")
            ;;
    esac
    # The URL goes through -K: /proc/<pid>/cmdline is world-readable.
    raw="$(curl -q -sS --proto '=http,https' --connect-timeout 5 --max-time 10 \
        --max-filesize 65536 -A "tn-heartbeat/${HEARTBEAT_VERSION}" -w '\n%{http_code}' \
        "${opt[@]}" -K <(printf 'url = "%s"\n' "$url") 2>/dev/null)" || rc=$?
    code="${raw##*"$nl"}"
    body=""
    if [[ "$raw" == *"$nl"* ]]; then
        body="${raw%"$nl"*}"
    fi
    if [[ ! "$code" =~ ^[0-9]{3}$ ]]; then
        code="000"
    fi
    re='"ok"[[:space:]]*:[[:space:]]*false'
    if [[ $rc -ne 0 ]]; then
        why="$(hb_curl_why "$rc")"
    elif [[ "$code" != 2[0-9][0-9] ]]; then
        why="http"
    elif [[ "$kind" == "kuma" && "$body" =~ $re ]]; then
        why="body"
    fi
    p_ok=0
    if [[ -z "$why" ]]; then
        p_ok=1
        p_line="$((i + 1)) ${kind}@${host} ok ${code}"
        p_rec="${kind} ok ${code} ${host}"
    else
        p_line="$((i + 1)) ${kind}@${host} fail ${code} ${why}"
        p_rec="${kind} fail ${code} ${why} ${host}"
    fi
}

# hb_main -- one heartbeat run (see the header).
hb_main() {
    set -u
    umask 077
    LC_ALL=C
    export LC_ALL
    unset TN_BLS_PASSPHRASE 2>/dev/null || true

    local svc_base rpc_url network chain_id label health_port stall_after
    local inactive_after grace now mono up cred state_dir state_file line kind url n i
    local status reason changed prev_status prev_mono ok_count line_out p_line p_rec p_ok
    local status_since header_since inactive_since started svc_since svc_restarts last_header
    local push_total push_ok webhook_json prio
    local svc_active=0 rpc_up=0 ping="" mode="unknown"
    local block="" epoch="" health_note="" down_msg="" up_msg=""
    local r_rc=0 r_code="000" r_time="" r_body=""
    local -a t_kind t_url t_host

    _hb_env_ok ALERTS_SERVICE '^[A-Za-z0-9_.@-]{1,64}$' || return 2
    _hb_env_ok ALERTS_RPC_URL '^http://[][A-Za-z0-9.:-]{1,80}$' || return 2
    _hb_env_ok ALERTS_NETWORK '^[a-z]{0,16}$' || return 2
    _hb_env_ok ALERTS_CHAIN_ID '^[0-9]{0,10}$' || return 2
    _hb_env_ok ALERTS_LABEL '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' || return 2
    _hb_env_ok ALERTS_HEALTH_PORT '^[0-9]{1,5}$' || return 2
    _hb_env_ok ALERTS_INTERVAL '^[0-9]{1,5}$' 30 3600 || return 2
    _hb_env_ok ALERTS_STALL_AFTER '^[0-9]{1,6}$' || return 2
    _hb_env_ok ALERTS_INACTIVE_AFTER '^[0-9]{1,6}$' || return 2
    _hb_env_ok ALERTS_RESTART_GRACE '^[0-9]{1,5}$' 30 3600 || return 2
    svc_base="$ALERTS_SERVICE"
    rpc_url="$ALERTS_RPC_URL"
    network="${ALERTS_NETWORK:-}"
    chain_id="${ALERTS_CHAIN_ID:-}"
    if [[ -n "$chain_id" ]]; then
        chain_id=$((10#$chain_id))
    fi
    label="$ALERTS_LABEL"
    health_port=$((10#$ALERTS_HEALTH_PORT))
    stall_after=$((10#$ALERTS_STALL_AFTER))
    inactive_after=$((10#$ALERTS_INACTIVE_AFTER))
    grace=$((10#$ALERTS_RESTART_GRACE))

    now="${TN_HB_NOW:-}"
    if [[ ! "$now" =~ ^[0-9]{1,19}$ ]]; then
        now="$(date +%s)"
    fi
    now=$((10#$now))
    mono="${TN_HB_MONO:-}"
    if [[ ! "$mono" =~ ^[0-9]{1,19}$ ]]; then
        mono=""
        up=""
        if [[ -r /proc/uptime ]]; then
            read -r up _ < /proc/uptime || true
            mono="${up%%.*}"
        fi
        if [[ ! "$mono" =~ ^[0-9]{1,19}$ ]]; then
            mono="$now"
        fi
    fi
    mono=$((10#$mono))

    cred="${CREDENTIALS_DIRECTORY:-}/targets"
    if [[ -z "${CREDENTIALS_DIRECTORY:-}" || ! -f "$cred" || ! -r "$cred" ]]; then
        hb_log 3 "config: no targets credential"
        return 2
    fi
    n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ $n -ge 5 ]]; then
            hb_log 3 "config: targets credential holds more than 5 lines"
            return 2
        fi
        kind="${line%% *}"
        url=""
        if [[ "$line" == *" "* ]]; then
            url="${line#* }"
        fi
        if ! hb_target_normalize "$kind" "$url" 1 >/dev/null; then
            hb_log 3 "config: targets line $((n + 1)) invalid: ${HB_ERR}"
            return 2
        fi
        t_kind[$n]="$kind"
        t_url[$n]="$HB_URL"
        t_host[$n]="$(hb_url_host "$HB_URL")"
        n=$((n + 1))
    done < "$cred"
    if [[ $n -eq 0 ]]; then
        hb_log 3 "config: targets credential is empty"
        return 2
    fi

    state_dir="${STATE_DIRECTORY:-}"
    state_dir="${state_dir%%:*}"
    if [[ -z "$state_dir" || ! -d "$state_dir" ]]; then
        hb_log 3 "config: STATE_DIRECTORY invalid"
        return 2
    fi
    state_file="${state_dir%/}/state"
    hb_state_load "$state_file"
    prev_status="${HB_S_last_status-}"
    prev_mono="${HB_S_mono-}"
    status_since="${HB_S_status_since:-$mono}"
    header_since="${HB_S_header_since:-$mono}"
    started="${HB_S_started:-$mono}"
    inactive_since="${HB_S_inactive_since-}"
    last_header="${HB_S_last_header-}"
    svc_since="${HB_S_svc_since-}"
    svc_restarts="${HB_S_svc_restarts-}"
    push_total="${HB_S_push_total:-0}"
    push_ok="${HB_S_push_ok:-0}"
    # A monotonic clock lower than the last run's: the host rebooted.
    if [[ -n "$prev_mono" ]] && (( 10#$prev_mono > mono )); then
        header_since="$mono"
        started="$mono"
        status_since="$mono"
        if [[ -n "$inactive_since" ]]; then
            inactive_since="$mono"
        fi
    fi

    # Every step runs so the trackers and the pushed fields stay current; the
    # first down found is the reason. A restart inside the grace window (step
    # 1) or an RPC still starting (step 2) ends the checks as up, and the steps
    # after the RPC need it answering.
    _hb_check_service
    if [[ -z "$up_msg" ]]; then
        _hb_check_rpc
    fi
    if [[ $rpc_up -eq 1 ]]; then
        _hb_check_header
        _hb_check_mode
        _hb_check_health
    fi

    if [[ -n "$down_msg" ]]; then
        status="down"
        reason="$down_msg"
    else
        status="up"
        if [[ -n "$up_msg" ]]; then
            reason="$up_msg"
        else
            reason=""
            if [[ "$mode" != "unknown" ]]; then
                reason="$mode"
            fi
            if [[ -n "$block" ]]; then
                reason="${reason:+$reason }block ${block}"
            fi
            if [[ -n "$epoch" ]]; then
                reason="${reason:+$reason }epoch ${epoch}"
            fi
            if [[ -z "$reason" ]]; then
                reason="rpc answering"
            fi
            reason="${reason}${health_note}"
        fi
    fi
    reason="$(hb_clean "$reason")"
    changed="false"
    if [[ "$prev_status" != "$status" ]]; then
        changed="true"
        status_since="$mono"
    fi

    webhook_json="{\"status\":\"${status}\",\"reason\":$(hb_json_str "$reason"),\"node\":$(hb_json_str "$label"),\"network\":$(hb_json_str "$network"),\"mode\":\"${mode}\",\"block\":${block:-null},\"epoch\":${epoch:-null},\"ts\":${now},\"changed\":${changed}}"

    _hb_state_clear
    ok_count=0
    line_out=""
    i=0
    while [[ $i -lt $n ]]; do
        _hb_push "$i"
        if [[ $p_ok -eq 1 ]]; then
            ok_count=$((ok_count + 1))
        fi
        line_out="${line_out:+$line_out, }${p_line}"
        _hb_set "push_$((i + 1))" "$p_rec"
        i=$((i + 1))
    done
    push_total=$(( 10#$push_total + n ))
    push_ok=$(( 10#$push_ok + ok_count ))

    if [[ "$changed" == "true" ]]; then
        hb_log 5 "status ${prev_status:-none} -> ${status}: ${reason}"
    fi
    prio=6
    if [[ "$status" == "down" ]]; then
        prio=4
    fi
    hb_log "$prio" "${status}: ${reason} | ${line_out}"
    if [[ $ok_count -eq 0 ]]; then
        hb_log 4 "every target failed"
    fi

    _hb_set version "$HEARTBEAT_VERSION"
    _hb_set last_run "$now"
    _hb_set mono "$mono"
    _hb_set last_status "$status"
    _hb_set status_since "$status_since"
    _hb_set last_reason "$reason"
    _hb_set last_mode "$mode"
    _hb_set last_block "$block"
    _hb_set last_epoch "$epoch"
    _hb_set last_header "$last_header"
    _hb_set header_since "$header_since"
    _hb_set inactive_since "$inactive_since"
    _hb_set started "$started"
    _hb_set svc_since "$svc_since"
    _hb_set svc_restarts "$svc_restarts"
    _hb_set push_total "$push_total"
    _hb_set push_ok "$push_ok"
    hb_state_save "$state_file" || true

    if [[ $ok_count -eq 0 ]]; then
        return 1
    fi
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    hb_main "$@"
    exit $?
fi
