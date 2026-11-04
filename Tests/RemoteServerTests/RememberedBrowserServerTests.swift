import XCTest
import Foundation
import RemoteCore
@testable import RemoteServer

final class RememberedBrowserServerTests: XCTestCase {
    @MainActor
    func testRememberedAccountEnforcesPolicyAndRechecksConcurrentRevocation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vela-browser-policy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = RemoteFiles(directory: directory), account = RememberedAccountDirectory()
        var config = RemoteConfiguration()
        try config.selectAuthentication(.macOSAccount, account: account.identity)
        config.enabled = true; config.port = Int.random(in: 42000...58000); try files.save(config)
        let host = RemoteHostService(files: files, addressProvider: { [] }, authenticator: RemoteAuthenticator(directory: account))
        await host.tick()
        func call(_ path: String, body: [String: Any], cookie: String? = nil) async throws -> RemoteResponse {
            await host.handle(RemoteRequest(method: "POST", path: "/api/\(path)", host: "127.0.0.1:\(config.port)",
                origin: "https://127.0.0.1:\(config.port)", authorization: nil, contentType: "application/json",
                body: try JSONSerialization.data(withJSONObject: body), address: "127.0.0.1", cookie: cookie))
        }
        do {
            let enrolled = try await call("login", body: ["password": "fixture-account-password", "rememberDevice": true])
            XCTAssertEqual(enrolled.status, 200)
            let cookie = String(try XCTUnwrap(enrolled.setCookie).split(separator: ";")[0])
            let body: [String: Any] = ["mode": "macOSAccount", "generation": config.generation]
            account.allowed = false
            let policyDenied = try await call("device/resume", body: body, cookie: cookie)
            XCTAssertEqual(policyDenied.status, 401)
            account.allowed = true; account.block = true
            let pending = Task { try await call("device/resume", body: body, cookie: cookie) }
            for _ in 0..<100 where !account.entered { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(account.entered)
            let forgotten = try await call("device/forget", body: [:], cookie: cookie)
            XCTAssertEqual(forgotten.status, 200)
            account.release.signal()
            let deniedAfterRevocation = try await pending.value
            XCTAssertEqual(deniedAfterRevocation.status, 401, "Revocation during account-policy validation cannot mint a session")
            await host.shutdown()
        } catch { account.release.signal(); await host.shutdown(); throw error }
    }

