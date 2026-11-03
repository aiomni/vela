import AppKit
import RemoteCore
import RemoteDisplayBridge

@MainActor
public final class VirtualDisplay {
    private var handle: APVirtualDisplayRef?
    private let createdID: UInt32
    private let serialNumber: UInt32
    public var id: UInt32 {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        if CGGetActiveDisplayList(32, &ids, &count) == .success,
           let current = ids.prefix(Int(count)).first(where: {
               CGDisplayVendorNumber($0) == 0x4157 && CGDisplayModelNumber($0) == 1 && CGDisplaySerialNumber($0) == serialNumber
           }) { return current }
        return createdID
    }
    public let configuration: VirtualDisplayConfiguration
    public static var isAvailable: Bool { APVirtualDisplayIsAvailable() }
    public var currentSystemID: UInt32 { handle.map(APVirtualDisplayGetID) ?? 0 }

    public init(configuration: VirtualDisplayConfiguration) throws {
        try configuration.validate()
        guard Self.isAvailable else { throw RemoteError.message("This system does not support Vela virtual displays.") }
        let serial = UInt32.random(in: 1...UInt32.max)
        guard let handle = APVirtualDisplayCreate(UInt32(configuration.width), UInt32(configuration.height),
                                                  configuration.hiDPI, serial) else {
            throw RemoteError.message("The system could not create a virtual display. Existing displays remain connected.")
        }
        self.handle = handle; self.createdID = APVirtualDisplayGetID(handle); self.serialNumber = serial; self.configuration = configuration
    }

    /// WindowServer may initially select a generated 1x mode even for a HiDPI
    /// descriptor. Select and verify the exact mode before advertising readiness.
    public func prepare() async throws {
        for _ in 0..<40 {
            guard handle != nil else { throw RemoteError.message("Virtual display creation canceled.") }
            let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
            let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
            if let mode = modes.first(where: {
                $0.pixelWidth == configuration.width && $0.pixelHeight == configuration.height &&
                $0.width == configuration.logicalWidth && $0.height == configuration.logicalHeight
            }) {
                var transaction: CGDisplayConfigRef?
                guard CGBeginDisplayConfiguration(&transaction) == .success, let transaction else {
                    throw RemoteError.message("Unable to begin virtual display configuration.")
                }
                var ids = [CGDirectDisplayID](repeating: 0, count: 32)
                var count: UInt32 = 0
                guard CGGetActiveDisplayList(32, &ids, &count) == .success else {
                    CGCancelDisplayConfiguration(transaction); throw RemoteError.message("Unable to read the existing display layout.")
                }
                let right = ids.prefix(Int(count)).filter { $0 != id }.map { CGDisplayBounds($0).maxX }.max() ?? 0
                guard CGConfigureDisplayWithDisplayMode(transaction, id, mode, nil) == .success,
                      CGConfigureDisplayMirrorOfDisplay(transaction, id, kCGNullDirectDisplay) == .success,
                      CGConfigureDisplayOrigin(transaction, id, Int32(right), 0) == .success else {
                    CGCancelDisplayConfiguration(transaction); throw RemoteError.message("Unable to configure virtual display resolution or position.")
                }
                guard CGCompleteDisplayConfiguration(transaction, .forSession) == .success else {
                    throw RemoteError.message("The system rejected the virtual display configuration.")
                }
                for _ in 0..<20 {
                    guard handle != nil else { throw RemoteError.message("Virtual display creation canceled.") }
                    let actual = CGDisplayCopyDisplayMode(id)
                    let bounds = CGDisplayBounds(id)
                    if actual?.pixelWidth == configuration.width && actual?.pixelHeight == configuration.height &&
                        Int(bounds.width) == configuration.logicalWidth && Int(bounds.height) == configuration.logicalHeight { return }
                    try await Task.sleep(for: .milliseconds(50))
                }
                throw RemoteError.message("The virtual display resolution did not match the request. Creation canceled.")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw RemoteError.message("The system did not provide the requested virtual display mode.")
    }

    public func close() {
        guard let handle else { return }
        self.handle = nil; APVirtualDisplayDestroy(handle)
    }

    deinit {
        // A CoreGraphics virtual screen is process-owned; release also removes it.
        if let handle { APVirtualDisplayDestroy(handle) }
    }
}
