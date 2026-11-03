#!/usr/bin/env bash
# Run: docker run --rm -v "$PWD:/w" bash:3.2 bash /w/tasks/verify-fup/V2/repro/repro-k1.sh
# K-1: under a setpriv that exits 1 (busybox), tn_keytool_has reports "not listed" (1), not "probe failed" (4)
mkdir -p /opt/b; chmod 0755 /opt/b
printf '#!/bin/sh\nprintf "Commands:\\n  verify    Check the passphrase\\n"\n' > /opt/b/tn; chmod 0755 /opt/b/tn
. /w/tools/tests/lib.sh; TN_ROOT_PREFIX=""; eval "$(tn_test_source_common)"
SERVICE_USER=nobody; SERVICE_GROUP=nobody
/opt/b/tn keytool --help | head -2
tn_keytool_has binary:/opt/b/tn verify; echo "tn_keytool_has rc=$? (expected 4: the probe could not run as the service user)"
