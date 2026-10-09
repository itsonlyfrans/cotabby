import XCTest
@testable import Cotabby

final class RecoveredFocusValidationTests: XCTestCase {
    func testFocusedFieldInCurrentWindowIsAccepted() {
        XCTAssertTrue(accepts(focused: true, windows: ["field": "current"]))
    }

    func testMouseOverAnUnfocusedFieldDoesNotRecoverKeyboardFocus() {
        XCTAssertFalse(accepts(focused: false, windows: ["field": "current"]))
    }

    func testFocusedFieldFromAnotherWindowOrAppIsRejected() {
        XCTAssertFalse(accepts(focused: true, windows: ["field": "background"]))
        XCTAssertFalse(accepts(focused: true, parents: ["field": "other-app"]))
    }

    func testRendererSubtreeCanProveOwnershipThroughWindowAncestry() {
        XCTAssertTrue(accepts(focused: true, parents: ["field": "renderer", "renderer": "current"]))
    }

    func testMissingAndCyclicAncestryFailClosed() {
        XCTAssertFalse(accepts(focused: true))
        XCTAssertFalse(accepts(focused: true, parents: ["field": "renderer", "renderer": "field"]))
    }

    func testTraversalStopsAtConfiguredBound() {
        // Resolve the generic node and closure types before XCTest's assertion autoclosure.
        let windowOf: (String) -> String? = { _ in nil }
        let parentOf: (String) -> String? = { $0 == "field" ? "renderer" : "current" }
        let equal: (String, String) -> Bool = { $0 == $1 }
        let isAccepted: Bool = RecoveredFocusValidation.accepts(
            "field", isFocused: true, expectedWindow: "current",
            windowOf: windowOf, parentOf: parentOf,
            equal: equal, maximumDepth: 1
        )
        XCTAssertFalse(isAccepted)
    }

    private func accepts(focused: Bool, windows: [String: String] = [:],
                         parents: [String: String] = [:]) -> Bool {
        RecoveredFocusValidation.accepts(
            "field", isFocused: focused, expectedWindow: "current",
            windowOf: { windows[$0] }, parentOf: { parents[$0] }, equal: ==
        )
    }
}
