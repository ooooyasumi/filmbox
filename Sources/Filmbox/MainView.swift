import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FilmboxCore
import Observation

struct MainView: View {
    @Bindable var store: AppStore
    @State private var isDropTarget = false
    @State private var sidebarVisible = true
    @State private var searchFocused = false
    @State private var cloudConnectionRequest: CloudConnectionRequest?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @AppStorage("refreshOnActivation") private var refreshOnActivation = true
    @AppStorage("appearance") private var appearance = "system"
    private var palette: LightTablePalette { LightTablePalette(dark: scheme == .dark) }

    var body: some View {
        HSplitView {
            if sidebarVisible {
                SidebarView(store: store).frame(minWidth: 186, idealWidth: 216, maxWidth: 248)
            }
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    header(width: geometry.size.width)
                    controls
                    Divider().overlay(palette.border)
                    CloudConnectionBanner(store: store)
                    HStack(spacing: 0) {
                        canvas
                        if store.layout == .grid && !store.timelineSections.isEmpty && geometry.size.width > (store.showInspector ? 850 : 530) {
                            Rectangle().fill(palette.border.opacity(0.6)).frame(width: 0.5)
                            LineDateSidebar(store: store)
                                .frame(width: 138)
                        }
                        if store.showInspector {
                            Divider().overlay(palette.border)
                            InspectorView(store: store).frame(width: 280)
                        }
                    }
                    Divider().overlay(palette.border)
                    statusBar
                }.background(palette.canvas)
            }.frame(minWidth: 500)
        }
        .background(palette.panel)
        .background(NativeWindowIdentity(identifier: "main").frame(width: 0, height: 0).accessibilityHidden(true))
        .background(MediaDoubleClickMonitor(store: store).frame(width: 0, height: 0).accessibilityHidden(true))
        .tint(LightTablePalette.blue)
        .onCopyCommand {
            let items = store.selectedItems
            if items.contains(where: { !$0.isLocal }) { store.copyFiles(items); return [] }
            return items.compactMap { NSItemProvider(contentsOf: $0.url) }
        }
        .onExitCommand {
            if store.isSelectionMode { store.setSelectionMode(false) }
            else { store.clearSelection() }
        }
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .bottom) {
            if let notice = store.notice {
                Text(notice).font(.callout).foregroundStyle(palette.text)
                    .padding(.horizontal, 16).padding(.vertical, 10).background(palette.raised, in: RoundedRectangle(cornerRadius: 9))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    .padding(.bottom, 48).transition(.opacity).allowsHitTesting(false)
            }
        }
        .background {
            Button("搜索") { searchFocused = true }.keyboardShortcut("f").hidden().frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .modifier(CloudBackgroundLoadModifier(store: store))
        .task { store.refreshOriginalDownloadStatus { await MediaAssetResolver.shared.cachedOriginalIDs(for: $0) } }
        .onReceive(NotificationCenter.default.publisher(for: .filmboxCloudOriginalCacheChanged)) { _ in
            store.refreshOriginalDownloadStatus { await MediaAssetResolver.shared.cachedOriginalIDs(for: $0) }
        }
        .onChange(of: CloudTransferCenter.shared.accountIssues) { _, _ in store.applyCloudConnectionIssues() }
        .task { store.applyCloudConnectionIssues() }
        .onChange(of: store.isScanning) { _, scanning in
            if !scanning { NotificationCenter.default.post(name: Notification.Name("FilmboxPreviewRetry"), object: nil) }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { notification in store.volumeDidMount(notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { notification in store.volumeDidUnmount(notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL) }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FilmboxCloudMetadata")).receive(on: RunLoop.main)) { notification in
            store.applyCloudMetadata(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .filmboxRecoveryRequested)) { notification in
            if let request = notification.object as? ResourceRecoveryRequest { store.recover(request) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.resumeRecoverableResources() }
        .onReceive(NotificationCenter.default.publisher(for: .filmboxNetworkRestored)) { _ in store.resumeRecoverableResources() }
        .task { ResourceNetworkMonitor.shared.start() }
        .onChange(of: store.viewerOpenRequestID) { _, _ in
            if store.previewID != nil { openWindow(id: "viewer") }
        }
        .sheet(isPresented: $store.showAbout) { AboutView() }
        .sheet(isPresented: $store.showShortcuts) { ShortcutsView() }
        .sheet(isPresented: $store.showAddLibrary) { AddLibrarySheet(store: store) }
        .onChange(of: store.showCloudConnection, initial: true) { _, requested in
            if requested {
                if let account = store.reconnectCloudAccount { cloudConnectionRequest = CloudConnectionRequest(mode: .reconnect(account)) }
                else { cloudConnectionRequest = CloudConnectionRequest(mode: .add) }
            } else { cloudConnectionRequest = nil }
        }
        .sheet(item: $cloudConnectionRequest, onDismiss: {
            store.showCloudConnection = false
            store.reconnectCloudAccount = nil
        }) { request in
            CloudConnectionSheet(accounts: store.cloudAccounts, reconnectAccount: request.reconnectAccount) { account, reference, name in
                if request.reconnectAccount != nil { store.updateCloudAccount(account) }
                else { store.addCloudLibrary(account: account, reference: reference, name: name) }
                cloudConnectionRequest = nil
                store.showCloudConnection = false
                store.reconnectCloudAccount = nil
            }
        }
        .alert("无法完成操作", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .confirmationDialog("移除“\(store.pendingRemoval?.name ?? "")”？", isPresented: Binding(get: { store.pendingRemoval != nil }, set: { if !$0 { store.pendingRemoval = nil } }), titleVisibility: .visible) {
            Button("移除资源库", role: .destructive) { if let library = store.pendingRemoval { store.removeLibrary(library) }; store.pendingRemoval = nil }
        } message: { Text("只从菲林盒移除资源库记录，原文件会保留。") }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && refreshOnActivation { store.refreshIfNeeded() }
            if phase == .background { store.flush() }
        }
        .preferredColorScheme(appearance == "dark" ? .dark : (appearance == "light" ? .light : nil))
    }

    private func header(width: CGFloat) -> some View {
        HStack(spacing: 12) {
            ChromeIconButton(title: "显示 / 隐藏资源库", symbol: "sidebar.left", active: !sidebarVisible, accessibilityState: sidebarVisible ? "已展开" : "已收起") { sidebarVisible.toggle() }
            Text(store.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            LibrarySearchField(store: store, isFocused: $searchFocused, width: min(220, max(130, width * 0.22)))
            Button { store.setSelectionMode(!store.isSelectionMode) } label: {
                Label(store.isSelectionMode ? "完成" : "多选", systemImage: store.isSelectionMode ? "checkmark" : "checkmark.circle")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 11).frame(height: 30)
                    .foregroundStyle(store.isSelectionMode ? palette.accentText : palette.text)
                    .background(store.isSelectionMode ? palette.selectedFill : palette.quietFill, in: Capsule())
            }.buttonStyle(.plain).modifier(QuietFocusTreatment())
                .accessibilityLabel(store.isSelectionMode ? "完成选择" : "进入多选模式")
            ChromeIconButton(title: "显示信息 (⌘I)", symbol: "sidebar.right", active: store.showInspector, accessibilityState: store.showInspector ? "已展开" : "已收起") { store.showInspector.toggle() }
        }.foregroundStyle(palette.text).padding(.horizontal, 20).padding(.top, 22).frame(height: 80)
            .background(palette.panel)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(AppStore.MediaFilter.allCases, id: \.self) { filter in
                    FilterChoiceButton(title: filter.rawValue, selected: store.filter == filter) { store.filter = filter }
                }
            }
            MediaFilterButton(store: store)
            Spacer(minLength: 4)
            if store.isSelectionMode {
                Button(allVisibleSelected ? "取消全选" : "全选") {
                    if allVisibleSelected { store.clearSelection() } else { store.selectAll() }
                }.font(.system(size: 12)).buttonStyle(.plain).modifier(QuietFocusTreatment())
                    .foregroundStyle(palette.secondary).disabled(store.visibleItems.isEmpty)
                Button { store.copySelectedFiles() } label: {
                    Label("复制", systemImage: "doc.on.doc").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 11).frame(height: 28)
                        .background(palette.selectedFill, in: Capsule())
                }.buttonStyle(.plain).modifier(QuietFocusTreatment()).foregroundStyle(palette.accentText)
                    .disabled(store.selectedIDs.isEmpty || store.isPerformingFileOperation)
                Menu {
                    if let first = store.selectedItems.first { MediaContextMenu(store: store, item: first) }
                } label: { Image(systemName: "ellipsis").font(.system(size: 15)).frame(width: 26, height: 28) }
                    .menuStyle(.borderlessButton).fixedSize().disabled(store.selectedIDs.isEmpty)
                    .help("所选项目操作").accessibilityLabel("所选项目操作")
            } else {
              Menu {
                Picker("排序依据", selection: $store.sort) {
                    ForEach(AppStore.SortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Picker("排序方向", selection: $store.descending) {
                    Label("升序", systemImage: "arrow.up").tag(false)
                    Label("降序", systemImage: "arrow.down").tag(true)
                }.pickerStyle(.inline)
                if store.sort == .name || store.sort == .size { Text("名称与大小在日期分组内排序") }
            } label: {
                Label(store.sort == .name || store.sort == .size ? "组内 · " + store.sort.rawValue : store.sort.rawValue, systemImage: store.descending ? "arrow.down" : "arrow.up")
                    .font(.system(size: 11)).foregroundStyle(palette.secondary)
              }.menuStyle(.borderlessButton).fixedSize().help("排序").tint(palette.secondary)
            }
            Rectangle().fill(palette.border).frame(width: 1, height: 16)
            HStack(spacing: 2) {
                ChromeIconButton(title: "时间线 (⌘3)", symbol: "rectangle.grid.1x2", active: store.layout == .grid) { store.layout = .grid }
                ChromeIconButton(title: "翻阅 (⌘4)", symbol: "rectangle.stack", active: store.layout == .browse) { store.layout = .browse }
            }
        }.padding(.horizontal, 20).frame(height: 48).background(palette.panel)
    }

    private var allVisibleSelected: Bool {
        !store.visibleItems.isEmpty && store.selectedIDs.count == store.visibleItems.count
    }

    private var canvas: some View {
        ZStack {
            palette.canvas
            if store.libraries.isEmpty {
                VStack(spacing: 20) {
                    FilmboxMark().frame(width: 44, height: 52).padding(.bottom, 4)
                    Text("添加资源库").font(.system(size: 20, weight: .semibold))
                    Button { store.showAddLibrary = true } label: { Label("添加资源库…", systemImage: "plus").font(.system(size: 13)).padding(.horizontal, 12) }
                        .buttonStyle(.bordered).controlSize(.large)
                    Text("或将文件夹拖到这里").font(.system(size: 12)).foregroundStyle(palette.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.visibleItems.isEmpty {
                let activity = store.canvasIndexActivity
                VStack(spacing: 14) {
                    Image(systemName: activity != nil ? "photo.stack" : "photo.on.rectangle").font(.system(size: 28, weight: .ultraLight))
                    Text(activity?.title ?? emptyTitle).font(.system(size: 14))
                    if let detail = activity?.detail {
                        Text(detail)
                            .font(.system(size: 12))
                    }
                    if !store.query.isEmpty || store.hasActiveFilters {
                        Button("清除筛选") { store.query = ""; store.clearFilters() }.buttonStyle(.borderless)
                    } else if store.scope == .folders && store.directorySelection.included.isEmpty { Text("选择要浏览的文件夹").font(.system(size: 12)) }
                }.foregroundStyle(palette.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.layout == .grid { MediaGrid(store: store) }
            else { BrowseView(store: store) }
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10).strokeBorder(LightTablePalette.blue, style: StrokeStyle(lineWidth: 2, dash: [7]))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            FolderImportDrop.receive(providers, store: store)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if store.isPerformingFileOperation {
                ProgressView().controlSize(.mini)
                Text("正在管理文件…")
            } else if store.isScanning {
                ProgressView().controlSize(.mini)
                Text("正在更新…")
                Button("停止刷新", systemImage: "xmark.circle.fill", action: store.cancelScan).labelStyle(.iconOnly).buttonStyle(.plain).help("停止刷新")
            } else {
                Text("\(store.visibleItems.count.formatted()) 个项目")
            }
            if CloudTasksButton.shouldShow(for: store) { CloudTasksButton(store: store) }
            if !store.selectedIDs.isEmpty { Text("已选择 \(store.selectedIDs.count.formatted()) 项").foregroundStyle(palette.text) }
            if !store.offlineLibraries.isEmpty && store.scanWarnings.isEmpty {
                let localCount = store.libraries.filter { $0.isLocal && store.offlineLibraries.contains($0.id) }.count
                let cloudCount = store.libraries.filter { !$0.isLocal && store.offlineLibraries.contains($0.id) }.count
                if localCount > 0 {
                    Image(systemName: "externaldrive.badge.exclamationmark").help("\(localCount) 个本地资源库未连接")
                }
                if cloudCount > 0 && !CloudTasksButton.shouldShow(for: store) {
                    Image(systemName: "icloud.slash").help("\(cloudCount) 个云端资源库连接不可用，请查看云盘任务")
                }
            }
            if !store.scanWarnings.isEmpty {
                Menu { ForEach(Array(store.scanWarnings.prefix(12).enumerated()), id: \.offset) { _, warning in Text(warning) } }
                    label: { Image(systemName: "exclamationmark.triangle") }
                    .menuStyle(.borderlessButton).fixedSize().help("部分项目无法读取")
            }
            Spacer(minLength: 4)
            TimelineZoomControl(store: store)
        }.font(.system(size: 11)).foregroundStyle(palette.secondary)
            .padding(.horizontal, 20).frame(height: 36).background(palette.panel)
    }

    private var emptyTitle: String {
        if !store.query.isEmpty { return "没有搜索结果" }
        if store.hasActiveFilters { return "没有符合条件的项目" }
        switch store.scope {
        case .hidden: return "没有隐藏的项目"
        case .album: return "影集中还没有项目"
        case .favorites: return "还没有收藏"
        default: return "没有项目"
        }
    }

}

private struct LibrarySearchField: View {
    @Bindable var store: AppStore
    @Binding var isFocused: Bool
    let width: CGFloat
    @State private var input = SearchInputCoordinator()
    @Environment(\.colorScheme) private var scheme
    private var palette: LightTablePalette { LightTablePalette(dark: scheme == .dark) }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12))
                .foregroundStyle(isFocused ? palette.accentText : palette.secondary)
            FilmboxSearchField(text: Binding(get: { input.text }, set: { value in edit(value) }), isFocused: $isFocused).frame(height: 18)
            if !input.text.isEmpty {
                Button {
                    let target = store
                    input.clear(currentQuery: target.query) { [weak target] query in target?.query = query }
                } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(palette.secondary).accessibilityLabel("清除搜索")
            }
        }.padding(.horizontal, 11).frame(width: width, height: 30)
            .background(isFocused ? palette.selectedFill : palette.quietFill, in: Capsule())
            .onChange(of: store.query, initial: true) { _, query in
                _ = input.externalQueryChanged(query)
            }
            .onDisappear { input.cancel() }
    }

    private func edit(_ value: String) {
        let target = store
        input.edit(value, currentQuery: target.query) { [weak target] query in target?.query = query }
    }
}

/// Keeps typing local to the search field. Query commits still use AppStore's
/// synchronous setter, and an external query always supersedes pending input.
@MainActor @Observable final class SearchInputCoordinator {
    typealias Commit = @MainActor @Sendable (String) -> Void
    private(set) var text = ""
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var submittedQuery: String?

    func edit(_ text: String, currentQuery: String, commit: @escaping Commit) {
        self.text = text
        cancelPending()
        guard text != currentQuery else { return }
        if text.isEmpty { submit(text, commit: commit); return }
        let token = generation
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(170)) } catch { return }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.pending = nil
            self.submit(text, commit: commit)
        }
    }

    func clear(currentQuery: String, commit: @escaping Commit) {
        text = ""
        cancelPending()
        if !currentQuery.isEmpty { submit("", commit: commit) }
    }

    /// The field must not overwrite newer keystrokes when observing its own
    /// previous commit. All other query changes cancel pending user input.
    func externalQueryChanged(_ query: String) -> Bool {
        if submittedQuery == query { submittedQuery = nil; return false }
        text = query
        submittedQuery = nil
        cancelPending()
        return true
    }

    func cancel() { cancelPending(); submittedQuery = nil }
    private func cancelPending() { generation &+= 1; pending?.cancel(); pending = nil }
    private func submit(_ query: String, commit: @escaping Commit) {
        submittedQuery = query
        commit(query)
    }
    isolated deinit { pending?.cancel() }
}

