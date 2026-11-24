import Foundation
import UniformTypeIdentifiers
import FilmboxCore

typealias CloudDirectoryLoader = @Sendable (CloudAccount, String, String) async throws -> CloudDirectoryPage

enum CloudIndexScanOutcome: Sendable {
    case completed(CloudIndexSnapshot)
    case failed(CloudIndexProgress)
    case paused(CloudIndexProgress)
}

struct CloudIndexRestoration: Sendable {
    let status: CloudIndexStatus
    let snapshot: CloudIndexSnapshot?
    let folders: [MediaFolder]?
}

/// One library publishes only after every directory has completed. The provider
/// adapters finish all pages before returning; retry restarts a failed directory
/// at page one. This is a local snapshot, not a provider-side change feed.
actor CloudLibraryScanner {
    private let storage: CloudIndexStore
    private let loader: CloudDirectoryLoader
    private let temporaryDirectory: URL?
    private var activeGenerations: [UUID: UUID] = [:]

    init(directory: URL? = nil, loader: CloudDirectoryLoader? = nil) {
        let temporary = directory == nil ? FileManager.default.temporaryDirectory.appendingPathComponent("FilmboxCloudIndex-\(UUID().uuidString)", isDirectory: true) : nil
        temporaryDirectory = temporary
        storage = CloudIndexStore(catalogDirectory: directory ?? temporary)
        self.loader = loader ?? { account, folderID, path in
            try await CloudGateway.shared.list(account: account, folderID: folderID, path: path)
        }
    }

    func scan(library: MediaLibrary, account: CloudAccount?, resume: Bool,
              progress: @Sendable (CloudIndexProgress) async -> Void) async -> CloudIndexScanOutcome {
        let token = UUID()
        activeGenerations[library.id] = token
        defer { if activeGenerations[library.id] == token { activeGenerations[library.id] = nil } }
        var manifest: CloudIndexManifest
        do { manifest = try storage.begin(library: library, resume: resume) }
        catch {
            let state = CloudIndexProgress(phase: .failed, error: "无法保存索引检查点：\(error.localizedDescription)")
            await progress(state)
            return .failed(state)
        }
        guard let account, account.id == library.cloud?.accountID else {
            manifest.progress.phase = .failed
            manifest.progress.error = ResourceProblem.login.title
            manifest.progress.errorCode = ResourceProblem.login.rawValue
            manifest.progress.updatedAt = Date()
            try? storage.save(manifest)
            await progress(manifest.progress)
            return .failed(manifest.progress)
        }
        var queue = manifest.pending
        var cursor = 0
        do {
            let restored: CloudIndexSnapshot
            do { restored = try storage.snapshot(manifest) }
            catch {
                guard resume else { throw error }
                // A directory file can be corrupt even when its journal record
                // is intact. Recheck the tree instead of reusing partial data.
                manifest = try storage.begin(library: library, resume: false)
                queue = manifest.pending
                restored = try storage.snapshot(manifest)
            }
            var kinds = Dictionary(restored.items.map { ($0.id, $0.kind) }, uniquingKeysWith: { _, last in last })
            var folderIDs = Set(restored.folders.map(\.id))
            for pending in manifest.pending { folderIDs.insert("cloud-folder:\(account.id.uuidString):\(pending.id)") }
            let completedIDs = Set(manifest.completed.map(\.id))
            var discoveredIDs = completedIDs.union(manifest.pending.map(\.id))
            manifest.progress.photos = kinds.values.filter { $0 == .image }.count
            manifest.progress.videos = kinds.values.filter { $0 == .video }.count
            manifest.progress.folders = folderIDs.count
            var photos = manifest.progress.photos
            var videos = manifest.progress.videos
            await progress(manifest.progress)
            while cursor < queue.count {
                let directory = queue[cursor]
                try Task.checkCancellation()
                guard activeGenerations[library.id] == token else { return .paused(manifest.progress) }
                let page = try await loader(account, directory.id, directory.path)
                try Task.checkCancellation()
                guard activeGenerations[library.id] == token else { return .paused(manifest.progress) }
                let rootName = directory.path == manifest.reference.path ? library.name : nil
                var folders = [MediaFolder(cloud: CloudFolderReference(accountID: account.id, folderID: directory.id, path: directory.path), name: rootName)]
                var items: [MediaItem] = []
                var children: [CloudIndexDirectory] = []
                for entry in page.entries {
                    guard !entry.id.isEmpty, !entry.name.isEmpty, entry.name != ".", entry.name != "..", !entry.name.contains("/") else { continue }
                    let path = CloudMediaPath.normalized(directory.path + "/" + entry.name)
                    if entry.isDirectory {
                        let child = CloudIndexDirectory(id: entry.id, path: path)
                        if discoveredIDs.insert(entry.id).inserted { children.append(child) }
                        let folder = MediaFolder(cloud: CloudFolderReference(accountID: account.id, folderID: entry.id, path: path), name: entry.name)
                        folderIDs.insert(folder.id)
                        folders.append(folder)
                    } else if let kind = Self.kind(name: entry.name) {
                        // Temporary signed cover links are resolved by the helper,
                        // not persisted as catalogue changes on every token rotation.
                        let ref = CloudMediaReference(accountID: account.id, fileID: entry.id, parentID: directory.id,
                                                      remotePath: path, revision: "\(entry.size)|\(entry.modified.timeIntervalSince1970)")
                        let item = MediaItem(cloud: ref, kind: kind, fileSize: entry.size, modifiedDate: entry.modified,
                                             createdDate: entry.created ?? entry.modified, pixelWidth: entry.width,
                                             pixelHeight: entry.height, duration: entry.duration)
                        items.append(item)
                        if let previous = kinds.updateValue(kind, forKey: item.id) {
                            if previous != kind {
                                if previous == .image { photos -= 1 } else { videos -= 1 }
                                if kind == .image { photos += 1 } else { videos += 1 }
                            }
                        } else if kind == .image { photos += 1 }
                        else { videos += 1 }
                    }
                }
                // Directory data precedes its small journal event. A crash
                // before that event safely repeats this directory from page one.
                try storage.saveDirectory(CloudIndexDirectorySnapshot(directory: directory, items: items, folders: folders), libraryID: library.id)
                cursor += 1
                queue.append(contentsOf: children)
                manifest.completed.append(directory)
                manifest.progress.photos = photos
                manifest.progress.videos = videos
                manifest.progress.folders = folderIDs.count
                manifest.progress.updatedAt = Date()
                try storage.recordCompletion(directory: directory, children: children, manifest: manifest)
                await progress(manifest.progress)
            }
            try Task.checkCancellation()
            guard activeGenerations[library.id] == token else { return .paused(manifest.progress) }
            manifest.progress.phase = .ready
            manifest.progress.error = nil
            manifest.progress.updatedAt = Date()
            manifest.progress.lastCompletedAt = manifest.progress.updatedAt
            manifest.published = false
            manifest.pending = []
            try storage.save(manifest)
            let snapshot = try storage.snapshot(manifest)
            try storage.saveFolders(snapshot, libraryID: library.id)
            await progress(snapshot.progress)
            return .completed(snapshot)
        } catch {
            guard activeGenerations[library.id] == token else { return .paused(manifest.progress) }
            let paused = Task.isCancelled || error is CancellationError
            manifest.progress.phase = paused ? .paused : .failed
            manifest.progress.error = paused ? nil : error.localizedDescription
            manifest.progress.errorCode = paused ? nil : MediaFailureText.problem(error).rawValue
            manifest.progress.updatedAt = Date()
            manifest.pending = Array(queue.dropFirst(cursor))
            try? storage.save(manifest)
            await progress(manifest.progress)
            return paused ? .paused(manifest.progress) : .failed(manifest.progress)
        }
    }

    func discard(libraryID: UUID) throws {
        activeGenerations[libraryID] = UUID()
        try storage.discard(libraryID)
    }

    func markPublished(library: MediaLibrary, generation: UUID) throws { try storage.markPublished(library, generation: generation) }

    /// Full queue/media decoding never runs on the UI actor during startup.
    func restore(library: MediaLibrary) throws -> CloudIndexRestoration? {
        guard let manifest = storage.manifest(for: library) else {
            if storage.hasManifest(for: library.id) {
                throw CloudConnectionError.service("索引检查点无法读取，请重新校对资源库。")
            }
            return nil
        }
        if manifest.progress.phase == .ready && !manifest.published {
            let snapshot = try storage.snapshot(manifest)
            return CloudIndexRestoration(status: CloudIndexStatus(manifest), snapshot: snapshot, folders: snapshot.folders)
        }
        return CloudIndexRestoration(status: CloudIndexStatus(manifest), snapshot: nil,
                                     folders: storage.folders(for: library, generation: manifest.generation))
    }

    /// Compatibility for standalone checks. No partial directory data is exposed.
    func scan(libraries: [MediaLibrary], accounts: [CloudAccount],
              progress: @Sendable ([MediaItem], [MediaFolder]) async -> Void) async -> ScanResult {
        let byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var items: [String: MediaItem] = [:]
        var folders: [String: MediaFolder] = [:]
        var unavailable = Set<UUID>()
        var warnings: [String] = []
        for library in libraries {
            guard !Task.isCancelled else { break }
            switch await scan(library: library, account: library.cloud.flatMap { byID[$0.accountID] }, resume: false, progress: { _ in }) {
            case .completed(let snapshot):
                for item in snapshot.items { items[item.id] = item }
                for folder in snapshot.folders { folders[folder.selectionPath] = folder }
            case .failed(let state):
                unavailable.insert(library.id)
                warnings.append("\(library.name)：\(state.error ?? "无法完成索引")")
            case .paused:
                unavailable.insert(library.id)
            }
        }
        await progress(Array(items.values), Array(folders.values))
        return ScanResult(items: Array(items.values), folders: Array(folders.values), unavailableLibraryIDs: unavailable, warnings: warnings)
    }

    private static func kind(name: String) -> MediaKind? {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["webm", "mkv", "avi", "wmv", "flv", "mts", "m2ts", "vob", "mpeg", "mpg"].contains(ext) { return .video }
        guard let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        return nil
    }

    deinit { if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) } }
}
