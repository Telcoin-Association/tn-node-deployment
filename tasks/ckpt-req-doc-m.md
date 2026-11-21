status: done

# DOC-M checkpoint

Baseline 26.04 counts: CHANGELOG/scripts-v2.2.0.md 3, CHANGELOG.md 0, AGENTS.md 4, followup.md 2, docs/testnet-addons.md 0 (unchanged after all passes).

## Sections
- [x] pass 1: chain configs come from the pinned tag -- f57b9bb
- [x] pass 2: hardware requirements per network -- fc1ffa8 (rebased: a wording fix of its intro paragraph folded in with --fixup/--autosquash; was d2b91a6)
- [x] pass 3: the mainnet chain id is 731 -- 47d9960 (was 18837f4 before the rebase)
- [x] self-check: headings match constants; 487 hits all history/devnet/"moved from"; banned strings: only "Validator was c7i.8xlarge" (history); 26.04 counts equal; released notes byte-identical; old CHANGELOG.md entries untouched.

## Decisions
- UI heading "### Node Manager UI 2.1.3" (file says "Node Manager UI"; scripts-v2.1.0 precedent); table row telcoin-ui (`UI_VERSION`) 2.1.3.
- "### AWS one-click stack" heading added (no version).
- AGENTS.md: new "## Chain configs" section after "## The mainnet switch".
- CL-2: chain-id by-area entry ADDED to CHANGELOG.md Unreleased (section holds by-area scripts-v2.2.0 entries: release keys, worker gateway, gateway pins).
- One followup item of spec 7.2 LEFT OUT: it concerned a repository outside this one, named in no tracked file.

## Follow-up (coordinator, after the hand-back): done
- Three CHANGELOG.md entries added; commits rebuilt from 7a686dc with each pass's file states (fixups would have conflicted on every CHANGELOG.md insertion).
- New ids: pass 1 6bb5a33, pass 2 38e9a05, pass 3 b1732e0. Tip differs from the old tip 47d9960 only in CHANGELOG.md.
- Unreleased order: Partner guide 1.13 / Mainnet chain id 731 / Hardware requirements per network / Chain configs from the pinned tag / Partner documents at run.telcoin.network / ...
