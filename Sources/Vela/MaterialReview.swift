import VelaLocalization
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Exports the real PetView/fragment path. No design pixels enter the renderer.
@MainActor
func generateMaterialReview(at directory: URL,palette selected: PetPalette?,animated: Bool) throws {
    if let failure = ShaderMaterials.shared.failure {
        throw NSError(domain:"MaterialReview",code:2,userInfo:[NSLocalizedDescriptionKey:failure])
    }
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    let palettes = selected.map { [$0] } ?? PetPalette.selectable.filter { $0 != .custom && $0 != .stars }
    let geometry = try PetGeometry.load()
    func render(_ pet: PetView,time: Double,side: Int,bodyPixels: Int?,light: Bool) -> NSBitmapImageRep {
        pet.frame = NSRect(x:0,y:0,width:side,height:side)
        pet.drawingPadding = bodyPixels.map { CGFloat(side)-CGFloat($0)*259/228.54 } ?? 40
        pet.animationTime = time
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:side,pixelsHigh:side,bitsPerSample:8,
            samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        (light ? NSColor.white : NSColor(srgbRed:0.009,green:0.010,blue:0.014,alpha:1)).setFill()
        NSRect(x:0,y:0,width:side,height:side).fill()
        let context = NSGraphicsContext.current!.cgContext
        context.translateBy(x:0,y:CGFloat(side));context.scaleBy(x:1,y:-1)
        pet.draw(pet.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
    let gallery = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:800,pixelsHigh:palettes.count*400,bitsPerSample:8,
        samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    for (index,palette) in palettes.enumerated() {
        let pet = PetView(geometry:geometry);pet.palette = palette;pet.moodOverride = "idle";pet.isAwake = true
        for time in [0,2,4,8,16,32,60] {
            for light in [false,true] {
                let bitmap = autoreleasepool { render(pet,time:Double(time),side:400,bodyPixels:nil,light:light) }
                let name = "\(palette.rawValue)-\(time)-\(light ? "light" : "dark").png"
                try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(name))
                if time == 0 {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:gallery)
                    bitmap.draw(in:NSRect(x:light ? 400 : 0,y:(palettes.count-1-index)*400,width:400,height:400))
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
        }
        for bodyPixels in [24,48,96,144] {
            for time in [0,4,16] {
                let bitmap = autoreleasepool { render(pet,time:Double(time),side:bodyPixels*3/2,bodyPixels:bodyPixels,light:true) }
                try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("\(palette.rawValue)-body\(bodyPixels)-t\(time).png"))
            }
        }
        if animated {
            let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent("\(palette.rawValue).gif") as CFURL,
                UTType.gif.identifier as CFString,240,nil)!
            CGImageDestinationSetProperties(destination,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
            for frame in 0..<240 {
                autoreleasepool {
                    let image = render(pet,time:Double(frame)/24,side:400,bodyPixels:nil,light:false)
                    CGImageDestinationAddImage(destination,image.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:1.0/24,
                        kCGImagePropertyGIFUnclampedDelayTime:1.0/24]] as CFDictionary)
                }
            }
            guard CGImageDestinationFinalize(destination) else { throw NSError(domain:"MaterialReview",code:1) }
        }
    }
    try gallery.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("gallery.png"))
    let cards = palettes.map { palette in
        "<article><h2>\(palette.title)</h2><img src='\(palette.rawValue)-0-dark.png'><img src='\(palette.rawValue)-0-light.png'>" +
            (animated ? "<img src='\(palette.rawValue).gif'>" : "") + "</article>"
    }.joined(separator:"\n")
    let html = """
    <!doctype html><html lang="en"><meta charset="utf-8"><title>Vela Effect Review</title>
    <style>body{background:#10121b;color:#e8eefb;font:16px -apple-system;margin:32px}article{margin:32px 0}img{width:320px;max-width:100%;margin:8px}p{color:#a8b6cd}</style>
    <h1>Actual Render Review</h1><p>Images use production PetView and Metal fragments. Animations are 10-second clips at 24 Hz; loops restart. Continuous motion is checked separately in a live window.</p>
    \(cards)</html>
    """
    try html.write(to:directory.appendingPathComponent("index.html"),atomically:true,encoding:.utf8)
    print("Generated native material review: \(directory.path)")
}
