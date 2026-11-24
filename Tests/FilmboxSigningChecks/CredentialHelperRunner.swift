import Foundation

/// This caller intentionally shares Filmbox's signing identifier while keeping
/// all request account IDs random. It never loads the app catalogue or UI.
@main
private struct CredentialHelperChecks {
    struct Request: Encodable {
        let version = 1
        let operation: String
        let accountID: String
        let record: Data?
        enum CodingKeys: String, CodingKey { case version, operation, record; case accountID = "account_id" }
    }
    struct Response: Decodable {
        let version: Int
        let status: String
        let record: Data?
        let errorCode: String?
        let osStatus: Int32?
        enum CodingKeys: String, CodingKey {
            case version, status, record
            case errorCode = "error_code"
            case osStatus = "os_status"
        }
    }
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    static let initial = Data("{\"credential\":\"synthetic-original\",\"username\":null,\"password\":null}".utf8)
    static let refreshed = Data("{\"credential\":\"synthetic-refreshed\",\"username\":null,\"password\":null}".utf8)

    static func main() {
        #if HELPER_NEW_PARENT
        let variant = "升级后的不同主程序"
        #else
        let variant = "升级前的主程序"
        #endif
        guard CommandLine.arguments.count == 4,
              let bundleID = Bundle.main.bundleIdentifier,
              bundleID == "com.filmbox.app" || bundleID.hasPrefix("com.filmbox.helper-test."),
              let account = UUID(uuidString: CommandLine.arguments[3]), account.uuidString == CommandLine.arguments[3] else { exit(2) }
        let mode = CommandLine.arguments[1]
        let helper = URL(fileURLWithPath: CommandLine.arguments[2])
        guard helper.lastPathComponent == "filmbox-credential-helper-v1" else { exit(2) }
        do {
            switch mode {
            case "write":
                let absent = try call("load", helper: helper, account: account)
                guard absent.status == "not_found", absent.record == nil else { throw Failure("随机账号初始状态应为空") }
                try ok(call("save", helper: helper, account: account, record: initial))
                try check(helper: helper, account: account, expected: initial)
            case "read-initial":
                try check(helper: helper, account: account, expected: initial)
            case "refresh":
                try check(helper: helper, account: account, expected: initial)
                try ok(call("save", helper: helper, account: account, record: refreshed))
                try check(helper: helper, account: account, expected: refreshed)
            case "read-refreshed":
                try check(helper: helper, account: account, expected: refreshed)
            case "denied-adhoc", "denied-identifier", "denied-runtime":
                let response = try call("load", helper: helper, account: account, expectedExit: 77)
                guard response.status == "error", response.errorCode == "unauthorized_parent", response.record == nil else {
                    throw Failure("不可信父进程未被拒绝或泄露了凭据")
                }
            case "cleanup":
                try ok(call("remove", helper: helper, account: account))
                let absent = try call("load", helper: helper, account: account)
                guard absent.status == "not_found", absent.record == nil else { throw Failure("随机测试账号未清理完整") }
            default: throw Failure("未知验收模式")
            }
            print("✓ \(variant)：\(mode)")
        } catch {
            fputs("稳定凭据组件验收失败：\(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    static func call(_ operation: String, helper: URL, account: UUID, record: Data? = nil, expectedExit: Int32 = 0) throws -> Response {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = helper
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let data = try JSONEncoder().encode(Request(operation: operation, accountID: account.uuidString, record: record))
        // An unauthorized parent may be refused before stdin is read. Ignoring
        // SIGPIPE in this isolated probe lets us still verify the error reply.
        _ = signal(SIGPIPE, SIG_IGN)
        do { try input.fileHandleForWriting.write(contentsOf: data) }
        catch { if expectedExit != 77 { throw error } }
        try input.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == expectedExit else {
            throw Failure("凭据组件进程状态异常：\(process.terminationStatus)，期望 \(expectedExit)")
        }
        guard !result.isEmpty, result.count <= 262_144 else { throw Failure("凭据组件返回大小异常") }
        let response = try JSONDecoder().decode(Response.self, from: result)
        guard response.version == 1 else { throw Failure("凭据组件协议版本异常") }
        return response
    }

    static func ok(_ response: Response) throws {
        guard response.status == "ok", response.errorCode == nil else {
            throw Failure("凭据操作失败：\(response.errorCode ?? response.status)，系统状态 \(response.osStatus ?? 0)")
        }
    }

    static func check(helper: URL, account: UUID, expected: Data) throws {
        let response = try call("load", helper: helper, account: account)
        try ok(response)
        guard response.record == expected else { throw Failure("升级后的凭据与写入值不一致") }
    }
}
