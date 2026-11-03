import VelaLocalization
import AppKit
import RemoteCore
import RemoteRTC
import RemoteServer

@MainActor
private final class RemoteWebProbeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class RemoteWebProbeView: NSView {
    var green = false { didSet { needsDisplay = true } }
    var clicks = 0
    var keys = 0
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ rect: NSRect) { (green ? NSColor.systemGreen : NSColor.systemBlue).setFill(); bounds.fill() }
    override func mouseDown(with event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == 0x41575045545243 { clicks += 1 }
        window?.makeFirstResponder(self)
    }
    override func keyDown(with event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == 0x41575045545243 { keys += 1 }
    }
}

/// Opt-in local TLS/WebRTC test host. It never reads or changes the installed
/// remote configuration, and it always binds loopback with fixture credentials.
@MainActor
func runRemoteWebProbe(directory: URL) async -> Int32 {
    let oldFront = NSWorkspace.shared.frontmostApplication
    var display: VirtualDisplay?
    var window: NSWindow?
    var runtime: RemoteHostRuntime?
    do {
        guard DesktopSessionSnapshot.current().onConsole else { throw RemoteError.message(L("Log in locally before running the web integration probe.")) }
        guard CGPreflightScreenCaptureAccess(), CGPreflightPostEventAccess() else { throw RemoteError.message(L("Web verification requires Vela Screen Recording and Accessibility access.")) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let virtual = try VirtualDisplay(configuration: .init(width: 1920, height: 1080, hiDPI: true)); display = virtual
        try await virtual.prepare()
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == virtual.id }) else { throw RemoteError.message(L("Test display not found.")) }
        let view = RemoteWebProbeView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let fixture = RemoteWebProbeWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        fixture.level = .screenSaver; fixture.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        fixture.contentView = view; fixture.isReleasedWhenClosed = false; window = fixture
        fixture.makeKeyAndOrderFront(nil); fixture.makeFirstResponder(view); NSApp.activate(ignoringOtherApps: true)
        let files = RemoteFiles(directory: directory.appendingPathComponent("host"))
        var configuration = RemoteConfiguration(); configuration.enabled = true
        configuration.port = Int.random(in: 42000...58000); configuration.listenOnAllInterfaces = false
        configuration.password = try PasswordVerifier(password: "vela-web-fixture", iterations: 100_000)
        try files.save(configuration)
        let host = RemoteHostRuntime(files: files, addressProvider: { [] }); runtime = host
        try host.start()
        for _ in 0..<100 {
            if host.service.status.state == "listening" { break }
            if host.service.status.state == "error" { throw RemoteError.message(host.service.status.message) }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard host.service.status.state == "listening" else { throw RemoteError.message(L("Test service did not start.")) }
        try JSONSerialization.data(withJSONObject: ["port": configuration.port, "displayID": virtual.id], options: .prettyPrinted).write(to: directory.appendingPathComponent("ready.json"), options: .atomic)
        for _ in 0..<600 { // Five-minute ceiling even if the browser harness fails.
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path) { break }
            let targetID = DesktopCapture.displayMetadata().filter { CGDisplayVendorNumber($0.id) == 0x4157 }.map(\.id).max() ?? virtual.id
            if let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == targetID }), fixture.frame != screen.frame {
                fixture.setFrame(screen.frame, display: true)
            }
            view.green.toggle()
            try JSONSerialization.data(withJSONObject: ["clicks": view.clicks, "keys": view.keys, "displayID": targetID, "onConsole": DesktopSessionSnapshot.current().onConsole], options: .prettyPrinted).write(to: directory.appendingPathComponent("input.json"), options: .atomic)
            try await Task.sleep(for: .milliseconds(500))
        }
        await host.stop(); runtime = nil; fixture.close(); window = nil; virtual.close(); display = nil
        oldFront?.activate()
        return 0
    } catch {
        await runtime?.stop(); window?.close(); display?.close(); oldFront?.activate()
        try? error.localizedDescription.write(to: directory.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8)
        return 1
    }
}
