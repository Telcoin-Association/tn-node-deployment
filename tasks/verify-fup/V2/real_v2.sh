#!/usr/bin/env bash
# =============================================================================
# V2 real-tool run, AUDIT package: in a disposable ubuntu:24.04 container, as
# root, with the real auditd and aide packages, the library functions run
# against host paths (TN_ROOT_PREFIX empty). Proves the AIDE config parses, the
# exit codes of aide --check before and after a change to a watched file and
# after a refresh, that the credential, the ingest token, the root writers' temp
# files and /opt/telcoin-source are left out, and what augenrules/auditctl do in
# a container without kernel audit.
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tasks/verify-fup/V2/real_v2.sh
# Refuses to run outside a container.
# =============================================================================
set -u
if [[ ! -f /.dockerenv || "$(id -u)" != 0 ]]; then
    echo "real_v2.sh: run it only as root in a disposable container" >&2
    exit 2
fi
V2_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2_REPO="${V2_REPO:-$(cd "$V2_DIR/../../.." && pwd)}"
# shellcheck source=/dev/null
. "$V2_REPO/tools/tests/lib.sh"
echo "== installing auditd and aide (real packages)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q >/dev/null 2>&1
apt-get install -y -q --no-install-recommends auditd aide >/dev/null 2>&1
echo "apt-get rc=$?"
printf 'versions: %s | %s\n' "$(aide --version 2>&1 | head -1)" "$(dpkg-query -W -f='${Version}' auditd 2>/dev/null)"
check "real: aide, augenrules, auditctl installed" "yes yes yes" \
    "$(command -v aide >/dev/null && echo yes) $(command -v augenrules >/dev/null && echo yes) $(command -v auditctl >/dev/null && echo yes)"
check "real: no recommended packages pulled (no mail server, no aide-common cron)" "no" \
    "$(dpkg-query -W -f='${Status}\n' postfix exim4-daemon-light 2>/dev/null | grep -q 'install ok installed' && echo yes || echo no)"

# A node install at the host paths.
mkdir -p /etc/telcoin/alloy /var/lib/telcoin/node-keys /opt/telcoin /opt/telcoin-source /usr/local/libexec/telcoin
chmod 0755 /etc/telcoin /opt/telcoin /usr/local/libexec/telcoin
chmod 0700 /var/lib/telcoin
printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nINSTALL_METHOD=docker\nDATA_DIR=/var/lib/telcoin\nPASSPHRASE_METHOD=credential\n' > /etc/telcoin/.node-meta
chmod 0600 /etc/telcoin/.node-meta
printf '[Service]\nLoadCredentialEncrypted=bls-passphrase:/etc/telcoin/bls-passphrase.cred\nExecStart=/usr/local/libexec/telcoin/tn-start-docker\n' > /etc/systemd/system/telcoin.service
printf 'binary v1\n' > /opt/telcoin/telcoin-network
printf 'src\n' > /opt/telcoin-source/README
printf '#!/bin/bash\nexec docker run img telcoin node --http\n' > /usr/local/libexec/telcoin/tn-start-docker
printf 'cred-v1\n' > /etc/telcoin/bls-passphrase.cred; chmod 0600 /etc/telcoin/bls-passphrase.cred
printf 'token-v1\n' > /etc/telcoin/alloy/ingest-token; chmod 0640 /etc/telcoin/alloy/ingest-token
# Where lib/observability.sh keeps the ingest token at this tip (_obs_write_env_file).
printf 'OBS_INGEST_TOKEN=V2-ingest-token-1\n' > /etc/telcoin/alloy/telcoin-alloy.env; chmod 0600 /etc/telcoin/alloy/telcoin-alloy.env
printf 'RPC_PORT=8545\n' > /etc/telcoin/node.env
printf 'key\n' > /var/lib/telcoin/node-keys/bls.key

