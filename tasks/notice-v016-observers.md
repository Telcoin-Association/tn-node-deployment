# Notice for third-party observer operators: adiri moves to v0.16.0-adiri

Source: risk report §7.7 (`tn-workspace/shared/reports/report-update-v0.16.0-adiri.md`), with the
wording adjusted because the release ships commit d72cc2bc exactly (no M1 record-penalty change and no
M2 `--observer` no-op). The operator sends this; the orchestrator only drafted it.

---

The adiri validators are moving from v0.15.0-adiri to v0.16.0-adiri (telcoin-network commit
d72cc2bc, image `us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.16.0-adiri`, linux/amd64).

Before you upgrade your observer, check three things.

First, your advertised address must not be 0.0.0.0, :: or port 0, or v0.16 refuses to start. If you use
a DNS name, make it IPv4-only or IPv6-only (`/dns4` or `/dns6`).

Second, remove `--observer` from your command line. v0.16 exits at once when it sees the flag
(`unexpected argument '--observer'`). Node role is derived from committee membership each epoch.

Third, make sure you have free disk of at least twice your largest epoch directory
(`consensus-db/epochs/epoch-N`), because old data is converted in place on first start.

Stop the node and take a full copy of the data directory before the first start on v0.16. After v0.16
has run on that directory, v0.15 cannot open it (it fails with `invalid version`), and the copy is your
only way back. The public `update-node.sh` 1.2.1 warns about this, waits up to 600 seconds for the first
start, and never rolls the binary back on its own for this update.

If you stay on v0.15 with a clean IP address, your node keeps working and keeps syncing.

If you stay on v0.15 with 0.0.0.0, a DNS name or port 0 as your address, upgraded validators reject your
node record and disconnect your node for about 35 minutes at a time, and other nodes will struggle to
find you.

Publish a single address for now; v0.15 nodes reject a node that publishes more than one, and v0.16
will not start with a longer list.

Health checks that parse `/health/workers` should expect a brief "not accepting" at each epoch
boundary. `/health/network` is new on the same port.

The RPC port now opens before the node has caught up, so check `eth_syncing` before sending traffic.

Support: support@telcoin.org
