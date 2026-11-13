// Generated from design/tokens.json by tools/tokens (readlater-tokens). Do not edit.
// A view reads these names. A value change happens in the JSON.

import SwiftUI

public extension Theme {
    // MARK: - Colour (layer 2, bound to this platform)

    /// `page.paper`. Reader and entry background.
    static let paper = themedColor(light: 0xFFFCF7, dark: 0x121417)
    static let paperHex: (light: UInt32, dark: UInt32) = (0xFFFCF7, 0x121417)

    /// `page.surface`. Card, player bar, chrome.
    static let surface = themedColor(light: 0xFFFFFF, dark: 0x1E2226)
    static let surfaceHex: (light: UInt32, dark: UInt32) = (0xFFFFFF, 0x1E2226)

    /// `page.raised`. Hold badge fill, mono chip.
    static let surfaceRaised = themedColor(light: 0xFFF7ED, dark: 0x262B31)
    static let surfaceRaisedHex: (light: UInt32, dark: UInt32) = (0xFFF7ED, 0x262B31)

    /// `text.body`. Prose ink.
    static let ink = themedColor(light: 0x191C1F, dark: 0xE8E6E1)
    static let inkHex: (light: UInt32, dark: UInt32) = (0x191C1F, 0xE8E6E1)

    /// `text.meta`. Subhead, clock, provenance.
    static let inkSecondary = themedColor(light: 0x5B6570, dark: 0xA8B0B8)
    static let inkSecondaryHex: (light: UInt32, dark: UInt32) = (0x5B6570, 0xA8B0B8)

    /// `line.hair`. Divider, field border.
    static let line = themedColor(light: 0xE7E0D9, dark: 0x333A42)
    static let lineHex: (light: UInt32, dark: UInt32) = (0xE7E0D9, 0x333A42)

    /// `brand.link`. Quote rule, track fill, marker ink.
    static let brand = themedColor(light: 0x334E68, dark: 0x7FB3D5)
    static let brandHex: (light: UInt32, dark: UInt32) = (0x334E68, 0x7FB3D5)

    /// `action.fill`. Primary button fill. Stays dark in both modes so white ink keeps its contrast.
    static let actionFill = themedColor(light: 0x334E68, dark: 0x2C4A63)
    static let actionFillHex: (light: UInt32, dark: UInt32) = (0x334E68, 0x2C4A63)

    /// `action.ink`. Ink on a primary button.
    static let actionInk = themedColor(light: 0xFFFFFF, dark: 0xFFFFFF)
    static let actionInkHex: (light: UInt32, dark: UInt32) = (0xFFFFFF, 0xFFFFFF)

    /// `ghost.fill`. Secondary button fill on a card.
    static let ghostFill = themedColor(light: 0xFFFFFF, dark: 0x242A30)
    static let ghostFillHex: (light: UInt32, dark: UInt32) = (0xFFFFFF, 0x242A30)

    /// `wash.fill`. The word the voice is on.
    static let currentWordBg = themedColor(light: 0xFDE68A, dark: 0x854D0E)
    static let currentWordBgHex: (light: UInt32, dark: UInt32) = (0xFDE68A, 0x854D0E)

    /// `wash.ink`. Ink inside the wash.
    static let currentWordInk = themedColor(light: 0x78350F, dark: 0xFDE68A)
    static let currentWordInkHex: (light: UInt32, dark: UInt32) = (0x78350F, 0xFDE68A)

    /// `rule.paused`. Frozen wash fill while paused.
    static let pausedWash = themedColor(light: 0xE8D9B0, dark: 0x4A4030)
    static let pausedWashHex: (light: UInt32, dark: UInt32) = (0xE8D9B0, 0x4A4030)

    /// `rule.ring`. Frozen wash ring while paused.
    static let pausedRing = themedColor(light: 0x8A6D1B, dark: 0xC9A94E)
    static let pausedRingHex: (light: UInt32, dark: UInt32) = (0x8A6D1B, 0xC9A94E)

    /// `mark.selected`. The word the reader tapped.
    static let selection = themedColor(light: 0xDCE9F5, dark: 0x2C4A66)
    static let selectionHex: (light: UInt32, dark: UInt32) = (0xDCE9F5, 0x2C4A66)

