// This runner is appended to CloudGateway.swift so the tests exercise its
// private vault without exposing credential storage as application API.
import Foundation
import FilmboxCore

extension CloudCredentialVault {
    static func checkWriteLegacy(_ accountID: UUID) throws {
        var values = try query(accountID: accountID, slot: accountID.uuidString)
        values[kSecValueData] = try JSONEncoder().encode(CloudCredentialRecord(credential: "synthetic-old", username: nil, password: nil))
        let status = SecItemAdd(values as CFDictionary, nil)
        guard status == errSecSuccess else { throw CloudConnectionError.keychain(status) }
    }
    static func checkSlot(_ accountID: UUID) -> String { currentSlot(accountID) }
    static func checkNoPointers(_ accountID: UUID) -> Bool {
        let slots = UserDefaults.standard.dictionary(forKey: slotsKey) ?? [:]
        let retired = UserDefaults.standard.dictionary(forKey: retiredSlotsKey) ?? [:]
        return slots[accountID.uuidString] == nil && retired[accountID.uuidString] == nil
    }
    static func checkCrossAccountPointer(_ accountID: UUID, foreign: UUID) {
        var slots = UserDefaults.standard.dictionary(forKey: slotsKey) ?? [:]
        slots[accountID.uuidString] = foreign.uuidString + ".slot." + UUID().uuidString
        UserDefaults.standard.set(slots, forKey: slotsKey)
    }
    static func checkAccessFailure(_ unlocked: Bool?) -> CloudConnectionError {
        accessFailure(errSecInteractionNotAllowed, keychainUnlocked: unlocked)
    }
}
extension CloudKeychainWorker {
    func checkInstall(_ job: CloudKeychainJob) { active = job }
    func checkIsActive(_ job: CloudKeychainJob) -> Bool { active === job }
}
extension CloudKeychainJob {
    func checkTimeout() { resolve(.failure(CloudConnectionError.keychain(errSecNotAvailable)), systemCallFinished: false) }
    func checkFinish() { resolve(.success(.complete), systemCallFinished: true) }
}

extension CloudGateway {
    fileprivate func checkSeed(_ id: UUID, credential: String, revision: UInt64) -> UUID {
        let epoch = UUID()
        accounts[id] = CloudAccount(id: id, provider: .quark, name: "隔离测试")
        connectionEpochs[id] = epoch
        credentialRecords[id] = CloudCredentialRecord(credential: credential, username: nil, password: nil)
        credentialRevisions[id] = revision
        return epoch
    }
    fileprivate func checkUpdate(_ credential: String, revision: UInt64, id: UUID, epoch: UUID) async throws {
        try await updateCredential(credential, revision: revision, accountID: id, expectedEpoch: epoch)
    }
    fileprivate func checkRecord(_ id: UUID) -> String? { credentialRecords[id]?.credential }
    fileprivate func checkDirty(_ id: UUID) -> String? { dirtyCredentials[id]?.credential }
    fileprivate func checkAccountName(_ id: UUID) -> String? { accounts[id]?.name }
    fileprivate func checkConnected(_ id: UUID) { connected.insert(id) }
    fileprivate func checkRuntime(_ id: UUID) -> (URL, UUID, UUID)? {
        guard let runtime else { return nil }
        return (runtime.baseURL, runtime.id, currentEpoch(id))
    }
    fileprivate func checkFlush(_ id: UUID, epoch: UUID) async {
        scheduleCredentialPersistence(accountID: id, expectedEpoch: epoch)
        await credentialPersistence[id]?.value
    }
}

