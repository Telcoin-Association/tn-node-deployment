#!/usr/bin/env bash
# =============================================================================
# V3 independent harness, library level, for the OBS package (ingest token file,
# env file, units, config, migration, rotation, shred, status, vendoring).
# Written from tasks/spec-fup-OBS.md before reading the implementer's checkpoint.
#
#   bash tasks/verify-fup/V3/v3_obs_lib_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tasks/verify-fup/V3/v3_obs_lib_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tasks/verify-fup/V3/v3_obs_lib_test.sh
#
# V3_REPO=<tree> runs it against another checkout (the mutation runs).
# TN_UPSTREAM_ALLOY_CONFIG=<upstream config.alloy> adds the sync-note diff.
# V3_CLAIMED_SHA=<sha256> checks observability/config.alloy against a claimed hash.
# =============================================================================
set -u
V3_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${V3_REPO:-$(cd "$V3_DIR/../../.." && pwd)}"
# shellcheck source=/dev/null
. "$REPO/tools/tests/lib.sh"
T="$TN_TEST_TMP"
export TN_ROOT_PREFIX="$T/root"
export TN_UPDATE_LOCK_FILE="$T/update.lock"
RP="$TN_ROOT_PREFIX"
REC="$V3_DIR/records"; [ -z "${V3_REPO:-}" ] || REC="$T"   # a mutation run never touches the records
mkdir -p "$RP/etc/telcoin" "$RP/etc/systemd/system" "$RP/var/lib/telcoin" "$RP/var/log/telcoin/node" "$T/bin" "$T/grp" "$T/save"
META="$RP/etc/telcoin/.node-meta"
export V3_SCTL_LOG="$T/systemctl.log" V3_DOCKER_LOG="$T/docker.log" V3_ARGV_LOG="$T/argv.log"
export V3_ACTIVE_SEQ="$T/active.seq" V3_RESTART_SEQ="$T/restart.seq"
: > "$V3_SCTL_LOG"; : > "$V3_DOCKER_LOG"; : > "$V3_ARGV_LOG"; : > "$V3_ACTIVE_SEQ"; : > "$V3_RESTART_SEQ"

# --- stubs ---------------------------------------------------------------------
cat > "$T/bin/systemctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$V3_SCTL_LOG"
pop() { f="$1"; if [ -s "$f" ]; then v="$(head -n 1 "$f")"; tail -n +2 "$f" > "$f.n"; mv "$f.n" "$f"; printf '%s' "$v"; fi; }
case "$1" in
  restart) r="$(pop "$V3_RESTART_SEQ")"; exit "${r:-${V3_RESTART_RC:-0}}" ;;
  is-active)
    s="$(pop "$V3_ACTIVE_SEQ")"; s="${s:-${V3_ACTIVE_DEFAULT:-active}}"
    [ "$2" = "--quiet" ] || printf '%s\n' "$s"
    [ "$s" = active ] && exit 0; exit 3 ;;
  list-unit-files) [ "${V3_LISTED:-0}" = 1 ] && printf 'telcoin-alloy.service enabled enabled\n'; exit 0 ;;
  *) exit 0 ;;
esac
STUB
cat > "$T/bin/docker" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$V3_DOCKER_LOG"
exit 0
STUB
cat > "$T/bin/getent" <<'STUB'
#!/bin/sh
case "$1 $2" in
  "group telcoin-alloy") [ "${V3_NO_ALLOY_GROUP:-0}" = 1 ] && exit 2; echo "telcoin-alloy:x:${V3_ALLOY_GID:-990}:"; exit 0 ;;
  "passwd telcoin-alloy") [ "${V3_NO_ALLOY_USER:-0}" = 1 ] && exit 2; echo "telcoin-alloy:x:990:${V3_ALLOY_GID:-990}::/var/lib/telcoin-alloy:/usr/sbin/nologin"; exit 0 ;;
  "group telcoin-log") echo "telcoin-log:x:997:"; exit 0 ;;
esac
exit 2
STUB
printf '#!/bin/sh\nprintf "useradd %%s\\n" "$*" >> "$V3_ARGV_LOG"\nexit 1\n' > "$T/bin/useradd"
printf '#!/bin/sh\nprintf "chown %%s\\n" "$*" >> "$V3_ARGV_LOG"\nexit 0\n' > "$T/bin/chown"
printf '#!/bin/sh\nexit 7\n' > "$T/bin/curl"
printf '#!/bin/sh\necho v3host\n' > "$T/bin/hostname"
# argv-logging wrappers around the real tools (resolved before the stub dir is on PATH)
for n in cat head tail sed stat mktemp chmod mv rm shred install cut tr awk grep sort date find id dirname basename sha256sum wc env tee xargs logger printf echo ln cp touch; do
    real="$(type -P "$n" 2>/dev/null || true)"
    [ -n "$real" ] || continue
    printf '#!/bin/sh\n{ printf "%%s" "${0##*/}"; for a in "$@"; do printf " %%s" "$a"; done; printf "\\n"; } >> "${V3_ARGV_LOG:-/dev/null}"\nexec %s "$@"\n' "$real" > "$T/bin/$n"
done
chmod +x "$T/bin/"*
PATH="$T/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
hash -r

printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nINSTALL_METHOD=binary\nDATA_DIR=%s\nENABLE_OBSERVABILITY=true\nENABLE_METRICS=true\nNODE_LOG_DIR=%s\nREGION=eu\n' \
    "$RP/var/lib/telcoin" "$RP/var/log/telcoin/node" > "$META"

eval "$(tn_test_source_common)"
set +e

