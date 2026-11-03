import AppKit

/// A side-on constellation whale. The head leads a travelling flexion wave;
/// the peduncle, flukes, fins and constellation points share that same motion.
@MainActor
private final class DreamWhaleGeometry {
    static let shared = DreamWhaleGeometry()
    let body = NSBezierPath()
    let outline = NSBezierPath()
    let tail = NSBezierPath()
    let pleats = NSBezierPath()
    let fin = NSBezierPath()
    let dorsal = NSBezierPath()
    let bodyGlow = CGGradient(colorsSpace:CGColorSpace(name:CGColorSpace.sRGB)!,
        colors:[NSColor(srgbRed:0.12,green:0.73,blue:1,alpha:0.28).cgColor,
                NSColor(srgbRed:0.04,green:0.32,blue:0.65,alpha:0).cgColor] as CFArray,locations:[0,1])!
    let eye = NSBezierPath(ovalIn:NSRect(x:-63.5,y:6.5,width:3,height:3))
    let tailNode = NSBezierPath(ovalIn:NSRect(x:-1.7,y:-1.7,width:3.4,height:3.4))
    private(set) var tailTips = [NSPoint.zero,NSPoint.zero]
    let spout = NSBezierPath()
    let sprayDot = NSBezierPath(ovalIn:NSRect(x:-1,y:-1,width:2,height:2))
    private let depthX: CGFloat = sin(0.18)
    private let depthY: CGFloat = cos(0.18)
    var didLogPixelScale = false
    struct SprayParticle {
        let launch: Double
        let velocity: NSPoint
        let radius: CGFloat
        let drift: CGFloat
    }
    private let sprayParticles: [SprayParticle] = (0..<18).map { index in
        let seed = Double(index)
        return SprayParticle(launch:seed*0.039,
            velocity:NSPoint(x:sin(seed*2.17)*18,y:-48-14*(0.5+0.5*cos(seed*1.31))),
            radius:CGFloat(0.65+0.55*(0.5+0.5*sin(seed*3.2))),drift:CGFloat(sin(seed*1.7)*5))
    }
    struct Dust {
        let position: NSPoint
        let radius: CGFloat
        let sine: Double
        let cosine: Double
        let bendWave: SIMD2<Double>
    }
    struct FilteredDust {
        let position: NSPoint
        let path: NSBezierPath
        let gain: Double
        let sine: Double
        let cosine: Double
        let bendWave: SIMD2<Double>
    }
    struct Node {
        let position: NSPoint
        let path: NSBezierPath
    }
    private var seeds: [Dust] = []
    private var cachedScale: CGFloat = 0
    private var filtered: [FilteredDust] = []
    private(set) var nodes: [Node] = []

    private init() {
        for path in [outline,tail,pleats,fin,dorsal,spout] { path.lineCapStyle = .round;path.lineJoinStyle = .round }
        fin.move(to:.zero)
        fin.curve(to:NSPoint(x:13,y:27),controlPoint1:NSPoint(x:9,y:13),controlPoint2:NSPoint(x:3,y:24))
        fin.curve(to:NSPoint(x:31,y:7),controlPoint1:NSPoint(x:21,y:29),controlPoint2:NSPoint(x:27,y:16))
        fin.curve(to:.zero,controlPoint1:NSPoint(x:16,y:11),controlPoint2:NSPoint(x:5,y:4))
        fin.close()
        dorsal.move(to:NSPoint(x:8,y:-12))
        dorsal.curve(to:NSPoint(x:22,y:-24),controlPoint1:NSPoint(x:16,y:-14),controlPoint2:NSPoint(x:21,y:-22))
        dorsal.curve(to:NSPoint(x:26,y:-8),controlPoint1:NSPoint(x:18,y:-15),controlPoint2:NSPoint(x:22,y:-10))
        dorsal.close()
        update(phase:0)
        var candidate = 0
        while seeds.count<120 {
            let seed = Double(candidate)
            let position = NSPoint(x:sin(seed*127.1)*73,y:sin(seed*311.7)*38)
            if body.contains(NSPoint(x:position.x,y:position.y+bend(position.x,phase:0))) {
                let u = Double(min(1,max(0,(position.x+55)/110)))
                let wave = SIMD2(10*u*u*cos(u*1.25),10*u*u*sin(u*1.25))
                seeds.append(Dust(position:position,radius:candidate%11 == 0 ? 1.05 : 0.58,
                    sine:sin(seed*1.7),cosine:cos(seed*1.7),bendWave:wave))
            }
            candidate += 1
        }
        nodes = [NSPoint(x:-71,y:-13),NSPoint(x:-54,y:-10),NSPoint(x:-30,y:-6),NSPoint(x:4,y:-3),
            NSPoint(x:45,y:0),NSPoint(x:45,y:8),NSPoint(x:-1,y:30),NSPoint(x:-51,y:30)].map {
                Node(position:$0,path:NSBezierPath(ovalIn:NSRect(x:$0.x-1.55,y:$0.y-1.55,width:3.1,height:3.1)))
            }
    }

