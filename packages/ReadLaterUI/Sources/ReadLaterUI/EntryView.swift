import ReadLaterCore
import SwiftUI

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
    public static let linkCaption = "Paste link or text"
    public static let linkHint = "The prefilled link opens the sample article. x.com and similar → login wall, paste text instead."
    public static let rawCaption = "Raw text"
    public static let rawPlaceholder = "Paste a paragraph to override the sample…"
    public static let open = "Open in Read Later"
    public static let extracting = "Extracting…"
    public static let emptyRefusal = "nothing to open — paste a link or text"
    public static let loginWallRefusal = "login wall — paste text instead"
    public static let footer = "MVP cut: flow and tap-to-lookup. No drag-phrase, no saving."
    public static let sampleLink = "https://www.theatlantic.com/reading/slow"
}

/// The first screen. Prefilled link, optional raw text, one button, and a
/// progress area that runs the three extraction stages before opening.
public struct EntryView: View {
    private let onOpen: (ReadLaterCore.Document) -> Void

    @State private var linkText = EntryCopy.sampleLink
    @State private var rawText = ""
    @State private var state: EntryState = .idle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(onOpen: @escaping (ReadLaterCore.Document) -> Void) {
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The form sits in the optical centre of the window, not against
            // the top edge. Two flexible spacers do that without a fixed
            // offset, so a taller window keeps the form centred.
            Spacer(minLength: 24)
            Text(EntryCopy.linkCaption)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(0.88)
                .textCase(.uppercase)
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityAddTraits(.isHeader)
            TextField("Link", text: $linkText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.line, lineWidth: 1)
                )
                .padding(.top, 6)
                .accessibilityLabel("Link")
            Text(EntryCopy.linkHint)
                .font(Theme.caption())
                .foregroundStyle(Theme.inkSecondary)
                .padding(.top, 6)
            Text(EntryCopy.rawCaption)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(0.88)
                .textCase(.uppercase)
                .foregroundStyle(Theme.inkSecondary)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $rawText)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 14))
                    .frame(minHeight: 48, maxHeight: 96)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Theme.line, lineWidth: 1)
                    )
                    .accessibilityLabel("Raw text")
                if rawText.isEmpty {
                    Text(EntryCopy.rawPlaceholder)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.inkSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .padding(.top, 6)
            Button(isLoading ? EntryCopy.extracting : EntryCopy.open) {
                open()
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .padding(.top, 16)
            .disabled(isLoading)
            .accessibilityLabel(isLoading ? EntryCopy.extracting : EntryCopy.open)
            progressArea
                .padding(.top, 14)
            Spacer(minLength: 0)
            Text(EntryCopy.footer)
                .font(Theme.caption())
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 12)
        }
        .padding(.horizontal, Theme.screenGutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.paper)
    }

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    private var showsProgress: Bool {
        state != .idle
    }

    private var shownProgress: Double {
        switch state {
        case .idle: return 0
        case .loading(let stage, _): return stage.progress
        case .refused(let message):
            return message == EntryCopy.loginWallRefusal ? EntryStage.fetching.progress : 0
        }
    }

    private var progressLabel: String {
        switch state {
        case .idle: return ""
        case .loading(let stage, _): return stage.label
        case .refused(let message): return message
        }
    }

    @ViewBuilder
    private var progressArea: some View {
        // Always laid out, only revealed when a load starts. A view that
        // inserts itself on press moves the button under the reader's finger
        // and shifts the whole form; reserving the height costs two lines of
        // empty space and no jolt.
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.line)
                        .frame(height: 3)
                    Capsule()
                        .fill(Theme.brand)
                        .frame(width: shownProgress * geo.size.width, height: 3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(height: 3)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: shownProgress)
            Text(showsProgress ? progressLabel : " ")
                .font(Theme.caption())
                .foregroundStyle(Theme.inkSecondary)
        }
        .opacity(showsProgress ? 1 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading progress")
        .accessibilityValue("\(Int(shownProgress * 100)) percent")
        .accessibilityHidden(!showsProgress)
    }

    private func open() {
        let link = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if link.isEmpty && raw.isEmpty {
            state = .refused(EntryCopy.emptyRefusal)
            return
        }
        guard !isLoading else { return }
        Task { await load(link: link, raw: raw) }
    }

    /// The entry path. Raw text wins over the link. The bundled sample is
    /// recognised here so the demo opens with no network, and a real link is
    /// fetched, extracted, then opened.
    @MainActor
    private func load(link: String, raw: String) async {
        if !raw.isEmpty {
            state = .loading(stage: .stripping, progress: EntryStage.stripping.progress)
            await reveal(.ready)
            switch ArticleIngress.pasted(raw) {
            case .success(let document):
                onOpen(document)
            case .failure(let error):
                state = .refused(error.message)
            }
            return
        }
        if link == EntryCopy.sampleLink {
            state = .loading(stage: .fetching, progress: EntryStage.fetching.progress)
            await reveal(.stripping)
            await reveal(.ready)
            onOpen(ArticleLibrary.demo)
            return
        }

        state = .loading(stage: .fetching, progress: EntryStage.fetching.progress)
        let fetched = await ArticleIngress.fetch(link)
        guard case .success(let page) = fetched else {
            if case .failure(let error) = fetched {
                state = .refused(error.message)
            }
            return
        }
        state = .loading(stage: .stripping, progress: EntryStage.stripping.progress)
        switch ArticleIngress.read(page) {
        case .success(let document):
            await reveal(.ready)
            onOpen(document)
        case .failure(let error):
            state = .refused(error.message)
        }
    }

    /// Holds a stage long enough to be seen. Two stages can finish in the same
    /// millisecond on a cached page, and a progress rule that never moves tells
    /// the reader nothing.
    @MainActor
    private func reveal(_ stage: EntryStage) async {
        state = .loading(stage: stage, progress: stage.progress)
        try? await Task.sleep(for: .milliseconds(180))
    }
}
