import AppKit
@preconcurrency import AVFoundation
import FilmboxCore
import Foundation
import Observation
import SwiftUI
@testable import Filmbox

// Compiled with the real MediaGrid.swift, including its private layout and AX
// views. Every event is delivered directly to the hidden native responder.
@main
private struct GridSelectionChecks {
    private enum CheckError: Error { case failed(String) }
    private final class ObservationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func invalidate() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
    private struct GridModeSwitchFixture: View {
        let store: AppStore
        var body: some View {
            if store.layout == .grid { MediaGrid(store: store) }
            else { Color.clear }
        }
    }
    @MainActor private static var passed = 0

    @MainActor static func main() async {
        do { try await run() }
        catch { print("FAIL \(error)"); exit(EXIT_FAILURE) }
    }

    @MainActor private static func run() async throws {
        _ = NSApplication.shared
        try checkStrokeGeometry()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Filmbox-GridSelectionChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let items = (0..<8).map { index in
            MediaItem(url: directory.appendingPathComponent("photo-\(index).jpg"), kind: .image,
                      fileSize: 0, modifiedDate: date, createdDate: date,
                      pixelWidth: 1_600, pixelHeight: 1_200)
        }
        try CatalogPersistence(directory: directory).save(CatalogState(cachedItems: items))
        let store = AppStore(directory: directory)
        store.sort = .name; store.descending = false
        store.thumbnailSize = 180
        store.showInspector = false
        let hosting = NSHostingView(rootView: MediaGrid(store: store))
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        await settle(window)
        guard let collection: PhotoCollectionView = descendant(of: hosting),
              let layout = collection.collectionViewLayout as? TemporalCollectionLayout else {
            throw CheckError.failed("真实时间线没有建立原生容器")
        }
        layout.prepare()
        try check(!window.isVisible && !store.isSelectionMode && store.selectedIDs.isEmpty
                  && collection.selectionIndexPaths.isEmpty, "真实网格默认无选择且检查窗口从未显示")

        collection.mouseDown(with: try mouse(.leftMouseDown, item: items[0], layout: layout, collection: collection))
        try check(store.keyboardCursor == items[0].id && store.selectedIDs == [items[0].id]
                  && store.previewID == nil && store.showInspector,
                  "默认按下照片单选并打开右侧信息，保持查看器关闭")
        collection.mouseUp(with: try mouse(.leftMouseUp, item: items[0], layout: layout, collection: collection))
        let selectedCell = try cell(for: items[0], collection: collection)
        try check(store.previewID == nil && store.selectedIDs == [items[0].id]
                  && collection.selectionIndexPaths.count == 1 && selectedCell.isSelected
                  && selectedCell.view.isAccessibilitySelected(),
                  "默认松开单击仅保留轻选中标记，不打开照片")
        try click(items[0], count: 2, layout: layout, collection: collection)
        try check(store.previewID == items[0].id && store.selectedIDs == [items[0].id],
                  "真实双击打开查看器并保留单选信息")
        store.closePreview()

        let backgroundPoint = collection.convert(NSPoint(x: 2, y: 2), to: nil)
        collection.mouseDown(with: mouse(.leftMouseDown, point: backgroundPoint, window: window))
        collection.mouseUp(with: mouse(.leftMouseUp, point: backgroundPoint, window: window))
        try check(store.selectedIDs.isEmpty && collection.selectionIndexPaths.isEmpty && store.previewID == nil,
                  "默认点击背景清空单选且不会进入系统拖框选择")
        try click(items[0], layout: layout, collection: collection)
        collection.keyDown(with: key(124, flags: [.shift], window: window))
        try check(store.keyboardCursor == items[1].id && store.selectedIDs == [items[1].id],
                  "默认网格 Shift 方向键移动单选与当前文件信息")
        collection.selectAll(nil)
        try check(store.selectedIDs == [items[1].id] && collection.selectionIndexPaths.count == 1,
                  "原生全选入口在浏览模式保留单选，不隐式进入多选")

        let firstCell = try cell(for: items[0], collection: collection)
        try check(firstCell.view.accessibilityPerformPress() && store.previewID == nil
                  && store.selectedIDs == [items[0].id] && store.showInspector,
                  "辅助功能默认按压只单选并显示信息")
        try check(firstCell.view.accessibilityPerformPick() && store.selectedIDs == [items[0].id],
                  "辅助功能 Pick 在浏览模式可幂等单选")
        guard let accessibleView = firstCell.view as? AccessiblePhotoView else { throw CheckError.failed("缺少辅助功能照片容器") }
        try check(accessibleView.accessibilityCustomActions()?.contains(where: { $0.name == "打开" }) == true
                  && accessibleView.openPhoto() && store.previewID == items[0].id
                  && store.selectedIDs == [items[0].id], "辅助功能独立打开操作不与默认单选混淆")
        store.closePreview()

        // Opening the inspector changes the content width between two clicks.
        // Keep the second event at the first click's original window position.
        guard let originalFrame = layout.frame(for: items[0].id) else { throw CheckError.failed("缺少重排夹具") }
        let originalPoint = collection.convert(NSPoint(x: originalFrame.maxX - 3, y: originalFrame.midY), to: nil)
        collection.mouseDown(with: mouse(.leftMouseDown, point: originalPoint, window: window))
        collection.mouseUp(with: mouse(.leftMouseUp, point: originalPoint, window: window))
        hosting.frame.size.width = 650
        window.setContentSize(NSSize(width: 650, height: 620))
        await settle(window); layout.prepare()
        let newPath = collection.indexPathForItem(at: collection.convert(originalPoint, from: nil))
        try check(newPath.flatMap { collection.mediaByPath[$0]?.id }.map { $0 != items[0].id } == true,
                  "信息栏变窄夹具在原点击位置确实重排为其他照片")
        collection.mouseDown(with: mouse(.leftMouseDown, point: originalPoint, count: 2, window: window))
        collection.mouseUp(with: mouse(.leftMouseUp, point: originalPoint, count: 2, window: window))
        try check(store.previewID == items[0].id && store.selectedIDs == [items[0].id],
                  "首击后网格重排，原位置第二击仍打开原照片")
        store.closePreview()
        hosting.frame.size.width = 900; window.setContentSize(NSSize(width: 900, height: 620))
        await settle(window); layout.prepare()

        try click(items[0], layout: layout, collection: collection)
        store.visibleRevision += 1
        try click(items[0], count: 2, layout: layout, collection: collection)
        try check(store.previewID == nil, "可见内容版本改变后第二击不会打开过期首击目标")
        try click(items[0], layout: layout, collection: collection)
        store.setSelectionMode(true); store.setSelectionMode(false)
        try click(items[0], count: 2, layout: layout, collection: collection)
        try check(store.previewID == nil && store.selectedIDs.isEmpty,
                  "切换选择模式后第二击不会复活旧首击目标")
        let clickPoint = try mouse(.leftMouseDown, item: items[0], layout: layout, collection: collection).locationInWindow
        collection.mouseDown(with: mouse(.leftMouseDown, point: clickPoint, timestamp: 1, window: window))
        collection.mouseUp(with: mouse(.leftMouseUp, point: clickPoint, timestamp: 1, window: window))
        collection.mouseDown(with: mouse(.leftMouseDown, point: clickPoint, count: 2, timestamp: 3, window: window))
        collection.mouseUp(with: mouse(.leftMouseUp, point: clickPoint, count: 2, timestamp: 3, window: window))
        try check(store.previewID == nil, "超出系统双击间隔的第二击不能打开旧目标")

        store.setSelectionMode(true)
        hosting.rootView = MediaGrid(store: store)
        await settle(window)
        let pickFirst = try cell(for: items[0], collection: collection)
        let pickSecond = try cell(for: items[1], collection: collection)
        try check(pickFirst.view.accessibilityPerformPick() && pickSecond.view.accessibilityPerformPick()
                  && store.selectedIDs == Set([items[0].id, items[1].id])
                  && collection.selectionIndexPaths.count == 2 && store.previewID == nil,
                  "选择模式辅助功能连续 Pick 两项形成多选")
        try check(pickFirst.view.accessibilityPerformPick() && pickSecond.view.accessibilityPerformPick()
                  && store.selectedIDs == Set([items[0].id, items[1].id])
                  && collection.selectionIndexPaths.count == 2,
                  "重复 Pick 已选照片保持幂等且保留其他选择")
        store.setSelectionMode(false); store.setSelectionMode(true)
        hosting.rootView = MediaGrid(store: store)
        await settle(window)
        try click(items[0], layout: layout, collection: collection)
        try click(items[1], layout: layout, collection: collection)
        try check(store.selectedIDs == Set([items[0].id, items[1].id]) && store.previewID == nil
                  && collection.selectionIndexPaths.count == 2,
                  "选择模式普通单击累加两项并同步原生选中状态")
        try click(items[1], count: 2, layout: layout, collection: collection)
        try check(store.selectedIDs.count == 2 && store.previewID == items[1].id,
                  "批量选择双击打开查看器，第二击不重复反选")
        store.closePreview()
        collection.keyDown(with: key(124, window: window))
        try check(store.keyboardCursor == items[2].id && store.selectedIDs == Set([items[0].id, items[1].id])
                  && collection.selectionIndexPaths.count == 2,
                  "选择模式普通方向键只移动光标并保留已有多选")
        collection.keyDown(with: key(49, window: window))
        let spaceAddedFocusedItem = store.selectedIDs == Set([items[0].id, items[1].id, items[2].id])
        collection.keyDown(with: key(49, window: window))
        try check(spaceAddedFocusedItem && store.selectedIDs == Set([items[0].id, items[1].id])
                  && collection.selectionIndexPaths.count == 2 && store.previewID == nil,
                  "空格仅加入或移除新光标项且保留原两项")
        collection.mouseDown(with: try mouse(.leftMouseDown, item: items[1], layout: layout, collection: collection))
        try check(store.selectedIDs.count == 2, "按住已选照片保留批量选择以允许拖动")
        collection.mouseUp(with: try mouse(.leftMouseUp, item: items[1], layout: layout, collection: collection))
        try check(store.selectedIDs == [items[0].id], "松开已选照片才取消该项")

        store.setSelectionMode(false); store.setSelectionMode(true)
        try click(items[0], layout: layout, collection: collection)
        try click(items[3], flags: [.shift], layout: layout, collection: collection)
        let selected = Set(items[0...3].map(\.id))
        try check(store.selectedIDs == selected && store.selectionAnchor == items[0].id,
                  "真实网格 Shift 单击保留锚点并选择连续范围")
        collection.keyDown(with: key(36, window: window))
        store.stepPreview(1)
        try check(store.previewID == items[4].id && store.selectedIDs == selected,
                  "网格 Return 打开与查看器切图不替换原有多选")
        store.closePreview()
        let secondCell = try cell(for: items[1], collection: collection)
        try check(secondCell.view.accessibilityPerformPress() && store.selectedIDs == selected.subtracting([items[1].id]),
                  "辅助功能按压在选择模式切换单项")
        let contextSelection = store.selectedIDs
        let singleMenu = collection.menu(for: try mouse(.rightMouseDown, item: items[6], layout: layout, collection: collection))
        try check(store.selectedIDs == contextSelection && singleMenu?.item(withTitle: "重命名…")?.isEnabled == true,
                  "右键未选照片仅针对该项操作且保留批量选择")
        let batchMenu = collection.menu(for: try mouse(.rightMouseDown, item: items[0], layout: layout, collection: collection))
        try check(store.selectedIDs == contextSelection && batchMenu?.item(withTitle: "重命名…")?.isEnabled == false,
                  "右键已选照片保留多选并使用批量菜单")
        let cursor = store.keyboardCursor
        collection.keyDown(with: key(53, window: window))
        try check(!store.isSelectionMode && store.selectedIDs.isEmpty && store.selectionAnchor == nil
                  && store.keyboardCursor == cursor && collection.selectionIndexPaths.isEmpty,
                  "真实 Escape 退出选择清空勾选并保留浏览焦点")

        store.setSelectionMode(true)
        try click(items[0], layout: layout, collection: collection)
        collection.mouseDown(with: try mouse(.leftMouseDown, item: items[0], layout: layout, collection: collection))
        store.setSelectionMode(false)
        collection.mouseUp(with: try mouse(.leftMouseUp, item: items[0], layout: layout, collection: collection))
        try check(store.selectedIDs.isEmpty && store.previewID == nil, "按下期间退出选择会取消过期鼠标操作")
        try await checkMetadataOnlyRefresh(directory: directory, date: date)
        try await checkCloudMetadataDeltas(directory: directory, date: date)
        try checkDateGroupIncrementalGeometry(directory: directory, date: date)
        try await checkNativeStrokes(directory: directory, date: date)
        try await checkTimelineGeometry(directory: directory, date: date)
        try await checkStableViewportAnchor(directory: directory, date: date)
        try await checkVideoPreview(directory: directory, date: date)
        print("Grid selection checks: \(passed) passed")
    }

