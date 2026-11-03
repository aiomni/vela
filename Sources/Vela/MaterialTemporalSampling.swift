import AppKit

/// Exports actual rendered color signals at dense simulated phases. This is an
/// image-sampling diagnostic, not a display-rate or CPU/GPU benchmark.
@MainActor
func exportMaterialTemporalSampling(palette: PetPalette, bodyPixels: Int) throws {
    guard palette != .stars, palette.shaderKind != nil, (24...192).contains(bodyPixels) else {
        throw NSError(domain: "MaterialSampling", code: 1)
    }
    if let failure = ShaderMaterials.shared.failure {
        throw NSError(domain: "MaterialSampling", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: failure])
    }
    let sampleRate = 96, patchSide = 4
    var duration = 24
    if let index = CommandLine.arguments.firstIndex(of: "--sampling-seconds") {
        guard index+1 < CommandLine.arguments.count,
            let seconds = Int(CommandLine.arguments[index+1]), (24...192).contains(seconds) else {
            throw NSError(domain: "MaterialSampling", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "--sampling-seconds requires 24–192 seconds"])
        }
        duration = seconds
    }
    let samples = sampleRate * duration, side = bodyPixels * 3 / 2
    let columns = side / patchSide, rows = side / patchSide
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/other-effects-review/temporal")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let base = root.appendingPathComponent("\(palette.rawValue)-\(bodyPixels)")
    let binary = base.appendingPathExtension("f32")
    try Data().write(to: binary)
    let handle = try FileHandle(forWritingTo: binary)
    defer { try? handle.close() }
    guard let context = CGContext(data: nil, width: side, height: side,
        bitsPerComponent: 8, bytesPerRow: side * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        let data = context.data else { throw NSError(domain: "MaterialSampling", code: 3) }
    context.interpolationQuality = .high
    let pixels = data.assumingMemoryBound(to: UInt8.self)
    let rect = CGRect(x: 0, y: 0, width: side, height: side)
    var signals = [Float](repeating: 0, count: columns * rows * 3)
    for frame in 0..<samples {
        try autoreleasepool {
            guard let image = ShaderMaterials.shared.fieldImage(for: palette,
                time: Double(frame) / Double(sampleRate), bodyPixels: bodyPixels * 2,
                pixelFootprint: 1 / Float(bodyPixels)) else {
                throw NSError(domain: "MaterialSampling", code: 4)
            }
            context.clear(rect)
            context.draw(image, in: rect)
            for row in 0..<rows { for column in 0..<columns {
                var red = 0, green = 0, blue = 0
                for y in row * patchSide..<(row + 1) * patchSide {
                    for x in column * patchSide..<(column + 1) * patchSide {
                        let i = (y * side + x) * 4
                        red += Int(pixels[i]); green += Int(pixels[i + 1]); blue += Int(pixels[i + 2])
                    }
                }
                let i = (row * columns + column) * 3
                let divisor = Float(patchSide * patchSide * 255)
                signals[i] = Float(red) / divisor
                signals[i + 1] = Float(green) / divisor
                signals[i + 2] = Float(blue) / divisor
            }}
            try signals.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
        }
    }
    let report: [String: Any] = [
        "palette": palette.rawValue, "bodyPixels": bodyPixels,
        "sampleRate": sampleRate, "durationSeconds": duration, "samples": samples,
        "patchSidePixels": patchSide, "columns": columns, "rows": rows,
        "channels": 3, "format": "float32-little-endian",
        "binary": binary.lastPathComponent,
        "scope": "Actual native fragment at 2x display resolution, downsampled to physical pixels; RGB means of 4x4 patches at dense simulated phases. Excludes eyes, interactions and native display scheduling. No performance measurements."
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: base.appendingPathExtension("json"))
    print("Exported temporal image signals: \(palette.rawValue), \(bodyPixels) physical pixels")
}
