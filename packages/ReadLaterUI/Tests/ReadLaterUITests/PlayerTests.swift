import Foundation
import ReadLaterCore
import ReadLaterUI
import XCTest

/// Transport bar logic: labels, ladder, persistence, hold detection.
final class PlayerTests: XCTestCase {
    // MARK: - PlayerProgress.timeLabel

    func testTimeLabelAtStart() {
        let progress = PlayerProgress(wordIndex: 0, totalWords: 447, speed: 1, isFinished: false)
        XCTAssertEqual(progress.timeLabel, "03:12 left · 0/447")
    }

    func testTimeLabelMidDocument() {
        let progress = PlayerProgress(wordIndex: 138, totalWords: 447, speed: 1, isFinished: false)
        XCTAssertEqual(progress.timeLabel, "02:13 left · 138/447")
    }

    func testTimeLabelFinished() {
        let progress = PlayerProgress(wordIndex: 447, totalWords: 447, speed: 1, isFinished: true)
        XCTAssertEqual(progress.timeLabel, "Finished · 447/447")
    }

    func testTimeLabelZeroWords() {
        let progress = PlayerProgress(wordIndex: 0, totalWords: 0, speed: 1, isFinished: false)
        XCTAssertEqual(progress.timeLabel, "00:00 left · 0/0")
    }

    func testTimeLabelTopSpeedScalesSeconds() {
        let fast = PlayerProgress(wordIndex: 0, totalWords: 447, speed: 1.5, isFinished: false)
        XCTAssertEqual(fast.timeLabel, "02:08 left · 0/447")
        XCTAssertEqual(
            Pace.secondsRemaining(wordsLeft: 447, speed: 1.5) * 3,
            Pace.secondsRemaining(wordsLeft: 447, speed: 1) * 2
        )
    }

    func testTimeLabelHalfSpeedDoublesSeconds() {
        let progress = PlayerProgress(wordIndex: 0, totalWords: 447, speed: 0.5, isFinished: false)
        XCTAssertEqual(progress.timeLabel, "06:24 left · 0/447")
        XCTAssertEqual(
            Pace.secondsRemaining(wordsLeft: 447, speed: 0.5),
            Pace.secondsRemaining(wordsLeft: 447, speed: 1) * 2
        )
    }

    // MARK: - PlayerProgress.fraction

    func testFractionAtStart() {
        let progress = PlayerProgress(wordIndex: 0, totalWords: 447, speed: 1, isFinished: false)
        XCTAssertEqual(progress.fraction, 0, accuracy: 0.0001)
    }

    func testFractionAtEnd() {
        let progress = PlayerProgress(wordIndex: 447, totalWords: 447, speed: 1, isFinished: true)
        XCTAssertEqual(progress.fraction, 1, accuracy: 0.0001)
    }

    func testFractionClampsPastEnd() {
        let progress = PlayerProgress(wordIndex: 500, totalWords: 447, speed: 1, isFinished: false)
        XCTAssertEqual(progress.fraction, 1, accuracy: 0.0001)
    }

    // MARK: - Pace ladder

    func testNextWalksLadderAndWraps() {
        XCTAssertEqual(Pace.next(after: 0.5), 0.6)
        XCTAssertEqual(Pace.next(after: 1), 1.1)
        XCTAssertEqual(Pace.next(after: 1.4), 1.5)
        XCTAssertEqual(Pace.next(after: 1.5), 0.5)
    }

    func testNextOffLadderReturnsReference() {
        XCTAssertEqual(Pace.next(after: 3), Pace.reference)
    }

    func testLadderSuitsDirectSelection() {
        XCTAssertEqual(Pace.steps, Pace.steps.sorted())
        XCTAssertTrue(Pace.steps.contains(Pace.reference))
        XCTAssertFalse(Pace.steps.isEmpty)
    }

    // MARK: - SpeedStore

    private func scratchStore(key: String = "rl-speed-test") throws -> (SpeedStore, UserDefaults) {
        let suite = "test-speed-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw XCTSkip("Cannot create scratch UserDefaults")
        }
        defaults.removePersistentDomain(forName: suite)
        return (SpeedStore(defaults: defaults, key: key), defaults)
    }

    func testSpeedStoreRoundTrip() throws {
        let (store, defaults) = try scratchStore()
        XCTAssertEqual(store.speed, Pace.reference)
        store.save(1.5)
        XCTAssertEqual(store.speed, 1.5)
        XCTAssertEqual(SpeedStore(defaults: defaults).speed, Pace.reference)
    }

    func testSpeedStoreOffLadderFallsBack() throws {
        let (store, defaults) = try scratchStore()
        defaults.set(Float(3), forKey: "rl-speed-test")
        XCTAssertEqual(store.speed, Pace.reference)
        store.save(3)
        XCTAssertEqual(store.speed, Pace.reference)
    }

    // MARK: - HandednessStore

    private func scratchHandedness(key: String = "rl-play-trailing-test") throws -> (HandednessStore, UserDefaults) {
        let suite = "test-handedness-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw XCTSkip("Cannot create scratch UserDefaults")
        }
        defaults.removePersistentDomain(forName: suite)
        return (HandednessStore(defaults: defaults, key: key), defaults)
    }

    func testPlayDefaultsToTrailingEdge() throws {
        let (store, _) = try scratchHandedness()
        XCTAssertTrue(store.playOnTrailing)
    }

    func testHandednessFlipPersists() throws {
        let (store, defaults) = try scratchHandedness()
        store.save(trailing: false)
        XCTAssertFalse(store.playOnTrailing)
        XCTAssertFalse(HandednessStore(defaults: defaults, key: "rl-play-trailing-test").playOnTrailing)
        store.save(trailing: true)
        XCTAssertTrue(store.playOnTrailing)
    }

    // MARK: - HoldDetector

    func testHoldDetectorNeedsTwoFarEvents() {
        var detector = HoldDetector()
        XCTAssertFalse(detector.scrollEvent(distanceFromWash: 200, isFollowing: true, isScrubbing: false))
        XCTAssertTrue(detector.scrollEvent(distanceFromWash: 200, isFollowing: true, isScrubbing: false))
    }

    func testHoldDetectorIgnoresScrubbing() {
        var detector = HoldDetector()
        XCTAssertFalse(detector.scrollEvent(distanceFromWash: 200, isFollowing: true, isScrubbing: true))
        XCTAssertFalse(detector.scrollEvent(distanceFromWash: 200, isFollowing: true, isScrubbing: true))
    }

    func testHoldDetectorNearEventResets() {
        var detector = HoldDetector()
        XCTAssertFalse(detector.scrollEvent(distanceFromWash: 200, isFollowing: true, isScrubbing: false))
        XCTAssertFalse(detector.scrollEvent(distanceFromWash: 10, isFollowing: true, isScrubbing: false))
        XCTAssertFalse(detector.scrollEvent(distanceFromWash: 200, isFollowing: true, isScrubbing: false))
        XCTAssertTrue(detector.scrollEvent(distanceFromWash: 200, isFollowing: true, isScrubbing: false))
    }

    func testHoldDetectorIgnoresWhenNotFollowing() {
        var detector = HoldDetector()
        XCTAssertFalse(detector.scrollEvent(distanceFromWash: 200, isFollowing: false, isScrubbing: false))
        XCTAssertFalse(detector.scrollEvent(distanceFromWash: 200, isFollowing: false, isScrubbing: false))
    }
}
