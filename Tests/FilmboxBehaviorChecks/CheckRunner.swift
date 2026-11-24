import AppKit
import Darwin
import FilmboxCore
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Compiles together with the application's actual AppStore; no test copy of its logic.
@main
@MainActor
struct BehaviorCheckRunner {
    @MainActor private final class ObservationProbe { var changed = false }
    static func main() async {
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("普通单击单选并显示信息、显式打开与浏览同步", singleSelectionInspectsBeforeOpening),
            ("显式打开唤起已有查看器，内部切图与单击不唤起", explicitOpenRequestsViewerPresentation),
            ("选择模式单击切换与 Shift 范围", selectionModeActivationTogglesAndExtends),
            ("退出选择保留焦点且选择模式不落盘", selectionModeExitAndPersistence),
            ("查看器打开与切图保留显式多选", previewNavigationPreservesSelection),
            ("全选只在选择模式生效", selectAllRequiresSelectionMode),
            ("复制选中原文件 URL 且空操作保留独立剪贴板", copySelectedFilesUsesFileReferences),
            ("单击替换、Command 切换和 Shift 连续范围", clickCommandAndShiftSelection),
            ("连续 Shift + 方向键扩展、反向收缩和跨锚点", keyboardRangeExpansionAndContraction),
            ("跨资源库选择、排除子目录及筛选裁剪", folderSelectionSortingAndFiltering),
            ("网格切换翻阅保留当前项目", gridToBrowseRetainsCurrentItem),
            ("双向布局跟随真实视口且保留图片内位置", viewportAnchorSurvivesLayoutChanges),
            ("连续日期导航请求与过期几何保护", continuousTimelineNavigation),
            ("列表视频单击预览与查看器信息相互独立", gridVideoPreviewSelection),
            ("卷轴静音默认开启、会话内保留且不落盘", browseVideoSoundIsSessionOnly),
            ("查看器收藏快捷键只处理当前项目", viewerFavoriteOnlyChangesCurrentItem),
            ("收藏、缓存及退出保存保留最新版本", favoritesAndCachedItemsPersistAfterFlush),
            ("损坏目录恢复保留唯一备份和原始内容", corruptCatalogRecoveryPreservesBackups),
            ("时间线展平顺序及名称、大小组内排序", timelineFlattenAndGroupedSorting),
            ("天周月缩放保留选择、光标和翻阅项目", timelineZoomPreservesInteractionState),
            ("照片卷日期尺度与网格独立、路由及偏好恢复", browseTimelineZoomIsIndependent),
            ("日期跳转请求与媒体选择彼此独立", timelineNavigationDoesNotChangeSelection),
            ("筛选后清理失效日期、光标和查看器焦点", timelineFilteringClearsObsoleteState),
            ("启动立即显示缓存、激活节流及手动强制刷新", startupCacheAndActivationRefreshPolicy),
            ("离线资源库刷新保留历史索引与目录", offlineRefreshPreservesCatalogItems),
            ("全局隐藏、跨范围排除与恢复", hidingIsGlobalAndRestorable),
            ("影集创建、成员维护及持久化", albumLifecycleAndPersistence),
            ("真实重命名迁移索引及全部集合", renameMigratesAllItemReferences),
            ("重命名拒绝冲突、路径穿越及过期原件", renameRejectsUnsafeOrStaleChanges),
            ("重命名取消旧扫描并合并后续刷新", renameCannotResurrectOldScanPaths),
            ("移到系统废纸篓仅移除成功项目", trashPreservesFailedItemsAndUsesSystemTrash),
            ("退出等待文件操作完成并阻止补扫", terminationWaitsForFileOperations),
            ("保存失败保留已移动文件关系、取消退出并重试", failedSavePreservesMovesAndAllowsRetry),
            ("启动只读保护无新更改时仍可退出", protectedStartupCatalogCanQuitWithoutChanges)
        ]
        var failed = 0
        for (name, check) in checks {
            do {
                try await check()
                print("✓ \(name)")
            } catch {
                failed += 1
                print("✗ \(name)：\(error)")
            }
        }
        print("\(checks.count - failed)/\(checks.count) 行为检查通过")
        if failed > 0 { exit(EXIT_FAILURE) }
    }

    private static func singleSelectionInspectsBeforeOpening() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let items = fixture.items
        try expect(!store.isSelectionMode && store.selectedIDs.isEmpty, "新实例应处于无选择的浏览状态")
        store.focus(items[2])
        try expect(store.keyboardCursor == items[2].id && store.visibleItems[store.browseIndex].id == items[2].id,
                   "浏览聚焦应同步光标和当前卷轴项目")
        try expect(store.selectedIDs.isEmpty && store.selectionAnchor == nil && store.previewID == nil,
                   "单纯聚焦不能选择媒体或打开查看器")
        store.select(items[4], modifiers: [.command, .shift])
        try expect(store.keyboardCursor == items[4].id && store.selectedIDs == [items[4].id]
                   && store.showInspector && store.focusedItem?.id == items[4].id && store.previewID == nil,
                   "普通点击只建立单选并显示该文件信息，不受多选修饰影响或打开查看器")
        store.showInspector = false
        store.activate(items[1])
        try expect(store.previewID == nil && store.keyboardCursor == items[1].id && store.selectedIDs == [items[1].id]
                   && store.showInspector && store.focusedItem?.id == items[1].id && !store.isSelectionMode,
                   "单击另一项替换单选并重新打开信息栏，仍不进入查看器")
        store.activate(items[1])
        try expect(store.selectedIDs == [items[1].id] && store.previewID == nil,
                   "重复普通单击不能取消单选或隐式打开")
        store.open(items[1])
        try expect(store.previewID == items[1].id && store.selectedIDs == [items[1].id],
                   "双击或键盘的显式打开入口进入当前文件")
        store.stepPreview(1)
        try expect(store.previewID == items[2].id && store.keyboardCursor == items[2].id && store.selectedIDs == [items[2].id],
                   "普通查看器切图让单选与文件信息跟随当前媒体")
        store.closePreview()
        store.moveSelection(by: 1, extend: true)
        try expect(store.keyboardCursor == items[3].id && store.selectedIDs == [items[3].id] && !store.isSelectionMode,
                   "普通模式方向选择仍为单选，不隐式进入批量模式")
        store.clearSelection()
        try expect(store.selectedIDs.isEmpty && store.focusedItem == nil && store.previewID == nil,
                   "清空单选后不再显示旧文件信息")
    }

    private static func explicitOpenRequestsViewerPresentation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let items = fixture.items
        let initial = store.viewerOpenRequestID
        store.activate(items[0])
        try expect(store.previewID == nil && store.viewerOpenRequestID == initial,
                   "普通单击只能选择，不得请求唤起查看器")
        store.open(items[0])
        try expect(store.previewID == items[0].id && store.viewerOpenRequestID == initial + 1,
                   "首次打开应更新媒体并请求展示查看器")
        store.open(items[1])
        try expect(store.previewID == items[1].id && store.viewerOpenRequestID == initial + 2,
                   "已有查看器打开新图也必须请求置前")
        store.open(items[1])
        try expect(store.previewID == items[1].id && store.viewerOpenRequestID == initial + 3,
                   "同图重复打开也必须发出新的唤起请求")
        store.stepPreview(1)
        store.previewID = items[3].id
        store.focus(items[3])
        store.activate(items[4])
        try expect(store.viewerOpenRequestID == initial + 3,
                   "查看器切图、胶片导航、普通单击不能发出新的唤起请求")
        store.closePreview()
        try expect(store.viewerOpenRequestID == initial + 3, "关闭不能再次唤起查看器")
        store.open()
        try expect(store.previewID == items[4].id && store.viewerOpenRequestID == initial + 4,
                   "关闭后从当前焦点重新打开仍须请求展示")
        store.filter = .video
        store.open(items[0])
        try expect(store.viewerOpenRequestID == initial + 4, "过期不可见目标不能唤起查看器")
        store.filter = .all
        store.query = "不存在的媒体"
        store.open()
        try expect(store.viewerOpenRequestID == initial + 4, "空结果不能产生窗口唤起请求")
    }

    private static func selectionModeActivationTogglesAndExtends() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let items = fixture.items
        store.setSelectionMode(true)
        store.activate(items[1])
        store.activate(items[4])
        try expectIDs(store.selectedIDs, [items[1], items[4]], "选择模式普通点击应逐项添加")
        store.activate(items[1])
        try expectIDs(store.selectedIDs, [items[4]], "再次普通点击应取消该项")
        try expect(store.previewID == nil, "选择模式普通点击不能自动打开查看器")
        store.setSelectionMode(false)
        store.setSelectionMode(true)
        store.activate(items[1])
        store.activate(items[4], modifiers: [.shift])
        try expectIDs(store.selectedIDs, Array(items[1...4]), "选择模式 Shift 应选择包含两端的完整范围")
        try expect(store.selectionAnchor == items[1].id, "Shift 激活应保留固定锚点")
        store.activate(items[5], modifiers: [.command, .shift])
        try expectIDs(store.selectedIDs, Array(items[1...5]), "Command+Shift 应合并现有范围")
    }

    private static func selectionModeExitAndPersistence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let items = fixture.items
        store.focus(items[2])
        store.setSelectionMode(true)
        try expect(store.isSelectionMode && store.selectedIDs.isEmpty && store.keyboardCursor == items[2].id,
                   "进入选择模式不能自动选中已聚焦项目")
        store.activate(items[1]); store.activate(items[4])
        store.setSelectionMode(false)
        try expect(!store.isSelectionMode && store.selectedIDs.isEmpty && store.selectionAnchor == nil
                   && store.keyboardCursor == items[4].id,
                   "退出选择应清空媒体和范围锚点，同时保留浏览焦点")
        store.setSelectionMode(false)
        try expect(store.keyboardCursor == items[4].id, "重复退出不能丢失当前焦点")
        store.setSelectionMode(true)
        store.activate(items[3])
        store.toggleFavorite(items[0])
        let saved = await store.flushImmediately()
        try expect(saved, "选择模式检查未完成真实资料库保存")
        let reopened = fixture.makeStore()
        try expectIDs(reopened.favorites, [items[0]], "应从同一份已保存资料库重建实例")
        try expect(!reopened.isSelectionMode && reopened.selectedIDs.isEmpty && reopened.selectionAnchor == nil,
                   "重开资料库不能恢复选择模式和过期多选")
        try expect(store.isSelectionMode && store.selectedIDs == [items[3].id], "新实例不能修改原会话选择")
    }

    private static func previewNavigationPreservesSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let items = fixture.items
        store.setSelectionMode(true)
        store.select(items[0]); store.select(items[3], modifiers: [.command])
        let selected = store.selectedIDs
        let anchor = store.selectionAnchor
        store.open(items[1])
        try expect(store.previewID == items[1].id && store.selectedIDs == selected && store.selectionAnchor == anchor,
                   "打开未选项目不能改变已有多选或范围锚点")
        store.stepPreview(1)
        try expect(store.previewID == items[2].id && store.keyboardCursor == items[2].id
                   && store.selectedIDs == selected && store.selectionAnchor == anchor,
                   "查看器向后切图不能替换批量选择")
        store.stepPreview(-100)
        try expect(store.previewID == items[0].id && store.selectedIDs == selected,
                   "查看器前进到边界仍需保留原选择")
        store.closePreview()
        try expect(store.selectedIDs == selected && store.isSelectionMode, "关闭查看器不能退出选择模式或清空选择")
    }

    private static func selectAllRequiresSelectionMode() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        store.focus(fixture.items[2])
        store.selectAll()
        try expect(!store.isSelectionMode && store.selectedIDs.isEmpty && store.keyboardCursor == fixture.items[2].id,
                   "浏览模式全选不能启动批量选择或改变焦点")
        store.setSelectionMode(true)
        store.filter = .image
        store.selectAll()
        try expectIDs(store.selectedIDs, [fixture.items[0], fixture.items[1], fixture.items[3], fixture.items[5]],
                      "选择模式应仅全选当前筛选可见项目")
        store.setSelectionMode(false)
        store.selectAll()
        try expect(store.selectedIDs.isEmpty, "退出后全选不能恢复上次选择")
    }

    private static func copySelectedFilesUsesFileReferences() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let targets = [fixture.items[0], fixture.items[3]]
        for item in targets { try writeRefreshFixture(at: item.url) }
        let pasteboard = NSPasteboard(name: .init("com.filmbox.behavior-checks.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("保留原有独立剪贴板内容", forType: .string)
        let initialChange = pasteboard.changeCount
        store.focus(targets[0])
        try expect(!store.copySelectedFiles(to: pasteboard) && pasteboard.changeCount == initialChange,
                   "浏览聚焦不能复制文件或清空剪贴板")
        store.activate(targets[0])
        try expect(store.copySelectedFiles(to: pasteboard), "普通单选也应能复制真实文件引用")
        let singleReference = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? []
        try expect(singleReference.count == 1 && (singleReference[0] as URL).standardizedFileURL == targets[0].url,
                   "普通单选复制必须是该文件的原生 URL")
        let singleChange = pasteboard.changeCount
        store.setSelectionMode(true)
        try expect(!store.copySelectedFiles(to: pasteboard) && pasteboard.changeCount == singleChange,
                   "空选择复制不能清空剪贴板")
        store.select(targets[0]); store.select(targets[1], modifiers: [.command])
        try expect(store.copySelectedFiles(to: pasteboard), "有明确多选时应成功复制文件引用")
        let references = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? []
        try expect(references.count == 2 && Set(references.map { ($0 as URL).standardizedFileURL }) == Set(targets.map(\.url)),
                   "独立剪贴板应读取到两个真实文件 URL")
        try expect(pasteboard.pasteboardItems?.count == 2
                   && pasteboard.pasteboardItems?.allSatisfy { $0.types.contains(.fileURL) } == true,
                   "复制内容必须是文件引用，不能只是拼接后的文本路径")
        let copiedChange = pasteboard.changeCount
        store.setSelectionMode(false)
        try expect(!store.copySelectedFiles(to: pasteboard) && pasteboard.changeCount == copiedChange,
                   "退出选择后的复制不能覆盖已复制文件")
    }

    private static func clickCommandAndShiftSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let items = fixture.items
        store.setSelectionMode(true)
        store.select(items[1])
        try expectIDs(store.selectedIDs, [items[1]], "单击应只选一项")
        store.select(items[4], modifiers: [.command])
        try expectIDs(store.selectedIDs, [items[1], items[4]], "Command 单击应添加一项")
        store.select(items[1], modifiers: [.command])
        try expectIDs(store.selectedIDs, [items[4]], "Command 再次单击应取消该项")

        store.select(items[1])
        store.select(items[4], modifiers: [.shift])
        try expectIDs(store.selectedIDs, Array(items[1...4]), "Shift 应选中包含两端的完整范围")
        try expect(store.selectionAnchor == items[1].id, "Shift 选择应保留原始锚点")
        store.select(items[5], modifiers: [.command])
        store.select(items[3], modifiers: [.command, .shift])
        try expectIDs(store.selectedIDs, Array(items[1...5]), "Command + Shift 应合并范围并保留已有选择")
        store.select(items[0])
        try expectIDs(store.selectedIDs, [items[0]], "普通单击应替换多选")
        store.clearSelection()
        try expect(store.selectedIDs.isEmpty && store.selectionAnchor == nil && store.keyboardCursor == nil, "清除选择应重置锚点和键盘光标")
    }

    private static func keyboardRangeExpansionAndContraction() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        store.setSelectionMode(true)
        let items = fixture.items
        store.select(items[2])
        store.moveSelection(by: 1, extend: true)
        try expectIDs(store.selectedIDs, Array(items[2...3]), "第一次 Shift + 右应扩展一项")
        store.moveSelection(by: 1, extend: true)
        try expectIDs(store.selectedIDs, Array(items[2...4]), "第二次 Shift + 右应继续扩展")
        store.moveSelection(by: -1, extend: true)
        try expectIDs(store.selectedIDs, Array(items[2...3]), "反向移动应收缩，而非保留旧范围")
        store.moveSelection(by: -1, extend: true)
        try expectIDs(store.selectedIDs, [items[2]], "回到锚点应只保留锚点")
        store.moveSelection(by: -1, extend: true)
        try expectIDs(store.selectedIDs, Array(items[1...2]), "越过锚点后应向相反方向扩展")
        try expect(store.selectionAnchor == items[2].id && store.keyboardCursor == items[1].id, "固定锚点与移动光标应彼此独立")
        store.moveSelection(by: -100, extend: true)
        try expectIDs(store.selectedIDs, Array(items[0...2]), "范围移动应停在首项")
        store.moveSelection(by: 1)
        try expectIDs(store.selectedIDs, [items[1]], "普通方向键应退出范围多选")
        store.clearSelection()
        store.moveSelection(by: 1)
        try expectIDs(store.selectedIDs, [items[0]], "无选择时向右应从首项开始")
        store.clearSelection()
        store.moveSelection(by: -1)
        try expectIDs(store.selectedIDs, [items[5]], "无选择时向左应从末项开始")
    }

    private static func folderSelectionSortingAndFiltering() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        store.setSelectionMode(true)
        let items = fixture.items
        store.toggleFolder(fixture.libraries[0].url.path)
        try expectIDs(Set(store.visibleItems.map(\.id)), Array(items[0...2]), "选中资源库应包含其子目录")
        store.toggleFolder(fixture.libraries[1].url.path)
        try expect(store.visibleItems.count == 6, "两个资源库应能同时展示")
        store.toggleFolder(fixture.privateFolder.path)
        try expectIDs(Set(store.visibleItems.map(\.id)), [items[0], items[2], items[3], items[4], items[5]], "排除子目录不应影响另一资源库")
        try expect(store.folderState(fixture.libraries[0].url.path) == .partial, "有排除项的父目录应为部分选择")
        try expect(store.folderState(fixture.libraries[1].url.path) == .all, "平行资源库应保持全选")

        store.selectAll()
        store.filter = .image
        try expectIDs(store.selectedIDs, [items[0], items[3], items[5]], "按类型筛选应裁剪隐藏项的选择")
        store.sort = .size
        store.descending = true
        try expect(store.visibleItems.map(\.id) == [items[5].id, items[3].id, items[0].id], "大小排序应使用真实字节数")
        try expectIDs(store.selectedIDs, [items[0], items[3], items[5]], "排序应保留仍可见的选择")
        store.query = "04"
        try expectIDs(store.selectedIDs, [items[3]], "搜索后应只保留可见的选择")
        store.query = "missing"
        try expect(store.visibleItems.isEmpty && store.selectedIDs.isEmpty, "搜索无结果应清除不可见选择")

        store.query = ""
        store.filter = .all
        store.selectScope(.all)
        try expect(store.visibleItems.count == 6, "全部范围应恢复被排除目录中的项目")
        try expect(store.count(in: fixture.privateFolder.path) == 1, "缓存中的离线子目录应有正确计数")
        store.select(items[4])
        store.filter = .image
        store.open()
        try expect(store.focusedItem?.kind == .image, "过滤掉原键盘焦点后，查看器不能打开隐藏的视频")
        try expect(store.visibleItems.contains { $0.id == store.previewID }, "查看器项目必须属于当前筛选结果")
        store.closePreview()
    }

    private static func viewportAnchorSurvivesLayoutChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let items = fixture.items
        store.setSelectionMode(true)
        store.select(items[0])
        let selection = store.selectedIDs
        let cursor = store.keyboardCursor
        store.updateGridTimeline(spans: [], position: 123.5, totalLength: 2_000,
                                 anchor: items[4], anchorFraction: 0.37)
        try expect(store.keyboardCursor == cursor && store.selectedIDs == selection,
                   "滚动发布视口位置不得改变明确选择与键盘焦点")
        store.layout = .browse
        try expect(store.visibleItems[store.browseIndex].id == items[4].id && store.browsePosition == Double(store.browseIndex),
                   "列表已滚离旧选择时，翻阅须定位正在看的媒体")
        store.layout = .grid
        try expect(store.scrollTargetID == items[4].id && abs(store.scrollTargetFraction - 0.37) < 0.0001,
                   "未移动即返回列表应恢复同一媒体的内部纵向位置")
        store.layout = .browse
        let request = store.browseScrollRequestID
        let index = try require(store.visibleItems.firstIndex { $0.id == items[2].id })
        store.recordBrowsePosition(position: Double(index) + 0.25, item: items[2])
        try expect(store.browsePosition == Double(index) + 0.25 && store.browseScrollRequestID == request,
                   "真实横滚发布连续位置，不反向发出居中请求")
        store.layout = .grid
        try expect(store.scrollTargetID == items[2].id && store.selectedIDs == selection,
                   "翻阅移动后回到列表应定位新媒体，并保留多选")
        store.updateGridTimeline(spans: nil, position: 155, totalLength: 2_000,
                                 anchor: items[1], anchorFraction: 0.2)
        store.layout = .browse
        try expect(store.visibleItems[store.browseIndex].id == items[1].id,
                   "列表继续浏览后再次切换应采用最新视口，不能复用旧翻阅位置")
        store.layout = .grid
        store.setSelectionMode(false)
        store.activate(items[0])
        store.updateGridTimeline(spans: nil, position: 200, totalLength: 2_000,
                                 anchor: items[3], anchorFraction: 0)
        store.layout = .browse
        try expect(store.selectedIDs == [items[3].id] && store.libraryFocusedItem?.id == items[3].id,
                   "普通单选切模式后，信息必须跟随恢复的当前媒体，不能留在旧选择")
    }

    private static func continuousTimelineNavigation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let spans = [TimelineDateSpan(id: "day:one", start: 0, length: 200),
                     TimelineDateSpan(id: "day:many", start: 200, length: 1_800)]
        store.updateGridTimeline(spans: spans, position: 100, totalLength: 2_000,
                                 anchor: fixture.items[0], anchorFraction: 0)
        store.updateGridTimeline(spans: nil, position: 100.5, totalLength: 2_000,
                                 anchor: fixture.items[0], anchorFraction: 0.1)
        try expect(store.gridDateSpans == spans && store.gridTimelinePosition == 100.5,
                   "同日期内部小数位置须连续更新，同时复用已有范围映射")
        let probe = ObservationProbe()
        withObservationTracking {
            _ = store.gridDateSpans; _ = store.gridTimelinePosition
            _ = store.gridTimelineTotalLength; _ = store.navigationAnchorID
        } onChange: { MainActor.assumeIsolated { probe.changed = true } }
        store.updateGridTimeline(spans: nil, position: 100.5, totalLength: 2_000,
                                 anchor: fixture.items[0], anchorFraction: 0.1)
        try expect(!probe.changed, "相同几何回报不能制造SwiftUI更新循环")
        store.updateGridTimeline(spans: nil, position: 101, totalLength: 2_000,
                                 anchor: fixture.items[0], anchorFraction: 0.2)
        try expect(probe.changed, "真实位置改变仍必须通知日期尺更新")
        let request = store.gridTimelineScrollRequestID
        store.navigateGridTimeline(to: 235.25)
        try expect(store.gridTimelineScrollTarget == 235.25 && store.gridTimelineScrollRequestID == request + 1
                   && store.scrollTargetID == nil, "日期尺连续导航应请求真实文档位置，并取代旧媒体跳转")
        store.navigateGridTimeline(to: .nan)
        try expect(store.gridTimelineScrollRequestID == request + 1, "非法位置不能排队滚动")
        store.scroll(toSection: try require(store.timelineSections.first).id)
        try expect(store.gridTimelineScrollTarget == nil && store.scrollTargetFraction == 0,
                   "明确点击日期须清除旧连续尺请求")
        store.layout = .browse
        let current = store.browseIndex
        let before = store.browseScrollRequestID
        store.navigateBrowse(to: 1.25)
        try expect(store.browsePosition == 1.25 && store.browseIndex == 1 && store.browseScrollRequestID == before + 1,
                   "横向尺应保留精确分数位置并仅请求一次居中")
        let spansBefore = store.gridDateSpans
        store.updateGridTimeline(spans: [], position: 0, totalLength: 0, anchor: nil, anchorFraction: 0)
        try expect(store.gridDateSpans == spansBefore, "离开列表后的异步几何不得覆盖当前模式状态")
        store.navigateBrowse(to: .infinity)
        try expect(store.browseScrollRequestID == before + 1 && current >= 0, "非法横轴位置不得产生请求")
    }

    private static func gridVideoPreviewSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let video = try require(fixture.items.first { $0.kind == .video })
        let photo = try require(fixture.items.first { $0.kind == .image })
        store.activate(video)
        try expect(store.gridPreviewID == video.id && store.previewID == nil && store.browseVideoMuted,
                   "列表单击视频应只请求就地预览，初次静音，不打开查看器")
        store.browseVideoMuted = false
        store.activate(photo)
        try expect(store.gridPreviewID == nil && !store.browseVideoMuted, "点击照片停止就地预览并保留会话声音选择")
        store.open(photo)
        store.activate(video)
        try expect(store.gridPreviewID == video.id && store.previewID == photo.id
                   && store.libraryFocusedItem?.id == video.id && store.focusedItem?.id == photo.id,
                   "后台已有查看器时，图库新视频信息和预览须独立于查看器原照片")
        store.open(video)
        try expect(store.gridPreviewID == nil && store.previewID == video.id, "双击进入查看器应结束列表预览")
        store.closePreview()
        store.activate(video)
        store.clearSelection()
        try expect(store.gridPreviewID == nil, "取消选择须停止列表预览")
        store.activate(video)
        store.setSelectionMode(true)
        store.activate(video)
        try expect(store.gridPreviewID == nil, "批量选择不能启动视频")
        store.setSelectionMode(false)
        store.activate(video)
        store.layout = .browse
        try expect(store.gridPreviewID == nil && !store.browseVideoMuted, "切换翻阅结束网格会话且沿用声音偏好")
    }

    private static func gridToBrowseRetainsCurrentItem() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        store.setSelectionMode(true)
        let items = fixture.items
        let previousDate = try require(store.timelineSections.first)
        store.scroll(toSection: previousDate.id)
        let previousDateTarget = store.scrollTargetID
        store.select(items[4])
        store.layout = .browse
        try expect(store.visibleItems[store.browseIndex].id == items[4].id, "切换翻阅应定位网格当前项")
        let browseCurrent = items[2]
        store.browseIndex = try require(store.visibleItems.firstIndex { $0.id == browseCurrent.id })
        let previousRequest = store.scrollRequestID
        store.layout = .grid
        try expect(store.scrollTargetID == browseCurrent.id && store.scrollTargetID != previousDateTarget, "翻阅返回光桌应定位当前翻阅媒体，不能复用旧日期目标")
        try expect(store.scrollRequestID > previousRequest, "重建光桌时应重新发起当前媒体的滚动请求")
        try expectIDs(store.selectedIDs, [items[4]], "翻阅返回定位不应改变原有媒体选择")
        store.select(items[1], modifiers: [.command])
        store.layout = .browse
        try expect(store.visibleItems[store.browseIndex].id == items[1].id, "多选后翻阅应定位最后操作的项目")
        try expectIDs(store.selectedIDs, [items[4], items[1]], "布局切换应保留多选")
        store.layout = .grid
        store.sort = .size
        store.descending = true
        store.layout = .browse
        try expect(store.visibleItems[store.browseIndex].id == items[1].id, "排序后再切翻阅仍应按项目定位")
        store.open()
        try expect(store.previewID == items[1].id, "多选时默认打开最后操作的项目，不能跳回第一个选择")
        store.closePreview()
    }

    private static func browseVideoSoundIsSessionOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        store.setSelectionMode(true)
        try expect(store.browseVideoMuted, "新会话首次播放必须默认静音")
        store.browseVideoMuted = false
        for layout in [AppStore.Layout.browse, .grid, .browse] {
            store.layout = layout
            try expect(!store.browseVideoMuted, "切换布局不能覆盖用户已打开的声音")
        }
        store.filter = .video
        store.select(fixture.items[2])
        try expectIDs(store.selectedIDs, [fixture.items[2]], "视频筛选应确实切换到可见视频")
        try expect(!store.browseVideoMuted, "切换类型和当前视频不能重新静音")
        store.filter = .image
        store.select(fixture.items[0])
        store.select(fixture.items[3], modifiers: [.command])
        store.clearSelection()
        store.filter = .all
        try expect(!store.browseVideoMuted, "筛选、照片多选和清除选择不能改变本次会话声音")

        // Ensure the catalog really receives a new saved state, rather than
        // interpreting an untouched fixture as evidence that mute is transient.
        store.toggleFavorite(fixture.items[0])
        let saved = await store.flushImmediately()
        try expect(saved, "会话检查的临时资料库没有成功保存")
        let reopened = fixture.makeStore()
        try expectIDs(reopened.favorites, [fixture.items[0]], "新实例必须读取刚保存的同一份资料库")
        try expect(reopened.browseVideoMuted, "新会话必须恢复默认静音，不能持久化前次解除静音")
        try expect(!store.browseVideoMuted, "重建另一个实例不能改变原会话的声音选择")
    }

    private static func viewerFavoriteOnlyChangesCurrentItem() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        store.setSelectionMode(true)
        let items = fixture.items
        store.select(items[0])
        store.select(items[3], modifiers: [.command])
        store.open(items[3])
        try expect(store.focusedItem?.id == items[3].id, "查看器焦点应为打开的项目")
        store.favoriteSelection()
        try expectIDs(store.favorites, [items[3]], "查看器收藏快捷键应只收藏当前项")
        try expectIDs(store.selectedIDs, [items[0], items[3]], "查看器收藏应保留网格中的已有选择")
        store.favoriteSelection()
        try expect(store.favorites.isEmpty, "再次执行应只取消当前收藏")
        store.stepPreview(1)
        try expect(store.previewID == items[4].id, "查看器前进应遵循当前显示顺序")
        store.favoriteSelection()
        try expectIDs(store.favorites, [items[4]], "查看器前进后应收藏新的当前项")
        store.closePreview()
        store.select(items[0])
        store.select(items[3], modifiers: [.command])
        store.favoriteSelection()
        try expectIDs(store.favorites, [items[0], items[3], items[4]], "关闭查看器后快捷键应处理网格的完整选择")
        await store.flushImmediately()
    }

    private static func favoritesAndCachedItemsPersistAfterFlush() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        store.setSelectionMode(true)
        let items = fixture.items
        store.toggleFavorite(items[0])
        store.toggleFavorite(items[1])
        store.select(items[0])
        store.select(items[1], modifiers: [.command])
        store.favoriteSelection()
        store.toggleFavorite(items[5])
        await store.flushImmediately()
        let saved = try fixture.persistence.load()
        try expectIDs(saved.favorites, [items[5]], "退出保存应写入最后一次收藏状态")
        try expect(saved.cachedItems == items && saved.libraries == fixture.libraries, "保存应包含完整离线索引和资源库")

        // Let cancelled debounce jobs wake; none may overwrite the explicit newer flush.
        try await Task.sleep(for: .milliseconds(300))
        let afterDebounce = try fixture.persistence.load()
        try expectIDs(afterDebounce.favorites, [items[5]], "取消的延迟保存不应覆盖较新的退出保存")
        let reopened = fixture.makeStore()
        try expectIDs(reopened.favorites, [items[5]], "重新打开应恢复收藏")
        try expect(reopened.items == items && reopened.visibleItems.count == 6, "重新打开应恢复离线项目")
        try expect(reopened.focusedItem == nil, "持久化不应意外恢复过期的界面选择")
        reopened.selectScope(.favorites)
        try expectIDs(Set(reopened.visibleItems.map(\.id)), [items[5]], "收藏范围应只显示已恢复的收藏")
    }

    private static func corruptCatalogRecoveryPreservesBackups() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let corruptBytes = Data("{unreadable catalog — 用户原始记录".utf8)
        try corruptBytes.write(to: fixture.persistence.fileURL)
        let store = fixture.makeStore()
        let firstBackups = try fixture.backups()
        try expect(firstBackups.count == 1, "损坏记录应立即产生唯一备份")
        let firstBackup = try require(firstBackups.first)
        try expect(try Data(contentsOf: firstBackup) == corruptBytes, "备份必须逐字节保留原始记录")
        try expect(try Data(contentsOf: fixture.persistence.fileURL) == corruptBytes, "初始化备份不应提前覆盖原件")
        try expect(store.errorMessage?.contains(firstBackup.lastPathComponent) == true, "恢复提示应说明唯一备份的位置")

        await store.flushImmediately()
        let recovered = try fixture.persistence.load()
        try expect(recovered.libraries.isEmpty && recovered.cachedItems.isEmpty, "备份成功后应能保存可读取的新目录")
        try expect(try Data(contentsOf: firstBackup) == corruptBytes, "保存新目录不得覆盖备份")
        try corruptBytes.write(to: fixture.persistence.fileURL)
        let secondStore = fixture.makeStore()
        let secondBackups = try fixture.backups()
        try expect(secondBackups.count == 2 && Set(secondBackups).count == 2, "同一秒内再次恢复也应生成独立备份")
        await secondStore.flushImmediately()
        for backup in secondBackups {
            try expect(try Data(contentsOf: backup) == corruptBytes, "每一份原始备份都必须保持完整")
        }
    }

    private static func timelineFlattenAndGroupedSorting() async throws {
        let previousPreference = UserDefaults.standard.object(forKey: "thumbnailSize")
        defer { restoreThumbnailPreference(previousPreference) }
        let fixture = try TimelineFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        store.setThumbnailSize(180)
        store.sort = .name
        store.descending = false
        try expect(store.timelineScale == .day && store.timelineSections.count == 5, "大缩略图应按五个实际拍摄日期分组")
        try expectTimelineFlatten(store)
        try expect(store.timelineSections.map(\.startDate) == store.timelineSections.map(\.startDate).sorted(), "名称排序仍应按日期先后排列日期组")
        try expect(store.timelineSections[0].items.map(\.name) == ["Alpha.mov", "Zebra.jpg"], "同一天内应按名称升序")
        try expect(store.visibleItems.first?.name == "Alpha.mov" && store.visibleItems.last?.name == "Foxtrot.jpg", "组内排序不能把不同日期混为全局名称顺序")

        store.sort = .size
        for section in store.timelineSections {
            try expect(section.items.map(\.fileSize) == section.items.map(\.fileSize).sorted(), "同一天应按真实字节大小升序")
        }
        store.descending = true
        try expect(store.timelineSections.map(\.startDate) == store.timelineSections.map(\.startDate).sorted(by: >), "逆序应同步反转日期组顺序")
        for section in store.timelineSections {
            try expect(section.items.map(\.fileSize) == section.items.map(\.fileSize).sorted(by: >), "逆序应同步反转组内大小排序")
        }
        store.setThumbnailSize(140)
        store.sort = .name
        store.descending = false
        try expect(store.timelineScale == .week, "中等缩略图应聚合为周")
        for section in store.timelineSections {
            try expect(section.items.map(\.name) == section.items.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }, "同一周内应保留名称排序")
        }
        try expectTimelineFlatten(store)

        store.setThumbnailSize(180)
        store.sort = .created
        for section in store.timelineSections {
            try expect(section.items.allSatisfy { $0.createdDate >= section.startDate && $0.createdDate < section.endDate }, "创建时间排序应按创建日期分组")
        }
        store.sort = .modified
        for section in store.timelineSections {
            try expect(section.items.allSatisfy { $0.modifiedDate >= section.startDate && $0.modifiedDate < section.endDate }, "修改时间排序应按修改日期分组")
        }
        try expectTimelineFlatten(store)
    }

    private static func timelineZoomPreservesInteractionState() async throws {
        let previousPreference = UserDefaults.standard.object(forKey: "thumbnailSize")
        defer { restoreThumbnailPreference(previousPreference) }
        let fixture = try TimelineFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        store.setSelectionMode(true)
        store.setThumbnailSize(180)
        store.select(fixture.items[7])
        store.select(fixture.items[0], modifiers: [.command])
        store.layout = .browse
        let originalIDs = store.selectedIDs
        let originalCursor = store.keyboardCursor
        let originalAnchor = store.selectionAnchor
        let originalCurrent = store.visibleItems[store.browseIndex].id
        let originalSection = try require(store.timelineSections.first { $0.items.contains { $0.id == originalCurrent } })
        store.setVisibleTimelineSection(originalSection.id)
        let dayIDs = store.timelineSections.map(\.id)
        let visibleRevision = store.visibleRevision
        let timelineRevision = store.timelineRevision
        store.setThumbnailSize(200)
        try expect(store.timelineSections.map(\.id) == dayIDs && store.visibleRevision == visibleRevision, "同一天档位内缩放不应重排媒体或生成新日期标识")
        try expect(store.timelineRevision > timelineRevision, "同一聚合档位内缩放仍应请求布局更新")

        for (height, expectedScale) in [(150.0, TimelineScale.week), (90, .month), (280, .day), (64, .month), (180, .day)] {
            store.setThumbnailSize(height)
            try expect(store.timelineScale == expectedScale, "缩略图高度应映射到约定的天周月聚合档位")
            try expect(store.selectedIDs == originalIDs, "缩放不得改变媒体多选")
            try expect(store.keyboardCursor == originalCursor && store.selectionAnchor == originalAnchor, "缩放不得移动键盘光标或范围锚点")
            try expect(store.layout == .browse && store.visibleItems[store.browseIndex].id == originalCurrent, "缩放重排后翻阅仍应停留在同一媒体")
            let active = try require(store.timelineSections.first { $0.id == store.visibleTimelineSectionID })
            try expect(active.items.contains { $0.id == originalCurrent }, "天周月切换应把活动日期映射到同一时段")
            try expectTimelineFlatten(store)
            if expectedScale == .month { try expect(store.timelineSections.count == 2, "月档应把跨周照片聚合成六月和七月") }
        }
        store.setThumbnailSize(-100)
        try expect(store.thumbnailSize == 64 && store.timelineScale == .month, "缩放下界应为64")
        store.setThumbnailSize(1000)
        try expect(store.thumbnailSize == 280 && store.timelineScale == .day, "缩放上界应为280")
        try expect(store.selectedIDs == originalIDs && store.visibleItems[store.browseIndex].id == originalCurrent, "缩放边界也不能丢失选择或当前项目")
    }

    private static func browseTimelineZoomIsIndependent() async throws {
        let previousGrid = UserDefaults.standard.object(forKey: "thumbnailSize")
        let previousBrowse = UserDefaults.standard.object(forKey: "browseTimelineSize")
        defer {
            restoreThumbnailPreference(previousGrid)
            if let previousBrowse { UserDefaults.standard.set(previousBrowse, forKey: "browseTimelineSize") }
            else { UserDefaults.standard.removeObject(forKey: "browseTimelineSize") }
        }
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        store.setThumbnailSize(280)
        store.setBrowseTimelineSize(90)
        store.layout = .browse
        store.setSelectionMode(true)
        store.selectedIDs = [fixture.items[1].id, fixture.items[3].id]
        store.focus(fixture.items[2])
        let selected = store.selectedIDs, cursor = store.keyboardCursor
        let current = store.visibleItems[store.browseIndex].id
        let ordered = store.visibleItems, revision = store.visibleRevision, timelineRevision = store.timelineRevision
        store.zoomTimeline(1)
        try expect(store.browseTimelineScale == .week && store.thumbnailSize == 280 && store.timelineScale == .day,
                   "翻阅的放大命令仅展开独立日期轴，不能改变网格尺度")
        store.setActiveTimelineSize(180)
        try expect(store.browseTimelineScale == .day && store.browseTimelineSize == 180,
                   "翻阅滑块路由到自己的日期尺度")
        try expect(store.visibleItems == ordered && store.visibleRevision == revision && store.timelineRevision == timelineRevision,
                   "日期轴缩放不能重排媒体或生成网格刷新修订")
        try expect(store.selectedIDs == selected && store.keyboardCursor == cursor && store.visibleItems[store.browseIndex].id == current,
                   "日期轴缩放保持当前媒体、光标和多选")
        store.layout = .grid
        store.setActiveTimelineSize(120)
        try expect(store.thumbnailSize == 120 && store.timelineScale == .week && store.browseTimelineSize == 180,
                   "回到时间线后滑块仅改变网格，保留照片卷的日期尺度")
        let reopened = fixture.makeStore()
        try expect(reopened.thumbnailSize == 120 && reopened.browseTimelineSize == 180,
                   "重新创建实例可独立恢复两种布局的缩放偏好")
        store.setBrowseTimelineSize(.nan); store.setBrowseTimelineSize(.infinity)
        try expect(store.browseTimelineSize == 180, "非法尺度不能破坏日期轴几何")
        store.setBrowseTimelineSize(-100)
        try expect(store.browseTimelineSize == 64 && store.browseTimelineScale == .month, "日期轴缩小边界为月档")
        store.setBrowseTimelineSize(1000)
        try expect(store.browseTimelineSize == 280 && store.browseTimelineScale == .day && store.thumbnailSize == 120,
                   "日期轴放大边界为天档，仍不修改网格")
    }

    private static func timelineNavigationDoesNotChangeSelection() async throws {
        let previousPreference = UserDefaults.standard.object(forKey: "thumbnailSize")
        defer { restoreThumbnailPreference(previousPreference) }
        let fixture = try TimelineFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        store.setSelectionMode(true)
        store.setThumbnailSize(180)
        store.select(fixture.items[0])
        store.select(fixture.items[7], modifiers: [.command])
        store.layout = .browse
        let selected = store.selectedIDs
        let cursor = store.keyboardCursor
        let anchor = store.selectionAnchor
        let browsing = store.visibleItems[store.browseIndex].id
        let section = try require(store.timelineSections.first)
        let request = store.scrollRequestID
        store.scroll(toSection: section.id)
        try expect(store.layout == .grid, "点击日期应切到可滚动的光桌")
        try expect(store.scrollTargetID == section.items.first?.id && store.visibleTimelineSectionID == section.id, "日期点击应请求该日期第一张媒体的位置")
        try expect(store.scrollRequestID == request + 1, "日期点击应生成独立滚动请求")
        try expect(store.selectedIDs == selected && store.keyboardCursor == cursor && store.selectionAnchor == anchor, "日期跳转不应改变已有媒体选择或焦点")
        try expect(store.visibleItems[store.browseIndex].id == browsing, "日期跳转不应篡改翻阅当前媒体")
        store.scroll(toSection: section.id)
        try expect(store.scrollRequestID == request + 2, "重复点击同一天也应再次请求定位")
        let target = store.scrollTargetID
        store.scroll(toSection: "day:missing")
        try expect(store.scrollRequestID == request + 2 && store.scrollTargetID == target, "过期日期不能产生无效滚动请求")
        let other = try require(store.timelineSections.last)
        store.setVisibleTimelineSection(other.id)
        try expect(store.visibleTimelineSectionID == other.id && store.scrollRequestID == request + 2, "滚动回传活动日期不应反向触发滚动请求")
        try expect(store.selectedIDs == selected && store.keyboardCursor == cursor, "滚动更新活动日期不应改变媒体选择")
    }

    private static func timelineFilteringClearsObsoleteState() async throws {
        let previousPreference = UserDefaults.standard.object(forKey: "thumbnailSize")
        defer { restoreThumbnailPreference(previousPreference) }
        let fixture = try TimelineFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        store.setSelectionMode(true)
        store.setThumbnailSize(180)
        let videoOnlyDay = fixture.items[4]
        let section = try require(store.timelineSections.first { $0.items.contains { $0.id == videoOnlyDay.id } })
        store.select(videoOnlyDay)
        store.open()
        store.setVisibleTimelineSection(section.id)
        store.filter = .image
        try expect(store.timelineSections.allSatisfy { $0.id != section.id }, "只有视频的日期应从照片筛选中消失")
        try expect(store.visibleTimelineSectionID != section.id && store.timelineSections.contains { $0.id == store.visibleTimelineSectionID }, "活动日期不能继续指向已隐藏的日期组")
        try expect(store.selectedIDs.isEmpty && store.keyboardCursor == nil && store.selectionAnchor == nil, "筛选掉当前媒体后应清除过期选择和键盘锚点")
        try expect(store.previewID == nil, "查看器不能继续展示被筛选隐藏的媒体")
        try expectTimelineFlatten(store)
        store.query = "no-such-memory"
        try expect(store.timelineSections.isEmpty && store.visibleItems.isEmpty && store.visibleTimelineSectionID == nil, "无结果时应清空活动日期")
        store.query = ""
        try expect(store.timelineSections.contains { $0.id == store.visibleTimelineSectionID }, "恢复结果后应重新提供有效活动日期")
        store.filter = .all
        try expectTimelineFlatten(store)
    }

    private static func startupCacheAndActivationRefreshPolicy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        defer { store.cancelScan() }
        try expect(store.items == fixture.items && store.visibleItems.count == 6, "初始化应立即展示持久索引，无需等待媒体扫描")
        store.refreshIfNeeded()
        try expect(store.isScanning, "第一次自动激活应启动后台核验")
        store.refreshIfNeeded()
        try await waitForRefresh(store)
        try expect(store.items.isEmpty, "已连接的空目录应清除不存在的旧缓存项目")

        let photo = fixture.libraries[0].url.appendingPathComponent("added-after-scan.jpg")
        try writeRefreshFixture(at: photo)
        store.refreshIfNeeded()
        try expect(!store.isScanning && store.items.isEmpty, "完成后15秒内重复激活不应重新扫描")
        store.refresh()
        try expect(store.isScanning, "显式刷新应绕过自动激活冷却")
        try await waitForRefresh(store)
        try expect(store.items.count == 1 && store.items.first?.name == photo.lastPathComponent, "手动刷新应发现冷却期间新增的媒体")
        try expect(store.items.first?.pixelWidth == 32 && store.items.first?.pixelHeight == 16, "手动刷新应真实读取新增文件的元数据")
        await store.flushImmediately()
    }

    private static func offlineRefreshPreservesCatalogItems() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // Remove only temporary fixture directories to model disconnected volumes.
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("Media"))
        let store = fixture.makeStore()
        defer { store.cancelScan() }
        try expect(store.items == fixture.items, "离线时启动仍应立即展示持久索引")
        store.refreshIfNeeded()
        try await waitForRefresh(store)
        try expect(Set(store.items.map(\.id)) == Set(fixture.items.map(\.id)), "核验发现磁盘离线后不能丢弃历史媒体")
        try expect(store.offlineLibraries == Set(fixture.libraries.map(\.id)), "不可用的资源库应明确标记离线")
        try expect(store.scanWarnings.count == fixture.libraries.count, "每个不可用资源库应保留诊断")
        try expect(store.count(in: fixture.privateFolder.path) == 1, "离线索引应继续提供子目录计数")
        await store.flushImmediately()
        try expect(Set(try fixture.persistence.load().cachedItems.map(\.id)) == Set(fixture.items.map(\.id)), "离线后的持久化不能覆盖为一个空索引")

        // A replaced directory can invalidate its bookmark while the explicitly
        // selected path is reachable. Recheck that path rather than staying offline.
        let bookmarkFixture = try Fixture()
        defer { bookmarkFixture.remove() }
        let invalidBookmarks = bookmarkFixture.libraries.map {
            MediaLibrary(id: $0.id, url: $0.url, bookmark: Data([0, 1, 2]), name: $0.name)
        }
        try bookmarkFixture.persistence.save(CatalogState(libraries: invalidBookmarks, cachedItems: bookmarkFixture.items))
        let bookmarkStore = bookmarkFixture.makeStore()
        defer { bookmarkStore.cancelScan() }
        try expect(bookmarkStore.offlineLibraries.isEmpty, "书签失效但原选择路径可访问时不应保持离线")
        bookmarkStore.refreshIfNeeded()
        try await waitForRefresh(bookmarkStore)
        try expect(bookmarkStore.items.isEmpty, "重新连接的空目录应清除已经不存在的媒体记录")
        try expect(bookmarkStore.scanWarnings.isEmpty && bookmarkStore.offlineLibraries.isEmpty, "有效路径恢复后不保留过期离线诊断")
        await bookmarkStore.flushImmediately()
    }

    private static func waitForRefresh(_ store: AppStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isScanning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try expect(!store.isScanning, "临时夹具刷新未在5秒内完成")
    }

    fileprivate static func writeRefreshFixture(at url: URL) throws {
        let context = try require(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        let image = try require(context.makeImage())
        let destination = try require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try expect(CGImageDestinationFinalize(destination), "无法写入临时刷新夹具")
    }

    private static func hidingIsGlobalAndRestorable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        store.setSelectionMode(true)
        let items = fixture.items
        store.toggleFavorite(items[0]); store.toggleFavorite(items[1])
        let albumID = try require(store.createAlbum(name: "隐藏回归", addingIDs: Set(items[0...2].map(\.id))))
        store.setHidden(true, ids: [items[0].id, items[1].id])
        try expect(store.hiddenCount == 2 && store.visibleItems.count == 4, "全局隐藏应从所有项目中排除")
        try expect(store.favoriteCount == 0 && store.count(in: fixture.libraries[0].url.path) == 1, "收藏及目录计数应排除隐藏项目")
        try expect(store.favorites == [items[0].id, items[1].id], "隐藏应保留原有收藏关系")
        store.selectScope(.favorites)
        try expect(store.visibleItems.isEmpty, "收藏范围不能泄露隐藏项目")
        store.toggleFolder(fixture.libraries[0].url.path)
        try expectIDs(Set(store.visibleItems.map(\.id)), [items[2]], "文件夹范围不能泄露隐藏项目")
        store.selectScope(.album(albumID))
        try expectIDs(Set(store.visibleItems.map(\.id)), [items[2]], "影集范围不能泄露隐藏项目")
        try expect(store.albumCount(store.albums[0]) == 1 && store.albums[0].itemIDs.count == 3, "隐藏仅影响影集显示，不能删除成员")
        store.selectScope(.hidden)
        try expectIDs(Set(store.visibleItems.map(\.id)), Array(items[0...1]), "隐藏范围应可找回项目")
        store.select(items[0]); store.open()
        store.setHidden(false, ids: [items[0].id])
        try expectIDs(Set(store.visibleItems.map(\.id)), [items[1]], "恢复后项目应离开隐藏范围")
        try expect(store.previewID == nil && store.selectedIDs.isEmpty, "恢复到普通范围后应清除隐藏页的过期查看器和选择")
        store.selectScope(.favorites)
        try expectIDs(Set(store.visibleItems.map(\.id)), [items[0]], "恢复应重新出现于原收藏")
        store.selectScope(.album(albumID))
        try expectIDs(Set(store.visibleItems.map(\.id)), [items[0], items[2]], "恢复应重新出现于原影集")
        store.setHidden(false, ids: [items[1].id])
        store.selectScope(.all)
        try expect(store.visibleItems.count == 6 && store.hiddenCount == 0 && store.favoriteCount == 2, "全部恢复后应恢复普通范围及计数")
        await store.flushImmediately()
    }

    private static func albumLifecycleAndPersistence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        store.setSelectionMode(true)
        let items = fixture.items
        try expect(store.createAlbum(name: "  ") == nil, "空影集名称必须拒绝")
        let first = try require(store.createAlbum(name: " 旅行 "))
        try expect(store.albums[0].name == "旅行", "影集名称应去除意外空白")
        try expect(store.createAlbum(name: "旅行") == nil, "重复影集名称不得静默创建")
        let second = try require(store.createAlbum(name: "家人"))
        store.addToAlbum([items[0].id, items[1].id, "/not-in-catalog"], albumID: first)
        store.selectScope(.album(first))
        try expectIDs(Set(store.visibleItems.map(\.id)), Array(items[0...1]), "影集应只接收真实索引成员")
        store.select(items[1])
        store.removeFromAlbum([items[1].id], albumID: first)
        try expectIDs(Set(store.visibleItems.map(\.id)), [items[0]], "移出影集不应删除原件或其他成员")
        try expect(store.selectedIDs.isEmpty && store.items == items, "移出影集应裁剪不可见选择但保留完整索引")
        store.renameAlbum(first, to: "新的旅行")
        store.renameAlbum(second, to: "新的旅行")
        try expect(store.title == "新的旅行" && store.albums[1].name == "家人", "影集重命名应更新标题并拒绝重名")
        store.setHidden(true, ids: [items[0].id])
        await store.flushImmediately()
        let reopened = fixture.makeStore()
        try expect(reopened.albums == store.albums && reopened.hiddenIDs == [items[0].id], "重开应恢复影集成员和隐藏状态")
        reopened.selectScope(.album(first))
        try expect(reopened.visibleItems.isEmpty, "重开后的影集仍须排除隐藏成员")
        reopened.deleteAlbum(first)
        try expect(reopened.scope == .all && reopened.albums.map(\.id) == [second], "删除当前影集应回到所有项目")
        try expect(reopened.items == items && reopened.libraries == fixture.libraries, "删除影集不得移除原件索引或资源库")
        await reopened.flushImmediately()
    }

    private static func renameMigratesAllItemReferences() async throws {
        let fixture = try await FileOperationFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        store.setSelectionMode(true)
        let original = fixture.items[0]
        let originalBytes = try Data(contentsOf: original.url)
        store.toggleFavorite(original)
        store.setHidden(true, ids: [original.id])
        let albumID = try require(store.createAlbum(name: "文件迁移", addingIDs: [original.id, fixture.items[1].id]))
        store.selectScope(.hidden)
        store.select(original); store.open(original)
        store.scroll(toSection: try require(store.timelineSections.first).id)
        store.layout = .browse
        let basename = "已重命名-" + UUID().uuidString
        let destination = original.url.deletingLastPathComponent().appendingPathComponent(basename + ".jpg")
        let success = await store.rename(original, to: basename)
        try expect(success && FileManager.default.fileExists(atPath: destination.path) && !FileManager.default.fileExists(atPath: original.url.path), "重命名应真实移动同一目录中的文件")
        try expect(try Data(contentsOf: destination) == originalBytes, "重命名不得改写原文件内容")
        try expect(store.favorites == [destination.path] && store.hiddenIDs == [destination.path], "收藏和隐藏路径应一起迁移")
        try expect(store.albums.first(where: { $0.id == albumID })?.itemIDs.contains(destination.path) == true, "影集成员路径应一起迁移")
        try expect(store.albums.allSatisfy { !$0.itemIDs.contains(original.id) }, "影集不得残留旧路径")
        try expect(store.selectedIDs == [destination.path] && store.selectionAnchor == destination.path && store.keyboardCursor == destination.path, "选择、范围锚点和键盘光标应迁移")
        try expect(store.previewID == destination.path && store.scrollTargetID == destination.path, "查看器和滚动目标应迁移")
        try expect(store.visibleItems[store.browseIndex].id == destination.path, "翻阅当前媒体应保持为重命名后的同一文件")
        let renamed = try require(store.items.first { $0.id == destination.path })
        try expect(renamed == original.relocated(to: destination), "尺寸、时间和其他元数据不得在重命名时丢失")
        let restored = try fixture.persistence.load()
        try expect(restored.hiddenIDs == store.hiddenIDs && restored.albums == store.albums && restored.favorites == store.favorites, "文件成功移动后应立即持久化全部新路径")
        let finalName = "再次重命名-" + UUID().uuidString + ".jpg"
        let renamedAgain = await store.rename(renamed, to: finalName)
        try expect(renamedAgain, "包含原扩展名的完整输入应可重命名")
        try expect(store.items.contains { $0.name == finalName }, "原扩展名不得重复追加")
    }

    private static func renameRejectsUnsafeOrStaleChanges() async throws {
        let fixture = try await FileOperationFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let original = fixture.items[0]
        let conflict = original.url.deletingLastPathComponent().appendingPathComponent("unindexed-conflict-" + UUID().uuidString + ".jpg")
        try writeRefreshFixture(at: conflict)
        let sourceBytes = try Data(contentsOf: original.url)
        let conflictBytes = try Data(contentsOf: conflict)
        let conflictingRename = await store.rename(original, to: conflict.lastPathComponent)
        try expect(!conflictingRename, "未被索引的同名文件也必须拒绝覆盖")
        try expect(try Data(contentsOf: conflict) == conflictBytes && Data(contentsOf: original.url) == sourceBytes, "冲突时两个原文件都必须保持完整")
        for invalid in ["../escape", "folder/name", "folder\\name", "", ".hidden", ".."] {
            let invalidRename = await store.rename(original, to: invalid)
            try expect(!invalidRename, "路径穿越及无效名称不得执行")
        }
        let handle = try FileHandle(forWritingTo: original.url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
        let staleRename = await store.rename(original, to: "changed-source")
        try expect(!staleRename, "扫描后已变更的原件必须拒绝操作")
        try expect(store.errorMessage?.contains("变更") == true && FileManager.default.fileExists(atPath: original.url.path), "过期原件应留在原处并报告原因")
        try expect(store.items == fixture.items && !store.isPerformingFileOperation, "失败不能迁移索引，且必须释放操作状态")
    }

    private static func renameCannotResurrectOldScanPaths() async throws {
        let fixture = try await FileOperationFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let original = fixture.items[0]
        store.refresh()
        try expect(store.isScanning, "应先有一轮待完成扫描")
        let basename = "after-scan-" + UUID().uuidString
        let renamed = await store.rename(original, to: basename)
        try expect(renamed, "扫描中的重命名应安全完成")
        try await waitForRefresh(store)
        try await Task.sleep(for: .milliseconds(50))
        try expect(!store.items.contains { $0.id == original.id }, "旧扫描结果不能复活已经重命名的旧路径")
        try expect(store.items.contains { $0.name == basename + ".jpg" } && store.items.count == fixture.items.count, "合并刷新应重新核验当前文件位置且不重复")
        await store.flushImmediately()
    }

    private static func trashPreservesFailedItemsAndUsesSystemTrash() async throws {
        let fixture = try await FileOperationFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        store.setSelectionMode(true)
        let success = fixture.items[0]
        let failure = fixture.items[1]
        let bytes = try Data(contentsOf: success.url)
        let trashDirectory = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: fixture.root, create: true)
        let trashedFixture = trashDirectory.appendingPathComponent(success.name)
        // This UUID-named file belongs to this test. Restore it after proving that
        // Foundation used Trash, then the ordinary temporary-fixture cleanup runs.
        defer {
            if FileManager.default.fileExists(atPath: trashedFixture.path), !FileManager.default.fileExists(atPath: success.url.path) {
                try? FileManager.default.moveItem(at: trashedFixture, to: success.url)
            }
        }
        store.toggleFavorite(success); store.toggleFavorite(failure)
        store.setHidden(true, ids: [success.id, failure.id])
        let albumID = try require(store.createAlbum(name: "废纸篓回归", addingIDs: Set(fixture.items.map(\.id))))
        store.selectScope(.hidden)
        store.select(success); store.select(failure, modifiers: [.command]); store.open(success)
        try FileManager.default.removeItem(at: failure.url)
        await store.trash([success, failure, success])
        try expect(!FileManager.default.fileExists(atPath: success.url.path) && FileManager.default.fileExists(atPath: trashedFixture.path), "成功项目必须真实位于系统废纸篓，不能被永久删除")
        try expect(try Data(contentsOf: trashedFixture) == bytes, "系统废纸篓中的夹具内容必须完整")
        try expect(!store.items.contains { $0.id == success.id } && store.items.contains { $0.id == failure.id }, "只允许从索引移除成功移到废纸篓的项目")
        try expect(store.favorites == [failure.id] && store.hiddenIDs == [failure.id], "失败项目的收藏与隐藏状态必须保留")
        try expect(store.albums.first(where: { $0.id == albumID })?.itemIDs == [failure.id, fixture.items[2].id], "影集只应移除已成功移走的成员")
        try expect(store.previewID == nil && store.selectedIDs == [failure.id], "成功移走的项目不应残留在查看器或选择中")
        try expect(store.errorMessage?.contains(failure.name) == true && store.errorMessage?.contains("1项已移到废纸篓") == true, "部分失败应准确列出未移动文件并保留成功数量")
        let saved = try fixture.persistence.load()
        try expect(saved.hiddenIDs == [failure.id] && saved.favorites == [failure.id], "部分成功也应安全持久化集合状态")
        await store.trash([failure])
        try expect(store.items.contains { $0.id == failure.id }, "全部失败也不能删除索引或成员")
    }

    private static func terminationWaitsForFileOperations() async throws {
        let fixture = try await FileOperationFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let original = fixture.items[0]
        let basename = "termination-" + UUID().uuidString
        let destination = original.url.deletingLastPathComponent().appendingPathComponent(basename + ".jpg")
        store.toggleFavorite(original)
        store.refresh()
        var operationReturned = false
        let operation = Task { @MainActor in
            let success = await store.rename(original, to: basename)
            operationReturned = true
            return success
        }
        let startDeadline = ContinuousClock.now + .seconds(3)
        while !store.isPerformingFileOperation && !operationReturned && ContinuousClock.now < startDeadline {
            await Task.yield()
        }
        try expect(store.isPerformingFileOperation, "夹具应在真实文件操作等待时发出退出请求")

        // The direct call enters the barrier before the current MainActor turn
        // yields, so an already-running rename cannot slip past this check.
        var otherWaiterReturned = false
        let otherWaiter = Task { @MainActor in
            await store.waitForFileOperations()
            otherWaiterReturned = true
        }
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled {
                print("✗ 退出文件操作等待超过5秒，可能存在 continuation 未恢复")
                exit(EXIT_FAILURE)
            }
        }
        defer { watchdog.cancel() }
        await store.waitForFileOperations()
        try expect(!store.isPerformingFileOperation, "退出屏障必须等文件操作释放状态后才能返回")
        try expect(store.favorites == [destination.path] && !store.items.contains { $0.id == original.id }, "屏障返回前必须完成路径及集合迁移")
        let saved = try fixture.persistence.load()
        try expect(saved.favorites == [destination.path] && saved.cachedItems.contains { $0.id == destination.path }, "屏障返回前必须完成操作内部持久化")
        let renamed = await operation.value
        try expect(renamed, "退出请求不能取消已获准执行的文件操作")
        await otherWaiter.value
        try expect(otherWaiterReturned, "所有退出等待者都应被恢复")

        store.refresh(); store.refreshIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        try expect(!store.isScanning, "退出期间不得执行操作完成后的补扫或激活刷新")
        let second = fixture.items[1]
        let secondRename = await store.rename(second, to: "must-not-begin")
        try expect(!secondRename && FileManager.default.fileExists(atPath: second.url.path), "退出屏障后不得启动新的文件操作")
        await store.waitForFileOperations()
        let finalSave = await store.flushImmediately()
        try expect(finalSave, "正常退出屏障之后应明确返回保存成功")
    }

    private static func failedSavePreservesMovesAndAllowsRetry() async throws {
        let fixture = try await FileOperationFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let original = fixture.items[0]
        store.toggleFavorite(original)
        store.setHidden(true, ids: [original.id])
        let albumID = try require(store.createAlbum(name: "保存重试", addingIDs: [original.id]))
        let initialSave = await store.flushImmediately()
        try expect(initialSave, "夹具初始记录应可正常写入")
        let originalCatalog = try Data(contentsOf: fixture.persistence.fileURL)

        // Replace only this UUID fixture's catalog directory with a regular file.
        // A real directory-creation failure works even when permissions are ignored.
        let preservedDirectory = fixture.root.appendingPathComponent("Catalog-preserved", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.persistence.directory, to: preservedDirectory)
        let blocker = Data("仅属于本次测试的保存阻挡文件".utf8)
        try blocker.write(to: fixture.persistence.directory)
        let basename = "saved-later-" + UUID().uuidString
        let destination = original.url.deletingLastPathComponent().appendingPathComponent(basename + ".jpg")
        let renamed = await store.rename(original, to: basename)
        try expect(renamed, "原文件已成功重命名时必须保留成功语义，避免诱导重复移动")
        try expect(FileManager.default.fileExists(atPath: destination.path) && !FileManager.default.fileExists(atPath: original.url.path), "本次保存失败必须发生在真实文件移动之后")
        try expect(store.favorites == [destination.path] && store.hiddenIDs == [destination.path], "保存失败也必须保留内存中的新路径关系")
        try expect(store.albums.first(where: { $0.id == albumID })?.itemIDs == [destination.path], "保存失败不能撤销已发生的影集路径迁移")
        try expect(store.errorMessage?.contains("无法保存") == true, "原文件移动成功但记录失败时必须明确报告保存错误")

        await store.waitForFileOperations()
        let failedFinalSave = await store.flushImmediately()
        try expect(!failedFinalSave, "最终保存失败必须返回false以拒绝退出")
        try expect(try Data(contentsOf: preservedDirectory.appendingPathComponent("catalog.json")) == originalCatalog, "失败不得覆盖仍可恢复的上次目录记录")
        try expect(try Data(contentsOf: fixture.persistence.directory) == blocker, "保存失败不得破坏造成失败的路径")
        store.cancelTermination()
        try expect(store.errorMessage?.contains("无法保存") == true, "取消退出应保留保存失败提示")
        store.refresh()
        try expect(store.isScanning, "取消退出应重新允许刷新")
        try await waitForRefresh(store)
        let stillFailed = await store.flushImmediately()
        try expect(!stillFailed && store.items.contains { $0.id == destination.path }, "失败后刷新必须保留已移动原件的索引，且保存结果不能假报成功")

        try FileManager.default.removeItem(at: fixture.persistence.directory)
        try FileManager.default.moveItem(at: preservedDirectory, to: fixture.persistence.directory)
        let retried = await store.flushImmediately()
        try expect(retried && store.errorMessage == nil, "恢复写入路径后应可重试保存并清除对应保存错误")
        let restored = try fixture.persistence.load()
        try expect(restored.favorites == [destination.path] && restored.hiddenIDs == [destination.path], "重试必须持久化已移动文件的收藏与隐藏关系")
        try expect(restored.albums.first(where: { $0.id == albumID })?.itemIDs == [destination.path], "重试必须持久化影集的新路径")
        try expect(restored.cachedItems.contains { $0.id == destination.path } && !restored.cachedItems.contains { $0.id == original.id }, "重试不得复活旧路径")
        let nextRename = await store.rename(fixture.items[1], to: "after-recovery-" + UUID().uuidString)
        try expect(nextRename, "取消退出并恢复保存后应允许下一次文件操作")
        await store.waitForFileOperations()
        let finalRetry = await store.flushImmediately()
        try expect(finalRetry, "修复后再次退出应正常通过屏障和最终保存")
    }

    private static func protectedStartupCatalogCanQuitWithoutChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.persistence.fileURL)
        try FileManager.default.createDirectory(at: fixture.persistence.fileURL, withIntermediateDirectories: true)
        let marker = fixture.persistence.fileURL.appendingPathComponent("preserve-original")
        let bytes = Data("必须保留的不可读目录内容".utf8)
        try bytes.write(to: marker)
        let store = fixture.makeStore()
        try expect(store.items.isEmpty && store.errorMessage?.contains("无法读取") == true, "读取目录形状的catalog应进入启动只读保护")
        store.refresh()
        await store.waitForFileOperations()
        let unchangedQuit = await store.flushImmediately()
        try expect(unchangedQuit, "只读保护且没有新记录时不应把用户锁在退出循环中")
        try expect(try Data(contentsOf: marker) == bytes, "允许退出不能改写不可读原记录")
        store.cancelTermination()
        _ = store.createAlbum(name: "未保存影集")
        let changedQuit = await store.flushImmediately()
        try expect(!changedQuit, "只读保护中新增的内存记录不能假报已保存")
        try expect(try Data(contentsOf: marker) == bytes, "新记录也不能覆盖被保护的原目录")
    }
}

