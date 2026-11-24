import SwiftUI
import AppKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import FilmboxCore

@main @MainActor private struct ViewerRefinementChecks {
    static var passed = 0
    static func main() async {
        _ = NSApplication.shared
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("Filmbox-ViewerRefinement-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try await indexIsolation(root)
            try await rotation(root)
            try await presentation()
            try wheel()
            try await mountedViewer(root)
            try contextMenu(root)
            print("\(passed)项查看器与索引隔离检查通过；不使用真实账号或修改用户照片")
        } catch { print("FAIL \(error)"); exit(1) }
    }
    static func indexIsolation(_ root: URL) async throws {
        let account = CloudAccount(provider: .quark, name: "合成账号")
        let first = MediaLibrary(cloud: .init(accountID: account.id, folderID: "first", path: "/First"))
        let remote = Remote()
        let store = AppStore(directory: root.appendingPathComponent("index"), cloudDirectoryLoader: { _, id, path in
            try await remote.list(id, path)
        })
        store.cloudAccounts = [account]; store.libraries = [first]
        store.refreshCloudLibrary(first.id)
        try await wait { !store.isScanning }
        let complete = store.cloudIndexProgress[first.id]
        try check(await remote.count("first") == 1 && complete?.phase == .ready, "已有云库完整建立索引")
        let local = root.appendingPathComponent("local"); try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try makePhoto(local.appendingPathComponent("isolation.png"), type: .png, orientation: 1)
        store.addFolders([local]); try await wait { !store.isScanning }
        try check(await remote.count("first") == 1 && store.cloudIndexProgress[first.id] == complete, "添加本地资源库不遍历或重置已有云库")
        store.refreshLocalLibraries(); try await wait { !store.isScanning }
        try check(await remote.count("first") == 1, "磁盘挂载的本地刷新不触发云端请求")
        store.addCloudLibrary(account: account, reference: .init(accountID: account.id, folderID: "second", path: "/Second"), name: "Second")
        try await wait { !store.isScanning }
        try check(await remote.count("first") == 1, "添加同账号云库不遍历旧库")
        try check(await remote.count("second") == 1, "新增云库独立索引")
        store.refresh(); try await wait { !store.isScanning }
        try check(await remote.count("first") == 2, "手动全局刷新仍校对所有云库")
        await remote.setHold(true)
        store.refreshCloudLibrary(first.id)
        try await wait { await remote.count("first") == 3 }
        let localItem = try require(store.visibleItems.first(where: \.isLocal), "缺少本地夹具")
        let renamed = await store.rename(localItem, to: "renamed")
        try check(renamed && store.cloudIndexProgress[first.id]?.phase == .indexing, "本地文件管理不取消正在进行的云端索引")
        await remote.setHold(false); try await wait { !store.isScanning }
        try check(await remote.count("first") == 3, "本地文件管理完成不重新启动云端遍历")
        await store.waitForFileOperations(); _ = await store.flushImmediately()
    }
    static func rotation(_ root: URL) async throws {
        let folder = root.appendingPathComponent("photos"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for type in [UTType.jpeg, .png, .tiff, .heic] {
            for orientation in 1...8 {
                let url = folder.appendingPathComponent("\(type.preferredFilenameExtension!)-\(orientation).\(type.preferredFilenameExtension!)")
                try makePhoto(url, type: type, orientation: orientation)
                let tag = Data("preserved-finder-metadata".utf8)
                let tagged = tag.withUnsafeBytes { setxattr(url.path, "com.filmbox.rotation-test", $0.baseAddress, $0.count, 0, 0) }
                guard tagged == 0 else { throw Failure("无法创建扩展属性夹具") }
                let item = try fileItem(url)
                let originalPixels = try decodedPixels(url)
                let rotated = try await Task.detached { try LocalPhotoRotation.rotate(item, direction: .right) }.value
                let props = try properties(url)
                let next = LocalPhotoRotation.orientation(orientation, turning: .right)
                try check(props[kCGImagePropertyOrientation] as? Int == next && rotated.pixelWidth == (next >= 5 ? 80 : 120)
                          && rotated.pixelHeight == (next >= 5 ? 120 : 80), "\(type.preferredFilenameExtension!)方向\(orientation)右旋正确保存原文件和显示比例")
                try check(try decodedPixels(url) == originalPixels, "\(type.preferredFilenameExtension!)方向\(orientation)不重压缩像素")
                let restored = try await Task.detached { try LocalPhotoRotation.rotate(rotated, direction: .left) }.value
                let restoredProps = try properties(url)
                try check(restoredProps[kCGImagePropertyOrientation] as? Int == orientation && restored.id == item.id
                          && abs(restored.createdDate.timeIntervalSince(item.createdDate)) < 0.002
                          && (restoredProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String == "KeepCamera",
                          "\(type.preferredFilenameExtension!)左旋还原并保留身份、创建日期及相机元数据")
                try check(restored.modifiedDate != item.modifiedDate && restored.capturedDate == item.capturedDate, "旋转使预览缓存失效但不更改拍摄日期")
                var tagBytes = [UInt8](repeating: 0, count: 128)
                let tagSize = getxattr(url.path, "com.filmbox.rotation-test", &tagBytes, tagBytes.count, 0, 0)
                try check(tagSize == tag.count && Data(tagBytes.prefix(max(0, tagSize))) == tag, "旋转保留文件扩展属性（Finder标签等）")
                let saved = try Data(contentsOf: url)
                do { _ = try LocalPhotoRotation.rotate(item, direction: .left); throw Failure("陈旧索引被错误接受") }
                catch is LocalPhotoRotation.Failure { }
                try check(try Data(contentsOf: url) == saved, "陈旧原件引用被拒绝且不修改文件")
            }
        }
        let animated = folder.appendingPathComponent("multi.tiff")
        try makePhoto(animated, type: .tiff, orientation: 1, frames: 2)
        let multi = try fileItem(animated), bytes = try Data(contentsOf: animated)
        do { _ = try LocalPhotoRotation.rotate(multi, direction: .right); throw Failure("多帧被覆盖") } catch is LocalPhotoRotation.Failure { }
        try check(try Data(contentsOf: animated) == bytes, "多帧图片不被截断为一帧")
        let source = folder.appendingPathComponent("\(UTType.jpeg.preferredFilenameExtension!)-1.\(UTType.jpeg.preferredFilenameExtension!)"), alias = folder.appendingPathComponent("alias.jpg")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let linkItem = try fileItem(alias), before = try Data(contentsOf: source)
        do { _ = try LocalPhotoRotation.rotate(linkItem, direction: .right); throw Failure("符号链接被写入") } catch is LocalPhotoRotation.Failure { }
        try check(try Data(contentsOf: source) == before, "符号链接不绕过原文件保护")
        let store = AppStore(directory: root.appendingPathComponent("rotation-store"))
        store.libraries = [MediaLibrary(url: folder)]; store.refreshLocalLibraries(); try await wait { !store.isScanning }
        let current = try require(store.visibleItems.first(where: {$0.url == source}), "本地索引缺少测试照片")
        store.selectedIDs = [current.id]; store.favorites = [current.id]; store.previewID = current.id
        let album = store.createAlbum(name: "旋转影集", addingIDs: [current.id])!
        let success = await store.rotatePhoto(current, direction: .right)
        try check(success && store.visibleMediaItem(id: current.id)?.pixelWidth == 80 && store.previewID == current.id, "真实AppStore旋转刷新查看器和图库，保持当前项目")
        try check(store.selectedIDs == [current.id] && store.favorites == [current.id] && store.albums.first(where: {$0.id == album})?.itemIDs == [current.id], "旋转保留选择、收藏和影集")
        let scanner = MediaScanner(); let scanned = await scanner.scan(libraries: store.libraries)
        try check(scanned.items.first(where: {$0.id == current.id})?.pixelWidth == 80, "重新扫描仍读取已保存方向")
        await store.waitForFileOperations(); _ = await store.flushImmediately()
        let reopened = AppStore(directory: root.appendingPathComponent("rotation-store"))
        try check(reopened.visibleMediaItem(id: current.id)?.pixelWidth == 80, "重开资源库保留保存后的尺寸")
        await reopened.waitForFileOperations()
    }
    static func presentation() async throws {
        let local = MediaItem(url: URL(fileURLWithPath: "/fixture/local.jpg"), kind: .image, fileSize: 1, modifiedDate: .distantPast, createdDate: .distantPast)
        let reference = CloudMediaReference(accountID: UUID(), fileID: "cloud", parentID: "0", remotePath: "/cloud.jpg", revision: "1")
        let cloud = MediaItem(cloud: reference, kind: .image, fileSize: 100, modifiedDate: .distantPast, createdDate: .distantPast)
        try check(PhotoPreviewFeedback.presentation(state: .loading, item: local, isOffline: false, original: nil, needsLogin: true) == nil, "本地照片快速划过不弹加载或下载提示")
        try check(PhotoPreviewFeedback.presentation(state: .unavailable, item: local, isOffline: true, original: nil, needsLogin: false)?.title == MediaFailureText.offline, "本地离线错误仍可见")
        try check(PhotoPreviewFeedback.presentation(state: .loading, item: cloud, isOffline: false, original: nil, needsLogin: true)?.kind == .login, "云盘失效直接提示重新登录")
        let t = CloudTransferSnapshot(itemID: cloud.id, name: cloud.name, purpose: .original, state: .downloading, receivedBytes: 40, totalBytes: 100, isOriginalCached: false, updatedAt: Date(), priority: .foreground)
        try check(PhotoPreviewFeedback.presentation(state: .loading, item: cloud, isOffline: false, original: t, needsLogin: false)?.title == "正在下载", "云端真实下载保留清晰反馈")
        let ready = CloudTransferSnapshot(itemID: cloud.id, name: cloud.name, purpose: .original, state: .ready, receivedBytes: 100, totalBytes: 100, isOriginalCached: true, updatedAt: Date(), priority: .foreground)
        try check(PhotoPreviewFeedback.presentation(state: .loading, item: cloud, isOffline: false, original: ready, needsLogin: false) == nil, "已缓存的原图本机读取不闪加载提示")
        let small = Thumbnail(image: bitmap(90, 60), isProviderPreview: true)
        try check(small.shouldObscure(for: cloud) && !small.shouldObscure(for: local), "低清网盘封面刻意模糊，本地保持清晰")
        try check(!Thumbnail(image: bitmap(90, 60)).shouldObscure(for: cloud), "小尺寸原图派生预览不被误当成低清封面")
        try check(!Thumbnail(image: bitmap(1200, 800), isProviderPreview: true).shouldObscure(for: cloud), "清晰云端封面不额外模糊")
        let pattern = checkerboard()
        let softened = await Task.detached { ThumbnailService.softenProviderPreview(pattern) }.value
        try check(softened.width == pattern.width && softened.height == pattern.height && contrast(softened) < contrast(pattern) * 0.25,
                  "低清封面在后台变为高度模糊图，不扩大位图或改变布局比例")
        let detailed = cgBitmap(1200, 800)
        try check(ThumbnailService.softenProviderPreview(detailed) === detailed, "清晰封面直接复用，不生成模糊副本")
    }
    static func wheel() throws {
        var gate = ViewerWheelGate()
        try check(gate.consume(delta: -1, precise: false, phase: [], momentum: [], timestamp: 1) == 1, "鼠标向下滚轮切下一项")
        try check(gate.consume(delta: -1, precise: false, phase: [], momentum: [], timestamp: 1.05) == nil, "滚轮突发事件限频")
        try check(gate.consume(delta: 1, precise: false, phase: [], momentum: [], timestamp: 1.3) == -1, "鼠标反向切上一项")
        gate = ViewerWheelGate()
        try check(gate.consume(delta: -12, precise: true, phase: .began, momentum: [], timestamp: 2) == nil, "触控板轻微位移不误切")
        _ = gate.consume(delta: -12, precise: true, phase: .changed, momentum: [], timestamp: 2.03)
        try check(gate.consume(delta: -14, precise: true, phase: .changed, momentum: [], timestamp: 2.06) == 1, "触控板累计位移后切换一次")
        try check(gate.consume(delta: -90, precise: true, phase: .changed, momentum: [], timestamp: 2.4) == nil, "同一长手势不连续跳图")
        try check(gate.consume(delta: -90, precise: true, phase: [], momentum: .changed, timestamp: 2.5) == nil, "惯性不跳过其他照片")
        _ = gate.consume(delta: 0, precise: true, phase: .ended, momentum: [], timestamp: 2.55)
        try check(gate.consume(delta: 40, precise: true, phase: .began, momentum: [], timestamp: 2.8) == -1, "新手势可以反向切换")
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = PhotoScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let wheel = ViewerWheelView(frame: canvas.bounds)
        window.contentView = NSView(frame: canvas.bounds); window.contentView?.addSubview(canvas); window.contentView?.addSubview(wheel)
        var calls = 0; wheel.onStep = { _ in calls += 1 }
        let event = WheelEvent(host: window, command: false, time: 10)
        try check(wheel.handle(event) && calls == 1, "真实查看器区域拦截滚轮事件")
        let command = WheelEvent(host: window, command: true, time: 11)
        try check(!wheel.handle(command), "Command滚轮保留照片缩放")
        wheel.tearDown(); window.close()
    }
    static func mountedViewer(_ root: URL) async throws {
        let store = AppStore(directory: root.appendingPathComponent("mounted"))
        store.libraries = [MediaLibrary(url: root.appendingPathComponent("photos"))]
        store.refreshLocalLibraries(); try await wait { !store.isScanning }
        let item = try require(store.visibleItems.first, "缺少已挂载查看器夹具")
        store.open(item)
        let host = NSHostingView(rootView: ViewerView(store: store))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 720), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.alphaValue = 0; window.orderBack(nil)
        defer { window.close() }
        func find<T: NSView>(_ view: NSView, _ type: T.Type) -> T? {
            if let match = view as? T { return match }
            for child in view.subviews { if let match = find(child, type) { return match } }
            return nil
        }
        try await wait { host.layoutSubtreeIfNeeded(); return find(host, ViewerWheelView.self)?.bounds.width ?? 0 > 400 }
        let wheel = try require(find(host, ViewerWheelView.self), "查看器未安装滚轮桥")
        try check(wheel.bounds.width > 400 && wheel.bounds.height > 300, "真实SwiftUI查看器的滚轮桥覆盖媒体区而不是零尺寸")
        let point = wheel.convert(NSPoint(x: wheel.bounds.midX, y: wheel.bounds.midY), to: nil)
        let event = WheelEvent(host: window, command: false, time: 20, point: point)
        let previous = store.previewID
        try check(wheel.handle(event) && store.previewID != previous, "挂载后的真实查看器用滚轮前进，照片画布不截留事件")
        await store.waitForFileOperations()
    }
    static func contextMenu(_ root: URL) throws {
        let store = AppStore(directory: root.appendingPathComponent("menus"))
        let item = MediaItem(url: root.appendingPathComponent("context.jpg"), kind: .image, fileSize: 1, modifiedDate: .distantPast, createdDate: .distantPast)
        let homepage = MediaMenus.make(store: store, items: [item]).items.map(\.title)
        let viewer = MediaMenus.make(store: store, items: [item], includeOpen: false)
        try check(Array(homepage.dropFirst()) == viewer.items.map(\.title), "查看器右键复用主页菜单，仅省略重复打开")
        let canvas = PhotoScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400)); canvas.onContextMenu = { viewer }
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        try check(canvas.menu(for: event) === viewer && canvas.documentView?.menu(for: event) === viewer, "画布及图片内容均提供相同右键菜单")
        canvas.tearDown()
    }
    static func checkerboard() -> CGImage {
        let c = CGContext(data: nil, width: 90, height: 60, bitsPerComponent: 8, bytesPerRow: 360, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for y in 0..<30 { for x in 0..<45 {
            let v: CGFloat = (x + y).isMultiple(of: 2) ? 1 : 0
            c.setFillColor(CGColor(gray: v, alpha: 1)); c.fill(CGRect(x: x * 2, y: y * 2, width: 2, height: 2))
        } }
        return c.makeImage()!
    }
    static func contrast(_ image: CGImage) -> Double {
        let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let p = c.data!.assumingMemoryBound(to: UInt8.self)
        var total = 0
        for y in 0..<image.height { for x in 1..<image.width { let i = (y * image.width + x) * 4; total += abs(Int(p[i]) - Int(p[i - 4])) } }
        return Double(total) / Double(image.width * image.height)
    }
    static func bitmap(_ w: Int, _ h: Int) -> NSImage { NSImage(cgImage: cgBitmap(w, h), size: NSSize(width: w, height: h)) }
    static func cgBitmap(_ w: Int, _ h: Int) -> CGImage {
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.3, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(CGColor(red: 0.1, green: 0.8, blue: 0.3, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: w / 3, height: h / 2))
        return context.makeImage()!
    }
    static func makePhoto(_ url: URL, type: UTType, orientation: Int, frames: Int = 1) throws {
        let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames, nil)!
        for _ in 0..<frames { CGImageDestinationAddImage(d, cgBitmap(120,80), [kCGImagePropertyOrientation: orientation, kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "KeepCamera"], kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2023:01:02 03:04:05"]] as CFDictionary) }
        guard CGImageDestinationFinalize(d) else { throw Failure("生成测试图片失败") }
    }
    static func properties(_ url: URL) throws -> [CFString: Any] {
        guard let s = CGImageSourceCreateWithURL(url as CFURL,nil), let p = CGImageSourceCopyPropertiesAtIndex(s,0,nil) as? [CFString:Any] else { throw Failure("无元数据") }; return p
    }
    static func decodedPixels(_ url: URL) throws -> Data {
        let s = CGImageSourceCreateWithURL(url as CFURL,nil)!, image = CGImageSourceCreateImageAtIndex(s,0,nil)!
        let c = CGContext(data: nil, width: image.width,height: image.height,bitsPerComponent:8,bytesPerRow: image.width * 4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        c.draw(image,in: CGRect(x:0,y:0,width:image.width,height:image.height)); return Data(bytes: c.data!,count: image.width * image.height * 4)
    }
    static func fileItem(_ url: URL) throws -> MediaItem {
        let v = try URL(fileURLWithPath:url.path).resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey,.creationDateKey])
        return MediaItem(url:url,kind:.image,fileSize:Int64(v.fileSize ?? 0),modifiedDate:v.contentModificationDate!,createdDate:v.creationDate!,capturedDate:Date(timeIntervalSince1970:1672628645),pixelWidth:120,pixelHeight:80)
    }
    static func check(_ value: Bool, _ message: String) throws { guard value else { throw Failure(message) }; passed += 1; print("✓ \(message)") }
    static func require<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw Failure(message) }; return value }
    static func wait(_ condition: () async -> Bool) async throws { for _ in 0..<300 { if await condition() { return }; try await Task.sleep(for:.milliseconds(20)) }; throw Failure("等待超时") }
    struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
    actor Remote {
        var counts: [String:Int] = [:]
        var hold = false
        func setHold(_ value: Bool) { hold = value }
        func count(_ id: String) -> Int { counts[id,default:0] }
        func list(_ id: String, _ path: String) async throws -> CloudDirectoryPage {
            counts[id,default:0] += 1
            while hold { try await Task.sleep(for: .milliseconds(5)) }
            return .init(entries:[],folderID:id,path:path,credential:nil)
        }
    }
}

@MainActor private final class WheelEvent: NSEvent {
    private let host: NSWindow
    private let command: Bool
    private let time: TimeInterval
    private let point: NSPoint
    init(host: NSWindow, command: Bool, time: TimeInterval, point: NSPoint = NSPoint(x: 300, y: 200)) { self.host = host; self.command = command; self.time = time; self.point = point; super.init() }
    required init?(coder: NSCoder) { fatalError("unused") }
    override var window: NSWindow? { host }
    override var locationInWindow: NSPoint { point }
    override var modifierFlags: NSEvent.ModifierFlags { command ? .command : [] }
    override var scrollingDeltaY: CGFloat { -2 }
    override var scrollingDeltaX: CGFloat { 0 }
    override var timestamp: TimeInterval { time }
    override var hasPreciseScrollingDeltas: Bool { false }
    override var phase: NSEvent.Phase { [] }
    override var momentumPhase: NSEvent.Phase { [] }
}
