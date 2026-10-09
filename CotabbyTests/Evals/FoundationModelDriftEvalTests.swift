import XCTest
@testable import Cotabby

#if canImport(FoundationModels)
import FoundationModels

/// Live Apple Intelligence drift and quality eval — deliberately NOT a CI test.
///
/// Apple's system model is chat-tuned. Historically it broke character on plain prefixes: greeting
/// the user ("Jacob, how are you"), tacking on pleasantries ("Hope it's going well"), or replying
/// like an assistant. The chat-drift bucket below preserves those failing cases; the other buckets
/// (email, slack, code, code-comment, prose, mid-line insertion) widen coverage to the writing
/// surfaces real users complain about so prompt and engine changes can be measured per category
/// instead of averaged into one number.
///
/// Per-case scoring captures four signals:
///   - DRIFT     — output reads as an assistant reply (a "drift tell" phrase or unprompted greeting)
///   - EMPTY     — normalization stripped the output to nothing (a hard miss in production)
///   - NOISE     — chat-template residue leaked through (regression check for routing/normalization)
///   - MIDWORD   — token budget cut the output mid-word (clean-stop heuristic)
///
/// Plus per-case latency, so latency-focused changes (session reuse, prewarm, streaming) can be
/// measured with the same harness as quality-focused changes.
///
/// Gated behind the `RUN_FM_EVAL` compilation condition because it (a) needs the on-device model,
/// which CI runners do not have, and (b) is non-deterministic, so it is a local tuning tool rather
/// than a hard gate. xcodebuild does not forward shell env vars to the macOS test host, so a compile
/// flag (which *is* passable on the command line) is the reliable switch. CI never sets it — and
/// `tests.yml` also `-skip-testing`s this class — so it is a no-op there.
///
/// Run locally with:
///   xcodebuild test -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' \
///     -only-testing:CotabbyTests/FoundationModelDriftEvalTests \
///     SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) RUN_FM_EVAL' CODE_SIGNING_ALLOWED=NO
@available(macOS 26.0, *)
@MainActor
final class FoundationModelDriftEvalTests: XCTestCase {
#if RUN_FM_EVAL
    /// One scored scenario. Categories let per-category thresholds catch regressions that
    /// whole-set averages would smooth over.
    private struct EvalCase {
        enum Category: String, CaseIterable {
            case chatDrift     // chat-prone prefixes the chat-tuned model historically replied to
            case email         // mid-sentence business email writing
            case slack         // short informal team chat
            case code          // code-editor continuations (should produce code)
            case codeComment   // English inside source files
            case prose         // generic factual writing
            case midLine       // insertion with non-empty trailing text
        }

        let category: Category
        let prefix: String
        let trailing: String  // empty unless category == .midLine
    }

    /// Per-case scoring outcome, kept as a flat struct so the report renderer can iterate without
    /// re-running anything.
    private struct CaseOutcome {
        let scenario: EvalCase
        let drifted: Bool
        let empty: Bool
        let noise: Bool
        let midWord: Bool
        let normalized: String
        let raw: String
        let latency: TimeInterval
    }

    /// Historical chat-drift triggers: salutations, partial greetings, mid-thought stoppers that
    /// the chat-tuned model used to "reply" to instead of continuing.
    private static let chatDriftCases: [EvalCase] = [
        EvalCase(category: .chatDrift, prefix: "Hey Jacob, ", trailing: ""),
        EvalCase(category: .chatDrift, prefix: "Hi Sarah,\n\n", trailing: ""),
        EvalCase(category: .chatDrift, prefix: "Thanks for ", trailing: ""),
        EvalCase(category: .chatDrift, prefix: "I wanted to reach out about ", trailing: ""),
        EvalCase(category: .chatDrift, prefix: "Good morning team, ", trailing: ""),
        EvalCase(category: .chatDrift, prefix: "Let me know if ", trailing: ""),
        EvalCase(category: .chatDrift, prefix: "lol yeah ", trailing: ""),
        EvalCase(category: .chatDrift, prefix: "The quarterly numbers are ", trailing: ""),
        EvalCase(category: .chatDrift, prefix: "Please review the ", trailing: ""),
        EvalCase(category: .chatDrift, prefix: "Hello! ", trailing: ""),
        EvalCase(category: .chatDrift, prefix: "Dear hiring manager, ", trailing: ""),
        EvalCase(category: .chatDrift, prefix: "Cheers,\n", trailing: "")
    ]

