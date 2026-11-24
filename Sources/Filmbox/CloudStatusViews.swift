import SwiftUI
import FilmboxCore

/// A single quiet status mark. Source, transfer and failure never stack over
/// each other, and completed local previews do not acquire an extra badge.
struct CloudAssetBadge: View {
    let item: MediaItem
    var loading = false
    var failed = false
    @State private var transfers = CloudTransferCenter.shared

    private var original: CloudTransferSnapshot? { item.isLocal ? nil : transfers.snapshot(for: item.id, purpose: .original) }
    private var thumbnail: CloudTransferSnapshot? { item.isLocal ? nil : transfers.snapshot(for: item.id, purpose: .thumbnail) }
    private var needsLogin: Bool {
        guard let accountID = item.cloud?.accountID else { return false }
        return transfers.issue(for: accountID)?.kind == .authenticationRequired
    }
    private var hasNoPreview: Bool {
        thumbnail?.state == .noPreview && original?.isOriginalCached != true && original?.state != .ready
    }
    private var hasFailure: Bool { !needsLogin && (failedTask != nil || (failed && !hasNoPreview)) }
    private var waitingTask: CloudTransferSnapshot? {
        if original?.state == .queued || original?.state == .paused { return original }
        if thumbnail?.state == .queued || thumbnail?.state == .paused { return thumbnail }
        return nil
    }
    private var failedTask: CloudTransferSnapshot? {
        if original?.state == .failed { return original }
        if thumbnail?.state == .failed { return thumbnail }
        return nil
    }
    private var downloading: CloudTransferSnapshot? {
        if original?.state == .downloading { return original }
        if thumbnail?.state == .downloading { return thumbnail }
        return nil
    }
    private var title: String {
        if needsLogin {
            return MediaFailureText.login
        }
        if let task = failedTask { return task.errorMessage ?? MediaFailureText.failed }
        if downloading != nil { return MediaLoadingText.downloading }
        if let task = waitingTask { return task.state == .paused ? MediaLoadingText.paused : MediaLoadingText.waiting }
        if hasNoPreview { return MediaFailureText.noPreview }
        if loading { return MediaLoadingText.loading }
        if original?.isOriginalCached == true || original?.state == .ready { return "云端原文件已缓存在本机" }
        if thumbnail?.state == .ready { return "云端文件，缩略图已缓存" }
        return "云端文件"
    }

    var body: some View {
        if item.cloud != nil && !item.url.isFileURL {
            Group {
                if hasFailure {
                    Button {
                        if let task = failedTask { NotificationCenter.default.post(name: .filmboxRecoveryRequested, object: ResourceRecoveryRequest(problem: ResourceProblem(code: task.errorCode), itemID: task.itemID)) }
                    } label: { visual }.buttonStyle(.plain)
                } else { visual.allowsHitTesting(false) }
            }.help(title).accessibilityLabel(title)
                .task(id: item.id + (item.cloud?.revision ?? "")) {
                    if !item.isLocal { await MediaAssetResolver.shared.inspectCache(for: item) }
                }
        }
    }

    private var visual: some View {
        Group {
            if needsLogin {
                Image(systemName: "icloud.slash").foregroundStyle(.secondary)
            } else if hasFailure {
                Image(systemName: "exclamationmark.icloud").foregroundStyle(.secondary)
            } else if let task = downloading {
                if let progress = task.progress {
                    Circle().trim(from: 0, to: max(0.03, min(1, progress)))
                        .stroke(.primary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(5)
                } else { ProgressView().controlSize(.mini).scaleEffect(0.7) }
            } else if let task = waitingTask {
                Image(systemName: task.state == .paused ? "pause" : "clock")
            } else { Image(systemName: original?.isOriginalCached == true || original?.state == .ready ? "checkmark.icloud" : "cloud") }
        }.font(.system(size: 11, weight: .medium)).frame(width: 23, height: 23)
            .background(.regularMaterial, in: Circle())
    }

}

struct CloudConnectionBanner: View {
    @Bindable var store: AppStore
    @State private var transfers = CloudTransferCenter.shared
    private var affected: [MediaLibrary] { store.libraries.filter { !$0.isLocal && store.resourceProblem(for: $0) != nil } }
    var body: some View {
        if let library = affected.first, let problem = store.resourceProblem(for: library) {
            HStack(spacing: 10) {
                Image(systemName: "cloud").foregroundStyle(.secondary)
                Text("\(library.name) · \(problem.title)").lineLimit(1)
                Spacer()
                Button(problem.action) { store.recover(.init(problem: problem, libraryID: library.id)) }.buttonStyle(.plain)
                    .foregroundStyle(LightTablePalette.blue)
            }.font(.system(size: 12)).padding(.horizontal, 20).frame(height: 36)
                .help(problem.detail).background(Color.secondary.opacity(0.04))
            Divider()
        }
    }
}

struct CloudTasksButton: View {
    @Bindable var store: AppStore
    @State private var transfers = CloudTransferCenter.shared
    @State private var showingTasks = false
    @State private var preloader = CloudThumbnailPreloader.shared
    @AppStorage("cloudThumbnailMode") private var mode = "nearby"

