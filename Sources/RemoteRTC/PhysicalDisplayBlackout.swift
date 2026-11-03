import AppKit
import Darwin
import RemoteCore
import RemoteDisplayBridge

public struct BlackoutDisplay: Codable, Sendable {
    let id: UInt32
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    let x: Int32
    let y: Int32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let modeID: Int32
    let mirror: UInt32

    init(_ id: UInt32) throws {
        guard let mode = CGDisplayCopyDisplayMode(id) else { throw RemoteError.message("Unable to save the display mode.") }
        let bounds = CGDisplayBounds(id)
        self.id = id; vendor = CGDisplayVendorNumber(id); model = CGDisplayModelNumber(id)
        serial = CGDisplaySerialNumber(id); x = Int32(bounds.minX); y = Int32(bounds.minY)
        width = mode.width; height = mode.height; pixelWidth = mode.pixelWidth; pixelHeight = mode.pixelHeight
        modeID = mode.ioDisplayModeID; mirror = CGDisplayMirrorsDisplay(id)
    }

    func resolve(in ids: [UInt32]) -> UInt32? {
        let matches = ids.filter { CGDisplayVendorNumber($0) == vendor && CGDisplayModelNumber($0) == model && CGDisplaySerialNumber($0) == serial }
        if matches.contains(id) { return id }
        return matches.count == 1 ? matches[0] : nil
    }
}

public struct BlackoutLayout: Codable, Sendable {
    let owner: Int32
    let virtualID: UInt32
    let displays: [BlackoutDisplay]

    public static var supported: Bool { APDisplayPowerIsAvailable() }

    public init(virtualID: UInt32) throws {
        guard Self.supported, CGDisplayIsActive(virtualID) == 1,
              CGDisplayVendorNumber(virtualID) == 0x4157, CGDisplayModelNumber(virtualID) == 1 else {
            throw RemoteError.message("Create a working Vela virtual display first.")
        }
        var ids = [UInt32](repeating: 0, count: 64); var count: UInt32 = 0
        guard CGGetActiveDisplayList(64, &ids, &count) == .success else { throw RemoteError.message("Unable to read the display layout.") }
        displays = try ids.prefix(Int(count)).map { try BlackoutDisplay($0) }
        guard displays.contains(where: { $0.id == virtualID }), displays.count > 1 else {
            throw RemoteError.message("There are no physical displays to turn off.")
        }
        self.virtualID = virtualID; owner = getpid()
    }

    static func allDisplays() -> [UInt32] {
        var ids = [UInt32](repeating: 0, count: 64); var count: UInt32 = 0
        guard APGetAllDisplayList(64, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(min(count, 64))))
    }

    public func disablePhysicalDisplays() throws {
        guard DesktopSessionSnapshot.current().onConsole, !DesktopSessionSnapshot.current().locked,
              CGDisplayIsActive(virtualID) == 1 else { throw RemoteError.message("Unlock the host Mac and confirm the virtual display works first.") }
        var transaction: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&transaction) == .success, let transaction else { throw RemoteError.message("Unable to begin display configuration.") }
        for display in displays where display.id != virtualID {
            guard APConfigureDisplayEnabled(transaction, display.id, false) == .success else {
                CGCancelDisplayConfiguration(transaction); throw RemoteError.message("The system refused to turn off physical displays.")
            }
        }
        guard CGConfigureDisplayOrigin(transaction, virtualID, 0, 0) == .success else {
            CGCancelDisplayConfiguration(transaction); throw RemoteError.message("Unable to make the virtual display the active desktop.")
        }
        guard CGCompleteDisplayConfiguration(transaction, .forSession) == .success else {
            throw RemoteError.message("The system could not apply the physical display shutdown configuration.")
        }
    }

    public var onlyVirtualActive: Bool {
        CGDisplayIsActive(virtualID) == 1 && displays.filter { $0.id != virtualID }.allSatisfy { CGDisplayIsActive($0.id) != 1 }
    }

    /// Enable saved hardware first, then restore its layout. The virtual screen
    /// may already be gone after a parent crash; that must not prevent recovery.
    @discardableResult
    public func restore() -> Bool {
        let all = Self.allDisplays()
        let physical = displays.filter { $0.id != virtualID }
        let resolved = displays.compactMap { saved -> (BlackoutDisplay, UInt32)? in
            saved.resolve(in: all).map { (saved, $0) }
        }
        var transaction: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&transaction) == .success, let transaction else { return false }
        var enabled = true
        for (saved, id) in resolved where saved.id != virtualID {
            if APConfigureDisplayEnabled(transaction, id, true) != .success { enabled = false }
        }
        guard CGCompleteDisplayConfiguration(transaction, .forSession) == .success else { return false }
        // A disconnected cable is not a failed restore. If none of the old
        // hardware is currently attached, retain the marker for later recovery.
        guard resolved.contains(where: { $0.0.id != virtualID }), enabled else { return false }
        var layout: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&layout) == .success, let layout {
            for (saved, id) in resolved {
                let modes = CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary) as? [CGDisplayMode] ?? []
                if let mode = modes.first(where: { $0.ioDisplayModeID == saved.modeID && $0.pixelWidth == saved.pixelWidth && $0.pixelHeight == saved.pixelHeight }) ?? modes.first(where: { $0.width == saved.width && $0.height == saved.height && $0.pixelWidth == saved.pixelWidth && $0.pixelHeight == saved.pixelHeight }) {
                    _ = CGConfigureDisplayWithDisplayMode(layout, id, mode, nil)
                }
                _ = CGConfigureDisplayOrigin(layout, id, saved.x, saved.y)
                let mirror = resolved.first(where: { $0.0.id == saved.mirror })?.1 ?? kCGNullDirectDisplay
                _ = CGConfigureDisplayMirrorOfDisplay(layout, id, mirror)
            }
            _ = CGCompleteDisplayConfiguration(layout, .forSession)
        }
        return physical.allSatisfy { saved in
            guard let id = saved.resolve(in: Self.allDisplays()) else { return true }
            return CGDisplayIsActive(id) == 1
        }
    }
}