    /// Mid-sentence email writing — the continuation should match tone and finish the thought,
    /// not start a reply.
    private static let emailCases: [EvalCase] = [
        EvalCase(category: .email, prefix: "Following up on our call yesterday, I wanted to ", trailing: ""),
        EvalCase(category: .email, prefix: "Per our discussion, the next step is to ", trailing: ""),
        EvalCase(category: .email, prefix: "Apologies for the delay, I was waiting on ", trailing: ""),
        EvalCase(category: .email, prefix: "Could you take a look at the attached and ", trailing: ""),
        EvalCase(category: .email, prefix: "I've reviewed the proposal and overall it ", trailing: ""),
        EvalCase(category: .email, prefix: "We're targeting end-of-quarter for the rollout, so ", trailing: ""),
        EvalCase(category: .email, prefix: "Looping in Priya from legal so she can ", trailing: ""),
        EvalCase(category: .email, prefix: "Happy to set up a call this week to ", trailing: "")
    ]

    /// Informal team chat — short, conversational, lowercase. The model should match the register.
    private static let slackCases: [EvalCase] = [
        EvalCase(category: .slack, prefix: "anyone seen the ", trailing: ""),
        EvalCase(category: .slack, prefix: "merging the fix now, can someone ", trailing: ""),
        EvalCase(category: .slack, prefix: "lunch at 1? thinking we ", trailing: ""),
        EvalCase(category: .slack, prefix: "wfh today, ping me on ", trailing: ""),
        EvalCase(category: .slack, prefix: "looks like CI is red again, probably ", trailing: ""),
        EvalCase(category: .slack, prefix: "btw the new design ", trailing: "")
    ]

    /// Code-editor prefixes — the model should output code, not prose. These are chosen so any
    /// plausible continuation is a well-formed code fragment.
    private static let codeCases: [EvalCase] = [
        EvalCase(category: .code, prefix: "def total(items):\n    return sum(", trailing: ""),
        EvalCase(category: .code, prefix: "let total = items.reduce(0, { $0 + ", trailing: ""),
        EvalCase(category: .code, prefix: "const sorted = items.sort((a, b) => a.priority - ", trailing: ""),
        EvalCase(category: .code, prefix: "if let value = dictionary[\"", trailing: ""),
        EvalCase(category: .code, prefix: "guard !text.isEmpty else { return ", trailing: ""),
        EvalCase(category: .code, prefix: "func fibonacci(_ n: Int) -> Int {\n    if n < 2 { return ", trailing: ""),
        EvalCase(category: .code, prefix: "try { await fetch(`/api/users/${", trailing: ""),
        EvalCase(category: .code, prefix: "SELECT name, email FROM users WHERE created_at > ", trailing: "")
    ]

    /// English inside source files — should still be writing about code, not breaking into chat.
    private static let codeCommentCases: [EvalCase] = [
        EvalCase(category: .codeComment, prefix: "// TODO: handle the case where the response is ", trailing: ""),
        EvalCase(category: .codeComment, prefix: "/// Returns the smallest positive integer that ", trailing: ""),
        EvalCase(category: .codeComment, prefix: "// This is a workaround for the bug in ", trailing: ""),
        EvalCase(category: .codeComment, prefix: "# This function expects a list of ", trailing: "")
    ]

    /// Generic factual prose — should stay factual, not break into chat or refusal.
    private static let proseCases: [EvalCase] = [
        EvalCase(category: .prose, prefix: "The Swift compiler enforces optionals because ", trailing: ""),
        EvalCase(category: .prose, prefix: "Apple's on-device language model runs ", trailing: ""),
        EvalCase(category: .prose, prefix: "Photosynthesis converts sunlight into ", trailing: ""),
        EvalCase(category: .prose, prefix: "Inflation is when the general price level ", trailing: ""),
        EvalCase(category: .prose, prefix: "In macOS, an accessibility element is ", trailing: ""),
        EvalCase(category: .prose, prefix: "The largest moon of Saturn is ", trailing: "")
    ]

