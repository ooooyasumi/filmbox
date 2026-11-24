import AppKit
import FilmboxCore
import Foundation
import Observation

@main @MainActor private struct IndexFeedbackChecks {
    static var passed = 0
    @MainActor private final class Probe { var changed = false }
    static func main() async {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Filmbox-IndexFeedback-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = AppStore(directory: directory.appendingPathComponent("catalog"))
            let local = MediaLibrary(url: directory.appendingPathComponent("Album"))
            let cloud = MediaLibrary(cloud: .init(accountID: UUID(), folderID: "one", path: "/Photos"))
            let other = MediaLibrary(cloud: .init(accountID: UUID(), folderID: "two", path: "/Photos"))
            let libraries = [local, cloud, other]
            store.libraries = libraries
            store.cloudIndexProgress = [cloud.id: .init(photos: 3, videos: 2), other.id: .init(photos: 90, videos: 8), UUID(): .init(photos: 999)]
            store.isScanning = true // Global background work, not a local scan.
            store.scope = .folders
            store.directorySelection = .init(included: [local.selectionPath])
            try check(store.canvasIndexActivity == nil, "选择本地文件夹时不引用其他云盘的索引状态")
            store.setSourceFilter(.cloud)
            try check(store.canvasIndexActivity == nil && store.hasActiveFilters,
                      "本地文件夹保留云端筛选的空结果，不被后台索引覆盖")
            store.setSourceFilter(.all)
            store.directorySelection = .init(included: [cloud.selectionPath])
            try check(store.canvasIndexActivity == .cloud(.init(photos: 3, videos: 2)), "云端资源库只使用自己的计数")
            store.setSourceFilter(.local)
            try check(store.canvasIndexActivity == nil, "云端文件夹选择本地来源后不显示云端索引")
            store.setSourceFilter(.all)
            store.directorySelection = .init(included: [other.selectionPath])
            try check(store.canvasIndexActivity == .cloud(.init(photos: 90, videos: 8)), "切换云库即时切换提示计数")
            store.directorySelection = .init(included: [local.selectionPath, cloud.selectionPath])
            try check(store.canvasIndexActivity == .cloud(.init(photos: 3, videos: 2)), "多选范围只累计所选云库，不混入第三个资源库")
            store.directorySelection = .init(included: [cloud.selectionPath + "/Trip"])
            try check(store.canvasIndexActivity == .cloud(nil), "云端子目录显示相关索引，不冒用整个资源库的照片数量")
            store.directorySelection = .init(included: [cloud.selectionPath], excluded: [cloud.selectionPath])
            try check(store.canvasIndexActivity == nil, "完全排除的云库不参与索引提示")
            store.directorySelection = .init(included: [cloud.selectionPath + "-old"])
            try check(store.canvasIndexActivity == nil, "同名前缀目录不误认当前索引范围")
            store.directorySelection = .init()
            try check(store.canvasIndexActivity == nil, "没有选择文件夹时不显示无关索引")
            store.scope = .all
            try check(store.canvasIndexActivity == .cloud(.init(photos: 93, videos: 10)), "所有项目累计真实云库进度，忽略已移除库的遗留进度")
            store.setSourceFilter(.local)
            try check(store.canvasIndexActivity == nil, "所有项目仅看本地时不受全局云端工作影响")
            store.setSourceFilter(.all)
            for scope in [AppStore.Scope.favorites, .hidden, .album(UUID())] {
                store.scope = scope
                try check(store.canvasIndexActivity == nil, "收藏、隐藏或影集空状态不被索引状态替换：\(scope)")
            }
            store.scope = .folders; store.directorySelection = .init(included: [cloud.selectionPath])
            for phase in [CloudIndexPhase.ready, .paused, .failed] {
                store.cloudIndexProgress[cloud.id]?.phase = phase
                try check(store.canvasIndexActivity == nil, "就绪、暂停与失败不能冒充正在索引：\(phase)")
            }
            store.cloudIndexProgress[cloud.id]?.phase = .indexing
            // Start a real local scan without yielding the main actor, so its
            // pending state is deterministic and no network task can begin.
            store.libraries = [local]; store.refresh()
            store.libraries = libraries
            store.cloudIndexProgress[cloud.id] = .init(photos: 3, videos: 2)
            store.cloudIndexProgress[other.id] = .init(photos: 90, videos: 8)
            store.directorySelection = .init(included: [local.selectionPath])
            try check(store.canvasIndexActivity == .local && store.canvasIndexActivity?.detail == nil,
                      "本地真正扫描时显示本地整理提示，不显示云端计数")
            store.directorySelection = .init(included: [local.selectionPath, cloud.selectionPath])
            try check(store.canvasIndexActivity == .mixed && store.canvasIndexActivity?.detail == nil,
                      "混合范围同时扫描时显示中性整理提示")
            store.setSourceFilter(.cloud)
            try check(store.canvasIndexActivity == .cloud(.init(photos: 3, videos: 2)), "混合范围仅看云端时使用云端进度")
            store.setSourceFilter(.local)
            try check(store.canvasIndexActivity == .local, "混合范围仅看本地时只显示本地整理")
            let probe = Probe()
            withObservationTracking { _ = store.canvasIndexActivity } onChange: {
                MainActor.assumeIsolated { probe.changed = true }
            }
            store.cancelScan()
            try check(probe.changed, "本地扫描状态单独变化会刷新画布，不依赖全局任务变化")
            try check(store.canvasIndexActivity == nil, "停止扫描后及时退出索引提示")
            try check(AppStore.CanvasIndexActivity.local.title == "正在整理资源库…"
                      && AppStore.CanvasIndexActivity.cloud(nil).title == "正在建立云端索引…",
                      "来源提示文案明确区分本地和云端")
            await store.waitForFileOperations()
            print("\(passed)项索引提示检查通过；无真实账号或网络请求")
        } catch { print("FAIL \(error)"); exit(1) }
    }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.failed(message) }
        passed += 1; print("✓ \(message)")
    }
    enum Failure: Error { case failed(String) }
}
