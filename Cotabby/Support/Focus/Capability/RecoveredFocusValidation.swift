import Foundation

/// Validates a cursor-recovered field against the frontmost app's current focused window.
/// Mouse position is only a discovery hint: keyboard focus and window membership must agree
/// before the tracker may read text or send acceptance keystrokes. A bounded ancestry walk allows
/// renderer subprocess nodes without treating their process ID as the identity of the window.
nonisolated enum RecoveredFocusValidation {
    // Separate tree operations keep the policy testable without live AX objects.
    // swiftlint:disable:next function_parameter_count
    static func accepts<Node>(
        _ candidate: Node,
        isFocused: Bool,
        expectedWindow: Node,
        windowOf: (Node) -> Node?,
        parentOf: (Node) -> Node?,
        equal: (Node, Node) -> Bool,
        maximumDepth: Int = 24
    ) -> Bool {
        guard isFocused, maximumDepth >= 0 else { return false }
        var current = candidate
        for _ in 0...maximumDepth {
            if equal(current, expectedWindow) { return true }
            if let window = windowOf(current) { return equal(window, expectedWindow) }
            guard let parent = parentOf(current) else { return false }
            current = parent
        }
        // Missing, cyclic, or excessively deep ancestry provides no evidence of ownership.
        return false
    }
}
