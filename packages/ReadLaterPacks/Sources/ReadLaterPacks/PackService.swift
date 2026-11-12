import Foundation

/// One call the app makes: gate the manifest, then run the file-backed
/// installer. An allowlist refusal never touches the network; a broken
/// deploy reads as `failedRegistry`, the one failure with no retry.
public enum PackService {
    public static func install(
        manifest: PackManifest,
        archiveURL: URL,
        directory: URL,
        appVersion: String,
        download: @escaping PackInstaller.DownloadFile,
        freeSpace: @escaping @Sendable (URL) -> Int64? = PackDownloader.freeSpace(at:),
        buildIndex: @escaping PackInstaller.BuildIndex = { archive, directory in
            try PackIndexBuilder.build(archiveURL: archive, directory: directory)
        },
        progress: PackInstaller.Progress = { _, _ in }
    ) async -> InstallState {
        guard case .allowed = PackAllowlist.check(manifest, appVersion: appVersion) else {
            return .failedRegistry
        }
        let installer = PackInstaller(
            manifest: manifest,
            downloadFile: download,
            freeSpace: freeSpace,
            buildIndex: buildIndex
        )
        return await installer.start(url: archiveURL, directory: directory, progress: progress)
    }
}
