import AppKit

/// Checks visual changes at a simulated 24 Hz phase grid. This is not a frame-rate
/// or GPU benchmark, and does not establish native eye/interaction acceptance.
@MainActor
func verifyMaterialCycle(palette: PetPalette,bodyPixels: Int,whaleVector: Bool = false) throws {
    guard palette != .stars,palette.shaderKind != nil,(24...192).contains(bodyPixels) else {
        throw NSError(domain:"MaterialCycle",code:1,userInfo:[NSLocalizedDescriptionKey:"A non-star shader material and 24–192 body pixels are required."])
    }
    if let failure = ShaderMaterials.shared.failure { throw NSError(domain:"MaterialCycle",code:2,userInfo:[NSLocalizedDescriptionKey:failure]) }
    let side = bodyPixels*3/2,frames = 120*24+1
    if whaleVector && palette != .whales { throw NSError(domain:"MaterialCycle",code:6) }
    let whaleBody = whaleVector ? try PetView(geometry:PetGeometry.load()).body : nil
    func imageAt(_ time: Double) -> CGImage? {
        guard let whaleBody else {
            return ShaderMaterials.shared.fieldImage(for:palette,time:time,bodyPixels:bodyPixels*2,pixelFootprint:1/Float(bodyPixels))
        }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:side,pixelsHigh:side,bitsPerSample:8,
            samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
            let graphics = NSGraphicsContext(bitmapImageRep:bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.translateBy(x:CGFloat(side)/2,y:CGFloat(side)/2)
        let scale = CGFloat(bodyPixels)/228.54
        context.scaleBy(x:scale,y:scale);context.translateBy(x:-114.27,y:-114.27)
        whaleBody.addClip()
        drawDreamWhales(time:time,opacity:1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage
    }
    var previous: [UInt8]?,initial: [UInt8]?
    var maxWhole = 0.0,maxLocal = 0.0,largestMotion = 0.0,worstFrame = 0
    var worstOrigin = [0,0],worstPrevious = [UInt8](),worstCurrent = [UInt8]()
    for frame in 0..<frames {
        try autoreleasepool {
            guard let image = imageAt(Double(frame)/24),
                let context = CGContext(data:nil,width:side,height:side,bitsPerComponent:8,bytesPerRow:side*4,
                    space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),
                let data = context.data else { throw NSError(domain:"MaterialCycle",code:3) }
            context.interpolationQuality = .high
            context.draw(image,in:CGRect(x:0,y:0,width:side,height:side))
            let pixels = Array(UnsafeBufferPointer(start:data.assumingMemoryBound(to:UInt8.self),count:side*side*4))
            if let previous {
                var differences = [Double](repeating:0,count:side*side)
                var total = 0.0
                for p in 0..<(side*side) {
                    let i = p*4
                    let change = (abs(Double(pixels[i])-Double(previous[i])) +
                        abs(Double(pixels[i+1])-Double(previous[i+1])) +
                        abs(Double(pixels[i+2])-Double(previous[i+2])))/(255*3)
                    differences[p] = change;total += change
                }
                maxWhole = max(maxWhole,total/Double(side*side))
                for y in stride(from:0,through:side-8,by:4) { for x in stride(from:0,through:side-8,by:4) {
                    var local = 0.0
                    for py in y..<(y+8) { for px in x..<(x+8) { local += differences[py*side+px] } }
                    local /= 64
                    if local>maxLocal {
                        maxLocal = local;worstFrame = frame;worstOrigin = [x,y]
                        worstPrevious = previous;worstCurrent = pixels
                    }
                }}
            }
            if let initial,frame%192 == 0 {
                let difference = zip(pixels,initial).map { abs(Double($0)-Double($1))/255 }.reduce(0,+)/Double(pixels.count)
                largestMotion = max(largestMotion,difference)
            } else if initial == nil { initial = pixels }
            previous = pixels
        }
    }
    let passed = maxLocal<0.04 && maxWhole<0.01 && largestMotion>0.001
    let label = palette.rawValue + (whaleVector ? "-vector" : "")
    let report: [String:Any] = ["palette":label,"bodyPixels":bodyPixels,"supersamplingPerAxis":whaleVector ? 1 : 2,
        "phaseSamples":frames,"phaseStepSeconds":1.0/24,"durationSeconds":120,"maxWholeFrameChange":maxWhole,
        "maxLocalPatchChange":maxLocal,"largestDifferenceFromInitial":largestMotion,"worstLocalFrame":worstFrame,
        "worstPatchOrigin":worstOrigin,"passed":passed,"scope":whaleVector ? "actual drawDreamWhales vector output at physical display pixels, including deforming body, fins, flukes, dust and spout; excludes shell shader, eyes, shared body pose and native display scheduling; not a performance measurement" : "actual native fragment output at two-times display resolution, downsampled to physical pixels; excludes eyes and native display scheduling; not a performance measurement"]
    let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/other-effects-review/cycles")
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("\(label)-\(bodyPixels).json"))
    if !passed {
        for (label,pixels) in [("before",worstPrevious),("after",worstCurrent)] {
            let provider = CGDataProvider(data:Data(pixels) as CFData)!
            let image = CGImage(width:side,height:side,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:side*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
                provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
            try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!
                .write(to:root.appendingPathComponent("\(palette.rawValue)\(whaleVector ? "-vector" : "")-\(bodyPixels)-worst-\(label).png"))
        }
    }
    guard passed else { throw NSError(domain:"MaterialCycle",code:4,userInfo:[NSLocalizedDescriptionKey:"Material continuity/visible-change check failed: \(palette.rawValue) at \(bodyPixels) pixels"]) }
    print("PASS: \(label) visual continuity and visible change at \(bodyPixels) physical body pixels")
}
