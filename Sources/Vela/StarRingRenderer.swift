import AppKit
import Metal
import simd

/// One scene, shared by live presentation and review snapshots. No image textures or frame playback.
@MainActor
final class StarRingRenderer {
    struct Vertex {
        var position: SIMD2<Float>
        var local: SIMD2<Float>
        var distance: Float
        var strength: Float
        var color: SIMD4<Float>
        var animation: SIMD4<Float> = .zero
        // Star quads: core
        // width, halo width, halo radiance, and neutral-white core fraction.
        var wave: SIMD4<Float> = .zero
    }
    struct Curve {
        var radius: Float
        var inclination: Float
        var tilt: Float
        var phase: Float
        var speed: Float
        var brightness: Float
        var tone: SIMD3<Float>
        var tailLength: Float
        var width: Float
    }
    private struct Light { var position: SIMD4<Float>;var color: SIMD4<Float> }
    private struct PreparedField {
        var position: SIMD4<Float>
        var radiance: SIMD4<Float>
        var basis: SIMD4<Float>
        var accent: SIMD4<Float>
    }
    private struct FieldSeed {
        let field: StarRingLightPaths.LightField
        let sinPhase: Float
        let rimRadius: Float
        let gate: Float
    }
    private struct Surfaces {
        let width: Int
        let height: Int
        let scene: any MTLTexture
        let emittedLight: any MTLTexture
        let bloom: [any MTLTexture]
        let scratch: [any MTLTexture]
    }
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let glass: any MTLRenderPipelineState
    private let emission: any MTLRenderPipelineState
    private let composite: any MTLRenderPipelineState
    private let downsample: any MTLComputePipelineState
    private let blur: any MTLComputePipelineState
    private let lightFields: [StarRingLightPaths.LightField]
    private let fieldSeeds: [FieldSeed]
    private let companionSeeds: [SIMD4<Float>] = (0..<9).map { index in
        let phase = Float(index)*2.399
        return SIMD4(2.03+0.17*sin(phase),4.33+0.21*cos(phase),
            0.26+0.04*cos(phase),0.20+0.03*sin(phase))
    }
    private let glintMotionSeeds: [SIMD2<Float>]
    private let glints: [StarRingLightPaths.Glint]
    private struct AttachedGlint {
        let headIndex: Int
        let glintIndex: Int
        let anchor: SIMD2<Float>
    }
    private lazy var attachedGlints: [AttachedGlint] = (6..<curves.count).compactMap { index in
        let p = point(curves[index],angle:curves[index].phase)
        let anchor = StarRingLightPaths.insideGlass(SIMD2(p.x,p.y))
        let nearest = glints.indices.filter { glints[$0].strength>0 }.min {
            simd_distance(glints[$0].position,anchor)<simd_distance(glints[$1].position,anchor)
        }
        guard let nearest,simd_distance(glints[nearest].position,anchor)<0.03 else { return nil }
        return AttachedGlint(headIndex:index,glintIndex:nearest,anchor:anchor)
    }
    private let buffers: StarRingBuffers
    private var staticGeometryBuffer: (any MTLBuffer)?
    private var staticVertexCount = 0
    private(set) var staticGeometryBuilds = 0
    private(set) var geometryBufferAllocations = 3
    private var liveSurfaces: Surfaces?
    private var reviewSurfaces: Surfaces?
    private struct ReviewKey: Equatable {
        let phase: Float
        let footprint: Float
        let side: Int
        let bloomLevels: Int
    }
    private var cachedReview: (ReviewKey, CGImage)?
    private(set) var lastGPUTimeMilliseconds: Double = 0
    private(set) var geometryVertexCount = 0
    private(set) var liveFrames = 0
    private(set) var snapshots = 0

