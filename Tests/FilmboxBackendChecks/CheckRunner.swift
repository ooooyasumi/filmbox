// The script appends this runner to the production backend sources. Private
// fixture helpers stay out of the application API and touch only temp files.
import Foundation
import Observation
import FilmboxCore

private final class BackendEventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

extension MediaAssetResolver {
    fileprivate func fixtureDestination(_ item: MediaItem) -> URL { destination(for: item, purpose: .original) }
    fileprivate func fixtureCheck(_ url: URL) -> Bool { validCache(url, expected: nil) }
    fileprivate func fixtureReserve(_ bytes: Int64, evict: Bool) async throws {
        let token = UUID()
        _ = try await reserve(token: token, bytes: bytes, unknownSize: false, evictIfNeeded: evict)
        reservations[token] = nil
    }
}

extension CloudGateway {
    fileprivate func fixtureUnchangedCredential(_ accountID: UUID) async throws {
        credentialRecords[accountID] = CloudCredentialRecord(credential: "synthetic-unchanged-cookie", username: nil, password: nil)
        for _ in 0..<10_000 { try await updateCredential("synthetic-unchanged-cookie", accountID: accountID) }
        credentialRecords[accountID] = nil
    }
}
extension CloudKeychainWorker {
    fileprivate func fixtureInstall(_ job: CloudKeychainJob) { active = job }
}
extension CloudKeychainJob {
    fileprivate func fixtureUnavailable() { resolve(.failure(CloudConnectionError.credentialsMissing), systemCallFinished: false) }
    fileprivate func fixtureComplete() { resolve(.success(.complete), systemCallFinished: true) }
}

