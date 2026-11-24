import AVFoundation
import CoreGraphics
import FilmboxCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

func scannerRecursesDeduplicatesAndIgnoresHiddenPackagesAndSymlinks() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let nested = root.appendingPathComponent("夏天/海边", isDirectory: true)
    let hidden = root.appendingPathComponent(".hidden", isDirectory: true)
    let package = root.appendingPathComponent("Hidden.app/Contents", isDirectory: true)
    for folder in [nested, hidden, package] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    try writeImage(at: root.appendingPathComponent("one.jpg"))
    try writeImage(at: nested.appendingPathComponent("two.jpg"))
    try writeImage(at: hidden.appendingPathComponent("hidden.jpg"))
    try writeImage(at: root.appendingPathComponent(".hidden.jpg"))
    try writeImage(at: package.appendingPathComponent("icon.jpg"))
    try Data("not media".utf8).write(to: root.appendingPathComponent("note.txt"))
    try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("cycle"), withDestinationURL: root)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("duplicate.jpg"), withDestinationURL: root.appendingPathComponent("one.jpg"))
    let missing = MediaLibrary(url: root.appendingPathComponent("disconnected"))
    let result = await MediaScanner().scan(libraries: [MediaLibrary(url: nested), MediaLibrary(url: root), missing])
    try expect(Set(result.items.map(\.name)) == ["one.jpg", "two.jpg"])
    try expect(result.items.allSatisfy { $0.kind == .image && $0.fileSize > 0 })
    try expect(Set(result.items.map(\.id)).count == 2)
    try expect(result.unavailableLibraryIDs == [missing.id])
    try expect(result.warnings.count == 1)
    try expect(result.folders.contains { $0.url.path == nested.path && $0.parentPath == nested.deletingLastPathComponent().path })
    try expect(!result.folders.contains { $0.name == "cycle" || $0.name == ".hidden" || $0.name == "Hidden.app" })
}

func scannerReadsOriginalExifDateCameraAndOrientedDimensions() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let photo = root.appendingPathComponent("capture.jpg")
    try writeImage(at: photo, properties: [
        kCGImagePropertyOrientation as String: 6,
        kCGImagePropertyTIFFDictionary as String: [
            kCGImagePropertyTIFFMake as String: "Canon",
            kCGImagePropertyTIFFModel as String: "Canon EOS R5"
        ],
        kCGImagePropertyExifDictionary as String: [
            kCGImagePropertyExifDateTimeOriginal as String: "2021:01:02 03:04:05",
            "OffsetTimeOriginal": "+08:00",
            kCGImagePropertyExifLensModel as String: "RF35mm F1.8 MACRO IS STM",
            kCGImagePropertyExifFNumber as String: 1.8,
            kCGImagePropertyExifFocalLength as String: 35,
            kCGImagePropertyExifISOSpeedRatings as String: [400],
            kCGImagePropertyExifExposureTime as String: 0.008
        ]
    ])
    let result = await MediaScanner().scan(libraries: [MediaLibrary(url: root)])
    let item = try require(result.items.first)
    try expect(item.pixelWidth == 20)
    try expect(item.pixelHeight == 40)
    try expect(item.camera == "Canon EOS R5")
    try expect(item.lens == "RF35mm F1.8 MACRO IS STM")
    try expect(item.aperture == 1.8)
    try expect(item.focalLength == 35)
    try expect(item.iso == 400)
    try expect(item.exposure == "1/125 s")
    try expect(item.capturedDate == ISO8601DateFormatter().date(from: "2021-01-01T19:04:05Z"))
    try expect(item.displayDate == item.capturedDate)
}

func scannerUsesFilesystemDatesWhenImageHasNoExif() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeImage(at: root.appendingPathComponent("plain.jpg"))
    let result = await MediaScanner().scan(libraries: [MediaLibrary(url: root)])
    let item = try require(result.items.first)
    try expect(item.capturedDate == nil)
    try expect(item.displayDate == item.createdDate)
    try expect(item.pixelWidth == 40 && item.pixelHeight == 20)
}

func scannerReadsVideoDimensionsAndDuration() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try await writeVideo(at: root.appendingPathComponent("clip.mov"))
    let result = await MediaScanner().scan(libraries: [MediaLibrary(url: root)])
    let item = try require(result.items.first)
    try expect(item.kind == .video)
    try expect(item.pixelWidth == 64 && item.pixelHeight == 48)
    try expect((item.duration ?? 0) > 0)
}

