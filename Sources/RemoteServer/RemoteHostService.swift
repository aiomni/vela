import AppKit
import ApplicationServices
import IOKit.ps
import IOKit.pwr_mgt
import RemoteCore
import RemoteRTC

@MainActor
public final class RemoteHostService {
    public let files: RemoteFiles
    public private(set) var status = RemoteHostStatus()
    private var configuration = RemoteConfiguration()
    private var loaded = false
    private var addresses: [String] = []
    private var addressChanges = RemoteAddressChangeTracker()
    private var observedAddresses: [String]?
    private var diagnosticEvents: [[String: String]] = []
    private var lastCaptureError: String?
    private var server: RemoteHTTPS?
    private var peer: RemotePeer?
    private let capture = DesktopCapture()
    private let blackout: PhysicalDisplayBlackout
    private var virtualDisplay: VirtualDisplay?
    private var preVirtualIdentity: DesktopDisplayIdentity?
    private var selectedQuality: DesktopQuality = .native
    private let losslessSender = DesktopLosslessSender()
    private var qualityController = DesktopQualityController()
    private var streamMetrics = DesktopStreamMetrics()
    private var streamDecision: DesktopStreamDecision?
    private var streamSample = DesktopStreamSample()
    private var lastStreamCodec: String?
    private var streamFeedback: RemoteStreamFeedback?
    private var feedbackReceivedAt = -Double.infinity
    private var lastQualityUpdate = -Double.infinity
    private var streamUpdateInFlight = false
    private let input = DesktopInput()
    private var sessions = SessionRegistry()
    private var rateLimiter = LoginRateLimiter()
    private var browserRateLimiter = LoginRateLimiter()
    private var rememberedSessions: [String: String] = [:]
    private var loginInFlight = 0
    private var authenticationEpoch = UUID()
    private let authenticator: RemoteAuthenticator
    private var operationInFlight = false
    private var controller: String?
    private var mediaID: String?
    private var lastHeartbeat: TimeInterval = 0
    private var lastDisconnected: TimeInterval?
    private var powerAssertion: IOPMAssertionID?
    private var consoleActivityAssertion: IOPMAssertionID?
    private var lastConsoleActivity: TimeInterval = -.infinity
    private var tickInFlight = false
    private var suspended = false
    private var desktopSession = DesktopSessionSnapshot.current()
    private var needsCaptureRebuild = false
    private var rebuildingCapture = false
    private var selectedIdentity: DesktopDisplayIdentity?
    private var selectedDisplayID: UInt32?
    private var lockDisplayIdentity: DesktopDisplayIdentity?
    private var sessionActive: Bool {
        desktopSession.available && desktopSession.loginDone && !desktopSession.locked &&
            desktopSession.onConsole
    }
    private var consoleAvailable: Bool {
        desktopSession.available && desktopSession.loginDone && desktopSession.onConsole
    }
    private var inputReady: Bool { consoleAvailable && !needsCaptureRebuild && !rebuildingCapture && !operationInFlight && !suspended }
    private let addressProvider: (@MainActor () -> [String])?
    public var onStatus: ((RemoteHostStatus) -> Void)?
    public init(files: RemoteFiles = RemoteFiles(), addressProvider: (@MainActor () -> [String])? = nil,
                authenticator: RemoteAuthenticator = RemoteAuthenticator()) {
        self.authenticator = authenticator
        self.files = files
        self.blackout = PhysicalDisplayBlackout(directory: files.directory.appendingPathComponent("display-recovery"))
        self.addressProvider = addressProvider
    }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    public func tick() async {
        guard !tickInFlight else { return }
        tickInFlight = true
        defer { tickInFlight = false }
        do {
            let next = try files.load()
            if next.enabled && next.authenticationMode == .macOSAccount {
                let authenticator = self.authenticator
                try await Task.detached { try authenticator.validate(next) }.value
            }
            let localAddresses = addressProvider?() ?? LocalNetwork.addresses(allInterfaces: next.listenOnAllInterfaces)
            if observedAddresses != localAddresses {
                observedAddresses = localAddresses
                record("network-observed", ["addresses": localAddresses.joined(separator: ","),
                                            "hasPeer": String(peer != nil)])
            }
            let rebind = addressChanges.shouldRebind(current: addresses, observed: localAddresses,
                                                     now: now, hasPeer: peer != nil)
            if !loaded || next.generation != configuration.generation || next.enabled != configuration.enabled ||
                next.port != configuration.port || next.password != configuration.password ||
                next.listenOnAllInterfaces != configuration.listenOnAllInterfaces ||
                next.authenticationMode != configuration.authenticationMode || next.systemAccount != configuration.systemAccount || rebind {
                loaded = true
                record("service-reconfigure", ["addressChange": String(rebind)])
                await shutdown()
                configuration = next
                addresses = localAddresses
                addressChanges.reset()
                if next.enabled { try await start() }
            }
            if next.disconnectGeneration != configuration.disconnectGeneration {
                configuration.disconnectGeneration = next.disconnectGeneration
                await disconnect()
                sessions.revokeAll()
                rememberedSessions.removeAll()
            }
            configuration.batteryFloor = next.batteryFloor
            status.screenPermission = CGPreflightScreenCaptureAccess()
            status.inputPermission = CGPreflightPostEventAccess()
            await refreshDesktopSession()
            if let reason = blackout.heartbeat() {
                record("physical-displays-restored", ["reason": reason])
                status.message = reason == "restore-failed" ? "Physical display restoration is incomplete. Retrying." : "Physical displays restored. Remote control can continue."
                if !blackout.isActive, peer != nil { needsCaptureRebuild = true }
            }
            if peer != nil {
                if !status.screenPermission || suspended || safetyReason() != nil {
                    await disconnect()
                    status.message = safetyReason() ?? "The desktop is unavailable or Screen Recording access was revoked. Connection ended."
                } else if now - lastHeartbeat > 35 {
                    await disconnect()
                    status.message = "Connection heartbeat timed out. All input has been released."
                } else if let token = controller, !sessions.validate(token, now: now, touch: false) {
                    await disconnect()
                    status.message = "The access session has expired. Enter the password again."
                } else {
                    await rebuildCaptureIfNeeded()
                    await updateStreamQuality()
                    input.enabled = status.inputPermission && inputReady && peer?.connectionState == .connected
                }
            }
            if let lastDisconnected, now - lastDisconnected >= 20 { releasePower(); self.lastDisconnected = nil }
            if peer == nil, consoleActivityAssertion != nil, now - lastConsoleActivity >= 10 { releaseConsoleActivity() }
            if safetyReason() != nil { releasePower() }
            sessions.expire(now: now)
            rememberedSessions = rememberedSessions.filter { sessions.validate($0.value, now: now, touch: false) }
        } catch {
            await shutdown()
            loaded = false
            status.state = "error"
            status.message = error.localizedDescription
        }
        publish()
    }

