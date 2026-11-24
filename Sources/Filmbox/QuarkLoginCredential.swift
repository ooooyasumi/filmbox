import Foundation

/// Export the same cookies the browser can send to the Quark drive API.
/// Login pages on sibling hosts must not shadow the API's session cookie.
enum QuarkLoginCredential {
    enum CollectionError: LocalizedError {
        case incomplete
        var errorDescription: String? { "尚未完成登录。请在网页中登录夸克网盘后重试。" }
    }

    static func header(from cookies: [HTTPCookie], now: Date = .now) -> String? {
        let host = "drive.quark.cn"
        let apiPath = "/1/clouddrive/"
        let applicable = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let path = cookie.path.isEmpty ? "/" : cookie.path
            let matchesDomain = host == domain || host.hasSuffix("." + domain)
            let matchesPath = apiPath == path || (apiPath.hasPrefix(path) && (path.hasSuffix("/") || apiPath.dropFirst(path.count).first == "/"))
            return (domain == "quark.cn" || domain.hasSuffix(".quark.cn")) && matchesDomain && matchesPath
                && (cookie.expiresDate == nil || cookie.expiresDate! > now)
                && validName(cookie.name) && validValue(cookie.value)
        }.sorted { lhs, rhs in
            if lhs.domain.count != rhs.domain.count { return lhs.domain.count > rhs.domain.count }
            if lhs.path.count != rhs.path.count { return lhs.path.count > rhs.path.count }
            return lhs.name < rhs.name
        }
        var values: [String: String] = [:]
        for cookie in applicable where values[cookie.name] == nil { values[cookie.name] = cookie.value }
        // __pus alone can exist before the drive login finishes. The provider
        // still verifies the collected credential with a real directory request.
        guard values["__puus"] != nil else { return nil }
        return values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "; ")
    }

    /// A scan can finish while WebKit is still applying login Set-Cookie values.
    /// Require three identical snapshots, without blocking the main run loop.
    @MainActor static func collect(
        readCookies: () async -> [HTTPCookie],
        isActive: () -> Bool,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(180)) },
        maximumAttempts: Int = 12
    ) async throws -> String {
        var previous: String?
        var stableSamples = 0
        for attempt in 0..<maximumAttempts {
            try Task.checkCancellation()
            guard isActive() else { throw CancellationError() }
            let cookies = await readCookies()
            try Task.checkCancellation()
            guard isActive() else { throw CancellationError() }
            if let value = header(from: cookies) {
                stableSamples = previous == value ? stableSamples + 1 : 1
                previous = value
                if stableSamples >= 3 { return value }
            } else {
                previous = nil
                stableSamples = 0
            }
            if attempt + 1 < maximumAttempts { try await pause() }
        }
        throw CollectionError.incomplete
    }

    private static func validName(_ name: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        return !name.isEmpty && name.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func validValue(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f || $0 == ";" }
    }
}
