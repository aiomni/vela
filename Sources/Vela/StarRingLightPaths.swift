import Foundation
import simd

/// Sparse lighting and point-reflection parameters. Orbital trails are generated
/// analytically by StarRingRenderer; no image textures or playback frames are stored.
struct StarRingLightPaths {
    struct LightField { let position: SIMD4<Float>;let radiance: SIMD4<Float> }
    struct Glint {
        let position:SIMD2<Float>;let radius:Float;let strength:Float;let color:SIMD3<Float>;let angle:Float
        let reflectionStrength:Float;let reflectionColor:SIMD3<Float>
        let hasFlare:Bool
        let shape:SIMD2<Float>
    }
    private struct Document: Decodable {
        let version: Int
        let lighting: [[Float]]?
        let dust: [[Float]]?
        let dustReflections: [[Float]]?
        let dustFlareIndices: [Int]?
        let dustShapes: [[Float]]?
    }

    @MainActor
    static func loadGlints() throws -> [Glint] {
        let url = Bundle.module.url(forResource:"StarRingPaths",withExtension:"json",subdirectory:"Assets")!
        let document = try JSONDecoder().decode(Document.self,from:Data(contentsOf:url))
        guard document.version == 1,let dust = document.dust,dust.count<=128,
              dust.allSatisfy({ $0.count==8 && $0.allSatisfy(\.isFinite) && (0.005...0.05).contains($0[2]) }) else {
            throw NSError(domain:"StarRingPaths",code:5)
        }
        let reflections = document.dustReflections
        guard reflections == nil || (reflections!.count == dust.count && reflections!.allSatisfy({
            $0.count == 4 && $0.allSatisfy({ $0.isFinite && $0 >= 0 })
        })) else { throw NSError(domain:"StarRingPaths",code:7) }
        let flares = document.dustFlareIndices
        guard flares == nil || (Set(flares!).count == flares!.count && flares!.allSatisfy({dust.indices.contains($0)})) else {
            throw NSError(domain:"StarRingPaths",code:8)
        }
        let shapes = document.dustShapes
        guard shapes == nil || (shapes!.count == dust.count && shapes!.allSatisfy({
            $0.count == 2 && $0.allSatisfy({$0.isFinite && (0.25...4).contains($0)})
        })) else { throw NSError(domain:"StarRingPaths",code:9) }
        return dust.enumerated().map { index,value in
            let reflected = reflections?[index] ?? Array(value[3...6])
            return Glint(position:insideGlass(SIMD2(value[0],value[1])),radius:value[2],strength:value[3],
                color:SIMD3(value[4],value[5],value[6]),angle:value[7],
                reflectionStrength:reflected[0],reflectionColor:SIMD3(reflected[1],reflected[2],reflected[3]),
                hasFlare:flares?.contains(index) ?? (value[4]>value[6]*1.1),
                shape:shapes.map({SIMD2($0[index][0],$0[index][1])}) ?? SIMD2(0.65,1.45))
        }
    }

    @MainActor
    static func loadLighting() throws -> [LightField] {
        let url = Bundle.module.url(forResource:"StarRingPaths",withExtension:"json",subdirectory:"Assets")!
        let document = try JSONDecoder().decode(Document.self,from:Data(contentsOf:url))
        guard document.version == 1,let fields = document.lighting,fields.count <= 80,
              fields.allSatisfy({ $0.count == 8 && $0.allSatisfy(\.isFinite) && $0[2]>0 && $0[3]>0 }) else {
            throw NSError(domain:"StarRingPaths",code:4)
        }
        return fields.map { LightField(position:SIMD4($0[0],$0[1],$0[2],$0[3]),radiance:SIMD4($0[4],$0[5],$0[6],$0[7])) }
    }

    /// Place geometry behind the shell so its refracted ray lands on the intended
    /// screen contour. The glass still performs live refraction.
    static func insideGlass(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let z = sqrt(max(0.0001,1-simd_dot(p,p)))
        let normal = simd_normalize(SIMD3(p.x,p.y,z))
        let incoming = SIMD3<Float>(0,0,-1)
        let transmitted = refract(incoming,normal,eta:1/1.46)
        let b = simd_dot(normal,transmitted)
        let disc = b*b-(1-0.968*0.968)
        guard disc>0 else { return p }
        let travel = -b-sqrt(disc)
        let innerPosition = normal+transmitted*travel
        let innerNormal = simd_normalize(innerPosition)
        let cosine = simd_dot(transmitted,innerNormal)
        let critical = max(0,1-1.46*1.46*(1-cosine*cosine))
        let ray = refract(transmitted,innerNormal,eta:1.46)
        guard simd_dot(ray,ray)>0.1,ray.z < -0.15 else { return p }
        let hit = innerPosition+ray*(-innerPosition.z/ray.z)
        let grazing = min(1,max(0,(-ray.z-0.15)/0.15))
        let transmission = min(1,critical/0.04)
        let weight = grazing*grazing*(3-2*grazing)*transmission*transmission*(3-2*transmission)
        return p+(SIMD2(hit.x,hit.y)-p)*weight
    }
    private static func refract(_ ray: SIMD3<Float>,_ normal: SIMD3<Float>,eta:Float) -> SIMD3<Float> {
        let dot = simd_dot(normal,ray),k = 1-eta*eta*(1-dot*dot)
        return k<0 ? .zero : eta*ray-(eta*dot+sqrt(k))*normal
    }
}
