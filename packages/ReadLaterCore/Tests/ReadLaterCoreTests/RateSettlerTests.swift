import Testing

@testable import ReadLaterCore

/// One restart per gesture: bursts collapse to the last push, and a take
/// without a new push yields nothing.
@Test func burstCollapsesToTheLastPush() {
    var settler = RateSettler()
    settler.push(1.1)
    settler.push(1.2)
    settler.push(1.3)
    #expect(settler.takePending() == 1.3)
}

@Test func takeWithoutPushYieldsNothing() {
    var settler = RateSettler()
    #expect(settler.takePending() == nil)
    settler.push(1.2)
    _ = settler.takePending()
    #expect(settler.takePending() == nil)
}
