#!/usr/bin/env bash
# =============================================================================
# V3 end-to-end harness for OBS: runs the real setup-observability.sh and the
# remove-node.sh teardown as root against the real /etc paths, with systemctl and
# docker stubbed and every other tool on PATH wrapped to log its argv. Runs ONLY in
# a disposable container (V3_DISPOSABLE=1 and uid 0); anywhere else it skips.
#
#   docker run --rm -e V3_DISPOSABLE=1 --cap-add SYS_ADMIN --security-opt apparmor=unconfined \
#       -v "$PWD:/w:ro" -w /w ubuntu:24.04 bash tasks/verify-fup/V3/v3_obs_e2e_test.sh
# =============================================================================
set -u
V3_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${V3_REPO:-$(cd "$V3_DIR/../../.." && pwd)}"
# shellcheck source=/dev/null
. "$REPO/tools/tests/lib.sh"
if [ "${V3_DISPOSABLE:-0}" != 1 ] || [ "$(id -u)" != 0 ]; then
    skip "e2e (real /etc paths)" "needs a disposable container as root (V3_DISPOSABLE=1)"
    finish
fi
T="$TN_TEST_TMP"
BASH_BIN="$(type -P bash)"
SO="$REPO/setup-observability.sh"
AD=/etc/telcoin/alloy
TOKF="$AD/ingest-token"; ENVF="$AD/telcoin-alloy.env"; CONF="$AD/config.alloy"
UNITF=/etc/systemd/system/telcoin-alloy.service
export V3_SCTL_LOG="$T/sctl.log" V3_DOCKER_LOG="$T/docker.log" V3_ARGV_LOG="$T/argv.log" V3_MARK="$T/mark"
export V3_ACTIVE_SEQ="$T/active.seq" V3_RESTART_SEQ="$T/restart.seq"
export TN_UPDATE_LOCK_FILE=/run/v3-update.lock TN_SKIP_EPOCH_WAIT=1 TERM=xterm
OLDTOK="old-e2e-token-0123456789abcdef"
NEWTOK="new-e2e-token-0123456789abcdef"

# --- accounts and stubs -------------------------------------------------------------
getent group telcoin-alloy >/dev/null || groupadd -r telcoin-alloy
getent passwd telcoin-alloy >/dev/null || useradd -r -g telcoin-alloy -M -d /var/lib/telcoin-alloy -s /usr/sbin/nologin telcoin-alloy
getent group telcoin-log >/dev/null || groupadd -r telcoin-log
mkdir -p "$T/bin" /etc/systemd/system /var/lib/telcoin /var/log/telcoin/node /run
for d in /usr/bin /usr/sbin; do
    for f in "$d"/*; do
        n="${f##*/}"
        case "$n" in bash|sh|dash|rbash|systemctl|docker|chown|"["|*'%'*) continue ;; esac
        [ -x "$f" ] && [ ! -d "$f" ] && [ ! -e "$T/bin/$n" ] || continue
        printf '#!/bin/sh\n{ printf "%%s" "${0##*/}"; for a in "$@"; do printf " %%s" "$a"; done; printf "\\n"; } >> "${V3_ARGV_LOG:-/dev/null}"\nexec %s "$@"\n' "$f" > "$T/bin/$n"
    done
done
cat > "$T/bin/chown" <<'STUB'
#!/bin/sh
{ printf "chown"; for a in "$@"; do printf " %s" "$a"; done; printf "\n"; } >> "${V3_ARGV_LOG:-/dev/null}"
case "$*" in
  *"/etc/telcoin/alloy/.tn."*) if [ "${V3_HANG_CHOWN:-0}" = 1 ]; then : > "$V3_MARK"; /usr/bin/sleep 8; fi ;;
