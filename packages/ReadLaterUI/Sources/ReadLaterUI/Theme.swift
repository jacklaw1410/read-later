import SwiftUI

/// Calm Editorial design tokens.
///
/// The values live in `design/tokens.json`. `tools/tokens/generate.py` turns
/// that file into `Generated/ThemeTokens.swift` for this platform, and into
/// CSS, Kotlin and XAML for the others. This file holds only the resolver the
/// generated tokens call, plus the UIKit and AppKit adapters that a text engine
/// needs before SwiftUI can resolve a colour.
///
/// A view reads a semantic name (`Theme.ink`, `Theme.screenGutter`). Never add
/// a hex or a point here: change the JSON and regenerate.
public enum Theme {
    /// Resolves a light/dark pair at render time. Called by generated tokens.
    static func themedColor(light: UInt32, dark: UInt32) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { trait in
            UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light)
        })
        #elseif canImport(AppKit)
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
        #else
        Color(hex: light)
        #endif
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

#if canImport(UIKit)
import UIKit

extension Theme {
    /// Dynamic platform colors for layout-manager temporary attributes.
    ///
    /// The text system needs a `UIColor` before SwiftUI resolves the colour, so
    /// these read the generated hex pairs rather than spelling a value.
    public static var platformInk: UIColor { uiColor(inkHex) }

    public static var platformWashBackground: UIColor { uiColor(currentWordBgHex) }

    public static var platformWashForeground: UIColor { uiColor(currentWordInkHex) }

    public static var platformSerifBody: UIFont {
        let base = UIFont.systemFont(ofSize: bodySize, weight: .regular)
        guard let serif = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: serif, size: bodySize)
    }

    /// Builds a trait-aware `UIColor` from a generated light/dark pair.
    static func uiColor(_ pair: (light: UInt32, dark: UInt32)) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: pair.dark) : UIColor(hex: pair.light) }
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
#endif

#if canImport(AppKit)
import AppKit

extension Theme {
    public static var platformInk: NSColor { nsColor(inkHex) }

    public static var platformWashBackground: NSColor { nsColor(currentWordBgHex) }

    public static var platformWashForeground: NSColor { nsColor(currentWordInkHex) }

    public static var platformSerifBody: NSFont {
        let base = NSFont.systemFont(ofSize: bodySize, weight: .regular)
        guard let serif = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: serif, size: bodySize) ?? base
    }

    /// Builds an appearance-aware `NSColor` from a generated light/dark pair.
    static func nsColor(_ pair: (light: UInt32, dark: UInt32)) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: pair.dark)
                : NSColor(hex: pair.light)
        }
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
#endif