TN_ROOT_PREFIX=""
eval "$(tn_test_source_common)"
CONF=/etc/aide/telcoin-node.conf
achk() { aide --config="$CONF" --check >/dev/null 2>&1; echo "$?"; }

echo "== tn_host_baseline_install (real)"
t0="$(date +%s)"
out="$(tn_host_baseline_install 2>&1)"; rc=$?
t1="$(date +%s)"
printf '%s\n' "$out" | sed 's/^/  | /'
printf 'install rc=%s in %ss\n' "$rc" "$((t1 - t0))"
check_rc "real: install rc 0" 0 "$rc"
check "real: HOST_BASELINE=true" "true" "$(meta_get HOST_BASELINE)"
check "real: rules file root 0640" "root:root 640" "$(stat -c '%U:%G %a' /etc/audit/rules.d/telcoin-node.rules)"
ar=0; augenrules --load >/dev/null 2>&1 || ar=$?
ac=0; auditctl -l >/dev/null 2>&1 || ac=$?
printf 'augenrules --load rc=%s, auditctl -l rc=%s (no kernel audit in a container)\n' "$ar" "$ac"
check "real: the install said the rules did not load now" yes "$(case "$out" in *"did not load now"*) echo yes ;; *) echo no ;; esac)"
check "real: augenrules accepts the rules file (it is in audit.rules)" yes \
    "$(grep -q -- '-w /var/lib/telcoin/node-keys -p rwxa -k telcoin-keys' /etc/audit/audit.rules 2>/dev/null && echo yes || echo no)"
check "real: auditctl parses each rule line" "" "$(grep '^-w' /etc/audit/rules.d/telcoin-node.rules | while IFS= read -r l; do auditctl $l 2>&1 | grep -iE 'unknown|invalid|syntax' ; done)"

cc=0; aide --config="$CONF" --config-check >/dev/null 2>&1 || cc=$?
check_rc "real: aide --config-check of the node config" 0 "$cc"
check "real: database root 0600, /var/lib/aide root 0700, /etc/aide root 0755" "root:root 600 root:root 700 root:root 755" \
    "$(stat -c '%U:%G %a' /var/lib/aide/telcoin-node.db) $(stat -c '%U:%G %a' /var/lib/aide) $(stat -c '%U:%G %a' /etc/aide)"
check "real: database made, no .new left" "yes no" "$([[ -s /var/lib/aide/telcoin-node.db ]] && echo yes || echo no) $([[ -e /var/lib/aide/telcoin-node.db.new ]] && echo yes || echo no)"
db="$(cat /var/lib/aide/telcoin-node.db)"
inc() { case "$db" in *"$1 "*|*"$1"$'\n'*) echo yes ;; *) echo no ;; esac; }
check "real: database holds /opt/telcoin/telcoin-network" yes "$(inc /opt/telcoin/telcoin-network)"
check "real: database holds the start script" yes "$(inc /usr/local/libexec/telcoin/tn-start-docker)"
check "real: database holds the unit" yes "$(inc /etc/systemd/system/telcoin.service)"
check "real: database holds .node-meta and node.env" "yes yes" "$(inc /etc/telcoin/.node-meta) $(inc /etc/telcoin/node.env)"
check "real: database leaves out the credential" no "$(inc /etc/telcoin/bls-passphrase.cred)"
check "real: database leaves out the ingest token" no "$(inc /etc/telcoin/alloy/ingest-token)"
check "[finding N-2] real: database leaves out the Alloy env file that holds the token at this tip" no "$(inc /etc/telcoin/alloy/telcoin-alloy.env)"
check "real: database leaves out /opt/telcoin-source" no "$(inc /opt/telcoin-source/README)"
check "real: database leaves out the node keys and the data dir" no "$(inc /var/lib/telcoin/node-keys/bls.key)"
check "real: database holds no other unit" no "$(case "$db" in *"/etc/systemd/system/"[!t]*) echo yes ;; *) echo no ;; esac)"
printf 'database entries: %s\n' "$(grep -c '^/' /var/lib/aide/telcoin-node.db)"

