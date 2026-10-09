import XCTest
@testable import Cotabby

/// Explicit vocabulary must retain the spelling the person chose without accepting hidden text or
/// silently turning a dictionary into instructions. These checks cover the pure validation boundary.
final class PersonalVocabularyTests: XCTestCase {
    func testCanonicalCaseDeduplicationPreservesFirstDisplaySpellingAndAccents() {
        XCTAssertEqual(PersonalVocabulary.normalize([" Élodie ", "e\u{301}LODIE", "résumé", "resume", "O’Neill"]),
                       ["Élodie", "résumé", "resume", "O’Neill"])
        XCTAssertTrue(PersonalVocabulary.contains("e\u{301}LODIE", in: ["Élodie"]))
        XCTAssertTrue(PersonalVocabulary.contains("STRASSE", in: ["Straße"]))
        XCTAssertFalse(PersonalVocabulary.contains("resume", in: ["résumé"]))
        XCTAssertEqual(PersonalVocabulary.normalize(["東京", "Δημήτρης", "Ольга", "Jean-Luc"]),
                       ["東京", "Δημήτρης", "Ольга", "Jean-Luc"])
    }

    func testRejectsMultipleWordsControlsAndOverlongEntries() {
        for invalid in ["", "two words", "one\ntwo", "word\n", "a\tb", "a\u{200B}b", "word1", "-word", "word-",
                        String(repeating: "é", count: PersonalVocabulary.maximumWordCharacters + 1)] {
            XCTAssertNil(PersonalVocabulary.normalizedWord(invalid), invalid)
        }
        let atLimit = String(repeating: "é", count: PersonalVocabulary.maximumWordCharacters)
        XCTAssertEqual(PersonalVocabulary.normalizedWord(atLimit), atLimit)
    }

    func testBoundsEntryCountWithoutDuplicatesConsumingSlots() {
        let words = (0..<250).map { "Word" + String(repeating: "a", count: $0 / 26) + String(UnicodeScalar(97 + $0 % 26)!) }
        let normalized = PersonalVocabulary.normalize(["Cotabby", "COTABBY"] + words)
        XCTAssertEqual(normalized.count, PersonalVocabulary.maximumEntries)
        XCTAssertEqual(normalized.first, "Cotabby")
        XCTAssertEqual(normalized, Array((["Cotabby"] + words).prefix(PersonalVocabulary.maximumEntries)))
    }

    func testVocabularyDoesNotEnterPromptsForAnyBackend() {
        let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Please send ")
        for engine in [SuggestionEngineKind.appleIntelligence, .llamaOpenSource, .openAICompatible] {
            let baseline = SuggestionRequestFactory.buildRequest(context: context,
                settings: CotabbyTestFixtures.settingsSnapshot(selectedEngine: engine), configuration: .standard)
            let personalized = SuggestionRequestFactory.buildRequest(context: context,
                settings: CotabbyTestFixtures.settingsSnapshot(selectedEngine: engine,
                    personalVocabularyWords: ["PrivateVocabularyMarker"]), configuration: .standard)
            // Request IDs intentionally differ on every factory call. Compare the rendered text
            // delivered to each backend, including Apple's separate instructions channel.
            XCTAssertEqual(personalized.promptPreview, baseline.promptPreview)
            XCTAssertEqual(personalized.request.prompt, baseline.request.prompt)
            XCTAssertEqual(FoundationModelPromptRenderer.prompt(for: personalized.request),
                           FoundationModelPromptRenderer.prompt(for: baseline.request))
            XCTAssertEqual(FoundationModelPromptRenderer.sessionInstructions(for: personalized.request),
                           FoundationModelPromptRenderer.sessionInstructions(for: baseline.request))
            XCTAssertFalse(personalized.request.prompt.contains("PrivateVocabularyMarker"))
        }
    }

    func testSavedWordsCompleteExactPrefixesAndAbstainWhenAmbiguous() {
        let words = Set(PersonalVocabulary.normalize(["Cotabby", "Élodie", "東京大学"]))
        XCTAssertEqual(WordCompletionFallback.suffix(for: "Cota", references: words, dictionaryCandidates: []), "bby")
        XCTAssertEqual(WordCompletionFallback.suffix(for: "e\u{301}lo", references: words, dictionaryCandidates: []), "die")
        XCTAssertEqual(WordCompletionFallback.suffix(for: "東京大", references: words, dictionaryCandidates: []), "学")
        XCTAssertEqual(WordCompletionFallback.suffix(for: "O’N", references: ["O’Neill"], dictionaryCandidates: []), "eill")
        XCTAssertEqual(WordCompletionFallback.suffix(for: "Jean-L", references: ["Jean-Luc"], dictionaryCandidates: []), "uc")
        XCTAssertNil(WordCompletionFallback.suffix(for: "Cota", references: ["Cotabby", "Cotangent"], dictionaryCandidates: []))
        XCTAssertNil(WordCompletionFallback.suffix(for: "Coty", references: words, dictionaryCandidates: []))
    }
}
