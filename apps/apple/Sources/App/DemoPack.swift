import Foundation
import ReadLaterCore
import ReadLaterPacks

/// The bundled demo dictionary.
///
/// The real pack is a 14.47 MiB download that does not exist yet. This one is
/// twenty entries shipped in the app so the offer, the install, and the
/// re-resolve loop are all real on a machine with no network. It goes through
/// the same manifest decode and the same sha256 check as the real pack, so a
/// defect in that path shows up here rather than after the download lands.
///
/// Source words are measured, not invented: `out-argues` is in the demo article
/// and the system dictionary does not have it, so a tap on it reaches the miss
/// card and the install turns that same card into a hit.
struct DemoPack: Sendable {
    let version: String
    private let entries: [String: LookupResult]

    /// Loads and verifies the bundled pack, or nil when it is missing or does
    /// not match its manifest.
    static func load() -> DemoPack? {
        guard let tsvURL = Bundle.main.url(forResource: "demo-pack", withExtension: "tsv"),
              let manifestURL = Bundle.main.url(forResource: "demo-pack.manifest", withExtension: "json"),
              let data = try? Data(contentsOf: tsvURL),
              let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PackManifest.self, from: manifestData)
        else { return nil }

        guard case .match = Verifier.verify(data: data, expectedHex: manifest.sha256) else {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var entries: [String: LookupResult] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4 else { continue }
            let headword = fields[0].lowercased()
            guard !headword.isEmpty else { continue }
            entries[headword] = LookupResult(
                word: fields[0],
                gloss: GlossRenderer.render(gloss: fields[3]),
                phonetic: fields[2].isEmpty ? nil : fields[2],
                partOfSpeech: fields[1].isEmpty ? nil : fields[1],
                source: .pack
            )
        }
        return DemoPack(version: manifest.version, entries: entries)
    }

    func lookup(_ word: String) -> LookupResult? {
        entries[word.lowercased()]
    }

    var headwordCount: Int { entries.count }
}

/// Walks the real install state machine against the bundled bytes.
///
/// The download closure reads the resource instead of the network. Everything
/// after it is the production path: offered, downloading, verifying, installed,
/// including the sha256 check that decides `failedHash`.
enum DemoPackInstaller {
    enum Outcome: Sendable {
        case installed(DemoPack)
        case failed(InstallState)
    }

    static func install(progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> Outcome {
        guard let manifestURL = Bundle.main.url(forResource: "demo-pack.manifest", withExtension: "json"),
              let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PackManifest.self, from: manifestData)
        else { return .failed(.failedRegistry) }

        guard case .allowed = PackAllowlist.check(manifest, appVersion: appVersion) else {
            return .failed(.failedRegistry)
        }

        let installer = PackInstaller(
            manifest: manifest,
            initialState: .offered,
            download: { _ in
                // A small delay so the card's Installing… state is visible and
                // the progress callback has something to report.
                try await Task.sleep(nanoseconds: 400_000_000)
                guard let url = Bundle.main.url(forResource: "demo-pack", withExtension: "tsv"),
                      let data = try? Data(contentsOf: url)
                else { throw PackDownloadError.network(reason: "bundled pack missing") }
                return data
            }
        )

        let state = await installer.start(
            url: URL(string: "bundled://demo-pack.tsv")!,
            progress: progress
        )

        switch state {
        case .installed:
            guard let pack = DemoPack.load() else { return .failed(.failedCorrupt) }
            return .installed(pack)
        default:
            return .failed(state)
        }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}
