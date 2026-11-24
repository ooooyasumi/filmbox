import Foundation
import Security
import LocalAuthentication
import CryptoKit
import FilmboxCore

struct CloudDirectoryEntry: Decodable, Sendable {
    let id: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date
    let created: Date?
    let width: Int?
    let height: Int?
    let duration: Double?
    let thumbnail: String?

    enum CodingKeys: String, CodingKey {
        case id, name, size, modified, created, width, height, duration, thumbnail
        case isDirectory = "is_directory"
    }
}

struct CloudDirectoryPage: Decodable, Sendable {
    let entries: [CloudDirectoryEntry]
    let folderID: String
    let path: String
    let credential: String?
    var credentialRevision: UInt64? = nil
    enum CodingKeys: String, CodingKey {
        case entries, path, credential
        case folderID = "folder_id"
        case credentialRevision = "credential_revision"
    }
}

struct CloudResolvedAsset: Decodable, Sendable {
    let url: URL
    let headers: [String: String]
    let expiresAt: Date?
    let thumbnailAvailable: Bool?
    let credential: String?
    var credentialRevision: UInt64? = nil
    var connectionEpoch: UUID? = nil
    var connectionRuntimeID: UUID? = nil
    enum CodingKeys: String, CodingKey {
        case url, headers, credential
        case expiresAt = "expires_at"
        case thumbnailAvailable = "thumbnail_available"
        case credentialRevision = "credential_revision"
    }
}

enum CloudConnectionError: LocalizedError {
    case engineMissing, engineStart, engineUnavailable, credentialsMissing, invalidEndpoint, invalidCredential
    case keychain(OSStatus)
    case service(String)
    case problem(ResourceProblem)
    case thumbnailUnavailable, thumbnailTooLarge, originalDownloadRequired
    case cacheBudgetExceeded(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .engineMissing: "未找到云盘组件，请重新安装菲林盒。"
        case .engineStart: ResourceProblem.engine.detail
        case .engineUnavailable: ResourceProblem.engine.detail
        case .credentialsMissing: "需要重新登录"
        case .invalidEndpoint: "请输入 HTTPS 地址；本机服务也可使用 HTTP。"
        case .invalidCredential: "请先完成登录或输入有效的授权信息。"
        case .keychain: "无法将登录信息保存到钥匙串，请检查系统钥匙串是否已解锁。"
        case .service(let message): message
        case .problem(let issue): issue.title + "。" + issue.detail
        case .thumbnailUnavailable: "网盘未提供此文件的封面。"
        case .thumbnailTooLarge: "网盘返回的封面过大，已停止读取。"
        case .originalDownloadRequired: "此格式需要先缓存原文件才能播放。"
        case .cacheBudgetExceeded(let required, let available): "缓存空间不足：需要 \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file))，可用 \(ByteCountFormatter.string(fromByteCount: max(0, available), countStyle: .file))。请清理缓存或调整缓存上限。"
        }
    }
}

