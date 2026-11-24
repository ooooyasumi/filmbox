import AppKit
@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import FilmboxCore
import Foundation
import SwiftUI

/// Runs the actual playback component with encoded temporary sources. A silent
/// AAC track allows mute/unmute checks without producing sound or using a device.
@main
@MainActor
private struct PlaybackCheckRunner {
    private static var passed = 0

    static func main() async {
        _ = NSApplication.shared
        let fixture: PlaybackFixture
        do { fixture = try await PlaybackFixture.make() }
        catch {
            print("✗ 无法创建播放检查夹具：\(error)")
            exit(EXIT_FAILURE)
        }
        defer { fixture.remove() }

        let checks: [(String, (PlaybackFixture) async throws -> Void)] = [
            ("真实夹具含可解码视频和静音 AAC 音轨", fixtureTracks),
            ("当前视频自动播放且默认静音", defaultMutedAutoplay),
            ("重复更新同一视频保留播放器和进度", repeatedUpdate),
            ("手动暂停后重复更新不会重新播放", manualPauseSurvivesUpdate),
            ("当前视频解除静音且后续视频沿用", unmuteFollowsNextItem),
            ("切到照片立即暂停并清除旧播放器", imageStopsVideo),
            ("浏览失去播放资格立即清理播放器", disabledStopsVideo),
            ("停止播放清理播放器且恢复初始状态", stopClearsPlayback),
            ("过期加载和结束事件不会污染新视频", staleEventsStayIsolated),
            ("坏文件进入失败状态并可切回正常视频", failedFileCanRecover),
            ("相同项目和元数据下缺失或损坏源恢复后可重试", unchangedItemCanRecover),
            ("返回已离开的视频重新自动播放", returningStartsFresh),
            ("短视频播完连续循环", shortVideoLoops),
            ("真实视频层首帧前透明并可清理", surfaceKeepsPosterUntilReady),
            ("窗口观察器覆盖遮挡最小化关闭迁移和拆卸", windowVisibilityLifecycle)
        ]
        for (name, body) in checks {
            do {
                try await body(fixture)
                passed += 1
                print("✓ \(name)")
            } catch { print("✗ \(name)：\(error)") }
        }
        print("\(passed)/\(checks.count) 卷轴视频播放检查通过")
        if passed != checks.count { exit(EXIT_FAILURE) }
    }

    private static func fixtureTracks(_ fixture: PlaybackFixture) async throws {
        for item in [fixture.first, fixture.second] {
            let asset = AVURLAsset(url: item.url)
            let videos = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            try expect(videos.count == 1, "夹具缺少视频轨道")
            try expect(audio.count == 1, "夹具缺少音轨，无法真实覆盖静音设置")
            let generator = AVAssetImageGenerator(asset: asset)
            let image = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
            try expect(image.width == 160 && image.height == 120, "编码夹具无法解码真实像素")
        }
    }

    private static func defaultMutedAutoplay(_ fixture: PlaybackFixture) async throws {
        let playback = BrowseVideoPlayback()
        defer { playback.stop() }
        try expect(playback.isMuted, "初始默认状态必须静音")
        playback.update(item: fixture.first, muted: true, enabled: true)
        let player = try require(playback.player, "当前视频未创建播放器")
        try expect(player.isMuted && playback.isMuted && playback.currentID == fixture.first.id,
                   "自动播放第一次必须先静音且绑定当前项目")
        try await eventually("当前视频时间没有推进") {
            player.currentTime().seconds > 0.12 && playback.isPlaying
        }
    }

    private static func repeatedUpdate(_ fixture: PlaybackFixture) async throws {
        let playback = BrowseVideoPlayback()
        defer { playback.stop() }
        playback.update(item: fixture.first, muted: true, enabled: true)
        let player = try require(playback.player, "未创建播放器")
        try await eventually("首次播放未开始") { player.currentTime().seconds > 0.15 }
        let before = player.currentTime().seconds
        for _ in 0..<8 { playback.update(item: fixture.first, muted: true, enabled: true) }
        try expect(playback.player === player, "相同项目更新重建了 AVPlayer")
        try expect(player.currentTime().seconds >= before - 0.04, "相同项目更新重置了进度")
        try await eventually("相同项目更新后未继续播放") { player.currentTime().seconds > before + 0.08 }
    }

