import Foundation

/// Production transport for the pack installer. Streams the archive to a file
/// with `URLSession.bytes`, so a 15 MB pack never sits in memory, and resumes
/// from a partial file with a Range request. Tests inject their own
/// `PackInstaller.DownloadFile`; the app passes these two functions.
public enum PackDownloader {
    /// Fetches a small response (the manifest) into memory. 404/410 is a
    /// broken deploy (`registry`); anything else transport-shaped is `network`.
    public static func fetch(url: URL, session: URLSession = .shared) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw PackDownloadError.network(reason: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PackDownloadError.network(reason: "no HTTP response")
        }
        switch http.statusCode {
        case 200 ... 299:
            return data
        case 404, 410:
            throw PackDownloadError.registry(status: http.statusCode)
        default:
            throw PackDownloadError.network(reason: "HTTP \(http.statusCode)")
        }
    }

    /// Streams `url` to `destination`. When `resumeOffset` is greater than
    /// zero the kept prefix stays and the request carries
    /// `Range: bytes=<offset>-`; a 200 answer means the server ignored the
    /// range and the file is restarted from zero. Reports (received, total)
    /// per chunk; the total comes from `Content-Range` when the server sends
    /// one. Cancellation keeps the partial file for a later resume.
    public static func download(
        url: URL,
        destination: URL,
        resumeOffset: Int,
        progress: PackInstaller.Progress,
        session: URLSession = .shared
    ) async throws {
        var request = URLRequest(url: url)
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw PackDownloadError.network(reason: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PackDownloadError.network(reason: "no HTTP response")
        }
        let appending: Bool
        switch http.statusCode {
        case 206:
            appending = true
        case 200:
            appending = false
        case 404, 410:
            throw PackDownloadError.registry(status: http.statusCode)
        default:
            throw PackDownloadError.network(reason: "HTTP \(http.statusCode)")
        }
        if !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: destination)
        } catch {
            throw PackDownloadError.disk
        }
        defer { try? handle.close() }
        do {
            if appending {
                try handle.seekToEnd()
            } else {
                try handle.truncate(atOffset: 0)
            }
        } catch {
            throw PackDownloadError.disk
        }
        var received = appending ? resumeOffset : 0
        let total = expectedTotal(from: http, resumeOffset: resumeOffset, appending: appending)
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                if buffer.count >= 1 << 16 {
                    try write(buffer, to: handle)
                    received += buffer.count
                    buffer.removeAll(keepingCapacity: true)
                    progress(received, total)
                }
            }
            if !buffer.isEmpty {
                try write(buffer, to: handle)
                received += buffer.count
                buffer.removeAll(keepingCapacity: true)
            }
            progress(received, total)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PackDownloadError {
            throw error
        } catch {
            throw PackDownloadError.network(reason: error.localizedDescription)
        }
    }

    /// Free bytes on the volume holding `url`, or nil when it cannot be read.
    /// Nil means "unknown", and the install proceeds; only a known shortage
    /// stops it.
    public static func freeSpace(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfFileSystem(forPath: url.path)[.systemFreeSize] as? NSNumber)?
            .int64Value
    }

    private static func write(_ data: Data, to handle: FileHandle) throws {
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw PackDownloadError.disk
        }
    }

    static func expectedTotal(from http: HTTPURLResponse, resumeOffset: Int, appending: Bool) -> Int {
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = range.lastIndex(of: "/"),
           let total = Int(range[range.index(after: slash)...])
        {
            return total
        }
        if let lengthString = http.value(forHTTPHeaderField: "Content-Length"),
           let length = Int(lengthString)
        {
            return length + (appending ? resumeOffset : 0)
        }
        return max(resumeOffset, 1)
    }
}
