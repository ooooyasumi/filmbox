import AppKit
import SwiftUI
import Observation
import FilmboxCore

// SwiftUI scene IDs and native window identifiers are separate. Only a root
// identity marker can register a window; no title or arbitrary key-window fallback.
struct NativeWindowIdentity: NSViewRepresentable {
    let identifier: String
    func makeNSView(context: Context) -> WindowIdentityView { WindowIdentityView(identifier: identifier) }
    func updateNSView(_ view: WindowIdentityView, context: Context) { view.nativeIdentifier = identifier; view.assignIdentity() }
}

@MainActor final class WindowIdentityView: NSView {
    var nativeIdentifier: String
    private var lastAssignment: String?
    init(identifier: String) { nativeIdentifier = identifier; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        WindowManagementContext.shared.log("identity.move role=\(nativeIdentifier) window=\(WindowManagementContext.describe(window)) frame=\(frame)")
        assignIdentity()
    }
    func assignIdentity() {
        guard let window else { return }
        let assignment = "\(ObjectIdentifier(window))|\(nativeIdentifier)|\(window.identifier?.rawValue ?? "nil")"
        if assignment != lastAssignment {
            lastAssignment = assignment
            WindowManagementContext.shared.log("identity.assign role=\(nativeIdentifier) before=\(WindowManagementContext.describe(window))")
        }
        WindowManagementContext.shared.register(window, as: nativeIdentifier)
        // SwiftUI can finish assigning its own native identifier after mounting.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            WindowManagementContext.shared.register(window, as: self.nativeIdentifier)
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor @Observable private final class WindowManagementContext {
    static let shared = WindowManagementContext()
    var revision = 0
    private final class Registration {
        weak var window: NSWindow?
        let role: String
        init(_ window: NSWindow, role: String) { self.window = window; self.role = role }
    }
    @ObservationIgnored private var registrations: [ObjectIdentifier: Registration] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastContext = ""
    @ObservationIgnored private var lastDecision = ""

    private init() {
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
            NSWindow.didUpdateNotification, NSWindow.willCloseNotification,
            NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSControl.textDidBeginEditingNotification, NSControl.textDidEndEditingNotification
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let reason = notification.name.rawValue
                MainActor.assumeIsolated { self?.refresh(reason: reason) }
            })
        }
        refresh(reason: "init")
    }
    func register(_ window: NSWindow, as role: String) {
        guard role == "main" || role == "viewer" else { return }
        registrations[ObjectIdentifier(window)] = Registration(window, role: role)
        if window.identifier?.rawValue != role {
            window.identifier = NSUserInterfaceItemIdentifier(role)
            log("identity.assigned role=\(role) window=\(Self.describe(window))")
        }
        refresh(reason: "identity.register")
    }
    func role(of window: NSWindow) -> String? {
        registrations = registrations.filter { $0.value.window != nil }
        if let registered = registrations[ObjectIdentifier(window)], registered.window === window { return registered.role }
        let identifier = window.identifier?.rawValue
        return identifier == "main" || identifier == "viewer" ? identifier : nil
    }
    private func refresh(reason: String) {
        if let key = NSApp?.keyWindow, let registered = registrations[ObjectIdentifier(key)], registered.window === key,
           key.identifier?.rawValue != registered.role {
            key.identifier = NSUserInterfaceItemIdentifier(registered.role)
            log("identity.restored role=\(registered.role) window=\(Self.describe(key))")
        }
        let context = "active=\(NSApp?.isActive ?? false) key=\(Self.describe(NSApp?.keyWindow)) main=\(Self.describe(NSApp?.mainWindow))"
        guard context != lastContext else { return }
        lastContext = context
        revision += 1
        log("context revision=\(revision) reason=\(reason) \(context)")
    }
    func recordDecision(_ reason: String, selected: Int, visible: Int, result: Int) {
        let decision = "management reason=\(reason) selected=\(selected) visible=\(visible) result=\(result) \(lastContext)"
        guard decision != lastDecision else { return }
        lastDecision = decision
        log(decision)
    }
    static func describe(_ window: NSWindow?) -> String {
        guard let window else { return "nil" }
        let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        return "{object=\(ObjectIdentifier(window)) number=\(window.windowNumber) id=\(window.identifier?.rawValue ?? "nil") key=\(window.isKeyWindow) visible=\(window.isVisible) sheet=\(window.attachedSheet != nil) sheetParent=\(window.sheetParent != nil) responder=\(responder)}"
    }
    func log(_ message: String) {
        #if DEBUG
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".build/WindowDiagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("window-\(ProcessInfo.processInfo.processIdentifier).log")
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 512 * 1024 { return }
        guard let data = "\(Date().ISO8601Format()) \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else { try? data.write(to: url, options: .atomic) }
        #endif
    }
}

