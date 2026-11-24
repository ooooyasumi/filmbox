import Foundation

public enum MediaKind: String, Codable, Hashable, Sendable, CaseIterable {
    case image
    case video
}

public struct MediaItem: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let url: URL
    public let kind: MediaKind
    public let fileSize: Int64
    public let modifiedDate: Date
    public let createdDate: Date
    public let capturedDate: Date?
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let camera: String?
    public let lens: String?
    public let aperture: Double?
    public let focalLength: Double?
    public let iso: Int?
    public let exposure: String?
    public let duration: Double?
    public let cloud: CloudMediaReference?
    /// Display ratio learned from a decoded preview, never original pixel dimensions.
    public let localRevision: String?
    public var contentRevision: String? { cloud?.revision ?? localRevision }
    public var localFileStamp: String? { localRevision.map { String($0.prefix(while: { $0 != "|" })) } }
    public let previewAspectRatio: Double?

    public var displayDate: Date { capturedDate ?? createdDate }
    public var name: String { cloud?.name ?? url.lastPathComponent }
    public var folderPath: String {
        cloud.map { CloudMediaPath.selectionPath(accountID: $0.accountID, path: $0.folderPath) }
            ?? url.deletingLastPathComponent().path
    }
    public var selectionPath: String { cloud?.selectionPath ?? url.path }
    public var displayPath: String { cloud?.remotePath ?? url.path }
    public var isLocal: Bool { cloud == nil && url.isFileURL }
    public var aspectRatio: Double? {
        if let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 {
            return Double(pixelWidth) / Double(pixelHeight)
        }
        return previewAspectRatio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    public init(
        id: String? = nil,
        url: URL,
        kind: MediaKind,
        fileSize: Int64,
        modifiedDate: Date,
        createdDate: Date,
        capturedDate: Date? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        camera: String? = nil,
        lens: String? = nil,
        aperture: Double? = nil,
        focalLength: Double? = nil,
        iso: Int? = nil,
        exposure: String? = nil,
        duration: Double? = nil,
        cloud: CloudMediaReference? = nil,
        previewAspectRatio: Double? = nil,
        localRevision: String? = nil
    ) {
        self.url = cloud?.locatorURL ?? (url.isFileURL ? url.standardizedFileURL : url)
        self.id = cloud?.stableID ?? id ?? (url.isFileURL ? url.standardizedFileURL.path : url.absoluteString)
        self.kind = kind
        self.fileSize = fileSize
        self.modifiedDate = modifiedDate
        self.createdDate = createdDate
        self.capturedDate = capturedDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.camera = camera
        self.lens = lens
        self.aperture = aperture
        self.focalLength = focalLength
        self.iso = iso
        self.exposure = exposure
        self.duration = duration
        self.cloud = cloud
        self.localRevision = cloud == nil ? localRevision : nil
        self.previewAspectRatio = previewAspectRatio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    public init(
        cloud: CloudMediaReference,
        kind: MediaKind,
        fileSize: Int64,
        modifiedDate: Date,
        createdDate: Date,
        capturedDate: Date? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        duration: Double? = nil,
        previewAspectRatio: Double? = nil
    ) {
        self.init(url: cloud.locatorURL, kind: kind, fileSize: fileSize,
                  modifiedDate: modifiedDate, createdDate: createdDate, capturedDate: capturedDate,
                  pixelWidth: pixelWidth, pixelHeight: pixelHeight, duration: duration, cloud: cloud,
                  previewAspectRatio: previewAspectRatio)
    }

    /// Keep the new listing's path, identity and revision. Only metadata read
    /// from the same unchanged original can survive a fresh directory listing.
    public func mergingMetadata(from old: MediaItem) -> MediaItem {
        guard id == old.id, kind == old.kind, fileSize == old.fileSize,
              modifiedDate == old.modifiedDate else { return self }
        if let cloud {
            guard let previous = old.cloud, cloud.accountID == previous.accountID,
                  cloud.fileID == previous.fileID, cloud.revision == previous.revision else { return self }
        } else if old.cloud != nil || localRevision != old.localRevision { return self }
        return MediaItem(id: id, url: url, kind: kind, fileSize: fileSize,
                         modifiedDate: modifiedDate, createdDate: createdDate,
                         capturedDate: capturedDate ?? old.capturedDate,
                         pixelWidth: pixelWidth ?? old.pixelWidth, pixelHeight: pixelHeight ?? old.pixelHeight,
                         camera: camera ?? old.camera, lens: lens ?? old.lens,
                         aperture: aperture ?? old.aperture, focalLength: focalLength ?? old.focalLength,
                         iso: iso ?? old.iso, exposure: exposure ?? old.exposure,
                         duration: duration ?? old.duration, cloud: cloud,
                         previewAspectRatio: previewAspectRatio ?? old.previewAspectRatio, localRevision: localRevision)
    }

    public func withPreviewAspectRatio(_ ratio: Double) -> MediaItem {
        guard ratio.isFinite, ratio > 0 else { return self }
        return MediaItem(id: id, url: url, kind: kind, fileSize: fileSize,
                         modifiedDate: modifiedDate, createdDate: createdDate, capturedDate: capturedDate,
                         pixelWidth: pixelWidth, pixelHeight: pixelHeight, camera: camera, lens: lens,
                         aperture: aperture, focalLength: focalLength, iso: iso, exposure: exposure,
                         duration: duration, cloud: cloud, previewAspectRatio: ratio, localRevision: localRevision)
    }

    public func withLocalRevision(_ revision: String?) -> MediaItem {
        MediaItem(id: id, url: url, kind: kind, fileSize: fileSize, modifiedDate: modifiedDate,
                  createdDate: createdDate, capturedDate: capturedDate, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                  camera: camera, lens: lens, aperture: aperture, focalLength: focalLength, iso: iso,
                  exposure: exposure, duration: duration, cloud: cloud, previewAspectRatio: previewAspectRatio, localRevision: revision)
    }

    public func belongs(to library: MediaLibrary) -> Bool {
        if let cloud, let libraryCloud = library.cloud {
            return cloud.accountID == libraryCloud.accountID
                && DirectorySelection.isWithin(selectionPath, directory: library.selectionPath)
        }
        guard isLocal, library.isLocal else { return false }
        return DirectorySelection.isWithin(selectionPath, directory: library.selectionPath)
    }

    public func relocated(to url: URL) -> MediaItem {
        guard isLocal else { return self }
        return MediaItem(url: url, kind: kind, fileSize: fileSize, modifiedDate: modifiedDate,
                  createdDate: createdDate, capturedDate: capturedDate,
                  pixelWidth: pixelWidth, pixelHeight: pixelHeight, camera: camera,
                  lens: lens, aperture: aperture, focalLength: focalLength,
                  iso: iso, exposure: exposure, duration: duration, previewAspectRatio: previewAspectRatio, localRevision: localRevision)
    }
}

/// A logical collection. Membership never copies, moves or duplicates a file.
public struct MediaAlbum: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var itemIDs: Set<String>
    public let createdDate: Date

    public init(id: UUID = UUID(), name: String, itemIDs: Set<String> = [], createdDate: Date = Date()) {
        self.id = id
        self.name = name
        self.itemIDs = itemIDs
        self.createdDate = createdDate
    }

    private enum CodingKeys: String, CodingKey { case id, name, itemIDs, createdDate }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        itemIDs = Set(try values.decodeIfPresent([String].self, forKey: .itemIDs) ?? [])
        createdDate = try values.decodeIfPresent(Date.self, forKey: .createdDate) ?? .distantPast
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(itemIDs.sorted(), forKey: .itemIDs)
        try values.encode(createdDate, forKey: .createdDate)
    }
}

