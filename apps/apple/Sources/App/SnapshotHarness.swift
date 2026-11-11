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

        // Press the real button. The point is the centre of the primary
        // action in a 430 x 760 window; a layout change moves it, and the
        // capture then shows the entry screen twice rather than lying.
        clickPrimaryAction()
        await pause(0.35)
        capture("02-entry-progress", into: directory)
        await pause(1.1)

        capture("03-reader", into: directory)

        app.session?.togglePlay()
        await pause(0.4)
        capture("04-playing", into: directory)

        // The audio engine in this launch delivers no word boundaries, so the
        // wash is advanced here at the measured reference pace (429 ms a word)
        // to photograph where the voice would be, not where it is stuck.
        await advance(24, app: app)
        capture("05-playing-scrolled", into: directory)

        await advance(60, app: app)
        app.session?.holdFollowing()
        await pause(0.4)
        capture("06-hold", into: directory)
        app.session?.resumeFollowing()

        app.session?.togglePlay()
        await pause(0.4)
        app.session?.openNote(0)
        await pause(0.8)
        capture("07-footnote", into: directory)
        app.session?.closeNote()
        await pause(0.25)
        capture("07b-after-note", into: directory)

        // The block gallery: tables, code, figures, maths and notes all live
        // below the first two screens.
        app.session?.scrub(toFraction: 0.62)
        await pause(0.9)
        capture("08-middle-blocks", into: directory)

        app.session?.scrub(toFraction: 0.93)
        await pause(0.7)
        capture("09-notes", into: directory)

        app.session?.scrub(toFraction: 0.05)
        await pause(0.5)
        app.session?.tapped(blockID: 2, slot: nil, word: "out-argues")
        await pause(0.9)
        capture("10-miss-offer", into: directory)

        await app.session?.installPack()
        await pause(1.6)
        capture("11-miss-resolved", into: directory)

        app.session?.closeCard()
        await pause(0.3)
        app.session?.tapped(blockID: 2, slot: nil, word: "susurrus")
        await pause(0.9)
        capture("12-hit", into: directory)

        print("[snapshot] wrote \(directory.path)")
        NSApp.terminate(nil)
    }

    /// Moves the wash forward by `words`.
    ///
    /// Debug builds only, and only the wash: the run-loop and the transport
    /// stay real. The pause after the loop is what the screenshots need, so
    /// the platform text view can scroll the new word into place.
    private static func advance(_ words: Int, app: AppModel) async {
        #if DEBUG
        guard let session = app.session else { return }
        for _ in 0 ..< words {
            session.simulateWash(toWord: session.washWordIndex + 1)
            await pause(0.02)
        }
        await pause(0.3)
        #endif
    }

    /// Sends a click into the window's own event queue. No accessibility
    /// permission is involved, so this works in a headless-ish launch.
    ///
    /// The button is found in this process's own accessibility tree, so the
    /// click follows the layout instead of a remembered coordinate.
    private static func clickPrimaryAction() {
        guard let window = mainWindow() else { return }
        // SwiftUI does not populate the accessibility tree for a window that
        // was never focused, so the button is found by sweeping the column it
        // must occupy. The form is vertically centred, so the button lies
        // between half and four fifths of the height. A click on anything
        // else on this screen only moves focus.
        let height = window.frame.height
        let width = window.frame.width
        for fraction in stride(from: 0.52, through: 0.80, by: 0.035) {
            click(at: NSPoint(x: width / 2, y: height * (1 - fraction)), in: window)
        }
    }

    private static func click(at point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            window.sendEvent(event)
        }
    }

    private static func scrollOffsetText() -> String {
        guard let window = mainWindow(),
              let scrollView = findScrollView(in: window.contentView)
        else { return "none" }
        let doc = scrollView.documentView?.frame.height ?? -1
        return "offset=\(Int(scrollView.contentView.bounds.origin.y)) clip=\(Int(scrollView.contentSize.height)) doc=\(Int(doc)) count=\(scrollViewCount(in: window.contentView))"
    }

    private static func scrollViewCount(in view: NSView?) -> Int {
        guard let view else { return 0 }
        var total = view is NSScrollView ? 1 : 0
        for child in view.subviews { total += scrollViewCount(in: child) }
        return total
    }

    private static func findScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scrollView = view as? NSScrollView, scrollView.hasVerticalScroller || scrollView.documentView != nil {
            return scrollView
        }
        for child in view.subviews {
            if let hit = findScrollView(in: child) { return hit }
        }
        return nil
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil }
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

#if os(macOS)
import AppKit

extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}

/// Depth-first search of this process's accessibility tree. SwiftUI builds the
/// tree from the view hierarchy, and a visible button carries its label.
@MainActor
func accessibilityElement(labelled label: String, in window: NSWindow) -> NSAccessibilityElement? {
    guard let root = window.contentView else { return nil }
    return search(element: root, label: label, depth: 0)
}

@MainActor
private func search(element: Any, label: String, depth: Int) -> NSAccessibilityElement? {
    guard depth < 40 else { return nil }
    if let object = element as? NSAccessibilityProtocol,
       object.accessibilityLabel() == label
    {
        // The protocol is shared, but only the concrete element type carries
        // the frame we need for a synthetic click.
        if let concrete = element as? NSAccessibilityElement {
            return concrete
        }
        if let view = element as? NSView {
            let element = NSAccessibilityElement()
            element.setAccessibilityParent(view)
            element.setAccessibilityFrame(view.accessibilityFrame())
            element.setAccessibilityLabel(label)
            return element
        }
    }
    guard let children = (element as? NSAccessibilityProtocol)?.accessibilityChildren() else { return nil }
    for child in children {
        if let hit = search(element: child, label: label, depth: depth + 1) {
            return hit
        }
    }
    return nil
}
#endif
