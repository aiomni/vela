import VelaLocalization
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Compares real shader passes at final display scale, including transparent halo.
@MainActor
func generateStarRingQualityReview(at directory: URL) throws {
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    guard let renderer = ShaderMaterials.shared.starRenderer else { throw NSError(domain:"StarRingQuality",code:1) }
    for bodyPixels in [48,96,144] {
        let side = bodyPixels*3/2
        for samples: Float in [1,1.5,2] { for levels in 3...5 {
            for time in [0,30,60,120,180,240] {
                try autoreleasepool {
                    guard let image = renderer.qualityImage(time:Double(time),bodyPixels:bodyPixels,samples:samples,bloomLevels:levels),
                          let context = CGContext(data:nil,width:side,height:side,bitsPerComponent:8,bytesPerRow:side*4,
                            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {
                        throw NSError(domain:"StarRingQuality",code:2)
                    }
                    context.interpolationQuality = .high
                    context.draw(image,in:CGRect(x:0,y:0,width:side,height:side))
                    let bitmap = NSBitmapImageRep(cgImage:context.makeImage()!)
                    let name = "body\(bodyPixels)-samples\(samples)-bloom\(levels)-t\(time).png"
                    try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(name))
                }
            }
        }}
    }
    print("Generated display-scale quality candidates: \(directory.path)")
}

@MainActor
func generateEffectPreviews(at directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let geometry = try PetGeometry.load()
    let palettes = PetPalette.selectable
    let rows = (palettes.count + 3) / 4
    let pets = palettes.map { palette in
        let pet = PetView(geometry: geometry)
        pet.palette = palette
        pet.customColor = .systemPink
        pet.frame = NSRect(x: 0, y: 0, width: 176, height: 176)
        pet.isAwake = true
        pet.moodOverride = "idle"
        return pet
    }
    let frameCount = 80
    func destination(_ name: String) throws -> CGImageDestination {
        guard let result = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name).appendingPathExtension("gif") as CFURL,
            UTType.gif.identifier as CFString, frameCount, nil) else {
            throw NSError(domain: "EffectPreviews", code: 1)
        }
        CGImageDestinationSetProperties(result, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        return result
    }
    let combined = try destination("all-effects")
    let individual = try palettes.map { try destination($0.rawValue) }
    let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.125,
        kCGImagePropertyGIFUnclampedDelayTime: 0.125]] as CFDictionary
    for frame in 0..<frameCount {
        try autoreleasepool {
            let gallery = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: rows * 224,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: gallery)
            NSColor(srgbRed: 0.08, green: 0.09, blue: 0.13, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 800, height: rows * 224).fill()
            NSGraphicsContext.restoreGraphicsState()
            for (index, pet) in pets.enumerated() {
                pet.animationTime = Double(frame) * 0.125
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 224,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                    NSColor(srgbRed: 0.08, green: 0.09, blue: 0.13, alpha: 1).setFill()
                    NSRect(x: 0, y: 0, width: 200, height: 224).fill()
                    let title = palettes[index].title as NSString
                    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white]
                    let titleSize = title.size(withAttributes: attributes)
                    title.draw(at: NSPoint(x: (200 - titleSize.width) / 2, y: 12), withAttributes: attributes)
                    let context = NSGraphicsContext.current!.cgContext
                    context.saveGState()
                    context.translateBy(x: 12, y: 213)
                    context.scaleBy(x: 1, y: -1)
                    pet.draw(pet.bounds)
                    context.restoreGState()
                }
                NSGraphicsContext.restoreGraphicsState()
                CGImageDestinationAddImage(individual[index], bitmap.cgImage!, delay)
                if frame == 0 {
                    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(palettes[index].rawValue).png"))
                }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: gallery)
                bitmap.draw(in: NSRect(x: (index % 4) * 200, y: (rows - 1 - index / 4) * 224, width: 200, height: 224))
                NSGraphicsContext.restoreGraphicsState()
            }
            CGImageDestinationAddImage(combined, gallery.cgImage!, delay)
            if frame == 0 {
                try gallery.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("all-effects.png"))
            }
        }
    }
    for result in individual + [combined] {
        guard CGImageDestinationFinalize(result) else { throw NSError(domain: "EffectPreviews", code: 2) }
    }
    for name in palettes.map(\.rawValue) + ["all-effects"] {
        let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(name).appendingPathExtension("gif") as CFURL, nil)!
        precondition(CGImageSourceGetCount(source) == frameCount)
    }
    let cards = palettes.map { "<article><h2>\($0.title)</h2><img src='\($0.rawValue).gif' alt='\($0.title) animated preview'></article>" }.joined(separator: "\n")
    let html = """
    <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Vela Live Effect Previews</title><style>
    body{margin:0;background:#141721;color:#f6f6fa;font:15px -apple-system,BlinkMacSystemFont,sans-serif}main{max-width:1000px;margin:36px auto;padding:0 24px}h1{font-size:24px}p{color:#b8bdce;line-height:1.6}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:16px}article{background:#1c2030;border:1px solid #30364a;border-radius:16px;text-align:center;padding:12px}h2{font-size:15px;font-weight:500}img{width:200px;height:224px;border-radius:12px}button{background:#343c55;color:white;border:0;border-radius:8px;padding:9px 15px;cursor:pointer;margin-bottom:18px}
    </style><main><h1>Current Effects · Animated Previews</h1><p>Generated using the companion renderer. Each clip loops for 10 seconds at normal speed; the custom color example uses pink. Pause to inspect colors and details.</p><button id="toggle">Pause animation</button><div class="grid">\(cards)</div></main><script>
    let paused=false;document.getElementById('toggle').onclick=()=>{paused=!paused;document.querySelectorAll('img').forEach(img=>{img.src=img.src.replace(paused?'.gif':'.png',paused?'.png':'.gif')});document.getElementById('toggle').textContent=paused?'Play animation':'Pause animation'};
    </script></html>
    """
    try html.write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    print("Generated and verified \(palettes.count) animated previews: \(directory.path)")
}

