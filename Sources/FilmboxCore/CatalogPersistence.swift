import Foundation

public struct CatalogState: Codable, Equatable, Sendable {
    public var libraries: [MediaLibrary]
    public var favorites: Set<String>
    public var cachedItems: [MediaItem]
    public var hiddenIDs: Set<String>
    public var albums: [MediaAlbum]
    public var cloudAccounts: [CloudAccount]

    public init(libraries: [MediaLibrary] = [], favorites: Set<String> = [], cachedItems: [MediaItem] = [], hiddenIDs: Set<String> = [], albums: [MediaAlbum] = [], cloudAccounts: [CloudAccount] = []) {
        self.libraries = libraries
        self.favorites = favorites
        self.cachedItems = cachedItems
        self.hiddenIDs = hiddenIDs
        self.albums = albums
        self.cloudAccounts = cloudAccounts
    }

    private enum CodingKeys: String, CodingKey { case libraries, favorites, cachedItems, hiddenIDs, albums, cloudAccounts }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        libraries = try container.decode([MediaLibrary].self, forKey: .libraries)
        favorites = Set(try container.decode([String].self, forKey: .favorites))
        cachedItems = try container.decodeIfPresent([MediaItem].self, forKey: .cachedItems) ?? []
        hiddenIDs = Set(try container.decodeIfPresent([String].self, forKey: .hiddenIDs) ?? [])
        albums = try container.decodeIfPresent([MediaAlbum].self, forKey: .albums) ?? []
        cloudAccounts = try container.decodeIfPresent([CloudAccount].self, forKey: .cloudAccounts) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(libraries, forKey: .libraries)
        try container.encode(favorites.sorted(), forKey: .favorites)
        try container.encode(cachedItems, forKey: .cachedItems)
        try container.encode(hiddenIDs.sorted(), forKey: .hiddenIDs)
        try container.encode(albums, forKey: .albums)
        try container.encode(cloudAccounts, forKey: .cloudAccounts)
    }
}

public enum CatalogPersistenceError: LocalizedError {
    case unreadable(URL, String)
    case corrupted(URL, String)
    case unwritable(URL, String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url, let reason):
            return "无法读取资料库记录（\(url.lastPathComponent)）：\(reason)"
        case .corrupted(let url, _):
            return "资料库记录已损坏。原文件保留于 \(url.path)，请从备份恢复或联系支持。"
        case .unwritable(_, let reason):
            return "无法保存资料库记录：\(reason)"
        }
    }
}

public struct CatalogPersistence: Sendable {
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("catalog.json", isDirectory: false) }

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.filmbox.app", isDirectory: true)
    }

    public func load() throws -> CatalogState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return CatalogState() }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw CatalogPersistenceError.unreadable(fileURL, error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(CatalogState.self, from: data)
        } catch {
            throw CatalogPersistenceError.corrupted(fileURL, error.localizedDescription)
        }
    }

    public func save(_ state: CatalogState) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            // The catalogue is machine storage. Avoid sorting every media field and
            // allocating an extra indented copy during frequent background saves.
            encoder.outputFormatting = [.withoutEscapingSlashes]
            try encoder.encode(state).write(to: fileURL, options: [.atomic])
        } catch {
            throw CatalogPersistenceError.unwritable(fileURL, error.localizedDescription)
        }
    }

    /// Copies the existing catalog before recovery. The original stays untouched.
    /// A UUID makes multiple recoveries in the same second safe and distinct.
    @discardableResult
    public func backupCorruptCatalog() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "catalog-corrupt-\(formatter.string(from: Date()))-\(UUID().uuidString).json"
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        do {
            try FileManager.default.copyItem(at: fileURL, to: destination)
            return destination
        } catch {
            throw CatalogPersistenceError.unwritable(destination, error.localizedDescription)
        }
    }
}
