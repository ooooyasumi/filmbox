import AppKit
import Foundation
import SwiftUI
import FilmboxCore
@testable import Filmbox

// Compiled after the actual BrowseView.swift in the same temporary source file
// so these integration checks can exercise its private native components.
@main
struct FilmboxInteractionChecks {
    private enum CheckError: Error { case failed(String) }
    @MainActor private static var passed = 0

    @MainActor static func main() async {
        do { try await run() }
        catch { print("FAIL \(error)"); exit(EXIT_FAILURE) }
    }

    @MainActor private static func run() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Filmbox-InteractionChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        let originalThumbnailPreference = UserDefaults.standard.object(forKey: "thumbnailSize")
        let originalBrowsePreference = UserDefaults.standard.object(forKey: "browseTimelineSize")
        defer {
            if let originalThumbnailPreference { UserDefaults.standard.set(originalThumbnailPreference, forKey: "thumbnailSize") }
            else { UserDefaults.standard.removeObject(forKey: "thumbnailSize") }
            if let originalBrowsePreference { UserDefaults.standard.set(originalBrowsePreference, forKey: "browseTimelineSize") }
            else { UserDefaults.standard.removeObject(forKey: "browseTimelineSize") }
        }
        store.setThumbnailSize(180); store.setBrowseTimelineSize(180)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let items = (0..<5_500).map { index in
            MediaItem(url: directory.appendingPathComponent("\(index).jpg"), kind: .image,
                      fileSize: 0, modifiedDate: date, createdDate: date,
                      pixelWidth: index.isMultiple(of: 3) ? 1_200 : 1_600, pixelHeight: 1_200)
        }
        store.items = items; store.visibleItems = items; store.visibleRevision = 1
        store.layout = .browse; store.browseIndex = 12
        store.setSelectionMode(true)
        store.selectedIDs = [items[1].id, items[2].id]
        let originalSelection = store.selectedIDs

        let hosting = NSHostingView(rootView: album(store: store))
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        // Never order this window front or activate the application. A real
        // window hierarchy is needed for AppKit document sizing and cell reuse.
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        await settle(window)
        guard let scroll: BrowseScrollView = descendant(of: hosting),
              let collection = scroll.documentView as? BrowseCollectionView,
              let layout = collection.collectionViewLayout as? BrowseAlbumLayout else {
            throw CheckError.failed("真实相册没有建立滚动容器")
        }
        layout.prepare()
        try check(collection.frame.width > scroll.contentSize.width * 100
                  && collection.frame.width >= layout.collectionViewContentSize.width - 1,
                  "真实 document 宽度覆盖 5500 项布局")

        let start = try center(12, layout: layout, scroll: scroll)
        scroll.scrollWheel(with: wheel(vertical: -2))
        let firstDown = scroll.contentView.bounds.minX
        scroll.scrollWheel(with: wheel(vertical: -2))
        let secondDown = scroll.contentView.bounds.minX
        try check(firstDown > start && secondDown > firstDown, "连续向下滚动持续向后浏览")
        scroll.scrollWheel(with: wheel(vertical: 2))
        let firstUp = scroll.contentView.bounds.minX
        scroll.scrollWheel(with: wheel(vertical: 2))
        let secondUp = scroll.contentView.bounds.minX
        try check(firstUp < secondDown && secondUp < firstUp, "连续向上滚动持续返回")

