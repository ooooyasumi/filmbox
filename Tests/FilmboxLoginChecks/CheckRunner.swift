import Foundation

@main @MainActor
private struct LoginChecks {
    static var passed = 0
    static var assertions = 0
    static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    static func main() async {
        let checks: [(String, () async throws -> Void)] = [
            ("仅有登录中间态 Cookie 时不能完成", partialLogin),
            ("完整 API Cookie 收集且允许缺少可选令牌", completeLogin),
            ("登录兄弟域和无关路径不能覆盖 API Cookie", domainAndPathScope),
            ("过期、空值和删除 Cookie 不参与凭据", invalidCookies),
            ("重复名称选用 API 最具体域与路径", duplicatePriority),
            ("等待登录写入稳定后仅交付最新凭据", waitsForStableSession),
            ("半套或持续轮换中的登录返回可重试错误", unstableSession),
            ("离开登录页后拒绝迟到的 Cookie 结果", stoppedSession),
            ("取消确认任务后不能完成登录", cancellation)
        ]
        for (name, check) in checks {
            do { try await check(); passed += 1; print("✓ \(name)") }
            catch { print("✗ \(name)：\(error)") }
        }
        print("\(passed)/\(checks.count) 登录凭据检查通过，\(assertions) 项断言")
        if passed != checks.count { exit(EXIT_FAILURE) }
    }

    static func partialLogin() throws {
        try expect(header([cookie("__pus", "partial")]) == nil, "单个 __pus 中间态不能完成登录")
        try expect(header([cookie("__puus", "")]) == nil, "空 __puus 不能完成登录")
        try expect(header([cookie("__puus", "   ")]) == nil, "空白 __puus 不能完成登录")
        try expect(header([cookie("sid", "unrelated")]) == nil, "普通会话 Cookie 不能代替网盘凭据")
    }

    static func completeLogin() throws {
        let value = header([cookie("__puus", "synthetic-drive"), cookie("__kps", "synthetic-extra")])
        try expect(value == "__kps=synthetic-extra; __puus=synthetic-drive", "必须保留适用的完整 Cookie 且序列化稳定")
        try expect(header([cookie("__puus", "synthetic-drive"), cookie("__pus", "synthetic-optional")])?.contains("__pus=synthetic-optional") == true,
                   "可选令牌存在时必须一起保留")
        try expect(header([cookie("__puus", "synthetic-drive")]) != nil, "__pus 不应被强制要求")
    }

    static func domainAndPathScope() throws {
        let cookies = [cookie("__puus", "synthetic-drive"),
                       cookie("__puus", "must-not-shadow", domain: "pan.quark.cn"),
                       cookie("__puus", "must-not-shadow", domain: "accounts.quark.cn"),
                       cookie("__puus", "must-not-shadow", domain: "evilquark.cn"),
                       cookie("__puus", "must-not-shadow", domain: ".cn"),
                       cookie("login", "must-not-export", path: "/account"),
                       cookie("file", "must-not-export", path: "/1/clouddrive/file"),
                       cookie("api", "allowed", path: "/1/clouddrive"),
                       cookie("root", "allowed", path: "/")]
        let value = header(cookies)
        try expect(value?.contains("__puus=synthetic-drive") == true, "兄弟域不应覆盖 API 的父域令牌")
        try expect(value?.contains("must-not-") == false, "不适用域/path Cookie 被泄露到 API")
        try expect(value?.contains("api=allowed") == true && value?.contains("root=allowed") == true,
                   "有效 API 前缀与根路径必须保留")
    }

    static func invalidCookies() throws {
        let valid = cookie("__puus", "synthetic-valid")
        let expired = cookie("__puus", "synthetic-expired", domain: "drive.quark.cn", expires: fixedNow.addingTimeInterval(-1))
        let deletion = cookie("__puus", "", domain: "drive.quark.cn")
        try expect(header([valid, expired, deletion]) == "__puus=synthetic-valid", "过期或删除的具体 Cookie 不应覆盖有效父域 Cookie")
        try expect(header([expired]) == nil, "只剩过期令牌时不能完成")
        try expect(header([cookie("__puus", "synthetic", expires: fixedNow)]) == nil, "刚过期令牌不能完成")
        if let unsafe = HTTPCookie(properties: [.domain: ".quark.cn", .path: "/", .name: "__puus", .value: "bad; injected=true"]) {
            try expect(header([unsafe]) == nil, "凭据必须拒绝可改变 Cookie 头语义的值")
        }
    }

