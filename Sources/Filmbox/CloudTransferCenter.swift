import Foundation
import Observation
import FilmboxCore

extension Notification.Name {
    /// Disk availability changed; byte progress and thumbnail work do not
    /// invalidate the library's downloaded-original filter.
    static let filmboxCloudOriginalCacheChanged = Notification.Name("FilmboxCloudOriginalCacheChanged")
}

@MainActor private enum OriginalCachePublication {
    static var pending: Task<Void, Never>?
    static func schedule() {
        guard pending == nil else { return }
        pending = Task {
            try? await Task.sleep(for: .milliseconds(120))
            pending = nil
            NotificationCenter.default.post(name: .filmboxCloudOriginalCacheChanged, object: nil)
        }
    }
}

enum CloudTransferPurpose: String, Sendable, CaseIterable { case thumbnail, original }
enum CloudTransferPriority: Int, Sendable { case background, foreground }
enum CloudTransferState: String, Sendable { case idle, queued, downloading, ready, failed, paused, noPreview }

struct CloudAccountIssue: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case authenticationRequired }
    let kind: Kind
    let message: String
}

struct CloudTransferSnapshot: Identifiable, Equatable, Sendable {
    var id: String { itemID + "|" + purpose.rawValue }
    let itemID: String
    let name: String
    let purpose: CloudTransferPurpose
    var state: CloudTransferState
    var receivedBytes: Int64
    var totalBytes: Int64?
    var errorMessage: String?
    var errorCode: String? = nil
    var isOriginalCached: Bool
    var updatedAt: Date
    var priority: CloudTransferPriority
    var progress: Double? {
        guard let totalBytes, totalBytes > 0 else { return state == .ready ? 1 : nil }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }
}

struct CloudCacheSizes: Sendable {
    let originalBytes: Int64
    let thumbnailBytes: Int64
    let protectedBytes: Int64
    var totalBytes: Int64 { originalBytes + thumbnailBytes }
}
struct CloudCacheCleanup: Sendable { let removedBytes: Int64; let protectedBytes: Int64 }

