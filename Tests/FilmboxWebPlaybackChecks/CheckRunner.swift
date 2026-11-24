import AppKit
import Foundation
import FilmboxCore
@preconcurrency import WebKit

/// Exercises the real HTML, native bridge, media server and roll controller.
/// Windows stay hidden and the app is never activated. Unmute checks pause first
/// and set the real element's volume to zero before changing its muted flag.
@main @MainActor
private struct WebPlaybackCheckRunner {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { await run() }
        app.run()
    }

    private static func run() async {
        let fixture: WebFixture
        do { fixture = try WebFixture.make() }
        catch { print("✗ 无法创建 WebM 播放检查夹具：\(error)"); exit(EXIT_FAILURE) }
        let checks: [(String, (WebFixture) async throws -> Void)] = [
            ("真实同源桥接收到首帧且默认静音", readyFrame),
            ("原比例留边快照使用黑底且保留真实视频画面", letterboxBackground),
            ("真实播放时钟推进、定位和循环", seekAndLoop),
            ("同一身份保留手动暂停、静音设置和会话", sameIdentity),
            ("后台暂停保留进度及手动播放意图", suspension),
            ("切项清理旧页面且停止后撤销媒体租约", switchAndRevoke),
            ("快速取消准备不会恢复过期会话", cancelledPreparation),
            ("坏文件可恢复且照片及禁用状态立即清理", failedAndDisabled),
            ("错误桥接令牌和非播放器导航不能改写状态", restrictedBridge),
            ("查看器控制条与非自动播放策略实际生效", viewerPolicy),
            ("卷轴 WebM 桥接保留静音、暂停及单一会话", browseBridge)
        ]
        var passed = 0
        for (name, check) in checks {
            do { try await check(fixture); passed += 1; print("✓ \(name)") }
            catch { print("✗ \(name)：\(error)") }
            fflush(stdout)
        }
        fixture.remove()
        print("\(passed)/\(checks.count) WebM 播放检查通过")
        exit(passed == checks.count ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    private static func readyFrame(_ fixture: WebFixture) async throws {
        let playback = WebVideoPlayback(), host = HiddenWebHost()
        defer { playback.stop(); host.close() }
        try expect(playback.isMuted && !playback.isReady, "默认静音或初始就绪状态不正确")
        playback.update(item: fixture.first, muted: true, enabled: true, controls: false, loop: true)
        let view = try await ready(playback, host: host)
        let state = try await snapshot(view)
        try expect(state.muted && !state.controls && state.loop && state.width == 320 && state.height == 180,
                   "真实视频尺寸、静音或卷轴显示策略不正确")
        try expect(state.readyState >= 2 && playback.isReady && !playback.failed && !playback.isLoading,
                   "真实首帧没有通过严格来源桥接通知控制器")
        try expect(view.alphaValue == 1 && !host.window.isVisible && !NSApp.isActive,
                   "首帧未显示，或检查意外显示/激活窗口")
        try expect(view.url?.scheme == "http" && view.url?.host == "127.0.0.1"
                   && state.source.hasPrefix("http://127.0.0.1:"), "页面与媒体必须来自本机服务")
        let frame: FrameResult = try await value(view, expression: """
        (()=>{const v=document.getElementById('video'),c=document.createElement('canvas');
        c.width=v.videoWidth;c.height=v.videoHeight;const x=c.getContext('2d');x.drawImage(v,0,0);
        const p=Array.from(x.getImageData(10,10,1,1).data);return {bytes:c.toDataURL('image/png').length,pixel:p};})()
        """)
        try expect(frame.bytes > 1000 && frame.pixel.count == 4 && frame.pixel.prefix(3).contains(where: { $0 > 0 }),
                   "canvas 没有读出实际解码帧，或被跨源权限污染")
    }

    private static func seekAndLoop(_ fixture: WebFixture) async throws {
        let playback = WebVideoPlayback(), host = HiddenWebHost()
        defer { playback.stop(); host.close() }
        playback.update(item: fixture.first, muted: true, enabled: true, controls: false, loop: true)
        let view = try await ready(playback, host: host)
        try await eventually("WebM 时钟或实际状态桥接没有推进") {
            let state = try await snapshot(view)
            return state.time > 0.12 && playback.currentTime > 0.05 && playback.isPlaying
        }
        playback.togglePlayback()
        try await eventually("暂停命令未到达真实 video") { try await snapshot(view).paused }
        try await evaluate(view, "document.getElementById('video').currentTime=0.9")
        try await eventually("HTTP Range 定位未到达 0.9 秒") {
            abs(try await snapshot(view).time - 0.9) < 0.08
        }
        playback.togglePlayback()
        var previous = 0.9, wrapped = false
        try await eventually("短 WebM 没有在同一会话里循环", timeout: 7) {
            let state = try await snapshot(view)
            if previous > 0.8 && state.time < previous - 0.4 { wrapped = true }
            previous = state.time
            return wrapped && !state.paused && playback.isPlaying
        }
        try expect(playback.webView === view && playback.isMuted, "定位或循环重建了会话或改变静音")
    }

    private static func letterboxBackground(_ fixture: WebFixture) async throws {
        let playback = WebVideoPlayback(), host = HiddenWebHost()
        defer { playback.stop(); host.close() }
        playback.update(item: fixture.first, muted: true, enabled: true, controls: false, loop: true)
        let view = try await ready(playback, host: host)
        playback.togglePlayback()
        try await eventually("留边检查前无法暂停") { try await snapshot(view).paused }
        // The source is a colored 320×180 fixture. Both host shapes deliberately
        // differ from its aspect ratio, so these samples come from letterboxing.
        let source: [Int] = try await value(view, expression: """
        (()=>{const v=document.getElementById('video'),c=document.createElement('canvas');
        c.width=v.videoWidth;c.height=v.videoHeight;const x=c.getContext('2d');x.drawImage(v,0,0);
        return Array.from(x.getImageData(10,10,1,1).data);})()
        """)
        try expect(source.count == 4 && source.prefix(3).contains(where: { $0 > 30 }),
                   "源视频彩色帧未实际解码，不能用空白画布验证留边")
        for size in [NSSize(width: 640, height: 480), NSSize(width: 900, height: 360)] {
            host.window.setContentSize(size)
            host.configure(view)
            try await eventually("WebKit 视口没有跟随非原比例宿主缩放") {
                let viewport: [Double] = try await value(view, expression: "[innerWidth,innerHeight]")
                return viewport == [size.width, size.height]
            }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = view.bounds
            let image = try await view.takeSnapshot(configuration: configuration)
            let tiff = try require(image.tiffRepresentation, "留边快照没有图像数据")
            let bitmap = try require(NSBitmapImageRep(data: tiff), "留边快照无法读取像素")
            let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
            let points = size.height == 480
                ? [(width / 2, 2), (width / 2, height - 3)]
                : [(2, height / 2), (width - 3, height / 2)]
            for (x, y) in points {
                let color = try require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), "留边像素不可读取")
                try expect(color.redComponent < 0.03 && color.greenComponent < 0.03
                           && color.blueComponent < 0.03 && color.alphaComponent > 0.98,
                           "真实 WebKit 留边出现浅色：\(size)，像素(\(x),\(y)) = \(color)")
            }
            var hasPicture = false
            for y in [height / 3, height / 2, height * 2 / 3] {
                for x in [width / 3, width / 2, width * 2 / 3] {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       max(color.redComponent, max(color.greenComponent, color.blueComponent)) > 0.1 {
                        hasPicture = true
                    }
                }
            }
            try expect(hasPicture && playback.isReady && !playback.failed,
                       "黑底遮住了真实视频画面，或宿主缩放使播放失败")
        }
    }

    private static func sameIdentity(_ fixture: WebFixture) async throws {
        let playback = WebVideoPlayback(), host = HiddenWebHost()
        defer { playback.stop(); host.close() }
        playback.update(item: fixture.first, muted: true, enabled: true, controls: false, loop: true)
        let view = try await ready(playback, host: host)
        playback.togglePlayback()
        try await eventually("无法为静音检查暂停") { try await snapshot(view).paused }
        try await evaluate(view, "document.getElementById('video').volume=0")
        playback.setMuted(false)
        try await eventually("setMuted 未同步真实元素") { !(try await snapshot(view).muted) && !playback.isMuted }
        let before = try await snapshot(view).time
        playback.update(item: fixture.first, muted: false, enabled: true, controls: false, loop: true)
        await settle(0.35)
        let after = try await snapshot(view)
        try expect(playback.webView === view && after.paused && !after.muted && !playback.isPlaying
                   && abs(after.time - before) < 0.1, "同身份更新覆盖了手动暂停、静音或播放位置")
        playback.setMuted(true)
        try await eventually("重新静音未到达真实页面") { try await snapshot(view).muted }
    }

    private static func suspension(_ fixture: WebFixture) async throws {
        let playback = WebVideoPlayback(), host = HiddenWebHost()
        defer { playback.stop(); host.close() }
        playback.update(item: fixture.first, muted: true, enabled: true, controls: true, loop: true)
        let view = try await ready(playback, host: host)
        try await eventually("后台测试前播放未启动") { try await snapshot(view).time > 0.12 }
        playback.setSuspended(true)
        try await eventually("后台状态未暂停真实媒体") { try await snapshot(view).paused && !playback.isPlaying }
        let pausedAt = try await snapshot(view).time
        await settle(0.3)
        let suspendedState = try await snapshot(view)
        playback.setSuspended(false)
        let resumeInitial = try await snapshot(view).time
        try await eventually("回到前台没有恢复原播放意图") {
            let state = try await snapshot(view)
            return !state.paused && abs(state.time - pausedAt) > 0.1 && playback.isPlaying
        }
        playback.togglePlayback()
        try await eventually("手动暂停未生效") { try await snapshot(view).paused }
        playback.setSuspended(true); playback.setSuspended(false)
        await settle(0.3)
        let manualState = try await snapshot(view)
        try expect(manualState.paused && !playback.isPlaying && playback.webView === view,
                   "后台往返覆盖了用户手动暂停或重建会话")
        try expect(abs(suspendedState.time - pausedAt) < 0.08,
                   "后台暂停位置变化：\(pausedAt) → \(suspendedState.time)，resume=\(resumeInitial)，paused=\(suspendedState.paused)")
    }

    private static func switchAndRevoke(_ fixture: WebFixture) async throws {
        let playback = WebVideoPlayback(), host = HiddenWebHost()
        defer { playback.stop(); host.close() }
        playback.update(item: fixture.first, muted: true, enabled: true, controls: false, loop: true)
        let old = try await ready(playback, host: host)
        let oldSource = try await mediaURL(old)
        playback.update(item: fixture.second, muted: true, enabled: true, controls: false, loop: true)
        let current = try await ready(playback, host: host)
        try expect(current !== old && playback.currentID == fixture.second.id, "切项沿用了旧页面身份")
        try await eventually("切项没有撤销旧媒体路由") { try await status(oldSource) == 404 }
        try? await evaluate(old, "window.webkit?.messageHandlers?.filmboxVideo?.postMessage({event:'error',token:'stale'})")
        await settle(0.1)
        try expect(playback.currentID == fixture.second.id && !playback.failed && playback.webView === current,
                   "旧页面回调污染了新视频")
        let source = try await mediaURL(current)
        playback.stop()
        try expect(playback.webView == nil && playback.currentID == nil && !playback.isPlaying
                   && !playback.isReady && !playback.isLoading && !playback.failed
                   && playback.currentTime == 0 && playback.duration == 0, "stop 没有清理公开状态")
        try await eventually("stop 没有撤销媒体路由") { try await status(source) == 404 }
        await settle(0.15)
        try expect(playback.webView == nil && playback.currentID == nil && !playback.failed,
                   "stop 后旧异步事件重新建立了状态")
    }

    private static func cancelledPreparation(_ fixture: WebFixture) async throws {
        let playback = WebVideoPlayback(), host = HiddenWebHost()
        defer { playback.stop(); host.close() }
        for _ in 0..<4 {
            playback.update(item: fixture.first, muted: true, enabled: true, controls: false, loop: true)
            playback.update(item: fixture.second, muted: true, enabled: true, controls: false, loop: true)
            playback.stop()
        }
        await settle(0.3)
        try expect(playback.currentID == nil && playback.webView == nil && !playback.isLoading,
                   "已取消的异步准备在 stop 后复活")
        playback.update(item: fixture.first, muted: true, enabled: true, controls: false, loop: true)
        _ = try await ready(playback, host: host)
        try expect(playback.currentID == fixture.first.id && !playback.failed, "取消准备后无法建立新会话")
    }

    private static func failedAndDisabled(_ fixture: WebFixture) async throws {
        let playback = WebVideoPlayback(), host = HiddenWebHost()
        defer { playback.stop(); host.close() }
        playback.update(item: fixture.corrupt, muted: true, enabled: true, controls: false, loop: true)
        try await eventually("坏 WebM 未进入失败状态") {
            host.configure(playback.webView)
            return playback.failed
        }
        try expect(playback.webView == nil && !playback.isLoading && !playback.isPlaying,
                   "失败会话仍保留加载页或播放状态")
        playback.update(item: fixture.first, muted: true, enabled: true, controls: false, loop: true)
        _ = try await ready(playback, host: host)
        playback.update(item: fixture.photo, muted: true, enabled: true, controls: false, loop: true)
        try expect(playback.currentID == nil && playback.webView == nil, "照片没有清理视频")
        playback.update(item: fixture.first, muted: true, enabled: true, controls: false, loop: true)
        _ = try await ready(playback, host: host)
        playback.update(item: fixture.first, muted: true, enabled: false, controls: false, loop: true)
        try expect(playback.currentID == nil && playback.webView == nil && !playback.isPlaying,
                   "禁用播放后未清理会话")
    }

    private static func restrictedBridge(_ fixture: WebFixture) async throws {
        let playback = WebVideoPlayback(), host = HiddenWebHost()
        defer { playback.stop(); host.close() }
        playback.update(item: fixture.first, muted: true, enabled: true, controls: false, loop: true)
        let view = try await ready(playback, host: host)
        let page = try require(view.url, "缺少播放器页面 URL")
        try await evaluate(view, "window.webkit.messageHandlers.filmboxVideo.postMessage({token:'wrong-token',event:'error'})")
        try await evaluate(view, "window.webkit.messageHandlers.filmboxVideo.postMessage({token:'wrong-token',event:'state',time:999,duration:999,playing:false,muted:false})")
        await settle(0.1)
        try expect(!playback.failed && playback.currentTime < 10 && playback.duration < 10 && playback.isMuted,
                   "错误令牌消息越过真实来源校验")
        view.load(URLRequest(url: page.deletingLastPathComponent().appendingPathComponent("not-a-player.html")))
        await settle(0.25)
        try expect(view.url == page && playback.webView === view && playback.isReady && !playback.failed,
                   "非播放器主框架导航没有被拒绝，或污染当前会话")
    }

    private static func viewerPolicy(_ fixture: WebFixture) async throws {
        let playback = WebVideoPlayback(), host = HiddenWebHost()
        defer { playback.stop(); host.close() }
        playback.update(item: fixture.first, muted: true, enabled: true, controls: true, loop: false, playOnOpen: false)
        let view = try await ready(playback, host: host)
        var state = try await snapshot(view)
        try expect(state.paused && state.controls && !state.loop && view.interactive && !playback.isPlaying,
                   "查看器显示或非自动播放策略未到达真实页面")
        playback.togglePlayback()
        try await eventually("非循环查看器没有播放至结尾", timeout: 7) {
            state = try await snapshot(view)
            return state.ended && state.paused && !playback.isPlaying
        }
        try expect(playback.webView === view && playback.isReady, "播完不应销毁查看器首帧")
    }

    private static func browseBridge(_ fixture: WebFixture) async throws {
        let browse = BrowseVideoPlayback(), host = HiddenWebHost()
        defer { browse.stop(); host.close() }
        browse.update(item: fixture.first, muted: true, enabled: true)
        let first = try require(browse.webPlayback, "卷轴没有选择 WebM 后端")
        let view = try await ready(first, host: host)
        try await eventually("WebM 状态没有回传卷轴") { browse.isReady && browse.isPlaying && !browse.failed }
        try expect(browse.player == nil && browse.isMuted, "卷轴创建了双重播放器或丢失默认静音")
        browse.togglePlayback()
        try await eventually("卷轴暂停未到达 WebM") { try await snapshot(view).paused && !browse.isPlaying }
        try await evaluate(view, "document.getElementById('video').volume=0")
        browse.update(item: fixture.first, muted: false, enabled: true)
        await settle(0.2)
        let paused = try await snapshot(view)
        try expect(browse.webPlayback === first && first.webView === view && paused.paused && !paused.muted && !browse.isMuted,
                   "卷轴同身份刷新覆盖暂停、静音或单一会话")

        // Suspend before the asynchronous page exists. This permits checking
        // carried unmute state without ever playing the sine-wave audio aloud.
        browse.update(item: fixture.second, muted: false, enabled: true)
        let second = try require(browse.webPlayback, "新项目没有建立 WebM 会话")
        second.setSuspended(true)
        let next = try await prepared(second, host: host)
        try await eventually("新页面未准备静音检查 DOM") {
            let found: Bool = try await value(next, expression: "!!document.getElementById('video')")
            return found
        }
        try await evaluate(next, "document.getElementById('video').volume=0")
        second.setSuspended(false)
        _ = try await ready(second, host: host)
        try await eventually("新 WebM 未回传卷轴播放状态") { browse.isReady && browse.isPlaying }
        let carriedState = try await snapshot(next)
        try expect(second !== first && first.webView == nil && browse.player == nil
                   && !browse.isMuted && !carriedState.muted, "切项没有保留声音设置或旧会话仍存活")
        browse.update(item: fixture.photo, muted: false, enabled: true)
        try expect(browse.webPlayback == nil && browse.player == nil && browse.currentID == nil
                   && !browse.isReady && !browse.isPlaying, "卷轴切到照片未清理共享播放器")
    }
}

