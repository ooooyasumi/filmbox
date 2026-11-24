import AppKit
import QuartzCore
import SwiftUI
import FilmboxCore

struct BrowseView: View {
    @Bindable var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var playback = BrowseVideoPlayback()
    @State private var photoPreview = BrowsePhotoPreview()
    @State private var appActive = false
    @State private var windowVisible = false
    @AppStorage("physicalEffects") private var physicalEffects = true
    @AppStorage("showFileNames") private var showNames = false
    private var index: Int { min(max(0, store.browseIndex), max(0, store.visibleItems.count - 1)) }
    private var palette: LightTablePalette { LightTablePalette(dark: scheme == .dark) }
    private var mediaEnabled: Bool {
        appActive && windowVisible && scenePhase == .active && store.layout == .browse && store.previewID == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ContinuousPhotoAlbum(store: store, showNames: showNames,
                                 effects: physicalEffects && !reduceMotion, reduceMotion: reduceMotion,
                                 selectionMode: store.isSelectionMode, playback: playback,
                                 photoPreview: photoPreview, photoEnabled: mediaEnabled && !store.isSelectionMode)
            if store.visibleItems.indices.contains(index) {
                let item = store.visibleItems[index]
                HStack(spacing: 14) {
                    ChromeIconButton(title: "上一项", symbol: "chevron.left") { move(-1) }.disabled(index == 0)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            .truncationMode(.middle).foregroundStyle(palette.text)
                        HStack(spacing: 10) {
                            Text(item.displayDate.formatted(date: .abbreviated, time: .omitted)).lineLimit(1)
                            Spacer(minLength: 0)
                            Text("\((index + 1).formatted()) / \(store.visibleItems.count.formatted())")
                                .monospacedDigit().fixedSize().accessibilityLabel("第\(index + 1)项，共\(store.visibleItems.count)项")
                        }.font(.system(size: 10)).foregroundStyle(palette.secondary)
                    }.frame(maxWidth: .infinity)
                    if item.kind == .video {
                        if playback.failed {
                            let problem: ResourceProblem = item.isLocal ? .unsupported : item.cloud.flatMap { ref in CloudTransferCenter.shared.issue(for: ref.accountID) != nil ? .login : CloudTransferCenter.shared.connectionProblems[ref.accountID] } ?? .unknown
                            Button(problem.action) { store.recover(.init(problem: problem, itemID: item.id)) }.buttonStyle(.plain).font(.caption).help(problem.detail)
                        } else if playback.isLoading {
                            ProgressView().controlSize(.mini).frame(width: 16).allowsHitTesting(false)
                        }
                        ChromeIconButton(title: playback.playbackRequested ? "暂停视频" : "播放视频", symbol: playback.playbackRequested ? "pause.fill" : "play.fill") {
                            playback.togglePlayback()
                        }.disabled(!playback.canTogglePlayback)
                        ChromeIconButton(title: store.browseVideoMuted ? "打开声音" : "静音", symbol: store.browseVideoMuted ? "speaker.slash" : "speaker.wave.2",
                                         accessibilityState: store.browseVideoMuted ? "已静音" : "声音已打开") {
                            store.browseVideoMuted.toggle()
                            updatePlayback()
                        }
                    }
                    ChromeIconButton(title: "下一项", symbol: "chevron.right") { move(1) }
                        .disabled(index == store.visibleItems.count - 1)
                }.padding(.horizontal, 20).frame(height: 44)
                BrowseTimeRuler(store: store, reduceMotion: reduceMotion)
                    .frame(height: 52)
            }
        }
        .background(palette.canvas)
        .background {
            BrowsePlaybackWindowObserver { visible in
                windowVisible = visible
                updatePlayback()
            }.frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .onAppear {
            appActive = NSApp.isActive
            updatePlayback()
        }
        .onChange(of: store.browseIndex) { _, _ in updatePlayback() }
        .onChange(of: store.visibleRevision) { _, _ in updatePlayback() }
        .onChange(of: store.mediaMetadataRevision) { _, _ in updatePlayback() }
        .onChange(of: store.browseVideoMuted) { _, _ in updatePlayback() }
        .onChange(of: store.previewID) { _, _ in updatePlayback() }
        .onChange(of: store.isSelectionMode) { _, _ in updatePlayback() }
        .onChange(of: scenePhase) { _, _ in updatePlayback() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appActive = true; updatePlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            appActive = false; playback.stop(); photoPreview.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FilmboxPreviewRetry"))) { _ in
            if mediaEnabled, photoPreview.preview?.state != .ready { photoPreview.retry() }
        }
        .onDisappear { playback.stop(); photoPreview.stop() }
    }
    private func updatePlayback() {
        let item = store.visibleItems.indices.contains(index) ? store.visibleItems[index] : nil
        playback.update(item: item, muted: store.browseVideoMuted, enabled: mediaEnabled)
        photoPreview.update(item: item, enabled: mediaEnabled && !store.isSelectionMode)
    }
    private func move(_ amount: Int) {
        guard !store.visibleItems.isEmpty else { return }
        let next = min(max(index + amount, 0), store.visibleItems.count - 1)
        store.focus(store.visibleItems[next])
    }
}

