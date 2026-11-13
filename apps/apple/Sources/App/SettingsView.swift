import ReadLaterCore
import ReadLaterUI
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

#if os(macOS)
import AppKit
#endif

/// Settings content on both platforms: the macOS Settings scene shows it,
/// and the reader screen sheet shows it on iOS.
struct SettingsView: View {
    @ObservedObject var registry: PackRegistry = .shared
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system.rawValue
    @AppStorage(HandednessStore.storageKey) private var playOnTrailing = true

    var body: some View {
        NavigationStack {
            List {
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases, id: \.rawValue) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Appearance")
                    .accessibilityIdentifier(AccessibilityID.settingsAppearance)
                }
                Section("Play button") {
                    Picker("Side", selection: $playOnTrailing) {
                        Text("Right").tag(true)
                        Text("Left").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Play button side")
                    .accessibilityIdentifier(AccessibilityID.settingsHandedness)
                }
                NavigationLink("Dictionaries") {
                    DictionariesSettings(registry: registry)
                }
                if DiagnosticsExport.isEnabled {
                    NavigationLink("Diagnostics") {
                        DiagnosticsView()
                    }
                }
            }
            .navigationTitle("Settings")
        }
        // A macOS sheet sizes to its content, and a List asks for very
        // little. The floor keeps the sheet readable on both platforms.
        .frame(minWidth: 360, minHeight: 420)
    }
}

/// The Diagnostics row: where the files came from, what is staged, and the
/// one export action. Also the no-UI pull command, for the analyst.
struct DiagnosticsView: View {
    @State private var staged: URL?
    @State private var errorMessage: String?
    @State private var showingShare = false
    @State private var savedPath: String?

    private var hub: TelemetryHub { .shared }
    private var sourcePath: String {
        hub.oplog.configuredDirectory?.path ?? "memory only (directory not configured)"
    }

    var body: some View {
        List {
            Section("Files") {
                Text("Files come from:")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.inkSecondary)
                Text(sourcePath)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                Text("\(hub.oplog.logFiles().count) file(s) on disk · \(hub.oplog.pendingCount) event(s) waiting")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.inkSecondary)
                let tail = hub.oplog.tail(5).map(\.event)
                if !tail.isEmpty {
                    Text("Latest: \(tail.joined(separator: ", "))")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.inkSecondary)
                }
            }

            Section("Export") {
                Button("Export diagnostics") { export() }
                    .frame(minHeight: 44)
                if let staged {
                    Text("Staged: \(staged.lastPathComponent)")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.inkSecondary)
                }
                if let savedPath {
                    Text("Saved to: \(savedPath)")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.inkSecondary)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.holdInk)
                }
            }

            Section("Without the UI") {
                Text("Pull the same folder off the device:")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.inkSecondary)
                Text(DiagnosticsExport.pullCommand(
                    bundleID: Bundle.main.bundleIdentifier ?? "app.readlater.reader"
                ))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                Button("Copy command") { copyToClipboard(command()) }
                    .frame(minHeight: 44)
            }
        }
        .navigationTitle("Diagnostics")
        #if canImport(UIKit)
        .sheet(isPresented: $showingShare) {
            if let staged {
                ActivitySheet(items: [staged])
            }
        }
        #endif
    }

    private func command() -> String {
        DiagnosticsExport.pullCommand(
            bundleID: Bundle.main.bundleIdentifier ?? "app.readlater.reader"
        )
    }

    private func copyToClipboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private func export() {
        errorMessage = nil
        savedPath = nil
        let registry = PackRegistry.shared
        let pace = String(SpeedStore().speed)
        let stagedFolder: URL
        do {
            stagedFolder = try DiagnosticsExport.stage(
                dictionaryVersion: registry.installedVersion ?? "not-installed",
                pace: pace
            )
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
            return
        }
        staged = stagedFolder
        #if canImport(UIKit)
        showingShare = true
        #elseif os(macOS)
        pickDirectory { picked in
            guard let picked else { return }
            let target = picked.appendingPathComponent(stagedFolder.lastPathComponent, isDirectory: true)
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: stagedFolder, to: target)
                savedPath = target.path
            } catch {
                errorMessage = "Save failed: \(error.localizedDescription)"
            }
        }
        #endif
    }

    #if os(macOS)
    private func pickDirectory(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save diagnostics here"
        panel.begin { response in
            completion(response == .OK ? panel.url : nil)
        }
    }
    #endif
}

#if canImport(UIKit)
/// A share sheet for the staged diagnostics folder.
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
#endif
