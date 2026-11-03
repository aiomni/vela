import VelaLocalization
import AppKit
import Carbon
import IOKit.pwr_mgt
import ServiceManagement
import RemoteCore
import Metal

@MainActor
private final class VerificationApplication: NSObject,NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            do { try verifyVela();exit(0) }
            catch { fputs("FAIL: \(error.localizedDescription)\n",stderr);exit(1) }
        }
    }
}

@MainActor
func runVerificationApplication() {
    let delegate = VerificationApplication()
    NSApp.delegate = delegate
    NSApp.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { NSApp.run() }
}

/// WindowServer visibility notifications arrive as AppKit events; a CF run-loop
/// wait alone does not exercise the same event delivery as the real application.
@MainActor
private func dispatchNativeEvents(for seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date()<deadline {
        let next = min(deadline,Date().addingTimeInterval(0.01))
        if let event = NSApp.nextEvent(matching:.any,until:next,inMode:.default,dequeue:true) {
            NSApp.sendEvent(event)
        }
        NSApp.updateWindows()
    }
}

private func iconInkSize(_ image: NSImage) -> NSSize {
    let scale = 4
    let width = Int(image.size.width) * scale
    let height = Int(image.size.height) * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { return .zero }
    return NSSize(width: CGFloat(maxX - minX + 1) / CGFloat(scale),
                  height: CGFloat(maxY - minY + 1) / CGFloat(scale))
}

private func exportControlIconPreview(_ images: [NSImage], to path: String) throws {
    let cellWidth = 92
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cellWidth * images.count,
                                  pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4,
                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: cellWidth * images.count, height: 100).fill()
    for (index, image) in images.enumerated() {
        image.draw(in: NSRect(x: index * cellWidth + 22, y: 27, width: 48, height: 48))
        let label = ["Power", "Agent", "Display", "System", "Lid", "Settings"][index]
        (label as NSString).draw(at: NSPoint(x: index * cellWidth + 20, y: 10),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 11),
                                                  .foregroundColor: NSColor.black])
    }
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

@MainActor
private final class TestLoginItem: LoginItemServicing {
    var status = SMAppService.Status.notRegistered
    var failure = false
    var approval = false
    func register() throws {
        if failure { throw NSError(domain: "Verification", code: 1) }
        status = approval ? .requiresApproval : .enabled
    }
    func unregister() throws { status = .notRegistered }
    func openSettings() {}
}