/// The entire album stores geometry only; AppKit realises image cells solely
/// for the visible horizontal range, including for libraries with 5,000+ items.
private struct ContinuousPhotoAlbum: NSViewRepresentable {
    let store: AppStore
    let showNames: Bool
    let effects: Bool
    let reduceMotion: Bool
    var selectionMode = false
    var playback: BrowseVideoPlayback? = nil
    var photoPreview: BrowsePhotoPreview? = nil
    var photoEnabled = false
    func makeCoordinator() -> Coordinator { Coordinator(store: store, playback: playback, photoPreview: photoPreview) }
    func makeNSView(context: Context) -> BrowseScrollView {
        let scroll = BrowseScrollView()
        scroll.focusRingType = .none
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.usesPredominantAxisScrolling = true
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.store = store
        let collection = BrowseCollectionView()
        collection.identifier = .init("filmbox.browse.collection")
        collection.focusRingType = .none
        collection.autoresizingMask = [.height]
        collection.backgroundColors = [.clear]
        collection.isSelectable = false
        collection.collectionViewLayout = BrowseAlbumLayout()
        collection.register(BrowseCollectionItem.self, forItemWithIdentifier: .init("album-photo"))
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.store = store
        collection.setAccessibilityLabel("连续照片相册")
        collection.onSelectionChange = { [weak coordinator = context.coordinator] in coordinator?.refreshVisibleCells() }
        scroll.onViewportChange = { [weak coordinator = context.coordinator] in coordinator?.viewportChanged() }
        scroll.onUserScroll = { [weak coordinator = context.coordinator] in coordinator?.beginUserScroll() }
        scroll.documentView = collection
        context.coordinator.collection = collection
        context.coordinator.scroll = scroll
        context.coordinator.observe(scroll.contentView)
        return scroll
    }
    func updateNSView(_ scroll: BrowseScrollView, context: Context) {
        (scroll.documentView as? BrowseCollectionView)?.validateSelectionStroke()
        context.coordinator.update(showNames: showNames, effects: effects, reduceMotion: reduceMotion,
                                   selectionMode: selectionMode, photoEnabled: photoEnabled)
    }
    static func dismantleNSView(_ scroll: BrowseScrollView, coordinator: Coordinator) {
        coordinator.stop()
        if let collection = scroll.documentView as? BrowseCollectionView {
            collection.cancelSelectionStroke()
            collection.dataSource = nil; collection.delegate = nil; collection.onSelectionChange = nil
            for case let cell as BrowseCollectionItem in collection.visibleItems() { cell.releaseImage() }
        }
        scroll.onViewportChange = nil; scroll.onUserScroll = nil
    }

    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let store: AppStore
        let playback: BrowseVideoPlayback?
        let photoPreview: BrowsePhotoPreview?
        weak var collection: BrowseCollectionView?
        weak var scroll: BrowseScrollView?
        private var items: [MediaItem] = []
        private var indexByID: [String: Int] = [:]
        private var revision = -1
        private var metadataRevision = -1
        private var activeID: String?
        private var effects = true
        private var reduceMotion = false
        private var showNames = false
        private var selectionMode = false
        private var photoEnabled = false
        private var centerRequest = 0
        private var isCentering = false
        private var pendingScrollUpdate = false
        private var scrollRequestID = -1
        private var prefetchTask: Task<Void, Never>?
        init(store: AppStore, playback: BrowseVideoPlayback? = nil, photoPreview: BrowsePhotoPreview? = nil) {
            self.store = store; self.playback = playback; self.photoPreview = photoPreview
        }
        func observe(_ clip: NSClipView) {
            NotificationCenter.default.addObserver(self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification, object: clip)
        }
        func stop() { NotificationCenter.default.removeObserver(self); centerRequest += 1; isCentering = false; playback?.stop(); photoPreview?.stop(); prefetchTask?.cancel() }
        func update(showNames: Bool, effects: Bool, reduceMotion: Bool, selectionMode: Bool, photoEnabled: Bool = false) {
            guard let collection, let layout = collection.collectionViewLayout as? BrowseAlbumLayout else { return }
            let dataChanged = revision != store.visibleRevision
            let metadataChanged = metadataRevision != store.mediaMetadataRevision
            let metadata = !dataChanged && metadataChanged ? store.mediaMetadataChanges(since: metadataRevision) : nil
            let replaceSnapshot = dataChanged || (metadataChanged && metadata == nil)
            let geometryIndexes = Set(metadata?.geometryChangedIDs.compactMap { indexByID[$0] } ?? [])
            let structureChanged = dataChanged && items.map(\.id) != store.visibleItems.map(\.id)
            let metricsChanged = self.showNames != showNames
            let loadingChanged = self.photoEnabled != photoEnabled
            if structureChanged || metricsChanged { collection.cancelSelectionStroke() }
            if structureChanged { MediaDoubleClickTracker.shared.cancel(store: store) }
            let reflowsGeometry = dataChanged || metadataChanged && (metadata == nil || !geometryIndexes.isEmpty)
            let nextID = store.visibleItems.indices.contains(store.browseIndex) ? store.visibleItems[store.browseIndex].id : nil
            let requested = scrollRequestID != store.browseScrollRequestID
            let activeChanged = activeID != nextID
            // A metadata update is not navigation. Anchor the actual visible
            // photograph in screen coordinates, not a fraction interpolated
            // between centres: that fraction changes when a neighbour resizes.
            let anchor: (index: Int, screenX: CGFloat)? = {
                guard reflowsGeometry, !structureChanged, !metricsChanged, !activeChanged, !requested,
                      !isCentering, let scroll,
                      let index = layout.nearestIndex(to: scroll.contentView.bounds.midX),
                      let frame = layout.frame(at: index) else { return nil }
                let visibleFrame = collection.item(at: IndexPath(item: index, section: 0)).map {
                    $0.view.convert($0.view.bounds, to: collection)
                } ?? frame
                return (index, visibleFrame.midX - scroll.contentView.bounds.minX)
            }()
            if anchor != nil { isCentering = true }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            self.showNames = showNames; self.effects = effects; self.reduceMotion = reduceMotion
            self.selectionMode = selectionMode
            self.photoEnabled = photoEnabled
            if replaceSnapshot {
                revision = store.visibleRevision; items = store.visibleItems
                indexByID = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
                collection.items = items
                collection.mediaRevision = revision
                layout.configure(items: items, revision: revision, showNames: showNames)
                if !dataChanged { layout.applyMetadata(items: items, geometryIndexes: nil) }
                if structureChanged { collection.reloadData() }
            } else {
                if metadataChanged {
                    items = store.visibleItems
                    collection.items = items
                    layout.applyMetadata(items: items, geometryIndexes: geometryIndexes)
                }
                layout.configure(items: items, revision: revision, showNames: showNames)
            }
            metadataRevision = store.mediaMetadataRevision
            scrollRequestID = store.browseScrollRequestID
            activeID = nextID
            updatePhotoFocus()
            layout.prepare()
            collection.layoutSubtreeIfNeeded()
            if let anchor, let scroll, let frame = layout.frame(at: anchor.index) {
                // Grow/shrink the document before constraining the clip origin;
                // otherwise AppKit can clamp it using the previous content size.
                collection.setFrameSize(layout.collectionViewContentSize)
                collection.layoutSubtreeIfNeeded()
                let maximum = max(0, layout.collectionViewContentSize.width - scroll.contentSize.width)
                let visibleFrame = collection.item(at: IndexPath(item: anchor.index, section: 0)).map {
                    $0.view.convert($0.view.bounds, to: collection)
                } ?? frame
                let point = CGPoint(x: min(maximum, max(0, visibleFrame.midX - anchor.screenX)), y: 0)
                scroll.contentView.scroll(to: point)
                scroll.reflectScrolledClipView(scroll.contentView)
                // The collection pixel-aligns realised cells again when the
                // clip moves. Correct that small rounding residual before the
                // transaction can paint, using the actual nested view frame.
                for _ in 0..<3 {
                    collection.layoutSubtreeIfNeeded()
                    guard let cell = collection.item(at: IndexPath(item: anchor.index, section: 0)) else { break }
                    let actual = cell.view.convert(cell.view.bounds, to: collection)
                    let correction = actual.midX - scroll.contentView.bounds.minX - anchor.screenX
                    guard abs(correction) > 0.001 else { break }
                    let x = min(maximum, max(0, scroll.contentView.bounds.minX + correction))
                    guard abs(x - scroll.contentView.bounds.minX) > 0.001 else { break }
                    scroll.contentView.scroll(to: CGPoint(x: x, y: 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                isCentering = false
                didScroll() // Rebase the date cursor to the new geometry next turn.
            } else if dataChanged || metricsChanged || activeChanged || requested || reflowsGeometry && isCentering {
                centerCurrent(animated: activeChanged && !dataChanged && !metricsChanged && !requested && !reduceMotion)
            }
            refreshVisibleCells()
            if structureChanged || activeChanged || loadingChanged { schedulePrefetch() }
        }
        func viewportChanged() {
            guard let collection else { return }
            collection.cancelSelectionStroke()
            collection.collectionViewLayout?.invalidateLayout(); collection.needsLayout = true
            centerCurrent(animated: false)
        }
        func beginUserScroll() {
            CloudMetadataUpdates.shared.noteInteraction()
            centerRequest += 1; isCentering = false
            scroll?.contentView.layer?.removeAllAnimations()
        }
        @objc private func didScroll() {
            guard !isCentering, !pendingScrollUpdate else { return }
            pendingScrollUpdate = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingScrollUpdate = false; self.publishVisibleFocus()
            }
        }
        private func publishVisibleFocus() {
            guard !isCentering, store.layout == .browse, let collection, let scroll,
                  let layout = collection.collectionViewLayout as? BrowseAlbumLayout,
                  let position = layout.position(at: scroll.contentView.bounds.midX),
                  items.indices.contains(Int(position.rounded())), store.visibleRevision == revision else { return }
            let item = items[Int(position.rounded())]
            // Publish every fraction, including movement within one day or one
            // photo. Record the scroll origin before SwiftUI updates, so the
            // ruler's response cannot snap the roll back to its nearest item.
            let changed = activeID != item.id
            activeID = item.id
            scrollRequestID = store.browseScrollRequestID
            store.recordBrowsePosition(position: position, item: item)
            // Leaving a newly downloaded item may settle the "未下载" filter.
            // Keep the new focus, but let the next render replace this snapshot.
            if store.visibleRevision != revision {
                photoPreview?.update(item: item, enabled: photoEnabled)
                return
            }
            if changed { updatePhotoFocus() }
            if changed { refreshVisibleCells() }
            if changed { schedulePrefetch() }
        }
        private func schedulePrefetch() {
            prefetchTask?.cancel()
            guard !items.isEmpty, photoEnabled else { return }
            let center = min(max(0, store.browseIndex), items.count - 1)
            let nearby = BrowseThumbnailNeighborhood.indexes(center: center, count: items.count).map { items[$0] }
            prefetchTask = Task(priority: .background) {
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                for item in nearby {
                    guard !Task.isCancelled else { return }
                    _ = await ThumbnailService.shared.thumbnail(for: item.url, kind: item.kind,
                        modifiedDate: item.modifiedDate, pixelSize: 768, priority: .background, localRevision: item.localRevision)
                }
            }
        }
        private func updatePhotoFocus() {
            let item = activeID.flatMap { indexByID[$0] }.map { items[$0] }
            photoPreview?.update(item: item, enabled: photoEnabled)
        }
        private func reconnect(_ item: MediaItem) {
            if let accountID = item.cloud?.accountID, let account = store.cloudAccounts.first(where: { $0.id == accountID }) {
                store.reconnectAccount(account)
            }
        }
        private func centerCurrent(animated: Bool) {
            guard let id = activeID else { return }
            if collection?.isSelectionGestureActive == true {
                beginUserScroll()
                return
            }
            centerRequest += 1
            let request = centerRequest
            isCentering = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.centerRequest == request, let scroll = self.scroll,
                      let collection = self.collection, let index = self.indexByID[id],
                      let layout = collection.collectionViewLayout as? BrowseAlbumLayout else { return }
                collection.layoutSubtreeIfNeeded(); layout.prepare()
                self.refreshVisibleCells()
                let requestedPosition = self.store.browsePosition
                let position = requestedPosition.isFinite && Int(requestedPosition.rounded()) == index ? requestedPosition : Double(index)
                guard let center = layout.center(at: position), scroll.contentSize.width > 1 else { self.isCentering = false; return }
                let maximum = max(0, layout.collectionViewContentSize.width - scroll.contentSize.width)
                let point = CGPoint(x: min(maximum, max(0, center - scroll.contentSize.width / 2)), y: 0)
                if animated && abs(scroll.contentView.bounds.minX - point.x) < scroll.contentSize.width * 2 {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.18
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        scroll.contentView.animator().setBoundsOrigin(point)
                    } completionHandler: { [weak self, weak scroll] in
                        MainActor.assumeIsolated {
                            guard let self, self.centerRequest == request else { return }
                            self.isCentering = false
                            if let scroll { scroll.reflectScrolledClipView(scroll.contentView) }
                        }
                    }
                } else {
                    scroll.contentView.scroll(to: point); scroll.reflectScrolledClipView(scroll.contentView)
                    self.isCentering = false
                }
            }
        }
        func refreshVisibleCells() {
            guard let collection else { return }
            if collection.isSelectionGestureActive {
                // Pointer selection owns the viewport. focus() also serves
                // explicit keyboard navigation, but a drag's focus request
                // must be consumed while the stroke is still alive so its
                // final mouse-up cannot trigger delayed automatic centering.
                scrollRequestID = store.browseScrollRequestID
                activeID = items.indices.contains(store.browseIndex) ? items[store.browseIndex].id : nil
            }
            for case let cell as BrowseCollectionItem in collection.visibleItems() {
                guard let id = cell.media?.id, let index = indexByID[id], items.indices.contains(index) else { continue }
                let item = items[index]
                cell.configure(item, active: item.id == activeID, selected: store.selectedIDs.contains(item.id),
                               effects: effects, showNames: showNames, pixelSize: pixelSize,
                               selectionMode: selectionMode, playback: playback, photoPreview: photoPreview,
                               onReconnect: { [weak self] in self?.reconnect(item) })
            }
        }
        private var pixelSize: Int {
            guard let collection, let layout = collection.collectionViewLayout as? BrowseAlbumLayout else { return 768 }
            return layout.photoHeight * (collection.window?.backingScaleFactor ?? 2) > 768 ? 1600 : 768
        }
        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = collectionView.makeItem(withIdentifier: .init("album-photo"), for: indexPath) as! BrowseCollectionItem
            guard items.indices.contains(indexPath.item) else { return cell }
            let item = items[indexPath.item]
            cell.configure(item, active: item.id == activeID, selected: store.selectedIDs.contains(item.id),
                           effects: effects, showNames: showNames, pixelSize: pixelSize,
                           selectionMode: selectionMode, playback: playback, photoPreview: photoPreview,
                           onReconnect: { [weak self] in self?.reconnect(item) })
            (cell.view as? BrowseAccessiblePhoto)?.onPress = { [weak self] in
                guard let self, let item = self.store.visibleItems.first(where: { $0.id == item.id }) else { return false }
                self.store.activate(item)
                self.refreshVisibleCells()
                return true
            }
            (cell.view as? BrowseAccessiblePhoto)?.onOpen = { [weak self] in
                guard let self, let item = self.store.visibleItems.first(where: { $0.id == item.id }) else { return false }
                self.store.open(item)
                self.refreshVisibleCells()
                return true
            }
            return cell
        }
        func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
            (item as? BrowseCollectionItem)?.releaseImage()
        }
        func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
            guard let cell = item as? BrowseCollectionItem, items.indices.contains(indexPath.item) else { return }
            let media = items[indexPath.item]
            cell.configure(media, active: media.id == activeID, selected: store.selectedIDs.contains(media.id),
                           effects: effects, showNames: showNames, pixelSize: pixelSize,
                           selectionMode: selectionMode, playback: playback, photoPreview: photoPreview,
                           onReconnect: { [weak self] in self?.reconnect(media) })
        }
    }
}

