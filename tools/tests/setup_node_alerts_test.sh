#!/usr/bin/env bash
# =============================================================================
# tools/tests/setup_node_alerts_test.sh -- setup-node.sh and private alerts (#60):
#
#   prompt_alerts  asks on every network, records pending on yes and false on
#                  no, asks nothing under TN_ASSUME_YES, without setup-alerts.sh
#                  or when private alerts are already on;
#   the read-back  step_preflight keeps a true or pending ENABLE_ALERTS from
#                  .node-meta, so a re-run never turns live alerts off; a key
#                  set twice stops setup;
#   .node-meta     step_create_service writes ENABLE_ALERTS with the other keys;
#   step_alerts    a no-op in --json and unless pending; a node that is not
#                  running stays pending; otherwise setup-alerts.sh --enable
#                  runs as a child (its rc decides on or pending), without fd 3
#                  and without the BLS passphrase, and the node is never stopped
#                  or restarted;
#   the summary    "Private alerts: on" or the pending line with the command.
#
#   bash tools/tests/setup_node_alerts_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/setup_node_alerts_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/setup_node_alerts_test.sh
#
# A copy of setup-node.sh without its last line (main "$@") is sourced by a
# driver that runs one function per call. setup-alerts.sh and systemctl are
# stand-ins that record their arguments; setup-alerts.sh exits SNA_ALERTS_RC and
# `systemctl is-active` exits SNA_ACTIVE_RC. Maintainer tooling (not
# updater-tracked). bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
SN="$TN_TEST_REPO/setup-node.sh"
export SNA_DIR="$T"

has() {
    case "$1" in
        *"$2"*) echo yes ;;
        *) echo no ;;
    esac
}

# The copy of setup-node.sh, its library and the stand-ins.
mkdir -p "$T/sn" "$T/bin" "$T/fx/etc/telcoin" "$T/fx/var/lib/telcoin"
grep -v '^main "\$@"$' "$SN" > "$T/sn/setup-node.sh"
ln -s "$TN_TEST_REPO/lib" "$T/sn/lib"
# The read-back, cut out of step_preflight (it holds a `local`, so it runs in a function).
{
    echo 'readback_fn() {'
    awk '/^    # Private alerts, on every network\./ { f = 1 } f { print } f && /json_mode \|\| prompt_alerts/ { exit }' "$SN"
    echo '}'
} > "$T/sn/readback.sh"
cat > "$T/sn/setup-alerts.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SNA_DIR/alerts.argv"
if { true >&3; } 2>/dev/null; then echo fd3-open; else echo fd3-closed; fi >> "$SNA_DIR/alerts.seen"
if env | grep -q 'sna-test-pass'; then echo pass-in-env; else echo pass-not-in-env; fi >> "$SNA_DIR/alerts.seen"
exit "${SNA_ALERTS_RC:-0}"
STUB
cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SNA_DIR/systemctl.log"
case "${1:-}" in
    is-active) exit "${SNA_ACTIVE_RC:-0}" ;;
esac
exit 0
STUB
chmod 0755 "$T/sn/setup-alerts.sh" "$T/bin/systemctl"

cat > "$T/sn/drv.sh" <<'DRV'
# drv.sh CASE -- source the copy of setup-node.sh, then run one function.
source "$SNA_DIR/sn/setup-node.sh"
source "$SNA_DIR/sn/readback.sh"
set +e
CONFIG_DIR="$SNA_DIR/fx/etc/telcoin"
DATA_DIR="$SNA_DIR/fx/var/lib/telcoin"
NETWORK="${SNA_NETWORK:-testnet}"
ENABLE_ALERTS="${SNA_ENABLE:-false}"
JSON_MODE="${SNA_JSON:-false}"
case "$1" in
    prompt)
        prompt_alerts
        echo "ENABLE_ALERTS=${ENABLE_ALERTS}"
        ;;
    readback)
        readback_fn
        echo "ENABLE_ALERTS=${ENABLE_ALERTS}"
        ;;
    step)
        exec 3>/dev/null
        TN_SETUP_PASS="sna-test-pass"
        step_alerts
        echo "ENABLE_ALERTS=${ENABLE_ALERTS}"
        ;;
    summary)
        set +u
        PASSPHRASE_METHOD=credential
        VALIDATOR_ADDRESS=0x0000000000000000000000000000000000000001
        step_final_summary
        ;;
