import ReadLaterCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The three extraction stages, in order. One table maps each stage to its
/// label and progress, so the view and the tests read the same values.
public enum EntryStage: Int, Sendable, CaseIterable {
    case fetching
    case stripping
    case ready

    public var step: (label: String, progress: Double) {
        switch self {
        case .fetching: return ("Fetching page…", 0.3)
        case .stripping: return ("Removing nav · ads…", 0.65)
        case .ready: return ("Body ready", 1.0)
        }
    }

    public var label: String { step.label }
    public var progress: Double { step.progress }
}

/// Entry flow state. The stage table lives on `EntryStage`, so tests cover
/// it without a view.
public enum EntryState: Sendable, Equatable {
    case idle
    case loading(stage: EntryStage, progress: Double)
    case refused(String)
}

/// Every reader-facing string on the entry screen, in one type.
public enum EntryCopy {
    public static let heading = "Read it later"
    public static let description =
        "Paste a link or a few paragraphs. We fetch the clean text and prepare audio."
    public static let fieldPlaceholder = "Paste a link or a paragraph…"
    public static let fieldLabel = "Link or text"
    public static let linkMode = "Link"
    public static let textMode = "Text"
    public static let linkCaption = "Paste link"
    public static let linkHint = "The prefilled link opens the sample article."
    /// The caption for any link that is not the prefilled sample. Saying
    /// "prefilled" over an empty field is a lie the reader can see.
    public static let linkHintEdited = "A web link opens the article."
    public static let rawCaption = "Raw text"
    public static let rawPlaceholder = "Paste a paragraph to read…"
    public static let open = "Open"
    public static let opening = "Opening…"
    public static let settings = "Settings"
    public static let pasteFromClipboard = "Paste from clipboard"
    public static let pasteHint = "Paste a link and open it"
    /// A paste tap that lands nothing. iOS can hold the app in an
    /// explicitly denied paste-permission state, where every read fails
    /// with "Operation not authorized" and no prompt ever returns; a
    /// silent no-op reads as a broken button.
    public static let pasteBlockedNote =
        "Paste is blocked — allow ReadLater to read the clipboard in Settings (Paste from Other Apps)."
    public static let extracting = "Extracting…"
    public static let emptyRefusal = "Nothing to open — paste a link or some text."
    public static let emptyRefusalNoClipboard =
        "Nothing to open — copy a link or some text first."
    public static let sampleLink = "https://www.theatlantic.com/reading/slow"

    /// Strip titles and subtitles for each detector kind.
    public static func stripTitle(for kind: EntryKind, wordCount: Int) -> String {
        switch kind {
        case .empty: return "Paste to begin"
        case .link: return "Article link"
        case .text: return "Pasted text · \(wordCount) words"
        }
    }

    public static func stripSubtitle(for kind: EntryKind, value: String) -> String {
        switch kind {
        case .empty:
            return "A link or a few paragraphs"
        case .link:
            return "\(EntryDetector.domain(of: value)) · fetches full text + audio"
        case .text:
            return "“\(EntryDetector.preview(of: value))…” · opens instantly"
        }
    }

    /// The link caption follows the field: the sample variant only when the
    /// field really holds the sample.
    public static func linkHint(for text: String) -> String {
        text == sampleLink ? linkHint : linkHintEdited
    }
}

/// One open reads the field as one kind. Link stays first, so a pasted
/// paragraph never hijacks a link open.
public enum EntryMode: String, Sendable, CaseIterable {
    case link
    case text

    public var title: String {
        switch self {
        case .link: return EntryCopy.linkMode
        case .text: return EntryCopy.textMode
        }
    }
}

/// The input as tapped. `load` only reads this value, never live state,
/// so an edit during fetch cannot steer the in-flight request.
struct EntryRequest: Sendable, Equatable {
    var mode: EntryMode
    var link: String
    var raw: String
    /// Ingress name captured at the tap, before any async work can change it.
    var source: EntrySource

    init(mode: EntryMode = .link, linkText: String, rawText: String, source: EntrySource = .link) {
        self.mode = mode
        self.link = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source
    }