    private func start() async throws {
        try configuration.validate()
        try blackout.recoverPreviousSession()
        let files = self.files
        let addresses = self.addresses
        let fingerprint = try await Task.detached { try RemoteCertificate.prepare(files: files, addresses: addresses) }.value
        status.fingerprint = fingerprint
        let server = RemoteHTTPS()
        do {
            try await server.start(addresses: addresses, port: configuration.port, files: files,
                                   bindAllInterfaces: configuration.listenOnAllInterfaces && addressProvider == nil) { [weak self] request in
                guard let self else { return .error("Remote control is off.", status: 503) }
                return await self.handle(request)
            }
        } catch {
            throw RemoteError.message("Unable to start remote port \(configuration.port); it may be in use: \(error.localizedDescription)")
        }
        self.server = server
        status.state = "listening"
        status.message = configuration.listenOnAllInterfaces && addressProvider == nil
            ? "Waiting for a connection · Listening on 0.0.0.0 and [::]:\(configuration.port)"
            : (addresses.isEmpty ? "Waiting for a LAN connection; currently accessible only from this Mac." : "Waiting for a connection")
        status.addresses = (addresses.isEmpty ? ["127.0.0.1"] : addresses).map { "https://\(LocalNetwork.authority(address: $0, port: configuration.port))" }
    }
    public func shutdown() async {
        record("service-shutdown")
        authenticationEpoch = UUID()
        let oldServer = server; server = nil
        await disconnect()
        sessions.revokeAll()
        rememberedSessions.removeAll()
        releasePower(); lastDisconnected = nil
        await oldServer?.stop()
        status.state = "stopped"; status.message = "Remote control is off"; status.addresses = []
    }
    public func disconnect(preserveVirtualDisplay: Bool = false) async {
        if peer != nil { record("media-disconnect", ["preserveVirtual": String(preserveVirtualDisplay)]) }
        input.enabled = false
        controller = nil; mediaID = nil
        losslessSender.stop()
        qualityController.reset(); streamMetrics = DesktopStreamMetrics(); streamDecision = nil
        streamFeedback = nil; feedbackReceivedAt = -.infinity; lastQualityUpdate = -.infinity
        streamSample = DesktopStreamSample(); lastStreamCodec = nil
        let oldPeer = peer; peer = nil
        oldPeer?.close()
        let restored = await blackout.restore()
        await capture.stop()
        if !preserveVirtualDisplay && restored {
            virtualDisplay?.close(); virtualDisplay = nil; preVirtualIdentity = nil
        }
        selectedIdentity = nil; selectedDisplayID = nil; lockDisplayIdentity = nil; needsCaptureRebuild = false
        releaseConsoleActivity()
        if powerAssertion != nil { lastDisconnected = now }
        status.connected = false
        status.state = server == nil ? "stopped" : "listening"
        status.message = server == nil ? "Remote control is off" : "Waiting for a connection"
        publish()
    }
    public func suspend(_ suspend: Bool) async {
        suspended = suspend
        if suspend { await disconnect(); releasePower() }
    }
    public func setSessionActive(_ active: Bool) async {
        // Notifications can arrive before WindowServer finishes switching. Read
        // authoritative state here and again in tick, rather than trusting a hint.
        await refreshDesktopSession()
    }

    private func refreshDesktopSession() async {
        let current = DesktopSessionSnapshot.current()
        input.destination = current.locked ? .lockScreen : .desktop
        guard current != desktopSession else { return }
        desktopSession = current
        losslessSender.stop()
        streamFeedback = nil; feedbackReceivedAt = -.infinity; streamDecision = nil
        qualityController.reset(); streamMetrics = DesktopStreamMetrics()
        record("desktop-session", ["state": current.state, "onConsole": String(current.onConsole),
                                   "locked": String(current.locked)])
        input.enabled = false
        if blackout.isActive && (!current.onConsole || current.locked) { _ = await blackout.restore() }
        lockDisplayIdentity = current.locked && current.onConsole ? DesktopDisplayIdentity(displayID: CGMainDisplayID()) : nil
        if !current.locked { releaseConsoleActivity() }
        if peer != nil {
            needsCaptureRebuild = true
            if consoleAvailable && capture.isRunning {
                // An established SCK stream can continue across ordinary lock.
                // Discard its pre-transition cache before accepting new input.
                capture.beginSessionTransition()
            } else { await capture.stop() }
            status.message = current.locked ? "Mac is locked. Preparing the system lock screen…" :
                (!current.onConsole ? "The current user has left the local console. Return to this account on the host Mac." : "Restoring the session video…")
        }
        publish()
    }