@main struct KeychainChecks {
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw CheckFailure(message: message) }
    }
    struct CheckFailure: Error { let message: String }
    static func main() async {
        guard let bundleID = Bundle.main.bundleIdentifier, bundleID.hasPrefix("com.filmbox.keychain-checks."),
              CommandLine.arguments.count == 3, let id = UUID(uuidString: CommandLine.arguments[2]) else { exit(2) }
        #if KEYCHAIN_NEW_SIGNATURE
        let identity = "new"
        #else
        let identity = "old"
        #endif
        let mode = CommandLine.arguments[1]
        do {
            switch mode {
            case "write":
                try CloudCredentialVault.checkWriteLegacy(id)
                try expect(try await CloudCredentialVault.load(accountID: id)?.credential == "synthetic-old", "initial signature cannot read its own legacy item")
            case "denied":
                let start = Date()
                do {
                    _ = try await CloudCredentialVault.load(accountID: id)
                    throw CheckFailure(message: "signature change did not deny legacy item")
                } catch CloudConnectionError.credentialsMissing { }
                try expect(Date().timeIntervalSince(start) < 5.5, "legacy read exceeded deadline")
                do {
                    try await CloudCredentialVault.save(CloudCredentialRecord(credential: "must-not-save", username: nil, password: nil), accountID: id)
                    throw CheckFailure(message: "background save migrated an inaccessible item")
                } catch CloudConnectionError.credentialsMissing { }
                try expect(CloudCredentialVault.checkSlot(id) == id.uuidString, "background access created a pointer")
            case "recover":
                try await CloudCredentialVault.save(CloudCredentialRecord(credential: "synthetic-new", username: nil, password: nil), accountID: id, allowRecovery: true)
                let slot = CloudCredentialVault.checkSlot(id)
                try expect(slot.hasPrefix(id.uuidString + ".slot."), "explicit reconnect did not create an account-scoped slot")
                try expect(try await CloudCredentialVault.load(accountID: id)?.credential == "synthetic-new", "recovered slot cannot be read")
                try await CloudCredentialVault.save(CloudCredentialRecord(credential: "synthetic-refreshed", username: nil, password: nil), accountID: id)
                try expect(CloudCredentialVault.checkSlot(id) == slot, "normal token refresh replaced slot")
                try expect(try await CloudCredentialVault.load(accountID: id)?.credential == "synthetic-refreshed", "normal token refresh failed")
            case "remove":
                try await CloudCredentialVault.remove(accountID: id)
            case "cleanup":
                try await CloudCredentialVault.remove(accountID: id)
                try expect(CloudCredentialVault.checkNoPointers(id), "test left pointer metadata")
                try expect(try await CloudCredentialVault.load(accountID: id) == nil, "test left its legacy item")
            case "bound":
                for unlocked: Bool? in [false, nil] {
                    guard case .keychain = CloudCredentialVault.checkAccessFailure(unlocked) else {
                        throw CheckFailure(message: "locked or unavailable Keychain was mistaken for an expired provider login")
                    }
                }
                guard case .credentialsMissing = CloudCredentialVault.checkAccessFailure(true) else {
                    throw CheckFailure(message: "unlocked Keychain ACL denial did not require recovery")
                }
                let worker = CloudKeychainWorker(), job = CloudKeychainJob()
                await worker.checkInstall(job)
                job.checkTimeout()
                let start = Date()
                for _ in 0..<1000 {
                    do { _ = try await worker.execute(.load(id)); throw CheckFailure(message: "timed-out worker accepted another job") }
                    catch CloudConnectionError.keychain(let status) { try expect(status == errSecNotAvailable, "timeout was misclassified as an expired login") }
                }
                try expect(await worker.checkIsActive(job), "timed-out worker was replaced")
                try expect(Date().timeIntervalSince(start) < 2, "repeated blocked requests accumulated waits")
                job.checkFinish()
                guard case .record(nil) = try await worker.execute(.load(id)) else { throw CheckFailure(message: "worker did not recover after system call finished") }
                CloudCredentialVault.checkCrossAccountPointer(id, foreign: UUID())
                try expect(CloudCredentialVault.checkSlot(id) == id.uuidString, "foreign account pointer was accepted")
                try await CloudCredentialVault.remove(accountID: id)
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
            case "rotation":
                let gateway = CloudGateway()
                let initial = CloudCredentialRecord(credential: "synthetic-first", username: nil, password: nil)
                try await CloudCredentialVault.save(initial, accountID: id, allowRecovery: true)
                let epoch = await gateway.checkSeed(id, credential: initial.credential, revision: 1)
                let blocked = CloudKeychainJob()
                blocked.checkTimeout()
                await CloudKeychainWorker.shared.checkInstall(blocked)
                try await gateway.checkUpdate("synthetic-current", revision: 3, id: id, epoch: epoch)
                await gateway.checkFlush(id, epoch: epoch)
                try expect(await gateway.checkRecord(id) == "synthetic-current", "temporary Keychain failure lost the refreshed cookie")
                try expect(await gateway.checkDirty(id) == "synthetic-current", "temporary Keychain failure lost its retry")
                try expect(CloudTransferCenter.shared.issue(for: id) == nil, "temporary Keychain failure required a new login")
                try await gateway.checkUpdate("synthetic-stale", revision: 2, id: id, epoch: epoch)
                try await gateway.checkUpdate("synthetic-conflicting", revision: 3, id: id, epoch: epoch)
                try expect(await gateway.checkRecord(id) == "synthetic-current", "out-of-order helper response overwrote the latest cookie")
                blocked.checkFinish()
                await gateway.checkFlush(id, epoch: epoch)
                try expect(try await CloudCredentialVault.load(accountID: id)?.credential == "synthetic-current", "dirty cookie was not retried")
                try expect(await gateway.checkDirty(id) == nil, "successful retry retained dirty state")
                for revision: UInt64 in 4...100 {
                    try await gateway.checkUpdate("synthetic-revision-\(revision)", revision: revision, id: id, epoch: epoch)
                }
                await gateway.checkFlush(id, epoch: epoch)
                try expect(try await CloudCredentialVault.load(accountID: id)?.credential == "synthetic-revision-100", "concurrent persistence regressed the cookie")
                let newEpoch = await gateway.checkSeed(id, credential: "synthetic-new-login", revision: 1)
                do {
                    try await gateway.checkUpdate("synthetic-old-login", revision: 999, id: id, epoch: epoch)
                    throw CheckFailure(message: "old login response was accepted")
                } catch is CancellationError { }
                try expect(await gateway.checkRecord(id) == "synthetic-new-login", "stale login response changed the new session")
                try await gateway.checkUpdate("synthetic-new-login-refresh", revision: 2, id: id, epoch: newEpoch)
                await gateway.checkFlush(id, epoch: newEpoch)
                try expect(try await CloudCredentialVault.load(accountID: id)?.credential == "synthetic-new-login-refresh", "new epoch could not persist a lower revision")
                try await CloudCredentialVault.remove(accountID: id)
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
            case "connect-failure":
                let gateway = CloudGateway()
                do {
                    _ = try await gateway.connect(provider: .quark, credential: "synthetic-initial", accountID: id)
                    throw CheckFailure(message: "temporary connect failure was accepted")
                } catch CloudConnectionError.service(let message) {
                    try expect(message == "synthetic-temporary", "initial cookie rotation replaced the real service error")
                }
                let failedRecord = await gateway.checkRecord(id), failedDirty = await gateway.checkDirty(id)
                try expect(failedRecord == nil && failedDirty == nil, "failed new login retained an unverified credential")
                try expect(await gateway.checkAccountName(id) == nil, "failed new login registered an account")
                try expect(try await CloudCredentialVault.load(accountID: id) == nil, "failed new login created a persistent credential")
                let existing = CloudCredentialRecord(credential: "synthetic-existing", username: nil, password: nil)
                try await CloudCredentialVault.save(existing, accountID: id, allowRecovery: true)
                _ = await gateway.checkSeed(id, credential: existing.credential, revision: 1)
                do {
                    _ = try await gateway.connect(provider: .quark, credential: "synthetic-failed-relogin", accountID: id)
                    throw CheckFailure(message: "temporary relogin failure was accepted")
                } catch CloudConnectionError.service(let message) {
                    try expect(message == "synthetic-temporary", "relogin cookie rotation replaced the service error")
                }
                try expect(await gateway.checkRecord(id) == existing.credential, "failed relogin overwrote the prior memory credential")
                try expect(await gateway.checkAccountName(id) == "隔离测试", "failed relogin changed the registered account")
                try expect(try await CloudCredentialVault.load(accountID: id) == existing, "failed relogin persisted an unverified credential")
                await gateway.checkConnected(id)
                await gateway.checkAuthenticationAfterPlaybackFailure(accountID: id)
                guard let (base, runtimeID, epoch) = await gateway.checkRuntime(id) else { throw CheckFailure(message: "fixture helper did not start") }
                await gateway.checkFlush(id, epoch: epoch)
                try expect(await gateway.checkRecord(id) == "synthetic-playback", "successful playback verification discarded the rotated cookie")
                let body = FileManager.default.temporaryDirectory.appendingPathComponent("filmbox-session-check-\(id).json")
                defer { try? FileManager.default.removeItem(at: body) }
                try Data("{\"code\":\"service_unavailable\"}".utf8).write(to: body)
                let response = HTTPURLResponse(url: base.appendingPathComponent("v1/asset"), statusCode: 502, httpVersion: nil, headerFields: nil)!
                try expect(await gateway.assetRequiresLogin(accountID: id, response: response, bodyURL: body,
                                                           connectionEpoch: epoch, connectionRuntimeID: runtimeID) == false,
                           "temporary asset failure was mistaken for an expired login")
                await gateway.checkFlush(id, epoch: epoch)
                try expect(try await CloudCredentialVault.load(accountID: id)?.credential == "synthetic-asset-refresh", "asset failure lost the local in-memory cookie snapshot")
                try Data("{\"code\":\"auth_expired\"}".utf8).write(to: body)
                try expect(await gateway.assetRequiresLogin(accountID: id, response: response, bodyURL: body,
                                                           connectionEpoch: epoch, connectionRuntimeID: UUID()) == false,
                           "old helper asset failure expired the current account")
                try expect(CloudTransferCenter.shared.issue(for: id) == nil, "stale helper published a login issue")
                await gateway.shutdown()
                try await CloudCredentialVault.remove(accountID: id)
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
            default: throw CheckFailure(message: "unknown test mode")
            }
            UserDefaults.standard.synchronize()
            print("\(identity) signature: \(mode) passed")
        } catch {
            print("keychain check failed: \(error)")
            exit(1)
        }
    }
}
