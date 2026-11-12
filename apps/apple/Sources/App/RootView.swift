import ReadLaterCore
import ReadLaterStore
import ReadLaterUI
import SwiftUI

/// A started article with a saved place, for the launch affordance.
struct PendingResume: Equatable {
    let contentHash: String
    let document: ReadLaterCore.Document
    let wordIndex: Int
    let totalWords: Int
}

/// Holds the open document. One speech controller for the process, so a second
/// document does not pay the cold start again.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var session: ReaderSession?
    @Published private(set) var pendingResume: PendingResume?

    private let speech = AVSpeechController()
    private let lookup = PackLookupProvider()
    private let store: ReadLaterStore.Store?

    init() {
        self.store = Self.openStore()
        refreshResumeOffer()
    }

    /// The resume store is best-effort: reading works without it, only the
    /// launch offer disappears.
    private static func openStore() -> ReadLaterStore.Store? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ReadLater", isDirectory: true)
        else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try? ReadLaterStore.Store(
            databaseURL: dir.appendingPathComponent("store.sqlite"), device: "apple-app")
    }

    func open(_ document: ReadLaterCore.Document, startWord: Int? = nil) {
        flushPosition()
        session?.stop()
        try? store?.save(document: document)
        let next = ReaderSession(document: document, speech: speech, lookupProvider: lookup)
        next.onProgress = { [weak self] index in self?.recordPosition(index: index) }
        if let startWord { next.begin(at: startWord) }
        session = next
        if pendingResume?.document.id == document.id { pendingResume = nil }
        next.warmUp()
        TelemetryHub.shared.record(TelemetryName.articleReady, fields: [
            "title": document.title,
            "words": String(document.plan.spokenWords),
        ])
    }

    func closeDocument() {
        flushPosition()
        session?.stop()
        session = nil
        refreshResumeOffer()
        TelemetryHub.shared.endRunIfActive(outcome: "closed")
    }

    /// Opens the offered article at its saved word.
    func resumePending() {
        guard let pending = pendingResume else { return }
        open(pending.document, startWord: pending.wordIndex)
    }

    /// Drops the launch offer. The next pause re-records, so this only
    /// silences the current offer.
    func dismissPending() {
        guard let pending = pendingResume else { return }
        try? store?.dismissPosition(contentHash: pending.contentHash)
        pendingResume = nil
    }

    /// Writes the current place now. Called on pause-adjacent transitions the
    /// throttle might miss: close, background, and anywhere the app can die.
    func flushPosition() {
        guard let session, let store, session.progress.totalWords > 0 else { return }
        try? store.recordPosition(of: session.document, wordIndex: session.progress.wordIndex)
    }

    private func recordPosition(index: Int) {
        guard let session, let store else { return }
        try? store.recordPosition(of: session.document, wordIndex: index)
    }

    private func refreshResumeOffer() {
        guard let store,
              let saved = try? store.latestUnfinishedPosition(),
              let document = try? store.document(id: saved.documentID)
        else {
            pendingResume = nil
            return
        }
        let total = SpokenIndex(plan: document.plan).totalWords
        pendingResume = PendingResume(
            contentHash: saved.contentHash, document: document,
            wordIndex: min(saved.wordIndex, max(total - 1, 0)), totalWords: total)
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
                EntryView(
                    onOpen: { model.open($0) },
                    resumeOffer: model.pendingResume.map {
                        ResumeOffer(
                            title: $0.document.title, wordIndex: $0.wordIndex,
                            totalWords: $0.totalWords)
                    },
                    onResume: model.resumePending,
                    onDismiss: model.dismissPending
                )
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
                model.flushPosition()
            case .active:
                TelemetryHub.shared.record(TelemetryName.appReturn)
                model.session?.reconcileOnReturn()
            case .inactive:
                // Lock and overlays pass through here before background; a
                // kill in between sends no callback, so pause and record now.
                model.session?.pauseForBackground()
                model.flushPosition()

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
    @State private var washVisible = true
    @State private var returnToken = 0

    var body: some View {
        VStack(spacing: 0) {
            chrome
            ReaderView(
                document: session.document,
                wash: session.wash,
                spoken: session.spoken,
                autoScroll: session.autoScroll && !session.isScrubbing,
                isScrubbing: session.isScrubbing,
                returnToken: returnToken,
                onTapWord: { blockID, slot, word in
                    session.tapped(blockID: blockID, slot: slot, word: word)
                },
                onTapNote: { session.openNote($0) },
                onHold: { session.userScrolled() },
                onWashVisibilityChanged: { washVisible = $0 },
                player: {
                    VStack(spacing: 0) {
                        HoldBadge(
                            isHeld: session.isHeld,
                            isPlaying: session.isPlaying,
                            onResume: { session.resumeFollowing() }
                        )
                        if shouldShowReturnPill(
                            washVisible: washVisible,
                            isHeld: session.isHeld,
                            isPlaying: session.isPlaying
                        ) {
                            ReturnToWashPill {
                                session.resumeFollowing()
                                returnToken += 1
                            }
                        }
                        SentenceStepper(
                            onStepSentence: { session.stepSentence($0) },
                            onStepBlock: { session.stepBlock($0) }
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
        ReaderChrome(
            title: session.document.title,
            autoScroll: session.autoScroll,
            isFinished: session.isFinished,
            onExit: onExit,
            onRestart: {
                session.scrub(toFraction: 0)
                session.resumeFollowing()
            },
            onToggleFollow: {
                if session.autoScroll { session.holdFollowing() } else { session.resumeFollowing() }
            },
            onSettings: { showSettings = true },
            onReplay: { session.togglePlay() }
        )
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

/// Reader top bar. Takes plain values, never the session, so a wash tick
/// cannot invalidate it. The menu reads two values, follow state and
/// finished state, and no per-word state. No behavior change.
struct ReaderChrome: View {
    let title: String
    let autoScroll: Bool
    let isFinished: Bool
    let onExit: () -> Void
    let onRestart: () -> Void
    let onToggleFollow: () -> Void
    let onSettings: () -> Void
    let onReplay: () -> Void

    var body: some View {
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

            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Menu {
                Button("Restart from the first word") {
                    onRestart()
                }
                Button(autoScroll ? "Stop following the wash" : "Follow the wash") {
                    onToggleFollow()
                }
                Button("Settings") { onSettings() }
                if isFinished {
                    Button("Replay") { onReplay() }
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
}
