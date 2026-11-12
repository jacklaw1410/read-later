import Testing

@testable import ReadLaterCore

/// The paused-scrub contract (F19 1.3): the stash survives a failed start and
/// clears only on success. The session cannot be hosted here (SwiftUI +
/// AVFoundation), so the latch it must obey is tested instead.
@Test func peekDoesNotConsumeTheStash() {
    var latch = ResumeLatch()
    #expect(latch.peek() == nil)
    latch.stash(42)
    #expect(latch.peek() == 42)
    #expect(latch.peek() == 42)
}

@Test func failedStartKeepsTheStashForTheNextPress() {
    var latch = ResumeLatch()
    latch.stash(42)
    // The session peeks, attempts the start, and clears only on success.
    // A failure path that never calls clear() must leave the word behind.
    let started = false
    if started { latch.clear() }
    #expect(latch.peek() == 42)
}

@Test func successfulStartClearsTheStash() {
    var latch = ResumeLatch()
    latch.stash(42)
    let started = true
    if started { latch.clear() }
    #expect(latch.peek() == nil)
}

@Test func restashOverwritesThePreviousWord() {
    var latch = ResumeLatch()
    latch.stash(10)
    latch.stash(77)
    #expect(latch.peek() == 77)
}
