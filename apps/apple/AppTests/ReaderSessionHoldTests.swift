import ReadLaterCore
import ReadLaterUI
import XCTest
@testable import ReadLater

/// Hold rules in `ReaderSession`: entry while paused, and one way out.
@MainActor
final class ReaderSessionHoldTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "app.readlater.holdtests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func test_scrollEntersHoldWhilePaused() {
        let session = makeSession()
        XCTAssertFalse(session.playbackState.isPlaying)
        XCTAssertTrue(session.playbackState.autoScroll)

        session.userScrolled()

        XCTAssertTrue(session.playbackState.isHeld, "a paused scroll enters Hold")
        XCTAssertFalse(session.playbackState.autoScroll)
    }

    func test_turningFollowingOffEntersHoldWhilePaused() {
        let session = makeSession()
        XCTAssertFalse(session.playbackState.isPlaying)

        session.holdFollowing()

        XCTAssertTrue(session.playbackState.isHeld, "turning following off enters Hold while paused")
        XCTAssertFalse(session.playbackState.autoScroll)
    }

    func test_endingHoldFollowsAgain() {
        let session = makeSession()
        session.holdFollowing()
        XCTAssertTrue(session.playbackState.isHeld)

        session.endHold()

        XCTAssertFalse(session.playbackState.isHeld)
        XCTAssertTrue(session.playbackState.autoScroll)
    }

    func test_endHoldRecordsOnlyWhenItEndsAHold() {
        let hub = TelemetryHub()
        let session = makeSession(telemetry: hub)

        session.endHold()
        XCTAssertEqual(holdEndCount(hub), 0, "endHold from a non-held state logs nothing")

        session.holdFollowing()
        session.endHold()
        XCTAssertEqual(holdEndCount(hub), 1)
    }

    private func holdEndCount(_ hub: TelemetryHub) -> Int {
        hub.telemetryLog.tail(50).filter { $0.event == TelemetryName.holdEnd }.count
    }

    private func makeSession(telemetry: TelemetryHub = TelemetryHub()) -> ReaderSession {
        ReaderSession(
            seed: ReaderSeed(document: ArticleLibrary.demo, savedWordIndex: nil),
            speech: ScriptedSpeechController(millisecondsPerWord: 60_000),
            lookupProvider: HoldFakeLookup(),
            packs: PackRegistry(defaults: defaults),
            connectivity: Connectivity(status: .online),
            telemetry: telemetry,
            speedStore: SpeedStore(defaults: defaults)
        )
    }
}

private final class HoldFakeLookup: LookupProvider {
    func lookup(_ word: String) async -> LookupOutcome {
        .miss(.notInDictionary)
    }
}
