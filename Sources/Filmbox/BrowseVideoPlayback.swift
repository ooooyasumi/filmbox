import AppKit
import AVFoundation
import Observation
import QuartzCore
import SwiftUI
import FilmboxCore

/// One playback session belongs to the roll, rather than to its reusable cells.
@MainActor @Observable
final class BrowseVideoPlayback {
    private(set) var player: AVPlayer?
    private(set) var webPlayback: WebVideoPlayback?
    private(set) var currentID: String?
    private(set) var isPlaying = false
    private(set) var isMuted = true
    private(set) var isReady = false
    private(set) var failed = false
    private(set) var isLoading = false
    private(set) var usesRemoteStream = false
    var loadingTitle: String { usesRemoteStream ? MediaLoadingText.downloading : MediaLoadingText.loading }
    private(set) var needsOriginalDownload = false
    private(set) var isDownloadingOriginal = false
    private(set) var originalDownloadError: String?
    var originalFileSize: Int64 { media?.fileSize ?? 0 }
    var playbackRequested: Bool { webPlayback?.wantsPlayback ?? wantsPlayback }
    var canTogglePlayback: Bool { !failed && (player != nil || webPlayback?.canTogglePlayback == true) }

    @ObservationIgnored private var identity: String?
    @ObservationIgnored private var media: MediaItem?
    @ObservationIgnored private var generation = 0
    private(set) var wantsPlayback = false
    @ObservationIgnored private var itemReady = false
    @ObservationIgnored private var readySurfaces: Set<UUID> = []
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var cacheLease: UUID?
    @ObservationIgnored private let resolveAsset: @Sendable (MediaItem) async throws -> CloudResolvedAsset
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    init(resolveAsset: @escaping @Sendable (MediaItem) async throws -> CloudResolvedAsset = {
        try await MediaAssetResolver.shared.playbackAsset(for: $0)
    }) { self.resolveAsset = resolveAsset }

    func update(item: MediaItem?, muted: Bool, enabled: Bool) {
        isMuted = muted
        guard enabled, let item, item.kind == .video else {
            stop()
            return
        }

        let nextIdentity = "\(item.id)|\(item.url.absoluteString)|\(item.fileSize)|\(item.modifiedDate.timeIntervalSinceReferenceDate)|\(item.contentRevision ?? "")"
        if identity == nextIdentity, (player != nil || webPlayback != nil || preparation != nil), !failed {
            player?.isMuted = muted
            webPlayback?.setMuted(muted)
            return // A render or sound change must not undo the user's pause.
        }

        stop()
        usesRemoteStream = false
        identity = nextIdentity
        media = item
        currentID = item.id
        guard !item.isLocal || FileManager.default.isReadableFile(atPath: item.url.path) else {
            failed = true
            return
        }

        let token = generation
        if WebVideoPlayback.supports(item.url) {
            let web = WebVideoPlayback()
            webPlayback = web
            web.onStateChange = { [weak self, weak web] in
                guard let self, let web, self.generation == token, self.webPlayback === web else { return }
                self.isPlaying = web.isPlaying
                self.isMuted = web.isMuted
                self.isReady = web.isReady
                self.isLoading = web.isLoading
                self.failed = web.failed
                self.needsOriginalDownload = web.needsOriginalDownload
                self.isDownloadingOriginal = web.isDownloadingOriginal
                self.originalDownloadError = web.originalDownloadError
            }
            web.update(item: item, muted: muted, enabled: true, controls: false, loop: true)
            return
        }
        isLoading = true
        if item.isLocal {
            installNativePlayback(asset: AVURLAsset(url: item.url), token: token)
        } else {
            preparation = Task { @MainActor [weak self] in
                do {
                    let cacheLease = await MediaAssetResolver.shared.acquireViewingLease(for: item)
                    guard let self, self.generation == token, !Task.isCancelled else {
                        await MediaAssetResolver.shared.releaseViewingLease(cacheLease)
                        return
                    }
                    self.cacheLease = cacheLease
                    let resolved = try await self.resolveAsset(item)
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.preparation = nil
                    self.usesRemoteStream = !resolved.url.isFileURL
                    let options: [String: Any] = resolved.headers.isEmpty ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": resolved.headers]
                    self.installNativePlayback(asset: AVURLAsset(url: resolved.url, options: options), token: token)
                } catch {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.preparation = nil
                    self.markFailed()
                }
            }
        }
    }

