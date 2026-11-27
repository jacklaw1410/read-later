#if DEBUG
import Foundation
import ReadLaterCore

/// A voice with a clock but no audio. It emits the same `SpokenWordRange` the
/// synthesizer emits, so the wash, the progress store, the player bar and the
/// pause/resume contract run unchanged.
///
/// Used by `--debug.voice=scripted`. The interval is a fixed number of
/// milliseconds per word divided by the speed, so a speed change is visible in
/// the state without making a test wait on real speech.
///
/// `Sentence.offset` counts Characters; the block text is not available here,
/// so it is used as a UTF-16 offset. The two agree for the bundled article and
/// for raw-text fixtures, which are all in the basic plane. A corpus with
/// characters outside it would need the block text as well.
@MainActor
final class ScriptedSpeechController: SpeechController {
    var onWord: ((SpokenWordRange) -> Void)?
    var onStateChange: ((SpeechState) -> Void)?

    private(set) var state: SpeechState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    var rate: Float = 1

    private let millisecondsPerWord: Int
    private var words: [ScriptedWord] = []
    private var firstWordOfUtterance: [Int] = []
    private var cursor = 0
    private var task: Task<Void, Never>?

    private struct ScriptedWord {
        let range: NSRange
        let utteranceIndex: Int
        let sentenceOffset: Int
    }

    init(millisecondsPerWord: Int) {
        self.millisecondsPerWord = max(1, millisecondsPerWord)
    }

    func warmUp() {
        // No synthesizer to pre-warm. The first press starts at once, which is
        // what the reader sees with a warm system voice.
    }

    func speak(sentences: [(blockID: Int, sentence: Sentence)], prefetch: Int) {
        task?.cancel()
        task = nil
        words = []
        firstWordOfUtterance = []
        cursor = 0

        for (index, entry) in sentences.enumerated() {
            firstWordOfUtterance.append(words.count)
            let base = entry.sentence.offset
            for range in SpokenWordNumbering.wordRanges(in: entry.sentence.text, base: base) {
                words.append(ScriptedWord(range: range, utteranceIndex: index, sentenceOffset: base))
            }
        }

        guard !words.isEmpty else {
            state = .idle
            return
        }
        state = .speaking
        startTask()
    }

    func pause() {
        guard state == .speaking else { return }
        task?.cancel()
        task = nil
        state = .paused
    }

    func holdAtWord() {
        pause()
    }

    func resume() {
        guard state == .paused else { return }
        state = .speaking
        startTask()
    }

    func stop() {
        task?.cancel()
        task = nil
        cursor = 0
        state = .idle
    }

    var canRestart: Bool {
        !words.isEmpty
    }

    @discardableResult
    func restart(fromWord index: Int) -> Bool {
        guard canRestart else { return false }
        task?.cancel()
        task = nil
        cursor = min(max(index, 0), words.count - 1)
        state = .speaking
        startTask()
        return true
    }

    @discardableResult
    func restart(fromUtterance index: Int) -> Bool {
        guard !firstWordOfUtterance.isEmpty else { return false }
        let clamped = min(max(index, 0), firstWordOfUtterance.count - 1)
        return restart(fromWord: firstWordOfUtterance[clamped])
    }

    var hasLiveUtterances: Bool {
        state == .speaking || state == .paused
    }

    // MARK: - Clock

    private func startTask() {
        task?.cancel()
        let interval = max(
            1,
            Int((Double(millisecondsPerWord) / Double(max(rate, 0.1))).rounded())
        )
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.state == .speaking else { return }
                guard self.cursor < self.words.count else {
                    self.finish()
                    return
                }
                let word = self.words[self.cursor]
                self.onWord?(
                    SpokenWordRange(
                        range: word.range,
                        utteranceIndex: word.utteranceIndex,
                        sentenceOffset: word.sentenceOffset
                    )
                )
                self.cursor += 1
                // Yield between words so the run loop can draw and the test
                // can tap. Cancellation stops the loop at the next check.
                try? await Task.sleep(for: .milliseconds(interval))
            }
        }
    }

    private func finish() {
        task = nil
        state = .finished
    }
}
#endif