    /// `mark.saved`. Saved-phrase rule. Tier 2.
    static let savedMark = themedColor(light: 0x9A3412, dark: 0xFDBA74)
    static let savedMarkHex: (light: UInt32, dark: UInt32) = (0x9A3412, 0xFDBA74)

    /// `mark.savedFill`. Saved-phrase fill. Tier 2.
    static let savedWash = themedColor(light: 0xFFF0E6, dark: 0x3A2A1F)
    static let savedWashHex: (light: UInt32, dark: UInt32) = (0xFFF0E6, 0x3A2A1F)

    /// `skip.surface`. A block the voice skips: it keeps its own surface.
    static let skipSurface = themedColor(light: 0xF7F3EC, dark: 0x1B1F24)
    static let skipSurfaceHex: (light: UInt32, dark: UInt32) = (0xF7F3EC, 0x1B1F24)

    /// `skip.border`. Skip block edge.
    static let skipBorder = themedColor(light: 0xE7E0D9, dark: 0x2C333A)
    static let skipBorderHex: (light: UInt32, dark: UInt32) = (0xE7E0D9, 0x2C333A)

    /// `skip.ink`. Reduced ink inside a skip block.
    static let skipInk = themedColor(light: 0x191C1F, dark: 0xC9CDD2)
    static let skipInkHex: (light: UInt32, dark: UInt32) = (0x191C1F, 0xC9CDD2)

    /// `chip.surface`. Skip chip tile.
    static let chipSurface = themedColor(light: 0xEFE7D3, dark: 0x2E2A20)
    static let chipSurfaceHex: (light: UInt32, dark: UInt32) = (0xEFE7D3, 0x2E2A20)

    /// `chip.ink`. Skip chip label.
    static let chipInk = themedColor(light: 0x7A6A3A, dark: 0xD8C48C)
    static let chipInkHex: (light: UInt32, dark: UInt32) = (0x7A6A3A, 0xD8C48C)

    /// `chip.border`. Skip chip edge.
    static let chipBorder = themedColor(light: 0xE0D3B0, dark: 0x453D2A)
    static let chipBorderHex: (light: UInt32, dark: UInt32) = (0xE0D3B0, 0x453D2A)

    /// `code.inlineSurface`. Inline code fill.
    static let inlineCodeSurface = themedColor(light: 0xF1EDE4, dark: 0x23282E)
    static let inlineCodeSurfaceHex: (light: UInt32, dark: UInt32) = (0xF1EDE4, 0x23282E)

    /// `mark.coincide`. Ring when the tap lands on the spoken word.
    static let coincidenceRing = themedColor(light: 0xB45309, dark: 0xF59E0B)
    static let coincidenceRingHex: (light: UInt32, dark: UInt32) = (0xB45309, 0xF59E0B)

    /// `veil.scrim`. Card dim.
    static let scrim = themedColor(light: 0x191C1F, dark: 0x000000).opacity(0.28)
    static let scrimHex: (light: UInt32, dark: UInt32) = (0x191C1F, 0x000000)

    /// `hold.surface`. Hold badge fill.
    static let holdSurface = themedColor(light: 0xFFF0E6, dark: 0x3A2A1F)
    static let holdSurfaceHex: (light: UInt32, dark: UInt32) = (0xFFF0E6, 0x3A2A1F)

    /// `hold.ink`. Hold badge ink.
    static let holdInk = themedColor(light: 0x9A3412, dark: 0xFDBA74)
    static let holdInkHex: (light: UInt32, dark: UInt32) = (0x9A3412, 0xFDBA74)

    /// `hold.border`. Hold badge edge.
    static let holdBorder = themedColor(light: 0xFDBA74, dark: 0x7C4A1E)
    static let holdBorderHex: (light: UInt32, dark: UInt32) = (0xFDBA74, 0x7C4A1E)

    // MARK: - Type (layer 2)

    /// `body`. Reader prose.
    static func body() -> Font { .system(size: 19, weight: .regular, design: .serif) }
    static let bodySize: CGFloat = 19
    static let bodyLine: CGFloat = 31

    /// `title`. Article title.
    static func title() -> Font { .system(size: 28, weight: .semibold, design: .serif) }
    static let titleSize: CGFloat = 28
    static let titleLine: CGFloat = 34

    /// `heading`. Heading block.
    static func heading() -> Font { .system(size: 22, weight: .semibold, design: .serif) }
    static let headingSize: CGFloat = 22