public struct MediaLibrary: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var url: URL
    public var bookmark: Data?
    public var name: String
    public let cloud: CloudLibraryReference?
    public var isLocal: Bool { cloud == nil && url.isFileURL }
    public var selectionPath: String { cloud?.selectionPath ?? url.path }
    public var displayPath: String { cloud?.path ?? url.path }

    public init(id: UUID = UUID(), url: URL, bookmark: Data? = nil, name: String? = nil, cloud: CloudLibraryReference? = nil) {
        self.id = id
        self.url = cloud?.locatorURL ?? (url.isFileURL ? url.standardizedFileURL : url)
        self.bookmark = cloud == nil ? bookmark : nil
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? url.lastPathComponent.precomposedStringWithCanonicalMapping
        self.cloud = cloud
    }

    public init(id: UUID = UUID(), cloud: CloudLibraryReference, name: String? = nil) {
        self.init(id: id, url: cloud.locatorURL, name: name, cloud: cloud)
    }

    /// The caller owns the lifetime of security-scoped access to this URL.
    public func resolvedURL() throws -> URL {
        guard isLocal else { return url }
        let current = URL(fileURLWithPath: url.path).standardizedFileURL
        guard let bookmark else { return current }
        func available(_ candidate: URL) -> Bool {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: candidate.path, isDirectory: &directory)
                && directory.boolValue && FileManager.default.isReadableFile(atPath: candidate.path)
        }
        if available(current) { return current }
        do {
            var stale = false
            let resolved = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                   relativeTo: nil, bookmarkDataIsStale: &stale).standardizedFileURL
            if available(resolved) { return resolved }
            // Replacing a directory on another computer invalidates its old
            // file identity. The explicitly chosen path may now be valid again.
            return available(current) ? current : resolved
        } catch {
            if available(current) { return current }
            throw error
        }
    }

    public func refreshedBookmark(for resolved: URL) -> Data? {
        guard isLocal, let bookmark else { return nil }
        var stale = false
        let original = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard stale || original?.standardizedFileURL.path != resolved.standardizedFileURL.path || original == nil else { return nil }
        return try? resolved.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}

