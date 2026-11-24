import Foundation
import Darwin
import CryptoKit

/// Filesystem identity catches atomic replacement and writes which preserve the
/// mtime/length. Explicit verification also assigns a new preview generation,
/// so externally rewritten media cannot reuse an old same-path bitmap.
public enum LocalFileRevision {
    public static func stamp(at url: URL) -> String? {
        guard url.isFileURL else { return nil }
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let value = "\(info.st_dev)|\(info.st_ino)|\(info.st_size)|\(info.st_mtimespec.tv_sec)|\(info.st_mtimespec.tv_nsec)|\(info.st_ctimespec.tv_sec)|\(info.st_ctimespec.tv_nsec)|\(info.st_birthtimespec.tv_sec)|\(info.st_birthtimespec.tv_nsec)"
        let hex = Array("0123456789abcdef".utf8)
        var encoded: [UInt8] = []; encoded.reserveCapacity(64)
        for byte in SHA256.hash(data: Data(value.utf8)) { encoded.append(hex[Int(byte >> 4)]); encoded.append(hex[Int(byte & 15)]) }
        return String(decoding: encoded, as: UTF8.self)
    }
}
