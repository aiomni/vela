import XCTest
import Foundation
import Security
import RemoteCore
import RemoteRTC
import WebRTC
import CoreVideo
@testable import RemoteServer

final class RemoteServerTests: XCTestCase {
    @MainActor
    func testAppOwnedRuntimeStopsListenerPreservesSettingsAndRevokesSessions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vela-lifecycle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = RemoteFiles(directory: directory)
        var config = RemoteConfiguration()
        config.enabled = true; config.port = Int.random(in: 42000...58000)
        config.password = try PasswordVerifier(password: "fixture-lifecycle-password", iterations: 100_000)
        try files.save(config)
        let saved = try Data(contentsOf: files.configurationURL)
        let runtime = RemoteHostRuntime(files: files, addressProvider: { [] })
        func waitUntilListening(_ runtime: RemoteHostRuntime) async throws {
            for _ in 0..<200 {
                if runtime.service.status.state == "listening" { return }
                if runtime.service.status.state == "error" { throw RemoteError.message(runtime.service.status.message) }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw RemoteError.message("Runtime did not start")
        }
        try runtime.start()
        do { try await waitUntilListening(runtime) }
        catch { await runtime.stop(); throw error }
        let session = URLSession(configuration: .ephemeral,
            delegate: TestCertificateTrust(expected: try Data(contentsOf: files.certificateURL)), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        func request(_ path: String, password: String? = nil, token: String? = nil) async throws -> (Int, Data) {
            var request = URLRequest(url: URL(string: "https://127.0.0.1:\(config.port)/api/\(path)")!)
            request.timeoutInterval = 3
            if let password {
                request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(["password": password])
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await session.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, data)
        }
        var replacement: RemoteHostRuntime?
        do {
            XCTAssertEqual(runtime.service.status.pid, getpid(), "The service must run inside the owning app process")
            for route in ["i18n.js", "locales/zh-Hans.json"] {
                let url = URL(string: "https://127.0.0.1:\(config.port)/\(route)")!
                let (data, response) = try await session.data(from: url)
                XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
                if route.hasSuffix(".json") {
                    let catalog = try JSONDecoder().decode([String: String].self, from: data)
                    XCTAssertGreaterThan(catalog.count, 700)
                    XCTAssertNotNil(catalog["Connect"])
                } else {
                    XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("VelaI18n"))
                }
            }
            let duplicate = RemoteHostRuntime(files: files, addressProvider: { [] })
            XCTAssertThrowsError(try duplicate.start())
            await duplicate.stop()
            XCTAssertEqual(files.status()?.state, "listening", "An unsuccessful second instance must not overwrite live status")
            let login = try await request("login", password: "fixture-lifecycle-password")
            XCTAssertEqual(login.0, 200)
            let token = try XCTUnwrap(JSONDecoder().decode([String: String].self, from: login.1)["token"])
            await runtime.stop()
            await runtime.stop() // App termination callbacks may repeat.
            XCTAssertEqual(files.status()?.state, "stopped")
            XCTAssertEqual(try Data(contentsOf: files.configurationURL), saved)
            do { _ = try await request("authentication"); XCTFail("Listener survived app shutdown") } catch {}
            try await Task.sleep(for: .milliseconds(1100))
            XCTAssertEqual(files.status()?.state, "stopped", "Polling must not reopen the server after stop")
            let next = RemoteHostRuntime(files: files, addressProvider: { [] }); replacement = next
            try next.start(); try await waitUntilListening(next)
            let oldSession = try await request("poll", token: token)
            XCTAssertEqual(oldSession.0, 401)
            let newLogin = try await request("login", password: "fixture-lifecycle-password")
            XCTAssertEqual(newLogin.0, 200)
            await next.stop()
            // Terminating while startup has just been scheduled must not leak a listener or lock.
            let interrupted = RemoteHostRuntime(files: files, addressProvider: { [] }); replacement = interrupted
            try interrupted.start()
            await interrupted.stop()
            XCTAssertEqual(files.status()?.state, "stopped")
            let last = RemoteHostRuntime(files: files, addressProvider: { [] }); replacement = last
            try last.start(); try await waitUntilListening(last)
            await last.stop()
            XCTAssertEqual(try files.load(), config)
        } catch {
            await runtime.stop(); await replacement?.stop(); throw error
        }
    }

