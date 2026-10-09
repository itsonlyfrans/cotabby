# Cotypist static research for Cotabby

Inspected 2026-10-09. Scope: `/Users/owl/Downloads/Cotypist.dmg`, static only. Cotypist and its model engines were never executed. No implementation, model, resource, or proprietary asset was copied into Cotabby.

## Identity and evidence

- DMG SHA-256: `367625cbb4389631f028ba00e827a72b03f4be8b892c6128584ef20b43099530`.
- Main executable SHA-256: `8cb2475a56de0dcee2d1f9bdc05a6e45b4679e430710d2c7a67dc0c092143529`.
- Cotypist 2026.5, build 81, bundle `app.cotypist.Cotypist`, Apple Silicon arm64, minimum macOS 14.0, `LSUIElement=true`.
- Inventory Evidence `ev_69a44a7f62a06868d10c063cd31d5d3d5c19b1589a662b6dea2ba808aa2426d5`; graph manifest `agm_3ed2628a46fb05d45eabab3325af1977d759edb8e337af8b30a7dab62d61bf0e`; complete inline Evidence: `inventory-evidence.json`.
- Parsed plist Evidence `ev_fde46c8ad2a7e20d029e67d6481a81bde27b4042cf4ec9007d5ce65da2518045`: `plist-evidence.json`.
- Mach-O Evidence `ev_237730d6204d1439314f21bd168ddf3429cdfa56022e3c2e04edf6a7bc0a7ed5`: `macho-evidence.json`.
- Supplemental local Evidence `local_static_ascii_offsets_v1`: `local-static-evidence.json`, `matching-strings.tsv`, `state-strings.tsv`, `symbols.txt`, `linked-libraries.txt`. Addresses in the inventory/string sections are **file offsets**. The later native control-flow section explicitly uses **unslid virtual addresses**.

## Observed shipped components

The artifact contains native Swift/Objective-C metadata, AppKit/SwiftUI resources, llama/ggml dylibs including CPU, Metal, and BLAS backends, GRDB, Sparkle, Sentry, RepliesSDK, and SwiftProtobuf. Mach-O directly imports llama loading, tokenizing, decoding and memory operations. The main binary includes model-catalog text naming Gemma, Qwen and Llama GGUF models. This supports a llama.cpp-based native completion engine inference; it does not establish the selected/default model, exact sampling parameters, or live behavior.

Mach-O imports include Accessibility observers and element getters/setters, CGEvent key-event APIs, `IsSecureEventInputEnabled`, `NSAccessibilitySecureTextFieldSubrole`, and `NSSpellChecker`. Imports establish available API boundaries, not their reachable control flow.

## Behavior declared by packaged UI text

These are observed settings/help strings describing intended behavior. They are stronger than filenames or class names, but have not been verified by decompilation or execution.

| Area | Packaged behavior description | Main-binary file offsets |
| --- | --- | --- |
| Typo filtering | Suppress completions when the current word looks misspelled; limit the check to that word. Optional inline correction shows a struck-through typo beside the fix. | `0xbe27b0`, `0xbe27e0`, `0xbe2940`, `0xbe0380` |
| Mid-line context | Suggest at the end of an unfinished line by default; optional completion with existing text after the cursor. | `0xbe2e70`, `0xbe0280`, `0xbd83a0` |
| Acceptance | Next-word and full-completion shortcuts. Options to include a following space and directly attached punctuation with a word. | `0xbd69b0`, `0xbd69d0`, `0xbe6280`, `0xbe63e0`, `0xbe6480` |
| Escape behavior | Clear only the displayed suggestion; the next Escape reaches the host app. Alternative modes temporarily pause or pause until the next app switch. | `0xbe5f30`, `0xbe70b0`, `0xbe7150` |
| Scope controls | Globally disable, enable by app, and enable/disable by web domain. Temporarily disable for seconds/minutes. Allow a default-disabled mode. | `0xbd9910`, `0xbd99d0`, `0xbd9a30`, `0xbe2ff0` |
| Host Tab behavior | Per-app option to disable Tab acceptance where Tab indents text or moves between fields. | `0xbe0440` |
| Context inputs | Clipboard and screenshot context switches; packaged text says locally processed and not stored/sent. Screen Recording permission supports richer context and appearance. | `0xbe1c90`, `0xbe1f50`, `0xbe20a0`, `0xbe2250` |
| Custom instructions | User style/occupation instructions; additional app-specific instructions can supply language/style/terminology. | `0xbe4840`, `0xbe00c0` |
| Personalization | Opt-in recording of writing from fields where suggestions occur; described as encrypted/local. Per-app disable and deletion. Option to record writing even with no accepted completion; adjustable word-choice strength. | `0xbdbef0`, `0xbdc200`, `0xbe4d10`, `0xbe4ec0` |
| Power/latency | Battery mode offers on-demand suggestions, shorter completions and lighter model. Length guidance describes slower and less relevant long completions. | `0xbe17b0`, `0xbe18c0`, `0xbe1960`, `0xbe2c61` |
| Compatibility | Hidden-input editor compatibility switch; optionally allow small fields. A fallback mirror previews suggestions when cursor placement is unavailable. | `0xbe05c0`, `0xbe05f0`, `0xbde71d` |
| Alternatives | Delayed/on-demand alternative words for the current completion and contextual synonyms for selected text. | `0xbe4080`, `0xbe42e0` |
| Emoji | Colon/shortcode filtering and optional neutral tone alongside preferred tone. | `0xbd81d0`, `0xbe23e0` |

