import VelaLocalization
import AppKit
import RemoteServer
import RemoteCore

@MainActor
final class RemoteSettingsController: NSObject {
    let view = NSStackView()
    private let enabledButton = SettingsStyle.compactSwitch()
    private let portField = NSTextField(string: "8443")
    private let applyPortButton = NSButton(title: L("Apply port"), target: nil, action: nil)
    private let listenModeButton = NSPopUpButton()
    private let authenticationButton = NSPopUpButton()
    private let accountLabel = NSTextField(wrappingLabelWithString: "")
    private let authenticator = RemoteAuthenticator()
    private let passwordButton = NSButton(title: L("Set access password…"), target: nil, action: nil)
    private let permissionButton = NSButton(title: L("Open settings…"), target: nil, action: nil)
    private let disconnectButton = NSButton(title: L("Disconnect all sessions"), target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: L("Remote control is off"))
    private let addressLabel = NSTextField(wrappingLabelWithString: L("Enable to show connection addresses"))
    private let permissionLabel = NSTextField(wrappingLabelWithString: "")
    private let certificateLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let helpLabel = SettingsStyle.note("")
    private let files: RemoteFiles
    private let service: RemoteHostService?
    private var timer: Timer?
    private var busy = false
    private var lastGeneration: String?
    private var lastEnabled: Bool?

