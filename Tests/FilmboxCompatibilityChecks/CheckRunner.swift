import AppKit
@preconcurrency import AVFoundation
import CryptoKit
import Darwin
import FilmboxCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Runs the production decoder/cache/metadata services and production HTTP
/// transport against checked-in generated media in a private temporary tree.
@main
@MainActor
struct CompatibilityCheckRunner {
    static func main() async {
        let fixture: CompatibilityFixture
        do { fixture = try CompatibilityFixture.make() }
        catch { print("✗ 无法创建兼容性夹具：\(error)"); exit(EXIT_FAILURE) }
        defer { fixture.remove() }
        let checks: [(String, (CompatibilityFixture) async throws -> Void)] = [
            ("内置工具定位与无封面 VP9/Opus 元数据", runtimeMetadata),
            ("真实 VP9 取帧和详情元数据兜底", realVideoPreview),
            ("同名封面优先，不等待阻塞视频", sidecarPriority),
            ("WebM 缓存损坏重建、服务重启与源离线复用", cacheRebuildAndOffline),
            ("失败请求不留空缓存，原路径同请求可恢复", failedRequestRecovers),
            ("损坏输入及时失败，阻塞后端可取消并恢复", backendFailureAndCancellation),
            ("旧目录缓存 nil 视频元数据可以补全", scannerRepairsOldMetadata),
            ("取消旧缓存升级后再次刷新仍可补全元数据", cancelledScannerRepairCanRetry),
            ("系统 H.264 路径仍可解码与读取详情", nativeH264RemainsPlayable),
            ("本机媒体 GET/HEAD/前缀/后缀/开放 Range", httpMediaRanges),
            ("无效 Range/任意路径/非 GET 方法被拒绝", httpRejectsInvalidRequests),
            ("同源播放器页面、独立租约与幂等撤销", httpPlayerAndRevocation)
        ]
        var failures = 0
        for (name, check) in checks {
            do { try await check(fixture); print("✓ \(name)") }
            catch { failures += 1; print("✗ \(name)：\(error)") }
        }
        print("\(checks.count - failures)/\(checks.count) 格式兼容检查通过")
        if failures > 0 { exit(EXIT_FAILURE) }
    }

