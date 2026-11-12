import Foundation

/// The R2 registry: manifest in, archive URL out. No state, no cache. The
/// installer builds the archive URL from the base, the pack id and the
/// version in the manifest, because the manifest carries no download URL.
/// Source of truth: read-later-research/spec/dictionary-packs.md §2 and
/// read-later/tools/registry/README.md.
public enum RegistryClient {
    public static let defaultBaseURL = URL(
        string: "https://pub-2965e1ed8e124382ae9d91ea1e8637ce.r2.dev"
    )!
    public static let packID = "dictionary.en-zh-HK.lexical"

    /// Returns the raw manifest bytes. Tests inject a closure; the app passes
    /// `PackDownloader.fetch`.
    public typealias FetchData = @Sendable (URL) async throws -> Data

    /// The manifest path never carries a version; it is the pointer to the
    /// current release and is short-cached.
    public static func manifestURL(baseURL: URL = defaultBaseURL, id: String = packID) -> URL {
        baseURL
            .appendingPathComponent("packs")
            .appendingPathComponent(id)
            .appendingPathComponent("manifest.json")
    }

    /// The archive path carries the version. A published version never moves,
    /// so an installed pack keeps working with no manifest re-fetch.
    public static func archiveURL(baseURL: URL = defaultBaseURL, manifest: PackManifest) -> URL {
        baseURL
            .appendingPathComponent("packs")
            .appendingPathComponent(manifest.id)
            .appendingPathComponent(manifest.version)
            .appendingPathComponent("\(manifest.id).pack.gz")
    }

    /// Fetches the manifest and decodes it. A decode failure is a broken
    /// deploy and maps to `failedRegistry`, never to a network retry.
    public static func fetchManifest(
        id: String = packID,
        baseURL: URL = defaultBaseURL,
        fetch: FetchData
    ) async throws -> PackManifest {
        let data = try await fetch(manifestURL(baseURL: baseURL, id: id))
        return try JSONDecoder().decode(PackManifest.self, from: data)
    }
}
