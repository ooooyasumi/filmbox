import AppKit
import SwiftUI
import FilmboxCore

private actor FailureSource {
    var reason: ResourceProblem? = .network
    var calls = 0
    func set(_ value: ResourceProblem?) { reason = value }
    func load() throws -> CloudDirectoryPage {
        calls += 1
        if let reason { throw CloudConnectionError.problem(reason) }
        return CloudDirectoryPage(entries: [], folderID: "/", path: "/", credential: nil)
    }
}
@main @MainActor struct RecoveryChecks {
    static var count = 0
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: message, code: 1) }; count += 1; print("✓ \(message)")
    }
    static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw NSError(domain: "recovery timeout", code: 1)
    }
    static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("filmbox-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FailureSource()
        let store = AppStore(directory: root, cloudDirectoryLoader: { _,_,_ in try await source.load() })
        let account = CloudAccount(id: UUID(), provider: .webdav, name: "测试云盘", endpoint: URL(string:"http://127.0.0.1:1"))
        let library = MediaLibrary(cloud: .init(accountID: account.id, folderID: "/", path: "/"), name: "测试资源库")
        store.cloudAccounts = [account]; store.libraries = [library]
        for reason in [ResourceProblem.network, .timeout, .service, .limited, .denied, .missing, .login] {
            await source.set(reason)
            store.refreshCloudLibrary(library.id, restart: true)
            try await wait { store.cloudIndexProgress[library.id]?.phase == .failed && !store.isScanning }
            try check(store.resourceProblem(for: library) == reason, "索引保留真实错误代码 \(reason.rawValue)")
            try check(store.scanWarnings.isEmpty, "已就近说明的问题不再重复成黄色警告")
        }
        await source.set(nil)
        store.retryCloudIndex(library.id)
        try await wait { store.cloudIndexProgress[library.id]?.phase == .ready && !store.isScanning }
        try check(store.resourceProblem(for: library) == nil && !store.offlineLibraries.contains(library.id), "连接恢复后清除错误与离线状态")
        for reason in [ResourceProblem.login, .denied, .missing, .limited] {
            try check(!reason.canAutomaticallyRetry, "终止无效自动重试 \(reason.rawValue)")
        }
        let center = CloudTransferCenter(defaults: UserDefaults(suiteName: "filmbox-recovery-\(UUID())")!)
        center.connectionFailed(accountID: account.id, problem: .network)
        try check(center.issue(for: account.id) == nil && center.connectionProblems[account.id] == .network, "网络中断不标记为登录失效")
        center.connectionResponded(accountID: account.id)
        try check(center.connectionProblems.isEmpty, "成功响应清除网络问题")
        let picture = MediaItem(cloud: .init(accountID: account.id, fileID: "one", parentID: "/", remotePath: "/one.jpg", revision: "v"), kind: .image, fileSize: 16, modifiedDate: .now, createdDate: .now)
        let token = UUID(); center.queued(item: picture, purpose: .original, priority: .foreground, token: token)
        center.failed(itemID: picture.id, purpose: .original, token: token, error: CloudConnectionError.problem(.denied))
        let snapshot = center.snapshot(for: picture.id)
        try check(snapshot?.errorCode == ResourceProblem.denied.rawValue, "下载失败保留原因")
        let feedback = PhotoPreviewFeedback.resolve(state: .failed, item: picture, isOffline: false, original: snapshot, needsLogin: false)
        try check(feedback?.problem == .denied && feedback?.title == ResourceProblem.denied.title, "查看器展示拒绝访问，不诱导重新登录")
        let view = NSHostingView(rootView: VStack(spacing: 16) {
            ForEach([ResourceProblem.network, .login, .denied, .missing], id: \.rawValue) { problem in ResourceRecoveryView(problem: problem) }
        }.padding(24).frame(width: 400).background(Color(NSColor.windowBackgroundColor)))
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 700); view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/recovery-qa/mac-recovery.png")
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output)
        }
        print("\(count) 项故障恢复检查通过；只使用临时索引与注入错误")
    }
}
