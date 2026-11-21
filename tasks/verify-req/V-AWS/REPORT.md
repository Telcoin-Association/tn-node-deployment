# V-AWS report: the Validator preset and data volume change (6aebeee, tip 1a3404b)

Verifier V-AWS, 2026-11-21. Worktree `/home/drtnarg/coding/telcoin/tnd-req-v-aws` at `1a3404b`, no tracked file edited. Scratch output in `/var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/46275ae3-5cf9-4f35-b799-c09950443243/scratchpad/v-aws/` (written `S/` below). I formed every answer before reading `tasks/ckpt-req-aws.md`; the last section compares the two.

Verdict: the template change is correct as a change. Lint and guard are green at the CI pins, every number in the template agrees with the new values, every allowed size is a valid gp3 configuration, and each preset passes the shell hardware check for its role. One substantive point is for the user to decide (V-AWS-1): on the two `c7i.2xlarge` presets the instance holds EBS to 12,000 IOPS sustained, below the 15,000 IOPS testnet minimum, and the template's console text does not say so. F9 needs small corrections. F10 is correct as far as it goes, but it leaves out how an update of an old stack actually fails, the modification limits, and the filesystem grow.

## Gates

| Gate | Tool and version | Result |
|---|---|---|
| `cfn-lint aws/node.yaml` | cfn-lint 1.60.1 in my own venv (`S/venv-own`), built in `python:3.12-slim` (Python 3.12) with `pip install --require-hashes -r aws/requirements-ci.txt`; `pip freeze` matches the 9 pins | rc 0 |
| `cfn-guard validate --rules aws/rules --data aws/node.yaml --show-summary fail` | cfn-guard 3.2.2; tarball sha256 `65ce4d16…d823d7` = `ci.yml` `GUARD_SHA256`; re-extracted to `S/guard-x1` | rc 0; `--show-summary all`: all 9 rules PASS, none SKIP, on both `01664cc` and the tip |
| `cfn-guard test --dir aws/rules` | same | rc 0, 29/29 cases "PASS Rules" over 4 files (`S/guard-test-tip.out`) |
| Lint is live | broken copies in `S/neg-a1/` | `Default: 300` → E2015 rc 2; a literal `InstanceType: c7i.2xlargee` → E3628 rc 6; `Encrypted: false` on DataVolume → guard FAIL `storage.guard/data_volumes_encrypted` rc 19 |
| Harness `*.sh` | shellcheck 0.11.0, bash 5.3.9, `bash:3.2`, `tools/check-bash32.sh` | both files: shebang; `--severity=error` clean (2 warnings: SC2034 through `eval`, SC2319); `bash -n` clean under bash 5 and 3.2; check-bash32 clean |
| `hw_presets.sh` | real `check_hardware` | 87 checks, 0 failures under host bash 5, `bash:3.2` and `ubuntu:26.04` |

## Findings

