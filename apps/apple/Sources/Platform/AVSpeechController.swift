import AVFoundation
import Foundation
import ReadLaterCore

/// Sentence-queue speech. Word boundaries come from
/// `speechSynthesizer(_:willSpeakRangeOfSpeechString:utterance:)`, which
/// delivers an NSRange into the utterance string; `SpeechQueue` maps it back
/// to a block-text range, so the reported range addresses the block.
///
/// Where the four scaffold defects (HANDOFF-TO-BUILD §3) are fixed:
/// 1. The delegate signature is `willSpeakRangeOfSpeechString:utterance:`
///    (NSRange) on the bridge below. The scaffold form did not compile.
/// 2. Two-utterance prefetch: `speak` fills the window and `didFinish`
///    enqueues one more while `SpeechQueue.shouldEnqueueNext` holds.
///    Nothing speaks one-at-a-time.
/// 3. The lookup owner decides when to pause and resume. `resume()` continues
///    the queue only from `.paused`, so a card never starts audio that was
///    already paused.
/// 4. The tick gate (`!scrubbing`, auto-scroll hold) lives in the session,
///    not here: `ReaderSession.handleWord` in RootView.swift drops
///    boundaries while scrubbing and ReaderView gates auto-scroll. This
///    controller delivers every boundary.
@MainActor
public final class AVSpeechController: NSObject, SpeechController {
    private var bridge: SpeechDelegateBridge?
    public var onWord: ((SpokenWordRange) -> Void)?
    public var onStateChange: ((SpeechState) -> Void)?
    /// Debug-only stall probe. Nil in Release, so every call is one optional
    /// check. The probe owns its timer and its log lines; this class only
    /// reports what happened.
    public var onProbe: ((SpeechProbeEvent) -> Void)?