    static func shouldShow(for store: AppStore) -> Bool {
        let transfers = CloudTransferCenter.shared
        let preloader = CloudThumbnailPreloader.shared
        if store.cloudAccounts.contains(where: { transfers.issue(for: $0.id) != nil || transfers.connectionProblems[$0.id] != nil }) || transfers.failedCount > 0 { return true }
        if store.cloudIndexProgress.values.contains(where: { $0.phase == .failed }) { return true }
        // Completed history and missing-cover records are not active tasks.
        return transfers.activeCount > 0 || transfers.queuedCount > 0 || transfers.activeStreamCount > 0
            || (preloader.isRunning && preloader.completed < preloader.total)
    }
    private var hasBackgroundWork: Bool { mode == "all" && preloader.completed < preloader.total && (preloader.isRunning || preloader.isCapacityPaused) }
    private var backgroundActive: Bool {
        hasBackgroundWork && preloader.isRunning && !transfers.isBackgroundPaused
            && store.libraries.contains { !$0.isLocal && !needsLogin($0.cloud?.accountID) }
    }
    private var indexLibraries: [MediaLibrary] { store.libraries.filter { !$0.isLocal && !needsLogin($0.cloud?.accountID) } }
    private var indexingCount: Int { indexLibraries.filter { store.cloudIndexProgress[$0.id]?.phase == .indexing }.count }
    private var failedCount: Int {
        transfers.failedCount + indexLibraries.filter { store.cloudIndexProgress[$0.id]?.phase == .failed }.count
            + store.cloudAccounts.filter { needsLogin($0.id) }.count
    }
    // Streams include native video playback; the helper may describe the same
    // download already counted by the resolver, so these counts must not be added.
    private var count: Int { max(transfers.activeCount, transfers.activeStreamCount) }

