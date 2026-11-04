import XCTest
@testable import RemoteCore

final class RememberedBrowserTests: XCTestCase {
    func testPersistenceHashingExpiryReplacementAndRevocation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RememberedBrowsers(files: RemoteFiles(directory: directory)), now = Date(timeIntervalSince1970: 1000)
        let token = try store.issue(binding: "binding", replacing: nil, now: now)
        XCTAssertTrue(try RememberedBrowsers(files: store.files).validate(token, binding: "binding", now: now))
        XCTAssertFalse(String(decoding: try Data(contentsOf: store.url), as: UTF8.self).contains(token))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertFalse(try store.validate(token, binding: "different", now: now))
        XCTAssertFalse(try store.validate(token, binding: "binding", now: now.addingTimeInterval(-1)))
        XCTAssertTrue(try store.validate(token, binding: "binding", now: now.addingTimeInterval(RememberedBrowsers.lifetime - 1)))
        XCTAssertFalse(try store.validate(token, binding: "binding", now: now.addingTimeInterval(RememberedBrowsers.lifetime)))
        let replacement = try store.issue(binding: "binding", replacing: token, now: now)
        XCTAssertNotEqual(token, replacement)
        XCTAssertFalse(try store.validate(token, binding: "binding", now: now))
        try store.revoke(replacement)
        XCTAssertFalse(try store.validate(replacement, binding: "binding", now: now))
        try Data("invalid".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.validate(token, binding: "binding", now: now))
    }
    func testBindingChangesForAuthenticationCertificateAndHostRevocation() throws {
        var config = RemoteConfiguration()
        config.password = try PasswordVerifier(password: "fixture-remember-password", iterations: 100_000)
        let original = try RememberedBrowsers.binding(configuration: config, fingerprint: "certificate")
        config.batteryFloor += 1
        XCTAssertEqual(try RememberedBrowsers.binding(configuration: config, fingerprint: "certificate"), original)
        XCTAssertNotEqual(try RememberedBrowsers.binding(configuration: config, fingerprint: "new-certificate"), original)
        config.disconnectGeneration += 1
        XCTAssertNotEqual(try RememberedBrowsers.binding(configuration: config, fingerprint: "certificate"), original)
        config.disconnectGeneration -= 1; config.password = try PasswordVerifier(password: "fixture-new-password", iterations: 100_000)
        XCTAssertNotEqual(try RememberedBrowsers.binding(configuration: config, fingerprint: "certificate"), original)
    }
    func testCookieRejectsAmbiguityAndUnsafeValues() throws {
        let token = try RemoteSecurity.token(), name = RememberedBrowserCookie.name(port: 8443)
        XCTAssertEqual(RememberedBrowserCookie.read("other=1; \(name)=\(token)", port: 8443), token)
        XCTAssertNil(RememberedBrowserCookie.read("\(name)=\(token); \(name)=\(token)", port: 8443))
        XCTAssertNil(RememberedBrowserCookie.read("\(name)=\(token)", port: 8444))
        XCTAssertNil(RememberedBrowserCookie.read("\(name)=not-a-credential", port: 8443))
        let header = RememberedBrowserCookie.set(token, port: 8443)
        for part in ["__Host-", "Path=/", "Max-Age=2592000", "Secure", "HttpOnly", "SameSite=Strict"] { XCTAssertTrue(header.contains(part)) }
        XCTAssertFalse(header.contains("Domain="))
        let invalid = RememberedBrowserCookie.set("unsafe\r\nheader", port: 8443)
        XCTAssertFalse(invalid.contains("\r\n")); XCTAssertTrue(invalid.contains("Max-Age=0"))
    }
}