    /// Mid-line insertion — non-empty trailing text. Today FM never sees the trailing context, so
    /// many of these will produce a continuation that does not bridge cleanly. PR 5 adds trailing
    /// context to the request; rerunning this bucket against PR 5 is the way to measure that gain.
    private static let midLineCases: [EvalCase] = [
        EvalCase(category: .midLine, prefix: "I'm flying to ", trailing: " on Friday."),
        EvalCase(category: .midLine, prefix: "The deadline is ", trailing: ", which gives us about a week."),
        EvalCase(category: .midLine, prefix: "Could you bring the ", trailing: " when you come by?"),
        EvalCase(category: .midLine, prefix: "Let's name the project ", trailing: ", that's catchy enough."),
        EvalCase(category: .midLine, prefix: "The CEO will be in ", trailing: " for the offsite next month."),
        EvalCase(category: .midLine, prefix: "for value in ", trailing: " {\n    process(value)\n}"),
        EvalCase(category: .midLine, prefix: "func parse(_ input: ", trailing: ") -> Result<Value, Error> {"),
        EvalCase(category: .midLine, prefix: "SELECT * FROM ", trailing: " WHERE id = ?")
    ]

    private static let allCases: [EvalCase] = chatDriftCases + emailCases + slackCases
        + codeCases + codeCommentCases + proseCases + midLineCases

    /// Synthetic context stresses pair the unchanged raw renderer with the production bounded
    /// engine over identical inputs. Facts sit at the beginning of each reference so excerpting can
    /// retain them. Recall is reported separately from fit: a non-empty completion is not proof that
    /// the model used context, and stochastic recall has no perfect-score assertion.
    private struct ContextCase {
        let name: String
        let request: SuggestionRequest
        let expectedRecall: String?
        let isDuplicateSuffixControl: Bool

        init(name: String, request: SuggestionRequest, expectedRecall: String?, isDuplicateSuffixControl: Bool = false) {
            self.name = name
            self.request = request
            self.expectedRecall = expectedRecall
            self.isDuplicateSuffixControl = isDuplicateSuffixControl
        }
    }

