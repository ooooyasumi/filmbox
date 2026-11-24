import AppKit
import Foundation
import FilmboxCore

@main @MainActor
private struct ViewerLoadingChecks {
    static var passed = 0
    static func main() async {
        _ = NSApplication.shared
        let checks: [(String, () async throws -> Void)] = [
            ("慢速高清加载期间保留缩略图与中央进度", slowOriginal),
            ("下载完成后解码期间继续显示准备状态", downloadIsNotDecode),
            ("高清失败保留已有缩略图并停止动画", failedRetainsPreview),
            ("重新登录提示取代失效请求的加载动画", loginReplacesProgress),
            ("已有原图缓存时断连仍可准备高清", cachedOriginalCanDecode),
            ("本地照片不继承云盘下载进度或重新登录提示", localReadIgnoresCloudState),
            ("云端尚无下载事件或读取本机缓存时只显示加载", unknownTransferIsNotDownload),
            ("其他文件和缩略图传输不能冒充当前原图状态", unrelatedTransferIsIgnored),
            ("切换照片后迟到的旧图不能覆盖当前图", staleCompletionCannotReplace),
            ("取消加载后不再显示永远旋转的进度", cancellationStopsProgress),
            ("焦点离开时取消实际高清加载消费者并保留小图", focusCancellationReachesLoader),
            ("重新聚焦未完成照片时复用小图并重新获取高清", refocusRetainsProvisional),
            ("旧焦点取消结束不能清除新焦点正在加载的状态", lateCancellationCannotClearNext),
            ("同一照片已完成时无需重复发起高清请求", completedRequestIsStable),
            ("原生画布高清替换保留缩放且切项目不残留过渡", canvasPreservesZoom),
            ("缺尺寸缩略图到高清拟合区域与手动缩放不突跳", provisionalGeometryIsStable)
        ]
        for (name, check) in checks {
            do { try await check(); passed += 1; print("✓ \(name)") }
            catch { print("✗ \(name)：\(error)") }
        }
        print("\(passed)/\(checks.count) 查看器加载检查通过")
        if passed != checks.count { exit(EXIT_FAILURE) }
    }

    static func slowOriginal() async throws {
        let session = PhotoPreviewSession(), gate = PreviewGate()
        let small = bitmap(.gray), high = bitmap(.blue), item = cloudPhoto()
        let job = Task { await session.load(item: item, cached: { _ in small }, full: { _ in await gate.load() }) }
        try await wait { await gate.isWaiting }
        try expect(session.state == .loading && session.thumbnail?.image === small.image,
                   "已有缩略图不应被当成完成，或被加载占位清空")
        let feedback = PhotoPreviewFeedback.resolve(state: session.state, item: item, isOffline: false,
                                                    original: transfer(.downloading, received: 30), needsLogin: false)
        try expect(feedback?.kind == .loading && feedback?.title == "正在下载" && feedback?.progress == 0.3,
                   "原图下载未提供独立且真实的可见进度")
        await gate.finish(.ready(high)); await job.value
        try expect(session.state == .ready && session.thumbnail?.image === high.image, "原图完成没有替换缩略图")
        try expect(PhotoPreviewFeedback.resolve(state: session.state, item: item, isOffline: false,
                                               original: transfer(.ready), needsLogin: false) == nil,
                   "完成后应移除中央浮层")
    }

    static func downloadIsNotDecode() async throws {
        let queued = PhotoPreviewFeedback.resolve(state: .loading, item: cloudPhoto(), isOffline: false,
                                                 original: transfer(.queued), needsLogin: false)
        try expect(queued?.title == "等待下载" && queued?.progress == nil, "排队状态不能显示下载假进度")
        let paused = PhotoPreviewFeedback.resolve(state: .loading, item: cloudPhoto(), isOffline: false,
                                                 original: transfer(.paused), needsLogin: false)
        try expect(paused?.title == "已暂停" && paused?.progress == nil, "暂停传输不能显示正在下载")
        let decoding = PhotoPreviewFeedback.resolve(state: .loading, item: cloudPhoto(), isOffline: false,
                                                   original: transfer(.ready, cached: true), needsLogin: false)
        try expect(decoding?.kind == .loading && decoding?.title == "正在加载" && decoding?.progress == nil,
                   "下载完成仍需等待可见高清，不能提前移除动画")
        let local = PhotoPreviewFeedback.resolve(state: .loading, item: photo("local"), isOffline: false,
                                                original: nil, needsLogin: false)
        try expect(local?.title == "正在加载", "本地慢解码也需要进度反馈")
    }

