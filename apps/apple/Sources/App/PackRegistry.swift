import Foundation
import ReadLaterCore
import ReadLaterPacks
import ReadLaterUI
import SwiftUI

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
final class PackRegistry: ObservableObject {
    static let shared = PackRegistry()

    @Published private(set) var installedVersion: String?
    @Published private(set) var isInstalling = false
    @Published private(set) var failure: String?

    private var store: PackIndexStore?
    private var demo: DemoPack?
    private let defaults: UserDefaults
    private let installedKey = "rl-pack-installed-version"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let version = defaults.string(forKey: installedKey),
           let sqliteURL = Self.sqliteURL(),
           FileManager.default.fileExists(atPath: sqliteURL.path)
        {
            self.store = PackIndexStore(sqliteURL: sqliteURL)
            self.installedVersion = version
        }
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

    /// Fetches the manifest, gates it against the allowlist, downloads the
    /// archive with resume, verifies the sha256, and builds the on-disk
    /// index. The demo pack keeps answering while this runs and after it
    /// fails.
    func install() async {
        guard !isInstalling, !isInstalled else { return }
        isInstalling = true
        failure = nil
        defer { isInstalling = false }

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

        guard let directory = Self.packsDirectory() else {
            failure = InstallState.failedDisk.settingsDescription
            return
        }
        let state = await PackService.install(
            manifest: manifest,
            archiveURL: RegistryClient.archiveURL(manifest: manifest),
            directory: directory,
            appVersion: Self.appVersion,
            download: { url, destination, offset, progress in
                try await PackDownloader.download(
                    url: url,
                    destination: destination,
                    resumeOffset: offset,
                    progress: progress
                )
            }
        )
        switch state {
        case .installed(let version):
            guard let sqliteURL = Self.sqliteURL() else {
                failure = InstallState.failedDisk.settingsDescription
                return
            }
            self.store = PackIndexStore(sqliteURL: sqliteURL)
            installedVersion = version
            defaults.set(version, forKey: installedKey)
        default:
            failure = state.settingsDescription
        }
    }

    /// Removes the pack. The reader keeps working; the demo answers and the
    /// offer returns.
    func remove() {
        store = nil
        installedVersion = nil
        defaults.removeObject(forKey: installedKey)
        if let directory = Self.packsDirectory() {
            for name in ["\(RegistryClient.packID).pack.gz", "\(RegistryClient.packID).sqlite"] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    /// The real pack first, the bundled demo while nothing is installed.
    /// Case-insensitive; `café` resolves to the `cafe` row with the stored
    /// headword as the subtitle.
    func lookup(_ word: String) -> LookupResult? {
        if let entry = store?.entry(for: word) {
            return LookupResult(
                word: word,
                gloss: entry.gloss,
                phonetic: entry.phonetic,
                partOfSpeech: entry.partOfSpeech,
                source: .pack,
                accentVariant: PackIndexStore.accentSubtitle(tapped: word, stored: entry.word)
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

/// Settings › Dictionaries. Names the pack, its size, its state, and the one
/// action that matches that state. No control here is decorative.
struct DictionariesSettings: View {
    @ObservedObject var registry: PackRegistry = .shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Dictionaries")
                .font(.system(size: 17, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("English–Chinese dictionary (Traditional)")
                    .font(Theme.gloss())
                Text("14.47 MiB · downloads once · works offline")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.inkSecondary)
                Text(stateLine)
                    .font(Theme.caption())
                    .foregroundStyle(stateIsProblem ? Theme.holdInk : Theme.inkSecondary)
                    .padding(.top, 2)
            }

            HStack(spacing: 8) {
                if registry.isInstalled {
                    Button("Remove", role: .destructive) { registry.remove() }
                        .frame(minHeight: 44)
                } else {
                    Button(registry.isInstalling ? "Installing…" : "Install") {
                        Task { await registry.install() }
                    }
                    .disabled(registry.isInstalling)
                    .frame(minHeight: 44)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .frame(minHeight: 44)
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.screenGutter)
        .frame(minWidth: 320, minHeight: 200, alignment: .topLeading)
        .background(Theme.paper)
    }

    private var stateLine: String {
        if let failure = registry.failure { return failure }
        if registry.isInstalling { return "Downloading…" }
        if let version = registry.installedVersion { return "Installed · \(version)" }
        return "Not installed."
    }

    private var stateIsProblem: Bool { registry.failure != nil }
}
