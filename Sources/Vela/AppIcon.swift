import AppKit

@MainActor
private func appIconBitmap(geometry: PetGeometry, pixels: Int, enabled: Bool, palette: PetPalette = .orange, customColor: NSColor = .systemOrange, shape: PetShape = .blob, eyeColor: NSColor? = nil, restColor: NSColor? = nil, restPalette: PetPalette? = nil, restColorMode: PetColorMode = .solid, colorMode: PetColorMode = .solid) -> NSBitmapImageRep {
    let side = CGFloat(pixels)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
        let tile = NSBezierPath(roundedRect: NSRect(x: side * 0.07, y: side * 0.07,
            width: side * 0.86, height: side * 0.86), xRadius: side * 0.19, yRadius: side * 0.19)
        NSColor(calibratedRed: 0.965, green: 0.95, blue: 0.92, alpha: 1).setFill()
        tile.fill()
        NSColor.black.withAlphaComponent(0.08).setStroke()
        tile.lineWidth = max(0.5, side / 512)
        tile.stroke()
        let pet = PetView(geometry: geometry)
        pet.palette = palette
        pet.customColor = customColor
        pet.shape = shape
        pet.eyeColor = eyeColor
        pet.restColor = restColor
        pet.restPalette = restPalette
        pet.restColorMode = restColorMode
        pet.colorMode = colorMode
        pet.frame = NSRect(x: 0, y: 0, width: 256, height: 256)
        pet.isAwake = enabled
        pet.usesAwakeColor = true
        pet.animationTime = 0.8
        let context = NSGraphicsContext.current!.cgContext
        context.saveGState()
        context.translateBy(x: side * 0.11, y: side * 0.89)
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: side * 0.78 / 256, y: side * 0.78 / 256)
        pet.draw(pet.bounds)
        context.restoreGState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

@MainActor
func makeApplicationIcon(geometry: PetGeometry, enabled: Bool, palette: PetPalette = .orange, customColor: NSColor = .systemOrange, shape: PetShape = .blob, eyeColor: NSColor? = nil, restColor: NSColor? = nil, restPalette: PetPalette? = nil, restColorMode: PetColorMode = .solid, colorMode: PetColorMode = .solid) -> NSImage {
    let bitmap = appIconBitmap(geometry: geometry, pixels: 512, enabled: enabled, palette: palette, customColor: customColor, shape: shape, eyeColor: eyeColor, restColor: restColor, restPalette: restPalette, restColorMode: restColorMode, colorMode: colorMode)
    bitmap.size = NSSize(width: 256, height: 256)
    let image = NSImage(size: bitmap.size)
    image.addRepresentation(bitmap)
    return image
}

@MainActor
func generateAppIconSet(at directory: URL) throws {
    let geometry = try PetGeometry.load()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        for density in [1, 2] {
            let pixels = size * density
            let bitmap = appIconBitmap(geometry: geometry, pixels: pixels, enabled: false)
            let suffix = density == 2 ? "@2x" : ""
            let data = bitmap.representation(using: .png, properties: [:])!
            try data.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        }
    }
}
