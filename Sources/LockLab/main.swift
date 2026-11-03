import VelaLocalization
import AppKit
import CoreGraphics
import IOKit
import IOKit.pwr_mgt

enum IdleObservation {
    static func hidSeconds() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString,
                                                         kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let nanoseconds = value as? NSNumber else { return nil }
        let seconds = nanoseconds.doubleValue / 1_000_000_000
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    static func quartzSeconds() -> Double? {
        // kCGAnyInputEventType is ~0, not CGEventType.null (zero).
        let anyInput = CGEventType(rawValue: UInt32.max)!
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    static func format(_ seconds: Double?) -> String {
        seconds.map { String(format: "%.1fs", $0) } ?? L("Unavailable")
    }
}

enum Mode: Int, CaseIterable {
    case baseline, system, display, activity
    var title: String {
        switch self {
        case .baseline: L("Baseline: no keep-awake request")
        case .system: L("Keep system awake")
        case .display: L("Keep display awake")
        case .activity: L("Declare user activity every 30 seconds")
        }
    }
    var detail: String {
        switch self {
        case .baseline: L("Record data only. Observe when the existing policy starts the screen saver or requires a password.")
        case .system: L("Request PreventUserIdleSystemSleep. Effects on the display and screen saver need real-device testing.")
        case .display: L("Request PreventUserIdleDisplaySleep. Screen savers or managed lock policies may still apply.")
        case .activity: L("Call DeclareUserActivity without sending input events. Effects on the screen saver need real-device testing.")
        }
    }
}

@MainActor
final class PowerSession {
    private(set) var id: IOPMAssertionID?

    func start(_ mode: Mode) throws {
        stop()
        var value = IOPMAssertionID(0)
        let result: IOReturn
        switch mode {
        case .baseline: return
        case .system, .display:
            let type = mode == .system
                ? kIOPMAssertionTypePreventUserIdleSystemSleep
                : kIOPMAssertionTypePreventUserIdleDisplaySleep
            result = IOPMAssertionCreateWithName(type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "LockLab: \(mode.title)" as CFString, &value)
        case .activity:
            result = IOPMAssertionDeclareUserActivity("LockLab: activity experiment" as CFString,
                                                     kIOPMUserActiveLocal, &value)
        }
        guard result == kIOReturnSuccess else { throw failure(result) }
        id = value
    }

    func pulse() throws {
        guard var value = id else { return }
        let result = IOPMAssertionDeclareUserActivity("LockLab: activity experiment" as CFString,
                                                     kIOPMUserActiveLocal, &value)
        guard result == kIOReturnSuccess else { throw failure(result) }
        id = value
    }

    func stop() {
        if let id { IOPMAssertionRelease(id) }
        id = nil
    }

