import SwiftUI

/// The reader's appearance choice. The tokens already carry a light and a dark
/// value for every colour, so this only decides which pair SwiftUI resolves.
///
/// `system` follows the OS. The other two pin the whole app, including sheets,
/// because the value is applied once at the root.
public enum Appearance: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    /// The `UserDefaults` key. One key, read by the root and by Settings.
    public static let storageKey = "rl-appearance"

    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// What the root hands to `preferredColorScheme`. `nil` follows the OS.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Reads the stored choice. An unknown or absent value reads as `system`,
    /// so a downgrade never leaves the app on a value it cannot show.
    public static func stored(in defaults: UserDefaults = .standard) -> Appearance {
        defaults.string(forKey: storageKey).flatMap(Appearance.init(rawValue:)) ?? .system
    }
}
