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
    private var companionDisplays: [UInt32: VirtualDisplay] = [:]
    private var companionDisplayAssertion: IOPMAssertionID?
    private var companionBlackoutStarting = false
    private var companionDisplayRecovery: Task<Void, Never>?
    private var closeRemoteDisplayAfterCompanionBlackout = false
    public var companionBlackoutActive: Bool { !companionDisplays.isEmpty }
    private var canSelectDisplay: Bool {
        companionBlackoutActive ? blackout.isIsolated : !blackout.isActive && !companionBlackoutStarting
    }
    public var onCompanionBlackoutChange: ((Bool) -> Void)?
    private var virtualDisplay: VirtualDisplay?
    private var privacyDisplay: VirtualDisplay?
    private var privacyCaptureTarget: DesktopCapture.PreparedDisplay?
    private var retryPrivacyPreparationAt: TimeInterval = 0
    private var privacyIntent = RemotePrivacyIntent()
    private var privateOwner: String?
    private var privateReconnectDeadline: TimeInterval?
    private var privateRestorePending = false
    private var restoreDisplaySleep = false
    private var teardownInFlight = false
    private var connectionRevision = UUID()
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
    private var desktopSessionRevision = UUID()
    private var previewInFlight = false
    private var lastPreviewAt = -Double.infinity
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
    private var inputReady: Bool {
        consoleAvailable && peer != nil && capture.isRunning && !needsCaptureRebuild && !rebuildingCapture &&
            !operationInFlight && !teardownInFlight && !suspended &&
            (!companionBlackoutActive || blackout.isIsolated) &&
            (privateOwner == nil || (blackout.isIsolated && capture.displayID == privacyCaptureTarget?.id && CGPreflightPostEventAccess()))
    }
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
            await refreshDesktopSession()
            if let reason = await blackout.heartbeat() {
                record("physical-displays-restored", ["reason": reason])
                status.message = reason == "restore-failed" ? "Physical display restoration is incomplete. Retrying." : "Physical displays restored. Remote control can continue."
                if !blackout.isActive, peer != nil { needsCaptureRebuild = true }
                if !blackout.isActive, let owner = privateOwner {
                    // A client retry must not undo a local takeover or re-enter
                    // an isolation that the watchdog found unsafe.
                    sessions.revoke(owner)
                    restoreDisplaySleep = false
                    await disconnect()
                    status.message = "Physical displays restored. The private connection ended."
                }
            }
            if companionBlackoutActive, !blackout.isActive { await restoreCompanionBlackout() }
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
                                                     now: now, hasPeer: peer != nil || privateOwner != nil)
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
            configuration.privacyMode = next.privacyMode
            status.screenPermission = CGPreflightScreenCaptureAccess()
            status.inputPermission = CGPreflightPostEventAccess()
            await refreshDesktopSession()
            if privateOwner != nil && !blackout.isIsolated { releaseConsoleActivity() }
            if privateRestorePending || privateReconnectDeadline.map({ now >= $0 }) == true {
                await disconnect()
            } else if peer != nil || privateOwner != nil {
                if !status.screenPermission || suspended || safetyReason() != nil ||
                    (privateOwner != nil && (!status.inputPermission || !PhysicalDisplayBlackout.canObserveLocalInput)) {
                    await disconnect()
                    status.message = safetyReason() ?? "The desktop is unavailable or Screen Recording access was revoked. Connection ended."
                } else if peer != nil, now - lastHeartbeat > 35 {
                    if privateOwner != nil { await retainPrivateDisplayForReconnect() }
                    else { await disconnect() }
                    status.message = "Connection heartbeat timed out. All input has been released."
                } else if let token = controller, !sessions.validate(token, now: now, touch: false) {
                    await disconnect()
                    status.message = "The access session has expired. Enter the password again."
                } else {
                    if privateOwner != nil, let id = capture.displayID, CGDisplayIsAsleep(id) != 0 {
                        input.enabled = false
                        if !needsCaptureRebuild { capture.beginSessionTransition() }
                        needsCaptureRebuild = true
                    }
                    await rebuildCaptureIfNeeded()
                    await updateStreamQuality()
                    input.enabled = status.inputPermission && inputReady && peer?.connectionState == .connected
                }
            }
            await preparePrivacyDisplay()
            if let lastDisconnected, now - lastDisconnected >= 20 { releasePower(); self.lastDisconnected = nil }
            if peer == nil, consoleActivityAssertion != nil, now - lastConsoleActivity >= 10 { releaseConsoleActivity() }
            if safetyReason() != nil { releasePower() }
            sessions.expire(now: now)
            var activeSessions = sessions
            let expirationTime = now
            privacyIntent.expire { activeSessions.validate($0, now: expirationTime, touch: false) }
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
        if !companionBlackoutActive && !companionBlackoutStarting {
            guard !blackout.isActive else { throw RemoteError.message("Physical display restoration is incomplete. Retrying.") }
            try await blackout.recoverPreviousSession()
        }
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
    public func shutdown(restoreCompanion: Bool = false) async {
        record("service-shutdown")
        authenticationEpoch = UUID()
        let oldServer = server; server = nil
        await disconnect()
        if restoreCompanion { await restoreCompanionBlackout() }
        if !blackout.isActive { discardPrivacyDisplay() }
        sessions.revokeAll()
        privacyIntent = RemotePrivacyIntent()
        rememberedSessions.removeAll()
        releasePower(); lastDisconnected = nil
        await oldServer?.stop()
        status.state = "stopped"; status.message = "Remote control is off"; status.addresses = []
    }
    public func disconnect() async {
        connectionRevision = UUID()
        guard !teardownInFlight else { return }
        teardownInFlight = true
        defer { teardownInFlight = false }
        if peer != nil { record("media-disconnect") }
        controller = nil; privacyIntent.endConnection(); privateReconnectDeadline = nil
        await stopMedia()
        releaseConsoleActivity()
        if privateOwner != nil && blackout.isActive && consoleAvailable {
            do { try await DesktopSession.ensureLocked() }
            catch {
                privateRestorePending = true
                status.message = "macOS did not confirm the lock. Physical displays remain off."
                publish()
                return
            }
        }
        let restored = if companionBlackoutActive || companionBlackoutStarting { true } else { await blackout.restore() }
        privateRestorePending = privateOwner != nil && !restored
        if restored {
            if privateOwner != nil && restoreDisplaySleep && DesktopSessionSnapshot.current().locked {
                try? await DesktopSession.sleepPhysicalDisplays()
            }
            privateOwner = nil; restoreDisplaySleep = false
        }
        if restored {
            if companionBlackoutActive || companionBlackoutStarting {
                closeRemoteDisplayAfterCompanionBlackout = virtualDisplay != nil
            } else {
                closeRemoteVirtualDisplay()
            }
        }
        if powerAssertion != nil { lastDisconnected = now }
        status.state = server == nil ? "stopped" : "listening"
        status.message = !restored ? "Physical display restoration is incomplete. Retrying." :
            server == nil ? "Remote control is off" : "Waiting for a connection"
        publish()
    }

    private func stopMedia() async {
        input.enabled = false; mediaID = nil
        losslessSender.stop()
        qualityController.reset(); streamMetrics = DesktopStreamMetrics(); streamDecision = nil
        streamFeedback = nil; feedbackReceivedAt = -.infinity; lastQualityUpdate = -.infinity
        streamSample = DesktopStreamSample(); lastStreamCodec = nil
        let oldPeer = peer; peer = nil
        oldPeer?.close()
        await capture.stop()
        selectedIdentity = nil; selectedDisplayID = nil; lockDisplayIdentity = nil; needsCaptureRebuild = false
        status.connected = false
    }

    private func retainPrivateDisplayForReconnect() async {
        guard privateOwner != nil, !teardownInFlight, !privateRestorePending, !operationInFlight else { return }
        privateReconnectDeadline = privateReconnectDeadline ?? now + 30
        operationInFlight = true
        defer { operationInFlight = false }
        await stopMedia()
        status.state = "connecting"
        status.message = "Waiting for the private connection to resume…"
        publish()
    }
    public func suspend(_ suspend: Bool) async {
        suspended = suspend
        if suspend {
            await restoreCompanionBlackout()
            await disconnect()
            releasePower()
        }
    }
    public func setSessionActive(_ active: Bool) async {
        // Notifications can arrive before WindowServer finishes switching. Read
        // authoritative state here and again in tick, rather than trusting a hint.
        await refreshDesktopSession()
    }

    func recoverDisplayLayoutAfterLaunch() async {
        guard !operationInFlight, !blackout.isActive else { return }
        operationInFlight = true
        defer { operationInFlight = false }
        try? await blackout.recoverPreviousSession(allowLock: false)
    }

    private func closeRemoteVirtualDisplay() {
        virtualDisplay?.close()
        virtualDisplay = nil
        preVirtualIdentity = nil
        closeRemoteDisplayAfterCompanionBlackout = false
    }

    private func refreshDesktopSession() async {
        let current = DesktopSessionSnapshot.current()
        input.destination = current.locked ? .lockScreen : .desktop
        guard current != desktopSession else { return }
        desktopSession = current
        desktopSessionRevision = UUID()
        losslessSender.stop()
        streamFeedback = nil; feedbackReceivedAt = -.infinity; streamDecision = nil
        qualityController.reset(); streamMetrics = DesktopStreamMetrics()
        record("desktop-session", ["state": current.state, "onConsole": String(current.onConsole),
                                   "locked": String(current.locked)])
        input.enabled = false
        if privateOwner != nil, !consoleAvailable {
            await disconnect()
            return
        }
        if privateOwner == nil && blackout.isActive && (!current.onConsole || current.locked) {
            if companionBlackoutActive { await restoreCompanionBlackout() }
            else { _ = await blackout.restore() }
        }
        let lockTarget = privateOwner != nil ? privacyDisplay?.id : CGMainDisplayID()
        lockDisplayIdentity = current.locked && current.onConsole ? lockTarget.map { DesktopDisplayIdentity(displayID: $0) } : nil
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
              !companionBlackoutActive || blackout.isIsolated,
              !suspended, let peer, let source = peer.videoSource,
              let identity = desktopSession.locked ? lockDisplayIdentity : selectedIdentity else { return }
        rebuildingCapture = true
        defer { rebuildingCapture = false }
        let expected = desktopSession
        do {
            try await prepareConsoleCapture()
            let displays = DesktopCapture.displayMetadata()
            guard let id = identity.resolve(in: displays) else { throw RemoteError.message("The previous display is unavailable. Select another in the Display panel.") }
            guard self.peer === peer, consoleAvailable else { return }
            if !capture.isRunning || capture.displayID != id {
                try await capture.start(source: source, displayID: id, quality: selectedQuality, limit: peer.captureLimit,
                                        prepared: privateOwner == nil ? nil : privacyCaptureTarget)
            }
            try await capture.waitForFirstFrame()
            guard self.peer === peer, expected == DesktopSessionSnapshot.current(), consoleAvailable,
                  companionDisplayRecovery == nil,
                  !companionBlackoutActive || blackout.isIsolated,
                  privateOwner == nil || blackout.isIsolated else { return }
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

    private func prepareConsoleCapture(connectingToken: String? = nil) async throws {
        guard consoleAvailable, peer != nil else { return }
        if privateOwner != nil {
            guard blackout.isIsolated, let display = privacyDisplay else {
                throw RemoteError.message("The private display could not be isolated.")
            }
            // The remote activity assertion is system-wide. Only use it once
            // WindowServer reports that the virtual display is the sole output.
            if CGDisplayIsAsleep(display.id) != 0 {
                requestConsoleActivity()
                try await Task.sleep(for: .milliseconds(300))
            }
            guard blackout.isIsolated else { throw RemoteError.message("The private display could not be isolated.") }
            return
        }
        if let connectingToken, try requiresPrivateConnection(token: connectingToken, mode: files.load().privacyMode) {
            throw RemoteError.message("The host now requires a private display. Reconnect to continue.")
        }
        guard !blackout.isActive,
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

    public func beginCompanionBlackout() async throws {
        guard PhysicalDisplayBlackout.isAvailable, VirtualDisplay.isAvailable else {
            throw RemoteError.message("This system does not support disabling physical displays.")
        }
        guard !operationInFlight, !rebuildingCapture, !teardownInFlight, companionDisplayRecovery == nil,
              !blackout.isActive, !companionBlackoutActive, privateOwner == nil else {
            throw RemoteError.message("The session or display is switching. Try again shortly.")
        }
        guard PhysicalDisplayBlackout.canObserveLocalInput else {
            throw RemoteError.message("Grant Vela Input Monitoring access in System Settings so local input can restore physical displays.")
        }
        operationInFlight = true
        companionBlackoutStarting = true
        defer {
            companionBlackoutStarting = false
            operationInFlight = false
        }
        let mayCommit = {
            let current = DesktopSessionSnapshot.current()
            return !Task.isCancelled && !self.suspended && current.available &&
                current.loginDone && current.onConsole && !current.locked
        }
        var replacements: [UInt32: VirtualDisplay] = [:]
        do {
            guard mayCommit() else {
                throw RemoteError.message("The current user session or virtual display is unavailable.")
            }
            // A previous private recovery may have to lock the console. Leave
            // that to its existing recovery path before starting a local action.
            try await blackout.recoverPreviousSession(allowLock: false)
            let snapshot = try PhysicalDisplaySnapshot()
            for (id, configuration) in snapshot.configurations.sorted(by: { $0.key < $1.key }) {
                guard mayCommit() else { throw RemoteError.message("Virtual display creation canceled.") }
                let display = try VirtualDisplay(configuration: configuration)
                try await display.prepare(mayConfigure: mayCommit)
                replacements[id] = display
            }
            var assertion = IOPMAssertionID(0)
            guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "Vela: virtual-only desktop" as CFString,
                &assertion) == kIOReturnSuccess else {
                throw RemoteError.message("Unable to keep the virtual desktop awake.")
            }
            companionDisplayAssertion = assertion
            input.enabled = false
            losslessSender.stop()
            capture.beginSessionTransition()
            try await blackout.begin(snapshot: snapshot, replacements: replacements.mapValues(\.id), mayCommit: mayCommit)
        } catch {
            if blackout.isActive {
                companionDisplays = replacements
                onCompanionBlackoutChange?(true)
            } else {
                for display in replacements.values { display.close() }
                if closeRemoteDisplayAfterCompanionBlackout { closeRemoteVirtualDisplay() }
                releaseCompanionDisplayAssertion()
            }
            if peer != nil { needsCaptureRebuild = true }
            throw error
        }
        companionDisplays = replacements
        if peer != nil {
            let id = (capture.displayID ?? selectedDisplayID).flatMap { replacements[$0]?.id }
                ?? (selectedDisplayID.flatMap { CGDisplayIsOnline($0) != 0 ? $0 : nil }) ?? CGMainDisplayID()
            retargetCompanionCapture(to: id)
        }
        if !mayCommit() { await restoreCompanionBlackout(); return }
        status.message = "Physical displays are off. Local input restores them."
        onCompanionBlackoutChange?(true)
        publish()
    }

    private func releaseCompanionDisplayAssertion() {
        if let companionDisplayAssertion { IOPMAssertionRelease(companionDisplayAssertion) }
        companionDisplayAssertion = nil
    }

    private func retargetCompanionCapture(to id: UInt32) {
        input.enabled = false
        losslessSender.stop()
        capture.beginSessionTransition()
        selectedDisplayID = id
        selectedIdentity = DesktopDisplayIdentity(displayID: id)
        needsCaptureRebuild = true
    }

    private func restoreCompanionBlackout() async {
        if let companionDisplayRecovery { await companionDisplayRecovery.value; return }
        guard companionBlackoutActive else { return }
        input.enabled = false
        losslessSender.stop()
        let recovery = Task {
            if await blackout.restore() {
                await finishCompanionBlackout()
                status.message = "Physical displays restored. Remote control can continue."
                publish()
            }
        }
        companionDisplayRecovery = recovery
        await recovery.value
        companionDisplayRecovery = nil
    }

    private func finishCompanionBlackout() async {
        guard companionBlackoutActive else { return }
        while rebuildingCapture {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let selection = selectedDisplayID ?? capture.displayID
        let physical = companionDisplays.first { $0.value.id == selection || $0.value.currentSystemID == selection }?.key
        if peer != nil {
            let retiringRemote = closeRemoteDisplayAfterCompanionBlackout ? virtualDisplay?.id : nil
            let candidates = [physical, selection, CGMainDisplayID()].compactMap { $0 }
                + DesktopCapture.displayMetadata().map(\.id)
            let target = candidates.first {
                $0 != retiringRemote && $0 != privacyDisplay?.id &&
                    CGDisplayIsOnline($0) != 0 && CGDisplayIsActive($0) != 0
            } ?? CGMainDisplayID()
            retargetCompanionCapture(to: target)
            await capture.stop()
        }
        for display in companionDisplays.values { display.close() }
        companionDisplays.removeAll()
        if closeRemoteDisplayAfterCompanionBlackout { closeRemoteVirtualDisplay() }
        releaseCompanionDisplayAssertion()
        onCompanionBlackoutChange?(false)
    }

    private var physicalDisplaysAsleep: Bool {
        PhysicalDisplayBlackout.physicalDisplaysAreAsleep(excluding: Set([virtualDisplay?.id, privacyDisplay?.id].compactMap { $0 }))
    }

    private var automaticPrivacySupported: Bool {
        VirtualDisplay.isAvailable && PhysicalDisplayBlackout.isAvailable && DesktopSession.canLock
    }

    private func preparePrivacyDisplay() async {
        guard configuration.enabled, configuration.privacyMode != .off else {
            status.privacyReadiness = nil
            if privateOwner == nil && !operationInFlight && !teardownInFlight && !blackout.isActive {
                discardPrivacyDisplay()
            }
            return
        }
        guard automaticPrivacySupported else { status.privacyReadiness = "unsupported"; return }
        guard status.screenPermission, status.inputPermission, PhysicalDisplayBlackout.canObserveLocalInput else {
            status.privacyReadiness = "permissions"
            return
        }
        if let privacyDisplay, CGDisplayIsOnline(privacyDisplay.id) == 1, privacyDisplay.id == privacyCaptureTarget?.id {
            status.privacyReadiness = "prepared"
            return
        }
        if now < retryPrivacyPreparationAt { return }
        status.privacyReadiness = "waiting"
        guard sessionActive, !physicalDisplaysAsleep, !suspended, peer == nil, privateOwner == nil,
              !operationInFlight, !teardownInFlight, !blackout.isActive else { return }
        operationInFlight = true
        defer { operationInFlight = false }
        let revision = connectionRevision
        do {
            let display = try VirtualDisplay(configuration: .init(width: 2560, height: 1440, hiDPI: true))
            let mayConfigure = {
                let current = DesktopSessionSnapshot.current()
                let virtualIDs = Set([display.id, self.privacyDisplay?.id, self.virtualDisplay?.id].compactMap { $0 })
                return revision == self.connectionRevision && !self.suspended && current.available && current.loginDone &&
                    current.onConsole && !current.locked &&
                    !PhysicalDisplayBlackout.physicalDisplaysAreAsleep(excluding: virtualIDs)
            }
            try await display.prepare(mayConfigure: mayConfigure)
            let target = try await DesktopCapture.prepareDisplay(display.id)
            guard mayConfigure() else { return }
            discardPrivacyDisplay()
            privacyDisplay = display
            privacyCaptureTarget = target
            status.privacyReadiness = "prepared"
        } catch {
            status.privacyReadiness = "failed"
            retryPrivacyPreparationAt = now + 10
        }
    }

    private func discardPrivacyDisplay() {
        privacyCaptureTarget = nil
        privacyDisplay?.close(); privacyDisplay = nil
    }

    private func requiresPrivateConnection(token: String, mode: RemotePrivacyMode) -> Bool {
        if privateOwner == token { return true }
        let current = DesktopSessionSnapshot.current()
        return privacyIntent.requiresIsolation(token: token, mode: mode, locked: current.locked,
                                               physicalDisplaysAsleep: mode == .lockedOrAsleep && physicalDisplaysAsleep)
    }

    private func preparedPrivacyDisplay() throws -> VirtualDisplay {
        guard automaticPrivacySupported, PhysicalDisplayBlackout.canObserveLocalInput, CGPreflightPostEventAccess() else {
            throw RemoteError.message("Private connection requires compatible displays, Input Monitoring, and remote input access on the host Mac.")
        }
        guard let privacyDisplay, CGDisplayIsOnline(privacyDisplay.id) == 1, privacyDisplay.id == privacyCaptureTarget?.id else {
            throw RemoteError.message("Private display is not ready. Unlock the host Mac locally and wait for Vela to prepare it.")
        }
        return privacyDisplay
    }

    private struct SessionInfo: Encodable {
        let state: String
        let recovering: Bool
        let requiresAccountVerification: Bool
        let lockScreenControl: Bool
        let canEnterPrivacy: Bool
        let canManageVirtualDisplay: Bool
        let displaySleepRequested: Bool
        let localWakePermission: Bool
        let automaticPrivacy: Bool
        let companionBlackout: Bool
    }
    private var sessionInfo: SessionInfo {
        let state = !desktopSession.available ? "unavailable" : desktopSession.locked ? "locked" :
            !desktopSession.onConsole ? "detached" : blackout.isActive || companionBlackoutActive ? "blackout" : "local"
        return SessionInfo(state: state, recovering: needsCaptureRebuild || rebuildingCapture || operationInFlight || teardownInFlight ||
                               (privateOwner != nil && (peer == nil || !blackout.isIsolated)) ||
                               (companionBlackoutActive && !blackout.isIsolated),
                           requiresAccountVerification: !consoleAvailable,
                           lockScreenControl: desktopSession.locked && inputReady,
                           canEnterPrivacy: PhysicalDisplayBlackout.isAvailable && sessionActive && !blackout.isActive && !companionBlackoutActive &&
                               virtualDisplay != nil && capture.displayID == virtualDisplay?.id,
                           canManageVirtualDisplay: VirtualDisplay.isAvailable && sessionActive && !blackout.isActive && !companionBlackoutActive && privateOwner == nil,
                           displaySleepRequested: blackout.isActive || companionBlackoutActive,
                           localWakePermission: PhysicalDisplayBlackout.canObserveLocalInput,
                           automaticPrivacy: privateOwner != nil, companionBlackout: companionBlackoutActive)
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
            try await blackout.begin(virtualID: virtualDisplay.id, mayCommit: {
                self.peer === peer && self.controller == token && self.sessions.validate(token, now: self.now, touch: false) &&
                    !self.suspended && !self.teardownInFlight
            })
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

    private func restoreDisplays(token: String, mediaID: String, showDesktop: Bool) async -> RemoteResponse {
        guard controller == token, self.mediaID == mediaID, let peer else {
            return .error("The connection is no longer valid.", status: 409)
        }
        guard !operationInFlight, !rebuildingCapture, !teardownInFlight, blackout.isActive else {
            return .error("The session or display is switching. Try again shortly.", status: 409)
        }
        if companionBlackoutActive {
            return .error("Use the host Mac’s keyboard, mouse, or trackpad to restore physical displays.", status: 409)
        }
        operationInFlight = true; input.enabled = false
        defer { operationInFlight = false }
        let automatic = privateOwner == token
        do {
            if automatic && !showDesktop { try await DesktopSession.ensureLocked() }
            let current = DesktopSessionSnapshot.current()
            guard self.peer === peer, controller == token, sessions.validate(token, now: now, touch: false),
                  !teardownInFlight, current.onConsole, !automatic || showDesktop || current.locked else {
                throw RemoteError.message("The connection is no longer valid.")
            }
            releaseConsoleActivity()
            guard await blackout.restore(showDesktop: automatic && showDesktop) else {
                throw RemoteError.message("Physical displays are not fully restored. The recovery process will keep trying.")
            }
            guard self.peer === peer, controller == token, !teardownInFlight else {
                throw RemoteError.message("The connection is no longer valid.")
            }
            if automatic {
                privateOwner = nil; privateReconnectDeadline = nil; restoreDisplaySleep = false
                privacyIntent.allowPhysicalDisplays(for: token)
                let target = DesktopDisplayIdentity(displayID: CGMainDisplayID())
                selectedIdentity = target; lockDisplayIdentity = target
            }
            needsCaptureRebuild = true
            record("physical-displays-restored", ["reason": "remote-request"])
            return .json(["ok": true])
        } catch {
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
            case ("POST", "/api/display-preview"):
                return await previewDisplay(request.body, token: token)
            case ("GET", "/api/display-capabilities"):
                return .json(["virtualDisplay": VirtualDisplay.isAvailable,
                              "privateSession": false, "physicalBlackout": PhysicalDisplayBlackout.isAvailable])
            case ("POST", "/api/session/blackout"):
                return await enterBlackout(request, token: token)
            case ("POST", "/api/session/restore-displays"):
                struct Payload: Decodable { let mediaID: String; let showDesktop: Bool? }
                let payload = try JSONDecoder().decode(Payload.self, from: request.body)
                return await restoreDisplays(token: token, mediaID: payload.mediaID, showDesktop: payload.showDesktop == true)
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
                    session: sessionInfo, displays: currentDisplays()))
            case ("POST", "/api/offer"):
                return await connect(request.body, token: token)
            case ("POST", "/api/candidate"):
                struct Payload: Decodable { let mediaID: String; let candidate: RemoteICECandidate }
                let payload = try JSONDecoder().decode(Payload.self, from: request.body)
                guard controller == token, mediaID == payload.mediaID, let peer else { return .error("The connection is no longer valid.", status: 409) }
                try await peer.add(payload.candidate)
                return .json(["ok": true])
            case ("POST", "/api/disconnect"):
                if controller == token || privateOwner == token { await disconnect() }
                return .json(["ok": true])
            case ("POST", "/api/logout"):
                sessions.revoke(token)
                if controller == token || privateOwner == token { await disconnect() }
                return .json(["ok": true])
            case ("POST", "/api/display"):
                struct Payload: Decodable { let displayID: UInt32; let quality: DesktopQuality; let mediaID: String }
                let payload = try JSONDecoder().decode(Payload.self, from: request.body)
                guard controller == token, mediaID == payload.mediaID, let peer, let source = peer.videoSource else {
                    return .error("The connection is no longer valid.", status: 409)
                }
                guard !operationInFlight, !rebuildingCapture, !teardownInFlight, consoleAvailable, canSelectDisplay,
                      privateOwner == nil else { return .error("The session or display is switching. Try again shortly.", status: 409) }
                guard currentDisplays().contains(where: { $0.id == payload.displayID }) else { return .error("Displays changed. Refresh the list.", status: 409) }
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
                guard canSelectDisplay, selectedDisplayID == payload.displayID else {
                    return .error("The session or display is switching. Try again shortly.", status: 409)
                }
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
        guard !operationInFlight, !rebuildingCapture, !teardownInFlight, !privateRestorePending,
              !companionBlackoutActive || blackout.isIsolated else { return .error("Another connection operation is in progress.", status: 409) }
        guard (controller == nil || controller == token), (privateOwner == nil || privateOwner == token) else { return .error("A controller is already connected. Disconnect it on the host Mac first.", status: 409) }
        guard !suspended, consoleAvailable, CGPreflightScreenCaptureAccess() else {
            return .error("Desktop unavailable. Check Screen Recording access, the lock screen, and the current user session on the host Mac.", status: 403)
        }
        if let reason = safetyReason() { return .error(reason, status: 503) }
        operationInFlight = true
        defer { operationInFlight = false }
        let generation = configuration.generation
        let revision = connectionRevision
        let mayContinue = {
            let current = DesktopSessionSnapshot.current()
            return self.connectionRevision == revision && self.configuration.enabled && self.configuration.generation == generation &&
                self.server != nil && !self.suspended && !self.teardownInFlight && current.available && current.loginDone &&
                current.onConsole && (!self.companionBlackoutActive || self.blackout.isIsolated) &&
                self.sessions.validate(token, now: self.now, touch: false) && CGPreflightScreenCaptureAccess()
        }
        let usePrivacy: Bool
        do {
            usePrivacy = try requiresPrivateConnection(token: token, mode: files.load().privacyMode)
        } catch { return .error(error.localizedDescription, status: 409) }
        if usePrivacy {
            do { _ = try preparedPrivacyDisplay() }
            catch { return .error(error.localizedDescription, status: 409) }
            guard !blackout.isActive || privateOwner == token else {
                return .error("Restore the current display layout before starting an automatic private connection.", status: 409)
            }
        }
        do {
            await stopMedia()
            guard mayContinue() else { throw RemoteError.message("Connection canceled.") }
            try holdPower()
            let targetID: UInt32
            if usePrivacy {
                let display = try preparedPrivacyDisplay()
                if privateOwner == nil {
                    restoreDisplaySleep = physicalDisplaysAsleep
                    releaseConsoleActivity()
                    privateOwner = token; controller = token
                    privateReconnectDeadline = now + 30
                    status.state = "connecting"; status.message = "Preparing the private display…"; publish()
                    try await blackout.begin(virtualID: display.id, lockBeforeRestore: true, mayCommit: mayContinue)
                }
                guard mayContinue(), blackout.isIsolated else { throw RemoteError.message("The private display could not be isolated.") }
                targetID = display.id
                selectedIdentity = DesktopDisplayIdentity(displayID: targetID)
                privateReconnectDeadline = privateReconnectDeadline ?? now + 30
                record("private-display-isolated")
            } else {
                if !companionBlackoutActive, !(await blackout.restore()) {
                    throw RemoteError.message("Physical display restoration is incomplete. Retrying.")
                }
                guard mayContinue(), try !requiresPrivateConnection(token: token, mode: files.load().privacyMode) else {
                    throw RemoteError.message("The host now requires a private display. Reconnect to continue.")
                }
                guard currentDisplays().contains(where: { $0.id == offer.displayID }) else {
                    throw RemoteError.message("Displays changed. Refresh the display list and reconnect.")
                }
                selectedIdentity = DesktopDisplayIdentity(displayID: offer.displayID)
                targetID = DesktopSessionSnapshot.current().locked ? CGMainDisplayID() : offer.displayID
            }
            await refreshDesktopSession()
            guard mayContinue(), !usePrivacy || blackout.isIsolated else { throw RemoteError.message("Connection canceled.") }
            lockDisplayIdentity = desktopSession.locked ? DesktopDisplayIdentity(displayID: targetID) : nil
            selectedDisplayID = targetID; selectedQuality = offer.quality
            input.destination = desktopSession.locked ? .lockScreen : .desktop
            needsCaptureRebuild = true
            let codecCapability = await DesktopHEVC.capability.value
            guard mayContinue(), !usePrivacy || blackout.isIsolated else { throw RemoteError.message("Connection canceled.") }
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
                if self.privateOwner == token, state == .connected, !self.operationInFlight { self.privateReconnectDeadline = nil }
                if self.privateOwner == token && state == .disconnected {
                    self.privateReconnectDeadline = self.privateReconnectDeadline ?? self.now + 30
                }
                if state == .failed || state == .closed {
                    Task {
                        guard self.peer === peer, !self.operationInFlight else { return }
                        if self.privateOwner == token { await self.retainPrivateDisplayForReconnect() }
                        else { await self.disconnect() }
                    }
                }
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
            guard mayContinue(), self.peer === peer, let source = peer.videoSource else { throw RemoteError.message("Connection canceled.") }
            let captureSession = desktopSession
            if consoleAvailable {
                try await prepareConsoleCapture(connectingToken: token)
                do {
                    guard mayContinue(), !usePrivacy || blackout.isIsolated else { throw RemoteError.message("The private display could not be isolated.") }
                    try await capture.start(source: source, displayID: targetID, quality: offer.quality, limit: peer.captureLimit,
                                            prepared: usePrivacy ? privacyCaptureTarget : nil)
                    try await capture.waitForFirstFrame()
                    needsCaptureRebuild = captureSession != DesktopSessionSnapshot.current()
                    if usePrivacy && needsCaptureRebuild { throw RemoteError.message("The local session changed. Reconnect to the private display.") }
                } catch {
                    // Lock/display transitions can temporarily hide SCK's display
                    // list. Keep the authenticated peer and retry in tick.
                    if usePrivacy { throw RemoteError.message("The private display did not provide a fresh frame. Reconnect or check the host Mac locally.") }
                    if !desktopSession.locked { throw error }
                    await capture.stop()
                }
            }
            guard self.peer === peer, mayContinue(), safetyReason() == nil, !usePrivacy || blackout.isIsolated,
                  let mediaID else { throw RemoteError.message("Connection canceled.") }
            input.displayID = targetID
            input.enabled = peer.connectionState == .connected && CGPreflightPostEventAccess() && inputReady
            peer.configureBitrate(maximum: offer.quality.bitrate, fps: offer.quality.fps)
            selectedQuality = offer.quality
            if usePrivacy, peer.connectionState == .connected { privateReconnectDeadline = nil }
            status.state = "connecting"; status.message = "Establishing a live connection"; publish()
            return .json(["sdp": answer, "mediaID": mediaID])
        } catch {
            if revision == connectionRevision {
                if usePrivacy, privateOwner == token, blackout.isIsolated, mayContinue(), safetyReason() == nil {
                    await stopMedia()
                    status.message = "Waiting for the private connection to resume…"; publish()
                } else { await disconnect() }
            }
            return .error(usePrivacy ? error.localizedDescription : "Unable to start the desktop: \(error.localizedDescription)", status: 500)
        }
    }

    private func availableDisplays() async throws -> [RemoteDisplay] {
        currentDisplays()
    }

    private func displaysForConnection(token: String) async throws -> [RemoteDisplay] {
        await refreshDesktopSession()
        guard !suspended, consoleAvailable, !teardownInFlight, !privateRestorePending,
              (controller == nil || controller == token), (privateOwner == nil || privateOwner == token),
              sessions.validate(token, now: now, touch: false) else {
            throw RemoteError.message("The current user session is unavailable or the connection was canceled.")
        }
        let mode = try files.load().privacyMode
        if requiresPrivateConnection(token: token, mode: mode) {
            let display = try preparedPrivacyDisplay()
            let mode = display.configuration
            return [RemoteDisplay(id: display.id, name: "Vela Virtual Display", width: mode.width, height: mode.height,
                                  isVirtual: true, logicalWidth: mode.logicalWidth, logicalHeight: mode.logicalHeight)]
        }
        // When automatic privacy is enabled, discovery never wakes displays.
        // Recheck lock and sleep in the offer handler before any activity request.
        if mode != .off { return currentDisplays() }
        // This endpoint runs after authentication, but before the browser can
        // construct an offer. It must not require an already-established peer.
        // Never wake another user's session or the physical-blackout session.
        if blackout.isActive || companionBlackoutActive { return try await availableDisplays() }
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
                    (try? self.files.load().privacyMode) == .off &&
                    !self.suspended && !self.blackout.isActive && !self.companionBlackoutActive && !self.companionBlackoutStarting &&
                    current.available && current.loginDone && current.onConsole &&
                    (self.controller == nil || self.controller == token) &&
                    self.sessions.validate(token, now: self.now, touch: false) && CGPreflightScreenCaptureAccess()
            })
        return describeDisplays(displays.filter { $0.id != privacyDisplay?.id })
    }

    private func currentDisplays() -> [RemoteDisplay] {
        guard !companionBlackoutActive || blackout.isIsolated else { return [] }
        return describeDisplays(DesktopCapture.displayMetadata().filter {
            privateOwner != nil ? $0.id == privacyDisplay?.id : $0.id != privacyDisplay?.id
        })
    }

    private func previewDisplay(_ body: Data, token: String) async -> RemoteResponse {
        struct Payload: Decodable { let displayID: UInt32; let mediaID: String }
        struct Preview: Encodable { var jpeg: String? }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: body) else {
            return .error("Invalid display preview request.", status: 400)
        }
        guard controller == token, mediaID == payload.mediaID, let peer else {
            return .error("The connection is no longer valid.", status: 409)
        }
        let id = payload.displayID
        let revision = desktopSessionRevision
        let identity = DesktopDisplayIdentity(displayID: id)
        let mayCapture = {
            self.peer === peer && self.controller == token && self.mediaID == payload.mediaID &&
                peer.connectionState == .connected && self.sessions.validate(token, now: self.now, touch: false) &&
                self.desktopSessionRevision == revision && self.sessionActive && self.desktopSession == DesktopSessionSnapshot.current() &&
                self.canSelectDisplay &&
                self.privateOwner == nil && !self.suspended && !self.teardownInFlight &&
                !self.operationInFlight && !self.rebuildingCapture && !self.needsCaptureRebuild &&
                self.streamDecision?.state != "limited" && CGPreflightScreenCaptureAccess() &&
                self.capture.displayID != id && CGDisplayIsAsleep(id) == 0 &&
                identity.resolve(in: self.currentDisplays()) == id
        }
        guard !previewInFlight, now - lastPreviewAt >= 0.6, mayCapture() else { return .json(Preview()) }
        previewInFlight = true; lastPreviewAt = now
        defer { previewInFlight = false }
        let data = try? await DesktopCapture.displayPreview(id, mayCapture: mayCapture)
        guard mayCapture() else { return .json(Preview()) }
        return .json(Preview(jpeg: data?.base64EncodedString()))
    }

    private func describeDisplays(_ displays: [RemoteDisplay]) -> [RemoteDisplay] {
        displays.map { display in
            let isVirtual = display.id == virtualDisplay?.id || display.id == privacyDisplay?.id ||
                companionDisplays.values.contains { $0.id == display.id }
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
        guard !operationInFlight, !rebuildingCapture, sessionActive, desktopSession.onConsole, !suspended, !blackout.isActive,
              !companionBlackoutActive else { return .error("Restore physical displays and unlock the host Mac before creating or changing a virtual display.", status: 409) }
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
            guard self.peer === peer, controller == token, sessionActive, !suspended else { throw RemoteError.message("Connection ended.") }
            // Do not destroy the old virtual screen until replacement capture is ready.
            if oldVirtual == nil { preVirtualIdentity = selectedIdentity }
            virtualDisplay = display; candidate = nil
            selectedIdentity = DesktopDisplayIdentity(displayID: display.id); selectedDisplayID = display.id; needsCaptureRebuild = false
            input.displayID = display.id
            input.enabled = CGPreflightPostEventAccess() && peer.connectionState == .connected
            oldVirtual?.close()
            return .json(DisplayChange(displayID: display.id, displays: currentDisplays()))
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
        guard !operationInFlight, !rebuildingCapture, sessionActive, desktopSession.onConsole, !suspended, !blackout.isActive,
              !companionBlackoutActive else { return .error("Restore physical displays and unlock the host Mac before closing a virtual display.", status: 409) }
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
        case "/companion-icon.svg": name = "companion-icon.svg"; mime = "image/svg+xml"
        case "/style.css": name = "style.css"; mime = "text/css; charset=utf-8"
        default: return nil
        }
        guard let directory = Bundle.module.url(forResource: "Web", withExtension: nil),
              let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return .init(body: data, contentType: mime)
    }
}