@MainActor private final class HiddenWebHost {
    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 640, height: 360),
                          styleMask: .borderless, backing: .buffered, defer: false)
    let host = WebVideoHostView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    init() { window.isReleasedWhenClosed = false; window.contentView = host }
    func configure(_ view: RestrictedVideoWebView?) { host.configure(view); window.layoutIfNeeded() }
    func close() { host.configure(nil); window.contentView = nil }
}

private struct WebFixture {
    let root: URL
    let first: MediaItem
    let second: MediaItem
    let photo: MediaItem
    let corrupt: MediaItem

    static func make() throws -> WebFixture {
        let base = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1])
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/Fixtures")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Filmbox-WebPlayback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let first = root.appendingPathComponent("合成 WebM 一.webm")
            let second = root.appendingPathComponent("合成 WebM 二.webm")
            let corrupt = root.appendingPathComponent("损坏.webm")
            try FileManager.default.copyItem(at: base.appendingPathComponent("vp9-opus.webm"), to: first)
            try FileManager.default.copyItem(at: first, to: second)
            try Data("not-a-WebM".utf8).write(to: corrupt)
            func item(_ url: URL, _ kind: MediaKind) -> MediaItem {
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                return MediaItem(url: url, kind: kind, fileSize: bytes, modifiedDate: Date(timeIntervalSince1970: 1_700_000_000),
                                 createdDate: Date(timeIntervalSince1970: 1_700_000_000))
            }
            return WebFixture(root: root, first: item(first, .video), second: item(second, .video),
                              photo: item(root.appendingPathComponent("photo.jpg"), .image), corrupt: item(corrupt, .video))
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private struct VideoState: Decodable {
    let time: Double
    let duration: Double
    let paused: Bool
    let ended: Bool
    let muted: Bool
    let volume: Double
    let controls: Bool
    let loop: Bool
    let readyState: Int
    let width: Int
    let height: Int
    let source: String
}
private struct FrameResult: Decodable { let bytes: Int; let pixel: [Int] }
private struct WebCheckFailure: Error, CustomStringConvertible { let description: String }