    private func installNativePlayback(asset: AVURLAsset, token: Int) {
        guard generation == token else { return }
        let template = AVPlayerItem(asset: asset)
        if usesRemoteStream { template.preferredForwardBufferDuration = 4 }
        let queue = AVQueuePlayer()
        // Set sound before the first item can be played.
        queue.isMuted = isMuted
        queue.actionAtItemEnd = .advance
        queue.automaticallyWaitsToMinimizeStalling = true
        player = queue
        wantsPlayback = true
        if usesRemoteStream {
            // A looper queues clones that can open duplicate cloud streams.
            // Keep one remote item and seek it back only after it actually ends.
            queue.actionAtItemEnd = .pause
            queue.insert(template, after: nil)
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                object: template, queue: .main) { [weak self, weak queue] _ in
                Task { @MainActor [weak self, weak queue] in
                    guard let self, let queue, self.isCurrent(queue, token: token), self.wantsPlayback else { return }
                    await queue.seek(to: .zero)
                    guard self.isCurrent(queue, token: token), self.wantsPlayback else { return }
                    queue.play()
                }
            }
        } else { looper = AVPlayerLooper(player: queue, templateItem: template) }

        observations.append(queue.observe(\.currentItem, options: [.initial, .new]) { [weak self, weak queue] _, _ in
            Task { @MainActor [weak self, weak queue] in
                guard let self, let queue, self.isCurrent(queue, token: token) else { return }
                self.observeCurrentItem(of: queue, token: token)
            }
        })
        observations.append(queue.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self, weak queue] _, _ in
            Task { @MainActor [weak self, weak queue] in
                guard let self, let queue, self.isCurrent(queue, token: token) else { return }
                self.refreshPlaybackState()
            }
        })
        observations.append(queue.observe(\.status, options: [.initial, .new]) { [weak self, weak queue] _, _ in
            Task { @MainActor [weak self, weak queue] in
                guard let self, let queue, self.isCurrent(queue, token: token) else { return }
                if queue.status == .failed { self.markFailed() }
            }
        })
        if let looper {
            observations.append(looper.observe(\.status, options: [.initial, .new]) { [weak self, weak queue] observedLooper, _ in
                let didFail = observedLooper.status == .failed
                Task { @MainActor [weak self, weak queue] in
                    guard didFail, let self, let queue, self.isCurrent(queue, token: token) else { return }
                    self.markFailed()
                }
            })
        }
        queue.play()
        refreshPlaybackState()
    }

    func togglePlayback() {
        if let webPlayback { webPlayback.togglePlayback(); return }
        guard let player, !failed else { return }
        wantsPlayback.toggle()
        if wantsPlayback { player.play() }
        else { player.pause() }
        refreshPlaybackState()
    }

    func downloadOriginalAndPlay() { webPlayback?.downloadOriginalAndPlay() }

    func retry() {
        guard let media, !isDownloadingOriginal else { return }
        let muted = isMuted
        stop()
        update(item: media, muted: muted, enabled: true)
    }

    func stop() {
        generation &+= 1
        preparation?.cancel()
        preparation = nil
        webPlayback?.onStateChange = nil
        webPlayback?.stop()
        webPlayback = nil
        itemObservation?.invalidate()
        itemObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        player?.pause()
        looper?.disableLooping()
        looper = nil
        (player as? AVQueuePlayer)?.removeAllItems()
        player = nil
        currentID = nil
        identity = nil
        media = nil
        wantsPlayback = false
        itemReady = false
        readySurfaces.removeAll()
        isPlaying = false
        isReady = false
        isLoading = false
        failed = false
        usesRemoteStream = false
        needsOriginalDownload = false
        isDownloadingOriginal = false
        originalDownloadError = nil
        releaseCacheLease()
    }

    private func releaseCacheLease() {
        if let cacheLease {
            self.cacheLease = nil
            Task { await MediaAssetResolver.shared.releaseViewingLease(cacheLease) }
        }
    }

    fileprivate func reportDisplayReadiness(_ ready: Bool, player: AVPlayer, surface: UUID) {
        guard self.player === player else { return }
        if ready { readySurfaces.insert(surface) }
        else { readySurfaces.remove(surface) }
        refreshPlaybackState()
    }

    private func isCurrent(_ player: AVPlayer, token: Int) -> Bool {
        generation == token && self.player === player
    }

    private func observeCurrentItem(of queue: AVQueuePlayer, token: Int) {
        itemObservation?.invalidate()
        itemObservation = nil
        guard let item = queue.currentItem else { return }
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak queue, weak item] _, _ in
            Task { @MainActor [weak self, weak queue, weak item] in
                guard let self, let queue, let item,
                      self.isCurrent(queue, token: token), queue.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    self.itemReady = true
                    self.refreshPlaybackState()
                case .failed:
                    self.markFailed()
                case .unknown:
                    break // Keep an already displayed loop frame during the next item handoff.
                @unknown default:
                    break
                }
            }
        }
    }

    private func refreshPlaybackState() {
        guard let player, !failed else { return }
        isReady = itemReady && !readySurfaces.isEmpty
        isPlaying = wantsPlayback && player.timeControlStatus == .playing
        // A displayed frame stays visible during a later network stall. Only
        // the loading overlay returns; AVPlayer retains playback intent and
        // resumes itself when enough data is available. Never call pause here.
        isLoading = !isReady || (wantsPlayback && player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
    }

    private func markFailed() {
        if usesRemoteStream, let accountID = media?.cloud?.accountID {
            usesRemoteStream = false
            Task { await CloudGateway.shared.checkAuthenticationAfterPlaybackFailure(accountID: accountID) }
        }
        failed = true
        wantsPlayback = false
        isPlaying = false
        isReady = false
        isLoading = false
        player?.pause()
        releaseCacheLease()
    }

    isolated deinit { stop() }
}

