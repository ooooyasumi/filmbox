import AppKit
import SwiftUI
import FilmboxCore

@MainActor private struct TransitionRoot: View {
    @Bindable var store: AppStore
    var body: some View {
        if store.layout == .grid { MediaGrid(store: store) }
        else { BrowseView(store: store) }
    }
}

@main @MainActor private enum GridTransitionChecks {
    private struct Failure: Error { let message: String }
    static var assertions = 0
    static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }; assertions += 1
    }
    static func main() async {
        do { try await run() } catch { print("FAIL: \(error)"); exit(1) }
    }
    static func run() async throws {
        _ = NSApplication.shared
        guard let path = Bundle.main.object(forInfoDictionaryKey: "FilmboxDevelopmentCache") as? String,
              path.contains("filmbox-grid-transition.") else { throw Failure(message: "requires isolated cache") }
        let root = URL(fileURLWithPath: path).deletingLastPathComponent()
        let store = AppStore(directory: root.appendingPathComponent("Catalogue"))
        store.thumbnailSize = 180
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let source = root.appendingPathComponent("sample.jpg")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .jpeg, properties: [:])!.write(to: source)
        store.items = (0..<240).map { i in
            MediaItem(id: "transition-\(i)", url: source, kind: .image, fileSize: 100,
                modifiedDate: date, createdDate: date.addingTimeInterval(Double(i)), pixelWidth: 120, pixelHeight: 80)
        }
        store.applyFilters()
        let host = NSHostingView(rootView: TransitionRoot(store: store))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 935, height: 560),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.contentView = host
        defer { window.close() }
        window.orderBack(nil)
        await settle(host)
        let grid = try require(descendant(host) as PhotoCollectionView?)
        let coordinator = try require(grid.mediaCoordinator)
        try expect(store.gridBrowsePositionProvider === coordinator, "native grid must register its live geometry provider")

        // Select a corner photo, then let scroll publication replace the old
        // top-edge navigation anchor. A visible selection must still win.
        let visible = attributes(grid)
        let selectedPath = try require(visible.last?.indexPath)
        let selected = try require(coordinator.mediaByPath[selectedPath])
        store.activate(selected)
        await settle(host)
        let firstScroll = try require(grid.enclosingScrollView)
        firstScroll.contentView.scroll(to: CGPoint(x: 0, y: firstScroll.contentView.bounds.minY + 20))
        firstScroll.reflectScrolledClipView(firstScroll.contentView)
        coordinator.scheduleVisibleSectionUpdate()
        await settle(host)
        try expect(store.navigationAnchorID != selected.id, "fixture must publish a different top-edge timeline anchor")
        let middle = try centerItem(grid)
        try expect(middle.id != selected.id, "fixture needs a selected corner distinct from viewport center")
        store.layout = .browse
        try expect(store.visibleItems[store.browseIndex].id == selected.id, "visible selection must beat the timeline's top-edge anchor")
        await settle(host)
        try assertRollCentered(host, store: store, id: selected.id)
        try expect(store.gridBrowsePositionProvider == nil, "departing grid cannot leave a stale provider")
        print("✓ 视口内选中项优先，卷轴实际居中")

        store.layout = .grid
        await settle(host)
        let scrolledGrid = try require(descendant(host) as PhotoCollectionView?)
        let target = store.visibleItems[100]
        scrollGrid(scrolledGrid, to: target.id)
        let expected = try centerItem(scrolledGrid)
        try expect(!attributes(scrolledGrid).contains { scrolledGrid.mediaCoordinator?.mediaByPath[$0.indexPath!]?.id == selected.id },
            "old selection must be completely outside the current viewport")
        // Deliberately do not await the deferred scroll publisher before switch.
        store.layout = .browse
        try expect(store.visibleItems[store.browseIndex].id == expected.id, "offscreen selection must use the current native viewport center immediately")
        try expect(store.selectedIDs == [expected.id], "ordinary selection and inspector must follow the chosen media")
        await settle(host)
        try assertRollCentered(host, store: store, id: expected.id)
        print("✓ 旧选择已离屏时采用视口中央，快速滚动后立即切换也正确")

        store.layout = .grid
        await settle(host)
        let emptyGrid = try require(descendant(host) as PhotoCollectionView?)
        store.setSelectionMode(true) // Clears explicit selection.
        scrollGrid(emptyGrid, to: store.visibleItems[155].id)
        let noSelectionCenter = try centerItem(emptyGrid)
        store.layout = .browse
        try expect(store.visibleItems[store.browseIndex].id == noSelectionCenter.id, "without selection use the viewport center")
        try expect(store.selectedIDs.isEmpty, "switching must not invent a multi-selection")
        await settle(host)
        try assertRollCentered(host, store: store, id: noSelectionCenter.id)
        print("✓ 无选择同样采用视口中央且不创建选择")

        store.layout = .grid
        await settle(host)
        let multiGrid = try require(descendant(host) as PhotoCollectionView?)
        scrollGrid(multiGrid, to: store.visibleItems[80].id)
        let multiCoordinator = try require(multiGrid.mediaCoordinator)
        let shown = attributes(multiGrid).compactMap { $0.indexPath.flatMap { multiCoordinator.mediaByPath[$0] } }
        let other = try require(shown.first)
        store.activate(other)
        store.activate(store.visibleItems.last!) // Offscreen keyboard cursor.
        let multiSelection = store.selectedIDs
        store.layout = .browse
        try expect(store.visibleItems[store.browseIndex].id == other.id, "remaining visible selected item must win over an offscreen active selection")
        try expect(store.selectedIDs == multiSelection, "mode switch must retain the explicit multi-selection")
        await settle(host)
        try assertRollCentered(host, store: store, id: other.id)
        print("✓ 多选优先可见选项并保留选择集合")
        print("\(assertions)项真实网格／卷轴切换断言通过")
    }
    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure(message: "missing native test geometry") }; return value
    }
    static func attributes(_ grid: PhotoCollectionView) -> [NSCollectionViewLayoutAttributes] {
        let viewport = grid.enclosingScrollView!.contentView.bounds
        return (grid.collectionViewLayout?.layoutAttributesForElements(in: viewport) ?? [])
            .filter { $0.representedElementCategory == .item && $0.frame.intersection(viewport).width > 1 && $0.frame.intersection(viewport).height > 1 }
            .sorted { $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY }
    }
    static func centerItem(_ grid: PhotoCollectionView) throws -> MediaItem {
        let viewport = grid.enclosingScrollView!.contentView.bounds
        let center = CGPoint(x: viewport.midX, y: viewport.midY)
        let path = grid.indexPathForItem(at: center) ?? attributes(grid).min {
            hypot($0.frame.midX - center.x, $0.frame.midY - center.y) < hypot($1.frame.midX - center.x, $1.frame.midY - center.y)
        }?.indexPath
        return try require(path.flatMap { grid.mediaCoordinator?.mediaByPath[$0] })
    }
    static func scrollGrid(_ grid: PhotoCollectionView, to id: String) {
        guard let coordinator = grid.mediaCoordinator, let path = coordinator.pathByID[id],
              let frame = grid.collectionViewLayout?.layoutAttributesForItem(at: path)?.frame,
              let scroll = grid.enclosingScrollView else { return }
        scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, frame.midY - scroll.contentSize.height / 2)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    static func assertRollCentered(_ host: NSView, store: AppStore, id: String) throws {
        let roll = try require(descendant(host) as BrowseCollectionView?)
        let index = try require(roll.items.firstIndex { $0.id == id })
        let frame = try require(roll.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame)
        let viewport = try require(roll.enclosingScrollView?.contentView.bounds)
        try expect(abs(frame.midX - viewport.midX) < 2, "actual roll must center the chosen photo")
    }
    static func settle(_ host: NSView) async {
        host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
    }
    static func descendant<T: NSView>(_ view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { descendant($0) as T? }.first
    }
}