/// The native app owns the catalogue; the bundled OpenList helper only owns
/// transient provider sessions. Persistent credentials live in Keychain.
actor CloudGateway {
    static let shared = CloudGateway()
    private var runtime: CloudEngineProcess?
    private var starting: Task<CloudEngineProcess, Error>?
    private var credentialSyncTask: Task<Void, Never>?
    private var trafficSyncTask: Task<Void, Never>?
    private var connected = Set<UUID>()
    private var connecting: [UUID: Task<Void, Error>] = [:]
    private var explicitLogins: [UUID: UUID] = [:]
    private var accounts: [UUID: CloudAccount] = [:]
    private var credentialRecords: [UUID: CloudCredentialRecord] = [:]
    private var credentialRevisions: [UUID: UInt64] = [:]
    private var dirtyCredentials: [UUID: CloudCredentialRecord] = [:]
    private var credentialPersistence: [UUID: Task<Void, Never>] = [:]
    private var connectionEpochs: [UUID: UUID] = [:]
    private var authenticationChecks: [UUID: Task<Void, Never>] = [:]
    private var lastAuthenticationCheck: [UUID: Date] = [:]
    private var lastAssetCredentialSync: [UUID: TimeInterval] = [:]
    private var recoveryBlocks: [UUID: (ResourceProblem, Date)] = [:]
    func allowRecovery(accountID: UUID) { recoveryBlocks[accountID] = nil }
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 150
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    func register(accounts values: [CloudAccount]) {
        accounts = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        credentialRecords = credentialRecords.filter { accounts[$0.key] != nil }
        for account in values where connectionEpochs[account.id] == nil { connectionEpochs[account.id] = UUID() }
    }

    func connect(provider: CloudProvider, credential: String, endpoint: String? = nil,
                 username: String? = nil, password: String? = nil, accountID: UUID = UUID()) async throws -> CloudAccount {
        let cleanCredential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointURL = try Self.validatedEndpoint(endpoint, required: provider == .webdav)
        if provider != .webdav && cleanCredential.isEmpty { throw CloudConnectionError.invalidCredential }
        let record = CloudCredentialRecord(credential: cleanCredential, username: username, password: password)
        // Invalidate older requests before the helper replaces its account
        // session. A delayed response must never overwrite a fresh login.
        let previousRecord = credentialRecords[accountID]
        let previousDirty = dirtyCredentials[accountID]
        var committed = false
        let epoch = UUID()
        connectionEpochs[accountID] = epoch
        explicitLogins[accountID] = epoch
        defer {
            if explicitLogins[accountID] == epoch {
                if !committed {
                    credentialRecords[accountID] = previousRecord
                    dirtyCredentials[accountID] = previousDirty
                    credentialRevisions[accountID] = nil
                }
                explicitLogins[accountID] = nil
            }
        }
        connecting.removeValue(forKey: accountID)?.cancel()
        authenticationChecks.removeValue(forKey: accountID)?.cancel()
        credentialPersistence.removeValue(forKey: accountID)?.cancel()
        dirtyCredentials[accountID] = nil
        credentialRevisions[accountID] = nil
        // Initial validation can rotate the cookie even on a temporary error.
        // Keep that response in memory without creating an unverified account.
        credentialRecords[accountID] = record
        connected.remove(accountID)
        let result = try await connectSession(provider: provider, accountID: accountID, endpoint: endpointURL, record: record)
        var saved = record
        if let replacement = result.credential, !replacement.isEmpty { saved.credential = replacement }
        try Task.checkCancellation()
        guard connectionEpochs[accountID] == epoch else { throw CancellationError() }
        try await CloudCredentialVault.save(saved, accountID: accountID, allowRecovery: true)
        guard connectionEpochs[accountID] == epoch else { throw CancellationError() }
        credentialRecords[accountID] = saved
        credentialRevisions[accountID] = result.credentialRevision
        dirtyCredentials[accountID] = nil
        let account = CloudAccount(id: accountID, provider: provider,
                                   name: result.name.isEmpty ? provider.displayName : result.name, endpoint: endpointURL)
        accounts[accountID] = account
        lastAuthenticationCheck[accountID] = nil
        connected.insert(accountID)
        committed = true
        recoveryBlocks[accountID] = nil
        await CloudTransferCenter.shared.connectionRecovered(accountID: accountID)
        return account
    }

    func list(account: CloudAccount, folderID: String, path: String) async throws -> CloudDirectoryPage {
        accounts[account.id] = account
        let epoch = currentEpoch(account.id)
        try await ensureConnected(account.id)
        let runtimeID = runtime?.id
        let page: CloudDirectoryPage = try await request("/v1/files/list", body: CloudListRequest(accountID: account.id.uuidString, folderID: folderID, path: path), accountID: account.id)
        try await updateCredential(page.credential, revision: page.credentialRevision, accountID: account.id, expectedEpoch: epoch, expectedRuntimeID: runtimeID)
        return page
    }

    func resolve(accountID: UUID, fileID: String, path: String, purpose: String = "original") async throws -> CloudResolvedAsset {
        let epoch = currentEpoch(accountID)
        try await ensureConnected(accountID)
        let runtimeID = runtime?.id
        var asset: CloudResolvedAsset = try await request("/v1/files/resolve", body: CloudResolveRequest(accountID: accountID.uuidString, fileID: fileID, path: path, purpose: purpose), accountID: accountID)
        try await updateCredential(asset.credential, revision: asset.credentialRevision, accountID: accountID, expectedEpoch: epoch, expectedRuntimeID: runtimeID)
        asset.connectionEpoch = epoch
        asset.connectionRuntimeID = runtimeID
        return asset
    }

    func checkAuthentication(accountID: UUID) async throws {
        if await CloudTransferCenter.shared.issue(for: accountID) != nil {
            connected.remove(accountID)
            throw CloudConnectionError.credentialsMissing
        }
    }
    private func currentEpoch(_ accountID: UUID) -> UUID {
        if let epoch = connectionEpochs[accountID] { return epoch }
        let epoch = UUID(); connectionEpochs[accountID] = epoch; return epoch
    }
    private func requireLogin(accountID: UUID, expectedEpoch: UUID) async {
        guard connectionEpochs[accountID] == expectedEpoch, accounts[accountID] != nil else { return }
        connected.remove(accountID)
        credentialRecords[accountID] = nil
        dirtyCredentials[accountID] = nil
        credentialPersistence.removeValue(forKey: accountID)?.cancel()
        connecting.removeValue(forKey: accountID)?.cancel()
        await CloudTransferCenter.shared.requireLogin(accountID: accountID)
    }

    /// A codec/HTTP playback error is not evidence that the whole account has
    /// expired. Revalidate through a provider directory request, once per burst.
    func checkAuthenticationAfterPlaybackFailure(accountID: UUID) async {
        guard accounts[accountID] != nil, await CloudTransferCenter.shared.issue(for: accountID) == nil else { return }
        if let pending = authenticationChecks[accountID] { await pending.value; return }
        if let previous = lastAuthenticationCheck[accountID], Date().timeIntervalSince(previous) < 15 { return }
        let epoch = currentEpoch(accountID)
        lastAuthenticationCheck[accountID] = .now
        let task = Task<Void, Never> {
            do {
                try await ensureConnected(accountID)
                guard let account = accounts[accountID], connectionEpochs[accountID] == epoch else { return }
                let runtimeID = runtime?.id
                let page: CloudDirectoryPage = try await request("/v1/files/list", body: CloudListRequest(accountID: accountID.uuidString, folderID: account.provider == .quark ? "0" : "/", path: "/"), accountID: accountID)
                try await updateCredential(page.credential, revision: page.credentialRevision, accountID: accountID, expectedEpoch: epoch, expectedRuntimeID: runtimeID)
            } catch { /* Only request/Keychain typed authentication errors publish an issue. */ }
        }
        authenticationChecks[accountID] = task
        await task.value
        if connectionEpochs[accountID] == epoch { authenticationChecks[accountID] = nil }
    }

    func assetRequiresLogin(accountID: UUID, response: HTTPURLResponse, bodyURL: URL, connectionEpoch: UUID?, connectionRuntimeID: UUID? = nil) async -> Bool {
        let epoch = connectionEpoch ?? currentEpoch(accountID)
        guard connectionEpochs[accountID] == epoch, let engine = runtime,
              connectionRuntimeID == nil || connectionRuntimeID == engine.id,
              let url = response.url, url.scheme == engine.baseURL.scheme,
              url.host == engine.baseURL.host, url.port == engine.baseURL.port else { return false }
        let size = (try? bodyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let payload = size <= 16_384 ? (try? Data(contentsOf: bodyURL)) : nil
        let code = payload.flatMap { try? Self.decoder().decode(CloudServiceError.self, from: $0).code }
        // Asset error bodies are cached as temporary files, so deliberately
        // carry no credential. Read a secret only via the local in-memory API.
        await synchronizeCredential(accountID: accountID, expectedEpoch: epoch, expectedRuntimeID: engine.id)
        guard connectionEpochs[accountID] == epoch, runtime === engine else { return false }
        if ["auth_expired", "authentication_expired"].contains(code ?? "") {
            await requireLogin(accountID: accountID, expectedEpoch: epoch)
        } else if response.statusCode == 401, code != "unauthorized" {
            await checkAuthenticationAfterPlaybackFailure(accountID: accountID)
        }
        return await CloudTransferCenter.shared.issue(for: accountID) != nil
    }

    func assetFailure(accountID: UUID, response: HTTPURLResponse, bodyURL: URL, connectionEpoch: UUID?, connectionRuntimeID: UUID?) async -> CloudConnectionError {
        if await assetRequiresLogin(accountID: accountID, response: response, bodyURL: bodyURL, connectionEpoch: connectionEpoch, connectionRuntimeID: connectionRuntimeID) { return .credentialsMissing }
        guard let engine = runtime, response.url?.host == engine.baseURL.host, response.url?.port == engine.baseURL.port else { return .problem(.unknown) }
        let problem = ResourceProblem(code: response.value(forHTTPHeaderField: "X-Filmbox-Error"))
        if [.network, .timeout, .service, .limited, .engine, .secure].contains(problem) {
            recoveryBlocks[accountID] = (problem, Date().addingTimeInterval(problem == .limited ? 60 : 15))
            await CloudTransferCenter.shared.connectionFailed(accountID: accountID, problem: problem)
        }
        return .problem(problem)
    }

    func forget(accountID: UUID) async throws {
        connectionEpochs[accountID] = UUID()
        explicitLogins[accountID] = nil
        authenticationChecks.removeValue(forKey: accountID)?.cancel()
        lastAuthenticationCheck[accountID] = nil
        connecting[accountID]?.cancel()
        connecting[accountID] = nil
        credentialPersistence.removeValue(forKey: accountID)?.cancel()
        dirtyCredentials[accountID] = nil
        credentialRevisions[accountID] = nil
        if runtime != nil {
            let _: CloudDisconnectResponse? = try? await request("/v1/accounts/disconnect", body: CloudAccountRequest(accountID: accountID.uuidString))
        }
        try await CloudCredentialVault.remove(accountID: accountID)
        credentialRecords[accountID] = nil
        connected.remove(accountID)
        accounts[accountID] = nil
        await CloudTransferCenter.shared.forgetConnection(accountID: accountID)
    }

    /// Asset streaming can refresh a provider session after its resolve call.
    /// Capture those changes periodically and before a normal application exit.
    func synchronizeCredentials() async {
        guard runtime?.isRunning == true else { return }
        for accountID in connected {
            guard runtime?.isRunning == true else { break }
            let epoch = currentEpoch(accountID)
            let runtimeID = runtime?.id
            await synchronizeCredential(accountID: accountID, expectedEpoch: epoch, expectedRuntimeID: runtimeID)
            scheduleCredentialPersistence(accountID: accountID, expectedEpoch: epoch)
        }
    }

    private func synchronizeCredential(accountID: UUID, expectedEpoch: UUID, expectedRuntimeID: UUID?) async {
        guard connectionEpochs[accountID] == expectedEpoch, runtime?.id == expectedRuntimeID else { return }
        if let value: CloudCredentialResponse = try? await request("/v1/accounts/credential", body: CloudAccountRequest(accountID: accountID.uuidString), accountID: accountID) {
            try? await updateCredential(value.credential, revision: value.credentialRevision, accountID: accountID,
                                        expectedEpoch: expectedEpoch, expectedRuntimeID: expectedRuntimeID)
        }
    }

    /// Completing or cancelling an original can rotate a cookie in the asset
    /// proxy. Capture its local snapshot without fetching another media body.
    func synchronizeAssetCredential(accountID: UUID, connectionEpoch: UUID?, connectionRuntimeID: UUID?) async {
        guard let epoch = connectionEpoch, let runtimeID = connectionRuntimeID,
              connectionEpochs[accountID] == epoch, runtime?.id == runtimeID else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let previous = lastAssetCredentialSync[accountID], now - previous < 0.25 { return }
        lastAssetCredentialSync[accountID] = now
        await synchronizeCredential(accountID: accountID, expectedEpoch: epoch, expectedRuntimeID: runtimeID)
    }

    func shutdown() async {
        for task in authenticationChecks.values { task.cancel() }
        authenticationChecks.removeAll()
        credentialSyncTask?.cancel()
        credentialSyncTask = nil
        trafficSyncTask?.cancel()
        trafficSyncTask = nil
        await synchronizeTraffic()
        await synchronizeCredentials()
        for accountID in dirtyCredentials.keys {
            scheduleCredentialPersistence(accountID: accountID, expectedEpoch: currentEpoch(accountID))
        }
        for task in Array(credentialPersistence.values) { await task.value }
        credentialPersistence.removeAll()
        starting?.cancel()
        for task in connecting.values { task.cancel() }
        connecting.removeAll()
        explicitLogins.removeAll()
        starting = nil
        runtime?.stop()
        runtime = nil
        connected.removeAll()
        credentialRecords.removeAll()
        credentialRevisions.removeAll()
        dirtyCredentials.removeAll()
        await CloudTransferCenter.shared.trafficStopped()
    }

    func synchronizeTraffic() async {
        guard runtime?.isRunning == true else { return }
        do {
            let value: CloudTrafficResponse = try await request("/v1/traffic", body: CloudEmptyRequest())
            await CloudTransferCenter.shared.traffic(sessionID: value.sessionID, received: value.receivedBytes,
                                                     days: value.receivedByDay, activeStreams: value.activeStreams)
        } catch { await CloudTransferCenter.shared.trafficStopped() }
    }

    private func ensureConnected(_ accountID: UUID) async throws {
        try Task.checkCancellation()
        if let (problem, until) = recoveryBlocks[accountID], until > Date() { throw CloudConnectionError.problem(problem) }
        guard explicitLogins[accountID] == nil else { throw CancellationError() }
        try await checkAuthentication(accountID: accountID)
        let epoch = currentEpoch(accountID)
        _ = try await ensureRuntime()
        guard explicitLogins[accountID] == nil, connectionEpochs[accountID] == epoch else { throw CancellationError() }
        try await checkAuthentication(accountID: accountID)
        guard !connected.contains(accountID) else { return }
        if let pending = connecting[accountID] { return try await pending.value }
        guard let account = accounts[accountID] else {
            throw CloudConnectionError.credentialsMissing
        }
        let task = Task<Void, Error> {
            guard let record = try await credentialRecord(accountID: accountID) else { throw CloudConnectionError.credentialsMissing }
            try Task.checkCancellation()
            let result = try await connectSession(provider: account.provider, accountID: accountID, endpoint: account.endpoint, record: record)
            try Task.checkCancellation()
            try await updateCredential(result.credential, revision: result.credentialRevision, accountID: accountID, expectedEpoch: epoch)
        }
        connecting[accountID] = task
        do {
            try await task.value
            guard connectionEpochs[accountID] == epoch else { throw CancellationError() }
            connected.insert(accountID)
            if connectionEpochs[accountID] == epoch { connecting[accountID] = nil }
        } catch {
            if connectionEpochs[accountID] == epoch { connecting[accountID] = nil }
            if case .credentialsMissing = error as? CloudConnectionError { await requireLogin(accountID: accountID, expectedEpoch: epoch) }
            let problem = (error as? CloudConnectionError)?.recoveryProblem ?? .unknown
            if [.network, .timeout, .service, .limited, .engine, .secure].contains(problem) {
                recoveryBlocks[accountID] = (problem, Date().addingTimeInterval(problem == .limited ? 60 : 15))
                await CloudTransferCenter.shared.connectionFailed(accountID: accountID, problem: problem)
            }
            throw error
        }
    }

    private func connectSession(provider: CloudProvider, accountID: UUID, endpoint: URL?, record: CloudCredentialRecord) async throws -> CloudConnectResponse {
        try await request("/v1/accounts/connect", body: CloudConnectRequest(accountID: accountID.uuidString, provider: provider.rawValue,
                           credential: record.credential, endpoint: endpoint?.absoluteString,
                           username: record.username, password: record.password), accountID: accountID)
    }

    private func updateCredential(_ value: String?, revision: UInt64? = nil, accountID: UUID, expectedEpoch: UUID? = nil, expectedRuntimeID: UUID? = nil) async throws {
        guard let value, !value.isEmpty else { return }
        let epoch = expectedEpoch ?? currentEpoch(accountID)
        guard connectionEpochs[accountID] == epoch else { throw CancellationError() }
        if let expectedRuntimeID, runtime?.id != expectedRuntimeID { throw CancellationError() }
        if let revision, let current = credentialRevisions[accountID], revision <= current { return }
        do {
            guard var record = try await credentialRecord(accountID: accountID) else { throw CloudConnectionError.credentialsMissing }
            guard connectionEpochs[accountID] == epoch else { throw CancellationError() }
            if let expectedRuntimeID, runtime?.id != expectedRuntimeID { throw CancellationError() }
            if let revision, let current = credentialRevisions[accountID], revision <= current { return }
            if let revision { credentialRevisions[accountID] = revision }
            guard record.credential != value else { return }
            record.credential = value
            // Keep a refreshed provider session usable even if the Keychain
            // daemon is briefly busy. One worker persists only the latest value.
            credentialRecords[accountID] = record
            dirtyCredentials[accountID] = record
            scheduleCredentialPersistence(accountID: accountID, expectedEpoch: epoch)
        } catch {
            if case .credentialsMissing = error as? CloudConnectionError { await requireLogin(accountID: accountID, expectedEpoch: epoch) }
            throw error
        }
    }

    private func scheduleCredentialPersistence(accountID: UUID, expectedEpoch: UUID) {
        guard connectionEpochs[accountID] == expectedEpoch,
              explicitLogins[accountID] == nil,
              dirtyCredentials[accountID] != nil, credentialPersistence[accountID] == nil else { return }
        credentialPersistence[accountID] = Task { [weak self] in
            await self?.persistCredentials(accountID: accountID, expectedEpoch: expectedEpoch)
        }
    }

    private func persistCredentials(accountID: UUID, expectedEpoch: UUID) async {
        defer {
            if connectionEpochs[accountID] == expectedEpoch { credentialPersistence[accountID] = nil }
        }
        while !Task.isCancelled, connectionEpochs[accountID] == expectedEpoch,
              let record = dirtyCredentials[accountID] {
            do {
                try await CloudCredentialVault.save(record, accountID: accountID)
                guard connectionEpochs[accountID] == expectedEpoch else { return }
                if dirtyCredentials[accountID] == record { dirtyCredentials[accountID] = nil }
            } catch {
                guard connectionEpochs[accountID] == expectedEpoch else { return }
                if case .credentialsMissing = error as? CloudConnectionError {
                    await requireLogin(accountID: accountID, expectedEpoch: expectedEpoch)
                }
                // Transient daemon failures retain the latest value in memory
                // and are retried on the next sync or normal application exit.
                return
            }
        }
    }

    private func credentialRecord(accountID: UUID) async throws -> CloudCredentialRecord? {
        if let value = credentialRecords[accountID] { return value }
        let epoch = currentEpoch(accountID)
        let value = try await CloudCredentialVault.load(accountID: accountID)
        guard connectionEpochs[accountID] == epoch else { throw CancellationError() }
        credentialRecords[accountID] = value
        return value
    }

    private func ensureRuntime() async throws -> CloudEngineProcess {
        if let runtime, runtime.isRunning { return runtime }
        if let starting { return try await starting.value }
        connected.removeAll()
        credentialRevisions.removeAll()
        let task = Task { try await CloudEngineProcess.start() }
        starting = task
        do {
            let engine = try await task.value
            runtime = engine
            starting = nil
            credentialSyncTask?.cancel()
            credentialSyncTask = Task { [weak self] in
                while !Task.isCancelled {
                    // This only reads the local helper's in-memory snapshot;
                    // unchanged cookies do not perform Keychain operations.
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    await self?.synchronizeCredentials()
                }
            }
            trafficSyncTask?.cancel()
            trafficSyncTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.synchronizeTraffic()
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
            return engine
        } catch {
            starting = nil
            throw error
        }
    }

    private func request<Body: Encodable & Sendable, Response: Decodable & Sendable>(_ path: String, body: Body, accountID: UUID? = nil) async throws -> Response {
        let read = ["/v1/files/list", "/v1/files/resolve"].contains(path)
        if read, let accountID, let (problem, until) = recoveryBlocks[accountID], until > Date() { throw CloudConnectionError.problem(problem) }
        for attempt in 0..<2 {
            do {
                let response: Response = try await requestOnce(path, body: body, accountID: accountID)
                if read, let accountID { recoveryBlocks[accountID] = nil; await CloudTransferCenter.shared.connectionResponded(accountID: accountID) }
                return response
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                let problem = (error as? CloudConnectionError)?.recoveryProblem ?? .unknown
                if read && attempt == 0 && (problem.canAutomaticallyRetry || problem == .engine) {
                    if problem == .engine {
                        connected.removeAll(); runtime?.stop(); runtime = nil
                        if let accountID { try await ensureConnected(accountID) }
                    }
                    try await Task.sleep(for: .milliseconds(600))
                    continue
                }
                if read, let accountID, [.network, .timeout, .service, .limited, .engine, .secure].contains(problem) {
                    recoveryBlocks[accountID] = (problem, Date().addingTimeInterval(problem == .limited ? 60 : 15))
                    await CloudTransferCenter.shared.connectionFailed(accountID: accountID, problem: problem)
                }
                throw error
            }
        }
        throw CloudConnectionError.engineUnavailable
    }

    private func requestOnce<Body: Encodable & Sendable, Response: Decodable & Sendable>(_ path: String, body: Body, accountID: UUID? = nil) async throws -> Response {
        try Task.checkCancellation()
        let epoch = accountID.map { currentEpoch($0) }
        let requiresAuthentication = ["/v1/files/list", "/v1/files/resolve", "/v1/accounts/credential"].contains(path)
        if requiresAuthentication, let accountID { try await checkAuthentication(accountID: accountID) }
        let engine = try await ensureRuntime()
        if requiresAuthentication, let accountID { try await checkAuthentication(accountID: accountID) }
        var request = URLRequest(url: engine.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(engine.secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        do {
            let (data, response) = try await session.data(for: request)
            guard runtime === engine else { throw CancellationError() }
            if let accountID, connectionEpochs[accountID] != epoch { throw CancellationError() }
            guard let response = response as? HTTPURLResponse else { throw CloudConnectionError.engineUnavailable }
            guard (200..<300).contains(response.statusCode) else {
                let serviceError = try? Self.decoder().decode(CloudServiceError.self, from: data)
                if let accountID { try await updateCredential(serviceError?.credential, revision: serviceError?.credentialRevision, accountID: accountID, expectedEpoch: epoch, expectedRuntimeID: engine.id) }
                guard runtime === engine else { throw CancellationError() }
                if serviceError?.code == "thumbnail_unavailable" { throw CloudConnectionError.thumbnailUnavailable }
                if ["auth_expired", "authentication_expired"].contains(serviceError?.code ?? "") {
                    if let accountID, let epoch { await requireLogin(accountID: accountID, expectedEpoch: epoch) }
                    throw CloudConnectionError.credentialsMissing
                }
                if ["unauthorized", "account_not_connected"].contains(serviceError?.code ?? "") { throw CloudConnectionError.engineUnavailable }
                throw CloudConnectionError.problem(ResourceProblem(code: serviceError?.code))
            }
            return try Self.decoder().decode(Response.self, from: data)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw CloudConnectionError.problem(.timeout) }
            if error.code == .cannotConnectToHost, runtime === engine { connected.removeAll(); runtime?.stop(); runtime = nil }
            throw CloudConnectionError.engineUnavailable
        }
    }

    private static func validatedEndpoint(_ value: String?, required: Bool) throws -> URL? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if required { throw CloudConnectionError.invalidEndpoint }; return nil
        }
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.scheme?.lowercased() == "https" || (url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw CloudConnectionError.invalidEndpoint
        }
        guard url.query == nil, url.fragment == nil else {
            throw CloudConnectionError.service("服务器地址不能包含查询参数或登录信息，请将用户名和密码填在下方。")
        }
        return url
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            if let number = try? container.decode(Double.self) { return Date(timeIntervalSince1970: number) }
            let text = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid cloud date")
            }
            return date
        }
        return decoder
    }
}