esac
exec /usr/bin/chown "$@"
STUB
cat > "$T/bin/systemctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$V3_SCTL_LOG"
pop() { f="$1"; if [ -s "$f" ]; then v="$(/usr/bin/head -n 1 "$f")"; /usr/bin/tail -n +2 "$f" > "$f.n"; /usr/bin/mv "$f.n" "$f"; printf '%s' "$v"; fi; }
case "$1" in
  restart)
    if [ "${V3_HANG_RESTART:-0}" = 1 ]; then : > "$V3_MARK"; /usr/bin/sleep 8; fi
    r="$(pop "$V3_RESTART_SEQ")"; exit "${r:-0}" ;;
  is-active)
    s="$(pop "$V3_ACTIVE_SEQ")"; s="${s:-${V3_ACTIVE_DEFAULT:-active}}"
    [ "$2" = "--quiet" ] || printf '%s\n' "$s"
    [ "$s" = active ] && exit 0; exit 3 ;;
  list-unit-files) printf 'telcoin-alloy.service enabled enabled\n'; exit 0 ;;
  *) exit 0 ;;
esac
STUB
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$V3_DOCKER_LOG"\nexit 0\n' > "$T/bin/docker"
chmod +x "$T/bin/"*
export PATH="$T/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
hash -r
yn() { if "$@"; then echo yes; else echo no; fi; }
st() { /usr/bin/stat -c '%a %U:%G' "$1" 2>/dev/null || echo absent; }
logs_reset() { : > "$V3_SCTL_LOG"; : > "$V3_DOCKER_LOG"; : > "$V3_ARGV_LOG"; : > "$V3_ACTIVE_SEQ"; : > "$V3_RESTART_SEQ"; rm -f "$V3_MARK"; }
snap() { cat "$V3_ARGV_LOG" "$V3_SCTL_LOG" "$V3_DOCKER_LOG" > "$T/argv.snap"; }
save4() { for f in "$TOKF" "$ENVF" "$CONF" "$UNITF"; do n="$(printf '%s' "$f" | /usr/bin/tr / _)"; if [ -e "$f" ]; then /usr/bin/cp -p "$f" "$T/s.$n"; printf '%s\n' "$(st "$f")" > "$T/s.$n.st"; else rm -f "$T/s.$n" "$T/s.$n.st"; fi; done; }
same4() { for f in "$TOKF" "$ENVF" "$CONF" "$UNITF"; do n="$(printf '%s' "$f" | /usr/bin/tr / _)"
    if [ -e "$T/s.$n" ]; then /usr/bin/cmp -s "$f" "$T/s.$n" || { echo "differs: $f"; return; }
        [ "$(st "$f")" = "$(cat "$T/s.$n.st")" ] || { echo "owner/mode: $f $(st "$f")"; return; }
    else [ ! -e "$f" ] || { echo "present: $f"; return; }; fi; done; echo same; }
# seed METHOD TOKEN-IN-FILE LEGACY-ENV-TOKEN [ENABLE_METRICS]: an installed shipper rendered by the library itself
seed() {
    rm -rf "$AD" "$UNITF" /etc/telcoin/.node-meta
    mkdir -p /etc/telcoin
    printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nINSTALL_METHOD=%s\nDATA_DIR=/var/lib/telcoin\nENABLE_OBSERVABILITY=true\nENABLE_METRICS=%s\nNODE_LOG_DIR=/var/log/telcoin/node\nREGION=eu\n' "$1" "${4:-true}" > /etc/telcoin/.node-meta
    chmod 0600 /etc/telcoin/.node-meta
    install -d -m 0750 -o root -g telcoin-alloy "$AD"
    "$BASH_BIN" -c 'source "$1/lib/common.sh"; set +e; NETWORK=testnet; ENABLE_OBSERVABILITY=true; ENABLE_METRICS=$4
        [ -z "$2" ] || obs_write_token_file "$2"; obs_render_alloy
        if [ -n "$3" ]; then printf "OBS_INGEST_TOKEN=%s\n" "$3" >> "$OBS_ETC_DIR/telcoin-alloy.env"; fi' _ "$REPO" "$2" "$3" "${4:-true}" > "$T/seed.out" 2>&1
    logs_reset
}
so() { "$BASH_BIN" "$SO" "$@"; }

