import ReadLaterCore

/// Closes the library sheet after a successful open. A failed open leaves the
/// sheet up, so the reason the provider shows stays visible.
@MainActor
public struct LibraryOpener {
    private let provider: any LibraryProvider
    private let onOpened: () -> Void

    public init(provider: any LibraryProvider, onOpened: @escaping () -> Void) {
        self.provider = provider
        self.onOpened = onOpened
    }

    public func open(_ row: LibraryRow) async {
        if await provider.open(row) {
            onOpened()
        }
    }
}
