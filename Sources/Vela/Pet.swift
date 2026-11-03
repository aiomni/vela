import VelaLocalization
import AppKit

struct PetGeometry: Decodable {
    struct Segment: Decodable { let command: String; let values: [Double] }
    struct Face: Decodable { let x, y, sx, sy, eye: Double; let leftDX: Double? }
    struct Shape: Decodable { let body: [Segment]; let cutouts: [[Segment]]?; let face: Face }
    let shapes: [String: Shape]
    let eyes: [[[[Double]]]]
    let moods: [String: PetMood]

    static func load() throws -> PetGeometry {
        guard let url = Bundle.module.url(forResource: "pet", withExtension: "json", subdirectory: "Assets") else {
            throw NSError(domain: "Vela.Assets", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L("Companion assets are missing. Rebuild the app.")])
        }
        let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard PetShape.allCases.allSatisfy({ result.shapes[$0.rawValue] != nil }),
              result.eyes.count == 25,
              result.eyes.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.count == 48 && $0.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isFinite) } } }),
              result.shapes.values.allSatisfy({ shape in
                  (shape.body + (shape.cutouts ?? []).flatMap { $0 }).allSatisfy {
                      ["M": 2, "L": 2, "C": 6, "Q": 4, "Z": 0][$0.command] == $0.values.count && $0.values.allSatisfy(\.isFinite)
                  }
              }) else {
            throw NSError(domain: "Vela.Assets", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: L("Companion geometry is incomplete.")])
        }
        guard PetAnimation.catalog.allSatisfy({ result.moods[$0.id] != nil }),
              result.moods.values.allSatisfy({ !$0.eyes.isEmpty && $0.eyes.allSatisfy { (0..<25).contains($0) }
                  && $0.holdSeconds.count == 2 && $0.holdSeconds.allSatisfy { $0.isFinite && $0 > 0 } }) else {
            throw NSError(domain: "Vela.Assets", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: L("Companion expression list is missing.")])
        }
        return result
    }

    @MainActor func bodyPath(for shape: PetShape = .blob) -> NSBezierPath {
        let path = NSBezierPath()
        let geometry = shapes[shape.rawValue]!
        for segment in geometry.body + (geometry.cutouts ?? []).flatMap({ $0 }) {
            let v = segment.values
            switch segment.command {
            case "M": path.move(to: NSPoint(x: v[0], y: v[1]))
            case "C": path.curve(to: NSPoint(x: v[4], y: v[5]),
                                  controlPoint1: NSPoint(x: v[0], y: v[1]),
                                  controlPoint2: NSPoint(x: v[2], y: v[3]))
            case "L": path.line(to: NSPoint(x: v[0], y: v[1]))
            case "Q":
                let current = path.currentPoint
                let control = NSPoint(x: v[0], y: v[1])
                path.curve(to: NSPoint(x: v[2], y: v[3]),
                    controlPoint1: NSPoint(x: current.x + (control.x-current.x)*2/3, y: current.y + (control.y-current.y)*2/3),
                    controlPoint2: NSPoint(x: v[2] + (control.x-v[2])*2/3, y: v[3] + (control.y-v[3])*2/3))
            default: path.close()
            }
        }
        if geometry.cutouts != nil { path.windingRule = .evenOdd }
        return path
    }

    func materialZoom(for shape: PetShape) -> CGFloat {
        guard shape != .blob else { return 1 }
        let radius = shapes[shape.rawValue]!.body.reduce(114.27) { widest, segment in
            let values = segment.values
            let points = stride(from: 0, to: values.count, by: 2).map {
                hypot(values[$0] - 114.27, values[$0 + 1] - 114.27)
            }
            return max(widest, points.max() ?? 0)
        }
        // A small margin keeps the material's antialiased circular edge beyond
        // the body even while it rotates and breathes.
        return CGFloat(radius / 114.27 * 1.04)
    }
}

enum PetShape: String, CaseIterable {
    case blob, pebble, bean, egg, squircle, tablet, capsule, cylinder, hex, gem, crystal, wedge, shield, dome, arch, cloud, teardrop, leaf, whale
    var title: String {
        switch self {
        case .blob: L("Dumpling")
        case .pebble: L("Pebble")
        case .bean: L("Bean")
        case .egg: L("Egg")
        case .squircle: L("Cube")
        case .tablet: L("Wide Capsule")
        case .capsule: L("Capsule")
        case .cylinder: L("Cylinder")
        case .hex: L("Hexagon")
        case .gem: L("Gem")
        case .crystal: L("Crystal")
        case .wedge: L("Wedge")
        case .shield: L("Shield")
        case .dome: L("Dome")
        case .arch: L("Arch")
        case .cloud: L("Cloud")
        case .teardrop: L("Drop")
        case .leaf: L("Leaf")
        case .whale: L("Whale")
        }
    }
}