private struct CloudEmptyRequest: Encodable, Sendable {}
private struct CloudTrafficResponse: Decodable, Sendable {
    let sessionID: String
    let receivedBytes: Int64
    let receivedByDay: [String: Int64]
    let activeStreams: Int
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", receivedBytes = "received_bytes", receivedByDay = "received_by_day", activeStreams = "active_streams" }
}

private struct CloudConnectRequest: Encodable, Sendable {
    let accountID: String; let provider: String; let credential: String
    let endpoint: String?; let username: String?; let password: String?
    enum CodingKeys: String, CodingKey { case accountID = "account_id"; case provider, credential, endpoint, username, password }
}
private struct CloudAccountRequest: Encodable, Sendable {
    let accountID: String
    enum CodingKeys: String, CodingKey { case accountID = "account_id" }
}
private struct CloudDisconnectResponse: Decodable, Sendable { let disconnected: Bool }
private struct CloudCredentialResponse: Decodable, Sendable {
    let credential: String?
    let credentialRevision: UInt64?
    enum CodingKeys: String, CodingKey { case credential; case credentialRevision = "credential_revision" }
}
private struct CloudConnectResponse: Decodable, Sendable {
    let name: String
    let credential: String?
    let credentialRevision: UInt64?
    enum CodingKeys: String, CodingKey { case name, credential; case credentialRevision = "credential_revision" }
}
private struct CloudListRequest: Encodable, Sendable {
    let accountID: String; let folderID: String; let path: String
    enum CodingKeys: String, CodingKey { case accountID = "account_id"; case folderID = "folder_id"; case path }
}
private struct CloudResolveRequest: Encodable, Sendable {
    let accountID: String; let fileID: String; let path: String; let purpose: String
    enum CodingKeys: String, CodingKey { case accountID = "account_id"; case fileID = "file_id"; case path, purpose }
}
private struct CloudServiceError: Decodable {
    let error: String?; let code: String?; let credential: String?; let credentialRevision: UInt64?
    enum CodingKeys: String, CodingKey { case error, code, credential; case credentialRevision = "credential_revision" }
}
private struct CloudCredentialRecord: Codable, Sendable, Equatable { var credential: String; let username: String?; let password: String? }

