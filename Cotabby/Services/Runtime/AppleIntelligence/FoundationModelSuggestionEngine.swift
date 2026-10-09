import Foundation
import Logging

#if canImport(FoundationModels)
import FoundationModels
#endif

/// File overview:
/// Adapts Apple's on-device Foundation Models framework to Cotabby's existing
/// `SuggestionGenerating` capability. The coordinator should not care whether suggestions come
/// from llama.cpp or Apple Intelligence; that backend choice belongs in app composition.
///
/// The engine caches a pristine `LanguageModelSession` so the focus-time `prewarm(for:)` call can
/// hand the same prewarmed session to the first user-typed request. Reuse is bounded: once a
/// session has actually serviced a `respond` (its transcript has grown past the pristine count)
/// or is mid-stream (`isResponding == true`), the next request builds a fresh session instead.
/// This keeps the prewarm latency win on the first keystroke after focus without inheriting
/// Apple's two single-flight failure modes — `concurrentRequests` from overlapping streams on the
/// same session, and `exceededContextWindowSize` from transcript entries piling up over many
/// keystrokes in the same field. See `ensureSession` for the reuse predicate.
///
/// `prewarm(for:)` is the supported hook for "the user just focused an editable field; a real
/// request is likely within a second." The coordinator calls it from the focus path; the engine
/// builds (or reuses) the session and calls Apple's `LanguageModelSession.prewarm()` so weight
/// loading and instruction tokenization happen before the first user-visible respond call.
///
/// Generation itself goes through `session.streamResponse` rather than `session.respond`. Apple's
/// stream yields cumulative partials, so the loop captures the latest snapshot and exits with it
/// as the final raw text. The win is responsiveness to cancellation: `Task.checkCancellation()`
/// inside the loop lets the coordinator interrupt mid-decode when the user types past the
/// in-flight suggestion, where `respond` would otherwise have to run to completion. The external
/// `SuggestionResult` shape is unchanged, so the rest of the pipeline (overlay, presenter,
/// active-session reconciliation) stays as-is — pushing partials all the way to the overlay is a
/// separate, larger change scoped to a follow-up.
#if canImport(FoundationModels)
@available(macOS 26.0, *)
@MainActor
final class FoundationModelSuggestionEngine {
    private let availabilityService: FoundationModelAvailabilityService
    private var cachedSession: CachedSession?

