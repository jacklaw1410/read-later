import ReadLaterCore
import SwiftUI

/// The three non-clean states. Card copy is owned by
/// design/miss-state.md and quoted exactly; MissKind labels match it.
public struct MissCard: View {
    private let word: String
    private let kind: MissKind
    private let packInstalled: Bool
    private let isOnline: Bool
    private let onInstall: () -> Void
    private let onNotNow: () -> Void
    private let onClose: () -> Void
    private let onSearchWeb: () -> Void

    public init(
        word: String,
        kind: MissKind,
        packInstalled: Bool,
        isOnline: Bool,
        onInstall: @escaping () -> Void,
        onNotNow: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onSearchWeb: @escaping () -> Void
    ) {
        self.word = word
        self.kind = kind
        self.packInstalled = packInstalled
        self.isOnline = isOnline
        self.onInstall = onInstall
        self.onNotNow = onNotNow
        self.onClose = onClose
        self.onSearchWeb = onSearchWeb
    }

    private var showsOffer: Bool {
        !packInstalled && isOnline
    }

    private var stateLine: String {
        LookupOutcome.miss(kind).label
    }

    private var sourceLine: String {
        if packInstalled {
            "Source · Apple 譯典通 (built-in) + English–Chinese pack · no entry"
        } else {
            "Source · Apple 譯典通 (built-in) · no entry"
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(word)
                .font(Theme.lookupWord())
                .foregroundStyle(Theme.ink)
            Text(stateLine)
                .font(Theme.gloss())
                .foregroundStyle(Theme.inkSecondary)
                .padding(.top, 2)
                .padding(.bottom, 12)

            Divider()

            if showsOffer {
                VStack(alignment: .leading, spacing: 2) {
                    Text("English–Chinese dictionary (Traditional)")
                        .font(Theme.gloss())
                        .foregroundStyle(Theme.ink)
                    Text("14.47 MiB · downloads once · works offline")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.inkSecondary)
                    Text("You can add it later in Settings › Dictionaries.")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.inkSecondary)
                }
                .padding(.vertical, 12)

                Divider()
            }

            Text(sourceLine)
                .font(Theme.caption())
                .foregroundStyle(Theme.inkSecondary)
                .padding(.vertical, 8)

            Divider()

            footer
                .frame(minHeight: Theme.minTarget)
        }
        .padding(Theme.screenGutter)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

    @ViewBuilder
    private var footer: some View {
        if showsOffer {
            HStack(spacing: 8) {
                Button("Install", action: onInstall)
                    .frame(maxWidth: .infinity, minHeight: Theme.minTarget)
                    .background(Theme.brand, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
                Button("Not now", action: onNotNow)
                    .frame(maxWidth: .infinity, minHeight: Theme.minTarget)
            }
        } else if kind == .noNetwork {
            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .frame(minWidth: 120, minHeight: Theme.minTarget)
            }
        } else {
            HStack(spacing: 8) {
                Button("Close", action: onClose)
                    .frame(minWidth: 120, minHeight: Theme.minTarget)
                Spacer()
                Button("Search the web ↗", action: onSearchWeb)
                    .frame(minHeight: Theme.minTarget)
            }
        }
    }
}
