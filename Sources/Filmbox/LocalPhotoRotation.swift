import Foundation
import Darwin
import ImageIO
import FilmboxCore
import UniformTypeIdentifiers

enum PhotoRotationDirection: Sendable { case left, right }

/// Saves EXIF/container orientation in the original file, without recompressing
/// its pixels. All filesystem and ImageIO work runs on the file-operation actor.
enum LocalPhotoRotation {
    private static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]
    static func supports(_ item: MediaItem) -> Bool {
        item.isLocal && item.kind == .image && extensions.contains(item.url.pathExtension.lowercased())
    }
    static func orientation(_ old: Int, turning direction: PhotoRotationDirection) -> Int {
        let clockwise = [1: 6, 2: 7, 3: 8, 4: 5, 5: 2, 6: 3, 7: 4, 8: 1]
        if direction == .right { return clockwise[old] ?? 6 }
        return clockwise.first(where: { $0.value == old })?.key ?? 8
    }
    static func rotate(_ item: MediaItem, direction: PhotoRotationDirection) throws -> MediaItem {
        guard supports(item) else { throw Failure("此文件暂不支持保存旋转；云端原件和 RAW 保持原样。") }
        let url = URL(fileURLWithPath: item.url.path)
        let initial = try revision(url, matching: item)
        guard FileManager.default.isWritableFile(atPath: url.path) else { throw Failure("文件为只读，无法保存旋转。") }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var outcome: Result<MediaItem, Error>?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinated in
            outcome = Result {
                _ = try revision(coordinated, matching: item, inode: initial)
                guard let source = CGImageSourceCreateWithURL(coordinated as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      CGImageSourceGetCount(source) == 1, let type = CGImageSourceGetType(source),
                      [UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier, UTType.heif.identifier, UTType.tiff.identifier].contains(type as String),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
                    throw Failure("此格式或多帧图片无法安全保存旋转，原文件未修改。")
                }
                let next = orientation(properties[kCGImagePropertyOrientation] as? Int ?? 1, turning: direction)
                let temporary = coordinated.deletingLastPathComponent().appendingPathComponent(".filmbox-rotate-\(UUID().uuidString).\(coordinated.pathExtension)")
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type, 1, nil) else { throw Failure("无法创建旋转文件。") }
                var copyError: Unmanaged<CFError>?
                guard CGImageDestinationCopyImageSource(destination, source, [kCGImageDestinationOrientation: next] as CFDictionary, &copyError) else {
                    _ = copyError?.takeRetainedValue()
                    throw Failure("此图片无法无损保存旋转，原文件未修改。")
                }
                guard let check = CGImageSourceCreateWithURL(temporary as CFURL, nil),
                      CGImageSourceGetCount(check) == 1,
                      let saved = CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [CFString: Any],
                      saved[kCGImagePropertyOrientation] as? Int == next,
                      saved[kCGImagePropertyPixelWidth] as? Int == width,
                      saved[kCGImagePropertyPixelHeight] as? Int == height else { throw Failure("旋转校验失败，原文件未修改。") }
                // ImageIO may recreate its destination, so copy filesystem
                // metadata only AFTER encoding, including Finder tags and ACLs.
                guard copyfile(coordinated.path, temporary.path, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: coordinated.path)
                let modifiedDate = max(Date(), item.modifiedDate.addingTimeInterval(1))
                var preserved: [FileAttributeKey: Any] = [.creationDate: item.createdDate, .modificationDate: modifiedDate]
                if let permissions = attributes[.posixPermissions] { preserved[.posixPermissions] = permissions }
                try FileManager.default.setAttributes(preserved, ofItemAtPath: temporary.path)
                try Task.checkCancellation()
                _ = try revision(coordinated, matching: item, inode: initial)
                _ = try FileManager.default.replaceItemAt(coordinated, withItemAt: temporary, options: .usingNewMetadataOnly)
                let values = try URL(fileURLWithPath: coordinated.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
                return MediaItem(id: item.id, url: item.url, kind: item.kind,
                    fileSize: Int64(values.fileSize ?? 0), modifiedDate: values.contentModificationDate ?? modifiedDate,
                    createdDate: values.creationDate ?? item.createdDate, capturedDate: item.capturedDate,
                    pixelWidth: next >= 5 ? height : width, pixelHeight: next >= 5 ? width : height,
                    camera: item.camera, lens: item.lens, aperture: item.aperture, focalLength: item.focalLength,
                    iso: item.iso, exposure: item.exposure, duration: item.duration)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw Failure("无法协调文件访问，请重试。") }
        return try outcome.get()
    }
    private static func revision(_ url: URL, matching item: MediaItem, inode: UInt64? = nil) throws -> UInt64 {
        let fresh = URL(fileURLWithPath: url.path)
        let values = try fresh.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: fresh.path)
        let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.contentModificationDate == item.modifiedDate, values.creationDate == item.createdDate,
              Int64(values.fileSize ?? 0) == item.fileSize, inode == nil || inode == number else {
            throw Failure("文件已变更或不是普通文件，请刷新后重试。")
        }
        return number
    }
    struct Failure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
}
