import Foundation

public enum CloudProvider: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case baidu
    case quark
    case webdav

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .baidu: "百度网盘"
        case .quark: "夸克网盘"
        case .webdav: "WebDAV"
        }
    }

    public var systemImage: String {
        switch self {
        case .baidu: "externaldrive.badge.icloud"
        case .quark: "cloud"
        case .webdav: "network"
        }
    }
}

/// Public account metadata only. Authentication material belongs in the Keychain.
public struct CloudAccount: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let provider: CloudProvider
    public var name: String
    public var endpoint: URL?

    public init(id: UUID = UUID(), provider: CloudProvider, name: String, endpoint: URL? = nil) {
        self.id = id
        self.provider = provider
        self.name = name
        self.endpoint = endpoint
    }
}

public struct CloudLibraryReference: Codable, Hashable, Sendable {
    public let accountID: UUID
    public let folderID: String
    public let path: String

    public init(accountID: UUID, folderID: String, path: String) {
        self.accountID = accountID
        self.folderID = folderID
        self.path = CloudMediaPath.normalized(path)
    }

    public var selectionPath: String { CloudMediaPath.selectionPath(accountID: accountID, path: path) }
    public var locatorURL: URL { CloudMediaPath.locatorURL(accountID: accountID, path: path) }
}

/// File identity is independent of its name, parent directory and expiring download links.
public struct CloudMediaReference: Codable, Hashable, Sendable {
    public let accountID: UUID
    public let fileID: String
    public let parentID: String
    public let remotePath: String
    public let revision: String
    public let thumbnailURL: URL?

    public init(accountID: UUID, fileID: String, parentID: String, remotePath: String, revision: String, thumbnailURL: URL? = nil) {
        self.accountID = accountID
        self.fileID = fileID
        self.parentID = parentID
        self.remotePath = CloudMediaPath.normalized(remotePath)
        self.revision = revision
        self.thumbnailURL = thumbnailURL
    }

    public var stableID: String { "cloud:\(accountID.uuidString):\(fileID)" }
    public var selectionPath: String { CloudMediaPath.selectionPath(accountID: accountID, path: remotePath) }
    public var locatorURL: URL { CloudMediaPath.locatorURL(accountID: accountID, path: remotePath) }
    public var name: String { (remotePath as NSString).lastPathComponent }
    public var folderPath: String { CloudMediaPath.normalized((remotePath as NSString).deletingLastPathComponent) }
}

public struct CloudFolderReference: Codable, Hashable, Sendable {
    public let accountID: UUID
    public let folderID: String
    public let path: String

    public init(accountID: UUID, folderID: String, path: String) {
        self.accountID = accountID
        self.folderID = folderID
        self.path = CloudMediaPath.normalized(path)
    }

    public var stableID: String { "cloud-folder:\(accountID.uuidString):\(folderID)" }
    public var selectionPath: String { CloudMediaPath.selectionPath(accountID: accountID, path: path) }
    public var locatorURL: URL { CloudMediaPath.locatorURL(accountID: accountID, path: path) }
    public var name: String { (path as NSString).lastPathComponent }
    public var parentSelectionPath: String? {
        guard path != "/" else { return nil }
        return CloudMediaPath.selectionPath(accountID: accountID, path: (path as NSString).deletingLastPathComponent)
    }
}

/// Logical paths are solely for selection rules; they are never local filesystem paths.
public enum CloudMediaPath {
    public static func normalized(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    public static func selectionPath(accountID: UUID, path: String) -> String {
        let normalized = normalized(path)
        let root = "/__filmbox_cloud__/\(accountID.uuidString)"
        return normalized == "/" ? root : root + normalized
    }

    public static func locatorURL(accountID: UUID, path: String) -> URL {
        var components = URLComponents()
        components.scheme = "filmbox-cloud"
        components.host = accountID.uuidString.lowercased()
        components.path = normalized(path)
        // URLComponents percent-encodes remote names, including spaces and Unicode.
        return components.url!
    }
}
