import Foundation
import FilmboxCore

@main @MainActor struct TransferChecks {
    static var passed = 0
    static let size: Int64 = 4 * 1024 * 1024
    static func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) }; passed += 1 }
    struct Failure: Error { let message: String }
    static func main() async {
        let endpoint = URL(string: CommandLine.arguments[1])!
        let accountID = UUID(), otherAccountID = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FilmboxTransferChecks-\(UUID())")
        var failure: Error?
        do {
            let account = try await CloudGateway.shared.connect(provider: .webdav, credential: "", endpoint: endpoint.appendingPathComponent("dav/").absoluteString, username: "filmbox", password: "transfer-fixture", accountID: accountID)
            let resolver = MediaAssetResolver(directory: directory, diskBudget: 32 * 1024 * 1024, recentProtectionDuration: 0)
            func item(_ id: String, bytes: Int64 = size) -> MediaItem {
                MediaItem(cloud: CloudMediaReference(accountID: account.id, fileID: "/\(id).png", parentID: "/", remotePath: "/\(id).png", revision: "r1"), kind: .image, fileSize: bytes, modifiedDate: Date(timeIntervalSince1970: 1700000000), createdDate: Date(timeIntervalSince1970: 1700000000))
            }
            let photo = item("photo")
            CloudMediaRegistry.shared.register([photo])
            do { _ = try await resolver.thumbnailFile(for: photo.url); throw Failure(message: "missing cover unexpectedly downloaded") }
            catch CloudConnectionError.thumbnailUnavailable { passed += 1 }
            do { _ = try await resolver.playbackURL(for: photo); throw Failure(message: "compatibility playback downloaded silently") }
            catch CloudConnectionError.originalDownloadRequired { passed += 1 }
            let before = try await stats(endpoint)
            try expect(before.gets == 0, "a thumbnail/playback opened the original")

            let task = Task { try await resolver.originalFile(for: photo) }
            var sawProgress = false
            for _ in 0..<150 {
                if let snapshot = CloudTransferCenter.shared.snapshot(for: photo.id), snapshot.state == .downloading, snapshot.receivedBytes > 0, snapshot.receivedBytes < size { sawProgress = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try expect(sawProgress,"no byte progress before completion")
            let cached = try await task.value
            try expect(FileManager.default.fileExists(atPath: cached.path),"original not cached")
            try expect(CloudTransferCenter.shared.snapshot(for:photo.id)?.state == .ready,"completed transfer not ready")
            try expect(CloudTransferCenter.shared.snapshot(for:photo.id)?.isOriginalCached == true,"cache badge missing")
            let afterFirst = try await stats(endpoint)
            async let a = resolver.originalFile(for:photo)
            async let b = resolver.originalFile(for:photo)
            _ = try await(a,b)
            let afterHit = try await stats(endpoint)
            try expect(afterHit.gets == afterFirst.gets,"cache hit redownloaded original")
            await CloudGateway.shared.synchronizeTraffic()
            try expect(CloudTransferCenter.shared.sessionReceivedBytes == size,"traffic counted proxy bytes twice")
            await CloudGateway.shared.synchronizeTraffic()
            try expect(CloudTransferCenter.shared.sessionReceivedBytes == size,"polling duplicated traffic")

            await resolver.setBackgroundPaused(true)
            let pendingItem = item("paused")
            let pending = Task { try await resolver.originalFile(for:pendingItem,priority:.background) }
            try await Task.sleep(for:.milliseconds(100))
            let pausedStats = try await stats(endpoint)
            try expect(pausedStats.gets == afterHit.gets,"paused background request was dispatched")
            pending.cancel()
            do { _ = try await pending.value; throw Failure(message:"cancelled queue succeeded") } catch is CancellationError { passed += 1 }
            let foregroundItem = item("foreground")
            _ = try await resolver.originalFile(for:foregroundItem)
            passed += 1
            await resolver.setBackgroundPaused(false)

            let originals = [item("one"),item("two"),item("three"),item("four")]
            let jobs = originals.map { value in Task { try await resolver.originalFile(for:value) } }
            for job in jobs { _ = try await job.value }
            let concurrency = try await stats(endpoint)
            try expect(concurrency.maximum <= 3 && concurrency.maximum >= 2,"download concurrency is not bounded at three")

            let viewing = await resolver.acquireViewingLease(for:photo)
            let export = await resolver.acquireExportLease(for:[foregroundItem])
            let cleanup = await resolver.clearOriginalCache()
            try expect(cleanup.protectedBytes == 2*size,"clear did not preserve active viewing/export")
            try expect(FileManager.default.fileExists(atPath:cached.path),"clear deleted viewed original")
            await resolver.releaseViewingLease(viewing); await resolver.releaseExportLease(export)
            let finalCleanup = await resolver.clearOriginalCache()
            try expect(finalCleanup.removedBytes == 2*size,"released cache did not clear")
            let empty = await resolver.cacheSizes()
            try expect(empty.totalBytes == 0,"cache clear left media files")

            let small = MediaAssetResolver(directory:directory.appendingPathComponent("budget"),diskBudget:1024,recentProtectionDuration:0)
            let smallBefore = try await stats(endpoint)
            do { _ = try await small.originalFile(for:item("too-large")); throw Failure(message:"budget silently exceeded") }
            catch CloudConnectionError.cacheBudgetExceeded { passed += 1 }
            let smallAfter = try await stats(endpoint)
            try expect(smallAfter.gets == smallBefore.gets,"oversize original requested before budget check")
            let cancelItem = item("cancel-active")
            let cancelJob = Task { try await resolver.originalFile(for:cancelItem) }
            try await Task.sleep(for:.milliseconds(200)); await resolver.cancel(itemID:cancelItem.id)
            do { _ = try await cancelJob.value; throw Failure(message:"cancelled download succeeded") } catch is CancellationError { passed += 1 }
            let partials = (FileManager.default.enumerator(at:directory,includingPropertiesForKeys:nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "partial" }
            try expect(partials.isEmpty,"cancelled transfer left temporary files")
            try await checkAccountRejection(endpoint: endpoint, account: account, otherAccountID: otherAccountID, directory: directory)
        } catch { failure = error }
        _ = try? await control("online", endpoint)
        _ = try? await control("available", endpoint)
        try? await CloudGateway.shared.forget(accountID:accountID)
        try? await CloudGateway.shared.forget(accountID:otherAccountID)
        await CloudGateway.shared.shutdown()
        try? FileManager.default.removeItem(at:directory)
        if let failure { print("FAILED after \(passed): \(failure)"); exit(1) }
        print("\(passed) transfer checks passed; temporary account/process/cache cleaned")
    }
    private static func checkAccountRejection(endpoint: URL, account: CloudAccount, otherAccountID: UUID, directory: URL) async throws {
        let other = try await CloudGateway.shared.connect(provider: .webdav, credential: "",
            endpoint: endpoint.appendingPathComponent("other-dav/").absoluteString,
            username: "filmbox", password: "transfer-fixture", accountID: otherAccountID)
        let resolver = MediaAssetResolver(directory: directory.appendingPathComponent("account-rejection"),
                                          diskBudget: 32 * 1024 * 1024, recentProtectionDuration: 0)
        func item(_ name: String, accountID: UUID) -> MediaItem {
            MediaItem(cloud: CloudMediaReference(accountID: accountID, fileID: "/\(name).png", parentID: "/",
                remotePath: "/\(name).png", revision: "auth-r1"), kind: .image, fileSize: size,
                modifiedDate: Date(timeIntervalSince1970: 1_700_000_000), createdDate: Date(timeIntervalSince1970: 1_700_000_000))
        }
        _ = try await control("unavailable", endpoint)
        do {
            _ = try await CloudGateway.shared.list(account: account, folderID: "/", path: "/")
            throw Failure(message: "synthetic unavailable server unexpectedly listed")
        } catch CloudConnectionError.problem(.service) { passed += 1 }
        try expect(CloudTransferCenter.shared.issue(for: account.id) == nil, "ordinary server error was classified as expired login")
        _ = try await control("available", endpoint)
        await CloudGateway.shared.allowRecovery(accountID: account.id)
        do {
            _ = try await resolver.originalFile(for: item("no-access", accountID: account.id))
            throw Failure(message: "file-level forbidden asset unexpectedly downloaded")
        } catch CloudConnectionError.problem(.denied) { passed += 1 }
        try expect(CloudTransferCenter.shared.issue(for: account.id) == nil, "single forbidden file invalidated a healthy account")
        let cachedItem = item("auth-cached", accountID: account.id)
        let cachedURL = try await resolver.originalFile(for: cachedItem)
        let active = item("auth-in-flight", accountID: account.id)
        let activeJob = Task { try await resolver.originalFile(for: active) }
        try await wait {
            CloudTransferCenter.shared.snapshot(for: active.id)?.state == .downloading
                && (CloudTransferCenter.shared.snapshot(for: active.id)?.receivedBytes ?? 0) > 0
        }
        // Pause background work to leave another same-account operation at the
        // gate while the foreground body above is already arriving.
        await resolver.setBackgroundPaused(true)
        let queued = item("auth-queued", accountID: account.id)
        let queuedJob = Task { try await resolver.originalFile(for: queued, priority: .background) }
        try await wait {
            [.queued, .paused].contains(CloudTransferCenter.shared.snapshot(for: queued.id)?.state ?? .idle)
        }
        let otherItem = item("other-account", accountID: other.id)
        let otherJob = Task { try await resolver.originalFile(for: otherItem) }
        _ = try await control("expired", endpoint)
        do {
            _ = try await CloudGateway.shared.list(account: account, folderID: "/", path: "/")
            throw Failure(message: "expired provider account was accepted")
        } catch CloudConnectionError.credentialsMissing { passed += 1 }
        try expect(CloudTransferCenter.shared.issue(for: account.id)?.kind == .authenticationRequired,
                   "account-wide login issue was not published")
        try expect(CloudTransferCenter.shared.issue(for: other.id) == nil, "unrelated account acquired a login issue")
        try await expectCredentialsMissing(activeJob, "in-flight same-account transfer survived login rejection")
        try await expectCredentialsMissing(queuedJob, "queued same-account transfer survived login rejection")
        try expect(CloudTransferCenter.shared.snapshot(for: active.id)?.state == .failed,
                   "in-flight auth failure fell back to idle/paused")
        try expect(CloudTransferCenter.shared.snapshot(for: queued.id)?.state == .failed,
                   "queued auth failure fell back to idle/paused")
        let otherURL = try await otherJob.value
        try expect(FileManager.default.fileExists(atPath: otherURL.path), "other account download was cancelled")
        await resolver.setBackgroundPaused(false)
        let beforeFailfast = try await stats(endpoint)
        _ = try await resolver.originalFile(for: cachedItem)
        try expect(try Data(contentsOf: cachedURL).count == size, "expired account lost a previously cached original")
        CloudMediaRegistry.shared.register([cachedItem])
        let cachedPreviewSource = try await resolver.thumbnailFile(for: cachedItem.url)
        try expect(cachedPreviewSource == cachedURL, "expired account could not reuse cached original as a preview")
        let uncached = item("known-expired", accountID: account.id)
        for _ in 0..<3 {
            do { _ = try await resolver.originalFile(for: uncached); throw Failure(message: "known invalid original did not fail fast") }
            catch CloudConnectionError.credentialsMissing { passed += 1 }
            do { _ = try await CloudGateway.shared.list(account: account, folderID: "/", path: "/"); throw Failure(message: "known invalid list did not fail fast") }
            catch CloudConnectionError.credentialsMissing { passed += 1 }
        }
        let afterFailfast = try await stats(endpoint)
        try expect(afterFailfast.requests == beforeFailfast.requests,
                   "cache hit or known invalid account repeatedly contacted provider")
        // Server recovery is insufficient: only an explicit successful login
        // may clear the session issue and release future requests.
        _ = try await control("online", endpoint)
        do { _ = try await resolver.originalFile(for: uncached); throw Failure(message: "network recovery silently cleared login rejection") }
        catch CloudConnectionError.credentialsMissing { passed += 1 }
        let stillBlocked = try await stats(endpoint)
        try expect(stillBlocked.requests == afterFailfast.requests, "blocked account reconnected without user action")
        _ = try await CloudGateway.shared.connect(provider: .webdav, credential: "",
            endpoint: endpoint.appendingPathComponent("dav/").absoluteString,
            username: "filmbox", password: "transfer-fixture", accountID: account.id)
        try expect(CloudTransferCenter.shared.issue(for: account.id) == nil, "explicit successful reconnect retained login issue")
        let recovered = try await resolver.originalFile(for: uncached)
        try expect(FileManager.default.fileExists(atPath: recovered.path), "reconnected account could not load a new original")
        try expect(CloudTransferCenter.shared.snapshot(for: uncached.id)?.state == .ready, "reconnected transfer was not ready")
        // Model the delayed cancellation dispatched by an earlier requireLogin:
        // it may cancel work existing then, but must spare work from a fresh login.
        await resolver.setBackgroundPaused(true)
        let beforeReconnect = item("before-reconnect-cutoff", accountID: account.id)
        let oldQueuedJob = Task { try await resolver.originalFile(for: beforeReconnect, priority: .background) }
        try await wait { CloudTransferCenter.shared.snapshot(for: beforeReconnect.id)?.state == .queued }
        let cutoff = ProcessInfo.processInfo.systemUptime
        let afterReconnect = item("after-reconnect-cutoff", accountID: account.id)
        let newForegroundJob = Task { try await resolver.originalFile(for: afterReconnect) }
        try await wait {
            CloudTransferCenter.shared.snapshot(for: afterReconnect.id)?.state == .downloading
                && (CloudTransferCenter.shared.snapshot(for: afterReconnect.id)?.receivedBytes ?? 0) > 0
        }
        await resolver.cancel(accountID: account.id, createdBefore: cutoff)
        do { _ = try await oldQueuedJob.value; throw Failure(message: "delayed account cancellation did not cancel old work") }
        catch is CancellationError { passed += 1 }
        let newURL = try await newForegroundJob.value
        try expect(FileManager.default.fileExists(atPath: newURL.path), "delayed cancellation killed new-login work")
        await resolver.setBackgroundPaused(false)
        let orphaned = (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "partial" }
        try expect(orphaned.isEmpty, "account rejection left a partial original")
        _ = try await control("expired", endpoint)
        do { _ = try await CloudGateway.shared.list(account: account, folderID: "/", path: "/"); throw Failure(message: "second auth rejection was ignored") }
        catch CloudConnectionError.credentialsMissing { passed += 1 }
        try expect(CloudTransferCenter.shared.issue(for: account.id) != nil, "reconnected account could not record a later auth issue")
        try await CloudGateway.shared.forget(accountID: account.id)
        try expect(CloudTransferCenter.shared.issue(for: account.id) == nil, "disconnect retained an orphaned login issue")
        print("✓ Account-wide auth rejection: active/queued cancellation, account isolation, offline cache, fail-fast and explicit recovery")
    }
    private static func expectCredentialsMissing(_ job: Task<URL, Error>, _ message: String) async throws {
        do { _ = try await job.value; throw Failure(message: message) }
        catch CloudConnectionError.credentialsMissing { passed += 1 }
    }
    private static func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now >= deadline { throw Failure(message: "account state timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    struct Stats: Decodable { let gets: Int; let maximum: Int; let bytes: Int64; let requests: Int }
    static func stats(_ endpoint:URL) async throws -> Stats { let(data,_) = try await URLSession.shared.data(from:endpoint.appendingPathComponent("stats")); return try JSONDecoder().decode(Stats.self,from:data) }
    static func control(_ action: String, _ endpoint: URL) async throws -> Stats {
        let (data, _) = try await URLSession.shared.data(from: endpoint.appendingPathComponent("control/\(action)"))
        return try JSONDecoder().decode(Stats.self, from: data)
    }
}
