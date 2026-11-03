#!/usr/bin/env bash
# Run: docker run --rm -v "$PWD:/w" ubuntu:24.04 bash /w/tasks/verify-fup/V2/repro/repro-n1.sh
# N: tn_host_baseline_install accepts an existing /var/lib/aide owned by another account
set -u
mkdir -p /tmp/st /etc/telcoin /etc/systemd/system /var/lib/telcoin/node-keys /etc/audit/rules.d /var/lib/aide
for t in apt-get augenrules; do printf '#!/bin/sh\nexit 0\n' > /tmp/st/$t; done
printf '#!/bin/sh\necho "-w /var/lib/telcoin/node-keys -p rwxa -k telcoin-keys"\n' > /tmp/st/auditctl
printf '#!/bin/sh\nprintf db > /var/lib/aide/telcoin-node.db.new\nexit 0\n' > /tmp/st/aide
chmod 0755 /tmp/st/*; export PATH=/tmp/st:$PATH
chown nobody /var/lib/aide; chmod 0777 /var/lib/aide
printf 'OWNERSHIP_LAYOUT=2\nDATA_DIR=/var/lib/telcoin\n' > /etc/telcoin/.node-meta; chmod 600 /etc/telcoin/.node-meta
printf '[Service]\nExecStart=/usr/local/libexec/telcoin/tn-start\n' > /etc/systemd/system/telcoin.service
. /w/tools/tests/lib.sh; TN_ROOT_PREFIX=""; eval "$(tn_test_source_common)"
tn_host_baseline_install >/dev/null 2>&1; echo "install rc=$?"
ls -ld /var/lib/aide | awk '{print $1, $3}'; ls -l /var/lib/aide/telcoin-node.db | awk '{print $1, $3}'
tn_root_dir_ok /var/lib/aide; echo "tn_root_dir_ok /var/lib/aide rc=$?"
