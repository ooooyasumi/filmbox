import AppKit
import AVFoundation
import CryptoKit
import CoreImage
import FilmboxCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The image is decoded off the main actor and treated as immutable after creation.
struct Thumbnail: @unchecked Sendable {
    let image: NSImage
    let byteCost: Int
    let isProviderPreview: Bool
    init(image: NSImage, byteCost: Int = 0, isProviderPreview: Bool = false) {
        self.image = image; self.byteCost = byteCost; self.isProviderPreview = isProviderPreview
    }
    func shouldObscure(for item: MediaItem) -> Bool {
        guard !item.isLocal, isProviderPreview else { return false }
        let longest = image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? Int(max(image.size.width, image.size.height))
        return longest < 1024
    }
}

private final class ThumbnailBox: NSObject {
    let thumbnail: Thumbnail

    init(_ thumbnail: Thumbnail) {
        self.thumbnail = thumbnail
    }
}

/// Limits asynchronous video work as well as image decoding. Cancelled queued work
/// is removed before it can open a file or create a video decoder.
private actor MediaWorkLimiter {
    struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var active = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else if active < limit {
                    active += 1
                    continuation.resume(returning: true)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiting(id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            let next = waiters.removeFirst()
            next.continuation.resume(returning: true)
        }
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

enum ThumbnailLoadResult: Sendable {
    case ready(Thumbnail)
    case cancelled
    case unavailable
    case failed
    case noCloudPreview
}

enum ThumbnailPreloadResult: Sendable { case ready, noCloudPreview, cancelled, unavailable, failed }

enum PreviewCacheCategory: String, CaseIterable, Identifiable, Sendable {
    case local, cloud, highResolution, legacy
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .local: "本地媒体缩略图"
        case .cloud: "云端媒体缩略图"
        case .highResolution: "高清预览"
        case .legacy: "旧版预览"
        }
    }
}

private struct ThumbnailCacheCandidate: Sendable {
    let key: String
    let pixelSize: Int
}

extension Notification.Name {
    static let filmboxCloudOriginalPreviewReady = Notification.Name("FilmboxCloudOriginalPreviewReady")
}

