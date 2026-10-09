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

Follow-up patch: production counter immediately uses a conservative byte bound when the exact pair already fits the available window, avoiding two asynchronous tokenizer calls for normal short requests. Larger input still receives actual Apple counts before trimming. Structured logs report `input_measurement`, `tokenizer_calls`, `byte_bound_attempts`, and `preparation_ms`; skipped counts are never labeled actual token measurements. Stress noise now scales by `max(1, contextSize / 4096) * 3`, with English control unchanged and facts retained at heads, so raw-vs-bounded input comparison remains identical within each case. Eval labels exact-count preparation timing separately from production timing. Added conservative runtime26.4 guard around contextSize for originalSDK compatibility; earlierOS always4096. Parent re-run pending.