    /// Only the active mode counts. The hidden field keeps its text, but an
    /// open never reads it.
    var isEmpty: Bool {
        switch mode {
        case .link: return link.isEmpty
        case .text: return raw.isEmpty
        }
    }
}

/// The first screen: one field, a status strip, one Open button, and a
/// loadline that appears below the button on the first open.
public struct EntryView: View {
    private let telemetry: TelemetryHub
    private let onOpen: (ReadLaterCore.Document, EntrySource, FetchedPage?) -> Void
    private let onSettings: (() -> Void)?
    private let onLibrary: (() -> Void)?
    /// True for the clipboard-empty variant: no paste button, and the empty
    /// refusal names copying first. Never read live: the host picks the
    /// variant, so iOS shows no permission prompt.
    private let clipboardEmpty: Bool

    @State private var inputText: String
    @State private var state: EntryState = .idle
    @State private var hasAttempted = false
    @State private var settledStage: EntryStage?
    @State private var pulseOn = false
    @State private var shimmerX: CGFloat = -80
    @State private var pasteHover = false
    /// Set when the clipboard button puts text in the field. Consumed by the
    /// next Open, so a typed link is not reported as a clipboard link.
    @State private var inputFromClipboard = false
    #if !os(macOS)
    @State private var pasteBlocked = false
    @State private var pasting = false
    #endif
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        telemetry: TelemetryHub,
        onOpen: @escaping (ReadLaterCore.Document, EntrySource, FetchedPage?) -> Void,
        onSettings: (() -> Void)? = nil,
        onLibrary: (() -> Void)? = nil,
        prefillLink: String = EntryCopy.sampleLink,
        clipboardEmpty: Bool = false
    ) {
        self.telemetry = telemetry
        self.onOpen = onOpen
        self.onSettings = onSettings
        self.onLibrary = onLibrary
        self.clipboardEmpty = clipboardEmpty
        self._inputText = State(initialValue: prefillLink)
    }

    private var kind: EntryKind { EntryDetector.classify(inputText) }
    private var trimmedInput: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var body: some View {
        VStack(spacing: 0) {
            chrome
            VStack(alignment: .leading, spacing: 0) {
                Text(EntryCopy.heading)
                .font(Theme.title())
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 12)
            Text(EntryCopy.description)
                .font(Theme.caption())
                .foregroundStyle(Theme.inkSecondary)
                .padding(.top, 4)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $inputText)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 15))
                    .frame(minHeight: 88, maxHeight: 132)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.cardRadius)
                            .stroke(Theme.line, lineWidth: 1)
                    )
                    .accessibilityLabel(EntryCopy.fieldLabel)
                    .accessibilityIdentifier(AccessibilityID.entryLinkField)
                    .disabled(isLoading)
                    .focused($fieldFocused)
                if trimmedInput.isEmpty {
                    Text(EntryCopy.fieldPlaceholder)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.inkSecondary)
                        .padding(.horizontal, 12)
                        // The editor draws its text below its padding by the
                        // platform text-container inset. iOS is 6 + 8 by
                        // UITextView default. macOS measured: placeholder
                        // glyph top 183 pt vs real-text 179.5 pt at padding
                        // 9, so 6 meets the text.
                        #if os(macOS)
                        .padding(.vertical, 6)
                        #else
                        .padding(.vertical, 14)
                        #endif
                        .allowsHitTesting(false)
                }
            }
            .padding(.top, 12)
            strip
                .padding(.top, 12)
            Button(isLoading ? EntryCopy.opening : EntryCopy.open) {
                open()
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .padding(.top, 12)
            .disabled(isLoading)
            .accessibilityLabel(isLoading ? EntryCopy.opening : EntryCopy.open)
            .accessibilityIdentifier(AccessibilityID.entryOpen)
            // Feedback expands below Open. Open never moves.
            if hasAttempted {
                loadline
                    .padding(.top, 12)
            }
            if case .refused(let message) = state {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.holdInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.buttonRadius)
                            .fill(Theme.holdSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.buttonRadius)
                            .stroke(Theme.holdBorder, lineWidth: 1)
                    )
                    .padding(.top, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(message)
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityIdentifier(AccessibilityID.entryError)
            }
            Spacer(minLength: 0)
                .onTapGesture { fieldFocused = false }
            }
            .padding(.horizontal, Theme.screenGutter)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.paper)
        .toolbar {
            // Return inserts a newline in the editor, so it needs its own
            // dismiss path.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { fieldFocused = false }
            }
        }
        .onAppear { telemetry.markEntryReady() }
    }

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    /// The top bar: library left, settings right, one shared look. The
    /// system has no icon-plus-label bar variant (§7 is icon-only, the
    /// library header close is text-only), so the chrome button is its own
    /// thing: 13 semibold ink, 14 pt glyph, one control-gap between glyph
    /// and label, 44 pt target, plain style.
    @ViewBuilder
    private var chrome: some View {
        // Settings live here, not in the reading menu: reading controls
        // change while reading, Settings never does. The library is a
        // place, not a reading control, so it sits opposite the gear.
        HStack(spacing: Theme.controlGap) {
            if let onLibrary {
                chromeButton(
                    title: LibraryCopy.title, systemImage: "book",
                    id: AccessibilityID.entryLibrary, action: onLibrary)
            }
            Spacer(minLength: 0)
            if let onSettings {
                chromeButton(
                    title: EntryCopy.settings, systemImage: "gearshape",
                    id: AccessibilityID.entrySettings, action: onSettings)
            }
        }
        .padding(.horizontal, Theme.stackGap)
        .background(Theme.surface)
        .overlay(Divider(), alignment: .bottom)
    }

    private func chromeButton(
        title: String, systemImage: String, id: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.controlGap) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Theme.ink)
            .frame(minHeight: Theme.minTarget)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    /// The B2-S strip: a 4 pt state edge, a status line, and the paste
    /// control folded inside while the field is empty.
    @ViewBuilder
    private var strip: some View {
        let words = EntryDetector.words(in: trimmedInput)
        let showPaste = trimmedInput.isEmpty && !clipboardEmpty
        let edge: Color = {
            switch kind {
            case .link: return Theme.brand
            case .text: return Theme.ink
            case .empty: return Theme.line
            }
        }()
        HStack(spacing: 0) {
            edge
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind == .empty && clipboardEmpty
                    ? "Nothing on the clipboard"
                    : EntryCopy.stripTitle(for: kind, wordCount: words.count))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(kind == .empty && clipboardEmpty
                    ? "Copy a link or some text first — then paste it here."
                    : EntryCopy.stripSubtitle(for: kind, value: trimmedInput))
                    .font(Theme.caption())
                    .foregroundStyle(Theme.inkSecondary)
                    // One line, tail-clipped: a long paste must not push
                    // the card open.
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Paste on tap, from the tap only: the host picks the
                // variant, so there is no live clipboard read.
                //
                // macOS is one visible control: the label IS the button
                // (styled line, whole 44 pt row, `.plain`, no chrome). A
                // transparent overlay twin never fires on AppKit — an
                // empty label has no hit area — so the label is the
                // button. macOS reads the board directly (no prompt
                // there): string flavor first, then RTF data, then a bare
                // URL object (Copy Link / Universal Clipboard can hold
                // public.url with no plain text; a String-only read
                // silently ignores that tap).
                //
                // iOS: a plain Button owns the tap and reads the board
                // directly, which may show the native paste prompt in the
                // Ask state. PasteButton is not used: its provider reads
                // may skip that prompt.
                if showPaste {
                    #if os(macOS)
                    Button {
                        if let text = EntryPaste.appKitBoardText() {
                            inputText = text
                            inputFromClipboard = true
                        }
                    } label: {
                        Text(EntryCopy.pasteFromClipboard)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.brand)
                            .underline(pasteHover)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                            .accessibilityIdentifier(AccessibilityID.entryPasteLabel)
                    }
                    .buttonStyle(.plain)
                    .onHover { pasteHover = $0 }
                    .disabled(isLoading)
                    .accessibilityIdentifier(AccessibilityID.entryPaste)
                    #else
                    Button {
                        pasting = true
                        EntryPaste.pasteFromBoard(
                            telemetry: telemetry,
                            deliver: { text in
                                MainActor.assumeIsolated {
                                    pasting = false
                                    pasteBlocked = false
                                    inputText = text
                                    inputFromClipboard = true
                                }
                            },
                            fail: {
                                MainActor.assumeIsolated {
                                    pasting = false
                                    pasteBlocked = true
                                }
                            }
                        )
                    } label: {
                        Text(EntryCopy.pasteFromClipboard)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.brand)
                            .underline(pasteHover)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                            .accessibilityIdentifier(AccessibilityID.entryPasteLabel)
                    }
                    .buttonStyle(.plain)
                    .onHover { pasteHover = $0 }
                    .disabled(pasting || isLoading)
                    .accessibilityLabel(EntryCopy.pasteFromClipboard)
                    .accessibilityIdentifier(AccessibilityID.entryPaste)
                    #endif
                }
                #if !os(macOS)
                if showPaste && pasteBlocked {
                    Text(EntryCopy.pasteBlockedNote)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.holdInk)
                        .padding(.top, 6)
                }
                #endif
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(
                    Theme.line,
                    style: kind == .empty
                        ? StrokeStyle(lineWidth: 1, dash: [5, 4])
                        : StrokeStyle(lineWidth: 1)
                )
        )
        // The 4 pt edge is a bare Color, which is vertically flexible and
        // would drink the VStack leftover, stretching the card. The strip
        // hugs its content; the Spacer below takes the rest.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(stripAccessibilityLabel(wordCount: words.count))
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier(AccessibilityID.entryStrip)
    }

    private func stripAccessibilityLabel(wordCount: Int) -> String {
        if kind == .empty && clipboardEmpty {
            return "Nothing on the clipboard. Copy a link or some text first."
        }
        return EntryCopy.stripTitle(for: kind, wordCount: wordCount)
            + ". "
            + EntryCopy.stripSubtitle(for: kind, value: trimmedInput)
    }

    private var shownProgress: Double {
        switch state {
        case .idle: return 0
        case .loading(let stage, _): return stage.progress
        case .refused: return settledStage?.progress ?? 0
        }
    }

    /// The loadline step the bar has reached. Nil before the first stage.
    private var currentStep: Int? {
        switch state {
        case .idle: return nil
        case .loading(let stage, _): return stepIndex(for: stage)
        case .refused: return settledStage.map(stepIndex)
        }
    }

    private func stepIndex(for stage: EntryStage) -> Int {
        switch stage {
        case .fetching: return 0
        case .stripping: return 1
        case .ready: return 2
        }
    }

    private var loadStatus: String {
        switch state {
        case .idle: return ""
        case .loading(let stage, _): return stage.label
        case .refused: return ""
        }
    }

    /// The loadline: progress bar, Fetch / Clean / Ready ticks, status line.
    /// Hidden until the first Open; steps stay out of the AT tree.
    @ViewBuilder
    private var loadline: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.line)
                    Capsule()
                        .fill(Theme.brand)
                        .frame(width: shownProgress * geo.size.width)
                    if isLoading && !reduceMotion {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.clear, .white.opacity(0.65), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: 80)
                            .offset(x: shimmerX)
                            .onAppear {
                                shimmerX = -80
                                withAnimation(
                                    .linear(duration: 1.2).repeatForever(autoreverses: false)
                                ) {
                                    shimmerX = geo.size.width + 80
                                }
                            }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(height: 3)
            .animation(reduceMotion ? nil : ThemeMotion.entryProgress, value: shownProgress)
            HStack(spacing: 10) {
                stepTick(
                    title: "Fetch",
                    id: AccessibilityID.entryStepFetch,
                    index: 0
                )
                stepTick(
                    title: "Clean",
                    id: AccessibilityID.entryStepClean,
                    index: 1
                )
                stepTick(
                    title: "Ready",
                    id: AccessibilityID.entryStepReady,
                    index: 2,
                    showsCheck: true
                )
            }
            .accessibilityHidden(true)
            Text(loadStatus)
                .font(Theme.caption())
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .onAppear {
            if !reduceMotion {
                withAnimation(
                    .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                ) {
                    pulseOn = true
                }
            }
        }
    }

    @ViewBuilder
    private func stepTick(
        title: String,
        id: String,
        index: Int,
        showsCheck: Bool = false
    ) -> some View {
        let step = currentStep
        let done = step.map { $0 > index } ?? false
        let now = step == index
        let readyDone = showsCheck && done
        HStack(spacing: 5) {
            if readyDone {
                Text("✓")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.brand)
                    .scaleEffect(step == 2 ? 1.0 : 0.4)
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.5),
                        value: step
                    )
            } else {
                Circle()
                    .fill(done || now ? Theme.brand : Theme.line)
                    .frame(width: 8, height: 8)
                    .opacity(now && !reduceMotion ? (pulseOn ? 0.35 : 1.0) : 1.0)
            }
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .textCase(.uppercase)
                .foregroundStyle(done || now ? (now && !done ? Theme.brand : Theme.ink) : Theme.inkSecondary)
        }
        .accessibilityIdentifier(id)
    }

    private func setLoading(_ stage: EntryStage) {
        settledStage = stage
        state = .loading(stage: stage, progress: stage.progress)
    }

    private func open() {
        hasAttempted = true
        if trimmedInput.isEmpty {
            state = .refused(
                clipboardEmpty ? EntryCopy.emptyRefusalNoClipboard : EntryCopy.emptyRefusal
            )
            return
        }
        guard !isLoading else { return }
        // The keyboard has done its job once the request leaves. Dismiss it
        // here so the loadline is visible on small screens.
        fieldFocused = false
        telemetry.record(TelemetryName.tap)
        let request: EntryRequest
        if kind == .text {
            request = EntryRequest(
                mode: .text, linkText: "", rawText: trimmedInput, source: .rawText
            )
        } else {
            request = EntryRequest(
                mode: .link,
                linkText: EntryDetector.linkTarget(for: trimmedInput),
                rawText: "",
                source: inputFromClipboard ? .clipboard : .link
            )
        }
        inputFromClipboard = false
        Task { await load(request) }
    }

    /// The entry path follows the field kind. The bundled sample is
    /// recognised here so the demo opens with no network, and a real link is
    /// fetched, extracted, then opened.
    @MainActor
    private func load(_ request: EntryRequest) async {
        switch request.mode {
        case .text:
            setLoading(.stripping)
            reveal(.ready)
            switch ArticleIngress.pasted(request.raw, telemetry: telemetry) {
            case .success(let document):
                telemetry.record(TelemetryName.readerOpen, fields: ["source": request.source.rawValue])
                onOpen(document, request.source, nil)
            case .failure(let error):
                state = .refused(error.message)
            }
            return
        case .link:
            break
        }
        if request.link == EntryCopy.sampleLink {
            setLoading(.fetching)
            reveal(.stripping)
            reveal(.ready)
            telemetry.record(TelemetryName.fetchSkipped, fields: ["reason": "sample-link"])
            telemetry.record(TelemetryName.planReady, fields: [
                "source": EntrySource.sample.rawValue,
                "words": String(ArticleLibrary.demo.plan.spokenWords),
            ])
            telemetry.record(TelemetryName.readerOpen, fields: ["source": EntrySource.sample.rawValue])
            onOpen(ArticleLibrary.demo, .sample, nil)
            return
        }

        setLoading(.fetching)
        let fetched = await ArticleIngress.fetch(request.link, telemetry: telemetry)
        guard case .success(let page) = fetched else {
            if case .failure(let error) = fetched {
                state = .refused(error.message)
            }
            return
        }
        setLoading(.stripping)
        switch ArticleIngress.read(page, telemetry: telemetry, original: URL(string: request.link)) {
        case .success(let document):
            reveal(.ready)
            telemetry.record(TelemetryName.readerOpen, fields: ["source": request.source.rawValue])
            onOpen(document, request.source, page)
        case .failure(let error):
            state = .refused(error.message)
        }
    }

    /// Sets a loadline stage without holding the open path. The stage is
    /// visible as soon as SwiftUI commits the next frame.
    @MainActor
    private func reveal(_ stage: EntryStage) {
        setLoading(stage)
    }
}
