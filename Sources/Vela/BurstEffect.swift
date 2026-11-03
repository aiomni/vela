import AppKit

/// One bounded, deterministic burst. No particle timers or retained particle objects.
struct BurstEffect {
    static let duration: TimeInterval = 0.78
    let age: TimeInterval
    var progress: Double { min(1, max(0, age / Self.duration)) }
    var isActive: Bool { age >= 0 && age < Self.duration }
    var bodyScale: Double {
        guard isActive else { return 1 }
        return 1 - 0.16 * exp(-progress * 7) * cos(progress * .pi * 5)
    }
    func radius(for index: Int) -> Double {
        let travel = 1 - pow(1 - progress, 3)
        return 48 + travel * (105 + Double(index % 4) * 8)
    }

    @MainActor func draw(enabled: Bool, palette: PetPalette = .orange, customColor: NSColor = .systemOrange) {
        guard isActive else { return }
        let p = progress
        let center = NSPoint(x: 114.27, y: 114.27)
        let colors = palette.colors(custom: customColor)
        let tint = colors[0]
        if p < 0.3 {
            let flare = NSBezierPath()
            let growth = min(1, p / 0.1)
            for index in 0..<16 {
                let angle = Double(index) * .pi / 8
                let radius = (index.isMultiple(of: 2) ? 128.0 : 42.0) * growth
                let point = NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                if index == 0 { flare.move(to: point) } else { flare.line(to: point) }
            }
            flare.close()
            (enabled ? tint : NSColor.white).withAlphaComponent((1 - p / 0.3) * 0.9).setFill()
            flare.fill()
        }
        // A bright expanding shock wave, then separate ballistic sparks with tails.
        let ringRadius = 30 + 144 * (1 - pow(1 - p, 2))
        tint.withAlphaComponent(pow(1 - p, 2) * 0.85).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - ringRadius, y: center.y - ringRadius,
            width: ringRadius * 2, height: ringRadius * 2))
        ring.lineWidth = 2 + 7 * (1 - p)
        ring.stroke()
        for index in 0..<20 {
            let sparkColor = colors[index % colors.count]
            let angle = Double(index) * .pi / 10 + Double(index % 3) * 0.09
            let radius = radius(for: index)
            let end = NSPoint(x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius + p * p * 12)
            let tail = 8 + 23 * (1 - p)
            let start = NSPoint(x: end.x - cos(angle) * tail, y: end.y - sin(angle) * tail)
            let alpha = pow(1 - p, 1.25)
            (index.isMultiple(of: 3) ? NSColor.white : sparkColor).withAlphaComponent(alpha).setStroke()
            let ray = NSBezierPath()
            ray.move(to: start)
            ray.line(to: end)
            ray.lineWidth = (index.isMultiple(of: 3) ? 5 : 3) * (1 - p) + 1
            ray.lineCapStyle = .round
            ray.stroke()
            if index.isMultiple(of: 2) {
                sparkColor.withAlphaComponent(alpha).setFill()
                let dot = 3 + 3 * (1 - p)
                NSBezierPath(ovalIn: NSRect(x: end.x - dot, y: end.y - dot,
                    width: dot * 2, height: dot * 2)).fill()
            }
        }
    }
}
