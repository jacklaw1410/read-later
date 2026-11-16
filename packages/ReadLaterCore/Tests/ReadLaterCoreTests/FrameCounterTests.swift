import Testing
@testable import ReadLaterCore

@Suite("Frame counter")
struct FrameCounterTests {
    @Test("Empty and single-frame windows have no summary")
    func emptyAndSingleHaveNoSummary() {
        var counter = FrameCounter()
        #expect(counter.summary() == nil)
        #expect(counter.count == 0)
        counter.record(at: 1_000)
        #expect(counter.summary() == nil)
        #expect(counter.count == 1)
    }

    @Test("Steady 60 Hz gives 60 fps and one-frame longest gap")
    func steady60Hz() throws {
        var counter = FrameCounter()
        let step = 1.0 / 60
        for i in 0 ..< 61 {
            counter.record(at: 1_000 + Double(i) * step)
        }
        let summary = try #require(counter.summary())
        #expect(summary.frames == 61)
        #expect(abs(summary.fps - 60) < 0.01)
        #expect(abs(summary.longestGap - step) < 1e-9)
    }

    @Test("One dropped frame shows up in the longest gap, not the mean")
    func droppedFrame() throws {
        var counter = FrameCounter()
        let step = 1.0 / 120
        for i in 0 ..< 12 {
            counter.record(at: 2_000 + Double(i) * step)
        }
        // Skip one vsync, then continue.
        for i in 13 ..< 24 {
            counter.record(at: 2_000 + Double(i) * step)
        }
        let summary = try #require(counter.summary())
        #expect(summary.frames == 23)
        #expect(abs(summary.longestGap - 2 * step) < 1e-9)
        // Mean rate barely moves: 22 intervals over ~23 frames at 120 Hz.
        #expect(abs(summary.fps - 120 * 22 / 23) < 0.01)
    }

    @Test("Flat timestamps have no summary")
    func flatTimestampsHaveNoSummary() {
        var counter = FrameCounter()
        counter.record(at: 3_000)
        counter.record(at: 3_000)
        #expect(counter.summary() == nil)
    }

    @Test("Reset clears the window")
    func resetClears() {
        var counter = FrameCounter()
        counter.record(at: 4_000)
        counter.record(at: 4_001)
        #expect(counter.summary() != nil)
        counter.reset()
        #expect(counter.count == 0)
        #expect(counter.summary() == nil)
    }

    @Test("Fields carry M5 numbers with units in the key")
    func fieldsCarryM5Numbers() throws {
        var counter = FrameCounter()
        let step = 1.0 / 120
        for i in 0 ..< 121 {
            counter.record(at: 5_000 + Double(i) * step)
        }
        let summary = try #require(counter.summary())
        let fields = summary.fields()
        #expect(fields["frames"] == "121")
        #expect(fields["fps"] == "120.0")
        #expect(fields["longestGapMs"] == "8.33")
        #expect(fields["durationMs"] == "1000.00")
    }

    @Test("Extra fields ride along without overriding counters")
    func extraFieldsRideAlong() throws {
        var counter = FrameCounter()
        counter.record(at: 6_000)
        counter.record(at: 6_001)
        let summary = try #require(counter.summary())
        let fields = summary.fields(extra: [
            "tapToStateMs": "12.50",
            "state": "changed",
            "frames": "intruder",
        ])
        #expect(fields["tapToStateMs"] == "12.50")
        #expect(fields["state"] == "changed")
        #expect(fields["frames"] == "2")
    }
}