@MainActor
final class PetView: NSView {
    let geometry: PetGeometry
    private(set) var body: NSBezierPath
    var shape = PetShape.blob {
        didSet {
            shapeMorph = nil
            body = geometry.bodyPath(for: shape)
            materialZoom = geometry.materialZoom(for: shape)
            needsDisplay = true
        }
    }
    private var materialZoom: CGFloat = 1
    private var shapeRings: [PetShape: [NSPoint]] = [:]
    private var shapeMorph: ShapeMorphState?
    var animationTime: TimeInterval = 0
    var reduceMotion = false
    private var colorTransition = ColorTransition()
    private var burstStartedAt: TimeInterval?
    var drawingPadding: CGFloat = 12
    var isAwake = false {
        didSet {
            guard oldValue != isAwake else { return }
            colorTransition.set(isAwake ? 1 : 0, at: ProcessInfo.processInfo.systemUptime,
                animated: !reduceMotion && window?.isVisible == true)
            burstStartedAt = colorStyle == .burst && !reduceMotion && window?.isVisible == true
                ? ProcessInfo.processInfo.systemUptime : nil
            needsDisplay = true
        }
    }
    var usesAwakeColor = true
    var colorStyle = ColorTransitionStyle.radial
    var palette = PetPalette.orange
    var customColor = NSColor.systemOrange
    var restPalette: PetPalette?
    var restColor: NSColor?
    var restColorMode = PetColorMode.solid
    var eyeColor: NSColor?
    var colorMode = PetColorMode.solid
    var activeColors: [NSColor] { palette.inkColors(mode: colorMode, custom: customColor) }
    weak var materialSurface: LiveMaterialSurface?
    var moodOverride: String?
    var dutyMood: String?
    var onMoodChange: ((String?) -> Void)?
    private var reactionCount = 0
    var onDragEnd: (() -> Void)?
    var onHover: (() -> Void)?
    var onHoverExit: (() -> Void)?
    private(set) var isHovered = false
    private(set) var reactionAt: TimeInterval?
    private var pointer = NSPoint.zero
    private var tracking: NSTrackingArea?
    private var didDrag = false
    private var dragMouse = NSPoint.zero
    private var dragOrigin = NSPoint.zero
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(geometry: PetGeometry) {
        self.geometry = geometry
        self.body = geometry.bodyPath()
        super.init(frame: .zero)
        toolTip = L("Click to say hello · Drag to move · Right-click for the menu")
        setAccessibilityElement(true)
        setAccessibilityLabel(L("Keep-awake companion. Click to say hello and drag to move"))
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    private func ring(for shape: PetShape) -> [NSPoint] {
        if let cached = shapeRings[shape] { return cached }
        let result = ShapeMorphGeometry.ring(for: geometry.shapes[shape.rawValue]!)
        shapeRings[shape] = result
        return result
    }

    func transition(to next: PetShape, at now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                    animated: Bool) {
        guard next != shape else { return }
        let previous = shape
        let oldMorph = shapeMorph
        let progress = oldMorph?.progress(at: now) ?? 1
        let fromRing = oldMorph.map { ShapeMorphGeometry.interpolate($0.fromRing, ring(for: previous), progress) }
            ?? ring(for: previous)
        let previousFace = geometry.shapes[previous.rawValue]!.face
        let fromFace = oldMorph.map { ShapeMorphGeometry.interpolate($0.fromFace, previousFace, progress) }
            ?? previousFace
        let fromPath = oldMorph == nil || progress >= 1 ? body.copy() as! NSBezierPath
            : ShapeMorphGeometry.path(fromRing)
        let interpolatedZoom = oldMorph.map { $0.fromZoom + (materialZoom - $0.fromZoom) * progress } ?? materialZoom
        let fromZoom = max(interpolatedZoom, ShapeMorphGeometry.zoomCovering(fromRing))
        shape = next
        guard animated && !reduceMotion else { return }
        shapeMorph = ShapeMorphState(fromRing: fromRing, fromFace: fromFace, fromPath: fromPath,
                                    fromZoom: fromZoom, startedAt: now)
        body = fromPath
        needsDisplay = true
    }

    func shapeFrame(at now: TimeInterval) -> (path: NSBezierPath, face: PetGeometry.Face,
                                              zoom: CGFloat, morphing: Bool) {
        let targetFace = geometry.shapes[shape.rawValue]!.face
        guard let morph = shapeMorph else { return (body, targetFace, materialZoom, false) }
        let progress = morph.progress(at: now)
        guard progress < 0.999 else {
            shapeMorph = nil
            body = geometry.bodyPath(for: shape)
            return (body, targetFace, materialZoom, false)
        }
        let currentRing = ShapeMorphGeometry.interpolate(morph.fromRing, ring(for: shape), progress)
        let path = progress < 0.001 ? morph.fromPath : ShapeMorphGeometry.path(currentRing)
        let face = ShapeMorphGeometry.interpolate(morph.fromFace, targetFace, progress)
        let interpolatedZoom = morph.fromZoom + (materialZoom - morph.fromZoom) * progress
        return (path, face, max(interpolatedZoom, ShapeMorphGeometry.zoomCovering(currentRing)), true)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let shapeFrame = shapeFrame(at: ProcessInfo.processInfo.systemUptime)
        body = shapeFrame.path
        let incomingTransform = context.ctm
        let time = reduceMotion ? 0 : animationTime
        let scale = (bounds.width - drawingPadding) / 259
        let burst = BurstEffect(age: burstStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 10)
        let reactionAge = reactionAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 10
        let reacting = reactionAge < 2
        let reactions = ["happy", "excited", "surprised", "playful", "shy", "laughing", "celebrate"]
        let reaction = reacting ? reactions[max(0, reactionCount - 1) % reactions.count] : nil
        let animation = PetAnimation(moods: geometry.moods)
        let pose = animation.frame(at: reacting ? reactionAge + 0.4 : time,
            override: reaction ?? moodOverride ?? dutyMood, reduced: reduceMotion)
        let colorAmount = usesAwakeColor ? (reduceMotion ? (isAwake ? 1.0 : 0.0)
            : colorTransition.value(at: ProcessInfo.processInfo.systemUptime)) : 0
        let visiblePalette = colorAmount < 0.5 ? restPalette : palette
        let bodyPose = visiblePalette == .pokeball ? ButtonEyeMotion.body(at: time, reduced: reduceMotion)
            : (rotation: pose.rotation, squash: pose.squash, bounce: pose.bounce)
        let hop = !reduceMotion && reactionAge < 0.65 ? sin(reactionAge / 0.65 * .pi) * 5 : 0
        let hoverX = isHovered ? pointer.x : 0
        let hoverY = isHovered ? pointer.y : 0
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY - hop + bodyPose.bounce * bounds.width)
        context.saveGState()
        context.rotate(by: reduceMotion ? 0 : bodyPose.rotation + hoverX * 0.07)
        let breath = bodyPose.squash
        let hoverScale = isHovered && !reduceMotion ? 1.025 : 1
        let burstScale = reduceMotion ? 1 : burst.bodyScale
        context.scaleBy(x: scale * breath * hoverScale * burstScale, y: scale / breath * hoverScale * burstScale)
        context.translateBy(x: -114.27, y: -114.27)

        func blendColor(_ base: NSColor, _ active: NSColor) -> NSColor {
            base.blended(withFraction: colorAmount, of: active) ?? base
        }
        // Fill plain silhouettes directly; material shaders own their edge light.
        let colorMask = colorStyle.mask(at: colorAmount)
        let exactDefault = shape == .blob && !shapeFrame.morphing
        let liveCapable = exactDefault && materialSurface?.available == true && window?.isVisible == true
        let live = liveCapable && palette.shaderKind != nil && colorAmount > 0 &&
            !(restPalette != nil && colorStyle == .fade && colorAmount < 1)
        let liveRest = liveCapable && restPalette?.shaderKind != nil && colorAmount == 0
        let fieldTransform = context.ctm
        let fieldDiameter = 228.54 * min(hypot(fieldTransform.a,fieldTransform.b),hypot(fieldTransform.c,fieldTransform.d))
        let fieldBaseDiameter = 228.54 * scale * min(hypot(incomingTransform.a,incomingTransform.b),hypot(incomingTransform.c,incomingTransform.d))
        if exactDefault && !live && palette.shaderKind != nil && colorAmount > 0 {
            context.saveGState()
            let transform = context.ctm
            let displayDiameter = 228.54 * min(hypot(transform.a,transform.b),hypot(transform.c,transform.d))
            let baseDiameter = 228.54 * scale * min(hypot(incomingTransform.a,incomingTransform.b),hypot(incomingTransform.c,incomingTransform.d))
            if palette == .stars {
                ShaderMaterials.shared.starRenderer?.drawFullField(time: time, opacity: colorAmount,
                    displayDiameter:displayDiameter,baseDiameter:baseDiameter)
            } else {
                ShaderMaterials.shared.drawFullField(palette,time:time,opacity:colorAmount,
                    displayDiameter:displayDiameter,baseDiameter:baseDiameter)
            }
            context.restoreGState()
        }
        if let surface = materialSurface {
            surface.isHidden = !live && !liveRest
            if live || liveRest {
                surface.parameters.time = Float(time)
                surface.parameters.kind = (live ? palette : restPalette!).shaderKind!
                surface.parameters.size = SIMD2(Float(bounds.width), Float(bounds.height))
                surface.parameters.center = SIMD2(Float(bounds.midX), Float(bounds.midY - hop + bodyPose.bounce * bounds.width))
                surface.parameters.scale = SIMD2(Float(scale * breath * hoverScale * burstScale), Float(scale / breath * hoverScale * burstScale))
                // Every material filters for the physical display pixels.
                let diameter = 228.54 * min(abs(surface.parameters.scale.x),abs(surface.parameters.scale.y))
                surface.parameters.padding = 1 / max(1,diameter*Float(window?.backingScaleFactor ?? 2))
                surface.parameters.rotation = Float(reduceMotion ? 0 : bodyPose.rotation + hoverX * 0.07)
                surface.parameters.progress = Float(live ? colorAmount : 1)
                surface.parameters.style = UInt32(live ? ColorTransitionStyle.allCases.firstIndex(of: colorStyle)! : 3)
                let mono = (restColor ?? .labelColor).usingColorSpace(.sRGB)!
                surface.parameters.monochrome = SIMD4(Float(mono.redComponent), Float(mono.greenComponent), Float(mono.blueComponent), 1)
                surface.draw()
            }
        }
        let restingColor = restColor ?? NSColor.labelColor
        if let restPalette {
            if colorAmount < 1 && !liveRest {
                context.saveGState()
                body.addClip()
                if restPalette.drawsBase {
                    (restPalette == .stars ? NSColor(srgbRed: 0.015, green: 0.035, blue: 0.085, alpha: 1)
                        : restPalette.colors[0]).setFill()
                    body.fill()
                    if restPalette == .stars {
                        ShaderMaterials.shared.starRenderer?.drawFullField(time: time, opacity: 1,
                            displayDiameter: fieldDiameter, baseDiameter: fieldBaseDiameter, zoom: shapeFrame.zoom)
                    } else {
                        ShaderMaterials.shared.drawFullField(restPalette, time: time, opacity: 1,
                            displayDiameter: fieldDiameter, baseDiameter: fieldBaseDiameter, zoom: shapeFrame.zoom)
                    }
                    if restPalette == .whales { drawDreamWhales(time: time, opacity: 1) }
                } else {
                    let colors = restPalette.inkColors(mode: restColorMode, custom: restColor ?? .systemOrange)
                    if restColorMode == .solid || colors.count == 1 { colors[0].setFill(); body.fill() }
                    else if restColorMode == .linear { NSGradient(colors: colors)!.draw(in: body, angle: 135) }
                    else { NSGradient(colors: colors)!.draw(in: body, relativeCenterPosition: .zero) }
                    restPalette.drawDetails(in: body, time: time, opacity: 1)
                }
                context.restoreGState()
            } else if liveRest && restPalette == .whales {
                context.saveGState()
                body.addClip()
                drawDreamWhales(time: time, opacity: 1)
                context.restoreGState()
            } else if colorAmount >= 1 {
                // Cover the pre-rendered effect field inside the body before
                // the awake layer is composited over it.
                restingColor.setFill()
                body.fill()
            }
        } else {
            restingColor.setFill()
            body.fill()
        }
        if colorAmount > 0 {
            context.saveGState()
            if live {
                body.addClip()
                if colorStyle != .fade { colorMask?.addClip() }
                context.setBlendMode(.clear)
                body.fill()
                context.setBlendMode(.normal)
                if palette == .whales {
                    // A layer-backed AppKit context may expose a point-space CTM.
                    // Derive the vector filter footprint from backing pixels,
                    // matching the native Metal surface rather than exports only.
                    let backing = convertToBacking(NSRect(x:0,y:0,width:1,height:1)).size
                    let displayScale = sqrt(abs(backing.width*backing.height))*scale*hoverScale*burstScale
                    drawDreamWhales(time: time, opacity: colorStyle == .fade ? colorAmount : 1,displayScale:displayScale)
                }
            } else {
                colorMask?.addClip()
                if !exactDefault && palette.drawsBase {
                    let fallback = palette == .stars
                        ? NSColor(srgbRed: 0.015, green: 0.035, blue: 0.085, alpha: 1)
                        : palette.colors[0]
                    context.saveGState()
                    if colorStyle == .fade && restPalette != nil { context.setAlpha(colorAmount) }
                    (colorStyle == .fade && restPalette == nil ? blendColor(restingColor, fallback) : fallback).setFill()
                    body.fill()
                    context.restoreGState()
                }
                if !palette.drawsBase {
                    let colors = activeColors.map { colorStyle == .fade && restPalette == nil ? blendColor(restingColor, $0) : $0 }
                    context.saveGState()
                    if colorStyle == .fade && restPalette != nil { context.setAlpha(colorAmount) }
                    if colorMode == .solid || colors.count == 1 { colors[0].setFill(); body.fill() }
                    else if colorMode == .linear { NSGradient(colors: colors)!.draw(in: body, angle: 135) }
                    else { NSGradient(colors: colors)!.draw(in: body, relativeCenterPosition: .zero) }
                    context.restoreGState()
                }
                if palette.shaderKind != nil {
                    body.addClip()
                    if palette == .stars {
                        ShaderMaterials.shared.starRenderer?.drawFullField(time:time,opacity:colorStyle == .fade ? colorAmount : 1,
                            displayDiameter:fieldDiameter,baseDiameter:fieldBaseDiameter,zoom:shapeFrame.zoom)
                    } else {
                        ShaderMaterials.shared.drawFullField(palette,time:time,opacity:colorStyle == .fade ? colorAmount : 1,
                            displayDiameter:fieldDiameter,baseDiameter:fieldBaseDiameter,zoom:shapeFrame.zoom)
                    }
                    if palette == .whales { drawDreamWhales(time:time,opacity:colorStyle == .fade ? colorAmount : 1) }
                } else {
                    palette.drawDetails(in: body, time: time, opacity: colorStyle == .fade ? colorAmount : 1)
                }
            }
            context.restoreGState()
        }
        body.addClip()
        let blend = pose.blend
        let clickLid = !reduceMotion && reactionAge < 0.22 ? max(0.07, abs(reactionAge - 0.11) / 0.11) : 1
        let lid = min(pose.lid, clickLid)
        let face = shapeFrame.face
        // The Poké Ball button is its single curious eye. Fade the normal
        // face out with the material rather than drawing two eyes over it.
        let buttonEye = palette == .pokeball && colorAmount > 0
        let restButtonEye = restPalette == .pokeball && colorAmount < 1
        let defaultRestEye = restPalette == nil ? NSColor.windowBackgroundColor
            : restPalette == .rainbow ? NSColor.black : NSColor.white
        let normalEyeOpacity = (buttonEye ? 1 - colorAmount : 1) * (restButtonEye ? colorAmount : 1)
        context.saveGState()
        if buttonEye || restButtonEye { context.setAlpha(normalEyeOpacity) }
        let whaleEye = shape == .whale && !shapeFrame.morphing
        for eye in 0..<(whaleEye || normalEyeOpacity <= 0 ? 0 : 2) {
            let a = geometry.eyes[pose.from][eye].map { NSPoint(x:$0[0],y:$0[1]) }
            let b = geometry.eyes[pose.to][eye].map { NSPoint(x:$0[0],y:$0[1]) }
            let eyeLid = pose.winkEye == eye ? min(lid, 0.12) : lid
            let points = zip(a, b).map { p, q in
                NSPoint(x: p.x + (q.x - p.x) * blend, y: p.y + (q.y - p.y) * blend)
            }
            let center = NSPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                                 y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
            let eyeScale = CGFloat(face.eye)
            let eyePath = NSBezierPath()
            for (i, point) in points.enumerated() {
                let eyeOffset = eye == 0 ? -28.5 + (face.leftDX ?? 0) : 28.5
                let target = NSPoint(x: 114.27 + CGFloat(face.x) + CGFloat(eyeOffset) * CGFloat(face.sx) * 1.18 + (point.x - center.x) * 0.96 * eyeScale + (isHovered ? hoverX * 12 : pose.gazeX),
                                     y: 103 + CGFloat(face.y) + (point.y - center.y) * 0.92 * eyeScale * CGFloat(face.sy) * eyeLid + (isHovered ? hoverY * 9 : pose.gazeY))
                if i == 0 { eyePath.move(to: target) } else { eyePath.line(to: target) }
            }
            eyePath.close()
            (eyeColor ?? defaultRestEye).setFill()
            eyePath.fill()
            if restPalette == .soccer && colorAmount < 1 {
                NSColor(srgbRed: 0.04, green: 0.05, blue: 0.07,
                    alpha: 0.38 * (1 - colorAmount)).setStroke()
                eyePath.lineWidth = 1.1
                eyePath.stroke()
            }
            if colorAmount > 0 {
                context.saveGState()
                colorMask?.addClip()
                let activeEye = eyeColor ?? (palette == .rainbow ? NSColor.black : NSColor.white)
                (colorStyle == .fade ? blendColor(eyeColor ?? defaultRestEye, activeEye) : activeEye).setFill()
                eyePath.fill()
                if palette == .soccer || palette == .pokeball {
                    // Keep the approved eye shape readable over white panels.
                    NSColor(srgbRed:0.04,green:0.05,blue:0.07,alpha:0.38*colorAmount).setStroke()
                    eyePath.lineWidth = 1.1
                    eyePath.stroke()
                }
                context.restoreGState()
            }
        }
        context.restoreGState()
        context.restoreGState()
        if whaleEye {
            let eyeHeight = max(0.7, 5.2 * lid)
            let pupil = NSBezierPath(ovalIn: NSRect(x: 120.6 + pose.gazeX * 0.15,
                y: 101.7 + (5.2 - eyeHeight) / 2 + pose.gazeY * 0.15,
                width: 5.2, height: eyeHeight))
            (eyeColor ?? .labelColor).setFill()
            pupil.fill()
        }
        // Draw outside the body clip and independently of the character's recoil.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -114.27, y: -114.27)
        if usesAwakeColor && !reduceMotion && colorStyle == .burst { burst.draw(enabled: isAwake, palette: palette, customColor: customColor) }
        context.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        onHover?()
        didDrag = false
        dragMouse = NSEvent.mouseLocation
        dragOrigin = window?.frame.origin ?? .zero
    }
    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        if hypot(current.x - dragMouse.x, current.y - dragMouse.y) > 3 { didDrag = true }
        guard didDrag else { return }
        window?.setFrameOrigin(NSPoint(x: dragOrigin.x + current.x - dragMouse.x,
                                       y: dragOrigin.y + current.y - dragMouse.y))
    }
    override func mouseUp(with event: NSEvent) {
        if didDrag { onDragEnd?() } else { reactToClick() }
    }

    func reactToClick() {
        reactionCount += 1
        reactionAt = ProcessInfo.processInfo.systemUptime
        needsDisplay = true
    }

    @objc func selectMood(_ sender: NSMenuItem) {
        moodOverride = sender.representedObject as? String
        reactionAt = nil
        onMoodChange?(moodOverride)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseEntered(with event: NSEvent) { isHovered = true; mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { isHovered = false; onHoverExit?(); needsDisplay = true }
    override func mouseMoved(with event: NSEvent) {
        isHovered = true
        onHover?()
        let point = convert(event.locationInWindow, from: nil)
        pointer = NSPoint(x: min(1, max(-1, (point.x - bounds.midX) / max(1, bounds.width / 2))),
                          y: min(1, max(-1, (point.y - bounds.midY) / max(1, bounds.height / 2))))
        needsDisplay = true
    }
}

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DelayedHelpButton: NSButton {
    static let helpDelay: TimeInterval = 3
    var helpText = "" {
        didSet { if oldValue != helpText { dismissHelp() } }
    }
    private var tracking: NSTrackingArea?
    private var helpTimer: Timer?
    private var helpPopover: NSPopover?
    private var hovering = false
    var helpIsPending: Bool { helpTimer != nil }
    var helpIsVisible: Bool { helpPopover?.isShown == true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { beginHelpDelay() }
    override func mouseMoved(with event: NSEvent) {
        if !hovering { beginHelpDelay() }
    }
    override func mouseExited(with event: NSEvent) { dismissHelp() }
    override func mouseDown(with event: NSEvent) {
        dismissHelp()
        super.mouseDown(with: event)
    }

    private func beginHelpDelay() {
        guard !hovering, !helpText.isEmpty else { return }
        hovering = true
        let timer = Timer(timeInterval: Self.helpDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.presentHelp() }
        }
        helpTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func presentHelp() {
        helpTimer = nil
        guard hovering, !isHidden, window?.isVisible == true else { return }
        let label = NSTextField(labelWithString: helpText)
        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        let controller = NSViewController()
        controller.view = content
        controller.preferredContentSize = NSSize(width: max(100, label.intrinsicContentSize.width + 24), height: 32)
        let popover = NSPopover()
        popover.animates = false
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        helpPopover = popover
    }

    func dismissHelp() {
        helpTimer?.invalidate()
        helpTimer = nil
        helpPopover?.close()
        helpPopover = nil
        hovering = false
    }
}

@MainActor
final class HoverPetContainer: NSView {
    var pet: NSView?
    var controls: NSView?
    var onControlsHidden: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var dismissal: Timer?
    private var hoverMonitor: Timer?
    private var outsideAt: TimeInterval?
    private var suppressedAt: NSPoint?
    private(set) var controlsVisible = false

    func setControlsVisible(_ visible: Bool) {
        if visible, let suppressedAt, hypot(NSEvent.mouseLocation.x - suppressedAt.x, NSEvent.mouseLocation.y - suppressedAt.y) < 2 { return }
        if visible { suppressedAt = nil }
        dismissal?.invalidate()
        dismissal = nil
        controls?.isHidden = !visible
        if !visible { onControlsHidden?() }
        guard controlsVisible != visible else { return }
        controlsVisible = visible
        updateTrackingAreas()
    }

    func startMonitoring() {
        stopMonitoring()
        hoverMonitor = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                let point = self.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                self.refreshHover(point: point, now: ProcessInfo.processInfo.systemUptime,
                    visible: window.isVisible && window.occlusionState.contains(.visible))
            }
        }
        RunLoop.main.add(hoverMonitor!, forMode: .common)
    }

    func stopMonitoring() { hoverMonitor?.invalidate(); hoverMonitor = nil; outsideAt = nil }

    func dismissForContextChange() {
        setControlsVisible(false)
        suppressedAt = NSEvent.mouseLocation
        outsideAt = nil
    }

    func refreshHover(point: NSPoint, now: TimeInterval, visible: Bool) {
        guard visible else { setControlsVisible(false); outsideAt = nil; return }
        let area = controlsVisible ? bounds : (pet?.frame ?? bounds)
        if area.contains(point) {
            outsideAt = nil
            setControlsVisible(true)
        } else if controlsVisible {
            if let outsideAt, now - outsideAt >= 0.18 { setControlsVisible(false); self.outsideAt = nil }
            else if outsideAt == nil { outsideAt = now }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: controlsVisible ? bounds : (pet?.frame ?? bounds),
            options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setControlsVisible(true) }
    override func mouseExited(with event: NSEvent) { scheduleDismissal() }
    func scheduleDismissal() {
        dismissal?.invalidate()
        dismissal = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                let point = self.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                // Keep controls available while traversing the small gap below the pet.
                if !self.bounds.contains(point) { self.setControlsVisible(false) }
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if !controlsVisible, let pet, !pet.frame.contains(point) { return nil }
        return super.hitTest(point)
    }
}

@MainActor
final class PetController {
    let panel: PetPanel
    let view: PetView
    let powerButton = DelayedHelpButton()
    let modeButton = DelayedHelpButton()
    let modeMenu = NSMenu(title: L("Choose keep-awake mode"))
    let modePopover = NSPopover()
    private var modeOptionLabels: [NSTextField] = []
    private var modeOptionChecks: [NSImageView] = []
    private var modeLanguage: VelaLanguage?
    private var modeOutsideClickMonitor: Any?
    private var modeAppActivationObserver: NSObjectProtocol?
    let agentButton = DelayedHelpButton()
    let settingsButton = DelayedHelpButton()
    let container = HoverPetContainer()
    let materialSurface = LiveMaterialSurface()
    let controls = NSGlassEffectView()
    var onToggle: (() -> Void)?
    var onModeSelect: ((KeepAwakeMode) -> Void)?
    var onAgentToggle: (() -> Void)?
    var onSettings: (() -> Void)?
    var onPaletteChange: (() -> Void)?
    var onShapeChange: (() -> Void)?
    private let defaults: UserDefaults
    private var timer: Timer?
    private var shapeTimer: Timer?
    private var epoch = ProcessInfo.processInfo.systemUptime
    private var running = false
    private var sleeping = false
    private var dutyAnimationPaused = false
    private var thermalLevel = DutyHeat.nominal
    private(set) var automaticShape: Bool
    private static let controlIconSize = NSSize(width: 24, height: 24)
    private static let controlsWidth: CGFloat = 146
    private static func approvedIcon(_ name: String, template: Bool = false) -> NSImage {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png",
                                          subdirectory: "Assets/ControlIcons"),
              let image = NSImage(contentsOf: url) else {
            fatalError("Missing approved control icon: \(name)")
        }
        image.size = controlIconSize
        image.isTemplate = template
        return image
    }

    private static let powerIcon = approvedIcon("power")
    private static let powerInactiveIcon = approvedIcon("power", template: true)
    private static let robotIcon = approvedIcon("agent")
    private static let robotInactiveIcon = approvedIcon("agent", template: true)
    private static let displayModeIcon = approvedIcon("display")
    private static let systemModeIcon = approvedIcon("system")
    private static let lidModeIcon = approvedIcon("lid")
    private static let settingsIcon = approvedIcon("settings")

    private static func icon(for mode: KeepAwakeMode) -> NSImage {
        switch mode {
        case .display: displayModeIcon
        case .system: systemModeIcon
        case .lid: lidModeIcon
        }
    }

    private static func menuIcon(for mode: KeepAwakeMode) -> NSImage {
        let source = icon(for: mode)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            source.draw(in: bounds)
            return true
        }
        image.isTemplate = false
        return image
    }

    init(defaults: UserDefaults = .standard) throws {
        self.defaults = defaults
        automaticShape = defaults.bool(forKey: "petShapeAuto")
        view = PetView(geometry: try PetGeometry.load())
        view.drawingPadding = 40
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.materialSurface = materialSurface
        panel = PetPanel(contentRect: NSRect(x: 0, y: 0, width: 60, height: 60),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = L("Vela Companion")
        container.frame = panel.contentView!.bounds
        container.pet = view
        container.controls = controls
        container.addSubview(materialSurface)
        container.addSubview(view)
        controls.cornerRadius = 15
        controls.style = .regular
        if #available(macOS 27, *) { controls.effectIsInteractive = true }
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: Self.controlsWidth, height: 30))
        powerButton.frame = NSRect(x: 6, y: 3, width: 28, height: 24)
        powerButton.image = Self.powerInactiveIcon
        powerButton.imagePosition = .imageOnly
        powerButton.isBordered = false
        powerButton.wantsLayer = true
        powerButton.layer?.cornerRadius = 7
        powerButton.setButtonType(.pushOnPushOff)
        powerButton.target = self
        powerButton.action = #selector(togglePower)
        bar.addSubview(powerButton)
        let powerDivider = NSBox(frame: NSRect(x: 36, y: 7, width: 1, height: 16))
        powerDivider.boxType = .separator
        bar.addSubview(powerDivider)
        modeButton.frame = NSRect(x: 77, y: 3, width: 28, height: 24)
        modeButton.image = Self.displayModeIcon
        modeButton.imagePosition = .imageOnly
        modeButton.imageScaling = .scaleProportionallyDown
        modeButton.isBordered = false
        modeButton.contentTintColor = .labelColor
        modeButton.target = self
        modeButton.action = #selector(showModeMenu)
        bar.addSubview(modeButton)
        for (title, mode) in [(L("Keep display awake"), KeepAwakeMode.display),
                              (L("Allow display sleep, keep system running"), .system),
                              (L("Keep running with lid closed"), .lid)] {
            let item = NSMenuItem(title: title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.image = Self.menuIcon(for: mode)
            modeMenu.addItem(item)
        }
        let options: [(String, String, KeepAwakeMode, CGFloat, CGFloat)] = [
            (L("Keep display awake"), L("Keep display awake"), .display, 80, 32),
            (L("Allow display sleep, keep system running"), L("Allow display sleep, keep system running"), .system, 44, 32),
            (L("Keep running with lid closed"), L("Keep running with lid closed"), .lid, 8, 32)
        ]
        let popoverView = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 250, height: 120))
        popoverView.cornerRadius = 22
        popoverView.style = .regular
        if #available(macOS 27, *) { popoverView.effectIsInteractive = true }
        let popoverContent = NSView(frame: popoverView.bounds)
        popoverView.contentView = popoverContent
        for (index, option) in options.enumerated() {
            let (title, visibleTitle, mode, y, height) = option
            let check = NSImageView(frame: NSRect(x: 9, y: y + (height - 14) / 2, width: 14, height: 14))
            check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            check.contentTintColor = .labelColor
            check.imageScaling = .scaleProportionallyDown
            popoverContent.addSubview(check)
            modeOptionChecks.append(check)

            let icon = NSImageView(frame: NSRect(x: 31, y: y + (height - 18) / 2,
                                                 width: 18, height: 18))
            icon.image = Self.menuIcon(for: mode)
            icon.contentTintColor = .labelColor
            icon.imageScaling = .scaleProportionallyDown
            popoverContent.addSubview(icon)

            let label = NSTextField(labelWithString: visibleTitle)
            label.frame = NSRect(x: 52, y: y + (height - 18) / 2,
                                 width: 190, height: 18)
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.usesSingleLineMode = true
            popoverContent.addSubview(label)
            modeOptionLabels.append(label)

            let button = NSButton(frame: NSRect(x: 4, y: y, width: 242, height: height))
            button.isBordered = false
            button.title = ""
            button.tag = index
            button.target = self
            button.action = #selector(selectModeFromPopover(_:))
            button.setAccessibilityLabel(title)
            popoverContent.addSubview(button)
        }
        let popoverController = NSViewController()
        popoverController.view = popoverView
        modePopover.contentViewController = popoverController
        modePopover.contentSize = popoverView.frame.size
        modePopover.behavior = .transient
        modeOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.modePopover.close() }
        }
        modeAppActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard activated?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor [weak self] in self?.modePopover.close() }
        }
        let divider = NSBox(frame: NSRect(x: 72, y: 7, width: 1, height: 16))
        divider.boxType = .separator
        bar.addSubview(divider)
        agentButton.frame = NSRect(x: 41, y: 3, width: 28, height: 24)
        agentButton.image = Self.robotInactiveIcon
        agentButton.imagePosition = .imageOnly
        agentButton.isBordered = false
        agentButton.wantsLayer = true
        agentButton.layer?.cornerRadius = 7
        agentButton.setButtonType(.pushOnPushOff)
        agentButton.target = self
        agentButton.action = #selector(toggleAgentWatch)
        bar.addSubview(agentButton)
        let agentDivider = NSBox(frame: NSRect(x: 109, y: 7, width: 1, height: 16))
        agentDivider.boxType = .separator
        bar.addSubview(agentDivider)
        settingsButton.frame = NSRect(x: 114, y: 3, width: 28, height: 24)
        settingsButton.image = Self.settingsIcon
        settingsButton.imagePosition = .imageOnly
        settingsButton.isBordered = false
        settingsButton.contentTintColor = .labelColor
        settingsButton.image?.size = Self.controlIconSize
        settingsButton.imageScaling = .scaleProportionallyDown
        settingsButton.helpText = L("Open Settings")
        settingsButton.setAccessibilityLabel(L("Open Settings"))
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        bar.addSubview(settingsButton)
        controls.contentView = bar
        container.addSubview(controls)
        container.onControlsHidden = { [weak self] in
            self?.powerButton.dismissHelp()
            self?.modeButton.dismissHelp()
            self?.agentButton.dismissHelp()
            self?.settingsButton.dismissHelp()
        }
        container.setControlsVisible(false)
        panel.contentView = container
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        view.onDragEnd = { [weak self] in self?.fitOnScreen(); self?.savePosition() }
        view.onHover = { [weak self] in self?.container.setControlsVisible(true) }
        view.onHoverExit = { [weak self] in self?.container.scheduleDismissal() }
        resize(to: petSize)
        if defaults.object(forKey: "petX") != nil && defaults.object(forKey: "petY") != nil {
            panel.setFrameOrigin(NSPoint(x: defaults.double(forKey: "petX"), y: defaults.double(forKey: "petY")))
            fitOnScreen()
        } else { resetPosition() }
        setEnabled(false)
        setKeepAwakeMode(.display)
        setAgentWatchEnabled(false)
        view.colorStyle = ColorTransitionStyle(rawValue: defaults.string(forKey: "colorStyle") ?? "") ?? .radial
        view.palette = PetPalette(rawValue: defaults.string(forKey: "petPalette") ?? "") ?? .rainbow
        view.restPalette = PetPalette(rawValue: defaults.string(forKey: "petRestPalette") ?? "")
        view.restColorMode = PetColorMode(rawValue: defaults.string(forKey: "petRestColorMode") ?? "") ?? .solid
        view.shape = PetShape(rawValue: defaults.string(forKey: "petShape") ?? "") ?? .blob
        view.colorMode = PetColorMode(rawValue: defaults.string(forKey: "petColorMode") ?? "") ?? .solid
        if let mood = defaults.string(forKey: "petMood"), view.geometry.moods[mood] != nil { view.moodOverride = mood }
        if let rgb = defaults.array(forKey: "petCustomColor") as? [Double], rgb.count == 3,
           rgb.allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
            view.customColor = defaults.string(forKey: "petColorSpace") == "sRGB"
                ? NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
                : NSColor(calibratedRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
        }
        if let rgb = defaults.array(forKey: "petEyeColor") as? [Double], rgb.count == 3,
           rgb.allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
            view.eyeColor = NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
        }
        if let rgb = defaults.array(forKey: "petRestColor") as? [Double], rgb.count == 3,
           rgb.allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
            view.restColor = NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
            if view.restPalette == nil { view.restPalette = .custom }
        }
    }

    @objc private func togglePower() { onToggle?() }
    @objc private func showModeMenu() {
        modeButton.dismissHelp()
        refreshLocalization()
        modePopover.show(relativeTo: modeButton.bounds, of: modeButton, preferredEdge: .maxY)
    }
    @objc private func selectModeFromPopover(_ sender: NSButton) {
        guard modeMenu.items.indices.contains(sender.tag),
              let raw = modeMenu.items[sender.tag].representedObject as? String,
              let mode = KeepAwakeMode(rawValue: raw) else { return }
        modePopover.close()
        onModeSelect?(mode)
    }
    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = KeepAwakeMode(rawValue: raw) else { return }
        onModeSelect?(mode)
    }
    @objc private func toggleAgentWatch() { onAgentToggle?() }
    @objc private func openSettings() { onSettings?() }
    func setColorStyle(_ style: ColorTransitionStyle) {
        view.colorStyle = style
        defaults.set(style.rawValue, forKey: "colorStyle")
        view.needsDisplay = true
    }
    func setShape(_ shape: PetShape) {
        if automaticShape {
            automaticShape = false
            defaults.set(false, forKey: "petShapeAuto")
            updateAutoShape()
        }
        applyShape(shape)
    }
    func setAutomaticShape(_ enabled: Bool) {
        guard automaticShape != enabled else { return }
        automaticShape = enabled
        defaults.set(enabled, forKey: "petShapeAuto")
        if enabled { advanceAutoShape() }
        updateAutoShape()
        onShapeChange?()
    }
    func advanceAutoShape() {
        guard automaticShape else { return }
        let shapes = PetShape.allCases
        let index = shapes.firstIndex(of: view.shape) ?? 0
        applyShape(shapes[(index + 1) % shapes.count])
    }
    private func applyShape(_ shape: PetShape) {
        view.transition(to: shape, animated: panel.isVisible && !view.reduceMotion)
        defaults.set(shape.rawValue, forKey: "petShape")
        onPaletteChange?()
        onShapeChange?()
    }
    func setColorMode(_ mode: PetColorMode) {
        view.colorMode = mode
        defaults.set(mode.rawValue, forKey: "petColorMode")
        view.needsDisplay = true
        onPaletteChange?()
    }
    func setEyeColor(_ color: NSColor?) {
        if let rgb = color?.usingColorSpace(.sRGB) {
            view.eyeColor = rgb.withAlphaComponent(1)
            defaults.set([Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)], forKey: "petEyeColor")
        } else {
            view.eyeColor = nil
            defaults.removeObject(forKey: "petEyeColor")
        }
        view.needsDisplay = true
        onPaletteChange?()
    }
    func setRestColor(_ color: NSColor?) {
        if let rgb = color?.usingColorSpace(.sRGB) {
            view.restColor = rgb.withAlphaComponent(1)
            defaults.set([Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)], forKey: "petRestColor")
            setRestPalette(.custom)
        } else {
            view.restColor = nil
            defaults.removeObject(forKey: "petRestColor")
            setRestPalette(nil)
        }
    }
    func setRestPalette(_ palette: PetPalette?) {
        view.restPalette = palette
        if let palette { defaults.set(palette.rawValue, forKey: "petRestPalette") }
        else { defaults.removeObject(forKey: "petRestPalette") }
        view.needsDisplay = true
        onPaletteChange?()
    }
    func setRestColorMode(_ mode: PetColorMode) {
        view.restColorMode = mode
        defaults.set(mode.rawValue, forKey: "petRestColorMode")
        view.needsDisplay = true
        onPaletteChange?()
    }
    func setMood(_ mood: String?) {
        persistMood(mood)
        let item = NSMenuItem()
        item.representedObject = mood
        view.selectMood(item)
    }
    func persistMood(_ mood: String?) {
        if let mood { defaults.set(mood, forKey: "petMood") }
        else { defaults.removeObject(forKey: "petMood") }
    }
    func setPalette(_ palette: PetPalette) {
        view.palette = palette
        defaults.set(palette.rawValue, forKey: "petPalette")
        view.needsDisplay = true
        onPaletteChange?()
    }
    func setCustomColor(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        view.customColor = rgb.withAlphaComponent(1)
        defaults.set([Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)], forKey: "petCustomColor")
        defaults.set("sRGB", forKey: "petColorSpace")
        setPalette(.custom)
    }

    func resetPreferences() {
        automaticShape = false
        defaults.removeObject(forKey: "petShapeAuto")
        updateAutoShape()
        view.colorStyle = .radial
        view.palette = .rainbow
        view.customColor = .systemOrange
        view.shape = .blob
        view.colorMode = .solid
        view.eyeColor = nil
        view.restColor = nil
        view.restPalette = nil
        view.restColorMode = .solid
        view.selectMood(NSMenuItem())
        for key in ["colorStyle", "petPalette", "petCustomColor", "petColorSpace", "petShape", "petColorMode", "petEyeColor", "petRestColor", "petRestPalette", "petRestColorMode", "petMood"] {
            defaults.removeObject(forKey: key)
        }
        resize(to: 48)
        defaults.removeObject(forKey: "petSize")
        resetPosition()
        defaults.removeObject(forKey: "petX")
        defaults.removeObject(forKey: "petY")
        view.needsDisplay = true
        onPaletteChange?()
        onShapeChange?()
    }

    func setEnabled(_ enabled: Bool) {
        powerButton.state = enabled ? .on : .off
        powerButton.image = enabled ? Self.powerIcon : Self.powerInactiveIcon
        powerButton.image?.size = Self.controlIconSize
        powerButton.imageScaling = .scaleProportionallyDown
        powerButton.contentTintColor = enabled ? .controlAccentColor : .secondaryLabelColor
        powerButton.layer?.backgroundColor = enabled
            ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor
        powerButton.helpText = enabled ? L("Keep-awake is on · Click to turn off") : L("Keep-awake is off · Click to turn on")
        powerButton.setAccessibilityLabel(enabled ? L("Turn off keep-awake") : L("Turn on keep-awake"))
        view.isAwake = enabled
        view.needsDisplay = true
    }

    func setKeepAwakeMode(_ mode: KeepAwakeMode) {
        refreshLocalization()
        modeButton.image = Self.icon(for: mode)
        for item in modeMenu.items {
            item.state = item.representedObject as? String == mode.rawValue ? .on : .off
        }
        for (index, check) in modeOptionChecks.enumerated() {
            check.isHidden = modeMenu.items[index].representedObject as? String != mode.rawValue
        }
        let label: String = switch mode {
        case .display: L("Keep display awake")
        case .system: L("Allow display sleep, keep system running")
        case .lid: L("Keep running with lid closed")
        }
        modeButton.helpText = L("Keep-awake mode: {0} · Shared by power and Agent controls; click to change", "\(label)")
        modeButton.setAccessibilityLabel(modeButton.helpText)
    }

    func refreshLocalization() {
        guard modeLanguage != Localization.language else { return }
        modeLanguage = Localization.language
        LocalizationUI.refresh(modeMenu)
        guard let surface = modePopover.contentViewController?.view as? NSGlassEffectView,
              let content = surface.contentView else { return }
        LocalizationUI.refresh(content)
        let font = NSFont.systemFont(ofSize: 13)
        let longest = modeOptionLabels.map { ($0.stringValue as NSString).size(withAttributes: [.font: font]).width }.max() ?? 190
        let width = max(250, ceil(longest) + 70)
        surface.setFrameSize(NSSize(width: width, height: 120))
        content.setFrameSize(surface.frame.size)
        for label in modeOptionLabels { label.frame.size.width = width - 60 }
        for button in content.subviews.compactMap({ $0 as? NSButton }) { button.frame.size.width = width - 8 }
        modePopover.contentSize = surface.frame.size
        settingsButton.helpText = L("Open Settings")
        settingsButton.setAccessibilityLabel(L("Open Settings"))
    }

    func setAgentWatchEnabled(_ enabled: Bool) {
        agentButton.state = enabled ? .on : .off
        agentButton.image = enabled ? Self.robotIcon : Self.robotInactiveIcon
        agentButton.image?.size = Self.controlIconSize
        agentButton.imageScaling = .scaleProportionallyDown
        agentButton.contentTintColor = enabled ? .controlAccentColor : .secondaryLabelColor
        agentButton.layer?.backgroundColor = enabled
            ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor
        agentButton.helpText = enabled ? L("Turn off Agent watch") : L("Turn on Agent watch")
        agentButton.setAccessibilityLabel(agentButton.helpText)
    }

    func setDutyPhase(_ phase: DutyPhase) {
        let mood: String? = switch phase {
        case .agentStandby: "searching"
        case .agentActive: "listening"
        case .grace: "thinking"
        case .thermalPaused: "drowsy"
        case .lowBatteryStopped: "sad"
        case .fault: "confused"
        case .off, .manual: nil
        }
        let pause = phase == .thermalPaused
        guard view.dutyMood != mood || dutyAnimationPaused != pause else { return }
        view.dutyMood = mood
        dutyAnimationPaused = pause
        updateAnimation()
    }

    func setHeat(_ level: DutyHeat) {
        guard thermalLevel != level else { return }
        thermalLevel = level
        updateAnimation()
    }

    var petSize: Double {
        let value = defaults.object(forKey: "petSize") as? Double ?? 48
        return value.isFinite ? min(512, max(24, value)) : 48
    }

    func resize(to value: Double) {
        let size = value.isFinite ? min(512, max(24, value)) : 48
        defaults.set(size, forKey: "petSize")
        let art = size + 40
        let width = max(Self.controlsWidth + 4, art)
        controls.frame = NSRect(x: (width - Self.controlsWidth) / 2, y: 1,
                                width: Self.controlsWidth, height: 30)
        // Anchor the bar to the visible body, allowing the transparent animation
        // canvas to overlap it instead of adding its padding to the visual gap.
        let scale = (art - view.drawingPadding) / 259
        let bottomInset = art / 2 - (view.body.bounds.maxY - 114.27) * scale
        let petY = controls.frame.maxY + 12 - bottomInset
        panel.setContentSize(NSSize(width: width, height: art + petY))
        view.frame = NSRect(x: (width - art) / 2, y: petY, width: art, height: art)
        materialSurface.frame = view.frame
        container.updateTrackingAreas()
        fitOnScreen()
        view.needsDisplay = true
    }

    func show() {
        running = true
        sleeping = false
        epoch = ProcessInfo.processInfo.systemUptime
        fitOnScreen()
        panel.orderFrontRegardless()
        container.startMonitoring()
        updateAnimation()
    }

    func hide() {
        running = false
        timer?.invalidate()
        timer = nil
        shapeTimer?.invalidate()
        shapeTimer = nil
        panel.orderOut(nil)
        materialSurface.isHidden = true
        container.stopMonitoring()
        container.setControlsVisible(false)
    }

    func setSleeping(_ value: Bool) { sleeping = value; updateAnimation() }

    func updateAnimation() {
        timer?.invalidate()
        timer = nil
        view.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        view.needsDisplay = true
        updateAutoShape()
        guard running, !sleeping, !view.reduceMotion, !dutyAnimationPaused,
              thermalLevel != .critical else { return }
        let framesPerSecond: Double = thermalLevel >= .serious ? 12 : 24
        timer = Timer(timeInterval: 1 / framesPerSecond, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible,
                      self.panel.occlusionState.contains(.visible) else { return }
                self.view.animationTime = ProcessInfo.processInfo.systemUptime - self.epoch
                self.view.needsDisplay = true
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func updateAutoShape() {
        shapeTimer?.invalidate()
        shapeTimer = nil
        guard running, !sleeping, automaticShape else { return }
        shapeTimer = Timer(timeInterval: Double.random(in: 60...300), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advanceAutoShape()
                self?.updateAutoShape()
            }
        }
        RunLoop.main.add(shapeTimer!, forMode: .common)
    }

    static func clamped(_ frame: NSRect, to area: NSRect) -> NSRect {
        var frame = frame
        frame.origin.x = min(max(frame.minX, area.minX), max(area.minX, area.maxX - frame.width))
        frame.origin.y = min(max(frame.minY, area.minY), max(area.minY, area.maxY - frame.height))
        return frame
    }

    func fitOnScreen() {
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        panel.setFrame(Self.clamped(panel.frame, to: screen.visibleFrame.insetBy(dx: 6, dy: 6)), display: true)
    }

    func resetPosition() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: area.maxX - panel.frame.width - 18, y: area.minY + 18))
        savePosition()
    }

    func savePosition() {
        defaults.set(panel.frame.minX, forKey: "petX")
        defaults.set(panel.frame.minY, forKey: "petY")
    }
}