public struct MediaFolder: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let url: URL
    public let parentPath: String?
    public let name: String
    public let cloud: CloudFolderReference?
    public var isLocal: Bool { cloud == nil && url.isFileURL }
    public var selectionPath: String { cloud?.selectionPath ?? url.path }
    public var displayPath: String { cloud?.path ?? url.path }

    public init(id: String? = nil, url: URL, parentPath: String? = nil, name: String? = nil, cloud: CloudFolderReference? = nil) {
        self.id = cloud?.stableID ?? id ?? (url.isFileURL ? url.standardizedFileURL.path : url.absoluteString)
        self.url = cloud?.locatorURL ?? (url.isFileURL ? url.standardizedFileURL : url)
        self.parentPath = cloud?.parentSelectionPath ?? parentPath
        self.name = name ?? url.lastPathComponent.precomposedStringWithCanonicalMapping
        self.cloud = cloud
    }

    public init(cloud: CloudFolderReference, name: String? = nil) {
        self.init(url: cloud.locatorURL, name: name, cloud: cloud)
    }

    public func belongs(to library: MediaLibrary) -> Bool {
        if let cloud, let libraryCloud = library.cloud {
            return cloud.accountID == libraryCloud.accountID
                && DirectorySelection.isWithin(selectionPath, directory: library.selectionPath)
        }
        guard isLocal, library.isLocal else { return false }
        return DirectorySelection.isWithin(selectionPath, directory: library.selectionPath)
    }
}

public struct ScanResult: Sendable {
    public let items: [MediaItem]
    public let folders: [MediaFolder]
    public let unavailableLibraryIDs: Set<UUID>
    public let warnings: [String]
    public let resolvedLibraryURLs: [UUID: URL]
    public let refreshedBookmarks: [UUID: Data]
    public let unverifiedPaths: Set<String>

    public init(items: [MediaItem], folders: [MediaFolder], unavailableLibraryIDs: Set<UUID> = [], warnings: [String] = [], resolvedLibraryURLs: [UUID: URL] = [:], refreshedBookmarks: [UUID: Data] = [:], unverifiedPaths: Set<String> = []) {
        self.items = items
        self.folders = folders
        self.unavailableLibraryIDs = unavailableLibraryIDs
        self.warnings = warnings
        self.resolvedLibraryURLs = resolvedLibraryURLs
        self.refreshedBookmarks = refreshedBookmarks
        self.unverifiedPaths = unverifiedPaths
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
