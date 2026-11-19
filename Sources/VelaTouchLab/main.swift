import AppKit
import TouchLabCore

struct Options {
    enum Mode: String { case probe = "--probe", activateProbe = "--activate-probe", receiver = "--receiver-only", run = "--run" }
    let mode: Mode
    let displayID: CGDirectDisplayID?
    let requireVelaDisplay: Bool
    let duration: Int
    let output: String?
    static let usage = """
    VelaTouchLab --probe [--vela-virtual-display] [--display-id ID] [--output NEW.json]
    VelaTouchLab --activate-probe [--vela-virtual-display] [--display-id ID] [--duration 2..120] [--output NEW.json]
    VelaTouchLab --receiver-only [--vela-virtual-display] [--display-id ID] [--duration 2..120] [--output NEW.json]
    VelaTouchLab --run --isolated-desktop [--vela-virtual-display] [--display-id ID] [--duration 15..120] [--output NEW.json]

    --probe: attempts CoreHID initialization, no activation/reports/window/TCC request.
    --activate-probe: activation, enumeration and own-device Feature Get; ZERO input reports.
    --receiver-only: opens a bounded native test window, creates no HID device.
    --run: creates/activates HID and sends SYSTEM-WIDE input at intended test coordinates.
    --isolated-desktop: required acknowledgment of an isolated, non-sensitive test desktop.
    --vela-virtual-display: require an existing active, unmirrored Vela virtual display.
    Use --display-id to select one when multiple Vela displays are active.
    Experimental display properties may be ignored, delivering input to unrelated UI.
    Do not touch the mouse/trackpad during --run. Focus loss aborts with release.
    No network host, private Sidecar API, driver install, signing or permission changes.
    --output must name a file that does not exist; stdout also contains JSON evidence.
    """
    init(_ arguments: [String]) throws {
        guard let first = arguments.first, let mode = Mode(rawValue: first) else {
            throw NSError(domain: "VelaTouchLab.Options", code: 1)
        }
        var displayID: CGDirectDisplayID?, duration = 15, output: String?
        var index = 1, seen: Set<String> = []
        var isolatedDesktop = false, requireVelaDisplay = false
        while index < arguments.count {
            let key = arguments[index]
            if key == "--isolated-desktop" {
                guard mode == .run, seen.insert(key).inserted else { throw NSError(domain: "VelaTouchLab.Options", code: 7) }
                isolatedDesktop = true
                index += 1
                continue
            }
            if key == "--vela-virtual-display" {
                guard seen.insert(key).inserted else { throw NSError(domain: "VelaTouchLab.Options", code: 9) }
                requireVelaDisplay = true
                index += 1
                continue
            }
            guard index + 1 < arguments.count, seen.insert(key).inserted else {
                throw NSError(domain: "VelaTouchLab.Options", code: 2)
            }
            let value = arguments[index + 1]
            switch key {
            case "--display-id":
                guard let id = UInt32(value), id != 0 else { throw NSError(domain: "VelaTouchLab.Options", code: 3) }
                displayID = id
            case "--duration":
                guard let seconds = Int(value), (2...120).contains(seconds), mode != .run || seconds >= 15 else {
                    throw NSError(domain: "VelaTouchLab.Options", code: 4)
                }
                duration = seconds
            case "--output":
                guard !value.isEmpty, !FileManager.default.fileExists(atPath: value) else {
                    throw NSError(domain: "VelaTouchLab.Options", code: 5)
                }
                output = value
            default: throw NSError(domain: "VelaTouchLab.Options", code: 6)
            }
            index += 2
        }
        guard mode != .run || isolatedDesktop else { throw NSError(domain: "VelaTouchLab.Options", code: 8) }
        self.mode = mode; self.displayID = displayID; self.duration = duration; self.output = output
        self.requireVelaDisplay = requireVelaDisplay
    }
}