private enum CloudCredentialVault {
    private static let service = "com.filmbox.app.cloud"
    private static let slotsKey = "cloudCredentialSlots.v1"
    private static let retiredSlotsKey = "cloudCredentialRetiredSlots.v1"
    static func save(_ record: CloudCredentialRecord, accountID: UUID, allowRecovery: Bool = false) async throws {
        _ = try await CloudKeychainWorker.shared.execute(.save(record, accountID, allowRecovery: allowRecovery))
    }
    static func load(accountID: UUID) async throws -> CloudCredentialRecord? {
        guard case let .record(record) = try await CloudKeychainWorker.shared.execute(.load(accountID)) else { return nil }
        return record
    }
    static func remove(accountID: UUID) async throws {
        _ = try await CloudKeychainWorker.shared.execute(.remove(accountID))
    }

    // LAContext alone does not suppress legacy macOS Keychain ACL dialogs.
    // This setting is process-local and is never restored to an interactive mode.
    private static let legacyInteractionStatus = SecKeychainSetUserInteractionAllowed(false)
    private static func query(accountID: UUID, slot: String? = nil) throws -> [CFString: Any] {
        guard legacyInteractionStatus == errSecSuccess else { throw CloudConnectionError.keychain(legacyInteractionStatus) }
        let context = LAContext()
        context.interactionNotAllowed = true
        let name = slot ?? currentSlot(accountID)
        guard validSlot(name, accountID: accountID) else { throw CloudConnectionError.credentialsMissing }
        return [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name,
                kSecUseAuthenticationContext: context, kSecUseAuthenticationUI: kSecUseAuthenticationUIFail]
    }
    private static func validSlot(_ value: String, accountID: UUID) -> Bool {
        if value == accountID.uuidString { return true }
        let prefix = accountID.uuidString + ".slot."
        guard value.hasPrefix(prefix), let suffix = UUID(uuidString: String(value.dropFirst(prefix.count))) else { return false }
        return prefix + suffix.uuidString == value
    }
    private static func currentSlot(_ accountID: UUID) -> String {
        let candidate = (UserDefaults.standard.dictionary(forKey: slotsKey) as? [String: String])?[accountID.uuidString]
        return candidate.flatMap { validSlot($0, accountID: accountID) ? $0 : nil } ?? accountID.uuidString
    }
    private static func setSlot(_ slot: String?, accountID: UUID) {
        var values = UserDefaults.standard.dictionary(forKey: slotsKey) as? [String: String] ?? [:]
        values[accountID.uuidString] = slot
        UserDefaults.standard.set(values, forKey: slotsKey)
    }
    private static func retiredSlots(_ accountID: UUID) -> [String] {
        let values = (UserDefaults.standard.dictionary(forKey: retiredSlotsKey) as? [String: [String]])?[accountID.uuidString] ?? []
        return values.filter { validSlot($0, accountID: accountID) }
    }
    private static func setRetiredSlots(_ slots: [String], accountID: UUID) {
        var values = UserDefaults.standard.dictionary(forKey: retiredSlotsKey) as? [String: [String]] ?? [:]
        values[accountID.uuidString] = slots.isEmpty ? nil : Array(Set(slots))
        UserDefaults.standard.set(values, forKey: retiredSlotsKey)
    }
    private static func isAccessDenied(_ status: OSStatus) -> Bool {
        [errSecInteractionNotAllowed, errSecAuthFailed, errSecNoAccessForItem].contains(status)
    }
    private static func accessFailure(_ status: OSStatus, keychainUnlocked: Bool?) -> CloudConnectionError {
        // A locked/unavailable daemon cannot establish that a provider login
        // expired. Only an unlocked Keychain's ACL denial requires reconnect.
        keychainUnlocked == true ? .credentialsMissing : .keychain(status)
    }
    private static func accessFailure(_ status: OSStatus) -> CloudConnectionError {
        var state: SecKeychainStatus = 0
        let result = SecKeychainGetStatus(nil, &state)
        let unlocked = result == errSecSuccess ? state & SecKeychainStatus(kSecUnlockStateStatus) != 0 : nil
        return accessFailure(status, keychainUnlocked: unlocked)
    }
    fileprivate static func perform(_ operation: CloudKeychainOperation) throws -> CloudKeychainResult {
        let defaults = UserDefaults.standard
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let compatibilityKey = "cloudCredentialHelper.macos15.v1"
        // Keep the original executable's identity on existing macOS 26 installs.
        // A Sequoia install retains its helper after a later system upgrade.
        let name = CloudCredentialHelperRouting.name(systemMajorVersion: major,
                                                     usedCompatibilityHelper: defaults.bool(forKey: compatibilityKey),
                                                     distribution: CloudCredentialHelperRouting.usesDistributionProfile)
        if major < 26 && !CloudCredentialHelperRouting.usesDistributionProfile { defaults.set(true, forKey: compatibilityKey) }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/" + name)
        #if DEBUG
        if FileManager.default.isExecutableFile(atPath: helper.path) {
            return try CloudCredentialHelperClient.perform(operation, executable: helper)
        }
        // Standalone synthetic checks have no helper and retain the direct
        // vault. A packaged Release never falls back to this legacy store.
        #else
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw CloudConnectionError.service("未找到安全登录组件，请重新安装菲林盒。")
        }
        return try CloudCredentialHelperClient.perform(operation, executable: helper)
        #endif
        #if DEBUG
        switch operation {
        case let .save(record, accountID, allowRecovery): try saveSynchronously(record, accountID: accountID, allowRecovery: allowRecovery); return .complete
        case let .load(accountID): return .record(try loadSynchronously(accountID: accountID))
        case let .remove(accountID): try removeSynchronously(accountID: accountID); return .complete
        }
        #endif
    }
    private static func saveSynchronously(_ record: CloudCredentialRecord, accountID: UUID, allowRecovery: Bool) throws {
        let data = try JSONEncoder().encode(record)
        let previousSlot = currentSlot(accountID)
        var readable = false
        do { readable = try loadSynchronously(accountID: accountID) != nil }
        catch CloudConnectionError.credentialsMissing {
            guard allowRecovery else { throw CloudConnectionError.credentialsMissing }
        }
        // A legacy item can allow SecItemUpdate yet still deny decryption to
        // the new signature. Confirm readability before reusing its old ACL.
        let status = readable ? SecItemUpdate(try query(accountID: accountID, slot: previousSlot) as CFDictionary, [kSecValueData: data] as CFDictionary) : errSecItemNotFound
        if status == errSecSuccess { return }
        // Only an explicit successful provider login can replace inaccessible
        // storage. Background reads/token refreshes never create another slot.
        guard allowRecovery, status == errSecItemNotFound || isAccessDenied(status) else {
            if isAccessDenied(status) { throw accessFailure(status) }
            throw CloudConnectionError.keychain(status)
        }
        let replacement = accountID.uuidString + ".slot." + UUID().uuidString
        var addition = try self.query(accountID: accountID, slot: replacement)
        addition[kSecValueData] = data
        addition[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let created = SecItemAdd(addition as CFDictionary, nil)
        guard created == errSecSuccess else { throw CloudConnectionError.keychain(created) }
        // The pointer contains only a validated item name, never a credential.
        setSlot(replacement, accountID: accountID)
        var retained: [String] = []
        for old in Set(retiredSlots(accountID) + [previousSlot]) where old != replacement {
            let removed = SecItemDelete(try self.query(accountID: accountID, slot: old) as CFDictionary)
            if removed != errSecSuccess && removed != errSecItemNotFound { retained.append(old) }
        }
        setRetiredSlots(retained, accountID: accountID)
    }
    private static func loadSynchronously(accountID: UUID) throws -> CloudCredentialRecord? {
        var query = try query(accountID: accountID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if isAccessDenied(status) { throw accessFailure(status) }
        guard status == errSecSuccess, let data = result as? Data else { throw CloudConnectionError.keychain(status) }
        return try JSONDecoder().decode(CloudCredentialRecord.self, from: data)
    }
    private static func removeSynchronously(accountID: UUID) throws {
        let current = currentSlot(accountID)
        var retained: [String] = [], currentFailure: OSStatus?
        for slot in Set(retiredSlots(accountID) + [current, accountID.uuidString]) {
            let status = SecItemDelete(try query(accountID: accountID, slot: slot) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                retained.append(slot)
                if slot == current { currentFailure = status }
            }
        }
        setRetiredSlots(retained, accountID: accountID)
        if let currentFailure { throw CloudConnectionError.keychain(currentFailure) }
        setSlot(nil, accountID: accountID)
    }
}

enum CloudCredentialHelperRouting {
    static var usesDistributionProfile: Bool {
        Bundle.main.object(forInfoDictionaryKey: "FilmboxCredentialProfile") as? String == "developer-id-v1"
    }
    static func name(systemMajorVersion: Int, usedCompatibilityHelper: Bool, distribution: Bool = false) -> String {
        if distribution { return "filmbox-credential-helper-distribution-v1" }
        return systemMajorVersion < 26 || usedCompatibilityHelper
            ? "filmbox-credential-helper-macos15-v1" : "filmbox-credential-helper-v1"
    }
}

/// A byte-stable, narrowly authorized helper owns the new Keychain items. Main
/// application updates can change CDHash without changing those items' ACLs.
private enum CloudCredentialHelperClient {
    private static var helperIdentifier: String {
        CloudCredentialHelperRouting.usesDistributionProfile
            ? "com.filmbox.app.credential-helper.distribution.v1" : "com.filmbox.app.credential-helper.v1"
    }
    private static let maximumFrameBytes = 131_072
    private struct Request: Encodable {
        let version = 1
        let operation: String
        let accountID: String
        let record: Data?
        enum CodingKeys: String, CodingKey { case version, operation, record; case accountID = "account_id" }
    }
    private struct Response: Decodable {
        let version: Int
        let status: String
        let record: Data?
        let errorCode: String?
        let osStatus: Int32?
        enum CodingKeys: String, CodingKey { case version, status, record; case errorCode = "error_code"; case osStatus = "os_status" }
    }
    private static func requirement() throws -> SecRequirement {
        var ownCode: SecCode?
        var ownStaticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
              SecCodeCheckValidity(ownCode, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(ownCode, [], &ownStaticCode) == errSecSuccess, let ownStaticCode,
              SecCodeCopySigningInformation(ownStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any],
              information[kSecCodeInfoIdentifier as String] as? String == "com.filmbox.app",
              let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first else {
            throw CloudConnectionError.keychain(errSecNotAvailable)
        }
        let fingerprint = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        let rule = "identifier \"\(helperIdentifier)\" and certificate leaf = H\"\(fingerprint)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw CloudConnectionError.keychain(errSecNotAvailable)
        }
        return requirement
    }
    private static func validate(_ executable: URL, requirement: SecRequirement) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess else {
            throw CloudConnectionError.keychain(errSecNotAvailable)
        }
    }
    static func perform(_ operation: CloudKeychainOperation, executable: URL) throws -> CloudKeychainResult {
        let request: Request
        switch operation {
        case let .save(record, id, _):
            let bytes = try JSONEncoder().encode(record)
            guard !bytes.isEmpty, bytes.count <= 65_536 else { throw CloudConnectionError.invalidCredential }
            request = Request(operation: "save", accountID: id.uuidString, record: bytes)
        case let .load(id): request = Request(operation: "load", accountID: id.uuidString, record: nil)
        case let .remove(id): request = Request(operation: "remove", accountID: id.uuidString, record: nil)
        }
        var frame = try JSONEncoder().encode(request)
        frame.append(10)
        guard frame.count <= maximumFrameBytes else { throw CloudConnectionError.invalidCredential }
        let requirement = try requirement()
        try validate(executable, requirement: requirement)
        let child = CloudCredentialHelperProcess()
        let process = child.process
        let input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = []
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw CloudConnectionError.keychain(errSecNotAvailable)
        }
        let deadline = DispatchWorkItem { child.stop() }
        defer {
            deadline.cancel()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            child.stop()
        }
        do {
            try process.run()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: deadline)
            // Validate the actual running child before sending any secret.
            // This closes the path-replacement gap between verification/run.
            var runningCode: SecCode?
            guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: process.processIdentifier] as CFDictionary, [], &runningCode) == errSecSuccess,
                  let runningCode, SecCodeCheckValidity(runningCode, [], requirement) == errSecSuccess else {
                throw CloudConnectionError.keychain(errSecNotAvailable)
            }
            try input.fileHandleForWriting.write(contentsOf: frame)
            try input.fileHandleForWriting.close()
            var reply = Data()
            while let bytes = try output.fileHandleForReading.read(upToCount: min(4_096, maximumFrameBytes + 1 - reply.count)), !bytes.isEmpty {
                reply.append(bytes)
                guard reply.count <= maximumFrameBytes else { throw CloudConnectionError.keychain(errSecNotAvailable) }
            }
            process.waitUntilExit()
            guard let response = try? JSONDecoder().decode(Response.self, from: reply), response.version == 1 else {
                throw CloudConnectionError.keychain(errSecNotAvailable)
            }
            if response.status == "error" {
                if response.errorCode == "keychain_denied" { throw CloudConnectionError.credentialsMissing }
                throw CloudConnectionError.keychain(response.osStatus ?? errSecNotAvailable)
            }
            guard process.terminationStatus == 0 else { throw CloudConnectionError.keychain(errSecNotAvailable) }
            if request.operation == "load" {
                if response.status == "not_found" { return .record(nil) }
                guard response.status == "ok", let bytes = response.record, !bytes.isEmpty, bytes.count <= 65_536,
                      let record = try? JSONDecoder().decode(CloudCredentialRecord.self, from: bytes) else {
                    throw CloudConnectionError.keychain(errSecNotAvailable)
                }
                return .record(record)
            }
            guard response.status == "ok", response.record == nil else { throw CloudConnectionError.keychain(errSecNotAvailable) }
            return .complete
        } catch let error as CloudConnectionError { throw error }
        catch { throw CloudConnectionError.keychain(errSecNotAvailable) }
    }
}

