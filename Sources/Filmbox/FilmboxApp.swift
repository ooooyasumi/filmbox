import SwiftUI
import AppKit

@main
struct FilmboxApp: App {
    @NSApplicationDelegateAdaptor(FilmboxDelegate.self) private var delegate
    @State private var store = AppStore(directory: developmentCatalogDirectory())

    var body: some Scene {
        Window("菲林盒", id: "main") {
            MainView(store: store)
                .frame(minWidth: 840, minHeight: 560)
                .onAppear { delegate.store = store; store.refreshIfNeeded() }
        }
        .defaultSize(width: 1260, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands { FilmboxCommands(store: store) }
        Window("查看器", id: "viewer") {
            ViewerView(store: store)
                .frame(minWidth: 800, minHeight: 560)
                .windowFullScreenBehavior(.enabled)
                .onDisappear { store.closePreview() }
        }
        .defaultSize(width: 1160, height: 800)
        .windowManagerRole(.principal)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)
        Settings { SettingsView(store: store) }
    }
}

@MainActor final class FilmboxDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        Task {
            await store.waitForFileOperations()
            let saved = await store.flushImmediately()
            if saved { await CloudGateway.shared.shutdown() }
            if !saved { store.cancelTermination() }
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
    func application(_ application: NSApplication, open urls: [URL]) { store?.addFolders(urls) }
}

struct FilmboxCommands: Commands {
    let store: AppStore
    var body: some Commands {
        CommandGroup(replacing: .appInfo) { Button("关于菲林盒") { store.showAbout = true } }
        CommandGroup(replacing: .newItem) {
            Button("新建影集…", systemImage: "rectangle.stack.badge.plus") { store.promptNewAlbum() }.keyboardShortcut("n")
            Button("添加资源库…", systemImage: "plus") { store.showAddLibrary = true }.keyboardShortcut("o")
            Button("刷新资源库", systemImage: "arrow.clockwise") { store.refresh() }.keyboardShortcut("r")
        }
        CommandGroup(after: .pasteboard) {
            Button("复制文件路径") { store.copyFiles(store.managementItems, pathsOnly: true) }.keyboardShortcut("c", modifiers: [.command, .option]).disabled(store.managementItems.isEmpty)
            Divider()
            Button("取消选择") { store.clearSelection() }.keyboardShortcut("a", modifiers: [.command, .shift])
        }
        CommandGroup(before: .toolbar) {
            Button("所有项目") { store.selectScope(.all) }.keyboardShortcut("1")
            Button("收藏") { store.selectScope(.favorites) }.keyboardShortcut("2")
            Button("隐藏") { store.selectScope(.hidden) }
            Divider()
            Button("时间线") { store.layout = .grid }.keyboardShortcut("3")
            Button("翻阅") { store.layout = .browse }.keyboardShortcut("4")
            Button("放大") { zoom("in") }.keyboardShortcut("+")
            Button("缩小") { zoom("out") }.keyboardShortcut("-")
            Button("适应窗口") { zoom("fit") }.keyboardShortcut("0")
                .disabled(store.previewID == nil || store.focusedItem?.kind != .image)
            Button("实际大小（100%）") { zoom("actualSize") }.keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(store.previewID == nil || store.focusedItem?.kind != .image)
            Button("显示信息") { store.toggleInspector() }.keyboardShortcut("i")
            Divider()
            Button("打开查看器") { store.open() }.keyboardShortcut(.return, modifiers: []).disabled(store.visibleItems.isEmpty)
            Button("在访达中显示") { for item in store.managementItems { store.reveal(item) } }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(store.managementItems.isEmpty)
        }
        CommandMenu("项目") {
            Button("收藏 / 取消收藏") { store.setFavorite(store.managementItems) }.keyboardShortcut("l").disabled(store.managementItems.isEmpty)
            Button("隐藏 / 恢复显示") { store.toggleHiddenForManagementItems() }.keyboardShortcut("h", modifiers: [.command, .shift]).disabled(store.managementItems.isEmpty)
            Menu("添加到影集") {
                Button("新建影集…") { store.promptNewAlbum(addingIDs: Set(store.managementItems.map(\.id))) }
                ForEach(store.albums) { album in
                    Button(album.name) { store.addToAlbum(Set(store.managementItems.map(\.id)), albumID: album.id) }
                }
            }.disabled(store.managementItems.isEmpty)
            Button("从影集移除") {
                if case .album(let id) = store.scope { store.removeFromAlbum(Set(store.managementItems.map(\.id)), albumID: id) }
            }.disabled(store.managementItems.isEmpty || !isAlbumScope)
            Divider()
            Button("重命名…") { if let item = store.managementItems.first { store.promptRename(item) } }
                .keyboardShortcut(KeyEquivalent("\u{F705}"), modifiers: [])
                .disabled(store.managementItems.count != 1 || store.managementItems.contains { !$0.isLocal } || store.isPerformingFileOperation)
            Button("移到废纸篓…") { store.confirmTrash(store.managementItems) }.keyboardShortcut(.delete, modifiers: .command)
                .disabled(store.managementItems.isEmpty || store.managementItems.contains { !$0.isLocal } || store.isPerformingFileOperation)
        }
        CommandGroup(replacing: .help) {
            Button("键盘快捷键") { store.showShortcuts = true }.keyboardShortcut("/", modifiers: .command)
        }
    }
    private var isAlbumScope: Bool { if case .album = store.scope { return true }; return false }
    private func zoom(_ command: String) {
        if NSApp.keyWindow?.identifier?.rawValue == "viewer" {
            NotificationCenter.default.post(name: Notification.Name("FilmboxViewerZoom"), object: command)
        } else if command == "in" || command == "out" { store.zoomTimeline(command == "in" ? 1 : -1) }
    }
}

// A separate development bundle can opt into a temporary catalog for UI checks.
// Release builds always use the normal user catalog.
private func developmentCatalogDirectory() -> URL? {
    #if DEBUG
    if let path = Bundle.main.object(forInfoDictionaryKey: "FilmboxDevelopmentCatalog") as? String {
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    #endif
    return nil
}
