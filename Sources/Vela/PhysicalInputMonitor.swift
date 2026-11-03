import AppKit

@MainActor
final class PhysicalInputMonitor {
    enum StartFailure {
        case permissionRequired
        case tapUnavailable
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var onPhysicalInput: (() -> Void)?
    private(set) var startFailure: StartFailure?

    static func isPhysical(_ event: CGEvent) -> Bool {
        // Quartz-posted events carry their originating process ID. Hardware
        // keyboard and mouse events arrive from the HID system with PID 0.
        event.getIntegerValueField(.eventSourceUnixProcessID) == 0
    }

    func start(requestPermission: Bool) -> Bool {
        startFailure = nil
        if let tap {
            let enabled = CGEvent.tapIsEnabled(tap: tap)
            if !enabled { startFailure = .tapUnavailable }
            return enabled
        }
        if !CGPreflightListenEventAccess(),
           !(requestPermission && CGRequestListenEventAccess()) {
            startFailure = .permissionRequired
            return false
        }
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged, .scrollWheel
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<PhysicalInputMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if PhysicalInputMonitor.isPhysical(event) {
                    owner.onPhysicalInput?()
                }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            startFailure = .tapUnavailable
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        self.source = source
        return true
    }

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func ensureRunning() -> Bool {
        guard let tap else { return false }
        if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }
}
