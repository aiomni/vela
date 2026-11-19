import VelaLocalization
import AppKit
import RemoteCore
import RemoteRTC

@MainActor
private final class BlackoutProbeView: NSView {
    var injectedKeys = 0
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == 0x41575045545243 { injectedKeys += 1 }
    }
}

@MainActor
private final class BlackoutProbeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
func runPhysicalBlackoutProbe(directory: URL) async -> Int32 {
    var displays: [VirtualDisplay] = []
    var window: NSWindow?
    let oldFront = NSWorkspace.shared.frontmostApplication
    let blackout = PhysicalDisplayBlackout(directory: directory.appendingPathComponent("recovery"))
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var result: [String: Any] = ["inputMonitoring": PhysicalDisplayBlackout.canObserveLocalInput,
                                     "displayDisableAvailable": PhysicalDisplayBlackout.isAvailable]
        if CommandLine.arguments.contains("--capabilities-only") {
            try JSONSerialization.data(withJSONObject: result, options: .prettyPrinted).write(to: directory.appendingPathComponent("result.json"))
            return 0
        }
        let before = DesktopCapture.displayMetadata()
        let companion = CommandLine.arguments.contains("--companion-blackout")
        let snapshot = companion ? try PhysicalDisplaySnapshot() : nil
        var replacements: [UInt32: UInt32] = [:]
        if let snapshot {
            for (id, configuration) in snapshot.configurations.sorted(by: { $0.key < $1.key }) {
                let display = try VirtualDisplay(configuration: configuration)
                displays.append(display)
                try await display.prepare()
                replacements[id] = display.id
            }
        } else {
            let display = try VirtualDisplay(configuration: .init(width: 1920, height: 1080, hiDPI: true))
            displays.append(display)
            try await display.prepare()
        }
        let fixture = BlackoutProbeWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        fixture.isReleasedWhenClosed = false
        fixture.title = L("Vela Input Verification")
        let view = BlackoutProbeView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        fixture.contentView = view; window = fixture
        if CommandLine.arguments.contains("--test-remote-input") {
            fixture.makeKeyAndOrderFront(nil); fixture.makeFirstResponder(view); NSApp.activate(ignoringOtherApps: true)
        }
        result["before"] = before.map { ["id": Int($0.id), "width": $0.width, "height": $0.height] }
        result["virtualIDs"] = displays.map(\.id)
        if let snapshot {
            try await blackout.begin(snapshot: snapshot, replacements: replacements, mayCommit: { !Task.isCancelled })
        } else {
            result["virtualID"] = displays[0].id
            try await blackout.begin(virtualID: displays[0].id)
        }
        result["whileOff"] = DesktopCapture.displayMetadata().map { Int($0.id) }
        result["onConsoleWhileOff"] = DesktopSessionSnapshot.current().onConsole
        result["lockedWhileOff"] = DesktopSessionSnapshot.current().locked
        if CommandLine.arguments.contains("--crash-after-blackout") {
            try JSONSerialization.data(withJSONObject: result, options: .prettyPrinted).write(to: directory.appendingPathComponent("before-crash.json"))
            _exit(99) // Isolated probe only: verify the independent recovery child.
        }
        if CommandLine.arguments.contains("--test-remote-input") {
            let source = CGEventSource(stateID: .privateState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.setIntegerValueField(.eventSourceUserData, value: 0x41575045545243)
                event?.post(tap: .cgSessionEventTap)
            }
        }
        for _ in 0..<(companion ? 150 : 50) {
            if let reason = await blackout.heartbeat() { result["restoredBy"] = reason; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        result["restoreSucceeded"] = await blackout.restore()
        result["injectedKeys"] = view.injectedKeys
        fixture.close(); window = nil
        for display in displays { display.close() }
        displays.removeAll()
        try await Task.sleep(for: .milliseconds(500))
        result["after"] = DesktopCapture.displayMetadata().map { ["id": Int($0.id), "width": $0.width, "height": $0.height] }
        try JSONSerialization.data(withJSONObject: result, options: .prettyPrinted).write(to: directory.appendingPathComponent("result.json"))
        oldFront?.activate()
        return result["restoreSucceeded"] as? Bool == true ? 0 : 1
    } catch {
        _ = await blackout.restore()
        window?.close()
        if !blackout.isActive {
            for display in displays { display.close() }
            displays.removeAll()
        }
        oldFront?.activate()
        try? error.localizedDescription.write(to: directory.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8)
        return 1
    }
}
