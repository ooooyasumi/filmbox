import AppKit
@preconcurrency import AVFoundation
import CoreVideo
import CryptoKit
import Darwin
import FilmboxCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Compiles with the application's real media service and decoder. All media
/// and caches belong to a unique temporary directory, never the user's library.
@main
@MainActor
struct MediaCheckRunner {
    static func main() async {
        let fixture: MediaFixture
        do { fixture = try await MediaFixture.make() }
        catch {
            print("✗ 无法创建媒体检查夹具：\(error)")
            exit(EXIT_FAILURE)
        }
        defer { fixture.remove() }

        let checks: [(String, (MediaFixture) async throws -> Void)] = [
            ("合法延迟起点 H.264 / HEVC 的 MP4、MOV 取帧", delayedStartVideos),
            ("256 / 768 / 1600 / 4096 缓存档位与640、768共享", canonicalSizeBands),
            ("旧384预览在线升级、离线继续保留", legacyPreviewUpgradesWhenOnline),
            ("冷缓存查询不生成缩略图", cacheOnlyMissDoesNotDecode),
            ("服务重建及源文件离线后复用磁盘缓存", persistedCacheWorksOffline),
            ("两个并发消费者共享同一缩略图及缓存项", concurrentRequestsShareWork),
            ("取消一个消费者不影响另一个消费者", cancellationDoesNotPoisonSurvivor),
            ("修改时间改变后不复用旧图像", modificationDateInvalidatesCache),
            ("损坏的磁盘缩略图可以自动修复", corruptDiskCacheHeals),
            ("失败结果不持久化，源文件出现后同请求恢复", missingSourceCanRecover),
            ("4096查看图从全尺寸源读取而非内嵌小预览", fullSizePreviewUsesSource),
            ("原件离线时小缓存不冒充高清完成", offlineThumbnailIsNotFullPreview),
            ("旧云端高清小图缓存失效且普通预览保留", legacyCloudCoverIsNotFullPreview),
            ("分级缓存统计及选择清理保留其它预览", classifiedCacheClearing)
        ]
        var failed = 0
        for (name, check) in checks {
            do {
                try await check(fixture)
                print("✓ \(name)")
            } catch {
                failed += 1
                print("✗ \(name)：\(error)")
            }
        }
        await observeCancelledRequestPersistence(fixture)
        print("\(checks.count - failed)/\(checks.count) 媒体检查通过")
        if failed > 0 { exit(EXIT_FAILURE) }
    }

    private static func delayedStartVideos(_ fixture: MediaFixture) async throws {
        let service = ThumbnailService(cacheDirectory: try fixture.cache("delayed"))
        for url in fixture.videos {
            let asset = AVURLAsset(url: url)
            let track = try require(try await asset.loadTracks(withMediaType: .video).first)
            let segments = try await track.load(.segments)
            try expect(segments.contains { $0.isEmpty && $0.timeMapping.target.duration.seconds >= 0.9 },
                       "夹具应包含一秒合法前置空编辑段：\(url.lastPathComponent)")

            let oldGenerator = AVAssetImageGenerator(asset: asset)
            oldGenerator.appliesPreferredTrackTransform = true
            oldGenerator.maximumSize = CGSize(width: 768, height: 768)
            oldGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
            oldGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
            var oldStrategyFailed = false
            do { _ = try await oldGenerator.image(at: .zero) }
            catch { oldStrategyFailed = true }
            try expect(oldStrategyFailed, "夹具必须真实重现旧的0秒窄容差失败")

            let result = try require(await service.thumbnail(for: url, kind: .video,
                                                            modifiedDate: fixture.date, pixelSize: 768))
            let image = try cgImage(result)
            try expect(image.width > 0 && image.height > 0, "合法视频应得到真实像素")
        }
    }

