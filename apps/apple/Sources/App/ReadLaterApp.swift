import ReadLaterUI
import SwiftUI

@main
struct ReadLaterApp: App {
    @StateObject private var session = ReaderSession.makeSample()

    var body: some Scene {
        WindowGroup {
            ReaderHome(session: session)
                .task {
                    session.warmUp()
                }
        }
    }
}

/// Sample document reader: title, wash, player bar, lookup card on tap.
struct ReaderHome: View {
    @ObservedObject var session: ReaderSession
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            ReaderView(
                document: session.document,
                wash: session.wash,
                autoScroll: session.autoScroll && !session.isScrubbing,
                onTapWord: { word, blockID in session.tapped(word: word, blockID: blockID) }
            )
            PlayerBar(
                isPlaying: session.isPlaying,
                progress: session.progress,
                speed: session.speed,
                onPlayPause: { session.togglePlay() },
                onSpeed: { session.setSpeed($0) },
                onScrub: { session.scrub(to: $0) },
                onScrubbingChanged: { session.isScrubbing = $0 }
            )
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(session.autoScroll ? "Following" : "Follow") {
                    session.autoScroll.toggle()
                }
            }
        }
        .sheet(item: $session.card) { card in
            cardView(for: card)
                .presentationDetents([.medium])
                .onDisappear {
                    session.closeLookup()
                }
        }
    }

    @ViewBuilder
    private func cardView(for card: LookupCardState) -> some View {
        switch card {
        case let .hit(result):
            LookupCard(result: result, onClose: { session.closeLookup() })
        case let .miss(word, kind):
            MissCard(
                word: word,
                kind: kind,
                packInstalled: session.packInstalled,
                isOnline: session.isOnline,
                onInstall: { session.closeLookup() },
                onNotNow: { session.closeLookup() },
                onClose: { session.closeLookup() },
                onSearchWeb: {
                    if let url = URL(string: "https://www.google.com/search?q=\(word)") {
                        openURL(url)
                    }
                    session.closeLookup()
                }
            )
        }
    }
}