    var body: some View {
        Button { showingTasks.toggle() } label: {
            HStack(spacing: 5) {
                if count > 0 || indexingCount > 0 || backgroundActive { ProgressView().controlSize(.mini) }
                else {
                    Image(systemName: failedCount > 0 ? "exclamationmark.icloud" : ((transfers.isBackgroundPaused || preloader.isCapacityPaused) && (transfers.queuedCount > 0 || hasBackgroundWork) ? "pause.circle" : "arrow.down.circle"))
                        .foregroundStyle(Color.secondary)
                }
                if count > 0 { Text("\(count)").monospacedDigit() }
            }.padding(.horizontal, 7).frame(height: 26).contentShape(Capsule())
        }.buttonStyle(.plain).help(count > 0 ? "\(MediaLoadingText.downloading) \(count) 项" : "云盘任务")
            .accessibilityLabel(count > 0 ? "云盘任务，\(MediaLoadingText.downloading) \(count) 项" : (backgroundActive ? "云盘任务，后台加载中" : "云盘任务"))
            .popover(isPresented: $showingTasks, arrowEdge: .top) {
                CloudTasksPopover(store: store) { account in
                    showingTasks = false
                    store.reconnectAccount(account)
                }
            }
    }
    private func needsLogin(_ accountID: UUID?) -> Bool {
        guard let accountID else { return false }
        return transfers.issue(for: accountID)?.kind == .authenticationRequired
    }
}

private struct CloudTasksPopover: View {
    @Bindable var store: AppStore
    @State private var transfers = CloudTransferCenter.shared
    @AppStorage("cloudThumbnailMode") private var mode = "nearby"
    @State private var preloader = CloudThumbnailPreloader.shared
    @Environment(\.openSettings) private var openSettings
    let onReconnect: (CloudAccount) -> Void
    private var accountsNeedingLogin: [CloudAccount] {
        store.cloudAccounts.filter { needsLogin($0.id) }
    }
    private var canLoadBackground: Bool { store.libraries.contains { !$0.isLocal && !needsLogin($0.cloud?.accountID) } }
    private var hasBackgroundWork: Bool { canLoadBackground && mode == "all" && preloader.completed < preloader.total && (preloader.isRunning || preloader.isCapacityPaused) }
    private var indexLibraries: [MediaLibrary] {
        store.libraries.filter { library in
            guard !needsLogin(library.cloud?.accountID) else { return false }
            guard let state = store.cloudIndexProgress[library.id] else { return false }
            return state.phase != .ready
        }
    }
    private var tasks: [CloudTransferSnapshot] {
        transfers.tasks.filter { $0.state != .idle && $0.state != .ready && $0.state != .noPreview && !needsLogin(transfers.accountID(for: $0.itemID)) }
            .sorted { lhs, rhs in
                let order: [CloudTransferState: Int] = [.downloading: 0, .queued: 1, .paused: 2, .failed: 3]
                let left = order[lhs.state, default: 4], right = order[rhs.state, default: 4]
                if left != right { return left < right }
                return lhs.id < rhs.id
            }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("云盘任务").font(.headline)
                Spacer()
                if canLoadBackground && (mode == "all" || transfers.isBackgroundPaused) && !(mode == "all" && preloader.isCapacityPaused) {
                    Button(transfers.isBackgroundPaused || preloader.isCapacityPaused ? "继续后台加载" : "暂停后台加载") {
                        if transfers.isBackgroundPaused || preloader.isCapacityPaused { resumeBackground() }
                        else { transfers.pauseBackground(true) }
                    }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }.padding(16)
            if !accountsNeedingLogin.isEmpty {
                VStack(spacing: 12) {
                    ForEach(accountsNeedingLogin) { account in
                        HStack(spacing: 9) {
                            Image(systemName: "icloud.slash").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(cloudAccountLabel(account)).font(.callout).lineLimit(1)
                                Text("需要重新登录").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("重新登录") { onReconnect(account) }.buttonStyle(.plain).font(.caption)
                        }
                    }
                }.padding(.horizontal, 16).padding(.bottom, 14)
            }
            if mode == "all", preloader.total > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(!canLoadBackground && !accountsNeedingLogin.isEmpty ? "后台加载等待登录" : (preloader.isCapacityPaused ? "缓存空间不足，预载已暂停" : (transfers.isBackgroundPaused ? "后台缩略图已暂停" : "后台缩略图")))
                        Spacer()
                        Text("已检查 \(preloader.completed.formatted()) / \(preloader.total.formatted())").monospacedDigit()
                    }.font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: Double(preloader.completed), total: Double(max(1, preloader.total))).controlSize(.small)
                    if canLoadBackground && preloader.isCapacityPaused {
                        HStack(spacing: 14) {
                            Button("继续", action: resumeBackground)
                            Button("缓存设置") {
                                UserDefaults.standard.set("cache", forKey: "settingsSelectedTab")
                                openSettings()
                            }
                        }.font(.caption).buttonStyle(.plain)
                    }
                }.padding(.horizontal, 16).padding(.bottom, 14)
            }
            Divider()
            if indexLibraries.isEmpty && tasks.isEmpty {
                if !hasBackgroundWork && accountsNeedingLogin.isEmpty {
                    ContentUnavailableView("暂无进行中的任务", systemImage: "checkmark.circle")
                        .frame(height: 150)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 15) {
                        ForEach(indexLibraries) { library in
                            if let progress = store.cloudIndexProgress[library.id] {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 9) {
                                        if progress.phase == .indexing { ProgressView().controlSize(.small) }
                                        else { Image(systemName: progress.phase == .failed ? "exclamationmark.icloud" : "pause.circle").foregroundStyle(.secondary) }
                                        Text(library.name).font(.callout).lineLimit(1)
                                        Spacer()
                                        if progress.phase == .indexing {
                                            Button("暂停") { store.cancelCloudIndex(library.id) }.buttonStyle(.plain).font(.caption)
                                        } else {
                                            if progress.phase == .paused { Button("继续") { store.retryCloudIndex(library.id) }.buttonStyle(.plain).font(.caption) }
                                        }
                                    }
                                    Text("\(progress.photos.formatted()) 张照片 · \(progress.videos.formatted()) 个视频 · \(progress.folders.formatted()) 个文件夹")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if progress.phase == .failed { ResourceRecoveryView(problem: store.resourceProblem(for: library) ?? .unknown, libraryID: library.id) }
                                }
                            }
                        }
                        ForEach(tasks) { task in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Image(systemName: task.purpose == .original ? "arrow.down.document" : "photo")
                                        .foregroundStyle(.secondary)
                                    Text(task.name).font(.callout).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    if task.state == .failed {
                                        Button(ResourceProblem(code: task.errorCode).action) {
                                            store.recover(.init(problem: ResourceProblem(code: task.errorCode), itemID: task.itemID))
                                        }.buttonStyle(.plain).font(.caption)
                                    } else if task.state == .paused {
                                        Button("继续") { transfers.retry(itemID: task.itemID, purpose: task.purpose) }.buttonStyle(.plain).font(.caption)
                                    } else {
                                        Button { transfers.cancel(itemID: task.itemID, purpose: task.purpose) } label: {
                                            Image(systemName: "xmark").font(.caption2)
                                        }.buttonStyle(.plain).accessibilityLabel("取消\(task.name)")
                                    }
                                }
                                if task.state == .downloading {
                                    if let progress = task.progress { ProgressView(value: progress).controlSize(.small) }
                                    else { ProgressView().progressViewStyle(.linear).controlSize(.small) }
                                }
                                Text(taskDescription(task)).font(.caption).foregroundStyle(task.state == .failed ? Color.orange : Color.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }.padding(16)
                }.frame(maxHeight: 300)
            }
            Divider()
            HStack {
                Text("今日已接收 \(cloudByteCount(transfers.todayReceivedBytes))")
                Spacer()
                let count = max(transfers.activeCount, transfers.activeStreamCount)
                if count > 0 { Text("\(MediaLoadingText.downloading) \(count) 项").monospacedDigit() }
            }.font(.caption).foregroundStyle(.secondary).padding(16)
        }.frame(width: 410)
    }
    private func resumeBackground() {
        transfers.pauseBackground(false)
        if mode == "all" { preloader.update(items: store.items) }
    }
    private func needsLogin(_ accountID: UUID?) -> Bool {
        guard let accountID else { return false }
        return transfers.issue(for: accountID)?.kind == .authenticationRequired
    }
    private func taskDescription(_ task: CloudTransferSnapshot) -> String {
        if task.state == .failed { return task.errorMessage ?? MediaFailureText.failed }
        if task.state == .paused { return MediaLoadingText.paused }
        if task.state == .queued { return MediaLoadingText.waiting }
        let received = cloudByteCount(task.receivedBytes)
        if let total = task.totalBytes { return "\(received) / \(cloudByteCount(total))" }
        return received
    }
}

private func cloudAccountLabel(_ account: CloudAccount) -> String {
    account.name == account.provider.displayName ? account.name : "\(account.provider.displayName) · \(account.name)"
}

func cloudByteCount(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
}

struct CloudBackgroundLoadModifier: ViewModifier {
    @Bindable var store: AppStore
    func body(content: Content) -> some View {
        content
            .onChange(of: store.isScanning) { _, scanning in if !scanning { update() } }
            .onChange(of: store.cloudIndexProgress) { (previous: [UUID: CloudIndexProgress], current: [UUID: CloudIndexProgress]) in
                if current.contains(where: { entry in entry.value.phase == .ready && previous[entry.key]?.phase != .ready }) { update() }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FilmboxCloudThumbnailModeChanged"))) { _ in update() }
            .onChange(of: CloudTransferCenter.shared.accountIssues) { _, _ in update() }
            .task { CloudThumbnailPreloader.shared.update(items: store.items) }
    }
    private func update() { CloudThumbnailPreloader.shared.update(items: store.items) }
}
