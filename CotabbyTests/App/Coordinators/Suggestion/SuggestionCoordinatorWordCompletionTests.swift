import XCTest
@testable import Cotabby

/// Deterministic interaction replays exercise the production coordinator with synthetic focus
/// and engine boundaries. They cover what isolated model accuracy misses: correction eligibility,
/// transient bad ghosts, exact insertion, dismissal/cache reuse, and cancelled delayed display.
@MainActor
final class SuggestionCoordinatorWordCompletionTests: XCTestCase {
    func testUniquePersonalVocabularyPrefixWinsBeforeModelPartialsOrDispatch() async {
        for engine in [SuggestionEngineKind.appleIntelligence, .llamaOpenSource, .openAICompatible] {
            let rig = makeCoordinatorRig(
                snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "The codename is Quasarwic"),
                settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(selectedEngine: engine,
                    debounceMilliseconds: 1, streamSuggestionsWhileGenerating: true,
                    personalVocabularyWords: ["Quasarwick"]))
            defer { rig.coordinator.stop() }
            // The real bug ended the unknown capitalized fragment with punctuation; such output
            // passed the seam guard and never reached the previous final-result-only fallback.
            rig.engine.partialTexts = [", a"]
            rig.engine.resultProvider = { request in
                .init(generation: request.generation, rawText: ", a", text: ", a", latency: 0.01)
            }
            rig.coordinator.schedulePrediction()
            await waitUntil { rig.interactionState.activeSession != nil }
            XCTAssertEqual(rig.overlayController.shownTexts, ["k"])
            XCTAssertEqual(rig.interactionState.activeSession?.fullText, "k")
            XCTAssertTrue(rig.engine.requests.isEmpty, "A unique saved word needs no model dispatch")
            XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
            XCTAssertEqual(rig.inserter.insertedChunks, ["k"])
            XCTAssertTrue(rig.inserter.replacements.isEmpty)
        }
    }

    func testAmbiguousPersonalVocabularyPrefixStillUsesOrdinaryPrediction() async {
        let rig = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "The codename is Quasarwi"),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1,
                personalVocabularyWords: ["Quasarwick", "Quasarwind"]))
        defer { rig.coordinator.stop() }
        rig.engine.resultProvider = { request in
            .init(generation: request.generation, rawText: "nd", text: "nd", latency: 0.01)
        }
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.interactionState.activeSession != nil }
        XCTAssertEqual(rig.engine.requests.first?.prefixText, "The codename is Quasarwi")
        XCTAssertTrue(rig.interactionState.activeSession?.remainingText.hasPrefix("nd") == true)
    }

    func testPersonalVocabularyEndingCannotDuplicateTextAfterCaretEvenAsFinalFallback() async {
        let rig = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "North", trailingText: " wind"),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1,
                personalVocabularyWords: ["Northwind"]))
        defer { rig.coordinator.stop() }
        rig.engine.resultProvider = { request in
            .init(generation: request.generation, rawText: "", text: "", latency: 0.01)
        }
        let context = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        XCTAssertNil(rig.coordinator.personalVocabularyCompletion(context: context))
        XCTAssertNil(rig.coordinator.localWordCompletion(context: context))
        rig.coordinator.schedulePrediction()
        await waitUntil { !rig.engine.requests.isEmpty && rig.coordinator.state == .idle }
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertTrue(rig.overlayController.shownTexts.isEmpty)
        XCTAssertTrue(rig.inserter.insertedChunks.isEmpty)
    }

    func testAcceptingExplicitVocabularyDoesNotAlterModelQualityCountersOrLatency() async {
        let rig = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "The codename is Quasarwic"),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(selectedEngine: .openAICompatible,
                debounceMilliseconds: 1, personalVocabularyWords: ["Quasarwick"]))
        defer { rig.coordinator.stop() }
        let metrics = rig.coordinator.qualityMetricsStore
        metrics.recordGenerated()
        metrics.recordShown()
        metrics.recordAcceptedSuggestion()
        let baseline = metrics.counters
        rig.coordinator.lastLatencyByEngine[.openAICompatible] = 120
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.interactionState.activeSession != nil }
        XCTAssertEqual(rig.interactionState.activeSession?.countsTowardModelQuality, false)
        XCTAssertEqual(metrics.counters, baseline)
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        rig.coordinator.stop()
        await waitUntil { rig.coordinator.totalTabAcceptedWordCount > 0 }
        XCTAssertEqual(rig.inserter.insertedChunks, ["k"])
        XCTAssertEqual(metrics.counters, baseline, "Explicit local acceptance is not a generated-model acceptance")
        XCTAssertEqual(metrics.counters.acceptanceRate, 1)
        XCTAssertEqual(rig.coordinator.lastLatencyByEngine[.openAICompatible], 120)
    }

    func testVocabularyBecomingAmbiguousCannotRestoreOldLocalEndingFromCache() async {
        let rig = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "The codename is Quasarwi"),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1,
                personalVocabularyWords: ["Quasarwick"]))
        defer { rig.coordinator.stop() }
        rig.engine.resultProvider = { request in
            .init(generation: request.generation, rawText: "", text: "", latency: 0.01)
        }
        let context = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.interactionState.activeSession?.remainingText == "ck" }
        XCTAssertTrue(rig.engine.requests.isEmpty)
        XCTAssertNil(rig.coordinator.suggestionAnchorCache.remainder(
            identityKey: context.suggestionSessionIdentityKey, precedingText: context.precedingText))

        // Invalidating a session is a second cache-writing path, independent of the initial offer.
        rig.coordinator.invalidateActiveSuggestion(reason: "Synthetic focus interruption")
        XCTAssertNil(rig.coordinator.suggestionAnchorCache.remainder(
            identityKey: context.suggestionSessionIdentityKey, precedingText: context.precedingText))
        rig.coordinator.handleSuggestionSettingsChange(CotabbyTestFixtures.settingsSnapshot(
            debounceMilliseconds: 1, personalVocabularyWords: ["Quasarwick", "Quasarwind"]))
        await waitUntil { !rig.engine.requests.isEmpty && rig.coordinator.state == .idle }
        XCTAssertEqual(rig.engine.requests.first?.prefixText, "The codename is Quasarwi")
        XCTAssertEqual(rig.overlayController.shownTexts, ["ck"], "The old local offer must not reappear after ambiguity")
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertEqual(rig.coordinator.qualityMetricsStore.counters.shown, 0)
        XCTAssertEqual(rig.coordinator.qualityMetricsStore.counters.acceptedSuggestions, 0)
        XCTAssertNil(rig.coordinator.qualityMetricsStore.counters.acceptanceRate)
    }

    func testLateOldEngineResultCannotReplaceDeterministicVocabularyEnding() async {
        let rig = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "The codename is "),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1,
                personalVocabularyWords: ["Quasarwick"]))
        defer { rig.coordinator.stop() }
        var previousRequest: SuggestionRequest?
        var previousCompletion: CheckedContinuation<SuggestionResult, Never>?
        rig.engine.resultProvider = { request in
            previousRequest = request
            return await withCheckedContinuation { previousCompletion = $0 }
        }
        rig.coordinator.schedulePrediction()
        await waitUntil { previousCompletion != nil }
        publishText("The codename is Quasarwic", in: rig)
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.interactionState.activeSession?.remainingText == "k" }
        if let previousRequest {
            previousCompletion?.resume(returning: .init(generation: previousRequest.generation,
                rawText: ", a", text: ", a", latency: 0.01))
        }
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(rig.overlayController.shownTexts, ["k"])
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "k")
        XCTAssertEqual(rig.engine.requests.count, 1, "Only the earlier word-boundary request reached the engine")
    }

    func testPersonalVocabularyProtectsCommittedNameAndBufferedWord() async {
        let rig = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Contact Recieve "),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1,
                suppressCompletionsOnTypo: true, offerTypoCorrections: true, automaticallyFixTypos: true,
                personalVocabularyWords: ["Recieve"]))
        defer { rig.coordinator.stop() }
        rig.coordinator.symSpellCorrector.loadForTesting(contents: "receive 100\n")
        rig.engine.resultProvider = { request in
            .init(generation: request.generation, rawText: "tomorrow", text: "tomorrow", latency: 0.01)
        }
        rig.coordinator.schedulePrediction()
        await waitUntil { !rig.engine.requests.isEmpty }
        XCTAssertTrue(rig.inserter.replacements.isEmpty, "A saved name followed by Space must not be corrected")
        XCTAssertEqual(rig.coordinator.completionSpellingAssessment(for: "RECIEVE"), .known)
        XCTAssertEqual(rig.engine.requests.first?.prefixText, "Contact Recieve ")
        let context = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        XCTAssertEqual(rig.coordinator.bufferedCompletionText("tomorrow Recieve", visibleText: "tomorrow",
            context: context, isFinal: true), "tomorrow Recieve")
    }

    func testPersonalVocabularyCompletesWithoutSendingSavedWordsAsContext() {
        let rig = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Contact Cota"),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(personalVocabularyWords: ["Cotabby"]))
        defer { rig.coordinator.stop() }
        let context = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        XCTAssertEqual(rig.coordinator.localWordCompletion(context: context), "bby")
        XCTAssertEqual(rig.coordinator.completionReferenceWords(context: context), ["Contact", "Cotabby"])
        XCTAssertTrue(rig.engine.requests.isEmpty, "Exact local word completion does not invoke a model")
    }

    func testExplicitVocabularyCompletesUnspacedScriptsWithoutBroadeningDictionaryPolicy() {
        for (prefix, word, suffix) in [("東京大", "東京大学", "学"), ("대한민", "대한민국", "국"),
                                       ("ประชา", "ประชาชน", "ชน")] {
            let rig = makeCoordinatorRig(
                snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: prefix),
                settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(personalVocabularyWords: [word]))
            let context = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
            XCTAssertEqual(rig.coordinator.localWordCompletion(context: context), suffix)
            XCTAssertTrue(rig.engine.requests.isEmpty)
            XCTAssertNil(CaretWordContext.unfinishedWord(in: prefix), "Ordinary spelling policy remains unchanged")
            rig.coordinator.stop()
        }
        let ambiguous = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "東京大"),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(personalVocabularyWords: ["東京大学", "東京大学院"]))
        defer { ambiguous.coordinator.stop() }
        let context = ambiguous.interactionState.materializeContext(from: ambiguous.focusProvider.snapshot.context!)
        XCTAssertNil(ambiguous.coordinator.localWordCompletion(context: context))
        let insideToken = CotabbyTestFixtures.focusedInputContext(precedingText: "東京大", trailingText: "学")
        XCTAssertNil(ambiguous.coordinator.localWordCompletion(context: insideToken))
    }

    func testOtherTyposStillCorrectWithPersonalVocabularyConfigured() async {
        let rig = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please recieve "),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1,
                suppressCompletionsOnTypo: true, automaticallyFixTypos: true, personalVocabularyWords: ["Cotabby"]))
        defer { rig.coordinator.stop() }
        rig.coordinator.symSpellCorrector.loadForTesting(contents: "receive 100\n")
        rig.coordinator.schedulePrediction()
        await waitUntil { !rig.inserter.replacements.isEmpty }
        XCTAssertEqual(rig.inserter.replacements.map(\.text), ["receive "])
    }

    func testMissingSpacePredictionAppearsAndAcceptsWithoutAnotherGeneration() async {
        for streaming in [false, true] {
            let rig = makeCoordinatorRig(
                snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "predictions come up"),
                settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
                    debounceMilliseconds: 1, streamSuggestionsWhileGenerating: streaming))
            defer { rig.coordinator.stop() }
            rig.engine.partialTexts = streaming ? ["and it takes time "] : []
            rig.engine.resultProvider = { request in
                .init(generation: request.generation, rawText: "and it takes time",
                      text: "and it takes time", latency: 0.01)
            }
            rig.coordinator.schedulePrediction()
            await waitUntil { if case .ready = rig.coordinator.state { return true }; return false }
            XCTAssertEqual(rig.interactionState.activeSession?.fullText, " and it takes time")
            XCTAssertTrue(rig.overlayController.shownTexts.allSatisfy { $0.hasPrefix(" and") })
            XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
            XCTAssertEqual(rig.inserter.insertedChunks, [" and"])
            XCTAssertEqual(rig.interactionState.activeSession?.remainingText, " it takes time")
            XCTAssertEqual(rig.engine.requests.count, 1)
        }
    }

    func testPausingAfterEveryLetterCompletesWithoutReplacingTypedText() async {
        for word in ["because", "schedule", "recommend"] {
            for count in 1..<word.count {
                let prefix = String(word.prefix(count))
                let rig = makeCoordinatorRig(
                    snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please " + prefix),
                    settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1,
                        suppressCompletionsOnTypo: true, offerTypoCorrections: true))
                let suffix = String(word.dropFirst(count))
                rig.engine.resultProvider = { request in
                    let text = request.prefixText.hasSuffix(" ") ? "" : suffix
                    return .init(generation: request.generation, rawText: text, text: text, latency: 0.01)
                }
                rig.coordinator.schedulePrediction()
                await waitUntil("No word completion for \(prefix)") { rig.interactionState.activeSession != nil }
                XCTAssertEqual(rig.engine.requests.filter { $0.prefixText == "Please " + prefix }.count, 1, prefix)
                XCTAssertTrue(rig.engine.requests.dropFirst().allSatisfy { $0.prefixText == "Please " + word + " " })
                XCTAssertEqual(rig.interactionState.activeSession?.kind, .continuation, prefix)
                XCTAssertEqual(rig.interactionState.activeSession?.remainingText, suffix, prefix)
                XCTAssertTrue(rig.inserter.replacements.isEmpty, prefix)
                rig.coordinator.stop()
            }
        }
    }

    func testMalformedStreamNeverAppearsAndLocalFallbackAcceptsOnlyMissingLetters() async {
        let rig = makeCoordinatorRig(snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please schedu"),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1, streamSuggestionsWhileGenerating: true))
        defer { rig.coordinator.stop() }
        rig.coordinator.symSpellCorrector.loadForTesting(contents: "schedule 100\nscheduled 5\n")
        rig.engine.partialTexts = [" schedule", " schedule a meeting"]
        rig.engine.resultProvider = { request in
            let text = request.prefixText == "Please schedule " ? "a meeting" : " schedule a meeting"
            return .init(generation: request.generation, rawText: text, text: text, latency: 0.01)
        }
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.interactionState.activeSession != nil }
        XCTAssertEqual(rig.overlayController.shownTexts, ["le"])
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertEqual(rig.inserter.insertedChunks, ["le"])
        XCTAssertTrue(rig.inserter.replacements.isEmpty)
    }

    func testDismissedSuggestionDoesNotReturnFromCacheOrRegeneration() async {
        let rig = makeCoordinatorRig()
        defer { rig.coordinator.stop() }
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.interactionState.activeSession != nil }
        _ = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .dismissal))
        XCTAssertNil(rig.interactionState.activeSession)
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.engine.requests.count == 2 && rig.coordinator.state == .idle }
        XCTAssertEqual(rig.overlayController.shownTexts, [" world"])
    }

    func testShortPrefixKeepsFollowingWordsAfterAcceptingWordEnding() async {
        let rig = makeCoordinatorRig(snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "I want to b"))
        defer { rig.coordinator.stop() }
        rig.engine.resultProvider = { request in
            .init(generation: request.generation, rawText: "uild a spaceship", text: "uild a spaceship", latency: 0.01)
        }
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.interactionState.activeSession != nil }
        XCTAssertEqual(rig.interactionState.activeSession?.fullText, "uild a spaceship")
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertEqual(rig.inserter.insertedChunks, ["uild"])
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, " a spaceship")
        XCTAssertEqual(rig.engine.requests.count, 1, "The following words were already generated.")
    }

    func testBoundaryPreferenceWaitsThenGeneratesAfterSpace() async {
        let rig = makeCoordinatorRig(snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello"),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1, suggestWithinWords: false))
        defer { rig.coordinator.stop() }
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.coordinator.state == .idle }
        XCTAssertTrue(rig.engine.requests.isEmpty)
        XCTAssertTrue(rig.overlayController.shownTexts.isEmpty)

        publishText("Hello ", in: rig)
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.interactionState.activeSession != nil }
        XCTAssertEqual(rig.engine.requests.map(\.prefixText), ["Hello "])
    }

    func testBoundaryPreferencePreservesVisibleTailThroughTypingAndRefresh() async {
        let rig = makeCoordinatorRig(snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello "),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1, suggestWithinWords: false))
        defer { rig.coordinator.stop() }
        let context = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        _ = rig.interactionState.startSession(fullText: "world again", liveContext: context, latency: 0.01)
        rig.overlayController.showSuggestion("world again", geometry: CotabbyTestFixtures.overlayGeometry())

        _ = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .textMutation, characters: "w"))
        publishText("Hello w", in: rig)
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.coordinator.state == .ready(text: "orld again", latency: 0.01) }
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "orld again")
        XCTAssertTrue(rig.engine.requests.isEmpty)
    }

    func testAcceptedCorrectionWaitsForPublishedTextAndQueuesNextTab() async {
        let rig = makeCoordinatorRig(snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please recieve "),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1,
                suggestWithinWords: false, suppressCompletionsOnTypo: true, offerTypoCorrections: true))
        defer { rig.coordinator.stop() }
        let context = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        _ = rig.interactionState.startSession(fullText: "receive", liveContext: context, latency: 0,
            kind: .correction(typoWord: "recieve"))
        rig.overlayController.showSuggestion("receive", geometry: CotabbyTestFixtures.overlayGeometry())
        rig.engine.resultProvider = { request in
            .init(generation: request.generation, rawText: "the package", text: "the package", latency: 0.01)
        }

        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertEqual(rig.inserter.replacements.map(\.text), ["receive "])
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion(), "Rapid Tab should wait for the continuation.")
        await waitUntil { rig.focusProvider.refreshCount > 0 }
        XCTAssertTrue(rig.engine.requests.allSatisfy { $0.prefixText == "Please receive " },
            "Lookahead must use the corrected word, never stale pre-replacement AX.")
        XCTAssertNil(rig.interactionState.activeSession)

        publishText("Please receive ", in: rig)
        await waitUntil { !rig.inserter.insertedChunks.isEmpty }
        XCTAssertEqual(rig.engine.requests.map(\.prefixText), ["Please receive "])
        XCTAssertEqual(rig.inserter.insertedChunks, ["the"])
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, " package")
    }

    func testAXWrapperChurnCannotReapplyAnUnpublishedAutomaticCorrection() async {
        // The endpoint engine prepares no continuation, so only the publication poll guards this edit.
        let rig = makeCoordinatorRig(snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please recieve "),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(selectedEngine: .openAICompatible,
                debounceMilliseconds: 1, suppressCompletionsOnTypo: true, automaticallyFixTypos: true))
        defer { rig.coordinator.stop() }
        rig.coordinator.symSpellCorrector.loadForTesting(contents: "receive 100\n")
        rig.coordinator.schedulePrediction()
        await waitUntil { !rig.inserter.replacements.isEmpty }
        XCTAssertNil(rig.coordinator.preparedContinuation)

        // Chromium can recycle the AX wrapper before the replacement publishes. The stale typo is
        // the same edit, so it must not authorize a second replacement ("word " -> "wword ").
        let churned = CotabbyTestFixtures.focusedInputSnapshot(elementIdentifier: "recycled-ax-token",
                                                               precedingText: "Please recieve ")
        rig.focusProvider.snapshot = FocusSnapshot(applicationName: churned.applicationName,
            bundleIdentifier: churned.bundleIdentifier, capability: .supported, context: churned)
        // Outlast the endpoint's debounce, but stay inside the 400 ms publication ceiling so the
        // real publish below is still observed.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(rig.inserter.replacements.count, 1)

        publishText("Please receive ", in: rig)
        await waitUntil { !rig.engine.requests.isEmpty }
        XCTAssertEqual(rig.engine.requests.map(\.prefixText), ["Please receive "])
        XCTAssertEqual(rig.inserter.replacements.count, 1)
    }

    func testTypingAfterAHeldTabKeepsItFromAcceptingTheNextSuggestion() async {
        let rig = makeCoordinatorRig(snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please recieve "),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1,
                suppressCompletionsOnTypo: true, offerTypoCorrections: true))
        defer { rig.coordinator.stop() }
        let context = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        _ = rig.interactionState.startSession(fullText: "receive", liveContext: context, latency: 0,
            kind: .correction(typoWord: "recieve"))
        rig.overlayController.showSuggestion("receive", geometry: CotabbyTestFixtures.overlayGeometry())
        rig.engine.resultProvider = { request in
            let text = request.prefixText.hasSuffix("I") ? " love the package" : "the package"
            return .init(generation: request.generation, rawText: text, text: text, latency: 0.01)
        }

        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion(), "Rapid Tab is held while the continuation regenerates.")
        XCTAssertTrue(rig.coordinator.postExhaustionAcceptanceState.hasQueuedAccept)

        // The user starts the next word before anything new appears. The held Tab answered the
        // earlier text, so the suggestion for this new text must wait for its own acceptance.
        _ = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .textMutation, characters: "I"))
        XCTAssertFalse(rig.coordinator.postExhaustionAcceptanceState.isArmed)
        publishText("Please receive I", in: rig)
        await waitUntil { rig.interactionState.activeSession != nil }
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, " love the package")
        XCTAssertTrue(rig.inserter.insertedChunks.isEmpty, "A suggestion the user never saw must not be accepted")
    }

    func testFinalAcceptPredictsFromActualInsertedTrailingSpace() async {
        let rig = makeCoordinatorRig(settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
            suggestWithinWords: false, addSpaceAfterAccept: true))
        defer { rig.coordinator.stop() }
        let context = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        _ = rig.interactionState.startSession(fullText: " world", liveContext: context, latency: 0.01)
        rig.overlayController.showSuggestion(" world", geometry: CotabbyTestFixtures.overlayGeometry())

        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertEqual(rig.inserter.insertedChunks, [" world "])
        let expected = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello world ")
        XCTAssertEqual(rig.coordinator.pendingSpeculativeContext?.contentSignature, expected.contentSignature)
        await waitUntil { !rig.engine.requests.isEmpty }
        XCTAssertEqual(rig.engine.requests.first?.prefixText, "Hello world ")
    }

    func testBoundaryPreferenceDoesNotCaptureNextTabWhenFinalAcceptAddsNoSpace() {
        let rig = makeCoordinatorRig(settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(suggestWithinWords: false))
        defer { rig.coordinator.stop() }
        let context = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        _ = rig.interactionState.startSession(fullText: " world", liveContext: context, latency: 0.01)
        rig.overlayController.showSuggestion(" world", geometry: CotabbyTestFixtures.overlayGeometry())
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertEqual(rig.inserter.insertedChunks, [" world"])
        XCTAssertNil(rig.coordinator.pendingSpeculativeContext)
        XCTAssertFalse(rig.coordinator.postExhaustionAcceptanceState.isArmed)
        XCTAssertFalse(rig.coordinator.acceptCurrentSuggestion())
    }

    func testCorrectionTimeoutNeverReoffersOrRepeatsAnUnpublishedReplacement() async {
        for automatic in [false, true] {
            let rig = makeCoordinatorRig(snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please recieve "),
                settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1,
                    suppressCompletionsOnTypo: true, offerTypoCorrections: true, automaticallyFixTypos: automatic))
            rig.coordinator.schedulePrediction()
            if automatic {
                await waitUntil { !rig.inserter.replacements.isEmpty }
            } else {
                await waitUntil { rig.interactionState.activeSession?.kind.isCorrection == true }
                XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
                XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
            }
            // Keep AX frozen beyond its 400 ms publication ceiling. Neither manual nor automatic
            // correction may interpret this old word as permission to replace it a second time.
            try? await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(rig.inserter.replacements.count, 1)
            XCTAssertNil(rig.interactionState.activeSession)
            XCTAssertEqual(rig.engine.requests.map(\.prefixText), ["Please receive "])
            XCTAssertFalse(rig.coordinator.postExhaustionAcceptanceState.isArmed)
            rig.coordinator.stop()
        }
    }

    func testCancellationDuringTypingPausePreventsLatePresentation() async {
        let rig = makeCoordinatorRig(snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please schedu"))
        defer { rig.coordinator.stop() }
        let context = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        rig.coordinator.typingCadence.record(identityKey: context.focusedInputIdentityKey, characters: "u",
                                            at: ProcessInfo.processInfo.systemUptime)
        let workID = rig.coordinator.currentWorkID
        let task = Task { await rig.coordinator.apply(result: .init(generation: context.generation,
            rawText: "le", text: "le", latency: 0.01), workID: workID) }
        await Task.yield()
        rig.coordinator.cancelPredictionWork()
        await task.value
        XCTAssertTrue(rig.overlayController.shownTexts.isEmpty)
        XCTAssertNil(rig.interactionState.activeSession)
    }

    private func publishText(_ text: String, in rig: CoordinatorRig) {
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: text)
        rig.focusProvider.snapshot = FocusSnapshot(applicationName: snapshot.applicationName,
            bundleIdentifier: snapshot.bundleIdentifier, capability: .supported, context: snapshot)
    }
}
