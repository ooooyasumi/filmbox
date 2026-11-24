import Foundation
import CryptoKit
import Darwin
import FilmboxCore

/// Locators identify catalogue entries; only the resolver may turn them into
/// downloadable or playable assets. No cloud locator is a filesystem path.
final class CloudMediaRegistry: @unchecked Sendable {
    static let shared = CloudMediaRegistry()
    private let lock = NSLock()
    private var items: [URL: MediaItem] = [:]

    func register(_ values: [MediaItem]) {
        lock.withLock {
            for item in values where !item.isLocal { items[item.url] = item }
        }
    }
    func item(for url: URL) -> MediaItem? { lock.withLock { items[url] } }
}

private final class CloudResolverRegistry: @unchecked Sendable {
    static let shared = CloudResolverRegistry()
    private final class WeakResolver { weak var value: MediaAssetResolver?; init(_ value: MediaAssetResolver) { self.value = value } }
    private let lock = NSLock()
    private var values: [ObjectIdentifier: WeakResolver] = [:]
    func register(_ resolver: MediaAssetResolver) { lock.withLock { values[ObjectIdentifier(resolver)] = WeakResolver(resolver) } }
    func active() -> [MediaAssetResolver] {
        lock.withLock {
            values = values.filter { $0.value.value != nil }
            return values.values.compactMap(\.value)
        }
    }
}