OBS_ETC_DIR="$RP/etc/telcoin/alloy"
OBS_DATA_DIR="$RP/var/lib/telcoin-alloy"
mkdir -p "$OBS_ETC_DIR" "$OBS_DATA_DIR"
TOKF="$OBS_ETC_DIR/ingest-token"
ENVF="$OBS_ETC_DIR/telcoin-alloy.env"
CONF="$OBS_ETC_DIR/config.alloy"
UNITF="$RP/etc/systemd/system/telcoin-alloy.service"
WRITES="$T/writes"; : > "$WRITES"
V3_TRF_CALLS=0
V3_REAL_STAT="$(PATH=/usr/bin:/bin type -P stat)"
sleep() { :; }
tn_committee_down_guard() { printf 'GUARD\n' >> "$V3_SCTL_LOG"; return 0; }
tn_wait_restart_window() { printf 'WAIT\n' >> "$V3_SCTL_LOG"; return 0; }
_gkey() { printf '%s' "$1" | tr '/' '_'; }
# tn_write_root_file stand-in: records DEST MODE GROUP and the kind of stdin (pipe or
# file), counts calls in this shell (a pipe's subshell loses the count), writes the file.
tn_write_root_file() {
    local kind=other
    V3_TRF_CALLS=$((V3_TRF_CALLS + 1))
    if [ -p /dev/stdin ]; then kind=pipe; elif [ -f /dev/stdin ]; then kind=file; fi
    printf '%s %s %s %s\n' "$1" "$2" "${3:-root}" "$kind" >> "$WRITES"
    case "$1" in
        *"${V3_TRF_FAIL:-//never//}"*) cat > /dev/null; return 2 ;;
    esac
    [ -d "${1%/*}" ] || { cat > /dev/null; return 1; }
    cat > "$1.v3tmp" && chmod "$2" "$1.v3tmp" && mv -f "$1.v3tmp" "$1" || return 2
    printf '%s\n' "${3:-root}" > "$T/grp/$(_gkey "$1")"
    return 0
}
grp_of() { cat "$T/grp/$(_gkey "$1")" 2>/dev/null; }
stat() {
    local last=""
    for last in "$@"; do :; done
    if [ -n "${V3_STAT_OVERRIDE:-}" ] && [ "$last" = "$TOKF" ]; then
        printf '%s\n' "$V3_STAT_OVERRIDE"
        return 0
    fi
    "$V3_REAL_STAT" "$@"
}
yn() { if "$@"; then echo yes; else echo no; fi; }
lines_of() { grep -c -- "$1" "$2" 2>/dev/null || true; }
reset_fixture() {
    rm -f "$TOKF" "$ENVF" "$CONF" "$UNITF" "$OBS_ETC_DIR"/.tn.* 2>/dev/null
    : > "$WRITES"; : > "$V3_SCTL_LOG"; : > "$V3_DOCKER_LOG"; : > "$V3_ARGV_LOG"; : > "$V3_ACTIVE_SEQ"; : > "$V3_RESTART_SEQ"
    OBS_TOKEN_MOVED_SAID=false
    unset V3_TRF_FAIL V3_STAT_OVERRIDE V3_NO_ALLOY_GROUP OBS_PUSH_URL OBS_METRICS_PUSH_URL 2>/dev/null
    NETWORK=testnet
}
meta_put() { # meta_put KEY VAL: replace or add
    local k="$1" v="$2"
    grep -v "^${k}=" "$META" > "$META.n"; printf '%s=%s\n' "$k" "$v" >> "$META.n"; mv -f "$META.n" "$META"
}
OLDTOK="old-token-0123456789abcdefOLD"
NEWTOK="new-token-0123456789abcdefNEW"
NETWORK=testnet
ADVERTISED_NAME=v3node

# =============================================================================
# 1. token file: path, mode, group, content; written through tn_write_root_file
# =============================================================================
reset_fixture
check "token path" "$RP/etc/telcoin/alloy/ingest-token" "$(obs_token_file)"
check "token path (production)" "/etc/telcoin/alloy/ingest-token" "$(OBS_ETC_DIR=/etc/telcoin/alloy obs_token_file)"
n0=$V3_TRF_CALLS
obs_write_token_file "$NEWTOK" > "$T/o" 2>&1; rc=$?
cat "$V3_ARGV_LOG" "$V3_SCTL_LOG" "$V3_DOCKER_LOG" > "$T/argv.snap"
check_rc "token write: rc 0" 0 "$rc"
check "token write: through tn_write_root_file in this shell (no pipe subshell)" "$((n0 + 1))" "$V3_TRF_CALLS"
check "token write: DEST MODE GROUP" "$TOKF 0640 telcoin-alloy" "$(grep "^$TOKF " "$WRITES" | tail -n 1 | cut -d' ' -f1-3)"
check "token write: stdin is a pipe (process substitution), not a here-string temp file" "pipe" "$(grep "^$TOKF " "$WRITES" | tail -n 1 | cut -d' ' -f4)"
check "token file: one line, the token" "$NEWTOK" "$(cat "$TOKF")"
check "token file: exactly one line" "1" "$(wc -l < "$TOKF" | tr -d ' ')"
check "token file: mode 640 (as written)" "640" "$("$V3_REAL_STAT" -c %a "$TOKF")"
check_lacks "token never in any argv" "$NEWTOK" "$(cat "$T/argv.snap")"

# adversarial tokens through obs_rotate_token's trim + write path (_obs_trim_token + write)
long="$(printf 'k%.0s' $(seq 1 4096) 2>/dev/null)"
[ "${#long}" -eq 4096 ] || long="$(awk 'BEGIN{for(i=0;i<4096;i++) printf "k"}')"
i=0
for tok in "abc def ghi jkl mno pqr" "-n-leading-dash-token-0123" "%s%d%%-percent-token-0123" "quo\"te'token-0123456789ab" "$long"; do
    i=$((i + 1))
    reset_fixture
    t="$(_obs_trim_token "$tok")"
    obs_write_token_file "$t" > "$T/o" 2>&1
    cat "$V3_ARGV_LOG" > "$T/argv.snap"
    check "adversarial token $i: file holds it exactly" "$tok" "$(cat "$TOKF")"
    check_lacks "adversarial token $i: never in argv" "$tok" "$(cat "$T/argv.snap")"