        scroll.scrollWheel(with: wheel(horizontal: -2))
        let horizontalForward = scroll.contentView.bounds.minX
        scroll.scrollWheel(with: wheel(horizontal: 2))
        try check(horizontalForward > secondUp && scroll.contentView.bounds.minX < horizontalForward,
                  "横向滚轮两个方向均可移动")
        let preciseStart = scroll.contentView.bounds.minX
        scroll.scrollWheel(with: wheel(vertical: -8, precise: true))
        try check(scroll.contentView.bounds.minX > preciseStart, "触控板精细增量可移动")

        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        scroll.scrollWheel(with: wheel(vertical: 2)); scroll.scrollWheel(with: wheel(vertical: 2))
        try check(abs(scroll.contentView.bounds.minX) < 1, "首项边界不会越界")
        let maximum = max(0, collection.bounds.width - scroll.contentSize.width)
        scroll.contentView.scroll(to: NSPoint(x: maximum, y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
        scroll.scrollWheel(with: wheel(vertical: 2))
        let beforeEnd = scroll.contentView.bounds.minX
        scroll.scrollWheel(with: wheel(vertical: -2)); scroll.scrollWheel(with: wheel(vertical: -2))
        try check(beforeEnd < maximum && abs(scroll.contentView.bounds.minX - maximum) < 1,
                  "末项可以返回且向后滚动稳定停在边界")

        var maximumAttributes = 0
        var maximumCells = 0
        for index in [0, 12, 2_749, 5_499] {
            _ = try center(index, layout: layout, scroll: scroll)
            await settle(window)
            maximumAttributes = max(maximumAttributes, layout.layoutAttributesForElements(in: scroll.contentView.bounds).count)
            maximumCells = max(maximumCells, collection.visibleItems().count)
        }
        try check(maximumAttributes > 0 && maximumAttributes < 20 && maximumCells > 0 && maximumCells < 30,
                  "5500 项首中末均仅实现可见范围（最多 \(maximumAttributes) 个布局项 / \(maximumCells) 个单元）")
        try check(store.selectedIDs == originalSelection, "滚动保留明确选中的照片")

        _ = try center(12, layout: layout, scroll: scroll)
        await settle(window)
        let fractionalCenter = layout.center(at: 12.125)!
        scroll.contentView.scroll(to: CGPoint(x: fractionalCenter - scroll.contentSize.width / 2, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle(window)
        let fractionalOrigin = scroll.contentView.bounds.minX
        try check(abs(store.browsePosition - 12.125) < 0.002 && store.browseIndex == 12,
                  "真实照片卷滚动在最近照片未变时发布连续位置")
        hosting.rootView = album(store: store)
        await settle(window)
        try check(abs(scroll.contentView.bounds.minX - fractionalOrigin) < 0.01,
                  "连续位置回传 SwiftUI 后不会反向吸附到照片中心")
        let fractionalInverse = layout.position(at: fractionalCenter)!
        try check(abs(fractionalInverse - 12.125) < 0.0001,
                  "不同照片宽度之间中心插值与反解保持精确")
        store.navigateBrowse(to: 12.375)
        hosting.rootView = album(store: store); await settle(window)
        try check(abs(scroll.contentView.bounds.midX - layout.center(at: 12.375)!) < 0.01,
                  "日期尺连续请求精确定位分数，最近照片相同时也会移动")
        store.navigateBrowse(to: 12.125)
        hosting.rootView = album(store: store); await settle(window)
        try check(abs(scroll.contentView.bounds.midX - fractionalCenter) < 0.01,
                  "日期尺反向连续请求恢复同一照片内原位置")
        let beforeCommandOrigin = scroll.contentView.bounds.origin
        let beforeCommandSize = store.browseTimelineSize
        let beforeCommandGridSize = store.thumbnailSize
        let beforeCommandHeight = layout.photoHeight
        let beforeCommandFrames = [0, 12, 2_749, 5_499].compactMap { layout.frame(at: $0) }
        let beforeCommandIndex = store.browseIndex
        let beforeCommandSelection = store.selectedIDs
        // Invoke the real responder locally; never post input to the desktop.
        scroll.scrollWheel(with: wheel(vertical: 2, command: true))
        let commandDidNotScroll = abs(scroll.contentView.bounds.minX - beforeCommandOrigin.x) < 0.01
            && abs(scroll.contentView.bounds.minY - beforeCommandOrigin.y) < 0.01
        hosting.rootView = album(store: store)
        await settle(window)
        layout.prepare()
        try check(store.browseTimelineSize > beforeCommandSize && store.thumbnailSize == beforeCommandGridSize
                  && layout.photoHeight == beforeCommandHeight
                  && [0, 12, 2_749, 5_499].compactMap({ layout.frame(at: $0) }) == beforeCommandFrames
                  && commandDidNotScroll && scroll.contentView.bounds.origin == beforeCommandOrigin
                  && store.browseIndex == beforeCommandIndex && store.selectedIDs == beforeCommandSelection,
                  "Command+滚轮仅缩放底部日期尺，照片布局、横滚位置、当前项与多选不变")

        window.setContentSize(NSSize(width: 720, height: 440))
        hosting.rootView = album(store: store, showNames: true)
        await settle(window)
        layout.prepare()
        try check(collection.frame.width >= layout.collectionViewContentSize.width - 1,
                  "调整窗口与文件名显示后文档范围仍与自动适配布局一致")
        store.visibleItems = Array(items.prefix(3)); store.visibleRevision += 1; store.browseIndex = 1
        hosting.rootView = album(store: store)
        await settle(window)
        layout.prepare()
        try check(collection.frame.width >= layout.collectionViewContentSize.width - 1 && collection.frame.width < 10_000,
                  "筛选后文档缩小到剩余照片")
        store.visibleItems = []; store.visibleRevision += 1; store.browseIndex = 0
        hosting.rootView = album(store: store)
        await settle(window)
        try check(abs(collection.frame.width - scroll.contentSize.width) < 1,
                  "空结果收回多余滚动范围")
        try await checkMetadataOnlyRefresh(directory: directory, date: date)
        try await checkCloudMetadataDeltas(directory: directory, date: date)
        try await checkStableMetadataViewport(directory: directory, date: date)
        try await checkAutomaticFit(directory: directory, date: date)
        try await checkDateRuler(directory: directory, date: date)
        try checkYearBoundaries(directory: directory)
        try await checkNativeActivation(directory: directory, date: date)
        try await checkNativeStrokes(directory: directory, date: date)
        try await checkQueuedCenterCancelledOnMouseDown(directory: directory, date: date)
        print("Interaction checks: \(passed) passed")
        withExtendedLifetime(window) { }
    }

    @MainActor private static func checkYearBoundaries(directory: URL) throws {
        let calendar = Calendar.current
        let seed = MediaItem(url: directory.appendingPathComponent("year-marker.jpg"), kind: .image,
                             fileSize: 1, modifiedDate: .now, createdDate: .now)
        let dates = [(2025, 2, 1), (2025, 1, 15), (2024, 12, 20), (2024, 11, 1), (2023, 12, 20)]
        let sections = dates.enumerated().map { index, d in
            let date = calendar.date(from: DateComponents(year: d.0, month: d.1, day: d.2))!
            return TemporalSection(id: "day:year-\(index)", startDate: date, endDate: date.addingTimeInterval(86400),
                                   title: "year \(index)", items: [seed])
        }
        let view = BrowseDateRulerView(frame: CGRect(x: 0, y: 0, width: 1000, height: 56))
        func configure(_ source: [TemporalSection], active: Int, changed: Bool) {
            let entries = source.enumerated().map { BrowseDateEntry(section: $0.element, firstItemIndex: $0.offset) }
            view.configure(entries: entries, activeIndex: active, dataChanged: changed, reduceMotion: true, dark: true)
        }
        configure(sections, active: 2, changed: true)
        try check(view.visibleYearBoundaries.map(\.marker.year) == ["2025", "2023"],
                  "横轴2024当前日期两侧，仅在真实跨年分界显示2025和2023")
        try check(view.visibleYearBoundaries.allSatisfy { boundary in
            abs(boundary.marker.position - view.x(at: Double(boundary.marker.index) - 0.5)) < 0.001
                && view.bounds.contains(boundary.frame)
        }, "跨年分割线跟随压缩时间坐标，年份完整显示在视口内")
        let previous = view.visibleYearBoundaries.map(\.marker.position)
        configure(sections, active: 3, changed: false)
        try check(zip(previous, view.visibleYearBoundaries.map(\.marker.position)).allSatisfy { abs($0 - $1) > 1 },
                  "同年内继续浏览，年份分界随日期移动而不固定在屏幕")
        configure(Array(sections.reversed()), active: 2, changed: true)
        try check(view.visibleYearBoundaries.map(\.marker.year) == ["2023", "2025"],
                  "升序时相邻年份标记保持正确方向")
        view.setFrameSize(CGSize(width: 120, height: 56))
        configure(sections, active: 0, changed: true)
        try check(view.visibleYearBoundaries.isEmpty && view.labelHitRect(for: 0)!.maxY > 42,
                  "邻年不在横轴视口时不显示分界年份，当前年份仍保留")
        view.stop()
    }

    @MainActor private static func checkMetadataOnlyRefresh(directory: URL, date: Date) async throws {
        let catalog = directory.appendingPathComponent("MetadataBrowseCatalog", isDirectory: true)
        let items = (0..<6).map { index in
            MediaItem(url: directory.appendingPathComponent("metadata-browse-\(index).jpg"), kind: .image,
                      fileSize: 0, modifiedDate: date, createdDate: date)
        }
        try CatalogPersistence(directory: catalog).save(CatalogState(cachedItems: items))
        let store = AppStore(directory: catalog)
        store.sort = .name; store.descending = false; store.layout = .browse; store.browseIndex = 1
        store.setSelectionMode(true); store.selectedIDs = [items[0].id, items[1].id]
        let hosting = NSHostingView(rootView: album(store: store))
        hosting.sizingOptions = []; hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        await settle(window)
        guard let collection: BrowseCollectionView = descendant(of: hosting),
              let layout = collection.collectionViewLayout as? BrowseAlbumLayout,
              let initialCell = collection.item(at: IndexPath(item: 1, section: 0)) as? BrowseCollectionItem,
              let imageHost: NSHostingView<BrowsePhotoCell> = descendant(of: initialCell.view),
              let initialFrame = layout.frame(at: 1) else { throw CheckError.failed("缺少元数据翻阅夹具") }
        let selection = store.selectedIDs
        let enriched = MediaItem(url: items[1].url, kind: .image, fileSize: 0, modifiedDate: date, createdDate: date,
                                 camera: "Metadata Camera", lens: "Metadata Lens")
        store.items = items.map { $0.id == enriched.id ? enriched : $0 }; store.applyFilters()
        hosting.rootView = album(store: store); await settle(window)
        let metadataCell = collection.item(at: IndexPath(item: 1, section: 0)) as? BrowseCollectionItem
        let metadataHost: NSHostingView<BrowsePhotoCell>? = metadataCell.flatMap { descendant(of: $0.view) }
        try check(metadataCell === initialCell && metadataHost === imageHost,
                  "翻阅仅补全相机元数据时保留原生单元与现有图片宿主")
        try check(metadataHost?.rootView.item.camera == "Metadata Camera" && metadataCell?.media?.lens == "Metadata Lens",
                  "翻阅复用图片宿主同步最新元数据而非旧值")
        try check(layout.frame(at: 1) == initialFrame && store.selectedIDs == selection && store.browseIndex == 1,
                  "翻阅非几何元数据更新不移动照片、不改变当前项或多选")
        let ratio = enriched.withPreviewAspectRatio(0.55)
        store.items = store.items.map { $0.id == ratio.id ? ratio : $0 }; store.applyFilters()
        hosting.rootView = album(store: store); await settle(window); layout.prepare()
        let ratioCell = collection.item(at: IndexPath(item: 1, section: 0)) as? BrowseCollectionItem
        let ratioHost: NSHostingView<BrowsePhotoCell>? = ratioCell.flatMap { descendant(of: $0.view) }
        try check(ratioCell === initialCell && ratioHost === imageHost && ratioHost?.rootView.item.previewAspectRatio == 0.55,
                  "翻阅补全比例时复用可见单元，不销毁现有图片宿主")
        try check(layout.frame(at: 1) != initialFrame && store.selectedIDs == selection && store.browseIndex == 1 && !window.isVisible,
                  "翻阅新比例生效且保留当前项目和多选，窗口始终隐藏")
    }

    @MainActor private static func checkCloudMetadataDeltas(directory: URL, date: Date) async throws {
        let accountID = UUID()
        CloudTransferCenter.shared.requireLogin(accountID: accountID)
        defer { CloudTransferCenter.shared.forgetConnection(accountID: accountID) }
        let items = (0..<80).map { index in
            MediaItem(cloud: CloudMediaReference(accountID: accountID, fileID: "roll-\(index)", parentID: "/",
                                                remotePath: String(format: "/roll-%03d.jpg", index), revision: "v1"),
                      kind: .image, fileSize: 0, modifiedDate: date, createdDate: date)
        }
        let catalog = directory.appendingPathComponent("CloudDeltaBrowseCatalog", isDirectory: true)
        try CatalogPersistence(directory: catalog).save(CatalogState(cachedItems: items))
        let store = AppStore(directory: catalog)
        store.sort = .name; store.descending = false; store.layout = .browse; store.browseIndex = 1
        store.setSelectionMode(true); store.selectedIDs = [items[1].id]
        let hosting = NSHostingView(rootView: album(store: store))
        hosting.sizingOptions = []; hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        await settle(window)
        guard let collection: BrowseCollectionView = descendant(of: hosting),
              let scroll = collection.enclosingScrollView,
              let layout = collection.collectionViewLayout as? BrowseAlbumLayout,
              let initialCell = collection.item(at: IndexPath(item: 1, section: 0)) as? BrowseCollectionItem,
              let imageHost: NSHostingView<BrowsePhotoCell> = descendant(of: initialCell.view) else { throw CheckError.failed("缺少云端增量翻阅夹具") }
        let generation = layout.layoutGeneration
        let visibleRevision = store.visibleRevision, timelineRevision = store.timelineRevision
        let origin = scroll.contentView.bounds.origin
        store.commitCloudMetadata([["id": items[1].id, "revision": "v1", "camera": "Delta Camera"]])
        store.commitCloudMetadata([["id": items[72].id, "revision": "v1", "lens": "Offscreen Lens"]])
        hosting.rootView = album(store: store); await settle(window)
        let refreshed = collection.item(at: IndexPath(item: 1, section: 0)) as? BrowseCollectionItem
        let refreshedHost: NSHostingView<BrowsePhotoCell>? = refreshed.flatMap { descendant(of: $0.view) }
        try check(layout.layoutGeneration == generation && store.visibleRevision == visibleRevision && store.timelineRevision == timelineRevision,
                  "真实云元数据提交不重建翻阅几何，也不递增结构修订")
        try check(refreshed === initialCell && refreshedHost === imageHost && refreshedHost?.rootView.item.camera == "Delta Camera"
                  && collection.items[72].lens == "Offscreen Lens" && scroll.contentView.bounds.origin == origin,
                  "翻阅消费两批合并delta，保留原图片宿主及浏览位置并更新屏外描述")
        let previous = layout.frame(at: 71), following = layout.frame(at: 73)
        store.commitCloudMetadata([["id": items[72].id, "revision": "v1", "ratio": 0.25]])
        hosting.rootView = album(store: store); await settle(window); layout.prepare()
        try check(layout.lastMeasuredItemCount == 1 && layout.frame(at: 71) == previous && layout.frame(at: 73) != following,
                  "翻阅屏外比例补齐只测量一张尺寸，正确平移后续照片且保留前方几何")
        try check(store.browseIndex == 1 && store.selectedIDs == [items[1].id] && !window.isVisible,
                  "翻阅增量重排保持当前项与选择，测试窗口始终隐藏")
    }

    @MainActor private static func checkStableMetadataViewport(directory: URL, date: Date) async throws {
        let accountID = UUID()
        CloudTransferCenter.shared.requireLogin(accountID: accountID)
        defer { CloudTransferCenter.shared.forgetConnection(accountID: accountID) }
        let items = (0..<40).map { index in
            MediaItem(cloud: CloudMediaReference(accountID: accountID, fileID: "stable-\(index)", parentID: "/",
                                                remotePath: String(format: "/stable-%03d.jpg", index), revision: "v1"),
                      kind: .image, fileSize: 0, modifiedDate: date, createdDate: date)
        }
        let catalog = directory.appendingPathComponent("StableRollCatalog")
        try CatalogPersistence(directory: catalog).save(CatalogState(cachedItems: items))
        let store = AppStore(directory: catalog)
        store.sort = .name; store.descending = false; store.layout = .browse; store.browseIndex = 18
        store.setSelectionMode(true); store.selectedIDs = [items[18].id]
        let scroll = BrowseScrollView(frame: CGRect(x: 0, y: 0, width: 900, height: 500))
        scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        let collection = BrowseCollectionView(); collection.store = store
        let layout = BrowseAlbumLayout(); collection.collectionViewLayout = layout
        collection.register(BrowseCollectionItem.self, forItemWithIdentifier: .init("album-photo"))
        let coordinator = ContinuousPhotoAlbum.Coordinator(store: store)
        collection.dataSource = coordinator; collection.delegate = coordinator
        scroll.documentView = collection; coordinator.collection = collection; coordinator.scroll = scroll
        coordinator.observe(scroll.contentView)
        scroll.onUserScroll = { coordinator.beginUserScroll() }
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 900, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { coordinator.stop(); scroll.onUserScroll = nil; collection.dataSource = nil; collection.delegate = nil; window.contentView = nil }
        func update() { coordinator.update(showNames: false, effects: true, reduceMotion: false, selectionMode: true) }
        update(); await settle(window)
        // Stop between centres. Changing the right neighbour changes the
        // centre-interpolation scale, but must not move the photo under view.
        store.navigateBrowse(to: 18.25); update(); await settle(window)
        func screenCentre(_ index: Int) -> CGFloat {
            let frame = collection.item(at: IndexPath(item: index, section: 0)).map {
                $0.view.convert($0.view.bounds, to: collection)
            } ?? layout.frame(at: index)!
            return frame.midX - scroll.contentView.bounds.minX
        }
        let initial = screenCentre(18), origin = scroll.contentView.bounds.minX
        store.commitCloudMetadata([["id": items[19].id, "revision": "v1", "ratio": 0.2]])
        update(); await settle(window)
        try check(abs(screenCentre(18) - initial) < 0.01 && abs(scroll.contentView.bounds.minX - origin) < 0.01,
                  "右侧缩略图补齐比例不改变当前照片位置，含两张照片之间的停留位置")
        for (index, ratio) in [(2, 0.3), (17, 2.8), (18, 0.6), (39, 0.4)] {
            let before = screenCentre(18)
            store.commitCloudMetadata([["id": items[index].id, "revision": "v1", "ratio": ratio]])
            update()
            let immediateCell = collection.item(at: IndexPath(item: 18, section: 0))
            let actualCentre = immediateCell.map { $0.view.convert($0.view.bounds, to: collection).midX - scroll.contentView.bounds.minX }
            try check(abs(screenCentre(18) - before) < 0.01 && actualCentre.map { abs($0 - before) < 0.01 } == true,
                      "第\(index)张比例更新在同一布局事务内补偿真实单元位置，无一帧中间跳动")
            await settle(window)
            let cell = collection.item(at: IndexPath(item: 18, section: 0))
            try check(abs(screenCentre(18) - before) < 0.01
                      && cell.map { abs($0.view.convert($0.view.bounds, to: collection).midX - scroll.contentView.bounds.minX - before) < 0.01 } == true
                      && (cell?.view.layer?.animationKeys()?.isEmpty ?? true),
                      "第\(index)张比例更新后当前照片持续稳定，无延迟位移动画")
        }
        // Simulate a live wheel event whose focus publication has not run yet.
        coordinator.beginUserScroll()
        scroll.contentView.scroll(to: CGPoint(x: layout.center(at: 23.15)! - scroll.contentSize.width / 2, y: 0))
        collection.layoutSubtreeIfNeeded()
        let live = screenCentre(23)
        store.commitCloudMetadata([["id": items[4].id, "revision": "v1", "ratio": 0.4]])
        update()
        try check(abs(screenCentre(23) - live) < 0.01, "滚动焦点尚未回传时按真实视口保位，不跳回旧照片")
        await settle(window)
        store.focus(items[30])
        store.commitCloudMetadata([["id": items[5].id, "revision": "v1", "ratio": 0.45]])
        update(); await settle(window)
        try check(abs(screenCentre(30) - scroll.contentSize.width / 2) <= 1 && store.browseIndex == 30,
                  "比例更新不阻止明确点击或键盘导航到另一张照片")
        try check(store.selectedIDs == [items[18].id] && !window.isVisible, "保位检查不改多选规则、不显示测试窗口且不访问网盘")
    }

    @MainActor private static func checkAutomaticFit(directory: URL, date: Date) async throws {
        let store = AppStore(directory: directory.appendingPathComponent("AutomaticFitCatalog"))
        let dimensions: [(String, Int?, Int?)] = [
            ("landscape", 1_600, 1_200), ("portrait", 800, 1_200),
            ("panorama", 12_000, 1_000), ("square", 1_200, 1_200),
            ("unknown", nil, nil), ("invalid-zero", 0, 1_200),
            ("invalid-negative", -1, 1_200), ("extreme-wide", Int.max, 1),
            ("extreme-tall", 1, Int.max), ("last-panorama", 9_600, 1_000)
        ]
        let items = dimensions.map { label, width, height in
            MediaItem(url: directory.appendingPathComponent("fit-\(label).jpg"), kind: .image,
                      fileSize: 0, modifiedDate: date, createdDate: date,
                      pixelWidth: width, pixelHeight: height)
        }
        store.items = items; store.visibleItems = items; store.visibleRevision += 1
        store.layout = .browse; store.browseIndex = 0; store.setBrowseTimelineSize(180)
        store.setSelectionMode(true); store.selectedIDs = [items[1].id, items[2].id]
        let hosting = NSHostingView(rootView: album(store: store))
        hosting.sizingOptions = []; hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        await settle(window)
        guard let scroll: BrowseScrollView = descendant(of: hosting),
              let collection = scroll.documentView as? BrowseCollectionView,
              let layout = collection.collectionViewLayout as? BrowseAlbumLayout else {
            throw CheckError.failed("自动适配检查缺少真实原生布局")
        }
        func verify(_ indices: [Int], caption: CGFloat, label: String) throws {
            layout.prepare()
            let viewport = scroll.contentSize
            let availableHeight = max(0, viewport.height - caption)
            var matches = abs(layout.photoHeight - availableHeight) < 0.001
            for index in indices {
                guard let frame = layout.frame(at: index) else { matches = false; continue }
                let ratio = items[index].aspectRatio ?? 1.5
                let imageHeight = min(availableHeight, viewport.width / ratio)
                let expectedWidth = min(viewport.width, imageHeight * ratio)
                matches = matches && frame.width.isFinite && frame.height.isFinite && frame.minY.isFinite
                    && abs(frame.width - expectedWidth) < 0.001
                    && abs(frame.height - (imageHeight + caption)) < 0.001
                    && abs(frame.minY - (availableHeight - imageHeight) / 2) < 0.001
                    && frame.width <= viewport.width + 0.001 && frame.height <= viewport.height + 0.001
            }
            try check(matches, label)
        }
        try verify([0, 1, 3], caption: 0, label: "横图、竖图与方图默认顶满真实视口高度，不留旧上下边距")
        try verify([2, 9], caption: 0, label: "超宽全景优先完整适配视口宽度，降低高度并垂直居中")
        try verify([4, 5, 6], caption: 0, label: "未知及无效尺寸使用稳定比例自动适配")
        try verify([7, 8], caption: 0, label: "极宽与极窄比例保持有限完整几何，不强加最小宽度或裁切")

        for index in [0, items.count - 1] {
            store.browseIndex = index
            hosting.rootView = album(store: store); await settle(window); layout.prepare()
            guard let frame = layout.frame(at: index) else { throw CheckError.failed("缺少首尾全幅布局") }
            let viewport = scroll.contentView.bounds
            try check(abs(frame.midX - viewport.midX) < 0.01
                      && frame.minX >= viewport.minX - 0.01 && frame.maxX <= viewport.maxX + 0.01
                      && frame.minY >= viewport.minY - 0.01 && frame.maxY <= viewport.maxY + 0.01
                      && !window.isVisible,
                      index == 0 ? "首张照片由真实协调器完整居中，验收窗口始终隐藏"
                                 : "末张全景由真实协调器完整居中，不留最低侧边距")
        }

        // Both a window resize and an open inspector/sidebar reduce the
        // actual clip viewport. Fit must use that measured width, not a screen
        // or stale initial-window metric.
        window.setContentSize(NSSize(width: 560, height: 620))
        hosting.rootView = album(store: store); await settle(window)
        try verify([0, 1, 2, 3, 4, 7, 8, 9], caption: 0,
                   label: "窄窗口或侧栏占宽后按新可用视口重新适配，普通横图也完整可见")
        store.browseIndex = 0
        hosting.rootView = album(store: store); await settle(window); layout.prepare()
        guard let firstFullWidth = layout.frame(at: 0) else { throw CheckError.failed("缺少全宽首张布局") }
        try check(abs(firstFullWidth.minX - scroll.contentView.bounds.minX) < 0.01
                  && abs(firstFullWidth.width - scroll.contentSize.width) < 0.01,
                  "首张被宽度限制时可完整贴合视口两边，不额外加入侧向边距")
        window.setContentSize(NSSize(width: 1_100, height: 380))
        hosting.rootView = album(store: store); await settle(window)
        try verify([0, 1, 2, 3, 4, 7, 8, 9], caption: 0,
                   label: "窗口变宽变矮后恢复高度优先，全景继续宽度优先")

        hosting.rootView = album(store: store, showNames: true); await settle(window)
        try verify(Array(items.indices), caption: 24,
                   label: "显示文件名准确预留 24 点，照片在剩余区域满高或完整居中")
        hosting.rootView = album(store: store); await settle(window)
        try verify(Array(items.indices), caption: 0,
                   label: "关闭文件名立即收回 24 点高度，恢复完整视口适配")

        store.browseIndex = 2
        hosting.rootView = album(store: store); await settle(window); layout.prepare()
        let frames = items.indices.compactMap { layout.frame(at: $0) }
        let origin = scroll.contentView.bounds.origin
        let selection = store.selectedIDs
        let current = store.browseIndex
        let gridSize = store.thumbnailSize
        let revision = store.visibleRevision
        for size in [64.0, 130.0, 280.0] {
            store.setBrowseTimelineSize(size)
            hosting.rootView = album(store: store); await settle(window); layout.prepare()
            try check(items.indices.compactMap({ layout.frame(at: $0) }) == frames
                      && scroll.contentView.bounds.origin == origin && store.browseIndex == current
                      && store.selectedIDs == selection && store.thumbnailSize == gridSize
                      && store.visibleRevision == revision,
                      "底部日期尺调整至 \(Int(size)) 时照片几何、连续位置、当前照片与多选完全不变")
        }
    }

    @MainActor private static func checkDateRuler(directory: URL, date: Date) async throws {
        let store = AppStore(directory: directory.appendingPathComponent("RulerCatalog"))
        let items = (0..<5_500).map { index in
            let date = date.addingTimeInterval(Double(index / 2) * -86_400)
            return MediaItem(url: directory.appendingPathComponent("date-\(index).jpg"), kind: .image,
                             fileSize: 0, modifiedDate: date, createdDate: date)
        }
        store.items = items; store.filter = .all; store.layout = .browse
        store.setBrowseTimelineSize(180); store.setSelectionMode(true)
        store.selectedIDs = [items[1].id, items[2].id]
        let selection = store.selectedIDs
        let view = BrowseDateRulerView(frame: NSRect(x: 0, y: 0, width: 720, height: 52))
        let coordinator = BrowseTimeRuler.Coordinator(store: store)
        view.onNavigate = { coordinator.navigate(to: $0) }
        view.onNavigatePosition = { coordinator.navigate(toPosition: $0) }
        view.onZoom = { store.zoomTimeline(with: $0) }
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 720, height: 52),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        coordinator.update(view, reduceMotion: true, dark: false)
        try check(view.entries.count == 2_750 && coordinator.sectionByItem[0] == 0
                  && coordinator.sectionByItem[1] == 0 && coordinator.sectionByItem[2] == 1,
                  "日期尺真实分组，同日照片拥有独立媒体坐标")
        let sizeBeforeCommand = store.browseTimelineSize, gridSizeBeforeCommand = store.thumbnailSize
        let visibleRevisionBeforeCommand = store.visibleRevision, offsetBeforeCommand = view.scrollOffset
        view.scrollWheel(with: wheel(vertical: 2, command: true))
        try check(store.browseTimelineSize > sizeBeforeCommand && store.thumbnailSize == gridSizeBeforeCommand
                  && store.visibleRevision == visibleRevisionBeforeCommand && store.browseIndex == 0
                  && view.scrollOffset == offsetBeforeCommand,
                  "日期尺 Command+滚轮只调整独立日期尺度")
        store.setBrowseTimelineSize(180); coordinator.update(view, reduceMotion: true, dark: false)
        let initialBuilds = coordinator.rebuildCount, dayEntries = view.entries.map(\.id), daySpacing = view.tickSpacing
        store.setBrowseTimelineSize(210); coordinator.update(view, reduceMotion: true, dark: false)
        try check(view.tickSpacing > daySpacing && view.entries.map(\.id) == dayEntries
                  && coordinator.rebuildCount == initialBuilds && store.browseIndex == 0 && store.selectedIDs == selection,
                  "同粒度连续缩放压缩日期尺，不重建日期索引或移动照片")
        store.setBrowseTimelineSize(180); coordinator.update(view, reduceMotion: true, dark: false)
        try check(abs(view.tickSpacing - daySpacing) < 0.001 && coordinator.rebuildCount == initialBuilds,
                  "反向缩放恢复压缩日期尺的尺度")
        store.focus(store.visibleItems[2_749]); coordinator.update(view, reduceMotion: true, dark: false)
        try check(view.activeIndex == 1_374 && view.visibleDateIndices.contains(1_374)
                  && coordinator.rebuildCount == initialBuilds && abs(view.position - 2_749) < 0.001,
                  "照片卷整数游标同步日期，不重建 5500 项成员索引")
        try check(view.visibleDateIndices.count < 400, "2750 个日期在压缩后仍仅绘制可见范围")
        let denseLabels = view.visibleDateLabels, denseTicks = view.visibleTicks
        try check(denseTicks.count <= Int(view.bounds.width / 22) + 1
                  && zip(denseTicks, denseTicks.dropFirst()).allSatisfy({ $0.1.position - $0.0.position >= 22 - 0.001 }),
                  "密集日期只保留至少 22 点间隔的真实刻度，数量由视口限制")
        try check(denseTicks.filter(\.isMajor).count == denseLabels.count
                  && denseLabels.allSatisfy({ label in
                      denseTicks.contains { $0.isMajor && $0.index == label.index && abs($0.position - Double(label.x)) < 0.001 }
                  })
                  && denseTicks.filter({ $0.index == view.activeIndex }).count == 1,
                  "每个日期标签严格对齐唯一主刻度，当前中线不叠加日期边界线")
        try check(denseLabels.filter({ $0.index != view.activeIndex }).allSatisfy({
                      abs($0.x - ($0.index == view.activeIndex - 1 ? min(view.x(at: Double(view.entries[$0.index].firstItemIndex)), view.bounds.midX - 84) : ($0.index == view.activeIndex + 1 ? max(view.x(at: Double(view.entries[$0.index].firstItemIndex)), view.bounds.midX + 84) : view.x(at: Double(view.entries[$0.index].firstItemIndex))))) < 0.001
                  })
                  && denseTicks.filter({ !$0.isMajor }).allSatisfy({
                      view.entries.indices.contains($0.index)
                          && abs($0.position - Double(view.x(at: Double(view.entries[$0.index].firstItemIndex)))) < 0.001
                  }),
                  "相邻日期标签保留最小可读间距，远处日期和短刻度仍锚定真实日期")
        guard let tickLabel = denseLabels.first(where: { $0.index != view.activeIndex }) else {
            throw CheckError.failed("密集日期夹具缺少可点击主刻度")
        }
        view.selectDate(at: CGPoint(x: tickLabel.x, y: 6))
        coordinator.update(view, reduceMotion: true, dark: false)
        try check(view.activeIndex == tickLabel.index
                  && store.browseIndex == view.entries[tickLabel.index].firstItemIndex && store.selectedIDs == selection,
                  "点击非当前主刻度与下方日期文字定位同一天首项")
        store.focus(store.visibleItems[2_749]); coordinator.update(view, reduceMotion: true, dark: false)
        let beforeWithinDay = view.scrollOffset
        store.recordBrowsePosition(position: 2_748.25, item: store.visibleItems[2_748])
        coordinator.update(view, reduceMotion: true, dark: false)
        let firstWithinDay = view.scrollOffset
        store.recordBrowsePosition(position: 2_748.4, item: store.visibleItems[2_748])
        coordinator.update(view, reduceMotion: true, dark: false)
        try check(view.activeIndex == 1_374 && firstWithinDay < beforeWithinDay
                  && view.scrollOffset > firstWithinDay
                  && abs((view.position(at: CGPoint(x: view.x(at: 2_748.4), y: 25)) ?? -1) - 2_748.4) < 0.001,
                  "同日、同一最近照片内浏览仍连续平移压缩刻度且可精确反算")
        let startPosition = store.browsePosition, startOffset = view.scrollOffset
        view.scrollWheel(with: wheel(vertical: -1)); coordinator.update(view, reduceMotion: true, dark: false)
        try check(abs(view.scrollOffset - startOffset - 28) < 0.001 && store.browsePosition > startPosition
                  && abs(view.position - store.browsePosition) < 0.001,
                  "普通滚轮以紧凑尺距离前进，精确反算照片位置")
        view.scrollWheel(with: wheel(horizontal: 1)); coordinator.update(view, reduceMotion: true, dark: false)
        try check(abs(store.browsePosition - startPosition) < 0.001, "日期尺横向滚轮反向返回原连续位置")
        let beforePrecise = view.scrollOffset
        view.scrollWheel(with: wheel(vertical: -12, precise: true)); coordinator.update(view, reduceMotion: true, dark: false)
        try check(abs(view.scrollOffset - beforePrecise - 12) < 0.001
                  && store.browsePosition != store.browsePosition.rounded(), "触控板精细位移同步到照片卷且不取整")
        let beforeClick = view.position
        view.selectDate(at: CGPoint(x: view.x(at: beforeClick + 2.25), y: 6))
        coordinator.update(view, reduceMotion: true, dark: false)
        try check(abs(store.browsePosition - beforeClick - 2.25) < 0.001
                  && store.browseIndex == Int(store.browsePosition.rounded())
                  && store.visibleTimelineSectionID == view.entries[view.activeIndex].id,
                  "点击尺上任意位置定位精确媒体分数并同步当前日期")
        let dragPoint = CGPoint(x: view.bounds.midX, y: 20), beforeDrag = view.position
        let dragDistance = view.x(at: beforeDrag + 27.125) - view.bounds.midX
        view.beginScrubbing(at: dragPoint)
        view.scrub(to: CGPoint(x: dragPoint.x - dragDistance, y: dragPoint.y))
        view.endScrubbing(at: CGPoint(x: dragPoint.x - dragDistance, y: dragPoint.y))
        coordinator.update(view, reduceMotion: true, dark: false)
        try check(abs(view.position - beforeDrag - 27.125) < 0.001 && abs(store.browsePosition - view.position) < 0.001,
                  "拖动压缩日期尺连续跨组，保留精确分数位置")
        let beforeAX = view.activeIndex
        let increment = view.accessibilityPerformIncrement(), decrement = view.accessibilityPerformDecrement()
        try check(increment && decrement && view.activeIndex == beforeAX && store.selectedIDs == selection,
                  "辅助功能逐日期导航且保留显式多选")
        let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124)!
        view.keyDown(with: right)
        try check(view.activeIndex == beforeAX + 1, "键盘方向键逐日期导航")
        // Daily segments here are only a few points wide, so a label's edge
        // overlaps another date's raw coordinate. Visible words must still
        // navigate to the date they name.
        guard let dateLabel = view.visibleDateLabels.first(where: { label in
            guard label.index != view.activeIndex, let rect = view.labelHitRect(for: label.index) else { return false }
            return view.index(at: CGPoint(x: rect.maxX - 1, y: 25)) != label.index
        }), let dateHitRect = view.labelHitRect(for: dateLabel.index) else {
            throw CheckError.failed("密集日期夹具没有建立覆盖邻日的可见日期文字")
        }
        let dateFirstItem = view.entries[dateLabel.index].firstItemIndex
        view.selectDate(at: CGPoint(x: dateHitRect.maxX - 1, y: 25))
        coordinator.update(view, reduceMotion: true, dark: false)
        try check(view.activeIndex == dateLabel.index && store.browseIndex == dateFirstItem && store.selectedIDs == selection,
                  "压缩日期文字边缘优先选中文字日期，不误跳其下方邻日")
        guard let currentYearHit = view.labelHitRect(for: view.activeIndex) else {
            throw CheckError.failed("当前日期必须保留年份触点")
        }
        let currentDate = view.activeIndex
        view.selectDate(at: CGPoint(x: currentYearHit.midX, y: 42))
        coordinator.update(view, reduceMotion: true, dark: false)
        try check(view.activeIndex == currentDate && view.visibleDateLabels.filter({ $0.index != view.activeIndex })
                    .allSatisfy({ (view.labelHitRect(for: $0.index)?.maxY ?? 100) < 40 }),
                  "仅当前日期保留年份文字触点，其余日期下方留空")
        store.query = "date-0.jpg"; coordinator.update(view, reduceMotion: true, dark: false)
        view.scrollWheel(with: wheel(vertical: -10))
        try check(view.entries.count == 1 && view.activeIndex == 0 && view.scrollOffset == 0 && store.browseIndex == 0,
                  "单结果收回日期与连续滚动范围")
        store.query = "missing-date-name"; coordinator.update(view, reduceMotion: true, dark: false)
        view.selectDate(at: CGPoint(x: 500, y: 20)); view.scrollWheel(with: wheel(vertical: -10))
        try check(view.entries.isEmpty && view.activeIndex == -1 && view.visibleDateIndices.isEmpty
                  && !view.accessibilityPerformIncrement(), "空结果点击、滚动、辅助功能安全")
        store.query = ""; store.setBrowseTimelineSize(130); coordinator.update(view, reduceMotion: true, dark: false)
        let weekCount = view.entries.count, weekBuilds = coordinator.rebuildCount, weekEntries = view.entries.map(\.id)
        store.setThumbnailSize(64); coordinator.update(view, reduceMotion: true, dark: false)
        try check(weekCount > 120 && weekCount < 500 && view.entries.allSatisfy { $0.id.hasPrefix("week:") }
                  && view.entries.map(\.id) == weekEntries && coordinator.rebuildCount == weekBuilds,
                  "周日期尺独立于网格粒度")
        store.selectedIDs = selection
        coordinator.navigate(to: 1); coordinator.update(view, reduceMotion: true, dark: false)
        let currentItem = store.visibleItems[store.browseIndex]
        let currentGridSection = store.timelineSections.first { $0.id == store.visibleTimelineSectionID }
        try check(view.activeIndex == 1 && store.browseIndex == view.entries[1].firstItemIndex
                  && currentGridSection?.items.contains(where: { $0.id == currentItem.id }) == true && store.selectedIDs == selection,
                  "周日期导航同步有效网格高亮并保留多选")
        store.setBrowseTimelineSize(64); coordinator.update(view, reduceMotion: true, dark: true)
        let monthCount = view.entries.count
        coordinator.navigate(to: 1); coordinator.update(view, reduceMotion: true, dark: true)
        try check(monthCount > 1 && monthCount < 120 && view.entries.allSatisfy { $0.id.hasPrefix("month:") }
                  && view.activeIndex == 1 && store.browseIndex == view.entries[1].firstItemIndex,
                  "月粒度重映射正确且可导航")
        // Sparse dates do not allocate empty calendar buckets, and a busy day
        // receives only a moderate bonus rather than one unit per photograph.
        let calendar = Calendar.current
        let dates = [(2026, 9, 27, 80), (2026, 9, 24, 2), (2025, 12, 31, 1)]
        var unequal: [MediaItem] = []
        for (year, month, day, count) in dates {
            let shot = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
            for index in 0..<count {
                unequal.append(MediaItem(url: directory.appendingPathComponent("unequal-\(year)-\(month)-\(day)-\(index).jpg"),
                                         kind: .image, fileSize: 0, modifiedDate: shot, createdDate: shot))
            }
        }
        store.items = unequal; store.filter = .all; store.setBrowseTimelineSize(180)
        coordinator.update(view, reduceMotion: true, dark: true)
        try check(view.entries.count == 3 && view.entries.map(\.itemCount) == [80, 2, 1]
                  && view.span(for: 0) > view.span(for: 1) && view.span(for: 0) < view.span(for: 1) * 2.25,
                  "80 张日期仅比 2 张适度加长，空日期不占长度")
        store.recordBrowsePosition(position: 30.25, item: store.visibleItems[30])
        coordinator.update(view, reduceMotion: true, dark: true)
        try check(view.activeIndex == 0 && view.visibleDateLabels.contains(where: { $0.index == 0 && $0.x == view.bounds.midX })
                  && view.visibleDateLabels.allSatisfy({ $0.x == $0.yearX }) && view.entries[0].year == "2026",
                  "长日期组内部当前日期始终可读，当前年份严格位于对应日期下方")
        let previous = view.scrollOffset
        let expectedShift = view.x(at: 30.375) - view.x(at: 30.25)
        store.recordBrowsePosition(position: 30.375, item: store.visibleItems[30])
        coordinator.update(view, reduceMotion: true, dark: true)
        try check(expectedShift > 0 && abs(view.scrollOffset - previous - expectedShift) < 0.001 && view.activeIndex == 0,
                  "80 张同日照片之间压缩刻度仍不间断移动")
        for zoom in [64.0, 130, 280, 180] {
            store.setBrowseTimelineSize(zoom); coordinator.update(view, reduceMotion: true, dark: true)
            try check(abs(view.position - 30.375) < 0.001
                      && view.visibleDateLabels.allSatisfy({ $0.x == $0.yearX })
                      && view.entries.indices.allSatisfy({ view.span(for: $0) > 0 })
                      && abs((view.position(at: CGPoint(x: view.x(at: 40.625), y: 25)) ?? -1) - 40.625) < 0.001
                      && zip(view.visibleDateLabels, view.visibleDateLabels.dropFirst()).allSatisfy({ $0.1.x - $0.0.x >= 84 }),
                      "日期轴缩放 \(Int(zoom)) 保留连续位置并避让日期和年份")
        }
        store.setBrowseTimelineSize(64); coordinator.update(view, reduceMotion: true, dark: true)
        try check(view.entries.map(\.itemCount) == [82, 1] && view.span(for: 0) > view.span(for: 1)
                  && view.span(for: 0) / view.span(for: 1) <= 1.501,
                  "82 张的月份只适度加长，不因文件数量拉成 82 倍")
        store.setBrowseTimelineSize(180); coordinator.update(view, reduceMotion: true, dark: true)
        coordinator.navigate(toPosition: 82); coordinator.update(view, reduceMotion: true, dark: true)
        try check(view.activeIndex == 2 && view.entries[2].year == "2025"
                  && view.visibleDateLabels.contains(where: { $0.index == 2 && $0.yearX == view.bounds.midX }),
                  "跨年后当前年份跟随对应日期，绝不沿用可见范围首个年份")
        // Twelve populated months stay within a small number of viewports,
        // including a month with thousands of files.
        var annual: [MediaItem] = []
        for monthOffset in 0..<13 {
            let shot = calendar.date(byAdding: .month, value: -monthOffset,
                                     to: calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!)!
            for index in 0..<(monthOffset == 0 ? 2_000 : 2) {
                annual.append(MediaItem(url: directory.appendingPathComponent("annual-\(monthOffset)-\(index).jpg"),
                                        kind: .image, fileSize: 0, modifiedDate: shot, createdDate: shot))
            }
        }
        store.items = annual; store.applyFilters(); store.setBrowseTimelineSize(180)
        coordinator.update(view, reduceMotion: true, dark: true)
        let lastDate = view.entries[12].firstItemIndex
        let annualDistance = view.x(at: Double(lastDate)) - view.x(at: 0)
        try check(annualDistance > 0 && annualDistance < view.bounds.width * 2,
                  "横卷日期尺跨一年仅约两屏距离，千张拍摄日不会撑爆时间轴")
        coordinator.navigate(toPosition: 0); coordinator.update(view, reduceMotion: true, dark: true)
        view.scrollWheel(with: wheel(vertical: -Int32(annualDistance - 120), precise: true))
        coordinator.update(view, reduceMotion: true, dark: true)
        let previousYearX = view.x(at: Double(lastDate))
        try check(view.bounds.minX...view.bounds.maxX ~= previousYearX,
                  "一次紧凑滚动后去年日期进入可点击视口")
        view.selectDate(at: CGPoint(x: previousYearX, y: 25))
        coordinator.update(view, reduceMotion: true, dark: true)
        try check(view.activeIndex == 12 && store.browseIndex == lastDate && view.entries[12].year == "2025",
                  "压缩日期尺可点击去年日期并保持正确媒体和年份")
        let alternating = [unequal[0], unequal[80], unequal[1]].enumerated().map { index, item in
            MediaItem(url: directory.appendingPathComponent("run-\(index).jpg"), kind: .image,
                      fileSize: 0, modifiedDate: item.modifiedDate, createdDate: item.createdDate)
        }
        store.items = alternating; store.sort = .name; store.descending = false
        store.visibleItems = alternating; store.visibleRevision += 1
        coordinator.update(view, reduceMotion: true, dark: true)
        try check(view.entries.count == 3 && coordinator.sectionByItem == [0, 1, 2]
                  && view.entries.map(\.firstItemIndex) == [0, 1, 2],
                  "非日期排序中重复日期按连续段映射，范围不重叠也不错误跳转")
        view.stop(); withExtendedLifetime(window) { }
    }

    @MainActor private static func checkNativeActivation(directory: URL, date: Date) async throws {
        let store = AppStore(directory: directory.appendingPathComponent("ActivationCatalog"))
        let items = (0..<6).map { index in
            MediaItem(url: directory.appendingPathComponent("activation-\(index).jpg"), kind: .image,
                      fileSize: 0, modifiedDate: date, createdDate: date,
                      pixelWidth: index == 1 ? 400 : 1_600, pixelHeight: 1_200)
        }
        store.items = items; store.sort = .name; store.descending = false; store.layout = .browse
        let hosting = NSHostingView(rootView: album(store: store))
        hosting.sizingOptions = []; hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        await settle(window)
        guard let scroll: BrowseScrollView = descendant(of: hosting),
              let collection = scroll.documentView as? BrowseCollectionView,
              let layout = collection.collectionViewLayout as? BrowseAlbumLayout else {
            throw CheckError.failed("真实卷轴激活检查缺少原生容器")
        }
        layout.prepare()
        var clock: TimeInterval = 1
        func sendClick(at point: CGPoint, flags: NSEvent.ModifierFlags = [], count: Int = 1,
                       timestamp: TimeInterval? = nil) {
            clock = timestamp ?? (clock + 0.01)
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags, timestamp: clock,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: count, pressure: 1)!
            collection.mouseDown(with: event)
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: flags, timestamp: clock + 0.001,
                                       windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 1, clickCount: count, pressure: 0)!
            collection.mouseUp(with: up)
        }
        func click(_ index: Int, flags: NSEvent.ModifierFlags = [], count: Int = 1) async throws {
            _ = try center(index, layout: layout, scroll: scroll)
            await settle(window)
            guard let rect = layout.frame(at: index) else { throw CheckError.failed("缺少卷轴照片布局") }
            sendClick(at: collection.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), flags: flags, count: count)
            hosting.rootView = album(store: store)
            await settle(window)
        }
        func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: "",
                                        charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
            collection.keyDown(with: event)
        }
        store.showInspector = false
        try await click(0)
        guard let firstCell = collection.item(at: IndexPath(item: 0, section: 0)) as? BrowseCollectionItem else {
            throw CheckError.failed("卷轴缺少首击照片单元")
        }
        try check(!window.isVisible && store.previewID == nil && store.selectedIDs == [items[0].id]
                  && store.showInspector && firstCell.view.isAccessibilitySelected(),
                  "真实卷轴单击选中并显示信息与选中标记，窗口始终隐藏")
        try await click(1, flags: [.command, .shift])
        try check(store.selectedIDs == [items[1].id] && store.previewID == nil,
                  "卷轴普通浏览点击另一项始终替换单选")
        try await click(1, count: 2)
        try check(store.previewID == items[1].id && store.selectedIDs == [items[1].id],
                  "卷轴真实双击打开当前文件并保留首击单选")
        store.closePreview()
        key(124)
        try check(store.selectedIDs == [items[2].id] && store.keyboardCursor == items[2].id,
                  "卷轴普通方向键同步单选和右侧信息")
        key(53)
        try check(store.selectedIDs.isEmpty && store.previewID == nil && !store.isSelectionMode,
                  "卷轴普通 Escape 清除单选且不进入多选")
        key(49)
        try check(store.previewID == items[2].id && store.selectedIDs.isEmpty,
                  "卷轴普通空格显式打开且不额外建立选择")
        store.closePreview()

        store.setSelectionMode(true)
        hosting.rootView = album(store: store); await settle(window)
        try await click(0); try await click(1)
        try check(store.selectedIDs == Set([items[0].id, items[1].id]) && store.previewID == nil,
                  "卷轴选择模式普通点击逐项累加")
        try await click(1, count: 2)
        try check(store.selectedIDs.count == 2 && store.previewID == items[1].id,
                  "卷轴选择模式双击打开且第二击不重复反选")
        store.closePreview()
        try await click(1)
        try check(store.selectedIDs == [items[0].id], "卷轴选择模式重复单击取消当前项")
        try await click(1, count: 2)
        try check(store.previewID == items[1].id && store.selectedIDs == [items[0].id],
                  "卷轴已选项首击移除后双击打开保留移除结果")
        store.closePreview()
        store.setSelectionMode(false); store.setSelectionMode(true)
        try await click(0); try await click(3, flags: [.shift])
        let selected = Set(items[0...3].map(\.id))
        try check(store.selectedIDs == selected && store.selectionAnchor == items[0].id,
                  "卷轴 Shift 单击按真实顺序扩展范围")
        key(124)
        try check(store.keyboardCursor == items[4].id && store.selectedIDs == selected,
                  "卷轴普通方向键移动焦点且保留明确多选")
        key(36)
        store.stepPreview(1)
        try check(store.previewID == items[5].id && store.selectedIDs == selected,
                  "卷轴 Return 打开及预览切图保留多选")
        store.closePreview()
        let cursor = store.keyboardCursor
        key(53)
        try check(!store.isSelectionMode && store.selectedIDs.isEmpty && store.selectionAnchor == nil
                  && store.keyboardCursor == cursor,
                  "卷轴 Escape 退出选择并保留浏览焦点")
        key(49)
        try check(store.previewID == items[5].id && store.selectedIDs.isEmpty,
                  "卷轴默认空格打开当前项目而不选择")
        store.closePreview()
        store.focus(items[0])
        hosting.rootView = album(store: store); await settle(window)
        guard let cell = collection.item(at: IndexPath(item: 0, section: 0)) as? BrowseCollectionItem,
              let accessible = cell.view as? BrowseAccessiblePhoto else {
            throw CheckError.failed("卷轴缺少真实辅助功能照片单元")
        }
        store.showInspector = false
        try check(accessible.accessibilityPerformPress() && store.previewID == nil && store.selectedIDs == [items[0].id]
                  && store.showInspector,
                  "卷轴辅助功能默认按压选中并打开右侧信息")
        try check(accessible.accessibilityCustomActions()?.contains(where: { $0.name == "打开" }) == true
                  && accessible.openPhoto() && store.previewID == items[0].id && store.selectedIDs == [items[0].id],
                  "卷轴辅助功能提供明确打开操作且保留单选")
        store.closePreview(); store.setSelectionMode(true)
        hosting.rootView = album(store: store); await settle(window)
        try check(cell.view.accessibilityPerformPress() && store.selectedIDs == [items[0].id] && store.previewID == nil,
                  "卷轴辅助功能在选择模式切换单项")
        store.setSelectionMode(false)
        try await click(0)
        guard let first = layout.frame(at: 0) else { throw CheckError.failed("卷轴缺少空白布局") }
        sendClick(at: collection.convert(CGPoint(x: first.minX - 8, y: first.midY), to: nil))
        try check(store.selectedIDs.isEmpty && store.selectionAnchor == nil && store.previewID == nil,
                  "卷轴普通背景单击清除选中且不打开")

        // Mimic the inspector consuming width between the two real mouse-downs.
        // The unchanged window point now hits a different photo; the first
        // click's identity must still win, without allowing stale identities.
        window.setContentSize(NSSize(width: 900, height: 500)); await settle(window)
        _ = try center(1, layout: layout, scroll: scroll); await settle(window)
        guard let original = layout.frame(at: 1) else { throw CheckError.failed("卷轴缺少双击布局") }
        let originalPoint = collection.convert(CGPoint(x: original.midX, y: original.midY), to: nil)
        sendClick(at: originalPoint)
        let firstTimestamp = clock
        window.setContentSize(NSSize(width: 500, height: 500))
        hosting.rootView = album(store: store); await settle(window); layout.prepare()
        let movedHit = collection.indexPathForItem(at: collection.convert(originalPoint, from: nil))
        sendClick(at: originalPoint, count: 2, timestamp: firstTimestamp + 0.05)
        try check(movedHit?.item != 1 && store.previewID == items[1].id && store.selectedIDs == [items[1].id],
                  "卷轴首击显示信息后重排同坐标命中变化，第二击仍打开原文件")
        store.closePreview()

        window.setContentSize(NSSize(width: 900, height: 500)); await settle(window)
        _ = try center(0, layout: layout, scroll: scroll); await settle(window)
        guard let fresh = layout.frame(at: 0) else { throw CheckError.failed("卷轴缺少失效双击布局") }
        let freshPoint = collection.convert(CGPoint(x: fresh.midX, y: fresh.midY), to: nil)
        sendClick(at: freshPoint)
        store.visibleRevision += 1
        hosting.rootView = album(store: store); await settle(window)
        sendClick(at: freshPoint, count: 2)
        try check(store.previewID == nil, "卷轴可见内容版本改变后旧双击不能打开过期文件")
        sendClick(at: freshPoint)
        store.setSelectionMode(true); store.setSelectionMode(false)
        sendClick(at: freshPoint, count: 2)
        try check(store.previewID == nil && store.selectedIDs.isEmpty,
                  "卷轴退出重进选择后旧双击身份失效")
        sendClick(at: freshPoint)
        let expiredTimestamp = clock + NSEvent.doubleClickInterval + 0.1
        sendClick(at: freshPoint, count: 2, timestamp: expiredTimestamp)
        try check(store.previewID == nil, "卷轴超过系统双击间隔后不能打开旧目标")
        sendClick(at: freshPoint)
        scroll.scrollWheel(with: wheel(vertical: -1))
        sendClick(at: freshPoint, count: 2)
        try check(store.previewID == nil, "卷轴首击后滚轮导航取消旧双击目标")
    }

    @MainActor private static func checkNativeStrokes(directory: URL, date: Date) async throws {
        let catalog = directory.appendingPathComponent("StrokeCatalog", isDirectory: true)
        let items = (0..<100).map { index in
            MediaItem(url: directory.appendingPathComponent(String(format: "stroke-%03d.jpg", index)), kind: .image,
                      fileSize: 0, modifiedDate: date, createdDate: date, pixelWidth: 1_200, pixelHeight: 1_200)
        }
        try CatalogPersistence(directory: catalog).save(CatalogState(cachedItems: items))
        let store = AppStore(directory: catalog)
        store.sort = .name; store.descending = false; store.layout = .browse; store.setSelectionMode(true)
        let hosting = NSHostingView(rootView: album(store: store))
        // Three viewport-height square photos must fit for the stroke path to
        // stay inside the window; actual edge autoscrolling is checked below.
        hosting.sizingOptions = []; hosting.frame = NSRect(x: 0, y: 0, width: 2_400, height: 500)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 2_400, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        await settle(window)
        guard let scroll: BrowseScrollView = descendant(of: hosting),
              let collection = scroll.documentView as? BrowseCollectionView,
              let layout = collection.collectionViewLayout as? BrowseAlbumLayout,
              let first = layout.frame(at: 0), let third = layout.frame(at: 2), let preserved = items.last else {
            throw CheckError.failed("缺少拖过选择的真实卷轴布局")
        }
        let start = CGPoint(x: first.midX, y: first.midY), end = CGPoint(x: third.midX, y: third.midY)
        let expected = Set(items.prefix(3).map(\.id)).union([preserved.id])
        func send(_ type: NSEvent.EventType, _ point: CGPoint, flags: NSEvent.ModifierFlags = []) {
            let event = NSEvent.mouseEvent(with: type, location: collection.convert(point, to: nil), modifierFlags: flags,
                                          timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            switch type {
            case .leftMouseDown: collection.mouseDown(with: event)
            case .leftMouseDragged: collection.mouseDragged(with: event)
            default: collection.mouseUp(with: event)
            }
        }
        func reset() async {
            store.setSelectionMode(false); store.setSelectionMode(true)
            store.select(preserved); store.focus(items[0])
            hosting.rootView = album(store: store)
            await settle(window)
        }
        await reset()
        send(.leftMouseDown, start); send(.leftMouseDragged, end)
        let originDuringStroke = scroll.contentView.bounds.origin
        hosting.rootView = album(store: store); await settle(window)
        try check(store.selectedIDs == expected && collection.isSelectionStrokeActive && store.previewID == nil
                  && scroll.contentView.bounds.origin == originDuringStroke,
                  "卷轴快速拖过三项补选中间照片并保留原选择，更新时不自动居中")
        send(.leftMouseDragged, start); send(.leftMouseDragged, end); send(.leftMouseUp, end)
        try check(store.selectedIDs == expected && !collection.isSelectionStrokeActive && store.previewID == nil,
                  "卷轴回扫不反选且松手不取消起点或打开预览")
        send(.leftMouseDown, start); send(.leftMouseDragged, end); send(.leftMouseUp, end)
        try check(store.selectedIDs == expected, "卷轴从已选照片开始拖过仍保留已选项")
        await reset()
        send(.leftMouseDown, start, flags: [.shift]); send(.leftMouseDragged, end); send(.leftMouseUp, end)
        try check(store.selectedIDs == expected,
                  "卷轴 Shift 起拖恢复按下前快照且只选择经过照片")
        await reset()
        send(.leftMouseDown, start); send(.leftMouseUp, end)
        try check(store.selectedIDs == expected && !collection.isSelectionStrokeActive && store.previewID == nil,
                  "卷轴未收到拖动事件时松手位移仍补全快速轨迹")
        await reset()
        send(.leftMouseDown, CGPoint(x: first.minX - 8, y: first.midY))
        send(.leftMouseDragged, end); send(.leftMouseUp, end)
        try check(store.selectedIDs == expected && store.previewID == nil, "卷轴从空白起拖也累加真正经过的照片")

        await reset()
        send(.leftMouseDown, start); send(.leftMouseDragged, end)
        store.setSelectionMode(false)
        send(.leftMouseDragged, start); send(.leftMouseUp, start)
        try check(store.selectedIDs.isEmpty && !collection.isSelectionStrokeActive && !collection.isSelectionAutoscrolling
                  && store.previewID == nil, "卷轴退出选择取消旧轨迹和自动滚动")
        store.setSelectionMode(true)
        send(.leftMouseDown, start); send(.leftMouseDragged, end)
        store.setSelectionMode(false); store.setSelectionMode(true)
        send(.leftMouseDragged, start); send(.leftMouseUp, start)
        try check(store.selectedIDs.isEmpty && !collection.isSelectionStrokeActive && !collection.isSelectionAutoscrolling,
                  "同一轮退出并重进选择不能复活旧卷轴轨迹")
        send(.leftMouseDown, start)
        let beforeRevision = store.selectedIDs
        store.visibleRevision += 1
        send(.leftMouseDragged, end); send(.leftMouseUp, end)
        try check(store.selectedIDs == beforeRevision && !collection.isSelectionStrokeActive && store.previewID == nil,
                  "卷轴内容版本改变后过期轨迹不能继续选择")
        store.setSelectionMode(false)
        send(.leftMouseDown, CGPoint(x: first.minX - 8, y: first.midY))
        send(.leftMouseDragged, end); send(.leftMouseUp, end)
        try check(store.selectedIDs.isEmpty && store.previewID == nil && !collection.isSelectionStrokeActive,
                  "普通浏览从空白拖过不会启动卷轴选择或打开照片")

        await reset()
        let clip = scroll.contentView
        send(.leftMouseDown, start)
        let edge = CGPoint(x: clip.bounds.maxX - 2, y: first.midY)
        send(.leftMouseDragged, edge)
        let beforeFrame = clip.bounds.minX
        let moved = collection.advanceSelectionAutoscrollFrame()
        try check(moved && clip.bounds.minX > beforeFrame && collection.isSelectionAutoscrolling,
                  "卷轴边缘拖选实际单帧向后滚动")
        let maximum = max(0, collection.bounds.width - clip.bounds.width)
        clip.scroll(to: NSPoint(x: maximum, y: 0)); scroll.reflectScrolledClipView(clip)
        let movedPastEnd = collection.advanceSelectionAutoscrollFrame()
        try check(!movedPastEnd && abs(clip.bounds.minX - maximum) < 1 && !collection.isSelectionAutoscrolling,
                  "卷轴自动滚动到末端停止且不越界")
        send(.leftMouseUp, CGPoint(x: clip.bounds.maxX - 2, y: first.midY))
        await reset()
        send(.leftMouseDown, start); send(.leftMouseDragged, CGPoint(x: clip.bounds.maxX - 2, y: first.midY))
        send(.leftMouseUp, CGPoint(x: clip.bounds.maxX - 2, y: first.midY))
        let stoppedOrigin = clip.bounds.origin
        let movedAfterUp = collection.advanceSelectionAutoscrollFrame()
        try await Task.sleep(for: .milliseconds(40))
        try check(!movedAfterUp && !collection.isSelectionStrokeActive && !collection.isSelectionAutoscrolling
                  && clip.bounds.origin == stoppedOrigin && !window.isVisible,
                  "卷轴松手后计时滚动停止且检查窗口始终隐藏")
    }

    @MainActor private static func album(store: AppStore, showNames: Bool = false) -> ContinuousPhotoAlbum {
        ContinuousPhotoAlbum(store: store, showNames: showNames, effects: false,
                             reduceMotion: true, selectionMode: store.isSelectionMode)
    }

    @MainActor private static func checkQueuedCenterCancelledOnMouseDown(directory: URL, date: Date) async throws {
        let catalog = directory.appendingPathComponent("QueuedCenterCatalog", isDirectory: true)
        let items = (0..<20).map { index in
            MediaItem(url: directory.appendingPathComponent(String(format: "queued-%02d.jpg", index)), kind: .image,
                      fileSize: 0, modifiedDate: date, createdDate: date, pixelWidth: 1_200, pixelHeight: 1_200)
        }
        try CatalogPersistence(directory: catalog).save(CatalogState(cachedItems: items))
        let store = AppStore(directory: catalog)
        store.sort = .name; store.descending = false; store.layout = .browse; store.setSelectionMode(true)
        // Wire the actual native types to their production coordinator. Direct
        // access to update() lets this test queue centering and press in the
        // very same event-loop turn, without adding test hooks to application UI.
        let coordinator = ContinuousPhotoAlbum.Coordinator(store: store)
        let scroll = BrowseScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true; scroll.store = store
        let collection = BrowseCollectionView()
        collection.autoresizingMask = [.height]; collection.isSelectable = false; collection.store = store
        collection.collectionViewLayout = BrowseAlbumLayout()
        collection.register(BrowseCollectionItem.self, forItemWithIdentifier: .init("album-photo"))
        collection.dataSource = coordinator; collection.delegate = coordinator
        collection.onSelectionChange = { [weak coordinator] in coordinator?.refreshVisibleCells() }
        scroll.onUserScroll = { [weak coordinator] in coordinator?.beginUserScroll() }
        scroll.onViewportChange = { [weak coordinator] in coordinator?.viewportChanged() }
        scroll.documentView = collection; coordinator.collection = collection; coordinator.scroll = scroll
        coordinator.observe(scroll.contentView)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer {
            collection.cancelSelectionStroke(); coordinator.stop()
            collection.dataSource = nil; collection.delegate = nil
            scroll.onUserScroll = nil; scroll.onViewportChange = nil; window.contentView = nil
        }
        await settle(window)
        func update() { coordinator.update(showNames: false, effects: false, reduceMotion: true, selectionMode: true) }
        update(); await settle(window)
        let initialOrigin = scroll.contentView.bounds.origin
        store.focus(items[15]); update(); await settle(window)
        guard scroll.contentView.bounds.minX > initialOrigin.x + 500 else {
            throw CheckError.failed("排队居中检查夹具没有建立真实远项滚动范围")
        }
        store.focus(items[0]); update(); await settle(window)
        guard let layout = collection.collectionViewLayout as? BrowseAlbumLayout, let first = layout.frame(at: 0) else {
            throw CheckError.failed("排队居中检查缺少首项布局")
        }
        let originBeforePress = scroll.contentView.bounds.origin
        let point = collection.convert(CGPoint(x: first.midX, y: first.midY), to: nil)
        store.focus(items[15]); update() // Queues an async center; deliberately do not yield.
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        collection.mouseDown(with: down)
        await settle(window)
        try check(scroll.contentView.bounds.origin == originBeforePress && collection.isSelectionGestureActive
                  && !collection.isSelectionStrokeActive && store.selectedIDs == [items[0].id]
                  && store.previewID == nil && !window.isVisible,
                  "卷轴按下即取消已排队居中，阈值前保留视口与待拖手势")
    }
    @MainActor private static func settle(_ window: NSWindow) async {
        for _ in 0..<4 {
            window.contentView?.layoutSubtreeIfNeeded()
            await Task.yield()
        }
    }
    @MainActor private static func descendant<T: NSView>(of view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match: T = descendant(of: child) { return match }
        }
        return nil
    }
    @MainActor private static func center(_ index: Int, layout: BrowseAlbumLayout, scroll: NSScrollView) throws -> CGFloat {
        guard let frame = layout.frame(at: index) else { throw CheckError.failed("缺少第 \(index) 项布局") }
        let maximum = max(0, (scroll.documentView?.bounds.width ?? 0) - scroll.contentSize.width)
        let point = NSPoint(x: min(maximum, max(0, frame.midX - scroll.contentSize.width / 2)), y: 0)
        scroll.contentView.scroll(to: point); scroll.reflectScrolledClipView(scroll.contentView)
        return scroll.contentView.bounds.minX
    }
    private static func wheel(vertical: Int32 = 0, horizontal: Int32 = 0, precise: Bool = false, command: Bool = false) -> NSEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                            wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)!
        if precise { event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
        if command { event.flags.insert(.maskCommand) }
        return NSEvent(cgEvent: event)!
    }
    @MainActor private static func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        guard condition() else { throw CheckError.failed(description) }
        passed += 1
        print("PASS \(description)")
    }
}