    static func failedRetainsPreview() async throws {
        let session = PhotoPreviewSession(), small = bitmap(.gray), item = cloudPhoto()
        await session.load(item: item, cached: { _ in small }, full: { _ in .failed })
        try expect(session.state == .failed && session.thumbnail?.image === small.image,
                   "失败必须保留预览，且不能一直处于加载或冒充ready")
        let feedback = PhotoPreviewFeedback.resolve(state: session.state, item: item, isOffline: false,
                                                    original: transfer(.failed), needsLogin: false)
        try expect(feedback?.kind == .failed && feedback?.progress == nil, "失败必须变成静态重试状态")
        let high = bitmap(.blue)
        await session.load(item: item, cached: { _ in nil }, full: { _ in .ready(high) })
        try expect(session.state == .ready && session.thumbnail?.image === high.image, "重试不能被旧失败状态拦住")
    }

    static func loginReplacesProgress() async throws {
        for state in [PhotoPreviewSession.State.loading, .failed, .unavailable] {
            let feedback = PhotoPreviewFeedback.resolve(state: state, item: cloudPhoto(), isOffline: false,
                                                       original: transfer(.failed), needsLogin: true)
            try expect(feedback?.kind == .login && feedback?.progress == nil, "断连后不能保持旋转或普通文件错误")
        }
    }

    static func cachedOriginalCanDecode() async throws {
        let feedback = PhotoPreviewFeedback.resolve(state: .loading, item: cloudPhoto(), isOffline: false,
                                                    original: transfer(.ready, cached: true), needsLogin: true)
        try expect(feedback?.kind == .loading && feedback?.title == "正在加载", "登录失效不应阻止已下载原图解码")
        let finished = PhotoPreviewFeedback.resolve(state: .ready, item: cloudPhoto(), isOffline: false,
                                                    original: transfer(.ready, cached: true), needsLogin: true)
        try expect(finished == nil, "已显示原图不应被登录提示遮挡")
    }

    static func localReadIgnoresCloudState() async throws {
        let item = photo("local-with-stale-transfer")
        try expect(item.isLocal && item.cloud == nil && item.url.isFileURL, "本地检查必须使用真实文件来源")
        for state in [CloudTransferState.downloading, .queued, .paused, .failed, .ready] {
            for needsLogin in [false, true] {
                let feedback = PhotoPreviewFeedback.resolve(state: .loading, item: item, isOffline: false,
                    original: transfer(state, item: item, received: 30), needsLogin: needsLogin)
                try expect(feedback?.kind == .loading && feedback?.title == "正在加载" && feedback?.progress == nil,
                           "本地读取不能沿用残留云盘状态：\(state)，needsLogin=\(needsLogin)")
            }
        }
        for state in [PhotoPreviewSession.State.failed, .unavailable] {
            let feedback = PhotoPreviewFeedback.resolve(state: state, item: item, isOffline: true,
                original: transfer(.downloading, item: item, received: 30), needsLogin: true)
            try expect(feedback?.kind == .failed && feedback?.title == MediaFailureText.offline && feedback?.progress == nil,
                       "本地磁盘离线应显示文件错误，不能要求登录云盘")
        }
    }

    static func unknownTransferIsNotDownload() async throws {
        let item = cloudPhoto()
        let snapshots: [CloudTransferSnapshot?] = [nil, transfer(.idle), transfer(.failed),
            transfer(.noPreview), transfer(.ready), transfer(.ready, cached: true)]
        for snapshot in snapshots {
            let feedback = PhotoPreviewFeedback.resolve(state: .loading, item: item, isOffline: false,
                original: snapshot, needsLogin: false)
            try expect(feedback?.kind == .loading && feedback?.title == "正在加载" && feedback?.progress == nil,
                       "无当前下载事件或读取本机缓存时不能声称正在下载")
        }
    }