## Other static clues and limits

- Focus-change notification strings occur at `0xbd4660` and `0xbd4680`; metadata names `DisplayedAcceptSnapshot` (`0xb280c0`), `currentGeneration` (`0xbbba10`), `latestUpdateCycleToken` (`0xbc1a80`), and `pendingFirstGenerationOfFieldSession` (`0xbc35d0`) suggest deliberate stale-result/focus coordination. The invariant itself is **unknown** without control-flow analysis.
- Sensitive-key pattern string at `0xbd4e00` matches secret/password/token/API-key/credential/authorization labels. Known password-manager identifiers and Apple's Passwords identifier occur around `0xbd2180`–`0xbd2400`. The placement, use, and completeness of those filters are **unknown**.
- `NSSpellChecker` imports plus spell-check/guess selectors at `0xbba878` and `0xbbe837` corroborate the declared current-word correction feature. Thresholds, language detection and dictionary behavior remain **unknown**.
- Metadata includes `TextFieldContextCapture`, `ScreenshotContext`, `PromptCoordinator`, and prompt-boundary offsets. OCR context is plausible from Vision and screen capture dependencies, but exact capture scope, truncation, redaction and prompt assembly are **unknown**.
- Typing-history customization is described in UI text. Its encryption, iCloud sync guarantees, retention, and implementation cannot be independently verified from strings alone.
- No conclusion is drawn about use of Sentry session replay, network privacy, or transmission of text simply because Sentry is bundled.
- Initial Ghidra focused searches returned no result within the bounded pass and were cancelled. The deeper follow-up recovered the limited instruction-level branches documented below; no completed Ghidra pseudocode was obtained. REA DMG inventory worked; its DMG extraction operation reported unavailable. A separate owned read-only mount provided the native binary for metadata inspection.

## Independently implementable ideas for Cotabby

1. **Guard text and focus at generation and acceptance.** Bind a request to the focused process, AX element, selection and text snapshot; discard results when any change. Recheck before inserting. This is an independent design recommendation motivated by exposed snapshot/generation metadata, not a recovered Cotypist algorithm.
2. **Keep privacy gates explicit.** Reject secure text fields before reading values. Clear pending context/results on focus changes. Add per-app scope and optional per-domain scope controls; keep clipboard/screenshot/personalization inputs separately opt-in.
3. **Suppress completions that extend a likely typo.** Use the system spelling service for the current incomplete word only, with conservative language handling. Preserve names/code and allow disabling per app. Offer correction as a separate optional action rather than silently rewriting.
4. **Make single-word acceptance predictable.** Optionally include its following whitespace and adjacent punctuation; expose full acceptance separately. Use Unicode boundaries instead of splitting solely on ASCII spaces.
5. **Prefer end-of-line suggestions by default.** Offer mid-line mode explicitly and validate suffix text before insertion. This avoids disrupting existing text without requiring a richer prompt pipeline.
6. **Reduce distraction and latency.** Briefly pause after dismissing a suggestion; support on-demand mode, maximum length and battery-specific settings. Treat model output filtering and stale-result invalidation as separate concerns.
7. **Start personalization with user-controlled instructions or personal terms.** Avoid automatic keystroke history as the initial implementation. If later added, require explicit consent, per-app exclusions, deletion and verified encrypted storage. Cotypist's UI describes history-based word preference, not a recovered personal dictionary algorithm.

These are candidate product behaviors and engineering designs. Actual Cotabby defects or coverage must be assessed from Cotabby's source and runtime independently.

## Deeper native control-flow follow-up

This pass used the requested REA native provider and then supplemental LLVM ARM64 disassembly when the provider exceeded its response deadline. The binary SHA-256 still matches the REA Mach-O Evidence above. No Cotypist process or model was run. Raw instruction and metadata evidence remains in ignored `build/research/`; the report contains behavior, addresses and evidence references, not implementation code.

