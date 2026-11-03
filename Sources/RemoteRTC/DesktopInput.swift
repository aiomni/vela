import AppKit
import RemoteCore

@MainActor
public final class DesktopInput {
    public enum Destination { case desktop, lockScreen }
    public var destination: Destination = .desktop {
        willSet { if newValue != destination { releaseAll() } }
    }
    public var displayID: UInt32?
    public var enabled = false { didSet { if !enabled { releaseAll() } } }
    private let desktopSource = CGEventSource(stateID: .privateState)
    private let consoleSource = CGEventSource(stateID: .combinedSessionState)
    private var source: CGEventSource? { destination == .lockScreen ? consoleSource : desktopSource }
    private var keys: Set<UInt16> = []
    private var buttons: Set<Int> = []
    private var location = CGPoint.zero
    private var lastSequence: UInt64 = 0
    private var second: TimeInterval = 0
    private var events = 0
    private var textBudget = 0
    private var lastClickTime: TimeInterval = 0
    private var lastClickLocation = CGPoint.zero
    private var lastClickButton = -1
    private var clickCount: Int64 = 0
    public init() {}
    public var diagnostics: [String: Int] { ["keysDown": keys.count, "buttonsDown": buttons.count] }

    public func receive(_ data: Data, pointerChannel: Bool) {
        guard enabled, CGPreflightPostEventAccess(), data.count <= 16384,
              let input = try? JSONDecoder().decode(RemoteInput.self, from: data), input.validate() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - second >= 1 { second = now; events = 0; textBudget = 0 }
        events += 1
        guard events <= 1500 else { releaseAll(); return }
        if pointerChannel && !(input.type == "pointer" && input.action == "move") { return }
        if input.type == "pointer" || input.type == "scroll" {
            guard input.displayID == displayID, let displayID, CGDisplayIsActive(displayID) == 1,
                  CGDisplayBounds(displayID).width > 1, CGDisplayBounds(displayID).height > 1 else { return }
        }
        let flags = flags(input.modifiers ?? [])
        switch input.type {
        case "pointer":
            if let sequence = input.sequence {
                if input.action == "move" && sequence <= lastSequence { return }
                lastSequence = max(lastSequence, sequence)
            }
            let bounds = CGDisplayBounds(displayID!)
            location = CGPoint(x: bounds.minX + min(bounds.width - 1, input.x! * bounds.width),
                               y: bounds.minY + min(bounds.height - 1, input.y! * bounds.height))
            let button = input.button ?? 0
            let cgButton: CGMouseButton = button == 2 ? .right : button == 1 ? .center : .left
            let type: CGEventType
            if input.action == "down" {
                if button == lastClickButton, now - lastClickTime < NSEvent.doubleClickInterval,
                   hypot(location.x - lastClickLocation.x, location.y - lastClickLocation.y) < 5 {
                    clickCount = min(3, clickCount + 1)
                } else { clickCount = 1 }
                lastClickTime = now; lastClickLocation = location; lastClickButton = button
                buttons.insert(button)
                type = button == 2 ? .rightMouseDown : button == 1 ? .otherMouseDown : .leftMouseDown
            } else if input.action == "up" {
                buttons.remove(button)
                type = button == 2 ? .rightMouseUp : button == 1 ? .otherMouseUp : .leftMouseUp
            } else {
                type = buttons.contains(0) ? .leftMouseDragged : buttons.contains(2) ? .rightMouseDragged : buttons.contains(1) ? .otherMouseDragged : .mouseMoved
            }
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: cgButton)
            event?.setIntegerValueField(.mouseEventClickState, value: clickCount)
            post(event, flags: flags)
        case "scroll":
            let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                wheel1: Int32(-input.deltaY!), wheel2: Int32(-input.deltaX!), wheel3: 0)
            event?.location = location
            post(event, flags: flags)
        case "key":
            let code = KeyMap.macKeyCode[input.code!]!
            let down = input.action == "down"
            let isRepeat = down && keys.contains(code)
            if down { keys.insert(code) } else { keys.remove(code) }
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.setIntegerValueField(.keyboardEventAutorepeat, value: isRepeat ? 1 : 0)
            post(event, flags: flags)
        case "text":
            textBudget += input.text!.utf8.count
            guard textBudget <= 8192 else { return }
            // Use committed Unicode; do not touch the system clipboard or record keystrokes.
            for character in input.text! {
                let units = Array(String(character).utf16)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    units.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
                    post(event, flags: [])
                }
            }
        case "release": releaseAll()
        default: break
        }
    }
    private func flags(_ modifiers: [String]) -> CGEventFlags {
        var result: CGEventFlags = []
        if modifiers.contains("shift") { result.insert(.maskShift) }
        if modifiers.contains("control") { result.insert(.maskControl) }
        if modifiers.contains("alt") { result.insert(.maskAlternate) }
        if modifiers.contains("meta") { result.insert(.maskCommand) }
        return result
    }
    private func post(_ event: CGEvent?, flags: CGEventFlags) {
        // Arrow/function/keypad events carry key-identity flags in addition to
        // held modifiers. Dropping them makes macOS ignore Control+Arrow for
        // Spaces and Mission Control, even though ordinary typing still works.
        let keyFlags: CGEventFlags = event?.type == .keyDown || event?.type == .keyUp
            ? (event?.flags.intersection([.maskNumericPad, .maskSecondaryFn]) ?? []) : []
        event?.flags = flags.union(keyFlags)
        event?.setIntegerValueField(.eventSourceUserData, value: 0x41575045545243)
        // The system password field accepts console HID events backed by the
        // combined session source. Normal desktop input stays at the session
        // tap, including virtual-only control. The host authenticates and checks
        // the current console/lock state before admitting every input message.
        event?.post(tap: destination == .lockScreen ? .cghidEventTap : .cgSessionEventTap)
    }
    public func releaseAll() {
        for code in keys { post(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false), flags: []) }
        for button in buttons {
            let type: CGEventType = button == 2 ? .rightMouseUp : button == 1 ? .otherMouseUp : .leftMouseUp
            let cgButton: CGMouseButton = button == 2 ? .right : button == 1 ? .center : .left
            post(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: cgButton), flags: [])
        }
        keys.removeAll(); buttons.removeAll(); lastSequence = 0
    }
}
