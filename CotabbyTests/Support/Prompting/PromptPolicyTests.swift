import XCTest
@testable import Cotabby

/// Tests for the Apple Intelligence prompt adapter.
///
/// Foundation Models gives Cotabby an instructions channel, so these tests lock down which rules go
/// into high-priority instructions and which field-specific text remains in the short prompt. Both
/// payloads are asserted as exact strings: every line is deliberate prompt policy, and a `contains`
/// check would miss a dropped rule, a reordered section, or a stray blank line.
final class FoundationModelPromptRendererTests: XCTestCase {
    /// The fixed instruction block every request receives, before optional language, style, and
    /// reference-note additions.
    private static let baseInstructionLines = [
        "You complete partially-typed text. The user is the author; you produce the next few words "
            + "they would type, in their voice.",
        "Output the continuation only: no greeting, no sign-off, no quotes, no markdown, no labels, "
            + "no explanation.",
        "Continue from the position immediately after the existing text. Do not repeat or quote the "
            + "existing text.",
        "Match the existing language, register, casing, and punctuation. Continue the current "
            + "sentence or thought rather than restarting it.",
        "Use clipboard or screen context only when it directly helps the next words."
    ]

    /// The single continuation demonstration. It must stay a prose example: an unconditional
    /// programming demo leaked unrelated code into email and chat completions.
    private static let exampleLines = [
        "Examples (quotes only mark the boundaries; never output the quotes):",
        "Existing text: \"I just wanted to follow up on the \"",
        "Continuation: proposal we discussed last week."
    ]

    // MARK: - Session instructions

    /// Pins the complete default instructions: positive identity, the output contract, the
    /// anti-echo rule (without it the chat-tuned model re-emits the prefix, which the normalizer then
    /// strips to nothing), and one prose example. The completion-length cue and the user's name are
    /// supplied but must not appear: the length cue is per-request prompt policy, and a stated name
    /// is the biggest trigger for the chat-tuned model breaking character ("Jacob, how are you").
    func test_sessionInstructions_defaultRequestRendersFixedBlockWithoutNameOrLengthCue() {
        let request = CotabbyTestFixtures.suggestionRequest(
            completionLengthInstruction: "UNIQUE_LENGTH_POLICY",
            userName: "UNIQUE_PROFILE_NAME"
        )

        XCTAssertEqual(
            FoundationModelPromptRenderer.sessionInstructions(for: request),
            (Self.baseInstructionLines + Self.exampleLines).joined(separator: "\n")
        )
    }

    /// Empty optional strings behave exactly like nil: no dangling headers or subordination lines.
    func test_sessionInstructions_emptyOptionalInputsAddNothing() {
        let request = CotabbyTestFixtures.suggestionRequest(
            customRules: ["", "  \n "],
            extendedContext: "",
            languageInstruction: ""
        )

        XCTAssertEqual(
            FoundationModelPromptRenderer.sessionInstructions(for: request),
            (Self.baseInstructionLines + Self.exampleLines).joined(separator: "\n")
        )
    }

    /// Order matters: the language hint refines the base "match the language" rule so it sits
    /// directly after it, while user-authored style rules and notes come last, each followed by a
    /// subordination line so they cannot override the output contract. Rules are trimmed and blank
    /// rules dropped.
    func test_sessionInstructions_orderLanguageThenExamplesThenRulesThenNotes() {
        let request = CotabbyTestFixtures.suggestionRequest(
            customRules: ["  Keep it casual  ", "", "Use British spelling"],
            extendedContext: "Glossary: meow = cat sound",
            languageInstruction: "Write in French."
        )

        let expected = Self.baseInstructionLines
            + ["Write in French."]
            + Self.exampleLines
            + [
                "Your style preferences:",
                "- Keep it casual",
                "- Use British spelling",
                "Apply these only when they fit the continuation naturally; never break the rules above.",
                "Reference notes from the user:",
                "Glossary: meow = cat sound",
                "Use these notes only when they fit the continuation naturally; never break the rules above."
            ]
        XCTAssertEqual(
            FoundationModelPromptRenderer.sessionInstructions(for: request),
            expected.joined(separator: "\n")
        )
    }

