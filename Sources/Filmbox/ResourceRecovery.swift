import AppKit
import SwiftUI
import FilmboxCore
import Network


struct ResourceRecoveryRequest {
    let problem: ResourceProblem
    var itemID: String? = nil
    var libraryID: UUID? = nil
}

struct ResourceRecoveryView: View {
    let problem: ResourceProblem
    var item: MediaItem? = nil
    var libraryID: UUID? = nil
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(problem.title).font(.system(size: 12, weight: .medium))
            Text(problem.detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(problem.action) {
                if problem == .storage { openSettings() }
                else { NotificationCenter.default.post(name: .filmboxRecoveryRequested, object: ResourceRecoveryRequest(problem: problem, itemID: item?.id, libraryID: libraryID)) }
            }.buttonStyle(.borderless)
        }.frame(maxWidth: 320, alignment: .leading).padding(14)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
    }
}

extension Notification.Name { static let filmboxRecoveryRequested = Notification.Name("FilmboxRecoveryRequested") }
extension Notification.Name { static let filmboxNetworkRestored = Notification.Name("FilmboxNetworkRestored") }

@MainActor final class ResourceNetworkMonitor {
    static let shared = ResourceNetworkMonitor()
    private var monitor: NWPathMonitor?
    func start() {
        guard monitor == nil else { return }
        let value = NWPathMonitor()
        let state = ResourcePathState()
        value.pathUpdateHandler = { path in
            if state.restored(path.status == .satisfied) {
                Task { @MainActor in NotificationCenter.default.post(name: .filmboxNetworkRestored, object: nil) }
            }
        }
        monitor = value
        value.start(queue: DispatchQueue(label: "filmbox.network.recovery"))
    }
}

@MainActor extension AppStore {
    func resumeRecoverableResources() {
        for library in libraries where !library.isLocal {
            guard let problem = resourceProblem(for: library), problem.canAutomaticallyRetry else { continue }
            retryCloudIndex(library.id)
        }
        NotificationCenter.default.post(name: Notification.Name("FilmboxPreviewRetry"), object: nil)
    }
    func resourceProblem(for library: MediaLibrary) -> ResourceProblem? {
        if library.isLocal { return offlineLibraries.contains(library.id) ? .offline : nil }
        if let account = library.cloud?.accountID {
            if CloudTransferCenter.shared.issue(for: account) != nil { return .login }
            if let value = CloudTransferCenter.shared.connectionProblems[account] { return value }
        }
        guard let progress = cloudIndexProgress[library.id], progress.phase == .failed else { return nil }
        return ResourceProblem(code: progress.errorCode)
    }
    func recover(_ request: ResourceRecoveryRequest) {
        let item = request.itemID.flatMap { id in items.first { $0.id == id } }
        let library = libraries.first { library in
            if let id = request.libraryID { return library.id == id }
            return item.map { $0.belongs(to: library) } ?? false
        }
        let accountID = item?.cloud?.accountID ?? library?.cloud?.accountID
        let account = cloudAccounts.first { $0.id == accountID }
        switch request.problem {
        case .login:
            if let account { reconnectAccount(account) }
            else { beginCloudConnection() }
        case .offline, .permission:
            if let library { reconnect(library) }
        case .network, .timeout:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") { NSWorkspace.shared.open(url) }
        case .service, .limited, .denied, .secure:
            let url = account.map { account in
                switch account.provider {
                case .quark: URL(string: "https://pan.quark.cn")!
                case .baidu: URL(string: "https://pan.baidu.com")!
                case .webdav: account.endpoint ?? URL(string: "https://openlist.team")!
                }
            }
            if let url { NSWorkspace.shared.open(url) }
        case .missing, .incomplete:
            if let library { refreshLibrary(library.id) }
        case .unsupported:
            if let item { openExternally(item) }
        case .engine, .unknown, .storage:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("Filmbox \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")\ncode=\(request.problem.rawValue)\nsource=\(library?.isLocal == true ? "local" : account?.provider.rawValue ?? "unknown")", forType: .string)
            notify("诊断信息已复制")
        }
    }
}

private final class ResourcePathState: @unchecked Sendable {
    private let lock = NSLock()
    private var unavailable = false
    func restored(_ available: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !available { unavailable = true; return false }
        let value = unavailable; unavailable = false; return value
    }
}
