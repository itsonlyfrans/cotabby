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
        XCTAssertFalse(RecoveredFocusValidation.accepts(
            "field", isFocused: true, expectedWindow: "current",
            windowOf: { _ in nil }, parentOf: { $0 == "field" ? "renderer" : "current" },
            equal: ==, maximumDepth: 1
        ))
    }

    private func accepts(focused: Bool, windows: [String: String] = [:],
                         parents: [String: String] = [:]) -> Bool {
        RecoveredFocusValidation.accepts(
            "field", isFocused: focused, expectedWindow: "current",
            windowOf: { windows[$0] }, parentOf: { parents[$0] }, equal: ==
        )
    }
}
