import Foundation
import CryptoKit
import FilmboxCore

struct CloudIndexDirectory: Codable, Hashable, Sendable {
    let id: String
    let path: String
}

struct CloudIndexManifest: Codable, Sendable {
    let generation: UUID
    let libraryID: UUID
    let reference: CloudLibraryReference
    let startedAt: Date
    var pending: [CloudIndexDirectory]
    var completed: [CloudIndexDirectory]
    var progress: CloudIndexProgress
    var published: Bool
}

/// A bounded startup read; queues and media remain on the scanner actor.
struct CloudIndexStatus: Codable, Sendable {
    let generation: UUID
    let libraryID: UUID
    let reference: CloudLibraryReference
    let progress: CloudIndexProgress
    let published: Bool

    init(_ manifest: CloudIndexManifest) {
        generation = manifest.generation; libraryID = manifest.libraryID
        reference = manifest.reference; progress = manifest.progress; published = manifest.published
    }
}

private struct CloudIndexCompletion: Codable {
    let generation: UUID
    let sequence: Int
    let directory: CloudIndexDirectory
    let children: [CloudIndexDirectory]
    let progress: CloudIndexProgress
}

struct CloudIndexDirectorySnapshot: Codable, Sendable {
    let directory: CloudIndexDirectory
    let items: [MediaItem]
    let folders: [MediaFolder]
}

struct CloudIndexSnapshot: Sendable {
    let generation: UUID
    let items: [MediaItem]
    let folders: [MediaFolder]
    let progress: CloudIndexProgress
}

private struct CloudIndexFolders: Codable {
    let generation: UUID
    let folders: [MediaFolder]
}

/// Directory responses are atomic. A small append-only journal advances the
/// queue only after its directory data is durable; no provider page offset is
/// resumed. The full queue is checkpointed only at run boundaries, keeping
/// persistence proportional to the number of directories rather than its square.
struct CloudIndexStore: Sendable {
    let directory: URL

    init(catalogDirectory: URL? = nil) {
        directory = (catalogDirectory ?? CatalogPersistence().directory)
            .appendingPathComponent("cloud-index", isDirectory: true)
    }

    func status(for library: MediaLibrary) -> CloudIndexStatus? {
        guard let data = try? Data(contentsOf: statusURL(library.id)), data.count <= 16_384,
              let value = try? JSONDecoder().decode(CloudIndexStatus.self, from: data),
              value.libraryID == library.id, value.reference == library.cloud else { return nil }
        return value
    }

    func hasManifest(for libraryID: UUID) -> Bool { FileManager.default.fileExists(atPath: manifestURL(libraryID).path) }

    /// Called on the scanner actor. A truncated final journal entry represents
    /// an interrupted write and is retried from that complete directory boundary.
    func manifest(for library: MediaLibrary) -> CloudIndexManifest? {
        guard let data = try? Data(contentsOf: manifestURL(library.id)),
              var value = try? JSONDecoder().decode(CloudIndexManifest.self, from: data),
              value.libraryID == library.id, value.reference == library.cloud else { return nil }
        guard let journal = try? Data(contentsOf: journalURL(library.id)), !journal.isEmpty else { return value }
        var queue = value.pending
        var cursor = 0
        var start = journal.startIndex
        while start < journal.endIndex, let end = journal[start...].firstIndex(of: 10) {
            let line = journal[start..<end]
            start = journal.index(after: end)
            guard !line.isEmpty else { continue }
            guard let event = try? JSONDecoder().decode(CloudIndexCompletion.self, from: line),
                  event.generation == value.generation else { return nil }
            // A crash between replacing the base manifest and truncating the
            // journal leaves already checkpointed events, which are harmless.
            if event.sequence <= value.completed.count { continue }
            guard event.sequence == value.completed.count + 1,
                  cursor < queue.count, queue[cursor] == event.directory else { return nil }
            cursor += 1
            queue.append(contentsOf: event.children)
            value.completed.append(event.directory)
            value.progress = event.progress
        }
        value.pending = Array(queue.dropFirst(cursor))
        return value
    }

    func begin(library: MediaLibrary, resume: Bool) throws -> CloudIndexManifest {
        guard let reference = library.cloud else { throw CloudConnectionError.invalidCredential }
        let previous = manifest(for: library)
        if resume, var previous, previous.progress.phase != .ready,
           Date().timeIntervalSince(previous.startedAt) < 24 * 3600,
           previous.completed.allSatisfy({ FileManager.default.fileExists(atPath: directoryURL($0, libraryID: library.id).path) }) {
            previous.progress.phase = .indexing
            previous.progress.error = nil
            previous.progress.updatedAt = Date()
            // Compaction also removes a possible truncated trailing journal line
            // before the next append, without touching the usable catalogue.
            try save(previous)
            return previous
        }
        let lastCompleted = previous?.progress.lastCompletedAt
        // Reuse verified directory files while checking their remote listings.
        // The new manifest is authoritative; leftover files never publish by
        // themselves, and are pruned only after a complete successful commit.
        if previous?.progress.phase != .ready || previous?.published != true { try discard(library.id) }
        let initial = CloudIndexManifest(generation: UUID(), libraryID: library.id, reference: reference, startedAt: Date(),
                                         pending: [CloudIndexDirectory(id: reference.folderID, path: reference.path)], completed: [],
                                         progress: CloudIndexProgress(folders: 1, lastCompletedAt: lastCompleted), published: false)
        try save(initial)
        return initial
    }

