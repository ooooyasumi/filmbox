import AppKit
import Foundation
import FilmboxCore
import ImageIO
import UniformTypeIdentifiers

@main @MainActor private struct RefreshChecks {
    static var count = 0
    static func main() async {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FilmboxRefresh-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try await replaceEighty(root)
            try await refreshScopeAndStableLayout(root)
            try await cloudDelta(root)
            try await cacheAndLateDecode(root)
            try await bookmarkAndMove(root)
            try await writerNoop(root)
            try await partialPermissions(root)
            try await nestedLibraries(root)
            try trackpad()
            print("\(count)项刷新／重连／缓存／触控板检查通过；仅临时文件和合成云账号")
        } catch { print("FAIL \(error)"); exit(1) }
    }
    static func replaceEighty(_ root: URL) async throws {
        let media = root.appendingPathComponent("Disk/Photos")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for i in 0..<80 { try image(media.appendingPathComponent("old-\(i).bmp"), blue: false) }
        let library = MediaLibrary(url: media)
        let store = AppStore(directory: root.appendingPathComponent("catalog-80"))
        store.libraries = [library]; store.refreshLibrary(library.id); try await wait { !store.isScanning }
        try check(store.items.count == 80 && !store.isOffline(store.items[0]), "首次导入80张照片，数量和在线状态正确")
        let oldIDs = Set(store.items.map(\.id))
        let detached = media.deletingLastPathComponent().appendingPathComponent("Detached")
        try FileManager.default.moveItem(at: media, to: detached)
        store.volumeDidUnmount(root.appendingPathComponent("Disk")); try await wait { !store.isScanning }
        try check(store.offlineLibraries.contains(library.id) && Set(store.items.map(\.id)) == oldIDs, "拔盘后保留80项离线索引")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for i in 0..<80 { try image(media.appendingPathComponent("new-\(i).bmp"), blue: true) }
        store.volumeDidMount(root.appendingPathComponent("Disk")); try await wait { !store.isScanning }
        try check(store.items.count == 80 && Set(store.items.map(\.id)).isDisjoint(with: oldIDs), "插回换了名字的80张：删除旧项、加入新项，数量不靠旧缓存")
        try check(store.offlineLibraries.isEmpty && store.items.allSatisfy { !store.isOffline($0) }, "重新挂载自动退出离线状态")
        let original = store.items[0], url = original.url
        try image(url, blue: false)
        try FileManager.default.setAttributes([.modificationDate: original.modifiedDate, .creationDate: original.createdDate], ofItemAtPath: url.path)
        store.refreshLibrary(library.id); try await wait { !store.isScanning }
        let updated = try require(store.items.first { $0.id == original.id })
        try check(updated.fileSize == original.fileSize && updated.modifiedDate == original.modifiedDate && updated.localRevision != original.localRevision,
                  "同名、同大小且保留修改时间的替换文件获得新预览身份")
        let fresh = await ThumbnailService(cacheDirectory: root.appendingPathComponent("thumb-80")).thumbnail(for: updated.url, kind: .image, modifiedDate: updated.modifiedDate, pixelSize: 256, localRevision: updated.localRevision)
        try check(fresh.map { !isBlue($0) } == true, "替换后的缩略图读取当前红图，不显示之前的蓝图")
        try FileManager.default.removeItem(at: media)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        store.refreshLibrary(library.id); try await wait { !store.isScanning }
        try check(store.items.isEmpty && store.offlineLibraries.isEmpty, "已连接但空的目录刷新为空，不误报离线")
        await store.waitForFileOperations(); _ = await store.flushImmediately()
    }
    static func refreshScopeAndStableLayout(_ root: URL) async throws {
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        for p in [a,b] { try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true); try image(p.appendingPathComponent("one.bmp"),blue:false) }
        let la = MediaLibrary(url:a), lb = MediaLibrary(url:b)
        let store = AppStore(directory:root.appendingPathComponent("scoped"));store.libraries=[la,lb]
        store.refreshLocalLibraries(); try await wait { !store.isScanning }
        let before = store.items, visible = store.visibleRevision, timeline = store.timelineRevision, metadata = store.mediaMetadataRevision
        store.refreshLocalLibraries();try await wait { !store.isScanning }
        try check(store.items == before && store.visibleRevision == visible && store.timelineRevision == timeline && store.mediaMetadataRevision == metadata,
                  "无变化的后台核验不重建媒体、时间线或元数据快照")
        let current = try require(store.items.first { $0.belongs(to: la) });store.layout = .browse;store.focus(current)
        let unrelated = try require(store.items.first { $0.belongs(to: lb) })
        store.refreshLibrary(la.id);try await wait { !store.isScanning }
        try check(store.items.first { $0.id == unrelated.id } == unrelated, "单库重新加载不更改其他本地资源库的缓存身份")
        try check(store.visibleRevision == visible && store.timelineRevision == timeline && store.mediaMetadataRevision > metadata,
                  "只有预览身份变化时采用元数据增量发布，不重排图库")
        try check(store.visibleItems[store.browseIndex].id == current.id,"刷新保留当前照片卷位置")
        let scanner = MediaScanner();let both = await scanner.scan(libraries:[la,lb]);_ = await scanner.scan(libraries:[la])
        let warmB = await scanner.scan(libraries:[lb]);try check(warmB.items.first?.localRevision == both.items.first { $0.belongs(to:lb) }?.localRevision, "分库扫描保留其他根目录的元数据缓存")
        store.refreshLibrary(la.id);store.refreshLibrary(lb.id);try await wait { !store.isScanning }
        try check(store.items.count == 2 && store.items.allSatisfy { $0.localRevision != nil }, "连续两个单库刷新会合并，不丢弃前一个请求")
        store.scope = .folders; store.directorySelection = .init(included: [b.path]); store.applyFilters()
        store.refreshLibrary(la.id)
        try check(store.canvasIndexActivity == nil, "单库扫描不让另一个文件夹误显示正在整理")
        try await wait { !store.isScanning }
        await store.waitForFileOperations()
    }
    static func cloudDelta(_ root: URL) async throws {
        let remote = Remote(), account = CloudAccount(provider:.quark,name:"合成账号")
        let first = MediaLibrary(cloud:.init(accountID:account.id,folderID:"one",path:"/One"))
        let second = MediaLibrary(cloud:.init(accountID:account.id,folderID:"two",path:"/Two"))
        let directory = root.appendingPathComponent("cloud")
        let store = AppStore(directory:directory,cloudDirectoryLoader:{ _,id,path in try await remote.page(id,path) })
        store.cloudAccounts=[account];store.libraries=[first,second]
        store.refresh();try await wait { !store.isScanning }
        try check(store.items.count == 4, "云端首次完整索引，两个库各两项")
        let item = try require(store.items.first { $0.cloud?.fileID == "one-a" });store.favorites=[item.id];_ = store.createAlbum(name:"保存整理",addingIDs:[item.id])
        let storeIndex = CloudIndexStore(catalogDirectory:directory)
        let jsonFiles = try FileManager.default.contentsOfDirectory(at:storeIndex.directory.appendingPathComponent(first.id.uuidString),includingPropertiesForKeys:nil).filter { $0.deletingPathExtension().lastPathComponent.count == 64 }
        let unchangedPath = try require(jsonFiles.first), before = try unchangedPath.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate
        let revision = store.visibleRevision, time = store.timelineRevision
        store.refreshLibrary(first.id);try await wait { !store.isScanning }
        try check(await remote.calls("one") == 2, "单库云端刷新只检查该库的目录")
        try check(await remote.calls("two") == 1, "其他云库不重新遍历")
        try check(try unchangedPath.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate == before,
                  "无变化的云目录复用原检查点，不重写大目录JSON")
        try check(store.visibleRevision == revision && store.timelineRevision == time, "无变化的云端校对不重排媒体")
        await remote.setHold(true)
        store.refreshLibrary(first.id);try await wait { await remote.calls("one") == 3 }
        store.refreshLibrary(first.id);store.refresh()
        try await wait { await remote.calls("two") == 2 }
        try check(await remote.calls("one") == 3,"重复刷新和全局刷新不取消重启已经进行的云目录检查")
        await remote.setHold(false);try await wait { !store.isScanning }
        try check(store.cloudIndexProgress[first.id]?.phase == .ready && store.cloudIndexProgress[second.id]?.phase == .ready,
                  "全局刷新继续检查尚未工作的资源库，两者独立完成")
        await remote.setPhase(1);store.refreshLibrary(first.id);try await wait { !store.isScanning }
        let own = store.items.filter { $0.belongs(to:first) }
        try check(own.count == 2 && own.contains { $0.cloud?.fileID == "one-c" } && !own.contains { $0.cloud?.fileID == "one-b" }, "云端增删仅提交最新差异")
        try check(own.first { $0.id == item.id }?.fileSize == 200 && store.favorites == [item.id] && store.albums[0].itemIDs == [item.id],
                  "云端文件版本变化更新索引，并保留身份、收藏及影集")
        let previous = store.items;await remote.setPhase(2);store.refreshLibrary(first.id);try await wait { !store.isScanning }
        try check(store.items == previous && store.cloudIndexProgress[first.id]?.phase == .failed, "云端校对失败保留完整旧索引")
        await store.waitForFileOperations()
    }
    static func cacheAndLateDecode(_ root: URL) async throws {
        let url = root.appendingPathComponent("same.bmp");try image(url,blue:false)
        let library = MediaLibrary(url:root), scanner = MediaScanner()
        let firstScan = await scanner.scan(libraries:[library]);let original = try require(firstScan.items.first { $0.url == url })
        let service = ThumbnailService(cacheDirectory:root.appendingPathComponent("same-cache"))
        let old = await service.thumbnail(for:url,kind:.image,modifiedDate:original.modifiedDate,pixelSize:256,localRevision:original.localRevision)
        try check(old.map { !isBlue($0) } == true,"先把红图放入旧版本预览缓存")
        try image(url,blue:true);try FileManager.default.setAttributes([.modificationDate:original.modifiedDate,.creationDate:original.createdDate],ofItemAtPath:url.path)
        let next = await scanner.scan(libraries:[library],verifyContents:true);let updated = try require(next.items.first { $0.url == url })
        let high = await service.thumbnail(for:url,kind:.image,modifiedDate:updated.modifiedDate,pixelSize:256,localRevision:updated.localRevision)
        try check(high.map(isBlue) == true,"新版本不命中旧内存或旧磁盘的红图")
        let reopened = ThumbnailService(cacheDirectory:root.appendingPathComponent("same-cache"))
        let disk = await reopened.cachedThumbnail(for:url,kind:.image,modifiedDate:updated.modifiedDate,pixelSize:256,localRevision:updated.localRevision)
        try check(disk.map(isBlue) == true,"重开后只读取该版本的蓝图缓存")
        let secondVerification = await scanner.scan(libraries:[library],verifyContents:true)
        try check(secondVerification.items.first { $0.url == url }?.localRevision != updated.localRevision, "手动刷新更新验证代际，不依赖不可靠的磁盘时间精度")
        let session = PhotoPreviewSession(), gate = Gate()
        let job = Task { await session.load(item:original,cached:{ _ in old },full:{ _ in await gate.wait() }) }
        try await wait { await gate.waiting }
        await session.load(item:updated,cached:{ _ in high },full:{ _ in .ready(high!) })
        await gate.finish(.ready(old!));await job.value
        try check(session.state == .ready && session.thumbnail.map(isBlue) == true,"旧版本解码晚到也不会覆盖新的照片")
        let verified = updated.withLocalRevision((updated.localFileStamp ?? "") + "|next-verification")
        let quietGate = Gate()
        let quietJob = Task { await session.load(item:verified,cached:{_ in nil},full:{_ in await quietGate.wait()}) }
        try await wait { await quietGate.waiting }
        try check(session.thumbnail.map(isBlue) == true, "同一文件复核时保留可用画面，避免空白闪动")
        await quietGate.finish(.ready(high!)); await quietJob.value
        let canvas = PhotoScrollView(frame:NSRect(x:0,y:0,width:600,height:400))
        canvas.configure(item:updated,image:high!.image);_ = canvas.setPhotoScale(2)
        let scale = canvas.magnification
        canvas.configure(item:verified,image:high!.image)
        try check(abs(canvas.magnification-scale)<0.001,"验证代际变化不重置查看器缩放")
        canvas.tearDown()
        var legacy = try JSONSerialization.jsonObject(with:JSONEncoder().encode(updated)) as! [String:Any]
        legacy.removeValue(forKey:"localRevision")
        let migrated = try JSONDecoder().decode(MediaItem.self,from:JSONSerialization.data(withJSONObject:legacy))
        try check(migrated.id == updated.id && migrated.localRevision == nil,"旧版资料库没有新增修订字段时仍能读取")
    }
    static func bookmarkAndMove(_ root: URL) async throws {
        let path = root.appendingPathComponent("bookmark-root");try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true);try image(path.appendingPathComponent("valid.bmp"),blue:false)
        let library = MediaLibrary(url:path,bookmark:Data([1,2,3]))
        try check(try library.resolvedURL().path == path.path, "坏书签不会覆盖可访问的原选择路径")
        let result = await MediaScanner().scan(libraries:[library])
        try check(result.items.count == 1 && result.unavailableLibraryIDs.isEmpty && result.refreshedBookmarks[library.id] != nil, "扫描恢复正常路径并提供更新后的书签")
        let state = CatalogState(libraries:[library],cachedItems:result.items)
        let directory = root.appendingPathComponent("bookmark-catalog");try CatalogPersistence(directory:directory).save(state)
        let store = AppStore(directory:directory);store.refreshLibrary(library.id);try await wait { !store.isScanning }
        try check(store.libraries[0].bookmark != library.bookmark && store.offlineLibraries.isEmpty, "可访问目录恢复后修复持久书签，不需要反复重新连接")
        let previous = try require(store.items.first)
        store.favorites = [previous.id]; let album = store.createAlbum(name: "移动目录", addingIDs: [previous.id])!
        store.scope = .folders; store.directorySelection = .init(included: [path.path]); store.applyFilters(); store.focus(previous)
        let moved = root.appendingPathComponent("moved-bookmark-root")
        try FileManager.default.moveItem(at: path, to: moved)
        store.refreshLibrary(library.id); try await wait { !store.isScanning }
        let relocated = moved.appendingPathComponent("valid.bmp").path
        try check(store.libraries[0].url.path == moved.path && store.favorites == [relocated]
                  && store.albums.first { $0.id == album }?.itemIDs == [relocated], "文件夹改名后通过书签定位并迁移收藏、影集关系")
        try check(store.visibleItems.first?.id == relocated && store.visibleItems[store.browseIndex].id == relocated,
                  "根目录变动后保留文件夹选择和当前照片")
        await store.waitForFileOperations()
    }
    static func partialPermissions(_ root: URL) async throws {
        let media = root.appendingPathComponent("partial-access"), child = media.appendingPathComponent("private")
        try FileManager.default.createDirectory(at:child,withIntermediateDirectories:true)
        try image(media.appendingPathComponent("visible.bmp"),blue:false)
        try image(child.appendingPathComponent("protected.bmp"),blue:true)
        let library = MediaLibrary(url:media), store = AppStore(directory:root.appendingPathComponent("partial-catalog"))
        store.libraries=[library];store.refreshLibrary(library.id);try await wait { !store.isScanning }
        try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:child.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:child.path) }
        let probe = await MediaScanner().scan(libraries:[library])
        try check(probe.unavailableLibraryIDs.isEmpty && !probe.unverifiedPaths.isEmpty,
                  "子目录无法读取不等于整块磁盘离线，记录无法验证的范围")
        store.refreshLibrary(library.id);try await wait { !store.isScanning }
        try check(store.items.count == 2 && store.offlineLibraries.isEmpty && !store.scanWarnings.isEmpty,
                  "部分目录无权限时保留其旧索引，其他可访问照片仍保持在线")
        await store.waitForFileOperations()
    }
    static func nestedLibraries(_ root: URL) async throws {
        let parent = root.appendingPathComponent("nested-libraries"), child = parent.appendingPathComponent("Child")
        try FileManager.default.createDirectory(at:child,withIntermediateDirectories:true)
        try image(parent.appendingPathComponent("parent.bmp"),blue:false);try image(child.appendingPathComponent("child.bmp"),blue:true)
        let a=MediaLibrary(url:parent),b=MediaLibrary(url:child),store=AppStore(directory:root.appendingPathComponent("nested-catalog"))
        store.libraries=[a,b];store.refreshLocalLibraries();try await wait { !store.isScanning }
        let parentItem=try require(store.items.first { $0.name == "parent.bmp" })
        store.refreshLibrary(b.id);try await wait { !store.isScanning }
        try check(store.childFolders[parent.path]?.contains { $0.url.path == child.path } == true && store.items.count == 2,
                  "单独重载嵌套资源库不会让它从父资源库目录树中消失")
        try check(store.items.first { $0.id == parentItem.id } == parentItem,"子库重载不使父库其他照片的缓存失效")
        await store.waitForFileOperations()
    }
    static func writerNoop(_ root: URL) async throws {
        let directory = root.appendingPathComponent("noop-catalog"), store = AppStore(directory:directory)
        _ = await store.flushImmediately()
        let file = directory.appendingPathComponent("catalog.json"), stamp = LocalFileRevision.stamp(at:file)
        _ = await store.flushImmediately();try check(LocalFileRevision.stamp(at:file) == stamp,"无变化的重复保存不重写资料库文件")
        try FileManager.default.removeItem(at:file);_ = await store.flushImmediately()
        try check(FileManager.default.fileExists(atPath:file.path),"保存去重不掩盖被外部删除的资料库文件")
        await store.waitForFileOperations()
    }
    static func trackpad() throws {
        var projection = BrowseWheelProjection()
        let a = projection.project(x:-12,y:2,precise:true,phase:.began,momentum:[],time:1)
        let b = projection.project(x:-2,y:8,precise:true,phase:.changed,momentum:[],time:1.01)
        let c = projection.project(x:-1,y:5,precise:true,phase:[],momentum:.changed,time:1.2)
        try check(a.0 == .horizontal && b.0 == .horizontal && b.1 == -2 && c.0 == .horizontal,"触控板斜向噪声和惯性不导致横纵轴来回切换")
        let d = projection.project(x:1,y:-8,precise:true,phase:.began,momentum:[],time:1.3)
        try check(d.0 == .vertical && d.1 == -8,"新手势可以用竖向滑动浏览照片卷")
    }
    static func image(_ url: URL, blue: Bool) throws {
        let c = CGContext(data:nil,width:40,height:20,bitsPerComponent:8,bytesPerRow:160,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
        c.setFillColor(CGColor(red:blue ? 0:1,green:0,blue:blue ? 1:0,alpha:1));c.fill(CGRect(x:0,y:0,width:40,height:20))
        let d=CGImageDestinationCreateWithURL(url as CFURL,UTType.bmp.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(d,c.makeImage()!,nil);guard CGImageDestinationFinalize(d) else { throw Failure("图片夹具写入失败") }
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1700000000)],ofItemAtPath:url.path)
    }
    static func isBlue(_ thumbnail:Thumbnail) -> Bool {
        let image=thumbnail.image.cgImage(forProposedRect:nil,context:nil,hints:nil)!
        let c=CGContext(data:nil,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image,in:CGRect(x:0,y:0,width:1,height:1));let p=c.data!.assumingMemoryBound(to:UInt8.self);return p[2]>p[0]
    }
    static func check(_ condition:Bool,_ text:String)throws { guard condition else {throw Failure(text)};count+=1;print("✓ \(text)") }
    static func require<T>(_ v:T?)throws->T {guard let v else{throw Failure("缺少测试数据")};return v}
    static func wait(_ f:()async->Bool)async throws {for _ in 0..<1000 {if await f(){return};try await Task.sleep(for:.milliseconds(10))};throw Failure("等待超时")}
    struct Failure:Error {let message:String;init(_ message:String){self.message=message}}
    actor Remote {
        var n:[String:Int]=[:],phase=0
        var held=false
        func setHold(_ value:Bool){held=value}
        func setPhase(_ v:Int){phase=v}
        func calls(_ id:String)->Int{n[id,default:0]}
        func page(_ id:String,_ path:String)async throws->CloudDirectoryPage {
            n[id,default:0]+=1
            while held { try await Task.sleep(for:.milliseconds(5)) }
            if phase==2 && id=="one"{throw Failure("合成离线")}
            let a=CloudDirectoryEntry(id:id+"-a",name:"a.jpg",isDirectory:false,size:phase==1 && id=="one" ? 200:100,modified:Date(timeIntervalSince1970:1700000000+(phase==1 && id=="one" ? 1:0)),created:nil,width:nil,height:nil,duration:nil,thumbnail:nil)
            let b=CloudDirectoryEntry(id:id+(phase==1 && id=="one" ? "-c":"-b"),name:phase==1 && id=="one" ? "c.jpg":"b.jpg",isDirectory:false,size:100,modified:Date(timeIntervalSince1970:1700000000),created:nil,width:nil,height:nil,duration:nil,thumbnail:nil)
            return .init(entries:[a,b],folderID:id,path:path,credential:nil)
        }
    }
    actor Gate {
        var continuation:CheckedContinuation<ThumbnailLoadResult,Never>?
        var waiting:Bool{continuation != nil}
        func wait()async->ThumbnailLoadResult{await withCheckedContinuation{continuation=$0}}
        func finish(_ value:ThumbnailLoadResult){continuation?.resume(returning:value);continuation=nil}
    }
}
