import ReadLaterUI
import XCTest

@MainActor
final class ReaderStateModelsTests: XCTestCase {
    func testWashEmphasisUsesPlaybackState() {
        let wash = WashState(wordIndex: 5)
        let playback = PlaybackState(status: .playing)

        XCTAssertEqual(wash.emphasis(for: 5, isPlaying: playback.isPlaying, selectedWordIndex: 5), .coincide)
        XCTAssertTrue(playback.isHeld == false)
    }

    func testPlaybackDefaultsToStopped() {
        let playback = PlaybackState()

        XCTAssertFalse(playback.isPlaying)
        XCTAssertFalse(playback.isFinished)
        XCTAssertFalse(playback.isScrubbing)
    }
}