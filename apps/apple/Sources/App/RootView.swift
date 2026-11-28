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
    /// Ingress name for the Reader-entry event. Every open names its path.
    private(set) var readerSource: EntrySource = .library
    /// Changes on every open, so SwiftUI builds fresh Reader state per open.
    private(set) var openToken = 0
    /// One line the reader shows after an open that reset the place: the
    /// rewrite gate or a lost library row. Separate from `libraryMessage`
    /// because the library sheet closes the moment the reader opens, so a
    /// library line would never be seen (and would go stale there).
    private(set) var readerNotice: String?
    /// The root's two sheets. The model owns them so the open paths and the
    /// snapshot harness raise the same screens the buttons raise.
    var isLibraryPresented = false
    var isSettingsPresented = false

    private let speech: SpeechController
    private let packs: any CapabilityPacks
    private let connectivity: Connectivity
    private let telemetry: TelemetryHub
    private let speedStore: SpeedStore
    private let lookup: PackLookupProvider
    private let store: ReadLaterStore.Store?
    private let recorder: ReadLaterStore.PositionRecorder?
    init(packs: any CapabilityPacks, connectivity: Connectivity, telemetry: TelemetryHub, speedStore: SpeedStore) {
        self.packs = packs
        self.connectivity = connectivity
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

    func open(
        _ document: ReadLaterCore.Document,
        startWord: Int? = nil,
        source: EntrySource,
        page: FetchedPage? = nil
    ) {
        readerSource = source
        openToken += 1
        flushPosition()
        session?.stop()
        readerNotice = nil
        // A successful open re-lists, so a stale sheet message from an
        // earlier action clears here; failures below set their own.
        // (openFromLibrary already clears; Entry opens land here.)
        // Cross-attempt trade-off, documented: a background task that named
        // its failure just before this open loses it to the clear, and this
        // open's own failures set fresh after. Within one attempt
        // first-failure-wins still holds; across attempts the latest action
        // wins, since its list is what the sheet will show.
        libraryMessage = nil
        // The save runs on main (dbQueue.write blocks the caller): accepted
        // under the same M8 exception as the deletes — one user-initiated
        // write per open, and the session needs the row to exist now.
        if store == nil {
            // No library on this device: the reader still opens, but no
            // place is kept. Told in the reader, where it is seen.
            readerNotice = LibraryCopy.noStore
        } else {
            do {
                try store?.save(document: document)
            } catch {
                // The reader still opens: the failure is the library row, not
                // the article. Told in the reader, where it is seen; the
                // library sheet is already closing.
                readerNotice = LibraryCopy.libraryRowLost
            }
        }
        // The bytes this plan was read from, for a future re-plan on a
        // parser change. Best-effort on the recorder's background queue:
        // a zlib pass plus a write never blocks the open path (M8).
        if let page {
            recorder?.persistRawPage(
                RawPage(html: page.html, status: page.status, finalURL: page.url),
                for: document)
        }
        let seed = ReaderSeed(document: document, savedWordIndex: startWord)
        let next = ReaderSession(
            seed: seed, speech: speech, lookupProvider: lookup, packs: packs,
            connectivity: connectivity, telemetry: telemetry, speedStore: speedStore)
        next.onProgress = { [weak self] index, source in self?.recordPosition(index: index, source: source) }
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
        readerNotice = nil
        // Fresh list on exit: a stale message clears, a failed refresh sets.
        libraryMessage = nil
        refreshLibrary()
        telemetry.endRunIfActive(outcome: "closed")
    }

    /// Opens the newest saved place, if any. The resume offer is gone, so
    /// the debug autoplay and any future caller re-enter through the same
    /// door the library uses: latest row, resolved start. Routes through
    /// `store.resolve` like `openAtPlace`, so a parser re-split surfaces
    /// the "article updated" note instead of a blind clamp. A corrupt place
    /// row names `readFailed`; a missing document (released by design)
    /// skips silently, while a corrupt plan or disk failure names
    /// `readFailed` like the row fetch above.
    func openLatestSavedPlace() {
        guard let store else { return }
        let saved: ReadingPosition
        do {
            guard let row = try store.latestUnfinishedPosition() else { return }
            saved = row
        } catch {
            libraryMessage = LibraryCopy.readFailed
            return
        }
        let document: ReadLaterCore.Document?
        do {
            document = try store.document(id: saved.documentID)
        } catch {
            libraryMessage = LibraryCopy.readFailed
            return
        }
        guard let document else {
            // Released rows survive by design; the library path opens (and
            // names failures for) anything still present. Silent skip: the
            // next launch re-reads.
            return
        }
        let reopened = reopenedDocument(document)
        let resolved = store.resolve(row: saved, newPlan: reopened.plan)
        open(reopened, startWord: resolved.start, source: .library)
        // Set after open: open() clears the notice, and the note is
        // informational, so a pre-existing failure would outrank it — but
        // this entry point names no failures, hence the plain nil guard.
        if resolved.rewrote, readerNotice == nil {
            readerNotice = LibraryCopy.articleUpdated
        }
    }

    // MARK: - Library

    /// Reads the browse list again. Called on launch, open, close and after
    /// every library action, so the list never shows a stale row. Runs on
    /// main (dbQueue.read blocks the caller): accepted under the same M8
    /// exception as the deletes — a rare, user-initiated read whose result
    /// the sheet needs synchronously.
    func refreshLibrary() {
        guard let store else {
            library = []
            return
        }
        do {
            library = try store.recentPositions()
        } catch {
            library = []
            // First failure wins: callers (save/release/forget/refetch)
            // name their own failure first, then refresh to list what is
            // there — the refresh must not overwrite it.
            if libraryMessage == nil {
                libraryMessage = LibraryCopy.readFailed
            }
        }
    }

    /// Opens a library row. The stored plan is the normal path; only an older
    /// parser re-plans the saved page bytes first. After a release the plan is
    /// gone, so the page is fetched and read again from its last known URL,
    /// then opened at the same place. Returns true when the article opened,
    /// which the library sheet uses to close itself.
    func openFromLibrary(_ row: ReadingPosition) async -> Bool {
        guard let store else {
            // Unconditional: nothing in-attempt yet (the nil below runs only
            // on the happy path). Mid-attempt sites use if-nil instead, so a
            // sibling-loop failure stands; see the refetch supersede guard.
            libraryMessage = LibraryCopy.noStore
            return false
        }
        libraryMessage = nil
        do {
            if let document = try store.document(id: row.documentID) {
                openAtPlace(reopenedDocument(document), row: row)
                return true
            }
        } catch {
            libraryMessage = LibraryCopy.openFailed
            return false
        }
        // The row outlives a release, so its URL is the way back. The pasted
        // link goes first: the canonical URL may have stripped a key the
        // site needs.
        guard let url = row.originalURL ?? row.url else {
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

    func releaseCopy(_ row: ReadingPosition) {
        libraryMessage = nil
        guard let store else {
            libraryMessage = LibraryCopy.noStore
            return
        }
        // Drain the recorder queue first: a tick enqueued just before this
        // call must land before the delete, or it resurrects the row after.
        // A main-thread drain plus a main-thread delete, against the M8
        // no-block rule: accepted because deletes are rare, user-initiated,
        // and correctness (no resurrect) outranks the stall.
        recorder?.wait()
        do {
            try store.releaseCopy(documentID: row.documentID)
        } catch {
            libraryMessage = LibraryCopy.refreshFailed
        }
        refreshLibrary()
    }

    func forget(_ row: ReadingPosition) {
        libraryMessage = nil
        guard let store else {
            libraryMessage = LibraryCopy.noStore
            return
        }
        // Same drain as releaseCopy: no enqueued tick may land after this.
        // Same M8 exception: rare user action, correctness first.
        // The delete itself also runs on main (dbQueue.write blocks the
        // caller); same exception, same reason.
        recorder?.wait()
        do {
            try store.forget(contentHash: row.contentHash, documentID: row.documentID)
        } catch {
            libraryMessage = LibraryCopy.forgetFailed
        }
        refreshLibrary()
    }

    /// A stored document with a current parser is returned untouched. An older
    /// parser re-plans from the saved page bytes only: no network fetch runs.
    /// The old plan stays on disk until `open` saves the validated result, so
    /// a failed extraction, a missing page or a hash mismatch keeps the
    /// article readable from the plan the reader already has.
    private func reopenedDocument(_ document: ReadLaterCore.Document) -> ReadLaterCore.Document {
        guard document.plan.extractorVersion < BlockPlan.currentExtractorVersion,
              let store,
              let page = try? store.rawPage(
                contentHash: ReadLaterStore.Store.resumeKey(for: document))
        else {
            return document
        }
        return LibraryReopen.document(
            document,
            page: FetchedPage(html: page.html, status: page.status, url: page.finalURL),
            telemetry: telemetry)
    }

    @discardableResult
    private func openAtPlace(_ document: ReadLaterCore.Document, row: ReadingPosition, page: FetchedPage? = nil) -> Int {
        let resolved = store?.resolve(row: row, newPlan: document.plan)
        // Total only for the no-store fallback: resolve already computed it
        // for the normal path, so a second plan walk here would be the third
        // of the open (resolve builds one field, not two, since round-50).
        let start: Int
        if let resolved {
            start = resolved.start
        } else {
            let total = SpokenWordNumbering(plan: document.plan).totalWords
            start = min(max(row.wordIndex, 0), max(total - 1, 0))
        }
        open(document, startWord: start, source: .library, page: page)
        // Set after open: open() clears the notice, and a failed save
        // (row loss) outranks the rewrite note.
        if resolved?.rewrote == true, readerNotice == nil {
            readerNotice = LibraryCopy.articleUpdated
        }
        // A retire that threw leaves a missing-document sibling behind; the
        // next tick seeds a second row and the library shows two until
        // something retires the stale one. Absorb it now: same URL, bytes
        // gone, so its only value is the saved flag it carries. Present
        // siblings are live entries the user can still open — never touched.
        // One small read per open plus rare writes, under the same M8
        // exception as the save above. Libraries with released pre-v5 rows
        // pay a COUNT plus the widened scan, still gated to those rows.
        if let urlString = document.url?.absoluteString, let store {
            let key = ReadLaterStore.Store.resumeKey(for: document)
            // A corrupt position row (bad UUID, undecodable) throws out of
            // the sibling lookup itself: name it like a corrupt document
            // below instead of skipping in silence.
            let siblings: [ReadingPosition]
            do {
                siblings = try store.siblingRows(url: urlString, excluding: key)
            } catch {
                // The reader is open (open() already ran): the sheet line
                // is invisible until it closes, so name it on both surfaces
                // like the refetch supersede failure below. Failures outrank
                // the informational rewrite note but the first one wins.
                if libraryMessage == nil {
                    libraryMessage = LibraryCopy.readFailed
                }
                if readerNotice == nil || readerNotice == LibraryCopy.articleUpdated {
                    readerNotice = LibraryCopy.readFailed
                }
                return start
            }
            var absorbed = false
            for sibling in siblings {
                // The refetch supersede below retires `row` itself: absorbing
                // it here too would seed the new row twice (converges via the
                // merge, but costs a second write). The only other caller of
                // `openAtPlace` passes a row whose hash already equals the new
                // key, so it is never a sibling and the skip never fires
                // there.
                guard sibling.contentHash != row.contentHash else { continue }
                // A corrupt plan decodes to a throw, not a nil: never
                // absorb it (its history is not known-gone), and name
                // the failure instead of healing past it.
                let siblingDoc: ReadLaterCore.Document?
                do {
                    siblingDoc = try store.document(id: sibling.documentID)
                } catch {
                    if libraryMessage == nil {
                        libraryMessage = LibraryCopy.readFailed
                    }
                    if readerNotice == nil || readerNotice == LibraryCopy.articleUpdated {
                        readerNotice = LibraryCopy.readFailed
                    }
                    continue
                }
                guard siblingDoc == nil else { continue }
                do {
                    try store.supersedeOnRefetch(oldRow: sibling, newDocument: document, startWord: start)
                    absorbed = true
                } catch {
                    // A real write failure (not a missing row): the stale
                    // duplicate stays until the next open heals it. Name it
                    // on both surfaces; other siblings may still absorb.
                    if libraryMessage == nil {
                        libraryMessage = LibraryCopy.refreshFailed
                    }
                    if readerNotice == nil || readerNotice == LibraryCopy.articleUpdated {
                        readerNotice = LibraryCopy.refreshFailed
                    }
                    continue
                }
            }
            if absorbed {
                refreshLibrary()
            }
        }
        return start
    }

    private func refetchAndOpen(_ row: ReadingPosition, url: URL) async -> Bool {
        switch await ArticleIngress.fetch(url.absoluteString, telemetry: telemetry) {
        case .failure(let error):
            // An expired short link fails while the canonical URL still
            // works. One retry on the canonical URL, then the message.
            // Normalized like the rescue below: a case/port/fragment
            // variant of the canonical URL is the same resource, not a
            // reason to fetch twice.
            if let canonical = row.url,
               ArticleIngress.originalForRefetch(request: url, canonical: canonical) != nil {
                return await refetchAndOpen(row, url: canonical)
            }
            // First failure wins, like every other sheet message.
            if libraryMessage == nil {
                libraryMessage = error.message
            }
            return false
        case .success(let page):
            switch ArticleIngress.read(page, telemetry: telemetry, original: ArticleIngress.originalForRefetch(request: url, canonical: row.url)) {
            case .failure(let error):
                if libraryMessage == nil {
                    libraryMessage = error.message
                }
                return false
            case .success(let document):
                let start = openAtPlace(document, row: row, page: page)
                // Changed bytes mint a new id and hash: retire the old row
                // so the library keeps one row per article. Runs on main
                // (dbQueue.write blocks the caller): accepted under the same
                // M8 exception as the deletes — one rare user-initiated
                // write per refetch, and the rows must retire together.
                // The seeded row carries the old link; a rescue still in
                // flight retargets to the new row below. Refresh after: the
                // seed replaced the row `open()` already listed.
                var clearHash = row.contentHash
                var clearDoc = row.documentID
                if ReadLaterStore.Store.resumeKey(for: document) != row.contentHash {
                    do {
                        guard let store else {
                            // First failure wins, like every other sheet message.
                            if libraryMessage == nil {
                                libraryMessage = LibraryCopy.noStore
                            }
                            return true
                        }
                        try store.supersedeOnRefetch(oldRow: row, newDocument: document, startWord: start)
                    } catch {
                        // The session already holds the new bytes, but the
                        // transaction rolled back: no row seeded, old row
                        // intact with its bytes already gone (that is why
                        // this refetched). The next tick seeds the new row;
                        // the next open heals either way: the new row
                        // absorbs its document-less sibling, the old row
                        // refetches and retires again (see `openAtPlace`).
                        // Name it where it is seen — the reader is open —
                        // and list what is there. A failure outranks the
                        // informational rewrite note; the first one wins, so
                        // an earlier sibling-loop failure stands on both.
                        if libraryMessage == nil {
                            libraryMessage = LibraryCopy.refreshFailed
                        }
                        if readerNotice == nil || readerNotice == LibraryCopy.articleUpdated {
                            readerNotice = LibraryCopy.refreshFailed
                        }
                        refreshLibrary()
                        return true
                    }
                    clearHash = ReadLaterStore.Store.resumeKey(for: document)
                    clearDoc = document.id
                    refreshLibrary()
                }
                // The canonical fallback rescued a dead pasted link: drop it
                // from both rows so later opens fetch once, from the
                // canonical URL. After `openAtPlace`: `open()` flushes the
                // old session (a tick carrying the dead link) and re-saves
                // the document (nil original keeps the old link via
                // COALESCE) — clears enqueued before either would lose to
                // them. Enqueued behind everything on the same serial queue,
                // so no drain blocks this path; new-session ticks carry nil
                // and keep the cleared NULL. A failed clear only costs a
                // double fetch: the next fallback retries. The request is
                // compared normalized, so case/port/fragment variants of
                // the pasted link still read as the link itself.
                if let original = row.originalURL,
                   ArticleIngress.originalForRefetch(request: url, canonical: original) != nil {
                    // One block clears both rows: split enqueues could leave
                    // the document row holding the dead link, and the next
                    // open would tick it back into the position row.
                    // Retargeted above when a supersede seeded a new row.
                    recorder?.clearRescuedLink(contentHash: clearHash, documentID: clearDoc)
                }
                return true
            }
        }
    }

    /// Writes the current place now. Called on pause-adjacent transitions the
    /// throttle might miss: close, background, and anywhere the app can die.
    /// The drain blocks the caller (main on close/background): accepted,
    /// because losing the place outranks the stall, and the queue holds at
    /// most a few lightweight writes.
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
    let connectivity: Connectivity
    let speedStore: SpeedStore
    let diagnostics: any DiagnosticsExporting
    let telemetry: TelemetryHub
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system.rawValue
    @AppStorage("rl-seen-demo") private var seenDemo = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        registry: PackRegistry,
        connectivity: Connectivity,
        speedStore: SpeedStore,
        diagnostics: any DiagnosticsExporting,
        telemetry: TelemetryHub
    ) {
        self.registry = registry
        self.connectivity = connectivity
        self.speedStore = speedStore
        self.diagnostics = diagnostics
        self.telemetry = telemetry
        _model = State(initialValue: AppModel(
            packs: registry, connectivity: connectivity, telemetry: telemetry, speedStore: speedStore))
    }

    var body: some View {
        @Bindable var bound = model
        Group {
            if let session = model.session {
                ReaderScreen(
                    session: session, registry: registry, connectivity: connectivity, telemetry: telemetry,
                    source: model.readerSource,
                    onExit: model.closeDocument, notice: model.readerNotice)
                    .id(model.openToken)
                    .transition(.opacity)
                    // Escape closes card/note from any focus inside the
                    // reader. Hoisted here because RootView.body runs once per
                    // document while ReaderScreen.body rebuilds per wash tick;
                    // recreating the handler each tick rewrites the KeyPress
                    // environment and re-evaluates the rail buttons (M7).
                    // Same focus scope as before: every path out of the reader
                    // passes through here. No behavior change.
                    .onKeyPress(.escape) {
                        if session.lookup.state.card != nil {
                            session.lookup.closeCard()
                            return .handled
                        }
                        if session.lookup.state.note != nil {
                            session.lookup.closeNote()
                            return .handled
                        }
                        return .ignored
                    }
            } else {
                EntryView(
                    telemetry: telemetry,
                    onOpen: { document, source, page in
                        model.open(document, source: source, page: page)
                    },
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
            // the telemetry run, so speech.first_word lands in the trace.
            telemetry.record(TelemetryName.entryTap)
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
        #if DEBUG
        .task {
            if let count = DebugLaunch.options.interactionIterations, count > 0,
               !SnapshotHarness.isEnabled
            {
                await InteractionBenchmark.run(app: model, telemetry: telemetry, iterations: count)
            }
        }
        #endif
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
    let connectivity: Connectivity
    let telemetry: TelemetryHub
    let source: EntrySource
    let onExit: () -> Void
    /// Set when the open reset the place (rewrite gate) or lost the
    /// library row. Shown under the chrome; cleared on close.
    var notice: String? = nil

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var washVisible = true
    @State private var returnToken = 0
    @State private var clockMode = 0
    @State private var lastProgrammaticFollow = Date.distantPast

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                chrome
                if let notice {
                    Text(notice)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.screenGutter)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier(AccessibilityID.readerNotice)
                }
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
            // Screen-level layer above chrome + reader + rail + bottomBar, so
            // the scrim dims everything and the card stays on top. Previously
            // this lived inside ReaderView's reader-column ZStack, whose frame
            // is only the left column: ignoresSafeArea could not escape that
            // column, leaving chrome/rail/transport white.
            overlay
        }
    }

    private var reader: some View {
        ReaderView(
            document: session.document,
            blockRoles: session.blockRoles,
            wash: session.washState,
            playback: session.playbackState,
            selectedWordIndex: session.lookup.selectedWordIndex,
            spoken: session.spoken,
            autoScroll: session.playbackState.autoScroll && !session.playbackState.isScrubbing,
            isScrubbing: session.playbackState.isScrubbing,
            returnToken: returnToken,
            telemetry: telemetry,
            source: source,
            onTapWord: { _, slot, word in
                session.lookup.tap(slot: slot, word: word)
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
            overlay: { EmptyView() }
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
        if let card = session.lookup.state.card {
            CardSheet(onDismiss: { session.lookup.closeCard() }) {
                Group {
                    switch card {
                    case let .hit(result, wordIndex, wasPlaying):
                        LookupCard(
                            telemetry: telemetry,
                            result: result,
                            wasPlayingBeforeLookup: wasPlaying,
                            wordIndex: wordIndex,
                            isCurrentWashWord: wordIndex != nil && wordIndex == session.washState.wordIndex,
                            onPronounce: { session.pronounce(result.word) },
                            onClose: { session.lookup.closeCard() }
                        )
                    case let .miss(word, kind, wordIndex, wasPlaying):
                        MissCard(
                            telemetry: telemetry,
                            word: word,
                            kind: kind,
                            packInstalled: registry.isInstalled,
                            isOnline: connectivity.status != .offline,
                            offerDeclined: registry.offerDeclined,
                            isInstalling: registry.isInstalling,
                            wasPlayingBeforeLookup: wasPlaying,
                            wordIndex: wordIndex,
                            onPronounce: { session.pronounce(word) },
                            onInstall: { Task { await session.lookup.installPack() } },
                            onNotNow: { session.lookup.declineOffer() },
                            onClose: { session.lookup.closeCard() },
                            onSearchWeb: {
                                let query = word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? word
                                if let url = URL(string: "https://duckduckgo.com/?q=\(query)") {
                                    openURL(url)
                                }
                                session.lookup.closeCard()
                            }
                        )
                    }
                }
                // A new card is a new identity, so its `didLogShown` starts false.
                // Without this, a card that swaps in the same slot keeps the
                // previous card's state and never logs `card.shown`.
                .id(card.id)
            }
            .animation(reduceMotion ? nil : ThemeMotion.sheet, value: session.lookup.state.card == nil)
            .zIndex(2)
        }

        if let note = session.lookup.state.note, session.document.noteBlocks.indices.contains(note.index) {
            let block = session.document.noteBlocks[note.index]
            ZStack {
                Theme.scrim
                    .ignoresSafeArea()
                    .onTapGesture { session.lookup.closeNote() }
                VStack {
                    Spacer(minLength: 0)
                    FootnoteOverlay(
                        marker: "¹",
                        text: block.text,
                        pauseLine: note.wasPlaying ? "Audio paused · resumes on close" : "Audio was already paused · stays paused",
                        onTapWord: { word in session.lookup.tap(slot: nil, word: word) },
                        onClose: { session.lookup.closeNote() }
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
