import Foundation
import Testing

@testable import ReadLaterPacks

/// Sendable box for one value reported from the installer actor.
final class LockedValue<T: Sendable>: @unchecked Sendable {
    private var storage: T
    private let lock = NSLock()

    init(_ value: T) {
        storage = value
    }

    var value: T {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

func packTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func packTestManifest(data: Data, kind: String = "dictionary.en-zh-HK.lexical") throws -> PackManifest {
    var manifest = try decodeManifest(manifestJSON(sha256: Verifier.sha256Hex(of: data), kind: kind))
    manifest.sizeBytes = data.count
    return manifest
}

/// Copies bytes to the destination, honouring the resume offset the
/// installer passes in. Reports (total, total) once.
func passthroughDownload(
    _ data: Data,
    offsetSeen: LockedValue<Int>? = nil,
    called: LockedValue<Bool>? = nil
) -> PackInstaller.DownloadFile {
    { _, destination, offset, progress in
        called?.value = true
        offsetSeen?.value = offset
        let remaining = data.dropFirst(offset)
        if offset == 0 {
            try remaining.write(to: destination)
        } else {
            let handle = try FileHandle(forUpdating: destination)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: remaining)
        }
        progress(data.count, data.count)
    }
}

/// The lexical TSV layout: word, phonetic, pos, gloss.
func syntheticLexicalTSV() -> String {
    [
        "serendipity\t,serәn'dipiti\tn.\t偶然發現珍寶的運氣",
        "cafe\tka'fei\tn.\t咖啡館",
        "London\t'lʌndәn\tn.\t倫敦",
        "cafa\t\t\tabbr. 測試",
        "out-argues\t\tn.\t在辯論中勝過",
    ].joined(separator: "\n") + "\n"
}

func syntheticArchive(_ tsv: String, in directory: URL, id: String) throws -> URL {
    let raw = directory.appendingPathComponent("\(id).tsv")
    let gz = directory.appendingPathComponent("\(id).pack.gz")
    try tsv.write(to: raw, atomically: true, encoding: .utf8)
    try Gzip.gzip(file: raw, to: gz)
    try? FileManager.default.removeItem(at: raw)
    return gz
}

@Suite("Registry client")
struct RegistryClientTests {
    @Test("manifest URL has no version in it")
    func manifestURL() {
        let url = RegistryClient.manifestURL()
        #expect(url.absoluteString.hasSuffix("/packs/dictionary.en-zh-HK.lexical/manifest.json"))
    }

    @Test("archive URL carries the version from the manifest")
    func archiveURL() throws {
        let manifest = try decodeManifest(realManifestJSON)
        let url = RegistryClient.archiveURL(manifest: manifest)
        #expect(
            url.absoluteString
                == "https://pub-2965e1ed8e124382ae9d91ea1e8637ce.r2.dev/packs/dictionary.en-zh-HK.lexical/2026-11-10.1/dictionary.en-zh-HK.lexical.pack.gz"
        )
    }

    @Test("manifest decode failure throws before any download")
    func decodeFailure() async {
        let called = LockedValue(false)
        do {
            _ = try await RegistryClient.fetchManifest(fetch: { _ in
                called.value = true
                return Data("not json".utf8)
            })
            Issue.record("expected a decode error")
        } catch {
            #expect(error is DecodingError || error is PackManifestError)
        }
        #expect(called.value)
    }