    /// Compact at start/end only. Base replacement precedes journal removal, so
    /// either side of an interruption still has all committed directory records.
    func save(_ manifest: CloudIndexManifest) throws {
        try FileManager.default.createDirectory(at: libraryDirectory(manifest.libraryID), withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: manifestURL(manifest.libraryID), options: .atomic)
        try saveStatus(CloudIndexStatus(manifest))
        try Data().write(to: journalURL(manifest.libraryID), options: .atomic)
    }

    func recordCompletion(directory completed: CloudIndexDirectory, children: [CloudIndexDirectory],
                          manifest: CloudIndexManifest) throws {
        let event = CloudIndexCompletion(generation: manifest.generation, sequence: manifest.completed.count,
                                         directory: completed, children: children, progress: manifest.progress)
        var data = try JSONEncoder().encode(event)
        data.append(10)
        let url = journalURL(manifest.libraryID)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try saveStatus(CloudIndexStatus(manifest))
    }

    @discardableResult
    func saveDirectory(_ value: CloudIndexDirectorySnapshot, libraryID: UUID) throws -> Bool {
        if let previous = try? readDirectory(value.directory, libraryID: libraryID),
           Set(previous.items) == Set(value.items), Set(previous.folders) == Set(value.folders) { return false }
        try FileManager.default.createDirectory(at: libraryDirectory(libraryID), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: directoryURL(value.directory, libraryID: libraryID), options: .atomic)
        return true
    }

    func readDirectory(_ value: CloudIndexDirectory, libraryID: UUID) throws -> CloudIndexDirectorySnapshot {
        let result = try JSONDecoder().decode(CloudIndexDirectorySnapshot.self, from: Data(contentsOf: directoryURL(value, libraryID: libraryID)))
        guard result.directory == value else { throw CloudConnectionError.service("索引检查点不完整，请重新校对资源库。") }
        return result
    }

    func snapshot(_ manifest: CloudIndexManifest) throws -> CloudIndexSnapshot {
        if manifest.progress.phase == .ready && !manifest.pending.isEmpty {
            throw CloudConnectionError.service("索引检查点尚未完成，请重新校对资源库。")
        }
        var items: [String: MediaItem] = [:]
        var folders: [String: MediaFolder] = [:]
        for completed in manifest.completed {
            let value = try readDirectory(completed, libraryID: manifest.libraryID)
            for item in value.items { items[item.id] = item }
            for folder in value.folders { folders[folder.id] = folder }
        }
        return CloudIndexSnapshot(generation: manifest.generation, items: items.values.sorted { $0.id < $1.id },
                                  folders: folders.values.sorted { $0.selectionPath < $1.selectionPath }, progress: manifest.progress)
    }

    func saveFolders(_ snapshot: CloudIndexSnapshot, libraryID: UUID) throws {
        let value = CloudIndexFolders(generation: snapshot.generation, folders: snapshot.folders)
        try JSONEncoder().encode(value).write(to: foldersURL(libraryID), options: .atomic)
    }

    func folders(for library: MediaLibrary, generation: UUID) -> [MediaFolder]? {
        guard let data = try? Data(contentsOf: foldersURL(library.id)),
              let value = try? JSONDecoder().decode(CloudIndexFolders.self, from: data), value.generation == generation else { return nil }
        return value.folders
    }

    func markPublished(_ library: MediaLibrary, generation: UUID) throws {
        guard var value = manifest(for: library), value.generation == generation else { return }
        value.published = true
        try save(value)
        let retained = Set(value.completed.map { directoryURL($0, libraryID: library.id).lastPathComponent })
        let entries = (try? FileManager.default.contentsOfDirectory(at: libraryDirectory(library.id), includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.pathExtension == "json" && entry.deletingPathExtension().lastPathComponent.count == 64 && !retained.contains(entry.lastPathComponent) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    func discard(_ libraryID: UUID) throws {
        let folder = libraryDirectory(libraryID)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    private func saveStatus(_ status: CloudIndexStatus) throws {
        try JSONEncoder().encode(status).write(to: statusURL(status.libraryID), options: .atomic)
    }
    private func libraryDirectory(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func manifestURL(_ id: UUID) -> URL { libraryDirectory(id).appendingPathComponent("manifest.json") }
    private func statusURL(_ id: UUID) -> URL { libraryDirectory(id).appendingPathComponent("status.json") }
    private func journalURL(_ id: UUID) -> URL { libraryDirectory(id).appendingPathComponent("completed.ndjson") }
    private func foldersURL(_ id: UUID) -> URL { libraryDirectory(id).appendingPathComponent("folders.json") }
    private func directoryURL(_ value: CloudIndexDirectory, libraryID: UUID) -> URL {
        let hash = SHA256.hash(data: Data((value.id + "\u{0}" + value.path).utf8)).map { String(format: "%02x", $0) }.joined()
        return libraryDirectory(libraryID).appendingPathComponent(hash).appendingPathExtension("json")
    }
}
