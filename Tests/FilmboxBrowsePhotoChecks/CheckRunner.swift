import AppKit
import FilmboxCore

@main @MainActor
private struct BrowsePhotoChecks {
    static var passed = 0
    static var assertions = 0
    static func main() async {
        _ = NSApplication.shared
        guard let cache = Bundle.main.object(forInfoDictionaryKey: "FilmboxDevelopmentCache") as? String,
              cache.contains("filmbox-browse-photo.") else {
            print("请通过隔离缓存的 check-browse-photo.sh 运行")
            exit(EXIT_FAILURE)
        }
        let checks: [(String, () async throws -> Void)] = [
            ("稳定焦点只发起一次高清并替换小图", stableFocus),
            ("A到B立即取消A且回A重新请求高清", focusChangesCancelAndRestart),
            ("停止后释放当前预览且旧请求不能回流", stoppedPreviewRejectsLateResult),
            ("视频、禁用和空焦点不请求照片高清", nonPhotoFocusDoesNotLoad),
            ("同ID尺寸、修改日期和URL变化刷新高清", changedLocalIdentityReloads),
            ("同云端ID版本变化刷新高清", changedCloudRevisionReloads),
            ("焦点重试保留单一请求所有权", retryStartsFreshRequest),
            ("邻近缩略图按距离排列并限制四张半径", thumbnailNeighborhood)
        ]
        for (name, check) in checks {
            do { try await check(); passed += 1; print("✓ \(name)") }
            catch { print("✗ \(name)：\(error)") }
        }
        print("\(passed)/\(checks.count) 横向照片聚焦检查通过，\(assertions) 项断言")
        if passed != checks.count { exit(EXIT_FAILURE) }
    }

    static func stableFocus() async throws {
        let gate = FocusLoader(), small = bitmap(.gray), high = bitmap(.blue)
        let controller = BrowsePhotoPreview(cached: { _ in small }, full: { await gate.load($0) })
        defer { controller.stop() }
        let item = photo("stable")
        for _ in 0..<20 { controller.update(item: item, enabled: true) }
        try await wait { await gate.requestCount == 1 }
        try expect(controller.currentID == item.id && controller.preview?.state == .loading,
                   "当前焦点必须立即持有独立加载会话")
        try expect(controller.preview?.thumbnail?.image === small.image, "下载时应保留小图")
        await gate.finish(0, with: .ready(high))
        try await wait { controller.preview?.state == .ready }
        try expect(controller.preview?.thumbnail?.image === high.image, "高清完成未展示高清位图")
        for _ in 0..<20 { controller.update(item: item, enabled: true) }
        await Task.yield()
        try expect(await gate.requestCount == 1, "重复可见或元数据通知不能重复启动同一高清")
    }

    static func focusChangesCancelAndRestart() async throws {
        let gate = FocusLoader(), small = bitmap(.gray), high = bitmap(.blue)
        let controller = BrowsePhotoPreview(cached: { _ in small }, full: { await gate.load($0) })
        defer { controller.stop() }
        let a = photo("a"), b = photo("b")
        controller.update(item: a, enabled: true)
        try await wait { await gate.requestCount == 1 }
        controller.update(item: b, enabled: true)
        try await wait { await gate.hasRequests(2, cancelling: 0) }
        try expect(controller.currentID == b.id && controller.preview?.thumbnail?.image === small.image,
                   "切换后B必须立即获得自己的加载会话")
        try expect(await gate.request(at: 1)?.id == b.id, "第二个请求必须是B而非邻近预取")
        controller.update(item: a, enabled: true)
        try await wait { await gate.hasRequests(3, cancelling: 1) }
        try expect(await gate.request(at: 2)?.id == a.id, "返回未完成的A应重新请求")
        await gate.finish(2, with: .ready(high))
        try await wait { controller.preview?.state == .ready }
        try expect(controller.currentID == a.id && controller.preview?.thumbnail?.image === high.image,
                   "A高清完成应只替换当前A的小图")
    }

