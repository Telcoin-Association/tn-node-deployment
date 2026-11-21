status: done

# V-AWS checkpoint

Worktree /home/drtnarg/coding/telcoin/tnd-req-v-aws at 1a3404b. Scratch (S):
/var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/46275ae3-5cf9-4f35-b799-c09950443243/scratchpad/v-aws/

Sections: A1 lint/guard, A2 diff, A3 EBS limits, A4 hardware check, A5 update behaviour,
A6 operators, A7 rules, REPORT.

Completed: A1, A2, A3, A4, A5, A6, A7; REPORT.md Write refused -> full text returned in the hand-back

## A1 (done)
- Tools: cfn-guard 3.2.2; tarball sha256 65ce4d16...d823d7 = ci.yml GUARD_SHA256; I re-extracted
  it to S/guard-x1 (binary sha256 d16a35e5... same as the shared one). cfn-lint 1.60.1 in my OWN
  venv S/venv-own, built in python:3.12-slim with `pip install --require-hashes -r
  aws/requirements-ci.txt` (freeze matches the 9 pins).
- Tip 1a3404b: cfn-lint rc 0; guard validate rc 0; guard test rc 0, 29/29 cases "PASS Rules"
  over 4 files (out: S/guard-test-tip.out).
- Live: S/neg-a1/m1 (Default 300) -> E2015 rc 2; m9 (literal c7i.2xlargee) -> E3628 rc 6; m5
  (DataVolume Encrypted false) -> guard FAIL storage.guard/data_volumes_encrypted rc 19.
- Blind spots (rc 0, nothing reported): m2 Iops 90000 (> gp3 80000), m3 Throughput 2500
  (> 2000), m4 typo in the Validator Mapping (c7i.2xlargee via FindInMap), m7 an allowed size of
  20 GiB with 15000 IOPS (750/GiB), m8 Iops 3000 + Throughput 1000 (ratio 0.33). So nothing in
  CI checks the preset names or the IOPS/throughput/size relations -> feeds A7.

## A2 (done)
- `git diff 01664cc 1a3404b -- aws/`: aws/node.yaml only (6aebeee; 1a3404b touches no aws/ file).
  Preset description (51-56), DataVolumeSize default 500 / allowed 350,500,2000,4000 / desc
  (75-78), Mapping Validator c7i.2xlarge (105), volume comment (288-291) + Iops 15000. Nothing else.
- ImageId block identical (moved from 84-90 to 90-96); 26.04 lines 4 before, 4 after.
- CPU wording c7i.2xlarge 4 cores (8 vCPU) 16 GiB, c7i.4xlarge 8 cores (16 vCPU) 32 GiB: AWS co.html
  "Performance specifications" rows (vCPUs 8/16, CPU cores 4/8, threads 2, 16.00/32.00 GiB). OK.