func scannerCachesUnchangedRevisionsAndInvalidatesChangedOrDeletedFiles() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let photo = root.appendingPathComponent("cached.jpg")
    try writeImage(at: photo, properties: [
        kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFModel as String: "Fixture Camera A"]
    ])
    // Whole-second timestamps survive FileManager's attribute round trip exactly.
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)], ofItemAtPath: photo.path)
    let library = MediaLibrary(url: root)
    let scanner = MediaScanner()
    let initial = await scanner.scan(libraries: [library])
    let first = try require(initial.items.first)
    try expect(first.camera == "Fixture Camera A")

    // Change embedded metadata while deliberately preserving mtime and byte length.
    // Change-time/file identity must invalidate a replacement even when mtime and size match.
    let bytes = try Data(contentsOf: photo)
    let range = try require(bytes.range(of: Data("Fixture Camera A".utf8)))
    let handle = try FileHandle(forWritingTo: photo)
    try handle.seek(toOffset: UInt64(range.lowerBound))
    try handle.write(contentsOf: Data("Fixture Camera B".utf8))
    try handle.close()
    try FileManager.default.setAttributes([.modificationDate: first.modifiedDate], ofItemAtPath: photo.path)
    let cached = await scanner.scan(libraries: [library])
    try expect(cached.items.first?.camera == "Fixture Camera B")
    let fresh = await MediaScanner().scan(libraries: [library])
    try expect(fresh.items.first?.camera == "Fixture Camera B")

    try FileManager.default.setAttributes([.modificationDate: first.modifiedDate.addingTimeInterval(2)], ofItemAtPath: photo.path)
    let changed = await scanner.scan(libraries: [library])
    try expect(changed.items.first?.camera == "Fixture Camera B")
    try FileManager.default.removeItem(at: photo)
    let deleted = await scanner.scan(libraries: [library])
    try expect(deleted.items.isEmpty)
}

func scannerRestoresPersistedImageMetadataAndChecksAllRevisionFields() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let media = root.appendingPathComponent("Media", isDirectory: true)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    let photo = media.appendingPathComponent("restart.jpg")
    try writeImage(at: photo, properties: [
        kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFModel as String: "Persisted Camera A"]
    ])
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)], ofItemAtPath: photo.path)
    let library = MediaLibrary(url: media)
    let initial = await MediaScanner().scan(libraries: [library])
    let original = try require(initial.items.first)
    let persistence = CatalogPersistence(directory: root.appendingPathComponent("Catalog"))
    try persistence.save(CatalogState(libraries: [library], cachedItems: initial.items))
    let saved = try persistence.load()

    // Alter only embedded metadata, retaining the exact revision the catalog stores.
    // A persisted filesystem stamp must notice changed bytes even after restart.
    try replaceFixtureBytes(at: photo, old: "Persisted Camera A", new: "Persisted Camera B", modifiedDate: original.modifiedDate)
    let reopened = MediaScanner()
    await reopened.seed(cachedItems: saved.cachedItems)
    let reused = await reopened.scan(libraries: saved.libraries)
    try expect(reused.items.first?.camera == "Persisted Camera B")
    let uncached = await MediaScanner().scan(libraries: saved.libraries)
    try expect(uncached.items.first?.camera == "Persisted Camera B")

    // A later seed cannot overwrite newer metadata that this actor has validated.
    try FileManager.default.setAttributes([.modificationDate: original.modifiedDate.addingTimeInterval(2)], ofItemAtPath: photo.path)
    let changed = await reopened.scan(libraries: saved.libraries)
    try expect(changed.items.first?.camera == "Persisted Camera B")
    await reopened.seed(cachedItems: saved.cachedItems)
    let afterReseed = await reopened.scan(libraries: saved.libraries)
    try expect(afterReseed.items.first?.camera == "Persisted Camera B")

    // Matching mtime and size are insufficient when creation time changes.
    try FileManager.default.setAttributes([
        .modificationDate: original.modifiedDate,
        .creationDate: original.createdDate.addingTimeInterval(-60)
    ], ofItemAtPath: photo.path)
    let changedBirth = MediaScanner()
    await changedBirth.seed(cachedItems: saved.cachedItems)
    let birthResult = await changedBirth.scan(libraries: saved.libraries)
    try expect(birthResult.items.first?.camera == "Persisted Camera B")

    // A size change must invalidate even if the timestamps were deliberately restored.
    let append = try FileHandle(forWritingTo: photo)
    try append.seekToEnd()
    try append.write(contentsOf: Data([0]))
    try append.close()
    try FileManager.default.setAttributes([.modificationDate: original.modifiedDate, .creationDate: original.createdDate], ofItemAtPath: photo.path)
    let changedSize = MediaScanner()
    await changedSize.seed(cachedItems: saved.cachedItems)
    let resized = await changedSize.scan(libraries: saved.libraries)
    try expect(resized.items.first?.camera == "Persisted Camera B")
    try expect(resized.items.first?.fileSize == original.fileSize + 1)
    try FileManager.default.removeItem(at: photo)
    let removedResult = await changedSize.scan(libraries: saved.libraries)
    try expect(removedResult.items.isEmpty)
}