struct SidebarView: View {
    @Bindable var store: AppStore
    @State private var cloudTransfers = CloudTransferCenter.shared
    @State private var expandedLibraries: Set<UUID> = []
    @State private var expandedFolders: Set<String> = []
    @State private var dropAlbumID: UUID?
    @State private var isLibraryDropTarget = false

    @Environment(\.colorScheme) private var scheme
    private var palette: LightTablePalette { LightTablePalette(dark: scheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                FilmboxMark().frame(width: 27, height: 32)
                Text("filmbox").font(.custom("HelveticaNeue-Bold", size: 23)).tracking(-0.5)
            }.padding(.horizontal, 22).padding(.top, 44).padding(.bottom, 30)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                scopeRow("所有项目", symbol: "photo.on.rectangle", count: store.indexedItemCount - store.hiddenCount, scope: .all)
                scopeRow("收藏", symbol: "heart", count: store.favoriteCount, scope: .favorites)
                scopeRow("隐藏", symbol: "eye.slash", count: store.hiddenCount, scope: .hidden)
                HStack {
                    Text("影集").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Button { store.promptNewAlbum() } label: { Image(systemName: "plus").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).help("新建影集 (⌘N)").accessibilityLabel("新建影集")
                }.foregroundStyle(palette.secondary).padding(.horizontal, 10).padding(.top, 22).padding(.bottom, 6)
                ForEach(store.albums) { album in
                    AlbumDropTarget(store: store, albumID: album.id, isTargeted: Binding(
                        get: { dropAlbumID == album.id },
                        set: { targeted in
                            if targeted { dropAlbumID = album.id }
                            else if dropAlbumID == album.id { dropAlbumID = nil }
                        }
                    )) {
                        scopeRow(album.name, symbol: "rectangle.stack", count: store.albumCount(album), scope: .album(album.id))
                            .background(dropAlbumID == album.id ? LightTablePalette.blue.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .contextMenu {
                                Button("重命名影集…") { store.promptRenameAlbum(album) }
                                Divider()
                                Button("删除影集…", role: .destructive) { store.confirmDeleteAlbum(album) }
                            }
                            .font(.system(size: 12))
                            .tint(LightTablePalette.blue)
                            .environment(\.colorScheme, scheme)
                    }.frame(maxWidth: .infinity).frame(height: 36)
                }
                HStack {
                    Text("资源库").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Button { store.showAddLibrary = true } label: {
                        Image(systemName: "plus").frame(width: 24, height: 24)
                    }.buttonStyle(.plain).help("添加资源库").accessibilityLabel("添加资源库")
                }.foregroundStyle(palette.secondary).padding(.horizontal, 10).padding(.top, 26).padding(.bottom, 8)
                    .background(isLibraryDropTarget ? LightTablePalette.blue.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                    .onDrop(of: [.fileURL], isTargeted: $isLibraryDropTarget) { providers in
                        FolderImportDrop.receive(providers, store: store)
                    }
                ForEach(store.libraries) { library in libraryRows(library) }
                }.padding(.horizontal, 12).padding(.bottom, 16)
            }.scrollIndicators(.hidden)
            Spacer(minLength: 0)
            HStack {
                SettingsLink { Image(systemName: "gearshape").font(.system(size: 14)) }.buttonStyle(.plain).help("设置 (⌘,)")
                Spacer()
                Button("刷新", systemImage: "arrow.clockwise", action: store.refresh).labelStyle(.iconOnly).buttonStyle(.plain).disabled(store.isPerformingFileOperation).help("检查所有资源库的更改 (⌘R)")
            }.foregroundStyle(palette.secondary).padding(.horizontal, 22).frame(height: 48)
        }.font(.system(size: 12)).foregroundStyle(palette.text).background(palette.panel)
    }

    private func scopeRow(_ title: String, symbol: String, count: Int, scope: AppStore.Scope) -> some View {
        Button { store.selectScope(scope) } label: {
            HStack { Label(title, systemImage: symbol); Spacer(); Text(count.formatted()).font(.caption).foregroundStyle(.secondary) }
                .padding(.horizontal, 10).frame(height: 36).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(QuietFocusTreatment())
        .background(store.scope == scope ? palette.selectedFill : .clear, in: Capsule())
        .foregroundStyle(store.scope == scope ? palette.accentText : palette.secondary)
        .accessibilityAddTraits(store.scope == scope ? .isSelected : [])
    }

    @ViewBuilder private func libraryRows(_ library: MediaLibrary) -> some View {
        let rootPath = library.selectionPath
        let children = directChildren(rootPath)
        folderRow(name: library.name, path: rootPath, depth: 0, isExpanded: expandedLibraries.contains(library.id), hasChildren: !children.isEmpty, isOffline: store.offlineLibraries.contains(library.id), count: store.count(in: rootPath), isCloud: !library.isLocal, dragLibraryID: library.id, isLoading: store.isRefreshing(library) && store.count(in: rootPath) == 0 && !store.offlineLibraries.contains(library.id), helpText: library.cloud?.path) {
            if expandedLibraries.contains(library.id) { expandedLibraries.remove(library.id) } else { expandedLibraries.insert(library.id) }
        }
        .contextMenu {
            Button("设置名称…") { store.promptRenameLibrary(library) }
            Button("重新加载") { store.refreshLibrary(library.id) }
                .disabled(store.isRefreshing(library) || store.isPerformingFileOperation)
            Divider()
            if library.isLocal { Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([library.url]) } }
            Button(library.isLocal ? "重新连接文件夹…" : "重新登录云盘…") { store.reconnect(library) }
            Divider()
            Button("移除资源库…", role: .destructive) { store.pendingRemoval = library }
        }
        if let problem = store.resourceProblem(for: library) {
            HStack(spacing: 6) {
                Text(problem.title).font(.system(size: 10)).lineLimit(1).help(problem.detail)
                Spacer(minLength: 0)
                Button(problem.action) { store.recover(.init(problem: problem, libraryID: library.id)) }
                    .font(.system(size: 10)).buttonStyle(.plain)
            }.foregroundStyle(palette.secondary).padding(.leading, 43).padding(.trailing, 8).padding(.bottom, 5)
        } else if let progress = store.cloudIndexProgress[library.id], progress.phase == .indexing || progress.phase == .paused {
            HStack(spacing: 6) {
                if progress.phase == .indexing { ProgressView().controlSize(.mini) }
                Text(progress.phase == .indexing ? "正在检查更改…" : "索引已暂停").font(.system(size: 10))
                Spacer()
                if progress.phase == .paused { Button("继续") { store.retryCloudIndex(library.id) }.font(.system(size: 10)).buttonStyle(.plain) }
            }.foregroundStyle(palette.secondary).padding(.leading, 43).padding(.trailing, 8).padding(.bottom, 5)
        }
        if expandedLibraries.contains(library.id) {
            ForEach(flatten(rootPath, depth: 1), id: \.folder.id) { entry in
                folderRow(name: entry.folder.name, path: entry.folder.selectionPath, depth: entry.depth, isExpanded: expandedFolders.contains(entry.folder.selectionPath), hasChildren: !directChildren(entry.folder.selectionPath).isEmpty, isOffline: false, count: store.count(in: entry.folder.selectionPath), helpText: entry.folder.displayPath) {
                    if expandedFolders.contains(entry.folder.selectionPath) { expandedFolders.remove(entry.folder.selectionPath) } else { expandedFolders.insert(entry.folder.selectionPath) }
                }
            }
        }
    }

    private func folderRow(name: String, path: String, depth: Int, isExpanded: Bool, hasChildren: Bool, isOffline: Bool, count: Int, isCloud: Bool = false, dragLibraryID: UUID? = nil, isLoading: Bool = false, helpText: String? = nil, expand: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Button(action: expand) { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(isExpanded ? 90 : 0)).frame(width: 10, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.plain).modifier(QuietFocusTreatment()).opacity(hasChildren ? 1 : 0).disabled(!hasChildren).accessibilityLabel(isExpanded ? "折叠\(name)" : "展开\(name)")
            let label = folderLabel(name: name, path: path, count: count, isOffline: isOffline, isCloud: isCloud, isLoading: isLoading)
            let description = "\(name)，\(isLoading ? "正在读取资源库" : "\(count) 个项目")，\(store.folderState(path) == .all ? "已选" : (store.folderState(path) == .partial ? "部分已选" : "选择文件夹"))"
            if let id = dragLibraryID {
                label.frame(height: 32)
                    .overlay { LibraryNativeDragSource(id: id, name: name, onMove: { store.moveLibrary($0, to: id) }, onClick: { store.toggleFolder(path) }) }
                    .accessibilityElement(children: .ignore).accessibilityLabel(description)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAddTraits(store.folderState(path) == .all ? .isSelected : [])
                    .accessibilityAction { store.toggleFolder(path) }
                    .focusable().modifier(QuietFocusTreatment())
                    .onKeyPress(.space) { store.toggleFolder(path); return .handled }
                    .onKeyPress(.return) { store.toggleFolder(path); return .handled }
                    .help(helpText ?? path)
            } else {
                Button { store.toggleFolder(path) } label: { label }
                    .buttonStyle(.plain).modifier(QuietFocusTreatment()).help(helpText ?? path).accessibilityLabel(description)
            }
        }
        .padding(.leading, CGFloat(min(depth, 4)) * 10).padding(.horizontal, 4).frame(height: 32)
        .accessibilityElement(children: .contain)
    }
    private func folderLabel(name: String, path: String, count: Int, isOffline: Bool, isCloud: Bool, isLoading: Bool) -> some View {
        let state = store.folderState(path)
        return HStack(spacing: 8) {
                    Image(systemName: state == .all ? "checkmark.circle.fill" : (state == .partial ? "minus.circle.fill" : "circle"))
                        .foregroundStyle(state == .none ? Color.secondary.opacity(0.5) : .accentColor).font(.system(size: 13))
                    Image(systemName: isOffline ? (isCloud ? "icloud.slash" : "externaldrive.badge.exclamationmark") : (isCloud ? "cloud" : "folder")).foregroundStyle(isOffline ? Color.orange : Color.secondary)
                    Text(name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if isLoading { ProgressView().controlSize(.mini).accessibilityLabel("正在读取资源库") }
                    else { Text(count.formatted()).font(.system(size: 10)).foregroundStyle(palette.secondary) }
                }.contentShape(Rectangle())

    }
    private func directChildren(_ path: String) -> [MediaFolder] {
        store.childFolders[path] ?? []
    }
    private struct FolderEntry { let folder: MediaFolder; let depth: Int }
    private func flatten(_ parent: String, depth: Int) -> [FolderEntry] {
        guard depth < 30 else { return [] }
        return directChildren(parent).flatMap { folder in
            [FolderEntry(folder: folder, depth: depth)] + (expandedFolders.contains(folder.selectionPath) ? flatten(folder.selectionPath, depth: depth + 1) : [])
        }
    }
}

