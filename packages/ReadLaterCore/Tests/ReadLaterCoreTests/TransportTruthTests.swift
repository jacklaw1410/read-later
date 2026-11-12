import Testing

@testable import ReadLaterCore

/// The reconcile rule (F19 1.4): speaking requires live utterances.
@Test func speakingWithNothingLiveNeedsReconcile() {
    #expect(TransportTruth.needsReconcile(state: .speaking, hasLiveUtterances: false))
}

@Test func speakingWithLiveUtterancesIsTruthful() {
    #expect(!TransportTruth.needsReconcile(state: .speaking, hasLiveUtterances: true))
}

@Test func nonSpeakingStatesNeverReconcile() {
    for state: SpeechState in [.idle, .warming, .paused, .finished] {
        #expect(!TransportTruth.needsReconcile(state: state, hasLiveUtterances: false))
        #expect(!TransportTruth.needsReconcile(state: state, hasLiveUtterances: true))
    }
}
