status: done
unit: B3 (no-break space in the marking lint of tools/build-partner-pdf.sh)
start tip: 9da2a07
new tip: 2e6ce45 (amended; parent 35214c4 untouched; not pushed)

## finished steps
- 1. Pre-edit reproduction: spec description + " Confidential<C2 A0>and Proprietary." -> build exit 0,
  "Wrote ... (37 pages)", pdfinfo Subject ends "... Confidential and Proprietary."; restored with git checkout,
  docs/partner clean.
- 2. Script edited: flat= line now
  `flat="$(LC_ALL=C sed "s/$(printf '\302\240')/ /g" <"$f" | tr -s '[:space:]' ' ')"`;
  loop comment + "; a no-break space (U+00A0) between the words counts as a space." (rewrapped 1 line);
  header + "; the document's metadata.yaml, template and stylesheet are also checked for the confidentiality marking."
  bash -n ok, shellcheck quiet, check-bash32 clean.
- 3. Tests (all restored, docs/partner clean after each):
  T1 --all exit 0, PDF unchanged x4 (77, 37, 1, 1).
  T2 NBSP before "and" in spec description -> exit 1 at lint, nothing built.
  T3 NBSP both sides (2 byte pairs confirmed) in spec description and in mainnet badge -> exit 1 at lint.
  T4 NBSP between ordinary words -> exit 0, "Wrote ... (37 pages)", restored.
  T5 plain spaces / split across folded lines / capitals in author -> exit 1 at lint.
- 4. Commit amended with message from scratch/b3/msg-new.txt (lint paragraph + test list item added).
  origin/main..HEAD = 2 commits; status only tasks/; diff --stat 9da2a07 HEAD = script only (+6 -3);
  final --all: PDF unchanged x4, exit 0.
