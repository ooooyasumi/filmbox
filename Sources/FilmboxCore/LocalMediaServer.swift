import Foundation
@preconcurrency import Network

/// An unguessable, read-only route to one original file. Releasing the lease
/// revokes its routes and closes its active streams; releasing twice is harmless.
public final class LocalMediaLease: @unchecked Sendable {
    public let id: UUID
    public let url: URL
    public var mediaURL: URL { url }
    public let playerURL: URL
    public let originURL: URL
    private let lock = NSLock()
    private var releaseAction: (@Sendable () -> Void)?

    fileprivate init(id: UUID, url: URL, playerURL: URL, originURL: URL,
                     release: @escaping @Sendable () -> Void) {
        self.id = id
        self.url = url
        self.playerURL = playerURL
        self.originURL = originURL
        releaseAction = release
    }

    public func release() {
        let action = lock.withLock {
            let action = releaseAction
            releaseAction = nil
            return action
        }
        action?()
    }

    deinit { release() }
}

/// Supplies WebKit with same-origin HTML and byte-range media without copying
/// or transcoding the source. The listener binds only IPv4 loopback.
public actor LocalMediaServer {
    public static let shared = LocalMediaServer()
    private let transport = LocalMediaTransport()

    public init() {}

    public func open(_ file: URL) async throws -> LocalMediaLease {
        guard file.isFileURL else { throw LocalMediaServerError.invalidFile }
        let source = file.standardizedFileURL
        let scoped = source.startAccessingSecurityScopedResource()
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  size > 0, FileManager.default.isReadableFile(atPath: source.path) else {
                throw LocalMediaServerError.invalidFile
            }
            let port = try await transport.start()
            let id = UUID()
            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let origin = URL(string: "http://127.0.0.1:\(port)/")!
            let media = origin.appendingPathComponent("\(token)/media")
            let player = origin.appendingPathComponent("\(token)/player.html")
            let record = LocalMediaRecord(id: id, file: source, size: size,
                                          mimeType: Self.mimeType(source.pathExtension),
                                          mediaPath: media.path, playerPath: player.path,
                                          securityScoped: scoped)
            await transport.register(record)
            let transport = transport
            return LocalMediaLease(id: id, url: media, playerURL: player, originURL: origin) {
                transport.revoke(id)
            }
        } catch {
            if scoped { source.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    /// Call before loading lease.playerURL. The page and media share one origin,
    /// so WebKit needs no broad file-read grant and canvas remains readable.
    public func setPlayerHTML(_ html: String, for lease: LocalMediaLease) async {
        guard let data = html.data(using: .utf8), data.count <= 1_048_576 else { return }
        await transport.setHTML(data, id: lease.id)
    }

    private static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "webm": "video/webm"
        case "mkv": "video/x-matroska"
        case "avi": "video/x-msvideo"
        case "mov": "video/quicktime"
        case "m4v", "mp4": "video/mp4"
        case "ogg", "ogv": "video/ogg"
        default: "application/octet-stream"
        }
    }
}

public enum LocalMediaServerError: Error, LocalizedError, Sendable {
    case invalidFile
    case listenerUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidFile: "原视频暂时无法读取"
        case .listenerUnavailable: "暂时无法启动视频播放"
        }
    }
}

private struct LocalMediaRecord: Sendable {
    let id: UUID
    let file: URL
    let size: UInt64
    let mimeType: String
    let mediaPath: String
    let playerPath: String
    let securityScoped: Bool
    var html: Data?
}

