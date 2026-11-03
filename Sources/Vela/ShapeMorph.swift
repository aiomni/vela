import AppKit

/// A common radial contour gives unlike path command lists matching points.
@MainActor
enum ShapeMorphGeometry {
    static let center = NSPoint(x: 114.27, y: 114.27)
    static let ringCount = 128

    static func ring(for shape: PetGeometry.Shape) -> [NSPoint] {
        let contour = flatten(shape.body)
        return (0..<ringCount).map { index in
            let angle = CGFloat(index) * 2 * .pi / CGFloat(ringCount)
            let direction = NSPoint(x: cos(angle), y: sin(angle))
            var radius: CGFloat = 0
            for i in contour.indices {
                let a = contour[i], b = contour[(i + 1) % contour.count]
                let sx = b.x - a.x, sy = b.y - a.y
                let denominator = direction.x * sy - direction.y * sx
                if abs(denominator) < 1e-9 { continue }
                let px = a.x - center.x, py = a.y - center.y
                let alongRay = (px * sy - py * sx) / denominator
                let alongEdge = (px * direction.y - py * direction.x) / denominator
                if alongRay > radius && alongEdge >= 0 && alongEdge <= 1 { radius = alongRay }
            }
            return NSPoint(x: center.x + direction.x * radius, y: center.y + direction.y * radius)
        }
    }

    static func interpolate(_ a: [NSPoint], _ b: [NSPoint], _ amount: CGFloat) -> [NSPoint] {
        precondition(a.count == b.count)
        return zip(a, b).map { p, q in
            NSPoint(x: p.x + (q.x - p.x) * amount, y: p.y + (q.y - p.y) * amount)
        }
    }

    static func zoomCovering(_ ring: [NSPoint]) -> CGFloat {
        let radius = ring.map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? 114.27
        return max(1, radius / 114.27 * 1.02)
    }

    static func interpolate(_ a: PetGeometry.Face, _ b: PetGeometry.Face, _ amount: CGFloat) -> PetGeometry.Face {
        let t = Double(amount)
        func blend(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        return PetGeometry.Face(x: blend(a.x, b.x), y: blend(a.y, b.y),
            sx: blend(a.sx, b.sx), sy: blend(a.sy, b.sy), eye: blend(a.eye, b.eye),
            leftDX: blend(a.leftDX ?? 0, b.leftDX ?? 0))
    }

    static func path(_ ring: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard !ring.isEmpty else { return path }
        path.move(to: ring[0])
        for i in ring.indices {
            let a = ring[(i + ring.count - 1) % ring.count]
            let b = ring[i]
            let c = ring[(i + 1) % ring.count]
            let d = ring[(i + 2) % ring.count]
            path.curve(to: c,
                controlPoint1: NSPoint(x: b.x + (c.x - a.x) / 6, y: b.y + (c.y - a.y) / 6),
                controlPoint2: NSPoint(x: c.x - (d.x - b.x) / 6, y: c.y - (d.y - b.y) / 6))
        }
        path.close()
        return path
    }

    private static func flatten(_ segments: [PetGeometry.Segment]) -> [NSPoint] {
        var points: [NSPoint] = []
        var current = center
        var first = center
        func sample(to end: NSPoint, length: CGFloat, point: (CGFloat) -> NSPoint) {
            let count = max(2, Int(ceil(length / 4)))
            for step in 1...count { points.append(point(CGFloat(step) / CGFloat(count))) }
            current = end
        }
        for segment in segments {
            let v = segment.values.map { CGFloat($0) }
            switch segment.command {
            case "M":
                current = NSPoint(x: v[0], y: v[1]); first = current; points.append(current)
            case "L":
                let start = current, end = NSPoint(x: v[0], y: v[1])
                sample(to: end, length: hypot(end.x - start.x, end.y - start.y)) { t in
                    NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                }
            case "Q":
                let start = current, control = NSPoint(x: v[0], y: v[1]), end = NSPoint(x: v[2], y: v[3])
                let length = hypot(control.x - start.x, control.y - start.y) + hypot(end.x - control.x, end.y - control.y)
                sample(to: end, length: length) { t in
                    let s = 1 - t
                    let a = s * s, b = 2 * s * t, c = t * t
                    return NSPoint(x: a * start.x + b * control.x + c * end.x,
                                   y: a * start.y + b * control.y + c * end.y)
                }
            case "C":
                let start = current, c1 = NSPoint(x: v[0], y: v[1]), c2 = NSPoint(x: v[2], y: v[3])
                let end = NSPoint(x: v[4], y: v[5])
                let length = hypot(c1.x - start.x, c1.y - start.y) + hypot(c2.x - c1.x, c2.y - c1.y)
                    + hypot(end.x - c2.x, end.y - c2.y)
                sample(to: end, length: length) { t in
                    let s = 1 - t
                    let a = s * s * s, b = 3 * s * s * t, c = 3 * s * t * t, d = t * t * t
                    return NSPoint(x: a * start.x + b * c1.x + c * c2.x + d * end.x,
                                   y: a * start.y + b * c1.y + c * c2.y + d * end.y)
                }
            case "Z":
                if hypot(current.x - first.x, current.y - first.y) > 0.01 {
                    let start = current, end = first
                    sample(to: end, length: hypot(end.x - start.x, end.y - start.y)) { t in
                        NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                    }
                }
            default: break
            }
        }
        return points
    }
}

struct ShapeMorphState {
    let fromRing: [NSPoint]
    let fromFace: PetGeometry.Face
    let fromPath: NSBezierPath
    let fromZoom: CGFloat
    let startedAt: TimeInterval

    func progress(at time: TimeInterval) -> CGFloat {
        let elapsed = max(0, time - startedAt)
        if elapsed >= 0.65 { return 1 }
        let spring = min(1, max(0, 1 - (1 + 10 * elapsed) * exp(-10 * elapsed)))
        return CGFloat(spring < 0.5 ? 4 * spring * spring * spring
            : 1 - pow(-2 * spring + 2, 3) / 2)
    }
}
