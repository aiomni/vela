import AppKit

@MainActor
enum MaterialEffects {
    private static func color(_ r: Double, _ g: Double, _ b: Double, _ alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
    private static func haze(at center: CGPoint, radius: CGFloat, color: NSColor) {
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
        NSGraphicsContext.current!.cgContext.drawRadialGradient(gradient, startCenter: center,
            startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    static func draw(_ effect: PetPalette, body: NSBezierPath, time: Double, opacity: Double) {
        NSGraphicsContext.current!.cgContext.setAlpha(opacity)
        switch effect {
        case .siri:
            NSGradient(colors: [color(0.035, 0.045, 0.14), color(0.14, 0.055, 0.22)])!.draw(in: body, angle: 100)
            let tones = [color(0.14, 0.78, 1), color(0.92, 0.24, 0.66), color(0.55, 0.27, 1), color(1, 0.64, 0.3)]
            let breath = 0.93 + sin(time * 0.7) * 0.07
            for index in 0..<4 {
                let phase = time * 0.28 + Double(index) * .pi / 2
                let center = CGPoint(x: 114 + cos(phase) * 67, y: 114 + sin(phase * 0.9) * 67)
                haze(at: center, radius: 125 * breath, color: tones[index].withAlphaComponent(index == 3 ? 0.42 : 0.82))
            }
            // Deforming luminous loops create fluid movement rather than a rotating static image.
            for index in 0..<3 {
                let loop = NSBezierPath()
                let phase = time * 0.4 + Double(index) * 2.1
                for step in 0...96 {
                    let angle = Double(step) * .pi * 2 / 96
                    let radius = (69 + sin(angle * 2 + phase) * 17 + cos(angle * 3 - phase * 0.6) * 7) * breath
                    let point = NSPoint(x: 114 + cos(angle + phase * 0.12) * radius,
                        y: 114 + sin(angle + phase * 0.12) * radius * 0.86)
                    if step == 0 { loop.move(to: point) } else { loop.line(to: point) }
                }
                loop.close()
                loop.lineJoinStyle = .round
                for step in 0..<20 {
                    loop.lineWidth = 36 - Double(step) * 1.6
                    tones[index].withAlphaComponent(0.013 + Double(step) * 0.001).setStroke()
                    loop.stroke()
                }
            }
            haze(at: CGPoint(x: 111 + sin(time * 0.35) * 14, y: 140 + cos(time * 0.3) * 12),
                radius: 48 * breath, color: color(0.86, 0.91, 1, 0.2))
            let rim = body.copy() as! NSBezierPath
            rim.lineWidth = 5
            color(0.7, 0.8, 1, 0.22).setStroke()
            rim.stroke()
        case .aurora:
            NSGradient(colors: [color(0.025, 0.08, 0.16), color(0.1, 0.14, 0.26)])!.draw(in: body, angle: 90)
            let tones = [color(0.2, 0.95, 0.66), color(0.16, 0.7, 1), color(0.65, 0.35, 1)]
            for index in 0..<3 {
                let ribbon = NSBezierPath()
                let phase = time * 0.26 + Double(index) * 1.9
                func point(_ step: Int) -> NSPoint {
                    let y = Double(step) * 12 - 12
                    let x = 28 + Double(index) * 73 + sin(y * 0.018 + phase) * 27 + sin(y * 0.007 - phase * 0.6) * 18
                    return NSPoint(x: x, y: y)
                }
                ribbon.move(to: point(0))
                for step in 1...22 { ribbon.line(to: point(step)) }
                ribbon.lineCapStyle = .round
                ribbon.lineJoinStyle = .round
                // Nested faint strokes feather the curtain into the night sky without hard edges.
                for step in 0..<36 {
                    let width = 108.0 - Double(step) * 3
                    let alpha = 0.023 * exp(-pow(width / 62, 2) / 2)
                    ribbon.lineWidth = width
                    tones[index].withAlphaComponent(alpha * (0.9 + sin(phase * 0.6) * 0.1)).setStroke()
                    ribbon.stroke()
                }
            }
            haze(at: CGPoint(x: 120 + sin(time * 0.18) * 45, y: 155), radius: 120, color: color(0.2, 0.7, 0.75, 0.18))
        case .neon:
            color(0.025, 0.035, 0.085).setFill()
            body.fill()
            // Broad low-opacity strokes form the glow; narrow strokes keep a crisp silhouette.
            for width in [28.0, 17, 8] {
                let rim = body.copy() as! NSBezierPath
                rim.lineWidth = width
                color(0.25, 0.55, 1, (width == 8 ? 0.32 : 0.09) * (0.9 + sin(time * 0.7) * 0.1)).setStroke()
                rim.stroke()
            }
            let context = NSGraphicsContext.current!.cgContext
            context.saveGState()
            for index in 0..<96 {
                let angle = Double(index) * .pi * 2 / 96
                let hue = (Double(index) / 96 + time * 0.045).truncatingRemainder(dividingBy: 1)
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 114.27, y: 114.27))
                path.line(to: NSPoint(x: 114.27 + cos(angle) * 170, y: 114.27 + sin(angle) * 170))
                path.line(to: NSPoint(x: 114.27 + cos(angle + 0.068) * 170, y: 114.27 + sin(angle + 0.068) * 170))
                path.close()
                context.saveGState()
                path.addClip()
                let rim = body.copy() as! NSBezierPath
                rim.lineWidth = 7
                NSColor(calibratedHue: hue, saturation: 0.7, brightness: 1, alpha: 1).setStroke()
                rim.stroke()
                context.restoreGState()
            }
            context.restoreGState()
        case .stars:
            NSGradient(colors: [color(0.025, 0.035, 0.12), color(0.1, 0.055, 0.22)])!.draw(in: body, angle: 65)
            haze(at: CGPoint(x: 145 + sin(time * 0.13) * 35, y: 163 + cos(time * 0.17) * 20),
                radius: 100, color: color(0.42, 0.25, 0.8, 0.2))
            for index in 0..<14 {
                let x = Double((index * 83 + 31) % 194) + 17 + sin(time * 0.2 + Double(index)) * 3
                let y = Double((index * 61 + 19) % 194) + 17 + cos(time * 0.17 + Double(index)) * 3
                let shine = 0.2 + 0.7 * pow((sin(time * 0.75 + Double(index) * 2.3) + 1) / 2, 2)
                let radius = (index.isMultiple(of: 4) ? 4.2 : 2.8) * (0.85 + shine * 0.15)
                haze(at: CGPoint(x: x, y: y), radius: radius * 3.5, color: color(0.55, 0.76, 1, shine * 0.28))
                color(0.85, 0.93, 1, shine).setFill()
                NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)).fill()
                if index.isMultiple(of: 4) {
                    let cross = NSBezierPath()
                    cross.move(to: NSPoint(x: x - 7, y: y)); cross.line(to: NSPoint(x: x + 7, y: y))
                    cross.move(to: NSPoint(x: x, y: y - 7)); cross.line(to: NSPoint(x: x, y: y + 7))
                    cross.lineWidth = 1.5
                    color(0.85, 0.93, 1, shine * 0.55).setStroke()
                    cross.stroke()
                }
            }
        default: break
        }
    }
}