    private static func runtimeMetadata(_ fixture: CompatibilityFixture) async throws {
        try expect(MediaCodecRuntime.isAvailable, "App 自带的两个解码工具必须可用")
        try expect(MediaCodecRuntime.executable("sh") == nil, "工具定位器不能执行任意工具")
        for name in ["ffmpeg", "ffprobe"] {
            let url = try require(MediaCodecRuntime.executable(name))
            try expect(!url.path.hasPrefix("/opt/homebrew/"), "不能依赖用户安装的 Homebrew")
        }
        let metadata = try require(await MediaCodecRuntime.videoMetadata(at: fixture.vp9))
        try expect(metadata.width == 320 && metadata.height == 180, "VP9 原生后端应返回真实画幅")
        try expect(metadata.codec == "vp9", "后端应识别 VP9 视频流")
        let duration = try require(metadata.duration)
        try expect(duration > 1.1 && duration < 1.4, "VP9/Opus 容器时长应为约1.2秒")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: fixture.vp9.deletingLastPathComponent().path)
        try expect(siblings == [fixture.vp9.lastPathComponent], "VP9 取帧夹具必须没有同名封面")
        let native = (try? await AVURLAsset(url: fixture.vp9).load(.isPlayable)) ?? false
        try expect(!native, "夹具必须实际覆盖当前系统 AVFoundation 不可播的输入")
    }

    private static func realVideoPreview(_ fixture: CompatibilityFixture) async throws {
        let bytes = try require(await MediaCodecRuntime.previewData(at: fixture.vp9, pixelSize: 192))
        let source = try require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let frame = try require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        try expect(frame.width == 192 && frame.height == 108, "后端必须返回视频实际像素")
        try expect(colorVariation(frame) > 0.05, "帧必须是测试图像，不能是空白或格式图标")
        let integrated = try require(await ThumbnailDecoder.decode(url: fixture.vp9, kind: .video, pixelSize: 192))
        try expect(integrated.width == 192 && integrated.height == 108, "生产缩略解码链应接入备用解码器")
        let details = try require(await DetailsService().videoDetails(url: fixture.vp9))
        try expect(details.width == 320 && details.height == 180 && details.codec == "vp9", "详情应显示真实VP9信息")
        try expect(details.duration > 1.1 && details.duration < 1.4, "详情时长应使用备用元数据")
    }

    private static func sidecarPriority(_ fixture: CompatibilityFixture) async throws {
        let directory = try fixture.directory("sidecar")
        let blocked = directory.appendingPathComponent("clip.webm")
        try makeFIFO(at: blocked)
        try writeSolidJPEG(at: directory.appendingPathComponent("clip.jpg"))
        let start = ProcessInfo.processInfo.systemUptime
        let frame = try require(await ThumbnailDecoder.decode(url: blocked, kind: .video, pixelSize: 192))
        try expect(ProcessInfo.processInfo.systemUptime - start < 1.5, "封面应在打开阻塞的视频前返回")
        let color = try sampleColor(frame)
        try expect(color.redComponent > max(color.greenComponent, color.blueComponent) + 0.5,
                   "应优先显示同名红色封面")
    }

    private static func cacheRebuildAndOffline(_ fixture: CompatibilityFixture) async throws {
        let source = try fixture.copyVP9("cache-source")
        let cache = try fixture.directory("cache-data")
        let first = ThumbnailService(cacheDirectory: cache)
        _ = try require(await first.thumbnail(for: source, kind: .video, modifiedDate: fixture.date, pixelSize: 640))
        let files = try cacheFiles(cache)
        try expect(files.count == 1, "成功VP9预览必须持久化为一个缓存项")
        try Data("corrupt-cache".utf8).write(to: try require(files.first), options: .atomic)
        let rebuilt = ThumbnailService(cacheDirectory: cache)
        let thumbnail = try require(await rebuilt.thumbnail(for: source, kind: .video, modifiedDate: fixture.date, pixelSize: 768))
        try expect(try longestSide(thumbnail) == 768, "损坏缓存应由可读WebM恢复真实768档预览")
        let moved = source.appendingPathExtension("offline")
        try FileManager.default.moveItem(at: source, to: moved)
        defer { try? FileManager.default.moveItem(at: moved, to: source) }
        let restarted = ThumbnailService(cacheDirectory: cache)
        let offline = try require(await restarted.thumbnail(for: source, kind: .video, modifiedDate: fixture.date, pixelSize: 768))
        try expect(try longestSide(offline) == 768, "服务重启和源文件离线后应保留缓存画面")
        _ = try require(await restarted.cachedThumbnail(for: source, kind: .video, modifiedDate: fixture.date, pixelSize: 640))
    }

    private static func failedRequestRecovers(_ fixture: CompatibilityFixture) async throws {
        let directory = try fixture.directory("retry-source")
        let source = directory.appendingPathComponent("same.webm")
        try Data("invalid-webm".utf8).write(to: source)
        let cache = try fixture.directory("retry-cache")
        let service = ThumbnailService(cacheDirectory: cache)
        let failed = await service.thumbnail(for: source, kind: .video, modifiedDate: fixture.date, pixelSize: 768)
        try expect(failed == nil && (try cacheFiles(cache)).isEmpty, "失败不能留下空白磁盘预览")
        try fixture.vp9Data.write(to: source, options: .atomic)
        // Identical URL, supplied revision and size request. Recovery must not
        // depend on an app restart or an unrelated new cache key.
        let recovered = try require(await service.thumbnail(for: source, kind: .video, modifiedDate: fixture.date, pixelSize: 768))
        try expect(try longestSide(recovered) == 768, "同请求在视频恢复后应成功")
    }

    private static func backendFailureAndCancellation(_ fixture: CompatibilityFixture) async throws {
        let directory = try fixture.directory("backend-failure")
        let corrupt = directory.appendingPathComponent("broken.webm")
        try Data([0x1a, 0x45, 0xdf, 0xa3, 0, 0, 0]).write(to: corrupt)
        let start = ProcessInfo.processInfo.systemUptime
        let metadata = await MediaCodecRuntime.videoMetadata(at: corrupt)
        let preview = await MediaCodecRuntime.previewData(at: corrupt, pixelSize: 192)
        try expect(metadata == nil && preview == nil, "损坏输入应返回失败而非伪造结果")
        try expect(ProcessInfo.processInfo.systemUptime - start < 3, "小型损坏输入应及时失败")
        let blocked = directory.appendingPathComponent("blocked.webm")
        try makeFIFO(at: blocked)
        let probe = Task.detached { await MediaCodecRuntime.videoMetadata(at: blocked) }
        let decode = Task.detached { await MediaCodecRuntime.previewData(at: blocked, pixelSize: 192) }
        try await Task.sleep(for: .milliseconds(150))
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        probe.cancel(); decode.cancel()
        let stoppedMetadata = await probe.value
        let stoppedPreview = await decode.value
        try expect(stoppedMetadata == nil && stoppedPreview == nil, "被取消后端不能返回成功")
        try expect(ProcessInfo.processInfo.systemUptime - cancelledAt < 1.5, "取消应立即释放等待者，不等待8/12秒超时")
        _ = try require(await MediaCodecRuntime.videoMetadata(at: fixture.vp9))
        _ = try require(await MediaCodecRuntime.previewData(at: fixture.vp9, pixelSize: 192))
    }

    private static func scannerRepairsOldMetadata(_ fixture: CompatibilityFixture) async throws {
        let source = try fixture.copyVP9("scanner-old-cache")
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
        let modified = try require(values.contentModificationDate)
        let created = values.creationDate ?? modified
        let old = MediaItem(url: source, kind: .video, fileSize: Int64(try require(values.fileSize)),
                            modifiedDate: modified, createdDate: created)
        let scanner = MediaScanner()
        await scanner.seed(cachedItems: [old])
        let library = MediaLibrary(url: source.deletingLastPathComponent())
        let scan = await scanner.scan(libraries: [library])
        let repaired = try require(scan.items.first)
        try expect(scan.items.count == 1 && repaired.url == source, "WebM应被扫描为一条视频")
        try expect(repaired.pixelWidth == 320 && repaired.pixelHeight == 180, "同文件版本的旧nil画幅必须补全")
        try expect((repaired.duration ?? 0) > 1.1, "同文件版本的旧nil时长必须补全")
        let repeatScan = await scanner.scan(libraries: [library])
        try expect(repeatScan.items.first == repaired, "补全后的元数据应可稳定复用")
    }

    private static func nativeH264RemainsPlayable(_ fixture: CompatibilityFixture) async throws {
        let asset = AVURLAsset(url: fixture.h264)
        let playable = try await asset.load(.isPlayable)
        try expect(playable, "系统H.264路径应仍可播放")
        let frame = try require(await ThumbnailDecoder.decode(url: fixture.h264, kind: .video, pixelSize: 192))
        try expect(frame.width > 0 && frame.height > 0, "系统H.264取帧不能回退为空")
        let details = try require(await DetailsService().videoDetails(url: fixture.h264))
        try expect(details.width == 128 && details.height == 86, "系统H.264详情尺寸必须保留")
        try expect(details.codec == "avc1", "可直接读取的H.264应保留AVFoundation codec信息")
    }

    private static func httpMediaRanges(_ fixture: CompatibilityFixture) async throws {
        let server = LocalMediaServer()
        let lease = try await server.open(fixture.vp9)
        defer { lease.release() }
        try expect(lease.originURL.host == "127.0.0.1" && lease.url.scheme == "http", "媒体只能通过本机回环地址提供")
        let full = try await request(lease.url)
        try expect(full.response.statusCode == 200 && full.data == fixture.vp9Data, "GET必须逐字节返回原视频")
        try expect(full.response.value(forHTTPHeaderField: "Content-Type") == "video/webm", "WebM MIME应正确")
        try expect(full.response.value(forHTTPHeaderField: "Accept-Ranges") == "bytes", "应声明字节范围")
        try expect(full.response.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == nil, "不能向任意网页开放CORS")
        try expect(full.response.value(forHTTPHeaderField: "Cross-Origin-Resource-Policy") == "same-origin", "媒体只能同源引用")
        let head = try await request(lease.url, method: "HEAD")
        try expect(head.response.statusCode == 200 && head.data.isEmpty, "HEAD不能发送视频body")
        try expect(head.response.value(forHTTPHeaderField: "Content-Length") == String(fixture.vp9Data.count), "HEAD必须给出原文件总长")
        let rangeHead = try await request(lease.url, method: "HEAD", range: "bytes=0-31")
        try expect(rangeHead.response.statusCode == 206 && rangeHead.data.isEmpty, "带范围的HEAD也不能发送body")
        try expect(rangeHead.response.value(forHTTPHeaderField: "Content-Length") == "32", "范围HEAD必须声明对应长度")
        for (range, expected, contentRange) in [
            ("bytes=0-31", Data(fixture.vp9Data.prefix(32)), "bytes 0-31/\(fixture.vp9Data.count)"),
            ("bytes=-19", Data(fixture.vp9Data.suffix(19)), "bytes \(fixture.vp9Data.count - 19)-\(fixture.vp9Data.count - 1)/\(fixture.vp9Data.count)"),
            ("bytes=\(fixture.vp9Data.count - 19)-", Data(fixture.vp9Data.suffix(19)), "bytes \(fixture.vp9Data.count - 19)-\(fixture.vp9Data.count - 1)/\(fixture.vp9Data.count)")
        ] {
            let part = try await request(lease.url, range: range)
            try expect(part.response.statusCode == 206 && part.data == expected, "Range \(range)必须返回准确字节")
            try expect(part.response.value(forHTTPHeaderField: "Content-Range") == contentRange, "Range响应边界必须准确")
        }
    }

    private static func httpRejectsInvalidRequests(_ fixture: CompatibilityFixture) async throws {
        let server = LocalMediaServer()
        let lease = try await server.open(fixture.vp9)
        defer { lease.release() }
        for range in ["bytes=\(fixture.vp9Data.count)-", "bytes=-0", "bytes=4-2", "bytes=0-2,5-7"] {
            let response = try await request(lease.url, range: range)
            try expect(response.response.statusCode == 416 && response.data.isEmpty, "无效范围必须416：\(range)")
            try expect(response.response.value(forHTTPHeaderField: "Content-Range") == "bytes */\(fixture.vp9Data.count)", "416必须给出资源总长")
        }
        let arbitrary = lease.originURL.appendingPathComponent("unregistered/path")
        let unknown = try await request(arbitrary)
        try expect(unknown.response.statusCode == 404, "不能按任意URL路径读取本机文件")
        var components = try require(URLComponents(url: lease.url, resolvingAgainstBaseURL: false))
        components.query = "unexpected=1"
        let query = try await request(try require(components.url))
        try expect(query.response.statusCode == 404, "不能用任意查询参数绕过精确租约路由")
        let post = try await request(lease.url, method: "POST")
        try expect(post.response.statusCode == 405, "服务不能接受写入方法")
        let wrongHost = try await request(lease.url, headers: ["Host": "untrusted.invalid"])
        try expect(wrongHost.response.statusCode == 403, "不匹配的Host不能访问本机资源")
        do { _ = try await server.open(fixture.root); throw CompatibilityFailure("不能给目录建立媒体租约") }
        catch is LocalMediaServerError { }
        do { _ = try await server.open(URL(string: "https://example.invalid/video.webm")!); throw CompatibilityFailure("不能给外部URL建立媒体租约") }
        catch is LocalMediaServerError { }
    }

    private static func httpPlayerAndRevocation(_ fixture: CompatibilityFixture) async throws {
        let server = LocalMediaServer()
        let first = try await server.open(fixture.vp9)
        let second = try await server.open(fixture.vp9)
        defer { first.release(); second.release() }
        try expect(first.url != second.url, "每个租约应获得独立随机路由")
        let html = "<!doctype html><meta charset=utf-8><title>Generated player test</title>"
        await server.setPlayerHTML(html, for: first)
        let page = try await request(first.playerURL)
        try expect(page.response.statusCode == 200 && page.data == Data(html.utf8), "播放器页面必须通过同源租约提供")
        try expect(first.playerURL.host == first.url.host && first.playerURL.port == first.url.port, "页面与媒体必须同源")
        first.release(); first.release()
        var revoked = false
        for _ in 0..<30 {
            if try await request(first.url).response.statusCode == 404 { revoked = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try expect(revoked, "释放租约后原媒体URL必须失效")
        let pageAfter = try await request(first.playerURL)
        try expect(pageAfter.response.statusCode == 404, "释放租约后原播放器URL必须失效")
        let survivor = try await request(second.url, range: "bytes=0-7")
        try expect(survivor.response.statusCode == 206 && survivor.data == Data(fixture.vp9Data.prefix(8)), "撤销一个租约不能影响另一个")
    }

    private static func cancelledScannerRepairCanRetry(_ fixture: CompatibilityFixture) async throws {
        let source = try fixture.copyVP9("scanner-cancelled-repair")
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
        let modified = try require(values.contentModificationDate)
        let old = MediaItem(url: source, kind: .video, fileSize: Int64(try require(values.fileSize)),
                            modifiedDate: modified, createdDate: values.creationDate ?? modified)
        let library = MediaLibrary(url: source.deletingLastPathComponent())
        // Exercise cancellation both before work begins and around the native
        // metadata/probe handoff. Every subsequent completed refresh must still
        // repair the same unchanged, previously persisted nil record.
        for delay in [0, 1, 2, 5, 10] {
            let scanner = MediaScanner()
            await scanner.seed(cachedItems: [old])
            let interrupted = Task.detached { await scanner.scan(libraries: [library]) }
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            interrupted.cancel()
            _ = await interrupted.value
            let retry = await scanner.scan(libraries: [library])
            let repaired = try require(retry.items.first)
            try expect(repaired.pixelWidth == 320 && repaired.pixelHeight == 180 && (repaired.duration ?? 0) > 1.1,
                       "取消\(delay)ms处的旧缓存升级后，同版本下一次刷新必须可修复")
        }
    }
}

private struct CompatibilityFixture {
    let root: URL
    let vp9: URL
    let h264: URL
    let vp9Data: Data
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    static func make() throws -> CompatibilityFixture {
        let supplied = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/Fixtures"
        let inputs = URL(fileURLWithPath: supplied, isDirectory: true)
        let vp9Bytes = try Data(contentsOf: inputs.appendingPathComponent("vp9-opus.webm"))
        let h264Bytes = try Data(contentsOf: inputs.appendingPathComponent("h264-aac.mp4"))
        try expect(digest(vp9Bytes) == "fd69311d8675c40c4866fdb77495521d3d050a8bb00c0cfa2084323e4ce5e9ae", "生成WebM夹具校验失败")
        try expect(digest(h264Bytes) == "9a6b7299329f6a46c65c4997143d36d51ee63c574ef39857d5c8d83664ba7441", "生成MP4夹具校验失败")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FilmboxCompatibilityChecks-" + UUID().uuidString, isDirectory: true)
        let vp9Directory = root.appendingPathComponent("NoPoster", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: vp9Directory, withIntermediateDirectories: true)
            let vp9 = vp9Directory.appendingPathComponent("generated.webm")
            let h264 = root.appendingPathComponent("generated-native.mp4")
            try vp9Bytes.write(to: vp9)
            try h264Bytes.write(to: h264)
            return CompatibilityFixture(root: root, vp9: vp9, h264: h264, vp9Data: vp9Bytes)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func directory(_ name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    func copyVP9(_ name: String) throws -> URL {
        let copy = try directory(name).appendingPathComponent("generated.webm")
        try vp9Data.write(to: copy)
        return copy
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private struct HTTPResult { let data: Data; let response: HTTPURLResponse }
private func request(_ url: URL, method: String = "GET", range: String? = nil, headers: [String: String] = [:]) async throws -> HTTPResult {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 3
    configuration.timeoutIntervalForResource = 5
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.httpMethod = method
    if let range { request.setValue(range, forHTTPHeaderField: "Range") }
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    let (data, response) = try await session.data(for: request)
    return HTTPResult(data: data, response: try require(response as? HTTPURLResponse))
}

private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func makeFIFO(at url: URL) throws {
    try expect(url.path.withCString { mkfifo($0, mode_t(0o600)) } == 0, "无法创建私有阻塞输入夹具")
}
private func writeSolidJPEG(at url: URL) throws {
    let context = try require(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.95, green: 0.03, blue: 0.02, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
    let image = try require(context.makeImage())
    let destination = try require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try expect(CGImageDestinationFinalize(destination), "无法创建同名封面夹具")
}
@MainActor private func longestSide(_ thumbnail: Thumbnail) throws -> Int {
    let image = try require(thumbnail.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    return max(image.width, image.height)
}
@MainActor private func sampleColor(_ image: CGImage) throws -> NSColor {
    try require(NSBitmapImageRep(cgImage: image).colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.deviceRGB))
}
@MainActor private func colorVariation(_ image: CGImage) -> Double {
    let pixels = NSBitmapImageRep(cgImage: image)
    let colors = [image.width / 4, image.width / 2, image.width * 3 / 4].compactMap {
        pixels.colorAt(x: $0, y: image.height / 3)?.usingColorSpace(.deviceRGB)
    }
    let values = colors.flatMap { [Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent)] }
    return (values.max() ?? 0) - (values.min() ?? 0)
}
private func cacheFiles(_ directory: URL) throws -> [URL] {
    let urls = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])?.allObjects as? [URL] ?? []
    return urls.filter { $0.pathExtension == "thumb" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
}
private struct CompatibilityFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
private func expect(_ condition: @autoclosure () throws -> Bool, _ reason: String, file: StaticString = #filePath, line: UInt = #line) throws {
    guard try condition() else { throw CompatibilityFailure("\(reason)（\(file):\(line)）") }
}
private func require<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { throw CompatibilityFailure("缺少必要结果（\(file):\(line)）") }
    return value
}
