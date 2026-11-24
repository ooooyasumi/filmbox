import SwiftUI
import AVKit
import FilmboxCore

struct ViewerView: View {
    @Bindable var store: AppStore
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("slideshowInterval") private var slideshowInterval = 4.0
    @State private var photoZoom = PhotoZoomState()
    @State private var showFilmstrip = true
    @State private var isSlideshow = false
    @State private var isFullScreen = false
    @State private var slideshowTask: Task<Void, Never>?
    @State private var playbackCommand = 0
    @FocusState private var focused: Bool
    @FocusState private var zoomSliderFocused: Bool
    private var current: MediaItem? { store.previewID.flatMap { store.visibleMediaItem(id: $0) } }
    private var currentIndex: Int { store.previewID.flatMap { store.visibleMediaIndex(id: $0) } ?? 0 }
    private var viewerWindow: NSWindow? {
        if let key = NSApp.keyWindow, key.identifier?.rawValue == "viewer" { return key }
        return NSApp.windows.first { $0.identifier?.rawValue == "viewer" && $0.isVisible }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            HStack(spacing: 0) {
                ZStack {
                    Color.black.opacity(0.7)
                    if let item = current {
                        if item.isLocal && store.isOffline(item) && item.kind == .video {
                            VStack(spacing: 12) {
                                AsyncThumbnail(item: item, pixelSize: 1600, contentMode: .fit)
                                Label(item.isLocal ? "连接磁盘后可播放" : "连接云盘后可播放", systemImage: item.isLocal ? "externaldrive.badge.exclamationmark" : "icloud.slash")
                                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 16)
                            }
                        } else if item.kind == .video {
                            if WebVideoPlayback.supports(item.url) {
                                CompatibleWebVideo(item: item, playOnOpen: true, playbackCommand: playbackCommand, onEscape: handleEscape).id(item.id)
                            } else {
                                VideoCanvas(item: item, playOnOpen: true, playbackCommand: playbackCommand).id(item.id)
                            }
                        } else {
                            ZoomablePhoto(item: item, zoomState: photoZoom, isOffline: store.isOffline(item), onKeyAction: handleCanvasKey, onReconnect: {
                                if let account = store.cloudAccounts.first(where: { $0.id == item.cloud?.accountID }) {
                                    store.reconnectAccount(account)
                                    if let mainWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                                        mainWindow.deminiaturize(nil)
                                        mainWindow.makeKeyAndOrderFront(nil)
                                    }
                                    NSApp.activate()
                                }
                            }, onContextMenu: { MediaMenus.make(store: store, items: [store.visibleMediaItem(id: item.id) ?? item], includeOpen: false) }).id(item.id)
                        }
                    }
                    HStack {
                        navButton("chevron.left", label: "上一项", disabled: currentIndex == 0) { step(-1) }
                        Spacer()
                        navButton("chevron.right", label: "下一项", disabled: currentIndex >= store.visibleItems.count - 1) { step(1) }
                    }.padding(.horizontal, 16)
                }
                .background(ViewerWheelNavigation(onStep: step).accessibilityHidden(true))
                if store.showViewerInspector { InspectorView(store: store, isViewer: true, onClose: { store.showViewerInspector = false }).frame(width: 280).background(.background) }
            }
            if let item = current, showFilmstrip {
                Filmstrip(store: store, activeID: item.id) { item in isSlideshow = false; store.previewID = item.id; store.focus(item) }
                    .frame(height: 82).background(.black.opacity(0.45))
            }
            if current?.kind == .image { zoomBar }
        }
        .background(Color(white: 0.075))
        .background(NativeWindowIdentity(identifier: "viewer").frame(width: 0, height: 0).accessibilityHidden(true))
        .onCopyCommand {
            guard let current else { return [] }
            if current.isLocal { return [NSItemProvider(object: current.url as NSURL)] }
            store.copyFiles([current])
            return []
        }
        .preferredColorScheme(.dark)
        .focusable().focusEffectDisabled().focused($focused)
        .onKeyPress(.escape) { handleEscape(); return .handled }
        .onKeyPress(.leftArrow) { guard !zoomSliderFocused else { return .ignored }; step(-1); return .handled }
        .onKeyPress(.rightArrow) { guard !zoomSliderFocused else { return .ignored }; step(1); return .handled }
        .onKeyPress(.space) {
            guard !zoomSliderFocused else { return .ignored }
            if current?.kind == .video { playbackCommand += 1; return .handled }
            isSlideshow.toggle(); return .handled
        }
        .onAppear { focused = true; isFullScreen = viewerWindow?.styleMask.contains(.fullScreen) == true }
        .onDisappear { slideshowTask?.cancel(); isSlideshow = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
            if (notification.object as? NSWindow)?.identifier?.rawValue == "viewer" { isFullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            if (notification.object as? NSWindow)?.identifier?.rawValue == "viewer" { isFullScreen = false }
        }
        .onChange(of: store.previewID) { _, _ in focused = true; if current == nil { dismissWindow(id: "viewer") } }
        .onReceive(NotificationCenter.default.publisher(for: .filmboxViewerZoom)) { notification in
            guard NSApp.keyWindow?.identifier?.rawValue == "viewer", current?.kind == .image,
                  let value = notification.object as? String, let command = ViewerZoomCommand(rawValue: value) else { return }
            photoZoom.perform(command)
        }
        .onChange(of: isSlideshow) { _, enabled in
            slideshowTask?.cancel()
            guard enabled else { return }
            slideshowTask = Task { @MainActor in
                while !Task.isCancelled && isSlideshow {
                    let interval = current?.kind == .video ? max(slideshowInterval, current?.duration ?? 0) : slideshowInterval
                    try? await Task.sleep(for: .seconds(max(2, interval)))
                    guard !Task.isCancelled && isSlideshow else { return }
                    if currentIndex >= store.visibleItems.count - 1 { isSlideshow = false; return }
                    store.stepPreview(1)
                }
            }
        }
    }
    private var header: some View {
        HStack(spacing: 14) {
            Button("返回图库", systemImage: "chevron.left") { close() }.labelStyle(.iconOnly).help(isFullScreen ? "返回图库" : "返回图库 (Esc)")
            VStack(alignment: .leading, spacing: 3) {
                Text(current?.name ?? "查看器").font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text("\(currentIndex + 1) / \(store.visibleItems.count)").font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }.frame(maxWidth: 300, alignment: .leading)
            Spacer()
            Button(isSlideshow ? "暂停幻灯片" : "播放幻灯片", systemImage: isSlideshow ? "pause.fill" : "play.fill") { isSlideshow.toggle() }.labelStyle(.iconOnly).help("幻灯片")
            if let item = current {
                if item.kind == .image {
                    Button("向左旋转", systemImage: "rotate.left") { Task { await store.rotatePhoto(item, direction: .left) } }
                        .labelStyle(.iconOnly).disabled(!LocalPhotoRotation.supports(item) || store.isPerformingFileOperation || store.isOffline(item))
                        .help(!item.isLocal ? "云端原件暂不支持改写" : LocalPhotoRotation.supports(item) ? "向左旋转并保存原文件" : "此格式暂不支持保存旋转")
                    Button("向右旋转", systemImage: "rotate.right") { Task { await store.rotatePhoto(item, direction: .right) } }
                        .labelStyle(.iconOnly).disabled(!LocalPhotoRotation.supports(item) || store.isPerformingFileOperation || store.isOffline(item))
                        .help(!item.isLocal ? "云端原件暂不支持改写" : LocalPhotoRotation.supports(item) ? "向右旋转并保存原文件" : "此格式暂不支持保存旋转")
                }
                Button(store.favorites.contains(item.id) ? "取消收藏" : "收藏", systemImage: store.favorites.contains(item.id) ? "heart.fill" : "heart") { store.toggleFavorite(item) }.labelStyle(.iconOnly).help("收藏 (⌘L)")
                Menu {
                    MediaContextMenu(store: store, item: item, includeOpen: false)
                    if item.isLocal {
                        ShareLink(item: item.url) { Label("共享…", systemImage: "square.and.arrow.up") }
                    }
                } label: { Image(systemName: "ellipsis") }.help("更多")
            }
            Divider().frame(height: 16)
            Button("胶片导航", systemImage: "rectangle.bottomthird.inset.filled") { showFilmstrip.toggle() }.labelStyle(.iconOnly).help("显示胶片导航")
            Button(isFullScreen ? "退出全屏" : "全屏", systemImage: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                viewerWindow?.toggleFullScreen(nil)
            }.labelStyle(.iconOnly).help(isFullScreen ? "退出全屏" : "全屏")
            Button("信息", systemImage: "info.circle") { store.showViewerInspector.toggle() }.labelStyle(.iconOnly).help("显示元数据 (⌘I)")
        }
        .buttonStyle(.borderless).controlSize(.regular).padding(.horizontal, 20).frame(height: 62)
    }
    private var zoomBar: some View {
        HStack(spacing: 9) {
            Spacer(minLength: 0)
            Button("缩小", systemImage: "minus") { photoZoom.perform(.zoomOut) }
                .labelStyle(.iconOnly).disabled(!photoZoom.canZoomOut).help("缩小 (⌘−)")
            Slider(value: Binding(get: { photoZoom.sliderValue }, set: { photoZoom.sliderValue = $0 }), in: 0...1)
                .frame(width: 136).controlSize(.small).tint(LightTablePalette.blue)
                .disabled(!photoZoom.hasImage)
                .focused($zoomSliderFocused).focusEffectDisabled()
                .accessibilityLabel("照片缩放")
                .accessibilityValue(photoZoom.percentage)
            Button("放大", systemImage: "plus") { photoZoom.perform(.zoomIn) }
                .labelStyle(.iconOnly).disabled(!photoZoom.canZoomIn).help("放大 (⌘+)")
            Menu {
                Button("适应窗口") { photoZoom.perform(.fit) }
                Button("实际大小（100%）") { photoZoom.perform(.actualSize) }
                Divider()
                ForEach([0.25, 0.5, 1.0, 2.0, 4.0], id: \.self) { value in
                    Button("\(Int(value * 100))%") { photoZoom.setScale(value) }
                }
            } label: {
                Text(photoZoom.percentage).font(.system(size: 11, design: .monospaced)).frame(minWidth: 44)
            }.disabled(!photoZoom.hasImage)
                .help("100%：1 原图像素对应 1 屏幕像素；当前预览最长边为 4096 像素")
            Button("适应窗口", systemImage: "arrow.down.right.and.arrow.up.left") { photoZoom.perform(.fit) }
                .labelStyle(.iconOnly).disabled(!photoZoom.hasImage).help("适应窗口 (⌘0)")
        }
        .buttonStyle(.borderless).controlSize(.small)
        .padding(.horizontal, 20).frame(height: 36)
        .background(.white.opacity(0.025))
    }
    private func handleCanvasKey(_ action: PhotoCanvasKeyAction) {
        switch action {
        case .previous: step(-1)
        case .next: step(1)
        case .close: handleEscape()
        case .toggleSlideshow: isSlideshow.toggle()
        }
    }
    private func step(_ delta: Int) { isSlideshow = false; store.stepPreview(delta) }
    private func handleEscape() {
        if let window = viewerWindow, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        else { close() }
    }
    private func close() { isSlideshow = false; store.closePreview(); dismissWindow(id: "viewer") }
    private func navButton(_ symbol: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 18, weight: .medium)).frame(width: 38, height: 44) }
            .buttonStyle(.plain).modifier(ViewerNavigationMaterial()).opacity(disabled ? 0 : 0.85).disabled(disabled).accessibilityLabel(label)
    }
}