actor MediaAssetResolver {
    static let shared = MediaAssetResolver()
    private struct Work {
        let token: UUID
        let task: Task<URL, Error>
        let item: MediaItem
        let purpose: CloudTransferPurpose
        let createdAt: TimeInterval
        var priority: CloudTransferPriority
        var consumers: Set<UUID>
    }
    private struct ExportLease: Codable { var expires: Date; let paths: Set<String> }
    private let directory: URL
    private let transport = CloudDownloadTransport()
    private let gate = CloudDownloadGate(limit: 3)
    private var downloads: [String: Work] = [:]
    private var reservations: [UUID: Int64] = [:]
    private var exportLeases: [UUID: ExportLease] = [:]
    private var viewingLeases: [UUID: Set<String>] = [:]
    private var recentUse: [String: Date] = [:]
    private struct CacheOwner { let itemID: String; let purpose: CloudTransferPurpose }
    private var cacheOwners: [String: CacheOwner] = [:]
    private var foregroundThumbnails: [String: Date] = [:]
    private var missingThumbnails: [String: Date] = [:]
    private var cacheIndex: [String: CacheEntry]?
    private var cacheScan: Task<[CacheEntry], Never>?
    private var cacheScanID: UUID?
    private var lastCacheReconciliation: TimeInterval = -.infinity
    private let cacheReconciliationInterval: TimeInterval
    private enum CacheChange { case stored(CacheEntry), removed }
    private var pendingCacheChanges: [String: CacheChange] = [:]
    private var indexedOriginalBytes: Int64 = 0
    private var indexedThumbnailBytes: Int64 = 0
    private var originalCachePublicationPending = false
    private let budgetOverride: Int64?
    private let recentProtectionDuration: TimeInterval
    private var leaseFile: URL { directory.appendingPathComponent(".export-leases.json") }

    init(directory: URL? = nil, diskBudget: Int64? = nil, recentProtectionDuration: TimeInterval = 120, cacheReconciliationInterval: TimeInterval = 30) {
        var fallback = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.filmbox.app", isDirectory: true)
        #if DEBUG
        if let path = Bundle.main.object(forInfoDictionaryKey: "FilmboxDevelopmentCache") as? String { fallback = URL(fileURLWithPath: path, isDirectory: true) }
        #endif
        let requested = directory ?? fallback.appendingPathComponent("cloud-assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        self.directory = URL(fileURLWithPath: Self.canonicalPath(requested.path), isDirectory: true)
        budgetOverride = diskBudget
        self.recentProtectionDuration = max(0, recentProtectionDuration)
        self.cacheReconciliationInterval = max(0, cacheReconciliationInterval)
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent(".export-leases.json")),
           let saved = try? JSONDecoder().decode([UUID: ExportLease].self, from: data) {
            exportLeases = saved.filter { $0.value.expires > .now }
        }
        CloudResolverRegistry.shared.register(self)
    }
    deinit { transport.invalidate() }

    func playbackAsset(for item: MediaItem) async throws -> CloudResolvedAsset {
        if item.isLocal { return localAsset(item.url) }
        if let cached = cachedOriginal(for: item) {
            await markCached(item, purpose: .original, url: cached)
            return localAsset(cached)
        }
        guard let ref = item.cloud else { throw CloudConnectionError.invalidCredential }
        return try await CloudGateway.shared.resolve(accountID: ref.accountID, fileID: ref.fileID, path: ref.remotePath)
    }

    /// Compatibility playback must never turn a browse/hover into an original
    /// download. A user can explicitly cache the original, then retry playback.
    func playbackURL(for item: MediaItem) async throws -> URL {
        if item.isLocal { return item.url }
        if let cached = cachedOriginal(for: item) { return cached }
        if let ref = item.cloud { try await CloudGateway.shared.checkAuthentication(accountID: ref.accountID) }
        throw CloudConnectionError.originalDownloadRequired
    }
    private func localAsset(_ url: URL) -> CloudResolvedAsset {
        CloudResolvedAsset(url: url, headers: [:], expiresAt: nil, thumbnailAvailable: nil, credential: nil)
    }

    /// This lookup never resolves a link or downloads bytes.
    func cachedOriginalFile(for item: MediaItem) -> URL? {
        guard !item.isLocal else { return item.url }
        return cachedOriginal(for: item)
    }

    func originalFile(for item: MediaItem, priority: CloudTransferPriority = .foreground) async throws -> URL {
        if item.isLocal { return item.url }
        return try await file(for: item, purpose: .original, priority: priority)
    }
    func thumbnailFile(for locator: URL, priority: CloudTransferPriority = .foreground) async throws -> URL {
        guard let item = CloudMediaRegistry.shared.item(for: locator) else { throw CloudConnectionError.credentialsMissing }
        return try await thumbnailFile(for: item, priority: priority)
    }
    /// Keep the captured catalogue revision through every suspension point.
    /// A registry refresh must not resolve a newer original into an older key.
    func thumbnailFile(for item: MediaItem, priority: CloudTransferPriority = .foreground) async throws -> URL {
        if item.isLocal { return item.url }
        // Reuse a previously explicit original download without more traffic.
        if let cached = cachedOriginal(for: item) {
            await markCached(item, purpose: .original, url: cached)
            return cached
        }
        return try await file(for: item, purpose: .thumbnail, priority: priority)
    }

    @discardableResult func inspectCache(for item: MediaItem) async -> CloudTransferSnapshot? {
        guard !item.isLocal else { return nil }
        await CloudTransferCenter.shared.register(item: item)
        if let original = cachedOriginal(for: item, protectRecently: false) { await markCached(item, purpose: .original, url: original) }
        else { await CloudTransferCenter.shared.cacheRemoved(itemID: item.id, purpose: .original) }
        let preview = destination(for: item, purpose: .thumbnail)
        if validCache(preview, expected: nil) { await markCached(item, purpose: .thumbnail, url: preview) }
        else { await CloudTransferCenter.shared.cacheRemoved(itemID: item.id, purpose: .thumbnail) }
        return await CloudTransferCenter.shared.snapshot(for: item.id)
    }
    /// Read-only availability query for filtering. Reuse the shared disk index
    /// so an uncached library does not issue a stat for every catalogue entry.
    /// Only indexed original candidates are checked for completeness; previews,
    /// staging files and a different remote revision can never satisfy it.
    func cachedOriginalIDs(for items: [MediaItem]) async -> Set<String> {
        guard !Task.isCancelled else { return [] }
        await ensureCacheIndex()
        guard indexedOriginalBytes > 0 else { return [] }
        var result = Set<String>()
        for (offset, item) in items.enumerated() {
            if offset.isMultiple(of: 128) {
                await Task.yield()
                guard !Task.isCancelled else { return [] }
            }
            guard !item.isLocal else { continue }
            let path = destination(for: item, purpose: .original)
            guard let entry = cacheIndex?[path.path], entry.purpose == .original else { continue }
            // Construct a fresh URL; values retained by a directory scan may
            // otherwise still describe a file removed outside the app.
            let bytes = fileBytes(URL(fileURLWithPath: path.path))
            guard bytes > 0 else {
                cacheRemoved(entry)
                continue
            }
            if bytes != entry.size {
                recordCacheEntry(CacheEntry(url: path, size: bytes, date: entry.date, purpose: .original))
            }
            guard item.fileSize <= 0 || bytes == item.fileSize else {
                // Keep occupied bytes in the budget even when an external
                // edit/truncation makes the original incomplete.
                if let owner = cacheOwners.removeValue(forKey: path.path) {
                    Task { @MainActor in CloudTransferCenter.shared.cacheRemoved(itemID: owner.itemID, purpose: .original) }
                }
                continue
            }
            result.insert(item.id)
        }
        return result
    }
    func setBackgroundPaused(_ paused: Bool) async { await gate.setPaused(paused) }
    func cancel(itemID: String, purpose: CloudTransferPurpose? = nil) {
        for work in downloads.values where work.item.id == itemID && (purpose == nil || work.purpose == purpose) { work.task.cancel() }
    }
    func cancelAllBackground() {
        for work in downloads.values where work.priority == .background { work.task.cancel() }
    }
    func cancel(accountID: UUID, createdBefore cutoff: TimeInterval = .infinity) {
        for work in downloads.values where work.item.cloud?.accountID == accountID && work.createdAt <= cutoff { work.task.cancel() }
    }
    nonisolated static func cancelAllTransfers(accountID: UUID, createdBefore cutoff: TimeInterval = .infinity) async {
        for resolver in CloudResolverRegistry.shared.active() { await resolver.cancel(accountID: accountID, createdBefore: cutoff) }
    }

    /// Called even if ThumbnailService coalesced before reaching the resolver.
    /// A short-lived promotion therefore survives its decode limiter queue.
    func promoteThumbnail(for locator: URL) async {
        guard let item = CloudMediaRegistry.shared.item(for: locator) else { return }
        let key = destination(for: item, purpose: .thumbnail).path
        foregroundThumbnails[key] = .now
        if var work = downloads[key], work.priority == .background {
            work.priority = .foreground; downloads[key] = work
            await gate.promote(work.token)
            await CloudTransferCenter.shared.promoted(itemID: item.id, purpose: .thumbnail, token: work.token)
        }
        if foregroundThumbnails.count > 512 {
            for key in foregroundThumbnails.sorted(by: { $0.value < $1.value }).prefix(foregroundThumbnails.count - 512).map(\.key) { foregroundThumbnails[key] = nil }
        }
    }
    func invalidateThumbnailAvailability(for itemID: String? = nil) {
        if let itemID {
            let paths = cacheOwners.filter { $0.value.itemID == itemID && $0.value.purpose == .thumbnail }.map(\.key)
            for path in paths { missingThumbnails[path] = nil }
            // A failed cover never creates a cache owner. Clearing the small
            // negative cache also covers those entries without keeping items.
            if paths.isEmpty { missingThumbnails.removeAll() }
        } else { missingThumbnails.removeAll() }
    }

    private func file(for item: MediaItem, purpose: CloudTransferPurpose, priority: CloudTransferPriority) async throws -> URL {
        try Task.checkCancellation()
        let target = destination(for: item, purpose: purpose)
        if validCache(target, expected: purpose == .original ? item.fileSize : nil) {
            protectRecently(target)
            touch(target)
            await markCached(item, purpose: purpose, url: target)
            if purpose == .original {
                Task(priority: .utility) { await ThumbnailService.shared.prepareCloudOriginalPreview(for: item, originalURL: target) }
            }
            if purpose == .original, item.pixelWidth == nil || item.pixelHeight == nil || (item.kind == .video && item.duration == nil) {
                Task { await CloudPreviewMetadata.originalMetadata(item: item, url: target) }
            }
            return target
        }
        guard let ref = item.cloud else { throw CloudConnectionError.invalidCredential }
        try await CloudGateway.shared.checkAuthentication(accountID: ref.accountID)
        try Task.checkCancellation()
        if purpose == .thumbnail, let missing = missingThumbnails[target.path], Date().timeIntervalSince(missing) < 60 {
            throw CloudConnectionError.thumbnailUnavailable
        }
        let key = target.path, consumer = UUID()
        let priority: CloudTransferPriority = purpose == .thumbnail && foregroundThumbnails[key].map { Date().timeIntervalSince($0) < 60 } == true ? .foreground : priority
        let work: Work
        if var pending = downloads[key], !pending.task.isCancelled {
            pending.consumers.insert(consumer)
            let shouldPromote = priority == .foreground && pending.priority == .background
            if shouldPromote {
                pending.priority = .foreground
            }
            downloads[key] = pending
            if shouldPromote {
                await gate.promote(pending.token)
                await CloudTransferCenter.shared.promoted(itemID: item.id, purpose: purpose, token: pending.token)
            }
            work = pending
        } else {
            let token = UUID()
            let task = Task<URL, Error> { try await self.download(item: item, purpose: purpose, priority: priority, token: token, destination: target) }
            work = Work(token: token, task: task, item: item, purpose: purpose, createdAt: ProcessInfo.processInfo.systemUptime, priority: priority, consumers: [consumer])
            downloads[key] = work
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await work.task.value
            } onCancel: { Task { await self.removeConsumer(consumer, key: key, token: work.token) } }
            if downloads[key]?.token == work.token { downloads[key] = nil }
            try Task.checkCancellation()
            return result
        } catch {
            if downloads[key]?.token == work.token { downloads[key] = nil }
            throw error
        }
    }
    private func removeConsumer(_ consumer: UUID, key: String, token: UUID) {
        guard var work = downloads[key], work.token == token else { return }
        work.consumers.remove(consumer)
        if work.consumers.isEmpty {
            work.task.cancel()
            // A rapid return to this photo needs fresh work immediately. Old
            // completion/cancellation callbacks are isolated by their token.
            downloads[key] = nil
        } else {
            downloads[key] = work
        }
    }

    private func download(item: MediaItem, purpose: CloudTransferPurpose, priority: CloudTransferPriority, token: UUID, destination: URL) async throws -> URL {
        await CloudTransferCenter.shared.queued(item: item, purpose: purpose, priority: priority, token: token)
        do {
            try await gate.acquire(token, priority: priority)
            defer { Task { await gate.release(token) } }
            try Task.checkCancellation()
            await CloudTransferCenter.shared.started(itemID: item.id, purpose: purpose, token: token)
            guard let ref = item.cloud else { throw CloudConnectionError.invalidCredential }
            try await CloudGateway.shared.checkAuthentication(accountID: ref.accountID)
            let asset = try await CloudGateway.shared.resolve(accountID: ref.accountID, fileID: ref.fileID, path: ref.remotePath, purpose: purpose.rawValue)
            defer {
                if purpose == .original {
                    Task { await CloudGateway.shared.synchronizeAssetCredential(accountID: ref.accountID,
                        connectionEpoch: asset.connectionEpoch, connectionRuntimeID: asset.connectionRuntimeID) }
                }
            }
            if purpose == .thumbnail && asset.thumbnailAvailable != true { throw CloudConnectionError.thumbnailUnavailable }
            if validCache(destination, expected: purpose == .original ? item.fileSize : nil) {
                await markCached(item, purpose: purpose, url: destination)
                return destination
            }
            // Reserve before opening an HTTP body. Covers have a hard ceiling;
            // unknown-size originals cannot silently grow beyond free budget.
            let desired = purpose == .thumbnail ? min(16 * 1024 * 1024, budget) : max(1, item.fileSize)
            let effectivePriority = downloads[destination.path]?.priority ?? priority
            let allowance = try await reserve(token: token, bytes: desired, unknownSize: purpose == .original && item.fileSize <= 0,
                                              evictIfNeeded: purpose == .original || effectivePriority == .foreground)
            defer { reservations[token] = nil }
            let incoming = directory.appendingPathComponent(".incoming", isDirectory: true)
            try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
            let temporary = incoming.appendingPathComponent(UUID().uuidString + ".partial")
            defer { try? FileManager.default.removeItem(at: temporary) }
            var request = URLRequest(url: asset.url)
            request.allHTTPHeaderFields = asset.headers
            let maximum = purpose == .thumbnail ? min(allowance, 16 * 1024 * 1024) : allowance
            let result = try await transport.download(request, staging: temporary, maximum: maximum,
                limitError: purpose == .thumbnail ? CloudConnectionError.thumbnailTooLarge : CloudConnectionError.cacheBudgetExceeded(required: item.fileSize, available: allowance)) { received, total in
                Task { @MainActor in CloudTransferCenter.shared.progress(itemID: item.id, purpose: purpose, token: token, received: received, total: total) }
            }
            try Task.checkCancellation()
            guard (200..<300).contains(result.response.statusCode) else {
                throw await CloudGateway.shared.assetFailure(accountID: ref.accountID, response: result.response, bodyURL: temporary, connectionEpoch: asset.connectionEpoch, connectionRuntimeID: asset.connectionRuntimeID)
            }
            if ["text/html", "application/json", "application/xml", "text/xml"].contains(result.response.mimeType?.lowercased() ?? "") { throw CloudConnectionError.problem(.service) }
            let length = fileBytes(temporary)
            guard length > 0 else { throw CloudConnectionError.problem(.unsupported) }
            if purpose == .original, item.fileSize > 0, length != item.fileSize { throw CloudConnectionError.problem(.incomplete) }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path), !validCache(destination, expected: purpose == .original ? item.fileSize : nil) { try FileManager.default.removeItem(at: destination) }
            if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.moveItem(at: temporary, to: destination) }
            if purpose == .original {
                try? FileManager.default.setAttributes([.modificationDate: item.modifiedDate, .creationDate: item.createdDate], ofItemAtPath: destination.path)
                Task { await CloudPreviewMetadata.originalMetadata(item: item, url: destination) }
                Task(priority: .utility) { await ThumbnailService.shared.prepareCloudOriginalPreview(for: item, originalURL: destination) }
                missingThumbnails[self.destination(for: item, purpose: .thumbnail).path] = nil
            }
            protectRecently(destination)
            touch(destination)
            cacheOwners[Self.canonicalPath(destination.path)] = CacheOwner(itemID: item.id, purpose: purpose)
            recordCacheEntry(CacheEntry(url: destination, size: length, date: .now, purpose: purpose))
            reservations[token] = nil
            await CloudTransferCenter.shared.finished(item: item, purpose: purpose, token: token, bytes: length)
            // The gateway samples helper traffic once per second. Polling again
            // for every small cover turns a library sweep into thousands of
            // redundant RPCs and global UI updates.
            return destination
        } catch {
            if purpose == .thumbnail, case .thumbnailUnavailable = error as? CloudConnectionError {
                missingThumbnails[destination.path] = .now
                if missingThumbnails.count > 2048 {
                    for key in missingThumbnails.sorted(by: { $0.value < $1.value }).prefix(missingThumbnails.count - 1536).map(\.key) { missingThumbnails[key] = nil }
                }
            }
            let authenticationFailed = (error as? CloudConnectionError).map { if case .credentialsMissing = $0 { return true }; return false } == true
            let accountRequiresLogin: Bool
            if let accountID = item.cloud?.accountID { accountRequiresLogin = await CloudTransferCenter.shared.issue(for: accountID) != nil }
            else { accountRequiresLogin = false }
            let normalized: Error = authenticationFailed || accountRequiresLogin ? CloudConnectionError.credentialsMissing : ((Task.isCancelled || (error as? URLError)?.code == .cancelled) ? CancellationError() : error)
            await CloudTransferCenter.shared.failed(itemID: item.id, purpose: purpose, token: token, error: normalized)
            throw normalized
        }
    }

    private var budget: Int64 {
        let value = UserDefaults.standard.object(forKey: "cloudCacheLimitGB") as? Double ?? 8
        return max(1, budgetOverride ?? Int64((value.isFinite ? min(64, max(1, value)) : 8) * 1_073_741_824))
    }
    private func reserve(token: UUID, bytes: Int64, unknownSize: Bool, evictIfNeeded: Bool = true) async throws -> Int64 {
        await ensureCacheIndex()
        try Task.checkCancellation()
        var other = reservations.values.reduce(Int64(0), +)
        if indexedOriginalBytes + indexedThumbnailBytes + other + bytes > budget {
            await reconcileCacheIfNeeded()
            try Task.checkCancellation()
            other = reservations.values.reduce(Int64(0), +)
        }
        if evictIfNeeded { trimToBudget(max(0, budget - other - bytes)) }
        let current = indexedOriginalBytes + indexedThumbnailBytes
        let available = max(0, budget - current - other)
        let wanted = unknownSize ? available : bytes
        guard wanted > 0, wanted <= available else { throw CloudConnectionError.cacheBudgetExceeded(required: bytes, available: available) }
        let diskAvailable = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let diskAvailable, diskAvailable > 0, wanted > max(0, diskAvailable - 32 * 1024 * 1024) { throw CloudConnectionError.cacheBudgetExceeded(required: wanted, available: max(0, diskAvailable - 32 * 1024 * 1024)) }
        reservations[token] = wanted
        return wanted
    }
    func cacheSize() async -> Int64 { await cacheSizes().totalBytes }
    func cacheSizes() async -> CloudCacheSizes {
        await ensureCacheIndex()
        await reconcileCacheIfNeeded()
        let protected = protectedPaths()
        return CloudCacheSizes(originalBytes: indexedOriginalBytes, thumbnailBytes: indexedThumbnailBytes,
            protectedBytes: protected.reduce(0) { $0 + (cacheIndex?[$1]?.size ?? 0) })
    }
    func hasBackgroundThumbnailCapacity() async -> Bool {
        await ensureCacheIndex()
        if indexedOriginalBytes + indexedThumbnailBytes >= budget * 95 / 100 { await reconcileCacheIfNeeded() }
        return indexedOriginalBytes + indexedThumbnailBytes + reservations.values.reduce(0, +) < budget * 95 / 100
    }
    @discardableResult func clearCache() async -> CloudCacheCleanup { await clearCache(purpose: nil) }
    @discardableResult func clearOriginalCache() async -> CloudCacheCleanup { await clearCache(purpose: .original) }
    @discardableResult func clearThumbnailCache() async -> CloudCacheCleanup { await clearCache(purpose: .thumbnail) }
    private func clearCache(purpose: CloudTransferPurpose?) async -> CloudCacheCleanup {
        await ensureCacheIndex()
        let protected = protectedPaths(); var removed: Int64 = 0, retained: Int64 = 0
        for entry in cacheEntries() where purpose == nil || entry.purpose == purpose {
            if protected.contains(entry.url.path) { retained += entry.size; continue }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil { removed += entry.size; cacheRemoved(entry) }
            else if !FileManager.default.fileExists(atPath: entry.url.path) { cacheRemoved(entry) }
        }
        return CloudCacheCleanup(removedBytes: removed, protectedBytes: retained)
    }
    func trimCache(keeping protected: URL? = nil) async { await ensureCacheIndex(); trimToBudget(budget, keeping: protected) }
    private func trimToBudget(_ maximum: Int64, keeping: URL? = nil) {
        guard indexedOriginalBytes + indexedThumbnailBytes > maximum else { return }
        let entries = cacheEntries().sorted { $0.date < $1.date }; let protected = protectedPaths()
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        for entry in entries where total > maximum && entry.url != keeping && !protected.contains(entry.url.path) {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil || !FileManager.default.fileExists(atPath: entry.url.path) {
                total -= entry.size; cacheRemoved(entry)
            }
        }
    }
    private func cacheRemoved(_ entry: CacheEntry) {
        removeCacheEntry(entry.url.path)
        recentUse[entry.url.path] = nil
        if let owner = cacheOwners.removeValue(forKey: entry.url.path) { Task { @MainActor in CloudTransferCenter.shared.cacheRemoved(itemID: owner.itemID, purpose: owner.purpose) } }
        let parent = entry.url.deletingLastPathComponent()
        if parent != directory, (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true { try? FileManager.default.removeItem(at: parent) }
    }
    func acquireExportLease(for items: [MediaItem]) -> UUID {
        let id = UUID()
        exportLeases[id] = ExportLease(expires: .now.addingTimeInterval(24 * 3600), paths: Set(items.filter { !$0.isLocal }.map { destination(for: $0, purpose: .original).path }))
        saveLeases(); return id
    }
    func releaseExportLease(_ id: UUID) { exportLeases[id] = nil; saveLeases() }
    func retainExportLease(_ id: UUID) { exportLeases[id]?.expires = .now.addingTimeInterval(24 * 3600); saveLeases() }
    func acquireViewingLease(for item: MediaItem) -> UUID {
        let id = UUID()
        viewingLeases[id] = Set([destination(for: item, purpose: .original).path, destination(for: item, purpose: .thumbnail).path])
        return id
    }
    func releaseViewingLease(_ id: UUID) { viewingLeases[id] = nil }
    private func saveLeases() {
        exportLeases = exportLeases.filter { $0.value.expires > .now }
        if let data = try? JSONEncoder().encode(exportLeases) { try? data.write(to: leaseFile, options: .atomic) }
    }
    private func protectedPaths() -> Set<String> {
        recentUse = recentUse.filter { $0.value > .now }
        let paths = exportLeases.values.filter { $0.expires > .now }.flatMap(\.paths)
            + viewingLeases.values.flatMap { $0 } + Array(recentUse.keys)
            + downloads.values.map { destination(for: $0.item, purpose: $0.purpose).path }
        return Set(paths.map { Self.canonicalPath($0) })
    }
    private func protectRecently(_ url: URL) { recentUse[Self.canonicalPath(url.path)] = .now.addingTimeInterval(recentProtectionDuration) }
    private func cachedOriginal(for item: MediaItem, protectRecently: Bool = true) -> URL? {
        let path = destination(for: item, purpose: .original)
        guard validCache(path, expected: item.fileSize) else { return nil }
        if protectRecently { self.protectRecently(path); touch(path) }
        return path
    }
    private func validCache(_ url: URL, expected: Int64?) -> Bool {
        let bytes = fileBytes(url)
        if bytes == 0 { removeCacheEntry(url.path) }
        return bytes > 0 && (expected == nil || expected! <= 0 || bytes == expected!)
    }
    private func fileBytes(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])).flatMap { $0.isRegularFile == true ? $0.fileSize : nil } ?? 0) }
    private func markCached(_ item: MediaItem, purpose: CloudTransferPurpose, url: URL) async {
        cacheOwners[Self.canonicalPath(url.path)] = CacheOwner(itemID: item.id, purpose: purpose)
        let bytes = fileBytes(url)
        recordCacheEntry(CacheEntry(url: url, size: bytes, date: .now, purpose: purpose))
        await CloudTransferCenter.shared.cached(item: item, purpose: purpose, bytes: bytes)
    }
    private func destination(for item: MediaItem, purpose: CloudTransferPurpose) -> URL {
        let identity = "\(item.id)|\(item.cloud?.revision ?? "")|\(item.fileSize)|\(item.modifiedDate.timeIntervalSinceReferenceDate)|\(purpose.rawValue)"
        let alphabet = Array("0123456789abcdef".utf8)
        let hex = SHA256.hash(data: Data(identity.utf8)).reduce(into: [UInt8]()) { bytes, byte in
            bytes.append(alphabet[Int(byte >> 4)]); bytes.append(alphabet[Int(byte & 15)])
        }
        let digest = String(decoding: hex, as: UTF8.self)
        return purpose == .original ? directory.appendingPathComponent(digest, isDirectory: true).appendingPathComponent(item.name) : directory.appendingPathComponent(digest).appendingPathExtension("preview")
    }
    private func touch(_ url: URL) {
        var info = stat(); guard lstat(url.path, &info) == 0 else { return }
        let now = Date().timeIntervalSince1970
        var times = [timeval(tv_sec: Int(now), tv_usec: Int32((now - floor(now)) * 1_000_000)), timeval(tv_sec: info.st_mtimespec.tv_sec, tv_usec: Int32(info.st_mtimespec.tv_nsec / 1000))]
        _ = utimes(url.path, &times)
        if let entry = cacheIndex?[url.path] {
            cacheIndex?[url.path] = CacheEntry(url: entry.url, size: entry.size, date: Date(timeIntervalSince1970: now), purpose: entry.purpose)
        }
    }
    private nonisolated static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }; defer { free(resolved) }; return String(cString: resolved)
    }
    private struct CacheEntry: Sendable { let url: URL; let size: Int64; let date: Date; let purpose: CloudTransferPurpose }
    private func ensureCacheIndex() async {
        guard cacheIndex == nil else { return }
        await refreshCacheIndex()
    }
    private func reconcileCacheIfNeeded() async {
        guard cacheScan != nil || ProcessInfo.processInfo.systemUptime - lastCacheReconciliation >= cacheReconciliationInterval else { return }
        await refreshCacheIndex()
    }
    private func refreshCacheIndex() async {
        let task: Task<[CacheEntry], Never>
        let id: UUID
        if let existing = cacheScan, let existingID = cacheScanID { task = existing; id = existingID }
        else {
            id = UUID()
            let directory = directory
            task = Task.detached(priority: .utility) { Self.scanCache(directory: directory) }
            cacheScan = task
            cacheScanID = id
        }
        let entries = await task.value
        guard cacheScanID == id else { return }
        let previousOriginals = cacheIndex.map { $0.filter { $0.value.purpose == .original }.mapValues(\.size) }
        cacheIndex = Dictionary(uniqueKeysWithValues: entries.map { ($0.url.path, $0) })
        for (path, change) in pendingCacheChanges {
            switch change { case let .stored(entry): cacheIndex?[path] = entry; case .removed: cacheIndex?[path] = nil }
        }
        pendingCacheChanges.removeAll()
        indexedOriginalBytes = cacheIndex!.values.filter { $0.purpose == .original }.reduce(0) { $0 + $1.size }
        indexedThumbnailBytes = cacheIndex!.values.filter { $0.purpose == .thumbnail }.reduce(0) { $0 + $1.size }
        if let previousOriginals, previousOriginals != cacheIndex!.filter({ $0.value.purpose == .original }).mapValues(\.size) {
            publishOriginalCacheChange()
        }
        cacheScan = nil
        cacheScanID = nil
        lastCacheReconciliation = ProcessInfo.processInfo.systemUptime
    }
    private func recordCacheEntry(_ entry: CacheEntry) {
        let path = entry.url.path
        let originalChanged = entry.purpose == .original && (cacheIndex?[path]?.purpose != .original || cacheIndex?[path]?.size != entry.size)
        if cacheScan != nil { pendingCacheChanges[path] = .stored(entry) }
        guard cacheIndex != nil else {
            pendingCacheChanges[path] = .stored(entry)
            if originalChanged { publishOriginalCacheChange() }
            return
        }
        let previous = cacheIndex?[path]
        if previous?.purpose == .original { indexedOriginalBytes -= previous!.size }
        else if previous?.purpose == .thumbnail { indexedThumbnailBytes -= previous!.size }
        cacheIndex?[path] = entry
        if entry.purpose == .original { indexedOriginalBytes += entry.size }
        else { indexedThumbnailBytes += entry.size }
        if originalChanged { publishOriginalCacheChange() }
    }
    private func removeCacheEntry(_ path: String) {
        if cacheScan != nil { pendingCacheChanges[path] = .removed }
        guard cacheIndex != nil else { pendingCacheChanges[path] = .removed; return }
        guard let previous = cacheIndex?.removeValue(forKey: path) else { return }
        if previous.purpose == .original { indexedOriginalBytes -= previous.size }
        else { indexedThumbnailBytes -= previous.size }
        if previous.purpose == .original { publishOriginalCacheChange() }
    }
    private func publishOriginalCacheChange() {
        // A bulk clear/trim can remove thousands of ownerless files without
        // creating thousands of main-actor notification tasks.
        guard !originalCachePublicationPending else { return }
        originalCachePublicationPending = true
        Task {
            await CloudTransferCenter.originalCacheDidChange()
            originalCachePublicationPending = false
        }
    }
    private func cacheEntries() -> [CacheEntry] { Array(cacheIndex?.values ?? Dictionary<String, CacheEntry>().values) }
    private nonisolated static func scanCache(directory: URL) -> [CacheEntry] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentAccessDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        let urls = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])?.allObjects as? [URL] ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return CacheEntry(url: url, size: Int64(values.fileSize ?? 0), date: values.contentAccessDate ?? .distantPast, purpose: url.deletingLastPathComponent() == directory && url.pathExtension == "preview" ? .thumbnail : .original)
        }
    }
}