    static func unrelatedTransferIsIgnored() async throws {
        let item = cloudPhoto(), other = cloudPhoto("other-file")
        for state in [CloudTransferState.downloading, .queued, .paused, .ready] {
            let feedback = PhotoPreviewFeedback.resolve(state: .loading, item: item, isOffline: false,
                original: transfer(state, item: other, received: 70), needsLogin: false)
            try expect(feedback?.title == "正在加载" && feedback?.progress == nil,
                       "其他文件的传输不能串到当前照片")
        }
        let thumbnail = PhotoPreviewFeedback.resolve(state: .loading, item: item, isOffline: false,
            original: transfer(.downloading, received: 70, purpose: .thumbnail), needsLogin: false)
        try expect(thumbnail?.title == "正在加载" && thumbnail?.progress == nil,
                   "当前缩略图的下载不能冒充原图下载")
        let login = PhotoPreviewFeedback.resolve(state: .loading, item: item, isOffline: false,
            original: transfer(.ready, item: other, cached: true), needsLogin: true)
        try expect(login?.kind == .login && login?.progress == nil,
                   "其他文件的原图缓存不能掩盖当前云盘登录失效")
    }

    static func staleCompletionCannotReplace() async throws {
        let session = PhotoPreviewSession(), gate = PreviewGate(), old = bitmap(.red), new = bitmap(.blue)
        let oldJob = Task { await session.load(item: photo("old"), cached: { _ in nil }, full: { _ in await gate.load() }) }
        try await wait { await gate.isWaiting }
        await session.load(item: photo("new"), cached: { _ in nil }, full: { _ in .ready(new) })
        await gate.finish(.ready(old)); await oldJob.value
        try expect(session.state == .ready && session.thumbnail?.image === new.image, "迟到的旧请求串到了新照片")
    }

    static func cancellationStopsProgress() async throws {
        let session = PhotoPreviewSession(), gate = PreviewGate(), small = bitmap(.gray), item = cloudPhoto()
        let job = Task { await session.load(item: item, cached: { _ in small }, full: { _ in await gate.load() }) }
        try await wait { await gate.isWaiting }
        job.cancel(); await gate.finish(.ready(bitmap(.blue))); await job.value
        try expect(session.state == .idle && session.thumbnail?.image === small.image, "取消后不应继续转圈或接受迟到的高清")
        try expect(PhotoPreviewFeedback.resolve(state: session.state, item: item, isOffline: false,
                                                original: transfer(.downloading), needsLogin: false) == nil,
                   "已取消的视图不应沿用后台传输动画")
    }

    static func completedRequestIsStable() async throws {
        let session = PhotoPreviewSession(), image = bitmap(.blue), counter = PreviewCounter(), item = photo("done")
        await session.load(item: item, cached: { _ in nil }, full: { _ in await counter.increment(); return .ready(image) })
        await session.load(item: item, cached: { _ in nil }, full: { _ in await counter.increment(); return .failed })
        try expect(await counter.value == 1, "元数据或登录状态更新不应使已完成高清重复下载")
        try expect(session.state == .ready && session.thumbnail?.image === image.image, "已显示的高清被无关重试覆盖")
    }

    static func focusCancellationReachesLoader() async throws {
        let session = PhotoPreviewSession(), gate = CancellablePreviewGate(), small = bitmap(.gray)
        let job = Task { await session.load(item: photo("focused"), cached: { _ in small }, full: { _ in await gate.load() }) }
        try await wait { await gate.isWaiting }
        job.cancel(); session.cancel()
        try await wait { await gate.wasCancelled }
        await job.value
        try expect(session.state == .idle && session.thumbnail?.image === small.image,
                   "划走必须取消高清消费者，同时保留已经显示的小图")
    }

    static func refocusRetainsProvisional() async throws {
        let session = PhotoPreviewSession(), first = CancellablePreviewGate(), second = PreviewGate()
        let counter = PreviewCounter(), item = photo("refocus"), small = bitmap(.gray), high = bitmap(.blue)
        let firstJob = Task {
            await session.load(item: item, cached: { _ in await counter.increment(); return small }, full: { _ in await first.load() })
        }
        try await wait { await first.isWaiting }
        firstJob.cancel(); session.cancel()
        let secondJob = Task {
            await session.load(item: item, cached: { _ in await counter.increment(); return nil }, full: { _ in await second.load() })
        }
        try await wait { await second.isWaiting }
        await firstJob.value
        try expect(await counter.value == 1, "同一照片重新聚焦不应清空小图后再次读取它")
        try expect(session.state == .loading && session.thumbnail?.image === small.image,
                   "重新聚焦未完成照片应立即保留已有小图并恢复高清加载")
        await second.finish(.ready(high)); await secondJob.value
        try expect(session.state == .ready && session.thumbnail?.image === high.image,
                   "重新聚焦后新的高清结果未能正确显示")
    }