# =============================================================================
# E1. CLI --rotate-token --token-stdin (native)
# =============================================================================
seed binary "$OLDTOK" ""
check "seed: token file 640 root:telcoin-alloy" "640 root:telcoin-alloy" "$(st "$TOKF")"
printf '%s\n' "$NEWTOK" > "$T/tok"
so --rotate-token --token-stdin < "$T/tok" > "$T/o" 2>&1; rc=$?; snap
check_rc "E1 cli stdin: rc 0" 0 "$rc"
check "E1: token file holds the new token" "$NEWTOK" "$(cat "$TOKF")"
check "E1: token file 640 root:telcoin-alloy (real owner, group, mode)" "640 root:telcoin-alloy" "$(st "$TOKF")"
check "E1: env file 600 root:root" "600 root:root" "$(st "$ENVF")"
check_lacks "E1: env file without the token" "$NEWTOK" "$(cat "$ENVF")"
check "E1: unit LoadCredential" "yes" "$(yn grep -qx 'LoadCredential=ingest-token:/etc/telcoin/alloy/ingest-token' "$UNITF")"
check_lacks "E1: token never in any argv (all tools wrapped), systemctl or docker" "$NEWTOK" "$(cat "$T/argv.snap")"
check_lacks "E1: token never printed" "$NEWTOK" "$(cat "$T/o")"
check "E1: one Alloy restart, nothing else restarted" "restart telcoin-alloy.service" "$(grep -E '^(restart|stop|start)' "$V3_SCTL_LOG")"
check "E1: no temp file left in $AD" "" "$(ls -A "$AD" | grep '^\.tn\.' || true)"
check "E1: said rotated" "yes" "$(yn grep -q 'Ingest token rotated' "$T/o")"

# E2. non-tty without a token: refused, nothing changed
seed binary "$OLDTOK" ""; save4
so --rotate-token < /dev/null > "$T/o" 2>&1; rc=$?
check_rc "E2 non-tty, no token: rc 1" 1 "$rc"
check "E2: said" "yes" "$(yn grep -q 'needs the new token' "$T/o")"
check "E2: nothing changed" "same" "$(same4)"
check "E2: no restart" "0" "$(grep -c '^restart' "$V3_SCTL_LOG")"

# E3. tty: hidden prompt (util-linux script gives a pty)
if command -v script >/dev/null 2>&1; then
    seed binary "$OLDTOK" ""
    ( /usr/bin/sleep 2; printf '%s\r' "$NEWTOK" ) | script -qec "$BASH_BIN $SO --rotate-token" /dev/null > "$T/o" 2>&1; rc=$?
    check_rc "E3 tty prompt: rc 0" 0 "$rc"
    check "E3: prompt shown" "yes" "$(yn grep -q 'New ingest token (input hidden)' "$T/o")"
    check_lacks "E3: typed token not echoed" "$NEWTOK" "$(cat "$T/o")"
    check "E3: token file holds the typed token" "$NEWTOK" "$(cat "$TOKF")"
    # menu entry 8
    seed binary "$OLDTOK" ""
    ( /usr/bin/sleep 2; printf '8\r'; /usr/bin/sleep 1; printf '%s\r' "$NEWTOK"; /usr/bin/sleep 2; printf '\r'; /usr/bin/sleep 1; printf '9\r' ) | script -qec "$BASH_BIN $SO" /dev/null > "$T/o" 2>&1; rc=$?
    check "E3 menu: entry 8 listed" "yes" "$(yn grep -q '8) Rotate the ingest token' "$T/o")"
    check "E3 menu: token rotated" "$NEWTOK" "$(cat "$TOKF")"
    check_lacks "E3 menu: token not echoed" "$NEWTOK" "$(cat "$T/o")"
else
    skip "E3 tty" "no script(1)"
fi

