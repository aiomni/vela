import AppKit
import MetalKit

@MainActor
final class LiveMaterialSurface: MTKView, MTKViewDelegate {
    struct Parameters {
        var time: Float = 0
        var kind: UInt32 = 0
        var size = SIMD2<Float>(0, 0)
        var center = SIMD2<Float>(0, 0)
        var scale = SIMD2<Float>(1, 1)
        var rotation: Float = 0
        var progress: Float = 0
        var style: UInt32 = 0
        var padding: Float = 0
        var monochrome = SIMD4<Float>(0, 0, 0, 1)
    }
    var parameters = Parameters()
    private(set) var submittedFrames = 0
    var available: Bool { device != nil && ShaderMaterials.shared.renderPipeline != nil }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero, device: ShaderMaterials.shared.renderingDevice)
        colorPixelFormat = .bgra8Unorm
        colorspace = CGColorSpace(name:CGColorSpace.sRGB)
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        isPaused = true
        enableSetNeedsDisplay = false
        framebufferOnly = true
        autoResizeDrawable = false
        presentsWithTransaction = true
        layer?.isOpaque = false
        layer?.minificationFilter = .linear
        delegate = self
        isHidden = true
    }
    required init(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func layout() {
        super.layout()
        updateDrawableSize()
    }
    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        // Render four samples per screen pixel before Core Animation downsamples the surface.
        let size = CGSize(width: max(1, bounds.width * scale * 2), height: max(1, bounds.height * scale * 2))
        if drawableSize != size { drawableSize = size }
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard !isHidden,let window,window.isVisible,window.occlusionState.contains(.visible) else { return }
        updateDrawableSize()
        guard let pipeline = ShaderMaterials.shared.renderPipeline,
              let queue = ShaderMaterials.shared.renderingQueue,
              let drawable = currentDrawable, let pass = currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer() else { return }
        if parameters.kind == 3, let renderer = ShaderMaterials.shared.starRenderer {
            guard renderer.encodeLive(command: command, output: pass, parameters: parameters) else { return }
        } else {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(ShaderMaterials.shared.volumeNoise,index:0)
        encoder.setFragmentBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        }
        command.commit()
        // Keep the material and native eye/mask layers in the same presentation transaction.
        command.waitUntilScheduled()
        drawable.present()
        submittedFrames += 1
    }
}