    @Test("missing manifest field names the field")
    func missingField() async {
        let json = manifestJSON(sha256: String(repeating: "0", count: 64))
            .replacingOccurrences(of: #""size_bytes": 15171897,"#, with: "")
        do {
            _ = try await RegistryClient.fetchManifest(fetch: { _ in Data(json.utf8) })
            Issue.record("expected a missing-field error")
        } catch let error as PackManifestError {
            #expect(error == .missingField("size_bytes"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test(
        "live R2 manifest decodes and allows install",
        .enabled(if: ProcessInfo.processInfo.environment["READLATER_LIVE_PACK"] == "1")
    )
    func liveManifest() async throws {
        let manifest = try await RegistryClient.fetchManifest(fetch: { url in
            try await PackDownloader.fetch(url: url)
        })
        #expect(manifest.id == RegistryClient.packID)
        #expect(manifest.sizeBytes == 15_171_897)
        #expect(manifest.sha256 == "769256b3f33470a0271c8b3f74fe1e0eb7e9dd53ae58bc42292ca305168359a7")
        #expect(PackAllowlist.check(manifest, appVersion: "0.1.0") == .allowed)
        #expect(RegistryClient.archiveURL(manifest: manifest).absoluteString.hasSuffix("/2026-11-10.1/dictionary.en-zh-HK.lexical.pack.gz"))
    }
}

@Suite("File-backed install")
struct PackFileInstallTests {
    func archiveURL(in directory: URL) -> URL {
        directory.appendingPathComponent("dictionary.en-zh-HK.lexical.pack.gz")
    }

    @Test("allowlist refusal never downloads")
    func allowlistRefusal() async throws {
        let data = Data("gloss pack".utf8)
        let manifest = try packTestManifest(data: data, kind: "dictionary.en-zh-HK.gloss")
        let called = LockedValue(false)
        let directory = try packTestDirectory()
        let state = await PackService.install(
            manifest: manifest,
            archiveURL: URL(string: "https://example.com/pack.gz")!,
            directory: directory,
            appVersion: "0.1.0",
            download: passthroughDownload(data, called: called)
        )
        #expect(state == .failedRegistry)
        #expect(!called.value)
        #expect(PackCardCopy.actions(for: state) == [.close])
    }

    @Test("hash mismatch deletes the partial file and shows the check state")
    func hashMismatch() async throws {
        let manifest = try decodeManifest(manifestJSON(sha256: String(repeating: "0", count: 64)))
        let directory = try packTestDirectory()
        let archive = archiveURL(in: directory)
        let state = await PackService.install(
            manifest: manifest,
            archiveURL: URL(string: "https://example.com/pack.gz")!,
            directory: directory,
            appVersion: "0.1.0",
            download: passthroughDownload(Data("corrupt".utf8))
        )
        #expect(state == .failedHash)
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        #expect(PackCardCopy.message(for: state) == "Download corrupted — try again.")
        #expect(state.canTransition(to: .offered))
        #expect(!state.canTransition(to: .downloading))
    }

    @Test("disk precheck stops before the first byte")
    func diskPrecheck() async throws {
        let data = Data(repeating: 0x41, count: 4096)
        let manifest = try packTestManifest(data: data)
        let called = LockedValue(false)
        let directory = try packTestDirectory()
        let state = await PackService.install(
            manifest: manifest,
            archiveURL: URL(string: "https://example.com/pack.gz")!,
            directory: directory,
            appVersion: "0.1.0",
            download: passthroughDownload(data, called: called),
            freeSpace: { _ in 0 }
        )
        #expect(state == .failedDisk)
        #expect(!called.value)
        #expect(PackCardCopy.message(for: state) == "Not enough space (needs 14.47 MiB).")
    }

    @Test("resume continues from the partial file")
    func resumeFromPartial() async throws {
        let tsv = syntheticLexicalTSV()
        let build = try packTestDirectory()
        let source = try syntheticArchive(tsv, in: build, id: "dictionary.en-zh-HK.lexical")
        let bytes = try Data(contentsOf: source)
        var manifest = try packTestManifest(data: bytes)
        manifest.format = "gzip-tsv"

        let directory = try packTestDirectory()
        let archive = archiveURL(in: directory)
        let half = bytes.count / 2
        try bytes.prefix(half).write(to: archive)

        let offsetSeen = LockedValue(-1)
        let seen = LockedPairs()
        let installer = PackInstaller(
            manifest: manifest,
            initialState: .paused,
            downloadFile: { url, destination, offset, progress in
                offsetSeen.value = offset
                let inner = passthroughDownload(bytes)
                try await inner(url, destination, offset) { received, total in
                    seen.append((received, total))
                    progress(received, total)
                }
            }
        )
        let state = await installer.start(url: URL(string: "https://example.com/pack.gz")!, directory: directory)
        #expect(state == .installed(version: manifest.version))
        #expect(offsetSeen.value == half)
        let pairs = seen.values
        #expect(!pairs.isEmpty)
        #expect(pairs.allSatisfy { $0.0 >= half })
        #expect(pairs.last?.0 == bytes.count)
        #expect(await installer.transferredBytes == bytes.count)
    }

    @Test("network error reaches failedNetwork, registry error is permanent")
    func transportMapping() async throws {
        let data = Data("x".utf8)
        let manifest = try packTestManifest(data: data)
        let directory = try packTestDirectory()
        let network = PackInstaller(manifest: manifest, downloadFile: { _, _, _, _ in
            throw PackDownloadError.network(reason: "offline")
        })
        #expect(
            await network.start(url: URL(string: "https://example.com/pack.gz")!, directory: directory)
                == .failedNetwork
        )
        let registry = PackInstaller(manifest: manifest, downloadFile: { _, _, _, _ in
            throw PackDownloadError.registry(status: 404)
        })
        let failed = await registry.start(url: URL(string: "https://example.com/pack.gz")!, directory: directory)
        #expect(failed == .failedRegistry)
        #expect(!failed.canTransition(to: .offered))
        #expect(failed.canTransition(to: .absent))
    }

    @Test("end to end: synthetic archive installs and lookups read it back")
    func endToEnd() async throws {
        let build = try packTestDirectory()
        let source = try syntheticArchive(syntheticLexicalTSV(), in: build, id: "dictionary.en-zh-HK.lexical")
        let bytes = try Data(contentsOf: source)
        let manifest = try packTestManifest(data: bytes)

        let directory = try packTestDirectory()
        let seen = LockedPairs()
        let state = await PackService.install(
            manifest: manifest,
            archiveURL: URL(string: "https://example.com/pack.gz")!,
            directory: directory,
            appVersion: "0.1.0",
            download: passthroughDownload(bytes),
            progress: { received, total in seen.append((received, total)) }
        )
        #expect(state == .installed(version: manifest.version))
        let pairs = seen.values
        #expect(!pairs.isEmpty)
        #expect(pairs.last?.0 == pairs.last?.1)

        let sqlite = directory.appendingPathComponent("dictionary.en-zh-HK.lexical.sqlite")
        #expect(FileManager.default.fileExists(atPath: sqlite.path))
        let store = PackIndexStore(sqliteURL: sqlite)

        let hit = try #require(store.entry(for: "SERENDIPITY"))
        #expect(hit.word == "serendipity")
        #expect(hit.phonetic == ",serәn'dipiti")
        #expect(hit.partOfSpeech == "n.")
        #expect(hit.gloss == "偶然發現珍寶的運氣")

        let accented = try #require(store.entry(for: "café"))
        #expect(accented.word == "cafe")
        #expect(PackIndexStore.accentSubtitle(tapped: "café", stored: accented.word) == "cafe")

        let cased = try #require(store.entry(for: "LONDON"))
        #expect(cased.word == "London")
        #expect(PackIndexStore.accentSubtitle(tapped: "LONDON", stored: cased.word) == nil)

        let bare = try #require(store.entry(for: "cafa"))
        #expect(bare.phonetic == nil)
        #expect(bare.partOfSpeech == nil)

        #expect(store.entry(for: "zzzqqq") == nil)
        #expect(store.entry(for: "  ") == nil)
    }

    @Test("corrupt archive reaches failedCorrupt")
    func corruptArchive() async throws {
        let data = Data("definitely not gzip".utf8)
        let real = try packTestManifest(data: data)
        let directory = try packTestDirectory()
        let state = await PackService.install(
            manifest: real,
            archiveURL: URL(string: "https://example.com/pack.gz")!,
            directory: directory,
            appVersion: "0.1.0",
            download: passthroughDownload(data)
        )
        #expect(state == .failedCorrupt)
        #expect(PackCardCopy.message(for: state) == "Dictionary could not be read — try again.")
        #expect(!FileManager.default.fileExists(atPath: archiveURL(in: directory).path))
    }

    @Test("success deletes the archive, keeping the index")
    func successDeletesArchive() async throws {
        let build = try packTestDirectory()
        let source = try syntheticArchive(syntheticLexicalTSV(), in: build, id: "dictionary.en-zh-HK.lexical")
        let bytes = try Data(contentsOf: source)
        let manifest = try packTestManifest(data: bytes)

        let directory = try packTestDirectory()
        let state = await PackService.install(
            manifest: manifest,
            archiveURL: URL(string: "https://example.com/pack.gz")!,
            directory: directory,
            appVersion: "0.1.0",
            download: passthroughDownload(bytes)
        )
        #expect(state == .installed(version: manifest.version))
        #expect(!FileManager.default.fileExists(atPath: archiveURL(in: directory).path))
        let sqlite = directory.appendingPathComponent("dictionary.en-zh-HK.lexical.sqlite")
        #expect(FileManager.default.fileExists(atPath: sqlite.path))
        #expect(PackIndexStore(sqliteURL: sqlite).entry(for: "serendipity") != nil)
    }

    @Test("pause keeps the partial file so resume still works")
    func pauseKeepsPartial() async throws {
        let data = Data(repeating: 0x41, count: 1_000_000)
        let manifest = try packTestManifest(data: data)
        let directory = try packTestDirectory()
        let installer = PackInstaller(
            manifest: manifest,
            downloadFile: { _, destination, _, _ in
                try Data("partial".utf8).write(to: destination)
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        )
        let task = Task {
            await installer.start(url: URL(string: "https://example.com/pack.gz")!, directory: directory)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await installer.cancel() == .paused)
        #expect(await task.value == .paused)
        #expect(FileManager.default.fileExists(atPath: archiveURL(in: directory).path))
    }
}