    private func rebuildCaptureIfNeeded() async {
        guard needsCaptureRebuild, !rebuildingCapture, !operationInFlight, consoleAvailable,
              !suspended, let peer, let source = peer.videoSource,
              let identity = desktopSession.locked ? lockDisplayIdentity : selectedIdentity else { return }
        rebuildingCapture = true
        defer { rebuildingCapture = false }
        let expected = desktopSession
        do {
            await prepareConsoleCapture()
            let displays = DesktopCapture.displayMetadata()
            guard let id = identity.resolve(in: displays) else { throw RemoteError.message("The previous display is unavailable. Select another in the Display panel.") }
            guard self.peer === peer, consoleAvailable else { return }
            if !capture.isRunning || capture.displayID != id {
                try await capture.start(source: source, displayID: id, quality: selectedQuality, limit: peer.captureLimit)
            }
            try await capture.waitForFirstFrame()
            guard self.peer === peer, expected == DesktopSessionSnapshot.current(), consoleAvailable else { return }
            selectedDisplayID = id; input.displayID = id; needsCaptureRebuild = false
            lastCaptureError = nil
            record("capture-restored", ["displayID": String(id), "state": desktopSession.state])
            status.message = desktopSession.locked ? "Mac is locked. Enter the password in the system password field to unlock." :
                blackout.isActive ? "Remote control on the virtual display only; local input restores physical displays." : "Remote desktop connected"
        } catch {
            if self.peer === peer {
                await capture.stop()
                status.message = "Waiting for video recovery: \(error.localizedDescription)"
                if lastCaptureError != error.localizedDescription {
                    lastCaptureError = error.localizedDescription
                    record("capture-recovery-failed", ["message": error.localizedDescription])
                }
            }
        }
    }
    private func updateStreamQuality() async {
        guard !streamUpdateInFlight, now - lastQualityUpdate >= 0.9, !operationInFlight,
              !needsCaptureRebuild, !rebuildingCapture, consoleAvailable, !suspended,
              let peer, peer.connectionState == .connected, capture.baseDimensions != nil else { return }
        streamUpdateInFlight = true
        defer { streamUpdateInFlight = false }
        lastQualityUpdate = now
        let session = desktopSession
        let statistics = await peer.diagnostics()
        guard self.peer === peer, session == desktopSession, !operationInFlight, !needsCaptureRebuild else { return }
        if lastStreamCodec != peer.videoCodec {
            lastStreamCodec = peer.videoCodec
            capture.selectQuality(selectedQuality, limit: peer.captureLimit)
            qualityController.reset()
            if let preference = streamFeedback?.preference { qualityController.setPreference(preference) }
        }
        guard let base = capture.baseDimensions else { return }
        var sample = streamMetrics.sample(statistics)
        let feedback = now - feedbackReceivedAt <= 5 ? streamFeedback : nil
        sample.decodeMilliseconds = feedback?.decodeMilliseconds
        sample.droppedFrameRatio = feedback?.droppedFrameRatio
        streamSample = sample
        let diagnostics = capture.diagnostics
        let age = now - Double(diagnostics["lastContentChangeMilliseconds"] ?? 0) / 1000
        let next = qualityController.update(now: now, sample: sample, moving: age < 0.35,
            baseWidth: base.width, baseHeight: base.height, baseFPS: base.fps, maximumBitrate: selectedQuality.bitrate,
            viewportWidth: feedback?.viewportWidth, viewportHeight: feedback?.viewportHeight,
            refining: (0.35...1.35).contains(age))
        do {
            let bandwidth = sample.availableBitrate ?? 0
            let lossless = feedback?.lossless == true && peer.videoCodec == "H264" && sessionActive && peer.enhancementReady &&
                next.state != "limited" && bandwidth.isFinite && bandwidth >= 3_000_000
            try await capture.apply(next, lossless: lossless)
            guard self.peer === peer, session == desktopSession, session == DesktopSessionSnapshot.current() else { return }
            losslessSender.update(capture: capture, peer: peer, enabled: lossless,
                                  availableBitrate: sample.availableBitrate)
            peer.configureBitrate(maximum: next.maximumBitrate, fps: next.fps)
            streamDecision = next
        } catch {
            // A transient configuration failure must not disconnect a working controller.
            record("stream-configuration-failed")
        }
    }

    private func prepareConsoleCapture() async {
        guard consoleAvailable, peer != nil, !blackout.isActive,
              desktopSession.locked || CGDisplayIsAsleep(CGMainDisplayID()) != 0 || DesktopCapture.displayMetadata().isEmpty else { return }
        requestConsoleActivity()
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { try? await Task.sleep(for: .milliseconds(300)) }
    }
    private func requestConsoleActivity() {
        guard now - lastConsoleActivity >= 5 else { return }
        lastConsoleActivity = now
        var assertion = consoleActivityAssertion ?? 0
        if IOPMAssertionDeclareUserActivity("Vela: authenticated remote display access" as CFString,
                                           kIOPMUserActiveRemote, &assertion) == kIOReturnSuccess {
            consoleActivityAssertion = assertion
        }
    }
    private func releaseConsoleActivity() {
        if let consoleActivityAssertion { IOPMAssertionRelease(consoleActivityAssertion) }
        consoleActivityAssertion = nil; lastConsoleActivity = -.infinity
    }
    private func record(_ event: String, _ fields: [String: String] = [:]) {
        // Local bounded diagnostics: no request bodies, account names, passwords,
        // bearer tokens, key events, window titles or desktop content.
        var entry = fields
        entry["event"] = event; entry["time"] = ISO8601DateFormatter().string(from: Date())
        diagnosticEvents.append(entry)
        if diagnosticEvents.count > 80 { diagnosticEvents.removeFirst(diagnosticEvents.count - 80) }
        let url = files.directory.appendingPathComponent("session-events.json")
        if let data = try? JSONEncoder().encode(diagnosticEvents) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
    public func requestPermissions() {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
    }
    public func publish() {
        status.updated = Date(); status.pid = getpid()
        try? files.writeStatus(status)
        onStatus?(status)
    }
    private func safetyReason() -> String? {
        if ProcessInfo.processInfo.thermalState == .critical { return "System temperature is too high. Remote control paused." }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            if current * 100 / maximum <= configuration.batteryFloor { return "Battery is too low. Remote control paused." }
        }
        return nil
    }
    private func holdPower() throws {
        lastDisconnected = nil
        guard powerAssertion == nil else { return }
        var assertion = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Vela: active remote-control session" as CFString, &assertion)
        guard result == kIOReturnSuccess else { throw RemoteError.message("Unable to keep the system running for remote control.") }
        powerAssertion = assertion
    }
    private func releasePower() { if let powerAssertion { IOPMAssertionRelease(powerAssertion) }; powerAssertion = nil }

    private struct SessionInfo: Encodable {
        let state: String
        let recovering: Bool
        let requiresAccountVerification: Bool
        let lockScreenControl: Bool
        let canEnterPrivacy: Bool
        let canManageVirtualDisplay: Bool
        let displaySleepRequested: Bool
        let localWakePermission: Bool
    }
    private var sessionInfo: SessionInfo {
        let state = !desktopSession.available ? "unavailable" : desktopSession.locked ? "locked" :
            !desktopSession.onConsole ? "detached" : blackout.isActive ? "blackout" : "local"
        return SessionInfo(state: state, recovering: needsCaptureRebuild || rebuildingCapture || operationInFlight,
                           requiresAccountVerification: !consoleAvailable,
                           lockScreenControl: desktopSession.locked && inputReady,
                           canEnterPrivacy: PhysicalDisplayBlackout.isAvailable && sessionActive &&
                               virtualDisplay != nil && capture.displayID == virtualDisplay?.id,
                           canManageVirtualDisplay: VirtualDisplay.isAvailable && sessionActive && !blackout.isActive,
                           displaySleepRequested: blackout.isActive,
                           localWakePermission: PhysicalDisplayBlackout.canObserveLocalInput)
    }