    // MARK: - Request prompt

    /// Minimal request: app line, the prefix verbatim (edge whitespace included), and the length cue
    /// on the prompt channel. An unrecognized bundle gets no tone hint, and an empty suffix or empty
    /// screen/clipboard strings add no sections.
    func test_prompt_minimalRequestRendersExactSkeleton() {
        let request = makeRequest(
            prefixText: "  Hello from the field  ",
            clipboardContext: "",
            visualContextSummary: ""
        )

        XCTAssertEqual(
            FoundationModelPromptRenderer.prompt(for: request),
            [
                "Screen context:",
                "User is on TestApp.",
                "",
                "Text before the caret:",
                "  Hello from the field  ",
                "",
                "Write only the next continuation fragment.",
                "Return only the next 7 to 12 words."
            ].joined(separator: "\n")
        )
    }

    /// Every optional section in its fixed order: tone hint, surface facts, screen, clipboard,
    /// prefix, suffix, then the length cue. Surface facts mirror the llama preface so the two engines
    /// agree about the field (the placeholder is often the only label a field has).
    func test_prompt_fullRequestRendersEverySectionInOrder() {
        let request = makeRequest(
            applicationName: "Mail",
            bundleIdentifier: "com.apple.mail",
            prefixText: "Thanks for ",
            trailingText: " the update.",
            clipboardContext: "Q3.xlsx",
            visualContextSummary: "Budget due Friday",
            surfaceContext: SurfaceContext(
                surfaceClass: .email,
                applicationName: "Mail",
                windowTitle: "Re: Q3",
                domain: "mail.example.com",
                fieldPlaceholder: "Body"
            )
        )

        XCTAssertEqual(
            FoundationModelPromptRenderer.prompt(for: request),
            [
                "Screen context:",
                "User is on Mail.",
                "The user is writing an email, so keep the same register and finish the current thought.",
                "The window is titled \"Re: Q3\".",
                "The user is on mail.example.com.",
                "The text field is labeled \"Body\".",
                "Screen content:",
                "Budget due Friday",
                "",
                "User's clipboard:",
                "Q3.xlsx",
                "",
                "Text before the caret:",
                "Thanks for ",
                "",
                "Text after the caret:",
                " the update.",
                "",
                "Write only the next continuation fragment.",
                "Return only the next 7 to 12 words."
            ].joined(separator: "\n")
        )
    }

    /// Each surface fact is independent: a surface with only a placeholder contributes one line.
    func test_prompt_surfaceContextOmitsMissingFacts() {
        let request = makeRequest(
            prefixText: "Hi",
            surfaceContext: SurfaceContext(
                surfaceClass: .other,
                applicationName: "TestApp",
                windowTitle: nil,
                domain: nil,
                fieldPlaceholder: "Comment"
            )
        )

        XCTAssertEqual(
            FoundationModelPromptRenderer.prompt(for: request),
            [
                "Screen context:",
                "User is on TestApp.",
                "The text field is labeled \"Comment\".",
                "",
                "Text before the caret:",
                "Hi",
                "",
                "Write only the next continuation fragment.",
                "Return only the next 7 to 12 words."
            ].joined(separator: "\n")
        )
    }

    /// The focus snapshot hands over the whole document tail, so the renderer itself must bound it
    /// to `maxSuffixCharacters` to keep a caret-at-top edit inside Apple's shared context window.
    func test_prompt_boundsTrailingTextToMaxSuffixCharacters() {
        let request = makeRequest(prefixText: "Hi", trailingText: " there, friend", maxSuffixCharacters: 6)

        let prompt = FoundationModelPromptRenderer.prompt(for: request)

        XCTAssertTrue(prompt.contains("\nText after the caret:\n there\n\n"), prompt)
        XCTAssertFalse(prompt.contains("friend"))
    }