/// All mutable transport state belongs to queue. Network.framework handlers
/// and file reads use that same queue; a stream keeps at most one 64 KiB chunk.
private final class LocalMediaTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.filmbox.local-media", qos: .userInitiated)
    private var listener: NWListener?
    private var port: UInt16?
    private var starters: [CheckedContinuation<UInt16, any Error>] = []
    private var records: [UUID: LocalMediaRecord] = [:]
    private var paths: [String: UUID] = [:]
    private var connections: [UUID: LocalMediaConnection] = [:]

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let port { continuation.resume(returning: port); return }
                starters.append(continuation)
                guard listener == nil else { return }
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    parameters.includePeerToPeer = false
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.accept(connection)
                    }
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = listener?.port?.rawValue else {
                                self.startFailed(LocalMediaServerError.listenerUnavailable)
                                return
                            }
                            self.port = port
                            let pending = self.starters
                            self.starters.removeAll()
                            pending.forEach { $0.resume(returning: port) }
                        case .failed(let error): self.startFailed(error)
                        default: break
                        }
                    }
                    listener.start(queue: queue)
                } catch { startFailed(error) }
            }
        }
    }

    func register(_ record: LocalMediaRecord) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                records[record.id] = record
                paths[record.mediaPath] = record.id
                paths[record.playerPath] = record.id
                continuation.resume()
            }
        }
    }

    func setHTML(_ html: Data, id: UUID) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                records[id]?.html = html
                continuation.resume()
            }
        }
    }

    func revoke(_ id: UUID) {
        queue.async { [self] in
            guard let record = records.removeValue(forKey: id) else { return }
            paths.removeValue(forKey: record.mediaPath)
            paths.removeValue(forKey: record.playerPath)
            let active = connections.values.filter { $0.leaseID == id }
            active.forEach { finish($0) }
            if record.securityScoped { record.file.stopAccessingSecurityScopedResource() }
        }
    }

    private func startFailed(_ error: any Error) {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        port = nil
        let pending = starters
        starters.removeAll()
        pending.forEach { $0.resume(throwing: error) }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 64 else { connection.cancel(); return }
        let context = LocalMediaConnection(connection)
        connections[context.id] = context
        connection.stateUpdateHandler = { [weak self, weak context] state in
            guard let self, let context else { return }
            switch state {
            case .failed, .cancelled: self.finish(context)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(context)
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak context] in
            guard let self, let context, !context.headersComplete else { return }
            self.finish(context)
        }
    }

    private func receive(_ context: LocalMediaConnection) {
        context.connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak context] data, _, complete, error in
            guard let self, let context, !context.closed else { return }
            if let data { context.request.append(data) }
            guard context.request.count <= 16_384 else { self.respond(context, status: 431); return }
            if let boundary = context.request.range(of: Data("\r\n\r\n".utf8)) {
                context.headersComplete = true
                self.handle(context, header: context.request[..<boundary.lowerBound])
            } else if complete || error != nil { self.finish(context) }
            else { self.receive(context) }
        }
    }

    private func handle(_ context: LocalMediaConnection, header: Data.SubSequence) {
        guard let text = String(data: header, encoding: .utf8) else { respond(context, status: 400); return }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { respond(context, status: 400); return }
        let request = first.split(separator: " ", omittingEmptySubsequences: true)
        guard request.count == 3, request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0" else {
            respond(context, status: 400); return
        }
        let method = String(request[0])
        guard method == "GET" || method == "HEAD" else {
            respond(context, status: 405, extra: ["Allow": "GET, HEAD"]); return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { respond(context, status: 400); return }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { respond(context, status: 400); return }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let port, headers["host"] == "127.0.0.1:\(port)" else { respond(context, status: 403); return }
        let path = String(request[1])
        guard let id = paths[path], let record = records[id] else { respond(context, status: 404); return }
        context.leaseID = id
        if path == record.playerPath {
            guard let html = record.html else { respond(context, status: 404); return }
            respond(context, status: 200, type: "text/html; charset=utf-8", length: UInt64(html.count),
                    body: method == "HEAD" ? nil : html)
            return
        }
        let byteRange: ClosedRange<UInt64>
        do { byteRange = try Self.range(headers["range"], size: record.size) }
        catch {
            respond(context, status: 416, extra: ["Content-Range": "bytes */\(record.size)"])
            return
        }
        let length = byteRange.upperBound - byteRange.lowerBound + 1
        var extra = ["Accept-Ranges": "bytes"]
        let status = headers["range"] == nil ? 200 : 206
        if status == 206 { extra["Content-Range"] = "bytes \(byteRange.lowerBound)-\(byteRange.upperBound)/\(record.size)" }
        if method == "HEAD" {
            respond(context, status: status, type: record.mimeType, length: length, extra: extra)
            return
        }
        do {
            let handle = try FileHandle(forReadingFrom: record.file)
            try handle.seek(toOffset: byteRange.lowerBound)
            context.file = handle
            context.remaining = length
            let header = Self.responseHeader(status: status, type: record.mimeType, length: length, extra: extra)
            context.connection.send(content: header, completion: .contentProcessed { [weak self, weak context] error in
                guard let self, let context else { return }
                if error != nil { self.finish(context) }
                else { self.sendChunk(context) }
            })
        } catch { respond(context, status: 404) }
    }

    private func sendChunk(_ context: LocalMediaConnection) {
        guard !context.closed else { return }
        guard context.remaining > 0, let file = context.file else { finish(context); return }
        do {
            guard let data = try file.read(upToCount: Int(min(context.remaining, 65_536))), !data.isEmpty else {
                finish(context); return
            }
            context.remaining -= UInt64(data.count)
            context.connection.send(content: data, completion: .contentProcessed { [weak self, weak context] error in
                guard let self, let context else { return }
                if error != nil { self.finish(context) }
                else { self.sendChunk(context) }
            })
        } catch { finish(context) }
    }

    private func respond(_ context: LocalMediaConnection, status: Int, type: String = "text/plain",
                         length: UInt64 = 0, extra: [String: String] = [:], body: Data? = nil) {
        var data = Self.responseHeader(status: status, type: type, length: length, extra: extra)
        if let body { data.append(body) }
        context.connection.send(content: data, completion: .contentProcessed { [weak self, weak context] _ in
            guard let self, let context else { return }
            self.finish(context)
        })
    }

    private func finish(_ context: LocalMediaConnection) {
        guard !context.closed else { return }
        context.closed = true
        try? context.file?.close()
        context.file = nil
        context.connection.stateUpdateHandler = nil
        context.connection.cancel()
        connections.removeValue(forKey: context.id)
    }

    private static func responseHeader(status: Int, type: String, length: UInt64,
                                       extra: [String: String]) -> Data {
        let reason = switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        case 431: "Request Header Fields Too Large"
        default: "Error"
        }
        var result = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\n"
            + "Connection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
            + "Cross-Origin-Resource-Policy: same-origin\r\nReferrer-Policy: no-referrer\r\n"
        for (key, value) in extra.sorted(by: { $0.key < $1.key }) { result += "\(key): \(value)\r\n" }
        result += "\r\n"
        return Data(result.utf8)
    }

    private static func range(_ raw: String?, size: UInt64) throws -> ClosedRange<UInt64> {
        guard let raw else { return 0...(size - 1) }
        guard raw.hasPrefix("bytes="), !raw.contains(",") else { throw LocalMediaServerError.invalidFile }
        let bounds = raw.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { throw LocalMediaServerError.invalidFile }
        if bounds[0].isEmpty {
            guard let suffix = UInt64(bounds[1]), suffix > 0 else { throw LocalMediaServerError.invalidFile }
            return (suffix >= size ? 0 : size - suffix)...(size - 1)
        }
        guard let start = UInt64(bounds[0]), start < size else { throw LocalMediaServerError.invalidFile }
        let end: UInt64
        if bounds[1].isEmpty { end = size - 1 }
        else {
            guard let requested = UInt64(bounds[1]), requested >= start else { throw LocalMediaServerError.invalidFile }
            end = min(requested, size - 1)
        }
        return start...end
    }
}

private final class LocalMediaConnection: @unchecked Sendable {
    let id = UUID()
    let connection: NWConnection
    var leaseID: UUID?
    var request = Data()
    var headersComplete = false
    var closed = false
    var file: FileHandle?
    var remaining: UInt64 = 0

    init(_ connection: NWConnection) { self.connection = connection }
}
