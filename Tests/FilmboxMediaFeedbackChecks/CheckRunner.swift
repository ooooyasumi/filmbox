import AppKit
import AVKit
import FilmboxCore

@main @MainActor struct MediaFeedbackChecks {
    static var checks = 0
    static func check(_ condition: Bool, _ title: String) throws {
        guard condition else { throw NSError(domain: title, code: 1) }
        checks += 1; print("✓ \(title)")
    }
    static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("filmbox-feedback-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = MediaItem(url: root.appendingPathComponent("broken.mp4"), kind: .video, fileSize: 8, modifiedDate: .now, createdDate: .now)
        try Data("notvideo".utf8).write(to: local.url)
        let cloud = MediaItem(cloud: .init(accountID: UUID(), fileID: "one", parentID: "/", remotePath: "/one.mp4", revision: "v1"), kind: .video, fileSize: 8, modifiedDate: .now, createdDate: .now)
        for kind in [PhotoPreviewSession.State.failed, .unavailable] {
            for needsLogin in [false, true] {
                let normal = PhotoPreviewFeedback.resolve(state: kind, item: local, isOffline: false, original: nil, needsLogin: needsLogin)
                try check(normal?.title == MediaFailureText.failed && normal?.kind == .failed, "本地\(kind)不借用云端登录或连接原因\(needsLogin)")
                let offline = PhotoPreviewFeedback.resolve(state: kind, item: local, isOffline: true, original: nil, needsLogin: needsLogin)
                try check(offline?.title == MediaFailureText.offline, "仅已确认的本地离线显示资源库未连接\(kind)\(needsLogin)")
            }
        }
        let localLoading = MediaPlaceholderFeedback.resolve(item: local, loading: true, noPreview: true, needsLogin: true)
        try check(localLoading.title == MediaLoadingText.loading && !localLoading.spins && localLoading.symbol == "film", "本地占位读取不提前显示失败或网络图标")
        let localFailed = MediaPlaceholderFeedback.resolve(item: local, loading: false, noPreview: true, needsLogin: true)
        try check(localFailed.title == MediaFailureText.failed && localFailed.symbol == "exclamationmark.triangle", "本地缩略图读取失败不使用云盘或磁盘离线图标")
        try check(MediaPlaceholderFeedback.resolve(item: cloud, loading: false, noPreview: true, needsLogin: false).title == MediaFailureText.noPreview, "没有云封面不等于网络故障")
        try check(MediaPlaceholderFeedback.resolve(item: cloud, loading: true, noPreview: false, needsLogin: true).title == MediaFailureText.login, "明确登录失效不持续旋转")
        for error in [URLError(.notConnectedToInternet), URLError(.cannotConnectToHost), URLError(.timedOut), URLError(.cannotOpenFile)] {
            try check(MediaFailureText.transferError(error) == MediaFailureText.failed, "底层URL错误\(error.code)不成为推测性的网络提示")
        }
        try check(MediaFailureText.transferError(CloudConnectionError.credentialsMissing) == MediaFailureText.login, "真实登录失效使用统一提示")
        try check(MediaFailureText.transferError(CloudConnectionError.cacheBudgetExceeded(required: 1024, available: 0)).hasPrefix("缓存空间不足"), "保留有依据且可处理的缓存空间不足说明")
        let loading = PhotoPreviewFeedback.presentation(state: .loading, item: local, isOffline: false, original: nil, needsLogin: true)
        try check(loading == nil, "本地读取仍不弹加载浮层")
        let container = VideoCanvasContainer(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let view = container.playerView
        let coordinator = VideoCanvas.Coordinator()
        defer { coordinator.stop() }
        coordinator.configure(view: view, item: local, playOnOpen: false, command: 0)
        try await wait { coordinator.failureTitle != nil }
        try check(coordinator.failureTitle == MediaFailureText.failed && view.player == nil && view.controlsStyle == .none && view.isHidden && !coordinator.isLoading, "真实损坏本地视频移除AVKit失败播放器，只保留统一提示")
        try check(labels(container).filter { $0 == MediaFailureText.failed }.count == 1 && !labels(container).contains(where: { $0.contains("网络") }), "播放器失败只显示一条无法加载，不叠加网络说明")
        let goodURL = root.appendingPathComponent("healthy.mp4")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/Fixtures/h264-aac.mp4"), to: goodURL)
        let good = MediaItem(url: goodURL, kind: .video, fileSize: 100, modifiedDate: .now, createdDate: .now)
        coordinator.configure(view: view, item: good, playOnOpen: false, command: 0)
        try await wait { view.player?.currentItem?.status == .readyToPlay }
        try check(coordinator.failureTitle == nil && view.controlsStyle == .floating && !view.isHidden && !labels(container).contains(MediaFailureText.failed), "切换到正常本地视频恢复系统控件并清除旧错误")
        let remote = VideoCanvas.Coordinator(resolveAsset: { _ in throw URLError(.notConnectedToInternet) })
        defer { remote.stop() }
        let remoteView = AVPlayerView()
        remote.configure(view: remoteView, item: cloud, playOnOpen: false, command: 1)
        try await wait { remote.failureTitle != nil }
        try check(remote.failureTitle == MediaFailureText.failed && !remote.isLoading, "云端解析失败同样不展示原始系统网络错误")
        let transfer = CloudTransferCenter(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let token = UUID(); transfer.queued(item: cloud, purpose: .original, priority: .foreground, token: token)
        transfer.failed(itemID: cloud.id, purpose: .original, token: token, error: URLError(.cannotOpenFile))
        try check(transfer.snapshot(for: cloud.id)?.errorMessage == MediaFailureText.failed, "任务列表与图片视频复用同一失败文案")
        print("\(checks)项媒体提示检查通过；仅合成坏视频与注入错误，没有真实云盘或网络请求")
    }
    static func labels(_ view: NSView) -> [String] { (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels) }
    static func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw NSError(domain: "等待错误反馈超时", code: 1)
    }
}