/// All visible transfer state is shared by grids, viewers and Settings. Network
/// traffic comes only from the helper's upstream counters, never loopback bytes.
@MainActor @Observable
final class CloudTransferCenter {
    static let shared = CloudTransferCenter()
    @ObservationIgnored private var records: [String: CloudTransferSnapshot] = [:]
    @ObservationIgnored private var tokens: [String: UUID] = [:]
    @ObservationIgnored private var originalCache = Set<String>()
    @ObservationIgnored private var items: [String: MediaItem] = [:]
    @ObservationIgnored private let itemObservation = ObservationRegistrar()
    @ObservationIgnored private var sortedTasks: [CloudTransferSnapshot]?
    @ObservationIgnored private var taskPublication: Task<Void, Never>?
    private var tasksVersion = 0
    private(set) var activeCount = 0
    private(set) var queuedCount = 0
    /// Authentication failures are presented once per account, not per file.
    private(set) var failedCount = 0
    @ObservationIgnored private var promotedTokens = Set<UUID>()
    private(set) var accountIssues: [UUID: CloudAccountIssue] = [:]
    private(set) var connectionProblems: [UUID: ResourceProblem] = [:]
    func connectionFailed(accountID: UUID, problem: ResourceProblem) { connectionProblems[accountID] = problem }
    func connectionResponded(accountID: UUID) { connectionProblems[accountID] = nil }
    private(set) var isBackgroundPaused = false
    private(set) var sessionReceivedBytes: Int64 = 0
    private(set) var todayReceivedBytes: Int64 = 0
    private(set) var bytesPerSecond: Double = 0
    private(set) var activeStreamCount = 0
    @ObservationIgnored private var trafficTotals: [String: Int64] = [:]
    @ObservationIgnored private var trafficDays: [String: Int64] = [:]
    @ObservationIgnored private var lastTrafficTime: Date?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var dayKey: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dayKey = Self.todayKey()
        if defaults.string(forKey: "cloudTrafficDay") == dayKey {
            todayReceivedBytes = max(0, Int64(defaults.double(forKey: "cloudTrafficTodayBytes")))
        }
    }
    var tasks: [CloudTransferSnapshot] {
        _ = tasksVersion
        if let sortedTasks { return sortedTasks }
        let result = records.values.sorted { $0.updatedAt > $1.updatedAt }
        sortedTasks = result
        return result
    }
    // A dynamic subscript key path includes the item ID. Observation can track
    // each visible item without retaining thousands of observable row objects.
    private subscript(observed itemID: String) -> Int { 0 }
    var receivedBytes: Int64 { sessionReceivedBytes }
    var speed: Double { bytesPerSecond }

    func issue(for accountID: UUID) -> CloudAccountIssue? { accountIssues[accountID] }
    func accountID(for itemID: String) -> UUID? { items[itemID]?.cloud?.accountID }
    func requireLogin(accountID: UUID) {
        guard accountIssues[accountID] == nil else { return }
        let issue = CloudAccountIssue(kind: .authenticationRequired, message: MediaFailureText.login)
        accountIssues[accountID] = issue
        for key in records.keys where self.accountID(for: records[key]!.itemID) == accountID {
            guard let state = records[key]?.state, [.queued, .downloading, .paused].contains(state) else { continue }
            if let token = tokens.removeValue(forKey: key) { promotedTokens.remove(token) }
            var value = records[key]!
            value.state = .failed
            value.errorMessage = issue.message
            value.updatedAt = .now
            setRecord(value, key: key)
        }
        // Invalidate state first; delayed cancellation/progress callbacks cannot
        // turn the account's failed rows back into idle or downloading.
        recalculateCounts()
        let cutoff = ProcessInfo.processInfo.systemUptime
        Task { await MediaAssetResolver.cancelAllTransfers(accountID: accountID, createdBefore: cutoff) }
    }
    func connectionRecovered(accountID: UUID) {
        connectionProblems[accountID] = nil
        let previous = accountIssues.removeValue(forKey: accountID)
        guard let previous else { return }
        for key in records.keys where self.accountID(for: records[key]!.itemID) == accountID {
            if records[key]?.state == .failed, records[key]?.errorMessage == previous.message {
                var value = records[key]!
                value.state = .idle
                value.errorMessage = nil
                setRecord(value, key: key)
            }
        }
        recalculateCounts()
    }
    func forgetConnection(accountID: UUID) {
        accountIssues[accountID] = nil
        connectionProblems[accountID] = nil
        let ids = Set(items.values.filter { $0.cloud?.accountID == accountID }.map(\.id))
        for key in records.keys where ids.contains(records[key]!.itemID) { setRecord(nil, key: key); tokens[key] = nil }
        for id in ids { items[id] = nil; setOriginalCached(id, cached: false) }
        recalculateCounts()
        let cutoff = ProcessInfo.processInfo.systemUptime
        Task { await MediaAssetResolver.cancelAllTransfers(accountID: accountID, createdBefore: cutoff) }
    }

    func register(item: MediaItem) {
        if let previous = items[item.id], previous.cloud?.revision != item.cloud?.revision
            || previous.fileSize != item.fileSize || previous.modifiedDate != item.modifiedDate || previous.name != item.name {
            setOriginalCached(item.id, cached: false)
            for purpose in CloudTransferPurpose.allCases { let key = key(item.id, purpose); setRecord(nil, key: key); tokens[key] = nil }
        }
        items[item.id] = item
    }

    func snapshot(for itemID: String, purpose: CloudTransferPurpose = .original) -> CloudTransferSnapshot? {
        itemObservation.access(self, keyPath: \.[observed: itemID])
        guard var value = records[key(itemID, purpose)] else {
            guard purpose == .original, originalCache.contains(itemID) else { return nil }
            return CloudTransferSnapshot(itemID: itemID, name: items[itemID]?.name ?? "原文件", purpose: .original,
                state: .ready, receivedBytes: 0, totalBytes: nil, errorMessage: nil, isOriginalCached: true,
                updatedAt: .distantPast, priority: .foreground)
        }
        value.isOriginalCached = originalCache.contains(itemID)
        return value
    }
    func pauseBackground(_ paused: Bool = true) {
        isBackgroundPaused = paused
        for key in records.keys where records[key]?.priority == .background {
            if var value = records[key] {
                if value.state == .queued && paused { value.state = .paused }
                else if value.state == .paused && !paused { value.state = .queued }
                setRecord(value, key: key)
            }
        }
        Task { await MediaAssetResolver.shared.setBackgroundPaused(paused) }
    }
    func cancel(itemID: String, purpose: CloudTransferPurpose? = nil) {
        Task { await MediaAssetResolver.shared.cancel(itemID: itemID, purpose: purpose) }
    }
    func cancelAllBackground() { Task { await MediaAssetResolver.shared.cancelAllBackground() } }
    func retry(itemID: String, purpose: CloudTransferPurpose = .original) {
        guard let item = items[itemID] else { return }
        Task {
            if purpose == .original { _ = try? await MediaAssetResolver.shared.originalFile(for: item) }
            else { _ = try? await MediaAssetResolver.shared.thumbnailFile(for: item.url) }
        }
    }

    func queued(item: MediaItem, purpose: CloudTransferPurpose, priority: CloudTransferPriority, token: UUID) {
        register(item: item)
        let priority: CloudTransferPriority = promotedTokens.remove(token) != nil ? .foreground : priority
        let key = key(item.id, purpose)
        let issue = item.cloud.flatMap { accountIssues[$0.accountID] }
        tokens[key] = issue == nil ? token : nil
        setRecord(CloudTransferSnapshot(itemID: item.id, name: item.name, purpose: purpose,
            state: issue != nil ? .failed : (priority == .background && isBackgroundPaused ? .paused : .queued),
            receivedBytes: 0, totalBytes: purpose == .original && item.fileSize > 0 ? item.fileSize : nil,
            errorMessage: issue?.message, isOriginalCached: originalCache.contains(item.id), updatedAt: .now, priority: priority), key: key)
        pruneHistory()
    }
    func started(itemID: String, purpose: CloudTransferPurpose, token: UUID) {
        mutate(itemID, purpose, token) { $0.state = .downloading; $0.updatedAt = .now }
    }
    func promoted(itemID: String, purpose: CloudTransferPurpose, token: UUID) {
        if tokens[key(itemID, purpose)] != token { promotedTokens.insert(token) }
        if promotedTokens.count > 512 { promotedTokens = Set(promotedTokens.prefix(512)) }
        mutate(itemID, purpose, token) { $0.priority = .foreground; if $0.state == .paused { $0.state = .queued } }
    }
    func progress(itemID: String, purpose: CloudTransferPurpose, token: UUID, received: Int64, total: Int64?) {
        if let previous = records[key(itemID, purpose)], previous.receivedBytes >= received,
           total == nil || previous.totalBytes == total { return }
        mutate(itemID, purpose, token) {
            $0.receivedBytes = max($0.receivedBytes, received)
            if let total, total > 0 { $0.totalBytes = total }
            $0.updatedAt = .now
        }
    }
    func finished(item: MediaItem, purpose: CloudTransferPurpose, token: UUID, bytes: Int64) {
        guard tokens[key(item.id, purpose)] == token else { return }
        cached(item: item, purpose: purpose, bytes: bytes)
    }
    func failed(itemID: String, purpose: CloudTransferPurpose, token: UUID, error: Error) {
        mutate(itemID, purpose, token) {
            let noPreview = purpose == .thumbnail && (error as? CloudConnectionError).map { if case .thumbnailUnavailable = $0 { return true }; return false } == true
            $0.state = noPreview ? .noPreview : (error is CancellationError ? .idle : .failed)
            $0.errorMessage = noPreview || error is CancellationError ? nil : MediaFailureText.transferError(error)
            $0.errorCode = noPreview || error is CancellationError ? nil : MediaFailureText.problem(error).rawValue
            $0.updatedAt = .now
        }
    }
    func cached(item: MediaItem, purpose: CloudTransferPurpose, bytes: Int64) {
        register(item: item)
        if purpose == .original { setOriginalCached(item.id, cached: true) }
        let isCached = originalCache.contains(item.id)
        // A file has only these two records; never scan the whole task history
        // for every cover produced by the background library sweep.
        for otherPurpose in CloudTransferPurpose.allCases {
            let otherKey = key(item.id, otherPurpose)
            guard var value = records[otherKey] else { continue }
            value.isOriginalCached = isCached
            if purpose == .original, otherPurpose == .thumbnail,
               item.cloud.flatMap({ accountIssues[$0.accountID] }) == nil,
               [.failed, .noPreview].contains(value.state) {
                value.state = .idle; value.errorMessage = nil
            }
            setRecord(value, key: otherKey)
        }
        let key = key(item.id, purpose)
        tokens[key] = nil
        setRecord(CloudTransferSnapshot(itemID: item.id, name: item.name, purpose: purpose, state: .ready,
            receivedBytes: bytes, totalBytes: bytes, errorMessage: nil, isOriginalCached: isCached,
            updatedAt: records[key]?.updatedAt ?? .now, priority: .foreground), key: key)
        pruneHistory()
    }
    func cacheRemoved(itemID: String, purpose: CloudTransferPurpose) {
        if purpose == .original { setOriginalCached(itemID, cached: false) }
        let isCached = originalCache.contains(itemID)
        for otherPurpose in CloudTransferPurpose.allCases {
            let recordKey = key(itemID, otherPurpose)
            guard var value = records[recordKey] else { continue }
            value.isOriginalCached = isCached
            if otherPurpose == purpose, value.state == .ready {
                value.state = .idle; value.receivedBytes = 0; value.errorMessage = nil
            }
            setRecord(value, key: recordKey)
        }
    }
    func traffic(sessionID: String, received: Int64, days: [String: Int64], activeStreams: Int) {
        let now = Date(), today = Self.todayKey()
        let changedDay = dayKey != today
        if changedDay { dayKey = today; if todayReceivedBytes != 0 { todayReceivedBytes = 0 } }
        let delta = max(0, received - (trafficTotals[sessionID] ?? 0))
        trafficTotals[sessionID] = max(received, trafficTotals[sessionID] ?? 0)
        if delta > 0 { sessionReceivedBytes += delta }
        let dailyKey = sessionID + "|" + today
        let dayBytes = max(0, days[today] ?? 0)
        let dayDelta = max(0, dayBytes - (trafficDays[dailyKey] ?? 0))
        if dayDelta > 0 { todayReceivedBytes += dayDelta }
        trafficDays[dailyKey] = max(dayBytes, trafficDays[dailyKey] ?? 0)
        if let lastTrafficTime {
            let speed = Double(delta) / max(0.1, now.timeIntervalSince(lastTrafficTime))
            if bytesPerSecond != speed { bytesPerSecond = speed }
        }
        self.lastTrafficTime = now
        let streams = max(0, activeStreams)
        if activeStreamCount != streams { activeStreamCount = streams }
        if changedDay || dayDelta > 0 {
            defaults.set(dayKey, forKey: "cloudTrafficDay")
            defaults.set(Double(todayReceivedBytes), forKey: "cloudTrafficTodayBytes")
        }
    }
    func trafficStopped() { bytesPerSecond = 0; activeStreamCount = 0; lastTrafficTime = nil }

    private func key(_ itemID: String, _ purpose: CloudTransferPurpose) -> String { itemID + "|" + purpose.rawValue }
    private func mutate(_ itemID: String, _ purpose: CloudTransferPurpose, _ token: UUID, change: (inout CloudTransferSnapshot) -> Void) {
        let key = key(itemID, purpose)
        guard tokens[key] == token, var value = records[key] else { return }
        change(&value); setRecord(value, key: key)
    }
    private func isActionableFailure(_ value: CloudTransferSnapshot?) -> Bool {
        guard let value, value.state == .failed else { return false }
        return accountID(for: value.itemID).flatMap { accountIssues[$0] } == nil
    }
    private func setOriginalCached(_ itemID: String, cached: Bool) {
        guard originalCache.contains(itemID) != cached else { return }
        itemObservation.withMutation(of: self, keyPath: \.[observed: itemID]) {
            if cached { originalCache.insert(itemID) }
            else { originalCache.remove(itemID) }
        }
        Self.originalCacheDidChange()
    }
    /// The resolver also publishes evictions of files discovered on launch,
    /// whose owners have never appeared in this process's transfer history.
    static func originalCacheDidChange() { OriginalCachePublication.schedule() }
    private func setRecord(_ value: CloudTransferSnapshot?, key: String) {
        let previous = records[key]
        guard previous != value else { return }
        let itemID = value?.itemID ?? previous!.itemID
        let activeDelta = (value?.state == .downloading ? 1 : 0) - (previous?.state == .downloading ? 1 : 0)
        let queuedDelta = ([.queued, .paused].contains(value?.state ?? .idle) ? 1 : 0) - ([.queued, .paused].contains(previous?.state ?? .idle) ? 1 : 0)
        let failedDelta = (isActionableFailure(value) ? 1 : 0) - (isActionableFailure(previous) ? 1 : 0)
        if activeDelta != 0 { activeCount += activeDelta }
        if queuedDelta != 0 { queuedCount += queuedDelta }
        if failedDelta != 0 { failedCount += failedDelta }
        itemObservation.withMutation(of: self, keyPath: \.[observed: itemID]) { records[key] = value }
        sortedTasks = nil
        // The task popover may refresh ten times per second. Individual visible
        // file progress is still immediate and only invalidates that file.
        if taskPublication == nil {
            taskPublication = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self else { return }
                self.tasksVersion &+= 1
                self.taskPublication = nil
            }
        }
    }
    private func recalculateCounts() {
        activeCount = records.values.reduce(0) { $0 + ($1.state == .downloading ? 1 : 0) }
        queuedCount = records.values.reduce(0) { $0 + ([.queued, .paused].contains($1.state) ? 1 : 0) }
        failedCount = records.values.reduce(0) { $0 + (isActionableFailure($1) ? 1 : 0) }
    }
    private func pruneHistory() {
        guard records.count > 2000 else { return }
        let candidates = records.values.filter { ![.queued,.paused,.downloading].contains($0.state) }.sorted { $0.updatedAt < $1.updatedAt }
        for value in candidates.prefix(max(0, records.count - 1500)) { setRecord(nil, key: value.id); tokens[value.id] = nil }
        let retained = Set(records.values.map(\.itemID))
        items = items.filter { retained.contains($0.key) }
    }
    private static func todayKey() -> String {
        let values = Calendar.current.dateComponents([.year,.month,.day], from: .now)
        return String(format: "%04d-%02d-%02d", values.year ?? 0, values.month ?? 0, values.day ?? 0)
    }
}
