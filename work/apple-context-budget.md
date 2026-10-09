# Apple combined context budget

Goal: prevent Apple's pristine autocomplete session from exceeding its shared input/output window while retaining useful local context and the caret-nearest text. Parent owns builds, live models, eval execution, packaging, and changelog. No builds or model calls by the implementation worker.

## Implementation

- `FoundationModelPromptRenderer.Content` holds per-preparation mutable rendering inputs; its immutable `Payload` carries the exact instructions/prompt pair. Original raw render methods retain exact short prompt strings. No changes to shared requests or other engine prompts.
- `preparePayload` budgets both channels together, reserving `max(1, maxPredictionTokens)` plus 128 framing tokens. It checks cancellation before and after every async count and refuses impossible payloads before constructing a session. Maximum 64 refits is a hard termination ceiling, not a target.
- Oversized optional sources shrink together each refit, then lower-priority sources drop before editor text. Reference excerpts retain their head; prefix retains its tail, suffix its head. Each editor side retains up to a minimum 64 whole graphemes (or all shorter text). The fixed continuation contract is never truncated.
- Runtime uses actual Apple token counts on macOS 26.4+ with SDK support, memoizing unchanged instructions within one preparation. Older OS versions use combined UTF-8 bytes as a conservative token upper bound. Xcode before 26.4 (compiler before Swift 6.3) compiles out the new symbols and uses Apple's documented 4096 window plus byte budgeting.
- Generation and prewarm both prepare a bounded pair and construct/reuse the session from those exact counted instructions. Pristine-transcript/responding/cache identity rules remain intact.

## Evidence and checks

Parent captured old production renderer in `/private/tmp/cotabby-foundation-prompt-before.swift`, baseline Release result in `build/validation/apple-context-before.log`: 52 passed, 1 drift, 0 empty, 0 noise, p50 322ms / p95 543ms. Existing 52 evaluation cases are unchanged.

Worker checks: `git diff --check` passed; scoped production SwiftLint with `--no-cache` passed. Initial lint cache attempt failed because its global cache was not writable; disabled cache for the scoped check. Xcode compilation, test execution, live model recall/latency, and older-SDK/OS execution are still pending with parent.

Focused pure class: `FoundationModelPromptRendererTests` in existing `PromptPolicyTests.swift`. Added exact short pair, combined dense CJK/Korean/Thai/emoji byte limit, exact UTF-8/whole-grapheme caret preservation, injected real-count policy, impossible reserve/fixed contract, cancellation after fitting count, and cancellation during refit regressions.

Live evaluation class: `FoundationModelDriftEvalTests/test_reportCombinedContextSuite`. Five identical raw-before/bounded-after stress scenarios cover English reference notes, Chinese screen, Japanese clipboard, Korean writing history, and dense multilingual editor text. Reports raw/bounded units, actual overflow/errors, prep milliseconds/refit count, nonempty outputs, and separately scored reference recall. Raw before uses the preserved raw renderer through `Content.payload` and a fresh Apple session; after uses the production engine. This is opt-in under existing `RUN_FM_EVAL`, not CI model invocation. Re-run existing `test_reportEvalSuite` alongside it for the unchanged 52-case comparison.

## Limits and next action

Parent should build and run the two eval methods plus `FoundationModelPromptRendererTests`, inspect actual stress prep latency and recall, and adjust only demonstrated failures. UTF-8 fallback deliberately sacrifices older-OS prompt capacity to avoid multilingual undercount; it is conservative, not an exact tokenizer. 128 framing reserve and useful 64-grapheme editor floors are explicit bounded policy choices. Recall is reported separately because nonempty text is not evidence that references were used; the live eval does not demand perfect stochastic recall. Compiler/SDK pairing assumes Apple's bundled Xcode toolchain (not a custom new compiler paired with an old SDK).

## Primary sources