/// Folder import targets are siblings of album targets, never their ancestors.
@MainActor private enum FolderImportDrop {
    static func receive(_ providers: [NSItemProvider], store: AppStore) -> Bool {
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !matching.isEmpty else { return false }
        let collector = FolderImportDropCollector(store: store, count: matching.count)
        for provider in matching {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in collector.receive(url) }
            }
        }
        return true
    }
}

@MainActor private final class FolderImportDropCollector {
    private weak var store: AppStore?
    private var remaining: Int
    private var folders: [URL] = []
    private var paths: Set<String> = []

    init(store: AppStore, count: Int) {
        self.store = store
        remaining = count
    }

    func receive(_ url: URL?) {
        if let url, url.isFileURL {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                if paths.insert(path).inserted { folders.append(url) }
            }
        }
        remaining -= 1
        // Dropping media onto the canvas is not an attempted folder import.
        guard remaining == 0, !folders.isEmpty, let store else { return }
        store.addFolders(folders)
    }
}

private struct AlbumDropTarget<Content: View>: NSViewRepresentable {
    let store: AppStore
    let albumID: UUID
    @Binding var isTargeted: Bool
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> AlbumDropView<Content> {
        let view = AlbumDropView(rootView: content)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: AlbumDropView<Content>, context: Context) {
        view.hostingView.rootView = content
        view.store = store
        view.albumID = albumID
        view.targetChanged = { isTargeted = $0 }
    }