@MainActor
final class LabController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let options: Options
    let evidence = TouchEvidence()
    var receiver: TouchReceiver?
    var hid: VirtualTouchscreen?
    var task: Task<Void, Never>?
    var stopping = false
    var watchdog: Task<Void, Never>?
    init(options: Options) { self.options = options }

    func applicationDidFinishLaunching(_ notification: Notification) {
        task = Task { await execute() }
        watchdog = Task {
            do {
                try await Task.sleep(for: .seconds(options.duration + (options.mode == .receiver ? 1 : 0)))
                evidence.values["watchdogTriggered"] = true
                task?.cancel()
                try await Task.sleep(for: .seconds(3))
                // A stalled CoreHID await must not keep a virtual device alive indefinitely.
                // Process exit closes the user client; do not claim successful lift delivery.
                evidence.values["emergencyProcessTeardown"] = true
                evidence.values["nativeTouchAndGesturesVerified"] = false
                evidence.values["exitCode"] = 6
                try? evidence.finish(output: options.output)
                Darwin.exit(6)
            } catch { }
        }
    }
    func applicationDidResignActive(_ notification: Notification) {
        if options.mode == .run { task?.cancel() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { task?.cancel(); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if stopping { return .terminateNow }
        task?.cancel()
        return .terminateCancel
    }

    private func selectScreen() throws -> NSScreen {
        let screenNumber = NSDeviceDescriptionKey("NSScreenNumber")
        let candidates = NSScreen.screens.filter { screen in
            guard let id = screen.deviceDescription[screenNumber] as? CGDirectDisplayID else { return false }
            if let requested = options.displayID, id != requested { return false }
            return !options.requireVelaDisplay || Self.isActiveVelaDisplay(id)
        }
        if options.requireVelaDisplay {
            evidence.values["eligibleVelaDisplayIDs"] = candidates.compactMap {
                $0.deviceDescription[screenNumber] as? CGDirectDisplayID
            }
            guard candidates.count == 1, let screen = candidates.first else {
                let reason = candidates.isEmpty
                    ? "No matching active, unmirrored Vela virtual display. Create one in Vela's Display panel."
                    : "Multiple active Vela virtual displays. Choose one with --display-id."
                throw NSError(domain: "VelaTouchLab.VelaDisplay", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: reason])
            }
            return screen
        }
        guard let screen = options.displayID == nil ? NSScreen.main : candidates.first else {
            throw NSError(domain: "VelaTouchLab.NoDisplay", code: 1)
        }
        return screen
    }

    private static func isActiveVelaDisplay(_ id: CGDirectDisplayID) -> Bool {
        // Match the descriptor in RemoteDisplayBridge and the ownership lookup in VirtualDisplay.
        CGDisplayIsActive(id) != 0 && CGDisplayIsInMirrorSet(id) == 0 &&
            CGDisplayVendorNumber(id) == 0x4157 && CGDisplayModelNumber(id) == 1 && CGDisplaySerialNumber(id) != 0
    }

    private func execute() async {
        evidence.values["mode"] = options.mode.rawValue
        evidence.values["scope"] = "Isolated CoreHID/AppKit prototype. No remote host, TCC requests, private APIs, signing, driver installation or display/power changes."
        var exitCode: Int32 = 0
        do {
            if options.mode == .run {
                guard #available(macOS 27, *) else { throw NSError(domain: "VelaTouchLab.RequiresMacOS27", code: 1) }
            }
            evidence.values["velaDisplayRequired"] = options.requireVelaDisplay
            let screen = try selectScreen()
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else {
                throw NSError(domain: "VelaTouchLab.NoDisplay", code: 1)
            }
            evidence.values["selectedDisplayID"] = displayID
            evidence.values["selectedActiveVelaDisplay"] = Self.isActiveVelaDisplay(displayID)
            evidence.values["selectedDisplayFramePoints"] = ["x": screen.frame.minX, "y": screen.frame.minY,
                "width": screen.frame.width, "height": screen.frame.height]
            evidence.values["backingScaleFactor"] = screen.backingScaleFactor
            if options.mode != .receiver {
                hid = VirtualTouchscreen(evidence: evidence)
                hid?.create(displayID: displayID)
                guard evidence.values["deviceCreated"] as? Bool == true else {
                    exitCode = 2
                    await finish(exitCode: exitCode)
                    return
                }
                if options.mode == .probe {
                    await finish(exitCode: 0)
                    return
                }
            }
            if options.mode == .activateProbe {
                guard await hid?.activate() == true else { throw NSError(domain: "VelaTouchLab.Activation", code: 1) }
                try await Task.sleep(for: .milliseconds(500))
                hid?.recordEnumeration()
                let verified = await hid?.inspectWithoutInput() ?? false
                await finish(exitCode: verified ? 0 : 3)
                return
            }
            let testReceiver = TouchReceiver(screen: screen, evidence: evidence)
            receiver = testReceiver
            testReceiver.window.delegate = self
            testReceiver.show()
            let receiverDisplayID = testReceiver.window.screen?
                .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            evidence.values["receiverDisplayID"] = receiverDisplayID
            let receiverOnTarget = receiverDisplayID == displayID && screen.visibleFrame.contains(testReceiver.window.frame)
            evidence.values["receiverFitsSelectedDisplay"] = receiverOnTarget
            if options.requireVelaDisplay || options.mode == .run {
                guard receiverOnTarget else {
                    throw NSError(domain: "VelaTouchLab.Display", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "The test window must fit inside the selected display."])
                }
            }
            if options.mode == .receiver {
                try await Task.sleep(for: .seconds(options.duration))
            } else {
                let activated = await hid?.activate() ?? false
                guard activated else { throw NSError(domain: "VelaTouchLab.Activation", code: 1) }
                try await Task.sleep(for: .seconds(2))
                hid?.recordEnumeration()
                guard evidence.values["deviceEnumerated"] as? Bool == true else {
                    throw NSError(domain: "VelaTouchLab.Enumeration", code: 1)
                }
                guard await hid?.inspectWithoutInput() == true else {
                    throw NSError(domain: "VelaTouchLab.NoInputInspection", code: 1)
                }
                try await runSequence(displayID: displayID)
                try await Task.sleep(for: .seconds(1))
                func count(_ key: String) -> Int { evidence.values[key] as? Int ?? 0 }
                let direct = count("directTouchBegan") == 4 && count("directTouchEnded") == 4 &&
                    count("directTouchCancelled") == 0 && count("pendingNativeContacts") == 0 &&
                    count("matched.directTouchBegan.scroll") == 1 && count("matched.directTouchEnded.scroll") == 1 &&
                    count("matched.directTouchMoved.scroll") >= 3 &&
                    count("matched.directTouchBegan.pinch") == 2 && count("matched.directTouchEnded.pinch") == 2 &&
                    count("matched.directTouchMoved.pinch") >= 6 &&
                    count("matched.directTouchBegan.release") == 1 && count("matched.directTouchEnded.release") == 1
                evidence.values["expectedNativeLifecycleObserved"] = direct
                evidence.values["causalAttributionLimit"] = "Coordinates/stages correlate with generated reports, but AppKit does not expose an authenticated HID source identity. Isolated desktop and no physical input are required."
                let verified = direct && evidence.values["scrollOriginChanged"] as? Bool == true &&
                    evidence.values["directPinchRecognized"] as? Bool == true
                evidence.values["nativeTouchAndGesturesVerified"] = verified
                if !verified { exitCode = 3 }
            }
        } catch {
            evidence.values["runError"] = String(describing: error)
            exitCode = 4
        }
        await finish(exitCode: exitCode)
    }

    private func runSequence(displayID: CGDirectDisplayID) async throws {
        guard let receiver, let hid else { return }
        let originalFrame = receiver.window.frame
        let started = ContinuousClock().now
        func send(_ points: [(UInt8, CGFloat, CGFloat)], touching: Bool = true) async throws {
            try Task.checkCancellation()
            guard started.duration(to: ContinuousClock().now) < .seconds(options.duration),
                  !options.requireVelaDisplay || Self.isActiveVelaDisplay(displayID),
                  receiver.safeToSend(displayID: displayID, originalFrame: originalFrame) else {
                throw NSError(domain: "VelaTouchLab.SafetyAbort", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Focus, console, display, geometry or time-limit changed; releasing contacts."])
            }
            let contacts = try points.map { id, x, y -> TouchscreenReport.Contact in
                let point = try receiver.pointOnDisplay(NSPoint(x: x, y: y), displayID: displayID)
                return .init(id: id, x: point.x, y: point.y, touching: touching)
            }
            try await hid.send(contacts)
            try await Task.sleep(for: .milliseconds(25))
        }
        evidence.stage = "scroll"
        receiver.resetScrollBaseline()
        for step in 0...40 {
            try await send([(1, 320, 120 + CGFloat(step) * 3)])
        }
        try await send([(1, 320, 240)], touching: false)
        try await hid.send([])
        try await Task.sleep(for: .milliseconds(600))
        evidence.stage = "pinch"
        for step in 0...40 {
            let separation = CGFloat(40 + step * 2)
            try await send([(2, 320 - separation, 205), (3, 320 + separation, 205)])
        }
        try await send([(2, 200, 205), (3, 440, 205)], touching: false)
        try await hid.send([])
        try await Task.sleep(for: .milliseconds(600))
        evidence.stage = "release"
        try await send([(4, 320, 205)])
        try await send([(4, 320, 205)], touching: false)
        try await hid.send([])
        evidence.values["sequenceCompleted"] = true
        // HID has no NSTouch cancelled phase: cancellation is best-effort lift + teardown.
    }

    private func finish(exitCode: Int32) async {
        await hid?.close()
        hid = nil
        watchdog?.cancel()
        receiver?.close()
        let finalExitCode: Int32 = exitCode == 0 && options.mode == .run &&
            evidence.values["releaseReportsSubmitted"] as? Bool != true ? 4 : exitCode
        evidence.values["exitCode"] = finalExitCode
        do { try evidence.finish(output: options.output) }
        catch {
            FileHandle.standardError.write(Data("Evidence write failed: \(error)\n".utf8))
            Darwin.exit(5)
        }
        stopping = true
        NSApp.stop(nil)
        Darwin.exit(finalExitCode)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments == ["--help"] {
    print(Options.usage)
} else {
    do {
        let options = try Options(arguments)
        let app = NSApplication.shared
        app.setActivationPolicy(options.mode == .probe || options.mode == .activateProbe ? .prohibited : .regular)
        let controller = LabController(options: options)
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    } catch {
        FileHandle.standardError.write(Data("Invalid options: \(error)\n\(Options.usage)\n".utf8))
        Darwin.exit(1)
    }
}
