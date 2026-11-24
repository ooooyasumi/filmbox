import AppKit
import Observation
import FilmboxCore

/// One focused photo request. A provisional bitmap stays useful while the
/// original is downloading or decoding; only the full-size request can finish it.
@MainActor @Observable
final class PhotoPreviewSession {
    enum State: Equatable { case loading, ready, failed, unavailable, idle }
    private(set) var thumbnail: Thumbnail?
    private(set) var state: State = .loading
    private struct Identity: Equatable {
        let id: String
        let url: URL
        let modifiedDate: Date
        let fileSize: Int64
        let revision: String?
    }
    @ObservationIgnored private var identity: Identity?
    @ObservationIgnored private var generation = 0

    func load(item: MediaItem,
              cached: @Sendable (MediaItem) async -> Thumbnail? = { item in
                  await ThumbnailService.shared.cachedThumbnail(for: item.url, kind: item.kind,
                      modifiedDate: item.modifiedDate, pixelSize: 768, localRevision: item.localRevision)
              },
              full: @Sendable (MediaItem) async -> ThumbnailLoadResult = { item in
                  await ThumbnailService.shared.loadThumbnail(for: item.url, kind: item.kind,
                      modifiedDate: item.modifiedDate, pixelSize: 4096, localRevision: item.localRevision)
              }) async {
        let nextIdentity = Identity(id: item.id, url: item.url, modifiedDate: item.modifiedDate,
                                    fileSize: item.fileSize, revision: item.contentRevision)
        if identity == nextIdentity, state == .ready { return }
        generation &+= 1
        let token = generation
        if identity != nextIdentity {
            let previousStamp = identity?.revision.map { String($0.prefix(while: { $0 != "|" })) }
            let retain = item.isLocal && identity?.id == item.id && identity?.fileSize == item.fileSize
                && previousStamp != nil && previousStamp == item.localFileStamp
            if !retain { thumbnail = nil }
            identity = nextIdentity
        }
        state = .loading
        defer {
            if token == generation, Task.isCancelled, state == .loading { state = .idle }
        }
        if thumbnail == nil, let small = await cached(item) {
            guard token == generation, !Task.isCancelled else { return }
            thumbnail = small
        }
        guard token == generation, !Task.isCancelled else { return }
        for attempt in 0..<3 {
            if attempt > 0 {
                do { try await Task.sleep(for: .milliseconds(attempt == 1 ? 250 : 800)) }
                catch { return }
            }
            let result = await full(item)
            guard token == generation, !Task.isCancelled else { return }
            switch result {
            case .ready(let highResolution):
                thumbnail = highResolution
                state = .ready
                return
            case .unavailable: state = .unavailable; return
            case .cancelled: state = .idle; return
            case .noCloudPreview: state = .failed; return
            case .failed: break
            }
            if let accountID = item.cloud?.accountID,
               CloudTransferCenter.shared.issue(for: accountID) != nil {
                state = .unavailable
                return
            }
        }
        state = .failed
    }

    /// Invalidate late results while retaining the provisional image. The owner
    /// also cancels the Task running load so cancellation reaches its download
    /// consumer; invalidating presentation alone does not stop shared work.
    func cancel() {
        generation &+= 1
        if state == .loading { state = .idle }
    }
}

/// Presentation follows both the viewer's decode and the original transfer.
/// A completed download alone is not a decoded, visible high-resolution image.
struct PhotoPreviewFeedback: Equatable {
    enum Kind: Equatable { case loading, failed, login }
    let kind: Kind
    let title: String
    var progress: Double?
    var problem: ResourceProblem? = nil

    static func resolve(state: PhotoPreviewSession.State, item: MediaItem, isOffline: Bool,
                        original: CloudTransferSnapshot?, needsLogin: Bool) -> Self? {
        if state == .ready { return nil }
        if state == .idle { return nil }
        // A local read cannot inherit cloud progress or authentication. An
        // unknown transfer is loading, never evidence of a network download.
        let isCloud = item.cloud != nil && !item.url.isFileURL
        let original = isCloud && original?.itemID == item.id && original?.purpose == .original ? original : nil
        if isCloud && needsLogin && original?.isOriginalCached != true {
            return Self(kind: .login, title: MediaFailureText.login)
        }
        if state == .failed || state == .unavailable {
            let problem: ResourceProblem? = isCloud ? ResourceProblem(code: original?.errorCode) : (isOffline ? .offline : .unsupported)
            return Self(kind: .failed, title: isCloud ? problem?.title ?? MediaFailureText.failed : MediaFailureText.title(for: item, isOffline: isOffline), problem: problem)
        }
        if !isCloud { return Self(kind: .loading, title: MediaLoadingText.loading) }
        if original?.isOriginalCached == true || original?.state == .ready {
            return Self(kind: .loading, title: MediaLoadingText.loading)
        }
        switch original?.state {
        case .queued:
            return Self(kind: .loading, title: MediaLoadingText.waiting)
        case .paused:
            return Self(kind: .loading, title: MediaLoadingText.paused)
        case .downloading:
            return Self(kind: .loading, title: MediaLoadingText.downloading, progress: original?.progress)
        default:
            return Self(kind: .loading, title: MediaLoadingText.loading)
        }
    }
}

/// A transfer deserves feedback; a routine disk decode does not. Failures and
/// login requests remain actionable for local, cached and remote media alike.
extension PhotoPreviewFeedback {
    static func presentation(state: PhotoPreviewSession.State, item: MediaItem, isOffline: Bool,
                             original: CloudTransferSnapshot?, needsLogin: Bool) -> Self? {
        guard let feedback = resolve(state: state, item: item, isOffline: isOffline, original: original, needsLogin: needsLogin) else { return nil }
        if feedback.kind == .loading {
            guard !item.isLocal, item.cloud != nil,
                  !(original?.itemID == item.id && original?.purpose == .original && (original?.isOriginalCached == true || original?.state == .ready)) else { return nil }
        }
        return feedback
    }
}