    init(files: RemoteFiles = RemoteFiles(), service: RemoteHostService? = nil) {
        self.files = files
        self.service = service
        super.init()
        view.orientation = .vertical; view.alignment = .leading; view.spacing = 10
        enabledButton.setAccessibilityLabel(L("Enable local network remote control"))
        enabledButton.target = self; enabledButton.action = #selector(toggle)
        authenticationButton.addItems(withTitles: [L("Custom password"), L("macOS account")])
        authenticationButton.target = self; authenticationButton.action = #selector(changeAuthentication)
        authenticationButton.setAccessibilityLabel(L("Remote authentication method"))
        authenticationButton.widthAnchor.constraint(equalToConstant: 190).isActive = true
        portField.widthAnchor.constraint(equalToConstant: 75).isActive = true
        portField.setAccessibilityLabel(L("Remote control port"))
        applyPortButton.target = self; applyPortButton.action = #selector(applyPort)
        passwordButton.target = self; passwordButton.action = #selector(changePassword)
        let portControls = NSStackView(views: [portField, applyPortButton]); portControls.spacing = 8
        listenModeButton.addItems(withTitles: [L("LAN interfaces only"), L("All IPv4 interfaces (0.0.0.0)")])
        listenModeButton.setAccessibilityLabel(L("Remote listening scope"))
        listenModeButton.widthAnchor.constraint(equalToConstant: 240).isActive = true
        listenModeButton.target = self; listenModeButton.action = #selector(changeListenMode)
        for popup in [authenticationButton, listenModeButton] {
            popup.isBordered = false; popup.alignment = .right; popup.cell?.alignment = .right
        }
        for label in [statusLabel, addressLabel, permissionLabel, certificateLabel, errorLabel, accountLabel] {
            label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
            label.isSelectable = true
        }
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        addressLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        certificateLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        errorLabel.textColor = .systemOrange
        permissionButton.target = self; permissionButton.action = #selector(requestPermissions)
        permissionButton.setAccessibilityLabel(L("Open remote control permission settings"))
        disconnectButton.target = self; disconnectButton.action = #selector(disconnect)
        let copy = NSButton(title: L("Copy address"), target: self, action: #selector(copyAddress))
        let browser = NSButton(title: L("Connect in browser"), target: self, action: #selector(openBrowser))
        let viewer = NSButton(title: L("Open Vela Connect…"), target: self, action: #selector(openViewer))
        let connections = NSStackView(views: [copy, browser, NSView()]); connections.spacing = 8
        let trust = NSButton(title: L("View / trust local certificate…"), target: self, action: #selector(openCertificate))
        let export = NSButton(title: L("Export public certificate…"), target: self, action: #selector(exportCertificate))
        for section in [
            SettingsStyle.group([SettingsStyle.row(L("Remote control"), enabledButton),
                                 SettingsStyle.block([statusLabel, addressLabel, connections]),
                                 SettingsStyle.row(L("Native controller"), viewer)]),
            SettingsStyle.group([SettingsStyle.row(L("Authentication"), authenticationButton),
                                 SettingsStyle.block([accountLabel]),
                                 SettingsStyle.row(L("Access password"), passwordButton)]),
            SettingsStyle.group([SettingsStyle.row(L("Port"), portControls),
                                 SettingsStyle.row(L("Listen on"), listenModeButton)]),
            SettingsStyle.note(L("All interfaces allows LAN and VPN connections. Use this Mac's actual connection address.")),
            SettingsStyle.heading(L("Permissions")),
            SettingsStyle.group([SettingsStyle.row(SettingsPrivacy.controlTitle, permissionButton,
                                    detail: permissionLabel),
                                 SettingsStyle.row(L("Sessions"), disconnectButton)]),
            SettingsStyle.note(L("Allows remote keyboard and mouse control. Screen Recording is also required to share the desktop.")),
            SettingsStyle.group([SettingsStyle.block([certificateLabel]),
                                 SettingsStyle.row(L("Certificate"), trust),
                                 SettingsStyle.row(L("Public certificate"), export)]),
            errorLabel, helpLabel
        ] {
            view.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }
    func refresh() {
        guard !busy else { return }
        helpLabel.stringValue = L("Connect using IP:port and the password for the selected authentication method. System authentication accepts only the local account running Vela and does not itself unlock the screen. Grant Vela Screen Recording and {0} access, then quit and reopen it if macOS requests it. Remote control starts and stops with Vela; its enabled setting is saved. Hiding the companion or closing Settings keeps Vela running. Browsers require certificate trust; Vela Connect asks you to verify its fingerprint.", SettingsPrivacy.controlTitle)
        do {
            let config = try files.load()
            enabledButton.state = config.enabled ? .on : .off
            if lastGeneration != config.generation {
                portField.stringValue = String(config.port)
                lastGeneration = config.generation
            }
            listenModeButton.selectItem(at: config.listenOnAllInterfaces ? 1 : 0)
            authenticationButton.selectItem(at: config.authenticationMode == .customPassword ? 0 : 1)
            passwordButton.isEnabled = config.authenticationMode == .customPassword
            accountLabel.stringValue = config.authenticationMode == .macOSAccount
                ? L("Only local account {0}, which runs Vela, is allowed. Use that account's login password. The password is not saved; other accounts and Touch ID are not supported. The system lock screen accepts password entry over an established connection.", "\(config.systemAccount?.shortName ?? L("Unknown"))")
                : L("Use a separate Vela password. Changing authentication disconnects and revokes sessions; it does not automatically enable remote control.")
            passwordButton.title = config.password == nil ? L("Set access password…") : L("Change access password…")
            let status = service?.status ?? files.status()
            if config.enabled {
                statusLabel.stringValue = status.map { L($0.message) } ?? L("Waiting for the Vela remote service…")
                addressLabel.stringValue = status?.addresses.joined(separator: "\n") ?? L("Addresses appear after the service starts")
            } else {
                statusLabel.stringValue = L("Remote control is off")
                addressLabel.stringValue = L("Enable to show connection addresses")
            }
            permissionLabel.stringValue = L("Input control: {0}\nScreen Recording: {1}",
                CGPreflightPostEventAccess() ? L("Granted") : L("Not granted"),
                CGPreflightScreenCaptureAccess() ? L("Granted") : L("Not granted"))
            if let fingerprint = status?.fingerprint {
                certificateLabel.stringValue = L("Certificate SHA-256:\n{0}", "\(fingerprint)")
            } else { certificateLabel.stringValue = L("The TLS certificate is generated when the service starts.") }
            disconnectButton.isEnabled = config.enabled
            if lastEnabled != config.enabled { lastEnabled = config.enabled }
        } catch { errorLabel.stringValue = L(error.localizedDescription) }
    }
    private func ensureHost() throws {
        guard service != nil else { throw RemoteError.message(L("The remote service is not running. Quit and reopen Vela.")) }
    }
    @objc private func toggle() {
        errorLabel.stringValue = ""
        do {
            var config = try files.load()
            let enable = enabledButton.state == .on
            if enable && config.authenticationMode == .customPassword && config.password == nil {
                enabledButton.state = .off
                setPassword(enableAfterSaving: true)
                return
            }
            if enable { try ensureHost() }
            config.enabled = enable; config.generation = UUID().uuidString
            try files.save(config)
            refresh()
        } catch { errorLabel.stringValue = L(error.localizedDescription); refresh() }
    }
    @objc private func applyPort() {
        do {
            guard let port = Int(portField.stringValue) else { throw RemoteError.message(L("Enter a valid port number.")) }
            var config = try files.load(); config.port = port; config.generation = UUID().uuidString
            try files.save(config); errorLabel.stringValue = ""; refresh()
        } catch { errorLabel.stringValue = L(error.localizedDescription) }
    }
    @objc private func changeListenMode() {
        do {
            var config = try files.load()
            config.listenOnAllInterfaces = listenModeButton.indexOfSelectedItem == 1
            config.generation = UUID().uuidString
            try files.save(config)
            errorLabel.stringValue = L("Listening scope saved. Use an actual connection address shown below.")
            refresh()
        } catch { errorLabel.stringValue = L(error.localizedDescription); refresh() }
    }
    @objc private func changeAuthentication() {
        let mode: RemoteAuthenticationMode = authenticationButton.indexOfSelectedItem == 1 ? .macOSAccount : .customPassword
        busy = true; authenticationButton.isEnabled = false; enabledButton.isEnabled = false; passwordButton.isEnabled = false
        Task {
            defer { busy = false; authenticationButton.isEnabled = true; enabledButton.isEnabled = true; refresh() }
            do {
                let authenticator = self.authenticator
                let account = mode == .macOSAccount
                    ? try await Task.detached { try authenticator.selectableSystemAccount() }.value : nil
                var config = try files.load()
                try config.selectAuthentication(mode, account: account)
                try files.save(config)
                errorLabel.stringValue = L("Authentication method saved. Existing logins and connections will be revoked.")
            } catch { errorLabel.stringValue = L("Unable to change authentication. Check the local account. Existing settings were preserved.") }
        }
    }
    @objc private func changePassword() { setPassword(enableAfterSaving: false) }
    private func setPassword(enableAfterSaving: Bool) {
        guard (try? files.load().authenticationMode) == .customPassword else { return }
        let alert = NSAlert()
        alert.messageText = L("Set remote access password")
        alert.informativeText = L("At least 10 characters. Changing it disconnects all sessions. The password is never stored as plain text.")
        alert.addButton(withTitle: L("Save")); alert.addButton(withTitle: L("Cancel"))
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 38, width: 320, height: 24))
        password.placeholderString = L("New access password")
        let confirmation = NSSecureTextField(frame: NSRect(x: 0, y: 4, width: 320, height: 24))
        confirmation.placeholderString = L("Confirm password")
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 68))
        accessory.addSubview(password); accessory.addSubview(confirmation); alert.accessoryView = accessory
        alert.window.initialFirstResponder = password
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard password.stringValue == confirmation.stringValue else { errorLabel.stringValue = L("The passwords do not match."); return }
        let secret = password.stringValue
        password.stringValue = ""; confirmation.stringValue = ""
        busy = true; enabledButton.isEnabled = false; passwordButton.isEnabled = false; authenticationButton.isEnabled = false
        Task {
            defer { busy = false; enabledButton.isEnabled = true; passwordButton.isEnabled = true; authenticationButton.isEnabled = true; refresh() }
            do {
                let verifier = try await Task.detached(priority: .userInitiated) { try PasswordVerifier(password: secret) }.value
                var config = try files.load()
                config.password = verifier; config.generation = UUID().uuidString
                if enableAfterSaving { try ensureHost(); config.enabled = true }
                try files.save(config); errorLabel.stringValue = ""
            } catch { errorLabel.stringValue = L(error.localizedDescription) }
        }
    }
    @objc private func requestPermissions() {
        service?.requestPermissions()
        SettingsPrivacy.open("Privacy_Accessibility")
        errorLabel.stringValue = L("Grant Vela screen and remote control access in System Settings → Privacy & Security. Quit and reopen Vela if macOS requests it.")
    }
    @objc private func disconnect() {
        do { var config = try files.load(); config.disconnectGeneration += 1; try files.save(config) }
        catch { errorLabel.stringValue = L(error.localizedDescription) }
    }
    @objc private func copyAddress() {
        guard let address = files.status()?.addresses.first else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address, forType: .string)
    }
    @objc private func openBrowser() {
        guard let address = files.status()?.addresses.first, let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func openViewer() {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Applications/VelaConnect.app")
        guard FileManager.default.fileExists(atPath: url.path) else { errorLabel.stringValue = L("Vela Connect is missing from this bundle. Rebuild the app."); return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
    }
    @objc private func openCertificate() {
        guard FileManager.default.fileExists(atPath: files.certificateURL.path) else { errorLabel.stringValue = L("Enable the service first to generate a certificate."); return }
        NSWorkspace.shared.open(files.certificateURL)
        errorLabel.stringValue = L("Verify the certificate fingerprint in Keychain Access. Trust it only on controller devices you trust.")
    }
    @objc private func exportCertificate() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Vela-Remote.crt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(contentsOf: files.certificateURL).write(to: url, options: .atomic); errorLabel.stringValue = L("Public certificate exported. It does not include the private key.") }
        catch { errorLabel.stringValue = L(error.localizedDescription) }
    }
    func reset() throws {
        var config = RemoteConfiguration()
        config.generation = UUID().uuidString
        try files.save(config)
        refresh()
    }
}

/// Isolated visual QA entry point: it does not create a pet, register shortcuts,
/// acquire power assertions, or enable the remote listener.
@MainActor
final class RemoteSettingsReview: NSObject, NSApplicationDelegate {
    private let controller = RemoteSettingsController()
    private var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 650),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("Vela Remote Settings Review")
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        content.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            controller.view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            controller.view.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)
        ])
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