    static func duplicatePriority() throws {
        let cookies = [cookie("__puus", "parent"),
                       cookie("__puus", "drive-root", domain: "drive.quark.cn"),
                       cookie("__puus", "drive-api", domain: "drive.quark.cn", path: "/1/clouddrive/")]
        try expect(header(cookies) == "__puus=drive-api", "优先 API 最具体域和路径")
        try expect(header(Array(cookies.reversed())) == header(cookies), "Cookie 存储返回顺序不应改变凭据")
    }

    static func waitsForStableSession() async throws {
        let incomplete = [cookie("__pus", "partial")]
        let initial = [cookie("__puus", "synthetic-initial")]
        let refreshed = [cookie("__puus", "synthetic-refreshed")]
        let snapshots = [incomplete, initial, initial, refreshed, refreshed, refreshed]
        var reads = 0
        var pauses = 0
        let result = try await QuarkLoginCredential.collect(readCookies: {
            defer { reads += 1 }
            return snapshots[min(reads, snapshots.count - 1)]
        }, isActive: { true }, pause: { pauses += 1 })
        try expect(result == "__puus=synthetic-refreshed", "扫码后续更新必须纳入最终凭据")
        try expect(reads == 6 && pauses == 5, "未等到三份稳定快照或读取次数异常")
    }

    static func unstableSession() async throws {
        var reads = 0
        do {
            _ = try await QuarkLoginCredential.collect(readCookies: {
                reads += 1
                return [cookie("__puus", "synthetic-\(reads)")]
            }, isActive: { true }, pause: {}, maximumAttempts: 5)
            throw Failure(message: "持续轮换的 Cookie 不应被提前交付")
        } catch QuarkLoginCredential.CollectionError.incomplete { }
        try expect(reads == 5, "确认过程必须有界，不能永远转圈")
        do {
            _ = try await QuarkLoginCredential.collect(readCookies: { [cookie("__pus", "partial")] },
                                                       isActive: { true }, pause: {}, maximumAttempts: 3)
            throw Failure(message: "半套 Cookie 不应被交付")
        } catch QuarkLoginCredential.CollectionError.incomplete { }
    }

    static func stoppedSession() async throws {
        var active = true
        var reads = 0
        do {
            _ = try await QuarkLoginCredential.collect(readCookies: {
                reads += 1
                active = false
                return [cookie("__puus", "synthetic-late")]
            }, isActive: { active }, pause: {})
            throw Failure(message: "离开页面后迟到结果不能触发连接")
        } catch is CancellationError { }
        try expect(reads == 1, "停止后不得继续轮询 Cookie")
    }

    static func cancellation() async throws {
        var reads = 0
        let task = Task { () throws -> String in
            try await QuarkLoginCredential.collect(readCookies: {
                reads += 1
                return [cookie("__puus", "synthetic")]
            }, isActive: { true }, pause: { try await Task.sleep(for: .seconds(10)) })
        }
        await Task.yield()
        task.cancel()
        do { _ = try await task.value; throw Failure(message: "取消任务不能完成登录") }
        catch is CancellationError { }
        try expect(reads <= 1, "取消后继续读取 Cookie")
    }

    static func header(_ cookies: [HTTPCookie]) -> String? { QuarkLoginCredential.header(from: cookies, now: fixedNow) }
    static func cookie(_ name: String, _ value: String, domain: String = ".quark.cn", path: String = "/", expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: path, .name: name, .value: value, .secure: "TRUE"]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }
    static func expect(_ condition: Bool, _ message: String) throws {
        assertions += 1
        if !condition { throw Failure(message: message) }
    }
    struct Failure: Error { let message: String }
}
