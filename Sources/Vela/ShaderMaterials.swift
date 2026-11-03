import AppKit
import Metal

/// A bounded offscreen surface, shared by desktop drawing and application-icon snapshots.
@MainActor
final class ShaderMaterials {
    static let shared = ShaderMaterials()
    private let device: (any MTLDevice)?
    private let queue: (any MTLCommandQueue)?
    private let pipeline: (any MTLComputePipelineState)?
    let renderPipeline: (any MTLRenderPipelineState)?
    var renderingDevice: (any MTLDevice)? { device }
    var renderingQueue: (any MTLCommandQueue)? { queue }
    private(set) var starRenderer: StarRingRenderer?
    private let texture: (any MTLTexture)?
    private(set) var volumeNoise: (any MTLTexture)?
    private var cache: [PetPalette: (Double, Float, CGImage)] = [:]
    private var fieldTexture: (any MTLTexture)?
    private struct FieldKey: Equatable {
        let palette: PetPalette
        let phase: Float
        let side: Int
        let footprint: Float
    }
    private var cachedField: (FieldKey, CGImage)?
    private(set) var fieldTextureAllocations = 0
    private(set) var failure: String?
    private(set) var snapshotReadbacks = 0
    private let side = 256
    private struct Parameters { var time: Float; var kind: UInt32; var size: UInt32; var footprint: Float = 1 / 256 }

