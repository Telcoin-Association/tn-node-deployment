# Run: docker run --rm -v "$PWD:/w" ubuntu:24.04 bash /w/tasks/verify-fup/V2/repro/repro-s3.sh
# S-3: setup-node calls tn_host_baseline_install without listing it in tn_require_fns:
# a lib/common.sh 2.x without the tn_host_baseline_* functions passes the up-front check.
set -u
W=/tmp/s3; rm -rf /tmp/s3; mkdir -p $W/h $W/lib $W/fx/etc/systemd/system $W/fx/etc/telcoin
for f in /w/lib/*; do [ "${f##*/}" = common.sh ] || ln -s "$f" "$W/lib/${f##*/}"; done
awk '/^tn_host_baseline_(install|refresh|remove|status)\(\) \{$/ {s=1; next} s && /^\}$/ {s=0; next} s {next} {print}' /w/lib/common.sh > $W/lib/common.sh
cp /w/setup-node.sh $W/h/setup-node.sh; ln -s $W/lib $W/h/lib
printf '[Service]\nExecStart=/usr/local/libexec/telcoin/tn-start\n' > $W/fx/etc/systemd/system/telcoin.service
printf 'OWNERSHIP_LAYOUT=2\n' > $W/fx/etc/telcoin/.node-meta
TN_ROOT_PREFIX=$W/fx TN_UPDATE_LOCK_FILE=$W/lock bash $W/h/setup-node.sh --host-baseline 2>&1 | tail -4; echo "exit=${PIPESTATUS[0]}"
