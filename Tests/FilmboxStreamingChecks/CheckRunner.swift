import AppKit
import AVKit
import SwiftUI
import FilmboxCore

@main @MainActor private enum StreamingChecks {
    struct Failure: Error { let message: String }
    static var assertions = 0
    static var base: URL { URL(string: Bundle.main.object(forInfoDictionaryKey: "StreamCheckURL") as! String)! }
    static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }; assertions += 1
    }
    static func main() async {
        _ = NSApplication.shared
        do { try await run() } catch { print("FAIL: \(error)"); exit(1) }
    }
    static func run() async throws {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "FilmboxDevelopmentCache") as? String,
              path.contains("filmbox-streaming.") else { throw Failure(message: "requires isolated cache") }
        let source = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "StreamCheckSource") as! String)
        let length = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
        let media = MediaItem(cloud: CloudMediaReference(accountID: UUID(), fileID: "stream", parentID: "/",
            remotePath: "/video.mp4", revision: UUID().uuidString), kind: .video, fileSize: length,
            modifiedDate: .now, createdDate: .now, pixelWidth: 640, pixelHeight: 360, duration: 40)
        let resolved = CloudResolvedAsset(url: base.appendingPathComponent("video.mp4"),
            headers: ["Authorization": "Bearer synthetic-stream-check"], expiresAt: nil, thumbnailAvailable: nil, credential: nil)
        let playback = BrowseVideoPlayback(resolveAsset: { _ in resolved })
        let host = NSHostingView(rootView: BrowseVideoSurface(playback: playback))
        let window = makeWindow(host)
        defer { playback.stop(); window.close() }
        playback.update(item: media, muted: true, enabled: true)
        try expect(playback.isLoading && playback.currentID == media.id, "initial load must be visible immediately")
        try await eventually("cloud stream did not begin before the complete file arrived", seconds: 18) {
            playback.player?.currentTime().seconds ?? 0 > 0.25 && playback.isReady && !playback.isLoading && playback.isPlaying
        }
        let first = try await stats()
        try expect(first.bytes < first.length, "stream playback must not require the entire original")
        try expect(playback.player?.isMuted == true && playback.usesRemoteStream, "cloud stream must preserve mute and source identity")
        print("✓ 云端首帧在原件未完整下载时播放，已接收 \(first.bytes) / \(first.length) 字节")
        try await eventually("roll did not restore its loading indicator after the network gate exhausted its buffer", seconds: 20) {
            playback.isLoading && playback.isReady && playback.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
        }
        try expect(playback.loadingTitle == MediaLoadingText.downloading && !playback.isPlaying && playback.playbackRequested,
            "a stalled stream must show downloading, retain its last frame and preserve play intent")
        playback.togglePlayback()
        try await eventually("manual pause during buffering must remove the loading indicator") { !playback.isLoading && !playback.playbackRequested }
        let paused = playback.player!.currentTime().seconds
        try await control("open")
        try await Task.sleep(for: .milliseconds(600))
        try expect(playback.player?.timeControlStatus == .paused && abs(playback.player!.currentTime().seconds - paused) < 0.1,
            "network recovery cannot undo the user's explicit pause")
        playback.togglePlayback()
        try await eventually("manual resume did not continue the existing stream") { playback.isPlaying && !playback.isLoading && playback.player!.currentTime().seconds > paused + 0.2 }
        playback.stop()
        try expect(playback.player == nil && !playback.isLoading && !playback.usesRemoteStream, "leaving video must clear player and loading state")
        try expect(CloudTransferCenter.shared.snapshot(for: media.id)?.isOriginalCached != true, "streamed bytes cannot masquerade as a fully cached original")
        try await eventuallyAsync("outgoing stream did not cancel", seconds: 8) { try await stats().active == 0 }
        print("✓ 缓冲不足重现加载提示，手动暂停保持暂停，离开停止流播")

        try await control("gated")
        let before = try await stats().bytes
        let canvas = AVPlayerView()
        canvas.controlsStyle = .floating
        let viewerWindow = makeWindow(canvas)
        let coordinator = VideoCanvas.Coordinator(resolveAsset: { _ in resolved })
        defer { coordinator.stop(); viewerWindow.close() }
        coordinator.configure(view: canvas, item: media, playOnOpen: true, command: 0)
        try expect(coordinator.isLoading, "viewer must show initial progress")
        try await eventually("viewer did not start partial-file playback", seconds: 18) {
            canvas.player?.timeControlStatus == .playing && (canvas.player?.currentTime().seconds ?? 0) > 0.25 && !coordinator.isLoading
        }
        let partial = try await stats()
        try expect(partial.bytes - before < partial.length, "viewer must also begin before the full file arrives")
        try await eventually("viewer did not show its central buffering indicator again", seconds: 20) {
            coordinator.isLoading && canvas.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
        }
        canvas.layoutSubtreeIfNeeded()
        let indicator = canvas.subviews.first { $0 is NSHostingView<VideoLoadingIndicator> }
        try expect(indicator != nil && indicator!.bounds.width > 30 && indicator!.bounds.height > 10,
            "viewer loading indicator must have real visible layout")
        try expect(coordinator.loadingTitle == MediaLoadingText.downloading, "viewer wording must match the roll")
        let stalledAt = canvas.player!.currentTime().seconds
        try await control("open")
        try await eventually("viewer failed to resume automatically after network recovery", seconds: 12) {
            !coordinator.isLoading && canvas.player?.timeControlStatus == .playing && canvas.player!.currentTime().seconds > stalledAt + 0.2
        }
        canvas.player?.pause()
        coordinator.configure(view: canvas, item: media, playOnOpen: true, command: 0)
        try await Task.sleep(for: .milliseconds(200))
        try expect(canvas.player?.timeControlStatus == .paused && !coordinator.isLoading, "native controls pause must not be treated as buffering or restart on re-render")
        coordinator.stop()
        try expect(!coordinator.isLoading && canvas.player == nil, "viewer teardown must clear buffering and network ownership")
        try await eventuallyAsync("viewer stream did not cancel", seconds: 8) { try await stats().active == 0 }
        print("✓ 查看器未下完整件即播放，真实断流后显示中央提示，网络恢复自动续播")
        print("\(assertions)项真实HTTP Range流播断言通过")
    }
    struct Stats: Decodable { let bytes: Int64; let length: Int64; let active: Int }
    static func stats() async throws -> Stats {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        return try JSONDecoder().decode(Stats.self, from: data)
    }
    static func control(_ mode: String) async throws {
        _ = try await URLSession.shared.data(from: URL(string: base.absoluteString + "/control?mode=" + mode)!)
    }
    static func makeWindow(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 640, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.contentView = view; window.orderBack(nil)
        view.layoutSubtreeIfNeeded()
        return window
    }
    static func eventually(_ message: String, seconds: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }; try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure(message: message)
    }
    static func eventuallyAsync(_ message: String, seconds: Double, _ condition: () async throws -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if try await condition() { return }; try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure(message: message)
    }
}
