import XCTest
import Foundation
import RemoteCore
@testable import RemoteServer

final class RemoteNetworkRecoveryTests: XCTestCase {
    func testAddressChangesWaitForStableNetworkAndIdleMedia() {
        var changes = RemoteAddressChangeTracker()
        let original = ["192.168.1.2"], replacement = ["192.168.2.2"]
        XCTAssertFalse(changes.shouldRebind(current: original, observed: [], now: 0, hasPeer: true))
        XCTAssertFalse(changes.shouldRebind(current: original, observed: [], now: 60, hasPeer: false))
        XCTAssertFalse(changes.shouldRebind(current: original, observed: original, now: 61, hasPeer: true))
        XCTAssertFalse(changes.shouldRebind(current: original, observed: replacement, now: 62, hasPeer: false))
        XCTAssertFalse(changes.shouldRebind(current: original, observed: replacement, now: 76, hasPeer: false))
        XCTAssertFalse(changes.shouldRebind(current: original, observed: replacement, now: 80, hasPeer: true))
        XCTAssertTrue(changes.shouldRebind(current: original, observed: replacement, now: 81, hasPeer: false))
        XCTAssertFalse(changes.shouldRebind(current: original, observed: [], now: 82, hasPeer: false))
        XCTAssertFalse(changes.shouldRebind(current: original, observed: replacement, now: 83, hasPeer: false))
    }

    @MainActor
    func testTemporaryAddressLossPreservesTLSTrustAndAuthenticatedSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vela-network-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = RemoteFiles(directory: directory)
        var configuration = RemoteConfiguration()
        configuration.enabled = true; configuration.port = Int.random(in: 42000...58000)
        configuration.password = try PasswordVerifier(password: "network-recovery-fixture", iterations: 100_000)
        try files.save(configuration)
        var addresses = ["127.0.0.1"]
        let host = RemoteHostService(files: files, addressProvider: { addresses })
        await host.tick()
        let certificate = try Data(contentsOf: files.certificateURL)
        let session = URLSession(configuration: .ephemeral,
                                 delegate: TestCertificateTrust(expected: certificate), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        func request(_ path: String, token: String? = nil) async throws -> (Int, Data) {
            var request = URLRequest(url: URL(string: "https://127.0.0.1:\(configuration.port)/api/\(path)")!)
            request.timeoutInterval = 3
            if path == "login" {
                request.httpMethod = "POST"
                request.httpBody = try JSONEncoder().encode(["password": "network-recovery-fixture"])
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await session.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, data)
        }
        do {
            let login = try await request("login")
            XCTAssertEqual(login.0, 200)
            let token = try XCTUnwrap(try JSONDecoder().decode([String: String].self, from: login.1)["token"])
            for observed in [[], ["127.0.0.1"], [], ["127.0.0.1"]] {
                addresses = observed
                await host.tick()
                XCTAssertEqual(try Data(contentsOf: files.certificateURL), certificate)
                let poll = try await request("poll", token: token)
                XCTAssertEqual(poll.0, 200, "Temporary interface loss must not revoke login or replace TLS")
            }
            await host.shutdown()
        } catch { await host.shutdown(); throw error }
    }
}