struct BrowseWheelProjection {
    enum Axis { case horizontal, vertical }
    private(set) var axis: Axis?
    private var lastTime: TimeInterval = -.infinity
    mutating func project(x: CGFloat, y: CGFloat, precise: Bool, phase: NSEvent.Phase,
                          momentum: NSEvent.Phase, time: TimeInterval) -> (Axis, CGFloat) {
        if !precise { return abs(x) >= abs(y) ? (.horizontal, x) : (.vertical, y) }
        if phase.contains(.began) || (phase.isEmpty && momentum.isEmpty && time - lastTime > 0.30) { axis = nil }
        lastTime = time
        if axis == nil, max(abs(x), abs(y)) > 0.01 { axis = abs(x) >= abs(y) ? .horizontal : .vertical }
        let chosen = axis ?? .horizontal
        return (chosen, chosen == .horizontal ? x : y)
    }
}

@MainActor private final class BrowseScrollView: NSScrollView {
    weak var store: AppStore?
    var onViewportChange: (() -> Void)?
    var onUserScroll: (() -> Void)?
    private var previousViewport = CGSize.zero
    private var wheelProjection = BrowseWheelProjection()
    override func layout() {
        super.layout()
        if contentSize != previousViewport { previousViewport = contentSize; onViewportChange?() }
    }
    override func scrollWheel(with event: NSEvent) {
        (documentView as? BrowseCollectionView)?.cancelPendingDoubleClick()
        if event.modifierFlags.contains(.command) { store?.zoomTimeline(with: event); return }
        onUserScroll?()
        let (axis, axisDelta) = wheelProjection.project(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas, phase: event.phase, momentum: event.momentumPhase, time: event.timestamp)
        if event.hasPreciseScrollingDeltas, axis == .horizontal, !event.phase.isEmpty || !event.momentumPhase.isEmpty {
            // Native fractional scrolling, elasticity and system inertia.
            super.scrollWheel(with: event)
            return
        }
        let delta = axisDelta * (event.hasPreciseScrollingDeltas ? 1 : 18)
        var point = contentView.bounds.origin
        point.x = min(max(0, (documentView?.bounds.width ?? 0) - contentSize.width), max(0, point.x - delta))
        point.y = 0
        contentView.scroll(to: point); reflectScrolledClipView(contentView)
    }
}

