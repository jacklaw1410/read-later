import ReadLaterCore
import ReadLaterUI
import XCTest
@testable import ReadLater

/// Lookup state in `LookupController`, reached through `ReaderSession`: replace-in-place,
/// the playback snapshot, stale-result drop, and the network state that decides `.noNetwork`.
/// The persisted decline lives in `PackRegistry`.
@MainActor
final class ReaderSessionLookupTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "app.readlater.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    // MARK: - Replace in place and playback snapshot

    func test_secondTapReplacesCardAndKeepsOnePauseSnapshot() async {
        let speech = makeSpeech()
        let session = makeSession(speech: speech, lookup: FakeLookup())
        session.togglePlay()
        XCTAssertEqual(speech.state, .speaking)

        session.lookup.tap(slot: nil, word: "zxqv")
        await waitUntil { session.lookup.state.card?.word == "zxqv" }
        session.lookup.tap(slot: nil, word: "quux")
        await waitUntil { session.lookup.state.card?.word == "quux" }

        XCTAssertEqual(session.lookup.state.card?.word, "quux", "the second tap replaces the first card")
        XCTAssertEqual(session.lookup.state.card?.wasPlaying, true, "the second tap reuses the snapshot taken by the first")
        XCTAssertEqual(speech.state, .paused)

        session.lookup.closeCard()
        XCTAssertEqual(speech.state, .speaking, "close restores playback that was live before the first tap")
    }

    func test_closeLeavesPausedVoiceAsItWas() async {
        let speech = makeSpeech()
        let session = makeSession(speech: speech, lookup: FakeLookup())

        session.lookup.tap(slot: nil, word: "zxqv")
        await waitUntil { session.lookup.state.card != nil }
        XCTAssertEqual(session.lookup.state.card?.wasPlaying, false)

        session.lookup.closeCard()
        XCTAssertNotEqual(speech.state, .speaking, "close must not start a voice that was not live")
    }

    // MARK: - Stale generation

    func test_slowEarlierResultIsDroppedAfterNewerTap() async {
        let lookup = FakeLookup()
        lookup.outcomes["slow"] = .hit(LookupResult(word: "slow", gloss: "慢", source: .pack))
        lookup.delays["slow"] = .milliseconds(300)
        let session = makeSession(speech: makeSpeech(), lookup: lookup)

        session.lookup.tap(slot: nil, word: "slow")
        session.lookup.tap(slot: nil, word: "fast")
        await waitUntil { session.lookup.state.card?.word == "fast" }

        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(session.lookup.state.card?.word, "fast", "the earlier slow result must not replace the newer card")
    }

    // MARK: - Network state

    func test_unknownNetworkKeepsOrdinaryMiss() async {
        let session = makeSession(speech: makeSpeech(), lookup: FakeLookup(), connectivity: Connectivity())

        session.lookup.tap(slot: nil, word: "zxqv")
        await waitUntil { session.lookup.state.card != nil }

        XCTAssertEqual(missKind(session), .notInDictionary, "an unknown path is not called offline")
    }

    func test_offlineMissWithoutPackIsNoNetwork() async {
        let session = makeSession(
            speech: makeSpeech(), lookup: FakeLookup(), connectivity: Connectivity(status: .offline)
        )

        session.lookup.tap(slot: nil, word: "zxqv")
        await waitUntil { session.lookup.state.card != nil }

        XCTAssertEqual(missKind(session), .noNetwork)
    }

    // MARK: - Decline persistence

    func test_declinePersistsAcrossRelaunch() {
        let first = PackRegistry(defaults: defaults)
        XCTAssertFalse(first.offerDeclined)

        first.declineOffer()
        XCTAssertTrue(defaults.bool(forKey: "rl-pack-offer-declined"))

        let relaunched = PackRegistry(defaults: defaults)
        XCTAssertTrue(relaunched.offerDeclined, "a new registry reads the decline from defaults")
    }

    // MARK: - Helpers

    private func makeSpeech() -> ScriptedSpeechController {
        // Slow clock: no word boundaries arrive during a test.
        ScriptedSpeechController(millisecondsPerWord: 60_000)
    }

    private func makeSession(
        speech: SpeechController,
        lookup: FakeLookup,
        connectivity: Connectivity? = nil
    ) -> ReaderSession {
        ReaderSession(
            seed: ReaderSeed(document: ArticleLibrary.demo, savedWordIndex: nil),
            speech: speech,
            lookupProvider: lookup,
            packs: PackRegistry(defaults: defaults),
            connectivity: connectivity ?? Connectivity(status: .online),
            telemetry: TelemetryHub(),
            speedStore: SpeedStore(defaults: defaults)
        )
    }

    private func missKind(_ session: ReaderSession) -> MissKind? {
        if case let .miss(_, kind, _, _)? = session.lookup.state.card { return kind }
        return nil
    }

    private func waitUntil(_ condition: () -> Bool) async {
        var spins = 0
        while !condition(), spins < 400 {
            try? await Task.sleep(for: .milliseconds(5))
            spins += 1
        }
    }
}

/// Answers from a table. A word listed in `delays` waits before it answers.
@MainActor
private final class FakeLookup: LookupProvider {
    var outcomes: [String: LookupOutcome] = [:]
    var delays: [String: Duration] = [:]

    func lookup(_ word: String) async -> LookupOutcome {
        if let delay = delays[word] {
            try? await Task.sleep(for: delay)
        }
        return outcomes[word] ?? .miss(.notInDictionary)
    }
}

private extension PaperCard {
    var word: String? {
        switch self {
        case let .hit(result, _, _): return result.word
        case let .miss(word, _, _, _): return word
        }
    }
}
