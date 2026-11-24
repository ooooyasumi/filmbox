import AppKit
import Darwin
import FilmboxCore
import Foundation

@main @MainActor private struct CloudIndexCheckRunner {
    private static var passed = 0
    private static let date = Date(timeIntervalSince1970: 1_700_000_000)

    static func main() async {
        var checks: [(String, @MainActor () async throws -> Void)] = [
            ("首次完整发布和数量、重开即读旧库及自动校对节流", firstPublicationAndStartup),
            ("目录失败保留正式旧库、用户集合和可恢复检查点", failureAndResume),
            ("取消后不发布半成品且可从完整目录边界继续", cancellation),
            ("完整但未提交的staging可在启动时恢复", readyCheckpointRecovery),
            ("破损staging重新校对且不清空正式旧库", corruptCheckpointRecovery),
            ("不同资源库独立成功失败及原子发布", independentLibraries),
            ("移除资源库撤销进行中索引且清理检查点", removalDoesNotResurrectLibrary),
            ("多目录追加检查点及进程中断日志恢复", journalRecoveryAndScale),
            ("账号失效阻止索引并保留旧库及用户整理", accountIssuePreservesIndex)
        ]
        if ProcessInfo.processInfo.environment["FILMBOX_INDEX_SCALE"] == "1" {
            checks.append(("十万媒体与一千目录完整索引及后台恢复", massiveTree))
        }
        var failures = 0
        for (name, check) in checks {
            do { try await check(); print("✓ \(name)") }
            catch { failures += 1; print("✗ \(name)：\(error)") }
        }
        print("\(checks.count - failures)/\(checks.count) 云盘索引场景、\(passed) 项断言通过")
        if failures > 0 { exit(EXIT_FAILURE) }
    }

