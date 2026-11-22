import Observation
import ReadLaterCore
import ReadLaterStore
import ReadLaterUI
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Holds the open document. One speech controller for the process, so a second
/// document does not pay the cold start again.
@MainActor
@Observable
final class AppModel {
    private(set) var session: ReaderSession?
    /// The browse list: every started article, newest first.
    private(set) var library: [ReadingPosition] = []
    /// One line the library view shows when an action fails.
    private(set) var libraryMessage: String?
    /// The root's two sheets. The model owns them so the open paths and the
    /// snapshot harness raise the same screens the buttons raise.
    var isLibraryPresented = false
    var isSettingsPresented = false

    private let speech: SpeechController
    private let packs: any CapabilityPacks
    private let telemetry: TelemetryHub
    private let speedStore: SpeedStore
    private let lookup: PackLookupProvider
    private let store: ReadLaterStore.Store?
    private let recorder: ReadLaterStore.PositionRecorder?
    init(packs: any CapabilityPacks, telemetry: TelemetryHub, speedStore: SpeedStore) {
        self.packs = packs
        self.telemetry = telemetry
        self.speedStore = speedStore
        self.lookup = PackLookupProvider(packs: packs, apple: AppleDictionaryLookup())
        self.speech = Self.makeSpeech(telemetry: telemetry)
        self.store = Self.openStore(telemetry: telemetry)
        Self.seedIfRequested(store: self.store, telemetry: telemetry)
        self.recorder = self.store.map { ReadLaterStore.PositionRecorder(store: $0) }
        refreshLibrary()
    }