    private static func combinedContextCases(contextSize: Int) -> [ContextCase] {
        // Scale filler to the actual model window: macOS 27 currently reports 8192, while older
        // releases use 4096. Keep English as a short recall control, then force real overflow in
        // multilingual cases without moving their reference fact away from the retained head.
        let scale = max(1, contextSize / 4096) * 3
        return [
            ContextCase(name: "english-reference", request: CotabbyTestFixtures.suggestionRequest(
                prefixText: "The project codename is ", maxPredictionTokens: 32,
                extendedContext: "The project codename is Cedar Lantern. " + String(repeating: "Reference details for project scheduling. ", count: 100),
                visualContextSummary: String(repeating: "Meeting agenda and project schedule. ", count: 120)),
                expectedRecall: "Cedar Lantern"),
            ContextCase(name: "chinese-screen", request: CotabbyTestFixtures.suggestionRequest(
                prefixText: "The project codename is ", maxPredictionTokens: 32,
                extendedContext: String(repeating: "背景资料。", count: 200 * scale),
                visualContextSummary: "Project codename: Silver Beacon. 项目代号是银色灯塔。 " + String(repeating: "项目会议记录与排期说明。", count: 300 * scale)),
                expectedRecall: "Silver Beacon"),
            ContextCase(name: "japanese-clipboard", request: CotabbyTestFixtures.suggestionRequest(
                prefixText: "The passphrase for the meeting is ", maxPredictionTokens: 32,
                extendedContext: String(repeating: "会議の参考資料です。", count: 140 * scale),
                clipboardContext: "The meeting passphrase is Blue Comet. 合言葉は青い彗星です。 " + String(repeating: "会議の予定。", count: 140 * scale),
                visualContextSummary: String(repeating: "今週の計画と会議記録。", count: 300 * scale)),
                expectedRecall: "Blue Comet"),
            ContextCase(name: "korean-history", request: CotabbyTestFixtures.suggestionRequest(
                prefixText: "Our release codename is ", maxPredictionTokens: 32,
                visualContextSummary: String(repeating: "이번주회의일정과업무기록입니다。", count: 250 * scale),
                historyExamples: ["Our release codename is Quiet Harbor. " + String(repeating: "이전출시회의기록입니다。", count: 100 * scale)]),
                expectedRecall: "Quiet Harbor"),
            // Retain the original failing fixture: copying this existing suffix is correctly
            // suppressed. It is a safety control, not a requirement to show duplicate ghost text.
            ContextCase(name: "dense-editor-duplicate-suffix-control", request: CotabbyTestFixtures.suggestionRequest(
                prefixText: String(repeating: "東京と大阪の報告書。대한민국보고서。ประชุมรายงาน。", count: 120 * scale) + "The next step is ",
                trailingText: " before Friday." + String(repeating: "報告書。", count: 100 * scale), maxPredictionTokens: 32,
                extendedContext: String(repeating: "Context references. ", count: 100 * scale),
                visualContextSummary: String(repeating: "Additional project notes. ", count: 160 * scale)),
                expectedRecall: nil, isDuplicateSuffixControl: true),
            // The same oversized multilingual document now has a coherent caret-nearest checklist:
            // the missing verb belongs before an existing object/deadline, so a useful continuation
            // must bridge into the suffix rather than merely copy an unrelated date fragment.
            ContextCase(name: "dense-editor-tail", request: CotabbyTestFixtures.suggestionRequest(
                prefixText: String(repeating: "東京と大阪の報告書。대한민국보고서。ประชุมรายงาน。", count: 120 * scale)
                    + "\n\nRelease checklist:\nValidation has passed. Packaging is next. The next step is to ",
                trailingText: " the signed app before Friday.\n\n" + String(repeating: "報告書。", count: 100 * scale),
                maxPredictionTokens: 32,
                extendedContext: String(repeating: "Context references. ", count: 100 * scale),
                visualContextSummary: String(repeating: "Additional project notes. ", count: 160 * scale)), expectedRecall: nil)
        ]
    }

