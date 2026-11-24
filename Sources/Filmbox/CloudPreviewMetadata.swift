import Foundation
import CoreGraphics
import ImageIO
import AVFoundation
import FilmboxCore

/// Preview geometry is a display hint. Original dimensions and camera metadata
/// are read from an original file or authenticated video stream, never a cover.
enum CloudPreviewMetadata {
    static let notification = Notification.Name("FilmboxCloudMetadata")

    static func report(item: MediaItem, image: CGImage) {
        report(item: item, width: image.width, height: image.height)
    }

    static func report(item: MediaItem, width: Int, height: Int) {
        guard let cloud = item.cloud, width > 0, height > 0 else { return }
        if let width = item.pixelWidth, let height = item.pixelHeight, width > 0, height > 0 { return }
        let ratio = Double(width) / Double(height)
        if let previous = item.previewAspectRatio, abs(previous - ratio) / max(previous, ratio) < 0.01 { return }
        NotificationCenter.default.post(name: notification, object: nil,
            userInfo: ["id": item.id, "revision": cloud.revision, "ratio": ratio])
    }

    static func originalMetadata(item: MediaItem, url: URL) async {
        guard item.cloud != nil, url.isFileURL, !Task.isCancelled else { return }
        let metadata: OriginalMetadata
        if item.kind == .image {
            metadata = await Task.detached(priority: .utility) { imageMetadata(at: url) }.value
        } else {
            metadata = await videoMetadata(at: url)
        }
        guard !Task.isCancelled else { return }
        publish(item: item, metadata: metadata)
    }

    static func streamingVideoMetadata(item: MediaItem, url: URL, headers: [String: String]) async {
        guard item.cloud != nil, item.kind == .video, !Task.isCancelled,
              url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        guard item.pixelWidth == nil || item.pixelHeight == nil || item.duration == nil else { return }
        await StreamingRequests.shared.perform(item: item, url: url, headers: headers)
    }

    private static func publish(item: MediaItem, metadata: OriginalMetadata) {
        guard let cloud = item.cloud else { return }
        var values: [String: Any] = ["id": item.id, "revision": cloud.revision]
        if let width = metadata.width, let height = metadata.height, width > 0, height > 0 {
            values["width"] = width
            values["height"] = height
            values["ratio"] = Double(width) / Double(height)
        }
        if let date = metadata.capturedDate { values["capturedDate"] = date }
        if let duration = metadata.duration, duration.isFinite, duration >= 0 { values["duration"] = duration }
        if let camera = metadata.camera { values["camera"] = camera }
        if let lens = metadata.lens { values["lens"] = lens }
        if let aperture = metadata.aperture { values["aperture"] = aperture }
        if let focalLength = metadata.focalLength { values["focalLength"] = focalLength }
        if let iso = metadata.iso { values["iso"] = iso }
        if let exposure = metadata.exposure { values["exposure"] = exposure }
        guard values.count > 2 else { return }
        NotificationCenter.default.post(name: notification, object: nil, userInfo: values)
    }

    /// A visible file may request several thumbnail sizes concurrently. Only one
    /// metadata read runs for a revision, and transient failures can be retried.
    private actor StreamingRequests {
        static let shared = StreamingRequests()
        private struct Work { let id: UUID; let task: Task<Bool, Never> }
        private var pending: [String: Work] = [:]
        private var completed: [String: Date] = [:]
        private var failed: [String: Date] = [:]

        func perform(item: MediaItem, url: URL, headers: [String: String]) async {
            let key = item.id + "|" + (item.cloud?.revision ?? "")
            guard completed[key] == nil else { return }
            if let work = pending[key] {
                _ = await withTaskCancellationHandler { await work.task.value } onCancel: { work.task.cancel() }
                return
            }
            if let last = failed[key], Date().timeIntervalSince(last) < 30 { return }
            let id = UUID()
            let task = Task<Bool, Never> {
                guard !Task.isCancelled,
                      let metadata = await timedStreamingRead(url: url, headers: headers),
                      !Task.isCancelled else { return false }
                publish(item: item, metadata: metadata)
                return metadata.width != nil && metadata.height != nil && metadata.duration != nil
            }
            pending[key] = Work(id: id, task: task)
            let success = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            guard pending[key]?.id == id else { return }
            pending[key] = nil
            if success { completed[key] = Date(); failed[key] = nil }
            else { failed[key] = Date() }
            // Metadata itself is persisted in the catalogue; this only prevents
            // repeated network requests during the current app session.
            if completed.count > 4096 { completed = completed.filter { Date().timeIntervalSince($0.value) < 1800 } }
            if failed.count > 1024 { failed = failed.filter { Date().timeIntervalSince($0.value) < 30 } }
        }
    }