@MainActor private func prepared(_ playback: WebVideoPlayback, host: HiddenWebHost) async throws -> RestrictedVideoWebView {
    try await eventually("没有安装真实 WKWebView", timeout: 10) {
        try expect(!playback.failed, "WebM 准备失败")
        host.configure(playback.webView)
        return playback.webView != nil
    }
    return try require(playback.webView, "缺少 WKWebView")
}

@MainActor private func ready(_ playback: WebVideoPlayback, host: HiddenWebHost) async throws -> RestrictedVideoWebView {
    let view = try await prepared(playback, host: host)
    try await eventually("首帧没有通过真实 WebKit 桥接就绪", timeout: 12) {
        try expect(!playback.failed, "WebKit 媒体加载或来源校验失败")
        host.configure(playback.webView)
        return playback.isReady
    }
    return view
}

@MainActor private func snapshot(_ view: WKWebView) async throws -> VideoState {
    try await value(view, expression: """
    (()=>{const v=document.getElementById('video');return {time:v.currentTime,duration:Number.isFinite(v.duration)?v.duration:0,
    paused:v.paused,ended:v.ended,muted:v.muted,volume:v.volume,controls:v.controls,loop:v.loop,readyState:v.readyState,
    width:v.videoWidth,height:v.videoHeight,source:v.currentSrc||v.src};})()
    """)
}