echo "== aide --check exit codes"
check "real: --check right after install: 0" 0 "$(achk)"
printf 'binary v2\n' > /opt/telcoin/telcoin-network
r="$(achk)"
check "real: --check after the binary changed: rc 4" 4 "$r"
out="$(tn_host_baseline_refresh 2>&1)"; rc=$?
printf '%s\n' "$out" | sed 's/^/  | /'
check "real: refresh rc 0" 0 "$rc"
check "real: --check after the refresh: 0" 0 "$(achk)"
printf 'cred-v2\n' > /etc/telcoin/bls-passphrase.cred
printf 'token-v2\n' > /etc/telcoin/alloy/ingest-token
printf 'x\n' > /etc/telcoin/bls-passphrase.new
printf 'x\n' > /etc/telcoin/.tn.AbC123
printf 'y\n' > /opt/telcoin-source/NEW
check "real: --check after credential, token, temp files and /opt/telcoin-source changed: 0" 0 "$(achk)"
rm -f /etc/telcoin/bls-passphrase.new /etc/telcoin/.tn.AbC123
printf 'RPC_PORT=8546\n' > /etc/telcoin/node.env
check "real: --check after node.env changed: 4" 4 "$(achk)"
tn_host_baseline_refresh >/dev/null 2>&1
printf 'z\n' > /etc/telcoin/added-file
check "real: --check after a file was added to /etc/telcoin: 1" 1 "$(achk)"
rm -f /etc/telcoin/added-file
printf '[Service]\nExecStart=/bin/evil\n' > /etc/systemd/system/telcoin.service
check "real: --check after the unit changed: 4" 4 "$(achk)"
printf 'evil\n' > /etc/systemd/system/other.service
r="$(achk)"
check "real: another unit in /etc/systemd/system is not watched" 4 "$r"
rm -f /etc/systemd/system/other.service
tn_host_baseline_refresh >/dev/null 2>&1
printf '#!/bin/bash\nexec evil\n' > /usr/local/libexec/telcoin/tn-start-docker
check "real: --check after the start script changed: 4" 4 "$(achk)"
tn_host_baseline_refresh >/dev/null 2>&1
chmod 0777 /opt/telcoin/telcoin-network
check "real: --check after a mode change: 4" 4 "$(achk)"
chmod 0755 /opt/telcoin/telcoin-network
tn_host_baseline_refresh >/dev/null 2>&1
meta_set FOO bar >/dev/null 2>&1
check "real: --check after a meta_set (rename write): 4 (.node-meta is watched)" 4 "$(achk)"
tn_host_baseline_refresh >/dev/null 2>&1
check "real: after a refresh the check is clean again" 0 "$(achk)"

echo "== status and remove (real)"
out="$(tn_host_baseline_status)"; rc=$?
printf '%s\n' "$out" | sed 's/^/  | /'
check "real: status rc 1 (rules not loaded in a container)" 1 "$rc"
out="$(tn_host_baseline_remove 2>&1)"; rc=$?
printf '%s\n' "$out" | sed 's/^/  | /'
check "real: remove rc 0" 0 "$rc"
check "real: remove: files gone" "no no no" "$([[ -e /etc/audit/rules.d/telcoin-node.rules ]] && echo yes || echo no) $([[ -e $CONF ]] && echo yes || echo no) $([[ -e /var/lib/aide/telcoin-node.db ]] && echo yes || echo no)"
check "real: remove: packages still installed" "install ok installed
install ok installed" "$(dpkg-query -W -f='${Status}\n' auditd aide 2>/dev/null)"
check "real: remove: the rules are out of audit.rules after augenrules" no \
    "$(grep -q telcoin-keys /etc/audit/audit.rules 2>/dev/null && echo yes || echo no)"
check "real: remove: marker gone" "" "$(meta_get HOST_BASELINE 2>/dev/null)"
finish
