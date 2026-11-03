import CoreGraphics
import Foundation
import RemoteCore

/// The numeric display ID changes when WindowServer detaches a user session.
/// Resolve only an unambiguous hardware identity; never choose an arbitrary screen.
public struct DesktopDisplayIdentity: Sendable {
    private let vendor: UInt32
    private let model: UInt32
    private let serial: UInt32
    private let x: Double
    private let y: Double

    public init(displayID: UInt32) {
        vendor = CGDisplayVendorNumber(displayID); model = CGDisplayModelNumber(displayID)
        serial = CGDisplaySerialNumber(displayID)
        let bounds = CGDisplayBounds(displayID); x = bounds.minX; y = bounds.minY
    }

    public func resolve(in displays: [RemoteDisplay]) -> UInt32? {
        let sameHardware = displays.filter {
            CGDisplayVendorNumber($0.id) == vendor && CGDisplayModelNumber($0.id) == model && CGDisplaySerialNumber($0.id) == serial
        }
        if sameHardware.count == 1 { return sameHardware[0].id }
        let sameOrigin = sameHardware.filter { CGDisplayBounds($0.id).minX == x && CGDisplayBounds($0.id).minY == y }
        return sameOrigin.count == 1 ? sameOrigin[0].id : nil
    }
}
