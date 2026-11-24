import Foundation

public enum FolderSelectionState: String, Codable, Hashable, Sendable {
    case none
    case partial
    case all
}

/// Directory rules use the most specific ancestor; exclusion wins ties.
/// Paths are compared at directory boundaries so /Trips never matches /Trips-old.
public struct DirectorySelection: Codable, Hashable, Sendable {
    public var included: Set<String>
    public var excluded: Set<String>

    public init(included: Set<String> = [], excluded: Set<String> = []) {
        self.included = Set(included.map(Self.normalized))
        self.excluded = Set(excluded.map(Self.normalized))
    }

    public func contains(_ filePath: String) -> Bool {
        let path = Self.normalized(filePath)
        let include = included.filter { Self.isWithin(path, directory: $0) }.max { $0.count < $1.count }
        let exclude = excluded.filter { Self.isWithin(path, directory: $0) }.max { $0.count < $1.count }
        guard let include else { return false }
        guard let exclude else { return true }
        return include.count > exclude.count
    }

    public func state(for folderPath: String) -> FolderSelectionState {
        let folder = Self.normalized(folderPath)
        let rules = included.union(excluded).filter { Self.isWithin($0, directory: folder) }
        let states = [contains(folder)] + rules.map { contains($0) }
        guard states.contains(true) else { return .none }
        return states.contains(false) ? .partial : .all
    }

    public mutating func toggle(_ folderPath: String) {
        let folder = Self.normalized(folderPath)
        let wasAll = state(for: folder) == .all
        included = included.filter { !Self.isWithin($0, directory: folder) }
        excluded = excluded.filter { !Self.isWithin($0, directory: folder) }
        if wasAll {
            excluded.insert(folder)
        } else {
            included.insert(folder)
        }
    }

    public static func isWithin(_ path: String, directory: String) -> Bool {
        path == directory || path.hasPrefix(directory == "/" ? "/" : directory + "/")
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
