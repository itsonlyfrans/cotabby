# Next improvements

This first pass prioritizes reliable completion and explicit vocabulary. Follow-up work
should use measured behavior rather than add prompt rules speculatively.

1. **Live host matrix:** after granting the development app Accessibility and Input
   Monitoring, verify preview, TextEdit, a Chromium contenteditable, Codex, Slack,
   Element and Ferdium. Exercise focus switches, mid-line text, accented corrections,
   and popup placement near screen edges. The three newly recognized messaging apps
   are not installed on this machine, so recognition tests are not compatibility proof.
2. **History spelling:** `TypingHistoryPhrasePredictor` keeps one latest display form
   per lowercase token. An unrelated later lowercase occurrence can change a saved
   phrase's capitalization. Preserve spelling by phrase context and measure memory
   before changing the model of stored transitions.
3. **Apple context limits:** the Apple renderer caps individual context sources but
   lacks a combined request budget. Measure long multilingual requests and add a
   shared budget while protecting caret text; compare against existing quality evals.
4. **Cotypist control flow:** package and native imports are documented. Deeper Ghidra
   analysis did not yield usable results in this pass. Trace a small selected behavior
   before claiming implementation differences or reconstructing an algorithm.

Typing-history collection, cloud inference, and model downloads remain separate,
explicit user choices. Personal vocabulary does not require any of them.