    /// Tone hints live in the prompt (not the cached instructions) so switching apps does not
    /// invalidate the session prefix. Terminals host mostly prose (commit messages, pagers), and
    /// Cursor's opaque ToDesktop bundle is intentionally unclassified, so both get no hint.
    func test_prompt_toneHintFollowsAppSurfaceClass() {
        let cases: [(bundle: String, hint: String?)] = [
            ("com.apple.dt.Xcode", "The user is writing code, so the continuation should be code rather than prose."),
            ("com.apple.mail", "The user is writing an email, so keep the same register and finish the current thought."),
            ("com.tinyspeck.slackmacgap", "The user is in a chat app, so keep the continuation short and informal."),
            ("com.google.Chrome", "The user is typing inside a browser, so keep the continuation concise."),
            ("com.apple.Terminal", nil),
            ("com.googlecode.iterm2", nil),
            ("co.zeit.hyper", nil),
            ("com.todesktop.230313mzl4w4u92", nil),
            ("com.example.TestApp", nil)
        ]
        for testCase in cases {
            let request = makeRequest(applicationName: "App", bundleIdentifier: testCase.bundle, prefixText: "Hi")
            let hintLines = testCase.hint.map { [$0] } ?? []
            let expected = ["Screen context:", "User is on App."] + hintLines + [
                "",
                "Text before the caret:",
                "Hi",
                "",
                "Write only the next continuation fragment.",
                "Return only the next 7 to 12 words."
            ]
            XCTAssertEqual(
                FoundationModelPromptRenderer.prompt(for: request),
                expected.joined(separator: "\n"),
                "bundle \(testCase.bundle)"
            )
        }
    }

    /// Upstream gating should prevent a blank prefix, but the renderer still returns a safe prompt
    /// instead of sending the model an empty caret section.
    func test_prompt_returnsFallbackWhenPrefixIsEmptyAfterTrimming() {
        let request = makeRequest(prefixText: " \n ", visualContextSummary: "ignored")

        XCTAssertEqual(
            FoundationModelPromptRenderer.prompt(for: request),
            "Continue the text at the caret using a short inline completion."
        )
    }

    /// Diagnostics must show both payloads Apple receives, instructions first, so the debug preview
    /// can never display the llama prompt while Apple Intelligence is selected.
    func test_promptPreview_concatenatesLabeledInstructionsAndPrompt() {
        let request = makeRequest(prefixText: "Continue this", visualContextSummary: "UNIQUE_APPLE_SCREEN_CONTEXT")

        XCTAssertEqual(
            FoundationModelPromptRenderer.promptPreview(for: request),
            "Instructions:\n"
                + FoundationModelPromptRenderer.sessionInstructions(for: request)
                + "\n\nPrompt:\n"
                + FoundationModelPromptRenderer.prompt(for: request)
        )
    }

    func test_combinedBudgetPreservesExactShortRenderAndCountsBothChannels() async throws {
        let request = makeRequest(prefixText: "Thanks for ", clipboardContext: "Q3.xlsx",
            visualContextSummary: "Budget due Friday", customRules: ["Keep it casual"],
            extendedContext: "Glossary: meow = cat sound", languageInstruction: "Write in French.")
        var counted: [FoundationModelPromptRenderer.Payload] = []
        let payload = try await FoundationModelPromptRenderer.preparePayload(for: request, contextSize: 4096) {
            counted.append($0)
            return $0.utf8Count
        }
        XCTAssertEqual(counted.count, 1)
        XCTAssertEqual(payload.instructions, FoundationModelPromptRenderer.sessionInstructions(for: request))
        XCTAssertEqual(payload.prompt, FoundationModelPromptRenderer.prompt(for: request))
        XCTAssertTrue(payload.instructions.contains("Write in French."))
        XCTAssertTrue(payload.prompt.contains("Q3.xlsx"))
    }