- Every size/IOPS/throughput statement in the template agrees with the new values. Wording
  issues go to findings: desc "It runs at 15000 IOPS" (instance sustains 12000), comment
  "bursts to 40000" (volume caps at 15000), "MB/s" where gp3 is MiB/s (comment says "0.25 MB/s
  per IOPS"; AWS: 0.25 MiB/s per provisioned IOPS).

## A3 (done)
- AWS co.html "Amazon EBS specifications" (read 2026-11-21, offset 100000): c7i.2xlarge(1)
  2500/10000 Mbps, 312.50/1250.00 MB/s, 12000/40000 IOPS; c7i.4xlarge(1) 5000/10000,
  625/1250, 20000/40000; c7i.8xlarge 10000, 1250, 40000 (no footnote). Footnote 1 verbatim: "These
  instances can support maximum performance for 30 minutes at least once every 24 hours, after
  which they revert to their baseline performance. Other instances can sustain the maximum
  performance indefinitely. ..." -> spec section 1 row confirmed.
- AWS EBS general-purpose.html: gp3 3000 IOPS / 125 MiB/s baseline; up to 80000 IOPS at 500 IOPS
  per GiB (max at 160 GiB); up to 2000 MiB/s at 0.25 MiB/s per provisioned IOPS (max at 8000 IOPS
  and 16 GiB); 1 GiB-64 TiB; "gp3 volumes do not use burst performance". -> spec row confirmed.
- Per size 350/500/2000/4000: 15000 <= 500*size (min 30 GiB) and <= 80000; 300 <= 0.25*15000 =
  3750 and <= 2000. All valid.
- Delivered: c7i.2xlarge sustained min(15000 vol, 12000 inst) = 12000 IOPS; burst 15000 (volume
  cap, not 40000); throughput min(300 MiB/s, 312.5 MB/s = 298.0 MiB/s) = ~298 MiB/s sustained.
  c7i.4xlarge: 15000 IOPS and 300 MiB/s sustained (inst 20000 / 625 MB/s = 596 MiB/s).
  Old template: Validator c7i.8xlarge 10000 IOPS sustained (volume-bound); FullNode 10000.
- Units: 312.5 = 2500/8 so instance MB/s is decimal (inferred). 300 MiB/s = 314.6 MB/s. "300
  MB/s" understates the volume and is <= what any preset sustains (312.5 MB/s), so no statement
  is wrong in effect; the comment's "0.25 MB/s per IOPS" mislabels AWS's MiB/s (Info).
- Testnet storage minimum is 15000 IOPS: FullNode/Validator presets sustain 12000 (80 %) ->
  finding (preset claimed as "recommended testnet hardware").

## A4 (done)
- ext4_df.sh in ubuntu:26.04 (mke2fs 1.47.2, `mkfs.ext4 -q -E nodiscard` on sparse files,
  never mounted). mke2fs records "Overhead clusters"; df total = (blocks - overhead) * 4 kB,
  checked inside [free blocks, blocks - inode tables - journal]. Results (S/ext4/df-bracket.txt):
  300 GiB 308521792 kB; 315 323999324; 316 325031452; 326 335352664; 350 360123532 (368.8 GB);
  500 514937088 (527.3 GB); 2000 2063105424; 4000 4127329224.
- hw_presets.sh (real check_hardware, stubs lscpu/nproc/sysctl/df, meminfo fixture): 87 checks,
  0 failures under host bash 5, bash:3.2 and ubuntu:26.04.
  - c7i.2xlarge (4c/8t; MemTotal 16148070 and 16357786) x 350/500/2000/4000 testnet: all three
    roles meet, gaps empty, rc 0, exact validator line.
  - Validator recommended (4/16/500, not checked by the code; judged with _tn_hw_role): met on
    500/2000/4000 GiB; 350 GiB is short (369 GB vs a 475 GB floor).
  - c7i.4xlarge (8c/16t, 32715571 kB) all sizes: all roles meet; RPC recommended 8c/32GB met by
    hand (>= 31876710 kB).
  - Disk floor: 316 GiB passes, 315 GiB warns (332 GB). 350 GiB clears it by ~36 GB, so "350 is
    the minimum" in GiB is conservative (a 350 GB = 326 GiB volume would pass too).
  - RAM: floor 15938355 kB; passes at that, warns 1 below. Margin on a 16 GiB guest = 838861 kB
    (819 MiB) of reservations. 16 GiB - 512 MiB crashkernel - 400 MiB -> rpc,validator below.
    Ubuntu docs: kdump on by default only from 24.10, only on standard Desktop/Server installs,
    and only when /var free > 5 x RAM (80 GiB on a 16 GiB host; the root volume is 50 GiB) ->
    not expected on the AMI; real MemTotal NOT PROVED (no instance).
  - Mainnet: c7i.2xlarge 500 GiB -> node,rpc,validator; c7i.4xlarge 2000 GiB -> none.
- Gates on both .sh: shebang, shellcheck 0.11.0 --severity=error clean (2 warnings, SC2034
  through eval, SC2319), bash -n bash 5 and bash:3.2, check-bash32 clean.

## A5 (done)
Pages read 2026-11-21: CFN TemplateReference aws-resource-ec2-instance.html (saved tool
result), aws-resource-ec2-volume.html, EBS ebs-modify-volume.html, modify-volume-requirements.html
(no cooldown text there now), CFN UserGuide using-cfn-stack-drift.html.
- Instance: InstanceType "Update requires: Some interruptions" + "When you change your EBS-backed
  instance type, instance restart or replacement behavior depends on the instance type
  compatibility between the old and new types." ImageId "Replacement". UserData "Some
  interruptions" (restart) - user data unchanged 01664cc->tip, so not triggered.
  NetworkInterfaces: "If you use this property to point to a network interface, you must
  terminate the original interface before attaching a new one to allow the update of the
  instance to succeed." -> replacement fails while the old instance holds NodeNetworkInterface.
- Volume: Size/Iops/Throughput "No interruption". Important box: "When you use AWS CloudFormation
  to update an Amazon EBS volume that modifies Iops, Size, or VolumeType, there is a cooldown
  period before another operation can occur. This can cause your stack to report being in
  UPDATE_IN_PROGRESS or UPDATE_ROLLBACK_IN_PROGRESS for long periods of time." ... "You
  successfully update an Amazon EBS volume and the update succeeds but another change in your
  update-stack call fails. The rollback will be subject to a cooldown period." "Amazon EBS does
  not support sizing down an Amazon EBS volume. AWS CloudFormation does not attempt to modify an
  Amazon EBS volume to a smaller size on rollback."
- EBS: "you must wait for that modification to reach the completed state before you can initiate
  another modification for the same volume. You can modify a volume up to four times within a
  rolling 24-hour period" (NOT a fixed six hours any more); "Typically, A 1-TiB volume can take up
  to six hours to be modified."; "You can't decrease the volume size."; no detach/restart on
  Elastic-Volumes instances; a subpage "Extend the file system after resizing" exists.
- Answers: (a) Validator, no override: DataVolume first (NodeInstance depends on it via
  !Sub ${DataVolume}), Iops 10000->15000 no interruption; then type c7i.8xlarge->c7i.2xlarge:
  Some interruptions = stop/start (same family, inferred compatible) -> node down, no epoch guard.
  documented+inferred. (b) Size 2000 kept (previous parameter value, still allowed; inferred),
  Iops only: ModifyVolume, no interruption, starts the modification window. documented.
  (c) smaller size: EBS refuses -> update fails -> rollback; volume untouched (inferred that Size
  and Iops go in one call). documented (no shrink) + inferred. (d) drift: CFN diffs templates,
  so it re-sends Iops 15000; before the console modification is completed it fails
  (documented rule), after it: outcome not documented (no-op or error) - NOT PROVED.
  (e) new image: Iops modification lands, instance replacement fails on the ENI, rollback must
  wait for the modification to complete (hours on 2000 GiB) before reverting Iops to 10000; Size
  growth would stay. documented (CFN box) + inferred (order). OPERATOR.md "the stack rolls back
  unchanged" is then wrong in time and, for a grown size, in content.
- No resize2fs/growpart anywhere outside tasks/ (git grep). Whole-device ext4 (no partition),
  so after a console grow `sudo resize2fs <device>` online is the only step; docs should say so.

## A6 (done)
- Validator launched last week (01664cc: c7i.8xlarge 16c/64 GiB, 2000 GiB, 10000 IOPS): nothing
  required; it exceeds the testnet recommended row. Optional: raise Iops to 15000 in the EC2
  console (no restart; next modification only after this one is completed, at most 4 per 24 h);
  optional cost cut: change type to c7i.2xlarge in the console (stop/start: node down, no
  epoch guard; do it when the node may restart); size stays 2000 (cannot shrink). Never update
  the stack. After a console size grow: resize2fs on the device (no partition), no snapshot
  (repo rule; AWS's page suggests one).
- New launch: FullNode c7i.2xlarge (unchanged), Validator c7i.2xlarge (was 8xlarge),
  PublicRPC c7i.4xlarge (unchanged); 500 GiB default (was 2000); 15000 IOPS (was 10000),
  300 MiB/s. Sustained on c7i.2xlarge 12000 IOPS (burst 15000, volume-capped), on c7i.4xlarge 15000.
- Doc lines still saying the old values (wave 3): OPERATOR.md 687, 689, 701, 777; README.md
  204; mno-node-guide.md 594, 596, 607. OPERATOR.md 687 and the guide 594 write "8 vCPU (4
  cores)", not F1's "4 cores (8 vCPU)". OPERATOR.md ~763 "the stack rolls back unchanged".

## A7 (done)
- No rule or test pins Iops/Size/type; storage_tests.yaml fixtures use Size 2000 as data only.
  All 9 rules PASS (none SKIP) on both 01664cc and tip (--show-summary all). aws/rules untouched.
- A guard rule pinning Iops >= 15000 / sizes: not posture (AGENTS.md: principal, policy, no TCP
  22, IMDSv2, encryption, retention, resource-type list) -> recommend no. If a check is wanted,
  the A1 blind spots (Mapping types, gp3 ranges/ratios vs AllowedValues) fit a plain test.