/// Internal so the common key monitor can identify this native responder and
/// pass its navigation events through exactly once.
@MainActor final class BrowseCollectionView: NSCollectionView {
    weak var store: AppStore?
    var items: [MediaItem] = []
    var mediaRevision = -1
    var onSelectionChange: (() -> Void)?
    private struct SelectionPress {
        let item: MediaItem?
        let documentPoint: CGPoint
        let windowPoint: CGPoint
        let modifiers: NSEvent.ModifierFlags
        let initialSelectedIDs: Set<String>
        let visibleRevision: Int
        let modeRevision: Int
        let toggleOnClick: Bool
    }
    // Keep the original click target in window coordinates: revealing the
    // inspector can resize and recenter the roll before the second mouse-down.
    private struct FirstClick {
        let id: String
        let event: NSEvent
        let windowPoint: CGPoint
        let timestamp: TimeInterval
        let visibleRevision: Int
        let modeRevision: Int
        var completed = false
    }
    private var firstClick: FirstClick?
    private var selectionPress: SelectionPress?
    private var selectionStroke: MediaSelectionStroke?
    private var dragWindowPoint: CGPoint?
    private var selectionAutoscrollTimer: Timer?
    var isSelectionGestureActive: Bool { selectionPress != nil }
    var isSelectionStrokeActive: Bool { selectionStroke != nil }
    var isSelectionAutoscrolling: Bool { selectionAutoscrollTimer?.isValid == true }

