import XCTest
@testable import Cotabby

/// Tests for the pure synthetic-key accounting behind `SuggestionInserter.replace`.
///
/// The accounting is what keeps the picker's own deletes from leaking back as user input: the
/// suppression window must cover exactly the keydowns we post. A single emoji is one keydown even
/// though it is two UTF-16 units (a surrogate pair), which is the subtle case these tests pin down.
final class SyntheticReplacePlannerTests: XCTestCase {

    func test_plan_countsBackspacesAndOneInsertKeyDown() {
        let plan = SyntheticReplacePlanner.plan(deletingUTF16Count: 6, text: "😀")

        XCTAssertEqual(plan.backspaceCount, 6)
        XCTAssertEqual(plan.insertUTF16, Array("😀".utf16))
        XCTAssertEqual(plan.insertUTF16.count, 2, "An emoji glyph is a surrogate pair, i.e. two UTF-16 units")
        XCTAssertEqual(plan.totalKeyDownCount, 7, "Six deletes plus one insertion keydown")
        XCTAssertFalse(plan.isNoop)
    }

    func test_textPlan_deletesDecomposedLetterOnceAndPreservesPrecedingText() {
        let deleted = "cafe\u{0301} "
        let plan = SyntheticReplacePlanner.plan(deletingText: deleted, text: "coffee ")

        XCTAssertEqual(plan.backspaceCount, 5)
        XCTAssertEqual(plan.totalKeyDownCount, 6)
        XCTAssertEqual(plan.insertUTF16, Array("coffee ".utf16))
        XCTAssertEqual(String(("Keep " + deleted).dropLast(plan.backspaceCount)), "Keep ")
        XCTAssertEqual(deleted.utf16.count, 6, "UTF-16 length must not become the Delete count")
    }

    func test_textPlan_deletesEachEmojiGraphemeOnce() {
        for deleted in ["😀", "👨‍👩‍👧‍👦", "👍🏽", "🇨🇦"] {
            let plan = SyntheticReplacePlanner.plan(deletingText: deleted, text: "x")
            XCTAssertEqual(plan.backspaceCount, 1, deleted)
            XCTAssertEqual(plan.totalKeyDownCount, 2, deleted)
            XCTAssertEqual(String(("Keep " + deleted).dropLast(plan.backspaceCount)), "Keep ", deleted)
            XCTAssertGreaterThan(deleted.utf16.count, plan.backspaceCount, deleted)
        }
    }

    func test_plan_emptyInsertCountsNoInsertionKeyDown() {
        let plan = SyntheticReplacePlanner.plan(deletingUTF16Count: 3, text: "")

        XCTAssertEqual(plan.backspaceCount, 3)
        XCTAssertTrue(plan.insertUTF16.isEmpty)
        XCTAssertEqual(plan.totalKeyDownCount, 3)
        XCTAssertFalse(plan.isNoop)
    }

    func test_plan_negativeDeleteCountClampsToZero() {
        let plan = SyntheticReplacePlanner.plan(deletingUTF16Count: -5, text: "x")

        XCTAssertEqual(plan.backspaceCount, 0)
        XCTAssertEqual(plan.totalKeyDownCount, 1)
    }

    func test_plan_noopWhenNothingToDeleteOrInsert() {
        let plan = SyntheticReplacePlanner.plan(deletingUTF16Count: 0, text: "")

        XCTAssertTrue(plan.isNoop)
        XCTAssertEqual(plan.totalKeyDownCount, 0)
    }

    func test_plan_stripsCarriageReturns() {
        let plan = SyntheticReplacePlanner.plan(deletingUTF16Count: 1, text: "a\rb")

        XCTAssertEqual(plan.insertUTF16, Array("ab".utf16))
    }
}