    func test_combinedByteBudgetBoundsDenseUnicodeAndRetainsCaretNearestText() async throws {
        for source in ["東京の報告書", "대한민국보고서", "ประชุมรายงาน", "🧑🏽‍💻📋"] {
            let request = makeRequest(applicationName: String(repeating: source, count: 100),
                prefixText: String(repeating: source, count: 800) + " CARET_NEAREST_END ",
                trailingText: "SUFFIX_NEAREST_START " + String(repeating: source, count: 800),
                clipboardContext: String(repeating: source, count: 800),
                visualContextSummary: String(repeating: source, count: 800),
                surfaceContext: SurfaceContext(surfaceClass: .other, applicationName: "TestApp",
                    windowTitle: String(repeating: source, count: 100), domain: "example.com", fieldPlaceholder: "Body"),
                customRules: [String(repeating: source, count: 100)],
                extendedContext: String(repeating: source, count: 800),
                languageInstruction: String(repeating: source, count: 100),
                historyExamples: [String(repeating: source, count: 100)])
            var counts = 0
            let payload = try await FoundationModelPromptRenderer.preparePayload(for: request, contextSize: 4096) {
                counts += 1
                return $0.utf8Count
            }
            XCTAssertLessThanOrEqual(payload.utf8Count + request.maxPredictionTokens + 128, 4096)
            XCTAssertTrue(payload.prompt.contains("CARET_NEAREST_END "), source)
            XCTAssertTrue(payload.prompt.contains("SUFFIX_NEAREST_START "), source)
            XCTAssertTrue(payload.instructions.contains("Output the continuation only:"))
            XCTAssertTrue(payload.instructions.contains("Do not repeat or quote the existing text."))
            XCTAssertTrue(payload.prompt.contains("Write only the next continuation fragment."))
            XCTAssertLessThanOrEqual(counts, FoundationModelPromptRenderer.maximumBudgetRefits)
        }
    }

    func test_refitPreservesExactUTF8AndWholeCaretGraphemes() async throws {
        // Decomposed accents and a skin-tone ZWJ emoji deliberately exercise Character boundaries.
        // Compare bytes as well as String equality, which otherwise treats canonical forms alike.
        let nearestPrefix = "Cafe\u{301} 🧑🏽‍💻 résumé 東京 next words "
        let nearestSuffix = "🧑🏽‍💻 Cafe\u{301} 東京 after the caret; "
        let prefix = String(repeating: "older text ", count: 1500) + nearestPrefix
        let suffix = nearestSuffix + String(repeating: "later text ", count: 1500)
        let request = makeRequest(prefixText: prefix, trailingText: suffix, maxSuffixCharacters: suffix.count)
        let payload = try await FoundationModelPromptRenderer.preparePayload(for: request, contextSize: 4096) { $0.utf8Count }
        let before = try XCTUnwrap(payload.prompt.components(separatedBy: "Text before the caret:\n").last?
            .components(separatedBy: "\n\nText after the caret:").first)
        let after = try XCTUnwrap(payload.prompt.components(separatedBy: "Text after the caret:\n").last?
            .components(separatedBy: "\n\nWrite only the next continuation fragment.").first)
        XCTAssertEqual(Array(before.suffix(nearestPrefix.count).utf8), Array(nearestPrefix.utf8))
        XCTAssertEqual(Array(after.prefix(nearestSuffix.count).utf8), Array(nearestSuffix.utf8))
        XCTAssertEqual(Array(before.utf8), Array(prefix.suffix(before.count).utf8))
        XCTAssertEqual(Array(after.utf8), Array(suffix.prefix(after.count).utf8))
        XCTAssertLessThanOrEqual(payload.utf8Count + request.maxPredictionTokens + 128, 4096)
    }

    func test_tokenBudgetUsesInjectedCountRatherThanCharacterOrByteHeuristic() async throws {
        let request = makeRequest(prefixText: "Keep this exact tail ",
            visualContextSummary: String(repeating: "Context. ", count: 500))
        let original = FoundationModelPromptRenderer.Content(request).payload
        var counts = 0
        let payload = try await FoundationModelPromptRenderer.preparePayload(for: request, contextSize: 1000) {
            counts += 1
            // Deliberately token-dense screen text. Only the supplied combined count can determine
            // fit; this protects the modern path from falling back to a chars/4 approximation.
            return $0.prompt.contains("Context. Context.") ? 1200 : 300
        }
        XCTAssertGreaterThan(counts, 1)
        XCTAssertNotEqual(payload, original)
        XCTAssertTrue(payload.prompt.contains("Keep this exact tail "))
    }

