import Foundation

public struct VirtualDisplayConfiguration: Codable, Equatable, Sendable {
    /// Actual backing pixels, not scaled desktop points.
    public let width: Int
    public let height: Int
    public let hiDPI: Bool
    public init(width: Int, height: Int, hiDPI: Bool) {
        self.width = width; self.height = height; self.hiDPI = hiDPI
    }
    public var logicalWidth: Int { width / (hiDPI ? 2 : 1) }
    public var logicalHeight: Int { height / (hiDPI ? 2 : 1) }
    public func validate() throws {
        guard (640...3840).contains(width), (480...3840).contains(height),
              width * height <= 3840 * 2160, width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw RemoteError.message("Virtual display dimensions must be even: width 640–3840, height 480–3840, with no more than 3840×2160 total pixels.")
        }
        let portrait = height > width
        guard !hiDPI || (logicalWidth >= (portrait ? 480 : 640) && logicalHeight >= (portrait ? 640 : 480)) else {
            throw RemoteError.message("HiDPI needs at least 640×480 landscape or 480×640 portrait desktop points. Increase the pixel resolution or turn off HiDPI.")
        }
    }
}
