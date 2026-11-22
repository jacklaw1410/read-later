import ReadLaterCore
import SwiftUI

/// The three non-clean states. Card copy is owned by
/// design/miss-state.md and quoted exactly; `MissKind` labels come from
/// `LookupOutcome` and are never reworded here.
public struct MissCard: View {
    private let telemetry: TelemetryHub
    private let word: String
    private let kind: MissKind
    private let packInstalled: Bool
    private let isOnline: Bool
    private let offerDeclined: Bool
    private let isInstalling: Bool
    private let wasPlayingBeforeLookup: Bool
    private let wordIndex: Int?
    private let onPronounce: () -> Void
    private let onInstall: () -> Void
    private let onNotNow: () -> Void
    private let onClose: () -> Void
    private let onSearchWeb: () -> Void
    @State private var didLogShown = false

    public init(
        telemetry: TelemetryHub,
        word: String,
        kind: MissKind,
        packInstalled: Bool,
        isOnline: Bool,
        offerDeclined: Bool,
        isInstalling: Bool,
        wasPlayingBeforeLookup: Bool,
        wordIndex: Int?,
        onPronounce: @escaping () -> Void,
        onInstall: @escaping () -> Void,
        onNotNow: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onSearchWeb: @escaping () -> Void
    ) {
        self.telemetry = telemetry
        self.word = word
        self.kind = kind
        self.packInstalled = packInstalled
        self.isOnline = isOnline
        self.offerDeclined = offerDeclined
        self.isInstalling = isInstalling
        self.wasPlayingBeforeLookup = wasPlayingBeforeLookup
        self.wordIndex = wordIndex
        self.onPronounce = onPronounce
        self.onInstall = onInstall
        self.onNotNow = onNotNow
        self.onClose = onClose
        self.onSearchWeb = onSearchWeb
    }

    /// The offer renders once: pack absent, network up, never declined, and a
    /// state where a pack could help.
    private var showsOffer: Bool {
        Self.showsOffer(kind: kind, packInstalled: packInstalled, isOnline: isOnline, offerDeclined: offerDeclined)
    }

    /// The web search is a second, deliberate tap. Never offline, never beside
    /// the offer: one secondary action per card.
    private var showsSearch: Bool {
        Self.showsSearch(kind: kind, packInstalled: packInstalled, isOnline: isOnline, offerDeclined: offerDeclined)
    }

    nonisolated static func showsOffer(kind: MissKind, packInstalled: Bool, isOnline: Bool, offerDeclined: Bool) -> Bool {
        kind != .noNetwork && !packInstalled && isOnline && !offerDeclined
    }

    nonisolated static func showsSearch(kind: MissKind, packInstalled: Bool, isOnline: Bool, offerDeclined: Bool) -> Bool {
        isOnline && kind != .noNetwork
            && !showsOffer(kind: kind, packInstalled: packInstalled, isOnline: isOnline, offerDeclined: offerDeclined)
            && (packInstalled || offerDeclined)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(word)
                    .font(Theme.lookupWord())
                    .foregroundStyle(Theme.ink)
                    .accessibilityIdentifier(AccessibilityID.missWord)
                IconButton(systemName: "speaker.wave.2", label: "Pronounce \(word)", action: onPronounce)
                    .accessibilityIdentifier(AccessibilityID.missPronounce)
                    // The 44 pt box would grow the word row. These margins match the prototype's `.pronounce`.
                    .padding(.vertical, -10)
                    .padding(.leading, -2)
                    .padding(.trailing, -12)
            }
            Text(LookupOutcome.miss(kind).label)
                .font(Theme.caption())
                .foregroundStyle(Theme.inkSecondary)
                .padding(.top, 2)
                .padding(.bottom, 12)

            Divider()

            if showsOffer {
                VStack(alignment: .leading, spacing: 2) {
                    Text(CardCopy.offerTitle)
                        .font(Theme.offerTitle())
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
                .font(Theme.caption())
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
        // A container, so the card and the word each answer to their own
        // identifier. Same rule as the hit card: without it SwiftUI copies
        // the card identifier onto every child.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.missCard)
        .onAppear {
            // Same post-commit mark as the hit card (see LookupCard).
            DispatchQueue.main.async {
                guard !didLogShown else { return }
                didLogShown = true
                telemetry.record(
                    TelemetryName.cardShown,
                    fields: ["word": word, "kind": "miss"]
                )
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if showsOffer {
            HStack(spacing: 8) {
                Button(isInstalling ? CardCopy.installing : CardCopy.install, action: onInstall)
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(isInstalling)
                    .accessibilityIdentifier(AccessibilityID.missInstall)
                Button(CardCopy.notNow, action: onNotNow)
                    .buttonStyle(SecondaryActionButtonStyle())
                    .accessibilityIdentifier(AccessibilityID.missNotNow)
            }
        } else if showsSearch {
            HStack(spacing: 8) {
                Button(CardCopy.close, action: onClose)
                    .buttonStyle(SecondaryActionButtonStyle())
                    .accessibilityIdentifier(AccessibilityID.missClose)
                Button(CardCopy.searchWeb, action: onSearchWeb)
                    .buttonStyle(SecondaryActionButtonStyle())
                    .accessibilityIdentifier(AccessibilityID.missSearch)
            }
        } else {
            Button(CardCopy.close, action: onClose)
                .buttonStyle(SecondaryActionButtonStyle())
                .accessibilityIdentifier(AccessibilityID.missClose)
        }
    }
}
