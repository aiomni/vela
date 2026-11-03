import VelaLocalization
import AppKit
import ScreenCaptureKit
import CoreMedia
import RemoteCore
import RemoteRTC

private final class ProbeFrames: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var fixtureFrames = 0
    private var statuses: [String: Int] = [:]
    private var error = ""
    func clearError() { lock.lock(); error = ""; lock.unlock() }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); self.error = error.localizedDescription; lock.unlock()
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let status = attachments?.first?[.status] as? Int ?? -1
        var fixture = false
        if status == SCFrameStatus.complete.rawValue, let image = CMSampleBufferGetImageBuffer(buffer) {
            CVPixelBufferLockBaseAddress(image, .readOnly)
            if let pointer = CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self) {
                let offset = CVPixelBufferGetBytesPerRow(image) * (CVPixelBufferGetHeight(image) / 2) + (CVPixelBufferGetWidth(image) / 2) * 4
                let b = Int(pointer[offset]), g = Int(pointer[offset+1]), r = Int(pointer[offset+2])
                fixture = b < 80 && ((r > 150 && g < 80) || (g > 150 && r < 80))
            }
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
        }
        lock.lock(); frames += 1; if fixture { fixtureFrames += 1 }; statuses[String(status), default: 0] += 1; lock.unlock()
    }
    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["frames": frames, "fixtureFrames": fixtureFrames, "statuses": statuses, "error": error]
    }
}

@MainActor
private final class ProbeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class ProbeView: NSView {
    var green = false { didSet { needsDisplay = true } }
    var inputCount = 0
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        (green ? NSColor.green : NSColor.red).setFill(); bounds.fill()
    }
    override func keyDown(with event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == 0x41575050524F42 { inputCount += 1 }
    }
}

/// Opt-in integration probe: only generated colors and counters are recorded.
/// --probe-detach explicitly switches the local console to its login window.
@MainActor
func runRemoteSessionProbe(directory: URL, detach: Bool, lockFirst: Bool = false, sleepPhysical: Bool = false) async -> Int32 {
    let oldFront = NSWorkspace.shared.frontmostApplication
    var virtual: VirtualDisplay?
    var stream: SCStream?
    var window: NSWindow?
    var samples: [[String: Any]] = []
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard CGPreflightScreenCaptureAccess(), CGPreflightPostEventAccess() else {
            throw RemoteError.message(L("Verification requires Screen Recording and Accessibility access for the current Vela build."))
        }
        let display = try VirtualDisplay(configuration: .init(width: 1920, height: 1080, hiDPI: true)); virtual = display
        try await display.prepare()
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id }) else {
            throw RemoteError.message(L("The virtual display did not appear in NSScreen."))
        }
        let view = ProbeView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let fixture = ProbeWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        fixture.level = .screenSaver; fixture.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        fixture.contentView = view; fixture.isReleasedWhenClosed = false; window = fixture
        fixture.makeKeyAndOrderFront(nil); fixture.makeFirstResponder(view); NSApp.activate(ignoringOtherApps: true)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let target = content.displays.first(where: { $0.displayID == display.id }) else { throw RemoteError.message(L("Unable to capture the virtual display.")) }
        let config = SCStreamConfiguration(); config.width = 640; config.height = 360
        config.pixelFormat = kCVPixelFormatType_32BGRA; config.showsCursor = false; config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        let output = ProbeFrames()
        let capture = SCStream(filter: SCContentFilter(display: target, excludingWindows: []), configuration: config, delegate: output); stream = capture
        try capture.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "Vela.sessionProbe"))
        try await capture.startCapture()
        let started = ProcessInfo.processInfo.systemUptime
        var remapped = false
        var remappedDisplayID: UInt32?
        var displaySleepRequested = false
        for step in 0..<(detach ? 60 : 12) {
            view.green.toggle()
            // Session event tap deliberately targets the caller's WindowServer
            // session, not the machine-wide HID stream / console login window.
            if (step == 4 || step == 18 || step == 30 || step == 45) && !DesktopSessionSnapshot.current().locked {
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                    event?.setIntegerValueField(.eventSourceUserData, value: 0x41575050524F42)
                    event?.post(tap: .cgSessionEventTap)
                }
            }
            if lockFirst && step == 10 { try DesktopSession.lockScreen() }
            if detach && step == (lockFirst ? 20 : 10) { try DesktopSession.detachFromConsole(allowLocked: lockFirst) }
            try await Task.sleep(for: .milliseconds(500))
            let state = DesktopSessionSnapshot.current()
            if detach && !state.onConsole && !remapped {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    let windowDisplayID = (fixture.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                    if let target = content.displays.first(where: { $0.displayID == windowDisplayID }) ??
                        content.displays.first(where: { Int(CGDisplayBounds($0.displayID).width) == 960 && Int(CGDisplayBounds($0.displayID).height) == 540 }) {
                        try? await stream?.stopCapture()
                        let replacement = SCStream(filter: SCContentFilter(display: target, excludingWindows: []), configuration: config, delegate: output)
                        try replacement.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "Vela.sessionProbe.rebound"))
                        try await replacement.startCapture(); stream = replacement; output.clearError()
                        remappedDisplayID = target.displayID; remapped = true
                    }
                } catch { /* Record the error of the original stream and retry on the next step. */ }
            }
            if sleepPhysical && remapped && !displaySleepRequested {
                try await DesktopSession.sleepPhysicalDisplays(); displaySleepRequested = true
            }
            samples.append(["seconds": ProcessInfo.processInfo.systemUptime-started,
                            "state": state.state, "onConsole": state.onConsole, "locked": state.locked,
                            "capture": output.snapshot(), "receivedTestKeys": view.inputCount,
                            "fixtureKeyWindow": fixture.isKeyWindow,
                            "windowDisplayID": (fixture.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
                            "bridgeDisplayID": display.currentSystemID,
                            "remappedDisplayID": remappedDisplayID ?? 0,
                            "displaySleepRequested": displaySleepRequested,
                            "displayID": display.id, "logicalWidth": Int(CGDisplayBounds(display.id).width),
                            "logicalHeight": Int(CGDisplayBounds(display.id).height)])
            try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("samples.json"), options: .atomic)
        }
        try? await stream?.stopCapture(); stream = nil
        fixture.close(); window = nil; display.close(); virtual = nil
        if DesktopSessionSnapshot.current().onConsole { oldFront?.activate() }
        return 0
    } catch {
        try? await stream?.stopCapture(); window?.close(); virtual?.close()
        if DesktopSessionSnapshot.current().onConsole { oldFront?.activate() }
        try? error.localizedDescription.write(to: directory.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8)
        return 1
    }
}