/// Review frames come from the production PetView and Metal material, never concept artwork.
@MainActor
func generateStarRingReview(at directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let pet = PetView(geometry: try PetGeometry.load())
    pet.palette = .stars
    pet.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    pet.drawingPadding = 40
    pet.isAwake = true
    pet.moodOverride = "idle"
    let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent("star-ring.gif") as CFURL,
        UTType.gif.identifier as CFString, 288, nil)!
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for frame in 0..<288 {
        try autoreleasepool {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 400,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor(srgbRed: 0.009, green: 0.010, blue: 0.014, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 400, height: 400).fill()
            let context = NSGraphicsContext.current!.cgContext
            context.translateBy(x: 0, y: 400)
            context.scaleBy(x: 1, y: -1)
            pet.animationTime = Double(frame) / 24
            pet.draw(pet.bounds)
            NSGraphicsContext.restoreGraphicsState()
            if frame % 72 == 0 {
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("star-ring-\(frame / 24).png"))
            }
            CGImageDestinationAddImage(destination, bitmap.cgImage!, [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 1.0 / 24,
                kCGImagePropertyGIFUnclampedDelayTime: 1.0 / 24]] as CFDictionary)
        }
    }
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "StarRingReview", code: 1) }
    // Long-cycle stills and an unbacked frame distinguish animation/material failures
    // from a comparison canvas background. These use exactly the same PetView draw.
    for time in [0,30,60,120,180,240] {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: 400,pixelsHigh: 400,
            bitsPerSample: 8,samplesPerPixel: 4,hasAlpha: true,isPlanar: false,
            colorSpaceName: .deviceRGB,bytesPerRow: 0,bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.clear(CGRect(x:0,y:0,width:400,height:400))
        context.translateBy(x:0,y:400);context.scaleBy(x:1,y:-1)
        pet.animationTime = Double(time)
        pet.draw(pet.bounds)
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("star-ring-transparent-\(time).png"))
    }
    // Compare resting, automatic and hovered eyes at the same animation phase.
    // These are native PetView frames, so the old mood-dependent size jump is visible.
    for mood in PetAnimation.catalog {
        pet.moodOverride = mood.id
        pet.animationTime = 1.2
        for hovered in [false,true] {
            let event = NSEvent.mouseEvent(with:.mouseMoved,
                location:NSPoint(x:200,y:200),modifierFlags:[],timestamp:0,windowNumber:0,
                context:nil,eventNumber:0,clickCount:0,pressure:0)!
            if hovered { pet.mouseEntered(with:event) } else { pet.mouseExited(with:event) }
            let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:400,pixelsHigh:400,
                bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,
                colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
            let context = NSGraphicsContext.current!.cgContext
            NSColor.white.setFill()
            NSRect(x:0,y:0,width:400,height:400).fill()
            context.translateBy(x:0,y:400);context.scaleBy(x:1,y:-1)
            pet.draw(pet.bounds)
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(
                "eyes-\(mood.id)-\(hovered ? "hover" : "rest").png"))
        }
    }
    print("Generated production star-ring frames: \(directory.path)")
}
