import Foundation

/// Typed download failure so the installer maps each transport outcome to
/// its state instead of collapsing everything to one failure.
public enum PackDownloadError: Error, Sendable, Equatable {
    case network(reason: String)
    case registry(status: Int)
    case disk
}

extension PackDownloadError {
    /// Each transport outcome names its state; nothing collapses to one failure.
    public var installState: InstallState {
        switch self {
        case .network:
            return .failedNetwork
        case .registry:
            return .failedRegistry
        case .disk:
            return .failedDisk
        }
    }
}

/// Walks offered → downloading → verifying → installed, plus cancel → paused
/// and resume. No real network: the caller injects the `download` closure, so
/// tests pass bytes and production passes URLSession.
public actor PackInstaller {
    public typealias Progress = @Sendable (Int, Int) -> Void

    /// Streams the archive to `destination`, continuing from `resumeOffset`
    /// kept bytes, and reports (received, total) as it goes.
    public typealias DownloadFile = @Sendable (URL, URL, Int, Progress) async throws -> Void
    /// Builds the on-disk lookup index from verified archive bytes.
    public typealias BuildIndex = @Sendable (URL, URL) async throws -> URL

    private let manifest: PackManifest
    private let download: @Sendable (URL) async throws -> Data
    private let downloadFile: DownloadFile
    private let buildIndex: BuildIndex
    private let freeSpace: @Sendable (URL) -> Int64?
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
        self.downloadFile = { _, _, _, _ in
            throw PackDownloadError.network(reason: "no file download configured")
        }
        self.buildIndex = { _, directory in directory }
        self.freeSpace = { _ in nil }
    }

    /// File-backed install: streams to `<directory>/<id>.pack.gz`, verifies
    /// the sha256, then builds the on-disk index. The demo path above keeps
    /// its in-memory API; this is the production path for the real pack.
    public init(
        manifest: PackManifest,
        initialState: InstallState = .offered,
        downloadFile: @escaping DownloadFile,
        freeSpace: @escaping @Sendable (URL) -> Int64? = PackDownloader.freeSpace(at:),
        buildIndex: @escaping BuildIndex = { archive, directory in
            try PackIndexBuilder.build(archiveURL: archive, directory: directory)
        }
    ) {
        self.manifest = manifest
        self.state = initialState
        self.download = { _ in
            throw PackDownloadError.network(reason: "no data download configured")
        }
        self.downloadFile = downloadFile
        self.buildIndex = buildIndex
        self.freeSpace = freeSpace
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

    // MARK: - File-backed install (real pack)

    /// Starts (or restarts) the file-backed download into `directory`. A
    /// start from `offered` or `updateAvailable` is a new download and
    /// deletes any partial file; a start from `paused` keeps it.
    @discardableResult
    public func start(url: URL, directory: URL, progress: Progress = { _, _ in }) async -> InstallState {
        let resuming = state == .paused
        if !resuming {
            try? FileManager.default.removeItem(at: archiveURL(in: directory))
            transferredBytes = 0
            totalBytes = 0
        }
        cancelled = false
        return await runFile(url: url, directory: directory, resuming: resuming, progress: progress)
    }

    /// Resumes a paused download from the kept partial file.
    @discardableResult
    public func resume(url: URL, directory: URL, progress: Progress = { _, _ in }) async -> InstallState {
        guard state == .paused else { return state }
        cancelled = false
        return await runFile(url: url, directory: directory, resuming: true, progress: progress)
    }

    private func runFile(url: URL, directory: URL, resuming: Bool, progress: Progress) async -> InstallState {
        guard state.canTransition(to: .downloading) else { return state }
        state = (try? advance(to: .downloading)) ?? state

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = archiveURL(in: directory)
        var offset = 0
        if resuming, let kept = fileSize(at: archive), kept <= manifest.sizeBytes {
            offset = kept
        } else if resuming {
            try? FileManager.default.removeItem(at: archive)
        }
        transferredBytes = offset
        totalBytes = manifest.sizeBytes

        // Disk precheck against the bytes still missing. A known shortage
        // stops the run before the first byte; unknown stays permissive.
        if let free = freeSpace(directory), free < Int64(manifest.sizeBytes - offset) {
            return move(to: .failedDisk)
        }

        do {
            try await downloadFile(url, archive, offset, progress)
        } catch let error as PackDownloadError {
            return move(to: error.installState)
        } catch is CancellationError {
            return move(to: .paused)
        } catch {
            return move(to: .failedNetwork)
        }
        if cancelled || Task.isCancelled {
            return move(to: .paused)
        }

        transferredBytes = fileSize(at: archive) ?? offset
        totalBytes = manifest.sizeBytes
        progress(transferredBytes, totalBytes)

        state = (try? advance(to: .verifying)) ?? state
        let result: VerificationResult
        do {
            result = try Verifier.verify(contentsOf: archive, expectedHex: manifest.sha256)
        } catch {
            discard(archive)
            return move(to: .failedCorrupt)
        }
        switch result {
        case .match:
            break
        case .mismatch:
            // A mismatch is never shown as a hit: the partial file goes and
            // the card shows the "failed its check" state.
            discard(archive)
            return move(to: .failedHash)
        }

        do {
            _ = try await buildIndex(archive, directory)
        } catch {
            discard(archive)
            return move(to: .failedCorrupt)
        }
        return move(to: .installed(version: manifest.version))
    }

    private func archiveURL(in directory: URL) -> URL {
        directory.appendingPathComponent("\(manifest.id).pack.gz")
    }

    private func fileSize(at url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    /// A failed verification leaves no bytes behind for the next attempt to
    /// mistake for a pack. A later retry is a new download.
    private func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        transferredBytes = 0
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
