import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import FilmboxCore

/// The script supplies an isolated DEBUG cache and a loopback-only WebDAV. No
/// existing account, catalogue, user media or production cache is consulted.
@main @MainActor struct FocusedDownloadChecks {
    private struct Failure: Error { let message: String }
    private struct Request: Decodable { let bytes: Int64; let closed: Bool; let complete: Bool }
    private struct Stats: Decodable { let size: Int64; let files: [String: [Request]] }
    private static var passed = 0
    private static let date = Date(timeIntervalSince1970: 1_700_000_000)
    private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }; passed += 1
    }
    static func main() async {
        let accountID = UUID()
        var failure: Error?
        do {
            guard let endpoint = URL(string: CommandLine.arguments[1]), endpoint.host == "127.0.0.1",
                  let cache = Bundle.main.object(forInfoDictionaryKey: "FilmboxDevelopmentCache") as? String,
                  normalizedTemporaryPath(cache).hasPrefix(normalizedTemporaryPath(FileManager.default.temporaryDirectory.path)),
                  URL(fileURLWithPath: cache).lastPathComponent == "isolated-cache" else {
                throw Failure(message: "missing isolated cache or loopback fixture")
            }
            _ = try await CloudGateway.shared.connect(provider: .webdav, credential: "",
                endpoint: endpoint.appendingPathComponent("dav/").absoluteString,
                username: "filmbox", password: "focused-download-fixture", accountID: accountID)
            let size = try await stats(endpoint).size
            func photo(_ name: String) -> MediaItem {
                MediaItem(cloud: CloudMediaReference(accountID: accountID, fileID: "/\(name).png", parentID: "/",
                    remotePath: "/\(name).png", revision: "focus-r1"), kind: .image, fileSize: size,
                    modifiedDate: date, createdDate: date, pixelWidth: 1600, pixelHeight: 1000)
            }
            let first = photo("first"), next = photo("next"), shared = photo("shared"), returned = photo("returned")
            let rapid = photo("rapid"), direct = photo("direct")
            let all = [first, next, shared, returned, rapid, direct]
            CloudMediaRegistry.shared.register(all)
            try seedCovers(all, root: URL(fileURLWithPath: cache))
            let service = ThumbnailService.shared
            let cover = await service.loadThumbnail(for: first.url, kind: .image, modifiedDate: date, pixelSize: 768)
            try expect(width(cover) == 24, "the provisional cover fixture was not used")
            try expect(try await stats(endpoint).files.isEmpty, "cover browsing downloaded an original")

            let firstJob = high(first)
            try await wait(endpoint) { $0.files[first.name]?.last?.bytes ?? 0 > 0 }
            let cancelledAt = ContinuousClock.now
            firstJob.cancel()
            let nextJob = high(next)
            try await wait(endpoint) { value in
                value.files[first.name]?.last?.closed == true && (value.files[next.name]?.last?.bytes ?? 0) > 0
            }
            let cancellationLatency = cancelledAt.duration(to: .now)
            try expect(cancellationLatency < .seconds(1.5), "leaving a photo did not promptly stop its HTTP body and start the next")
            let afterCancel = try await stats(endpoint)
            try expect(afterCancel.files[first.name]?.last?.complete == false, "the abandoned original was downloaded completely")
            try expect((afterCancel.files[first.name]?.last?.bytes ?? size) < size / 2, "abandoned original consumed most of the file")
            guard case .cancelled = await firstJob.value else { throw Failure(message: "abandoned high-resolution consumer did not cancel") }
            passed += 1
            try expect(CloudTransferCenter.shared.snapshot(for: first.id)?.state == .idle,
                "leaving the photo displayed a download failure instead of cancellation")
            let original = await nextJob.value
            try expect(width(original) == 1600, "the new focused photo did not replace its small cover with original pixels")
            let cachedIDs = await MediaAssetResolver.shared.cachedOriginalIDs(for: [first, next])
            try expect(cachedIDs == [next.id], "cancelled original counted as complete, or completed original was not retained")
            let beforeHit = try await stats(endpoint)
            try expect(width(await high(next).value) == 1600, "a downloaded original returned only a thumbnail")
            try expect(try await stats(endpoint).files[next.name]?.count == beforeHit.files[next.name]?.count,
                "returning to a completed original opened another network body")

            // The roll acquires its raw original before entering a decode slot.
            // Exercise that direct resolver consumer independently of the
            // thumbnail-service cancellation path tested above.
            let directJob = Task { try await MediaAssetResolver.shared.originalFile(for: direct) }
            try await wait(endpoint) { $0.files[direct.name]?.last?.bytes ?? 0 > 0 }
            let directCancelledAt = ContinuousClock.now
            directJob.cancel()
            do { _ = try await directJob.value; throw Failure(message: "direct focused original did not cancel") }
            catch is CancellationError { passed += 1 }
            try await wait(endpoint) { $0.files[direct.name]?.last?.closed == true }
            try expect(directCancelledAt.duration(to: .now) < .seconds(1.5), "direct focused original retained its HTTP body after leaving")
            try expect(try await stats(endpoint).files[direct.name]?.last?.complete == false, "direct abandoned original downloaded completely")
            try expect(await MediaAssetResolver.shared.cachedOriginalIDs(for: [direct]).isEmpty, "direct cancelled original remained marked complete")
            try expect(width(await high(direct).value) == 1600, "direct cancelled photo could not later download and decode its original")

            // Two UI consumers coalesce. Losing one must not cancel the viewer
            // that still needs the same original or make a duplicate download.
            let one = high(shared)
            try await wait(endpoint) { $0.files[shared.name]?.last?.bytes ?? 0 > 0 }
            let two = high(shared)
            try await Task.sleep(for: .milliseconds(40))
            one.cancel()
            try expect(width(await two.value) == 1600, "cancelling one coalesced consumer interrupted the other")
            guard case .cancelled = await one.value else { throw Failure(message: "cancelled coalesced consumer remained ready") }
            passed += 1
            try expect(try await stats(endpoint).files[shared.name]?.count == 1, "coalesced consumers downloaded the original twice")

            // An explicit download is a separate resolver consumer. A departed
            // scroll viewer must never cancel the user's still-running request.
            let viewed = high(returned)
            try await wait(endpoint) { $0.files[returned.name]?.last?.bytes ?? 0 > 0 }
            let explicit = Task { try await MediaAssetResolver.shared.originalFile(for: returned) }
            try await Task.sleep(for: .milliseconds(40))
            viewed.cancel()
            let kept = try await explicit.value
            try expect(FileManager.default.fileExists(atPath: kept.path), "viewer cancellation removed an explicit download's completed cache")
            try expect(width(await high(returned).value) == 1600, "returning after another consumer finished did not display the cached original")
            try expect(try await stats(endpoint).files[returned.name]?.count == 1, "explicit and viewing consumers failed to share the same original")

            // Re-enter while old cancellation callbacks are still in flight.
            // A surviving/replacement request must remain independent of them.
            let outgoing = high(rapid)
            try await wait(endpoint) { $0.files[rapid.name]?.last?.bytes ?? 0 > 0 }
            outgoing.cancel()
            let incoming = high(rapid)
            try expect(width(await incoming.value) == 1600, "rapidly returning to the same photo inherited stale cancellation")
            guard case .cancelled = await outgoing.value else { throw Failure(message: "outgoing rapid consumer was not cancelled") }
            passed += 1
            let rapidRequests = try await stats(endpoint).files[rapid.name] ?? []
            try expect((1...2).contains(rapidRequests.count) && rapidRequests.last?.complete == true,
                "rapid refocus duplicated work or cancelled its replacement")

            // A previously cancelled original can be focused again immediately.
            try expect(width(await high(first).value) == 1600, "refocusing a previously cancelled original rejoined stale cancelled work")
            try expect(try await stats(endpoint).files[first.name]?.count == 2, "refocused original was not downloaded afresh exactly once")
            try expect(await MediaAssetResolver.shared.cachedOriginalIDs(for: all) == Set(all.map(\.id)), "fully completed originals did not survive focus changes")
            let files = FileManager.default.enumerator(at: URL(fileURLWithPath: cache), includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            try expect(!files.contains { $0.pathExtension == "partial" }, "cancelled/completed work left staging files")
            print("✓ Real HTTP focus change: \(cancellationLatency); initial abandoned body \(afterCancel.files[first.name]?.last?.bytes ?? 0)/\(size) bytes")
        } catch { failure = error }
        try? await CloudGateway.shared.forget(accountID: accountID)
        await CloudGateway.shared.shutdown()
        if let failure { print("FAILED after \(passed): \(failure)"); exit(1) }
        print("\(passed) focused-download checks passed; temporary account, helper and cache isolated")
    }
    private static func high(_ item: MediaItem) -> Task<ThumbnailLoadResult, Never> {
        Task { await ThumbnailService.shared.loadThumbnail(for: item.url, kind: .image, modifiedDate: item.modifiedDate, pixelSize: 4096) }
    }
    private static func normalizedTemporaryPath(_ path: String) -> String {
        path.hasPrefix("/private/var/") ? String(path.dropFirst(8)) : path
    }
    private static func width(_ result: ThumbnailLoadResult) -> Int? {
        guard case let .ready(value) = result else { return nil }
        return value.image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width
    }
    private static func stats(_ endpoint: URL) async throws -> Stats {
        let (data, _) = try await URLSession.shared.data(from: endpoint.appendingPathComponent("stats"))
        return try JSONDecoder().decode(Stats.self, from: data)
    }
    private static func wait(_ endpoint: URL, _ condition: (Stats) -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(try await stats(endpoint)) {
            guard ContinuousClock.now < deadline else { throw Failure(message: "slow WebDAV request state timed out") }
            try await Task.sleep(for: .milliseconds(15))
        }
    }
    private static func seedCovers(_ items: [MediaItem], root: URL) throws {
        let pixels = Data(repeating: 130, count: 24 * 16 * 4)
        let image = CGImage(width: 24, height: 16, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 24 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        let directory = root.appendingPathComponent("cloud-assets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for item in items {
            let identity = "\(item.id)|focus-r1|\(item.fileSize)|\(date.timeIntervalSinceReferenceDate)|thumbnail"
            let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            let target = directory.appendingPathComponent(digest).appendingPathExtension("preview")
            guard let output = CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw Failure(message: "cover write failed") }
            CGImageDestinationAddImage(output, image, nil)
            guard CGImageDestinationFinalize(output) else { throw Failure(message: "cover finalize failed") }
        }
    }
}