    private init() {
        let gpu = MTLCreateSystemDefaultDevice()
        device = gpu
        queue = gpu?.makeCommandQueue()
        do {
            guard let gpu, let url = Bundle.module.url(forResource: "Materials", withExtension: "metal", subdirectory: "Assets") else {
                throw NSError(domain: "Vela.Materials", code: 1)
            }
            starRenderer = try StarRingRenderer(device: gpu)
            guard let queue else { throw NSError(domain:"Vela.Materials",code:3) }
            volumeNoise = try MaterialVolume.make(device:gpu,queue:queue)
            let library = try gpu.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
            guard let function = library.makeFunction(name: "materialFrame") else { throw NSError(domain: "Vela.Materials", code: 2) }
            let compute = try gpu.makeComputePipelineState(function: function)
            let renderDescriptor = MTLRenderPipelineDescriptor()
            renderDescriptor.vertexFunction = library.makeFunction(name: "materialVertex")
            renderDescriptor.fragmentFunction = library.makeFunction(name: "liveMaterialFragment")
            renderDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            let render = try gpu.makeRenderPipelineState(descriptor: renderDescriptor)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 512, height: 512, mipmapped: false)
            descriptor.usage = [.shaderWrite]
            descriptor.storageMode = .shared
            texture = gpu.makeTexture(descriptor: descriptor)
            pipeline = compute
            renderPipeline = render
        } catch {
            pipeline = nil
            renderPipeline = nil
            texture = nil
            failure = error.localizedDescription
        }
    }

    func image(for palette: PetPalette, time: Double, pixelFootprint: Float? = nil) -> CGImage? {
        if palette == .stars {
            guard let image = starRenderer?.bodyImage(time: time, pixelFootprint: pixelFootprint ?? 0) else { return nil }
            snapshotReadbacks += 1
            return image
        }
        guard let kind = palette.shaderKind, let queue, let pipeline, let texture else { return nil }
        let phase = floor(time * 15) / 15
        let size = palette == .stars ? 512 : side
        let footprint = pixelFootprint ?? 1 / Float(size)
        if let entry = cache[palette], entry.0 == phase && entry.1 == footprint { return entry.2 }
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { return nil }
        var parameters = Parameters(time: Float(phase), kind: kind, size: UInt32(size), footprint: footprint)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(volumeNoise,index:1)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: size, height: size, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { failure = command.error?.localizedDescription; return nil }
        var bytes = Data(count: size * size * 4)
        bytes.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        snapshotReadbacks += 1
        guard let provider = CGDataProvider(data: bytes as CFData), let image = CGImage(width: size, height: size,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        cache[palette] = (phase, footprint, image)
        return image
    }

    func draw(_ palette: PetPalette, body: NSBezierPath, time: Double, opacity: Double) -> Bool {
        if palette == .stars, let starRenderer {
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let transform = context.ctm
            let diameter = 228.54 * min(hypot(transform.a,transform.b),hypot(transform.c,transform.d))
            starRenderer.drawFullField(time: time, opacity: opacity,displayDiameter:diameter,baseDiameter:diameter)
            return true
        }
        guard palette.shaderKind != nil,let context = NSGraphicsContext.current?.cgContext else { return false }
        let transform = context.ctm
        let diameter = 228.54 * min(hypot(transform.a,transform.b),hypot(transform.c,transform.d))
        return drawFullField(palette,time:time,opacity:opacity,displayDiameter:diameter,baseDiameter:diameter)
    }

    /// Native fragment pass, including transparent padding. Only export/icon draws
    /// read pixels back; the live MTKView keeps its own GPU drawable.
    func fieldImage(for palette: PetPalette,time: Double,bodyPixels: Int,pixelFootprint: Float) -> CGImage? {
        guard palette != .stars,let kind = palette.shaderKind,let device,let queue,let renderPipeline else { return nil }
        let side = max(24,min(3072,Int(ceil(Double(bodyPixels)*1.5/6))*6))
        // Keep explicit capture phases identical to live time. Quantizing an
        // already sampled Double can repeat a frame then jump two steps.
        let key = FieldKey(palette:palette,phase:Float(time),side:side,footprint:pixelFootprint)
        if let cachedField,cachedField.0 == key { return cachedField.1 }
        if fieldTexture?.width != side {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:side,height:side,mipmapped:false)
            descriptor.storageMode = .shared;descriptor.usage = [.renderTarget]
            fieldTexture = device.makeTexture(descriptor:descriptor)
            fieldTextureAllocations += 1
        }
        guard let target = fieldTexture,let command = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor:pass) else { return nil }
        var frame = LiveMaterialSurface.Parameters()
        frame.time = key.phase;frame.kind = kind;frame.progress = 1;frame.style = 3
        frame.size = SIMD2(repeating:Float(side));frame.center = frame.size/2
        frame.scale = SIMD2(repeating:Float(side)/(228.54*1.5));frame.padding = pixelFootprint
        encoder.setRenderPipelineState(renderPipeline)
        encoder.setFragmentTexture(volumeNoise,index:0)
        encoder.setFragmentBytes(&frame,length:MemoryLayout<LiveMaterialSurface.Parameters>.stride,index:0)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);encoder.endEncoding()
        command.commit();command.waitUntilCompleted()
        guard command.status == .completed else { failure = command.error?.localizedDescription;return nil }
        var bytes = Data(count:side*side*4)
        bytes.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow:side*4,from:MTLRegionMake2D(0,0,side,side),mipmapLevel:0) }
        snapshotReadbacks += 1
        guard let provider = CGDataProvider(data:bytes as CFData),let image = CGImage(width:side,height:side,
            bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:side*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
            bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue),
            provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else { return nil }
        cachedField = (key,image)
        return image
    }

    @discardableResult
    func drawFullField(_ palette: PetPalette,time: Double,opacity: Double,displayDiameter: CGFloat,baseDiameter: CGFloat,zoom: CGFloat = 1) -> Bool {
        guard displayDiameter.isFinite,baseDiameter.isFinite,displayDiameter>0,baseDiameter>0,
              let context = NSGraphicsContext.current?.cgContext,
              let image = fieldImage(for:palette,time:time,bodyPixels:Int(ceil(baseDiameter*zoom*2)),pixelFootprint:1/Float(displayDiameter*zoom)) else { return false }
        context.saveGState()
        context.setAlpha(opacity)
        context.translateBy(x:114.27,y:114.27)
        context.scaleBy(x:zoom,y:zoom)
        context.translateBy(x:-114.27,y:-114.27)
        context.translateBy(x:0,y:228.54);context.scaleBy(x:1,y:-1)
        context.draw(image,in:CGRect(x:-57.135,y:-57.135,width:342.81,height:342.81))
        context.restoreGState()
        return true
    }
}
