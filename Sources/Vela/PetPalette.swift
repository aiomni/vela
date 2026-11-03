import VelaLocalization
import AppKit

enum PetColorMode: String, CaseIterable {
    case solid, linear, radial
    var title: String {
        switch self { case .solid: L("Solid"); case .linear: L("Linear gradient"); case .radial: L("Radial gradient") }
    }
}

enum PetPalette: String, CaseIterable {
    case custom, rainbow, camouflage, glass, mosaic, soccer, basketball, pokeball, aurora, aurora2, neon, neonFlow, stars, nebula, whales, siri
    case black, brown, red, orange, yellow, green, cyan, blue, violet, magenta, gray
    case purple // Legacy saved preference.
    static let selectable: [Self] = [.rainbow, .aurora, .aurora2, .stars, .nebula, .whales, .neon, .neonFlow, .siri, .camouflage, .glass, .mosaic, .soccer, .basketball, .pokeball]
    static let inkSelectable: [Self] = [.black, .brown, .red, .orange, .yellow, .green, .cyan, .blue, .violet, .magenta, .gray, .custom]
    var shaderKind: UInt32? {
        switch self {
        case .rainbow: 0
        case .aurora: 1
        case .aurora2: 2
        case .stars: 3
        case .nebula: 4
        case .whales: 5
        case .neon: 6
        case .neonFlow: 7
        case .siri: 8
        case .camouflage: 9
        case .glass: 10
        case .mosaic: 11
        case .soccer: 12
        case .basketball: 13
        case .pokeball: 14
        default: nil
        }
    }
    var drawsBase: Bool { shaderKind != nil }
    var title: String {
        switch self {
        case .siri: L("Aura")
        case .aurora: L("Aurora")
        case .aurora2: L("Silk")
        case .neon: L("Night Rhythm")
        case .neonFlow: L("Flow")
        case .stars: L("Star Ring")
        case .nebula: L("Nebula")
        case .whales: L("Whale Dream")
        case .custom: L("Plain")
        case .camouflage: L("Forest")
        case .glass: L("Glass")
        case .mosaic: L("Mosaic Ball")
        case .soccer: L("Soccer")
        case .basketball: L("Basketball")
        case .pokeball: L("Poke Ball")
        case .rainbow: L("Iridescence")
        case .orange: L("Warm Orange")
        case .blue: L("Blue")
        case .purple: L("Violet")
        case .green: L("Green")
        case .black: L("Black")
        case .brown: L("Brown")
        case .red: L("Red")
        case .yellow: L("Yellow")
        case .cyan: L("Cyan")
        case .violet: L("Purple")
        case .magenta: L("Magenta")
        case .gray: L("Gray")
        }
    }
    @MainActor var colors: [NSColor] {
        func rgb(_ r: Double, _ g: Double, _ b: Double) -> NSColor {
            NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
        }
        switch self {
        case .siri: return [rgb(0.2, 0.8, 1), rgb(0.95, 0.3, 0.65), rgb(0.6, 0.3, 1)]
        case .aurora, .aurora2: return [rgb(0.2, 0.95, 0.66), rgb(0.3, 0.4, 1)]
        case .neon, .neonFlow: return [rgb(0.25, 0.65, 1), rgb(0.8, 0.3, 1)]
        case .stars, .nebula, .whales: return [rgb(0.5, 0.7, 1), rgb(0.6, 0.4, 0.9)]
        case .custom: return [.systemOrange, .systemOrange]
        case .camouflage: return [rgb(0.58, 0.64, 0.34), rgb(0.18, 0.29, 0.16), rgb(0.78, 0.73, 0.48)]
        case .glass: return [rgb(0.72, 0.93, 1), rgb(0.4, 0.56, 0.8), rgb(0.9, 0.77, 1)]
        case .mosaic: return [rgb(0.06, 0.46, 0.57), rgb(0.12, 0.23, 0.34), rgb(1, 0.56, 0.13)]
        case .soccer: return [rgb(0.92, 0.94, 0.91), rgb(0.06, 0.07, 0.09)]
        case .basketball: return [rgb(1, 0.43, 0.06), rgb(0.22, 0.10, 0.03)]
        case .pokeball: return [rgb(0.91, 0.03, 0.06), rgb(0.94, 0.93, 0.97), rgb(0.02, 0.02, 0.03)]
        case .rainbow: return [rgb(1, 0.15, 0.22), rgb(1, 0.5, 0.08), rgb(1, 0.82, 0.05), rgb(0.15, 0.72, 0.34), rgb(0.06, 0.53, 1), rgb(0.24, 0.27, 0.77), rgb(0.65, 0.2, 0.86)]
        case .black: return [Self.inkColor("#000000"), Self.inkColor("#FFFFFF")]
        case .brown: return [Self.inkColor("#A27952"), Self.inkColor("#855C36")]
        case .red: return [Self.inkColor("#FF3E51"), Self.inkColor("#E02135")]
        case .orange: return [Self.inkColor("#FF781C"), Self.inkColor("#FF6700")]
        case .yellow: return [Self.inkColor("#FFAF38"), Self.inkColor("#FF9800")]
        case .green: return [Self.inkColor("#00C972"), Self.inkColor("#009957")]
        case .cyan: return [Self.inkColor("#1CC3B0"), Self.inkColor("#00A592")]
        case .blue: return [Self.inkColor("#2A92FE"), Self.inkColor("#0E74E0")]
        case .violet, .purple: return [Self.inkColor("#A97EFE"), Self.inkColor("#804EE0")]
        case .magenta: return [Self.inkColor("#FF5EB1"), Self.inkColor("#E02A88")]
        case .gray: return [Self.inkColor("#959595"), Self.inkColor("#777777")]
        }
    }
    @MainActor func colors(custom: NSColor) -> [NSColor] {
        guard self == .custom else { return colors }
        return [custom, custom.blended(withFraction: 0.22, of: .black) ?? custom]
    }

