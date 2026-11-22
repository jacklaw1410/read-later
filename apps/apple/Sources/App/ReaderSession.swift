import Foundation
import Observation
import ReadLaterCore
import ReadLaterStore
import ReadLaterUI

/// Playback and transport for one open document: the wash, the hold, the speech
/// controller, and the saved place. Lookups and notes live in `LookupController`,
/// which owns the pause and restore contract. The views read this and send intents
/// back. None of them start or stop audio on their own. Mutable state that no view
/// reads is `@ObservationIgnored`, so its writes do not invalidate the reader.
@MainActor
@Observable
final class ReaderSession {
    let document: ReadLaterCore.Document
    let spoken: SpokenWordNumbering
    /// Block roles and counts the reader draws each render. Built once per open by `ReaderSeed`.
    let blockRoles: BlockRoles

    let washState = WashState()
    let playbackState = PlaybackState()
    let lookup: LookupController

    private let speech: SpeechController
    private let pronouncer = WordPronouncer()
    private let speedStore: SpeedStore
    private let telemetry: TelemetryHub

    /// Where the next `play` starts. Set by a scrub while paused. A latch,
    /// not a plain optional: the stash clears only after a start succeeds,
    /// so a failed first press retries the same word (F19 1.3).
    @ObservationIgnored private var latch = ResumeLatch()
    /// Set when a drag pauses a playing voice. The release plays again from
    /// the released word.
    @ObservationIgnored private var resumeAfterScrub = false
    /// Receives the current word index when the place should be recorded.
    /// Throttled during reading; immediate on pause, scrub and finish.
    @ObservationIgnored var onProgress: ((Int, String) -> Void)?
    @ObservationIgnored private var progressThrottle = PositionWriteThrottle()


    init(
        seed: ReaderSeed,
        speech: SpeechController,
        lookupProvider: any LookupProvider,
        packs: any CapabilityPacks,
        connectivity: Connectivity,
        telemetry: TelemetryHub,
        speedStore: SpeedStore
    ) {
        self.document = seed.document
        self.spoken = seed.spoken
        self.blockRoles = seed.blockRoles
        self.speech = speech
        self.telemetry = telemetry
        self.speedStore = speedStore
        self.lookup = LookupController(
            speech: speech,
            playback: playbackState,
            lookupProvider: lookupProvider,
            packs: packs,
            connectivity: connectivity,
            telemetry: telemetry
        )
        self.playbackState.speed = speedStore.speed

        speech.rate = playbackState.speed
        speech.onWord = { [weak self] range in self?.advance(to: range) }
        speech.onStateChange = { [weak self] state in self?.speechStateChanged(state) }
        if let startWord = seed.startWord { begin(at: startWord) }
    }

    func warmUp() {
        speech.warmUp()
    }

    // MARK: - Resume

    /// Starts the next play at a saved word. The wash shows the place at
    /// once; the voice starts there on the next press.
    func begin(at wordIndex: Int) {
        guard spoken.totalWords > 0 else { return }
        let clamped = min(max(wordIndex, 0), spoken.totalWords - 1)
        washState.wordIndex = clamped
        if clamped > 0 { latch.stash(clamped) } else { latch.clear() }
        playbackState.isFinished = false
    }

    /// Records the place: at most once per throttle interval during reading,
    /// always for the out-of-band writes (pause, scrub, background flush).
    private func record(_ index: Int, force: Bool = false, source: String) {
        if force {
            progressThrottle.recordNow()
            onProgress?(index, source)
        } else if progressThrottle.shouldWrite() {
            onProgress?(index, source)
        }
    }

    // MARK: - Transport

    var progress: PlayerProgress {
        PlayerProgress(
            wordIndex: washState.wordIndex ?? 0,
            totalWords: spoken.totalWords,
            speed: playbackState.speed,
            isFinished: playbackState.isFinished
        )
    }

