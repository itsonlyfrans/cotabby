@testable import Cotabby
import XCTest

final class TypingHistoryPhrasePredictorTests: XCTestCase {
    private let limits = TypingHistoryPhrasePredictor.Limits(maxWords: 12, allowsNewlines: false)

    private func record(_ text: String) -> TypingHistoryRecord {
        TypingHistoryRecord(
            id: UUID(), bundleIdentifier: "com.apple.mail", domain: nil,
            createdAt: Date(), updatedAt: Date(), text: text, source: .imported
        )
    }

    private func predictor(_ texts: [String]) -> TypingHistoryPhrasePredictor {
        TypingHistoryPhrasePredictor(records: texts.map(record))
    }

    func test_repeatedPhraseIsCompletedAfterAWordBoundary() {
        let history = Array(repeating: "Thanks again, please let me know if you have any questions.", count: 4)

        XCTAssertEqual(
            predictor(history).continuation(after: "Sure, please let me know ", limits: limits),
            "if you have any questions."
        )
    }

    func test_partialWordIsFinishedWithOnlyTheUntypedLetters() {
        let history = Array(repeating: "Thanks again, please let me know if you have any questions.", count: 4)

        XCTAssertEqual(
            predictor(history).continuation(after: "Sure, please let me know if you ha", limits: limits),
            "ve any questions."
        )
    }

    func test_fullyTypedWordWithoutSpaceGetsALeadingSpace() {
        let history = Array(repeating: "Thanks again, please let me know if you have any questions.", count: 4)

        XCTAssertEqual(
            predictor(history).continuation(after: "Sure, please let me know if", limits: limits),
            " you have any questions."
        )
    }

    func test_ambiguousContinuationIsNotOffered() {
        let history = [
            "please let me know if it works",
            "please let me know when it ships",
            "please let me know what you think",
            "please let me know how it goes"
        ]

        XCTAssertNil(predictor(history).continuation(after: "please let me know ", limits: limits))
    }

    func test_tooFewOccurrencesAreNotOffered() {
        let history = Array(repeating: "please let me know if you have any questions.", count: 2)

        XCTAssertNil(predictor(history).continuation(after: "please let me know ", limits: limits))
    }

    func test_singleWordShortcutNeedsStrongerEvidence() {
        let three = Array(repeating: "Thanks for the update.\nBest regards, Senad\nImperum", count: 3)
        let six = Array(repeating: "Thanks for the update.\nBest regards, Senad\nImperum", count: 6)

        XCTAssertNil(predictor(three).continuation(after: "Thanks!\nBest regards, ", limits: limits))
        XCTAssertEqual(predictor(six).continuation(after: "Thanks!\nBest regards, ", limits: limits), "Senad")
    }

    func test_newlineContinuesOnlyWhenMultiLineIsAllowed() {
        let history = Array(repeating: "Thanks for your time.\nKind regards,\nSenad Aruc\nImperum B.V.", count: 6)
        let multiLine = TypingHistoryPhrasePredictor.Limits(maxWords: 12, allowsNewlines: true)

        XCTAssertNil(predictor(history).continuation(after: "Thanks for your time.\nKind regards,", limits: limits))
        XCTAssertEqual(
            predictor(history).continuation(after: "Thanks for your time.\nKind regards,", limits: multiLine),
            "\nSenad Aruc\nImperum B.V."
        )
    }

    func test_outputUsesTheUsersSpellingAndRespectsTheWordLimit() {
        let history = Array(repeating: "we will start the imperum POC with the SOC team next Monday morning", count: 4)
        let twoWords = TypingHistoryPhrasePredictor.Limits(maxWords: 2, allowsNewlines: false)

        XCTAssertEqual(predictor(history).continuation(after: "Then we will start the ", limits: twoWords), "imperum POC")
    }

    func test_unrelatedLowercaseTokensCannotRewriteALearnedPhrase() {
        let learned = Array(repeating: "we will start the Imperum POC with the SOC team", count: 6)
        let history = learned + ["unrelated notes contain imperum poc and soc today"]

        XCTAssertEqual(
            predictor(history).continuation(after: "we will start the ", limits: limits),
            "Imperum POC with the SOC team"
        )
        XCTAssertEqual(
            predictor(history).continuation(after: "we will start the Im", limits: limits),
            "perum POC with the SOC team"
        )
    }

    func test_eachPhraseContextKeepsItsOwnLatestSpelling() {
        let uppercase = Array(repeating: "we will start the POC now", count: 6)
        let lowercase = Array(repeating: "please refer to the poc later", count: 6)
        let history = predictor(uppercase + lowercase)

        XCTAssertEqual(history.continuation(after: "we will start the ", limits: limits), "POC now")
        XCTAssertEqual(history.continuation(after: "please refer to the ", limits: limits), "poc later")
    }

    func test_samePhraseContextUsesItsOwnLatestSpelling() {
        let earlier = Array(repeating: "we will start the poc now", count: 6)
        let history = earlier + ["we will start the POC now", "unrelated mentions poc elsewhere"]

        XCTAssertEqual(predictor(history).continuation(after: "we will start the ", limits: limits), "POC now")
    }

