import Foundation
import ReadLaterCore
import ReadLaterStore
import ReadLaterUI

/// Playback and lookup state for one open document.
///
/// One place owns the wash, the card, the hold, and the speech controller. The
/// views read this and send intents back; none of them start or stop audio on
/// their own, because the pause/restore contract only holds if one object
/// remembers whether the voice was live before the tap.
@MainActor
final class ReaderSession: ObservableObject {
    let document: ReadLaterCore.Document
    let spoken: SpokenIndex

    @Published private(set) var wash = WashState.idle
    @Published private(set) var isPlaying = false
    @Published private(set) var isFinished = false
    @Published var isScrubbing = false {
        didSet {
            #if DEBUG
            if isScrubbing != oldValue {
                if isScrubbing {
                    DebugFrameMonitor.shared.noteScrubBegan()
                } else {
                    DebugFrameMonitor.shared.noteScrubEnded()
                }
            }
            #endif
        }
    }
    @Published var autoScroll = true
    @Published private(set) var isHeld = false
    @Published private(set) var card: PaperCard?
    @Published private(set) var note: NoteToShow?
    @Published private(set) var speed: Float
    @Published private(set) var offerDeclined = false
    @Published private(set) var isOnline = true

    private let speech: SpeechController
    private let lookupProvider: PackLookupProvider
    private let speedStore: SpeedStore

    /// Where the next `play` starts. Set by a scrub while paused. A latch,
    /// not a plain optional: the stash clears only after a start succeeds,
    /// so a failed first press retries the same word (F19 1.3).
    private var latch = ResumeLatch()
    /// Set when a drag pauses a playing voice. The release plays again from
    /// the released word.
    private var resumeAfterScrub = false
    /// Receives the current word index when the place should be recorded.
    /// Throttled during reading; immediate on pause, scrub and finish.
    var onProgress: ((Int, String) -> Void)?
    private var progressThrottle = PositionWriteThrottle()


    init(
        document: ReadLaterCore.Document,
        speech: SpeechController,
        lookupProvider: PackLookupProvider,
        speedStore: SpeedStore = SpeedStore()
    ) {
        self.document = document
        self.spoken = SpokenIndex(plan: document.plan)
        self.speech = speech
        self.lookupProvider = lookupProvider
        self.speedStore = speedStore
        self.speed = speedStore.speed

        speech.rate = speed
        speech.onWord = { [weak self] range in self?.advance(to: range) }
        speech.onStateChange = { [weak self] state in self?.speechStateChanged(state) }
    }