actor ThumbnailService {
    static let shared = ThumbnailService()

    private struct InFlight {
        let id: UUID
        let task: Task<ThumbnailLoadResult, Never>
        var consumers: Set<UUID>
        var started = false
        let cancelWhenUnobserved: Bool
    }
    private let memory = NSCache<NSString, ThumbnailBox>()
    private let limiter = MediaWorkLimiter(limit: 3)
    private let originalPreviewLimiter = MediaWorkLimiter(limit: 1)
    private var originalPreviews: [String: (id: UUID, task: Task<Bool, Never>)] = [:]
    private static let originalPreviewSize = 2560
    private let diskDirectory: URL
    private let budgetOverride: Int64?
    private let diskMutations = ThumbnailDiskMutations()
    private var inFlight: [String: InFlight] = [:]
    private var pruneTask: Task<Void, Never>?
    private var pruneID: UUID?
    private var bytesSincePrune: Int64 = 0
    private var lastPrune = Date.distantPast

    init(cacheDirectory: URL? = nil, diskBudget: Int64? = nil) {
        memory.totalCostLimit = 64 * 1_024 * 1_024
        memory.countLimit = 192
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        var root = caches.appendingPathComponent("com.filmbox.app", isDirectory: true)
        #if DEBUG
        if let path = Bundle.main.object(forInfoDictionaryKey: "FilmboxDevelopmentCache") as? String { root = URL(fileURLWithPath: path, isDirectory: true) }
        #endif
        diskDirectory = cacheDirectory ?? root.appendingPathComponent("thumbs", isDirectory: true)
        budgetOverride = diskBudget
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    static func previewSize(for requested: Int) -> Int {
        if requested <= 256 { return 256 }
        if requested <= 768 { return 768 }
        if requested <= 1600 { return 1600 }
        return 4096
    }

    /// Full-library warming persists the provider cover and reads its header.
    /// It does not decode pixels, create NSImage, or compete with viewed images.
    func preloadCloudThumbnail(for item: MediaItem,
        loadPreview: @Sendable (MediaItem) async throws -> URL = { item in
            try await MediaAssetResolver.shared.thumbnailFile(for: item, priority: .background)
        }) async -> ThumbnailPreloadResult {
        guard item.cloud != nil, !Task.isCancelled else { return .cancelled }
        do {
            let url = try await loadPreview(item)
            guard !Task.isCancelled else { return .cancelled }
            let dimensions = await Task.detached(priority: .utility) { () -> (Int, Int)? in
                guard url.isFileURL else { return nil }
                return autoreleasepool {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? Int,
                          let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
                    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
                    return (5...8).contains(orientation) ? (height, width) : (width, height)
                }
            }.value
            guard !Task.isCancelled else { return .cancelled }
            if let dimensions { CloudPreviewMetadata.report(item: item, width: dimensions.0, height: dimensions.1) }
            return .ready
        } catch CloudConnectionError.thumbnailUnavailable { return .noCloudPreview }
        catch CloudConnectionError.credentialsMissing { return .unavailable }
        catch is CancellationError { return .cancelled }
        catch { return .failed }
    }

    func thumbnail(for url: URL, kind: MediaKind, modifiedDate: Date, pixelSize: Int, priority: CloudTransferPriority = .foreground, localRevision: String? = nil) async -> Thumbnail? {
        if case let .ready(image) = await loadThumbnail(for: url, kind: kind, modifiedDate: modifiedDate, pixelSize: pixelSize, priority: priority, localRevision: localRevision) { return image }
        return nil
    }

    /// Only consult memory/disk. This also works when the source disk is offline.
    func cachedThumbnail(for url: URL, kind: MediaKind, modifiedDate: Date, pixelSize: Int, localRevision: String? = nil) async -> Thumbnail? {
        let snapshot = CloudMediaRegistry.shared.item(for: url)
        let size = Self.previewSize(for: pixelSize)
        if let item = snapshot, size < 4096 || kind == .video,
           let preview = await originalPreview(for: item, size: size, generate: false) { return preview }
        let key = cacheKey(url: url, modifiedDate: modifiedDate, pixelSize: size, snapshot: snapshot, localRevision: localRevision)
        if let cached = memory.object(forKey: key as NSString) {
            reportCloudPreview(cached.thumbnail, item: snapshot)
            return cached.thumbnail
        }
        let candidates = cacheCandidates(url: url, modifiedDate: modifiedDate, size: size, requested: pixelSize, snapshot: snapshot, localRevision: localRevision)
        guard await limiter.acquire() else { return nil }
        let task = Task.detached(priority: .userInitiated) { [diskDirectory] in
            ThumbnailDiskCache.read(directory: diskDirectory, keys: candidates, pixelSize: size, cloud: !url.isFileURL)
        }
        let hit = await task.value
        await limiter.release()
        guard !Task.isCancelled, let hit else { return nil }
        if let item = snapshot, item.previewAspectRatio == nil {
            CloudPreviewMetadata.report(item: item, image: hit.image)
        }
        // A small progressive preview must not poison the completed high-res key.
        return remember(hit.image, key: hit.candidate.pixelSize >= size ? key : hit.candidate.key, isProviderPreview: snapshot != nil && hit.candidate.pixelSize < 4096)
    }

    func loadThumbnail(for url: URL, kind: MediaKind, modifiedDate: Date, pixelSize: Int,
                       priority: CloudTransferPriority = .foreground, localRevision: String? = nil) async -> ThumbnailLoadResult {
        guard !Task.isCancelled else { return .cancelled }
        let size = Self.previewSize(for: pixelSize)
        let snapshot = CloudMediaRegistry.shared.item(for: url)
        if let item = snapshot, size < 4096 || kind == .video,
           let preview = await originalPreview(for: item, size: size, generate: true) {
            return Task.isCancelled ? .cancelled : .ready(preview)
        }
        let key = cacheKey(url: url, modifiedDate: modifiedDate, pixelSize: size, snapshot: snapshot, localRevision: localRevision)
        if let cached = memory.object(forKey: key as NSString) {
            reportCloudPreview(cached.thumbnail, item: snapshot)
            return .ready(cached.thumbnail)
        }
        let consumer = UUID()
        let work: InFlight
        if var existing = inFlight[key], !existing.task.isCancelled {
            existing.consumers.insert(consumer)
            inFlight[key] = existing
            work = existing
            if priority == .foreground, !url.isFileURL { await MediaAssetResolver.shared.promoteThumbnail(for: url) }
        } else {
            let id = UUID()
            let candidates = cacheCandidates(url: url, modifiedDate: modifiedDate, size: size, requested: pixelSize, allowSmaller: false, snapshot: snapshot, localRevision: localRevision)
            let task = Task(priority: priority == .background ? .utility : .userInitiated) {
                let result = await self.makeThumbnail(url: url, kind: kind, size: size, modifiedDate: modifiedDate, key: key, candidates: candidates, workID: id, priority: priority, snapshot: snapshot, localRevision: localRevision)
                self.complete(key: key, workID: id)
                return result
            }
            // A focused cloud photo owns its original download. Unlike a small
            // decode, continuing after its last viewer leaves wastes traffic.
            work = InFlight(id: id, task: task, consumers: [consumer],
                cancelWhenUnobserved: snapshot?.kind == .image && !url.isFileURL && size >= 4096)
            inFlight[key] = work
        }
        let result = await withTaskCancellationHandler {
            await work.task.value
        } onCancel: {
            Task { await self.cancelConsumer(consumer, key: key, workID: work.id) }
        }
        guard !Task.isCancelled else { return .cancelled }
        if case let .ready(thumbnail) = result, priority == .foreground, size <= 1600 {
            return .ready(remember(thumbnail, key: key))
        }
        return result
    }

    /// Keep one original-derived poster on disk, never a library of decoded
    /// originals. This work is local-only, serialized and shared across sizes.
    @discardableResult
    func prepareCloudOriginalPreview(for item: MediaItem, originalURL: URL, repair: Bool = false) async -> Bool {
        guard item.cloud != nil, originalURL.isFileURL else { return false }
        let key = originalPreviewKey(item: item, size: Self.originalPreviewSize)
        if let work = originalPreviews[key] { return await work.task.value }
        let destination = originalPreviewURL(item)
        if !repair {
            let valid = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(destination as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
                return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0) > 0
                    && (properties[kCGImagePropertyPixelHeight] as? Int ?? 0) > 0
            }.value
            if valid { return true }
        }
        if let work = originalPreviews[key] { return await work.task.value }
        let epoch = await diskMutations.generation(for: .highResolution)
        if let work = originalPreviews[key] { return await work.task.value }
        let id = UUID()
        let task = Task(priority: .utility) { await self.makeOriginalPreview(item, url: originalURL, destination: destination, epoch: epoch) }
        originalPreviews[key] = (id, task)
        let result = await task.value
        if originalPreviews[key]?.id == id { originalPreviews[key] = nil }
        return result
    }

    private func makeOriginalPreview(_ item: MediaItem, url: URL, destination: URL, epoch: Int) async -> Bool {
        guard await originalPreviewLimiter.acquire() else { return false }
        let lease = await MediaAssetResolver.shared.acquireViewingLease(for: item)
        let decoder = Task.detached(priority: .utility) { () -> CGImage? in
            await ThumbnailDecoder.localOriginalPreview(item: item, url: url, pixelSize: Self.originalPreviewSize)
        }
        let image = await withTaskCancellationHandler { await decoder.value } onCancel: { decoder.cancel() }
        var bytes: Int64 = 0
        if !Task.isCancelled, let image {
            bytes = await diskMutations.persist(image, to: destination, category: .highResolution, generation: epoch)
        }
        await MediaAssetResolver.shared.releaseViewingLease(lease)
        await originalPreviewLimiter.release()
        guard bytes > 0, !Task.isCancelled else { return false }
        bytesSincePrune += bytes
        schedulePrune()
        await MainActor.run {
            NotificationCenter.default.post(name: .filmboxCloudOriginalPreviewReady, object: nil,
                userInfo: ["id": item.id, "revision": item.cloud!.revision, "fileSize": item.fileSize, "modifiedDate": item.modifiedDate])
        }
        return true
    }

    private func originalPreview(for item: MediaItem, size: Int, generate: Bool) async -> Thumbnail? {
        let key = originalPreviewKey(item: item, size: size)
        if let cached = memory.object(forKey: key as NSString) { return cached.thumbnail }
        if let image = await readOriginalPreview(item: item, size: size) { return remember(image, key: key) }
        guard generate, !Task.isCancelled,
              let original = await MediaAssetResolver.shared.cachedOriginalFile(for: item),
              await prepareCloudOriginalPreview(for: item, originalURL: original, repair: true), !Task.isCancelled,
              let image = await readOriginalPreview(item: item, size: size) else { return nil }
        return remember(image, key: key)
    }

    private func readOriginalPreview(item: MediaItem, size: Int) async -> CGImage? {
        let url = originalPreviewURL(item)
        // Existing verified photo previews are also original-derived. Reuse
        // them before old covers, including when the raw original was evicted.
        let verified = item.kind == .image ? diskDirectory.appendingPathComponent(PreviewCacheCategory.highResolution.rawValue)
            .appendingPathComponent(cacheKey(url: item.url, modifiedDate: item.modifiedDate, pixelSize: 4096, snapshot: item))
            .appendingPathExtension("thumb") : nil
        guard await limiter.acquire() else { return nil }
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            for candidate in [url, verified].compactMap({ $0 }) {
                if FileManager.default.fileExists(atPath: candidate.path),
                   let image = ThumbnailDecoder.downsample(url: candidate, pixelSize: size) {
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: candidate.path)
                    return image
                }
            }
            return nil as CGImage?
        }.value
        await limiter.release()
        return Task.isCancelled ? nil : image
    }

    private func originalPreviewURL(_ item: MediaItem) -> URL {
        diskDirectory.appendingPathComponent(PreviewCacheCategory.highResolution.rawValue, isDirectory: true)
            .appendingPathComponent(originalPreviewKey(item: item, size: Self.originalPreviewSize)).appendingPathExtension("thumb")
    }
    private func originalPreviewKey(item: MediaItem, size: Int) -> String {
        let identity = "cloud-original-poster-v1|\(item.id)|\(item.cloud?.revision ?? "")|\(item.fileSize)|\(item.modifiedDate.timeIntervalSince1970.bitPattern)|\(size)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func clearCache() async {
        // Keep valid visible requests alive. Their successful result may repopulate
        // the cache; a cache operation must not create a false decoding error.
        memory.removeAllObjects()
        originalPreviews.values.forEach { $0.task.cancel() }
        originalPreviews.removeAll()
        pruneTask?.cancel()
        pruneTask = nil
        pruneID = nil
        await diskMutations.clear(directory: diskDirectory)
        bytesSincePrune = 0
        lastPrune = .distantPast
    }

    func cacheSize() async -> Int64 {
        let directory = diskDirectory
        return await Task.detached(priority: .utility) { ThumbnailDiskCache.entries(directory: directory).reduce(0) { $0 + $1.size } }.value
    }

    func cacheSizes() async -> [PreviewCacheCategory: Int64] {
        let directory = diskDirectory
        return await Task.detached(priority: .utility) {
            Dictionary(grouping: ThumbnailDiskCache.entries(directory: directory), by: { ThumbnailDiskCache.category(of: $0.url) })
                .mapValues { $0.reduce(Int64(0)) { $0 + $1.size } }
        }.value
    }

    func clearCache(categories: Set<PreviewCacheCategory>) async {
        guard !categories.isEmpty else { return }
        memory.removeAllObjects()
        if categories.contains(.highResolution) {
            originalPreviews.values.forEach { $0.task.cancel() }
            originalPreviews.removeAll()
        }
        await diskMutations.clear(directory: diskDirectory, categories: categories)
    }

    func trimCache() { schedulePrune(force: true) }

    private func complete(key: String, workID: UUID) {
        if inFlight[key]?.id == workID { inFlight.removeValue(forKey: key) }
    }
    private func cancelConsumer(_ consumer: UUID, key: String, workID: UUID) {
        guard var work = inFlight[key], work.id == workID else { return }
        work.consumers.remove(consumer)
        if work.consumers.isEmpty && (!work.started || work.cancelWhenUnobserved) {
            work.task.cancel()
            inFlight.removeValue(forKey: key)
        } else {
            // Finish an already-started decode and persist it, even after a fast
            // scroll. A new visible cell can rejoin the same work instead of
            // cancelling/restarting AVFoundation or an expensive RAW development.
            inFlight[key] = work
        }
    }

    private func makeThumbnail(url: URL, kind: MediaKind, size: Int, modifiedDate: Date, key: String, candidates: [ThumbnailCacheCandidate], workID: UUID, priority: CloudTransferPriority, snapshot: MediaItem?, localRevision: String?) async -> ThumbnailLoadResult {
        let directory = diskDirectory
        let category: PreviewCacheCategory = size >= 1600 ? .highResolution : (url.isFileURL ? .local : .cloud)
        let cacheEpoch = await diskMutations.generation(for: category)
        guard await limiter.acquire() else { return .cancelled }
        let cached = await Task.detached(priority: priority == .background ? .utility : .userInitiated) {
            ThumbnailDiskCache.read(directory: directory, keys: candidates, pixelSize: size, cloud: !url.isFileURL)
        }.value
        await limiter.release()
        guard !Task.isCancelled else { return .cancelled }
        if let cached {
            if let item = snapshot, item.previewAspectRatio == nil {
                CloudPreviewMetadata.report(item: item, image: cached.image)
            }
            return .ready(wrap(cached.image, isProviderPreview: snapshot != nil && cached.candidate.pixelSize < 4096))
        }
        guard !url.isFileURL || FileManager.default.isReadableFile(atPath: url.path) else {
            if size < 4096, let preview = await cachedThumbnail(for: url, kind: kind, modifiedDate: modifiedDate, pixelSize: size, localRevision: localRevision) { return .ready(preview) }
            return .unavailable
        }
        if let item = snapshot, let cloud = item.cloud,
           await CloudTransferCenter.shared.issue(for: cloud.accountID) != nil {
            // Local preview/cover/original caches remain useful while signed out.
            // Uncached work must not queue behind unrelated local decoders.
            let original = await MediaAssetResolver.shared.inspectCache(for: item)
            let cover = await CloudTransferCenter.shared.snapshot(for: item.id, purpose: .thumbnail)
            guard original?.isOriginalCached == true || cover?.state == .ready else { return .unavailable }
        }
        guard await limiter.acquire() else { return .cancelled }
        guard !Task.isCancelled, var work = inFlight[key], work.id == workID else {
            await limiter.release()
            return .cancelled
        }
        work.started = true
        inFlight[key] = work
        let decode = Task.detached(priority: .utility) { () -> (CGImage?, Bool) in
            if let item = snapshot {
                do { return (try await ThumbnailDecoder.cloudPreview(item: item, pixelSize: size, priority: priority), false) }
                catch CloudConnectionError.thumbnailUnavailable { return (nil, true) }
                catch { return (nil, false) }
            }
            return (await ThumbnailDecoder.decode(url: url, kind: kind, pixelSize: size), false)
        }
        let (image, missingCover) = await withTaskCancellationHandler {
            await decode.value
        } onCancel: {
            // Detached decoding otherwise outlives the coalesced request and
            // keeps its resolver consumer (and URLSession body) alive.
            decode.cancel()
        }
        await limiter.release()
        guard !Task.isCancelled else { return .cancelled }
        if missingCover { return .noCloudPreview }
        guard let image else { return .failed }
        if let item = snapshot {
            CloudPreviewMetadata.report(item: item, image: image)
        }
        let destination = directory.appendingPathComponent(category.rawValue, isDirectory: true).appendingPathComponent(key).appendingPathExtension("thumb")
        let byteCount = await diskMutations.persist(image, to: destination, category: category, generation: cacheEpoch)
        bytesSincePrune += byteCount
        schedulePrune()
        return .ready(wrap(image, isProviderPreview: snapshot != nil && size < 4096))
    }

    private static let softPreviewContext = CIContext(options: [.cacheIntermediates: false])
    nonisolated static func softenProviderPreview(_ image: CGImage) -> CGImage {
        guard max(image.width, image.height) < 1024 else { return image }
        let source = CIImage(cgImage: image)
        let softened = source.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(2, Double(max(image.width, image.height)) * 0.025)])
            .cropped(to: source.extent)
        return softPreviewContext.createCGImage(softened, from: source.extent) ?? image
    }
    private func wrap(_ image: CGImage, isProviderPreview: Bool = false) -> Thumbnail {
        // Soften the tiny bitmap once off the main actor. A live filter on a
        // full-size scroll canvas would allocate a much larger render surface.
        let display = isProviderPreview ? Self.softenProviderPreview(image) : image
        return Thumbnail(image: NSImage(cgImage: display, size: NSSize(width: display.width, height: display.height)), byteCost: display.bytesPerRow * display.height, isProviderPreview: isProviderPreview)
    }
    private func remember(_ thumbnail: Thumbnail, key: String) -> Thumbnail {
        if let existing = memory.object(forKey: key as NSString) { return existing.thumbnail }
        memory.setObject(ThumbnailBox(thumbnail), forKey: key as NSString, cost: thumbnail.byteCost)
        return thumbnail
    }
    private func remember(_ image: CGImage, key: String, isProviderPreview: Bool = false) -> Thumbnail {
        if let existing = memory.object(forKey: key as NSString) { return existing.thumbnail }
        return remember(wrap(image, isProviderPreview: isProviderPreview), key: key)
    }

    private func reportCloudPreview(_ thumbnail: Thumbnail, item: MediaItem?) {
        guard let item, item.previewAspectRatio == nil,
              let image = thumbnail.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CloudPreviewMetadata.report(item: item, image: image)
    }

    private func cacheKey(url: URL, modifiedDate: Date, pixelSize: Int, snapshot: MediaItem? = nil, localRevision: String? = nil) -> String {
        let identity: String
        if url.isFileURL { identity = url.standardizedFileURL.path + (localRevision.map { "|local-v2|" + $0 } ?? "") }
        else if let item = snapshot ?? CloudMediaRegistry.shared.item(for: url) { identity = item.id + "|" + (item.cloud?.revision ?? "") }
        else { identity = url.absoluteString }
        // Earlier cloud viewer entries could contain a provider cover after an
        // original failed. They cannot establish that a full preview is ready.
        // Originals and all ordinary thumbnails keep their existing cache keys.
        let version = !url.isFileURL && pixelSize >= 4096 ? "cloud-original-v2" : "v1"
        let value = "\(version)\u{0}\(identity)\u{0}\(modifiedDate.timeIntervalSince1970.bitPattern)\u{0}\(pixelSize)"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func cacheCandidates(url: URL, modifiedDate: Date, size: Int, requested: Int, allowSmaller: Bool = true, snapshot: MediaItem? = nil, localRevision: String? = nil) -> [ThumbnailCacheCandidate] {
        // Reuse larger cached previews, plus old exact-size grid/inspector entries.
        // Ordinary previews retain v1; cloud viewer-size entries require the
        // verified original path introduced with cloud-original-v2.
        var sizes = [size] + [768, 1600, 4096].filter { $0 > size }
        if allowSmaller { sizes += [requested, 1600, 768, 640, 512, 384, 256, 192] }
        var seen = Set<Int>()
        return sizes.filter { seen.insert($0).inserted }.map { ThumbnailCacheCandidate(key: cacheKey(url: url, modifiedDate: modifiedDate, pixelSize: $0, snapshot: snapshot, localRevision: localRevision), pixelSize: $0) }
    }
    private func schedulePrune(force: Bool = false) {
        guard pruneTask == nil, force || bytesSincePrune >= 32 * 1024 * 1024 || Date().timeIntervalSince(lastPrune) > 60 else { return }
        bytesSincePrune = 0
        lastPrune = Date()
        let directory = diskDirectory
        let preference = UserDefaults.standard.object(forKey: "thumbnailCacheLimitGB") as? Double ?? 2
        let gib = preference.isFinite ? min(8.0, max(0.5, preference)) : 2.0
        let budget = budgetOverride ?? Int64(gib * 1_073_741_824.0)
        let id = UUID()
        pruneID = id
        let mutations = diskMutations
        pruneTask = Task.detached(priority: .utility) {
            await mutations.prune(directory: directory, budget: budget)
            await self.didPrune(id: id)
        }
    }
    private func didPrune(id: UUID) {
        guard pruneID == id else { return }
        pruneTask = nil
        pruneID = nil
    }
}

