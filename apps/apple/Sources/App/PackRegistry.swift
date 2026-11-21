import Foundation
import Observation
import ReadLaterCore
import ReadLaterPacks

/// The installed dictionary, shared by the reader and the Settings pane.
///
/// One object owns the install, so the miss card and Settings cannot disagree
/// about whether a pack is present. The fact is persisted, because an install
/// that forgets itself on relaunch is not an install.
///
/// Two sources answer lookups: the installed real pack from the R2 registry,
/// and the bundled demo pack while nothing is installed. The reading path
/// never touches the network either way.
@MainActor
@Observable
final class PackRegistry: CapabilityPacks {
    static let shared = PackRegistry()

    private(set) var installedVersion: String?
    private(set) var isInstalling = false
    private(set) var offerDeclined = false
    private(set) var isPaused = false
    private(set) var failure: String?
    private(set) var downloadedBytes = 0
    private(set) var totalBytes = 0
    private(set) var updateVersion: String?
    private(set) var updateSizeBytes: Int?

    private var store: PackIndexStore?
    private var demo: DemoPack?
    private let defaults: UserDefaults
    private let installedKey = "rl-pack-installed-version"
    private let declinedKey = "rl-pack-offer-declined"
    private var installTask: Task<Void, Never>?
    private var installer: PackInstaller?
    private var installerVersion: String?
    private var lastUpdateCheck: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let version = defaults.string(forKey: installedKey),
           let sqliteURL = Self.sqliteURL(),
           FileManager.default.fileExists(atPath: sqliteURL.path)
        {
            self.store = PackIndexStore(sqliteURL: sqliteURL)
            self.installedVersion = version
        }
        self.offerDeclined = defaults.bool(forKey: declinedKey)
    }

    var isInstalled: Bool { store != nil }

    static func packsDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Packs", isDirectory: true)
    }

    static func sqliteURL() -> URL? {
        packsDirectory()?.appendingPathComponent("\(RegistryClient.packID).sqlite")
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    /// Starts the install, or resumes a paused one. A second call while a
    /// run is in flight is ignored; the card path awaits `install()` below.
    func startInstall() {
        guard installTask == nil, !isInstalled else { return }
        installTask = Task { await runInstall() }
    }

    /// Cancels a running download. The partial file stays, so the next
    /// `startInstall` resumes instead of restarting.
    func cancelInstall() {
        installTask?.cancel()
    }

    /// The card path: starts the install and waits for it. No progress UI;
    /// the card re-resolves when the pack lands.
    func install() async {
        startInstall()
        await installTask?.value
    }

    /// Asks the registry whether a newer pack exists. Called when Settings ›
    /// Dictionaries opens, never at launch and never on the tap path. A
    /// fetch inside the last five minutes is reused. A failed fetch shows
    /// nothing and says nothing: the installed pack keeps working.
    func checkForUpdate() async {
        guard let installed = installedVersion, store != nil else { return }
        if let last = lastUpdateCheck, Date().timeIntervalSince(last) < 300 { return }
        lastUpdateCheck = Date()
        guard let manifest = try? await RegistryClient.fetchManifest(fetch: { url in
            try await PackDownloader.fetch(url: url)
        }) else { return }
        guard manifest.id == RegistryClient.packID else { return }
        guard case .allowed = PackAllowlist.check(manifest, appVersion: Self.appVersion) else { return }
        guard PackUpdate.isUpdateAvailable(installed: installed, remote: manifest.version) else {
            updateVersion = nil
            updateSizeBytes = nil
            return
        }
        updateVersion = manifest.version
        updateSizeBytes = manifest.sizeBytes
    }

    private func runInstall() async {
        isInstalling = true
        isPaused = false
        failure = nil
        downloadedBytes = 0
        totalBytes = 0
        defer {
            isInstalling = false
            installTask = nil
        }

        let manifest: PackManifest
        do {
            manifest = try await RegistryClient.fetchManifest(fetch: { url in
                try await PackDownloader.fetch(url: url)
            })
        } catch let error as PackDownloadError {
            failure = error.installState.settingsDescription
            return
        } catch {
            failure = InstallState.failedRegistry.settingsDescription
            return
        }

        guard case .allowed = PackAllowlist.check(manifest, appVersion: Self.appVersion) else {
            failure = InstallState.failedRegistry.settingsDescription
            return
        }
        guard let directory = Self.packsDirectory() else {
            failure = InstallState.failedDisk.settingsDescription
            return
        }

        // A paused installer is reused so resume continues the partial file.
        // Any other state starts fresh: a retry after a failure is a new
        // download, and a new version is a new installer.
        if await installer?.state != .paused || installerVersion != manifest.version {
            installer = PackInstaller(
                manifest: manifest,
                downloadFile: { url, destination, offset, progress in
                    try await PackDownloader.download(
                        url: url,
                        destination: destination,
                        resumeOffset: offset,
                        progress: progress
                    )
                }
            )
            installerVersion = manifest.version
        }
        guard let installer else {
            failure = InstallState.failedDisk.settingsDescription
            return
        }
        let box = ProgressBox(registry: self)
        let progress: PackInstaller.Progress = { received, total in
            Task { @MainActor in
                box.registry?.reportProgress(received: received, total: total)
            }
        }
        let state: InstallState
        if await installer.state == .paused {
            state = await installer.resume(
                url: RegistryClient.archiveURL(manifest: manifest),
                directory: directory,
                progress: progress
            )
        } else {
            state = await installer.start(
                url: RegistryClient.archiveURL(manifest: manifest),
                directory: directory,
                progress: progress
            )
        }
        switch state {
        case .installed(let version):
            guard let sqliteURL = Self.sqliteURL() else {
                failure = InstallState.failedDisk.settingsDescription
                return
            }
            self.store = PackIndexStore(sqliteURL: sqliteURL)
            installedVersion = version
            defaults.set(version, forKey: installedKey)
            self.installer = nil
            installerVersion = nil
            updateVersion = nil
            updateSizeBytes = nil
        case .paused:
            isPaused = true
        default:
            failure = state.settingsDescription
        }
    }

    private func reportProgress(received: Int, total: Int) {
        downloadedBytes = received
        totalBytes = total
    }

    /// Removes the pack. The reader keeps working; the demo answers and the
    /// offer returns.
    func remove() {
        store = nil
        installedVersion = nil
        defaults.removeObject(forKey: installedKey)
        installer = nil
        installerVersion = nil
        updateVersion = nil
        updateSizeBytes = nil
        isPaused = false
        downloadedBytes = 0
        totalBytes = 0
        if let directory = Self.packsDirectory() {
            for name in ["\(RegistryClient.packID).pack.gz", "\(RegistryClient.packID).sqlite"] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    /// Records the reader's permanent choice not to install. Persisted, so
    /// the offer does not return on relaunch.
    func declineOffer() {
        offerDeclined = true
        defaults.set(true, forKey: declinedKey)
    }

    /// Discards a paused download's partial file. The offer returns; a later
    /// install is a new download.
    func removePartial() {
        if let directory = Self.packsDirectory() {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent("\(RegistryClient.packID).pack.gz")
            )
        }
        installer = nil
        installerVersion = nil
        isPaused = false
        downloadedBytes = 0
        totalBytes = 0
    }

    /// The real pack first, the bundled demo while nothing is installed.
    /// Case-insensitive; `café` resolves to the `cafe` row with the stored
    /// headword as the subtitle. Pointer glosses resolve through the base
    /// word the same way. The gloss is card-ready: the three rendering rules
    /// already ran in the packs package, never in a view.
    func lookup(_ word: String) -> LookupResult? {
        if let display = store?.displayEntry(for: word) {
            return LookupResult(
                word: display.tapped,
                gloss: display.gloss,
                phonetic: display.phonetic,
                partOfSpeech: display.partOfSpeech,
                source: .pack,
                accentVariant: display.subtitle
            )
        }
        if demo == nil { demo = DemoPack.load() }
        return demo?.lookup(word)
    }
}

private extension InstallState {
    /// Only the two failures the reader can act on get a sentence here.
    var settingsDescription: String {
        switch self {
        case .failedNetwork: return "The dictionary could not be downloaded."
        case .failedHash, .failedCorrupt: return "The dictionary failed its check."
        case .failedDisk: return "There is no room for the dictionary."
        case .failedRegistry: return "The dictionary list is unavailable."
        default: return "The dictionary could not be installed."
        }
    }
}

/// Carries progress reports from the installer's `@Sendable` closure back to
/// the registry on the main actor. The weak reference keeps the registry
/// owning the run, not the other way round.
private struct ProgressBox: @unchecked Sendable {
    weak var registry: PackRegistry?
}
