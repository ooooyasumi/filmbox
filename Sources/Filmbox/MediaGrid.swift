import AppKit
import SwiftUI
import QuartzCore
import FilmboxCore

// Native reuse and focus, with our own temporal layout.
struct MediaGrid: NSViewRepresentable {
    let store: AppStore
    @AppStorage("showFileNames") private var showFileNames = false
    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.tearDown()
        (nsView as? TimelineScrollView)?.onScroll = nil
        (nsView.documentView as? PhotoCollectionView)?.synchronizeSelection = nil
    }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TimelineScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.store = store
        let collection = PhotoCollectionView()
        collection.focusRingType = .none
        collection.autoresizingMask = [.width]
        collection.collectionViewLayout = TemporalCollectionLayout()
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.setDraggingSourceOperationMask(.copy, forLocal: true)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.backgroundColors = [.clear]
        collection.register(PhotoCollectionItem.self, forItemWithIdentifier: .init("photo"))
        collection.register(TimelineHeaderView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: .init("date"))
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.store = store
        collection.mediaCoordinator = context.coordinator
        collection.setAccessibilityLabel("照片和视频时间线")
        collection.synchronizeSelection = { [weak coordinator = context.coordinator] in coordinator?.applySelection() }
        scroll.onScroll = { [weak coordinator = context.coordinator] in coordinator?.scheduleVisibleSectionUpdate() }
        scroll.documentView = collection
        context.coordinator.collection = collection
        store.gridBrowsePositionProvider = context.coordinator
        context.coordinator.installPlaybackVisibility(in: scroll)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let collection = scroll.documentView as? PhotoCollectionView,
              let layout = collection.collectionViewLayout as? TemporalCollectionLayout else { return }
        let coordinator = context.coordinator
        coordinator.store = store
        store.gridBrowsePositionProvider = coordinator
        collection.store = store
        (scroll as? TimelineScrollView)?.store = store
        if coordinator.scrollRequestID != store.scrollRequestID {
            coordinator.scrollRequestID = store.scrollRequestID
            if let id = store.scrollTargetID {
                coordinator.preferViewportAnchor(id)
                collection.requestScrollToPhoto(id, fraction: store.scrollTargetFraction)
            }
        }
        if coordinator.browseScrollRequestID != store.browseScrollRequestID {
            coordinator.browseScrollRequestID = store.browseScrollRequestID
            if let id = store.navigationAnchorID ?? store.keyboardCursor { coordinator.preferViewportAnchor(id) }
        }
        if coordinator.gridTimelineScrollRequestID != store.gridTimelineScrollRequestID {
            coordinator.gridTimelineScrollRequestID = store.gridTimelineScrollRequestID
            if let target = store.gridTimelineScrollTarget {
                coordinator.preferViewportAnchor(nil)
                collection.requestScroll(to: target)
            }
        }
        let oldViewport = scroll.contentView.bounds.origin
        let oldFrames = Dictionary(uniqueKeysWithValues: collection.visibleItems().compactMap { cell -> (String, CGRect)? in
            guard let photo = cell as? PhotoCollectionItem, let id = photo.media?.id else { return nil }
            return (id, cell.view.frame)
        })
        let timelineChanged = coordinator.revision != store.timelineRevision
        let metadataChanged = coordinator.metadataRevision != store.mediaMetadataRevision
        let metadata = !timelineChanged && metadataChanged ? store.mediaMetadataChanges(since: coordinator.metadataRevision) : nil
        let replaceSnapshot = timelineChanged || (metadataChanged && metadata == nil)
        let sectionsChanged = timelineChanged && (coordinator.sections.map(\.id) != store.timelineSections.map(\.id)
            || coordinator.sections.map { $0.items.map(\.id) } != store.timelineSections.map { $0.items.map(\.id) })
        let namesChanged = coordinator.showNames != showFileNames
        if timelineChanged || namesChanged || metadata?.geometryChangedIDs.isEmpty == false { coordinator.cancelPrefetch() }
        coordinator.isUpdating = true
        collection.cancelInvalidSelectionGesture()
        collection.isSelectable = true
        if replaceSnapshot {
            coordinator.sections = store.timelineSections
            coordinator.rebuildIndex()
            collection.visualOrder = coordinator.visualOrder
        } else if let metadata {
            coordinator.sections = store.timelineSections
            for id in metadata.changedIDs {
                guard let path = coordinator.pathByID[id], coordinator.sections.indices.contains(path.section),
                      coordinator.sections[path.section].items.indices.contains(path.item) else { continue }
                coordinator.mediaByPath[path] = coordinator.sections[path.section].items[path.item]
            }
        }
        coordinator.revision = store.timelineRevision
        coordinator.visibleRevision = store.visibleRevision
        coordinator.metadataRevision = store.mediaMetadataRevision
        coordinator.showNames = showFileNames
        layout.configure(sections: coordinator.sections, revision: store.timelineRevision, targetHeight: store.thumbnailSize, showNames: showFileNames)
        if metadataChanged && !timelineChanged {
            layout.applyMetadata(sections: coordinator.sections,
                                 geometrySections: metadata.map { Set($0.geometryChangedIDs.compactMap { coordinator.pathByID[$0]?.section }) })
        }
        if sectionsChanged || namesChanged { collection.reloadData() }
        collection.layoutSubtreeIfNeeded()
        if timelineChanged || metadata?.geometryChangedIDs.isEmpty == false, !sectionsChanged, !namesChanged, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            DispatchQueue.main.async { [weak collection, weak scroll] in
                guard let collection, let scroll else { return }
                let offset = scroll.contentView.bounds.origin.y - oldViewport.y
                for case let cell as PhotoCollectionItem in collection.visibleItems() {
                    guard let id = cell.media?.id, let old = oldFrames[id], let layer = cell.view.layer,
                          old != cell.view.frame else { continue }
                    let position = CABasicAnimation(keyPath: "position")
                    position.fromValue = NSValue(point: CGPoint(x: old.minX, y: old.minY + offset))
                    position.toValue = NSValue(point: layer.position)
                    position.duration = 0.2
                    position.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    let bounds = CABasicAnimation(keyPath: "bounds.size")
                    bounds.fromValue = NSValue(size: old.size); bounds.toValue = NSValue(size: cell.view.bounds.size)
                    bounds.duration = 0.2; bounds.timingFunction = position.timingFunction
                    layer.add(position, forKey: "cloudGeometryPosition")
                    layer.add(bounds, forKey: "cloudGeometryBounds")
                }
            }
        }
        coordinator.applySelection()
        coordinator.isUpdating = false
        for case let cell as PhotoCollectionItem in collection.visibleItems() {
            if let path = collection.indexPath(for: cell), let item = coordinator.mediaByPath[path] {
                if timelineChanged || (metadataChanged && (metadata == nil || metadata?.changedIDs.contains(item.id) == true)), !sectionsChanged, cell.media != item {
                    cell.configure(item, favorite: store.favorites.contains(item.id), showNames: showFileNames, store: store) { [weak coordinator] in coordinator?.applySelection() }
                }
                cell.updatePresentation(favorite: store.favorites.contains(item.id), selectionMode: store.isSelectionMode)
            }
        }
        coordinator.updatePlayback()
        coordinator.scheduleVisibleSectionUpdate()
    }
    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, GridBrowsePositionProviding {
        var store: AppStore
        weak var collection: PhotoCollectionView?
        var sections: [TemporalSection] = []
        var mediaByPath: [IndexPath: MediaItem] = [:]
        var pathByID: [String: IndexPath] = [:]
        var visualOrder: [IndexPath] = []
        var revision = -1
        var visibleRevision = -1
        var metadataRevision = -1
        var scrollRequestID = -1
        var browseScrollRequestID = -1
        var gridTimelineScrollRequestID = -1
        var showNames = false
        var isUpdating = false
        private var visibilityUpdateScheduled = false
        private struct PrefetchKey: Hashable {
            let id: String
            let modifiedDate: Date
            let kind: MediaKind
            init(_ item: MediaItem) { id = item.id; modifiedDate = item.modifiedDate; kind = item.kind }
        }
        private struct PrefetchContext: Equatable {
            let viewport: CGRect
            let revision: Int
        }
        private var prefetchContext: PrefetchContext?
        private var prefetchTask: Task<Void, Never>?
        private var prefetchGeneration = 0
        private var prefetchedKeys: Set<PrefetchKey> = []
        private var prefetchedOrder: [PrefetchKey] = []
        private var isTornDown = false
        let previewSession = GridVideoPreviewSession()
        private let playbackVisibility = BrowsePlaybackVisibilityView()
        private var windowVisible = false
        private var publishedLayoutGeneration = -1
        private var preferredViewportAnchorID: String?
        private var preferredViewportOrigin: CGPoint?
        private var preferredViewportLayoutGeneration: Int?
        init(store: AppStore) {
            self.store = store
            super.init()
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(playbackEnvironmentChanged), name: name, object: nil)
            }
        }
        func installPlaybackVisibility(in scroll: NSScrollView) {
            playbackVisibility.frame = .zero
            playbackVisibility.configure { [weak self] visible in
                guard let self, !self.isTornDown else { return }
                self.windowVisible = visible
                self.updatePlayback()
            }
            scroll.addSubview(playbackVisibility)
        }
        @objc private func playbackEnvironmentChanged() { updatePlayback() }
        func preferViewportAnchor(_ id: String?) {
            preferredViewportAnchorID = id
            preferredViewportOrigin = nil
            preferredViewportLayoutGeneration = nil
            (collection?.collectionViewLayout as? TemporalCollectionLayout)?.preferredViewportAnchorID = id
        }
        private func viewportAnchor(layout: TemporalCollectionLayout, viewport: CGRect, probeY: CGFloat) -> (path: IndexPath, fraction: Double)? {
            if let id = preferredViewportAnchorID {
                let sameGeometry = preferredViewportLayoutGeneration == layout.layoutGeneration
                let scrolled = preferredViewportOrigin.map { abs($0.y - viewport.minY) > 0.5 } ?? false
                if sameGeometry && scrolled {
                    // Only a changed document origin after the explicit focus
                    // settled relinquishes it. A reflow has a new generation.
                    preferViewportAnchor(nil)
                } else if let path = pathByID[id], let frame = layout.frame(for: id), frame.intersects(viewport) {
                    preferredViewportOrigin = viewport.origin
                    preferredViewportLayoutGeneration = layout.layoutGeneration
                    return (path, Double(min(1, max(0, (probeY - frame.minY) / max(1, frame.height)))))
                } else {
                    preferViewportAnchor(nil)
                }
            }
            return layout.firstVisibleItem(at: probeY, viewport: viewport)
        }
        func browseTransitionTargetID() -> String? {
            guard !isTornDown, let collection,
                  let layout = collection.collectionViewLayout as? TemporalCollectionLayout,
                  let scroll = collection.enclosingScrollView else { return nil }
            collection.layoutSubtreeIfNeeded()
            let viewport = scroll.contentView.bounds
            guard viewport.width > 1, viewport.height > 1 else { return nil }
            let center = CGPoint(x: viewport.midX, y: viewport.midY)
            let candidates = layout.layoutAttributesForElements(in: viewport).compactMap { attributes -> (id: String, frame: CGRect)? in
                guard attributes.representedElementCategory == .item,
                      let path = attributes.indexPath, let item = mediaByPath[path],
                      store.visibleMediaIndex(id: item.id) != nil else { return nil }
                let intersection = attributes.frame.intersection(viewport)
                guard intersection.width > 1, intersection.height > 1 else { return nil }
                return (item.id, attributes.frame)
            }
            // Prefer the last explicitly selected photo in a multi-selection.
            if let cursor = store.keyboardCursor, store.selectedIDs.contains(cursor),
               candidates.contains(where: { $0.id == cursor }) { return cursor }
            func distance(_ frame: CGRect) -> CGFloat {
                let x = center.x - min(frame.maxX, max(frame.minX, center.x))
                let y = center.y - min(frame.maxY, max(frame.minY, center.y))
                return x * x + y * y
            }
            let ordered = candidates.sorted {
                let a = distance($0.frame), b = distance($1.frame)
                if abs(a - b) > 0.01 { return a < b }
                let da = hypot($0.frame.midX - center.x, $0.frame.midY - center.y)
                let db = hypot($1.frame.midX - center.x, $1.frame.midY - center.y)
                return da == db ? $0.id < $1.id : da < db
            }
            return ordered.first(where: { store.selectedIDs.contains($0.id) })?.id ?? ordered.first?.id
        }
        func updatePlayback() {
            guard !isTornDown, let collection,
                  let layout = collection.collectionViewLayout as? TemporalCollectionLayout else { previewSession.stop(); return }
            let viewport = collection.enclosingScrollView?.contentView.bounds ?? .zero
            let media = store.gridPreviewID.flatMap { pathByID[$0] }.flatMap { path -> MediaItem? in
                guard let frame = layout.layoutAttributesForItem(at: path)?.frame,
                      frame.intersection(viewport).width > 1, frame.intersection(viewport).height > 1 else { return nil }
                return mediaByPath[path]
            }
            let presented = NSApp.isActive && windowVisible && NSApp.keyWindow === collection.window
            previewSession.update(item: media, store: store, presented: presented)
            for case let cell as PhotoCollectionItem in collection.visibleItems() {
                cell.updatePreview(session: previewSession)
            }
        }
        func rebuildIndex() {
            mediaByPath = [:]; pathByID = [:]; visualOrder = []
            for (sectionIndex, section) in sections.enumerated() {
                for (itemIndex, media) in section.items.enumerated() {
                    let path = IndexPath(item: itemIndex, section: sectionIndex)
                    mediaByPath[path] = media
                    pathByID[media.id] = path
                    visualOrder.append(path)
                }
            }
        }
        func applySelection() {
            guard let collection else { return }
            let wasUpdating = isUpdating
            isUpdating = true
            let selection = Set(store.selectedIDs.compactMap { pathByID[$0] })
            if collection.selectionIndexPaths != selection { collection.selectionIndexPaths = selection }
            isUpdating = wasUpdating
        }
        func scheduleVisibleSectionUpdate() {
            guard !isTornDown else { return }
            if let context = prefetchContext,
               context.revision != revision || context.viewport != collection?.enclosingScrollView?.contentView.bounds {
                cancelPrefetch()
            }
            guard !visibilityUpdateScheduled else { return }
            visibilityUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                self.visibilityUpdateScheduled = false
                guard let collection = self.collection,
                      let layout = collection.collectionViewLayout as? TemporalCollectionLayout else { return }
                guard !collection.hasPendingScroll, !layout.hasPendingViewportRestore,
                      self.scrollRequestID == self.store.scrollRequestID,
                      self.browseScrollRequestID == self.store.browseScrollRequestID,
                      self.gridTimelineScrollRequestID == self.store.gridTimelineScrollRequestID,
                      self.revision == self.store.timelineRevision,
                      self.visibleRevision == self.store.visibleRevision, self.store.layout == .grid else { return }
                let viewport = collection.enclosingScrollView?.contentView.bounds ?? .zero
                let y = viewport.minY + min(44, viewport.height / 2)
                let id = layout.sectionID(at: y)
                if self.store.visibleTimelineSectionID != id { self.store.setVisibleTimelineSection(id) }
                let geometryChanged = self.publishedLayoutGeneration != layout.layoutGeneration
                self.publishedLayoutGeneration = layout.layoutGeneration
                let anchor = self.viewportAnchor(layout: layout, viewport: viewport, probeY: y)
                self.store.updateGridTimeline(spans: geometryChanged ? layout.dateSpans : nil,
                    position: Double(viewport.minY), totalLength: Double(layout.collectionViewContentSize.height),
                    anchor: anchor.flatMap { self.mediaByPath[$0.path] }, anchorFraction: anchor?.fraction ?? 0)
                self.updatePlayback()
                self.schedulePrefetchIfNeeded()
            }
        }
        func cancelPrefetch() {
            prefetchGeneration += 1
            prefetchTask?.cancel()
            prefetchTask = nil
            prefetchContext = nil
        }
        func tearDown() {
            if store.gridBrowsePositionProvider === self { store.gridBrowsePositionProvider = nil }
            collection?.cancelSelectionGesture()
            if let collection {
                for case let cell as PhotoCollectionItem in collection.visibleItems() { cell.releaseImage() }
            }
            isTornDown = true
            NotificationCenter.default.removeObserver(self)
            playbackVisibility.tearDown()
            previewSession.stop()
            cancelPrefetch()
            prefetchedKeys = []
            prefetchedOrder = []
        }
        private func schedulePrefetchIfNeeded() {
            guard !isTornDown, let scroll = collection?.enclosingScrollView else { return }
            let viewport = scroll.contentView.bounds
            guard viewport.width > 1, viewport.height > 1 else { cancelPrefetch(); return }
            let context = PrefetchContext(viewport: viewport, revision: revision)
            guard context != prefetchContext else { return }
            cancelPrefetch()
            prefetchContext = context
            let generation = prefetchGeneration
            prefetchTask = Task(priority: .background) { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, self?.prefetchGeneration == generation,
                      let candidates = self?.prefetchCandidates(in: context.viewport) else { return }
                for media in candidates {
                    guard !Task.isCancelled, self?.prefetchGeneration == generation else { return }
                    // This is an independent consumer of the same shared/cache-first request
                    // as the cell. Cancelling it must never cancel a visible consumer.
                    let thumbnail = await ThumbnailService.shared.thumbnail(
                        for: media.url, kind: media.kind, modifiedDate: media.modifiedDate,
                        pixelSize: gridThumbnailPixelSize, priority: .background
                    )
                    guard !Task.isCancelled, self?.prefetchGeneration == generation else { return }
                    if thumbnail != nil { self?.rememberPrefetch(PrefetchKey(media)) }
                }
            }
        }
        private func prefetchCandidates(in viewport: CGRect) -> [MediaItem] {
            guard let layout = collection?.collectionViewLayout as? TemporalCollectionLayout else { return [] }
            let region = viewport.insetBy(dx: 0, dy: -viewport.height)
            let neighbors = layout.layoutAttributesForElements(in: region).compactMap { attributes -> (MediaItem, CGFloat, CGFloat)? in
                guard attributes.representedElementCategory == .item,
                      !attributes.frame.intersects(viewport), let path = attributes.indexPath,
                      let media = mediaByPath[path], !prefetchedKeys.contains(PrefetchKey(media)) else { return nil }
                let distance = max(viewport.minY - attributes.frame.maxY, attributes.frame.minY - viewport.maxY)
                return (media, distance, attributes.frame.minX)
            }
            return neighbors.sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                if $0.2 != $1.2 { return $0.2 < $1.2 }
                return $0.0.id < $1.0.id
            }.prefix(16).map(\.0)
        }
        private func rememberPrefetch(_ key: PrefetchKey) {
            guard prefetchedKeys.insert(key).inserted else { return }
            prefetchedOrder.append(key)
            if prefetchedOrder.count > 256 { prefetchedKeys.remove(prefetchedOrder.removeFirst()) }
        }
        func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }
        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
            store.isSelectionMode && !indexPaths.isEmpty && indexPaths.allSatisfy { mediaByPath[$0]?.url.isFileURL == true }
        }
        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
            guard let url = mediaByPath[indexPath]?.url, url.isFileURL else { return nil }
            // NSURL publishes public.file-url for both SwiftUI album targets and Finder.
            // It is a reference to the source: the operation mask never permits moving it.
            return url as NSURL
        }
        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
            synchronize(collectionView)
        }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            sections.indices.contains(section) ? sections[section].items.count : 0
        }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = collectionView.makeItem(withIdentifier: .init("photo"), for: indexPath) as! PhotoCollectionItem
            if let media = mediaByPath[indexPath] {
                cell.configure(media, favorite: store.favorites.contains(media.id), showNames: showNames, store: store) { [weak self, weak collectionView] in
                    if let collectionView { collectionView.window?.makeFirstResponder(collectionView) }
                    self?.applySelection()
                }
                cell.updatePreview(session: previewSession)
            }
            return cell
        }
        func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
            (item as? PhotoCollectionItem)?.releaseImage()
        }
        func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
            let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: .init("date"), for: indexPath) as! TimelineHeaderView
            guard sections.indices.contains(indexPath.section) else { view.isHidden = true; return view }
            view.isHidden = false
            let section = sections[indexPath.section]
            view.configure(title: section.title, count: section.items.count)
            return view
        }
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { synchronize(collectionView) }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { synchronize(collectionView) }
        private func synchronize(_ collection: NSCollectionView) {
            guard !isUpdating else { return }
            guard store.isSelectionMode else { applySelection(); return }
            store.selectedIDs = Set(collection.selectionIndexPaths.compactMap { mediaByPath[$0]?.id })
            if let path = collection.selectionIndexPaths.sorted().last, let media = mediaByPath[path] {
                store.selectionAnchor = media.id
                store.keyboardCursor = media.id
                if let index = store.visibleItems.firstIndex(where: { $0.id == media.id }) { store.browseIndex = index }
            }
        }
    }
}

