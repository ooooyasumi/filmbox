import AppKit
import SwiftUI
import FilmboxCore

/// Keep the catalogue behind a reference. SwiftUI only compares scalar revisions;
/// AppKit realises the thumbnails in the viewport, even when opening item 10,000.
struct Filmstrip: View {
    let store: AppStore
    let activeID: String
    let select: (MediaItem) -> Void
    var body: some View {
        FilmstripCollection(store: store, activeID: activeID, revision: store.visibleRevision,
            metadataRevision: store.mediaMetadataRevision, select: select)
    }
}

struct FilmstripCollection: NSViewRepresentable {
    let store: AppStore
    let activeID: String
    let revision: Int
    let metadataRevision: Int
    let select: (MediaItem) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = FilmstripScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.focusRingType = .none
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 7
        layout.minimumInteritemSpacing = 7
        layout.sectionInset = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        let collection = NSCollectionView()
        collection.identifier = .init("filmbox.viewer.filmstrip")
        collection.collectionViewLayout = layout
        collection.backgroundColors = [.clear]
        collection.isSelectable = false
        collection.focusRingType = .none
        collection.setAccessibilityLabel("胶片导航")
        collection.register(FilmstripCollectionItem.self, forItemWithIdentifier: .init("filmstrip-photo"))
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.autoresizingMask = [.height]
        scroll.documentView = collection
        context.coordinator.collection = collection
        scroll.onResize = { [weak coordinator = context.coordinator] in
            coordinator?.collection?.layoutSubtreeIfNeeded()
            coordinator?.centerActive()
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(activeID: activeID, revision: revision, metadataRevision: metadataRevision, select: select)
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        (scroll as? FilmstripScrollView)?.onResize = nil
        if let collection = coordinator.collection {
            for case let item as FilmstripCollectionItem in collection.visibleItems() { item.releaseThumbnail() }
            collection.dataSource = nil
            collection.delegate = nil
        }
        coordinator.select = nil
    }

    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
        let store: AppStore
        weak var collection: NSCollectionView?
        var select: ((MediaItem) -> Void)?
        private var items: [MediaItem] = []
        private var activeID: String?
        private var revision = -1
        private var metadataRevision = -1
        init(store: AppStore) { self.store = store }

        func update(activeID: String, revision: Int, metadataRevision: Int, select: @escaping (MediaItem) -> Void) {
            guard let collection else { return }
            self.select = select
            let structureChanged = self.revision != revision
            let metadataChanged = self.metadataRevision != metadataRevision
            let activeChanged = self.activeID != activeID
            let patch = metadataChanged && !structureChanged ? store.mediaMetadataChanges(since: self.metadataRevision) : nil
            let geometryChanged = metadataChanged && (patch == nil || !patch!.geometryChangedIDs.isEmpty)
            let wasVisible = collection.visibleItems().contains { ($0 as? FilmstripCollectionItem)?.mediaID == activeID }
            if structureChanged || metadataChanged { items = store.visibleItems }
            self.revision = revision; self.metadataRevision = metadataRevision; self.activeID = activeID
            if structureChanged { collection.reloadData() }
            else if geometryChanged { collection.collectionViewLayout?.invalidateLayout() }
            if structureChanged || geometryChanged { collection.layoutSubtreeIfNeeded() }
            if activeChanged || structureChanged || (geometryChanged && wasVisible) { centerActive() }
            if activeChanged || structureChanged || metadataChanged {
                for case let cell as FilmstripCollectionItem in collection.visibleItems() {
                    guard let path = collection.indexPath(for: cell), items.indices.contains(path.item) else { continue }
                    configure(cell, at: path.item)
                }
            }
        }

        fileprivate func centerActive() {
            guard let collection, let scroll = collection.enclosingScrollView,
                  let activeID, let index = store.visibleMediaIndex(id: activeID), items.indices.contains(index) else { return }
            let path = IndexPath(item: index, section: 0)
            guard let frame = collection.collectionViewLayout?.layoutAttributesForItem(at: path)?.frame else { return }
            let maximum = max(0, (collection.collectionViewLayout?.collectionViewContentSize.width ?? 0) - scroll.contentSize.width)
            scroll.contentView.scroll(to: NSPoint(x: min(maximum, max(0, frame.midX - scroll.contentSize.width / 2)), y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = collectionView.makeItem(withIdentifier: .init("filmstrip-photo"), for: indexPath) as! FilmstripCollectionItem
            configure(cell, at: indexPath.item)
            return cell
        }
        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> NSSize {
            guard items.indices.contains(indexPath.item) else { return NSSize(width: 87, height: 60) }
            let ratio = items[indexPath.item].aspectRatio ?? 1.5
            return NSSize(width: min(180, max(28, 54 * ratio)) + 6, height: 60)
        }
        func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                            forRepresentedObjectAt indexPath: IndexPath) {
            (item as? FilmstripCollectionItem)?.releaseThumbnail()
        }
        func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                            forRepresentedObjectAt indexPath: IndexPath) {
            if let cell = item as? FilmstripCollectionItem { configure(cell, at: indexPath.item) }
        }
        func selectItem(id: String) {
            guard let current = store.visibleMediaItem(id: id) else { return }
            select?(current)
        }
        private func configure(_ cell: FilmstripCollectionItem, at index: Int) {
            guard items.indices.contains(index) else { return }
            let item = items[index]
            cell.configure(item, active: item.id == activeID) { [weak self] id in
                self?.selectItem(id: id)
            }
        }
    }
}

@MainActor private final class FilmstripScrollView: NSScrollView {
    var onResize: (() -> Void)?
    private var lastViewport = NSSize.zero
    override func layout() {
        super.layout()
        guard contentSize.width > 0, contentSize.height > 0, contentSize != lastViewport else { return }
        lastViewport = contentSize
        onResize?()
    }
}

@MainActor private final class FilmstripCollectionItem: NSCollectionViewItem {
    private(set) var mediaID: String?
    private var hosting: NSHostingView<FilmstripThumbnail>?
    private var media: MediaItem?
    private var active = false
    override func loadView() { view = NSView() }
    func configure(_ item: MediaItem, active: Bool, select: @escaping (String) -> Void) {
        guard hosting == nil || media != item || self.active != active else { return }
        mediaID = item.id; media = item; self.active = active
        let content = FilmstripThumbnail(item: item, active: active, select: select)
        if let hosting { hosting.rootView = content }
        else {
            let host = NSHostingView(rootView: content)
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host)
            NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: view.trailingAnchor), host.topAnchor.constraint(equalTo: view.topAnchor),
                host.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
            hosting = host
        }
    }
    func releaseThumbnail() { hosting?.removeFromSuperview(); hosting = nil; media = nil; mediaID = nil }
    override func prepareForReuse() { super.prepareForReuse(); releaseThumbnail() }
}

private struct FilmstripThumbnail: View {
    let item: MediaItem
    let active: Bool
    let select: (String) -> Void
    var body: some View {
        Button { select(item.id) } label: {
            AsyncThumbnail(item: item, pixelSize: (item.aspectRatio ?? 1.5) > 2.3 ? 384 : 256, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(alignment: .bottomTrailing) {
                    if item.kind == .video { Image(systemName: "play.fill").font(.system(size: 8)).foregroundStyle(.white).padding(5) }
                }.padding(3).opacity(active ? 1 : 0.65)
        }.buttonStyle(.plain).focusEffectDisabled().help(item.name)
            .accessibilityLabel(item.name).accessibilityAddTraits(active ? .isSelected : [])
    }
}