esac
DRV

# drv CASE -- run the driver with PATH's stand-ins first; OUT (stdout and
# stderr together), RC, and the stand-ins' logs reset first.
drv() {
    rm -f "$T/alerts.argv" "$T/alerts.seen" "$T/systemctl.log"
    RC=0
    OUT="$(PATH="$T/bin:$PATH" bash "$T/sn/drv.sh" "$@" 2>&1 < "${SNA_STDIN:-/dev/null}")" || RC=$?
}
argv() { cat "$T/alerts.argv" 2>/dev/null | tr '\n' ' '; }
meta() {
    local l
    : > "$T/fx/etc/telcoin/.node-meta"
    for l in "$@"; do
        printf '%s\n' "$l" >> "$T/fx/etc/telcoin/.node-meta"
    done
}
printf 'y\n' > "$T/yes"
printf 'n\n' > "$T/no"

# -----------------------------------------------------------------------------
# prompt_alerts
# -----------------------------------------------------------------------------
SNA_STDIN="$T/yes" drv prompt
check "prompt: yes records pending" "0 ENABLE_ALERTS=pending" "$RC $(printf '%s\n' "$OUT" | tail -n 1)"
check "prompt: the header" yes "$(has "$OUT" "Private alerts (optional)")"
check "prompt: what it is" yes "$(has "$OUT" "A timer on this host pushes a heartbeat to a monitor you own, through an Uptime Kuma push URL, a healthchecks.io ping URL or a JSON webhook.")"
check "prompt: what is sent" yes "$(has "$OUT" "Each heartbeat says up or down with the reason (node mode, block and epoch); a webhook also gets this host's label and the network. Nothing else is sent.")"
check "prompt: no port, no Association" yes "$(has "$OUT" "No port opens on this host, and the Telcoin Association is not involved.")"
check "prompt: the URLs come later" yes "$(has "$OUT" "Setup asks for the monitor URLs once the node is running.")"
SNA_STDIN="$T/no" drv prompt
check "prompt: no records false" "0 ENABLE_ALERTS=false" "$RC $(printf '%s\n' "$OUT" | tail -n 1)"
SNA_ENABLE=pending SNA_STDIN="$T/no" drv prompt
check "prompt: no over a pending value records false" "ENABLE_ALERTS=false" "$(printf '%s\n' "$OUT" | tail -n 1)"
SNA_ENABLE=pending SNA_STDIN="$T/yes" drv prompt
check "prompt: asks again over a pending value" "yes ENABLE_ALERTS=pending" \
    "$(has "$OUT" "Private alerts (optional)") $(printf '%s\n' "$OUT" | tail -n 1)"
for net in mainnet devnet; do
    SNA_NETWORK="$net" SNA_STDIN="$T/yes" drv prompt
    check "prompt: asked on ${net} too" "yes ENABLE_ALERTS=pending" \
        "$(has "$OUT" "Private alerts (optional)") $(printf '%s\n' "$OUT" | tail -n 1)"
done
TN_ASSUME_YES=true SNA_STDIN="$T/yes" drv prompt
check "prompt: TN_ASSUME_YES asks nothing and keeps false" "ENABLE_ALERTS=false" "$OUT"
SNA_ENABLE=true SNA_STDIN="$T/no" drv prompt
check "prompt: already on, asks nothing and keeps true" "ENABLE_ALERTS=true" "$OUT"
mv "$T/sn/setup-alerts.sh" "$T/sn/setup-alerts.sh.away"
SNA_STDIN="$T/yes" drv prompt
mv "$T/sn/setup-alerts.sh.away" "$T/sn/setup-alerts.sh"
check "prompt: without setup-alerts.sh asks nothing" "ENABLE_ALERTS=false" "$OUT"
check "prompt: no testnet gate in prompt_alerts or step_alerts" "0" \
    "$(sed -n '/^prompt_alerts() {/,/^}/p; /^step_alerts() {/,/^}/p' "$SN" | grep -c 'is_testnet\|require_testnet')"