    override var acceptsFirstResponder: Bool { true }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            cancelSelectionStroke(); clearFirstClick()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(selectionWindowResignedKey),
                                               name: NSWindow.didResignKeyNotification, object: window)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.store?.layout == .browse, let window = self.window, window.isKeyWindow else { return }
            window.makeFirstResponder(self)
        }
    }
    @objc private func selectionWindowResignedKey() { cancelSelectionStroke(); clearFirstClick() }
    override func mouseDown(with event: NSEvent) {
        cancelSelectionStroke()
        window?.makeFirstResponder(self)
        guard let store, store.visibleRevision == mediaRevision else { return }
        if event.clickCount == 2 {
            let first = firstClick
            clearFirstClick()
            guard let first, first.completed,
                  store.visibleRevision == first.visibleRevision,
                  store.selectionModeRevision == first.modeRevision,
                  event.timestamp >= first.timestamp,
                  event.timestamp - first.timestamp <= NSEvent.doubleClickInterval,
                  hypot(event.locationInWindow.x - first.windowPoint.x,
                        event.locationInWindow.y - first.windowPoint.y) <= 4,
                  let target = store.visibleItems.first(where: { $0.id == first.id }) else { return }
            // The first click already selected or toggled this item. Opening
            // must preserve that result, including in batch selection mode.
            store.open(target); onSelectionChange?()
            return
        }
        clearFirstClick()
        guard event.clickCount < 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let item = item(at: point)
        if let item {
            firstClick = FirstClick(id: item.id, event: event, windowPoint: event.locationInWindow, timestamp: event.timestamp,
                                    visibleRevision: store.visibleRevision, modeRevision: store.selectionModeRevision)
        }
        if !store.isSelectionMode {
            if let item { store.activate(item, modifiers: event.modifierFlags) }
            else { store.clearSelection() }
            onSelectionChange?()
            return
        }
        // The pointer owns the viewport from mouse-down, before the stroke's
        // movement threshold. Invalidate any already queued keyboard centering.
        (enclosingScrollView as? BrowseScrollView)?.onUserScroll?()
        let shift = event.modifierFlags.contains(.shift)
        let alreadySelected = item.map { store.selectedIDs.contains($0.id) } ?? false
        selectionPress = SelectionPress(item: item, documentPoint: point, windowPoint: event.locationInWindow,
                                        modifiers: event.modifierFlags, initialSelectedIDs: store.selectedIDs,
                                        visibleRevision: store.visibleRevision,
                                        modeRevision: store.selectionModeRevision, toggleOnClick: alreadySelected && !shift)
        if let item {
            if !alreadySelected || shift { store.activate(item, modifiers: event.modifierFlags) }
            else { store.focus(item) }
        }
        onSelectionChange?()
    }

    override func mouseDragged(with event: NSEvent) {
        if let first = firstClick,
           hypot(event.locationInWindow.x - first.windowPoint.x, event.locationInWindow.y - first.windowPoint.y) >= 4 {
            clearFirstClick()
        }
        validateSelectionStroke()
        guard let press = selectionPress else { return }
        guard pointerIsInsideWindow(event.locationInWindow) else { cancelSelectionStroke(); return }
        let distance = hypot(event.locationInWindow.x - press.windowPoint.x,
                             event.locationInWindow.y - press.windowPoint.y)
        guard selectionStroke != nil || distance >= 4 else { return }
        beginSelectionStrokeIfNeeded()
        dragWindowPoint = event.locationInWindow
        extendSelectionStroke(to: convert(event.locationInWindow, from: nil), focusPointerItem: true)
        updateSelectionAutoscroll()
    }

    override func mouseUp(with event: NSEvent) {
        if let first = firstClick, event.clickCount == 1 {
            if pointerIsInsideWindow(event.locationInWindow),
               hypot(event.locationInWindow.x - first.windowPoint.x, event.locationInWindow.y - first.windowPoint.y) < 4 {
                firstClick?.completed = true
                if let store, store.visibleRevision == first.visibleRevision,
                   store.selectionModeRevision == first.modeRevision,
                   let item = store.visibleItems.first(where: { $0.id == first.id }) {
                    MediaDoubleClickTracker.shared.record(item: item, store: store, event: first.event)
                }
            } else { clearFirstClick() }
        }
        validateSelectionStroke()
        guard let press = selectionPress else { return }
        guard pointerIsInsideWindow(event.locationInWindow) else { cancelSelectionStroke(); return }
        if selectionStroke == nil,
           hypot(event.locationInWindow.x - press.windowPoint.x, event.locationInWindow.y - press.windowPoint.y) >= 4 {
            beginSelectionStrokeIfNeeded()
        }
        let didDrag = selectionStroke != nil
        if didDrag {
            extendSelectionStroke(to: convert(event.locationInWindow, from: nil), focusPointerItem: true)
        }
        cancelSelectionStroke()
        if !didDrag, press.toggleOnClick, let item = press.item {
            store?.activate(item, modifiers: press.modifiers)
            onSelectionChange?()
        }
    }

    func cancelPendingDoubleClick() { clearFirstClick() }

    private func clearFirstClick() {
        firstClick = nil
        if let store { MediaDoubleClickTracker.shared.cancel(store: store) }
    }

    func validateSelectionStroke() {
        guard let press = selectionPress else { return }
        guard let store, store.isSelectionMode, store.visibleRevision == press.visibleRevision,
              store.selectionModeRevision == press.modeRevision else {
            cancelSelectionStroke()
            return
        }
    }

    func cancelSelectionStroke() {
        stopSelectionAutoscroll()
        selectionPress = nil
        selectionStroke = nil
        dragWindowPoint = nil
    }

    private func item(at point: CGPoint) -> MediaItem? {
        guard let path = indexPathForItem(at: point), items.indices.contains(path.item),
              let store, store.visibleRevision == mediaRevision else { return nil }
        return items[path.item]
    }

    private func beginSelectionStrokeIfNeeded() {
        guard selectionStroke == nil, let press = selectionPress, let store else { return }
        // A modifier click may have temporarily selected a range on mouse-down.
        // Painting uses the original selection plus the actual pointer path.
        store.selectedIDs = press.initialSelectedIDs
        selectionStroke = MediaSelectionStroke(at: press.documentPoint)
        (enclosingScrollView as? BrowseScrollView)?.onUserScroll?()
        extendSelectionStroke(to: press.documentPoint, focusPointerItem: false)
    }

    private func pointerIsInsideWindow(_ point: CGPoint) -> Bool {
        guard let content = window?.contentView else { return false }
        return content.bounds.contains(content.convert(point, from: nil))
    }

    private func extendSelectionStroke(to rawPoint: CGPoint, focusPointerItem: Bool) {
        validateSelectionStroke()
        guard let store, var stroke = selectionStroke,
              let layout = collectionViewLayout as? BrowseAlbumLayout,
              let scroll = enclosingScrollView else { return }
        let viewport = scroll.contentView.bounds.intersection(bounds)
        guard viewport.width > 1, viewport.height > 1 else { return }
        let point = CGPoint(x: min(viewport.maxX - 0.5, max(viewport.minX + 0.5, rawPoint.x)),
                            y: min(viewport.maxY - 0.5, max(viewport.minY + 0.5, rawPoint.y)))
        let candidates: [(id: String, frame: CGRect)] = layout.layoutAttributesForElements(in: stroke.searchRect(to: point)).compactMap { attributes in
            guard let path = attributes.indexPath, items.indices.contains(path.item) else { return nil }
            return (items[path.item].id, attributes.frame)
        }
        let added = stroke.advance(to: point, candidates: candidates)
        selectionStroke = stroke
        if !added.isEmpty { store.selectedIDs.formUnion(added) }
        if focusPointerItem, viewport.contains(rawPoint), let item = item(at: rawPoint) { store.focus(item) }
        if !added.isEmpty || focusPointerItem { onSelectionChange?() }
    }

    private func selectionAutoscrollDelta() -> CGFloat {
        guard selectionStroke != nil, let point = dragWindowPoint, let scroll = enclosingScrollView else { return 0 }
        let viewport = scroll.contentView.bounds
        let pointer = convert(point, from: nil)
        guard pointer.y >= viewport.minY, pointer.y <= viewport.maxY,
              pointer.x >= viewport.minX - 24, pointer.x <= viewport.maxX + 24 else { return 0 }
        let edge = min(56, viewport.width / 4)
        guard edge > 0 else { return 0 }
        let direction: CGFloat
        let proximity: CGFloat
        if pointer.x < viewport.minX + edge {
            direction = -1; proximity = (viewport.minX + edge - pointer.x) / edge
        } else if pointer.x > viewport.maxX - edge {
            direction = 1; proximity = (pointer.x - viewport.maxX + edge) / edge
        } else { return 0 }
        let maximum = max(0, bounds.width - scroll.contentSize.width)
        if direction < 0 && viewport.minX <= 0.01 || direction > 0 && viewport.minX >= maximum - 0.01 { return 0 }
        return direction * (3 + 21 * pow(min(1, max(0, proximity)), 1.5))
    }

    private func updateSelectionAutoscroll() {
        guard selectionAutoscrollDelta() != 0 else { stopSelectionAutoscroll(); return }
        guard selectionAutoscrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                // AppKit normally delivers mouse-up even outside the window;
                // also stop if activation changed before that event arrived.
                guard NSEvent.pressedMouseButtons & 1 != 0, NSApp.isActive,
                      self.window?.isVisible == true else { self.cancelSelectionStroke(); return }
                if !self.advanceSelectionAutoscrollFrame() { self.stopSelectionAutoscroll() }
            }
        }
        selectionAutoscrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// A single real scroll-and-paint frame, also callable by hidden-window checks.
    @discardableResult func advanceSelectionAutoscrollFrame() -> Bool {
        validateSelectionStroke()
        guard selectionStroke != nil, let point = dragWindowPoint,
              let scroll = enclosingScrollView else { stopSelectionAutoscroll(); return false }
        guard pointerIsInsideWindow(point) else { cancelSelectionStroke(); return false }
        let delta = selectionAutoscrollDelta()
        let origin = scroll.contentView.bounds.origin
        let maximum = max(0, bounds.width - scroll.contentSize.width)
        let nextX = min(maximum, max(0, origin.x + delta))
        guard delta != 0, abs(nextX - origin.x) > 0.01 else { stopSelectionAutoscroll(); return false }
        (scroll as? BrowseScrollView)?.onUserScroll?()
        scroll.contentView.scroll(to: CGPoint(x: nextX, y: origin.y))
        scroll.reflectScrolledClipView(scroll.contentView)
        layoutSubtreeIfNeeded()
        extendSelectionStroke(to: convert(point, from: nil), focusPointerItem: false)
        if nextX <= 0.01 || nextX >= maximum - 0.01 { stopSelectionAutoscroll() }
        return true
    }

    private func stopSelectionAutoscroll() {
        selectionAutoscrollTimer?.invalidate()
        selectionAutoscrollTimer = nil
    }
    override func keyDown(with event: NSEvent) {
        clearFirstClick()
        guard let store else { super.keyDown(with: event); return }
        let plainNavigation = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if plainNavigation, [123, 124].contains(event.keyCode), !store.visibleItems.isEmpty {
            let next = min(max(0, store.browseIndex + (event.keyCode == 123 ? -1 : 1)), store.visibleItems.count - 1)
            if store.isSelectionMode && event.modifierFlags.contains(.shift) {
                store.select(store.visibleItems[next], modifiers: [.shift])
            } else { store.focus(store.visibleItems[next]) }
            onSelectionChange?(); return
        }
        if plainNavigation, event.keyCode == 49 || event.keyCode == 36 {
            if store.visibleItems.indices.contains(store.browseIndex) {
                let item = store.visibleItems[store.browseIndex]
                if event.keyCode == 49 && store.isSelectionMode { store.activate(item, modifiers: event.modifierFlags) }
                else { store.open(item) }
            }
            onSelectionChange?()
            return
        }
        if !event.modifierFlags.contains(.command), [51, 117].contains(event.keyCode), case let .album(id) = store.scope {
            store.removeFromAlbum(store.selectedIDs, albumID: id)
            onSelectionChange?(); return
        }
        if event.keyCode == 120, store.managementItems.count == 1, !store.isPerformingFileOperation,
           let item = store.managementItems.first, !store.isOffline(item) {
            store.promptRename(item); return
        }
        if plainNavigation, event.keyCode == 53 {
            cancelSelectionStroke()
            if store.isSelectionMode { store.setSelectionMode(false) }
            else { store.clearSelection() }
            onSelectionChange?(); return
        }
        super.keyDown(with: event)
    }
    override func selectAll(_ sender: Any?) { store?.selectAll(); onSelectionChange?() }
    @objc func copy(_ sender: Any?) { store?.copySelectedFiles() }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let store, let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)), items.indices.contains(path.item) else { return nil }
        let item = items[path.item]
        store.focus(item)
        let targets = store.isSelectionMode && store.selectedIDs.contains(item.id) ? store.selectedItems : [item]
        onSelectionChange?()
        return MediaMenus.make(store: store, items: targets)
    }

    isolated deinit {
        selectionAutoscrollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}

