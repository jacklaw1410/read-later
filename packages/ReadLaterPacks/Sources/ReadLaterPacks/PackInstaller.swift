import Foundation

/// Typed download failure so the installer maps each transport outcome to
/// its state instead of collapsing everything to one failure.
public enum PackDownloadError: Error, Sendable, Equatable {
    case network(reason: String)
    case registry(status: Int)
    case disk
}

/// Walks offered → downloading → verifying → installed, plus cancel → paused
/// and resume. No real network: the caller injects the `download` closure, so
/// tests pass bytes and production passes URLSession.
public actor PackInstaller {
    public typealias Progress = @Sendable (Int, Int) -> Void

    private let manifest: PackManifest
    private let download: @Sendable (URL) async throws -> Data
    private(set) public var state: InstallState
    private(set) public var transferredBytes: Int = 0
    private(set) public var totalBytes: Int = 0
    private var cancelled = false
    private var storedData: Data?

    public init(
        manifest: PackManifest,
        initialState: InstallState = .offered,
        download: @escaping @Sendable (URL) async throws -> Data
    ) {
        self.manifest = manifest
        self.state = initialState
        self.download = download
    }

    /// Starts (or restarts) the download. A start from `offered` or
    /// `updateAvailable` is a new download and resets the byte count; a
    /// resume from `paused` keeps it.
    @discardableResult
    public func start(url: URL, progress: Progress = { _, _ in }) async -> InstallState {
        if state == .offered || isUpdateAvailable {
            storedData = nil
            transferredBytes = 0
            totalBytes = 0
        }
        cancelled = false
        return await run(url: url, progress: progress)
    }

    /// Cancel a running download. Keeps the byte count for a later resume.
    public func cancel() -> InstallState {
        if state == .downloading {
            cancelled = true
            state = tryAdvance(to: .paused)
        }
        return state
    }

    /// Resume a paused download from the kept byte count.
    @discardableResult
    public func resume(url: URL, progress: Progress = { _, _ in }) async -> InstallState {
        guard state == .paused else { return state }
        cancelled = false
        return await run(url: url, progress: progress)
    }

    /// Report that the index build failed on verified bytes.
    public func reportIndexFailure() -> InstallState {
        if state == .verifying {
            state = tryAdvance(to: .failedCorrupt)
        }
        return state
    }

    private var isUpdateAvailable: Bool {
        if case .updateAvailable = state { return true }
        return false
    }

    private func run(url: URL, progress: Progress) async -> InstallState {
        guard state.canTransition(to: .downloading) else { return state }
        state = (try? advance(to: .downloading)) ?? state

        if storedData == nil {
            do {
                let data = try await download(url)
                storedData = data
                totalBytes = data.count
            } catch let error as PackDownloadError {
                switch error {
                case .network:
                    return move(to: .failedNetwork)
                case .registry:
                    return move(to: .failedRegistry)
                case .disk:
                    return move(to: .failedDisk)
                }
            } catch is CancellationError {
                return move(to: .paused)
            } catch {
                return move(to: .failedNetwork)
            }
        }

        guard let data = storedData else { return move(to: .failedNetwork) }

        let chunk = max(1, totalBytes / 8)
        while transferredBytes < totalBytes {
            if cancelled || Task.isCancelled {
                return move(to: .paused)
            }
            transferredBytes = min(totalBytes, transferredBytes + chunk)
            progress(transferredBytes, totalBytes)
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        if cancelled || Task.isCancelled {
            return move(to: .paused)
        }

        state = (try? advance(to: .verifying)) ?? state
        switch Verifier.verify(data: data, expectedHex: manifest.sha256) {
        case .match:
            return move(to: .installed(version: manifest.version))
        case .mismatch:
            storedData = nil
            return move(to: .failedHash)
        }
    }

    @discardableResult
    private func move(to next: InstallState) -> InstallState {
        state = (try? advance(to: next)) ?? state
        return state
    }

    private func advance(to next: InstallState) throws -> InstallState {
        var current = state
        try current.advance(to: next)
        return current
    }

    private func tryAdvance(to next: InstallState) -> InstallState {
        (try? advance(to: next)) ?? state
    }
}
