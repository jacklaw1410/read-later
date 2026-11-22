import Network
import Observation

/// The device's network path, shared by the whole app. The path says whether
/// a route exists. It does not say whether a server answers, so callers act on
/// the outcome of their own request and use this only to choose copy.
@MainActor
@Observable
final class Connectivity {
    enum Status: Equatable {
        case unknown
        case online
        case offline
    }

    private(set) var status: Status
    private let monitor = NWPathMonitor()

    init(status: Status = .unknown) {
        self.status = status
    }

    /// Starts the monitor. The first path callback replaces `.unknown`.
    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let status = Self.status(for: path)
            Task { @MainActor in self?.status = status }
        }
        monitor.start(queue: .main)
    }

    /// Reads the monitor's current path again. Call after a request fails for
    /// a network reason, so the miss card matches the path the monitor holds.
    func refresh() {
        status = Self.status(for: monitor.currentPath)
    }

    nonisolated private static func status(for path: NWPath) -> Status {
        path.status == .satisfied ? .online : .offline
    }
}