    private func enterBlackout(_ request: RemoteRequest, token: String) async -> RemoteResponse {
        struct Payload: Decodable { let mediaID: String; let videoReady: Bool }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: request.body) else {
            return .error("Invalid physical display shutdown request.", status: 400)
        }
        guard controller == token, mediaID == payload.mediaID, let peer, peer.connectionState == .connected,
              let source = peer.videoSource else { return .error("Establish a remote connection first.", status: 409) }
        await refreshDesktopSession()
        guard !operationInFlight, !rebuildingCapture, !needsCaptureRebuild, !suspended, sessionActive,
              !blackout.isActive, let virtualDisplay, capture.displayID == virtualDisplay.id,
              payload.videoReady, (capture.diagnostics["submitted"] ?? 0) > 0 else {
            return .error("Create and select a virtual display in Display, then confirm the video works before turning off physical displays.", status: 409)
        }
        operationInFlight = true; input.enabled = false
        defer { operationInFlight = false }
        do {
            try holdPower()
            try await blackout.begin(virtualID: virtualDisplay.id)
            guard self.peer === peer, controller == token, sessions.validate(token, now: now, touch: false),
                  DesktopSessionSnapshot.current().onConsole, !DesktopSessionSnapshot.current().locked else {
                throw RemoteError.message("The connection or local session changed. Physical displays restored.")
            }
            needsCaptureRebuild = true
            try await capture.start(source: source, displayID: virtualDisplay.id, quality: selectedQuality, limit: peer.captureLimit)
            try await capture.waitForFirstFrame()
            guard self.peer === peer, blackout.isActive else { throw RemoteError.message("Physical displays restored.") }
            input.displayID = virtualDisplay.id; needsCaptureRebuild = false
            input.enabled = CGPreflightPostEventAccess() && peer.connectionState == .connected && sessionActive
            status.message = "Physical displays are off. Remote control continues on the virtual display; local input restores them."
            record("physical-displays-disabled", ["virtualID": String(virtualDisplay.id)])
            publish()
            return .json(["ok": true])
        } catch {
            _ = await blackout.restore()
            if self.peer === peer { needsCaptureRebuild = true }
            record("physical-blackout-failed", ["message": error.localizedDescription])
            return .error(error.localizedDescription, status: 409)
        }
    }

    public func handle(_ request: RemoteRequest) async -> RemoteResponse {
        guard configuration.enabled, server != nil else { return .error("Remote control is off.", status: 503) }
        guard LocalNetwork.allowsAuthority(request.host, addresses: addresses, port: configuration.port),
              request.origin == nil || request.origin == "https://\(request.host)" else {
            return .error("Invalid request origin.", status: 403)
        }
        if request.method == "GET", let asset = webAsset(request.path) { return asset }
        guard request.path.hasPrefix("/api/") else { return .error("Not found.", status: 404) }
        if request.method == "POST", !(request.contentType?.lowercased().hasPrefix("application/json") ?? false) {
            return .error("Requests must use JSON.", status: 415)
        }
        if request.path == "/api/authentication", request.method == "GET" {
            return .json(["mode": configuration.authenticationMode.rawValue,
                          "account": configuration.authenticationMode == .macOSAccount ? (configuration.systemAccount?.shortName ?? "") : "",
                          "generation": configuration.generation])
        }
        if request.path == "/api/login", request.method == "POST" { return await login(request) }
        if request.method == "POST", ["/api/device/resume", "/api/device/forget"].contains(request.path) {
            guard request.origin == "https://\(request.host)" else { return .error("Invalid request origin.", status: 403) }
            if request.path == "/api/device/resume" { return await resumeBrowser(request) }
            return await forgetBrowser(request)
        }
        guard let authorization = request.authorization, authorization.hasPrefix("Bearer ") else {
            return .error("Enter the access password.", status: 401)
        }
        let token = String(authorization.dropFirst(7))
        guard sessions.validate(token, now: now) else { return .error("Login expired. Enter the password again.", status: 401) }
        do {
            switch (request.method, request.path) {
            case ("GET", "/api/diagnostics"):
                guard controller == token, let peer else { return .error("No active connection.", status: 409) }
                let statistics = await peer.diagnostics()
                guard self.peer === peer, controller == token else { return .error("The connection is no longer valid.", status: 409) }
                return .json(statistics)
            case ("GET", "/api/stream-capabilities"):
                return .json(await DesktopHEVC.capability.value.diagnostics)
            case ("POST", "/api/stream-feedback"):
                struct Payload: Decodable { let mediaID: String; let feedback: RemoteStreamFeedback }
                let payload = try JSONDecoder().decode(Payload.self, from: request.body)
                guard controller == token, mediaID == payload.mediaID, peer != nil else {
                    return .error("The connection is no longer valid.", status: 409)
                }
                guard payload.feedback.isValid else { return .error("Invalid streaming feedback.", status: 400) }
                streamFeedback = payload.feedback; feedbackReceivedAt = now
                if let preference = payload.feedback.preference { qualityController.setPreference(preference) }
                return .json(["ok": true])
            case ("GET", "/api/displays"):
                guard CGPreflightScreenCaptureAccess() else { return .error("Grant Vela Screen Recording access on the host Mac. If already granted, quit and reopen Vela.", status: 403) }
                return .json(try await displaysForConnection(token: token))
            case ("GET", "/api/display-capabilities"):
                return .json(["virtualDisplay": VirtualDisplay.isAvailable,
                              "privateSession": false, "physicalBlackout": PhysicalDisplayBlackout.isAvailable])
            case ("POST", "/api/session/blackout"):
                return await enterBlackout(request, token: token)
            case ("POST", "/api/session/restore-displays"):
                struct Payload: Decodable { let mediaID: String }
                let payload = try JSONDecoder().decode(Payload.self, from: request.body)
                guard controller == token, mediaID == payload.mediaID else { return .error("The connection is no longer valid.", status: 409) }
                input.enabled = false
                guard await blackout.restore() else { return .error("Physical displays are not fully restored. The recovery process will keep trying.", status: 500) }
                needsCaptureRebuild = true
                record("physical-displays-restored", ["reason": "remote-request"])
                return .json(["ok": true])
            case ("POST", "/api/session/privacy"), ("POST", "/api/session/end-private"), ("POST", "/api/session/sleep-displays"):
                return .error("The old user-switching mode is disabled. Refresh the page and use Physical Displays.", status: 409)
            case ("POST", "/api/virtual-display"):
                return await configureVirtualDisplay(request.body, token: token)
            case ("POST", "/api/virtual-display/remove"):
                return await removeVirtualDisplay(request.body, token: token)
            case ("GET", "/api/poll"):
                struct Poll: Encodable {
                    let candidates: [RemoteICECandidate]; let mediaID: String?; let connected: Bool
                    let inputPermission: Bool; let message: String; let displayID: UInt32?
                    let capture: [String: Int]
                    let stream: DesktopStreamDecision?
                    let streamMetrics: DesktopStreamSample?
                    let videoCodec: String?
                    let input: [String: Int]
                    let session: SessionInfo
                    let displays: [RemoteDisplay]
                }
                if controller == token { lastHeartbeat = now }
                return .json(Poll(candidates: controller == token ? (peer?.localCandidates ?? []) : [],
                    mediaID: controller == token ? mediaID : nil, connected: status.connected,
                    inputPermission: CGPreflightPostEventAccess() && inputReady, message: status.message,
                    displayID: controller == token ? (capture.displayID ?? selectedDisplayID) : nil,
                    capture: controller == token ? capture.diagnostics : [:], stream: controller == token ? streamDecision : nil, streamMetrics: controller == token ? streamSample : nil, videoCodec: controller == token ? peer?.videoCodec : nil, input: controller == token ? input.diagnostics : [:],
                    session: sessionInfo, displays: describeDisplays(DesktopCapture.displayMetadata())))
            case ("POST", "/api/offer"):
                return await connect(request.body, token: token)
            case ("POST", "/api/candidate"):
                struct Payload: Decodable { let mediaID: String; let candidate: RemoteICECandidate }
                let payload = try JSONDecoder().decode(Payload.self, from: request.body)
                guard controller == token, mediaID == payload.mediaID, let peer else { return .error("The connection is no longer valid.", status: 409) }
                try await peer.add(payload.candidate)
                return .json(["ok": true])
            case ("POST", "/api/disconnect"):
                if controller == token { await disconnect() }
                return .json(["ok": true])
            case ("POST", "/api/logout"):
                sessions.revoke(token)
                if controller == token { await disconnect() }
                return .json(["ok": true])
            case ("POST", "/api/display"):
                struct Payload: Decodable { let displayID: UInt32; let quality: DesktopQuality; let mediaID: String }
                let payload = try JSONDecoder().decode(Payload.self, from: request.body)
                guard controller == token, mediaID == payload.mediaID, let peer, let source = peer.videoSource else {
                    return .error("The connection is no longer valid.", status: 409)
                }
                guard !operationInFlight, !rebuildingCapture, consoleAvailable, !blackout.isActive else { return .error("The session or display is switching. Try again shortly.", status: 409) }
                guard DesktopCapture.displayMetadata().contains(where: { $0.id == payload.displayID }) else { return .error("Displays changed. Refresh the list.", status: 409) }
                operationInFlight = true
                defer { operationInFlight = false }
                input.enabled = false
                needsCaptureRebuild = true
                if desktopSession.locked { lockDisplayIdentity = DesktopDisplayIdentity(displayID: payload.displayID) }
                else { selectedIdentity = DesktopDisplayIdentity(displayID: payload.displayID) }
                selectedDisplayID = payload.displayID; selectedQuality = payload.quality
                losslessSender.stop()
                qualityController.reset(); streamMetrics = DesktopStreamMetrics(); streamDecision = nil
                if let preference = streamFeedback?.preference { qualityController.setPreference(preference) }
                if capture.displayID == payload.displayID, capture.isRunning {
                    capture.selectQuality(payload.quality, limit: peer.captureLimit)
                    if let base = capture.baseDimensions {
                        let decision = qualityController.update(now: now, sample: DesktopStreamSample(), moving: true,
                            baseWidth: base.width, baseHeight: base.height, baseFPS: base.fps, maximumBitrate: payload.quality.bitrate)
                        try await capture.apply(decision)
                    }
                } else {
                    try await capture.start(source: source, displayID: payload.displayID, quality: payload.quality, limit: peer.captureLimit)
                }
                try await capture.waitForFirstFrame()
                guard self.peer === peer else { await capture.stop(); return .error("Connection ended.", status: 409) }
                input.displayID = payload.displayID
                needsCaptureRebuild = false
                input.enabled = CGPreflightPostEventAccess() && consoleAvailable
                peer.configureBitrate(maximum: payload.quality.bitrate, fps: payload.quality.fps)
                selectedQuality = payload.quality
                return .json(["ok": true])
            default: return .error("Endpoint not found.", status: 404)
            }
        } catch {
            return .error(error.localizedDescription, status: 400)
        }
    }

    private func login(_ request: RemoteRequest) async -> RemoteResponse {
        struct Credentials: Decodable { let password: String; let mode: String?; let generation: String?; let rememberDevice: Bool? }
        guard let credentials = try? JSONDecoder().decode(Credentials.self, from: request.body), credentials.password.utf8.count <= 1024 else {
            return .error("Invalid login request.", status: 400)
        }
        if credentials.rememberDevice == true, request.origin != "https://\(request.host)" {
            return .error("Invalid request origin.", status: 403)
        }
        // A system account has one failure budget across all source IPs; do not fan out guesses.
        let rateLimitKey = configuration.authenticationMode == .macOSAccount ? "system-account" : request.address
        let concurrencyLimit = configuration.authenticationMode == .macOSAccount ? 1 : 2
        guard loginInFlight < concurrencyLimit, rateLimiter.begin(address: rateLimitKey, now: now) else {
            return .error("Too many attempts. Try again later.", status: 429)
        }
        // New clients bind the form to the host-selected mode. Password-only legacy clients remain supported.
        guard credentials.mode == nil || credentials.mode == configuration.authenticationMode.rawValue,
              credentials.generation == nil || credentials.generation == configuration.generation else {
            return .error("Authentication method changed. Reconnect.", status: 409)
        }
        let snapshot = configuration
        let epoch = authenticationEpoch
        let authenticator = self.authenticator
        loginInFlight += 1
        let success = await Task.detached(priority: .userInitiated) { authenticator.verify(credentials.password, configuration: snapshot) }.value
        loginInFlight -= 1
        rateLimiter.finish(address: rateLimitKey, success: success, now: now)
        guard configuration.enabled, server != nil, configuration == snapshot, authenticationEpoch == epoch,
              (try? files.load()) == snapshot else {
            return .error("Configuration changed. Reconnect.", status: 409)
        }
        guard success else { return .error("Authentication failed. Check the password, host authentication method, and account status.", status: 401) }
        if credentials.rememberDevice != nil, let previous = browserCookie(request),
           let oldToken = rememberedSessions.removeValue(forKey: RemoteSecurity.hash(Data(previous.utf8))) {
            sessions.revoke(oldToken)
            if controller == oldToken { await disconnect() }
            guard configuration == snapshot, authenticationEpoch == epoch, (try? files.load()) == snapshot else {
                return .error("Configuration changed. Reconnect.", status: 409)
            }
        }
        let token: String
        do { token = try sessions.issue(now: now) }
        catch { return .error(error.localizedDescription, status: 429) }
        do {
            var response = RemoteResponse.json(BrowserLogin(token: token, remembered: credentials.rememberDevice))
            if let remember = credentials.rememberDevice {
                let previous = browserCookie(request)
                let store = RememberedBrowsers(files: files)
                if remember {
                    let secret = try store.issue(binding: browserBinding(), replacing: previous)
                    rememberedSessions[RemoteSecurity.hash(Data(secret.utf8))] = token
                    response.setCookie = RememberedBrowserCookie.set(secret, port: configuration.port)
                } else {
                    if let previous { try store.revoke(previous) }
                    response.setCookie = RememberedBrowserCookie.set(nil, port: configuration.port)
                }
            }
            return response
        } catch {
            sessions.revoke(token)
            return .error(error.localizedDescription, status: 503)
        }
    }

    private struct BrowserLogin: Encodable { let token: String; let remembered: Bool? }
    private func browserCookie(_ request: RemoteRequest) -> String? {
        RememberedBrowserCookie.read(request.cookie, port: configuration.port)
    }
    private func browserBinding() throws -> String {
        guard let fingerprint = status.fingerprint else { throw RemoteError.message("The host certificate is unavailable.") }
        return try RememberedBrowsers.binding(configuration: configuration, fingerprint: fingerprint)
    }
    private func expiredBrowser(_ message: String, status: Int = 401) -> RemoteResponse {
        var response = RemoteResponse.error(message, status: status)
        response.setCookie = RememberedBrowserCookie.set(nil, port: configuration.port)
        return response
    }
    private func resumeBrowser(_ request: RemoteRequest) async -> RemoteResponse {
        guard let secret = browserCookie(request) else { return expiredBrowser("Enter the access password.") }
        let concurrencyLimit = configuration.authenticationMode == .macOSAccount ? 1 : 2
        guard browserRateLimiter.begin(address: request.address, now: now), loginInFlight < concurrencyLimit else {
            return .error("Too many attempts. Try again later.", status: 429)
        }
        struct Payload: Decodable { let mode: String; let generation: String }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: request.body),
              payload.mode == configuration.authenticationMode.rawValue, payload.generation == configuration.generation else {
            return expiredBrowser("Authentication method changed. Reconnect.", status: 409)
        }
        let store = RememberedBrowsers(files: files), snapshot = configuration, epoch = authenticationEpoch
        do {
            guard try store.validate(secret, binding: browserBinding()) else {
                return expiredBrowser("Remembered browser access expired. Enter the password again.")
            }
            let authenticator = self.authenticator
            loginInFlight += 1
            let allowed = await Task.detached { (try? authenticator.validate(snapshot)) != nil }.value
            loginInFlight -= 1
            guard allowed, configuration.enabled, server != nil, configuration == snapshot,
                  authenticationEpoch == epoch, (try? files.load()) == snapshot,
                  try store.validate(secret, binding: browserBinding()) else {
                return expiredBrowser("Remembered browser access expired. Enter the password again.")
            }
            let key = RemoteSecurity.hash(Data(secret.utf8)), token: String
            if let cached = rememberedSessions[key], sessions.validate(cached, now: now) { token = cached }
            else {
                do { token = try sessions.issue(now: now) }
                catch { return .error(error.localizedDescription, status: 429) }
                rememberedSessions[key] = token
            }
            return .json(BrowserLogin(token: token, remembered: true))
        } catch { return expiredBrowser("Remembered browser data is unavailable.", status: 503) }
    }
    private func forgetBrowser(_ request: RemoteRequest) async -> RemoteResponse {
        do {
            if let secret = browserCookie(request) {
                try RememberedBrowsers(files: files).revoke(secret)
                if let token = rememberedSessions.removeValue(forKey: RemoteSecurity.hash(Data(secret.utf8))) {
                    sessions.revoke(token)
                    if controller == token { await disconnect() }
                }
            }
            var response = RemoteResponse.json(["ok": true])
            response.setCookie = RememberedBrowserCookie.set(nil, port: configuration.port)
            return response
        } catch { return .error("Remembered browser data is unavailable.", status: 503) }
    }

    private func connect(_ body: Data, token: String) async -> RemoteResponse {
        struct Offer: Decodable {
            let sdp: String; let displayID: UInt32; let quality: DesktopQuality
            let stream: RemoteStreamFeedback?; let hevc: Bool?
        }
        guard let offer = try? JSONDecoder().decode(Offer.self, from: body), offer.sdp.utf8.count <= 65536, offer.stream?.isValid != false else {
            return .error("Invalid connection request.", status: 400)
        }
        await refreshDesktopSession()
        guard !operationInFlight, !rebuildingCapture else { return .error("Another connection operation is in progress.", status: 409) }
        guard controller == nil || controller == token else { return .error("A controller is already connected. Disconnect it on the host Mac first.", status: 409) }
        guard !suspended, consoleAvailable, CGPreflightScreenCaptureAccess() else {
            return .error("Desktop unavailable. Check Screen Recording access, the lock screen, and the current user session on the host Mac.", status: 403)
        }
        if let reason = safetyReason() { return .error(reason, status: 503) }
        operationInFlight = true
        defer { operationInFlight = false }
        let generation = configuration.generation
        await disconnect(preserveVirtualDisplay: controller == token)
        do {
            guard DesktopCapture.displayMetadata().contains(where: { $0.id == offer.displayID }) else { throw RemoteError.message("Displays changed. Refresh the display list and reconnect.") }
            selectedIdentity = DesktopDisplayIdentity(displayID: offer.displayID)
            let targetID = desktopSession.locked ? CGMainDisplayID() : offer.displayID
            lockDisplayIdentity = desktopSession.locked ? DesktopDisplayIdentity(displayID: targetID) : nil
            selectedDisplayID = targetID; selectedQuality = offer.quality
            input.destination = desktopSession.locked ? .lockScreen : .desktop
            needsCaptureRebuild = true
            let codecCapability = await DesktopHEVC.capability.value
            guard sessions.validate(token, now: now), configuration.enabled else { throw RemoteError.message("Connection canceled.") }
            let peer = try RemotePeer(sendingVideo: true, allowHEVC: offer.hevc == true && codecCapability.available)
            streamFeedback = offer.stream; feedbackReceivedAt = now
            if let preference = offer.stream?.preference { qualityController.setPreference(preference) }
            capture.frameIdentity = peer.frameIdentity
            self.peer = peer; self.controller = token; self.mediaID = UUID().uuidString
            lastHeartbeat = now
            peer.onInput = { [weak self, weak peer] data, pointer in
                guard let self, let peer, self.peer === peer, self.controller == token,
                      self.sessions.validate(token, now: self.now, touch: false) else { return }
                guard self.inputReady, self.desktopSession == DesktopSessionSnapshot.current() else { self.input.enabled = false; return }
                self.input.receive(data, pointerChannel: pointer)
            }
            peer.onState = { [weak self, weak peer] state in
                guard let self, let peer, self.peer === peer else { return }
                self.record("peer-state", ["state": String(describing: state)])
                self.status.connected = state == .connected
                self.input.enabled = state == .connected && CGPreflightPostEventAccess() && self.inputReady
                self.status.state = state == .connected ? "connected" : "connecting"
                self.status.message = state == .connected ? (self.desktopSession.locked ? "Mac is locked. Connecting to the system lock screen." : "Remote desktop connected") : "Establishing a live connection"
                if state == .failed || state == .closed { Task { await self.disconnect() } }
                self.publish()
            }
            capture.onError = { [weak self, weak peer] message in
                Task { @MainActor in
                    guard let self, let peer, self.peer === peer else { return }
                    self.losslessSender.stop()
                    self.input.enabled = false; self.needsCaptureRebuild = true
                    self.status.message = "Video changed. Recovering: \(message)"; self.publish()
                }
            }
            let answer = try await peer.answer(offer: offer.sdp)
            guard self.peer === peer, let source = peer.videoSource else { throw RemoteError.message("Connection canceled.") }
            if consoleAvailable {
                await prepareConsoleCapture()
                do {
                    try await capture.start(source: source, displayID: targetID, quality: offer.quality, limit: peer.captureLimit)
                    try await capture.waitForFirstFrame()
                    needsCaptureRebuild = false
                } catch {
                    // Lock/display transitions can temporarily hide SCK's display
                    // list. Keep the authenticated peer and retry in tick.
                    if !desktopSession.locked { throw error }
                    await capture.stop()
                }
            }
            guard self.peer === peer, configuration.enabled, configuration.generation == generation,
                  !suspended, CGPreflightScreenCaptureAccess(), safetyReason() == nil,
                  sessions.validate(token, now: now) else {
                await disconnect(); return .error("Connection canceled.", status: 409)
            }
            input.displayID = targetID
            input.enabled = peer.connectionState == .connected && CGPreflightPostEventAccess() && inputReady
            peer.configureBitrate(maximum: offer.quality.bitrate, fps: offer.quality.fps)
            selectedQuality = offer.quality
            try holdPower()
            status.state = "connecting"; status.message = "Establishing a live connection"; publish()
            return .json(["sdp": answer, "mediaID": mediaID!])
        } catch {
            await disconnect()
            return .error("Unable to start the desktop: \(error.localizedDescription)", status: 500)
        }
    }

    private func availableDisplays() async throws -> [RemoteDisplay] {
        describeDisplays(DesktopCapture.displayMetadata())
    }

    private func displaysForConnection(token: String) async throws -> [RemoteDisplay] {
        await refreshDesktopSession()
        // This endpoint runs after authentication, but before the browser can
        // construct an offer. It must not require an already-established peer.
        // Never wake another user's session or the physical-blackout session.
        if blackout.isActive { return try await availableDisplays() }
        let generation = configuration.generation
        defer { if peer == nil && !sessions.validate(token, now: now, touch: false) { releaseConsoleActivity() } }
        let displays = try await RemoteDisplayDiscovery.discover(
            read: { DesktopCapture.displayMetadata() },
            needsPreparation: { $0.isEmpty || $0.contains { CGDisplayIsAsleep($0.id) != 0 } },
            prepare: {
                self.record("display-discovery-recovery", ["state": self.desktopSession.state])
                self.requestConsoleActivity()
            },
            mayContinue: {
                let current = DesktopSessionSnapshot.current()
                return self.configuration.enabled && self.configuration.generation == generation &&
                    !self.suspended && !self.blackout.isActive && current.available && current.loginDone && current.onConsole &&
                    (self.controller == nil || self.controller == token) &&
                    self.sessions.validate(token, now: self.now, touch: false) && CGPreflightScreenCaptureAccess()
            })
        return describeDisplays(displays)
    }

    private func describeDisplays(_ displays: [RemoteDisplay]) -> [RemoteDisplay] {
        displays.map { display in
            let isVirtual = display.id == virtualDisplay?.id
            let bounds = CGDisplayBounds(display.id)
            return RemoteDisplay(id: display.id, name: isVirtual ? "Vela Virtual Display" : display.name,
                                 width: display.width, height: display.height, isVirtual: isVirtual,
                                 logicalWidth: Int(bounds.width), logicalHeight: Int(bounds.height))
        }
    }

    private struct DisplayChange: Encodable {
        let displayID: UInt32
        let displays: [RemoteDisplay]
    }

    private func configureVirtualDisplay(_ body: Data, token: String) async -> RemoteResponse {
        struct Payload: Decodable { let mediaID: String; let configuration: VirtualDisplayConfiguration }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: body) else { return .error("Invalid virtual display settings.", status: 400) }
        do { try payload.configuration.validate() } catch { return .error(error.localizedDescription, status: 400) }
        guard controller == token, mediaID == payload.mediaID, let peer, let source = peer.videoSource else {
            return .error("Only the current controller can manage virtual displays.", status: 409)
        }
        guard !operationInFlight, !rebuildingCapture, sessionActive, desktopSession.onConsole, !suspended, !blackout.isActive else { return .error("Restore physical displays and unlock the host Mac before creating or changing a virtual display.", status: 409) }
        operationInFlight = true
        defer { operationInFlight = false }
        let originalDisplayID = capture.displayID
        let quality = selectedQuality
        let oldVirtual = virtualDisplay
        var candidate: VirtualDisplay?
        var captureChanged = false
        do {
            let display = try VirtualDisplay(configuration: payload.configuration); candidate = display
            try await display.prepare()
            guard self.peer === peer, controller == token, sessionActive, !suspended else { throw RemoteError.message("Connection ended.") }
            input.enabled = false; captureChanged = true
            try await capture.start(source: source, displayID: display.id, quality: quality, limit: peer.captureLimit)
            try await capture.waitForFirstFrame()
            let currentDisplays = try await DesktopCapture.displays()
            guard self.peer === peer, controller == token, sessionActive, !suspended else { throw RemoteError.message("Connection ended.") }
            // Do not destroy the old virtual screen until replacement capture is ready.
            if oldVirtual == nil { preVirtualIdentity = selectedIdentity }
            virtualDisplay = display; candidate = nil
            selectedIdentity = DesktopDisplayIdentity(displayID: display.id); selectedDisplayID = display.id; needsCaptureRebuild = false
            input.displayID = display.id
            input.enabled = CGPreflightPostEventAccess() && peer.connectionState == .connected
            oldVirtual?.close()
            return .json(DisplayChange(displayID: display.id,
                                       displays: describeDisplays(currentDisplays.filter { $0.id != oldVirtual?.id })))
        } catch {
            if captureChanged, self.peer === peer, let originalDisplayID, sessionActive, !suspended {
                do {
                    try await capture.start(source: source, displayID: originalDisplayID, quality: quality, limit: peer.captureLimit)
                    if self.peer === peer {
                        input.displayID = originalDisplayID
                        input.enabled = CGPreflightPostEventAccess() && peer.connectionState == .connected
                    }
                } catch { if self.peer === peer { await disconnect() } }
            }
            candidate?.close()
            return .error(error.localizedDescription, status: 500)
        }
    }

    private func removeVirtualDisplay(_ body: Data, token: String) async -> RemoteResponse {
        struct Payload: Decodable { let mediaID: String }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: body) else { return .error("Invalid request.", status: 400) }
        guard controller == token, mediaID == payload.mediaID, let peer, let source = peer.videoSource else {
            return .error("Only the current controller can manage virtual displays.", status: 409)
        }
        guard !operationInFlight, !rebuildingCapture, sessionActive, desktopSession.onConsole, !suspended, !blackout.isActive else { return .error("Restore physical displays and unlock the host Mac before closing a virtual display.", status: 409) }
        guard let virtualDisplay else { return .error("There is no Vela virtual display.", status: 409) }
        operationInFlight = true
        defer { operationInFlight = false }
        do {
            let remaining = try await availableDisplays().filter { $0.id != virtualDisplay.id }
            let previousID = preVirtualIdentity?.resolve(in: remaining)
            guard let fallback = remaining.first(where: { $0.id == capture.displayID }) ?? remaining.first(where: { $0.id == previousID }) ?? remaining.first(where: { $0.id == CGMainDisplayID() }) ?? remaining.first else {
                return .error("No display is available to restore. Connect or restore a physical display first.", status: 409)
            }
            guard self.peer === peer, sessionActive, !suspended else { throw RemoteError.message("Connection ended.") }
            input.enabled = false
            if capture.displayID == virtualDisplay.id {
                try await capture.start(source: source, displayID: fallback.id, quality: selectedQuality, limit: peer.captureLimit)
                try await capture.waitForFirstFrame()
            }
            guard self.peer === peer, sessionActive, !suspended else { throw RemoteError.message("Connection ended.") }
            input.displayID = fallback.id
            selectedIdentity = DesktopDisplayIdentity(displayID: fallback.id); selectedDisplayID = fallback.id; needsCaptureRebuild = false
            input.enabled = CGPreflightPostEventAccess() && peer.connectionState == .connected
            self.virtualDisplay = nil; preVirtualIdentity = nil; virtualDisplay.close()
            return .json(DisplayChange(displayID: fallback.id, displays: describeDisplays(remaining)))
        } catch {
            // Keep the virtual display alive if the replacement screen cannot be captured.
            if self.peer === peer, sessionActive, !suspended {
                try? await capture.start(source: source, displayID: virtualDisplay.id, quality: selectedQuality, limit: peer.captureLimit)
                if self.peer === peer {
                    input.displayID = virtualDisplay.id
                    input.enabled = CGPreflightPostEventAccess() && peer.connectionState == .connected && capture.displayID == virtualDisplay.id
                }
            }
            return .error(error.localizedDescription, status: 500)
        }
    }

    private func webAsset(_ path: String) -> RemoteResponse? {
        let name: String
        let mime: String
        switch path {
        case "/", "/index.html": name = "index.html"; mime = "text/html; charset=utf-8"
        case "/app.js": name = "app.js"; mime = "text/javascript; charset=utf-8"
        case "/frame-identity-worker.js": name = "frame-identity-worker.js"; mime = "text/javascript; charset=utf-8"
        case "/lossless.js": name = "lossless.js"; mime = "text/javascript; charset=utf-8"
        case "/client-core.js": name = "client-core.js"; mime = "text/javascript; charset=utf-8"
        case "/i18n.js": name = "i18n.js"; mime = "text/javascript; charset=utf-8"
        case "/locales/zh-Hans.json": name = "locales/zh-Hans.json"; mime = "application/json; charset=utf-8"
        case "/style.css": name = "style.css"; mime = "text/css; charset=utf-8"
        default: return nil
        }
        guard let directory = Bundle.module.url(forResource: "Web", withExtension: nil),
              let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return .init(body: data, contentType: mime)
    }
}
