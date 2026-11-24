import Foundation
import Darwin

public struct CompatibleVideoMetadata: Sendable {
    public let width: Int?
    public let height: Int?
    public let duration: Double?
    public let codec: String?
    public let capturedDate: Date?
}

/// The packaged tools are private, local-only helpers. Never execute a user's
/// PATH or interpolate a media filename into a command shell.
public enum MediaCodecRuntime {
    public static var isAvailable: Bool { executable("ffprobe") != nil && executable("ffmpeg") != nil }

    public static func executable(_ name: String) -> URL? {
        guard ["ffmpeg", "ffprobe"].contains(name) else { return nil }
        let packaged = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
        if FileManager.default.isExecutableFile(atPath: packaged.path) { return packaged }
        #if DEBUG
        // Debug checks and the isolated development app share the locally built
        // runtime. Release builds resolve helpers only inside their signed app.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let development = root.appendingPathComponent(".build/CodecRuntime/install/bin/\(name)")
        if FileManager.default.isExecutableFile(atPath: development.path) { return development }
        #endif
        return nil
    }

    public static func videoMetadata(at url: URL) async -> CompatibleVideoMetadata? {
        guard url.isFileURL, let tool = executable("ffprobe"), !Task.isCancelled else { return nil }
        let args = ["-v", "error", "-probesize", "10000000", "-analyzeduration", "5000000",
                    "-select_streams", "v:0", "-show_entries",
                    "stream=codec_name,width,height,duration:stream_tags=rotate:stream_side_data=rotation:format=duration:format_tags=creation_time",
                    "-of", "json", url.path]
        guard let data = try? await run(tool, arguments: args, timeout: 8, outputLimit: 2 * 1024 * 1024),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]], let video = streams.first else { return nil }
        let format = json["format"] as? [String: Any] ?? [:]
        func number(_ value: Any?) -> Double? {
            let result = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
            return result.flatMap { $0.isFinite ? $0 : nil }
        }
        func dimension(_ value: Any?) -> Int? {
            guard let n = number(value), n > 0, n <= 100_000 else { return nil }
            return Int(n.rounded())
        }
        let tags = video["tags"] as? [String: Any] ?? [:]
        let sideData = video["side_data_list"] as? [[String: Any]] ?? []
        let rotation = sideData.compactMap { number($0["rotation"]) }.first ?? number(tags["rotate"]) ?? 0
        let swaps = abs(rotation.truncatingRemainder(dividingBy: 180)) > 45
        let width = dimension(video["width"]), height = dimension(video["height"])
        let duration = (number(format["duration"]) ?? number(video["duration"])).flatMap { $0 >= 0 ? $0 : nil }
        let creation = (format["tags"] as? [String: Any])?["creation_time"] as? String
        let date: Date? = creation.flatMap { value in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        }
        return CompatibleVideoMetadata(width: swaps ? height : width, height: swaps ? width : height,
                                       duration: duration, codec: video["codec_name"] as? String, capturedDate: date)
    }

    public static func previewData(at url: URL, pixelSize: Int) async -> Data? {
        guard url.isFileURL, let tool = executable("ffmpeg"), !Task.isCancelled else { return nil }
        let size = min(4096, max(64, pixelSize))
        let args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-threads", "2",
                    "-i", url.path, "-map", "0:v:0", "-an", "-sn", "-dn", "-frames:v", "1",
                    "-vf", "scale=\(size):\(size):force_original_aspect_ratio=decrease:reset_sar=1",
                    "-threads", "1", "-c:v", "mjpeg", "-q:v", "3", "-f", "image2pipe", "pipe:1"]
        return try? await run(tool, arguments: args, timeout: 12, outputLimit: 32 * 1024 * 1024)
    }

    private static func run(_ executable: URL, arguments: [String], timeout: TimeInterval, outputLimit: Int) async throws -> Data {
        let job = CodecProcessJob(executable: executable, arguments: arguments, outputLimit: outputLimit)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in job.start(continuation, timeout: timeout) }
        } onCancel: { job.cancel() }
    }
}

private enum CodecProcessError: Error { case failed, timedOut, excessiveOutput }

/// Process and its pipes belong to a background lane. A deadline or cancellation
/// releases the caller immediately, terminates the child, then reaps it there.
private final class CodecProcessJob: @unchecked Sendable {
    private let executable: URL
    private let arguments: [String]
    private let outputLimit: Int
    private let lock = NSLock()
    private var process: Process?
    private var finished = false
    private var continuation: CheckedContinuation<Data, Error>?

    init(executable: URL, arguments: [String], outputLimit: Int) {
        self.executable = executable; self.arguments = arguments; self.outputLimit = outputLimit
    }
    func start(_ next: CheckedContinuation<Data, Error>, timeout: TimeInterval) {
        let registered = lock.withLock {
            if finished { return false }
            continuation = next
            return true
        }
        guard registered else { next.resume(throwing: CancellationError()); return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.stop(with: CodecProcessError.timedOut)
        }
        DispatchQueue.global(qos: .utility).async { [self] in execute() }
    }
    func cancel() { stop(with: CancellationError()) }

    private func execute() {
        let child = Process(), pipe = Pipe()
        child.executableURL = executable
        child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = pipe
        child.standardError = FileHandle.nullDevice
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            lock.withLock { process = nil }
        }
        do {
            try lock.withLock {
                guard !finished else { throw CancellationError() }
                process = child
                try child.run()
            }
            // The parent must close its writer so EOF also arrives on failure.
            try pipe.fileHandleForWriting.close()
            var data = Data()
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                guard data.count <= outputLimit - chunk.count else {
                    stop(with: CodecProcessError.excessiveOutput)
                    child.waitUntilExit()
                    return
                }
                data.append(chunk)
            }
            child.waitUntilExit()
            resolve(child.terminationStatus == 0 ? .success(data) : .failure(CodecProcessError.failed))
        } catch {
            stop(with: error)
            if child.isRunning { child.waitUntilExit() }
        }
    }
    private func stop(with error: Error) {
        // Deciding that the job is finished and taking the child snapshot must
        // be one transition. Otherwise execute() can launch between a nil
        // snapshot and resolve(), leaving a cancelled child until its deadline.
        let (waiting, child) = lock.withLock {
            guard !finished else {
                return (nil as CheckedContinuation<Data, Error>?, nil as Process?)
            }
            finished = true
            let waiting = continuation
            continuation = nil
            return (waiting, process)
        }
        waiting?.resume(throwing: error)
        guard let child, child.isRunning else { return }
        child.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }
    private func resolve(_ result: Result<Data, Error>) {
        let waiting = lock.withLock {
            guard !finished else { return nil as CheckedContinuation<Data, Error>? }
            finished = true
            let waiting = continuation
            continuation = nil
            return waiting
        }
        waiting?.resume(with: result)
    }
}
