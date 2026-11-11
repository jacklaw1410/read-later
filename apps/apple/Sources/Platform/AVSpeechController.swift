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
/// 3. `closeLookup` restores playback below: `continueSpeaking` runs only
///    when the lookup paused live speech, so the card never leaves a dead
///    queue and never starts audio that was already paused.
/// 4. The tick gate (`!scrubbing`, auto-scroll hold) lives in the session,
///    not here: `ReaderSession.handleWord` in RootView.swift drops
///    boundaries while scrubbing and ReaderView gates auto-scroll. This
///    controller delivers every boundary.
@MainActor
public final class AVSpeechController: NSObject, SpeechController {
    private var bridge: SpeechDelegateBridge?
    public var onWord: ((SpokenWordRange) -> Void)?
    public var onStateChange: ((SpeechState) -> Void)?

    /// UI speed multiplier. 1.0 is the reference pace, about 140 words per minute.
    /// A change while speaking restarts from the current word, because the
    /// synthesizer cannot change rate mid-utterance. A change while paused
    /// applies to later utterances; the paused queue is left untouched.
    public var rate: Float = 1.0 {
        didSet {
            guard rate != oldValue, state == .speaking else { return }
            restart(fromWord: currentWordIndex)
        }
    }

    public private(set) var state: SpeechState = .idle {
        didSet {
            if state != oldValue { onStateChange?(state) }
        }
    }

    /// Snapshot taken when a lookup pauses playback. `closeLookup()` restores
    /// the loop from this flag, so a lookup never leaves a dead queue.
    public private(set) var wasPlayingBeforeLookup = false

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
    private var epoch = 0
    private var warmedUp = false
    private var warmupIDs = Set<ObjectIdentifier>()
    private var pausedByInterruption = false
    private var voice: AVSpeechSynthesisVoice?
    private nonisolated(unsafe) var interruptionToken: NSObjectProtocol?

    public override init() {
        voice = Self.defaultVoice()
        super.init()
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
        synthesizer.stopSpeaking(at: .immediate)
        inFlight.removeAll()
        retained.removeAll()
        headTruncation = nil
        currentWordIndex = 0
        prefetchWindow = max(1, prefetch)
        queue = SpeechQueue(sentences: sentences)
        nextToEnqueue = 0
        wasPlayingBeforeLookup = false
        guard !(queue?.utterances.isEmpty ?? true) else {
            state = .finished
            return
        }
        state = .speaking
        fillWindow()
    }

    public func pause() {
        guard state == .speaking, !inFlight.isEmpty else { return }
        synthesizer.pauseSpeaking(at: .word)
        state = .paused
    }

    public func resume() {
        guard state == .paused else { return }
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
        state = .idle
    }

    // MARK: - Lookup pause contract

    public func pauseForLookup() {
        wasPlayingBeforeLookup = (state == .speaking)
        if wasPlayingBeforeLookup {
            synthesizer.pauseSpeaking(at: .word)
            state = .paused
        }
    }

    /// Restores the loop when the card closes: resumes only if playback was
    /// live when the lookup paused, then clears the snapshot.
    public func closeLookup() {
        defer { wasPlayingBeforeLookup = false }
        guard wasPlayingBeforeLookup else { return }
        synthesizer.continueSpeaking()
        state = .speaking
    }

    /// Restarts speech at a global word index without restarting the
    /// document. The first utterance is the truncated remainder of its
    /// sentence from that word on; the queue continues from there with the
    /// prefetch window refilled.
    public func restart(fromWord index: Int) {
        guard let current = queue, !current.utterances.isEmpty else { return }
        let clamped = min(max(index, 0), current.totalWords - 1)
        guard let start = current.startPosition(forWord: clamped),
              let position = current.utterances.firstIndex(of: start.utterance)
        else { return }
        epoch += 1
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
        fillWindow()
    }

    /// Restarts speech at a sentence position. Kept for the sentence-order
    /// scrubber: `init(sentences:)` emits one utterance per sentence in order,
    /// so utterance `index` opens with that sentence's first word.
    public func restart(fromSentence index: Int) {
        guard let current = queue, !current.utterances.isEmpty else { return }
        let clamped = min(max(index, 0), current.utterances.count - 1)
        restart(fromWord: current.utterances[clamped].firstWordIndex)
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
        nextToEnqueue += 1
        synthesizer.speak(spoken)
    }

    // MARK: - Interruption

    private func handleInterruption(_ note: Notification) {
        #if os(iOS)
            guard let raw = note.userInfo?[AVAudioSession.interruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            switch type {
            case .began:
                if state == .speaking {
                    pausedByInterruption = true
                    synthesizer.pauseSpeaking(at: .word)
                    state = .paused
                }
            case .ended:
                let options = (note.userInfo?[AVAudioSession.interruptionOptionKey] as? UInt)
                    .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                defer { pausedByInterruption = false }
                guard pausedByInterruption, options.contains(.shouldResume), state == .paused else { return }
                synthesizer.continueSpeaking()
                state = .speaking
            @unknown default:
                break
            }
        #endif
    }
}

// MARK: - Delegate callbacks (run on the main actor via the bridge)

extension AVSpeechController {
    fileprivate func handleDidStart(utteranceID: ObjectIdentifier) {
        guard inFlight[utteranceID] != nil || warmupIDs.contains(utteranceID) else { return }
        if state == .warming { return }
        state = .speaking
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
        guard let current = queue else { return }
        if current.shouldEnqueueNext(afterFinished: entry.utteranceIndex, enqueuedAhead: inFlight.count),
           nextToEnqueue < current.utterances.count
        {
            enqueueNext()
            return
        }
        if inFlight.isEmpty, nextToEnqueue >= current.utterances.count {
            state = .finished
        }
    }

    fileprivate func handleDidPause(utteranceID: ObjectIdentifier) {
        guard inFlight[utteranceID] != nil else { return }
        if state == .speaking { state = .paused }
    }

    fileprivate func handleDidResume(utteranceID: ObjectIdentifier) {
        guard inFlight[utteranceID] != nil else { return }
        if state == .paused { state = .speaking }
    }

    fileprivate func handleDidCancel(utteranceID: ObjectIdentifier) {
        if warmupIDs.remove(utteranceID) != nil {
            retained.removeValue(forKey: utteranceID)
            if state == .warming { state = .idle }
            return
        }
        guard let entry = inFlight[utteranceID], entry.epoch == epoch else { return }
        inFlight.removeValue(forKey: utteranceID)
        retained.removeValue(forKey: utteranceID)
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