    func bend(_ x: CGFloat,phase: Double) -> CGFloat {
        let u = min(1,max(0,(x+55)/110))
        return 10*u*u*sin(phase-Double(u)*1.25)
    }

    func update(phase: Double) {
        func p(_ x: CGFloat,_ y: CGFloat) -> NSPoint { NSPoint(x:x,y:y+bend(x,phase:phase)) }
        // Reuse the four animated paths. The head stays firm; flexion grows
        // towards the narrow tail stock, rather than distorting the whole fish.
        body.removeAllPoints();outline.removeAllPoints();tail.removeAllPoints();pleats.removeAllPoints()
        for path in [body,outline] {
            path.move(to:p(-70,-15))
            path.curve(to:p(45,0),controlPoint1:p(-40,-24),controlPoint2:p(15,-18))
            if path === body { path.line(to:p(45,8)) } else { path.move(to:p(45,8)) }
            path.curve(to:p(-54,30),controlPoint1:p(-8,39),controlPoint2:p(-33,43))
            path.curve(to:p(-77,15),controlPoint1:p(-68,30),controlPoint2:p(-78,21))
            path.curve(to:p(-70,-15),controlPoint1:p(-80,6),controlPoint2:p(-78,-8))
        }
        body.close()
        // The two lobes spread horizontally in the whale's local x/z plane.
        // Pitch follows peduncle velocity, not its displacement: a stroke
        // changes angle of attack and projected depth instead of translating
        // an unchanged fish-tail silhouette up and down.
        let pitch = 0.52*cos(phase-1.25),bank = 0.66+0.05*sin(phase*0.5)
        let root = p(45,4),pitchCosine = cos(pitch),pitchSine = sin(pitch),projectedDepth = depthY*sin(bank)
        func fluke(_ x: CGFloat,_ depth: CGFloat) -> NSPoint {
            NSPoint(x:root.x+x*pitchCosine+depth*depthX,
                    y:root.y+x*pitchSine+depth*projectedDepth)
        }
        tail.move(to:fluke(0,0))
        tail.curve(to:fluke(34,-31),controlPoint1:fluke(10,-9),controlPoint2:fluke(20,-33))
        tail.curve(to:fluke(16,0),controlPoint1:fluke(33,-16),controlPoint2:fluke(21,-7))
        tail.curve(to:fluke(34,31),controlPoint1:fluke(21,7),controlPoint2:fluke(33,16))
        tail.curve(to:fluke(0,0),controlPoint1:fluke(20,33),controlPoint2:fluke(10,9))
        tail.close()
        tailTips[0] = fluke(34,-31);tailTips[1] = fluke(34,31)
        for offset in [0.0,4,8] {
            pleats.move(to:p(-73+offset,13+offset*0.4))
            pleats.curve(to:p(8-offset,27+offset*0.3),controlPoint1:p(-55+offset,32+offset*0.3),controlPoint2:p(-24,36+offset*0.3))
        }
    }

    func particles(at scale: CGFloat) -> [FilteredDust] {
        if abs(scale-cachedScale)<0.0001 { return filtered }
        cachedScale = scale
        filtered = seeds.map { seed in
            let radius = max(seed.radius,0.55/max(scale,0.001))
            return FilteredDust(position:seed.position,
                path:NSBezierPath(ovalIn:NSRect(x:seed.position.x-radius,y:seed.position.y-radius,width:radius*2,height:radius*2)),
                gain:Double(pow(seed.radius/radius,2)),sine:seed.sine,cosine:seed.cosine,bendWave:seed.bendWave)
        }
        return filtered
    }

