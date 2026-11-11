import SwiftUI

/// Calm Editorial design tokens. Single source of truth for both platforms.
/// Values from spec/target-design.md §4. Light/dark pairs resolve at render time.
public enum Theme {
    // MARK: - Color

    public static let paper = themed(light: 0xFFFCF7, dark: 0x121417)
    public static let surface = themed(light: 0xFFFFFF, dark: 0x1E2226)
    public static let surfaceRaised = themed(light: 0xFFF7ED, dark: 0x262B31)
    public static let ink = themed(light: 0x191C1F, dark: 0xE8E6E1)
    public static let inkSecondary = themed(light: 0x5B6570, dark: 0xA8B0B8)
    public static let line = themed(light: 0xE7E0D9, dark: 0x333A42)
    public static let brand = themed(light: 0x334E68, dark: 0x7FB3D5)

    /// The fill behind a primary action, and the ink on it.
    ///
    /// `brand` lightens in dark mode so it reads as a link colour, and white on
    /// pale blue is unreadable. These two tokens stay a dark slate and pure
    /// white in both modes, so the primary button has the same contrast either
    /// way. Source: protoype `--brand` + white label.
    public static let actionFill = themed(light: 0x334E68, dark: 0x2C4A63)
    public static let actionInk = themed(light: 0xFFFFFF, dark: 0xFFFFFF)
    /// A ghost action's fill. Sits on the card, so it is the card surface plus
    /// a line, never a second grey.
    public static let ghostFill = themed(light: 0xFFFFFF, dark: 0x242A30)

    /// Current word while playing: amber fill + dark amber ink.
    public static let currentWordBg = themed(light: 0xFDE68A, dark: 0x854D0E)
    public static let currentWordInk = themed(light: 0x78350F, dark: 0xFDE68A)
    /// Frozen position while paused: grey-amber + ring, never alpha-only.
    public static let pausedWash = themed(light: 0xE8D9B0, dark: 0x4A4030)
    public static let pausedRing = themed(light: 0x8A6D1B, dark: 0xC9A94E)
    /// Tapped-word selection.
    public static let selection = themed(light: 0xDCE9F5, dark: 0x2C4A66)
    public static let savedMark = themed(light: 0x9A3412, dark: 0xFDBA74)
    public static let savedWash = themed(light: 0xFFF0E6, dark: 0x3A2A1F)

    /// A block the voice will not read: reduced ink, never bare grey.
    /// Opacity alone loses the block's edges, so it keeps its own surface.
    public static let skipSurface = themed(light: 0xF7F3EC, dark: 0x1B1F24)
    public static let skipBorder = themed(light: 0xE7E0D9, dark: 0x2C333A)
    public static let skipInk = themed(light: 0x191C1F, dark: 0xC9CDD2)
    public static let chipSurface = themed(light: 0xEFE7D3, dark: 0x2E2A20)
    public static let chipInk = themed(light: 0x7A6A3A, dark: 0xD8C48C)
    public static let chipBorder = themed(light: 0xE0D3B0, dark: 0x453D2A)
    public static let inlineCodeSurface = themed(light: 0xF1EDE4, dark: 0x23282E)

    /// Tapped and spoken at the same time: blue fill, amber ring.
    public static let coincidenceRing = themed(light: 0xB45309, dark: 0xF59E0B)
    public static let scrim = themed(light: 0x191C1F, dark: 0x000000).opacity(0.28)
    public static let holdSurface = themed(light: 0xFFF0E6, dark: 0x3A2A1F)
    public static let holdInk = themed(light: 0x9A3412, dark: 0xFDBA74)
    public static let holdBorder = themed(light: 0xFDBA74, dark: 0x7C4A1E)

    private static func themed(light: UInt32, dark: UInt32) -> Color {
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

    // MARK: - Type

    /// Reader body: 19 pt serif on a 31 pt line (12 pt leading).
    public static func body() -> Font { .system(size: 19, weight: .regular, design: .serif) }
    public static func title() -> Font { .system(size: 28, weight: .semibold, design: .serif) }
    public static func caption() -> Font { .system(size: 13, weight: .regular, design: .default) }
    public static func player() -> Font { .system(size: 15, weight: .regular, design: .default).monospacedDigit() }
    public static func lookupWord() -> Font { .system(size: 22, weight: .medium, design: .serif) }
    public static func gloss() -> Font { .system(size: 17, weight: .regular, design: .default) }

    /// A reduced-ink block's label: small, monospaced, uppercase, tracked.
    public static func chip() -> Font { .system(size: ReaderMetrics.chipSize, weight: .bold, design: .monospaced) }
    public static func code() -> Font { .system(size: ReaderMetrics.codeSize, weight: .regular, design: .monospaced) }
    public static func footnote() -> Font { .system(size: ReaderMetrics.footnoteSize, weight: .regular, design: .default) }
    /// The clock and the speed label. Tabular figures keep the width steady.
    public static func mono() -> Font { .system(size: 11, weight: .regular, design: .monospaced) }

    // MARK: - Spacing

    public static let paragraphGap: CGFloat = 16
    public static let screenGutter: CGFloat = 20
    public static let breathingRoom: CGFloat = 32
    public static let cardRadius: CGFloat = 12
    public static let minTarget: CGFloat = 44
    public static let maxLineWidth: CGFloat = 640
    /// 19 pt type on a 31 pt line.
    public static let bodyLineSpacing: CGFloat = 12
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
    public static var platformInk: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xE8E6E1) : UIColor(hex: 0x191C1F) }
    }

    public static var platformWashBackground: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x854D0E) : UIColor(hex: 0xFDE68A) }
    }

    public static var platformWashForeground: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xFDE68A) : UIColor(hex: 0x78350F) }
    }

    public static var platformSerifBody: UIFont {
        let base = UIFont.systemFont(ofSize: 19, weight: .regular)
        guard let serif = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: serif, size: 19)
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
    /// Dynamic platform colors for layout-manager temporary attributes.
    public static var platformInk: NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: 0xE8E6E1) : NSColor(hex: 0x191C1F) }
    }

    public static var platformWashBackground: NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: 0x854D0E) : NSColor(hex: 0xFDE68A) }
    }

    public static var platformWashForeground: NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: 0xFDE68A) : NSColor(hex: 0x78350F) }
    }

    public static var platformSerifBody: NSFont {
        let base = NSFont.systemFont(ofSize: 19, weight: .regular)
        guard let serif = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: serif, size: 19) ?? base
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
