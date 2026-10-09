import Foundation

/// File overview:
/// Adapts Cotabby's shared suggestion request into the prompting style that works best with Apple's
/// Foundation Models framework.
///
/// Why this file exists:
/// llama.cpp and Apple's on-device model accept the same high-level task, but they respond best
/// to different prompt shapes. The local llama runtime consumes one prompt string directly, while
/// Foundation Models gives us a first-class instructions channel. Keeping that translation here
/// prevents Apple-specific prompt policy from leaking back into `SuggestionCoordinator` or the
/// shared request factory.
nonisolated enum FoundationModelPromptRenderer {
    /// The exact two-channel payload passed to one pristine Apple session. Budgeting this pair
    /// together prevents optional instructions from silently competing with the prompt for context.
    struct Payload: Equatable, Sendable {
        let instructions: String
        let prompt: String
        var utf8Count: Int { instructions.utf8.count + prompt.utf8.count }
    }

    enum BudgetError: Error { case cannotFit }
    static let framingTokenReserve = 128
    static let maximumBudgetRefits = 64

    /// Mutable rendering inputs live only during one preparation. Trimming these values preserves
    /// section framing and the fixed continuation contract; slicing a rendered prompt would not.
    struct Content: Sendable {
        var applicationName: String
        var toneHint: String?
        var surfaceFacts: [String]
        var visualContextSummary: String?
        var historyExamples: [String]
        var clipboardContext: String?
        var prefixText: String
        var trailingText: String
        var completionLengthInstruction: String
        var languageInstruction: String?
        var customRules: [String]
        var extendedContext: String?

        init(_ request: SuggestionRequest) {
            applicationName = request.context.applicationName
            toneHint = FoundationModelPromptRenderer.appToneHint(forBundleIdentifier: request.context.bundleIdentifier)
            surfaceFacts = []
            if let surface = request.surfaceContext {
                if let title = surface.windowTitle { surfaceFacts.append("The window is titled \"\(title)\".") }
                if let domain = surface.domain { surfaceFacts.append("The user is on \(domain).") }
                if let placeholder = surface.fieldPlaceholder {
                    surfaceFacts.append("The text field is labeled \"\(placeholder)\".")
                }
            }
            visualContextSummary = request.visualContextSummary
            historyExamples = request.historyExamples.filter { !$0.isEmpty }
            clipboardContext = request.clipboardContext
            prefixText = request.prefixText
            trailingText = String(request.context.trailingText.prefix(max(0, request.maxSuffixCharacters)))
            completionLengthInstruction = request.completionLengthInstruction
            languageInstruction = request.languageInstruction
            customRules = request.customRules.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            extendedContext = request.extendedContext
        }

        var payload: Payload {
            Payload(instructions: FoundationModelPromptRenderer.sessionInstructions(for: self),
                    prompt: FoundationModelPromptRenderer.prompt(for: self))
        }

        /// First reduce oversized optional sources to useful excerpts, then drop lower-priority
        /// sources before touching editor text. Keeping a small excerpt from each avoids one large
        /// OCR capture crowding every reference out. Prefix keeps its tail; suffix keeps its head.
        mutating func shrink() -> Bool {
            if shrinkOversizedReferences() { return true }
            if removeOptionalReference() { return true }
            // Sixty-four complete graphemes leave useful nearby words on both sides of a caret.
            // Never cut UTF-8 or a composed emoji to make the payload fit; fail if this floor plus
            // the fixed output contract still exceeds the window.
            if trailingText.count > 64 {
                trailingText = String(trailingText.prefix(max(64, trailingText.count / 2)))
                return true
            }
            if prefixText.count > 64 {
                prefixText = String(prefixText.suffix(max(64, prefixText.count / 2)))
                return true
            }
            return false
        }

        private mutating func shrinkOversizedReferences() -> Bool {
            var changed = false
            if historyExamples.reduce(0, { $0 + $1.count }) > 512 {
                historyExamples = Array(historyExamples.prefix(max(1, historyExamples.count / 2)))
                    .map { String($0.prefix(max(64, $0.count / 2))) }
                changed = true
            }
            if customRules.reduce(0, { $0 + $1.count }) > 256 {
                customRules = Array(customRules.prefix(max(1, customRules.count / 2)))
                    .map { String($0.prefix(max(32, $0.count / 2))) }
                changed = true
            }
            // Reduce all oversized optional sources in the same refit. This avoids serially
            // tokenizing dozens of nearly identical payloads when several sources are long.
            changed = Self.shorten(&clipboardContext, floor: 256) || changed
            changed = Self.shorten(&extendedContext, floor: 256) || changed
            changed = Self.shorten(&visualContextSummary, floor: 512) || changed
            if surfaceFacts.reduce(0, { $0 + $1.count }) > 256 {
                surfaceFacts = surfaceFacts.map { String($0.prefix(max(32, $0.count / 2))) }
                changed = true
            }
            changed = Self.shorten(&languageInstruction, floor: 128) || changed
            if applicationName.count > 128 { applicationName = String(applicationName.prefix(128)); changed = true }
            if completionLengthInstruction.count > 256 {
                completionLengthInstruction = String(completionLengthInstruction.prefix(256)); changed = true
            }
            return changed
        }

        private mutating func removeOptionalReference() -> Bool {
            if !historyExamples.isEmpty { historyExamples = []; return true }
            if !customRules.isEmpty { customRules = []; return true }
            if clipboardContext != nil { clipboardContext = nil; return true }
            if extendedContext != nil { extendedContext = nil; return true }
            if visualContextSummary != nil { visualContextSummary = nil; return true }
            if !surfaceFacts.isEmpty { surfaceFacts = []; return true }
            if toneHint != nil { toneHint = nil; return true }
            if languageInstruction != nil { languageInstruction = nil; return true }
            if applicationName != "App" { applicationName = "App"; return true }
            if !completionLengthInstruction.isEmpty { completionLengthInstruction = ""; return true }
            return false
        }

        private static func shorten(_ value: inout String?, floor: Int) -> Bool {
            guard let text = value, text.count > floor else { return false }
            value = String(text.prefix(max(floor, text.count / 2)))
            return true
        }
    }

    /// Counts the exact fully rendered pair on every attempt. Modern callers inject Apple's token
    /// counts; older systems use UTF-8 bytes as a conservative upper bound rather than chars/4,
    /// which dangerously undercounts Chinese and other dense scripts. Cancellation is checked
    /// after each asynchronous count before a fitting payload can reach session construction.
    static func preparePayload(
        for request: SuggestionRequest, contextSize: Int,
        count: (Payload) async throws -> Int
    ) async throws -> Payload {
        let responseReserve = max(1, request.maxPredictionTokens)
        guard contextSize > framingTokenReserve, contextSize - framingTokenReserve > responseReserve else {
            throw BudgetError.cannotFit
        }
        let limit = contextSize - framingTokenReserve - responseReserve
        var content = Content(request)
        for _ in 0..<maximumBudgetRefits {
            try Task.checkCancellation()
            let payload = content.payload
            let units = try await count(payload)
            try Task.checkCancellation()
            guard units >= 0 else { throw BudgetError.cannotFit }
            if units <= limit { return payload }
            guard content.shrink() else { throw BudgetError.cannotFit }
        }
        throw BudgetError.cannotFit
    }

    /// Session instructions define the model's role and output contract.
    /// Apple documents that instructions have higher priority than the prompt itself, which makes
    /// them the right place to say "this is autocomplete, not chat."
    ///
    /// The framing is deliberately *text continuation*, not *assist the user*. Apple's system model
    /// is chat-tuned, so any second-person/assistant framing pulls it toward greetings and
    /// replies. Apple's WWDC25 prompt-design guidance is to use a positive identity plus a small
    /// number of demonstrations rather than a long list of prohibitions, so the rules here stay
    /// short, positive, and concrete; the continuation example below carries the rest of the
    /// anti-drift signal.
    static func sessionInstructions(for request: SuggestionRequest) -> String {
        sessionInstructions(for: Content(request))
    }

    private static func sessionInstructions(for request: Content) -> String {
        var lines = [
            "You complete partially-typed text. The user is the author; you produce the next "
                + "few words they would type, in their voice.",
            "Output the continuation only: no greeting, no sign-off, no quotes, no markdown, "
                + "no labels, no explanation.",
            // Anti-echo guard. Without an explicit rule the chat-tuned model sometimes emits the
            // existing text again instead of continuing — most reliably on mid-line comment and
            // mid-sentence prose prefixes — which the normalizer then strips, leaving the user
            // with no suggestion at all. The rule is paired with positive framing so it does not
            // violate the WWDC25 "positive identity over prohibitions" guidance that motivates
            // this rewrite.
            "Continue from the position immediately after the existing text. Do not repeat or "
                + "quote the existing text.",
            "Match the existing language, register, casing, and punctuation. Continue the "
                + "current sentence or thought rather than restarting it.",
            "Use clipboard or screen context only when it directly helps the next words."
        ]

        // The declared-language hint refines the "match the existing language" rule above. It sits
        // right after the base block so the instructions channel weights it heavily.
        if let languageInstruction = request.languageInstruction, !languageInstruction.isEmpty {
            lines.append(languageInstruction)
        }

        // We intentionally do NOT inject the user's name here. On the chat-tuned system model a
        // stated name is the single biggest trigger for breaking character ("Jacob, how are
        // you"). The llama backend personalizes via `BaseCompletionPromptRenderer`; Apple's model
        // does not get the name until we can scope it to contexts that actually need it.

        // Instructions reach every writing surface. An unconditional programming demonstration
        // introduces unrelated code even when the live text is an email or chat. Keep one short
        // continuation example; the live prefix and per-app hint supply the subject and format.
        lines.append("Examples (quotes only mark the boundaries; never output the quotes):")
        lines.append(contentsOf: Self.continuationExampleLines)

        // Style rules live in the high-priority instructions channel like the base rules, but are
        // appended last with an explicit subordination line so they cannot override the output
        // contract above.
        let trimmedRules = request.customRules
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !trimmedRules.isEmpty {
            lines.append("Your style preferences:")
            lines.append(contentsOf: trimmedRules.map { "- \($0)" })
            lines.append("Apply these only when they fit the continuation naturally; never break the rules above.")
        }

        // Free-form reference notes live in the instructions channel (not the per-request prompt)
        // so the cached session prefix carries them across keystrokes and they do not have to be
        // re-tokenized on every generation. The subordination line repeats the prompt-injection
        // guard used for style preferences above: this is reference material, not an override.
        if let extendedContext = request.extendedContext, !extendedContext.isEmpty {
            lines.append("Reference notes from the user:")
            lines.append(extendedContext)
            lines.append("Use these notes only when they fit the continuation naturally; never break the rules above.")
        }

        return lines.joined(separator: "\n")
    }

    /// Demonstrates continuing a sentence without replying to its author. Code completion still
    /// follows the request's actual text and tone hint, without a fixed programming topic in
    /// every session's instructions.
    private static let continuationExampleLines: [String] = [
        "Existing text: \"I just wanted to follow up on the \"",
        "Continuation: proposal we discussed last week."
    ]

    /// The request prompt stays short and concrete.
    /// Foundation Models tends to behave more reliably when the prompt describes the immediate task
    /// and the stable rules live in session instructions instead of being mixed together.
    static func prompt(for request: SuggestionRequest) -> String {
        prompt(for: Content(request))
    }

    private static func prompt(for request: Content) -> String {
        let prefixText = request.prefixText

        if prefixText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // This should be rare because upstream generation is already gated on meaningful text.
            // Returning a small fallback prompt is safer than crashing or sending an empty string.
            return "Continue the text at the caret using a short inline completion."
        }

        var sections = [
            "Screen context:",
            "User is on \(request.applicationName)."
        ]

        // Per-app tone hint lives in the per-request prompt, not the session instructions, so it
        // can vary as the user switches apps without invalidating the cached instruction prefix.
        if let toneHint = request.toneHint {
            sections.append(toneHint)
        }

        // The same sanitized surface facts the llama preface states: the window title (subject,
        // document, channel) and the web domain are the strongest on-topic cues available. Apple's
        // session cache holds instructions, not the per-request prompt, so per-app variance here
        // costs nothing.
        sections.append(contentsOf: request.surfaceFacts)

        if let summary = request.visualContextSummary,
           !summary.isEmpty {
            sections.append("Screen content:")
            sections.append(summary)
        }

        // The user's own earlier sentences live in the per-request prompt, not the instructions:
        // they change as the topic moves, and instructions are the cached part of Apple's session.
        // The framing says what they are for so the chat-tuned model borrows wording, not content.
        let examples = request.historyExamples.filter { !$0.isEmpty }
        if !examples.isEmpty {
            sections.append("")
            sections.append("Earlier writing by the same user, to match their wording (do not repeat it):")
            sections.append(contentsOf: examples.map { "\"\($0)\"" })
        }

        if let clipboardContext = request.clipboardContext,
           !clipboardContext.isEmpty {
            sections.append("")
            sections.append("User's clipboard:")
            sections.append(clipboardContext)
        }

        sections.append(contentsOf: [
            "",
            "Text before the caret:",
            prefixText
        ])

        // Trailing context lets the model produce a continuation that bridges into what is already
        // present after the caret instead of overwriting it. The upstream focus snapshot does NOT
        // bound this string (it returns the full document tail from the caret), so we apply
        // `maxSuffixCharacters` here to keep a caret-at-top in a long document from pushing the
        // entire body through Apple's 4096-token shared context window.
        let trailing = request.trailingText
        if !trailing.isEmpty {
            sections.append(contentsOf: [
                "",
                "Text after the caret:",
                trailing
            ])
        }

        // Length cue is reintroduced on the FM prompt channel (not instructions). Apple's model
        // responds reliably to plain-language length hints, and the explicit cue keeps shorter
        // completions from getting hard-truncated mid-word by `maximumResponseTokens` alone.
        sections.append(contentsOf: [
            "",
            "Write only the next continuation fragment.",
            request.completionLengthInstruction
        ])

        return sections.joined(separator: "\n")
    }

    /// Maps the focused app's surface class to a one-line tone cue or nil if no rule matches.
    /// Classification lives in the shared `AppSurfaceClassifier` so the Apple and llama prompt
    /// paths agree about what kind of app the user is in. Terminal emulators and unrecognized apps get no hint: a shell
    /// prompt, log pager, or `git commit` buffer is mostly prose, not code, so the no-hint default
    /// is safer than a guessed cue.
    private static func appToneHint(forBundleIdentifier identifier: String) -> String? {
        switch AppSurfaceClassifier.classify(bundleIdentifier: identifier) {
        case .codeEditor:
            return "The user is writing code, so the continuation should be code rather than prose."
        case .email:
            return "The user is writing an email, so keep the same register and finish the current thought."
        case .chat:
            return "The user is in a chat app, so keep the continuation short and informal."
        case .browser:
            return "The user is typing inside a browser, so keep the continuation concise."
        case .terminal, .other:
            return nil
        }
    }

    /// Diagnostics need to show both payloads Apple receives: the high-priority instructions and
    /// the shorter request prompt. Keeping this renderer-owned prevents the menu/debug preview from
    /// accidentally showing the llama prompt while Apple Intelligence is the selected engine.
    static func promptPreview(for request: SuggestionRequest) -> String {
        [
            "Instructions:",
            sessionInstructions(for: request),
            "",
            "Prompt:",
            prompt(for: request)
        ].joined(separator: "\n")
    }
}
