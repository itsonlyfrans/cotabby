# Cotabby improvement work

## Goal and scope

Improve the user's GitHub fork (`itsonlyfrans/cotabby`) across completion quality,
app compatibility, and personal vocabulary/writing style. Use the supplied Cotypist
DMG for static research and independent design ideas; keep its binaries and resources
out of this repository. User explicitly authorized testing an already available local
AI engine on 2026-10-09.

## Starting state

- Empty workspace cloned with colocated Jujutsu/Git.
- Existing fork main: `ac2699e4`; latest upstream: `8cdbea2d` (22 commits ahead).
- Work is on `improve-completions`, based on latest upstream; fork main preserved.
- macOS 27.0.1, Xcode 27.0; a development signing identity and installed production
  Cotabby are present. Keep the production app and its settings separate.

## Workstreams

- Parent: build/run setup, integration, concrete feature scope, validation and changelog.
- Quality audit: output, context, correction dismissal, personalization gaps.
- Compatibility audit: AX focus/acceptance and host integration defects.
- Cotypist research: static REA evidence, maintained outside the public repository.

## Decisions and verification

- Prefer focused, demonstrated improvements over speculative prompt/model tuning.
- No cloud inference, model download, personal typing-history collection, or upstream
  messages are part of this pass.
- Use targeted existing tests and focused regression coverage for changed behavior.
- Run and inspect the isolated development app; distinguish UI/AX/model verification.

## Implementation

Baseline Debug development build succeeded; signed and launched from
`build/Development/Cotabby Dev.app`. XcodeGen installed; SwiftLint already present.
Prepared dependencies pin CotabbyInference and its checked-in API patch.

Implemented:
- Explicit local personal vocabulary: protect names/jargon from typo correction and
  supply deterministic prefix completions, no prompt or network changes.
- Unicode correction deletion counts graphemes, while AX offsets remain UTF-16.
- History phrase completion refuses unsafe text and existing trailing signatures.
- Exact Slack/Element/Ferdium recovery identities; popup switches above caret near
  the bottom edge.
- Cursor-based recovery requires actual focus and current-window membership.

XcodeGen regenerated the project; final development build succeeded and its signature
passed strict verification. Research remains static; Cotypist logic claims require
evidence, not package-name inference.

## Verification update

- All 340 unique focused regression tests pass across the initial and affected-class
  reruns; no skips. One new test exposed a real history output-budget bug, now fixed.
- Direct AppKit NSTextView backspace checks preserve preceding text for decomposed
  accents, skin-tone/ZWJ emoji, and flags using grapheme-count deletion.
- SwiftLint finds only three pre-existing large-tuple warnings in two unchanged test
  helpers; introduced lint findings repaired.
- Baseline UI inspected in Cotabby Dev. Apple Intelligence is available and selected;
  no model downloads. Screen recording/history remain off. File-backed baseline
  screenshot unavailable; CUA screenshot viewed, private whole-screen attempt deleted.
- User explicitly approved development-app Accessibility and Input Monitoring, then
  completed macOS authentication. Both Dev grants are enabled. No credentials were
  entered by the agent. macOS quit Dev but did not reopen it; relaunched the exact
  signed bundle with its normal settings argument and no debug text logging.
- Cotypist REA inventory, plist and native Mach-O evidence complete; report in
  `work/COTYPIST_RESEARCH.md`, raw evidence in ignored `build/research`. No usable Ghidra
  control-flow result; session closed and read-only mount ejected.

- Real Apple Intelligence Release evaluation completed: 52 cases, 0 empty, 0 template
  noise, 1 heuristic chat-drift flag. Its 15 "midword" flags merely count responses
  without final punctuation; inspected scorer does not establish truncated words. Test passed its
  existing gates. Engine latency p50 298 ms, p95 527 ms, max 1102 ms. This is a single
  real-engine run, not a before/after quality improvement claim and not UI latency.
- Rebuilt and signed Dev after the live vocabulary fix; strict signature and the prior
  designated signing requirement both pass, preserving the approved permission identity.
- Native vocabulary UI passes add, duplicate rejection, remove, re-add, and persistence
  after changing settings panes. Synthetic test word: Quasarwick.
- Three user-visible outcomes and remaining host/history/context limitations recorded
  through the required changelog script. Online publication verified.

## Live verification and remaining scope

Initial implementation published and remote SHA verified as `492e80045ce51c270a90cdfee5a136ef21f21792`
on `itsonlyfrans/cotabby:improve-completions`; fork main unchanged.

Live TextEdit acceptance PASSED after confirming actual foreground and posting global
CoreGraphics key events: `The capital of France is` + Space + Tab inserted `Paris`.
CUA's app-targeted Tab had bypassed the consuming global event tap; it was not a valid
acceptance test. State-only OSLog confirmed model generation, inline presentation, and
accept-tap consumption. No prompt/screenshot file logging was enabled.

The same live boundary exposed a personal vocabulary defect: saved `Quasarwick`,
prefix `The codename is Quasarwic`, Tab produced `The codename is Quasarwic, a`.
The missing final k proved explicit-prefix completion must take precedence over model
continuation. The fix now offers a unique saved ending before engine/cache dispatch,
keeps model-quality counts accurate, applies the duplicate guard, and avoids caching
deterministic offers. Focused tests cover stale callbacks and vocabulary becoming
ambiguous after a settings change. Independent review findings resolved.

Final rebuilt app PASSED the same foreground/global-key boundary: `The codename is
Quasarwi` + c + Tab produced exactly `The codename is Quasarwick`, with no extra text.
Synthetic documents discarded and the test word removed; normal signed Dev app left
running without debug logging. Changelog and local validation evidence updated.

Remaining scope is the wider host matrix and the separate limitations in
`FORK_ROADMAP.md`. Slack, Element, and Ferdium are not installed.
Cleanup of generated DerivedData and the
previous Dev bundle was blocked by the command safety hook's recursive-deletion rule;
explicit user approval is pending. Retain final app and research/log evidence.
