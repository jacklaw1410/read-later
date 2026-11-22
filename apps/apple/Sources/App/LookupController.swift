import Observation
import ReadLaterCore
import ReadLaterStore
import ReadLaterUI

/// One lookup session: the tapped word or note, its card, the voice that was
/// live when the session opened, and the lookup in flight. Views send intents
/// here. This owner is the only place that pauses and resumes speech for a
/// lookup.
@MainActor
@Observable
final class LookupController {
    let state = LookupState<PaperCard, NoteToShow>()
    private(set) var selectedWordIndex: Int?

    private let speech: SpeechController
    private let playback: PlaybackState
    private let lookupProvider: any LookupProvider
    private let packs: any CapabilityPacks
    private let connectivity: Connectivity
    private let telemetry: TelemetryHub

    /// Whether the voice was live when the session opened. Nil while no session
    /// is open. Written once per session, so every later tap reuses it.
    @ObservationIgnored private var wasPlayingAtOpen: Bool?
    /// The lookup in flight. A new tap or a close cancels it, so its result is dropped.
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        speech: SpeechController,
        playback: PlaybackState,
        lookupProvider: any LookupProvider,
        packs: any CapabilityPacks,
        connectivity: Connectivity,
        telemetry: TelemetryHub
    ) {
        self.speech = speech
        self.playback = playback
        self.lookupProvider = lookupProvider
        self.packs = packs
        self.connectivity = connectivity
        self.telemetry = telemetry
    }

    var isOpen: Bool { wasPlayingAtOpen != nil }

    func tap(slot: WordSlot?, word: String) {
        guard state.note == nil else { return }
        // A Hit card blocks taps until Close. A Miss card (or a pending lookup)
        // takes the tap and replaces the card in place.
        if case .some(.hit) = state.card { return }
        let token = TokenShape.trimmed(word)
        guard !token.isEmpty else { return }

        let wasPlaying = openSession()
        selectedWordIndex = slot?.index
        playback.isPlaying = false
        telemetry.record(TelemetryName.lookup, fields: ["word": token])

        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.lookupProvider.lookup(token)
            guard !Task.isCancelled else { return }
            switch outcome {
            case let .hit(result):
                // The source and the line count are the proof that a lookup card
                // carries text: an empty gloss from the wrong source is the
                // defect this field catches.
                self.telemetry.record(
                    TelemetryName.lookupHit,
                    fields: [
                        "source": result.source.rawValue,
                        "lines": String(result.gloss.split(separator: "\n").count),
                    ]
                )
                self.state.card = .hit(result, wordIndex: slot?.index, wasPlaying: wasPlaying)
            case let .miss(kind):
                let refined = self.refine(kind)
                self.telemetry.record(
                    TelemetryName.lookupMiss,
                    fields: ["kind": String(describing: refined)]
                )
                self.state.card = .miss(
                    word: token,
                    kind: refined,
                    wordIndex: slot?.index,
                    wasPlaying: wasPlaying
                )
            }
        }
    }

    func closeCard() {
        guard state.card != nil else { return }
        // Close-request mark for M14: with lookup card.shown (paint) and
        // state.speaking (resume) this splits close-to-resume into test
        // delivery (tap to here) and teardown-plus-resume (here to speaking).
        telemetry.record(TelemetryName.cardClose)
        state.card = nil
        selectedWordIndex = nil
        closeSession()
    }

    func declineOffer() {
        packs.declineOffer()
        closeCard()
    }

    func openNote(_ index: Int) {
        guard state.card == nil, state.note == nil else { return }
        let wasPlaying = openSession()
        playback.isPlaying = false
        state.note = NoteToShow(index: index, wasPlaying: wasPlaying)
    }

    func closeNote() {
        guard state.note != nil else { return }
        state.note = nil
        closeSession()
    }

    /// Ends any open session without restoring playback. The caller stops the voice.
    func cancel() {
        task?.cancel()
        task = nil
        state.card = nil
        state.note = nil
        selectedWordIndex = nil
        wasPlayingAtOpen = nil
    }

    /// Runs the install, then resolves an open miss card in place when the pack lands.
    func installPack() async {
        await packs.install()
        guard packs.isInstalled else {
            connectivity.refresh()
            return
        }

        // The lookup card becomes the answer in place. The reader does not tap again.
        if case let .miss(word, _, wordIndex, wasPlaying) = state.card {
            if case let .hit(result) = await lookupProvider.lookup(word) {
                state.card = .hit(result, wordIndex: wordIndex, wasPlaying: wasPlaying)
            }
        }
    }

    /// A shape refusal is decided before the dictionary is asked, and an
    /// offline miss says so instead of pretending the word is unknown.
    private func refine(_ kind: MissKind) -> MissKind {
        if kind == .notAWord { return .notAWord }
        if connectivity.status == .offline && !packs.isInstalled { return .noNetwork }
        return kind
    }

    /// Pauses the voice on the first call of a session and returns whether it was live.
    /// Later calls return the snapshot without touching speech.
    private func openSession() -> Bool {
        if let wasPlaying = wasPlayingAtOpen { return wasPlaying }
        let wasPlaying = speech.state == .speaking
        wasPlayingAtOpen = wasPlaying
        if wasPlaying { speech.pause() }
        return wasPlaying
    }

    /// Ends the session and resumes the voice only if it was live when the session opened.
    private func closeSession() {
        let wasPlaying = wasPlayingAtOpen ?? false
        wasPlayingAtOpen = nil
        task?.cancel()
        task = nil
        if wasPlaying { speech.resume() }
        playback.isPlaying = wasPlaying && speech.state == .speaking
    }
}
