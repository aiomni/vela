import XCTest
@testable import RemoteCore

final class RemoteCoreTests: XCTestCase {
    func testPasswordUnicodeRoundtripAndSalt() throws {
        let first = try PasswordVerifier(password: "\u{6D4B}\u{8BD5}-remote-password-long-password", iterations: 100_000)
        let second = try PasswordVerifier(password: "\u{6D4B}\u{8BD5}-remote-password-long-password", iterations: 100_000)
        XCTAssertTrue(first.verify("\u{6D4B}\u{8BD5}-remote-password-long-password"))
        XCTAssertFalse(first.verify("wrong-password-long-password"))
        XCTAssertFalse(first.verify(""))
        XCTAssertNotEqual(first.digest, second.digest)
        let encoded = try JSONEncoder().encode(first)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("long-password"))
        XCTAssertTrue(try JSONDecoder().decode(PasswordVerifier.self, from: encoded).verify("\u{6D4B}\u{8BD5}-remote-password-long-password"))
        XCTAssertThrowsError(try PasswordVerifier(password: "short"))
    }
    func testSessionExpiryAndRevocation() throws {
        var registry = SessionRegistry(absoluteLifetime: 100, idleLifetime: 20)
        let token = try registry.issue(now: 0)
        XCTAssertFalse(registry.validate("unknown", now: 1))
        XCTAssertTrue(registry.validate(token, now: 19))
        XCTAssertTrue(registry.validate(token, now: 38))
        XCTAssertFalse(registry.validate(token, now: 59))
        let second = try registry.issue(now: 100)
        for now in stride(from: 110.0, to: 200.0, by: 10) { XCTAssertTrue(registry.validate(second, now: now)) }
        XCTAssertFalse(registry.validate(second, now: 200))
        let third = try registry.issue(now: 300)
        registry.revokeAll()
        XCTAssertFalse(registry.validate(third, now: 301))
    }
    func testRateLimitAndGlobalBudget() {
        var limiter = LoginRateLimiter()
        XCTAssertTrue(limiter.begin(address: "a", now: 0))
        limiter.finish(address: "a", success: false, now: 0)
        XCTAssertFalse(limiter.begin(address: "a", now: 0.1))
        XCTAssertTrue(limiter.begin(address: "a", now: 1))
        limiter.finish(address: "a", success: true, now: 1)
        XCTAssertTrue(limiter.begin(address: "a", now: 1.1))
        for index in 0..<17 { XCTAssertTrue(limiter.begin(address: String(index), now: 2)) }
        XCTAssertFalse(limiter.begin(address: "new", now: 3))
        XCTAssertTrue(limiter.begin(address: "new", now: 65))
    }
    func testConfigurationFailsClosed() throws {
        var config = RemoteConfiguration()
        XCTAssertFalse(config.enabled)
        config.enabled = true
        XCTAssertThrowsError(try config.validate())
        config.enabled = false; config.port = 80
        XCTAssertThrowsError(try config.validate())
    }
    func testUnconfiguredStateIsStableAndDoesNotWriteFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("remote-missing-\(UUID())")
        let files = RemoteFiles(directory: directory)
        XCTAssertEqual(try files.load(), try files.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testInputRejectsInvalidCoordinatesAndCommands() throws {
        var input = RemoteInput(type: "pointer")
        input.action = "down"; input.x = 0.2; input.y = 0.8; input.displayID = 1
        XCTAssertTrue(input.validate())
        input.x = .nan
        XCTAssertFalse(input.validate())
        input.x = 2
        XCTAssertFalse(input.validate())
        input.x = 0.5; input.button = 9
        XCTAssertFalse(input.validate())
        XCTAssertFalse(RemoteInput(type: "exec").validate())
        var key = RemoteInput(type: "key")
        key.action = "down"; key.code = "Bogus"
        XCTAssertFalse(key.validate())
        key.code = "MetaLeft"
        XCTAssertTrue(key.validate())
    }
}
