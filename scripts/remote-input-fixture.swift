// A disposable, visible target for end-to-end remote-input checks. It only records
// text and events delivered to this test window, never system-wide keyboard input.
import AppKit

@MainActor
final class Fixture: NSObject, NSApplicationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let text = NSTextView(frame: NSRect(x: 20, y: 180, width: 720, height: 220))
    let pad = InputPad(frame: NSRect(x: 20, y: 20, width: 720, height: 140))
    let output: URL
    var timer: Timer?
    init(output: URL) { self.output = output; super.init() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "Vela Remote Input Test — disposable fixture"
        window.isReleasedWhenClosed = false
        window.contentView!.addSubview(text)
        window.contentView!.addSubview(pad)
        text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 20, weight: .regular)
        text.string = ""
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(text)
        let menu = NSMenu()
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu; menu.addItem(editItem); NSApp.mainMenu = menu
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.write() }
        }
        write()
    }
    func normalized(_ view: NSView, fraction: Double = 0.5) -> [String: Double] {
        let local = view.convert(NSPoint(x: view.bounds.width * fraction, y: view.bounds.height / 2), to: nil)
        let screen = window.convertPoint(toScreen: local)
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return ["x": screen.x / bounds.width, "y": (bounds.height - screen.y) / bounds.height]
    }
    func write() {
        let values: [String: Any] = ["pid": getpid(), "displayID": CGMainDisplayID(), "windowID": window.windowNumber,
            "text": text.string, "active": NSApp.isActive, "keyWindow": window.isKeyWindow,
            "textPoint": normalized(text), "padPoint": normalized(pad),
            "dragStart": normalized(pad, fraction: 0.2), "dragEnd": normalized(pad, fraction: 0.8),
            "mouseDowns": pad.downs, "mouseUps": pad.ups, "drags": pad.drags,
            "scrolls": pad.scrolls, "doubleClicks": pad.doubleClicks]
        if let data = try? JSONSerialization.data(withJSONObject: values, options: .sortedKeys) {
            try? data.write(to: output, options: .atomic)
        }
    }
}
@MainActor
final class InputPad: NSView {
    var downs = 0, ups = 0, drags = 0, scrolls = 0, doubleClicks = 0
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemTeal.withAlphaComponent(0.2).setFill(); bounds.fill()
        let label = "Remote mouse / drag / scroll test area"
        label.draw(at: NSPoint(x: 20, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
    }
    override func mouseDown(with event: NSEvent) { downs += 1; if event.clickCount == 2 { doubleClicks += 1 } }
    override func mouseUp(with event: NSEvent) { ups += 1 }
    override func mouseDragged(with event: NSEvent) { drags += 1 }
    override func scrollWheel(with event: NSEvent) { scrolls += 1 }
}
guard CommandLine.arguments.count == 2 else { fatalError("Usage: remote-input-fixture OUTPUT_JSON") }
let application = NSApplication.shared
let fixture = Fixture(output: URL(fileURLWithPath: CommandLine.arguments[1]))
application.delegate = fixture
application.setActivationPolicy(.regular)
withExtendedLifetime(fixture) { application.run() }
