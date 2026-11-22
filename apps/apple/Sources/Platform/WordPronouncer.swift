import AVFoundation

/// Speaks one word when the reader taps the pronounce control on a card.
///
/// A second synthesizer, not the reader's `AVSpeechController`. The reader's
/// sentence queue, word callbacks and pause snapshot stay untouched, so a
/// pronounce tap cannot change playback state. The engine is the system voice
/// because no pronunciation audio ships in the dictionary pack yet.
@MainActor
final class WordPronouncer {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice = AVSpeechSynthesisVoice(language: "en-US")

    func speak(_ word: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: word)
        utterance.voice = voice
        synthesizer.speak(utterance)
    }
}
