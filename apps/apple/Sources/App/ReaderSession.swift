import Foundation
import Observation
import ReadLaterCore
import ReadLaterStore
import ReadLaterUI

/// Playback and lookup state for one open document.
///
/// One place owns the wash, the lookupState.card, the hold, and the speech controller. The
/// views read this and send intents back; none of them start or stop audio on
/// their own, because the pause/restore contract only holds if one object
/// remembers whether the voice was live before the tap. Mutable state that no
/// view reads is `@ObservationIgnored`, so its writes do not invalidate the reader.
@MainActor
@Observable
final class ReaderSession {
    let document: ReadLaterCore.Document
    let spoken: SpokenWordNumbering

    let washState = WashState()
    let playbackState = PlaybackState()
    let lookupState = LookupState<PaperCard, NoteToShow>()


    private let speech: SpeechController
    private let lookupProvider: any LookupProvider
    private let packs: any CapabilityPacks
    private let speedStore: SpeedStore

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
        document: ReadLaterCore.Document,
        speech: SpeechController,
        lookupProvider: any LookupProvider,
        packs: any CapabilityPacks,
        speedStore: SpeedStore = SpeedStore()
    ) {
        self.document = document
        self.spoken = SpokenWordNumbering(plan: document.plan)
        self.speech = speech
        self.lookupProvider = lookupProvider
        self.packs = packs
        self.speedStore = speedStore
        self.playbackState.speed = speedStore.speed

        speech.rate = playbackState.speed
        speech.onWord = { [weak self] range in self?.advance(to: range) }
        speech.onStateChange = { [weak self] state in self?.speechStateChanged(state) }
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
        guard lookupState.card == nil, lookupState.note == nil else { return }
        // Logged at handler entry, before any state change, for M1 and M2.
        // The word is the wash at tap time, for M9.
        TelemetryHub.shared.record(speech.state == .speaking ? TelemetryName.tapPause : TelemetryName.tapPlay,
                                   fields: ["word": String(washState.wordIndex ?? -1)])
        #if DEBUG
        DebugFrameMonitor.shared.noteTap()
        #endif
        if speech.state == .speaking {
            speech.pause()
            checkpoint(source: "pause")
            TelemetryHub.shared.record(TelemetryName.pause)
            return
        }
        TelemetryHub.shared.record(TelemetryName.play)
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
            TelemetryHub.shared.record(TelemetryName.pause)
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
        TelemetryHub.shared.record(TelemetryName.speedChange, fields: ["from": String(from), "to": String(value)])
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
        TelemetryHub.shared.record(TelemetryName.scrubCommit, fields: [
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
        TelemetryHub.shared.record(TelemetryName.scrubBegin, fields: [
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

    func tapped(blockID: Int, slot: WordSlot?, word: String) {
        guard lookupState.card == nil, lookupState.note == nil else { return }
        let token = TokenShape.trimmed(word)
        guard !token.isEmpty else { return }

        // The lookupState.card pauses in every case. The controller remembers whether the
        // voice was live so closing can restore exactly that.
        speech.pauseForLookup()
        let wasPlaying = speech.wasPlayingBeforeLookup
        washState.selectedWordIndex = slot?.index
        playbackState.isPlaying = false
        TelemetryHub.shared.record(TelemetryName.lookup, fields: ["word": token])

        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.lookupProvider.lookup(token)
            guard !Task.isCancelled else { return }
            switch outcome {
            case let .hit(result):
                // The source and the line count are the proof that a lookupState.card
                // carries text: an empty gloss from the wrong source is the
                // defect this field catches.
                TelemetryHub.shared.record(
                    TelemetryName.lookupHit,
                    fields: [
                        "source": result.source.rawValue,
                        "lines": String(result.gloss.split(separator: "\n").count),
                    ]
                )
                lookupState.card = .hit(result, wordIndex: slot?.index, wasPlaying: wasPlaying)
            case let .miss(kind):
                let refined = self.refine(kind)
                TelemetryHub.shared.record(
                    TelemetryName.lookupMiss,
                    fields: ["kind": String(describing: refined)]
                )
                lookupState.card = .miss(
                    word: token,
                    kind: refined,
                    wordIndex: slot?.index,
                    wasPlaying: wasPlaying
                )
            }
        }
    }

    /// A shape refusal is decided before the dictionary is asked, and an
    /// offline miss says so instead of pretending the word is unknown.
    private func refine(_ kind: MissKind) -> MissKind {
        if kind == .notAWord { return .notAWord }
        if !lookupState.isOnline && !packs.isInstalled { return .noNetwork }
        return kind
    }

    func closeCard() {
        guard let card = lookupState.card else { return }
        // Close-request mark for M14: with lookupState.card.shown (paint) and
        // state.speaking (resume) this splits close-to-resume into test
        // delivery (tap to here) and teardown-plus-resume (here to speaking).
        TelemetryHub.shared.record(TelemetryName.cardClose)
        let wasPlaying = card.wasPlaying
        lookupState.card = nil
        washState.selectedWordIndex = nil
        // Restores playback iff it was live before the tap. `closeLookup` reads
        // the snapshot the controller took in `pauseForLookup`.
        speech.closeLookup()
        playbackState.isPlaying = wasPlaying && speech.state == .speaking
    }

    func declineOffer() {
        packs.declineOffer()
        closeCard()
    }

    // MARK: - Notes

    func openNote(_ index: Int) {
        guard lookupState.card == nil, lookupState.note == nil, document.noteBlocks.indices.contains(index) else { return }
        speech.pauseForLookup()
        let wasPlaying = speech.wasPlayingBeforeLookup
        lookupState.note = NoteToShow(index: index, wasPlaying: wasPlaying)
        playbackState.isPlaying = false
    }

    func closeNote() {
        guard lookupState.note != nil else { return }
        lookupState.note = nil
        speech.closeLookup()
        playbackState.isPlaying = speech.state == .speaking
    }

    func stop() {
        speech.stop()
        washState.wordIndex = nil
        washState.selectedWordIndex = nil
        playbackState.isPlaying = false
        playbackState.isFinished = false
        playbackState.isHeld = false
        playbackState.isScrubbing = false
        lookupState.card = nil
        lookupState.note = nil
        latch.clear()
    }

    // MARK: - Pack

    /// Runs the real install state machine against the bundled demo pack.
    /// On success the open lookupState.card resolves again, which is the moment the
    /// prototype gets right: the lookupState.card becomes the answer without a second tap.
    func installPack() async {
        await packs.install()
        guard packs.isInstalled else { return }

        // The lookupState.card becomes the answer in place. The reader does not tap again.
        if case let .miss(word, _, wordIndex, wasPlaying) = lookupState.card {
            if case let .hit(result) = await lookupProvider.lookup(word) {
                lookupState.card = .hit(result, wordIndex: wordIndex, wasPlaying: wasPlaying)
            }
        }
    }

    // MARK: - Hold

    /// Called when the reader scrolls the page themselves. Auto-scroll stops
    /// following so the page does not fight the finger. Playback continues.
    func userScrolled() {
        guard playbackState.isPlaying, playbackState.autoScroll else { return }
        playbackState.autoScroll = false
        playbackState.isHeld = true
        TelemetryHub.shared.record(TelemetryName.holdStart, fields: ["reason": "scroll"])
    }

    func holdFollowing() {
        playbackState.autoScroll = false
        playbackState.isHeld = playbackState.isPlaying
        TelemetryHub.shared.record(TelemetryName.holdStart, fields: ["reason": "menu"])
    }

    func resumeFollowing() {
        playbackState.autoScroll = true
        playbackState.isHeld = false
        TelemetryHub.shared.record(TelemetryName.holdEnd, fields: ["outcome": "resume"])
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
        guard !playbackState.isScrubbing, lookupState.card == nil, lookupState.note == nil else { return }
        guard let index = spoken.wordIndex(utteranceIndex: range.utteranceIndex, blockRange: range.range) else {
            return
        }
        washState.wordIndex = index
        playbackState.isPlaying = playbackState.isPlaying
        record(index, source: "tick")
    }

    private func speechStateChanged(_ state: SpeechState) {
        // Every delegate change is logged, including late callbacks (F20.4).
        TelemetryHub.shared.record("state.\(state)")
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
            TelemetryHub.shared.record(TelemetryName.finished)
        }
        playbackState.isPlaying = playbackState.isPlaying
    }
}

// MARK: - Card payloads

/// One rendered lookupState.card. The word index and the pre-tap playback state travel with
/// it, because the lookupState.card prints both and the close path needs the second.
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