    static func dismantleNSView(_ view: AlbumDropView<Content>, coordinator: ()) {
        view.unregisterDraggedTypes()
        view.targetChanged = nil
        view.store = nil
    }
}

/// The row remains clickable through the hosted button. Its native ancestor
/// receives the NSURL drag directly instead of crossing the item-provider bridge.
@MainActor private final class AlbumDropView<Content: View>: NSView {
    let hostingView: NSHostingView<Content>
    weak var store: AppStore?
    var albumID: UUID?
    var targetChanged: ((Bool) -> Void)?
    private var targeted = false
    private var acceptedIDs: Set<String> = []
    override var isFlipped: Bool { true }

    init(rootView: Content) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptedIDs = matchingIDs(in: sender.draggingPasteboard)
        let operation = acceptedOperation(sender)
        setTargeted(operation == .copy)
        AlbumDropDiagnostics.note("entered urls=\(fileURLs(in: sender.draggingPasteboard).count) matched=\(acceptedIDs.count) source=\(sender.draggingSourceOperationMask.rawValue) operation=\(operation.rawValue)")
        return operation
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = acceptedOperation(sender)
        setTargeted(operation == .copy)
        return operation
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        acceptedIDs.removeAll()
        setTargeted(false)
        AlbumDropDiagnostics.note("exited")
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        acceptedIDs = matchingIDs(in: sender.draggingPasteboard)
        let accepted = acceptedOperation(sender) == .copy
        AlbumDropDiagnostics.note("prepare matched=\(acceptedIDs.count) accepted=\(accepted)")
        return accepted
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let ids = matchingIDs(in: sender.draggingPasteboard)
        defer { acceptedIDs.removeAll(); setTargeted(false) }
        guard sender.draggingSourceOperationMask.contains(.copy), !ids.isEmpty,
              let store, let albumID, store.albums.contains(where: { $0.id == albumID }) else {
            AlbumDropDiagnostics.note("perform rejected matched=\(ids.count)")
            return false
        }
        let previous = store.albums.first(where: { $0.id == albumID })?.itemIDs.count ?? 0
        store.addToAlbum(ids, albumID: albumID)
        let current = store.albums.first(where: { $0.id == albumID })?.itemIDs.count ?? 0
        AlbumDropDiagnostics.note("perform matched=\(ids.count) before=\(previous) after=\(current) accepted=true")
        return true
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        acceptedIDs.removeAll()
        setTargeted(false)
        AlbumDropDiagnostics.note("ended")
    }

    private func acceptedOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSourceOperationMask.contains(.copy), !acceptedIDs.isEmpty,
              let store, let albumID, store.albums.contains(where: { $0.id == albumID }) else { return [] }
        return .copy
    }

    private func setTargeted(_ value: Bool) {
        guard targeted != value else { return }
        targeted = value
        targetChanged?(value)
    }

    private func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? [])
            .compactMap { ($0 as? NSURL).map { $0 as URL } }
    }

    private func matchingIDs(in pasteboard: NSPasteboard) -> Set<String> {
        guard let store else { return [] }
        let idsByPath = Dictionary(store.items.map { ($0.url.standardizedFileURL.path, $0.id) }, uniquingKeysWith: { first, _ in first })
        return Set(fileURLs(in: pasteboard).compactMap { url in
            idsByPath[url.standardizedFileURL.path] ?? idsByPath[url.resolvingSymlinksInPath().standardizedFileURL.path]
        })
    }
}

