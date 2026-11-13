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
    /// The browse list: every started article, newest first.
    @Published private(set) var library: [ReadingPosition] = []
    /// Spoken length per document id, so a row can say "word X of Y" without a
    /// store read on every render. A busted row keeps its last known length.
    @Published private(set) var libraryTotals: [UUID: Int] = [:]
    /// One line the library view shows when an action fails.
    @Published private(set) var libraryMessage: String?

    private let speech = AVSpeechController()
    private let lookup = PackLookupProvider()
    private let store: ReadLaterStore.Store?
    /// Last known URL per document id. A cache bust drops the stored document,
    /// and the position row holds no URL, so the map is saved in defaults to
    /// survive a relaunch.
    private var libraryURLs: [UUID: URL]
    private static let libraryURLsKey = "rl-library-urls"

    init() {
        self.store = Self.openStore()
        self.libraryURLs = Self.loadLibraryURLs()
        refreshResumeOffer()
        refreshLibrary()
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
        refreshLibrary()
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
        refreshLibrary()
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

    // MARK: - Library

    /// Reads the browse list again. Called on launch, open, close and after
    /// every library action, so the list never shows a stale row.
    func refreshLibrary() {
        guard let store else {
            library = []
            libraryTotals = [:]
            return
        }
        do {
            library = try store.recentPositions()
        } catch {
            library = []
            libraryMessage = LibraryCopy.readFailed
            return
        }
        var totals: [UUID: Int] = [:]
        for row in library {
            guard let document = try? store.document(id: row.documentID) else {
                // A busted row keeps the length it had before the bust.
                if let known = libraryTotals[row.documentID] { totals[row.documentID] = known }
                continue
            }
            totals[row.documentID] = SpokenIndex(plan: document.plan).totalWords
            rememberLibraryURL(document.url, documentID: row.documentID)
        }
        libraryTotals = totals
    }

    /// Opens a library row. The stored plan is the normal path. After a cache
    /// bust the plan is gone, so the page is fetched and read again from its
    /// last known URL, then opened at the same place.
    func openFromLibrary(_ row: ReadingPosition) {
        guard let store else {
            libraryMessage = LibraryCopy.noStore
            return
        }
        libraryMessage = nil
        do {
            if let document = try store.document(id: row.documentID) {
                rememberLibraryURL(document.url, documentID: row.documentID)
                openAtPlace(document, row: row)
                return
            }
        } catch {
            libraryMessage = LibraryCopy.openFailed
            return
        }
        guard let url = libraryURLs[row.documentID] else {
            libraryMessage = LibraryCopy.needsLink
            return
        }
        Task { await refetchAndOpen(row, url: url) }
    }

    func setSaved(_ row: ReadingPosition, saved: Bool) {
        libraryMessage = nil
        guard let store else {
            libraryMessage = LibraryCopy.noStore
            return
        }
        do {
            try store.setSaved(contentHash: row.contentHash, saved: saved)
        } catch {
            libraryMessage = LibraryCopy.saveFailed
        }
        refreshLibrary()
    }

    func cacheBust(_ row: ReadingPosition) {
        libraryMessage = nil
        guard let store else {
            libraryMessage = LibraryCopy.noStore
            return
        }
        do {
            try store.cacheBust(documentID: row.documentID)
        } catch {
            libraryMessage = LibraryCopy.bustFailed
        }
        refreshLibrary()
    }

    func forget(_ row: ReadingPosition) {
        libraryMessage = nil
        guard let store else {
            libraryMessage = LibraryCopy.noStore
            return
        }
        do {
            try store.forget(contentHash: row.contentHash, documentID: row.documentID)
        } catch {
            libraryMessage = LibraryCopy.forgetFailed
        }
        libraryURLs[row.documentID] = nil
        libraryTotals[row.documentID] = nil
        Self.saveLibraryURLs(libraryURLs)
        refreshLibrary()
    }

    /// Spoken length for a row, or 0 when the plan is gone.
    func totalWords(for row: ReadingPosition) -> Int {
        libraryTotals[row.documentID] ?? 0
    }

    private func openAtPlace(_ document: ReadLaterCore.Document, row: ReadingPosition) {
        let total = SpokenIndex(plan: document.plan).totalWords
        open(document, startWord: min(row.wordIndex, max(total - 1, 0)))
    }

    private func refetchAndOpen(_ row: ReadingPosition, url: URL) async {
        switch await ArticleIngress.fetch(url.absoluteString) {
        case .failure(let error):
            libraryMessage = error.message
        case .success(let page):
            switch ArticleIngress.read(page) {
            case .failure(let error):
                libraryMessage = error.message
            case .success(let document):
                try? store?.save(document: document)
                openAtPlace(document, row: row)
            }
        }
    }

    /// Keeps the URL for a document id, and writes the map to defaults only
    /// when it changes. A busted row needs this map to fetch its page again.
    private func rememberLibraryURL(_ url: URL?, documentID: UUID) {
        guard let url, libraryURLs[documentID] != url else { return }
        libraryURLs[documentID] = url
        Self.saveLibraryURLs(libraryURLs)
    }

    private static func loadLibraryURLs() -> [UUID: URL] {
        let raw = UserDefaults.standard.dictionary(forKey: libraryURLsKey) ?? [:]
        var map: [UUID: URL] = [:]
        for (id, value) in raw {
            guard let uuid = UUID(uuidString: id),
                  let link = value as? String,
                  let url = URL(string: link)
            else { continue }
            map[uuid] = url
        }
        return map
    }

    private static func saveLibraryURLs(_ map: [UUID: URL]) {
        var raw: [String: String] = [:]
        for (id, url) in map { raw[id.uuidString] = url.absoluteString }
        UserDefaults.standard.set(raw, forKey: libraryURLsKey)
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
    @ObservedObject private var registry = PackRegistry.shared
    @State private var showSettings = false
    @State private var showLibrary = false
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system.rawValue
    @AppStorage("rl-seen-demo") private var seenDemo = false
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
                    onDismiss: model.dismissPending,
                    onSettings: { showSettings = true },
                    onLibrary: { showLibrary = true },
                    prefillLink: LibraryCopy.prefillLink(seenDemo: seenDemo)
                )
                .transition(.opacity)
            }
        }
        .frame(minWidth: 380, minHeight: 560)
        .background(Theme.paper)
        .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
        .sheet(isPresented: $showSettings) {
            SettingsView(registry: registry)
        }
        .sheet(isPresented: $showLibrary) {
            LibraryView(model: model, onClose: { showLibrary = false })
        }
        .animation(reduceMotion ? nil : ThemeMotion.screen, value: model.session == nil)
        // One demo open sets the first-run flag, whichever path opened it:
        // entry, resume or the library.
        .onChange(of: model.session?.document.url) { _, url in
            if LibraryCopy.isDemo(url: url) { seenDemo = true }
        }
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
    let onReplay: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onExit()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.inkSecondary)
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