@MainActor private final class BrowseAlbumLayout: NSCollectionViewFlowLayout {
    override init() {
        super.init()
        // AppKit otherwise treats a custom layout as vertical and repeatedly
        // constrains the document width to its clip view during scrolling.
        scrollDirection = .horizontal
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var items: [MediaItem] = []
    private var frames: [CGRect] = []
    private var revision = -1
    private var showNames = false
    private var preparedViewport = CGSize.zero
    private var needsRebuild = true
    private var dirtyIndexes = Set<Int>()
    private var content = CGSize.zero
    private(set) var photoHeight: CGFloat = 0
    private(set) var layoutGeneration = 0
    private(set) var lastMeasuredItemCount = 0
    func configure(items: [MediaItem], revision: Int, showNames: Bool) {
        guard self.revision != revision || self.showNames != showNames else { return }
        self.items = items; self.revision = revision; self.showNames = showNames
        needsRebuild = true; invalidateLayout()
    }
    func applyMetadata(items: [MediaItem], geometryIndexes: Set<Int>?) {
        self.items = items
        guard let geometryIndexes else { needsRebuild = true; invalidateLayout(); return }
        guard !geometryIndexes.isEmpty else { return }
        dirtyIndexes.formUnion(geometryIndexes)
        invalidateLayout()
    }
    override func prepare() {
        super.prepare()
        guard let viewport = collectionView?.enclosingScrollView?.contentSize, viewport.width > 1, viewport.height > 1 else { return }
        let fullRebuild = needsRebuild || viewport != preparedViewport || frames.count != items.count
        guard fullRebuild || !dirtyIndexes.isEmpty else { return }
        needsRebuild = false; preparedViewport = viewport
        layoutGeneration += 1
        let caption: CGFloat = showNames ? 24 : 0
        photoHeight = max(0, viewport.height - caption)
        func size(for item: MediaItem) -> CGSize {
            let ratio = item.aspectRatio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? (item.isLocal ? 1.5 : 1)
            // Fill the photograph's available height, except for panoramas:
            // those fit the viewport width so the whole image remains visible.
            let height = min(photoHeight, viewport.width / ratio)
            return CGSize(width: min(viewport.width, height * ratio), height: height)
        }
        if fullRebuild {
            frames = []
            frames.reserveCapacity(items.count)
            var x: CGFloat = 0
            for (index, item) in items.enumerated() {
                let size = size(for: item)
                if index == 0 { x = max(0, (viewport.width - size.width) / 2) }
                frames.append(CGRect(x: x, y: (photoHeight - size.height) / 2,
                                     width: size.width, height: size.height + caption))
                x += size.width + 24
            }
            lastMeasuredItemCount = items.count
        } else if let first = dirtyIndexes.filter({ items.indices.contains($0) }).min() {
            // A changed width shifts the following roll. Only changed photographs
            // need measuring; keep the existing frame storage and item index.
            var x = first == 0 ? 0 : frames[first - 1].maxX + 24
            for index in first..<frames.count {
                let measured = dirtyIndexes.contains(index)
                let size = measured ? size(for: items[index]) : CGSize(width: frames[index].width, height: frames[index].height - caption)
                if index == 0 { x = max(0, (viewport.width - size.width) / 2) }
                frames[index] = CGRect(x: x, y: (photoHeight - size.height) / 2,
                                       width: size.width, height: size.height + caption)
                x += size.width + 24
            }
            lastMeasuredItemCount = dirtyIndexes.count
        }
        dirtyIndexes.removeAll(keepingCapacity: true)
        content = CGSize(width: max(viewport.width, (frames.last?.maxX ?? 0) + max(0, (viewport.width - (frames.last?.width ?? 0)) / 2)), height: viewport.height)
    }
    override var collectionViewContentSize: NSSize { content }
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { collectionView?.enclosingScrollView?.contentSize != preparedViewport }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard frames.indices.contains(indexPath.item) else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = frames[indexPath.item]
        return attributes
    }
    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        var low = 0, high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].maxX < rect.minX { low = middle + 1 } else { high = middle }
        }
        var result: [NSCollectionViewLayoutAttributes] = []
        for index in low..<frames.count {
            if frames[index].minX > rect.maxX { break }
            if frames[index].intersects(rect), let attributes = layoutAttributesForItem(at: IndexPath(item: index, section: 0)) { result.append(attributes) }
        }
        return result
    }
    func frame(at index: Int) -> CGRect? { frames.indices.contains(index) ? frames[index] : nil }
    func center(at position: Double) -> CGFloat? {
        guard !frames.isEmpty, position.isFinite else { return nil }
        let value = min(Double(frames.count - 1), max(0, position))
        let lower = Int(floor(value)), upper = min(frames.count - 1, lower + 1)
        return frames[lower].midX + (frames[upper].midX - frames[lower].midX) * CGFloat(value - Double(lower))
    }
    func position(at x: CGFloat) -> Double? {
        guard !frames.isEmpty else { return nil }
        var low = 0, high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].midX < x { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return 0 }
        guard low < frames.count else { return Double(frames.count - 1) }
        let before = low - 1, span = frames[low].midX - frames[before].midX
        return Double(before) + Double(span > 0 ? (x - frames[before].midX) / span : 0)
    }
    func nearestIndex(to x: CGFloat) -> Int? { position(at: x).map { Int($0.rounded()) } }

}

