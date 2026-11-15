import ReadLaterCore
import ReadLaterStore
import ReadLaterUI
import SwiftUI
#if os(macOS)
import AppKit
#endif

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
    /// One line the library view shows when an action fails.
    @Published private(set) var libraryMessage: String?
    /// The root's two sheets. The model owns them so the open paths and the
    /// snapshot harness raise the same screens the buttons raise.
    @Published var isLibraryPresented = false
    @Published var isSettingsPresented = false

    private let speech: SpeechController
    private let lookup = PackLookupProvider()
    private let store: ReadLaterStore.Store?
    init() {
        self.speech = Self.makeSpeech()
        self.store = Self.openStore()
        refreshResumeOffer()
        refreshLibrary()
    }

    /// The one place the voice is chosen. Production always gets the system
    /// synthesizer; a debug launch can substitute the scripted voice.
    @MainActor
    private static func makeSpeech() -> SpeechController {
        #if DEBUG
        return DebugLaunch.makeSpeech()
        #else
        return AVSpeechController()
        #endif
    }

    /// Application Support/ReadLater. Shared with the debug reset, so a test
    /// launch deletes the same directory this opens.
    nonisolated static var storeDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ReadLater", isDirectory: true)
    }

    /// The resume store is best-effort: reading works without it, only the
    /// launch offer disappears.
    private static func openStore() -> ReadLaterStore.Store? {
        guard let dir = storeDirectory else { return nil }
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
            return
        }
        do {
            library = try store.recentPositions()
        } catch {
            library = []
            libraryMessage = LibraryCopy.readFailed
        }
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
                openAtPlace(document, row: row)
                return
            }
        } catch {
            libraryMessage = LibraryCopy.openFailed
            return
        }
        // The row outlives a cache bust, so its URL is the way back.
        guard let url = row.url else {
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
        refreshLibrary()
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

    /// Writes the current place now. Called on pause-adjacent transitions the
    /// throttle might miss: close, background, and anywhere the app can die.
    func flushPosition() {
        guard let session, let store, session.progress.totalWords > 0 else { return }
        timedStoreWrite { try store.recordPosition(of: session.document, wordIndex: session.progress.wordIndex) }
    }

    private func recordPosition(index: Int) {
        guard let session, let store else { return }
        timedStoreWrite { try store.recordPosition(of: session.document, wordIndex: index) }
    }

    /// Times one place write and logs its duration and thread (M8: no
    /// main-thread writes). The write itself is unchanged.
    private func timedStoreWrite(_ write: () throws -> Void) {
        let start = CFAbsoluteTimeGetCurrent()
        try? write()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        TelemetryHub.shared.record(TelemetryName.storeWrite, fields: [
            "ms": String(format: "%.2f", ms),
            "main": Thread.isMainThread ? "1" : "0",
        ])
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
                    onSettings: { model.isSettingsPresented = true },
                    onLibrary: { model.isLibraryPresented = true },
                    prefillLink: LibraryCopy.prefillLink(seenDemo: seenDemo)
                )
                .transition(.opacity)
            }
        }
        .frame(minWidth: 380, minHeight: 560)
#if os(macOS)
        .onAppear {
            let options = LaunchOptions()
            if options.isActive {
                DispatchQueue.main.async {
                    // The e2e suite drives clicks at screen coordinates. A
                    // window on another display can sit in a full-screen
                    // Space, where XCUI cannot hit it at all, and a restored
                    // frame can hang past a screen edge, where no display
                    // owns the point. Keep the whole test window inside the
                    // built-in display so the host desktop elsewhere does
                    // not block the run.
                    let home = NSScreen.screens.first
                    for window in NSApplication.shared.windows where window.isVisible {
                        window.level = .floating
                        guard let home else { continue }
                        let area = home.visibleFrame
                        guard !area.contains(window.frame) else { continue }
                        var frame = window.frame
                        frame.origin.x = area.minX + 40
                        frame.origin.y = area.maxY - frame.height - 60
                        frame.origin.x = min(max(frame.origin.x, area.minX), max(area.maxX - frame.width, area.minX))
                        frame.origin.y = min(max(frame.origin.y, area.minY), max(area.maxY - frame.height, area.minY))
                        window.setFrame(frame, display: true)
                    }
                }
            }
        }
