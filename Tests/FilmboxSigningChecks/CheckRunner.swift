import Foundation
import LocalAuthentication
import Security

/// A separate bundle and random Keychain service/account verify the system's
/// actual partition boundary across a self-signed binary replacement. No app
/// credentials, Keychain trust settings, or item ACLs are read or modified.
@main
private struct StableSigningChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func main() {
        #if SIGNING_NEW_VARIANT
        let variant = "升级后的不同二进制"
        #else
        let variant = "升级前的二进制"
        #endif
        guard CommandLine.arguments.count == 4,
              let bundleID = Bundle.main.bundleIdentifier, bundleID.hasPrefix("com.filmbox.signing-checks."),
              let randomID = UUID(uuidString: CommandLine.arguments[3]),
              CommandLine.arguments[2] == "com.filmbox.signing-checks." + randomID.uuidString else { exit(2) }
        let mode = CommandLine.arguments[1]
        let service = CommandLine.arguments[2]
        let account = randomID.uuidString
        do {
            guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw Failure("无法关闭探针的钥匙串交互") }
            switch mode {
            case "write":
                var addition = query(service: service, account: account)
                addition[kSecValueData] = Data("synthetic-upgrade-original".utf8)
                addition[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                try success(SecItemAdd(addition as CFDictionary, nil), "建立随机测试凭据")
                try check(service: service, account: account, value: "synthetic-upgrade-original")
            case "read-initial":
                try check(service: service, account: account, value: "synthetic-upgrade-original")
            case "refresh":
                try check(service: service, account: account, value: "synthetic-upgrade-original")
                let update = [kSecValueData: Data("synthetic-upgrade-refreshed".utf8)] as CFDictionary
                try success(SecItemUpdate(query(service: service, account: account) as CFDictionary, update), "更新随机测试凭据")
                try check(service: service, account: account, value: "synthetic-upgrade-refreshed")
            case "read-refreshed":
                try check(service: service, account: account, value: "synthetic-upgrade-refreshed")
            case "denied":
                let (status, data) = read(service: service, account: account)
                guard [errSecInteractionNotAllowed, errSecAuthFailed, errSecNoAccessForItem].contains(status), data == nil else {
                    throw Failure("未获分区授权的二进制未被拒绝，状态 \(status)")
                }
            case "cleanup":
                let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure("清理随机测试凭据失败，状态 \(status)") }
                let (remaining, data) = read(service: service, account: account)
                guard remaining == errSecItemNotFound, data == nil else { throw Failure("随机测试凭据未清理完整，状态 \(remaining)") }
            default: throw Failure("未知验收模式")
            }
            print("✓ \(variant)：\(mode)")
        } catch {
            fputs("稳定签名验收失败：\(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    static func query(service: String, account: String) -> [CFString: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                kSecUseAuthenticationContext: context, kSecUseAuthenticationUI: kSecUseAuthenticationUIFail]
    }

    static func read(service: String, account: String) -> (OSStatus, Data?) {
        var request = query(service: service, account: account)
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        return (status, result as? Data)
    }

    static func check(service: String, account: String, value: String) throws {
        let (status, data) = read(service: service, account: account)
        try success(status, "读取随机测试凭据")
        guard data == Data(value.utf8) else { throw Failure("升级后随机凭据内容不匹配") }
    }

    static func success(_ status: OSStatus, _ operation: String) throws {
        guard status == errSecSuccess else { throw Failure("\(operation)失败，状态 \(status)") }
    }

}