    init(device: any MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue(),
              let url = Bundle.module.url(forResource: "StarRing", withExtension: "metal", subdirectory: "Assets") else {
            throw NSError(domain: "StarRing", code: 1)
        }
        self.queue = queue
        buffers = try StarRingBuffers(device:device,vertexStride:MemoryLayout<Vertex>.stride,
            fieldStride:MemoryLayout<PreparedField>.stride)
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        func pipeline(_ vertex: String, _ fragment: String, _ format: MTLPixelFormat, additive: Bool = false) throws -> any MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = format
            if additive {
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = .one
                color.destinationRGBBlendFactor = .one
                color.sourceAlphaBlendFactor = .one
                color.destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        glass = try pipeline("ringFullVertex", "ringGlass", .rgba16Float)
        emission = try pipeline("ringMeshVertex", "ringEmission", .rgba16Float, additive: true)
        composite = try pipeline("ringFullVertex", "ringComposite", .bgra8Unorm)
        downsample = try device.makeComputePipelineState(function: library.makeFunction(name: "ringDownsample")!)
        blur = try device.makeComputePipelineState(function: library.makeFunction(name: "ringBlur")!)
        // Zero-radiance fitted lobes cannot affect any frame, even when their
        // breathing/drift changes. Keep the authored data, omit only dead work.
        lightFields = try StarRingLightPaths.loadLighting().filter {
            $0.radiance.x != 0 || $0.radiance.y != 0 || $0.radiance.z != 0
        }
        glints = try StarRingLightPaths.loadGlints()
        glintMotionSeeds = glints.indices.map { index in
            let phase = Float(index)*2.399
            return SIMD2(sin(phase),cos(phase))
        }
        fieldSeeds = lightFields.map { field in
            let phase = field.radiance.w
            return FieldSeed(field:field,sinPhase:sin(phase),rimRadius:0.984+0.008*sin(phase),
                gate:0.3+0.7*pow(sin(phase*1.73),2))
        }
        precondition(MemoryLayout<Vertex>.stride == 80)
        precondition(MemoryLayout<PreparedField>.stride == 64)
        let vertices = staticGeometry()
        guard let buffer = device.makeBuffer(bytes:vertices,length:vertices.count*MemoryLayout<Vertex>.stride,
            options:.storageModeShared) else { throw NSError(domain:"StarRing",code:2) }
        buffer.label = "StarRing immutable paths and reflections"
        staticGeometryBuffer = buffer
        staticVertexCount = vertices.count
        geometryBufferAllocations += 1
    }

    private func makeSurfaces(width: Int, height: Int, bloomLevels: Int = 5) -> Surfaces? {
        func texture(_ width: Int, _ height: Int) -> (any MTLTexture)? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
            return device.makeTexture(descriptor: descriptor)
        }
        guard let scene = texture(width, height), let emittedLight = texture(width,height) else { return nil }
        var bloom: [any MTLTexture] = [], scratch: [any MTLTexture] = []
        for level in 1...bloomLevels {
            let w = max(1, width >> level), h = max(1, height >> level)
            guard let a = texture(w, h), let b = texture(w, h) else { return nil }
            bloom.append(a); scratch.append(b)
        }
        return Surfaces(width: width, height: height, scene: scene, emittedLight: emittedLight, bloom: bloom, scratch: scratch)
    }