private final class CloudCredentialHelperProcess: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    func stop() { lock.withLock { if process.isRunning { process.terminate() } } }
}

private enum CloudKeychainOperation: Sendable {
    case save(CloudCredentialRecord, UUID, allowRecovery: Bool), load(UUID), remove(UUID)
}
private enum CloudKeychainResult: Sendable { case record(CloudCredentialRecord?), complete }

/// Security.framework is synchronous and its daemon can stall independently of
/// Swift cancellation. Never occupy the gateway actor or add another worker
/// while an earlier system call is still blocked after our deadline.
private actor CloudKeychainWorker {
    static let shared = CloudKeychainWorker()
    private var active: CloudKeychainJob?
    func execute(_ operation: CloudKeychainOperation) async throws -> CloudKeychainResult {
        while let existing = active {
            if existing.systemCallFinished { active = nil; continue }
            do { _ = try await existing.value() }
            catch { if !existing.systemCallFinished { throw error } }
        }
        try Task.checkCancellation()
        let job = CloudKeychainJob()
        active = job
        job.start(operation)
        let result = try await job.value()
        try Task.checkCancellation()
        return result
    }
}

private final class CloudKeychainJob: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<CloudKeychainResult, Error>?
    private var finished = false
    private var waiters: [CheckedContinuation<CloudKeychainResult, Error>] = []
    var systemCallFinished: Bool { lock.withLock { finished } }
    func start(_ operation: CloudKeychainOperation) {
        DispatchQueue.global(qos: .utility).async {
            self.resolve(Result { try CloudCredentialVault.perform(operation) }, systemCallFinished: true)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            self.resolve(.failure(CloudConnectionError.keychain(errSecNotAvailable)), systemCallFinished: false)
        }
    }
    func value() async throws -> CloudKeychainResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result) }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
    private func resolve(_ value: Result<CloudKeychainResult, Error>, systemCallFinished: Bool) {
        lock.lock()
        if systemCallFinished { finished = true }
        guard result == nil else { lock.unlock(); return }
        result = value
        let pending = waiters; waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume(with: value) }
    }
}