    @MainActor
    func testRememberedCookieSurvivesRestartAndHonorsLogoutForgetAndHostRevocation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vela-browser-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = RemoteFiles(directory: directory)
        var configuration = RemoteConfiguration()
        configuration.enabled = true; configuration.port = Int.random(in: 42000...58000)
        configuration.password = try PasswordVerifier(password: "fixture-browser-password", iterations: 100_000)
        try files.save(configuration)
        var host = RemoteHostService(files: files, addressProvider: { [] })
        await host.tick()
        guard host.status.state == "listening" else { XCTFail(host.status.message); await host.shutdown(); return }
        let clientConfiguration = URLSessionConfiguration.ephemeral
        clientConfiguration.httpShouldSetCookies = false
        let client = URLSession(configuration: clientConfiguration,
            delegate: TestCertificateTrust(expected: try Data(contentsOf: files.certificateURL)), delegateQueue: nil)
        defer { client.invalidateAndCancel() }
        let origin = "https://127.0.0.1:\(configuration.port)"
        func call(_ path: String, body: [String: Any]? = nil, cookie: String? = nil,
                  token: String? = nil, requestOrigin: String? = nil) async throws -> (HTTPURLResponse, [String: Any]) {
            var request = URLRequest(url: URL(string: "\(origin)/api/\(path)")!)
            request.timeoutInterval = 5
            if let body {
                request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            if let requestOrigin { request.setValue(requestOrigin, forHTTPHeaderField: "Origin") }
            if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await client.data(for: request)
            return (try XCTUnwrap(response as? HTTPURLResponse), try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]))
        }
        func cookie(_ response: HTTPURLResponse) throws -> String {
            let value = try XCTUnwrap(response.value(forHTTPHeaderField: "Set-Cookie"))
            for attribute in ["Secure", "HttpOnly", "SameSite=Strict", "Path=/", "Max-Age=2592000"] { XCTAssertTrue(value.contains(attribute)) }
            return String(value.split(separator: ";")[0])
        }
        func resumeBody() -> [String: Any] { ["mode": "customPassword", "generation": configuration.generation] }
        do {
            let noConsent = try await call("login", body: ["password": "fixture-browser-password"])
            XCTAssertEqual(noConsent.0.statusCode, 200); XCTAssertNil(noConsent.0.value(forHTTPHeaderField: "Set-Cookie"))
            let enrolled = try await call("login", body: ["password": "fixture-browser-password", "rememberDevice": true], requestOrigin: origin)
            XCTAssertEqual(enrolled.0.statusCode, 200)
            let credential = try cookie(enrolled.0), originalToken = try XCTUnwrap(enrolled.1["token"] as? String)
            let noOrigin = try await call("device/resume", body: resumeBody(), cookie: credential)
            XCTAssertEqual(noOrigin.0.statusCode, 403)
            let crossOrigin = try await call("device/resume", body: resumeBody(), cookie: credential, requestOrigin: "https://evil.invalid")
            XCTAssertEqual(crossOrigin.0.statusCode, 403)
            let cookieOnly = try await call("display-capabilities", cookie: credential)
            XCTAssertEqual(cookieOnly.0.statusCode, 401, "Device cookies cannot authorize control APIs")
            let resumed = try await call("device/resume", body: resumeBody(), cookie: credential, requestOrigin: origin)
            XCTAssertEqual(resumed.0.statusCode, 200); XCTAssertEqual(resumed.1["token"] as? String, originalToken)
            let ended = try await call("logout", body: [:], token: originalToken)
            XCTAssertEqual(ended.0.statusCode, 200); XCTAssertNil(ended.0.value(forHTTPHeaderField: "Set-Cookie"))
            let reconnected = try await call("device/resume", body: resumeBody(), cookie: credential, requestOrigin: origin)
            XCTAssertEqual(reconnected.0.statusCode, 200); XCTAssertNotEqual(reconnected.1["token"] as? String, originalToken)
            await host.shutdown()
            host = RemoteHostService(files: files, addressProvider: { [] }); await host.tick()
            let afterRestart = try await call("device/resume", body: resumeBody(), cookie: credential, requestOrigin: origin)
            XCTAssertEqual(afterRestart.0.statusCode, 200, "Remembered browsers survive an ordinary app restart")
            let wrongForget = try await call("device/forget", body: [:], cookie: credential, requestOrigin: "https://evil.invalid")
            XCTAssertEqual(wrongForget.0.statusCode, 403)
            let forgotten = try await call("device/forget", body: [:], cookie: credential, requestOrigin: origin)
            XCTAssertEqual(forgotten.0.statusCode, 200); XCTAssertTrue(forgotten.0.value(forHTTPHeaderField: "Set-Cookie")?.contains("Max-Age=0") == true)
            let denied = try await call("device/resume", body: resumeBody(), cookie: credential, requestOrigin: origin)
            XCTAssertEqual(denied.0.statusCode, 401)
            let forgottenToken = try XCTUnwrap(afterRestart.1["token"] as? String)
            let revokedSession = try await call("display-capabilities", token: forgottenToken)
            XCTAssertEqual(revokedSession.0.statusCode, 401)
            let enrolledAgain = try await call("login", body: ["password": "fixture-browser-password", "rememberDevice": true], requestOrigin: origin)
            let secondCookie = try cookie(enrolledAgain.0)
            configuration.disconnectGeneration += 1; try files.save(configuration); await host.tick()
            let hostRevoked = try await call("device/resume", body: resumeBody(), cookie: secondCookie, requestOrigin: origin)
            XCTAssertEqual(hostRevoked.0.statusCode, 401)
            let enrolledThird = try await call("login", body: ["password": "fixture-browser-password", "rememberDevice": true], requestOrigin: origin)
            let thirdCookie = try cookie(enrolledThird.0)
            configuration.password = try PasswordVerifier(password: "fixture-new-browser-password", iterations: 100_000)
            try files.save(configuration); await host.tick()
            let passwordRevoked = try await call("device/resume", body: resumeBody(), cookie: thirdCookie, requestOrigin: origin)
            XCTAssertEqual(passwordRevoked.0.statusCode, 401, "Even a verifier change without a generation edit revokes browser trust")
            let finalEnrollment = try await call("login", body: ["password": "fixture-new-browser-password", "rememberDevice": true], requestOrigin: origin)
            let finalCookie = try cookie(finalEnrollment.0), finalToken = try XCTUnwrap(finalEnrollment.1["token"] as? String)
            let optOut = try await call("login", body: ["password": "fixture-new-browser-password", "rememberDevice": false], cookie: finalCookie, requestOrigin: origin)
            XCTAssertEqual(optOut.0.statusCode, 200)
            XCTAssertTrue(optOut.0.value(forHTTPHeaderField: "Set-Cookie")?.contains("Max-Age=0") == true)
            let optedOutSession = try await call("display-capabilities", token: finalToken)
            XCTAssertEqual(optedOutSession.0.statusCode, 401)
            let optedOutTrust = try await call("device/resume", body: resumeBody(), cookie: finalCookie, requestOrigin: origin)
            XCTAssertEqual(optedOutTrust.0.statusCode, 401)
            await host.shutdown()
        } catch { await host.shutdown(); throw error }
    }
}

private final class RememberedAccountDirectory: RemoteAccountDirectory, @unchecked Sendable {
    let identity = RemoteSystemAccount(uid: 501, generatedUID: UUID(), shortName: "fixture-owner")
    private let lock = NSLock()
    private var permitted = true
    private var blocked = false
    private var started = false
    let release = DispatchSemaphore(value: 0)
    var allowed: Bool { get { lock.withLock { permitted } } set { lock.withLock { permitted = newValue } } }
    var block: Bool { get { lock.withLock { blocked } } set { lock.withLock { blocked = newValue } } }
    var entered: Bool { lock.withLock { started } }
    func currentAccount() throws -> RemoteSystemAccount { identity }
    func authenticationAllowed(for account: RemoteSystemAccount) throws {
        guard allowed else { throw RemoteError.message("Fixture account policy denied authentication.") }
        if block {
            lock.withLock { started = true }
            guard release.wait(timeout: .now() + 3) == .success else { throw RemoteError.message("Fixture policy timeout.") }
        }
    }
    func verifyPassword(_ password: String, for account: RemoteSystemAccount) throws {
        guard password == "fixture-account-password" else { throw RemoteError.message("Fixture password rejected.") }
    }
}