    static func stoppedPreviewRejectsLateResult() async throws {
        let gate = FocusLoader(ignoresCancellation: true), small = bitmap(.gray)
        let controller = BrowsePhotoPreview(cached: { _ in small }, full: { await gate.load($0) })
        controller.update(item: photo("late"), enabled: true)
        try await wait { await gate.requestCount == 1 }
        let old = controller.preview
        controller.stop()
        try expect(controller.currentID == nil && controller.preview == nil, "离开卷轴后不能保留大图引用")
        try expect(old?.state == .idle && old?.thumbnail?.image === small.image,
                   "旧会话应停止加载反馈并保留其既有小图")
        try await wait { await gate.cancelled.contains(0) }
        await gate.finish(0, with: .ready(bitmap(.red)))
        await Task.yield()
        try expect(controller.preview == nil && controller.currentID == nil,
                   "取消不及时的旧网络结果不能重新激活卷轴预览")
        try expect(old?.state == .idle && old?.thumbnail?.image === small.image,
                   "旧结果不能污染已经失效的照片会话")
    }

    static func nonPhotoFocusDoesNotLoad() async throws {
        let gate = FocusLoader()
        let controller = BrowsePhotoPreview(cached: { _ in nil }, full: { await gate.load($0) })
        controller.update(item: photo("disabled"), enabled: false)
        controller.update(item: photo("movie", kind: .video), enabled: true)
        controller.update(item: nil, enabled: true)
        await Task.yield()
        try expect(await gate.requestCount == 0, "视频、禁用和空焦点都不能启动照片下载")
        controller.update(item: photo("active"), enabled: true)
        try await wait { await gate.requestCount == 1 }
        controller.update(item: photo("active"), enabled: false)
        try await wait { await gate.cancelled.contains(0) }
        try expect(controller.preview == nil && controller.currentID == nil, "失去活动状态须释放高清并取消请求")
        controller.stop()
    }

    static func changedLocalIdentityReloads() async throws {
        let counter = FocusCounter(), image = bitmap(.blue)
        let controller = BrowsePhotoPreview(cached: { _ in nil }, full: { item in
            await counter.record(item); return .ready(image)
        })
        defer { controller.stop() }
        let base = photo("revised")
        controller.update(item: base, enabled: true)
        try await wait { controller.preview?.state == .ready }
        let changes = [photo("revised", modified: .distantPast.addingTimeInterval(1)),
                       photo("revised", bytes: 101, modified: .distantPast.addingTimeInterval(1)),
                       photo("revised", bytes: 101, modified: .distantPast.addingTimeInterval(1), path: "renamed")]
        for (index, item) in changes.enumerated() {
            controller.update(item: item, enabled: true)
            try await wait { await counter.count == index + 2 && controller.preview?.state == .ready }
            try expect(controller.currentID == base.id, "内容版本变化不应变更稳定身份")
        }
        try expect(await counter.count == 4, "同ID内容大小、修改日期和URL变化应分别刷新")
    }

    static func changedCloudRevisionReloads() async throws {
        let counter = FocusCounter(), image = bitmap(.blue), account = UUID()
        let controller = BrowsePhotoPreview(cached: { _ in nil }, full: { item in
            await counter.record(item); return .ready(image)
        })
        defer { controller.stop() }
        func cloud(_ revision: String) -> MediaItem {
            MediaItem(cloud: CloudMediaReference(accountID: account, fileID: "revision-check", parentID: "root",
                                                remotePath: "/photo.jpg", revision: revision),
                      kind: .image, fileSize: 100, modifiedDate: .distantPast, createdDate: .distantPast)
        }
        controller.update(item: cloud("1"), enabled: true)
        try await wait { controller.preview?.state == .ready }
        controller.update(item: cloud("2"), enabled: true)
        try await wait { await counter.count == 2 && controller.preview?.state == .ready }
        try expect(await counter.last?.cloud?.revision == "2", "新修订版必须重新加载而非沿用旧高清")
    }