@MainActor private final class BrowseAccessiblePhoto: NSView {
    var onPress: (() -> Bool)?
    var onOpen: (() -> Bool)?
    override func accessibilityPerformPress() -> Bool { onPress?() ?? false }
    @objc func openPhoto() -> Bool { onOpen?() ?? false }
}

@MainActor private final class BrowseCollectionItem: NSCollectionViewItem {
    var media: MediaItem?
    private var hosting: NSHostingView<BrowsePhotoCell>?
    private var signature: String?
    override func loadView() { view = BrowseAccessiblePhoto(); view.wantsLayer = true }
    func configure(_ item: MediaItem, active: Bool, selected: Bool, effects: Bool, showNames: Bool, pixelSize: Int,
                   selectionMode: Bool = false, playback: BrowseVideoPlayback? = nil,
                   photoPreview: BrowsePhotoPreview? = nil, onReconnect: @escaping () -> Void = {}) {
        let metadataChanged = media != item
        media = item
        let next = "\(item.id)|\(item.modifiedDate.timeIntervalSince1970)|\(active)|\(selected)|\(effects)|\(showNames)|\(pixelSize)|\(selectionMode)"
        guard next != signature || hosting == nil || metadataChanged else { return }
        signature = next
        let content = BrowsePhotoCell(item: item, active: active, selected: selected, effects: effects, showNames: showNames,
                                      pixelSize: pixelSize, selectionMode: selectionMode, playback: playback,
                                      photoPreview: photoPreview, onReconnect: onReconnect)
        if let hosting { hosting.rootView = content }
        else {
            let hosting = NSHostingView(rootView: content)
            hosting.sizingOptions = []; hosting.translatesAutoresizingMaskIntoConstraints = false
            hosting.focusRingType = .none
            view.addSubview(hosting)
            NSLayoutConstraint.activate([hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor), hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor), hosting.topAnchor.constraint(equalTo: view.topAnchor), hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
            self.hosting = hosting
        }
        view.setAccessibilityElement(true); view.setAccessibilityRole(.button)
        view.setAccessibilityLabel("\(item.name)，\(item.kind == .image ? "照片" : "视频")")
        view.setAccessibilitySelected(selected); view.setAccessibilityValue(active ? "当前项目" : nil)
        view.setAccessibilityHelp(selectionMode ? "按下以选择或取消选择，双击打开。" : "按下以选择并查看信息，双击打开。")
        if let accessibleView = view as? BrowseAccessiblePhoto {
            accessibleView.setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: "打开", target: accessibleView, selector: #selector(BrowseAccessiblePhoto.openPhoto))
            ])
        }
    }
    func releaseImage() { hosting?.removeFromSuperview(); hosting = nil; signature = nil }
    override func prepareForReuse() {
        super.prepareForReuse(); releaseImage(); media = nil
        (view as? BrowseAccessiblePhoto)?.onPress = nil; (view as? BrowseAccessiblePhoto)?.onOpen = nil
    }
}