/// Process and pipe callbacks are synchronized by CloudEngineHandshake.
private final class CloudEngineProcess: @unchecked Sendable {
    let id = UUID()
    let process: Process
    let output: Pipe
    let secret: String
    let baseURL: URL
    var isRunning: Bool { process.isRunning }
    private init(process: Process, output: Pipe, secret: String, port: Int) {
        self.process = process; self.output = output; self.secret = secret
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }
    static func start() async throws -> CloudEngineProcess {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["FILMBOX_CLOUD_ENGINE"] { candidates.append(URL(fileURLWithPath: override)) }
        #endif
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/filmbox-cloud-engine"))
        #if DEBUG
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(sourceRoot.appendingPathComponent(".build/CloudEngine/install/filmbox-cloud-engine"))
        #endif
        guard let executable = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else { throw CloudConnectionError.engineMissing }
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw CloudConnectionError.engineStart }
        let secret = random.map { String(format: "%02x", $0) }.joined()
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["--port", "0"]
        var environment = ProcessInfo.processInfo.environment
        environment["FILMBOX_CLOUD_SECRET"] = secret
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let handshake = CloudEngineHandshake()
        let port: Int = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                handshake.install(continuation)
                if Task.isCancelled { handshake.fail(CancellationError()); return }
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    handshake.receive(data)
                }
                process.terminationHandler = { _ in handshake.fail(CloudConnectionError.engineStart) }
                do { try process.run() } catch { handshake.fail(CloudConnectionError.engineStart) }
                Task {
                    try? await Task.sleep(for: .seconds(20))
                    if handshake.fail(CloudConnectionError.engineStart), process.isRunning { process.terminate() }
                }
            }
        } onCancel: {
            handshake.fail(CancellationError())
            if process.isRunning { process.terminate() }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        return CloudEngineProcess(process: process, output: pipe, secret: secret, port: port)
    }
    func stop() { if process.isRunning { process.terminate() } }
    deinit { if process.isRunning { process.terminate() } }
}

private final class CloudEngineHandshake: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int, Error>?
    private var buffer = Data()
    private var finished = false
    private var failure: Error?
    func install(_ continuation: CheckedContinuation<Int, Error>) {
        lock.lock()
        if let failure {
            lock.unlock()
            continuation.resume(throwing: failure)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }
    func receive(_ data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let port = object["port"] as? Int, (1...65535).contains(port) {
                finished = true
                let pending = continuation; continuation = nil
                lock.unlock()
                pending?.resume(returning: port)
                return
            }
        }
        let failed = data.isEmpty || buffer.count > 65_536
        lock.unlock()
        if failed { fail(CloudConnectionError.engineStart) }
    }
    @discardableResult func fail(_ error: Error) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        failure = error
        let pending = continuation; continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
        return true
    }
}

extension CloudConnectionError {
    var recoveryProblem: ResourceProblem {
        switch self {
        case .problem(let value): value
        case .credentialsMissing: .login
        case .engineMissing, .engineStart, .engineUnavailable: .engine
        case .cacheBudgetExceeded: .storage
        default: .unknown
        }
    }
}
