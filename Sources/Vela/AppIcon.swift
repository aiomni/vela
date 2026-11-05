import AppKit

@MainActor
private func appIconBitmap(geometry: PetGeometry, pixels: Int) -> NSBitmapImageRep {
    let side = CGFloat(pixels)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let tile = NSBezierPath(roundedRect: NSRect(x: side * 0.07, y: side * 0.07,
        width: side * 0.86, height: side * 0.86), xRadius: side * 0.19, yRadius: side * 0.19)
    NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
    tile.fill()
    NSColor.black.withAlphaComponent(0.08).setStroke()
    tile.lineWidth = max(0.5, side / 512)
    tile.stroke()
    NSColor(calibratedWhite: 0.035, alpha: 1).setFill()
    companionIconPath(geometry: geometry,
        in: NSRect(x: side * 0.20, y: side * 0.20, width: side * 0.60, height: side * 0.60)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

@MainActor
func makeApplicationIcon(geometry: PetGeometry) -> NSImage {
    let bitmap = appIconBitmap(geometry: geometry, pixels: 512)
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
            let bitmap = appIconBitmap(geometry: geometry, pixels: pixels)
            let suffix = density == 2 ? "@2x" : ""
            let data = bitmap.representation(using: .png, properties: [:])!
            try data.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        }
    }
}