    func test_impossibleCombinedBudgetThrowsBeforeAnyCountOrDispatch() async {
        let request = makeRequest(prefixText: "Hello")
        var counts = 0
        do {
            _ = try await FoundationModelPromptRenderer.preparePayload(for: request, contextSize: 128) {
                counts += 1
                return $0.utf8Count
            }
            XCTFail("The response/framing reservation cannot fit")
        } catch FoundationModelPromptRenderer.BudgetError.cannotFit {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(counts, 0)
    }

    func test_fixedContractCannotBeTruncatedToMakeImpossiblePayloadFit() async {
        let request = makeRequest(prefixText: "Hello")
        var counts = 0
        do {
            _ = try await FoundationModelPromptRenderer.preparePayload(for: request, contextSize: 400) {
                counts += 1
                XCTAssertTrue($0.instructions.contains("Output the continuation only:"))
                return $0.utf8Count
            }
            XCTFail("The fixed continuation contract cannot fit this context")
        } catch FoundationModelPromptRenderer.BudgetError.cannotFit {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThanOrEqual(counts, FoundationModelPromptRenderer.maximumBudgetRefits)
    }

    func test_cancellationAfterAsyncCountStopsBeforeReturningFittingPayload() async {
        let request = makeRequest(prefixText: "Hello")
        let task = Task {
            try await FoundationModelPromptRenderer.preparePayload(for: request, contextSize: 4096) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return 0
            }
        }
        do { _ = try await task.value; XCTFail("A cancelled count must not produce a dispatchable payload") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func test_cancellationDuringRefitStopsWithoutFurtherCounting() async {
        let request = makeRequest(prefixText: "Hello", visualContextSummary: String(repeating: "context", count: 1000))
        let task = Task {
            var counts = 0
            return try await FoundationModelPromptRenderer.preparePayload(for: request, contextSize: 4096) { _ in
                counts += 1
                if counts == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                XCTAssertLessThanOrEqual(counts, 2)
                return 10_000
            }
        }
        do { _ = try await task.value; XCTFail("A cancelled refit must stop") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    // MARK: - Helpers

    /// The shared fixture cannot set the bundle identifier, suffix bound, or surface facts, which
    /// are exactly the inputs the Apple prompt branches on.
    private func makeRequest(
        applicationName: String = "TestApp",
        bundleIdentifier: String = "com.example.TestApp",
        prefixText: String,
        trailingText: String = "",
        maxSuffixCharacters: Int = 192,
        clipboardContext: String? = nil,
        visualContextSummary: String? = nil,
        surfaceContext: SurfaceContext? = nil,
        customRules: [String] = [], extendedContext: String? = nil,
        languageInstruction: String? = nil, historyExamples: [String] = []
    ) -> SuggestionRequest {
        SuggestionRequest(
            context: CotabbyTestFixtures.focusedInputContext(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                precedingText: prefixText,
                trailingText: trailingText
            ),
            prefixText: prefixText,
            prompt: "PROMPT",
            generation: 1,
            maxPredictionTokens: 16,
            temperature: 0.1,
            topK: 20,
            topP: 0.7,
            minP: 0.08,
            repetitionPenalty: 1.05,
            randomSeed: 42,
            maxSuffixCharacters: maxSuffixCharacters,
            completionLengthInstruction: "Return only the next 7 to 12 words.",
            userName: nil,
            customRules: customRules,
            extendedContext: extendedContext,
            languageInstruction: languageInstruction,
            clipboardContext: clipboardContext,
            visualContextSummary: visualContextSummary,
            surfaceContext: surfaceContext,
            historyExamples: historyExamples,
            isMultiLineEnabled: false
        )
    }
}
