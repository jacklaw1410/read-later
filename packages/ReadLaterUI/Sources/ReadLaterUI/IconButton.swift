import SwiftUI

/// The three icon button looks. Each one is a design decision, not a size.
public enum IconButtonVariant: Sendable {
    /// No surface, text ink. Top bar, rows and settings.
    case quiet
    /// Primary fill on a rounded square, the same pair as the primary button.
    case filled
    /// Primary fill on a circle. The one exception: play.
    case circle
}

/// An icon and its box, with no action. Use it as a `Menu` label, where a
/// `Button` would nest inside the menu.
///
/// The box is `Theme.minTarget` on each side and takes every tap. The glyph
/// is `Theme.icon()`, so the size and weight come from `typography.icon`.
public struct IconGlyph: View {
    private let systemName: String
    private let variant: IconButtonVariant

    public init(systemName: String, variant: IconButtonVariant = .quiet) {
        self.systemName = systemName
        self.variant = variant
    }

    public var body: some View {
        Image(systemName: systemName)
            .font(Theme.icon())
            .foregroundStyle(variant.ink)
            .frame(width: Theme.minTarget, height: Theme.minTarget)
            .background { surface }
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var surface: some View {
        switch variant {
        case .quiet:
            Color.clear
        case .filled:
            RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .fill(Theme.actionFill)
        case .circle:
            Circle()
                .fill(Theme.actionFill)
        }
    }
}

/// An icon-only action. The label is required, because a glyph has no text
/// for VoiceOver to read.
public struct IconButton: View {
    private let systemName: String
    private let label: String
    private let variant: IconButtonVariant
    private let action: () -> Void

    public init(
        systemName: String,
        label: String,
        variant: IconButtonVariant = .quiet,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.label = label
        self.variant = variant
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            IconGlyph(systemName: systemName, variant: variant)
        }
        .buttonStyle(IconButtonStyle(variant: variant))
        .accessibilityLabel(label)
    }
}

extension IconButtonVariant {
    /// Quiet ink is `text.body`. The filled looks take the primary button pair.
    var ink: Color {
        switch self {
        case .quiet: Theme.ink
        case .filled, .circle: Theme.actionInk
        }
    }

    /// Matches `ButtonStyles.swift`: quiet dims to 0.7, filled to 0.82.
    var pressedOpacity: Double {
        switch self {
        case .quiet: 0.7
        case .filled, .circle: 0.82
        }
    }
}

/// Dims the glyph while the button is held. It adds no box of its own, so the
/// glyph view keeps the single frame.
struct IconButtonStyle: ButtonStyle {
    let variant: IconButtonVariant

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? variant.pressedOpacity : 1)
    }
}