    func togglePlay() {
        guard !lookup.isOpen else { return }
        // Logged at handler entry, before any state change, for M1 and M2.
        // The word is the wash at tap time, for M9.
        telemetry.record(speech.state == .speaking ? TelemetryName.tapPause : TelemetryName.tapPlay,
                                   fields: ["word": String(washState.wordIndex ?? -1)])
        #if DEBUG
        DebugFrameMonitor.shared.noteTap()
        #endif
        if speech.state == .speaking {
            speech.pause()
            checkpoint(source: "pause")
            telemetry.record(TelemetryName.pause)
            return
        }
        telemetry.record(TelemetryName.play)
        // A paused scrub arms the latch. It wins over resume-from-pause:
        // resuming would replay the old position and strand the scrub.
        if let target = latch.peek() {
            startSpeaking(at: target)
            return
        }
        switch speech.state {
        case .paused:
            speech.resume()
        case .speaking:
            speech.pause()
            telemetry.record(TelemetryName.pause)
        case .warming, .idle, .finished:
            // Warming is a background pre-warm, not playback. The reader's
            // first press must start the article even if the voice is still
            // getting ready; treating warming as playing made the button do
            // nothing on a cold launch.
            startSpeaking(at: 0)
        }
    }

    /// Starts audio at a word. Returns true when audio will move. The latch
    /// clears only on success, so a failed press keeps the word for the next
    /// one instead of losing the place.
    @discardableResult
    private func startSpeaking(at wordIndex: Int) -> Bool {
        playbackState.isFinished = false
        washState.wordIndex = min(max(wordIndex, 0), max(spoken.totalWords - 1, 0))
        playbackState.isPlaying = true
        if wordIndex > 0, speech.canRestart {
            guard speech.restart(fromWord: wordIndex) else { return false }
            latch.clear()
            return true
        }
        if wordIndex > 0 {
            // No queue to seek in: never played, or a stop destroyed it.
            // Rebuild from the sentences, then seek. The restart bumps the
            // epoch, so the speak's deferred fill is stale and only the seek
            // fill runs.
            speech.speak(sentences: document.spokenSentences)
            guard speech.restart(fromWord: wordIndex) else { return false }
            latch.clear()
            return true
        }
        speech.speak(sentences: document.spokenSentences)
        latch.clear()
        return true
    }

    func setSpeed(_ value: Float) {
        let from = playbackState.speed
        playbackState.speed = value
        speedStore.save(value)
        telemetry.record(TelemetryName.speedChange, fields: ["from": String(from), "to": String(value)])
        // The synthesizer cannot change tempo mid-utterance, so the controller
        // restarts the current utterance and keeps the word.
        speech.rate = value
    }

    func scrub(toFraction fraction: Double) {
        guard spoken.totalWords > 0 else { return }
        let index = wordIndex(for: fraction)
        playbackState.isFinished = false
        let resume = resumeAfterScrub
        resumeAfterScrub = false
        if resume {
            // The drag paused the voice. Release plays again from the word.
            if !startSpeaking(at: index) { latch.stash(index) }
        } else if speech.state == .speaking {
            // Restart before the wash and the mark below, so the engine start
            // does not wait behind main-thread work (M4).
            speech.restart(fromWord: index)
        } else {
            // Paused scrub stashes the word and leaves the queue alive.
            // stop() used to destroy the queue restart() needs, and the old
            // code cleared the position before the failed start (F19 1.3).
            latch.stash(index)
        }
        // Logged after the restart, for M4 (release to sound).
        telemetry.record(TelemetryName.scrubCommit, fields: [
            "fraction": String(format: "%.4f", fraction),
            "word": String(index),
        ])
        washState.wordIndex = index
        playbackState.isPlaying = speech.state == .speaking

        checkpoint(source: "scrub")
    }

    /// Wash preview for an in-flight scrub drag. Moves the highlight only:
    /// no audio seek, no latch, no checkpoint. The seek commits on release
    /// through `scrub(toFraction:)`, so one drag costs one restart (F19 1.7).
    /// Voice boundaries stay frozen while previewing because `advance(to:)`
    /// drops ticks while `playbackState.isScrubbing` holds.
    func previewScrub(toFraction fraction: Double) {
        guard spoken.totalWords > 0 else { return }
        let index = wordIndex(for: fraction)
        washState.wordIndex = index
        playbackState.isPlaying = false
    }

    private func wordIndex(for fraction: Double) -> Int {
        let raw = Int((fraction * Double(spoken.totalWords)).rounded())
        return min(max(raw, 0), spoken.totalWords - 1)

    }

