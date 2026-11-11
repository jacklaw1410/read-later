import ReadLaterCore
import SwiftUI

/// The three non-clean states. Card copy is owned by
/// design/miss-state.md and quoted exactly; `MissKind` labels come from
/// `LookupOutcome` and are never reworded here.
public struct MissCard: View {
    private let word: String
    private let kind: MissKind
    private let packInstalled: Bool
    private let isOnline: Bool
    private let offerDeclined: Bool
    private let isInstalling: Bool
    private let wasPlayingBeforeLookup: Bool
    private let wordIndex: Int?
    private let onInstall: () -> Void
    private let onNotNow: () -> Void
    private let onClose: () -> Void
    private let onSearchWeb: () -> Void

    public init(
        word: String,
        kind: MissKind,
        packInstalled: Bool,
        isOnline: Bool,
        offerDeclined: Bool,
        isInstalling: Bool,
        wasPlayingBeforeLookup: Bool,
        wordIndex: Int?,
        onInstall: @escaping () -> Void,
        onNotNow: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onSearchWeb: @escaping () -> Void
    ) {
        self.word = word
        self.kind = kind
        self.packInstalled = packInstalled
        self.isOnline = isOnline
        self.offerDeclined = offerDeclined
        self.isInstalling = isInstalling
        self.wasPlayingBeforeLookup = wasPlayingBeforeLookup
        self.wordIndex = wordIndex
        self.onInstall = onInstall
        self.onNotNow = onNotNow
        self.onClose = onClose
        self.onSearchWeb = onSearchWeb
    }

    /// The offer renders once: pack absent, network up, never declined, and a
    /// state where a pack could help.
    private var showsOffer: Bool {
        kind != .noNetwork && !packInstalled && isOnline && !offerDeclined
    }

    /// The web search is a second, deliberate tap. Never offline, never beside
    /// the offer: one secondary action per card.
    private var showsSearch: Bool {
        isOnline && kind != .noNetwork && !showsOffer && (packInstalled || offerDeclined)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(word)
                .font(Theme.lookupWord())
                .foregroundStyle(Theme.ink)
            Text(LookupOutcome.miss(kind).label)
                .font(Theme.caption())
                .foregroundStyle(Theme.inkSecondary)
                .padding(.top, 2)
                .padding(.bottom, 12)

            Divider()

            if showsOffer {
                VStack(alignment: .leading, spacing: 2) {
                    Text(CardCopy.offerTitle)
                        .font(Theme.gloss())
                        .fontWeight(.bold)
                        .foregroundStyle(Theme.ink)
                    Text(CardCopy.offerMeta)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.inkSecondary)
                    Text(CardCopy.offerWayBack)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.inkSecondary)
                }
                .padding(.vertical, 12)

                Divider()
            }

            Text(CardCopy.missSourceLine(packInstalled: packInstalled))
                .font(.system(size: 11))
                .foregroundStyle(Theme.inkSecondary)
                .padding(.vertical, 8)

            Divider()

            Text(CardCopy.pauseLine(wasPlayingBeforeLookup: wasPlayingBeforeLookup, wordIndex: wordIndex))
                .font(Theme.caption())
                .foregroundStyle(Theme.inkSecondary)
                .padding(.top, 8)

            footer
                .padding(.top, 8)
        }
        .padding(Theme.screenGutter)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

    @ViewBuilder
    private var footer: some View {
        if showsOffer {
            HStack(spacing: 8) {
                Button(isInstalling ? CardCopy.installing : CardCopy.install, action: onInstall)
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(isInstalling)
                Button(CardCopy.notNow, action: onNotNow)
                    .buttonStyle(SecondaryActionButtonStyle())
            }
        } else if showsSearch {
            HStack(spacing: 8) {
                Button(CardCopy.close, action: onClose)
                    .buttonStyle(SecondaryActionButtonStyle())
                Button(CardCopy.searchWeb, action: onSearchWeb)
                    .buttonStyle(SecondaryActionButtonStyle())
            }
        } else {
            Button(CardCopy.close, action: onClose)
                .buttonStyle(SecondaryActionButtonStyle())
        }
    }
}