    private static func manualPauseSurvivesUpdate(_ fixture: PlaybackFixture) async throws {
        let playback = BrowseVideoPlayback()
        defer { playback.stop() }
        playback.update(item: fixture.first, muted: true, enabled: true)
        let player = try require(playback.player, "未创建播放器")
        try await eventually("首次播放未开始") { player.currentTime().seconds > 0.12 && playback.isPlaying }
        playback.togglePlayback()
        try await eventually("暂停后状态没有更新") { !playback.isPlaying && player.rate == 0 }
        let pausedTime = player.currentTime().seconds
        playback.update(item: fixture.first, muted: true, enabled: true)
        await settle(0.15)
        try expect(playback.player === player && !playback.isPlaying && player.rate == 0,
                   "视图刷新覆盖了手动暂停")
        try expect(abs(player.currentTime().seconds - pausedTime) < 0.04, "暂停期间视频继续推进")
        playback.togglePlayback()
        try await eventually("手动恢复没有继续播放") { player.currentTime().seconds > pausedTime + 0.08 }
    }

    private static func unmuteFollowsNextItem(_ fixture: PlaybackFixture) async throws {
        let playback = BrowseVideoPlayback()
        defer { playback.stop() }
        playback.update(item: fixture.first, muted: true, enabled: true)
        let first = try require(playback.player, "未创建第一个播放器")
        playback.update(item: fixture.first, muted: false, enabled: true)
        try expect(playback.player === first && !first.isMuted && !playback.isMuted,
                   "解除静音不应重建当前播放器")
        playback.update(item: fixture.second, muted: false, enabled: true)
        let second = try require(playback.player, "未创建后续播放器")
        try expect(first !== second && first.rate == 0, "切视频后旧播放器仍然播放")
        try expect(!second.isMuted && !playback.isMuted, "后续视频没有沿用解除静音状态")
        try await eventually("解除静音后的后续视频未自动播放") { second.currentTime().seconds > 0.12 }
    }

    private static func imageStopsVideo(_ fixture: PlaybackFixture) async throws {
        let playback = BrowseVideoPlayback()
        defer { playback.stop() }
        playback.update(item: fixture.first, muted: true, enabled: true)
        let old = try require(playback.player, "未创建播放器")
        try await eventually("首次播放未开始") { old.currentTime().seconds > 0.1 }
        playback.update(item: fixture.photo, muted: true, enabled: true)
        try expect(playback.player == nil && playback.currentID == nil && old.rate == 0 && !playback.isPlaying,
                   "照片出现后旧视频没有释放并暂停")
        await settle(0.12)
        try expect(playback.player == nil, "旧回调重新挂回了照片的播放器")
    }

    private static func disabledStopsVideo(_ fixture: PlaybackFixture) async throws {
        let playback = BrowseVideoPlayback()
        defer { playback.stop() }
        playback.update(item: fixture.first, muted: true, enabled: true)
        let old = try require(playback.player, "未创建播放器")
        playback.update(item: fixture.first, muted: true, enabled: false)
        try expect(playback.player == nil && playback.currentID == nil && old.rate == 0 && !playback.isPlaying,
                   "关闭自动播放资格时没有立即清理")
        await settle(0.15)
        try expect(playback.player == nil && !playback.isPlaying, "禁用后异步加载恢复了播放")
    }

    private static func stopClearsPlayback(_ fixture: PlaybackFixture) async throws {
        let playback = BrowseVideoPlayback()
        playback.update(item: fixture.first, muted: true, enabled: true)
        let old = try require(playback.player, "未创建播放器")
        try await eventually("首次播放未开始") { old.currentTime().seconds > 0.1 }
        playback.stop()
        try expect(playback.player == nil && playback.currentID == nil && old.rate == 0
                   && !playback.isPlaying && !playback.isReady && !playback.failed,
                   "stop 后有播放器或状态残留")
        playback.stop()
        await settle(0.15)
        try expect(playback.player == nil, "重复 stop 后出现过期播放器")
    }