    private let curves: [Curve] = {
        let gold = SIMD3<Float>(1,0.48,0.15),blue = SIMD3<Float>(0.10,0.40,1)
        func orbit(_ anchor:SIMD2<Float>,_ inclination:Float,_ tilt:Float,_ speed:Float,
                   _ brightness:Float,_ tone:SIMD3<Float>,_ tail:Float,_ width:Float) -> Curve {
            let u = anchor.x*cos(tilt)+anchor.y*sin(tilt)
            let v = -anchor.x*sin(tilt)+anchor.y*cos(tilt)
            var c = cos(inclination)
            c = max(c,abs(v)/sqrt(max(0.001,0.988*0.988-u*u)))
            let radius = sqrt(u*u+v*v/(c*c))
            return Curve(radius:radius,inclination:acos(min(1,c)),tilt:tilt,
                phase:atan2(v/c,u),speed:speed*3,brightness:brightness,tone:tone,tailLength:tail,width:width)
        }
        // Analytic inclined circles: the initial heads retain the design's major
        // landmarks, but the flowing tails are continuous curves, not traced fragments.
        return [
            orbit(SIMD2(-0.53125,-0.650),0.50,-0.64,-0.028,2.4,gold,1.60,0.0016),
            orbit(SIMD2(-0.73125,0.48125),1.07,-0.63,0.032,2.2,gold,1.65,0.0016),
            orbit(SIMD2(0.7875,-0.050),0.92,-0.64,-0.026,2.3,gold,1.85,0.0017),
            orbit(SIMD2(0.5625,-0.7125),1.01,-0.64,0.031,2.5,blue,1.75,0.0015),
            orbit(SIMD2(-0.89375,-0.050),0.60,-0.60,0.022,1.4,blue,1.15,0.0013),
            orbit(SIMD2(0.050,-0.650),0.64,-0.66,0.036,1.1,blue,1.00,0.0010),
            orbit(SIMD2(0.36875,-0.4875),0.98,-0.72,0.026,0.9,blue,0.90,0.0009),
            orbit(SIMD2(0.19375,-0.40625),0.92,-0.60,0.031,0.75,blue,0.95,0.0008),
            orbit(SIMD2(-0.525,0.250),1.10,-0.74,-0.028,0.85,blue,0.90,0.0009)
        ]
    }()

    private func point(_ curve: Curve, angle: Float) -> SIMD3<Float> {
        let u = curve.radius*cos(angle)
        let v = curve.radius*sin(angle)*cos(curve.inclination)
        return SIMD3(u*cos(curve.tilt)-v*sin(curve.tilt),
            u*sin(curve.tilt)+v*cos(curve.tilt),curve.radius*sin(angle)*sin(curve.inclination))
    }

    private func streamParameters(time:Float) -> [SIMD4<Float>] {
        curves.map { curve in
            let angle = (Double(curve.phase)+Double(time)*Double(curve.speed))
                .truncatingRemainder(dividingBy:2*Double.pi)
            return SIMD4(Float(angle),curve.speed<0 ? -1 : 1,curve.tailLength,curve.width)
        }
    }

    private func companionParameters(heads:[SIMD4<Float>]) -> [SIMD4<Float>] {
        heads.enumerated().map { index,head in
            let seed = companionSeeds[index]
            return SIMD4(head.x+seed.x*head.y,head.x+seed.y*head.y,seed.z,seed.w)
        }
    }

    private func movingGeometry(time: Float,headCenters:[SIMD2<Float>],companions:[SIMD4<Float>]) -> [Vertex] {
        var vertices: [Vertex] = []
        vertices.reserveCapacity(162)
        let corners:[SIMD2<Float>] = [SIMD2(-1,-1),SIMD2(1,-1),SIMD2(1,1),
            SIMD2(-1,-1),SIMD2(1,1),SIMD2(-1,1)]
        for (index,curve) in curves.enumerated() {
            let center = headCenters[index]
            let main = index<6
            let optics = main ? [SIMD4<Float>(0.008,0.048,3.2,1),SIMD4(0.0075,0.033,0.60,1),
                SIMD4(0.0075,0.033,0.60,1),SIMD4(0.0075,0.060,3.0,0.8),
                SIMD4(0.0075,0.033,0.60,1),SIMD4(0.0065,0.028,0.30,0.15)][index]
                : SIMD4(0.0055,0.023,0.25,0)
            let strength:Float = main ? (index == 5 ? 0.25 : index == 4 ? 0.40
                : 0.94+0.06*sin(time*0.3+Float(index))) : 0.16+0.018*sin(time*0.20+Float(index-6))
            let tone:SIMD3<Float> = index == 0 ? SIMD3(1,0.25,0.035)
                : index<3 ? SIMD3(1,0.42,0.12) : index == 3 ? SIMD3(0.03,0.20,1) : curve.tone
            let angle:Float = main ? [Float(0.12),-0.10,0.06,0.18,0.14,-0.08][index] : 0
            let flare:Float = main ? [Float(5.0),2.8,3.5,4.5,2.8,2.8][index] : 2.8
            let radius:Float = main ? 0.15 : 0.085
            for corner in corners {
                let rotated = SIMD2(corner.x*cos(angle)-corner.y*sin(angle),
                    corner.x*sin(angle)+corner.y*cos(angle))
                vertices.append(Vertex(position:center+rotated*radius,local:corner*radius,
                    distance:flare,strength:strength,color:SIMD4(tone,1),wave:optics))
            }
            // Small companion meteors restore long/short layering without tracing
            // image fragments. Their heads and trails share the same orbit phase.
            for companion in 0..<2 {
                let head = companion == 0 ? companions[index].x : companions[index].y
                let position = point(curve,angle:head)
                let center = StarRingLightPaths.insideGlass(SIMD2(position.x,position.y))
                let strength = (0.025+0.018*sqrt(curve.brightness))*23
                for corner in corners {
                    vertices.append(Vertex(position:center+corner*0.055,local:corner*0.055,
                        distance:0.0042,strength:strength,color:SIMD4(curve.tone,2)))
                }
            }
        }
        return vertices
    }

