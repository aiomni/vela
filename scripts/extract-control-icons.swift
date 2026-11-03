import AppKit

// Extract the six approved illustrations with one scale factor per icon.
// Matching visible areas balances their apparent size without distorting circles
// or changing the laptop screen-to-base geometry.
// Usage: swift scripts/extract-control-icons.swift SHEET.png OUTPUT_DIR
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let bitmap = NSBitmapImageRep(data: try Data(contentsOf: sourceURL))!
let columns = 3
let rows = 2
precondition(bitmap.pixelsWide % columns == 0 && bitmap.pixelsHigh % rows == 0)
let cellWidth = bitmap.pixelsWide / columns
let cellHeight = bitmap.pixelsHigh / rows
let names = ["power", "agent", "display", "system", "lid", "settings"]
let outputSide = 256
let targetInkArea: CGFloat = 38_000
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

for (index, name) in names.enumerated() {
    let originX = index % columns * cellWidth
    let originY = index / columns * cellHeight
    var minX = cellWidth
    var minY = cellHeight
    var maxX = -1
    var maxY = -1
    for y in originY..<(originY + cellHeight) {
        for x in originX..<(originX + cellWidth) {
            if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                minX = min(minX, x - originX)
                minY = min(minY, y - originY)
                maxX = max(maxX, x - originX)
                maxY = max(maxY, y - originY)
            }
        }
    }
    precondition(maxX > minX && maxY > minY, "Missing \(name) illustration")
    if name == "lid" {
        var pinkMinX = cellWidth
        var pinkMinY = cellHeight
        var pinkMaxX = -1
        var pinkMaxY = -1
        var baseMinX = cellWidth
        var baseMaxX = -1
        for y in originY..<(originY + cellHeight) {
            for x in originX..<(originX + cellWidth) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.2 else { continue }
                let localX = x - originX
                let localY = y - originY
                if color.redComponent > 0.65 &&
                    color.redComponent > color.greenComponent + 0.12 &&
                    color.redComponent > color.blueComponent + 0.08 {
                    pinkMinX = min(pinkMinX, localX)
                    pinkMinY = min(pinkMinY, localY)
                    pinkMaxX = max(pinkMaxX, localX)
                    pinkMaxY = max(pinkMaxY, localY)
                }
                if (300..<400).contains(localY) {
                    baseMinX = min(baseMinX, localX)
                    baseMaxX = max(baseMaxX, localX)
                }
            }
        }
        let screenLength = hypot(CGFloat(pinkMaxX - pinkMinX), CGFloat(pinkMaxY - pinkMinY))
        let baseLength = CGFloat(baseMaxX - baseMinX)
        precondition(abs(screenLength / baseLength - 1) < 0.06,
                     "Lid screen and base have different lengths")
    }
    let margin = 3
    let cropX = originX + max(0, minX - margin)
    let cropY = originY + max(0, minY - margin)
    let cropWidth = min(cellWidth, maxX + margin + 1) - (cropX - originX)
    let cropHeight = min(cellHeight, maxY + margin + 1) - (cropY - originY)
    let crop = bitmap.cgImage!.cropping(to: CGRect(x: cropX, y: cropY,
                                                   width: cropWidth, height: cropHeight))!
    let image = NSImage(cgImage: crop, size: NSSize(width: cropWidth, height: cropHeight))
    let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: outputSide,
                                  pixelsHigh: outputSide, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                  bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: output)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: outputSide, height: outputSide).fill()
    let sourceInkWidth = CGFloat(maxX - minX + 1)
    let sourceInkHeight = CGFloat(maxY - minY + 1)
    let scale = sqrt(targetInkArea / (sourceInkWidth * sourceInkHeight))
    let width = CGFloat(cropWidth) * scale
    let height = CGFloat(cropHeight) * scale
    image.draw(in: NSRect(x: (CGFloat(outputSide) - width) / 2,
                          y: (CGFloat(outputSide) - height) / 2,
                          width: width, height: height),
               from: .zero, operation: .sourceOver, fraction: 1)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    var outputMinX = outputSide
    var outputMinY = outputSide
    var outputMaxX = -1
    var outputMaxY = -1
    for y in 0..<outputSide {
        for x in 0..<outputSide where (output.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
            outputMinX = min(outputMinX, x)
            outputMinY = min(outputMinY, y)
            outputMaxX = max(outputMaxX, x)
            outputMaxY = max(outputMaxY, y)
        }
    }
    let outputInkWidth = outputMaxX - outputMinX + 1
    let outputInkHeight = outputMaxY - outputMinY + 1
    let visibleArea = CGFloat(outputInkWidth * outputInkHeight)
    let sourceAspect = sourceInkWidth / sourceInkHeight
    let outputAspect = CGFloat(outputInkWidth) / CGFloat(outputInkHeight)
    precondition(abs(visibleArea - targetInkArea) / targetInkArea < 0.02 &&
                 abs(outputAspect / sourceAspect - 1) < 0.02 &&
                 outputInkWidth < outputSide - 16 && outputInkHeight < outputSide - 16,
                 "Unexpected visible size for \(name)")
    try output.representation(using: .png, properties: [:])!
        .write(to: outputURL.appendingPathComponent("\(name).png"))
    print("\(name): \(cropWidth)x\(cropHeight) -> \(outputInkWidth)x\(outputInkHeight) ink")
}