    /// A drag began. A playing voice pauses and stays paused until the release.
    /// A paused voice stays paused, and the release only stashes the word.
    func beginScrubbing() {
        guard !playbackState.isScrubbing else { return }
        playbackState.isScrubbing = true
        #if DEBUG
        DebugFrameMonitor.shared.noteScrubBegan()
        #endif
        resumeAfterScrub = speech.state == .speaking
        telemetry.record(TelemetryName.scrubBegin, fields: [
            "state": String(describing: speech.state),
        ])
        if resumeAfterScrub { speech.holdForScrub() }
    }

    func finishScrubbing() {
        playbackState.isScrubbing = false
        #if DEBUG
        DebugFrameMonitor.shared.noteScrubEnded()
        #endif
        resumeAfterScrub = false
    }

    /// Keyboard and VoiceOver step, in words. Reads the live wash position at
    /// press time, so a key handler holding this never captures per-tick view
    /// state (M7: the KeyPress environment stays stable across wash ticks).
    /// Same path as a scrub commit to the same word: one synthesizer restart.
    func seekWords(_ delta: Int) {
        guard spoken.totalWords > 0 else { return }
        let target = min(spoken.totalWords, max(0, (washState.wordIndex ?? 0) + delta))
        scrub(toFraction: Double(target) / Double(spoken.totalWords))
    }


    // MARK: - Background (F19 1.4, decided: clean pause)

    /// Deliberate pause on leaving `.active`. Lands before the system
    /// suspends the process, so the reader returns to a paused article at
    /// the same word with a truthful button. Never auto-resumes.
    func pauseForBackground() {
        guard speech.state == .speaking else { return }
        speech.pause()
        checkpoint(source: "background")
    }

    /// Reconcile on return to `.active`. Suspension can kill synthesis with
    /// the controller still reading `.speaking`; that lie becomes a clean
    /// pause here instead of a dead button.
    func reconcileOnReturn() {
        if TransportTruth.needsReconcile(state: speech.state, hasLiveUtterances: speech.hasLiveUtterances) {
            speech.pause()
        }
    }

    /// Hands the current word to the persistence slice, if one is attached.
    /// Delegates to the throttled record path, forced: checkpoints fire on
    /// pause, scrub commit and background, never per word.
    private func checkpoint(source: String) {
        if let word = washState.wordIndex {
            record(word, force: true, source: source)
        }
    }

    // MARK: - Unit navigation

    /// Steps the wash one utterance. Playing restarts the queue at the
    /// utterance; paused moves the wash and arms the latch, like a scrub that
    /// lands on an utterance start. Tap-a-word stays lookup-only.
    func stepUtterance(_ delta: Int) {
        let count = min(spoken.utteranceCount, spoken.firstWordOfUtterance.count)
        guard count > 0 else { return }
        let current = spoken.utteranceIndex(forWord: washState.wordIndex ?? 0)
        guard let target = UnitNavigation.clampedUtterance(current: current, delta: delta, count: count) else {
            return
        }
        seekToUtterance(target)
    }

    /// Steps the wash one spoken block. Same play/paused split as utterances.
    func stepBlock(_ delta: Int) {
        let ids = document.readingOrder.filter { spoken.byBlock[$0.id] != nil }.map(\.id)
        let currentID = washState.wordIndex.flatMap { spoken.word(at: $0)?.blockID }
        guard let target = UnitNavigation.clampedBlock(currentID: currentID, delta: delta, orderedIDs: ids),
              let first = spoken.byBlock[target]?.first
        else { return }
        seekToWord(first.index)
    }

    private func seekToUtterance(_ utterance: Int) {
        guard utterance < spoken.firstWordOfUtterance.count else { return }
        playbackState.isFinished = false
        let word = spoken.firstWordOfUtterance[utterance]
        if speech.state == .speaking {
            speech.restart(fromUtterance: utterance)
            washState.wordIndex = word
            playbackState.isPlaying = true
        } else {
            latch.stash(word)
            washState.wordIndex = word
            playbackState.isPlaying = false
        }
        checkpoint(source: "step")
    }

    private func seekToWord(_ word: Int) {
        playbackState.isFinished = false
        if speech.state == .speaking {
            speech.restart(fromWord: word)
            washState.wordIndex = word
            playbackState.isPlaying = true
        } else {
            latch.stash(word)
            washState.wordIndex = word
            playbackState.isPlaying = false
        }
        checkpoint(source: "seek")
    }

    // MARK: - Lookup

