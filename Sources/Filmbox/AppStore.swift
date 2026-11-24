import AppKit
import Darwin
import Observation
import SwiftUI
import FilmboxCore

/// Document-space extents shared by the grid and its date ruler.
struct TimelineDateSpan: Equatable {
    let id: String
    let start: Double
    let length: Double
}

@MainActor protocol GridBrowsePositionProviding: AnyObject {
    func browseTransitionTargetID() -> String?
}

// One catalog, one window. File changes require explicit rename/trash actions.
@MainActor @Observable
final class AppStore {
    enum Scope: Equatable { case all, favorites, folders, hidden, album(UUID) }
    enum MediaFilter: String, CaseIterable { case all = "全部", image = "照片", video = "视频" }
    enum SourceFilter: String, CaseIterable { case all = "全部", local = "本地", cloud = "云端" }
    enum OriginalDownloadFilter: String, CaseIterable { case all = "全部", downloaded = "已下载", notDownloaded = "未下载" }
    enum SortOrder: String, CaseIterable {
        case captured = "拍摄时间", created = "创建时间", modified = "修改时间", name = "名称", size = "文件大小"
    }
    enum Layout: String, CaseIterable { case grid = "时间线", browse = "翻阅" }

    var libraries: [MediaLibrary] = []
    var cloudAccounts: [CloudAccount] = []
    var showCloudConnection = false
    var reconnectCloudAccount: CloudAccount?
    var items: [MediaItem] = [] {
        didSet {
            if !applyingMetadataPatch {
                metadataItemIndexDirty = true
                originalCacheItemsRevision &+= 1
                refreshOriginalDownloadStatus()
            }
            let count = max(0, items.count - excludedDotItemCount)
            if indexedItemCount != count { indexedItemCount = count }
        }
    }
    private var excludedDotItemCount = 0
    private(set) var indexedItemCount = 0
    private(set) var mediaMetadataRevision = 0
    var folders: [MediaFolder] = []
    var visibleItems: [MediaItem] = [] {
        didSet {
            if !applyingMetadataPatch {
                visibleIndexByID = Dictionary(visibleItems.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
            }
        }
    }
    var visibleRevision = 0
    var timelineSections: [TemporalSection] = [] {
        didSet { if !applyingMetadataPatch { metadataSectionIndexDirty = true } }
    }
    var timelineRevision = 0
    var scrollTargetID: String?
    var scrollTargetFraction: Double = 0
    var scrollRequestID = 0
    var visibleTimelineSectionID: String?
    var folderCounts: [String: Int] = [:]
    var childFolders: [String: [MediaFolder]] = [:]
    var favorites: Set<String> = []
    var hiddenIDs: Set<String> = []
    var albums: [MediaAlbum] = []
    var selectedIDs: Set<String> = []
    private(set) var isSelectionMode = false
    private(set) var selectionModeRevision = 0
    var selectionAnchor: String?
    var keyboardCursor: String?
    var scope: Scope = .all
    var directorySelection = DirectorySelection()
    var filter: MediaFilter = .all {
        didSet {
            if !updatingMediaFilters {
                clearOriginalFilterDeferrals()
                applyFilters()
            }
        }
    }
    private(set) var sourceFilter: SourceFilter = .all
    private(set) var originalDownloadFilter: OriginalDownloadFilter = .all
    private(set) var selectedFormats: Set<String> = []
    private(set) var availableFormats: [String] = []
    private(set) var isCheckingOriginalCache = false
    private(set) var hasLoadedOriginalCache = false
    var activeFilterCount: Int {
        (filter == .all ? 0 : 1) + (sourceFilter == .all ? 0 : 1)
            + (selectedFormats.isEmpty ? 0 : 1) + (originalDownloadFilter == .all ? 0 : 1)
    }
    var hasActiveFilters: Bool { activeFilterCount > 0 }
    var sort: SortOrder = .captured { didSet { applyFilters() } }
    var descending = true { didSet { applyFilters() } }
    var query = "" { didSet { clearOriginalFilterDeferrals(); applyFilters() } }
    var layout: Layout = .grid {
        didSet {
            guard layout != oldValue else { return }
            // Read native geometry before SwiftUI dismantles the outgoing grid.
            // Its last published timeline anchor describes the top edge, not
            // necessarily the selected photo or the middle of the viewport.
            let gridTarget = layout == .browse ? gridBrowsePositionProvider?.browseTransitionTargetID() : nil
            gridPreviewID = nil
            if layout != .browse, originalFilterBrowsePinnedID != nil {
                originalFilterBrowsePinnedID = nil
                if let previewID, let item = cachedMediaItem(id: previewID), !matchesOriginalDownloadState(item) {
                    originalFilterRefreshDeferred = true
                }
                if !isTerminating { applyFilters() }
            }
            if layout == .grid, visibleItems.indices.contains(browseIndex) {
                let id = visibleItems[browseIndex].id
                scrollTargetID = id
                gridTimelineScrollTarget = nil
                scrollTargetFraction = gridViewportAnchorID == id ? gridViewportAnchorFraction : 0
                navigationAnchorID = id
                scrollRequestID += 1
            }
            if layout == .browse {
                if let id = gridTarget ?? navigationAnchorID ?? keyboardCursor ?? selectionAnchor ?? selectedItems.first?.id,
                   let index = visibleItems.firstIndex(where: { $0.id == id }) { browseIndex = index }
                browsePosition = Double(browseIndex)
                browseScrollRequestID += 1
                if visibleItems.indices.contains(browseIndex) {
                    let id = visibleItems[browseIndex].id
                    keyboardCursor = id
                    if !isSelectionMode, !selectedIDs.isEmpty {
                        selectedIDs = [id]
                        selectionAnchor = id
                    }
                }
            }
        }
    }
    var showInspector = false
    var showViewerInspector = false
    var previewID: String? {
        didSet {
            guard previewID == nil, oldValue != nil, originalFilterRefreshDeferred else { return }
            originalFilterRefreshDeferred = false
            if !isTerminating { applyFilters() }
        }
    }
    // Explicit open actions must also raise an existing viewer, including
    // reopening the same file. Internal navigation only changes previewID.
    private(set) var viewerOpenRequestID = 0
    var browseIndex = 0
    var browsePosition: Double = 0
    private(set) var browseScrollRequestID = 0
    private(set) var navigationAnchorID: String?
    private(set) var gridDateSpans: [TimelineDateSpan] = []
    private(set) var gridTimelinePosition: Double = 0
    private(set) var gridTimelineTotalLength: Double = 0
    private(set) var gridTimelineScrollTarget: Double?
    private(set) var gridTimelineScrollRequestID = 0
    @ObservationIgnored weak var gridBrowsePositionProvider: (any GridBrowsePositionProviding)?
    private var gridViewportAnchorID: String?
    private var gridViewportAnchorFraction: Double = 0
    var gridPreviewID: String?
    // Sound is opt-in for each app session, and shared across the photo roll.
    var browseVideoMuted = true
    var isScanning = false
    var cloudIndexProgress: [UUID: CloudIndexProgress] = [:]

    enum CanvasIndexActivity: Equatable {
        struct Counts: Equatable { let photos: Int; let videos: Int }
        case local, cloud(Counts?), mixed
        var title: String {
            switch self {
            case .cloud: "正在建立云端索引…"
            case .local, .mixed: "正在整理资源库…"
            }
        }
        var detail: String? {
            guard case .cloud(let counts?) = self else { return nil }
            return "已找到 \(counts.photos.formatted()) 张照片、\(counts.videos.formatted()) 个视频"
        }
    }
    /// Canvas feedback belongs to the current scope. The footer deliberately
    /// keeps reporting global work, including jobs running in other libraries.
    var canvasIndexActivity: CanvasIndexActivity? {
        switch scope {
        case .favorites, .hidden, .album: return nil
        case .all, .folders: break
        }
        var local = false
        var cloud: [CloudIndexProgress] = []
        var countsAreScoped = true
        for library in libraries {
            let state = scope == .all ? FolderSelectionState.all : directorySelection.state(for: library.selectionPath)
            guard state != .none else { continue }
            if library.isLocal {
                if sourceFilter != .cloud && localScanInProgress && localScanLibraryIDs.contains(library.id) { local = true }
            } else if sourceFilter != .local, let progress = cloudIndexProgress[library.id], progress.phase == .indexing {
                cloud.append(progress)
                if state != .all { countsAreScoped = false }
            }
        }
        if local { return cloud.isEmpty ? .local : .mixed }
        guard !cloud.isEmpty else { return nil }
        let counts = countsAreScoped ? CanvasIndexActivity.Counts(
            photos: cloud.reduce(0) { $0 + $1.photos }, videos: cloud.reduce(0) { $0 + $1.videos }) : nil
        return .cloud(counts)
    }
    var isPerformingFileOperation = false
    var offlineLibraries: Set<UUID> = []
    var notice: String?
    var errorMessage: String?
    var pendingRemoval: MediaLibrary?
    var showAbout = false
    var showAddLibrary = false
    var showShortcuts = false
    var scanWarnings: [String] = []
    var thumbnailSize: Double = min(280, max(64, UserDefaults.standard.object(forKey: "thumbnailSize") as? Double ?? 180)) {
        didSet {
            UserDefaults.standard.set(thumbnailSize, forKey: "thumbnailSize")
            if TimelineScale(targetRowHeight: oldValue) != timelineScale { applyFilters() }
            else { timelineRevision += 1 }
        }
    }
    var timelineScale: TimelineScale { TimelineScale(targetRowHeight: thumbnailSize) }
    var timelineScaleLabel: String {
        switch timelineScale { case .day: "天"; case .week: "周"; case .month: "月" }
    }
    // The roll fits media to the viewport. Its independent zoom changes only
    // the date ruler, without rebuilding the media order or grid layout.
    var browseTimelineSize: Double = min(280, max(64, UserDefaults.standard.object(forKey: "browseTimelineSize") as? Double ?? 180)) {
        didSet { UserDefaults.standard.set(browseTimelineSize, forKey: "browseTimelineSize") }
    }
    var browseTimelineScale: TimelineScale { TimelineScale(targetRowHeight: browseTimelineSize) }
    var browseTimelineScaleLabel: String {
        switch browseTimelineScale { case .day: "天"; case .week: "周"; case .month: "月" }
    }
    var timelineDateBasis: TimelineDateBasis {
        switch sort { case .created: .created; case .modified: .modified; default: .captured }
    }

    func setThumbnailSize(_ value: Double) { thumbnailSize = min(280, max(64, value)) }
    func setBrowseTimelineSize(_ value: Double) {
        guard value.isFinite else { return }
        browseTimelineSize = min(280, max(64, value))
    }
    var activeTimelineSize: Double { layout == .browse ? browseTimelineSize : thumbnailSize }
    func setActiveTimelineSize(_ value: Double) {
        if layout == .browse { setBrowseTimelineSize(value) }
        else { setThumbnailSize(value) }
    }
    func zoomTimeline(_ direction: Double) { setActiveTimelineSize(activeTimelineSize * pow(1.2, direction)) }
    func setVisibleTimelineSection(_ id: String?) {
        if visibleTimelineSectionID != id { visibleTimelineSectionID = id }
    }
    func scroll(toSection id: String) {
        guard let section = timelineSections.first(where: { $0.id == id }), let first = section.items.first else { return }
        let changesLayout = layout != .grid
        layout = .grid
        visibleTimelineSectionID = id
        scrollTargetID = first.id
        gridTimelineScrollTarget = nil
        scrollTargetFraction = 0
        navigationAnchorID = first.id
        if !changesLayout { scrollRequestID += 1 }
    }

    func updateGridTimeline(spans: [TimelineDateSpan]?, position: Double, totalLength: Double,
                            anchor: MediaItem?, anchorFraction: Double) {
        guard layout == .grid, position.isFinite, totalLength.isFinite else { return }
        if let spans, gridDateSpans != spans { gridDateSpans = spans }
        let length = max(0, totalLength)
        if gridTimelineTotalLength != length { gridTimelineTotalLength = length }
        let nextPosition = min(length, max(0, position))
        if gridTimelinePosition != nextPosition { gridTimelinePosition = nextPosition }
        if let anchor, visibleIndexByID[anchor.id] != nil {
            if navigationAnchorID != anchor.id { navigationAnchorID = anchor.id }
            if gridViewportAnchorID != anchor.id { gridViewportAnchorID = anchor.id }
            let fraction = anchorFraction.isFinite ? min(1, max(0, anchorFraction)) : 0
            if gridViewportAnchorFraction != fraction { gridViewportAnchorFraction = fraction }
        }
    }

    func navigateGridTimeline(to position: Double) {
        guard position.isFinite, !visibleItems.isEmpty else { return }
        gridTimelineScrollTarget = min(gridTimelineTotalLength, max(0, position))
        scrollTargetID = nil
        gridTimelineScrollRequestID += 1
    }

    func recordBrowsePosition(position: Double, item: MediaItem) {
        guard layout == .browse, position.isFinite,
              let index = visibleIndexByID[item.id] else { return }
        browsePosition = min(Double(max(0, visibleItems.count - 1)), max(0, position))
        browseIndex = index
        navigationAnchorID = item.id
        keyboardCursor = item.id
        if !isSelectionMode, !selectedIDs.isEmpty {
            selectedIDs = [item.id]
            selectionAnchor = item.id
        }
        settleBrowseOriginalFilterIfNeeded(position: browsePosition)
    }

    func navigateBrowse(to position: Double) {
        guard position.isFinite, !visibleItems.isEmpty else { return }
        let position = min(Double(visibleItems.count - 1), max(0, position))
        let oldIndex = Int(position.rounded())
        let item = visibleItems[oldIndex]
        focus(item)
        if let index = visibleIndexByID[item.id] {
            browsePosition = min(Double(max(0, visibleItems.count - 1)), max(0, position + Double(index - oldIndex)))
        }
    }

    @ObservationIgnored private let persistence: CatalogPersistence
    @ObservationIgnored private let scanner = MediaScanner()
    @ObservationIgnored private let cloudScanner: CloudLibraryScanner
    @ObservationIgnored private let cloudIndexStore: CloudIndexStore
    @ObservationIgnored private let writer: CatalogWriter
    @ObservationIgnored private let fileOperations = MediaFileOperations()
    @ObservationIgnored private var saveRevision = 0
    @ObservationIgnored private var lastSaveOutcomeRevision = -1
    @ObservationIgnored private var persistenceFailureMessage: String?
    @ObservationIgnored private var catalogWritable = true
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    private var localScanInProgress = false
    @ObservationIgnored private var cloudIndexTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var cloudIndexTokens: [UUID: UUID] = [:]
    @ObservationIgnored private var localScanWarnings: [String] = []
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var scopedURLs: [UUID: URL] = [:]
    @ObservationIgnored private var itemMap: [String: MediaItem] = [:]
    @ObservationIgnored private var formatByID: [String: String] = [:]
    @ObservationIgnored private var visibleIndexByID: [String: Int] = [:]
    @ObservationIgnored private var itemIndexByID: [String: Int] = [:]
    @ObservationIgnored private var metadataSectionPositions: [String: (section: Int, item: Int)] = [:]
    @ObservationIgnored private var metadataItemIndexDirty = true
    @ObservationIgnored private var metadataSectionIndexDirty = true
    @ObservationIgnored private var applyingMetadataPatch = false
    @ObservationIgnored private var metadataChanges: [(revision: Int, ids: Set<String>, geometry: Set<String>)] = []
    @ObservationIgnored private var metadataPersistenceTask: Task<Void, Never>?
    @ObservationIgnored private var updatingMediaFilters = false
    @ObservationIgnored private var originalDownloadedIDs: Set<String> = []
    @ObservationIgnored private var originalCacheLoader: (@Sendable ([MediaItem]) async -> Set<String>)?
    @ObservationIgnored private var originalCacheTask: Task<Void, Never>?
    @ObservationIgnored private var originalCacheTaskToken: UUID?
    @ObservationIgnored private var originalCacheRefreshRequested = false
    @ObservationIgnored private var originalFilterRefreshDeferred = false
    @ObservationIgnored private var originalFilterBrowsePinnedID: String?
    @ObservationIgnored private var originalCacheItemsRevision = 0
    private var catalogueStructureRevision = 0
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var lastCompletedScanUptime: TimeInterval?
    private(set) var localScanLibraryIDs: Set<UUID> = []
    @ObservationIgnored private var localVerificationIDs: Set<UUID> = []
    @ObservationIgnored private var deferredLocalRefreshIDs: Set<UUID> = []
    @ObservationIgnored private var deferredLocalVerificationIDs: Set<UUID> = []
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var refreshRequestedDuringOperation = false
    @ObservationIgnored private var fullRefreshRequestedDuringOperation = false
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private var fileOperationWaiters: [CheckedContinuation<Void, Never>] = []

    var selectedItems: [MediaItem] {
        selectedIDs.compactMap { id -> (Int, MediaItem)? in
            guard let index = visibleIndexByID[id], visibleItems.indices.contains(index) else { return nil }
            return (index, visibleItems[index])
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }
    var focusedItem: MediaItem? {
        previewID.flatMap { itemMap[$0] } ?? selectedItems.first
            ?? keyboardCursor.flatMap { visibleMediaItem(id: $0) }
    }
    var libraryFocusedItem: MediaItem? {
        selectedItems.first ?? keyboardCursor.flatMap { visibleMediaItem(id: $0) }
    }
    func visibleMediaIndex(id: String) -> Int? { visibleIndexByID[id] }
    func visibleMediaItem(id: String) -> MediaItem? {
        guard let index = visibleIndexByID[id], visibleItems.indices.contains(index) else { return nil }
        return visibleItems[index]
    }
    var title: String {
        switch scope {
        case .all: "所有项目"
        case .favorites: "收藏"
        case .hidden: "已隐藏"
        case .album(let id): albums.first(where: { $0.id == id })?.name ?? "影集"
        case .folders:
            if directorySelection.included.count == 1, let path = directorySelection.included.first {
                libraries.first(where: { $0.selectionPath == path })?.name
                    ?? folders.first(where: { $0.selectionPath == path })?.name
                    ?? URL(fileURLWithPath: path).lastPathComponent
            } else { "所选文件夹" }
        }
    }
    var selectionLabel: String {
        switch scope {
        case .folders: "\(directorySelection.included.count) 个文件夹"
        case .favorites: "收藏"
        case .hidden: "已隐藏"
        case .album: title
        case .all: "全部资源库"
        }
    }
    var favoriteCount: Int {
        _ = catalogueStructureRevision
        return favorites.reduce(0) { $0 + (itemMap[$1] != nil && !hiddenIDs.contains($1) ? 1 : 0) }
    }
    var hiddenCount: Int {
        _ = catalogueStructureRevision
        return hiddenIDs.reduce(0) { $0 + (itemMap[$1] != nil ? 1 : 0) }
    }
    func albumCount(_ album: MediaAlbum) -> Int {
        _ = catalogueStructureRevision
        return album.itemIDs.reduce(0) { $0 + (itemMap[$1] != nil && !hiddenIDs.contains($1) ? 1 : 0) }
    }
    var totalSize: Int64 { visibleItems.reduce(0) { $0 + $1.fileSize } }

    init(directory: URL? = nil, cloudDirectoryLoader: CloudDirectoryLoader? = nil) {
        persistence = CatalogPersistence(directory: directory)
        writer = CatalogWriter(directory: directory)
        let catalogDirectory = CatalogPersistence(directory: directory).directory
        cloudIndexStore = CloudIndexStore(catalogDirectory: catalogDirectory)
        cloudScanner = CloudLibraryScanner(directory: catalogDirectory, loader: cloudDirectoryLoader)
        do {
            let state = try persistence.load()
            libraries = state.libraries
            cloudAccounts = state.cloudAccounts
            favorites = state.favorites
            hiddenIDs = state.hiddenIDs
            albums = state.albums
            items = state.cachedItems
            for index in libraries.indices {
                let library = libraries[index]
                guard library.isLocal else { continue }
                do {
                    let url = try library.resolvedURL()
                    if url.startAccessingSecurityScopedResource() { scopedURLs[library.id] = url }
                    libraries[index].url = url
                } catch { offlineLibraries.insert(library.id) }
            }
            restoreCloudIndexState()
            rebuildMap()
            applyFilters()
        } catch {
            if case CatalogPersistenceError.corrupted = error {
                do {
                    let backup = try persistence.backupCorruptCatalog()
                    errorMessage = "资源库记录损坏，原记录已备份至 \(backup.path)。可以重新添加文件夹。"
                } catch {
                    catalogWritable = false
                    errorMessage = "无法读取或备份资源库记录，已停止写入以保留原记录。\(error.localizedDescription)"
                }
            } else {
                catalogWritable = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "添加资源库"
        panel.message = "选择照片或视频所在的文件夹"
        if panel.runModal() == .OK { addFolders(panel.urls) }
    }

    func addFolders(_ urls: [URL]) {
        var added = 0
        for original in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: original.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let url = original.resolvingSymlinksInPath().standardizedFileURL
            guard !libraries.contains(where: { $0.isLocal && $0.url.resolvingSymlinksInPath().standardizedFileURL == url }) else { continue }
            let bookmark = try? original.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            let library = MediaLibrary(url: url, bookmark: bookmark)
            if original.startAccessingSecurityScopedResource() { scopedURLs[library.id] = original }
            libraries.append(library)
            added += 1
        }
        guard added > 0 else { notify("文件夹已在资源库中，或无法访问") ; return }
        scope = .all
        save()
        refreshLocalLibraries()
    }

    func removeLibrary(_ library: MediaLibrary) {
        cancelCloudIndex(library.id)
        cloudIndexProgress[library.id] = nil
        Task { try? await cloudScanner.discard(libraryID: library.id) }
        libraries.removeAll { $0.id == library.id }
        scopedURLs.removeValue(forKey: library.id)?.stopAccessingSecurityScopedResource()
        offlineLibraries.remove(library.id)
        directorySelection.included = directorySelection.included.filter { !Self.isInside($0, folder: library.selectionPath) }
        directorySelection.excluded = directorySelection.excluded.filter { !Self.isInside($0, folder: library.selectionPath) }
        // Keep overlapping roots, remove only items no remaining library owns.
        items.removeAll { item in !libraries.contains { item.belongs(to: $0) } }
        folders.removeAll { folder in !libraries.contains { folder.belongs(to: $0) } }
        rebuildMap()
        applyFilters()
        save()
        refreshLocalLibraries()
    }

    func reconnect(_ library: MediaLibrary) {
        if let cloud = library.cloud {
            reconnectCloudAccount = cloudAccounts.first { $0.id == cloud.accountID }
            showCloudConnection = true
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "重新连接"
        panel.directoryURL = library.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url,
              let index = libraries.firstIndex(where: { $0.id == library.id }) else { return }
        let previous = libraries[index].url.path
        let replacement = url.resolvingSymlinksInPath().standardizedFileURL
        guard !libraries.contains(where: { $0.id != library.id && $0.url == replacement }) else { notify("该文件夹已在资源库中"); return }
        scopedURLs.removeValue(forKey: library.id)?.stopAccessingSecurityScopedResource()
        libraries[index].url = replacement
        libraries[index].bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        if url.startAccessingSecurityScopedResource() { scopedURLs[library.id] = url }
        if previous != replacement.path {
            favorites = Set(favorites.map { Self.isInside($0, folder: previous) ? replacement.path + $0.dropFirst(previous.count) : $0 })
            hiddenIDs = Set(hiddenIDs.map { Self.isInside($0, folder: previous) ? replacement.path + $0.dropFirst(previous.count) : $0 })
            for index in albums.indices {
                albums[index].itemIDs = Set(albums[index].itemIDs.map { Self.isInside($0, folder: previous) ? replacement.path + $0.dropFirst(previous.count) : $0 })
            }
            items.removeAll { Self.isInside($0.id, folder: previous) }
            directorySelection = DirectorySelection()
            scope = .all
        }
        save()
        refreshLocalLibraries(libraryIDs: [library.id], verifyContents: true)
    }

    /// Local activation checks stay responsive. Remote libraries use their
    /// persisted last successful check, rather than traversing every 15 seconds.
    /// The current providers do not expose a reliable unified delta feed.
    func refreshIfNeeded() {
        guard !isTerminating else { return }
        if isPerformingFileOperation { refreshRequestedDuringOperation = true; return }
        if !localScanInProgress {
            let needsLocalCheck = lastCompletedScanUptime.map { ProcessInfo.processInfo.systemUptime - $0 >= 15 } ?? true
            if needsLocalCheck { refreshLocalLibraries() }
        }
        for library in libraries where !library.isLocal && cloudIndexTasks[library.id] == nil {
            let progress = cloudIndexProgress[library.id]
            // A paused/failed run resumes at complete directory boundaries. A
            // ready library is checked at most every 30 minutes automatically.
            let lastAttempt = progress?.updatedAt ?? .distantPast
            let lastComplete = progress?.lastCompletedAt ?? .distantPast
            let isIncomplete = progress?.phase != .ready
            if (isIncomplete && Date().timeIntervalSince(lastAttempt) >= 60)
                || (!isIncomplete && Date().timeIntervalSince(lastComplete) >= 30 * 60)
                || progress == nil {
                startCloudIndex(library, resume: isIncomplete)
            }
        }
    }

    /// Explicit refresh remains a complete provider directory check; only
    /// changed catalogue records are published, and decoded metadata are reused.
    func refresh() {
        guard !isTerminating else { return }
        if isPerformingFileOperation { fullRefreshRequestedDuringOperation = true; return }
        refreshLocalLibraries(verifyContents: true)
        let activeIDs = Set(libraries.filter { !$0.isLocal }.map(\.id))
        for id in Array(cloudIndexTasks.keys) where !activeIDs.contains(id) { cancelCloudIndex(id) }
        cloudIndexProgress = cloudIndexProgress.filter { activeIDs.contains($0.key) }
        for library in libraries where !library.isLocal && cloudIndexTasks[library.id] == nil { startCloudIndex(library, resume: false) }
        if libraries.isEmpty {
            items = []; folders = []; selectedIDs = []; offlineLibraries = []
            rebuildMap(); applyFilters(); save()
        }
    }

    func isRefreshing(_ library: MediaLibrary) -> Bool {
        library.isLocal ? localScanLibraryIDs.contains(library.id) : cloudIndexTasks[library.id] != nil
    }

    func refreshLibrary(_ libraryID: UUID) {
        guard let library = libraries.first(where: { $0.id == libraryID }) else { return }
        if library.isLocal { refreshLocalLibraries(libraryIDs: [libraryID], verifyContents: true) }
        else { refreshCloudLibrary(libraryID) }
    }

    /// Requests are coalesced by library. Starting another local refresh keeps
    /// the roots already being checked; a single-library refresh leaves every
    /// unrelated local/cloud catalogue and offline state alone.
    func refreshLocalLibraries(libraryIDs: Set<UUID>? = nil, verifyContents: Bool = false) {
        guard !isTerminating else { return }
        let localIDs = Set(libraries.filter(\.isLocal).map(\.id))
        let requested = (libraryIDs ?? localIDs).intersection(localIDs)
        guard !requested.isEmpty else { return }
        if isPerformingFileOperation {
            deferredLocalRefreshIDs.formUnion(requested)
            if verifyContents { deferredLocalVerificationIDs.formUnion(requested) }
            return
        }
        if localScanInProgress, requested.isSubset(of: localScanLibraryIDs),
           !verifyContents || requested.isSubset(of: localVerificationIDs) { return }
        let active = localScanLibraryIDs.union(requested).intersection(localIDs)
        let verified = localVerificationIDs.union(verifyContents ? requested : []).intersection(active)
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        let ignoreDotFiles = self.ignoreDotFiles
        let currentLibraries = libraries.filter { active.contains($0.id) }
        let cachedItems = items.filter { item in currentLibraries.contains { item.belongs(to: $0) } }
        localScanLibraryIDs = active
        localVerificationIDs = verified
        localScanInProgress = true
        updateScanningState()
        scanTask = Task {
            await scanner.seed(cachedItems: cachedItems)
            guard !Task.isCancelled, generation == scanGeneration else { return }
            // Verify only requested roots; other coalesced roots retain their
            // inexpensive filesystem revision checks and metadata cache.
            var resultItems: [MediaItem] = [], resultFolders: [MediaFolder] = []
            var unverifiedPaths = Set<String>()
            var unavailable = Set<UUID>(), warnings: [String] = [], resolved: [UUID: URL] = [:], bookmarks: [UUID: Data] = [:]
            for strict in [false, true] {
                let roots = currentLibraries.filter { verified.contains($0.id) == strict }
                guard !roots.isEmpty else { continue }
                let result = await scanner.scan(libraries: roots, verifyContents: strict, ignoreDotFiles: ignoreDotFiles)
                guard !Task.isCancelled, generation == scanGeneration else { return }
                resultItems += result.items; resultFolders += result.folders
                unavailable.formUnion(result.unavailableLibraryIDs); warnings += result.warnings
                unverifiedPaths.formUnion(result.unverifiedPaths)
                resolved.merge(result.resolvedLibraryURLs, uniquingKeysWith: { _, latest in latest })
                bookmarks.merge(result.refreshedBookmarks, uniquingKeysWith: { _, latest in latest })
            }
            let offlineRoots = currentLibraries.filter { unavailable.contains($0.id) }
            let preserved = items.filter { item in
                !currentLibraries.contains { item.belongs(to: $0) } || offlineRoots.contains { item.belongs(to: $0) }
                    || unverifiedPaths.contains { Self.isInside(item.url.path, folder: $0) }
            }
            let merged = Self.merging(resultItems, preserving: preserved)
            let untouchedFolders = folders.filter { folder in
                !currentLibraries.contains { folder.belongs(to: $0) } || offlineRoots.contains { folder.belongs(to: $0) }
                    || unverifiedPaths.contains { Self.isInside(folder.url.path, folder: $0) }
            }
            let folderMap = Dictionary((resultFolders + untouchedFolders).map { ($0.id, $0) }, uniquingKeysWith: { latest, _ in latest })
            for (id, url) in resolved {
                if let index = libraries.firstIndex(where: { $0.id == id }), libraries[index].url != url {
                    migrateLocalRoot(from: libraries[index].url.path, to: url.path)
                    libraries[index].url = url
                }
                if let index = libraries.firstIndex(where: { $0.id == id }), let bookmark = bookmarks[id] {
                    libraries[index].bookmark = bookmark
                    scopedURLs.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
                    if url.startAccessingSecurityScopedResource() { scopedURLs[id] = url }
                }
            }
            offlineLibraries.subtract(active)
            offlineLibraries.formUnion(unavailable)
            localScanWarnings = warnings
            refreshScanWarnings()
            publishRefreshedMedia(merged, folders: Array(folderMap.values))
            localScanInProgress = false
            localScanLibraryIDs = []; localVerificationIDs = []
            scanTask = nil
            updateScanningState()
            lastCompletedScanUptime = ProcessInfo.processInfo.systemUptime
            save()
        }
    }

    private func migrateLocalRoot(from old: String, to new: String) {
        func mapped(_ value: String) -> String { Self.isInside(value, folder: old) ? new + value.dropFirst(old.count) : value }
        favorites = Set(favorites.map(mapped)); hiddenIDs = Set(hiddenIDs.map(mapped)); selectedIDs = Set(selectedIDs.map(mapped))
        for index in albums.indices { albums[index].itemIDs = Set(albums[index].itemIDs.map(mapped)) }
        directorySelection.included = Set(directorySelection.included.map(mapped))
        directorySelection.excluded = Set(directorySelection.excluded.map(mapped))
        selectionAnchor = selectionAnchor.map(mapped); keyboardCursor = keyboardCursor.map(mapped)
        navigationAnchorID = navigationAnchorID.map(mapped); gridViewportAnchorID = gridViewportAnchorID.map(mapped)
        previewID = previewID.map(mapped); scrollTargetID = scrollTargetID.map(mapped); gridPreviewID = gridPreviewID.map(mapped)
    }

    private func publishRefreshedMedia(_ refreshed: [MediaItem], folders suppliedFolders: [MediaFolder]) {
        // A scanner sees only the roots it was asked to check. Restore actual
        // local parent links so reloading a nested library does not detach it
        // from another library's already-known directory tree.
        let nextFolders = suppliedFolders.map { folder -> MediaFolder in
            guard folder.isLocal else { return folder }
            let parent = folder.url.deletingLastPathComponent().path
            let path: String? = parent == folder.url.path ? nil : parent
            guard folder.parentPath != path else { return folder }
            return MediaFolder(id: folder.id, url: folder.url, parentPath: path, name: folder.name)
        }
        let structural = refreshed.count != items.count || refreshed.contains { itemMap[$0.id] == nil }
        let foldersChanged = Set(folders) != Set(nextFolders)
        let updates = Dictionary(refreshed.filter { itemMap[$0.id] != $0 }.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        guard structural || foldersChanged || !updates.isEmpty else { return }
        let needsReorder = updates.values.contains { item in
            guard let old = itemMap[item.id] else { return true }
            switch sort {
            case .captured: return old.displayDate != item.displayDate
            case .created: return old.createdDate != item.createdDate
            case .modified: return old.modifiedDate != item.modifiedDate
            case .size: return old.fileSize != item.fileSize
            case .name: return old.name != item.name
            }
        }
        if !structural && !foldersChanged && !needsReorder {
            let geometry = Set(updates.values.filter { itemMap[$0.id]?.aspectRatio != $0.aspectRatio }.map(\.id))
            updateCachedMediaItems(updates)
            publishVisibleMetadata(updates, geometryChangedIDs: geometry)
        } else {
            items = refreshed; folders = nextFolders
            rebuildMap(); applyFilters()
        }
    }

    func volumeDidMount(_ volume: URL?) {
        let roots = libraries.filter { library in
            library.isLocal && (volume.map { Self.isInside(library.url.path, folder: $0.path) } ?? true
                               || offlineLibraries.contains(library.id))
        }
        refreshLocalLibraries(libraryIDs: Set(roots.map(\.id)), verifyContents: true)
    }

    func volumeDidUnmount(_ volume: URL?) {
        guard let volume else { return }
        let ids = Set(libraries.filter { $0.isLocal && Self.isInside($0.url.path, folder: volume.path) }.map(\.id))
        offlineLibraries.formUnion(ids)
        refreshLocalLibraries(libraryIDs: ids)
    }

    func refreshCloudLibrary(_ libraryID: UUID, restart: Bool = false) {
        guard let library = libraries.first(where: { $0.id == libraryID && !$0.isLocal }),
              restart || cloudIndexTasks[libraryID] == nil else { return }
        startCloudIndex(library, resume: false)
    }

    func retryCloudIndex(_ libraryID: UUID) {
        guard let library = libraries.first(where: { $0.id == libraryID && !$0.isLocal }) else { return }
        startCloudIndex(library, resume: true)
    }

    func cancelCloudIndex(_ libraryID: UUID) {
        cloudIndexTasks.removeValue(forKey: libraryID)?.cancel()
        cloudIndexTokens[libraryID] = nil
        if var progress = cloudIndexProgress[libraryID], progress.phase == .indexing {
            progress.phase = .paused
            progress.error = nil
            progress.updatedAt = Date()
            cloudIndexProgress[libraryID] = progress
        }
        updateScanningState()
    }

    func rebuildCloudIndexes() {
        // begin(resume:false) replaces only staging. The last complete catalogue
        // and all user collections stay available throughout the new check.
        for library in libraries where !library.isLocal { startCloudIndex(library, resume: false) }
    }

    func rebuildIndexes() {
        guard !isTerminating, !isPerformingFileOperation else { return }
        refreshLocalLibraries()
        rebuildCloudIndexes()
    }

    private func startCloudIndex(_ library: MediaLibrary, resume: Bool) {
        guard !isTerminating, !isPerformingFileOperation else { return }
        cloudIndexTasks[library.id]?.cancel()
        let token = UUID()
        cloudIndexTokens[library.id] = token
        let old = cloudIndexProgress[library.id]
        cloudIndexProgress[library.id] = CloudIndexProgress(photos: old?.photos ?? 0, videos: old?.videos ?? 0,
                                                          folders: old?.folders ?? 0, lastCompletedAt: old?.lastCompletedAt)
        let account = library.cloud.flatMap { reference in cloudAccounts.first { $0.id == reference.accountID } }
        if let accountID = library.cloud?.accountID, let issue = CloudTransferCenter.shared.issue(for: accountID) {
            cloudIndexTasks[library.id] = nil
            cloudIndexTokens[library.id] = nil
            var progress = cloudIndexProgress[library.id] ?? CloudIndexProgress()
            progress.phase = .failed
            progress.error = issue.message
            progress.errorCode = ResourceProblem.login.rawValue
            cloudIndexProgress[library.id] = progress
            offlineLibraries.insert(library.id)
            refreshScanWarnings()
            updateScanningState()
            return
        }
        cloudIndexTasks[library.id] = Task {
            if let accountID = library.cloud?.accountID { await CloudGateway.shared.allowRecovery(accountID: accountID) }
            let outcome = await cloudScanner.scan(library: library, account: account, resume: resume) { [weak self] progress in
                await self?.receiveCloudProgress(progress, libraryID: library.id, token: token)
            }
            guard !Task.isCancelled, cloudIndexTokens[library.id] == token,
                  libraries.contains(where: { $0.id == library.id }), !isTerminating else { return }
            switch outcome {
            case .completed(let snapshot):
                publishCloudSnapshot(snapshot, library: library)
                // Keep a complete unpublished staging snapshot until the formal
                // catalogue is durable. A crash here can be recovered at startup.
                let saved = await flushImmediately()
                if saved { try? await cloudScanner.markPublished(library: library, generation: snapshot.generation) }
            case .failed(let progress):
                cloudIndexProgress[library.id] = progress
                offlineLibraries.insert(library.id)
            case .paused(let progress):
                cloudIndexProgress[library.id] = progress
            }
            guard cloudIndexTokens[library.id] == token else { return }
            cloudIndexTasks[library.id] = nil
            cloudIndexTokens[library.id] = nil
            refreshScanWarnings()
            updateScanningState()
        }
        updateScanningState()
    }

    private func receiveCloudProgress(_ progress: CloudIndexProgress, libraryID: UUID, token: UUID) {
        guard cloudIndexTokens[libraryID] == token, !isTerminating else { return }
        // Ready is published with its complete catalogue, never before it.
        if progress.phase != .ready { cloudIndexProgress[libraryID] = progress }
    }

    private func publishCloudSnapshot(_ snapshot: CloudIndexSnapshot, library: MediaLibrary) {
        let previous = items
        let preserved = items.filter { !$0.belongs(to: library) }
        let merged = Self.merging(snapshot.items, preserving: preserved, metadataFrom: previous)
        let nextFolders = folders.filter { !$0.belongs(to: library) } + snapshot.folders
        cloudIndexProgress[library.id] = snapshot.progress
        offlineLibraries.remove(library.id)
        publishRefreshedMedia(merged, folders: nextFolders)
        save()
    }

    private func restoreCloudIndexState() {
        for library in libraries where !library.isLocal {
            if let status = cloudIndexStore.status(for: library) {
                var progress = status.progress
                if progress.phase == .indexing { progress.phase = .paused }
                cloudIndexProgress[library.id] = progress
            } else {
                let cached = items.filter { $0.belongs(to: library) }
                if !cached.isEmpty {
                    cloudIndexProgress[library.id] = CloudIndexProgress(photos: cached.filter { $0.kind == .image }.count,
                                                                      videos: cached.filter { $0.kind == .video }.count,
                                                                      phase: .ready, updatedAt: .distantPast)
                }
            }
            let token = UUID()
            cloudIndexTokens[library.id] = token
            cloudIndexTasks[library.id] = Task { [weak self] in
                guard let self else { return }
                do {
                    let restored = try await self.cloudScanner.restore(library: library)
                    guard !Task.isCancelled, self.cloudIndexTokens[library.id] == token,
                          self.libraries.contains(where: { $0.id == library.id }), !self.isTerminating else { return }
                    if let restored {
                        var progress = restored.status.progress
                        if progress.phase == .indexing { progress.phase = .paused }
                        self.cloudIndexProgress[library.id] = progress
                        if let snapshot = restored.snapshot {
                            self.publishCloudSnapshot(snapshot, library: library)
                            let saved = await self.flushImmediately()
                            if saved { try? await self.cloudScanner.markPublished(library: library, generation: snapshot.generation) }
                        } else if let restoredFolders = restored.folders {
                            self.folders = self.folders.filter { !$0.belongs(to: library) } + restoredFolders
                        }
                    }
                } catch {
                    guard !Task.isCancelled, self.cloudIndexTokens[library.id] == token else { return }
                    var progress = self.cloudIndexProgress[library.id] ?? CloudIndexProgress()
                    progress.phase = .failed
                    progress.error = "索引检查点不完整，现有资源库已保留。请重新校对。"
                    self.cloudIndexProgress[library.id] = progress
                }
                guard self.cloudIndexTokens[library.id] == token else { return }
                self.cloudIndexTasks[library.id] = nil
                self.cloudIndexTokens[library.id] = nil
                self.refreshScanWarnings()
                self.updateScanningState()
                // The launch activation may arrive while this background
                // restoration owns the library. Check due work once it yields.
                self.refreshIfNeeded()
            }
        }
        updateScanningState()
    }

    func applyCloudConnectionIssues() {
        for library in libraries {
            guard let accountID = library.cloud?.accountID,
                  let issue = CloudTransferCenter.shared.issue(for: accountID) else { continue }
            cancelCloudIndex(library.id)
            var progress = cloudIndexProgress[library.id] ?? CloudIndexProgress()
            progress.phase = .failed
            progress.error = issue.message
            progress.errorCode = ResourceProblem.login.rawValue
            progress.updatedAt = Date()
            cloudIndexProgress[library.id] = progress
            offlineLibraries.insert(library.id)
        }
        refreshScanWarnings()
        updateScanningState()
    }

    private func refreshScanWarnings() {
        scanWarnings = localScanWarnings
    }

    private func updateScanningState() { isScanning = localScanInProgress || !cloudIndexTasks.isEmpty }

    private static func sameItems(_ left: [MediaItem], _ right: [MediaItem]) -> Bool {
        guard left.count == right.count else { return false }
        return Dictionary(left.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            == Dictionary(right.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    private func cancelLocalScan() {
        scanGeneration += 1
        scanTask?.cancel(); scanTask = nil
        localScanInProgress = false
        localScanLibraryIDs = []; localVerificationIDs = []
        updateScanningState()
    }

    func cancelScan() {
        cancelLocalScan()
        for id in Array(cloudIndexTasks.keys) { cancelCloudIndex(id) }
        updateScanningState()
    }

    private static func merging(_ incoming: [MediaItem], preserving previous: [MediaItem], metadataFrom: [MediaItem] = []) -> [MediaItem] {
        var merged = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let metadata = Dictionary(metadataFrom.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in incoming {
            if !item.isLocal, let old = metadata[item.id] { merged[item.id] = item.mergingMetadata(from: old) }
            else { merged[item.id] = item }
        }
        return Array(merged.values)
    }

    /// Termination barrier: no new scans or file operations may begin after this
    /// call. An in-flight operation migrates its records and attempts to save
    /// before releasing waiters. The final flush decides whether quitting is safe.
    func waitForFileOperations() async {
        isTerminating = true
        originalCacheTask?.cancel()
        originalCacheTask = nil
        originalCacheTaskToken = nil
        isCheckingOriginalCache = false
        refreshRequestedDuringOperation = false
        cancelScan()
        guard isPerformingFileOperation else { return }
        await withCheckedContinuation { fileOperationWaiters.append($0) }
    }

    /// A failed final save cancels termination without discarding the in-memory
    /// catalog, including paths of originals that have already been moved.
    func cancelTermination() {
        isTerminating = false
        refreshRequestedDuringOperation = false
    }

    func selectScope(_ newScope: Scope) {
        clearOriginalFilterDeferrals()
        scope = newScope
        if newScope == .all { directorySelection = DirectorySelection(included: Set(libraries.map(\.selectionPath))) }
        applyFilters()
    }

    func toggleFolder(_ path: String) {
        clearOriginalFilterDeferrals()
        if scope == .all { directorySelection = DirectorySelection(included: Set(libraries.map(\.selectionPath))); scope = .folders }
        else if scope != .folders { directorySelection = DirectorySelection(); scope = .folders }
        directorySelection.toggle(path)
        applyFilters()
    }

    func folderState(_ path: String) -> FolderSelectionState {
        scope == .all ? .all : (scope == .folders ? directorySelection.state(for: path) : .none)
    }

    private static func hasDotComponent(_ path: String, roots: [String]) -> Bool {
        // A deliberately selected root may itself live in a hidden parent.
        // Ignore dot entries inside that root, never its external ancestors.
        let relative = roots.first(where: { isInside(path, folder: $0) }).map { String(path.dropFirst($0.count)) }
            ?? (path as NSString).lastPathComponent
        return relative.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    var ignoreDotFiles: Bool { UserDefaults.standard.object(forKey: "ignoreDotFiles") as? Bool ?? true }

    func dotFilePreferenceChanged() {
        rebuildMap()
        applyFilters()
        // A changed enumeration policy must restart local work even when the
        // same roots were already being checked. Cloud work remains intact.
        localScanLibraryIDs = []; localVerificationIDs = []
        refreshLocalLibraries(verifyContents: true)
    }

    func renameLibrary(_ id: UUID, to proposed: String) {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120, !name.contains("\n"),
              let index = libraries.firstIndex(where: { $0.id == id }) else { return }
        libraries[index].name = name
        save()
    }

    func moveLibrary(_ id: UUID, to targetID: UUID) {
        guard id != targetID, let source = libraries.firstIndex(where: { $0.id == id }),
              let target = libraries.firstIndex(where: { $0.id == targetID }) else { return }
        let library = libraries.remove(at: source)
        libraries.insert(library, at: target)
        save()
    }

    func count(in folder: String) -> Int { folderCounts[folder] ?? 0 }

    func cachedMediaItem(id: String) -> MediaItem? {
        prepareMetadataItemIndex()
        return itemMap[id]
    }

    private func prepareMetadataItemIndex() {
        guard metadataItemIndexDirty else { return }
        itemIndexByID = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        itemMap = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        formatByID = Dictionary(items.map { ($0.id, Self.formatIdentifier(for: $0)) }, uniquingKeysWith: { a, _ in a })
        metadataItemIndexDirty = false
    }

    func updateCachedMediaItem(_ item: MediaItem) { updateCachedMediaItems([item.id: item]) }

    func updateCachedMediaItems(_ updates: [String: MediaItem]) {
        guard !updates.isEmpty else { return }
        prepareMetadataItemIndex()
        var next = items
        var changed: [MediaItem] = []
        for (id, item) in updates {
            guard let index = itemIndexByID[id], next[index] != item else { continue }
            next[index] = item
            itemMap[id] = item
            changed.append(item)
        }
        guard !changed.isEmpty else { return }
        applyingMetadataPatch = true
        items = next
        applyingMetadataPatch = false
        CloudMediaRegistry.shared.register(changed)
    }

    /// Metadata delivery has its own bounded delta history. Collection views can
    /// consume several coalesced UI updates without rescanning every media ID.
    func mediaMetadataChanges(since revision: Int) -> (changedIDs: Set<String>, geometryChangedIDs: Set<String>)? {
        guard revision <= mediaMetadataRevision else { return nil }
        if revision == mediaMetadataRevision { return ([], []) }
        guard let first = metadataChanges.first, revision >= first.revision - 1 else { return nil }
        var changed = Set<String>(), geometry = Set<String>()
        for delta in metadataChanges where delta.revision > revision {
            changed.formUnion(delta.ids); geometry.formUnion(delta.geometry)
        }
        return (changed, geometry)
    }

    func publishVisibleMetadata(_ updates: [String: MediaItem], geometryChangedIDs: Set<String>) {
        let visibleUpdates = updates.filter { visibleIndexByID[$0.key] != nil }
        guard !visibleUpdates.isEmpty else { return }
        if metadataSectionIndexDirty {
            metadataSectionPositions.removeAll(keepingCapacity: true)
            for (section, value) in timelineSections.enumerated() {
                for (index, item) in value.items.enumerated() { metadataSectionPositions[item.id] = (section, index) }
            }
            metadataSectionIndexDirty = false
        }
        var nextVisible = visibleItems
        var nextSections = timelineSections
        var sectionUpdates: [Int: [(Int, MediaItem)]] = [:]
        for (id, item) in visibleUpdates {
            if let index = visibleIndexByID[id] { nextVisible[index] = item }
            if let position = metadataSectionPositions[id] { sectionUpdates[position.section, default: []].append((position.item, item)) }
        }
        for (index, values) in sectionUpdates {
            let section = nextSections[index]
            var sectionItems = section.items
            for (itemIndex, item) in values { sectionItems[itemIndex] = item }
            nextSections[index] = TemporalSection(id: section.id, startDate: section.startDate, endDate: section.endDate,
                                                 title: section.title, items: sectionItems)
        }
        applyingMetadataPatch = true
        visibleItems = nextVisible
        timelineSections = nextSections
        applyingMetadataPatch = false
        mediaMetadataRevision &+= 1
        let ids = Set(visibleUpdates.keys)
        metadataChanges.append((mediaMetadataRevision, ids, geometryChangedIDs.intersection(ids)))
        if metadataChanges.count > 64 { metadataChanges.removeFirst(metadataChanges.count - 64) }
    }

    func saveMetadataChanges() {
        guard metadataPersistenceTask == nil else { return }
        metadataPersistenceTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self else { return }
            self.metadataPersistenceTask = nil
            self.save()
        }
    }

    @discardableResult
    func createAlbum(name: String, addingIDs: Set<String> = []) -> UUID? {
        guard let name = validAlbumName(name) else { return nil }
        let album = MediaAlbum(name: name, itemIDs: addingIDs.intersection(Set(itemMap.keys)))
        albums.append(album)
        save()
        return album.id
    }

    func renameAlbum(_ id: UUID, to name: String) {
        guard let index = albums.firstIndex(where: { $0.id == id }),
              let name = validAlbumName(name, excluding: id) else { return }
        albums[index].name = name
        save()
    }

    func deleteAlbum(_ id: UUID) {
        albums.removeAll { $0.id == id }
        if scope == .album(id) { scope = .all }
        applyFilters()
        save()
    }

    func addToAlbum(_ ids: Set<String>, albumID: UUID) {
        guard let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        albums[index].itemIDs.formUnion(ids.intersection(Set(itemMap.keys)))
        applyFilters()
        save()
    }

    func removeFromAlbum(_ ids: Set<String>, albumID: UUID) {
        guard let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        albums[index].itemIDs.subtract(ids)
        applyFilters()
        save()
    }

    func setHidden(_ hidden: Bool, ids: Set<String>) {
        if hidden { hiddenIDs.formUnion(ids.intersection(Set(itemMap.keys))) }
        else { hiddenIDs.subtract(ids) }
        rebuildMap()
        applyFilters()
        save()
    }

    private func validAlbumName(_ proposed: String, excluding id: UUID? = nil) -> String? {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name.count <= 120, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            errorMessage = "请输入有效的影集名称（最多120个字符）。"
            return nil
        }
        guard !albums.contains(where: { $0.id != id && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            errorMessage = "已存在名为“\(name)”的影集。"
            return nil
        }
        return name
    }

    /// `name` is a base name; an existing matching extension is also accepted.
    /// The original format extension is always retained.
    func rename(_ item: MediaItem, to name: String) async -> Bool {
        guard let current = trackedFileItem(item) else { return false }
        let destinationName: String
        do { destinationName = try MediaFileOperations.destinationName(for: current.url, proposed: name) }
        catch { errorMessage = "无法重命名“\(current.name)”：\(error.localizedDescription)"; return false }
        let destination = current.url.deletingLastPathComponent().appendingPathComponent(destinationName)
        if destination.path == current.url.path { return true }
        guard itemMap[destination.path] == nil else {
            errorMessage = "无法重命名“\(current.name)”：资源库中已有“\(destinationName)”，请先刷新检查。"
            return false
        }
        guard beginFileOperation() else { return false }
        defer { endFileOperation() }
        do {
            let result = try await fileOperations.rename(current, to: destinationName)
            migrateItem(current.id, to: result)
            await flushImmediately()
            notify("已重命名为“\(result.lastPathComponent)”")
            return true
        } catch {
            errorMessage = "无法重命名“\(current.name)”：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func rotatePhoto(_ item: MediaItem, direction: PhotoRotationDirection) async -> Bool {
        guard let current = trackedFileItem(item), beginFileOperation() else { return false }
        defer { endFileOperation() }
        do {
            let rotated = try await fileOperations.rotate(current, direction: direction)
            updateCachedMediaItem(rotated)
            publishVisibleMetadata([rotated.id: rotated], geometryChangedIDs: [rotated.id])
            await flushImmediately()
            NotificationCenter.default.post(name: Notification.Name("FilmboxPreviewRetry"), object: nil)
            return true
        } catch {
            errorMessage = "无法旋转“\(current.name)”：\(error.localizedDescription)"
            return false
        }
    }

    /// Moves originals to the system Trash. Failed items remain in every index
    /// and collection; a partial success is reported item by item.
    func trash(_ targets: [MediaItem]) async {
        var seen = Set<String>()
        var candidates: [MediaItem] = []
        var failures: [String] = []
        for target in targets where seen.insert(target.id).inserted {
            if let current = trackedFileItem(target) { candidates.append(current) }
            else { failures.append("“\(target.name)”：项目已变更或不属于当前资源库。") }
        }
        guard !candidates.isEmpty else {
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
            return
        }
        guard beginFileOperation() else { return }
        defer { endFileOperation() }
        let outcome = await fileOperations.trash(candidates)
        failures.append(contentsOf: outcome.failures)
        let removed = outcome.successfulIDs
        if !removed.isEmpty {
            items.removeAll { removed.contains($0.id) }
            favorites.subtract(removed)
            hiddenIDs.subtract(removed)
            for index in albums.indices { albums[index].itemIDs.subtract(removed) }
            selectedIDs.subtract(removed)
            if let previewID, removed.contains(previewID) { self.previewID = nil }
            if let scrollTargetID, removed.contains(scrollTargetID) { self.scrollTargetID = nil }
            rebuildMap()
            applyFilters()
            await flushImmediately()
            notify("\(removed.count)项已移到废纸篓")
        }
        if !failures.isEmpty {
            errorMessage = (removed.isEmpty ? "无法移到废纸篓：\n" : "\(removed.count)项已移到废纸篓，以下项目未移动：\n")
                + failures.joined(separator: "\n")
        }
    }

    private func trackedFileItem(_ requested: MediaItem) -> MediaItem? {
        guard let current = itemMap[requested.id], current.url == requested.url,
              current.url.isFileURL,
              libraries.contains(where: { Self.isInside(current.id, folder: $0.url.path) }) else {
            errorMessage = "项目已变更或不属于当前资源库，请刷新后重试。"
            return nil
        }
        return current
    }

    private func beginFileOperation() -> Bool {
        guard !isTerminating else { return false }
        guard catalogWritable else { errorMessage = "无法安全保存资源库记录，暂不能修改原文件。"; return false }
        guard !isPerformingFileOperation else { errorMessage = "正在处理文件，请稍后重试。"; return false }
        refreshRequestedDuringOperation = localScanInProgress
        deferredLocalRefreshIDs.formUnion(localScanLibraryIDs)
        deferredLocalVerificationIDs.formUnion(localVerificationIDs)
        isPerformingFileOperation = true
        cancelLocalScan()
        return true
    }

    private func endFileOperation() {
        isPerformingFileOperation = false
        let fullRefresh = fullRefreshRequestedDuringOperation
        let localRefresh = refreshRequestedDuringOperation
        fullRefreshRequestedDuringOperation = false
        refreshRequestedDuringOperation = false
        let requested = deferredLocalRefreshIDs, verified = deferredLocalVerificationIDs
        deferredLocalRefreshIDs = []; deferredLocalVerificationIDs = []
        if !isTerminating {
            if fullRefresh { refresh() }
            else {
                if !requested.isEmpty { refreshLocalLibraries(libraryIDs: requested, verifyContents: !verified.isEmpty) }
                else if localRefresh { refreshLocalLibraries() }
            }
        }
        let waiters = fileOperationWaiters
        fileOperationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func migrateItem(_ oldID: String, to url: URL) {
        let newID = url.standardizedFileURL.path
        let browsing = visibleItems.indices.contains(browseIndex) ? visibleItems[browseIndex].id : nil
        items = items.map { $0.id == oldID ? $0.relocated(to: url) : $0 }
        func migrate(_ ids: Set<String>) -> Set<String> { Set(ids.map { $0 == oldID ? newID : $0 }) }
        favorites = migrate(favorites)
        hiddenIDs = migrate(hiddenIDs)
        selectedIDs = migrate(selectedIDs)
        for index in albums.indices { albums[index].itemIDs = migrate(albums[index].itemIDs) }
        if selectionAnchor == oldID { selectionAnchor = newID }
        if keyboardCursor == oldID { keyboardCursor = newID }
        if previewID == oldID { previewID = newID }
        if scrollTargetID == oldID { scrollTargetID = newID }
        if navigationAnchorID == oldID { navigationAnchorID = newID }
        if gridViewportAnchorID == oldID { gridViewportAnchorID = newID }
        if gridPreviewID == oldID { gridPreviewID = newID }
        rebuildMap()
        applyFilters()
        if let browsing, let index = visibleItems.firstIndex(where: { $0.id == (browsing == oldID ? newID : browsing) }) {
            browseIndex = index
        }
    }

    /// Cache checking is injected so catalogue and indexing checks stay independent
    /// of cloud transport. The resolver performs disk work away from the main actor.
    /// Repeated completion/eviction events share one refresh and at most one filter
    /// pass per batch; transfer progress never requests a new filter pass.
    func refreshOriginalDownloadStatus(using loader: (@Sendable ([MediaItem]) async -> Set<String>)? = nil) {
        if let loader { originalCacheLoader = loader }
        guard originalCacheLoader != nil, !isTerminating else { return }
        originalCacheRefreshRequested = true
        guard originalCacheTask == nil else { return }
        isCheckingOriginalCache = true
        let token = UUID()
        originalCacheTaskToken = token
        originalCacheTask = Task { [weak self] in
            defer {
                if self?.originalCacheTaskToken == token {
                    self?.originalCacheTask = nil
                    self?.originalCacheTaskToken = nil
                    self?.isCheckingOriginalCache = false
                }
            }
            while !Task.isCancelled {
                // Full downloads often finish together. Allow their notifications
                // to settle before reading the index and rebuilding an active view.
                do { try await Task.sleep(for: .milliseconds(400)) }
                catch { return }
                guard let self, let loader = self.originalCacheLoader,
                      !self.isTerminating else { return }
                self.originalCacheRefreshRequested = false
                let revision = self.originalCacheItemsRevision
                let snapshot = self.items
                let downloaded = await loader(snapshot)
                guard !Task.isCancelled, !self.isTerminating,
                      self.originalCacheTaskToken == token else { return }
                if revision != self.originalCacheItemsRevision {
                    self.originalCacheRefreshRequested = true
                } else {
                    if !self.hasLoadedOriginalCache { self.hasLoadedOriginalCache = true }
                    if downloaded != self.originalDownloadedIDs {
                        self.originalDownloadedIDs = downloaded
                        if self.originalDownloadFilter != .all {
                            self.updateBrowseOriginalFilterPin()
                            // Opening an undownloaded original completes its download.
                            // Keep that viewing session alive instead of closing its
                            // window as soon as the file leaves the underlying filter.
                            if let id = self.previewID, let item = self.cachedMediaItem(id: id),
                               !self.matchesOriginalDownloadState(item) {
                                self.originalFilterRefreshDeferred = true
                            } else {
                                self.originalFilterRefreshDeferred = false
                                self.applyOriginalFiltersPreservingBrowsePosition()
                            }
                        }
                    }
                }
                if !self.originalCacheRefreshRequested { return }
            }
        }
    }

    func setSourceFilter(_ value: SourceFilter) {
        guard value != sourceFilter else { return }
        clearOriginalFilterDeferrals()
        sourceFilter = value
        if value != .cloud { originalDownloadFilter = .all }
        applyFilters()
    }

    func setOriginalDownloadFilter(_ value: OriginalDownloadFilter) {
        guard value != originalDownloadFilter else { return }
        clearOriginalFilterDeferrals()
        originalDownloadFilter = value
        if value != .all { sourceFilter = .cloud }
        applyFilters()
        if value != .all { refreshOriginalDownloadStatus() }
    }

    func toggleFormat(_ format: String) {
        clearOriginalFilterDeferrals()
        let normalized = Self.normalizedFormat(format)
        if selectedFormats.contains(normalized) { selectedFormats.remove(normalized) }
        else { selectedFormats.insert(normalized) }
        applyFilters()
    }

    func clearFormatFilter() {
        guard !selectedFormats.isEmpty else { return }
        clearOriginalFilterDeferrals()
        selectedFormats = []
        applyFilters()
    }

    /// Restores media filters together, leaving search, scope and sorting intact.
    func clearFilters() {
        guard hasActiveFilters else { return }
        clearOriginalFilterDeferrals()
        updatingMediaFilters = true
        filter = .all
        sourceFilter = .all
        originalDownloadFilter = .all
        selectedFormats = []
        updatingMediaFilters = false
        applyFilters()
    }

    /// Display file extensions rather than a codec guessed from a cached cover.
    /// A cloud file's source name can differ from its opaque local locator URL.
    static func formatIdentifier(for item: MediaItem) -> String {
        normalizedFormat((item.name as NSString).pathExtension)
    }

    private static func normalizedFormat(_ format: String) -> String {
        let value = format.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return value.isEmpty ? "无扩展名" : value.uppercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private func applyOriginalFiltersPreservingBrowsePosition() {
        let currentID = layout == .browse && visibleItems.indices.contains(browseIndex) ? visibleItems[browseIndex].id : nil
        let oldIndex = browseIndex
        let oldPosition = browsePosition
        applyFilters()
        if let currentID, let index = visibleIndexByID[currentID], oldPosition.isFinite {
            browsePosition = min(Double(max(0, visibleItems.count - 1)), max(0, oldPosition + Double(index - oldIndex)))
        }
    }

    private func clearOriginalFilterDeferrals() {
        originalFilterRefreshDeferred = false
        originalFilterBrowsePinnedID = nil
    }

    /// Keep the roll's current photo when a completed original changes its
    /// download eligibility. Reusing its ID also protects catalogue regrouping.
    private func updateBrowseOriginalFilterPin() {
        guard layout == .browse, visibleItems.indices.contains(browseIndex) else {
            originalFilterBrowsePinnedID = nil
            return
        }
        let current = visibleItems[browseIndex]
        if !matchesOriginalDownloadState(current) {
            // A batch selection owns the collection's snapshot until the mode
            // ends; replacing this pin mid-stroke could invalidate its ranges.
            if !isSelectionMode || originalFilterBrowsePinnedID == nil {
                originalFilterBrowsePinnedID = current.id
            }
        } else if originalFilterBrowsePinnedID == current.id {
            originalFilterBrowsePinnedID = nil
        }
    }

    /// Drain the old exception after focus moves, preserving the new photo and
    /// its fractional scroll position even when removing a preceding item.
    private func settleBrowseOriginalFilterIfNeeded(position: Double) {
        guard layout == .browse, !isSelectionMode,
              let pinnedID = originalFilterBrowsePinnedID,
              visibleItems.indices.contains(browseIndex) else { return }
        let current = visibleItems[browseIndex]
        guard current.id != pinnedID else { return }
        let oldIndex = browseIndex
        originalFilterBrowsePinnedID = nil
        guard !originalFilterRefreshDeferred else { return }
        applyFilters()
        if let index = visibleIndexByID[current.id] {
            browsePosition = min(Double(max(0, visibleItems.count - 1)), max(0, position + Double(index - oldIndex)))
        }
    }

    private func matchesOriginalDownloadState(_ item: MediaItem) -> Bool {
        switch originalDownloadFilter {
        case .all: true
        case .downloaded: item.cloud != nil && originalDownloadedIDs.contains(item.id)
        case .notDownloaded: item.cloud != nil && !originalDownloadedIDs.contains(item.id)
        }
    }

    private func isInCurrentScope(_ item: MediaItem, albumIDs: Set<String>) -> Bool {
        switch scope {
        case .all: !hiddenIDs.contains(item.id)
        case .favorites: !hiddenIDs.contains(item.id) && favorites.contains(item.id)
        case .folders: !hiddenIDs.contains(item.id) && directorySelection.contains(item.selectionPath)
        case .hidden: hiddenIDs.contains(item.id)
        case .album: !hiddenIDs.contains(item.id) && albumIDs.contains(item.id)
        }
    }

    func applyFilters() {
        prepareMetadataItemIndex()
        let browsingID = navigationAnchorID
            ?? (visibleItems.indices.contains(browseIndex) ? visibleItems[browseIndex].id : nil)
        let previousVisibleRevision = visibleRevision
        let terms = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeAlbumIDs: Set<String>
        if case .album(let id) = scope { activeAlbumIDs = albums.first(where: { $0.id == id })?.itemIDs ?? [] }
        else { activeAlbumIDs = [] }
        var formats = selectedFormats
        let ignoreDotFiles = self.ignoreDotFiles
        let dotRoots = libraries.map(\.selectionPath).sorted { $0.count < $1.count }
        let filtered = items.filter { item in
            guard isInCurrentScope(item, albumIDs: activeAlbumIDs) else { return false }
            if ignoreDotFiles && Self.hasDotComponent(item.selectionPath, roots: dotRoots) { return false }
            let format = formatByID[item.id] ?? Self.formatIdentifier(for: item)
            formats.insert(format)
            let inFilter = filter == .all || (filter == .image && item.kind == .image) || (filter == .video && item.kind == .video)
            let inFormat = selectedFormats.isEmpty || selectedFormats.contains(format)
            let inSource = sourceFilter == .all || (sourceFilter == .local && item.isLocal)
                || (sourceFilter == .cloud && item.cloud != nil)
            // Only automatic cache changes may retain a currently viewed file.
            // Explicit filters clear these exceptions; every other dimension
            // still applies, including hidden items and directory scope.
            let inDownload = matchesOriginalDownloadState(item)
                || (originalFilterRefreshDeferred && previewID == item.id)
                || (layout == .browse && originalFilterBrowsePinnedID == item.id)
            let matches = terms.isEmpty || item.name.localizedStandardContains(terms) || item.url.deletingLastPathComponent().lastPathComponent.localizedStandardContains(terms)
            return inFilter && inFormat && inSource && inDownload && matches
        }.sorted { left, right in
            let comparison: ComparisonResult
            switch sort {
            case .name: comparison = left.name.localizedStandardCompare(right.name)
            case .size: comparison = left.fileSize == right.fileSize ? .orderedSame : (left.fileSize < right.fileSize ? .orderedAscending : .orderedDescending)
            case .captured: comparison = left.displayDate.compare(right.displayDate)
            case .created: comparison = left.createdDate.compare(right.createdDate)
            case .modified: comparison = left.modifiedDate.compare(right.modifiedDate)
            }
            if comparison == .orderedSame { return left.id < right.id }
            return descending ? comparison == .orderedDescending : comparison == .orderedAscending
        }
        let nextFormats = formats.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if availableFormats != nextFormats { availableFormats = nextFormats }
        let previousSectionItem = timelineSections.first { $0.id == visibleTimelineSectionID }?.items.first?.id
        let sections = TimelineGrouping.sections(for: filtered, scale: timelineScale, dateBasis: timelineDateBasis, descending: descending)
        let ordered = sections.flatMap(\.items)
        let sectionsChanged = sections.map(\.id) != timelineSections.map(\.id)
            || sections.map(\.items) != timelineSections.map(\.items)
        if sectionsChanged { timelineSections = sections; timelineRevision += 1 }
        if visibleItems != ordered { visibleItems = ordered; visibleRevision += 1 }
        if !sections.contains(where: { $0.id == visibleTimelineSectionID }) {
            visibleTimelineSectionID = sections.first(where: { section in
                section.items.contains { $0.id == previousSectionItem }
            })?.id ?? sections.first?.id
        }
        let visibleIDs = Set(visibleItems.map(\.id))
        selectedIDs.formIntersection(visibleIDs)
        if let selectionAnchor, !visibleIDs.contains(selectionAnchor) { self.selectionAnchor = nil }
        if let keyboardCursor, !visibleIDs.contains(keyboardCursor) { self.keyboardCursor = nil }
        browseIndex = browsingID.flatMap { id in visibleItems.firstIndex { $0.id == id } } ?? min(browseIndex, max(0, visibleItems.count - 1))
        if previousVisibleRevision != visibleRevision { browsePosition = Double(browseIndex) }
        if let navigationAnchorID, !visibleIDs.contains(navigationAnchorID) { self.navigationAnchorID = nil }
        if let gridPreviewID, !visibleIDs.contains(gridPreviewID) { self.gridPreviewID = nil }
        if let previewID, !visibleItems.contains(where: { $0.id == previewID }) { self.previewID = nil }
    }

    func setSelectionMode(_ enabled: Bool) {
        guard isSelectionMode != enabled else { return }
        isSelectionMode = enabled
        gridPreviewID = nil
        selectionModeRevision &+= 1
        selectedIDs = []
        selectionAnchor = nil
        if !enabled { settleBrowseOriginalFilterIfNeeded(position: browsePosition) }
    }

    func focus(_ item: MediaItem) {
        guard let index = visibleIndexByID[item.id] else { return }
        keyboardCursor = item.id
        browseIndex = index
        browsePosition = Double(index)
        browseScrollRequestID += 1
        navigationAnchorID = item.id
        if !isSelectionMode, !selectedIDs.isEmpty {
            selectedIDs = [item.id]
            selectionAnchor = item.id
        }
        settleBrowseOriginalFilterIfNeeded(position: browsePosition)
    }

    func activate(_ item: MediaItem, modifiers: NSEvent.ModifierFlags = []) {
        guard visibleItems.contains(where: { $0.id == item.id }) else { return }
        if isSelectionMode {
            select(item, modifiers: modifiers.contains(.shift) ? modifiers : modifiers.union(.command))
        } else { select(item) }
    }

    func select(_ item: MediaItem, modifiers: NSEvent.ModifierFlags = []) {
        guard visibleItems.contains(where: { $0.id == item.id }) else { return }
        showInspector = true
        if !isSelectionMode {
            focus(item)
            selectedIDs = [item.id]
            selectionAnchor = item.id
            gridPreviewID = layout == .grid && item.kind == .video ? item.id : nil
            return
        }
        keyboardCursor = item.id
        navigationAnchorID = item.id
        if modifiers.contains(.shift), let anchor = selectionAnchor,
           let start = visibleItems.firstIndex(where: { $0.id == anchor }),
           let end = visibleItems.firstIndex(where: { $0.id == item.id }) {
            let range = Set(visibleItems[min(start, end)...max(start, end)].map(\.id))
            if modifiers.contains(.command) { selectedIDs.formUnion(range) } else { selectedIDs = range }
        } else if modifiers.contains(.command) {
            if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) }
            selectionAnchor = item.id
        } else { selectedIDs = [item.id]; selectionAnchor = item.id }
        if let index = visibleItems.firstIndex(where: { $0.id == item.id }) { browseIndex = index }
    }

    func moveSelection(by offset: Int, extend: Bool = false) {
        guard !visibleItems.isEmpty else { return }
        let current = visibleItems.firstIndex(where: { $0.id == keyboardCursor ?? selectionAnchor }) ?? (offset > 0 ? -1 : visibleItems.count)
        let next = min(max(current + offset, 0), visibleItems.count - 1)
        select(visibleItems[next], modifiers: extend ? [.shift] : [])
    }

    func selectAll() { if isSelectionMode { selectedIDs = Set(visibleItems.map(\.id)) } }
    func clearSelection() { selectedIDs = []; selectionAnchor = nil; keyboardCursor = nil; gridPreviewID = nil }
    func open(_ item: MediaItem? = nil) {
        guard let target = item ?? keyboardCursor.flatMap({ itemMap[$0] }) ?? selectedItems.first ?? visibleItems.first else { return }
        guard visibleItems.contains(where: { $0.id == target.id }) else { return }
        focus(target)
        gridPreviewID = nil
        previewID = target.id
        viewerOpenRequestID += 1
    }
    func closePreview() { previewID = nil }
    func stepPreview(_ delta: Int) {
        guard let id = previewID, let current = visibleItems.firstIndex(where: { $0.id == id }), !visibleItems.isEmpty else { return }
        let next = min(max(current + delta, 0), visibleItems.count - 1)
        previewID = visibleItems[next].id
        focus(visibleItems[next])
    }
    func toggleFavorite(_ item: MediaItem) {
        if favorites.contains(item.id) { favorites.remove(item.id) } else { favorites.insert(item.id) }
        save(); if scope == .favorites { applyFilters() }
    }
    func favoriteSelection() {
        if previewID != nil, let item = focusedItem { toggleFavorite(item); return }
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        if ids.isSubset(of: favorites) { favorites.subtract(ids) } else { favorites.formUnion(ids) }
        save(); if scope == .favorites { applyFilters() }
    }
    func toggleInspector() {
        if NSApp?.keyWindow?.identifier?.rawValue == "viewer" { showViewerInspector.toggle() }
        else { showInspector.toggle() }
    }
    func reveal(_ item: MediaItem) {
        if item.isLocal { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        else { materialize([item]) { NSWorkspace.shared.activateFileViewerSelecting($0) } }
    }
    func openExternally(_ item: MediaItem) {
        materialize([item]) { [weak self] urls in
            if let url = urls.first, !NSWorkspace.shared.open(url) { self?.errorMessage = "无法打开“\(item.name)”。文件可能已移动或离线。" }
        }
    }
    func copySelectedPaths() {
        NSPasteboard.general.clearContents()
        let targets = previewID != nil ? focusedItem.map { [$0] } ?? [] : selectedItems
        NSPasteboard.general.setString(targets.map(\.displayPath).joined(separator: "\n"), forType: .string)
        notify("已复制路径")
    }
    @discardableResult func copySelectedFiles(to pasteboard: NSPasteboard = .general) -> Bool {
        if selectedItems.contains(where: { !$0.isLocal }) {
            copyFiles(selectedItems, to: pasteboard)
            return !selectedItems.isEmpty
        }
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return false }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(urls as [NSURL]) else {
            errorMessage = "无法复制所选文件，请重试。"
            return false
        }
        notify("已复制 \(urls.count) 个项目")
        return true
    }
    func isOffline(_ item: MediaItem) -> Bool {
        libraries.contains { offlineLibraries.contains($0.id) && item.belongs(to: $0) }
            && !libraries.contains { !offlineLibraries.contains($0.id) && item.belongs(to: $0) }
    }
    func notify(_ message: String) {
        noticeTask?.cancel(); notice = message
        noticeTask = Task { try? await Task.sleep(for: .seconds(2.5)); if !Task.isCancelled { notice = nil } }
    }
    func save() {
        guard catalogWritable else { return }
        metadataPersistenceTask?.cancel(); metadataPersistenceTask = nil
        let state = catalogState
        saveRevision += 1
        let revision = saveRevision
        // Debounce writes so repeated favorites do not repeatedly serialize a large index.
        persistenceTask?.cancel()
        persistenceTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            do {
                try await writer.save(state, revision: revision)
                recordSaveSuccess(revision: revision)
            } catch { recordSaveFailure(error, revision: revision) }
        }
    }
    func flush() {
        Task { await flushImmediately() }
    }
    @discardableResult
    func flushImmediately() async -> Bool {
        metadataPersistenceTask?.cancel(); metadataPersistenceTask = nil
        // A protected, unreadable startup catalog must not trap an unchanged app
        // in a quit loop. New in-memory records still cannot replace its original.
        guard catalogWritable else {
            if catalogMatches(CatalogState()) { return true }
            if errorMessage == nil { errorMessage = "无法安全保存资源库记录，内存中的更改尚未保存。" }
            return false
        }
        while true {
            persistenceTask?.cancel()
            saveRevision += 1
            let revision = saveRevision
            let state = catalogState
            do {
                try await writer.save(state, revision: revision)
                recordSaveSuccess(revision: revision)
            } catch {
                recordSaveFailure(error, revision: revision)
                return false
            }
            // Collection edits can arrive while the writer is awaited. Persist
            // that latest state too, rather than approving an older quit snapshot.
            if catalogMatches(state) { return true }
        }
    }
    private func recordSaveSuccess(revision: Int) {
        guard revision >= lastSaveOutcomeRevision else { return }
        lastSaveOutcomeRevision = revision
        if let persistenceFailureMessage, errorMessage == persistenceFailureMessage { errorMessage = nil }
        persistenceFailureMessage = nil
    }
    private func recordSaveFailure(_ error: Error, revision: Int) {
        guard revision >= lastSaveOutcomeRevision else { return }
        lastSaveOutcomeRevision = revision
        let message = "无法保存资源库：\(error.localizedDescription)"
        persistenceFailureMessage = message
        errorMessage = message
        NSLog("Filmbox catalog save failed: %@", error.localizedDescription)
    }
    private func catalogMatches(_ state: CatalogState) -> Bool {
        libraries == state.libraries && favorites == state.favorites && items == state.cachedItems
            && hiddenIDs == state.hiddenIDs && albums == state.albums && cloudAccounts == state.cloudAccounts
    }
    private var catalogState: CatalogState {
        CatalogState(libraries: libraries, favorites: favorites, cachedItems: items, hiddenIDs: hiddenIDs, albums: albums, cloudAccounts: cloudAccounts)
    }
    private func rebuildMap() {
        CloudMediaRegistry.shared.register(items)
        let accounts = cloudAccounts
        Task { await CloudGateway.shared.register(accounts: accounts) }
        itemMap = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        itemIndexByID = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        formatByID = Dictionary(items.map { ($0.id, Self.formatIdentifier(for: $0)) }, uniquingKeysWith: { a, _ in a })
        metadataItemIndexDirty = false
        catalogueStructureRevision &+= 1
        var counts: [String: Int] = [:]
        var knownFolders = Dictionary(folders.map { ($0.selectionPath, $0) }, uniquingKeysWith: { first, _ in first })
        let ignoreDotFiles = self.ignoreDotFiles
        let dotRoots = libraries.map(\.selectionPath).sorted { $0.count < $1.count }
        var countedItems = 0
        for item in items {
            if ignoreDotFiles && Self.hasDotComponent(item.selectionPath, roots: dotRoots) { continue }
            countedItems += 1
            var path = (item.selectionPath as NSString).deletingLastPathComponent
            let cloudRoot = item.cloud.map { CloudMediaPath.selectionPath(accountID: $0.accountID, path: "/") }
            while path != "/" && !path.isEmpty {
                if !hiddenIDs.contains(item.id) { counts[path, default: 0] += 1 }
                if knownFolders[path] == nil {
                    if let cloud = item.cloud {
                        let remote = String(path.dropFirst(cloudRoot!.count))
                        knownFolders[path] = MediaFolder(cloud: CloudFolderReference(accountID: cloud.accountID, folderID: path, path: remote))
                    } else {
                        knownFolders[path] = MediaFolder(url: URL(fileURLWithPath: path), parentPath: (path as NSString).deletingLastPathComponent)
                    }
                }
                if path == cloudRoot { break }
                path = (path as NSString).deletingLastPathComponent
            }
        }
        excludedDotItemCount = items.count - countedItems
        indexedItemCount = countedItems
        folderCounts = counts
        childFolders = Dictionary(grouping: knownFolders.values.filter { !ignoreDotFiles || !Self.hasDotComponent($0.selectionPath, roots: dotRoots) }, by: { $0.parentPath ?? "" }).mapValues { $0.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    }
    static func isInside(_ file: String, folder: String) -> Bool { file == folder || file.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/") }
}

private struct MediaFileActionError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// This actor is deliberately separate from UI and scanning. There is no
/// permanent-delete fallback, and rename uses the filesystem's exclusive move.
private actor MediaFileOperations {
    struct TrashOutcome: Sendable {
        var successfulIDs: Set<String> = []
        var failures: [String] = []
    }

    nonisolated static func destinationName(for url: URL, proposed: String) throws -> String {
        var base = proposed.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        let forbidden = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
        guard !base.isEmpty, !base.unicodeScalars.contains(where: forbidden.contains) else {
            throw MediaFileActionError(message: "名称不能为空，也不能包含路径分隔符或控制字符。")
        }
        let originalExtension = url.pathExtension
        if !originalExtension.isEmpty,
           (base as NSString).pathExtension.compare(originalExtension, options: .caseInsensitive) == .orderedSame {
            base = (base as NSString).deletingPathExtension
        }
        guard !base.isEmpty, !base.hasPrefix("."), !base.hasSuffix(".") else {
            throw MediaFileActionError(message: "名称不能以句点开头或结尾。")
        }
        let filename = originalExtension.isEmpty ? base : base + "." + originalExtension
        guard filename.utf8.count <= 255 else { throw MediaFileActionError(message: "文件名过长，请缩短后重试。") }
        return filename
    }

    func rename(_ item: MediaItem, to filename: String) throws -> URL {
        guard !Task.isCancelled else { throw MediaFileActionError(message: "操作已取消。") }
        let source = try verifiedSource(item)
        let destination = source.deletingLastPathComponent().appendingPathComponent(filename).standardizedFileURL
        let status = source.path.withCString { from in
            destination.path.withCString { to in Darwin.renamex_np(from, to, UInt32(RENAME_EXCL)) }
        }
        if status != 0 {
            let code = errno
            if code == EEXIST { throw MediaFileActionError(message: "同一文件夹中已存在“\(filename)”，未覆盖任何文件。") }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return destination
    }

    func rotate(_ item: MediaItem, direction: PhotoRotationDirection) throws -> MediaItem {
        _ = try verifiedSource(item)
        return try LocalPhotoRotation.rotate(item, direction: direction)
    }

    func trash(_ items: [MediaItem]) -> TrashOutcome {
        var outcome = TrashOutcome()
        for item in items {
            do {
                guard !Task.isCancelled else { throw MediaFileActionError(message: "操作已取消。") }
                let source = try verifiedSource(item)
                // Foundation returns success only after moving the item to a Trash.
                // Never replace this with removeItem, including on unsupported disks.
                try FileManager.default.trashItem(at: source, resultingItemURL: nil)
                outcome.successfulIDs.insert(item.id)
            } catch {
                outcome.failures.append("“\(item.name)”（\(item.url.deletingLastPathComponent().lastPathComponent)）：\(error.localizedDescription)")
            }
        }
        return outcome
    }

    private func verifiedSource(_ item: MediaItem) throws -> URL {
        guard item.isLocal, item.url.isFileURL else { throw MediaFileActionError(message: "云盘原文件目前仅供浏览。") }
        // Recreate the URL to avoid resource values cached in an older URL object.
        let url = URL(fileURLWithPath: item.url.path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MediaFileActionError(message: "目标不是普通媒体文件，未执行操作。")
        }
        let modified = values.contentModificationDate ?? values.creationDate ?? .distantPast
        let created = values.creationDate ?? modified
        guard modified == item.modifiedDate, created == item.createdDate, Int64(values.fileSize ?? 0) == item.fileSize else {
            throw MediaFileActionError(message: "文件在扫描后已变更，请刷新后重试。")
        }
        return url
    }
}

private actor CatalogWriter {
    private let persistence: CatalogPersistence
    private var lastRevision = -1
    private var lastState: CatalogState?
    private var lastFileStamp: String?
    init(directory: URL? = nil) { persistence = CatalogPersistence(directory: directory) }
    func save(_ state: CatalogState, revision: Int) throws {
        guard revision >= lastRevision else { return }
        if let stamp = LocalFileRevision.stamp(at: persistence.fileURL), stamp == lastFileStamp, state == lastState {
            lastRevision = revision
            return
        }
        try persistence.save(state)
        lastRevision = revision
        lastState = state
        lastFileStamp = LocalFileRevision.stamp(at: persistence.fileURL)
    }
}
