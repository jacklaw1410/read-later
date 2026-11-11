import Foundation
import Testing

@testable import ReadLaterPacks

@Suite("InstallState transitions")
struct InstallStateTests {
    @Test("every legal transition is allowed")
    func legalTransitions() throws {
        let legal: [(InstallState, InstallState)] = [
            (.absent, .offered),
            (.offered, .downloading),
            (.offered, .absent),
            (.downloading, .downloading),
            (.downloading, .paused),
            (.paused, .downloading),
            (.downloading, .verifying),
            (.verifying, .installed(version: "2026-11-10.1")),
            (.verifying, .failedHash),
            (.verifying, .failedCorrupt),
            (.downloading, .failedNetwork),
            (.downloading, .failedRegistry),
            (.downloading, .failedDisk),
            (.failedHash, .offered),
            (.failedCorrupt, .offered),
            (.failedNetwork, .offered),
            (.failedRegistry, .absent),
            (.failedDisk, .offered),
            (.installed(version: "2026-11-10.1"), .updateAvailable(version: "2026-11-11.1")),
            (.updateAvailable(version: "2026-11-11.1"), .downloading),
            (.installed(version: "2026-11-10.1"), .absent),
        ]
        for (from, to) in legal {
            #expect(from.canTransition(to: to), "expected \(from) -> \(to) to be legal")
            var state = from
            try state.advance(to: to)
            #expect(state == to)
        }
    }

    @Test("illegal transitions throw and never move")
    func illegalTransitions() {
        let illegal: [(InstallState, InstallState)] = [
            (.absent, .downloading),
            (.absent, .installed(version: "x")),
            (.offered, .verifying),
            (.offered, .installed(version: "x")),
            (.downloading, .offered),
            (.downloading, .installed(version: "x")),
            (.paused, .verifying),
            (.paused, .offered),
            (.verifying, .downloading),
            (.verifying, .offered),
            (.failedHash, .downloading),
            (.failedNetwork, .downloading),
            (.failedRegistry, .offered),
            (.failedRegistry, .downloading),
            (.failedDisk, .downloading),
            (.installed(version: "x"), .downloading),
            (.installed(version: "x"), .offered),
            (.updateAvailable(version: "x"), .offered),
            (.updateAvailable(version: "x"), .installed(version: "x")),
            (.offered, .failedRegistry),
        ]
        for (from, to) in illegal {
            #expect(!from.canTransition(to: to), "expected \(from) -> \(to) to be illegal")
            var state = from
            #expect(throws: PackTransitionError.illegal(from: from, to: to)) {
                try state.advance(to: to)
            }
            #expect(state == from)
        }
    }

    @Test("recoverable failures return to offered, registry failure closes")
    func recoveryPoints() {
        for failure in [InstallState.failedHash, .failedCorrupt, .failedNetwork, .failedDisk] {
            #expect(failure.canTransition(to: .offered))
            #expect(!failure.canTransition(to: .downloading))
        }
        #expect(InstallState.failedRegistry.canTransition(to: .absent))
        #expect(!InstallState.failedRegistry.canTransition(to: .offered))
    }
}

@Suite("Card copy")
struct CardCopyTests {
    @Test("registry failure copy and permanent no-retry rule")
    func registryFailure() {
        #expect(PackCardCopy.message(for: .failedRegistry) == "The dictionary list is unavailable.")
        let actions = PackCardCopy.actions(for: .failedRegistry)
        #expect(actions == [.close])
        #expect(actions.count == 1)
        #expect(!actions.contains(.install))
    }

    @Test("offline miss copy")
    func offlineMiss() {
        #expect(PackCardCopy.offlineMissMessage == "No offline entry for this word.")
    }

    @Test("offer copy matches design/miss-state.md §2.1")
    func offerCopy() {
        #expect(PackCardCopy.offerTitle == "English–Chinese dictionary (Traditional)")
        #expect(PackCardCopy.offerMeta == "14.47 MiB · downloads once · works offline")
        #expect(PackCardCopy.offerWayBack == "You can add it later in Settings › Dictionaries.")
    }

    @Test("action titles")
    func actionTitles() {
        #expect(CardAction.install.rawValue == "Install")
        #expect(CardAction.notNow.rawValue == "Not now")
        #expect(CardAction.close.rawValue == "Close")
        #expect(CardAction.searchWeb.rawValue == "Search the web ↗")
    }

