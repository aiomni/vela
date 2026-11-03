import VelaLocalization
import AppKit
import Security
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
    private let message = NSTextField(wrappingLabelWithString: L("Enter the host Mac's IP:port and the password for its selected authentication method. Mac account authentication accepts only the account running Vela. Touch ID is not supported. An existing connection can show the system lock screen for password entry."))
    private let textField = NSTextField(string: "")
    private let surface = RemoteDesktopSurface()
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
        window.minSize = NSSize(width: 760, height: 520)
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
        addressField.placeholderString = "192.168.1.20:8443"
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
        qualityButton.target = self; qualityButton.action = #selector(changeDisplay)
        let full = NSButton(title: L("Full screen"), target: self, action: #selector(fullscreen))
        let release = NSButton(title: L("Release keys"), target: self, action: #selector(releaseKeys))
        let options = NSStackView(views: [displayButton, qualityButton, full, release, LanguagePicker(), NSView()])
        options.spacing = 8; stack.addArrangedSubview(options)
        options.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(surface)
        surface.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        surface.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        surface.setContentHuggingPriority(.defaultLow, for: .vertical)
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
        languageObserver = NotificationCenter.default.addObserver(forName: Localization.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LocalizationUI.refreshWindows() }
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
                    throw RemoteError.message(L("Enter IP:port, for example 192.168.1.20:8443."))
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
                retries = 0
                try await startPeer()
            } catch { message.stringValue = L(error.localizedDescription) }
        }
    }
    private func startPeer() async throws {
        closePeer()
        let generation = UUID(); connectionGeneration = generation
        guard let displayID = selectedDisplay else { throw RemoteError.message(L("Select a display.")) }
        let peer = try RemotePeer(sendingVideo: false)
        self.peer = peer; surface.displayID = displayID
        peer.onVideo = { [weak self] track in guard let self else { return }; track.add(self.surface.renderer) }
        peer.onState = { [weak self, weak peer] state in
            guard let self, let peer, self.peer === peer else { return }
            if state == .connected { self.retries = 0; self.message.stringValue = L("Connected · Click the screen to control · ⌃⌥Esc releases the keyboard") }
            if state == .failed || state == .disconnected {
                self.surface.releaseAll(); self.surface.inputAllowed = false; self.scheduleReconnect()
            }
        }
        let offer = try await peer.makeOffer()
        let answer = try await object("offer", body: ["sdp": offer, "displayID": displayID, "quality": quality.rawValue])
        guard connectionGeneration == generation, let sdp = answer["sdp"] as? String, let id = answer["mediaID"] as? String else {
            throw RemoteError.message(L("Connection canceled or invalid response."))
        }
        mediaID = id
        try await peer.accept(answer: sdp)
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
        surface.releaseAll(); surface.inputAllowed = false
        timer?.invalidate(); timer = nil
        peer?.remoteVideo?.remove(surface.renderer)
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
private final class RemoteDesktopSurface: NSView, RTCVideoViewDelegate {
    let renderer = RTCMTLNSVideoView(frame: .zero)
    var onInput: ((RemoteInput) -> Void)?
    var onRelease: (() -> Void)?
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
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func layout() {
        super.layout()
        let scale = min(bounds.width / max(1, videoSize.width), bounds.height / max(1, videoSize.height))
        let width = videoSize.width * scale, height = videoSize.height * scale
        renderer.frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
    nonisolated func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        Task { @MainActor [weak self] in self?.videoSize = size; self?.needsLayout = true }
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