    func testWildcardBindingAcceptsRealTLSAndClosesListener() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vela-wildcard-\(UUID())")
        let files = RemoteFiles(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try RemoteCertificate.prepare(files: files, addresses: [])
        let server = RemoteHTTPS()
        let port = Int.random(in: 42000...58000)
        let session = URLSession(configuration: .ephemeral,
            delegate: TestCertificateTrust(expected: try Data(contentsOf: files.certificateURL)), delegateQueue: nil)
        do {
            try await server.start(addresses: [], port: port, files: files, bindAllInterfaces: true) { _ in .json(["ok": true]) }
            XCTAssertEqual(server.listeningAddresses, ["0.0.0.0"])
            let url = URL(string: "https://127.0.0.1:\(port)/")!
            let (_, response) = try await session.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            await server.stop()
            XCTAssertTrue(server.listeningAddresses.isEmpty)
            session.invalidateAndCancel()
        } catch { await server.stop(); session.invalidateAndCancel(); throw error }
    }

    func testErrorResponseIsJSON() throws {
        let response = RemoteResponse.error("Incorrect password", status: 401)
        XCTAssertEqual(response.status, 401)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: response.body)["error"], "Incorrect password")
    }

    @MainActor
    func testRealTLSLoginOriginChecksPasswordChangeAndShutdown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vela-https-test-\(UUID())")
        let files = RemoteFiles(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = RemoteConfiguration()
        configuration.port = Int.random(in: 42000...58000)
        configuration.password = try PasswordVerifier(password: "integration-test-password", iterations: 100_000)
        configuration.enabled = true
        try files.save(configuration)
        let host = RemoteHostService(files: files, addressProvider: { [] })
        await host.tick()
        XCTAssertEqual(host.status.state, "listening", host.status.message)
        guard host.status.state == "listening" else { await host.shutdown(); return }
        let delegate = TestCertificateTrust(expected: try Data(contentsOf: files.certificateURL))
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let base = URL(string: "https://127.0.0.1:\(configuration.port)")!
        func call(_ path: String, body: [String: String]? = nil, token: String? = nil, origin: String? = nil) async throws -> (Int, Data) {
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.timeoutInterval = 5
            if let body {
                request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
            let (data, response) = try await session.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, data)
        }
        do {
            let anonymous = try await call("api/poll")
            XCTAssertEqual(anonymous.0, 401)
            let crossOrigin = try await call("api/login", body: ["password": "integration-test-password"], origin: "https://evil.invalid")
            XCTAssertEqual(crossOrigin.0, 403)
            let wrong = try await call("api/login", body: ["password": "wrong"])
            XCTAssertEqual(wrong.0, 401)
            let throttled = try await call("api/login", body: ["password": "integration-test-password"])
            XCTAssertEqual(throttled.0, 429)
            try await Task.sleep(for: .milliseconds(1100))
            let valid = try await call("api/login", body: ["password": "integration-test-password"])
            XCTAssertEqual(valid.0, 200)
            let token = try XCTUnwrap(try JSONDecoder().decode([String: String].self, from: valid.1)["token"])
            let authenticated = try await call("api/poll", token: token)
            XCTAssertEqual(authenticated.0, 200)
            let page = try await call("")
            XCTAssertEqual(page.0, 200)
            XCTAssertTrue(String(decoding: page.1, as: UTF8.self).contains("Vela"))
            configuration.password = try PasswordVerifier(password: "updated-test-password", iterations: 100_000)
            configuration.generation = UUID().uuidString
            try files.save(configuration)
            await host.tick()
            let revoked = try await call("api/poll", token: token)
            XCTAssertEqual(revoked.0, 401)
            configuration.enabled = false; configuration.generation = UUID().uuidString
            try files.save(configuration); await host.tick()
            XCTAssertEqual(host.status.state, "stopped")
            do { _ = try await call("api/poll"); XCTFail("disabled host still accepts connections") }
            catch { /* The TCP listener must be gone, not only returning an error. */ }
            await host.shutdown(); session.invalidateAndCancel()
        } catch { await host.shutdown(); session.invalidateAndCancel(); throw error }
    }

    @MainActor
    func testSystemAuthenticationSwitchRevocationPolicyAndRestartOverTLS() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vela-auth-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = RemoteFiles(directory: directory)
        let backend = MockAccountDirectory()
        var config = RemoteConfiguration()
        config.port = Int.random(in: 42000...58000)
        config.password = try PasswordVerifier(password: "fixture-custom-password", iterations: 100_000)
        config.enabled = true
        try files.save(config)
        var host = RemoteHostService(files: files, addressProvider: { [] }, authenticator: RemoteAuthenticator(directory: backend))
        await host.tick()
        guard host.status.state == "listening" else { XCTFail(host.status.message); await host.shutdown(); return }
        let session = URLSession(configuration: .ephemeral, delegate: TestCertificateTrust(expected: try Data(contentsOf: files.certificateURL)), delegateQueue: nil)
        func call(_ path: String, body: [String: String]? = nil, token: String? = nil) async throws -> RemoteResponse {
            var request = URLRequest(url: URL(string: "https://127.0.0.1:\(config.port)/api/\(path)")!)
            request.timeoutInterval = 5
            if let body { request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await session.data(for: request)
            return RemoteResponse(status: (response as! HTTPURLResponse).statusCode, body: data)
        }
        func token(_ response: RemoteResponse) throws -> String {
            XCTAssertEqual(response.status, 200)
            return try XCTUnwrap(JSONDecoder().decode([String: String].self, from: response.body)["token"])
        }
        do {
            let customToken = try token(await call("login", body: ["password": "fixture-custom-password"]))
            try config.selectAuthentication(.macOSAccount, account: backend.identity)
            try files.save(config); await host.tick()
            XCTAssertEqual(host.status.state, "listening")
            let revoked = try await call("poll", token: customToken); XCTAssertEqual(revoked.status, 401)
            let metadata = try await call("authentication")
            let info = try JSONDecoder().decode([String: String].self, from: metadata.body)
            XCTAssertEqual(info["mode"], "macOSAccount"); XCTAssertEqual(info["account"], backend.identity.shortName)
            let stale = try await call("login", body: ["password": "fixture-custom-password", "mode": "customPassword"])
            XCTAssertEqual(stale.status, 409)
            let wrong = try await call("login", body: ["password": "wrong"]); XCTAssertEqual(wrong.status, 401)
            let calls = backend.calls
            let request = RemoteRequest(method: "POST", path: "/api/login", host: "127.0.0.1:\(config.port)", origin: nil,
                authorization: nil, contentType: "application/json", body: try JSONEncoder().encode(["password":"fixture-system-password"]), address: "another-ip")
            let throttled = await host.handle(request); XCTAssertEqual(throttled.status, 429); XCTAssertEqual(backend.calls, calls)
            try await Task.sleep(for: .milliseconds(1100))
            let systemToken = try token(await call("login", body: ["password": "fixture-system-password", "mode": "macOSAccount", "generation": config.generation]))
            let active = try await call("poll", token: systemToken); XCTAssertEqual(active.status, 200)
            backend.allowed = false
            await host.tick(); XCTAssertEqual(host.status.state, "error")
            XCTAssertFalse(host.status.message.contains("private-directory-detail"))
            do { _ = try await call("poll", token: systemToken); XCTFail("Disabled account must close listener") } catch {}
            backend.allowed = true
            await host.tick()
            let expired = try await call("poll", token: systemToken); XCTAssertEqual(expired.status, 401)
            await host.shutdown()
            host = RemoteHostService(files: files, addressProvider: { [] }, authenticator: RemoteAuthenticator(directory: backend))
            await host.tick()
            XCTAssertEqual(try files.load().authenticationMode, .macOSAccount)
            let restartedToken = try token(await call("login", body: ["password": "fixture-system-password"]))
            // Even a mode edit without generation rotation must revoke old tokens.
            config.authenticationMode = .customPassword; config.systemAccount = nil
            try files.save(config); await host.tick()
            let switched = try await call("poll", token: restartedToken); XCTAssertEqual(switched.status, 401)
            _ = try token(await call("login", body: ["password": "fixture-custom-password"]))
            // Corrupt/unknown modes must stop an already-running listener, never fall back.
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
            json["authenticationMode"] = "unknown"
            try JSONSerialization.data(withJSONObject: json).write(to: files.configurationURL)
            await host.tick(); XCTAssertEqual(host.status.state, "error")
            do { _ = try await call("poll"); XCTFail("Invalid mode must close listener") } catch {}
            await host.shutdown(); session.invalidateAndCancel()
        } catch { await host.shutdown(); session.invalidateAndCancel(); throw error }
    }

    @MainActor
    func testInFlightSystemLoginCannotSurviveConfigurationSwitch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vela-auth-race-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = RemoteFiles(directory: directory)
        let backend = MockAccountDirectory(); backend.blockVerification = true
        var config = RemoteConfiguration()
        try config.selectAuthentication(.macOSAccount, account: backend.identity)
        config.enabled = true; config.port = Int.random(in: 42000...58000)
        try files.save(config)
        let host = RemoteHostService(files: files, addressProvider: { [] }, authenticator: RemoteAuthenticator(directory: backend))
        await host.tick()
        guard host.status.state == "listening" else { XCTFail(host.status.message); await host.shutdown(); return }
        let request = RemoteRequest(method: "POST", path: "/api/login", host: "127.0.0.1:\(config.port)", origin: nil,
            authorization: nil, contentType: "application/json", body: try JSONEncoder().encode(["password":"fixture-system-password"]), address: "fixture")
        let pending = Task { await host.handle(request) }
        for _ in 0..<100 {
            if backend.calls > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(backend.calls, 1)
        config.enabled = false
        try files.save(config)
        // File changed while verification is in flight, before the periodic tick.
        backend.release.signal()
        let response = await pending.value
        XCTAssertEqual(response.status, 409)
        XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("token"))
        await host.tick(); XCTAssertEqual(host.status.state, "stopped")
        // Disable and restore an identical configuration while a second login is in flight.
        // A pre-restart authentication must not mint a token for the new listener.
        config.enabled = true; try files.save(config); await host.tick()
        let second = Task { await host.handle(request) }
        for _ in 0..<100 {
            if backend.calls > 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(backend.calls, 2)
        config.enabled = false; try files.save(config); await host.tick()
        config.enabled = true; try files.save(config); await host.tick()
        backend.release.signal()
        let afterRestart = await second.value
        XCTAssertEqual(afterRestart.status, 409)
        await host.shutdown()
    }

    @MainActor
    func testWebRTC4KVideoAndControlOverRealPeerConnection() async throws {
        let host = try RemotePeer(sendingVideo: true)
        let viewer = try RemotePeer(sendingVideo: false)
        defer { host.close(); viewer.close() }
        let receivedVideo = expectation(description: "decoded H264 frame")
        let receivedControl = expectation(description: "reliable input")
        let sink = FrameSink(expectation: receivedVideo)
        viewer.onVideo = { track in track.add(sink) }
        host.onInput = { data, pointer in
            if !pointer, let input = try? JSONDecoder().decode(RemoteInput.self, from: data), input.type == "release" {
                receivedControl.fulfill()
            }
        }
        let offer = try await viewer.makeOffer()
        let answer = try await host.answer(offer: offer)
        XCTAssertTrue(answer.contains("H264/90000"))
        try await viewer.accept(answer: answer)
        var hostIndex = 0, viewerIndex = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while ProcessInfo.processInfo.systemUptime < deadline {
            let hostCandidates = host.localCandidates, viewerCandidates = viewer.localCandidates
            for candidate in hostCandidates.dropFirst(hostIndex) { try await viewer.add(candidate) }
            for candidate in viewerCandidates.dropFirst(viewerIndex) { try await host.add(candidate) }
            hostIndex = hostCandidates.count; viewerIndex = viewerCandidates.count
            if host.connectionState == .connected && viewer.connectionState == .connected { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(host.connectionState, .connected)
        XCTAssertEqual(viewer.connectionState, .connected)
        let source = try XCTUnwrap(host.videoSource)
        source.adaptOutputFormat(toWidth: 3840, height: 2160, fps: 30)
        host.configureBitrate(maximum: DesktopQuality.native.bitrate, fps: 30)
        let capturer = RTCVideoCapturer(delegate: source)
        var buffer: CVPixelBuffer?
        // Retina-class resolution catches upstream's level-3.1 black-frame failure.
        let result = CVPixelBufferCreate(kCFAllocatorDefault, 3840, 2160, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        XCTAssertEqual(result, kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        if let address = CVPixelBufferGetBaseAddress(pixels) {
            memset(address, 100, CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for index in 0..<60 {
            let timestamp = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
            source.capturer(capturer, didCapture: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0, timeStampNs: timestamp))
            if index == 15 { viewer.sendInput(RemoteInput(type: "release")) }
            try await Task.sleep(for: .milliseconds(33))
        }
        await fulfillment(of: [receivedVideo, receivedControl], timeout: 8)
        XCTAssertGreaterThan(sink.frames, 0)
        XCTAssertEqual(sink.maximumWidth, 3840)
        XCTAssertEqual(sink.maximumHeight, 2160)
        let stats = await host.diagnostics()
        XCTAssertTrue(stats.contains { $0["encoderImplementation"] == "VideoToolbox" && $0["framesEncoded"] != "0" })
    }

    func testCaptureRespectsNegotiatedMacroblockAndRateLimits() {
        let conservative = H264CaptureLimit(level: 31).dimensions(width: 2056, height: 1329, quality: .native)
        let blocks = ((conservative.width + 15) / 16) * ((conservative.height + 15) / 16)
        XCTAssertLessThanOrEqual(blocks, 3600)
        XCTAssertLessThanOrEqual(blocks * conservative.fps, 108000)
        let desktop = H264CaptureLimit(level: 52).dimensions(width: 3840, height: 2160, quality: .native)
        XCTAssertEqual(desktop.width, 3840); XCTAssertEqual(desktop.height, 2160); XCTAssertEqual(desktop.fps, 30)
        let retina = H264CaptureLimit(level: 52).dimensions(width: 4112, height: 2658, quality: .native)
        XCTAssertGreaterThan(retina.width, 3000)
        XCTAssertEqual(retina.height, 2160)
        XCTAssertLessThanOrEqual(((retina.width + 15) / 16) * ((retina.height + 15) / 16), 36864)
    }

    @MainActor
    func testCaptureUsesRetinaBackingPixelsInsteadOfScaledDesktopSize() throws {
        let display = CGMainDisplayID()
        let mode = try XCTUnwrap(CGDisplayCopyDisplayMode(display))
        let size = DesktopCapture.pixelDimensions(displayID: display)
        XCTAssertEqual(size.width, mode.pixelWidth)
        XCTAssertEqual(size.height, mode.pixelHeight)
    }
}

final class TestCertificateTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    let expected: Data
    init(expected: Data) {
        let pem = String(decoding: expected, as: UTF8.self).components(separatedBy: .newlines).filter { !$0.hasPrefix("---") }.joined()
        self.expected = Data(base64Encoded: pem)!
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let certificate = chain.first,
              SecCertificateCopyData(certificate) as Data == expected else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
private final class FrameSink: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var width = 0, height = 0
    var maximumWidth: Int { lock.lock(); defer { lock.unlock() }; return width }
    var maximumHeight: Int { lock.lock(); defer { lock.unlock() }; return height }
    let expectation: XCTestExpectation
    init(expectation: XCTestExpectation) { self.expectation = expectation }
    var frames: Int { lock.lock(); defer { lock.unlock() }; return count }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock(); count += 1; width = max(width, Int(frame.width)); height = max(height, Int(frame.height)); let first = count == 1; lock.unlock()
        if first { expectation.fulfill() }
    }
}

private final class MockAccountDirectory: RemoteAccountDirectory, @unchecked Sendable {
    let identity = RemoteSystemAccount(uid: 501, generatedUID: UUID(), shortName: "fixture-owner")
    private let lock = NSLock()
    private var permitted = true
    private var count = 0
    var blockVerification = false
    let release = DispatchSemaphore(value: 0)
    var allowed: Bool { get { lock.withLock { permitted } } set { lock.withLock { permitted = newValue } } }
    var calls: Int { lock.withLock { count } }
    func currentAccount() throws -> RemoteSystemAccount { identity }
    func authenticationAllowed(for account: RemoteSystemAccount) throws {
        if !allowed { throw RemoteError.message("private-directory-detail") }
    }
    func verifyPassword(_ password: String, for account: RemoteSystemAccount) throws {
        lock.withLock { count += 1 }
        if blockVerification, release.wait(timeout: .now() + 5) == .timedOut { throw RemoteError.message("fixture timeout") }
        if password != "fixture-system-password" { throw RemoteError.message("private-directory-detail") }
    }
}
