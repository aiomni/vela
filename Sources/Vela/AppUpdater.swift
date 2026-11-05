import AppKit
import AppUpdateCore
import VelaLocalization

@MainActor
final class AppUpdater: NSObject {
    enum State { case idle, checking, current, available, downloading, failed, unavailable, rateLimited }
    let button = NSButton(title: L("Check for Updates…"), target: nil, action: nil)
    let automaticSwitch = SettingsStyle.compactSwitch()
    let detail = SettingsStyle.note("")
    private(set) var state: State = .idle
    private var update: ReleaseUpdate?
    private let service = ReleaseUpdateService()
    private let defaults: UserDefaults
    private var timer: Timer?
    private let appURL: URL
    private let version: String
    var onChange: (() -> Void)?
    var updateAvailable: Bool { state == .available }
    private var busy = false

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        appURL = bundle.bundleURL
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        super.init()
        button.bezelStyle = .rounded
        button.target = self; button.action = #selector(performAction)
        automaticSwitch.target = self; automaticSwitch.action = #selector(toggleAutomatic)
        refreshUI()
    }

    var automatic: Bool { defaults.object(forKey: "velaAutomaticallyCheckUpdates") as? Bool ?? true }

    func start() {
        guard appURL.pathExtension == "app" else { return }
        checkIfDue()
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func checkIfDue() {
        guard automatic, Date().timeIntervalSince1970 - defaults.double(forKey: "velaLastUpdateCheck") >= 86400 else { return }
        check()
    }

    @objc private func toggleAutomatic() {
        defaults.set(automaticSwitch.state == .on, forKey: "velaAutomaticallyCheckUpdates")
        if automatic { checkIfDue() }
    }

    func reset() {
        defaults.removeObject(forKey: "velaAutomaticallyCheckUpdates")
        defaults.removeObject(forKey: "velaLastUpdateCheck")
        refreshUI()
    }

    func check() {
        guard !busy else { return }
        busy = true; state = .checking; refreshUI()
        Task {
            defer { busy = false; refreshUI() }
            do {
                update = try await service.check(currentVersion: version)
                state = update == nil ? .current : .available
                defaults.set(Date().timeIntervalSince1970, forKey: "velaLastUpdateCheck")
            } catch UpdateError.rateLimited {
                state = .rateLimited
            } catch UpdateError.noSignedAsset {
                update = nil; state = .unavailable
                defaults.set(Date().timeIntervalSince1970, forKey: "velaLastUpdateCheck")
            } catch {
                state = .failed
            }
        }
    }

    @objc private func performAction() {
        guard let update, state == .available else { check(); return }
        busy = true; state = .downloading; refreshUI()
        Task {
            var stagedCandidate: URL?
            var handedOff = false
            defer {
                if !handedOff, let candidate = stagedCandidate {
                    UpdateInstaller.discardCandidate(candidate)
                }
            }
            do {
                let candidate = try await service.prepare(update, installedApp: appURL)
                stagedCandidate = candidate
                // Close the bundled controller before replacing its files.
                let controllers = NSRunningApplication.runningApplications(withBundleIdentifier: "app.aiomni.awakepet.remoteviewer")
                for controller in controllers { controller.terminate() }
                for _ in 0..<100 {
                    if controllers.allSatisfy(\.isTerminated) { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard controllers.allSatisfy(\.isTerminated) else {
                    UpdateInstaller.discardCandidate(candidate)
                    throw UpdateError.appStillRunning
                }
                let helper = Process()
                helper.executableURL = candidate.appendingPathComponent("Contents/MacOS/Vela")
                helper.arguments = ["--install-update", appURL.path, String(ProcessInfo.processInfo.processIdentifier)]
                helper.standardOutput = FileHandle.nullDevice
                helper.standardError = FileHandle.nullDevice
                try helper.run()
                let ready = candidate.deletingLastPathComponent().appendingPathComponent("updater-ready")
                for _ in 0..<100 {
                    if FileManager.default.fileExists(atPath: ready.path) || !helper.isRunning { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard helper.isRunning, FileManager.default.fileExists(atPath: ready.path) else {
                    throw UpdateError.processFailed
                }
                handedOff = true
                // Normal termination releases assertions, input, and physical display recovery.
                NSApp.terminate(nil)
            } catch {
                busy = false; state = .failed; refreshUI()
            }
        }
    }

    func refreshUI() {
        automaticSwitch.state = automatic ? .on : .off
        automaticSwitch.setAccessibilityLabel(L("Automatically check for updates"))
        button.isEnabled = !busy
        switch state {
        case .idle:
            button.title = L("Check for Updates…")
            detail.stringValue = L("Version {0}. Updates are downloaded from GitHub Releases.", version)
        case .checking:
            button.title = L("Checking…")
            detail.stringValue = L("Checking GitHub Releases for a newer version…")
        case .current:
            button.title = L("Check for Updates…")
            detail.stringValue = L("Vela {0} is up to date.", version)
        case .available:
            button.title = L("Install and Restart")
            detail.stringValue = L("Vela {0} is available. Installing restarts Vela and disconnects remote sessions.", update?.version ?? "")
        case .downloading:
            button.title = L("Downloading…")
            detail.stringValue = L("Downloading and verifying the update before restarting…")
        case .unavailable:
            button.title = L("Check for Updates…")
            detail.stringValue = L("A newer release is available, but its signed update package is not ready yet.")
        case .rateLimited:
            button.title = L("Check for Updates…")
            detail.stringValue = L("GitHub's update check limit has been reached. Try again later.")
        case .failed:
            button.title = L("Check for Updates…")
            detail.stringValue = L("Update failed. Try again, or download the app from GitHub Releases. Install Vela in a writable Applications folder first.")
        }
        button.setAccessibilityLabel(button.title)
        onChange?()
    }
}

@MainActor
func runUpdateInstallerIfRequested() {
    let arguments = CommandLine.arguments
    guard arguments.contains("--install-update") else { return }
    guard arguments.count == 4, arguments[1] == "--install-update",
          let pid = Int32(arguments[3]), pid > 1, pid != ProcessInfo.processInfo.processIdentifier else { exit(1) }
    let destination = URL(fileURLWithPath: arguments[2], isDirectory: true)
    do {
        let candidate = Bundle.main.bundleURL
        try UpdateInstaller.validateLocation(destination)
        let identity = try UpdateSigningIdentity.read(from: destination)
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            throw UpdateError.invalidBundle
        }
        try UpdateInstaller.validateBundle(candidate, version: version, identity: identity)
        try Data().write(to: candidate.deletingLastPathComponent().appendingPathComponent("updater-ready"), options: .atomic)
        try UpdateInstaller.install(candidate: candidate, destination: destination, parentPID: pid)
        exit(0)
    } catch {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let alert = NSAlert()
        alert.messageText = L("Update could not be installed")
        alert.informativeText = L("Try again, or download Vela from GitHub Releases. The update requires the same signing certificate and a writable Applications folder.")
        alert.addButton(withTitle: L("OK"))
        app.activate(ignoringOtherApps: true)
        alert.runModal()
        if kill(pid, 0) != 0 { _ = try? UpdateInstaller.run("/usr/bin/open", [destination.path]) }
        exit(1)
    }
}