/// A per-blackout child of the signed application. It owns no remote listener,
/// password or video stream, and exits after restoring the displays.
@MainActor
public enum PhysicalDisplayWatchdog {
    private final class Input {
        var tap: CFMachPort?
        var source: CFRunLoopSource?
        var requested = false
        var armed = false
        func start() -> Bool {
            guard CGPreflightListenEventAccess() else { return false }
            let types: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .leftMouseDragged, .rightMouseDragged]
            let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                   eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let input = Unmanaged<Input>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    input.requested = true // Restore rather than losing the escape route.
                } else if input.armed && event.getIntegerValueField(.eventSourceUnixProcessID) == 0 &&
                            event.getIntegerValueField(.eventSourceUserData) != 0x41575045545243 {
                    input.requested = true
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
            guard let tap else { return false }
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            return CGEvent.tapIsEnabled(tap: tap)
        }
        func stop() {
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            if let tap { CFMachPortInvalidate(tap) }
        }
    }

    public static func run(directory: URL) async -> Int32 {
        let file = directory.appendingPathComponent("layout.json")
        guard let data = try? Data(contentsOf: file), data.count < 65536,
              let layout = try? JSONDecoder().decode(BlackoutLayout.self, from: data),
              layout.owner == getppid() else { return 2 }
        let input = Input()
        guard input.start() else { return 3 }
        defer { input.stop() }
        try? Data("ready".utf8).write(to: directory.appendingPathComponent("ready"), options: .atomic)
        let began = ProcessInfo.processInfo.systemUptime
        var activeSince: TimeInterval?
        var reason = "parent-exited"
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            let active = FileManager.default.fileExists(atPath: directory.appendingPathComponent("active").path)
            if active && activeSince == nil { activeSince = now }
            input.armed = activeSince.map { now - $0 > 0.8 } ?? false
            if input.requested { reason = "local-input"; break }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("restore").path) { reason = "requested"; break }
            if kill(layout.owner, 0) != 0 { break }
            let lease = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("lease").path)[.modificationDate] as? Date
            if now - began > 8 && (lease == nil || Date().timeIntervalSince(lease!) > 8) { reason = "heartbeat-expired"; break }
            if active && CGDisplayIsActive(layout.virtualID) != 1 { reason = "virtual-display-lost"; break }
            if input.armed {
                var activeIDs = [UInt32](repeating: 0, count: 64); var count: UInt32 = 0
                if CGGetActiveDisplayList(64, &activeIDs, &count) != .success ||
                    activeIDs.prefix(Int(count)).contains(where: { $0 != layout.virtualID }) {
                    reason = "display-topology-changed"; break
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        var restored = false
        for _ in 0..<10 {
            if layout.restore() { restored = true; break }
            try? await Task.sleep(for: .milliseconds(300))
        }
        let result = ["reason": reason, "restored": restored ? "true" : "false"]
        if let data = try? JSONEncoder().encode(result) { try? data.write(to: directory.appendingPathComponent("result.json"), options: .atomic) }
        return restored ? 0 : 4
    }
}