    /// `caption`. Meta line, provenance.
    static func caption() -> Font { .system(size: 13, weight: .regular, design: .default) }
    static let captionSize: CGFloat = 13

    /// `player`. Player clock.
    static func player() -> Font { .system(size: 15, weight: .regular, design: .default).monospacedDigit() }
    static let playerSize: CGFloat = 15

    /// `lookupWord`. Tapped word in the card.
    static func lookupWord() -> Font { .system(size: 22, weight: .medium, design: .serif) }
    static let lookupWordSize: CGFloat = 22

    /// `gloss`. Gloss text, Traditional Chinese.
    static func gloss() -> Font { .system(size: 17, weight: .regular, design: .default) }
    static let glossSize: CGFloat = 17

    /// `chip`. Skip chip label. Tracking is in em, so it scales with the size.
    static func chip() -> Font { .system(size: 10, weight: .bold, design: .monospaced) }
    static let chipSize: CGFloat = 10
    /// `chip` tracking, in points: 0.088em at 10.
    static let chipTracking: CGFloat = 0.88

    /// `eyebrow`. Small caps label above a field or a block.
    static func eyebrow() -> Font { .system(size: 11, weight: .bold, design: .monospaced) }
    static let eyebrowSize: CGFloat = 11
    /// `eyebrow` tracking, in points: 0.08em at 11.
    static let eyebrowTracking: CGFloat = 0.88

    /// `code`. Code block.
    static func code() -> Font { .system(size: 12, weight: .regular, design: .monospaced) }
    static let codeSize: CGFloat = 12

    /// `note`. Footnote body.
    static func footnote() -> Font { .system(size: 14, weight: .regular, design: .default) }
    static let footnoteSize: CGFloat = 14

    /// `mono`. NOTES label, footnote marker.
    static func mono() -> Font { .system(size: 11, weight: .regular, design: .monospaced) }
    static let monoSize: CGFloat = 11

    // MARK: - Space, shape, size (layer 2)

    /// `inlineGap`. Chip inset, tight pairs.
    static let inlineGap: CGFloat = 4

    /// `controlGap`. Adjacent controls.
    static let controlGap: CGFloat = 8

    /// `stackGap`. Card rows.
    static let stackGap: CGFloat = 12

    /// `paragraphGap`. Between reader blocks.
    static let paragraphGap: CGFloat = 16

    /// `screenGutter`. Page side margin, card padding.
    static let screenGutter: CGFloat = 20

    /// `breathingRoom`. Top room above the title.
    static let breathingRoom: CGFloat = 32

    /// `radius.chip`. Wash chip.
    static let chipRadius: CGFloat = 4

    /// `radius.inner`. Skip inner table.
    static let innerRadius: CGFloat = 8

    /// `radius.button`. Buttons and fields.
    static let buttonRadius: CGFloat = 10

    /// `radius.card`. Card, skip shell, sheet.
    static let cardRadius: CGFloat = 12

    /// `radius.sheet`. Provisional. Sheet top.
    static let sheetRadius: CGFloat = 16

    /// `radius.pill`. Capsule.
    static let pillRadius: CGFloat = 999

    /// `size.playerBar`. Bar height, including the 44 pt hit row.
    static let playerBar: CGFloat = 58

    /// `size.chrome`. Reader top bar.
    static let chrome: CGFloat = 44

    /// `size.minTarget`. Smallest control, both axes.
    static let minTarget: CGFloat = 44

    /// `size.maxLineWidth`. Reading measure.
    static let maxLineWidth: CGFloat = 640

    /// The body line box, minus the type size.
    static let bodyLineSpacing: CGFloat = 12
}

/// Motion, layer 2. Built from the numbers, not from a name.
public enum ThemeMotion {
    /// `motion.wash`. linear
    public static let wash = Animation.linear(duration: 0.150)

    /// `motion.sheet`. easeInOut
    public static let sheet = Animation.timingCurve(0.42, 0, 0.58, 1, duration: 0.180)

    /// `motion.screen`. easeInOut
    public static let screen = Animation.timingCurve(0.42, 0, 0.58, 1, duration: 0.180)

    /// `motion.entryProgress`. easeInOut
    public static let entryProgress = Animation.timingCurve(0.42, 0, 0.58, 1, duration: 0.300)

}
