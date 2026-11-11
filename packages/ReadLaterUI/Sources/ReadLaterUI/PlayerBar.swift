import SwiftUI

/// Docked playback bar: play/pause, 1×/2× speed, progress scrubber.
public struct PlayerBar: View {
    private let isPlaying: Bool
    private let progress: Double
    private let speed: Float
    private let onPlayPause: () -> Void
    private let onSpeed: (Float) -> Void
    private let onScrub: (Double) -> Void
    private let onScrubbingChanged: (Bool) -> Void

    public init(
        isPlaying: Bool,
        progress: Double,
        speed: Float,
        onPlayPause: @escaping () -> Void,
        onSpeed: @escaping (Float) -> Void,
        onScrub: @escaping (Double) -> Void,
        onScrubbingChanged: @escaping (Bool) -> Void
    ) {
        self.isPlaying = isPlaying
        self.progress = progress
        self.speed = speed
        self.onPlayPause = onPlayPause
        self.onSpeed = onSpeed
        self.onScrub = onScrub
        self.onScrubbingChanged = onScrubbingChanged
    }

    public var body: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(get: { progress }, set: { onScrub($0) }),
                in: 0 ... 1,
                onEditingChanged: onScrubbingChanged
            )
            .tint(Theme.brand)
            .accessibilityLabel("Reading progress")

            HStack(spacing: 12) {
                Button(action: onPlayPause) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.brand)
                }
                .frame(minWidth: Theme.minTarget, minHeight: Theme.minTarget)
                .accessibilityLabel(isPlaying ? "Pause" : "Play")

                HStack(spacing: 0) {
                    ForEach([Float(1), Float(2)], id: \.self) { value in
                        Button {
                            onSpeed(value)
                        } label: {
                            Text(String(format: "%.0g×", value))
                                .font(Theme.player())
                                .foregroundStyle(speed == value ? Theme.surface : Theme.inkSecondary)
                                .frame(width: 44, height: 32)
                                .background(speed == value ? Theme.brand : Color.clear)
                        }
                        .accessibilityLabel("Speed \(value) times")
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))

                Spacer()

                Text("\(Int((progress * 100).rounded()))%")
                    .font(Theme.player())
                    .foregroundStyle(Theme.inkSecondary)
                    .accessibilityLabel("Progress \(Int((progress * 100).rounded())) percent")
            }
            .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, Theme.screenGutter)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(Divider(), alignment: .top)
    }
}
