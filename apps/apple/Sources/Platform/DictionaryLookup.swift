import Foundation
import ReadLaterCore

#if os(macOS)
import CoreServices
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Apple built-in dictionary lookup. Never touches the network.
public struct AppleDictionaryLookup: LookupProvider, Sendable {
    public init() {}

    public func lookup(_ word: String) async -> LookupOutcome {
        let token = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TokenShape.shape(of: token) == .word else {
            return .miss(.notAWord)
        }
        #if os(macOS)
        if let gloss = Self.macOSDefinition(for: token) {
            return .hit(LookupResult(word: token, gloss: gloss, source: .apple))
        }
        return .miss(.notInDictionary)
        #elseif canImport(UIKit)
        if UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: token) {
            // iOS exposes existence only; the gloss renders in the system view.
            return .hit(LookupResult(word: token, gloss: "", source: .apple))
        }
        return .miss(.notInDictionary)
        #else
        return .miss(.notInDictionary)
        #endif
    }

    #if os(macOS)
    private static func macOSDefinition(for word: String) -> String? {
        let cfWord: CFString = word as NSString
        let range = CFRangeMake(0, CFStringGetLength(cfWord))
        guard let unmanaged = DCSCopyTextDefinition(nil, cfWord, range) else { return nil }
        let definition = unmanaged.takeRetainedValue() as String
        return definition.isEmpty ? nil : definition
    }
    #endif
}