@MainActor
private struct FileOperationFixture {
    let root: URL
    let persistence: CatalogPersistence
    let libraries: [MediaLibrary]
    let items: [MediaItem]

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FilmboxFileOperations-" + UUID().uuidString, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let media = root.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for number in 1...3 {
            try BehaviorCheckRunner.writeRefreshFixture(at: media.appendingPathComponent("0\(number)-" + UUID().uuidString + ".jpg"))
        }
        libraries = [MediaLibrary(url: media)]
        items = await MediaScanner().scan(libraries: libraries).items
        try expect(items.count == 3, "真实文件操作夹具扫描失败")
        persistence = CatalogPersistence(directory: root.appendingPathComponent("Catalog"))
        try persistence.save(CatalogState(libraries: libraries, cachedItems: items))
    }

    func makeStore() -> AppStore {
        let store = AppStore(directory: persistence.directory)
        store.sort = .name; store.descending = false
        return store
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private struct TimelineFixture {
    let root: URL
    let persistence: CatalogPersistence
    let items: [MediaItem]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FilmboxTimelineBehavior-" + UUID().uuidString, isDirectory: true)
        let media = root.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        persistence = CatalogPersistence(directory: root.appendingPathComponent("Catalog", isDirectory: true))
        let specifications: [(String, Int, Int, Int, Int64)] = [
            ("Zebra.jpg", 6, 18, 9, 900), ("Alpha.mov", 6, 18, 18, 100),
            ("Hotel.jpg", 6, 19, 10, 700), ("Bravo.jpg", 6, 19, 14, 300),
            ("Delta.mov", 6, 28, 12, 500), ("Echo.jpg", 7, 2, 8, 200),
            ("Charlie.mov", 7, 2, 17, 800), ("Foxtrot.jpg", 7, 16, 12, 400)
        ]
        let calendar = Calendar.current
        items = specifications.map { name, month, day, hour, size in
            let captured = calendar.date(from: DateComponents(year: 2024, month: month, day: day, hour: hour))!
            let created = calendar.date(byAdding: .day, value: 40, to: captured)!
            let modified = calendar.date(byAdding: .day, value: 75, to: captured)!
            let isVideo = name.hasSuffix("mov")
            return MediaItem(url: media.appendingPathComponent(name), kind: isVideo ? .video : .image,
                             fileSize: size, modifiedDate: modified, createdDate: created, capturedDate: captured,
                             pixelWidth: 6000, pixelHeight: 4000, duration: isVideo ? 4 : nil)
        }
        try persistence.save(CatalogState(libraries: [MediaLibrary(url: media)], cachedItems: items))
    }

    func makeStore() -> AppStore {
        let store = AppStore(directory: persistence.directory)
        store.sort = .name
        store.descending = false
        return store
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private func restoreThumbnailPreference(_ previous: Any?) {
    if let previous { UserDefaults.standard.set(previous, forKey: "thumbnailSize") }
    else { UserDefaults.standard.removeObject(forKey: "thumbnailSize") }
}

@MainActor
private func expectTimelineFlatten(_ store: AppStore, file: StaticString = #filePath, line: UInt = #line) throws {
    try expect(store.timelineSections.flatMap(\.items) == store.visibleItems, "时间线展平结果必须与网格和翻阅共享同一顺序", file: file, line: line)
    try expect(Set(store.visibleItems.map(\.id)).count == store.visibleItems.count, "时间线不能重复媒体项目", file: file, line: line)
}

@MainActor
private struct Fixture {
    let root: URL
    let persistence: CatalogPersistence
    let libraries: [MediaLibrary]
    let privateFolder: URL
    let items: [MediaItem]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FilmboxBehaviorChecks-" + UUID().uuidString, isDirectory: true)
        let trip = root.appendingPathComponent("Media/Trip", isDirectory: true)
        let family = root.appendingPathComponent("Media/Family", isDirectory: true)
        privateFolder = trip.appendingPathComponent("Private", isDirectory: true)
        for directory in [privateFolder, family] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        persistence = CatalogPersistence(directory: root.appendingPathComponent("Catalog", isDirectory: true))
        libraries = [MediaLibrary(url: trip, name: "旅行"), MediaLibrary(url: family, name: "家人")]
        let urls = [
            trip.appendingPathComponent("01.jpg"), privateFolder.appendingPathComponent("02.jpg"),
            trip.appendingPathComponent("03.mov"), family.appendingPathComponent("04.jpg"),
            family.appendingPathComponent("05.mov"), family.appendingPathComponent("06.jpg")
        ]
        items = urls.enumerated().map { index, url in
            let date = Date(timeIntervalSince1970: 1_600_000_000 + Double(index * 100))
            return MediaItem(
                url: url, kind: url.pathExtension == "mov" ? .video : .image,
                fileSize: Int64((index + 1) * 100), modifiedDate: date, createdDate: date,
                capturedDate: date, pixelWidth: 1200, pixelHeight: 800,
                camera: "Fixture Camera", duration: url.pathExtension == "mov" ? 3 : nil
            )
        }
        try persistence.save(CatalogState(libraries: libraries, cachedItems: items))
    }

    func makeStore() -> AppStore {
        let store = AppStore(directory: persistence.directory)
        store.sort = .name
        store.descending = false
        return store
    }

    func backups() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: persistence.directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("catalog-corrupt-") }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private struct BehaviorCheckFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private func expect(_ condition: @autoclosure () throws -> Bool, _ reason: String, file: StaticString = #filePath, line: UInt = #line) throws {
    guard try condition() else { throw BehaviorCheckFailure(description: "\(reason)（\(file):\(line)）") }
}

@MainActor
private func expectIDs(_ actual: Set<String>, _ expected: [MediaItem], _ reason: String, file: StaticString = #filePath, line: UInt = #line) throws {
    let expectedIDs = Set(expected.map(\.id))
    guard actual == expectedIDs else {
        let actualNames = actual.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted()
        let expectedNames = expected.map(\.name).sorted()
        throw BehaviorCheckFailure(description: "\(reason)，预期 \(expectedNames)，实际 \(actualNames)（\(file):\(line)）")
    }
}

private func require<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { throw BehaviorCheckFailure(description: "缺少必要结果（\(file):\(line)）") }
    return value
}