private struct BrowsePhotoCell: View {
    let item: MediaItem
    let active: Bool
    let selected: Bool
    let effects: Bool
    let showNames: Bool
    let pixelSize: Int
    let selectionMode: Bool
    let playback: BrowseVideoPlayback?
    let photoPreview: BrowsePhotoPreview?
    let onReconnect: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                AsyncThumbnail(item: item, pixelSize: pixelSize, contentMode: .fit)
                if active, item.kind == .image, let photoPreview {
                    BrowseFocusedPhoto(item: item, photoPreview: photoPreview, onReconnect: onReconnect)
                }
                if active, item.kind == .video, let playback, playback.currentID == item.id, !playback.failed {
                    BrowseVideoSurface(playback: playback)
                }
            }
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .modifier(MediaSelectionTreatment(selected: selected, selectionMode: selectionMode))
                .overlay(alignment: .bottomTrailing) {
                    if item.kind == .video && !(active && playback?.isPlaying == true) {
                        Image(systemName: "play.fill").font(.system(size: 12)).foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 2).padding(12)
                    }
                }
            if showNames {
                Text(item.name).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(scheme == .dark ? Color.white.opacity(0.65) : Color.black.opacity(0.60))
                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: 24)
            }
        }.accessibilityHidden(true)
    }
}

private struct BrowseFocusedPhoto: View {
    let item: MediaItem
    let photoPreview: BrowsePhotoPreview
    let onReconnect: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var session: PhotoPreviewSession? { photoPreview.currentID == item.id ? photoPreview.preview : nil }
    private var original: CloudTransferSnapshot? {
        item.isLocal ? nil : CloudTransferCenter.shared.snapshot(for: item.id, purpose: .original)
    }
    private var feedback: PhotoPreviewFeedback? {
        guard let session else { return nil }
        return PhotoPreviewFeedback.presentation(state: session.state, item: item, isOffline: false,
            original: original, needsLogin: item.cloud.map { CloudTransferCenter.shared.issue(for: $0.accountID) != nil } ?? false)
    }
    var body: some View {
        ZStack {
            if let session, session.state == .ready, let thumbnail = session.thumbnail {
                Image(nsImage: thumbnail.image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).transition(.opacity)
                    .allowsHitTesting(false)
            }
            if let feedback {
                PhotoPreviewProgress(feedback: feedback, item: item, onRetry: { photoPreview.retry() }, onReconnect: onReconnect)
                    .allowsHitTesting(feedback.kind != .loading)
            }
        }.overlay(alignment: .topLeading) {
            if !item.isLocal, session?.state == .ready {
                CloudAssetBadge(item: item).padding(7)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: session?.state == .ready)
    }
}
