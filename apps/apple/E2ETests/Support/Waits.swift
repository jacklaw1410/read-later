import XCTest

/// One timeout constant. No `sleep`, no per-test timeout drift.
enum Waits {
    /// A screen change: launch, open, close.
    static let screen: TimeInterval = 20
    /// A state change inside a screen: wash movement, card, sheet.
    static let state: TimeInterval = 10
}