    private static func canonicalSizeBands(_ fixture: MediaFixture) async throws {
        let cache = try fixture.cache("bands")
        let service = ThumbnailService(cacheDirectory: cache)
        let small = try require(await service.thumbnail(for: fixture.photo, kind: .image,
                                                       modifiedDate: fixture.date, pixelSize: 64))
        try expect(try longestSide(small) == 256, "64请求应进入256档，不能生成64像素缓存")
        let provisional = try require(await service.cachedThumbnail(for: fixture.photo, kind: .image,
                                                                   modifiedDate: fixture.date, pixelSize: 768))
        try expect(try longestSide(provisional) == 256, "渐进显示应能立即读取现有256小预览")
        let medium = try require(await service.thumbnail(for: fixture.photo, kind: .image,
                                                        modifiedDate: fixture.date, pixelSize: 640))
        let sameBand = try require(await service.thumbnail(for: fixture.photo, kind: .image,
                                                          modifiedDate: fixture.date, pixelSize: 768))
        try expect(medium.image === sameBand.image, "640与768应共享同一缓存图像")
        try expect(try longestSide(medium) == 768, "640请求应生成768档图像")
        let large = try require(await service.thumbnail(for: fixture.photo, kind: .image,
                                                       modifiedDate: fixture.date, pixelSize: 1200))
        try expect(try longestSide(large) == 1600, "1200请求应进入1600档")
        let viewer = try require(await service.thumbnail(for: fixture.photo, kind: .image,
                                                        modifiedDate: fixture.date, pixelSize: 1601))
        try expect(try longestSide(viewer) == 4096, "超过1600的请求应进入4096档")
        try expect(try cacheFiles(cache).count == 4, "同一源文件只应写入四个规范尺寸缓存")
    }

    private static func legacyPreviewUpgradesWhenOnline(_ fixture: MediaFixture) async throws {
        let source = fixture.sources.appendingPathComponent("legacy-preview.jpg")
        try FileManager.default.copyItem(at: fixture.photo, to: source)
        let onlineCache = try fixture.cache("legacy-online")
        let offlineCache = try fixture.cache("legacy-offline")
        try writeLegacyCache(source: source, date: fixture.date, size: 384, directory: onlineCache)
        try writeLegacyCache(source: source, date: fixture.date, size: 384, directory: offlineCache)
        let service = ThumbnailService(cacheDirectory: onlineCache)
        let provisional = try require(await service.cachedThumbnail(for: source, kind: .image,
                                                                   modifiedDate: fixture.date, pixelSize: 768))
        try expect(try longestSide(provisional) == 384, "旧版小预览应可立即用于渐进显示")
        let upgraded = try require(await service.thumbnail(for: source, kind: .image,
                                                          modifiedDate: fixture.date, pixelSize: 768))
        try expect(try longestSide(upgraded) == 768, "在线源必须升级旧384预览，不能永久停留在小图")
        let repeatRequest = try require(await service.thumbnail(for: source, kind: .image,
                                                               modifiedDate: fixture.date, pixelSize: 768))
        try expect(try longestSide(repeatRequest) == 768, "后续请求不能再次命中被错误标记的大档小图")

        let moved = source.deletingLastPathComponent().appendingPathComponent("legacy-moved.jpg")
        try FileManager.default.moveItem(at: source, to: moved)
        let offlineService = ThumbnailService(cacheDirectory: offlineCache)
        let fallback = try require(await offlineService.thumbnail(for: source, kind: .image,
                                                                 modifiedDate: fixture.date, pixelSize: 768))
        try expect(try longestSide(fallback) == 384, "源离线时应继续使用旧小预览，不能将其丢弃")
    }

    private static func cacheOnlyMissDoesNotDecode(_ fixture: MediaFixture) async throws {
        let cache = try fixture.cache("cache-only")
        let service = ThumbnailService(cacheDirectory: cache)
        let result = await service.cachedThumbnail(for: fixture.photo, kind: .image,
                                                   modifiedDate: fixture.date, pixelSize: 768)
        try expect(result == nil, "cachedThumbnail不能在冷缓存中解码源文件")
        try expect(try cacheFiles(cache).isEmpty, "只查缓存不能生成磁盘缩略图")
    }

    private static func offlineThumbnailIsNotFullPreview(_ fixture: MediaFixture) async throws {
        let cache = try fixture.cache("offline-not-full")
        let source = fixture.sources.appendingPathComponent("offline-not-full.jpg")
        try FileManager.default.copyItem(at: fixture.photo, to: source)
        let online = ThumbnailService(cacheDirectory: cache)
        _ = try require(await online.thumbnail(for: source, kind: .image, modifiedDate: fixture.date, pixelSize: 768))
        try FileManager.default.removeItem(at: source)
        let offline = ThumbnailService(cacheDirectory: cache)
        _ = try require(await offline.cachedThumbnail(for: source, kind: .image, modifiedDate: fixture.date, pixelSize: 768))
        let result = await offline.loadThumbnail(for: source, kind: .image, modifiedDate: fixture.date, pixelSize: 4096)
        guard case .unavailable = result else { throw MediaCheckFailure(description: "离线原件只有小图时，不能返回高清ready") }
        _ = try require(await offline.cachedThumbnail(for: source, kind: .image, modifiedDate: fixture.date, pixelSize: 768))
    }

