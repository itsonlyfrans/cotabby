# Next improvements

The fork prioritizes reliable completion and explicit vocabulary. Follow-up work
uses measured behavior rather than adding prompt rules speculatively.

1. **Live host matrix:** TextEdit completion and global Tab acceptance are verified
   with both development-app permissions enabled. Expand to a Brave contenteditable,
   Codex, Slack, Element and Ferdium when desktop testing is convenient. The user requested
   Brave only and no foreground interruptions. Exercise focus switches, mid-line text, accented corrections,
   and popup placement near screen edges. The three newly recognized messaging apps
   are not installed on this machine, so recognition tests are not compatibility proof.
2. **History spelling completed:** spelling is retained per phrase context. Focused tests
   and exact-source memory measurements are recorded in `history-capitalization.md`.
3. **Apple context limits:** the renderer now budgets instructions and prompt together,
   reserves output space and protects caret-nearest text. Ordinary and six-scenario stress
   evaluation passed; results and timing limits are recorded in `apple-context-budget.md`.
   The dense mid-line case still produced awkward wording before an existing suffix.
   Improving that semantic fit needs a separate before/after evaluation; nonempty output
   is not sufficient proof of quality.
4. **Cotypist control flow completed for the selected investigation:** native disassembly
   demonstrates one secure/search-field exclusion branch and a Secure Input diagnostic
   branch. Evidence and uncertainty are documented in `COTYPIST_RESEARCH.md`. Correction
   thresholds and the complete acceptance/privacy paths remain unknown.
5. **Fork distribution:** the isolated target and manual release links are implemented.
   Actual archive, signing, notarization and packaged-app verification status belongs in
   `fork-release.md`; source checks alone do not establish a distributable release.

Typing-history collection, cloud inference, and model downloads remain separate,
explicit user choices. Personal vocabulary does not require any of them.