private struct ViewerNavigationMaterial: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

struct ZoomablePhoto: View {
    let item: MediaItem
    let zoomState: PhotoZoomState
    var isOffline = false
    var onKeyAction: (PhotoCanvasKeyAction) -> Void
    var onReconnect: () -> Void = {}
    var onContextMenu: (() -> NSMenu)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var preview = PhotoPreviewSession()
    @State private var retryGeneration = 0
    @State private var viewingLease: UUID?
    @State private var leaseGeneration = 0

    private var connectionIssue: CloudAccountIssue? {
        item.cloud.flatMap { CloudTransferCenter.shared.issue(for: $0.accountID) }
    }
    private var original: CloudTransferSnapshot? {
        item.isLocal ? nil : CloudTransferCenter.shared.snapshot(for: item.id, purpose: .original)
    }
    private var feedback: PhotoPreviewFeedback? {
        PhotoPreviewFeedback.presentation(state: preview.state, item: item, isOffline: isOffline,
                                     original: original, needsLogin: connectionIssue != nil)
    }
    private struct Request: Hashable {
        let id: String
        let modifiedDate: Date
        let fileSize: Int64
        let revision: String?
        let offline: Bool
        let requiresLogin: Bool
        let retry: Int
    }
    private var request: Request { Request(id: item.id, modifiedDate: item.modifiedDate, fileSize: item.fileSize, revision: item.contentRevision, offline: isOffline, requiresLogin: connectionIssue != nil, retry: retryGeneration) }