    init(availabilityService: FoundationModelAvailabilityService) {
        self.availabilityService = availabilityService
    }

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        try await generateSuggestion(for: request, onPartial: nil)
    }

    /// Streaming variant: Apple's response stream already yields cumulative snapshots; each one is
    /// normalized and forwarded so ghost text can render before the stream finishes. The previous
    /// implementation deliberately discarded the partials pending coordinator support.
    func generateSuggestion(
        for request: SuggestionRequest,
        onPartial: (@MainActor (SuggestionResult) -> Void)?
    ) async throws -> SuggestionResult {
        availabilityService.refresh()

        let baseMetadata: Logger.Metadata = [
            "request_id": .string(request.requestID),
            "engine": .string("apple_intelligence")
        ]

        guard availabilityService.isAvailable else {
            let message = availabilityService.userVisibleMessage
            CotabbyLogger.suggestion.debug(
                "Foundation model unavailable: \(message)",
                metadata: baseMetadata
            )
            throw SuggestionClientError.unavailable(message)
        }

        do {
            let startTime = Date()
            // In production, `isAvailable == true` implies `systemLanguageModel` is non-nil because
            // only `SystemAvailabilityProvider` can report `.available`, and it owns
            // the model instance. If a future test provider reports available without a model, keep
            // the failure explicit instead of constructing a session with the wrong backend state.
            guard let model = availabilityService.systemLanguageModel else {
                throw SuggestionClientError.unavailable(
                    "Apple Intelligence reported available, but Cotabby could not access the system language model."
                )
            }

            let payload = try await preparedPayload(for: request, model: model)
            try Task.checkCancellation()
            let prompt = payload.prompt
            CotabbyLogger.suggestion.debug("Foundation model generating", metadata: baseMetadata.merging([
                "prompt_bytes": .stringConvertible(prompt.utf8.count),
                "instructions_bytes": .stringConvertible(payload.instructions.utf8.count),
                "context_size": .stringConvertible(contextSize(for: model)),
                "max_tokens": .stringConvertible(request.maxPredictionTokens)
            ]) { _, new in new })
            // Build/cache with the exact instructions we just counted, rather than rendering the
            // original unbounded request again after deciding the combined payload fits.
            let session = ensureSession(instructions: payload.instructions, model: model)
            let stream = session.streamResponse(
                to: prompt,
                options: generationOptions(for: request)
            )
            // Apple's stream yields cumulative `Snapshot` values whose `.content` carries the
            // text generated so far. Capture each snapshot first and check cancellation after, so a
            // late cancel between the final snapshot and its assignment doesn't discard fully
            // decoded text — cancellation always throws, but keeping the best-available text saved
            // before honoring the signal makes the intent obvious.
            var rawSuggestion = ""
            var didReceiveSnapshot = false
            for try await partial in stream {
                rawSuggestion = partial.content
                didReceiveSnapshot = true
                try Task.checkCancellation()
                // This engine is main-actor confined, so partials forward inline (no hop). Empty
                // normalizations are withheld; the coordinator's monotonic policy handles the rest.
                if let onPartial {
                    let partialNormalized = SuggestionTextNormalizer.normalizeDetailed(
                        rawSuggestion,
                        for: request,
                        promptEchoCandidates: [prompt]
                    ).text
                    if !partialNormalized.isEmpty {
                        onPartial(SuggestionResult(
                            generation: request.generation,
                            rawText: rawSuggestion,
                            text: partialNormalized,
                            latency: Date().timeIntervalSince(startTime)
                        ))
                    }
                }
            }
            try Task.checkCancellation()
            // Apple's documented contract is at least one snapshot on a successful stream, so a
            // zero-snapshot path is treated as a generation failure rather than a silent empty
            // suggestion — the latter would let the overlay clear without surfacing that the model
            // produced literally nothing.
            guard didReceiveSnapshot else {
                throw SuggestionClientError.generationFailed(
                    "Apple Intelligence finished streaming without producing any content."
                )
            }
            let normalization = SuggestionTextNormalizer.normalizeDetailed(
                rawSuggestion,
                for: request,
                promptEchoCandidates: [prompt]
            )
            let normalizedSuggestion = normalization.text

            let latency = Date().timeIntervalSince(startTime)
            let rawChars = rawSuggestion.count
            let normalizedChars = normalizedSuggestion.count
            let latencyMs = Int(latency * 1000)
            let suppressionReason = normalization.suppression?.rawValue ?? "none"
            CotabbyLogger.suggestion.debug(
                "Foundation model generated",
                metadata: baseMetadata.merging([
                    "raw_chars": .stringConvertible(rawChars),
                    "normalized_chars": .stringConvertible(normalizedChars),
                    "suppression_reason": .string(suppressionReason),
                    "latency_ms": .stringConvertible(latencyMs)
                ]) { _, new in new }
            )
            CotabbyLogger.llmIO.debug(
                "foundation_model generation",
                metadata: baseMetadata.merging([
                    "prompt": .string(prompt),
                    "completion_raw": .string(rawSuggestion),
                    "completion_normalized": .string(normalizedSuggestion),
                    "prompt_bytes": .stringConvertible(prompt.utf8.count),
                    "raw_chars": .stringConvertible(rawChars),
                    "normalized_chars": .stringConvertible(normalizedChars),
                    "suppression_reason": .string(suppressionReason),
                    "latency_ms": .stringConvertible(latencyMs),
                    "max_tokens": .stringConvertible(request.maxPredictionTokens)
                ]) { _, new in new }
            )
            return SuggestionResult(
                generation: request.generation,
                rawText: rawSuggestion,
                text: normalizedSuggestion,
                latency: latency,
                suppressionReason: normalization.suppression?.rawValue
            )
        } catch is CancellationError {
            CotabbyLogger.suggestion.debug("Foundation model generation cancelled", metadata: baseMetadata)
            throw SuggestionClientError.cancelled
        } catch let error as LanguageModelSession.GenerationError {
            CotabbyLogger.suggestion.error(
                "Foundation model generation error: \(error.localizedDescription)",
                metadata: baseMetadata
            )
            throw mapGenerationError(error)
        } catch let error as SuggestionClientError {
            throw error
        } catch {
            CotabbyLogger.suggestion.error(
                "Foundation model unexpected error: \(error.localizedDescription)",
                metadata: baseMetadata
            )
            throw SuggestionClientError.generationFailed(error.localizedDescription)
        }
    }

    /// Best-effort warmup. Apple's prewarm loads weights into memory and primes the instruction
    /// prefix cache. We swallow errors because prewarming is opportunistic — the next
    /// `respond` call will surface real availability or generation failures with the right
    /// vocabulary, and reporting them here would just produce noise.
    func prewarm(for request: SuggestionRequest) async {
        availabilityService.refresh()
        guard availabilityService.isAvailable else {
            return
        }
        guard let model = availabilityService.systemLanguageModel else {
            return
        }

        do {
            let payload = try await preparedPayload(for: request, model: model)
            try Task.checkCancellation()
            let session = ensureSession(instructions: payload.instructions, model: model)
            session.prewarm()
            CotabbyLogger.suggestion.debug("Foundation model session prewarmed")
        } catch {
            // Prewarm is opportunistic, including a request whose fixed contract cannot fit. Never
            // construct an unbounded instruction session just because no response is requested yet.
            return
        }
    }

    /// Dropping the cached session forces the next request to rebuild instructions, which is the
    /// right behavior when the coordinator signals the editing context is no longer continuous
    /// (focus changes, settings edits). Apple's session also holds a transcript that we
    /// deliberately do not want to leak across editing contexts.
    func resetCachedGenerationContext() async {
        cachedSession = nil
    }

    /// Returns the cached session when it is safe to reuse, otherwise builds a fresh session
    /// and replaces the cache. The cache key (rendered instructions) keeps this correct if the
    /// renderer composition rules change later.
    ///
    /// Reuse is gated on three conditions that together avoid two Apple-surfaced failures the
    /// previous unconditional-reuse design was vulnerable to:
    ///
    /// - `cached.instructions == instructions`: the cached session was built with this exact
    ///   instruction string. Any settings edit (custom rules, language override) that re-renders
    ///   instructions forces a rebuild.
    /// - `!cached.session.isResponding`: Apple's `LanguageModelSession` rejects a second concurrent
    ///   `respond` / `streamResponse` with `.concurrentRequests`. Swift task cancellation is
    ///   cooperative, so the coordinator's `cancelPredictionWork()` + `schedulePrediction()` pair
    ///   can leave the previous stream still draining inside Apple's runtime when the next request
    ///   arrives. Falling through to a fresh session keeps that case from surfacing as a
    ///   user-visible `generationFailed` error.
    /// - `cached.session.transcript.count == cached.pristineTranscriptCount`: a successful (or even
    ///   cancelled) `respond` appends the prompt and response to the session's transcript. Reusing
    ///   the session indefinitely accumulates entries that all replay through the 4096-token
    ///   shared context, which Apple eventually surfaces as `.exceededContextWindowSize`. Bounded
    ///   reuse keeps the prewarm benefit on the first keystroke after focus — the session is
    ///   built and prewarmed on focus change, then consumed once — and any further keystroke in
    ///   the same field starts from a fresh session, matching the pre-PR single-turn behavior.
    ///
    /// The cache key intentionally omits `model` identity. `availabilityService` owns the singleton
    /// `SystemLanguageModel` and only swaps it on app restart, never mid-session — so a cached
    /// session can never be silently bound to a stale model. If that invariant ever changes
    /// (e.g. live Apple Intelligence asset reloads), include `ObjectIdentifier(model)` here.
    private func ensureSession(
        instructions: String,
        model: SystemLanguageModel
    ) -> LanguageModelSession {
        if let cached = cachedSession,
           cached.instructions == instructions,
           !cached.session.isResponding,
           cached.session.transcript.count == cached.pristineTranscriptCount {
            return cached.session
        }

        let session = LanguageModelSession(model: model, instructions: instructions)
        cachedSession = CachedSession(
            instructions: instructions,
            session: session,
            pristineTranscriptCount: session.transcript.count
        )
        return session
    }

    /// Apple counts both channels against one context. Count with the model's real tokenizer on
    /// 26.4+, and reserve response capacity plus framing even for a pristine session. Earlier OS
    /// versions expose no tokenizer: one UTF-8 byte per budget unit deliberately overestimates
    /// ordinary text and avoids the unsafe four-characters-per-token assumption for dense scripts.
    private func preparedPayload(for request: SuggestionRequest, model: SystemLanguageModel) async throws
        -> FoundationModelPromptRenderer.Payload {
        do {
            let preparationStart = Date()
            let window = contextSize(for: model)
            var tokenizerCalls = 0
            var byteBoundAttempts = 0
            #if compiler(>=6.3)
            var countedInstructions: (text: String, tokens: Int)?
            #endif
            let prepared = try await FoundationModelPromptRenderer.preparePayload(
                for: request, contextSize: window
            ) { payload in
                // The preparer validates this subtraction before calling the counter. A fitting
                // byte upper bound needs no async tokenizer work, so ordinary keystrokes retain
                // their previous latency. Larger pairs still use real counts before any trimming.
                let inputLimit = window - FoundationModelPromptRenderer.framingTokenReserve
                    - max(1, request.maxPredictionTokens)
                if payload.utf8Count <= inputLimit {
                    byteBoundAttempts += 1
                    return payload.utf8Count
                }
                // Xcode 26.4 introduced these declarations with Swift 6.3. An OS availability
                // check alone cannot compile an unknown symbol against an earlier SDK.
                #if compiler(>=6.3)
                if #available(macOS 26.4, *) {
                    let instructionTokens: Int
                    if let countedInstructions, countedInstructions.text == payload.instructions {
                        instructionTokens = countedInstructions.tokens
                    } else {
                        instructionTokens = try await model.tokenCount(for: Instructions(payload.instructions))
                        tokenizerCalls += 1
                        try Task.checkCancellation()
                        countedInstructions = (payload.instructions, instructionTokens)
                    }
                    let promptTokens = try await model.tokenCount(for: payload.prompt)
                    tokenizerCalls += 1
                    try Task.checkCancellation()
                    let (combined, overflow) = instructionTokens.addingReportingOverflow(promptTokens)
                    guard !overflow else { throw FoundationModelPromptRenderer.BudgetError.cannotFit }
                    return combined
                }
                #endif
                byteBoundAttempts += 1
                return payload.utf8Count
            }
            CotabbyLogger.suggestion.debug("Foundation model context prepared", metadata: [
                "request_id": .string(request.requestID),
                "engine": .string("apple_intelligence"),
                "input_measurement": .string(tokenizerCalls == 0 ? "utf8_upper_bound" : "apple_tokens"),
                "tokenizer_calls": .stringConvertible(tokenizerCalls),
                "byte_bound_attempts": .stringConvertible(byteBoundAttempts),
                "preparation_ms": .stringConvertible(Int(Date().timeIntervalSince(preparationStart) * 1000))
            ])
            return prepared
        } catch FoundationModelPromptRenderer.BudgetError.cannotFit {
            throw SuggestionClientError.generationFailed(
                "The Apple on-device context window cannot fit the autocomplete instructions and requested response."
            )
        }
    }

    private func contextSize(for model: SystemLanguageModel) -> Int {
        #if compiler(>=6.3)
        if #available(macOS 26.4, *) { return model.contextSize }
        #endif
        // Apple's original on-device model has a documented 4096-token window. Older SDKs
        // lack the back-deployed contextSize symbol, so pair that limit with byte budgeting.
        return 4096
    }

    /// Maps Cotabby's existing generation knobs onto the subset of Foundation Models options the
    /// system model exposes. We preserve the same upstream request shape so the coordinator does
    /// not fork behavior by backend.
    private func generationOptions(for request: SuggestionRequest) -> GenerationOptions {
        let sampling: GenerationOptions.SamplingMode

        if request.temperature <= 0.15 {
            sampling = .greedy
        } else {
            sampling = .random(top: max(request.topK, 1))
        }

        return GenerationOptions(
            sampling: sampling,
            temperature: request.temperature,
            maximumResponseTokens: max(request.maxPredictionTokens, 1)
        )
    }

    /// Converts framework-specific failures into Cotabby's existing error vocabulary so the rest of
    /// the pipeline can stay backend-agnostic.
    private func mapGenerationError(
        _ error: LanguageModelSession.GenerationError
    ) -> SuggestionClientError {
        switch error {
        case .assetsUnavailable:
            return .unavailable("Apple Intelligence assets are unavailable right now.")
        case .unsupportedLanguageOrLocale:
            return .unsupportedLanguageOrLocale(
                "Apple Intelligence does not support the current language or locale for this request."
            )
        case .exceededContextWindowSize:
            return .generationFailed("The Apple on-device model rejected the prompt because it was too large.")
        case .guardrailViolation:
            return .generationFailed("Apple Intelligence rejected this request because of model guardrails.")
        case .unsupportedGuide:
            return .generationFailed("Apple Intelligence rejected a guided-generation request Cotabby sent.")
        case .decodingFailure:
            return .generationFailed("Apple Intelligence returned a response Cotabby could not decode.")
        case .rateLimited:
            return .generationFailed("Apple Intelligence is temporarily rate limited.")
        case .concurrentRequests:
            return .generationFailed("Apple Intelligence rejected a concurrent request for this session.")
        case .refusal:
            return .generationFailed("Apple Intelligence refused to answer this prompt.")
        @unknown default:
            return .generationFailed(error.localizedDescription)
        }
    }

    private struct CachedSession {
        let instructions: String
        let session: LanguageModelSession
        /// Snapshot of `session.transcript.count` immediately after construction (and after any
        /// `prewarm()`, which does not modify the transcript). A respond call appends entries,
        /// so a count divergence is the cue that this session is no longer single-turn safe.
        let pristineTranscriptCount: Int
    }
}

@available(macOS 26.0, *)
extension FoundationModelSuggestionEngine: SuggestionGenerating {}
#endif
