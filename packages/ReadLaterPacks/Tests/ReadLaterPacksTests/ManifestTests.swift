import Foundation
import Testing

@testable import ReadLaterPacks

/// The real lexical manifest, pasted verbatim from
/// read-later-research/evidence/2026-11-10-pack-zh-hk/artifacts/dictionary.en-zh-HK.lexical.manifest.json
let realManifestJSON = """
{
  "id": "dictionary.en-zh-HK.lexical",
  "kind": "dictionary.en-zh-HK.lexical",
  "version": "2026-11-10.1",
  "size_bytes": 15171897,
  "sha256": "769256b3f33470a0271c8b3f74fe1e0eb7e9dd53ae58bc42292ca305168359a7",
  "min_app_version": "0.1.0",
  "languages": [
    "en",
    "zh-HK"
  ],
  "capabilities": [
    "gloss",
    "phonetic",
    "pos"
  ],
  "licence": {
    "name": "MIT",
    "text_url": "https://github.com/skywind3000/ECDICT/blob/master/LICENSE",
    "attribution": "Copyright (c) 2025 Linwei"
  },
  "source_url": "https://raw.githubusercontent.com/skywind3000/ECDICT/master/ecdict.csv",
  "conversion": "opencc s2hk-standard",
  "headwords": 770238,
  "format": "gzip-tsv"
}
"""

func manifestJSON(sha256: String, kind: String = "dictionary.en-zh-HK.lexical") -> String {
    """
    {
      "id": "dictionary.en-zh-HK.lexical",
      "kind": "\(kind)",
      "version": "2026-11-10.1",
      "size_bytes": 15171897,
      "sha256": "\(sha256)",
      "min_app_version": "0.1.0",
      "languages": ["en", "zh-HK"],
      "capabilities": ["gloss", "phonetic", "pos"],
      "licence": {
        "name": "MIT",
        "text_url": "https://github.com/skywind3000/ECDICT/blob/master/LICENSE",
        "attribution": "Copyright (c) 2025 Linwei"
      },
      "source_url": "https://example.com/pack.gz",
      "conversion": "opencc s2hk-standard",
      "headwords": 770238,
      "format": "gzip-tsv"
    }
    """
}

func decodeManifest(_ json: String) throws -> PackManifest {
    try JSONDecoder().decode(PackManifest.self, from: Data(json.utf8))
}

@Suite("PackManifest decoding")
struct ManifestTests {
    @Test("decodes the real manifest exactly")
    func decodesRealManifest() throws {
        let manifest = try decodeManifest(realManifestJSON)
        #expect(manifest.id == "dictionary.en-zh-HK.lexical")
        #expect(manifest.kind == "dictionary.en-zh-HK.lexical")
        #expect(manifest.version == "2026-11-10.1")
        #expect(manifest.sizeBytes == 15_171_897)
        #expect(manifest.sha256 == "769256b3f33470a0271c8b3f74fe1e0eb7e9dd53ae58bc42292ca305168359a7")
        #expect(manifest.minAppVersion == "0.1.0")
        #expect(manifest.languages == ["en", "zh-HK"])
        #expect(manifest.capabilities == ["gloss", "phonetic", "pos"])
        #expect(manifest.licence.name == "MIT")
        #expect(manifest.licence.textURL == "https://github.com/skywind3000/ECDICT/blob/master/LICENSE")
        #expect(manifest.licence.attribution == "Copyright (c) 2025 Linwei")
        #expect(manifest.sourceURL == "https://raw.githubusercontent.com/skywind3000/ECDICT/master/ecdict.csv")
        #expect(manifest.conversion == "opencc s2hk-standard")
        #expect(manifest.headwords == 770_238)
        #expect(manifest.format == "gzip-tsv")
    }

    @Test("unknown extra fields do not fail decoding")
    func unknownFieldsTolerated() throws {
        let json = realManifestJSON.replacingOccurrences(
            of: #""format": "gzip-tsv""#,
            with: #""format": "gzip-tsv", "future_field": {"nested": [1, 2]}, "another": 42"#
        )
        let manifest = try decodeManifest(json)
        #expect(manifest.format == "gzip-tsv")
    }

    @Test("missing field fails naming the field")
    func missingFieldNamesField() {
        let json = manifestJSON(sha256: "abc").replacingOccurrences(of: #""sha256": "abc","#, with: "")
        do {
            _ = try decodeManifest(json)
            Issue.record("expected missing-field error")
        } catch let error as PackManifestError {
            #expect(error == .missingField("sha256"))
            #expect(error.errorDescription?.contains("sha256") == true)
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("missing licence fails naming the field")
    func missingLicenceNamesField() {
        var json = realManifestJSON
        // Drop the whole licence object.
        json = json.replacingOccurrences(
            of: #""licence": {"#,
            with: #""licence_REMOVED": {"#
        )
        do {
            _ = try decodeManifest(json)
            Issue.record("expected missing-field error")
        } catch let error as PackManifestError {
            #expect(error == .missingField("licence"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }
}

@Suite("Pack allowlist and version gate")
struct AllowlistTests {
    @Test("the lexical pack is allowed")
    func lexicalAllowed() throws {
        let manifest = try decodeManifest(realManifestJSON)
        #expect(PackAllowlist.check(manifest, appVersion: "0.1.0") == .allowed)
    }

    @Test("any other kind is refused with a reason")
    func wrongKindRefused() throws {
        for kind in ["dictionary.en-zh-HK.gloss", "model.llm.small", "dictionary.en-zh-CN.lexical", ""] {
            let manifest = try decodeManifest(manifestJSON(sha256: "abc", kind: kind))
            let gate = PackAllowlist.check(manifest, appVersion: "99.0.0")
            guard case .refused(let reason) = gate else {
                Issue.record("kind '\(kind)' was not refused")
                continue
            }
            #expect(reason.contains("unsupported pack"))
            #expect(kind.isEmpty || reason.contains(kind))
        }
    }

    @Test("gloss-only pack from the old two-pack design is refused")
    func glossPackRefused() throws {
        let manifest = try decodeManifest(manifestJSON(sha256: "abc", kind: "dictionary.en-zh-HK.gloss"))
        #expect(PackAllowlist.check(manifest, appVersion: "99.0.0") != .allowed)
    }

    @Test("app below min_app_version is refused")
    func versionGate() throws {
        let manifest = try decodeManifest(realManifestJSON) // min_app_version 0.1.0
        let gate = PackAllowlist.check(manifest, appVersion: "0.0.9")
        guard case .refused(let reason) = gate else {
            Issue.record("old app was not refused")
            return
        }
        #expect(reason.contains("0.1.0"))
    }

    @Test("numeric version comparison handles YYYY-MM-DD.N and semver")
    func versionCompare() {
        #expect(VersionCompare.compare("2026-11-10.1", "2026-11-10.1") == .orderedSame)
        #expect(VersionCompare.compare("2026-11-10.2", "2026-11-10.1") == .orderedDescending)
        #expect(VersionCompare.compare("2026-11-10.1", "2026-11-11.1") == .orderedAscending)
        #expect(VersionCompare.compare("0.1.0", "0.1.0") == .orderedSame)
        #expect(VersionCompare.compare("0.0.9", "0.1.0") == .orderedAscending)
        #expect(VersionCompare.compare("0.2.0", "0.10.0") == .orderedAscending)
        #expect(VersionCompare.compare("1.0", "1.0.0") == .orderedSame)
    }
}