    /// Speaks the card's word. Leaves playback and the card as they are.
    func pronounce(_ word: String) {
        pronouncer.speak(word)
    }

    // MARK: - Notes

    func openNote(_ index: Int) {
        guard document.noteBlocks.indices.contains(index) else { return }
        lookup.openNote(index)
    }

    func stop() {
        speech.stop()
        washState.wordIndex = nil
        playbackState.isPlaying = false
        playbackState.isFinished = false
        playbackState.isHeld = false
        playbackState.isScrubbing = false
        lookup.cancel()
        latch.clear()
    }

    // MARK: - Hold

    /// Called when the reader scrolls the page themselves. Auto-scroll stops
    /// following so the page does not fight the finger. Playback continues.
    func userScrolled() {
        guard playbackState.isPlaying, playbackState.autoScroll else { return }
        playbackState.autoScroll = false
        playbackState.isHeld = true
        telemetry.record(TelemetryName.holdStart, fields: ["reason": "scroll"])
    }

    func holdFollowing() {
        playbackState.autoScroll = false
        playbackState.isHeld = playbackState.isPlaying
        telemetry.record(TelemetryName.holdStart, fields: ["reason": "menu"])
    }

    func resumeFollowing() {
        playbackState.autoScroll = true
        playbackState.isHeld = false
        telemetry.record(TelemetryName.holdEnd, fields: ["outcome": "resume"])
    }

    #if DEBUG
    /// Moves the wash and the progress without the audio engine.
    ///
    /// The snapshot harness runs in a launch where `AVSpeechSynthesizer`
    /// starts an utterance and then delivers no word boundaries at all, so
    /// every screenshot of playback would show word zero. This drives the same
    /// wash the voice would drive, and nothing else. Release builds do not
    /// contain it.
    var washWordIndex: Int { washState.wordIndex ?? 0 }

    func simulateWash(toWord index: Int) {
        guard let slot = spoken.word(at: index) else { return }
        washState.wordIndex = slot.index
        playbackState.isPlaying = true
    }
    #endif

    // MARK: - Speech callbacks

    private func advance(to range: SpokenWordRange) {
        guard !playbackState.isScrubbing, !lookup.isOpen else { return }
        guard let index = spoken.wordIndex(utteranceIndex: range.utteranceIndex, blockRange: range.range) else {
            return
        }
        washState.wordIndex = index
        playbackState.isPlaying = playbackState.isPlaying
        record(index, source: "tick")
    }

    private func speechStateChanged(_ state: SpeechState) {
        // Every delegate change is logged, including late callbacks (F20.4).
        telemetry.record("state.\(state)")
        #if DEBUG
        DebugFrameMonitor.shared.noteStateChange()
        #endif
        switch state {
        case .speaking:
            playbackState.isPlaying = true
            playbackState.isFinished = false
        case .paused, .warming:
            playbackState.isPlaying = false
            if case .paused = state {
                record(washState.wordIndex ?? 0, force: true, source: "pause")
            }
        case .idle:
            playbackState.isPlaying = false
        case .finished:
            playbackState.isPlaying = false
            playbackState.isFinished = true
            playbackState.isPlaying = false
            record(max(spoken.totalWords - 1, 0), force: true, source: "finish")
            telemetry.record(TelemetryName.finished)
        }
        playbackState.isPlaying = playbackState.isPlaying
    }
}

// MARK: - Card payloads

/// One rendered lookup card. The word index and the pre-tap playback state travel with
/// it, because the card prints both and the close path needs the second.
enum PaperCard: Identifiable {
    case hit(LookupResult, wordIndex: Int?, wasPlaying: Bool)
    case miss(word: String, kind: MissKind, wordIndex: Int?, wasPlaying: Bool)

    var id: String {
        switch self {
        case let .hit(result, _, _): return "hit-\(result.word)"
        case let .miss(word, kind, _, _): return "miss-\(kind)-\(word)"
        }
    }

    var wasPlaying: Bool {
        switch self {
        case let .hit(_, _, wasPlaying): return wasPlaying
        case let .miss(_, _, _, wasPlaying): return wasPlaying
        }
    }

    var wordIndex: Int? {
        switch self {
        case let .hit(_, index, _): return index
        case let .miss(_, _, index, _): return index
        }
    }
}

struct NoteToShow: Identifiable {
    var index: Int
    var wasPlaying: Bool
    var id: Int { index }
}