@MainActor extension AppStore {
    var managementItems: [MediaItem] {
        // Read observable inputs before a native-window guard can return early.
        // Otherwise Commands created before a key window never observe selection.
        let selected = selectedIDs
        let visible = visibleItems
        let preview = previewID
        let context = WindowManagementContext.shared
        _ = context.revision
        func rejected(_ reason: String) -> [MediaItem] {
            context.recordDecision(reason, selected: selected.count, visible: visible.count, result: 0)
            return []
        }
        guard let window = NSApp?.keyWindow else { return rejected("no-key-window") }
        guard window.attachedSheet == nil, window.sheetParent == nil else { return rejected("modal-window") }
        guard !(window.firstResponder is NSTextView) else { return rejected("text-editor") }
        guard let role = context.role(of: window) else { return rejected("unregistered-window") }
        let result: [MediaItem]
        if role == "viewer" { result = preview.flatMap { id in visible.first { $0.id == id } }.map { [$0] } ?? [] }
        else { result = visible.filter { selected.contains($0.id) } }
        context.recordDecision(role, selected: selected.count, visible: visible.count, result: result.count)
        return result
    }

    func zoomTimeline(with event: NSEvent) {
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : -event.scrollingDeltaX
        guard delta.isFinite, abs(delta) > 0.001 else { return }
        let amount = max(-0.4, min(0.4, Double(delta) * (event.hasPreciseScrollingDeltas ? 0.009 : 0.035)))
        setActiveTimelineSize(activeTimelineSize * exp(amount))
    }

    func promptNewAlbum(addingIDs: Set<String> = []) {
        NamePrompt.present(title: "新建影集", value: "", placeholder: "影集名称", confirm: "创建") { [weak self] name in
            guard let self, let id = self.createAlbum(name: name, addingIDs: addingIDs) else { return }
            self.selectScope(.album(id))
        }
    }

    func promptRenameLibrary(_ library: MediaLibrary) {
        NamePrompt.present(title: "资源库名称", value: library.name, placeholder: "资源库名称", confirm: "存储") { [weak self] name in
            self?.renameLibrary(library.id, to: name)
        }
    }

    func promptRenameAlbum(_ album: MediaAlbum) {
        NamePrompt.present(title: "重命名影集", value: album.name, placeholder: "影集名称", confirm: "存储") { [weak self] name in
            self?.renameAlbum(album.id, to: name)
        }
    }

    func confirmDeleteAlbum(_ album: MediaAlbum) {
        let alert = NSAlert()
        alert.messageText = "删除影集“\(album.name)”？"
        alert.informativeText = "影集中的原文件会保留，也不会影响其他影集。"
        alert.addButton(withTitle: "删除影集")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        present(alert) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.deleteAlbum(album.id) }
        }
    }

    func promptRename(_ item: MediaItem) {
        guard item.isLocal, !isPerformingFileOperation else { return }
        NamePrompt.present(title: "重命名", value: item.url.deletingPathExtension().lastPathComponent,
                           placeholder: "文件名称", confirm: "重命名", detail: "扩展名 .\(item.url.pathExtension) 会保留。") { [weak self] name in
            Task { await self?.rename(item, to: name) }
        }
    }

    func confirmTrash(_ targets: [MediaItem]) {
        guard !targets.isEmpty, targets.allSatisfy(\.isLocal), !isPerformingFileOperation else { return }
        let alert = NSAlert()
        alert.messageText = targets.count == 1 ? "将“\(targets[0].name)”移到废纸篓？" : "将 \(targets.count) 个项目移到废纸篓？"
        alert.informativeText = "这会移动原文件。你可以在访达的废纸篓中恢复。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { await self?.trash(targets) }
        }
    }

    func toggleHiddenForManagementItems() {
        let ids = Set(managementItems.map(\.id))
        guard !ids.isEmpty else { return }
        setHidden(!ids.isSubset(of: hiddenIDs), ids: ids)
    }

    func setFavorite(_ targets: [MediaItem]) {
        let ids = Set(targets.map(\.id))
        if ids.isSubset(of: favorites) { favorites.subtract(ids) } else { favorites.formUnion(ids) }
        save()
        applyFilters()
    }

    func copyFiles(_ targets: [MediaItem], pathsOnly: Bool = false, to pasteboard: NSPasteboard = .general) {
        guard !targets.isEmpty else { return }
        if pathsOnly {
            pasteboard.clearContents()
            pasteboard.setString(targets.map(\.displayPath).joined(separator: "\n"), forType: .string)
            notify("已复制路径")
        } else {
            materialize(targets) { [weak self] urls in
                pasteboard.clearContents()
                if pasteboard.writeObjects(urls as [NSURL]) { self?.notify("已复制 \(urls.count) 个项目") }
                else { self?.errorMessage = "无法复制所选文件，请重试。" }
            }
        }
    }

    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow {
            guard window.attachedSheet == nil, window.sheetParent == nil else { return }
            alert.beginSheetModal(for: window, completionHandler: completion)
        }
        else { completion(alert.runModal()) }
    }
}

@MainActor private enum NamePrompt {
    static func present(title: String, value: String, placeholder: String, confirm: String, detail: String = "", completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
        field.setAccessibilityLabel(placeholder)
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            completion(field.stringValue)
        }
        if let window = NSApp.keyWindow {
            guard window.attachedSheet == nil, window.sheetParent == nil else { return }
            alert.beginSheetModal(for: window, completionHandler: handle)
        }
        else { handle(alert.runModal()) }
    }
}

