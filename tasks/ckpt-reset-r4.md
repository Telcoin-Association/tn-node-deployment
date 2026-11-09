status: done
reviewer: r4 (independent review of PR #52, devnet-docker-images, 8175a88..090d9e1)
completed sections:

- S1 diff read (lib/common.sh, setup-node.sh, update-node.sh, edit-config.sh, ui/server.py, docs): done
- S2 call-path trace (setup-node json/interactive, update-node json/interactive, edit-config): done
  notes: interactive setup offers testnet only (select_network) -> devnet only via setup --json;
  update-node source/release use detect_network (devnet rc1); --ref only honoured in --json;
  json_check on devnet: latest_docker_ref uses detect_network -> empty -> image_network never reached.
- S3 G1 lib vectors base vs head (vec.sh, 3 modes): done -- only diffs on non-devnet: grammar string; tn_docker_repo_ok testnet "GAR GHCR" rc0->rc1
- S4 G2 setup json refusals + update-node vectors (uvec.sh): done -- testnet/mainnet identical; devnet no registry calls
- S5 G5 hygiene: run.sh 59/0 failed (bash 5.3.9), lib_skew 132/0, check-bash32 clean, sidecars fresh (gen-checksums no diff), pytest ui 258 passed (py3.10-slim); shellcheck pending
- S6 UI vectors base vs head (py3.10): 0 non-devnet diffs; latest_* devnet 0 probes; network_rule never yields devnet
- NOTE: a grep at S6 accidentally printed 2 lines of tasks/pr12-body.md + 2 lines of ckpt-reset-pr12-code.md (after G1/G2/G5 runs were done)
- S7 shellcheck: --severity=error clean; warnings 218 lines identical to base
- S8 G3 demo (g3.sh): head _tn_release_fetch/tn_source_checkout_tag devnet -devnet tag no longer rc3 (checkout runs git clone); no caller reaches with devnet
- S9 independent verdict formed (before reading PR body / author ckpts):
  F1 Low  G3 gap: _tn_release_fetch (lib/common.sh:6726) + tn_source_checkout_tag (:7467) let -devnet tags through on devnet; checkout runs git clone; unreachable today; recommend 1-line refusal each
  F2 Low  docs: --check on devnet is byte-identical to 8175a88 (latest_docker_ref update-node.sh:2761 uses detect_network -> empty; :2848 never reached)
  F3 Low  docs/UX: --ref honoured only with --json (update-node.sh:3349); interactive custom tag regex :2362/:2417 refuses digests -> devnet interactive update is a dead end
  F4 Low  apply path: verify_consensus_participation update-node.sh:1177 still detect_network -> devnet chain id unchecked (warn only)
  F5 Info G1 diffs: grammar text; tn_docker_repo_ok testnet "<GAR> <GHCR>" rc0->rc1 (resolve_ref testnet "<GAR> <GHCR>:v0.16.0-adiri" rc0->rc1) -> "testnet behaves as before" slightly inaccurate
  F6 Info caveat: DEFAULT_DOCKER_IMAGE (testnet v0.16.0-adiri) allowed on devnet; OPERATOR.md lacks the caveat sentence
  F7 Info tn_docker_release_tag_for recorded-tag branch (:7367) not filtered by tn_release_tag_ok net
  F8 Info UI devnet tables unreachable (network_rule :340)
  F9 Info version floors still 2.0.0 (skew fails safe)
- S10 compared with PR body + author ckpts: author recorded F1 (G3) and the whitespace tightening in tests; F2, F3 (PR body says "--ref ... interactive and --json"; interactive cannot take a digest), F4, F7 not recorded by author. Gate numbers agree (59/0, 258 passed, shellcheck no new).
- S11 pre-existing (out of scope): pick_docker_version update-node.sh:2344-2354 `local -a all_tags` + set -u -> "all_tags: unbound variable" on bash 5.2/5.3 when no tags (always on devnet); bash 3.2 ok. Same at 8175a88.
- scratch: /tmp/claude-1000/-home-drtnarg-coding-telcoin-devnet-genesis/9749f56d-69ba-4ad5-9af1-7f63cb688653/scratchpad/r4 (bin/vec.sh uvec.sh g3.sh ws.sh pick.sh py/uivec.py; out-*.txt u-*.txt)