    private func failure(_ code: IOReturn) -> NSError {
        NSError(domain: "LockLab.IOKit", code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: L("Power API failed: {0}", "\(code)")])
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let session = PowerSession()
    var window: NSWindow!
    let modes = NSPopUpButton()
    let durations = NSPopUpButton()
    let detail = NSTextField(wrappingLabelWithString: "")
    let status = NSTextField(labelWithString: L("Not started"))
    let logView = NSTextView()
    var startButton: NSButton!
    var stopButton: NSButton!
    var timer: Timer?
    var started: TimeInterval?
    var lastSample = -10
    var lastPulse = 0
    var activeMode = Mode.baseline
    var duration = 720
    var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        if CommandLine.arguments.contains("--ui-smoke-test") {
            durations.selectItem(at: 2)
            start()
            precondition(!startButton.isEnabled && stopButton.isEnabled && !modes.isEnabled)
            stop()
            precondition(startButton.isEnabled && !stopButton.isEnabled && modes.isEnabled)
            print("PASS: baseline start/stop and control states")
            modes.selectItem(at: Mode.display.rawValue)
            modeChanged()
            start()
            precondition(session.id != nil)
            let verifier = Timer.scheduledTimer(withTimeInterval: 32, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { fatalError("Missing delegate") }
                    precondition(self.started == nil && self.session.id == nil)
                    precondition(self.startButton.isEnabled && !self.stopButton.isEnabled)
                    precondition(self.logView.string.contains(L("Test timer ended")))
                    print("PASS: 30-second timer auto-release and UI reset")
                    NSApp.terminate(nil)
                }
            }
            RunLoop.main.add(verifier, forMode: .common)
            return
        }
        let center = NSWorkspace.shared.notificationCenter
        for (name, label) in [(NSWorkspace.screensDidSleepNotification, L("Display asleep")),
                              (NSWorkspace.screensDidWakeNotification, L("Display awake")),
                              (NSWorkspace.willSleepNotification, L("System will sleep")),
                              (NSWorkspace.didWakeNotification, L("System woke"))] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.append(label + L(" (not equivalent to password locking)")) }
            })
        }
        append(L("Ready. Pause video, quit games, and check other apps' power assertions first."))
        NSApp.activate(ignoringOtherApps: true)
    }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 570),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = L("LockLab · Auto-Lock Experiment")
        window.minSize = NSSize(width: 660, height: 520)
        window.center()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
        let title = NSTextField(labelWithString: L("Auto-Lock Experiment"))
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        stack.addArrangedSubview(title)
        let note = NSTextField(wrappingLabelWithString:
            L("Each run defaults to 12 minutes. Do not use the keyboard or mouse after starting. On wake, record whether a password is required. Stopping or quitting releases this app's keep-awake request."))
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)
        modes.addItems(withTitles: Mode.allCases.map(\.title))
        modes.target = self
        modes.action = #selector(modeChanged)
        durations.addItems(withTitles: [L("12 minutes"), L("20 minutes"), L("30 seconds (debug)")])
        let row = NSStackView(views: [modes, durations])
        row.spacing = 12
        stack.addArrangedSubview(row)
        detail.textColor = .secondaryLabelColor
        stack.addArrangedSubview(detail)
        modeChanged()
        startButton = NSButton(title: L("Start test"), target: self, action: #selector(start))
        stopButton = NSButton(title: L("Stop and release"), target: self, action: #selector(stop))
        stopButton.isEnabled = false
        let snapshot = NSButton(title: L("View power assertions"), target: self, action: #selector(snapshot))
        let actions = NSStackView(views: [startButton, stopButton, snapshot])
        actions.spacing = 10
        stack.addArrangedSubview(actions)
        status.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(status)
        let scroll = VelaScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        logView.isEditable = false
        logView.isSelectable = true
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textContainerInset = NSSize(width: 8, height: 8)
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = false
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true
        scroll.documentView = logView
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        let foot = NSTextField(wrappingLabelWithString:
            L("Control test: press ⌃⌘Q during a run. Manual locking should still require authentication. Power assertions, screen savers, display sleep, and password locking are different states. Logs can be selected and copied."))
        foot.textColor = .secondaryLabelColor
        stack.addArrangedSubview(foot)
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Quit LockLab"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem()
        item.submenu = appMenu
        menu.addItem(item)
        let editMenu = NSMenu(title: L("Edit"))
        editMenu.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Select all"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: L("Edit"), action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        if !CommandLine.arguments.contains("--ui-smoke-test") { window.makeKeyAndOrderFront(nil) }
    }

    @objc func modeChanged() {
        detail.stringValue = (Mode(rawValue: modes.indexOfSelectedItem) ?? .baseline).detail
    }

    @objc func start() {
        activeMode = Mode(rawValue: modes.indexOfSelectedItem) ?? .baseline
        duration = [720, 1200, 30][durations.indexOfSelectedItem]
        do { try session.start(activeMode) }
        catch { append(error.localizedDescription); return }
        started = ProcessInfo.processInfo.systemUptime
        lastSample = -10
        lastPulse = 0
        startButton.isEnabled = false
        stopButton.isEnabled = true
        modes.isEnabled = false
        durations.isEnabled = false
        append(L("Started: {0}, duration {1}s, assertion ID: {2}", "\(activeMode.title)", "\(duration)", "\(session.id.map(String.init) ?? L("None"))"))
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func tick() {
        guard let started else { return }
        let elapsed = Int(ProcessInfo.processInfo.systemUptime - started)
        if elapsed >= duration { stop(); append(L("Test timer ended. Request released.")); return }
        if activeMode == .activity && elapsed - lastPulse >= 30 {
            do { try session.pulse(); lastPulse = elapsed; append(L("User activity declared")) }
            catch { append(error.localizedDescription); stop(); return }
        }
        let hid = IdleObservation.format(IdleObservation.hidSeconds())
        let quartz = IdleObservation.format(IdleObservation.quartzSeconds())
        status.stringValue = L("Elapsed {0}s  ·  Remaining {1}s  ·  HID idle {2}", "\(elapsed)", "\(duration - elapsed)", "\(hid)")
        if elapsed - lastSample >= 10 {
            append(L("Elapsed {0}s; HID idle {1}; Quartz input idle {2} (neither is the lock timer)", "\(elapsed)", "\(hid)", "\(quartz)"))
            lastSample = elapsed
        }
    }

    @objc func stop() {
        timer?.invalidate()
        timer = nil
        session.stop()
        if started != nil { append(L("Stopped: app assertion released")) }
        started = nil
        status.stringValue = L("Not running · No keep-awake request from this app")
        startButton.isEnabled = true
        stopButton.isEnabled = false
        modes.isEnabled = true
        durations.isEnabled = true
    }

    @objc func snapshot() {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            append(String(data: data, encoding: .utf8) ?? L("Unable to decode power assertion output"))
        } catch { append(error.localizedDescription) }
    }

    func append(_ message: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        let line = "[\(time)] \(message)\n"
        logView.textStorage?.append(NSAttributedString(string: line,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: NSColor.labelColor]))
        if logView.string.count > 100_000 { logView.textStorage?.deleteCharacters(in: NSRange(location: 0, length: 20_000)) }
        logView.scrollToEndOfDocument(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        session.stop()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

// Short integration check: real IOKit calls, released before returning. No input events or lock actions.
if CommandLine.arguments.contains("--idle-sample") {
    print("HIDIdleTime: \(IdleObservation.format(IdleObservation.hidSeconds()))")
    print("Quartz any input: \(IdleObservation.format(IdleObservation.quartzSeconds()))")
} else if CommandLine.arguments.contains("--smoke-test") {
    let session = PowerSession()
    do {
        for mode in Mode.allCases {
            try session.start(mode)
            if mode == .baseline { precondition(session.id == nil) }
            else { precondition(session.id != nil) }
            if mode == .activity { try session.pulse() }
            let releasedID = session.id
            if let id = session.id {
                guard let properties = IOPMAssertionCopyProperties(id)?.takeRetainedValue() else {
                    fatalError("Created assertion missing in power management service")
                }
                let dictionary = properties as NSDictionary
                let expected = switch mode {
                case .baseline: ""
                case .system: "PreventUserIdleSystemSleep"
                case .display: "PreventUserIdleDisplaySleep"
                case .activity: "UserIsActive"
                }
                precondition(dictionary["AssertType"] as? String == expected)
                precondition((dictionary["AssertLevel"] as? NSNumber)?.intValue == Int(kIOPMAssertionLevelOn))
            }
            print("PASS: \(mode.title)")
            session.stop()
            precondition(session.id == nil)
            if let id = releasedID { precondition(IOPMAssertionCopyProperties(id) == nil) }
        }
        print("PASS: all assertions released")
    } catch {
        fputs("FAIL: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(CommandLine.arguments.contains("--ui-smoke-test") ? .prohibited : .regular)
    app.run()
}