    /// The one place the voice is chosen. Production always gets the system
    /// synthesizer; a debug launch can substitute the scripted voice.
    @MainActor
    private static func makeSpeech(telemetry: TelemetryHub) -> SpeechController {
        #if DEBUG
        return DebugLaunch.makeSpeech(telemetry: telemetry)
        #else
        return AVSpeechController(telemetry: telemetry)
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
    private static func openStore(telemetry: TelemetryHub) -> ReadLaterStore.Store? {
        guard let dir = storeDirectory else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try? ReadLaterStore.Store(
            databaseURL: dir.appendingPathComponent("store.sqlite"),
            device: "apple-app",
            telemetry: telemetry
        )
    }

    /// Debug-only seeding for device latency runs (M2/M4 treatment). The
    /// article arrives as base64 in `--debug.seedTextB64` and lands in the
    /// store with its place at word zero, so the test opens the newest
    /// library row instead of typing the raw text. Runs before the library
    /// refresh, so the row is there on launch. Debug builds only.
    private static func seedIfRequested(store: ReadLaterStore.Store?, telemetry: TelemetryHub) {
        #if DEBUG
        guard let store, let b64 = DebugLaunch.options.seedTextB64,
              let data = Data(base64Encoded: b64),
              let text = String(data: data, encoding: .utf8),
              case .success(let document) = ArticleIngress.pasted(text, telemetry: telemetry) else { return }
        try? store.save(document: document)
        try? store.recordPosition(of: document, wordIndex: 0, source: "seed")
        #endif
    }

    func open(_ document: ReadLaterCore.Document, startWord: Int? = nil) {
        flushPosition()
        session?.stop()
        try? store?.save(document: document)
        let next = ReaderSession(
            document: document, speech: speech, lookupProvider: lookup, packs: packs,
            telemetry: telemetry, speedStore: speedStore)
        next.onProgress = { [weak self] index, source in self?.recordPosition(index: index, source: source) }
        if let startWord { next.begin(at: startWord) }
        session = next
        next.warmUp()
        refreshLibrary()
        telemetry.record(TelemetryName.articleReady, fields: [
            "title": document.title,
            "words": String(document.plan.spokenWords),
        ])
    }

    func closeDocument() {
        flushPosition()
        session?.stop()
        session = nil
        refreshLibrary()
        telemetry.endRunIfActive(outcome: "closed")
    }

    /// Opens the newest saved place, if any. The resume offer is gone, so
    /// the debug autoplay and any future caller re-enter through the same
    /// door the library uses: latest row, saved word.
    func openLatestSavedPlace() {
        guard let store,
              let saved = try? store.latestUnfinishedPosition(),
              let document = try? store.document(id: saved.documentID)
        else { return }
        let total = SpokenWordNumbering(plan: document.plan).totalWords
        open(document, startWord: min(saved.wordIndex, max(total - 1, 0)))
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
    func openFromLibrary(_ row: ReadingPosition) async -> Bool {
        guard let store else {
            libraryMessage = LibraryCopy.noStore
            return false
        }
        libraryMessage = nil
        do {
            if let document = try store.document(id: row.documentID) {
                openAtPlace(document, row: row)
                return true
            }
        } catch {
            libraryMessage = LibraryCopy.openFailed
            return false
        }
        // The row outlives a cache bust, so its URL is the way back.
        guard let url = row.url else {
            libraryMessage = LibraryCopy.needsLink
            return false
        }
        return await refetchAndOpen(row, url: url)
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
        let total = SpokenWordNumbering(plan: document.plan).totalWords
        open(document, startWord: min(row.wordIndex, max(total - 1, 0)))
    }

    private func refetchAndOpen(_ row: ReadingPosition, url: URL) async -> Bool {
        switch await ArticleIngress.fetch(url.absoluteString, telemetry: telemetry) {
        case .failure(let error):
            libraryMessage = error.message
            return false
        case .success(let page):
            switch ArticleIngress.read(page, telemetry: telemetry) {
            case .failure(let error):
                libraryMessage = error.message
                return false
            case .success(let document):
                try? store?.save(document: document)
                openAtPlace(document, row: row)
                return true
            }
        }
    }

    /// Writes the current place now. Called on pause-adjacent transitions the
    /// throttle might miss: close, background, and anywhere the app can die.
    func flushPosition() {
        guard let session, let recorder, session.progress.totalWords > 0 else { return }
        recorder.record(document: session.document, wordIndex: session.progress.wordIndex, source: "flush")
        recorder.wait()
    }

    private func recordPosition(index: Int, source: String) {
        guard let session, let recorder else { return }
        recorder.record(document: session.document, wordIndex: index, source: source)
    }
}

struct RootView: View {
    @State private var model: AppModel
    let registry: PackRegistry
    let diagnostics: any DiagnosticsExporting
    let telemetry: TelemetryHub
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system.rawValue
    @AppStorage("rl-seen-demo") private var seenDemo = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        registry: PackRegistry,
        speedStore: SpeedStore,
        diagnostics: any DiagnosticsExporting,
        telemetry: TelemetryHub
    ) {
        self.registry = registry
        self.diagnostics = diagnostics
        self.telemetry = telemetry
        _model = State(initialValue: AppModel(
            packs: registry, telemetry: telemetry, speedStore: speedStore))
    }

    var body: some View {
        @Bindable var bound = model
        Group {
            if let session = model.session {
                ReaderScreen(
                    session: session, registry: registry, telemetry: telemetry,
                    onExit: model.closeDocument)
                    .transition(.opacity)
                    // Escape closes card/note from any focus inside the
                    // reader. Hoisted here because RootView.body runs once per
                    // document while ReaderScreen.body rebuilds per wash tick;
                    // recreating the handler each tick rewrites the KeyPress
                    // environment and re-evaluates the rail buttons (M7).
                    // Same focus scope as before: every path out of the reader
                    // passes through here. No behavior change.
                    .onKeyPress(.escape) {
                        if session.lookupState.card != nil {
                            session.closeCard()
                            return .handled
                        }
                        if session.lookupState.note != nil {
                            session.closeNote()
                            return .handled
                        }
                        return .ignored
                    }
            } else {
                EntryView(
                    telemetry: telemetry,
                    onOpen: { model.open($0) },
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
        .sheet(isPresented: $bound.isSettingsPresented) {
            SettingsView(packs: registry, diagnostics: diagnostics)
        }
        .sheet(isPresented: $bound.isLibraryPresented) {
            LibraryView(
                provider: LibraryAdapter(model: model),
                onClose: { model.isLibraryPresented = false }
            )
        }
        .animation((debugDisablesMotion || reduceMotion) ? nil : ThemeMotion.screen, value: model.session == nil)
        // One demo open sets the first-run flag, whichever path opened it:
        // entry or the library.
        .onChange(of: model.session?.document.url) { _, url in
            if LibraryCopy.isDemo(url: url) { seenDemo = true }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                model.session?.pauseForBackground()
                telemetry.record(TelemetryName.appHide)
                model.flushPosition()
            case .active:
                telemetry.record(TelemetryName.appReturn)
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
        #if os(iOS) && DEBUG
        .task { @MainActor in
            guard let delay = DebugLaunch.options.autoPlayAfterMs else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            } catch {
                return
            }
            // Same path as the entry tap and the play button. The tap starts
            // the telemetry run, so T7.firstWord lands in the trace.
            telemetry.record(TelemetryName.tap)
            if model.session == nil {
                model.openLatestSavedPlace()
            }
            if let session = model.session, !session.playbackState.isPlaying {
                session.togglePlay()
            }
        }
        #endif
        #if os(macOS)
        .task {
            if SnapshotHarness.isEnabled {
                await SnapshotHarness.run(app: model, registry: registry, telemetry: telemetry)
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
    let session: ReaderSession
    let registry: any CapabilityPacks
    let telemetry: TelemetryHub
    let onExit: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var washVisible = true
    @State private var returnToken = 0
    @State private var clockMode = 0
    @State private var lastProgrammaticFollow = Date.distantPast

    var body: some View {
        VStack(spacing: 0) {
            chrome
            // The rail stops above the full-width bottom bar, which holds the
            // clock and the transport.
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    reader
                    rail
                }
                bottomBar
            }
        }
    }

    private var reader: some View {
        ReaderView(
            document: session.document,
            blockRoles: session.blockRoles,
            wash: session.washState,
            playback: session.playbackState,
            spoken: session.spoken,
            autoScroll: session.playbackState.autoScroll && !session.playbackState.isScrubbing,
            isScrubbing: session.playbackState.isScrubbing,
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
                        isHeld: session.playbackState.isHeld,
                        isPlaying: session.playbackState.isPlaying,
                        onResume: {
                            lastProgrammaticFollow = Date()
                            session.resumeFollowing()
                        }
                    )
                    if shouldShowReturnPill(
                        washVisible: washVisible,
                        isHeld: session.playbackState.isHeld,
                        isPlaying: session.playbackState.isPlaying
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
        ReaderRail(session: session, arrowHandler: scrubArrowHandler)
    }

    /// Reads `session.progress` in its own body. A wash tick rebuilds this
    /// rail and nothing in `ReaderScreen`.
    private struct ReaderRail: View {
        let session: ReaderSession
        let arrowHandler: (KeyPress) -> KeyPress.Result

        var body: some View {
            RailView(
                progress: session.progress,
                onSpeed: { session.setSpeed($0) },
                onScrub: { session.scrub(toFraction: $0) },
                onPreviewScrub: { session.previewScrub(toFraction: $0) },
                onScrubbingChanged: { scrubbing in
                    if scrubbing { session.beginScrubbing() } else { session.finishScrubbing() }
                },
                arrowHandler: arrowHandler
            )
        }
    }

    /// Arrow-key handler for the rail scrubber. Captures only the session, so
    /// its content is identical on every wash tick; passing it straight
    /// through keeps the KeyPress environment stable (M7 third cut). Reads
    /// the live wash position at press time, same word as the old handler.
    private var scrubArrowHandler: (KeyPress) -> KeyPress.Result {
        { [session] press in
            switch press.key {
            case .upArrow:
                session.seekWords(-1)
                return .handled
            case .downArrow:
                session.seekWords(1)
                return .handled
            default:
                return .ignored
            }
        }
    }

    /// Bottom bar: clock at the left edge, transport at the right. Tapping the
    /// clock cycles 0 time+count, 1 count, 2 percent. The trailing edge matches
    /// the rail's gutter. The top and bottom gaps keep the play button off the
    /// hairline and the window border.
    private var bottomBar: some View {
        HStack(spacing: 0) {
            clockButton
            Spacer(minLength: 0)
            BottomTransport(
                isPlaying: session.playbackState.isPlaying,
                isFinished: session.playbackState.isFinished,
                onPlayPause: { session.togglePlay() },
                onStepUtterance: { session.stepUtterance($0) }
            )
        }
        .padding(.leading, Theme.screenGutter)
        .frame(height: Theme.minTarget)
        .padding(.trailing, RailView.trailingGutter)
        .padding(.top, Theme.stackGap)
        .padding(.bottom, Theme.stackGap)
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Theme.line.frame(height: 1)
        }
    }

    private var clockButton: some View {
        ReaderClock(session: session, mode: $clockMode)
    }

    /// Reads `session.progress` in its own body, like `ReaderRail`.
    private struct ReaderClock: View {
        let session: ReaderSession
        @Binding var mode: Int

        var body: some View {
            Button {
                mode = (mode + 1) % 3
            } label: {
                Text(session.progress.clockText(mode: mode))
                    .font(Theme.mono())
                    .foregroundStyle(Theme.inkSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clock \(modeLabel), tap to change format")
            .accessibilityValue(session.progress.clockText(mode: mode))
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier(AccessibilityID.clock)
        }

        private var modeLabel: String {
            switch mode {
            case 1: return "count"
            case 2: return "percent"
            default: return "time and count"
            }
        }
    }

    private var chrome: some View {
        ReaderChrome(
            title: session.document.title,
            autoScroll: session.playbackState.autoScroll,
            isHeld: session.playbackState.isHeld,
            offScreen: !washVisible,
            isFinished: session.playbackState.isFinished,
            onExit: onExit,
            onRestart: {
                session.scrub(toFraction: 0)
                session.resumeFollowing()
            },
            onToggleFollow: {
                if session.playbackState.autoScroll {
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
        if let card = session.lookupState.card {
            CardSheet(onDismiss: { session.closeCard() }) {
                switch card {
                case let .hit(result, wordIndex, wasPlaying):
                    LookupCard(
                        telemetry: telemetry,
                        result: result,
                        wasPlayingBeforeLookup: wasPlaying,
                        wordIndex: wordIndex,
                        isCurrentWashWord: wordIndex != nil && wordIndex == session.washState.wordIndex,
                        onClose: { session.closeCard() }
                    )
                case let .miss(word, kind, wordIndex, wasPlaying):
                    MissCard(
                        telemetry: telemetry,
                        word: word,
                        kind: kind,
                        packInstalled: registry.isInstalled,
                        isOnline: session.lookupState.isOnline,
                        offerDeclined: registry.offerDeclined,
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
            .animation(reduceMotion ? nil : ThemeMotion.sheet, value: session.lookupState.card == nil)
            .zIndex(2)
        }

        if let note = session.lookupState.note, session.document.noteBlocks.indices.contains(note.index) {
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
///
/// Equatable (data-only, closures ignored): the parent rebuilds every tick
/// with identical values, and without this the bar, menu and icon buttons
/// re-evaluate per wash word (M7).
struct ReaderChrome: View, Equatable {
    let title: String
    let autoScroll: Bool
    let isHeld: Bool
    let offScreen: Bool
    let isFinished: Bool
    let onExit: () -> Void
    let onRestart: () -> Void
    let onToggleFollow: () -> Void
    let onReplay: () -> Void

    nonisolated static func == (lhs: ReaderChrome, rhs: ReaderChrome) -> Bool {
        lhs.title == rhs.title
            && lhs.autoScroll == rhs.autoScroll
            && lhs.isHeld == rhs.isHeld
            && lhs.offScreen == rhs.offScreen
            && lhs.isFinished == rhs.isFinished
    }

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