    private func staticGeometry() -> [Vertex] {
        staticGeometryBuilds += 1
        var vertices: [Vertex] = []
        vertices.reserveCapacity(16_000)
        func quad(center: SIMD2<Float>, radius: Float, strength: Float, tone: SIMD3<Float>, dust: Bool,
                  angle: Float, animation: SIMD4<Float>, shape:SIMD2<Float> = SIMD2(0.65,1.45)) {
            let corners: [SIMD2<Float>] = [SIMD2(-1,-1),SIMD2(1,-1),SIMD2(1,1),SIMD2(-1,-1),SIMD2(1,1),SIMD2(-1,1)]
            for corner in corners {
                let point = dust ? corner*shape : corner
                let rotated = SIMD2(point.x*cos(angle)-point.y*sin(angle),point.x*sin(angle)+point.y*cos(angle))
                vertices.append(Vertex(position:center+rotated*radius,local:corner*radius,
                    distance:dust ? radius*0.1 : 2.8,strength:strength,color:SIMD4(tone,dust ? 2 : 1),animation:animation,
                    wave:SIMD4(0.0075,0.033,0.60,1)))
            }
        }
        let segments = 160
        for (index,curve) in curves.enumerated() {
            func position(_ step:Int) -> SIMD2<Float> {
                let angle = Float(step)*2*Float.pi/Float(segments)
                let p = point(curve,angle:angle)
                return StarRingLightPaths.insideGlass(SIMD2(p.x,p.y))
            }
            func vertex(_ step:Int,_ side:Float) -> Vertex {
                let center = position(step)
                let tangent = simd_normalize(position(step+1)-position(step-1))
                let normal = SIMD2(-tangent.y,tangent.x)
                let angle = Float(step)*2*Float.pi/Float(segments)
                return Vertex(position:center+normal*(side*0.025),local:SIMD2(curve.width,angle),
                    distance:side*0.025,strength:curve.brightness,color:SIMD4(curve.tone,0.25),
                    animation:SIMD4(0,0,Float(index),4))
            }
            let left = (0...segments).map { vertex($0,-1) }
            let right = (0...segments).map { vertex($0,1) }
            for step in 0..<segments {
                vertices.append(left[step]);vertices.append(right[step]);vertices.append(left[step+1])
                vertices.append(right[step]);vertices.append(right[step+1]);vertices.append(left[step+1])
            }
        }
        for (index,glint) in glints.enumerated() where glint.strength > 0 {
            // Warm accent stars retain a small cross flare instead of becoming blue
            // dust. Their sparse anchors and drift remain independent of the orbits.
            let accent = glint.hasFlare
            quad(center:glint.position,radius:accent ? 0.08 : glint.radius,
                strength:glint.strength*1.8,
                tone:glint.color,dust:!accent,angle:glint.angle,
                animation:SIMD4(0,0,Float(index),2),shape:glint.shape)
        }
        // Short curved reflection slivers share the sparse glint anchors. Their
        // unequal lengths, orientation and taper avoid another full orbital ring.
        for (index,glint) in glints.enumerated() where index<80 && simd_length(glint.position)>0.62 {
            let phase = Float(index)*2.399
            let z = sqrt(max(0.001,1-simd_dot(glint.position,glint.position)))
            let normal = SIMD3<Float>(0.38,0.65,0.65)
            let surface = simd_normalize(SIMD3(glint.position.x,glint.position.y,index%3 == 0 ? -z : z))
            let tangent = simd_normalize(simd_cross(normal,surface))
            // Unequal great-circle arcs follow the shell's actual curvature.
            // Projecting a straight tangent with a shared bow made the reflection
            // fragments look detached from the glass, particularly at the rim.
            let length:Float = 0.035+0.085*pow(sin(phase),2)
            let strength = glint.reflectionStrength
            func vertex(_ step:Int,_ side:Float) -> Vertex {
                let u = Float(step)/8
                let angle = (u-0.5)*length
                let point = surface*cos(angle)+tangent*sin(angle)
                let derivative = -surface*sin(angle)+tangent*cos(angle)
                let direction = simd_normalize(SIMD2(derivative.x,derivative.y))
                let crossTrack = SIMD2(-direction.y,direction.x)
                let taper = pow(sin(u * .pi),2)
                return Vertex(position:SIMD2(point.x,point.y)+crossTrack*side*0.012,
                    local:SIMD2(0.00055+0.0003*taper,index%2 == 0 ? 0.004 : -0.004),distance:side*0.012,
                    strength:strength*taper,color:SIMD4(glint.reflectionColor*1.5,0),
                    animation:SIMD4(0,0,Float(index),3))
            }
            let left = (0...8).map { vertex($0,-1) }
            let right = (0...8).map { vertex($0,1) }
            for i in 0..<8 {
                let a=left[i],b=right[i],c=left[i+1],d=right[i+1]
                vertices.append(a);vertices.append(b);vertices.append(c)
                vertices.append(b);vertices.append(d);vertices.append(c)
            }
        }
        return vertices
    }

