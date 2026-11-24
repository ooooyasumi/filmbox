import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import FilmboxCore

/// Run only inside the temporary bundle created by check-cloud-preview.sh.
/// The DEBUG cache override keeps the shared resolver away from user data.
@main @MainActor struct CloudPreviewChecks {
    private struct Failure: Error { let message: String }
    private static var passed = 0
    private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }; passed += 1
    }
    static func main() async {
        do {
            guard let path = Bundle.main.object(forInfoDictionaryKey: "FilmboxDevelopmentCache") as? String,
                  normalizedTemporaryPath(path).hasPrefix(normalizedTemporaryPath(FileManager.default.temporaryDirectory.path)),
                  URL(fileURLWithPath: path).lastPathComponent == "isolated-cache" else {
                throw Failure(message: "missing isolated DEBUG cache override; refusing shared-cache access")
            }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            let rawDirectory = directory.appendingPathComponent("cloud-assets", isDirectory: true)
            let pixels = Data(repeating: 130, count: 24 * 16 * 4)
            let provider = CGDataProvider(data: pixels as CFData)!
            let image = CGImage(width: 24, height: 16, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 24 * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
            let png = NSMutableData()
            let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            try expect(CGImageDestinationFinalize(destination), "synthetic PNG could not be written")
            let account = UUID(), date = Date(timeIntervalSince1970: 1_700_000_000)
            let item = MediaItem(cloud: CloudMediaReference(accountID: account, fileID: "cover-only", parentID: "/", remotePath: "/cover-only.png", revision: "r1"),
                kind: .image, fileSize: Int64(png.length), modifiedDate: date, createdDate: date)
            let identity = "\(item.id)|r1|\(item.fileSize)|\(date.timeIntervalSinceReferenceDate)|thumbnail"
            let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            try FileManager.default.createDirectory(at: rawDirectory, withIntermediateDirectories: true)
            try (png as Data).write(to: rawDirectory.appendingPathComponent(digest).appendingPathExtension("preview"))
            CloudMediaRegistry.shared.register([item])
            CloudTransferCenter.shared.requireLogin(accountID: account)
            defer { CloudTransferCenter.shared.forgetConnection(accountID: account) }
            let cover = try await ThumbnailDecoder.cloudPreview(item: item, pixelSize: 768)
            try expect(cover?.width == 24 && cover?.height == 16, "provider cover was not truly usable offline")
            do {
                _ = try await ThumbnailDecoder.cloudPreview(item: item, pixelSize: 4096)
                throw Failure(message: "high-resolution decoder silently succeeded with the small provider cover")
            } catch CloudConnectionError.credentialsMissing { passed += 1 }
            let service = ThumbnailService(cacheDirectory: directory.appendingPathComponent("isolated-thumbs", isDirectory: true))
            let high = await service.loadThumbnail(for: item.url, kind: .image, modifiedDate: date, pixelSize: 4096)
            if case .ready = high { throw Failure(message: "high-resolution service reported cover fallback as ready") }
            passed += 1
            try expect(await service.cachedThumbnail(for: item.url, kind: .image, modifiedDate: date, pixelSize: 4096) == nil,
                "failed original persisted a cover under the high-resolution key")
            let lower = await service.loadThumbnail(for: item.url, kind: .image, modifiedDate: date, pixelSize: 768)
            guard case .ready = lower else { throw Failure(message: "high-resolution failure broke ordinary offline cover browsing") }
            passed += 1
            try expect(await MediaAssetResolver.shared.cachedOriginalIDs(for: [item]).isEmpty, "provider cover counted as a downloaded original")
            await CloudGateway.shared.shutdown()
            print("\(passed) cloud-preview checks passed; isolated raw cover, no original, network or user cache")
        } catch { print("FAILED after \(passed): \(error)"); exit(1) }
    }
    private static func normalizedTemporaryPath(_ path: String) -> String {
        // Foundation may present the macOS /var alias while Python resolves the
        // same temporary directory through /private/var.
        path.hasPrefix("/private/var/") ? String(path.dropFirst(8)) : path
    }
}
