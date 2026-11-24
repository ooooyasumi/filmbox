// Appended to CloudGateway.swift to exercise the production Vault IPC path.
// The test uses only a generated account ID and never opens the catalogue.
@main private enum CredentialVaultClientChecks {
    private struct Failure: Error { let message: String }
    private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
    }
    static func main() async {
        guard Bundle.main.bundleIdentifier == "com.filmbox.app", (2...3).contains(CommandLine.arguments.count),
              let id = UUID(uuidString: CommandLine.arguments[1]) else { exit(2) }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/filmbox-credential-helper-v1")
        let backup = helper.appendingPathExtension("fixture-backup")
        var written = false
        do {
            if CommandLine.arguments.count == 3 {
                guard CommandLine.arguments[2] == "cleanup" else { exit(2) }
                try await CloudCredentialVault.remove(accountID: id)
                return
            }
            try expect(CloudCredentialHelperRouting.name(systemMajorVersion: 15, usedCompatibilityHelper: false, distribution: true) == "filmbox-credential-helper-distribution-v1", "distribution must select its own helper on macOS 15")
            try expect(CloudCredentialHelperRouting.name(systemMajorVersion: 26, usedCompatibilityHelper: true, distribution: true) == "filmbox-credential-helper-distribution-v1", "legacy routing markers must not override the distribution profile")
            try expect(try await CloudCredentialVault.load(accountID: id) == nil, "random helper account was not initially empty")
            let first = CloudCredentialRecord(credential: "synthetic-helper-first", username: "synthetic-user", password: "synthetic-password")
            try await CloudCredentialVault.save(first, accountID: id, allowRecovery: true)
            written = true
            try expect(try await CloudCredentialVault.load(accountID: id) == first, "production Vault client did not decode the helper record")
            let current = CloudCredentialRecord(credential: "synthetic-helper-current", username: nil, password: nil)
            try await CloudCredentialVault.save(current, accountID: id)
            try expect(try await CloudCredentialVault.load(accountID: id) == current, "production Vault client did not persist rotation")
            // Verify the Release path fails closed without its helper. The
            // original helper itself is copied, never modified or re-signed.
            try FileManager.default.moveItem(at: helper, to: backup)
            do {
                _ = try await CloudCredentialVault.load(accountID: id)
                throw Failure(message: "Release silently fell back to the legacy direct Keychain")
            } catch CloudConnectionError.service { }
            try FileManager.default.moveItem(at: backup, to: helper)
            try expect(try await CloudCredentialVault.load(accountID: id) == current, "a helper startup failure lost the cached credential")
            try await CloudCredentialVault.remove(accountID: id)
            written = false
            try expect(try await CloudCredentialVault.load(accountID: id) == nil, "helper remove left the random account")
            print("Production credential Vault client: 6 checks passed; random account removed")
        } catch {
            if FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.moveItem(at: backup, to: helper)
            }
            if written { try? await CloudCredentialVault.remove(accountID: id) }
            fputs("Credential Vault client failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