    private static func staleEventsStayIsolated(_ fixture: PlaybackFixture) async throws {
        let playback = BrowseVideoPlayback()
        defer { playback.stop() }
        playback.update(item: fixture.first, muted: true, enabled: true)
        let old = try require(playback.player, "未创建旧播放器")
        try await eventually("旧播放器未排入项目") { old.currentItem != nil }
        let oldItem = try require(old.currentItem, "旧播放器没有项目")
        // Replace before the first item can finish loading. Also deliver an old
        // end notification through the real observer path, locally in-process.
        playback.update(item: fixture.corrupt, muted: true, enabled: true)
        playback.update(item: fixture.second, muted: false, enabled: true)
        let current = try require(playback.player, "未创建最新播放器")
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
        try await eventually("最新视频没有开始播放") { current.currentTime().seconds > 0.12 }
        await settle(0.15)
        try expect(playback.player === current && playback.currentID == fixture.second.id
                   && (current.currentItem?.asset as? AVURLAsset)?.url == fixture.second.url,
                   "旧回调替换了新播放器")
        try expect(!playback.failed && !playback.isMuted && !current.isMuted && old.rate == 0,
                   "旧失败或循环回调污染了新播放器状态")
    }

    private static func failedFileCanRecover(_ fixture: PlaybackFixture) async throws {
        let playback = BrowseVideoPlayback()
        defer { playback.stop() }
        playback.update(item: fixture.corrupt, muted: true, enabled: true)
        try await eventually("无效文件没有进入失败状态") { playback.failed }
        try expect(!playback.isPlaying && !playback.isReady, "失败项目仍被报告为可播放")
        playback.update(item: fixture.first, muted: true, enabled: true)
        let player = try require(playback.player, "失败后无法建立正常播放器")
        try await eventually("失败后切回正常项目未恢复") {
            player.currentTime().seconds > 0.12 && !playback.failed
        }
    }

    private static func unchangedItemCanRecover(_ fixture: PlaybackFixture) async throws {
        // Both paths retain the exact same MediaItem, including ID, file size,
        // and modification date. Availability can change before a library scan
        // notices new metadata (for example, immediately after remounting).
        for startsCorrupt in [false, true] {
            let url = fixture.root.appendingPathComponent("recovered-\(UUID().uuidString).mp4")
            if startsCorrupt { try Data("temporarily-corrupt-video".utf8).write(to: url) }
            let item = MediaItem(url: url, kind: .video, fileSize: 0,
                                 modifiedDate: fixture.first.modifiedDate, createdDate: fixture.first.createdDate,
                                 pixelWidth: 160, pixelHeight: 120, duration: 0.8)
            let playback = BrowseVideoPlayback()
            defer { playback.stop() }
            playback.update(item: item, muted: true, enabled: true)
            try await eventually("不可读或损坏项目没有进入失败状态") { playback.failed }
            let failedPlayer = playback.player
            try expect(playback.currentID == item.id && !playback.isPlaying,
                       "失败项目没有保留当前身份或未停止播放")
            if startsCorrupt { try FileManager.default.removeItem(at: url) }
            try FileManager.default.copyItem(at: fixture.first.url, to: url)

            // No new ID, metadata refresh, or stop call is allowed to disguise
            // the retry: an external update of this exact item must recover it.
            playback.update(item: item, muted: true, enabled: true)
            let recovered = try require(playback.player, "同一项目恢复后未重新建立播放器")
            try expect(recovered !== failedPlayer && (failedPlayer?.rate ?? 0) == 0,
                       "重试沿用了失败播放器或没有暂停旧播放器")
            try await eventually("同一项目恢复后没有自动播放") {
                recovered.currentTime().seconds > 0.12 && playback.isPlaying && !playback.failed
            }
            await settle(0.12)
            try expect(playback.player === recovered && playback.currentID == item.id
                       && !playback.failed && recovered.isMuted,
                       "旧失败回调污染了同一项目的重试结果")
        }
    }