    static func lateCancellationCannotClearNext() async throws {
        let session = PhotoPreviewSession(), oldGate = PreviewGate(), nextGate = PreviewGate()
        let oldSmall = bitmap(.red), nextSmall = bitmap(.gray), nextHigh = bitmap(.blue)
        let oldJob = Task { await session.load(item: photo("departing"), cached: { _ in oldSmall }, full: { _ in await oldGate.load() }) }
        try await wait { await oldGate.isWaiting }
        oldJob.cancel(); session.cancel()
        let nextJob = Task { await session.load(item: photo("arriving"), cached: { _ in nextSmall }, full: { _ in await nextGate.load() }) }
        try await wait { await nextGate.isWaiting }
        await oldGate.finish(.ready(bitmap(.red))); await oldJob.value
        try expect(session.state == .loading && session.thumbnail?.image === nextSmall.image,
                   "旧请求取消清理不能让当前照片停止加载或接受旧图")
        await nextGate.finish(.ready(nextHigh)); await nextJob.value
        try expect(session.state == .ready && session.thumbnail?.image === nextHigh.image,
                   "新焦点高清应独立完成")
    }

    static func canvasPreservesZoom() async throws {
        let canvas = PhotoScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(contentRect: canvas.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.wantsLayer = true
        canvas.layoutSubtreeIfNeeded()
        canvas.displayIfNeeded()
        defer { window.contentView = nil; window.close() }
        let item = MediaItem(url: URL(fileURLWithPath: "/tmp/viewer-loading-canvas.jpg"), kind: .image,
                             fileSize: 500, modifiedDate: .distantPast, createdDate: .distantPast,
                             pixelWidth: 6000, pixelHeight: 4000)
        canvas.configure(item: item, image: bitmap(.gray).image)
        canvas.layoutSubtreeIfNeeded()
        canvas.setPhotoScale(1.4)
        let magnification = canvas.magnification, origin = canvas.contentView.bounds.origin
        canvas.configure(item: item, image: bitmap(.blue).image)
        try expect(abs(canvas.magnification - magnification) < 0.001 && canvas.contentView.bounds.origin == origin,
                   "高清到达不能重置用户正在看的位置或缩放")
        let transition = canvas.documentView?.layer?.animation(forKey: "transition")
        try expect(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? transition == nil : transition != nil,
                   "同源高清替换需要短暂过渡，且必须遵守减少动态效果")
        let next = MediaItem(url: URL(fileURLWithPath: "/tmp/viewer-loading-other.jpg"), kind: .image,
                             fileSize: 500, modifiedDate: .distantPast, createdDate: .distantPast)
        canvas.configure(item: next, image: bitmap(.red).image)
        try expect(canvas.documentView?.layer?.animation(forKey: "transition") == nil,
                   "切换不同照片不能沿用上一张图的高清替换动画")
        canvas.tearDown()
    }

    static func provisionalGeometryIsStable() async throws {
        let canvas = PhotoScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let item = photo("unknown-size"), small = bitmap(.gray, size: NSSize(width: 768, height: 432))
        let high = bitmap(.blue, size: NSSize(width: 4096, height: 2304))
        canvas.configure(item: item, image: small.image, isProvisional: true)
        canvas.layoutSubtreeIfNeeded()
        let fittedSmall = displayedSize(canvas)
        try expect(fittedSmall.width > 800, "未知原尺寸的小图应先适应视口，不能等高清后突然撑大")
        canvas.configure(item: item, image: high.image, isProvisional: false)
        let fittedHigh = displayedSize(canvas)
        try expect(abs(fittedHigh.width - fittedSmall.width) < 0.5 && abs(fittedHigh.height - fittedSmall.height) < 0.5,
                   "768到4096高分替换不能改变相同比例的拟合区域")
        canvas.tearDown()

        let zoomed = PhotoScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        zoomed.configure(item: item, image: small.image, isProvisional: true)
        zoomed.layoutSubtreeIfNeeded()
        zoomed.setPhotoScale(Double(zoomed.magnification) * 1.5)
        let before = displayedSize(zoomed), beforeCenter = normalizedCenter(zoomed)
        zoomed.configure(item: item, image: high.image, isProvisional: false)
        let after = displayedSize(zoomed), afterCenter = normalizedCenter(zoomed)
        try expect(abs(before.width - after.width) < 0.5 && abs(before.height - after.height) < 0.5,
                   "用户已放大临时预览时，高清到达应保持相对拟合倍率")
        try expect(abs(beforeCenter.x - afterCenter.x) < 0.002 && abs(beforeCenter.y - afterCenter.y) < 0.002,
                   "高清到达不应改变用户正在观察的位置")
        zoomed.tearDown()
    }
    static func displayedSize(_ canvas: PhotoScrollView) -> CGSize {
        let size = canvas.documentView?.bounds.size ?? .zero
        return CGSize(width: size.width * canvas.magnification, height: size.height * canvas.magnification)
    }
    static func normalizedCenter(_ canvas: PhotoScrollView) -> CGPoint {
        let size = canvas.documentView?.bounds.size ?? CGSize(width: 1, height: 1)
        return CGPoint(x: canvas.contentView.bounds.midX / size.width, y: canvas.contentView.bounds.midY / size.height)
    }

    static func photo(_ id: String) -> MediaItem {
        MediaItem(url: URL(fileURLWithPath: "/tmp/filmbox-viewer-check-\(id).jpg"), kind: .image,
                  fileSize: 100, modifiedDate: .distantPast, createdDate: .distantPast)
    }
    static func cloudPhoto(_ id: String = "viewer-test") -> MediaItem {
        let accountID = UUID(uuidString: "C729658E-C7CB-49B1-8C2B-F81D6D3785D0")!
        let reference = CloudMediaReference(accountID: accountID, fileID: id, parentID: "root",
            remotePath: "/\(id).jpg", revision: "viewer-loading-check-v1")
        return MediaItem(cloud: reference, kind: .image, fileSize: 100,
            modifiedDate: .distantPast, createdDate: .distantPast)
    }
    static func bitmap(_ color: NSColor, size: NSSize = NSSize(width: 120, height: 80)) -> Thumbnail {
        Thumbnail(image: NSImage(size: size, flipped: false) { rect in
            color.setFill(); rect.fill(); return true
        })
    }
    static func transfer(_ state: CloudTransferState, item: MediaItem? = nil, received: Int64 = 0,
                         cached: Bool = false, purpose: CloudTransferPurpose = .original) -> CloudTransferSnapshot {
        let item = item ?? cloudPhoto()
        return CloudTransferSnapshot(itemID: item.id, name: item.name, purpose: purpose,
                              state: state, receivedBytes: received, totalBytes: 100, errorMessage: nil,
                              isOriginalCached: cached, updatedAt: .now, priority: .foreground)
    }
    static func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure(message: "受控请求未开始")
    }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    struct Failure: Error, CustomStringConvertible { let message: String; var description: String { message } }
}

private actor PreviewGate {
    private var continuation: CheckedContinuation<ThumbnailLoadResult, Never>?
    var isWaiting: Bool { continuation != nil }
    func load() async -> ThumbnailLoadResult { await withCheckedContinuation { continuation = $0 } }
    func finish(_ result: ThumbnailLoadResult) { continuation?.resume(returning: result); continuation = nil }
}
private actor PreviewCounter {
    var value = 0
    func increment() { value += 1 }
}

private actor CancellablePreviewGate {
    private var continuation: CheckedContinuation<ThumbnailLoadResult, Never>?
    private(set) var wasCancelled = false
    var isWaiting: Bool { continuation != nil }
    func load() async -> ThumbnailLoadResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || wasCancelled { continuation.resume(returning: .cancelled) }
                else { self.continuation = continuation }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }
    private func cancel() {
        wasCancelled = true
        continuation?.resume(returning: .cancelled)
        continuation = nil
    }
}