# -----------------------------------------------------------------------------
# The read-back in step_preflight
# -----------------------------------------------------------------------------
check "read-back: cut out of step_preflight" yes \
    "$(grep -q 'setup_meta_read alerts_meta ENABLE_ALERTS' "$T/sn/readback.sh" && echo yes || echo no)"
check "read-back: after the add-on prompt, before the install method" "prompt_testnet_addons setup_meta_read alerts_meta prompt_alerts Selecting" \
    "$(sed -n '/^step_preflight() {/,/^}/p' "$SN" | grep -o 'json_mode || prompt_testnet_addons\|setup_meta_read alerts_meta\|json_mode || prompt_alerts\|"Selecting install method' \
        | sed 's/json_mode || //; s/^"//; s/ install method$//' | tr '\n' ' ' | sed 's/ $//')"
rm -f "$T/fx/etc/telcoin/.node-meta"
SNA_STDIN="$T/no" drv readback
check "read-back: no .node-meta, the prompt decides" "yes ENABLE_ALERTS=false" \
    "$(has "$OUT" "Private alerts (optional)") $(printf '%s\n' "$OUT" | tail -n 1)"
meta "NETWORK=testnet" "ENABLE_ALERTS=true"
SNA_STDIN="$T/no" drv readback
check "read-back: true is kept and nothing is asked" "ENABLE_ALERTS=true" "$OUT"
meta "NETWORK=testnet" "ENABLE_ALERTS=pending"
SNA_JSON=true drv readback
check "read-back: pending is kept in a --json run, nothing asked" "ENABLE_ALERTS=pending" "$OUT"
SNA_STDIN="$T/yes" drv readback
check "read-back: pending, asked again" "yes ENABLE_ALERTS=pending" \
    "$(has "$OUT" "Private alerts (optional)") $(printf '%s\n' "$OUT" | tail -n 1)"
meta "NETWORK=testnet" "ENABLE_ALERTS=false"
SNA_JSON=true drv readback
check "read-back: false stays false" "ENABLE_ALERTS=false" "$OUT"
meta "NETWORK=testnet" "ENABLE_ALERTS=yes"
SNA_JSON=true drv readback
check "read-back: another value counts as false" "ENABLE_ALERTS=false" "$OUT"
meta "NETWORK=testnet" "ENABLE_ALERTS=true" "ENABLE_ALERTS=false"
SNA_JSON=false drv readback
check "read-back: a key set twice stops setup" "1 yes" \
    "$RC $(has "$OUT" "ENABLE_ALERTS is set more than once in ${T}/fx/etc/telcoin/.node-meta")"
rm -f "$T/fx/etc/telcoin/.node-meta"

# -----------------------------------------------------------------------------
# .node-meta: step_create_service writes the key with the others
# -----------------------------------------------------------------------------
check "meta: write_node_meta in step_create_service carries ENABLE_ALERTS" "1" \
    "$(sed -n '/^step_create_service() {/,/^}/p' "$SN" | grep -c '^        "ENABLE_ALERTS=${ENABLE_ALERTS:-false}" \\$')"
check "meta: the default is false" 'ENABLE_ALERTS="false"' \
    "$(grep -o '^ENABLE_ALERTS="[a-z]*"' "$SN")"

# -----------------------------------------------------------------------------
# step_alerts
# -----------------------------------------------------------------------------
SNA_ENABLE=pending SNA_JSON=true drv step
check "step: --json is a no-op" "ENABLE_ALERTS=pending||" "${OUT}|$(argv)|$(cat "$T/systemctl.log" 2>/dev/null)"
for v in false true; do
    SNA_ENABLE="$v" drv step
    check "step: ${v} is a no-op" "ENABLE_ALERTS=${v}||" "${OUT}|$(argv)|$(cat "$T/systemctl.log" 2>/dev/null)"
