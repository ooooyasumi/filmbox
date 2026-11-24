// Frozen protocol v1. Changing this executable changes its Keychain identity;
// ship a deliberate version migration rather than silently rebuilding v1.
import Foundation
import Security
import LocalAuthentication
import CryptoKit
import Darwin

private let helperIdentifier = "com.filmbox.app.credential-helper.v1"
private let applicationIdentifier = "com.filmbox.app"
private let credentialService = "com.filmbox.app.cloud.credentials.v1"
private let maximumRecordBytes = 65_536
private let maximumFrameBytes = 131_072

private struct Request: Decodable {
    let version: Int
    let operation: String
    let accountID: String
    let record: Data?
    enum CodingKeys: String, CodingKey { case version, operation, record; case accountID = "account_id" }
}

private struct Response: Encodable {
    let version = 1
    let status: String
    var record: Data? = nil
    var errorCode: String? = nil
    var osStatus: Int32? = nil
    enum CodingKeys: String, CodingKey { case version, status, record; case errorCode = "error_code"; case osStatus = "os_status" }
}

private enum HelperFailure: Error {
    case unauthorizedParent, invalidRequest, keychain(OSStatus)
}

private func signingInfo(_ code: SecCode) throws -> [String: Any] {
    var staticCode: SecStaticCode?
    var information: CFDictionary?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let information = information as? [String: Any] else { throw HelperFailure.unauthorizedParent }
    return information
}

private func leafCertificate(_ information: [String: Any]) throws -> Data {
    guard let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate],
          let leaf = certificates.first else { throw HelperFailure.unauthorizedParent }
    return SecCertificateCopyData(leaf) as Data
}

private func isHardened(_ information: [String: Any]) -> Bool {
    guard let flags = information[kSecCodeInfoFlags as String] as? NSNumber,
          flags.uint32Value & 0x10000 != 0 else { return false } // CS_RUNTIME
    let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
    return !["com.apple.security.get-task-allow", "com.apple.security.cs.allow-dyld-environment-variables",
             "com.apple.security.cs.disable-library-validation", "com.apple.security.cs.disable-executable-page-protection",
             "com.apple.security.cs.allow-unsigned-executable-memory", "com.apple.security.cs.allow-jit"]
        .contains { (entitlements[$0] as? Bool) == true }
}

private func authorizeParent() throws {
    var ownCode: SecCode?
    guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
          SecCodeCheckValidity(ownCode, [], nil) == errSecSuccess else { throw HelperFailure.unauthorizedParent }
    let ownInformation = try signingInfo(ownCode)
    guard ownInformation[kSecCodeInfoIdentifier as String] as? String == helperIdentifier,
          isHardened(ownInformation) else { throw HelperFailure.unauthorizedParent }
    let certificate = try leafCertificate(ownInformation)
    let fingerprint = Insecure.SHA1.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
    var requirement: SecRequirement?
    let rule = "identifier \"\(applicationIdentifier)\" and certificate leaf = H\"\(fingerprint)\""
    guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
          let requirement else { throw HelperFailure.unauthorizedParent }
    let parentPID = getppid()
    guard parentPID > 1 else { throw HelperFailure.unauthorizedParent }
    var parentCode: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: parentPID] as CFDictionary, [], &parentCode) == errSecSuccess,
          let parentCode, SecCodeCheckValidity(parentCode, [], requirement) == errSecSuccess else {
        throw HelperFailure.unauthorizedParent
    }
    let parentInformation = try signingInfo(parentCode)
    guard parentInformation[kSecCodeInfoIdentifier as String] as? String == applicationIdentifier,
          try leafCertificate(parentInformation) == certificate, isHardened(parentInformation),
          getppid() == parentPID else { throw HelperFailure.unauthorizedParent }
}

private func readRequest() throws -> Request {
    var frame = Data()
    while let bytes = try FileHandle.standardInput.read(upToCount: min(4_096, maximumFrameBytes + 1 - frame.count)), !bytes.isEmpty {
        frame.append(bytes)
        guard frame.count <= maximumFrameBytes else { throw HelperFailure.invalidRequest }
    }
    guard let request = try? JSONDecoder().decode(Request.self, from: frame), request.version == 1,
          let accountID = UUID(uuidString: request.accountID), accountID.uuidString == request.accountID,
          ["load", "save", "remove"].contains(request.operation) else { throw HelperFailure.invalidRequest }
    if request.operation == "save" {
        guard let record = request.record, !record.isEmpty, record.count <= maximumRecordBytes else { throw HelperFailure.invalidRequest }
    } else if request.record != nil { throw HelperFailure.invalidRequest }
    return request
}

private func keychainQuery(_ accountID: String) -> [CFString: Any] {
    let context = LAContext()
    context.interactionNotAllowed = true
    return [kSecClass: kSecClassGenericPassword, kSecAttrService: credentialService,
            kSecAttrAccount: accountID, kSecUseAuthenticationContext: context,
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail]
}

private func perform(_ request: Request) throws -> Response {
    let interactionStatus = SecKeychainSetUserInteractionAllowed(false)
    guard interactionStatus == errSecSuccess else { throw HelperFailure.keychain(interactionStatus) }
    var query = keychainQuery(request.accountID)
    switch request.operation {
    case "load":
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return Response(status: "not_found") }
        guard status == errSecSuccess else { throw HelperFailure.keychain(status) }
        guard let record = result as? Data, !record.isEmpty, record.count <= maximumRecordBytes else { throw HelperFailure.invalidRequest }
        return Response(status: "ok", record: record)
    case "save":
        guard let record = request.record else { throw HelperFailure.invalidRequest }
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: record] as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData] = record
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw HelperFailure.keychain(status) }
        return Response(status: "ok")
    case "remove":
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw HelperFailure.keychain(status) }
        return Response(status: "ok")
    default: throw HelperFailure.invalidRequest
    }
}

private func write(_ response: Response, exitCode: Int32 = 0) -> Never {
    if var bytes = try? JSONEncoder().encode(response) {
        bytes.append(10)
        try? FileHandle.standardOutput.write(contentsOf: bytes)
    }
    _exit(exitCode)
}

@main private enum CredentialHelper {
    static func main() {
        // No inherited environment influences storage paths, code requirements
        // or credential service. No socket or persistent listener is created.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6) { _exit(75) }
        do {
            try authorizeParent()
            let request = try readRequest()
            write(try perform(request))
        } catch HelperFailure.unauthorizedParent {
            write(Response(status: "error", errorCode: "unauthorized_parent"), exitCode: 77)
        } catch HelperFailure.invalidRequest {
            write(Response(status: "error", errorCode: "invalid_request"), exitCode: 64)
        } catch HelperFailure.keychain(let status) {
            var state: SecKeychainStatus = 0
            let stateStatus = SecKeychainGetStatus(nil, &state)
            let denied = [errSecInteractionNotAllowed, errSecAuthFailed, errSecNoAccessForItem].contains(status)
            let unlocked = stateStatus == errSecSuccess && state & SecKeychainStatus(kSecUnlockStateStatus) != 0
            write(Response(status: "error", errorCode: denied && unlocked ? "keychain_denied" : "keychain_unavailable", osStatus: status))
        } catch {
            write(Response(status: "error", errorCode: "invalid_request"), exitCode: 64)
        }
    }
}