    @MainActor private static func checkMetadataOnlyRefresh(directory: URL, date: Date) async throws {
        let catalog = directory.appendingPathComponent("MetadataGridCatalog", isDirectory: true)
        let items = (0..<8).map { index in
            MediaItem(url: directory.appendingPathComponent("metadata-grid-\(index).jpg"), kind: .image,
                      fileSize: 0, modifiedDate: date, createdDate: date)
        }
        try CatalogPersistence(directory: catalog).save(CatalogState(cachedItems: items))
        let store = AppStore(directory: catalog)
        store.sort = .name; store.descending = false; store.thumbnailSize = 180
        store.setSelectionMode(true); store.selectedIDs = [items[0].id, items[1].id]
        let hosting = NSHostingView(rootView: MediaGrid(store: store))
        hosting.sizingOptions = []; hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        await settle(window)
        guard let collection: PhotoCollectionView = descendant(of: hosting),
              let layout = collection.collectionViewLayout as? TemporalCollectionLayout else { throw CheckError.failed("缺少元数据网格夹具") }
        let initialCell = try cell(for: items[0], collection: collection)
        guard let imageHost: NSHostingView<PhotoCell> = descendant(of: initialCell.view),
              let initialFrame = layout.frame(for: items[0].id) else { throw CheckError.failed("缺少元数据图片容器") }
        let initialGeneration = layout.layoutGeneration
        let selection = store.selectedIDs
        let enriched = MediaItem(url: items[0].url, kind: .image, fileSize: 0, modifiedDate: date, createdDate: date,
                                 camera: "Metadata Camera", lens: "Metadata Lens")
        store.items = items.map { $0.id == enriched.id ? enriched : $0 }; store.applyFilters()
        hosting.rootView = MediaGrid(store: store); await settle(window)
        let metadataCell = try cell(for: enriched, collection: collection)
        let metadataHost: NSHostingView<PhotoCell>? = descendant(of: metadataCell.view)
        try check(metadataCell === initialCell && metadataHost === imageHost,
                  "网格仅补全相机元数据时保留原生单元及图片宿主，不重新创建可见照片")
        try check(metadataHost?.rootView.item.camera == "Metadata Camera" && metadataCell.media?.lens == "Metadata Lens",
                  "网格复用单元同步最新元数据而非继续展示旧描述")
        try check(layout.layoutGeneration == initialGeneration && layout.frame(for: enriched.id) == initialFrame
                  && store.selectedIDs == selection && metadataCell.isSelected,
                  "网格非几何元数据更新不重排、不改变轻选中或多选")
        let ratio = enriched.withPreviewAspectRatio(0.55)
        store.items = store.items.map { $0.id == ratio.id ? ratio : $0 }; store.applyFilters()
        hosting.rootView = MediaGrid(store: store); await settle(window); layout.prepare()
        let ratioCell = try cell(for: ratio, collection: collection)
        let ratioHost: NSHostingView<PhotoCell>? = descendant(of: ratioCell.view)
        try check(ratioCell === initialCell && ratioHost === imageHost && ratioHost?.rootView.item.previewAspectRatio == 0.55,
                  "网格补全比例时复用已显示的图片宿主并应用新比例")
        try check(layout.frame(for: ratio.id) != initialFrame && store.selectedIDs == selection
                  && ratioCell.isSelected && !window.isVisible,
                  "网格比例重排生效且多选保留，检查窗口从未显示")
    }

