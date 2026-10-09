import Foundation

/// Adapts pure word/presentation policies to the app's spell checker, local dictionary, and live
/// work identity. Keeping this at the orchestration boundary avoids giving pure rules access to
/// AppKit or user settings, and keeps the prediction lifecycle readable.
extension SuggestionCoordinator {
    /// Keeps prediction separate from its first visible offer. An uncertain word ending can be
    /// shown conservatively while its following words stay buffered. Validate their first word
    /// independently: the seam check that approved a name ending did not approve `teh` after it.
    func bufferedCompletionText(_ prediction: String, visibleText: String,
                                context: FocusedInputContext, isFinal: Bool) -> String {
        var buffered = visibleText
        if prediction.hasPrefix(visibleText), prediction.count > visibleText.count {
            let following = String(prediction.dropFirst(visibleText.count))
            if case .show = CompletionSeamGuard.presentation(
                precedingText: context.precedingText + visibleText + " ", completion: following,
                isFinal: isFinal, spellingAssessment: { self.completionSpellingAssessment(for: $0) }
            ) { buffered = prediction }
        }
        if !isFinal {
            let visibleCount = settingsSnapshot.showFollowingWords ? visibleText.count
                : SuggestionSessionReconciler.nextAcceptanceChunk(from: visibleText).count
            buffered = StreamedGhostTextPolicy.completedBufferedPrediction(buffered, visibleCharacterCount: visibleCount)
        }
        return buffered
    }

    func startCompletionSession(prediction: String, visibleText: String, context: FocusedInputContext,
                                latency: TimeInterval, isFinal: Bool, wordEndingOnly: Bool = false,
                                countsTowardModelQuality: Bool = true) -> ActiveSuggestionSession {
        let fullText = bufferedCompletionText(prediction, visibleText: visibleText, context: context, isFinal: isFinal)
        return interactionState.startSession(fullText: fullText,
            initialVisibleCharacterCount: wordEndingOnly || fullText != visibleText ? visibleText.count : nil,
            showFollowingWords: settingsSnapshot.showFollowingWords, liveContext: context, latency: latency,
            countsTowardModelQuality: countsTowardModelQuality)
    }

    func completionPresentation(
        text: String, context: FocusedInputContext, isFinal: Bool
    ) -> CompletionSeamGuard.PresentationDecision {
        let references = completionReferenceWords(context: context)
        let knownReferences = Set(references.map { $0.lowercased() })
        return CompletionSeamGuard.presentation(
            precedingText: context.precedingText, completion: text, isFinal: isFinal,
            spellingAssessment: { word in
                if knownReferences.contains(word.lowercased()) { return .known }
                if let cached = self.suggestionStreamingState.spellingAssessments[word] { return cached }
                let assessment = self.completionSpellingAssessment(for: word)
                self.suggestionStreamingState.spellingAssessments[word] = assessment
                return assessment
            }
        )
    }

    func completionReferenceWords(context: FocusedInputContext) -> Set<String> {
        WordCompletionFallback.referenceWords(precedingText: context.precedingText,
                                             trailingText: context.trailingText,
                                             glossary: settingsSnapshot.extendedContext)
            .union(settingsSnapshot.personalVocabularyWords)
    }

    /// Explicit vocabulary has higher authority than generated or cached text at an unfinished
    /// word. The shared fallback still withholds ambiguous matches, including document references.
    func personalVocabularyCompletion(context: FocusedInputContext) -> String? {
        guard !CaretTokenPosition.isInsideToken(precedingText: context.precedingText,
                                               trailingText: context.trailingText),
              let prefix = PersonalVocabulary.unfinishedWord(in: context.precedingText),
              let savedSuffix = WordCompletionFallback.suffix(for: prefix,
                  references: Set(settingsSnapshot.personalVocabularyWords), dictionaryCandidates: []),
              WordCompletionFallback.suffix(for: prefix, references: completionReferenceWords(context: context),
                  dictionaryCandidates: []) == savedSuffix,
              !TrailingDuplicationFilter.duplicatesTrailingText(savedSuffix, trailingText: context.trailingText) else { return nil }
        return savedSuffix
    }