    private static func firstPublicationAndStartup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        await fixture.remote.configure(delay: .milliseconds(160), path: "/Trips")
        let store = fixture.makeStore()
        store.refreshCloudLibrary(fixture.library.id)
        try await wait { await fixture.remote.wasRequested("/Trips") }
        try expect(store.items.isEmpty && store.visibleItems.isEmpty, "首个目录的媒体提前进入了正式列表")
        let active = try require(store.cloudIndexProgress[fixture.library.id], "没有索引进度")
        try expect(active.phase == .indexing && active.photos == 1 && active.videos == 1 && active.folders == 2, "发现数量不正确")
        try await wait { !store.isScanning }
        try expect(store.items.count == 3 && store.visibleItems.count == 3, "整库完成后没有一次发布全部媒体")
        try expect(store.cloudIndexProgress[fixture.library.id]?.phase == .ready, "完成状态未与列表同时发布")
        try expect(store.cloudIndexProgress[fixture.library.id]?.photos == 2 && store.cloudIndexProgress[fixture.library.id]?.videos == 1, "最终数量不准确")
        try expect(store.items.allSatisfy { $0.cloud?.thumbnailURL == nil }, "临时签名封面 URL 被持久化为索引字段")
        let saved = try fixture.persistence.load()
        try expect(saved.cachedItems.count == 3, "完整发布没有写入正式目录")
        let beforeRevision = store.visibleRevision
        let beforeTimeline = store.timelineRevision
        await fixture.remote.clearRequests()
        let reopened = fixture.makeStore()
        try expect(reopened.items.count == 3 && reopened.cloudIndexProgress[fixture.library.id]?.phase == .ready, "重开未直接恢复已完成索引")
        reopened.refreshIfNeeded()
        try await wait { !reopened.isScanning }
        let startupRequests = await fixture.remote.requests()
        try expect(startupRequests.isEmpty, "刚完成的云盘在激活时又完整遍历")
        await fixture.remote.setPage(path: "/", entries: [entry(id: "photo-1", name: "Root.jpg", thumbnail: "https://example.invalid/cover?signature=rotated"),
                                                        entry(id: "video-1", name: "Clip.mp4"), entry(id: "trip", name: "Trips", directory: true)])
        store.refreshCloudLibrary(fixture.library.id)
        try await wait { !store.isScanning }
        try expect(store.visibleRevision == beforeRevision && store.timelineRevision == beforeTimeline, "无变化校对重建了媒体及日期布局")
        let requested = await fixture.remote.requests()
        try expect(requested.contains("/") && requested.contains("/Trips"), "显式校对没有完整复查目录")
        reopened.cancelScan(); store.cancelScan()
    }

    private static func failureAndResume() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let photo = fixture.item(id: "photo-1", path: "/Root.jpg", camera: "Original Camera")
        let stale = fixture.item(id: "removed", path: "/Removed.jpg")
        let album = MediaAlbum(name: "保留影集", itemIDs: [photo.id, stale.id])
        let hidden = "orphan-hidden-id"
        try fixture.persistence.save(CatalogState(libraries: [fixture.library], favorites: [photo.id], cachedItems: [photo, stale],
                                                 hiddenIDs: [hidden], albums: [album], cloudAccounts: [fixture.account]))
        await fixture.remote.configure(failed: true, delay: .milliseconds(140), path: "/Trips")
        let store = fixture.makeStore()
        store.refreshCloudLibrary(fixture.library.id)
        try await wait { await fixture.remote.wasRequested("/Trips") }
        try expect(Set(store.items.map(\.id)) == [photo.id, stale.id], "扫描期间替换了可用旧快照")
        let learned = MediaItem(url: photo.url, kind: photo.kind, fileSize: photo.fileSize, modifiedDate: photo.modifiedDate,
                                createdDate: photo.createdDate, capturedDate: date.addingTimeInterval(-86400), pixelWidth: 6000, pixelHeight: 4000,
                                camera: "Learned During Scan", cloud: photo.cloud, previewAspectRatio: 1.5)
        store.updateCachedMediaItems([photo.id: learned])
        try await wait { !store.isScanning }
        try expect(Set(store.items.map(\.id)) == [photo.id, stale.id], "失败目录导致正式旧索引或记录消失")
        try expect(store.cloudIndexProgress[fixture.library.id]?.phase == .failed && store.offlineLibraries.contains(fixture.library.id), "失败没有明确进度状态")
        try expect(store.favorites == [photo.id] && store.hiddenIDs == [hidden] && store.albums == [album], "失败清除了用户整理")
        let saved = await store.flushImmediately()
        try expect(saved, "旧库及已学元数据无法保存")
        let checkpoint = try require(fixture.indexStore.manifest(for: fixture.library), "失败未保存检查点")
        try expect(checkpoint.completed.count == 1 && checkpoint.pending.first?.path == "/Trips", "失败目录被错误标为完整")
        await fixture.remote.configure(failed: false, delay: .zero, path: "/Trips")
        await fixture.remote.clearRequests()
        let reopened = fixture.makeStore()
        try expect(reopened.visibleItems.count == 2 && reopened.cloudIndexProgress[fixture.library.id]?.phase == .failed, "重开没有保留旧库和失败进度")
        reopened.retryCloudIndex(fixture.library.id)
        try await wait { !reopened.isScanning }
        let resumedRequests = await fixture.remote.requests()
        try expect(resumedRequests == ["/Trips"], "重试没有从失败目录第一页恢复，或重复了已完成目录")
        try expect(reopened.items.count == 3 && !reopened.items.contains(where: { $0.id == stale.id }), "完整恢复后未正确替换目录")
        let recovered = try require(reopened.items.first { $0.id == photo.id }, "原有照片在恢复后消失")
        try expect(recovered.camera == "Learned During Scan" && recovered.pixelWidth == 6000 && recovered.capturedDate == learned.capturedDate, "刷新丢失未变化文件的元数据")
        try expect(reopened.favorites == [photo.id] && reopened.hiddenIDs == [hidden] && reopened.albums == [album], "恢复重建改写了用户整理")
        reopened.cancelScan(); store.cancelScan()
    }

    private static func cancellation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        await fixture.remote.configure(delay: .seconds(2), path: "/Trips")
        let store = fixture.makeStore()
        store.refreshCloudLibrary(fixture.library.id)
        try await wait { await fixture.remote.wasRequested("/Trips") }
        store.cancelCloudIndex(fixture.library.id)
        try expect(!store.isScanning && store.items.isEmpty && store.cloudIndexProgress[fixture.library.id]?.phase == .paused, "取消未立即暂停或发布了半成品")
        try await wait { fixture.indexStore.manifest(for: fixture.library)?.progress.phase == .paused }
        let formal = try fixture.persistence.load()
        try expect(formal.cachedItems.isEmpty, "取消后半成品进入正式目录")
        await fixture.remote.configure(delay: .zero, path: "/Trips")
        await fixture.remote.clearRequests()
        store.retryCloudIndex(fixture.library.id)
        try await wait { !store.isScanning }
        let requests = await fixture.remote.requests()
        try expect(requests == ["/Trips"] && store.items.count == 3, "取消恢复丢失完整目录检查点")
        store.cancelScan()
    }

    private static func readyCheckpointRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let scanner = CloudLibraryScanner(directory: fixture.directory, loader: fixture.loader)
        guard case .completed(let snapshot) = await scanner.scan(library: fixture.library, account: fixture.account, resume: false, progress: { _ in }) else {
            throw Failure("无法产生完整 staging 夹具")
        }
        try expect(snapshot.items.count == 3 && (try fixture.persistence.load()).cachedItems.isEmpty, "夹具提前写入正式目录")
        try expect(fixture.indexStore.manifest(for: fixture.library)?.published == false, "staging 错误标为正式持久化")
        let store = fixture.makeStore()
        try expect(store.items.isEmpty, "启动同步解码了尚未提交的完整媒体 staging")
        try await wait { !store.isScanning }
        try expect(store.visibleItems.count == 3, "完整但未提交的 staging 没有在后台恢复")
        try await wait { fixture.indexStore.manifest(for: fixture.library)?.published == true }
        try expect(try fixture.persistence.load().cachedItems.count == 3, "恢复快照没有先保存正式目录再提交 staging")
        store.cancelScan()
    }

    private static func corruptCheckpointRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = fixture.item(id: "old", path: "/Old.jpg")
        try fixture.persistence.save(CatalogState(libraries: [fixture.library], cachedItems: [old], cloudAccounts: [fixture.account]))
        await fixture.remote.configure(failed: true, path: "/Trips")
        let store = fixture.makeStore()
        store.refreshCloudLibrary(fixture.library.id)
        try await wait { !store.isScanning }
        let libraryFolder = fixture.indexStore.directory.appendingPathComponent(fixture.library.id.uuidString)
        let files = try FileManager.default.contentsOfDirectory(at: libraryFolder, includingPropertiesForKeys: nil)
        let directorySnapshot = try require(files.first { $0.pathExtension == "json" && $0.deletingPathExtension().lastPathComponent.count == 64 }, "没有目录检查点")
        try Data("broken staging".utf8).write(to: directorySnapshot)
        await fixture.remote.configure(failed: false, delay: .milliseconds(80), path: "/Trips")
        await fixture.remote.clearRequests()
        store.retryCloudIndex(fixture.library.id)
        try expect(store.items.map(\.id) == [old.id], "破损 staging 清除了旧库")
        try await wait { !store.isScanning }
        let requests = await fixture.remote.requests()
        try expect(requests.contains("/") && requests.contains("/Trips") && store.items.count == 3, "破损检查点没有安全重扫")
        let scanner = CloudLibraryScanner(directory: fixture.directory, loader: fixture.loader)
        guard case .completed = await scanner.scan(library: fixture.library, account: fixture.account, resume: false, progress: { _ in }) else {
            throw Failure("无法建立未发布的完整检查点")
        }
        let readyFiles = try FileManager.default.contentsOfDirectory(at: libraryFolder, includingPropertiesForKeys: nil)
        let brokenReady = try require(readyFiles.first { $0.pathExtension == "json" && $0.deletingPathExtension().lastPathComponent.count == 64 }, "缺少完整目录检查点")
        try Data("broken ready snapshot".utf8).write(to: brokenReady)
        let reopened = fixture.makeStore()
        try await wait { !reopened.isScanning }
        try expect(reopened.items.count == 3 && reopened.cloudIndexProgress[fixture.library.id]?.phase == .failed,
                   "完整快照破损仍被宣称可用或覆盖了正式旧记录")
        reopened.cancelScan()
        store.cancelScan()
    }

    private static func journalRecoveryAndScale() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let storage = fixture.indexStore
        let libraryFolder = storage.directory.appendingPathComponent(fixture.library.id.uuidString)
        let manifestURL = libraryFolder.appendingPathComponent("manifest.json")
        let journalURL = libraryFolder.appendingPathComponent("completed.ndjson")
        var manifest = try storage.begin(library: fixture.library, resume: false)
        let originalBase = try Data(contentsOf: manifestURL)
        let root = try require(manifest.pending.first, "根目录不存在")
        let children = (0..<300).map { CloudIndexDirectory(id: "folder-\($0)", path: "/Folder-\($0)") }
        try storage.saveDirectory(CloudIndexDirectorySnapshot(directory: root, items: [], folders: []), libraryID: fixture.library.id)
        manifest.completed.append(root)
        manifest.progress.folders = children.count + 1
        try storage.recordCompletion(directory: root, children: children, manifest: manifest)
        for child in children {
            try storage.saveDirectory(CloudIndexDirectorySnapshot(directory: child, items: [], folders: []), libraryID: fixture.library.id)
            manifest.completed.append(child)
            try storage.recordCompletion(directory: child, children: [], manifest: manifest)
        }
        try expect(try Data(contentsOf: manifestURL) == originalBase, "每个目录仍在重写完整 manifest")
        let journal = try Data(contentsOf: journalURL)
        try expect(journal.count < children.count * 800, "追加日志大小没有按目录数量线性增长")
        try expect(try Data(contentsOf: libraryFolder.appendingPathComponent("status.json")).count < 4096, "启动状态文件包含完整目录队列")
        let replayed = try require(storage.manifest(for: fixture.library), "无法重放完整目录日志")
        try expect(replayed.completed.count == children.count + 1 && replayed.pending.isEmpty, "日志重放丢失目录边界")
        var interrupted = journal
        interrupted.append(contentsOf: Data("{\"generation\":\"interrupted".utf8))
        try interrupted.write(to: journalURL)
        let resumed = try storage.begin(library: fixture.library, resume: true)
        try expect(resumed.completed.count == children.count + 1 && resumed.pending.isEmpty,
                   "进程中断的最后半行破坏了前面已完成目录")
        try expect(try Data(contentsOf: journalURL).isEmpty, "恢复后半行日志没有先安全合并清理")
        // Simulate a crash after base replacement but before clearing the old
        // journal: already checkpointed events must not duplicate directories.
        try journal.write(to: journalURL)
        let duplicateReplay = try require(storage.manifest(for: fixture.library), "旧日志重放失败")
        try expect(duplicateReplay.completed.count == resumed.completed.count && duplicateReplay.pending.isEmpty,
                   "manifest 替换后遗留日志重复发布目录")
    }

    private static func massiveTree() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let timestamp = date
        let loader: CloudDirectoryLoader = { _, folderID, path in
            let entries: [CloudDirectoryEntry]
            if path == "/" {
                entries = (0..<1000).map {
                    CloudDirectoryEntry(id: "folder-\($0)", name: "Folder-\($0)", isDirectory: true, size: 0,
                                        modified: timestamp, created: timestamp, width: nil, height: nil, duration: nil, thumbnail: nil)
                }
            } else {
                entries = (0..<100).map {
                    CloudDirectoryEntry(id: "\(folderID)-media-\($0)", name: "Image-\($0).jpg", isDirectory: false, size: 100,
                                        modified: timestamp, created: timestamp, width: nil, height: nil, duration: nil, thumbnail: nil)
                }
            }
            return CloudDirectoryPage(entries: entries, folderID: folderID, path: path, credential: nil)
        }
        let scanner = CloudLibraryScanner(directory: fixture.directory, loader: loader)
        let started = Date()
        guard case .completed(let snapshot) = await scanner.scan(library: fixture.library, account: fixture.account,
                                                                resume: false, progress: { _ in }) else {
            throw Failure("十万记录索引未完整结束")
        }
        let indexedSeconds = Date().timeIntervalSince(started)
        try expect(snapshot.items.count == 100_000 && snapshot.folders.count == 1001, "十万记录或目录数量不完整")
        try expect(snapshot.progress.photos == 100_000 && snapshot.progress.videos == 0, "大型索引发现数量错误")
        let formal = try fixture.persistence.load()
        try expect(formal.cachedItems.isEmpty, "大型 scanner 提前发布了 staging")
        let restoredScanner = CloudLibraryScanner(directory: fixture.directory, loader: loader)
        let restoring = Date()
        let restored = try await restoredScanner.restore(library: fixture.library)
        let restoreSeconds = Date().timeIntervalSince(restoring)
        try expect(restored?.snapshot?.items.count == 100_000, "大型 staging 重开恢复不完整")
        let libraryFolder = fixture.indexStore.directory.appendingPathComponent(fixture.library.id.uuidString)
        let statusSize = try Data(contentsOf: libraryFolder.appendingPathComponent("status.json")).count
        try expect(statusSize < 4096, "十万记录启动仍需要读取整个目录队列")
        print(String(format: "  十万记录 / 1001 目录：索引 %.2f 秒，后台恢复 %.2f 秒，启动状态 %d 字节", indexedSeconds, restoreSeconds, statusSize))
    }

    private static func independentLibraries() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = MediaLibrary(cloud: CloudLibraryReference(accountID: fixture.account.id, folderID: "first", path: "/First"), name: "第一库")
        let second = MediaLibrary(cloud: CloudLibraryReference(accountID: fixture.account.id, folderID: "second", path: "/Second"), name: "第二库")
        let original = fixture.item(id: "old-first", path: "/First/old.jpg")
        await fixture.remote.setPage(path: "/First", entries: [], failed: true)
        await fixture.remote.setPage(path: "/Second", entries: [entry(id: "new-second", name: "New.jpg")])
        try fixture.persistence.save(CatalogState(libraries: [first, second], cachedItems: [original], cloudAccounts: [fixture.account]))
        let store = fixture.makeStore()
        store.refresh()
        try await wait { !store.isScanning }
        try expect(store.items.count == 2 && store.items.contains(original), "失败库阻塞成功库或旧库被清空")
        try expect(store.cloudIndexProgress[first.id]?.phase == .failed && store.cloudIndexProgress[second.id]?.phase == .ready, "每库状态未独立维护")
        store.cancelScan()
    }

    private static func removalDoesNotResurrectLibrary() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        await fixture.remote.configure(delay: .seconds(2), path: "/Trips")
        let store = fixture.makeStore()
        store.refreshCloudLibrary(fixture.library.id)
        try await wait { await fixture.remote.wasRequested("/Trips") }
        store.removeLibrary(fixture.library)
        try await wait { !store.isScanning }
        try await wait { fixture.indexStore.manifest(for: fixture.library) == nil }
        try expect(store.libraries.isEmpty && store.items.isEmpty && store.cloudIndexProgress[fixture.library.id] == nil,
                   "移除后过期扫描重新发布了资源库")
        let saved = await store.flushImmediately()
        try expect(saved && (try fixture.persistence.load()).libraries.isEmpty && (try fixture.persistence.load()).cachedItems.isEmpty,
                   "移除后的正式目录被过期扫描复活")
        store.cancelScan()
    }

    private static func accountIssuePreservesIndex() async throws {
        let fixture = try Fixture()
        defer { fixture.remove(); CloudTransferCenter.shared.forgetConnection(accountID: fixture.account.id) }
        let original = fixture.item(id: "photo-1", path: "/Root.jpg", camera: "Keep Camera")
        let album = MediaAlbum(name: "保留影集", itemIDs: [original.id])
        try fixture.persistence.save(CatalogState(libraries: [fixture.library], favorites: [original.id], cachedItems: [original],
            hiddenIDs: [original.id], albums: [album], cloudAccounts: [fixture.account]))
        CloudTransferCenter.shared.requireLogin(accountID: fixture.account.id)
        let store = fixture.makeStore()
        store.refreshCloudLibrary(fixture.library.id)
        try await wait { !store.isScanning }
        let rejectedRequests = await fixture.remote.requests()
        try expect(rejectedRequests.isEmpty && store.cloudIndexProgress[fixture.library.id]?.phase == .failed,
                   "已知失效账号仍调用目录 loader")
        try expect(store.items == [original] && store.favorites == [original.id] && store.hiddenIDs == [original.id] && store.albums == [album],
                   "已知失效账号清空了正式索引或用户整理")
        CloudTransferCenter.shared.connectionRecovered(accountID: fixture.account.id)
        await fixture.remote.configure(delay: .seconds(2), path: "/Trips")
        store.refreshCloudLibrary(fixture.library.id)
        try await wait { await fixture.remote.wasRequested("/Trips") }
        CloudTransferCenter.shared.requireLogin(accountID: fixture.account.id)
        store.applyCloudConnectionIssues()
        try expect(!store.isScanning && store.cloudIndexProgress[fixture.library.id]?.phase == .failed,
                   "账号失效没有停止在途索引并标记失败")
        try expect(store.items == [original] && store.albums == [album], "在途索引失效发布了半成品或误删整理")
        await fixture.remote.clearRequests()
        store.retryCloudIndex(fixture.library.id)
        try await Task.sleep(for: .milliseconds(30))
        let retryRequests = await fixture.remote.requests()
        try expect(retryRequests.isEmpty, "失效账号的重试重复请求了 provider")
        CloudTransferCenter.shared.connectionRecovered(accountID: fixture.account.id)
        await fixture.remote.configure(delay: .zero, path: "/Trips")
        store.refreshCloudLibrary(fixture.library.id)
        try await wait { !store.isScanning }
        try expect(store.items.count == 3 && store.cloudIndexProgress[fixture.library.id]?.phase == .ready,
                   "明确恢复账号后无法完成完整索引")
        try expect(store.items.first(where: { $0.id == original.id })?.camera == original.camera
            && store.favorites == [original.id] && store.hiddenIDs == [original.id] && store.albums == [album],
                   "恢复账号后的索引丢失旧元数据或用户整理")
        store.cancelScan()
    }

    private static func entry(id: String, name: String, directory: Bool = false, thumbnail: String? = nil) -> CloudDirectoryEntry {
        CloudDirectoryEntry(id: id, name: name, isDirectory: directory, size: directory ? 0 : 100,
                            modified: date, created: date, width: nil, height: nil, duration: nil, thumbnail: thumbnail)
    }

    @MainActor private final class Fixture {
        let directory: URL
        let account = CloudAccount(provider: .quark, name: "合成账号")
        let library: MediaLibrary
        let remote: Remote
        var persistence: CatalogPersistence { CatalogPersistence(directory: directory) }
        var indexStore: CloudIndexStore { CloudIndexStore(catalogDirectory: directory) }
        var loader: CloudDirectoryLoader {
            let remote = remote
            return { _, folderID, path in try await remote.list(folderID: folderID, path: path) }
        }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("FilmboxCloudIndexChecks-\(UUID().uuidString)", isDirectory: true)
            library = MediaLibrary(cloud: CloudLibraryReference(accountID: account.id, folderID: "0", path: "/"), name: "合成资源库")
            remote = Remote(pages: ["/": [entry(id: "photo-1", name: "Root.jpg", thumbnail: "https://example.invalid/cover?signature=initial"), entry(id: "video-1", name: "Clip.mp4"), entry(id: "trip", name: "Trips", directory: true)],
                                   "/Trips": [entry(id: "photo-2", name: "Tall.jpg")]])
            try persistence.save(CatalogState(libraries: [library], cloudAccounts: [account]))
        }
        func makeStore() -> AppStore { AppStore(directory: directory, cloudDirectoryLoader: loader) }
        func item(id: String, path: String, camera: String? = nil) -> MediaItem {
            let reference = CloudMediaReference(accountID: account.id, fileID: id, parentID: "0", remotePath: path, revision: "100|\(date.timeIntervalSince1970)")
            return MediaItem(url: reference.locatorURL, kind: .image, fileSize: 100, modifiedDate: date,
                             createdDate: date, camera: camera, cloud: reference)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private actor Remote {
        var pages: [String: [CloudDirectoryEntry]]
        var failed = Set<String>()
        var delays: [String: Duration] = [:]
        var requested: [String] = []
        init(pages: [String: [CloudDirectoryEntry]]) { self.pages = pages }
        func configure(failed: Bool = false, delay: Duration = .zero, path: String) {
            if failed { self.failed.insert(path) } else { self.failed.remove(path) }
            delays[path] = delay
        }
        func setPage(path: String, entries: [CloudDirectoryEntry], failed: Bool = false) {
            pages[path] = entries
            if failed { self.failed.insert(path) } else { self.failed.remove(path) }
        }
        func list(folderID: String, path: String) async throws -> CloudDirectoryPage {
            requested.append(path)
            if let delay = delays[path], delay > .zero { try await Task.sleep(for: delay) }
            if failed.contains(path) { throw Failure("合成目录暂不可用") }
            guard let entries = pages[path] else { throw Failure("合成目录不存在") }
            return CloudDirectoryPage(entries: entries, folderID: folderID, path: path, credential: nil)
        }
        func wasRequested(_ path: String) -> Bool { requested.contains(path) }
        func requests() -> [String] { requested }
        func clearRequests() { requested = [] }
    }

    private static func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            if ContinuousClock.now >= deadline { throw Failure("等待索引状态超时") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(message) }
        passed += 1
    }
    private static func require<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw Failure(message) }; return value }
    private struct Failure: Error, CustomStringConvertible { let description: String; init(_ value: String) { description = value } }
}

