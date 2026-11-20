status: done

## Finished sections
- licences: LICENSE-APACHE (201 lines), LICENSE-MIT (21 lines) copied from src-main 2d1bdc7; cmp clean for both
- workflow: .github/workflows/publish.yml (73 lines); actionlint silent (exit 0); PyYAML parses; pins identical to publish-installer.yml (diff of the three pins clean)
- README: README.md (184 lines, 11 sections in brief order, sentence-per-line); snippets pass bash -n and shellcheck; sha256sum -c --ignore-missing flow tested on a mock source.txt
- format-output pass on README.md: no changes needed (cmp against pre-pass snapshot clean)