# E4. TN_OBS_TOKEN, E5. --token (argv, warned)
seed binary "$OLDTOK" ""
TN_OBS_TOKEN="$NEWTOK" so --rotate-token < /dev/null > "$T/o" 2>&1; rc=$?
check_rc "E4 TN_OBS_TOKEN: rc 0" 0 "$rc"
check "E4: rotated" "$NEWTOK" "$(cat "$TOKF")"
seed binary "$OLDTOK" ""
so --rotate-token --token "$NEWTOK" < /dev/null > "$T/o" 2>&1; rc=$?
check_rc "E5 --token: rc 0" 0 "$rc"
check "E5: warned about the command line" "yes" "$(yn grep -q 'puts the ingest token on the command line' "$T/o")"

# E6. --json success: JSON only on stdout, done ok:true with token:rotated
seed binary "$OLDTOK" ""
so --json --rotate-token --token-stdin < "$T/tok" > "$T/j" 2> "$T/e"; rc=$?
check_rc "E6 json: rc 0" 0 "$rc"
check "E6: every stdout line is JSON" "0" "$(grep -cv '^{.*}$' "$T/j")"
check "E6: last line done ok:true with token:rotated" "yes" "$(yn sh -c 'tail -n 1 "$1" | grep -q "\"event\":\"done\",\"ok\":true,\"applied\":\[\"token:rotated\"\]"' _ "$T/j")"
check_lacks "E6: token not in JSON or stderr" "$NEWTOK" "$(cat "$T/j" "$T/e")"
# E7. --json, Alloy dies: rollback, done ok:false, rc 1
seed binary "$OLDTOK" ""; save4
V3_ACTIVE_DEFAULT=failed so --json --rotate-token --token-stdin < "$T/tok" > "$T/j" 2> "$T/e"; rc=$?
check_rc "E7 json rollback: rc 1" 1 "$rc"
check "E7: done ok:false last" "yes" "$(yn sh -c 'tail -n 1 "$1" | grep -q "\"event\":\"done\",\"ok\":false"' _ "$T/j")"
check "E7: error event names the rollback" "yes" "$(yn grep -q 'did not stay running on the new token' "$T/j")"
check "E7: files, owners and modes as before" "same" "$(same4)"
check "E7: restarted twice (new, then previous)" "2" "$(grep -c '^restart telcoin-alloy' "$V3_SCTL_LOG")"
# E8. combined with an enable or a disable: refused
for extra in --enable-logs --disable-metrics --enable-health; do
    seed binary "$OLDTOK" ""; save4
    so --rotate-token "$extra" --token-stdin < "$T/tok" > "$T/o" 2>&1; rc=$?
    check_rc "E8 --rotate-token $extra: rc 1" 1 "$rc"
    check "E8 $extra: nothing changed" "same" "$(same4)"
    so --json --rotate-token "$extra" --token-stdin < "$T/tok" > "$T/j" 2>/dev/null; rc=$?
    check "E8 json $extra: done ok:false" "yes" "$(yn grep -q '"event":"done","ok":false' "$T/j")"
