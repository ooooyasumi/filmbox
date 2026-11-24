import Foundation
import Observation
import CryptoKit
import FilmboxCore

/// One optional, low-priority catalogue sweep. A durable completion ledger
/// prevents an eviction from creating a download/evict/download loop on restart.
@MainActor @Observable final class CloudThumbnailPreloader {
    static let shared = CloudThumbnailPreloader()
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var isRunning = false
    private(set) var isCapacityPaused = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var finished: Set<String>
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var saveRevision = 0
    @ObservationIgnored private let writer = CloudPreloadLedgerWriter()
    @ObservationIgnored private let ledger: URL

    init(directory: URL? = nil) {
        var fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.filmbox.app", isDirectory: true)
        #if DEBUG
        if let path = Bundle.main.object(forInfoDictionaryKey: "FilmboxDevelopmentCatalog") as? String { fallback = URL(fileURLWithPath: path, isDirectory: true) }
        #endif
        let root = directory ?? fallback
        ledger = root.appendingPathComponent("cloud-preloaded.json")
        finished = (try? Data(contentsOf: ledger)).flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
    }

    func update(items: [MediaItem]) {
        generation += 1
        let token = generation
        task?.cancel(); task = nil
        isRunning = false
        guard UserDefaults.standard.string(forKey: "cloudThumbnailMode") == "all" else { return }
        let remote = items.filter { !$0.isLocal }
        total = remote.count
        isCapacityPaused = false
        guard !remote.isEmpty else { return }
        isRunning = true
        let previous = finished
        task = Task(priority: .background) { [weak self] in
            let entries = await Task.detached(priority: .utility) {
                remote.map { ($0, Self.key($0)) }
            }.value
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.finished.formIntersection(Set(entries.map(\.1)))
            self.completed = entries.filter { previous.contains($0.1) }.count
            let pending = entries.filter { entry in
                !previous.contains(entry.1) && entry.0.cloud.map { CloudTransferCenter.shared.issue(for: $0.accountID) == nil } == true
            }
            var sinceCapacityCheck = 0
            for (item, key) in pending {
                guard !Task.isCancelled, self.generation == token else { return }
                while CloudTransferCenter.shared.isBackgroundPaused {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
                if let accountID = item.cloud?.accountID, CloudTransferCenter.shared.issue(for: accountID) != nil { continue }
                if sinceCapacityCheck == 0, !(await MediaAssetResolver.shared.hasBackgroundThumbnailCapacity()) {
                    self.isCapacityPaused = true; self.isRunning = false
                    self.persist()
                    return
                }
                let result = await ThumbnailService.shared.preloadCloudThumbnail(for: item)
                guard !Task.isCancelled, self.generation == token else { return }
                switch result {
                case .ready, .noCloudPreview:
                    self.finished.insert(key); self.completed += 1
                case .cancelled:
                    if let id = item.cloud?.accountID, CloudTransferCenter.shared.issue(for: id) != nil { continue }
                    self.isRunning = false; self.persist(); return
                case .failed, .unavailable:
                    if let id = item.cloud?.accountID, CloudTransferCenter.shared.issue(for: id) != nil { continue }
                    // A service/login failure must not hammer the rest of a large
                    // account. A later refresh retries the unfinished suffix.
                    self.isRunning = false; self.persist(); return
                }
                sinceCapacityCheck = (sinceCapacityCheck + 1) % 16
                if Date().timeIntervalSince(self.lastSave) > 5 { self.persist() }
                await Task.yield()
            }
            guard self.generation == token else { return }
            self.isRunning = false; self.persist()
        }
    }

    func resetCompletion() {
        generation += 1
        task?.cancel(); task = nil
        finished.removeAll()
        completed = 0
        isRunning = false
        isCapacityPaused = false
        persist()
    }

    private func persist() {
        lastSave = .now
        saveRevision += 1
        let values = finished, path = ledger, revision = saveRevision, writer = writer
        Task.detached(priority: .utility) {
            await writer.save(values, to: path, revision: revision)
        }
    }
    nonisolated private static func key(_ item: MediaItem) -> String {
        SHA256.hash(data: Data("\(item.id)|\(item.cloud?.revision ?? "")|\(item.modifiedDate)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

private actor CloudPreloadLedgerWriter {
    private var latestRevision = 0
    func save(_ values: Set<String>, to path: URL, revision: Int) {
        guard revision >= latestRevision else { return }
        latestRevision = revision
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: path, options: .atomic)
    }
}
