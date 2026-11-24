import AppKit
import AVFoundation
import ImageIO
import FilmboxCore
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Decoding runs outside the cache actor, so a slow RAW never blocks cache hits.
enum ThumbnailDecoder {
    static func cloudPreview(item: MediaItem, pixelSize: Int, priority: CloudTransferPriority = .foreground) async throws -> CGImage? {
        if item.kind == .image, pixelSize >= 4096 {
            // An explicit high-resolution request must never succeed with the
            // provider cover after its original download or decode failed.
            let url = try await MediaAssetResolver.shared.originalFile(for: item, priority: priority)
            return await decode(url: url, kind: .image, pixelSize: pixelSize)
        }
        if let original = await MediaAssetResolver.shared.cachedOriginalFile(for: item) {
            // A downloaded video is a movie, not a provider JPEG cover.
            return await decode(url: original, kind: item.kind, pixelSize: pixelSize)
        }
        do {
            let url = try await MediaAssetResolver.shared.thumbnailFile(for: item, priority: priority)
            if let image = await decode(url: url, kind: .image, pixelSize: pixelSize) { return image }
        } catch CloudConnectionError.thumbnailUnavailable {
            if item.kind == .image || priority == .background { throw CloudConnectionError.thumbnailUnavailable }
        }
        guard priority == .foreground, item.kind == .video, !Task.isCancelled,
              let asset = try? await MediaAssetResolver.shared.playbackAsset(for: item) else { return nil }
        let frame = await videoFrame(url: asset.url, pixelSize: pixelSize, at: .zero, headers: asset.headers)
        if frame != nil {
            Task(priority: .utility) {
                await CloudPreviewMetadata.streamingVideoMetadata(item: item, url: asset.url, headers: asset.headers)
            }
        }
        return frame
    }

    static func localOriginalPreview(item: MediaItem, url: URL, pixelSize: Int) async -> CGImage? {
        guard url.isFileURL, !Task.isCancelled else { return nil }
        if item.kind == .video {
            let seconds = min(1, max(0.05, (item.duration ?? 2) * 0.1))
            if let frame = await videoFrame(url: url, pixelSize: pixelSize,
                at: CMTime(seconds: seconds, preferredTimescale: 600)) { return frame }
        }
        return await decode(url: url, kind: item.kind, pixelSize: pixelSize)
    }

    static func decode(url: URL, kind: MediaKind, pixelSize: Int) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if kind == .image {
            if let image = downsample(url: url, pixelSize: pixelSize) { return image }
        } else {
            // Game consoles often export a still beside a WebM. It is an
            // intentional poster and avoids opening a multi-gigabyte recording.
            if ["webm", "mkv", "avi", "wmv", "flv"].contains(url.pathExtension.lowercased()),
               let image = sidecarPreview(url: url, pixelSize: pixelSize) { return image }
            if let image = await videoFrame(url: url, pixelSize: pixelSize, at: .zero) { return image }
            guard !Task.isCancelled else { return nil }
            // Do not read duration here: even metadata can stall on a damaged
            // movie. The tolerant zero-time request covers short clips already.
            if let image = await videoFrame(url: url, pixelSize: pixelSize, at: CMTime(seconds: 1, preferredTimescale: 600)) { return image }
        }
        guard !Task.isCancelled else { return nil }
        if let image = await quickLook(url: url, pixelSize: pixelSize) { return image }
        guard !Task.isCancelled else { return nil }
        if kind == .video, let image = sidecarPreview(url: url, pixelSize: pixelSize) { return image }
        guard let data = await MediaCodecRuntime.previewData(at: url, pixelSize: pixelSize),
              !Task.isCancelled else { return nil }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
    }

    private static func sidecarPreview(url: URL, pixelSize: Int) -> CGImage? {
        let stem = url.deletingPathExtension()
        for ext in ["jpg", "jpeg", "png", "heic", "JPG", "JPEG", "PNG", "HEIC"] {
            let candidate = stem.appendingPathExtension(ext)
            if FileManager.default.isReadableFile(atPath: candidate.path),
               let image = downsample(url: candidate, pixelSize: pixelSize) { return image }
        }
        return nil
    }

    static func downsample(url: URL, pixelSize: Int) -> CGImage? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            let sourceType = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
            var options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ]
            if pixelSize <= 1024 && sourceType?.conforms(to: .rawImage) == true {
                options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
            } else {
                options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
    }

    private static func videoFrame(url: URL, pixelSize: Int, at time: CMTime, headers: [String: String] = [:]) async -> CGImage? {
        let asset = AVURLAsset(url: url, options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixelSize, height: pixelSize)
        // Valid movies can contain an empty edit before their first visible frame.
        // A narrow ±0.3s tolerance at zero incorrectly reports those as unreadable.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let job = VideoThumbnailJob(generator, time: time)
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            job.cancel()
        }
        defer { timeout.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { job.start($0) }
        } onCancel: { job.cancel() }
    }

    private static func quickLook(url: URL, pixelSize: Int) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: pixelSize, height: pixelSize), scale: 1, representationTypes: .thumbnail)
        request.iconMode = false
        let job = QuickLookThumbnailJob(request)
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            job.cancel()
        }
        defer { timeout.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { job.start($0) }
        } onCancel: { job.cancel() }
    }

}