done
# E9. --json without a token
seed binary "$OLDTOK" ""; save4
so --json --rotate-token < /dev/null > "$T/j" 2>/dev/null; rc=$?
check_rc "E9 json no token: rc 1" 1 "$rc"
check "E9: done ok:false names the token sources" "yes" "$(yn grep -q 'needs the new token' "$T/j")"
check "E9: nothing changed" "same" "$(same4)"
# E10. legacy env host: rotate migrates; --json reports once
seed binary "" "$OLDTOK"
so --rotate-token --token-stdin < "$T/tok" > "$T/o" 2>&1; rc=$?
check_rc "E10 legacy rotate: rc 0" 0 "$rc"
check "E10: env without OBS_INGEST_TOKEN" "0" "$(grep -c OBS_INGEST_TOKEN "$ENVF")"
check "E10: migration said once" "1" "$(grep -c 'no longer holds the ingest token' "$T/o")"
# E11. docker install: sidecar unit, env CREDENTIALS_DIRECTORY, real group gid
seed docker "$OLDTOK" ""
so --rotate-token --token-stdin < "$T/tok" > "$T/o" 2>&1; rc=$?
GID="$(getent group telcoin-alloy | cut -d: -f3)"
check_rc "E11 docker rotate: rc 0" 0 "$rc"
check "E11: --group-add the real gid" "yes" "$(yn grep -qF -- "--group-add ${GID} " "$UNITF")"
check "E11: env CREDENTIALS_DIRECTORY" "yes" "$(yn grep -qx 'CREDENTIALS_DIRECTORY=/run/credentials/telcoin-alloy' "$ENVF")"
check "E11: token file 640 root:telcoin-alloy" "640 root:telcoin-alloy" "$(st "$TOKF")"
cp "$UNITF" "$V3_DIR/records/e2e-docker.unit" 2>/dev/null || true

# =============================================================================
# E12. SIGTERM between the token write and the restart (CLI and --json)
# =============================================================================
for mode in cli json; do
    seed binary "$OLDTOK" ""
    if [ "$mode" = json ]; then set -- --json; else set --; fi
    V3_HANG_RESTART=1 "$BASH_BIN" "$SO" "$@" --rotate-token --token-stdin < "$T/tok" > "$T/o" 2>&1 &
    pid=$!
    n=0; while [ ! -e "$V3_MARK" ] && [ "$n" -lt 200 ]; do /usr/bin/sleep 0.1; n=$((n + 1)); done
    kill -TERM "$pid"; wait "$pid"; rc=$?
    /usr/bin/pkill -f "sleep 8" 2>/dev/null || true
    {
        printf '%s\n' "--- E12 $mode: rc=$rc"
        printf 'token file: %s (%s)\n' "$(if [ "$(cat "$TOKF")" = "$NEWTOK" ]; then echo NEW; elif [ "$(cat "$TOKF")" = "$OLDTOK" ]; then echo OLD; else echo other; fi)" "$(st "$TOKF")"
        printf 'temp files: %s\n' "$(ls -A "$AD" | grep '^\.tn\.' | tr '\n' ' ')"
        printf 'restarts: %s\n' "$(grep -c '^restart' "$V3_SCTL_LOG")"
        printf 'output tail:\n'; tail -n 5 "$T/o"
    } >> "$T/e12.txt"
    check "E12 $mode: SIGTERM ends the run (rc 143 or the trap's rc)" "yes" "$(yn test "$rc" -ne 0)"
    check "E12 $mode: what is left: the new token file, no rollback" "$NEWTOK" "$(cat "$TOKF")"
    check "E12 $mode: no temp file left" "" "$(ls -A "$AD" | grep '^\.tn\.' || true)"
    [ "$mode" = json ] && check "E12 json: a done event closes the run" "yes" "$(yn grep -q '"event":"done","ok":false' "$T/o")"
done
# E13. SIGTERM during the token temp write (between mktemp and the rename)
for mode in cli json; do
    seed binary "$OLDTOK" ""
    if [ "$mode" = json ]; then set -- --json; else set --; fi
    V3_HANG_CHOWN=1 "$BASH_BIN" "$SO" "$@" --rotate-token --token-stdin < "$T/tok" > "$T/o" 2>&1 &
    pid=$!
    n=0; while [ ! -e "$V3_MARK" ] && [ "$n" -lt 200 ]; do /usr/bin/sleep 0.1; n=$((n + 1)); done
    kill -TERM "$pid"; wait "$pid"; rc=$?
    /usr/bin/pkill -f "sleep 8" 2>/dev/null || true
    /usr/bin/sleep 0.5
    left="$(ls -A "$AD" | grep '^\.tn\.' || true)"
    {
        printf '%s\n' "--- E13 $mode: rc=$rc"
        printf 'token file: %s\n' "$(cat "$TOKF")"
        printf 'temp files: %s\n' "$left"
        for f in $left; do printf '  %s %s holds-new-token=%s\n' "$f" "$(st "$AD/$f")" "$(yn grep -qxF "$NEWTOK" "$AD/$f")"; done
    } >> "$T/e12.txt"
    check "E13 $mode: token file still the old one" "$OLDTOK" "$(cat "$TOKF")"
    check "E13 $mode: no temp copy of the new token left in $AD" "" "$left"