    func drawSpout(age: Double,phase: Double,scale: CGFloat,opacity: Double,context: CGContext) {
        guard age<2.8 else { return }
        context.saveGState()
        // The blowhole sits behind the forehead, on the firm part of the back.
        context.translateBy(x:-48,y:-12.8+bend(-48,phase:phase))
        let rise = min(1,max(0,age/0.35))
        let fade = min(1,max(0,(1.25-age)/0.60))
        let jetAlpha = rise*rise*(3-2*rise)*fade*fade*(3-2*fade)*opacity
        let height = CGFloat(42*(1-exp(-age*7)))
        spout.removeAllPoints()
        spout.move(to:.zero)
        spout.curve(to:NSPoint(x:0,y:-height*0.72),controlPoint1:NSPoint(x:1,y:-height*0.3),controlPoint2:NSPoint(x:-1,y:-height*0.57))
        for side: CGFloat in [-1,1] {
            spout.move(to:NSPoint(x:0,y:-height*0.52))
            spout.curve(to:NSPoint(x:side*15,y:-height*0.83),
                controlPoint1:NSPoint(x:side*4,y:-height),controlPoint2:NSPoint(x:side*12,y:-height*1.04))
        }
        let coreWidth = max(1.05,1.4/max(scale,0.001))
        for (width,alpha) in [(5.5,0.06),(coreWidth,0.62*Double(1.05/coreWidth))] {
            spout.lineWidth = width
            NSColor(srgbRed:0.58,green:0.91,blue:1,alpha:jetAlpha*alpha).setStroke();spout.stroke()
        }
        for particle in sprayParticles {
            let elapsed = age-particle.launch
            guard elapsed>0,elapsed<2.1 else { continue }
            let flight = CGFloat(elapsed)
            let x = particle.velocity.x*flight+particle.drift*flight*flight*0.35
            let y = particle.velocity.y*flight+37*flight*flight
            let birth = min(1,elapsed/0.40),death = min(1,max(0,(2.1-elapsed)/0.65))
            let aboveBack = min(1,max(0,(7-y)/12))
            let alpha = birth*birth*(3-2*birth)*death*death*aboveBack*opacity
            let radius = max(particle.radius,0.90/max(scale,0.001))
            let gain = Double(pow(particle.radius/radius,2))
            context.saveGState();context.translateBy(x:x,y:y)
            context.saveGState();context.scaleBy(x:radius*3.5,y:radius*2.5)
            NSColor(srgbRed:0.42,green:0.85,blue:1,alpha:alpha*0.055*gain).setFill();sprayDot.fill()
            context.restoreGState();context.scaleBy(x:radius,y:radius*1.4)
            NSColor(srgbRed:0.77,green:0.96,blue:1,alpha:alpha*0.62*gain).setFill();sprayDot.fill()
            context.restoreGState()
        }
        context.restoreGState()
    }
}