private actor CloudDownloadGate {
    private struct Waiting { let id: UUID; var priority: CloudTransferPriority; let continuation: CheckedContinuation<Void, Error> }
    private let limit: Int
    private var active = Set<UUID>()
    private var waiting: [Waiting] = []
    private var paused = false
    private var promoted = Set<UUID>()
    init(limit: Int) { self.limit = limit }
    func acquire(_ id: UUID, priority: CloudTransferPriority) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                waiting.append(Waiting(id: id, priority: promoted.contains(id) ? .foreground : priority, continuation: continuation)); drain()
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func release(_ id: UUID) { active.remove(id); promoted.remove(id); drain() }
    func promote(_ id: UUID) { promoted.insert(id); if let index = waiting.firstIndex(where: { $0.id == id }) { waiting[index].priority = .foreground }; drain() }
    func setPaused(_ value: Bool) { paused = value; drain() }
    private func cancel(_ id: UUID) { promoted.remove(id); if let index = waiting.firstIndex(where: { $0.id == id }) { waiting.remove(at: index).continuation.resume(throwing: CancellationError()) } }
    private func drain() {
        while active.count < limit {
            guard let index = waiting.firstIndex(where: { $0.priority == .foreground }) ?? (paused ? nil : waiting.firstIndex(where: { $0.priority == .background })) else { return }
            let work = waiting.remove(at: index); active.insert(work.id); work.continuation.resume()
        }
    }
}

