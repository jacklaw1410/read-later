import Foundation

/// Pack install states.
/// Source of truth: read-later-research/spec/dictionary-packs.md §3,
/// repeated in read-later-research/spec/state-machines.md §9.
public enum InstallState: Sendable, Equatable {
    case absent
    case offered
    case downloading
    case paused
    case verifying
    case installed(version: String)
    case failedHash
    case failedCorrupt
    case failedNetwork
    case failedRegistry
    case failedDisk
    case updateAvailable(version: String)
}

public enum PackTransitionError: Error, Sendable, Equatable {
    case illegal(from: InstallState, to: InstallState)
}

extension PackTransitionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .illegal(let from, let to):
            return "Illegal pack transition from \(from) to \(to)."
        }
    }
}

extension InstallState {
    /// The only legal moves. Every state change must go through
    /// `advance(to:)`; anything this returns false for cannot happen.
    public func canTransition(to next: InstallState) -> Bool {
        switch (self, next) {
        case (.absent, .offered):
            return true
        case (.offered, .downloading):
            return true
        case (.offered, .absent):
            return true
        case (.downloading, .downloading):
            return true
        case (.downloading, .paused):
            return true
        case (.paused, .downloading):
            return true
        case (.downloading, .verifying):
            return true
        case (.verifying, .installed):
            return true
        case (.verifying, .failedHash):
            return true
        case (.verifying, .failedCorrupt):
            return true
        case (.downloading, .failedNetwork):
            return true
        case (.downloading, .failedRegistry):
            return true
        case (.downloading, .failedDisk):
            return true
        case (.failedHash, .offered):
            return true
        case (.failedCorrupt, .offered):
            return true
        case (.failedNetwork, .offered):
            return true
        case (.failedDisk, .offered):
            return true
        case (.failedRegistry, .absent):
            return true
        case (.installed, .updateAvailable):
            return true
        case (.updateAvailable, .downloading):
            return true
        case (.installed, .absent):
            return true
        default:
            return false
        }
    }

    /// The single choke point for state changes. Throws instead of moving
    /// on an illegal transition, so illegal moves are inexpressible in code
    /// that uses this API.
    public mutating func advance(to next: InstallState) throws {
        guard canTransition(to: next) else {
            throw PackTransitionError.illegal(from: self, to: next)
        }
        self = next
    }
}

// MARK: - Card copy

/// Reader-facing action titles. Views use these raw values; no view invents
/// its own string.
public enum CardAction: String, Sendable, CaseIterable {
    case install = "Install"
    case notNow = "Not now"
    case close = "Close"
    case searchWeb = "Search the web ↗"
    case closeAndResume = "Close & resume"
}

/// Every reader-facing pack/miss string in one type.
/// Source of truth: read-later-research/design/miss-state.md for miss and
/// offer copy, read-later-research/spec/dictionary-packs.md §3 for failure
/// copy. No view invents a string.
public enum PackCardCopy {
    // Failure messages (spec/dictionary-packs.md §3, failure table).
    public static let failedNetworkMessage = "Download stopped — no network."
    public static let failedRegistryMessage = "The dictionary list is unavailable."
    public static let failedDiskMessage = "Not enough space (needs 14.47 MiB)."
    public static let failedHashMessage = "Download corrupted — try again."
    public static let failedCorruptMessage = "Dictionary could not be read — try again."

    // Miss-state copy (design/miss-state.md §2.1–§2.2).
    public static let notInDictionary = "Not in dictionary."
    public static let notAWord = "This doesn't look like a word."
    public static let offlineMissMessage = "No offline entry for this word."

    // Pack offer (design/miss-state.md §2.1, §3).
    public static let offerTitle = "English–Chinese dictionary (Traditional)"
    public static let offerMeta = "14.47 MiB · downloads once · works offline"
    public static let offerWayBack = "You can add it later in Settings › Dictionaries."
    public static let offerProvenance = "Source · Apple 譯典通 (built-in) · no entry"
    public static let installedMissProvenance = "Source · Apple 譯典通 (built-in) + English–Chinese pack · no entry"

    public static func message(for state: InstallState) -> String? {
        switch state {
        case .failedNetwork:
            return failedNetworkMessage
        case .failedRegistry:
            return failedRegistryMessage
        case .failedDisk:
            return failedDiskMessage
        case .failedHash:
            return failedHashMessage
        case .failedCorrupt:
            return failedCorruptMessage
        case .absent, .offered, .downloading, .paused, .verifying, .installed, .updateAvailable:
            return nil
        }
    }

    /// Actions the card shows for a state. `failedRegistry` is permanent:
    /// one `Close` action, no retry. The reader cannot repair a broken
    /// deploy, so no retry is shown (spec/dictionary-packs.md §3 rule 6).
    public static func actions(for state: InstallState) -> [CardAction] {
        switch state {
        case .absent:
            return []
        case .offered:
            return [.install, .notNow]
        case .downloading, .paused, .verifying:
            return [.close]
        case .installed:
            return [.close]
        case .failedHash, .failedCorrupt, .failedNetwork, .failedDisk:
            return [.install, .close]
        case .failedRegistry:
            return [.close]
        case .updateAvailable:
            return [.install, .close]
        }
    }
}