- [Apple TN3193](https://developer.apple.com/documentation/Technotes/tn3193-managing-the-on-device-foundation-model-s-context-window): instructions, prompts, and output all consume the shared 4096-token context; dense CJK does not follow Latin chars-per-token estimates; `tokenCount(for:)` measures channels.
- [Xcode 26.4 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26_4-release-notes): Swift 6.3 with macOS 26.4 SDK.
- Local FoundationModels SDK Swift interface verified the two `tokenCount` overloads' macOS 26.4 availability and `contextSize` back-deployment to macOS 26.0.

## Live-eval follow-up

Parent first execution: all pure renderer tests passed; unchanged 52-case quality remained 1 drift / 0 empty / 0 noise, p50 395ms / p95 578ms versus baseline 322/543. The initial five context cases all fit this Mac's actual 8192-token window; recall 4/4 before/after and real counting cost 40–44ms. The overflow assertion correctly exposed an insufficient stress fixture. This initial result is retained as control evidence; it is not overflow protection proof.

Follow-up patch: production counter immediately uses a conservative byte bound when the exact pair already fits the available window, avoiding two asynchronous tokenizer calls for normal short requests. Larger input still receives actual Apple counts before trimming. Structured logs report `input_measurement`, `tokenizer_calls`, `byte_bound_attempts`, and `preparation_ms`; skipped counts are never labeled actual token measurements. Stress noise now scales by `max(1, contextSize / 4096) * 3`, with English control unchanged and facts retained at heads, so raw-vs-bounded input comparison remains identical within each case. Eval labels exact-count preparation timing separately from production timing. Added conservative runtime26.4 guard around contextSize for originalSDK compatibility; earlierOS always4096.

## Final overflow evaluation follow-up

Parent Release rerun (`build/validation/apple-context-final.log`) proves four raw overflow failures against8192 and bounded Chinese/Japanese/Korean success with reference recall4/4 total. Unchanged52cases: 1drift/0empty/0noise, p50301/p95522. Dense editor stress fits5669units but normalizes to empty, so5nonempty assertion fails. Current eval omitted bounded raw/suppression evidence; first repair is diagnostic only, preserving fixture and assertion for a targeted rerun. Do not loosen normalization or infer the failure cause without that evidence.

## Dense editor diagnosis and final fixture repair

Parent's unchanged-fixture diagnostic rerun established the cause: bounded raw output started `before Friday.報告書。...`, copying the text already following the caret; `suppressionReason=duplicatesTrailingText`. The pair fit its context budget and generation succeeded. The production normalizer correctly prevented duplicate insertion; this was a semantically ambiguous stress fixture, not budget overflow or an overaggressive normalization defect.

Eval-only repair: retain that exact original request as `dense-editor-duplicate-suffix-control`, with raw/suppression diagnostics. It may return useful text; if empty, it must have nonempty raw output and exactly `duplicatesTrailingText`. Add a separate `dense-editor-tail` with the same oversized mixed Japanese/Korean/Thai filler and optional reference noise, followed by a coherent nearest-caret paragraph: `Release checklist:\nValidation has passed. Packaging is next. The next step is to `. Its suffix starts ` the signed app before Friday.\n\n` and keeps the same long Japanese filler. The missing packaging verb can now bridge into a real object and deadline. The suite still requires five useful nonempty results across its five intended-continuation cases; the preserved duplicate control is a sixth independent safety check. All before/after pairs still use identical input within each case.

No production prompt, engine, or normalization changes for this repair. Failed evidence remains in `build/validation/apple-context-final.log` and the parent's diagnostic rerun log; do not overwrite it or report it as success. Worker diff check passed; parent final combined-suite execution pending. Parent also reports six `RecoveredFocusValidationTests` passed (separate scope).

Scoped eval lint follow-up: split introduced diagnostic line and extracted the useful/safety assertion helper without changing gates or fixtures. Scoped `swiftlint lint --no-cache` and `git diff --check` run; existing nested-type and original long-fixture-line warnings remain out of scope.

## Final live result

`build/validation/apple-context-verified.log`: six scenarios passed. Five identical raw
inputs failed Apple's actual 8192-token window; their bounded versions fit at 4762–5968
measured tokens. All five intended continuations were nonempty, all four scored reference
facts were recalled, and the unchanged duplicate-suffix control was correctly suppressed.
The dense checklist continuation was grammatically awkward before the existing suffix:
nonempty output is not semantic-quality proof. Mid-line wording remains a follow-up quality
limitation; this patch does not alter normalization or claim to solve it.

The unchanged 52-case Release suite in `apple-context-final.log` passed with 1 heuristic
drift flag, 0 empty, 0 template noise, p50 301ms and p95 522ms (baseline 322/543). These
single-run timings show no observed ordinary-case regression, not a statistical speed claim.
Stress exact-count preparation took roughly 0.2–1.5 seconds in the final diagnostic run;
it includes deliberately huge inputs and concurrent packaging load. Normal short requests
use the byte fast path instead. No user text or screenshots were collected for these evals.

The final wording-only edit labels the aggregate `intended_nonempty` and explains its
semantic limit. No assertion, fixture, or production behavior changed after the passing run.
