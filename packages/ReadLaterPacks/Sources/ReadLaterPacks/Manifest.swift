import Foundation

/// One JSON manifest per pack, fetched from the pack registry.
/// Source of truth: read-later-research/spec/dictionary-packs.md §2.
/// Field names follow the real manifest at
/// evidence/2026-11-10-pack-zh-hk/artifacts/dictionary.en-zh-HK.lexical.manifest.json.
public struct PackManifest: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var version: String
    public var sizeBytes: Int
    public var sha256: String
    public var minAppVersion: String
    public var languages: [String]
    public var capabilities: [String]
    public var licence: PackLicence
    public var sourceURL: String
    public var conversion: String
    public var headwords: Int
    public var format: String

    public init(
        id: String,
        kind: String,
        version: String,
        sizeBytes: Int,
        sha256: String,
        minAppVersion: String,
        languages: [String],
        capabilities: [String],
        licence: PackLicence,
        sourceURL: String,
        conversion: String,
        headwords: Int,
        format: String
    ) {
        self.id = id
        self.kind = kind
        self.version = version
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.minAppVersion = minAppVersion
        self.languages = languages
        self.capabilities = capabilities
        self.licence = licence
        self.sourceURL = sourceURL
        self.conversion = conversion
        self.headwords = headwords
        self.format = format
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case version
        case sizeBytes = "size_bytes"
        case sha256
        case minAppVersion = "min_app_version"
        case languages
        case capabilities
        case licence
        case sourceURL = "source_url"
        case conversion
        case headwords
        case format
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try Self.required(String.self, c, .id, "id")
        kind = try Self.required(String.self, c, .kind, "kind")
        version = try Self.required(String.self, c, .version, "version")
        sizeBytes = try Self.required(Int.self, c, .sizeBytes, "size_bytes")
        sha256 = try Self.required(String.self, c, .sha256, "sha256")
        minAppVersion = try Self.required(String.self, c, .minAppVersion, "min_app_version")
        languages = try Self.required([String].self, c, .languages, "languages")
        capabilities = try Self.required([String].self, c, .capabilities, "capabilities")
        licence = try Self.required(PackLicence.self, c, .licence, "licence")
        sourceURL = try Self.required(String.self, c, .sourceURL, "source_url")
        conversion = try Self.required(String.self, c, .conversion, "conversion")
        headwords = try Self.required(Int.self, c, .headwords, "headwords")
        format = try Self.required(String.self, c, .format, "format")
    }

    private static func required<T: Decodable>(
        _ type: T.Type,
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys,
        _ field: String
    ) throws -> T {
        do {
            return try container.decode(T.self, forKey: key)
        } catch DecodingError.keyNotFound(_, _) {
            throw PackManifestError.missingField(field)
        } catch DecodingError.valueNotFound(_, _) {
            throw PackManifestError.missingField(field)
        }
    }
}

public struct PackLicence: Codable, Sendable, Equatable {
    public var name: String
    public var textURL: String
    public var attribution: String

    public init(name: String, textURL: String, attribution: String) {
        self.name = name
        self.textURL = textURL
        self.attribution = attribution
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case textURL = "text_url"
        case attribution
    }
}

public enum PackManifestError: Error, Sendable, Equatable {
    case missingField(String)
}

extension PackManifestError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingField(let field):
            return "Pack manifest is missing required field '\(field)'."
        }
    }
}

// MARK: - Allowlist and version gate

/// The installer allowlist. Exactly one kind is installable.
/// Source of truth: read-later-research/spec/dictionary-packs.md §5.
/// Note: §5 also names `model.llm.small` as a reserved future kind. It is
/// reserved, not installable: this allowlist holds only what a surface may
/// offer today, which is the one dictionary pack (F12).
public enum PackAllowlist {
    public static let installableKinds: Set<String> = [
        "dictionary.en-zh-HK.lexical"
    ]

    public static func check(
        _ manifest: PackManifest,
        appVersion: String
    ) -> PackGate {
        guard installableKinds.contains(manifest.kind) else {
            return .refused(reason: "unsupported pack kind '\(manifest.kind)'")
        }
        if VersionCompare.compare(appVersion, manifest.minAppVersion) == .orderedAscending {
            return .refused(
                reason: "pack requires app version \(manifest.minAppVersion) (this app \(appVersion))"
            )
        }
        return .allowed
    }
}

public enum PackGate: Sendable, Equatable {
    case allowed
    case refused(reason: String)
}

/// Numeric comparison for `YYYY-MM-DD.N` and semver-ish strings.
/// Splits on every non-digit run and compares the integer components,
/// zero-filling the shorter side.
public enum VersionCompare {
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = components(of: lhs)
        let b = components(of: rhs)
        let count = max(a.count, b.count)
        for i in 0 ..< count {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }

    static func components(of version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}

/// Update detection: the registry version is newer than the installed one.
/// Numeric, so `2026-11-10.10` beats `2026-11-10.2`.
public enum PackUpdate {
    public static func isUpdateAvailable(installed: String, remote: String) -> Bool {
        VersionCompare.compare(remote, installed) == .orderedDescending
    }
}
