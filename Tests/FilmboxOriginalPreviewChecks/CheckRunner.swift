import AppKit
import SwiftUI
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
import FilmboxCore

@MainActor private final class PreviewEvents {
    var ids: [String] = []
}

@main @MainActor private enum OriginalPreviewChecks {
    struct Failure: Error { let message: String }
    static var assertions = 0
    static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }; assertions += 1
    }
    static func main() async {
        _ = NSApplication.shared
        do { try await run() } catch { print("FAIL: \(error)"); exit(1) }
    }
    static func run() async throws {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "FilmboxDevelopmentCache") as? String,
              path.contains("filmbox-original-preview."), URL(fileURLWithPath: path).lastPathComponent == "isolated-cache" else {
            throw Failure(message: "requires an isolated cache")
        }
        let root = URL(fileURLWithPath: path), fixture = root.deletingLastPathComponent()
        let date = Date(timeIntervalSince1970: 1_700_000_000), account = UUID()
        let original = imageData(width: 3600, height: 2400, color: .init(red: 0.08, green: 0.18, blue: 0.9, alpha: 1))
        let redCover = imageData(width: 90, height: 60, color: .init(red: 0.9, green: 0.08, blue: 0.08, alpha: 1))
        let photo = media(account: account, name: "photo.png", revision: "r1", kind: .image, bytes: original.count, date: date)
        let service = ThumbnailService.shared
        CloudMediaRegistry.shared.register([photo])
        try write(redCover, to: rawPath(root, photo, purpose: "thumbnail"))
        CloudTransferCenter.shared.requireLogin(accountID: account)
        defer { CloudTransferCenter.shared.forgetConnection(accountID: account) }
        guard case .ready(let low) = await service.loadThumbnail(for: photo.url, kind: .image, modifiedDate: date, pixelSize: 768) else {
            throw Failure(message: "initial provider cover failed offline")
        }
        try expect(width(low) == 90 && low.isProviderPreview, "fixture must put the low-resolution cover in the memory cache first")
        let host = NSHostingView(rootView: AsyncThumbnail(item: photo, pixelSize: 768, contentMode: .fit).frame(width: 240, height: 160))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 240, height: 160),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.contentView = host; window.orderBack(nil)
        defer { window.close() }
        try await eventually("actual visible thumbnail did not begin with its red provider cover") {
            host.layoutSubtreeIfNeeded(); return centerColor(host).map { $0.redComponent > $0.blueComponent + 0.3 } ?? false
        }
        let events = PreviewEvents()
        let observer = NotificationCenter.default.addObserver(forName: .filmboxCloudOriginalPreviewReady, object: nil, queue: .main) { note in
            guard let id = note.userInfo?["id"] as? String else { return }
            Task { @MainActor in events.ids.append(id) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let originalURL = rawPath(root, photo, purpose: "original")
        try write(original, to: originalURL)
        let cachedFile = try await MediaAssetResolver.shared.originalFile(for: photo)
        try expect(cachedFile == originalURL || cachedFile.resolvingSymlinksInPath() == originalURL.resolvingSymlinksInPath(),
            "existing originals must be reused without login or download")
        try await eventually("download completion did not upgrade the on-screen thumbnail without reappearing", seconds: 15) {
            host.layoutSubtreeIfNeeded(); return centerColor(host).map { $0.blueComponent > $0.redComponent + 0.3 } ?? false
        }
        let upgraded = await service.thumbnail(for: photo.url, kind: .image, modifiedDate: date, pixelSize: 768)
        try expect(upgraded.map { width($0) == 768 && !$0.isProviderPreview } == true, "old 90-pixel cover memory must not win after original availability")
        try expect(events.ids.contains(photo.id), "background original poster must notify only its own item")
        let roll = await service.thumbnail(for: photo.url, kind: .image, modifiedDate: date, pixelSize: 1600)
        try expect(roll.map { width($0) == 1600 } == true, "unfocused roll-size image must retain original-derived detail")
        try expect((await service.cacheSizes())[.highResolution, default: 0] > 0, "derived previews belong to managed high-resolution cache")
        window.close()
        print("✓ 小封面已在内存与实际画面中，原件就绪后自动升级为高清，离焦卷轴不降回封面")

        try FileManager.default.removeItem(at: originalURL)
        _ = await MediaAssetResolver.shared.inspectCache(for: photo)
        let restarted = ThumbnailService(cacheDirectory: root.appendingPathComponent("thumbs"))
        let afterRestart = await restarted.cachedThumbnail(for: photo.url, kind: .image, modifiedDate: date, pixelSize: 1600)
        try expect(afterRestart.map { width($0) == 1600 } == true, "new service must restore a high-quality poster even without the original or login")
        try expect(await MediaAssetResolver.shared.cachedOriginalIDs(for: [photo]).isEmpty, "poster cannot count as an original")
        await restarted.clearCache(categories: [.cloud])
        let retained = await restarted.cachedThumbnail(for: photo.url, kind: .image, modifiedDate: date, pixelSize: 1600)
        try expect(retained.map { width($0) == 1600 } == true, "clearing ordinary cloud covers must retain the independent HD category")
        print("✓ 磁盘高清预览可跨实例恢复，原件移除和退出登录不影响它，下载状态仍准确")

        let legacy = media(account: account, name: "legacy.png", revision: "old", kind: .image, bytes: original.count, date: date)
        CloudMediaRegistry.shared.register([legacy])
        try write(redCover, to: rawPath(root, legacy, purpose: "thumbnail"))
        _ = await service.thumbnail(for: legacy.url, kind: .image, modifiedDate: date, pixelSize: 768)
        let identity = "cloud-original-v2\u{0}\(legacy.id)|old\u{0}\(date.timeIntervalSince1970.bitPattern)\u{0}4096"
        let verifiedKey = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        try write(original, to: root.appendingPathComponent("thumbs/highResolution").appendingPathComponent(verifiedKey).appendingPathExtension("thumb"))
        let migrated = await service.cachedThumbnail(for: legacy.url, kind: .image, modifiedDate: date, pixelSize: 1600)
        try expect(migrated.map { width($0) == 1600 } == true, "previous verified full-size previews must also beat old cover memory without downloading originals again")
        print("✓ 旧版已验证的高清照片缓存同样优先复用")

        let videoData = try Data(contentsOf: fixture.appendingPathComponent("sample.mp4"))
        let video = media(account: account, name: "movie.mp4", revision: "v1", kind: .video, bytes: videoData.count, date: date)
        CloudMediaRegistry.shared.register([video])
        try write(redCover, to: rawPath(root, video, purpose: "thumbnail"))
        let videoLow = await service.thumbnail(for: video.url, kind: .video, modifiedDate: date, pixelSize: 1600)
        try expect(videoLow.map { width($0) == 90 } == true, "video fixture needs an existing low cover")
        let movieURL = rawPath(root, video, purpose: "original")
        try write(videoData, to: movieURL)
        _ = try await MediaAssetResolver.shared.originalFile(for: video)
        guard let videoHigh = await service.thumbnail(for: video.url, kind: .video, modifiedDate: date, pixelSize: 1600) else {
            throw Failure(message: "downloaded movie did not produce a still")
        }
        try expect(width(videoHigh) == 1600 && Int(videoHigh.image.size.height) == 900, "movie must be decoded as video into a sharp correctly proportioned still")
        let decoderFrame = try await ThumbnailDecoder.cloudPreview(item: video, pixelSize: 1600)
        try expect(decoderFrame?.width == 1600, "cached original movie must not go through the JPEG-cover decoder")
        try FileManager.default.removeItem(at: movieURL)
        _ = await MediaAssetResolver.shared.inspectCache(for: video)
        let videoRestarted = await restarted.cachedThumbnail(for: video.url, kind: .video, modifiedDate: date, pixelSize: 1600)
        try expect(videoRestarted.map { width($0) == 1600 } == true, "movie still must persist after the original has left the cache")
        print("✓ 已下载视频生成1600×900高清静帧，重新读取时无需再解码或下载原片")

        let changed = media(account: account, name: "photo.png", revision: "r2", kind: .image, bytes: original.count, date: date)
        CloudMediaRegistry.shared.register([changed])
        try write(imageData(width: 96, height: 64, color: .green), to: rawPath(root, changed, purpose: "thumbnail"))
        let revised = await restarted.thumbnail(for: changed.url, kind: .image, modifiedDate: date, pixelSize: 768)
        try expect(revised.map { width($0) == 96 } == true, "changed remote revision cannot reuse an older HD poster")
        CloudMediaRegistry.shared.register([photo])
        await service.clearCache(categories: [.highResolution])
        let cleared = await service.cachedThumbnail(for: photo.url, kind: .image, modifiedDate: date, pixelSize: 768)
        try expect(cleared.map { width($0) <= 96 } ?? true, "HD cleanup must remove both disk and in-memory original-derived preview")
        try expect((await service.cacheSizes())[.highResolution, default: 0] == 0, "HD cleanup must include movie stills and master previews")
        print("✓ 版本隔离与高清缓存清理正确；全部测试不连接网盘或读取生产缓存")
        print("\(assertions)项原件高清预览检查通过")
    }
    static func media(account: UUID, name: String, revision: String, kind: MediaKind, bytes: Int, date: Date) -> MediaItem {
        MediaItem(cloud: CloudMediaReference(accountID: account, fileID: name, parentID: "/", remotePath: "/" + name, revision: revision),
            kind: kind, fileSize: Int64(bytes), modifiedDate: date, createdDate: date, duration: kind == .video ? 1 : nil)
    }
    static func rawPath(_ root: URL, _ item: MediaItem, purpose: String) -> URL {
        let identity = "\(item.id)|\(item.cloud!.revision)|\(item.fileSize)|\(item.modifiedDate.timeIntervalSinceReferenceDate)|\(purpose)"
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent("cloud-assets")
        return purpose == "original" ? directory.appendingPathComponent(key).appendingPathComponent(item.name)
            : directory.appendingPathComponent(key).appendingPathExtension("preview")
    }
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    static func imageData(width: Int, height: Int, color: NSColor) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(color.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData(), destination = CGImageDestinationCreateWithData( data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil); precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
    static func width(_ thumbnail: Thumbnail) -> Int { Int(thumbnail.image.size.width) }
    static func centerColor(_ view: NSView) -> NSColor? {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB)
    }
    static func eventually(_ message: String, seconds: Double = 8, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }; try await Task.sleep(for: .milliseconds(40))
        }
        throw Failure(message: message)
    }
}
