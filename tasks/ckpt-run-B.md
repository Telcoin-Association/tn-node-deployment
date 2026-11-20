status: done

# Unit B checkpoint: PR-1, specification 1.3 without the confidentiality footer

Scratch: /var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/9e8efab4-ccd8-4e70-8b1b-387187e040a7/scratchpad/b

## Finished sections
- 0. baseline: shellcheck clean at all severities (0 lines); --all on 2d1bdc7 untouched: 4x PDF unchanged; git works in container with :ro .git mount
- 1. sources: metadata.yaml (key + comment gone, 1.3), template.html run-meta line, theme.css class + 2 comments
- 2. build script: NEED_CONFIDENTIALITY/CONFIDENTIALITY gone; readonly MARKING added to FORBIDDEN; stage 6 any-case check on whitespace-squeezed PDF text (here-string, not a pipe into grep -q: pipefail+SIGPIPE); shellcheck clean at all severities
- 3. AGENTS.md (metadata sentence, forbidden list) and CHANGELOG entry at top of Unreleased
- 4. rebuild: spec Wrote 37 pages; --all 4x PDF unchanged (spec now matches new); git status docs/partner: only spec's 4 files (logs build-spec.log, build-all-1.log)
- 5a. PDF checks: 37 pages, 0 'confidential', footer on p2-37 + cover 1.3; per-page diff -w = only footer/version line; pixel diff confined to 258.9-261.5 mm on p2/4/20 and cover version line; PNGs viewed OK
- 5b. negative tests (logs neg-*.log in scratch), all restored by cp from scratch/keep (hashes match): (a) rc=1 two errors (FORBIDDEN + any-case); (a2) uppercase rc=1 any-case only; (b) rc=1 lint forbidden text line 776; (b2) lowercase wrapped rc=1 any-case; (c) rc=0 PDF unchanged, inert
- 5c. greps: confidential only in script comment+MARKING, AGENTS 590, CHANGELOG entry (+16 lines in tasks/ round records); run-conf only in tasks/; no stale spec version
- 6. commits: plan two commits (1: spec 1.3 + drop label requirement; 2: forbid marking). final files in scratch/final, commit-1 script+AGENTS in scratch/mid
- 6a. committed: 93412a4 (spec 1.3, --all on its tree 4x unchanged, log build-all-mid.log), def6961 (forbid marking). 
- 6b. final --all on def6961 (worktree): 4x PDF unchanged (build-all-final.log); fresh clone of the branch: 4x PDF unchanged, uppercase negative test rc=1 (build-clone-all.log, neg-a2-clone.log); git status: only tasks/; no trailers in messages

## Notes
- FORBIDDEN is matched against the Markdown (stage 2 lint, grep -F, exact case) and
  against the PDF text (stage 6, pdftotext -layout, grep -F, exact case, skipped
  when pdftotext is missing). Exact case only, so an any-case check is needed.