    @MainActor private static func checkCloudMetadataDeltas(directory: URL, date: Date) async throws {
        let accountID = UUID()
        CloudTransferCenter.shared.requireLogin(accountID: accountID)
        defer { CloudTransferCenter.shared.forgetConnection(accountID: accountID) }
        let items = (0..<80).map { index in
            MediaItem(cloud: CloudMediaReference(accountID: accountID, fileID: "delta-\(index)", parentID: "/",
                                                remotePath: String(format: "/delta-%03d.jpg", index), revision: "v1"),
                      kind: .image, fileSize: 0, modifiedDate: date,
                      createdDate: date.addingTimeInterval(Double(index / 4) * 86_400))
        }
        let catalog = directory.appendingPathComponent("CloudDeltaGridCatalog", isDirectory: true)
        try CatalogPersistence(directory: catalog).save(CatalogState(cachedItems: items))
        let store = AppStore(directory: catalog)
        store.sort = .name; store.descending = false; store.thumbnailSize = 180
        store.setSelectionMode(true); store.selectedIDs = [items[0].id]
        let hosting = NSHostingView(rootView: MediaGrid(store: store))
        hosting.sizingOptions = []; hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        await settle(window)
        guard let collection: PhotoCollectionView = descendant(of: hosting),
              let layout = collection.collectionViewLayout as? TemporalCollectionLayout,
              let originalHost: NSHostingView<PhotoCell> = descendant(of: try cell(for: items[0], collection: collection).view) else {
            throw CheckError.failed("缺少云端增量网格夹具")
        }
        let initialCell = try cell(for: items[0], collection: collection)
        let generation = layout.layoutGeneration
        let visibleRevision = store.visibleRevision, timelineRevision = store.timelineRevision
        store.commitCloudMetadata([["id": items[0].id, "revision": "v1", "camera": "Delta Camera"]])
        store.commitCloudMetadata([["id": items[72].id, "revision": "v1", "lens": "Offscreen Lens"]])
        hosting.rootView = MediaGrid(store: store); await settle(window)
        let refreshed = try cell(for: items[0], collection: collection)
        let refreshedHost: NSHostingView<PhotoCell>? = descendant(of: refreshed.view)
        try check(store.visibleRevision == visibleRevision && store.timelineRevision == timelineRevision && layout.layoutGeneration == generation,
                  "真实云元数据提交不递增结构修订，两个合并刷新不重建网格几何")
        try check(refreshed === initialCell && refreshedHost === originalHost && refreshedHost?.rootView.item.camera == "Delta Camera"
                  && collection.mediaByPath.values.contains(where: { $0.id == items[72].id && $0.lens == "Offscreen Lens" }),
                  "网格跨过两批delta仍同步可见与屏外描述，并保留图片宿主")
        let firstFrame = layout.frame(for: items[0].id)
        store.commitCloudMetadata([["id": items[72].id, "revision": "v1", "ratio": 0.45]])
        hosting.rootView = MediaGrid(store: store); await settle(window); layout.prepare()
        try check(layout.lastRebuiltSectionCount == 1 && layout.frame(for: items[0].id) == firstFrame
                  && store.selectedIDs == [items[0].id] && !window.isVisible,
                  "屏外比例补齐仅重排一个日期组，前方照片与选择保持且窗口不显示")
    }