@MainActor
func verifyVela() throws {
    verifySettingsControls()
    if let failure = ShaderMaterials.shared.failure {
        throw NSError(domain:"Vela.Materials",code:1,userInfo:[NSLocalizedDescriptionKey:failure])
    }
    // Fixed writable storage must reject a fourth in-flight frame and reuse only
    // the released slot. Other leased buffers retain their own contents/identity.
    let bufferPool = try StarRingBuffers(device:ShaderMaterials.shared.renderingDevice!,vertexStride:80,fieldStride:64)
    let first = bufferPool.acquire()!,second = bufferPool.acquire()!,third = bufferPool.acquire()!
    precondition(bufferPool.acquire() == nil)
    precondition(ObjectIdentifier(first.1.vertices) != ObjectIdentifier(second.1.vertices))
    precondition(ObjectIdentifier(second.1.vertices) != ObjectIdentifier(third.1.vertices))
    bufferPool.release(second.0)
    let reused = bufferPool.acquire()!
    precondition(reused.0==second.0 && ObjectIdentifier(reused.1.vertices)==ObjectIdentifier(second.1.vertices))
    precondition(bufferPool.acquire() == nil)
    bufferPool.release(first.0);bufferPool.release(reused.0);bufferPool.release(third.0)
    print("PASS: bounded GPU buffer leases / no in-flight overwrite / released storage reused")
    for palette in PetPalette.selectable where palette.shaderKind != nil {
        precondition(ShaderMaterials.shared.image(for: palette, time: 0) != nil)
    }
    print("PASS: Metal material compilation / all selectable shader materials rendered")
    let sharedMaterials = ShaderMaterials.shared
    let fieldPalettes = PetPalette.selectable.filter { $0.shaderKind != nil && $0 != .stars }
    var fieldAllocations: Int?
    for palette in fieldPalettes {
        let field = sharedMaterials.fieldImage(for:palette,time:0,bodyPixels:96,pixelFootprint:1/96)!
        let pixels = NSBitmapImageRep(cgImage:field)
        for (x,y) in [(0,0),(143,0),(0,143),(143,143),(72,128)] {
            precondition(pixels.colorAt(x:x,y:y)!.alphaComponent<0.01,"Material has an opaque background or ground pool: \(palette)")
        }
        precondition(pixels.colorAt(x:72,y:72)!.alphaComponent>0.99)
        let raw = field.dataProvider!.data! as Data
        raw.withUnsafeBytes { bytes in
            let values = bytes.bindMemory(to:UInt8.self)
            for offset in stride(from:0,to:values.count,by:4) { for channel in 0..<3 {
                precondition(Int(values[offset+channel])<=Int(values[offset+3])+1,"Material violates premultiplied alpha")
            }}
        }
        let allocations = sharedMaterials.fieldTextureAllocations
        if let fieldAllocations { precondition(allocations==fieldAllocations,"Same-size review target was reallocated") }
        else { fieldAllocations = allocations }
        precondition(sharedMaterials.fieldImage(for:palette,time:4,bodyPixels:96,pixelFootprint:1/96) != nil)
        precondition(sharedMaterials.fieldTextureAllocations==allocations)
    }
    print("PASS: native material pass transparency / no ground pool / premultiplied alpha / fixed-size target reuse")
    // Reference 04 crop: (29,392)-(429,792), center (200,200), radius 160.
    // These measured bright cores include the three smaller blue orbit stars,
    // not merely the six major emitters. They protect against misplaced or lost
    // stars after refraction; they do not establish overall visual acceptance.
    let referenceStars: [(Double, Double)] = [(-0.53125,-0.650),(-0.73125,0.48125),(0.7875,-0.050),
        (0.5625,-0.7125),(0.050,-0.650),(-0.89375,-0.050),
        (0.36875,-0.4875),(0.19375,-0.40625),(-0.525,0.250)]
    let starBody = NSBitmapImageRep(cgImage: ShaderMaterials.shared.image(for: .stars,time: 0)!)
    func peak(_ x:Double,_ y:Double,in image:NSBitmapImageRep) -> Double {
        let cx = Int((x+1)*256), cy = Int((y+1)*256)
        var peak = 0.0
        for px in (cx-7)...(cx+7) { for py in (cy-7)...(cy+7) {
            let c = image.colorAt(x: px,y: py)!.usingColorSpace(.sRGB)!
            peak = max(peak,0.2126*c.redComponent+0.7152*c.greenComponent+0.0722*c.blueComponent)
        }}
        return peak
    }
    for (x,y) in referenceStars {
        precondition(peak(x,y,in:starBody) > 0.65,"A reference star disappeared through the glass shell")
    }
    let fullField = NSBitmapImageRep(cgImage: ShaderMaterials.shared.starRenderer!.reviewImage(time: 0)!)
    for (x,y) in [(0,0),(767,0),(0,767),(767,767)] {
        precondition(fullField.colorAt(x:x,y:y)!.alphaComponent < 0.01,"Square background outside the pet")
    }
    precondition(fullField.colorAt(x:384,y:384)!.alphaComponent > 0.99)
    print("PASS: nine reference star landmarks remain visible / transparent field corners")
    // Independent reference neighborhoods expose duplicated fixed cores: a global
    // animation delta can pass even while a small star's brightest core stays put.
    let movedStars = NSBitmapImageRep(cgImage:ShaderMaterials.shared.image(for:.stars,time:9)!)
    for (x,y) in referenceStars.suffix(3) {
        precondition(peak(x,y,in:movedStars)<peak(x,y,in:starBody)*0.85,
            "A small orbit star left a stationary bright core at its initial location")
    }
    print("PASS: small blue star cores move away from all three initial reference neighborhoods")
    let transparentField = ShaderMaterials.shared.starRenderer!.reviewImage(time:0)!
    let raw = transparentField.dataProvider!.data! as Data
    var partialPixels = 0
    raw.withUnsafeBytes { bytes in
        let pixels = bytes.bindMemory(to:UInt8.self)
        for y in 0..<transparentField.height { for x in 0..<transparentField.width {
            let offset = y*transparentField.bytesPerRow+x*4
            let alpha = pixels[offset+3]
            if alpha>0 && alpha<255 { partialPixels += 1 }
            for channel in 0..<3 {
                precondition(Int(pixels[offset+channel])<=Int(alpha)+1,"Transparent material violates premultiplied-alpha presentation")
            }
        }}
    }
    precondition(partialPixels>100,"Review must include actual antialiased edges and soft transparent light")
    print("PASS: premultiplied-alpha pixel contract / antialiased transparent edges")
    for palette in PetPalette.selectable where palette.shaderKind != nil {
        for frame in 0..<6 {
            precondition(ShaderMaterials.shared.image(for: palette, time: 20 + Double(frame) / 15) != nil)
        }
        print("PASS: bounded \(palette == .stars ? 512 : 256)px \(palette.title) surface / six distinct phases")
    }
    var color = ColorTransition()
    color.set(1, at: 10, animated: true)
    precondition(color.value(at: 10) == 0 && abs(color.value(at: 10.2) - 0.5) < 0.001)
    let middle = color.value(at: 10.2)
    color.set(0, at: 10.2, animated: true)
    precondition(abs(color.value(at: 10.2) - middle) < 0.001 && color.value(at: 10.7) == 0)
    color.set(1, at: 11, animated: false)
    precondition(color.value(at: 11) == 1)
    print("PASS: smooth color transition / continuous reversal / reduced-motion snap")
    for style in ColorTransitionStyle.allCases where style != .fade {
        let start = style.mask(at: 0)!
        let middle = style.mask(at: 0.5)!
        let end = style.mask(at: 1)!
        precondition(start.bounds.width == 0 && middle.bounds.width > 0)
        precondition(end.contains(NSPoint(x: 0, y: 114)) && end.contains(NSPoint(x: 229, y: 114)))
    }
    print("PASS: radial/corner/burst reveal masks and endpoint coverage")
    let power = PowerController()
    defer { power.disable() }
    precondition(!power.isEnabled)
    try power.enable()
    let id = power.assertion!
    try power.enable()
    precondition(power.assertion == id, "Repeated enable must not leak an assertion")
    let properties = IOPMAssertionCopyProperties(id)!.takeRetainedValue() as NSDictionary
    precondition(properties["AssertType"] as? String == "PreventUserIdleDisplaySleep")
    precondition((properties["AssertLevel"] as? NSNumber)?.intValue == Int(kIOPMAssertionLevelOn))
    power.disable()
    power.disable()
    precondition(!power.isEnabled && IOPMAssertionCopyProperties(id) == nil)
    print("PASS: display assertion enable/idempotence/disable/release")

    let hotKey = HotKey()
    defer { hotKey.stop() }
    try hotKey.install()
    let candidate = Shortcut(keyCode: UInt32(kVK_F19), modifiers: UInt32(cmdKey | controlKey | optionKey), keyLabel: "F19")
    try hotKey.register(candidate)
    try hotKey.register(candidate)
    let other = HotKey()
    defer { other.stop() }
    do {
        try other.register(candidate)
        fatalError("A duplicate hotkey should not register")
    } catch {
        precondition(hotKey.shortcut == candidate && other.shortcut == nil)
    }
    print("PASS: hotkey registration/conflict handling")
    hotKey.stop()

    let suite = "Vela.verification.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    WakeDuration.minutes(Int.max).save(to: defaults)
    precondition(WakeDuration.load(from: defaults) == .minutes(Int.max))
    WakeDuration.unlimited.save(to: defaults)
    precondition(WakeDuration.load(from: defaults) == .unlimited)
    precondition(IdleThreshold.load(from: defaults) == .defaultValue)
    IdleThreshold(minutes: 7).save(to: defaults)
    precondition(IdleThreshold.load(from: defaults).minutes == 7)
    IdleThreshold.defaultValue.save(to: defaults)
    precondition(defaults.object(forKey: IdleThreshold.preferenceKey) == nil)
    var idleFlow = IdleWakeTimer(duration: .minutes(2), threshold: .defaultValue)
    idleFlow.arm(at: 100)
    precondition(idleFlow.phase == .waiting && !idleFlow.tick(at: 339.9))
    precondition(!idleFlow.tick(at: 340) && idleFlow.phase == .counting)
    precondition(abs(idleFlow.remaining(at: 340)! - 120) < 0.01)
    precondition(idleFlow.recordPhysicalInput(at: 400) && idleFlow.phase == .waiting)
    precondition(!idleFlow.tick(at: 639) && !idleFlow.tick(at: 640))
    precondition(idleFlow.tick(at: 760))
    let simulatedEvent = CGEvent(mouseEventSource: CGEventSource(stateID: .privateState),
                                 mouseType: .mouseMoved, mouseCursorPosition: .zero,
                                 mouseButton: .left)!
    simulatedEvent.setIntegerValueField(.eventSourceUnixProcessID, value: 123)
    precondition(!PhysicalInputMonitor.isPhysical(simulatedEvent))
    simulatedEvent.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
    precondition(PhysicalInputMonitor.isPhysical(simulatedEvent))
    print("PASS: idle threshold persistence / physical-only input filter / delayed and resettable countdown")
    let pet = try PetController(defaults: defaults)
    defer { pet.hide() }
    pet.setEnabled(true)
    pet.resize(to: 24)
    precondition(pet.view.frame.width == 64 && pet.panel.frame.width == 150)
    precondition(pet.controls.frame.minX >= 0 && pet.controls.frame.maxX <= pet.panel.contentView!.bounds.maxX)
    precondition(pet.powerButton.frame.maxX < pet.agentButton.frame.minX &&
                 pet.agentButton.frame.maxX < pet.modeButton.frame.minX)
    precondition(pet.agentButton.image != nil && pet.modeButton.frame.maxX < pet.settingsButton.frame.minX)
    pet.resize(to: 96)
    precondition(pet.view.frame.width == 136 && pet.panel.frame.width == 150)
    pet.resize(to: 256)
    precondition(pet.petSize == 256 && pet.view.frame.width == 296 && pet.panel.frame.width == 296)
    pet.resize(to: 512)
    precondition(pet.petSize == 512 && pet.view.frame.width == 552 && pet.panel.frame.width == 552)
    pet.resize(to: 900)
    precondition(pet.petSize == 512)
    pet.resize(to: .nan)
    precondition(pet.petSize == 48)
    let clamped = PetController.clamped(NSRect(x: -4000, y: 9999, width: 60, height: 60),
                                      to: NSRect(x: -1920, y: 40, width: 1920, height: 1000))
    precondition(clamped.minX == -1920 && clamped.maxY == 1040)
    print("PASS: asset topology/24–512 pt size bounds/multiple-screen geometry")
    let animation = PetAnimation(moods: pet.view.geometry.moods)
    var visitedMoods = Set<String>()
    var visitedEyes = Set<Int>()
    for step in 0...Int(animation.cycleDuration * 100) {
        let frame = animation.frame(at: Double(step) / 100)
        visitedMoods.insert(frame.mood)
        visitedEyes.insert(frame.to)
        precondition((0..<25).contains(frame.from) && (0..<25).contains(frame.to))
        precondition(frame.blend.isFinite && (0...1).contains(frame.blend))
    }
    let catalogEyes = Set(PetAnimation.catalog.flatMap { pet.view.geometry.moods[$0.id]!.eyes })
    precondition(visitedMoods.count == PetAnimation.catalog.count && visitedEyes == catalogEyes)
    precondition(pet.view.geometry.eyes.count == 25 && pet.view.geometry.moods.count == 39)
    for mood in pet.view.geometry.moods.keys.sorted() {
        let frame = animation.frame(at: 1, override: mood, reduced: true)
        precondition(frame.mood == mood && frame.rotation == 0 && frame.bounce == 0)
        precondition(frame.lid > 0 && frame.lid <= 1)
    }
    precondition(animation.frame(at: 1, override: "sleeping", reduced: true).lid
        < animation.frame(at: 1, override: "drowsy", reduced: true).lid)
    precondition(animation.frame(at: 1, override: "drowsy", reduced: true).lid
        < animation.frame(at: 1, override: "idle", reduced: true).lid)
    print("PASS: all 22 cycling moods / all 25 original eye poses and 39 expression records retained / reduced-motion states")

    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/pet-previews")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    precondition(pet.view.geometry.shapes.count == 19)
    for shape in PetShape.allCases {
        let ring = ShapeMorphGeometry.ring(for: pet.view.geometry.shapes[shape.rawValue]!)
        precondition(ring.count == ShapeMorphGeometry.ringCount && ring.allSatisfy {
            $0.x.isFinite && $0.y.isFinite && hypot($0.x - 114.27, $0.y - 114.27) > 15
        }, "Invalid morph ring for \(shape)")
    }
    let morphView = PetView(geometry: pet.view.geometry)
    morphView.transition(to: .tablet, at: 100, animated: true)
    let morphStart = morphView.shapeFrame(at: 100)
    let morphMiddle = morphView.shapeFrame(at: 100.18)
    let morphTarget = pet.view.geometry.bodyPath(for: .tablet)
    precondition(morphStart.morphing && morphMiddle.morphing)
    precondition(abs(morphStart.path.bounds.width - pet.view.geometry.bodyPath().bounds.width) < 0.01)
    precondition(abs(morphMiddle.path.bounds.height - morphStart.path.bounds.height) > 1)
    precondition(abs(morphMiddle.path.bounds.height - morphTarget.bounds.height) > 1)
    let beforeRetarget = morphView.shapeFrame(at: 100.18)
    morphView.transition(to: .cloud, at: 100.18, animated: true)
    let afterRetarget = morphView.shapeFrame(at: 100.18)
    precondition(abs(beforeRetarget.path.bounds.width - afterRetarget.path.bounds.width) < 0.5)
    precondition(abs(beforeRetarget.face.sx - afterRetarget.face.sx) < 0.001)
    let settled = morphView.shapeFrame(at: 101)
    precondition(!settled.morphing && abs(settled.path.bounds.width - pet.view.geometry.bodyPath(for: .cloud).bounds.width) < 0.01)
    let morphPreviewView = PetView(geometry: pet.view.geometry)
    morphPreviewView.transition(to: .tablet, at: 100, animated: true)
    let morphPreview = NSImage(size: NSSize(width: 600, height: 120), flipped: true) { _ in
        let context = NSGraphicsContext.current!.cgContext
        for (index, elapsed) in [0.0, 0.1, 0.18, 0.28, 0.65].enumerated() {
            context.saveGState()
            context.translateBy(x: CGFloat(index) * 120 + 10, y: 10)
            context.scaleBy(x: 100 / 228.54, y: 100 / 228.54)
            NSColor.systemBlue.setFill()
            morphPreviewView.shapeFrame(at: 100 + elapsed).path.fill()
            context.restoreGState()
        }
        return true
    }
    let morphPreviewBitmap = NSBitmapImageRep(data: morphPreview.tiffRepresentation!)!
    try morphPreviewBitmap.representation(using: .png, properties: [:])!
        .write(to: directory.appendingPathComponent("shape-morph.png"))
    print("PASS: all shape contours morph smoothly, retarget continuously, and settle on exact paths")
    pet.view.appearance = NSAppearance(named: .aqua)
    pet.setPalette(.blue)
    pet.setColorMode(.linear)
    pet.setEyeColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    pet.setMood("angry")
    pet.view.frame = NSRect(x: 0, y: 0, width: 108, height: 108)
    var shapeFrames = Set<Data>()
    for shape in PetShape.allCases {
        let path = pet.view.geometry.bodyPath(for: shape)
        precondition(path.elementCount > 2 && path.bounds.width > 40 && path.bounds.height > 40)
        pet.setShape(shape)
        let bitmap = pet.view.bitmapImageRepForCachingDisplay(in: pet.view.bounds)!
        pet.view.cacheDisplay(in: pet.view.bounds, to: bitmap)
        let data = bitmap.representation(using: .png, properties: [:])!
        shapeFrames.insert(data)
        try data.write(to: directory.appendingPathComponent("shape-\(shape.rawValue).png"))
    }
    precondition(shapeFrames.count == PetShape.allCases.count)
    let restoredAppearance = try PetController(defaults: defaults)
    precondition(restoredAppearance.view.shape == .whale && restoredAppearance.view.palette == .blue)
    precondition(restoredAppearance.view.colorMode == .linear && restoredAppearance.view.moodOverride == "angry")
    precondition(restoredAppearance.view.eyeColor?.usingColorSpace(.sRGB)?.redComponent == 1)
    restoredAppearance.hide()
    pet.setShape(.blob)
    pet.setAutomaticShape(true)
    precondition(pet.automaticShape && pet.view.shape == .pebble)
    pet.advanceAutoShape()
    precondition(pet.view.shape == .bean && defaults.bool(forKey: "petShapeAuto"))
    let restoredAutoShape = try PetController(defaults: defaults)
    precondition(restoredAutoShape.automaticShape && restoredAutoShape.view.shape == .bean)
    restoredAutoShape.hide()
    pet.setShape(.blob)
    precondition(!pet.automaticShape && !defaults.bool(forKey: "petShapeAuto"))
    pet.setPalette(.rainbow)
    pet.setColorMode(.solid)
    pet.setEyeColor(nil)
    pet.setMood(nil)
    print("PASS: 19 shape paths render distinctly / automatic shape cycles, persists, and yields to manual selection")
    pet.view.reduceMotion = true
    pet.view.isAwake = false
    let defaultRestBitmap = pet.view.bitmapImageRepForCachingDisplay(in: pet.view.bounds)!
    pet.view.cacheDisplay(in: pet.view.bounds, to: defaultRestBitmap)
    pet.setRestColor(NSColor(srgbRed: 0.15, green: 0.72, blue: 0.3, alpha: 1))
    precondition(pet.view.restPalette == .custom)
    let coloredRestBitmap = pet.view.bitmapImageRepForCachingDisplay(in: pet.view.bounds)!
    pet.view.cacheDisplay(in: pet.view.bounds, to: coloredRestBitmap)
    precondition(defaultRestBitmap.tiffRepresentation != coloredRestBitmap.tiffRepresentation)
    let savedRestColor = defaults.array(forKey: "petRestColor") as? [Double]
    precondition(savedRestColor?.count == 3 && abs(savedRestColor![1] - 0.72) < 0.001)
    let restoredRestColor = try PetController(defaults: defaults)
    precondition(abs(restoredRestColor.view.restColor!.usingColorSpace(.sRGB)!.greenComponent - 0.72) < 0.001)
    restoredRestColor.hide()
    pet.setRestColor(nil)
    precondition(pet.view.restColor == nil && pet.view.restPalette == nil && defaults.object(forKey: "petRestColor") == nil)
    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
        for mode in PetColorMode.allCases {
            let colors = PetPalette.black.inkColors(mode: mode, custom: .systemOrange)
            precondition(colors.allSatisfy { $0.usingColorSpace(.sRGB)!.redComponent < 0.36 },
                "Black ink must remain dark in Dark Mode")
        }
    }
    pet.setRestPalette(.whales)
    pet.setRestColorMode(.radial)
    precondition(pet.view.palette == .rainbow && pet.view.restPalette == .whales)
    let restoredRestEffect = try PetController(defaults: defaults)
    precondition(restoredRestEffect.view.restPalette == .whales && restoredRestEffect.view.restColorMode == .radial)
    restoredRestEffect.hide()
    let effectRestView = PetView(geometry: pet.view.geometry)
    effectRestView.frame = NSRect(x: 0, y: 0, width: 144, height: 144)
    effectRestView.palette = .blue
    effectRestView.restPalette = .whales
    effectRestView.reduceMotion = true
    let effectRestBitmap = effectRestView.bitmapImageRepForCachingDisplay(in: effectRestView.bounds)!
    effectRestView.cacheDisplay(in: effectRestView.bounds, to: effectRestBitmap)
    try effectRestBitmap.representation(using: .png, properties: [:])!
        .write(to: directory.appendingPathComponent("resting-whales.png"))
    effectRestView.restPalette = .green
    let inkRestBitmap = effectRestView.bitmapImageRepForCachingDisplay(in: effectRestView.bounds)!
    effectRestView.cacheDisplay(in: effectRestView.bounds, to: inkRestBitmap)
    precondition(effectRestBitmap.tiffRepresentation != inkRestBitmap.tiffRepresentation,
        "Resting effect and ink palettes must render differently while awake palette is unchanged")
    pet.setRestPalette(nil)
    pet.setRestColorMode(.solid)
    pet.view.isAwake = true
    print("PASS: resting ink and effect palettes render independently, persist, and reset")
    pet.view.reduceMotion = true
    pet.view.frame = NSRect(x: 0, y: 0, width: 144, height: 144)
    pet.setPalette(.rainbow)
    for shape in [PetShape.squircle, .dome, .tablet] {
        pet.setShape(shape)
        let bitmap = pet.view.bitmapImageRepForCachingDisplay(in: pet.view.bounds)!
        pet.view.cacheDisplay(in: pet.view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: directory.appendingPathComponent("effect-shape-\(shape.rawValue).png"))
        if shape == .squircle {
            let scale = (pet.view.bounds.width-pet.view.drawingPadding)/259
            let ratio = CGFloat(bitmap.pixelsWide)/pet.view.bounds.width
            let path = pet.view.geometry.bodyPath(for: shape)
            let corners = [(30.0,30.0),(198.0,30.0),(30.0,198.0),(198.0,198.0)]
            for (x,y) in corners where path.contains(NSPoint(x:x,y:y)) {
                let px = Int((pet.view.bounds.midX+(x-114.27)*scale)*ratio)
                let py = Int((pet.view.bounds.midY+(y-114.27)*scale)*ratio)
                let color = bitmap.colorAt(x:px,y:py)!.usingColorSpace(.sRGB)!
                precondition(color.alphaComponent > 0.9 && max(color.redComponent,color.greenComponent,color.blueComponent) > 0.08,
                    "A masked material left a black body corner at \(x),\(y)")
            }
        }
    }
    pet.setPalette(.stars)
    pet.setShape(.squircle)
    let starShape = pet.view.bitmapImageRepForCachingDisplay(in: pet.view.bounds)!
    pet.view.cacheDisplay(in: pet.view.bounds, to: starShape)
    try starShape.representation(using: .png, properties: [:])!
        .write(to: directory.appendingPathComponent("effect-shape-stars-squircle.png"))
    pet.setShape(.blob)
    pet.setPalette(.rainbow)
    pet.view.reduceMotion = false
    print("PASS: rainbow material covers squircle, dome, and tablet without circular holes")
    for (mood, name) in [(StatusPetIconMood.asleep, "asleep"), (.awake, "awake"), (.watching, "watching")] {
        let statusPreview = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 144, pixelsHigh: 144,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0)!
        statusPreview.size = NSSize(width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: statusPreview)
        let icon = makeStatusPetIcon(geometry: pet.view.geometry, mood: mood)
        precondition(icon.isTemplate)
        icon.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        NSGraphicsContext.restoreGraphicsState()
        try statusPreview.representation(using: .png, properties: [:])!
            .write(to: directory.appendingPathComponent("status-pet-\(name).png"))
        let nativePreview = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 18, pixelsHigh: 18,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: nativePreview)
        icon.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        NSGraphicsContext.restoreGraphicsState()
        let clearEyes = mood == .watching ? [5, 10] : [6, 11]
        for x in clearEyes { precondition(nativePreview.colorAt(x: x, y: 9)!.alphaComponent < 0.5) }
        precondition(nativePreview.colorAt(x: 9, y: 9)!.alphaComponent > 0.8)
        try nativePreview.representation(using: .png, properties: [:])!
            .write(to: directory.appendingPathComponent("status-pet-\(name)-18px.png"))
    }
    for palette in [PetPalette.stars, .neon, .neonFlow, .siri] {
        var previous: [UInt8]?
        var maximumDelta = 0.0
        var maximumLocalDelta = 0.0
        let phases: [Double] = palette == .stars ? [0,30,60,120,180,240] : [0]
        for frame in 0..<(8 * phases.count) {
            if frame % 8 == 0 { previous = nil }
            let image = ShaderMaterials.shared.image(for: palette, time: phases[frame / 8] + Double(frame % 8) / 15, pixelFootprint: 1 / 48)!
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 48 * 4, bitsPerPixel: 32)!
            let context = CGContext(data: bitmap.bitmapData, width: 48, height: 48, bitsPerComponent: 8,
                bytesPerRow: 48 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 48, height: 48))
            let bytes = Array(UnsafeBufferPointer(start: bitmap.bitmapData!, count: 48 * 48 * 4))
            if let previous {
                let delta = zip(bytes, previous).map { abs(Double($0) - Double($1)) / 255 }.reduce(0, +) / Double(bytes.count)
                maximumDelta = max(maximumDelta, delta)
                if palette == .stars {
                    // Whole-frame averaging can hide a flashing small star. Check local
                    // 8px patches, overlapping by half a patch, throughout the sampled cycle.
                    for y in stride(from:0,through:40,by:4) { for x in stride(from:0,through:40,by:4) {
                        var change = 0.0
                        for py in y..<(y+8) { for px in x..<(x+8) { for channel in 0..<3 {
                            let index = (py*48+px)*4+channel
                            change += abs(Double(bytes[index])-Double(previous[index])) / 255
                        }}}
                        maximumLocalDelta = max(maximumLocalDelta,change / (8*8*3))
                    }}
                }
            }
            previous = bytes
            if frame == 0 { try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("small-aa-\(palette.rawValue).png")) }
        }
        precondition(maximumDelta < 0.06, "Tiny material frames must not flash discontinuously")
        precondition(maximumLocalDelta < 0.18,"A local star/glass patch flashes discontinuously")
        print(String(format: "PASS: 48px %@ temporal change %.4f", palette.title, maximumDelta))
        if palette == .stars { print(String(format:"PASS: 48px star-ring six cycle phases / local patch change %.4f",maximumLocalDelta)) }
    }
    precondition(!BurstEffect(age: -1).isActive && !BurstEffect(age: 0.78).isActive)
    precondition(BurstEffect(age: 0.1).radius(for: 0) < BurstEffect(age: 0.4).radius(for: 0))
    for (index, age) in [0.08, 0.24, 0.48, 0.72].enumerated() {
        let effect = BurstEffect(age: age)
        let image = NSImage(size: NSSize(width: 400, height: 400), flipped: true) { _ in
            NSGraphicsContext.current!.cgContext.translateBy(x: 85, y: 85)
            effect.draw(enabled: true)
            return true
        }
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("burst-\(index).png"))
    }
    print("PASS: bounded burst lifetime / outward spark travel / native burst frames")
    for (name, time, appearance) in [("idle-light", 0.8, NSAppearance.Name.aqua),
                                     ("curious-light", 1.8, .aqua), ("happy-dark", 3.9, .darkAqua)] {
        pet.view.appearance = NSAppearance(named: appearance)
        pet.view.animationTime = time
        pet.view.frame = NSRect(x: 0, y: 0, width: 108, height: 108)
        let bitmap = pet.view.bitmapImageRepForCachingDisplay(in: pet.view.bounds)!
        pet.view.cacheDisplay(in: pet.view.bounds, to: bitmap)
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
    print("PASS: native light/dark animation frames rendered")
    for mood in pet.view.geometry.moods.keys.sorted() {
        pet.view.moodOverride = mood
        pet.view.animationTime = 0.8
        let bitmap = pet.view.bitmapImageRepForCachingDisplay(in: pet.view.bounds)!
        pet.view.cacheDisplay(in: pet.view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("mood-\(mood).png"))
    }
    pet.view.moodOverride = nil
    print("PASS: all mood previews rendered")
    for palette in PetPalette.selectable {
        let icon = makeApplicationIcon(geometry: pet.view.geometry, enabled: true, palette: palette, customColor: .systemPink)
        let bitmap = NSBitmapImageRep(data: icon.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("palette-\(palette.rawValue).png"))
    }
    pet.setCustomColor(.systemPink)
    precondition(pet.view.palette == .custom)
    let restoredPet = try PetController(defaults: defaults)
    precondition(restoredPet.view.palette == .custom)
    let restoredColor = restoredPet.view.customColor.usingColorSpace(.deviceRGB)!
    let savedColor = NSColor.systemPink.usingColorSpace(.deviceRGB)!
    precondition(abs(restoredColor.redComponent - savedColor.redComponent) < 0.001)
    restoredPet.hide()
    pet.setPalette(.rainbow)
    print("PASS: custom color persistence / special palette render previews")
    for palette in PetPalette.selectable {
        var frames: [Data] = []
        for time in [0.0, 6.0] {
            let image = NSImage(size: NSSize(width: 240, height: 240), flipped: true) { _ in
                let body = pet.view.geometry.bodyPath()
                NSColor.black.setFill()
                body.fill()
                if !palette.drawsBase { NSGradient(colors: palette.colors(custom: .systemPink))!.draw(in: body, angle: 45) }
                palette.drawDetails(in: body, time: time, opacity: 1)
                return true
            }
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            let data = bitmap.representation(using: .png, properties: [:])!
            frames.append(data)
            try data.write(to: directory.appendingPathComponent("effect-\(palette.rawValue)-\(Int(time)).png"))
        }
        precondition(frames[0] != frames[1], "Effect must animate its material, independently of the pet pose: \(palette)")
    }
    print("PASS: all \(PetPalette.selectable.count) material effects change over time independently of eye/body animation")
    let picker = PalettePickerController(pet: pet)
    _ = picker.view
    picker.view.layoutSubtreeIfNeeded()
    precondition(picker.view.subviews.first!.frame.maxX <= picker.view.bounds.maxX)
    precondition(picker.view.subviews.first!.frame.maxY <= picker.view.bounds.maxY)
    let palettePickerBitmap = picker.view.bitmapImageRepForCachingDisplay(in: picker.view.bounds)!
    picker.view.cacheDisplay(in: picker.view.bounds, to: palettePickerBitmap)
    try palettePickerBitmap.representation(using: .png, properties: [:])!
        .write(to: directory.appendingPathComponent("palette-picker.png"))
    picker.hexField.stringValue = "#2266CC"
    picker.hexField.sendAction(picker.hexField.action!, to: picker.hexField.target)
    precondition(pet.view.palette == .custom && picker.hexField.stringValue == "#2266CC")
    let picked = pet.view.customColor.usingColorSpace(.sRGB)!
    precondition(abs(picked.blueComponent - 0.8) < 0.001)
    picker.hueSlider.doubleValue = 0.3
    picker.hueSlider.sendAction(picker.hueSlider.action!, to: picker.hueSlider.target)
    precondition(abs(pet.view.customColor.usingColorSpace(.sRGB)!.hueComponent - 0.3) < 0.001)
    pet.setPalette(.rainbow)
    picker.refresh()
    print("PASS: attached picker hex input / hue selection / custom palette routing")

    let mouse = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 70, y: 30),
                                   modifierFlags: [], timestamp: 0, windowNumber: pet.panel.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
    pet.view.updateTrackingAreas()
    pet.view.mouseEntered(with: mouse)
    precondition(pet.view.isHovered && !pet.view.trackingAreas.isEmpty)
    pet.view.mouseExited(with: mouse)
    precondition(!pet.view.isHovered)
    let click = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: pet.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
    pet.view.mouseUp(with: click)
    precondition(pet.view.reactionAt != nil)
    print("PASS: hover tracking and click reaction routing")

    let remoteTestDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Vela-self-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: remoteTestDirectory) }
    let isolatedRemoteSettings = RemoteSettingsController(files: RemoteFiles(directory: remoteTestDirectory))
    let delegate = AppDelegate(defaults: defaults, remoteSettings: isolatedRemoteSettings)
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
    let languagePreference = UserDefaults.standard.object(forKey: Localization.preferenceKey)
    delegate.settings.show()
    delegate.settings.durationField.stringValue = "123"
    delegate.settings.idleField.stringValue = "17"
    delegate.watchSettings.agents.stringValue = "unsaved-agent"
    for language in VelaLanguage.allCases {
        Localization.setLanguage(language)
        precondition(delegate.settings.window.title == L("Vela Settings"))
        precondition(delegate.toggleItem.title == L("Turn on keep-awake"))
        precondition(delegate.settings.durationField.placeholderString == L("Custom"))
        if language == .simplifiedChinese { precondition(SettingsPage.allCases.allSatisfy { $0.title.count == 2 }) }
        precondition(delegate.pet.modeMenu.items[1].title == L("Allow display sleep, keep system running"))
        precondition(!delegate.power.isEnabled && delegate.duty.source == .off)
        precondition(delegate.settings.durationField.stringValue == "123" && delegate.settings.idleField.stringValue == "17")
        precondition(delegate.watchSettings.agents.stringValue == "unsaved-agent")
        delegate.settings.window.contentView?.layoutSubtreeIfNeeded()

    }
    UserDefaults.standard.set(languagePreference, forKey: Localization.preferenceKey)
    NotificationCenter.default.post(name: Localization.didChange, object: nil)
    delegate.settings.refresh()
    delegate.settings.window.orderOut(nil)
    print("PASS: native language switching preserves keep-awake state and updates settings, menus, and placeholders")
    let lidMenu = delegate.watchModeItem.submenu!.items.first {
        $0.representedObject as? String == KeepAwakeMode.lid.rawValue
    }!
    precondition(lidMenu.isEnabled)
    precondition(delegate.watchSettings.view.window === delegate.settings.window)
    precondition(delegate.pet.modeMenu.items.count == 3)
    precondition(delegate.pet.modeMenu.items.allSatisfy {
        $0.image?.size == NSSize(width: 18, height: 18) && $0.image?.isTemplate == false
    })
    let modeWidth = delegate.pet.modePopover.contentSize.width
    precondition(modeWidth >= 250)
    let modeSurface = delegate.pet.modePopover.contentViewController!.view as! NSGlassEffectView
    precondition(modeSurface.style == .regular && modeSurface.cornerRadius == 22)
    let modeContents = modeSurface.contentView!.subviews
    let modeLabels = modeContents.compactMap { $0 as? NSTextField }
    let modeIcons = modeContents
        .compactMap { $0 as? NSImageView }.filter { $0.frame.minX == 31 }
    precondition(modeLabels.count == 3 && modeLabels[1].stringValue == L("Allow display sleep, keep system running"))
    precondition(modeIcons.count == 3 && zip(modeIcons, modeLabels).allSatisfy { pair in
        pair.0.frame.midY == pair.1.frame.midY && pair.1.frame.minX - pair.0.frame.maxX == 3
    })
    precondition(modeLabels.allSatisfy { $0.frame.maxX <= modeWidth && $0.font?.pointSize == 13 })
    precondition((modeLabels[1].stringValue as NSString)
        .size(withAttributes: [.font: modeLabels[1].font!]).width < modeLabels[1].frame.width - 4)
    delegate.pet.modeMenu.performActionForItem(at: 1)
    precondition(delegate.keepAwakeMode == .system && delegate.duty.source == .off && !delegate.power.isEnabled)
    precondition(delegate.pet.modeMenu.items[1].state == .on && delegate.settings.watchMode == .system)
    delegate.pet.powerButton.performClick(nil)
    precondition(delegate.duty.source == .manual && delegate.power.mode == .system && delegate.power.isActuallyHeld())
    delegate.pet.modeMenu.performActionForItem(at: 0)
    precondition(delegate.keepAwakeMode == .display && delegate.power.mode == .display)
    delegate.pet.powerButton.performClick(nil)
    precondition(delegate.duty.source == .off && !delegate.power.isEnabled)
    delegate.settings.watchModeButton.selectItem(withTitle: L("Allow display sleep, keep system running"))
    delegate.settings.watchModeChanged()
    precondition(delegate.keepAwakeMode == .system && delegate.settings.watchMode == .system)
    precondition(defaults.string(forKey: AppDelegate.keepAwakeModeKey) == KeepAwakeMode.system.rawValue)
    precondition(AppDelegate(defaults: defaults).keepAwakeMode == .system)
    delegate.toggleAgentWatch()
    precondition(delegate.keepAwakeMode == .system && delegate.settings.watchMode == .system)
    delegate.toggleAgentWatch()
    delegate.watchModeItem.submenu!.performActionForItem(at: 2)
    precondition(delegate.keepAwakeMode == .lid && delegate.settings.watchMode == .lid)
    precondition(AppDelegate(defaults: defaults).keepAwakeMode == .lid)
    delegate.watchModeItem.submenu!.performActionForItem(at: 0)
    precondition(delegate.keepAwakeMode == .display && delegate.settings.watchMode == .display)
    precondition(AppDelegate(defaults: defaults).keepAwakeMode == .display)
    delegate.watchSettings.grace.selectItem(withTitle: L("2 minutes"))
    delegate.watchSettings.activity.selectItem(withTitle: AgentActivityMode.presence.title)
    delegate.watchSettings.battery.selectItem(withTitle: "30%")
    delegate.watchSettings.agents.stringValue = "goose, amp"
    delegate.watchSettings.changed()
    precondition(delegate.duty.graceSeconds == 120 && delegate.duty.batteryFloor == 30)
    precondition(WatchSettingsController.customAgents(from: defaults) == ["amp", "goose"])
    precondition(WatchSettingsController.activityMode(from: defaults) == .presence)
    delegate.watchSettings.grace.selectItem(withTitle: L("5 minutes"))
    delegate.watchSettings.activity.selectItem(withTitle: AgentActivityMode.working.title)
    delegate.watchSettings.battery.selectItem(withTitle: "20%")
    delegate.watchSettings.agents.stringValue = ""
    delegate.watchSettings.changed()
    precondition(WatchSettingsController.activityMode(from: defaults) == .working)
    delegate.activityModeItem.submenu!.performActionForItem(at: 1)
    precondition(WatchSettingsController.activityMode(from: defaults) == .presence)
    precondition(delegate.watchSettings.activity.titleOfSelectedItem == AgentActivityMode.presence.title)
    delegate.activityModeItem.submenu!.performActionForItem(at: 0)
    precondition(WatchSettingsController.activityMode(from: defaults) == .working)
    print("PASS: settings/menu modes synchronize and persist across Agent switching and relaunch")
    precondition(!delegate.power.isEnabled && delegate.pet.panel.isVisible)
    precondition(delegate.wakeDuration == .unlimited && delegate.status.button?.title == "")
    delegate.setWakeDuration(.minutes(1))
    precondition(WakeDuration.load(from: defaults) == .minutes(1))
    delegate.toggle()
    precondition(delegate.power.isEnabled && delegate.wakeDeadline == nil)
    precondition(delegate.status.button!.title == "")
    let waitingIcon = delegate.status.button!.image!
    delegate.setIdleThreshold(IdleThreshold(minutes: 0))
    let firstDeadline = delegate.wakeDeadline!
    let timedAssertion = delegate.power.assertion!
    precondition(delegate.status.button!.title.contains(":"))
    precondition(delegate.status.button!.image !== waitingIcon)
    delegate.setWakeDuration(.minutes(2))
    precondition(delegate.wakeDeadline! > firstDeadline && WakeDuration.load(from: defaults) == .minutes(2))
    let freshLaunch = AppDelegate(defaults: defaults)
    precondition(freshLaunch.wakeDuration == .minutes(2) && !freshLaunch.power.isEnabled && freshLaunch.wakeDeadline == nil)
    delegate.refreshWakeCountdown(now: delegate.wakeDeadline!.addingTimeInterval(1),
                                  uptime: delegate.idleTimer.countdownStartedAt! + 121)
    precondition(!delegate.power.isEnabled && delegate.wakeDeadline == nil)
    precondition(IOPMAssertionCopyProperties(timedAssertion) == nil)
    precondition(delegate.status.button!.title == "" && delegate.toggleItem.state == .off && !delegate.pet.view.isAwake)
    delegate.setWakeDuration(.unlimited)
    delegate.setIdleThreshold(.defaultValue)
    precondition(WakeDuration.load(from: defaults) == .unlimited)
    delegate.setWakeDuration(.minutes(31))
    let resumedDeadline = Date().addingTimeInterval(45)
    delegate.resumeKeepAwake(until: resumedDeadline)
    precondition(delegate.power.isEnabled && abs(delegate.wakeDeadline!.timeIntervalSince(resumedDeadline)) < 0.1)
    delegate.toggle()
    delegate.setWakeDuration(.unlimited)
    print("PASS: timed assertion reset/expiry/release and menu bar countdown")
    let offIcon = NSBitmapImageRep(data: NSApp.applicationIconImage.tiffRepresentation!)!
    precondition(delegate.pet.panel.isVisible && !delegate.power.isEnabled)
    delegate.status.menu!.performActionForItem(at: 0)
    precondition(delegate.power.isEnabled && delegate.pet.panel.isVisible)
    dispatchNativeEvents(for:0.20)
    let liveWindowVisible = delegate.pet.panel.occlusionState.contains(.visible)
    let readbacks = ShaderMaterials.shared.snapshotReadbacks
    delegate.pet.view.display()
    if liveWindowVisible {
        precondition(delegate.pet.materialSurface.submittedFrames > 0)
        precondition(delegate.pet.materialSurface.drawableSize.width >= delegate.pet.materialSurface.bounds.width * delegate.pet.panel.backingScaleFactor * 2)
        precondition(!delegate.pet.materialSurface.isHidden)
        precondition(ShaderMaterials.shared.snapshotReadbacks == readbacks, "Desktop animation must not convert GPU frames to images")
        print("PASS: live Metal drawable presentation / no desktop bitmap readback")
    } else {
        fputs("INCONCLUSIVE: WindowServer reports pet window occluded; live drawable checks need a visible desktop\n", stderr)
    }
    delegate.pet.view.reduceMotion = true
    delegate.pet.setRestPalette(.whales)
    delegate.toggle()
    let restReadbacks = ShaderMaterials.shared.snapshotReadbacks
    let restFrames = delegate.pet.materialSurface.submittedFrames
    delegate.pet.view.display()
    delegate.pet.materialSurface.draw()
    if liveWindowVisible {
        precondition(!delegate.pet.materialSurface.isHidden &&
            delegate.pet.materialSurface.submittedFrames > restFrames &&
            ShaderMaterials.shared.snapshotReadbacks == restReadbacks,
            "Resting shader must use the live GPU surface")
    }
    delegate.pet.setRestPalette(nil)
    delegate.toggle()
    delegate.pet.view.reduceMotion = false
    dispatchNativeEvents(for: 0.20)
    if liveWindowVisible { print("PASS: resting effect uses live GPU presentation") }
    if liveWindowVisible {
    let coverFrame = delegate.pet.panel.frame.insetBy(dx:-4,dy:-4)
    let cover = Process()
    cover.executableURL = Bundle.main.executableURL!
    cover.arguments = ["--occlusion-cover",String(Double(coverFrame.minX)),String(Double(coverFrame.minY)),
        String(Double(coverFrame.width)),String(Double(coverFrame.height)),String(delegate.pet.panel.level.rawValue+1)]
    try cover.run()
    defer { if cover.isRunning { cover.terminate() } }
    dispatchNativeEvents(for:0.75)
    fputs("NATIVE COVER separateProcess=\(cover.isRunning) targetOcclusion=\(delegate.pet.panel.occlusionState.rawValue)\n",stderr)
    if delegate.pet.panel.occlusionState.contains(.visible) {
        fputs("INCONCLUSIVE: native separate-process covering window did not change the pet's occlusion state; physical covered-window GPU stop is not verified\n",stderr)
        if cover.isRunning { cover.terminate();cover.waitUntilExit() }
        dispatchNativeEvents(for:0.20)
    } else {
        let occludedFrames = delegate.pet.materialSurface.submittedFrames
        delegate.pet.materialSurface.draw()
        dispatchNativeEvents(for:0.12)
        precondition(delegate.pet.materialSurface.submittedFrames == occludedFrames,
            "Actual native occlusion must stop direct and timer-driven GPU submissions")
        if cover.isRunning { cover.terminate();cover.waitUntilExit() }
        dispatchNativeEvents(for:0.20)
        precondition(delegate.pet.panel.occlusionState.contains(.visible))
        delegate.pet.view.display();delegate.pet.materialSurface.draw()
        precondition(delegate.pet.materialSurface.submittedFrames>occludedFrames,
            "GPU presentation must resume after the covering window is removed")
        print("PASS: real opaque-window occlusion stops GPU submissions / uncover resumes live rendering")
    }
    }
    let onIcon = NSBitmapImageRep(data: NSApp.applicationIconImage.tiffRepresentation!)!
    let offColor = offIcon.colorAt(x: offIcon.pixelsWide / 2, y: offIcon.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
    precondition(abs(offColor.redComponent - offColor.blueComponent) < 0.03)
    // Sample the lower body, avoiding animated eyes and pale gradient crossings.
    let saturation = [0.4, 0.5, 0.6].map { fraction in
        let sample = onIcon.colorAt(x: Int(Double(onIcon.pixelsWide) * fraction), y: Int(Double(onIcon.pixelsHigh) * 0.65))!.usingColorSpace(.deviceRGB)!
        let channels = [sample.redComponent, sample.greenComponent, sample.blueComponent]
        return channels.max()! - channels.min()!
    }.max()!
    precondition(saturation > 0.2)
    precondition(delegate.status.button!.image!.isTemplate)
    try onIcon.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("app-icon-on.png"))
    try offIcon.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("app-icon-off.png"))
    precondition(delegate.toggleItem.title == L("Turn off keep-awake") && delegate.toggleItem.state == .on)
    delegate.status.menu!.performActionForItem(at: 0)
    precondition(!delegate.power.isEnabled && delegate.pet.panel.isVisible)
    precondition(delegate.status.button!.image!.isTemplate)
    print("PASS: application icon color follows wake state / menu bar pet remains a readable template")
    let savedPalette = delegate.pet.view.palette
    delegate.pet.setPalette(.stars)
    let savedPetSize = delegate.pet.petSize
    var liveFootprints: [Float] = []
    for size: CGFloat in [24,48,96,256,512] {
        delegate.pet.resize(to:size)
        delegate.pet.view.display()
        let footprint = delegate.pet.materialSurface.parameters.padding
        precondition(footprint.isFinite && footprint>0,"Live thin reflections must use the final display pixel footprint")
        liveFootprints.append(footprint)
    }
    precondition(zip(liveFootprints, liveFootprints.dropFirst()).allSatisfy { pair in pair.0 > pair.1 })
    delegate.pet.resize(to:savedPetSize)
    print("PASS: 24/48/96/256/512-point live star-ring filtering follows final display pixels")
    let starFrames = ShaderMaterials.shared.starRenderer!.liveFrames
    let starReadbacks = ShaderMaterials.shared.snapshotReadbacks
    let starSnapshots = ShaderMaterials.shared.starRenderer!.snapshots
    delegate.pet.view.display()
    if liveWindowVisible {
        precondition(ShaderMaterials.shared.starRenderer!.liveFrames > starFrames)
        precondition(ShaderMaterials.shared.snapshotReadbacks == starReadbacks, "HDR desktop rendering must stay on the GPU")
        precondition(ShaderMaterials.shared.starRenderer!.snapshots == starSnapshots)
    }
    precondition(ShaderMaterials.shared.starRenderer!.geometryVertexCount < 16000)
    precondition(ShaderMaterials.shared.starRenderer!.staticGeometryBuilds == 1,
        "Live frames must reuse static paths and reflections")
    precondition(ShaderMaterials.shared.starRenderer!.geometryBufferAllocations == 4,
        "Live frames must reuse the fixed vertex-buffer pool")
    delegate.pet.hide()
    let hiddenFrames = ShaderMaterials.shared.starRenderer!.liveFrames
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    if liveWindowVisible {
        precondition(ShaderMaterials.shared.starRenderer!.liveFrames == hiddenFrames, "Hidden pets must stop HDR rendering")
    }
    delegate.pet.show()
    delegate.pet.setPalette(savedPalette)
    if liveWindowVisible {
        print("PASS: live HDR glass/curves/bloom/composite / bounded geometry (\(ShaderMaterials.shared.starRenderer!.geometryVertexCount) vertices) / hidden rendering stops")
    } else {
        print("PASS: bounded HDR geometry (\(ShaderMaterials.shared.starRenderer!.geometryVertexCount) vertices)")
    }
    precondition(delegate.toggleItem.title == L("Turn on keep-awake") && delegate.toggleItem.state == .off)
    precondition(delegate.pet.view.menu?.items.count == 4)
    precondition(!delegate.status.menu!.items.contains { $0.title.contains(L("Move to bottom right")) || $0.title.contains("Reset") })
    precondition(!delegate.pet.view.menu!.items.contains { $0.title.contains(L("Move to bottom right")) || $0.title.contains("Reset") })
    let expressionMenu = delegate.pet.view.menu!.items[2].submenu!
    expressionMenu.performActionForItem(at: 3)
    precondition(delegate.pet.view.moodOverride == "curious")
    expressionMenu.performActionForItem(at: 0)
    precondition(delegate.pet.view.moodOverride == nil)
    print("PASS: native menu toggle/pet visibility/menu state/lifecycle cleanup")
    precondition(delegate.pet.controls.isHidden)
    delegate.pet.container.stopMonitoring()
    delegate.pet.container.setControlsVisible(true)
    precondition(!delegate.pet.controls.isHidden && delegate.pet.container.controlsVisible)
    let helpEvent = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: delegate.pet.panel.windowNumber, context: nil,
        eventNumber: 0, clickCount: 0, pressure: 0)!
    for button in [delegate.pet.powerButton, delegate.pet.modeButton, delegate.pet.agentButton, delegate.pet.settingsButton] {
        precondition(!button.helpText.isEmpty && button.toolTip == nil)
    }
    let displayIcon = delegate.pet.modeButton.image!
    delegate.pet.setKeepAwakeMode(.system)
    let systemIcon = delegate.pet.modeButton.image!
    delegate.pet.setKeepAwakeMode(.lid)
    let lidIcon = delegate.pet.modeButton.image!
    delegate.pet.setKeepAwakeMode(.display)
    precondition(displayIcon !== systemIcon && systemIcon !== lidIcon && displayIcon !== lidIcon)
    precondition(delegate.pet.powerButton.image?.size == NSSize(width: 24, height: 24))
    precondition(delegate.pet.modeButton.image?.size == NSSize(width: 24, height: 24))
    precondition(delegate.pet.agentButton.image?.size == NSSize(width: 24, height: 24))
    precondition(delegate.pet.settingsButton.image?.size == NSSize(width: 24, height: 24))
    precondition(delegate.pet.powerButton.image?.isTemplate == true &&
                 delegate.pet.agentButton.image?.isTemplate == true &&
                 delegate.pet.modeButton.image?.isTemplate == false &&
                 delegate.pet.settingsButton.image?.isTemplate == false)
    let inactivePowerIcon = delegate.pet.powerButton.image!
    let inactiveAgentIcon = delegate.pet.agentButton.image!
    let icons = [delegate.pet.powerButton.image!, delegate.pet.agentButton.image!,
                 displayIcon, systemIcon, lidIcon, delegate.pet.settingsButton.image!]
    if let path = ProcessInfo.processInfo.environment["VELA_CONTROL_ICON_PREVIEW"] {
        try exportControlIconPreview(icons, to: path)
    }
    let ink = icons
        .map(iconInkSize)
    precondition(ink.allSatisfy { $0.width >= 15 && $0.width <= 23 &&
                                     $0.height >= 14 && $0.height <= 22 })
    let inkAreas = ink.map { $0.width * $0.height }
    precondition(inkAreas.max()! / inkAreas.min()! <= 1.1)
    print("PASS: six approved control icons preserve shape and balance visible area")
    delegate.pet.powerButton.mouseEntered(with: helpEvent)
    precondition(delegate.pet.powerButton.helpIsPending && !delegate.pet.powerButton.helpIsVisible)
    RunLoop.current.run(until: Date().addingTimeInterval(2.9))
    precondition(!delegate.pet.powerButton.helpIsVisible)
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    precondition(delegate.pet.powerButton.helpIsVisible)
    delegate.pet.powerButton.mouseExited(with: helpEvent)
    precondition(!delegate.pet.powerButton.helpIsPending && !delegate.pet.powerButton.helpIsVisible)
    delegate.pet.agentButton.mouseEntered(with: helpEvent)
    delegate.pet.agentButton.mouseExited(with: helpEvent)
    precondition(!delegate.pet.agentButton.helpIsPending && !delegate.pet.agentButton.helpIsVisible)
    delegate.pet.container.startMonitoring()
    print("PASS: pet controls show delayed help after 3 seconds and use a robot Agent icon")
    delegate.pet.powerButton.performClick(nil)
    precondition(delegate.power.isEnabled && delegate.pet.powerButton.state == .on)
    precondition(delegate.pet.powerButton.image?.isTemplate == false &&
                 delegate.pet.powerButton.image !== inactivePowerIcon)
    precondition(delegate.pet.powerButton.contentTintColor == .controlAccentColor)
    precondition(NSColor(cgColor: delegate.pet.powerButton.layer!.backgroundColor!)!.alphaComponent > 0.2)
    precondition(delegate.toggleItem.state == .on && delegate.pet.view.isAwake)
    let buttonAssertion = delegate.power.assertion!
    delegate.pet.powerButton.performClick(nil)
    precondition(!delegate.power.isEnabled && delegate.pet.powerButton.state == .off)
    precondition(delegate.pet.powerButton.image === inactivePowerIcon &&
                 delegate.pet.powerButton.contentTintColor == .secondaryLabelColor)
    precondition(NSColor(cgColor: delegate.pet.powerButton.layer!.backgroundColor!)!.alphaComponent == 0)
    precondition(delegate.toggleItem.state == .off && !delegate.pet.view.isAwake)
    precondition(delegate.pet.panel.isVisible && IOPMAssertionCopyProperties(buttonAssertion) == nil)
    delegate.pet.container.setControlsVisible(false)
    precondition(delegate.pet.controls.isHidden && delegate.pet.panel.isVisible)
    // Exercise pointer transitions independently of real Space-change notifications.
    let region = HoverPetContainer(frame: delegate.pet.container.bounds)
    region.pet = delegate.pet.view
    region.controls = NSView(frame: .zero)
    let inside = NSPoint(x: delegate.pet.view.frame.midX, y: delegate.pet.view.frame.midY)
    region.refreshHover(point: inside, now: 0, visible: true)
    precondition(region.controlsVisible)
    let outside = NSPoint(x: -100, y: -100)
    region.refreshHover(point: outside, now: 1, visible: true)
    precondition(region.controlsVisible)
    region.refreshHover(point: outside, now: 1.3, visible: true)
    precondition(!region.controlsVisible, "Pointer polling must dismiss even without mouseExited")
    region.setControlsVisible(true)
    region.dismissForContextChange()
    precondition(!region.controlsVisible)
    region.refreshHover(point: inside, now: 2, visible: true)
    precondition(!region.controlsVisible, "Space changes must wait for pointer movement before reopening")
    print("PASS: pet power button/assertion release/menu synchronization/off-state visibility")

    var event: EventRef?
    precondition(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                             GetCurrentEventTime(), 0, &event) == noErr)
    defer { ReleaseEvent(event!) }
    var key = EventHotKeyID(signature: 0x41575054, id: 1)
    precondition(SetEventParameter(event!, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &key) == noErr)
    delegate.hotKey.suspended = true
    precondition(SendEventToEventTarget(event!, GetApplicationEventTarget()) == noErr)
    precondition(!delegate.power.isEnabled, "Recording must suppress toggles")
    delegate.hotKey.suspended = false
    precondition(SendEventToEventTarget(event!, GetApplicationEventTarget()) == noErr)
    precondition(delegate.power.isEnabled && delegate.pet.panel.isVisible)
    precondition(SendEventToEventTarget(event!, GetApplicationEventTarget()) == noErr)
    precondition(!delegate.power.isEnabled && delegate.pet.panel.isVisible)
    print("PASS: Carbon hotkey event delivery/recording suppression/toggle")
    precondition(!delegate.status.menu!.items.contains { $0.title.contains(L("Shortcut")) || $0.title.contains(L("Watch diagnostics")) })
    delegate.showSettings()
    delegate.settings.shortcutButton.performClick(nil)
    precondition(delegate.settings.window.isVisible && delegate.settings.shortcutButton.title == L("Press a shortcut…"))
    precondition(delegate.hotKey.suspended)
    delegate.settings.window.close()
    precondition(!delegate.hotKey.suspended)
    print("PASS: shortcut recorder remains available in settings; menu omits shortcut and diagnostics")
    delegate.pet.agentButton.performClick(nil)
    precondition(delegate.duty.source == .agent && delegate.pet.agentButton.state == .on &&
                 delegate.pet.agentButton.image != nil)
    precondition(delegate.pet.agentButton.image?.isTemplate == false &&
                 delegate.pet.agentButton.image !== inactiveAgentIcon)
    precondition(delegate.pet.agentButton.contentTintColor == .controlAccentColor)
    precondition(NSColor(cgColor: delegate.pet.agentButton.layer!.backgroundColor!)!.alphaComponent > 0.2)
    delegate.pet.agentButton.performClick(nil)
    precondition(delegate.duty.source == .off && delegate.pet.agentButton.state == .off)
    precondition(delegate.pet.agentButton.image === inactiveAgentIcon &&
                 delegate.pet.agentButton.contentTintColor == .secondaryLabelColor)
    print("PASS: pet Agent button toggles automatic watch and reflects its state")
    try delegate.power.enable()
    let beforeClose = delegate.power.assertion!
    delegate.pet.view.menu!.performActionForItem(at: 3)
    precondition(!delegate.pet.panel.isVisible && delegate.power.assertion == beforeClose)
    precondition(delegate.petDisplayItem.title == L("Show companion"))
    precondition(SendEventToEventTarget(event!, GetApplicationEventTarget()) == noErr)
    precondition(!delegate.pet.panel.isVisible && !delegate.power.isEnabled, "Hotkey must not reopen the pet")
    delegate.status.menu!.performActionForItem(at: 1)
    precondition(delegate.pet.panel.isVisible && !delegate.power.isEnabled)
    print("PASS: pet close preserves power state / hotkey stays hidden / menu-only reopen")
    let login = TestLoginItem()
    let visualWatchSettings = WatchSettingsController(defaults: defaults)
    let settings = SettingsController(hotKey: delegate.hotKey, pet: delegate.pet,
                                      watchSettings: visualWatchSettings, loginItem: login, appearanceDefaults: defaults)
    precondition(settings.navigationController.splitViewItems.first?.behavior == .sidebar)
    precondition(settings.navigationController.pages.count == 5 && settings.window.styleMask.contains(.resizable))
    precondition(settings.navigationController.pages.values.allSatisfy { $0.scroll.documentView?.isFlipped == true })
    precondition(settings.watchModeButton.itemTitles.count == 3)
    precondition(settings.watchModeButton.window === settings.window)
    precondition(settings.colorStyleButton.alignment == .right)
    let restingPickerPreview = PalettePickerController(pet: delegate.pet, target: .resting)
    restingPickerPreview.view.layoutSubtreeIfNeeded()
    precondition(restingPickerPreview.view.subviews.first!.frame.minY >= 0,
        "Resting palette controls must fit in their popover")
    func backgroundBrightness(_ view: NSView) -> CGFloat {
        NSColor(cgColor: view.layer!.backgroundColor!)!.usingColorSpace(.sRGB)!.brightnessComponent
    }
    let lightAppearance = NSAppearance(named: .aqua)!
    let darkAppearance = NSAppearance(named: .darkAqua)!
    restingPickerPreview.view.appearance = lightAppearance
    precondition(backgroundBrightness(restingPickerPreview.view) > 0.7)
    restingPickerPreview.view.appearance = darkAppearance
    precondition(backgroundBrightness(restingPickerPreview.view) < 0.5)
    restingPickerPreview.view.appearance = lightAppearance
    precondition(backgroundBrightness(restingPickerPreview.view) > 0.7,
        "The palette popover background must follow its appearance")
    let restingPickerBitmap = restingPickerPreview.view.bitmapImageRepForCachingDisplay(in: restingPickerPreview.view.bounds)!
    restingPickerPreview.view.cacheDisplay(in: restingPickerPreview.view.bounds, to: restingPickerBitmap)
    try restingPickerBitmap.representation(using: .png, properties: [:])!
        .write(to: directory.appendingPathComponent("resting-palette-picker.png"))
    let shapePickerPreview = settings.appearancePopover(
        items: [(L("Automatic"), delegate.pet.view.shape, nil)] +
            PetShape.allCases.map { ($0.title, $0, String?.none) }, shapePicker: true)
    shapePickerPreview.view.appearance = lightAppearance
    precondition(backgroundBrightness(shapePickerPreview.view) > 0.7)
    shapePickerPreview.view.appearance = darkAppearance
    precondition(backgroundBrightness(shapePickerPreview.view) < 0.5)
    shapePickerPreview.view.appearance = lightAppearance
    precondition(backgroundBrightness(shapePickerPreview.view) > 0.7,
        "The shape popover background must follow its appearance")
    shapePickerPreview.view.layoutSubtreeIfNeeded()
    let shapePickerBitmap = shapePickerPreview.view.bitmapImageRepForCachingDisplay(in: shapePickerPreview.view.bounds)!
    shapePickerPreview.view.cacheDisplay(in: shapePickerPreview.view.bounds, to: shapePickerBitmap)
    try shapePickerBitmap.representation(using: .png, properties: [:])!
        .write(to: directory.appendingPathComponent("shape-picker.png"))
    settings.window.contentView!.layoutSubtreeIfNeeded()
    let navigation = settings.navigationController!
    let pageControls: [SettingsPage: [NSView]] = [
        .general: [settings.languagePicker, settings.loginButton, settings.shortcutButton, settings.resetButton],
        .keepAwake: [settings.durationBar, settings.durationField, settings.idleField, settings.watchModeButton],
        .agent: [visualWatchSettings.grace, visualWatchSettings.activity, visualWatchSettings.battery, visualWatchSettings.agents],
        .appearance: [settings.appearancePicker.view, settings.sizeBar, settings.shapeButton, settings.moodButton, settings.paletteButton, settings.restPaletteButton]
    ]
    for appearanceName: NSAppearance.Name in [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
        settings.window.appearance = NSAppearance(named: appearanceName)
        for size in [NSSize(width: 740, height: 540), NSSize(width: 800, height: 620), NSSize(width: 860, height: 650)] {
            settings.window.setContentSize(size)
            for page in SettingsPage.allCases {
                navigation.select(page)
                settings.window.contentView!.layoutSubtreeIfNeeded()
                let content = navigation.pages[page]!
                let document = content.scroll.documentView!
                precondition(!content.view.isHidden && document.frame.width > 400)
                for control in pageControls[page] ?? [] {
                    let frame = control.convert(control.bounds, to: document)
                    precondition(frame.width > 0 && frame.minX >= 0 && frame.maxX <= document.bounds.width + 1,
                                 "Settings control escapes its page: \(page.rawValue)")
                }
            }
        }
    }
    settings.window.appearance = nil
    settings.window.setContentSize(NSSize(width: 860, height: 650))
    settings.window.contentView!.layoutSubtreeIfNeeded()
    let sidebarWidth = navigation.splitViewItems[0].viewController.view.frame.width
    precondition(sidebarWidth >= 164 && sidebarWidth <= 184, "Settings sidebar must remain compact")
    precondition(AppAppearance.load(from: defaults) == .automatic)
    for (index, mode) in AppAppearance.allCases.enumerated() {
        settings.appearancePicker.buttons[index].performClick(nil)
        precondition(AppAppearance.load(from: defaults) == mode)
        let restored = AppearancePreferencesController(defaults: defaults)
        precondition(restored.buttons[index].state == .on && restored.buttons.filter { $0.state == .on }.count == 1)
        switch mode {
        case .light: precondition(NSApp.appearance?.name == .aqua)
        case .dark: precondition(NSApp.appearance?.name == .darkAqua)
        case .automatic: precondition(NSApp.appearance == nil)
        }
    }
    let themeArrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: settings.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: 124)!
    settings.appearancePicker.buttons[0].keyDown(with: themeArrow)
    precondition(AppAppearance.load(from: defaults) == .dark)
    settings.appearancePicker.reset()
    precondition(defaults.object(forKey: AppAppearance.preferenceKey) == nil && NSApp.appearance == nil)
    print("PASS: light/dark/automatic app appearance applies immediately, persists, supports keyboard selection, and resets")
    precondition(settings.window.makeFirstResponder(navigation.sidebarTable))
    navigation.select(.appearance)
    precondition(settings.window.firstResponder === navigation.sidebarTable,
                 "Category navigation must retain keyboard focus in the sidebar")
    navigation.select(.general); navigation.select(.appearance)
    navigation.back(); precondition(navigation.selectedPage == .general)
    navigation.forward(); precondition(navigation.selectedPage == .appearance)
    navigation.navigation.configure(reduceTransparency: true)
    precondition(navigation.navigation.usesOpaqueBackground && navigation.navigation.glass.isHidden)
    navigation.navigation.configure(reduceTransparency: false)
    precondition(!navigation.navigation.usesOpaqueBackground && !navigation.navigation.glass.isHidden)
    navigation.select(.keepAwake)
    print("PASS: native settings sidebar, five compact pages, history, light/dark/high-contrast layouts, and opaque accessibility fallback")
    precondition(settings.window.contentView!.subviews.first!.frame.minY >= 0)
    precondition(settings.resetButton.window === settings.window)
    precondition(settings.watchModeButton.window === settings.window)
    precondition(settings.restPaletteButton.window === settings.window && settings.restPaletteButton.title.contains(L("Default")))
    let settingsSnapshot = settings.window.contentView!.bitmapImageRepForCachingDisplay(in: settings.window.contentView!.bounds)!
    settings.window.contentView!.cacheDisplay(in: settings.window.contentView!.bounds, to: settingsSnapshot)
    try settingsSnapshot.representation(using: .png, properties: [:])!
        .write(to: directory.appendingPathComponent("settings-idle-countdown.png"))
    precondition(settings.idleField.stringValue == "4")
    settings.onIdleThreshold = { delegate.setIdleThreshold($0) }
    settings.idleField.stringValue = "7"
    settings.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification,
                                                   object: settings.idleField))
    precondition(delegate.idleThreshold.minutes == 7 && IdleThreshold.load(from: defaults).minutes == 7)
    precondition(settings.durationBar.frame.width >= 290)
    precondition(settings.durationBar.duration(at: 0.29) == .minutes(60))
    precondition(settings.durationBar.duration(at: 0.54) == .minutes(720))
    precondition(settings.durationBar.duration(at: 0.92) == .minutes(10080))
    precondition(settings.durationBar.duration(at: 1) == .unlimited)
    precondition(settings.durationBar.position(for: .minutes(10080)) - settings.durationBar.position(for: .minutes(720)) >= 0.35)
    let nativeDuration = DurationProgressBar()
    var chosenDuration: WakeDuration?
    nativeDuration.onChange = { chosenDuration = $0 }
    nativeDuration.native.slider.doubleValue = 0.54
    nativeDuration.native.slider.sendAction(nativeDuration.native.slider.action!, to: nativeDuration.native.slider.target)
    precondition(chosenDuration == .minutes(720) && nativeDuration.duration == .minutes(720))
    precondition(nativeDuration.accessibilityChildren()?.first as? NSSlider === nativeDuration.native.slider)
    print("PASS: nonlinear duration bar has 1-hour, 12-hour, 7-day and unlimited stops")
    precondition(settings.sizeBar.frame.width >= 290)
    precondition(settings.sizeBar.size(at: 0) == 24)
    precondition(settings.sizeBar.size(at: 0.5) == 96)
    precondition(settings.sizeBar.size(at: 0.75) == 256)
    precondition(settings.sizeBar.size(at: 1) == 512)
    precondition(settings.sizeBar.position(for: 96) == 0.5 && settings.sizeBar.position(for: 256) == 0.75)
    let sizePreview = settings.sizeBar.bitmapImageRepForCachingDisplay(in: settings.sizeBar.bounds)!
    settings.sizeBar.cacheDisplay(in: settings.sizeBar.bounds, to: sizePreview)
    try sizePreview.representation(using: .png, properties: [:])!
        .write(to: directory.appendingPathComponent("size-bar.png"))
    let nativeSize = PetSizeProgressBar()
    var chosenSize: Double?
    nativeSize.onChange = { chosenSize = $0 }
    nativeSize.native.slider.doubleValue = 0.75
    nativeSize.native.slider.sendAction(nativeSize.native.slider.action!, to: nativeSize.native.slider.target)
    precondition(chosenSize == 256 && nativeSize.size == 256)
    precondition(nativeSize.accessibilityChildren()?.first as? NSSlider === nativeSize.native.slider)
    print("PASS: pet size scale maps 96 to center, 256 to three-quarter, 512 to endpoint")
    precondition(settings.loginButton.state == .off)
    settings.loginButton.performClick(nil)
    precondition(login.status == .enabled && settings.loginButton.state == .on)
    settings.loginButton.performClick(nil)
    precondition(login.status == .notRegistered && settings.loginButton.state == .off)
    login.failure = true
    settings.loginButton.performClick(nil)
    precondition(settings.loginButton.state == .off && settings.loginHint.stringValue.contains(L("Setting failed")))
    login.failure = false
    login.approval = true
    settings.loginButton.performClick(nil)
    precondition(login.status == .requiresApproval && !settings.loginSettingsButton.isHidden)
    print("PASS: login item enable/disable/error rollback/system approval (isolated service)")
    precondition(settings.resetButton.window === settings.window)
    settings.onReset = { try delegate.resetSettings() }
    delegate.setWakeDuration(.minutes(17))
    delegate.pet.resize(to: 256)
    delegate.pet.setColorStyle(.fade)
    delegate.pet.setCustomColor(.systemPink)
    delegate.pet.setRestColor(.systemGreen)
    delegate.pet.setRestPalette(.whales)
    delegate.pet.setRestColorMode(.linear)
    delegate.pet.setAutomaticShape(true)
    let sadItem = NSMenuItem(title: L("Sad"), action: nil, keyEquivalent: "")
    sadItem.representedObject = "sad"
    delegate.pet.view.selectMood(sadItem)
    precondition(delegate.pet.view.moodOverride == "sad")
    delegate.pet.savePosition()
    defaults.set(Data([1, 2, 3]), forKey: "shortcut")
    delegate.toggle()
    precondition(delegate.power.isEnabled)
    try settings.resetToDefaults()
    precondition(login.status == .notRegistered && settings.loginButton.state == .off)
    precondition(!delegate.power.isEnabled && delegate.wakeDeadline == nil)
    precondition(delegate.wakeDuration == .unlimited && settings.durationBar.duration == .unlimited)
    precondition(delegate.idleThreshold == .defaultValue && settings.idleField.stringValue == "4")
    precondition(delegate.hotKey.shortcut == .initial && delegate.pet.petSize == 48)
    precondition(delegate.pet.view.colorStyle == .radial && delegate.pet.view.palette == .rainbow)
    precondition(delegate.pet.view.restColor == nil && delegate.pet.view.restPalette == nil &&
        delegate.pet.view.restColorMode == .solid && !delegate.pet.automaticShape)
    precondition(delegate.pet.view.moodOverride == nil && delegate.pet.panel.isVisible)
    precondition(settings.sizeBar.size == 48 && settings.colorStyleButton.indexOfSelectedItem == 0)
    for key in ["shortcut", "wakeDurationMinutes", "idleThresholdMinutes", AppDelegate.keepAwakeModeKey, "petSize", "petX", "petY", "colorStyle", "petPalette", "petCustomColor", "petRestColor", "petRestPalette", "petRestColorMode", "petShapeAuto"] {
        precondition(defaults.object(forKey: key) == nil, "Reset retained \(key)")
    }
    print("PASS: settings-only Reset restores defaults and stops active keep-awake")
    defaults.set(KeepAwakeMode.lid.rawValue, forKey: AppDelegate.keepAwakeModeKey)
    let consent = AppDelegate(defaults: defaults)
    precondition(consent.keepAwakeMode == .lid)
    let noPower = DutyObservation(now: ProcessInfo.processInfo.systemUptime, busyAgents: "", battery: nil, heat: .nominal,
                                  assertionHeld: false, assertionMode: nil,
                                  lidHeld: false, lidAvailable: false)
    consent.applyDutyEffects(consent.duty.select(.off, mode: .lid, observation: noPower))
    precondition(consent.keepAwakeMode == .lid && consent.duty.source == .off)
    precondition(defaults.string(forKey: AppDelegate.keepAwakeModeKey) == KeepAwakeMode.lid.rawValue)
    precondition(consent.applicationShouldTerminate(NSApp) == .terminateNow)
    print("PASS: completed lid session keeps the selection without restarting itself")
}

