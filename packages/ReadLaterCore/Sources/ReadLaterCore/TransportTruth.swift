import Foundation

/// The truth rule for transport state after an halt the app did not ask for.
///
/// Suspension, lock, and interruption can kill synthesiser speech while the
/// controller still reads `.speaking`. A controller that claims to speak with
/// nothing live is lying, and the button then takes a pause branch whose
/// pause no-ops (F19 1.4). The rule: speaking requires live utterances.
/// Anything else reconciles to paused, never to playing.
public enum TransportTruth {
    public static func needsReconcile(state: SpeechState, hasLiveUtterances: Bool) -> Bool {
        state == .speaking && !hasLiveUtterances
    }
}
