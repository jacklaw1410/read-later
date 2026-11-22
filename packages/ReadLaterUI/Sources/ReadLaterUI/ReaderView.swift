import ReadLaterCore
import SwiftUI

/// Reads a document in order. The body renders `document.bodyBlocks`; notes
/// render in a `Notes` section at the end. The caller owns the player and any
/// overlay: the player sits below the scroll view, the overlay layers on top.
public struct ReaderView<Player: View, Overlay: View>: View {
    private let document: ReadLaterCore.Document
    private let wash: WashState
    private let playback: PlaybackState
    private let spoken: SpokenWordNumbering
    private let autoScroll: Bool
    private let isScrubbing: Bool
    /// Bumped by the caller to scroll back to the wash block. The tap on the
    /// return pill is the only writer, so play alone never yanks.
    private let returnToken: Int
    private let onTapWord: (Int, WordSlot?, String) -> Void
    private let onTapNote: (Int) -> Void
    /// Fired when the reader's own scroll trips the hold detector. The caller
    /// sets held state; programmatic reveals never reach here.
    private let onHold: () -> Void
    /// Fired when the wash block enters or leaves the viewport.
    private let onWashVisibilityChanged: (Bool) -> Void
    private let player: () -> Player
    private let overlay: () -> Overlay

    @State private var holdDetector = HoldDetector()
    @State private var userDriving = false
    @State private var lastOffset: CGFloat?
    @State private var washMidY: CGFloat?
    @State private var viewportHeight: CGFloat = 0
    @State private var lastReportedVisible = true

    public init(
        document: ReadLaterCore.Document,
        wash: WashState,
        playback: PlaybackState,
        spoken: SpokenWordNumbering,
        autoScroll: Bool,
        isScrubbing: Bool = false,
        returnToken: Int = 0,
        onTapWord: @escaping (_ blockID: Int, _ slot: WordSlot?, _ word: String) -> Void,
        onTapNote: @escaping (Int) -> Void,
        onHold: @escaping () -> Void = {},
        onWashVisibilityChanged: @escaping (Bool) -> Void = { _ in },
        @ViewBuilder player: @escaping () -> Player,
        @ViewBuilder overlay: @escaping () -> Overlay
    ) {
        self.document = document
        self.wash = wash
        self.playback = playback
        self.spoken = spoken
        self.autoScroll = autoScroll
        self.isScrubbing = isScrubbing
        self.returnToken = returnToken
        self.onTapWord = onTapWord
        self.onTapNote = onTapNote
        self.onHold = onHold
        self.onWashVisibilityChanged = onWashVisibilityChanged
        self.player = player
        self.overlay = overlay
    }

    /// True when this block holds the word the voice is on.
    private func holdsWash(_ blockID: Int) -> Bool {
        guard let index = wash.wordIndex else { return false }
        return spoken.byBlock[blockID]?.contains { $0.index == index } ?? false
    }

    /// Marker blocks attached to the preceding body block, paired with note
    /// bodies by order. Maps body block ID to its attachment.
    private var footnoteAttachments: [Int: FootnoteAttachment] {
        let notes = document.noteBlocks
        let body = document.bodyBlocks
        var attachments: [Int: FootnoteAttachment] = [:]
        var markerIndex = 0
        for position in body.indices {
            guard body[position].kind == .footnoteMarker else { continue }
            defer { markerIndex += 1 }
            guard markerIndex < notes.count, position > 0 else { continue }
            let preceding = body[position - 1]
            guard preceding.kind != .footnoteMarker else { continue }
            attachments[preceding.id] = FootnoteAttachment(
                marker: body[position].text,
                noteIndex: markerIndex
            )
        }
        return attachments
    }

    private var readableBlocks: [ReadLaterCore.Block] {
        document.bodyBlocks.filter { $0.kind != .footnoteMarker }
    }

    private var metaLine: String {
        let host = document.url?.host() ?? "pasted text"
        // Short enough for one line at the narrowest window. The counts are
        // the voice's own numbers, so the subhead cannot claim a word the
        // reader will not hear.
        return "\(host) · \(document.spokenWordCount) words · \(document.skippedRegionCount) skipped"
    }

    /// The block holding the wash word, for the return scroll. Per-block
    /// `scrollTo` is the accepted grain: SwiftUI cannot address a word.
    private var washBlockID: Int? {
        guard let index = wash.wordIndex else { return nil }
        return spoken.word(at: index)?.blockID
    }