    @Test("failure messages match spec/dictionary-packs.md §3")
    func failureMessages() {
        #expect(PackCardCopy.message(for: .failedNetwork) == "Download stopped — no network.")
        #expect(PackCardCopy.message(for: .failedDisk) == "Not enough space (needs 14.47 MiB).")
        #expect(PackCardCopy.message(for: .failedHash) == "Download corrupted — try again.")
        #expect(PackCardCopy.message(for: .failedCorrupt) == "Dictionary could not be read — try again.")
    }
}

/// Sendable box for progress pairs reported from the installer actor.
final class LockedPairs: @unchecked Sendable {
    private var pairs: [(Int, Int)] = []
    private let lock = NSLock()

    func append(_ pair: (Int, Int)) {
        lock.withLock { pairs.append(pair) }
    }

    var values: [(Int, Int)] {
        lock.withLock { pairs }
    }
}

@Suite("PackInstaller")
struct PackInstallerTests {
    func manifest(for data: Data) throws -> PackManifest {
        try decodeManifest(manifestJSON(sha256: Verifier.sha256Hex(of: data)))
    }

    @Test("walks offered to installed with byte progress")
    func happyPath() async throws {
        let bytes = Data(repeating: 0x41, count: 4096)
        let manifest = try manifest(for: bytes)
        let installer = PackInstaller(manifest: manifest) { _ in bytes }
        let seen = LockedPairs()
        let final = await installer.start(url: URL(string: "https://example.com/pack.gz")!) { received, total in
            seen.append((received, total))
        }
        #expect(final == .installed(version: "2026-11-10.1"))
        #expect(await installer.state == .installed(version: "2026-11-10.1"))
        let pairs = seen.values
        #expect(!pairs.isEmpty)
        #expect(pairs.last?.0 == pairs.last?.1)
        #expect(pairs.last?.1 == bytes.count)
        #expect(await installer.transferredBytes == bytes.count)
    }

    @Test("hash mismatch reaches failedHash, never installed")
    func failedHash() async throws {
        let manifest = try decodeManifest(manifestJSON(sha256: String(repeating: "0", count: 64)))
        let installer = PackInstaller(manifest: manifest) { _ in Data("corrupt".utf8) }
        let final = await installer.start(url: URL(string: "https://example.com/pack.gz")!)
        #expect(final == .failedHash)
        #expect(await installer.state == .failedHash)
        if case .installed = await installer.state {
            Issue.record("failed hash must not be installed")
        }
        // Retry returns to offered, never straight back to downloading.
        let state = await installer.state
        #expect(state.canTransition(to: .offered))
        #expect(!state.canTransition(to: .downloading))
    }

    @Test("network error reaches failedNetwork")
    func failedNetwork() async throws {
        let bytes = Data("x".utf8)
        let manifest = try manifest(for: bytes)
        let installer = PackInstaller(manifest: manifest) { _ in
            throw PackDownloadError.network(reason: "offline")
        }
        let final = await installer.start(url: URL(string: "https://example.com/pack.gz")!)
        #expect(final == .failedNetwork)
    }

    @Test("registry error is permanent: close only, no retry")
    func failedRegistryPermanent() async throws {
        let bytes = Data("x".utf8)
        let manifest = try manifest(for: bytes)
        let installer = PackInstaller(manifest: manifest) { _ in
            throw PackDownloadError.registry(status: 404)
        }
        let final = await installer.start(url: URL(string: "https://example.com/pack.gz")!)
        #expect(final == .failedRegistry)
        #expect(PackCardCopy.actions(for: final) == [.close])
        #expect(!final.canTransition(to: .offered))
        #expect(final.canTransition(to: .absent))
    }

    @Test("cancel then resume keeps the byte count")
    func cancelResume() async throws {
        let bytes = Data(repeating: 0x42, count: 65_536)
        let manifest = try manifest(for: bytes)
        let installer = PackInstaller(manifest: manifest) { _ in
            try? await Task.sleep(nanoseconds: 20_000_000)
            return bytes
        }
        let url = URL(string: "https://example.com/pack.gz")!
        let task = Task { await installer.start(url: url) { _, _ in } }
        while await installer.state != .downloading {
            await Task.yield()
        }
        while await installer.transferredBytes == 0 {
            await Task.yield()
        }
        let paused = await installer.cancel()
        #expect(paused == .paused)
        let kept = await installer.transferredBytes
        #expect(kept > 0)
        _ = await task.value
        #expect(await installer.state == .paused)
        #expect(await installer.transferredBytes == kept)
        let final = await installer.resume(url: url) { _, _ in }
        #expect(final == .installed(version: "2026-11-10.1"))
        #expect(await installer.transferredBytes == bytes.count)
    }
}
