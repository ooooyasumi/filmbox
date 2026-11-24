import AppKit
import FilmboxCore

@main @MainActor struct LibraryUXChecks {
    static var count = 0
    static func check(_ ok: Bool, _ message: String) throws {
        guard ok else { throw NSError(domain: message, code: 1) }
        count += 1; print("✓ \(message)")
    }
    static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(".filmbox-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Pictures"), hidden = folder.appendingPathComponent(".private")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = bitmap.representation(using: .png, properties: [:])!
        for name in ["one.png", ".two.png", "._three.png", ".private/four.png"] { try data.write(to: folder.appendingPathComponent(name)) }
        let library = MediaLibrary(url: folder), nested = MediaLibrary(url: hidden)
        let scan = MediaScanner()
        let normal = await scan.scan(libraries: [library])
        try check(normal.items.count == 1, "默认不索引点文件、AppleDouble及点目录的媒体")
        let full = await scan.scan(libraries: [library], ignoreDotFiles: false)
        try check(full.items.count == 3, "关闭忽略选项收录点命名媒体，AppleDouble元数据仍不伪装成图片")
        let store = AppStore(directory: root.appendingPathComponent("catalog"))
        store.libraries = [library, nested]; store.items = full.items
        store.selectScope(.all)
        try check(store.folderState(folder.path) == .all && store.folderState(hidden.path) == .all, "所有项目勾选全部根目录，包括嵌套库")
        try check(store.visibleItems.count == 1, "已有索引中的点文件也默认从显示中排除")
        store.toggleFolder(hidden.path)
        try check(store.scope == .folders && store.folderState(hidden.path) == .none && store.folderState(folder.path) == .partial, "从所有项目取消子库时保留其他目录选择")
        store.renameLibrary(library.id, to: "旅行记忆")
        try check(store.libraries.first?.name == "旅行记忆" && store.libraries.first?.url.path == folder.path, "资源库别名不更改磁盘文件夹")
        store.renameLibrary(library.id, to: "   ")
        try check(store.libraries.first?.name == "旅行记忆", "空别名不会覆盖已有名称")
        store.moveLibrary(library.id, to: nested.id)
        try check(store.libraries.map(\.id) == [nested.id, library.id], "拖放可以向下排序")
        store.moveLibrary(library.id, to: nested.id)
        try check(store.libraries.map(\.id) == [library.id, nested.id], "拖放可以向上排序")
        _ = await store.flushImmediately()
        let saved = try CatalogPersistence(directory: root.appendingPathComponent("catalog")).load()
        try check(saved.libraries.map(\.id) == store.libraries.map(\.id) && saved.libraries.first?.name == "旅行记忆", "别名和排序写入资料库并可恢复")
        store.libraries = [MediaLibrary(cloud: .init(accountID: UUID(), folderID: "one", path: "/Photos"))]
        try check(!CloudTasksButton.shouldShow(for: store), "空闲云库不再常驻下载图标")
        let loading = AppStore(directory: root.appendingPathComponent("loading"))
        loading.libraries = [library]
        loading.refreshLocalLibraries()
        try check(loading.isRefreshing(library) && loading.count(in: library.selectionPath) == 0, "首次扫描在数量为零时立即发布加载状态")
        for _ in 0..<200 where loading.isScanning { try await Task.sleep(for: .milliseconds(10)) }
        try check(!loading.isRefreshing(library) && loading.count(in: library.selectionPath) == 1, "首次读取完成后以实际数量替换加载状态")
        _ = await loading.flushImmediately()
        print("\(count)项资源库体验检查通过；仅使用临时合成图片")
    }
}
