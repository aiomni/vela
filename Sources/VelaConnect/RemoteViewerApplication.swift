import VelaLocalization
import AppKit
import Security
import CoreImage
import MetalKit
import WebRTC
import RemoteCore
import RemoteRTC

private final class CertificateTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let certificate = chain.first else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let fingerprint = RemoteSecurity.hash(SecCertificateCopyData(certificate) as Data)
        let endpoint = "\(challenge.protectionSpace.host):\(challenge.protectionSpace.port)"
        let key = "remoteCertificate.\(endpoint)"
        // Even when pinned, validate the certificate's hostname and validity using the leaf as its explicit anchor.
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        Task { @MainActor in
            let saved = UserDefaults.standard.string(forKey: key)
            if saved == fingerprint { completionHandler(.useCredential, URLCredential(trust: trust)); return }
            let alert = NSAlert()
            alert.messageText = saved == nil ? L("Confirm the remote computer's certificate") : L("The remote computer's certificate has changed")
            alert.informativeText = L("Address: {0}\n\nCompare this fingerprint with the one in Vela Settings on the host Mac.\n\nSHA-256: {1}\n\n{2}", "\(endpoint)", "\(fingerprint)", "\(saved == nil ? L("After confirmation, this certificate will be checked automatically next time.") : L("A network address or certificate update may cause this change. Cancel if the fingerprints do not match."))")
            alert.addButton(withTitle: L("Fingerprints match, continue"))
            alert.addButton(withTitle: L("Cancel"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                UserDefaults.standard.set(fingerprint, forKey: key)
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else { completionHandler(.cancelAuthenticationChallenge, nil) }
        }
    }
}