    /// Unstructured workers let the caller return at the deadline even if an AV
    /// loader ignores Swift cancellation; cancelLoading also closes its I/O.
    private static func timedStreamingRead(url: URL, headers: [String: String]) async -> OriginalMetadata? {
        let options: [String: Any] = headers.isEmpty ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: options)
        let race = TimedRead()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard race.install(continuation) else { return }
                let reader = Task {
                    let metadata = await videoMetadata(asset: asset, fallbackURL: nil)
                    race.finish(metadata)
                }
                let timeout = Task {
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    race.finish(nil)
                    asset.cancelLoading()
                }
                race.install(reader: reader, timeout: timeout)
            }
        } onCancel: {
            race.finish(nil)
            asset.cancelLoading()
        }
    }

    private final class TimedRead: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<OriginalMetadata?, Never>?
        private var reader: Task<Void, Never>?
        private var timeout: Task<Void, Never>?
        private var finished = false
        private var result: OriginalMetadata?

        func install(_ continuation: CheckedContinuation<OriginalMetadata?, Never>) -> Bool {
            lock.lock()
            if finished { let result = result; lock.unlock(); continuation.resume(returning: result); return false }
            self.continuation = continuation
            lock.unlock()
            return true
        }
        func install(reader: Task<Void, Never>, timeout: Task<Void, Never>) {
            lock.lock()
            if finished { lock.unlock(); reader.cancel(); timeout.cancel(); return }
            self.reader = reader; self.timeout = timeout
            lock.unlock()
        }
        func finish(_ result: OriginalMetadata?) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true; self.result = result
            let continuation = continuation, reader = reader, timeout = timeout
            self.continuation = nil; self.reader = nil; self.timeout = nil
            lock.unlock()
            reader?.cancel(); timeout?.cancel()
            continuation?.resume(returning: result)
        }
    }

    private struct OriginalMetadata: Sendable {
        var width: Int?
        var height: Int?
        var capturedDate: Date?
        var duration: Double?
        var camera: String?
        var lens: String?
        var aperture: Double?
        var focalLength: Double?
        var iso: Int?
        var exposure: String?
    }

    private static func imageMetadata(at url: URL) -> OriginalMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return OriginalMetadata() }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue
        let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        let swapped = (5...8).contains(orientation)
        let dateText = string(exif[kCGImagePropertyExifDateTimeOriginal as String])
            ?? string(exif[kCGImagePropertyExifDateTimeDigitized as String])
            ?? string(tiff[kCGImagePropertyTIFFDateTime as String])
        let offset = string(exif["OffsetTimeOriginal"]) ?? string(exif["OffsetTimeDigitized"])
        let make = string(tiff[kCGImagePropertyTIFFMake as String])
        let model = string(tiff[kCGImagePropertyTIFFModel as String])
        let camera: String? = {
            guard let model else { return make }
            guard let make, !model.localizedCaseInsensitiveContains(make) else { return model }
            return make + " " + model
        }()
        let seconds = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
        let exposure = seconds.flatMap { value -> String? in
            guard value.isFinite, value > 0 else { return nil }
            if value < 1 {
                let inverse = (1 / value).rounded()
                guard inverse.isFinite, inverse < Double(Int.max) else { return nil }
                return "1/\(Int(inverse)) s"
            }
            return "\(value.formatted(.number.precision(.fractionLength(0...3)))) s"
        }
        let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue
        return OriginalMetadata(width: swapped ? height : width, height: swapped ? width : height,
            capturedDate: dateText.flatMap { exifDate($0, offset: offset) }, camera: camera,
            lens: string(exif[kCGImagePropertyExifLensModel as String]),
            aperture: positive(exif[kCGImagePropertyExifFNumber as String]),
            focalLength: positive(exif[kCGImagePropertyExifFocalLength as String]),
            iso: iso.flatMap { $0 > 0 ? $0 : nil }, exposure: exposure)
    }

    private static func videoMetadata(at url: URL) async -> OriginalMetadata {
        await videoMetadata(asset: AVURLAsset(url: url), fallbackURL: url)
    }

    private static func videoMetadata(asset: AVURLAsset, fallbackURL: URL?) async -> OriginalMetadata {
        var result = OriginalMetadata()
        if let creation = try? await asset.load(.creationDate) { result.capturedDate = try? await creation.load(.dateValue) }
        guard !Task.isCancelled else { return result }
        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds.isFinite {
            result.duration = max(0, duration.seconds)
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
            let displayed = CGRect(origin: .zero, size: size).applying(transform).standardized.size
            if displayed.width.isFinite, displayed.height.isFinite,
               displayed.width > 0, displayed.height > 0,
               displayed.width < CGFloat(Int.max), displayed.height < CGFloat(Int.max) {
                result.width = Int(displayed.width.rounded())
                result.height = Int(displayed.height.rounded())
            }
        }
        if !Task.isCancelled, let fallbackURL, fallbackURL.isFileURL,
           result.width == nil || result.height == nil || result.duration == nil,
           let compatible = await MediaCodecRuntime.videoMetadata(at: fallbackURL) {
            result.width = result.width ?? compatible.width
            result.height = result.height ?? compatible.height
            result.duration = result.duration ?? compatible.duration
            result.capturedDate = result.capturedDate ?? compatible.capturedDate
        }
        return result
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
    private static func positive(_ value: Any?) -> Double? {
        guard let number = (value as? NSNumber)?.doubleValue, number.isFinite, number > 0 else { return nil }
        return number
    }
    private static func exifDate(_ value: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.isLenient = false
        if let offset { formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"; if let date = formatter.date(from: value + offset) { return date } }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: value)
    }
}
