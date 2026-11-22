import SwiftUI

/// The primary action: a slate fill with white text, full width, 44 pt tall.
///
/// A `ButtonStyle` rather than modifiers on each `Button`, because macOS draws
/// its own chrome inside a button whose label is only styled. The style owns the
/// label's frame, so the fill and the hit area cannot disagree.
public struct PrimaryActionButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PrimaryActionBody(configuration: configuration)
    }
}

/// Reads `isEnabled` from the environment, which a `ButtonStyle` cannot do
/// directly. Disabled is the `btn-disabled` look in the settled prototype:
/// surface fill, secondary ink, hairline border.
private struct PrimaryActionBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(isEnabled ? Theme.actionInk : Theme.inkSecondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isEnabled ? Theme.actionFill : Theme.surface)
                    .opacity(configuration.isPressed ? 0.82 : 1)
            )
            .overlay {
                if !isEnabled {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.line, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// A secondary action: card surface, one hairline border, ink text.
public struct SecondaryActionButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.ghostFill)
                    .opacity(configuration.isPressed ? 0.7 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.line, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}
