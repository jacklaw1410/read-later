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
@MainActor
final class PackRegistry: ObservableObject {
    static let shared = PackRegistry()

    @Published private(set) var installedVersion: String?
    @Published private(set) var isInstalling = false
    @Published private(set) var failure: String?

    private(set) var pack: DemoPack?
    private let defaults: UserDefaults
    private let installedKey = "rl-pack-installed-version"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let version = defaults.string(forKey: installedKey),
           let pack = DemoPack.load(),
           pack.version == version
        {
            self.pack = pack
            self.installedVersion = version
        }
    }

    var isInstalled: Bool { installedVersion != nil }

    func install() async {
        guard !isInstalling, !isInstalled else { return }
        isInstalling = true
        failure = nil
        defer { isInstalling = false }

        switch await DemoPackInstaller.install() {
        case let .installed(pack):
            self.pack = pack
            installedVersion = pack.version
            defaults.set(pack.version, forKey: installedKey)
        case let .failed(state):
            failure = state.settingsDescription
        }
    }

    /// Removes the pack. The reader keeps working; the offer returns.
    func remove() {
        pack = nil
        installedVersion = nil
        defaults.removeObject(forKey: installedKey)
    }

    func lookup(_ word: String) -> LookupResult? {
        pack?.lookup(word)
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
