#if DEBUG
import Foundation

/// Launch configuration for debug runs.
///
/// The default is production behaviour: no `--debug.` flag changes nothing.
/// A preset fills a group of fields, and an explicit flag overrides one field
/// of that preset. The e2e suites use the `e2e` preset; other debug runs can
/// start from it and change one value, for example a faster scripted voice.
///
/// Flags are namespaced so they cannot collide with a real launch argument:
///
///     --debug.preset=e2e
///     --debug.voice=scripted
///     --debug.voice-pace=120
///     --debug.animations=off
///     --debug.appearance=dark
///     --debug.locale=zh_HK
///     --debug.reset=all
///     --debug.seedPasteboard=https://example.com/article
///     --debug.autoplay=3000
///
/// Unknown keys and bad values are ignored with a warning, never a crash: a
/// mistyped flag must not hide the behaviour under test.
public struct LaunchOptions: Equatable, Sendable {
    public enum Voice: Equatable, Sendable {
        case system
        case scripted(millisecondsPerWord: Int)
    }

    public enum Reset: String, Equatable, Sendable {
        case none
        case store
        case defaults
        case all
    }

    /// Launch mark after which a benchmark run exits on its own.
    public enum BenchmarkExit: String, Equatable, Sendable {
        case firstFrame
    }

    public static let flagPrefix = "--debug."
    public static let defaultScriptedPace = 80
    public static let scriptedPaceRange = 20 ... 1_000

    /// Delete the reading store, the defaults, or both, before the store opens.
    public private(set) var reset: Reset = .none
    /// Which voice drives the wash.
    public private(set) var voice: Voice = .system
    /// SwiftUI motion. Off also sets the reduce-motion environment.
    public private(set) var animations = true
    /// Pins the colour scheme. Nil follows the stored choice.
    public private(set) var appearance: Appearance?
    /// Pins the locale. Nil follows the system.
    public private(set) var locale: String?
    /// Debug seed for device latency runs (M2/M4 treatment): base64 article
    /// text. The app saves it to the store with its place at word zero, so
    /// the test opens the resume offer instead of typing the raw text.
    public private(set) var seedTextB64: String?
    /// Debug seed for the pasteboard (paste journeys): plain text, no `=`.
    /// Set at launch inside the app process, because a UI test runner
    /// cannot reach the simulator's board from the host.
    public private(set) var seedPasteboard: String?
    /// Milliseconds after launch to resume the offered article and start
    /// playback. Nil = off. Exists for CLI SwiftUI traces, which interpose
    /// only at launch and cannot host a test runner's taps (M7).
    public private(set) var autoPlayAfterMs: Int?
    /// Number of scripted reader-interaction iterations to run after the
    /// reader opens, warmups included. Nil = off. Debug-only benchmark driver.
    public private(set) var interactionIterations: Int?
    /// Telemetry output directory for benchmark runs. Nil = the stock
    /// Application Support directory. Debug-only.
    public private(set) var telemetryDirectory: String?
    /// Exit as soon as a named launch mark lands, so the harness never has
    /// to kill the app and lose a buffered line. Nil = stay running.
    public private(set) var benchmarkExit: BenchmarkExit?
    /// True when at least one `--debug.` flag was present.
    public private(set) var isActive = false
    /// Human-readable notes for flags that were ignored.
    public private(set) var warnings: [String] = []

    public init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        var values: [String: String] = [:]

        for argument in arguments where argument.hasPrefix(Self.flagPrefix) {
            isActive = true
            let body = argument.dropFirst(Self.flagPrefix.count)
            guard let separator = body.firstIndex(of: "=") else {
                warnings.append("ignored \(argument): expected key=value")
                continue
            }
            let key = String(body[..<separator])
            let value = String(body[body.index(after: separator)...])
            values[key] = value
        }

        if let preset = values.removeValue(forKey: "preset") {
            apply(preset: preset)
        }

        let pace = Self.pace(from: values["voice-pace"])
        var voiceValue = values["voice"]
        if voiceValue == nil, case .scripted = voice, pace != nil {
            voiceValue = "scripted"
        }
        if let raw = voiceValue {
            switch raw {
            case "system":
                voice = .system
            case "scripted":
                voice = .scripted(millisecondsPerWord: pace ?? Self.defaultScriptedPace)
            default:
                warnings.append("ignored voice=\(raw): expected system or scripted")
            }
        }

        if let raw = values["animations"] {
            switch raw {
            case "on": animations = true
            case "off": animations = false
            default: warnings.append("ignored animations=\(raw): expected on or off")
            }
        }

        if let raw = values["appearance"] {
            if let parsed = Appearance(rawValue: raw) {
                appearance = parsed
            } else {
                warnings.append("ignored appearance=\(raw): expected system, light or dark")
            }
        }

        if let raw = values["locale"] {
            if raw.isEmpty {
                warnings.append("ignored locale: the value is empty")
            } else {
                locale = raw
            }
        }

        if let raw = values["reset"] {
            if let parsed = Reset(rawValue: raw) {
                reset = parsed
            } else {
                warnings.append("ignored reset=\(raw): expected none, store, defaults or all")
            }
        }

        if let raw = values["seedTextB64"] {
            if raw.isEmpty {
                warnings.append("ignored seedTextB64: the value is empty")
            } else {
                seedTextB64 = raw
            }
        }

        if let raw = values["seedPasteboard"] {
            if raw.isEmpty {
                warnings.append("ignored seedPasteboard: the value is empty")
            } else {
                seedPasteboard = raw
            }
        }

        if let raw = values["autoplay"] {
            if let milliseconds = Int(raw), (0 ... 600_000).contains(milliseconds) {
                autoPlayAfterMs = milliseconds
            } else {
                warnings.append("ignored autoplay=\(raw): expected milliseconds 0...600000")
            }
        }

        if let raw = values["interactions"] {
            if let count = Int(raw), (0 ... 10_000).contains(count) {
                interactionIterations = count
            } else {
                warnings.append("ignored interactions=\(raw): expected count 0...10000")
            }
        }

        if let raw = values["telemetryDir"] {
            if raw.isEmpty {
                warnings.append("ignored telemetryDir: the value is empty")
            } else {
                telemetryDirectory = raw
            }
        }

        if let raw = values["benchmarkExit"] {
            if let parsed = BenchmarkExit(rawValue: raw) {
                benchmarkExit = parsed
            } else {
                warnings.append("ignored benchmarkExit=\(raw): expected firstFrame")
            }
        }

        for key in values.keys where !Self.knownKeys.contains(key) {
            warnings.append("ignored unknown flag \(Self.flagPrefix)\(key)")
        }
    }

    private mutating func apply(preset: String) {
        switch preset {
        case "e2e":
            reset = .all
            voice = .scripted(millisecondsPerWord: Self.defaultScriptedPace)
            animations = false
            appearance = .light
            locale = "en"
        default:
            warnings.append("ignored preset=\(preset): expected e2e")
        }
    }

    private static let knownKeys: Set<String> = [
        "preset", "reset", "voice", "voice-pace", "animations", "appearance", "locale",
        "seedTextB64", "seedPasteboard", "autoplay",
        "interactions", "telemetryDir", "benchmarkExit",
    ]

    private static func pace(from raw: String?) -> Int? {
        guard let raw, let value = Int(raw) else { return nil }
        return min(max(value, scriptedPaceRange.lowerBound), scriptedPaceRange.upperBound)
    }
}
#endif