    /// Called synchronously after the normal focus, host-composition, availability and typo gates.
    /// No engine request means no model latency or quality event is fabricated for this local offer.
    /// `schedulePrediction` already retired earlier work, fencing any late engine callback out.
    func presentPersonalVocabularyCompletion(context: FocusedInputContext, workID: UInt64) -> Bool {
        guard workController.isCurrent(workID), context.selection.length == 0, !context.isSecure,
              let suffix = personalVocabularyCompletion(context: context) else { return false }
        if let accepted = lastAcceptedTail,
           SuggestionSessionReconciler.isStaleAcceptanceEcho(resultText: suffix, acceptedChunk: accepted.text,
               currentPrecedingText: context.precedingText, acceptedPrecedingText: accepted.precedingText) {
            lastAcceptedTail = nil
            clearSuggestion()
            hideOverlay(reason: "Overlay hidden while the host publishes the accepted vocabulary word.")
            state = .idle
            return true
        }
        guard !wasDismissed(suffix, context: context) else {
            clearSuggestion()
            hideOverlay(reason: "Overlay hidden because this vocabulary completion was explicitly dismissed.")
            state = .idle
            return true
        }
        lastAcceptedTail = nil
        latestGenerationNumber = context.generation
        let session = startCompletionSession(prediction: suffix, visibleText: suffix, context: context,
            latency: 0, isFinal: true, wordEndingOnly: true, countsTowardModelQuality: false)
        // The string-only cache cannot retain local provenance or re-evaluate vocabulary
        // ambiguity. Recompute explicit words from live settings instead of remembering them.
        hasPrefetchedContinuation = false
        state = .ready(text: session.remainingText, latency: 0)
        presentOverlay(text: session.remainingText, at: context.caretRect, context: context,
            isRightToLeft: TextDirectionDetector.isRightToLeft(context.precedingText))
        logStage("personal-vocabulary-ready", workID: workID, generation: context.generation,
            message: "Offered an explicit local vocabulary ending before model generation.", normalizedOutput: suffix)
        flushQueuedPostExhaustionAcceptIfNeeded()
        return true
    }

    /// A final unusable model result may fall back to a single exact-prefix word ending. This
    /// remains entirely local even for the endpoint backend and never invokes another generation.
    func localWordCompletion(context: FocusedInputContext) -> String? {
        guard !CaretTokenPosition.isInsideToken(precedingText: context.precedingText,
                                               trailingText: context.trailingText) else { return nil }
        guard let prefix = CaretWordContext.unfinishedWord(in: context.precedingText) else {
            // Ordinary dictionary policy excludes unspaced scripts. An explicit saved word can
            // still supply a safe exact ending without changing spelling-language detection or
            // treating arbitrary document text as a new dictionary for those scripts.
            guard let prefix = PersonalVocabulary.unfinishedWord(in: context.precedingText) else { return nil }
            return withoutTrailingDuplication(WordCompletionFallback.suffix(for: prefix,
                references: Set(settingsSnapshot.personalVocabularyWords), dictionaryCandidates: []), context: context)
        }
        let languages = SpellingDictionaryCatalog.languages(for: settingsSnapshot.enabledSpellingDictionaryCodes)
        let language = spellingLanguageResolver.resolve(precedingText: context.precedingText,
                                                       currentWord: prefix, enabledLanguages: languages)
        let candidates = language.map { symSpellCorrector.completionCandidates(for: prefix, language: $0) } ?? []
        return withoutTrailingDuplication(WordCompletionFallback.suffix(for: prefix,
            references: completionReferenceWords(context: context), dictionaryCandidates: candidates), context: context)
    }

    /// Final local fallback needs the same downstream-text check as the early saved-word offer;
    /// otherwise an empty model result could reintroduce an ending rejected before dispatch.
    private func withoutTrailingDuplication(_ suffix: String?, context: FocusedInputContext) -> String? {
        guard let suffix, !TrailingDuplicationFilter.duplicatesTrailingText(suffix, trailingText: context.trailingText)
        else { return nil }
        return suffix
    }

    func wasDismissed(_ text: String, context: FocusedInputContext) -> Bool {
        dismissalMemory.suppresses(identityKey: context.suggestionSessionIdentityKey,
                                  precedingText: context.precedingText, trailingText: context.trailingText,
                                  completion: text, at: ProcessInfo.processInfo.systemUptime)
    }

    func presentationDelay(context: FocusedInputContext) -> TimeInterval {
        typingCadence.remainingDelay(identityKey: context.focusedInputIdentityKey,
                                     precedingText: context.precedingText, at: ProcessInfo.processInfo.systemUptime)
    }

    /// Await inside the existing generation task so cancellation remains owned by the work
    /// controller. The caller must re-read focus and validate again after this suspension.
    func waitForTypingPause(workID: UInt64) async -> Bool {
        if let raw = focusModel.snapshot.context {
            let context = interactionState.materializeContext(from: raw)
            let delay = presentationDelay(context: context)
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return false }
            }
        }
        return !Task.isCancelled && workController.isCurrent(workID)
    }
}