    private static func returningStartsFresh(_ fixture: PlaybackFixture) async throws {
        let playback = BrowseVideoPlayback()
        defer { playback.stop() }
        playback.update(item: fixture.first, muted: true, enabled: true)
        let original = try require(playback.player, "未创建原播放器")
        try await eventually("首次播放未开始") { original.currentTime().seconds > 0.12 }
        playback.togglePlayback()
        playback.update(item: fixture.photo, muted: true, enabled: true)
        playback.update(item: fixture.first, muted: true, enabled: true)
        let returned = try require(playback.player, "返回时未创建播放器")
        try expect(returned !== original && original.rate == 0, "离开项目后返回沿用了旧的暂停播放器")
        try await eventually("返回后没有重新自动播放") { returned.currentTime().seconds > 0.12 && playback.isPlaying }
    }

    private static func shortVideoLoops(_ fixture: PlaybackFixture) async throws {
        let playback = BrowseVideoPlayback()
        defer { playback.stop() }
        playback.update(item: fixture.first, muted: true, enabled: true)
        let player = try require(playback.player, "未创建播放器")
        try await eventually("短视频没有推进到片尾附近") { player.currentTime().seconds > 0.6 }
        var previous = player.currentTime().seconds
        var sawWrap = false
        try await eventually("短视频到片尾后没有循环", timeout: 4) {
            let current = player.currentTime().seconds
            if previous > 0.6 && current < previous - 0.3 { sawWrap = true }
            previous = current
            return sawWrap && current > 0.12 && playback.isPlaying
        }
        try expect(playback.player === player && player.isMuted, "循环不应重建播放器或改变静音状态")
    }

    private static func surfaceKeepsPosterUntilReady(_ fixture: PlaybackFixture) async throws {
        let playback = BrowseVideoPlayback()
        let view = BrowseVideoLayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { view.tearDown(); playback.stop(); window.contentView = nil }
        let layer = try require(view.layer as? AVPlayerLayer, "真实视图没有建立 AVPlayerLayer")
        try expect(layer.opacity == 0 && layer.player == nil && !window.isVisible,
                   "没有视频时视频层必须透明且检查窗口不得显示")
        playback.update(item: fixture.first, muted: true, enabled: true)
        view.configure(playback: playback)
        try expect(layer.player === playback.player && layer.opacity == 0 && !playback.isReady,
                   "首帧未就绪时应接入播放器并保留透明海报层")
        window.layoutIfNeeded(); view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await eventually("隐藏原生层未准备首帧") { playback.isReady && layer.isReadyForDisplay }
        try expect(layer.opacity == 1 && !window.isVisible, "真实首帧就绪后没有显示视频层")
        let player = try require(playback.player, "播放层丢失播放器")
        view.tearDown()
        try expect(layer.player == nil && layer.opacity == 0 && !playback.isReady,
                   "拆卸视频层后透明度或显示状态未清理")
        try expect(playback.player === player, "视图拆卸不应擅自替换卷轴播放器")
    }

