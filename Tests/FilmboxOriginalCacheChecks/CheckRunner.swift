import Foundation
import CryptoKit
import Observation
import FilmboxCore

@main @MainActor struct OriginalCacheChecks {
    private static var passed = 0
    private static let date = Date(timeIntervalSince1970: 1_700_000_000)
    private struct Failure: Error { let message: String }
    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
        passed += 1
    }
    static func main() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FilmboxOriginalCacheChecks-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await checkDiskAvailability(directory: directory)
            try await checkNotifications()
            print("\(passed) original-cache checks passed; no account, credential or network access")
        } catch {
            print("FAILED after \(passed): \(error)")
            exit(1)
        }
    }
    private static func item(_ name: String, account: UUID, revision: String = "r1", bytes: Int64 = 8, modified: Date = date) -> MediaItem {
        MediaItem(cloud: CloudMediaReference(accountID: account, fileID: name, parentID: "/", remotePath: "/\(name).jpg", revision: revision),
            kind: .image, fileSize: bytes, modifiedDate: modified, createdDate: date)
    }
    private static func path(_ item: MediaItem, purpose: CloudTransferPurpose, directory: URL) -> URL {
        // Existing on-disk format, independently using the old formatter. This
        // also guards the optimized digest formatter against a cache migration.
        let identity = "\(item.id)|\(item.cloud?.revision ?? "")|\(item.fileSize)|\(item.modifiedDate.timeIntervalSinceReferenceDate)|\(purpose.rawValue)"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return purpose == .original ? directory.appendingPathComponent(digest, isDirectory: true).appendingPathComponent(item.name)
            : directory.appendingPathComponent(digest).appendingPathExtension("preview")
    }
    @discardableResult private static func seed(_ item: MediaItem, bytes: Int, purpose: CloudTransferPurpose = .original, directory: URL) throws -> URL {
        let url = path(item, purpose: purpose, directory: directory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 42, count: bytes).write(to: url)
        return url
    }
    private static func checkDiskAvailability(directory: URL) async throws {
        let account = UUID()
        let complete = item("complete", account: account)
        let preview = item("preview-only", account: account)
        let partial = item("partial", account: account)
        let empty = item("empty", account: account)
        let unknown = item("unknown-size", account: account, bytes: 0)
        let old = item("changed", account: account)
        let changed = item("changed", account: account, revision: "r2")
        let local = MediaItem(url: directory.appendingPathComponent(".local.jpg"), kind: .image, fileSize: 8, modifiedDate: date, createdDate: date)
        let completeURL = try seed(complete, bytes: 8, directory: directory)
        try seed(preview, bytes: 8, purpose: .thumbnail, directory: directory)
        try seed(partial, bytes: 3, directory: directory)
        try seed(empty, bytes: 0, directory: directory)
        try seed(unknown, bytes: 5, directory: directory)
        try seed(old, bytes: 8, directory: directory)
        try Data(repeating: 42, count: 8).write(to: local.url)
        let staging = directory.appendingPathComponent(".incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(repeating: 42, count: 8).write(to: staging.appendingPathComponent("download.partial"))
        let items = [complete, preview, partial, empty, unknown, changed, local]
        let resolver = MediaAssetResolver(directory: directory, diskBudget: 1_024, recentProtectionDuration: 0)
        let available = await resolver.cachedOriginalIDs(for: items)
        try expect(available == [complete.id, unknown.id], "preview, partial, old revision or local file counted as a complete cloud original")
        let restarted = MediaAssetResolver(directory: directory, diskBudget: 1_024, recentProtectionDuration: 0)
        try expect(await restarted.cachedOriginalIDs(for: items) == available, "pre-existing originals were lost after resolver restart")
        let sizes = await resolver.cacheSizes()
        try expect(sizes.originalBytes == 24 && sizes.thumbnailBytes == 8, "cache accounting included staging or lost incomplete-file occupied bytes")
        try FileManager.default.removeItem(at: completeURL)
        try expect(await resolver.cachedOriginalIDs(for: items) == [unknown.id], "externally deleted original remained downloaded")
        let corrected = await resolver.cacheSizes()
        try expect(corrected.originalBytes == 16, "deleted original was not removed from the byte ledger")
        // Repeated queries need no per-item transfer registration and continue
        // to work when no provider has ever been connected in this process.
        let many = (0..<10_000).map { item("uncached-\($0)", account: account) } + [unknown]
        let start = ContinuousClock.now
        try expect(await resolver.cachedOriginalIDs(for: many) == [unknown.id], "large mixed library availability incorrect")
        print("✓ 10,001-item availability query: \(start.duration(to: .now))")
        let cancelled = Task { await resolver.cachedOriginalIDs(for: many) }
        cancelled.cancel()
        try expect(await cancelled.value.isEmpty, "cancelled availability query returned a partial filter result")
        let cleanup = await resolver.clearOriginalCache()
        try expect(cleanup.removedBytes == 16, "clear missed indexed original files")
        try expect(await resolver.cachedOriginalIDs(for: items).isEmpty, "originals remained downloaded after clear")
        try expect((await resolver.cacheSizes()).thumbnailBytes == 8, "clearing originals also removed thumbnail cache")

        let evictionDirectory = directory.appendingPathComponent("eviction", isDirectory: true)
        let first = item("eviction-one", account: account), second = item("eviction-two", account: account)
        try seed(first, bytes: 8, directory: evictionDirectory); try seed(second, bytes: 8, directory: evictionDirectory)
        let evicting = MediaAssetResolver(directory: evictionDirectory, diskBudget: 8, recentProtectionDuration: 0)
        try expect(await evicting.cachedOriginalIDs(for: [first, second]).count == 2, "eviction fixture did not start complete")
        await evicting.trimCache()
        try expect(await evicting.cachedOriginalIDs(for: [first, second]).count == 1, "budget eviction did not update original availability")
    }
    private static func checkNotifications() async throws {
        // Drain changes from the preceding fixture, then watch only this
        // center. The public notification itself holds no catalogue or images.
        try await Task.sleep(for: .milliseconds(180))
        let counter = Counter()
        let observer = NotificationCenter.default.addObserver(forName: .filmboxCloudOriginalCacheChanged, object: nil, queue: nil) { _ in counter.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let center = CloudTransferCenter(defaults: UserDefaults(suiteName: "FilmboxOriginalCacheChecks-\(UUID())")!)
        let account = UUID(), photo = item("notifications", account: UUID())
        let token = UUID()
        center.queued(item: photo, purpose: .original, priority: .foreground, token: token)
        center.started(itemID: photo.id, purpose: .original, token: token)
        center.progress(itemID: photo.id, purpose: .original, token: token, received: 4, total: 8)
        center.cached(item: photo, purpose: .thumbnail, bytes: 2)
        try await Task.sleep(for: .milliseconds(180))
        try expect(counter.value == 0, "progress or thumbnails invalidated downloaded-original filter")
        center.finished(item: photo, purpose: .original, token: token, bytes: 8)
        center.cached(item: photo, purpose: .original, bytes: 8)
        try await Task.sleep(for: .milliseconds(180))
        try expect(counter.value == 1, "completed original did not publish one coalesced availability change")
        center.cacheRemoved(itemID: photo.id, purpose: .thumbnail)
        center.cached(item: photo, purpose: .original, bytes: 8)
        try await Task.sleep(for: .milliseconds(180))
        try expect(counter.value == 1, "cache hits or preview eviction republished original availability")
        center.cacheRemoved(itemID: photo.id, purpose: .original)
        try await Task.sleep(for: .milliseconds(180))
        try expect(counter.value == 2, "original removal was not published")
        let previous = item("same-revision", account: account)
        center.cached(item: previous, purpose: .original, bytes: 8)
        try await Task.sleep(for: .milliseconds(180))
        center.register(item: item("same-revision", account: account, bytes: 9))
        try expect(center.snapshot(for: previous.id)?.isOriginalCached != true, "same-revision size change retained old downloaded badge")
        try await Task.sleep(for: .milliseconds(180))
        try expect(counter.value == 4, "cache identity change was not published")
        let revised = item("revised", account: account)
        center.cached(item: revised, purpose: .original, bytes: 8)
        center.register(item: item("revised", account: account, revision: "r2"))
        try await Task.sleep(for: .milliseconds(180))
        try expect(counter.value == 5, "burst revision changes were not coalesced")
    }
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}