/// Serialize mutations without holding the request/coalescing actor. Reads use
/// atomic cache files and can continue while an unrelated original is decoding.
private actor ThumbnailDiskMutations {
    private var generations: [PreviewCacheCategory: Int] = [:]
    func generation(for category: PreviewCacheCategory) -> Int { generations[category, default: 0] }
    func clear(directory: URL) {
        for category in PreviewCacheCategory.allCases { generations[category, default: 0] += 1 }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func persist(_ image: CGImage, to url: URL, category: PreviewCacheCategory, generation: Int) -> Int64 {
        guard generations[category, default: 0] == generation else { return 0 }
        return ThumbnailDiskCache.persist(image, to: url)
    }
    func prune(directory: URL, budget: Int64) { ThumbnailDiskCache.prune(directory: directory, budget: budget) }
    func clear(directory: URL, categories: Set<PreviewCacheCategory>) {
        for category in categories { generations[category, default: 0] += 1 }
        for entry in ThumbnailDiskCache.entries(directory: directory)
            where categories.contains(ThumbnailDiskCache.category(of: entry.url)) {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }
}

private enum ThumbnailDiskCache {
    struct Entry: Sendable { let url: URL; let size: Int64; let date: Date }
    struct Hit: Sendable { let image: CGImage; let candidate: ThumbnailCacheCandidate }
    static func read(directory: URL, keys: [ThumbnailCacheCandidate], pixelSize: Int, cloud: Bool) -> Hit? {
        for candidate in keys {
            let category: PreviewCacheCategory = candidate.pixelSize >= 1600 ? .highResolution : (cloud ? .cloud : .local)
            let categorized = directory.appendingPathComponent(category.rawValue).appendingPathComponent(candidate.key).appendingPathExtension("thumb")
            let legacy = directory.appendingPathComponent(candidate.key).appendingPathExtension("thumb")
            let url = FileManager.default.fileExists(atPath: categorized.path) ? categorized : legacy
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let image = ThumbnailDecoder.downsample(url: url, pixelSize: pixelSize) {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
                return Hit(image: image, candidate: candidate)
            }
            // A concurrent decode may already have atomically repaired this path.
            // Skip bad bytes here; only the mutation lane replaces/prunes files.
        }
        return nil
    }
    static func persist(_ image: CGImage, to url: URL) -> Int64 {
        autoreleasepool {
            let alpha = image.alphaInfo
            let type = [CGImageAlphaInfo.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(alpha) ? UTType.png : .jpeg
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return 0 }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return 0 }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (data as Data).write(to: url, options: .atomic)
                return Int64(data.length)
            } catch { return 0 }
        }
    }
    static func entries(directory: URL) -> [Entry] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])?.allObjects as? [URL] ?? []
        return files.compactMap { url in
            guard url.pathExtension == "thumb", let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return Entry(url: url, size: Int64(values.fileSize ?? 0), date: values.contentModificationDate ?? .distantPast)
        }
    }
    static func category(of url: URL) -> PreviewCacheCategory {
        PreviewCacheCategory(rawValue: url.deletingLastPathComponent().lastPathComponent) ?? .legacy
    }
    static func prune(directory: URL, budget: Int64) {
        let entries = entries(directory: directory)
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard !Task.isCancelled, total > budget else { break }
            let current = try? entry.url.resourceValues(forKeys: [.contentModificationDateKey])
            if let date = current?.contentModificationDate, date > entry.date { continue }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil { total -= entry.size }
        }
    }
}