@MainActor
final class RemoteViewerApplication: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let addressField = NSTextField(string: "")
    private let passwordField = NSSecureTextField(string: "")
    private let connectButton = NSButton(title: L("Connect"), target: nil, action: nil)
    private let disconnectButton = NSButton(title: L("Disconnect"), target: nil, action: nil)
    private let displayButton = NSPopUpButton()
    private let qualityButton = NSPopUpButton()
    private let streamPreference = NSPopUpButton()
    private let zoomButton = NSPopUpButton()
    private let streamStatus = NSTextField(labelWithString: "")
    private var streamPresentation: (codec: String, reason: String?, state: String?)?
    private let losslessButton = NSButton(checkboxWithTitle: L("Lossless text enhancement"), target: nil, action: nil)
    private var receiverMetrics = DesktopStreamMetrics()
    private var forceH264 = false
    private var attemptedHEVC = false
    private var peerStartedAt = 0.0
    private var lastDecodedFrames = 0.0
    private let message = NSTextField(wrappingLabelWithString: L("Enter the host Mac's IP:port and the password for its selected authentication method. Mac account authentication accepts only the account running Vela. Touch ID is not supported. An existing connection can show the system lock screen for password entry."))
    private let textField = NSTextField(string: "")
    private let surface = RemoteDesktopSurface()
    private lazy var viewport = RemoteDesktopViewport(surface: surface)
    private let trustDelegate = CertificateTrust()
    private lazy var http: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: trustDelegate, delegateQueue: nil)
    }()
    private var baseURL: URL?
    private var token: String?
    private var peer: RemotePeer?
    private var mediaID: String?
    private var timer: Timer?
    private var polling = false
    private var connecting = false
    private var localCandidateCount = 0
    private var remoteCandidateCount = 0
    private var connectionGeneration = UUID()
    private var reconnectTask: Task<Void, Never>?
    private var retries = 0
    private var languageObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L("Vela Connect")
        window.minSize = NSSize(width: 760, height: 680)
        window.delegate = self; window.center(); window.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -18)
        ])
        addressField.placeholderString = "192.168.1.20:8443 / [fd00::1234]:8443"
        addressField.stringValue = UserDefaults.standard.string(forKey: "lastRemoteAddress") ?? ""
        addressField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        addressField.setAccessibilityLabel(L("Remote computer IP and port"))
        passwordField.placeholderString = L("Custom / Mac account password")
        passwordField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        passwordField.setAccessibilityLabel(L("Remote access password"))
        connectButton.target = self; connectButton.action = #selector(connect)
        disconnectButton.target = self; disconnectButton.action = #selector(disconnectAction)
        let toolbar = NSStackView(views: [NSTextField(labelWithString: L("Computer")), addressField, passwordField, connectButton, disconnectButton, NSView()])
        toolbar.spacing = 8; stack.addArrangedSubview(toolbar)
        toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        displayButton.target = self; displayButton.action = #selector(changeDisplay)
        qualityButton.addItems(withTitles: [L("Smooth · 1080p / 60"), L("Clear · 1440p / 30"), L("Full resolution · Up to 4K")])
        qualityButton.selectItem(at: 2)
        qualityButton.target = self; qualityButton.action = #selector(changeDisplay)
        let full = NSButton(title: L("Full screen"), target: self, action: #selector(fullscreen))
        let release = NSButton(title: L("Release keys"), target: self, action: #selector(releaseKeys))
        let options = NSStackView(views: [displayButton, qualityButton, full, release, LanguagePicker(), NSView()])
        options.spacing = 8; stack.addArrangedSubview(options)
        options.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        streamPreference.addItems(withTitles: [L("Automatic"), L("Text clarity"), L("Smooth motion")])
        let preferences = RemoteStreamPreference.allCases
        let savedPreference = RemoteStreamPreference(rawValue: UserDefaults.standard.string(forKey: "velaStreamPreference") ?? "") ?? .automatic
        streamPreference.selectItem(at: preferences.firstIndex(of: savedPreference) ?? 0)
        streamPreference.target = self; streamPreference.action = #selector(changeStreamPreference)
        streamPreference.setAccessibilityLabel(L("Streaming preference"))
        streamStatus.font = .systemFont(ofSize: 11); streamStatus.textColor = .secondaryLabelColor
        losslessButton.target = self; losslessButton.action = #selector(changeLosslessPreference)
        let streamRow = NSStackView(views: [streamPreference, losslessButton, streamStatus, NSView()])
        streamRow.spacing = 8; stack.addArrangedSubview(streamRow)
        streamRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for (id, title) in [("fit", "Fit window"), ("1", "100% · Pixel for pixel"), ("1.5", "150% · Zoom in"), ("2", "200% · Zoom in"), ("4", "400% · Zoom in")] {
            zoomButton.addItem(withTitle: L(title)); zoomButton.lastItem?.representedObject = id
        }
        zoomButton.setAccessibilityLabel(L("Video size"))
        zoomButton.target = self; zoomButton.action = #selector(changeZoom)
        let centerVideo = NSButton(title: L("Center video"), target: self, action: #selector(centerVideo))
        let zoomHint = NSTextField(labelWithString: L("Option-scroll to pan. Scroll controls the remote Mac."))
        zoomHint.font = .systemFont(ofSize: 11); zoomHint.textColor = .secondaryLabelColor
        zoomButton.toolTip = L("Pixel-for-pixel view preserves available detail. Zooming cannot restore detail lost in transmission.")
        let zoomRow = NSStackView(views: [zoomButton, centerVideo, zoomHint, NSView()])
        zoomRow.spacing = 8; stack.addArrangedSubview(zoomRow)
        zoomRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(viewport)
        viewport.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        viewport.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        viewport.setContentHuggingPriority(.defaultLow, for: .vertical)
        surface.onInput = { [weak self] input in self?.peer?.sendInput(input) }
        surface.onRelease = { [weak self] in self?.peer?.sendInput(RemoteInput(type: "release")) }
        textField.placeholderString = L("Enter text to send to the remote computer")
        let send = NSButton(title: L("Send text"), target: self, action: #selector(sendText))
        textField.target = self; textField.action = #selector(sendText)
        let textRow = NSStackView(views: [textField, send]); textRow.spacing = 8
        stack.addArrangedSubview(textRow); textRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        message.font = .systemFont(ofSize: 12); message.textColor = .secondaryLabelColor
        stack.addArrangedSubview(message); message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Quit Vela Connect"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(); let editMenu = NSMenu(title: L("Edit"))
        for (title, action, key) in [(L("Cut"), #selector(NSText.cut(_:)), "x"), (L("Copy"), #selector(NSText.copy(_:)), "c"), (L("Paste"), #selector(NSText.paste(_:)), "v"), (L("Select all"), #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = editMenu; menu.addItem(editItem); NSApp.mainMenu = menu
        languageObserver = NotificationCenter.default.addObserver(forName: Localization.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { LocalizationUI.refreshWindows(); self?.renderStreamStatus() }
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private var selectedDisplay: UInt32? { (displayButton.selectedItem?.representedObject as? RemoteDisplay)?.id }
    private var quality: DesktopQuality { DesktopQuality.allCases[max(0, qualityButton.indexOfSelectedItem)] }
    @objc private func connect() {
        guard !connecting else { return }
        Task {
            connecting = true; connectButton.isEnabled = false
            defer { connecting = false; connectButton.isEnabled = true; passwordField.stringValue = "" }
            do {
                await disconnect(notify: true)
                let raw = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: raw.hasPrefix("https://") ? raw : "https://\(raw)"),
                      url.scheme == "https", let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                      url.query == nil, url.fragment == nil, ["", "/"].contains(url.path), url.port != nil else {
                    throw RemoteError.message(L("Enter IPv4:port or [IPv6]:port, for example [fd00::1234]:8443."))
                }
                baseURL = url
                let authentication = try await object("authentication")
                guard let mode = authentication["mode"] as? String,
                      ["customPassword", "macOSAccount"].contains(mode),
                      let generation = authentication["generation"] as? String else {
                    throw RemoteError.message(L("The host's authentication method is invalid. Update Vela on the host Mac."))
                }
                message.stringValue = mode == "macOSAccount"
                    ? L("Verifying local account {0}…", "\(authentication["account"] as? String ?? "")") : L("Verifying custom password…")
                let password = passwordField.stringValue; passwordField.stringValue = ""
                let login = try await object("login", body: ["password": password, "mode": mode, "generation": generation])
                guard let token = login["token"] as? String else { throw RemoteError.message(L("Invalid login response.")) }
                self.token = token; passwordField.stringValue = ""
                let displays = try JSONDecoder().decode([RemoteDisplay].self, from: await request("displays"))
                guard !displays.isEmpty else { throw RemoteError.message(L("The remote computer has no display available for capture.")) }
                displayButton.removeAllItems()
                for display in displays {
                    displayButton.addItem(withTitle: "\(display.name) · \(display.width)×\(display.height)")
                    displayButton.lastItem?.representedObject = display
                }
                UserDefaults.standard.set(raw, forKey: "lastRemoteAddress")
                retries = 0; forceH264 = false
                try await startPeer()
            } catch { message.stringValue = L(error.localizedDescription) }
        }
    }
    private func startPeer() async throws {
        do { try await startPeerAttempt() }
        catch {
            guard attemptedHEVC, !forceH264 else { throw error }
            forceH264 = true
            try await startPeerAttempt()
        }
    }
    private func startPeerAttempt() async throws {
        closePeer()
        let generation = UUID(); connectionGeneration = generation
        guard let displayID = selectedDisplay else { throw RemoteError.message(L("Select a display.")) }
        let capability = await DesktopHEVC.capability.value
        attemptedHEVC = capability.available && !forceH264 && losslessButton.state != .on
        let peer = try RemotePeer(sendingVideo: false, allowHEVC: attemptedHEVC)
        peerStartedAt = ProcessInfo.processInfo.systemUptime; lastDecodedFrames = 0
        receiverMetrics = DesktopStreamMetrics()
        self.peer = peer; surface.displayID = displayID
        peer.onVideo = { [weak self] track in guard let self else { return }; track.add(self.surface.videoSink) }
        peer.onState = { [weak self, weak peer] state in
            guard let self, let peer, self.peer === peer else { return }
            if state == .connected { self.peerStartedAt = ProcessInfo.processInfo.systemUptime; self.retries = 0; self.message.stringValue = L("Connected · Click the screen to control · ⌃⌥Esc releases the keyboard") }
            if state == .failed || state == .disconnected {
                self.surface.releaseAll(); self.surface.inputAllowed = false; self.scheduleReconnect()
            }
        }
        observeLossless(peer, generation: generation)
        peer.onEnhancement = { [weak self] data in
            guard let self, self.losslessButton.state == .on else { return }
            self.surface.lossless.receive(data)
        }
        let offer = try await peer.makeOffer()
        let answer = try await object("offer", body: ["sdp": offer, "displayID": displayID, "quality": quality.rawValue, "stream": try JSONSerialization.jsonObject(with: JSONEncoder().encode(currentStreamFeedback())), "hevc": attemptedHEVC])
        guard connectionGeneration == generation, let sdp = answer["sdp"] as? String, let id = answer["mediaID"] as? String else {
            throw RemoteError.message(L("Connection canceled or invalid response."))
        }
        mediaID = id
        try await peer.accept(answer: sdp)
        if peer.videoCodec != "H265" { attemptedHEVC = false }
        message.stringValue = L("Establishing a live video connection…")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in await self?.poll() } }
        await poll()
    }
    private func poll() async {
        guard !polling, let peer, let mediaID, let token else { return }
        polling = true; defer { polling = false }
        let generation = connectionGeneration
        do {
            let pending = peer.localCandidates
            for candidate in pending.dropFirst(localCandidateCount) {
                let dictionary = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate))
                _ = try await object("candidate", body: ["mediaID": mediaID, "candidate": dictionary])
            }
            localCandidateCount = pending.count
            let value = try await object("poll")
            guard generation == connectionGeneration, self.token == token else { return }
            guard value["mediaID"] as? String == mediaID else { throw RemoteError.message(value["message"] as? String ?? L("The session has ended.")) }
            surface.inputAllowed = value["inputPermission"] as? Bool == true && peer.connectionState == .connected
            let session = value["session"] as? [String: Any]
            surface.renderer.isHidden = session?["requiresAccountVerification"] as? Bool == true || session?["recovering"] as? Bool == true
            surface.losslessAllowed = losslessButton.state == .on && ["local", "blackout"].contains(session?["state"] as? String ?? "") && !surface.renderer.isHidden
            if !surface.losslessAllowed { surface.lossless.reset() }
            if session?["requiresAccountVerification"] as? Bool == true {
                message.stringValue = L("The current user has left the local console. Return to this account on the host Mac.")
            } else if session?["recovering"] as? Bool == true {
                message.stringValue = L("Restoring the session video…")
            } else if session?["lockScreenControl"] as? Bool == true {
                message.stringValue = L("Mac is locked: click the system password field, enter the password, and press Return to unlock.")
            } else if value["inputPermission"] as? Bool == false {
                message.stringValue = L("View only: grant Accessibility access on the host Mac.")
            } else if session?["state"] as? String == "blackout" {
                message.stringValue = L("Virtual display only: local keyboard or mouse input restores physical displays.")
            }
            if let rawDisplays = value["displays"], let selected = value["displayID"] as? UInt32 {
                let data = try JSONSerialization.data(withJSONObject: rawDisplays)
                let displays = try JSONDecoder().decode([RemoteDisplay].self, from: data)
                if selectedDisplay != selected || displayButton.numberOfItems != displays.count {
                    displayButton.removeAllItems()
                    for display in displays {
                        displayButton.addItem(withTitle: "\(display.name) · \(display.width)×\(display.height)")
                        displayButton.lastItem?.representedObject = display
                        if display.id == selected { displayButton.select(displayButton.lastItem) }
                    }
                }
                surface.displayID = selected
            }
            let data = try JSONSerialization.data(withJSONObject: value["candidates"] ?? [])
            let candidates = try JSONDecoder().decode([RemoteICECandidate].self, from: data)
            for candidate in candidates.dropFirst(remoteCandidateCount) { try await peer.add(candidate) }
            remoteCandidateCount = candidates.count
            if let stream = value["stream"] as? [String: Any] {
                streamPresentation = (value["videoCodec"] as? String ?? "H264", stream["reason"] as? String, stream["state"] as? String)
                renderStreamStatus()
            }
            let statistics = await peer.diagnostics()
            guard generation == connectionGeneration else { return }
            let sample = receiverMetrics.sample(statistics)
            if attemptedHEVC, peer.activeVideoCodec == "H264" { attemptedHEVC = false; forceH264 = true }
            let decoded = statistics.filter { $0["type"] == "inbound-rtp" && ($0["kind"] == "video" || $0["mediaType"] == "video") }
                .compactMap { Double($0["framesDecoded"] ?? "") }.max() ?? 0
            if decoded != lastDecodedFrames || surface.renderer.isHidden {
                lastDecodedFrames = decoded; peerStartedAt = ProcessInfo.processInfo.systemUptime
            }
            if attemptedHEVC, ProcessInfo.processInfo.systemUptime - peerStartedAt > 6 {
                forceH264 = true; scheduleReconnect(); return
            }
            let feedback = currentStreamFeedback(decode: sample.decodeMilliseconds, dropped: sample.droppedFrameRatio)
            _ = try? await object("stream-feedback", body: ["mediaID": mediaID, "feedback": try JSONSerialization.jsonObject(with: JSONEncoder().encode(feedback))])
        } catch { message.stringValue = L(error.localizedDescription); scheduleReconnect() }
    }
    private func scheduleReconnect() {
        guard reconnectTask == nil, token != nil, retries < 5 else { return }
        retries += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            do { try await self.startPeer() }
            catch { self.message.stringValue = L("Reconnection failed: {0}", "\(L(error.localizedDescription))"); self.scheduleReconnect() }
        }
    }
    private func request(_ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard let baseURL else { throw RemoteError.message(L("Enter a remote address first.")) }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/\(path)"))
        request.httpMethod = body == nil ? "GET" : "POST"
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await http.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteError.message(L("Invalid remote response.")) }
        guard (200...299).contains(http.statusCode) else {
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if http.statusCode == 401 { self.token = nil; closePeer() }
            throw RemoteError.message(value?["error"] as? String ?? L("Request failed: {0}", "\(http.statusCode)"))
        }
        return data
    }
    private func object(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let data = try await request(path, body: body)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    private func closePeer() {
        connectionGeneration = UUID()
        streamPresentation = nil; renderStreamStatus()
        surface.releaseAll(); surface.inputAllowed = false
        timer?.invalidate(); timer = nil
        peer?.remoteVideo?.remove(surface.videoSink)
        surface.resetVideoSession(); surface.losslessAllowed = false
        peer?.close(); peer = nil; mediaID = nil
        localCandidateCount = 0; remoteCandidateCount = 0
        surface.renderer.renderFrame(nil)
    }
    private func disconnect(notify: Bool) async {
        reconnectTask?.cancel(); reconnectTask = nil
        closePeer()
        if notify && token != nil { _ = try? await object("logout", body: [:]) }
        token = nil
    }
    @objc private func disconnectAction() { Task { await disconnect(notify: true); message.stringValue = L("Disconnected") } }
    @objc private func changeDisplay() {
        surface.releaseAll()
        guard let displayID = selectedDisplay, let mediaID else { return }
        Task {
            do {
                _ = try await object("display", body: ["mediaID": mediaID, "displayID": displayID, "quality": quality.rawValue])
                surface.displayID = displayID
            } catch { message.stringValue = L(error.localizedDescription) }
        }
    }
    private func renderStreamStatus() {
        guard let presentation = streamPresentation else { streamStatus.stringValue = ""; return }
        let label: String
        switch presentation.reason {
        case "network": label = L("Network limited · Reducing workload")
        case "device": label = L("Device limited · Reducing workload")
        case "recovering": label = L("Recovering stream quality")
        default:
            label = presentation.state == "refining" ? L("Restoring text detail") :
                presentation.state == "idle" ? L("Static desktop · Saving bandwidth") : L("Adaptive streaming")
        }
        streamStatus.stringValue = L("{0} · {1}", presentation.codec, label)
    }
    private func currentStreamFeedback(decode: Double? = nil, dropped: Double? = nil) -> RemoteStreamFeedback {
        let scale = surface.window?.backingScaleFactor ?? 1
        return RemoteStreamFeedback(preference: RemoteStreamPreference.allCases[max(0, streamPreference.indexOfSelectedItem)], lossless: losslessButton.state == .on,
            viewportWidth: viewport.zoom == nil ? max(1, min(16384, Int(viewport.bounds.width * scale))) : nil,
            viewportHeight: viewport.zoom == nil ? max(1, min(16384, Int(viewport.bounds.height * scale))) : nil,
            decodeMilliseconds: decode, droppedFrameRatio: dropped)
    }
    @objc private func changeZoom() {
        surface.releaseAll()
        viewport.setZoom(Double(zoomButton.selectedItem?.representedObject as? String ?? "fit"))
        changeStreamPreference()
    }
    @objc private func centerVideo() { surface.releaseAll(); viewport.centerVideo() }
    private func observeLossless(_ peer: RemotePeer, generation: UUID) {
        guard losslessButton.state == .on else { peer.frameIdentity.observe(nil); return }
        peer.frameIdentity.observe { [weak self, weak peer] marker in
            Task { @MainActor in
                guard let self, let peer, self.peer === peer, self.connectionGeneration == generation else { return }
                self.surface.lossless.marker(marker)
            }
        }
    }
    @objc private func changeLosslessPreference() {
        surface.lossless.reset()
        if let peer { observeLossless(peer, generation: connectionGeneration) }
        if losslessButton.state == .on && attemptedHEVC { scheduleReconnect() }
        else if losslessButton.state == .off && !forceH264 {
            Task { if await DesktopHEVC.capability.value.available { self.scheduleReconnect() } }
        }
        changeStreamPreference()
    }
    @objc private func changeStreamPreference() {
        let feedback = currentStreamFeedback()
        UserDefaults.standard.set(feedback.preference?.rawValue, forKey: "velaStreamPreference")
        guard let mediaID else { return }
        Task { _ = try? await object("stream-feedback", body: ["mediaID": mediaID, "feedback": try JSONSerialization.jsonObject(with: JSONEncoder().encode(feedback))]) }
    }
    @objc private func sendText() {
        guard !textField.stringValue.isEmpty, surface.inputAllowed else { return }
        var input = RemoteInput(type: "text"); input.text = textField.stringValue
        guard input.validate() else { message.stringValue = L("Send at most 8192 bytes at a time. Split longer text into smaller parts."); return }
        peer?.sendInput(input); textField.stringValue = ""; window.makeFirstResponder(surface)
    }
    @objc private func fullscreen() { window.toggleFullScreen(nil) }
    @objc private func releaseKeys() { surface.releaseAll(); window.makeFirstResponder(addressField) }
    func windowDidResignKey(_ notification: Notification) { surface.releaseAll() }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await disconnect(notify: true); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@MainActor
private final class RemoteDesktopViewport: NSView {
    private let scrollView = VelaScrollView(frame: .zero)
    private let surface: RemoteDesktopSurface
    private(set) var zoom: Double?
    init(surface: RemoteDesktopSurface) {
        self.surface = surface
        super.init(frame: .zero)
        scrollView.hasVerticalScroller = true; scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = true; scrollView.backgroundColor = .black
        scrollView.documentView = surface; addSubview(scrollView)
        surface.onVideoSizeChange = { [weak self] in self?.updateDocument() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        scrollView.frame = bounds
        updateDocument()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateDocument() }
    func setZoom(_ value: Double?) {
        let center = visibleVideoCenter()
        zoom = value.map { min(4, max(0.25, $0)) }
        updateDocument(center: center)
    }
    private func visibleVideoCenter() -> NSPoint {
        let visible = scrollView.contentView.bounds, video = surface.renderer.frame
        guard video.width > 0, video.height > 0 else { return NSPoint(x: 0.5, y: 0.5) }
        return NSPoint(x: (visible.midX - video.minX) / video.width, y: (visible.midY - video.minY) / video.height)
    }
    private func updateDocument(center: NSPoint? = nil) {
        let center = center ?? visibleVideoCenter(), visible = scrollView.contentView.bounds.size
        guard visible.width > 0, visible.height > 0 else { return }
        surface.zoom = zoom
        let size = surface.displaySize(in: visible)
        surface.setFrameSize(NSSize(width: max(visible.width, size.width), height: max(visible.height, size.height)))
        surface.needsLayout = true; surface.layoutSubtreeIfNeeded()
        let video = surface.renderer.frame
        let origin = NSPoint(x: video.minX + center.x * video.width - visible.width / 2,
                             y: video.minY + center.y * video.height - visible.height / 2)
        scrollView.contentView.scroll(to: NSPoint(x: min(max(0, origin.x), max(0, surface.bounds.width - visible.width)),
                                                 y: min(max(0, origin.y), max(0, surface.bounds.height - visible.height))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    func centerVideo() { updateDocument(center: NSPoint(x: 0.5, y: 0.5)) }
    static func runChecks() -> Bool {
        let viewport = RemoteDesktopViewport(surface: RemoteDesktopSurface())
        // Use the viewport's document view so input checks exercise the actual scrolled hierarchy.
        let document = viewport.surface
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [], backing: .buffered, defer: false)
        window.contentView = viewport
        document.updateVideoSize(NSSize(width: 3840, height: 2160))
        document.renderer.setSize(NSSize(width: 3840, height: 2160))
        viewport.needsLayout = true; viewport.layoutSubtreeIfNeeded()
        var passed = true, count = 0
        func check(_ value: Bool, _ label: String) {
            count += 1; if !value { passed = false }
            print("\(value ? "PASS" : "FAIL"): \(label)")
        }
        check(document.frame.width <= 800 && document.frame.height <= 500, "Fit view stays within the viewport")
        viewport.setZoom(1)
        check(abs(document.renderer.frame.width * window.backingScaleFactor - 3840) < 1, "100 percent maps one source pixel to one backing pixel")
        viewport.setZoom(4)
        check(abs(document.renderer.frame.width * window.backingScaleFactor - 15360) < 1, "400 percent enlarges the source in both dimensions")
        let targets = document.renderer.subviews.compactMap { $0 as? MTKView }
        check(!targets.isEmpty && targets.allSatisfy { !$0.autoResizeDrawable && $0.drawableSize.width <= 3840 && $0.drawableSize.height <= 2160 }, "Zoom keeps Metal drawables at source resolution")
        viewport.centerVideo()
        check(abs(viewport.scrollView.contentView.bounds.midX - document.renderer.frame.midX) < 1, "Center action centers enlarged video")
        viewport.scrollView.contentView.scroll(to: .zero)
        let point = NSPoint(x: 100, y: 100)
        let location = document.convert(point, to: nil)
        var inputs: [RemoteInput] = []
        document.inputAllowed = true; document.displayID = 42; document.onInput = { inputs.append($0) }
        if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            document.mouseDown(with: event)
        }
        let click = inputs.last
        check(click?.type == "pointer" && click?.displayID == 42 && abs((click?.x ?? -1) - Double(100 / document.renderer.frame.width)) < 0.001 && abs((click?.y ?? -1) - Double(100 / document.renderer.frame.height)) < 0.001, "Panned zoom maps clicks to the source without injecting system input")
        if let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 30, wheel2: 20, wheel3: 0),
           let event = NSEvent(cgEvent: wheel) {
            inputs.removeAll(); document.scrollWheel(with: event)
            check(inputs.last?.type == "scroll", "Ordinary scrolling still controls the remote desktop")
            wheel.flags = .maskAlternate
            if let pan = NSEvent(cgEvent: wheel) {
                viewport.centerVideo()
                let origin = viewport.scrollView.contentView.bounds.origin
                inputs.removeAll(); document.scrollWheel(with: pan)
                check(inputs.isEmpty, "Option scrolling stays local")
                check(viewport.scrollView.contentView.bounds.origin != origin, "Option scrolling pans the actual native clip view")
            }
        } else { check(false, "Synthetic scroll event creation") }
        document.inputAllowed = false; inputs.removeAll()
        if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) {
            document.mouseDown(with: event)
        }
        check(inputs.isEmpty, "View-only input remains blocked when zoomed")
        viewport.setZoom(nil)
        check(viewport.scrollView.contentView.bounds.origin == .zero, "Returning to fit clears local panning")
        print("Viewport checks: \(count), result: \(passed ? "PASS" : "FAIL")")
        return passed
    }
}

@MainActor
private final class DesktopVideoView: RTCMTLNSVideoView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // RTC sets drawableSize from source frames through its public setSize method.
        // Display zoom must not allocate a 400-percent-resolution Metal drawable.
        for case let target as MTKView in subviews { target.autoResizeDrawable = false }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class RemoteDesktopSurface: NSView, RTCVideoViewDelegate {
    let renderer = DesktopVideoView(frame: .zero)
    let lossless = DesktopLosslessReceiver()
    private let enhancement = LosslessTileView()
    var losslessAllowed = false { didSet { videoSink.setIdentityEnabled(losslessAllowed); if !losslessAllowed { enhancement.isHidden = true } } }
    private var videoGeneration = UUID()
    private var decodedFrame: DesktopDecodedFrame?
    private lazy var losslessContext = CIContext(options: [.cacheIntermediates: false])
    private(set) lazy var videoSink = makeVideoSink()
    private func makeVideoSink() -> DesktopIdentityRenderer {
        let generation = videoGeneration
        return DesktopIdentityRenderer(target: renderer) { [weak self] frame in
            Task { @MainActor in
                guard let self, self.videoGeneration == generation else { return }
                self.decodedFrame = frame
                self.lossless.present(timestamp: frame.timestamp, width: frame.width, height: frame.height)
            }
        }
    }
    func resetVideoSession() { videoGeneration = UUID(); videoSink = makeVideoSink(); decodedFrame = nil; lossless.reset() }
    var onInput: ((RemoteInput) -> Void)?
    var onRelease: (() -> Void)?
    var onVideoSizeChange: (() -> Void)?
    var zoom: Double?
    var displayID: UInt32?
    var inputAllowed = false
    private var videoSize = NSSize(width: 16, height: 9)
    private var sequence: UInt64 = 0
    private var tracking: NSTrackingArea?
    private var modifiers: NSEvent.ModifierFlags = []
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor; layer?.cornerRadius = 8
        addSubview(renderer); renderer.delegate = self
        addSubview(enhancement); enhancement.isHidden = true
        lossless.onChange = { [weak self] tiles, width, height in
            guard let self else { return }
            self.enhancement.tiles = tiles; self.enhancement.pixelSize = NSSize(width: width, height: height)
            self.enhancement.baseImage = nil
            if self.losslessAllowed, !tiles.isEmpty, let frame = self.decodedFrame, frame.width == width, frame.height == height, let pixels = frame.pixels {
                // Composite over this exact decoded frame instead of the independently scheduled Metal surface.
                self.enhancement.baseImage = self.losslessContext.createCGImage(CIImage(cvPixelBuffer: pixels),
                    from: CGRect(x: 0, y: 0, width: width, height: height))
            }
            self.enhancement.isHidden = self.enhancement.baseImage == nil
            self.enhancement.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func layout() {
        super.layout()
        let size = displaySize(in: bounds.size)
        renderer.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        enhancement.frame = renderer.frame
    }
    func displaySize(in available: NSSize) -> NSSize {
        let scale = zoom.map { CGFloat($0) / max(1, window?.backingScaleFactor ?? 1) } ??
            min(available.width / max(1, videoSize.width), available.height / max(1, videoSize.height))
        return NSSize(width: videoSize.width * scale, height: videoSize.height * scale)
    }
    nonisolated func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        Task { @MainActor [weak self] in self?.updateVideoSize(size) }
    }
    func updateVideoSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return }
        videoSize = size; onVideoSizeChange?()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    private func flags(_ event: NSEvent) -> [String] {
        var result: [String] = []
        if event.modifierFlags.contains(.shift) { result.append("shift") }
        if event.modifierFlags.contains(.control) { result.append("control") }
        if event.modifierFlags.contains(.option) { result.append("alt") }
        if event.modifierFlags.contains(.command) { result.append("meta") }
        return result
    }
    private func pointer(_ event: NSEvent, action: String) {
        guard inputAllowed, renderer.frame.width > 0, renderer.frame.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard action != "down" || renderer.frame.contains(point) else { return }
        if action == "down" { window?.makeFirstResponder(self) }
        var input = RemoteInput(type: "pointer")
        input.action = action; input.displayID = displayID
        input.x = min(1, max(0, (point.x - renderer.frame.minX) / renderer.frame.width))
        input.y = min(1, max(0, (point.y - renderer.frame.minY) / renderer.frame.height))
        input.button = event.buttonNumber == 1 ? 2 : event.buttonNumber == 2 ? 1 : 0
        sequence += 1; input.sequence = sequence; input.modifiers = flags(event)
        onInput?(input)
    }
    override func mouseDown(with event: NSEvent) { pointer(event, action: "down") }
    override func mouseUp(with event: NSEvent) { pointer(event, action: "up") }
    override func rightMouseDown(with event: NSEvent) { pointer(event, action: "down") }
    override func rightMouseUp(with event: NSEvent) { pointer(event, action: "up") }
    override func otherMouseDown(with event: NSEvent) { pointer(event, action: "down") }
    override func otherMouseUp(with event: NSEvent) { pointer(event, action: "up") }
    override func mouseMoved(with event: NSEvent) { pointer(event, action: "move") }
    override func mouseDragged(with event: NSEvent) { pointer(event, action: "move") }
    override func rightMouseDragged(with event: NSEvent) { pointer(event, action: "move") }
    override func otherMouseDragged(with event: NSEvent) { pointer(event, action: "move") }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            releaseAll()
            guard let scrollView = enclosingScrollView else { return }
            let clip = scrollView.contentView, scale = event.hasPreciseScrollingDeltas ? 1.0 : 16.0
            let origin = NSPoint(x: min(max(0, clip.bounds.minX - event.scrollingDeltaX * scale), max(0, bounds.width - clip.bounds.width)),
                                 y: min(max(0, clip.bounds.minY - event.scrollingDeltaY * scale), max(0, bounds.height - clip.bounds.height)))
            clip.scroll(to: origin); scrollView.reflectScrolledClipView(clip)
            return
        }
        guard inputAllowed else { return }
        var input = RemoteInput(type: "scroll")
        let scale = event.hasPreciseScrollingDeltas ? 1.0 : 16.0
        input.deltaX = min(2000, max(-2000, -event.scrollingDeltaX * scale))
        input.deltaY = min(2000, max(-2000, -event.scrollingDeltaY * scale))
        input.displayID = displayID; input.modifiers = flags(event); onInput?(input)
    }
    private func key(_ event: NSEvent, down: Bool) {
        guard inputAllowed, let code = KeyMap.macKeyCode.first(where: { $0.value == event.keyCode })?.key else { return }
        var input = RemoteInput(type: "key")
        input.action = down ? "down" : "up"; input.code = code; input.modifiers = flags(event)
        onInput?(input)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 && event.modifierFlags.contains([.control, .option]) {
            releaseAll(); window?.makeFirstResponder(nil); return
        }
        key(event, down: true)
    }
    override func keyUp(with event: NSEvent) { key(event, down: false) }
    override func flagsChanged(with event: NSEvent) {
        let mask: NSEvent.ModifierFlags
        switch event.keyCode { case 54,55: mask = .command; case 56,60: mask = .shift; case 58,61: mask = .option; case 59,62: mask = .control; default: return }
        key(event, down: event.modifierFlags.contains(mask)); modifiers = event.modifierFlags
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, inputAllowed else { return false }
        if event.keyCode == 12 && event.modifierFlags.contains(.command) { return false } // Cmd-Q always exits locally.
        keyDown(with: event); return true
    }
    override func resignFirstResponder() -> Bool { releaseAll(); return super.resignFirstResponder() }
    func releaseAll() { onRelease?(); modifiers = [] }
}

@MainActor
func runRemoteViewportChecks() -> Bool { RemoteDesktopViewport.runChecks() }

@MainActor
private final class LosslessTileView: NSView {
    var tiles: [DesktopLosslessTile] = []
    var baseImage: CGImage?
    var pixelSize = NSSize.zero
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(bounds)
        guard pixelSize.width > 0, pixelSize.height > 0, let baseImage else { return }
        NSImage(cgImage: baseImage, size: .zero).draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        let sx = bounds.width / pixelSize.width, sy = bounds.height / pixelSize.height
        for tile in tiles {
            let rect = NSRect(x: CGFloat(tile.x) * sx, y: CGFloat(tile.y) * sy,
                width: CGFloat(tile.image.width) * sx, height: CGFloat(tile.image.height) * sy)
            NSImage(cgImage: tile.image, size: .zero).draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}