    func test_reportCombinedContextSuite() async throws {
        let availability = FoundationModelAvailabilityService()
        availability.refresh()
        try XCTSkipUnless(availability.isAvailable, "Apple Intelligence unavailable: \(availability.userVisibleMessage)")
        let model = try XCTUnwrap(availability.systemLanguageModel)
        let engine = FoundationModelSuggestionEngine(availabilityService: availability)
        let contextSize: Int
        #if compiler(>=6.3)
        if #available(macOS 26.4, *) { contextSize = model.contextSize } else { contextSize = 4096 }
        #else
        contextSize = 4096
        #endif
        let scenarios = Self.combinedContextCases(contextSize: contextSize)
        var rawOverflows = 0
        var rawFailures = 0
        var rawRecalls = 0
        var boundedRecalls = 0
        var boundedNonempty = 0
        for scenario in scenarios {
            let request = scenario.request
            let original = FoundationModelPromptRenderer.Content(request).payload
            let responseReserve = max(1, request.maxPredictionTokens)
            var countMeasurements = 0
            var actualTokenizerCalls = 0
            #if compiler(>=6.3)
            var countedInstructions: (text: String, tokens: Int)?
            #endif
            let count: (FoundationModelPromptRenderer.Payload) async throws -> Int = { payload in
                countMeasurements += 1
                #if compiler(>=6.3)
                if #available(macOS 26.4, *) {
                    let instructions: Int
                    if let countedInstructions, countedInstructions.text == payload.instructions {
                        instructions = countedInstructions.tokens
                    } else {
                        instructions = try await model.tokenCount(for: Instructions(payload.instructions))
                        actualTokenizerCalls += 1
                        try Task.checkCancellation()
                        countedInstructions = (payload.instructions, instructions)
                    }
                    let prompt = try await model.tokenCount(for: payload.prompt)
                    actualTokenizerCalls += 1
                    try Task.checkCancellation()
                    return instructions + prompt
                }
                #endif
                return payload.utf8Count
            }
            let originalUnits = try await count(original)
            let overflowing = originalUnits + responseReserve + 128 > contextSize
            if overflowing { rawOverflows += 1 }
            let prepareStart = Date()
            let payload = try await FoundationModelPromptRenderer.preparePayload(for: request,
                contextSize: contextSize, count: count)
            let preparationMilliseconds = Date().timeIntervalSince(prepareStart) * 1000
            let boundedUnits = try await count(payload)
            XCTAssertLessThanOrEqual(boundedUnits + responseReserve + 128, contextSize)
            XCTAssertTrue(payload.prompt.contains("The next step is ") || payload.prompt.contains(request.prefixText), scenario.name)
            var rawText = ""
            var rawError = "none"
            do {
                let baselineSession = LanguageModelSession(model: model, instructions: original.instructions)
                for try await snapshot in baselineSession.streamResponse(to: original.prompt,
                    options: GenerationOptions(sampling: .greedy, temperature: 0.1, maximumResponseTokens: responseReserve)) {
                    rawText = snapshot.content
                    try Task.checkCancellation()
                }
            } catch {
                rawFailures += 1
                rawError = String(describing: error)
            }
            let baselineText = SuggestionTextNormalizer.normalizeDetailed(rawText, for: request,
                promptEchoCandidates: [original.prompt]).text
            let result: SuggestionResult
            do {
                result = try await engine.generateSuggestion(for: request)
            } catch {
                print("FM_CONTEXT_BOUNDED_ERROR name=\(scenario.name) error=\(String(describing: error))")
                throw error
            }
            boundedNonempty += assertContextResult(result, for: scenario) ? 1 : 0
            let baselineRecall = scenario.expectedRecall.map { baselineText.localizedCaseInsensitiveContains($0) } ?? false
            let boundedRecall = scenario.expectedRecall.map { result.text.localizedCaseInsensitiveContains($0) } ?? false
            if baselineRecall { rawRecalls += 1 }
            if boundedRecall { boundedRecalls += 1 }
            print("FM_CONTEXT_CASE name=\(scenario.name) raw_units=\(originalUnits) bounded_units=\(boundedUnits) " +
                "context_size=\(contextSize) raw_overflow=\(overflowing) " +
                "duplicate_suffix_control=\(scenario.isDuplicateSuffixControl) " +
                "count_measurements=\(countMeasurements) actual_tokenizer_calls=\(actualTokenizerCalls) " +
                "measurement=\(actualTokenizerCalls > 0 ? "apple_tokens" : "utf8_upper_bound") " +
                "exact_count_prep_ms=\(Int(preparationMilliseconds.rounded())) " +
                "raw_recall=\(baselineRecall) bounded_recall=\(boundedRecall) " +
                "raw_error=\(rawError) raw=\(baselineText.debugDescription) bounded=\(result.text.debugDescription) " +
                "bounded_raw=\(result.rawText.debugDescription) bounded_suppression=\(result.suppressionReason ?? "none")")
        }
        print("FM_CONTEXT_SUMMARY cases=\(scenarios.count) raw_overflows=\(rawOverflows) " +
            "raw_failures=\(rawFailures) raw_recall=\(rawRecalls)/4 bounded_recall=\(boundedRecalls)/4 " +
            "intended_nonempty=\(boundedNonempty)/5 duplicate_suffix_controls=1")
        XCTAssertGreaterThan(rawOverflows, 0, "Stress cases must actually exceed the unbounded combined window")
        XCTAssertEqual(boundedNonempty, 5, "All five intended-continuation cases must produce text")
    }

    /// Counts nonempty intended completions, not semantic quality. The safety control may be empty only
    /// when the model produced a real suffix copy and the normalizer rejected that specific copy.
    private func assertContextResult(_ result: SuggestionResult, for scenario: ContextCase) -> Bool {
        let isNonempty = !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if scenario.isDuplicateSuffixControl {
            if !isNonempty {
                XCTAssertFalse(result.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "The safety control must have real output to suppress")
                XCTAssertEqual(result.suppressionReason, "duplicatesTrailingText",
                    "An unrelated empty generation is not evidence of duplicate-suffix protection")
            }
            return false
        }
        XCTAssertTrue(isNonempty, "\(scenario.name): \(result.suppressionReason ?? "no suppression reason")")
        return isNonempty
    }

    /// Phrases that mark a continuation as out-of-character. Matched case-insensitively anywhere
    /// in the output, so a continuation that mentions one inside a longer thought still flags.
    private static let driftTells: [String] = [
        "how are you", "how's it going", "hows it going", "hope you", "hope it", "hope this",
        "as an ai", "i'm here to", "i am here to", "let me know if you", "feel free to",
        "happy to help", "how can i help", "is there anything i", "i'd be happy", "i would be happy",
        // Assistant refusals / apologies — the model treating the prefix as a request to decline.
        "i'm sorry", "i am sorry", "i cannot assist", "i can't assist", "cannot assist with",
        "cannot help with", "unable to assist", "i cannot help", "i can't help"
    ]

    /// Chat-template or decoder residue. None should appear on the FM-only path, but having them in
    /// the rubric catches future routing regressions where the llama backend's output reaches the
    /// FM normalizer.
    private static let noiseMarkers: [String] = [
        "<|im_start|>", "<|im_end|>", "<think>", "</think>", "[INST]", "[/INST]"
    ]

    func test_reportEvalSuite() async throws {
        let availability = FoundationModelAvailabilityService()
        availability.refresh()
        try XCTSkipUnless(
            availability.isAvailable,
            "Apple Intelligence is unavailable here: \(availability.userVisibleMessage)"
        )

        let engine = FoundationModelSuggestionEngine(availabilityService: availability)

        var outcomes: [CaseOutcome] = []
        outcomes.reserveCapacity(Self.allCases.count)

        for scenario in Self.allCases {
            let request = CotabbyTestFixtures.suggestionRequest(
                prefixText: scenario.prefix,
                trailingText: scenario.trailing,
                maxPredictionTokens: 32
            )
            let start = Date()
            let result = try await engine.generateSuggestion(for: request)
            let elapsed = Date().timeIntervalSince(start)

            let normalized = result.text
            outcomes.append(
                CaseOutcome(
                    scenario: scenario,
                    drifted: Self.isDrift(prefix: scenario.prefix, output: normalized),
                    empty: normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    noise: Self.containsNoise(normalized) || Self.containsNoise(result.rawText),
                    midWord: Self.endsMidWord(normalized),
                    normalized: normalized,
                    raw: result.rawText,
                    latency: elapsed
                )
            )
        }

        let report = Self.renderReport(outcomes: outcomes)
        print(report)

        // Overall drift threshold stays permissive — we run this to track *trend*, not to gate CI.
        // 20% of cases (rounded down, floor of 3) gives the eval headroom for stochastic samples.
        let driftCount = outcomes.filter(\.drifted).count
        let driftCeiling = max(outcomes.count / 5, 3)
        XCTAssertLessThanOrEqual(
            driftCount,
            driftCeiling,
            "Too many out-of-character continuations.\n\(report)"
        )
        XCTAssertEqual(
            outcomes.filter(\.noise).count,
            0,
            "Chat-template residue leaked through.\n\(report)"
        )
        XCTAssertEqual(
            outcomes.filter(\.empty).count,
            0,
            "Some prompts returned empty after normalization.\n\(report)"
        )
    }

    private static func renderReport(outcomes: [CaseOutcome]) -> String {
        var lines = ["\n=== FM eval suite ==="]
        for (index, outcome) in outcomes.enumerated() {
            let tags = [
                outcome.drifted ? "DRIFT" : nil,
                outcome.empty ? "EMPTY" : nil,
                outcome.noise ? "NOISE" : nil,
                outcome.midWord ? "MIDWORD" : nil
            ].compactMap { $0 }
            let status = tags.isEmpty ? "ok" : tags.joined(separator: "+")
            let ms = Int((outcome.latency * 1000).rounded())
            lines.append("[\(index + 1)] \(outcome.scenario.category.rawValue) \(status) \(ms)ms")
            lines.append("    prefix=\(outcome.scenario.prefix.debugDescription)")
            if !outcome.scenario.trailing.isEmpty {
                lines.append("    trail =\(outcome.scenario.trailing.debugDescription)")
            }
            lines.append("    norm  =\(outcome.normalized.debugDescription)")
            lines.append("    raw   =\(outcome.raw.debugDescription)")
        }

        let categories = Set(outcomes.map(\.scenario.category)).sorted { $0.rawValue < $1.rawValue }
        lines.append("--- per-category ---")
        for category in categories {
            let bucket = outcomes.filter { $0.scenario.category == category }
            let drift = bucket.filter(\.drifted).count
            let midWord = bucket.filter(\.midWord).count
            lines.append(
                "\(category.rawValue): drift \(drift)/\(bucket.count), midword \(midWord)/\(bucket.count)"
            )
        }

        let latenciesMs = outcomes.map { Int(($0.latency * 1000).rounded()) }.sorted()
        if !latenciesMs.isEmpty {
            // Median: for an even-length sample average the two middle values, otherwise pick the
            // single middle. Reporting the upper-middle as "p50" would mask a small regression
            // sitting right at the median.
            let p50: Int
            if latenciesMs.count.isMultiple(of: 2) {
                let mid = latenciesMs.count / 2
                p50 = (latenciesMs[mid - 1] + latenciesMs[mid]) / 2
            } else {
                p50 = latenciesMs[latenciesMs.count / 2]
            }
            // Nearest-rank: ceil(0.95 * n) gives the 1-indexed rank, so subtract 1 for the array
            // index. Plain truncation overshoots for small per-category buckets.
            let rank = Int((Double(latenciesMs.count) * 0.95).rounded(.up))
            let p95Index = min(latenciesMs.count - 1, max(0, rank - 1))
            let p95 = latenciesMs[p95Index]
            lines.append("--- latency (ms) ---")
            lines.append("p50=\(p50), p95=\(p95), max=\(latenciesMs.last ?? 0)")
        }

        let driftTotal = outcomes.filter(\.drifted).count
        let midWordTotal = outcomes.filter(\.midWord).count
        let emptyTotal = outcomes.filter(\.empty).count
        let noiseTotal = outcomes.filter(\.noise).count
        lines.append(
            "TOTAL: \(outcomes.count) cases, drift=\(driftTotal), "
                + "midword=\(midWordTotal), empty=\(emptyTotal), noise=\(noiseTotal)"
        )
        return lines.joined(separator: "\n")
    }

    /// A continuation drifts if it contains an assistant tell, or opens with a greeting word that
    /// the prefix had not already started (so finishing "Hi Sa…" → "rah" is fine, but a bare
    /// "Hi there" after a mid-sentence prefix is drift).
    private static func isDrift(prefix: String, output: String) -> Bool {
        let lower = output.lowercased()
        if driftTells.contains(where: { lower.contains($0) }) {
            return true
        }

        // Greeting openers only — "thanks" is omitted because continuing the user's own message
        // with a thank-you ("Hey Jacob, " -> "thanks for the update") is correct, not drift.
        let openers = ["hi ", "hey ", "hello", "dear ", "good morning", "good afternoon"]
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixLower = prefix.lowercased()
        return openers.contains { opener in
            trimmed.hasPrefix(opener) && !prefixLower.contains(opener)
        }
    }

    private static func containsNoise(_ text: String) -> Bool {
        noiseMarkers.contains { text.contains($0) }
    }

    /// Heuristic for "the token budget cut the model off mid-word". Empty strings are exempt
    /// (counted under `empty`). A clean stop is sentence-ending punctuation or a closing bracket
    /// / paren that finishes a code fragment. Trimming above strips any trailing whitespace, so a
    /// whitespace check here would be dead code.
    private static func endsMidWord(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else {
            return false
        }
        if last.isPunctuation { return false }
        if "})]>".contains(last) { return false }
        return true
    }
#else
    func test_reportCombinedContextSuite() throws {
        throw XCTSkip("Live combined-context eval is local-only; enable RUN_FM_EVAL.")
    }

    func test_reportEvalSuite() throws {
        throw XCTSkip(
            "Live FM eval is local-only. Run with "
                + "SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) RUN_FM_EVAL' (see file header)."
        )
    }
#endif
}

#endif