@MainActor private func value<T: Decodable>(_ view: WKWebView, expression: String) async throws -> T {
    let text: String = try await withCheckedThrowingContinuation { continuation in
        view.evaluateJavaScript("JSON.stringify(\(expression))") { result, error in
            if let error { continuation.resume(throwing: error) }
            else if let text = result as? String { continuation.resume(returning: text) }
            else { continuation.resume(throwing: WebCheckFailure(description: "JavaScript 未返回可读取结果")) }
        }
    }
    return try JSONDecoder().decode(T.self, from: Data(text.utf8))
}

@MainActor private func evaluate(_ view: WKWebView, _ body: String) async throws {
    let _: Bool = try await value(view, expression: "(()=>{\(body);return true;})()")
}

@MainActor private func mediaURL(_ view: WKWebView) async throws -> URL {
    let state = try await snapshot(view)
    return try require(URL(string: state.source), "媒体 URL 不可读取")
}

private func status(_ url: URL) async throws -> Int {
    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"
    request.timeoutInterval = 3
    let (_, response) = try await URLSession.shared.data(for: request)
    return (response as? HTTPURLResponse)?.statusCode ?? 0
}

@MainActor private func eventually(_ reason: String, timeout: TimeInterval = 7,
                                    _ condition: @MainActor () async throws -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !(try await condition()) {
        try expect(ProcessInfo.processInfo.systemUptime < deadline, reason)
        await settle(0.04)
    }
}
@MainActor private func settle(_ interval: TimeInterval) async { try? await Task.sleep(for: .seconds(interval)) }
private func expect(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
    guard try condition() else { throw WebCheckFailure(description: reason) }
}
private func require<T>(_ value: T?, _ reason: String) throws -> T {
    guard let value else { throw WebCheckFailure(description: reason) }
    return value
}