    /// UI speed multiplier. 1.0 is the reference pace, about 140 words per minute.
    /// A change while speaking restarts from the current word, because the
    /// synthesizer cannot change rate mid-utterance. Rapid changes coalesce:
    /// one restart per gesture, not per tick, with the 50 ms delay doubling
    /// as the throttle fallback (F19 1.7). A change while paused applies to
    /// later utterances; the paused queue is left untouched.
    public var rate: Float = 1.0 {
        didSet {
            guard rate != oldValue, state == .speaking else { return }
            rateSettler.push(rate)
            rateTask?.cancel()
            rateTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, !Task.isCancelled, self.state == .speaking else { return }
                guard self.rateSettler.takePending() != nil else { return }
                self.restart(fromWord: self.currentWordIndex)
            }
        }
    }

    public private(set) var state: SpeechState = .idle {
        didSet {
            if state != oldValue { onStateChange?(state) }
        }
    }

    private struct InFlight {
        var epoch: Int
        var utteranceIndex: Int
    }

    private struct HeadTruncation {
        var position: Int
        var text: String
        var shift: Int
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var queue: SpeechQueue?
    private var inFlight: [ObjectIdentifier: InFlight] = [:]
    /// Retains spoken utterances so a stale callback can never match a new
    /// utterance reused at the same address.
    private var retained: [ObjectIdentifier: AVSpeechUtterance] = [:]
    /// Absolute utterance index of the next sentence not yet enqueued.
    private var nextToEnqueue = 0
    private var prefetchWindow = SpeechQueue.prefetch
    private var headTruncation: HeadTruncation?
    private var currentWordIndex = 0
    /// Word the voice was held at: a scrub drag, a pause, or an interruption.
    /// `resume()` plays on from it, not from the queue position, which is past
    /// the cut sentence.
    private var heldWord: Int?
    private var rateTask: Task<Void, Never>?
    private var rateSettler = RateSettler()
    private var epoch = 0
    private var warmedUp = false
    /// Epoch captured when a fill is scheduled, so a stale fill does nothing.
    private var epochAtFill = 0
    private var warmupIDs = Set<ObjectIdentifier>()
    /// First voice callback and first word boundary of the current `speak`,
    /// for the speech.enqueued → speech.first-word stage. Reset on every speak; only the first of each is
    /// recorded, and only while a tap-to-first-word run is active.
    private var ttfwVoiceStarted = false
    private var ttfwWordDelivered = false
    private var pausedByInterruption = false
    private let telemetry: TelemetryHub
    private var voice: AVSpeechSynthesisVoice?
    private nonisolated(unsafe) var interruptionToken: NSObjectProtocol?

    public init(telemetry: TelemetryHub) {
        self.telemetry = telemetry
        voice = Self.defaultVoice()
        super.init()
        // This init is the one place that owns the audio-session config. The
        // MVP declares no `audio` background key (see project.yml: none) and
        // pauses on leaving `.active`, so a later listen-only mode adds the
        // key, `.playback`, and Now Playing info here — never a second
        // transport path (F19 1.4, decision 6).
        let bridge = SpeechDelegateBridge()
        bridge.owner = self
        self.bridge = bridge
        synthesizer.delegate = bridge
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
            interruptionToken = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: nil
            ) { [weak self] note in
                Task { @MainActor [weak self] in self?.handleInterruption(note) }
            }
        #endif
    }

    deinit {
        if let token = interruptionToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// All spoken text is English, so the voice stays English whatever the app
    /// language is. Never localised: a Chinese UI still hears `en-US`.
    private static func defaultVoice() -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: "en-US")
            ?? AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.hasPrefix("en") })
    }

    // MARK: - SpeechController

    /// Pre-warms the synthesizer and voice so the first real word arrives
    /// without a stall. Cold start measured 1,139.7 ms against a 700 ms gate.
    public func warmUp() {
        guard !warmedUp else { return }
        warmedUp = true
        state = .warming
        // One empty utterance at load. A single space produces no audible
        // output; an empty string may not engage the voice at all.
        let utterance = AVSpeechUtterance(string: " ")
        utterance.rate = utteranceRate
        utterance.voice = voice
        warmupIDs.insert(ObjectIdentifier(utterance))
        retained[ObjectIdentifier(utterance)] = utterance
        synthesizer.speak(utterance)
    }

    public func speak(sentences: [(blockID: Int, sentence: Sentence)], prefetch: Int) {
        epoch += 1
        epochAtFill = epoch
        ttfwVoiceStarted = false
        ttfwWordDelivered = false
        synthesizer.stopSpeaking(at: .immediate)
        inFlight.removeAll()
        retained.removeAll()
        headTruncation = nil
        currentWordIndex = 0
        heldWord = nil
        prefetchWindow = max(1, prefetch)
        queue = SpeechQueue(sentences: sentences)
        nextToEnqueue = 0
        guard !(queue?.utterances.isEmpty ?? true) else {
            state = .finished
            return
        }
        state = .speaking
        if telemetry.hasActiveRun {
            telemetry.record(TelemetryName.speakEnqueued, fields: [
                "sentences": String(sentences.count),
            ])
        }
        // `stopSpeaking(at: .immediate)` is processed on the synthesizer's own
        // queue. An utterance enqueued in the same turn as the stop is
        // discarded, so the first fill waits for one run-loop turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.epoch == self.epochAtFill, self.state == .speaking else { return }
            self.fillWindow()
        }
    }

    public func pause() {
        hold(reason: .pause)
    }

    public func holdAtWord() {
        hold(reason: .scrub)
    }

    private func hold(reason: SpeechHoldReason) {
        guard state == .speaking else { return }
        epoch += 1
        synthesizer.stopSpeaking(at: .immediate)
        inFlight.removeAll()
        retained.removeAll()
        heldWord = currentWordIndex
        state = .paused
        onProbe?(.held(reason: reason))
    }

    public func resume() {
        guard state == .paused else { return }
        if let word = heldWord {
            heldWord = nil
            restart(fromWord: word)
            return
        }
        if inFlight.isEmpty {
            fillWindow()
            guard !inFlight.isEmpty else {
                state = .finished
                return
            }
            state = .speaking
            return
        }
        synthesizer.continueSpeaking()
        state = .speaking
        onProbe?(.resumed)
    }

    public func stop() {
        epoch += 1
        synthesizer.stopSpeaking(at: .immediate)
        inFlight.removeAll()
        retained.removeAll()
        queue = nil
        headTruncation = nil
        nextToEnqueue = 0
        currentWordIndex = 0
        heldWord = nil
        state = .idle
        onProbe?(.stopped)
    }

    /// Restarts speech at a global word index without restarting the
    /// document. The first utterance is the truncated remainder of its
    /// sentence from that word on; the queue continues from there with the
    /// prefetch window refilled. Returns false when there is no queue to
    /// restart, so the caller can rebuild instead of dying silently. A
    /// paused scrub must keep the queue alive for exactly this reason.
    @discardableResult
    public func restart(fromWord index: Int) -> Bool {
        guard let current = queue, !current.utterances.isEmpty else { return false }
        let clamped = min(max(index, 0), current.totalWords - 1)
        guard let start = current.startPosition(forWord: clamped),
              let position = current.utterances.firstIndex(of: start.utterance)
        else { return false }
        epoch += 1
        heldWord = nil
        synthesizer.stopSpeaking(at: .immediate)
        inFlight.removeAll()
        retained.removeAll()
        let remainder = (start.utterance.text as NSString).substring(from: start.characterOffset)
        headTruncation = remainder.isEmpty ? nil : HeadTruncation(
            position: position,
            text: remainder,
            shift: start.characterOffset
        )
        nextToEnqueue = position
        currentWordIndex = clamped
        state = .speaking
        epochAtFill = epoch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.epoch == self.epochAtFill, self.state == .speaking else { return }
            self.fillWindow()
        }
        return true
    }

    /// Restarts speech at a sentence position. Kept for the sentence-order
    /// scrubber: `init(sentences:)` emits one utterance per sentence in order,
    /// so utterance `index` opens with that sentence's first word.
    @discardableResult
    public func restart(fromUtterance index: Int) -> Bool {
        guard let current = queue, !current.utterances.isEmpty else { return false }
        let clamped = min(max(index, 0), current.utterances.count - 1)
        return restart(fromWord: current.utterances[clamped].firstWordIndex)
    }

    /// Whether a restart has a queue to seek in. False before the first
    /// `speak` and after `stop`, which destroys the queue.
    public var canRestart: Bool {
        queue.map { !$0.utterances.isEmpty } ?? false
    }

    /// Whether any utterance is still with the synthesizer. False after a
    /// suspension kill delivered every cancel, which is the reconcile signal:
    /// a `.speaking` controller with nothing live is lying (F19 1.4).
    public var hasLiveUtterances: Bool {
        !inFlight.isEmpty
    }

    /// Read-only engine truth for the stall probe's sample. Nil is not a case:
    /// the sample always names the current state.
    public var health: SpeechProbeSample {
        SpeechProbeSample(
            state: state,
            isSpeaking: synthesizer.isSpeaking,
            isPaused: synthesizer.isPaused,
            queued: inFlight.count,
            word: currentWordIndex
        )
    }

    // MARK: - Queue

    /// Maps the app speed to the synthesizer rate. `1×` is
    /// `AVSpeechUtteranceDefaultSpeechRate`, clamped to the system range.
    /// This is a linear approximation; the true tempo mapping is a device
    /// measurement (open question Q2).
    private var utteranceRate: Float {
        let scaled = AVSpeechUtteranceDefaultSpeechRate * rate
        return min(max(scaled, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    private func fillWindow() {
        guard let current = queue else { return }
        while nextToEnqueue < current.utterances.count,
              current.shouldEnqueueNext(afterFinished: nextToEnqueue - 1, enqueuedAhead: inFlight.count)
        {
            enqueueNext()
        }
    }

    private func enqueueNext() {
        guard let current = queue, nextToEnqueue < current.utterances.count else { return }
        let utterance = current.utterances[nextToEnqueue]
        let text: String
        if let head = headTruncation, head.position == nextToEnqueue {
            text = head.text
        } else {
            text = utterance.text
        }
        let spoken = AVSpeechUtterance(string: text)
        spoken.rate = utteranceRate
        spoken.voice = voice
        spoken.preUtteranceDelay = 0.0
        let id = ObjectIdentifier(spoken)
        inFlight[id] = InFlight(epoch: epoch, utteranceIndex: nextToEnqueue)
        retained[id] = spoken
        telemetry.record(TelemetryName.speechEnqueue, fields: [
            "utterance": String(nextToEnqueue),
            "inFlight": String(inFlight.count),
        ])
        nextToEnqueue += 1
        synthesizer.speak(spoken)
    }

    // MARK: - Interruption

    private func handleInterruption(_ note: Notification) {
        #if os(iOS)
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            onProbe?(.interrupted(type: raw, state: state))
            switch type {
            case .began:
                if state == .speaking {
                    pausedByInterruption = true
                    hold(reason: .interruption)
                }
            case .ended:
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                defer { pausedByInterruption = false }
                guard pausedByInterruption, options.contains(.shouldResume), state == .paused else { return }
                resume()
            @unknown default:
                break
            }
        #endif
    }
}

// MARK: - Delegate callbacks (run on the main actor via the bridge)

extension AVSpeechController {
    fileprivate func handleDidStart(utteranceID: ObjectIdentifier) {
        // A warm-up is not playback. Its callbacks can arrive out of order
        // (the finish of a single space often beats its own start), and a
        // late start must never promote the controller to `speaking`: that
        // leaves a state that claims to play while nothing is queued, and the
        // transport then swallows the reader's first press.
        guard let entry = inFlight[utteranceID], !warmupIDs.contains(utteranceID) else { return }
        state = .speaking
        onProbe?(.utteranceStarted(utterance: entry.utteranceIndex))
        // M4 phone-side mark: every utterance start, ungated (see TelemetryName).
        telemetry.record(TelemetryName.utteranceStart, fields: [
            "utterance": String(entry.utteranceIndex),
        ])
        if !ttfwVoiceStarted {
            ttfwVoiceStarted = true
            if telemetry.hasActiveRun {
                telemetry.record(TelemetryName.speechDidStart)
            }
        }
    }

    fileprivate func handleWord(range: NSRange, utteranceID: ObjectIdentifier) {
        guard let current = queue,
              let entry = inFlight[utteranceID], entry.epoch == epoch,
              entry.utteranceIndex < current.utterances.count
        else { return }
        let utterance = current.utterances[entry.utteranceIndex]
        var adjusted = range
        // A truncated head utterance speaks from a slice, but the queue maps
        // full utterance coordinates, so shift the reported range back.
        if let head = headTruncation, head.position == entry.utteranceIndex {
            adjusted = NSRange(location: range.location + head.shift, length: range.length)
        }
        guard let word = current.spokenWordRange(reportedRange: adjusted, in: utterance),
              let global = current.wordIndex(reportedRange: adjusted, in: utterance)
        else { return }
        currentWordIndex = global
        onProbe?(.boundary(utterance: entry.utteranceIndex, word: global))
        if !ttfwWordDelivered {
            ttfwWordDelivered = true
            if telemetry.hasActiveRun {
                telemetry.record(TelemetryName.firstWord)
            }
        }
        onWord?(word)
    }

    fileprivate func handleDidFinish(utteranceID: ObjectIdentifier) {
        if warmupIDs.remove(utteranceID) != nil {
            retained.removeValue(forKey: utteranceID)
            if state == .warming { state = .idle }
            return
        }
        guard let entry = inFlight.removeValue(forKey: utteranceID), entry.epoch == epoch else { return }
        retained.removeValue(forKey: utteranceID)
        telemetry.record(TelemetryName.speechDidFinish, fields: [
            "utterance": String(entry.utteranceIndex),
            "inFlight": String(inFlight.count),
            "nextToEnqueue": String(nextToEnqueue),
            "state": String(describing: state),
        ])
        guard let current = queue else { return }
        if current.shouldEnqueueNext(afterFinished: entry.utteranceIndex, enqueuedAhead: inFlight.count),
           nextToEnqueue < current.utterances.count
        {
            enqueueNext()
            return
        }
        if inFlight.isEmpty, nextToEnqueue >= current.utterances.count {
            state = .finished
            onProbe?(.finished)
        }
    }

    fileprivate func handleDidPause(utteranceID: ObjectIdentifier) {
        let tracked = inFlight[utteranceID] != nil
        telemetry.record(TelemetryName.speechDidPause, fields: [
            "tracked": String(tracked),
            "state": String(describing: state),
        ])
        guard tracked else { return }
        if state == .speaking { state = .paused }
    }

    fileprivate func handleDidResume(utteranceID: ObjectIdentifier) {
        let tracked = inFlight[utteranceID] != nil
        telemetry.record(TelemetryName.speechDidResume, fields: [
            "tracked": String(tracked),
            "state": String(describing: state),
        ])
        guard tracked else { return }
        if state == .paused { state = .speaking }
    }

    fileprivate func handleDidCancel(utteranceID: ObjectIdentifier) {
        onProbe?(.cancelled(tracked: inFlight[utteranceID] != nil, state: state))
        if warmupIDs.remove(utteranceID) != nil {
            retained.removeValue(forKey: utteranceID)
            if state == .warming { state = .idle }
            return
        }
        guard let entry = inFlight[utteranceID], entry.epoch == epoch else { return }
        inFlight.removeValue(forKey: utteranceID)
        retained.removeValue(forKey: utteranceID)
        // A cancel for the current epoch means the synthesizer dropped live
        // speech, not a superseded queue: suspension or interruption. The
        // controller must leave `.speaking`, or the button lies (F19 1.4).
        // Stale-epoch cancels return above and change nothing.
        if inFlight.isEmpty, state == .speaking {
            state = .paused
        }
    }
}

/// Nonisolated delegate: AVSpeechSynthesizerDelegate is not actor-isolated,
/// so a @MainActor controller cannot conform directly. The bridge captures
/// only Sendable values (NSRange, ObjectIdentifier) and hops to the main
/// actor, where stale events are no-ops because stop/speak/restart clear the
/// in-flight map and bump the epoch.
private final class SpeechDelegateBridge: NSObject, AVSpeechSynthesizerDelegate {
    weak var owner: AVSpeechController?

    func speechSynthesizer(_: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak owner] in owner?.handleDidStart(utteranceID: id) }
    }

    func speechSynthesizer(
        _: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString range: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak owner] in owner?.handleWord(range: range, utteranceID: id) }
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak owner] in owner?.handleDidFinish(utteranceID: id) }
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak owner] in owner?.handleDidPause(utteranceID: id) }
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didResume utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak owner] in owner?.handleDidResume(utteranceID: id) }
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak owner] in owner?.handleDidCancel(utteranceID: id) }
    }
}