    private static func legacyCloudCoverIsNotFullPreview(_ fixture: MediaFixture) async throws {
        let cache = try fixture.cache("legacy-cloud-not-full")
        let account = UUID()
        let cloud = CloudMediaReference(accountID: account, fileID: "legacy-photo", parentID: "/", remotePath: "/legacy-photo.jpg", revision: "r1")
        let item = MediaItem(cloud: cloud, kind: .image, fileSize: 9_000_000, modifiedDate: fixture.date, createdDate: fixture.date)
        CloudMediaRegistry.shared.register([item])
        CloudTransferCenter.shared.requireLogin(accountID: account)
        try writeLegacyCache(source: fixture.photo, date: fixture.date, size: 768, directory: cache)
        let image = try require(try cacheFiles(cache).first)
        let bytes = try Data(contentsOf: image)
        for size in [768, 4096] {
            let identity = item.id + "|" + cloud.revision
            let value = "v1\u{0}\(identity)\u{0}\(fixture.date.timeIntervalSince1970.bitPattern)\u{0}\(size)"
            let key = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
            let folder = cache.appendingPathComponent(size == 4096 ? "highResolution" : "cloud", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try bytes.write(to: folder.appendingPathComponent(key).appendingPathExtension("thumb"))
        }
        let service = ThumbnailService(cacheDirectory: cache)
        _ = try require(await service.cachedThumbnail(for: item.url, kind: .image, modifiedDate: fixture.date, pixelSize: 768))
        let result = await service.loadThumbnail(for: item.url, kind: .image, modifiedDate: fixture.date, pixelSize: 4096)
        guard case .unavailable = result else { throw MediaCheckFailure(description: "旧版小图不能从4096键冒充原图ready") }
    }

    private static func classifiedCacheClearing(_ fixture: MediaFixture) async throws {
        let cache = try fixture.cache("classified")
        let service = ThumbnailService(cacheDirectory: cache)
        _ = try require(await service.thumbnail(for: fixture.photo, kind: .image, modifiedDate: fixture.date, pixelSize: 768))
        _ = try require(await service.thumbnail(for: fixture.photo, kind: .image, modifiedDate: fixture.date, pixelSize: 4096))
        try writeLegacyCache(source: fixture.photo, date: fixture.date, size: 384, directory: cache)
        let before = await service.cacheSizes()
        try expect((before[.local] ?? 0) > 0 && (before[.highResolution] ?? 0) > 0 && (before[.legacy] ?? 0) > 0, "新版和旧版预览必须分类统计且继续兼容")
        let total = await service.cacheSize()
        try expect(before.values.reduce(0, +) == total, "分类缓存总和应等于实际缓存大小")
        await service.clearCache(categories: [.highResolution])
        let after = await service.cacheSizes()
        try expect((after[.highResolution] ?? 0) == 0 && after[.local] == before[.local] && after[.legacy] == before[.legacy], "清高清预览不能误删小图或旧版缓存")
        let kept = await service.cachedThumbnail(for: fixture.photo, kind: .image, modifiedDate: fixture.date, pixelSize: 768)
        try expect(kept != nil, "选择清理后小图应继续离线可用")
        await service.clearCache(categories: [.legacy, .local])
        let remaining = await service.cacheSize()
        try expect(remaining == 0, "全部选定类别应正确清除")
    }

    private static func persistedCacheWorksOffline(_ fixture: MediaFixture) async throws {
        let cache = try fixture.cache("offline")
        let source = fixture.sources.appendingPathComponent("offline.jpg")
        let moved = fixture.sources.appendingPathComponent("offline-moved.jpg")
        try FileManager.default.copyItem(at: fixture.photo, to: source)
        let firstService = ThumbnailService(cacheDirectory: cache)
        let first = try require(await firstService.thumbnail(for: source, kind: .image,
                                                            modifiedDate: fixture.date, pixelSize: 768))
        try expect(!(try cacheFiles(cache).isEmpty), "首次请求完成前应写入持久缓存")
        try FileManager.default.moveItem(at: source, to: moved)
        try expect(!FileManager.default.fileExists(atPath: source.path), "源文件必须真实不可读，不能只测试内存缓存")

        let restarted = ThumbnailService(cacheDirectory: cache)
        let cached = try require(await restarted.cachedThumbnail(for: source, kind: .image,
                                                                modifiedDate: fixture.date, pixelSize: 640))
        try expect(try longestSide(cached) == longestSide(first), "重启服务后应读取同一规范档位的磁盘像素")
        let requested = try require(await restarted.thumbnail(for: source, kind: .image,
                                                             modifiedDate: fixture.date, pixelSize: 768))
        try expect(try longestSide(requested) == 768, "源文件离线不应使已有缓存失效")
    }

    private static func concurrentRequestsShareWork(_ fixture: MediaFixture) async throws {
        let cache = try fixture.cache("shared")
        let service = ThumbnailService(cacheDirectory: cache)
        let url = try require(fixture.videos.first)
        let date = fixture.date
        // Two callers maximum; there is never a video-decoder stress burst.
        async let first = service.thumbnail(for: url, kind: .video, modifiedDate: date, pixelSize: 640)
        async let second = service.thumbnail(for: url, kind: .video, modifiedDate: date, pixelSize: 768)
        let pair = await (first, second)
        let a = try require(pair.0)
        let b = try require(pair.1)
        try expect(a.image === b.image, "并发消费者应拿到同一缓存对象，而非重复创建图像")
        try expect(try cacheFiles(cache).count == 1, "规范尺寸相同的并发请求只能生成一份磁盘缓存")
    }

    private static func cancellationDoesNotPoisonSurvivor(_ fixture: MediaFixture) async throws {
        let cache = try fixture.cache("cancel-shared")
        let service = ThumbnailService(cacheDirectory: cache)
        let url = try require(fixture.videos.first)
        let date = fixture.date
        let cancelled = Task.detached {
            await service.thumbnail(for: url, kind: .video, modifiedDate: date, pixelSize: 768)
        }
        let survivor = Task.detached {
            await service.thumbnail(for: url, kind: .video, modifiedDate: date, pixelSize: 768)
        }
        // Cancellation may race a very fast decode. The invariant is the live
        // consumer's success, not the cancelled caller's eventual return value.
        await Task.yield()
        cancelled.cancel()
        _ = await cancelled.value
        _ = try require(await survivor.value)
        try expect(try cacheFiles(cache).count == 1, "取消一个消费者不能丢失另一个消费者的缓存结果")
        let restarted = ThumbnailService(cacheDirectory: cache)
        _ = try require(await restarted.cachedThumbnail(for: url, kind: .video,
                                                       modifiedDate: date, pixelSize: 768))
    }

    private static func modificationDateInvalidatesCache(_ fixture: MediaFixture) async throws {
        let cache = try fixture.cache("mtime")
        let service = ThumbnailService(cacheDirectory: cache)
        let source = fixture.sources.appendingPathComponent("revision.jpg")
        try writePhoto(at: source, width: 1200, height: 800, red: true)
        try FileManager.default.setAttributes([.modificationDate: fixture.date], ofItemAtPath: source.path)
        let old = try require(await service.thumbnail(for: source, kind: .image,
                                                     modifiedDate: fixture.date, pixelSize: 768))
        try writePhoto(at: source, width: 1200, height: 800, red: false)
        let newDate = fixture.date.addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: source.path)
        let staleLookup = await service.cachedThumbnail(for: source, kind: .image,
                                                         modifiedDate: newDate, pixelSize: 768)
        try expect(staleLookup == nil, "mtime改变后旧缓存不能命中新版本")
        let updated = try require(await service.thumbnail(for: source, kind: .image,
                                                         modifiedDate: newDate, pixelSize: 768))
        try expect(old.image !== updated.image, "版本变化应替换图像对象")
        let color = try sampleColor(updated)
        try expect(color.blueComponent > 0.7 && color.redComponent < 0.3, "新缩略图必须反映蓝色的新源内容")
    }