@MainActor private final class TimelineScrollView: NSScrollView {
    weak var store: AppStore?
    var onScroll: (() -> Void)?
    override func scrollWheel(with event: NSEvent) {
        CloudMetadataUpdates.shared.noteInteraction()
        if event.modifierFlags.contains(.command) { store?.zoomTimeline(with: event); return }
        super.scrollWheel(with: event)
    }
    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        onScroll?()
    }
}

@MainActor private final class TemporalCollectionLayout: NSCollectionViewLayout {
    private struct Row { var rect: CGRect; var attributes: [NSCollectionViewLayoutAttributes] }
    private struct SectionGeometry {
        let header: CGRect
        let attributes: [NSCollectionViewLayoutAttributes]
        let rows: [Row]
        let rowByItem: [Int]
        let height: CGFloat
    }
    private struct ViewportAnchor { let id: String; let offset: CGFloat }
    private var sections: [TemporalSection] = []
    private var revision = -1
    private var targetHeight: Double = 180
    private var showNames = false
    private var preparedWidth: CGFloat = -1
    private var needsRebuild = true
    private var dirtySections = Set<Int>()
    private var geometries: [SectionGeometry] = []
    private var sectionOffsets: [CGFloat] = []
    private var height: CGFloat = 0
    private var pathByID: [String: IndexPath] = [:]
    private var headers: [NSCollectionViewLayoutAttributes] = []
    private var generation = 0
    var preferredViewportAnchorID: String?
    private(set) var dateSpans: [TimelineDateSpan] = []
    private(set) var hasPendingViewportRestore = false
    private(set) var layoutGeneration = 0
    private(set) var lastRebuiltSectionCount = 0
    private var pendingViewportAnchor: ViewportAnchor?
    private var pendingViewportOrigin: CGFloat?

