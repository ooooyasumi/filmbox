import AppKit
import Darwin
import FilmboxCore
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// No windows, network accounts, user catalogue or shared cache. This runner
/// links the real app objects and uses only synthetic records and temporary JPEGs.
@main @MainActor struct PerformanceChecks {
    static var assertions = 0
    static var baseline = false
    static var metrics: [String: Double] = [:]
    static let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    static func main() async {
        baseline = CommandLine.arguments.contains("--baseline")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FilmboxPerformance-\(UUID())", isDirectory: true)
        var failure: Error?
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let heartbeat = Heartbeat()
            heartbeat.start()
            let startingRSS = residentBytes()
            try await metadata(root: root, heartbeat: heartbeat)
            try await transfers(root: root, heartbeat: heartbeat)
            try await bitmapCache(root: root, heartbeat: heartbeat)
            #if !PERFORMANCE_BASELINE_061
            if !CommandLine.arguments.contains("--compare-only") {
                try await rawCloudPreloading(root: root, heartbeat: heartbeat)
            }
            #endif
            await heartbeat.settle()
            metrics["rssStartMiB"] = Double(startingRSS) / 1_048_576
            metrics["rssEndMiB"] = Double(residentBytes()) / 1_048_576
            metrics["rssPeakMiB"] = Double(peakResidentBytes()) / 1_048_576
            metrics["mainActorWorstDelayMs"] = heartbeat.worstDelay * 1000
            metrics["backgroundMainActorWorstDelayMs"] = ["metadataWorkWorstDelayMs", "transferWorkWorstDelayMs", "bitmapWorkWorstDelayMs", "rawPreloadWorkWorstDelayMs"]
                .map { metrics[$0, default: 0] }.max() ?? 0
            heartbeat.stop()
            try policy(metrics["backgroundMainActorWorstDelayMs", default: 0] < 250, "后台工作使 MainActor 单次阻塞超过250毫秒")
        } catch { failure = error }
        try? FileManager.default.removeItem(at: root)
        if let output = argument(after: "--report"), let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        for key in metrics.keys.sorted() { print(String(format: "%@: %.2f", key, metrics[key]!)) }
        if let failure { print("FAILED: \(failure)"); exit(1) }
        print("\(assertions) performance assertions passed\(baseline ? " (baseline: policy regressions recorded only)" : "")")
    }

    private static func metadata(root: URL, heartbeat: Heartbeat) async throws {
        let account = UUID()
        let items = (0..<10_000).map { item($0, account: account) }
        let catalogue = root.appendingPathComponent("Catalogue", isDirectory: true)
        // No libraries means there is no launch scan or authentication path.
        try CatalogPersistence(directory: catalogue).save(CatalogState(libraries: [], cachedItems: items))
        let store = AppStore(directory: catalogue)
        store.query = "Visible-"
        try check(store.items.count == 10_000 && store.visibleItems.count == 20, "一万记录夹具或可见子集不正确")
        await heartbeat.settle()
        metrics["metadataSetupWorstDelayMs"] = heartbeat.phaseWorstDelay * 1000
        heartbeat.resetPhase()
        let beforeVisible = store.visibleRevision, beforeTimeline = store.timelineRevision
        #if !PERFORMANCE_BASELINE_061
        let beforeMetadata = store.mediaMetadataRevision
        #endif
        let invisible = Array(items.dropFirst(20))
        let start = ProcessInfo.processInfo.systemUptime
        var worstBatch = 0.0
        for offset in stride(from: 0, to: invisible.count, by: 200) {
            let values = invisible[offset..<min(invisible.count, offset + 200)].map { media -> [AnyHashable: Any] in
                ["id": media.id, "revision": "perf-r1", "ratio": 1.5, "camera": "Indexed Camera"]
            }
            let batch = ProcessInfo.processInfo.systemUptime
            store.commitCloudMetadata(values)
            worstBatch = max(worstBatch, ProcessInfo.processInfo.systemUptime - batch)
            await Task.yield()
        }
        metrics["metadata10000Seconds"] = ProcessInfo.processInfo.systemUptime - start
        metrics["metadataWorstBatchMs"] = worstBatch * 1000
        metrics["invisibleVisibleRevisionDelta"] = Double(store.visibleRevision - beforeVisible)
        metrics["invisibleTimelineRevisionDelta"] = Double(store.timelineRevision - beforeTimeline)
        try check(store.items.last?.camera == "Indexed Camera", "不可见媒体的元数据没有合并")
        try policy(store.visibleRevision == beforeVisible && store.timelineRevision == beforeTimeline,
                   "不可见媒体元数据触发可见几何 revision")
        #if !PERFORMANCE_BASELINE_061
        try check(store.mediaMetadataRevision == beforeMetadata, "不可见媒体仍发布可见 metadata delta")
        #endif
        let visible = items[0]
        store.commitCloudMetadata([["id": visible.id, "revision": "perf-r1", "ratio": 0.75]])
        try check(store.visibleItems.first(where: { $0.id == visible.id })?.previewAspectRatio == 0.75,
                  "可见媒体比例没有更新")
        #if PERFORMANCE_BASELINE_061
        try check(store.timelineRevision > beforeTimeline, "可见比例变化没有发布布局 revision")
        #else
        try check(store.visibleRevision == beforeVisible && store.timelineRevision == beforeTimeline,
                  "可见元数据复用了结构 revision")
        let delta = store.mediaMetadataChanges(since: beforeMetadata)
        try check(delta?.changedIDs == [visible.id] && delta?.geometryChangedIDs == [visible.id], "比例更新没有精确发布几何 delta")
        let beforeCamera = store.mediaMetadataRevision
        store.commitCloudMetadata([["id": visible.id, "revision": "perf-r1", "camera": "Visible Camera"]])
        let cameraDelta = store.mediaMetadataChanges(since: beforeCamera)
        try check(cameraDelta?.changedIDs == [visible.id] && cameraDelta?.geometryChangedIDs.isEmpty == true,
                  "相机文本变化触发了几何 delta")
        #endif
        let burstStart = ProcessInfo.processInfo.systemUptime
        let burstVisible = store.visibleRevision, burstTimeline = store.timelineRevision
        for media in invisible {
            store.applyCloudMetadata(Notification(name: CloudPreviewMetadata.notification,
                userInfo: ["id": media.id, "revision": "perf-r1", "camera": "Notification Burst"]))
        }
        metrics["notificationEnqueue10000Ms"] = (ProcessInfo.processInfo.systemUptime - burstStart) * 1000
        try await wait(seconds: 15) {
            store.items.last?.camera == "Notification Burst"
                && store.items.filter { $0.camera == "Notification Burst" }.count == invisible.count
        }
        try check(store.items.filter { $0.camera == "Notification Burst" }.count == invisible.count,
                  "后台通知只合并了部分媒体")
        metrics["notificationBurst10000Seconds"] = ProcessInfo.processInfo.systemUptime - burstStart
        try policy(store.visibleRevision == burstVisible && store.timelineRevision == burstTimeline,
                   "后台通知合并仍触发不可见媒体的可见布局更新")
        await heartbeat.settle()
        metrics["metadataWorkWorstDelayMs"] = heartbeat.phaseWorstDelay * 1000
        #if !PERFORMANCE_BASELINE_061
        if !CommandLine.arguments.contains("--compare-only") {
            try await racingMetadataNotifications(store: store, items: invisible)
        }
        #endif
        let saved = await store.flushImmediately()
        try check(saved, "合并后的隔离目录无法保存")
        let reopened = try CatalogPersistence(directory: catalogue).load()
        #if PERFORMANCE_BASELINE_061
        let expectedCamera = "Notification Burst"
        #else
        let expectedCamera = CommandLine.arguments.contains("--compare-only") ? "Notification Burst" : "Newest During Drain"
        #endif
        try check(reopened.cachedItems.count == 10_000 && reopened.cachedItems.last?.camera == expectedCamera,
                  "性能优化未完整保存后台元数据")
        store.cancelScan()
        await heartbeat.settle()
    }

    private static func transfers(root: URL, heartbeat: Heartbeat) async throws {
        heartbeat.resetPhase()
        let domain = "FilmboxPerformance-\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let center = CloudTransferCenter(defaults: defaults)
        let account = UUID(), visible = item(0, account: account)
        let visibleToken = UUID()
        center.queued(item: visible, purpose: .thumbnail, priority: .foreground, token: visibleToken)
        center.started(itemID: visible.id, purpose: .thumbnail, token: visibleToken)
        let invalidations = LockedCounter()
        withObservationTracking { _ = center.snapshot(for: visible.id, purpose: .thumbnail) } onChange: { invalidations.increment() }
        let start = ProcessInfo.processInfo.systemUptime
        var worstChunk = 0.0
        var chunkStart = start
        for index in 20..<10_020 {
            let media = item(index, account: account), token = UUID()
            center.queued(item: media, purpose: .thumbnail, priority: .background, token: token)
            center.started(itemID: media.id, purpose: .thumbnail, token: token)
            for progress in 1...4 {
                center.progress(itemID: media.id, purpose: .thumbnail, token: token,
                                received: Int64(progress * 1024), total: 4096)
            }
            center.finished(item: media, purpose: .thumbnail, token: token, bytes: 4096)
            if index % 100 == 19 {
                worstChunk = max(worstChunk, ProcessInfo.processInfo.systemUptime - chunkStart)
                await Task.yield()
                chunkStart = ProcessInfo.processInfo.systemUptime
            }
            if ProcessInfo.processInfo.systemUptime - start > 45 { throw Failure("一万传输记录更新超过45秒") }
        }
        metrics["transfer10000Seconds"] = ProcessInfo.processInfo.systemUptime - start
        metrics["transferWorst100ItemChunkMs"] = worstChunk * 1000
        metrics["unrelatedTransferInvalidations"] = Double(invalidations.value)
        try policy(invalidations.value == 0, "后台其它文件的状态变化使可见文件观察失效")
        let visibleChange = LockedCounter()
        withObservationTracking { _ = center.snapshot(for: visible.id, purpose: .thumbnail) } onChange: { visibleChange.increment() }
        center.progress(itemID: visible.id, purpose: .thumbnail, token: visibleToken, received: 1024, total: 4096)
        try check(visibleChange.value == 1, "可见文件自身进度没有观察通知")
        await heartbeat.settle()
        metrics["transferWorkWorstDelayMs"] = heartbeat.phaseWorstDelay * 1000
    }

    private static func bitmapCache(root: URL, heartbeat: Heartbeat) async throws {
        heartbeat.resetPhase()
        let source = root.appendingPathComponent("Source.jpg")
        try writePhoto(source)
        let caches = root.appendingPathComponent("Bitmaps", isDirectory: true)
        let budget: Int64 = 512 * 1024
        let service = ThumbnailService(cacheDirectory: caches, diskBudget: budget)
        var images: [WeakImage] = []
        let startRSS = residentBytes()
        let start = ProcessInfo.processInfo.systemUptime
        // Each file has a distinct key but shares identical compressed fixture
        // bytes. Only the decoder/cache sees the full 768-pixel bitmaps.
        for index in 0..<96 {
            let path = root.appendingPathComponent("Background-\(index).jpg")
            try FileManager.default.linkItem(at: source, to: path)
            let weak = await backgroundImage(service: service, url: path)
            try check(weak != nil, "后台缩略图实际解码失败")
            images.append(weak!)
        }
        await heartbeat.settle()
        let retained = images.filter { $0.value != nil }.count
        metrics["backgroundBitmapRetainedCount"] = Double(retained)
        metrics["backgroundBitmapSeconds"] = ProcessInfo.processInfo.systemUptime - start
        metrics["backgroundBitmapRSSDeltaMiB"] = Double(max(0, residentBytes() - startRSS)) / 1_048_576
        metrics["bitmapWorkWorstDelayMs"] = heartbeat.phaseWorstDelay * 1000
        try policy(retained == 0, "后台预载占用了前台 bitmap 内存缓存")
        let foreground = await foregroundImage(service: service, url: source)
        try check(foreground?.value != nil, "前台缩略图未保留在内存缓存")
        let viewer = await viewerImage(service: service, url: source)
        try check(viewer != nil, "查看器大预览没有实际解码")
        await heartbeat.settle()
        try policy(viewer?.value == nil, "查看器大预览仍额外保留在前台 thumbnail cache")
        let recentSource = root.appendingPathComponent("Background-95.jpg")
        try FileManager.default.removeItem(at: recentSource)
        let reopened = ThumbnailService(cacheDirectory: caches, diskBudget: budget)
        let persisted = await reopened.cachedThumbnail(for: recentSource, kind: .image, modifiedDate: timestamp, pixelSize: 768)
        try check(persisted != nil, "后台优化没有保留可离线复用的磁盘缩略图")
        await service.trimCache()
        try await Task.sleep(for: .milliseconds(250))
        let bytes = await service.cacheSize()
        metrics["thumbnailDiskBytes"] = Double(bytes)
        metrics["thumbnailDiskBudgetBytes"] = Double(budget)
        try check(bytes <= budget, "缩略图磁盘缓存超过测试预算")
        await service.clearCache()
    }

    private static func backgroundImage(service: ThumbnailService, url: URL) async -> WeakImage? {
        guard case .ready(let thumbnail) = await service.loadThumbnail(for: url, kind: .image,
            modifiedDate: timestamp, pixelSize: 768, priority: .background) else { return nil }
        return WeakImage(thumbnail.image)
    }
    private static func foregroundImage(service: ThumbnailService, url: URL) async -> WeakImage? {
        guard case .ready(let thumbnail) = await service.loadThumbnail(for: url, kind: .image,
            modifiedDate: timestamp, pixelSize: 768, priority: .foreground) else { return nil }
        return WeakImage(thumbnail.image)
    }
    private static func viewerImage(service: ThumbnailService, url: URL) async -> WeakImage? {
        guard case .ready(let thumbnail) = await service.loadThumbnail(for: url, kind: .image,
            modifiedDate: timestamp, pixelSize: 4096, priority: .foreground) else { return nil }
        return WeakImage(thumbnail.image)
    }
    #if !PERFORMANCE_BASELINE_061
    private static func rawCloudPreloading(root: URL, heartbeat: Heartbeat) async throws {
        heartbeat.resetPhase()
        let source = root.appendingPathComponent("Source.jpg")
        let service = ThumbnailService(cacheDirectory: root.appendingPathComponent("RawCovers"))
        let account = UUID(), loaderCalls = LockedCounter(), ratioReports = LockedCounter()
        let accountText = account.uuidString
        let observer = NotificationCenter.default.addObserver(forName: CloudPreviewMetadata.notification, object: nil, queue: nil) { notification in
            if let id = notification.userInfo?["id"] as? String, id.contains(accountText),
               notification.userInfo?["ratio"] as? Double == 1.5,
               notification.userInfo?["width"] == nil, notification.userInfo?["height"] == nil { ratioReports.increment() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let startRSS = residentBytes(), start = ProcessInfo.processInfo.systemUptime
        var last: MediaItem?
        for index in 20_000..<20_256 {
            let media = item(index, account: account)
            CloudMediaRegistry.shared.register([media])
            let result = await service.preloadCloudThumbnail(for: media) { _ in loaderCalls.increment(); return source }
            guard case .ready = result else { throw Failure("原始封面预载没有完成") }
            last = media
        }
        await heartbeat.settle()
        metrics["rawPreload256Seconds"] = ProcessInfo.processInfo.systemUptime - start
        metrics["rawPreloadRSSDeltaMiB"] = Double(max(0, residentBytes() - startRSS)) / 1_048_576
        metrics["rawPreloadWorkWorstDelayMs"] = heartbeat.phaseWorstDelay * 1000
        try check(loaderCalls.value == 256 && ratioReports.value == 256, "原始封面预载未准确读取封面图头比例")
        let decodedBytes = await service.cacheSize()
        try check(decodedBytes == 0, "原始封面预载生成了不必要的解码位图缓存")
        guard let last else { throw Failure("缺少原始封面夹具") }
        let bitmap = await service.cachedThumbnail(for: last.url, kind: .image, modifiedDate: timestamp, pixelSize: 768)
        try check(bitmap == nil, "原始封面预载填充了前台位图缓存")
        let rotated = root.appendingPathComponent("Rotated.jpg")
        try writePhoto(rotated, orientation: 6)
        let rotatedMedia = item(21_000, account: account), reported = LockedPreviewMetadata()
        let rotationObserver = NotificationCenter.default.addObserver(forName: CloudPreviewMetadata.notification, object: nil, queue: nil) { notification in
            if notification.userInfo?["id"] as? String == rotatedMedia.id { reported.record(notification) }
        }
        defer { NotificationCenter.default.removeObserver(rotationObserver) }
        let rotatedResult = await service.preloadCloudThumbnail(for: rotatedMedia) { _ in rotated }
        guard case .ready = rotatedResult else { throw Failure("旋转封面头部读取失败") }
        let rotation = reported.value
        try check(abs((rotation.ratio ?? 0) - 2.0 / 3.0) < 0.001 && !rotation.hasOriginalDimensions,
                  "旋转JPEG封面的展示比例错误，或封面尺寸冒充了原文件尺寸")
    }

    private static func racingMetadataNotifications(store: AppStore, items: [MediaItem]) async throws {
        let state = MetadataRaceState(), start = ProcessInfo.processInfo.systemUptime
        withObservationTracking { _ = store.items.count } onChange: {
            Task { @MainActor in
                let oldCount = store.items.filter { $0.camera == "Older Drain Value" }.count
                state.overlapped = oldCount > 0 && oldCount < items.count
                for media in items {
                    store.applyCloudMetadata(Notification(name: CloudPreviewMetadata.notification,
                        userInfo: ["id": media.id, "revision": "perf-r1", "camera": "Newest During Drain"]))
                }
                state.injected = true
            }
        }
        for media in items {
            store.applyCloudMetadata(Notification(name: CloudPreviewMetadata.notification,
                userInfo: ["id": media.id, "revision": "perf-r1", "camera": "Older Drain Value"]))
        }
        try await wait(seconds: 15) {
            state.injected && store.items.filter { $0.camera == "Newest During Drain" }.count == items.count
        }
        try check(state.overlapped, "新值没有在旧批次尚未清空时到达，竞态夹具不成立")
        try await Task.sleep(for: .milliseconds(100))
        try check(store.items.filter { $0.camera == "Newest During Drain" }.count == items.count,
                  "分块旧批次覆盖了同一媒体后到的新值")
        metrics["metadataDrainRace20000Seconds"] = ProcessInfo.processInfo.systemUptime - start
    }
    #endif
    private static func item(_ index: Int, account: UUID) -> MediaItem {
        let path = "/\(index < 20 ? "Visible" : "Archive")-\(index).jpg"
        return MediaItem(cloud: CloudMediaReference(accountID: account, fileID: "perf-\(index)", parentID: "/",
            remotePath: path, revision: "perf-r1"), kind: .image, fileSize: 4096,
            modifiedDate: timestamp, createdDate: timestamp)
    }
    private static func writePhoto(_ url: URL, orientation: Int = 1) throws {
        guard let context = CGContext(data: nil, width: 1536, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure("无法生成照片夹具") }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1536, height: 1024))
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure("无法保存照片夹具") }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure("夹具编码失败") }
    }
    private static func wait(seconds: Double, condition: @MainActor () -> Bool) async throws {
        let start = ProcessInfo.processInfo.systemUptime
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime - start < seconds else { throw Failure("后台元数据合并超时") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private static func argument(after name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }
    private static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message) }; assertions += 1
    }
    private static func policy(_ value: Bool, _ message: String) throws {
        if baseline && !value { print("BASELINE REGRESSION: \(message)"); return }
        try check(value, message)
    }
    private static func residentBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }
    private static func peakResidentBytes() -> Int64 {
        var usage = rusage()
        return getrusage(RUSAGE_SELF, &usage) == 0 ? Int64(usage.ru_maxrss) : residentBytes()
    }
    @MainActor private final class WeakImage { weak var value: NSImage?; init(_ value: NSImage) { self.value = value } }
    @MainActor private final class MetadataRaceState { var injected = false; var overlapped = false }
    private final class LockedPreviewMetadata: @unchecked Sendable {
        private let lock = NSLock()
        private var ratio: Double?
        private var hasOriginalDimensions = false
        func record(_ notification: Notification) {
            lock.withLock {
                ratio = notification.userInfo?["ratio"] as? Double
                hasOriginalDimensions = notification.userInfo?["width"] != nil || notification.userInfo?["height"] != nil
            }
        }
        var value: (ratio: Double?, hasOriginalDimensions: Bool) { lock.withLock { (ratio, hasOriginalDimensions) } }
    }
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock(); private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
    @MainActor private final class Heartbeat {
        private var task: Task<Void, Never>?
        private var last = ProcessInfo.processInfo.systemUptime
        var worstDelay = 0.0
        var phaseWorstDelay = 0.0
        func start() {
            last = ProcessInfo.processInfo.systemUptime
            task = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                    guard let self else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    self.worstDelay = max(self.worstDelay, now - self.last - 0.02)
                    self.phaseWorstDelay = max(self.phaseWorstDelay, now - self.last - 0.02)
                    self.last = now
                }
            }
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(60)) }
        func resetPhase() { phaseWorstDelay = 0; last = ProcessInfo.processInfo.systemUptime }
        func stop() { task?.cancel(); task = nil }
    }
    private struct Failure: Error, CustomStringConvertible { let description: String; init(_ text: String) { description = text } }
}