done
SNA_ENABLE=pending SNA_ACTIVE_RC=3 drv step
check "step: node not running, stays pending" "0 ENABLE_ALERTS=pending" "$RC $(printf '%s\n' "$OUT" | tail -n 1)"
check "step: node not running, says so with the command" yes \
    "$(has "$OUT" "The node is not running yet, so private alerts stay pending. Once it runs: sudo bash setup-alerts.sh")"
check "step: node not running, setup-alerts.sh not run" "" "$(argv)"
check "step: node not running, systemctl asked is-active only" "is-active --quiet telcoin" "$(cat "$T/systemctl.log" 2>/dev/null)"
SNA_ENABLE=pending SNA_ALERTS_RC=0 drv step
check "step: enable went through, on" "0 ENABLE_ALERTS=true" "$RC $(printf '%s\n' "$OUT" | tail -n 1)"
check "step: setup-alerts.sh --enable ran once" "--enable " "$(argv)"
check "step: the header and the ok line" "yes yes" "$(has "$OUT" "Private alerts") $(has "$OUT" "Private alerts are on.")"
check "step: the child has no fd 3 and no passphrase" "fd3-closed pass-not-in-env" \
    "$(cat "$T/alerts.seen" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
check "step: the node is never stopped or restarted" "is-active --quiet telcoin" "$(cat "$T/systemctl.log" 2>/dev/null)"
SNA_ENABLE=pending SNA_ALERTS_RC=1 drv step
check "step: enable refused, stays pending" "0 ENABLE_ALERTS=pending" "$RC $(printf '%s\n' "$OUT" | tail -n 1)"
check "step: enable refused, warns with the command" yes \
    "$(has "$OUT" "Private alerts were not set up (setup-alerts.sh exit 1, see above); they stay pending. To finish: sudo bash setup-alerts.sh")"
SNA_ENABLE=pending SNA_ALERTS_RC=3 drv step
check "step: enable failed after a change, stays pending" "ENABLE_ALERTS=pending yes" \
    "$(printf '%s\n' "$OUT" | tail -n 1) $(has "$OUT" "setup-alerts.sh exit 3")"
SNA_ENABLE=pending SNA_NETWORK=mainnet drv step
check "step: runs on mainnet too" "ENABLE_ALERTS=true --enable " "$(printf '%s\n' "$OUT" | tail -n 1) $(argv)"
mv "$T/sn/setup-alerts.sh" "$T/sn/setup-alerts.sh.away"
SNA_ENABLE=pending drv step
mv "$T/sn/setup-alerts.sh.away" "$T/sn/setup-alerts.sh"
check "step: setup-alerts.sh missing, stays pending" "ENABLE_ALERTS=pending yes" \
    "$(printf '%s\n' "$OUT" | tail -n 1) $(has "$OUT" "setup-alerts.sh is missing (${T}/sn/setup-alerts.sh), so private alerts stay pending. Restore it with update-scripts.sh, then run: sudo bash setup-alerts.sh")"
check "step: main runs it after the add-ons, before the host baseline" "step_testnet_addons step_alerts step_host_baseline" \
    "$(sed -n '/^main() {/,/^}/p' "$SN" | grep -o '^    step_testnet_addons$\|^    step_alerts$\|^    step_host_baseline$' | tr -d ' ' | tr '\n' ' ' | sed 's/ $//')"

# -----------------------------------------------------------------------------
# step_final_summary
# -----------------------------------------------------------------------------
SNA_ENABLE=true drv summary
check "summary: on" "yes no" "$(has "$OUT" "Private alerts: on") $(has "$OUT" "Private alerts: pending")"
SNA_ENABLE=pending drv summary
check "summary: pending, with the command" yes "$(has "$OUT" "Private alerts: pending. To finish: sudo bash setup-alerts.sh")"
SNA_ENABLE=false drv summary
check "summary: off says nothing about private alerts" "no yes" "$(has "$OUT" "Private alerts") $(has "$OUT" "Useful commands")"

# --help names the section and the --json command.
OUT="$(bash "$SN" --help 2>&1)"
check "--help: the private alerts section" "yes yes" \
    "$(has "$OUT" "PRIVATE ALERTS (optional, every network)") $(has "$OUT" "setup-alerts.sh --json --enable --targets-stdin")"

finish