    func configure(sections: [TemporalSection], revision: Int, targetHeight: Double, showNames: Bool) {
        guard self.revision != revision || self.targetHeight != targetHeight || self.showNames != showNames else { return }
        let geometryChanged = self.targetHeight != targetHeight || self.showNames != showNames
            || self.sections.map(\.id) != sections.map(\.id)
            || !zip(self.sections, sections).allSatisfy { old, new in
                old.items.count == new.items.count && zip(old.items, new.items).allSatisfy { lhs, rhs in
                    lhs.id == rhs.id && lhs.aspectRatio == rhs.aspectRatio
                }
            }
        self.sections = sections; self.revision = revision
        self.targetHeight = targetHeight; self.showNames = showNames
        guard geometryChanged else { return }
        needsRebuild = true
        invalidateLayout()
    }
    func applyMetadata(sections: [TemporalSection], geometrySections: Set<Int>?) {
        self.sections = sections
        guard let geometrySections else { needsRebuild = true; invalidateLayout(); return }
        guard !geometrySections.isEmpty else { return }
        dirtySections.formUnion(geometrySections)
        invalidateLayout()
    }
    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = max(1, collectionView.enclosingScrollView?.contentSize.width ?? collectionView.bounds.width)
        let fullRebuild = needsRebuild || abs(width - preparedWidth) > 0.5 || geometries.count != sections.count
        guard fullRebuild || !dirtySections.isEmpty else { return }
        let anchor = hasPendingViewportRestore ? pendingViewportAnchor : viewportAnchor()
        let oldOffset = hasPendingViewportRestore ? pendingViewportOrigin ?? 0
            : collectionView.enclosingScrollView?.contentView.bounds.minY ?? 0
        preparedWidth = width; needsRebuild = false; generation += 1; layoutGeneration += 1
        let token = generation
        if fullRebuild {
            geometries = sections.indices.map { makeGeometry(section: $0, width: width) }
            pathByID = [:]
            for (sectionIndex, section) in sections.enumerated() {
                for (itemIndex, item) in section.items.enumerated() {
                    pathByID[item.id] = IndexPath(item: itemIndex, section: sectionIndex)
                }
            }
            lastRebuiltSectionCount = sections.count
        } else {
            let dirty = dirtySections.filter { sections.indices.contains($0) }
            for index in dirty { geometries[index] = makeGeometry(section: index, width: width) }
            lastRebuiltSectionCount = dirty.count
        }
        dirtySections.removeAll(keepingCapacity: true)
        // Item frames remain relative to their date group. A changed group's
        // height only changes these small per-group offsets, not every later item.
        sectionOffsets = []; headers = []
        sectionOffsets.reserveCapacity(sections.count); headers.reserveCapacity(sections.count)
        var origin: CGFloat = 0
        for (index, geometry) in geometries.enumerated() {
            sectionOffsets.append(origin)
            let header = NSCollectionViewLayoutAttributes(forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                                         with: IndexPath(item: 0, section: index))
            header.frame = geometry.header.offsetBy(dx: 0, dy: origin)
            headers.append(header)
            origin += geometry.height - 20
        }
        height = geometries.isEmpty ? 0 : origin + 20
        dateSpans = headers.enumerated().map { index, header in
            let end = headers.indices.contains(index + 1) ? headers[index + 1].frame.minY : height
            return TimelineDateSpan(id: sections[index].id, start: Double(header.frame.minY),
                                    length: Double(max(1, end - header.frame.minY)))
        }
        pendingViewportAnchor = anchor
        pendingViewportOrigin = oldOffset
        hasPendingViewportRestore = true
        DispatchQueue.main.async { [weak self, weak collectionView] in
            guard let self, self.generation == token, let collectionView,
                  let scroll = collectionView.enclosingScrollView else { return }
            self.hasPendingViewportRestore = false
            self.pendingViewportAnchor = nil
            self.pendingViewportOrigin = nil
            let clip = scroll.contentView
            let desired: CGFloat
            if let anchor, let frame = self.frame(for: anchor.id) {
                desired = frame.midY + anchor.offset - clip.bounds.height / 2
            } else { desired = oldOffset }
            let y = max(0, min(desired, max(0, self.height - clip.bounds.height)))
            if abs(clip.bounds.minY - y) > 0.5 || abs(clip.bounds.minX) > 0.5 {
                clip.scroll(to: NSPoint(x: 0, y: y))
            }
            scroll.reflectScrolledClipView(clip)
        }
    }
    private func makeGeometry(section index: Int, width: CGFloat) -> SectionGeometry {
        let layout = JustifiedTimelineLayout.make(sections: [sections[index]], width: Double(width), targetHeight: targetHeight)
        guard let section = layout.sections.first else { return SectionGeometry(header: .zero, attributes: [], rows: [], rowByItem: [], height: 0) }
        let captionHeight: CGFloat = showNames ? 24 : 0
        var attributes: [NSCollectionViewLayoutAttributes] = [], rows: [Row] = [], rowByItem: [Int] = []
        attributes.reserveCapacity(section.items.count); rowByItem.reserveCapacity(section.items.count)
        var previousY: CGFloat?
        for (itemIndex, item) in section.items.enumerated() {
            if previousY == nil || abs(item.frame.minY - previousY!) > 0.5 {
                previousY = item.frame.minY
                rows.append(Row(rect: .null, attributes: []))
            }
            let rowIndex = rows.count - 1
            let value = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: itemIndex, section: index))
            var rect = item.frame.offsetBy(dx: 0, dy: CGFloat(rowIndex) * captionHeight)
            rect.size.height += captionHeight; value.frame = rect
            attributes.append(value); rowByItem.append(rowIndex)
            rows[rowIndex].rect = rows[rowIndex].rect.union(rect)
            rows[rowIndex].attributes.append(value)
        }
        return SectionGeometry(header: section.headerFrame, attributes: attributes, rows: rows, rowByItem: rowByItem,
                               height: CGFloat(layout.contentHeight) + CGFloat(rows.count) * captionHeight)
    }
    override var collectionViewContentSize: NSSize { NSSize(width: max(0, preparedWidth), height: height) }
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { abs(newBounds.width - preparedWidth) > 0.5 }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard geometries.indices.contains(indexPath.section), sectionOffsets.indices.contains(indexPath.section),
              geometries[indexPath.section].attributes.indices.contains(indexPath.item) else { return nil }
        return translated(geometries[indexPath.section].attributes[indexPath.item], offset: sectionOffsets[indexPath.section])
    }
    override func layoutAttributesForSupplementaryView(ofKind elementKind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard elementKind == NSCollectionView.elementKindSectionHeader, headers.indices.contains(indexPath.section) else { return nil }
        return headers[indexPath.section]
    }
    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        var result: [NSCollectionViewLayoutAttributes] = []
        var low = 0, high = geometries.count
        while low < high {
            let middle = (low + high) / 2
            if sectionOffsets[middle] + geometries[middle].height < rect.minY { low = middle + 1 } else { high = middle }
        }
        for sectionIndex in low..<geometries.count {
            let offset = sectionOffsets[sectionIndex], geometry = geometries[sectionIndex]
            if offset + geometry.header.minY > rect.maxY { break }
            if headers[sectionIndex].frame.intersects(rect) { result.append(headers[sectionIndex]) }
            let local = rect.offsetBy(dx: 0, dy: -offset)
            var rowLow = 0, rowHigh = geometry.rows.count
            while rowLow < rowHigh {
                let middle = (rowLow + rowHigh) / 2
                if geometry.rows[middle].rect.maxY < local.minY { rowLow = middle + 1 } else { rowHigh = middle }
            }
            for row in geometry.rows.dropFirst(rowLow) {
                if row.rect.minY > local.maxY { break }
                for value in row.attributes where value.frame.intersects(local) { result.append(translated(value, offset: offset)) }
            }
        }
        return result
    }
    private func translated(_ value: NSCollectionViewLayoutAttributes, offset: CGFloat) -> NSCollectionViewLayoutAttributes {
        let result = value.copy() as! NSCollectionViewLayoutAttributes
        result.frame = value.frame.offsetBy(dx: 0, dy: offset)
        return result
    }
    func sectionID(at y: CGFloat) -> String? {
        guard !headers.isEmpty else { return nil }
        var low = 0, high = headers.count
        while low < high {
            let middle = (low + high) / 2
            if headers[middle].frame.minY <= y { low = middle + 1 } else { high = middle }
        }
        return sections[max(0, low - 1)].id
    }
    func frame(for id: String) -> CGRect? { pathByID[id].flatMap { layoutAttributesForItem(at: $0)?.frame } }
    func cancelPendingViewportRestore() {
        generation += 1; hasPendingViewportRestore = false
        pendingViewportAnchor = nil; pendingViewportOrigin = nil
    }
    func firstVisibleItem(at y: CGFloat, viewport: CGRect) -> (path: IndexPath, fraction: Double)? {
        let probe = CGRect(x: viewport.minX, y: y, width: viewport.width, height: max(1, viewport.maxY - y))
        var candidates = layoutAttributesForElements(in: probe).filter { $0.representedElementCategory == .item }
        if candidates.isEmpty { candidates = layoutAttributesForElements(in: viewport).filter { $0.representedElementCategory == .item } }
        guard let first = candidates.min(by: {
            abs($0.frame.minY - $1.frame.minY) > 0.5 ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX
        }), let path = first.indexPath else { return nil }
        return (path, Double(min(1, max(0, (y - first.frame.minY) / max(1, first.frame.height)))))
    }
    func verticalNeighbor(from path: IndexPath, downward: Bool) -> IndexPath? {
        guard geometries.indices.contains(path.section), let current = layoutAttributesForItem(at: path),
              geometries[path.section].rowByItem.indices.contains(path.item) else { return nil }
        var sectionIndex = path.section
        var rowIndex = geometries[sectionIndex].rowByItem[path.item] + (downward ? 1 : -1)
        while !geometries[sectionIndex].rows.indices.contains(rowIndex) {
            sectionIndex += downward ? 1 : -1
            guard geometries.indices.contains(sectionIndex) else { return nil }
            rowIndex = downward ? 0 : geometries[sectionIndex].rows.count - 1
        }
        let x = current.frame.midX
        return geometries[sectionIndex].rows[rowIndex].attributes.min {
            let firstEdge = max(0, max($0.frame.minX - x, x - $0.frame.maxX))
            let secondEdge = max(0, max($1.frame.minX - x, x - $1.frame.maxX))
            return firstEdge * 2 + abs($0.frame.midX - x) * 0.12 < secondEdge * 2 + abs($1.frame.midX - x) * 0.12
        }?.indexPath
    }
    private func viewportAnchor() -> ViewportAnchor? {
        guard let clip = collectionView?.enclosingScrollView?.contentView, !geometries.isEmpty else { return nil }
        let center = CGPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        if let id = preferredViewportAnchorID, let frame = frame(for: id), frame.intersects(clip.bounds) {
            return ViewportAnchor(id: id, offset: center.y - frame.midY)
        }
        let candidates = layoutAttributesForElements(in: clip.bounds).filter { $0.representedElementCategory == .item }
        let nearest = candidates.min {
            hypot($0.frame.midX - center.x, $0.frame.midY - center.y) < hypot($1.frame.midX - center.x, $1.frame.midY - center.y)
        }
        guard let nearest, let path = nearest.indexPath,
              sections.indices.contains(path.section), sections[path.section].items.indices.contains(path.item) else { return nil }
        return ViewportAnchor(id: sections[path.section].items[path.item].id, offset: center.y - nearest.frame.midY)
    }
}