/// The deadline releases the caller even if AVFoundation responds late. The
/// generator is configured before handoff; only its documented cancel API races.
private final class VideoThumbnailJob: @unchecked Sendable {
    private let generator: AVAssetImageGenerator
    private let time: CMTime
    private let submission = DispatchQueue(label: "com.filmbox.thumbnail.video", qos: .utility)
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var finished = false
    init(_ generator: AVAssetImageGenerator, time: CMTime) { self.generator = generator; self.time = time }
    func start(_ next: CheckedContinuation<CGImage?, Never>) {
        let shouldStart = lock.withLock {
            if finished { return false }
            continuation = next
            return true
        }
        guard shouldStart else { next.resume(returning: nil); return }
        submission.async { [self] in
            guard !lock.withLock({ finished }) else { return }
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { [self] _, image, _, result, _ in
                resolve(result == .succeeded ? image : nil)
            }
        }
    }
    func cancel() {
        resolve(nil)
        // If submission is already running, cancellation is enqueued after it.
        // If it has not begun, its finished check prevents a late orphan decode.
        submission.async { [self] in generator.cancelAllCGImageGeneration() }
    }
    private func resolve(_ image: CGImage?) {
        let pending = lock.withLock {
            guard !finished else { return nil as CheckedContinuation<CGImage?, Never>? }
            finished = true
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(returning: image)
    }
}

/// Quick Look cancellation need not wait for the provider callback. Resolve the
/// continuation once and discard late replies, including timeouts and shutdown.
private final class QuickLookThumbnailJob: @unchecked Sendable {
    private let request: QLThumbnailGenerator.Request
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var finished = false
    init(_ request: QLThumbnailGenerator.Request) { self.request = request }
    func start(_ next: CheckedContinuation<CGImage?, Never>) {
        let shouldStart = lock.withLock {
            if finished { return false }
            continuation = next
            return true
        }
        guard shouldStart else { next.resume(returning: nil); return }
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [self] representation, _ in
            resolve(representation?.type == .thumbnail ? representation?.cgImage : nil)
        }
        if lock.withLock({ finished }) { QLThumbnailGenerator.shared.cancel(request) }
    }
    func cancel() {
        resolve(nil)
        QLThumbnailGenerator.shared.cancel(request)
    }
    private func resolve(_ image: CGImage?) {
        let pending = lock.withLock {
            guard !finished else { return nil as CheckedContinuation<CGImage?, Never>? }
            finished = true
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(returning: image)
    }
}