private enum AlbumDropDiagnostics {
    @MainActor static func note(_ message: String) {
        #if DEBUG
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/DragDiagnostics", isDirectory: true)
        let file = directory.appendingPathComponent("album-events.log")
        guard let data = "\(Date().timeIntervalSince1970) \(message)\n".data(using: .utf8) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            if (try handle.seekToEnd()) > 256 * 1024 {
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
            }
            try handle.write(contentsOf: data)
        } catch { }
        #endif
    }
}

private struct LibraryNativeDragSource: NSViewRepresentable {
    let id: UUID
    let name: String
    let onMove: (UUID) -> Void
    let onClick: () -> Void
    func makeNSView(context: Context) -> LibraryDragView { LibraryDragView() }
    func updateNSView(_ view: LibraryDragView, context: Context) {
        view.libraryID = id; view.title = name; view.onMove = onMove; view.onClick = onClick
    }
}

@MainActor private final class LibraryDragView: NSView {
    private final class WeakView { weak var value: LibraryDragView?; init(_ value: LibraryDragView) { self.value = value } }
    private static var rows: [WeakView] = []
    var libraryID = UUID()
    var title = ""
    var onMove: ((UUID) -> Void)?
    var onClick: (() -> Void)?
    private var press: NSEvent?
    private var dragging = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Self.rows.removeAll { $0.value == nil || $0.value === self }
        if window != nil { Self.rows.append(WeakView(self)) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let type = NSApp.currentEvent?.type, [.rightMouseDown, .rightMouseUp, .rightMouseDragged].contains(type) { return nil }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) { press = event; dragging = false }
    override func mouseDragged(with event: NSEvent) {
        guard let press, hypot(event.locationInWindow.x - press.locationInWindow.x, event.locationInWindow.y - press.locationInWindow.y) >= 4 else { return }
        dragging = true; alphaValue = 0.65; NSCursor.closedHand.set()
        autoscroll(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        defer { press = nil; dragging = false; alphaValue = 1; NSCursor.arrow.set() }
        guard press != nil else { return }
        if dragging {
            let target = Self.rows.compactMap(\.value).first {
                $0.window === window && $0 !== self && !$0.isHiddenOrHasHiddenAncestor
                    && $0.bounds.contains($0.convert(event.locationInWindow, from: nil))
            }
            target?.onMove?(libraryID)
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}