@MainActor final class PhotoCollectionView: NSCollectionView {
    weak var store: AppStore?
    weak var mediaCoordinator: MediaGrid.Coordinator?
    var mediaByPath: [IndexPath: MediaItem] { mediaCoordinator?.mediaByPath ?? [:] }
    var visualOrder: [IndexPath] = []
    var synchronizeSelection: (() -> Void)?
    private var pendingScrollTarget: (id: String, fraction: Double)?
    private var pendingScrollOrigin: Double?
    var hasPendingScroll: Bool { pendingScrollTarget != nil || pendingScrollOrigin != nil }
    private struct CompletedPhotoClick {
        let id: String
        let locationInWindow: NSPoint
        let timestamp: TimeInterval
        let selectionMode: Bool
        let selectionModeRevision: Int
        let visibleRevision: Int
    }
    private var completedPhotoClick: CompletedPhotoClick?
    private struct PhotoPress {
        let media: MediaItem?
        let point: NSPoint
        let downEvent: NSEvent
        let selectedItems: [MediaItem]
        let initialSelectedIDs: Set<String>
        let toggleOnClick: Bool
        let openOnClick: Bool
        let selectionMode: Bool
        let selectionModeRevision: Int
        let visibleRevision: Int
        let dragsReferences: Bool
    }
    private var photoPress: PhotoPress?
    private var selectionStroke: MediaSelectionStroke?
    private var autoScrollPointerInWindow: NSPoint?
    private var selectionAutoScrollTimer: Timer?
    private let referenceDragSource = PhotoReferenceDragSource()
    var isSelectionStrokeActive: Bool { selectionStroke != nil }
    var isSelectionAutoscrolling: Bool { selectionAutoScrollTimer != nil }
    var isReferenceDragPending: Bool { photoPress?.dragsReferences == true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            cancelSelectionGesture()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                                                   name: NSWindow.didResignKeyNotification, object: window)
        }
    }
    @objc private func windowResignedKey() {
        cancelSelectionGesture()
    }

    func cancelInvalidSelectionGesture() {
        if let click = completedPhotoClick,
           store?.isSelectionMode != click.selectionMode
            || store?.selectionModeRevision != click.selectionModeRevision
            || store?.visibleRevision != click.visibleRevision {
            clearCompletedClick()
        }
        guard let press = photoPress else { return }
        guard let store, press.selectionMode == store.isSelectionMode,
              press.selectionModeRevision == store.selectionModeRevision,
              press.visibleRevision == store.visibleRevision else {
            cancelSelectionGesture()
            return
        }
    }
    private func clearCompletedClick() {
        completedPhotoClick = nil
        if let store { MediaDoubleClickTracker.shared.cancel(store: store) }
    }
    func cancelSelectionGesture(keepingCompletedClick: Bool = false) {
        photoPress = nil
        selectionStroke = nil
        autoScrollPointerInWindow = nil
        stopSelectionAutoScroll()
        if !keepingCompletedClick { clearCompletedClick() }
    }
    override func layout() {
        super.layout()
        if hasPendingScroll {
            DispatchQueue.main.async { [weak self] in self?.performPendingScroll() }
        }
    }
    func requestScrollToPhoto(_ id: String, fraction: Double = 0) {
        pendingScrollOrigin = nil
        pendingScrollTarget = (id, min(1, max(0, fraction.isFinite ? fraction : 0)))
        DispatchQueue.main.async { [weak self] in self?.performPendingScroll() }
    }
    func requestScroll(to origin: Double) {
        guard origin.isFinite else { return }
        pendingScrollTarget = nil
        pendingScrollOrigin = origin
        DispatchQueue.main.async { [weak self] in self?.performPendingScroll() }
    }
    private func performPendingScroll() {
        guard hasPendingScroll, let scroll = enclosingScrollView,
              scroll.contentView.bounds.width > 1, scroll.contentView.bounds.height > 1,
              let layout = collectionViewLayout as? TemporalCollectionLayout else { return }
        layout.prepare()
        let target = pendingScrollTarget, origin = pendingScrollOrigin
        pendingScrollTarget = nil
        pendingScrollOrigin = nil
        if let target, layout.frame(for: target.id) != nil {
            scrollToPhoto(target.id, alignTop: true, fraction: target.fraction)
            scroll.reflectScrolledClipView(scroll.contentView)
        } else if let origin {
            layout.cancelPendingViewportRestore()
            let clip = scroll.contentView
            let maximum = max(0, layout.collectionViewContentSize.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, origin))))
            scroll.reflectScrolledClipView(clip)
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        cancelSelectionGesture(keepingCompletedClick: true)
        cancelInvalidSelectionGesture()
        guard let store else { return }
        let selectionMode = store.isSelectionMode
        if event.clickCount == 2 {
            defer { clearCompletedClick() }
            // The first click can reveal the inspector and reflow the grid.
            // Resolve the second click against the original window position,
            // never the different photo that may now occupy that position.
            guard let click = completedPhotoClick,
                  event.timestamp >= click.timestamp,
                  event.timestamp - click.timestamp <= NSEvent.doubleClickInterval,
                  hypot(event.locationInWindow.x - click.locationInWindow.x,
                        event.locationInWindow.y - click.locationInWindow.y) <= 4,
                  let media = store.visibleItems.first(where: { $0.id == click.id }) else { return }
            photoPress = PhotoPress(media: media, point: point, downEvent: event,
                                    selectedItems: [], initialSelectedIDs: store.selectedIDs,
                                    toggleOnClick: false, openOnClick: true, selectionMode: selectionMode,
                                    selectionModeRevision: store.selectionModeRevision,
                                    visibleRevision: store.visibleRevision, dragsReferences: false)
            return
        }
        clearCompletedClick()
        guard event.clickCount <= 1 else { return }
        let media = indexPathForItem(at: point).flatMap { mediaByPath[$0] }
        guard selectionMode || media != nil else {
            store.clearSelection()
            synchronizeSelection?()
            return
        }
        let initialSelection = store.selectedIDs
        let modifiesSelection = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift)
        let wasSelected = media.map { store.selectedIDs.contains($0.id) } ?? false
        if let media {
            if !selectionMode {
                store.activate(media)
            } else {
                store.focus(media)
            }
            if selectionMode, modifiesSelection || !wasSelected {
                store.activate(media, modifiers: event.modifierFlags)
            }
        }
        synchronizeSelection?()
        let selected = selectionMode ? store.selectedItems : media.map { [$0] } ?? []
        // A simple click still toggles on mouse-up. A selection stroke keeps
        // its starting photo selected, and Option preserves reference dragging.
        photoPress = PhotoPress(media: media, point: point, downEvent: event,
                                selectedItems: selected, initialSelectedIDs: initialSelection,
                                toggleOnClick: selectionMode && wasSelected && !modifiesSelection,
                                openOnClick: false, selectionMode: selectionMode,
                                selectionModeRevision: store.selectionModeRevision,
                                visibleRevision: store.visibleRevision,
                                dragsReferences: media != nil && (!selectionMode || event.modifierFlags.contains(.option)))
        GridDragDiagnostics.note("down selected=\(selected.count) stroke=\(selectionMode && !event.modifierFlags.contains(.option))")
    }
    override func mouseDragged(with event: NSEvent) {
        cancelInvalidSelectionGesture()
        guard let press = photoPress, pointerIsInsideWindow(event.locationInWindow) else {
            cancelSelectionGesture()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard selectionStroke != nil || distanceFromPress(event, press: press) >= 4 else { return }
        clearCompletedClick()
        if press.openOnClick { cancelSelectionGesture(); return }
        if press.selectionMode && !press.dragsReferences {
            if selectionStroke == nil {
                // Modifier clicks can change the start item on mouse-down;
                // crossing it with a stroke always adds instead of removing.
                store?.selectedIDs = press.initialSelectedIDs
                selectionStroke = MediaSelectionStroke(at: press.point)
            }
            autoScrollPointerInWindow = event.locationInWindow
            extendSelectionStroke(to: point)
            updateSelectionAutoScroll()
            return
        }
        guard let pressedMedia = press.media,
              press.selectedItems.contains(where: { $0.id == pressedMedia.id }) else { return }
        cancelSelectionGesture()
        let media = [pressedMedia] + press.selectedItems.filter { $0.id != pressedMedia.id }
        let draggingItems = referenceDraggingItems(for: media, fallbackPoint: press.point)
        guard !draggingItems.isEmpty else { return }
        GridDragDiagnostics.note("begin items=\(draggingItems.count) model=\(store?.selectedIDs.count ?? 0)")
        let session = beginDraggingSession(with: draggingItems, event: press.downEvent, source: referenceDragSource)
        session.draggingFormation = .stack
        session.draggingLeaderIndex = 0
        session.animatesToStartingPositionsOnCancelOrFail = true
        GridDragDiagnostics.note("pasteboard items=\(session.draggingPasteboard.pasteboardItems?.count ?? 0) fileURL=\(session.draggingPasteboard.types?.contains(.fileURL) == true)")
    }
    override func mouseUp(with event: NSEvent) {
        cancelInvalidSelectionGesture()
        guard let press = photoPress else { cancelSelectionGesture(); return }
        if selectionStroke == nil, press.selectionMode, !press.dragsReferences,
           pointerIsInsideWindow(event.locationInWindow),
           distanceFromPress(event, press: press) >= 4 {
            store?.selectedIDs = press.initialSelectedIDs
            selectionStroke = MediaSelectionStroke(at: press.point)
        }
        if selectionStroke != nil {
            if pointerIsInsideWindow(event.locationInWindow) {
                extendSelectionStroke(to: convert(event.locationInWindow, from: nil))
            }
            cancelSelectionGesture()
            return
        }
        cancelSelectionGesture()
        guard let store, let media = press.media,
              store.isSelectionMode == press.selectionMode,
              pointerIsInsideWindow(event.locationInWindow),
              distanceFromPress(event, press: press) < 4 else { return }
        if press.toggleOnClick {
            store.activate(media)
            synchronizeSelection?()
        }
        if press.openOnClick {
            store.open(media)
        } else {
            completedPhotoClick = CompletedPhotoClick(id: media.id,
                                                     locationInWindow: press.downEvent.locationInWindow,
                                                     timestamp: press.downEvent.timestamp,
                                                     selectionMode: press.selectionMode,
                                                     selectionModeRevision: press.selectionModeRevision,
                                                     visibleRevision: press.visibleRevision)
            MediaDoubleClickTracker.shared.record(item: media, store: store, event: press.downEvent)
        }
        GridDragDiagnostics.note("click selected=\(store.selectedIDs.count)")
    }
    private func distanceFromPress(_ event: NSEvent, press: PhotoPress) -> CGFloat {
        hypot(event.locationInWindow.x - press.downEvent.locationInWindow.x,
              event.locationInWindow.y - press.downEvent.locationInWindow.y)
    }
    private func pointerIsInsideWindow(_ point: NSPoint) -> Bool {
        guard let window, let contentView = window.contentView else { return false }
        return contentView.bounds.contains(contentView.convert(point, from: nil))
    }
    private func extendSelectionStroke(to rawPoint: NSPoint) {
        guard var stroke = selectionStroke, let store, store.isSelectionMode,
              let layout = collectionViewLayout else { return }
        let viewport = visibleRect
        guard viewport.width > 0, viewport.height > 0 else { return }
        let point = CGPoint(x: min(viewport.maxX, max(viewport.minX, rawPoint.x)),
                            y: min(viewport.maxY, max(viewport.minY, rawPoint.y)))
        let candidates = layout.layoutAttributesForElements(in: stroke.searchRect(to: point)).compactMap { attributes -> (id: String, frame: CGRect)? in
            guard attributes.representedElementCategory == .item, let path = attributes.indexPath,
                  let media = mediaByPath[path] else { return nil }
            return (media.id, attributes.frame)
        }
        let added = stroke.advance(to: point, candidates: candidates)
        selectionStroke = stroke
        if !added.isEmpty { store.selectedIDs.formUnion(added) }
        if viewport.contains(rawPoint), let path = indexPathForItem(at: rawPoint), let media = mediaByPath[path] {
            store.focus(media)
        }
        synchronizeSelection?()
    }
    private func selectionScrollDelta() -> CGFloat {
        guard let pointer = autoScrollPointerInWindow else { return 0 }
        let point = convert(pointer, from: nil), viewport = visibleRect
        guard viewport.width > 0, viewport.height > 0,
              point.x >= viewport.minX, point.x <= viewport.maxX,
              point.y >= viewport.minY - 24, point.y <= viewport.maxY + 24 else { return 0 }
        let edge: CGFloat = min(48, viewport.height / 3)
        if point.y < viewport.minY + edge {
            return -18 * min(1, max(0, (viewport.minY + edge - point.y) / edge))
        }
        if point.y > viewport.maxY - edge {
            return 18 * min(1, max(0, (point.y - viewport.maxY + edge) / edge))
        }
        return 0
    }
    private func updateSelectionAutoScroll() {
        guard selectionStroke != nil, selectionScrollDelta() != 0 else { stopSelectionAutoScroll(); return }
        guard selectionAutoScrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { _ = self.advanceSelectionAutoscrollFrame() }
        }
        selectionAutoScrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func stopSelectionAutoScroll() {
        selectionAutoScrollTimer?.invalidate()
        selectionAutoScrollTimer = nil
    }
    @discardableResult func advanceSelectionAutoscrollFrame() -> Bool {
        cancelInvalidSelectionGesture()
        guard selectionStroke != nil, let pointer = autoScrollPointerInWindow,
              pointerIsInsideWindow(pointer), let scroll = enclosingScrollView else {
            cancelSelectionGesture()
            return false
        }
        let delta = selectionScrollDelta(), clip = scroll.contentView
        let maximum = max(0, collectionViewLayout?.collectionViewContentSize.height ?? bounds.height) - clip.bounds.height
        let nextY = min(max(0, maximum), max(0, clip.bounds.minY + delta))
        guard delta != 0, abs(nextY - clip.bounds.minY) > 0.01 else { stopSelectionAutoScroll(); return false }
        (collectionViewLayout as? TemporalCollectionLayout)?.cancelPendingViewportRestore()
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: nextY))
        scroll.reflectScrolledClipView(clip)
        extendSelectionStroke(to: convert(pointer, from: nil))
        return true
    }
    private func referenceDraggingItems(for items: [MediaItem], fallbackPoint: NSPoint) -> [NSDraggingItem] {
        guard items.allSatisfy(\.isLocal) else {
            store?.notify("云端文件请使用「复制」")
            return []
        }
        let pathByID = Dictionary(mediaByPath.map { ($0.value.id, $0.key) }, uniquingKeysWith: { first, _ in first })
        return items.enumerated().map { index, media in
            let draggingItem = NSDraggingItem(pasteboardWriter: media.url as NSURL)
            let path = pathByID[media.id]
            let frame = path.flatMap { collectionViewLayout?.layoutAttributesForItem(at: $0)?.frame }
                ?? NSRect(x: fallbackPoint.x - 32, y: fallbackPoint.y - 24, width: 64, height: 48)
            draggingItem.draggingFrame = frame
            // Drag all references, but render only a handful of already visible
            // previews. Selecting an entire library must not decode it for a drag.
            if index < 4 {
                let components: [NSDraggingImageComponent]
                if let path, let cell = item(at: path) as? PhotoCollectionItem {
                    components = cell.draggingImageComponents
                } else {
                    let icon = NSDraggingImageComponent(key: .icon)
                    icon.contents = NSImage(systemSymbolName: media.kind == .video ? "play.rectangle.fill" : "photo.fill", accessibilityDescription: nil)
                    icon.frame = NSRect(x: 0, y: 0, width: min(64, frame.width), height: min(48, frame.height))
                    components = [icon]
                }
                draggingItem.imageComponentsProvider = { components }
            }
            return draggingItem
        }
    }
    override func magnify(with event: NSEvent) {
        clearCompletedClick()
        guard let store else { return }
        store.thumbnailSize = min(280, max(64, store.thumbnailSize * exp(Double(event.magnification))))
    }
    override func scrollWheel(with event: NSEvent) {
        clearCompletedClick()
        if event.modifierFlags.contains(.command) { store?.zoomTimeline(with: event); return }
        (collectionViewLayout as? TemporalCollectionLayout)?.cancelPendingViewportRestore()
        super.scrollWheel(with: event)
    }
    override func keyDown(with event: NSEvent) {
        clearCompletedClick()
        if event.keyCode == 49 {
            guard let store else { return }
            if store.isSelectionMode {
                if let media = store.keyboardCursor.flatMap({ id in mediaByPath.values.first { $0.id == id } })
                    ?? store.visibleItems.first {
                    store.activate(media)
                    synchronizeSelection?()
                }
            } else { store.open() }
            return
        }
        if event.keyCode == 36 { store?.open(); return }
        if event.keyCode == 53 {
            cancelSelectionGesture()
            if store?.isSelectionMode == true { store?.setSelectionMode(false) }
            else { store?.clearSelection() }
            synchronizeSelection?()
            return
        }
        if event.keyCode == 51, !event.modifierFlags.contains(.command), let store, case .album(let id) = store.scope {
            store.removeFromAlbum(store.selectedIDs, albumID: id); synchronizeSelection?(); return
        }
        if [123, 124, 125, 126].contains(event.keyCode), !event.modifierFlags.contains(.command) {
            moveCursor(keyCode: event.keyCode, extend: event.modifierFlags.contains(.shift)); return
        }
        super.keyDown(with: event)
    }
    private func moveCursor(keyCode: UInt16, extend: Bool) {
        guard let store, !visualOrder.isEmpty, let layout = collectionViewLayout as? TemporalCollectionLayout else { return }
        let cursor = store.keyboardCursor ?? store.selectionAnchor
        let currentIndex = visualOrder.firstIndex { mediaByPath[$0]?.id == cursor }
        let target: IndexPath
        if let currentIndex {
            let currentPath = visualOrder[currentIndex]
            if keyCode == 125 || keyCode == 126 { target = layout.verticalNeighbor(from: currentPath, downward: keyCode == 125) ?? currentPath }
            else {
                let index = min(visualOrder.count - 1, max(0, currentIndex + (keyCode == 123 ? -1 : 1)))
                target = visualOrder[index]
            }
        } else { target = (keyCode == 123 || keyCode == 126) ? visualOrder.last! : visualOrder[0] }
        guard let media = mediaByPath[target] else { return }
        if store.isSelectionMode && extend { store.select(media, modifiers: [.shift]) }
        else { store.focus(media) }
        synchronizeSelection?(); scrollToPhoto(media.id)
    }
    func scrollToPhoto(_ id: String, alignTop: Bool = false, fraction: Double = 0) {
        guard let layout = collectionViewLayout as? TemporalCollectionLayout,
              let frame = layout.frame(for: id), let scroll = enclosingScrollView else { return }
        layout.cancelPendingViewportRestore()
        let clip = scroll.contentView
        let current = clip.bounds
        let desired: CGFloat
        if alignTop { desired = max(0, frame.minY + frame.height * fraction - 44) }
        else if frame.minY < current.minY { desired = frame.minY - 16 }
        else if frame.maxY > current.maxY { desired = frame.maxY - current.height + 16 }
        else { return }
        let y = min(max(0, desired), max(0, layout.collectionViewContentSize.height - current.height))
        guard abs(current.minY - y) > 0.5 || abs(current.minX) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
    }
    override func selectAll(_ sender: Any?) { store?.selectAll(); synchronizeSelection?() }
    @objc func copy(_ sender: Any?) { store?.copySelectedFiles() }
    override func menu(for event: NSEvent) -> NSMenu? {
        clearCompletedClick()
        guard let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)), let media = mediaByPath[path] else { return nil }
        guard let store else { return nil }
        store.focus(media)
        let targets = store.isSelectionMode && store.selectedIDs.contains(media.id) ? store.selectedItems : [media]
        return MediaMenus.make(store: store, items: targets)
    }
}