/// A separate, exhaustive material check. It creates no app delegate, power assertion
/// or hotkey and renders the production scene rather than a substitute test shader.
@MainActor
func verifyStarRingCycle(displayPixels: Int = 48) throws {
    guard (12...192).contains(displayPixels) else {
        throw NSError(domain:"StarRingCycle",code:4,userInfo:[NSLocalizedDescriptionKey:L("Display pixel checks support 12–192 sphere pixels")])
    }
    let start = ProcessInfo.processInfo.systemUptime
    let side = displayPixels, integralSide = side+1
    var storage = [UInt8](repeating:0,count:side*side*4)
    var previous: [UInt8]?
    var maxLocal = 0.0, maxWhole = 0.0
    var worstFrame = 0
    var worstBefore: [UInt8] = [],worstAfter: [UInt8] = []
    var worstPatch = [0,0]
    try storage.withUnsafeMutableBytes { bytes in
        let pixels = bytes.bindMemory(to:UInt8.self)
        guard let context = CGContext(data:bytes.baseAddress,width:side,height:side,bitsPerComponent:8,
            bytesPerRow:side*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain:"StarRingCycle",code:1)
        }
        context.interpolationQuality = .high
        for frame in 0...7200 {
            try autoreleasepool {
                // Offset inside the quantized phase to avoid floating-point rounding
                // accidentally repeating the preceding 24Hz phase at exact boundaries.
                let renderSide = max(24,Int(ceil(Double(side)*3/6))*6)
                let levels = StarRingRenderer.bloomLevels(renderWidth:renderSide,renderHeight:renderSide)
                guard let field = ShaderMaterials.shared.starRenderer?.qualityImage(time:(Double(frame)+0.1)/24,
                          bodyPixels:side,samples:2,bloomLevels:levels),
                      let image = field.cropping(to:CGRect(x:renderSide/6,y:renderSide/6,width:renderSide*2/3,height:renderSide*2/3)) else {
                    throw NSError(domain:"StarRingCycle",code:2)
                }
                context.clear(CGRect(x:0,y:0,width:side,height:side))
                context.draw(image,in:CGRect(x:0,y:0,width:side,height:side))
                if let previous {
                    var integral = [Double](repeating:0,count:integralSide*integralSide)
                    for y in 0..<side { for x in 0..<side {
                        let i = (y*side+x)*4
                        var delta = 0.0
                        for channel in 0..<3 { delta += abs(Double(pixels[i+channel])-Double(previous[i+channel]))/765 }
                        let j = (y+1)*integralSide+x+1
                        integral[j] = delta+integral[j-1]+integral[j-integralSide]-integral[j-integralSide-1]
                    }}
                    maxWhole = max(maxWhole,integral.last!/Double(side*side))
                    for y in stride(from:0,through:side-8,by:4) { for x in stride(from:0,through:side-8,by:4) {
                        let change = (integral[(y+8)*integralSide+x+8]-integral[y*integralSide+x+8]
                            - integral[(y+8)*integralSide+x]+integral[y*integralSide+x])/64
                        if change>maxLocal {
                            maxLocal = change;worstFrame = frame;worstPatch = [x,y]
                            worstBefore = previous;worstAfter = Array(pixels)
                        }
                    }}
                }
                previous = Array(pixels)
            }
            if frame % 1440 == 0 { print("Star-ring cycle: \(frame)/7200 frames") }
        }
    }
    let elapsed = ProcessInfo.processInfo.systemUptime-start
    let report: [String:Any] = ["frames":7201,"durationSeconds":300,"framesPerSecond":24,
        "displayPixels":side,"patchPixels":8,"patchStridePixels":4,"maxWholeFrameChange":maxWhole,"maxLocalPatchChange":maxLocal,
        "renderBodyPixels":max(24,Int(ceil(Double(side)*3/6))*6)*2/3,"supersamplingPerAxis":2,"bloomLevels":StarRingRenderer.bloomLevels(renderWidth:side*3,renderHeight:side*3),
        "worstLocalFrame":worstFrame,"worstPatchOrigin":worstPatch,"wallSeconds":elapsed,"passed":maxLocal<0.04 && maxWhole<0.01,
        "scope":"production material passes at actual two-times display resolution at every 24Hz phase; native eyes and display presentation are checked separately"]
    let directory = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/star-goal-review")
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    let filename = side == 48 ? "full-cycle.json" : "full-cycle-\(side)px.json"
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent(filename))
    if maxLocal >= 0.04 || maxWhole >= 0.01 {
        for (name,pixels) in [("before",worstBefore),("after",worstAfter)] {
            let provider = CGDataProvider(data:Data(pixels) as CFData)!
            let image = CGImage(width:side,height:side,bitsPerComponent:8,bitsPerPixel:32,
                bytesPerRow:side*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
                provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
            try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!
                .write(to:directory.appendingPathComponent("cycle-\(side)px-\(name).png"))
        }
    }
    guard maxLocal<0.04 && maxWhole<0.01 else { throw NSError(domain:"StarRingCycle",code:3) }
    print(String(format:"PASS: %dpx / 7201 production frames / 300s / local %.5f / whole %.5f / %.2fs wall",side,maxLocal,maxWhole,elapsed))
}