/// Keep this above the poster even before isReady becomes true: the layer must
/// receive a player to decode its first frame. It stays transparent until then.
struct BrowseVideoSurface: View {
    let playback: BrowseVideoPlayback
    private var originalCached: Bool {
        guard let id = playback.currentID else { return false }
        return CloudTransferCenter.shared.snapshot(for: id)?.isOriginalCached == true
    }

    var body: some View {
        ZStack {
            if let web = playback.webPlayback {
                WebVideoSurface(webView: web.webView).allowsHitTesting(false)
            } else { NativeBrowseVideoSurface(playback: playback).allowsHitTesting(false) }
            if playback.isLoading, !playback.needsOriginalDownload, !playback.isDownloadingOriginal {
                GeometryReader { geometry in
                    VideoLoadingIndicator(title: playback.loadingTitle, compact: geometry.size.width < 140)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if playback.needsOriginalDownload || playback.isDownloadingOriginal {
                VStack(spacing: 8) {
                    Button(action: playback.downloadOriginalAndPlay) {
                        HStack(spacing: 8) {
                            if playback.isDownloadingOriginal { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.down.circle") }
                            Text(playback.isDownloadingOriginal ? MediaLoadingText.downloading : (originalCached ? "播放" : "下载后播放"))
                        }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 9)
                            .background(.regularMaterial, in: Capsule())
                    }.buttonStyle(.plain).disabled(playback.isDownloadingOriginal)
                    if playback.originalFileSize > 0 {
                        Text(originalCached ? "已缓存在本机" : ByteCountFormatter.string(fromByteCount: playback.originalFileSize, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = playback.originalDownloadError {
                        Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                    }
                }.padding(16).frame(maxWidth: 300)
            }
        }
    }

}

private struct NativeBrowseVideoSurface: NSViewRepresentable {
    let playback: BrowseVideoPlayback

    func makeNSView(context: Context) -> BrowseVideoLayerView {
        let view = BrowseVideoLayerView()
        view.configure(playback: playback)
        return view
    }

    func updateNSView(_ view: BrowseVideoLayerView, context: Context) {
        view.configure(playback: playback)
    }

    static func dismantleNSView(_ view: BrowseVideoLayerView, coordinator: ()) {
        view.tearDown()
    }
}

@MainActor final class BrowseVideoLayerView: NSView {
    private let surfaceID = UUID()
    private weak var playback: BrowseVideoPlayback?
    private var readinessObservation: NSKeyValueObservation?
    private var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        videoLayer.videoGravity = .resizeAspect
        videoLayer.backgroundColor = NSColor.black.cgColor
        videoLayer.opacity = 0
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(playback: BrowseVideoPlayback) {
        let nextPlayer = playback.failed ? nil : playback.player
        guard self.playback !== playback || videoLayer.player !== nextPlayer else { return }
        tearDown()
        self.playback = playback
        guard let nextPlayer else { return }
        videoLayer.player = nextPlayer
        readinessObservation = videoLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshReadiness() }
        }
    }

    func tearDown() {
        readinessObservation?.invalidate()
        readinessObservation = nil
        if let player = videoLayer.player {
            playback?.reportDisplayReadiness(false, player: player, surface: surfaceID)
        }
        videoLayer.player = nil
        videoLayer.opacity = 0
        playback = nil
    }

    private func refreshReadiness() {
        guard let player = videoLayer.player, let playback else { return }
        let ready = videoLayer.isReadyForDisplay && !playback.failed && playback.player === player
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.opacity = ready ? 1 : 0
        CATransaction.commit()
        playback.reportDisplayReadiness(ready, player: player, surface: surfaceID)
    }

    isolated deinit { readinessObservation?.invalidate() }
}

/// Window visibility is separate from application activation: a settings window
/// can keep the app active after the roll's window has been minimized.
struct BrowsePlaybackWindowObserver: NSViewRepresentable {
    let onVisibilityChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> BrowsePlaybackVisibilityView {
        let view = BrowsePlaybackVisibilityView()
        view.configure(onVisibilityChange: onVisibilityChange)
        return view
    }

    func updateNSView(_ view: BrowsePlaybackVisibilityView, context: Context) {
        view.configure(onVisibilityChange: onVisibilityChange)
    }

    static func dismantleNSView(_ view: BrowsePlaybackVisibilityView, coordinator: ()) {
        view.tearDown()
    }
}

@MainActor final class BrowsePlaybackVisibilityView: NSView {
    private weak var observedWindow: NSWindow?
    private var onVisibilityChange: (@MainActor (Bool) -> Void)?
    private var lastVisibility: Bool?
    private var isClosing = false
    private var isMinimizing = false
    private var isStopped = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(onVisibilityChange: @escaping @MainActor (Bool) -> Void) {
        self.onVisibilityChange = onVisibilityChange
        guard !isStopped else { return }
        observe(window)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !isStopped else { return }
        observe(window)
    }

    private func observe(_ window: NSWindow?) {
        guard observedWindow !== window else { publishCurrentVisibility(); return }
        // Migration first withdraws the old window's permission, even if the
        // destination is also visible. Callbacks retain their enqueue order.
        NotificationCenter.default.removeObserver(self)
        publish(false)
        observedWindow = window
        isClosing = false
        isMinimizing = false
        guard let window else { return }
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.willMiniaturizeNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification,
                     NSWindow.didExposeNotification,
                     NSWindow.didUpdateNotification,
                     NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: window)
        }
        publishCurrentVisibility()
    }

    @objc private func windowChanged(_ notification: Notification) {
        guard !isStopped, let window = notification.object as? NSWindow,
              observedWindow === window else { return }
        switch notification.name {
        case NSWindow.willCloseNotification:
            isClosing = true
        case NSWindow.willMiniaturizeNotification, NSWindow.didMiniaturizeNotification:
            isMinimizing = true
        case NSWindow.didDeminiaturizeNotification:
            isMinimizing = false
        case NSWindow.didChangeOcclusionStateNotification:
            // SwiftUI may reuse the same NSWindow when the user reopens it.
            if window.isVisible && window.occlusionState.contains(.visible) { isClosing = false }
        default:
            break
        }
        publishCurrentVisibility()
    }

    private func publishCurrentVisibility() {
        guard !isStopped, let window = observedWindow else { publish(false); return }
        publish(!isClosing && !isMinimizing && window.isVisible && !window.isMiniaturized
                && window.occlusionState.contains(.visible))
    }

    private func publish(_ visible: Bool) {
        guard lastVisibility != visible else { return }
        lastVisibility = visible
        guard let callback = onVisibilityChange else { return }
        // AppKit can attach/detach this view inside a SwiftUI update. Deliver on
        // the next main turn so the callback may safely update SwiftUI state.
        DispatchQueue.main.async { callback(visible) }
    }

    func tearDown() {
        guard !isStopped else { return }
        isStopped = true
        NotificationCenter.default.removeObserver(self)
        observedWindow = nil
        publish(false)
        onVisibilityChange = nil
    }

    isolated deinit { tearDown() }
}