@MainActor private final class PhotoReferenceDragSource: NSObject, NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        GridDragDiagnostics.note("source-will-begin")
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        GridDragDiagnostics.note("source-ended operation=\(operation.rawValue)")
    }
}

private enum GridDragDiagnostics {
    @MainActor static func note(_ message: String) {
        #if DEBUG
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/DragDiagnostics", isDirectory: true)
        let file = directory.appendingPathComponent("events.log")
        guard let data = "\(Date().timeIntervalSince1970) \(message)\n".data(using: .utf8) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch { }
        #endif
    }
}

@MainActor final class ActionMenuItem: NSMenuItem {
    var handler: (@MainActor () -> Void)?
    @objc func invoke() { handler?() }
}

@MainActor private final class TimelineHeaderView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.textColor = .labelColor
        countField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        countField.textColor = .tertiaryLabelColor
        for field in [titleField, countField] { field.translatesAutoresizingMaskIntoConstraints = false; addSubview(field) }
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            countField.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 10),
            countField.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
            countField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(title: String, count: Int) {
        titleField.stringValue = title; countField.stringValue = "\(count.formatted()) 项"
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(title)，\(count) 个项目")
    }
}

@MainActor private final class AccessiblePhotoView: NSView {
    var onPress: (() -> Bool)?
    var onOpen: (() -> Bool)?
    var onSelect: (() -> Bool)?
    var onToggleSelection: (() -> Bool)?
    weak var previewControls: GridVideoPreviewControls?
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let controls = previewControls, !controls.isHidden,
           controls.frame.contains(convert(point, from: superview)) {
            return controls.hitTest(convert(point, from: superview))
        }
        // The hosted SwiftUI cell is display-only. Let its native item container
        // route mouse tracking to NSCollectionView instead of swallowing a drag.
        return super.hitTest(point) == nil ? nil : self
    }
    private var photoCollection: PhotoCollectionView? {
        var ancestor = superview
        while let view = ancestor {
            if let collection = view as? PhotoCollectionView { return collection }
            ancestor = view.superview
        }
        return nil
    }
    override func mouseDown(with event: NSEvent) {
        if let photoCollection { photoCollection.mouseDown(with: event) } else { super.mouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        if let photoCollection { photoCollection.mouseDragged(with: event) } else { super.mouseDragged(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        if let photoCollection { photoCollection.mouseUp(with: event) } else { super.mouseUp(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { onPress?() ?? false }
    override func accessibilityPerformPick() -> Bool { onSelect?() ?? false }
    @objc func selectPhoto() -> Bool { onSelect?() ?? false }
    @objc func openPhoto() -> Bool { onOpen?() ?? false }
    @objc func togglePhotoSelection() -> Bool { onToggleSelection?() ?? false }
}

@MainActor final class PhotoCollectionItem: NSCollectionViewItem {
    var media: MediaItem?
    private var hosting: NSHostingView<PhotoCell>?
    private var favorite = false
    private var showNames = false
    private var selectionMode = false
    private weak var store: AppStore?
    private weak var previewSession: GridVideoPreviewSession?
    private var previewControls: GridVideoPreviewControls?
    private var controlsBottomConstraint: NSLayoutConstraint?
    private struct PreviewPresentation: Equatable {
        let session: ObjectIdentifier
        let store: ObjectIdentifier?
        let mediaID: String?
        let active: Bool
        let showNames: Bool
    }
    private var previewPresentation: PreviewPresentation?
    private var selectionDidChange: (() -> Void)?
    override var isSelected: Bool { didSet { render() } }
    override var draggingImageComponents: [NSDraggingImageComponent] {
        guard media != nil else { return [] }
        let component = NSDraggingImageComponent(key: .icon)
        let bounds = view.bounds
        if bounds.width > 0, bounds.height > 0,
           let representation = view.bitmapImageRepForCachingDisplay(in: bounds) {
            view.cacheDisplay(in: bounds, to: representation)
            let image = NSImage(size: bounds.size)
            image.addRepresentation(representation)
            component.contents = image
            component.frame = NSRect(origin: .zero, size: bounds.size)
        } else {
            component.contents = NSImage(systemSymbolName: media?.kind == .video ? "play.rectangle.fill" : "photo.fill", accessibilityDescription: nil)
            component.frame = NSRect(x: 0, y: 0, width: 48, height: 48)
        }
        return [component]
    }
    override func loadView() {
        let accessibleView = AccessiblePhotoView()
        accessibleView.wantsLayer = true
        accessibleView.focusRingType = .none
        accessibleView.onPress = { [weak self] in self?.performAccessibleSelection(toggle: true) ?? false }
        accessibleView.onOpen = { [weak self] in self?.performAccessibleActivation() ?? false }
        accessibleView.onSelect = { [weak self] in self?.performAccessibleSelection() ?? false }
        accessibleView.onToggleSelection = { [weak self] in self?.performAccessibleSelection(toggle: true) ?? false }
        accessibleView.setAccessibilityChildren([])
        view = accessibleView
    }
    func configure(_ item: MediaItem, favorite: Bool, showNames: Bool, store: AppStore, selectionDidChange: @escaping () -> Void) {
        media = item; self.favorite = favorite; self.showNames = showNames
        self.store = store; self.selectionDidChange = selectionDidChange
        selectionMode = store.isSelectionMode
        render()
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel("\(item.name)，\(item.kind == .image ? "照片" : "视频")")
        view.setAccessibilityRole(.button)
    }
    private func performAccessibleActivation() -> Bool {
        guard let media, let store, store.visibleItems.contains(where: { $0.id == media.id }) else { return false }
        store.open(media)
        selectionDidChange?()
        return true
    }
    private func performAccessibleSelection(toggle: Bool = false) -> Bool {
        guard let media, let store,
              store.visibleItems.contains(where: { $0.id == media.id }) else { return false }
        if !store.isSelectionMode || toggle {
            store.activate(media)
        } else if !store.selectedIDs.contains(media.id) {
            store.select(media, modifiers: [.command])
        } else { store.focus(media) }
        store.showInspector = true
        selectionDidChange?()
        return true
    }
    func updatePresentation(favorite: Bool, selectionMode: Bool) {
        guard self.favorite != favorite || self.selectionMode != selectionMode else { return }
        self.favorite = favorite; self.selectionMode = selectionMode
        render()
    }
    func updateFavorite(_ value: Bool) { if value != favorite { favorite = value; render() } }
    func updatePreview(session: GridVideoPreviewSession) {
        let active = media?.kind == .video && session.playback.currentID == media?.id
        let next = PreviewPresentation(session: ObjectIdentifier(session), store: store.map(ObjectIdentifier.init),
                                       mediaID: media?.id, active: active, showNames: showNames)
        guard previewPresentation != next else { return }
        let wasActive = previewPresentation?.active == true
        previewPresentation = next
        if previewSession !== session { previewSession = session; render() }
        // Most cells remain posters. Leave their hosting view and AX children
        // alone during scroll/SwiftUI refreshes instead of invalidating layout.
        guard active || wasActive else { return }
        if active, previewControls == nil {
            let controls = GridVideoPreviewControls()
            controls.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(controls)
            let bottom = controls.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: showNames ? -32 : -8)
            let width = controls.widthAnchor.constraint(equalToConstant: 62)
            width.priority = .defaultHigh
            NSLayoutConstraint.activate([
                controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8), bottom,
                controls.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 4),
                controls.heightAnchor.constraint(equalToConstant: 28),
                width
            ])
            previewControls = controls; controlsBottomConstraint = bottom
            (view as? AccessiblePhotoView)?.previewControls = controls
        }
        previewControls?.isHidden = !active
        previewControls?.configure(session: active ? session : nil, store: active ? store : nil)
        controlsBottomConstraint?.constant = showNames ? -32 : -8
        view.setAccessibilityChildren(active ? previewControls.map { [$0] } ?? [] : [])
    }
    private func render() {
        guard let media else { return }
        let selected = isSelected
        let content = PhotoCell(item: media, selected: selected, favorite: favorite, showNames: showNames,
                                selectionMode: selectionMode, previewSession: previewSession)
        if let hosting { hosting.rootView = content }
        else {
            let hosting = NSHostingView(rootView: content)
            hosting.focusRingType = .none
            hosting.sizingOptions = []
            hosting.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hosting)
            NSLayoutConstraint.activate([hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor), hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor), hosting.topAnchor.constraint(equalTo: view.topAnchor), hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
            self.hosting = hosting
        }
        view.setAccessibilitySelected(selected)
        view.setAccessibilityValue(selected ? "已选择" : "未选择")
        view.setAccessibilityHelp(selectionMode ? "按下以选择或取消选择，双击以打开。" : "按下以选择并查看信息，双击以打开。")
        if let accessibleView = view as? AccessiblePhotoView {
            var actions = [NSAccessibilityCustomAction(name: "打开", target: accessibleView, selector: #selector(AccessiblePhotoView.openPhoto))]
            if selectionMode { actions.append(contentsOf: [
                NSAccessibilityCustomAction(name: "选择", target: accessibleView, selector: #selector(AccessiblePhotoView.selectPhoto)),
                NSAccessibilityCustomAction(name: selected ? "从多选中移除" : "加入多选", target: accessibleView, selector: #selector(AccessiblePhotoView.togglePhotoSelection))
            ]) }
            accessibleView.setAccessibilityCustomActions(actions)
        }
    }
    func releaseImage() {
        hosting?.removeFromSuperview()
        hosting = nil
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        media = nil; store = nil; selectionDidChange = nil; selectionMode = false
        releaseImage()
        previewControls?.configure(session: nil, store: nil)
        previewControls?.removeFromSuperview(); previewControls = nil; controlsBottomConstraint = nil
        previewSession = nil
        previewPresentation = nil
        (view as? AccessiblePhotoView)?.previewControls = nil
        view.setAccessibilityChildren([])
        view.setAccessibilityValue(nil)
        view.setAccessibilitySelected(false)
        view.setAccessibilityCustomActions([])
    }
}

private let gridThumbnailPixelSize = 768

private struct PhotoCell: View {
    let item: MediaItem
    let selected: Bool
    let favorite: Bool
    let showNames: Bool
    let selectionMode: Bool
    let previewSession: GridVideoPreviewSession?
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                AsyncThumbnail(item: item, pixelSize: gridThumbnailPixelSize, contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .overlay {
                        if let playback = previewSession?.playback, item.kind == .video,
                           playback.currentID == item.id, !playback.failed {
                            BrowseVideoSurface(playback: playback)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(alignment: .bottomLeading) {
                        HStack(spacing: 6) {
                            if favorite { Image(systemName: "heart.fill") }
                            Spacer(minLength: 0)
                            if item.kind == .video && previewSession?.playback.currentID != item.id {
                                Image(systemName: "play.fill")
                                if geometry.size.width >= 80, let duration = item.duration {
                                    Text(durationLabel(duration)).monospacedDigit().lineLimit(1)
                                }
                            }
                        }
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 2, y: 1).padding(8)
                    }
                    .modifier(MediaSelectionTreatment(selected: selected, selectionMode: selectionMode))
            }
            if showNames {
                Text(item.name).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.62) : Color.black.opacity(0.58))
                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: 24)
            }
        }.contentShape(Rectangle())
    }
    private func durationLabel(_ value: Double) -> String {
        guard value.isFinite, let seconds = Int(exactly: max(0, value).rounded(.towardZero)) else { return "—:—" }
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
