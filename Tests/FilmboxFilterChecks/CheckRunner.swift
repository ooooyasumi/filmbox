import AppKit
import Darwin
import FilmboxCore
import Foundation

/// Exercises the actual AppStore with synthetic catalogue records and an injected
/// disk-index reader. It never logs into a provider or touches a user's cache.
@main @MainActor private struct FilterCheckRunner {
    private static var assertions = 0

    static func main() async {
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("实际格式统一大小写、多格式并集与类型来源交集", formatAndSourceIntersection),
            ("高清原图筛选排除本地及缩略图、可逆切换", originalDownloadsAreCloudOnly),
            ("筛选服从隐藏、收藏、影集和目录范围", scopeIsolation),
            ("原图下载事件合并、无变化不重排、缓存清除及时消失", coalescedCacheChanges),
            ("异步旧缓存快照不能覆盖新目录且元数据不触发重查", staleSnapshotProtection),
            ("一次清空全部条件保留搜索排序与幸存浏览锚点", clearingPreservesInteraction),
            ("空结果可清格式、首次缓存检查状态可区分", emptyResultsAndFirstStatus),
            ("缓存变更不关闭当前查看器、关闭后应用且显式筛选即时", viewerSurvivesDownloadStateChange),
            ("卷轴聚焦下载完成后保留当前照片、切走校正连续位置", rollSurvivesDownloadStateChange),
            ("卷轴保留可在模式切换和显式条件下结算、多选不中断", rollPinRespectsExplicitActions)
        ]
        var failures = 0
        for (name, check) in checks {
            do { try await check(); print("✓ \(name)") }
            catch { failures += 1; print("✗ \(name)：\(error)") }
        }
        print("\(checks.count - failures)/\(checks.count) 筛选场景、\(assertions) 项断言通过")
        if failures > 0 { exit(EXIT_FAILURE) }
    }

    private static func formatAndSourceIntersection() async throws {
        let f = try Fixture(); defer { f.remove() }
        let s = f.store
        try expect(Set(s.availableFormats) == ["JPG", "PNG", "HEIC", "MP4", "无扩展名"], "格式必须来自本地与云端真实文件名并合并大小写")
        s.toggleFormat(".jpg")
        try expectIDs(s, [f.localJPG, f.cloudJPG], "单格式应匹配大小写不同的照片")
        s.toggleFormat("png")
        try expectIDs(s, [f.localJPG, f.cloudJPG, f.cloudPNG], "格式之间应取并集")
        s.setSourceFilter(.cloud)
        try expectIDs(s, [f.cloudJPG, f.cloudPNG], "来源与格式应取交集")
        s.filter = .video
        try expect(s.visibleItems.isEmpty && s.hasActiveFilters, "类型与来源、格式组合后允许空结果但保留可清条件")
        s.clearFormatFilter()
        try expectIDs(s, [f.cloudVideo], "单独清格式不得清掉视频和云端条件")
        s.setSourceFilter(.local)
        try expectIDs(s, [f.localVideo], "来源切换不应重置类型")
        s.clearFilters()
        try expect(s.visibleItems.count == f.items.count && !s.hasActiveFilters, "一键重置应还原全部媒体条件")
    }

    private static func originalDownloadsAreCloudOnly() async throws {
        let f = try Fixture(); defer { f.remove() }
        let source = CacheSource(ids: [f.cloudJPG.id, f.cloudVideo.id, f.localJPG.id])
        f.store.refreshOriginalDownloadStatus { await source.load($0) }
        try await wait { f.store.hasLoadedOriginalCache && !f.store.isCheckingOriginalCache }
        f.store.setOriginalDownloadFilter(.downloaded)
        try expect(f.store.sourceFilter == .cloud, "选高清原图条件应同时明确云端来源")
        try expectIDs(f.store, [f.cloudJPG, f.cloudVideo], "即使错误缓存ID含本地，已下载也不能混入本地原件")
        f.store.setOriginalDownloadFilter(.notDownloaded)
        try expectIDs(f.store, [f.cloudPNG, f.cloudHEIC], "只有缩略图的云端文件仍应属于未下载原图")
        f.store.filter = .image
        try expectIDs(f.store, [f.cloudPNG, f.cloudHEIC], "未下载与照片类型应交集")
        f.store.setSourceFilter(.local)
        try expect(f.store.originalDownloadFilter == .all && f.store.sourceFilter == .local, "选择本地必须原子清除矛盾的云端下载条件")
        try expectIDs(f.store, [f.localJPG, f.localNoExtension], "切本地后的照片范围不应残留下载条件")
        f.store.setOriginalDownloadFilter(.downloaded)
        f.store.setSourceFilter(.all)
        try expect(f.store.originalDownloadFilter == .all && f.store.sourceFilter == .all, "选择全部来源也应退出云端限定")
        await f.store.waitForFileOperations()
    }

    private static func scopeIsolation() async throws {
        let f = try Fixture(); defer { f.remove() }
        let s = f.store
        s.hiddenIDs = [f.cloudPNG.id]
        s.favorites = [f.localJPG.id, f.cloudJPG.id, f.cloudPNG.id]
        let album = MediaAlbum(name: "旅行", itemIDs: [f.cloudJPG.id, f.cloudPNG.id, f.cloudHEIC.id])
        s.albums = [album]
        s.setSourceFilter(.cloud)
        try expect(!s.visibleItems.contains { $0.id == f.cloudPNG.id }, "所有项目中的筛选不能泄露隐藏内容")
        s.selectScope(.favorites)
        try expectIDs(s, [f.cloudJPG], "收藏范围仍应排除隐藏项并应用来源")
        s.selectScope(.album(album.id))
        try expectIDs(s, [f.cloudJPG, f.cloudHEIC], "影集范围仍服从媒体筛选")
        s.selectScope(.hidden)
        try expectIDs(s, [f.cloudPNG], "隐藏分类中筛选可以找回隐藏云端文件")
        s.directorySelection = DirectorySelection(included: [f.cloudJPG.folderPath])
        s.selectScope(.folders)
        try expectIDs(s, [f.cloudJPG, f.cloudVideo, f.cloudHEIC], "目录筛选应使用云端逻辑目录而非本地缓存路径")
        s.toggleFormat("png")
        try expect(s.visibleItems.isEmpty && s.availableFormats.contains("PNG"), "筛选后不存在的已选格式仍必须可取消")
    }

    private static func coalescedCacheChanges() async throws {
        let f = try Fixture(); defer { f.remove() }
        let source = CacheSource(ids: [f.cloudJPG.id])
        let s = f.store
        s.refreshOriginalDownloadStatus { await source.load($0) }
        try await wait { s.hasLoadedOriginalCache && !s.isCheckingOriginalCache }
        s.setOriginalDownloadFilter(.downloaded)
        try await wait { !s.isCheckingOriginalCache }
        let before = s.visibleRevision
        let callsBefore = await source.calls()
        for _ in 0..<40 { s.refreshOriginalDownloadStatus() }
        try expectIDs(s, [f.cloudJPG], "后续刷新应保留已知列表，不清空闪烁")
        try await wait { !s.isCheckingOriginalCache }
        let callsAfter = await source.calls()
        try expect(callsAfter == callsBefore + 1, "同批缓存通知必须合并成一次索引读取")
        try expect(s.visibleRevision == before, "同一原图ID集合不能触发布局修订")
        await source.setIDs([f.cloudJPG.id, f.cloudVideo.id])
        s.refreshOriginalDownloadStatus()
        try await wait { !s.isCheckingOriginalCache }
        try expectIDs(s, [f.cloudJPG, f.cloudVideo], "原图完成下载必须进入已下载结果")
        try expect(s.visibleRevision == before + 1, "一批原图状态变更只应发布一次列表修订")
        s.setSelectionMode(true)
        s.selectAll()
        s.focus(f.cloudJPG)
        await source.setIDs([f.cloudJPG.id])
        s.refreshOriginalDownloadStatus()
        try await wait { !s.isCheckingOriginalCache }
        try expectIDs(s, [f.cloudJPG], "原图清除或驱逐后必须退出已下载结果")
        try expect(s.selectedIDs == [f.cloudJPG.id] && s.visibleItems[s.browseIndex].id == f.cloudJPG.id,
                   "缓存清除裁剪失效多选并保留幸存浏览锚点")
        await s.waitForFileOperations()
    }

    private static func staleSnapshotProtection() async throws {
        let f = try Fixture(); defer { f.remove() }
        let source = CacheSource(ids: [f.cloudJPG.id], delay: .milliseconds(250))
        let s = f.store
        s.refreshOriginalDownloadStatus { await source.load($0) }
        try await wait { await source.calls() == 1 }
        s.items = [f.cloudPNG]
        s.applyFilters()
        await source.setIDs([f.cloudPNG.id])
        try await wait { s.hasLoadedOriginalCache && !s.isCheckingOriginalCache }
        s.setOriginalDownloadFilter(.downloaded)
        try expectIDs(s, [f.cloudPNG], "旧目录的延迟快照不能冒充新目录的缓存状态")
        try await wait { !s.isCheckingOriginalCache }
        let count = await source.calls()
        let updated = f.cloudPNG.withPreviewAspectRatio(1.7)
        s.updateCachedMediaItems([updated.id: updated])
        try await Task.sleep(for: .milliseconds(500))
        let after = await source.calls()
        try expect(after == count && !s.isCheckingOriginalCache, "只补比例等元数据不得重新查询磁盘原图索引")
        await s.waitForFileOperations()
    }

    private static func clearingPreservesInteraction() async throws {
        let f = try Fixture(); defer { f.remove() }
        let s = f.store
        s.descending = false
        s.sort = .name
        s.query = "trip"
        s.toggleFormat("jpg")
        s.setSourceFilter(.cloud)
        s.focus(f.cloudJPG)
        s.setSelectionMode(true)
        s.activate(f.cloudJPG)
        let previousVisibleRevision = s.visibleRevision
        let previousTimelineRevision = s.timelineRevision
        s.clearFilters()
        try expect(s.visibleRevision == previousVisibleRevision + 1 && s.timelineRevision == previousTimelineRevision + 1,
                   "清除多个维度应只进行一次列表与时间线发布")
        try expect(s.query == "trip" && s.sort == .name && !s.descending && s.scope == .all,
                   "清筛选不能清搜索、排序和所在范围")
        try expect(s.selectedIDs == [f.cloudJPG.id] && s.navigationAnchorID == f.cloudJPG.id
                   && s.visibleItems[s.browseIndex].id == f.cloudJPG.id,
                   "幸存的选择与真实浏览锚点应保留")
        let revision = s.visibleRevision
        s.clearFilters()
        try expect(s.visibleRevision == revision, "没有条件时重置应不发布无意义修订")
    }

    private static func emptyResultsAndFirstStatus() async throws {
        let f = try Fixture(); defer { f.remove() }
        let s = f.store
        try expect(!s.hasLoadedOriginalCache && !s.isCheckingOriginalCache, "首次缓存状态应明确未知，不能冒充全部未下载")
        let source = CacheSource(ids: [])
        s.refreshOriginalDownloadStatus { await source.load($0) }
        try expect(s.isCheckingOriginalCache && !s.hasLoadedOriginalCache && s.visibleItems.count == f.items.count,
                   "首次磁盘检查只暴露状态、不遮盖已显示的全部媒体")
        try await wait { s.hasLoadedOriginalCache && !s.isCheckingOriginalCache }
        try expect(s.hasLoadedOriginalCache, "合法空缓存也必须结束未知状态")
        s.toggleFormat("AVIF")
        try expect(s.visibleItems.isEmpty && s.availableFormats.contains("AVIF"), "空结果保留所选格式与重置入口")
        s.clearFormatFilter()
        try expect(s.visibleItems.count == f.items.count, "空结果必须可一次清该格式恢复列表")
        await s.waitForFileOperations()
    }

    private static func viewerSurvivesDownloadStateChange() async throws {
        let f = try Fixture(); defer { f.remove() }
        let s = f.store
        let source = CacheSource(ids: [])
        s.refreshOriginalDownloadStatus { await source.load($0) }
        try await wait { s.hasLoadedOriginalCache && !s.isCheckingOriginalCache }
        s.setOriginalDownloadFilter(.notDownloaded)
        try await wait { !s.isCheckingOriginalCache }
        s.open(f.cloudJPG)
        let revision = s.visibleRevision
        await source.setIDs([f.cloudJPG.id])
        s.refreshOriginalDownloadStatus()
        try await wait { !s.isCheckingOriginalCache }
        try expect(s.previewID == f.cloudJPG.id && s.visibleRevision == revision,
                   "正在查看未下载照片时，原图完成不得关闭窗口或立即移除当前项目")
        s.applyFilters()
        try expect(s.previewID == f.cloudJPG.id && s.visibleItems.contains { $0.id == f.cloudJPG.id },
                   "缓存更新延后期间，自动目录/布局重算也不能间接关闭查看器")
        let step = s.visibleMediaIndex(id: f.cloudJPG.id) == s.visibleItems.count - 1 ? -1 : 1
        s.stepPreview(step)
        try expect(s.previewID != nil && s.previewID != f.cloudJPG.id,
                   "延后期间仍可安全连续切图，不能在切图setter中重排索引")
        s.closePreview()
        try expect(s.previewID == nil && !s.visibleItems.contains { $0.id == f.cloudJPG.id },
                   "关闭查看器应立即按最新原图状态移除已下载项")
        s.open(f.cloudPNG)
        await source.setIDs([f.cloudJPG.id, f.cloudPNG.id])
        s.refreshOriginalDownloadStatus()
        try await wait { !s.isCheckingOriginalCache }
        try expect(s.previewID == f.cloudPNG.id, "下一个未下载文件完成后也应保持查看器")
        s.setSourceFilter(.local)
        try expect(s.previewID == nil && s.originalDownloadFilter == .all && s.sourceFilter == .local,
                   "用户显式切换来源仍应即时应用，不被延后状态吞掉")
        s.setOriginalDownloadFilter(.downloaded)
        try await wait { !s.isCheckingOriginalCache }
        s.open(f.cloudJPG)
        await source.setIDs([])
        s.refreshOriginalDownloadStatus()
        try await wait { !s.isCheckingOriginalCache }
        try expect(s.previewID == f.cloudJPG.id, "正在看已下载文件时外部清缓存也不能使查看器突然关闭")
        s.closePreview()
        try expect(s.visibleItems.isEmpty, "关闭后应将清掉原图的项目从已下载范围移除")
        await s.waitForFileOperations()
    }

    private static func rollSurvivesDownloadStateChange() async throws {
        let f = try Fixture(); defer { f.remove() }
        let s = f.store
        let source = CacheSource(ids: [])
        s.refreshOriginalDownloadStatus { await source.load($0) }
        try await wait { s.hasLoadedOriginalCache && !s.isCheckingOriginalCache }
        s.setOriginalDownloadFilter(.notDownloaded)
        try await wait { !s.isCheckingOriginalCache }
        s.sort = .name
        s.descending = false
        s.layout = .browse
        s.focus(f.cloudJPG)
        let revision = s.visibleRevision
        await source.setIDs([f.cloudJPG.id])
        s.refreshOriginalDownloadStatus()
        try await wait { !s.isCheckingOriginalCache }
        try expect(s.visibleItems[s.browseIndex].id == f.cloudJPG.id && s.visibleRevision == revision,
                   "卷轴聚焦图片原图完成时不得被未下载筛选移除或重排")
        s.applyFilters()
        try expect(s.visibleItems[s.browseIndex].id == f.cloudJPG.id,
                   "自动目录和时间分组刷新仍需保留当前卷轴照片")
        let next = s.visibleItems.first { $0.id != f.cloudJPG.id }!
        let oldNextIndex = s.visibleMediaIndex(id: next.id)!
        let fraction = oldNextIndex < s.visibleItems.count - 1 ? 0.2 : -0.2
        s.recordBrowsePosition(position: Double(oldNextIndex) + fraction, item: next)
        let nextIndex = s.visibleMediaIndex(id: next.id)!
        try expect(!s.visibleItems.contains { $0.id == f.cloudJPG.id }
                   && s.visibleItems[s.browseIndex].id == next.id && s.navigationAnchorID == next.id,
                   "划走后应移除旧照片而保留新焦点的真实ID")
        try expect(abs(s.browsePosition - (Double(nextIndex) + fraction)) < 0.001,
                   "删除前一项后必须校正小数滚动坐标，不能回弹到图片中心")
        s.focus(f.cloudPNG)
        await source.setIDs([f.cloudJPG.id, f.cloudPNG.id])
        s.refreshOriginalDownloadStatus()
        try await wait { !s.isCheckingOriginalCache }
        try expect(s.visibleItems[s.browseIndex].id == f.cloudPNG.id, "下一张下载完成也必须独立保留")
        let target = s.visibleItems.first { $0.id != f.cloudPNG.id }!
        s.navigateBrowse(to: Double(s.visibleMediaIndex(id: target.id)!))
        try expect(!s.visibleItems.contains { $0.id == f.cloudPNG.id }
                   && s.visibleItems[s.browseIndex].id == target.id
                   && abs(s.browsePosition - Double(s.browseIndex)) < 0.001,
                   "时间轴点击切图也应结算旧项且不把旧序号用于新列表")
        await source.setIDs([])
        s.refreshOriginalDownloadStatus()
        try await wait { !s.isCheckingOriginalCache }
        let passingItem = s.visibleItems[0]
        let currentItem = s.visibleItems[2]
        s.recordBrowsePosition(position: 2.2, item: currentItem)
        await source.setIDs([passingItem.id])
        s.refreshOriginalDownloadStatus()
        try await wait { !s.isCheckingOriginalCache }
        try expect(!s.visibleItems.contains { $0.id == passingItem.id }
                   && s.visibleItems[s.browseIndex].id == currentItem.id
                   && abs(s.browsePosition - 1.2) < 0.001,
                   "用户已划走后延迟到达的完成通知不能将正在滚动的新照片拉回中心")
        await s.waitForFileOperations()
    }

    private static func rollPinRespectsExplicitActions() async throws {
        let f = try Fixture(); defer { f.remove() }
        let s = f.store
        let source = CacheSource(ids: [])
        s.refreshOriginalDownloadStatus { await source.load($0) }
        try await wait { s.hasLoadedOriginalCache && !s.isCheckingOriginalCache }
        s.setOriginalDownloadFilter(.notDownloaded)
        try await wait { !s.isCheckingOriginalCache }
        s.layout = .browse
        s.focus(f.cloudJPG)
        s.setSelectionMode(true)
        s.select(f.cloudJPG)
        s.select(f.cloudPNG, modifiers: [.command])
        s.focus(f.cloudJPG)
        let selected = s.selectedIDs
        await source.setIDs([f.cloudJPG.id])
        s.refreshOriginalDownloadStatus()
        try await wait { !s.isCheckingOriginalCache }
        s.focus(f.cloudPNG)
        try expect(s.selectedIDs == selected && s.visibleItems.contains { $0.id == f.cloudJPG.id },
                   "批量选择期间原图完成及焦点移动不能裁剪正在操作的选择快照")
        s.setSelectionMode(false)
        try expect(!s.visibleItems.contains { $0.id == f.cloudJPG.id }
                   && s.visibleItems[s.browseIndex].id == f.cloudPNG.id,
                   "退出多选应应用已完成原图状态并保留新焦点")
        await source.setIDs([f.cloudJPG.id, f.cloudPNG.id])
        s.refreshOriginalDownloadStatus()
        try await wait { !s.isCheckingOriginalCache }
        s.layout = .grid
        try expect(!s.visibleItems.contains { $0.id == f.cloudPNG.id },
                   "从卷轴回到列表应结算当前原图状态")
        s.layout = .browse
        s.focus(f.cloudHEIC)
        await source.setIDs([f.cloudJPG.id, f.cloudPNG.id, f.cloudHEIC.id])
        s.refreshOriginalDownloadStatus()
        try await wait { !s.isCheckingOriginalCache }
        s.query = "trip"
        try expect(!s.visibleItems.contains { $0.id == f.cloudHEIC.id },
                   "显式搜索即使仍匹配名称也应按最新下载状态重新应用")
        await source.setIDs([])
        s.refreshOriginalDownloadStatus()
        try await wait { !s.isCheckingOriginalCache }
        s.focus(f.cloudJPG)
        await source.setIDs([f.cloudJPG.id])
        s.refreshOriginalDownloadStatus()
        try await wait { !s.isCheckingOriginalCache }
        s.setSourceFilter(.local)
        try expectIDs(s, [f.localJPG, f.localVideo, f.localNoExtension], "显式来源筛选不能保留不合条件的云端项目")
        s.setOriginalDownloadFilter(.downloaded)
        try await wait { !s.isCheckingOriginalCache }
        s.focus(f.cloudJPG)
        await source.setIDs([])
        s.refreshOriginalDownloadStatus()
        try await wait { !s.isCheckingOriginalCache }
        try expect(s.visibleItems[s.browseIndex].id == f.cloudJPG.id,
                   "已下载范围中的当前卷轴照片被驱逐时也应保持连续浏览")
        s.selectScope(.favorites)
        try expect(s.visibleItems.isEmpty, "显式切换范围必须立即清除卷轴下载保留")
        await s.waitForFileOperations()
    }

    private static func expectIDs(_ s: AppStore, _ expected: [MediaItem], _ message: String) throws {
        try expect(Set(s.visibleItems.map(\.id)) == Set(expected.map(\.id)), message)
    }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !value() { throw CheckError(message: message) }
    }
    private static func wait(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(6)
        while !(await predicate()) {
            if Date() > deadline { throw CheckError(message: "异步缓存状态超时") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private struct CheckError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private actor CacheSource {
        var ids: Set<String>
        var delay: Duration
        var count = 0
        init(ids: Set<String>, delay: Duration = .zero) { self.ids = ids; self.delay = delay }
        func setIDs(_ ids: Set<String>) { self.ids = ids }
        func calls() -> Int { count }
        func load(_ items: [MediaItem]) async -> Set<String> {
            count += 1
            let result = ids.intersection(items.map(\.id))
            if delay != .zero { try? await Task.sleep(for: delay) }
            return result
        }
    }

    @MainActor private final class Fixture {
        let directory: URL
        let store: AppStore
        let localJPG: MediaItem
        let localVideo: MediaItem
        let localNoExtension: MediaItem
        let cloudJPG: MediaItem
        let cloudPNG: MediaItem
        let cloudVideo: MediaItem
        let cloudHEIC: MediaItem
        let items: [MediaItem]
        init() throws {
            let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Filmbox-Filters-\(UUID())", isDirectory: true)
            directory = fixtureDirectory
            try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
            let date = Date(timeIntervalSince1970: 1_750_000_000)
            let account = UUID()
            func local(_ name: String, _ kind: MediaKind) -> MediaItem {
                MediaItem(url: fixtureDirectory.appendingPathComponent("Local/\(name)"), kind: kind,
                          fileSize: 100, modifiedDate: date, createdDate: date)
            }
            func cloud(_ name: String, _ kind: MediaKind) -> MediaItem {
                let ref = CloudMediaReference(accountID: account, fileID: name, parentID: "trip",
                                              remotePath: "/Trip/\(name)", revision: "one")
                return MediaItem(cloud: ref, kind: kind, fileSize: 200, modifiedDate: date, createdDate: date)
            }
            localJPG = local("trip-local.JPG", .image)
            localVideo = local("trip-local.mp4", .video)
            localNoExtension = local("trip-without-extension", .image)
            cloudJPG = cloud("trip-cloud.jpg", .image)
            cloudPNG = cloud("trip-cloud.PnG", .image)
            cloudVideo = cloud("trip-cloud.MP4", .video)
            cloudHEIC = cloud("trip-cloud.HEIC", .image)
            items = [localJPG, localVideo, localNoExtension, cloudJPG, cloudPNG, cloudVideo, cloudHEIC]
            store = AppStore(directory: directory.appendingPathComponent("Catalog", isDirectory: true))
            store.items = items
            store.applyFilters()
        }
        func remove() { store.cancelScan(); try? FileManager.default.removeItem(at: directory) }
    }
}