    private func preparedFields(time: Float) -> [PreparedField] {
        fieldSeeds.map { seed in
            let field = seed.field, phase = field.radiance.w
            let animatedSin = sin(time*0.035+phase)
            let rotation = 0.005*(animatedSin-seed.sinPhase)
            let c = cos(rotation),s = sin(rotation)
            let center = SIMD2(field.position.x*c-field.position.y*s,field.position.x*s+field.position.y*c)
            let angle = atan2(center.y,center.x)
            let breathe = 1+0.025*(sin(time*0.07+phase)-seed.sinPhase)
            let at = simd_length(center)>0 ? simd_normalize(center)*seed.rimRadius : SIMD2<Float>.zero
            return PreparedField(position:SIMD4(center.x,center.y,1/field.position.z,1/field.position.w),
                radiance:SIMD4(field.radiance.x*breathe,field.radiance.y*breathe,field.radiance.z*breathe,0),
                basis:SIMD4(cos(angle),sin(angle),simd_length(center),0),
                accent:SIMD4(0.012*seed.sinPhase+0.002*animatedSin,seed.gate,at.x,at.y))
        }
    }

    private func encode(command: any MTLCommandBuffer, output: MTLRenderPassDescriptor,
                        surfaces: Surfaces, parameters: LiveMaterialSurface.Parameters) -> Bool {
        var frame = parameters
        guard let staticBuffer = staticGeometryBuffer,let (slotIndex,slot) = buffers.acquire() else { return false }
        var encoded = false
        defer { if !encoded { buffers.release(slotIndex) } }
        let streams = streamParameters(time:frame.time)
        let companions = companionParameters(heads:streams)
        let headPositions = curves.enumerated().map { point($0.element,angle:streams[$0.offset].x) }
        let headCenters = headPositions.map { StarRingLightPaths.insideGlass(SIMD2($0.x,$0.y)) }
        let vertices = movingGeometry(time:frame.time,headCenters:headCenters,companions:companions)
        precondition(vertices.count<=buffers.vertexCapacity)
        geometryVertexCount = vertices.count+staticVertexCount
        vertices.withUnsafeBufferPointer {
            _ = memcpy(slot.vertices.contents(),$0.baseAddress!,vertices.count*MemoryLayout<Vertex>.stride)
        }
        let fields = preparedFields(time:frame.time)
        if !fields.isEmpty {
            fields.withUnsafeBufferPointer {
                _ = memcpy(slot.fields.contents(),$0.baseAddress!,fields.count*MemoryLayout<PreparedField>.stride)
            }
        }
        let angles = SIMD4<Float>(0.043,0.037,0.16,0.13)*frame.time
        let s = SIMD4<Float>(sin(angles.x),sin(angles.y),sin(angles.z),sin(angles.w))
        let c = SIMD4<Float>(cos(angles.x),cos(angles.y),cos(angles.z),cos(angles.w))
        var glintMotion = glintMotionSeeds.map { seed -> SIMD4<Float> in
            return SIMD4((s.x*seed.y+c.x*seed.x-seed.x)*0.002,
                (c.y*seed.y-s.y*seed.x-seed.y)*0.002,
                1+0.16*(s.z*seed.y+c.z*seed.x-seed.x),0.45+0.10*(s.w*seed.y+c.w*seed.x))
        }
        // Preserve the fitted small cores, but bind them to the moving head rather
        // than leaving another bright core at its initial reference position.
        for attachment in attachedGlints {
            let offset = headCenters[attachment.headIndex]-attachment.anchor
            glintMotion[attachment.glintIndex].x += offset.x
            glintMotion[attachment.glintIndex].y += offset.y
        }
        var rotationBasis = SIMD2<Float>(cos(frame.rotation),sin(frame.rotation))
        var flow = SIMD4<Float>(0,0,rotationBasis.x,rotationBasis.y)
        guard let hdr = command.makeRenderCommandEncoder(descriptor: {
                  let pass = MTLRenderPassDescriptor()
                  pass.colorAttachments[0].texture = surfaces.emittedLight
                  pass.colorAttachments[0].loadAction = .clear
                  pass.colorAttachments[0].storeAction = .store
                  pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0)
                  return pass
              }()) else { return false }
        hdr.setRenderPipelineState(emission)
        hdr.setVertexBuffer(slot.vertices, offset: 0, index: 0)
        hdr.setVertexBytes(&frame, length: MemoryLayout<LiveMaterialSurface.Parameters>.stride, index: 1)
        hdr.setVertexBytes(&flow,length:MemoryLayout<SIMD4<Float>>.stride,index:2)
        func bindMotion(_ values: [SIMD4<Float>], index: Int) {
            if values.isEmpty {
                var zero = SIMD4<Float>.zero
                hdr.setVertexBytes(&zero,length:MemoryLayout<SIMD4<Float>>.stride,index:index)
            } else {
                values.withUnsafeBufferPointer {
                    hdr.setVertexBytes($0.baseAddress!,length:values.count*MemoryLayout<SIMD4<Float>>.stride,index:index)
                }
            }
        }
        bindMotion(streams,index:3)
        bindMotion(glintMotion,index:4)
        hdr.setFragmentBytes(&frame, length: MemoryLayout<LiveMaterialSurface.Parameters>.stride, index: 1)
        companions.withUnsafeBufferPointer {
            hdr.setFragmentBytes($0.baseAddress!,length:companions.count*MemoryLayout<SIMD4<Float>>.stride,index:2)
        }
        hdr.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        hdr.setVertexBuffer(staticBuffer,offset:0,index:0)
        hdr.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:staticVertexCount)
        hdr.endEncoding()
        let shellPass = MTLRenderPassDescriptor()
        shellPass.colorAttachments[0].texture = surfaces.scene
        shellPass.colorAttachments[0].loadAction = .clear
        shellPass.colorAttachments[0].storeAction = .store
        guard let shell = command.makeRenderCommandEncoder(descriptor: shellPass) else { return false }
        shell.setRenderPipelineState(glass)
        shell.setFragmentBytes(&frame, length: MemoryLayout<LiveMaterialSurface.Parameters>.stride, index: 0)
        let lights = Array(curves.prefix(6).enumerated()).map { index, curve -> Light in
            let p = headPositions[index]
            let intensity: Float = index < 3 ? 0.014 : 0.075
            return Light(position: SIMD4(p,1),color: SIMD4(curve.tone*intensity,1))
        }
        lights.withUnsafeBufferPointer {
            shell.setFragmentBytes($0.baseAddress!,length: lights.count*MemoryLayout<Light>.stride,index: 1)
        }
        shell.setFragmentBuffer(slot.fields,offset:0,index:2)
        var lightFieldCount = UInt32(lightFields.count)
        shell.setFragmentBytes(&lightFieldCount,length:MemoryLayout<UInt32>.stride,index:3)
        shell.setFragmentBytes(&rotationBasis,length:MemoryLayout<SIMD2<Float>>.stride,index:4)
        shell.setFragmentTexture(surfaces.emittedLight,index: 0)
        shell.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3)
        shell.endEncoding()
        guard let compute = command.makeComputeCommandEncoder() else { return false }
        func dispatch(_ texture: any MTLTexture) {
            compute.dispatchThreads(MTLSize(width: texture.width, height: texture.height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16,height: 16,depth: 1))
        }
        for level in surfaces.bloom.indices {
            var threshold: Float = level == 0 ? 1.2 : -1
            compute.setComputePipelineState(downsample)
            compute.setTexture(level == 0 ? surfaces.scene : surfaces.bloom[level-1], index: 0)
            compute.setTexture(surfaces.bloom[level], index: 1)
            compute.setBytes(&threshold, length: MemoryLayout<Float>.stride, index: 0)
            dispatch(surfaces.bloom[level])
            for direction in [SIMD2<Int32>(1,0), SIMD2<Int32>(0,1)] {
                var axis = direction
                compute.setComputePipelineState(blur)
                compute.setTexture(direction.x == 1 ? surfaces.bloom[level] : surfaces.scratch[level], index: 0)
                compute.setTexture(direction.x == 1 ? surfaces.scratch[level] : surfaces.bloom[level], index: 1)
                compute.setBytes(&axis, length: MemoryLayout<SIMD2<Int32>>.stride, index: 0)
                dispatch(surfaces.bloom[level])
            }
        }
        compute.endEncoding()
        guard let final = command.makeRenderCommandEncoder(descriptor: output) else { return false }
        final.setRenderPipelineState(composite)
        final.setFragmentBytes(&frame, length: MemoryLayout<LiveMaterialSurface.Parameters>.stride, index: 0)
        final.setFragmentBytes(&rotationBasis,length:MemoryLayout<SIMD2<Float>>.stride,index:1)
        var bloomCount = UInt32(surfaces.bloom.count)
        final.setFragmentBytes(&bloomCount,length:MemoryLayout<UInt32>.stride,index:2)
        final.setFragmentTexture(surfaces.scene, index: 0)
        // Unused slots stay valid; the uniform count prevents sampling them.
        for level in 0..<5 { final.setFragmentTexture(surfaces.bloom[min(level,surfaces.bloom.count-1)], index: level+1) }
        final.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        final.endEncoding()
        let bufferPool = buffers
        command.addCompletedHandler { _ in bufferPool.release(slotIndex) }
        encoded = true
        return true
    }

    func encodeLive(command: any MTLCommandBuffer, output: MTLRenderPassDescriptor,
                    parameters: LiveMaterialSurface.Parameters) -> Bool {
        guard let target = output.colorAttachments[0].texture else { return false }
        let levels = Self.bloomLevels(renderWidth:target.width,renderHeight:target.height)
        if liveSurfaces?.width != target.width || liveSurfaces?.height != target.height || liveSurfaces?.bloom.count != levels {
            liveSurfaces = makeSurfaces(width: target.width, height: target.height,bloomLevels:levels)
        }
        guard let surfaces = liveSurfaces, encode(command: command, output: output, surfaces: surfaces, parameters: parameters) else { return false }
        liveFrames += 1
        return true
    }

    // The drawable includes transparent padding and two samples per display axis.
    // Size, rather than the animated pose, determines quality so breathing and
    // hovering cannot repeatedly recreate the texture workspace.
    static func bloomLevels(renderWidth: Int, renderHeight: Int) -> Int {
        max(renderWidth,renderHeight) <= 576 ? 4 : 5
    }

    func reviewImage(time: Double, pixelFootprint: Float = 0, renderSide: Int = 768, bloomLevels: Int = 5) -> CGImage? {
        precondition(renderSide >= 24 && (3...5).contains(bloomLevels))
        let phase = Float(floor(time * 24) / 24)
        let key = ReviewKey(phase:phase,footprint:pixelFootprint,side:renderSide,bloomLevels:bloomLevels)
        if let cachedReview, cachedReview.0 == key { return cachedReview.1 }
        let side = renderSide
        if reviewSurfaces?.width != side || reviewSurfaces?.bloom.count != bloomLevels {
            reviewSurfaces = makeSurfaces(width: side,height: side,bloomLevels:bloomLevels)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,width: side,height: side,mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget]
        guard let target = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer(), let surfaces = reviewSurfaces else { return nil }
        var frame = LiveMaterialSurface.Parameters()
        frame.time = phase;frame.kind = 3;frame.progress = 1;frame.style = 3
        frame.size = SIMD2(Float(side),Float(side));frame.center = frame.size / 2
        frame.scale = SIMD2(repeating: Float(side) / (228.54 * 1.5))
        frame.padding = pixelFootprint
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard encode(command: command, output: pass, surfaces: surfaces, parameters: frame) else { return nil }
        command.commit();command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        lastGPUTimeMilliseconds = max(0, command.gpuEndTime-command.gpuStartTime)*1000
        var bytes = Data(count: side*side*4)
        bytes.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow: side*4,
            from: MTLRegionMake2D(0,0,side,side),mipmapLevel: 0) }
        guard let provider = CGDataProvider(data: bytes as CFData), let image = CGImage(width: side,height: side,
            bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: side*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,decode: nil,shouldInterpolate: true,intent: .defaultIntent) else { return nil }
        snapshots += 1
        cachedReview = (key,image)
        return image
    }

    /// Same passes as the drawable, at the candidate's actual physical resolution.
    func qualityImage(time: Double, bodyPixels: Int, samples: Float, bloomLevels: Int) -> CGImage? {
        let side = max(24,Int(ceil(Float(bodyPixels)*1.5*samples/6))*6)
        return reviewImage(time:time,pixelFootprint:1/Float(bodyPixels),renderSide:side,bloomLevels:bloomLevels)
    }

    func bodyImage(time: Double, pixelFootprint: Float = 0) -> CGImage? {
        reviewImage(time: time,pixelFootprint: pixelFootprint)?.cropping(to: CGRect(x: 128,y: 128,width: 512,height: 512))
    }

    func drawFullField(time: Double, opacity: Double, displayDiameter: CGFloat, baseDiameter: CGFloat, zoom: CGFloat = 1) {
        // PetView review canvases must filter for their final display pixels,
        // just like the live drawable. A fixed 512px body with zero footprint
        // otherwise presents more subpixel detail than the real desktop view.
        guard displayDiameter.isFinite,baseDiameter.isFinite,displayDiameter>0,baseDiameter>0,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let side = max(24,Int(ceil(baseDiameter*zoom*3/6))*6)
        let levels = Self.bloomLevels(renderWidth:side,renderHeight:side)
        guard let image = reviewImage(time:time,pixelFootprint:1/Float(displayDiameter*zoom),renderSide:side,bloomLevels:levels) else { return }
        context.saveGState()
        context.setAlpha(opacity)
        context.translateBy(x:114.27,y:114.27)
        context.scaleBy(x:zoom,y:zoom)
        context.translateBy(x:-114.27,y:-114.27)
        context.translateBy(x: 0,y: 228.54)
        context.scaleBy(x: 1,y: -1)
        context.draw(image,in: CGRect(x: -57.135,y: -57.135,width: 342.81,height: 342.81))
        context.restoreGState()
    }
}