### Observed: secure and search subroles take an early false return

Supplemental Evidence `local_native_arm64_control_flow_v2`, manifest `build/research/native-instruction-manifest.json`, plus `local_native_selector_decode_v2` in `native-selector-evidence.json`. Every address here is an **unslid virtual address**.

- The routine starting at `0x10009c020` calls the role reader at `0x10009c164` and subrole reader at `0x10009c16c`. Helpers `0x10024e650` and `0x10024ecc8` load the imported `NSAccessibilityRoleAttribute` and `NSAccessibilitySubroleAttribute`. Their shared helper sends `UIElementUtilities.valueOfAttribute:ofUIElement:` through Objective-C stub `0x100b15c60`. The selector slot and class are independently resolved in the selector evidence.
- Initializer `0x1000a7868` loads `NSAccessibilitySecureTextFieldSubrole` from import slot `0x100c97448` and `NSAccessibilitySearchFieldSubrole` from `0x100c97440`, constructs a Swift Set with capacity two, adds both values, and stores it at global `0x100d67838`.
- The routine loads that set at `0x10009c1ec` and checks the returned subrole at `0x10009c200`. The thunk at `0x1006eca44` branches to `0x1006e6b54`; its body performs a hash lookup with string comparisons and returns a Boolean membership result.
- Branch `0x10009c210` continues at `0x10009c230` when membership is false. When membership is true, cleanup leads to `0x10009c674`, which sets return register `w0` to zero and returns at `0x10009c69c`. This establishes a reachable exclusion branch for both secure and search subroles in this routine, beyond an import or UI string.

**Inferred:** this routine participates in field eligibility, given its AX role/subrole reads, role-set check, and Boolean result. Its source name and callers were not recovered, so this does not prove every context collection, generation or insertion path passes through it. It also does not establish a global guarantee that no field value was previously read.

**Observed boundary:** a missing subrole takes `cbz x23` at `0x10009c1d4` directly to the continuation at `0x10009c230`. This particular subrole check therefore does not reject every element with unavailable AX subrole metadata. Other checks in the routine still apply; successful eligibility is not established by this branch alone.

**Independent Cotabby comparison:** keep secure-field exclusion before collecting text, and consider suppressing unsolicited suggestions in AX search fields to avoid interfering with navigation and queries. Treat missing AX metadata as a deliberate compatibility/privacy policy and verify it separately. These are behavior-level recommendations, not a request to copy recovered code or weaken Cotabby's existing gates.

### Observed: one Secure Input helper returns an empty collection when disabled

The complete small routine at `0x1007c9df0` calls imported `IsSecureEventInputEnabled` at `0x1007c9dfc`. It loads `__swiftEmptyArrayStorage`, then `cbz w8` at `0x1007c9e0c` returns that empty collection when Secure Input is disabled. When enabled, it runs two once-initialized branches and calls `0x1007ce7e8` twice with distinct kind values before returning the resulting collection. Evidence: `secure-input-shortcut-diagnostic.asm.txt` and import mappings in `indirect-symbols.txt`.

**Inferred, limited:** the surrounding metadata and UI text suggest shortcut/status diagnostics. The branch itself is observed; the collection's complete meaning and callers are not established. This is **not evidence that Cotypist globally pauses completion inference when system Secure Input is enabled**. Cotabby may independently choose that stronger gate.

### Provider outcome and remaining questions

Supplemental diagnostic `local_rea_ghidra_attempt_v2` in `build/research/rea-ghidra-attempt-diagnostic.json` records the bounded provider attempt. REA run `8a917085-3492-4d7d-ac79-74e362d16b12` opened the matching main binary with existing Ghidra 12.1.4 and Java 21. The focused `Secure|correct|accept` procedure search returned the MCP error `timed out awaiting tools/call after 300s` before whole-binary analysis completed. The log showed unsupported Objective-C type encoding `T` in the metadata analyzer and subsequent decompiler-switch progress, so those warnings alone do not establish a fatal analyzer failure. No matching saved database was available: the owned headless job used `-readOnly -deleteProject`. The temporary log was removed on provider cleanup; the diagnostic preserves the error and reported excerpts, not a complete original log.

REA session closure was verified with `binary_session.open=false`; the owned read-only DMG mount was ejected (`disk40`). Relevant snippets and manifest hashes were checked against the matching binary. Cotypist runtime execution remains unverified. Current-word correction thresholds, exact acceptance boundaries, focus snapshot invalidation, and the placement of all privacy filters remain **unknown control flow**; their UI descriptions and import clues should not be promoted to implementation findings.
