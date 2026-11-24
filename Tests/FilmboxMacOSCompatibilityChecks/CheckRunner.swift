import Foundation

@main struct CompatibilityChecks {
    static func main() throws {
        var count = 0
        for major in [15, 16, 25, 26, 27] {
            for retained in [false, true] {
                let actual = CloudCredentialHelperRouting.name(systemMajorVersion: major, usedCompatibilityHelper: retained)
                let expected = major < 26 || retained ? "filmbox-credential-helper-macos15-v1" : "filmbox-credential-helper-v1"
                guard actual == expected else { throw Failure() }
                count += 1
            }
        }
        print("\(count)项登录组件系统选择检查通过；macOS 15 不启动26组件，升级系统后保留原有凭据身份")
    }
    private struct Failure: Error {}
}
