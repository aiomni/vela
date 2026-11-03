import VelaLocalization
import AppKit

enum ColorTransitionStyle: String, CaseIterable {
    case radial, corner, burst, fade
    var title: String {
        switch self {
        case .radial: L("Expand from center")
        case .corner: L("Expand from top left")
        case .burst: L("Radial burst")
        case .fade: L("Smooth fade")
        }
    }
    @MainActor func mask(at progress: Double) -> NSBezierPath? {
        guard self != .fade else { return nil }
        if progress >= 1 { return NSBezierPath(rect: NSRect(x: -30, y: -30, width: 290, height: 290)) }
        let amount = max(0, progress)
        let origin = self == .corner ? NSPoint.zero : NSPoint(x: 114.27, y: 114.27)
        if self != .burst {
            let radius = (self == .corner ? 325.0 : 165.0) * amount
            return NSBezierPath(ovalIn: NSRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2))
        }
        let path = NSBezierPath()
        for index in 0..<32 {
            let angle = Double(index) * .pi / 16
            let radius = (index.isMultiple(of: 2) ? 185.0 : 135.0) * amount
            let point = NSPoint(x: origin.x + cos(angle) * radius, y: origin.y + sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        return path
    }
}