    public var body: some View {
        let footnotes = footnoteAttachments
        ZStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(document.title)
                                .font(Theme.title())
                                .foregroundStyle(Theme.ink)
                                .padding(.bottom, 8)
                            Text(metaLine)
                                .font(Theme.caption())
                                .foregroundStyle(Theme.inkSecondary)
                                .padding(.bottom, 12)
                            ForEach(readableBlocks) { block in
                                BlockView(
                                    block: block,
                                    wash: wash,
                                    playback: playback,
                                    spoken: spoken,
                                    footnote: footnotes[block.id],
                                    followsWash: autoScroll && holdsWash(block.id),
                                    onTapWord: onTapWord,
                                    onTapNote: onTapNote
                                )
                                .id(block.id)
                                .background {
                                    // The wash anchor is independent of follow
                                    // state: a held or paused reader still needs
                                    // to know the wash left the viewport.
                                    if holdsWash(block.id) {
                                        GeometryReader { geo in
                                            Color.clear.preference(
                                                key: WashAnchorKey.self,
                                                value: geo.frame(in: .named("readerScroll")).midY
                                            )
                                        }
                                    }
                                }
                            }
                            if !document.noteBlocks.isEmpty {
                                notesSection
                            }
                        }
                        .padding(.horizontal, Theme.screenGutter)
                        .padding(.vertical, Theme.breathingRoom)
                        .frame(maxWidth: Theme.maxLineWidth)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .background {
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: ScrollOffsetKey.self,
                                    value: geo.frame(in: .named("readerScroll")).minY
                                )
                            }
                        }
                    }
                    .coordinateSpace(name: "readerScroll")
                    // The reader body is one scrolling text element for the UI
                    // journeys: a word tap is a coordinate tap inside this
                    // frame, so the tests need a stable box to aim at. An
                    // identifier only; the tree shape does not change.
                    .accessibilityIdentifier(AccessibilityID.readerWash)
                    .overlay {
                        GeometryReader { geo in
                            Color.clear.preference(key: ViewportHeightKey.self, value: geo.size.height)
                        }
                    }
                    .trackUserDriving($userDriving)                    .onPreferenceChange(ScrollOffsetKey.self) { minY in
                        let offset = -minY
                        defer { lastOffset = offset }
                        guard let last = lastOffset, userDriving else { return }
                        let delta = offset - last
                        guard delta != 0 else { return }
                        if holdDetector.scrollEvent(
                            distanceFromWash: delta,
                            isFollowing: autoScroll && !isScrubbing,
                            isScrubbing: isScrubbing
                        ) {
                            onHold()
                        }
                    }
                    .onPreferenceChange(WashAnchorKey.self) { midY in
                        washMidY = midY
                        reportVisibility()
                    }
                    .onPreferenceChange(ViewportHeightKey.self) { height in
                        viewportHeight = height
                        reportVisibility()
                    }
                    .onChange(of: wash.wordIndex) {
                        // No wash, no return target: report visible so a stale
                        // anchor cannot pin the pill on.
                        if wash.wordIndex == nil {
                            washMidY = nil
                            reportVisibility()
                        }
                    }
                    .onChange(of: returnToken) {
                        guard returnToken > 0, let id = washBlockID else { return }
                        withAnimation {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                    // No `ScrollViewReader` scroll on wash ticks here on
                    // purpose: `scrollTo` takes a view id, and a word is not a
                    // view. The block holding the wash word scrolls its own
                    // enclosing scroll view, so the page follows within a
                    // paragraph as well as between paragraphs.
                }
                player()
            }
            overlay()
        }
        .background(Theme.paper)
    }

    /// Reports wash visibility once per change. The pill reads this, not the
    /// wash ticks, so visibility costs one call per enter/leave.
    private func reportVisibility() {
        let visible: Bool
        if let midY = washMidY, viewportHeight > 0 {
            visible = midY >= 0 && midY <= viewportHeight
        } else {
            visible = true
        }
        guard visible != lastReportedVisible else { return }
        lastReportedVisible = visible
        onWashVisibilityChanged(visible)
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOTES")
                .font(Theme.mono())
                .foregroundStyle(Theme.inkSecondary)
            Divider()
            ForEach(document.noteBlocks) { note in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    WashableText(text: note.text, slots: [], wash: WashState(), playback: PlaybackState(), style: .note) { _, word in
                        onTapWord(note.id, nil, word)
                    }
                }
                .id(note.id)
            }
        }
        .padding(.top, 18)
    }
}

/// Content top in scroll space. Negated, it is the content offset.
private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Mid-Y of the block holding the wash word, in scroll space. Nil when no
/// block holds the wash, so a stale anchor cannot pin the pill on.
private struct WashAnchorKey: PreferenceKey {
    static var defaultValue: CGFloat? { nil }
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

/// Scroll viewport height, for the wash visibility check.
private struct ViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private extension View {
    /// Tracks whether the scroll offset moves under the reader's finger.
    /// `onScrollPhaseChange` is iOS 18 / macOS 15; below that the reader
    /// never reports user-driven, so a deliberate scroll cannot hold.
    @ViewBuilder
    func trackUserDriving(_ driving: Binding<Bool>) -> some View {
        if #available(macOS 15, iOS 18, *) {
            self.onScrollPhaseChange { _, phase in
                driving.wrappedValue = phase == .interacting || phase == .decelerating
            }
        } else {
            self
        }
    }
}
