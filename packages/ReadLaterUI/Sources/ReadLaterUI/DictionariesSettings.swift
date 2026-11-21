import Foundation
import ReadLaterCore
import SwiftUI

/// The words Settings › Dictionaries shows for a pack's state. Reads only the
/// `CapabilityPacks` seam, so a test can drive it with a fake pack.
@MainActor
public struct DictionaryStatusText {
    private let packs: any CapabilityPacks

    public init(packs: any CapabilityPacks) {
        self.packs = packs
    }

    public var stateLine: String {
        if let failure = packs.failure { return failure }
        if packs.isInstalling { return "Downloading…" }
        if packs.isPaused { return "Paused · \(Self.formatMiB(packs.downloadedBytes)) kept" }
        if let version = packs.installedVersion { return "Installed · \(version)" }
        return "Not installed."
    }

    public var stateIsProblem: Bool { packs.failure != nil }

    public var progressLine: String {
        "\(Self.formatMiB(packs.downloadedBytes)) of \(Self.formatMiB(packs.totalBytes)) · \(percent)%"
    }

    public var percent: Int {
        guard packs.totalBytes > 0 else { return 0 }
        return Int((Double(packs.downloadedBytes) / Double(packs.totalBytes) * 100).rounded())
    }

    public var updateLine: String? {
        guard let version = packs.updateVersion else { return nil }
        if let size = packs.updateSizeBytes {
            return "Update available · \(version) · \(Self.formatMiB(size))"
        }
        return "Update available · \(version)"
    }

    public var updateButtonTitle: String {
        if let version = packs.updateVersion { return "Update to \(version)" }
        return "Update"
    }

    public static func formatMiB(_ bytes: Int) -> String {
        String(format: "%.2f MiB", Double(bytes) / 1_048_576)
    }
}

/// Settings › Dictionaries. Names the pack, its size, its state, and the one
/// action that matches that state. No control here is decorative.
public struct DictionariesSettings: View {
    private let packs: any CapabilityPacks
    @Environment(\.dismiss) private var dismiss

    public init(packs: any CapabilityPacks) {
        self.packs = packs
    }

    public var body: some View {
        let status = DictionaryStatusText(packs: packs)
        VStack(alignment: .leading, spacing: 16) {
            Text("Dictionaries")
                .font(.system(size: 17, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("English–Chinese dictionary (Traditional)")
                    .font(Theme.gloss())
                Text("14.47 MiB · downloads once · works offline")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.inkSecondary)
                Text(status.stateLine)
                    .font(Theme.caption())
                    .foregroundStyle(status.stateIsProblem ? Theme.holdInk : Theme.inkSecondary)
                    .padding(.top, 2)
                if packs.isInstalling { progressSection(status) }
                if let update = status.updateLine {
                    Text(update)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.inkSecondary)
                        .padding(.top, 2)
                }
            }

            HStack(spacing: 8) {
                if packs.isInstalled {
                    if packs.updateVersion != nil {
                        Button(status.updateButtonTitle) { packs.startInstall() }
                            .frame(minHeight: 44)
                    }
                    Button("Remove", role: .destructive) { packs.remove() }
                        .frame(minHeight: 44)
                } else if packs.isPaused {
                    Button("Resume") { packs.startInstall() }
                        .frame(minHeight: 44)
                    Button("Cancel", role: .cancel) { packs.removePartial() }
                        .frame(minHeight: 44)
                } else {
                    Button(packs.isInstalling ? "Installing…" : "Install") {
                        packs.startInstall()
                    }
                    .disabled(packs.isInstalling)
                    .frame(minHeight: 44)
                    if packs.isInstalling {
                        Button("Cancel", role: .cancel) { packs.cancelInstall() }
                            .frame(minHeight: 44)
                    }
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
        .task { await packs.checkForUpdate() }
    }

    private func progressSection(_ status: DictionaryStatusText) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if packs.totalBytes > 0 {
                ProgressView(value: Double(packs.downloadedBytes), total: Double(packs.totalBytes))
                Text(status.progressLine)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.inkSecondary)
            } else {
                ProgressView()
                Text("Starting download…")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .padding(.top, 4)
    }
}
