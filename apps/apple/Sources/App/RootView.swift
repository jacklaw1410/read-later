import ReadLaterCore
import ReadLaterUI
import SwiftUI

/// Holds the open document. One speech controller for the process, so a second
/// document does not pay the cold start again.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var session: ReaderSession?

    private let speech = AVSpeechController()
    private let lookup = PackLookupProvider()

    func open(_ document: ReadLaterCore.Document) {
        session?.stop()
        let next = ReaderSession(document: document, speech: speech, lookupProvider: lookup)
        session = next
        next.warmUp()
        TelemetryHub.shared.record(TelemetryName.articleReady, fields: [
            "title": document.title,
            "words": String(document.plan.spokenWords),
        ])
    }

    func closeDocument() {
        session?.stop()
        session = nil
        TelemetryHub.shared.endRunIfActive(outcome: "closed")
    }
}

struct RootView: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let session = model.session {
                ReaderScreen(session: session, onExit: model.closeDocument)
                    .transition(.opacity)
            } else {
                EntryView(onOpen: model.open)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 380, minHeight: 560)
        .background(Theme.paper)
        .animation(reduceMotion ? nil : ThemeMotion.screen, value: model.session == nil)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                model.session?.pauseForBackground()
                TelemetryHub.shared.record(TelemetryName.appHide)
            case .active:
                TelemetryHub.shared.record(TelemetryName.appReturn)
                model.session?.reconcileOnReturn()
            case .inactive:
                // Lock and background pass through `.inactive` on the way
                // out. Pause here so the state lands before suspension.
                model.session?.pauseForBackground()
            @unknown default:
                break
            }
        }
        #if os(macOS)
        .task {
            if SnapshotHarness.isEnabled {
                await SnapshotHarness.run(app: model)
            }
        }
        #endif
    }
}

/// The reader: chrome, blocks, transport, and the one overlay layer.
struct ReaderScreen: View {
    @ObservedObject var session: ReaderSession
    let onExit: () -> Void

    @ObservedObject private var registry = PackRegistry.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            chrome
            ReaderView(
                document: session.document,
                wash: session.wash,
                spoken: session.spoken,
                autoScroll: session.autoScroll && !session.isScrubbing,
                onTapWord: { blockID, slot, word in
                    session.tapped(blockID: blockID, slot: slot, word: word)
                },
                onTapNote: { session.openNote($0) },
                player: {
                    VStack(spacing: 0) {
                        HoldBadge(
                            isHeld: session.isHeld,
                            isPlaying: session.isPlaying,
                            onResume: { session.resumeFollowing() }
                        )
                        PlayerBar(
                            progress: session.progress,
                            isPlaying: session.isPlaying,
                            onPlayPause: { session.togglePlay() },
                            onSpeed: { session.setSpeed($0) },
                            onScrub: { session.scrub(toFraction: $0) },
                            onPreviewScrub: { session.previewScrub(toFraction: $0) },
                            onScrubbingChanged: { scrubbing in
                                session.isScrubbing = scrubbing
                                if !scrubbing { session.finishScrubbing() }
                            }
                        )
                    }
                },
                overlay: { overlay }
            )
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(registry: registry)
        }
        .onKeyPress(.escape) {
            if session.card != nil {
                session.closeCard()
                return .handled
            }
            if session.note != nil {
                session.closeNote()
                return .handled
            }
            return .ignored
        }
    }

    private var chrome: some View {
        HStack(spacing: 8) {
            Button {
                onExit()
            } label: {
                Label("Library", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.inkSecondary)
            .frame(minHeight: 44)
            .accessibilityLabel("Back to library")

            Spacer(minLength: 8)

            Text(session.document.title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Menu {
                Button("Restart from the first word") {
                    session.scrub(toFraction: 0)
                    session.resumeFollowing()
                }
                Button(session.autoScroll ? "Stop following the wash" : "Follow the wash") {
                    if session.autoScroll { session.holdFollowing() } else { session.resumeFollowing() }
                }
                Button("Settings") { showSettings = true }
                if session.isFinished {
                    Button("Replay") { session.togglePlay() }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 44, height: 44)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 44, height: 44)
            .accessibilityLabel("Reader options")
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(Theme.surface)
        .overlay(Divider(), alignment: .bottom)
    }

    @ViewBuilder
    private var overlay: some View {
        if let card = session.card {
            CardSheet(onDismiss: { session.closeCard() }) {
                switch card {
                case let .hit(result, wordIndex, wasPlaying):
                    LookupCard(
                        result: result,
                        wasPlayingBeforeLookup: wasPlaying,
                        wordIndex: wordIndex,
                        isCurrentWashWord: wordIndex != nil && wordIndex == session.wash.wordIndex,
                        onClose: { session.closeCard() }
                    )
                case let .miss(word, kind, wordIndex, wasPlaying):
                    MissCard(
                        word: word,
                        kind: kind,
                        packInstalled: registry.isInstalled,
                        isOnline: session.isOnline,
                        offerDeclined: session.offerDeclined,
                        isInstalling: registry.isInstalling,
                        wasPlayingBeforeLookup: wasPlaying,
                        wordIndex: wordIndex,
                        onInstall: { Task { await session.installPack() } },
                        onNotNow: { session.declineOffer() },
                        onClose: { session.closeCard() },
                        onSearchWeb: {
                            let query = word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? word
                            if let url = URL(string: "https://duckduckgo.com/?q=\(query)") {
                                openURL(url)
                            }
                            session.closeCard()
                        }
                    )
                }
            }
            .animation(reduceMotion ? nil : ThemeMotion.sheet, value: session.card == nil)
            .zIndex(2)
        }

        if let note = session.note, session.document.noteBlocks.indices.contains(note.index) {
            let block = session.document.noteBlocks[note.index]
            ZStack {
                Theme.scrim
                    .ignoresSafeArea()
                    .onTapGesture { session.closeNote() }
                VStack {
                    Spacer(minLength: 0)
                    FootnoteOverlay(
                        marker: "¹",
                        text: block.text,
                        pauseLine: note.wasPlaying ? "Audio paused · resumes on close" : "Audio was already paused · stays paused",
                        onTapWord: { word in session.tapped(blockID: block.id, slot: nil, word: word) },
                        onClose: { session.closeNote() }
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 58)
                }
            }
            .zIndex(3)
        }
    }
}