done
check "trim: surrounding whitespace dropped" "abc" "$(_obs_trim_token "  abc	 ")"
check "trim: only whitespace -> empty" "" "$(_obs_trim_token "   	 ")"
_obs_token_warn "abc def ghi jkl mno pqr" > "$T/o" 2>&1
check "warn: internal whitespace said" "yes" "$(yn grep -q 'internal whitespace' "$T/o")"
check_lacks "warn: never prints the token" "abc def" "$(cat "$T/o")"

# =============================================================================
# 2. env file: no token, the two host variables, CREDENTIALS_DIRECTORY for docker only
# =============================================================================
reset_fixture
( ENABLE_METRICS=true; _obs_write_env_file ) > "$T/o" 2>&1; rc=$?
check_rc "env file: rc 0" 0 "$rc"
E="$(cat "$ENVF")"
check_lacks "env file: no OBS_INGEST_TOKEN" "OBS_INGEST_TOKEN" "$E"
check_has "env file: OBS_PUSH_HOST" "OBS_PUSH_HOST=obs.adiri.telcoin.network" "$E"
check_has "env file: OBS_METRICS_PUSH_HOST" "OBS_METRICS_PUSH_HOST=obs.adiri.telcoin.network" "$E"
check_has "env file: OBS_PUSH_URL" "OBS_PUSH_URL=$OBS_PUSH_URL_TESTNET" "$E"
check_lacks "env file (native): no CREDENTIALS_DIRECTORY" "CREDENTIALS_DIRECTORY" "$E"
check "env file: written 0600 via tn_write_root_file" "$ENVF 0600 root" "$(grep "^$ENVF " "$WRITES" | tail -n 1 | cut -d' ' -f1-3)"
( ENABLE_METRICS=false; _obs_write_env_file ) > "$T/o" 2>&1
check_lacks "env file logs-only: no metrics host" "OBS_METRICS_PUSH_HOST" "$(cat "$ENVF")"
meta_put INSTALL_METHOD docker
( ENABLE_METRICS=true; _obs_write_env_file ) > "$T/o" 2>&1
check_has "env file (docker): CREDENTIALS_DIRECTORY" "CREDENTIALS_DIRECTORY=/run/credentials/telcoin-alloy" "$(cat "$ENVF")"
check_lacks "env file (docker): no token" "OBS_INGEST_TOKEN" "$(cat "$ENVF")"
meta_put INSTALL_METHOD binary

