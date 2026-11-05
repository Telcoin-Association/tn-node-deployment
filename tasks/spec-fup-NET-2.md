# NET-2: network-hit annotations and lint (issue #47)

Read `tasks/spec-fup-shared.md` first. Worktree `~/coding/telcoin/tnd-fup-NET-2`, branch
`fup/NET-2` from the integration branch AFTER wave 1 is in, checkpoint
`tasks/ckpt-fup-NET-2.md`.

## Goal

Every line of shipped code that names a testnet endpoint says why it is safe on mainnet, and
a lint fails CI on a new one that does not.

## Owned files

New `tools/check-network-hits.sh`, new `tools/tests/network_hits_test.sh`, and comment-only
edits (the annotation) on the lines the lint reports in `lib/*.sh`, the root `*.sh` scripts,
`ui/server.py`, `ui/telcoin-ui-helper.sh`, `ui/static/index.html`. No behaviour change
anywhere: if a hit is a real gap, write it under "Open issues" with the file and line and
annotate nothing there.

## Lint contract (decision 11)

- Patterns: `adiri` (case-insensitive, as a word or inside a hostname such as
  `rpc.adiri.tel`, `status.adiri.telcoin.network`, `node7.adiri.telcoin.network`) and the
  hub/monitor addresses from `lib/testnet-addons.env` (read at run time: the host part of
  `OBS_PUSH_URL_TESTNET`, `OBS_METRICS_PUSH_URL_TESTNET`, `TN_WG_HUB_ENDPOINT`'s address,
  `TN_KUMA_SRC`'s address). Release tags `vX.Y.Z-adiri` and the words "Adiri Testnet" in
  pure prose lines are hits too (they are the point: each line needs the marker or must be a
  comment line that is itself an annotation).
- Scope: `lib/*.sh` (not `lib/wgvpn/`, vendored), root `*.sh`, `ui/server.py`,
  `ui/telcoin-ui-helper.sh`, `ui/static/index.html`, `observability/config.alloy`; excluded:
  `common/`, `tools/`, `tests/`, `CHANGELOG*`, `tasks/`, `followup.md`, `docs/`, `*.md`,
  `lib/testnet-addons.env` itself, `.sha256` files.
- A hit line passes when it, or the line right above it, contains `network-gated:` followed
  by a reason (shell/Python `# network-gated: …`, JS `// network-gated: …`, HTML
  `<!-- network-gated: … -->`). A plain comment line (`#`, `//`, `<!--`) that is only
  documentation and names adiri passes when it carries the marker too; a comment line that
  is the marker itself is not reported.
- Output: `file:line: <text>` per unannotated hit, exit 1; exit 0 with a count when clean;
  `--list` prints every hit with its reason; bash 3.2 safe, GNU and BSD grep (CI's macOS job
  may run it: use `grep -n -i -E` with a portable pattern and `awk`, no `-P`).
- Reasons are specific: "testnet constant, selected by NETWORK" / "testnet release tag form,
  checked by tn_release_tag_ok per network" / "example in a message shown only when
  NETWORK=testnet" / "status page per network (server STATUS_PAGE_BASE)". A reason that is
  not true of the line is a bug: read the surrounding code.

## Tests

`tools/tests/network_hits_test.sh`: a fixture tree under a temp dir with annotated and
unannotated hits in each file type, the above-line form, the hub address read from a
stub `lib/testnet-addons.env`, excluded paths ignored, exit codes, `--list`. Then run the
real lint over the tree: it must exit 0 after your annotations (count in the checkpoint).
bash 5.3 and `bash:3.2` (busybox grep/awk) and `ubuntu:24.04`.

## Docs notes to hand over

The marker forms, the lint name and when CI runs it (GOV wires it), the count of annotated
lines, and any real gap found.