@main @MainActor struct BackendChecks {
    static var passed = 0
    struct Failure: Error { let message: String }
    static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
        passed += 1
    }
    static func item(_ n: Int, account: UUID, bytes: Int64 = 32) -> MediaItem {
        MediaItem(cloud: CloudMediaReference(accountID: account, fileID: "/\(n).jpg", parentID: "/", remotePath: "/\(n).jpg", revision: "r1"),
                  kind: .image, fileSize: bytes, modifiedDate: Date(timeIntervalSince1970: 1_700_000_000), createdDate: Date(timeIntervalSince1970: 1_700_000_000))
    }
    static func main() async {
        let domain = "FilmboxBackendChecks.\(UUID())", defaults = UserDefaults(suiteName: domain)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        var failure: Error?
        do {
            let center = CloudTransferCenter(defaults: defaults), account = UUID()
            let visible = (0..<50).map { item($0, account: account) }
            for value in visible { center.cached(item: value, purpose: .original, bytes: value.fileSize) }
            let hidden = item(900_000, account: account), token = UUID()
            center.queued(item: hidden, purpose: .thumbnail, priority: .background, token: token)
            center.started(itemID: hidden.id, purpose: .thumbnail, token: token)
            let unrelated = BackendEventCounter(), own = BackendEventCounter(), aggregate = BackendEventCounter()
            for value in visible {
                withObservationTracking { _ = center.snapshot(for: value.id) } onChange: { unrelated.increment() }
            }
            withObservationTracking { _ = center.snapshot(for: hidden.id, purpose: .thumbnail) } onChange: { own.increment() }
            withObservationTracking { _ = center.activeCount; _ = center.queuedCount; _ = center.failedCount } onChange: { aggregate.increment() }
            center.progress(itemID: hidden.id, purpose: .thumbnail, token: token, received: 16, total: 32)
            try expect(unrelated.value == 0, "background progress invalidated unrelated visible files")
            try expect(own.value == 1, "file progress did not invalidate its own snapshot")
            try expect(aggregate.value == 0, "byte progress invalidated unchanged task counts")
            let unchanged = BackendEventCounter()
            withObservationTracking { _ = center.snapshot(for: visible[0].id) } onChange: { unchanged.increment() }
            center.cached(item: visible[0], purpose: .original, bytes: visible[0].fileSize)
            try expect(unchanged.value == 0, "a cache inspection republished an unchanged ready state")
            let missing = item(900_001, account: account), appeared = BackendEventCounter()
            withObservationTracking { _ = center.snapshot(for: missing.id, purpose: .thumbnail) } onChange: { appeared.increment() }
            center.queued(item: missing, purpose: .thumbnail, priority: .background, token: UUID())
            try expect(appeared.value == 1, "an initially missing snapshot failed to observe its first task")
            try expect(center.activeCount == 1 && center.queuedCount == 1, "constant-time counts differ from actual states")
            center.requireLogin(accountID: account)
            try expect(center.activeCount == 0 && center.queuedCount == 0 && center.failedCount == 0, "account authentication failures were counted as per-file failures")
            center.failed(itemID: hidden.id, purpose: .thumbnail, token: token, error: CancellationError())
            try expect(center.snapshot(for: hidden.id, purpose: .thumbnail)?.state == .failed, "late cancellation replaced an account failure")
            center.connectionRecovered(accountID: account)
            try expect(center.snapshot(for: hidden.id, purpose: .thumbnail)?.state == .idle, "explicit recovery did not reset the account's failed task")

            let start = ProcessInfo.processInfo.systemUptime
            for n in 1_000..<11_000 {
                let value = item(n, account: account), token = UUID()
                center.queued(item: value, purpose: .thumbnail, priority: .background, token: token)
                center.started(itemID: value.id, purpose: .thumbnail, token: token)
                center.progress(itemID: value.id, purpose: .thumbnail, token: token, received: 32, total: 32)
                center.finished(item: value, purpose: .thumbnail, token: token, bytes: 32)
            }
            print(String(format: "10,000 transfer states: %.3f s", ProcessInfo.processInfo.systemUptime - start))
            try expect(center.tasks.count <= 2_000, "terminal history grew with the whole library")
            try expect(center.activeCount == 0 && center.queuedCount == 0, "completed sweep retained active work")
            let fallback = BackendEventCounter()
            withObservationTracking { _ = center.snapshot(for: visible[0].id)?.isOriginalCached } onChange: { fallback.increment() }
            center.cacheRemoved(itemID: visible[0].id, purpose: .original)
            try expect(fallback.value == 1 && center.snapshot(for: visible[0].id)?.isOriginalCached != true, "pruned cache records lost their per-file invalidation")

            let cache = root.appendingPathComponent("cache")
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            for n in 0..<10_000 { try Data(repeating: 42, count: 32).write(to: cache.appendingPathComponent("\(n).preview")) }
            let resolver = MediaAssetResolver(directory: cache, diskBudget: 64 * 1_024 * 1_024, recentProtectionDuration: 0)
            let originals = item(800_000, account: UUID())
            let originalURL = await resolver.fixtureDestination(originals)
            let scans = (0..<8).map { _ in Task { await resolver.cacheSizes() } }
            try FileManager.default.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 24, count: 32).write(to: originalURL)
            _ = await resolver.inspectCache(for: originals)
            let missingURL = cache.appendingPathComponent("0.preview")
            try FileManager.default.removeItem(at: missingURL)
            try expect(await resolver.fixtureCheck(missingURL) == false, "deleted cache file still validated")
            for scan in scans { _ = await scan.value }
            let indexed = await resolver.cacheSizes()
            try expect(indexed.thumbnailBytes == 9_999 * 32 && indexed.originalBytes == 32, "concurrent cold scan lost a cache hit or deletion")
            try expect(await resolver.hasBackgroundThumbnailCapacity(), "small cache incorrectly stopped preloading")
            let reserveStart = ProcessInfo.processInfo.systemUptime
            for _ in 0..<20 { try await resolver.fixtureReserve(16 * 1_024 * 1_024, evict: false) }
            print(String(format: "20 warm reservations, 10,000 files: %.4f s", ProcessInfo.processInfo.systemUptime - reserveStart))
            let lease = await resolver.acquireViewingLease(for: originals)
            let clear = await resolver.clearCache()
            try expect(clear.removedBytes == 9_999 * 32 && clear.protectedBytes == 32, "indexed cleanup lost its viewing protection/accounting")
            await resolver.releaseViewingLease(lease)
            try expect(await resolver.clearOriginalCache().removedBytes == 32, "released original did not clear")
            try expect(await resolver.cacheSize() == 0, "incremental byte ledger did not reach zero")

            let full = root.appendingPathComponent("full")
            try FileManager.default.createDirectory(at: full, withIntermediateDirectories: true)
            for n in 0..<3 { try Data(repeating: 1, count: 100).write(to: full.appendingPathComponent("\(n).preview")) }
            let limited = MediaAssetResolver(directory: full, diskBudget: 256, recentProtectionDuration: 0, cacheReconciliationInterval: 0)
            try expect(await limited.hasBackgroundThumbnailCapacity() == false, "full cache did not stop the background sweep")
            do { try await limited.fixtureReserve(64, evict: false); throw Failure(message: "background reservation exceeded budget") }
            catch CloudConnectionError.cacheBudgetExceeded { passed += 1 }
            try expect(await limited.cacheSize() == 300, "background capacity pressure evicted existing covers")
            try await limited.fixtureReserve(64, evict: true)
            try expect(await limited.cacheSize() <= 192, "foreground budget pressure did not trim cached files")
            for file in try FileManager.default.contentsOfDirectory(at: full, includingPropertiesForKeys: nil) {
                try FileManager.default.removeItem(at: file)
            }
            try expect(await limited.hasBackgroundThumbnailCapacity(), "OS-purged, unvisited files kept the background queue capacity-paused")
            _ = await limited.clearThumbnailCache()
            try expect(await limited.cacheSize() == 0, "OS-purged files left phantom cache bytes after cleanup")

            // A deliberately unavailable fake Keychain proves that unchanged
            // cookies are handled in memory rather than one daemon call/file.
            let blocked = CloudKeychainJob()
            blocked.fixtureUnavailable()
            await CloudKeychainWorker.shared.fixtureInstall(blocked)
            do { try await CloudGateway.shared.fixtureUnchangedCredential(UUID()) }
            catch { blocked.fixtureComplete(); throw error }
            blocked.fixtureComplete()
            passed += 1
        } catch { failure = error }
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
        if let failure { print("FAILED after \(passed): \(failure)"); exit(1) }
        print("\(passed) backend isolation/cache/observation checks passed; no network or real account used")
    }
}