@MainActor
func drawDreamWhales(time: Double, opacity: Double,displayScale: CGFloat? = nil) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let geometry = DreamWhaleGeometry.shared
    let transform = context.ctm
    let contextScale = sqrt(abs(transform.a*transform.d-transform.b*transform.c))
    let physicalScale = (displayScale ?? contextScale)*0.95
    if CommandLine.arguments.contains("--review-whale-display-log"),!geometry.didLogPixelScale {
        geometry.didLogPixelScale = true
        fputs("WHALE DISPLAY contextScale=\(contextScale) explicitBackingScale=\(displayScale.map(String.init(describing:)) ?? "none") filteredScale=\(physicalScale)\n",stderr)
    }
    let phase = time*1.30
    let breathAge = (time+8.5).truncatingRemainder(dividingBy:9.5)
    let surface = breathAge<2.8 ? pow(sin(breathAge/2.8*Double.pi),2) : 0
    geometry.update(phase:phase)
    context.saveGState()
    // Water and stars pass the whale to show forward travel. A gentle course
    // change and stroke recoil keep it in view without flips or disappearing.
    context.translateBy(x:112-12*sin(time*0.20)-0.6*sin(phase*2),y:151+3*sin(time*0.24)+0.8*sin(phase)-4*surface)
    context.rotate(by:-0.18+0.040*sin(phase-0.65)+0.025*cos(time*0.20)+0.055*surface)
    context.scaleBy(x:0.95,y:0.95)
    geometry.drawSpout(age:breathAge,phase:phase,scale:physicalScale,opacity:opacity,context:context)
    // The far pectoral fin is visible through the constellation volume; both
    // fins stabilize the body with smaller strokes than the propulsive flukes.
    context.saveGState()
    context.translateBy(x:-38,y:14+geometry.bend(-38,phase:phase))
    context.rotate(by:-0.25+0.10*sin(phase-0.65));context.scaleBy(x:0.72,y:0.55)
    geometry.fin.lineWidth = max(0.85,0.5/max(physicalScale,0.001))
    NSColor(srgbRed:0.25,green:0.71,blue:0.90,alpha:0.30*opacity).setStroke();geometry.fin.stroke()
    context.restoreGState()
    context.saveGState();context.translateBy(x:0,y:geometry.bend(18,phase:phase))
    geometry.dorsal.lineWidth = max(0.9,0.5/max(physicalScale,0.001))
    NSColor(srgbRed:0.32,green:0.79,blue:0.96,alpha:0.48*opacity).setStroke();geometry.dorsal.stroke()
    context.restoreGState()
    NSColor(srgbRed:0.07,green:0.43,blue:0.68,alpha:0.13*opacity).setFill()
    geometry.body.fill();geometry.tail.fill()
    context.saveGState();geometry.body.addClip();context.setAlpha(opacity)
    context.drawRadialGradient(geometry.bodyGlow,startCenter:CGPoint(x:-36,y:5),startRadius:3,
        endCenter:CGPoint(x:-36,y:5),endRadius:88,options:[.drawsAfterEndLocation])
    context.restoreGState()
    let coreWidth = max(1.10,1.0/max(physicalScale,0.001))
    let coreGain = Double(1.10/coreWidth)
    for (width,alpha) in [(7.0,0.04),(3.5,0.14),(coreWidth,0.88*coreGain)] {
        geometry.outline.lineWidth = width
        NSColor(srgbRed:0.50,green:0.93,blue:1,alpha:alpha*opacity).setStroke()
        geometry.outline.stroke()
        // Fast fluke edges use a wider reconstruction footprint than the
        // slowly moving torso, while preserving each stroke's light energy.
        let flukeWidth = max(width,2.5/max(physicalScale,0.001))
        geometry.tail.lineWidth = flukeWidth
        NSColor(srgbRed:0.50,green:0.93,blue:1,alpha:alpha*Double(width/flukeWidth)*opacity).setStroke()
        geometry.tail.stroke()
    }
    let sine = sin(time*0.75),cosine = cos(time*0.75)
    let bendSine = sin(phase),bendCosine = cos(phase)
    for dust in geometry.particles(at:physicalScale) {
        let bend = bendSine*dust.bendWave.x-bendCosine*dust.bendWave.y
        context.saveGState();context.translateBy(x:0,y:CGFloat(bend))
        let alpha = (0.42+0.16*(sine*dust.cosine+cosine*dust.sine))*dust.gain*opacity
        NSColor(srgbRed:0.36,green:0.87,blue:1,alpha:alpha).setFill();dust.path.fill()
        context.restoreGState()
    }
    let detail = min(1,max(0,(physicalScale-0.16)/0.35))
    geometry.pleats.lineWidth = max(0.65,0.35/max(physicalScale,0.001))
    NSColor(srgbRed:0.36,green:0.82,blue:1,alpha:0.45*opacity*detail).setStroke();geometry.pleats.stroke()
    context.saveGState()
    context.translateBy(x:-26,y:18+geometry.bend(-26,phase:phase));context.rotate(by:sin(phase-0.4)*0.14)
    NSColor(srgbRed:0.10,green:0.58,blue:0.8,alpha:0.10*opacity).setFill();geometry.fin.fill()
    geometry.fin.lineWidth = max(0.85,0.5/max(physicalScale,0.001))
    NSColor(srgbRed:0.42,green:0.87,blue:1,alpha:0.80*opacity).setStroke();geometry.fin.stroke()
    context.restoreGState()
    for (index,node) in geometry.nodes.enumerated() {
        let filter = max(1,0.70/(1.55*max(physicalScale,0.001)))
        context.saveGState()
        context.translateBy(x:node.position.x,y:node.position.y+geometry.bend(node.position.x,phase:phase))
        context.scaleBy(x:filter,y:filter);context.translateBy(x:-node.position.x,y:-node.position.y)
        let alpha = (0.72+0.12*sin(time*0.65+Double(index)*1.3))*opacity/Double(filter*filter)
        NSColor(srgbRed:0.66,green:0.96,blue:1,alpha:alpha).setFill();node.path.fill()
        context.restoreGState()
    }
    NSColor(srgbRed:0.77,green:0.98,blue:1,alpha:opacity).setFill();geometry.eye.fill()
    for point in geometry.tailTips {
        context.saveGState();context.translateBy(x:point.x,y:point.y)
        let filter = max(1,1.2/(1.7*max(physicalScale,0.001)))
        context.scaleBy(x:filter,y:filter)
        NSColor(srgbRed:0.67,green:0.96,blue:1,alpha:0.85*opacity/Double(filter*filter)).setFill()
        geometry.tailNode.fill();context.restoreGState()
    }
    context.restoreGState()
}