    var body: some View {
        ZStack {
            NativePhotoCanvas(item: item, image: preview.thumbnail?.image, zoomState: zoomState,
                              isProvisional: preview.state != .ready, onKeyAction: onKeyAction,
                              onContextMenu: onContextMenu)
            if let feedback {
                PhotoPreviewProgress(feedback: feedback, item: item, onRetry: { retryGeneration += 1 }, onReconnect: onReconnect)
                    .transition(.opacity)
                    .allowsHitTesting(feedback.kind != .loading)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: feedback?.kind)
        .task(id: request) {
            leaseGeneration &+= 1
            let token = leaseGeneration
            if let previous = viewingLease {
                viewingLease = nil
                await MediaAssetResolver.shared.releaseViewingLease(previous)
            }
            let lease = await MediaAssetResolver.shared.acquireViewingLease(for: item)
            guard !Task.isCancelled, token == leaseGeneration else {
                await MediaAssetResolver.shared.releaseViewingLease(lease)
                return
            }
            viewingLease = lease
            await preview.load(item: item)
        }
        .onDisappear {
            leaseGeneration &+= 1
            preview.cancel()
            if let viewingLease { Task { await MediaAssetResolver.shared.releaseViewingLease(viewingLease) } }
            viewingLease = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if connectionIssue == nil && preview.state != .ready { retryGeneration += 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FilmboxPreviewRetry"))) { _ in
            if connectionIssue == nil && preview.state != .ready { retryGeneration += 1 }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            retryGeneration += 1
        }
    }
}

struct PhotoPreviewProgress: View {
    let feedback: PhotoPreviewFeedback
    var item: MediaItem? = nil
    let onRetry: () -> Void
    let onReconnect: () -> Void
    @State private var presented = false

    var body: some View {
        if let problem = feedback.problem { ResourceRecoveryView(problem: problem, item: item) } else { legacyBody }
    }
    private var legacyBody: some View {
        HStack(spacing: 11) {
            if feedback.kind == .loading && feedback.title != MediaLoadingText.paused {
                Group {
                    if let progress = feedback.progress {
                        ProgressView(value: progress).progressViewStyle(.circular)
                    } else { ProgressView().progressViewStyle(.circular) }
                }.controlSize(.small).frame(width: 23, height: 23)
            } else {
                Image(systemName: feedback.title == MediaLoadingText.paused ? "pause.circle" : feedback.kind == .login ? "exclamationmark.icloud" : "exclamationmark.circle")
                    .font(.system(size: 19)).foregroundStyle(.secondary)
            }
            Text(feedback.title).font(.system(size: 12, weight: .medium))
            if let progress = feedback.progress, feedback.kind == .loading {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            if feedback.kind == .failed {
                Button("重试", action: onRetry).buttonStyle(.borderless)
            } else if feedback.kind == .login {
                Button("重新登录", action: onReconnect).buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(.regularMaterial, in: .rect(cornerRadius: 13))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(feedback.title)
        .opacity(presented ? 1 : 0)
        .accessibilityHidden(!presented)
        .task(id: feedback.kind) {
            presented = false
            if feedback.kind == .loading {
                do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            presented = true
        }
    }
}

struct CompatibleWebVideo: View {
    let item: MediaItem
    let playOnOpen: Bool
    let playbackCommand: Int
    var onEscape: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var playback = WebVideoPlayback()
    @State private var appActive = false
    @State private var windowVisible = false
    private var mediaIdentity: String { "\(item.id)|\(item.url)|\(item.fileSize)|\(item.modifiedDate)|\(item.contentRevision ?? "")" }

    var body: some View {
        ZStack {
            AsyncThumbnail(item: item, pixelSize: 1600, contentMode: .fit)
            WebVideoSurface(webView: playback.webView)
            if playback.isLoading {
                VideoLoadingIndicator(title: playback.isDownloadingOriginal ? MediaLoadingText.downloading : MediaLoadingText.loading)
            }
            if playback.isDownloadingOriginal {
                VStack { HStack { Spacer(); CloudAssetBadge(item: item, loading: true).padding(18) }; Spacer() }
            }
            if playback.needsOriginalDownload && !playback.isDownloadingOriginal {
                VStack(spacing: 8) {
                    Button("下载后播放", systemImage: "arrow.down.circle", action: playback.downloadOriginalAndPlay)
                        .buttonStyle(.borderedProminent)
                    if let error = playback.originalDownloadError { Text(error).font(.caption).foregroundStyle(.secondary) }
                }.padding(18).background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
            if playback.failed {
                ResourceRecoveryView(problem: item.isLocal ? .unsupported : item.cloud.flatMap { ref in
                    CloudTransferCenter.shared.issue(for: ref.accountID) != nil ? .login : CloudTransferCenter.shared.connectionProblems[ref.accountID]
                } ?? .unknown, item: item)
            }
        }
        .background {
            BrowsePlaybackWindowObserver { visible in windowVisible = visible; updateSuspension() }
                .frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .onAppear {
            appActive = NSApp.isActive
            playback.onEscape = onEscape
            updateSuspension()
            playback.update(item: item, muted: false, enabled: true, controls: true, loop: false, playOnOpen: playOnOpen)
        }
        .onChange(of: mediaIdentity) { _, _ in
            playback.update(item: item, muted: false, enabled: true, controls: true, loop: false, playOnOpen: playOnOpen)
        }
        .onChange(of: playbackCommand) { _, _ in playback.togglePlayback() }
        .onChange(of: playback.needsOriginalDownload) { _, needed in
            // Opening the independent viewer is an explicit original-file action.
            if needed, playback.originalDownloadError == nil { playback.downloadOriginalAndPlay() }
        }
        .onChange(of: scenePhase) { _, _ in updateSuspension() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true; updateSuspension() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appActive = false; updateSuspension() }
        .onDisappear { playback.onEscape = nil; playback.stop() }
    }
    private func updateSuspension() { playback.setSuspended(!appActive || !windowVisible || scenePhase != .active) }
}


/// Keep feedback outside AVKit. Hiding only the failed player's controls can
/// leave its floating material visible, even after the player is detached.
final class VideoCanvasContainer: NSView {
    let playerView = AVPlayerView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(playerView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); playerView.frame = bounds }
}

struct VideoCanvas: NSViewRepresentable {
    let item: MediaItem
    let playOnOpen: Bool
    let playbackCommand: Int

    func makeNSView(context: Context) -> VideoCanvasContainer {
        let container = VideoCanvasContainer()
        let view = container.playerView
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.showsSharingServiceButton = false
        context.coordinator.configure(view: view, item: item, playOnOpen: playOnOpen, command: playbackCommand)
        return container
    }

    func updateNSView(_ view: VideoCanvasContainer, context: Context) {
        context.coordinator.configure(view: view.playerView, item: item, playOnOpen: playOnOpen, command: playbackCommand)
    }

    static func dismantleNSView(_ view: VideoCanvasContainer, coordinator: Coordinator) {
        coordinator.stop()
        view.playerView.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject {
        private var player: AVPlayer?
        private var identity: String?
        private var observation: NSKeyValueObservation?
        private var timeObservation: NSKeyValueObservation?
        private var sawPlaybackActivity = false
        private(set) var isLoading = false
        var loadingTitle: String { usesRemoteStream ? MediaLoadingText.downloading : MediaLoadingText.loading }
        private let resolveAsset: @Sendable (MediaItem) async throws -> CloudResolvedAsset
        private var preparation: Task<Void, Never>?
        private var generation = 0
        private var playbackCommand = 0
        private var wantsPlayback = false
        private var media: MediaItem?
        private weak var view: AVPlayerView?
        private var errorStack: NSStackView?
        private(set) var failureTitle: String?
        private var recoveryProblem: ResourceProblem?
        private var progress: NSHostingView<VideoLoadingIndicator>?
        private var progressTitle: String?
        private var cacheLease: UUID?
        private var usesRemoteStream = false

        init(resolveAsset: @escaping @Sendable (MediaItem) async throws -> CloudResolvedAsset = {
            try await MediaAssetResolver.shared.playbackAsset(for: $0)
        }) { self.resolveAsset = resolveAsset; super.init() }

        func configure(view: AVPlayerView, item: MediaItem, playOnOpen: Bool, command: Int) {
            self.view = view
            let nextIdentity = "\(item.id)|\(item.url.absoluteString)|\(item.fileSize)|\(item.modifiedDate.timeIntervalSinceReferenceDate)|\(item.contentRevision ?? "")"
            guard identity == nextIdentity else {
                stop()
                self.view = view
                media = item
                identity = nextIdentity
                playbackCommand = command
                wantsPlayback = playOnOpen
                let token = generation
                showProgress()
                if item.isLocal {
                    install(asset: AVURLAsset(url: item.url), token: token)
                } else {
                    preparation = Task { @MainActor [weak self] in
                        do {
                            let lease = await MediaAssetResolver.shared.acquireViewingLease(for: item)
                            guard let self, self.generation == token, !Task.isCancelled else {
                                await MediaAssetResolver.shared.releaseViewingLease(lease)
                                return
                            }
                            self.cacheLease = lease
                            let resolved = try await self.resolveAsset(item)
                            guard self.generation == token, !Task.isCancelled else { return }
                            self.preparation = nil
                            self.usesRemoteStream = !resolved.url.isFileURL
                            let options: [String: Any] = resolved.headers.isEmpty ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": resolved.headers]
                            self.install(asset: AVURLAsset(url: resolved.url, options: options), token: token)
                        } catch {
                            guard let self, self.generation == token, !Task.isCancelled else { return }
                            self.preparation = nil
                            self.recoveryProblem = MediaFailureText.problem(error)
                            self.showError(reason: MediaFailureText.transferError(error))
                        }
                    }
                }
                return
            }
            guard playbackCommand != command else { return }
            playbackCommand = command
            if let player {
                wantsPlayback = player.timeControlStatus == .paused
                if wantsPlayback {
                    if let duration = player.currentItem?.duration.seconds, duration.isFinite,
                       player.currentTime().seconds >= duration - 0.05 { player.seek(to: .zero) }
                    player.play()
                } else { player.pause() }
            } else {
                wantsPlayback.toggle()
            }
        }

        func stop() {
            generation &+= 1
            if let cacheLease { Task { await MediaAssetResolver.shared.releaseViewingLease(cacheLease) } }
            cacheLease = nil
            preparation?.cancel(); preparation = nil
            observation?.invalidate(); observation = nil
            timeObservation?.invalidate(); timeObservation = nil
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
            view?.player = nil
            view?.isHidden = false
            identity = nil
            media = nil
            usesRemoteStream = false
            wantsPlayback = false
            errorStack?.removeFromSuperview(); errorStack = nil
            failureTitle = nil
            recoveryProblem = nil
            hideProgress()
            sawPlaybackActivity = false
        }

        private func install(asset: AVURLAsset, token: Int) {
            guard generation == token else { return }
            let playerItem = AVPlayerItem(asset: asset)
            if usesRemoteStream { playerItem.preferredForwardBufferDuration = 4 }
            let nextPlayer = AVPlayer(playerItem: playerItem)
            nextPlayer.automaticallyWaitsToMinimizeStalling = true
            player = nextPlayer
            view?.controlsStyle = .floating
            view?.isHidden = false
            view?.player = nextPlayer
            observation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self, weak playerItem] _, _ in
                Task { @MainActor [weak self, weak playerItem] in
                    guard let self, self.generation == token, let playerItem,
                          self.player?.currentItem === playerItem else { return }
                    if playerItem.status == .failed {
                        self.showError()
                        if self.usesRemoteStream, let accountID = self.media?.cloud?.accountID {
                            self.usesRemoteStream = false
                            Task { @MainActor [weak self] in
                                await CloudGateway.shared.checkAuthenticationAfterPlaybackFailure(accountID: accountID)
                                guard let self, self.generation == token else { return }
                                let center = CloudTransferCenter.shared
                                self.recoveryProblem = center.issue(for: accountID) != nil ? .login : center.connectionProblems[accountID] ?? .unknown
                                self.errorStack?.removeFromSuperview(); self.errorStack = nil
                                self.showError(reason: self.recoveryProblem?.title)
                            }
                        }
                    } else { self.refreshProgress() }
                }
            }
            timeObservation = nextPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self, weak nextPlayer] _, _ in
                Task { @MainActor [weak self, weak nextPlayer] in
                    guard let self, self.generation == token, let nextPlayer, self.player === nextPlayer else { return }
                    self.refreshProgress()
                }
            }
            if wantsPlayback { nextPlayer.play() }
            refreshProgress()
        }

        private func refreshProgress() {
            guard let player, errorStack == nil else { return }
            switch player.timeControlStatus {
            case .playing:
                sawPlaybackActivity = true
                hideProgress()
            case .waitingToPlayAtSpecifiedRate:
                sawPlaybackActivity = true
                showProgress()
            case .paused:
                if player.currentItem?.status != .readyToPlay || (wantsPlayback && !sawPlaybackActivity) { showProgress() }
                else { hideProgress() }
            @unknown default: break
            }
        }

        private func showProgress() {
            guard let view, errorStack == nil else { return }
            isLoading = true
            let title = loadingTitle
            if let progress {
                if progressTitle != title { progress.rootView = VideoLoadingIndicator(title: title) }
            } else {
                let host = NSHostingView(rootView: VideoLoadingIndicator(title: title))
                host.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(host)
                NSLayoutConstraint.activate([host.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                             host.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
                progress = host
            }
            progressTitle = title
        }

        private func hideProgress() {
            isLoading = false
            progress?.removeFromSuperview(); progress = nil; progressTitle = nil
        }

        private func showError(reason: String? = nil) {
            player?.pause()
            hideProgress()
            // Detach the failed player so AVKit cannot overlay its own generic
            // network diagnosis on a corrupt or unsupported local video.
            view?.player = nil
            view?.controlsStyle = .none
            let needsLogin = media?.cloud.flatMap { CloudTransferCenter.shared.issue(for: $0.accountID) } != nil
            let message = media.map { item in
                if !item.isLocal, !needsLogin, let reason { return reason }
                return MediaFailureText.title(for: item, needsLogin: needsLogin)
            } ?? MediaFailureText.failed
            failureTitle = message
            if let label = errorStack?.views.first as? NSTextField { label.stringValue = message; return }
            guard let view else { return }
            let host = (view.superview as? VideoCanvasContainer).map { $0 as NSView } ?? view
            if host !== view { view.isHidden = true }
            let label = NSTextField(wrappingLabelWithString: message)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            let problem = recoveryProblem ?? media.flatMap { item in
                if item.isLocal { return ResourceProblem.unsupported }
                if let account = item.cloud?.accountID {
                    if CloudTransferCenter.shared.issue(for: account) != nil { return .login }
                    return CloudTransferCenter.shared.connectionProblems[account]
                }
                return nil
            } ?? .unknown
            recoveryProblem = problem
            let recovery = NSButton(title: problem.action, target: self, action: #selector(recoverPlayback))
            recovery.bezelStyle = .rounded
            let detail = NSTextField(wrappingLabelWithString: problem.detail)
            detail.textColor = .secondaryLabelColor; detail.font = .systemFont(ofSize: 11); detail.alignment = .center
            let stack = NSStackView(views: [label, detail, recovery])
            stack.orientation = .vertical
            stack.spacing = 12
            stack.alignment = .centerX
            stack.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(stack)
            NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: host.centerXAnchor),
                                         stack.centerYAnchor.constraint(equalTo: host.centerYAnchor),
                                         stack.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, multiplier: 0.8)])
            errorStack = stack
        }

        @objc private func recoverPlayback() {
            guard let media else { return }
            NotificationCenter.default.post(name: .filmboxRecoveryRequested, object: ResourceRecoveryRequest(problem: recoveryProblem ?? .unknown, itemID: media.id))
        }
        @objc private func retryPlayback() {
            guard let media, let view else { return }
            let command = playbackCommand
            identity = nil
            configure(view: view, item: media, playOnOpen: true, command: command)
        }

        isolated deinit { stop() }
    }
}