struct VideoDetails: Sendable {
    let duration: Double
    let width: Int
    let height: Int
    let codec: String?
}

actor DetailsService {
    static let shared = DetailsService()

    private let limiter = MediaWorkLimiter(limit: 2)
    private var cache: [String: VideoDetails] = [:]

    func videoDetails(url: URL) async -> VideoDetails? {
        guard !Task.isCancelled else { return nil }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = "\(url.standardizedFileURL.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)|\(LocalFileRevision.stamp(at: url) ?? "")"
        if let cached = cache[key] { return cached }
        guard await limiter.acquire() else { return nil }
        let details = await readVideoDetails(url: url)
        await limiter.release()
        guard !Task.isCancelled, let details else { return nil }
        if cache.count >= 512 { cache.removeAll(keepingCapacity: true) }
        cache[key] = details
        return details
    }

    private func readVideoDetails(url: URL) async -> VideoDetails? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            guard !Task.isCancelled, let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let (size, transform, descriptions) = try await track.load(.naturalSize, .preferredTransform, .formatDescriptions)
            guard !Task.isCancelled else { return nil }
            let displayed = CGRect(origin: .zero, size: size).applying(transform).standardized.size
            let codec = descriptions.first.map { description in
                let value = CMFormatDescriptionGetMediaSubType(description)
                let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
                return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? nil
            return VideoDetails(
                duration: duration.seconds.isFinite ? max(0, duration.seconds) : 0,
                width: Int(displayed.width.rounded()),
                height: Int(displayed.height.rounded()),
                codec: codec
            )
        } catch {
            guard !Task.isCancelled, let compatible = await MediaCodecRuntime.videoMetadata(at: url),
                  let width = compatible.width, let height = compatible.height else { return nil }
            return VideoDetails(duration: compatible.duration ?? 0, width: width, height: height, codec: compatible.codec)
        }
    }
}