private struct CloudHTTPDownload: Sendable { let response: HTTPURLResponse }
private final class CloudDownloadTransport: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Work {
        let continuation: CheckedContinuation<CloudHTTPDownload, Error>
        let staging: URL
        let maximum: Int64
        let limitError: Error
        let progress: @Sendable (Int64, Int64?) -> Void
        var failure: Error?
        var finished = false
        var lastProgress: TimeInterval = 0
    }
    private let lock = NSLock()
    private var work: [Int: Work] = [:]
    private var session: URLSession!
    override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 1800; config.urlCache = nil
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }
    func invalidate() { session.invalidateAndCancel() }
    func download(_ request: URLRequest, staging: URL, maximum: Int64, limitError: Error,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> CloudHTTPDownload {
        let handle = DownloadHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request)
                lock.withLock { work[task.taskIdentifier] = Work(continuation: continuation, staging: staging, maximum: maximum, limitError: limitError, progress: progress) }
                handle.install(task); task.resume()
            }
        } onCancel: { handle.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        let value: Work? = lock.withLock {
            guard var value = work[downloadTask.taskIdentifier] else { return nil }
            if totalBytesWritten > value.maximum || totalBytesExpectedToWrite > value.maximum { value.failure = value.limitError }
            let notify = now - value.lastProgress >= 0.1 || totalBytesWritten == totalBytesExpectedToWrite
            if notify { value.lastProgress = now }
            work[downloadTask.taskIdentifier] = value
            return notify || value.failure != nil ? value : nil
        }
        guard let value else { return }
        if value.failure != nil { downloadTask.cancel() }
        value.progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.withLock {
            guard var value = work[downloadTask.taskIdentifier] else { return }
            do { try FileManager.default.moveItem(at: location, to: value.staging); value.finished = true }
            catch { value.failure = error }
            work[downloadTask.taskIdentifier] = value
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let value = lock.withLock({ work.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let failure = value.failure ?? error { value.continuation.resume(throwing: failure) }
        else if value.finished, let response = task.response as? HTTPURLResponse { value.continuation.resume(returning: CloudHTTPDownload(response: response)) }
        else { value.continuation.resume(throwing: CloudConnectionError.engineUnavailable) }
    }
    private final class DownloadHandle: @unchecked Sendable {
        private let lock = NSLock(); private var task: URLSessionTask?; private var cancelled = false
        func install(_ task: URLSessionTask) { lock.lock(); self.task = task; let cancel = cancelled; lock.unlock(); if cancel { task.cancel() } }
        func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
    }
}
