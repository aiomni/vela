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
    let rotation: Double?

    init(_ id: UInt32) throws {
        guard let mode = CGDisplayCopyDisplayMode(id) else { throw RemoteError.message("Unable to save the display mode.") }
        let bounds = CGDisplayBounds(id)
        self.id = id; vendor = CGDisplayVendorNumber(id); model = CGDisplayModelNumber(id)
        serial = CGDisplaySerialNumber(id); x = Int32(bounds.minX); y = Int32(bounds.minY)
        width = mode.width; height = mode.height; pixelWidth = mode.pixelWidth; pixelHeight = mode.pixelHeight
        modeID = mode.ioDisplayModeID; mirror = CGDisplayMirrorsDisplay(id)
        rotation = CGDisplayRotation(id)
    }

    func resolve(in ids: [UInt32]) -> UInt32? {
        let matches = ids.filter { CGDisplayVendorNumber($0) == vendor && CGDisplayModelNumber($0) == model && CGDisplaySerialNumber($0) == serial }
        if matches.contains(id) { return id }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Captured before attaching any temporary screens so WindowServer changes
/// during preparation cannot overwrite the original layout.
@MainActor
public struct PhysicalDisplaySnapshot {
    fileprivate let displays: [BlackoutDisplay]
    fileprivate let mainID: UInt32
    public let configurations: [UInt32: VirtualDisplayConfiguration]

    public init() throws {
        guard let ids = BlackoutLayout.onlineDisplays() else { throw RemoteError.message("Unable to read the display layout.") }
        mainID = CGMainDisplayID()
        displays = try ids.map(BlackoutDisplay.init)
        var configurations: [UInt32: VirtualDisplayConfiguration] = [:]
        for display in displays {
            var physical = false
            guard APDisplayIsPhysical(display.id, &physical) else {
                throw RemoteError.message("Unable to identify the physical displays.")
            }
            if physical {
                let bounds = CGDisplayBounds(display.id)
                let rotated = display.rotation == 90 || display.rotation == 270
                configurations[display.id] = Self.replacementMode(
                    width: Int(bounds.width), height: Int(bounds.height),
                    pixelWidth: rotated ? display.pixelHeight : display.pixelWidth,
                    pixelHeight: rotated ? display.pixelWidth : display.pixelHeight)
            }
        }
        guard !configurations.isEmpty else { throw RemoteError.message("There are no physical displays to turn off.") }
        self.configurations = configurations
    }

    nonisolated static func replacementMode(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int) -> VirtualDisplayConfiguration {
        if width * 2 == pixelWidth, height * 2 == pixelHeight {
            let exact = VirtualDisplayConfiguration(width: pixelWidth, height: pixelHeight, hiDPI: true)
            if (try? exact.validate()) != nil { return exact }
        }
        // Preserve desktop points even when the source's Retina backing exceeds the pixel budget.
        let w = Double(max(1, width)), h = Double(max(1, height))
        let scale = min(1, 3840 / w, 3840 / h, sqrt(Double(3840 * 2160) / (w * h)))
        return .init(width: max(640, Int(w * scale / 2) * 2),
                     height: max(480, Int(h * scale / 2) * 2), hiDPI: false)
    }
}

public struct BlackoutLayout: Codable, Sendable {
    let owner: Int32
    let virtualID: UInt32
    let displays: [BlackoutDisplay]
    let lockBeforeRestore: Bool?
    let mainID: UInt32?
    // Absent in legacy records and in remote-controlled single-display sessions.
    let replacements: [UInt32: UInt32]?
    let replacementDisplays: [BlackoutDisplay]?

    public static var supported: Bool { APDisplayPowerIsAvailable() }

    public init(virtualID: UInt32, lockBeforeRestore: Bool = false) throws {
        guard Self.supported, CGDisplayIsOnline(virtualID) == 1,
              CGDisplayVendorNumber(virtualID) == 0x4157, CGDisplayModelNumber(virtualID) == 1 else {
            throw RemoteError.message("Create a working Vela virtual display first.")
        }
        guard let ids = Self.onlineDisplays() else { throw RemoteError.message("Unable to read the display layout.") }
        displays = try ids.map { try BlackoutDisplay($0) }
        guard displays.contains(where: { $0.id == virtualID }), displays.count > 1 else {
            throw RemoteError.message("There are no physical displays to turn off.")
        }
        self.virtualID = virtualID; owner = getpid()
        self.lockBeforeRestore = lockBeforeRestore
        mainID = CGMainDisplayID()
        replacements = nil
        replacementDisplays = nil
    }

    @MainActor
    init(snapshot: PhysicalDisplaySnapshot, replacements: [UInt32: UInt32]) throws {
        let ids = Set(replacements.values)
        guard Self.supported, Set(replacements.keys) == Set(snapshot.configurations.keys),
              ids.count == replacements.count, ids.allSatisfy({
                  CGDisplayIsOnline($0) == 1 && CGDisplayVendorNumber($0) == 0x4157 && CGDisplayModelNumber($0) == 1
              }) else { throw RemoteError.message("Create a working Vela virtual display first.") }
        owner = getpid()
        displays = snapshot.displays
        mainID = snapshot.mainID
        virtualID = replacements[snapshot.mainID] ?? snapshot.mainID
        lockBeforeRestore = false
        self.replacements = replacements
        replacementDisplays = try ids.map(BlackoutDisplay.init)
    }

    private var disabledIDs: Set<UInt32> {
        if let replacements { return Set(replacements.keys) }
        return Set(displays.map(\.id)).subtracting([virtualID])
    }

    private var expectedBefore: Set<UInt32> {
        Set(displays.map(\.id)).union(replacements.map { Set($0.values) } ?? [])
    }

    static func onlineDisplays() -> [UInt32]? {
        var ids = [UInt32](repeating: 0, count: 64); var count: UInt32 = 0
        guard CGGetOnlineDisplayList(64, &ids, &count) == .success, count < 64 else { return nil }
        return Array(ids.prefix(Int(count)))
    }

    static func allDisplays() -> [UInt32] {
        var ids = [UInt32](repeating: 0, count: 64); var count: UInt32 = 0
        guard APGetAllDisplayList(64, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(min(count, 64))))
    }

    public func disablePhysicalDisplays() throws {
        let session = DesktopSessionSnapshot.current()
        guard session.available, session.loginDone, session.onConsole, !session.locked || lockBeforeRestore == true,
              CGDisplayIsOnline(virtualID) == 1 else { throw RemoteError.message("The current user session or virtual display is unavailable.") }
        guard Self.onlineDisplays().map(Set.init) == expectedBefore,
              replacements == nil || (CGMainDisplayID() == mainID && displays.allSatisfy { saved in
                  CGDisplayMirrorsDisplay(saved.id) == saved.mirror &&
                      CGDisplayCopyDisplayMode(saved.id)?.ioDisplayModeID == saved.modeID &&
                      CGDisplayBounds(saved.id).origin == CGPoint(x: Int(saved.x), y: Int(saved.y))
              }) else {
            throw RemoteError.message("The display layout changed. Try connecting again.")
        }
        var transaction: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&transaction) == .success, let transaction else { throw RemoteError.message("Unable to begin display configuration.") }
        for id in disabledIDs {
            guard APConfigureDisplayEnabled(transaction, id, false) == .success else {
                CGCancelDisplayConfiguration(transaction); throw RemoteError.message("The system refused to turn off physical displays.")
            }
        }
        if let replacements {
            guard configureArrangement(transaction, ids: displays.map { ($0, replacements[$0.id] ?? $0.id) }) else {
                CGCancelDisplayConfiguration(transaction)
                throw RemoteError.message("Unable to arrange the replacement virtual displays.")
            }
        } else if CGConfigureDisplayOrigin(transaction, virtualID, 0, 0) != .success {
            CGCancelDisplayConfiguration(transaction); throw RemoteError.message("Unable to make the virtual display the active desktop.")
        }
        guard CGCompleteDisplayConfiguration(transaction, .forSession) == .success else {
            throw RemoteError.message("The system could not apply the physical display shutdown configuration.")
        }
    }

    private func configureArrangement(_ configuration: CGDisplayConfigRef, ids: [(BlackoutDisplay, UInt32)]) -> Bool {
        // Move the new main first, then position the extended displays and attach mirror followers.
        for (saved, id) in ids.sorted(by: { $0.0.id == mainID && $1.0.id != mainID }) {
            let mirror = ids.first(where: { $0.0.id == saved.mirror })?.1 ?? kCGNullDirectDisplay
            if (CGDisplayMirrorsDisplay(id) != mirror || mirror != kCGNullDirectDisplay),
               CGConfigureDisplayMirrorOfDisplay(configuration, id, mirror) != .success { return false }
            if mirror == kCGNullDirectDisplay,
               CGConfigureDisplayOrigin(configuration, id, saved.x, saved.y) != .success { return false }
        }
        return true
    }

    public var onlyVirtualOnline: Bool {
        guard CGMainDisplayID() == virtualID,
              Self.onlineDisplays().map(Set.init) == expectedBefore.subtracting(disabledIDs) else { return false }
        guard let replacements else { return true }
        return displays.allSatisfy { saved in
            CGDisplayMirrorsDisplay(replacements[saved.id] ?? saved.id) == (replacements[saved.mirror] ?? saved.mirror)
        }
    }

    fileprivate var topologyChanged: Bool {
        Self.onlineDisplays().map(Set.init) != expectedBefore
    }

    /// Enable saved hardware first, then restore its layout. The virtual screen
    /// may already be gone after a parent crash; that must not prevent recovery.
    @discardableResult
    public func restore() -> Bool {
        let all = Self.allDisplays()
        let disabled = disabledIDs
        let physical = displays.filter { disabled.contains($0.id) }
        let resolved = displays.compactMap { saved -> (BlackoutDisplay, UInt32)? in
            saved.resolve(in: all).map { (saved, $0) }
        }
        var transaction: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&transaction) == .success, let transaction else { return false }
        var enabled = true
        for (saved, id) in resolved where disabled.contains(saved.id) {
            if APConfigureDisplayEnabled(transaction, id, true) != .success { enabled = false }
        }
        guard CGCompleteDisplayConfiguration(transaction, .forSession) == .success else { return false }
        // A disconnected cable is not a failed restore. If none of the old
        // hardware is currently attached, retain the marker for later recovery.
        guard resolved.contains(where: { disabled.contains($0.0.id) }), enabled else { return false }
        var layout: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&layout) == .success, let layout else { return false }
        if let replacementDisplays, let online = Self.onlineDisplays() {
            for id in replacementDisplays.compactMap({ $0.resolve(in: online) }) {
                guard APConfigureDisplayEnabled(layout, id, false) == .success else {
                    CGCancelDisplayConfiguration(layout)
                    return false
                }
            }
        }
        for (saved, id) in resolved {
            let modes = CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary) as? [CGDisplayMode] ?? []
            if let mode = modes.first(where: { $0.ioDisplayModeID == saved.modeID && $0.pixelWidth == saved.pixelWidth && $0.pixelHeight == saved.pixelHeight }) ?? modes.first(where: { $0.width == saved.width && $0.height == saved.height && $0.pixelWidth == saved.pixelWidth && $0.pixelHeight == saved.pixelHeight }) {
                _ = CGConfigureDisplayWithDisplayMode(layout, id, mode, nil)
            }
            if replacements == nil {
                _ = CGConfigureDisplayOrigin(layout, id, saved.x, saved.y)
                let mirror = resolved.first(where: { $0.0.id == saved.mirror })?.1 ?? kCGNullDirectDisplay
                _ = CGConfigureDisplayMirrorOfDisplay(layout, id, mirror)
            }
        }
        if replacements != nil, !configureArrangement(layout, ids: resolved) {
            CGCancelDisplayConfiguration(layout)
            return false
        }
        guard CGCompleteDisplayConfiguration(layout, .forSession) == .success else { return false }
        if let originalMain = resolved.first(where: { $0.0.id == mainID })?.1, CGMainDisplayID() != originalMain { return false }
        let attached = Self.allDisplays()
        return physical.allSatisfy { saved in
            guard let id = saved.resolve(in: attached) else { return true }
            return CGDisplayIsOnline(id) == 1
        }
    }
}