    private static func corruptDiskCacheHeals(_ fixture: MediaFixture) async throws {
        let cache = try fixture.cache("corrupt")
        let first = ThumbnailService(cacheDirectory: cache)
        _ = try require(await first.thumbnail(for: fixture.photo, kind: .image,
                                             modifiedDate: fixture.date, pixelSize: 768))
        let stored = try require(try cacheFiles(cache).first)
        try Data("invalid-thumbnail".utf8).write(to: stored, options: .atomic)
        let restarted = ThumbnailService(cacheDirectory: cache)
        let repaired = try require(await restarted.thumbnail(for: fixture.photo, kind: .image,
                                                            modifiedDate: fixture.date, pixelSize: 768))
        try expect(try longestSide(repaired) == 768, "损坏的缓存应从仍可读的源文件恢复")
        let source = try require(CGImageSourceCreateWithURL(stored as CFURL, nil))
        try expect(CGImageSourceGetCount(source) > 0, "修复结果必须覆盖损坏的磁盘缓存")
    }

    private static func missingSourceCanRecover(_ fixture: MediaFixture) async throws {
        let cache = try fixture.cache("failed-retry")
        let service = ThumbnailService(cacheDirectory: cache)
        let source = fixture.sources.appendingPathComponent("appeared-later.jpg")
        let absent = await service.thumbnail(for: source, kind: .image,
                                              modifiedDate: fixture.date, pixelSize: 768)
        try expect(absent == nil, "缺失源文件应返回nil")
        try expect(try cacheFiles(cache).isEmpty, "nil失败不能留下持久的空缓存")
        try writePhoto(at: source, width: 1200, height: 800, red: true)
        try FileManager.default.setAttributes([.modificationDate: fixture.date], ofItemAtPath: source.path)
        let recovered = try require(await service.thumbnail(for: source, kind: .image,
                                                           modifiedDate: fixture.date, pixelSize: 768))
        try expect(try longestSide(recovered) == 768, "完全相同的请求在源文件恢复后必须成功")
    }

