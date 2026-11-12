import CGzip
import Foundation

/// Thin Swift wrapper over the zlib streaming calls. The app never shells
/// out to gunzip; the index builder and the tests both go through here.
public enum GzipError: Error, Sendable, Equatable {
    case failed(String)
}

public enum Gzip {
    public static func gunzip(archive: URL, to destination: URL) throws {
        var err = [CChar](repeating: 0, count: 256)
        let code = archive.path.withCString { src in
            destination.path.withCString { dst in
                err.withUnsafeMutableBufferPointer { buf in
                    pack_gunzip(src, dst, buf.baseAddress, buf.count)
                }
            }
        }
        guard code == 0 else {
            throw GzipError.failed(String(cString: err))
        }
    }

    public static func gzip(file: URL, to destination: URL) throws {
        var err = [CChar](repeating: 0, count: 256)
        let code = file.path.withCString { src in
            destination.path.withCString { dst in
                err.withUnsafeMutableBufferPointer { buf in
                    pack_gzip(src, dst, buf.baseAddress, buf.count)
                }
            }
        }
        guard code == 0 else {
            throw GzipError.failed(String(cString: err))
        }
    }
}