    @MainActor private static func inkColor(_ value: String) -> NSColor {
        let rgb = UInt32(value.dropFirst(), radix: 16)!
        return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255,
                       green: Double((rgb >> 8) & 255) / 255,
                       blue: Double(rgb & 255) / 255, alpha: 1)
    }

    // Keep the original light and dark ink stops with the retained character data.
    @MainActor func inkColors(mode: PetColorMode, custom: NSColor) -> [NSColor] {
        let dark = self != .black && NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if self == .custom {
            if mode == .solid { return [custom] }
            return colors(custom: custom)
        }
        if mode == .solid { return [colors[dark ? 1 : 0]] }
        let stops: [String]
        switch self {
        case .black: stops = ["#585858", "#000000", "#FFFFFF", "#C2C2C2"]
        case .brown: stops = ["#AE8968", "#855C36", "#A27952", "#604227"]
        case .red: stops = ["#FF5667", "#E02135", "#FF3E51", "#A21826"]
        case .orange: stops = ["#FF8838", "#E05B00", "#FF781C", "#C24E00"]
        case .yellow: stops = ["#FFAF38", "#E08600", "#FFA31C", "#C27400"]
        case .green: stops = ["#1CCF82", "#009957", "#00C972", "#008048"]
        case .cyan: stops = ["#58D3C5", "#00A592", "#1CC3B0", "#007769"]
        case .blue: stops = ["#459FFE", "#0E74E0", "#2A92FE", "#0C64C1"]
        case .violet, .purple: stops = ["#B792FE", "#804EE0", "#9159FE", "#5C39A1"]
        case .magenta: stops = ["#FF77BE", "#E02A88", "#FF47A6", "#A21E62"]
        case .gray: stops = ["#A6A6A6", "#696969", "#B7B7B7", "#777777"]
        default: return colors
        }
        return Array(stops[(dark ? 2 : 0)..<(dark ? 4 : 2)]).map(Self.inkColor)
    }

    @MainActor func drawDetails(in body: NSBezierPath, time: Double, opacity: Double) {
        guard Self.selectable.contains(self) else { return }
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        if shaderKind != nil, ShaderMaterials.shared.draw(self, body: body, time: time, opacity: opacity) {
            if self == .whales { drawDreamWhales(time: time, opacity: opacity) }
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        if self == .aurora || self == .neon || self == .stars || self == .siri {
            MaterialEffects.draw(self, body: body, time: time, opacity: opacity)
        } else if self == .rainbow {
            // Broad overlapping radial reflections give thin-film iridescence without stripes.
            let context = NSGraphicsContext.current!.cgContext
            context.setAlpha(opacity)
            NSGradient(colors: [NSColor(srgbRed: 0.46, green: 0.56, blue: 0.76, alpha: 1),
                NSColor(srgbRed: 0.74, green: 0.77, blue: 0.87, alpha: 1)])!.draw(in: body, angle: 100)
            let reflections: [(CGFloat, CGFloat, NSColor)] = [
                (30, 45, NSColor(srgbRed: 1, green: 0.55, blue: 0.8, alpha: 1)),
                (195, 68, NSColor(srgbRed: 0.3, green: 0.88, blue: 1, alpha: 1)),
                (145, 198, NSColor(srgbRed: 0.4, green: 1, blue: 0.78, alpha: 1)),
                (43, 175, NSColor(srgbRed: 1, green: 0.84, blue: 0.45, alpha: 1))
            ]
            for (index, reflection) in reflections.enumerated() {
                let phase = time * 0.22 + Double(index) * 1.7
                let center = CGPoint(x: reflection.0 + sin(phase) * 24, y: reflection.1 + cos(phase * 0.8) * 20)
                let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                    colors: [reflection.2.withAlphaComponent(0.72).cgColor, reflection.2.withAlphaComponent(0).cgColor] as CFArray,
                    locations: [0, 1])!
                context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                    endCenter: center, endRadius: 158, options: [])
            }
            let edge = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                colors: [NSColor(srgbRed: 0.2, green: 0.25, blue: 0.47, alpha: 0).cgColor,
                    NSColor(srgbRed: 0.2, green: 0.25, blue: 0.47, alpha: 0.32).cgColor] as CFArray,
                locations: [0, 1])!
            context.drawRadialGradient(edge, startCenter: CGPoint(x: 114, y: 108), startRadius: 65,
                endCenter: CGPoint(x: 114, y: 108), endRadius: 116, options: [.drawsAfterEndLocation])
            let rim = body.copy() as! NSBezierPath
            rim.lineWidth = 7
            NSColor.white.withAlphaComponent(0.5).setStroke()
            rim.stroke()
            let glint = NSBezierPath()
            glint.move(to: NSPoint(x: 35, y: 76))
            glint.curve(to: NSPoint(x: 130, y: 24), controlPoint1: NSPoint(x: 51, y: 31), controlPoint2: NSPoint(x: 96, y: 17))
            glint.lineWidth = 5
            glint.lineCapStyle = .round
            NSColor.white.withAlphaComponent(0.75).setStroke()
            glint.stroke()
        } else if self == .camouflage {
            for index in 0..<18 {
                let phase = time * 0.2 + Double(index) * 1.4
                let x = Double((index * 83 + 17) % 240) + sin(phase) * 12
                let y = Double((index * 61 + 29) % 240) + cos(phase * 0.8) * 10
                let patch = NSBezierPath()
                for point in 0..<10 {
                    let angle = Double(point) * .pi / 5
                    let radius = 23 + Double((point * 13 + index * 7) % 27) + sin(phase + Double(point) * 0.7) * 4
                    let p = NSPoint(x: x + cos(angle) * radius, y: y + sin(angle) * radius * 0.65)
                    if point == 0 { patch.move(to: p) } else { patch.line(to: p) }
                }
                patch.close()
                colors[index % colors.count].withAlphaComponent(opacity).setFill()
                patch.fill()
            }
        } else if self == .glass {
            // A translucent, flowing highlight and luminous rim; native vector rendering.
            let highlight = NSBezierPath(ovalIn: NSRect(x: 18 + sin(time * 0.6) * 14,
                y: 17 + cos(time * 0.35) * 10, width: 170 + sin(time * 0.3) * 14, height: 92))
            NSGradient(starting: .white.withAlphaComponent(opacity * 0.65),
                ending: .white.withAlphaComponent(0))!.draw(in: highlight, angle: 90)
            let rim = body.copy() as! NSBezierPath
            rim.lineWidth = 12
            NSColor.white.withAlphaComponent(opacity * 0.6).setStroke()
            rim.stroke()
            let glint = NSBezierPath()
            let shift = sin(time * 0.35) * 12
            glint.move(to: NSPoint(x: 40 + shift, y: 85))
            glint.curve(to: NSPoint(x: 140 + shift, y: 35), controlPoint1: NSPoint(x: 52 + shift, y: 40), controlPoint2: NSPoint(x: 95 + shift, y: 26))
            glint.lineWidth = 5
            glint.lineCapStyle = .round
            NSColor.white.withAlphaComponent(opacity * 0.85).setStroke()
            glint.stroke()
        } else if self == .custom {
            let highlight = NSBezierPath(ovalIn: NSRect(x: 30 + sin(time * 0.3) * 35, y: 15,
                width: 155, height: 110))
            NSGradient(starting: .white.withAlphaComponent(0.16 * opacity), ending: .white.withAlphaComponent(0))!
                .draw(in: highlight, angle: 85)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
