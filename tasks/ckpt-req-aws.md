status: done

Commit a39170511fbdf88d6e417a804dc6b952ff742c0b on req/aws (aws/node.yaml only; no attribution lines).
Fix round (V-AWS-1, -2, -6): commit 045f072779fbd3a5c3cd927866589c03802907d1 on top, aws/node.yaml only.

# Checkpoint: implementer AWS (req round 2026-11-21)

Worktree /home/drtnarg/coding/telcoin/tnd-req-aws, branch req/aws, base 01664cc.
Not committed (leave untracked).

## Sections

- [x] 1. template (aws/node.yaml)
- [x] 2. rules and tests (aws/rules/**): no change (see notes)
- [x] 3. tool install commands
- [x] 4. gates
- [x] 5. update-behaviour answers
- [x] 6. commit (a391705)
- [x] 7. fix round V-AWS-1/-2/-6 (045f072)

## 7. Fix round (done, commit 045f072)

- V-AWS-1: Preset description now opens "Each preset follows the recommended testnet figures for
  cores and RAM." DataVolumeSize description ends "It is provisioned at 15000 IOPS and 300 MiB/s.
  A c7i.2xlarge (the FullNode and Validator presets) sustains 12000 IOPS to EBS and 15000 in
  bursts; a c7i.4xlarge (PublicRPC) sustains the full 15000."
- V-AWS-2: DataVolume comment: "A c7i.2xlarge sustains 12000 IOPS to EBS; above that it bursts,
  for 30 minutes at least once every 24 hours, up to the volume's 15000."
- V-AWS-6: MiB/s for the volume throughput and the gp3 ratio (description and comment).
- Rendered lengths: Preset 386, DataVolumeSize 387 (limit 4000). `grep -c '26\.04'` = 4.
- Gates at 045f072: cfn-lint 1.60.1 rc 0; cfn-guard 3.2.2 validate rc 0 (9 rules PASS), test
  rc 0 (29 cases, 0 mismatches); ci_pins_test 62 checks 0 failures; network-hits clean (153).

## 5. Update-behaviour answers (done; T = from the template, M = from memory, unverified)

Common to all three: every stack update re-resolves the ImageId SSM parameter; once a newer
Canonical image exists the update tries to replace the instance and rolls back (T, ImageId
description). Mechanism: the instance owns the stack's ENI at DeviceIndex 0, and a replacement
instance is created before the old one goes, so it cannot take the attached ENI (T for the
attachment, M for the create-before-delete order and the error). NodeInstance's user data
`!Sub`s `${DataVolume}`, so the volume is updated before the instance (T for the dependency, M
for the order).

(a) Validator preset, InstanceType empty: resolved type c7i.8xlarge -> c7i.2xlarge only via
  the mapping and only with no override (T). AWS::EC2::Instance InstanceType = "Some
  interruptions" on EBS-backed instances: stop, modify, start; no replacement (M). The node stops
  with the instance, no epoch-boundary wait (T: update-node.sh is not involved; the template has
  no other path). ENI/EIP/data volume stay; user data does not rerun (T: "cloud-init runs this
  once ... on the first boot"). FullNode and PublicRPC stacks see no type change (T).
(b) DataVolumeSize stays 2000: only Iops 10000 -> 15000 (T; 2000 still allowed, so the parameter
  validates). Volume Iops = "No interruption": CloudFormation calls ModifyVolume; the volume
  stays attached, goes modifying -> optimizing, no data loss (M). Risk: EBS limits how soon a
  volume can be modified again (historically 6 h; may be relaxed) (M), so a rollback of the same
  update (e.g. the ImageId replacement failing) that tries to set 10000 again can fail ->
  UPDATE_ROLLBACK_FAILED (M). Also unknown: whether ModifyVolume rejects a no-op when the
  operator already set 15000 in the console per F10 (M).
(c) Smaller size than the current volume: now possible to pick (350/500 are allowed values) (T).
  Size = "No interruption" -> ModifyVolume with a smaller size -> EBS refuses a decrease -> the
  update fails and rolls back; the volume and its data are untouched (M). Even if it were a
  replacement, DeletionPolicy and UpdateReplacePolicy Retain keep the old volume (T).
  Related (T): a grow (2000 -> 4000) is not followed by a filesystem grow; nothing in the
  template runs resize2fs.

## 4. Gates (done, on the uncommitted tree = 01664cc + the template edit)

- cfn-lint 1.60.1 (Python 3.12.16, python:3.12-slim, `--require-hashes`): `cfn-lint aws/node.yaml` rc 0.
  Live-check: a scratch copy with `Default: 600` gives E2015, rc 2.
- cfn-guard 3.2.2 (sha256 65ce4d16... OK): `validate --rules aws/rules --data aws/node.yaml
  --show-summary fail` rc 0 (all 9 rules PASS with `--show-summary all`);
  `test --dir aws/rules` rc 0, 29 test cases, 0 mismatches.
- `bash tools/tests/run.sh tools/tests/ci_pins_test.sh`: 62 checks, 0 failures.
- `bash tools/check-network-hits.sh`: clean, 153 annotated hits (aws/ is outside its scope).
- No fixture under tools/tests or ui/tests reads aws/ (grep for aws|cfn|node.yaml: none).
- User data and SSM documents not edited, so no bash -n / shellcheck extraction needed.
- Rendered (cfnlint.decode): Preset/DataVolumeSize descriptions as in the hand-back;
  Mapping {FullNode c7i.2xlarge, PublicRPC c7i.4xlarge, Validator c7i.2xlarge};
  DataVolume gp3 / 15000 / 300 / encrypted.

## 1. Template (done, uncommitted)

- Preset description (:50-56): one line per preset with `c7i.Nxlarge, N cores (M vCPU), K GiB`;
  Validator says "the same size as FullNode".
- DataVolumeSize (:67-78): Default 500; AllowedValues 350, 500, 2000, 4000; new description.
- Mapping Validator (:105): c7i.8xlarge -> c7i.2xlarge.
- DataVolume (:288-293): 4-line comment (gp3 ratios, c7i.2xlarge EBS baseline), Iops 15000,
  Throughput 300 unchanged.
- `grep -c '26\.04' aws/node.yaml` = 4 (unchanged). ImageId untouched.
- gp3 ratios: 15000 IOPS needs >= 30 GiB (smallest allowed 350); 300 MiB/s needs >= 1200 IOPS
  (15000). Within the old 16000-IOPS / 1000 MiB/s gp3 caps too.

## 2. Rules (done: no change)

- No rule or rule test pins a size, IOPS, throughput or instance type. storage_tests.yaml uses
  `Size: 2000` / `VolumeSize: 50` only as synthetic inputs; no rule reads them; 2000 is still an
  allowed value. Left as is.
- Did not add an IOPS-floor rule: aws/rules are the security-posture rules and AGENTS.md
  ("AWS one-click stack") enumerates what they pin; I cannot edit AGENTS.md. Open question.

## 3. Tool install commands (done)

```
S=/var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/46275ae3-5cf9-4f35-b799-c09950443243/scratchpad
T=$S/aws-req-tools; W=/home/drtnarg/coding/telcoin/tnd-req-aws
mkdir -p "$T/guard-dl" "$T/cfn-guard" "$T/venv312"
# cfn-guard 3.2.2, sha256 as pinned in .github/workflows/ci.yml
curl --proto '=https' --tlsv1.2 -fsSL -o "$T/guard-dl/cfn-guard.tar.gz" \
  "https://github.com/aws-cloudformation/cloudformation-guard/releases/download/3.2.2/cfn-guard-v3-x86_64-ubuntu-latest.tar.gz"
echo "65ce4d16c4cc26fac37176a7127ba3f36b5aef12e3afd9b847f7c1e8c3d823d7  $T/guard-dl/cfn-guard.tar.gz" | sha256sum -c -
tar -xzf "$T/guard-dl/cfn-guard.tar.gz" -C "$T/cfn-guard" --strip-components=1
"$T/cfn-guard/cfn-guard" --version        # cfn-guard 3.2.2
# cfn-lint 1.60.1 by hash, Python 3.12.16 (python:3.12-slim), venv in scratch
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$W/aws/requirements-ci.txt:/req/requirements-ci.txt:ro" -v "$T/venv312:/venv" python:3.12-slim sh -c \
  'python -m venv /venv && /venv/bin/python -m pip install -q --require-hashes -r /req/requirements-ci.txt && /venv/bin/cfn-lint --version'
```

Run:

```
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$W:/w:ro" -w /w -v "$T/venv312:/venv:ro" python:3.12-slim /venv/bin/cfn-lint aws/node.yaml
cd "$W" && "$T/cfn-guard/cfn-guard" validate --rules aws/rules --data aws/node.yaml --show-summary fail
cd "$W" && "$T/cfn-guard/cfn-guard" test --dir aws/rules
```

Baseline at 01664cc (unchanged template): all three rc=0.

## Notes

- Read: spec 0, 1, 3.1, 3.6, 5 F9/F10; AGENTS.md "AWS one-click stack"; project-context AWS map.
- Volume-size dependencies: user data has no size check, no df threshold; mkfs.ext4 default 5 %
  root reserve; nothing grows the filesystem after a volume grows (no resize2fs). Rules: none.
  Outside aws/: lib/common.sh:87-90 HW_*_MIN_DISK_GB=2000 (warn only) on main -> HW-SH makes
  testnet 350/500.