# host extraction (TLS server name) for overrides with ports, no path, userinfo, IPv6
check "host: testnet URL" "obs.adiri.telcoin.network" "$(obs_url_host "$OBS_PUSH_URL_TESTNET")"
check "host: port + path" "d.example" "$(obs_url_host https://d.example:8443/loki/api/v1/push)"
check "host: no path" "d.example" "$(obs_url_host https://d.example)"
check "host: port, no path" "d.example" "$(obs_url_host https://d.example:3100)"
check "host: userinfo" "d.example" "$(obs_url_host https://u:p@d.example:3100/x)"
check "host: IPv6 literal" "::1" "$(obs_url_host 'https://[::1]:3100/x')"
check "host: query only" "d.example" "$(obs_url_host 'https://d.example?x=1')"
check "host: empty" "" "$(obs_url_host '')"
check "devnet override with a port: effective URL keeps the port" "https://d.example:8443/push" "$(NETWORK=devnet OBS_PUSH_URL=https://d.example:8443/push obs_effective_push_url)"
reset_fixture
( NETWORK=devnet; OBS_PUSH_URL=https://d.example:8443/push; OBS_METRICS_PUSH_URL=https://m.example:9443; ENABLE_METRICS=true; _obs_write_env_file ) > "$T/o" 2>&1
check_has "devnet env: push host without the port" "OBS_PUSH_HOST=d.example" "$(cat "$ENVF")"
check_has "devnet env: metrics host without the port (URL without a path)" "OBS_METRICS_PUSH_HOST=m.example" "$(cat "$ENVF")"

# =============================================================================
# 3. native unit and docker unit text (production paths)
# =============================================================================
NU="$(OBS_ETC_DIR=/etc/telcoin/alloy OBS_DATA_DIR=/var/lib/telcoin-alloy obs_alloy_unit_text /usr/bin/alloy /etc/telcoin/alloy/telcoin-alloy.env telcoin-log /var/lib/telcoin /srv/tn)"
check_has "native unit: LoadCredential" "LoadCredential=ingest-token:/etc/telcoin/alloy/ingest-token" "$NU"
check_has "native unit: LimitCORE=0" "LimitCORE=0" "$NU"
check "native unit: InaccessiblePaths names the .cred with a - prefix" "yes" "$(yn grep -q '^InaccessiblePaths=.* -/etc/telcoin/bls-passphrase.cred\( \|$\)' <<< "$NU")"
check_lacks "native unit: no credstore" "credstore" "$NU"
check_lacks "native unit: no token variable" "OBS_INGEST_TOKEN" "$NU"
check_lacks "native unit: no Environment= line" "Environment=OBS" "$NU"
printf '%s\n' "$NU" > "$REC/native.unit.rendered"
DU="$(OBS_ETC_DIR=/etc/telcoin/alloy OBS_DATA_DIR=/var/lib/telcoin-alloy obs_alloy_docker_unit_text /etc/telcoin/alloy/telcoin-alloy.env /var/lib/telcoin/logs 990)"
DX="$(grep '^ExecStart=' <<< "$DU")"
check "docker ExecStart: token file mounted read-only at the fixed path" "yes" "$(yn grep -qF -- ' --mount type=bind,source=/etc/telcoin/alloy/ingest-token,target=/run/credentials/telcoin-alloy/ingest-token,readonly ' <<< "$DX")"
check "docker ExecStart: --group-add gid" "yes" "$(yn grep -qF -- ' --group-add 990 ' <<< "$DX")"
check "docker ExecStart: --ulimit core=0" "yes" "$(yn grep -qF -- ' --ulimit core=0 ' <<< "$DX")"
check "docker ExecStart: --env-file" "yes" "$(yn grep -qF -- ' --env-file /etc/telcoin/alloy/telcoin-alloy.env ' <<< "$DX")"
check "docker ExecStart: no -e" "no" "$(yn grep -qE -- ' (-e|--env) ' <<< "$DX")"
check_lacks "docker unit: no token variable" "OBS_INGEST_TOKEN" "$DU"
check_has "docker unit: LimitCORE=0" "LimitCORE=0" "$DU"
printf '%s\n' "$DU" > "$REC/docker.unit.rendered"
# render-time gid when the telcoin-alloy group is absent
reset_fixture
meta_put INSTALL_METHOD docker
( export V3_NO_ALLOY_GROUP=1; obs_run_alloy_docker /srv/logs ) > "$T/o" 2>&1; rc=$?
check_rc "docker unit: no telcoin-alloy group -> rc 1" 1 "$rc"
check "docker unit: no group -> no unit written" "no" "$(yn test -e "$UNITF")"
check "docker unit: no group -> said" "yes" "$(yn grep -q 'no telcoin-alloy group' "$T/o")"
( export V3_ALLOY_GID=4242; obs_run_alloy_docker /srv/logs ) > "$T/o" 2>&1
check "docker unit: the host group's gid goes into --group-add" "yes" "$(yn grep -qF -- '--group-add 4242 ' "$UNITF")"
meta_put INSTALL_METHOD binary

# =============================================================================
# 4. rendered config: bearer_token_file + tls_config TLS13, per pipeline combination
# =============================================================================
BTF='bearer_token_file = sys.env("CREDENTIALS_DIRECTORY") + "/ingest-token"'
render() { ( ENABLE_OBSERVABILITY="$1"; ENABLE_METRICS="$2"; obs_write_config_alloy "$T/r.alloy" ) > "$T/o" 2>&1; grep -v '^[[:space:]]*//' "$T/r.alloy"; }
for src in vendored fallback; do
    if [ "$src" = fallback ]; then OBS_CONFIG_SRC_SAVE="$OBS_CONFIG_SRC"; OBS_CONFIG_SRC="$T/absent.alloy"; fi
    C="$(render true true)"
    check "$src both: bearer_token_file twice" "2" "$(grep -cF "$BTF" <<< "$C")"
    check "$src both: TLS13 twice" "2" "$(grep -c 'min_version *= *"TLS13"' <<< "$C")"
    check "$src both: logs server_name" "1" "$(grep -c 'server_name *= *sys.env("OBS_PUSH_HOST")' <<< "$C")"
    check "$src both: metrics server_name" "1" "$(grep -c 'server_name *= *sys.env("OBS_METRICS_PUSH_HOST")' <<< "$C")"
    check_lacks "$src both: no bearer_token from env" 'OBS_INGEST_TOKEN' "$C"
    check "$src both: no plain bearer_token" "0" "$(grep -c 'bearer_token *=' <<< "$C")"
    C="$(render true false)"
    check "$src logs-only: one bearer_token_file" "1" "$(grep -cF "$BTF" <<< "$C")"
    check "$src logs-only: tls_config in loki.write" "yes" "$(yn awk '/^loki.write/{f=1} f&&/tls_config/{t=1} f&&/min_version *= *"TLS13"/&&t{ok=1} END{exit !ok}' <<< "$C")"
    check "$src logs-only: no metrics" "0" "$(grep -c 'prometheus.remote_write' <<< "$C")"
    C="$(render false true)"
    check "$src metrics-only: one bearer_token_file" "1" "$(grep -cF "$BTF" <<< "$C")"
    check "$src metrics-only: tls_config in remote_write" "yes" "$(yn awk '/^prometheus.remote_write/{f=1} f&&/tls_config/{t=1} f&&/min_version *= *"TLS13"/&&t{ok=1} END{exit !ok}' <<< "$C")"
    check "$src metrics-only: no loki.write" "0" "$(grep -c '^loki.write' <<< "$C")"
    if [ "$src" = fallback ]; then OBS_CONFIG_SRC="$OBS_CONFIG_SRC_SAVE"; fi
done
# fallback endpoint blocks render the same as the vendored file's (whitespace-normalised)
endpoints() { awk '/^(loki\.write|prometheus\.remote_write)/{f=1} f{print} f&&/^}/{f=0}' "$1" | sed -e 's://.*$::' -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//' | grep -v '^$'; }
_obs_alloy_fallback > "$T/fb.alloy"
check "fallback endpoint blocks == vendored endpoint blocks" "$(endpoints "$REPO/observability/config.alloy")" "$(endpoints "$T/fb.alloy")"
func_norm() { sed -n '/^local\.file_match/,$p' "$1" | sed -e 's://.*$::' -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//' | grep -v '^$'; }
check "fallback functional body == vendored (comments/whitespace ignored)" "$(func_norm "$REPO/observability/config.alloy")" "$(func_norm "$T/fb.alloy")"
# vendored vs upstream (the sync-note diff) and the hash
if [ -n "${TN_UPSTREAM_ALLOY_CONFIG:-}" ] && [ -r "$TN_UPSTREAM_ALLOY_CONFIG" ]; then
    check "sync note: from local.file_match to EOF identical to upstream" "" "$(diff <(sed -n '/^local\.file_match/,$p' "$TN_UPSTREAM_ALLOY_CONFIG") <(sed -n '/^local\.file_match/,$p' "$REPO/observability/config.alloy"))"
else
    skip "sync note diff" "TN_UPSTREAM_ALLOY_CONFIG not set"
fi
SHA="$(sha256sum "$REPO/observability/config.alloy" | cut -d' ' -f1)"
printf '%s\n' "$SHA" > "$T/sha"
if [ -n "${V3_CLAIMED_SHA:-}" ]; then
    check "sha256(observability/config.alloy) equals the claimed value" "$V3_CLAIMED_SHA" "$SHA"
else
    skip "claimed sha256" "V3_CLAIMED_SHA not set (computed $SHA)"
fi

# =============================================================================
# 5. migration (enable, partial disable, rotate), once per run; obs_existing_token order
# =============================================================================
reset_fixture
printf 'TN_NODE=x\nOBS_PUSH_URL=%s\nOBS_INGEST_TOKEN=%s\n' "$OBS_PUSH_URL_TESTNET" "$OLDTOK" > "$ENVF"
check "existing token: legacy env line when no token file" "$OLDTOK" "$(obs_existing_token)"
( _obs_write_env_file; _obs_write_env_file ) > "$T/o" 2>&1
check "migration: token file gets the legacy value" "$OLDTOK" "$(cat "$TOKF" 2>/dev/null)"
check "migration: token file 0640 telcoin-alloy" "$TOKF 0640 telcoin-alloy" "$(grep "^$TOKF " "$WRITES" | head -n 1 | cut -d' ' -f1-3)"
check_lacks "migration: env file rewritten without the token" "OBS_INGEST_TOKEN" "$(cat "$ENVF")"
check "migration: said once per run" "1" "$(grep -c 'no longer holds the ingest token' "$T/o")"
check_lacks "migration: message lacks the token" "$OLDTOK" "$(cat "$T/o")"
check "existing token: the token file first" "$OLDTOK" "$(obs_existing_token)"
printf '%s\n' "$NEWTOK" > "$TOKF"
printf 'OBS_INGEST_TOKEN=%s\n' "$OLDTOK" >> "$ENVF"
check "existing token: token file beats the legacy line" "$NEWTOK" "$(obs_existing_token)"
( _obs_write_env_file ) > "$T/o" 2>&1
check "migration: an existing token file is not overwritten by the legacy value" "$NEWTOK" "$(cat "$TOKF")"
: > "$TOKF"; printf 'OBS_INGEST_TOKEN=%s\n' "$OLDTOK" > "$ENVF"
check "existing token: empty token file -> legacy line" "$OLDTOK" "$(obs_existing_token)"
# two legacy lines
reset_fixture
printf 'OBS_INGEST_TOKEN=first-legacy-0123456789\nOBS_INGEST_TOKEN=second-legacy-0123456789\n' > "$ENVF"
( _obs_write_env_file ) > "$T/o" 2>&1
check "two legacy lines: the first is moved" "first-legacy-0123456789" "$(cat "$TOKF" 2>/dev/null)"
check "two legacy lines: neither stays" "0" "$(lines_of OBS_INGEST_TOKEN "$ENVF")"
# env file missing entirely
reset_fixture
( _obs_write_env_file ) > "$T/o" 2>&1; rc=$?
check_rc "no env file: rc 0" 0 "$rc"
check "no env file: no token file invented" "no" "$(yn test -e "$TOKF")"
check "no env file: no migration message" "0" "$(grep -c 'no longer holds' "$T/o")"
check "existing token: none" "" "$(obs_existing_token)"
# legacy migration when the token write fails
reset_fixture
printf 'OBS_INGEST_TOKEN=%s\n' "$OLDTOK" > "$ENVF"
( V3_TRF_FAIL=ingest-token; _obs_write_env_file ) > "$T/o" 2>&1; rc=$?
check_rc "migration: token write fails -> rc 1" 1 "$rc"
check "migration: token write fails -> env file keeps the token (not lost)" "1" "$(lines_of OBS_INGEST_TOKEN "$ENVF")"

# partial disable migrates
seed_native() { # seed_native TOKEN-IN-FILE|"" LEGACY|"": an installed native shipper
    reset_fixture
    meta_put INSTALL_METHOD binary; meta_put ENABLE_OBSERVABILITY true; meta_put ENABLE_METRICS true
    ( ENABLE_OBSERVABILITY=true; ENABLE_METRICS=true; obs_render_config_alloy ) > /dev/null 2>&1
    obs_alloy_unit_text /usr/bin/alloy "$ENVF" telcoin-log > "$UNITF"
    printf 'TN_NODE=v3node\nOBS_PUSH_URL=%s\n' "$OBS_PUSH_URL_TESTNET" > "$ENVF"
    [ -z "$2" ] || printf 'OBS_INGEST_TOKEN=%s\n' "$2" >> "$ENVF"
    [ -z "$1" ] || printf '%s\n' "$1" > "$TOKF"
    : > "$WRITES"; : > "$V3_SCTL_LOG"; : > "$V3_ARGV_LOG"
}
seed_native "" "$OLDTOK"
( obs_disable_metrics ) > "$T/o" 2>&1; rc=$?
check_rc "partial disable (metrics): rc 0" 0 "$rc"
check "partial disable: token moved to the file" "$OLDTOK" "$(cat "$TOKF" 2>/dev/null)"
check "partial disable: env without the token" "0" "$(lines_of OBS_INGEST_TOKEN "$ENVF")"
check "partial disable: unit now has LoadCredential" "yes" "$(yn grep -q '^LoadCredential=ingest-token:' "$UNITF")"
check "partial disable: said once" "1" "$(grep -c 'no longer holds' "$T/o")"
meta_put ENABLE_METRICS true
seed_native "" "$OLDTOK"
( obs_disable_logs ) > "$T/o" 2>&1; rc=$?
check_rc "partial disable (logs): rc 0" 0 "$rc"
check "partial disable (logs): token moved" "$OLDTOK" "$(cat "$TOKF" 2>/dev/null)"
meta_put ENABLE_OBSERVABILITY true

# enable migrates (node flags, install and log dir are not OBS's: stubbed)
seed_native "" "$OLDTOK"
( obs_check_reth_flags() { return 0; }; obs_ensure_reth_flags() { return 0; }; obs_install_alloy_native() { return 0; }
  obs_prepare_node_log_dir() { printf '%s\n' "$RP/var/log/telcoin/node"; }
  ENABLE_OBSERVABILITY=true; ENABLE_METRICS=true; obs_enable "$(obs_existing_token)" ) > "$T/o" 2>&1; rc=$?
cat "$V3_ARGV_LOG" "$V3_SCTL_LOG" "$V3_DOCKER_LOG" > "$T/argv.snap"
check_rc "enable on a legacy host: rc 0" 0 "$rc"
check "enable: token file holds the reused token" "$OLDTOK" "$(cat "$TOKF" 2>/dev/null)"
check "enable: env file without the token" "0" "$(lines_of OBS_INGEST_TOKEN "$ENVF")"
check "enable: said once" "1" "$(grep -c 'no longer holds' "$T/o")"
check_lacks "enable: token never in argv/systemctl/docker" "$OLDTOK" "$(cat "$T/argv.snap")"
# enable on docker writes the token file and the sidecar unit
seed_native "" ""
meta_put INSTALL_METHOD docker
( obs_check_reth_flags() { return 0; }; obs_ensure_reth_flags() { return 0; }; tn_as_service_user() { shift 0; "$@"; }
  ENABLE_OBSERVABILITY=true; ENABLE_METRICS=false; obs_enable "  $NEWTOK  " ) > "$T/o" 2>&1; rc=$?
check_rc "docker enable: rc 0" 0 "$rc"
check "docker enable: token file (trimmed)" "$NEWTOK" "$(cat "$TOKF" 2>/dev/null)"
check "docker enable: token file group telcoin-alloy" "telcoin-alloy" "$(grp_of "$TOKF")"
check "docker enable: unit mounts it" "yes" "$(yn grep -qF -- "source=$TOKF,target=/run/credentials/telcoin-alloy/ingest-token,readonly" "$UNITF")"
check_lacks "docker enable: token not in the unit" "$NEWTOK" "$(cat "$UNITF")"
meta_put INSTALL_METHOD binary

# =============================================================================
# 6. obs_rotate_token: settle sequences, rollback, refusals, migration
# =============================================================================
save4() { for f in "$TOKF" "$ENVF" "$CONF" "$UNITF"; do if [ -e "$f" ]; then cp "$f" "$T/save/$(_gkey "$f")"; else rm -f "$T/save/$(_gkey "$f")"; fi; done; }
same4() { local f; for f in "$TOKF" "$ENVF" "$CONF" "$UNITF"; do
    if [ -e "$T/save/$(_gkey "$f")" ]; then cmp -s "$f" "$T/save/$(_gkey "$f")" || { echo "differs: ${f##*/}"; return; }
    else [ ! -e "$f" ] || { echo "present: ${f##*/}"; return; }; fi; done; echo same; }
rot() { local r=0; obs_rotate_token "$1" > "$T/o" 2>&1 || r=$?; cat "$V3_ARGV_LOG" "$V3_SCTL_LOG" "$V3_DOCKER_LOG" > "$T/argv.snap"; return "$r"; }
restarts() { grep -c '^restart telcoin-alloy.service' "$V3_SCTL_LOG"; }

seed_native "$OLDTOK" ""
save4
printf 'active\nactive\nactive\nactive\nactive\n' > "$V3_ACTIVE_SEQ"
rot "$NEWTOK"; rc=$?
check_rc "rotate up: rc 0" 0 "$rc"
check "rotate up: token file holds the new token" "$NEWTOK" "$(cat "$TOKF")"
check "rotate up: one Alloy restart" "1" "$(restarts)"
check "rotate up: is-active read 5 times" "5" "$(grep -c '^is-active' "$V3_SCTL_LOG")"
check "rotate up: no node restart, no guard, no epoch wait" "" "$(grep -v -e 'telcoin-alloy' -e '^daemon-reload' "$V3_SCTL_LOG")"
check "rotate up: said" "yes" "$(yn grep -q 'Ingest token rotated' "$T/o")"
check_lacks "rotate up: token not in output" "$NEWTOK" "$(cat "$T/o")"
check_lacks "rotate up: token never in argv" "$NEWTOK" "$(cat "$T/argv.snap")"
check "rotate up: token written via a pipe (process substitution)" "pipe" "$(grep "^$TOKF " "$WRITES" | head -n 1 | cut -d' ' -f4)"
check "rotate up: OBS_ROTATE_MSG empty" "" "$OBS_ROTATE_MSG"

# flapping: active then activating -> rollback, second restart, rc 1, all four files back
seed_native "$OLDTOK" ""
chmod 0640 "$TOKF"; PRE_ST="$("$V3_REAL_STAT" -c '%a %G' "$TOKF")"
save4
printf 'active\nactivating\nactive\nactive\nactive\nactive\nactive\n' > "$V3_ACTIVE_SEQ"
rot "$NEWTOK"; rc=$?
check_rc "rotate flapping: rc 1" 1 "$rc"
check "rotate flapping: token file back to the old token" "$OLDTOK" "$(cat "$TOKF")"
check "rotate flapping: token file, env, config, unit as before" "same" "$(same4)"
check "rotate flapping: restarted again on the previous files" "2" "$(restarts)"
check "rotate flapping: said rolled back" "yes" "$(yn grep -q 'Rolled back' "$T/o")"
check "rotate flapping: OBS_ROTATE_MSG says the previous token runs again" "yes" "$(yn grep -q 'previous token was put back' <<< "$OBS_ROTATE_MSG")"
check "rotate flapping: restored token file keeps its mode and group" "$PRE_ST" "$("$V3_REAL_STAT" -c %a "$TOKF") $(grp_of "$TOKF")"
# dead: restart rc 0, is-active failed always (also after the rollback)
seed_native "$OLDTOK" ""
save4
export V3_ACTIVE_DEFAULT=failed
rot "$NEWTOK"; rc=$?
unset V3_ACTIVE_DEFAULT
check_rc "rotate dead: rc 1" 1 "$rc"
check "rotate dead: files as before" "same" "$(same4)"
check "rotate dead: two restarts" "2" "$(restarts)"
check "rotate dead: says it does not run on the previous token either" "yes" "$(yn grep -q 'does not stay running on the previous token either' "$T/o")"
# restart command itself fails
seed_native "$OLDTOK" ""
save4
printf '1\n0\n' > "$V3_RESTART_SEQ"
rot "$NEWTOK"; rc=$?
check_rc "rotate restart rc 1: rc 1" 1 "$rc"
check "rotate restart rc 1: files as before" "same" "$(same4)"
check "rotate restart rc 1: restarted again" "2" "$(restarts)"
# write failure: nothing restarted, files back
for what in ingest-token telcoin-alloy.env telcoin-alloy.service; do
    seed_native "$OLDTOK" ""
    save4
    export V3_TRF_FAIL="$what"
    rot "$NEWTOK"; rc=$?
    unset V3_TRF_FAIL
    check_rc "rotate write fails ($what): rc 1" 1 "$rc"
    check "rotate write fails ($what): no restart" "0" "$(restarts)"
    check "rotate write fails ($what): token file is the old one" "$OLDTOK" "$(cat "$TOKF")"
done
# refusals
seed_native "$OLDTOK" ""; save4
rot ""; rc=$?
check_rc "rotate empty: rc 1" 1 "$rc"
check "rotate empty: nothing changed" "same" "$(same4)"
rot "   	  "; rc=$?
check_rc "rotate whitespace-only: rc 1" 1 "$rc"
check "rotate whitespace-only: nothing changed" "same" "$(same4)"
check "rotate refusals: no restart" "0" "$(restarts)"
rm -f "$UNITF"; save4
rot "$NEWTOK"; rc=$?
check_rc "rotate without the unit: rc 1" 1 "$rc"
check "rotate without the unit: nothing changed" "same" "$(same4)"
seed_native "$OLDTOK" ""; meta_put ENABLE_OBSERVABILITY false; meta_put ENABLE_METRICS false; save4
rot "$NEWTOK"; rc=$?
check_rc "rotate with both pipelines off: rc 1" 1 "$rc"
check "rotate with both pipelines off: nothing changed" "same" "$(same4)"
meta_put ENABLE_OBSERVABILITY true; meta_put ENABLE_METRICS true
# legacy host: rotate migrates; on failure the rollback restores the legacy layout
seed_native "" "$OLDTOK"; save4
rot "$NEWTOK"; rc=$?
check_rc "rotate legacy host: rc 0" 0 "$rc"
check "rotate legacy host: new token in the file" "$NEWTOK" "$(cat "$TOKF")"
check "rotate legacy host: env without the token" "0" "$(lines_of OBS_INGEST_TOKEN "$ENVF")"
check "rotate legacy host: migration said once" "1" "$(grep -c 'no longer holds' "$T/o")"
seed_native "" "$OLDTOK"; save4
export V3_ACTIVE_DEFAULT=failed
rot "$NEWTOK"; rc=$?
unset V3_ACTIVE_DEFAULT
check_rc "rotate legacy host, Alloy dies: rc 1" 1 "$rc"
check "rotate legacy host, rollback: token file absent again, env with the legacy line" "same" "$(same4)"
# adversarial tokens end to end through obs_rotate_token
i=0
for tok in "abc def ghi jkl mno pqr" "-n-leading-dash-token-0123" "%s%d%%-percent-token-0123" "quo\"te'token-0123456789ab" "$long"; do
    i=$((i + 1))
    seed_native "$OLDTOK" ""
    rot "  $tok  "; rc=$?
    check_rc "rotate adversarial $i: rc 0" 0 "$rc"
    check "rotate adversarial $i: token file exact" "$tok" "$(cat "$TOKF")"
    check_lacks "rotate adversarial $i: not in argv, systemctl, output" "$tok" "$(cat "$T/argv.snap" "$T/o")"
done
# docker rotate: unit and env for the sidecar
seed_native "$OLDTOK" ""; meta_put INSTALL_METHOD docker
obs_alloy_docker_unit_text "$ENVF" "$RP/var/lib/telcoin/logs" 990 > "$UNITF"
rot "$NEWTOK"; rc=$?
check_rc "docker rotate: rc 0" 0 "$rc"
check_has "docker rotate: env has CREDENTIALS_DIRECTORY" "CREDENTIALS_DIRECTORY=/run/credentials/telcoin-alloy" "$(cat "$ENVF")"
check "docker rotate: unit mounts the token" "yes" "$(yn grep -qF -- "source=$TOKF," "$UNITF")"
seed_native "$OLDTOK" ""; meta_put INSTALL_METHOD docker
obs_alloy_docker_unit_text "$ENVF" "$RP/var/lib/telcoin/logs" 990 > "$UNITF"; save4
( export V3_NO_ALLOY_GROUP=1; obs_rotate_token "$NEWTOK" ) > "$T/o" 2>&1; rc=$?
check_rc "docker rotate without the group: rc 1" 1 "$rc"
check "docker rotate without the group: files back" "same" "$(same4)"
meta_put INSTALL_METHOD binary

# push URL override kept by a rotate (not persisted in .node-meta)
seed_native "$OLDTOK" ""
( NETWORK=devnet; OBS_PUSH_URL=https://d.example:8443/loki/api/v1/push; OBS_METRICS_PUSH_URL=https://d.example:8443/api/v1/write; ENABLE_OBSERVABILITY=true; ENABLE_METRICS=true; _obs_write_env_file ) > /dev/null 2>&1
cp "$ENVF" "$T/envf.enabled"
( NETWORK=devnet; obs_rotate_token "$NEWTOK" ) > "$T/o" 2>&1; rc=$?
printf 'rc=%s\n--- env at enable\n%s\n--- env after rotate\n%s\n' "$rc" "$(cat "$T/envf.enabled")" "$(cat "$ENVF")" > "$REC/pushurl-override-rotate.txt"
check "devnet override: rotate keeps OBS_PUSH_URL" "OBS_PUSH_URL=https://d.example:8443/loki/api/v1/push" "$(grep '^OBS_PUSH_URL=' "$ENVF")"
check "devnet override: rotate keeps OBS_PUSH_HOST" "OBS_PUSH_HOST=d.example" "$(grep '^OBS_PUSH_HOST=' "$ENVF")"
seed_native "$OLDTOK" ""
( OBS_PUSH_URL=https://own-hub.example/loki/api/v1/push; ENABLE_OBSERVABILITY=true; ENABLE_METRICS=true; _obs_write_env_file ) > /dev/null 2>&1
( obs_disable_metrics ) > "$T/o" 2>&1
check "testnet override: partial disable keeps OBS_PUSH_URL" "OBS_PUSH_URL=https://own-hub.example/loki/api/v1/push" "$(grep '^OBS_PUSH_URL=' "$ENVF")"
meta_put ENABLE_METRICS true

# snapshot/restore fidelity: a file without a trailing newline, or with two
seed_native "$OLDTOK" ""
printf '%s' "$OLDTOK" > "$TOKF"
printf 'TN_NODE=v3node\nOBS_PUSH_URL=%s\n\n' "$OBS_PUSH_URL_TESTNET" > "$ENVF"
save4
export V3_ACTIVE_DEFAULT=failed
rot "$NEWTOK"
unset V3_ACTIVE_DEFAULT
check "rollback fidelity: files byte-identical (no newline / two newlines)" "same" "$(same4)"

# =============================================================================
# 7. obs_disable shreds; status lines
# =============================================================================
seed_native "$NEWTOK" ""
( obs_disable ) > "$T/o" 2>&1; rc=$?
check_rc "disable: rc 0" 0 "$rc"
check "disable: token file gone" "no" "$(yn test -e "$TOKF")"
if command -v shred > /dev/null 2>&1; then
    check "disable: shred ran on the token file" "yes" "$(yn grep -qF "shred -u -- $TOKF" "$V3_ARGV_LOG")"
else
    skip "disable: shred ran" "no shred here"
fi
check "disable: env without the token kept" "yes" "$(yn test -e "$ENVF")"
seed_native "" "$OLDTOK"
( obs_disable ) > "$T/o" 2>&1
check "disable: env holding the legacy token shredded" "no" "$(yn test -e "$ENVF")"
seed_native "" ""
rm -f "$ENVF"
( obs_disable ) > "$T/o" 2>&1; rc=$?
check_rc "disable with nothing to shred: rc 0" 0 "$rc"

status_line() { ( export V3_LISTED=1; obs_status ) 2>&1 | grep -i 'token' ; }
seed_native "$NEWTOK" ""
export V3_STAT_OVERRIDE="640 root:telcoin-alloy"
S="$(status_line)"; unset V3_STAT_OVERRIDE
check "status: present" "yes" "$(yn grep -q 'Ingest token file present (0640 root:telcoin-alloy)' <<< "$S")"
check_lacks "status: never the token" "$NEWTOK" "$S"
export V3_STAT_OVERRIDE="600 root:telcoin-alloy"; S="$(status_line)"; unset V3_STAT_OVERRIDE
check "status: wrong mode" "yes" "$(yn grep -q 'is 600 root:telcoin-alloy, not 0640' <<< "$S")"
export V3_STAT_OVERRIDE="640 telcoin:telcoin-alloy"; S="$(status_line)"; unset V3_STAT_OVERRIDE
check "status: wrong owner" "yes" "$(yn grep -q 'is 640 telcoin:telcoin-alloy, not 0640' <<< "$S")"
seed_native "" "$OLDTOK"; S="$(status_line)"
check "status: legacy token still in env" "yes" "$(yn grep -q 'still in' <<< "$S")"
check_lacks "status: legacy value not printed" "$OLDTOK" "$S"
seed_native "" ""; S="$(status_line)"
check "status: missing" "yes" "$(yn grep -q 'No ingest token file' <<< "$S")"
if [ "$(id -u)" != 0 ]; then
    seed_native "$NEWTOK" ""
    chmod 0640 "$OBS_ETC_DIR"; S="$(status_line)"; chmod 0750 "$OBS_ETC_DIR"
    check "status: no sudo (dir closed) -> not checked" "yes" "$(yn grep -q 'not checked' <<< "$S")"
else
    skip "status: no sudo" "root enters any directory"
fi
# after a full disable (both pipelines off, unit file kept) the status must not send the
# operator to --rotate-token, which refuses with both pipelines off
seed_native "$NEWTOK" ""
( obs_disable ) > /dev/null 2>&1
S="$(status_line)"
( obs_rotate_token "$NEWTOK" ) > "$T/o2" 2>&1; rc=$?
printf '%s\n--- rotate after the disable: rc=%s\n%s\n' "$S" "$rc" "$(cat "$T/o2")" > "$REC/status-after-disable.txt"
check "status after a full disable: no advice to run --rotate-token (it refuses then)" "0" "$(grep -c 'rotate-token' <<< "$S")"
meta_put ENABLE_OBSERVABILITY true; meta_put ENABLE_METRICS true
seed_native "" ""; S="$( (export V3_LISTED=0; obs_status) 2>&1 )"
check "status: unit not installed -> no token warning" "0" "$(grep -c 'No ingest token file' <<< "$S")"

finish
