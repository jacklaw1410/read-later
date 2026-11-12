import Foundation
import ReadLaterCore

#if os(macOS)
import CoreServices
#endif

/// Apple built-in dictionary lookup. Never touches the network.
///
/// The product gloss is Traditional Chinese (`zh_HK`). The system's default
/// dictionary on an English machine answers in English, so an English answer is
/// not a gloss here: it is a miss, and the pack offer or the pack itself
/// answers instead. Reading a blob of English dictionary prose aloud on a
/// screen that promises a Chinese gloss is worse than showing the miss card.
///
/// On iOS the system exposes existence only. `dictionaryHasDefinition` says
/// "yes" for nearly every common word, so treating it as a hit answered every
/// tap with an empty card and the pack never ran. A tap with no gloss text is
/// a miss here; the pack is the only source that can render on this platform.
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
        #else
        // No API returns the iOS definition text, and an empty gloss is not a
        // gloss. The pack answers instead.
        return .miss(.notInDictionary)
        #endif
    }

    #if os(macOS)
    /// A Chinese definition for the word, or nil.
    ///
    /// DictionaryServices exposes one entry point and no way to name a
    /// dictionary, so the answer arrives from whatever the reader has installed
    /// and selected. On a machine set to English that answer is an English
    /// paragraph. The script test is what separates "has an entry" from "has an
    /// entry in the language this screen promises".
    private static func macOSDefinition(for word: String) -> String? {
        let cfWord: CFString = word as NSString
        let range = CFRangeMake(0, CFStringGetLength(cfWord))
        guard let unmanaged = DCSCopyTextDefinition(nil, cfWord, range) else { return nil }
        let text = (unmanaged.takeRetainedValue() as String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, containsCJK(text) else { return nil }
        return text
    }

    /// True when the text carries a CJK ideograph. Covers the common blocks, so
    /// a gloss that starts with an English headword and continues in Chinese
    /// still passes.
    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400 ... 0x4DBF,
                 0x4E00 ... 0x9FFF,
                 0xF900 ... 0xFAFF,
                 0x20000 ... 0x2FA1F:
                return true
            default:
                return false
            }
        }
    }
    #endif
}
