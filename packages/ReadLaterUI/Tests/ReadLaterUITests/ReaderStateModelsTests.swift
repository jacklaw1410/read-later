import ReadLaterUI
import XCTest

@MainActor
final class ReaderStateModelsTests: XCTestCase {
    func testWashSnapshotCarriesPlaybackAndSelection() {
        let wash = WashState(wordIndex: 5, selectedWordIndex: 5)
        let playback = PlaybackState(isPlaying: true, isHeld: true, isScrubbing: true)

        let snapshot = wash.snapshot(playback: playback)

        XCTAssertEqual(snapshot.wordIndex, 5)
        XCTAssertEqual(snapshot.selectedWordIndex, 5)
        XCTAssertTrue(snapshot.isPlaying)
        XCTAssertTrue(playback.isHeld)
        XCTAssertTrue(playback.isScrubbing)
        XCTAssertEqual(snapshot.emphasis(for: 5), .coincide)
    }

    func testWashSnapshotDefaultsToIdleShape() {
        let snapshot = WashState().snapshot(playback: PlaybackState())

        XCTAssertNil(snapshot.wordIndex)
        XCTAssertNil(snapshot.selectedWordIndex)
        XCTAssertFalse(snapshot.isPlaying)
        XCTAssertEqual(snapshot.emphasis(for: 0), .none)
    }
}
