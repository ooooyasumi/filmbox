import AppKit
import SwiftUI
import FilmboxCore

@MainActor
struct AsyncThumbnail: View {
    let item: MediaItem
    let pixelSize: Int
    let contentMode: ContentMode

    @State private var thumbnail: Thumbnail?
    @State private var loadedID: RequestID?
    @State private var completedID: RequestID?
    @State private var loading = true
    @State private var noCloudPreview = false
    @State private var retryGeneration = 0
    @State private var activeRequest: UUID?

    init(item: MediaItem, pixelSize: Int = 512, contentMode: ContentMode = .fill) {
        self.item = item
        self.pixelSize = pixelSize
        self.contentMode = contentMode
    }

    private struct RequestID: Hashable {
        let url: URL
        let modifiedDate: Date
        let fileSize: Int64
        let pixelSize: Int
        let revision: String?
    }

    private struct TaskID: Hashable { let request: RequestID; let retry: Int; let requiresLogin: Bool }
    private var connectionIssue: CloudAccountIssue? {
        item.cloud.flatMap { CloudTransferCenter.shared.issue(for: $0.accountID) }
    }
    private var taskID: TaskID { TaskID(request: requestID, retry: retryGeneration, requiresLogin: connectionIssue != nil) }
    private var placeholder: MediaPlaceholderFeedback {
        MediaPlaceholderFeedback.resolve(item: item, loading: loading, noPreview: noCloudPreview, needsLogin: connectionIssue != nil)
    }
    private var requestID: RequestID {
        RequestID(url: item.url, modifiedDate: item.modifiedDate, fileSize: item.fileSize, pixelSize: pixelSize, revision: item.contentRevision)
    }

    private var canRetainVerifiedPreview: Bool {
        guard item.isLocal, let previous = loadedID?.revision, let current = item.localFileStamp else { return false }
        return loadedID?.url == item.url && loadedID?.fileSize == item.fileSize
            && String(previous.prefix(while: { $0 != "|" })) == current
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.primary.opacity(0.035)
                if loadedID?.url == requestID.url, (loadedID?.modifiedDate == requestID.modifiedDate && loadedID?.revision == requestID.revision || loading && canRetainVerifiedPreview), let thumbnail {
                    Image(nsImage: thumbnail.image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    if placeholder.spins {
                        ProgressView().controlSize(.small).tint(.secondary)
                    } else {
                    Image(systemName: placeholder.symbol)
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                        .help(placeholder.title)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .overlay(alignment: .topLeading) {
                if !item.isLocal, geometry.size.width >= 70 {
                    CloudAssetBadge(item: item, loading: loading, failed: !loading && !noCloudPreview && thumbnail == nil)
                        .padding(7)
                }
            }
            .animation(.easeOut(duration: 0.18), value: loadedID)
        }
        .accessibilityHidden(true)
        .task(id: taskID) {
            guard !Task.isCancelled else { return }
            let token = UUID()
            activeRequest = token
            loading = true
            noCloudPreview = false
            // Show a previously viewed small preview while a viewer-size image
            // loads. Cached media remain visible even with the original offline.
            if thumbnail == nil || loadedID?.url != item.url || loadedID?.modifiedDate != item.modifiedDate || loadedID?.revision != item.cloud?.revision {
                if !canRetainVerifiedPreview { thumbnail = nil }
                if let cached = await ThumbnailService.shared.cachedThumbnail(for: item.url, kind: item.kind, modifiedDate: item.modifiedDate, pixelSize: min(pixelSize, 768), localRevision: item.localRevision) {
                    guard !Task.isCancelled, activeRequest == token else { return }
                    thumbnail = cached
                    loadedID = requestID
                }
            }
            for attempt in 0..<3 {
                if attempt > 0 {
                    do { try await Task.sleep(for: .milliseconds(attempt == 1 ? 250 : 800)) } catch { return }
                }
                let result = await ThumbnailService.shared.loadThumbnail(for: item.url, kind: item.kind, modifiedDate: item.modifiedDate, pixelSize: pixelSize, localRevision: item.localRevision)
                guard !Task.isCancelled, activeRequest == token else { return }
                switch result {
                case .ready(let image):
                    thumbnail = image
                    loadedID = requestID
                    completedID = requestID
                    loading = false
                    return
                case .cancelled:
                    loading = false
                    return
                case .unavailable:
                    loading = false
                    return
                case .noCloudPreview:
                    if CloudTransferCenter.shared.snapshot(for: item.id)?.isOriginalCached == true, attempt < 2 { continue }
                    noCloudPreview = true
                    completedID = requestID
                    loading = false
                    return
                case .failed: break
                }
                // Authentication is an account state, not a per-image retry.
                // Keep an existing cached image and stop the retry delay now.
                if connectionIssue != nil {
                    loading = false
                    return
                }
            }
            loading = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if connectionIssue == nil && completedID != requestID && !loading { retryGeneration += 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FilmboxPreviewRetry"))) { _ in
            if connectionIssue == nil && (completedID != requestID || noCloudPreview) && !loading { retryGeneration += 1 }
        }
        .onChange(of: CloudTransferCenter.shared.snapshot(for: item.id)?.isOriginalCached == true) { _, cached in
            if cached { retryGeneration += 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .filmboxCloudOriginalPreviewReady)) { notification in
            guard notification.userInfo?["id"] as? String == item.id,
                  notification.userInfo?["revision"] as? String == item.cloud?.revision,
                  notification.userInfo?["fileSize"] as? Int64 == item.fileSize,
                  notification.userInfo?["modifiedDate"] as? Date == item.modifiedDate else { return }
            retryGeneration += 1
        }
        .onChange(of: CloudTransferCenter.shared.snapshot(for: item.id, purpose: .thumbnail)?.state == .ready) { _, ready in
            if ready, thumbnail == nil { retryGeneration += 1 }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            // An offline lower-res preview can now be upgraded without scrolling
            // it offscreen first; adequate cache entries still return immediately.
            retryGeneration += 1
        }
        .onDisappear {
            // Lazy containers retain state after a cell leaves the screen.
            // Releasing this reference lets the shared cache enforce its limit;
            // SwiftUI starts the task again when the cell reappears.
            activeRequest = nil
            thumbnail = nil
            loadedID = nil
            completedID = nil
            loading = true
        }
    }
}