    private static func windowVisibilityLifecycle(_ fixture: PlaybackFixture) async throws {
        // No window is ordered onscreen. Override only the queried state and
        // deliver local AppKit notifications to test the actual observer.
        let first = VisibilityCheckWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 100, height: 100),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
        let second = VisibilityCheckWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 100, height: 100),
                                           styleMask: [.borderless], backing: .buffered, defer: false)
        let view = BrowsePlaybackVisibilityView(frame: .zero)
        var reported: [Bool] = []
        view.configure { reported.append($0) }
        first.contentView = view
        defer { view.tearDown(); first.contentView = nil; second.contentView = nil }
        await settle(0.04)
        try expect(reported == [false], "未显示的窗口应报告 false，重复挂载不能重复通知")

        first.testVisible = true; first.testOcclusion = .visible
        NotificationCenter.default.post(name: NSWindow.didExposeNotification, object: first)
        await settle(0.04)
        try expect(reported.last == true, "可见且未遮挡的窗口没有允许播放")
        let beforeKeyChange = reported.count
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: first)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: first)
        await settle(0.04)
        try expect(reported.last == true && reported.count == beforeKeyChange,
                   "仅失去 keyWindow 或重复窗口更新不应中断播放")

        NotificationCenter.default.post(name: NSWindow.willMiniaturizeNotification, object: first)
        await settle(0.04)
        try expect(reported.last == false, "最小化开始时没有撤销播放资格")
        first.testMiniaturized = true
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: first)
        first.testMiniaturized = false
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: first)
        await settle(0.04)
        try expect(reported.last == true, "退出最小化后没有恢复可见性")

        first.testOcclusion = []
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: first)
        await settle(0.04)
        try expect(reported.last == false, "完全遮挡时没有暂停资格")
        first.testOcclusion = .visible
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: first)
        await settle(0.04)
        try expect(reported.last == true, "重新可见时没有恢复资格")

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: first)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: first)
        await settle(0.04)
        try expect(reported.last == false, "关闭后的普通更新不得恢复播放")
        first.testVisible = false; first.testOcclusion = []
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: first)
        first.testVisible = true; first.testOcclusion = .visible
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: first)
        await settle(0.04)
        try expect(reported.last == true, "同一个窗口重新打开后没有恢复资格")

        second.testVisible = true; second.testOcclusion = .visible
        let beforeMigration = reported.count
        second.contentView = view
        await settle(0.04)
        try expect(view.window === second && Array(reported.dropFirst(beforeMigration)) == [false, true],
                   "迁移宿主窗口时必须先报告旧窗口 false 再报告新窗口 true")
        view.tearDown()
        await settle(0.04)
        try expect(reported.last == false, "拆卸观察器时没有撤销播放资格")
        let afterTearDown = reported.count
        NotificationCenter.default.post(name: NSWindow.didExposeNotification, object: second)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: first)
        await settle(0.04)
        try expect(reported.count == afterTearDown, "拆卸后仍响应旧窗口通知")
    }
}

@MainActor private final class VisibilityCheckWindow: NSWindow {
    var testVisible = false
    var testMiniaturized = false
    var testOcclusion: NSWindow.OcclusionState = []
    override var isVisible: Bool { testVisible }
    override var isMiniaturized: Bool { testMiniaturized }
    override var occlusionState: NSWindow.OcclusionState { testOcclusion }
}

private struct PlaybackFixture {
    let root: URL
    let first: MediaItem
    let second: MediaItem
    let photo: MediaItem
    let corrupt: MediaItem