// Transport-only doubles isolate directory timing/failures. The scanner,
// staging persistence and AppStore compiled above are the production sources.
struct CloudDirectoryEntry: Sendable {
    let id: String; let name: String; let isDirectory: Bool; let size: Int64
    let modified: Date; let created: Date?; let width: Int?; let height: Int?; let duration: Double?; let thumbnail: String?
}
struct CloudDirectoryPage: Sendable { let entries: [CloudDirectoryEntry]; let folderID: String; let path: String; let credential: String? }
enum CloudConnectionError: LocalizedError {
    case invalidCredential, service(String)
    var errorDescription: String? { switch self { case .invalidCredential: "合成账户不可用"; case .service(let text): text } }
}
actor CloudGateway {
    static let shared = CloudGateway()
    func register(accounts: [CloudAccount]) {}
    func list(account: CloudAccount, folderID: String, path: String) throws -> CloudDirectoryPage { throw CloudConnectionError.invalidCredential }
}
final class CloudMediaRegistry: @unchecked Sendable {
    static let shared = CloudMediaRegistry()
    func register(_ items: [MediaItem]) {}
}
// The real account state and resolver cancellation are covered by TransferChecks;
// this isolated source exercises AppStore's reaction without any network/vault.
struct CloudAccountIssue: Equatable, Sendable {
    enum Kind: Sendable { case authenticationRequired }
    let kind: Kind
    let message: String
}
@MainActor final class CloudTransferCenter {
    static let shared = CloudTransferCenter()
    private var accountIssues: [UUID: CloudAccountIssue] = [:]
    func issue(for accountID: UUID) -> CloudAccountIssue? { accountIssues[accountID] }
    func requireLogin(accountID: UUID) {
        accountIssues[accountID] = CloudAccountIssue(kind: .authenticationRequired, message: "此云盘需要重新登录。")
    }
    func connectionRecovered(accountID: UUID) { accountIssues[accountID] = nil }
    func forgetConnection(accountID: UUID) { accountIssues[accountID] = nil }
}
@MainActor extension AppStore {
    func materialize(_ targets: [MediaItem], completion: @escaping @MainActor ([URL]) -> Void) { preconditionFailure("索引检查不得下载媒体") }
    func copyFiles(_ targets: [MediaItem], pathsOnly: Bool = false, to pasteboard: NSPasteboard = .general) { preconditionFailure("索引检查不得访问剪贴板") }
}
