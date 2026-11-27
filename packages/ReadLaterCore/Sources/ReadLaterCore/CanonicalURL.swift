import Foundation

/// Canonical URL for library identity.
/// Source of truth: research repo `spec/library-identity.md` §2.
/// Canonical = final URL after redirects, host lowercased, default port
/// dropped, fragment dropped, known tracking params removed, remaining
/// query sorted.
public enum CanonicalURL {
    /// Normalizes one URL string. Returns the input unchanged when it does
    /// not parse as an absolute URL with a host.
    public static func canonicalize(_ raw: String) -> String {
        guard var parts = URLComponents(string: raw),
            let scheme = parts.scheme, !scheme.isEmpty,
            let host = parts.host, !host.isEmpty
        else { return raw }
        parts.scheme = scheme.lowercased()
        parts.host = host.lowercased()
        if (parts.scheme == "http" && parts.port == 80)
            || (parts.scheme == "https" && parts.port == 443)
        {
            parts.port = nil
        }
        parts.fragment = nil
        // Filter and sort the raw pairs, not `queryItems`: rebuilding from
        // decoded items re-encodes `%2B` as `+`, and a server that reads
        // `+` as a space then fetches a different resource. Decode only
        // for the tracking-name check and the sort key; the output keeps
        // the original encoding, normalized so `%2b` and `%2B` (and `%7E`
        // vs `~`) share one identity.
        if let rawQuery = parts.percentEncodedQuery {
            let pairs = rawQuery.split(separator: "&", omittingEmptySubsequences: false).compactMap { part -> (name: String, value: String, raw: String)? in
                guard !part.isEmpty else { return nil }
                let piece = String(part)
                if let eq = piece.firstIndex(of: "=") {
                    let nameRaw = String(piece[..<eq])
                    let valueRaw = String(piece[piece.index(after: eq)...])
                    let name = nameRaw.removingPercentEncoding ?? nameRaw
                    let value = valueRaw.removingPercentEncoding ?? valueRaw
                    return (name, value, normalizeEncoding(piece))
                }
                let name = piece.removingPercentEncoding ?? piece
                return (name, "", normalizeEncoding(piece))
            }
            let kept = pairs.filter {
                !isTrackingParam($0.name) && !($0.name.isEmpty && $0.value.isEmpty)
            }
            .sorted {
                if $0.name != $1.name { return $0.name < $1.name }
                return $0.value < $1.value
            }
            parts.percentEncodedQuery = kept.isEmpty ? nil : kept.map(\.raw).joined(separator: "&")
        }
        return parts.string ?? raw
    }

    /// Uppercases `%XX` hex and decodes unreserved marks (`%7E` to `~`,
    /// per RFC 3986 §2.3), so encoding case alone never splits an entry.
    /// Reserved escapes (`%2B`, `%26`, `%3D`) stay encoded. Shared with the
    /// refetch comparator so both agree on what counts as the same link.
    public static func normalizeEncoding(_ pair: String) -> String {
        var out = ""
        out.reserveCapacity(pair.count)
        let chars = Array(pair)
        var i = 0
        while i < chars.count {
            if chars[i] == "%", i + 2 < chars.count,
               let byte = UInt8(String(chars[i + 1...i + 2]), radix: 16) {
                let scalar = Unicode.Scalar(byte)
                if scalar == "-" || scalar == "." || scalar == "_" || scalar == "~"
                    || (scalar.value >= 48 && scalar.value <= 57)
                    || (scalar.value >= 65 && scalar.value <= 90)
                    || (scalar.value >= 97 && scalar.value <= 122) {
                    out.append(Character(scalar))
                } else {
                    out.append("%" + String(chars[i + 1...i + 2]).uppercased())
                }
                i += 3
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// Normalizes one URL value.
    public static func canonicalize(_ url: URL) -> URL {
        URL(string: canonicalize(url.absoluteString)) ?? url
    }

    private static func isTrackingParam(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.hasPrefix("utm_") { return true }
        switch n {
        case "fbclid", "gclid", "igshid", "source", "ref":
            return true
        default:
            return false
        }
    }
}