    @MainActor private static func checkDateGroupIncrementalGeometry(directory: URL, date: Date) throws {
        let items = (0..<96).map { index in
            MediaItem(url: directory.appendingPathComponent("relative-\(index).jpg"), kind: .image, fileSize: 0,
                      modifiedDate: date, createdDate: date.addingTimeInterval(Double(index / 8) * 86_400),
                      previewAspectRatio: [0.6, 1.0, 1.5, 2.1][index % 4])
        }
        let sections = TimelineGrouping.sections(for: items, scale: .day, descending: false)
        let layout = TemporalCollectionLayout()
        let collection = NSCollectionView()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 920, height: 620))
        collection.collectionViewLayout = layout; scroll.documentView = collection
        layout.configure(sections: sections, revision: 1, targetHeight: 180, showNames: false)
        layout.prepare()
        func matches(_ expected: TimelineLayout) -> Bool {
            abs(layout.collectionViewContentSize.height - expected.contentHeight) < 0.01
                && expected.sections.allSatisfy { section in
                    section.items.allSatisfy { value in
                        guard let frame = layout.frame(for: value.id) else { return false }
                        return abs(frame.minX - value.frame.minX) < 0.01 && abs(frame.minY - value.frame.minY) < 0.01
                            && abs(frame.width - value.frame.width) < 0.01 && abs(frame.height - value.frame.height) < 0.01
                    }
                }
        }
        let width = Double(scroll.contentSize.width)
        try check(matches(JustifiedTimelineLayout.make(sections: sections, width: width, targetHeight: 180)),
                  "日期组相对坐标的初始几何与完整核心排版逐项一致")
        let changed = items[41].withPreviewAspectRatio(0.24)
        let updated = TimelineGrouping.sections(for: items.map { $0.id == changed.id ? changed : $0 }, scale: .day, descending: false)
        layout.applyMetadata(sections: updated, geometrySections: [5]); layout.prepare()
        try check(layout.lastRebuiltSectionCount == 1 && matches(JustifiedTimelineLayout.make(sections: updated, width: width, targetHeight: 180)),
                  "中间日期组增量重排及后续偏移与完整核心排版逐项一致")
    }

    @MainActor private static func checkTimelineGeometry(directory: URL, date: Date) async throws {
        let catalog = directory.appendingPathComponent("GeometryCatalog", isDirectory: true)
        let items = (0..<46).map { index in
            let day = index < 40 ? 0 : index < 45 ? 1 : 8
            let captured = date.addingTimeInterval(Double(day) * 86_400)
            return MediaItem(url: directory.appendingPathComponent(String(format: "geometry-%03d.jpg", index)), kind: .image,
                             fileSize: 0, modifiedDate: captured, createdDate: captured,
                             pixelWidth: 1_200, pixelHeight: 800)
        }
        try CatalogPersistence(directory: catalog).save(CatalogState(cachedItems: items))
        let store = AppStore(directory: catalog)
        store.descending = false; store.thumbnailSize = 180
        let hosting = NSHostingView(rootView: MediaGrid(store: store))
        hosting.sizingOptions = []; hosting.frame = NSRect(x: 0, y: 0, width: 850, height: 460)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 850, height: 460),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        await settle(window)
        guard let collection: PhotoCollectionView = descendant(of: hosting),
              let scroll = collection.enclosingScrollView,
              let layout = collection.collectionViewLayout as? TemporalCollectionLayout else {
            throw CheckError.failed("缺少真实日期几何布局")
        }
        layout.prepare(); await settle(window)
        try check(layout.dateSpans.count == 3 && layout.dateSpans[0].length > layout.dateSpans[1].length * 4,
                  "日期跨度来自真实照片排布，四十张的一天明显长于五张的一天且空白日期不占等宽刻度")
        try check(zip(layout.dateSpans, layout.dateSpans.dropFirst()).allSatisfy { abs($0.start + $0.length - $1.start) < 0.001 }
                  && abs((layout.dateSpans.last?.start ?? 0) + (layout.dateSpans.last?.length ?? 0)
                         - Double(layout.collectionViewContentSize.height)) < 0.001,
                  "日期跨度连续覆盖原生文档直到末尾")
        let selected = store.selectedIDs, cursor = store.keyboardCursor
        let target = layout.collectionViewContentSize.height * 0.42
        layout.cancelPendingViewportRestore()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle(window)
        let expected = layout.firstVisibleItem(at: scroll.contentView.bounds.minY + 44, viewport: scroll.contentView.bounds)
            .flatMap { collection.mediaByPath[$0.path] }
        try check(store.navigationAnchorID == expected?.id && store.selectedIDs == selected && store.keyboardCursor == cursor,
                  "滚动发布真实可见图片锚点而不篡改单选与键盘焦点")
        try check(abs(store.gridTimelinePosition - Double(scroll.contentView.bounds.minY)) < 1
                  && store.gridDateSpans == layout.dateSpans,
                  "共享时间尺获得真实文档位置与缓存日期跨度")
        let generation = layout.layoutGeneration
        scroll.contentView.scroll(to: NSPoint(x: 0, y: target + 17))
        scroll.reflectScrolledClipView(scroll.contentView); await settle(window)
        try check(layout.layoutGeneration == generation, "纯滚动不重建日期几何映射")
        let anchorItem = items[20]
        guard let frame = layout.frame(for: anchorItem.id) else { throw CheckError.failed("缺少锚点图像") }
        collection.requestScrollToPhoto(anchorItem.id, fraction: 0.6)
        await settle(window)
        let expectedOrigin = max(0, min(frame.minY + frame.height * 0.6 - 44,
                                       layout.collectionViewContentSize.height - scroll.contentView.bounds.height))
        try check(abs(scroll.contentView.bounds.minY - expectedOrigin) < 1 && !collection.hasPendingScroll,
                  "跨模式图片锚点可恢复图片内部比例并在完成后解除待滚动状态")
        collection.requestScroll(to: 129.5); await settle(window)
        try check(abs(scroll.contentView.bounds.minY - 129.5) < 1 && !collection.hasPendingScroll,
                  "时间尺连续定位可精确滚动文档原点")
        store.layout = .browse
        store.recordBrowsePosition(position: 34, item: items[34])
        let rollAnchor = store.navigationAnchorID
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        await settle(window)
        try check(store.navigationAnchorID == rollAnchor,
                  "离开网格后其延迟滚动不能覆盖横向模式当前浏览锚点")
        store.layout = .grid
        hosting.rootView = MediaGrid(store: store)
        await settle(window)
        try check(store.navigationAnchorID == items[34].id && store.scrollTargetID == items[34].id
                  && layout.frame(for: items[34].id)?.intersects(scroll.contentView.bounds) == true,
                  "切回网格先应用横向浏览位置，挂载旧视口不会覆盖新锚点")
        collection.requestScroll(to: .greatestFiniteMagnitude); await settle(window)
        try check(abs(scroll.contentView.bounds.maxY - layout.collectionViewContentSize.height) < 1 && !window.isVisible,
                  "时间尺文档定位钳制边界且原生验收窗口始终保持隐藏")
    }

    @MainActor private static func checkStableViewportAnchor(directory: URL, date: Date) async throws {
        let catalog = directory.appendingPathComponent("StableAnchorCatalog", isDirectory: true)
        let items = (0..<60).map { index in
            MediaItem(url: directory.appendingPathComponent(String(format: "anchor-%03d.jpg", index)), kind: .image,
                      fileSize: 0, modifiedDate: date, createdDate: date,
                      pixelWidth: 1_200, pixelHeight: 800)
        }
        try CatalogPersistence(directory: catalog).save(CatalogState(cachedItems: items))
        let store = AppStore(directory: catalog)
        store.sort = .name; store.descending = false; store.thumbnailSize = 180
        let hosting = NSHostingView(rootView: GridModeSwitchFixture(store: store))
        hosting.sizingOptions = []; hosting.frame = NSRect(x: 0, y: 0, width: 850, height: 460)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 850, height: 460),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        await settle(window)
        guard let initialCollection: PhotoCollectionView = descendant(of: hosting),
              let initialLayout = initialCollection.collectionViewLayout as? TemporalCollectionLayout,
              let firstFrame = initialLayout.frame(for: items[0].id),
              let secondFrame = initialLayout.frame(for: items[1].id) else {
            throw CheckError.failed("缺少跨模式锚点的真实网格")
        }
        try check(abs(firstFrame.minY - secondFrame.minY) < 0.5 && firstFrame.minX < secondFrame.minX,
                  "跨模式回归夹具的目标照片确实是同排非第一项")
        try click(items[1], layout: initialLayout, collection: initialCollection)
        await settle(window)
        try check(store.navigationAnchorID == items[1].id,
                  "普通单击同排第二张后，视口发布保留明确点击目标")
        store.layout = .browse
        await settle(window)
        let detachedCollection: PhotoCollectionView? = descendant(of: hosting)
        try check(store.visibleItems[store.browseIndex].id == items[1].id && detachedCollection == nil,
                  "从网格切到翻阅定位点击的第二张且真实拆卸原网格")
        let target = items[32]
        for round in 1...3 {
            store.recordBrowsePosition(position: 32, item: target)
            store.layout = .grid
            await settle(window)
            guard let collection: PhotoCollectionView = descendant(of: hosting),
                  let layout = collection.collectionViewLayout as? TemporalCollectionLayout,
                  let viewport = collection.enclosingScrollView?.contentView.bounds else {
                throw CheckError.failed("第\(round)次往返没有重新建立真实网格")
            }
            let visible = layout.frame(for: target.id)?.intersects(viewport) == true
            let exactAnchor = store.navigationAnchorID == target.id
            store.layout = .browse
            await settle(window)
            try check(visible && exactAnchor && store.visibleItems[store.browseIndex].id == target.id,
                      "第\(round)次翻阅到网格再回翻阅，始终保留同排目标第33张")
        }
        store.layout = .grid
        await settle(window)
        hosting.frame.size.width = 700
        window.setContentSize(NSSize(width: 700, height: 460))
        await settle(window)
        try check(store.navigationAnchorID == target.id,
                  "窗口几何重排保留显式浏览锚点，不误判为用户滚动")
        guard let collection: PhotoCollectionView = descendant(of: hosting),
              let layout = collection.collectionViewLayout as? TemporalCollectionLayout,
              let scroll = collection.enclosingScrollView else { throw CheckError.failed("缺少重新挂载的网格") }
        let selected = store.selectedIDs, cursor = store.keyboardCursor
        layout.cancelPendingViewportRestore()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle(window)
        try check(store.navigationAnchorID == items[0].id && store.selectedIDs == selected && store.keyboardCursor == cursor,
                  "用户实际滚动后释放旧显式锚点，以新视口首项定位且不改变选择")
        hosting.rootView = GridModeSwitchFixture(store: store)
        await settle(window)
        store.layout = .browse
        await settle(window)
        try check(store.visibleItems[store.browseIndex].id == items[0].id && !window.isVisible,
                  "普通刷新不会用旧键盘焦点重新固定锚点，切换模式跟随最新实际视口")
    }

    @MainActor private static func checkVideoPreview(directory: URL, date: Date) async throws {
        let firstURL = directory.appendingPathComponent("preview-first.mp4")
        try await writeSilentPreview(at: firstURL)
        let secondURL = directory.appendingPathComponent("preview-second.mp4")
        try FileManager.default.copyItem(at: firstURL, to: secondURL)
        let webURL = directory.appendingPathComponent("preview.webm")
        let fixture = URL(fileURLWithPath: "Tests/Fixtures/vp9-opus.webm")
        try FileManager.default.copyItem(at: fixture, to: webURL)
        func media(_ url: URL, kind: MediaKind = .video) -> MediaItem {
            MediaItem(url: url, kind: kind, fileSize: 0, modifiedDate: date, createdDate: date,
                      pixelWidth: 160, pixelHeight: 120, duration: kind == .video ? 1 : nil)
        }
        let first = media(firstURL), second = media(secondURL), web = media(webURL)
        let photo = media(directory.appendingPathComponent("preview-photo.jpg"), kind: .image)
        let missing = media(directory.appendingPathComponent("missing-preview.mp4"))
        let catalog = directory.appendingPathComponent("PreviewCatalog", isDirectory: true)
        try CatalogPersistence(directory: catalog).save(CatalogState(cachedItems: [first, second, photo, web, missing]))
        let store = AppStore(directory: catalog)
        store.thumbnailSize = 180
        let hosting = NSHostingView(rootView: MediaGrid(store: store))
        hosting.sizingOptions = []; hosting.frame = NSRect(x: 0, y: 0, width: 850, height: 460)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 850, height: 460),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        await settle(window)
        guard let collection: PhotoCollectionView = descendant(of: hosting),
              let layout = collection.collectionViewLayout as? TemporalCollectionLayout else {
            throw CheckError.failed("缺少视频预览原生网格")
        }
        let session = GridVideoPreviewSession()
        defer { session.stop() }
        let idleProbe = observePlayback(session)
        for _ in 0..<100 {
            session.update(item: nil, store: store, presented: false)
            session.stop()
        }
        try check(idleProbe.count == 0,
                  "空闲网格重复禁用和停止不会写播放观察状态或触发渲染回路")
        try click(first, layout: layout, collection: collection)
        try check(store.gridPreviewID == first.id && store.previewID == nil && store.selectedIDs == [first.id],
                  "原生单击视频仅请求单元内预览并更新信息，不打开独立播放器")
        session.update(item: first, store: store, presented: true)
        guard let oldPlayer = session.playback.player else { throw CheckError.failed("视频没有建立共享播放器") }
        try check(oldPlayer.isMuted && session.playback.isMuted && session.playback.currentID == first.id,
                  "单元预览在首帧前即设置默认静音")
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !(oldPlayer.currentTime().seconds.isFinite && oldPlayer.currentTime().seconds > 0.1 && session.playback.isPlaying) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CheckError.failed("原生视频预览未推进") }
            try await Task.sleep(for: .milliseconds(20))
        }
        try check(session.playback.isPlaying && oldPlayer.currentTime().seconds > 0.08,
                  "单元预览使用真实解码器推进内容")
        let firstCell = try cell(for: first, collection: collection)
        firstCell.updatePreview(session: session); firstCell.view.layoutSubtreeIfNeeded()
        guard let controls: GridVideoPreviewControls = descendant(of: firstCell.view),
              let pause = controls.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.toolTip == "暂停视频预览" }),
              let sound = controls.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.toolTip == "打开声音" }) else {
            throw CheckError.failed("预览缺少独立暂停与声音控件")
        }
        let selectedBeforeControls = store.selectedIDs
        let controlPoint = firstCell.view.convert(NSPoint(x: controls.frame.midX, y: controls.frame.midY), to: firstCell.view.superview)
        let controlHit = firstCell.view.hitTest(controlPoint)
        try check(controlHit !== firstCell.view && controlHit != nil,
                  "单元声音暂停面板具有独立原生命中目标，不落入父图片手势")
        pause.performClick(nil)
        session.update(item: first, store: store, presented: true)
        try check(!session.playback.isPlaying && oldPlayer.rate == 0 && store.selectedIDs == selectedBeforeControls && store.previewID == nil,
                  "独立暂停控件不触发父选择或双击打开，刷新保留暂停")
        let pausedProbe = observePlayback(session)
        for _ in 0..<100 { session.update(item: first, store: store, presented: true) }
        try check(pausedProbe.count == 0,
                  "相同预览请求重复刷新不写播放状态且保留手动暂停")
        sound.performClick(nil)
        try check(!store.browseVideoMuted && !oldPlayer.isMuted && session.playback.player === oldPlayer
                  && store.selectedIDs == selectedBeforeControls && store.previewID == nil,
                  "独立声音控件解除静音且不重建预览或改变选择")
        try click(second, layout: layout, collection: collection)
        session.update(item: second, store: store, presented: true)
        try check(session.playback.currentID == second.id && session.playback.player !== oldPlayer && oldPlayer.rate == 0
                  && session.playback.player?.isMuted == false,
                  "选择下一视频释放旧解码器且沿用会话声音设置")
        try click(photo, layout: layout, collection: collection)
        session.update(item: photo, store: store, presented: true)
        try check(store.gridPreviewID == nil && session.playback.player == nil && session.playback.currentID == nil,
                  "单击照片立即停止单元视频预览")
        let stoppedProbe = observePlayback(session)
        for _ in 0..<100 { session.stop(); session.update(item: photo, store: store, presented: true) }
        try check(stoppedProbe.count == 0,
                  "真实会话停止后重复停止保持观察状态稳定")
        store.setSelectionMode(true)
        try click(first, layout: layout, collection: collection)
        session.update(item: first, store: store, presented: true)
        try check(store.gridPreviewID == nil && session.playback.player == nil,
                  "批量选择视频不会启播")
        store.setSelectionMode(false); store.activate(first)
        session.update(item: first, store: store, presented: true)
        store.open(first)
        session.update(item: first, store: store, presented: true)
        try check(session.playback.player == nil && store.gridPreviewID == nil && store.previewID == first.id,
                  "打开独立播放器撤销单元预览资格")
        store.closePreview(); store.activate(first)
        session.update(item: first, store: store, presented: true)
        session.update(item: nil, store: store, presented: true)
        try check(session.playback.player == nil && session.playback.currentID == nil,
                  "当前视频滚出可见范围后立即释放预览")
        session.update(item: first, store: store, presented: true)
        session.update(item: first, store: store, presented: false)
        try check(session.playback.player == nil && !session.playback.isPlaying,
                  "应用后台或网格窗口不可见时撤销播放资格")
        store.browseVideoMuted = true; store.activate(web)
        session.update(item: web, store: store, presented: true)
        try check(session.playback.webPlayback != nil && session.playback.player == nil
                  && session.playback.currentID == web.id && session.playback.isMuted,
                  "WebM 单元预览复用兼容播放器并保持首次静音")
        session.stop()
        try check(session.playback.webPlayback == nil && session.playback.currentID == nil && !window.isVisible,
                  "拆卸单元预览会清理兼容会话且检查窗口从未置前")
        store.activate(missing)
        session.update(item: missing, store: store, presented: true)
        let failedProbe = observePlayback(session)
        for _ in 0..<100 { session.update(item: missing, store: store, presented: true) }
        try check(session.playback.failed && failedProbe.count == 0,
                  "失败的视频不会因视图刷新进入自动重试与渲染循环")
    }

    @MainActor private static func observePlayback(_ session: GridVideoPreviewSession) -> ObservationProbe {
        let probe = ObservationProbe()
        withObservationTracking {
            let playback = session.playback
            _ = playback.currentID; _ = playback.player; _ = playback.webPlayback
            _ = playback.isPlaying; _ = playback.isMuted; _ = playback.isReady
            _ = playback.isLoading; _ = playback.failed
        } onChange: { probe.invalidate() }
        return probe
    }

    private static func writeSilentPreview(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 120
        ])
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 120
        ])
        writer.add(input)
        guard writer.startWriting() else { throw CheckError.failed("无法创建静音视频") }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<15 {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !input.isReadyForMoreMediaData {
                guard writer.status != .failed, ProcessInfo.processInfo.systemUptime < deadline else {
                    throw CheckError.failed("静音视频编码超时")
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 160, 120, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess,
                  let buffer else { throw CheckError.failed("无法建立检查视频像素") }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(30 + index * 8), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard pixels.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 15)) else {
                throw CheckError.failed("无法写入检查视频像素")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 15, timescale: 15))
        await writer.finishWriting()
        guard writer.status == .completed else { throw CheckError.failed("静音视频编码失败") }
    }

    @MainActor private static func checkStrokeGeometry() throws {
        var diagonal = MediaSelectionStroke(at: .zero)
        let onLine = CGRect(x: 40, y: 40, width: 20, height: 20)
        let offLine = CGRect(x: 4, y: 80, width: 12, height: 12)
        let crossed = diagonal.advance(to: CGPoint(x: 100, y: 100), candidates: [("on", onLine), ("off", offLine)])
        try check(crossed == ["on"] && diagonal.visitedIDs == ["on"],
                  "轨迹线段只选真正穿过的矩形，排除包围盒内未经过项目")
        var fast = MediaSelectionStroke(at: CGPoint(x: 0, y: 15))
        let candidates = [("a", CGRect(x: 10, y: 10, width: 10, height: 10)),
                          ("b", CGRect(x: 40, y: 10, width: 10, height: 10)),
                          ("c", CGRect(x: 70, y: 10, width: 10, height: 10))]
        try check(fast.advance(to: CGPoint(x: 100, y: 15), candidates: candidates) == ["a", "b", "c"],
                  "一次快速移动跨过中间项目时全部命中")
        try check(fast.advance(to: CGPoint(x: 0, y: 15), candidates: candidates).isEmpty
                  && fast.visitedIDs == ["a", "b", "c"] && fast.lastPoint == CGPoint(x: 0, y: 15),
                  "回扫已走过的项目去重且同步最后轨迹点")
        var stationary = MediaSelectionStroke(at: CGPoint(x: 15, y: 15))
        try check(stationary.advance(to: CGPoint(x: 15, y: 15), candidates: [candidates[0], candidates[0]]) == ["a"]
                  && stationary.visitedIDs == ["a"], "点状起点和重复候选只产生一次选择")
    }

    @MainActor private static func checkNativeStrokes(directory: URL, date: Date) async throws {
        let catalog = directory.appendingPathComponent("StrokeCatalog", isDirectory: true)
        let items = (0..<80).map { index in
            MediaItem(url: directory.appendingPathComponent(String(format: "stroke-%03d.jpg", index)), kind: .image,
                      fileSize: 0, modifiedDate: date, createdDate: date, pixelWidth: 1_200, pixelHeight: 1_200)
        }
        try CatalogPersistence(directory: catalog).save(CatalogState(cachedItems: items))
        let store = AppStore(directory: catalog)
        store.sort = .name; store.descending = false; store.setSelectionMode(true)
        let hosting = NSHostingView(rootView: MediaGrid(store: store))
        hosting.sizingOptions = []; hosting.frame = NSRect(x: 0, y: 0, width: 1_100, height: 480)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1_100, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        await settle(window)
        guard let collection: PhotoCollectionView = descendant(of: hosting),
              let scroll = collection.enclosingScrollView,
              let layout = collection.collectionViewLayout as? TemporalCollectionLayout,
              let firstRect = layout.frame(for: items[0].id) else { throw CheckError.failed("缺少拖过选择的真实网格布局") }
        let row = items.filter { item in layout.frame(for: item.id)?.minY == firstRect.minY }
        guard row.count >= 3, let last = row.last, let lastRect = layout.frame(for: last.id),
              let preserved = items.last else { throw CheckError.failed("夹具首行至少需要三张照片") }
        let start = CGPoint(x: firstRect.midX, y: firstRect.midY)
        let end = CGPoint(x: lastRect.midX, y: lastRect.midY)
        func send(_ type: NSEvent.EventType, _ point: CGPoint, flags: NSEvent.ModifierFlags = []) {
            let event = mouse(type, point: collection.convert(point, to: nil), flags: flags, window: window)
            switch type {
            case .leftMouseDown: collection.mouseDown(with: event)
            case .leftMouseDragged: collection.mouseDragged(with: event)
            default: collection.mouseUp(with: event)
            }
        }
        func reset() async {
            store.setSelectionMode(false); store.setSelectionMode(true)
            store.select(preserved)
            hosting.rootView = MediaGrid(store: store)
            await settle(window)
            // AppKit may reveal the preserved selected item while refreshing
            // native selection. These gestures deliberately exercise row one.
            layout.cancelPendingViewportRestore()
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        await reset()
        send(.leftMouseDown, start); send(.leftMouseDragged, end)
        let expected = Set(row.map(\.id)).union([preserved.id])
        try check(store.selectedIDs == expected && collection.isSelectionStrokeActive && store.previewID == nil,
                  "真实网格一次快速拖动选中途经整行并保留原选择")
        send(.leftMouseDragged, start); send(.leftMouseDragged, end); send(.leftMouseUp, end)
        try check(store.selectedIDs == expected && !collection.isSelectionStrokeActive && store.previewID == nil,
                  "网格回扫不反选且松手不取消起点或打开预览")
        send(.leftMouseDown, start); send(.leftMouseDragged, end); send(.leftMouseUp, end)
        try check(store.selectedIDs == expected, "从已选照片开始拖过仍保持已选项")

        await reset()
        send(.leftMouseDown, start, flags: [.shift]); send(.leftMouseDragged, end); send(.leftMouseUp, end)
        try check(store.selectedIDs == expected,
                  "Shift 起拖恢复按下前选择快照，仅保留真正经过照片")

        await reset()
        send(.leftMouseDown, start); send(.leftMouseUp, end)
        try check(store.selectedIDs == expected && !collection.isSelectionStrokeActive && store.previewID == nil,
                  "网格未收到拖动事件时松手位移仍补全快速轨迹")

        await reset()
        send(.leftMouseDown, CGPoint(x: firstRect.minX - 6, y: firstRect.midY))
        send(.leftMouseDragged, end); send(.leftMouseUp, end)
        try check(store.selectedIDs == expected && store.previewID == nil, "从网格空白开始拖过也只累加经过照片")

        await reset()
        send(.leftMouseDown, start); send(.leftMouseDragged, end)
        store.setSelectionMode(false)
        send(.leftMouseDragged, start); send(.leftMouseUp, start)
        try check(store.selectedIDs.isEmpty && !collection.isSelectionStrokeActive && !collection.isSelectionAutoscrolling
                  && store.previewID == nil, "退出选择取消正在拖过的旧手势与自动滚动")
        store.setSelectionMode(true)
        send(.leftMouseDown, start); send(.leftMouseDragged, end)
        store.setSelectionMode(false); store.setSelectionMode(true)
        send(.leftMouseDragged, start); send(.leftMouseUp, start)
        try check(store.selectedIDs.isEmpty && !collection.isSelectionStrokeActive && !collection.isSelectionAutoscrolling,
                  "同一轮退出并重进选择不能复活旧网格轨迹")
        store.setSelectionMode(true)
        send(.leftMouseDown, start)
        let beforeRevision = store.selectedIDs
        store.visibleRevision += 1
        send(.leftMouseDragged, end); send(.leftMouseUp, end)
        try check(store.selectedIDs == beforeRevision && !collection.isSelectionStrokeActive && store.previewID == nil,
                  "网格内容版本改变后过期轨迹不能继续选中")
        store.setSelectionMode(false)
        send(.leftMouseDown, CGPoint(x: firstRect.minX - 6, y: firstRect.midY))
        send(.leftMouseDragged, end); send(.leftMouseUp, end)
        try check(store.selectedIDs.isEmpty && store.previewID == nil && !collection.isSelectionStrokeActive,
                  "浏览模式从空白拖动不进入选择或误开照片")

        store.setSelectionMode(true)
        hosting.rootView = MediaGrid(store: store); await settle(window)
        send(.leftMouseDown, start, flags: [.option])
        try check(collection.isReferenceDragPending && !collection.isSelectionStrokeActive,
                  "Option 按下进入原文件拖动分支而不启动轨迹选择")
        // Never send a dragged event here: that would create an actual desktop
        // NSDraggingSession, outside these hidden responder checks.
        store.setSelectionMode(false)
        collection.cancelInvalidSelectionGesture()
        send(.leftMouseUp, start, flags: [.option])

        store.setSelectionMode(true)
        hosting.rootView = MediaGrid(store: store); await settle(window)
        let clip = scroll.contentView
        clip.scroll(to: .zero); scroll.reflectScrolledClipView(clip)
        send(.leftMouseDown, start)
        let edge = CGPoint(x: clip.bounds.midX, y: clip.bounds.maxY - 2)
        send(.leftMouseDragged, edge)
        let beforeTick = clip.bounds.minY
        let didScroll = collection.advanceSelectionAutoscrollFrame()
        try check(didScroll && clip.bounds.minY > beforeTick && collection.isSelectionAutoscrolling,
                  "网格边缘拖选实际单帧滚动向下延伸")
        // AppKit rounds the document frame to whole points; the layout keeps
        // subpoint row heights, so use its actual end instead of overshooting it.
        let maximum = max(0, layout.collectionViewContentSize.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: maximum)); scroll.reflectScrolledClipView(clip)
        let movedPastEnd = collection.advanceSelectionAutoscrollFrame()
        try check(!movedPastEnd && abs(clip.bounds.minY - maximum) < 1 && !collection.isSelectionAutoscrolling,
                  "网格自动滚动到边界后停止且不越界")
        send(.leftMouseUp, CGPoint(x: clip.bounds.midX, y: clip.bounds.maxY - 2))
        clip.scroll(to: .zero); scroll.reflectScrolledClipView(clip)
        send(.leftMouseDown, start); send(.leftMouseDragged, CGPoint(x: clip.bounds.midX, y: clip.bounds.maxY - 2))
        send(.leftMouseUp, CGPoint(x: clip.bounds.midX, y: clip.bounds.maxY - 2))
        let stoppedOffset = clip.bounds.origin
        let movedAfterUp = collection.advanceSelectionAutoscrollFrame()
        try await Task.sleep(for: .milliseconds(40))
        try check(!movedAfterUp && !collection.isSelectionStrokeActive && !collection.isSelectionAutoscrolling
                  && clip.bounds.origin == stoppedOffset && !window.isVisible,
                  "网格松手停止自动滚动且后台隐藏窗口始终不显示")
    }

    @MainActor private static func click(_ item: MediaItem, flags: NSEvent.ModifierFlags = [], count: Int = 1,
                                        layout: TemporalCollectionLayout, collection: PhotoCollectionView) throws {
        collection.mouseDown(with: try mouse(.leftMouseDown, item: item, flags: flags, count: count, layout: layout, collection: collection))
        collection.mouseUp(with: try mouse(.leftMouseUp, item: item, flags: flags, count: count, layout: layout, collection: collection))
    }
    @MainActor private static func mouse(_ type: NSEvent.EventType, item: MediaItem, flags: NSEvent.ModifierFlags = [], count: Int = 1,
                                        layout: TemporalCollectionLayout, collection: PhotoCollectionView) throws -> NSEvent {
        guard let rect = layout.frame(for: item.id), let window = collection.window else { throw CheckError.failed("缺少照片布局") }
        return mouse(type, point: collection.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), flags: flags, count: count, window: window)
    }
    @MainActor private static func mouse(_ type: NSEvent.EventType, point: NSPoint, flags: NSEvent.ModifierFlags = [], count: Int = 1,
                                        timestamp: TimeInterval = 0,
                                        window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: timestamp,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
    }
    @MainActor private static func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                        isARepeat: false, keyCode: code)!
    }
    @MainActor private static func cell(for item: MediaItem, collection: PhotoCollectionView) throws -> PhotoCollectionItem {
        guard let path = collection.mediaByPath.first(where: { $0.value.id == item.id })?.key,
              let cell = collection.item(at: path) as? PhotoCollectionItem else { throw CheckError.failed("缺少已实现的照片单元") }
        return cell
    }
    @MainActor private static func settle(_ window: NSWindow) async {
        for _ in 0..<5 { window.contentView?.layoutSubtreeIfNeeded(); await Task.yield() }
    }
    @MainActor private static func descendant<T: NSView>(of view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let match: T = descendant(of: child) { return match } }
        return nil
    }
    @MainActor private static func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        guard condition() else { throw CheckError.failed(description) }
        passed += 1; print("PASS \(description)")
    }
}
