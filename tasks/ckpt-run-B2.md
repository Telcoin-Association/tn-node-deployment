status: done
unit: B2, fix round on docs/spec-1.3-public (old tip ecf035f, parent 35214c4)
new tip: 9da2a07 (amended; parent still 35214c4; nothing pushed)
scratch: /var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/9e8efab4-ccd8-4e70-8b1b-387187e040a7/scratchpad/b2

finished sections:
- script: lint loop over $MD $META $TEMPLATE $CSS (tr -s whitespace fold, grep -q -i -F
  from a here-string), comment above MARKING updated, PDF-text comment updated.
- prose: AGENTS.md (Partner documents, forbidden-text bullet) and CHANGELOG.md (top
  Unreleased entry); ASCII only.
- tests: all ten as expected (b2/summary-pre-commit.txt, b2/T*.log); extra T5x; contrast
  against ecf035f (b2/summary-old-contrast.txt).
- commit: amended to 9da2a07 with b2/commit-msg.txt; post-commit --all rc=0, PDF unchanged
  x4 (b2/post-commit-all.log); bash -n and shellcheck clean (b2/t10-syntax-post-commit.log);
  git status shows only tasks/; ecf035f..9da2a07 touches only the three files, no PDF.
