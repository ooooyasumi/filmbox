import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

public actor MediaScanner {
    private var revisionCache: [String: MediaItem] = [:]
    private var compatibilityAttempts: Set<String> = []

    public init() {}

    /// Supplies the previous catalog without opening media files. Scanning still
    /// checks every candidate's filesystem revision before reusing its metadata.
    /// Never replace a record that this scanner has already verified or refreshed.
    public func seed(cachedItems: [MediaItem]) {
        for item in cachedItems {
            guard item.url.isFileURL, item.id == item.url.standardizedFileURL.path,
                  item.fileSize >= 0,
                  item.modifiedDate.timeIntervalSinceReferenceDate.isFinite,
                  item.createdDate.timeIntervalSinceReferenceDate.isFinite,
                  revisionCache[item.id] == nil else { continue }
            revisionCache[item.id] = item
        }
    }

    public func scan(libraries: [MediaLibrary], verifyContents: Bool = false, ignoreDotFiles: Bool = true) async -> ScanResult {
        let verification = UUID().uuidString
        var resolvedURLs: [UUID: URL] = [:]
        var bookmarks: [UUID: Data] = [:]
        var unverifiedPaths = Set<String>()
        var checkedRoots: [String] = []
        var visitedFiles = 0
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
            .isHiddenKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
            .contentTypeKey
        ]
        var items: [String: MediaItem] = [:]
        var nextCache: [String: MediaItem] = [:]
        var completedCompatibilityAttempts = Set<String>()
        var folderURLs: [String: URL] = [:]
        var visitedDirectories = Set<String>()
        var unavailable = Set<UUID>()
        var warnings: [String] = []

        for library in libraries {
            if Task.isCancelled { break }
            let resolved: URL
            do {
                resolved = try library.resolvedURL()
            } catch {
                unavailable.insert(library.id)
                warnings.append("\(library.name)：\(error.localizedDescription)")
                continue
            }
            let accessed = resolved.startAccessingSecurityScopedResource()
            defer { if accessed { resolved.stopAccessingSecurityScopedResource() } }
            let root = resolved.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  manager.isReadableFile(atPath: root.path) else {
                unavailable.insert(library.id)
                warnings.append("\(library.name)：文件夹不可用，请检查磁盘连接或访问权限。")
                continue
            }
            resolvedURLs[library.id] = root
            if let refreshed = library.refreshedBookmark(for: root) { bookmarks[library.id] = refreshed }
            checkedRoots.append(root.path)
            folderURLs[root.path] = root
            // Nested roots remain valid libraries but need only one traversal.
            guard visitedDirectories.insert(root.path).inserted else { continue }
            let diagnostics = EnumerationDiagnostics()
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants],
                errorHandler: { url, error in
                    diagnostics.append("\(url.lastPathComponent)：\(error.localizedDescription)", path: url.standardizedFileURL.path)
                    return true
                }
            ) else {
                unavailable.insert(library.id)
                warnings.append("\(library.name)：无法读取文件夹内容。")
                continue
            }

            while let entry = enumerator.nextObject() as? URL {
                if Task.isCancelled { break }
                do {
                    let values = try entry.resourceValues(forKeys: keys)
                    let dotName = entry.lastPathComponent.hasPrefix(".")
                    if (ignoreDotFiles && dotName) || (values.isHidden == true && !dotName) { enumerator.skipDescendants(); continue }
                    if values.isSymbolicLink == true {
                        // A shortcut can point outside the chosen library or form a cycle.
                        // Treat selected root symlinks above; never follow descendant links.
                        enumerator.skipDescendants()
                        continue
                    }
                    let url = entry.standardizedFileURL
                    if values.isDirectory == true {
                        if values.isPackage == true { enumerator.skipDescendants(); continue }
                        folderURLs[url.path] = url
                        if !visitedDirectories.insert(url.path).inserted { enumerator.skipDescendants() }
                        continue
                    }
                    guard values.isRegularFile == true,
                          items[url.path] == nil,
                          let kind = Self.mediaKind(for: url, contentType: values.contentType) else { continue }
                    let modified = values.contentModificationDate ?? values.creationDate ?? .distantPast
                    let created = values.creationDate ?? modified
                    let size = Int64(values.fileSize ?? 0)
                    let fileStamp = LocalFileRevision.stamp(at: url)
                    let freshRevision = (fileStamp ?? "unreadable") + "|" + verification
                    var compatibilityRepairKey: String?
                    if !verifyContents, let cached = revisionCache[url.path], cached.kind == kind,
                       cached.modifiedDate == modified, cached.createdDate == created, cached.fileSize == size,
                       (cached.localRevision == nil && fileStamp != nil) || fileStamp.map({ cached.localRevision?.hasPrefix($0 + "|") == true }) == true {
                        let missingVideoMetadata = kind == .video && (cached.pixelWidth == nil || cached.pixelHeight == nil || cached.duration == nil)
                        let repairKey = "\(url.path)|\(modified.timeIntervalSinceReferenceDate)|\(size)"
                        if !missingVideoMetadata || !MediaCodecRuntime.isAvailable || compatibilityAttempts.contains(repairKey) {
                            let reused = cached.localRevision == nil ? cached.withLocalRevision(fileStamp.map { $0 + "|adopted" }) : cached
                            items[url.path] = reused
                            nextCache[url.path] = reused
                            continue
                        }
                        compatibilityRepairKey = repairKey
                    }
                    let metadata = kind == .image ? autoreleasepool { Self.imageMetadata(at: url) } : await Self.videoMetadata(at: url)
                    guard !Task.isCancelled else { break }
                    if let compatibilityRepairKey { completedCompatibilityAttempts.insert(compatibilityRepairKey) }
                    let item = MediaItem(
                        url: url, kind: kind, fileSize: size,
                        modifiedDate: modified, createdDate: created,
                        capturedDate: metadata.capturedDate,
                        pixelWidth: metadata.width, pixelHeight: metadata.height,
                        camera: metadata.camera, lens: metadata.lens,
                        aperture: metadata.aperture, focalLength: metadata.focalLength,
                        iso: metadata.iso, exposure: metadata.exposure, duration: metadata.duration, localRevision: freshRevision
                    )
                    items[url.path] = item
                    // Cache unsuccessful metadata reads too: an unchanged damaged file
                    // should not repeat ImageIO/AVFoundation work on every refresh.
                    nextCache[url.path] = item
                    visitedFiles += 1
                    if visitedFiles.isMultiple(of: 128) { await Task.yield() }
                } catch {
                    warnings.append("\(entry.lastPathComponent)：\(error.localizedDescription)")
                    if manager.fileExists(atPath: entry.path) { unverifiedPaths.insert(entry.standardizedFileURL.path) }
                }
            }
            unverifiedPaths.formUnion(diagnostics.paths)
            warnings.append(contentsOf: diagnostics.messages)
        }

        let folders: [MediaFolder] = folderURLs.values.map { url -> MediaFolder in
            let parent = url.deletingLastPathComponent().path
            return MediaFolder(url: url, parentPath: folderURLs[parent] == nil ? nil : parent)
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        if !Task.isCancelled {
            // A scoped refresh must keep verified metadata of other libraries.
            revisionCache = revisionCache.filter { id, _ in !checkedRoots.contains { DirectorySelection.isWithin(id, directory: $0) } }
            revisionCache.merge(nextCache, uniquingKeysWith: { _, latest in latest })
            // A cancelled refresh must not consume an old nil record's only
            // compatibility retry. Commit attempts with the matching catalog.
            compatibilityAttempts.formUnion(completedCompatibilityAttempts)
        }
        return ScanResult(
            items: items.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending },
            folders: folders,
            unavailableLibraryIDs: unavailable,
            warnings: warnings, resolvedLibraryURLs: resolvedURLs, refreshedBookmarks: bookmarks, unverifiedPaths: unverifiedPaths
        )
    }

    private static func mediaKind(for url: URL, contentType: UTType?) -> MediaKind? {
        // Some installed UTIs describe Matroska/WebM as generic data.
        if ["webm", "mkv", "avi", "wmv", "flv", "mts", "m2ts", "vob", "mpeg", "mpg"].contains(url.pathExtension.lowercased()) { return .video }
        guard let type = contentType ?? UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        return nil
    }

    private static func imageMetadata(at url: URL) -> MediaMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return MediaMetadata() }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let dateText = Self.string(exif[kCGImagePropertyExifDateTimeOriginal as String])
            ?? Self.string(exif[kCGImagePropertyExifDateTimeDigitized as String])
            ?? Self.string(tiff[kCGImagePropertyTIFFDateTime as String])
        let offset = Self.string(exif["OffsetTimeOriginal"]) ?? Self.string(exif["OffsetTimeDigitized"])
        let capturedDate = dateText.flatMap { Self.exifDate($0, offset: offset) }
        let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue
        let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        let swapsDimensions = (5...8).contains(orientation)
        let make = Self.string(tiff[kCGImagePropertyTIFFMake as String])
        let model = Self.string(tiff[kCGImagePropertyTIFFModel as String])
        let camera: String? = {
            guard let model else { return make }
            guard let make, !model.localizedCaseInsensitiveContains(make) else { return model }
            return make + " " + model
        }()
        let seconds = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
        let exposure: String? = seconds.flatMap { value in
            guard value > 0 else { return nil }
            return value < 1 ? "1/\(Int((1 / value).rounded())) s" : "\(value.formatted(.number.precision(.fractionLength(0...3)))) s"
        }
        let isoValues = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber]
        return MediaMetadata(
            capturedDate: capturedDate,
            width: swapsDimensions ? height : width,
            height: swapsDimensions ? width : height,
            camera: camera,
            lens: Self.string(exif[kCGImagePropertyExifLensModel as String]),
            aperture: (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue,
            focalLength: (exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue,
            iso: isoValues?.first?.intValue,
            exposure: exposure
        )
    }

    private static func videoMetadata(at url: URL) async -> MediaMetadata {
        let asset = AVURLAsset(url: url)
        var metadata = MediaMetadata()
        if let creation = try? await asset.load(.creationDate) {
            metadata.capturedDate = try? await creation.load(.dateValue)
        }
        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds.isFinite {
            metadata.duration = max(0, duration.seconds)
        }
        if let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first,
           let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let transformed = size.applying(transform)
            metadata.width = Int(abs(transformed.width).rounded())
            metadata.height = Int(abs(transformed.height).rounded())
        }
        if metadata.width == nil || metadata.height == nil || metadata.duration == nil,
           let compatible = await MediaCodecRuntime.videoMetadata(at: url) {
            metadata.width = metadata.width ?? compatible.width
            metadata.height = metadata.height ?? compatible.height
            metadata.duration = metadata.duration ?? compatible.duration
            metadata.capturedDate = metadata.capturedDate ?? compatible.capturedDate
        }
        return metadata
    }

    private static func string(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func exifDate(_ value: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.isLenient = false
        if let offset {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
            if let date = formatter.date(from: value + offset) { return date }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: value)
    }
}

private struct MediaMetadata {
    var capturedDate: Date?
    var width: Int?
    var height: Int?
    var camera: String?
    var lens: String?
    var aperture: Double?
    var focalLength: Double?
    var iso: Int?
    var exposure: String?
    var duration: Double?
}

private final class EnumerationDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private var unreadable = Set<String>()

    func append(_ message: String, path: String) {
        lock.withLock { storage.append(message); unreadable.insert(path) }
    }
    var paths: Set<String> { lock.withLock { unreadable } }

    var messages: [String] { lock.withLock { storage } }
}
