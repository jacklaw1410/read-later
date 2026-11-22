import ReadLaterCore
import SwiftUI

/// The browse list: every started article, newest first. A tap opens the
/// stored copy; Save keeps the row, Refresh drops the cached plan, Remove
/// drops the article and its place.
public struct LibraryView: View {
    private let provider: any LibraryProvider
    private let onClose: () -> Void

    @State private var pendingRemoval: LibraryRow?

    public init(provider: any LibraryProvider, onClose: @escaping () -> Void) {
        self.provider = provider
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if let message = provider.message {
                Text(message)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.screenGutter)
                    .padding(.vertical, 8)
            }
            if provider.rows.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(minWidth: 340, minHeight: 420)
        .background(Theme.paper)
        .alert(
            LibraryCopy.removeTitle,
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { row in
            Button(LibraryCopy.remove, role: .destructive) {
                provider.forget(row)
                pendingRemoval = nil
            }
            Button(LibraryCopy.cancel, role: .cancel) { pendingRemoval = nil }
        } message: { _ in
            Text(LibraryCopy.removeQuestion)
        }
    }

    private var header: some View {
        HStack(spacing: Theme.controlGap) {
            Text(LibraryCopy.title)
                .font(Theme.eyebrow())
                .tracking(Theme.eyebrowTracking)
                .textCase(.uppercase)
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            Button(LibraryCopy.close, action: onClose)
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSecondary)
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.horizontal, Theme.screenGutter)
        .frame(height: Theme.chrome)
        .background(Theme.surface)
        .overlay(Divider(), alignment: .bottom)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.stackGap) {
            Spacer(minLength: 0)
            Text(LibraryCopy.empty)
                .font(Theme.caption())
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.screenGutter)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach(provider.rows) { row in
                rowView(row)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func rowView(_ row: LibraryRow) -> some View {
        HStack(spacing: Theme.controlGap) {
            Button {
                Task {
                    // A failed open keeps the sheet up so the provider's message stays visible.
                    if await provider.open(row) { onClose() }
                }
            } label: {
                rowText(row)
            }
            .buttonStyle(.plain)

            Menu {
                Button(row.saved ? LibraryCopy.unsave : LibraryCopy.save) {
                    provider.setSaved(row, saved: !row.saved)
                }
                .accessibilityIdentifier(row.saved ? AccessibilityID.libraryUnsave : AccessibilityID.librarySave)
                Button(LibraryCopy.refresh) {
                    provider.releaseCopy(row)
                }
                .accessibilityIdentifier(AccessibilityID.libraryRefresh)
                Divider()
                Button(LibraryCopy.remove, role: .destructive) {
                    pendingRemoval = row
                }
                .accessibilityIdentifier(AccessibilityID.libraryRemove)
            } label: {
                IconGlyph(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel(LibraryCopy.actions)
            .accessibilityIdentifier(AccessibilityID.libraryActions)
        }
        .padding(.vertical, 4)
    }

    private func rowText(_ row: LibraryRow) -> some View {
        HStack(spacing: Theme.controlGap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .accessibilityIdentifier(row.title)
                HStack(spacing: 6) {
                    let place = LibraryCopy.placeLine(
                        wordIndex: row.wordIndex, totalWords: row.totalWords)
                    if !place.isEmpty {
                        Text(place)
                            .font(Theme.caption())
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    // Derived completion, not the mechanical flag: the adapter
                    // sets `finished` from `reachedEnd || markedDone`, so
                    // scrubbing back from the end still reads done (spec §6).
                    if row.finished {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.inkSecondary)
                            .accessibilityLabel(LibraryCopy.finished)
                    }
                }
            }
            Spacer(minLength: 4)
            if row.saved {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.savedMark)
                    .accessibilityLabel(LibraryCopy.saved)
            }
        }
        .contentShape(Rectangle())
    }
}
