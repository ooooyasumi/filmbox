import AppKit
import Observation
import FilmboxCore

/// The roll owns one full-size photo, independently of its reusable thumbnail
/// cells. Leaving the focus cancels its consumer and releases the large bitmap.
@MainActor @Observable
final class BrowsePhotoPreview {
    private(set) var currentID: String?
    private(set) var preview: PhotoPreviewSession?
    @ObservationIgnored private var item: MediaItem?
    @ObservationIgnored private var identity: Identity?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var viewingLease: UUID?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let cached: @Sendable (MediaItem) async -> Thumbnail?
    @ObservationIgnored private let full: @Sendable (MediaItem) async -> ThumbnailLoadResult

    private struct Identity: Equatable {
        let id: String
        let url: URL
        let modifiedDate: Date
        let fileSize: Int64
        let revision: String?
        init(_ item: MediaItem) {
            id = item.id; url = item.url; modifiedDate = item.modifiedDate
            fileSize = item.fileSize; revision = item.contentRevision
        }
    }

    init(cached: @escaping @Sendable (MediaItem) async -> Thumbnail? = { item in
        await ThumbnailService.shared.cachedThumbnail(for: item.url, kind: item.kind,
            modifiedDate: item.modifiedDate, pixelSize: 768, localRevision: item.localRevision)
    }, full: @escaping @Sendable (MediaItem) async -> ThumbnailLoadResult = { item in
        // Acquire the focused original before the decode queue. Nearby cover
        // work must not occupy every decode slot while this download waits;
        // a cached display bitmap alone also does not imply a cached original.
        if !item.isLocal {
            do { _ = try await MediaAssetResolver.shared.originalFile(for: item) }
            catch {
                if Task.isCancelled || error is CancellationError { return .cancelled }
                if let cloud = item.cloud, CloudTransferCenter.shared.issue(for: cloud.accountID) != nil { return .unavailable }
                return .failed
            }
        }
        guard !Task.isCancelled else { return .cancelled }
        return await ThumbnailService.shared.loadThumbnail(for: item.url, kind: item.kind,
            modifiedDate: item.modifiedDate, pixelSize: 4096, localRevision: item.localRevision)
    }) {
        self.cached = cached; self.full = full
    }

    func update(item: MediaItem?, enabled: Bool) {
        guard enabled, let item, item.kind == .image else { stop(); return }
        guard identity != Identity(item) else { return }
        stop()
        self.item = item; identity = Identity(item); currentID = item.id
        let session = PhotoPreviewSession()
        preview = session
        let token = generation
        preparation = Task { [weak self, cached, full] in
            // Local decoded photos need no cloud-file eviction protection.
            if !item.isLocal {
                let lease = await MediaAssetResolver.shared.acquireViewingLease(for: item)
                guard let self, self.generation == token, !Task.isCancelled else {
                    await MediaAssetResolver.shared.releaseViewingLease(lease)
                    return
                }
                self.viewingLease = lease
            }
            guard !Task.isCancelled else { return }
            await session.load(item: item, cached: cached, full: full)
            if let self, self.generation == token { self.preparation = nil }
        }
    }

    func retry() {
        guard let item else { return }
        stop()
        update(item: item, enabled: true)
    }

    func stop() {
        guard identity != nil || preparation != nil || preview != nil else { return }
        generation &+= 1
        preparation?.cancel(); preparation = nil
        preview?.cancel(); preview = nil
        currentID = nil; identity = nil; item = nil
        if let viewingLease {
            self.viewingLease = nil
            Task { await MediaAssetResolver.shared.releaseViewingLease(viewingLease) }
        }
    }
}

/// Nearest neighbours first; never prefetch an original for a nearby photo.
enum BrowseThumbnailNeighborhood {
    static func indexes(center: Int, count: Int, radius: Int = 4) -> [Int] {
        guard count > 0, (0..<count).contains(center) else { return [] }
        var result = [center]
        for distance in 1...max(1, radius) where distance <= radius {
            if center + distance < count { result.append(center + distance) }
            if center - distance >= 0 { result.append(center - distance) }
        }
        return result
    }
}