| Id | Severity | One line |
|---|---|---|
| V-AWS-1 | Medium | The `FullNode` and `Validator` presets (c7i.2xlarge) sustain 12,000 IOPS to EBS, below the 15,000 IOPS testnet minimum, while the console text says "recommended testnet hardware" and "It runs at 15000 IOPS" |
| V-AWS-2 | Low | "bursts to 40000 for 30 minutes a day" (template comment, F9): the node can never see 40,000 on a 15,000 IOPS volume, and AWS states 30 minutes as a minimum, "at least once every 24 hours" |
| V-AWS-3 | Low | F10 is incomplete: an old stack's update fails for every preset once Canonical's image has moved, and its rollback then waits out the volume modification; F10 does not give the EBS modification limits or say that a grown volume needs a filesystem grow |
| V-AWS-4 | Low | Nothing grows the ext4 filesystem after the volume grows (spec 6.2 item confirmed); the docs must give the command and must not repeat AWS's "snapshot first" advice |
| V-AWS-5 | Low | OPERATOR.md:763 "the stack rolls back unchanged" is wrong for an update that modifies the volume, and with this template every update of an old stack does (Iops 10000 → 15000) |
| V-AWS-6 | Info | gp3 `Throughput` is MiB/s; the template and F9 say "MB/s" ("0.25 MB/s per IOPS" mislabels AWS's MiB/s). No figure is wrong in effect |
| V-AWS-7 | Info | cfn-lint does not check the preset instance types in the Mapping, nor gp3 IOPS and throughput ranges and ratios; a typo or a bad value passes CI. A guard rule is the wrong place for that (A7) |
| V-AWS-8 | Info | RAM on the 16 GiB presets clears the 16 GB tier by about 819 MiB of kernel reservations; a 512 MiB crashkernel would flip the RPC and validator lines to "below minimum". Not expected on the AMI; not measured |
| V-AWS-9 | Info | Doc lines that still carry the old values, and two that write vCPU before cores (input for wave 3) |

### V-AWS-1 (Medium): the c7i.2xlarge presets do not sustain the testnet IOPS minimum

- **Expected:** a preset that the template calls "the recommended testnet hardware for its role" (`aws/node.yaml:51`) delivers the testnet storage minimum, `350 GB SSD (15,000 IOPS, 240 MB/s)` (spec 3.1). That is the limit the reference validators run under: pd-ssd on `c3-highcpu-8`, capped at 15,000 IOPS sustained (spec section 1).
- **Got:** the volume is provisioned at 15,000 IOPS, but a `c7i.2xlarge` holds EBS to 12,000 IOPS and 312.5 MB/s baseline. It reaches its 40,000 IOPS maximum only "for 30 minutes at least once every 24 hours, after which they revert to their baseline performance".
  - On `FullNode` and `Validator` the node therefore gets min(15,000, 12,000) = **12,000 IOPS sustained**, 80 % of the minimum, and 15,000 in bursts.
  - `PublicRPC` (`c7i.4xlarge`, baseline 20,000 IOPS and 625 MB/s) sustains the full 15,000 IOPS and 300 MiB/s.
  - The only place that says so is the YAML comment at `:288-291`, which the console does not show. The console text reads "It runs at 15000 IOPS and 300 MB/s" (`:78`).
  - Compared with the old template, the sustained figure went up, not down: the old volumes ran at 10,000 IOPS on every preset. The gap is against the new table.
- **Also:** the table's recommended storage is "500 GB TLC NVMe". A gp3 volume is network storage that a Nitro instance presents as an NVMe device; it is not a TLC NVMe drive. The presets follow the recommended column in CPU, RAM and disk size, but not in storage medium.
- **Source:** AWS EC2 "compute optimized" instance-types page (`docs.aws.amazon.com/ec2/latest/instancetypes/co.html`), Amazon EBS specifications, read 2026-11-21:
  - `c7i.2xlarge 1 | 2500.00 / 10000.00 | 312.50 / 1250.00 | 12000.00 / 40000.00`
  - `c7i.4xlarge 1 | 5000.00 / 10000.00 | 625.00 / 1250.00 | 20000.00 / 40000.00`
  - footnote 1 as quoted above.
- **Suggested fix (the user decides):**
  - (a) Keep `c7i.2xlarge` and say it where the operator reads it. The `DataVolumeSize` description becomes "… It is provisioned at 15000 IOPS and 300 MiB/s; a c7i.2xlarge (FullNode, Validator) sustains 12000 IOPS to EBS and 15000 in bursts", and F9 takes the replacement wording below.
  - (b) Map `Validator` to `c7i.4xlarge` (8 cores (16 vCPU), 32 GiB, baseline 20,000 IOPS). It sustains the minimum at about twice the instance price.
  - (a) is enough for testnet's load; the benchmark figures in spec section 1 are mainnet-scale.

### V-AWS-2 (Low): the burst figure

- **Expected:** the burst the node can actually get.
- **Got:** `aws/node.yaml:290-291` and F9 say the instance "bursts to 40000 for 30 minutes a day". With `Iops: 15000`, the volume caps the burst at 15,000. And AWS's wording, "for 30 minutes at least once every 24 hours", is a floor, not a daily allowance.
- **Source:** as V-AWS-1.
- **Fix:** "a c7i.2xlarge sustains 12000 IOPS to EBS; above that it bursts, for 30 minutes at least once every 24 hours, up to the volume's 15000".

### V-AWS-3 (Low): F10 is right but incomplete

What a stack update does to a stack launched from `01664cc`, with this template:

| Case | Answer | Basis |
|---|---|---|
| (a) `Validator`, no `InstanceType` override | `DataVolume` is updated first (`NodeInstance`'s user data `!Sub`s `${DataVolume}`): Iops 10000 → 15000, no interruption. Then `InstanceType` c7i.8xlarge → c7i.2xlarge: "Some interruptions", i.e. stop, change, start. The node goes down outside the epoch-boundary wait. The ENI, EIP and data volume stay. User data does not rerun: it is unchanged, and cloud-init runs it once per instance | Documented: CFN `AWS::EC2::Instance` `InstanceType` "Update requires: Some interruptions" and "When you change your EBS-backed instance type, instance restart or replacement behavior depends on the instance type compatibility between the old and new types". Inferred: same family, so compatible (stop/start); resources are updated in dependency order |
| (b) `DataVolumeSize` stays 2000, only Iops changes | The parameter keeps its previous value (2000 is still allowed). ModifyVolume, no interruption. The volume cannot be modified again until this modification is `completed`, at most four times in a rolling 24 hours | Documented: CFN `AWS::EC2::Volume` `Iops` "Update requires: No interruption"; EBS "Modify … using Elastic Volumes": "you must wait for that modification to reach the `completed` state before you can initiate another modification for the same volume. You can modify a volume up to four times within a rolling 24-hour period"; "Typically, A 1-TiB volume can take up to six hours to be modified." Inferred: the previous parameter value is kept |
| (c) a smaller `DataVolumeSize` than the volume has (now selectable: 350, 500) | EBS refuses the decrease, the update fails and rolls back, and the volume and its data are untouched | Documented: CFN Volume page "Amazon EBS does not support sizing down an Amazon EBS volume"; EBS "You can't decrease the volume size." Inferred: Size and Iops go in one call, so nothing is half-applied |
| (d) the operator already raised Iops to 15,000 in the console, then updates | CFN compares templates, not the live volume, so it re-sends Iops 15000. Before the console modification is `completed`, that fails (EBS rule above) and the update rolls back. After it completes, the outcome is not documented (a no-op or an error) | Documented in part (the EBS rule); the rest is **not proved**. The drift page says only that changes made outside CloudFormation "can complicate stack update or deletion operations" |
| (e) the image parameter resolves to a newer AMI | `DataVolume`'s Iops change lands first. `ImageId` then forces a replacement, which fails because the old instance holds the ENI, and the stack rolls back. The rollback must wait until the volume modification completes (hours on 2000 GiB), with the stack in `UPDATE_ROLLBACK_IN_PROGRESS`, and then sets Iops back to 10,000. A grown Size would stay grown | Documented: `ImageId` "Update requires: Replacement"; `NetworkInterfaces` "you must terminate the original interface before attaching a new one to allow the update of the instance to succeed"; CFN Volume page "there is a cooldown period before another operation can occur. This can cause your stack to report being in `UPDATE_IN_PROGRESS` or `UPDATE_ROLLBACK_IN_PROGRESS` for long periods of time" … "the update succeeds but another change in your `update-stack` call fails. The rollback will be subject to a cooldown period" … "AWS CloudFormation does not attempt to modify an Amazon EBS volume to a smaller size on rollback." Inferred: the update order |

Pages read 2026-11-21:
- CloudFormation Template Reference: `aws-resource-ec2-instance.html`, `aws-resource-ec2-volume.html`.
- EBS User Guide: `ebs-modify-volume.html`, `modify-volume-requirements.html` (no waiting rule there now), `recognize-expanded-volume-linux.html`, `general-purpose.html`.
- CloudFormation User Guide: `using-cfn-stack-drift.html`.

- **Expected:** F10 tells an operator what to do and why.
- **Got:** F10's advice is right ("do not update"; raise IOPS in the console; grow but not shrink), and the Validator stop is real. What it leaves out:
  - the likelier failure: once Canonical's image has moved, every preset's update fails and sits in `UPDATE_ROLLBACK_IN_PROGRESS` for hours because of the Iops change;
  - the modification limits;
  - that a smaller size in an update fails;
  - the filesystem grow (V-AWS-4).
- **Suggested F10 (replacement wording):**

  > Existing stacks keep running as they are; nothing in this release needs a change on them. Do not update a stack to this template. Every stack update reads Canonical's image parameter again. Once a newer image is out, the update tries to replace the instance, fails because the old instance holds the network interface, and rolls back. The volume's IOPS change is made before that failure, so the rollback waits until the volume modification completes, which can take hours, and the stack shows `UPDATE_ROLLBACK_IN_PROGRESS` meanwhile. If the image has not changed, a `Validator` stack's update stops and starts the instance to change its type, outside the epoch-boundary wait of `update-node.sh`. Make changes on the resources instead. To raise the data volume to 15,000 IOPS, use the EC2 console (`Volumes`, `Modify volume`): the node keeps running, and the volume takes no other modification until this one shows `completed` (at most four modifications in 24 hours). To move a `Validator` to `c7i.2xlarge`, change the instance type in the EC2 console at a time when the node may restart. A volume can grow but not shrink, and a stack update that picks a smaller `DataVolumeSize` fails. After you grow a volume, grow its filesystem on the host: `sudo resize2fs "$(findmnt -no SOURCE /var/lib/telcoin)"` (the volume has no partition table, and ext4 grows while mounted). Do not snapshot the volume first: a snapshot is a copy of the node keys.

### V-AWS-4 (Low): nothing grows the filesystem

- **Expected:** a grown volume shows its new size to the node.
- **Got:** `git grep -n -I -E 'resize2fs|growpart|xfs_growfs|ModifyVolume|Elastic Volumes' -- ':!tasks/'` finds nothing.
  - The user data formats the whole device (`mkfs.ext4 -q -E nodiscard "$dev"`, no partition table), so `resize2fs` on the mounted device is the only step; `growpart` is not needed.
  - AWS: "After you increase the size of an EBS volume, you must extend the partition and file system to the new, larger size. You can do this as soon as the volume enters the `optimizing` state."
  - The same AWS page also says to "Create a snapshot of the volume" first. That conflicts with the repository's rule (AGENTS.md: "No snapshots or backup plan for the data volume: a snapshot is a copy of the node keys").
- **Fix:** the doc sentence in the F10 wording above. No code change is needed.

### V-AWS-5 (Low): "the stack rolls back unchanged"

- `OPERATOR.md:763` (section 2.11, "Changing the stack later") says: "Once a newer Ubuntu image is out, an update tries to replace the instance, which fails while the old instance holds the network interface, and the stack rolls back unchanged."
- For an update with this template, case (e) above applies: the rollback waits for the volume modification, and a grown size stays grown.
- **Fix:** wave 3 takes the F10 wording into that paragraph.

### V-AWS-6 (Info): MiB/s and MB/s

- gp3 `Throughput` is MiB/s (CFN: "a maximum of 2,000 MiB/s"; "0.25 MiB/s per IOPS"). The template says "300 MB/s" (`:78`, `:288`) and "0.25 MB/s per IOPS" (`:289`).
- 300 MiB/s is 314.6 MB/s. The instance table's MB/s is decimal (312.5 = 2,500 Mbps / 8, inferred), so a c7i.2xlarge holds sustained throughput to 312.5 MB/s = 298.0 MiB/s, a hair under the volume's 300 MiB/s.
- No statement is wrong in effect: "300 MB/s" is below what every preset gets, and far above the 240 MB/s minimum.
- **Fix:** write MiB/s in the template and in F9.

### V-AWS-7 (Info): what CI does not check

- cfn-lint returned rc 0 with nothing reported for each of these (reproduce with the copies m2, m3, m4, m7, m8 in `S/neg-a1/`):
  - `Iops: 90000` (gp3 maximum 80,000);
  - `Throughput: 2500` (maximum 2,000);
  - a typo `c7i.2xlargee` in the `Validator` Mapping (cfn-lint checks a literal type, E3628, but not one reached through `!FindInMap` inside `!If`);
  - an allowed size of 20 GiB with 15,000 IOPS (750 per GiB);
  - Iops 3000 with Throughput 1000 (ratio 0.33).
- **A7:** no rule in `aws/rules` reads a size, IOPS, throughput or instance type, so the change weakens no rule and makes none vacuous. `storage_tests.yaml` uses `Size: 2000` only as synthetic input.
- A guard rule pinning `Iops >= 15000` and the allowed sizes would not fit what AGENTS.md says the rules are for. Those are security posture: the role's principal and policy, no TCP 22 ingress, IMDSv2, encryption, retention, and the resource-type list. Such a rule would also block a deliberate later change of a performance figure.
- **Recommendation:** no guard rule. If a check is wanted, use a plain `tools/tests` case that reads the template and asserts the gp3 relations: `Iops <= 500 × min(AllowedValues)`, `Throughput <= 0.25 × Iops`, both within the per-volume maxima, and the three Mapping types against a short list.

### V-AWS-8 (Info): RAM margin on the 16 GiB presets

- The 16 GB tiers pass at MemTotal >= 15,938,355 kB (16 GiB × 95 %). A 16 GiB guest may therefore lose up to 838,861 kB (819 MiB) to the kernel and firmware.
- With the brief's 15.4 to 15.6 GiB, every role passes.
- A 512 MiB crashkernel (Ubuntu's `4G-32G:512M` tier) on top of about 400 MiB of normal reservations gives "Validator (minimum): below minimum — needs ≥ 16 GB RAM (have 15 GB RAM)" (harness case 5).
- That is not expected on this AMI. Ubuntu enables kdump by default only from 24.10, only "during standard Ubuntu Desktop or Ubuntu Server installations", and only when "the free space available in `/var` is more than 5 times the amount of RAM and swap space". Here that would be 80 GiB, against a 50 GiB root volume (ubuntu.com server docs "Kernel crash dump", read 2026-11-21).
- The real MemTotal of a c7i.2xlarge on the 26.04 AMI is **not proved**.

### V-AWS-9 (Info): doc lines for wave 3

- Old values:
  - `OPERATOR.md:687` (Validator c7i.8xlarge), `:689` (`2000` default), `:701` (10,000 IOPS), `:777` (cost: provisioned 10,000 IOPS);
  - `README.md:204` (Validator c7i.8xlarge);
  - `docs/partner/mno-node-guide/mno-node-guide.md:594`, `:596`, `:607`.
- `OPERATOR.md:687` and the guide's `:594` write "8 vCPU (4 cores)", not F1's "4 cores (8 vCPU)".

## F9 and F10

- **F9:** right on the instance figures (AWS: c7i.2xlarge 8 vCPUs, 4 cores, 2 threads per core, 16.00 GiB; c7i.4xlarge 16 / 8 / 2, 32.00 GiB; EBS 12,000 / 40,000 IOPS). Wrong in two places: the unit (V-AWS-6) and the burst (V-AWS-2). "Presets and default size follow the recommended column" holds for CPU, RAM and size, not for the storage medium or sustained IOPS (V-AWS-1). Replacement:

  > AWS presets: `FullNode` (default) `c7i.2xlarge, 4 cores (8 vCPU), 16 GiB`; `PublicRPC` `c7i.4xlarge, 8 cores (16 vCPU), 32 GiB`; `Validator` `c7i.2xlarge, 4 cores (8 vCPU), 16 GiB`, the same size as `FullNode`. `DataVolumeSize`: `500` (default) or `350` GiB; `2000` and `4000` stay allowed for stacks launched with them. The gp3 data volume is provisioned at 15,000 IOPS and 300 MiB/s. Cores, RAM and disk size follow the recommended column of the testnet table; the disk is an EBS network volume, not a local NVMe drive. A `c7i.2xlarge` sustains 12,000 IOPS and 312.5 MB/s to EBS and bursts above that for 30 minutes at least once every 24 hours, so on `FullNode` and `Validator` the volume gives 12,000 IOPS sustained and 15,000 in bursts. A `c7i.4xlarge` sustains the full 15,000.

- **F10:** correct but incomplete (V-AWS-3); the replacement wording is in V-AWS-3.

## What was proved

- **A1:** the gates table above.
- **A2:**
  - `git diff 01664cc 1a3404b -- aws/` touches `aws/node.yaml` only (6aebeee; 1a3404b touches no `aws/` file).
  - The diff covers the Preset description; the `DataVolumeSize` default, allowed values and description; the `Validator` Mapping; the volume comment and `Iops: 15000`. Nothing else changed.
  - The `ImageId` block is byte-identical (moved from `:84-90` to `:90-96`), and 4 lines name 26.04 before and after.
  - Every statement of a size, IOPS or throughput in the template (descriptions, labels, comments, user data, documents, Outputs) agrees with the new values. The CPU wording matches AWS's Performance specifications rows.
- **A3:** gp3 (EBS `general-purpose.html`): 3,000 IOPS and 125 MiB/s baseline; up to 80,000 IOPS at 500 IOPS per GiB; up to 2,000 MiB/s at 0.25 MiB/s per provisioned IOPS; 1 GiB to 64 TiB; "gp3 volumes do not use burst performance". For 350, 500, 2000 and 4000 GiB, 15,000 IOPS needs only 30 GiB and 300 MiB/s needs 1,200 IOPS, so all are valid. Spec section 1's two AWS rows are confirmed.
- **A4** (`hw_presets.sh` over the real `check_hardware`, df totals from `ext4_df.sh`):
  - **ext4 totals:** `mkfs.ext4 -q -E nodiscard` in `ubuntu:26.04` (mke2fs 1.47.2; 4 KiB blocks, 256-byte inodes at one per 16 KiB, 1 GiB journal). mke2fs records "Overhead clusters", so the df total is (blocks − overhead) × 4 kB, cross-checked between the free-block count and blocks − inode tables − journal. Assumption: the kernel takes s_overhead from the superblock at mount.

    | Volume | df total (kB) |
    |---|---|
    | 350 GiB | 360,123,532 (368.8 GB) |
    | 500 GiB | 514,937,088 |
    | 2000 GiB | 2,063,105,424 |
    | 4000 GiB | 4,127,329,224 |

  - **Testnet, `c7i.2xlarge`** (4 cores / 8 threads; MemTotal 16,148,070 and 16,357,786 kB), every size: follower, RPC and validator all `meets minimum`, `TN_HW_GAPS` empty, rc 0, and the line `Validator (minimum): meets minimum (3 cores (6 vCPU) / 16 GB / 350 GB)`.
  - **Validator recommended** (4 / 16 / 500; printed but not checked by the code, so judged with `_tn_hw_role`): met on 500, 2000 and 4000 GiB. 350 GiB falls short (369 GB against the 475 GB floor), consistent with "500 (recommended)".
  - **`c7i.4xlarge`** (8 / 16, 32,715,571 kB): every role meets on every size; the RPC recommended 8 cores / 32 GB is met by the same rule.
  - **Disk floor:** 316 GiB is the smallest whole GiB that passes 350 GB with its slack; 315 GiB warns (332 GB). 350 GiB clears it by about 36 GB, so there is no allowed size "one notch" below that fails. A disk sold as 350 GB (326 GiB) passes too.
  - **Mainnet, for F7:** `c7i.2xlarge` with 500 GiB is below every tier; `c7i.4xlarge` with 2000 GiB meets all three.
- **A5:** the cases table in V-AWS-3. **A6:** below. **A7:** V-AWS-7.

## A6: existing operators and new launches

- **An operator who launched a Validator stack last week** (c7i.8xlarge, 16 cores, 64 GiB; 2000 GiB at 10,000 IOPS) needs to do nothing: the host exceeds the testnet recommended row. Optional steps:
  - Raise the volume to 15,000 IOPS in the console. There is no restart, and the volume takes no further modification until this one completes.
  - Move to `c7i.2xlarge` in the console to save cost. This is a stop and start, done when the node may restart.
  - Leave the 2000 GiB volume as it is. It cannot shrink; going smaller means a new volume and a data copy, which these docs should not suggest.
  - Do not update the stack.
- **FullNode and PublicRPC stacks:** the same, without the instance type question.
- **A new launch gets:**
  - `FullNode` c7i.2xlarge (unchanged);
  - `Validator` c7i.2xlarge (was c7i.8xlarge);
  - `PublicRPC` c7i.4xlarge (unchanged);
  - a 500 GiB volume by default (was 2000) at 15,000 IOPS (was 10,000) and 300 MiB/s;
  - 12,000 IOPS sustained on the c7i.2xlarge presets (V-AWS-1).

## Not proved

- Case (d): what EBS does when CloudFormation re-sends Iops 15000 to a volume already at 15,000, after the console modification completed. No documentation says, and I launched no stack.
- The update order (DataVolume before NodeInstance) and the stop/start for c7i.8xlarge → c7i.2xlarge are inferred from the dependency and the documented rules, not observed.
- The MemTotal of a c7i.2xlarge on the Ubuntu 26.04 AMI, and whether that AMI reserves a crashkernel (V-AWS-8).
- The df totals come from unmounted images (mke2fs's recorded overhead), not from a mounted filesystem's `df`.

## Spec 6.2 open item (AWS)

- **"the stack-update answers in `tasks/ckpt-req-aws.md` are from memory":** now checked against AWS's pages. (a), (b) and (c) are confirmed, with two corrections:
  - EBS no longer has a fixed six-hour wait. The rule is that the previous modification must be `completed`, and at most four modifications in a rolling 24 hours.
  - The rollback waits ("subject to a cooldown period", `UPDATE_ROLLBACK_IN_PROGRESS`) rather than ending in `UPDATE_ROLLBACK_FAILED`.

  Severity: Info.
- **"nothing grows the filesystem after a volume grows":** confirmed, V-AWS-4 (Low).
- **"gp3 throughput is MiB/s":** confirmed, V-AWS-6 (Info).

## Harness and reproduction

- `tasks/verify-req/V-AWS/ext4_df.sh`: `docker run --rm -u "$(id -u):$(id -g)" -v <W>:<W>:ro -v S/ext4:S/ext4 ubuntu:26.04 bash <W>/tasks/verify-req/V-AWS/ext4_df.sh S/ext4 300 315 316 317 320 326 350 500 2000 4000`. Output in `S/ext4/df-bracket.txt`.
- `tasks/verify-req/V-AWS/hw_presets.sh`: `TMPDIR=S/tmp bash tasks/verify-req/V-AWS/hw_presets.sh`, or `docker run --rm -v <W>:<W>:ro -w <W> bash:3.2 bash tasks/verify-req/V-AWS/hw_presets.sh`.
- Lint and guard:
  - `docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v <W>:<W>:ro -v S/venv-own:/venv:ro -w <W> python:3.12-slim /venv/bin/cfn-lint aws/node.yaml`
  - `S/guard-x1/cfn-guard validate --rules aws/rules --data aws/node.yaml --show-summary fail`
  - `S/guard-x1/cfn-guard test --dir aws/rules`
  - The broken copies are in `S/neg-a1/`.

## Compared with the implementer's checkpoint (read after the above)

The implementer's (a), (b) and (c) agree with mine. Its "historically 6 h; may be relaxed" is replaced by the documented rule, and its "rollback … can fail → UPDATE_ROLLBACK_FAILED" by AWS's "subject to a cooldown period". It did not cover (d) or (e) separately, nor the sustained IOPS of the c7i.2xlarge against the 15,000 minimum (V-AWS-1).

Sources: [AWS compute optimized instance types](https://docs.aws.amazon.com/ec2/latest/instancetypes/co.html), [EBS General Purpose SSD](https://docs.aws.amazon.com/ebs/latest/userguide/general-purpose.html), [CFN AWS::EC2::Instance](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-instance.html), [CFN AWS::EC2::Volume](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-volume.html), [EBS Elastic Volumes](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-modify-volume.html), [EBS modification requirements](https://docs.aws.amazon.com/ebs/latest/userguide/modify-volume-requirements.html), [Extend the file system after resizing](https://docs.aws.amazon.com/ebs/latest/userguide/recognize-expanded-volume-linux.html), [CFN drift detection](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-stack-drift.html), [Ubuntu kernel crash dump](https://ubuntu.com/server/docs/how-to/software/kernel-crash-dump/), [Ubuntu discourse: kernel crash dump configuration](https://discourse.ubuntu.com/t/kernel-crash-dump-configuration/58080).