#endif
        .background(Theme.paper)
        .preferredColorScheme((debugAppearance ?? Appearance(rawValue: appearance))?.colorScheme)
        .environment(\.locale, debugLocale ?? .autoupdatingCurrent)
        .transaction { transaction in
            if debugDisablesMotion { transaction.disablesAnimations = true }
        }
        .sheet(isPresented: $model.isSettingsPresented) {
            SettingsView(registry: registry)
        }
        .sheet(isPresented: $model.isLibraryPresented) {
            LibraryView(model: model, onClose: { model.isLibraryPresented = false })
        }
        .animation((debugDisablesMotion || reduceMotion) ? nil : ThemeMotion.screen, value: model.session == nil)
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

    /// Debug overrides. Nil in every Release build, so the modifiers below
    /// fall back to the stored choice and the system environment.
    private var debugAppearance: Appearance? {
        #if DEBUG
        return DebugLaunch.options.appearance
        #else
        return nil
        #endif
    }

    private var debugLocale: Locale? {
        #if DEBUG
        return DebugLaunch.options.locale.map(Locale.init(identifier:))
        #else
        return nil
        #endif
    }

    private var debugDisablesMotion: Bool {
        #if DEBUG
        let options = DebugLaunch.options
        return options.isActive && !options.animations
        #else
        return false
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
    @State private var clockMode = 0
    @State private var lastProgrammaticFollow = Date.distantPast

    var body: some View {
        VStack(spacing: 0) {
            chrome
            // The rail is a sibling of the reader and the clock row. It spans
            // the full height below the chrome, so its bottom group sits on
            // the clock row band.
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    reader
                    clockRow
                }
                rail
            }
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

    private var reader: some View {
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
            onHold: {
                // Programmatic scroll guard (spec: 500 ms). A reveal
                // kicked by Return/Follow just moved the page; the
                // settling scroll events must not re-hold.
                guard Date().timeIntervalSince(lastProgrammaticFollow) >= 0.5 else { return }
                session.userScrolled()
            },
            onWashVisibilityChanged: { washVisible = $0 },
            player: {
                VStack(spacing: 0) {
                    HoldBadge(
                        isHeld: session.isHeld,
                        isPlaying: session.isPlaying,
                        onResume: {
                            lastProgrammaticFollow = Date()
                            session.resumeFollowing()
                        }
                    )
                    if shouldShowReturnPill(
                        washVisible: washVisible,
                        isHeld: session.isHeld,
                        isPlaying: session.isPlaying
                    ) {
                        ReturnToWashPill {
                            lastProgrammaticFollow = Date()
                            session.resumeFollowing()
                            returnToken += 1
                        }
                    }
                }
            },
            overlay: { overlay }
        )
    }

    private var rail: some View {
        RailView(
            progress: session.progress,
            isPlaying: session.isPlaying,
            onPlayPause: { session.togglePlay() },
            onSpeed: { session.setSpeed($0) },
            onScrub: { session.scrub(toFraction: $0) },
            onPreviewScrub: { session.previewScrub(toFraction: $0) },
            onScrubbingChanged: { scrubbing in
                session.isScrubbing = scrubbing
                if !scrubbing { session.finishScrubbing() }
            },
            onStepSentence: { session.stepSentence($0) }
        )
    }

    /// Bottom row: clock at the left edge. Tap cycles 0 time+count, 1 count,
    /// 2 percent.
    private var clockRow: some View {
        HStack(spacing: 0) {
            clockButton
            Spacer(minLength: 0)
        }
        .padding(.leading, Theme.screenGutter)
        .frame(height: 32)
    }

    private var clockButton: some View {
        Button {
            clockMode = (clockMode + 1) % 3
        } label: {
            Text(session.progress.clockText(mode: clockMode))
                .font(Theme.mono())
                .foregroundStyle(Theme.inkSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clock \(clockModeLabel), tap to change format")
        .accessibilityValue(session.progress.clockText(mode: clockMode))
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier(AccessibilityID.clock)
    }

    private var clockModeLabel: String {
        switch clockMode {
        case 1: return "count"
        case 2: return "percent"
        default: return "time and count"
        }
    }

    private var chrome: some View {
        ReaderChrome(
            title: session.document.title,
            autoScroll: session.autoScroll,
            isHeld: session.isHeld,
            offScreen: !washVisible,
            isFinished: session.isFinished,
            onExit: onExit,
            onRestart: {
                session.scrub(toFraction: 0)
                session.resumeFollowing()
            },
            onToggleFollow: {
                if session.autoScroll {
                    session.holdFollowing()
                } else {
                    lastProgrammaticFollow = Date()
                    session.resumeFollowing()
                }
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
    let isHeld: Bool
    let offScreen: Bool
    let isFinished: Bool
    let onExit: () -> Void
    let onRestart: () -> Void
    let onToggleFollow: () -> Void
    let onReplay: () -> Void

    private var isFollowing: Bool {
        autoScroll && !isHeld && !offScreen
    }

    var body: some View {
        HStack(spacing: 8) {
            IconButton(systemName: "chevron.left", label: "Back to library") {
                onExit()
            }
            .accessibilityIdentifier(AccessibilityID.readerBack)

            Spacer(minLength: 8)

            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel(title)
                .accessibilityIdentifier(AccessibilityID.readerTitle)

            Spacer(minLength: 8)

            // Persistent follow dot (C1 revised). Filled only while
            // following and on-screen; hollow when held or off-screen.
            Button(action: onToggleFollow) {
                Image(systemName: isFollowing ? "circle.fill" : "circle")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isFollowing ? Theme.brand : Theme.holdInk)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFollowing ? "Following wash, tap to hold" : "Held, tap to resume follow")
            .accessibilityIdentifier(AccessibilityID.followDot)

            Menu {
                Button("Restart from the first word") {
                    onRestart()
                }
                if isFinished {
                    Button("Replay") { onReplay() }
                }
            } label: {
                IconGlyph(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("Reader options")
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(Theme.surface)
        .overlay(Divider(), alignment: .bottom)
    }
}