    private static func fullSizePreviewUsesSource(_ fixture: MediaFixture) async throws {
        let cache = try fixture.cache("full-source")
        let service = ThumbnailService(cacheDirectory: cache)
        let source = try require(CGImageSourceCreateWithURL(fixture.photo as CFURL, nil))
        let embedded = try require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceThumbnailMaxPixelSize: 4096
        ] as CFDictionary))
        try expect(max(embedded.width, embedded.height) < 4096, "夹具必须包含与全源尺寸不同的小内嵌预览")
        _ = try require(await service.thumbnail(for: fixture.photo, kind: .image,
                                             modifiedDate: fixture.date, pixelSize: 64))
        let full = try require(await service.thumbnail(for: fixture.photo, kind: .image,
                                                      modifiedDate: fixture.date, pixelSize: 4096))
        try expect(try longestSide(full) == 4096, "查看器必须解码全源到4096，不能复用内嵌或256档小图")
    }

    private static func observeCancelledRequestPersistence(_ fixture: MediaFixture) async {
        do {
            let cache = try fixture.cache("cancel-observation")
            let service = ThumbnailService(cacheDirectory: cache)
            let url = try require(fixture.videos.first)
            let date = fixture.date
            let request = Task.detached {
                await service.thumbnail(for: url, kind: .video, modifiedDate: date, pixelSize: 768)
            }
            try await Task.sleep(for: .milliseconds(1))
            request.cancel()
            _ = await request.value
            let restarted = ThumbnailService(cacheDirectory: cache)
            let cached = await restarted.cachedThumbnail(for: url, kind: .video,
                                                         modifiedDate: date, pixelSize: 768)
            if cached != nil { print("· 观察：消费者离开后，已开始的视频请求完成并留下磁盘缓存") }
            else { print("· 观察：请求可能在解码开始前取消，未对落盘时序作强断言") }
        } catch { print("· 取消落盘观察未完成：\(error)") }
    }
}

