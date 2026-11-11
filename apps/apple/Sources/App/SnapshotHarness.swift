#if os(macOS)
import AppKit
import Foundation
import ReadLaterCore
import ReadLaterUI
import SwiftUI

/// Writes PNGs of the running window so the surface can be inspected without a
/// screen-recording permission.
///
/// Runs only when the app is launched with `--snapshot`. It drives the same
/// session the reader drives, so what it captures is the real rendering,
/// including the platform text views the wash lives in.
@MainActor
enum SnapshotHarness {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--snapshot")
    }

    static func run(app: AppModel) async {
        let directory = outputDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Start from no pack, so the offer is exercised and then resolved by
        // the real installer rather than by whatever a past run left behind.
        PackRegistry.shared.remove()

        await pause(1.4)
        capture("01-entry", into: directory)

        app.open(ArticleLibrary.demo)
        await pause(1.4)
        capture("02-reader", into: directory)

        app.session?.togglePlay()
        await pause(2.6)
        capture("03-playing", into: directory)

        // Long enough for the wash to cross several lines inside one block.
        await pause(11.0)
        capture("04-playing-scrolled", into: directory)

        app.session?.holdFollowing()
        await pause(0.6)
        capture("05-hold", into: directory)
        app.session?.resumeFollowing()

        app.session?.togglePlay()
        await pause(0.4)
        app.session?.openNote(0)
        await pause(0.8)
        capture("06-footnote", into: directory)
        app.session?.closeNote()

        app.session?.tapped(blockID: 2, slot: nil, word: "out-argues")
        await pause(0.9)
        capture("07-miss-offer", into: directory)

        await app.session?.installPack()
        await pause(1.6)
        capture("08-miss-resolved", into: directory)

        app.session?.closeCard()
        await pause(0.3)
        app.session?.tapped(blockID: 2, slot: nil, word: "susurrus")
        await pause(0.9)
        capture("09-hit", into: directory)

        print("[snapshot] wrote \(directory.path)")
        NSApp.terminate(nil)
    }

    private static func outputDirectory() -> URL {
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--snapshot"),
           ProcessInfo.processInfo.arguments.count > index + 1
        {
            return URL(fileURLWithPath: ProcessInfo.processInfo.arguments[index + 1])
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("readlater-snapshots")
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func capture(_ name: String, into directory: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView,
              view.bounds.width > 0, view.bounds.height > 0
        else {
            print("[snapshot] no window for \(name)")
            return
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let url = directory.appendingPathComponent("\(name).png")
        try? data.write(to: url)
        print("[snapshot] \(url.path) \(Int(view.bounds.width))x\(Int(view.bounds.height))")
    }
}
#endif