    convenience init() {
        self.init(
            document: ArticleLibrary.demo,
            speech: AVSpeechController(),
            lookupProvider: PackLookupProvider()
        )
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
        wash.wordIndex = clamped
        if clamped > 0 { latch.stash(clamped) } else { latch.clear() }
        isFinished = false
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
            wordIndex: wash.wordIndex ?? 0,
            totalWords: spoken.totalWords,
            speed: speed,
            isFinished: isFinished
        )
    }

    func togglePlay() {
        guard card == nil, note == nil else { return }
        // Logged at handler entry, before any state change, for M1 and M2.
        // The word is the wash at tap time, for M9.
        TelemetryHub.shared.record(speech.state == .speaking ? TelemetryName.tapPause : TelemetryName.tapPlay,
                                   fields: ["word": String(wash.wordIndex ?? -1)])
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
        isFinished = false
        wash.wordIndex = min(max(wordIndex, 0), max(spoken.totalWords - 1, 0))
        wash.isPlaying = true
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
        let from = speed
        speed = value
        speedStore.save(value)
        TelemetryHub.shared.record(TelemetryName.speedChange, fields: ["from": String(from), "to": String(value)])
        // The synthesizer cannot change tempo mid-utterance, so the controller
        // restarts the current sentence and keeps the word.
        speech.rate = value
    }

    func scrub(toFraction fraction: Double) {
        guard spoken.totalWords > 0 else { return }
        let index = wordIndex(for: fraction)
        isFinished = false
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
        wash.wordIndex = index
        wash.isPlaying = speech.state == .speaking

        checkpoint(source: "scrub")
    }

    /// Wash preview for an in-flight scrub drag. Moves the highlight only:
    /// no audio seek, no latch, no checkpoint. The seek commits on release
    /// through `scrub(toFraction:)`, so one drag costs one restart (F19 1.7).
    /// Voice boundaries stay frozen while previewing because `advance(to:)`
    /// drops ticks while `isScrubbing` holds.
    func previewScrub(toFraction fraction: Double) {
        guard spoken.totalWords > 0 else { return }
        let index = wordIndex(for: fraction)
        wash.wordIndex = index
        wash.isPlaying = false
    }

    private func wordIndex(for fraction: Double) -> Int {
        let raw = Int((fraction * Double(spoken.totalWords)).rounded())
        return min(max(raw, 0), spoken.totalWords - 1)

    }

    /// A drag began. A playing voice pauses and stays paused until the release.
    /// A paused voice stays paused, and the release only stashes the word.
    func beginScrubbing() {
        guard !isScrubbing else { return }
        isScrubbing = true
        resumeAfterScrub = speech.state == .speaking
        TelemetryHub.shared.record(TelemetryName.scrubBegin, fields: [
            "state": String(describing: speech.state),
        ])
        if resumeAfterScrub { speech.holdForScrub() }
    }

    func finishScrubbing() {
        isScrubbing = false
        resumeAfterScrub = false
    }

    /// Keyboard and VoiceOver step, in words. Reads the live wash position at
    /// press time, so a key handler holding this never captures per-tick view
    /// state (M7: the KeyPress environment stays stable across wash ticks).
    /// Same path as a scrub commit to the same word: one synthesizer restart.
    func seekWords(_ delta: Int) {
        guard spoken.totalWords > 0 else { return }
        let target = min(spoken.totalWords, max(0, (wash.wordIndex ?? 0) + delta))
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
        if let word = wash.wordIndex {
            record(word, force: true, source: source)
        }
    }

    // MARK: - Unit navigation

    /// Steps the wash one sentence. Playing restarts the queue at the
    /// sentence; paused moves the wash and arms the latch, like a scrub that
    /// lands on a sentence start. Tap-a-word stays lookup-only.
    func stepSentence(_ delta: Int) {
        let count = min(spoken.sentenceCount, spoken.firstWordOfSentence.count)
        guard count > 0 else { return }
        let current = spoken.sentenceIndex(forWord: wash.wordIndex ?? 0)
        guard let target = UnitNavigation.clampedSentence(current: current, delta: delta, count: count) else {
            return
        }
        seekToSentence(target)
    }

    /// Steps the wash one spoken block. Same play/paused split as sentences.
    func stepBlock(_ delta: Int) {
        let ids = document.readingOrder.filter { spoken.byBlock[$0.id] != nil }.map(\.id)
        let currentID = wash.wordIndex.flatMap { spoken.word(at: $0)?.blockID }
        guard let target = UnitNavigation.clampedBlock(currentID: currentID, delta: delta, orderedIDs: ids),
              let first = spoken.byBlock[target]?.first
        else { return }
        seekToWord(first.index)
    }

    private func seekToSentence(_ sentence: Int) {
        guard sentence < spoken.firstWordOfSentence.count else { return }
        isFinished = false
        let word = spoken.firstWordOfSentence[sentence]
        if speech.state == .speaking {
            speech.restart(fromSentence: sentence)
            wash.wordIndex = word
            wash.isPlaying = true
        } else {
            latch.stash(word)
            wash.wordIndex = word
            wash.isPlaying = false
        }
        checkpoint(source: "step")
    }

    private func seekToWord(_ word: Int) {
        isFinished = false
        if speech.state == .speaking {
            speech.restart(fromWord: word)
            wash.wordIndex = word
            wash.isPlaying = true
        } else {
            latch.stash(word)
            wash.wordIndex = word
            wash.isPlaying = false
        }
        checkpoint(source: "seek")
    }

    // MARK: - Lookup

    func tapped(blockID: Int, slot: WordSlot?, word: String) {
        guard card == nil, note == nil else { return }
        let token = TokenShape.trimmed(word)
        guard !token.isEmpty else { return }

        // The card pauses in every case. The controller remembers whether the
        // voice was live so closing can restore exactly that.
        speech.pauseForLookup()
        let wasPlaying = speech.wasPlayingBeforeLookup
        wash.selectedWordIndex = slot?.index
        wash.isPlaying = false
        TelemetryHub.shared.record(TelemetryName.lookup, fields: ["word": token])

        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.lookupProvider.lookup(token)
            guard !Task.isCancelled else { return }
            switch outcome {
            case let .hit(result):
                // The source and the line count are the proof that a card
                // carries text: an empty gloss from the wrong source is the
                // defect this field catches.
                TelemetryHub.shared.record(
                    TelemetryName.lookupHit,
                    fields: [
                        "source": result.source.rawValue,
                        "lines": String(result.gloss.split(separator: "\n").count),
                    ]
                )
                self.card = .hit(result, wordIndex: slot?.index, wasPlaying: wasPlaying)
            case let .miss(kind):
                let refined = self.refine(kind)
                TelemetryHub.shared.record(
                    TelemetryName.lookupMiss,
                    fields: ["kind": String(describing: refined)]
                )
                self.card = .miss(
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
        if !isOnline && !lookupProvider.hasPack { return .noNetwork }
        return kind
    }

    func closeCard() {
        guard let card else { return }
        // Close-request mark for M14: with card.shown (paint) and
        // state.speaking (resume) this splits close-to-resume into test
        // delivery (tap to here) and teardown-plus-resume (here to speaking).
        TelemetryHub.shared.record(TelemetryName.cardClose)
        let wasPlaying = card.wasPlaying
        self.card = nil
        wash.selectedWordIndex = nil
        // Restores playback iff it was live before the tap. `closeLookup` reads
        // the snapshot the controller took in `pauseForLookup`.
        speech.closeLookup()
        wash.isPlaying = wasPlaying && speech.state == .speaking
    }

    func declineOffer() {
        offerDeclined = true
        closeCard()
    }

    // MARK: - Notes

    func openNote(_ index: Int) {
        guard card == nil, note == nil, document.noteBlocks.indices.contains(index) else { return }
        speech.pauseForLookup()
        let wasPlaying = speech.wasPlayingBeforeLookup
        note = NoteToShow(index: index, wasPlaying: wasPlaying)
        wash.isPlaying = false
    }

    func closeNote() {
        guard note != nil else { return }
        note = nil
        speech.closeLookup()
        wash.isPlaying = speech.state == .speaking
    }

    func stop() {
        speech.stop()
        wash = .idle
        isPlaying = false
        isFinished = false
        card = nil
        note = nil
        latch.clear()
    }

    // MARK: - Pack

    /// Runs the real install state machine against the bundled demo pack.
    /// On success the open card resolves again, which is the moment the
    /// prototype gets right: the card becomes the answer without a second tap.
    func installPack() async {
        await PackRegistry.shared.install()
        guard PackRegistry.shared.isInstalled else { return }

        // The card becomes the answer in place. The reader does not tap again.
        if case let .miss(word, _, wordIndex, wasPlaying) = card {
            if case let .hit(result) = await lookupProvider.lookup(word) {
                card = .hit(result, wordIndex: wordIndex, wasPlaying: wasPlaying)
            }
        }
    }

    // MARK: - Hold

    /// Called when the reader scrolls the page themselves. Auto-scroll stops
    /// following so the page does not fight the finger. Playback continues.
    func userScrolled() {
        guard isPlaying, autoScroll else { return }
        autoScroll = false
        isHeld = true
        TelemetryHub.shared.record(TelemetryName.holdStart, fields: ["reason": "scroll"])
    }

    func holdFollowing() {
        autoScroll = false
        isHeld = isPlaying
        TelemetryHub.shared.record(TelemetryName.holdStart, fields: ["reason": "menu"])
    }

    func resumeFollowing() {
        autoScroll = true
        isHeld = false
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
    var washWordIndex: Int { wash.wordIndex ?? 0 }

    func simulateWash(toWord index: Int) {
        guard let slot = spoken.word(at: index) else { return }
        wash.wordIndex = slot.index
        wash.isPlaying = true
    }
    #endif

    // MARK: - Speech callbacks

    private func advance(to range: SpokenWordRange) {
        guard !isScrubbing, card == nil, note == nil else { return }
        guard let index = spoken.wordIndex(sentenceIndex: range.sentenceIndex, blockRange: range.range) else {
            return
        }
        wash.wordIndex = index
        wash.isPlaying = isPlaying
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
            isPlaying = true
            isFinished = false
        case .paused, .warming:
            isPlaying = false
            if case .paused = state {
                record(wash.wordIndex ?? 0, force: true, source: "pause")
            }
        case .idle:
            isPlaying = false
        case .finished:
            isPlaying = false
            isFinished = true
            wash.isPlaying = false
            record(max(spoken.totalWords - 1, 0), force: true, source: "finish")
            TelemetryHub.shared.record(TelemetryName.finished)
        }
        wash.isPlaying = isPlaying
    }
}

// MARK: - Card payloads

/// One rendered card. The word index and the pre-tap playback state travel with
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

/// A lookup that asks the system dictionary and, when installed, the pack.
///
/// Order is the research order: the system dictionary first, the installed pack
/// second. A token that cannot be a headword never reaches either.
@MainActor
final class PackLookupProvider: LookupProvider {
    private let apple: AppleDictionaryLookup

    init(apple: AppleDictionaryLookup = AppleDictionaryLookup()) {
        self.apple = apple
    }

    /// Asked of the registry at the moment of the lookup, never cached.
    /// A cached copy goes stale the first time the pack is installed or
    /// removed, and the miss card would then offer a dictionary that is
    /// already there.
    var hasPack: Bool { PackRegistry.shared.isInstalled }

    func lookup(_ word: String) async -> LookupOutcome {
        guard TokenShape.shape(of: word) == .word else { return .miss(.notAWord) }
        if case let .hit(result) = await apple.lookup(word) {
            return .hit(result)
        }
        if let entry = PackRegistry.shared.lookup(word) {
            return .hit(entry)
        }
        return .miss(.notInDictionary)
    }
}
