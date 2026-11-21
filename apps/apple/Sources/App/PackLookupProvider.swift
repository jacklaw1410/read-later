import ReadLaterCore

/// A lookup that asks the system dictionary and, when installed, the pack.
///
/// Order is the research order: the system dictionary first, the installed pack
/// second. A token that cannot be a headword never reaches either.
@MainActor
final class PackLookupProvider: LookupProvider {
    private let apple: AppleDictionaryLookup
    private let packs: any CapabilityPacks

    init(packs: any CapabilityPacks, apple: AppleDictionaryLookup = AppleDictionaryLookup()) {
        self.packs = packs
        self.apple = apple
    }

    func lookup(_ word: String) async -> LookupOutcome {
        guard TokenShape.shape(of: word) == .word else { return .miss(.notAWord) }
        if case let .hit(result) = await apple.lookup(word) {
            return .hit(result)
        }
        if let entry = packs.lookup(word) {
            return .hit(entry)
        }
        return .miss(.notInDictionary)
    }
}
