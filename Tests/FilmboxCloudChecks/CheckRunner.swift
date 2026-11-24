import AppKit
import Darwin
import FilmboxCore
import Foundation

/// Runs the actual native catalogue, scanner, transport and cache against the
/// loopback fixture started by check-cloud.sh. Every persistent record is temporary.
@main
@MainActor
private struct CloudCheckRunner {
    private static var passed = 0
    private static let password = "filmbox-test-password"

    static func main() async {
        guard CommandLine.arguments.count == 2, let endpoint = URL(string: CommandLine.arguments[1]) else {
            print("Usage: FilmboxCloudChecks <loopback WebDAV endpoint>")
            exit(EXIT_FAILURE)
        }
        let accountID = UUID()
        let rejectedAccountID = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FilmboxNativeCloudChecks-\(UUID().uuidString)", isDirectory: true)
        var store: AppStore?
        var failure: Error?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try checkLegacyAndStableModels()
            try await checkRejectedConnections(endpoint: endpoint, accountID: rejectedAccountID)
            let account = try await CloudGateway.shared.connect(provider: .webdav, credential: "", endpoint: endpoint.absoluteString,
                                                                username: "photos", password: password, accountID: accountID)
            try expect(account.id == accountID && account.endpoint == endpoint, "成功连接没有保留账号和公共服务器地址")
            let library = MediaLibrary(cloud: CloudLibraryReference(accountID: accountID, folderID: "/", path: "/"), name: "合成云盘")
            let scanned = try await checkMetadataScan(account: account, library: library)
            try await checkAuthenticatedRange(items: scanned.items)
            let resolver = MediaAssetResolver(directory: directory.appendingPathComponent("original-cache", isDirectory: true), recentProtectionDuration: 0)
            let cachedPhoto = try await checkOriginalCache(resolver: resolver, items: scanned.items, endpoint: endpoint)
            try await checkExportLease(items: scanned.items, directory: directory)
            try await checkThumbnailDiskCache(original: cachedPhoto, directory: directory)
            store = try await checkMixedCatalogue(account: account, library: library, scanned: scanned,
                                                  photoData: Data(contentsOf: cachedPhoto), endpoint: endpoint, directory: directory)
            if let store {
                try await checkOfflinePreservation(store: store, resolver: resolver, cachedPhoto: cachedPhoto,
                                                   items: scanned.items, account: account, endpoint: endpoint, directory: directory)
                store.cancelScan()
                let saved = await store.flushImmediately()
                try expect(saved, "最终测试目录保存失败")
            }
            try await checkReconnectAndForget(account: account, endpoint: endpoint)
            await resolver.clearCache()
            let remaining = await resolver.cacheSize()
            try expect(remaining == 0, "测试原文件缓存未完整清除")
        } catch {
            failure = error
        }
        store?.cancelScan()
        if let store { _ = await store.flushImmediately() }
        try? await CloudGateway.shared.forget(accountID: accountID)
        try? await CloudGateway.shared.forget(accountID: rejectedAccountID)
        await CloudGateway.shared.shutdown()
        try? FileManager.default.removeItem(at: directory)
        if let failure {
            print("✗ 云盘整合检查失败：\(failure)")
            print("此前 \(passed) 项断言通过；临时账号、目录和后台组件已清理")
            exit(EXIT_FAILURE)
        }
        print("\(passed) 项云盘原生整合断言通过；临时账号、目录和后台组件已清理")
    }

    private static func checkLegacyAndStableModels() throws {
        let legacy = try JSONDecoder().decode(CatalogState.self, from: Data("{\"libraries\":[],\"favorites\":[]}".utf8))
        try expect(legacy.cloudAccounts.isEmpty && legacy.cachedItems.isEmpty, "旧目录无法迁移")
        let account = UUID()
        let otherAccount = UUID()
        let original = CloudMediaReference(accountID: account, fileID: "1", parentID: "a", remotePath: "/Trips/a.jpg", revision: "1")
        let renamed = CloudMediaReference(accountID: account, fileID: "1", parentID: "b", remotePath: "/Albums/b.jpg", revision: "2")
        let independent = CloudMediaReference(accountID: otherAccount, fileID: "1", parentID: "a", remotePath: "/Trips/a.jpg", revision: "1")
        try expect(original.stableID == renamed.stableID, "移动或重命名改变云端文件身份")
        try expect(original.stableID != independent.stableID, "不同账号相同文件标识发生冲突")
        let rules = DirectorySelection(included: [CloudMediaPath.selectionPath(accountID: account, path: "/Trips")])
        try expect(rules.contains(original.selectionPath) && !rules.contains(independent.selectionPath), "目录规则穿透云端账号")
        try expect(!rules.contains(CloudMediaPath.selectionPath(accountID: account, path: "/Trips-old/a.jpg")), "目录规则穿透同名前缀目录")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let preview = MediaItem(cloud: original, kind: .image, fileSize: 100, modifiedDate: date, createdDate: date, previewAspectRatio: 1.5)
        let movedReference = CloudMediaReference(accountID: account, fileID: "1", parentID: "b", remotePath: "/Albums/renamed.jpg", revision: "1")
        let moved = MediaItem(cloud: movedReference, kind: .image, fileSize: 100, modifiedDate: date, createdDate: date).mergingMetadata(from: preview)
        try expect(moved.id == preview.id && moved.name == "renamed.jpg" && moved.displayPath == "/Albums/renamed.jpg", "合并旧元数据覆盖了新文件名或路径")
        try expect(moved.previewAspectRatio == 1.5 && moved.pixelWidth == nil && moved.pixelHeight == nil, "缩略图比例未保留或冒充了原图尺寸")
        let revised = MediaItem(cloud: renamed, kind: .image, fileSize: 100, modifiedDate: date, createdDate: date).mergingMetadata(from: preview)
        try expect(revised.previewAspectRatio == nil && revised.aspectRatio == nil, "新版本文件继承了旧预览比例")
        let originalMetadata = MediaItem(url: original.locatorURL, kind: .image, fileSize: 100, modifiedDate: date, createdDate: date,
                                         capturedDate: date.addingTimeInterval(-3600), pixelWidth: 6000, pixelHeight: 4000,
                                         camera: "Synthetic Camera", cloud: original)
        let mergedOriginal = MediaItem(cloud: movedReference, kind: .image, fileSize: 100, modifiedDate: date, createdDate: date).mergingMetadata(from: originalMetadata)
        try expect(mergedOriginal.pixelWidth == 6000 && mergedOriginal.camera == "Synthetic Camera" && mergedOriginal.capturedDate == originalMetadata.capturedDate,
                   "同一版本文件的真实原图元数据在刷新时丢失")
        print("✓ 旧记录兼容、云端稳定身份及目录边界")
    }

    private static func checkRejectedConnections(endpoint: URL, accountID: UUID) async throws {
        for invalid in ["http://example.com/dav", "https://photos:secret@example.com/dav", "https://example.com/dav?token=secret"] {
            do {
                _ = try await CloudGateway.shared.connect(provider: .webdav, credential: "", endpoint: invalid, accountID: accountID)
                throw CheckFailure(message: "服务器地址验证接受了不安全的输入")
            } catch is CloudConnectionError { passed += 1 }
        }
        do {
            _ = try await CloudGateway.shared.connect(provider: .webdav, credential: "", endpoint: endpoint.absoluteString,
                                                      username: "photos", password: "wrong-test-password", accountID: accountID)
            throw CheckFailure(message: "错误 WebDAV 密码被接受")
        } catch let error as CloudConnectionError {
            try expect(!error.localizedDescription.contains("wrong-test-password"), "错误信息泄露测试密码")
        }
        print("✓ 地址验证与真实 WebDAV 登录失败处理")
    }

    private static func checkMetadataScan(account: CloudAccount, library: MediaLibrary) async throws -> ScanResult {
        let scanner = CloudLibraryScanner()
        let result = await scanner.scan(libraries: [library], accounts: [account]) { _, _ in }
        try expect(result.unavailableLibraryIDs.isEmpty && result.warnings.isEmpty, "在线云盘被标记为离线：\(result.warnings)")
        try expect(result.items.count == 4, "递归云盘索引应有四个媒体，实际为 \(result.items.count)")
        try expect(result.folders.count == 3, "云盘根目录和两个子目录未被完整索引")
        try expect(result.items.filter { $0.kind == .video }.count == 1, "视频类型识别失败")
        try expect(result.items.allSatisfy { !$0.isLocal && !$0.url.isFileURL && $0.belongs(to: library) }, "云盘索引产生了本地文件路径")
        try expect(result.items.contains { $0.name == "Sunset #1.png" && $0.displayPath == "/Trips/Sunset #1.png" }, "带空格或井号的文件名解码错误")
        try expect(result.items.allSatisfy { $0.fileSize > 0 && $0.createdDate == $0.modifiedDate }, "服务器尺寸或日期元数据未正确解码")
        print("✓ 真实后台组件递归扫描、格式筛选、元数据及特殊文件名")
        return result
    }

    private static func checkAuthenticatedRange(items: [MediaItem]) async throws {
        let video = try require(items.first { $0.kind == .video }, "缺少视频夹具")
        let ref = try require(video.cloud, "视频缺少云端引用")
        let resolved = try await CloudGateway.shared.resolve(accountID: ref.accountID, fileID: ref.fileID, path: ref.remotePath)
        try expect(resolved.url.host == "127.0.0.1" && resolved.url.path == "/v1/asset", "媒体未经过本机认证代理")
        try expect(resolved.headers["Authorization"]?.hasPrefix("Bearer ") == true && !resolved.headers.values.contains(where: { $0.contains(password) }), "媒体返回了远端登录密码")
        let (_, unauthorized) = try await URLSession.shared.data(from: resolved.url)
        try expect((unauthorized as? HTTPURLResponse)?.statusCode == 401, "匿名请求能够读取本机媒体代理")
        var request = URLRequest(url: resolved.url)
        request.allHTTPHeaderFields = resolved.headers
        request.setValue("bytes=5-9", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        try expect((response as? HTTPURLResponse)?.statusCode == 206 && data == Data("56789".utf8), "跨进程 Range 代理未返回正确范围")
        try expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") == "bytes 5-9/36", "媒体范围响应头丢失")
        print("✓ 本机代理认证、实际远端密码传递及视频 Range 读取")
    }

    private static func checkOriginalCache(resolver: MediaAssetResolver, items: [MediaItem], endpoint: URL) async throws -> URL {
        let photo = try require(items.first { $0.name == "Sunset #1.png" }, "缺少云端照片")
        let before = try await control("stats", endpoint: endpoint)
        async let first = resolver.originalFile(for: photo)
        async let second = resolver.originalFile(for: photo)
        async let third = resolver.originalFile(for: photo)
        let urls = try await [first, second, third]
        let original = urls[0]
        let after = try await control("stats", endpoint: endpoint)
        try expect(urls.allSatisfy { $0 == original && $0.isFileURL }, "相同云端原件没有合并下载或未返回本地缓存")
        try expect(after.gets - before.gets == 1, "同一原件的并发请求触发了多次下载")
        try expect(original.lastPathComponent == photo.name, "导出的云端文件没有保留原文件名")
        try expect(try Data(contentsOf: original).count == photo.fileSize, "云端原件的缓存字节数不完整")
        _ = try await resolver.originalFile(for: photo)
        let modified = try original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try expect(modified == photo.modifiedDate, "重复读取原件缓存改变了导出文件的原始修改日期")
        let size = await resolver.cacheSize()
        try expect(size > 0, "原文件缓存大小未计入已下载原件")
        let ref = try require(photo.cloud, "缺少云端引用")
        let errorReference = CloudMediaReference(accountID: ref.accountID, fileID: "/login-error.png", parentID: "/", remotePath: "/login-error.png", revision: "1")
        let errorItem = MediaItem(cloud: errorReference, kind: .image, fileSize: 30, modifiedDate: .distantPast, createdDate: .distantPast)
        for _ in 0..<2 {
            do {
                _ = try await resolver.originalFile(for: errorItem)
                throw CheckFailure(message: "HTML 登录错误页进入了永久媒体缓存")
            } catch is CloudConnectionError { passed += 1 }
        }
        print("✓ 原件下载去重、原名保留、缓存统计及 HTML 错误页拒收")
        return original
    }

    private static func checkThumbnailDiskCache(original: URL, directory: URL) async throws {
        let cache = directory.appendingPathComponent("thumbnail-cache", isDirectory: true)
        let service = ThumbnailService(cacheDirectory: cache, diskBudget: 1_024 * 1_024)
        let date = Date(timeIntervalSince1970: 1_750_149_000)
        let result = await service.loadThumbnail(for: original, kind: .image, modifiedDate: date, pixelSize: 768)
        guard case let .ready(thumbnail) = result else { throw CheckFailure(message: "已下载的合成照片未能实际解码缩略图") }
        try expect(thumbnail.image.size.width > 0 && thumbnail.image.size.height > 0, "缩略图没有真实图像像素")
        let reopened = ThumbnailService(cacheDirectory: cache, diskBudget: 1_024 * 1_024)
        let recovered = await reopened.cachedThumbnail(for: original, kind: .image, modifiedDate: date, pixelSize: 768)
        try expect(recovered != nil, "新的缩略图服务没有读回上次生成的磁盘缓存")
        print("✓ 下载后真实照片解码及重开服务时的持久缩略图缓存")
    }

    private static func checkExportLease(items: [MediaItem], directory: URL) async throws {
        let targets = Array(items.filter { $0.kind == .image }.sorted { $0.name < $1.name }.prefix(2))
        try expect(targets.count == 2 && targets.reduce(0, { $0 + $1.fileSize }) > 100,
                   "导出保护夹具的总大小没有超过测试缓存预算")
        let cacheDirectory = directory.appendingPathComponent("export-cache", isDirectory: true)
        // An export lease protects completed originals, but it does not grant
        // permission to silently exceed the user's configured cache budget.
        let insufficient = MediaAssetResolver(directory: directory.appendingPathComponent("small-export-cache"), diskBudget: 100, recentProtectionDuration: 0)
        let insufficientLease = await insufficient.acquireExportLease(for: targets)
        do {
            for target in targets { _ = try await insufficient.originalFile(for: target) }
            throw CheckFailure(message: "导出保护绕过了缓存预算并静默超额下载")
        } catch CloudConnectionError.cacheBudgetExceeded { passed += 1 }
        let limitedSize = await insufficient.cacheSize()
        try expect(limitedSize <= 100, "被拒绝的导出批次仍突破缓存上限")
        await insufficient.releaseExportLease(insufficientLease)
        _ = await insufficient.clearCache()

        let requiredBytes = targets.reduce(Int64(0)) { $0 + $1.fileSize }
        let resolver = MediaAssetResolver(directory: cacheDirectory, diskBudget: requiredBytes, recentProtectionDuration: 0)
        let lease = await resolver.acquireExportLease(for: targets)
        var urls: [URL] = []
        for target in targets {
            urls.append(try await resolver.originalFile(for: target))
            await resolver.trimCache()
        }
        if !urls.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }) {
            let manifest = (try? String(contentsOf: cacheDirectory.appendingPathComponent(".export-leases.json"), encoding: .utf8)) ?? "missing"
            let files = FileManager.default.enumerator(at: cacheDirectory, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            throw CheckFailure(message: "导出保护路径诊断：返回=\(urls.map(\.path))；清单=\(manifest)；实际=\(files.map(\.path))")
        }
        try expect(urls.allSatisfy { FileManager.default.isReadableFile(atPath: $0.path) },
                   "准备中的受保护导出原件被清理")
        let size = await resolver.cacheSize()
        try expect(size == targets.reduce(0, { $0 + $1.fileSize }), "导出清单被误计入媒体缓存大小")
        await resolver.retainExportLease(lease)
        let protectedClear = await resolver.clearOriginalCache()
        try expect(protectedClear.removedBytes == 0 && protectedClear.protectedBytes == requiredBytes,
                   "手动清理删除了剪贴板待用的导出原件，或没有报告保留大小")
        let reopened = MediaAssetResolver(directory: cacheDirectory, diskBudget: 1, recentProtectionDuration: 0)
        await reopened.trimCache()
        try expect(urls.allSatisfy { FileManager.default.isReadableFile(atPath: $0.path) },
                   "重建缓存服务后导出保护失效，剪贴板原件被清理")
        let retainedDates = try urls.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        try expect(zip(retainedDates, targets).allSatisfy { $0 == $1.modifiedDate }, "缓存裁剪或导出保护改变了原件修改日期")
        await reopened.releaseExportLease(lease)
        await reopened.trimCache()
        let remaining = await reopened.cacheSize()
        try expect(remaining == 0 && urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
                   "解除导出保护后正常缓存预算清理未恢复")
        print("✓ 导出预算明确限制、已完成原件保护、重启保护恢复及解除后正常清理")
    }

    private static func checkMixedCatalogue(account: CloudAccount, library: MediaLibrary, scanned: ScanResult, photoData: Data, endpoint: URL, directory: URL) async throws -> AppStore {
        let localFolder = directory.appendingPathComponent("Local", isDirectory: true)
        try FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)
        let localURL = localFolder.appendingPathComponent("Local.png")
        try photoData.write(to: localURL)
        let localLibrary = MediaLibrary(url: localFolder, name: "本地合成照片")
        let localScan = await MediaScanner().scan(libraries: [localLibrary])
        let local = try require(localScan.items.first, "本地合成照片无法被真实索引")
        let catalogDirectory = directory.appendingPathComponent("Catalogue", isDirectory: true)
        try CatalogPersistence(directory: catalogDirectory).save(CatalogState(libraries: [localLibrary, library], cachedItems: [local] + scanned.items, cloudAccounts: [account]))
        let store = AppStore(directory: catalogDirectory)
        try expect(store.visibleItems.count == 5 && store.cloudAccounts == [account], "启动缓存没有同时显示本地及云端资源")
        store.refresh()
        try await waitForScan(store)
        try expect(store.visibleItems.count == 5 && store.items.count == 5, "实际刷新后本地和云端媒体没有混合")
        try expect(store.count(in: library.selectionPath) == 4 && store.count(in: localLibrary.selectionPath) == 1, "资源库目录计数错误")
        store.toggleFolder(localLibrary.selectionPath)
        try expect(Set(store.visibleItems.map(\.id)) == [local.id], "只选本地资源库仍混入云盘媒体")
        store.toggleFolder(library.selectionPath)
        try expect(store.visibleItems.count == 5, "同时勾选两类资源库未合并显示")
        store.toggleFolder(CloudMediaPath.selectionPath(accountID: account.id, path: "/Trips"))
        try expect(store.visibleItems.count == 4 && store.visibleItems.contains { $0.name == "Neighbor.png" }, "排除子目录错误影响同名前缀目录")
        store.selectScope(.all)
        store.filter = .video
        try expect(store.visibleItems.count == 1 && store.visibleItems[0].kind == .video, "混合媒体的视频筛选错误")
        store.filter = .all
        store.query = "Sunset"
        try expect(store.visibleItems.count == 1 && !store.visibleItems[0].isLocal, "搜索未找到云端原文件名")
        store.query = ""
        let photo = try require(store.items.first { $0.name == "Cloud photo.png" }, "缺少混合目录中的云端照片")
        try await checkCloudMetadataDelivery(store: store, photo: photo)
        try await checkMetadataDuringRefresh(store: store, photo: photo, endpoint: endpoint)
        store.toggleFavorite(photo)
        store.toggleFavorite(local)
        store.selectScope(.favorites)
        try expect(Set(store.visibleItems.map(\.id)) == [local.id, photo.id], "收藏未能混合本地与云端项目")
        let album = try require(store.createAlbum(name: "混合影集", addingIDs: [local.id, photo.id]), "创建混合影集失败")
        store.selectScope(.album(album))
        try expect(store.visibleItems.count == 2, "混合影集成员丢失")
        store.setHidden(true, ids: [photo.id])
        try expect(store.visibleItems.count == 1 && store.visibleItems[0].id == local.id, "隐藏未从影集中全局排除")
        store.selectScope(.all)
        try expect(store.visibleItems.count == 4, "隐藏未从全部项目排除")
        store.selectScope(.favorites)
        try expect(store.visibleItems.count == 1, "隐藏未从收藏排除")
        store.selectScope(.hidden)
        try expect(store.visibleItems.map(\.id) == [photo.id], "隐藏分类无法找回云端项目")
        store.setHidden(false, ids: [photo.id])
        store.selectScope(.all)
        try expect(store.visibleItems.count == 5, "恢复隐藏没有恢复混合目录")
        let sunset = try require(store.items.first { $0.name == "Sunset #1.png" }, "缺少隐藏持久化夹具")
        store.setHidden(true, ids: [sunset.id])
        let saved = await store.flushImmediately()
        try expect(saved, "混合目录持久化失败")
        let persisted = try CatalogPersistence(directory: catalogDirectory).load()
        try expect(persisted.cachedItems.count == 5 && persisted.cloudAccounts == [account] && persisted.albums.first?.itemIDs == [local.id, photo.id], "混合目录序列化丢失来源或集合")
        let json = try String(contentsOf: catalogDirectory.appendingPathComponent("catalog.json"), encoding: .utf8)
        try expect(!json.contains(password) && !json.contains("Authorization") && !json.contains("Bearer "), "目录中持久化了授权凭据")
        print("✓ 实际 AppStore 全部/多资源库/搜索/筛选/收藏/隐藏/恢复/影集及持久化")
        return store
    }

    private static func checkCloudMetadataDelivery(store: AppStore, photo: MediaItem) async throws {
        let ref = try require(photo.cloud, "元数据夹具缺少云端引用")
        store.open(photo)
        store.applyCloudMetadata(Notification(name: CloudPreviewMetadata.notification,
                                              userInfo: ["id": photo.id, "revision": ref.revision, "ratio": 1.5]))
        try await Task.sleep(for: .milliseconds(650))
        let preview = try require(store.items.first { $0.id == photo.id }, "预览元数据更新后项目消失")
        try expect(preview.aspectRatio == 1.5 && preview.pixelWidth == nil && preview.pixelHeight == nil,
                   "预览比例未更新或冒充原图尺寸")
        store.applyCloudMetadata(Notification(name: CloudPreviewMetadata.notification,
                                              userInfo: ["id": photo.id, "revision": "obsolete-revision", "width": 100, "height": 10, "ratio": 10.0]))
        try await Task.sleep(for: .milliseconds(650))
        try expect(store.items.first { $0.id == photo.id } == preview, "旧版本解码事件污染了当前项目")
        store.applyCloudMetadata(Notification(name: CloudPreviewMetadata.notification,
                                              userInfo: ["id": photo.id, "revision": ref.revision, "width": 2, "height": 2, "ratio": 1.0, "camera": "Synthetic Camera"]))
        try await Task.sleep(for: .milliseconds(650))
        let updated = try require(store.items.first { $0.id == photo.id }, "原图元数据更新后项目消失")
        try expect(updated.pixelWidth == 2 && updated.aspectRatio == 1 && updated.camera == "Synthetic Camera", "原图尺寸及相机元数据未写回目录")
        try expect(store.focusedItem?.pixelWidth == 2 && store.focusedItem?.camera == "Synthetic Camera", "查看器焦点仍读取旧的文件信息")
        let oldOrder = store.visibleItems.map(\.id)
        let oldSections = store.timelineSections.map(\.id)
        let revision = store.mediaMetadataRevision
        let structuralRevision = store.visibleRevision
        let timelineRevision = store.timelineRevision
        store.applyCloudMetadata(Notification(name: CloudPreviewMetadata.notification,
            userInfo: ["id": photo.id, "revision": ref.revision, "lens": "Batched Lens", "capturedDate": Date(timeIntervalSince1970: 1)]))
        store.applyCloudMetadata(Notification(name: CloudPreviewMetadata.notification,
            userInfo: ["id": photo.id, "revision": "obsolete-revision", "width": 999, "height": 1]))
        try await Task.sleep(for: .milliseconds(650))
        let batched = try require(store.items.first { $0.id == photo.id }, "批处理项目消失")
        try expect(batched.lens == "Batched Lens" && batched.pixelWidth == 2, "过期批次不能覆盖同时到达的当前版本信息")
        try expect(store.mediaMetadataRevision == revision + 1, "同批元数据应只发布一次差量更新")
        try expect(store.visibleRevision == structuralRevision && store.timelineRevision == timelineRevision,
                   "元数据变动不应发布结构更新")
        let metadataDelta = store.mediaMetadataChanges(since: revision)
        try expect(metadataDelta?.changedIDs == [photo.id] && metadataDelta?.geometryChangedIDs.isEmpty == true,
                   "镜头或拍摄日期元数据错误触发几何重排")
        try expect(store.visibleItems.map(\.id) == oldOrder && store.timelineSections.map(\.id) == oldSections,
                   "后台补拍摄日期不能突然重排当前浏览")
        store.closePreview()
        print("✓ 比例与原图尺寸区分、批次合并、过期版本隔离及当前浏览顺序保留")
    }

    private static func checkMetadataDuringRefresh(store: AppStore, photo: MediaItem, endpoint: URL) async throws {
        let ref = try require(photo.cloud, "扫描期间元数据夹具缺少云端引用")
        let before = try await control("slow", endpoint: endpoint)
        store.refresh()
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            let current = try await control("stats", endpoint: endpoint)
            if current.propfinds > before.propfinds { break }
            guard ContinuousClock.now < deadline else { throw CheckFailure(message: "延迟扫描夹具没有进入云端请求") }
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(store.isScanning, "元数据更新没有发生在真实云端扫描期间")
        let captured = Date(timeIntervalSince1970: 946_684_800)
        store.applyCloudMetadata(Notification(name: CloudPreviewMetadata.notification,
                                              userInfo: ["id": photo.id, "revision": ref.revision,
                                                         "width": 7, "height": 5, "camera": "Arrived During Scan", "capturedDate": captured]))
        try await waitForScan(store)
        try await Task.sleep(for: .milliseconds(650))
        _ = try await control("fast", endpoint: endpoint)
        let final = try require(store.items.first { $0.id == photo.id }, "扫描结束后媒体丢失")
        try expect(final.pixelWidth == 7 && final.pixelHeight == 5 && final.camera == "Arrived During Scan" && final.capturedDate == captured,
                   "刷新结束使用旧快照覆盖了扫描期间学到的原件元数据")
        print("✓ 真实扫描期间到达的原图尺寸、EXIF 及拍摄日期在扫描完成后保留")
    }

    private static func checkOfflinePreservation(store: AppStore, resolver: MediaAssetResolver, cachedPhoto: URL,
                                                  items: [MediaItem], account: CloudAccount, endpoint: URL, directory: URL) async throws {
        _ = try await control("offline", endpoint: endpoint)
        let before = Set(store.items.map(\.id))
        store.refresh()
        try await waitForScan(store)
        try expect(Set(store.items.map(\.id)) == before && store.visibleItems.count == 4, "离线刷新清除了已缓存的云盘索引或隐藏规则")
        let cloudLibrary = try require(store.libraries.first { !$0.isLocal }, "缺少云端资源库")
        try expect(store.offlineLibraries.contains(cloudLibrary.id), "云盘离线没有被明确记录")
        try expect(store.items.filter { !$0.isLocal }.allSatisfy(store.isOffline), "离线状态未对应到云端媒体")
        try expect(store.items.filter(\.isLocal).allSatisfy { !store.isOffline($0) }, "云盘离线影响本地磁盘")
        let photo = try require(items.first { $0.name == "Sunset #1.png" }, "缺少缓存照片")
        let recovered = try await resolver.originalFile(for: photo)
        try expect(recovered == cachedPhoto && FileManager.default.isReadableFile(atPath: recovered.path), "离线时没有复用已下载原件")
        let secondResolver = MediaAssetResolver(directory: directory.appendingPathComponent("original-cache", isDirectory: true))
        let secondRecovered = try await secondResolver.originalFile(for: photo)
        try expect(secondRecovered == recovered, "重建下载服务后离线缓存失效")
        let saved = await store.flushImmediately()
        try expect(saved, "离线目录保存失败")
        let reopened = AppStore(directory: directory.appendingPathComponent("Catalogue", isDirectory: true))
        try expect(reopened.items.count == 5 && reopened.visibleItems.count == 4 && reopened.cloudAccounts == [account], "离线重开目录没有立即显示已缓存媒体")
        reopened.cancelScan()
        print("✓ 云盘离线保留索引及集合、本地继续可用、原件缓存跨实例恢复")
    }

    private static func checkReconnectAndForget(account: CloudAccount, endpoint: URL) async throws {
        _ = try await control("online", endpoint: endpoint)
        await CloudGateway.shared.shutdown()
        await CloudGateway.shared.register(accounts: [account])
        let page = try await CloudGateway.shared.list(account: account, folderID: "/", path: "/")
        try expect(page.entries.count == 5, "后台组件重启后未从钥匙串恢复登录")
        try await CloudGateway.shared.forget(accountID: account.id)
        do {
            _ = try await CloudGateway.shared.list(account: account, folderID: "/", path: "/")
            throw CheckFailure(message: "移除账号后仍可以自动连接")
        } catch let error as CloudConnectionError {
            guard case .credentialsMissing = error else { throw error }
            passed += 1
        }
        print("✓ 钥匙串恢复连接、账号移除与凭据清理")
    }

    private struct FixtureState: Decodable { let gets: Int; let ranges: Int; let propfinds: Int; let auth_failures: Int }

    private static func control(_ action: String, endpoint: URL) async throws -> FixtureState {
        let url = endpoint.deletingLastPathComponent().appendingPathComponent("control").appendingPathComponent(action)
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CheckFailure(message: "本机夹具控制失败") }
        return try JSONDecoder().decode(FixtureState.self, from: data)
    }

    private static func waitForScan(_ store: AppStore) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while store.isScanning {
            guard ContinuousClock.now < deadline else { store.cancelScan(); throw CheckFailure(message: "云盘刷新超过二十秒") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CheckFailure(message: message) }
        passed += 1
    }

    private static func require<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else { throw CheckFailure(message: message) }
        return value
    }

    private struct CheckFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}

/// Clipboard commands are outside this runner. A call here is an unintended
/// test side effect; the user's system clipboard must remain untouched.
@MainActor extension AppStore {
    func copyFiles(_ targets: [MediaItem], pathsOnly: Bool = false, to pasteboard: NSPasteboard = .general) {
        preconditionFailure("Cloud integration checks must not access a clipboard")
    }
}
