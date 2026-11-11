import ReadLaterCore
import ReadLaterUI
import SwiftUI

/// Playback + lookup state for the sample document. Owns the wash position,
/// the scrub gate, and the lookup pause contract.
@MainActor
final class ReaderSession: ObservableObject {
    @Published var wash: WashPosition?
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var speed: Float = 1.0
    @Published var isScrubbing = false
    @Published var autoScroll = true
    @Published var card: LookupCardState?

    let document: ReadLaterCore.Document
    let speech: AVSpeechController
    let lookupProvider: AppleDictionaryLookup
    /// Stubbed until the pack installer ships: no pack installed, device online.
    let packInstalled = false
    let isOnline = true

    private let sentences: [(blockID: Int, sentence: Sentence)]
    private let blockBySentence: [Int: Int]
    private var currentSentence = 0

    init(document: ReadLaterCore.Document, speech: AVSpeechController, lookupProvider: AppleDictionaryLookup) {
        self.document = document
        self.speech = speech
        self.lookupProvider = lookupProvider
        let pairs = document.spokenSentences
        self.sentences = pairs
        var mapping: [Int: Int] = [:]
        for (position, pair) in pairs.enumerated() {
            mapping[position] = pair.blockID
        }
        self.blockBySentence = mapping
        speech.onWord = { [weak self] word in self?.handleWord(word) }
        speech.onStateChange = { [weak self] state in
            self?.isPlaying = (state == .speaking)
        }
    }

    static func makeSample() -> ReaderSession {
        ReaderSession(
            document: SampleDocument.make(),
            speech: AVSpeechController(),
            lookupProvider: AppleDictionaryLookup()
        )
    }

    func warmUp() {
        speech.warmUp()
    }

    func togglePlay() {
        if isPlaying {
            speech.pause()
            return
        }
        switch speech.state {
        case .paused:
            speech.resume()
        case .finished:
            currentSentence = 0
            speech.speak(sentences: sentences)
        default:
            speech.speak(sentences: sentences)
        }
    }

    func setSpeed(_ value: Float) {
        speed = value
        speech.rate = value
    }

    func scrub(to fraction: Double) {
        guard !sentences.isEmpty else { return }
        let index = min(Int(fraction * Double(sentences.count)), sentences.count - 1)
        currentSentence = index
        progress = Double(index) / Double(max(sentences.count - 1, 1))
        if isPlaying || speech.state == .paused {
            speech.restart(fromSentence: index)
        }
    }

    func tapped(word: String, blockID _: Int) {
        speech.pauseForLookup()
        let token = word
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.lookupProvider.lookup(token)
            await MainActor.run {
                switch outcome {
                case let .hit(result):
                    self.card = LookupCardState.hit(result)
                case let .miss(kind):
                    self.card = LookupCardState.miss(word: token, kind: kind)
                }
            }
        }
    }

    func closeLookup() {
        card = nil
        // Restores playback iff it was live before the tap.
        speech.closeLookup()
    }

    // MARK: - Word boundary tick

    /// Wash advances only when not scrubbing; auto-scroll is gated separately
    /// in ReaderView. A scrub never moves the highlight under the thumb.
    private func handleWord(_ word: SpokenWordRange) {
        guard !isScrubbing else { return }
        currentSentence = word.sentenceIndex
        guard let blockID = blockBySentence[word.sentenceIndex] else { return }
        wash = WashPosition(blockID: blockID, range: word.range)
        progress = Double(word.sentenceIndex) / Double(max(sentences.count - 1, 1))
    }
}

/// One lookup card render. Hit carries the result; miss carries the tapped word.
enum LookupCardState: Identifiable {
    case hit(LookupResult)
    case miss(word: String, kind: MissKind)

    var id: String {
        switch self {
        case let .hit(result): return "hit-\(result.word)"
        case let .miss(word, _): return "miss-\(word)"
        }
    }
}