func scannerRestoresPersistedVideoMetadataWithoutReopeningAsset() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let media = root.appendingPathComponent("Media", isDirectory: true)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    let video = media.appendingPathComponent("restart.mov")
    let firstDate = "2021-01-02T03:04:05+0000"
    let nextDate = "2022-01-02T03:04:05+0000"
    try await writeVideo(at: video, creationDate: firstDate)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)], ofItemAtPath: video.path)
    let library = MediaLibrary(url: media)
    let scanned = await MediaScanner().scan(libraries: [library])
    let original = try require(scanned.items.first)
    try expect(original.capturedDate != nil && original.duration != nil && original.pixelWidth == 64)
    let persistence = CatalogPersistence(directory: root.appendingPathComponent("Catalog"))
    try persistence.save(CatalogState(libraries: [library], cachedItems: scanned.items))
    let saved = try persistence.load()
    try replaceFixtureBytes(at: video, old: firstDate, new: nextDate, modifiedDate: original.modifiedDate)
    let reopened = MediaScanner()
    await reopened.seed(cachedItems: saved.cachedItems)
    let reused = await reopened.scan(libraries: saved.libraries)
    try expect(reused.items.first?.capturedDate != original.capturedDate)
    let uncached = await MediaScanner().scan(libraries: saved.libraries)
    try expect(uncached.items.first?.capturedDate != original.capturedDate)
    try FileManager.default.setAttributes([.modificationDate: original.modifiedDate.addingTimeInterval(2)], ofItemAtPath: video.path)
    let changed = await reopened.scan(libraries: saved.libraries)
    try expect(changed.items.first?.capturedDate == uncached.items.first?.capturedDate)
    try expect(changed.items.first?.duration == original.duration)
}

private func replaceFixtureBytes(at url: URL, old: String, new: String, modifiedDate: Date) throws {
    try expect(old.utf8.count == new.utf8.count)
    let range = try require(Data(contentsOf: url).range(of: Data(old.utf8)))
    let handle = try FileHandle(forWritingTo: url)
    try handle.seek(toOffset: UInt64(range.lowerBound))
    try handle.write(contentsOf: Data(new.utf8))
    try handle.close()
    try FileManager.default.setAttributes([.modificationDate: modifiedDate], ofItemAtPath: url.path)
}

private func writeImage(at url: URL, properties: [String: Any] = [:]) throws {
    let context = try require(CGContext(
        data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
    let image = try require(context.makeImage())
    let destination = try require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    try expect(CGImageDestinationFinalize(destination))
}

private func writeVideo(at url: URL, creationDate: String? = nil) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    if let creationDate {
        let metadata = AVMutableMetadataItem()
        metadata.identifier = .quickTimeMetadataCreationDate
        metadata.value = creationDate as NSString
        writer.metadata = [metadata]
    }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 64,
        AVVideoHeightKey: 48
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 64,
        kCVPixelBufferHeightKey as String: 48
    ])
    writer.add(input)
    try expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var pixelBuffer: CVPixelBuffer?
    try expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32ARGB, nil, &pixelBuffer) == kCVReturnSuccess)
    let buffer = try require(pixelBuffer)
    CVPixelBufferLockBaseAddress(buffer, [])
    memset(CVPixelBufferGetBaseAddress(buffer), 100, CVPixelBufferGetDataSize(buffer))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    try expect(adaptor.append(buffer, withPresentationTime: .zero))
    try expect(adaptor.append(buffer, withPresentationTime: CMTime(value: 1, timescale: 30)))
    input.markAsFinished()
    await writer.finishWriting()
    try expect(writer.status == .completed)
}
