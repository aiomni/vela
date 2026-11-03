import XCTest
@testable import RemoteCore

final class RemoteAuthenticationTests: XCTestCase {
    private let account = RemoteSystemAccount(uid: 501, generatedUID: UUID(), shortName: "fixture-owner")

    func testLegacyConfigurationMigrationAndUnknownModeFailClosed() throws {
        var original = RemoteConfiguration()
        original.enabled = true
        original.password = try PasswordVerifier(password: "fixture-custom-password", iterations: 100_000)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "authenticationMode"); json.removeValue(forKey: "systemAccount")
        let legacy = try JSONDecoder().decode(RemoteConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.authenticationMode, .customPassword)
        XCTAssertEqual(legacy.password, original.password)
        XCTAssertTrue(legacy.enabled)
        try legacy.validate()
        for invalid: Any in ["unrecognized", NSNull()] {
            json["authenticationMode"] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(RemoteConfiguration.self, from: JSONSerialization.data(withJSONObject: json)))
        }
    }
    func testModeSelectionPersistenceAndNoAutomaticEnable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = RemoteFiles(directory: directory)
        var config = RemoteConfiguration()
        let oldGeneration = config.generation
        try config.selectAuthentication(.macOSAccount, account: account)
        XCTAssertFalse(config.enabled)
        XCTAssertNotEqual(config.generation, oldGeneration)
        config.enabled = true
        try files.save(config)
        XCTAssertEqual(try RemoteFiles(directory: directory).load(), config)
        try config.selectAuthentication(.customPassword)
        XCTAssertFalse(config.enabled)
        config.password = try PasswordVerifier(password: "fixture-retained-password", iterations: 100_000)
        let saved = config.password
        try config.selectAuthentication(.macOSAccount, account: account)
        try config.selectAuthentication(.customPassword)
        XCTAssertEqual(config.password, saved)
        XCTAssertNil(config.systemAccount)
        XCTAssertThrowsError(try config.selectAuthentication(.macOSAccount))
    }
    func testPinnedIdentityPoliciesAndPasswordFailures() throws {
        var config = RemoteConfiguration()
        try config.selectAuthentication(.macOSAccount, account: account)
        let directory = FixtureDirectory(account: account)
        let auth = RemoteAuthenticator(directory: directory)
        XCTAssertEqual(try auth.selectableSystemAccount(), account)
        XCTAssertTrue(auth.verify("fixture-system-password", configuration: config))
        XCTAssertFalse(auth.verify("wrong", configuration: config))
        XCTAssertFalse(auth.verify("", configuration: config))
        XCTAssertFalse(auth.verify(String(repeating: "x", count: 1025), configuration: config))
        let count = directory.calls
        directory.account = RemoteSystemAccount(uid: account.uid, generatedUID: UUID(), shortName: account.shortName)
        XCTAssertFalse(auth.verify("fixture-system-password", configuration: config))
        directory.account = RemoteSystemAccount(uid: 502, generatedUID: account.generatedUID, shortName: account.shortName)
        XCTAssertFalse(auth.verify("fixture-system-password", configuration: config))
        directory.account = RemoteSystemAccount(uid: account.uid, generatedUID: account.generatedUID, shortName: "renamed")
        XCTAssertFalse(auth.verify("fixture-system-password", configuration: config))
        XCTAssertEqual(directory.calls, count, "Identity mismatch must not reach password verification")
        directory.account = account; directory.allowed = false
        XCTAssertFalse(auth.verify("fixture-system-password", configuration: config))
        XCTAssertThrowsError(try auth.validate(config)) { error in
            XCTAssertFalse(error.localizedDescription.contains("private-directory-detail"))
        }
        XCTAssertEqual(directory.calls, count)
        XCTAssertThrowsError(try RemoteSystemAccount(uid: 0, generatedUID: UUID(), shortName: "root").validate())
    }
    func testCustomPasswordNeverUsesSystemDirectoryAndNoSecretInConfiguration() throws {
        let directory = FixtureDirectory(account: account); directory.allowed = false
        let auth = RemoteAuthenticator(directory: directory)
        var config = RemoteConfiguration()
        config.password = try PasswordVerifier(password: "fixture-custom-password", iterations: 100_000)
        XCTAssertTrue(auth.verify("fixture-custom-password", configuration: config))
        XCTAssertEqual(directory.lookups, 0)
        try config.selectAuthentication(.macOSAccount, account: account)
        let json = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        XCTAssertFalse(json.contains("fixture-custom-password"))
        XCTAssertFalse(json.contains("fixture-system-password"))
    }
    func testProtectedSessionRequiresCurrentMacAccountPassword() throws {
        let directory = FixtureDirectory(account: account)
        let auth = RemoteAuthenticator(directory: directory)
        XCTAssertFalse(auth.verifyCurrentAccountPassword("fixture-custom-password"))
        XCTAssertTrue(auth.verifyCurrentAccountPassword("fixture-system-password"))
        let calls = directory.calls
        XCTAssertFalse(auth.verifyCurrentAccountPassword(""))
        XCTAssertFalse(auth.verifyCurrentAccountPassword(String(repeating: "x", count: 1025)))
        XCTAssertEqual(directory.calls, calls)
        directory.allowed = false
        XCTAssertFalse(auth.verifyCurrentAccountPassword("fixture-system-password"))
        XCTAssertEqual(directory.calls, calls, "A disabled account must not reach password verification")
        directory.allowed = true; directory.changeIdentityAfterVerify = true
        XCTAssertFalse(auth.verifyCurrentAccountPassword("fixture-system-password"), "Account replacement during verification must fail closed")
    }
}

// Synchronous fixture is used only synchronously in these core tests.
private final class FixtureDirectory: RemoteAccountDirectory, @unchecked Sendable {
    var account: RemoteSystemAccount
    var allowed = true
    var calls = 0
    var lookups = 0
    var changeIdentityAfterVerify = false
    init(account: RemoteSystemAccount) { self.account = account }
    func currentAccount() throws -> RemoteSystemAccount { lookups += 1; return account }
    func authenticationAllowed(for account: RemoteSystemAccount) throws {
        if !allowed { throw RemoteError.message("private-directory-detail") }
    }
    func verifyPassword(_ password: String, for account: RemoteSystemAccount) throws {
        calls += 1
        if password != "fixture-system-password" { throw RemoteError.message("private-directory-detail") }
        if changeIdentityAfterVerify { self.account = RemoteSystemAccount(uid: account.uid, generatedUID: UUID(), shortName: account.shortName) }
    }
}