private struct MediaFixture {
    let root: URL
    let sources: URL
    let photo: URL
    let videos: [URL]
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    static func make() async throws -> MediaFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FilmboxMediaChecks-" + UUID().uuidString, isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        do {
            let photo = sources.appendingPathComponent("large-with-embedded-preview.jpg")
            try writePhoto(at: photo, width: 4800, height: 3200, red: true, embeddedPreview: true)
            var videos: [URL] = []
            // Sequential encoding and a single decoded key in concurrency tests
            // keep actual media work at no more than two simultaneous requests.
            for (name, codec) in [("h264", AVVideoCodecType.h264), ("hevc", AVVideoCodecType.hevc)] {
                for (extensionName, container) in [("mp4", AVFileType.mp4), ("mov", AVFileType.mov)] {
                    let url = sources.appendingPathComponent("\(name)-delayed.\(extensionName)")
                    try await writeDelayedVideo(at: url, codec: codec, container: container)
                    videos.append(url)
                }
            }
            return MediaFixture(root: root, sources: sources, photo: photo, videos: videos)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func cache(_ name: String) throws -> URL {
        let directory = root.appendingPathComponent("Caches", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func writePhoto(at url: URL, width: Int, height: Int, red: Bool, embeddedPreview: Bool = false) throws {
    let context = try require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red ? CGColor(red: 0.9, green: 0.05, blue: 0.04, alpha: 1) : CGColor(red: 0.04, green: 0.05, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // A small contrasting edge gives the fixture content beyond a flat field,
    // while keeping the centre a stable, easily verified revision colour.
    context.setFillColor(CGColor(gray: 0.85, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: max(1, width / 30), height: height))
    let image = try require(context.makeImage())
    let destination = try require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [
        kCGImageDestinationLossyCompressionQuality: 0.9,
        kCGImageDestinationEmbedThumbnail: embeddedPreview
    ] as CFDictionary)
    try expect(CGImageDestinationFinalize(destination), "无法写入照片夹具")
}

private func writeDelayedVideo(at url: URL, codec: AVVideoCodecType, container: AVFileType) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: container)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: codec, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 200_000, AVVideoExpectedSourceFrameRateKey: 15]
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240
    ])
    try expect(writer.canAdd(input), "视频编码器不支持测试设置")
    writer.add(input)
    try expect(writer.startWriting(), "无法启动视频夹具编码：\(String(describing: writer.error))")
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<30 {
        try waitForVideoInput(input, writer: writer)
        var buffer: CVPixelBuffer?
        try expect(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess,
                   "无法分配视频夹具像素")
        let pixels = try require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), Int32(70 + frame * 3), CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        try expect(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame + 15), timescale: 15)),
                   "无法追加视频帧：\(String(describing: writer.error))")
    }
    writer.endSession(atSourceTime: CMTime(seconds: 3, preferredTimescale: 600))
    input.markAsFinished()
    await writer.finishWriting()
    try expect(writer.status == .completed, "视频夹具编码未完成：\(String(describing: writer.error))")
}

private func waitForVideoInput(_ input: AVAssetWriterInput, writer: AVAssetWriter) throws {
    let start = ProcessInfo.processInfo.systemUptime
    while !input.isReadyForMoreMediaData {
        try expect(writer.status != .failed, "视频编码失败：\(String(describing: writer.error))")
        try expect(ProcessInfo.processInfo.systemUptime - start < 15, "视频夹具编码超时")
        Thread.sleep(forTimeInterval: 0.002)
    }
}

@MainActor
private func cgImage(_ thumbnail: Thumbnail) throws -> CGImage {
    try require(thumbnail.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
}

@MainActor
private func longestSide(_ thumbnail: Thumbnail) throws -> Int {
    let image = try cgImage(thumbnail)
    return max(image.width, image.height)
}

@MainActor
private func sampleColor(_ thumbnail: Thumbnail) throws -> NSColor {
    let image = try cgImage(thumbnail)
    let bitmap = NSBitmapImageRep(cgImage: image)
    return try require(bitmap.colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.deviceRGB))
}

private func cacheFiles(_ directory: URL) throws -> [URL] {
    let urls = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])?.allObjects as? [URL] ?? []
    return urls.filter { $0.pathExtension == "thumb" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
}

/// The historical v1 exact-size cache format is intentionally fixed here so
/// migration tests cannot silently adopt a new service implementation's format.
private func writeLegacyCache(source: URL, date: Date, size: Int, directory: URL) throws {
    let value = "v1\u{0}\(source.standardizedFileURL.path)\u{0}\(date.timeIntervalSince1970.bitPattern)\u{0}\(size)"
    let key = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    let imageSource = try require(CGImageSourceCreateWithURL(source as CFURL, nil))
    let preview = try require(CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: size
    ] as CFDictionary))
    let target = directory.appendingPathComponent(key).appendingPathExtension("thumb")
    let destination = try require(CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, preview, nil)
    try expect(CGImageDestinationFinalize(destination), "无法写入历史缩略图夹具")
}

private struct MediaCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ reason: String, file: StaticString = #filePath, line: UInt = #line) throws {
    guard try condition() else { throw MediaCheckFailure(description: "\(reason)（\(file):\(line)）") }
}

private func require<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { throw MediaCheckFailure(description: "缺少必要结果（\(file):\(line)）") }
    return value
}
