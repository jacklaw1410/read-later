import AVFoundation
import Foundation
import ReadLaterCore

/// Sentence-queue speech. Word boundaries come from
/// `speechSynthesizer(_:willSpeakRangeOfSpeechString:utterance:)`, which
/// delivers an NSRange into the utterance string; the offset is shifted by
/// the sentence start so the reported range addresses the block text.
@MainActor
public final class AVSpeechController: NSObject, SpeechController {
    private var bridge: SpeechDelegateBridge?
    public var onWord: ((SpokenWordRange) -> Void)?
    public var onStateChange: ((SpeechState) -> Void)?

    /// UI speed multiplier. 1.0 is the reference pace, about 140 words per minute.
    public var rate: Float = 1.0

    public private(set) var state: SpeechState = .idle {
        didSet {
            if state != oldValue { onStateChange?(state) }
        }
    }

    /// Snapshot taken when a lookup pauses playback. `closeLookup()` restores
    /// the loop from this flag, so a lookup never leaves a dead timer.
    public private(set) var wasPlayingBeforeLookup = false

    private struct Entry {
        var blockID: Int
        var sentence: Sentence
        var queuePosition: Int
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var entries: [Entry] = []
    /// Absolute sentence index per in-flight utterance.
    private var utteranceIndex: [ObjectIdentifier: Int] = [:]
    /// Absolute index of the next sentence not yet enqueued.
    private var nextToEnqueue = 0
    /// Absolute index of entries[0] in the document order.
    private var indexBase = 0
    private var warmedUp = false
    private var warmupIDs = Set<ObjectIdentifier>()
    private var voice: AVSpeechSynthesisVoice?

    public override init() {
        super.init()
        let bridge = SpeechDelegateBridge()
        bridge.owner = self
        self.bridge = bridge
        synthesizer.delegate = bridge
        voice = AVSpeechSynthesisVoice(language: "en-US") ?? AVSpeechSynthesisVoice(language: "en")
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    // MARK: - SpeechController

    /// Pre-warms the synthesizer and voice so the first real word arrives
    /// without a stall. Cold start measured 1,139.7 ms against a 700 ms gate.
    public func warmUp() {
        guard !warmedUp else { return }
        warmedUp = true
        state = .warming
        let utterance = AVSpeechUtterance(string: " ")
        utterance.rate = utteranceRate
        utterance.voice = voice
        warmupIDs.insert(ObjectIdentifier(utterance))
        synthesizer.speak(utterance)
    }

    public func speak(sentences: [(blockID: Int, sentence: Sentence)], prefetch: Int) {
        synthesizer.stopSpeaking(at: .immediate)
        utteranceIndex.removeAll()
        indexBase = 0
        entries = sentences.enumerated().map { position, pair in
            Entry(blockID: pair.blockID, sentence: pair.sentence, queuePosition: position)
        }
        nextToEnqueue = 0
        wasPlayingBeforeLookup = false
        guard !entries.isEmpty else {
            state = .finished
            return
        }
        state = .speaking
        for _ in 0 ..< min(max(prefetch, 1), entries.count) {
            enqueueNext()
        }
    }

    public func pause() {
        guard state == .speaking else { return }
        synthesizer.pauseSpeaking(at: .word)
        state = .paused
    }

    public func resume() {
        guard state == .paused else { return }
        synthesizer.continueSpeaking()
        state = .speaking
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        utteranceIndex.removeAll()
        entries.removeAll()
        nextToEnqueue = 0
        indexBase = 0
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

    /// Restarts speech at an absolute sentence index, keeping the prefetch window full.
    public func restart(fromSentence index: Int) {
        guard !entries.isEmpty else { return }
        let clamped = min(max(index, indexBase), indexBase + entries.count - 1)
        let suffix = entries
            .filter { indexBase + $0.queuePosition >= clamped }
            .map { (blockID: $0.blockID, sentence: $0.sentence) }
        synthesizer.stopSpeaking(at: .immediate)
        utteranceIndex.removeAll()
        indexBase = clamped
        entries = suffix.enumerated().map { position, pair in
            Entry(blockID: pair.blockID, sentence: pair.sentence, queuePosition: position)
        }
        nextToEnqueue = 0
        guard !entries.isEmpty else {
            state = .finished
            return
        }
        state = .speaking
        for _ in 0 ..< min(2, entries.count) {
            enqueueNext()
        }
    }

    // MARK: - Queue

    private var utteranceRate: Float {
        min(max(0.5 * rate, 0.0), 1.0)
    }

    private func enqueueNext() {
        guard nextToEnqueue < entries.count else { return }
        let entry = entries[nextToEnqueue]
        let utterance = AVSpeechUtterance(string: entry.sentence.text)
        utterance.rate = utteranceRate
        utterance.voice = voice
        utterance.preUtteranceDelay = 0.0
        utteranceIndex[ObjectIdentifier(utterance)] = indexBase + entry.queuePosition
        nextToEnqueue += 1
        synthesizer.speak(utterance)
    }
}

// MARK: - Delegate callbacks (run on the main actor via the bridge)

extension AVSpeechController {
    fileprivate func handleDidStart(utteranceID: ObjectIdentifier) {
        guard utteranceIndex[utteranceID] != nil || warmupIDs.contains(utteranceID) else { return }
        if state == .warming { return }
        state = .speaking
    }

    fileprivate func handleWord(range: NSRange, utteranceID: ObjectIdentifier) {
        guard let absolute = utteranceIndex[utteranceID],
              let position = entries.firstIndex(where: { indexBase + $0.queuePosition == absolute })
        else { return }
        let entry = entries[position]
        let offset = entry.sentence.offset
        let blockRange = NSRange(location: offset + range.location, length: range.length)
        onWord?(SpokenWordRange(range: blockRange, sentenceIndex: absolute, sentenceOffset: offset))
    }

    fileprivate func handleDidFinish(utteranceID: ObjectIdentifier) {
        if warmupIDs.remove(utteranceID) != nil {
            if state == .warming { state = .idle }
            return
        }
        guard let absolute = utteranceIndex.removeValue(forKey: utteranceID) else { return }
        let lastAbsolute = indexBase + (entries.map(\.queuePosition).max() ?? 0)
        if absolute >= lastAbsolute {
            state = .finished
            return
        }
        enqueueNext()
    }

    fileprivate func handleDidPause(utteranceID: ObjectIdentifier) {
        guard utteranceIndex[utteranceID] != nil else { return }
        if state == .speaking { state = .paused }
    }

    fileprivate func handleDidResume(utteranceID: ObjectIdentifier) {
        guard utteranceIndex[utteranceID] != nil else { return }
        if state == .paused { state = .speaking }
    }

    fileprivate func handleDidCancel(utteranceID: ObjectIdentifier) {
        if warmupIDs.remove(utteranceID) != nil {
            if state == .warming { state = .idle }
            return
        }
        utteranceIndex.removeValue(forKey: utteranceID)
    }
}

/// Nonisolated delegate: AVSpeechSynthesizerDelegate is not actor-isolated,
/// so a @MainActor controller cannot conform directly. The bridge captures
/// only Sendable values (NSRange, ObjectIdentifier) and hops to the main
/// actor, where stale events are no-ops because stop/speak clear the map.
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