@MainActor
public final class PhysicalDisplayBlackout {
    private let directory: URL
    private var process: Process?
    private var layout: BlackoutLayout?
    public private(set) var isActive = false
    public static var isAvailable: Bool { BlackoutLayout.supported }
    public static var canObserveLocalInput: Bool { CGPreflightListenEventAccess() }

    public init(directory: URL) { self.directory = directory }

    public func recoverPreviousSession() throws {
        let path = directory.appendingPathComponent("layout.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let data = try Data(contentsOf: path)
        guard data.count < 65536 else { throw RemoteError.message("Invalid display recovery record.") }
        let saved = try JSONDecoder().decode(BlackoutLayout.self, from: data)
        guard saved.restore() else { throw RemoteError.message("Previously disabled physical displays are not fully restored. Connect a physical display and try again.") }
        try FileManager.default.removeItem(at: directory)
    }

    public func begin(virtualID: UInt32) async throws {
        guard !isActive, process == nil else { throw RemoteError.message("Physical display shutdown is already in progress.") }
        guard Self.canObserveLocalInput else { throw RemoteError.message("Grant Vela Input Monitoring access in System Settings so local input can restore physical displays.") }
        try recoverPreviousSession()
        let saved = try BlackoutLayout(virtualID: virtualID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["ready", "active", "restore", "result.json"] { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent("layout.json"), options: .atomic)
        try Data().write(to: directory.appendingPathComponent("lease"), options: .atomic)
        layout = saved
        let child = Process()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["--remote-display-watchdog", directory.path]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        process = child
        do {
            try child.run()
            for _ in 0..<40 {
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path) { break }
                guard child.isRunning else { throw RemoteError.message("Local input recovery monitoring could not start. Check Input Monitoring access.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard child.isRunning, FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path) else {
                throw RemoteError.message("Display recovery protection is not ready. No physical displays were turned off.")
            }
            isActive = true
            try saved.disablePhysicalDisplays()
            try Data().write(to: directory.appendingPathComponent("active"), options: .atomic)
            for _ in 0..<30 {
                if saved.onlyVirtualActive { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw RemoteError.message("The system did not disable all physical displays. The original layout was restored.")
        } catch {
            await restore()
            throw error
        }
    }

    /// Returns a recovery reason once. A hardware wake leaves the virtual screen
    /// available so the remote user can continue or explicitly select another.
    public func heartbeat() -> String? {
        guard isActive else { return nil }
        try? Data().write(to: directory.appendingPathComponent("lease"), options: .atomic)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("result.json")),
           let result = try? JSONDecoder().decode([String: String].self, from: data) {
            if result["restored"] == "true" {
                isActive = false; layout = nil; process = nil
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("layout.json"))
                return result["reason"] ?? "restored"
            }
            return "restore-failed"
        }
        if process?.isRunning != true {
            if layout?.restore() == true {
                isActive = false; layout = nil; process = nil
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("layout.json"))
                return "watchdog-exited"
            }
            return "restore-failed"
        }
        return nil
    }

    @discardableResult
    public func restore() async -> Bool {
        guard layout != nil || process != nil else { return !isActive }
        try? Data().write(to: directory.appendingPathComponent("restore"), options: .atomic)
        for _ in 0..<50 {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("result.json")),
               let result = try? JSONDecoder().decode([String: String].self, from: data), result["restored"] == "true" {
                isActive = false; layout = nil; process = nil
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("layout.json"))
                return true
            }
            if process?.isRunning != true { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let restored = layout?.restore() ?? !isActive
        if restored {
            if process?.isRunning == true { process?.terminate() }
            isActive = false; layout = nil; process = nil
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("layout.json"))
        }
        return restored
    }
}