/// A per-blackout child of the signed application. It owns no remote listener,
/// password or video stream, and exits after restoring the displays.
@MainActor
public enum PhysicalDisplayWatchdog {
    nonisolated static func isRestoreInput(_ event: CGEvent, isActive: Bool) -> Bool {
        isActive && event.getIntegerValueField(.eventSourceUnixProcessID) == 0 &&
            event.getIntegerValueField(.eventSourceUserData) != 0x41575045545243
    }

    private final class Input {
        var tap: CFMachPort?
        var source: CFRunLoopSource?
        var requested = false
        var armed = false
        var committedPath: String?

        var isActive: Bool {
            guard let committedPath else { return armed }
            return FileManager.default.fileExists(atPath: committedPath)
        }
        func start() -> Bool {
            guard CGPreflightListenEventAccess() else { return false }
            let types: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                   eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let input = Unmanaged<Input>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    input.requested = true // Restore rather than losing the escape route.
                } else if PhysicalDisplayWatchdog.isRestoreInput(event, isActive: input.isActive) {
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
        if layout.replacements != nil { input.committedPath = directory.appendingPathComponent("committed").path }
        guard input.start() else { return 3 }
        defer { input.stop() }
        try? Data("ready".utf8).write(to: directory.appendingPathComponent("ready"), options: .atomic)
        let began = ProcessInfo.processInfo.systemUptime
        var activeSince: TimeInterval?
        var committedSince: TimeInterval?
        var reason = "parent-exited"
        var showDesktop = false
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            let active = FileManager.default.fileExists(atPath: directory.appendingPathComponent("active").path)
            if active && activeSince == nil { activeSince = now }
            if committedSince == nil, let path = input.committedPath, FileManager.default.fileExists(atPath: path) {
                committedSince = now
            }
            let topologySettled = (input.committedPath == nil ? activeSince : committedSince).map { now - $0 > 0.8 } ?? false
            input.armed = input.committedPath == nil ? topologySettled : committedSince != nil
            if input.requested { reason = "local-input"; break }
            if let request = try? String(contentsOf: directory.appendingPathComponent("restore"), encoding: .utf8) {
                reason = "requested"; showDesktop = request == "show-desktop"; break
            }
            if kill(layout.owner, 0) != 0 { break }
            let lease = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("lease").path)[.modificationDate] as? Date
            if now - began > 8 && (lease == nil || Date().timeIntervalSince(lease!) > 8) { reason = "heartbeat-expired"; break }
            if active && CGDisplayIsOnline(layout.virtualID) != 1 { reason = "virtual-display-lost"; break }
            if topologySettled && !layout.onlyVirtualOnline {
                reason = "display-topology-changed"; break
            }
            if input.armed && layout.replacements != nil {
                let session = DesktopSessionSnapshot.current()
                if !session.available || !session.onConsole || session.locked {
                    reason = "local-session-changed"; break
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        var restored = activeSince == nil && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("active").path)
        if !restored {
            try? Data().write(to: directory.appendingPathComponent("recovering"), options: .atomic)
            if layout.lockBeforeRestore == true && !showDesktop { try? await DesktopSession.ensureLocked() }
            for _ in 0..<10 {
                if layout.restore() { restored = true; break }
                try? await Task.sleep(for: .milliseconds(300))
            }
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
    private var restoring = false
    public private(set) var isActive = false
    public var isIsolated: Bool {
        isActive && !restoring && process?.isRunning == true && layout?.onlyVirtualOnline == true &&
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent("recovering").path)
    }
    public static var isAvailable: Bool { BlackoutLayout.supported }
    public static var canObserveLocalInput: Bool { CGPreflightListenEventAccess() }
    public static func physicalDisplaysAreAsleep(excluding virtualIDs: Set<UInt32>) -> Bool {
        guard let displays = BlackoutLayout.onlineDisplays() else { return true }
        return displays.filter { !virtualIDs.contains($0) }.allSatisfy { CGDisplayIsAsleep($0) != 0 }
    }

    public init(directory: URL) { self.directory = directory }

    public func recoverPreviousSession(allowLock: Bool = true) async throws {
        let path = directory.appendingPathComponent("layout.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let data = try Data(contentsOf: path)
        guard data.count < 65536 else { throw RemoteError.message("Invalid display recovery record.") }
        let saved = try JSONDecoder().decode(BlackoutLayout.self, from: data)
        if saved.lockBeforeRestore != nil && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("active").path) {
            try FileManager.default.removeItem(at: directory)
            return
        }
        // A previous watchdog can still be finishing an autonomous recovery
        // after the parent released its host lock. Let it finish before reuse.
        let resultURL = directory.appendingPathComponent("result.json")
        for _ in 0..<40 {
            if let data = try? Data(contentsOf: resultURL),
               let result = try? JSONDecoder().decode([String: String].self, from: data) {
                if result["restored"] == "true" {
                    try FileManager.default.removeItem(at: directory)
                    return
                }
                break
            }
            let recovering = directory.appendingPathComponent("recovering").path
            let ready = directory.appendingPathComponent("ready").path
            guard FileManager.default.fileExists(atPath: recovering) ||
                (saved.owner != getpid() && FileManager.default.fileExists(atPath: ready)) else { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        if saved.lockBeforeRestore == true {
            guard allowLock else { throw RemoteError.message("Physical display restoration is incomplete. Retrying.") }
            try? await DesktopSession.ensureLocked()
        }
        try Task.checkCancellation()
        guard saved.restore() else { throw RemoteError.message("Previously disabled physical displays are not fully restored. Connect a physical display and try again.") }
        try FileManager.default.removeItem(at: directory)
    }

    public func begin(virtualID: UInt32, lockBeforeRestore: Bool = false,
                      mayCommit: () -> Bool = { true }) async throws {
        try await begin(layout: BlackoutLayout(virtualID: virtualID, lockBeforeRestore: lockBeforeRestore), mayCommit: mayCommit)
    }

    public func begin(snapshot: PhysicalDisplaySnapshot, replacements: [UInt32: UInt32],
                      mayCommit: () -> Bool) async throws {
        try await begin(layout: BlackoutLayout(snapshot: snapshot, replacements: replacements), mayCommit: mayCommit)
    }

    private func begin(layout saved: BlackoutLayout, mayCommit: () -> Bool) async throws {
        guard !isActive, process == nil else { throw RemoteError.message("Physical display shutdown is already in progress.") }
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("layout.json").path) else {
            throw RemoteError.message("Physical display restoration is incomplete. Retrying.")
        }
        guard Self.canObserveLocalInput else { throw RemoteError.message("Grant Vela Input Monitoring access in System Settings so local input can restore physical displays.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["ready", "active", "committed", "restore", "recovering", "result.json"] { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        layout = saved
        let child = Process()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["--remote-display-watchdog", directory.path]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        process = child
        do {
            try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent("layout.json"), options: .atomic)
            try Data().write(to: directory.appendingPathComponent("lease"), options: .atomic)
            try child.run()
            for _ in 0..<40 {
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path) { break }
                guard child.isRunning else { throw RemoteError.message("Local input recovery monitoring could not start. Check Input Monitoring access.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard child.isRunning, FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path) else {
                throw RemoteError.message("Display recovery protection is not ready. No physical displays were turned off.")
            }
            try Task.checkCancellation()
            guard process === child, child.isRunning, mayCommit() else { throw RemoteError.message("Connection canceled.") }
            // Persist recovery intent before the atomic WindowServer commit.
            try Data().write(to: directory.appendingPathComponent("active"), options: .atomic)
            try saved.disablePhysicalDisplays()
            isActive = true
            if saved.replacements != nil {
                try Data().write(to: directory.appendingPathComponent("committed"), options: .atomic)
            }
            for _ in 0..<30 {
                guard process === child, mayCommit() else { throw RemoteError.message("Connection canceled.") }
                if isIsolated { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw RemoteError.message("The system did not disable all physical displays.")
        } catch {
            if process === child {
                // A failed transaction can be ambiguous if WindowServer exited.
                // Keep the recovery record when the saved topology disappeared.
                if !isActive, FileManager.default.fileExists(atPath: directory.appendingPathComponent("active").path),
                   saved.topologyChanged {
                    isActive = true
                }
                await restore()
            }
            throw error
        }
    }

    /// Returns a recovery reason once. A hardware wake leaves the virtual screen
    /// available so the remote user can continue or explicitly select another.
    public func heartbeat() async -> String? {
        guard isActive else { return nil }
        try? Data().write(to: directory.appendingPathComponent("lease"), options: .atomic)
        guard !restoring else { return nil }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("result.json")),
           let result = try? JSONDecoder().decode([String: String].self, from: data) {
            if result["restored"] == "true" {
                isActive = false; layout = nil; process = nil
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("layout.json"))
                return result["reason"] ?? "restored"
            }
            return await restore() ? (result["reason"] ?? "restored") : "restore-failed"
        }
        if process?.isRunning != true {
            return await restore() ? "watchdog-exited" : "restore-failed"
        }
        return nil
    }

    @discardableResult
    public func restore(showDesktop: Bool = false) async -> Bool {
        if restoring {
            while restoring {
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return false }
            }
            return !isActive
        }
        guard layout != nil || process != nil else { return !isActive }
        if !isActive {
            if process?.isRunning == true { process?.terminate() }
            process = nil; layout = nil
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("layout.json"))
            return true
        }
        restoring = true
        defer { restoring = false }
        // Recovery must complete even when the caller is cancelling an in-flight
        // capture or exiting. A cancelled sleep would exhaust the child wait immediately.
        return await Task { await completeRestore(showDesktop: showDesktop) }.value
    }

    private func completeRestore(showDesktop: Bool) async -> Bool {
        try? Data((showDesktop ? "show-desktop" : "").utf8).write(to: directory.appendingPathComponent("restore"), options: .atomic)
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
        if layout?.lockBeforeRestore == true && !showDesktop { try? await DesktopSession.ensureLocked() }
        let restored = layout?.restore() ?? !isActive
        if restored {
            if process?.isRunning == true { process?.terminate() }
            isActive = false; layout = nil; process = nil
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("layout.json"))
        }
        return restored
    }
}