    static func retryStartsFreshRequest() async throws {
        let gate = FocusLoader(), controller = BrowsePhotoPreview(cached: { _ in nil }, full: { await gate.load($0) })
        defer { controller.stop() }
        controller.update(item: photo("retry"), enabled: true)
        try await wait { await gate.requestCount == 1 }
        controller.retry()
        try await wait { await gate.hasRequests(2, cancelling: 0) }
        await gate.finish(1, with: .ready(bitmap(.blue)))
        try await wait { controller.preview?.state == .ready }
        try expect(await gate.requestCount == 2, "重试必须仅创建一个替代请求")
    }

    static func thumbnailNeighborhood() async throws {
        try expect(BrowseThumbnailNeighborhood.indexes(center: 5, count: 11) == [5,6,4,7,3,8,2,9,1], "四张邻域须按距离交替排列")
        try expect(BrowseThumbnailNeighborhood.indexes(center: 0, count: 10) == [0,1,2,3,4], "起点不应越界或扩大右侧半径")
        try expect(BrowseThumbnailNeighborhood.indexes(center: 9, count: 10) == [9,8,7,6,5], "末端不应越界或扩大左侧半径")
        try expect(BrowseThumbnailNeighborhood.indexes(center: 0, count: 1) == [0], "单张资料库只包含焦点")
        try expect(BrowseThumbnailNeighborhood.indexes(center: 0, count: 0).isEmpty, "空资料库无预取")
        try expect(BrowseThumbnailNeighborhood.indexes(center: -1, count: 10).isEmpty, "负索引不应产生请求")
        try expect(BrowseThumbnailNeighborhood.indexes(center: 10, count: 10).isEmpty, "越界索引不应产生请求")
        try expect(BrowseThumbnailNeighborhood.indexes(center: 3, count: 8, radius: 0) == [3], "零半径仅请求当前缩略图")
        try expect(BrowseThumbnailNeighborhood.indexes(center: 3, count: 8, radius: 1) == [3,4,2], "自定义一张半径须受限")
    }

    static func photo(_ id: String, kind: MediaKind = .image, bytes: Int64 = 100,
                      modified: Date = .distantPast, path: String? = nil) -> MediaItem {
        MediaItem(id: id, url: URL(fileURLWithPath: "/tmp/filmbox-browse-check-\(path ?? id).jpg"), kind: kind,
                  fileSize: bytes, modifiedDate: modified, createdDate: .distantPast)
    }
    static func bitmap(_ color: NSColor) -> Thumbnail {
        Thumbnail(image: NSImage(size: NSSize(width: 120, height: 80), flipped: false) { rect in
            color.setFill(); rect.fill(); return true
        })
    }
    static func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Failure(message: "焦点请求或状态没有及时更新")
    }
    static func expect(_ condition: Bool, _ message: String) throws {
        assertions += 1
        if !condition { throw Failure(message: message) }
    }
    struct Failure: Error, CustomStringConvertible { let message: String; var description: String { message } }
}

private actor FocusLoader {
    private var requests: [MediaItem] = []
    private var continuations: [Int: CheckedContinuation<ThumbnailLoadResult, Never>] = [:]
    private let ignoresCancellation: Bool
    private(set) var cancelled: Set<Int> = []
    var requestCount: Int { requests.count }
    init(ignoresCancellation: Bool = false) { self.ignoresCancellation = ignoresCancellation }
    func hasRequests(_ count: Int, cancelling id: Int) -> Bool { requests.count == count && cancelled.contains(id) }
    func request(at index: Int) -> MediaItem? { requests.indices.contains(index) ? requests[index] : nil }
    func load(_ item: MediaItem) async -> ThumbnailLoadResult {
        let id = requests.count
        requests.append(item)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if !ignoresCancellation && (Task.isCancelled || cancelled.contains(id)) {
                    continuation.resume(returning: .cancelled)
                } else { continuations[id] = continuation }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    func finish(_ id: Int, with result: ThumbnailLoadResult) { continuations.removeValue(forKey: id)?.resume(returning: result) }
    private func cancel(_ id: Int) {
        cancelled.insert(id)
        if !ignoresCancellation { finish(id, with: .cancelled) }
    }
}

private actor FocusCounter {
    private var requests: [MediaItem] = []
    var count: Int { requests.count }
    var last: MediaItem? { requests.last }
    func record(_ item: MediaItem) { requests.append(item) }
}