    static func make() async throws -> PlaybackFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Filmbox-PlaybackChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let firstURL = root.appendingPathComponent("静音轨道 一.mp4")
            let secondURL = root.appendingPathComponent("静音轨道 二.mp4")
            try await writeSilentVideo(at: firstURL)
            try FileManager.default.copyItem(at: firstURL, to: secondURL)
            let badURL = root.appendingPathComponent("损坏.mp4")
            try Data("not-a-video".utf8).write(to: badURL)
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            func media(_ url: URL, _ kind: MediaKind) -> MediaItem {
                MediaItem(url: url, kind: kind, fileSize: 0, modifiedDate: date,
                          createdDate: date, pixelWidth: 160, pixelHeight: 120,
                          duration: kind == .video ? 0.8 : nil)
            }
            return PlaybackFixture(root: root, first: media(firstURL, .video), second: media(secondURL, .video),
                                   photo: media(root.appendingPathComponent("photo.jpg"), .image),
                                   corrupt: media(badURL, .video))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func writeSilentVideo(at url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 160, AVVideoHeightKey: 120,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 80_000, AVVideoExpectedSourceFrameRateKey: 15]
    ])
    let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 120
    ])
    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
    ])
    try expect(writer.canAdd(video) && writer.canAdd(audio), "编码器不支持 H.264 / AAC 夹具")
    writer.add(video); writer.add(audio)
    try expect(writer.startWriting(), "无法开始夹具编码：\(String(describing: writer.error))")
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<12 {
        try waitForInput(video, writer: writer)
        var buffer: CVPixelBuffer?
        try expect(CVPixelBufferCreate(kCFAllocatorDefault, 160, 120, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess,
                   "无法分配夹具像素")
        let value = try require(buffer, "缺少像素缓冲")
        CVPixelBufferLockBaseAddress(value, [])
        memset(CVPixelBufferGetBaseAddress(value), Int32(20 + frame * 15), CVPixelBufferGetDataSize(value))
        CVPixelBufferUnlockBaseAddress(value, [])
        try expect(pixels.append(value, withPresentationTime: CMTime(value: Int64(frame), timescale: 15)),
                   "视频帧追加失败：\(String(describing: writer.error))")
    }
    video.markAsFinished()

    var description = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
                                                  mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                  mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                                  mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    try expect(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
                                             layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil, formatDescriptionOut: &format) == noErr,
               "无法建立 PCM 音频格式")
    let audioFormat = try require(format, "缺少音频格式")
    let totalSamples = 35_280
    for start in stride(from: 0, to: totalSamples, by: 1024) {
        try waitForInput(audio, writer: writer)
        let count = min(1024, totalSamples - start)
        let silentBytes = [UInt8](repeating: 0, count: count * 4)
        var block: CMBlockBuffer?
        try expect(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                     blockLength: silentBytes.count, blockAllocator: kCFAllocatorDefault,
                                                     customBlockSource: nil, offsetToData: 0,
                                                     dataLength: silentBytes.count, flags: 0,
                                                     blockBufferOut: &block) == noErr,
                   "无法分配静音样本")
        let audioBlock = try require(block, "缺少静音样本")
        try expect(silentBytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: audioBlock,
                                          offsetIntoDestination: 0, dataLength: $0.count)
        } == noErr, "无法写入静音样本")
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44_100),
                                       presentationTimeStamp: CMTime(value: Int64(start), timescale: 44_100),
                                       decodeTimeStamp: .invalid)
        var sampleSize = 4
        var sample: CMSampleBuffer?
        try expect(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: audioBlock,
                                             formatDescription: audioFormat, sampleCount: count,
                                             sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                             sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                             sampleBufferOut: &sample) == noErr,
                   "无法建立音频样本")
        try expect(audio.append(try require(sample, "缺少音频样本")),
                   "音频追加失败：\(String(describing: writer.error))")
    }
    audio.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: 12, timescale: 15))
    await writer.finishWriting()
    try expect(writer.status == .completed, "夹具编码未完成：\(String(describing: writer.error))")
}

private func waitForInput(_ input: AVAssetWriterInput, writer: AVAssetWriter) throws {
    let start = ProcessInfo.processInfo.systemUptime
    while !input.isReadyForMoreMediaData {
        try expect(writer.status != .failed, "夹具编码失败：\(String(describing: writer.error))")
        try expect(ProcessInfo.processInfo.systemUptime - start < 15, "夹具编码超时")
        Thread.sleep(forTimeInterval: 0.002)
    }
}

@MainActor
private func eventually(_ reason: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() {
        try expect(ProcessInfo.processInfo.systemUptime < deadline, reason)
        await settle(0.02)
    }
}

@MainActor
private func settle(_ interval: TimeInterval) async {
    try? await Task.sleep(for: .seconds(interval))
}

private struct PlaybackCheckFailure: Error, CustomStringConvertible { let description: String }

private func expect(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
    guard try condition() else { throw PlaybackCheckFailure(description: reason) }
}

private func require<T>(_ value: T?, _ reason: String) throws -> T {
    guard let value else { throw PlaybackCheckFailure(description: reason) }
    return value
}