    func test_twoWordFallbackRetainsContextSpelling() {
        let signoffs = (0..<6).map { "Topic number \($0) is done.\nKind regards,\nSenad" }
        let history = predictor(signoffs + ["unrelated mentions of senad occur here"])
        let multiLine = TypingHistoryPhrasePredictor.Limits(maxWords: 4, allowsNewlines: true)

        XCTAssertEqual(
            history.continuation(after: "Something new.\nKind regards,", limits: multiLine), "\nSenad"
        )
    }

    func test_contextSpellingStorageIsInternedRatherThanCopiedForEveryOccurrence() {
        let phrase = "we will start the Imperum POC with the SOC team"
        let texts = Array(repeating: phrase, count: 6)
            + Array(repeating: "unrelated mentions imperum poc soc", count: 6)
        let small = predictor(texts).spellingStorageComparison
        let repeated = predictor(Array(repeating: texts, count: 100).flatMap { $0 }).spellingStorageComparison

        XCTAssertEqual(small.previousBytes, repeated.previousBytes)
        XCTAssertEqual(small.currentBytes, repeated.currentBytes)
        XCTAssertEqual(small.extraSpellings, 3)
        XCTAssertEqual(
            small.currentBytes - small.previousBytes,
            small.transitions * MemoryLayout<Int32>.stride + small.extraSpellings * MemoryLayout<String>.stride
        )
    }

    func test_multiLineHistoryRespectsTheWordLimitWithoutRewritingTheSignature() {
        let history = Array(repeating: "Thanks for your time.\nKind regards,\nSenad Aruc\nImperum B.V.", count: 6)
        let twoWords = TypingHistoryPhrasePredictor.Limits(maxWords: 2, allowsNewlines: true)

        XCTAssertEqual(
            predictor(history).continuation(after: "Thanks for your time.\nKind regards,", limits: twoWords),
            "\nSenad Aruc"
        )
    }

    func test_alreadyTypedWordDoesNotConsumeTheContinuationWordBudget() {
        let history = Array(repeating: "please let me know if you have any questions.", count: 6)
        let twoWords = TypingHistoryPhrasePredictor.Limits(maxWords: 2, allowsNewlines: false)

        XCTAssertEqual(predictor(history).continuation(after: "please let me know if", limits: twoWords), " you have")
    }

    func test_alreadyTypedWordDoesNotBypassSingleWordConfidence() {
        let history = Array(repeating: "please let me know if it", count: 3)
        let oneWord = TypingHistoryPhrasePredictor.Limits(maxWords: 1, allowsNewlines: false)

        XCTAssertNil(predictor(history).continuation(after: "please let me know if", limits: oneWord))
    }

    func test_blankLinesCannotTeachANewlineOnlyCycle() {
        let text = "Thanks for your time.\nKind regards,\n\n \n\nSenad Aruc\n\nImperum B.V."
        // Consecutive line breaks collapse even across whitespace-only lines. Therefore a learned
        // newline always leads to a counted word, keeping traversal bounded by the word budget.
        XCTAssertEqual(
            TypingHistoryPhrasePredictor.tokens(in: "regards,\n\n \n\nSenad"),
            ["regards,", "\n", "Senad"]
        )
        let history = Array(repeating: text, count: 6)
        let multiLine = TypingHistoryPhrasePredictor.Limits(maxWords: 4, allowsNewlines: true)

        XCTAssertEqual(
            predictor(history).continuation(after: "Thanks for your time.\nKind regards,", limits: multiLine),
            "\nSenad Aruc\nImperum B.V."
        )
    }

    func test_twoWordFallbackAnswersWhenTheThirdWordIsNew() {
        // "Kind regards," follows many different sentences, so the three-word context before it is
        // rarely the same; the two-word fallback still knows what comes next.
        let history = (0..<6).map { "Topic number \($0) is done.\nKind regards,\nSenad" }
        let multiLine = TypingHistoryPhrasePredictor.Limits(maxWords: 12, allowsNewlines: true)

        XCTAssertEqual(
            predictor(history).continuation(after: "Something never seen before.\nKind regards,", limits: multiLine),
            "\nSenad"
        )
    }

    func test_onlyTextTypedBeforeTheCaretIsLearned() {
        // The quoted thread after the caret is someone else's writing; their name must not become
        // the user's sign-off.
        let records = (0..<6).map { _ -> TypingHistoryRecord in
            let typed = "Thanks for the update.\nBest regards, Senad"
            let quoted = "\n\nOn Monday Luuk wrote:\nThanks for the update.\nBest regards, Luuk"
            var record = record(typed + quoted)
            record.typedLength = typed.count
            return record
        }

        XCTAssertEqual(
            TypingHistoryPhrasePredictor(records: records).continuation(after: "Done.\nBest regards, ", limits: limits),
            "Senad"
        )
    }

    func test_unknownContextReturnsNil() {
        XCTAssertNil(predictor(["hello there general kenobi"]).continuation(after: "completely new words ", limits: limits))
        XCTAssertNil(predictor([]).continuation(after: "", limits: limits))
    }
}