done
cat "$T/e12.txt"
cp "$T/e12.txt" "$V3_DIR/records/e2e-sigterm.txt" 2>/dev/null || true

# =============================================================================
# E14. read-only /etc/telcoin/alloy (bind mount remounted ro; needs CAP_SYS_ADMIN)
# =============================================================================
seed binary "$OLDTOK" "" false
if mount --bind "$AD" "$AD" 2>/dev/null && mount -o remount,bind,ro "$AD" 2>/dev/null; then
    save4
    so --rotate-token --token-stdin < "$T/tok" > "$T/o" 2>&1; rc=$?
    check_rc "E14 ro dir rotate: rc 1" 1 "$rc"
    check "E14 ro rotate: old token kept" "$OLDTOK" "$(cat "$TOKF")"
    check "E14 ro rotate: no restart" "0" "$(grep -c '^restart' "$V3_SCTL_LOG")"
    check "E14 ro rotate: said" "yes" "$(yn grep -q 'could not be put in place\|Could not write the ingest token' "$T/o")"
    check "E14 ro rotate: no claim that an unchanged file could not be put back" "0" "$(grep -c 'Could not put .* back' "$T/o")"
    cp "$T/o" "$T/e14-rotate.out"
    # disable (logs on, metrics off -> full teardown -> obs_disable)
    so --json --disable-logs > "$T/j" 2> "$T/o"; rc=$?
    check "E14 ro disable: the token file is still there" "yes" "$(yn test -e "$TOKF")"
    check "E14 ro disable: does not claim it shredded the token" "0" "$(grep -c 'ingest token file was shredded' "$T/o")"
    { echo "--- E14 rotate"; cat "$T/e14-rotate.out"; echo "--- E14 disable rc=$rc json:"; cat "$T/j"; echo "stderr:"; cat "$T/o"; } > "$T/e14.txt"
    cp "$T/e14.txt" "$V3_DIR/records/e2e-readonly.txt" 2>/dev/null || true
    umount "$AD"; umount "$AD" 2>/dev/null || true
else
    skip "E14 read-only Alloy dir" "cannot bind-mount here (needs --cap-add SYS_ADMIN, apparmor unconfined)"
fi

# =============================================================================
# E15. remove-node: the token file and a legacy env file are shredded; absent is fine
# =============================================================================
grep -v '^main "\$@"$' "$REPO/remove-node.sh" > "$T/remove-node.sh"
ln -s "$REPO/lib" "$T/lib"
rmn() { "$BASH_BIN" -c 'source "$1"; set +e; remove_testnet_addons' _ "$T/remove-node.sh" > "$T/o" 2>&1; }
seed binary "$NEWTOK" "$OLDTOK"
rmn; rc=$?; snap
check_rc "E15 remove: rc 0" 0 "$rc"
check "E15: token file gone" "no" "$(yn test -e "$TOKF")"
check "E15: Alloy dir gone" "no" "$(yn test -e "$AD")"
check "E15: shred ran on the token file" "yes" "$(yn grep -qF "shred -u -- $TOKF" "$T/argv.snap")"
check "E15: shred ran on the legacy env file" "yes" "$(yn grep -qF "shred -u -- $ENVF" "$T/argv.snap")"
mkdir -p "$AD"; rm -f "$TOKF"; logs_reset
rmn; rc=$?
check_rc "E15 remove with no token file: rc 0" 0 "$rc"
check "E15 no token file: no error printed" "0" "$(grep -c 'ERROR' "$T/o")"
finish
