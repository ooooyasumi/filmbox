import AppKit
import SwiftUI
import FilmboxCore

@MainActor private struct StripRoot: View {
    @Bindable var store: AppStore
    var body: some View {
        Filmstrip(store: store, activeID: store.previewID ?? "") { store.previewID = $0.id }
    }
}

@main @MainActor private enum ViewerFilmstripChecks {
    private struct Failure: Error { let message: String }
    static var assertions = 0
    static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }; assertions += 1
    }
    static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }
    static func run() async throws {
        _ = NSApplication.shared
        guard let path = Bundle.main.object(forInfoDictionaryKey: "FilmboxDevelopmentCache") as? String,
              path.contains("filmbox-filmstrip.") else { throw Failure(message: "requires isolated cache") }
        let root = URL(fileURLWithPath: path).deletingLastPathComponent()
        let store = AppStore(directory: root.appendingPathComponent("Catalogue"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let source = root.appendingPathComponent("synthetic.jpg")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .jpeg, properties: [:])!.write(to: source)
        store.items = (0..<10000).map { i in
            MediaItem(id: "strip-\(i)", url: source, kind: .image, fileSize: 100, modifiedDate: date,
                createdDate: date.addingTimeInterval(Double(i)), pixelWidth: 120, pixelHeight: 80)
        }
        store.applyFilters()
        let first = store.visibleItems.first!, last = store.visibleItems.last!
        store.previewID = last.id
        let host = NSHostingView(rootView: StripRoot(store: store))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 82),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.contentView = host
        defer { window.close() }
        window.orderBack(nil)
        await settle(host)
        guard let collection: NSCollectionView = descendant(host), let scroll = collection.enclosingScrollView else {
            throw Failure(message: "missing actual native filmstrip")
        }
        try expect(collection.numberOfItems(inSection: 0) == 10000, "navigation must retain the entire library")
        try expect(!collection.visibleItems().isEmpty && collection.visibleItems().count < 100, "only visible thumbnails may be realised")
        try expect(visible(last, store: store, collection: collection), "opening the final photo must center its thumbnail")
        print("✓ 一万项胶片导航完整且仅创建视口内缩略图")

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
        await settle(host)
        try expect(!collection.visibleItems().isEmpty && collection.visibleItems().allSatisfy { !$0.view.subviews.isEmpty },
            "manual scrolling must restore the hosts released outside the viewport")
        let farEnd = max(0, (collection.collectionViewLayout?.collectionViewContentSize.width ?? 0) - scroll.contentSize.width)
        scroll.contentView.scroll(to: NSPoint(x: farEnd, y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
        await settle(host)
        try expect(visible(last, store: store, collection: collection) && collection.visibleItems().allSatisfy { !$0.view.subviews.isEmpty },
            "returning to the active photo cannot leave recycled thumbnails blank")
        print("✓ 手动滚动往返后缩略图宿主正常恢复")

        var worst = 0.0
        for turn in 0..<6 {
            let update = MediaItem(id: last.id, url: source, kind: .image, fileSize: 100, modifiedDate: date,
                createdDate: last.createdDate, pixelWidth: 121 + turn, pixelHeight: 80)
            let start = ProcessInfo.processInfo.systemUptime
            store.updateCachedMediaItems([last.id: update])
            store.publishVisibleMetadata([last.id: update], geometryChangedIDs: [last.id])
            await settle(host)
            worst = max(worst, ProcessInfo.processInfo.systemUptime - start)
        }
        try expect(worst < 1, "metadata updates must not block the main thread for seconds")
        try expect(visible(last, store: store, collection: collection), "download metadata must preserve the current thumbnail")
        try expect(collection.visibleItems().count < 100, "metadata must not instantiate the whole library")
        print("✓ 连续元数据更新不陷入整库比较，最慢一轮 \(Int(worst * 1000)) ms（含等待）")

        store.previewID = first.id
        await settle(host)
        try expect(visible(first, store: store, collection: collection), "keyboard navigation must follow the current photo")
        window.setContentSize(NSSize(width: 640, height: 82))
        await settle(host)
        try expect(visible(first, store: store, collection: collection), "resize must retain the active thumbnail")
        try expect(scroll.contentSize.width < 700, "the real viewport must have resized")
        print("✓ 跳至首项与窗口缩放保留当前项")

        let coordinator = FilmstripCollection.Coordinator(store: store)
        var chosen: MediaItem?
        coordinator.select = { chosen = $0 }
        let updated = store.visibleMediaItem(id: last.id)!
        coordinator.selectItem(id: updated.id)
        try expect(chosen?.pixelWidth == 126, "click must resolve current metadata, not the old cell value")
        chosen = nil
        coordinator.selectItem(id: "removed-id")
        try expect(chosen == nil, "a stale removed thumbnail cannot select a different photo")
        print("✓ 选择取最新元数据并忽略失效身份")

        store.query = "no-match"
        await settle(host)
        try expect(collection.numberOfItems(inSection: 0) == 0, "empty filters must clear the filmstrip")
        store.query = ""; store.previewID = first.id
        await settle(host)
        try expect(collection.numberOfItems(inSection: 0) == 10000 && visible(first, store: store, collection: collection),
            "restoring a filter must restore correct item identity and positioning")
        try expect(collection.visibleItems().count < 100, "filter restoration must remain virtualised")
        print("✓ 清空与恢复筛选后导航及虚拟化正确")
        await store.waitForFileOperations()
        print("\(assertions) 项查看器胶片导航检查通过")
    }
    static func settle(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
    }
    static func visible(_ item: MediaItem, store: AppStore, collection: NSCollectionView) -> Bool {
        guard let index = store.visibleMediaIndex(id: item.id),
              let frame = collection.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return false }
        return frame.intersects(collection.visibleRect)
    }
    static func descendant<T: NSView>(_ view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { descendant($0) as T? }.first
    }
}