struct MediaContextMenu: View {
    let store: AppStore
    let item: MediaItem
    var includeOpen = true
    private var targets: [MediaItem] {
        if !includeOpen { return [item] }
        return store.selectedIDs.contains(item.id) ? store.selectedItems : [item]
    }
    private var ids: Set<String> { Set(targets.map(\.id)) }
    var body: some View {
        if includeOpen { Button("打开查看器") { store.open(item) } }
        Button(ids.isSubset(of: store.favorites) ? "取消收藏" : "收藏") { store.setFavorite(targets) }
        Button(ids.isSubset(of: store.hiddenIDs) ? "恢复显示" : "隐藏项目") { store.setHidden(!ids.isSubset(of: store.hiddenIDs), ids: ids) }
        Menu("添加到影集") {
            Button("新建影集…") { store.promptNewAlbum(addingIDs: ids) }
            if !store.albums.isEmpty { Divider() }
            ForEach(store.albums) { album in
                Button(album.name) { store.addToAlbum(ids, albumID: album.id) }
                    .disabled(ids.isSubset(of: album.itemIDs))
            }
        }
        if case .album(let id) = store.scope {
            Button("从影集移除") { store.removeFromAlbum(ids, albumID: id) }
        }
        Divider()
        if targets.contains(where: { !$0.isLocal }) {
            Button("下载原图与原视频") { store.downloadOriginals(targets) }
        }
        Button("重命名…") { store.promptRename(item) }.disabled(!item.isLocal || targets.count != 1 || store.isPerformingFileOperation || store.isOffline(item))
        Button(item.isLocal ? "在访达中显示" : "下载并在访达中显示") { for target in targets { store.reveal(target) } }
        Button("使用默认应用打开") { store.openExternally(item) }.disabled(targets.count != 1)
        Button("复制") { store.copyFiles(targets) }
        Button("复制文件路径") { store.copyFiles(targets, pathsOnly: true) }
        Divider()
        Button("移到废纸篓…", role: .destructive) { store.confirmTrash(targets) }
            .disabled(targets.contains { !$0.isLocal } || store.isPerformingFileOperation || targets.allSatisfy { store.isOffline($0) })
    }
}

@MainActor enum MediaMenus {
    static func make(store: AppStore, items: [MediaItem], includeOpen: Bool = true) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let first = items.first else { return menu }
        let ids = Set(items.map(\.id))
        func add(_ title: String, enabled: Bool = true, to parent: NSMenu? = nil, action: @escaping @MainActor () -> Void) {
            let entry = ActionMenuItem(title: title, action: #selector(ActionMenuItem.invoke), keyEquivalent: "")
            entry.handler = action
            entry.target = entry
            entry.isEnabled = enabled
            (parent ?? menu).addItem(entry)
        }
        if includeOpen { add("打开查看器") { store.open(first) } }
        add(ids.isSubset(of: store.favorites) ? "取消收藏" : "收藏") { store.setFavorite(items) }
        add(ids.isSubset(of: store.hiddenIDs) ? "恢复显示" : "隐藏项目") { store.setHidden(!ids.isSubset(of: store.hiddenIDs), ids: ids) }
        let albumsMenu = NSMenu()
        albumsMenu.autoenablesItems = false
        add("新建影集…", to: albumsMenu) { store.promptNewAlbum(addingIDs: ids) }
        if !store.albums.isEmpty { albumsMenu.addItem(.separator()) }
        for album in store.albums {
            add(album.name, enabled: !ids.isSubset(of: album.itemIDs), to: albumsMenu) { store.addToAlbum(ids, albumID: album.id) }
        }
        let albumsEntry = NSMenuItem(title: "添加到影集", action: nil, keyEquivalent: "")
        albumsEntry.submenu = albumsMenu
        menu.addItem(albumsEntry)
        if case .album(let id) = store.scope { add("从影集移除") { store.removeFromAlbum(ids, albumID: id) } }
        menu.addItem(.separator())
        if items.contains(where: { !$0.isLocal }) {
            add("下载原图与原视频") { store.downloadOriginals(items) }
        }
        add("重命名…", enabled: first.isLocal && items.count == 1 && !store.isPerformingFileOperation && !store.isOffline(first)) { store.promptRename(first) }
        add(items.allSatisfy(\.isLocal) ? "在访达中显示" : "下载并在访达中显示") { for item in items { store.reveal(item) } }
        add("使用默认应用打开", enabled: items.count == 1) { store.openExternally(first) }
        add("复制") { store.copyFiles(items) }
        add("复制文件路径") { store.copyFiles(items, pathsOnly: true) }
        menu.addItem(.separator())
        add("移到废纸篓…", enabled: items.allSatisfy(\.isLocal) && !store.isPerformingFileOperation && !items.allSatisfy { store.isOffline($0) }) { store.confirmTrash(items) }
        return menu
    }
}
